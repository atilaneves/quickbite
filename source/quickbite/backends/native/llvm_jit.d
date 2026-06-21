module quickbite.backends.native.llvm_jit;


private:


// A native backend that reuses SystemLinker's object production verbatim and
// replaces only the load step: instead of `dmd -shared` + dlopen, it links the
// same `.o` files in-process with LLVM's ORC JIT, killing the ~30 ms linker
// spawn. Object production is shared via native/codegen.d; this backend
// differs from SystemLinker only after the objects exist on disk.
public class LLVMJit:
    imported!"quickbite.backends".Backend,
    imported!"quickbite.backends.runner".GroupedRunner
{
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.backends.runner: TestResult;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    private const LLVMJitInputs _inputs;

    public alias eval = Evaluator.eval;

    public this(
        in LLVMJitInputs inputs = LLVMJitInputs.init,
    ) @safe @nogc nothrow pure {
        _inputs = inputs;
    }

    public this(
        const string[] linkFiles,
        const string[] importPaths,
    ) {
        this(
            LLVMJitInputs(
                importPaths,
                sharedLibraries(linkFiles),
                staticLibraries(linkFiles),
            ),
        );
        loadDependencyImages(_inputs.dependencyImages);
    }

    public this(
        const string[] linkFiles,
        const string[] importPaths,
        in string packageRoot,
    ) {
        this(
            LLVMJitInputs(
                archiveImportPathsUnder(importPaths, packageRoot),
                sharedLibraries(linkFiles),
                staticLibraries(linkFiles),
            ),
        );
        loadDependencyImages(_inputs.dependencyImages);
    }

    public override TestResult[] runTests(Module module_) {
        return runTests([module_]);
    }

    public override TestResult[] runTests(Module[] modules) {
        return runTestsInChild(modules, _inputs);
    }

    public override EvalResult eval(FuncDeclaration function_) {
        auto jit = jitForObjects([function_.getModule], _inputs);
        return evalCompiledFunction(jit, function_);
    }
}

// dmd emits each module's ModuleInfo, ClassInfo/vtables and template TypeInfos
// into the JIT object; weak-symbol interposition (defineHostSymbols) redirects
// only the symbols the host process also exports, so metadata unique to the
// object (user classes, the module's own TypeInfo, Throwable subtypes) stays
// JIT-resident. If the long-lived parent ran the tests, those metadata objects
// would survive in its GC heap as pointers into JIT memory, and the moment that
// memory is reclaimed they become dangling — a later collection would walk a
// survivor and dereference an unmapped ClassInfo/vtable, crashing the suite
// (ai/plans/llvm-jit.md, Step 4). So run the whole create -> load -> execute
// cycle in a forked child that _exits when done: the child takes all
// JIT-tainted heap and eh_frame state with it, and reports each test's result
// to the parent over a pipe. This mirrors the codegen fork the child itself
// then performs (native/codegen.d).
private imported!"quickbite.backends.runner".TestResult[] runTestsInChild(
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.runner: TestResult;
    import core.stdc.errno: EINTR, errno;
    import core.stdc.stdio: fflush;
    import core.sys.posix.unistd: _exit, close, fork, pipe, read;
    import core.sys.posix.sys.wait:
        WEXITSTATUS, WIFEXITED, WIFSIGNALED, WTERMSIG, waitpid;
    import std.conv: text;

    // The child inherits stdio buffers; flush so it cannot re-emit them.
    fflush(null);

    int[2] fds;
    if (pipe(fds) != 0)
        throw new Exception("pipe() failed");

    const pid = fork();
    if (pid < 0)
        throw new Exception("fork() failed");

    if (pid == 0) { // child: run the JIT cycle, report over the pipe, never return
        close(fds[0]);
        runChildAndReport(fds[1], modules, inputs);
        close(fds[1]);
        _exit(0);
    }

    // parent: read the report before reaping the child so a report larger than
    // the pipe buffer cannot deadlock against waitpid.
    close(fds[1]);
    ubyte[] data;
    ubyte[4096] buffer;
    for (;;) {
        const got = read(fds[0], buffer.ptr, buffer.length);
        if (got < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (got == 0)
            break;
        data ~= buffer[0 .. got];
    }
    close(fds[0]);

    int status;
    for (;;) {
        const reaped = waitpid(pid, &status, 0);
        if (reaped == pid)
            break;
        if (reaped < 0 && errno == EINTR)
            continue;
        throw new Exception("waitpid failed for the JIT child");
    }

    // The child _exits 0 after writing a complete frame (error frames included),
    // so a signal or non-zero exit means it died mid-report — surface it rather
    // than pass for success. A fixture that genuinely crashes lands here; none
    // of the SystemLinker-oracle fixtures do.
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        const detail = WIFSIGNALED(status)
            ? text("signal ", WTERMSIG(status))
            : WIFEXITED(status)
                ? text("exit code ", WEXITSTATUS(status))
                : text("status ", status);
        throw new Exception(text("JIT child died (", detail, ")"));
    }

    return decodeFrame(data);
}

// Child side: build the JIT, run every unittest, and write a result frame to
// the pipe. Never lets a Throwable unwind out — the child must not run the
// parent's inherited scope(exit)s — so infrastructure failures are reported as
// an error frame instead. A failing assert is not seen here: runUnitTest
// catches it into a TestResult.
private void runChildAndReport(
    int fd,
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.runner: TestResult;
    import quickbite.frontend.util: foreachUnitTestDeclaration;

    try {
        // No LLVMOrcDisposeLLJIT: the child _exits immediately after reporting,
        // so the OS reclaims the JIT mapping. Disposing here would be the very
        // munmap-then-collect that crashes the parent; _exit avoids both the
        // explicit unmap and any gc_term sweep over a JIT-resident survivor.
        auto jit = jitForObjects(modules, inputs);

        TestResult[] cases;
        foreach (module_; modules)
            foreachUnitTestDeclaration(module_, (unitTest) {
                cases ~= runUnitTest(jit, unitTest);
            });

        writeResults(fd, cases);
    } catch (Throwable throwable) {
        // toString can itself throw and would unwind into the parent's frames;
        // msg is a plain field, so report it and swallow any further failure.
        try
            writeError(fd, throwable.msg);
        catch (Throwable) {}
    }
}

public struct LLVMJitInputs {
    // Modules under archive import paths are defined by prebuilt libraries and
    // must not be codegen'd again. Whether default imports are traversed for
    // template-instance codegen is derived from the modules themselves by the
    // shared codegen path, not from a caller flag.
    public const string[] archiveImportPaths;
    // Cold dub dependency images are dlopen'd with RTLD_GLOBAL before ORC asks
    // the process-symbol generator to resolve dependency symbols.
    public const string[] dependencyImages;
    // Static libraries are searched by ORC and their members are linked only
    // when the hot objects reference a symbol they define.
    public const string[] staticLibraries;
}

private string[] sharedLibraries(in string[] linkFiles) @safe pure {
    import std.algorithm.iteration: filter, map;
    import std.array: array;

    return linkFiles
        .filter!(linkFile => linkFile.isSharedLibraryPath)
        .map!(linkFile => linkFile.idup)
        .array;
}

private string[] staticLibraries(in string[] linkFiles) @safe pure {
    import std.algorithm.iteration: filter, map;
    import std.array: array;

    return linkFiles
        .filter!(linkFile => !linkFile.isSharedLibraryPath)
        .map!(linkFile => linkFile.idup)
        .array;
}

private bool isSharedLibraryPath(in string linkFile) @safe pure {
    import std.string: endsWith;

    return linkFile.endsWith(".so");
}

// import paths under the package belong to the project under test and are
// compiled fresh per run; the rest belong to dependencies, whose code lives in
// the cold dependency image loaded into the process.
private string[] archiveImportPathsUnder(in string[] importPaths, in string packageRoot) @safe {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.searching: startsWith;
    import std.array: array;
    import std.path: absolutePath, buildNormalizedPath, dirSeparator;

    if (packageRoot.length == 0)
        return [];

    const root = packageRoot.absolutePath.buildNormalizedPath;
    bool underPackage(in string path) {
        const normalised = path.absolutePath.buildNormalizedPath;
        return normalised == root
            || normalised.startsWith(root ~ dirSeparator);
    }
    return importPaths
        .filter!(path => !underPackage(path))
        .map!(path => path.idup)
        .array;
}

private void loadDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages)
        loadDependencyImage(dependencyImage);
}

private void loadDependencyImage(in string dependencyImage) {
    import core.sys.posix.dlfcn: dlerror, dlopen, RTLD_GLOBAL, RTLD_NOW;
    import std.conv: text;
    import std.string: fromStringz, toStringz;

    if (dlopen(dependencyImage.toStringz, RTLD_NOW | RTLD_GLOBAL) is null) {
        auto err = dlerror();
        throw new Exception(text(
            "failed to load dependency image: ",
            dependencyImage,
            err is null ? "" : text(" :: ", err.fromStringz),
        ));
    }
}

// Emit the objects (shared codegen path, child emits, no link) and stand up an
// LLJIT with them all added to the main JITDylib, plus a process-symbol
// generator so druntime/phobos symbols resolve from the running bin/ut.
private imported!"quickbite.backends.native.llvm_orc".LLVMOrcLLJITRef jitForObjects(
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.native.codegen: CodegenInputs, emitObjectFilesForLink;
    import quickbite.backends.native.llvm_orc:
        LLVMOrcCreateLLJIT,
        LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess,
        LLVMOrcDefinitionGeneratorRef,
        LLVMOrcJITDylibAddGenerator,
        LLVMOrcLLJITGetGlobalPrefix,
        LLVMOrcLLJITGetMainJITDylib,
        LLVMOrcLLJITRef;
    import quickbite.frontend.compiler: withCompilerLock;
    import core.atomic: atomicFetchAdd;
    import core.sys.posix.unistd: getpid;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;

    // Unique per call; a crashed run leaks its directory, and a later run with
    // the same path would otherwise be ambiguous.
    const index = atomicFetchAdd(_jitCounter, 1u);
    const dir = buildPath(tempDir, text("quickbite_jit_", getpid, "_", index));
    mkdirRecurse(dir);
    // The JIT reads the objects into memory buffers before we return, so the
    // files can go as soon as they are added.
    scope(exit) rmdirRecurse(dir);

    string[] objPaths;
    withCompilerLock(() {
        objPaths = emitObjectFilesForLink(
            modules,
            dir,
            CodegenInputs(
                inputs.archiveImportPaths,
            ),
        );
    });

    initialiseNativeTarget;

    LLVMOrcLLJITRef jit;
    // Null builder requests host defaults: on this host that is the JITLink
    // ObjectLinkingLayer, whose EHFrameRegistrationPlugin calls
    // __register_frame so thrown Throwables unwind into the host catch (see
    // the gate in ai/plans/llvm-jit.md).
    throwOnError(LLVMOrcCreateLLJIT(&jit, null), "LLVMOrcCreateLLJIT");

    auto dylib = LLVMOrcLLJITGetMainJITDylib(jit);

    LLVMOrcDefinitionGeneratorRef generator;
    throwOnError(
        LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(
            &generator,
            LLVMOrcLLJITGetGlobalPrefix(jit),
            null,
            null,
        ),
        "process-symbol generator",
    );
    LLVMOrcJITDylibAddGenerator(dylib, generator);

    foreach (staticLibrary; inputs.staticLibraries)
        addStaticLibraryGenerator(jit, dylib, staticLibrary);

    foreach (objPath; objPaths)
        addObjectFile(jit, dylib, objPath);

    return jit;
}

private void addStaticLibraryGenerator(
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcLLJITRef jit,
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcJITDylibRef dylib,
    in string staticLibrary,
) {
    import quickbite.backends.native.llvm_orc:
        LLVMOrcCreateStaticLibrarySearchGeneratorForPath,
        LLVMOrcDefinitionGeneratorRef,
        LLVMOrcJITDylibAddGenerator,
        LLVMOrcLLJITGetObjLinkingLayer;
    import std.conv: text;
    import std.string: toStringz;

    LLVMOrcDefinitionGeneratorRef generator;
    throwOnError(
        LLVMOrcCreateStaticLibrarySearchGeneratorForPath(
            &generator,
            LLVMOrcLLJITGetObjLinkingLayer(jit),
            staticLibrary.toStringz,
        ),
        text("static library generator ", staticLibrary),
    );
    LLVMOrcJITDylibAddGenerator(dylib, generator);
}

// dmd emits many druntime/phobos template instances and TypeInfos into the rod
// object as weak (COMDAT) definitions, and some of those bodies are degenerate
// stubs (e.g. core.checkedint.mulu returns 0): the real bodies live in the
// host's libphobos2.so. When dmd's .so is dlopen'd, ELF interposition makes
// those calls bind to libphobos2's correct copies because the host is earlier
// in the global symbol scope. ORC has no such interposition: a symbol the added
// object defines (even weakly) is "resolved" within the JITDylib, so the
// process-symbol generator — which only fills *unresolved* symbols — never
// overrides it, and the broken stub runs. Replicate interposition by defining
// the host's copy of every object symbol the running process already exports as
// a weak absolute symbol *before* adding the object: ORC then discards the
// object's weak definition in favour of ours, while a symbol unique to the
// object (the unittest function, the module's own ModuleInfo) is not in the
// host, so dlsym misses it and the object keeps providing it. Weak flags mean a
// strong object definition, if any, still wins — exactly ELF semantics.
private void defineHostSymbols(
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcLLJITRef jit,
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcJITDylibRef dylib,
    imported!"quickbite.backends.native.llvm_orc".LLVMMemoryBufferRef buffer,
) {
    import quickbite.backends.native.llvm_orc:
        LLVMCreateBinary,
        LLVMDisposeBinary,
        LLVMDisposeSymbolIterator,
        LLVMGetSymbolName,
        LLVMJITEvaluatedSymbol,
        LLVMJITSymbolFlags,
        LLVMJITSymbolGenericFlags,
        LLVMMoveToNextSymbol,
        LLVMObjectFileCopySymbolIterator,
        LLVMObjectFileIsSymbolIteratorAtEnd,
        LLVMOrcAbsoluteSymbols,
        LLVMOrcCSymbolMapPair,
        LLVMOrcDisposeMaterializationUnit,
        LLVMOrcExecutorAddress,
        LLVMOrcJITDylibDefine,
        LLVMOrcLLJITMangleAndIntern;
    import core.sys.linux.dlfcn: RTLD_DEFAULT;
    import core.sys.posix.dlfcn: dlsym;
    import std.conv: text;
    import std.string: fromStringz;

    // The buffer stays owned by the caller (LLVMCreateBinary borrows it) and
    // is later handed to AddObjectFile, so the binary must be disposed first.
    char* binMessage;
    auto binary = LLVMCreateBinary(buffer, null, &binMessage);
    if (binary is null) {
        const detail = binMessage is null ? "" : binMessage.fromStringz.idup;
        throw new Exception(text("could not parse object: ", detail));
    }
    scope(exit) LLVMDisposeBinary(binary);

    LLVMOrcCSymbolMapPair[] pairs;
    auto iterator = LLVMObjectFileCopySymbolIterator(binary);
    if (iterator !is null) {
        scope(exit) LLVMDisposeSymbolIterator(iterator);
        enum genericFlags = LLVMJITSymbolGenericFlags.exported
            | LLVMJITSymbolGenericFlags.weak
            | LLVMJITSymbolGenericFlags.callable;
        for (; !LLVMObjectFileIsSymbolIteratorAtEnd(binary, iterator);
                LLVMMoveToNextSymbol(iterator)) {
            auto name = LLVMGetSymbolName(iterator);
            if (name is null)
                continue;
            // RTLD_DEFAULT searches the global scope the loader built for
            // bin/ut, i.e. libphobos2.so and friends; a hit is the host's
            // definitive copy of this symbol.
            auto hostAddress = dlsym(RTLD_DEFAULT, name);
            if (hostAddress is null)
                continue;
            pairs ~= LLVMOrcCSymbolMapPair(
                LLVMOrcLLJITMangleAndIntern(jit, name),
                LLVMJITEvaluatedSymbol(
                    cast(LLVMOrcExecutorAddress) hostAddress,
                    LLVMJITSymbolFlags(cast(ubyte) genericFlags, 0),
                ),
            );
        }
    }

    if (pairs.length == 0)
        return;

    auto unit = LLVMOrcAbsoluteSymbols(pairs.ptr, pairs.length);
    if (auto err = LLVMOrcJITDylibDefine(dylib, unit)) {
        // Define failed: the unit was not adopted, so dispose it. The names it
        // holds are released with it; ours were already consumed by the unit.
        LLVMOrcDisposeMaterializationUnit(unit);
        throwOnError(err, "defining host symbols");
    }
    // On success the dylib owns the unit and the names; nothing to free here
    // (LLVMOrcAbsoluteSymbols consumed each interned name's reference).
}

// LLJIT can only build for the host triple once the host target, its
// code-generator MC layer and asm printer are registered. Idempotent and
// process-wide, so do it once.
private void initialiseNativeTarget() {
    import quickbite.backends.native.llvm_orc:
        LLVMInitializeX86AsmPrinter,
        LLVMInitializeX86Target,
        LLVMInitializeX86TargetInfo,
        LLVMInitializeX86TargetMC;

    if (_nativeTargetInitialised)
        return;
    _nativeTargetInitialised = true;

    LLVMInitializeX86TargetInfo();
    LLVMInitializeX86Target();
    LLVMInitializeX86TargetMC();
    LLVMInitializeX86AsmPrinter();
}

private void addObjectFile(
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcLLJITRef jit,
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcJITDylibRef dylib,
    in string objPath,
) {
    import quickbite.backends.native.elf: normalizeDuplicateUndefinedGlobalsInFile;
    import quickbite.backends.native.llvm_orc:
        LLVMCreateMemoryBufferWithContentsOfFile,
        LLVMMemoryBufferRef,
        LLVMOrcLLJITAddObjectFile;
    import std.conv: text;
    import std.string: fromStringz, toStringz;

    normalizeDuplicateUndefinedGlobalsInFile(objPath);

    LLVMMemoryBufferRef buffer;
    char* message;
    if (LLVMCreateMemoryBufferWithContentsOfFile(objPath.toStringz, &buffer, &message) != 0) {
        const detail = message is null ? "" : message.fromStringz.idup;
        throw new Exception(text("could not read object file ", objPath, ": ", detail));
    }
    // Inject the host's copies of the object's weak druntime/phobos symbols
    // before adding it, so ORC binds calls to libphobos2 rather than to the
    // object's (sometimes degenerate) weak COMDAT bodies. This borrows the
    // buffer; AddObjectFile below consumes it.
    defineHostSymbols(jit, dylib, buffer);
    // AddObjectFile takes ownership of the buffer even on failure.
    throwOnError(
        LLVMOrcLLJITAddObjectFile(jit, dylib, buffer),
        text("AddObjectFile ", objPath),
    );
}

private imported!"quickbite.backends.runner".TestResult runUnitTest(
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcLLJITRef jit,
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import quickbite.backends.native.llvm_orc:
        LLVMOrcExecutorAddress,
        LLVMOrcLLJITLookup;
    import quickbite.backends.runner: TestResult;
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    // On Linux x86-64 ELF the global prefix is empty, so the lookup name is the
    // dmd mangled name as-is, exactly what SystemLinker passes to dlsym.
    LLVMOrcExecutorAddress address;
    throwOnError(
        LLVMOrcLLJITLookup(jit, &address, mangleExact(unitTest)),
        "lookup of " ~ mangleExact(unitTest).fromStringz.idup,
    );

    auto test = cast(void function()) address;

    auto result = TestResult(
        true,
        unitTest.ident.toChars.fromStringz.idup,
        unitTest.loc.toChars.fromStringz.idup,
        "",
    );

    try
        test();
    catch (Throwable throwable) { // assert failures are Errors, not Exceptions
        result.passed = false;
        result.message = throwable.msg.idup;
    }

    return result;
}

private imported!"quickbite.backends.evaluator".EvalResult evalCompiledFunction(
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcLLJITRef jit,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.native.evaluator: callNativeFunction, evalNativeFunction;
    import quickbite.backends.native.llvm_orc:
        LLVMOrcExecutorAddress,
        LLVMOrcLLJITLookup;
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    LLVMOrcExecutorAddress address;
    throwOnError(
        LLVMOrcLLJITLookup(jit, &address, mangleExact(function_)),
        "lookup of " ~ mangleExact(function_).fromStringz.idup,
    );

    return evalNativeFunction(
        () => callNativeFunction(cast(void*) address, function_),
        function_,
    );
}

// The child -> parent result frame. The first byte is the kind: 1 means a
// results frame (a size_t count followed by that many [passed, name, location,
// message] records), 0 means an error frame (the rest of the stream is the
// message). Strings are length-prefixed with a size_t; both sides are the same
// process image, so native endianness needs no normalisation.
private void writeResults(int fd, in imported!"quickbite.backends.runner".TestResult[] cases) {
    writeByte(fd, 1);
    writeSizeT(fd, cases.length);
    foreach (testCase; cases) {
        writeByte(fd, testCase.passed ? 1 : 0);
        writeString(fd, testCase.name);
        writeString(fd, testCase.location);
        writeString(fd, testCase.message);
    }
}

private void writeError(int fd, in char[] message) {
    writeByte(fd, 0);
    writeAll(fd, message);
}

private void writeString(int fd, in char[] str) {
    writeSizeT(fd, str.length);
    writeAll(fd, str);
}

private void writeByte(int fd, ubyte value) {
    writeAll(fd, (&value)[0 .. 1]);
}

private void writeSizeT(int fd, size_t value) {
    writeAll(fd, (cast(const(ubyte)*) &value)[0 .. size_t.sizeof]);
}

// write(2) may write partially or fail with EINTR; the frame must survive both
// or the parent sees a truncated report.
private void writeAll(int fd, scope const(void)[] data) {
    import core.stdc.errno: EINTR, errno;
    import core.sys.posix.unistd: write;

    const(ubyte)[] bytes = cast(const(ubyte)[]) data;
    size_t written = 0;
    while (written < bytes.length) {
        const wrote = write(fd, bytes.ptr + written, bytes.length - written);
        if (wrote < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        written += wrote;
    }
}

// Parent side: turn the bytes read from the pipe back into results, or throw
// the child's reported infrastructure error.
private imported!"quickbite.backends.runner".TestResult[] decodeFrame(
    const(ubyte)[] data,
) {
    import quickbite.backends.runner: TestResult;

    if (data.length == 0)
        throw new Exception("JIT child reported no results");

    const kind = data[0];
    auto rest = data[1 .. $];
    if (kind == 0) // error frame: the remainder is the message
        throw new Exception((cast(const(char)[]) rest).idup);

    size_t pos = 0;
    const count = readSizeT(rest, pos);
    TestResult[] cases;
    cases.reserve(count);
    foreach (_; 0 .. count) {
        const passed = readByte(rest, pos) != 0;
        const name = readString(rest, pos);
        const location = readString(rest, pos);
        const message = readString(rest, pos);
        cases ~= TestResult(passed, name, location, message);
    }
    return cases;
}

private string readString(const(ubyte)[] data, ref size_t pos) {
    const length = readSizeT(data, pos);
    if (pos + length > data.length)
        throw new Exception("truncated result stream");
    auto str = (cast(const(char)[]) data[pos .. pos + length]).idup;
    pos += length;
    return str;
}

private size_t readSizeT(const(ubyte)[] data, ref size_t pos) {
    if (pos + size_t.sizeof > data.length)
        throw new Exception("truncated result stream");
    size_t value;
    (cast(ubyte*) &value)[0 .. size_t.sizeof] = data[pos .. pos + size_t.sizeof];
    pos += size_t.sizeof;
    return value;
}

private ubyte readByte(const(ubyte)[] data, ref size_t pos) {
    if (pos + 1 > data.length)
        throw new Exception("truncated result stream");
    return data[pos++];
}

// An LLVMErrorRef is null on success; on failure it carries a message that
// LLVMGetErrorMessage consumes (frees), so the message must be copied first.
private void throwOnError(
    imported!"quickbite.backends.native.llvm_orc".LLVMErrorRef err,
    in string what,
) {
    import quickbite.backends.native.llvm_orc:
        LLVMDisposeErrorMessage,
        LLVMGetErrorMessage;
    import std.conv: text;
    import std.string: fromStringz;

    if (err is null)
        return;

    auto raw = LLVMGetErrorMessage(err);
    const message = raw is null ? "" : raw.fromStringz.idup;
    if (raw !is null)
        LLVMDisposeErrorMessage(raw);
    throw new Exception(text(what, " failed: ", message));
}

private __gshared uint _jitCounter;
private __gshared bool _nativeTargetInitialised;

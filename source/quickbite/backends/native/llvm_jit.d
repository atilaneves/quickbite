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
        in imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags =
            imported!"quickbite.frontend.compiler".FrontendFlags.init,
    ) {
        import quickbite.frontend.compiler: FrontendFlags;

        this(
            LLVMJitInputs(
                archiveImportPathsUnder(importPaths, packageRoot),
                sharedLibraries(linkFiles),
                staticLibraries(linkFiles),
                FrontendFlags(frontendFlags.compilerArguments.dup),
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
        return evalInChild(function_, _inputs);
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

// Eval has the same JIT-resident metadata lifetime as runTests, but the
// evaluator's public contract is one EvalResult rather than a TestResult
// array. Keep the LLJIT and all values reached from it inside this child.
private imported!"quickbite.backends.evaluator".EvalResult evalInChild(
    imported!"dmd.func".FuncDeclaration function_,
    in LLVMJitInputs inputs,
) {
    import core.stdc.errno: EINTR, errno;
    import core.stdc.stdio: fflush;
    import core.sys.posix.unistd: _exit, close, fork, pipe, read;
    import core.sys.posix.sys.wait:
        WEXITSTATUS, WIFEXITED, WIFSIGNALED, WTERMSIG, waitpid;
    import std.conv: text;

    fflush(null);

    int[2] fds;
    if (pipe(fds) != 0)
        throw new Exception("pipe() failed");

    const pid = fork();
    if (pid < 0)
        throw new Exception("fork() failed");

    if (pid == 0) {
        close(fds[0]);
        runEvalChildAndReport(fds[1], function_, inputs);
        close(fds[1]);
        _exit(0);
    }

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

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        const detail = WIFSIGNALED(status)
            ? text("signal ", WTERMSIG(status))
            : WIFEXITED(status)
                ? text("exit code ", WEXITSTATUS(status))
                : text("status ", status);
        throw new Exception(text("JIT child died (", detail, ")"));
    }

    return decodeEvalFrame(data);
}

private void runEvalChildAndReport(
    int fd,
    imported!"dmd.func".FuncDeclaration function_,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.evaluator: EvalResult;

    try {
        auto jit = jitForObjects([function_.getModule], inputs);
        writeEvalResult(fd, evalCompiledFunction(jit, function_));
    } catch (Throwable throwable) {
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
    public imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags =
        imported!"quickbite.frontend.compiler".FrontendFlags.init;
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

// Emit the objects (shared codegen path, child emits, no link) and hand them
// to the frontend-free ORC loader (orc.loader), which stands up an LLJIT with
// them all added to the main JITDylib, plus a process-symbol generator so
// druntime/phobos symbols resolve from the running bin/ut.
private imported!"orc.bindings".LLVMOrcLLJITRef jitForObjects(
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.native.codegen: CodegenInputs, emitObjectFilesForLink;
    import quickbite.frontend.compiler: FrontendFlags;
    import quickbite.frontend.compiler: withCompilerLock;
    import orc.loader: createJit;
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
    // The loader reads the objects into memory buffers before it returns, so
    // the files can go as soon as it has.
    scope(exit) rmdirRecurse(dir);

    string[] objPaths;
    withCompilerLock(() {
        objPaths = emitObjectFilesForLink(
            modules,
            dir,
            CodegenInputs(
                inputs.archiveImportPaths,
                FrontendFlags(inputs.frontendFlags.compilerArguments.dup),
            ),
        );
    });

    return createJit(objPaths, inputs.staticLibraries);
}

private imported!"quickbite.backends.runner".TestResult runUnitTest(
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import quickbite.backends.runner: TestResult;
    import orc.loader: runSymbol;
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    const run = runSymbol(jit, mangleExact(unitTest).fromStringz);

    return TestResult(
        run.passed,
        unitTest.ident.toChars.fromStringz.idup,
        unitTest.loc.toChars.fromStringz.idup,
        run.message,
    );
}

private imported!"quickbite.backends.evaluator".EvalResult evalCompiledFunction(
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.native.evaluator: callNativeFunction, evalNativeFunction;
    import orc.loader: symbolAddress;
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    auto address = symbolAddress(jit, mangleExact(function_).fromStringz);

    return evalNativeFunction(
        () => callNativeFunction(address, function_),
        function_,
    );
}

// The child -> parent result frame. The first byte is the kind: 1 means a
// results frame (a size_t count followed by that many [passed, name, location,
// message] records), 2 means an EvalResult, and 0 means an error frame (the
// rest of the stream is the message). Strings are length-prefixed with a
// size_t; both sides are the same process image, so native endianness needs no
// normalisation.
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

private void writeEvalResult(
    int fd,
    in imported!"quickbite.backends.evaluator".EvalResult result,
) {
    writeByte(fd, 2);
    writeByte(fd, result.failed ? 1 : 0);
    writeString(fd, result.display);
    writeString(fd, result.diagnostic);
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

private imported!"quickbite.backends.evaluator".EvalResult decodeEvalFrame(
    const(ubyte)[] data,
) {
    import quickbite.backends.evaluator: EvalResult;

    if (data.length == 0)
        throw new Exception("JIT child reported no results");

    const kind = data[0];
    auto rest = data[1 .. $];
    if (kind == 0)
        throw new Exception((cast(const(char)[]) rest).idup);
    if (kind != 2)
        throw new Exception("JIT child reported an unexpected frame");

    size_t pos = 0;
    const failed = readByte(rest, pos) != 0;
    const display = readString(rest, pos);
    const diagnostic = readString(rest, pos);
    return failed
        ? EvalResult(EvalResult.Diagnostic(diagnostic))
        : EvalResult(display);
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

private __gshared uint _jitCounter;

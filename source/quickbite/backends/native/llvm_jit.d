module quickbite.backends.native.llvm_jit;


private:


// A native backend that reuses SystemLinker's object production verbatim and
// replaces only the load step: instead of `dmd -shared` + dlopen, it links the
// same `.o` files in-process with LLVM's ORC JIT, killing the ~30 ms linker
// spawn. Object production is shared via native/codegen.d; this backend
// differs from SystemLinker only after the objects exist on disk.
public class LLVMJit: imported!"quickbite.backends.runner".GroupedRunner {
    import quickbite.backends.runner: TestResult;
    import dmd.dmodule: Module;

    private const LLVMJitInputs _inputs;

    public this(
        in LLVMJitInputs inputs = LLVMJitInputs.init,
    ) @safe @nogc nothrow pure {
        _inputs = inputs;
    }

    public override TestResult[] runTests(Module module_) {
        return runTests([module_]);
    }

    public override TestResult[] runTests(Module[] modules) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        auto jit = jitForObjects(modules, _inputs);
        scope(exit) disposeJit(jit);

        TestResult[] cases;
        foreach (module_; modules)
            foreachUnitTestDeclaration(module_, (unitTest) {
                cases ~= runUnitTest(jit, unitTest);
            });

        return cases;
    }
}

public struct LLVMJitInputs {
    // Modules under archive import paths are defined by prebuilt libraries and
    // must not be codegen'd again. Whether default imports are traversed for
    // template-instance codegen is derived from the modules themselves by the
    // shared codegen path, not from a caller flag. There is no `linkFiles`
    // field as SystemLinker has: ORC resolves druntime/phobos symbols from the
    // running process, and any archive symbols would have to be loaded into the
    // JIT separately (not POC scope).
    public const string[] archiveImportPaths;
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

    foreach (objPath; objPaths)
        addObjectFile(jit, dylib, objPath);

    return jit;
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
    import quickbite.backends.native.llvm_orc:
        LLVMCreateMemoryBufferWithContentsOfFile,
        LLVMMemoryBufferRef,
        LLVMOrcLLJITAddObjectFile;
    import std.conv: text;
    import std.string: fromStringz, toStringz;

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

private void disposeJit(
    imported!"quickbite.backends.native.llvm_orc".LLVMOrcLLJITRef jit,
) {
    import quickbite.backends.native.llvm_orc: LLVMOrcDisposeLLJIT;
    // Disposal returns an error of its own; ignore it on the cleanup path.
    cast(void) LLVMOrcDisposeLLJIT(jit);
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

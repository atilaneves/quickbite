module orc.loader;


// The frontend-free half of the LLVMJit backend: everything after the object
// files exist on disk — LLJIT creation, the process-symbol and static-library
// generators, per-object ELF duplicate-UND normalization + host-symbol
// interposition, object addition, lookup by mangled name, and execution.
// Inputs are plain data only (object file paths, archive paths, mangled
// symbol names) and no dmd.* import may appear anywhere under orc/: that is
// what lets the DMD-built bench-exec executor compile this package without
// the dmd frontend (ai/plans/llvm-jit.md, SystemLinker-peer parity plan).
// Codegen, unittest discovery/mangling and dependency-image dlopen stay with
// the caller.

private:


// Stand up an LLJIT with every object added to the main JITDylib, a
// process-symbol generator so druntime/phobos symbols resolve from the
// running host, and a search generator per static library. The objects are
// read into memory buffers before this returns, so the caller may delete the
// files as soon as it does.
public imported!"orc.bindings".LLVMOrcLLJITRef createJit(
    in string[] objectFiles,
    in string[] staticLibraries,
) {
    import orc.bindings:
        LLVMOrcCreateLLJIT,
        LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess,
        LLVMOrcDefinitionGeneratorRef,
        LLVMOrcJITDylibAddGenerator,
        LLVMOrcLLJITGetGlobalPrefix,
        LLVMOrcLLJITGetMainJITDylib,
        LLVMOrcLLJITRef;

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

    foreach (staticLibrary; staticLibraries)
        addStaticLibraryGenerator(jit, dylib, staticLibrary);

    foreach (objectFile; objectFiles)
        addObjectFile(jit, dylib, objectFile);

    return jit;
}

// Plain-data result of running a JIT'd symbol; the caller attaches display
// name and location, which are frontend concepts.
public struct RunResult {
    public bool passed;
    public string message;
}

public RunResult runSymbol(
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    in char[] mangledName,
) {
    auto test = cast(void function()) symbolAddress(jit, mangledName);

    auto result = RunResult(true, "");

    try
        test();
    catch (Throwable throwable) { // assert failures are Errors, not Exceptions
        result.passed = false;
        result.message = throwable.msg.idup;
    }

    return result;
}

// On Linux x86-64 ELF the global prefix is empty, so the lookup name is the
// dmd mangled name as-is, exactly what SystemLinker passes to dlsym.
public void* symbolAddress(
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    in char[] mangledName,
) {
    import orc.bindings: LLVMOrcExecutorAddress, LLVMOrcLLJITLookup;
    import std.string: toStringz;

    LLVMOrcExecutorAddress address;
    throwOnError(
        LLVMOrcLLJITLookup(jit, &address, mangledName.toStringz),
        "lookup of " ~ mangledName.idup,
    );

    return cast(void*) address;
}

private void addStaticLibraryGenerator(
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    imported!"orc.bindings".LLVMOrcJITDylibRef dylib,
    in string staticLibrary,
) {
    import orc.bindings:
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
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    imported!"orc.bindings".LLVMOrcJITDylibRef dylib,
    imported!"orc.bindings".LLVMMemoryBufferRef buffer,
) {
    import orc.bindings:
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
            // the host process, i.e. libphobos2.so and friends; a hit is the
            // host's definitive copy of this symbol.
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
    import orc.bindings:
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
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    imported!"orc.bindings".LLVMOrcJITDylibRef dylib,
    in string objPath,
) {
    import orc.bindings:
        LLVMCreateMemoryBufferWithContentsOfFile,
        LLVMMemoryBufferRef,
        LLVMOrcLLJITAddObjectFile;
    import orc.elf: normalizeObjectFile;
    import std.conv: text;
    import std.string: fromStringz, toStringz;

    normalizeObjectFile(objPath);

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

// An LLVMErrorRef is null on success; on failure it carries a message that
// LLVMGetErrorMessage consumes (frees), so the message must be copied first.
private void throwOnError(
    imported!"orc.bindings".LLVMErrorRef err,
    in string what,
) {
    import orc.bindings:
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

private __gshared bool _nativeTargetInitialised;

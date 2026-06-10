module quickbite.backends.native.dynamic;


private:


public class DynamicLibrary: imported!"quickbite.backends.runner".Runner {
    import quickbite.backends.runner: TestResult;
    import dmd.dmodule: Module;

    public override TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;
        import core.runtime: Runtime;

        auto library = compileToSharedLibrary(module_);
        // The results copy everything they need out of the library, so it can
        // be unloaded as soon as the tests have run.
        scope(exit) Runtime.unloadLibrary(library);

        TestResult[] cases;
        foreachUnitTestDeclaration(module_, (unitTest) {
            cases ~= runUnitTest(library, unitTest);
        });

        return cases;
    }
}

private void* compileToSharedLibrary(imported!"dmd.dmodule".Module module_) {
    import quickbite.frontend.compiler: withCompilerLock;
    import core.atomic: atomicFetchAdd;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;

    // Unique paths per call: dlopen caches by path, so reusing one would
    // return a previously loaded library instead of the new code.
    const index = atomicFetchAdd(_libraryCounter, 1u);
    const dir = buildPath(tempDir, text("quickbite_native_", index));
    mkdirRecurse(dir);
    // The loader keeps the library mapped after Runtime.loadLibrary, so the
    // files can go as soon as it is loaded.
    scope(exit) rmdirRecurse(dir);
    const objPath = buildPath(dir, "module.o");
    const libPath = buildPath(dir, "module.so");

    withCompilerLock(() {
        emitObjectFile(module_, objPath);
    });
    linkSharedLibrary(objPath, libPath);

    return loadSharedLibrary(libPath);
}

private void emitObjectFile(
    imported!"dmd.dmodule".Module module_,
    in string objPath,
) {
    import dmd.glue: generateCodeAndWrite;
    import dmd.globals: global;
    import dmd.root.filename: FileName;

    initialiseBackend;

    module_.objfile = FileName(objPath);

    const oldAllInst = global.params.allInst;
    scope(exit) global.params.allInst = oldAllInst;
    // Emit all template instances (notably `_d_assert_fail`) into this object
    // so the shared library does not rely on other objects providing them.
    global.params.allInst = true;

    enum noLibModules = (const(char)*[]).init;
    enum noLibName = "";
    enum currentDirectory = "";
    enum doNotWriteLibrary = false;
    enum writeObjectFile = true;
    enum oneObjectFile = true;
    enum doNotSplitObject = false;
    enum doNotPrintProgress = false;

    generateCodeAndWrite(
        [module_],
        noLibModules,
        noLibName,
        currentDirectory,
        doNotWriteLibrary,
        writeObjectFile,
        oneObjectFile,
        doNotSplitObject,
        doNotPrintProgress,
    );
    if (global.errors != 0)
        throw new Exception("codegen failed: " ~ objPath);
}

private void initialiseBackend() {
    import dmd.dmdparams: DMDparams, PIC;
    import dmd.dmsc: backend_init;
    import dmd.glue: ObjcGlue_initialize;
    import dmd.globals: global;
    import dmd.target: target;

    if (_backendInitialised)
        return;
    _backendInitialised = true;

    DMDparams driverParams;
    // Shared libraries need position independent code.
    driverParams.pic = PIC.pic;
    backend_init(global.params, driverParams, target);
    ObjcGlue_initialize;
}

private void linkSharedLibrary(in string objPath, in string libPath) {
    import std.conv: text;
    import std.process: execute;

    // Link against shared phobos so the library shares the host's druntime
    // (one GC, one DSO registry) instead of smuggling in its own copy.
    // `-z defs` turns any symbol the generated code fails to provide into a
    // link error instead of a load-time failure.
    const result = execute([
        "dmd",
        "-shared",
        "-defaultlib=libphobos2.so",
        "-L=-z",
        "-L=defs",
        "-of=" ~ libPath,
        objPath,
    ]);
    if (result.status != 0)
        throw new Exception(text("link failed: ", result.output));
}

private void* loadSharedLibrary(in string libPath) {
    import core.runtime: Runtime;

    // Runtime.loadLibrary registers the library with druntime (module
    // constructors, GC ranges, unloadable later). It requires the host to
    // link druntime as a shared library.
    auto handle = Runtime.loadLibrary(libPath);
    if (handle is null)
        throw new Exception("failed to load shared library: " ~ libPath);

    return handle;
}

private imported!"quickbite.backends.runner".TestResult runUnitTest(
    void* library,
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import quickbite.backends.runner: TestResult;
    import core.sys.posix.dlfcn: dlsym;
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    auto test = cast(void function()) dlsym(library, mangleExact(unitTest));
    if (test is null)
        throw new Exception("unittest symbol not found in shared library");

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

private __gshared uint _libraryCounter;
// Only accessed from initialiseBackend, which only runs under the compiler
// lock (emitObjectFile is always called inside withCompilerLock).
private __gshared bool _backendInitialised;

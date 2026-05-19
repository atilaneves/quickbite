module quickbite.backends.dmd_backend;

// Pull dmd.lib into the link before the frontend library so the linker can
// resolve the Library.factory and Library.setFilename references that
// dmd.glue.generateCodeAndWrite makes when writeLibrary=true.  We always
// pass writeLibrary=false, so these paths are unreachable at runtime, but
// the symbols must be present for static linking.
import dmd.lib: Library;

private:

__gshared bool _backendInit;
__gshared uint _tempCounter;

public final class DmdBackend : imported!"quickbite.executor".Executor {
    private string[] linkFiles;

    public this(in string[] linkFiles = []) {
        this.linkFiles = linkFiles.dup;
    }

    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;
        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;
        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override void runParsedTests(imported!"dmd.dmodule".Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        bool hasTests;
        foreachUnitTestDeclaration(module_, (_) { hasTests = true; });
        if (!hasTests)
            return;

        compileAndRun(module_, linkFiles);
    }

    public imported!"quickbite.executor".TestSummary runTestSummary(in string source) {
        import quickbite.executor: TestSummary;
        import quickbite.frontend.compiler: parseModule;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        auto module_ = parseModule(source).module_;
        TestSummary summary;

        // Count total tests
        foreachUnitTestDeclaration(module_, (_) { ++summary.total; });

        if (summary.total == 0)
            return summary;

        try {
            compileAndRun(module_, linkFiles);
            summary.passed = summary.total;
        } catch (Exception) {
            summary.failed = 1;
            summary.passed = summary.total - 1;
        }

        return summary;
    }
}

private void compileAndRun(
    imported!"dmd.dmodule".Module module_,
    in string[] linkFiles,
) @trusted {
    import core.atomic: atomicFetchAdd;
    import quickbite.frontend.compiler: withCompilerLock;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;

    const idx = atomicFetchAdd(_tempCounter, 1u);
    const tmpDir = buildPath(tempDir, text("quickbite_dmd_", idx));
    mkdirRecurse(tmpDir);
    scope(exit) rmdirRecurse(tmpDir);

    const objPath = buildPath(tmpDir, "module.o");
    const soPath  = buildPath(tmpDir, "module.so");

    withCompilerLock(() {
        ensureBackendInit;
        generateObj(module_, objPath);
    });

    link(objPath, soPath, linkFiles);
    loadAndRunTests(soPath, module_);
}

private void ensureBackendInit() @trusted {
    import dmd.dmsc: backend_init;
    import dmd.dmdparams: DMDparams, PIC;
    import dmd.glue: ObjcGlue_initialize;
    import dmd.globals: global;
    import dmd.target: target;

    if (_backendInit)
        return;

    DMDparams driverParams;
    driverParams.pic = PIC.pic;
    backend_init(global.params, driverParams, target);
    ObjcGlue_initialize;
    _backendInit = true;
}

private void generateObj(
    imported!"dmd.dmodule".Module module_,
    in string objPath,
) @trusted {
    import dmd.glue: generateCodeAndWrite;
    import dmd.root.filename: FileName;

    module_.objfile = FileName(objPath);
    generateCodeAndWrite([module_], [], "", "", false, true, false, false, false);
}

private void link(in string objPath, in string soPath, in string[] linkFiles) {
    import std.process: execute;
    import std.conv: text;

    auto command = [
        "dmd", "-shared", "-fPIC",
    ];
    version (QuickbiteRuntimeLoadLibrary) {
        command ~= "-defaultlib=libphobos2.so";
        command ~= ["-L=-z", "-L=defs"];
    }
    command ~= [
        "-of=" ~ soPath,
        objPath,
    ];
    command ~= linkFiles;

    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text("dmd link failed: ", result.output));
}

private void loadAndRunTests(
    in string soPath,
    imported!"dmd.dmodule".Module module_,
) @trusted {
    import core.sys.posix.dlfcn: dlerror, dlsym;
    import std.conv: text;
    import std.string: fromStringz, toStringz;

    void* handle;
    version (QuickbiteRuntimeLoadLibrary) {
        import core.runtime: Runtime;

        handle = Runtime.loadLibrary(soPath);
    } else {
        import core.sys.posix.dlfcn: dlclose, dlopen, RTLD_GLOBAL, RTLD_NOW;

        handle = dlopen(soPath.toStringz, RTLD_NOW | RTLD_GLOBAL);
        scope(exit) if (handle) dlclose(handle);
    }
    if (!handle)
        throw new Exception(text("dlopen failed: ", dlerror.fromStringz));

    const modtestSym = modtestSymbol(module_);
    auto fn = cast(void function()) dlsym(handle, modtestSym.toStringz);
    if (fn) {
        bool unittestRunnerThrowableCaught;
        try {
            fn();
        } catch (Throwable) {
            // DMD's generated __modtest runner can throw from any unittest
            // failure: druntime turns failed asserts into AssertError, and
            // user code can throw directly from the unittest body.
            unittestRunnerThrowableCaught = true;
        }
        throwIfUnittestRunnerThrowableCaught(unittestRunnerThrowableCaught);
    }
}

private void throwIfUnittestRunnerThrowableCaught(
    in bool unittestRunnerThrowableCaught,
) {
    if (!unittestRunnerThrowableCaught)
        return;

    throw new Exception("Unittest assertion failed.");
}

private string modtestSymbol(
    imported!"dmd.dmodule".Module module_,
) @trusted {
    import core.demangle: mangleFunc;
    import std.conv: text;
    import std.exception: assumeUnique;
    import std.string: fromStringz;

    const modtestName = text(module_.toPrettyChars.fromStringz, ".__modtest");
    return mangleFunc!(void function())(modtestName).assumeUnique;
}

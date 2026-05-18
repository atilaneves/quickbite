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
__gshared string _unittestFailureMessage;
__gshared string _unittestFailureFile;
__gshared uint _unittestFailureLine;

public final class DmdBackend : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;
        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;
        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override void runParsedTests(imported!"dmd.dmodule".Module module_) {
        import quickbite.dmd_util: foreachUnitTestDeclaration;

        bool hasTests;
        foreachUnitTestDeclaration(module_, (_) { hasTests = true; });
        if (!hasTests)
            return;

        compileAndRun(module_);
    }

    public imported!"quickbite.executor".TestSummary runTestSummary(in string source) {
        import quickbite.executor: TestSummary;
        import quickbite.frontend.compiler: parseModule;
        import quickbite.dmd_util: foreachUnitTestDeclaration;

        auto module_ = parseModule(source).module_;
        TestSummary summary;

        // Count total tests
        foreachUnitTestDeclaration(module_, (_) { ++summary.total; });

        if (summary.total == 0)
            return summary;

        try {
            compileAndRun(module_);
            summary.passed = summary.total;
        } catch (Exception) {
            summary.failed = 1;
            summary.passed = summary.total - 1;
        }

        return summary;
    }
}

private void compileAndRun(imported!"dmd.dmodule".Module module_) @trusted {
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

    link(objPath, soPath);
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

private void link(in string objPath, in string soPath) {
    import std.process: execute;
    import std.conv: text;

    const result = execute([
        "dmd", "-shared", "-fPIC",
        "-of=" ~ soPath,
        objPath,
    ]);
    if (result.status != 0)
        throw new Exception(text("dmd link failed: ", result.output));
}

extern(C) void _d_unittest_msg(string msg, string file, uint line) {
    if (_unittestFailureMessage !is null)
        return;

    _unittestFailureMessage = msg.idup;
    _unittestFailureFile = file.idup;
    _unittestFailureLine = line;
}

extern(C) void _d_unittestp(string file, uint line) {
    if (_unittestFailureMessage !is null)
        return;

    _unittestFailureMessage = "Unittest assertion failed.";
    _unittestFailureFile = file;
    _unittestFailureLine = line;
}

private void loadAndRunTests(
    in string soPath,
    imported!"dmd.dmodule".Module module_,
) @trusted {
    import core.sys.posix.dlfcn: dlclose, dlerror, dlopen, dlsym, RTLD_GLOBAL, RTLD_NOW;
    import std.conv: text;
    import std.string: fromStringz;

    const soPathZ = soPath ~ "\0";
    auto handle = dlopen(soPathZ.ptr, RTLD_NOW | RTLD_GLOBAL);
    if (!handle)
        throw new Exception(text("dlopen failed: ", dlerror.fromStringz));
    scope(exit) dlclose(handle);

    const modtestSym = modtestSymbol(module_);
    const modtestZ   = modtestSym ~ "\0";
    auto fn = cast(void function()) dlsym(handle, modtestZ.ptr);
    if (fn) {
        clearUnittestFailure;
        scope(exit) clearUnittestFailure;
        GeneratedThrowable generatedThrowable;
        try {
            fn();
        } catch (Throwable throwable) {
            generatedThrowable = copyGeneratedThrowable(throwable);
        }
        throwPendingUnittestFailure;
        throwPendingGeneratedThrowable(generatedThrowable);
    }
}

private struct GeneratedThrowable {
    public string type;
    public string message;
}

private GeneratedThrowable copyGeneratedThrowable(Throwable throwable) {
    return GeneratedThrowable(
        throwable.classinfo.name.idup,
        throwable.msg.idup,
    );
}

private void throwPendingGeneratedThrowable(in GeneratedThrowable throwable) {
    if (throwable.type is null)
        return;

    throw new Exception("Unittest assertion failed.");
}

private void throwPendingUnittestFailure() {
    if (_unittestFailureMessage is null)
        return;

    throw new Exception(_unittestFailureMessage);
}

private void clearUnittestFailure() nothrow @nogc {
    _unittestFailureMessage = null;
    _unittestFailureFile = null;
    _unittestFailureLine = 0;
}

private string modtestSymbol(
    imported!"dmd.dmodule".Module module_,
) @trusted {
    import dmd.common.outbuffer: OutBuffer;
    import dmd.mangle: mangleToBuffer;
    import std.conv: text;

    OutBuffer moduleMangle;
    mangleToBuffer(module_, moduleMangle);
    return text("_D", moduleMangle.extractSlice, "9__modtestFZv");
}

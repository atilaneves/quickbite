module quickbite.backends.native.system_linker;


private:


public class SystemLinker:
    imported!"quickbite.backends".Backend,
    imported!"quickbite.backends.runner".GroupedRunner,
    imported!"quickbite.backends.runner".CompileTimeReporter
{
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.backends.runner: TestResult;
    import core.time: Duration, MonoTime;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    private const SystemLinkerInputs _inputs;
    private Duration _compileTime;

    public alias eval = Evaluator.eval;

    public this(
        in SystemLinkerInputs inputs = SystemLinkerInputs.init,
    ) @safe @nogc nothrow pure {
        _inputs = inputs;
    }

    public this(
        const string[] dependencyImages,
        const string[] dependencyImportPaths,
    ) @safe @nogc nothrow pure {
        this(
            SystemLinkerInputs(dependencyImages, dependencyImportPaths),
        );
    }

    public override Duration compileTime() @safe @nogc nothrow pure const scope {
        return _compileTime;
    }

    public override void resetCompileTime() @safe @nogc nothrow pure scope {
        _compileTime = Duration.zero;
    }

    // Derives the dependency import paths from the raw dub import paths and the
    // package root: the driver forwards what dub reported and lets the backend
    // decide what is already compiled into the dependency image. The filtering uses
    // std.path/std.algorithm, so this constructor cannot be @nogc nothrow pure
    // like its siblings.
    public this(
        const string[] dependencyImages,
        const string[] importPaths,
        in string packageRoot,
        in imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags =
            imported!"quickbite.frontend.compiler".FrontendFlags.init,
        in DubPackage dubPackage = DubPackage.no,
    ) @safe {
        import quickbite.frontend.compiler: FrontendFlags;
        import quickbite.backends.native.link_files: dependencyImportPathsOutside;

        this(
            SystemLinkerInputs(
                dependencyImages,
                dependencyImportPathsOutside(importPaths, packageRoot),
                FrontendFlags(frontendFlags.compilerArguments.dup),
                dubPackage,
                packageRoot,
            ),
        );
    }

    public override TestResult[] runTests(Module module_) {
        return runTests([module_]);
    }

    public override TestResult[] runTests(Module[] modules) {
        // An LDC-built host cannot run DMD-codegen'd unittests in-process (the
        // extern(D) ABI and DMD-only EH symbols diverge, ai/spikes/ldc-eh/
        // FINDINGS.md), so hand the linked .so to the DMD-built run executor
        // across a process boundary instead. DMD-built hosts (bin/ut, the DMD
        // benchmark build) keep running the tests in-process, unchanged.
        version (LDC)
            return runTestsViaExecutor(modules, _inputs, _compileTime);
        else
            return runTestsInProcess(modules);
    }

    private TestResult[] runTestsInProcess(Module[] modules) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;
        import core.runtime: Runtime;

        const start = MonoTime.currTime;
        auto library = compileToSharedLibrary(
            modules,
            _inputs,
        );
        _compileTime += MonoTime.currTime - start;
        // The results copy everything they need out of the library, so it can
        // be unloaded as soon as the tests have run. Dead objects of classes
        // the fixture defines still sit in the GC heap with vptrs into this
        // library, though; collect them while it is still mapped, or any
        // later finalizer sweep dereferences unmapped memory.
        scope(exit) {
            import core.memory: GC;
            GC.collect;
            Runtime.unloadLibrary(library);
        }

        TestResult[] cases;
        foreach (module_; modules)
            foreachUnitTestDeclaration(module_, (unitTest) {
                cases ~= runUnitTest(library, unitTest);
            });

        return cases;
    }

    public override EvalResult eval(FuncDeclaration function_) {
        import core.runtime: Runtime;

        // eval runs the compiled function in-process; the LDC host cannot. It
        // is never reached on the LDC benchmark path (only runTests is), so
        // guard rather than route it through the executor.
        version (LDC)
            throw new Exception("SystemLinker.eval is unavailable under the LDC build");

        auto library = compileToSharedLibrary(
            [function_.getModule],
            _inputs,
        );
        scope(exit) {
            import core.memory: GC;
            GC.collect;
            Runtime.unloadLibrary(library);
        }

        return evalCompiledFunction(library, function_);
    }
}

public alias DubPackage = imported!"std.typecons".Flag!"dubPackage";

public struct SystemLinkerInputs {
    // Dependency images are appended to every hot project link. Modules under
    // dependency import paths are defined by those images and must not be
    // codegen'd again.
    public const string[] dependencyImages;
    public const string[] dependencyImportPaths;
    public imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags =
        imported!"quickbite.frontend.compiler".FrontendFlags.init;
    // Yes.dubPackage codegens the modules as a dub package's own root set
    // (`dmd -unittest <files>`): no lightning rod, no dependency-image-gated emission,
    // no member pruning -- that apparatus is for the single-snippet path. See
    // emitObjectFilesForDubPackage.
    public DubPackage dubPackage;
    // The executor mirrors `dub test`, including its package-root working
    // directory. Empty for standalone fixtures, which inherit the host cwd.
    public string workingDirectory;
}

// A codegen'd-and-linked shared library on disk. The caller owns dir, deleting
// it once the library is loaded (the loader keeps it mapped) or the executor
// has run against it.
private struct BuiltLibrary {
    string dir;
    string libPath;
}

private BuiltLibrary buildSharedLibrary(
    imported!"dmd.dmodule".Module[] modules,
    in SystemLinkerInputs inputs,
) {
    import quickbite.backends.native.codegen:
        CodegenInputs, emitObjectFilesForBackend;
    import quickbite.frontend.compiler: withCompilerLock;
    import quickbite.frontend.compiler: FrontendFlags;
    import core.atomic: atomicFetchAdd;
    import std.conv: text;
    import std.file: mkdirRecurse, tempDir;
    import std.path: buildPath;

    // Unique paths per call: dlopen caches by path, so reusing one would
    // return a previously loaded library instead of the new code. The pid
    // keeps paths unique across processes too: a crashed run leaks its
    // directories, and a later run reusing the path could load the stale
    // library if its own link step failed.
    import core.sys.posix.unistd: getpid;
    const index = atomicFetchAdd(_libraryCounter, 1u);
    const dir = buildPath(tempDir, text("quickbite_native_", getpid, "_", index));
    mkdirRecurse(dir);
    const libPath = buildPath(dir, "module.so");

    string[] objPaths;
    withCompilerLock(() {
        auto codegenInputs = CodegenInputs(
            inputs.dependencyImportPaths,
            FrontendFlags(inputs.frontendFlags.compilerArguments.dup),
            inputs.dubPackage == DubPackage.yes,
        );
        objPaths = emitObjectFilesForBackend(modules, dir, codegenInputs);
    });
    linkSharedLibrary(objPaths, libPath, inputs.dependencyImages);

    return BuiltLibrary(dir, libPath);
}

private void* compileToSharedLibrary(
    imported!"dmd.dmodule".Module[] modules,
    in SystemLinkerInputs inputs,
) {
    import std.file: rmdirRecurse;

    auto built = buildSharedLibrary(modules, inputs);
    // The loader keeps the library mapped after Runtime.loadLibrary, so the
    // files can go as soon as it is loaded.
    scope(exit) rmdirRecurse(built.dir);
    return loadSharedLibrary(built.libPath);
}

// The LDC host path: codegen+link in this (LDC) process, then run the linked
// .so in the DMD-built bench-exec subprocess so the generated code meets a
// matching DMD druntime. Only compiled under an LDC host; DMD hosts run tests
// in-process via runTestsInProcess.
version (LDC)
private imported!"quickbite.backends.runner".TestResult[] runTestsViaExecutor(
    imported!"dmd.dmodule".Module[] modules,
    in SystemLinkerInputs inputs,
    ref imported!"core.time".Duration compileTime,
) {
    import core.time: MonoTime;
    import quickbite.backends.runner: TestResult;
    import quickbite.frontend.util: foreachUnitTestDeclaration;
    import run_wire:
        RunKind, RunRequest, UnitTestSymbol, encodeRequest, decodeResults;
    import dmd.mangle: mangleExact;
    import std.file: read, rmdirRecurse, write;
    import std.path: buildPath;
    import std.string: fromStringz;

    const start = MonoTime.currTime;
    auto built = buildSharedLibrary(modules, inputs);
    compileTime += MonoTime.currTime - start;
    scope(exit) rmdirRecurse(built.dir);

    UnitTestSymbol[] symbols;
    foreach (module_; modules)
        foreachUnitTestDeclaration(module_, (unitTest) {
            symbols ~= UnitTestSymbol(
                mangleExact(unitTest).fromStringz.idup,
                unitTest.ident.toChars.fromStringz.idup,
                unitTest.loc.toChars.fromStringz.idup,
            );
        });

    const requestFile = buildPath(built.dir, "request.bin");
    const resultsFile = buildPath(built.dir, "results.bin");
    write(requestFile, encodeRequest(RunRequest(
        RunKind.sharedLibrary,
        built.libPath,
        inputs.dependencyImages.dup,
        [],
        symbols,
    )));

    import quickbite.backends.native.run_executor:
        RunExecutorConfig, runExecutor;
    runExecutor(
        requestFile,
        resultsFile,
        RunExecutorConfig(inputs.workingDirectory),
    );

    TestResult[] cases;
    foreach (result; decodeResults(cast(ubyte[]) read(resultsFile)))
        cases ~= TestResult(result.passed, result.name, result.location, result.message);
    return cases;
}

private void linkSharedLibrary(
    in string[] objPaths,
    in string libPath,
    in string[] dependencyImages,
) {
    import quickbite.ffi.ffi: verifyDependencyImages;
    import std.conv: text;
    import std.process: execute;

    // Link against shared phobos so the library shares the host's druntime
    // (one GC, one DSO registry) instead of smuggling in its own copy.
    //
    // `-z defs` turns any symbol the generated code fails to provide into a
    // link error instead of a load-time failure. Dependency images are the
    // exception: a module may reference a symbol supplied by a DT_NEEDED
    // dependency of the explicitly-linked image, and the dynamic loader
    // resolves that closure at load time.
    verifyDependencyImages(dependencyImages);
    auto command = [ // const fails: appended to below
        "dmd",
        "-shared",
        "-defaultlib=libphobos2.so",
        "-of=" ~ libPath,
    ];
    if (dependencyImages.length == 0)
        command ~= ["-L=-z", "-L=defs"];

    command ~= objPaths;
    command ~= dependencyImages;
    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text("link failed: ", result.output));
}

private void* loadSharedLibrary(in string libPath) {
    import core.runtime: Runtime;

    // Runtime.loadLibrary registers the library with druntime (module
    // constructors, GC ranges, unloadable later). It requires the host to
    // link druntime as a shared library.
    auto handle = Runtime.loadLibrary(libPath);
    if (handle is null) {
        import core.sys.posix.dlfcn: dlerror;
        import std.string: fromStringz;
        auto err = dlerror();
        throw new Exception("failed to load shared library: " ~ libPath
            ~ (err is null ? "" : " :: " ~ err.fromStringz.idup));
    }

    return handle;
}

private imported!"quickbite.backends.runner".TestResult runUnitTest(
    void* library,
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import quickbite.backends.runner: TestResult;
    import core.sys.posix.dlfcn: dlsym;
    import dmd.mangle: mangleExact;
    import std.conv: text;
    import std.string: fromStringz;

    auto test = cast(void function()) dlsym(library, mangleExact(unitTest));
    if (test is null)
        throw new Exception(text(
            "unittest symbol not found in shared library: ",
            mangleExact(unitTest).fromStringz,
        ));

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
    void* library,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.native.evaluator: callNativeFunction, evalNativeFunction;
    import core.sys.posix.dlfcn: dlsym;
    import dmd.mangle: mangleExact;
    import std.conv: text;
    import std.string: fromStringz;

    auto symbol = dlsym(library, mangleExact(function_));
    if (symbol is null)
        throw new Exception(text(
            "eval symbol not found in shared library: ",
            mangleExact(function_).fromStringz,
        ));

    return evalNativeFunction(
        () => callNativeFunction(symbol, function_),
        function_,
    );
}

private __gshared uint _libraryCounter;

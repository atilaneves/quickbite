module quickbite.backends.native.system_linker;


private:


public class SystemLinker:
    imported!"quickbite.backends".Backend,
    imported!"quickbite.backends.runner".GroupedRunner
{
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.backends.runner: TestResult;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    private const SystemLinkerInputs _inputs;

    public alias eval = Evaluator.eval;

    public this(
        in SystemLinkerInputs inputs = SystemLinkerInputs.init,
    ) @safe @nogc nothrow pure {
        _inputs = inputs;
    }

    public this(
        const string[] linkFiles,
        const string[] archiveImportPaths,
    ) @safe @nogc nothrow pure {
        this(
            SystemLinkerInputs(linkFiles, archiveImportPaths),
        );
    }

    // Derives the archive import paths from the raw dub import paths and the
    // package root: the driver forwards what dub reported and lets the backend
    // decide what is already compiled into the archives. The filtering uses
    // std.path/std.algorithm, so this constructor cannot be @nogc nothrow pure
    // like its siblings.
    public this(
        const string[] linkFiles,
        const string[] importPaths,
        in string packageRoot,
    ) @safe {
        this(
            SystemLinkerInputs(
                linkFiles,
                archiveImportPathsUnder(importPaths, packageRoot),
            ),
        );
    }

    public override TestResult[] runTests(Module module_) {
        return runTests([module_]);
    }

    public override TestResult[] runTests(Module[] modules) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;
        import core.runtime: Runtime;

        auto library = compileToSharedLibrary(
            modules,
            _inputs,
        );
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

public struct SystemLinkerInputs {
    // Link files are prebuilt libraries appended to every link. Modules under
    // archive import paths are defined by those libraries and must not be
    // codegen'd again.
    public const string[] linkFiles;
    public const string[] archiveImportPaths;
}

// import paths under the package belong to the project under test and are
// compiled fresh per run; the rest belong to dependencies, whose objects
// come from the dub-built archives in linkFiles.
private string[] archiveImportPathsUnder(in string[] importPaths, in string packageRoot) @safe {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.searching: startsWith;
    import std.array: array;
    import std.path: absolutePath, buildNormalizedPath, dirSeparator;

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

private void* compileToSharedLibrary(
    imported!"dmd.dmodule".Module[] modules,
    in SystemLinkerInputs inputs,
) {
    import quickbite.backends.native.codegen: CodegenInputs, emitObjectFilesForLink;
    import quickbite.frontend.compiler: withCompilerLock;
    import core.atomic: atomicFetchAdd;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
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
    // The loader keeps the library mapped after Runtime.loadLibrary, so the
    // files can go as soon as it is loaded.
    scope(exit) rmdirRecurse(dir);
    const libPath = buildPath(dir, "module.so");

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
    linkSharedLibrary(objPaths, libPath, inputs.linkFiles);

    return loadSharedLibrary(libPath);
}

private void linkSharedLibrary(
    in string[] objPaths,
    in string libPath,
    in string[] linkFiles,
) {
    import std.conv: text;
    import std.process: execute;

    // Link against shared phobos so the library shares the host's druntime
    // (one GC, one DSO registry) instead of smuggling in its own copy.
    // `-z defs` turns any symbol the generated code fails to provide into a
    // link error instead of a load-time failure.
    auto command = [ // const fails: appended to below
        "dmd",
        "-shared",
        "-defaultlib=libphobos2.so",
        "-L=-z",
        "-L=defs",
        "-of=" ~ libPath,
    ] ~ objPaths;
    if (linkFiles.length != 0 && allSharedLibraries(linkFiles)) {
        command ~= linkFiles;
    } else if (linkFiles.length != 0) {
        // Group-wrap archive lists: references between archives can go in
        // either direction, and the group makes the linker rescan to fixpoint.
        command ~= "-L=--start-group" ~ linkFiles ~ "-L=--end-group";
    }
    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text("link failed: ", result.output));
}

private bool allSharedLibraries(in string[] linkFiles) @safe pure {
    foreach (linkFile; linkFiles)
        if (!linkFile.isSharedLibraryPath)
            return false;
    return true;
}

private bool isSharedLibraryPath(in string linkFile) @safe pure {
    import std.string: endsWith;

    return linkFile.endsWith(".so");
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

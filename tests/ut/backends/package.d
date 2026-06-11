module ut.backends;


public import ut;
public import quickbite.backends.runner: ExecutionMode, TestResult;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;
public import quickbite.backends.interpreter;
public import quickbite.backends.bytecode;
public import quickbite.backends.ir;
public import quickbite.backends.native;
public import std.meta: AliasSeq;


auto newBackend(T)(in ExecutionMode mode = ExecutionMode.runtime) {
    return new T(mode);
}

public void runBackendSourceFixtureTests(T)(
    in string moduleSource,
    in ExecutionMode mode = ExecutionMode.runtime,
) {
    runBackendSourceFixtureTests!T(moduleSource, [], mode);
}

public void runBackendSourceFixtureTests(T)(
    in string moduleSource,
    in string[] importPaths,
    in ExecutionMode mode = ExecutionMode.runtime,
) {
    runBackendSourceFixtureTestResults!T(moduleSource, importPaths, mode)
        .throwOnTestFailure;
}

public TestResult[] runBackendSourceFixtureTestResults(T)(
    in string moduleSource,
    in ExecutionMode mode = ExecutionMode.runtime,
) {
    return runBackendSourceFixtureTestResults!T(moduleSource, [], mode);
}

public TestResult[] runBackendSourceFixtureTestResults(T)(
    in string moduleSource,
    in string[] importPaths,
    in ExecutionMode mode = ExecutionMode.runtime,
) {
    import quickbite.frontend.compiler:
        parseModuleWithCheckActionContext,
        parseModuleWithCheckActionContextUncached;

    // SystemLinker compiles the module to an object file, so it must get a
    // fresh parse: a cached module accumulates other compilations' speculative
    // template instances and TypeInfos (DMD appends them to root modules via
    // importedFrom), which codegen would then emit as dangling references.
    static if (is(T == SystemLinker))
        alias parse = parseModuleWithCheckActionContextUncached;
    else
        alias parse = parseModuleWithCheckActionContext;

    auto moduleResult = parse(moduleSource, importPaths);
    auto backend = newBackend!T(mode);
    return backend.runTests(moduleResult.module_);
}

public void runBackendFileFixtureTests(T)(
    in string filePath,
    in string[] importPaths,
    in ExecutionMode mode = ExecutionMode.runtime,
) {
    runBackendFileFixtureTestResults!T(filePath, importPaths, mode)
        .throwOnTestFailure;
}

public TestResult[]
runBackendFileFixtureTestResults(T)(
    in string filePath,
    in string[] importPaths,
    in ExecutionMode mode = ExecutionMode.runtime,
) {
    import quickbite.frontend.compiler: parseModuleFileWithCheckActionContext;

    auto moduleResult = parseModuleFileWithCheckActionContext(
        filePath,
        importPaths,
    );
    auto backend = newBackend!T(mode);
    return backend.runTests(moduleResult.module_);
}

private void throwOnTestFailure(in TestResult[] results) {
    foreach (result; results)
        if (!result.passed)
            throw new Exception(result.message);
}

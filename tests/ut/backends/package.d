module ut.backends;


public import ut;
public import quickbite.backends.runner: TestResult;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;
public import quickbite.backends.interpreter;
public import quickbite.backends.bytecode;
public import quickbite.backends.ir;
public import quickbite.backends.native;


alias backends = imported!"std.meta".AliasSeq!(
    Ctfe,
);

alias backendsWith(Extra...) = imported!"std.meta".AliasSeq!(
    backends,
    Extra,
);


auto newBackend(T)() {
    return new T;
}

public void runBackendSourceFixtureTests(T)(in string moduleSource) {
    runBackendSourceFixtureTests!T(moduleSource, []);
}

public void runBackendSourceFixtureTests(T)(
    in string moduleSource,
    in string[] importPaths,
) {
    runBackendSourceFixtureTestResults!T(moduleSource, importPaths)
        .throwOnTestFailure;
}

public TestResult[] runBackendSourceFixtureTestResults(T)(
    in string moduleSource,
) {
    return runBackendSourceFixtureTestResults!T(moduleSource, []);
}

public TestResult[] runBackendSourceFixtureTestResults(T)(
    in string moduleSource,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto moduleResult = parseModuleWithCheckActionContext(
        moduleSource,
        importPaths,
    );
    auto backend = newBackend!T;
    return backend.runTests(moduleResult.module_);
}

public void runBackendFileFixtureTests(T)(
    in string filePath,
    in string[] importPaths,
) {
    runBackendFileFixtureTestResults!T(filePath, importPaths)
        .throwOnTestFailure;
}

public TestResult[]
runBackendFileFixtureTestResults(T)(
    in string filePath,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseModuleFileWithCheckActionContext;

    auto moduleResult = parseModuleFileWithCheckActionContext(
        filePath,
        importPaths,
    );
    auto backend = newBackend!T;
    return backend.runTests(moduleResult.module_);
}

private void throwOnTestFailure(in TestResult[] results) {
    foreach (result; results)
        if (!result.passed)
            throw new Exception(result.message);
}

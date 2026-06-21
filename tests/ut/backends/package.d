module ut.backends;


public import ut;
public import quickbite.backends.runner: TestResult;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;
public import quickbite.backends.interpreter;
public import quickbite.backends.bytecode;
public import quickbite.backends.ir;
public import quickbite.backends.native;
public import std.meta: AliasSeq;


auto newBackend(T)() {
    return new T;
}

public string buildSharedLibrary(
    in Sandbox sandbox,
    in string libraryName,
    in string[] sourcePaths,
) {
    import std.process: execute;

    const imagePath = sandbox.inSandboxPath("lib" ~ libraryName ~ ".so");
    string[] command = [
        "dmd",
        "-shared",
        "-fPIC",
        "-defaultlib=libphobos2.so",
        "-of=" ~ imagePath,
    ];
    foreach (sourcePath; sourcePaths)
        command ~= sandbox.inSandboxPath(sourcePath);

    const build = execute(command);
    build.status.should == 0;

    return imagePath;
}

public void runBackendSourceFixtureTests(T)(
    in string moduleSource,
) {
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
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

    auto moduleResult = parseSnippetWithCheckActionContext(moduleSource, importPaths);
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
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto moduleResult = parseModuleWithCheckActionContext(
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

module ut.backends;


public import ut;
public import quickbite.backends: runModulesTests;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;
public import quickbite.backends.interpreter;
public import quickbite.backends.bytecode;
public import quickbite.backends.ir;


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
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto moduleResult = parseModuleWithCheckActionContext(moduleSource, importPaths);
    auto backend = newBackend!T;
    backend.runTests(moduleResult.module_);
}

public imported!"quickbite.backends".TestSummary runBackendSourceFixtureTestSummary(T)(
    in string moduleSource,
) {
    return runBackendSourceFixtureTestSummary!T(moduleSource, []);
}

public imported!"quickbite.backends".TestSummary runBackendSourceFixtureTestSummary(T)(
    in string moduleSource,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto moduleResult = parseModuleWithCheckActionContext(moduleSource, importPaths);
    auto backend = newBackend!T;
    return backend.runTestSummary(moduleResult.module_);
}

public void runBackendFileFixtureTests(T)(
    in string filePath,
    in string[] importPaths,
) {
    import std.file: readText;
    import quickbite.frontend.compiler: parseModule;

    auto moduleResult = parseModule(filePath.readText, importPaths);
    auto backend = newBackend!T;
    backend.runTests(moduleResult.module_);
}

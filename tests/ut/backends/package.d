module ut.backends;


public import ut;
public import quickbite.backend: runParsedModulesTests;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;


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

    auto parsed = parseModuleWithCheckActionContext(moduleSource, importPaths);
    auto backend = newBackend!T;
    backend.runParsedTests(parsed.module_);
}

public imported!"quickbite.backend".TestSummary runBackendSourceFixtureTestSummary(T)(
    in string moduleSource,
) {
    return runBackendSourceFixtureTestSummary!T(moduleSource, []);
}

public imported!"quickbite.backend".TestSummary runBackendSourceFixtureTestSummary(T)(
    in string moduleSource,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto parsed = parseModuleWithCheckActionContext(moduleSource, importPaths);
    auto backend = newBackend!T;
    return backend.runParsedTestSummary(parsed.module_);
}

public void runBackendFileFixtureTests(T)(
    in string filePath,
    in string[] importPaths,
) {
    import std.file: readText;
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(filePath.readText, importPaths);
    auto backend = newBackend!T;
    backend.runParsedTests(parsed.module_);
}

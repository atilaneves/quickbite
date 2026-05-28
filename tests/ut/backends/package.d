module ut.backends;


public import ut;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;


alias backends = imported!"std.meta".AliasSeq!(
    Ctfe,
);


auto newBackend(T)() {
    return new T;
}

public void runBackendSourceFixtureTests(T)(in string moduleSource) {
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto parsed = parseModuleWithCheckActionContext(moduleSource);
    auto backend = newBackend!T;
    backend.runParsedTests(parsed.module_);
}

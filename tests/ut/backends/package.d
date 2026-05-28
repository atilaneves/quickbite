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

public void runTests(T)(T backend, in string moduleSource) {
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto parsed = parseModuleWithCheckActionContext(moduleSource);
    backend.runParsedTests(parsed.module_);
}

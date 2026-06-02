module quickbite.backends;

private:

public struct TestSummary {
    public size_t total;
    public size_t passed;
    public size_t failed;
}

public interface Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import dmd.dmodule: Module;

    public Value eval(in string expr);
    public Value evalRepl(in EvalCell cell);
    public void runParsedTests(Module module_);
    public TestSummary runParsedTestSummary(Module module_);
}

public void runParsedModulesTests(
    Backend backend,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        backend.runParsedTests(module_);
}

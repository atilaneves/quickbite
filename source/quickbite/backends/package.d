module quickbite.backends;

private:

public struct TestSummary {
    public size_t total;
    public size_t passed;
    public size_t failed;
}

public enum TestOutcome {
    passed,
    failed,
}

public struct TestCaseResult {
    public TestOutcome outcome;
    public string name;
    public string location;
    public string message;
}

public struct TestRunResult {
    public TestSummary summary;
    public TestCaseResult[] cases;
}

public interface Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import dmd.dmodule: Module;

    public Value eval(in string expr);
    public Value evalRepl(EvalCell cell);
    public void runTests(Module module_);
    public TestRunResult runTestResults(Module module_);
    public TestSummary runTestSummary(Module module_);
}

public void runModulesTests(
    Backend backend,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        backend.runTests(module_);
}

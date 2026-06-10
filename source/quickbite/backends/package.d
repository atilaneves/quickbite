module quickbite.backends;

private:

public struct TestResult {
    public bool passed;
    public string name;
    public string location;
    public string message;
}

public interface Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import dmd.dmodule: Module;

    public Value eval(in string expr);
    public Value evalRepl(EvalCell cell);
    public TestResult[] runTestResults(Module module_);
}

public void runTests(
    Backend backend,
    imported!"dmd.dmodule".Module module_,
) {
    foreach (testCase; backend.runTestResults(module_))
        if (!testCase.passed)
            throw new Exception(testCase.message);
}

public void runModulesTests(
    Backend backend,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        backend.runTests(module_);
}

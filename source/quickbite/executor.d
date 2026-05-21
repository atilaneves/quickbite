module quickbite.executor;

private:

public struct TestSummary {
    public size_t total;
    public size_t passed;
    public size_t failed;
}

public interface Executor {
    public void runTests(in string source);
    public void runTests(in string source, in string[] importPaths);
    public void runParsedTests(imported!"dmd.dmodule".Module module_);
    public TestSummary runTestSummary(in string source);
}

public void runModulesTests(
    Executor executor,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        executor.runParsedTests(module_);
}

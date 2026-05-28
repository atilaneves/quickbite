module quickbite.backend;

private:

public struct TestSummary {
    public size_t total;
    public size_t passed;
    public size_t failed;
}

public interface Backend {
    public imported!"quickbite.lang".Value eval(in string expr);

    public imported!"quickbite.lang".Value evalRepl(
        in imported!"quickbite.frontend.repl".ReplCell cell,
    );

    public void runParsedTests(imported!"dmd.dmodule".Module module_);

    public TestSummary runParsedTestSummary(
        imported!"dmd.dmodule".Module module_,
    );
}

public void runParsedModulesTests(
    Backend backend,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        backend.runParsedTests(module_);
}

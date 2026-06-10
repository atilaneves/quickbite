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
    public TestResult[] runTests(Module module_);
}

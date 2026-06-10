module quickbite.backends.runner;


private:


public interface Runner {
    import dmd.dmodule: Module;
    TestResult[] runTests(Module module_);
}

public struct TestResult {
    public bool passed;
    public string name;
    public string location;
    public string message;
}

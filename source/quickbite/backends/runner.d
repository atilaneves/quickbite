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

// Whether a backend should mimic D's compile-time (CTFE) semantics or the
// behaviour of compiled code at runtime. A no-op for Ctfe (inherently
// compile-time) and SystemLinker (inherently runtime); the interpretation
// backends switch behaviour on it.
public enum ExecutionMode {
    runtime,
    compileTime,
}

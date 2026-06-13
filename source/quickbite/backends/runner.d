module quickbite.backends.runner;


private:


public interface Runner {
    import dmd.dmodule: Module;
    TestResult[] runTests(Module module_);
}

public interface GroupedRunner: Runner {
    import dmd.dmodule: Module;
    TestResult[] runTests(Module[] modules);
}

public TestResult[] runTests(Runner runner, imported!"dmd.dmodule".Module[] modules) {
    if (auto grouped = cast(GroupedRunner) runner)
        return grouped.runTests(modules);

    TestResult[] results;
    foreach (module_; modules)
        results ~= runner.runTests(module_);
    return results;
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

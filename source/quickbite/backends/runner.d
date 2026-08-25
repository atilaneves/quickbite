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

// A backend whose compilation happens inside `runTests` (eagerly or lazily
// mid-execution) reports the wall-clock cost of that compilation here, so a
// caller timing `runTests` can split compile time out of the total.
public interface CompileTimeReporter {
    import core.time: Duration;
    Duration compileTime() @safe @nogc nothrow pure const scope;
    void resetCompileTime() @safe @nogc nothrow pure scope;
}

public interface DgcAllocationReporter {
    ulong dGcAllocation() @safe @nogc nothrow pure const scope;
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

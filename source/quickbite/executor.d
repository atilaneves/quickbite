module quickbite.executor;

private:

public struct Value {
    private imported!"std.variant".Variant data;

    public this(T)(auto ref T value) {
        import std.traits: isIntegral;
        static if (isIntegral!T)
            data = cast(long) value;
        else
            data = value;
    }

    public bool opEquals(in Value other) const {
        return data == other.data;
    }
}

public struct TestSummary {
    public size_t total;
    public size_t passed;
    public size_t failed;
}

public interface Executor {
    public void runTests(in string source);
    public void runTests(in string source, in string[] importPaths);
    public TestSummary runTestSummary(in string source);
    public void runParsedTests(imported!"dmd.dmodule".Module module_);
    public Value eval(in string input);
}

public void runModulesTests(
    Executor executor,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        executor.runParsedTests(module_);
}

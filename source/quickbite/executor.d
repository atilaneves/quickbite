module quickbite.executor;

private:

public struct Value {
    private alias Data = imported!"std.sumtype".SumType!(
        bool,
        byte, ubyte,
        short, ushort,
        int, uint,
        long, ulong,
    );
    private Data data;

    public this(T)(in T value) {
        data = Data(value);
    }

    public bool opEquals(in Value other) const {
        return data == other.data;
    }

    public string toString() const {
        import std.conv: text;
        import std.sumtype: match;

        return data.match!((value) => text(value));
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

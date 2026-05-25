module quickbite.executor;

private:

public struct Value {
    private alias Data = imported!"std.sumtype".SumType!(
        bool,
        byte, ubyte,
        short, ushort,
        int, uint,
        long, ulong,
        long[],
    );
    private Data data;

    public this(T)(in T value)
    if (!is(T == long[]))
    {
        data = Data(value);
    }

    public this(in long[] value) {
        data = Data(value.dup);
    }

    public bool opEquals(in Value other) const {
        return data == other.data;
    }

    public long asLong() const {
        import std.sumtype: match;

        return data.match!(
            (const(long)[] _) {
                throw new Exception("Expected scalar, got array.");
                return 0L;
            },
            (value) => cast(long) value,
        );
    }

    public long[] asLongArray() const {
        import std.sumtype: match;

        return data.match!(
            (const(long)[] value) => value.dup,
            (_) {
                throw new Exception("Expected array, got scalar.");
                return null;
            },
        );
    }

    public bool isLongArray() const {
        import std.sumtype: match;

        return data.match!(
            (const(long)[] _) => true,
            (_) => false,
        );
    }

    public string toString() const {
        return data.toString;
    }
}

public struct TestSummary {
    public size_t total;
    public size_t passed;
    public size_t failed;
}

public struct Repl {
    public enum CellStatus {
        incomplete,
        void_,
        value,
    }

    public struct CellResult {
        public CellStatus status;
        public Value value;

        public static CellResult void_() {
            return CellResult(CellStatus.void_, Value(0));
        }

        public static CellResult value_(in Value payload) {
            return CellResult(CellStatus.value, payload);
        }
    }
}

public interface Executor {
    public void runTests(in string source);
    public void runTests(in string source, in string[] importPaths);
    public TestSummary runTestSummary(in string source);
    public void runParsedTests(imported!"dmd.dmodule".Module module_);
    public Value eval(in string input);
    public void runVoidReplCell(in string transcript, in string input);
}

public void runModulesTests(
    Executor executor,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        executor.runParsedTests(module_);
}

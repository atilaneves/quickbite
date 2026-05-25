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

    public this(T)(in T value) {
        static if (is(T == long[]))
            data = Data(value.dup);
        else
            data = Data(value);
    }

    public this(in long[] value) {
        data = Data(value.dup);
    }

    public bool opEquals(in Value other) const {
        return data == other.data;
    }

    public long asLong() {
        import std.sumtype: get, has;

        if (data.has!bool)
            return data.get!bool ? 1L : 0L;
        if (data.has!byte)
            return data.get!byte;
        if (data.has!ubyte)
            return data.get!ubyte;
        if (data.has!short)
            return data.get!short;
        if (data.has!ushort)
            return data.get!ushort;
        if (data.has!int)
            return data.get!int;
        if (data.has!uint)
            return data.get!uint;
        if (data.has!long)
            return data.get!long;
        if (data.has!ulong)
            return cast(long) data.get!ulong;

        throw new Exception("Expected scalar, got array.");
    }

    public long[] asLongArray() {
        import std.sumtype: get, has;

        if (data.has!(long[]))
            return data.get!(long[]).dup;

        throw new Exception("Expected array, got scalar.");
    }

    public bool isLongArray() {
        import std.sumtype: has;

        return data.has!(long[]);
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

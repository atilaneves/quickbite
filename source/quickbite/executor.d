module quickbite.executor;

private:

public struct Value {
    private static struct Void {
    }

    private alias Data = imported!"std.sumtype".SumType!(
        long,
        Void,
        bool,
        byte, ubyte,
        short, ushort,
        int, uint,
        ulong,
        char, wchar, dchar,
        float, double, real,
        ifloat, idouble, ireal,
        cfloat, cdouble, creal,
        long[],
    );
    private Data data;

    public this(T)(in T value) @safe pure
    if (!is(T == long[]))
    {
        data = Data(value);
    }

    public this(in long[] value) @safe pure {
        data = Data(value.dup);
    }

    public ref Value opAssign(in Value value) @trusted pure {
        data = value.data;
        return this;
    }

    public ref Value opAssign(T)(in T value) @trusted pure
    if (!is(T == Value) && !is(T == long[]))
    {
        data = Data(value);
        return this;
    }

    public ref Value opAssign(in long[] value) @trusted pure {
        data = Data(value.dup);
        return this;
    }

    public static Value void_() @trusted pure {
        Value value;
        value.data = Data(Void.init);
        return value;
    }

    public bool opEquals(in Value other) const @safe pure {
        return data == other.data;
    }

    public long asLong() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(Void))) {
                    throw new Exception("Expected scalar, got void.");
                    return 0L;
                } else static if (is(T == const(long)[])) {
                    throw new Exception("Expected scalar, got array.");
                    return 0L;
                } else static if (
                    is(T == const(cfloat)) ||
                    is(T == const(cdouble)) ||
                    is(T == const(creal))
                ) {
                    throw new Exception(
                        "Expected integer-compatible scalar, got complex.",
                    );
                    return 0L;
                } else static if (is(T == const(float))) {
                    return floatBits(value);
                } else static if (is(T == const(double))) {
                    return doubleBits(value);
                } else static if (is(T == const(real))) {
                    return doubleBits(cast(double) value);
                } else {
                    return cast(long) value;
                }
            },
        );
    }

    public size_t asIndex() const @safe pure {
        const value = asLong;
        if (value < 0)
            throw new Exception("Expected non-negative index.");

        return cast(size_t) value;
    }

    public double asDouble() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(float))) {
                    return cast(double) value;
                } else static if (is(T == const(double))) {
                    return value;
                } else static if (is(T == const(real))) {
                    return cast(double) value;
                } else static if (is(T == const(ifloat))) {
                    return cast(double) value;
                } else static if (is(T == const(idouble))) {
                    return cast(double) value;
                } else static if (is(T == const(ireal))) {
                    return cast(double) value;
                } else {
                    return cast(double) asLong;
                }
            },
        );
    }

    public real asReal() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(float))) {
                    return cast(real) value;
                } else static if (is(T == const(double))) {
                    return cast(real) value;
                } else static if (is(T == const(real))) {
                    return value;
                } else static if (is(T == const(ifloat))) {
                    return cast(real) value;
                } else static if (is(T == const(idouble))) {
                    return cast(real) value;
                } else static if (is(T == const(ireal))) {
                    return cast(real) value;
                } else {
                    return cast(real) asLong;
                }
            },
        );
    }

    public bool isFloating() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (
                    is(T == const(float)) ||
                    is(T == const(double)) ||
                    is(T == const(real)) ||
                    is(T == const(ifloat)) ||
                    is(T == const(idouble)) ||
                    is(T == const(ireal))
                ) {
                    return true;
                } else {
                    return false;
                }
            },
        );
    }

    public bool isFloat32() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                return is(T == const(float)) || is(T == const(ifloat));
            },
        );
    }

    public bool isFloat64() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                return is(T == const(double)) || is(T == const(idouble));
            },
        );
    }

    public bool isTruthy() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(Void))) {
                    return false;
                } else static if (is(T == const(long)[])) {
                    return value.length != 0;
                } else static if (
                    is(T == const(cfloat)) ||
                    is(T == const(cdouble)) ||
                    is(T == const(creal))
                ) {
                    return value != 0;
                } else {
                    return value != 0;
                }
            },
        );
    }

    public T opCast(T : bool)() const @safe pure {
        return isTruthy;
    }

    public long[] asLongArray() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(long)[] value) => value.dup,
            (_) {
                throw new Exception("Expected array, got scalar.");
                return null;
            },
        );
    }

    public bool isLongArray() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(long)[] _) => true,
            (_) => false,
        );
    }

    public string toString() const @safe pure {
        import std.conv: text;
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(float))) {
                    return text(value, "f");
                } else static if (is(T == const(double))) {
                    return text(value, "d");
                } else {
                    return data.toString;
                }
            },
        );
    }
}

private long floatBits(in float value) @trusted pure nothrow {
    return *cast(uint*) &value;
}

private long doubleBits(in double value) @trusted pure nothrow {
    return cast(long) *cast(ulong*) &value;
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
    public void runTests(imported!"dmd.dmodule".Module module_);
    public Value eval(in string input);
}

public void runModulesTests(
    Executor executor,
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        executor.runTests(module_);
}

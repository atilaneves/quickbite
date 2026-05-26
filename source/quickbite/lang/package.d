module quickbite.lang;

private:


public struct Value {
    private alias Data = imported!"std.sumtype".SumType!(

        Void,

        bool,

        ubyte,
        byte,
        short,
        ushort,
        int,
        uint,
        long,
        ulong,

        char,
        wchar,
        dchar,

        float,
        double,
        real,

        Array,
    );

    private Data data;

    public static Value void_() @safe pure {
        return Value(Void.init);
    }

    public this(T)(in T value) @safe pure
    if (!is(T == E[], E))
    {
        data = Data(value);
    }

    public this(T)(in T[] values) @safe pure {
        Value[] elements;
        foreach (value; values)
            elements ~= Value(value);

        data = Data(Array(elements));
    }

    public bool opEquals(in Value other) const @safe pure {
        return data == other.data;
    }

    public string toString() const @safe pure {
        return data.toString;
    }
}


private struct Array {
    public Value[] elements;

    public this(in Value[] elements) @safe pure {
        this.elements = elements.dup;
    }
}


private struct Void {}

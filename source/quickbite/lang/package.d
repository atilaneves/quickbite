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
        Struct,
    );

    private Data data = Data(Void.init);

    public static Value void_() @safe pure {
        return Value(Void.init);
    }

    private this(in Void value) @safe pure {
        data = Data(value);
    }

    public this(T)(in T value) @safe pure
    if (!is(T == E[], E) && !is(T == struct))
    {
        data = Data(value);
    }

    public this(T)(in T value) @safe pure
    if (is(T == struct) && !is(T == Void))
    {
        data = Data(Struct(value));
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
        import std.conv: text;
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(ubyte))) {
                    return text(value, ": ubyte");
                } else static if (is(T == const(byte))) {
                    return text(value, ": byte");
                } else static if (is(T == const(short))) {
                    return text(value, ": short");
                } else static if (is(T == const(ushort))) {
                    return text(value, ": ushort");
                } else static if (is(T == const(int))) {
                    return text(value, ": int");
                } else static if (is(T == const(uint))) {
                    return text(value, ": uint");
                } else static if (is(T == const(long))) {
                    return text(value, ": long");
                } else static if (is(T == const(ulong))) {
                    return text(value, ": ulong");
                } else {
                    return data.toString;
                }
            },
        );
    }
}


private struct Array {
    public Value[] elements;

    public this(in Value[] elements) @safe pure {
        this.elements = elements.dup;
    }
}


private struct Struct {
    public string typeName;
    public string typeIdentity;
    public Field[] fields;

    public this(T)(in T value) @safe pure
    if (is(T == struct))
    {
        typeName = T.stringof;
        typeIdentity = T.mangleof;

        static foreach (member; __traits(allMembers, T)) {
            fields ~= Field(member, Value(__traits(getMember, value, member)));
        }
    }
}


private struct Field {
    public string name;
    public Value value;
}


private struct Void {}

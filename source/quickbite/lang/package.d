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

        Null,
        float,
        double,
        real,

        Array,
        AssocArray,
        Struct,
        TypeName,
        EnumValue,
    );

    private Data data = Data(Void.init);

    public static Value void_() @safe pure {
        return Value(Void.init);
    }

    public static Value null_() @safe pure {
        return Value(Null.init);
    }

    public static Value structValue(
        in string typeName,
        in Value[] fields,
    ) @safe pure {
        return Value(Struct(typeName, fields));
    }

    public static Value arrayValue(in Value[] elements) @safe pure {
        return Value(Array(elements));
    }

    public static Value assocArrayValue(
        in Value[] keys,
        in Value[] values,
    ) @safe pure {
        return Value(AssocArray(keys, values));
    }

    public static Value typeName(in string name) @safe pure {
        return Value(TypeName(name));
    }

    public static Value enumValue(in string name) @safe pure {
        return Value(EnumValue(name));
    }

    private this(in Void value) @safe pure {
        data = Data(value);
    }

    private this(in Null value) @safe pure {
        data = Data(value);
    }

    private this(Struct value) @safe pure {
        data = Data(value);
    }

    private this(AssocArray value) @safe pure {
        data = Data(value);
    }

    private this(Array value) @safe pure {
        data = Data(value);
    }

    private this(in TypeName value) @safe pure {
        data = Data(value);
    }

    private this(in EnumValue value) @safe pure {
        data = Data(value);
    }

    public this(T)(in T value) @safe pure
    if (
        !is(T == E[], E) &&
        !is(T == V[K], V, K) &&
        !is(T == struct)
    )
    {
        data = Data(value);
    }

    public this(T)(in T value) @safe pure
    if (is(T == struct) && !is(T == Void))
    {
        data = Data(Struct(value));
    }

    public this(in string value) @safe pure {
        Value[] elements;
        foreach (char_; value)
            elements ~= Value(char_);

        data = Data(Array(elements));
    }

    public this(T)(in T[] values) @safe pure {
        Value[] elements;
        foreach (value; values)
            elements ~= Value(value);

        data = Data(Array(elements));
    }

    public this(K, V)(in V[K] values) @safe pure {
        data = Data(AssocArray(values));
    }

    public bool opEquals(in Value other) const @safe pure {
        return data == other.data;
    }

    public string asCharArrayString() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) {
                char[] result;
                foreach (element; array.elements)
                    result ~= element.asChar;
                return result.idup;
            },
            (_) {
                throw new Exception("Expected char array.");
                return null;
            },
        );
    }

    private dchar asDchar() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => cast(dchar) value,
            (const(wchar) value) => cast(dchar) value,
            (const(dchar) value) => value,
            (_) {
                throw new Exception("Expected character.");
                return dchar.init;
            },
        );
    }

    private bool isChar() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => true,
            (_) => false,
        );
    }

    private char asChar() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => value,
            (_) {
                throw new Exception("Expected char.");
                return char.init;
            },
        );
    }

    private string dText() const @safe pure {
        import std.conv: text;
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(AssocArray)) || is(T == AssocArray)) {
                    return value.toString;
                } else static if (is(T == const(Struct)) || is(T == Struct)) {
                    return value.toString;
                } else static if (is(T == const(TypeName)) || is(T == TypeName)) {
                    return value.toString;
                } else static if (is(T == const(EnumValue)) || is(T == EnumValue)) {
                    return value.toString;
                } else static if (is(T == const(Array)) || is(T == Array)) {
                    return value.dText;
                } else static if (is(T == const(Null)) || is(T == Null)) {
                    return "null";
                } else {
                    return text(value);
                }
            },
        );
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
                } else static if (is(T == const(uint))) {
                    return text(value, "u");
                } else static if (is(T == const(long))) {
                    return text(value, "L");
                } else static if (is(T == const(ulong))) {
                    return text(value, "UL");
                } else static if (is(T == const(float))) {
                    return text(value, "f");
                } else static if (is(T == const(real))) {
                    return text(value, ": real");
                } else static if (is(T == const(AssocArray)) || is(T == AssocArray)) {
                    return value.toString;
                } else static if (is(T == const(Struct)) || is(T == Struct)) {
                    return value.toString;
                } else static if (is(T == const(TypeName)) || is(T == TypeName)) {
                    return value.toString;
                } else static if (is(T == const(EnumValue)) || is(T == EnumValue)) {
                    return value.toString;
                } else static if (is(T == const(Array)) || is(T == Array)) {
                    return value.toString;
                } else static if (is(T == const(Null)) || is(T == Null)) {
                    return "null";
                } else {
                    return data.toString;
                }
            },
        );
    }

    public Value castTo(T)() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias U = Unqual!(typeof(value));

                static if (isIntegral!U || isFloatingPoint!U) {
                    return Value(cast(T) value);
                } else {
                    throw new Exception("Unsupported cast.");
                    return Value.void_;
                }
            },
        );
    }

    public Value opBinary(string op)(in Value rhs) const @safe pure
        if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (lhs) {
                alias L = Unqual!(typeof(lhs));

                static if (isIntegral!L) {
                    return rhs.binaryInteger!op(lhs);
                } else static if (isFloatingPoint!L) {
                    return rhs.binaryFloatingPoint!op(lhs);
                } else {
                    throw new Exception("Unsupported binary lhs type.");
                    return Value.void_;
                }
            },
        );
    }

    public Value opUnary(string op)() const @safe pure
        if (op == "-")
    {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isIntegral!T || isFloatingPoint!T) {
                    return Value(cast(T) -value);
                } else {
                    throw new Exception("Unsupported unary operand type.");
                    return Value.void_;
                }
            },
        );
    }

    public Value unaryFloating(alias operation)() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isFloatingPoint!T) {
                    return Value(operation(cast(T) value));
                } else {
                    throw new Exception("Unsupported unary floating operand type.");
                    return Value.void_;
                }
            },
        );
    }

    public Value binaryFloating(alias operation)(in Value rhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (lhs) {
                alias L = Unqual!(typeof(lhs));

                static if (isFloatingPoint!L) {
                    return rhs.data.match!(
                        (rhsValue) {
                            alias R = Unqual!(typeof(rhsValue));

                            static if (isFloatingPoint!R) {
                                return Value(cast(L) operation(
                                    cast(L) lhs,
                                    cast(R) rhsValue,
                                ));
                            } else {
                                throw new Exception(
                                    "Unsupported binary floating rhs type.",
                                );
                                return Value.void_;
                            }
                        },
                    );
                } else {
                    throw new Exception("Unsupported binary floating lhs type.");
                    return Value.void_;
                }
            },
        );
    }

    private Value binaryInteger(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (isIntegral!L && isIntegral!R) {
                    static if (op == "+")
                        return Value(cast(L) lhs + cast(R) rhs);
                    else static if (op == "-")
                        return Value(cast(L) lhs - cast(R) rhs);
                    else static if (op == "*")
                        return Value(cast(L) lhs * cast(R) rhs);
                    else static if (op == "/")
                        return Value(cast(L) lhs / cast(R) rhs);
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return Value.void_;
                }
            },
        );
    }

    private Value binaryFloatingPoint(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (isFloatingPoint!L && isFloatingPoint!R) {
                    static if (op == "+")
                        return Value(cast(L) lhs + cast(R) rhs);
                    else static if (op == "-")
                        return Value(cast(L) lhs - cast(R) rhs);
                    else static if (op == "*")
                        return Value(cast(L) lhs * cast(R) rhs);
                    else static if (op == "/")
                        return Value(cast(L) lhs / cast(R) rhs);
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return Value.void_;
                }
            },
        );
    }
}


private struct TypeName {
    public string name;

    public this(in string name) @safe pure {
        this.name = name;
    }

    public string toString() const @safe pure {
        return name;
    }
}


private struct EnumValue {
    public string name;

    public this(in string name) @safe pure {
        this.name = name;
    }

    public string toString() const @safe pure {
        return name;
    }
}


private struct Array {
    public Value[] elements;

    public this(in Value[] elements) @safe pure {
        this.elements = elements.dup;
    }

    public string toString() const @safe pure {
        string ret = "[";

        foreach (i, element; elements) {
            if (i != 0)
                ret ~= ", ";
            ret ~= element.dText;
        }

        return ret ~ "]";
    }

    public string dText() const @safe pure {
        if (!isNonEmptyCharArray)
            return toString;

        return `"` ~ charArrayString ~ `"`;
    }

    private bool isNonEmptyCharArray() const @safe pure {
        if (elements.length == 0)
            return false;

        foreach (element; elements)
            if (!element.isChar)
                return false;

        return true;
    }

    private string charArrayString() const @safe pure {
        char[] result;
        foreach (element; elements)
            result ~= element.asChar;

        return result.idup;
    }
}


private struct AssocArray {
    public Entry[] entries;

    public this(
        in Value[] keys,
        in Value[] values,
    ) @safe pure {
        assert(keys.length == values.length);
        foreach (index, key; keys)
            entries ~= Entry(key, values[index]);
    }

    public this(K, V)(in V[K] values) @safe pure {
        foreach (key, value; values)
            entries ~= Entry(Value(key), Value(value));
    }

    public string toString() const @safe pure {
        string ret = "[";

        foreach (i, entry; entries) {
            if (i != 0)
                ret ~= ", ";
            ret ~= entry.toString;
        }

        return ret ~ "]";
    }
}


private struct Entry {
    public Value key;
    public Value value;

    public string toString() const @safe pure {
        return key.dText ~ ":" ~ value.dText;
    }
}


private struct Struct {
    public string typeName;
    public Field[] fields;

    public this(
        in string typeName,
        in Value[] fields,
    ) @safe pure {
        this.typeName = typeName;

        foreach (field; fields)
            this.fields ~= Field("", field);
    }

    public this(T)(in T value) @safe pure
    if (is(T == struct))
    {
        typeName = T.stringof;

        static foreach (member; __traits(allMembers, T)) {
            fields ~= Field(member, Value(__traits(getMember, value, member)));
        }
    }

    public string toString() const @safe pure {
        string ret = typeName ~ "(";

        foreach (i, field; fields) {
            if (i != 0)
                ret ~= ", ";
            ret ~= field.toString;
        }

        return ret ~ ")";
    }
}


private struct Field {
    public string name;
    public Value value;

    public string toString() const @safe pure {
        return value.dText;
    }
}


private struct Void {}
private struct Null {}

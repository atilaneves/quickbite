module quickbite.backends.bytecode.core.reify;

private:

// Reifies raw result bytes into a Value using the static result type — the
// only place the new core constructs a Value. A string result is a slice
// descriptor (data offset and length) into the program's read-only data
// segment, reconstructed here just as a debugger renders memory by type.
package(quickbite.backends.bytecode) imported!"quickbite.lang".Value reify(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
    in ubyte[] data,
) @safe pure {
    import quickbite.lang: Value;

    if (type.isString) {
        const offset = scalar!uint(bytes);
        const length = scalar!uint(bytes[uint.sizeof .. $]);
        return Value.stringValue(cast(const(char)[]) data[offset .. offset + length]);
    }

    return reifyScalar(bytes, type.scalar);
}

private imported!"quickbite.lang".Value reifyScalar(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import quickbite.lang: Value;

    final switch (type) with (ScalarType) {
        case void_:
            return Value.void_;
        case bool_:
            return Value(scalar!bool(bytes));
        case byte_:
            return Value(scalar!byte(bytes));
        case ubyte_:
            return Value(scalar!ubyte(bytes));
        case short_:
            return Value(scalar!short(bytes));
        case ushort_:
            return Value(scalar!ushort(bytes));
        case int_:
            return Value(scalar!int(bytes));
        case uint_:
            return Value(scalar!uint(bytes));
        case long_:
            return Value(scalar!long(bytes));
        case ulong_:
            return Value(scalar!ulong(bytes));
        case char_:
            return Value(scalar!char(bytes));
        case wchar_:
            return Value(scalar!wchar(bytes));
        case dchar_:
            return Value(scalar!dchar(bytes));
        case float_:
            return Value(scalar!float(bytes));
        case double_:
            return Value(scalar!double(bytes));
    }
}

private T scalar(T)(in ubyte[] bytes) @safe pure {
    import std.bitmanip: littleEndianToNative;

    const ubyte[T.sizeof] raw = bytes[0 .. T.sizeof];
    return littleEndianToNative!T(raw);
}

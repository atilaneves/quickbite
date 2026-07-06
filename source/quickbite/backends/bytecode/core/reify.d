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
    import quickbite.backends.bytecode.core.program: ResultType;
    import quickbite.lang: Value;

    if (type.isString) {
        const offset = scalar!uint(bytes);
        const length = scalar!uint(bytes[uint.sizeof .. $]);
        return Value.stringValue(cast(const(char)[]) data[offset .. offset + length]);
    }

    if (type.isArray || type.isStaticArray)
        return reifyArray(bytes, type, data);

    return reifyScalar(bytes, type.scalar);
}

private imported!"quickbite.lang".Value reifyArray(
    in ubyte[] bytes,
    imported!"quickbite.backends.bytecode.core.program".ResultType type,
    in ubyte[] data,
) @safe pure {
    import quickbite.lang: Value;

    Value[] elements;
    const length = type.isStaticArray
        ? type.arrayLength
        : scalar!size_t(bytes[size_t.sizeof .. $]);
    foreach (index; 0 .. length) {
        const elementBytes = type.isStaticArray
            ? bytes[
                index * type.arrayElementSize
                .. (index + 1) * type.arrayElementSize
            ]
            : dynamicArrayElementBytes(bytes, index, type.arrayElementSize);
        if (type.arrayElementIsString) {
            const offset = scalar!uint(elementBytes);
            const stringLength = scalar!uint(elementBytes[uint.sizeof .. $]);
            elements ~= Value.stringValue(
                cast(const(char)[]) data[offset .. offset + stringLength],
            );
        } else if (type.arrayElementIsArray) {
            auto innerType = type;
            innerType.isStaticArray = false;
            innerType.isArray = true;
            innerType.arrayElementSize = scalarSize(type.elementType);
            innerType.arrayElementIsArray = false;
            elements ~= reifyArray(elementBytes, innerType, data);
        } else
            elements ~= reifyScalar(elementBytes, type.elementType);
    }
    return Value.arrayValue(elements);
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
        case real_:
            return Value(scalar!real(bytes));
    }
}

private uint scalarSize(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    final switch (type) with (ScalarType) {
        case void_:
            return 0;
        case bool_, byte_, ubyte_, char_:
            return 1;
        case short_, ushort_, wchar_:
            return 2;
        case int_, uint_, dchar_, float_:
            return 4;
        case long_, ulong_, double_:
            return 8;
        case real_:
            return real.sizeof;
    }
}

// Dynamic-array descriptors store a native heap pointer. The machine roots the
// pointed-to block for the session, and reification only reads the element bytes
// while producing the display value.
private const(ubyte)[] dynamicArrayElementBytes(
    in ubyte[] descriptor,
    in size_t index,
    in uint elementSize,
) @trusted pure {
    const pointer = scalar!size_t(descriptor);
    const bytes = cast(ubyte*) pointer;
    return bytes[index * elementSize .. (index + 1) * elementSize];
}

private T scalar(T)(in ubyte[] bytes) @safe pure {
    static if (is(T == real)) {
        union RealBytes {
            real value;
            ubyte[real.sizeof] bytes;
        }

        RealBytes raw;
        raw.bytes[] = bytes[0 .. real.sizeof];
        return raw.value;
    } else {
        import std.bitmanip: littleEndianToNative;

        const ubyte[T.sizeof] raw = bytes[0 .. T.sizeof];
        return littleEndianToNative!T(raw);
    }
}

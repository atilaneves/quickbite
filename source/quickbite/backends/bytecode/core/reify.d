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
    in ubyte[][] heap,
) @safe pure {
    import quickbite.lang: Value;

    if (type.isUndisplayable)
        return Value.undisplayable;

    if (type.isString) {
        const offset = scalar!uint(bytes);
        const length = scalar!uint(bytes[uint.sizeof .. $]);
        return reifyString(data[offset .. offset + length], type.elementType);
    }

    if (type.isArray)
        return reifyArray(bytes, type, data, heap);

    if (type.isStruct)
        return reifyStruct(bytes, type);

    return reifyScalar(bytes, type.scalar, type.enumMembers);
}

private imported!"quickbite.lang".Value reifyStruct(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: size;
    import quickbite.lang: Value;

    if (type.structName is null)
        return Value.undisplayable;

    Value[] fields;
    foreach (field; type.structFields) {
        const offset = field.offset;
        fields ~= reifyScalar(
            bytes[offset .. offset + size(field.type)],
            field.type,
            field.enumMembers,
        );
    }
    return Value.structDisplayValue(type.structName, fields);
}

private imported!"quickbite.lang".Value reifyArray(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
    in ubyte[] data,
    in ubyte[][] heap,
) @safe pure {
    import quickbite.backends.bytecode.core.program: size, sliceDescriptorSize;
    import quickbite.lang: Value;

    const length = type.isStaticArray
        ? type.arrayLength
        : scalar!size_t(bytes[size_t.sizeof .. $]);
    auto block = type.isStaticArray
        ? bytes
        : heapBlock(scalar!size_t(bytes), heap);
    if (!type.arrayElementsAreArrays && type.elementEnumMembers.length == 0 &&
        isCharacter(type.elementType))
        return reifyCharacterArray(block, length, type.elementType);

    Value[] elements;
    foreach (index; 0 .. length) {
        const offset = index * (type.arrayElementsAreArrays ||
            type.arrayElementsAreStrings
            ? sliceDescriptorSize
            : size(type.elementType));
        if (type.arrayElementsAreStrings) {
            elements ~= reifyStringDescriptor(
                block[offset .. offset + sliceDescriptorSize],
                type.elementType,
                data,
                index,
                length,
            );
        } else {
            elements ~= type.arrayElementsAreArrays
                ? reifyArray(
                    block[offset .. offset + sliceDescriptorSize],
                    type.withScalarArrayElements,
                    data,
                    heap,
                )
                : reifyScalar(
                    block[offset .. offset + size(type.elementType)],
                    type.elementType,
                    type.elementEnumMembers,
                );
        }
    }
    return Value.arrayValue(elements);
}

private imported!"quickbite.backends.bytecode.core.program".ResultType
withScalarArrayElements(
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ResultType;

    return ResultType.scalarArrayResult(
        type.elementType,
        type.elementEnumMembers.dup,
    );
}

private imported!"quickbite.lang".Value reifyString(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import quickbite.lang: Value;

    const chars = cast(const(char)[]) bytes;
    final switch (type) with (ScalarType) {
        case char_:
            return Value.stringValue(chars);
        case wchar_:
            wchar[] values;
            foreach (dchar value; chars)
                values ~= cast(wchar) value;
            return Value.stringValue(values);
        case dchar_:
            dchar[] values;
            foreach (dchar value; chars)
                values ~= value;
            return Value.stringValue(values);
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, float_, double_, real_:
            return Value.stringValue(chars);
    }
}

private imported!"quickbite.lang".Value reifyStringDescriptor(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
    in ubyte[] data,
    in size_t index,
    in size_t arrayLength,
) @safe pure {
    const offset = scalar!uint(bytes);
    const length = scalar!uint(bytes[uint.sizeof .. $]);
    if ((offset + length > data.length || length == 0) &&
        data.length == arrayLength)
    {
        return reifyString(data[index .. index + 1], type);
    }
    return reifyString(data[offset .. offset + length], type);
}

private imported!"quickbite.lang".Value reifyCharacterArray(
    in ubyte[] bytes,
    in size_t length,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import quickbite.lang: Value;

    final switch (type) with (ScalarType) {
        case char_:
            char[] values;
            foreach (index; 0 .. length)
                values ~= scalar!char(bytes[index .. index + char.sizeof]);
            return Value.stringValue(values);
        case wchar_:
            wchar[] values;
            foreach (index; 0 .. length) {
                const offset = index * wchar.sizeof;
                values ~= scalar!wchar(bytes[offset .. offset + wchar.sizeof]);
            }
            return Value.stringValue(values);
        case dchar_:
            dchar[] values;
            foreach (index; 0 .. length) {
                const offset = index * dchar.sizeof;
                values ~= scalar!dchar(bytes[offset .. offset + dchar.sizeof]);
            }
            return Value.stringValue(values);
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, float_, double_, real_:
            return Value.arrayValue([]);
    }
}

private bool isCharacter(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    final switch (type) with (ScalarType) {
        case char_:
        case wchar_:
        case dchar_:
            return true;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, float_, double_, real_:
            return false;
    }
}

private imported!"quickbite.lang".Value reifyScalar(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
    in string[ulong] enumMembers = null,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import quickbite.lang: Value;

    if (enumMembers.length != 0)
        if (auto name = scalarKey(bytes, type) in enumMembers)
            return Value.enumValue(*name);

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

private ulong scalarKey(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import std.meta: AliasSeq;

    final switch (type) with (ScalarType) {
        case void_:
            return 0;
        static foreach (T; AliasSeq!(
            bool, byte, ubyte, short, ushort, int, uint, long, ulong,
            char, wchar, dchar, float, double, real,
        ))
            mixin("case " ~ T.stringof ~ "_:" ~
                "return cast(ulong) scalar!" ~ T.stringof ~ "(bytes);");
    }
}

private const(ubyte)[] heapBlock(
    in size_t pointer,
    in ubyte[][] heap,
) @safe pure {
    foreach (block; heap)
        if (blockPointer(block) == pointer)
            return block;
    return null;
}

// Heap descriptors store native block pointers; comparing them requires taking
// the slice address, while all dereferencing stays through the rooted slice.
private size_t blockPointer(in ubyte[] block) @trusted pure {
    return cast(size_t) block.ptr;
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

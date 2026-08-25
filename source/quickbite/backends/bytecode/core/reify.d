module quickbite.backends.bytecode.core.reify;

private:

// Formats raw result bytes from their static type without materialising a
// backend-independent value carrier.
package(quickbite.backends.bytecode) string reify(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
    in ubyte[] data,
    in ubyte[][] heap,
    in ubyte[][] literalBlocks,
) @safe pure {
    if (type.isUndisplayable)
        return "<undisplayable>";
    if (type.isArray)
        return reifyArray(bytes, type, data, heap, literalBlocks, true);
    if (type.isStruct)
        return reifyStruct(bytes, type);
    return reifyScalar(bytes, type.scalar, type.enumMembers, false);
}

private string reifyStruct(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
) @safe pure {
    if (type.structName is null)
        return "<undisplayable>";

    string result = type.structName ~ "(";
    foreach (index, field; type.structFields) {
        if (index != 0)
            result ~= ", ";
        result ~= reifyStructField(bytes, field);
    }
    return result ~ ")";
}

private string reifyArray(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
    in ubyte[] data,
    in ubyte[][] heap,
    in ubyte[][] literalBlocks,
    in bool topLevel,
) @safe pure {
    import quickbite.backends.bytecode.core.program:
        size, sliceDescriptorLengthOffset, sliceDescriptorPtrOffset,
        sliceDescriptorSize;

    const length = type.isStaticArray
        ? type.arrayLength
        : scalar!size_t(bytes[sliceDescriptorLengthOffset(0) .. $]);
    const block = type.isStaticArray
        ? bytes
        : resolveBlock(
            scalar!size_t(bytes[sliceDescriptorPtrOffset(0) .. $]),
            heap, data, literalBlocks,
        );
    if (!type.arrayElementsAreArrays && !type.arrayElementsAreStructs &&
        type.elementEnumMembers.length == 0 && isCharacter(type.elementType))
        return reifyCharacterArray(block, length, type.elementType, topLevel);

    string result = "[";
    foreach (index; 0 .. length) {
        if (index != 0)
            result ~= ", ";
        const offset = index * (type.arrayElementsAreArrays ||
            type.arrayElementsAreStrings ? sliceDescriptorSize :
            type.arrayElementsAreStructs ? type.elementStructSize :
            size(type.elementType));
        if (type.arrayElementsAreStrings)
            result ~= reifyStringDescriptor(
                block[offset .. offset + sliceDescriptorSize], type.elementType,
                data, heap, literalBlocks,
            );
        else if (type.arrayElementsAreArrays)
            result ~= reifyArray(
                block[offset .. offset + sliceDescriptorSize],
                type.withScalarArrayElements, data, heap, literalBlocks, false,
            );
        else if (type.arrayElementsAreStructs)
            result ~= reifyArrayStructElement(
                block[offset .. offset + type.elementStructSize], type,
            );
        else
            result ~= reifyScalar(
                block[offset .. offset + size(type.elementType)], type.elementType,
                type.elementEnumMembers, true,
            );
    }
    return result ~ "]";
}

private imported!"quickbite.backends.bytecode.core.program".ResultType
withScalarArrayElements(
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ResultType;

    return ResultType.scalarArrayResult(type.elementType, type.elementEnumMembers.dup);
}

private string reifyArrayStructElement(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ResultType type,
) @safe pure {
    if (type.elementStructName is null)
        return "<undisplayable>";

    string result = type.elementStructName ~ "(";
    foreach (index, field; type.elementStructFields) {
        if (index != 0)
            result ~= ", ";
        result ~= reifyStructField(bytes, field);
    }
    return result ~ ")";
}

private string reifyStructField(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".StructDisplayField field,
) @safe pure {
    import quickbite.backends.bytecode.core.program: StructDisplayField, size;

    const offset = field.offset;
    final switch (field.kind) with (StructDisplayField.Kind) {
        case scalarField:
            return reifyScalar(
                bytes[offset .. offset + size(field.type)], field.type,
                field.enumMembers, false,
            );
        case nullableWord:
            return scalar!size_t(bytes[offset .. offset + size_t.sizeof]) == 0
                ? "null" : "<undisplayable>";
        case nullableDelegate:
            return scalar!size_t(bytes[offset .. offset + size_t.sizeof]) == 0 &&
                scalar!size_t(bytes[offset + size_t.sizeof ..
                    offset + 2 * size_t.sizeof]) == 0
                ? "null" : "<undisplayable>";
    }
}

private string reifyStringDescriptor(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
    in ubyte[] data,
    in ubyte[][] heap,
    in ubyte[][] literalBlocks,
) @safe pure {
    import quickbite.backends.bytecode.core.program:
        sliceDescriptorLengthOffset, sliceDescriptorPtrOffset;

    const pointer = scalar!size_t(bytes[sliceDescriptorPtrOffset(0) .. $]);
    const length = scalar!size_t(bytes[sliceDescriptorLengthOffset(0) .. $]);
    return reifyCharacterArray(
        resolveBlock(pointer, heap, data, literalBlocks), length, type, false,
    );
}

private string reifyCharacterArray(
    in ubyte[] bytes,
    in size_t length,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
    in bool topLevel,
) @safe pure {
    import quickbite.backends.bytecode.core.program: size;
    import std.utf: encode;

    string result;
    foreach (index; 0 .. length) {
        char[4] encoded;
        const width = size(type);
        const encodedLength = encode(encoded, character(
            bytes[index * width .. (index + 1) * width], type,
        ));
        result ~= encoded[0 .. encodedLength];
    }
    return topLevel
        ? result
        : `"` ~ result ~ `"` ~ characterArraySuffix(type);
}

private string characterArraySuffix(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    final switch (type) with (ScalarType) {
        case char_: return "";
        case wchar_: return "w";
        case dchar_: return "d";
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, float_, double_, real_:
            assert(0);
    }
}

private dchar character(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    final switch (type) with (ScalarType) {
        case char_: return cast(dchar) scalar!char(bytes);
        case wchar_: return cast(dchar) scalar!wchar(bytes);
        case dchar_: return scalar!dchar(bytes);
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, float_, double_, real_:
            assert(0);
    }
}

private bool isCharacter(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    final switch (type) with (ScalarType) {
        case char_, wchar_, dchar_: return true;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, float_, double_, real_: return false;
    }
}

private string reifyScalar(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
    in string[ulong] enumMembers,
    in bool dText,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import std.conv: text;

    if (enumMembers.length != 0)
        if (auto name = scalarKey(bytes, type) in enumMembers)
            return *name;

    final switch (type) with (ScalarType) {
        case void_: return "";
        case bool_: return text(scalar!bool(bytes));
        case byte_: return text(scalar!byte(bytes));
        case ubyte_: return text(scalar!ubyte(bytes));
        case short_: return text(scalar!short(bytes));
        case ushort_: return text(scalar!ushort(bytes));
        case int_: return text(scalar!int(bytes));
        case uint_: return text(scalar!uint(bytes), "u");
        case long_: return text(scalar!long(bytes), "L");
        case ulong_: return text(scalar!ulong(bytes), "UL");
        case char_, wchar_, dchar_:
            const value = reifyCharacterArray(bytes, 1, type, true);
            return dText ? value : text("'", value, "'");
        case float_: return text(decimalText(scalar!float(bytes)), "f");
        case double_: return decimalText(scalar!double(bytes));
        case real_: return text(decimalText(scalar!real(bytes)), "L");
    }
}

private string decimalText(T)(in T value) @safe pure {
    import std.algorithm: canFind;
    import std.conv: text;

    const result = text(value);
    return result.canFind('.', 'e', 'E', "inf", "nan") ? result : result ~ ".0";
}

private ulong scalarKey(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import std.meta: AliasSeq;

    final switch (type) with (ScalarType) {
        case void_: return 0;
        static foreach (T; AliasSeq!(
            bool, byte, ubyte, short, ushort, int, uint, long, ulong,
            char, wchar, dchar, float, double, real,
        ))
            mixin("case " ~ T.stringof ~ "_:" ~
                "return cast(ulong) scalar!" ~ T.stringof ~ "(bytes);");
    }
}

private const(ubyte)[] resolveBlock(
    in size_t pointer,
    in ubyte[][] heap,
    in ubyte[] data,
    in ubyte[][] literalBlocks,
) @safe pure {
    if (auto block = rangeBlock(pointer, heap))
        return block;
    if (auto literal = rangeBlock(pointer, literalBlocks))
        return literal;
    if (auto block = dataBlock(pointer, data))
        return block;
    return gcBlock(pointer);
}

// The GC validates each returned allocation before this view reads its bytes.
private const(ubyte)[] gcBlock(in size_t pointer) @trusted pure {
    import core.memory: GC;

    auto base = GC.addrOf(cast(void*) pointer);
    if (base is null)
        return null;
    const size = GC.sizeOf(base);
    return (cast(const(ubyte)*) base)[0 .. size][pointer - cast(size_t) base .. $];
}

// The range check keeps the conversion from the rooted data slice in bounds.
private const(ubyte)[] dataBlock(in size_t pointer, in ubyte[] data) @trusted pure {
    const base = cast(size_t) data.ptr;
    if (pointer < base || pointer > base + data.length)
        return null;
    return data[pointer - base .. $];
}

// The containing-range check keeps each converted block pointer in bounds.
private const(ubyte)[] rangeBlock(
    in size_t pointer,
    in ubyte[][] blocks,
) @trusted pure {
    foreach (block; blocks) {
        const base = cast(size_t) block.ptr;
        if (pointer >= base && pointer <= base + block.length)
            return block[pointer - base .. $];
    }
    return null;
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

module quickbite.lang;

private:


private enum ArrayDisplay {
    normal,
    string,
    wstring,
    dstring,
}


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
        ImaginaryScalar,
        ComplexScalar,

        Array,
        AssocArray,
        ClassObject,
        LocalPointer,
        Pointer,
        Struct,
        TypeName,
        EnumValue,
        FunctionPointer,
        Undisplayable,
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

    public static Value classValue(
        in string typeName,
        in string[] typeNames,
        in string[] fieldNames,
        in Value[] fields,
    ) @safe pure {
        return Value(ClassObject(typeName, typeNames, fieldNames, fields));
    }

    public static Value arrayValue(in Value[] elements) @safe pure {
        return Value(Array(elements));
    }

    public static Value stringValue(in char[] elements) @safe pure {
        Value[] values;
        foreach (element; elements)
            values ~= Value(element);

        return Value(Array(values, ArrayDisplay.string));
    }

    public static Value stringValue(in wchar[] elements) @safe pure {
        Value[] values;
        foreach (element; elements)
            values ~= Value(element);

        return Value(Array(values, ArrayDisplay.wstring));
    }

    public static Value stringValue(in dchar[] elements) @safe pure {
        Value[] values;
        foreach (element; elements)
            values ~= Value(element);

        return Value(Array(values, ArrayDisplay.dstring));
    }

    public static Value characterArrayValue(in Value[] elements) @safe pure {
        return Value(Array(elements, ArrayDisplay.string));
    }

    public static Value assocArrayValue(
        in Value[] keys,
        in Value[] values,
    ) @safe pure {
        return Value(AssocArray(keys, values));
    }

    public static Value pointerValue(in Value target) @safe pure {
        return Value(Pointer([target]));
    }

    public static Value arrayPointerValue(
        in Value[] allocation,
        in size_t allocationId,
        in long offset,
    ) @safe pure {
        return Value(Pointer(allocation, allocationId, offset));
    }

    public static Value localPointerValue(in size_t id) @safe pure {
        return Value(LocalPointer(id));
    }

    public static Value functionPointerValue(in size_t id) @safe pure {
        return Value(FunctionPointer(id));
    }

    public static Value typeName(in string name) @safe pure {
        return Value(TypeName(name));
    }

    public static Value enumValue(in string name) @safe pure {
        return Value(EnumValue(name));
    }

    public static Value complexValue(in real realPart, in real imaginaryPart) @safe pure {
        return Value(ComplexScalar(realPart, imaginaryPart));
    }

    public static Value imaginaryValue(in real value) @safe pure {
        return Value(ImaginaryScalar(value));
    }

    public static Value undisplayable() @safe pure {
        return Value(Undisplayable.init);
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

    private this(ClassObject value) @safe pure {
        data = Data(value);
    }

    private this(AssocArray value) @safe pure {
        data = Data(value);
    }

    private this(Pointer value) @safe pure {
        data = Data(value);
    }

    private this(LocalPointer value) @safe pure {
        data = Data(value);
    }

    private this(FunctionPointer value) @safe pure {
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

    private this(in ComplexScalar value) @safe pure {
        data = Data(value);
    }

    private this(in ImaginaryScalar value) @safe pure {
        data = Data(value);
    }

    private this(in Undisplayable value) @safe pure {
        data = Data(value);
    }

    public this(T)(in T value) @safe pure
    if (
        !is(T == E[], E) &&
        !is(T == V[K], V, K) &&
        !is(T == struct)
    )
    {
        import std.traits: Unqual;

        data = Data(cast(Unqual!T) value);
    }

    public this(T)(in T value) @safe pure
    if (is(T == struct) && !is(T == Void))
    {
        data = Data(Struct(value));
    }

    public this(in string value) @safe pure {
        data = Value.stringValue(value).data;
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

    public size_t toHash() const @safe pure nothrow {
        return 0;
    }

    public string asCharArrayString() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) {
                char[] result;
                foreach (element; array.elements)
                    result ~= element.asUtf8Character;
                return result.idup;
            },
            (_) {
                throw new Exception("Expected char array.");
                return null;
            },
        );
    }

    public string stringTypeAnnotation() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) => array.typeAnnotation,
            (_) => "",
        );
    }

    public bool isStringDisplayArray() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) {
                final switch (array.display) with (ArrayDisplay) {
                    case normal:
                        return false;
                    case string:
                    case wstring:
                    case dstring:
                        return true;
                }
            },
            (_) => false,
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

    private string asUtf8Character() const @safe pure {
        import std.sumtype: match;
        import std.utf: encode;

        return data.match!(
            (const(char) value) => [value].idup,
            (const(wchar) value) {
                char[4] encoded;
                const length = encode(encoded, cast(dchar) value);
                return encoded[0 .. length].idup;
            },
            (const(dchar) value) {
                char[4] encoded;
                const length = encode(encoded, value);
                return encoded[0 .. length].idup;
            },
            (_) {
                throw new Exception("Expected character.");
                return null;
            },
        );
    }

    public bool isChar() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => true,
            (_) => false,
        );
    }

    public bool isCharacter() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => true,
            (const(wchar) value) => true,
            (const(dchar) value) => true,
            (_) => false,
        );
    }

    public char asChar() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => value,
            (_) {
                throw new Exception("Expected char.");
                return char.init;
            },
        );
    }

    public string dText() const @safe pure {
        import std.conv: text;
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(AssocArray)) || is(T == AssocArray)) {
                    return value.toString;
                } else static if (is(T == const(Struct)) || is(T == Struct)) {
                    return value.toString;
                } else static if (is(T == const(ClassObject)) || is(T == ClassObject)) {
                    return value.toString;
                } else static if (is(T == const(TypeName)) || is(T == TypeName)) {
                    return value.toString;
                } else static if (is(T == const(EnumValue)) || is(T == EnumValue)) {
                    return value.toString;
                } else static if (is(T == const(FunctionPointer)) || is(T == FunctionPointer)) {
                    return value.toString;
                } else static if (is(T == const(Undisplayable)) || is(T == Undisplayable)) {
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
        import std.traits: isSomeChar;

        return data.match!(
            (value) {
                alias T = typeof(value);
                static if (is(T == const(ubyte))) {
                    return text(value);
                } else static if (is(T == const(byte))) {
                    return text(value);
                } else static if (is(T == const(short))) {
                    return text(value);
                } else static if (is(T == const(ushort))) {
                    return text(value);
                } else static if (is(T == const(uint))) {
                    return text(value, "u");
                } else static if (is(T == const(long))) {
                    return text(value, "L");
                } else static if (is(T == const(ulong))) {
                    return text(value, "UL");
                } else static if (is(T == const(float))) {
                    return text(decimalText(value), "f");
                } else static if (is(T == const(double))) {
                    return decimalText(value);
                } else static if (is(T == const(real))) {
                    return text(decimalText(value), "L");
                } else static if (is(T == const(ImaginaryScalar)) ||
                    is(T == ImaginaryScalar))
                {
                    return value.toString;
                } else static if (is(T == const(ComplexScalar)) ||
                    is(T == ComplexScalar))
                {
                    return value.toString;
                } else static if (isSomeChar!T) {
                    return text("'", asUtf8Character, "'");
                } else static if (is(T == const(AssocArray)) || is(T == AssocArray)) {
                    return value.toString;
                } else static if (is(T == const(Struct)) || is(T == Struct)) {
                    return value.toString;
                } else static if (is(T == const(ClassObject)) || is(T == ClassObject)) {
                    return value.toString;
                } else static if (is(T == const(TypeName)) || is(T == TypeName)) {
                    return value.toString;
                } else static if (is(T == const(EnumValue)) || is(T == EnumValue)) {
                    return value.toString;
                } else static if (is(T == const(FunctionPointer)) || is(T == FunctionPointer)) {
                    return value.toString;
                } else static if (is(T == const(Undisplayable)) || is(T == Undisplayable)) {
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

    private static string decimalText(T)(in T value) @safe pure {
        import std.algorithm: canFind;
        import std.conv: text;

        const result = text(value);
        return result.canFind('.', 'e', 'E', "inf", "nan") ? result : result ~ ".0";
    }

    public Value castTo(T)() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias U = Unqual!(typeof(value));

                static if (
                    is(U == bool) ||
                    isSomeChar!U ||
                    isIntegral!U ||
                    isFloatingPoint!U
                ) {
                    return Value(cast(T) value);
                } else static if (is(U == ImaginaryScalar)) {
                    return Value(cast(T) value.value);
                } else static if (is(U == ComplexScalar)) {
                    return Value(cast(T) value.realPart);
                } else {
                    throw new Exception("Unsupported cast.");
                    return Value.void_;
                }
            },
        );
    }

    public Value castToComplex() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias U = Unqual!(typeof(value));

                static if (
                    is(U == bool) ||
                    isSomeChar!U ||
                    isIntegral!U ||
                    isFloatingPoint!U
                ) {
                    return Value.complexValue(cast(real) value, 0.0L);
                } else static if (is(U == ImaginaryScalar)) {
                    return Value.complexValue(0.0L, value.value);
                } else static if (is(U == ComplexScalar)) {
                    return Value(value);
                } else {
                    throw new Exception("Unsupported complex cast.");
                    return Value.void_;
                }
            },
        );
    }

    public Value castToImaginary() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias U = Unqual!(typeof(value));

                static if (
                    is(U == bool) ||
                    isSomeChar!U ||
                    isIntegral!U ||
                    isFloatingPoint!U
                ) {
                    return Value.imaginaryValue(cast(real) value);
                } else static if (is(U == ImaginaryScalar)) {
                    return Value(value);
                } else static if (is(U == ComplexScalar)) {
                    return Value.imaginaryValue(value.imaginaryPart);
                } else {
                    throw new Exception("Unsupported imaginary cast.");
                    return Value.void_;
                }
            },
        );
    }

    public long asLong() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isIntegral!T || is(T == bool)) {
                    return cast(long) value;
                } else {
                    throw new Exception("Expected integer-compatible scalar.");
                    return 0L;
                }
            },
        );
    }

    public bool isIntegerCompatibleScalar() const @safe pure nothrow {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isIntegral!T || is(T == bool)) {
                    return true;
                } else {
                    return false;
                }
            },
        );
    }

    public bool isFloatingScalar() const @safe pure nothrow {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                return isFloatingPoint!T;
            },
        );
    }

    public size_t length() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) => array.elements.length,
            (const(AssocArray) assocArray) => assocArray.entries.length,
            (const(Pointer) pointer) => pointer.target.length,
            (_) {
                throw new Exception("Expected array.");
                return size_t.init;
            },
        );
    }

    public bool assocArrayContains(in Value key) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(AssocArray) assocArray) {
                foreach (entry; assocArray.entries)
                    if (entry.key == key)
                        return true;
                return false;
            },
            (_) {
                throw new Exception("Expected associative array.");
                return false;
            },
        );
    }

    public Value assocArrayElement(in Value key) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(AssocArray) assocArray) {
                foreach (entry; assocArray.entries)
                    if (entry.key == key)
                        return entry.value;

                throw new Exception("Expected present key.");
                return Value.void_;
            },
            (_) {
                throw new Exception("Expected associative array.");
                return Value.void_;
            },
        );
    }

    public Value withAssocArrayEntry(
        in Value key,
        in Value value,
    ) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(AssocArray) assocArray) {
                Value[] keys;
                Value[] values;
                bool replaced;

                foreach (entry; assocArray.entries) {
                    keys ~= entry.key;
                    if (entry.key == key) {
                        values ~= value;
                        replaced = true;
                    } else
                        values ~= entry.value;
                }

                if (!replaced) {
                    keys ~= key;
                    values ~= value;
                }

                return Value.assocArrayValue(keys, values);
            },
            (_) {
                throw new Exception("Expected associative array.");
                return Value.void_;
            },
        );
    }

    public Value withoutAssocArrayKey(in Value key) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(AssocArray) assocArray) {
                Value[] keys;
                Value[] values;

                foreach (entry; assocArray.entries) {
                    if (entry.key == key)
                        continue;
                    keys ~= entry.key;
                    values ~= entry.value;
                }

                return Value.assocArrayValue(keys, values);
            },
            (_) {
                throw new Exception("Expected associative array.");
                return Value.void_;
            },
        );
    }

    public Value assocArrayKeys() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(AssocArray) assocArray) {
                Value[] keys;
                foreach (entry; assocArray.entries)
                    keys ~= entry.key;

                return Value.arrayValue(keys);
            },
            (_) {
                throw new Exception("Expected associative array.");
                return Value.void_;
            },
        );
    }

    public Value assocArrayValues() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(AssocArray) assocArray) {
                Value[] values;
                foreach (entry; assocArray.entries)
                    values ~= entry.value;

                return Value.arrayValue(values);
            },
            (_) {
                throw new Exception("Expected associative array.");
                return Value.void_;
            },
        );
    }

    public bool isPointer() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => true,
            (const(LocalPointer) pointer) => true,
            (_) => false,
        );
    }

    public bool isLocalPointer() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(LocalPointer) pointer) => true,
            (_) => false,
        );
    }

    public size_t localPointerId() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(LocalPointer) pointer) => pointer.id,
            (_) {
                throw new Exception("Expected local pointer.");
                return size_t.init;
            },
        );
    }

    public bool isFunctionPointer() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(FunctionPointer) pointer) => true,
            (_) => false,
        );
    }

    public size_t functionPointerId() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(FunctionPointer) pointer) => pointer.id,
            (_) {
                throw new Exception("Expected function pointer.");
                return size_t.init;
            },
        );
    }

    public bool isStruct() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(Struct) struct_) => true,
            (_) => false,
        );
    }

    public bool isClassObject() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) => true,
            (_) => false,
        );
    }

    public bool isTypeName() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(TypeName) typeName) => true,
            (_) => false,
        );
    }

    public string asTypeNameString() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(TypeName) typeName) => typeName.name,
            (_) {
                throw new Exception("Expected type name.");
                return "";
            },
        );
    }

    public bool classHasType(in string typeName) const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) {
                foreach (candidate; object.typeNames)
                    if (candidate == typeName)
                        return true;
                return false;
            },
            (_) => false,
        );
    }

    public string classTypeName() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) => object.typeName,
            (_) {
                throw new Exception("Expected class object.");
                return "";
            },
        );
    }

    public bool isArray() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) => true,
            (_) => false,
        );
    }

    public size_t structFieldCount() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Struct) struct_) => struct_.fields.length,
            (_) {
                throw new Exception("Expected struct.");
                return size_t.init;
            },
        );
    }

    public Value pointerTarget() const @safe pure {
        return pointerIndex(0);
    }

    // Returns a new pointer value identical to this one except that the element
    // at offset 0 is replaced with `value`.  Only valid for single-element
    // struct-pointer allocations (those created by `pointerValue`).
    public Value withPointerTarget(in Value value) const pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) {
                auto target = pointer.target.dup;
                target[cast(size_t) pointer.offset] = value;
                return Value(Pointer(target, pointer.allocation, pointer.offset));
            },
            (_) {
                throw new Exception("Expected pointer.");
                return Value.void_;
            },
        );
    }

    public Value withPointerElements(in Value[] values) const pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) {
                auto target = pointer.target.dup;
                foreach (index, value; values) {
                    const element = pointer.offset + cast(long) index;
                    target[cast(size_t) element] = value;
                }
                return Value(Pointer(target, pointer.allocation, pointer.offset));
            },
            (_) {
                throw new Exception("Expected pointer.");
                return Value.void_;
            },
        );
    }

    public Value pointerIndex(in size_t index) const @safe pure {
        import std.conv: text;
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) {
                const element = pointer.offset + cast(long) index;
                if (element < 0 || element >= pointer.target.length)
                    throw new Exception(text(
                        "pointer index `", index,
                        "` exceeds allocated memory block `[",
                        -pointer.offset, "..",
                        cast(long) pointer.target.length - pointer.offset,
                        "]`",
                    ));

                return pointer.target[cast(size_t) element];
            },
            (_) {
                throw new Exception("Expected pointer.");
                return Value.void_;
            },
        );
    }

    public size_t pointerLength() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => pointer.target.length,
            (_) {
                throw new Exception("Expected pointer.");
                return size_t.init;
            },
        );
    }

    public Value pointerOffsetBy(in long delta) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => Value(Pointer(
                pointer.target,
                pointer.allocation,
                pointer.offset + delta,
            )),
            (_) {
                throw new Exception("Expected pointer.");
                return Value.void_;
            },
        );
    }

    public bool pointerSameAllocation(in Value other) const @safe pure {
        return pointerAllocation != 0 &&
            pointerAllocation == other.pointerAllocation;
    }

    public long pointerOffsetDifference(in Value other) const @safe pure {
        if (!pointerSameAllocation(other))
            throw new Exception("Expected pointers into the same allocation.");

        return pointerOffset - other.pointerOffset;
    }

    public Value pointerSlice(in size_t lower, in size_t upper) const @safe pure {
        import std.conv: text;
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) {
                const begin = pointer.offset + cast(long) lower;
                const end = pointer.offset + cast(long) upper;

                if (begin < 0 || begin > end || end > pointer.target.length)
                    throw new Exception(text(
                        "pointer slice `[", lower, "..", upper,
                        "]` exceeds allocated memory block `[",
                        -pointer.offset, "..",
                        cast(long) pointer.target.length - pointer.offset,
                        "]`",
                    ));

                return Value.arrayValue(
                    pointer.target[cast(size_t) begin .. cast(size_t) end],
                );
            },
            (_) {
                throw new Exception("Expected pointer.");
                return Value.void_;
            },
        );
    }

    public size_t pointerAllocation() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => pointer.allocation,
            (_) {
                throw new Exception("Expected pointer.");
                return size_t.init;
            },
        );
    }

    private long pointerOffset() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => pointer.offset,
            (_) {
                throw new Exception("Expected pointer.");
                return long.init;
            },
        );
    }

    public Value opIndex(in size_t index) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) => array.elements[index],
            (const(Pointer) pointer) => pointer.target[cast(size_t) pointer.offset + index],
            (_) {
                throw new Exception("Expected array.");
                return Value.void_;
            },
        );
    }

    public Value withArrayElement(
        in size_t index,
        in Value element,
    ) const pure {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) {
                auto elements = array.elements.dup;
                elements[index] = element;
                return Value.arrayValue(elements);
            },
            (_) {
                throw new Exception("Expected array.");
                return Value.void_;
            },
        );
    }

    public Value structFieldAt(in size_t index) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Struct) struct_) => struct_.fields[index].value,
            (_) {
                throw new Exception("Expected struct.");
                return Value.void_;
            },
        );
    }

    public Value classFieldAt(in size_t index) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) => object.fields[index].value,
            (_) {
                throw new Exception("Expected class object.");
                return Value.void_;
            },
        );
    }

    public Value classFieldNamed(in string name) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) {
                foreach (index, field; object.fields)
                    if (field.name == name)
                        return field.value;

                throw new Exception("Expected class field.");
                return Value.void_;
            },
            (_) {
                throw new Exception("Expected class object.");
                return Value.void_;
            },
        );
    }

    public bool hasClassFieldNamed(in string name) const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) {
                foreach (field; object.fields)
                    if (field.name == name)
                        return true;

                return false;
            },
            (_) => false,
        );
    }

    // not @safe: the sumtype match copies array-bearing alternatives,
    // which `match` infers as @system, same as withArrayElement below
    public Value withStructField(
        in size_t index,
        in Value value,
    ) const pure {
        import std.sumtype: match;

        return data.match!(
            (const(Struct) struct_) {
                Value[] values;
                foreach (field; struct_.fields)
                    values ~= field.value;
                values[index] = value;
                return Value.structValue(struct_.typeName, values);
            },
            (_) {
                throw new Exception("Expected struct.");
                return Value.void_;
            },
        );
    }

    public Value withClassField(
        in size_t index,
        in Value value,
    ) const pure {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) {
                Value[] values;
                foreach (field; object.fields)
                    values ~= field.value;
                values[index] = value;
                return Value.classValue(
                    object.typeName,
                    object.typeNames,
                    object.fieldNames,
                    values,
                );
            },
            (_) {
                throw new Exception("Expected class object.");
                return Value.void_;
            },
        );
    }

    public Value withClassFieldNamed(
        in string name,
        in Value value,
    ) const pure {
        import std.sumtype: match;

        return data.match!(
            (const(ClassObject) object) {
                Value[] values;
                size_t target;
                bool found;
                foreach (index, field; object.fields) {
                    values ~= field.value;
                    if (field.name == name) {
                        target = index;
                        found = true;
                    }
                }
                if (!found)
                    throw new Exception("Expected class field.");

                values[target] = value;
                return Value.classValue(
                    object.typeName,
                    object.typeNames,
                    object.fieldNames,
                    values,
                );
            },
            (_) {
                throw new Exception("Expected class object.");
                return Value.void_;
            },
        );
    }

    public Value withAppendedArrayElement(in Value element) const pure {
        import std.sumtype: match;

        return data.match!(
            (const(Array) array) {
                auto elements = array.elements.dup;
                elements ~= element;
                return Value.arrayValue(elements);
            },
            (_) {
                throw new Exception("Expected array.");
                return Value.void_;
            },
        );
    }

    public real asReal() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (
                    isIntegral!T ||
                    is(T == bool) ||
                    isFloatingPoint!T
                ) {
                    return cast(real) value;
                } else static if (is(T == ImaginaryScalar)) {
                    return value.value;
                } else static if (is(T == ComplexScalar)) {
                    return value.realPart;
                } else {
                    throw new Exception("Expected numeric scalar.");
                    return real.nan;
                }
            },
        );
    }

    public bool isNumericScalar() const @safe pure nothrow {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (
                    isIntegral!T ||
                    is(T == bool) ||
                    isFloatingPoint!T ||
                    is(T == ImaginaryScalar) ||
                    is(T == ComplexScalar)
                ) {
                    return true;
                } else {
                    return false;
                }
            },
        );
    }

    public Value complexRealPart() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);

                static if (is(T == const(ComplexScalar))) {
                    return Value(value.realPart);
                } else {
                    throw new Exception("Expected complex scalar.");
                    return Value.void_;
                }
            },
        );
    }

    public Value complexImaginaryPart() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);

                static if (is(T == const(ComplexScalar))) {
                    return Value(value.imaginaryPart);
                } else {
                    throw new Exception("Expected complex scalar.");
                    return Value.void_;
                }
            },
        );
    }

    public Value opBinary(string op)(in Value rhs) const @safe pure
        if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
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
                } else static if (is(L == ImaginaryScalar) || is(L == ComplexScalar)) {
                    return rhs.binaryComplex!op(lhs);
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
                    else static if (op == "%")
                        return Value(cast(L) lhs % cast(R) rhs);
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
                    else static if (op == "%")
                        return Value(cast(L) lhs % cast(R) rhs);
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return Value.void_;
                }
            },
        );
    }

    private Value binaryComplex(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (
                    isIntegral!R ||
                    isFloatingPoint!R ||
                    is(R == ImaginaryScalar) ||
                    is(R == ComplexScalar)
                ) {
                    const left = complexScalar(lhs);
                    const right = complexScalar(rhs);
                    static if (op == "+")
                        return Value(left + right);
                    else static if (op == "-")
                        return Value(left - right);
                    else static if (op == "*")
                        return Value(left * right);
                    else static if (op == "/")
                        return Value(left / right);
                    else {
                        throw new Exception("Unsupported complex binary operator.");
                        return Value.void_;
                    }
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return Value.void_;
                }
            },
        );
    }
}


private ComplexScalar complexScalar(T)(in T value) @safe pure {
    import std.traits: Unqual;

    alias U = Unqual!T;
    static if (is(U == ComplexScalar))
        return value;
    else static if (is(U == ImaginaryScalar))
        return ComplexScalar(0.0L, value.value);
    else
        return ComplexScalar(cast(real) value, 0.0L);
}


private struct ImaginaryScalar {
    public real value;

    public this(in real value) @safe pure {
        this.value = value;
    }

    public string toString() const @safe pure {
        import std.conv: text;

        return text(value, "i");
    }
}


private struct ComplexScalar {
    public real realPart;
    public real imaginaryPart;

    public this(in real realPart, in real imaginaryPart) @safe pure {
        this.realPart = realPart;
        this.imaginaryPart = imaginaryPart;
    }

    public ComplexScalar opBinary(string op)(in ComplexScalar rhs) const @safe pure
        if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        static if (op == "+")
            return ComplexScalar(
                realPart + rhs.realPart,
                imaginaryPart + rhs.imaginaryPart,
            );
        else static if (op == "-")
            return ComplexScalar(
                realPart - rhs.realPart,
                imaginaryPart - rhs.imaginaryPart,
            );
        else static if (op == "*")
            return ComplexScalar(
                realPart * rhs.realPart - imaginaryPart * rhs.imaginaryPart,
                realPart * rhs.imaginaryPart + imaginaryPart * rhs.realPart,
            );
        else
            return ComplexScalar(
                (realPart * rhs.realPart + imaginaryPart * rhs.imaginaryPart) /
                    (rhs.realPart * rhs.realPart + rhs.imaginaryPart * rhs.imaginaryPart),
                (imaginaryPart * rhs.realPart - realPart * rhs.imaginaryPart) /
                    (rhs.realPart * rhs.realPart + rhs.imaginaryPart * rhs.imaginaryPart),
            );
    }

    public string toString() const @safe pure {
        import std.conv: text;

        return text(realPart, "+", imaginaryPart, "i");
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


private struct FunctionPointer {
    public size_t id;

    public this(in size_t id) @safe pure {
        this.id = id;
    }

    public string toString() const @safe pure {
        import std.conv: text;

        return text("<function pointer ", id, ">");
    }
}


private struct Undisplayable {
    public string toString() const @safe pure {
        return "<undisplayable>";
    }
}


private struct Array {
    public Value[] elements;
    public ArrayDisplay display;

    public this(
        in Value[] elements,
        in ArrayDisplay display = ArrayDisplay.normal,
    ) @safe pure {
        this.elements = elements.dup;
        this.display = display;
    }

    public bool opEquals(in Array other) const @safe pure {
        return elements == other.elements;
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
        final switch (display) with (ArrayDisplay) {
            case normal:
                return toString;
            case string:
            case wstring:
            case dstring:
                return `"` ~ charArrayString ~ `"`;
        }
    }

    public string typeAnnotation() const @safe pure nothrow {
        import std.sumtype: match;
        import std.traits: Unqual;

        if (elements.length != 0)
            return elements[0].data.match!(
                (value) {
                    alias T = Unqual!(typeof(value));

                    static if (is(T == wchar)) {
                        return "w";
                    } else static if (is(T == dchar)) {
                        return "d";
                    } else {
                        return "";
                    }
                },
            );

        final switch (display) with (ArrayDisplay) {
            case normal:
            case string:
                return "";
            case wstring:
                return "w";
            case dstring:
                return "d";
        }
    }

    private bool isCharArray() const @safe pure {
        foreach (element; elements)
            if (!element.isCharacter)
                return false;

        return true;
    }

    private string charArrayString() const @safe pure {
        if (!isCharArray)
            return toString;

        char[] result;
        foreach (element; elements)
            result ~= element.asUtf8Character;

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

    public bool opEquals(in AssocArray other) const @safe pure {
        if (entries.length != other.entries.length)
            return false;

        foreach (entry; entries) {
            bool found;

            foreach (otherEntry; other.entries)
                if (otherEntry.key == entry.key &&
                    otherEntry.value == entry.value) {
                    found = true;
                    break;
                }

            if (!found)
                return false;
        }

        return true;
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


// `allocation` is an opaque nonzero id identifying the allocation the
// pointer points into; `target` is a copy-on-write snapshot of that
// allocation's elements and `offset` the element the pointer points at.
// Single-target pointers (e.g. associative array slots) have no
// allocation identity and use `allocation == 0`, `offset == 0`.
private struct Pointer {
    public Value[] target;
    public size_t allocation;
    public long offset;

    public this(in Value[] target) @safe pure {
        this.target = target.dup;
    }

    public this(
        in Value[] target,
        in size_t allocation,
        in long offset,
    ) @safe pure {
        this.target = target.dup;
        this.allocation = allocation;
        this.offset = offset;
    }
}


private struct LocalPointer {
    public size_t id;
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


private struct ClassObject {
    public string typeName;
    public string[] typeNames;
    public Field[] fields;
    public string[] fieldNames;

    public this(
        in string typeName,
        in string[] typeNames,
        in string[] fieldNames,
        in Value[] fields,
    ) @safe pure {
        this.typeName = typeName;
        this.typeNames = typeNames.dup;
        this.fieldNames = fieldNames.dup;

        foreach (index, field; fields) {
            const name = index < fieldNames.length ? fieldNames[index] : "";
            this.fields ~= Field(name, field);
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

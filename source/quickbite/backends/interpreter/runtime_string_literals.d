module quickbite.backends.interpreter.runtime_string_literals;

private:

private enum charCodeUnitWidth = 1;
private enum wcharCodeUnitWidth = 2;
private enum dcharCodeUnitWidth = 4;
private enum maxUtf8CodeUnits = 4;

public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult stringValue(
    imported!"dmd.expression".StringExp string_,
    out imported!"quickbite.backends.interpreter.native_block".NativeBlock
        pointerStorage,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    // DMD types a literal used directly as `"text".ptr` as a pointer,
    // rather than preserving the intermediate array expression.  Give that
    // pointer real NUL-terminated native storage; reconstructArray requires
    // an array Type and would otherwise reject this ordinary C-string path.
    if (string_.type.toBasetype.isTypePointer !is null) {
        pointerStorage = pointerStringStorage(string_);
        return ExpressionResult.pointerValue(pointerStorage.address);
    }

    switch (string_.sz) {
        case wcharCodeUnitWidth:
            return AggregateValue.reconstructArray(
                string_.type,
                characterValues(stringCodeUnits!wchar(string_)),
            );
        case dcharCodeUnitWidth:
            return AggregateValue.reconstructArray(
                string_.type,
                characterValues(stringCodeUnits!dchar(string_)),
            );
        default:
            return AggregateValue.reconstructArray(
                string_.type,
                characterValues(stringChars(string_)),
            );
    }
}


private imported!"quickbite.backends.interpreter.native_block".NativeBlock
pointerStringStorage(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.backends.interpreter.native_array: NativeArray;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.native_scalar: writeScalar;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import quickbite.backends.interpreter.layout: typeByteSize;

    auto elementType = string_.type.toBasetype.nextOf;
    const length = string_.numberOfCodeUnits + 1;
    auto storage = NativeBlock.allocate(
        length * typeByteSize(elementType),
        NativeBlock.Scan.no,
    );
    auto elements = NativeArray.borrow(elementType, storage.address, length);
    foreach (index; 0 .. string_.numberOfCodeUnits)
        writeScalar(elementType, elements.element(index), ExpressionResult(
            string_.getIndex(index),
        ));
    writeScalar(elementType, elements.element(length - 1), ExpressionResult(0));
    return storage;
}


private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult[]
characterValues(T)(in T[] codeUnits) @safe pure {
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    ExpressionResult[] values;
    foreach (codeUnit; codeUnits)
        values ~= ExpressionResult(codeUnit);
    return values;
}

public T[] stringCodeUnits(T)(
    imported!"dmd.expression".StringExp string_,
) {
    T[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits)
        values ~= cast(T) string_.getIndex(index);

    return values;
}

public char[] stringChars(
    imported!"dmd.expression".StringExp string_,
) {
    import std.utf: encode;

    char[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits) {
        const codeUnit = string_.getIndex(index);
        if (string_.sz == charCodeUnitWidth) {
            values ~= cast(char) codeUnit;
        } else {
            char[maxUtf8CodeUnits] encoded;
            const length = encode(encoded, cast(dchar) codeUnit);
            values ~= encoded[0 .. length];
        }
    }

    return values;
}

module quickbite.backends.interpreter.runtime_string_literals;

private:

private enum charCodeUnitWidth = 1;
private enum wcharCodeUnitWidth = 2;
private enum dcharCodeUnitWidth = 4;
private enum maxUtf8CodeUnits = 4;

public void stringValue(
    imported!"dmd.expression".StringExp string_,
    imported!"quickbite.backends.interpreter.place".Place destination,
    out imported!"quickbite.backends.interpreter.native_block".NativeBlock
        pointerStorage,
    out imported!"quickbite.backends.interpreter.native_block".NativeBlock
        backingStorage,
) {
    import quickbite.backends.interpreter.native_array: NativeArray;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    pointerStorage = NativeBlock.init;
    backingStorage = NativeBlock.init;

    // DMD types a literal used directly as `"text".ptr` as a pointer,
    // rather than preserving the intermediate array expression.  Give that
    // pointer real NUL-terminated native storage; an array destination cannot
    // represent this ordinary C-string path.
    if (string_.type.toBasetype.isTypePointer !is null) {
        pointerStorage = pointerStringStorage(string_);
        destination.storeReference(pointerStorage.address);
        return;
    }

    switch (string_.sz) {
        case wcharCodeUnitWidth:
            constructStringArray(
                string_.type,
                stringCodeUnits!wchar(string_),
                destination,
                backingStorage,
            );
            break;
        case dcharCodeUnitWidth:
            constructStringArray(
                string_.type,
                stringCodeUnits!dchar(string_),
                destination,
                backingStorage,
            );
            break;
        default:
            constructStringArray(
                string_.type,
                stringChars(string_),
                destination,
                backingStorage,
            );
    }
}


private void constructStringArray(T)(
    imported!"dmd.mtype".Type type,
    T[] codeUnits,
    imported!"quickbite.backends.interpreter.place".Place destination,
    out imported!"quickbite.backends.interpreter.native_block".NativeBlock
        backingStorage,
) {
    import quickbite.backends.interpreter.native_array: NativeArray;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    auto arrayType = type.toBasetype;
    if (auto slice = arrayType.isTypeDArray) {
        auto backing = NativeArray.allocate(slice.next, codeUnits.length);
        backing.writeSliceHeader(destination.address);
        backingStorage = backing.block;
        foreach (index, codeUnit; codeUnits)
            destination.index(index).storeNativeScalar(codeUnit);
        return;
    }

    if (arrayType.isTypeSArray !is null) {
        backingStorage = NativeBlock.init;
        foreach (index, codeUnit; codeUnits)
            destination.index(index).storeNativeScalar(codeUnit);
        return;
    }

    throw new Exception(
        "quickbite.backends.interpreter.runtime_string_literals: "
        ~ "string literal needs an array destination",
    );
}


private imported!"quickbite.backends.interpreter.native_block".NativeBlock
pointerStringStorage(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.backends.interpreter.native_array: NativeArray;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.layout: typeByteSize;
    import quickbite.backends.interpreter.place: Place;

    auto elementType = string_.type.toBasetype.nextOf;
    const length = string_.numberOfCodeUnits + 1;
    auto storage = NativeBlock.allocate(
        length * typeByteSize(elementType),
        NativeBlock.Scan.no,
    );
    auto elements = NativeArray.borrow(elementType, storage.address, length);
    switch (string_.sz) {
        case wcharCodeUnitWidth:
            foreach (index; 0 .. string_.numberOfCodeUnits)
                Place(elements.element(index).ptr, elementType).storeNativeScalar(
                    cast(wchar) string_.getIndex(index),
                );
            Place(elements.element(length - 1).ptr, elementType).storeNativeScalar(
                wchar.init,
            );
            break;
        case dcharCodeUnitWidth:
            foreach (index; 0 .. string_.numberOfCodeUnits)
                Place(elements.element(index).ptr, elementType).storeNativeScalar(
                    cast(dchar) string_.getIndex(index),
                );
            Place(elements.element(length - 1).ptr, elementType).storeNativeScalar(
                dchar.init,
            );
            break;
        default:
            foreach (index; 0 .. string_.numberOfCodeUnits)
                Place(elements.element(index).ptr, elementType).storeNativeScalar(
                    cast(char) string_.getIndex(index),
                );
            Place(elements.element(length - 1).ptr, elementType).storeNativeScalar(
                char.init,
            );
    }
    return storage;
}

public T[] stringCodeUnits(T)(
    imported!"dmd.expression".StringExp string_,
) {
    auto values = new T[](string_.numberOfCodeUnits);
    foreach (index; 0 .. string_.numberOfCodeUnits)
        values[index] = cast(T) string_.getIndex(index);

    return values;
}

public char[] stringChars(
    imported!"dmd.expression".StringExp string_,
) {
    import std.utf: encode;

    size_t valuesLength;
    foreach (index; 0 .. string_.numberOfCodeUnits) {
        const codeUnit = string_.getIndex(index);
        if (string_.sz == charCodeUnitWidth)
            ++valuesLength;
        else {
            char[maxUtf8CodeUnits] encoded;
            valuesLength += encode(encoded, cast(dchar) codeUnit);
        }
    }

    auto values = new char[](valuesLength);
    size_t valuesIndex;
    foreach (index; 0 .. string_.numberOfCodeUnits) {
        const codeUnit = string_.getIndex(index);
        if (string_.sz == charCodeUnitWidth)
            values[valuesIndex++] = cast(char) codeUnit;
        else {
            char[maxUtf8CodeUnits] encoded;
            const length = encode(encoded, cast(dchar) codeUnit);
            values[valuesIndex .. valuesIndex + length] = encoded[0 .. length];
            valuesIndex += length;
        }
    }
    return values;
}

module quickbite.backends.interpreter.runtime_string_literals;

private:

private enum charCodeUnitWidth = 1;
private enum wcharCodeUnitWidth = 2;
private enum dcharCodeUnitWidth = 4;
private enum maxUtf8CodeUnits = 4;

public imported!"quickbite.backends.interpreter.runtime_value".Value stringValue(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.backends.interpreter.runtime_value: Value;

    switch (string_.sz) {
        case wcharCodeUnitWidth:
            return Value.stringValue(stringCodeUnits!wchar(string_));
        case dcharCodeUnitWidth:
            return Value.stringValue(stringCodeUnits!dchar(string_));
        default:
            return Value.stringValue(stringChars(string_));
    }
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

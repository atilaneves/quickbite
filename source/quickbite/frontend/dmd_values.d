module quickbite.frontend.dmd_values;

private:

public imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const value = integer.getInteger;
    const type = integer.type is null ? null : integer.type.toBasetype;
    if (type is null)
        return Value(cast(long) value);

    switch (type.ty) with (TY) {
        case Tbool:
            return Value(value != 0);
        case Tint8:
            return Value(cast(byte) value);
        case Tuns8:
            return Value(cast(ubyte) value);
        case Tchar:
            return Value(cast(char) value);
        case Tint16:
            return Value(cast(short) value);
        case Tuns16:
            return Value(cast(ushort) value);
        case Twchar:
            return Value(cast(wchar) value);
        case Tint32:
            return Value(cast(int) value);
        case Tuns32:
            return Value(cast(uint) value);
        case Tdchar:
            return Value(cast(dchar) value);
        case Tint64:
            return Value(cast(long) value);
        case Tuns64:
            return Value(cast(ulong) value);
        default:
            assert(0);
    }
}

public imported!"quickbite.lang".Value castIntegerValue(
    imported!"dmd.expression".IntegerExp integer,
    in imported!"dmd.astenums".TY ty,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const value = integer.getInteger;

    switch (ty) with (TY) {
        case Tbool:
            return Value(value != 0);
        case Tint8:
            return Value(cast(byte) value);
        case Tuns8:
            return Value(cast(ubyte) value);
        case Tchar:
            return Value(cast(char) value);
        case Tint16:
            return Value(cast(short) value);
        case Tuns16:
            return Value(cast(ushort) value);
        case Twchar:
            return Value(cast(wchar) value);
        case Tint32:
            return Value(cast(int) value);
        case Tuns32:
            return Value(cast(uint) value);
        case Tdchar:
            return Value(cast(dchar) value);
        case Tint64:
            return Value(cast(long) value);
        case Tuns64:
            return Value(cast(ulong) value);
        default:
            assert(0);
    }
}

public imported!"quickbite.lang".Value castSignedIntegerValue(
    in long value,
    in imported!"dmd.astenums".TY ty,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    switch (ty) with (TY) {
        case Tbool:
            return Value(value != 0);
        case Tint8:
            return Value(cast(byte) value);
        case Tuns8:
            return Value(cast(ubyte) value);
        case Tchar:
            return Value(cast(char) value);
        case Tint16:
            return Value(cast(short) value);
        case Tuns16:
            return Value(cast(ushort) value);
        case Twchar:
            return Value(cast(wchar) value);
        case Tint32:
            return Value(cast(int) value);
        case Tuns32:
            return Value(cast(uint) value);
        case Tdchar:
            return Value(cast(dchar) value);
        case Tint64:
            return Value(cast(long) value);
        case Tuns64:
            return Value(cast(ulong) value);
        default:
            assert(0);
    }
}

public imported!"quickbite.lang".Value realValue(
    imported!"dmd.expression".RealExp real_,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const type = real_.type is null ? null : real_.type.toBasetype;
    if (type is null)
        return Value(cast(real) real_.toReal);

    switch (type.ty) with (TY) {
        case Tfloat32:
            return Value(cast(float) real_.toReal);
        case Tfloat64:
            return Value(cast(double) real_.toReal);
        case Tfloat80:
            return Value(cast(real) real_.toReal);
        default:
            assert(0);
    }
}

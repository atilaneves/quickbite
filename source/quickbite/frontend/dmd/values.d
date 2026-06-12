module quickbite.frontend.dmd.values;

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

public imported!"quickbite.lang".Value defaultValue(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    if (variable.type is null)
        throw new Exception("Unsupported DMD default value.");

    return defaultValue(variable.type);
}

public imported!"quickbite.lang".Value defaultValue(
    // not `in`: DMD's `Type.toBasetype` is not const-callable
    imported!"dmd.mtype".Type variableType,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    // `auto` because DMD's static array accessors are not const-callable
    auto type = variableType.toBasetype;
    with (TY) final switch (type.ty) {
        case Tbool:
            return scalarDefaultValue!Tbool;
        case Tint8:
            return scalarDefaultValue!Tint8;
        case Tuns8:
            return scalarDefaultValue!Tuns8;
        case Tint16:
            return scalarDefaultValue!Tint16;
        case Tuns16:
            return scalarDefaultValue!Tuns16;
        case Tint32:
            return scalarDefaultValue!Tint32;
        case Tuns32:
            return scalarDefaultValue!Tuns32;
        case Tint64:
            return scalarDefaultValue!Tint64;
        case Tuns64:
            return scalarDefaultValue!Tuns64;
        case Tfloat32:
            return scalarDefaultValue!Tfloat32;
        case Tfloat64:
            return scalarDefaultValue!Tfloat64;
        case Tfloat80:
            return scalarDefaultValue!Tfloat80;
        case Tchar:
            return scalarDefaultValue!Tchar;
        case Twchar:
            return scalarDefaultValue!Twchar;
        case Tdchar:
            return scalarDefaultValue!Tdchar;
        case Tpointer:
        case Tclass:
        case Tnull:
            return Value.null_;
        case Tsarray:
            return staticArrayDefaultValue(type.isTypeSArray);
        case Tstruct:
            return structDefaultValue(type.isTypeStruct);
        case Tvoid:
        case Tint128:
        case Tuns128:
        case Timaginary32:
        case Timaginary64:
        case Timaginary80:
        case Tcomplex32:
        case Tcomplex64:
        case Tcomplex80:
        case Tfunction:
        case Tarray:
        case Taarray:
        case Tident:
        case Tinstance:
        case Ttypeof:
        case Ttuple:
        case Tslice:
        case Treturn:
        case Terror:
        case Tvector:
        case Ttraits:
        case Tmixin:
        case Tnoreturn:
        case Ttag:
        case Tenum:
        case Tdelegate:
        case Treference:
        case Tnone:
            throw new Exception("Unsupported DMD default value.");
    }
}

private imported!"quickbite.lang".Value staticArrayDefaultValue(
    imported!"dmd.mtype".TypeSArray staticArray,
) {
    import quickbite.lang: Value;

    const length = cast(size_t) staticArray.dim.toInteger;

    Value[] elements;
    foreach (_; 0 .. length)
        elements ~= defaultValue(staticArray.nextOf);

    return Value.arrayValue(elements);
}

private imported!"quickbite.lang".Value structDefaultValue(
    imported!"dmd.mtype".TypeStruct structType,
) {
    import quickbite.lang: Value;

    if (structType is null || structType.sym is null)
        throw new Exception("Unsupported DMD default value.");

    const typeName = structType.sym.ident is null
        ? ""
        : structType.sym.ident.toString.idup;

    Value[] fields;
    foreach (field; structType.sym.fields)
        fields ~= defaultValue(field.type);

    return Value.structValue(typeName, fields);
}

private imported!"quickbite.lang".Value scalarDefaultValue(
    imported!"dmd.astenums".TY type,
)() {
    import quickbite.frontend.dmd.types: dmdScalarType;
    import quickbite.lang: Value;

    alias T = dmdScalarType!type;
    return Value(T.init);
}

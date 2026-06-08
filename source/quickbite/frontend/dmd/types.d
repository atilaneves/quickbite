module quickbite.frontend.dmd.types;

private:

public bool isIntegralExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (expression is null || expression.type is null)
        return false;

    return isIntegralType(expression.type);
}

public bool isIntegralType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto basetype = type.toBasetype;
    if (basetype is null)
        return false;

    with (TY) switch (basetype.ty) {
        case Tbool:
        case Tchar:
        case Twchar:
        case Tdchar:
            return false;
        default:
            return basetype.isIntegral;
    }
}

public template dmdScalarType(imported!"dmd.astenums".TY type) {
    import dmd.astenums: TY;

    static if (type == TY.Tbool)
        alias dmdScalarType = bool;
    else static if (type == TY.Tint8)
        alias dmdScalarType = byte;
    else static if (type == TY.Tuns8)
        alias dmdScalarType = ubyte;
    else static if (type == TY.Tint16)
        alias dmdScalarType = short;
    else static if (type == TY.Tuns16)
        alias dmdScalarType = ushort;
    else static if (type == TY.Tint32)
        alias dmdScalarType = int;
    else static if (type == TY.Tuns32)
        alias dmdScalarType = uint;
    else static if (type == TY.Tint64)
        alias dmdScalarType = long;
    else static if (type == TY.Tuns64)
        alias dmdScalarType = ulong;
    else static if (type == TY.Tfloat32)
        alias dmdScalarType = float;
    else static if (type == TY.Tfloat64)
        alias dmdScalarType = double;
    else static if (type == TY.Tfloat80)
        alias dmdScalarType = real;
    else static if (type == TY.Tchar)
        alias dmdScalarType = char;
    else static if (type == TY.Twchar)
        alias dmdScalarType = wchar;
    else static if (type == TY.Tdchar)
        alias dmdScalarType = dchar;
    else
        static assert(false, "Unsupported DMD scalar type.");
}

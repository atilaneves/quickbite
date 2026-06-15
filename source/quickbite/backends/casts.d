module quickbite.backends.casts;

private:

public enum CastTarget: size_t {
    bool_,
    byte_,
    ubyte_,
    char_,
    short_,
    ushort_,
    wchar_,
    int_,
    uint_,
    dchar_,
    long_,
    ulong_,
    float_,
    double_,
    real_,
    ifloat_,
    idouble_,
    ireal_,
    cfloat_,
    cdouble_,
    creal_,
}
public CastTarget castTarget(imported!"dmd.mtype".Type type) {
    CastTarget target;
    if (tryCastTarget(type, target))
        return target;

    import std.conv: text;
    throw new Exception(text("Unsupported cast target: ", type.toBasetype.ty));
}

public bool tryCastTarget(
    imported!"dmd.mtype".Type type,
    out CastTarget target,
) {
    import dmd.astenums: TY;

    const basetype = type.toBasetype;
    switch (basetype.ty) with (TY) {
        case Tbool:
            target = CastTarget.bool_;
            return true;
        case Tint8:
            target = CastTarget.byte_;
            return true;
        case Tuns8:
            target = CastTarget.ubyte_;
            return true;
        case Tchar:
            target = CastTarget.char_;
            return true;
        case Tint16:
            target = CastTarget.short_;
            return true;
        case Tuns16:
            target = CastTarget.ushort_;
            return true;
        case Twchar:
            target = CastTarget.wchar_;
            return true;
        case Tint32:
            target = CastTarget.int_;
            return true;
        case Tuns32:
            target = CastTarget.uint_;
            return true;
        case Tdchar:
            target = CastTarget.dchar_;
            return true;
        case Tint64:
            target = CastTarget.long_;
            return true;
        case Tuns64:
            target = CastTarget.ulong_;
            return true;
        case Tfloat32:
            target = CastTarget.float_;
            return true;
        case Tfloat64:
            target = CastTarget.double_;
            return true;
        case Tfloat80:
            target = CastTarget.real_;
            return true;
        case Timaginary32:
            target = CastTarget.ifloat_;
            return true;
        case Timaginary64:
            target = CastTarget.idouble_;
            return true;
        case Timaginary80:
            target = CastTarget.ireal_;
            return true;
        case Tcomplex32:
            target = CastTarget.cfloat_;
            return true;
        case Tcomplex64:
            target = CastTarget.cdouble_;
            return true;
        case Tcomplex80:
            target = CastTarget.creal_;
            return true;
        default:
            return false;
    }
}

public imported!"quickbite.lang".Value castValue(
    in imported!"quickbite.lang".Value value,
    in CastTarget target,
) {
    final switch (target) with (CastTarget) {
        case bool_:
            return value.castTo!bool;
        case byte_:
            return value.castTo!byte;
        case ubyte_:
            return value.castTo!ubyte;
        case char_:
            return value.castTo!char;
        case short_:
            return value.castTo!short;
        case ushort_:
            return value.castTo!ushort;
        case wchar_:
            return value.castTo!wchar;
        case int_:
            return value.castTo!int;
        case uint_:
            return value.castTo!uint;
        case dchar_:
            return value.castTo!dchar;
        case long_:
            return value.castTo!long;
        case ulong_:
            return value.castTo!ulong;
        case float_:
            return value.castTo!float;
        case double_:
            return value.castTo!double;
        case real_:
            return value.castTo!real;
        case ifloat_:
        case idouble_:
        case ireal_:
            return value.castToImaginary;
        case cfloat_:
        case cdouble_:
        case creal_:
            return value.castToComplex;
    }
}

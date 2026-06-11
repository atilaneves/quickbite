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
}
public CastTarget castTarget(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    const basetype = type.toBasetype;
    switch (basetype.ty) with (TY) {
        case Tbool:
            return CastTarget.bool_;
        case Tint8:
            return CastTarget.byte_;
        case Tuns8:
            return CastTarget.ubyte_;
        case Tchar:
            return CastTarget.char_;
        case Tint16:
            return CastTarget.short_;
        case Tuns16:
            return CastTarget.ushort_;
        case Twchar:
            return CastTarget.wchar_;
        case Tint32:
            return CastTarget.int_;
        case Tuns32:
            return CastTarget.uint_;
        case Tdchar:
            return CastTarget.dchar_;
        case Tint64:
            return CastTarget.long_;
        case Tuns64:
            return CastTarget.ulong_;
        case Tfloat32:
            return CastTarget.float_;
        case Tfloat64:
            return CastTarget.double_;
        case Tfloat80:
            return CastTarget.real_;
        default:
            import std.conv: text;
            throw new Exception(text("Unsupported cast target: ", basetype.ty));
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
    }
}

module quickbite.backends.interpreter.runtime_casts;

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

    auto basetype = type.toBasetype;
    if (auto enumType = basetype.isTypeEnum)
        basetype = enumType.toBasetype2;

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

public void castValue(
    imported!"quickbite.backends.interpreter.place".Place source,
    in CastTarget target,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    switch (source.type.toBasetype.ty) with (TY) {
        case Tbool: return castNativeValue(source.loadNativeScalar!bool, target, destination);
        case Tint8: return castNativeValue(source.loadNativeScalar!byte, target, destination);
        case Tuns8: return castNativeValue(source.loadNativeScalar!ubyte, target, destination);
        case Tchar: return castNativeValue(source.loadNativeScalar!char, target, destination);
        case Tint16: return castNativeValue(source.loadNativeScalar!short, target, destination);
        case Tuns16: return castNativeValue(source.loadNativeScalar!ushort, target, destination);
        case Twchar: return castNativeValue(source.loadNativeScalar!wchar, target, destination);
        case Tint32: return castNativeValue(source.loadNativeScalar!int, target, destination);
        case Tuns32: return castNativeValue(source.loadNativeScalar!uint, target, destination);
        case Tdchar: return castNativeValue(source.loadNativeScalar!dchar, target, destination);
        case Tint64: return castNativeValue(source.loadNativeScalar!long, target, destination);
        case Tuns64: return castNativeValue(source.loadNativeScalar!ulong, target, destination);
        case Tfloat32: return castNativeValue(source.loadNativeScalar!float, target, destination);
        case Tfloat64: return castNativeValue(source.loadNativeScalar!double, target, destination);
        case Tfloat80: return castNativeValue(source.loadNativeScalar!real, target, destination);
        case Timaginary32: return castNativeValue(source.loadNativeScalar!ifloat, target, destination);
        case Timaginary64: return castNativeValue(source.loadNativeScalar!idouble, target, destination);
        case Timaginary80: return castNativeValue(source.loadNativeScalar!ireal, target, destination);
        case Tcomplex32: return castNativeValue(source.loadNativeScalar!cfloat, target, destination);
        case Tcomplex64: return castNativeValue(source.loadNativeScalar!cdouble, target, destination);
        case Tcomplex80: return castNativeValue(source.loadNativeScalar!creal, target, destination);
        default:
            throw new Exception("Unsupported scalar cast source.");
    }
}

private void castNativeValue(T)(
    in T value,
    in CastTarget target,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    final switch (target) with (CastTarget) {
        case bool_:
            destination.storeNativeScalar(cast(bool) value);
            return;
        case byte_:
            destination.storeNativeScalar(cast(byte) value);
            return;
        case ubyte_:
            destination.storeNativeScalar(cast(ubyte) value);
            return;
        case char_:
            destination.storeNativeScalar(cast(char) value);
            return;
        case short_:
            destination.storeNativeScalar(cast(short) value);
            return;
        case ushort_:
            destination.storeNativeScalar(cast(ushort) value);
            return;
        case wchar_:
            destination.storeNativeScalar(cast(wchar) value);
            return;
        case int_:
            destination.storeNativeScalar(cast(int) value);
            return;
        case uint_:
            destination.storeNativeScalar(cast(uint) value);
            return;
        case dchar_:
            destination.storeNativeScalar(cast(dchar) value);
            return;
        case long_:
            destination.storeNativeScalar(cast(long) value);
            return;
        case ulong_:
            destination.storeNativeScalar(cast(ulong) value);
            return;
        case float_:
            destination.storeNativeScalar(cast(float) value);
            return;
        case double_:
            destination.storeNativeScalar(cast(double) value);
            return;
        case real_:
            destination.storeNativeScalar(cast(real) value);
            return;
        case ifloat_:
            destination.storeNativeScalar(cast(ifloat) value);
            return;
        case idouble_:
            destination.storeNativeScalar(cast(idouble) value);
            return;
        case ireal_:
            destination.storeNativeScalar(cast(ireal) value);
            return;
        case cfloat_:
            destination.storeNativeScalar(cast(cfloat) value);
            return;
        case cdouble_:
            destination.storeNativeScalar(cast(cdouble) value);
            return;
        case creal_:
            destination.storeNativeScalar(cast(creal) value);
            return;
    }
}

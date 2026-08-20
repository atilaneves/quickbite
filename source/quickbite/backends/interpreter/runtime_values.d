module quickbite.backends.interpreter.runtime_values;

private:

public void integerValue(
    imported!"dmd.expression".IntegerExp integer,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    const value = integer.getInteger;
    auto type = destination.type.toBasetype;
    switch (type.ty) with (TY) {
        case Tpointer:
            destination.storeReference(cast(void*) value);
            return;
        case Tbool:
            destination.storeNativeScalar(value != 0);
            return;
        case Tint8:
            destination.storeNativeScalar(cast(byte) value);
            return;
        case Tuns8:
            destination.storeNativeScalar(cast(ubyte) value);
            return;
        case Tchar:
            destination.storeNativeScalar(cast(char) value);
            return;
        case Tint16:
            destination.storeNativeScalar(cast(short) value);
            return;
        case Tuns16:
            destination.storeNativeScalar(cast(ushort) value);
            return;
        case Twchar:
            destination.storeNativeScalar(cast(wchar) value);
            return;
        case Tint32:
            destination.storeNativeScalar(cast(int) value);
            return;
        case Tuns32:
            destination.storeNativeScalar(cast(uint) value);
            return;
        case Tdchar:
            destination.storeNativeScalar(cast(dchar) value);
            return;
        case Tint64:
            destination.storeNativeScalar(cast(long) value);
            return;
        case Tuns64:
            destination.storeNativeScalar(cast(ulong) value);
            return;
        default:
            throw new Exception(
                "quickbite.backends.interpreter.runtime_values: "
                ~ "integer literal needs a scalar destination",
            );
    }
}

public void realValue(
    imported!"dmd.expression".RealExp real_,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    auto type = destination.type.toBasetype;
    switch (type.ty) with (TY) {
        case Tfloat32:
            destination.storeNativeScalar(cast(float) real_.toReal);
            return;
        case Tfloat64:
            destination.storeNativeScalar(cast(double) real_.toReal);
            return;
        case Tfloat80:
            destination.storeNativeScalar(cast(real) real_.toReal);
            return;
        case Timaginary32:
            destination.storeNativeScalar(cast(float) real_.toImaginary);
            return;
        case Timaginary64:
            destination.storeNativeScalar(cast(double) real_.toImaginary);
            return;
        case Timaginary80:
            destination.storeNativeScalar(cast(real) real_.toImaginary);
            return;
        default:
            throw new Exception(
                "quickbite.backends.interpreter.runtime_values: "
                ~ "real literal needs a real or imaginary destination",
            );
    }
}

// Construct a type's ordinary `.init` directly in caller-owned native
// storage. Structs and static arrays recurse through their typed places, so
// they do not first become a transient aggregate result. A union has one
// storage region: D initializes its first declared member and leaves every
// sibling as an overlapping view of those same bytes.
public void defaultValue(
    // not `in`: DMD's `Type.toBasetype` is not const-callable
    imported!"dmd.mtype".Type variableType,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.place_value: clearPlace;

    auto type = variableType.toBasetype;
    with (TY) final switch (type.ty) {
        case Tbool:
            destination.storeNativeScalar(bool.init);
            return;
        case Tint8:
            destination.storeNativeScalar(byte.init);
            return;
        case Tuns8:
            destination.storeNativeScalar(ubyte.init);
            return;
        case Tint16:
            destination.storeNativeScalar(short.init);
            return;
        case Tuns16:
            destination.storeNativeScalar(ushort.init);
            return;
        case Tint32:
            destination.storeNativeScalar(int.init);
            return;
        case Tuns32:
            destination.storeNativeScalar(uint.init);
            return;
        case Tint64:
            destination.storeNativeScalar(long.init);
            return;
        case Tuns64:
            destination.storeNativeScalar(ulong.init);
            return;
        case Tfloat32:
            destination.storeNativeScalar(float.init);
            return;
        case Tfloat64:
            destination.storeNativeScalar(double.init);
            return;
        case Tfloat80:
            destination.storeNativeScalar(real.init);
            return;
        case Tchar:
            destination.storeNativeScalar(char.init);
            return;
        case Twchar:
            destination.storeNativeScalar(wchar.init);
            return;
        case Tdchar:
            destination.storeNativeScalar(dchar.init);
            return;
        case Tpointer:
        case Tclass:
        case Taarray:
            destination.storeReference(null);
            return;
        case Tnull:
        case Tdelegate:
            // A default is constructed only in fresh storage, so a null
            // callable has no out-of-band callable metadata to preserve.
            clearPlace(destination);
            return;
        case Tsarray:
            auto staticArray = type.isTypeSArray;
            foreach (index; 0 .. cast(size_t) staticArray.dim.toInteger)
                defaultValue(staticArray.nextOf, destination.index(index));
            return;
        case Tstruct:
            auto structType = type.isTypeStruct;
            if (structType is null || structType.sym is null)
                throw new Exception("Unsupported DMD default value.");

            foreach (index, field; structType.sym.fields) {
                if (index != 0 && structType.sym.isUnionDeclaration !is null)
                    break;
                defaultValue(field.type, destination.field(field));
            }
            return;
        case Tarray:
            AggregateValue.initializeArray(destination, 0);
            return;
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
        case Treference:
        case Tnone:
            throw new Exception("Unsupported DMD default value.");
    }
}

// Creates an owned native value for an expression path that has no final
// destination yet. The caller can read it at its typed place, but default
// construction itself never selects a result arm.
public imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate defaultValueOwner(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
    import quickbite.backends.interpreter.place: Place;

    auto owner = NativeAggregate.allocate(type);
    defaultValue(type, Place(owner.address, type));
    return owner;
}

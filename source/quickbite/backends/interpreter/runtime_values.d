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

public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult castIntegerValue(
    imported!"dmd.expression".IntegerExp integer,
    in imported!"dmd.astenums".TY ty,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    const value = integer.getInteger;

    switch (ty) with (TY) {
        case Tbool:
            return ExpressionResult(value != 0);
        case Tint8:
            return ExpressionResult(cast(byte) value);
        case Tuns8:
            return ExpressionResult(cast(ubyte) value);
        case Tchar:
            return ExpressionResult(cast(char) value);
        case Tint16:
            return ExpressionResult(cast(short) value);
        case Tuns16:
            return ExpressionResult(cast(ushort) value);
        case Twchar:
            return ExpressionResult(cast(wchar) value);
        case Tint32:
            return ExpressionResult(cast(int) value);
        case Tuns32:
            return ExpressionResult(cast(uint) value);
        case Tdchar:
            return ExpressionResult(cast(dchar) value);
        case Tint64:
            return ExpressionResult(cast(long) value);
        case Tuns64:
            return ExpressionResult(cast(ulong) value);
        default:
            assert(0);
    }
}

public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult castSignedIntegerValue(
    in long value,
    in imported!"dmd.astenums".TY ty,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    switch (ty) with (TY) {
        case Tbool:
            return ExpressionResult(value != 0);
        case Tint8:
            return ExpressionResult(cast(byte) value);
        case Tuns8:
            return ExpressionResult(cast(ubyte) value);
        case Tchar:
            return ExpressionResult(cast(char) value);
        case Tint16:
            return ExpressionResult(cast(short) value);
        case Tuns16:
            return ExpressionResult(cast(ushort) value);
        case Twchar:
            return ExpressionResult(cast(wchar) value);
        case Tint32:
            return ExpressionResult(cast(int) value);
        case Tuns32:
            return ExpressionResult(cast(uint) value);
        case Tdchar:
            return ExpressionResult(cast(dchar) value);
        case Tint64:
            return ExpressionResult(cast(long) value);
        case Tuns64:
            return ExpressionResult(cast(ulong) value);
        default:
            assert(0);
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

public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult defaultValue(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    if (variable.type is null)
        throw new Exception("Unsupported DMD default value.");

    return defaultValue(variable.type);
}

public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult defaultValue(
    // not `in`: DMD's `Type.toBasetype` is not const-callable
    imported!"dmd.mtype".Type variableType,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

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
            return ExpressionResult.null_;
        case Tdelegate:
            return ExpressionResult.null_;
        case Tsarray:
            return staticArrayDefaultValue(type.isTypeSArray);
        case Tstruct:
            return structDefaultValue(type.isTypeStruct);
        case Tarray:
            return AggregateValue.reconstructArray(variableType, []);
        case Taarray:
            return ExpressionResult.null_;
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

// Construct a type's ordinary `.init` directly in caller-owned native
// storage. Structs and static arrays recurse through their typed places, so
// they do not first become an aggregate ExpressionResult. A union has one
// storage region: D initializes its first declared member and leaves every
// sibling as an overlapping view of those same bytes.
public void defaultValue(
    // not `in`: DMD's `Type.toBasetype` is not const-callable
    imported!"dmd.mtype".Type variableType,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import quickbite.backends.interpreter.place_value: writeValue;

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
            writeValue(destination, ExpressionResult.null_);
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
            // Preserve the existing dynamic-array default construction until
            // its carrier path has its own destination migration.
            writeValue(destination, defaultValue(variableType));
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

private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult staticArrayDefaultValue(
    imported!"dmd.mtype".TypeSArray staticArray,
) {
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
    import quickbite.backends.interpreter.place: placeAt;

    auto aggregate = NativeAggregate.allocate(staticArray);
    defaultValue(staticArray, placeAt(aggregate.storage, staticArray));
    return ExpressionResult.nativeAggregateValue(aggregate);
}

private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult structDefaultValue(
    imported!"dmd.mtype".TypeStruct structType,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
    import quickbite.backends.interpreter.place: Place;

    if (structType is null || structType.sym is null)
        throw new Exception("Unsupported DMD default value.");

    auto aggregate = NativeAggregate.allocate(structType);
    defaultValue(structType, Place(aggregate.address, structType));
    return ExpressionResult.nativeAggregateValue(aggregate);
}

private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult scalarDefaultValue(
    imported!"dmd.astenums".TY type,
)() {
    import quickbite.frontend.dmd.types: dmdScalarType;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    alias T = dmdScalarType!type;
    return ExpressionResult(T.init);
}

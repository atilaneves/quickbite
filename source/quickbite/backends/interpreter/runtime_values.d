module quickbite.backends.interpreter.runtime_values;

private:

public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult integerValue(
    imported!"dmd.expression".IntegerExp integer,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    const value = integer.getInteger;
    const type = integer.type is null ? null : integer.type.toBasetype;
    if (type is null)
        return ExpressionResult(cast(long) value);

    switch (type.ty) with (TY) {
        // A pointer-typed integer constant (e.g. a `cast(T*) size_t.max`
        // sentinel like Phobos' TempCStringBuffer.useStack): a native pointer
        // holding the address, so comparisons against it behave like
        // compiled D.
        case Tpointer:
            return ExpressionResult.pointerValue(cast(void*) value);
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

public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult realValue(
    imported!"dmd.expression".RealExp real_,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    const type = real_.type is null ? null : real_.type.toBasetype;
    if (type is null)
        return ExpressionResult(cast(real) real_.toReal);

    switch (type.ty) with (TY) {
        case Tfloat32:
            return ExpressionResult(cast(float) real_.toReal);
        case Tfloat64:
            return ExpressionResult(cast(double) real_.toReal);
        case Tfloat80:
            return ExpressionResult(cast(real) real_.toReal);
        case Timaginary32:
        case Timaginary64:
        case Timaginary80:
            return ExpressionResult.imaginaryValue(cast(real) real_.toImaginary);
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
        default:
            throw new Exception(
                "quickbite.backends.interpreter.runtime_values: "
                ~ "real literal needs a real scalar destination",
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

private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult staticArrayDefaultValue(
    imported!"dmd.mtype".TypeSArray staticArray,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import quickbite.backends.interpreter.scratch_array: releaseScratchArray;

    const length = cast(size_t) staticArray.dim.toInteger;

    auto elements = new ExpressionResult[](length);
    scope(exit) releaseScratchArray(elements);
    foreach (index; 0 .. length)
        elements[index] = defaultValue(staticArray.nextOf);

    return AggregateValue.reconstructArray(staticArray, elements);
}

private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult structDefaultValue(
    imported!"dmd.mtype".TypeStruct structType,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import quickbite.backends.interpreter.scratch_array: releaseScratchArray;

    if (structType is null || structType.sym is null)
        throw new Exception("Unsupported DMD default value.");

    auto fields = new ExpressionResult[](structType.sym.fields.length);
    scope(exit) releaseScratchArray(fields);
    foreach (index, field; structType.sym.fields)
        fields[index] = defaultValue(field.type);

    return AggregateValue.reconstructStruct(structType, fields);
}

private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult scalarDefaultValue(
    imported!"dmd.astenums".TY type,
)() {
    import quickbite.frontend.dmd.types: dmdScalarType;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    alias T = dmdScalarType!type;
    return ExpressionResult(T.init);
}

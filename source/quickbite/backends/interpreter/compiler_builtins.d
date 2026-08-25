module quickbite.backends.interpreter.compiler_builtins;

private:

// DMD assigns builtin identity during semantic analysis. Execute any builtin
// whose complete call signature has a native scalar representation through
// DMD's one builtin operation. The Interpreter does not classify function
// names or carry a second operation list.
package bool isExecutableCompilerBuiltin(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.builtin: isBuiltin;
    import dmd.func: BUILTIN;

    if (function_ is null || function_.type is null)
        return false;

    const builtin = isBuiltin(function_);
    with (BUILTIN) switch (builtin) {
        case unknown:
            assert(0, "isBuiltin returned an unresolved builtin identity");
        case unimp:
        case gcc:
        case llvm:
            return false;
        default:
            break;
    }

    if (!isBuiltinScalarType(function_.type.nextOf))
        return false;

    if (function_.parameters is null)
        return true;

    foreach (parameter; *function_.parameters)
        if (!isBuiltinScalarType(parameter.type))
            return false;

    return true;
}

package void executeCompilerBuiltin(
    imported!"dmd.location".Loc location,
    imported!"dmd.func".FuncDeclaration function_,
    scope imported!"quickbite.backends.interpreter.place".Place[] operands,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.arraytypes: Expressions;
    import dmd.builtin: eval_builtin;

    Expressions arguments = Expressions(operands.length);
    foreach (index, operand; operands)
        arguments[index] = builtinArgument(location, operand);

    auto result = eval_builtin(location, function_, &arguments);
    if (result is null)
        throw new Exception("DMD declined an executable compiler builtin.");

    storeBuiltinResult(result, destination);
}

private bool isBuiltinScalarType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type is null)
        return false;

    with (TY) switch (type.toBasetype.ty) {
        case Tbool:
        case Tint8:
        case Tuns8:
        case Tchar:
        case Tint16:
        case Tuns16:
        case Twchar:
        case Tint32:
        case Tuns32:
        case Tdchar:
        case Tint64:
        case Tuns64:
        case Tfloat32:
        case Tfloat64:
        case Tfloat80:
        case Timaginary32:
        case Timaginary64:
        case Timaginary80:
        case Tcomplex32:
        case Tcomplex64:
        case Tcomplex80:
            return true;
        default:
            return false;
    }
}

private imported!"dmd.expression".Expression builtinArgument(
    imported!"dmd.location".Loc location,
    imported!"quickbite.backends.interpreter.place".Place operand,
) {
    import dmd.astenums: TY;
    import dmd.expression: ComplexExp, IntegerExp, RealExp;
    import dmd.globals: dinteger_t;
    import dmd.root.complex: complex_t;
    import dmd.root.ctfloat: real_t;

    with (TY) switch (operand.type.toBasetype.ty) {
        case Tbool:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!bool,
                operand.type,
            );
        case Tint8:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!byte,
                operand.type,
            );
        case Tuns8:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!ubyte,
                operand.type,
            );
        case Tchar:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!char,
                operand.type,
            );
        case Tint16:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!short,
                operand.type,
            );
        case Tuns16:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!ushort,
                operand.type,
            );
        case Twchar:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!wchar,
                operand.type,
            );
        case Tint32:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!int,
                operand.type,
            );
        case Tuns32:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!uint,
                operand.type,
            );
        case Tdchar:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!dchar,
                operand.type,
            );
        case Tint64:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!long,
                operand.type,
            );
        case Tuns64:
            return new IntegerExp(
                location,
                cast(dinteger_t) operand.loadNativeScalar!ulong,
                operand.type,
            );
        case Tfloat32:
            return new RealExp(
                location,
                real_t(operand.loadNativeScalar!float),
                operand.type,
            );
        case Tfloat64:
            return new RealExp(
                location,
                real_t(operand.loadNativeScalar!double),
                operand.type,
            );
        case Tfloat80:
            return new RealExp(
                location,
                real_t(operand.loadNativeScalar!real),
                operand.type,
            );
        case Timaginary32:
            return new RealExp(
                location,
                real_t(operand.loadNativeScalar!ifloat.im),
                operand.type,
            );
        case Timaginary64:
            return new RealExp(
                location,
                real_t(operand.loadNativeScalar!idouble.im),
                operand.type,
            );
        case Timaginary80:
            return new RealExp(
                location,
                real_t(operand.loadNativeScalar!ireal.im),
                operand.type,
            );
        case Tcomplex32:
            auto value = operand.loadNativeScalar!cfloat;
            return new ComplexExp(
                location,
                complex_t(real_t(value.re), real_t(value.im)),
                operand.type,
            );
        case Tcomplex64:
            auto value = operand.loadNativeScalar!cdouble;
            return new ComplexExp(
                location,
                complex_t(real_t(value.re), real_t(value.im)),
                operand.type,
            );
        case Tcomplex80:
            auto value = operand.loadNativeScalar!creal;
            return new ComplexExp(
                location,
                complex_t(real_t(value.re), real_t(value.im)),
                operand.type,
            );
        default:
            assert(0, "compiler builtin operand is not a native scalar");
    }
}

private void storeBuiltinResult(
    imported!"dmd.expression".Expression result,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    with (TY) switch (destination.type.toBasetype.ty) {
        case Tbool: storeIntegerResult!bool(result, destination); return;
        case Tint8: storeIntegerResult!byte(result, destination); return;
        case Tuns8: storeIntegerResult!ubyte(result, destination); return;
        case Tchar: storeIntegerResult!char(result, destination); return;
        case Tint16: storeIntegerResult!short(result, destination); return;
        case Tuns16: storeIntegerResult!ushort(result, destination); return;
        case Twchar: storeIntegerResult!wchar(result, destination); return;
        case Tint32: storeIntegerResult!int(result, destination); return;
        case Tuns32: storeIntegerResult!uint(result, destination); return;
        case Tdchar: storeIntegerResult!dchar(result, destination); return;
        case Tint64: storeIntegerResult!long(result, destination); return;
        case Tuns64: storeIntegerResult!ulong(result, destination); return;
        case Tfloat32: storeRealResult!float(result, destination); return;
        case Tfloat64: storeRealResult!double(result, destination); return;
        case Tfloat80: storeRealResult!real(result, destination); return;
        case Timaginary32: storeImaginaryResult!ifloat(result, destination); return;
        case Timaginary64: storeImaginaryResult!idouble(result, destination); return;
        case Timaginary80: storeImaginaryResult!ireal(result, destination); return;
        case Tcomplex32: storeComplexResult!cfloat(result, destination); return;
        case Tcomplex64: storeComplexResult!cdouble(result, destination); return;
        case Tcomplex80: storeComplexResult!creal(result, destination); return;
        default:
            assert(0, "compiler builtin result is not a native scalar");
    }
}

private void storeIntegerResult(T)(
    imported!"dmd.expression".Expression result,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    auto integer = result.isIntegerExp;
    if (integer is null)
        throw new Exception("DMD returned a non-integral compiler builtin result.");
    destination.storeNativeScalar(cast(T) integer.getInteger);
}

private void storeRealResult(T)(
    imported!"dmd.expression".Expression result,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    auto real_ = result.isRealExp;
    if (real_ is null)
        throw new Exception("DMD returned a non-real compiler builtin result.");
    destination.storeNativeScalar(cast(T) real_.toReal);
}

private void storeImaginaryResult(T)(
    imported!"dmd.expression".Expression result,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    auto real_ = result.isRealExp;
    if (real_ is null)
        throw new Exception("DMD returned a non-imaginary compiler builtin result.");
    destination.storeNativeScalar(cast(T) real_.toImaginary);
}

private void storeComplexResult(T)(
    imported!"dmd.expression".Expression result,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    auto complex_ = result.isComplexExp;
    if (complex_ is null)
        throw new Exception("DMD returned a non-complex compiler builtin result.");
    const value = complex_.toComplex;
    const native = cast(T) (
        cast(real) value.re + cast(real) value.im * 1i
    );
    destination.storeNativeScalar(native);
}

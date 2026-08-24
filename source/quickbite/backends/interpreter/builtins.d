module quickbite.backends.interpreter.builtins;

private:

package enum InterpreterBuiltin: size_t {
    fabs,
    pow,
    sqrt,
}

package bool tryInterpreterBuiltin(
    imported!"dmd.func".FuncDeclaration function_,
    out InterpreterBuiltin builtin,
) {
    import dmd.builtin: isBuiltin;
    import dmd.func: BUILTIN;

    if (function_ is null)
        return false;

    with (BUILTIN) switch (isBuiltin(function_)) {
        case fabs:
            builtin = InterpreterBuiltin.fabs;
            return true;

        case pow:
            builtin = InterpreterBuiltin.pow;
            return true;

        case sqrt:
            builtin = InterpreterBuiltin.sqrt;
            return true;

        default:
            return false;
    }
}

package size_t interpreterBuiltinArgumentCount(
    in InterpreterBuiltin builtin,
) @safe pure nothrow @nogc {
    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
        case sqrt:
            return 1;

        case pow:
            return 2;
    }
}

package void unaryBuiltinCall(
    in InterpreterBuiltin builtin,
    imported!"quickbite.backends.interpreter.place".Place value,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import std.math: mathFabs = fabs, mathSqrt = sqrt;

    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
            storeUnaryFloatingResult!mathFabs(value, destination);
            return;

        case sqrt:
            storeUnaryFloatingResult!mathSqrt(value, destination);
            return;

        case pow:
            break;
    }

    throw new Exception("Unsupported interpreter unary builtin call.");
}

package void binaryBuiltinCall(
    in InterpreterBuiltin builtin,
    imported!"quickbite.backends.interpreter.place".Place lhs,
    imported!"quickbite.backends.interpreter.place".Place rhs,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import std.math: mathPow = pow;

    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
        case sqrt:
            break;

        case pow:
            storeBinaryFloatingResult!mathPow(lhs, rhs, destination);
            return;
    }

    throw new Exception("Unsupported interpreter binary builtin call.");
}

private void storeUnaryFloatingResult(alias operation, T)(
    T value,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    with (TY) switch (destination.type.toBasetype.ty) {
        case Tfloat32:
            destination.storeNativeScalar(operation(
                cast(float) floatingValue(value),
            ));
            return;

        case Tfloat64:
            destination.storeNativeScalar(operation(
                cast(double) floatingValue(value),
            ));
            return;

        case Tfloat80:
            destination.storeNativeScalar(operation(floatingValue(value)));
            return;

        default:
            throw new Exception("Unsupported unary floating result type.");
    }
}

private real floatingValue(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    import dmd.astenums: TY;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tfloat32:
            return value.loadNativeScalar!float;
        case Tfloat64:
            return value.loadNativeScalar!double;
        case Tfloat80:
            return value.loadNativeScalar!real;
        default:
            throw new Exception("Unsupported builtin floating operand type.");
    }
}

private void storeBinaryFloatingResult(alias operation, L, R)(
    L lhs,
    R rhs,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    with (TY) switch (destination.type.toBasetype.ty) {
        case Tfloat32:
            destination.storeNativeScalar(cast(float) operation(
                cast(float) floatingValue(lhs),
                cast(float) floatingValue(rhs),
            ));
            return;

        case Tfloat64:
            destination.storeNativeScalar(cast(double) operation(
                cast(double) floatingValue(lhs),
                cast(double) floatingValue(rhs),
            ));
            return;

        case Tfloat80:
            destination.storeNativeScalar(operation(
                floatingValue(lhs),
                floatingValue(rhs),
            ));
            return;

        default:
            throw new Exception("Unsupported binary floating result type.");
    }
}

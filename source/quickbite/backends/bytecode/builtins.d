module quickbite.backends.bytecode.builtins;

private:

package enum BytecodeBuiltin: size_t {
    fabs,
    isNaN,
    pow,
    sqrt,
}

package BytecodeBuiltin bytecodeBuiltin(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.builtin: isBuiltin;
    import dmd.func: BUILTIN;

    if (function_ is null)
        throw new Exception("Unsupported bytecode call target.");

    with (BUILTIN) switch (isBuiltin(function_)) {
        case fabs:
            return BytecodeBuiltin.fabs;

        case isnan:
            return BytecodeBuiltin.isNaN;

        case pow:
            return BytecodeBuiltin.pow;

        case sqrt:
            return BytecodeBuiltin.sqrt;

        default:
            break;
    }

    throw new Exception("Unsupported bytecode call target.");
}

package size_t bytecodeBuiltinArgumentCount(
    in BytecodeBuiltin builtin,
) @safe pure nothrow @nogc {
    with (BytecodeBuiltin) final switch (builtin) {
        case fabs:
            return 1;

        case isNaN:
            return 1;

        case pow:
            return 2;

        case sqrt:
            return 1;
    }
}

package imported!"quickbite.lang".Value unaryBuiltinCall(
    in BytecodeBuiltin builtin,
    in imported!"quickbite.lang".Value value,
) {
    import std.math: mathFabs = fabs;
    import std.math: mathIsNaN = isNaN;
    import std.math: mathSqrt = sqrt;

    with (BytecodeBuiltin) final switch (builtin) {
        case fabs:
            return value.unaryFloating!mathFabs;

        case isNaN:
            return value.unaryFloating!mathIsNaN;

        case pow:
            break;

        case sqrt:
            return value.unaryFloating!mathSqrt;
    }

    throw new Exception("Unsupported bytecode unary builtin call.");
}

package imported!"quickbite.lang".Value binaryBuiltinCall(
    in BytecodeBuiltin builtin,
    in imported!"quickbite.lang".Value lhs,
    in imported!"quickbite.lang".Value rhs,
) {
    import std.math: mathPow = pow;

    with (BytecodeBuiltin) final switch (builtin) {
        case fabs:
            break;

        case isNaN:
            break;

        case pow:
            return lhs.binaryFloating!mathPow(rhs);

        case sqrt:
            break;
    }

    throw new Exception("Unsupported bytecode binary builtin call.");
}

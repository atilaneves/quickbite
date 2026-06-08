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

package imported!"quickbite.lang".Value unaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.lang".Value value,
) {
    import std.math: mathFabs = fabs;
    import std.math: mathSqrt = sqrt;

    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
            return value.unaryFloating!mathFabs;

        case sqrt:
            return value.unaryFloating!mathSqrt;

        case pow:
            break;
    }

    throw new Exception("Unsupported interpreter unary builtin call.");
}

package imported!"quickbite.lang".Value binaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.lang".Value lhs,
    in imported!"quickbite.lang".Value rhs,
) {
    import std.math: mathPow = pow;

    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
        case sqrt:
            break;

        case pow:
            return lhs.binaryFloating!mathPow(rhs);
    }

    throw new Exception("Unsupported interpreter binary builtin call.");
}

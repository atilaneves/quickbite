module quickbite.backends.bytecode.builtins;

private:

package enum BytecodeBuiltin: size_t {
    fabs,
    pow,
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

        case pow:
            return BytecodeBuiltin.pow;

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

        case pow:
            return 2;
    }
}

package imported!"quickbite.lang".Value unaryBuiltinCall(
    in BytecodeBuiltin builtin,
    in imported!"quickbite.lang".Value value,
) {
    import std.math: mathFabs = fabs;

    with (BytecodeBuiltin) final switch (builtin) {
        case fabs:
            return value.unaryFloating!mathFabs;

        case pow:
            break;
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

        case pow:
            return lhs.binaryFloating!mathPow(rhs);
    }

    throw new Exception("Unsupported bytecode binary builtin call.");
}

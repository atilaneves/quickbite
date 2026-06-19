module quickbite.backends.bytecode.builtins;

private:

package enum BytecodeBuiltin: size_t {
    fabs,
    isInfinity,
    isNaN,
    pow,
    signbit,
    sqrt,
}

package BytecodeBuiltin bytecodeBuiltin(
    imported!"dmd.func".FuncDeclaration function_,
) {
    BytecodeBuiltin builtin;
    if (tryBytecodeBuiltin(function_, builtin))
        return builtin;

    throw new Exception("Unsupported bytecode call target.");
}

package bool tryBytecodeBuiltin(
    imported!"dmd.func".FuncDeclaration function_,
    out BytecodeBuiltin builtin,
    ) {
        import dmd.builtin: isBuiltin;
        import dmd.func: BUILTIN;

    if (function_ is null)
        return false;

    with (BUILTIN) switch (isBuiltin(function_)) {
        case fabs:
            builtin = BytecodeBuiltin.fabs;
            return true;

        case isinfinity:
            builtin = BytecodeBuiltin.isInfinity;
            return true;

        case isnan:
            builtin = BytecodeBuiltin.isNaN;
            return true;

        case pow:
            builtin = BytecodeBuiltin.pow;
            return true;

        case sqrt:
            builtin = BytecodeBuiltin.sqrt;
            return true;

        default:
            break;
    }

    if (isStdMathTraitsFunction(
            function_,
            "isInfinity",
            "_D3std4math6traits__T10isInfinity",
        )) {
        builtin = BytecodeBuiltin.isInfinity;
        return true;
    }

    if (isStdMathTraitsFunction(
            function_,
            "isNaN",
            "_D3std4math6traits__T5isNaN",
        )) {
        builtin = BytecodeBuiltin.isNaN;
        return true;
    }

    if (function_.ident !is null && function_.ident.toString == "signbit") {
        builtin = BytecodeBuiltin.signbit;
        return true;
    }

    return false;
}

private bool isStdMathTraitsFunction(
    imported!"dmd.func".FuncDeclaration function_,
    in string identifier,
    in string manglePrefix,
) {
    import dmd.mangle: mangleExact;
    import std.string: fromStringz, startsWith;

    return function_.ident !is null &&
        function_.ident.toString == identifier &&
        mangleExact(function_).fromStringz.startsWith(manglePrefix);
}

package size_t bytecodeBuiltinArgumentCount(
    in BytecodeBuiltin builtin,
) @safe pure nothrow @nogc {
    with (BytecodeBuiltin) final switch (builtin) {
        case fabs:
            return 1;

        case isInfinity:
            return 1;

        case isNaN:
            return 1;

        case pow:
            return 2;

        case signbit:
            return 1;

        case sqrt:
            return 1;
    }
}

package imported!"quickbite.lang".Value unaryBuiltinCall(
    in BytecodeBuiltin builtin,
    in imported!"quickbite.lang".Value value,
) {
    import std.math: mathFabs = fabs;
    import std.math: mathIsInfinity = isInfinity;
    import std.math: mathIsNaN = isNaN;
    import std.math: mathSignbit = signbit;
    import std.math: mathSqrt = sqrt;

    with (BytecodeBuiltin) final switch (builtin) {
        case fabs:
            return value.unaryFloating!mathFabs;

        case isInfinity:
            return value.unaryFloating!mathIsInfinity;

        case isNaN:
            return value.unaryFloating!mathIsNaN;

        case pow:
            break;

        case signbit:
            return value.unaryFloating!mathSignbit;

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

        case isInfinity:
            break;

        case isNaN:
            break;

        case pow:
            return lhs.binaryFloating!mathPow(rhs);

        case signbit:
            break;

        case sqrt:
            break;
    }

    throw new Exception("Unsupported bytecode binary builtin call.");
}

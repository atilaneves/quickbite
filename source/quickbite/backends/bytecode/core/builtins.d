module quickbite.backends.bytecode.core.builtins;

private:

package enum BytecodeBuiltin: size_t {
    fabs,
    isInfinity,
    isNaN,
    pow,
    signbit,
    sqrt,
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

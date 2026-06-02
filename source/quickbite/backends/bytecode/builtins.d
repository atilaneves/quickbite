module quickbite.backends.bytecode.builtins;

private:

// Mirrors DMD's useful CTFE builtin set in dmd.func.BUILTIN. DMD's
// unknown/unimp/gcc/llvm sentinels are intentionally not bytecode builtins.
package enum BytecodeBuiltin: size_t {
    sin,
    cos,
    tan,
    sqrt,
    fabs,
    ldexp,
    log,
    log2,
    log10,
    exp,
    expm1,
    exp2,
    round,
    floor,
    ceil,
    trunc,
    copysign,
    pow,
    fmin,
    fmax,
    fma,
    isnan,
    isinfinity,
    isfinite,
    bsf,
    bsr,
    bswap,
    popcnt,
    yl2x,
    yl2xp1,
    toPrecFloat,
    toPrecDouble,
    toPrecReal,
    ctfeWrite,
}

package BytecodeBuiltin bytecodeBuiltin(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.builtin: isBuiltin;

    if (function_ is null)
        throw new Exception("Unsupported bytecode call target.");

    return bytecodeBuiltinFromDmd(isBuiltin(function_));
}

package bool bytecodeBuiltinIsImplemented(
    in BytecodeBuiltin builtin,
) @safe pure nothrow @nogc {
    with (BytecodeBuiltin) switch (builtin) {
        static foreach (implemented; implementedBuiltinNames) {
            mixin("case " ~ implemented ~ ": return true;");
        }

        default:
            return false;
    }
}

package size_t bytecodeBuiltinArgumentCount(
    in BytecodeBuiltin builtin,
) {
    with (BytecodeBuiltin) switch (builtin) {
        static foreach (implemented; implementedBuiltinNames) {
            mixin("case " ~ implemented ~
                ": return stdMathBuiltinArgumentCount!implemented;");
        }
        default:
            break;
    }

    throw new Exception("Unsupported bytecode builtin.");
}

package imported!"quickbite.lang".Value unaryBuiltinCall(
    in BytecodeBuiltin builtin,
    in imported!"quickbite.lang".Value value,
) {
    import quickbite.lang: Value;

    with (BytecodeBuiltin) switch (builtin) {
        static foreach (implemented; implementedBuiltinNames) {
            static if (stdMathBuiltinArgumentCount!implemented == 1) {
                mixin("case " ~ implemented ~
                    ": return value.unaryFloating!(stdMathBuiltin!implemented);");
            }
        }

        default:
            break;
    }

    throw new Exception("Unsupported bytecode unary builtin call.");
}

package imported!"quickbite.lang".Value binaryBuiltinCall(
    in BytecodeBuiltin builtin,
    in imported!"quickbite.lang".Value lhs,
    in imported!"quickbite.lang".Value rhs,
) {
    import quickbite.lang: Value;

    with (BytecodeBuiltin) switch (builtin) {
        static foreach (implemented; implementedBuiltinNames) {
            static if (stdMathBuiltinArgumentCount!implemented == 2) {
                mixin("case " ~ implemented ~
                    ": return lhs.binaryFloating!(stdMathBuiltin!implemented)(rhs);");
            }
        }

        default:
            break;
    }

    throw new Exception("Unsupported bytecode binary builtin call.");
}

private BytecodeBuiltin bytecodeBuiltinFromDmd(
    in imported!"dmd.func".BUILTIN builtin,
) {
    import dmd.func: BUILTIN;

    with (BUILTIN) final switch (builtin) {
        static foreach (member; bytecodeBuiltinNames) {
            mixin("case " ~ member ~ ": return BytecodeBuiltin." ~ member ~ ";");
        }
        case unknown:
        case unimp:
        case gcc:
        case llvm:
            break;
    }

    throw new Exception("Unsupported bytecode call target.");
}

private enum implementedBuiltinNames = [
    "fabs",
    "pow",
];

private enum bytecodeBuiltinNames = [
    "sin",
    "cos",
    "tan",
    "sqrt",
    "fabs",
    "ldexp",
    "log",
    "log2",
    "log10",
    "exp",
    "expm1",
    "exp2",
    "round",
    "floor",
    "ceil",
    "trunc",
    "copysign",
    "pow",
    "fmin",
    "fmax",
    "fma",
    "isnan",
    "isinfinity",
    "isfinite",
    "bsf",
    "bsr",
    "bswap",
    "popcnt",
    "yl2x",
    "yl2xp1",
    "toPrecFloat",
    "toPrecDouble",
    "toPrecReal",
    "ctfeWrite",
];

private template stdMathBuiltin(string name) {
    mixin(
        "import std.math: " ~ name ~ ";",
        "alias stdMathBuiltin = " ~ name ~ ";",
    );
}

private template stdMathBuiltinArgumentCount(string name) {
    import std.math;

    mixin(
        "enum acceptsOneArgument = __traits(compiles, " ~
            name ~ "(1.0L));",
        "enum acceptsTwoArguments = __traits(compiles, " ~
            name ~ "(1.0L, 2.0L));",
    );

    static if (acceptsOneArgument) {
        enum stdMathBuiltinArgumentCount = 1;
    } else static if (acceptsTwoArguments) {
        enum stdMathBuiltinArgumentCount = 2;
    } else {
        static assert(false, "Unsupported std.math builtin arity: " ~ name);
    }
}

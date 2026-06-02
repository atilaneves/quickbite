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
        case fabs:
        case pow:
            return true;

        default:
            return false;
    }
}

package size_t bytecodeBuiltinArgumentCount(
    in BytecodeBuiltin builtin,
) {
    with (BytecodeBuiltin) switch (builtin) {
        case fabs:
            return 1;

        case pow:
            return 2;

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
        case fabs:
            import std.math: fabs;

            return value.unaryFloating!fabs;

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
        case pow:
            import std.math: pow;

            return lhs.binaryFloating!pow(rhs);

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
        case sin:
            return BytecodeBuiltin.sin;
        case cos:
            return BytecodeBuiltin.cos;
        case tan:
            return BytecodeBuiltin.tan;
        case sqrt:
            return BytecodeBuiltin.sqrt;
        case fabs:
            return BytecodeBuiltin.fabs;
        case ldexp:
            return BytecodeBuiltin.ldexp;
        case log:
            return BytecodeBuiltin.log;
        case log2:
            return BytecodeBuiltin.log2;
        case log10:
            return BytecodeBuiltin.log10;
        case exp:
            return BytecodeBuiltin.exp;
        case expm1:
            return BytecodeBuiltin.expm1;
        case exp2:
            return BytecodeBuiltin.exp2;
        case round:
            return BytecodeBuiltin.round;
        case floor:
            return BytecodeBuiltin.floor;
        case ceil:
            return BytecodeBuiltin.ceil;
        case trunc:
            return BytecodeBuiltin.trunc;
        case copysign:
            return BytecodeBuiltin.copysign;
        case pow:
            return BytecodeBuiltin.pow;
        case fmin:
            return BytecodeBuiltin.fmin;
        case fmax:
            return BytecodeBuiltin.fmax;
        case fma:
            return BytecodeBuiltin.fma;
        case isnan:
            return BytecodeBuiltin.isnan;
        case isinfinity:
            return BytecodeBuiltin.isinfinity;
        case isfinite:
            return BytecodeBuiltin.isfinite;
        case bsf:
            return BytecodeBuiltin.bsf;
        case bsr:
            return BytecodeBuiltin.bsr;
        case bswap:
            return BytecodeBuiltin.bswap;
        case popcnt:
            return BytecodeBuiltin.popcnt;
        case yl2x:
            return BytecodeBuiltin.yl2x;
        case yl2xp1:
            return BytecodeBuiltin.yl2xp1;
        case toPrecFloat:
            return BytecodeBuiltin.toPrecFloat;
        case toPrecDouble:
            return BytecodeBuiltin.toPrecDouble;
        case toPrecReal:
            return BytecodeBuiltin.toPrecReal;
        case ctfeWrite:
            return BytecodeBuiltin.ctfeWrite;
        case unknown:
        case unimp:
        case gcc:
        case llvm:
            break;
    }

    throw new Exception("Unsupported bytecode call target.");
}

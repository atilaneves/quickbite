module quickbite.backends.interpreter.builtins;

private:

package enum AssocArrayHook {
    length,
    getRvalue,
    getLvalue,
    in_,
    remove,
    equal,
    dup,
    keys,
    values,
    apply2,
}

// DMD lowers associative array operations to druntime template hooks in
// `core.internal.newaa` and `object`; the interpreter handles the semantics
// at the call site instead of executing the druntime hook bodies.
package bool tryAssocArrayHook(
    imported!"dmd.func".FuncDeclaration function_,
    out AssocArrayHook hook,
) {
    import std.algorithm: startsWith;
    import std.algorithm.searching: canFind;
    import std.conv: text;

    if (function_ is null)
        return false;

    const name = text(function_.toPrettyChars);
    if (name.canFind("_d_aaApply2!(")) {
        hook = AssocArrayHook.apply2;
        return true;
    }

    if (function_.parent is null || function_.parent.isTemplateInstance is null)
        return false;

    static struct Hook {
        string prefix;
        AssocArrayHook hook;
    }

    static immutable hooks = [
        Hook("core.internal.newaa._d_aaLen!(", AssocArrayHook.length),
        Hook("core.internal.newaa._d_aaGetRvalueX!(", AssocArrayHook.getRvalue),
        Hook("core.internal.newaa._d_aaGetY!(", AssocArrayHook.getLvalue),
        Hook("core.internal.newaa._d_aaIn!(", AssocArrayHook.in_),
        Hook("core.internal.newaa._d_aaDel!(", AssocArrayHook.remove),
        Hook("core.internal.newaa._d_aaEqual!(", AssocArrayHook.equal),
        Hook("object.dup!(", AssocArrayHook.dup),
        Hook("object.keys!(", AssocArrayHook.keys),
        Hook("object.values!(", AssocArrayHook.values),
    ];

    foreach (candidate; hooks) {
        if (name.startsWith(candidate.prefix)) {
            hook = candidate.hook;
            return true;
        }
    }

    return false;
}

package enum InterpreterBuiltin: size_t {
    fabs,
    isInfinity,
    pow,
    signbit,
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

        case isinfinity:
            builtin = InterpreterBuiltin.isInfinity;
            return true;

        case pow:
            builtin = InterpreterBuiltin.pow;
            return true;

        case sqrt:
            builtin = InterpreterBuiltin.sqrt;
            return true;

        default:
            break;
    }

    if (function_.ident !is null && function_.ident.toString == "signbit") {
        builtin = InterpreterBuiltin.signbit;
        return true;
    }

    return false;
}

package size_t interpreterBuiltinArgumentCount(
    in InterpreterBuiltin builtin,
) @safe pure nothrow @nogc {
    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
        case isInfinity:
        case signbit:
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
    import std.math: mathIsInfinity = isInfinity;
    import std.math: mathSignbit = signbit;
    import std.math: mathSqrt = sqrt;

    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
            return value.unaryFloating!mathFabs;

        case isInfinity:
            return value.unaryFloating!mathIsInfinity;

        case signbit:
            return value.unaryFloating!mathSignbit;

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
        case isInfinity:
        case signbit:
        case sqrt:
            break;

        case pow:
            return lhs.binaryFloating!mathPow(rhs);
    }

    throw new Exception("Unsupported interpreter binary builtin call.");
}

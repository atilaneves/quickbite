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

package enum AtomicHook {
    load,
    store,
    exchange,
    fetchAdd,
    fetchSub,
    aligned,
}

// core.internal.atomic implements these primitives as inline asm the
// interpreter cannot execute; interpretation is single-threaded, so plain
// reads and writes of the pointed-at value at the call site are observably
// equivalent.
package bool tryAtomicHook(
    imported!"dmd.func".FuncDeclaration function_,
    out AtomicHook hook,
) {
    import std.algorithm: startsWith;
    import std.conv: text;

    if (function_ is null)
        return false;

    if (function_.parent is null || function_.parent.isTemplateInstance is null)
        return false;

    const name = text(function_.toPrettyChars);

    static struct Hook {
        string prefix;
        AtomicHook hook;
    }

    static immutable hooks = [
        Hook("core.internal.atomic.atomicLoad!(", AtomicHook.load),
        Hook("core.internal.atomic.atomicStore!(", AtomicHook.store),
        Hook("core.internal.atomic.atomicExchange!(", AtomicHook.exchange),
        Hook("core.internal.atomic.atomicFetchAdd!(", AtomicHook.fetchAdd),
        Hook("core.internal.atomic.atomicFetchSub!(", AtomicHook.fetchSub),
        // Alignment asserts cast the pointer to size_t; interpreter values
        // have no numeric address and are always properly aligned. A single
        // template argument prints without parens, so match up to the `!`.
        Hook("core.atomic.atomicValueIsProperlyAligned!", AtomicHook.aligned),
        Hook("core.atomic.atomicPtrIsProperlyAligned!", AtomicHook.aligned),
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

package bool isStdConvText(imported!"dmd.func".FuncDeclaration function_) {
    if (function_ is null || function_.ident is null)
        return false;

    auto module_ = function_.getModule;
    if (module_ is null || module_.md is null)
        return false;

    const declaration = module_.md;
    return
        function_.ident.toString == "text" &&
        declaration.id !is null &&
        declaration.id.toString == "conv" &&
        declaration.packages.length == 1 &&
        declaration.packages[0] !is null &&
        declaration.packages[0].toString == "std";
}

package imported!"quickbite.backends.interpreter.runtime_value".Value stdConvTextCall(
    in imported!"quickbite.backends.interpreter.runtime_value".Value[] arguments,
    in bool[] rawStringArguments,
    imported!"dmd.mtype".Type resultType,
) @safe {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    string rendered;
    foreach (index, ref argument; arguments)
        rendered ~= stdConvTextArgument(argument, rawStringArguments[index]);

    Value[] characters;
    foreach (character; rendered)
        characters ~= Value(character);
    return AggregateValue.reconstructArray(resultType, characters);
}

private string stdConvTextArgument(
    in imported!"quickbite.backends.interpreter.runtime_value".Value argument,
    in bool rawStringArgument,
) @safe {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;

    // `rawStringArgument` comes from the original D expression type; after
    // evaluation, `char[]` is only a Value array, but `std.conv.text` renders
    // it as string text instead of an element range.
    if (AggregateValue.isArray(argument)) {
        if (rawStringArgument) {
            char[] result;
            foreach (index; 0 .. AggregateValue.elementCount(argument))
                result ~= AggregateValue.elementAt(argument, index)
                    .asUtf8Character;
            return result.idup;
        }
        return nativeArrayText(argument);
    }

    return argument.dText;
}


private string nativeArrayText(
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) @safe {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;

    string result = "[";
    foreach (index; 0 .. AggregateValue.elementCount(value)) {
        if (index)
            result ~= ", ";
        const element = AggregateValue.elementAt(value, index);
        result ~= AggregateValue.isArray(element)
            ? nativeArrayText(element)
            : element.dText;
    }
    return result ~ "]";
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

package imported!"quickbite.backends.interpreter.runtime_value".Value unaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
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

package imported!"quickbite.backends.interpreter.runtime_value".Value binaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.backends.interpreter.runtime_value".Value lhs,
    in imported!"quickbite.backends.interpreter.runtime_value".Value rhs,
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

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

    if (function_.ident is null)
        return false;

    switch (function_.ident.toString) {
        case "_d_aaApply2":
        case "_d_aaLen":
        case "_d_aaGetRvalueX":
        case "_d_aaGetY":
        case "_d_aaIn":
        case "_d_aaDel":
        case "_d_aaEqual":
        case "dup":
        case "keys":
        case "values":
            break;

        default:
            return false;
    }

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
            if (candidate.hook == AssocArrayHook.dup &&
                !hasAssocArrayParameterOrReturn(function_))
                return false;
            hook = candidate.hook;
            return true;
        }
    }

    return false;
}

private bool hasAssocArrayParameterOrReturn(
    imported!"dmd.func".FuncDeclaration function_,
) {
    auto signature = function_.type is null
        ? null
        : function_.type.toBasetype.isTypeFunction;
    if (signature is null)
        return false;
    if (signature.next !is null &&
        signature.next.toBasetype.isTypeAArray !is null)
        return true;
    if (signature.parameterList.parameters !is null)
        foreach (parameter; *signature.parameterList.parameters)
            if (parameter.type !is null &&
                parameter.type.toBasetype.isTypeAArray !is null)
                return true;
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

    if (function_.ident is null)
        return false;

    switch (function_.ident.toString) {
        case "atomicLoad":
        case "atomicStore":
        case "atomicExchange":
        case "atomicFetchAdd":
        case "atomicFetchSub":
        case "atomicValueIsProperlyAligned":
        case "atomicPtrIsProperlyAligned":
            break;

        default:
            return false;
    }

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

package imported!"quickbite.backends.interpreter.expression_result".ExpressionResult stdConvTextCall(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult[] arguments,
    imported!"dmd.mtype".Type[] argumentTypes,
    imported!"dmd.mtype".Type resultType,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    string rendered;
    foreach (index, ref argument; arguments)
        rendered ~= stdConvTextArgument(argument, argumentTypes[index]);

    ExpressionResult[] characters;
    foreach (character; rendered)
        characters ~= ExpressionResult(character);
    return AggregateValue.reconstructArray(resultType, characters);
}

private string stdConvTextArgument(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult argument,
    imported!"dmd.mtype".Type argumentType,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.frontend.dmd.types: isCharacterArrayType;

    // ExpressionResult intentionally carries no display metadata. The original
    // expression type supplies std.conv.text's scalar and array rendering
    // rules at this consumer.
    if (AggregateValue.isArray(argument)) {
        if (isCharacterArrayType(argumentType)) {
            char[] result;
            foreach (index; 0 .. AggregateValue.elementCount(argument))
                result ~= AggregateValue.elementAt(argument, index)
                    .asUtf8Character;
            return result.idup;
        }
        return nativeArrayText(argument, argumentType);
    }

    return scalarText(argument, argumentType);
}


private string nativeArrayText(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    imported!"dmd.mtype".Type type,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;

    auto elementType = type.toBasetype.nextOf;
    string result = "[";
    foreach (index; 0 .. AggregateValue.elementCount(value)) {
        if (index)
            result ~= ", ";
        const element = AggregateValue.elementAt(value, index);
        result ~= AggregateValue.isArray(element)
            ? nativeArrayText(element, elementType)
            : scalarText(element, elementType);
    }
    return result ~ "]";
}


private string scalarText(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import std.conv: text;

    if (value == ExpressionResult.null_)
        return "null";
    if (value.isEnumScalar)
        return value.enumName;
    if (value.isImaginaryScalar)
        return text(value.imaginaryPart, "i");
    if (value.isComplexScalar)
        return text(
            value.complexRealPart.asReal,
            "+",
            value.complexImaginaryPart.asReal,
            "i",
        );
    if (value.isTypeName)
        return value.asTypeNameString;
    if (value.isFunctionPointer)
        return text("<function pointer ", value.functionPointerId, ">");
    if (value.isPointer)
        return text(value.pointerAddress);
    if (value.isNativeDelegate)
        return text(value.nativeDelegateFuncptr);
    if (value.isNativeAggregate)
        return "<native aggregate>";

    switch (type.toBasetype.ty) with (TY) {
        case Tbool:
            return text(value == ExpressionResult(true));
        case Tchar, Twchar, Tdchar:
            return value.asUtf8Character;
        case Tint8, Tint16, Tint32, Tint64:
            return text(value.asLong);
        case Tuns8, Tuns16, Tuns32, Tuns64:
            return text(value.asUnsignedLong);
        case Tfloat32:
            return text(cast(float) value.asReal);
        case Tfloat64:
            return text(cast(double) value.asReal);
        case Tfloat80:
            return text(value.asReal);
        default:
            throw new Exception("Unsupported std.conv.text argument.");
    }
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

package imported!"quickbite.backends.interpreter.expression_result".ExpressionResult unaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
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

package imported!"quickbite.backends.interpreter.expression_result".ExpressionResult binaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult lhs,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult rhs,
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

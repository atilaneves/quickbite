module quickbite.backends.interpreter.builtins;

private:

// Druntime's struct-array `.dup` reaches a source-less allocator even though
// a struct without copy construction needs only an ordinary shallow element
// copy. Keep copy constructors and postblits on the D-body path, where their
// user-defined semantics remain authoritative.
package bool isBlitStructArrayDup(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.algorithm: startsWith;
    import std.conv: text;

    if (function_ is null || function_.ident is null ||
        function_.ident.toString != "dup" ||
        function_.parent is null || function_.parent.isTemplateInstance is null ||
        !text(function_.toPrettyChars).startsWith("object.dup!("))
        return false;

    auto signature = function_.type is null
        ? null
        : function_.type.toBasetype.isTypeFunction;
    if (signature is null || signature.next is null ||
        signature.parameterList.length != 1)
        return false;

    auto resultArray = signature.next.toBasetype.isTypeDArray;
    auto parameterType = signature.parameterList[0].type;
    auto parameterArray = parameterType is null
        ? null
        : parameterType.toBasetype.isTypeDArray;
    if (resultArray is null || parameterArray is null)
        return false;

    auto resultStruct = resultArray.next.toBasetype.isTypeStruct;
    auto parameterStruct = parameterArray.next.toBasetype.isTypeStruct;
    return resultStruct !is null && parameterStruct !is null &&
        resultStruct.sym is parameterStruct.sym &&
        !resultStruct.sym.hasCopyConstruction;
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

package void unaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import std.math: mathFabs = fabs;
    import std.math: mathIsInfinity = isInfinity;
    import std.math: mathSignbit = signbit;
    import std.math: mathSqrt = sqrt;

    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
            storeUnaryFloatingResult!mathFabs(value, destination);
            return;

        case isInfinity:
            destination.storeNativeScalar(mathIsInfinity(value.asReal));
            return;

        case signbit:
            destination.storeNativeScalar(mathSignbit(value.asReal));
            return;

        case sqrt:
            storeUnaryFloatingResult!mathSqrt(value, destination);
            return;

        case pow:
            break;
    }

    throw new Exception("Unsupported interpreter unary builtin call.");
}

package void binaryBuiltinCall(
    in InterpreterBuiltin builtin,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult lhs,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult rhs,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import std.math: mathPow = pow;

    with (InterpreterBuiltin) final switch (builtin) {
        case fabs:
        case isInfinity:
        case signbit:
        case sqrt:
            break;

        case pow:
            storeBinaryFloatingResult!mathPow(lhs, rhs, destination);
            return;
    }

    throw new Exception("Unsupported interpreter binary builtin call.");
}

// The builtin result goes directly to the caller's statically typed native
// destination. The legacy carrier remains only on the input side until the
// scalar recursive walk changes as one unit.
private void storeUnaryFloatingResult(alias operation, T)(
    in T value,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    with (TY) switch (destination.type.toBasetype.ty) {
        case Tfloat32:
            destination.storeNativeScalar(operation(cast(float) value.asReal));
            return;

        case Tfloat64:
            destination.storeNativeScalar(operation(cast(double) value.asReal));
            return;

        case Tfloat80:
            destination.storeNativeScalar(operation(value.asReal));
            return;

        default:
            throw new Exception("Unsupported unary floating result type.");
    }
}

private void storeBinaryFloatingResult(alias operation, L, R)(
    in L lhs,
    in R rhs,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    with (TY) switch (destination.type.toBasetype.ty) {
        case Tfloat32:
            destination.storeNativeScalar(cast(float) operation(
                cast(float) lhs.asReal,
                cast(float) rhs.asReal,
            ));
            return;

        case Tfloat64:
            destination.storeNativeScalar(cast(double) operation(
                cast(double) lhs.asReal,
                cast(double) rhs.asReal,
            ));
            return;

        case Tfloat80:
            destination.storeNativeScalar(operation(lhs.asReal, rhs.asReal));
            return;

        default:
            throw new Exception("Unsupported binary floating result type.");
    }
}

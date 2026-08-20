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

package void stdConvTextCall(
    scope imported!"quickbite.backends.interpreter.place".Place[] arguments,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;

    string rendered;
    foreach (argument; arguments)
        rendered ~= stdConvTextArgument(argument);

    AggregateValue.initializeArray(destination, rendered.length);
    foreach (index, character; rendered)
        destination.index(index).storeNativeScalar(character);
}

private string stdConvTextArgument(
    imported!"quickbite.backends.interpreter.place".Place argument,
) {
    import quickbite.frontend.dmd.types: isCharacterArrayType;

    // The place's DMD type and native bytes are the display input. In
    // particular, rendering a slice does not need an aggregate snapshot.
    auto type = argument.type;
    if (type.toBasetype.isTypeDArray !is null || type.toBasetype.isTypeSArray !is null) {
        if (isCharacterArrayType(type)) {
            char[] result;
            foreach (index; 0 .. argument.arrayLength)
                result ~= characterText(argument.index(index));
            return result.idup;
        }
        return nativeArrayText(argument);
    }

    return scalarText(argument);
}


private string nativeArrayText(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    string result = "[";
    foreach (index; 0 .. value.arrayLength) {
        if (index)
            result ~= ", ";
        auto element = value.index(index);
        auto elementType = element.type.toBasetype;
        result ~= elementType.isTypeDArray !is null || elementType.isTypeSArray !is null
            ? nativeArrayText(element)
            : scalarText(element);
    }
    return result ~ "]";
}


private string scalarText(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    import dmd.astenums: TY;
    import std.conv: text;

    auto type = value.type;
    if (type.toBasetype.ty == TY.Tnull)
        return "null";

    switch (type.toBasetype.ty) with (TY) {
        case Tbool:
            return text(value.loadNativeScalar!bool);
        case Tchar, Twchar, Tdchar:
            return characterText(value);
        case Tint8, Tint16, Tint32, Tint64:
            return signedText(value);
        case Tuns8, Tuns16, Tuns32, Tuns64:
            return unsignedText(value);
        case Tfloat32:
            return text(value.loadNativeScalar!float);
        case Tfloat64:
            return text(value.loadNativeScalar!double);
        case Tfloat80:
            return text(value.loadNativeScalar!real);
        case Tpointer, Tclass, Taarray:
            return value.deref.address is null ? "null" : text(value.deref.address);
        case Timaginary32, Timaginary64, Timaginary80,
            Tcomplex32, Tcomplex64, Tcomplex80:
            return imaginaryOrComplexText(value);
        default:
            return "<native aggregate>";
    }
}

// `place_value.readValue` already decodes an imaginary or complex place into
// its `ExpressionResult` category; std.conv.text's rendering only needs that
// category's parts, not a second native-layout reader.
private string imaginaryOrComplexText(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    import quickbite.backends.interpreter.place_value: readValue;
    import std.conv: text;

    auto decoded = readValue(value);
    if (decoded.isImaginaryScalar)
        return text(decoded.imaginaryPart, "i");

    return text(decoded.complexRealPart.asReal, "+", decoded.complexImaginaryPart.asReal, "i");
}

private string characterText(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    import dmd.astenums: TY;
    import std.utf: encode;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tchar:
            return [value.loadNativeScalar!char].idup;
        case Twchar:
            char[4] encoded;
            const length = encode(encoded, cast(dchar) value.loadNativeScalar!wchar);
            return encoded[0 .. length].idup;
        case Tdchar:
            char[4] encoded;
            const length = encode(encoded, value.loadNativeScalar!dchar);
            return encoded[0 .. length].idup;
        default:
            throw new Exception("std.conv.text needs a character place.");
    }
}

private string signedText(imported!"quickbite.backends.interpreter.place".Place value) {
    import dmd.astenums: TY;
    import std.conv: text;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tint8: return text(value.loadNativeScalar!byte);
        case Tint16: return text(value.loadNativeScalar!short);
        case Tint32: return text(value.loadNativeScalar!int);
        case Tint64: return text(value.loadNativeScalar!long);
        default: throw new Exception("std.conv.text needs a signed integer place.");
    }
}

private string unsignedText(imported!"quickbite.backends.interpreter.place".Place value) {
    import dmd.astenums: TY;
    import std.conv: text;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tuns8: return text(value.loadNativeScalar!ubyte);
        case Tuns16: return text(value.loadNativeScalar!ushort);
        case Tuns32: return text(value.loadNativeScalar!uint);
        case Tuns64: return text(value.loadNativeScalar!ulong);
        default: throw new Exception("std.conv.text needs an unsigned integer place.");
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
    imported!"quickbite.backends.interpreter.place".Place value,
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
            destination.storeNativeScalar(mathIsInfinity(floatingValue(value)));
            return;

        case signbit:
            destination.storeNativeScalar(mathSignbit(floatingValue(value)));
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
    imported!"quickbite.backends.interpreter.place".Place lhs,
    imported!"quickbite.backends.interpreter.place".Place rhs,
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

// Each builtin operand is an expression-specific typed temporary. The result
// goes directly to the caller's statically typed native destination.
private void storeUnaryFloatingResult(alias operation, T)(
    T value,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    with (TY) switch (destination.type.toBasetype.ty) {
        case Tfloat32:
            destination.storeNativeScalar(operation(cast(float) floatingValue(value)));
            return;

        case Tfloat64:
            destination.storeNativeScalar(operation(cast(double) floatingValue(value)));
            return;

        case Tfloat80:
            destination.storeNativeScalar(operation(floatingValue(value)));
            return;

        default:
            throw new Exception("Unsupported unary floating result type.");
    }
}

// The Place's DMD type selects the host scalar load. `real` is only the
// floating builtin's calculation type; it is not a guest-value carrier.
private real floatingValue(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    import dmd.astenums: TY;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tfloat32:
            return value.loadNativeScalar!float;
        case Tfloat64:
            return value.loadNativeScalar!double;
        case Tfloat80:
            return value.loadNativeScalar!real;
        default:
            throw new Exception("Unsupported builtin floating operand type.");
    }
}

private void storeBinaryFloatingResult(alias operation, L, R)(
    L lhs,
    R rhs,
    imported!"quickbite.backends.interpreter.place".Place destination,
) {
    import dmd.astenums: TY;

    with (TY) switch (destination.type.toBasetype.ty) {
        case Tfloat32:
            destination.storeNativeScalar(cast(float) operation(
                cast(float) floatingValue(lhs),
                cast(float) floatingValue(rhs),
            ));
            return;

        case Tfloat64:
            destination.storeNativeScalar(cast(double) operation(
                cast(double) floatingValue(lhs),
                cast(double) floatingValue(rhs),
            ));
            return;

        case Tfloat80:
            destination.storeNativeScalar(operation(floatingValue(lhs), floatingValue(rhs)));
            return;

        default:
            throw new Exception("Unsupported binary floating result type.");
    }
}

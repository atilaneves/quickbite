module quickbite.backends.interpreter.expression_result;

private:


public struct ExpressionResult {
    private alias NativeAggregate = imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate;

    private alias Data = imported!"std.sumtype".SumType!(

        Void,

        bool,

        ubyte,
        byte,
        short,
        ushort,
        int,
        uint,
        long,
        ulong,

        char,
        wchar,
        dchar,

        Null,
        float,
        double,
        real,
        ImaginaryScalar,
        ComplexScalar,

        NativeAggregate,
        Pointer,
        NativeDelegate,
        TypeName,
        FunctionPointer,
    );

    private Data data = Data(Void.init);

    public static ExpressionResult void_() @safe pure {
        return ExpressionResult(Void.init);
    }

    public static ExpressionResult null_() @safe pure {
        return ExpressionResult(Null.init);
    }

    public static ExpressionResult nativeAggregateValue(
        NativeAggregate aggregate,
    ) @safe pure {
        return ExpressionResult(aggregate);
    }

    public static ExpressionResult pointerValue(void* pointer) @safe pure {
        return ExpressionResult(Pointer(pointer));
    }

    // A delegate returned by native code: an opaque {context, funcptr} pair
    // callable through the FFI bridge (ffi.md §35.8).
    public static ExpressionResult nativeDelegateValue(
        const(void)* context,
        const(void)* funcptr,
    ) @safe pure {
        return ExpressionResult(NativeDelegate(context, funcptr));
    }

    public static ExpressionResult functionPointerValue(in size_t id) @safe pure {
        return ExpressionResult(FunctionPointer(id));
    }

    public static ExpressionResult typeName(in string name) @safe pure {
        return ExpressionResult(TypeName(name));
    }

    public static ExpressionResult complexValue(in real realPart, in real imaginaryPart) @safe pure {
        return ExpressionResult(ComplexScalar(realPart, imaginaryPart));
    }

    public static ExpressionResult imaginaryValue(in real value) @safe pure {
        return ExpressionResult(ImaginaryScalar(value));
    }

    private this(in Void value) @safe pure {
        data = Data(value);
    }

    public this(in ExpressionResult value) @safe pure {
        data = value.data;
    }

    private this(in Null value) @safe pure {
        data = Data(value);
    }

    private this(NativeAggregate value) @safe pure {
        data = Data(value);
    }

    private this(Pointer value) @safe pure {
        data = Data(value);
    }

    private this(NativeDelegate value) @safe pure {
        data = Data(value);
    }

    private this(FunctionPointer value) @safe pure {
        data = Data(value);
    }

    private this(in TypeName value) @safe pure {
        data = Data(value);
    }

    private this(in ComplexScalar value) @safe pure {
        data = Data(value);
    }

    private this(in ImaginaryScalar value) @safe pure {
        data = Data(value);
    }

    public this(T)(in T value) @safe pure
    if (
        !is(T == E[], E) &&
        !is(T == V[K], V, K) &&
        !is(T == struct)
    )
    {
        import std.traits: Unqual;

        data = Data(cast(Unqual!T) value);
    }

    public bool opEquals(in ExpressionResult other) const @safe pure {
        return data == other.data;
    }

    public string asUtf8Character() const @safe pure {
        import std.sumtype: match;
        import std.utf: encode;

        return data.match!(
            (const(char) value) => [value].idup,
            (const(wchar) value) {
                char[4] encoded;
                const length = encode(encoded, cast(dchar) value);
                return encoded[0 .. length].idup;
            },
            (const(dchar) value) {
                char[4] encoded;
                const length = encode(encoded, value);
                return encoded[0 .. length].idup;
            },
            (_) {
                throw new Exception("Expected character.");
                return null;
            },
        );
    }

    public bool isCharacter() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => true,
            (const(wchar) value) => true,
            (const(dchar) value) => true,
            (_) => false,
        );
    }

    public char asChar() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(char) value) => value,
            (_) {
                throw new Exception("Expected char.");
                return char.init;
            },
        );
    }

    public ExpressionResult castTo(T)() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias U = Unqual!(typeof(value));

                static if (
                    is(U == bool) ||
                    isSomeChar!U ||
                    isIntegral!U ||
                    isFloatingPoint!U
                ) {
                    return ExpressionResult(cast(T) value);
                } else static if (is(U == ImaginaryScalar)) {
                    return ExpressionResult(cast(T) value.value);
                } else static if (is(U == ComplexScalar)) {
                    return ExpressionResult(cast(T) value.realPart);
                } else static if (is(U == Pointer)) {
                    // `cast(ulong)ptr`/`cast(long)ptr` etc.: druntime's
                    // Throwable chaining (object.d, dip1008 scope-catch-var
                    // destructor lowering) reads `_nextInChainPtr` through
                    // this exact cast to test/clear its refcount tag bit.
                    //
                    // @trusted: a pointer-to-integer cast is `@system` only
                    // because the result COULD later be cast back to a
                    // pointer and dereferenced; this operation itself reads
                    // no memory through `value.address` -- it reinterprets
                    // an already-held address value as a same-width integer
                    // and stops there, with no dereference on either side of
                    // the cast.
                    return () @trusted {
                        return ExpressionResult(cast(T) cast(size_t) value.address);
                    }();
                } else static if (is(U == Null)) {
                    // A default-initialized pointer/class/delegate field is
                    // `Null`, not a zero-valued `Pointer`; the same
                    // pointer-to-integer cast must see it as address zero.
                    return ExpressionResult(cast(T) 0);
                } else {
                    import std.conv: text;
                    throw new Exception(
                        text("Unsupported cast to ", T.stringof, " from ", U.stringof),
                    );
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public ExpressionResult castToComplex() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias U = Unqual!(typeof(value));

                static if (
                    is(U == bool) ||
                    isSomeChar!U ||
                    isIntegral!U ||
                    isFloatingPoint!U
                ) {
                    return ExpressionResult.complexValue(cast(real) value, 0.0L);
                } else static if (is(U == ImaginaryScalar)) {
                    return ExpressionResult.complexValue(0.0L, value.value);
                } else static if (is(U == ComplexScalar)) {
                    return ExpressionResult(value);
                } else {
                    throw new Exception("Unsupported complex cast.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public ExpressionResult castToImaginary() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias U = Unqual!(typeof(value));

                static if (
                    is(U == bool) ||
                    isSomeChar!U ||
                    isIntegral!U ||
                    isFloatingPoint!U
                ) {
                    return ExpressionResult.imaginaryValue(cast(real) value);
                } else static if (is(U == ImaginaryScalar)) {
                    return ExpressionResult(value);
                } else static if (is(U == ComplexScalar)) {
                    return ExpressionResult.imaginaryValue(value.imaginaryPart);
                } else {
                    throw new Exception("Unsupported imaginary cast.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public long asLong() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isIntegral!T || isSomeChar!T || is(T == bool)) {
                    return cast(long) value;
                } else {
                    throw new Exception("Expected integer-compatible scalar.");
                    return 0L;
                }
            },
        );
    }

    public ulong asUnsignedLong() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isIntegral!T || isSomeChar!T || is(T == bool)) {
                    return cast(ulong) value;
                } else {
                    throw new Exception("Expected integer-compatible scalar.");
                    return 0UL;
                }
            },
        );
    }

    public bool isImaginaryScalar() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(ImaginaryScalar) value) => true,
            (_) => false,
        );
    }

    public real imaginaryPart() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(ImaginaryScalar) value) => value.value,
            (_) {
                throw new Exception("Expected imaginary scalar.");
                return real.nan;
            },
        );
    }

    public bool isIntegerCompatibleScalar() const @safe pure nothrow {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral, isSomeChar;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (
                    isIntegral!T ||
                    isSomeChar!T ||
                    is(T == bool)
                ) {
                    return true;
                } else {
                    return false;
                }
            },
        );
    }

    public bool isPointer() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => true,
            (_) => false,
        );
    }

    public bool isNativeAggregate() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(NativeAggregate) aggregate) => true,
            (_) => false,
        );
    }

    public NativeAggregate nativeAggregate() @safe pure {
        import std.sumtype: match;

        return data.match!(
            (NativeAggregate aggregate) => aggregate,
            (_) {
                throw new Exception("Expected native aggregate.");
                return NativeAggregate.init;
            },
        );
    }

    public const(NativeAggregate) nativeAggregate() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(NativeAggregate) aggregate) => aggregate,
            (_) {
                throw new Exception("Expected native aggregate.");
                return NativeAggregate.init;
            },
        );
    }

    public bool isFunctionPointer() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(FunctionPointer) pointer) => true,
            (_) => false,
        );
    }

    public size_t functionPointerId() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(FunctionPointer) pointer) => pointer.id,
            (_) {
                throw new Exception("Expected function pointer.");
                return size_t.init;
            },
        );
    }

    public void* pointerAddress() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => cast(void*) pointer.address,
            (const(Null) null_) => null,
            (value) {
                import std.conv: text;
                throw new Exception(
                    text("Expected pointer, not ", typeof(value).stringof),
                );
                return cast(void*) null;
            },
        );
    }

    public bool isNativeDelegate() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(NativeDelegate) delegate_) => true,
            (_) => false,
        );
    }

    public const(void)* nativeDelegateContext() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(NativeDelegate) delegate_) => delegate_.context,
            (_) {
                throw new Exception("Expected native delegate.");
                return cast(const(void)*) null;
            },
        );
    }

    public const(void)* nativeDelegateFuncptr() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(NativeDelegate) delegate_) => delegate_.funcptr,
            (_) {
                throw new Exception("Expected native delegate.");
                return cast(const(void)*) null;
            },
        );
    }

    public bool isTypeName() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(TypeName) typeName) => true,
            (_) => false,
        );
    }

    public string asTypeNameString() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(TypeName) typeName) => typeName.name,
            (_) {
                throw new Exception("Expected type name.");
                return "";
            },
        );
    }

    public ExpressionResult pointerOffsetBy(in long delta) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => ExpressionResult(Pointer(
                cast(void*) (cast(size_t) pointer.address + delta),
            )),
            // A default-initialized pointer-typed field/local is `Null`, the
            // same zero address `pointerAddress` already reads it as (e.g.
            // druntime's dip1008 Throwable chain-link arithmetic reads and
            // offsets its own default-null `_nextInChainPtr`).
            (const(Null) null_) => ExpressionResult(Pointer(cast(void*) delta)),
            (_) {
                throw new Exception("Expected pointer.");
                return ExpressionResult.void_;
            },
        );
    }

    // `pointerAddress` already reads a default-initialized (`Null`)
    // pointer-typed value as address zero; pointer comparison/difference
    // must agree so a never-assigned pointer compares/subtracts like the
    // zero-valued `Pointer` it represents.
    private bool isPointerOrNull() const @safe pure {
        return isPointer || this == ExpressionResult.null_;
    }

    public long pointerOffsetDifference(in ExpressionResult other) const @safe pure {
        if (isPointerOrNull && other.isPointerOrNull)
            return cast(long) cast(size_t) pointerAddress -
                cast(long) cast(size_t) other.pointerAddress;

        throw new Exception("Expected pointers.");
    }

    public real asReal() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (
                    isIntegral!T ||
                    is(T == bool) ||
                    isFloatingPoint!T
                ) {
                    return cast(real) value;
                } else static if (is(T == ImaginaryScalar)) {
                    return value.value;
                } else static if (is(T == ComplexScalar)) {
                    return value.realPart;
                } else {
                    throw new Exception("Expected numeric scalar.");
                    return real.nan;
                }
            },
        );
    }

    public bool isNumericScalar() const @safe pure nothrow {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (
                    isIntegral!T ||
                    is(T == bool) ||
                    isFloatingPoint!T ||
                    is(T == ImaginaryScalar) ||
                    is(T == ComplexScalar)
                ) {
                    return true;
                } else {
                    return false;
                }
            },
        );
    }

    public bool isComplexScalar() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (value) => is(typeof(value) == const(ComplexScalar)),
        );
    }

    public ExpressionResult complexRealPart() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);

                static if (is(T == const(ComplexScalar))) {
                    return ExpressionResult(value.realPart);
                } else {
                    throw new Exception("Expected complex scalar.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public ExpressionResult complexImaginaryPart() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);

                static if (is(T == const(ComplexScalar))) {
                    return ExpressionResult(value.imaginaryPart);
                } else {
                    throw new Exception("Expected complex scalar.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public ExpressionResult opBinary(string op)(in ExpressionResult rhs) const @safe pure
        if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
    {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (lhs) {
                alias L = Unqual!(typeof(lhs));

                static if (isIntegral!L) {
                    return rhs.binaryInteger!op(lhs);
                } else static if (isFloatingPoint!L) {
                    return rhs.binaryFloatingPoint!op(lhs);
                } else static if (is(L == ImaginaryScalar) || is(L == ComplexScalar)) {
                    return rhs.binaryComplex!op(lhs);
                } else {
                    throw new Exception("Unsupported binary lhs type.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public ExpressionResult opUnary(string op)() const @safe pure
        if (op == "-")
    {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isIntegral!T || isFloatingPoint!T) {
                    return ExpressionResult(cast(T) -value);
                } else {
                    throw new Exception("Unsupported unary operand type.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public ExpressionResult unaryFloating(alias operation)() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isFloatingPoint!T) {
                    return ExpressionResult(operation(cast(T) value));
                } else {
                    throw new Exception("Unsupported unary floating operand type.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    public ExpressionResult binaryFloating(alias operation)(in ExpressionResult rhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (lhs) {
                alias L = Unqual!(typeof(lhs));

                static if (isFloatingPoint!L) {
                    return rhs.data.match!(
                        (rhsValue) {
                            alias R = Unqual!(typeof(rhsValue));

                            static if (isFloatingPoint!R) {
                                return ExpressionResult(cast(L) operation(
                                    cast(L) lhs,
                                    cast(R) rhsValue,
                                ));
                            } else {
                                throw new Exception(
                                    "Unsupported binary floating rhs type.",
                                );
                                return ExpressionResult.void_;
                            }
                        },
                    );
                } else {
                    throw new Exception("Unsupported binary floating lhs type.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    private ExpressionResult binaryInteger(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (isIntegral!L && isIntegral!R) {
                    static if (op == "+")
                        return ExpressionResult(cast(L) lhs + cast(R) rhs);
                    else static if (op == "-")
                        return ExpressionResult(cast(L) lhs - cast(R) rhs);
                    else static if (op == "*")
                        return ExpressionResult(cast(L) lhs * cast(R) rhs);
                    else static if (op == "/")
                        return ExpressionResult(cast(L) lhs / cast(R) rhs);
                    else static if (op == "%")
                        return ExpressionResult(cast(L) lhs % cast(R) rhs);
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    private ExpressionResult binaryFloatingPoint(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (isFloatingPoint!L && isFloatingPoint!R) {
                    static if (op == "+")
                        return ExpressionResult(cast(L) lhs + cast(R) rhs);
                    else static if (op == "-")
                        return ExpressionResult(cast(L) lhs - cast(R) rhs);
                    else static if (op == "*")
                        return ExpressionResult(cast(L) lhs * cast(R) rhs);
                    else static if (op == "/")
                        return ExpressionResult(cast(L) lhs / cast(R) rhs);
                    else static if (op == "%")
                        return ExpressionResult(cast(L) lhs % cast(R) rhs);
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return ExpressionResult.void_;
                }
            },
        );
    }

    private ExpressionResult binaryComplex(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (
                    isIntegral!R ||
                    isFloatingPoint!R ||
                    is(R == ImaginaryScalar) ||
                    is(R == ComplexScalar)
                ) {
                    const left = complexScalar(lhs);
                    const right = complexScalar(rhs);
                    static if (op == "+")
                        return ExpressionResult(left + right);
                    else static if (op == "-")
                        return ExpressionResult(left - right);
                    else static if (op == "*")
                        return ExpressionResult(left * right);
                    else static if (op == "/")
                        return ExpressionResult(left / right);
                    else {
                        throw new Exception("Unsupported complex binary operator.");
                        return ExpressionResult.void_;
                    }
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return ExpressionResult.void_;
                }
            },
        );
    }
}


private ComplexScalar complexScalar(T)(in T value) @safe pure {
    import std.traits: Unqual;

    alias U = Unqual!T;
    static if (is(U == ComplexScalar))
        return value;
    else static if (is(U == ImaginaryScalar))
        return ComplexScalar(0.0L, value.value);
    else
        return ComplexScalar(cast(real) value, 0.0L);
}

private struct ImaginaryScalar {
    public real value;

    public this(in real value) @safe pure {
        this.value = value;
    }

}


private struct ComplexScalar {
    public real realPart;
    public real imaginaryPart;

    public this(in real realPart, in real imaginaryPart) @safe pure {
        this.realPart = realPart;
        this.imaginaryPart = imaginaryPart;
    }

    public ComplexScalar opBinary(string op)(in ComplexScalar rhs) const @safe pure
        if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        static if (op == "+")
            return ComplexScalar(
                realPart + rhs.realPart,
                imaginaryPart + rhs.imaginaryPart,
            );
        else static if (op == "-")
            return ComplexScalar(
                realPart - rhs.realPart,
                imaginaryPart - rhs.imaginaryPart,
            );
        else static if (op == "*")
            return ComplexScalar(
                realPart * rhs.realPart - imaginaryPart * rhs.imaginaryPart,
                realPart * rhs.imaginaryPart + imaginaryPart * rhs.realPart,
            );
        else
            return ComplexScalar(
                (realPart * rhs.realPart + imaginaryPart * rhs.imaginaryPart) /
                    (rhs.realPart * rhs.realPart + rhs.imaginaryPart * rhs.imaginaryPart),
                (imaginaryPart * rhs.realPart - realPart * rhs.imaginaryPart) /
                    (rhs.realPart * rhs.realPart + rhs.imaginaryPart * rhs.imaginaryPart),
            );
    }

}


private struct TypeName {
    public string name;

    public this(in string name) @safe pure {
        this.name = name;
    }

}


private struct FunctionPointer {
    public size_t id;

    public this(in size_t id) @safe pure {
        this.id = id;
    }

}


private struct Pointer {
    public void* address;
}


// A delegate returned by native code (ffi.md §35.8): the extern(D)
// {context, funcptr} pair, opaque to the backend, callable through the FFI
// bridge with the context pointer leading.
private struct NativeDelegate {
    public const(void)* context;
    public const(void)* funcptr;
}


private struct Void {}
private struct Null {}

module quickbite.backends.interpreter.runtime_value;

private:


public struct RuntimeValue {
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
        EnumValue,
        FunctionPointer,
    );

    private Data data = Data(Void.init);

    public static Value void_() @safe pure {
        return Value(Void.init);
    }

    public static Value null_() @safe pure {
        return Value(Null.init);
    }

    public static Value nativeAggregateValue(
        NativeAggregate aggregate,
    ) @safe pure {
        return Value(aggregate);
    }

    public static Value pointerValue(void* pointer) @safe pure {
        return Value(Pointer(pointer));
    }

    // A delegate returned by native code: an opaque {context, funcptr} pair
    // callable through the FFI bridge (ffi.md §35.8).
    public static Value nativeDelegateValue(
        const(void)* context,
        const(void)* funcptr,
    ) @safe pure {
        return Value(NativeDelegate(context, funcptr));
    }

    public static Value functionPointerValue(in size_t id) @safe pure {
        return Value(FunctionPointer(id));
    }

    public static Value typeName(in string name) @safe pure {
        return Value(TypeName(name));
    }

    public static Value enumValue(in string name, in long value = 0) @safe pure {
        return Value(EnumValue(name, value));
    }

    public static Value complexValue(in real realPart, in real imaginaryPart) @safe pure {
        return Value(ComplexScalar(realPart, imaginaryPart));
    }

    public static Value imaginaryValue(in real value) @safe pure {
        return Value(ImaginaryScalar(value));
    }

    private this(in Void value) @safe pure {
        data = Data(value);
    }

    public this(in Value value) @safe pure {
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

    private this(in EnumValue value) @safe pure {
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

    public bool opEquals(in Value other) const @safe pure {
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

    public Value castTo(T)() const @safe pure {
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
                    return Value(cast(T) value);
                } else static if (is(U == ImaginaryScalar)) {
                    return Value(cast(T) value.value);
                } else static if (is(U == ComplexScalar)) {
                    return Value(cast(T) value.realPart);
                } else static if (is(U == EnumValue)) {
                    return Value(cast(T) value.value);
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
                        return Value(cast(T) cast(size_t) value.address);
                    }();
                } else static if (is(U == Null)) {
                    // A default-initialized pointer/class/delegate field is
                    // `Null`, not a zero-valued `Pointer`; the same
                    // pointer-to-integer cast must see it as address zero.
                    return Value(cast(T) 0);
                } else {
                    import std.conv: text;
                    throw new Exception(
                        text("Unsupported cast to ", T.stringof, " from ", U.stringof),
                    );
                    return Value.void_;
                }
            },
        );
    }

    public Value castToComplex() const @safe pure {
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
                    return Value.complexValue(cast(real) value, 0.0L);
                } else static if (is(U == ImaginaryScalar)) {
                    return Value.complexValue(0.0L, value.value);
                } else static if (is(U == ComplexScalar)) {
                    return Value(value);
                } else {
                    throw new Exception("Unsupported complex cast.");
                    return Value.void_;
                }
            },
        );
    }

    public Value castToImaginary() const @safe pure {
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
                    return Value.imaginaryValue(cast(real) value);
                } else static if (is(U == ImaginaryScalar)) {
                    return Value(value);
                } else static if (is(U == ComplexScalar)) {
                    return Value.imaginaryValue(value.imaginaryPart);
                } else {
                    throw new Exception("Unsupported imaginary cast.");
                    return Value.void_;
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
                } else static if (is(T == EnumValue)) {
                    return value.value;
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
                } else static if (is(T == EnumValue)) {
                    return cast(ulong) value.value;
                } else {
                    throw new Exception("Expected integer-compatible scalar.");
                    return 0UL;
                }
            },
        );
    }

    public bool isEnumScalar() const @safe pure nothrow {
        import std.sumtype: match;

        return data.match!(
            (const(EnumValue) value) => true,
            (_) => false,
        );
    }

    public string enumName() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(EnumValue) value) => value.name,
            (_) {
                throw new Exception("Expected enum scalar.");
                return null;
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
                    is(T == bool) ||
                    is(T == EnumValue)
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

    public const(void)* nativeDelegateContext() const {
        import std.sumtype: match;

        return data.match!(
            (const(NativeDelegate) delegate_) => delegate_.context,
            (_) {
                throw new Exception("Expected native delegate.");
                return cast(const(void)*) null;
            },
        );
    }

    public const(void)* nativeDelegateFuncptr() const {
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

    public Value pointerOffsetBy(in long delta) const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (const(Pointer) pointer) => Value(Pointer(
                cast(void*) (cast(size_t) pointer.address + delta),
            )),
            // A default-initialized pointer-typed field/local is `Null`, the
            // same zero address `pointerAddress` already reads it as (e.g.
            // druntime's dip1008 Throwable chain-link arithmetic reads and
            // offsets its own default-null `_nextInChainPtr`).
            (const(Null) null_) => Value(Pointer(cast(void*) delta)),
            (_) {
                throw new Exception("Expected pointer.");
                return Value.void_;
            },
        );
    }

    // `pointerAddress` already reads a default-initialized (`Null`)
    // pointer-typed value as address zero; pointer comparison/difference
    // must agree so a never-assigned pointer compares/subtracts like the
    // zero-valued `Pointer` it represents.
    private bool isPointerOrNull() const @safe pure {
        return isPointer || this == Value.null_;
    }

    public bool pointerSameAllocation(in Value other) const @safe pure {
        return isPointerOrNull && other.isPointerOrNull;
    }

    public long pointerOffsetDifference(in Value other) const @safe pure {
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
                } else static if (is(T == EnumValue)) {
                    return cast(real) value.value;
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
                    is(T == EnumValue) ||
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

    public Value complexRealPart() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);

                static if (is(T == const(ComplexScalar))) {
                    return Value(value.realPart);
                } else {
                    throw new Exception("Expected complex scalar.");
                    return Value.void_;
                }
            },
        );
    }

    public Value complexImaginaryPart() const @safe pure {
        import std.sumtype: match;

        return data.match!(
            (value) {
                alias T = typeof(value);

                static if (is(T == const(ComplexScalar))) {
                    return Value(value.imaginaryPart);
                } else {
                    throw new Exception("Expected complex scalar.");
                    return Value.void_;
                }
            },
        );
    }

    public Value opBinary(string op)(in Value rhs) const @safe pure
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
                    return Value.void_;
                }
            },
        );
    }

    public Value opUnary(string op)() const @safe pure
        if (op == "-")
    {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint, isIntegral;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isIntegral!T || isFloatingPoint!T) {
                    return Value(cast(T) -value);
                } else {
                    throw new Exception("Unsupported unary operand type.");
                    return Value.void_;
                }
            },
        );
    }

    public Value unaryFloating(alias operation)() const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (value) {
                alias T = Unqual!(typeof(value));

                static if (isFloatingPoint!T) {
                    return Value(operation(cast(T) value));
                } else {
                    throw new Exception("Unsupported unary floating operand type.");
                    return Value.void_;
                }
            },
        );
    }

    public Value binaryFloating(alias operation)(in Value rhs) const @safe pure {
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
                                return Value(cast(L) operation(
                                    cast(L) lhs,
                                    cast(R) rhsValue,
                                ));
                            } else {
                                throw new Exception(
                                    "Unsupported binary floating rhs type.",
                                );
                                return Value.void_;
                            }
                        },
                    );
                } else {
                    throw new Exception("Unsupported binary floating lhs type.");
                    return Value.void_;
                }
            },
        );
    }

    private Value binaryInteger(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isIntegral;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (isIntegral!L && isIntegral!R) {
                    static if (op == "+")
                        return Value(cast(L) lhs + cast(R) rhs);
                    else static if (op == "-")
                        return Value(cast(L) lhs - cast(R) rhs);
                    else static if (op == "*")
                        return Value(cast(L) lhs * cast(R) rhs);
                    else static if (op == "/")
                        return Value(cast(L) lhs / cast(R) rhs);
                    else static if (op == "%")
                        return Value(cast(L) lhs % cast(R) rhs);
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return Value.void_;
                }
            },
        );
    }

    private Value binaryFloatingPoint(string op, L)(const L lhs) const @safe pure {
        import std.sumtype: match;
        import std.traits: Unqual, isFloatingPoint;

        return data.match!(
            (rhs) {
                alias R = Unqual!(typeof(rhs));

                static if (isFloatingPoint!L && isFloatingPoint!R) {
                    static if (op == "+")
                        return Value(cast(L) lhs + cast(R) rhs);
                    else static if (op == "-")
                        return Value(cast(L) lhs - cast(R) rhs);
                    else static if (op == "*")
                        return Value(cast(L) lhs * cast(R) rhs);
                    else static if (op == "/")
                        return Value(cast(L) lhs / cast(R) rhs);
                    else static if (op == "%")
                        return Value(cast(L) lhs % cast(R) rhs);
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return Value.void_;
                }
            },
        );
    }

    private Value binaryComplex(string op, L)(const L lhs) const @safe pure {
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
                        return Value(left + right);
                    else static if (op == "-")
                        return Value(left - right);
                    else static if (op == "*")
                        return Value(left * right);
                    else static if (op == "/")
                        return Value(left / right);
                    else {
                        throw new Exception("Unsupported complex binary operator.");
                        return Value.void_;
                    }
                } else {
                    throw new Exception("Unsupported binary rhs type.");
                    return Value.void_;
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

// Kept while the walker migration still uses the historical local spelling.
// This alias is interpreter-private: no shared `quickbite.lang.Value`
// implementation participates in execution.
public alias Value = RuntimeValue;


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


private struct EnumValue {
    public string name;
    public long value;

    public this(in string name, in long value) @safe pure {
        this.name = name;
        this.value = value;
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

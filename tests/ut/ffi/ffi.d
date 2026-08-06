module ut.ffi.ffi;


import dmd.astenums: LINK;
import dmd.mtype: ParameterList, Type, TypeDArray, TypeDelegate, TypeFunction;
import quickbite.ffi.ffi: Callable, CompilerAbi, TypedAddress, call;
import unit_threaded;


@("ffi.addressOnlyExternCScalarCall")
unittest {
    int lhs = 4;
    int rhs = 7;
    int result;

    call(
        Callable(cast(void*) &encodeArguments, LINK.c, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
    ).should == true;

    result.should == 47;
}


@("ffi.callableCompilerAbiControlsExternDArgumentOrder")
unittest {
    callEncoding(cast(void*) &encodeArguments, LINK.c, CompilerAbi.dmd)
        .should == 47;
    callEncoding(cast(void*) &encodeArguments, LINK.c, CompilerAbi.ldc)
        .should == 47;

    callEncoding(cast(void*) &encodeArguments, LINK.d, CompilerAbi.dmd)
        .should == 74;
    callEncoding(cast(void*) &encodeArguments, LINK.d, CompilerAbi.ldc)
        .should == 47;

    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    callEncoding(cast(void*) &encodeArgumentsD, LINK.d, hostCompilerAbi)
        .should == 47;
}


@("ffi.addressOnlyVoidPointerCall")
unittest {
    import core.stdc.stdlib: free;

    void* pointer;

    call(
        Callable(cast(void*) &free, LINK.c, CompilerAbi.dmd),
        [TypedAddress(Type.tvoidptr, &pointer)],
        TypedAddress(Type.tvoid, null),
    ).should == true;
}


@("ffi.addressOnlyIntegralAndCharacterCalls")
unittest {
    assertScalarRoundTrip(true, Type.tbool);
    assertScalarRoundTrip(cast(byte) -101, Type.tint8);
    assertScalarRoundTrip(cast(ubyte) 241, Type.tuns8);
    assertScalarRoundTrip(cast(char) 0xe7, Type.tchar);
    assertScalarRoundTrip(cast(short) -30_001, Type.tint16);
    assertScalarRoundTrip(cast(ushort) 60_001, Type.tuns16);
    assertScalarRoundTrip(cast(wchar) 0xf123, Type.twchar);
    assertScalarRoundTrip(-2_000_000_001, Type.tint32);
    assertScalarRoundTrip(4_000_000_001U, Type.tuns32);
    assertScalarRoundTrip(cast(dchar) 0x1f642, Type.tdchar);
    assertScalarRoundTrip(-8_000_000_000_000_001L, Type.tint64);
    assertScalarRoundTrip(16_000_000_000_000_001UL, Type.tuns64);
}


@("ffi.addressOnlyFloatingPointCallsPreserveNativePrecision")
unittest {
    assertFloatingPointCall(cast(float) 1.25, Type.tfloat32);
    assertFloatingPointCall(cast(double) 1.25, Type.tfloat64);

    real extendedPrecision = real.max / 2;
    const rounded = roundToDouble(extendedPrecision);
    assert(extendedPrecision != cast(real) rounded);
    assertFloatingPointCall(extendedPrecision, Type.tfloat80);
}


@("ffi.addressOnlyNativeDescriptorsPassUntouched")
unittest {
    int[] array = [3, 5, 7];
    const originalArrayLength = array.length;
    // `const` would also qualify the pointed-to backing storage.
    auto originalArrayPointer = array.ptr;
    int[] arrayResult;
    // TypedAddress intentionally retains DMD's mutable Type identity.
    auto arrayType = new TypeDArray(Type.tint32);

    call(
        Callable(cast(void*) &preserveArray, LINK.c, CompilerAbi.dmd),
        [TypedAddress(arrayType, &array)],
        TypedAddress(arrayType, &arrayResult),
    ).should == true;

    array.length.should == originalArrayLength;
    assert(array.ptr is originalArrayPointer);
    arrayResult.length.should == originalArrayLength;
    assert(arrayResult.ptr is originalArrayPointer);
    array[1].should == 50;

    int captured = 40;
    int delegate(int) delegate_ = value => captured + value;
    // `const` would change the two pointer types being identity-tested.
    auto originalDelegateContext = delegate_.ptr;
    auto originalDelegateFunction = delegate_.funcptr;
    assert(originalDelegateContext !is null);
    int delegate(int) delegateResult;
    // TypedAddress intentionally retains DMD's mutable Type identity.
    auto delegateType = new TypeDelegate(new TypeFunction(
        ParameterList(null),
        Type.tint32,
        LINK.d,
    ));

    call(
        Callable(cast(void*) &preserveDelegate, LINK.c, CompilerAbi.dmd),
        [TypedAddress(delegateType, &delegate_)],
        TypedAddress(delegateType, &delegateResult),
    ).should == true;

    assert(delegate_.ptr is originalDelegateContext);
    assert(delegate_.funcptr is originalDelegateFunction);
    assert(delegateResult.ptr is originalDelegateContext);
    assert(delegateResult.funcptr is originalDelegateFunction);
    (delegateResult == delegate_).should == true;
    delegateResult(2).should == 42;
}


private extern(C) int[] preserveArray(int[] value) {
    value[1] *= 10;
    return value;
}


private extern(C) int delegate(int) preserveDelegate(int delegate(int) value) {
    return value;
}


private void assertFloatingPointCall(T)(T argument, Type type) {
    T result;
    const expected = floatingPointOracle(argument);

    call(
        Callable(cast(void*) &floatingPointOracle!T, LINK.c, CompilerAbi.dmd),
        [TypedAddress(type, &argument)],
        TypedAddress(type, &result),
    ).should == true;

    result.should == expected;
}


private extern(C) T floatingPointOracle(T)(T value) {
    return value * cast(T) 1.5 + cast(T) 0.25;
}


pragma(inline, false)
private double roundToDouble(double value) {
    return value;
}


private void assertScalarRoundTrip(T)(T expected, Type type) {
    T argument = expected;
    T result;

    call(
        Callable(cast(void*) &identity!T, LINK.c, CompilerAbi.dmd),
        [TypedAddress(type, &argument)],
        TypedAddress(type, &result),
    ).should == true;

    result.should == expected;
}


private extern(C) T identity(T)(T value) {
    return value;
}


private int callEncoding(
    void* functionAddress,
    in LINK linkage,
    in CompilerAbi compilerAbi,
) {
    int lhs = 4;
    int rhs = 7;
    int result;

    assert(call(
        Callable(cast(void*) functionAddress, linkage, compilerAbi),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
    ));

    return result;
}


private extern(C) int encodeArguments(int lhs, int rhs) {
    return lhs * 10 + rhs;
}


private extern(D) int encodeArgumentsD(int lhs, int rhs) {
    return lhs * 10 + rhs;
}

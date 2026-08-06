module ut.ffi.ffi;


import dmd.astenums: LINK;
import dmd.mtype: Type;
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

module ut.ffi.ffi;


import dmd.astenums: LINK;
import dmd.arraytypes: Dsymbols;
import dmd.func: FuncDeclaration;
import dmd.mtype:
    ParameterList, Type, TypeClass, TypeDArray, TypeDelegate, TypeFunction,
    TypeStruct;
import quickbite.ffi.ffi: Callable, CompilerAbi, TypedAddress, call;
import unit_threaded;


@("ffi.addressOnlyExternCScalarCall")
unittest {
    int lhs = 4;
    int rhs = 7;
    int result;

    call(
        Callable(
            cast(void*) &encodeArguments,
            functionSignature(Type.tint32, [Type.tint32, Type.tint32], LINK.c),
            CompilerAbi.dmd,
        ),
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
        Callable(
            cast(void*) &free,
            functionSignature(Type.tvoid, [Type.tvoidptr], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(Type.tvoidptr, &pointer)],
        TypedAddress(Type.tvoid, null),
    ).should == true;
}


@("ffi.addressOnlyExternCVariadicCall")
unittest {
    import core.stdc.stdio: snprintf;

    auto signature = functionSignature(q{
        extern(C) int snprintf(char*, size_t, const(char)*, ...);
    }, "snprintf");
    char[32] actual;
    char[32] expected;
    char* actualPointer = actual.ptr;
    size_t actualLength = actual.length;
    const(char)* format = "%d %.1f".ptr;
    int integer = 17;
    double floating = 2.5;
    const expectedLength = snprintf(
        expected.ptr,
        expected.length,
        format,
        integer,
        floating,
    );
    int actualLengthWritten;

    call(
        Callable(cast(void*) &snprintf, signature, CompilerAbi.dmd),
        [
            TypedAddress(signature.parameterList[0].type, &actualPointer),
            TypedAddress(signature.parameterList[1].type, &actualLength),
            TypedAddress(signature.parameterList[2].type, &format),
            TypedAddress(Type.tint32, &integer),
            TypedAddress(Type.tfloat64, &floating),
        ],
        TypedAddress(Type.tint32, &actualLengthWritten),
    ).should == true;

    actualLengthWritten.should == expectedLength;
    actual[0 .. actualLengthWritten + 1]
        .should == expected[0 .. expectedLength + 1];

    float unpromoted = 2.5;
    call(
        Callable(cast(void*) &snprintf, signature, CompilerAbi.dmd),
        [
            TypedAddress(signature.parameterList[0].type, &actualPointer),
            TypedAddress(signature.parameterList[1].type, &actualLength),
            TypedAddress(signature.parameterList[2].type, &format),
            TypedAddress(Type.tint32, &integer),
            TypedAddress(Type.tfloat32, &unpromoted),
        ],
        TypedAddress(Type.tint32, &actualLengthWritten),
    ).should == false;
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


@("ffi.addressOnlyImaginaryAndComplexCallsUseNativeScalarStorage")
unittest {
    ifloat imaginaryFloat = -2.5fi;
    assertAddressOnlyCall(
        cast(void*) &imaginaryFloatOracle,
        Type.timaginary32,
        imaginaryFloat,
        imaginaryFloatOracle(imaginaryFloat),
    );

    idouble imaginaryDouble = 3.25i;
    assertAddressOnlyCall(
        cast(void*) &imaginaryDoubleOracle,
        Type.timaginary64,
        imaginaryDouble,
        imaginaryDoubleOracle(imaginaryDouble),
    );

    ireal imaginaryReal = -(real.max / 8) * 1.0Li;
    assertAddressOnlyCall(
        cast(void*) &imaginaryRealOracle,
        Type.timaginary80,
        imaginaryReal,
        imaginaryRealOracle(imaginaryReal),
    );

    cfloat complexFloat = 1.25f - 2.5fi;
    assertAddressOnlyCall(
        cast(void*) &complexFloatOracle,
        Type.tcomplex32,
        complexFloat,
        complexFloatOracle(complexFloat),
    );

    cdouble complexDouble = -3.5 + 6.25i;
    assertAddressOnlyCall(
        cast(void*) &complexDoubleOracle,
        Type.tcomplex64,
        complexDouble,
        complexDoubleOracle(complexDouble),
    );

    creal complexReal = real.max / 8 - (real.max / 16) * 1.0Li;
    const complexRealExpected = complexRealOracle(complexReal);
    assert(complexRealExpected.re > double.max);
    assert(complexRealExpected.im < -double.max);
    assertAddressOnlyCall(
        cast(void*) &complexRealOracle,
        Type.tcomplex80,
        complexReal,
        complexRealExpected,
    );
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
        Callable(
            cast(void*) &preserveArray,
            functionSignature(arrayType, [arrayType], LINK.c),
            CompilerAbi.dmd,
        ),
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
        Callable(
            cast(void*) &preserveDelegate,
            functionSignature(delegateType, [delegateType], LINK.c),
            CompilerAbi.dmd,
        ),
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


@("ffi.addressOnlyAggregatesUseNativeLayout")
unittest {
    // DMD owns mutable semantic type nodes.
    auto mixedType = structType(q{
        struct Mixed {
            long integer;
            double floating;
        }
    }, "Mixed");
    Mixed mixed = Mixed(11, 2.5);
    Mixed mixedResult;
    const mixedExpected = transformMixed(mixed);

    call(
        Callable(
            cast(void*) &transformMixed,
            functionSignature(mixedType, [mixedType], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(mixedType, &mixed)],
        TypedAddress(mixedType, &mixedResult),
    ).should == true;

    mixedResult.integer.should == mixedExpected.integer;
    mixedResult.floating.should == mixedExpected.floating;

    // DMD owns mutable semantic type nodes.
    auto largeType = structType(q{
        struct Large {
            long[3] values;
        }
    }, "Large");
    Large large = Large([13, 17, 19]);
    Large largeResult;
    const largeExpected = transformLarge(large);

    call(
        Callable(
            cast(void*) &transformLarge,
            functionSignature(largeType, [largeType], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(largeType, &large)],
        TypedAddress(largeType, &largeResult),
    ).should == true;

    largeResult.values.should == largeExpected.values;
}


@("ffi.addressOnlyEnumsAndAssociativeArraysUseNativeLayout")
unittest {
    auto enumSignature = functionSignature(q{
        enum Narrow : byte;
        extern(C) Narrow transformNarrow(Narrow);
    }, "transformNarrow");
    auto enumType = enumSignature.next.isTypeEnum;
    assert(enumType !is null);
    Narrow narrow = cast(Narrow) -101;
    Narrow narrowResult;

    call(
        Callable(
            cast(void*) &transformNarrow,
            enumSignature,
            CompilerAbi.dmd,
        ),
        [TypedAddress(enumType, &narrow)],
        TypedAddress(enumType, &narrowResult),
    ).should == true;

    narrowResult.should == cast(Narrow) 37;

    auto associativeArraySignature = functionSignature(q{
        extern(C) int[int] mutateAssociativeArray(int[int]);
    }, "mutateAssociativeArray");
    auto associativeArrayType = associativeArraySignature.next.isTypeAArray;
    assert(associativeArrayType !is null);
    int[int] values = [3: 11];
    int[int] result;

    call(
        Callable(
            cast(void*) &mutateAssociativeArray,
            associativeArraySignature,
            CompilerAbi.dmd,
        ),
        [TypedAddress(associativeArrayType, &values)],
        TypedAddress(associativeArrayType, &result),
    ).should == true;

    values[3].should == 22;
    result[7] = 41;
    values[7].should == 41;
}


@("ffi.referenceArgumentsAndReturnUseAuthoritativeStorage")
unittest {
    auto signature = functionSignature(q{
        extern(C) ref int referenceCall(
            ref int value,
            out int assigned,
            int* pointer,
        );
    }, "referenceCall");
    int value = 11;
    int assigned = -1;
    int pointedTo = 5;
    int* pointer = &pointedTo;
    int* returned;

    call(
        Callable(cast(void*) &referenceCall, signature, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &value),
            TypedAddress(Type.tint32, &assigned),
            TypedAddress(signature.parameterList[2].type, &pointer),
        ],
        TypedAddress(Type.tint32, &returned),
    ).should == true;

    value.should == 16;
    assigned.should == 32;
    pointedTo.should == 5;
    assert(returned is &value);
}


@("ffi.hiddenReceiversUseCallableCompilerAbiAndExistingStorage")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    // A D method's semantic function type contains only its explicit
    // parameters; `this` is the separate hidden receiver supplied below.
    auto structSignature = functionSignature(q{
        struct Receiver {
            int combine(int lhs, int rhs);
        }
    }, "combine");
    auto structReceiverType = structType(q{
        struct Receiver {
            int value;
        }
    }, "Receiver");
    ReceiverStruct structReceiver = ReceiverStruct(3);
    auto structMethod = &structReceiver.combine;
    int lhs = 4;
    int rhs = 7;
    int result;
    auto receiver = TypedAddress(structReceiverType, &structReceiver);

    call(
        Callable(
            cast(void*) structMethod.funcptr,
            structSignature,
            hostCompilerAbi,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
        &receiver,
    ).should == true;

    result.should == 1_047;
    structReceiver.value.should == 10;

    auto classSignature = functionSignature(q{
        class Receiver {
            final int combine(int lhs, int rhs);
        }
    }, "combine");
    auto classReceiverType = classType(q{
        class Receiver {
            int value;
        }
    }, "Receiver");
    auto classReceiver = new ReceiverClass(5);
    auto classMethod = &classReceiver.combine;
    receiver = TypedAddress(classReceiverType, &classReceiver);
    result = 0;

    call(
        Callable(
            cast(void*) classMethod.funcptr,
            classSignature,
            hostCompilerAbi,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
        &receiver,
    ).should == true;

    result.should == 1_247;
    classReceiver.value.should == 12;

    int captured = 6;
    int nested(int first, int second) {
        captured += second;
        return captured * 100 + first * 10 + second;
    }
    auto nestedDelegate = &nested;
    void* context = nestedDelegate.ptr;
    receiver = TypedAddress(Type.tvoidptr, &context);
    result = 0;

    call(
        Callable(
            cast(void*) nestedDelegate.funcptr,
            functionSignature(q{
                int nested(int first, int second);
            }, "nested"),
            hostCompilerAbi,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
        &receiver,
    ).should == true;

    result.should == 1_347;
    captured.should == 13;

    auto invalidReceiver = TypedAddress(Type.tint32, &lhs);
    call(
        Callable(
            cast(void*) structMethod.funcptr,
            structSignature,
            hostCompilerAbi,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
        &invalidReceiver,
    ).should == false;

    invalidReceiver = TypedAddress(Type.tvoidptr, null);
    call(
        Callable(
            cast(void*) nestedDelegate.funcptr,
            functionSignature(q{
                int nested(int first, int second);
            }, "nested"),
            hostCompilerAbi,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
        &invalidReceiver,
    ).should == false;
}


private extern(C) ref int referenceCall(
    ref int value,
    out int assigned,
    int* pointer,
) {
    value += *pointer;
    assigned = value * 2;
    return value;
}


private struct ReceiverStruct {
    private int value;

    private int combine(int lhs, int rhs) {
        value += rhs;
        return value * 100 + lhs * 10 + rhs;
    }
}


private class ReceiverClass {
    private int value;

    private this(int value) {
        this.value = value;
    }

    private final int combine(int lhs, int rhs) {
        value += rhs;
        return value * 100 + lhs * 10 + rhs;
    }
}


private extern(C) int[] preserveArray(int[] value) {
    value[1] *= 10;
    return value;
}


private extern(C) int delegate(int) preserveDelegate(int delegate(int) value) {
    return value;
}


private struct Mixed {
    private long integer;
    private double floating;
}


private extern(C) Mixed transformMixed(Mixed value) {
    return Mixed(value.integer * 3, value.floating + 0.75);
}


private struct Large {
    private long[3] values;
}


private extern(C) Large transformLarge(Large value) {
    return Large([
        value.values[2] + 1,
        value.values[1] + 2,
        value.values[0] + 3,
    ]);
}


private enum Narrow : byte {
    unused,
}


private extern(C) Narrow transformNarrow(Narrow value) {
    return cast(Narrow) (cast(byte) value + 138);
}


private extern(C) int[int] mutateAssociativeArray(int[int] values) {
    values[3] *= 2;
    return values;
}


private TypeStruct structType(in string source, in string name) {
    import quickbite.frontend.compiler: parseSnippet;

    // DMD owns mutable semantic state and type nodes.
    auto moduleResult = parseSnippet(source);
    foreach (member; *moduleResult.module_.members)
        if (auto struct_ = member.isStructDeclaration)
            if (struct_.ident.toString == name) {
                auto type = struct_.type.isTypeStruct;
                assert(type !is null);
                return type;
            }

    assert(false, "struct not found");
}


private TypeClass classType(in string source, in string name) {
    import quickbite.frontend.compiler: parseSnippet;

    // DMD owns mutable semantic state and type nodes.
    auto moduleResult = parseSnippet(source);
    foreach (member; *moduleResult.module_.members)
        if (auto class_ = member.isClassDeclaration)
            if (class_.ident.toString == name) {
                auto type = class_.type.isTypeClass;
                assert(type !is null);
                return type;
            }

    assert(false, "class not found");
}


private TypeFunction functionSignature(in string source, in string name) {
    import quickbite.frontend.compiler: parseSnippet;

    // DMD owns mutable semantic state and type nodes.
    auto moduleResult = parseSnippet(source);
    auto function_ = findFunction(moduleResult.module_.members, name);
    if (function_ !is null) {
        auto type = function_.type.isTypeFunction;
        assert(type !is null);
        return type;
    }

    assert(false, "function not found");
}


private FuncDeclaration findFunction(Dsymbols* members, in string name) {
    if (members is null)
        return null;

    foreach (member; *members) {
        if (auto function_ = member.isFuncDeclaration)
            if (function_.ident !is null && function_.ident.toString == name)
                return function_;
        if (auto attributes = member.isAttribDeclaration)
            if (auto function_ = findFunction(attributes.decl, name))
                return function_;
        if (auto aggregate = member.isAggregateDeclaration)
            if (auto function_ = findFunction(aggregate.members, name))
                return function_;
    }
    return null;
}


private TypeFunction functionSignature(
    Type returnType,
    Type[] parameterTypes,
    in LINK linkage,
) {
    import dmd.arraytypes: Parameters;
    import dmd.astenums: STC;
    import dmd.location: Loc;
    import dmd.mtype: Parameter;

    auto parameters = new Parameters;
    foreach (parameterType; parameterTypes)
        parameters.push(new Parameter(
            Loc.initial,
            STC.none,
            parameterType,
            null,
            null,
            null,
        ));
    return new TypeFunction(ParameterList(parameters), returnType, linkage);
}


private void assertFloatingPointCall(T)(T argument, Type type) {
    T result;
    const expected = floatingPointOracle(argument);

    call(
        Callable(
            cast(void*) &floatingPointOracle!T,
            functionSignature(type, [type], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(type, &argument)],
        TypedAddress(type, &result),
    ).should == true;

    result.should == expected;
}


private extern(C) T floatingPointOracle(T)(T value) {
    return value * cast(T) 1.5 + cast(T) 0.25;
}


private void assertAddressOnlyCall(T)(
    void* functionAddress,
    Type type,
    T argument,
    T expected,
) {
    T result;

    call(
        Callable(
            functionAddress,
            functionSignature(type, [type], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(type, &argument)],
        TypedAddress(type, &result),
    ).should == true;

    result.should == expected;
}


private extern(C) ifloat imaginaryFloatOracle(ifloat value) {
    return value * 1.5f + 0.25fi;
}


private extern(C) idouble imaginaryDoubleOracle(idouble value) {
    return value * 1.5 + 0.25i;
}


private extern(C) ireal imaginaryRealOracle(ireal value) {
    return value / 2.0L + 0.25Li;
}


private extern(C) cfloat complexFloatOracle(cfloat value) {
    return value * 1.5f + (0.5f - 0.75fi);
}


private extern(C) cdouble complexDoubleOracle(cdouble value) {
    return value * 1.5 + (0.5 - 0.75i);
}


private extern(C) creal complexRealOracle(creal value) {
    return value / 2.0L + (0.5L - 0.75Li);
}


pragma(inline, false)
private double roundToDouble(double value) {
    return value;
}


private void assertScalarRoundTrip(T)(T expected, Type type) {
    T argument = expected;
    T result;

    call(
        Callable(
            cast(void*) &identity!T,
            functionSignature(type, [type], LINK.c),
            CompilerAbi.dmd,
        ),
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
        Callable(
            cast(void*) functionAddress,
            functionSignature(Type.tint32, [Type.tint32, Type.tint32], linkage),
            compilerAbi,
        ),
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

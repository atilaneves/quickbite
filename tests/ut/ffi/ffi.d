module ut.ffi.ffi;


import dmd.astenums: LINK, STC, VarArg;
import dmd.arraytypes: Dsymbols;
import dmd.func: FuncDeclaration;
import dmd.mtype:
    ParameterList, Type, TypeClass, TypeDArray, TypeDelegate, TypeFunction,
    TypeReference, TypeStruct, TypeVector;
import dmd.typesem: constOf, merge, sarrayOf;
import quickbite.ffi.ffi:
    Callable, CompilerAbi, DVariadicMetadata, TypedAddress, call;
import unit_threaded;


@("ffi.addressOnlySysVYmmCalls")
unittest {
    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(8));
    vectorType = vectorType.merge;
    ubyte[32] value = [
        1, 2, 3, 4, 5, 6, 7, 8,
        9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24,
        25, 26, 27, 28, 29, 30, 31, 32,
    ];
    ubyte[32] result;

    import core.cpuid: avx;
    if (!avx) {
        call(
            Callable(
                cast(void*) &ymmIdentity,
                functionSignature(vectorType, [vectorType], LINK.c),
                CompilerAbi.dmd,
            ),
            [TypedAddress(vectorType, &value)],
            TypedAddress(vectorType, &result),
        ).should == false;
        return;
    }

    call(
        Callable(
            cast(void*) &ymmIdentity,
            functionSignature(vectorType, [vectorType], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(vectorType, &value)],
        TypedAddress(vectorType, &result),
    ).should == true;
    result.should == value;

    int marker = 7;
    result = ubyte[32].init;
    call(
        Callable(
            cast(void*) &ymmIdentity,
            functionSignature(
                vectorType,
                [Type.tint32, vectorType, Type.tint32],
                LINK.c,
            ),
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &marker),
            TypedAddress(vectorType, &value),
            TypedAddress(Type.tint32, &marker),
        ],
        TypedAddress(vectorType, &result),
    ).should == true;
    result.should == value;

    double[8] occupied = [1, 2, 3, 4, 5, 6, 7, 8];
    auto exhaustedSignature = functionSignature(
        vectorType,
        [
            Type.tfloat64, Type.tfloat64, Type.tfloat64, Type.tfloat64,
            Type.tfloat64, Type.tfloat64, Type.tfloat64, Type.tfloat64,
            vectorType,
        ],
        LINK.c,
    );
    TypedAddress[] exhaustedArguments;
    foreach (ref number; occupied)
        exhaustedArguments ~= TypedAddress(Type.tfloat64, &number);
    exhaustedArguments ~= TypedAddress(vectorType, &value);
    result = ubyte[32].init;
    call(
        Callable(
            cast(void*) &ymmStackIdentity,
            exhaustedSignature,
            CompilerAbi.dmd,
        ),
        exhaustedArguments,
        TypedAddress(vectorType, &result),
    ).should == true;
    result.should == value;

    auto variadicSignature = functionSignature(q{
        extern(C) ubyte vectorVariadicSseCount(int marker, ...);
    }, "vectorVariadicSseCount");
    ubyte sseCount;
    call(
        Callable(
            cast(void*) &vectorVariadicSseCount,
            variadicSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &marker),
            TypedAddress(vectorType, &value),
        ],
        TypedAddress(Type.tuns8, &sseCount),
    ).should == true;
    sseCount.should == 1;

    auto aggregateType = vectorType.sarrayOf(2);
    ubyte[64] aggregate;
    aggregate[0 .. 32] = value[];
    foreach (index; 32 .. aggregate.length)
        aggregate[index] = cast(ubyte) (index + 1);
    ubyte[64] aggregateResult;
    call(
        Callable(
            cast(void*) &ymmMemoryIdentity,
            functionSignature(aggregateType, [aggregateType], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(aggregateType, &aggregate)],
        TypedAddress(aggregateType, &aggregateResult),
    ).should == true;
    aggregateResult.should == aggregate;
}


@("ffi.addressOnlySysVVectorCalls")
unittest {
    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    auto signature = functionSignature(
        vectorType,
        [Type.tint32, vectorType, Type.tint32],
        LINK.c,
    );
    int bias = 3;
    int scale = 2;
    Float4 value = [1.0f, 2.0f, 4.0f, 8.0f];
    Float4 result;

    call(
        Callable(
            cast(void*) &transformVector,
            signature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &bias),
            TypedAddress(signature.parameterList[1].type, &value),
            TypedAddress(Type.tint32, &scale),
        ],
        TypedAddress(signature.next, &result),
    ).should == true;

    result.array.should == transformVector(bias, value, scale).array;

    double[8] occupied = [1, 2, 3, 4, 5, 6, 7, 8];
    result = Float4.init;
    call(
        Callable(
            cast(void*) &transformExhaustedVector,
            functionSignature(
                vectorType,
                [
                    Type.tfloat64,
                    Type.tfloat64,
                    Type.tfloat64,
                    Type.tfloat64,
                    Type.tfloat64,
                    Type.tfloat64,
                    Type.tfloat64,
                    Type.tfloat64,
                    vectorType,
                    Type.tint32,
                ],
                LINK.c,
            ),
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tfloat64, &occupied[0]),
            TypedAddress(Type.tfloat64, &occupied[1]),
            TypedAddress(Type.tfloat64, &occupied[2]),
            TypedAddress(Type.tfloat64, &occupied[3]),
            TypedAddress(Type.tfloat64, &occupied[4]),
            TypedAddress(Type.tfloat64, &occupied[5]),
            TypedAddress(Type.tfloat64, &occupied[6]),
            TypedAddress(Type.tfloat64, &occupied[7]),
            TypedAddress(vectorType, &value),
            TypedAddress(Type.tint32, &scale),
        ],
        TypedAddress(vectorType, &result),
    ).should == true;
    result.array.should == transformExhaustedVector(
        occupied[0],
        occupied[1],
        occupied[2],
        occupied[3],
        occupied[4],
        occupied[5],
        occupied[6],
        occupied[7],
        value,
        scale,
    ).array;

    auto aggregateType = vectorType.sarrayOf(2);
    auto aggregateSignature = functionSignature(
        aggregateType,
        [aggregateType, Type.tint32],
        LINK.c,
    );
    Float4[2] aggregate = [value, value * 2];
    Float4[2] aggregateResult;
    call(
        Callable(
            cast(void*) &transformVectorAggregate,
            aggregateSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(aggregateType, &aggregate),
            TypedAddress(Type.tint32, &scale),
        ],
        TypedAddress(aggregateType, &aggregateResult),
    ).should == true;
    const expectedAggregate = transformVectorAggregate(aggregate, scale);
    aggregateResult[0].array.should == expectedAggregate[0].array;
    aggregateResult[1].array.should == expectedAggregate[1].array;

    auto variadicSignature = functionSignature(q{
        extern(C) ubyte vectorVariadicSseCount(int marker, ...);
    }, "vectorVariadicSseCount");
    int marker = 1;
    double tail = 2.5;
    ubyte sseCount;
    call(
        Callable(
            cast(void*) &vectorVariadicSseCount,
            variadicSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &marker),
            TypedAddress(vectorType, &value),
            TypedAddress(Type.tfloat64, &tail),
        ],
        TypedAddress(Type.tuns8, &sseCount),
    ).should == true;
    sseCount.should == 2;

    bool caught;
    try {
        call(
            Callable(
                cast(void*) &throwVector,
                functionSignature(vectorType, [vectorType], LINK.c),
                CompilerAbi.dmd,
            ),
            [TypedAddress(vectorType, &value)],
            TypedAddress(vectorType, &result),
        );
        assert(false, "throwing vector call returned");
    } catch (Exception exception) {
        exception.msg.should == "vector failure";
        caught = true;
    }
    caught.should == true;
}


@("ffi.addressOnlyExternCppVectorCalls")
unittest {
    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    int bias = 3;
    Float4 value = [1.0f, 2.0f, 4.0f, 8.0f];
    Float4 result;

    call(
        Callable(
            cast(void*) &transformCppVector,
            functionSignature(
                vectorType,
                [Type.tint32, vectorType],
                LINK.cpp,
            ),
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &bias),
            TypedAddress(vectorType, &value),
        ],
        TypedAddress(vectorType, &result),
    ).should == true;
    result.array.should == transformCppVector(bias, value).array;

    auto memberSignature = functionSignature(
        vectorType,
        [Type.tint32, vectorType],
        LINK.cpp,
    );
    auto receiverType = structType(q{
        extern(C++) struct Receiver {
            int scale;
        }
    }, "Receiver");
    CppVectorReceiver receiverValue = CppVectorReceiver(2);
    auto method = &receiverValue.combine;
    auto receiver = TypedAddress(receiverType, &receiverValue);
    result = Float4.init;
    call(
        Callable(
            cast(void*) method.funcptr,
            memberSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &bias),
            TypedAddress(vectorType, &value),
        ],
        TypedAddress(vectorType, &result),
        &receiver,
    ).should == true;
    result.array.should == receiverValue.combine(bias, value).array;

    auto variadicSignature = functionSignatureWithStorageClasses(
        Type.tuns8,
        [Type.tint32],
        [STC.none],
        LINK.cpp,
        VarArg.variadic,
    );
    ubyte sseCount;
    call(
        Callable(
            cast(void*) &cppVectorVariadicSseCount,
            variadicSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &bias),
            TypedAddress(vectorType, &value),
        ],
        TypedAddress(Type.tuns8, &sseCount),
    ).should == true;
    sseCount.should == 1;
}


@("ffi.addressOnlyVectorCallsReuseIndirectStorage")
unittest {
    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    auto vectorReferenceSignature = functionSignatureWithStorageClasses(
        vectorType,
        [vectorType, Type.tint32, vectorType],
        [STC.ref_, STC.out_, STC.none],
        LINK.c,
        VarArg.none,
        true,
    );
    Float4 value = [1.0f, 2.0f, 4.0f, 8.0f];
    Float4 increment = [8.0f, 4.0f, 2.0f, 1.0f];
    int visits = -1;
    Float4* returnedVector;

    call(
        Callable(
            cast(void*) &updateVectorReference,
            vectorReferenceSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(vectorType, &value),
            TypedAddress(Type.tint32, &visits),
            TypedAddress(vectorType, &increment),
        ],
        TypedAddress(vectorType, &returnedVector),
    ).should == true;
    visits.should == 1;
    assert(returnedVector is &value);
    value.array.should == (Float4([9.0f, 6.0f, 6.0f, 9.0f])).array;

    auto scalarReferenceSignature = functionSignatureWithStorageClasses(
        Type.tint32,
        [Type.tint32, vectorType],
        [STC.ref_, STC.none],
        LINK.c,
        VarArg.none,
        true,
    );
    int scalar = 41;
    int* returnedScalar;
    call(
        Callable(
            cast(void*) &selectScalarReference,
            scalarReferenceSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &scalar),
            TypedAddress(vectorType, &value),
        ],
        TypedAddress(Type.tint32, &returnedScalar),
    ).should == true;
    assert(returnedScalar is &scalar);
}


@("ffi.addressOnlyDVectorDescriptorCalls")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    Float4 value = [1.0f, 2.0f, 4.0f, 8.0f];
    Float4 result;

    Float4 delegate() thunk = () => vectorThunk;
    auto thunkType = new TypeDelegate(new TypeFunction(
        ParameterList(null),
        vectorType,
        LINK.d,
    ));
    auto lazySignature = functionSignatureWithStorageClasses(
        vectorType,
        [vectorType, vectorType],
        [STC.none, STC.lazy_],
        LINK.d,
    );
    call(
        Callable(
            cast(void*) &evaluateLazyVector,
            lazySignature,
            hostCompilerAbi,
        ),
        [
            TypedAddress(vectorType, &value),
            TypedAddress(thunkType, &thunk),
        ],
        TypedAddress(vectorType, &result),
    ).should == true;
    result.array.should == evaluateLazyVector(value, vectorThunk).array;

    auto restType = new TypeDArray(vectorType);
    auto typesafeSignature = functionSignatureWithStorageClasses(
        vectorType,
        [vectorType, restType],
        [STC.none, STC.none],
        LINK.d,
        VarArg.typesafe,
    );
    Float4[] rest = [Float4([2.0f, 3.0f, 5.0f, 7.0f])];
    result = Float4.init;
    call(
        Callable(
            cast(void*) &sumTypesafeVectors,
            typesafeSignature,
            hostCompilerAbi,
        ),
        [
            TypedAddress(vectorType, &value),
            TypedAddress(typesafeSignature.parameterList[1].type, &rest),
        ],
        TypedAddress(vectorType, &result),
    ).should == true;
    result.array.should == sumTypesafeVectors(value, rest).array;
}


@("ffi.addressOnlyVectorCallsReturnX87Values")
unittest {
    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    Float4 value = [1.0f, 2.0f, 4.0f, 8.0f];
    real result;

    call(
        Callable(
            cast(void*) &vectorToReal,
            functionSignature(Type.tfloat80, [vectorType], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(vectorType, &value)],
        TypedAddress(Type.tfloat80, &result),
    ).should == true;
    result.should == vectorToReal(value);

    creal complexResult;
    call(
        Callable(
            cast(void*) &vectorToComplexReal,
            functionSignature(Type.tcomplex80, [vectorType], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(vectorType, &value)],
        TypedAddress(Type.tcomplex80, &complexResult),
    ).should == true;
    complexResult.should == vectorToComplexReal(value);
}


@("ffi.addressOnlyVectorCallsComposeHiddenResults")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    auto aggregateType = vectorType.sarrayOf(2);
    Float4 value = [1.0f, 2.0f, 4.0f, 8.0f];
    Float4[2] aggregateResult;
    DVectorSretReceiver dReceiver = DVectorSretReceiver(3);
    auto dMethod = &dReceiver.combine;
    auto dReceiverType = structType(q{
        struct Receiver {
            int bias;
        }
    }, "Receiver");
    auto receiver = TypedAddress(dReceiverType, &dReceiver);
    call(
        Callable(
            cast(void*) dMethod.funcptr,
            functionSignature(aggregateType, [vectorType], LINK.d),
            hostCompilerAbi,
        ),
        [TypedAddress(vectorType, &value)],
        TypedAddress(aggregateType, &aggregateResult),
        &receiver,
    ).should == true;
    const expectedAggregate = dReceiver.combine(value);
    aggregateResult[0].array.should == expectedAggregate[0].array;
    aggregateResult[1].array.should == expectedAggregate[1].array;

    foreach (compilerAbi; [CompilerAbi.dmd, CompilerAbi.ldc]) {
        aggregateResult = Float4[2].init;
        call(
            Callable(
                compilerAbi == CompilerAbi.dmd
                    ? cast(void*) &dmdVectorSretOrderOracle
                    : cast(void*) &ldcVectorSretOrderOracle,
                functionSignature(aggregateType, [vectorType], LINK.d),
                compilerAbi,
            ),
            [TypedAddress(vectorType, &value)],
            TypedAddress(aggregateType, &aggregateResult),
            &receiver,
        ).should == true;
        aggregateResult[0].array.should == expectedAggregate[0].array;
        aggregateResult[1].array.should == expectedAggregate[1].array;
    }

    auto nonPodType = functionSignature(q{
        extern(C++) {
            struct NonPod {
                int value;
                ~this();
            }
            NonPod make(NonPod value);
        }
    }, "make").next;
    auto nonPodSignature = functionSignature(
        nonPodType,
        [nonPodType, vectorType],
        LINK.cpp,
    );
    CppNonPod nonPod = CppNonPod(11);
    CppNonPod nonPodResult;
    const expectedNonPod = transformCppNonPodVector(nonPod, value);
    call(
        Callable(
            cast(void*) &transformCppNonPodVector,
            nonPodSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(nonPodType, &nonPod),
            TypedAddress(vectorType, &value),
        ],
        TypedAddress(nonPodType, &nonPodResult),
    ).should == true;
    nonPodResult.value.should == expectedNonPod.value;

    CppVectorNonPodFactory factory = CppVectorNonPodFactory(5);
    auto cppMethod = &factory.make;
    auto cppReceiverType = structType(q{
        extern(C++) struct Factory {
            int bias;
        }
    }, "Factory");
    receiver = TypedAddress(cppReceiverType, &factory);
    nonPodResult.value = 0;
    call(
        Callable(
            cast(void*) cppMethod.funcptr,
            functionSignature(nonPodType, [vectorType], LINK.cpp),
            CompilerAbi.dmd,
        ),
        [TypedAddress(vectorType, &value)],
        TypedAddress(nonPodType, &nonPodResult),
        &receiver,
    ).should == true;
    nonPodResult.value.should == factory.make(value).value;

    auto constructor = specialFunctionDeclaration(q{
        extern(C++) struct Lifetime {
            int value;
            this(int placeholder);
        }
    }, true);
    constructor.type.isTypeFunction.parameterList[0].type = vectorType;
    CppVectorLifetime lifetime;
    receiver = TypedAddress(constructor.isThis.type, &lifetime);
    call(
        Callable(
            cast(void*) &cppVectorConstructorOracle,
            constructor.type.isTypeFunction,
            CompilerAbi.dmd,
            constructor,
        ),
        [TypedAddress(vectorType, &value)],
        TypedAddress(constructor.type.isTypeFunction.next, null),
        &receiver,
    ).should == true;
    lifetime.value.should == 18;
}


@("ffi.addressOnlyVectorCallsComposeRegisterPressure")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    Float4 vector = [1.0f, 2.0f, 4.0f, 8.0f];

    UInt128Abi integer = UInt128Abi(11, 17);
    UInt128Abi integerResult;
    call(
        Callable(
            cast(void*) &transformUInt128Vector,
            functionSignature(
                Type.tuns128,
                [Type.tuns128, vectorType],
                LINK.c,
            ),
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tuns128, &integer),
            TypedAddress(vectorType, &vector),
        ],
        TypedAddress(Type.tuns128, &integerResult),
    ).should == true;
    integerResult.should == transformUInt128Vector(integer, vector);

    auto emptyType = structType(q{
        struct Empty {
        }
    }, "Empty");
    EmptyVectorArgument empty;
    Float4 vectorResult;
    call(
        Callable(
            cast(void*) &ignoreEmptyVectorArgument,
            functionSignature(
                vectorType,
                [emptyType, vectorType],
                LINK.c,
            ),
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(emptyType, &empty),
            TypedAddress(vectorType, &vector),
        ],
        TypedAddress(vectorType, &vectorResult),
    ).should == true;
    vectorResult.array.should == ignoreEmptyVectorArgument(
        empty,
        vector,
    ).array;

    auto aggregateType = vectorType.sarrayOf(2);
    auto signature = variadicFunctionSignature(
        aggregateType,
        [Type.tint32, Type.tint32, Type.tint32, Type.tint32],
        LINK.d,
    );
    DVariadicVectorSretReceiver receiverValue =
        DVariadicVectorSretReceiver(3);
    auto method = &receiverValue.combine;
    auto receiverType = structType(q{
        struct Receiver {
            int bias;
        }
    }, "Receiver");
    auto receiver = TypedAddress(receiverType, &receiverValue);
    int first = 1;
    int second = 2;
    int third = 4;
    int fourth = 8;
    DVariadicMetadata variadicMetadata;
    version (LDC) {
        TypeInfo[] metadata = [typeid(Float4)];
        auto metadataType = functionSignature(q{
            void metadata(TypeInfo[]);
        }, "metadata").parameterList[0].type;
        variadicMetadata = DVariadicMetadata(
            TypedAddress(metadataType, &metadata),
        );
    } else {
        TypeInfo_Tuple metadata = new TypeInfo_Tuple;
        metadata.elements = [typeid(Float4)];
        auto metadataType = functionSignature(q{
            void metadata(TypeInfo_Tuple);
        }, "metadata").parameterList[0].type;
        variadicMetadata = DVariadicMetadata(
            TypedAddress(metadataType, &metadata),
        );
    }
    Float4[2] aggregateResult;
    call(
        Callable(
            cast(void*) method.funcptr,
            signature,
            hostCompilerAbi,
        ),
        [
            TypedAddress(Type.tint32, &first),
            TypedAddress(Type.tint32, &second),
            TypedAddress(Type.tint32, &third),
            TypedAddress(Type.tint32, &fourth),
            TypedAddress(vectorType, &vector),
        ],
        TypedAddress(aggregateType, &aggregateResult),
        &receiver,
        &variadicMetadata,
    ).should == true;
    const expectedAggregate = receiverValue.combine(
        first,
        second,
        third,
        fourth,
        vector,
    );
    aggregateResult[0].array.should == expectedAggregate[0].array;
    aggregateResult[1].array.should == expectedAggregate[1].array;
}


@("ffi.addressOnlyExternDVectorCalls")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    auto signature = functionSignature(
        vectorType,
        [Type.tint32, vectorType, Type.tint32],
        LINK.d,
    );
    DVectorReceiver receiver = DVectorReceiver(3);
    auto method = &receiver.combine;
    int head = 4;
    int tail = 7;
    Float4 value = [1.0f, 2.0f, 4.0f, 8.0f];
    Float4 result;
    auto receiverType = structType(q{
        struct Receiver {
            int bias;
        }
    }, "Receiver");
    auto receiverAddress = TypedAddress(receiverType, &receiver);

    const expected = receiver.combine(head, value, tail);
    call(
        Callable(cast(void*) method.funcptr, signature, hostCompilerAbi),
        [
            TypedAddress(Type.tint32, &head),
            TypedAddress(vectorType, &value),
            TypedAddress(Type.tint32, &tail),
        ],
        TypedAddress(vectorType, &result),
        &receiverAddress,
    ).should == true;
    result.array.should == expected.array;

    result = Float4.init;
    call(
        Callable(
            cast(void*) &dmdVectorOrderOracle,
            signature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tint32, &head),
            TypedAddress(vectorType, &value),
            TypedAddress(Type.tint32, &tail),
        ],
        TypedAddress(vectorType, &result),
    ).should == true;
    result.array.should == dmdVectorOrderOracle(tail, value, head).array;
}


@("ffi.addressOnlyExternDVariadicVectorCalls")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    Type vectorType = new TypeVector(Type.tfloat32.sarrayOf(4));
    vectorType = vectorType.merge;
    auto signature = variadicFunctionSignature(
        vectorType,
        [Type.tint32],
        LINK.d,
    );
    DVariadicVectorReceiver receiver = DVariadicVectorReceiver(3);
    auto method = &receiver.combine;
    int fixed = 4;
    float unpromoted = 2.5;
    Float4 vector = [1.0f, 2.0f, 4.0f, 8.0f];
    Float4 result;
    auto receiverType = structType(q{
        struct Receiver {
            int bias;
        }
    }, "Receiver");
    auto receiverAddress = TypedAddress(receiverType, &receiver);
    DVariadicMetadata variadicMetadata;

    version (LDC) {
        TypeInfo[] metadata = [typeid(float), typeid(Float4)];
        auto metadataType = functionSignature(q{
            void metadata(TypeInfo[]);
        }, "metadata").parameterList[0].type;
        variadicMetadata = DVariadicMetadata(
            TypedAddress(metadataType, &metadata),
        );
    } else {
        TypeInfo_Tuple metadata = new TypeInfo_Tuple;
        metadata.elements = [typeid(float), typeid(Float4)];
        auto metadataType = functionSignature(q{
            void metadata(TypeInfo_Tuple);
        }, "metadata").parameterList[0].type;
        variadicMetadata = DVariadicMetadata(
            TypedAddress(metadataType, &metadata),
        );
    }

    const expected = receiver.combine(fixed, unpromoted, vector);
    call(
        Callable(cast(void*) method.funcptr, signature, hostCompilerAbi),
        [
            TypedAddress(Type.tint32, &fixed),
            TypedAddress(Type.tfloat32, &unpromoted),
            TypedAddress(vectorType, &vector),
        ],
        TypedAddress(vectorType, &result),
        &receiverAddress,
        &variadicMetadata,
    ).should == true;

    result.array.should == expected.array;

    enum otherCompilerAbi = hostCompilerAbi == CompilerAbi.dmd
        ? CompilerAbi.ldc
        : CompilerAbi.dmd;
    call(
        Callable(cast(void*) method.funcptr, signature, otherCompilerAbi),
        [
            TypedAddress(Type.tint32, &fixed),
            TypedAddress(Type.tfloat32, &unpromoted),
            TypedAddress(vectorType, &vector),
        ],
        TypedAddress(vectorType, &result),
        &receiverAddress,
        &variadicMetadata,
    ).should == false;
}


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


@("ffi.addressOnlyExternCppCallsUseNativeAbi")
unittest {
    auto freeSignature = functionSignature(q{
        extern(C++) int cppEncode(int lhs, int rhs);
    }, "cppEncode");
    int lhs = 4;
    int rhs = 7;
    int result;

    call(
        Callable(cast(void*) &cppEncode, freeSignature, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
    ).should == true;
    result.should == cppEncode(lhs, rhs);

    auto memberSignature = functionSignature(q{
        extern(C++) struct Receiver {
            int combine(int lhs, int rhs);
        }
    }, "combine");
    auto memberReceiverType = structType(q{
        extern(C++) struct Receiver {
            int bias;
        }
    }, "Receiver");
    CppReceiver cppReceiver = CppReceiver(3);
    auto member = &cppReceiver.combine;
    auto receiver = TypedAddress(memberReceiverType, &cppReceiver);
    result = 0;

    call(
        Callable(cast(void*) member.funcptr, memberSignature, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
        &receiver,
    ).should == true;
    result.should == 347;

    auto nonPodSignature = functionSignature(q{
        extern(C++) {
            struct NonPod {
                int value;
                ~this();
            }
            NonPod transform(NonPod value, int tail);
        }
    }, "transform");
    CppNonPod nonPod = CppNonPod(11);
    CppNonPod nonPodResult;
    const expectedNonPod = transformCppNonPod(nonPod, rhs);

    call(
        Callable(
            cast(void*) &transformCppNonPod,
            nonPodSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(nonPodSignature.parameterList[0].type, &nonPod),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(nonPodSignature.next, &nonPodResult),
    ).should == true;
    nonPodResult.value.should == expectedNonPod.value;

    auto nonPodMemberSignature = functionSignature(q{
        extern(C++) {
            struct NonPod {
                int value;
                ~this();
            }
            struct Factory {
                NonPod make(int value);
            }
        }
    }, "make");
    auto factoryType = structType(q{
        extern(C++) struct Factory {
            int bias;
        }
    }, "Factory");
    CppNonPodFactory factory = CppNonPodFactory(5);
    auto make = &factory.make;
    receiver = TypedAddress(factoryType, &factory);
    int madeValue = 13;
    nonPodResult.value = 0;
    call(
        Callable(
            cast(void*) make.funcptr,
            nonPodMemberSignature,
            CompilerAbi.dmd,
        ),
        [TypedAddress(Type.tint32, &madeValue)],
        TypedAddress(nonPodMemberSignature.next, &nonPodResult),
        &receiver,
    ).should == true;
    nonPodResult.value.should == 18;

    import core.stdc.stdio: snprintf;

    auto variadicSignature = functionSignature(q{
        extern(C++) int snprintf(char*, size_t, const(char)*, ...);
    }, "snprintf");
    char[32] buffer;
    char* bufferPointer = buffer.ptr;
    size_t bufferLength = buffer.length;
    const(char)* format = "%d %.1f".ptr;
    int integer = 17;
    double floating = 2.5;
    int length;
    call(
        Callable(
            cast(void*) &snprintf,
            variadicSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(variadicSignature.parameterList[0].type,
                &bufferPointer),
            TypedAddress(variadicSignature.parameterList[1].type,
                &bufferLength),
            TypedAddress(variadicSignature.parameterList[2].type, &format),
            TypedAddress(Type.tint32, &integer),
            TypedAddress(Type.tfloat64, &floating),
        ],
        TypedAddress(Type.tint32, &length),
    ).should == true;
    buffer[0 .. length].should == "17 2.5";

    auto referenceType = new TypeReference(Type.tint32);
    int referenced = 41;
    int referenceResult;
    call(
        Callable(
            cast(void*) &incrementCppReference,
            functionSignature(Type.tint32, [referenceType], LINK.cpp),
            CompilerAbi.dmd,
        ),
        [TypedAddress(referenceType, &referenced)],
        TypedAddress(Type.tint32, &referenceResult),
    ).should == true;
    referenced.should == 42;
    referenceResult.should == 42;

    auto constructor = specialFunctionDeclaration(q{
        extern(C++) struct Lifetime {
            int value;
            this(int lhs, int rhs);
            ~this();
        }
    }, true);
    auto otherReceiverType = structType(q{
        extern(C++) struct Other {
            int value;
        }
    }, "Other");
    CppLifetime unrelatedReceiverStorage;
    receiver = TypedAddress(otherReceiverType, &unrelatedReceiverStorage);
    call(
        Callable(
            cast(void*) &cppConstructorOracle,
            constructor.type.isTypeFunction,
            CompilerAbi.dmd,
            constructor,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(constructor.type.isTypeFunction.next, null),
        &receiver,
    ).should == false;

    CppLifetime lifetime;
    receiver = TypedAddress(constructor.isThis.type, &lifetime);
    call(
        Callable(
            cast(void*) &cppConstructorOracle,
            constructor.type.isTypeFunction,
            CompilerAbi.dmd,
            constructor,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(constructor.type.isTypeFunction.next, null),
        &receiver,
    ).should == true;
    lifetime.value.should == 47;

    receiver = TypedAddress(constructor.isThis.type.constOf, &lifetime);
    call(
        Callable(
            cast(void*) &cppConstructorOracle,
            constructor.type.isTypeFunction,
            CompilerAbi.dmd,
            constructor,
        ),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(constructor.type.isTypeFunction.next, null),
        &receiver,
    ).should == true;

    auto destructor = specialFunctionDeclaration(q{
        extern(C++) struct Lifetime {
            int value;
            this(int lhs, int rhs);
            ~this();
        }
    }, false);
    call(
        Callable(
            cast(void*) &cppDestructorOracle,
            destructor.type.isTypeFunction,
            CompilerAbi.dmd,
            destructor,
        ),
        [],
        TypedAddress(destructor.type.isTypeFunction.next, null),
        &receiver,
    ).should == true;
    lifetime.value.should == -47;
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


@("ffi.nativeNoreturnExceptionPropagatesUntouched")
unittest {
    auto signature = functionSignature(q{
        noreturn throwNative(Exception);
    }, "throwNative");
    auto expected = new Exception("native failure");
    bool caught;

    try {
        call(
            Callable(
                cast(void*) &throwNative,
                signature,
                CompilerAbi.dmd,
            ),
            [TypedAddress(signature.parameterList[0].type, &expected)],
            TypedAddress(signature.next, null),
        );
        assert(false, "noreturn native call returned");
    } catch (Exception actual) {
        assert(actual is expected);
        caught = true;
    }

    caught.should == true;
}


@("ffi.addressOnlyFunctionAndNullPointerCalls")
unittest {
    auto functionPointerSignature = functionSignature(q{
        extern(C) {
            alias Unary = int function(int);
            int callFunctionPointer(Unary, int);
        }
    }, "callFunctionPointer");
    CUnary functionPointer = &addThree;
    int argument = 39;
    int functionResult;

    call(
        Callable(
            cast(void*) &callFunctionPointer,
            functionPointerSignature,
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(
                functionPointerSignature.parameterList[0].type,
                &functionPointer,
            ),
            TypedAddress(Type.tint32, &argument),
        ],
        TypedAddress(Type.tint32, &functionResult),
    ).should == true;
    functionResult.should == 42;

    auto nullSignature = functionSignature(q{
        extern(C) bool isNull(typeof(null));
    }, "isNull");
    typeof(null) nullValue = null;
    bool nullResult;
    call(
        Callable(cast(void*) &isNull, nullSignature, CompilerAbi.dmd),
        [TypedAddress(nullSignature.parameterList[0].type, &nullValue)],
        TypedAddress(Type.tbool, &nullResult),
    ).should == true;
    nullResult.should == true;
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


@("ffi.addressOnlyExternDVariadicCall")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    auto signature = functionSignature(q{
        struct Receiver {
            float combine(int fixed, ...);
        }
    }, "combine");
    auto receiverType = structType(q{
        struct Receiver {
            int bias;
        }
    }, "Receiver");
    DVariadicReceiver receiver = DVariadicReceiver(3);
    auto method = &receiver.combine;
    int fixed = 4;
    int integer = 7;
    float floating = 2.5;
    float result;
    auto receiverAddress = TypedAddress(receiverType, &receiver);
    DVariadicMetadata variadicMetadata;

    version (LDC) {
        TypeInfo[] metadata = [typeid(int), typeid(float)];
        auto metadataType = functionSignature(q{
            void metadata(TypeInfo[]);
        }, "metadata").parameterList[0].type;
        variadicMetadata = DVariadicMetadata(
            TypedAddress(metadataType, &metadata),
        );
    } else {
        TypeInfo_Tuple metadata = new TypeInfo_Tuple;
        metadata.elements = [typeid(int), typeid(float)];
        auto metadataType = functionSignature(q{
            void metadata(TypeInfo_Tuple);
        }, "metadata").parameterList[0].type;
        variadicMetadata = DVariadicMetadata(
            TypedAddress(metadataType, &metadata),
        );
    }

    const expected = receiver.combine(fixed, integer, floating);
    call(
        Callable(cast(void*) method.funcptr, signature, hostCompilerAbi),
        [
            TypedAddress(Type.tint32, &fixed),
            TypedAddress(Type.tint32, &integer),
            TypedAddress(Type.tfloat32, &floating),
        ],
        TypedAddress(Type.tfloat32, &result),
        &receiverAddress,
        &variadicMetadata,
    ).should == true;

    result.should == expected;
    result.should == 772.5;
}


@("ffi.addressOnlyTypesafeExternDVariadicCall")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    auto signature = functionSignature(q{
        int sum(int seed, int[] rest...);
    }, "sum");
    int seed = 5;
    int[] rest = [7, 11, 13];
    int result;
    const expected = typesafeVariadicSum(seed, rest);

    call(
        Callable(
            cast(void*) &typesafeVariadicSum,
            signature,
            hostCompilerAbi,
        ),
        [
            TypedAddress(Type.tint32, &seed),
            TypedAddress(signature.parameterList[1].type, &rest),
        ],
        TypedAddress(Type.tint32, &result),
    ).should == true;

    result.should == expected;
}


@("ffi.addressOnlyLazyParameterUsesExistingDelegateStorage")
unittest {
    version (LDC)
        enum hostCompilerAbi = CompilerAbi.ldc;
    else
        enum hostCompilerAbi = CompilerAbi.dmd;

    auto signature = functionSignature(q{
        int evaluate(int seed, lazy int value);
    }, "evaluate");
    auto thunk = fortyTwoThunk;
    assert(thunk.ptr is null);
    auto thunkType = new TypeDelegate(new TypeFunction(
        ParameterList(null),
        Type.tint32,
        LINK.d,
    ));
    int seed = 3;
    int result;

    call(
        Callable(cast(void*) &evaluateLazy, signature, hostCompilerAbi),
        [
            TypedAddress(Type.tint32, &seed),
            TypedAddress(thunkType, &thunk),
        ],
        TypedAddress(Type.tint32, &result),
    ).should == true;

    result.should == evaluateLazy(seed, thunk());
    result.should == 87;
}


@("ffi.addressOnlyImportCKRVariadicCallHasNoFixedArguments")
unittest {
    import dmd.astenums: VarArg;

    auto signature = new TypeFunction(
        ParameterList(null, VarArg.KRvariadic),
        Type.tfloat64,
        LINK.c,
    );
    signature.parameterList.hasIdentifierList = true;
    int integer = 17;
    double floating = 2.5;
    double result;

    call(
        Callable(cast(void*) &krVariadicAbiOracle, signature, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &integer),
            TypedAddress(Type.tfloat64, &floating),
        ],
        TypedAddress(Type.tfloat64, &result),
    ).should == true;

    result.should == krVariadicAbiOracle(integer, floating);
    result.should == 172.5;

    float unpromoted = 2.5;
    call(
        Callable(cast(void*) &krVariadicAbiOracle, signature, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &integer),
            TypedAddress(Type.tfloat32, &unpromoted),
        ],
        TypedAddress(Type.tfloat64, &result),
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


@("ffi.addressOnly128BitIntegerCallsUseTwoIntegerEightbytes")
unittest {
    assert128BitIntegerCalls(Type.tint128);
    assert128BitIntegerCalls(Type.tuns128);
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


@("ffi.addressOnlyEmptyAndZeroSizedAggregatesUseNativeAbi")
unittest {
    auto emptySignature = functionSignature(q{
        struct Empty {}
        extern(C) int placeEmpty(int, Empty, int);
    }, "placeEmpty");
    auto emptyType = emptySignature.parameterList[1].type;
    Empty empty;
    int lhs = 4;
    int rhs = 7;
    int placement;

    call(
        Callable(cast(void*) &placeEmpty, emptySignature, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(emptyType, &empty),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &placement),
    ).should == true;
    placement.should == 47;

    auto zeroSignature = functionSignature(q{
        extern(C) int placeZero(int, int[0], int);
    }, "placeZero");
    auto zeroType = zeroSignature.parameterList[1].type;
    int[0] zero;
    placement = 0;

    call(
        Callable(cast(void*) &placeZero, zeroSignature, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(zeroType, &zero),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &placement),
    ).should == true;
    placement.should == 47;
}


@("ffi.addressOnlySysVUnionsAndIrregularAggregatesUseNativeLayout")
unittest {
    auto integerOrDoubleType = structType(q{
        union IntegerOrDouble {
            long integer;
            double floating;
        }
    }, "IntegerOrDouble");
    IntegerOrDouble integerOrDouble;
    integerOrDouble.integer = 13;
    IntegerOrDouble integerOrDoubleResult;
    const integerOrDoubleExpected = transformIntegerOrDouble(integerOrDouble);
    assertAggregateCall(
        cast(void*) &transformIntegerOrDouble,
        integerOrDoubleType,
        integerOrDouble,
        integerOrDoubleResult,
    );
    integerOrDoubleResult.integer.should == integerOrDoubleExpected.integer;

    auto mirroredLanesType = structType(q{
        union MirroredLanes {
            struct IntegerSse {
                long integer;
                double floating;
            }
            struct SseInteger {
                double floating;
                long integer;
            }
            IntegerSse integerSse;
            SseInteger sseInteger;
        }
    }, "MirroredLanes");
    MirroredLanes mirroredLanes;
    mirroredLanes.integerSse.integer = 17;
    mirroredLanes.sseInteger.integer = 23;
    MirroredLanes mirroredLanesResult;
    const mirroredLanesExpected = transformMirroredLanes(mirroredLanes);
    assertAggregateCall(
        cast(void*) &transformMirroredLanes,
        mirroredLanesType,
        mirroredLanes,
        mirroredLanesResult,
    );
    mirroredLanesResult.integerSse.integer.should ==
        mirroredLanesExpected.integerSse.integer;
    mirroredLanesResult.sseInteger.integer.should ==
        mirroredLanesExpected.sseInteger.integer;

    auto memoryUnionType = structType(q{
        union MemoryUnion {
            long[3] integers;
            double[3] floating;
        }
    }, "MemoryUnion");
    MemoryUnion memoryUnion;
    memoryUnion.integers = [29, 31, 37];
    MemoryUnion memoryUnionResult;
    const memoryUnionExpected = transformMemoryUnion(memoryUnion);
    assertAggregateCall(
        cast(void*) &transformMemoryUnion,
        memoryUnionType,
        memoryUnion,
        memoryUnionResult,
    );
    memoryUnionResult.integers.should == memoryUnionExpected.integers;

    auto packedType = structType(q{
        struct Packed {
            align(1):
            ubyte tag;
            long integer;
        }
    }, "Packed");
    Packed packed = Packed(41, 43);
    Packed packedResult;
    const packedExpected = transformPacked(packed);
    assertAggregateCall(
        cast(void*) &transformPacked,
        packedType,
        packed,
        packedResult,
    );
    packedResult.tag.should == packedExpected.tag;
    packedResult.integer.should == packedExpected.integer;

    auto nestedType = structType(q{
        struct NestedUnion {
            union Payload {
                long integer;
                double floating;
            }
            Payload value;
            double tail;
        }
    }, "NestedUnion");
    NestedUnion nested;
    nested.value.integer = 47;
    nested.tail = 53.5;
    NestedUnion nestedResult;
    const nestedExpected = transformNestedUnion(nested);
    assertAggregateCall(
        cast(void*) &transformNestedUnion,
        nestedType,
        nested,
        nestedResult,
    );
    nestedResult.value.integer.should == nestedExpected.value.integer;
    nestedResult.tail.should == nestedExpected.tail;
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


@("ffi.memoryReturnsPlaceDmdReceiverBeforeResultStorage")
unittest {
    auto signature = functionSignature(q{
        struct Receiver {
            long[3] combine(int value);
        }
    }, "combine");
    auto receiverType = structType(q{
        struct Receiver {
            long[3] storage;
        }
    }, "Receiver");
    int value = 7;

    DMemorySretReceiver dmdReceiver = DMemorySretReceiver([3, 0, 0]);
    long[3] dmdResult;
    auto receiver = TypedAddress(receiverType, &dmdReceiver);
    call(
        Callable(
            cast(void*) &dmdMemorySretOrderOracle,
            signature,
            CompilerAbi.dmd,
        ),
        [TypedAddress(Type.tint32, &value)],
        TypedAddress(signature.next, &dmdResult),
        &receiver,
    ).should == true;
    dmdResult.should == [37L, 38L, 39L];
    dmdReceiver.storage.should == [3L, 0L, 0L];

    DMemorySretReceiver ldcReceiver = DMemorySretReceiver([5, 0, 0]);
    long[3] ldcResult;
    receiver = TypedAddress(receiverType, &ldcReceiver);
    call(
        Callable(
            cast(void*) &ldcMemorySretOrderOracle,
            signature,
            CompilerAbi.ldc,
        ),
        [TypedAddress(Type.tint32, &value)],
        TypedAddress(signature.next, &ldcResult),
        &receiver,
    ).should == true;
    ldcResult.should == [57L, 58L, 59L];
    ldcReceiver.storage.should == [5L, 0L, 0L];

    version (DMD) {
        DMemorySretReceiver nativeReceiver =
            DMemorySretReceiver([11, 0, 0]);
        auto method = &nativeReceiver.combine;
        long[3] nativeResult;
        receiver = TypedAddress(receiverType, &nativeReceiver);
        call(
            Callable(
                cast(void*) method.funcptr,
                signature,
                CompilerAbi.dmd,
            ),
            [TypedAddress(Type.tint32, &value)],
            TypedAddress(signature.next, &nativeResult),
            &receiver,
        ).should == true;
        nativeResult.should == nativeReceiver.combine(value);
    }
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


private extern(C++) int cppEncode(int lhs, int rhs) {
    return lhs * 10 + rhs;
}


private extern(C++) struct CppReceiver {
    private int bias;

    private int combine(int lhs, int rhs) {
        return bias * 100 + lhs * 10 + rhs;
    }
}


private extern(C++) struct CppNonPod {
    private int value;

    private ~this() {
    }
}


private extern(C++) CppNonPod transformCppNonPod(
    CppNonPod value,
    int tail,
) {
    value.value = value.value * 10 + tail;
    return value;
}


private extern(C++) struct CppNonPodFactory {
    private int bias;

    private CppNonPod make(int value) {
        return CppNonPod(bias + value);
    }
}


private struct CppLifetime {
    private int value;
}


private extern(C++) void cppConstructorOracle(
    CppLifetime* receiver,
    int lhs,
    int rhs,
) {
    receiver.value = lhs * 10 + rhs;
}


private extern(C++) void cppDestructorOracle(CppLifetime* receiver) {
    receiver.value = -receiver.value;
}


private extern(C++) int incrementCppReference(ref int value) {
    return ++value;
}


private struct ReceiverStruct {
    private int value;

    private int combine(int lhs, int rhs) {
        value += rhs;
        return value * 100 + lhs * 10 + rhs;
    }
}


private struct DVariadicReceiver {
    private int bias;

    private float combine(int fixed, ...) {
        import core.vararg: va_arg;

        assert(_arguments.length == 2);
        assert(_arguments[0] is typeid(int));
        assert(_arguments[1] is typeid(float));
        const integer = va_arg!int(_argptr);
        const floating = va_arg!float(_argptr);
        return bias * 100 + fixed * 100 + integer * 10 + floating;
    }
}


private int typesafeVariadicSum(int seed, int[] rest...) {
    auto result = seed;
    foreach (const value; rest)
        result += value;
    return result;
}


private int evaluateLazy(int seed, lazy int value) {
    return seed + value + value;
}


private int delegate() fortyTwoThunk = () => 42;


private extern(C) double krVariadicAbiOracle(int integer, double floating) {
    return integer * 10 + floating;
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


private struct Empty {
}


private extern(C) int placeEmpty(int lhs, Empty, int rhs) {
    return lhs * 10 + rhs;
}


private extern(C) int placeZero(int lhs, int[0], int rhs) {
    return lhs * 10 + rhs;
}


private union IntegerOrDouble {
    private long integer;
    private double floating;
}


private extern(C) IntegerOrDouble transformIntegerOrDouble(
    IntegerOrDouble value,
) {
    IntegerOrDouble result;
    result.integer = value.integer * 3 + 5;
    return result;
}


private union MirroredLanes {
    private struct IntegerSse {
        private long integer;
        private double floating;
    }

    private struct SseInteger {
        private double floating;
        private long integer;
    }

    private IntegerSse integerSse;
    private SseInteger sseInteger;
}


private extern(C) MirroredLanes transformMirroredLanes(MirroredLanes value) {
    MirroredLanes result;
    result.integerSse.integer = value.integerSse.integer * 5 + 7;
    result.sseInteger.integer = value.sseInteger.integer * 11 + 13;
    return result;
}


private union MemoryUnion {
    private long[3] integers;
    private double[3] floating;
}


private extern(C) MemoryUnion transformMemoryUnion(MemoryUnion value) {
    MemoryUnion result;
    result.integers = [
        value.integers[2] + 17,
        value.integers[0] + 19,
        value.integers[1] + 23,
    ];
    return result;
}


private struct Packed {
    align(1):
    private ubyte tag;
    private long integer;
}


private extern(C) Packed transformPacked(Packed value) {
    return Packed(cast(ubyte) (value.tag + 29), value.integer * 31 + 37);
}


private struct NestedUnion {
    private union Payload {
        private long integer;
        private double floating;
    }

    private Payload value;
    private double tail;
}


private extern(C) NestedUnion transformNestedUnion(NestedUnion value) {
    NestedUnion result;
    result.value.integer = value.value.integer * 41 + 43;
    result.tail = value.tail * 2.0 + 0.25;
    return result;
}


private void assertAggregateCall(T)(
    void* functionAddress,
    TypeStruct type,
    T argument,
    ref T result,
) {
    call(
        Callable(
            functionAddress,
            functionSignature(type, [type], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(type, &argument)],
        TypedAddress(type, &result),
    ).should == true;
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
    auto struct_ = findStruct(moduleResult.module_.members, name);
    if (struct_ !is null) {
        auto type = struct_.type.isTypeStruct;
        assert(type !is null);
        return type;
    }

    assert(false, "struct not found");
}


private imported!"dmd.dstruct".StructDeclaration findStruct(
    Dsymbols* members,
    in string name,
) {
    if (members is null)
        return null;

    foreach (member; *members) {
        if (auto struct_ = member.isStructDeclaration)
            if (struct_.ident.toString == name)
                return struct_;
        if (auto attributes = member.isAttribDeclaration)
            if (auto struct_ = findStruct(attributes.decl, name))
                return struct_;
    }
    return null;
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


private FuncDeclaration specialFunctionDeclaration(
    in string source,
    in bool constructor,
) {
    import quickbite.frontend.compiler: parseSnippet;

    // DMD owns mutable semantic state and declaration nodes.
    auto moduleResult = parseSnippet(source);
    auto function_ = findSpecialFunction(
        moduleResult.module_.members,
        constructor,
    );
    assert(function_ !is null, "special function not found");
    return function_;
}


private FuncDeclaration findSpecialFunction(
    Dsymbols* members,
    in bool constructor,
) {
    if (members is null)
        return null;

    foreach (member; *members) {
        if (auto function_ = member.isFuncDeclaration)
            if (constructor
                ? function_.isCtorDeclaration !is null
                : function_.isDtorDeclaration !is null)
                return function_;
        if (auto attributes = member.isAttribDeclaration)
            if (auto function_ = findSpecialFunction(
                attributes.decl,
                constructor,
            ))
                return function_;
        if (auto aggregate = member.isAggregateDeclaration)
            if (auto function_ = findSpecialFunction(
                aggregate.members,
                constructor,
            ))
                return function_;
    }
    return null;
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


private TypeFunction functionSignatureWithStorageClasses(
    Type returnType,
    Type[] parameterTypes,
    STC[] storageClasses,
    in LINK linkage,
    in VarArg varargs = VarArg.none,
    in bool refResult = false,
) {
    import dmd.arraytypes: Parameters;
    import dmd.location: Loc;
    import dmd.mtype: Parameter;

    assert(parameterTypes.length == storageClasses.length);
    auto parameters = new Parameters;
    foreach (index, parameterType; parameterTypes)
        parameters.push(new Parameter(
            Loc.initial,
            storageClasses[index],
            parameterType,
            null,
            null,
            null,
        ));
    auto signature = new TypeFunction(
        ParameterList(parameters, varargs),
        returnType,
        linkage,
    );
    signature.isRef = refResult;
    return signature;
}


private TypeFunction variadicFunctionSignature(
    Type returnType,
    Type[] parameterTypes,
    in LINK linkage,
) {
    import dmd.arraytypes: Parameters;
    import dmd.astenums: STC, VarArg;
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
    return new TypeFunction(
        ParameterList(parameters, VarArg.variadic),
        returnType,
        linkage,
    );
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


private alias Float4 = __vector(float[4]);


pragma(inline, false)
private extern(C) void ymmIdentity() {
    asm pure nothrow @nogc {
        naked;
        db 0xC3;
    }
}


pragma(inline, false)
private extern(C) void ymmStackIdentity() {
    asm pure nothrow @nogc {
        naked;
        lea RAX, [RSP + 8];
        and RAX, 31;
        jz aligned;
        ud2;
    aligned:
        db 0xC5, 0xFE, 0x6F, 0x44, 0x24, 0x08;
        db 0xC3;
    }
}


pragma(inline, false)
private extern(C) void ymmMemoryIdentity() {
    asm pure nothrow @nogc {
        naked;
        db 0xC5, 0xFE, 0x6F, 0x44, 0x24, 0x08;
        db 0xC5, 0xFE, 0x6F, 0x4C, 0x24, 0x28;
        db 0xC5, 0xFE, 0x7F, 0x07;
        db 0xC5, 0xFE, 0x7F, 0x4F, 0x20;
        db 0x48, 0x89, 0xF8;
        db 0xC3;
    }
}


private struct DVectorReceiver {
    private int bias;

    private Float4 combine(int head, Float4 value, int tail) {
        Float4 factor = head;
        Float4 offset = bias * 10 + tail;
        return value * factor + offset;
    }
}


private struct DVariadicVectorReceiver {
    private int bias;

    private Float4 combine(int fixed, ...) {
        import core.vararg: va_arg;

        assert(_arguments.length == 2);
        assert(_arguments[0] is typeid(float));
        assert(_arguments[1] is typeid(Float4));
        const floating = va_arg!float(_argptr);
        const vector = va_arg!Float4(_argptr);
        Float4 offset = bias * 100 + fixed * 10 + floating;
        return vector + offset;
    }
}


private extern(C) Float4 dmdVectorOrderOracle(
    int tail,
    Float4 value,
    int head,
) {
    Float4 factor = head;
    Float4 offset = tail;
    return value * factor + offset;
}


private extern(C) Float4 transformVector(int bias, Float4 value, int scale) {
    Float4 factor = scale;
    Float4 offset = bias;
    return value * factor + offset;
}


private extern(C++) Float4 transformCppVector(int bias, Float4 value) {
    Float4 offset = bias;
    return value + offset;
}


private extern(C++) struct CppVectorReceiver {
    private int scale;

    private Float4 combine(int bias, Float4 value) {
        Float4 factor = scale;
        Float4 offset = bias;
        return value * factor + offset;
    }
}


pragma(inline, false)
private extern(C++) ubyte cppVectorVariadicSseCount(int marker, ...) {
    asm pure nothrow @nogc {
        naked;
        ret;
    }
}


private extern(C) ref Float4 updateVectorReference(
    ref Float4 value,
    out int visits,
    Float4 increment,
) {
    value += increment;
    visits = 1;
    return value;
}


private extern(C) ref int selectScalarReference(
    ref int value,
    Float4 ignored,
) {
    return value;
}


private Float4 vectorThunk() {
    return Float4([0.5f, 1.0f, 1.5f, 2.0f]);
}


private Float4 evaluateLazyVector(Float4 value, lazy Float4 increment) {
    return value + increment;
}


private Float4 sumTypesafeVectors(Float4 seed, Float4[] rest...) {
    foreach (value; rest)
        seed += value;
    return seed;
}


private extern(C) real vectorToReal(Float4 value) {
    return cast(real) value.array[0] * 10 + value.array[3];
}


private extern(C) creal vectorToComplexReal(Float4 value) {
    return cast(real) value.array[0] * 10 +
        cast(real) value.array[3] * 1.0Li;
}


private struct DVectorSretReceiver {
    private int bias;

    private Float4[2] combine(Float4 value) {
        Float4 offset = bias;
        return [value + offset, value * offset];
    }
}


private struct DMemorySretReceiver {
    private long[3] storage;

    private long[3] combine(int value) {
        const base = storage[0] * 10 + value;
        return [base, base + 1, base + 2];
    }
}


private extern(C) void dmdMemorySretOrderOracle(
    DMemorySretReceiver* receiver,
    long[3]* result,
    int value,
) {
    *result = receiver.combine(value);
}


private extern(C) void ldcMemorySretOrderOracle(
    long[3]* result,
    DMemorySretReceiver* receiver,
    int value,
) {
    *result = receiver.combine(value);
}


private extern(C) void dmdVectorSretOrderOracle(
    DVectorSretReceiver* receiver,
    Float4[2]* result,
    Float4 value,
) {
    *result = receiver.combine(value);
}


private extern(C) void ldcVectorSretOrderOracle(
    Float4[2]* result,
    DVectorSretReceiver* receiver,
    Float4 value,
) {
    *result = receiver.combine(value);
}


private extern(C++) CppNonPod transformCppNonPodVector(
    CppNonPod value,
    Float4 vector,
) {
    value.value += cast(int) vector.array[0] * 10 +
        cast(int) vector.array[3];
    return value;
}


private extern(C++) struct CppVectorNonPodFactory {
    private int bias;

    private CppNonPod make(Float4 vector) {
        return CppNonPod(
            bias + cast(int) vector.array[0] * 10 +
                cast(int) vector.array[3],
        );
    }
}


private struct CppVectorLifetime {
    private int value;
}


private extern(C++) void cppVectorConstructorOracle(
    CppVectorLifetime* receiver,
    Float4 vector,
) {
    receiver.value = cast(int) vector.array[0] * 10 +
        cast(int) vector.array[3];
}


private extern(C) UInt128Abi transformUInt128Vector(
    UInt128Abi value,
    Float4 vector,
) {
    value.low += cast(ulong) vector.array[0];
    value.high += cast(ulong) vector.array[3];
    return value;
}


private struct EmptyVectorArgument {
}


private extern(C) Float4 ignoreEmptyVectorArgument(
    EmptyVectorArgument empty,
    Float4 vector,
) {
    return vector + 1;
}


private struct DVariadicVectorSretReceiver {
    private int bias;

    private Float4[2] combine(
        int first,
        int second,
        int third,
        int fourth,
        ...
    ) {
        import core.vararg: va_arg;

        assert(_arguments.length == 1);
        assert(_arguments[0] is typeid(Float4));
        const vector = va_arg!Float4(_argptr);
        Float4 offset = bias + first + second + third + fourth;
        return [vector + offset, vector * offset];
    }
}


private extern(C) Float4 transformExhaustedVector(
    double first,
    double second,
    double third,
    double fourth,
    double fifth,
    double sixth,
    double seventh,
    double eighth,
    Float4 value,
    int scale,
) {
    Float4 factor = scale;
    Float4 offset = cast(float) (
        first + second + third + fourth + fifth + sixth + seventh + eighth
    );
    return value * factor + offset;
}


private extern(C) Float4[2] transformVectorAggregate(
    Float4[2] aggregate,
    int scale,
) {
    aggregate[0] *= scale;
    aggregate[1] += scale;
    return aggregate;
}


pragma(inline, false)
private extern(C) ubyte vectorVariadicSseCount(int marker, ...) {
    asm pure nothrow @nogc {
        naked;
        ret;
    }
}


private extern(C) Float4 throwVector(Float4 value) {
    throw new Exception("vector failure");
}


private struct UInt128Abi {
    ulong low;
    ulong high;
}


private void assert128BitIntegerCalls(Type type) {
    UInt128Abi value = UInt128Abi(
        0x0123_4567_89ab_cdef,
        0xfedc_ba98_7654_3210,
    );
    UInt128Abi result;

    call(
        Callable(
            cast(void*) &transformUInt128,
            functionSignature(type, [type], LINK.c),
            CompilerAbi.dmd,
        ),
        [TypedAddress(type, &value)],
        TypedAddress(type, &result),
    ).should == true;
    result.should == transformUInt128(value);

    ulong[5] prefix = [11, 22, 33, 44, 55];
    result = UInt128Abi.init;
    call(
        Callable(
            cast(void*) &transformExhaustedUInt128,
            functionSignature(
                type,
                [
                    Type.tuns64,
                    Type.tuns64,
                    Type.tuns64,
                    Type.tuns64,
                    Type.tuns64,
                    type,
                ],
                LINK.c,
            ),
            CompilerAbi.dmd,
        ),
        [
            TypedAddress(Type.tuns64, &prefix[0]),
            TypedAddress(Type.tuns64, &prefix[1]),
            TypedAddress(Type.tuns64, &prefix[2]),
            TypedAddress(Type.tuns64, &prefix[3]),
            TypedAddress(Type.tuns64, &prefix[4]),
            TypedAddress(type, &value),
        ],
        TypedAddress(type, &result),
    ).should == true;
    result.should == transformExhaustedUInt128(
        prefix[0],
        prefix[1],
        prefix[2],
        prefix[3],
        prefix[4],
        value,
    );
}


private extern(C) UInt128Abi transformUInt128(UInt128Abi value) {
    return UInt128Abi(
        value.high ^ 0x55aa_55aa_55aa_55aa,
        value.low ^ 0xaa55_aa55_aa55_aa55,
    );
}


private extern(C) UInt128Abi transformExhaustedUInt128(
    ulong first,
    ulong second,
    ulong third,
    ulong fourth,
    ulong fifth,
    UInt128Abi value,
) {
    return UInt128Abi(
        value.low ^ first ^ third ^ fifth,
        value.high ^ second ^ fourth,
    );
}


private extern(C) int addThree(int value) {
    return value + 3;
}


private alias CUnary = extern(C) int function(int);


private extern(C) int callFunctionPointer(CUnary function_, int value) {
    return function_(value);
}


private extern(C) bool isNull(typeof(null) value) {
    return value is null;
}


private extern(D) noreturn throwNative(Exception exception) {
    throw exception;
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

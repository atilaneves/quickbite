module quickbite.ffi.ffi;

private:


public enum CompilerAbi {
    dmd,
    ldc,
}


public struct Callable {
    public void* address;
    public imported!"dmd.mtype".TypeFunction signature;
    public CompilerAbi compilerAbi;
}


public struct TypedAddress {
    public imported!"dmd.mtype".Type type;
    public void* address;
}


public bool call(
    Callable callable,
    TypedAddress[] arguments,
    TypedAddress result,
    TypedAddress* receiver = null,
) {
    import quickbite.ffi.libffi:
        ffi_arg, ffi_cif, ffi_call, ffi_prep_cif, ffi_prep_cif_var,
        ffi_status, ffi_type, ffi_type_pointer, FFI_DEFAULT_ABI;
    import dmd.astenums: LINK, TY, VarArg;

    if (callable.address is null || callable.signature is null ||
        callable.signature.next is null ||
        (callable.signature.linkage != LINK.c &&
            callable.signature.linkage != LINK.d) ||
        (receiver !is null && callable.signature.linkage != LINK.d) ||
        (callable.signature.parameterList.varargs != VarArg.none &&
            (callable.signature.linkage != LINK.c ||
                callable.signature.parameterList.varargs != VarArg.variadic)))
        return false;

    const numFixedArguments = callable.signature.parameterList.length;
    const isVariadic = callable.signature.parameterList.varargs ==
        VarArg.variadic;
    if (isVariadic
            ? arguments.length < numFixedArguments
            : arguments.length != numFixedArguments)
        return false;

    const hasReceiver = receiver !is null;
    FfiType receiverMetadata;
    void* structReceiverCell;
    void* receiverAddress;
    if (hasReceiver) {
        if (receiver.type is null || receiver.address is null)
            return false;

        switch (receiver.type.toBasetype.ty) with (TY) {
            case Tstruct:
                receiverMetadata = FfiType(&ffi_type_pointer);
                structReceiverCell = receiver.address;
                receiverAddress = &structReceiverCell;
                break;
            case Tclass, Tpointer:
                receiverMetadata = FfiType(&ffi_type_pointer);
                receiverAddress = receiver.address;
                break;
            default:
                return false;
        }
    }

    auto returnType = callable.signature.next.toBasetype;
    if (result.type is null ||
        !result.type.toBasetype.equals(returnType))
        return false;

    const returnsReference = callable.signature.isRef;
    auto resultMetadata = returnsReference
        ? FfiType(&ffi_type_pointer)
        : ffiTypeFor(returnType);
    if (resultMetadata.type is null)
        return false;

    const resultTy = semanticStorageType(returnType).ty;
    if ((returnsReference || resultTy != TY.Tvoid) && result.address is null)
        return false;

    const numAbiArguments = arguments.length + hasReceiver;
    auto argumentTypes = new ffi_type*[](numAbiArguments);
    auto argumentAddresses = new void*[](numAbiArguments);
    auto argumentMetadata = new FfiType[](numAbiArguments);
    if (hasReceiver) {
        argumentMetadata[0] = receiverMetadata;
        argumentTypes[0] = receiverMetadata.type;
        argumentAddresses[0] = receiverAddress;
    }
    // A ref/out ABI argument is a pointer value. Only that pointer value is
    // temporary: its cell lives through ffi_call and points directly at the
    // caller's authoritative storage; no pointee bytes are copied.
    auto referenceCells = new void*[](arguments.length);
    auto argumentIsReference = new bool[](arguments.length);
    foreach (index, argument; arguments) {
        if (argument.type is null || argument.address is null)
            return false;

        const isFixedArgument = index < numFixedArguments;
        if (isFixedArgument) {
            auto parameter = callable.signature.parameterList[index];
            if (!argument.type.toBasetype.equals(parameter.type.toBasetype))
                return false;
            argumentIsReference[index] = isReferenceParameter(parameter);
        } else if (!isPromotedVariadicType(argument.type))
            return false;

        const abiIndex = abiArgumentIndex(
            callable,
            index,
            arguments.length,
            hasReceiver,
        );
        argumentMetadata[abiIndex] = argumentIsReference[index]
            ? FfiType(&ffi_type_pointer)
            : ffiTypeFor(argument.type);
        argumentTypes[abiIndex] = argumentMetadata[abiIndex].type;
        if (argumentTypes[abiIndex] is null)
            return false;
        if (argumentIsReference[index]) {
            referenceCells[index] = argument.address;
            argumentAddresses[abiIndex] = &referenceCells[index];
        } else
            argumentAddresses[abiIndex] = argument.address;
    }

    ffi_cif cif;
    const prepStatus = isVariadic
        ? ffi_prep_cif_var(
            &cif,
            FFI_DEFAULT_ABI,
            cast(uint) numFixedArguments,
            cast(uint) numAbiArguments,
            resultMetadata.type,
            argumentTypes.ptr,
        )
        : ffi_prep_cif(
            &cif,
            FFI_DEFAULT_ABI,
            cast(uint) numAbiArguments,
            resultMetadata.type,
            argumentTypes.ptr,
        );
    if (prepStatus != ffi_status.FFI_OK)
        return false;
    if (!returnsReference && !layoutMatches(returnType, resultMetadata))
        return false;
    foreach (index; 0 .. arguments.length) {
        if (!argumentIsReference[index] &&
            !layoutMatches(
                arguments[index].type,
                argumentMetadata[abiArgumentIndex(
                    callable,
                    index,
                    arguments.length,
                    hasReceiver,
                )],
            ))
            return false;
    }

    // libffi requires narrow integer returns to use an ffi_arg-wide slot.
    // Copy only the static type's native width into the caller's storage.
    ffi_arg resultScratch;
    const resultCopySize = narrowIntegerResultSize(resultTy);
    void* resultAddress = resultTy == TY.Tvoid && !returnsReference
        ? null
        : returnsReference || resultCopySize == 0
            ? result.address
            : &resultScratch;
    alias CFunction = extern(C) void function();
    ffi_call(
        &cif,
        cast(CFunction) callable.address,
        resultAddress,
        argumentAddresses.ptr,
    );

    if (!returnsReference && resultCopySize != 0) {
        import core.stdc.string: memcpy;
        memcpy(result.address, &resultScratch, resultCopySize);
    }
    return true;
}


private bool isPromotedVariadicType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    switch (type.toBasetype.ty) with (TY) {
        case Tbool, Tint8, Tuns8, Tchar, Tint16, Tuns16, Twchar, Tfloat32:
            return false;
        default:
            return true;
    }
}


private bool isReferenceParameter(
    imported!"dmd.mtype".Parameter parameter,
) @safe @nogc nothrow pure {
    import dmd.astenums: STC;

    return (parameter.storageClass & (STC.ref_ | STC.out_)) != STC.none;
}


private size_t abiArgumentIndex(
    in Callable callable,
    in size_t sourceIndex,
    in size_t numArguments,
    in bool hasReceiver = false,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK;

    const explicitIndex = callable.signature.linkage == LINK.d &&
            callable.compilerAbi == CompilerAbi.dmd
        ? numArguments - sourceIndex - 1
        : sourceIndex;
    // D's hidden receiver/context leads the explicit arguments for both
    // compiler ABIs; provenance controls only the explicit argument order.
    return explicitIndex + hasReceiver;
}


private size_t narrowIntegerResultSize(
    in imported!"dmd.astenums".TY type,
) @safe @nogc nothrow pure {
    import dmd.astenums: TY;

    switch (type) with (TY) {
        case Tbool, Tint8, Tuns8, Tchar: return byte.sizeof;
        case Tint16, Tuns16, Twchar: return short.sizeof;
        case Tint32, Tuns32, Tdchar: return int.sizeof;
        default: return 0;
    }
}


private struct FfiType {
    private imported!"quickbite.ffi.libffi".ffi_type* _type;
    private imported!"quickbite.ffi.libffi".ffi_type[] _ownedTypes;
    private imported!"quickbite.ffi.libffi".ffi_type*[] _ownedElements;
    private FfiType[] _members;

    private imported!"quickbite.ffi.libffi".ffi_type* type()
        @safe @nogc nothrow pure {
        return _type;
    }
}


private FfiType ffiTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.ffi.libffi:
        ffi_type_complex_double, ffi_type_complex_float,
        ffi_type_complex_longdouble, ffi_type_double, ffi_type_float,
        ffi_type_longdouble, ffi_type_pointer, ffi_type_sint8, ffi_type_sint16,
        ffi_type_sint32, ffi_type_sint64, ffi_type_uint8, ffi_type_uint16,
        ffi_type_uint32, ffi_type_uint64, ffi_type_void;
    import dmd.astenums: TY;

    if (type is null)
        return FfiType.init;

    // DMD owns mutable semantic type nodes.
    auto storageType = semanticStorageType(type);
    switch (storageType.ty) with (TY) {
        case Tvoid: return FfiType(&ffi_type_void);
        case Tbool, Tuns8, Tchar: return FfiType(&ffi_type_uint8);
        case Tint8: return FfiType(&ffi_type_sint8);
        case Tuns16, Twchar: return FfiType(&ffi_type_uint16);
        case Tint16: return FfiType(&ffi_type_sint16);
        case Tuns32, Tdchar: return FfiType(&ffi_type_uint32);
        case Tint32: return FfiType(&ffi_type_sint32);
        case Tuns64: return FfiType(&ffi_type_uint64);
        case Tint64: return FfiType(&ffi_type_sint64);
        // An imaginary scalar has the same one-component native storage as
        // its real counterpart. Complex descriptors express the two-component
        // ABI directly; neither path reads or reconstructs the value.
        case Tfloat32, Timaginary32: return FfiType(&ffi_type_float);
        case Tfloat64, Timaginary64: return FfiType(&ffi_type_double);
        case Tfloat80, Timaginary80: return FfiType(&ffi_type_longdouble);
        case Tcomplex32: return FfiType(&ffi_type_complex_float);
        case Tcomplex64: return FfiType(&ffi_type_complex_double);
        case Tcomplex80: return FfiType(&ffi_type_complex_longdouble);
        case Tpointer, Tclass, Taarray: return FfiType(&ffi_type_pointer);
        case Tarray:
            // A native D dynamic array is `{length, ptr}` in word order.
            return aggregateFfiType([
                FfiType(&ffi_type_uint64),
                FfiType(&ffi_type_pointer),
            ]);
        case Tdelegate:
            // A native D delegate is `{context, funcptr}` in word order.
            return aggregateFfiType([
                FfiType(&ffi_type_pointer),
                FfiType(&ffi_type_pointer),
            ]);
        case Tsarray: return staticArrayFfiType(storageType.isTypeSArray);
        case Tstruct: return structFfiType(storageType.isTypeStruct);
        default: return FfiType.init;
    }
}


private imported!"dmd.mtype".Type semanticStorageType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    // DMD owns mutable semantic type nodes.
    auto baseType = type.toBasetype;
    return baseType.ty == TY.Tenum
        ? semanticStorageType(baseType.isTypeEnum.memType)
        : baseType;
}


private FfiType staticArrayFfiType(
    imported!"dmd.mtype".TypeSArray type,
) {
    auto element = ffiTypeFor(type.next);
    if (element.type is null)
        return FfiType.init;

    const length = cast(size_t) type.dim.toInteger;
    auto elements = new FfiType[](length);
    foreach (ref member; elements)
        member = element;
    return aggregateFfiType(elements);
}


private FfiType structFfiType(
    imported!"dmd.mtype".TypeStruct type,
) {
    if (type.sym.isUnionDeclaration !is null)
        return FfiType.init;

    auto fields = new FfiType[](type.sym.fields.length);
    foreach (index, field; type.sym.fields) {
        fields[index] = ffiTypeFor(field.type);
        if (fields[index].type is null)
            return FfiType.init;
    }
    return aggregateFfiType(fields);
}


private bool layoutMatches(
    imported!"dmd.mtype".Type type,
    ref FfiType metadata,
) {
    import dmd.astenums: TY;
    import dmd.typesem: size;

    // DMD's layout queries require its mutable semantic type node.
    auto baseType = type.toBasetype;
    if (baseType.ty != TY.Tsarray && baseType.ty != TY.Tstruct)
        return true;

    return metadata.type.size == size(baseType) &&
        metadata.type.alignment == baseType.alignsize;
}


private FfiType aggregateFfiType(
    FfiType[] members,
) {
    import quickbite.ffi.libffi: ffi_type, FFI_TYPE_STRUCT;

    auto ownedTypes = new ffi_type[1];
    auto elements = new ffi_type*[](members.length + 1);
    foreach (index, ref member; members)
        elements[index] = member.type;
    elements[$ - 1] = null;
    ownedTypes[0] = ffi_type(0, 0, FFI_TYPE_STRUCT, elements.ptr);
    // Keep every recursive descriptor and element array alive until ffi_call.
    return FfiType(&ownedTypes[0], ownedTypes, elements, members);
}

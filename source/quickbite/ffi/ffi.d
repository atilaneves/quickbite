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
    public imported!"dmd.func".FuncDeclaration declaration;
}


public struct TypedAddress {
    public imported!"dmd.mtype".Type type;
    public void* address;
}


public struct DVariadicMetadata {
    public TypedAddress value;
}


public bool call(
    Callable callable,
    TypedAddress[] arguments,
    TypedAddress result,
    TypedAddress* receiver = null,
    DVariadicMetadata* variadicMetadata = null,
) {
    import quickbite.ffi.libffi:
        ffi_arg, ffi_cif, ffi_call, ffi_prep_cif, ffi_prep_cif_var,
        ffi_status, ffi_type, ffi_type_pointer, ffi_type_void,
        FFI_DEFAULT_ABI;
    import dmd.astenums: LINK, TY, VarArg;

    if (callable.address is null || callable.signature is null ||
        callable.signature.next is null ||
        (callable.signature.linkage != LINK.c &&
            callable.signature.linkage != LINK.d &&
            callable.signature.linkage != LINK.cpp) ||
        (receiver !is null && callable.signature.linkage != LINK.d &&
            callable.signature.linkage != LINK.cpp) ||
        !hasSupportedVarArgs(callable.signature))
        return false;
    if (callable.declaration !is null &&
        !callable.declaration.type.toBasetype.equals(callable.signature))
        return false;
    const isCppConstructor = callable.declaration !is null &&
        callable.declaration.isCtorDeclaration !is null;
    const isCppSpecialMember = isCppConstructor ||
        callable.declaration !is null &&
        callable.declaration.isDtorDeclaration !is null;
    if (isCppSpecialMember &&
        (callable.signature.linkage != LINK.cpp || receiver is null))
        return false;

    const isCKRVariadic = hasKRVariadicArguments(callable.signature);
    const numFixedArguments = isCKRVariadic
        ? 0
        : callable.signature.parameterList.length;
    const hasCVariadicTail = hasCVariadicArguments(callable.signature);
    const isDVariadic = callable.signature.linkage == LINK.d &&
        callable.signature.parameterList.varargs == VarArg.variadic;
    const hasArgumentTail = hasCVariadicTail || isDVariadic;
    if (hasArgumentTail && arguments.length < numFixedArguments ||
        !hasArgumentTail && arguments.length != numFixedArguments)
        return false;
    if (isDVariadic != (variadicMetadata !is null))
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

    const returnsReference = !isCppConstructor && callable.signature.isRef;
    const returnsCppNonPod = callable.signature.linkage == LINK.cpp &&
        isCppInvisibleReference(returnType);
    auto resultMetadata = isCppConstructor
        ? FfiType(&ffi_type_void)
        : returnsReference
        ? FfiType(&ffi_type_pointer)
        : returnsCppNonPod
            ? cppNonPodReturnFfiType(returnType)
            : ffiTypeFor(returnType, true);
    if (resultMetadata.type is null)
        return false;

    const resultTy = semanticStorageType(returnType).ty;
    const returnsVoid = isCppConstructor || resultTy == TY.Tvoid ||
        resultTy == TY.Tnoreturn;
    if ((returnsReference || !returnsVoid) && result.address is null)
        return false;

    FfiType variadicMetadataType;
    if (isDVariadic) {
        if (variadicMetadata.value.type is null ||
            variadicMetadata.value.address is null)
            return false;
        const expectedType = callable.compilerAbi == CompilerAbi.dmd
            ? TY.Tclass
            : TY.Tarray;
        if (variadicMetadata.value.type.toBasetype.ty != expectedType)
            return false;
        variadicMetadataType = ffiTypeFor(variadicMetadata.value.type);
        if (variadicMetadataType.type is null)
            return false;
    }

    auto argumentIsIndirect = new bool[](arguments.length);
    auto argumentIsIgnored = new bool[](arguments.length);
    foreach (index, argument; arguments) {
        if (argument.type is null || argument.address is null)
            return false;

        const isFixedArgument = index < numFixedArguments;
        if (isFixedArgument) {
            auto parameter = callable.signature.parameterList[index];
            if (isLazyParameter(parameter)) {
                if (!isMatchingLazyDelegate(argument.type, parameter.type))
                    return false;
            } else if (!argument.type.toBasetype.equals(
                parameter.type.toBasetype,
            ))
                return false;
            argumentIsIndirect[index] = isReferenceParameter(parameter) ||
                callable.signature.linkage == LINK.cpp &&
                (argument.type.toBasetype.ty == TY.Treference ||
                    isCppInvisibleReference(argument.type));
        } else if (hasCVariadicTail &&
            !isPromotedVariadicType(argument.type))
            return false;
        argumentIsIgnored[index] = !argumentIsIndirect[index] &&
            isIgnoredSysVArgument(argument.type);
    }

    size_t numPassedArguments;
    foreach (ignored; argumentIsIgnored)
        numPassedArguments += !ignored;
    const numAbiArguments = numPassedArguments + hasReceiver + isDVariadic;
    auto argumentTypes = new ffi_type*[](numAbiArguments);
    auto argumentAddresses = new void*[](numAbiArguments);
    auto argumentMetadata = new FfiType[](numAbiArguments);
    auto argumentAbiIndices = new size_t[](arguments.length);
    size_t nextAbiIndex = hasReceiver + isDVariadic;
    const reversesArguments = callable.signature.linkage == LINK.d &&
        callable.compilerAbi == CompilerAbi.dmd && !isDVariadic;
    foreach (offset; 0 .. arguments.length) {
        const sourceIndex = reversesArguments
            ? arguments.length - offset - 1
            : offset;
        if (!argumentIsIgnored[sourceIndex])
            argumentAbiIndices[sourceIndex] = nextAbiIndex++;
    }
    if (hasReceiver) {
        argumentMetadata[0] = receiverMetadata;
        argumentTypes[0] = receiverMetadata.type;
        argumentAddresses[0] = receiverAddress;
    }
    if (isDVariadic) {
        const metadataIndex = hasReceiver;
        argumentMetadata[metadataIndex] = variadicMetadataType;
        argumentTypes[metadataIndex] = variadicMetadataType.type;
        argumentAddresses[metadataIndex] = variadicMetadata.value.address;
    }
    // Language references and C++ invisible-reference values are pointer ABI
    // arguments. Only each pointer cell is temporary: it points directly at
    // the caller's authoritative storage; no pointee bytes are copied.
    auto indirectCells = new void*[](arguments.length);
    foreach (index, argument; arguments) {
        if (argumentIsIgnored[index])
            continue;
        const abiIndex = argumentAbiIndices[index];
        argumentMetadata[abiIndex] = argumentIsIndirect[index]
            ? FfiType(&ffi_type_pointer)
            : ffiTypeFor(argument.type);
        argumentTypes[abiIndex] = argumentMetadata[abiIndex].type;
        if (argumentTypes[abiIndex] is null)
            return false;
        if (argumentIsIndirect[index]) {
            indirectCells[index] = argument.address;
            argumentAddresses[abiIndex] = &indirectCells[index];
        } else
            argumentAddresses[abiIndex] = argument.address;
    }

    ffi_cif cif;
    const prepStatus = hasCVariadicTail
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
    resultMetadata.restoreNativeLayout;
    if (!isCppConstructor && !returnsReference &&
        !layoutMatches(returnType, resultMetadata))
        return false;
    foreach (index; 0 .. arguments.length) {
        if (!argumentIsIndirect[index] &&
            !argumentIsIgnored[index] &&
            !layoutMatches(
                arguments[index].type,
                argumentMetadata[argumentAbiIndices[index]],
            ))
            return false;
    }

    // libffi requires narrow integer returns to use an ffi_arg-wide slot.
    // Copy only the static type's native width into the caller's storage.
    ffi_arg resultScratch;
    const resultCopySize = narrowIntegerResultSize(resultTy);
    void* resultAddress = returnsVoid && !returnsReference
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

    switch (semanticStorageType(type).ty) with (TY) {
        case Tbool, Tint8, Tuns8, Tchar, Tint16, Tuns16, Twchar, Tfloat32:
            return false;
        default:
            return true;
    }
}


private bool hasSupportedVarArgs(
    imported!"dmd.mtype".TypeFunction signature,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK, VarArg;

    const varargs = signature.parameterList.varargs;
    return varargs == VarArg.none || varargs == VarArg.variadic ||
        hasKRVariadicArguments(signature) ||
        signature.linkage == LINK.d && varargs == VarArg.typesafe;
}


private bool hasCVariadicArguments(
    imported!"dmd.mtype".TypeFunction signature,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK, VarArg;

    const varargs = signature.parameterList.varargs;
    return (signature.linkage == LINK.c || signature.linkage == LINK.cpp) &&
        (varargs == VarArg.variadic || varargs == VarArg.KRvariadic);
}


private bool hasKRVariadicArguments(
    imported!"dmd.mtype".TypeFunction signature,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK, VarArg;

    return (signature.linkage == LINK.c || signature.linkage == LINK.cpp) &&
        signature.parameterList.varargs == VarArg.KRvariadic;
}


private bool isCppInvisibleReference(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;
    import dmd.dsymbolsem: isPOD;

    auto storageType = semanticStorageType(type);
    return storageType.ty == TY.Tstruct &&
        !storageType.isTypeStruct.sym.isPOD;
}


private FfiType cppNonPodReturnFfiType(imported!"dmd.mtype".Type type) {
    import dmd.typesem: size;

    auto storageType = semanticStorageType(type);
    return memoryClassificationWitness(
        cast(size_t) size(storageType),
        cast(ushort) storageType.alignsize,
        true,
    );
}


private bool isLazyParameter(
    imported!"dmd.mtype".Parameter parameter,
) @safe @nogc nothrow pure {
    import dmd.astenums: STC;

    return (parameter.storageClass & STC.lazy_) != STC.none;
}


private bool isMatchingLazyDelegate(
    imported!"dmd.mtype".Type storageType,
    imported!"dmd.mtype".Type resultType,
) {
    import dmd.astenums: VarArg;

    auto delegateType = storageType.toBasetype.isTypeDelegate;
    if (delegateType is null)
        return false;
    auto signature = delegateType.next.toBasetype.isTypeFunction;
    return signature !is null &&
        signature.parameterList.length == 0 &&
        signature.parameterList.varargs == VarArg.none &&
        signature.next.toBasetype.equals(resultType.toBasetype);
}


private bool isReferenceParameter(
    imported!"dmd.mtype".Parameter parameter,
) @safe @nogc nothrow pure {
    import dmd.astenums: STC;

    return (parameter.storageClass & (STC.ref_ | STC.out_)) != STC.none;
}


private bool isIgnoredSysVArgument(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto storageType = semanticStorageType(type);
    if (storageType.ty != TY.Tsarray && storageType.ty != TY.Tstruct)
        return false;

    SysVClass[2] classes;
    return classifySysV(storageType, 0, classes) &&
        classes == [SysVClass.none, SysVClass.none];
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
    private size_t _nativeSize;
    private ushort _nativeAlignment;

    private imported!"quickbite.ffi.libffi".ffi_type* type()
        @safe @nogc nothrow pure {
        return _type;
    }

    private void restoreNativeLayout() @safe @nogc nothrow pure {
        if (_nativeSize == 0)
            return;
        _type.size = _nativeSize;
        _type.alignment = _nativeAlignment;
    }
}


private FfiType ffiTypeFor(
    imported!"dmd.mtype".Type type,
    in bool isReturn = false,
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
        case Tvoid, Tnoreturn: return FfiType(&ffi_type_void);
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
        case Tpointer, Treference, Tclass, Taarray, Tnull:
            return FfiType(&ffi_type_pointer);
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
        case Tstruct: return structFfiType(storageType.isTypeStruct, isReturn);
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
    in bool isReturn,
) {
    if (type.sym.isUnionDeclaration !is null)
        return sysVClassificationWitness(type, isReturn);

    if (!hasNaturalStructLayout(type))
        return sysVClassificationWitness(type, isReturn);

    auto fields = new FfiType[](type.sym.fields.length);
    foreach (index, field; type.sym.fields) {
        fields[index] = ffiTypeFor(field.type);
        if (fields[index].type is null)
            return FfiType.init;
    }
    return aggregateFfiType(fields);
}


private bool hasNaturalStructLayout(
    imported!"dmd.mtype".TypeStruct type,
) {
    import dmd.typesem: size;

    size_t offset;
    size_t alignment = 1;
    foreach (field; type.sym.fields) {
        const fieldAlignment = cast(size_t) field.type.alignsize;
        offset = alignedTo(offset, fieldAlignment);
        if (offset != cast(size_t) field.offset)
            return false;
        offset += cast(size_t) size(field.type);
        if (fieldAlignment > alignment)
            alignment = fieldAlignment;
    }
    return alignedTo(offset, alignment) == cast(size_t) size(type) &&
        alignment == type.alignsize;
}


private size_t alignedTo(
    in size_t offset,
    in size_t alignment,
) @safe @nogc nothrow pure {
    return (offset + alignment - 1) / alignment * alignment;
}


private enum SysVClass {
    none,
    integer,
    sse,
    x87,
    x87Up,
    memory,
}


private FfiType sysVClassificationWitness(
    imported!"dmd.mtype".Type type,
    in bool isReturn,
) {
    import quickbite.ffi.libffi:
        ffi_type_double, ffi_type_longdouble, ffi_type_uint64;
    import dmd.typesem: size;

    SysVClass[2] classes;
    if (!classifySysV(type, 0, classes))
        return FfiType.init;

    // DMD owns mutable semantic type nodes.
    auto storageType = semanticStorageType(type);
    const nativeSize = cast(size_t) size(storageType);
    const nativeAlignment = cast(ushort) storageType.alignsize;
    if (classes[0] == SysVClass.memory || classes[1] == SysVClass.memory)
        // A classification witness contains only libffi call metadata. It
        // neither describes nor touches the native value's bytes.
        return memoryClassificationWitness(
            nativeSize,
            nativeAlignment,
            isReturn,
        );
    if (classes == [SysVClass.x87, SysVClass.x87Up])
        return FfiType(&ffi_type_longdouble);

    auto members = new FfiType[]((nativeSize + 7) / 8);
    foreach (index, ref member; members) {
        final switch (classes[index]) with (SysVClass) {
            case sse: member = FfiType(&ffi_type_double); break;
            case none, integer: member = FfiType(&ffi_type_uint64); break;
            case x87, x87Up, memory: return FfiType.init;
        }
    }
    return sizedAggregateFfiType(nativeSize, nativeAlignment, members);
}


private FfiType memoryClassificationWitness(
    in size_t nativeSize,
    in ushort nativeAlignment,
    in bool isReturn,
) {
    import quickbite.ffi.libffi:
        ffi_type, ffi_type_longdouble, ffi_type_uint8, ffi_type_uint64;

    if (nativeSize > 16 || isReturn) {
        // libffi records MEMORY return handling while preparing the CIF from
        // this three-eightbyte size. Before ffi_call, the descriptor returns
        // to DMD's native layout so the sret destination is used directly.
        const preparedSize = nativeSize > 16
            ? nativeSize
            : 3 * ulong.sizeof;
        auto result = sizedAggregateFfiType(
            preparedSize,
            nativeAlignment,
            [
                FfiType(&ffi_type_uint64),
                FfiType(&ffi_type_uint64),
                FfiType(&ffi_type_uint64),
            ],
        );
        if (preparedSize != nativeSize) {
            result._nativeSize = nativeSize;
            result._nativeAlignment = nativeAlignment;
        }
        return result;
    }

    auto ownedTypes = new ffi_type[1];
    // Mixing X87 and INTEGER makes libffi classify the argument as MEMORY.
    // Shrinking the marker lets both classes fit inside the native outer size;
    // it is metadata only and does not read an X87 value from storage.
    ownedTypes[0] = ffi_type_longdouble;
    ownedTypes[0].size = 1;
    ownedTypes[0].alignment = 1;
    auto x87Marker = FfiType(&ownedTypes[0], ownedTypes);
    return sizedAggregateFfiType(
        nativeSize,
        nativeAlignment,
        [
            x87Marker,
            FfiType(&ffi_type_uint8),
        ],
    );
}


private bool classifySysV(
    imported!"dmd.mtype".Type type,
    in size_t offset,
    ref SysVClass[2] classes,
) {
    import dmd.astenums: TY;
    import dmd.typesem: size;

    // DMD owns mutable semantic type nodes.
    auto storageType = semanticStorageType(type);
    const nativeSize = cast(size_t) size(storageType);
    if (offset == 0 && nativeSize > 16) {
        classes[0] = SysVClass.memory;
        return true;
    }
    if (storageType.alignsize > 1 && offset % storageType.alignsize != 0) {
        classes[0] = SysVClass.memory;
        return true;
    }

    switch (storageType.ty) with (TY) {
        case Tbool, Tint8, Tuns8, Tchar, Tint16, Tuns16, Twchar,
                Tint32, Tuns32, Tdchar, Tint64, Tuns64, Tpointer, Tclass,
                Taarray:
            return mergeSysVRange(classes, offset, nativeSize,
                SysVClass.integer);
        case Tint128, Tuns128:
            return mergeSysVRange(classes, offset, nativeSize,
                SysVClass.integer);
        case Tarray, Tdelegate:
            return mergeSysVRange(classes, offset, nativeSize,
                SysVClass.integer);
        case Tfloat32, Tfloat64, Timaginary32, Timaginary64, Tcomplex32,
                Tcomplex64:
            return mergeSysVRange(classes, offset, nativeSize, SysVClass.sse);
        case Tfloat80, Timaginary80:
            return mergeSysVLongDouble(classes, offset);
        case Tcomplex80:
            classes[0] = SysVClass.memory;
            return true;
        case Tvoid, Tnoreturn:
            return true;
        case Tsarray:
            const length = cast(size_t) storageType.isTypeSArray.dim.toInteger;
            const elementSize = cast(size_t) size(storageType.nextOf);
            foreach (index; 0 .. length)
                if (!classifySysV(
                    storageType.nextOf,
                    offset + index * elementSize,
                    classes,
                ))
                    return false;
            return true;
        case Tstruct:
            foreach (field; storageType.isTypeStruct.sym.fields)
                if (!classifySysV(
                    field.type,
                    offset + cast(size_t) field.offset,
                    classes,
                ))
                    return false;
            return true;
        case Tvector:
            // Vector SSEUP classification needs a faithful libffi witness of
            // its own; scalar SSE metadata must not stand in for it.
            return false;
        default:
            return false;
    }
}


private bool mergeSysVRange(
    ref SysVClass[2] classes,
    in size_t offset,
    in size_t size,
    in SysVClass incoming,
) @safe @nogc nothrow pure {
    if (size == 0)
        return true;
    const firstLane = offset / 8;
    const lastLane = (offset + size - 1) / 8;
    if (lastLane >= classes.length) {
        classes[0] = SysVClass.memory;
        return true;
    }
    foreach (lane; firstLane .. lastLane + 1)
        classes[lane] = mergeSysV(classes[lane], incoming);
    return true;
}


private bool mergeSysVLongDouble(
    ref SysVClass[2] classes,
    in size_t offset,
) @safe @nogc nothrow pure {
    if (offset != 0) {
        classes[0] = SysVClass.memory;
        return true;
    }
    classes[0] = mergeSysV(classes[0], SysVClass.x87);
    classes[1] = mergeSysV(classes[1], SysVClass.x87Up);
    if (classes[0] == SysVClass.memory || classes[1] == SysVClass.memory)
        classes[0] = SysVClass.memory;
    return true;
}


private SysVClass mergeSysV(
    in SysVClass existing,
    in SysVClass incoming,
) @safe @nogc nothrow pure {
    if (existing == SysVClass.none || existing == incoming)
        return incoming;
    if (incoming == SysVClass.none)
        return existing;
    if (existing == SysVClass.memory || incoming == SysVClass.memory)
        return SysVClass.memory;
    if (existing == SysVClass.x87 || existing == SysVClass.x87Up ||
        incoming == SysVClass.x87 || incoming == SysVClass.x87Up)
        return SysVClass.memory;
    if (existing == SysVClass.integer || incoming == SysVClass.integer)
        return SysVClass.integer;
    if (existing == SysVClass.sse && incoming == SysVClass.sse)
        return SysVClass.sse;
    return SysVClass.memory;
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
    return sizedAggregateFfiType(0, 0, members);
}


private FfiType sizedAggregateFfiType(
    in size_t size,
    in ushort alignment,
    FfiType[] members,
) {
    import quickbite.ffi.libffi: ffi_type, FFI_TYPE_STRUCT;

    auto ownedTypes = new ffi_type[1];
    auto elements = new ffi_type*[](members.length + 1);
    foreach (index, ref member; members)
        elements[index] = member.type;
    elements[$ - 1] = null;
    ownedTypes[0] = ffi_type(size, alignment, FFI_TYPE_STRUCT, elements.ptr);
    // Keep every recursive descriptor and element array alive until ffi_call.
    return FfiType(&ownedTypes[0], ownedTypes, elements, members);
}

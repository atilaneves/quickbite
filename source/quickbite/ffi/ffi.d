module quickbite.ffi.ffi;

private:


public enum CompilerAbi {
    dmd,
    ldc,
}


public struct Callable {
    public void* address;
    public imported!"dmd.astenums".LINK linkage;
    public CompilerAbi compilerAbi;
}


public struct TypedAddress {
    public imported!"dmd.mtype".Type type;
    public void* address;
}


public bool call(
    in Callable callable,
    TypedAddress[] arguments,
    TypedAddress result,
) {
    import quickbite.ffi.libffi:
        ffi_arg, ffi_cif, ffi_call, ffi_prep_cif, ffi_status, ffi_type,
        FFI_DEFAULT_ABI;
    import dmd.astenums: LINK, TY;

    if (callable.address is null ||
        (callable.linkage != LINK.c && callable.linkage != LINK.d))
        return false;

    auto resultMetadata = ffiTypeFor(result.type);
    if (resultMetadata.type is null)
        return false;

    const resultTy = result.type.toBasetype.ty;
    if (resultTy != TY.Tvoid && result.address is null)
        return false;

    auto argumentTypes = new ffi_type*[](arguments.length);
    auto argumentAddresses = new void*[](arguments.length);
    auto argumentMetadata = new FfiType[](arguments.length);
    foreach (index, argument; arguments) {
        const abiIndex = abiArgumentIndex(callable, index, arguments.length);
        argumentMetadata[abiIndex] = ffiTypeFor(argument.type);
        argumentTypes[abiIndex] = argumentMetadata[abiIndex].type;
        if (argumentTypes[abiIndex] is null || argument.address is null)
            return false;
        argumentAddresses[abiIndex] = argument.address;
    }

    ffi_cif cif;
    const prepStatus = ffi_prep_cif(
        &cif,
        FFI_DEFAULT_ABI,
        cast(uint) arguments.length,
        resultMetadata.type,
        argumentTypes.ptr,
    );
    if (prepStatus != ffi_status.FFI_OK)
        return false;
    if (!layoutMatches(result.type, resultMetadata))
        return false;
    foreach (index, argument; arguments)
        if (!layoutMatches(
            argument.type,
            argumentMetadata[abiArgumentIndex(
                callable,
                index,
                arguments.length,
            )],
        ))
            return false;

    // libffi requires narrow integer returns to use an ffi_arg-wide slot.
    // Copy only the static type's native width into the caller's storage.
    ffi_arg resultScratch;
    const resultCopySize = narrowIntegerResultSize(resultTy);
    void* resultAddress = resultTy == TY.Tvoid
        ? null
        : resultCopySize == 0 ? result.address : &resultScratch;
    alias CFunction = extern(C) void function();
    ffi_call(
        &cif,
        cast(CFunction) callable.address,
        resultAddress,
        argumentAddresses.ptr,
    );

    if (resultCopySize != 0) {
        import core.stdc.string: memcpy;
        memcpy(result.address, &resultScratch, resultCopySize);
    }
    return true;
}


private size_t abiArgumentIndex(
    in Callable callable,
    in size_t sourceIndex,
    in size_t numArguments,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK;

    return callable.linkage == LINK.d &&
            callable.compilerAbi == CompilerAbi.dmd
        ? numArguments - sourceIndex - 1
        : sourceIndex;
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
        ffi_type_double, ffi_type_float, ffi_type_longdouble, ffi_type_pointer,
        ffi_type_sint8, ffi_type_sint16, ffi_type_sint32, ffi_type_sint64,
        ffi_type_uint8, ffi_type_uint16, ffi_type_uint32, ffi_type_uint64,
        ffi_type_void;
    import dmd.astenums: TY;

    if (type is null)
        return FfiType.init;

    switch (type.toBasetype.ty) with (TY) {
        case Tvoid: return FfiType(&ffi_type_void);
        case Tbool, Tuns8, Tchar: return FfiType(&ffi_type_uint8);
        case Tint8: return FfiType(&ffi_type_sint8);
        case Tuns16, Twchar: return FfiType(&ffi_type_uint16);
        case Tint16: return FfiType(&ffi_type_sint16);
        case Tuns32, Tdchar: return FfiType(&ffi_type_uint32);
        case Tint32: return FfiType(&ffi_type_sint32);
        case Tuns64: return FfiType(&ffi_type_uint64);
        case Tint64: return FfiType(&ffi_type_sint64);
        case Tfloat32: return FfiType(&ffi_type_float);
        case Tfloat64: return FfiType(&ffi_type_double);
        case Tfloat80: return FfiType(&ffi_type_longdouble);
        case Tpointer, Tclass: return FfiType(&ffi_type_pointer);
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
        case Tsarray: return staticArrayFfiType(type.toBasetype.isTypeSArray);
        case Tstruct: return structFfiType(type.toBasetype.isTypeStruct);
        default: return FfiType.init;
    }
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

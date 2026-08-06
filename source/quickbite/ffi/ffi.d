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

    auto resultFfiType = ffiTypeFor(result.type);
    if (resultFfiType is null)
        return false;

    const resultTy = result.type.toBasetype.ty;
    if (resultTy != TY.Tvoid && result.address is null)
        return false;

    auto argumentTypes = new ffi_type*[](arguments.length);
    auto argumentAddresses = new void*[](arguments.length);
    foreach (index, argument; arguments) {
        const abiIndex = abiArgumentIndex(callable, index, arguments.length);
        argumentTypes[abiIndex] = ffiTypeFor(argument.type);
        if (argumentTypes[abiIndex] is null || argument.address is null)
            return false;
        argumentAddresses[abiIndex] = argument.address;
    }

    ffi_cif cif;
    const prepStatus = ffi_prep_cif(
        &cif,
        FFI_DEFAULT_ABI,
        cast(uint) arguments.length,
        resultFfiType,
        argumentTypes.ptr,
    );
    if (prepStatus != ffi_status.FFI_OK)
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


private imported!"quickbite.ffi.libffi".ffi_type* ffiTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.ffi.libffi:
        ffi_type_double, ffi_type_float, ffi_type_longdouble, ffi_type_pointer,
        ffi_type_sint8, ffi_type_sint16, ffi_type_sint32, ffi_type_sint64,
        ffi_type_uint8, ffi_type_uint16, ffi_type_uint32, ffi_type_uint64,
        ffi_type_void;
    import dmd.astenums: TY;

    if (type is null)
        return null;

    switch (type.toBasetype.ty) with (TY) {
        case Tvoid: return &ffi_type_void;
        case Tbool, Tuns8, Tchar: return &ffi_type_uint8;
        case Tint8: return &ffi_type_sint8;
        case Tuns16, Twchar: return &ffi_type_uint16;
        case Tint16: return &ffi_type_sint16;
        case Tuns32, Tdchar: return &ffi_type_uint32;
        case Tint32: return &ffi_type_sint32;
        case Tuns64: return &ffi_type_uint64;
        case Tint64: return &ffi_type_sint64;
        case Tfloat32: return &ffi_type_float;
        case Tfloat64: return &ffi_type_double;
        case Tfloat80: return &ffi_type_longdouble;
        case Tpointer, Tclass: return &ffi_type_pointer;
        default: return null;
    }
}

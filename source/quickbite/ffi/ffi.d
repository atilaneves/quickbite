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
    import dmd.astenums: LINK;

    if (callable.address is null || callable.linkage != LINK.c ||
        result.address is null)
        return false;

    auto resultFfiType = ffiTypeFor(result.type);
    if (resultFfiType is null)
        return false;

    auto argumentTypes = new ffi_type*[](arguments.length);
    auto argumentAddresses = new void*[](arguments.length);
    foreach (index, argument; arguments) {
        argumentTypes[index] = ffiTypeFor(argument.type);
        if (argumentTypes[index] is null || argument.address is null)
            return false;
        argumentAddresses[index] = argument.address;
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
    alias CFunction = extern(C) void function();
    ffi_call(
        &cif,
        cast(CFunction) callable.address,
        &resultScratch,
        argumentAddresses.ptr,
    );

    import core.stdc.string: memcpy;
    memcpy(result.address, &resultScratch, int.sizeof);
    return true;
}


private imported!"quickbite.ffi.libffi".ffi_type* ffiTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.ffi.libffi:
        ffi_type_sint32;
    import dmd.astenums: TY;

    return type !is null && type.toBasetype.ty == TY.Tint32
        ? &ffi_type_sint32
        : null;
}

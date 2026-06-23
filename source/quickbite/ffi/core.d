module quickbite.ffi.core;

private:


public void loadDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages)
        loadDependencyImage(dependencyImage);
}

public class NativeCallException: Exception {
    public string className;
    // The native Throwable.next link, captured as another NativeCallException
    // so the backend can rebuild the chain (ffi.md §34.13). Null at the tail.
    public NativeCallException chainedNext;

    public this(in string message, in string className) {
        super(message);
        this.className = className;
    }
}

// The seam (ffi.md §5): the backend injects ABI-byte conversion so the core
// never names a backend value type. `fill*` write argument/receiver bytes into
// a buffer sized to the matching ffi_type; `readResult`/`writeOutParameter`
// reify the return and out-parameter bytes into backend-owned state.
public interface NativeMarshaller {
    void fillArgument(
        ubyte[] buffer,
        imported!"dmd.mtype".Type type,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    );

    void fillReceiver(
        ubyte[] buffer,
        imported!"dmd.mtype".Type type,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    );

    void readResult(imported!"dmd.mtype".Type type, in ubyte[] buffer);

    void writeOutParameter(in size_t index, void* writtenPointer);
}

public bool callNative(
    imported!"dmd.func".FuncDeclaration function_,
    NativeMarshaller marshaller,
    in size_t argumentCount,
) {
    return callNativeImpl(
        function_,
        NativeThis.init,
        marshaller,
        argumentCount,
    );
}

public bool callNativeMember(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.mtype".TypeStruct receiverType,
    NativeMarshaller marshaller,
    in size_t argumentCount,
) {
    if (receiverType is null)
        return false;

    return callNativeImpl(
        function_,
        NativeThis(receiverType, true),
        marshaller,
        argumentCount,
    );
}

private struct NativeThis {
    private imported!"dmd.mtype".TypeStruct type;
    private bool enabled;
}

private bool callNativeImpl(
    imported!"dmd.func".FuncDeclaration function_,
    NativeThis receiver,
    NativeMarshaller marshaller,
    in size_t argumentCount,
) {
    import core.sys.posix.dlfcn: dlsym;
    version (DragonFlyBSD) import core.sys.dragonflybsd.dlfcn: RTLD_DEFAULT;
    version (FreeBSD) import core.sys.freebsd.dlfcn: RTLD_DEFAULT;
    version (linux) import core.sys.linux.dlfcn: RTLD_DEFAULT;
    version (NetBSD) import core.sys.netbsd.dlfcn: RTLD_DEFAULT;
    version (OpenBSD) import core.sys.openbsd.dlfcn: RTLD_DEFAULT;
    version (OSX) import core.sys.darwin.dlfcn: RTLD_DEFAULT;
    version (Solaris) import core.sys.solaris.dlfcn: RTLD_DEFAULT;
    import dmd.astenums: LINK, VarArg;
    import dmd.mangle: mangleExact;
    import dmd.mtype: TypeFunction;
    import std.string: fromStringz;

    if (!isSupportedNativeLinkage(function_._linkage))
        return false;

    auto type = cast(TypeFunction) function_.type;
    if (type is null)
        return false;

    // Variadic libc functions (printf) need ffi_prep_cif_var; deferred.
    if (type.parameterList.varargs != VarArg.none)
        return false;

    const symbol = dlsym(RTLD_DEFAULT, mangleExact(function_));
    if (symbol is null)
        throw new Exception(
            "Native symbol `" ~
            fromStringz(mangleExact(function_)).idup ~
            "` is not loaded",
        );

    return callViaLibffi(
        function_._linkage,
        type,
        symbol,
        receiver,
        marshaller,
        argumentCount,
    );
}

private void loadDependencyImage(in string dependencyImage) {
    import core.sys.posix.dlfcn: dlerror, dlopen, RTLD_GLOBAL, RTLD_NOW;
    import std.conv: text;
    import std.string: fromStringz, toStringz;

    if (dlopen(dependencyImage.toStringz, RTLD_NOW | RTLD_GLOBAL) is null) {
        auto err = dlerror();
        throw new Exception(text(
            "failed to load dependency image: ",
            dependencyImage,
            err is null ? "" : text(" :: ", err.fromStringz),
        ));
    }
}

private bool isSupportedNativeLinkage(
    imported!"dmd.astenums".LINK linkage,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK;

    return linkage == LINK.c || linkage == LINK.d;
}

// Build a libffi call interface from the function signature, have the injected
// marshaller fill the raw ABI buffers, perform the call, and have the marshaller
// reify the result (and any out-parameter writeback). Returns false for any
// signature shape not yet modelled, preserving the caller's no-available-source
// diagnostic.
private bool callViaLibffi(
    imported!"dmd.astenums".LINK linkage,
    imported!"dmd.mtype".TypeFunction type,
    const void* symbol,
    NativeThis receiver,
    NativeMarshaller marshaller,
    in size_t nargs,
) {
    import quickbite.ffi.libffi:
        ffi_cif, ffi_type, ffi_type_pointer, ffi_status, ffi_prep_cif,
        ffi_call, FFI_DEFAULT_ABI;
    import dmd.astenums: LINK, TY;
    import dmd.mtype: Type;
    import dmd.typesem: size;

    // Mutable Type: ffiTypeFor and dmd.typesem.size both need a non-const Type.
    auto returnType = type.next.toBasetype;
    auto returnFfi = ffiTypeFor(returnType);
    if (returnFfi is null)
        return false;

    auto parameterTypes = new Type[](nargs);
    auto argumentFfiTypes = new ffi_type*[](nargs);
    foreach (index; 0 .. nargs) {
        parameterTypes[index] = parameterType(type, index);
        argumentFfiTypes[index] = ffiArgumentTypeFor(parameterTypes[index]);
        if (argumentFfiTypes[index] is null)
            return false;
    }
    if (receiver.enabled && ffiTypeFor(receiver.type) is null)
        return false;
    const hiddenNargs = receiver.enabled ? 1 : 0;
    const totalNargs = hiddenNargs + nargs;
    auto abiArgumentFfiTypes = new ffi_type*[](totalNargs);
    if (receiver.enabled)
        abiArgumentFfiTypes[0] = &ffi_type_pointer;
    foreach (abiIndex; 0 .. nargs)
        abiArgumentFfiTypes[hiddenNargs + abiIndex] =
            argumentFfiTypes[abiSourceIndex(linkage, nargs, abiIndex)];

    // strtol's `endptr` writes a pointer into its string argument's buffer, so
    // any string argument of a call with an out-pointer must outlive the call.
    bool hasOutPointer;
    foreach (parameter; parameterTypes)
        if (isOutPointer(parameter))
            hasOutPointer = true;

    ffi_cif cif;
    if (
        ffi_prep_cif(
            &cif,
            FFI_DEFAULT_ABI,
            cast(uint) totalNargs,
            returnFfi,
            abiArgumentFfiTypes.ptr,
        ) != ffi_status.FFI_OK
    )
        return false;

    // libffi fills in struct ffi_type sizes during prep; cross-check against
    // DMD's computed layout (ffi.md §24.3).
    if (returnType.ty == TY.Tstruct)
        assert(returnFfi.size == cast(size_t) size(returnType));
    foreach (index; 0 .. nargs)
        if (parameterTypes[index].ty == TY.Tstruct)
            assert(argumentFfiTypes[index].size ==
                cast(size_t) size(parameterTypes[index]));

    // Native buffers marshalled for pointer/slice arguments, kept alive across
    // the call below so the GC cannot reclaim them mid-call.
    const(char)*[] keepAlive;
    ubyte[][] keepAliveBuffers;
    ubyte[] receiverBuffer;
    ubyte[] receiverPointerBuffer;
    if (receiver.enabled) {
        receiverBuffer = new ubyte[](cast(size_t) size(receiver.type));
        marshaller.fillReceiver(
            receiverBuffer,
            receiver.type,
            hasOutPointer,
            keepAlive,
            keepAliveBuffers,
        );

        receiverPointerBuffer = new ubyte[](ffi_type_pointer.size);
        *cast(void**) receiverPointerBuffer.ptr = receiverBuffer.ptr;
    }

    auto argumentBuffers = new ubyte[][](nargs);
    auto argumentValues = new void*[](nargs);
    auto outParameterCells = new void**[](nargs);

    foreach (index; 0 .. nargs) {
        argumentBuffers[index] = new ubyte[](argumentFfiTypes[index].size);

        if (isOutPointer(parameterTypes[index])) {
            // Allocate a host cell, pass its address as the out parameter, and
            // report the written pointer back through writeOutParameter.
            auto cell = new void*;
            outParameterCells[index] = cell;
            *cast(void**) argumentBuffers[index].ptr = cast(void*) cell;
        } else {
            marshaller.fillArgument(
                argumentBuffers[index],
                parameterTypes[index],
                index,
                hasOutPointer,
                keepAlive,
                keepAliveBuffers,
            );
        }

        argumentValues[index] = argumentBuffers[index].ptr;
    }
    auto abiArgumentValues = new void*[](totalNargs);
    if (receiver.enabled)
        abiArgumentValues[0] = receiverPointerBuffer.ptr;
    foreach (abiIndex; 0 .. nargs)
        abiArgumentValues[hiddenNargs + abiIndex] =
            argumentValues[abiSourceIndex(linkage, nargs, abiIndex)];

    // The return buffer must be at least ffi_arg-wide (8 bytes) and aligned,
    // even for narrow returns.
    const returnSize = returnFfi.size < 8 ? 8 : returnFfi.size;
    auto returnBuffer = new ubyte[](returnSize);

    // Pin the marshalled C-string buffers so a collection triggered by a D
    // allocation cannot reclaim them while the native call reads through them.
    import core.memory: GC;
    foreach (root; keepAlive)
        GC.addRoot(root);
    scope(exit) foreach (root; keepAlive)
        GC.removeRoot(root);

    alias CFunction = extern(C) void function();
    try {
        ffi_call(
            &cif,
            cast(CFunction) symbol,
            returnBuffer.ptr,
            abiArgumentValues.ptr,
        );
    } catch (Exception exception) {
        throw nativeCallExceptionFrom(exception);
    }

    foreach (index; 0 .. nargs) {
        if (outParameterCells[index] is null)
            continue;
        marshaller.writeOutParameter(index, *outParameterCells[index]);
    }

    marshaller.readResult(returnType, returnBuffer);
    return true;
}

// Capture the caught native Throwable and its `.next` chain as a linked
// NativeCallException, preserving each link's message and dynamic class name so
// the backend can rebuild the interpreted chain (ffi.md §34.13). Only Exception
// is caught at the call site; Error stays fatal.
private NativeCallException nativeCallExceptionFrom(Throwable throwable) {
    auto result = new NativeCallException(throwable.msg, throwable.classinfo.name);
    if (throwable.next !is null)
        result.chainedNext = nativeCallExceptionFrom(throwable.next);
    return result;
}

private size_t abiSourceIndex(
    imported!"dmd.astenums".LINK linkage,
    in size_t argumentCount,
    in size_t abiIndex,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK;

    return linkage == LINK.d ? argumentCount - abiIndex - 1 : abiIndex;
}

private imported!"quickbite.ffi.libffi".ffi_type* ffiArgumentTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    if (type.ty == TY.Tarray)
        return isSupportedScalarSlice(type) ? ffiSliceType : null;

    return ffiTypeFor(type);
}

// Map a DMD basetype to the matching libffi ffi_type, or null if unmodelled.
private imported!"quickbite.ffi.libffi".ffi_type* ffiTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.ffi.libffi;
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct;

    switch (type.ty) {
        case TY.Tvoid:                 return &ffi_type_void;
        case TY.Tbool, TY.Tchar,
             TY.Tuns8:                 return &ffi_type_uint8;
        case TY.Tint8:                 return &ffi_type_sint8;
        case TY.Tuns16, TY.Twchar:     return &ffi_type_uint16;
        case TY.Tint16:                return &ffi_type_sint16;
        case TY.Tuns32, TY.Tdchar:     return &ffi_type_uint32;
        case TY.Tint32:                return &ffi_type_sint32;
        case TY.Tuns64:                return &ffi_type_uint64;
        case TY.Tint64:                return &ffi_type_sint64;
        case TY.Tfloat32:              return &ffi_type_float;
        case TY.Tfloat64:              return &ffi_type_double;
        case TY.Tfloat80:              return &ffi_type_longdouble;
        case TY.Tpointer:              return &ffi_type_pointer;
        case TY.Tarray:
            return isSupportedScalarSlice(type) ? ffiSliceType : null;
        case TY.Tstruct:               return ffiStructType(cast(TypeStruct) type);
        default:                       return null;
    }
}

// Synthesize a STRUCT ffi_type by walking the struct's fields; libffi computes
// the laid-out size and alignment during ffi_prep_cif.
private imported!"quickbite.ffi.libffi".ffi_type* ffiStructType(
    imported!"dmd.mtype".TypeStruct type,
) {
    import quickbite.ffi.libffi: ffi_type, FFI_TYPE_STRUCT;

    auto sym = type.sym;
    auto elements = new ffi_type*[](sym.fields.length + 1);
    foreach (index; 0 .. sym.fields.length) {
        elements[index] = ffiTypeFor(sym.fields[index].type.toBasetype);
        if (elements[index] is null)
            return null;
    }
    elements[$ - 1] = null;

    auto result = new ffi_type;
    result.type = FFI_TYPE_STRUCT;
    result.elements = elements.ptr;
    return result;
}

private imported!"quickbite.ffi.libffi".ffi_type* ffiSliceType() {
    import quickbite.ffi.libffi:
        ffi_type, ffi_type_pointer, ffi_type_uint32, ffi_type_uint64,
        FFI_TYPE_STRUCT;

    auto elements = new ffi_type*[](3);
    elements[0] = size_t.sizeof == ulong.sizeof
        ? &ffi_type_uint64
        : &ffi_type_uint32;
    elements[1] = &ffi_type_pointer;
    elements[2] = null;

    auto result = new ffi_type;
    result.type = FFI_TYPE_STRUCT;
    result.elements = elements.ptr;
    return result;
}

public bool isSupportedScalarSlice(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type.ty != TY.Tarray)
        return false;

    switch (type.nextOf.toBasetype.ty) with (TY) {
        case Tbool, Tchar, Twchar, Tdchar,
             Tint8, Tuns8, Tint16, Tuns16,
             Tint32, Tuns32, Tint64, Tuns64,
             Tfloat32, Tfloat64, Tfloat80:
            return true;

        default:
            return false;
    }
}

// A pointer-to-pointer parameter (e.g. strtol's `char** endptr`) is an out
// slot rather than an in value.
private bool isOutPointer(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.ty == TY.Tpointer && type.nextOf.toBasetype.ty == TY.Tpointer;
}

private imported!"dmd.mtype".Type parameterType(
    imported!"dmd.mtype".TypeFunction functionType,
    in size_t index,
) {
    return (*functionType.parameterList.parameters)[index].type.toBasetype;
}

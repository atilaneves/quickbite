module quickbite.backends.ffi;

private:


public void loadDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages)
        loadDependencyImage(dependencyImage);
}

public class NativeCallException: Exception {
    public string className;

    public this(in string message, in string className) {
        super(message);
        this.className = className;
    }
}

public bool tryCallNative(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.lang".Value[] arguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    return tryCallNativeImpl(
        function_,
        NativeThis.init,
        arguments,
        result,
        argumentWritebacks,
    );
}

public bool tryCallNativeMember(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.mtype".TypeStruct receiverType,
    in imported!"quickbite.lang".Value receiver,
    in imported!"quickbite.lang".Value[] arguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    if (receiverType is null || !receiver.isStruct)
        return false;

    return tryCallNativeImpl(
        function_,
        NativeThis(receiverType, receiver, true),
        arguments,
        result,
        argumentWritebacks,
    );
}

private struct NativeThis {
    private imported!"dmd.mtype".TypeStruct type;
    private imported!"quickbite.lang".Value value;
    private bool enabled;
}

private bool tryCallNativeImpl(
    imported!"dmd.func".FuncDeclaration function_,
    NativeThis receiver,
    in imported!"quickbite.lang".Value[] arguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
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
        arguments,
        result,
        argumentWritebacks,
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

// Build a libffi call interface from the function signature, marshal the
// backend values into raw ABI buffers, perform the call, and marshal the
// result (and any out-parameter writeback) back into backend values. Returns
// false for any signature shape not yet modelled, preserving the caller's
// no-available-source diagnostic.
private bool callViaLibffi(
    imported!"dmd.astenums".LINK linkage,
    imported!"dmd.mtype".TypeFunction type,
    const void* symbol,
    NativeThis receiver,
    in imported!"quickbite.lang".Value[] arguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    import quickbite.backends.libffi:
        ffi_cif, ffi_type, ffi_type_pointer, ffi_status, ffi_prep_cif,
        ffi_call, FFI_DEFAULT_ABI;
    import quickbite.lang: Value;
    import dmd.astenums: LINK, TY;
    import dmd.mtype: Type;
    import dmd.typesem: size;

    // Mutable Type: ffiTypeFor and dmd.typesem.size both need a non-const Type.
    auto returnType = type.next.toBasetype;
    auto returnFfi = ffiTypeFor(returnType);
    if (returnFfi is null)
        return false;

    const nargs = arguments.length;
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
    if (
        linkage == LINK.d &&
        !externDArgumentsFitRegisterScope(parameterTypes, receiver.enabled)
    )
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
        marshalArgument(
            receiverBuffer,
            receiver.type,
            receiver.value,
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
            // report the written pointer back through argumentWritebacks.
            auto cell = new void*;
            outParameterCells[index] = cell;
            *cast(void**) argumentBuffers[index].ptr = cast(void*) cell;
        } else {
            marshalArgument(
                argumentBuffers[index],
                parameterTypes[index],
                arguments[index],
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
        throw new NativeCallException(exception.msg, exception.classinfo.name);
    }

    foreach (index; 0 .. nargs) {
        if (outParameterCells[index] is null)
            continue;
        if (argumentWritebacks.length == 0)
            argumentWritebacks = new Value[](nargs);
        argumentWritebacks[index] =
            Value.nativePointerValue(*outParameterCells[index]);
    }

    result = unmarshalValue(returnType, returnBuffer);
    return true;
}

private size_t abiSourceIndex(
    imported!"dmd.astenums".LINK linkage,
    in size_t argumentCount,
    in size_t abiIndex,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK;

    return linkage == LINK.d ? argumentCount - abiIndex - 1 : abiIndex;
}

private bool externDArgumentsFitRegisterScope(
    in imported!"dmd.mtype".Type[] parameterTypes,
    in bool hasHiddenThis,
) @safe @nogc nothrow pure {
    import dmd.astenums: TY;

    size_t integerRegisters = hasHiddenThis ? 1 : 0;
    size_t sseRegisters;
    foreach (parameterType; parameterTypes) {
        switch (parameterType.ty) {
            case TY.Tbool, TY.Tchar, TY.Twchar, TY.Tdchar,
                 TY.Tint8, TY.Tuns8, TY.Tint16, TY.Tuns16,
                 TY.Tint32, TY.Tuns32, TY.Tint64, TY.Tuns64,
                 TY.Tpointer:
                ++integerRegisters;
                break;

            case TY.Tarray:
                integerRegisters += 2;
                break;

            case TY.Tfloat32, TY.Tfloat64:
                ++sseRegisters;
                break;

            default:
                return false;
        }
    }

    return integerRegisters <= 6 && sseRegisters <= 8;
}

private imported!"quickbite.backends.libffi".ffi_type* ffiArgumentTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    if (type.ty == TY.Tarray)
        return isSupportedScalarSlice(type) ? ffiSliceType : null;

    return ffiTypeFor(type);
}

// Map a DMD basetype to the matching libffi ffi_type, or null if unmodelled.
private imported!"quickbite.backends.libffi".ffi_type* ffiTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.backends.libffi;
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
private imported!"quickbite.backends.libffi".ffi_type* ffiStructType(
    imported!"dmd.mtype".TypeStruct type,
) {
    import quickbite.backends.libffi: ffi_type, FFI_TYPE_STRUCT;

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

private imported!"quickbite.backends.libffi".ffi_type* ffiSliceType() {
    import quickbite.backends.libffi:
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

private bool isSupportedScalarSlice(imported!"dmd.mtype".Type type) {
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

// Marshal one backend value into a raw ABI buffer sized to its ffi_type.
private void marshalArgument(
    ubyte[] buffer,
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.lang".Value value,
    in bool stableString,
    ref const(char)*[] keepAlive,
    ref ubyte[][] keepAliveBuffers,
) {
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct;
    import dmd.typesem: size;

    switch (type.ty) {
        case TY.Tbool, TY.Tchar, TY.Twchar, TY.Tdchar,
             TY.Tint8, TY.Tuns8, TY.Tint16, TY.Tuns16,
             TY.Tint32, TY.Tuns32, TY.Tint64, TY.Tuns64:
            const scalar = scalarBits(type, value);
            foreach (index; 0 .. buffer.length)
                buffer[index] = cast(ubyte) (scalar >> (8 * index));
            return;

        case TY.Tfloat32:
            *cast(float*) buffer.ptr = cast(float) value.asReal;
            return;

        case TY.Tfloat64:
            *cast(double*) buffer.ptr = cast(double) value.asReal;
            return;

        case TY.Tfloat80:
            *cast(real*) buffer.ptr = value.asReal;
            return;

        case TY.Tpointer:
            *cast(void**) buffer.ptr =
                marshalPointerArgument(type, value, stableString, keepAlive);
            return;

        case TY.Tarray:
            marshalSliceArgument(buffer, type, value, keepAliveBuffers);
            return;

        case TY.Tstruct:
            auto sym = (cast(TypeStruct) type).sym;
            foreach (index; 0 .. sym.fields.length) {
                auto field = sym.fields[index];
                auto fieldType = field.type.toBasetype;  // mutable for size()
                const fieldSize = cast(size_t) size(fieldType);
                marshalArgument(
                    buffer[field.offset .. field.offset + fieldSize],
                    fieldType,
                    value.structFieldAt(index),
                    stableString,
                    keepAlive,
                    keepAliveBuffers,
                );
            }
            return;

        default:
            assert(false, "unmarshalled libffi argument type");
    }
}

private long scalarBits(
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.lang".Value value,
) @safe pure {
    import dmd.astenums: TY;

    switch (type.ty) with (TY) {
        case Tchar, Twchar, Tdchar:
            return value.castTo!long.asLong;

        default:
            return value.asLong;
    }
}

private void* marshalPointerArgument(
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.lang".Value value,
    in bool stableString,
    ref const(char)*[] keepAlive,
) {
    import dmd.astenums: TY;

    // A `char*`/`const char*` accepts a backend char array; everything else is
    // a raw native pointer (or null).
    if (type.nextOf.toBasetype.ty == TY.Tchar) {
        const text = stableString
            ? stableNativeString(value)
            : nativeString(value);
        keepAlive ~= text;
        return cast(void*) text;
    }

    return value.asNativePointer;
}

private void marshalSliceArgument(
    ubyte[] buffer,
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.lang".Value value,
    ref ubyte[][] keepAliveBuffers,
) {
    import dmd.typesem: size;

    auto elementType = type.nextOf.toBasetype;  // mutable for size()
    const elementSize = cast(size_t) size(elementType);
    auto bytes = new ubyte[](value.length * elementSize);
    const(char)*[] keepAlive;
    foreach (index; 0 .. value.length) {
        marshalArgument(
            bytes[index * elementSize .. (index + 1) * elementSize],
            elementType,
            value[index],
            false,
            keepAlive,
            keepAliveBuffers,
        );
    }

    keepAliveBuffers ~= bytes;
    *cast(size_t*) buffer.ptr = value.length;
    *cast(void**) (buffer.ptr + size_t.sizeof) = bytes.ptr;
}

// Marshal a raw ABI return buffer back into a backend value.
private imported!"quickbite.lang".Value unmarshalValue(
    imported!"dmd.mtype".Type type,
    in ubyte[] buffer,
) {
    import quickbite.lang: Value;
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct;

    switch (type.ty) {
        case TY.Tvoid:     return Value.void_;
        case TY.Tbool:     return Value(*cast(const bool*) buffer.ptr);
        case TY.Tchar:     return Value(*cast(const char*) buffer.ptr);
        case TY.Twchar:    return Value(*cast(const wchar*) buffer.ptr);
        case TY.Tdchar:    return Value(*cast(const dchar*) buffer.ptr);
        case TY.Tint8:     return Value(*cast(const byte*) buffer.ptr);
        case TY.Tuns8:     return Value(*cast(const ubyte*) buffer.ptr);
        case TY.Tint16:    return Value(*cast(const short*) buffer.ptr);
        case TY.Tuns16:    return Value(*cast(const ushort*) buffer.ptr);
        case TY.Tint32:    return Value(*cast(const int*) buffer.ptr);
        case TY.Tuns32:    return Value(*cast(const uint*) buffer.ptr);
        case TY.Tint64:    return Value(*cast(const long*) buffer.ptr);
        case TY.Tuns64:    return Value(*cast(const ulong*) buffer.ptr);
        case TY.Tfloat32:  return Value(*cast(const float*) buffer.ptr);
        case TY.Tfloat64:  return Value(*cast(const double*) buffer.ptr);
        case TY.Tfloat80:  return Value(*cast(const real*) buffer.ptr);
        case TY.Tpointer:
            return Value.nativePointerValue(*cast(void**) buffer.ptr);
        case TY.Tarray:
            return unmarshalSlice(type, buffer);
        case TY.Tstruct:
            return unmarshalStruct(cast(TypeStruct) type, buffer);
        default:
            assert(false, "unmarshalled libffi return type");
    }
}

private imported!"quickbite.lang".Value unmarshalSlice(
    imported!"dmd.mtype".Type type,
    in ubyte[] buffer,
) {
    import quickbite.lang: Value;
    import dmd.astenums: TY;
    import dmd.typesem: size;

    assert(isSupportedScalarSlice(type));

    const length = *cast(const size_t*) buffer.ptr;
    const data = *cast(const void**) (buffer.ptr + size_t.sizeof);
    if (length == 0)
        return emptySliceValue(type);
    if (data is null)
        throw new Exception("Native slice return has null data.");

    auto elementType = type.nextOf.toBasetype;  // mutable for size()
    const elementSize = cast(size_t) size(elementType);
    const bytes = (cast(const(ubyte)*) data)[0 .. length * elementSize];
    switch (elementType.ty) with (TY) {
        case Tchar:
            const chars = cast(const(char)*) data;
            return Value(chars[0 .. length].idup);

        case Twchar:
            const chars = cast(const(wchar)*) data;
            return Value.stringValue(chars[0 .. length].dup);

        case Tdchar:
            const chars = cast(const(dchar)*) data;
            return Value.stringValue(chars[0 .. length].dup);

        default:
            Value[] elements;
            foreach (index; 0 .. length) {
                elements ~= unmarshalValue(
                    elementType,
                    bytes[index * elementSize .. (index + 1) * elementSize],
                );
            }
            return Value.arrayValue(elements);
    }
}

private imported!"quickbite.lang".Value emptySliceValue(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.lang: Value;
    import dmd.astenums: TY;

    switch (type.nextOf.toBasetype.ty) with (TY) {
        case Tchar:
            return Value("");
        case Twchar:
            wchar[] empty;
            return Value.stringValue(empty);
        case Tdchar:
            dchar[] empty;
            return Value.stringValue(empty);
        default:
            return Value.arrayValue([]);
    }
}

private imported!"quickbite.lang".Value unmarshalStruct(
    imported!"dmd.mtype".TypeStruct type,
    in ubyte[] buffer,
) {
    import quickbite.lang: Value;
    import dmd.typesem: size;
    import std.string: fromStringz;

    auto sym = type.sym;
    Value[] fields;
    foreach (index; 0 .. sym.fields.length) {
        auto field = sym.fields[index];
        auto fieldType = field.type.toBasetype;  // mutable for size()
        const fieldSize = cast(size_t) size(fieldType);
        fields ~= unmarshalValue(
            fieldType,
            buffer[field.offset .. field.offset + fieldSize],
        );
    }

    return Value.structValue(fromStringz(sym.toChars).idup, fields);
}

// Marshal a backend value into a NUL-terminated C string valid for the
// duration of the native call. A native pointer is passed straight through;
// a backend char array is copied into a GC-owned NUL-terminated buffer.
private const(char)* nativeString(in imported!"quickbite.lang".Value value) {
    import std.string: toStringz;

    if (value.isNativePointer)
        return cast(const(char)*) value.asNativePointer;

    return value.asCharArrayString.toStringz;
}

// Like nativeString, but backs the C string with a stable C-heap buffer that
// outlives the call. strtol's `endptr` points into this buffer, so a GC-owned
// copy could be collected before the backend reads through it. The buffer is
// intentionally leaked: native allocations are reclaimed at process exit
// (ffi.md §5).
private const(char)* stableNativeString(
    in imported!"quickbite.lang".Value value,
) {
    import core.stdc.stdlib: malloc;
    import core.stdc.string: memcpy;

    if (value.isNativePointer)
        return cast(const(char)*) value.asNativePointer;

    const chars = value.asCharArrayString;
    auto buffer = cast(char*) malloc(chars.length + 1);
    memcpy(buffer, chars.ptr, chars.length);
    buffer[chars.length] = '\0';
    return buffer;
}

private imported!"dmd.mtype".Type parameterType(
    imported!"dmd.mtype".TypeFunction functionType,
    in size_t index,
) {
    return (*functionType.parameterList.parameters)[index].type.toBasetype;
}

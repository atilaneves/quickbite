module quickbite.backends.interpreter.ffi_marshal;

// The interpreter's materialize/reify (ffi.md §5): the boxed Value <-> ABI byte
// conversion the FFI core injects through NativeMarshaller. Track B owns this
// file and may replace the boxed conversion below with native-layout
// marshalling; Track A only wires it to the core.

private:

import quickbite.ffi: NativeMarshaller;

// Re-exported so the interpreter call sites keep a single import for the native
// call path and its exception type.
public import quickbite.ffi.core: NativeCallException;

public bool tryCallNative(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.lang".Value[] arguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    import quickbite.ffi: callNative;

    auto marshaller = new InterpreterNativeMarshaller(arguments);
    if (!callNative(function_, marshaller, arguments.length))
        return false;

    result = marshaller.result;
    argumentWritebacks = marshaller.writebacks;
    return true;
}

public bool tryCallNativeMember(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.mtype".TypeStruct receiverType,
    in imported!"quickbite.lang".Value receiver,
    in imported!"quickbite.lang".Value[] arguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    import quickbite.ffi: callNativeMember;

    if (receiverType is null || !receiver.isStruct)
        return false;

    auto marshaller = new InterpreterNativeMarshaller(arguments, receiver);
    if (!callNativeMember(function_, receiverType, marshaller, arguments.length))
        return false;

    result = marshaller.result;
    argumentWritebacks = marshaller.writebacks;
    return true;
}

private final class InterpreterNativeMarshaller: NativeMarshaller {
    import quickbite.lang: Value;
    import dmd.mtype: Type;

    private const(Value)[] _arguments;
    private Value _receiver;
    private Value _result;
    private Value[] _writebacks;

    public this(in Value[] arguments) {
        _arguments = arguments;
    }

    public this(in Value[] arguments, in Value receiver) {
        _arguments = arguments;
        _receiver = receiver;
    }

    public Value result() const {
        return _result;
    }

    public Value[] writebacks() {
        return _writebacks;
    }

    public override void fillArgument(
        ubyte[] buffer,
        Type type,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    ) {
        marshalArgument(
            buffer,
            type,
            _arguments[index],
            stableString,
            keepAlive,
            keepAliveBuffers,
        );
    }

    public override void fillReceiver(
        ubyte[] buffer,
        Type type,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    ) {
        marshalArgument(
            buffer,
            type,
            _receiver,
            stableString,
            keepAlive,
            keepAliveBuffers,
        );
    }

    public override void readResult(Type type, in ubyte[] buffer) {
        _result = unmarshalValue(type, buffer);
    }

    public override void writeOutParameter(in size_t index, void* writtenPointer) {
        if (_writebacks.length == 0)
            _writebacks = new Value[](_arguments.length);
        _writebacks[index] = Value.nativePointerValue(writtenPointer);
    }
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
    import quickbite.ffi: isSupportedScalarSlice;
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

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

// Runs an interpreted delegate that native code called back into (ffi.md
// §34.16). The Walker supplies it so the marshaller can re-enter the
// interpreter without this module importing the Walker.
public alias DelegateInvoker = imported!"quickbite.lang".Value delegate(
    in imported!"quickbite.lang".Value callee,
    in imported!"quickbite.lang".Value[] arguments,
);

public bool tryCallNative(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.lang".Value[] arguments,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    in imported!"quickbite.lang".Value[] outParameterInputs,
    DelegateInvoker invokeDelegate,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    import quickbite.ffi: callNative;

    auto marshaller = new InterpreterNativeMarshaller(
        arguments,
        outParameterInputs,
        invokeDelegate,
    );
    if (!callNative(function_, marshaller, argumentTypes, addressOfLocalArguments))
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
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
    out imported!"quickbite.lang".Value receiverWriteback,
) {
    import quickbite.ffi: callNativeMember;

    if (receiverType is null || !receiver.isStruct)
        return false;

    auto marshaller = new InterpreterNativeMarshaller(arguments, receiver);
    if (!callNativeMember(
        function_,
        receiverType,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    ))
        return false;

    result = marshaller.result;
    argumentWritebacks = marshaller.writebacks;
    // A mutating (non-const) member writes `this` back into the caller's
    // receiver (ffi.md §34.9); a const method cannot, so leave it void.
    if (mutatesReceiver(function_))
        receiverWriteback = marshaller.receiverWriteback;
    return true;
}

// Construct a native struct through its body-less extern(D) constructor
// (ffi.md §34.13). The caller supplies the struct's default `.init` as the
// receiver (the object the ctor initialises in place); the constructor runs
// against an allocated `this` and the *constructed* struct is reified from that
// receiver buffer. A struct ctor returns `ref this`, so its return value is the
// receiver, not a separate result — `result` is the reified receiver, not the
// (ignored) ABI return.
public bool tryCallNativeConstructor(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.mtype".TypeStruct receiverType,
    in imported!"quickbite.lang".Value receiver,
    in imported!"quickbite.lang".Value[] arguments,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    import quickbite.ffi: callNativeMember;

    if (receiverType is null || !receiver.isStruct)
        return false;

    auto marshaller = new InterpreterNativeMarshaller(arguments, receiver);
    if (!callNativeMember(
        function_,
        receiverType,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    ))
        return false;

    result = marshaller.receiverWriteback;
    argumentWritebacks = marshaller.writebacks;
    return true;
}

// Call a native delegate the backend holds as an opaque {context, funcptr}
// value reified from a native return (ffi.md §35.8). The core leads with the
// context pointer and reverses the extern(D) explicit arguments — the inverse
// of the §34.16 closure bridge.
public bool tryCallNativeDelegate(
    imported!"dmd.mtype".TypeFunction functionType,
    in imported!"quickbite.lang".Value delegate_,
    in imported!"quickbite.lang".Value[] arguments,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    in imported!"quickbite.lang".Value[] outParameterInputs,
    DelegateInvoker invokeDelegate,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    import quickbite.ffi: callNativeDelegate;

    if (!delegate_.isNativeDelegate)
        return false;

    auto marshaller = new InterpreterNativeMarshaller(
        arguments,
        outParameterInputs,
        invokeDelegate,
    );
    if (!callNativeDelegate(
        functionType,
        delegate_.nativeDelegateFuncptr,
        delegate_.nativeDelegateContext,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    ))
        return false;

    result = marshaller.result;
    argumentWritebacks = marshaller.writebacks;
    return true;
}

// A member call on a native class reference (ffi.md §34.12). The receiver is an
// opaque native handle (NativePointer); virtual dispatch happens in the core via
// the object's vtable. The object is mutated in place through the shared pointer,
// so there is no receiver writeback.
public bool tryCallNativeClassMember(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.mtype".TypeClass receiverType,
    in imported!"quickbite.lang".Value receiver,
    in imported!"quickbite.lang".Value[] arguments,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
) {
    import quickbite.ffi: callNativeClassMember;

    if (receiverType is null || !receiver.isNativePointer)
        return false;

    auto marshaller = new InterpreterNativeMarshaller(arguments, receiver);
    if (!callNativeClassMember(
        function_,
        receiverType,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    ))
        return false;

    result = marshaller.result;
    argumentWritebacks = marshaller.writebacks;
    return true;
}

private bool mutatesReceiver(
    imported!"dmd.func".FuncDeclaration function_,
) @safe {
    import dmd.mtype: TypeFunction;

    auto type = cast(TypeFunction) function_.type;
    return type !is null && type.isMutable;
}

private final class InterpreterNativeMarshaller: NativeMarshaller {
    import quickbite.lang: Value;
    import dmd.mtype: Type;

    private const(Value)[] _arguments;
    // The current value behind each `&local` argument (Value.void_ elsewhere),
    // marshalled into the out-parameter cell before the call so in-out callees
    // read the caller's value rather than zeroes (ffi.md §35.6).
    private const(Value)[] _outParameterInputs;
    private Value _receiver;
    private Value _result;
    private Value[] _writebacks;
    // The receiver's ABI buffer, retained so the (possibly mutated) bytes can
    // be reified back into a Value after the call (ffi.md §34.9). The buffer is
    // GC-allocated by the core; holding it here keeps it alive past the call.
    private ubyte[] _receiverBuffer;
    private Type _receiverType;
    // Element buffers for mutable slice arguments, retained so native writes
    // through them are reified back into the caller's array after the call
    // (ffi.md §34.10). The core GC-pins each buffer across the call (§13).
    private static struct SliceWriteback {
        size_t index;
        Type arrayType;
        ubyte[] bytes;
        size_t length;
    }
    private SliceWriteback[] _sliceWritebacks;
    // Runs an interpreted delegate passed into native code, supplied by the
    // Walker so the reverse bridge (ffi.md §34.16) can re-enter the interpreter.
    private DelegateInvoker _invokeDelegate;

    public this(
        in Value[] arguments,
        in Value[] outParameterInputs,
        DelegateInvoker invokeDelegate = null,
    ) {
        _arguments = arguments;
        _outParameterInputs = outParameterInputs;
        _invokeDelegate = invokeDelegate;
    }

    public this(in Value[] arguments, in Value receiver) {
        _arguments = arguments;
        _receiver = receiver;
    }

    public Value result() const {
        return _result;
    }

    public Value[] writebacks() {
        foreach (slice; _sliceWritebacks) {
            ensureWritebacks;
            _writebacks[slice.index] =
                reifySliceWriteback(slice.arrayType, slice.bytes, slice.length);
        }
        return _writebacks;
    }

    public Value receiverWriteback() {
        return unmarshalValue(_receiverType, _receiverBuffer);
    }

    public override bool canRepresent(Type type, in Direction direction) {
        final switch (direction) with (Direction) {
            case toNative:   return canMarshalToNative(type);
            case fromNative: return canReifyFromNative(type);
        }
    }

    public override void fillArgument(
        ubyte[] buffer,
        Type type,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    ) {
        // A mutable scalar slice is marshalled through its own element buffer
        // and tracked for writeback; everything else (and immutable/nested
        // slices) marshals copy-only (ffi.md §34.10).
        if (isMutableScalarSlice(type)) {
            auto bytes = marshalSliceArgument(
                buffer,
                type,
                _arguments[index],
                keepAliveBuffers,
            );
            _sliceWritebacks ~= SliceWriteback(
                index,
                type,
                bytes,
                _arguments[index].length,
            );
            return;
        }

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
        _receiverBuffer = buffer;
        _receiverType = type;
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

    public override const(void)* receiverObjectPointer() {
        // The class receiver is held as an opaque native handle; its object
        // pointer is passed as hidden `this` and read for vtable dispatch.
        return cast(const(void)*) _receiver.asNativePointer;
    }

    public override void invokeClosure(
        in size_t argumentIndex,
        Type returnType,
        Type[] parameterTypes,
        void*[] argumentBuffers,
        ubyte[] resultBuffer,
    ) {
        import dmd.astenums: TY;
        import dmd.typesem: size;

        assert(_invokeDelegate !is null, "native callback with no delegate invoker");

        // Materialize the native callback arguments into backend values, run the
        // interpreted closure, and marshal its result into the libffi return
        // buffer (ffi.md §34.16).
        Value[] callbackArguments;
        foreach (index, parameterType; parameterTypes) {
            const argumentSize = cast(size_t) size(parameterType);
            callbackArguments ~= unmarshalValue(
                parameterType,
                (cast(const(ubyte)*) argumentBuffers[index])[0 .. argumentSize],
            );
        }

        const callbackResult =
            _invokeDelegate(_arguments[argumentIndex], callbackArguments);

        if (returnType.ty == TY.Tvoid)
            return;

        const(char)*[] keepAlive;
        ubyte[][] keepAliveBuffers;
        marshalArgument(
            resultBuffer,
            returnType,
            callbackResult,
            false,
            keepAlive,
            keepAliveBuffers,
        );
    }

    public override void writeOutParameter(
        in size_t index,
        Type pointedToType,
        in ubyte[] cell,
    ) {
        // Reify the written cell through the pointed-to type: a `char**` out
        // slot yields a native pointer, a scalar out slot (`int*`) yields the
        // scalar value (ffi.md §34.8).
        ensureWritebacks;
        _writebacks[index] = unmarshalValue(pointedToType, cell);
    }

    public override void fillOutParameterCell(
        ubyte[] cell,
        Type pointedToType,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    ) {
        // No input value threaded for this slot (the argument is not `&local`,
        // or the call path does not supply inputs): the cell stays zeroed.
        if (index >= _outParameterInputs.length ||
            _outParameterInputs[index] == Value.void_)
            return;

        marshalArgument(
            cell,
            pointedToType,
            _outParameterInputs[index],
            stableString,
            keepAlive,
            keepAliveBuffers,
        );
    }

    private void ensureWritebacks() {
        if (_writebacks.length == 0)
            _writebacks = new Value[](_arguments.length);
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

        case TY.Tclass:
            // A class reference is an opaque native handle (ffi.md §34.12),
            // passed through as the object pointer.
            *cast(void**) buffer.ptr = value.asNativePointer;
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

private ubyte[] marshalSliceArgument(
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
    return bytes;
}

// A scalar slice whose element type is mutable: native code may write through
// it, so it needs the §34.10 writeback path rather than a copy.
private bool isMutableScalarSlice(imported!"dmd.mtype".Type type) {
    import quickbite.ffi: isSupportedScalarSlice;
    import dmd.astenums: TY;

    return type.ty == TY.Tarray &&
        isSupportedScalarSlice(type) &&
        type.nextOf.isMutable;
}

// Reify a mutable slice's (possibly native-mutated) element buffer back into a
// backend array Value by reusing the {length, ptr} return reification.
private imported!"quickbite.lang".Value reifySliceWriteback(
    imported!"dmd.mtype".Type arrayType,
    ubyte[] bytes,
    in size_t length,
) {
    auto descriptor = new ubyte[](size_t.sizeof + (void*).sizeof);
    *cast(size_t*) descriptor.ptr = length;
    *cast(void**) (descriptor.ptr + size_t.sizeof) = bytes.ptr;
    return unmarshalValue(arrayType, descriptor);
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
        case TY.Tclass:
            // A returned class reference reifies as an opaque native handle
            // (ffi.md §34.12); the object pointer is the return value itself.
            return Value.nativePointerValue(*cast(void**) buffer.ptr);
        case TY.Tarray:
            return unmarshalSlice(type, buffer);
        case TY.Tstruct:
            return unmarshalStruct(cast(TypeStruct) type, buffer);
        case TY.Tdelegate:
            // A returned native delegate reifies as an opaque callable
            // {context, funcptr} pair (ffi.md §35.8); calling it goes back
            // through the bridge (tryCallNativeDelegate).
            return Value.nativeDelegateValue(
                *cast(const(void)**) buffer.ptr,
                *cast(const(void)**) (buffer.ptr + (void*).sizeof),
            );
        default:
            assert(false, "unmarshalled libffi return type");
    }
}

// Mirrors marshalArgument's switch (ffi.md §35.8): the types whose boxed
// Value the interpreter can marshal into native ABI bytes.
private bool canMarshalToNative(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct;

    switch (type.ty) with (TY) {
        case Tbool, Tchar, Twchar, Tdchar,
             Tint8, Tuns8, Tint16, Tuns16,
             Tint32, Tuns32, Tint64, Tuns64,
             Tfloat32, Tfloat64, Tfloat80,
             Tpointer, Tclass:
            return true;

        case Tarray:
            return canMarshalToNative(type.nextOf.toBasetype);

        case Tstruct:
            auto sym = (cast(TypeStruct) type).sym;
            // A boxed union holds every member as its own value and cannot
            // reproduce the members' overlapped bytes (ffi.md §35.7).
            if (sym.isUnionDeclaration !is null)
                return false;
            foreach (field; sym.fields)
                if (!canMarshalToNative(field.type.toBasetype))
                    return false;
            return true;

        default:
            return false;
    }
}

// Mirrors unmarshalValue's switch (ffi.md §35.8): the types whose native ABI
// bytes the interpreter can reify into a boxed Value.
private bool canReifyFromNative(imported!"dmd.mtype".Type type) {
    import quickbite.ffi: isSupportedScalarSlice;
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct;

    switch (type.ty) with (TY) {
        case Tvoid,
             Tbool, Tchar, Twchar, Tdchar,
             Tint8, Tuns8, Tint16, Tuns16,
             Tint32, Tuns32, Tint64, Tuns64,
             Tfloat32, Tfloat64, Tfloat80,
             Tpointer, Tclass, Tdelegate:
            return true;

        case Tarray:
            return isSupportedScalarSlice(type);

        case Tstruct:
            // Unions reify field-by-field from the same overlapped bytes — a
            // bit-faithful snapshot — so they need no special case here.
            auto sym = (cast(TypeStruct) type).sym;
            foreach (field; sym.fields)
                if (!canReifyFromNative(field.type.toBasetype))
                    return false;
            return true;

        default:
            return false;
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
    import quickbite.lang: Value;
    import std.string: toStringz;

    if (value == Value.null_)
        return null;

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
    import quickbite.lang: Value;
    import core.stdc.stdlib: malloc;
    import core.stdc.string: memcpy;

    if (value == Value.null_)
        return null;

    if (value.isNativePointer)
        return cast(const(char)*) value.asNativePointer;

    const chars = value.asCharArrayString;
    auto buffer = cast(char*) malloc(chars.length + 1);
    memcpy(buffer, chars.ptr, chars.length);
    buffer[chars.length] = '\0';
    return buffer;
}

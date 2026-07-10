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

// Session-owned callback roots and callback-id invoker for durable FFI
// trampolines. The core registry owns libffi closure memory; this table owns
// interpreter Values and remains valid for the Walker session (§35.4).
public struct InterpreterInboundTrampolineSession {
    import quickbite.lang: Value;
    import quickbite.ffi: InboundTrampolineRegistry;

    private Value[] _callbacks;
    private DelegateInvoker _invokeDelegate;
    private InboundTrampolineRegistry* _registry;

    public this(DelegateInvoker invokeDelegate) {
        _invokeDelegate = invokeDelegate;
        _registry = new InboundTrampolineRegistry(&invoke);
    }

    public InboundTrampolineRegistry* registry() {
        return _registry;
    }

    public size_t register(in Value callback) {
        _callbacks ~= callback;
        return _callbacks.length - 1;
    }

    // Durable callbacks are valid only while their owning Walker can service
    // re-entry. Release the executable libffi closures and callback roots as
    // that session ends (§35.4).
    public void close() {
        if (_registry !is null)
            _registry.close;
        _registry = null;
        _callbacks = null;
        _invokeDelegate = null;
    }

    private void invoke(
        in size_t callbackId,
        imported!"dmd.mtype".Type returnType,
        imported!"dmd.mtype".Type[] parameterTypes,
        void*[] argumentBuffers,
        ubyte[] resultBuffer,
    ) {
        import dmd.astenums: TY;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.layout: typeByteSize;

        assert(callbackId < _callbacks.length, "unknown durable callback id");
        Value[] callbackArguments;
        foreach (index, parameterType; parameterTypes) {
            const argumentSize = typeByteSize(parameterType);
            callbackArguments ~= unmarshalValue(
                parameterType,
                (cast(const(ubyte)*) argumentBuffers[index])[0 .. argumentSize],
            );
        }
        const callbackResult = _invokeDelegate(
            _callbacks[callbackId], callbackArguments,
        );
        if (returnType.ty == TY.Tvoid)
            return;

        const(char)*[] keepAlive;
        ubyte[][] keepAliveBuffers;
        marshalArgument(resultBuffer, returnType, callbackResult, false,
            keepAlive, keepAliveBuffers);
    }
}

// A native write through a pointer into interpreter-managed array memory
// (e.g. posix read filling `buf.ptr + offset`): the pointed-at elements as
// they stand after the call, for the walker to write back through the
// pointer value.
public struct PointerElementsWriteback {
    public imported!"quickbite.lang".Value pointer;
    public imported!"quickbite.lang".Value[] elements;
}

public bool tryCallNative(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.lang".Value[] arguments,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    in imported!"quickbite.lang".Value[] outParameterInputs,
    DelegateInvoker invokeDelegate,
    InterpreterInboundTrampolineSession* durableSession,
    out imported!"quickbite.lang".Value result,
    out imported!"quickbite.lang".Value[] argumentWritebacks,
    out PointerElementsWriteback[] pointerWritebacks,
) {
    import quickbite.ffi: callNative;

    auto marshaller = new InterpreterNativeMarshaller(
        arguments,
        outParameterInputs,
        invokeDelegate, durableSession,
    );
    if (!callNative(function_, marshaller, argumentTypes, addressOfLocalArguments,
        durableSession is null ? null : durableSession.registry))
        return false;

    result = marshaller.result;
    argumentWritebacks = marshaller.writebacks;
    pointerWritebacks = marshaller.pointerWritebacks;
    return true;
}

public bool tryAssignNativeRefReturn(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.lang".Value[] arguments,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    in imported!"quickbite.lang".Value value,
) {
    import quickbite.ffi: assignNativeRefReturn;

    auto marshaller = new InterpreterNativeMarshaller(arguments, value);
    return assignNativeRefReturn(
        function_,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    );
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
    private Value _refResultValue;
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
    // Native buffers marshalled for pointer-into-array arguments, retained so
    // native writes through them (e.g. posix read filling a buffer) are
    // reified back through the pointer value after the call.
    private static struct PointerBufferWriteback {
        Type elementType;
        Value pointer;
        ubyte[] bytes;
    }
    private PointerBufferWriteback[] _pointerWritebacks;
    // Runs an interpreted delegate passed into native code, supplied by the
    // Walker so the reverse bridge (ffi.md §34.16) can re-enter the interpreter.
    private DelegateInvoker _invokeDelegate;
    private InterpreterInboundTrampolineSession* _durableSession;

    public this(
        in Value[] arguments,
        in Value[] outParameterInputs,
        DelegateInvoker invokeDelegate = null,
        InterpreterInboundTrampolineSession* durableSession = null,
    ) {
        _arguments = arguments;
        _outParameterInputs = outParameterInputs;
        _invokeDelegate = invokeDelegate;
        _durableSession = durableSession;
    }

    public this(in Value[] arguments, in Value receiver) {
        _arguments = arguments;
        _receiver = receiver;
        _refResultValue = receiver;
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

    public override bool canRepresentOutCell(Type pointedToType) {
        // An out cell is filled from and reified back into raw native bytes,
        // never boxed as a by-value union (ffi.md §35.10). A union whose
        // members are all fixed-size scalars (or scalar static arrays) has its
        // overlapped bytes round-trip verbatim through marshalArgument's
        // declaration-order field walk and unmarshalStruct's field-by-field
        // snapshot, so accept it here even though canMarshalToNative refuses a
        // by-value union — an interpreter-boxed union cannot reproduce
        // overlapped bytes from per-member values (ffi.md §35.7), but the out
        // cell never marshals from one. Everything else keeps the strict
        // both-directions check.
        if (isOpaqueUnionOutCell(pointedToType))
            return true;
        return canMarshalToNative(pointedToType) &&
            canReifyFromNative(pointedToType);
    }

    public PointerElementsWriteback[] pointerWritebacks() {
        import quickbite.backends.interpreter.layout: typeByteSize;

        PointerElementsWriteback[] result;
        foreach (writeback; _pointerWritebacks) {
            const elementSize = typeByteSize(writeback.elementType);
            Value[] elements;
            foreach (index; 0 .. writeback.bytes.length / elementSize)
                elements ~= unmarshalValue(
                    writeback.elementType,
                    writeback.bytes[index * elementSize .. (index + 1) * elementSize],
                );
            result ~= PointerElementsWriteback(writeback.pointer, elements);
        }
        return result;
    }

    public override void fillArgument(
        ubyte[] buffer,
        Type type,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    ) {
        import dmd.astenums: TY;

        // A non-char pointer into interpreter-managed array memory (e.g.
        // posix read's `void*` receiving `buf.ptr + n`): marshal the
        // pointed-at elements into a native buffer and track it, so bytes the
        // callee writes reify back through the pointer value after the call.
        if (
            type.ty == TY.Tpointer &&
            type.nextOf.toBasetype.ty != TY.Tchar &&
            _arguments[index].isPointer &&
            !_arguments[index].isNativePointer &&
            !_arguments[index].isLocalPointer
        ) {
            auto elementType = pointerElementType(type);
            auto bytes = marshalPointerElements(
                elementType,
                _arguments[index],
            );
            keepAliveBuffers ~= bytes;
            fillPointerCell(buffer, bytes);
            _pointerWritebacks ~= PointerBufferWriteback(
                elementType,
                _arguments[index],
                bytes,
            );
            return;
        }

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

    public override const(void)* argumentAddress(in size_t index, Type type) {
        return null;
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

    public override void* resultAddress(Type type) {
        return null;
    }

    public override void writeRefResult(
        Type type,
        void* address,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        marshalArgument(
            mutableNativeBytes(address, typeByteSize(type)),
            type,
            _refResultValue,
            stableString,
            keepAlive,
            keepAliveBuffers,
        );
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
        import quickbite.backends.interpreter.layout: typeByteSize;

        assert(_invokeDelegate !is null, "native callback with no delegate invoker");

        // Materialize the native callback arguments into backend values, run the
        // interpreted closure, and marshal its result into the libffi return
        // buffer (ffi.md §34.16).
        Value[] callbackArguments;
        foreach (index, parameterType; parameterTypes) {
            const argumentSize = typeByteSize(parameterType);
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

    public override size_t durableInboundCallbackId(in size_t argumentIndex) {
        assert(_durableSession !is null, "durable callback without session");
        return _durableSession.register(_arguments[argumentIndex]);
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

    switch (type.ty) {
        // native_scalar.writeScalar is `layout.d`'s single scalar<->bytes
        // authority (`ai/plans/value.md` item 7); it needs `dest.length ==
        // layout.typeByteSize(type)` exactly. That holds for every argument,
        // receiver, ref-result, and struct/array-field buffer this function
        // fills. It does NOT hold for a native closure/callback result
        // buffer (`invokeClosure`/`InterpreterInboundTrampolineSession.
        // invoke`, ffi.md §34.16): libffi widens a narrow scalar return
        // buffer to its `ffi_arg` width (>= 8 bytes) and requires the WHOLE
        // widened buffer to carry a sign/zero-extended copy of the value
        // for ABI correctness, which a fixed-width `writeScalar` cannot
        // produce. Route the common exact-size case through the shared
        // codec and keep the old byte splat for the widened one.
        case TY.Tbool, TY.Tchar, TY.Twchar, TY.Tdchar,
             TY.Tint8, TY.Tuns8, TY.Tint16, TY.Tuns16,
             TY.Tint32, TY.Tuns32, TY.Tint64, TY.Tuns64: {
            import quickbite.backends.interpreter.layout: typeByteSize;
            import quickbite.backends.interpreter.native_scalar: writeScalar;

            if (buffer.length == typeByteSize(type)) {
                writeScalar(type, buffer, value);
                return;
            }

            const scalar = scalarBits(type, value);
            foreach (index; 0 .. buffer.length)
                buffer[index] = cast(ubyte) (scalar >> (8 * index));
            return;
        }

        case TY.Tfloat32, TY.Tfloat64: {
            // Unlike the integral case above, the old code here already
            // writes only `typeByteSize(type)` bytes at `buffer.ptr`
            // regardless of `buffer.length` (a widened closure-result
            // buffer's extra bytes were already left untouched), so
            // slicing down to feed `writeScalar` reproduces it exactly.
            import quickbite.backends.interpreter.layout: typeByteSize;
            import quickbite.backends.interpreter.native_scalar: writeScalar;

            writeScalar(type, buffer[0 .. typeByteSize(type)], value);
            return;
        }

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

        case TY.Tstruct: {
            // Routed through the item 7 container handle rather than a
            // hand-rolled `sym.fields[i].offset`/`size(fieldType)` walk
            // (ai/plans/value.md item 7's guardrail). `field(index)` is a
            // writable sub-slice of `buffer` (the block borrows the
            // caller's own mutable buffer), and `fieldDeclaration(index).
            // type` is the DECLARED field type -- `.toBasetype` below
            // reproduces the exact same recursive dispatch the old code's
            // `field.type.toBasetype` performed.
            import quickbite.backends.interpreter.native_struct: NativeStruct;

            auto ns = NativeStruct.borrow(cast(TypeStruct) type, buffer.ptr);
            foreach (index; 0 .. ns.fieldCount)
                marshalArgument(
                    ns.field(index),
                    ns.fieldDeclaration(index).type.toBasetype,
                    value.structFieldAt(index),
                    stableString,
                    keepAlive,
                    keepAliveBuffers,
                );
            return;
        }

        case TY.Tsarray: {
            // Same consolidation as the Tstruct arm above, for a static
            // array's inline elements.
            import dmd.mtype: TypeSArray;
            import quickbite.backends.interpreter.native_array: NativeArray;

            auto staticArray = cast(TypeSArray) type;
            auto elementType = staticArray.next.toBasetype;
            const length = cast(size_t) staticArray.dim.toInteger;
            auto na = NativeArray.borrow(elementType, buffer.ptr, length);
            foreach (index; 0 .. length)
                marshalArgument(
                    na.element(index),
                    elementType,
                    value[index],
                    stableString,
                    keepAlive,
                    keepAliveBuffers,
                );
            return;
        }

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
            // A char value behind a type-erased pointer (fwrite's `void*`
            // receiving string bytes) reinterprets to its integer bits.
            return value.isCharacter ? value.castTo!long.asLong : value.asLong;
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

    if (value.isPointer && !value.isNativePointer && !value.isLocalPointer)
        return pointedAtByteBuffer(value);

    return value.asNativePointer;
}

// The element type behind a pointer parameter; a type-erased `void*` reads
// and writes bytes.
private imported!"dmd.mtype".Type pointerElementType(
    imported!"dmd.mtype".Type pointerType,
) {
    import dmd.astenums: TY;
    import dmd.mtype: Type;

    auto elementType = pointerType.nextOf.toBasetype;
    return elementType.ty == TY.Tvoid ? Type.tuns8 : elementType;
}

// Marshal the elements a backend array pointer points at (from its offset to
// the end of the allocation) into a GC buffer for a native call. Elements
// still `= void` (an uninitialized read buffer) marshal as zero bytes.
private ubyte[] marshalPointerElements(
    imported!"dmd.mtype".Type elementType,
    in imported!"quickbite.lang".Value pointer,
) {
    import quickbite.lang: Value;
    import quickbite.backends.interpreter.layout: typeByteSize;

    const elementSize = typeByteSize(elementType);
    const offset = cast(size_t) pointer.pointerElementOffset;
    const length = pointer.pointerLength - offset;
    auto bytes = new ubyte[](length * elementSize);

    const(char)*[] keepAlive;
    ubyte[][] keepAliveBuffers;
    foreach (index; 0 .. length) {
        const element = pointer.pointerIndex(index);
        if (element == Value.void_)
            continue;
        marshalArgument(
            bytes[index * elementSize .. (index + 1) * elementSize],
            elementType,
            element,
            true,
            keepAlive,
            keepAliveBuffers,
        );
    }

    return bytes;
}

// Writing the buffer's address into the pointer-sized argument cell is the
// same reinterpretation every other marshalling site performs.
private void fillPointerCell(ubyte[] cell, in ubyte[] bytes) @trusted {
    *cast(const(void)**) cell.ptr = bytes.ptr;
}

// A pointer into interpreter-managed array memory passed as a raw pointer
// (e.g. fwrite's `const void*` receiving a string's `.ptr`): copy the
// pointed-at bytes into a C-heap buffer that outlives the call (leaked;
// native allocations are reclaimed at process exit, ffi.md §5). Only
// byte-wide elements have an unambiguous memory image through a type-erased
// pointer, so anything wider is refused rather than silently truncated.
private void* pointedAtByteBuffer(in imported!"quickbite.lang".Value value) {
    const offset = cast(size_t) value.pointerElementOffset;
    const length = value.pointerLength - offset;
    auto buffer = byteBuffer(length == 0 ? 1 : length);
    foreach (index; 0 .. length) {
        const element = value.pointerIndex(index);
        const bits = element.isChar ? element.asChar : element.asLong;
        if (bits < 0 || bits > ubyte.max)
            throw new Exception(
                "Unsupported non-byte element behind a type-erased native pointer argument.",
            );
        buffer[index] = cast(ubyte) bits;
    }
    return buffer.ptr;
}

// The buffer deliberately leaks (see pointedAtByteBuffer); bounds are the
// allocation's own size.
private ubyte[] byteBuffer(in size_t length) @trusted {
    import core.stdc.stdlib: malloc;

    return (cast(ubyte*) malloc(length))[0 .. length];
}

private ubyte[] marshalSliceArgument(
    ubyte[] buffer,
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.lang".Value value,
    ref ubyte[][] keepAliveBuffers,
) {
    // Routed through the item 7 container handle rather than a hand-rolled
    // `new ubyte[](length * elementSize)` + `index * elementSize` walk
    // (ai/plans/value.md item 7's guardrail). `elementType` is resolved to
    // its basetype up front, exactly as the old code did, and reused both
    // to build the handle and to dispatch the recursive marshal.
    import quickbite.backends.interpreter.native_array: NativeArray;

    auto elementType = type.nextOf.toBasetype;
    auto na = NativeArray.allocate(elementType, value.length);
    const(char)*[] keepAlive;
    foreach (index; 0 .. value.length) {
        marshalArgument(
            na.element(index),
            elementType,
            value[index],
            false,
            keepAlive,
            keepAliveBuffers,
        );
    }

    // `na.block.bytes` is the same kind of GC-owned, zeroed byte range the
    // old `new ubyte[](...)` was (`NativeBlock.allocate` routes through
    // `GC.calloc`, which zeroes exactly as `new ubyte[]` did): kept alive by
    // being appended to `keepAliveBuffers` below and by `_sliceWritebacks`
    // (this module's `fillArgument`), and stable because `NativeBlock`'s GC
    // allocation never moves.
    auto bytes = na.block.bytes;
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
    import quickbite.backends.interpreter.layout: typeByteSize;
    import quickbite.backends.interpreter.native_scalar: readScalar;

    switch (type.ty) {
        case TY.Tvoid:     return Value.void_;

        // A direct (non-ref) native return buffer is at least libffi's
        // `ffi_arg` width (>= 8 bytes, `quickbite.ffi.core`'s
        // `returnSize`), wider than a narrow scalar's own `typeByteSize`;
        // every other buffer this function reads (a struct/array field, a
        // slice element, a callback argument, an out-parameter cell) is
        // already exactly `typeByteSize(type)` long. Slicing to the low
        // `typeByteSize(type)` bytes is a no-op for the exact-size callers
        // and, on this little-endian host, reads the same bytes the old
        // pointer cast read for the widened return buffer too -- reading
        // needs only those bytes, unlike the sign/zero-extended write-side
        // case in `marshalArgument`.
        case TY.Tbool, TY.Tchar, TY.Twchar, TY.Tdchar,
             TY.Tint8, TY.Tuns8, TY.Tint16, TY.Tuns16,
             TY.Tint32, TY.Tuns32, TY.Tint64, TY.Tuns64,
             TY.Tfloat32, TY.Tfloat64:
            return readScalar(type, buffer[0 .. typeByteSize(type)]);

        case TY.Tfloat80:  return Value(*cast(const real*) buffer.ptr);
        case TY.Tpointer:
            return Value.nativePointerValue(*cast(void**) buffer.ptr);
        case TY.Tclass:
            // A returned class reference reifies as an opaque native handle
            // (ffi.md §34.12); the object pointer is the return value itself.
            return Value.nativePointerValue(*cast(void**) buffer.ptr);
        case TY.Tarray:
            return unmarshalSlice(type, buffer);
        case TY.Tsarray:
            return unmarshalStaticArray(type, buffer);
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

// A union out-parameter cell the interpreter can cross as an opaque native
// byte buffer (ffi.md §35.10): a union whose every member is a fixed-size
// scalar or a static array (any nesting) of scalars, so the callee-written
// overlapped bytes fill from and reify back verbatim. Narrower than a general
// union — a pointer, slice, or nested-aggregate member would not round-trip
// byte-for-byte — and distinct from the by-value union refusal in
// canMarshalToNative, which the out cell never triggers because it hands the
// callee a native buffer rather than boxing the union (ffi.md §35.7).
private bool isOpaqueUnionOutCell(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct;

    if (type.ty != TY.Tstruct)
        return false;
    auto sym = (cast(TypeStruct) type).sym;
    if (sym.isUnionDeclaration is null)
        return false;
    foreach (field; sym.fields)
        if (!isFixedSizeScalarField(field.type.toBasetype))
            return false;
    return true;
}

private bool isFixedSizeScalarField(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type.ty == TY.Tsarray)
        return isFixedSizeScalarField(type.nextOf.toBasetype);

    switch (type.ty) with (TY) {
        case Tbool, Tchar, Twchar, Tdchar,
             Tint8, Tuns8, Tint16, Tuns16,
             Tint32, Tuns32, Tint64, Tuns64,
             Tfloat32, Tfloat64, Tfloat80:
            return true;

        default:
            return false;
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

        case Tarray, Tsarray:
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

        case Tarray, Tsarray:
            // A struct-element slice reifies through unmarshalSlice's
            // per-element default loop (ffi.md §34.3.1 item 0); a string slice
            // through its char special-case. Either way the element type
            // decides.
            return canReifyFromNative(type.nextOf.toBasetype);

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

// A static array laid out inline (e.g. a reserved field inside stat_t): one
// element after another, no descriptor.
private imported!"quickbite.lang".Value unmarshalStaticArray(
    imported!"dmd.mtype".Type type,
    in ubyte[] buffer,
) {
    import quickbite.lang: Value;
    import dmd.mtype: TypeSArray;
    import quickbite.backends.interpreter.native_array: NativeArray;

    // Routed through the item 7 container handle rather than a hand-rolled
    // `index * elementSize` walk (ai/plans/value.md item 7's guardrail).
    // `elementType` is resolved to its basetype up front, exactly as the
    // old code did, and reused both to build the handle and to dispatch
    // the recursive unmarshal.
    auto staticArray = cast(TypeSArray) type;
    auto elementType = staticArray.next.toBasetype;
    const length = cast(size_t) staticArray.dim.toInteger;
    auto na = NativeArray.borrow(elementType, cast(void*) buffer.ptr, length);

    Value[] elements;
    foreach (index; 0 .. length)
        elements ~= unmarshalValue(elementType, na.element(index));

    return Value.arrayValue(elements);
}

private imported!"quickbite.lang".Value unmarshalSlice(
    imported!"dmd.mtype".Type type,
    in ubyte[] buffer,
) {
    import quickbite.ffi: isSupportedFfiSlice;
    import quickbite.lang: Value;
    import dmd.astenums: TY;

    assert(isSupportedFfiSlice(type));

    const length = *cast(const size_t*) buffer.ptr;
    const data = *cast(const void**) (buffer.ptr + size_t.sizeof);
    if (length == 0)
        return emptySliceValue(type);
    if (data is null)
        throw new Exception("Native slice return has null data.");

    auto elementType = type.nextOf.toBasetype;
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
            // Routed through the item 7 container handle rather than a
            // hand-rolled `index * elementSize` walk (ai/plans/value.md
            // item 7's guardrail). `data` is native memory this function
            // did not allocate -- exactly `NativeArray.borrow`'s own
            // documented precondition, vouched for here by the native call
            // that filled this return buffer.
            import quickbite.backends.interpreter.native_array: NativeArray;

            auto na = NativeArray.borrow(elementType, cast(void*) data, length);
            Value[] elements;
            foreach (index; 0 .. length)
                elements ~= unmarshalValue(elementType, na.element(index));
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

// Read a value out of native memory (`*pointer`, e.g. a malloc'd struct
// like std.stdio.File's Impl, or a scalar inside one): a snapshot Value
// built from the pointee's bytes.
public imported!"quickbite.lang".Value unmarshalNative(
    imported!"dmd.mtype".Type type,
    in void* address,
) {
    import quickbite.backends.interpreter.layout: typeByteSize;

    return unmarshalValue(type, nativeBytes(address, typeByteSize(type)));
}

// Write a Value into native memory. String and slice fields are backed by
// buffers pinned for the rest of the process: native allocations are
// reclaimed at process exit (ffi.md §5).
public void marshalNative(
    imported!"dmd.mtype".Type type,
    void* address,
    in imported!"quickbite.lang".Value value,
) {
    import quickbite.backends.interpreter.layout: typeByteSize;

    const(char)*[] keepAlive;
    ubyte[][] keepAliveBuffers;
    marshalArgument(
        mutableNativeBytes(address, typeByteSize(type)),
        type,
        value,
        true,
        keepAlive,
        keepAliveBuffers,
    );
    pinnedNativeStrings ~= keepAlive;
    pinnedNativeBuffers ~= keepAliveBuffers;
}

// GC-owned backing memory that native structs now point into; pinned so a
// collection cannot free it while the C heap still references it.
private const(char)*[] pinnedNativeStrings;
private ubyte[][] pinnedNativeBuffers;

// Reading raw process memory the interpreter was handed a pointer to is as
// (un)safe as the compiled D it mirrors; the length comes from the struct
// type's own size.
private const(ubyte)[] nativeBytes(in void* address, in size_t length) @trusted {
    return (cast(const(ubyte)*) address)[0 .. length];
}

// Same justification as nativeBytes, for the write direction.
private ubyte[] mutableNativeBytes(void* address, in size_t length) @trusted {
    return (cast(ubyte*) address)[0 .. length];
}

private imported!"quickbite.lang".Value unmarshalStruct(
    imported!"dmd.mtype".TypeStruct type,
    in ubyte[] buffer,
) {
    import quickbite.lang: Value;
    import quickbite.backends.interpreter.native_struct: NativeStruct;
    import std.string: fromStringz;

    // Routed through the item 7 container handle rather than a hand-rolled
    // `sym.fields[i].offset`/`size(fieldType)` walk (ai/plans/value.md
    // item 7's "must not grow a second set of D layout rules" guardrail).
    // `NativeStruct.fieldDeclaration(index).type` is the DECLARED field
    // type, not the basetype the old code dispatched on -- `.toBasetype`
    // below reproduces the exact same recursive dispatch.
    auto ns = NativeStruct.borrow(type, cast(void*) buffer.ptr);
    Value[] fields;
    foreach (index; 0 .. ns.fieldCount)
        fields ~= unmarshalValue(
            ns.fieldDeclaration(index).type.toBasetype,
            ns.field(index),
        );

    return Value.structValue(fromStringz(type.sym.toChars).idup, fields);
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

    // A pointer into interpreter-managed array memory (e.g. `buffer.ptr` of
    // a struct's static-array field, as Phobos' tempCString returns): the
    // chars up to the NUL the D code wrote, which is all a native callee may
    // read of a C string.
    if (value.isPointer)
        return pointedAtCString(value).toStringz;

    return value.asCharArrayString.toStringz;
}

private string pointedAtCString(in imported!"quickbite.lang".Value value) {
    char[] chars;
    foreach (index; 0 .. value.pointerLength) {
        const character = value.pointerIndex(index).asChar;
        if (character == '\0')
            break;
        chars ~= character;
    }
    return chars.idup;
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

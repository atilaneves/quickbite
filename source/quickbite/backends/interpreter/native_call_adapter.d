module quickbite.backends.interpreter.native_call_adapter;

// Outbound calls prepare typed addresses for the value-free FFI bridge.
// Inbound callbacks borrow libffi's typed argument and result places.

private:

public class NativeCallException: Exception {
    public string className;
    public Throwable nativeThrowable;
    public const(void)* nativeThrowableObjectPointer;
    public NativeCallException chainedNext;

    public this(
        in string message,
        in string className,
        Throwable nativeThrowable,
    ) {
        super(message);
        this.className = className;
        this.nativeThrowable = nativeThrowable;
        nativeThrowableObjectPointer = cast(const(void)*) nativeThrowable;
    }
}

private NativeCallException nativeCallExceptionFrom(Throwable throwable) {
    auto result = new NativeCallException(
        throwable.msg,
        throwable.classinfo.name,
        throwable,
    );
    if (throwable.next !is null)
        result.chainedNext = nativeCallExceptionFrom(throwable.next);
    return result;
}

// Runs an interpreted delegate that native code called back into (ffi.md
// §34.16). The Walker supplies it so callback plumbing can re-enter the
// interpreter without this module importing the Walker.
public alias DelegateInvoker = imported!"quickbite.backends.interpreter.runtime_value".Value delegate(
    in imported!"quickbite.backends.interpreter.runtime_value".Value callee,
    in imported!"quickbite.backends.interpreter.runtime_value".Value[] arguments,
);

private alias InboundCallbackInvoker = void delegate(
    in size_t callbackId,
    imported!"dmd.mtype".Type returnType,
    imported!"dmd.mtype".Type[] parameterTypes,
    void*[] argumentBuffers,
    ubyte[] resultBuffer,
);

private struct InboundClosureContext {
    private InboundTrampolineRegistry* registry;
    private size_t callbackId;
    private imported!"dmd.mtype".Type returnType;
    private imported!"dmd.mtype".Type[] parameterTypes;
    private size_t returnSize;
    private imported!"quickbite.ffi.ffi".CompilerAbi compilerAbi;
    private const(void)* code;
    private imported!"quickbite.ffi.libffi".ffi_cif* cif;
    private imported!"quickbite.ffi.libffi".ffi_type*[] argumentFfiTypes;
}

private struct InboundTrampolineRegistry {
    private InboundCallbackInvoker _invoke;
    private InboundClosureContext*[] _contexts;
    private void*[] _closures;

    public this(InboundCallbackInvoker invoke) {
        _invoke = invoke;
    }

    public void setupDelegateArgument(
        ubyte[] buffer,
        imported!"dmd.mtype".Type delegateType,
        in size_t callbackId,
        in imported!"quickbite.ffi.ffi".CompilerAbi compilerAbi,
    ) {
        setupInboundDelegateArgument(
            buffer,
            delegateType,
            callbackId,
            compilerAbi,
            &this,
        );
    }

    public void close() {
        import quickbite.ffi.ffi: unregisterClosureAbi;
        import quickbite.ffi.libffi: ffi_closure_free;

        foreach (context; _contexts)
            unregisterClosureAbi(context.code);
        foreach (closure; _closures)
            ffi_closure_free(closure);
        _closures = null;
        _contexts = null;
        _invoke = null;
    }
}

private void setupInboundDelegateArgument(
    ubyte[] buffer,
    imported!"dmd.mtype".Type delegateType,
    in size_t callbackId,
    in imported!"quickbite.ffi.ffi".CompilerAbi compilerAbi,
    InboundTrampolineRegistry* registry,
) {
    import quickbite.ffi.ffi: libffiTypeFor, registerClosureAbi;
    import quickbite.ffi.libffi:
        ffi_cif, ffi_type, ffi_type_pointer, ffi_prep_cif, ffi_closure,
        ffi_closure_alloc, ffi_prep_closure_loc, FFI_DEFAULT_ABI;
    import dmd.mtype: Type, TypeFunction;

    auto functionType = delegateType is null
        ? null
        : cast(TypeFunction) delegateType.nextOf;
    if (functionType is null || registry is null)
        return;
    auto returnType = functionType.next.toBasetype;
    auto returnFfi = libffiTypeFor(returnType);
    if (returnFfi is null)
        return;

    const parameterCount = functionType.parameterList.length;
    auto parameterTypes = new Type[](parameterCount);
    foreach (index; 0 .. parameterCount) {
        parameterTypes[index] =
            functionType.parameterList[index].type.toBasetype;
        if (libffiTypeFor(parameterTypes[index]) is null)
            return;
    }

    auto argumentFfiTypes = new ffi_type*[](1 + parameterCount);
    argumentFfiTypes[0] = &ffi_type_pointer;
    foreach (abiIndex; 0 .. parameterCount)
        argumentFfiTypes[1 + abiIndex] = libffiTypeFor(parameterTypes[
            callbackSourceIndex(compilerAbi, parameterCount, abiIndex),
        ]);

    auto cif = new ffi_cif;
    if (ffi_prep_cif(
        cif,
        FFI_DEFAULT_ABI,
        cast(uint) (1 + parameterCount),
        returnFfi,
        argumentFfiTypes.ptr,
    ) != 0)
        return;

    auto context = new InboundClosureContext;
    context.registry = registry;
    context.callbackId = callbackId;
    context.returnType = returnType;
    context.parameterTypes = parameterTypes;
    context.returnSize = returnFfi.size < 8 ? 8 : returnFfi.size;
    context.compilerAbi = compilerAbi;
    context.cif = cif;
    context.argumentFfiTypes = argumentFfiTypes;
    registry._contexts ~= context;

    void* code;
    auto writable = ffi_closure_alloc(ffi_closure.sizeof, &code);
    if (writable is null)
        return;
    if (ffi_prep_closure_loc(
        cast(ffi_closure*) writable,
        cif,
        &inboundClosureTrampoline,
        cast(void*) context,
        code,
    ) != 0) {
        import quickbite.ffi.libffi: ffi_closure_free;

        ffi_closure_free(writable);
        return;
    }
    context.code = code;
    registerClosureAbi(code, compilerAbi);
    registry._closures ~= writable;

    *cast(void**) buffer.ptr = cast(void*) context;
    *cast(void**) (buffer.ptr + (void*).sizeof) = code;
}

private extern(C) void inboundClosureTrampoline(
    imported!"quickbite.ffi.libffi".ffi_cif* cif,
    void* result,
    void** arguments,
    void* userData,
) {
    auto context = cast(InboundClosureContext*) userData;
    const parameterCount = context.parameterTypes.length;
    auto sourceArguments = new void*[](parameterCount);
    foreach (abiIndex; 0 .. parameterCount)
        sourceArguments[callbackSourceIndex(
            context.compilerAbi,
            parameterCount,
            abiIndex,
        )] = arguments[1 + abiIndex];
    context.registry._invoke(
        context.callbackId,
        context.returnType,
        context.parameterTypes,
        sourceArguments,
        (cast(ubyte*) result)[0 .. context.returnSize],
    );
}

private size_t callbackSourceIndex(
    in imported!"quickbite.ffi.ffi".CompilerAbi compilerAbi,
    in size_t argumentCount,
    in size_t abiIndex,
) @safe @nogc nothrow pure {
    import quickbite.ffi.ffi: CompilerAbi;

    return compilerAbi == CompilerAbi.dmd
        ? argumentCount - abiIndex - 1
        : abiIndex;
}

// Session-owned callback roots and callback-id invoker for durable FFI
// trampolines. The registry owns libffi closure memory; this session owns
// interpreter Values and remains valid for the Walker session (§35.4).
public struct InterpreterInboundTrampolineSession {
    import quickbite.backends.interpreter.runtime_value: Value;

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
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue, writeValue;

        assert(callbackId < _callbacks.length, "unknown durable callback id");
        Value[] callbackArguments;
        foreach (index, parameterType; parameterTypes)
            callbackArguments ~= readValue(Place(
                argumentBuffers[index],
                parameterType,
            ));
        const callbackResult = _invokeDelegate(
            _callbacks[callbackId], callbackArguments,
        );
        if (returnType.ty == TY.Tvoid)
            return;

        resultBuffer[] = 0;
        writeValue(Place(resultBuffer.ptr, returnType), callbackResult);
        extendInboundIntegerResult(resultBuffer, returnType);
    }
}

// libffi reserves an ffi_arg-sized callback result cell for narrow integers.
// The typed write above fills the D value's own bytes; this extends only the
// ABI scratch tail, preserving the typed result place as the value authority.
private void extendInboundIntegerResult(
    ubyte[] resultBuffer,
    imported!"dmd.mtype".Type returnType,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.layout: typeByteSize;

    const valueSize = typeByteSize(returnType);
    if (resultBuffer.length <= valueSize || valueSize == 0)
        return;

    ubyte extension;
    switch (returnType.toBasetype.ty) with (TY) {
        case Tint8, Tint16, Tint32, Tint64:
            extension = (resultBuffer[valueSize - 1] & 0x80) == 0
                ? 0
                : 0xff;
            break;
        default:
            return;
    }
    resultBuffer[valueSize .. $] = extension;
}

// A typed, rooted address crossing the interpreter/native-call boundary.
// `owner` keeps interpreter-owned storage alive; `address` is the ABI operand
// itself and never denotes a recursively boxed aggregate snapshot.
public struct NativeOperand {
    public imported!"dmd.mtype".Type type;
    public void* address;
    public imported!"quickbite.backends.interpreter.native_block".NativeBlock owner;
    public imported!"quickbite.backends.interpreter.native_block".NativeBlock retained;
}

// The address-only bridge's complete call shape. Preparation owns selecting
// these typed addresses; execution may call `ffi.call` only once every field
// required by the selected shape is present.
private struct NativeInvocation {
    public imported!"quickbite.ffi.ffi".Callable callable;
    public imported!"quickbite.ffi.ffi".TypedAddress[] arguments;
    public imported!"quickbite.ffi.ffi".TypedAddress result;
    public imported!"quickbite.ffi.ffi".TypedAddress receiver;
    public imported!"quickbite.ffi.ffi".DVariadicMetadata variadicMetadata;
    public bool hasReceiver;
    public bool hasVariadicMetadata;
    public bool returnsRef;
    public bool returnsReceiver;
    public imported!"quickbite.backends.interpreter.native_block".NativeBlock[] roots;

    public bool isComplete() const @safe @nogc nothrow pure {
        if (
            callable.address is null ||
            callable.signature is null ||
            result.type is null
        )
            return false;
        foreach (argument; arguments)
            if (argument.type is null || argument.address is null)
                return false;
        if (hasReceiver &&
            (receiver.type is null || receiver.address is null))
            return false;
        if (hasVariadicMetadata &&
            (variadicMetadata.value.type is null ||
                variadicMetadata.value.address is null))
            return false;
        return true;
    }
}

public struct NativeCallRequest {
    public imported!"dmd.func".FuncDeclaration declaration;
    public imported!"dmd.mtype".TypeFunction delegateSignature;
    public const(void)* delegateAddress;
    public const(void)* delegateContext;
    public imported!"dmd.mtype".Type receiverType;
    public imported!"quickbite.backends.interpreter.runtime_value".Value receiver;
    public NativeOperand receiverOperand;
    public bool virtualDispatch;
    public bool returnsReceiver;
    public imported!"quickbite.backends.interpreter.runtime_value".Value[] arguments;
    public imported!"dmd.mtype".Type[] argumentTypes;
    public NativeOperand[] argumentOperands;
    public InterpreterInboundTrampolineSession* callbackSession;
}

public struct NativeCallResult {
    public imported!"quickbite.backends.interpreter.runtime_value".Value value;
    public void* referenceAddress;
}

public bool invokeNative(
    ref NativeCallRequest request,
    out NativeCallResult result,
) {
    NativeInvocation invocation;
    if (!prepareNativeInvocation(request, invocation) ||
        !executeNativeInvocation(invocation))
        return false;
    result = readNativeInvocationResult(invocation);
    return true;
}

private bool prepareNativeInvocation(
    ref NativeCallRequest request,
    out NativeInvocation invocation,
) {
    import dmd.astenums: LINK, STC, TY, VarArg;
    import dmd.mtype: Type, TypeFunction;
    import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.ffi.ffi:
        Callable, TypedAddress, compilerAbiFor, resolveCallable;

    auto signature = request.declaration is null
        ? request.delegateSignature
        : cast(TypeFunction) request.declaration.type;
    if (signature is null || signature.next is null ||
        (signature.linkage != LINK.c && signature.linkage != LINK.d &&
            signature.linkage != LINK.cpp))
        return false;
    if (signature.next.toBasetype.ty == TY.Taarray)
        return false;
    if (signature.parameterList.parameters !is null)
        foreach (parameter; *signature.parameterList.parameters)
            if (parameter.type.toBasetype.ty == TY.Taarray)
                return false;
    const cVariadic = signature.linkage == LINK.c &&
        signature.parameterList.varargs == VarArg.variadic;
    if (signature.parameterList.varargs != VarArg.none && !cVariadic)
        return false;

    invocation.returnsReceiver = request.returnsReceiver;
    if (request.receiverType !is null) {
        if (!prepareNativeOperand(
            request.receiverType,
            request.receiver,
            request.receiverOperand,
            null,
            invocation,
            invocation.receiver,
        ))
            return false;
        invocation.hasReceiver = true;
    } else if (request.delegateAddress !is null) {
        auto contextOwner = NativeBlock.allocate(
            (void*).sizeof,
            NativeBlock.Scan.conservative,
        );
        *cast(const(void)**) contextOwner.address = request.delegateContext;
        invocation.receiver = TypedAddress(Type.tvoidptr, contextOwner.address);
        invocation.hasReceiver = true;
        invocation.roots ~= contextOwner;
    }

    if (request.declaration !is null) {
        const objectAddress = invocation.hasReceiver &&
                request.receiverType.toBasetype.ty == TY.Tclass
            ? loadReference(invocation.receiver.address)
            : null;
        invocation.callable = resolveCallable(
            request.declaration,
            request.virtualDispatch,
            objectAddress,
        );
    } else if (request.delegateAddress !is null)
        invocation.callable = Callable(
            cast(void*) request.delegateAddress,
            signature,
            compilerAbiFor(cast(void*) request.delegateAddress),
        );
    else
        return false;
    if (invocation.callable.address is null)
        return false;

    const fixedCount = signature.parameterList.length;
    if (request.arguments.length != request.argumentTypes.length ||
        cVariadic && request.arguments.length < fixedCount ||
        !cVariadic && request.arguments.length != fixedCount)
        return false;
    invocation.arguments.length = request.arguments.length;
    foreach (index, argument; request.arguments) {
        auto type = index < fixedCount
            ? signature.parameterList[index].type.toBasetype
            : request.argumentTypes[index].toBasetype;
        if (request.argumentTypes[index] is null ||
            index < fixedCount &&
                !sameNativeStorageType(request.argumentTypes[index], type))
            return false;
        const isReference = index < fixedCount &&
            (signature.parameterList[index].storageClass &
                (STC.ref_ | STC.out_)) != STC.none;
        auto supplied = index < request.argumentOperands.length
            ? request.argumentOperands[index]
            : NativeOperand.init;
        if (isReference && !operandMatches(supplied, type))
            return false;
        if (!prepareNativeOperand(
            type,
            argument,
            supplied,
            request.callbackSession,
            invocation,
            invocation.arguments[index],
        ))
            return false;
    }

    auto returnType = signature.next.toBasetype;
    invocation.returnsRef = signature.isRef;
    if (invocation.returnsRef) {
        auto owner = NativeBlock.allocate(
            (void*).sizeof,
            NativeBlock.Scan.conservative,
        );
        invocation.result = TypedAddress(returnType, owner.address);
        invocation.roots ~= owner;
    } else if (returnType.ty == TY.Tvoid || returnType.ty == TY.Tnoreturn) {
        invocation.result = TypedAddress(returnType, null);
    } else {
        auto owner = NativeBlock.allocate(
            typeByteSize(returnType),
            typeHasPointers(returnType)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );
        invocation.result = TypedAddress(returnType, owner.address);
        invocation.roots ~= owner;
    }
    return invocation.isComplete;
}

private bool prepareNativeOperand(
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    NativeOperand supplied,
    InterpreterInboundTrampolineSession* callbackSession,
    ref NativeInvocation invocation,
    out imported!"quickbite.ffi.ffi".TypedAddress result,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.place_value: valueMatchesPlace, writeValue;
    import quickbite.backends.interpreter.runtime_value: Value;
    import quickbite.ffi.ffi: TypedAddress;

    const interpretedDelegate = type.toBasetype.ty == TY.Tdelegate &&
        value != Value.null_ &&
        !value.isNativeDelegate;
    if (!interpretedDelegate && operandMatches(supplied, type)) {
        result = TypedAddress(type, supplied.address);
        if (supplied.owner.address !is null)
            invocation.roots ~= supplied.owner;
        if (supplied.retained.address !is null)
            invocation.roots ~= supplied.retained;
        return true;
    }
    if (value.isNativeAggregate) {
        auto aggregate = AggregateValue.native(value);
        if (sameNativeStorageType(aggregate.type, type)) {
            result = TypedAddress(type, cast(void*) aggregate.address);
            return true;
        }
    }

    auto owner = NativeBlock.allocate(
        typeByteSize(type),
        typeHasPointers(type)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no,
    );
    if (type.toBasetype.ty == TY.Tdelegate && value != Value.null_) {
        if (value.isNativeDelegate) {
            *cast(const(void)**) owner.address = value.nativeDelegateContext;
            *cast(const(void)**) (cast(ubyte*) owner.address + (void*).sizeof) =
                value.nativeDelegateFuncptr;
        } else {
            if (callbackSession is null)
                return false;
            callbackSession.registry.setupDelegateArgument(
                owner.bytes,
                type,
                callbackSession.register(value),
                invocation.callable.compilerAbi,
            );
        }
    } else if (type.toBasetype.ty == TY.Tpointer &&
        type.toBasetype.nextOf.toBasetype.ty == TY.Tchar &&
        AggregateValue.isArray(value))
    {
        auto characters = NativeBlock.allocate(
            AggregateValue.length(value) + 1,
            NativeBlock.Scan.no,
        );
        foreach (index; 0 .. AggregateValue.length(value))
            characters.bytes[index] = cast(ubyte)
                AggregateValue.elementAt(value, index).asLong;
        writeValue(Place(owner.address, type), Value.pointerValue(characters.address));
        invocation.roots ~= characters;
    } else if (valueMatchesPlace(type, value) ||
        type.toBasetype.ty == TY.Tclass &&
            (value.isPointer || value == Value.null_) ||
        type.toBasetype.ty == TY.Tdelegate && value == Value.null_)
    {
        writeValue(Place(owner.address, type), value);
    } else
        return false;

    result = TypedAddress(type, owner.address);
    invocation.roots ~= owner;
    return true;
}

private bool operandMatches(
    NativeOperand operand,
    imported!"dmd.mtype".Type type,
) {
    return operand.address !is null && operand.type !is null &&
        sameNativeStorageType(operand.type, type);
}

private bool sameNativeStorageType(
    imported!"dmd.mtype".Type left,
    imported!"dmd.mtype".Type right,
) {
    import dmd.astenums: TY;
    import dmd.typesem: mutableOf;
    import quickbite.backends.interpreter.layout:
        staticArrayLength, typeByteSize;

    if (left is null || right is null)
        return false;
    auto leftBase = left.toBasetype;
    auto rightBase = right.toBasetype;
    if (leftBase.ty != rightBase.ty ||
        typeByteSize(leftBase) != typeByteSize(rightBase))
        return false;

    switch (leftBase.ty) with (TY) {
        case Tarray, Tpointer:
            return sameNativeStorageType(leftBase.nextOf, rightBase.nextOf);
        case Tsarray:
            return staticArrayLength(leftBase.isTypeSArray) ==
                    staticArrayLength(rightBase.isTypeSArray) &&
                sameNativeStorageType(leftBase.nextOf, rightBase.nextOf);
        case Tstruct:
            return leftBase.isTypeStruct.sym is rightBase.isTypeStruct.sym;
        case Tclass:
            return leftBase.isTypeClass.sym is rightBase.isTypeClass.sym;
        default:
            return mutableOf(leftBase).equals(mutableOf(rightBase));
    }
}

private const(void)* loadReference(const(void)* address) @trusted {
    return *cast(const(void)**) address;
}

private bool executeNativeInvocation(ref NativeInvocation invocation) {
    import quickbite.ffi.ffi: call;

    if (!invocation.isComplete)
        return false;
    try {
        return call(
            invocation.callable,
            invocation.arguments,
            invocation.result,
            invocation.hasReceiver ? &invocation.receiver : null,
            invocation.hasVariadicMetadata
                ? &invocation.variadicMetadata
                : null,
        );
    } catch (Exception exception) {
        throw nativeCallExceptionFrom(exception);
    }
}

private NativeCallResult readNativeInvocationResult(
    ref NativeInvocation invocation,
) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.place_value: readValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    NativeCallResult result;
    if (invocation.returnsReceiver) {
        result.value = readValue(Place(
            invocation.receiver.address,
            invocation.receiver.type,
        ));
        return result;
    }
    if (invocation.returnsRef) {
        result.referenceAddress = loadMutableReference(invocation.result.address);
        result.value = readValue(Place(
            result.referenceAddress,
            invocation.result.type,
        ));
        return result;
    }
    switch (invocation.result.type.toBasetype.ty) with (TY) {
        case Tvoid, Tnoreturn:
            result.value = Value.void_;
            break;
        case Tdelegate:
            result.value = Value.nativeDelegateValue(
                loadReference(invocation.result.address),
                loadReference(cast(ubyte*) invocation.result.address +
                    (void*).sizeof),
            );
            break;
        default:
            result.value = readValue(Place(
                invocation.result.address,
                invocation.result.type,
            ));
            break;
    }
    return result;
}

private void* loadMutableReference(void* address) @trusted {
    return *cast(void**) address;
}

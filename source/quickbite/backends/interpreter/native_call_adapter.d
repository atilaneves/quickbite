module quickbite.backends.interpreter.native_call_adapter;

// Outbound calls prepare typed addresses for the address-only FFI bridge.
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

// Runs an interpreted delegate that native code called back into. The Walker
// supplies it so callback plumbing can re-enter the interpreter without this
// module importing the Walker.
public alias DelegateInvoker = imported!"quickbite.backends.interpreter.expression_result".ExpressionResult delegate(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult callee,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult[] arguments,
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
    private imported!"quickbite.ffi.libffi".ffi_cif cif;
    private imported!"quickbite.ffi.libffi".ffi_type*[] argumentFfiTypes;
    private imported!"dmd.mtype".Type _singleParameterType;
    private imported!"quickbite.ffi.libffi".ffi_type*[2]
        _inlineArgumentFfiTypes;
    private void* _argumentStorage;

    public void initializeArguments(in size_t parameterCount) {
        import core.memory: GC;
        import dmd.mtype: Type;
        import quickbite.ffi.libffi: ffi_type;

        if (parameterCount <= 1) {
            parameterTypes = parameterCount == 0
                ? null
                : (&_singleParameterType)[0 .. 1];
            argumentFfiTypes = _inlineArgumentFfiTypes[
                0 .. parameterCount + 1
            ];
            return;
        }

        const ffiTypesOffset = alignedOffset(
            Type.sizeof * parameterCount,
            (ffi_type*).alignof,
        );
        const byteLength = ffiTypesOffset +
            (ffi_type*).sizeof * (parameterCount + 1);
        _argumentStorage = GC.calloc(byteLength);
        parameterTypes = (cast(Type*) _argumentStorage)[0 .. parameterCount];
        argumentFfiTypes = (cast(ffi_type**) (
            cast(ubyte*) _argumentStorage + ffiTypesOffset
        ))[0 .. parameterCount + 1];
    }
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
    auto context = new InboundClosureContext;
    context.initializeArguments(parameterCount);
    auto parameterTypes = context.parameterTypes;
    foreach (index; 0 .. parameterCount) {
        parameterTypes[index] =
            functionType.parameterList[index].type.toBasetype;
        if (libffiTypeFor(parameterTypes[index]) is null)
            return;
    }

    auto argumentFfiTypes = context.argumentFfiTypes;
    argumentFfiTypes[0] = &ffi_type_pointer;
    foreach (abiIndex; 0 .. parameterCount)
        argumentFfiTypes[1 + abiIndex] = libffiTypeFor(parameterTypes[
            callbackSourceIndex(compilerAbi, parameterCount, abiIndex),
        ]);

    if (ffi_prep_cif(
        &context.cif,
        FFI_DEFAULT_ABI,
        cast(uint) (1 + parameterCount),
        returnFfi,
        argumentFfiTypes.ptr,
    ) != 0)
        return;

    context.registry = registry;
    context.callbackId = callbackId;
    context.returnType = returnType;
    context.parameterTypes = parameterTypes;
    context.returnSize = returnFfi.size < 8 ? 8 : returnFfi.size;
    context.compilerAbi = compilerAbi;
    registry._contexts ~= context;

    void* code;
    auto writable = ffi_closure_alloc(ffi_closure.sizeof, &code);
    if (writable is null)
        return;
    if (ffi_prep_closure_loc(
        cast(ffi_closure*) writable,
        &context.cif,
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
    void*[1] inlineSourceArgument;
    auto sourceArguments = parameterCount == 0
        ? null
        : parameterCount == 1
            ? inlineSourceArgument[]
            : new void*[](parameterCount);
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

private size_t alignedOffset(
    in size_t offset,
    in size_t alignment,
) @safe @nogc nothrow pure {
    return (offset + alignment - 1) / alignment * alignment;
}

// Session-owned callback roots and callback-id invoker for durable FFI
// trampolines. The registry owns libffi closure memory; this session owns
// interpreter callback results and remains valid for the Walker session.
public struct InterpreterInboundTrampolineSession {
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    private ExpressionResult[] _callbacks;
    private DelegateInvoker _invokeDelegate;
    private InboundTrampolineRegistry* _registry;

    public this(DelegateInvoker invokeDelegate) {
        _invokeDelegate = invokeDelegate;
        _registry = new InboundTrampolineRegistry(&invoke);
    }

    public InboundTrampolineRegistry* registry() {
        return _registry;
    }

    public size_t register(in ExpressionResult callback) {
        _callbacks ~= callback;
        return _callbacks.length - 1;
    }

    // Durable callbacks are valid only while their owning Walker can service
    // re-entry. Release the executable libffi closures and callback roots as
    // that session ends.
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
        ExpressionResult[1] inlineCallbackArgument;
        auto callbackArguments = parameterTypes.length == 0
            ? null
            : parameterTypes.length == 1
                ? inlineCallbackArgument[]
                : new ExpressionResult[](parameterTypes.length);
        foreach (index, parameterType; parameterTypes)
            callbackArguments[index] = readValue(Place(
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
// itself, pointing directly at the value's native-layout bytes.
public struct NativeOperand {
    public imported!"dmd.mtype".Type type;
    public void* address;
    public imported!"quickbite.backends.interpreter.native_block".NativeBlock owner;
    public InterpreterInboundTrampolineSession* callbackSession;
    public size_t callbackId;
    // Delegate result words cross the native boundary as typed metadata. They
    // are not decoded by the general place-value codec, because that codec
    // deliberately only recognizes the all-zero null delegate representation.
    public NativeDelegate delegateMetadata;
}

// The native ABI representation of a D delegate. This metadata belongs to a
// typed NativeOperand and crosses only at the native-call boundary.
public struct NativeDelegate {
    public const(void)* context;
    public const(void)* funcptr;

    public bool isNull() const @safe @nogc nothrow pure {
        return context is null && funcptr is null;
    }
}

// The address-only bridge's complete call shape. Preparation owns selecting
// these typed addresses; execution may call `ffi.call` only once every field
// required by the selected shape is present.
private struct NativeInvocation {
    public imported!"quickbite.ffi.ffi".Callable callable;
    public imported!"quickbite.ffi.ffi".TypedAddress result;
    public imported!"quickbite.ffi.ffi".TypedAddress receiver;
    public imported!"quickbite.ffi.ffi".DVariadicMetadata variadicMetadata;
    public bool hasReceiver;
    public bool hasVariadicMetadata;
    public bool returnsRef;
    public bool returnsReceiver;
    private size_t _argumentCount;
    private size_t _rootCount;
    private void* _storage;
    private imported!"quickbite.ffi.ffi".TypedAddress _singleArgument;
    private imported!"quickbite.backends.interpreter.native_block".NativeBlock[3]
        _inlineRoots;
    private imported!"quickbite.backends.interpreter.native_block".NativeBlock
        _resultOwner;

    public this(in size_t argumentCount) {
        import core.memory: GC;

        _argumentCount = argumentCount;
        if (argumentCount > 1)
            _storage = GC.calloc(storageByteLength(argumentCount));
    }

    // @trusted: `_storage` is either null or the base pointer returned by
    // this value's own `GC.calloc` call. `invokeNative` releases the uncopied
    // staging value after native execution and result extraction complete.
    public void release() pure nothrow @nogc @trusted {
        import core.memory: GC;

        auto storage = _storage;
        _storage = null;
        GC.free(storage);
    }

    // `_storage` is allocated for exactly `_argumentCount` TypedAddresses
    // followed by the aligned roots range; this bounded cast exposes only the
    // first range.
    public inout(imported!"quickbite.ffi.ffi".TypedAddress)[] arguments()
    inout @trusted @nogc nothrow pure {
        alias TypedAddress = imported!"quickbite.ffi.ffi".TypedAddress;

        if (_argumentCount == 0)
            return null;
        if (_argumentCount == 1)
            return (&_singleArgument)[0 .. 1];
        return (cast(inout(TypedAddress)*) _storage)[0 .. _argumentCount];
    }

    public void retainRoot(
        imported!"quickbite.backends.interpreter.native_block".NativeBlock root,
    ) {
        auto storage = roots;
        assert(_rootCount < storage.length);
        storage[_rootCount++] = root;
    }

    private imported!"quickbite.backends.interpreter.native_block".NativeBlock[]
    roots() {
        alias NativeBlock = imported!"quickbite.backends.interpreter.native_block".NativeBlock;

        if (_argumentCount <= 1)
            return _inlineRoots[0 .. _argumentCount + 2];
        return (cast(NativeBlock*) (
            cast(ubyte*) _storage + rootsOffset(_argumentCount)
        ))[0 .. _argumentCount + 2];
    }

    private static size_t storageByteLength(
        in size_t argumentCount,
    ) @safe @nogc nothrow pure {
        alias NativeBlock = imported!"quickbite.backends.interpreter.native_block".NativeBlock;

        return rootsOffset(argumentCount) +
            NativeBlock.sizeof * (argumentCount + 2);
    }

    private static size_t rootsOffset(
        in size_t argumentCount,
    ) @safe @nogc nothrow pure {
        alias NativeBlock = imported!"quickbite.backends.interpreter.native_block".NativeBlock;
        alias TypedAddress = imported!"quickbite.ffi.ffi".TypedAddress;

        return alignedOffset(
            TypedAddress.sizeof * argumentCount,
            NativeBlock.alignof,
        );
    }

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
    public NativeOperand receiverOperand;
    public bool virtualDispatch;
    public bool returnsReceiver;
    // Non-null means the caller owns typed storage for an ordinary result.
    // Reference returns and receiver returns still use their existing result
    // paths because their ABI result is an address, not the value bytes.
    public void* resultAddress;
    public imported!"dmd.mtype".Type[] argumentTypes;
    public NativeOperand[] argumentOperands;
    public InterpreterInboundTrampolineSession* callbackSession;
}

public struct NativeCallResult {
    public NativeOperand value;
}

public bool invokeNative(
    ref NativeCallRequest request,
    out NativeCallResult result,
) {
    NativeInvocation invocation;
    scope(exit) invocation.release;
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

    const fixedCount = signature.parameterList.length;
    if (request.argumentOperands.length != request.argumentTypes.length ||
        cVariadic && request.argumentOperands.length < fixedCount ||
        !cVariadic && request.argumentOperands.length != fixedCount)
        return false;
    invocation = NativeInvocation(request.argumentOperands.length);

    invocation.returnsReceiver = request.returnsReceiver;
    if (request.receiverType !is null) {
        if (!prepareNativeOperand(
            request.receiverType,
            request.receiverOperand,
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
        invocation.retainRoot(contextOwner);
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

    foreach (index, supplied; request.argumentOperands) {
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
        if (isReference && !operandMatches(supplied, type))
            return false;
        if (!prepareNativeOperand(
            type,
            supplied,
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
        invocation._resultOwner = owner;
        invocation.retainRoot(owner);
    } else if (returnType.ty == TY.Tvoid || returnType.ty == TY.Tnoreturn) {
        invocation.result = TypedAddress(returnType, null);
    } else if (request.resultAddress !is null && !request.returnsReceiver) {
        invocation.result = TypedAddress(returnType, request.resultAddress);
    } else {
        auto owner = NativeBlock.allocate(
            typeByteSize(returnType),
            typeHasPointers(returnType)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );
        invocation.result = TypedAddress(returnType, owner.address);
        invocation._resultOwner = owner;
        invocation.retainRoot(owner);
    }
    return invocation.isComplete;
}

private bool prepareNativeOperand(
    imported!"dmd.mtype".Type type,
    NativeOperand supplied,
    ref NativeInvocation invocation,
    out imported!"quickbite.ffi.ffi".TypedAddress result,
) {
    import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.ffi.ffi: TypedAddress;

    if (operandMatches(supplied, type)) {
        result = TypedAddress(type, supplied.address);
        if (supplied.owner.address !is null)
            invocation.retainRoot(supplied.owner);
        return true;
    }
    if (supplied.callbackSession is null)
        return false;
    auto owner = NativeBlock.allocate(
        typeByteSize(type),
        typeHasPointers(type) ? NativeBlock.Scan.conservative :
            NativeBlock.Scan.no,
    );
    supplied.callbackSession.registry.setupDelegateArgument(
        owner.bytes,
        type,
        supplied.callbackId,
        invocation.callable.compilerAbi,
    );
    result = TypedAddress(type, owner.address);
    invocation.retainRoot(owner);
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
    } catch (Throwable throwable) {
        throw nativeCallExceptionFrom(throwable);
    }
}

private NativeCallResult readNativeInvocationResult(
    ref NativeInvocation invocation,
) {
    import dmd.astenums: TY;

    NativeCallResult result;
    if (invocation.returnsReceiver) {
        result.value = nativeResultOperand(
            invocation.receiver.type,
            invocation.receiver.address,
        );
        return result;
    }
    if (invocation.returnsRef) {
        result.value = nativeResultOperand(
            invocation.result.type,
            loadMutableReference(invocation.result.address),
            invocation._resultOwner,
        );
        return result;
    }
    switch (invocation.result.type.toBasetype.ty) with (TY) {
        case Tvoid, Tnoreturn:
            result.value = NativeOperand.init;
            break;
        default:
            result.value = nativeResultOperand(
                invocation.result.type,
                invocation.result.address,
                invocation._resultOwner,
            );
            break;
    }
    return result;
}

private NativeOperand nativeResultOperand(
    imported!"dmd.mtype".Type type,
    void* address,
    imported!"quickbite.backends.interpreter.native_block".NativeBlock owner =
        imported!"quickbite.backends.interpreter.native_block".NativeBlock.init,
) {
    import dmd.astenums: TY;

    auto result = NativeOperand(type, address, owner);
    if (address !is null && type !is null && type.toBasetype.ty == TY.Tdelegate)
        result.delegateMetadata = nativeDelegateMetadata(result);
    return result;
}

// Read a D delegate's native ABI words from a typed address. Native delegate
// result destinations can be caller-provided storage, so later typed reads use
// this crossing too instead of the general place-value codec.
public NativeDelegate nativeDelegateMetadata(NativeOperand operand) @trusted {
    import dmd.astenums: TY;

    assert(operand.type !is null && operand.type.toBasetype.ty == TY.Tdelegate);
    if (operand.address is null)
        return NativeDelegate.init;
    return NativeDelegate(
        loadReference(operand.address),
        loadReference(cast(ubyte*) operand.address + (void*).sizeof),
    );
}

private void* loadMutableReference(void* address) @trusted {
    return *cast(void**) address;
}

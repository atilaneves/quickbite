module quickbite.backends.bytecode.core.native_call;

// An outbound native call hands `quickbite.ffi.ffi` the addresses of the frame
// slots holding the call's operands. Frame storage is already the value's
// native D representation, so nothing is copied in, reordered, converted or
// written back: an argument slot, a receiver slot and the result slot are
// themselves the ABI operands. `&local` arguments are no exception: the slot
// holds the local's own frame address (`Op.frameAddress`), so the callee writes
// straight into the local.

private:

// The address-only bridge's complete call shape. Preparation selects the typed
// addresses; execution may invoke the bridge only once every field the shape
// needs is present.
private struct NativeInvocation {
    public imported!"quickbite.ffi.ffi".Callable callable;
    public imported!"quickbite.ffi.ffi".TypedAddress[] arguments;
    public imported!"quickbite.ffi.ffi".TypedAddress result;
    public imported!"quickbite.ffi.ffi".TypedAddress receiver;
    public bool hasReceiver;
    public bool returnsRef;
    // A ref return yields the referenced address rather than a value; the
    // bridge writes that pointer here and the frame receives what it names.
    public void* reference;
    public size_t destination;

    public bool isComplete() const @safe @nogc nothrow pure {
        if (callable.address is null || callable.signature is null ||
            result.type is null)
            return false;
        foreach (argument; arguments)
            if (argument.type is null || argument.address is null)
                return false;
        return !hasReceiver ||
            receiver.type !is null && receiver.address !is null;
    }
}

// Returns false for any call shape the bridge declines, leaving the caller's
// no-available-source diagnostic as the reported outcome.
package(quickbite.backends.bytecode) bool callNative(
    ref imported!"quickbite.backends.bytecode.core.program".NativeCall native,
    ubyte[] stack,
    in size_t base,
    in size_t argumentArea,
    in size_t destination,
) {
    NativeInvocation invocation;
    if (!prepareNativeInvocation(
            native, stack, base, argumentArea, destination, invocation,
        ) ||
        !executeNativeInvocation(invocation))
        return false;
    writeNativeInvocationResult(invocation, stack);
    return true;
}

private bool prepareNativeInvocation(
    ref imported!"quickbite.backends.bytecode.core.program".NativeCall native,
    ubyte[] stack,
    in size_t base,
    in size_t argumentArea,
    in size_t destination,
    out NativeInvocation invocation,
) {
    import dmd.astenums: TY;
    import dmd.mtype: TypeFunction;
    import quickbite.backends.bytecode.core.program: nativeArgumentSlotSize;
    import quickbite.ffi.ffi: TypedAddress, resolveCallable;

    if (native.function_ is null)
        return false;
    auto signature = cast(TypeFunction) native.function_.type;
    if (signature is null || signature.next is null)
        return false;

    // A class receiver crosses as the raw object pointer the slot holds; a
    // struct receiver as a hidden `this` pointing at the VM's inline block.
    if (native.nativeClassReceiverType !is null) {
        invocation.receiver = TypedAddress(
            native.nativeClassReceiverType,
            frameAddress(stack, base + native.nativeClassReceiverOffset),
        );
        invocation.hasReceiver = true;
    } else if (native.nativeStructReceiverType !is null) {
        invocation.receiver = TypedAddress(
            native.nativeStructReceiverType,
            frameAddress(stack, base + native.nativeStructReceiverOffset),
        );
        invocation.hasReceiver = true;
    }

    // Virtual dispatch reads the final overrider from the receiver object's
    // own vtable, so the object pointer, not its storage, resolves the code.
    const isClassReceiver = native.nativeClassReceiverType !is null;
    invocation.callable = resolveCallable(
        native.function_,
        isClassReceiver,
        isClassReceiver ? loadPointer(invocation.receiver.address) : null,
    );

    const fixedCount = signature.parameterList.length;
    invocation.arguments.length = native.argumentTypes.length;
    // `argumentOffsets` is empty for an ordinary direct call: each argument
    // then sits at the uniform `index * nativeArgumentSlotSize` stride
    // `allocateNativeArgumentArea` laid out. A native-leaf function reached
    // through a function-pointer value instead carries its callee's own
    // dense VM parameter-frame offsets (`ParameterLayout.offsets`) -- the
    // caller built an ordinary typed-frame argument area for the indirect
    // call, not a native one, so each argument's address is computed
    // differently.
    foreach (index; 0 .. native.argumentTypes.length) {
        // The declared parameter is the bridge's authority for a fixed
        // argument; only a C variadic tail is typed by the call site, which
        // the signature does not describe.
        auto type = index < fixedCount
            ? signature.parameterList[index].type.toBasetype
            : native.argumentTypes[index].toBasetype;
        const argumentOffset = native.argumentOffsets.length != 0
            ? argumentArea + native.argumentOffsets[index]
            : argumentArea + index * nativeArgumentSlotSize;
        invocation.arguments[index] = TypedAddress(
            type,
            frameAddress(stack, argumentOffset),
        );
    }

    auto returnType = signature.next.toBasetype;
    invocation.destination = destination;
    invocation.returnsRef = signature.isRef;
    if (invocation.returnsRef)
        invocation.result = TypedAddress(returnType, &invocation.reference);
    else if (returnType.ty == TY.Tvoid || returnType.ty == TY.Tnoreturn)
        invocation.result = TypedAddress(returnType, null);
    else
        invocation.result =
            TypedAddress(returnType, frameAddress(stack, destination));
    return invocation.isComplete;
}

private bool executeNativeInvocation(ref NativeInvocation invocation) {
    import quickbite.ffi.ffi: call;

    return call(
        invocation.callable,
        invocation.arguments,
        invocation.result,
        invocation.hasReceiver ? &invocation.receiver : null,
    );
}

// A ref return names storage the callee owns: the frame slot holds the
// referenced ADDRESS, not its value, mirroring how a VM-compiled callee's own
// `ref`-returning call leaves an address at its result slot. `compileCall`'s
// callers dereference through that address for an rvalue read
// (`compileExpression`'s `CallExp` handling) or wrap it directly as an
// lvalue (`resolvePlace`'s `pointerPlace`); writing the dereferenced value
// here instead would satisfy the former by accident while corrupting the
// latter, since the frame slot must hold a pointer either way.
private void writeNativeInvocationResult(
    ref NativeInvocation invocation,
    ubyte[] stack,
) @safe {
    if (!invocation.returnsRef)
        return;
    if (invocation.reference is null)
        throw new Exception("Native ref return has null address.");
    stack[
        invocation.destination
        .. invocation.destination + size_t.sizeof
    ] = pointerBytes(invocation.reference);
}

// @trusted: reinterprets a pointer value's own bytes, not the memory it
// addresses.
private ubyte[size_t.sizeof] pointerBytes(in void* pointer) @trusted {
    return *cast(const(ubyte[size_t.sizeof])*) &pointer;
}

// @trusted: the machine reserves the VM stack's capacity up front so growing a
// frame never reallocates, which keeps a slot address valid for the whole
// native call, the same guarantee `Op.frameAddress` relies on for `&local`.
private void* frameAddress(ubyte[] stack, in size_t offset) @trusted {
    return &stack[offset];
}

// @trusted: the slot holds a class reference, which is already an object
// pointer.
private const(void)* loadPointer(in void* address) @trusted {
    return *cast(const(void*)*) address;
}

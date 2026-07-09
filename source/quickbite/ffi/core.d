module quickbite.ffi.core;

private:


public void loadDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages)
        loadDependencyImage(dependencyImage);
}

// Returns a diagnostic naming an FFI-uncrossable type in `function_`'s
// signature (today: an associative array, whose hashing/allocation the bridge
// cannot reproduce across the ABI), or null if none. Lets the caller replace
// the misleading no-available-source message with an honest one (ffi.md
// §34.3.1 item 0). Scoped to the top-level return and parameter types; an AA
// nested inside a struct or slice is out of scope.
public string unsupportedNativeTypeMessage(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.mtype: TypeFunction;
    import std.conv: text;

    auto type = cast(TypeFunction) function_.type;
    if (type is null)
        return null;

    auto offending = uncrossableAssocArray(type.next);
    if (offending is null && type.parameterList.parameters !is null)
        foreach (parameter; *type.parameterList.parameters) {
            offending = uncrossableAssocArray(parameter.type);
            if (offending !is null)
                break;
        }

    if (offending is null)
        return null;

    return text(
        "`",
        function_.toChars,
        "` cannot be called natively: the associative array type `",
        offending.toChars,
        "` cannot cross the FFI boundary",
    );
}

// The basetype of `type` if it is an associative array the bridge cannot cross,
// else null.
private imported!"dmd.mtype".Type uncrossableAssocArray(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    if (type is null)
        return null;

    auto base = type.toBasetype;
    return base.ty == TY.Taarray ? base : null;
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
    // Which way a value crosses the boundary: toNative marshals a backend
    // value into ABI bytes (arguments, receivers, out-cell inputs); fromNative
    // reifies ABI bytes into a backend value (returns, out-cell writebacks).
    enum Direction {
        toNative,
        fromNative,
    }

    // Whether the backend can cross `type` in the given direction. The
    // marshaller owns representability (ffi.md §35.8): the core consults this
    // before ffi_prep_cif so type-mapper/marshaller drift degrades to the
    // graceful no-available-source diagnostic instead of a post-call assert.
    bool canRepresent(imported!"dmd.mtype".Type type, in Direction direction);

    // Whether the backend can cross an out-parameter's pointed-to type as an
    // out cell (ffi.md §35.10). Distinct from canRepresent both-directions
    // because an out cell crosses as an opaque native byte buffer the callee
    // writes and the backend snapshots back: a union out-cell round-trips its
    // overlapped bytes verbatim even where a by-value union cannot be
    // marshalled from a boxed value (ffi.md §35.7). Backends that cannot
    // special-case this fall back to canRepresent both directions.
    bool canRepresentOutCell(imported!"dmd.mtype".Type pointedToType);

    void fillArgument(
        ubyte[] buffer,
        imported!"dmd.mtype".Type type,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    );

    // Optional zero-copy seam (§35.1): a native-layout backend can return the
    // stable address of the argument slot containing ABI bytes. Returning null
    // keeps the boxed Interpreter on the existing core-owned buffer path.
    const(void)* argumentAddress(
        in size_t index,
        imported!"dmd.mtype".Type type,
    );

    void fillReceiver(
        ubyte[] buffer,
        imported!"dmd.mtype".Type type,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    );

    void readResult(imported!"dmd.mtype".Type type, in ubyte[] buffer);

    // Optional zero-copy result slot. Returning null keeps today's return
    // buffer plus readResult copy-out behavior.
    void* resultAddress(imported!"dmd.mtype".Type type);

    void writeRefResult(
        imported!"dmd.mtype".Type type,
        void* address,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    );

    void writeOutParameter(
        in size_t index,
        imported!"dmd.mtype".Type pointedToType,
        in ubyte[] cell,
    );

    // Marshal the argument's current pointed-to value into a freshly allocated
    // out-parameter cell before the call (ffi.md §35.6): an in-out scalar or a
    // read-through pointer input must see the caller's value, not zeroes. The
    // `&local` disambiguation governs only writeback, never input suppression.
    void fillOutParameterCell(
        ubyte[] cell,
        imported!"dmd.mtype".Type pointedToType,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    );

    // The receiver object pointer for a class member call: the class reference
    // itself, passed directly as hidden `this` and used to read the vtable for
    // virtual dispatch (ffi.md §34.12). Unused for non-member and struct calls.
    const(void)* receiverObjectPointer();

    // Reverse bridge (ffi.md §34.16): native code called back into the
    // interpreted delegate passed as argument `argumentIndex`. The core reifies
    // nothing itself — it hands the native argument buffers (in source order)
    // and the parameter/return types to the backend, which materializes its own
    // values, runs the closure, and writes the result bytes into `resultBuffer`.
    void invokeClosure(
        in size_t argumentIndex,
        imported!"dmd.mtype".Type returnType,
        imported!"dmd.mtype".Type[] parameterTypes,
        void*[] argumentBuffers,
        ubyte[] resultBuffer,
    );
}

// `argumentTypes` are the call site's actual argument types (one per argument).
// Fixed parameters are taken from the signature; the variadic tail (C `...`)
// relies on these actual types, which the signature does not carry (§34.14).
// `addressOfLocalArguments[i]` is true when argument `i` is `&local` at the call
// site, which disambiguates a single-level pointer-to-scalar out slot from an
// ordinary in-pointer (ffi.md §34.8).
public bool callNative(
    imported!"dmd.func".FuncDeclaration function_,
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
) {
    return callNativeImpl(
        function_,
        NativeThis.init,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    );
}

public bool assignNativeRefReturn(
    imported!"dmd.func".FuncDeclaration function_,
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
) {
    return callNativeImpl(
        function_,
        NativeThis.init,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
        RefReturnMode.write,
    );
}

public bool callNativeMember(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.mtype".TypeStruct receiverType,
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
) {
    if (receiverType is null)
        return false;

    return callNativeImpl(
        function_,
        NativeThis(receiverType, true),
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    );
}

// Call a native delegate reified from a native return value (ffi.md §35.8):
// the inverse of the §34.16 closure trampoline. The funcptr is invoked with
// the context pointer leading and the extern(D) explicit arguments reversed;
// there is no symbol resolution, the pair already names the code to run.
public bool callNativeDelegate(
    imported!"dmd.mtype".TypeFunction type,
    const void* funcptr,
    const void* context,
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
) {
    import dmd.astenums: LINK;

    if (type is null || funcptr is null)
        return false;

    return callViaLibffi(
        null,
        LINK.d,
        type,
        funcptr,
        NativeThis.fromRawContext(context),
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
        RefReturnMode.read,
    );
}

// A member call on a native class reference (ffi.md §34.12). The receiver is an
// opaque object pointer rather than marshalled struct bytes, and a virtual
// method dispatches through the object's vtable (see callNativeImpl).
public bool callNativeClassMember(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.mtype".TypeClass receiverType,
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
) {
    if (receiverType is null)
        return false;

    return callNativeImpl(
        function_,
        NativeThis(null, true, receiverType),
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
    );
}

private enum RefReturnMode {
    read,
    write,
}

private struct NativeThis {
    private imported!"dmd.mtype".TypeStruct structType;
    private bool enabled;
    private imported!"dmd.mtype".TypeClass classType;
    // A native delegate call's context pointer (ffi.md §35.8), passed raw as
    // the hidden leading argument with no marshalling and no type mapping.
    private const(void)* rawContext;
    private bool isRawContext;

    private static NativeThis fromRawContext(
        const(void)* context,
    ) @safe @nogc nothrow pure {
        NativeThis result;
        result.enabled = true;
        result.rawContext = context;
        result.isRawContext = true;
        return result;
    }

    private bool isClass() const @safe @nogc nothrow pure {
        return classType !is null;
    }

    // The receiver type as a plain Type, for ffiTypeFor / size(): the class type
    // for a class receiver, otherwise the struct type.
    private imported!"dmd.mtype".Type type() {
        import dmd.mtype: Type;

        return classType !is null
            ? cast(Type) classType
            : cast(Type) structType;
    }
}

private struct NativeCifCacheKey {
    private const(void)* function_;
    private bool hasReceiver;
    private RefReturnMode refReturnMode;
}

private struct CachedNativeCif {
    private imported!"quickbite.ffi.libffi".ffi_cif cif;
    private imported!"quickbite.ffi.libffi".ffi_type* returnFfi;
    private imported!"quickbite.ffi.libffi".ffi_type*[] argumentFfiTypes;
    private imported!"quickbite.ffi.libffi".ffi_type*[] abiArgumentFfiTypes;
}

private CachedNativeCif*[NativeCifCacheKey] _nativeCifCache;

private bool callNativeImpl(
    imported!"dmd.func".FuncDeclaration function_,
    NativeThis receiver,
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    in RefReturnMode refReturnMode = RefReturnMode.read,
) {
    import dmd.astenums: LINK, VarArg;
    import dmd.mangle: mangleExact;
    import dmd.mtype: TypeFunction;
    import std.string: fromStringz;

    if (!isSupportedNativeLinkage(function_._linkage))
        return false;

    auto type = cast(TypeFunction) function_.type;
    if (type is null)
        return false;

    // C `...` variadics go through ffi_prep_cif_var (§34.14); typesafe/K&R and
    // extern(D) variadics (TypeInfo/_argptr machinery) stay unsupported.
    if (type.parameterList.varargs == VarArg.typesafe ||
        type.parameterList.varargs == VarArg.KRvariadic)
        return false;
    if (type.parameterList.varargs == VarArg.variadic &&
        function_._linkage != LINK.c)
        return false;

    const symbol = resolveSymbol(function_, receiver, marshaller);
    if (symbol is null)
        throw new Exception(
            "Native symbol `" ~
            fromStringz(mangleExact(function_)).idup ~
            "` is not loaded",
        );

    return callViaLibffi(
        function_,
        function_._linkage,
        type,
        symbol,
        receiver,
        marshaller,
        argumentTypes,
        addressOfLocalArguments,
        refReturnMode,
    );
}

// Resolve the function pointer to call. A virtual method on a class receiver is
// read from the object's vtable at the DMD-computed slot so a base-typed handle
// dispatches to the runtime override (ffi.md §34.12); everything else (and
// non-virtual class methods) resolves by mangled symbol against the process.
private const(void)* resolveSymbol(
    imported!"dmd.func".FuncDeclaration function_,
    NativeThis receiver,
    NativeMarshaller marshaller,
) {
    import core.sys.posix.dlfcn: dlsym;
    version (DragonFlyBSD) import core.sys.dragonflybsd.dlfcn: RTLD_DEFAULT;
    version (FreeBSD) import core.sys.freebsd.dlfcn: RTLD_DEFAULT;
    version (linux) import core.sys.linux.dlfcn: RTLD_DEFAULT;
    version (NetBSD) import core.sys.netbsd.dlfcn: RTLD_DEFAULT;
    version (OpenBSD) import core.sys.openbsd.dlfcn: RTLD_DEFAULT;
    version (OSX) import core.sys.darwin.dlfcn: RTLD_DEFAULT;
    version (Solaris) import core.sys.solaris.dlfcn: RTLD_DEFAULT;
    import dmd.mangle: mangleExact;

    if (receiver.isClass && function_.vtblIndex >= 0) {
        auto objectPointer = marshaller.receiverObjectPointer;
        if (objectPointer is null)
            return null;
        // The object's first word is __vptr; the vtable slot at vtblIndex holds
        // the final overrider's function pointer.
        auto vtable = *cast(const(void*)**) objectPointer;
        return vtable[function_.vtblIndex];
    }

    return dlsym(RTLD_DEFAULT, mangleExact(function_));
}

// Resolve the address of a native `extern __gshared` global data symbol by its
// mangled name against the process (ffi.md §35.2a). Value-free: core is the
// backend-neutral bridge, so the caller reifies the bytes through its own
// marshaller.
public const(void)* resolveDataSymbol(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import core.sys.posix.dlfcn: dlsym;
    version (DragonFlyBSD) import core.sys.dragonflybsd.dlfcn: RTLD_DEFAULT;
    version (FreeBSD) import core.sys.freebsd.dlfcn: RTLD_DEFAULT;
    version (linux) import core.sys.linux.dlfcn: RTLD_DEFAULT;
    version (NetBSD) import core.sys.netbsd.dlfcn: RTLD_DEFAULT;
    version (OpenBSD) import core.sys.openbsd.dlfcn: RTLD_DEFAULT;
    version (OSX) import core.sys.darwin.dlfcn: RTLD_DEFAULT;
    version (Solaris) import core.sys.solaris.dlfcn: RTLD_DEFAULT;
    import dmd.mangle: mangleToBuffer;
    import dmd.common.outbuffer: OutBuffer;

    OutBuffer buf;
    mangleToBuffer(variable, buf);
    return dlsym(RTLD_DEFAULT, buf.peekChars);
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

    return linkage == LINK.c || linkage == LINK.d || linkage == LINK.cpp;
}

// Build a libffi call interface from the function signature, have the injected
// marshaller fill the raw ABI buffers, perform the call, and have the marshaller
// reify the result (and any out-parameter writeback). Returns false for any
// signature shape not yet modelled, preserving the caller's no-available-source
// diagnostic.
private bool callViaLibffi(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.astenums".LINK linkage,
    imported!"dmd.mtype".TypeFunction type,
    const void* symbol,
    NativeThis receiver,
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type[] argumentTypes,
    in bool[] addressOfLocalArguments,
    in RefReturnMode refReturnMode,
) {
    import quickbite.ffi.libffi:
        ffi_cif, ffi_type, ffi_type_pointer, ffi_status, ffi_prep_cif,
        ffi_prep_cif_var, ffi_call, ffi_closure_free, FFI_DEFAULT_ABI;
    import dmd.astenums: LINK, TY, VarArg;
    import dmd.mtype: Type;
    import dmd.typesem: size;

    const nargs = argumentTypes.length;
    const isVariadic = type.parameterList.varargs == VarArg.variadic;
    const fixedNargs = type.parameterList.parameters is null
        ? 0
        : type.parameterList.parameters.length;

    // Mutable Type: ffiTypeFor and dmd.typesem.size both need a non-const Type.
    auto returnType = type.next.toBasetype;
    const returnsRef = type.isRef;
    if (refReturnMode == RefReturnMode.write && !returnsRef)
        return false;
    auto returnFfi = returnsRef ? &ffi_type_pointer : ffiTypeFor(returnType);
    if (returnFfi is null)
        return false;

    auto parameterTypes = new Type[](nargs);
    auto argumentFfiTypes = new ffi_type*[](nargs);
    foreach (index; 0 .. nargs) {
        // Fixed parameters come from the signature; variadic-tail arguments are
        // typed by the call site (the signature does not carry them, §34.14).
        parameterTypes[index] = index < fixedNargs
            ? parameterType(type, index)
            : argumentTypes[index].toBasetype;
        argumentFfiTypes[index] = ffiArgumentTypeFor(parameterTypes[index]);
        if (argumentFfiTypes[index] is null)
            return false;
    }
    if (receiver.enabled && !receiver.isRawContext &&
        ffiTypeFor(receiver.type) is null)
        return false;

    // The marshaller owns representability (ffi.md §35.8): refuse before prep
    // any shape the type mapper claims but the backend cannot convert, so
    // mapper/marshaller drift degrades to the caller's no-available-source
    // diagnostic instead of a post-call assert.
    if (!canRepresentCall(
        marshaller,
        returnType,
        parameterTypes,
        receiver,
        addressOfLocalArguments,
        refReturnMode,
    ))
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

    // A variadic call needs ffi_prep_cif_var with the fixed/total split and
    // cannot share a non-variadic prep (§34.14). Non-variadic calls cache the
    // CIF and the ffi_type* arrays it points at by resolved callable (§35.1).
    ffi_cif cif;
    ffi_cif* cifPointer;
    auto preparedReturnFfi = returnFfi;
    auto preparedArgumentFfiTypes = argumentFfiTypes;
    if (isVariadic) {
        const prepStatus = ffi_prep_cif_var(
            &cif,
            FFI_DEFAULT_ABI,
            cast(uint) (hiddenNargs + fixedNargs),
            cast(uint) totalNargs,
            returnFfi,
            abiArgumentFfiTypes.ptr,
        );
        if (prepStatus != ffi_status.FFI_OK)
            return false;
        cifPointer = &cif;
    } else if (function_ is null) {
        const prepStatus = ffi_prep_cif(
            &cif,
            FFI_DEFAULT_ABI,
            cast(uint) totalNargs,
            returnFfi,
            abiArgumentFfiTypes.ptr,
        );
        if (prepStatus != ffi_status.FFI_OK)
            return false;
        cifPointer = &cif;
    } else {
        auto cachedCif = cachedNativeCif(
            function_,
            receiver,
            refReturnMode,
            returnFfi,
            argumentFfiTypes,
            abiArgumentFfiTypes,
        );
        if (cachedCif is null)
            return false;
        cifPointer = &cachedCif.cif;
        preparedReturnFfi = cachedCif.returnFfi;
        preparedArgumentFfiTypes = cachedCif.argumentFfiTypes;
    }

    // libffi fills in struct ffi_type sizes during prep; cross-check against
    // DMD's computed layout (ffi.md §24.3). ffiTypeFor only claims layouts
    // libffi reproduces exactly (ffi.md §35.7), so a mismatch is a mapper bug.
    if (!returnsRef && returnType.ty == TY.Tstruct)
        assert(preparedReturnFfi.size == cast(size_t) size(returnType),
            "libffi/DMD return struct layout mismatch (ffi.md §24.3)");
    foreach (index; 0 .. nargs)
        if (parameterTypes[index].ty == TY.Tstruct)
            assert(preparedArgumentFfiTypes[index].size ==
                cast(size_t) size(parameterTypes[index]),
                "libffi/DMD argument struct layout mismatch (ffi.md §24.3)");

    // Native buffers marshalled for pointer/slice arguments, kept alive across
    // the call below so the GC cannot reclaim them mid-call.
    const(char)*[] keepAlive;
    ubyte[][] keepAliveBuffers;
    ubyte[] receiverBuffer;
    ubyte[] receiverPointerBuffer;
    if (receiver.enabled) {
        receiverPointerBuffer = new ubyte[](ffi_type_pointer.size);
        if (receiver.isRawContext) {
            // A native delegate's context pointer crosses raw as the hidden
            // leading argument (ffi.md §35.8).
            *cast(const(void)**) receiverPointerBuffer.ptr =
                receiver.rawContext;
        } else if (receiver.isClass) {
            // A class reference is already a pointer to the object; pass it
            // straight through as hidden `this`, no struct-byte marshalling
            // (ffi.md §34.12).
            *cast(const(void)**) receiverPointerBuffer.ptr =
                marshaller.receiverObjectPointer;
        } else {
            receiverBuffer = new ubyte[](cast(size_t) size(receiver.type));
            marshaller.fillReceiver(
                receiverBuffer,
                receiver.type,
                hasOutPointer,
                keepAlive,
                keepAliveBuffers,
            );
            *cast(void**) receiverPointerBuffer.ptr = receiverBuffer.ptr;
        }
    }

    auto argumentBuffers = new ubyte[][](nargs);
    auto argumentValues = new void*[](nargs);
    auto outParameterCells = new ubyte[][](nargs);

    // Reverse-bridge state for delegate arguments (ffi.md §34.16): the libffi
    // closures to release after the call, and the contexts they route back
    // through, kept in a GC-scanned array so the trampoline's user data and its
    // CIF survive the call.
    void*[] closuresToFree;
    ClosureContext*[] closureContexts;
    scope(exit) foreach (closure; closuresToFree)
        ffi_closure_free(closure);

    foreach (index; 0 .. nargs) {
        const addressOfLocal =
            index < addressOfLocalArguments.length &&
            addressOfLocalArguments[index];
        if (auto address = marshaller.argumentAddress(
            index,
            parameterTypes[index],
        )) {
            argumentValues[index] = cast(void*) address;
        } else if (isDelegateParameter(parameterTypes[index])) {
            argumentBuffers[index] = new ubyte[](argumentFfiTypes[index].size);
            // Build a native trampoline whose calls re-enter the backend to run
            // the interpreted closure, and write the {context, funcptr} delegate
            // into the argument buffer.
            setupDelegateArgument(
                argumentBuffers[index],
                parameterTypes[index],
                index,
                marshaller,
                closuresToFree,
                closureContexts,
            );
            argumentValues[index] = argumentBuffers[index].ptr;
        } else if (isOutParameter(parameterTypes[index], addressOfLocal)) {
            argumentBuffers[index] = new ubyte[](argumentFfiTypes[index].size);
            // Allocate a host cell sized to the pointed-to type, marshal the
            // argument's current value into it (ffi.md §35.6), pass its
            // address as the out parameter, and reify the written value
            // through writeOutParameter after the call.
            auto pointedTo = parameterTypes[index].nextOf.toBasetype;
            outParameterCells[index] = new ubyte[](cast(size_t) size(pointedTo));
            marshaller.fillOutParameterCell(
                outParameterCells[index],
                pointedTo,
                index,
                hasOutPointer,
                keepAlive,
                keepAliveBuffers,
            );
            *cast(void**) argumentBuffers[index].ptr =
                outParameterCells[index].ptr;
            argumentValues[index] = argumentBuffers[index].ptr;
        } else {
            argumentBuffers[index] = new ubyte[](argumentFfiTypes[index].size);
            marshaller.fillArgument(
                argumentBuffers[index],
                parameterTypes[index],
                index,
                hasOutPointer,
                keepAlive,
                keepAliveBuffers,
            );
            argumentValues[index] = argumentBuffers[index].ptr;
        }
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
    auto returnSlot = returnsRef ? null : marshaller.resultAddress(returnType);
    auto returnBuffer = returnSlot is null ? new ubyte[](returnSize) : null;
    auto returnAddress = returnSlot is null ? returnBuffer.ptr : returnSlot;

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
            cifPointer,
            cast(CFunction) symbol,
            returnAddress,
            abiArgumentValues.ptr,
        );
    } catch (Exception exception) {
        throw nativeCallExceptionFrom(exception);
    }

    foreach (index; 0 .. nargs) {
        if (outParameterCells[index] is null)
            continue;
        marshaller.writeOutParameter(
            index,
            parameterTypes[index].nextOf.toBasetype,
            outParameterCells[index],
        );
    }

    if (returnsRef) {
        auto resultAddress = *cast(void**) returnBuffer.ptr;
        if (resultAddress is null)
            throw new Exception("Native ref return has null address.");
        if (refReturnMode == RefReturnMode.write) {
            marshaller.writeRefResult(
                returnType,
                resultAddress,
                hasOutPointer,
                keepAlive,
                keepAliveBuffers,
            );
        } else {
            marshaller.readResult(
                returnType,
                nativeBytes(resultAddress, cast(size_t) size(returnType)),
            );
        }
    } else {
        if (returnSlot is null)
            marshaller.readResult(returnType, returnBuffer);
    }
    return true;
}

private CachedNativeCif* cachedNativeCif(
    imported!"dmd.func".FuncDeclaration function_,
    NativeThis receiver,
    in RefReturnMode refReturnMode,
    imported!"quickbite.ffi.libffi".ffi_type* returnFfi,
    imported!"quickbite.ffi.libffi".ffi_type*[] argumentFfiTypes,
    imported!"quickbite.ffi.libffi".ffi_type*[] abiArgumentFfiTypes,
) {
    import quickbite.ffi.libffi: ffi_prep_cif, ffi_status, FFI_DEFAULT_ABI;

    const key = NativeCifCacheKey(
        cast(const(void)*) function_,
        receiver.enabled,
        refReturnMode,
    );
    if (auto existing = key in _nativeCifCache)
        return *existing;

    auto result = new CachedNativeCif;
    result.returnFfi = returnFfi;
    result.argumentFfiTypes = argumentFfiTypes.dup;
    result.abiArgumentFfiTypes = abiArgumentFfiTypes.dup;

    const prepStatus = ffi_prep_cif(
        &result.cif,
        FFI_DEFAULT_ABI,
        cast(uint) result.abiArgumentFfiTypes.length,
        result.returnFfi,
        result.abiArgumentFfiTypes.ptr,
    );
    if (prepStatus != ffi_status.FFI_OK)
        return null;

    _nativeCifCache[key] = result;
    return result;
}

private const(ubyte)[] nativeBytes(
    in void* address,
    in size_t length,
) @trusted {
    return (cast(const(ubyte)*) address)[0 .. length];
}

// Ask the marshaller whether every value crossing the call is representable
// in its direction (ffi.md §35.8): the return reifies fromNative; an argument
// marshals toNative, except an out slot, whose pointed-to value crosses both
// ways (input fill, writeback), and a delegate argument, which crosses through
// the §34.16 closure bridge rather than the marshalling switches. A class
// receiver and a raw delegate context cross as opaque pointers, unmarshalled.
private bool canRepresentCall(
    NativeMarshaller marshaller,
    imported!"dmd.mtype".Type returnType,
    imported!"dmd.mtype".Type[] parameterTypes,
    NativeThis receiver,
    in bool[] addressOfLocalArguments,
    in RefReturnMode refReturnMode,
) {
    with (NativeMarshaller.Direction) {
        const returnDirection = refReturnMode == RefReturnMode.write
            ? toNative
            : fromNative;
        if (!marshaller.canRepresent(returnType, returnDirection))
            return false;

        foreach (index, parameter; parameterTypes) {
            if (isDelegateParameter(parameter))
                continue;

            const addressOfLocal =
                index < addressOfLocalArguments.length &&
                addressOfLocalArguments[index];
            if (isOutParameter(parameter, addressOfLocal)) {
                // An out cell crosses both ways as an opaque native buffer; the
                // marshaller owns whether it can (ffi.md §35.10), which lets a
                // union out-cell round-trip even though a by-value union stays
                // refused (§35.7). Do not query canRepresent both directions.
                if (!marshaller.canRepresentOutCell(parameter.nextOf.toBasetype))
                    return false;
            } else if (!marshaller.canRepresent(parameter, toNative))
                return false;
        }

        if (receiver.enabled && !receiver.isRawContext && !receiver.isClass &&
            !marshaller.canRepresent(receiver.type, toNative))
            return false;
    }

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

// The reverse-bridge routing behind one libffi closure (ffi.md §34.16): which
// interpreted delegate argument to invoke, the call's types, and the return
// width to write back. Held in a GC-scanned array across the call so the
// trampoline can dereference it and so the CIF and its argument-type array (both
// read by libffi when native code invokes the closure) survive the call.
private struct ClosureContext {
    NativeMarshaller marshaller;
    size_t argumentIndex;
    imported!"dmd.mtype".Type returnType;
    imported!"dmd.mtype".Type[] parameterTypes;   // source order
    size_t returnSize;
    imported!"quickbite.ffi.libffi".ffi_cif* cif;
    imported!"quickbite.ffi.libffi".ffi_type*[] argumentFfiTypes;
}

private bool isDelegateParameter(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.ty == TY.Tdelegate;
}

// Prepare a libffi closure for an interpreted delegate argument and write the
// resulting {context, funcptr} delegate into `buffer`. Native code invokes the
// funcptr as `Ret(context, reverse(explicit args))` — the extern(D) delegate
// convention confirmed by disassembly — so the trampoline CIF leads with the
// context pointer and the explicit parameter types follow in reverse order.
private void setupDelegateArgument(
    ubyte[] buffer,
    imported!"dmd.mtype".Type delegateType,
    in size_t argumentIndex,
    NativeMarshaller marshaller,
    ref void*[] closuresToFree,
    ref ClosureContext*[] closureContexts,
) {
    import quickbite.ffi.libffi:
        ffi_cif, ffi_type, ffi_type_pointer, ffi_prep_cif, ffi_closure,
        ffi_closure_alloc, ffi_prep_closure_loc, FFI_DEFAULT_ABI;
    import dmd.astenums: LINK;
    import dmd.mtype: Type, TypeFunction;

    auto functionType = cast(TypeFunction) delegateType.nextOf;
    auto returnType = functionType.next.toBasetype;
    auto returnFfi = ffiTypeFor(returnType);

    const np = functionType.parameterList.parameters is null
        ? 0
        : functionType.parameterList.parameters.length;
    auto parameterTypes = new Type[](np);
    foreach (index; 0 .. np)
        parameterTypes[index] =
            (*functionType.parameterList.parameters)[index].type.toBasetype;

    // [context pointer] ++ reverse(explicit ffi types)
    auto argumentFfiTypes = new ffi_type*[](1 + np);
    argumentFfiTypes[0] = &ffi_type_pointer;
    foreach (abiIndex; 0 .. np)
        argumentFfiTypes[1 + abiIndex] =
            ffiArgumentTypeFor(parameterTypes[abiSourceIndex(LINK.d, np, abiIndex)]);

    auto cif = new ffi_cif;
    ffi_prep_cif(
        cif,
        FFI_DEFAULT_ABI,
        cast(uint) (1 + np),
        returnFfi,
        argumentFfiTypes.ptr,
    );

    auto context = new ClosureContext;
    context.marshaller = marshaller;
    context.argumentIndex = argumentIndex;
    context.returnType = returnType;
    context.parameterTypes = parameterTypes;
    context.returnSize = returnFfi.size < 8 ? 8 : returnFfi.size;
    context.cif = cif;
    context.argumentFfiTypes = argumentFfiTypes;
    closureContexts ~= context;

    void* code;
    auto writable = ffi_closure_alloc(ffi_closure.sizeof, &code);
    ffi_prep_closure_loc(
        cast(ffi_closure*) writable,
        cif,
        &closureTrampoline,
        cast(void*) context,
        code,
    );
    closuresToFree ~= writable;

    // The D delegate: context at offset 0, funcptr at offset 8.
    *cast(void**) buffer.ptr = cast(void*) context;
    *cast(void**) (buffer.ptr + (void*).sizeof) = code;
}

// Invoked by native code through the libffi closure. `args[0]` is the delegate
// context (ignored — the backend resolves the closure by argument index);
// `args[1 ..]` are the explicit arguments in ABI (reversed) order, restored to
// source order before the backend materializes them.
private extern(C) void closureTrampoline(
    imported!"quickbite.ffi.libffi".ffi_cif* cif,
    void* ret,
    void** args,
    void* userData,
) {
    import dmd.astenums: LINK;

    auto context = cast(ClosureContext*) userData;
    const np = context.parameterTypes.length;
    auto sourceArguments = new void*[](np);
    foreach (abiIndex; 0 .. np)
        sourceArguments[abiSourceIndex(LINK.d, np, abiIndex)] =
            args[1 + abiIndex];

    context.marshaller.invokeClosure(
        context.argumentIndex,
        context.returnType,
        context.parameterTypes,
        sourceArguments,
        (cast(ubyte*) ret)[0 .. context.returnSize],
    );
}

private imported!"quickbite.ffi.libffi".ffi_type* ffiArgumentTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    if (type.ty == TY.Tarray)
        return isSupportedFfiSlice(type) ? ffiSliceType : null;

    return ffiTypeFor(type);
}

// Map a DMD basetype to the matching libffi ffi_type, or null if unmodelled.
private imported!"quickbite.ffi.libffi".ffi_type* ffiTypeFor(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.ffi.libffi;
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct, TypeSArray;

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
        // A class reference is a single pointer to the object at the ABI
        // (ffi.md §11.3/§34.12); it crosses as an opaque native handle.
        case TY.Tclass:                return &ffi_type_pointer;
        case TY.Tarray:
            return isSupportedFfiSlice(type) ? ffiSliceType : null;
        case TY.Tstruct:               return ffiStructType(cast(TypeStruct) type);
        case TY.Tsarray:               return ffiStaticArrayType(cast(TypeSArray) type);
        // A delegate crosses as its two-pointer {context, funcptr} struct
        // (ffi.md §34.16); the interpreted closure behind it is invoked through
        // a libffi closure trampoline.
        case TY.Tdelegate:             return ffiDelegateType;
        default:                       return null;
    }
}

// A D delegate is a two-pointer struct {void* context, void* funcptr} (context
// at offset 0, funcptr at offset 8), classified as two INTEGER eightbytes.
private imported!"quickbite.ffi.libffi".ffi_type* ffiDelegateType() {
    import quickbite.ffi.libffi: ffi_type, ffi_type_pointer, FFI_TYPE_STRUCT;

    auto elements = new ffi_type*[](3);
    elements[0] = &ffi_type_pointer;
    elements[1] = &ffi_type_pointer;
    elements[2] = null;

    auto result = new ffi_type;
    result.type = FFI_TYPE_STRUCT;
    result.elements = elements.ptr;
    return result;
}

// Synthesize a STRUCT ffi_type by walking the struct's fields; libffi computes
// the laid-out size and alignment during ffi_prep_cif. A union is modelled
// separately (ffiUnionType); a layout libffi's sequential natural walk cannot
// reproduce (packed or over-aligned `align`, anonymous unions) returns null so
// the caller takes the graceful no-available-source path (ffi.md §35.7).
private imported!"quickbite.ffi.libffi".ffi_type* ffiStructType(
    imported!"dmd.mtype".TypeStruct type,
) {
    import quickbite.ffi.libffi: ffi_type, FFI_TYPE_STRUCT;
    import dmd.typesem: size;

    auto sym = type.sym;
    if (sym.isUnionDeclaration !is null)
        return ffiUnionType(type);

    auto elements = new ffi_type*[](sym.fields.length + 1);
    size_t naturalOffset;
    uint naturalAlignment = 1;
    foreach (index; 0 .. sym.fields.length) {
        auto field = sym.fields[index];
        auto fieldType = field.type.toBasetype;
        elements[index] = ffiTypeFor(fieldType);
        if (elements[index] is null)
            return null;

        // libffi places each field sequentially at its natural alignment; a
        // DMD offset that disagrees is a layout the element walk misdescribes.
        const fieldAlignment = fieldType.alignsize;
        naturalOffset = alignUp(naturalOffset, fieldAlignment);
        if (naturalOffset != field.offset)
            return null;
        naturalOffset += cast(size_t) size(fieldType);
        if (fieldAlignment > naturalAlignment)
            naturalAlignment = fieldAlignment;
    }
    elements[$ - 1] = null;

    // Explicit `align` can change the struct's alignment or total size without
    // moving any field; both must match the natural layout libffi computes.
    if (sym.fields.length != 0 &&
        (sym.alignsize != naturalAlignment ||
         alignUp(naturalOffset, naturalAlignment) != sym.structsize))
        return null;

    auto result = new ffi_type;
    result.type = FFI_TYPE_STRUCT;
    result.elements = elements.ptr;
    return result;
}

// A fixed-size array has no native libffi type; the ABI classifies it as a
// struct of `dim` identical elements (ffi.md §34.3.1). Recurse for the element
// so any supported element kind (scalar, pointer, nested struct/array) crosses,
// returning null when the element is unmodelled to keep the graceful
// no-available-source refusal. The elements are naturally aligned and
// sequential — exactly D's static-array layout — so ffi_prep_cif computes the
// same size DMD did without any offset fix-up.
private imported!"quickbite.ffi.libffi".ffi_type* ffiStaticArrayType(
    imported!"dmd.mtype".TypeSArray type,
) {
    import quickbite.ffi.libffi: ffi_type, FFI_TYPE_STRUCT;

    auto element = ffiTypeFor(type.next.toBasetype);
    if (element is null)
        return null;

    const dim = cast(size_t) type.dim.toInteger;
    auto elements = new ffi_type*[](dim + 1);
    foreach (index; 0 .. dim)
        elements[index] = element;
    elements[dim] = null;

    auto result = new ffi_type;
    result.type = FFI_TYPE_STRUCT;
    result.elements = elements.ptr;
    return result;
}

private size_t alignUp(
    in size_t offset,
    in uint alignment,
) @safe @nogc nothrow pure {
    return (offset + alignment - 1) & ~(cast(size_t) alignment - 1);
}

// libffi cannot express overlapped members (ffi.md §35.7); the accepted
// convention is a struct containing only the most-aligned member, with size
// and alignment forced to DMD's layout — ffi_prep_cif leaves them alone
// because it only initializes aggregates whose size is still 0. Members must
// map to fixed-size ffi types (scalars, pointers) so ABI classification never
// walks an unprepped aggregate; anything else returns null for the graceful
// no-available-source path.
private imported!"quickbite.ffi.libffi".ffi_type* ffiUnionType(
    imported!"dmd.mtype".TypeStruct type,
) {
    import quickbite.ffi.libffi: ffi_type, FFI_TYPE_STRUCT;

    auto sym = type.sym;
    if (sym.fields.length == 0)
        return null;

    ffi_type* dominant;
    uint dominantAlignment;
    foreach (field; sym.fields) {
        auto fieldType = field.type.toBasetype;
        auto fieldFfi = ffiTypeFor(fieldType);
        if (fieldFfi is null || fieldFfi.size == 0)
            return null;

        const fieldAlignment = fieldType.alignsize;
        if (dominant is null || fieldAlignment > dominantAlignment) {
            dominant = fieldFfi;
            dominantAlignment = fieldAlignment;
        }
    }

    auto elements = new ffi_type*[](2);
    elements[0] = dominant;
    elements[1] = null;

    auto result = new ffi_type;
    result.type = FFI_TYPE_STRUCT;
    result.size = sym.structsize;
    result.alignment = cast(ushort) sym.alignsize;
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

    return type.ty == TY.Tarray && isScalarFfiType(type.nextOf.toBasetype);
}

// A dynamic slice crosses when its element type is itself FFI-representable —
// a scalar as before, or a by-value struct/static array that ffiTypeFor maps
// (ffi.md §34.3.1 item 0). The slice ABI descriptor {length, ptr} is
// element-agnostic; only the element gate widens.
public bool isSupportedFfiSlice(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.ty == TY.Tarray && ffiTypeFor(type.nextOf.toBasetype) !is null;
}

// A DMD basetype that maps to a single libffi scalar ffi_type (not a pointer,
// struct, array, or void).
private bool isScalarFfiType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

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

// Whether a parameter is an out slot the native call writes through. A
// pointer-to-pointer (e.g. strtol's `char** endptr`) is always one by type; a
// single-level pointer-to-scalar is one only when the call site passed `&local`
// (ffi.md §34.8) — a bare pointer value stays an in-pointer.
private bool isOutParameter(
    imported!"dmd.mtype".Type type,
    in bool addressOfLocal,
) {
    return isOutPointer(type) ||
        (addressOfLocal && (isOutScalarPointer(type) || isOutStructPointer(type)));
}

// A single-level pointer to a struct passed as `&local` (e.g. fstat's
// `stat_t*`): an out cell the callee writes and the backend reifies back
// into the local (ffi.md §34.8).
private bool isOutStructPointer(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.ty == TY.Tpointer && type.nextOf.toBasetype.ty == TY.Tstruct;
}

// A pointer-to-pointer parameter (e.g. strtol's `char** endptr`) is an out
// slot rather than an in value.
private bool isOutPointer(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.ty == TY.Tpointer && type.nextOf.toBasetype.ty == TY.Tpointer;
}

// A single-level pointer to a scalar (e.g. `int*`, `double*`), the shape a
// scalar out-parameter writes through (ffi.md §34.8).
private bool isOutScalarPointer(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.ty == TY.Tpointer && isScalarFfiType(type.nextOf.toBasetype);
}

private imported!"dmd.mtype".Type parameterType(
    imported!"dmd.mtype".TypeFunction functionType,
    in size_t index,
) {
    return (*functionType.parameterList.parameters)[index].type.toBasetype;
}

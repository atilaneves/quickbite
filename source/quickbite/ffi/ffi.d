module quickbite.ffi.ffi;

private:


public enum CompilerAbi {
    dmd,
    ldc,
}

// ABI provenance belongs to the address-only bridge: loading an image records
// the ABI of the code at its symbols, and calls recover that provenance from
// their resolved address. Neither operation depends on a backend value type.
public struct DependencyImage {
    public string path;
    public CompilerAbi compilerAbi;
}

version (LDC)
    private enum CompilerAbi hostCompilerAbi = CompilerAbi.ldc;
else
    private enum CompilerAbi hostCompilerAbi = CompilerAbi.dmd;

private CompilerAbi[string] _dependencyImageAbis;
private CompilerAbi[const(void)*] _closureAbis;

private struct DependencyImageSegment {
    public size_t begin;
    public size_t end;
    public void* imageBase;
    public CompilerAbi compilerAbi;
}

private DependencyImageSegment[] _dependencyImageSegments;
private bool _dependencyImageNeedsPathLookup;


public void loadDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages) {
        verifyDependencyImage(dependencyImage);
        loadDependencyImage(
            dependencyImage,
            compilerAbiFromImage(dependencyImage),
        );
    }
}

public void loadDependencyImages(
    in DependencyImage[] dependencyImages,
) {
    foreach (dependencyImage; dependencyImages) {
        verifyDependencyImage(dependencyImage.path);
        loadDependencyImage(dependencyImage.path, dependencyImage.compilerAbi);
    }
}

public void verifyDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages)
        verifyDependencyImage(dependencyImage);
}

public void registerClosureAbi(
    in void* address,
    in CompilerAbi compilerAbi,
) {
    _closureAbis[address] = compilerAbi;
}

public void unregisterClosureAbi(in void* address) {
    _closureAbis.remove(address);
}

public CompilerAbi compilerAbiFor(in void* symbol) {
    if (auto compilerAbi = cast(const(void)*) symbol in _closureAbis)
        return *compilerAbi;

    const address = cast(size_t) symbol;
    foreach (segment; _dependencyImageSegments)
        if (address >= segment.begin && address < segment.end)
            return segment.compilerAbi;

    if (!_dependencyImageNeedsPathLookup)
        return hostCompilerAbi;

    import core.sys.posix.dlfcn: dladdr, Dl_info;
    import std.path: absolutePath, buildNormalizedPath;
    import std.string: fromStringz;

    Dl_info info;
    if (dladdr(symbol, &info) == 0 || info.dli_fname is null)
        return hostCompilerAbi;

    const imagePath = info.dli_fname.fromStringz.idup
        .absolutePath
        .buildNormalizedPath;
    if (auto compilerAbi = imagePath in _dependencyImageAbis)
        return *compilerAbi;
    return hostCompilerAbi;
}

private void verifyDependencyImage(in string dependencyImage) {
    import std.string: endsWith;

    if (!dependencyImage.endsWith(".so"))
        throw new Exception(
            "dependency image must be a loadable shared library (.so): "
            ~ dependencyImage,
        );
}

private CompilerAbi compilerAbiFromImage(in string dependencyImage) {
    import std.algorithm.searching: canFind;
    import std.file: read;

    const bytes = cast(const(ubyte)[]) dependencyImage.read;
    const comment = elfCommentSection(bytes);
    const saysDmd = comment.canFind(cast(const(ubyte)[]) "DMD v");
    const saysLdc = comment.canFind(cast(const(ubyte)[]) "ldc version ");
    if (saysDmd == saysLdc)
        throw new Exception(
            "dependency image compiler ABI is ambiguous; supply explicit "
            ~ "compiler provenance: " ~ dependencyImage,
        );
    return saysDmd ? CompilerAbi.dmd : CompilerAbi.ldc;
}

private const(ubyte)[] elfCommentSection(in ubyte[] bytes) {
    import std.algorithm.searching: countUntil;

    if (bytes.length < 64 || bytes[0 .. 4] != [0x7f, 'E', 'L', 'F'])
        throw new Exception("dependency image is not a supported ELF image");
    if (bytes[4] != 2 || bytes[5] != 1)
        throw new Exception("dependency image is not little-endian ELF64");

    const sectionOffset = readElfWord!ulong(bytes, 40);
    const sectionEntrySize = readElfWord!ushort(bytes, 58);
    const sectionCount = readElfWord!ushort(bytes, 60);
    const namesIndex = readElfWord!ushort(bytes, 62);
    if (sectionEntrySize < 64 || namesIndex >= sectionCount)
        throw new Exception("dependency image has an invalid ELF section table");

    const namesHeader = sectionOffset + namesIndex * sectionEntrySize;
    const namesOffset = readElfWord!ulong(bytes, namesHeader + 24);
    const namesSize = readElfWord!ulong(bytes, namesHeader + 32);
    const names = checkedElfSlice(bytes, namesOffset, namesSize);

    foreach (index; 0 .. sectionCount) {
        const header = sectionOffset + index * sectionEntrySize;
        const nameOffset = readElfWord!uint(bytes, header);
        if (nameOffset >= names.length)
            throw new Exception("dependency image has an invalid ELF section name");
        const nameTail = names[nameOffset .. $];
        const nameLength = nameTail.countUntil(0);
        if (nameLength < 0)
            throw new Exception("dependency image has an unterminated ELF section name");
        const name = cast(const(char)[]) nameTail[0 .. nameLength];
        if (name == ".comment") {
            const offset = readElfWord!ulong(bytes, header + 24);
            const size = readElfWord!ulong(bytes, header + 32);
            return checkedElfSlice(bytes, offset, size);
        }
    }
    throw new Exception("dependency image has no compiler metadata");
}

private T readElfWord(T)(in ubyte[] bytes, in size_t offset) {
    if (offset > bytes.length || T.sizeof > bytes.length - offset)
        throw new Exception("dependency image has a truncated ELF section table");
    T result;
    foreach (index; 0 .. T.sizeof)
        result |= cast(T) bytes[offset + index] << (index * 8);
    return result;
}

private const(ubyte)[] checkedElfSlice(
    in ubyte[] bytes,
    in size_t offset,
    in size_t length,
) {
    if (offset > bytes.length || length > bytes.length - offset)
        throw new Exception("dependency image has a truncated ELF section");
    return bytes[offset .. offset + length];
}

private void loadDependencyImage(
    in string dependencyImage,
    in CompilerAbi compilerAbi,
) {
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

    import std.path: absolutePath, buildNormalizedPath;

    _dependencyImageAbis[dependencyImage.absolutePath.buildNormalizedPath] =
        compilerAbi;
    if (!registerDependencyImageSegments(dependencyImage, compilerAbi))
        _dependencyImageNeedsPathLookup = true;
}

// Record the load segments once, while the image path is already part of image
// setup. Calls can then derive ABI provenance from the resolved code address
// without rediscovering and allocating its filesystem path every time.
private bool registerDependencyImageSegments(
    in string dependencyImage,
    in CompilerAbi compilerAbi,
) {
    version (linux) {
        import core.internal.elf.dl: SharedObject, SharedObjects;
        import core.sys.elf: PT_LOAD;
        import std.path: absolutePath, buildNormalizedPath;

        const expectedPath = dependencyImage.absolutePath.buildNormalizedPath;
        SharedObject matched;
        bool found;
        foreach (object; SharedObjects) {
            if (object.name != dependencyImage &&
                object.name != expectedPath)
                continue;
            matched = object;
            found = true;
            break;
        }
        if (found) {
            bool alreadyRegistered;
            foreach (ref segment; _dependencyImageSegments)
                if (segment.imageBase == matched.baseAddress) {
                    segment.compilerAbi = compilerAbi;
                    alreadyRegistered = true;
                }
            if (alreadyRegistered)
                return true;

            const base = cast(size_t) matched.baseAddress;
            foreach (ref header;
                matched.info.dlpi_phdr[0 .. matched.info.dlpi_phnum]
            ) {
                if (header.p_type != PT_LOAD || header.p_memsz == 0)
                    continue;
                _dependencyImageSegments ~= DependencyImageSegment(
                    base + header.p_vaddr,
                    base + header.p_vaddr + header.p_memsz,
                    matched.baseAddress,
                    compilerAbi,
                );
            }
            return true;
        }
    }
    return false;
}


public struct Callable {
    public void* address;
    public imported!"dmd.mtype".TypeFunction signature;
    public CompilerAbi compilerAbi;
    public imported!"dmd.func".FuncDeclaration declaration;
}


// Resolve a native declaration without involving a backend value representation.
// Class virtual dispatch reads the final overrider from the receiver object's
// vtable, so provenance must be captured from that resolved code address rather
// than from the base declaration's image.
public Callable resolveCallable(
    imported!"dmd.func".FuncDeclaration declaration,
    in bool virtualDispatch,
    const(void)* receiverObject = null,
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
    import dmd.mtype: TypeFunction;

    Callable result;
    result.declaration = declaration;
    result.signature = cast(TypeFunction) declaration.type;
    if (virtualDispatch && declaration.vtblIndex >= 0) {
        if (receiverObject is null)
            return result;
        // The object's first word is __vptr; the DMD-computed slot names the
        // final overrider, whose image determines the compiler ABI.
        const vtable = *cast(const(void*)**) receiverObject;
        result.address = cast(void*) vtable[declaration.vtblIndex];
    } else
        result.address = dlsym(RTLD_DEFAULT, mangleExact(declaration));
    if (result.address !is null)
        result.compilerAbi = compilerAbiFor(result.address);
    return result;
}


// Resolve an `extern __gshared` global by its mangled process symbol. The
// caller owns reading or writing its bytes through the returned address.
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
    import dmd.common.outbuffer: OutBuffer;
    import dmd.mangle: mangleToBuffer;

    OutBuffer buffer;
    mangleToBuffer(variable, buffer);
    return dlsym(RTLD_DEFAULT, buffer.peekChars);
}


public struct TypedAddress {
    public imported!"dmd.mtype".Type type;
    public void* address;
}


public struct DVariadicMetadata {
    public TypedAddress value;
}


// CIF construction metadata shared with backend-owned callback plumbing.
// It exposes no callback identity, lifetime, trampoline, or value conversion.
public imported!"quickbite.ffi.libffi".ffi_type* libffiTypeFor(
    imported!"dmd.mtype".Type type,
) {
    return ffiTypeFor(type).type;
}


private enum PhysicalReturn {
    value,
    reference,
    cppNonPod,
    cppConstructor,
}

private struct PhysicalArgument {
    private imported!"dmd.mtype".Type type;
    private void* address;
    private size_t sourceIndex = size_t.max;
    private bool pointer;
}


private struct PhysicalCall {
    private imported!"dmd.mtype".Type returnType;
    private PhysicalReturn returnPolicy;
    private size_t cFixedArgumentCount;
    private bool cVariadic;
    private size_t receiverArgumentIndex = size_t.max;
    private size_t _argumentCount;
    private size_t _pointerCellCount;
    private void* _storage;
    private PhysicalArgument _singleArgument;
    private void* _singlePointerCell;
    private imported!"quickbite.ffi.libffi".ffi_type* _singleArgumentType;
    private void* _singleArgumentAddress;
    private FfiType _singleArgumentMetadata;

    private void initialize(
        in size_t argumentCount,
        in size_t pointerCellCount,
    ) {
        import core.memory: GC;

        _argumentCount = argumentCount;
        _pointerCellCount = pointerCellCount;
        assert(argumentCount > 1 || pointerCellCount <= 1);
        if (argumentCount > 1)
            _storage = GC.calloc(storageByteLength(
                argumentCount,
                pointerCellCount,
            ));
    }

    // @trusted: `_storage` is either null or the base pointer returned by
    // this value's own `GC.calloc` call. `call` releases the uncopied staging
    // value only after the synchronous ABI call and result copy finish.
    private void release() pure nothrow @nogc @trusted {
        import core.memory: GC;

        auto storage = _storage;
        _storage = null;
        GC.free(storage);
    }

    // `_storage` is one exact allocation containing the five aligned staging
    // ranges below. Each cast exposes only the range whose size was included
    // in `storageByteLength`.
    private PhysicalArgument[] arguments() @trusted {
        if (_argumentCount == 0)
            return null;
        if (_argumentCount == 1)
            return (&_singleArgument)[0 .. 1];
        return (cast(PhysicalArgument*) _storage)[0 .. _argumentCount];
    }

    private void*[] pointerCells() @trusted {
        if (_pointerCellCount == 0)
            return null;
        if (_argumentCount == 1)
            return (&_singlePointerCell)[0 .. 1];
        return (cast(void**) (
            cast(ubyte*) _storage + pointerCellsOffset(_argumentCount)
        ))[0 .. _pointerCellCount];
    }

    private imported!"quickbite.ffi.libffi".ffi_type*[] argumentTypes()
    @trusted {
        alias ffi_type = imported!"quickbite.ffi.libffi".ffi_type;

        if (_argumentCount == 0)
            return null;
        if (_argumentCount == 1)
            return (&_singleArgumentType)[0 .. 1];
        return (cast(ffi_type**) (
            cast(ubyte*) _storage + argumentTypesOffset(
                _argumentCount,
                _pointerCellCount,
            )
        ))[0 .. _argumentCount];
    }

    private void*[] argumentAddresses() @trusted {
        if (_argumentCount == 0)
            return null;
        if (_argumentCount == 1)
            return (&_singleArgumentAddress)[0 .. 1];
        return (cast(void**) (
            cast(ubyte*) _storage + argumentAddressesOffset(
                _argumentCount,
                _pointerCellCount,
            )
        ))[0 .. _argumentCount];
    }

    private FfiType[] argumentMetadata() @trusted {
        if (_argumentCount == 0)
            return null;
        if (_argumentCount == 1)
            return (&_singleArgumentMetadata)[0 .. 1];
        return (cast(FfiType*) (
            cast(ubyte*) _storage + argumentMetadataOffset(
                _argumentCount,
                _pointerCellCount,
            )
        ))[0 .. _argumentCount];
    }

    private static size_t storageByteLength(
        in size_t argumentCount,
        in size_t pointerCellCount,
    ) @safe @nogc nothrow pure {
        return argumentMetadataOffset(argumentCount, pointerCellCount) +
            FfiType.sizeof * argumentCount;
    }

    private static size_t pointerCellsOffset(
        in size_t argumentCount,
    ) @safe @nogc nothrow pure {
        return alignedTo(
            PhysicalArgument.sizeof * argumentCount,
            (void*).alignof,
        );
    }

    private static size_t argumentTypesOffset(
        in size_t argumentCount,
        in size_t pointerCellCount,
    ) @safe @nogc nothrow pure {
        alias ffi_type = imported!"quickbite.ffi.libffi".ffi_type;

        return alignedTo(
            pointerCellsOffset(argumentCount) +
                (void*).sizeof * pointerCellCount,
            (ffi_type*).alignof,
        );
    }

    private static size_t argumentAddressesOffset(
        in size_t argumentCount,
        in size_t pointerCellCount,
    ) @safe @nogc nothrow pure {
        alias ffi_type = imported!"quickbite.ffi.libffi".ffi_type;

        return alignedTo(
            argumentTypesOffset(argumentCount, pointerCellCount) +
                (ffi_type*).sizeof * argumentCount,
            (void*).alignof,
        );
    }

    private static size_t argumentMetadataOffset(
        in size_t argumentCount,
        in size_t pointerCellCount,
    ) @safe @nogc nothrow pure {
        return alignedTo(
            argumentAddressesOffset(argumentCount, pointerCellCount) +
                (void*).sizeof * argumentCount,
            FfiType.alignof,
        );
    }
}


public bool call(
    Callable callable,
    TypedAddress[] arguments,
    TypedAddress result,
    TypedAddress* receiver = null,
    DVariadicMetadata* variadicMetadata = null,
) {
    import quickbite.ffi.libffi:
        ffi_arg, ffi_cif, ffi_call, ffi_prep_cif, ffi_prep_cif_var,
        ffi_status, ffi_type, ffi_type_pointer, ffi_type_void,
        FFI_DEFAULT_ABI;
    import dmd.astenums: TY;

    PhysicalCall physical;
    scope(exit) physical.release;
    if (!preparePhysicalCall(
        callable,
        arguments,
        result,
        receiver,
        variadicMetadata,
        physical,
    ))
        return false;

    if (requiresSysVTransport(callable, physical))
        return callSysV(callable, physical, result);

    auto resultMetadata = physical.returnPolicy == PhysicalReturn.cppConstructor
        ? FfiType(&ffi_type_void)
        : physical.returnPolicy == PhysicalReturn.reference
        ? FfiType(&ffi_type_pointer)
        : physical.returnPolicy == PhysicalReturn.cppNonPod
            ? cppNonPodReturnFfiType(physical.returnType)
            : ffiTypeFor(physical.returnType, true);
    if (resultMetadata.type is null)
        return false;

    const resultTy = semanticStorageType(physical.returnType).ty;
    const returnsVoid =
        physical.returnPolicy == PhysicalReturn.cppConstructor ||
        resultTy == TY.Tvoid ||
        resultTy == TY.Tnoreturn;
    const numAbiArguments = physical.arguments.length;
    auto argumentTypes = physical.argumentTypes;
    auto argumentAddresses = physical.argumentAddresses;
    auto argumentMetadata = physical.argumentMetadata;
    foreach (index, argument; physical.arguments) {
        argumentMetadata[index] = argument.pointer
            ? FfiType(&ffi_type_pointer)
            : ffiTypeFor(argument.type);
        argumentTypes[index] = argumentMetadata[index].type;
        if (argumentTypes[index] is null)
            return false;
        argumentAddresses[index] = argument.address;
    }

    ffi_cif cif;
    const prepStatus = physical.cVariadic
        ? ffi_prep_cif_var(
            &cif,
            FFI_DEFAULT_ABI,
            cast(uint) physical.cFixedArgumentCount,
            cast(uint) numAbiArguments,
            resultMetadata.type,
            argumentTypes.ptr,
        )
        : ffi_prep_cif(
            &cif,
            FFI_DEFAULT_ABI,
            cast(uint) numAbiArguments,
            resultMetadata.type,
            argumentTypes.ptr,
        );
    if (prepStatus != ffi_status.FFI_OK)
        return false;
    resultMetadata.restoreNativeLayout;
    if (physical.returnPolicy == PhysicalReturn.value &&
        !layoutMatches(physical.returnType, resultMetadata))
        return false;
    foreach (index, argument; physical.arguments)
        if (!argument.pointer && argument.sourceIndex != size_t.max &&
            !layoutMatches(argument.type, argumentMetadata[index]))
            return false;

    // libffi requires narrow integer returns to use an ffi_arg-wide slot.
    // Copy only the static type's native width into the caller's storage.
    ffi_arg resultScratch;
    const resultCopySize = narrowIntegerResultSize(resultTy);
    void* resultAddress = returnsVoid &&
        physical.returnPolicy != PhysicalReturn.reference
        ? null
        : physical.returnPolicy == PhysicalReturn.reference ||
            resultCopySize == 0
            ? result.address
            : &resultScratch;
    alias CFunction = extern(C) void function();
    ffi_call(
        &cif,
        cast(CFunction) callable.address,
        resultAddress,
        argumentAddresses.ptr,
    );

    if (physical.returnPolicy != PhysicalReturn.reference &&
        resultCopySize != 0) {
        import core.stdc.string: memcpy;
        memcpy(result.address, &resultScratch, resultCopySize);
    }
    return true;
}


private bool requiresSysVTransport(
    Callable callable,
    ref PhysicalCall physical,
) {
    if (containsVector(physical.returnType))
        return true;
    foreach (argument; physical.arguments)
        if (containsVector(argument.type))
            return true;
    return isDmdMemberMemoryReturn(callable, physical);
}


private bool isDmdMemberMemoryReturn(
    Callable callable,
    ref PhysicalCall physical,
) {
    import dmd.argtypes_sysv_x64: toArgTypes_sysv_x64;
    import dmd.astenums: LINK;

    if (callable.signature.linkage != LINK.d ||
        callable.compilerAbi != CompilerAbi.dmd ||
        physical.receiverArgumentIndex == size_t.max ||
        physical.returnPolicy != PhysicalReturn.value)
        return false;
    const returnTuple = toArgTypes_sysv_x64(
        semanticStorageType(physical.returnType),
    );
    return returnTuple !is null && returnTuple.arguments.length == 0;
}


private bool preparePhysicalCall(
    Callable callable,
    TypedAddress[] arguments,
    TypedAddress result,
    TypedAddress* receiver,
    DVariadicMetadata* variadicMetadata,
    out PhysicalCall physical,
) {
    import dmd.astenums: LINK, TY, VarArg;

    if (callable.address is null || callable.signature is null ||
        callable.signature.next is null ||
        (callable.signature.linkage != LINK.c &&
            callable.signature.linkage != LINK.d &&
            callable.signature.linkage != LINK.cpp) ||
        (receiver !is null && callable.signature.linkage != LINK.d &&
            callable.signature.linkage != LINK.cpp) ||
        !hasSupportedVarArgs(callable.signature))
        return false;
    if (callable.declaration !is null &&
        !callable.declaration.type.toBasetype.equals(callable.signature))
        return false;
    if (!hasValidCppReceiverPresence(callable, receiver))
        return false;
    const isCppConstructor = callable.signature.linkage == LINK.cpp &&
        callable.declaration !is null &&
        callable.declaration.isCtorDeclaration !is null;

    const isCKRVariadic = hasKRVariadicArguments(callable.signature);
    const numFixedArguments = isCKRVariadic
        ? 0
        : callable.signature.parameterList.length;
    const hasCVariadicTail = hasCVariadicArguments(callable.signature);
    const isDVariadic = callable.signature.linkage == LINK.d &&
        callable.signature.parameterList.varargs == VarArg.variadic;
    const hasArgumentTail = hasCVariadicTail || isDVariadic;
    if (hasArgumentTail && arguments.length < numFixedArguments ||
        !hasArgumentTail && arguments.length != numFixedArguments ||
        isDVariadic != (variadicMetadata !is null))
        return false;

    physical.returnType = callable.signature.next.toBasetype;
    if (result.type is null ||
        !result.type.toBasetype.equals(physical.returnType))
        return false;
    physical.returnPolicy = isCppConstructor
        ? PhysicalReturn.cppConstructor
        : callable.signature.isRef
            ? PhysicalReturn.reference
            : callable.signature.linkage == LINK.cpp &&
                isCppInvisibleReference(physical.returnType)
                ? PhysicalReturn.cppNonPod
                : PhysicalReturn.value;
    const resultTy = semanticStorageType(physical.returnType).ty;
    const returnsVoid = physical.returnPolicy ==
        PhysicalReturn.cppConstructor || resultTy == TY.Tvoid ||
        resultTy == TY.Tnoreturn;
    if ((physical.returnPolicy == PhysicalReturn.reference || !returnsVoid) &&
        result.address is null)
        return false;

    size_t numPassedArguments;
    size_t numPassedFixedArguments;
    size_t numPointerCells;
    foreach (index, argument; arguments) {
        PhysicalArgumentPolicy policy;
        if (!physicalArgumentPolicy(
            callable,
            argument,
            index,
            numFixedArguments,
            hasCVariadicTail,
            policy,
        ))
            return false;
        if (policy.ignored)
            continue;
        ++numPassedArguments;
        numPointerCells += policy.indirect;
        if (index < numFixedArguments)
            ++numPassedFixedArguments;
    }

    const hasReceiver = receiver !is null;
    if (hasReceiver && (receiver.type is null || receiver.address is null))
        return false;
    if (hasReceiver && callable.signature.linkage == LINK.cpp &&
        callable.declaration !is null &&
        callable.declaration.isThis !is null &&
        !isMatchingReceiverType(
            receiver.type,
            callable.declaration.isThis.type,
        ))
        return false;
    if (hasReceiver)
        switch (receiver.type.toBasetype.ty) with (TY) {
            case Tstruct:
                ++numPointerCells;
                break;
            case Tclass, Tpointer:
                break;
            default:
                return false;
        }
    if (isDVariadic) {
        // DMD's qualifier transforms require mutable type nodes.
        auto expectedType = dVariadicMetadataType(callable.compilerAbi);
        if (variadicMetadata.value.address is null ||
            !isSameUnqualifiedType(
                variadicMetadata.value.type,
                expectedType,
            ))
            return false;
    }
    physical.initialize(
        numPassedArguments + hasReceiver + isDVariadic,
        numPointerCells,
    );
    auto physicalArguments = physical.arguments;
    auto pointerCells = physical.pointerCells;
    size_t nextPhysicalIndex;
    size_t nextPointerCell;
    if (hasReceiver) {
        void* receiverAddress;
        switch (receiver.type.toBasetype.ty) with (TY) {
            case Tstruct:
                pointerCells[nextPointerCell] = receiver.address;
                receiverAddress = &pointerCells[nextPointerCell++];
                break;
            case Tclass, Tpointer:
                receiverAddress = receiver.address;
                break;
            default:
                assert(false, "receiver type was validated before staging");
        }
        physical.receiverArgumentIndex = nextPhysicalIndex;
        physicalArguments[nextPhysicalIndex++] = PhysicalArgument(
            receiver.type,
            receiverAddress,
            size_t.max,
            true,
        );
    }
    if (isDVariadic)
        physicalArguments[nextPhysicalIndex++] = PhysicalArgument(
            variadicMetadata.value.type,
            variadicMetadata.value.address,
        );

    const reversesArguments = callable.signature.linkage == LINK.d &&
        callable.compilerAbi == CompilerAbi.dmd && !isDVariadic;
    foreach (offset; 0 .. arguments.length) {
        const sourceIndex = reversesArguments
            ? arguments.length - offset - 1
            : offset;
        PhysicalArgumentPolicy policy;
        if (!physicalArgumentPolicy(
            callable,
            arguments[sourceIndex],
            sourceIndex,
            numFixedArguments,
            hasCVariadicTail,
            policy,
        ))
            return false;
        if (policy.ignored)
            continue;
        auto address = arguments[sourceIndex].address;
        if (policy.indirect) {
            pointerCells[nextPointerCell] = address;
            address = &pointerCells[nextPointerCell++];
        }
        physicalArguments[nextPhysicalIndex++] = PhysicalArgument(
            arguments[sourceIndex].type,
            address,
            sourceIndex,
            policy.indirect,
        );
    }
    physical.cVariadic = hasCVariadicTail;
    physical.cFixedArgumentCount = isCKRVariadic
        ? hasReceiver
        : numPassedFixedArguments + hasReceiver;
    return true;
}


private struct PhysicalArgumentPolicy {
    private bool indirect;
    private bool ignored;
}


private bool physicalArgumentPolicy(
    Callable callable,
    TypedAddress argument,
    in size_t index,
    in size_t numFixedArguments,
    in bool hasCVariadicTail,
    out PhysicalArgumentPolicy policy,
) {
    import dmd.astenums: LINK, TY;

    if (argument.type is null || argument.address is null)
        return false;
    if (index < numFixedArguments) {
        auto parameter = callable.signature.parameterList[index];
        if (isLazyParameter(parameter)) {
            if (!isMatchingLazyDelegate(argument.type, parameter.type))
                return false;
        } else if (!argument.type.toBasetype.equals(
            parameter.type.toBasetype,
        ))
            return false;
        policy.indirect = isReferenceParameter(parameter) ||
            callable.signature.linkage == LINK.cpp &&
            (argument.type.toBasetype.ty == TY.Treference ||
                isCppInvisibleReference(argument.type));
    } else if (hasCVariadicTail &&
        !isPromotedVariadicType(argument.type))
        return false;
    policy.ignored = !policy.indirect &&
        isIgnoredSysVArgument(argument.type);
    return true;
}


private bool hasValidCppReceiverPresence(
    Callable callable,
    TypedAddress* receiver,
) {
    import dmd.astenums: LINK;

    if (callable.declaration is null ||
        callable.signature.linkage != LINK.cpp)
        return true;
    const declarationHasReceiver = callable.declaration.isThis !is null ||
        callable.declaration.needThis;
    return (receiver !is null) == declarationHasReceiver;
}


private bool isMatchingReceiverType(
    imported!"dmd.mtype".Type actual,
    imported!"dmd.mtype".Type expected,
) {
    return isSameUnqualifiedType(actual, expected);
}


private imported!"dmd.mtype".Type dVariadicMetadataType(
    in CompilerAbi compilerAbi,
) {
    import dmd.mtype: Type;
    import dmd.typesem: arrayOf;

    final switch (compilerAbi) with (CompilerAbi) {
        case dmd:
            return Type.typeinfotypelist is null
                ? null
                : Type.typeinfotypelist.type;
        case ldc:
            return Type.dtypeinfo is null
                ? null
                : Type.dtypeinfo.type.arrayOf;
    }
}


private bool isSameUnqualifiedType(
    imported!"dmd.mtype".Type actual,
    imported!"dmd.mtype".Type expected,
) {
    import dmd.typesem: mutableOf, unSharedOf;

    if (actual is null || expected is null)
        return false;
    // DMD's qualifier transforms require mutable type nodes.
    auto actualBase = actual.toBasetype;
    auto expectedBase = expected.toBasetype;
    return actualBase.ty == expectedBase.ty &&
        actualBase.mutableOf.unSharedOf.equals(
            expectedBase.mutableOf.unSharedOf,
        );
}


private bool containsVector(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto storageType = semanticStorageType(type);
    switch (storageType.ty) with (TY) {
        case Tvector: return true;
        case Tsarray: return containsVector(storageType.nextOf);
        case Tstruct:
            foreach (field; storageType.isTypeStruct.sym.fields)
                if (containsVector(field.type))
                    return true;
            return false;
        default: return false;
    }
}


private bool containsWideVector(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;
    import dmd.typesem: size;

    auto storageType = semanticStorageType(type);
    switch (storageType.ty) with (TY) {
        case Tvector: return size(storageType) == 32;
        case Tsarray: return containsWideVector(storageType.nextOf);
        case Tstruct:
            foreach (field; storageType.isTypeStruct.sym.fields)
                if (containsWideVector(field.type))
                    return true;
            return false;
        default: return false;
    }
}


private bool callSysV(
    Callable callable,
    ref PhysicalCall physical,
    TypedAddress result,
) {
    import quickbite.ffi.sysv_call:
        SysVCallFrame, SysVResultKind, invokeSysV;
    import dmd.argtypes_sysv_x64: toArgTypes_sysv_x64;
    import dmd.astenums: LINK, TY;
    import dmd.mtype: Type;
    import dmd.typesem: size;
    import core.stdc.string: memcpy;

    bool needsAvx = containsWideVector(physical.returnType);
    foreach (argument; physical.arguments)
        needsAvx = needsAvx || containsWideVector(argument.type);
    if (needsAvx) {
        import core.cpuid: avx;
        if (!avx)
            return false;
    }
    if (callable.signature.linkage != LINK.c &&
        callable.signature.linkage != LINK.d &&
        callable.signature.linkage != LINK.cpp)
        return false;

    SysVCallFrame frame;
    frame.target = callable.address;
    frame.stackAlignment = 16;
    ubyte[] stackBytes;
    auto returnType = semanticStorageType(physical.returnType);
    auto returnTuple = physical.returnPolicy == PhysicalReturn.cppConstructor
        ? null
        : toArgTypes_sysv_x64(returnType);
    if (physical.returnPolicy == PhysicalReturn.reference)
        returnTuple = toArgTypes_sysv_x64(Type.tvoidptr);
    const returnsX87 = physical.returnPolicy == PhysicalReturn.value &&
        (returnType.ty == TY.Tfloat80 ||
            returnType.ty == TY.Timaginary80 ||
            returnType.ty == TY.Tcomplex80);
    const returnsInMemory =
        physical.returnPolicy == PhysicalReturn.cppNonPod ||
        physical.returnPolicy == PhysicalReturn.value &&
            returnTuple !is null && returnTuple.arguments.length == 0;
    if ((returnTuple !is null || returnsX87) && result.address is null)
        return false;
    const receiverPrecedesResult = returnsInMemory &&
        callable.signature.linkage == LINK.d &&
        callable.compilerAbi == CompilerAbi.dmd &&
        physical.receiverArgumentIndex != size_t.max;
    size_t nextGpr;
    if (returnsInMemory && !receiverPrecedesResult)
        frame.gpr[nextGpr++] = cast(size_t) result.address;
    size_t nextXmm;
    foreach (argumentIndex, argument; physical.arguments) {
        if (argument.pointer)
            placeSysVPointerArgument(
                frame,
                stackBytes,
                nextGpr,
                argument.address,
            );
        else if (!placeSysVArgument(
                frame,
                stackBytes,
                nextGpr,
                nextXmm,
                TypedAddress(argument.type, argument.address),
            ))
                return false;
        if (receiverPrecedesResult &&
            argumentIndex == physical.receiverArgumentIndex)
            frame.gpr[nextGpr++] = cast(size_t) result.address;
    }
    frame.sseCount = cast(ubyte) nextXmm;
    stackBytes.length = alignedTo(stackBytes.length, frame.stackAlignment);
    frame.stackAddress = stackBytes.ptr;
    frame.stackSize = stackBytes.length;

    if (returnsX87) {
        frame.resultKind = returnType.ty == TY.Tcomplex80
            ? SysVResultKind.x87Pair
            : SysVResultKind.x87;
    } else if (returnTuple is null) {
        frame.resultKind = SysVResultKind.none;
    } else if (!returnsInMemory) {
        frame.resultKind = SysVResultKind.registers;
        foreach (part; *returnTuple.arguments)
            if (isSysVVectorPart(part.type)) {
                const partSize = cast(size_t) size(part.type);
                if (partSize != 16 && partSize != 32)
                    return false;
                if (partSize == 32)
                    frame.usesAvx = true;
            }
    }

    invokeSysV(&frame);

    if (returnsX87) {
        memcpy(result.address, frame.resultX87.ptr,
            cast(size_t) size(returnType));
    } else if (returnTuple !is null && !returnsInMemory) {
        size_t nextResultGpr;
        size_t nextResultXmm;
        foreach (partIndex, part; *returnTuple.arguments) {
            const offset = partIndex * ulong.sizeof;
            const partSize = cast(size_t) size(part.type);
            if (isSysVVectorPart(part.type) || isSysVSseType(part.type)) {
                memcpy(cast(ubyte*) result.address + offset,
                    frame.resultVector[nextResultXmm].ptr, partSize);
                ++nextResultXmm;
            } else {
                memcpy(cast(ubyte*) result.address + offset,
                    &frame.resultGpr[nextResultGpr], partSize);
                ++nextResultGpr;
            }
        }
    }
    return true;
}


private void placeSysVPointerArgument(
    ref imported!"quickbite.ffi.sysv_call".SysVCallFrame frame,
    ref ubyte[] stackBytes,
    ref size_t nextGpr,
    const void* address,
) {
    import core.stdc.string: memcpy;

    if (nextGpr == frame.gpr.length)
        appendSysVPointerStackArgument(stackBytes, address);
    else
        memcpy(&frame.gpr[nextGpr++], address, void*.sizeof);
}


private bool placeSysVArgument(
    ref imported!"quickbite.ffi.sysv_call".SysVCallFrame frame,
    ref ubyte[] stackBytes,
    ref size_t nextGpr,
    ref size_t nextXmm,
    TypedAddress argument,
) {
    import dmd.argtypes_sysv_x64: toArgTypes_sysv_x64;
    import dmd.astenums: TY;
    import dmd.typesem: size;
    import core.stdc.string: memcpy;

    auto tuple = toArgTypes_sysv_x64(semanticStorageType(argument.type));
    if (tuple is null)
        return true;
    size_t neededGpr;
    size_t neededXmm;
    bool mustUseStack = tuple.arguments.length == 0;
    foreach (part; *tuple.arguments) {
        if (part.type.toBasetype.ty == TY.Tfloat80)
            mustUseStack = true;
        else if (isSysVVectorPart(part.type)) {
            const partSize = cast(size_t) size(part.type);
            if (partSize != 16 && partSize != 32)
                return false;
            if (partSize == 32)
                frame.usesAvx = true;
            ++neededXmm;
        } else if (isSysVSseType(part.type))
            ++neededXmm;
        else
            ++neededGpr;
    }
    mustUseStack = mustUseStack ||
        nextGpr + neededGpr > frame.gpr.length ||
        nextXmm + neededXmm > frame.vector.length;
    if (mustUseStack) {
        if (containsWideVector(argument.type))
            frame.stackAlignment = 32;
        appendSysVStackArgument(stackBytes, argument);
        return true;
    }

    foreach (partIndex, part; *tuple.arguments) {
        const offset = partIndex * ulong.sizeof;
        const partSize = cast(size_t) size(part.type);
        if (isSysVVectorPart(part.type) || isSysVSseType(part.type)) {
            if (partSize > frame.vector[nextXmm].length)
                return false;
            memcpy(
                frame.vector[nextXmm++].ptr,
                cast(ubyte*) argument.address + offset,
                partSize,
            );
        } else {
            if (partSize > ulong.sizeof)
                return false;
            memcpy(
                &frame.gpr[nextGpr++],
                cast(ubyte*) argument.address + offset,
                partSize,
            );
        }
    }
    return true;
}


private bool isSysVVectorPart(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tvector;
}


private void appendSysVStackArgument(
    ref ubyte[] stackBytes,
    TypedAddress argument,
) {
    import dmd.typesem: size;
    import core.stdc.string: memcpy;

    auto storageType = semanticStorageType(argument.type);
    const nativeSize = cast(size_t) size(storageType);
    const alignment = storageType.alignsize > 8
        ? cast(size_t) storageType.alignsize
        : size_t(8);
    const offset = alignedTo(stackBytes.length, alignment);
    stackBytes.length = offset + alignedTo(nativeSize, 8);
    memcpy(stackBytes.ptr + offset, argument.address, nativeSize);
}


private void appendSysVPointerStackArgument(
    ref ubyte[] stackBytes,
    const void* address,
) {
    import core.stdc.string: memcpy;

    const offset = alignedTo(stackBytes.length, void*.alignof);
    stackBytes.length = offset + void*.sizeof;
    memcpy(stackBytes.ptr + offset, address, void*.sizeof);
}


private bool isSysVSseType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    switch (type.toBasetype.ty) with (TY) {
        case Tfloat32, Tfloat64, Timaginary32, Timaginary64: return true;
        default: return false;
    }
}


private bool isPromotedVariadicType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    switch (semanticStorageType(type).ty) with (TY) {
        case Tbool, Tint8, Tuns8, Tchar, Tint16, Tuns16, Twchar, Tfloat32:
            return false;
        default:
            return true;
    }
}


private bool hasSupportedVarArgs(
    imported!"dmd.mtype".TypeFunction signature,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK, VarArg;

    const varargs = signature.parameterList.varargs;
    return varargs == VarArg.none || varargs == VarArg.variadic ||
        hasKRVariadicArguments(signature) ||
        signature.linkage == LINK.d && varargs == VarArg.typesafe;
}


private bool hasCVariadicArguments(
    imported!"dmd.mtype".TypeFunction signature,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK, VarArg;

    const varargs = signature.parameterList.varargs;
    return (signature.linkage == LINK.c || signature.linkage == LINK.cpp) &&
        (varargs == VarArg.variadic || varargs == VarArg.KRvariadic);
}


private bool hasKRVariadicArguments(
    imported!"dmd.mtype".TypeFunction signature,
) @safe @nogc nothrow pure {
    import dmd.astenums: LINK, VarArg;

    return (signature.linkage == LINK.c || signature.linkage == LINK.cpp) &&
        signature.parameterList.varargs == VarArg.KRvariadic;
}


private bool isCppInvisibleReference(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;
    import dmd.dsymbolsem: isPOD;

    auto storageType = semanticStorageType(type);
    return storageType.ty == TY.Tstruct &&
        !storageType.isTypeStruct.sym.isPOD;
}


private FfiType cppNonPodReturnFfiType(imported!"dmd.mtype".Type type) {
    import dmd.typesem: size;

    auto storageType = semanticStorageType(type);
    return memoryClassificationWitness(
        cast(size_t) size(storageType),
        cast(ushort) storageType.alignsize,
        true,
    );
}


private bool isLazyParameter(
    imported!"dmd.mtype".Parameter parameter,
) @safe @nogc nothrow pure {
    import dmd.astenums: STC;

    return (parameter.storageClass & STC.lazy_) != STC.none;
}


private bool isMatchingLazyDelegate(
    imported!"dmd.mtype".Type storageType,
    imported!"dmd.mtype".Type resultType,
) {
    import dmd.astenums: VarArg;

    auto delegateType = storageType.toBasetype.isTypeDelegate;
    if (delegateType is null)
        return false;
    auto signature = delegateType.next.toBasetype.isTypeFunction;
    return signature !is null &&
        signature.parameterList.length == 0 &&
        signature.parameterList.varargs == VarArg.none &&
        signature.next.toBasetype.equals(resultType.toBasetype);
}


private bool isReferenceParameter(
    imported!"dmd.mtype".Parameter parameter,
) @safe @nogc nothrow pure {
    import dmd.astenums: STC;

    return (parameter.storageClass & (STC.ref_ | STC.out_)) != STC.none;
}


private bool isIgnoredSysVArgument(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto storageType = semanticStorageType(type);
    if (storageType.ty != TY.Tsarray && storageType.ty != TY.Tstruct)
        return false;

    SysVClass[2] classes;
    return classifySysV(storageType, 0, classes) &&
        classes == [SysVClass.none, SysVClass.none];
}


private size_t narrowIntegerResultSize(
    in imported!"dmd.astenums".TY type,
) @safe @nogc nothrow pure {
    import dmd.astenums: TY;

    switch (type) with (TY) {
        case Tbool, Tint8, Tuns8, Tchar: return byte.sizeof;
        case Tint16, Tuns16, Twchar: return short.sizeof;
        case Tint32, Tuns32, Tdchar: return int.sizeof;
        default: return 0;
    }
}


private struct FfiType {
    private imported!"quickbite.ffi.libffi".ffi_type* _type;
    private imported!"quickbite.ffi.libffi".ffi_type[] _ownedTypes;
    private imported!"quickbite.ffi.libffi".ffi_type*[] _ownedElements;
    private FfiType[] _members;
    private size_t _nativeSize;
    private ushort _nativeAlignment;

    private imported!"quickbite.ffi.libffi".ffi_type* type()
        @safe @nogc nothrow pure {
        return _type;
    }

    private void restoreNativeLayout() @safe @nogc nothrow pure {
        if (_nativeSize == 0)
            return;
        _type.size = _nativeSize;
        _type.alignment = _nativeAlignment;
    }
}


private FfiType ffiTypeFor(
    imported!"dmd.mtype".Type type,
    in bool isReturn = false,
) {
    import quickbite.ffi.libffi:
        ffi_type_complex_double, ffi_type_complex_float,
        ffi_type_complex_longdouble, ffi_type_double, ffi_type_float,
        ffi_type_longdouble, ffi_type_pointer, ffi_type_sint8, ffi_type_sint16,
        ffi_type_sint32, ffi_type_sint64, ffi_type_uint8, ffi_type_uint16,
        ffi_type_uint32, ffi_type_uint64, ffi_type_void;
    import dmd.astenums: TY;

    if (type is null)
        return FfiType.init;

    // DMD owns mutable semantic type nodes.
    auto storageType = semanticStorageType(type);
    switch (storageType.ty) with (TY) {
        case Tvoid, Tnoreturn: return FfiType(&ffi_type_void);
        case Tbool, Tuns8, Tchar: return FfiType(&ffi_type_uint8);
        case Tint8: return FfiType(&ffi_type_sint8);
        case Tuns16, Twchar: return FfiType(&ffi_type_uint16);
        case Tint16: return FfiType(&ffi_type_sint16);
        case Tuns32, Tdchar: return FfiType(&ffi_type_uint32);
        case Tint32: return FfiType(&ffi_type_sint32);
        case Tuns64: return FfiType(&ffi_type_uint64);
        case Tint64: return FfiType(&ffi_type_sint64);
        case Tint128, Tuns128:
            return aggregateFfiType([
                FfiType(&ffi_type_uint64),
                FfiType(&ffi_type_uint64),
            ]);
        // An imaginary scalar has the same one-component native storage as
        // its real counterpart. Complex descriptors express the two-component
        // ABI directly; neither path reads or reconstructs the value.
        case Tfloat32, Timaginary32: return FfiType(&ffi_type_float);
        case Tfloat64, Timaginary64: return FfiType(&ffi_type_double);
        case Tfloat80, Timaginary80: return FfiType(&ffi_type_longdouble);
        case Tcomplex32: return FfiType(&ffi_type_complex_float);
        case Tcomplex64: return FfiType(&ffi_type_complex_double);
        case Tcomplex80: return FfiType(&ffi_type_complex_longdouble);
        case Tpointer, Treference, Tclass, Taarray, Tnull:
            return FfiType(&ffi_type_pointer);
        case Tarray:
            // A native D dynamic array is `{length, ptr}` in word order.
            return aggregateFfiType([
                FfiType(&ffi_type_uint64),
                FfiType(&ffi_type_pointer),
            ]);
        case Tdelegate:
            // A native D delegate is `{context, funcptr}` in word order.
            return aggregateFfiType([
                FfiType(&ffi_type_pointer),
                FfiType(&ffi_type_pointer),
            ]);
        case Tsarray: return staticArrayFfiType(storageType.isTypeSArray);
        case Tstruct: return structFfiType(storageType.isTypeStruct, isReturn);
        default: return FfiType.init;
    }
}


private imported!"dmd.mtype".Type semanticStorageType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

    // DMD owns mutable semantic type nodes.
    auto baseType = type.toBasetype;
    return baseType.ty == TY.Tenum
        ? semanticStorageType(baseType.isTypeEnum.memType)
        : baseType;
}


private FfiType staticArrayFfiType(
    imported!"dmd.mtype".TypeSArray type,
) {
    auto element = ffiTypeFor(type.next);
    if (element.type is null)
        return FfiType.init;

    const length = cast(size_t) type.dim.toInteger;
    auto elements = new FfiType[](length);
    foreach (ref member; elements)
        member = element;
    return aggregateFfiType(elements);
}


private FfiType structFfiType(
    imported!"dmd.mtype".TypeStruct type,
    in bool isReturn,
) {
    if (type.sym.isUnionDeclaration !is null)
        return sysVClassificationWitness(type, isReturn);

    if (!hasNaturalStructLayout(type))
        return sysVClassificationWitness(type, isReturn);

    auto fields = new FfiType[](type.sym.fields.length);
    foreach (index, field; type.sym.fields) {
        fields[index] = ffiTypeFor(field.type);
        if (fields[index].type is null)
            return FfiType.init;
    }
    return aggregateFfiType(fields);
}


private bool hasNaturalStructLayout(
    imported!"dmd.mtype".TypeStruct type,
) {
    import dmd.typesem: size;

    size_t offset;
    size_t alignment = 1;
    foreach (field; type.sym.fields) {
        const fieldAlignment = cast(size_t) field.type.alignsize;
        offset = alignedTo(offset, fieldAlignment);
        if (offset != cast(size_t) field.offset)
            return false;
        offset += cast(size_t) size(field.type);
        if (fieldAlignment > alignment)
            alignment = fieldAlignment;
    }
    return alignedTo(offset, alignment) == cast(size_t) size(type) &&
        alignment == type.alignsize;
}


private size_t alignedTo(
    in size_t offset,
    in size_t alignment,
) @safe @nogc nothrow pure {
    return (offset + alignment - 1) / alignment * alignment;
}


private enum SysVClass {
    none,
    integer,
    sse,
    x87,
    x87Up,
    memory,
}


private FfiType sysVClassificationWitness(
    imported!"dmd.mtype".Type type,
    in bool isReturn,
) {
    import quickbite.ffi.libffi:
        ffi_type_double, ffi_type_longdouble, ffi_type_uint64;
    import dmd.typesem: size;

    SysVClass[2] classes;
    if (!classifySysV(type, 0, classes))
        return FfiType.init;

    // DMD owns mutable semantic type nodes.
    auto storageType = semanticStorageType(type);
    const nativeSize = cast(size_t) size(storageType);
    const nativeAlignment = cast(ushort) storageType.alignsize;
    if (classes[0] == SysVClass.memory || classes[1] == SysVClass.memory)
        // A classification witness contains only libffi call metadata. It
        // neither describes nor touches the native value's bytes.
        return memoryClassificationWitness(
            nativeSize,
            nativeAlignment,
            isReturn,
        );
    if (classes == [SysVClass.x87, SysVClass.x87Up])
        return FfiType(&ffi_type_longdouble);

    auto members = new FfiType[]((nativeSize + 7) / 8);
    foreach (index, ref member; members) {
        final switch (classes[index]) with (SysVClass) {
            case sse: member = FfiType(&ffi_type_double); break;
            case none, integer: member = FfiType(&ffi_type_uint64); break;
            case x87, x87Up, memory: return FfiType.init;
        }
    }
    return sizedAggregateFfiType(nativeSize, nativeAlignment, members);
}


private FfiType memoryClassificationWitness(
    in size_t nativeSize,
    in ushort nativeAlignment,
    in bool isReturn,
) {
    import quickbite.ffi.libffi:
        ffi_type, ffi_type_longdouble, ffi_type_uint8, ffi_type_uint64;

    if (nativeSize > 16 || isReturn) {
        // libffi records MEMORY return handling while preparing the CIF from
        // this three-eightbyte size. Before ffi_call, the descriptor returns
        // to DMD's native layout so the sret destination is used directly.
        const preparedSize = nativeSize > 16
            ? nativeSize
            : 3 * ulong.sizeof;
        auto result = sizedAggregateFfiType(
            preparedSize,
            nativeAlignment,
            [
                FfiType(&ffi_type_uint64),
                FfiType(&ffi_type_uint64),
                FfiType(&ffi_type_uint64),
            ],
        );
        if (preparedSize != nativeSize) {
            result._nativeSize = nativeSize;
            result._nativeAlignment = nativeAlignment;
        }
        return result;
    }

    auto ownedTypes = new ffi_type[1];
    // Mixing X87 and INTEGER makes libffi classify the argument as MEMORY.
    // Shrinking the marker lets both classes fit inside the native outer size;
    // it is metadata only and does not read an X87 value from storage.
    ownedTypes[0] = ffi_type_longdouble;
    ownedTypes[0].size = 1;
    ownedTypes[0].alignment = 1;
    auto x87Marker = FfiType(&ownedTypes[0], ownedTypes);
    return sizedAggregateFfiType(
        nativeSize,
        nativeAlignment,
        [
            x87Marker,
            FfiType(&ffi_type_uint8),
        ],
    );
}


private bool classifySysV(
    imported!"dmd.mtype".Type type,
    in size_t offset,
    ref SysVClass[2] classes,
) {
    import dmd.astenums: TY;
    import dmd.typesem: size;

    // DMD owns mutable semantic type nodes.
    auto storageType = semanticStorageType(type);
    const nativeSize = cast(size_t) size(storageType);
    if (offset == 0 && nativeSize > 16) {
        classes[0] = SysVClass.memory;
        return true;
    }
    if (storageType.alignsize > 1 && offset % storageType.alignsize != 0) {
        classes[0] = SysVClass.memory;
        return true;
    }

    switch (storageType.ty) with (TY) {
        case Tbool, Tint8, Tuns8, Tchar, Tint16, Tuns16, Twchar,
                Tint32, Tuns32, Tdchar, Tint64, Tuns64, Tpointer, Tclass,
                Taarray:
            return mergeSysVRange(classes, offset, nativeSize,
                SysVClass.integer);
        case Tint128, Tuns128:
            return mergeSysVRange(classes, offset, nativeSize,
                SysVClass.integer);
        case Tarray, Tdelegate:
            return mergeSysVRange(classes, offset, nativeSize,
                SysVClass.integer);
        case Tfloat32, Tfloat64, Timaginary32, Timaginary64, Tcomplex32,
                Tcomplex64:
            return mergeSysVRange(classes, offset, nativeSize, SysVClass.sse);
        case Tfloat80, Timaginary80:
            return mergeSysVLongDouble(classes, offset);
        case Tcomplex80:
            classes[0] = SysVClass.memory;
            return true;
        case Tvoid, Tnoreturn:
            return true;
        case Tsarray:
            const length = cast(size_t) storageType.isTypeSArray.dim.toInteger;
            const elementSize = cast(size_t) size(storageType.nextOf);
            foreach (index; 0 .. length)
                if (!classifySysV(
                    storageType.nextOf,
                    offset + index * elementSize,
                    classes,
                ))
                    return false;
            return true;
        case Tstruct:
            foreach (field; storageType.isTypeStruct.sym.fields)
                if (!classifySysV(
                    field.type,
                    offset + cast(size_t) field.offset,
                    classes,
                ))
                    return false;
            return true;
        case Tvector:
            // Vector SSEUP classification needs a faithful libffi witness of
            // its own; scalar SSE metadata must not stand in for it.
            return false;
        default:
            return false;
    }
}


private bool mergeSysVRange(
    ref SysVClass[2] classes,
    in size_t offset,
    in size_t size,
    in SysVClass incoming,
) @safe @nogc nothrow pure {
    if (size == 0)
        return true;
    const firstLane = offset / 8;
    const lastLane = (offset + size - 1) / 8;
    if (lastLane >= classes.length) {
        classes[0] = SysVClass.memory;
        return true;
    }
    foreach (lane; firstLane .. lastLane + 1)
        classes[lane] = mergeSysV(classes[lane], incoming);
    return true;
}


private bool mergeSysVLongDouble(
    ref SysVClass[2] classes,
    in size_t offset,
) @safe @nogc nothrow pure {
    if (offset != 0) {
        classes[0] = SysVClass.memory;
        return true;
    }
    classes[0] = mergeSysV(classes[0], SysVClass.x87);
    classes[1] = mergeSysV(classes[1], SysVClass.x87Up);
    if (classes[0] == SysVClass.memory || classes[1] == SysVClass.memory)
        classes[0] = SysVClass.memory;
    return true;
}


private SysVClass mergeSysV(
    in SysVClass existing,
    in SysVClass incoming,
) @safe @nogc nothrow pure {
    if (existing == SysVClass.none || existing == incoming)
        return incoming;
    if (incoming == SysVClass.none)
        return existing;
    if (existing == SysVClass.memory || incoming == SysVClass.memory)
        return SysVClass.memory;
    if (existing == SysVClass.x87 || existing == SysVClass.x87Up ||
        incoming == SysVClass.x87 || incoming == SysVClass.x87Up)
        return SysVClass.memory;
    if (existing == SysVClass.integer || incoming == SysVClass.integer)
        return SysVClass.integer;
    if (existing == SysVClass.sse && incoming == SysVClass.sse)
        return SysVClass.sse;
    return SysVClass.memory;
}


private bool layoutMatches(
    imported!"dmd.mtype".Type type,
    ref FfiType metadata,
) {
    import dmd.astenums: TY;
    import dmd.typesem: size;

    // DMD's layout queries require its mutable semantic type node.
    auto baseType = type.toBasetype;
    if (baseType.ty != TY.Tsarray && baseType.ty != TY.Tstruct)
        return true;

    return metadata.type.size == size(baseType) &&
        metadata.type.alignment == baseType.alignsize;
}


private FfiType aggregateFfiType(
    FfiType[] members,
) {
    return sizedAggregateFfiType(0, 0, members);
}


private FfiType sizedAggregateFfiType(
    in size_t size,
    in ushort alignment,
    FfiType[] members,
) {
    import quickbite.ffi.libffi: ffi_type, FFI_TYPE_STRUCT;

    auto ownedTypes = new ffi_type[1];
    auto elements = new ffi_type*[](members.length + 1);
    foreach (index, ref member; members)
        elements[index] = member.type;
    elements[$ - 1] = null;
    ownedTypes[0] = ffi_type(size, alignment, FFI_TYPE_STRUCT, elements.ptr);
    // Keep every recursive descriptor and element array alive until ffi_call.
    return FfiType(&ownedTypes[0], ownedTypes, elements, members);
}

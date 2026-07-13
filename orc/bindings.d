module orc.bindings;


// Hand-written extern(C) declarations for the ORC-V2 / Core C API functions
// LLVMJit needs. No llvm-d/bindbc dependency and no LLVM dev headers: the
// installed libLLVM.so exports these symbols, so we declare the prototypes
// ourselves. Opaque handles are modelled as distinct pointer types so the D
// compiler keeps them apart; the C API only ever passes them around by
// pointer.

private:


// `libLLVM.so` is a bare soname symlink on this host (-> libLLVM.so.22.1), so
// the plain `-lLLVM` the build wiring passes resolves it. pragma(lib) here
// documents the dependency for non-dub builds; the dub.sdl `libs "LLVM"`
// drives the actual link.
pragma(lib, "LLVM");


public:


// Opaque ORC / Core handles.
extern(C) struct LLVMOrcOpaqueLLJIT {}
alias LLVMOrcLLJITRef = LLVMOrcOpaqueLLJIT*;

extern(C) struct LLVMOrcOpaqueLLJITBuilder {}
alias LLVMOrcLLJITBuilderRef = LLVMOrcOpaqueLLJITBuilder*;

extern(C) struct LLVMOrcOpaqueJITDylib {}
alias LLVMOrcJITDylibRef = LLVMOrcOpaqueJITDylib*;

extern(C) struct LLVMOrcOpaqueObjectLayer {}
alias LLVMOrcObjectLayerRef = LLVMOrcOpaqueObjectLayer*;

extern(C) struct LLVMOrcOpaqueDefinitionGenerator {}
alias LLVMOrcDefinitionGeneratorRef = LLVMOrcOpaqueDefinitionGenerator*;

extern(C) struct LLVMOpaqueMemoryBuffer {}
alias LLVMMemoryBufferRef = LLVMOpaqueMemoryBuffer*;

extern(C) struct LLVMOpaqueError {}
alias LLVMErrorRef = LLVMOpaqueError*;

// An executor-process address: where a looked-up symbol lives, castable to a
// function pointer when the JIT shares the host's address space (it does).
alias LLVMOrcExecutorAddress = ulong;

// A refcounted, interned symbol name owned by the execution session's string
// pool; absolute-symbol definitions are keyed by these.
extern(C) struct LLVMOrcOpaqueSymbolStringPoolEntry {}
alias LLVMOrcSymbolStringPoolEntryRef = LLVMOrcOpaqueSymbolStringPoolEntry*;

// A unit of symbols handed to a JITDylib (here, a set of absolute addresses).
extern(C) struct LLVMOrcOpaqueMaterializationUnit {}
alias LLVMOrcMaterializationUnitRef = LLVMOrcOpaqueMaterializationUnit*;

// An object-file binary parsed from a memory buffer (Object API), iterated to
// discover its symbol names.
extern(C) struct LLVMOpaqueBinary {}
alias LLVMBinaryRef = LLVMOpaqueBinary*;

extern(C) struct LLVMOpaqueSymbolIterator {}
alias LLVMSymbolIteratorRef = LLVMOpaqueSymbolIterator*;

// The low byte of a JIT symbol's flags: which of the generic properties hold.
// A host definition we inject is callable, exported and weak (so a strong
// definition in the object, if any, still wins — ELF interposition semantics).
enum LLVMJITSymbolGenericFlags {
    exported = 1,
    weak = 2,
    callable = 4,
}

// JIT symbol flags as the C API lays them out (two bytes, passed by value).
extern(C) struct LLVMJITSymbolFlags {
    ubyte genericFlags;
    ubyte targetFlags;
}

// An address plus its flags: the value half of an absolute-symbol definition.
extern(C) struct LLVMJITEvaluatedSymbol {
    LLVMOrcExecutorAddress address;
    LLVMJITSymbolFlags flags;
}

// One absolute-symbol definition: interned name -> evaluated symbol.
extern(C) struct LLVMOrcCSymbolMapPair {
    LLVMOrcSymbolStringPoolEntryRef name;
    LLVMJITEvaluatedSymbol sym;
}

// The C type for a JITDylib symbol-name predicate; we never filter, so callers
// pass null for the predicate and its context.
alias LLVMOrcSymbolPredicate =
    extern(C) int function(void* ctx, const(char)* symbol);


extern(C) @nogc nothrow {
    // Register the host's target, code generator and asm printer with LLVM's
    // target registry. LLJIT needs all three before it can build for the host
    // triple. (These are static-inline shims in the C headers but real
    // exported symbols in libLLVM.so as the
    // `LLVMInitialize<Arch>*` family; the per-arch entry points below are what
    // the inline shims call.)
    void LLVMInitializeX86TargetInfo();
    void LLVMInitializeX86Target();
    void LLVMInitializeX86TargetMC();
    void LLVMInitializeX86AsmPrinter();

    // Create an LLJIT instance. Passing a null builder requests host defaults
    // (host target triple, default object linking layer). Returns null on
    // success; an LLVMErrorRef to dispose on failure.
    LLVMErrorRef LLVMOrcCreateLLJIT(
        LLVMOrcLLJITRef* result,
        LLVMOrcLLJITBuilderRef builder,
    );

    // The JITDylib that AddObjectFile and lookup operate on by default.
    LLVMOrcJITDylibRef LLVMOrcLLJITGetMainJITDylib(LLVMOrcLLJITRef jit);

    // The object linking layer used by LLJIT. Static-library generators need
    // this so they can add archive members to the same layer as hot objects.
    LLVMOrcObjectLayerRef LLVMOrcLLJITGetObjLinkingLayer(LLVMOrcLLJITRef jit);

    // The platform global symbol prefix character (0 on Linux x86-64 ELF), so
    // lookup names need no extra leading underscore here.
    char LLVMOrcLLJITGetGlobalPrefix(LLVMOrcLLJITRef jit);

    // A generator that resolves symbols by searching the running process's own
    // symbol table (everything libphobos2.so already mapped into bin/ut).
    LLVMErrorRef LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(
        LLVMOrcDefinitionGeneratorRef* result,
        char globalPrefix,
        LLVMOrcSymbolPredicate filter,
        void* filterCtx,
    );

    // A generator that resolves symbols by lazily extracting object members
    // from a static library archive.
    LLVMErrorRef LLVMOrcCreateStaticLibrarySearchGeneratorForPath(
        LLVMOrcDefinitionGeneratorRef* result,
        LLVMOrcObjectLayerRef objLayer,
        const(char)* fileName,
    );

    // Attach a generator to a JITDylib so unresolved symbols fall through to it.
    void LLVMOrcJITDylibAddGenerator(
        LLVMOrcJITDylibRef dylib,
        LLVMOrcDefinitionGeneratorRef generator,
    );

    // Wrap an on-disk file's bytes in a memory buffer (Core API). Returns
    // nonzero on failure and writes a malloc'd message to *outMessage.
    int LLVMCreateMemoryBufferWithContentsOfFile(
        const(char)* path,
        LLVMMemoryBufferRef* outMemBuf,
        char** outMessage,
    );

    // Add an object file (taking ownership of the buffer) to a JITDylib; the
    // object is materialized lazily on lookup.
    LLVMErrorRef LLVMOrcLLJITAddObjectFile(
        LLVMOrcLLJITRef jit,
        LLVMOrcJITDylibRef dylib,
        LLVMMemoryBufferRef objBuffer,
    );

    // Look up a symbol by mangled name in the main JITDylib, materializing as
    // needed. Returns null and writes the address on success.
    LLVMErrorRef LLVMOrcLLJITLookup(
        LLVMOrcLLJITRef jit,
        LLVMOrcExecutorAddress* result,
        const(char)* name,
    );

    // Intentionally unused: the JIT child _exits instead of disposing; adding
    // a dispose call recreates the Step-4 munmap-then-collect crash.
    LLVMErrorRef LLVMOrcDisposeLLJIT(LLVMOrcLLJITRef jit);

    // The human-readable message of an error; consumes the error (frees it).
    char* LLVMGetErrorMessage(LLVMErrorRef err);

    // Free a string returned by LLVMGetErrorMessage.
    void LLVMDisposeErrorMessage(char* errMsg);

    // Intern an unmangled name into the execution session's symbol string pool
    // (refcount +1). On Linux x86-64 ELF the mangle step is a no-op, so this is
    // just interning; the returned entry is consumed by LLVMOrcAbsoluteSymbols.
    LLVMOrcSymbolStringPoolEntryRef LLVMOrcLLJITMangleAndIntern(
        LLVMOrcLLJITRef jit,
        const(char)* unmangledName,
    );

    // Build a materialization unit that defines the given names at the given
    // fixed addresses. It consumes one reference on each pair's name entry; the
    // pairs array itself stays caller-owned.
    LLVMOrcMaterializationUnitRef LLVMOrcAbsoluteSymbols(
        LLVMOrcCSymbolMapPair* syms,
        size_t numPairs,
    );

    // Define a materialization unit's symbols in a JITDylib. On success the
    // dylib owns the unit; on failure the returned error owns it (we dispose).
    LLVMErrorRef LLVMOrcJITDylibDefine(
        LLVMOrcJITDylibRef dylib,
        LLVMOrcMaterializationUnitRef unit,
    );

    // Dispose a materialization unit the JITDylib never took ownership of.
    void LLVMOrcDisposeMaterializationUnit(LLVMOrcMaterializationUnitRef unit);

    // Parse the bytes of a memory buffer as a binary (Object API). Returns null
    // and writes a malloc'd message on failure. Does NOT take ownership of the
    // buffer: it must outlive the returned binary.
    LLVMBinaryRef LLVMCreateBinary(
        LLVMMemoryBufferRef memBuf,
        void* context,
        char** errorMessage,
    );

    // Release a binary parsed by LLVMCreateBinary.
    void LLVMDisposeBinary(LLVMBinaryRef binary);

    // A symbol-name iterator over an object binary; null if it has no symbols.
    LLVMSymbolIteratorRef LLVMObjectFileCopySymbolIterator(LLVMBinaryRef binary);
    int LLVMObjectFileIsSymbolIteratorAtEnd(
        LLVMBinaryRef binary,
        LLVMSymbolIteratorRef si,
    );
    void LLVMMoveToNextSymbol(LLVMSymbolIteratorRef si);
    void LLVMDisposeSymbolIterator(LLVMSymbolIteratorRef si);
    const(char)* LLVMGetSymbolName(LLVMSymbolIteratorRef si);
}

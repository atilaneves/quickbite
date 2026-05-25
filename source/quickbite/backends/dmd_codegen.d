module quickbite.backends.dmd_codegen;

private:

__gshared bool _backendInit;
__gshared bool _loadedHandlesCleanupRegistered;
__gshared size_t _loadedHandlesCapacity;
__gshared size_t _loadedHandlesLength;
__gshared void** _loadedHandles;
__gshared uint _tempCounter;
__gshared imported!"dmd.dtemplate".TemplateInstance[void*] _templateNextByInstance;

// Object files accumulated across all fixture runs.  Linking every new
// fixture against the full accumulated set avoids re-emitting TypeInfo and
// other one-shot data symbols that were already emitted by an earlier run.
// The symbol duplication this causes is harmless: TypeInfo initialisers are
// weak-object (V) symbols; the linker silently picks one copy.
__gshared string[] _accumulatedObjPaths;
// Tracks which fixture modules have already contributed objects so that
// repeated benchmark iterations (warmup + timed) do not keep appending
// duplicate object sets and blowing up the link command.
__gshared bool[void*] _accumulatedModules;

struct GeneratedObjects {
    string[] objPaths;
    imported!"dmd.dmodule".Module[] modules;
}

struct TempDirNode {
    // C-owned mutable storage.  This is deliberately not a D string because
    // the atexit handler can run after the D runtime has started tearing down.
    char* path;
    TempDirNode* next;
}
__gshared TempDirNode* _tempDirsToCleanup;
__gshared bool _tempCleanupRegistered;

extern (C) private void removeTempDirsAtExit() @trusted @nogc nothrow {
    import core.stdc.stdlib: free;

    auto node = _tempDirsToCleanup;
    while (node) {
        auto next = node.next;
        removeTempDir(node.path);
        free(node.path);
        free(node);
        node = next;
    }
}

private void removeTempDir(char* path) @trusted @nogc nothrow {
    import core.stdc.stdlib: free, malloc;
    import core.stdc.string: memcpy, strcmp, strlen;
    import core.sys.posix.dirent: closedir, DT_DIR, opendir, readdir;
    import core.sys.posix.unistd: rmdir, unlink;

    auto dir = opendir(path);
    if (!dir) {
        unlink(path);
        return;
    }

    const pathLength = strlen(path);
    while (auto entry = readdir(dir)) {
        auto name = entry.d_name.ptr;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;

        const nameLength = strlen(name);
        // Allocate child paths with malloc so recursive cleanup stays out of
        // the GC and Phobos during process-exit teardown.
        auto child = cast(char*) malloc(pathLength + 1 + nameLength + 1);
        if (!child)
            continue;
        memcpy(child, path, pathLength);
        child[pathLength] = '/';
        memcpy(child + pathLength + 1, name, nameLength + 1);
        if (entry.d_type == DT_DIR) {
            removeTempDir(child);
        } else {
            unlink(child);
        }
        free(child);
    }

    closedir(dir);
    rmdir(path);
}

private void registerTempCleanup(in string dir) @trusted {
    import core.stdc.stdlib: atexit, free, malloc;
    import core.stdc.string: memcpy;

    if (!_tempCleanupRegistered) {
        atexit(&removeTempDirsAtExit);
        _tempCleanupRegistered = true;
    }

    // Keep a C-owned copy of the temp path.  The cleanup callback is registered
    // with libc's atexit, so it must not depend on GC-managed D arrays.
    auto path = cast(char*) malloc(dir.length + 1);
    auto node = cast(TempDirNode*) malloc(TempDirNode.sizeof);
    if (!path || !node) {
        if (path)
            free(path);
        if (node)
            free(node);
        throw new Exception("Failed to register DMD codegen temp directory cleanup.");
    }

    memcpy(path, dir.ptr, dir.length);
    path[dir.length] = '\0';
    node.path = path;
    node.next = _tempDirsToCleanup;
    _tempDirsToCleanup = node;
}

extern (C) private void closeLoadedHandlesAtExit() @trusted {
    import core.sys.posix.dlfcn: dlclose;

    while (_loadedHandlesLength != 0) {
        --_loadedHandlesLength;
        auto handle = _loadedHandles[_loadedHandlesLength];
        if (handle)
            dlclose(handle);
    }
}

private void keepLoadedHandle(void* handle) @trusted {
    registerLoadedHandlesCleanup;

    if (_loadedHandlesLength == _loadedHandlesCapacity) {
        import core.stdc.stdlib: realloc;

        const newCapacity = _loadedHandlesCapacity == 0
            ? 8
            : _loadedHandlesCapacity * 2;
        const newSize = newCapacity * (void*).sizeof;
        auto loadedHandles = cast(void**) realloc(_loadedHandles, newSize);
        if (!loadedHandles)
            throw new Exception("Failed to remember DMD codegen shared library handle.");

        _loadedHandles = loadedHandles;
        _loadedHandlesCapacity = newCapacity;
    }

    _loadedHandles[_loadedHandlesLength] = handle;
    ++_loadedHandlesLength;
}

private void registerLoadedHandlesCleanup() @trusted {
    import core.stdc.stdlib: atexit;

    if (_loadedHandlesCleanupRegistered)
        return;

    atexit(&closeLoadedHandlesAtExit);
    _loadedHandlesCleanupRegistered = true;
}

public final class DmdCodegen : imported!"quickbite.executor".Executor {
    private string[] linkFiles;
    private string[] sourceImportPaths;

    public this(
        in string[] linkFiles = [],
        in string[] sourceImportPaths = [],
    ) {
        this.linkFiles         = linkFiles.dup;
        this.sourceImportPaths = sourceImportPaths.dup;
    }

    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source, sourceImportPaths).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        auto module_ = parseModule(source, importPaths).module_;
        compileParsedTests(module_, importPaths);
    }

    public override void runParsedTests(imported!"dmd.dmodule".Module module_) {
        compileParsedTests(module_, sourceImportPaths);
    }

    private void compileParsedTests(
        imported!"dmd.dmodule".Module module_,
        in string[] importPaths,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        bool hasTests;
        foreachUnitTestDeclaration(module_, (_) { hasTests = true; });
        if (!hasTests)
            return;

        compileAndRun(module_, linkFiles, importPaths);
    }

    public override imported!"quickbite.executor".TestSummary runTestSummary(in string source) {
        import quickbite.executor: TestSummary;
        import quickbite.frontend.compiler: parseModule;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        auto module_ = parseModule(source).module_;
        TestSummary summary;

        bool hasTests;
        foreachUnitTestDeclaration(module_, (_) { hasTests = true; });

        if (!hasTests)
            return summary;

        summary.total = 1;
        try {
            compileAndRun(module_, linkFiles, sourceImportPaths);
            summary.passed = summary.total;
        } catch (Exception) {
            summary.failed = 1;
            summary.passed = summary.total - 1;
        }

        return summary;
    }
}

private void compileAndRun(
    imported!"dmd.dmodule".Module module_,
    in string[] linkFiles,
    in string[] sourceImportPaths,
) @trusted {
    import core.atomic: atomicFetchAdd;
    import quickbite.frontend.compiler: withCompilerLock;
    import std.conv: text;
    import std.file: mkdirRecurse, tempDir;
    import std.path: buildPath;

    const idx = atomicFetchAdd(_tempCounter, 1u);
    const tmpDir = buildPath(tempDir, text("quickbite_dmd_", idx));
    mkdirRecurse(tmpDir);
    // Object files are kept for the process lifetime so later fixture runs can
    // link against TypeInfo and other one-shot data symbols emitted earlier.
    // The temp dir is removed at process exit via removeTempDirsAtExit.
    registerTempCleanup(tmpDir);

    const soPath = buildPath(tmpDir, "module.so");
    GeneratedObjects generated;

    withCompilerLock(() {
        ensureBackendInit;
        generated = generateObjs(module_, tmpDir, sourceImportPaths, idx);
    });

    // Accumulate this fixture's objects on the first run only.  Repeated
    // benchmark iterations (warmup + timed) re-run codegen for measurement
    // but link against the already-accumulated first-run objects, keeping
    // the accumulated set bounded at one object-set per distinct fixture.
    const moduleKey = cast(void*) module_;
    if (moduleKey !in _accumulatedModules) {
        _accumulatedModules[moduleKey] = true;
        foreach (generatedModule; generated.modules)
            if (generatedModule.hasSnippetSourceFile)
                _accumulatedModules[cast(void*) generatedModule] = true;
        _accumulatedObjPaths ~= generated.objPaths;
    }
    runSharedLibraryBridge(
        _accumulatedObjPaths,
        soPath,
        linkFiles.withInferredLinkFiles(sourceImportPaths),
        module_,
    );
}

private void runSharedLibraryBridge(
    in string[] objPaths,
    in string soPath,
    in string[] linkFiles,
    imported!"dmd.dmodule".Module module_,
) @trusted {
    link(objPaths, soPath, linkFiles);
    loadAndRunTests(soPath, module_);
}

private string[] withInferredLinkFiles(
    in string[] linkFiles,
    in string[] sourceImportPaths,
) @safe {
    string[] ret = linkFiles.dup;
    bool[string] seen;

    foreach (linkFile; ret)
        seen[linkFile] = true;

    foreach (importPath; sourceImportPaths) {
        const linkFile = importPath.linkFileForImportPath;
        if (linkFile.length == 0 || linkFile in seen)
            continue;

        seen[linkFile] = true;
        ret ~= linkFile;
    }

    return ret;
}

private string linkFileForImportPath(in string importPath) @safe {
    import std.file: exists;
    import std.path: baseName, buildPath, dirName;

    const rootDir = importPath.importPackageRoot;
    const rootName = rootDir.baseName;
    const sourceDir = importPath.dirName;
    const sourceName = sourceDir.baseName;
    const packageDir = sourceDir.dirName;
    const packageName = packageDir.baseName;

    const candidates = [
        buildPath(rootDir, "lib" ~ rootName ~ ".a"),
        buildPath(rootDir, "bin", "lib" ~ rootName ~ ".a"),
        buildPath(sourceDir, "lib" ~ sourceName ~ ".a"),
        buildPath(sourceDir, "bin", "lib" ~ sourceName ~ ".a"),
        buildPath(sourceDir, "lib" ~ packageName ~ "_" ~ sourceName ~ ".a"),
        buildPath(packageDir, "lib" ~ packageName ~ ".a"),
        buildPath(packageDir, "bin", "lib" ~ packageName ~ ".a"),
    ];

    foreach (candidate; candidates)
        if (candidate.exists)
            return candidate;

    foreach (candidate; rootDir.libraryFiles)
        return candidate;

    foreach (candidate; buildPath(rootDir, "bin").libraryFiles)
        return candidate;

    foreach (candidate; packageDir.libraryFiles)
        return candidate;

    foreach (candidate; buildPath(packageDir, "bin").libraryFiles)
        return candidate;

    return "";
}

private string[] codegenSourceImportPaths(in string[] importPaths) @safe {
    string[] ret;

    foreach (importPath; importPaths) {
        if (importPath.linkFileForImportPath.length != 0)
            continue;

        ret ~= importPath;
    }

    return ret;
}

private string[] libraryFiles(in string dir) @trusted {
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: dirEntries, exists, SpanMode;

    if (!dir.exists)
        return [];

    auto files = dirEntries(dir, "lib*.a", SpanMode.shallow)
        .array;
    files.sort!((a, b) => a.name < b.name);

    string[] ret;
    foreach (file; files)
        ret ~= file.name;
    return ret;
}

// Link-order forcing mechanism: this intentionally-unused local import pulls
// dmd.lib into the link before the frontend library so the linker can resolve
// the Library.factory and Library.setFilename references that
// dmd.glue.generateCodeAndWrite makes when writeLibrary=true. We always pass
// writeLibrary=false, so these paths are unreachable at runtime, but the
// symbols must be present for static linking.
private void anchorDmdLibLinkOrder() @safe @nogc nothrow pure {
    import dmd.lib: Library;

    alias LinkAnchor = Library;
    static assert(is(LinkAnchor));
}

private void ensureBackendInit() @trusted {
    import dmd.dmsc: backend_init;
    import dmd.dmdparams: DMDparams, PIC;
    import dmd.glue: ObjcGlue_initialize;
    import dmd.globals: global;
    import dmd.target: target;

    anchorDmdLibLinkOrder;

    if (_backendInit)
        return;

    DMDparams driverParams;
    driverParams.pic = PIC.pic;
    backend_init(global.params, driverParams, target);
    ObjcGlue_initialize;
    _backendInit = true;
}

private GeneratedObjects generateObjs(
    imported!"dmd.dmodule".Module module_,
    in string tmpDir,
    in string[] sourceImportPaths,
    in uint idx,
) @trusted {
    import dmd.dmodule: Module;
    import dmd.glue: bzeroSymbol, generateCodeAndWrite;
    import dmd.globals: global;
    import dmd.root.filename: FileName;
    import std.conv: text;
    import std.path: buildPath;

    // Ensure the current fixture and its support module are semantically
    // analysed before codegen.
    auto fixtureModules = collectSourceModules(module_, sourceImportPaths.codegenSourceImportPaths);
    fixtureModules ~= dmdCodegenSupportModule(idx);
    semantic3Dependencies(fixtureModules);
    throwIfDmdErrors;

    // Run codegen over every parsed module that is not provided by a linked
    // archive.  The current fixture is always compiled explicitly.  Fixture
    // modules that are not accumulated yet are compiled once to emit shared
    // cross-fixture symbols; imported package modules are compiled when they
    // are not already provided by a linked archive.
    imported!"dmd.dmodule".Module[] modules;
    bool[void*] addedModules;
    void addModule(imported!"dmd.dmodule".Module m) {
        if (!m)
            return;
        const key = cast(void*) m;
        if (key in addedModules)
            return;
        addedModules[key] = true;
        modules ~= m;
    }
    addModule(module_);
    // Add backend runtime support modules (core.internal.newaa etc.) — these
    // are the non-archive modules that fixtureModules collected as support.
    foreach (m; fixtureModules)
        if (m !is module_)
            addModule(m);
    foreach (m; Module.amodules)
        if (!m.isUnitThreadedModule
            && !m.isArchiveBackedModule(sourceImportPaths)
            && (m.isUnaccumulatedSnippetSourceFile
                || m.isUnderAnyImportPackageRoot(sourceImportPaths)))
            addModule(m);
    resetObjState(modules);

    string[] objPaths;
    foreach (moduleIdx, currentModule; modules) {
        const objPath = buildPath(tmpDir, text("module_", moduleIdx, ".o"));
        currentModule.objfile = FileName(objPath);
        objPaths ~= objPath;
    }

    const allInst = global.params.allInst;
    scope(exit) global.params.allInst = allInst;
    global.params.allInst = true;
    foreach (currentModule; modules) {
        // DMD's backend keeps the generated zero-initializer helper in this
        // process-global. If it points at a symbol from an earlier object,
        // codegen can emit another `__bzeroBytes` with incompatible size and
        // the linker rejects the object set before the unittest can run.
        bzeroSymbol = null;
        generateCodeAndWrite([currentModule], [], "", "", false, true, true, false, false);
        throwIfDmdErrors;
    }

    return GeneratedObjects(objPaths, modules);
}

private void generateObjectFiles(imported!"dmd.dmodule".Module[] modules) @trusted {
    import dmd.glue: generateCodeAndWrite;

    enum noPrebuiltObjectsOrLibraries = (const(char)*[]).init;
    enum noLibraryName = "";
    enum currentObjectDirectory = "";
    enum writeObjectFiles = true;
    enum doNotWriteLibrary = false;
    enum oneObjectFilePerModule = false;
    enum doNotSplitSymbolsIntoSeparateObjects = false;
    enum doNotPrintCodegenProgress = false;

    generateCodeAndWrite(
        modules,
        noPrebuiltObjectsOrLibraries,
        noLibraryName,
        currentObjectDirectory,
        doNotWriteLibrary,
        writeObjectFiles,
        oneObjectFilePerModule,
        doNotSplitSymbolsIntoSeparateObjects,
        doNotPrintCodegenProgress,
    );
}

private imported!"dmd.dmodule".Module dmdCodegenSupportModule(in uint idx) @trusted {
    import dmd.frontend: parseModule;
    import std.conv: text;

    const moduleName = text("quickbite_dmd_codegen_support_", idx);
    const source = text(
        "module ", moduleName, ";\n",
        q{
            // The generated test objects reference a small set of Phobos and
            // druntime template symbols by their ABI names. Importing the real
            // modules here would instantiate weak template bodies in every
            // in-process DMD codegen run; DMD keeps enough object state alive
            // that later links can then see duplicate or stale definitions.
            //
            // These declarations are the narrow link-time contract we need
            // instead. If one is missing, `dmd -shared -L=-z -L=defs` fails
            // the link with an undefined reference before `dlopen` can load
            // the generated unittest library. The `pragma(mangle, ...)` names
            // are the exact symbols emitted by the compiled tests.
            struct SupportAppenderString {
                void* data;
            }

            struct SupportIotaUbyte {
                ubyte current;
                ubyte end;
            }

            // Const delegate TypeInfo points at the mutable initializer by ABI
            // name, but codegen does not always emit that mutable initializer
            // in the generated modules. Without this declaration, the shared
            // library has an unresolved TypeInfo back-reference at link time.
            pragma(mangle, "_D25TypeInfo_DFNaNbNiNfMKxiZm6__initZ")
            __gshared void*[3] intDelegateTypeInfoInit;

            // These mutable array TypeInfo initializers are referenced by
            // const-array TypeInfo. They are data symbols, not callable
            // helpers, so a minimal storage declaration is enough to satisfy
            // the link without pulling in druntime's full TypeInfo emission.
            pragma(mangle, "_D13TypeInfo_AxAi6__initZ")
            __gshared void*[3] constIntArrayTypeInfoInit;

            pragma(mangle, "_D12TypeInfo_Axt6__initZ")
            __gshared void*[3] constUshortArrayTypeInfoInit;

            // AA construction for `int` keys calls druntime's templated hash
            // helper by this exact ABI name. Importing `core.internal.newaa`
            // would emit more templated support symbols; this shim keeps the
            // dependency local and prevents an undefined `pure_hashOf!(int)`
            // linker error.
            pragma(mangle, "_D4core8internal5newaa__T11pure_hashOfTiZQqFNaNbNiNeMKxiZm")
            ulong pureHashOfInt(scope ref const(int) value)
                @safe @nogc nothrow pure
            {
                return cast(uint) value;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAiZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderIntArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAgZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderByteArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAsZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderShortArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAtZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderUshortArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAkZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderUintArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAlZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderLongArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAmZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderUlongArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAfZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderFloatArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAdZQn4Data9__xtoHashFNbNeKxSQBzQBy__TQBvTQBpZQCdQBrZm")
            ulong appenderDoubleArrayDataHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAiZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderIntArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAgZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderByteArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAsZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderShortArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAtZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderUshortArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAkZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderUintArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAlZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderLongArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAmZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderUlongArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAfZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderFloatArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__T8AppenderTAdZQn4Data11__xopEqualsMxFKxSQCaQBz__TQBwTQBqZQCeQBsZb")
            bool appenderDoubleArrayDataEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D3std5array__TQjTAiZQpFNaNbNfQmZQp")
            int[] arrayIntArray(int[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAAiZQqFNaNbNfQnZQq")
            int[][] arrayIntArrayArray(int[][] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAtZQpFNaNbNfQmZQp")
            ushort[] arrayUshortArray(ushort[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAhZQpFNaNbNfQmZQp")
            ubyte[] arrayUbyteArray(ubyte[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAfZQpFNaNbNfQmZQp")
            float[] arrayFloatArray(float[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAdZQpFNaNbNfQmZQp")
            double[] arrayDoubleArray(double[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAlZQpFNaNbNfQmZQp")
            long[] arrayLongArray(long[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAS5tests6nested6NestedZQBjFNaNbNfQBhZQBl")
            NestedNested[] arrayNestedNestedArray(NestedNested[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAS5tests6nested10SomeStructZQBoFNaNbNfQBmZQBq")
            NestedSomeStruct[] arrayNestedSomeStructArray(NestedSomeStruct[] value)
                @safe @nogc nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D3std5array__TQjTAaZQpFNaNbNfMQnZAw")
            dchar[] arrayCharArray(scope char[] value)
                @safe @nogc nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D3std5array__TQjTSQr5range__T4iotaThThZQkFhhZ6ResultZQBwFNaNbNfQBuZAh")
            ubyte[] arrayIotaUbyte(SupportIotaUbyte value)
            {
                ubyte[] ret;
                foreach (item; value.current .. value.end)
                    ret ~= item;
                return ret;
            }

            pragma(mangle, "_D3std5array__TQjTS5tests5range12MyInputRangeZQBoFQBgZAh")
            ubyte[] arrayMyInputRange()
            {
                return [9, 7, 6];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTtZQmFNaNbNiNfMKANgtZv")
            void popFrontUshort(scope ref inout(ushort)[] value)
                @safe @nogc nothrow pure
            {
                value = value[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTtZQjFNaNbNcNdNiNfNkMANgtZNgt")
            ref inout(ushort) frontUshort(return scope inout(ushort)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTS5tests6nested6NestedZQBgFNaNbNiNfMKANgSQBnQBkQBgZv")
            void popFrontNestedNested(scope ref inout(NestedNested)[] value)
                @safe @nogc nothrow pure
            {
                value = value[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTS5tests6nested6NestedZQBdFNaNbNcNdNiNfNkMANgSQBsQBpQBlZNgQn")
            ref inout(NestedNested) frontNestedNested(return scope inout(NestedNested)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTS5tests6nested10SomeStructZQBlFNaNbNiNfMKANgSQBsQBpQBlZv")
            void popFrontNestedSomeStruct(scope ref inout(NestedSomeStruct)[] value)
                @safe @nogc nothrow pure
            {
                value = value[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTS5tests6nested10SomeStructZQBiFNaNbNcNdNiNfNkMANgSQBxQBuQBqZNgQn")
            ref inout(NestedSomeStruct) frontNestedSomeStruct(return scope inout(NestedSomeStruct)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTfZQmFNaNbNiNfMKANgfZv")
            void popFrontFloat(scope ref inout(float)[] value)
                @safe @nogc nothrow pure
            {
                value = value[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTfZQjFNaNbNcNdNiNfNkMANgfZNgf")
            ref inout(float) frontFloat(return scope inout(float)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTdZQmFNaNbNiNfMKANgdZv")
            void popFrontDouble(scope ref inout(double)[] value)
                @safe @nogc nothrow pure
            {
                value = value[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTdZQjFNaNbNcNdNiNfNkMANgdZNgd")
            ref inout(double) frontDouble(return scope inout(double)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTlZQmFNaNbNiNfMKANglZv")
            void popFrontLong(scope ref inout(long)[] value)
                @safe @nogc nothrow pure
            {
                value = value[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTlZQjFNaNbNcNdNiNfNkMANglZNgl")
            ref inout(long) frontLong(return scope inout(long)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTAiZQnFNaNbNiNfMKANgAiZv")
            void popFrontIntArray(scope ref inout(int[])[] value)
                @safe @nogc nothrow pure
            {
                value = value[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTAiZQkFNaNbNcNdNiNfNkMANgAiZNgQf")
            ref inout(int[]) frontIntArrayArray(return scope inout(int[])[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAtZQkFNaNbNdNiNfMKQsZb")
            bool emptyUshortArray(scope ref ushort[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAdZQkFNaNbNdNiNfMKQsZb")
            bool emptyDoubleArray(scope ref double[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAAiZQlFNaNbNdNiNfMKQtZb")
            bool emptyIntArrayArray(scope ref int[][] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAfZQkFNaNbNdNiNfMKQsZb")
            bool emptyFloatArray(scope ref float[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAlZQkFNaNbNdNiNfMKQsZb")
            bool emptyLongArray(scope ref long[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D4core8internal5array7casting__T11__ArrayCastTvTsZQsFNaNbNiNeNkMAvZAs")
            short[] arrayCastVoidShort(return scope void[] value)
                @trusted @nogc nothrow pure
            {
                return cast(short[]) value;
            }

            pragma(mangle, "_D4core8internal5array7casting__T11__ArrayCastTvTtZQsFNaNbNiNeNkMAvZAt")
            ushort[] arrayCastVoidUshort(return scope void[] value)
                @trusted @nogc nothrow pure
            {
                return cast(ushort[]) value;
            }

            pragma(mangle, "_D4core8internal5array7casting__T11__ArrayCastTvTiZQsFNaNbNiNeNkMAvZAi")
            int[] arrayCastVoidInt(return scope void[] value)
                @trusted @nogc nothrow pure
            {
                return cast(int[]) value;
            }

            pragma(mangle, "_D4core8internal5array7casting__T11__ArrayCastTvTfZQsFNaNbNiNeNkMAvZAf")
            float[] arrayCastVoidFloat(return scope void[] value)
                @trusted @nogc nothrow pure
            {
                return cast(float[]) value;
            }

            pragma(mangle, "_D4core8internal5array7casting__T11__ArrayCastTvTdZQsFNaNbNiNeNkMAvZAd")
            double[] arrayCastVoidDouble(return scope void[] value)
                @trusted @nogc nothrow pure
            {
                return cast(double[]) value;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAxtZQlFNaNbNdNiNfMKQtZb")
            bool emptyConstUshortArray(scope ref const(ushort)[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            struct NestedNested {
                void* aa;
            }

            struct NestedSomeStruct {
                string[] str;
                int[][] ints;
                NestedNested[] nesteds;
            }

            __gshared int[1] nestedNestedIntKeys = [7];
        },
        nestedNestedTypeInfoInitDefinitions(idx),
        nestedNestedAaLengthDefinitions(idx),
        q{

            pragma(mangle, "_D3std5range__T4iotaThZQiFNaNbNiNfhZSQBjQBi__TQBfThThZQBnFhhZ6Result")
            SupportIotaUbyte iotaUbyte(ubyte end)
            {
                return SupportIotaUbyte(0, end);
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTS5tests12static_array17__unittest_L27_C1FZ4UnitZQCdFNaNbNcNdNiNfNkMANgSQCsQCpQCeFZQBoZNgQs")
            ref inout(ubyte) frontStaticArrayUnit(return scope inout(ubyte)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTS5tests12static_array17__unittest_L27_C1FZ4UnitZQCgFNaNbNiNfMKANgSQCnQCkQBzFZQBjZv")
            void popFrontStaticArrayUnit(scope ref SupportArray value)
                @safe @nogc nothrow pure
            {
                if (value.length != 0)
                    --value.length;
            }

            pragma(mangle, "_D5tests12static_array17__unittest_L27_C1FZ4Unit9__xtoHashFNbNeKxSQCmQCjQByFZQBiZm")
            ulong staticArrayUnitHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D5tests12static_array17__unittest_L27_C1FZ4Unit11__xopEqualsMxFKxSQCnQCkQBzFZQBjZb")
            bool staticArrayUnitEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D4core8internal5array8equality__T8__equalsTxS5tests12static_array17__unittest_L27_C1FZ4UnitTxQBxZQCmFNaNbNiNeMAxQCqMQgZb")
            bool arrayEqualityConstStaticArrayUnitArray(SupportArray value, SupportArray expected)
                @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAS5tests6nested10SomeStructZQBjFNaNbNdNiNfMKQBsZb")
            bool emptyNestedSomeStructArray(scope ref NestedSomeStruct[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAS5tests6nested6NestedZQBeFNaNbNdNiNfMKQBnZb")
            bool emptyNestedNestedArray(scope ref NestedNested[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAxS5tests6nested6NestedZQBfFNaNbNdNiNfMKQBoZb")
            bool emptyConstNestedNestedArray(scope ref const(NestedNested)[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAxS5tests12static_array17__unittest_L27_C1FZ4UnitZQCfFNaNbNdNiNfMKQCoZb")
            bool emptyConstStaticArrayUnitArray(scope ref SupportArray value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAyiZQlFNaNbNdNiNfMKQtZb")
            bool emptyImmutableIntArray(scope ref immutable(int)[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAxS5tests13protocol_unit18__unittest_L169_C1FZ5SmallZQCiFNaNbNdNiNfMKQCrZb")
            bool emptyConstProtocolUnitSmallArray(scope const(void)* value)
                @property @trusted @nogc nothrow pure
            {
                return (*(cast(const(void[])*) value)).length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAxS5tests13protocol_unit18__unittest_L169_C1FZ4UnitZQChFNaNbNdNiNfMKQCqZb")
            bool emptyConstProtocolUnitUnitArray(scope const(void)* value)
                @property @trusted @nogc nothrow pure
            {
                return (*(cast(const(void[])*) value)).length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTS5tests13protocol_unit18__unittest_L169_C1FZ5SmallZQCgFNaNbNcNdNiNfNkMANgSQCvQCsQCgFZQBpZNgQs")
            ref inout(ubyte) frontProtocolUnitSmallArray(return scope inout(ubyte)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            pragma(mangle, "_D3std5range10primitives__T5frontTS5tests13protocol_unit18__unittest_L169_C1FZ4UnitZQCfFNaNbNcNdNiNfNkMANgSQCuQCrQCfFZQBoZNgQs")
            ref inout(ubyte) frontProtocolUnitUnitArray(return scope inout(ubyte)[] value)
                @property @safe @nogc nothrow pure
            {
                return value[0];
            }

            struct SupportArray {
                void* ptr;
                size_t length;
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTS5tests13protocol_unit18__unittest_L169_C1FZ5SmallZQCjFNaNbNiNfMKANgSQCqQCnQCbFZQBkZv")
            void popFrontProtocolUnitSmallArray(scope ref SupportArray value)
                @safe @nogc nothrow pure
            {
                if (value.length != 0)
                    --value.length;
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTS5tests13protocol_unit18__unittest_L169_C1FZ4UnitZQCiFNaNbNiNfMKANgSQCpQCmQCaFZQBjZv")
            void popFrontProtocolUnitUnitArray(scope ref SupportArray value)
                @safe @nogc nothrow pure
            {
                if (value.length != 0)
                    --value.length;
            }

            pragma(mangle, "_D4core8internal5array8equality__T8__equalsTxS5tests13protocol_unit18__unittest_L169_C1FZ4UnitTxQBzZQCoFNaNbNiNeMAxQCsMQgZb")
            bool arrayEqualityConstProtocolUnitUnitArray(scope const(void)* value, scope const(void)* expected)
                @trusted @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTS13unit_threaded10randomized3gen__T3GenTAdVmi1Vmi1024ZQtZQCmFNaNbNdNiNfMKQCvZb")
            bool emptyRandomizedDoubleArrayGen(scope const(void)* value)
                @property @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTS13unit_threaded10randomized3gen__T3GenTAlVmi1Vmi1024ZQtZQCmFNaNbNdNiNfMKQCvZb")
            bool emptyRandomizedLongArrayGen(scope const(void)* value)
                @property @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTS13unit_threaded10randomized3gen__T3GenTAfVmi1Vmi1024ZQtZQCmFNaNbNdNiNfMKQCvZb")
            bool emptyRandomizedFloatArrayGen(scope const(void)* value)
                @property @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTS13unit_threaded10randomized3gen__T3GenTAhVmi1Vmi1024ZQtZQCmFNaNbNdNiNfMKQCvZb")
            bool emptyRandomizedUbyteArrayGen(scope const(void)* value)
                @property @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTS13unit_threaded10randomized3gen__T3GenTAiVmi1Vmi1024ZQtZQCmFNaNbNdNiNfMKQCvZb")
            bool emptyRandomizedIntArrayGen(scope const(void)* value)
                @property @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTS13unit_threaded10randomized3gen__T3GenTAtVmi1Vmi1024ZQtZQCmFNaNbNdNiNfMKQCvZb")
            bool emptyRandomizedUshortArrayGen(scope const(void)* value)
                @property @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAxAiZQmFNaNbNdNiNfMKQuZb")
            bool emptyConstIntArrayArray(scope ref const(int[])[] value)
                @property @safe @nogc nothrow pure
            {
                return value.length == 0;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests6nested10SomeStructTQBbZQBtFQBjKQBnAyamZv")
            void shouldEqualNestedSomeStruct(NestedSomeStruct value, ref NestedSomeStruct expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests6nested10SomeStructTQBbZQBtFKQBkKQBoAyamZv")
            void shouldEqualNestedSomeStructRefs(
                ref NestedSomeStruct value,
                ref NestedSomeStruct expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAS5tests6nested10SomeStructTQBcZQBuFNfQBmKQBqAyamZv")
            void shouldEqualNestedSomeStructArray(
                NestedSomeStruct[] value,
                ref NestedSomeStruct[] expected,
                string file,
                ulong line,
            )
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs17ProtoHeaderStructTxSQBkQBhQBcZQCjFNaNfQCdKxQyAyamZv")
            void shouldEqualStructsProtoHeaderStruct(
                void* value,
                void* expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            pragma(mangle, "_D4core8internal5array8equality__T8__equalsTAiTQdZQqFNaNbNiNeMAQtMQeZb")
            bool arrayEqualityIntArrayArray(scope int[][] value, scope int[][] expected)
                @trusted @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D4core8internal5array8equality__T8__equalsTxS5tests6nested6NestedTxQxZQBlFNaNbNiNeMAxQBpMQgZb")
            bool arrayEqualityConstNestedNestedArray(
                scope const(NestedNested)[] value,
                scope const(NestedNested)[] expected,
            )
                @trusted @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D6object__T3dupHTxHiiTiTxiZQqFNaNbNfxQtZHii")
            int[int] objectDupConstIntInt(const(int[int]) value)
                @trusted nothrow pure
            {
                return cast(int[int]) value;
            }

            pragma(mangle, "_D6object__T3dupTiZQhFNaNbNdNfAxiZAi")
            int[] objectDupConstIntArray(const(int)[] value)
                @property @trusted nothrow pure
            {
                return cast(int[]) value;
            }

            pragma(mangle, "_D6object__T3dupTfZQhFNaNbNdNfAxfZAf")
            float[] objectDupConstFloatArray(const(float)[] value)
                @property @trusted nothrow pure
            {
                return cast(float[]) value;
            }

            pragma(mangle, "_D6object__T3dupTdZQhFNaNbNdNfAxdZAd")
            double[] objectDupConstDoubleArray(const(double)[] value)
                @property @trusted nothrow pure
            {
                return cast(double[]) value;
            }

            pragma(mangle, "_D6object__T3dupTlZQhFNaNbNdNfAxlZAl")
            long[] objectDupConstLongArray(const(long)[] value)
                @property @trusted nothrow pure
            {
                return cast(long[]) value;
            }

            pragma(mangle, "_D6object__T3dupTtZQhFNaNbNdNfAxtZAt")
            ushort[] objectDupConstUshortArray(const(ushort)[] value)
                @property @trusted nothrow pure
            {
                return cast(ushort[]) value;
            }

            pragma(mangle, "_D6object__T3dupTAiZQiFNaNbNdNfAQpZQe")
            int[][] objectDupIntArrayArray(int[][] value)
                @property @safe nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D6object__T3dupTS5tests6nested10SomeStructZQBgFNaNbNdNfAQBoZQf")
            NestedSomeStruct[] objectDupNestedSomeStructArray(NestedSomeStruct[] value)
                @property @safe nothrow pure
            {
                return value;
            }

            pragma(mangle, "_D6object__T4keysTS5tests6nested6NestedTiZQBeFNaNbNdNfNgHiSQBoQBlQBhZAi")
            int[] objectKeysNestedNestedInt(inout(NestedNested[int]) value)
                @property @trusted nothrow
            {
                return value.length == 0 ? null : nestedNestedIntKeys[];
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAhTAiZQuFNaNfKQoQnAyamZv")
            void shouldEqualUbyteArrayIntArray(ref ubyte[] value, int[] expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaZQpFNaNbNiNfQpZv")
            void writelnUtString(string arg) @safe @nogc nothrow pure {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAxhZQpFNaNbNiNfQpZv")
            void writelnUtConstUbyteArray(const(ubyte)[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAiZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringIntArray(string arg, ref int[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAbZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringBoolArray(string arg, ref bool[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAgZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringByteArray(string arg, ref byte[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAhZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringUbyteArray(string arg, ref ubyte[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAxhZQtFNaNbNiNfQtQrZv")
            void writelnUtStringConstUbyteArray(string arg, const(ubyte)[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAsZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringShortArray(string arg, ref short[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAkZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringUintArray(string arg, ref uint[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTbZQrFNaNbNiNfQrKbZv")
            void writelnUtStringBool(string arg, ref bool value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTgZQrFNaNbNiNfQrKgZv")
            void writelnUtStringByte(string arg, ref byte value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaThZQrFNaNbNiNfQrKhZv")
            void writelnUtStringUbyte(string arg, ref ubyte value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTsZQrFNaNbNiNfQrKsZv")
            void writelnUtStringShort(string arg, ref short value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTtZQrFNaNbNiNfQrKtZv")
            void writelnUtStringUshort(string arg, ref ushort value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTiZQrFNaNbNiNfQrKiZv")
            void writelnUtStringInt(string arg, ref int value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTkZQrFNaNbNiNfQrKkZv")
            void writelnUtStringUint(string arg, ref uint value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAdZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringDoubleArray(string arg, ref double[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAlZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringLongArray(string arg, ref long[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAmZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringUlongArray(string arg, ref ulong[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTAfZQsFNaNbNiNfQsKQrZv")
            void writelnUtStringFloatArray(string arg, ref float[] value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTlZQrFNaNbNiNfQrKlZv")
            void writelnUtStringLong(string arg, ref long value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTfZQrFNaNbNiNfQrKfZv")
            void writelnUtStringFloat(string arg, ref float value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTmZQrFNaNbNiNfQrKmZv")
            void writelnUtStringUlong(string arg, ref ulong value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTmZQrFNaNbNiNfQrmZv")
            void writelnUtStringUlongValue(string arg, ulong value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded6runner2io__T9writelnUtTAyaTdZQrFNaNbNiNfQrKdZv")
            void writelnUtStringDouble(string arg, ref double value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T7isEqualTAxhTAiZQqFNaNbNiNfMQtMQsZb")
            bool isEqualConstUbyteArrayIntArray(const(ubyte)[] value, int[] expected)
                @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D3std9algorithm9searching__T7canFindZ__TQmTAxhTAiZQwFNaNbNiNfQsMQrZb")
            bool canFindConstUbyteArrayIntArray(const(ubyte)[] value, int[] expected)
                @safe @nogc nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTmTiZQsFNaNfmiAyamZv")
            void shouldEqualUlongInt(ulong value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTmTmZQsFNaNfmmAyamZv")
            void shouldEqualUlongUlong(ulong value, ulong expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTmTmZQsFNaNfmKmAyamZv")
            void shouldEqualUlongUlongRef(ulong value, ref ulong expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTgTiZQsFNaNfgiAyamZv")
            void shouldEqualByteInt(byte value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTgTiZQsFNaNfKgiAyamZv")
            void shouldEqualByteRefInt(ref byte value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTgTgZQsFNaNfgKgAyamZv")
            void shouldEqualByteByte(byte value, ref byte expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualThTiZQsFNaNfhiAyamZv")
            void shouldEqualUbyteInt(ubyte value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualThThZQsFNaNfhKhAyamZv")
            void shouldEqualUbyteUbyte(ubyte value, ref ubyte expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTxhThZQtFNaNfKxhKhAyamZv")
            void shouldEqualConstUbyteUbyte(ref const(ubyte) value, ref ubyte expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTxhTiZQtFNaNfKxhiAyamZv")
            void shouldEqualConstUbyteInt(ref const(ubyte) value, int expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAxhTxAhZQwFNaNfQpKxQoAyamZv")
            void shouldEqualConstUbyteArrayConstUbyteArray(
                const(ubyte)[] value,
                ref const(ubyte)[] expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTxAhTAiZQvFNaNfKxQpQoAyamZv")
            void shouldEqualConstUbyteArrayIntArray(ref const(ubyte)[] value, int[] expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTxtTtZQtFNaNfKxtKtAyamZv")
            void shouldEqualConstUshortUshort(ref const(ushort) value, ref ushort expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTuTiZQsFNaNfuiAyamZv")
            void shouldEqualWcharInt(wchar value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTuTuZQsFNaNfuKuAyamZv")
            void shouldEqualWcharWchar(wchar value, ref wchar expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTwTiZQsFNaNfwiAyamZv")
            void shouldEqualDcharInt(dchar value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTwTwZQsFNaNfwKwAyamZv")
            void shouldEqualDcharDchar(dchar value, ref dchar expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAxhTyAiZQwFNaNfQpKyQoAyamZv")
            void shouldEqualConstUbyteArrayImmutableIntArray(
                const(ubyte)[] value,
                ref immutable(int[]) expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T14shouldNotEqualTPxC5tests8pointers10InnerClassTPCQBeQBbQvZQChFNaNfQByQwAyamZv")
            void shouldNotEqualPointersInnerClass(void* value, void* expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T14shouldNotEqualTxPS5tests8pointers11InnerStructTPSQBfQBcQwZQCiFNaNfKxQCaKQzAyamZv")
            void shouldNotEqualPointersInnerStruct(ref const(void*) value, ref void* expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTsTiZQsFNaNfsiAyamZv")
            void shouldEqualShortInt(short value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTsTiZQsFNaNfKsiAyamZv")
            void shouldEqualShortRefInt(ref short value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTsTsZQsFNaNfsKsAyamZv")
            void shouldEqualShortShort(short value, ref short expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTbTbZQsFNaNfKbbAyamZv")
            void shouldEqualBoolRefBool(ref bool value, bool expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTbTbZQsFNaNfbKbAyamZv")
            void shouldEqualBoolBool(bool value, ref bool expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTfTfZQsFNaNffKfAyamZv")
            void shouldEqualFloatFloat(float value, ref float expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTdTdZQsFNaNfdKdAyamZv")
            void shouldEqualDoubleDouble(double value, ref double expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T12shouldBeTrueTbZQrFNaNfLbAyamZv")
            void shouldBeTrueBool(lazy bool expression, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_1FZ16__lambda_L13_C12FNfbZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyBool(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_2FZ16__lambda_L13_C12FNfgZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyByte(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_3FZ16__lambda_L13_C12FNfhZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyUbyte(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_4FZ16__lambda_L13_C12FNfsZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyShort(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_11FZ16__lambda_L13_C12FNfdZbVii100ZQCvFNfIkAyamZv")
            void checkPropertyDouble(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_6FZ16__lambda_L13_C12FNfiZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyInt(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_19FZ16__lambda_L13_C12FNfAfZbVii100ZQCwFNfIkAyamZv")
            void checkPropertyFloatArray(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_17FZ16__lambda_L13_C12FNfAiZbVii100ZQCwFNfIkAyamZv")
            void checkPropertyIntArray(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_8FZ16__lambda_L13_C12FNflZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyLong(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_9FZ16__lambda_L13_C12FNfmZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyUlong(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_10FZ16__lambda_L13_C12FNffZbVii100ZQCvFNfIkAyamZv")
            void checkPropertyFloat(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_12FZ16__lambda_L13_C12FNfaZbVii100ZQCvFNfIkAyamZv")
            void checkPropertyChar(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_13FZ16__lambda_L13_C12FNfuZbVii100ZQCvFNfIkAyamZv")
            void checkPropertyWchar(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_14FZ16__lambda_L13_C12FNfwZbVii100ZQCvFNfIkAyamZv")
            void checkPropertyDchar(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_15FZ16__lambda_L13_C12FNfAhZbVii100ZQCwFNfIkAyamZv")
            void checkPropertyUbyteArray(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_16FZ16__lambda_L13_C12FNfAtZbVii100ZQCwFNfIkAyamZv")
            void checkPropertyUshortArray(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_18FZ16__lambda_L13_C12FNfAlZbVii100ZQCwFNfIkAyamZv")
            void checkPropertyLongArray(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb20__unittest_L12_C1_20FZ16__lambda_L13_C12FNfAdZbVii100ZQCwFNfIkAyamZv")
            void checkPropertyDoubleArray(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb17__unittest_L18_C7FNfZ16__lambda_L19_C12FNfAhZbVii100ZQCvFNfIkAyamZv")
            void checkPropertyUbyteArrayLengthWidth(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_7FZ16__lambda_L13_C12FNfkZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyUint(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded8property__T5checkS_D5testsQBb19__unittest_L12_C1_5FZ16__lambda_L13_C12FNftZbVii100ZQCuFNfIkAyamZv")
            void checkPropertyUshort(in uint seed, string file, ulong line)
                @safe
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTaTiZQsFNaNfaiAyamZv")
            void shouldEqualCharInt(char value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTaTiZQsFNaNfKaiAyamZv")
            void shouldEqualCharRefInt(ref char value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTaTaZQsFNaNfaKaAyamZv")
            void shouldEqualCharChar(char value, ref char expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTkTiZQsFNaNfkiAyamZv")
            void shouldEqualUintInt(uint value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTkTkZQsFNaNfkKkAyamZv")
            void shouldEqualUintUint(uint value, ref uint expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTiTiZQsFNaNfiiAyamZv")
            void shouldEqualIntInt(int value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTiTiZQsFNaNfiKiAyamZv")
            void shouldEqualIntIntRef(int value, ref int expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTiTiZQsFNaNfKiKiAyamZv")
            void shouldEqualIntRefIntRef(ref int value, ref int expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTiTiZQsFNaNfKiiAyamZv")
            void shouldEqualIntRefInt(ref int value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests12static_array17__unittest_L27_C1FZ6PacketTQByZQCqFNaNfKQClQCoAyamZv")
            void shouldEqualStaticArrayPacket(ref SupportArray value, SupportArray expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs10EnumStructTxSQBdQBaQvZQCbFNaNfQBvKxQxAyamZv")
            void shouldEqualStructsEnumStruct(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs11DummyStructTQBdZQBvFNaNfQBpKQBtAyamZv")
            void shouldEqualStructsDummyStruct(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs12CustomStructTQBeZQBwFNaNfQBqQBtAyamZv")
            void shouldEqualStructsCustomStruct(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs13StringsStructTQBfZQBxFNaNfQBrKQBvAyamZv")
            void shouldEqualStructsStringsStruct(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs14PostBlitStructTQBgZQByFNaNfQBsQBvAyamZv")
            void shouldEqualStructsPostBlitStruct(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs15MqttFixedHeaderTQBhZQBzFNaNfQBtQBwAyamZv")
            void shouldEqualStructsMqttFixedHeader(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests7structs18StructWithNoCerealTQBkZQCcFNaNfQBwQBzAyamZv")
            void shouldEqualStructsStructWithNoCereal(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTlTiZQsFNaNfliAyamZv")
            void shouldEqualLongInt(long value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTlTiZQsFNaNfKliAyamZv")
            void shouldEqualLongRefInt(ref long value, int expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTlTlZQsFNaNflKlAyamZv")
            void shouldEqualLongLong(long value, ref long expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTHiiTQeZQvFNaNfKQpQrAyamZv")
            void shouldEqualIntIntAAs(ref int[int] value, int[int] expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTHiiTQeZQvFNaNfQoQqAyamZv")
            void shouldEqualIntIntAAsValue(int[int] value, int[int] expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTHiiTxHiiZQxFNaNfQqKxQpAyamZv")
            void shouldEqualIntIntAAsConst(int[int] value, ref const(int[int]) expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D6object__T4keysTiTiZQkFNaNbNdNfNgHiiZAi")
            int[] objectKeysIntInt(inout(int[int]) value)
                @safe nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D6object__T4keysTdTiZQkFNaNbNdNfNgHidZAi")
            int[] objectKeysDoubleInt(inout(double[int]) value)
                @safe nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAyaTQeZQvFNaNfKQpQrQtmZv")
            void shouldEqualStringRefString(ref string value, string expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAAyaTQfZQwFNaNfQpQrQsmZv")
            void shouldEqualStringArrayStringArray(string[] value, string[] expected, string file, ulong line)
                @safe nothrow
            {
            }

            struct ProtocolUnitStruct {
                void* ptr;
                size_t length;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAxhTAhZQvFNaNfQoKQnAyamZv")
            void shouldEqualConstUbyteArrayUbyteArray(const(ubyte)[] value, ref ubyte[] expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAxhTyAhZQwFNaNfQpKyQoAyamZv")
            void shouldEqualConstUbyteArrayImmutableUbyteArray(
                const(ubyte)[] value,
                ref immutable(ubyte[]) expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests13protocol_unit18__unittest_L169_C1FZ6StructTQCaZQCsFNaNfKQCnQCqAyamZv")
            void shouldEqualProtocolUnitStruct(
                ref ProtocolUnitStruct value,
                ProtocolUnitStruct expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualThTiZQsFNaNfKhiAyamZv")
            void shouldEqualUbyteRefInt(ref ubyte value, int expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTmTtZQsFNaNfmKtAyamZv")
            void shouldEqualUlongUshort(ulong value, ref ushort expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTtTiZQsFNaNfKtiAyamZv")
            void shouldEqualUshortRefInt(ref ushort value, int expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTtTmZQsFNaNfKtmAyamZv")
            void shouldEqualUshortRefUlong(ref ushort value, ulong expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAiTQdZQuFNaNfKQoQqAyamZv")
            void shouldEqualIntArrayRefIntArray(ref int[] value, int[] expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAiTxAiZQvFNaNfQoKxQoAyamZv")
            void shouldEqualIntArrayConstIntArray(int[] value, ref const(int)[] expected, string file, ulong line)
                @safe pure
            {
            }

            enum EnumsFoo : ubyte {
                bar,
                baz,
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTE5tests5enums17__unittest_L26_C1FZ3FooTQBnZQCfFNaNfQBzQCcAyamZv")
            void shouldEqualEnumsFoo(EnumsFoo value, EnumsFoo expected, string file, ulong line)
                @safe pure
            {
            }

            enum EnumsMyEnum {
                foo,
                bar,
                baz,
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTE5tests5enums6MyEnumTQvZQBmFNaNfQBgQBjAyamZv")
            void shouldEqualEnumsMyEnum(EnumsMyEnum value, EnumsMyEnum expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAhTAiZQuFNaNfQnQmAyamZv")
            void shouldEqualUbyteArrayIntArray(ubyte[] value, int[] expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAxhTAiZQvFNaNfQoQmAyamZv")
            void shouldEqualConstUbyteArrayIntArray(const(ubyte)[] value, int[] expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAxhTxAiZQwFNaNfQpKxQoAyamZv")
            void shouldEqualConstUbyteArrayConstIntArray(
                const(ubyte)[] value,
                const(int)[] expected,
                string file,
                ulong line,
            )
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTAxhTAiZQvFNaNfKQpQnAyamZv")
            void shouldEqualConstUbyteArrayIntArrayRef(ref const(ubyte)[] value, ref int[] expected, string file, ulong line)
                @safe nothrow
            {
            }

            struct EncodeDecodeFoo {
                ushort[] arr;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests13encode_decode18__unittest_L110_C1FZ3FooTQBxZQCpFNaNfQCjKQCnAyamZv")
            void shouldEqualEncodeDecodeFoo(EncodeDecodeFoo value, ref EncodeDecodeFoo expected, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T22shouldThrowWithMessageHTC9ExceptionTAhZQBpFNaNfLQmAyaQdmZv")
            void shouldThrowWithMessageExceptionUbyteArray(
                lazy ubyte[] expression,
                string expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T22shouldThrowWithMessageHTC9ExceptionTAiZQBpFNaNfLQmAyaQdmZv")
            void shouldThrowWithMessageExceptionIntArray(
                lazy int[] expression,
                string expected,
                string file,
                ulong line,
            )
                @safe pure
            {
            }

            struct QuickbiteThrownInfo {
                TypeInfo typeInfo;
                string msg;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC4core9exception10RangeErrorTbZQBuFNaNfLbAyamZxSQDpQDd10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowRangeErrorBool(lazy bool expression, string file, ulong line)
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC4core9exception10RangeErrorTiZQBuFNaNfLiAyamZxSQDpQDd10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowRangeErrorInt(lazy int expression, string file, ulong line)
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC4core9exception10RangeErrorThZQBuFNaNfLhAyamZxSQDpQDd10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowRangeErrorUbyte(lazy ubyte expression, string file, ulong line)
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC4core9exception10RangeErrorTsZQBuFNaNfLsAyamZxSQDpQDd10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowRangeErrorShort(lazy short expression, string file, ulong line)
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC9ExceptionTS5tests6decode18__unittest_L235_C1FZ3FooZQCqFNaNfLQByAyamZxSQEnQEb10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowExceptionDecodeFoo(lazy int expression, string file, ulong line)
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC9ExceptionTE5tests6decode18__unittest_L235_C1FZ3Foo4TypeZQCvFNaNfLQCdAyamZxSQEsQEg10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowExceptionDecodeFooType(lazy int expression, string file, ulong line)
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC8cerealed6cereal15CerealExceptionTS5tests13protocol_unit25PacketWithArrayLengthExprZQDwFNaNfLQChAyamZxSQFtQFh10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowCerealExceptionPacketWithArrayLengthExpr(
                lazy int expression,
                string file,
                ulong line,
            )
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC8cerealed6cereal15CerealExceptionTS5tests13protocol_unit14NegativeStructZQDlFNaNfLQBwAyamZxSQFiQEw10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowCerealExceptionNegativeStruct(
                lazy int expression,
                string file,
                ulong line,
            )
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldThrowHTC5tests7structs15CustomExceptionTSQBhQBe17StructWithPreBlitZQCxFNaNfLQBkAyamZxSQEuQEi10ThrownInfo")
            const(QuickbiteThrownInfo) shouldThrowCustomExceptionStructWithPreBlit(
                lazy int expression,
                string file,
                ulong line,
            )
                @safe pure
            {
                return QuickbiteThrownInfo.init;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T14shouldNotThrowHTC4core9exception10RangeErrorTS8cerealed10cerealiser__T14CerealiserImplTSQBq5range17DynamicArrayRangeZQBvZQEtFNaNfLQDhAyamZv")
            void shouldNotThrowRangeErrorCerealiserImpl(void delegate() expression, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T14shouldNotThrowHTC9ExceptionTdZQBgFNaNfLdAyamZv")
            void shouldNotThrowExceptionDouble(lazy double expression, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T14shouldNotThrowHTC9ExceptionTvZQBgFNaNfLvAyamZv")
            void shouldNotThrowExceptionVoid(lazy void expression, string file, ulong line)
                @safe pure
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTC5tests7classes12DerivedClassTQBeZQBwFQBmKQBqAyamZv")
            void shouldEqualDerivedClass(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTC5tests7classes12DerivedClassTQBeZQBwFQBmQBpAyamZv")
            void shouldEqualDerivedClassValue(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTC5tests7classes15ClassWithStructTQBhZQBzFQBpKQBtAyamZv")
            void shouldEqualClassWithStruct(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D6object__T8opEqualsTxC5tests8pointers10InnerClassTxQBeZQBtFxQBnxQBrZb")
            bool objectOpEqualsConstPointersInnerClass(const(void*) value, const(void*) expected)
                @safe nothrow pure
            {
                return true;
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTxC5tests8pointers10InnerClassTCQBdQBaQuZQCcFKxQBtKQuAyamZv")
            void shouldEqualPointersInnerClass(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTxS5tests8pointers11InnerStructTSQBeQBbQvZQCdFNaNfKxQByKQyAyamZv")
            void shouldEqualPointersInnerStruct(void* value, void* expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D13unit_threaded10assertions__T11shouldEqualTS5tests6decode18__unittest_L262_C1FNfZ9NoDefaultTQBxZQCpFNaNfQCjQCmAyamZv")
            void shouldEqualDecodeNoDefault(ubyte value, ubyte expected, string file, ulong line)
                @safe nothrow
            {
            }

            pragma(mangle, "_D8cerealed6cereal__T5grainTSQBb10cerealiser__T14CerealiserImplTS3std5array__T8AppenderTAhZQnZQBvTiZQDbFNaNbNfKQDfKiZv")
            void grainCerealiserAppenderInt(void* cereal, void* value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D8cerealed6cereal__T5grainTSQBb10cerealiser__T14CerealiserImplTS3std5array__T8AppenderTAhZQnZQBvThZQDbFNaNbNfKQDfKhZv")
            void grainCerealiserAppenderUbyte(void* cereal, void* value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D8cerealed6cereal__T5grainTSQBb10cerealiser__T14CerealiserImplTS3std5array__T8AppenderTAhZQnZQBvTtZQDbFNaNbNfKQDfKtZv")
            void grainCerealiserAppenderUshort(void* cereal, void* value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D8cerealed6cereal__T5grainTSQBb12decerealiser12DecerealiserTtZQBqFNfKQBqKtZv")
            void grainDecerealiserUshort(void* cereal, void* value)
                @safe @nogc nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests7classes11DummyStructTaZQCfFMKxSQDqQDp4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstDummyStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests7structs11DummyStructTaZQCfFMKxSQDqQDp4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstStructsDummyStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests12static_array17__unittest_L27_C1FZ6PacketTaZQDaFMKxSQElQEk4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstStaticArrayPacket()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests12static_array17__unittest_L27_C1FZ4UnitTaZQCyFMKxSQEjQEi4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstStaticArrayUnit()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests7structs13StringsStructTaZQChFMKxSQDsQDr4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstStringsStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests7structs14PostBlitStructTaZQCiFMKxSQDtQDs4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstPostBlitStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests7structs17ProtoHeaderStructTaZQClFMKxSQDwQDv4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstProtoHeaderStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxS5tests7structs18StructWithNoCerealTaZQCmFMKxSQDxQDw4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstStructWithNoCereal()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTxC5tests7classes15ClassWithStructTaZQCjFMKxSQDuQDt4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageConstClassWithStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T22enforceValidFormatSpecTS13unit_threaded10randomized3gen__T3GenTiViN2147483648Vii2147483647ZQBhTaZQDvFMKxSQFgQFf4spec__T10FormatSpecTaZQpZ21__dgliteral_L2877_C70MFNaNbNiNfZAxa")
            const(char)[] formatSpecMessageRandomizedIntGen()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7classes11DummyStructTaZQCyFKQCpKxQBpMKxSQEjQEi4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstDummyStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs11DummyStructTaZQCyFKQCpKxQBpMKxSQEjQEi4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstStructsDummyStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs12CustomStructTaZQCzFKQCqKxQBqMKxSQEkQEj4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstCustomStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxE5tests7structs10EnumStruct4EnumTaZQDcFKQCtKxQBtMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstEnumStructEnum()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs18StructWithNoCerealTaZQDfFKQCwKxQBwMKxSQEqQEp4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstStructWithNoCereal()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTgTaZQBwFKQBnKgMKxSQDeQDd4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageByte()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS5tests7structs18__unittest_L198_C1FZ8MyStructTaZQDpFKQDgKQCgMKxSQEzQEy4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageStructsMyStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTyiTaZQBxFKQBoKyiMKxSQDgQDf4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageImmutableInt()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs10EnumStructTaZQCxFKQCoKxQBoMKxSQEiQEh4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstEnumStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs13StringsStructTaZQDaFKQCrKxQBrMKxSQElQEk4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstStringsStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs14PostBlitStructTaZQDbFKQCsKxQBsMKxSQEmQEl4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstPostBlitStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs15MqttFixedHeaderTaZQDcFKQCtKxQBtMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstMqttFixedHeader()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests7structs17ProtoHeaderStructTaZQDeFKQCvKxQBvMKxSQEpQEo4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstProtoHeaderStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxE5tests7structs8MqttTypeTaZQCuFKQClKxQBlMKxSQEfQEe4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstMqttType()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests12static_array17__unittest_L27_C1FZ6PacketTaZQDtFKQDkKxQCkMKxSQFeQFd4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstStaticArrayPacket()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxS5tests12static_array17__unittest_L27_C1FZ4UnitTaZQDrFKQDiKxQCiMKxSQFcQFb4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstStaticArrayUnit()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxAS5tests12static_array17__unittest_L27_C1FZ4UnitTaZQDsFKQDjKxQCjMKxSQFdQFc4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstStaticArrayUnitArray()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxAhTaZQByFKQBpKxQpMKxSQDiQDh4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstUbyteArray()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T15formatValueImplTSQBw5array__T8AppenderTAyaZQoTxHidTaZQCdFKQBqxQpMKxSQDvQDu4spec__T10FormatSpecTaZQpZ20__dgliteral_L1677_C9MFNaNbNiNfZAxa")
            const(char)[] formatValueImplConstIntDoubleAaMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T15formatValueImplTSQBw5array__T8AppenderTAyaZQoTxHidTaZQCdFKQBqxQpMKxSQDvQDu4spec__T10FormatSpecTaZQpZ20__dgliteral_L1670_C9MFNaNbNiNfZAxa")
            const(char)[] formatValueImplConstIntDoubleAaValueMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTyAaZQoTE5tests7structs10EnumStruct4EnumTaZQDbFKQCsKQBsMKxSQElQEk4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageEnumStructEnum()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTxC5tests7classes15ClassWithStructTaZQDcFKQCtKxQBtMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueMessageConstClassWithStruct()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T15formatValueImplTDFAxaZvTfTaZQBeFKQrxfMKxSQCuQCt4spec__T10FormatSpecTaZQpZ21__dgliteral_L602_C101MFNaNbNfZQDj")
            const(char)[] formatValueImplFloatMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTfVfe0P0VfeFF0AA7A2BF5094CP75ZQBiZQEaFKQDoMxAaQDlQDkZ20__dgliteral_L545_C21MFNaNbNiNfZQFh")
            const(char)[] formattedWriteRandomizedGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTAyaTaZQBcFKQtKQoMKxSQCkQCj4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQDo")
            const(char)[] formatValueStringMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTuZQBdFKQrMxAauZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteWcharMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTAiVmi1Vmi1024ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedIntArrayGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAiVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedIntArrayGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTkVki0Vki4294967295ZQyZQDpFKQDdMxAaQDaQCzZ20__dgliteral_L615_C21MFNaNbNiNfZQEw")
            const(char)[] formattedWriteRandomizedUintGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTkTaZQBaFKQrKkMKxSQChQCg4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQDl")
            const(char)[] formatValueUintMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTaVai0Vai255ZQrTaZQDxFKQDoKQCoMKxSQFhQFg4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedCharGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTbZQhTaZQDnFKQDeKQCeMKxSQExQEw4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedBoolGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTdVde0P0VdeFF0AA7A2BF5094CP75ZQBiTaZQEpFKQEgKQDgMKxSQFzQFy4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedDoubleGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTfVfe0P0VfeFF0AA7A2BF5094CP75ZQBiTaZQEpFKQEgKQDgMKxSQFzQFy4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedFloatGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTgVgN128Vgi127ZQtTaZQDzFKQDqKQCqMKxSQFjQFi4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedByteGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenThVhi0Vhi255ZQrTaZQDxFKQDoKQCoMKxSQFhQFg4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedUbyteGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTsVsN32768Vsi32767ZQxTaZQEdFKQDuKQCuMKxSQFnQFm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedShortGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTtVti0Vti65535ZQtTaZQDzFKQDqKQCqMKxSQFjQFi4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedUshortGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTuVui0Vui65535ZQtTaZQDzFKQDqKQCqMKxSQFjQFi4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedWcharGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTSQBj5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTwVwi0Vwi65535ZQtTaZQDzFKQDqKQCqMKxSQFjQFi4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZAxa")
            const(char)[] formatValueAppenderRandomizedDcharGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTAdVmi1Vmi1024ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedDoubleArrayGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTAfVmi1Vmi1024ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedFloatArrayGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTAhVmi1Vmi1024ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedUbyteArrayGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTAlVmi1Vmi1024ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedLongArrayGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTAtVmi1Vmi1024ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedUshortArrayGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTbZQhTaZQCrFKQCiKQCeMKxSQEbQEa4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFf")
            const(char)[] formatValueRandomizedBoolGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTdVde0P0VdeFF0AA7A2BF5094CP75ZQBiTaZQDtFKQDkKQDgMKxSQFdQFc4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQGh")
            const(char)[] formatValueRandomizedDoubleGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTfVfe0P0VfeFF0AA7A2BF5094CP75ZQBiTaZQDtFKQDkKQDgMKxSQFdQFc4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQGh")
            const(char)[] formatValueRandomizedFloatGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenThVhi0Vhi255ZQrTaZQDbFKQCsKQCoMKxSQElQEk4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFp")
            const(char)[] formatValueRandomizedUbyteGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTiViN2147483648Vii2147483647ZQBhTaZQDsFKQDjKQDfMKxSQFcQFb4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQGg")
            const(char)[] formatValueRandomizedIntGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTkVki0Vki4294967295ZQyTaZQDiFKQCzKQCvMKxSQEsQEr4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFw")
            const(char)[] formatValueRandomizedUintGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTlVlN9223372036854775808Vli9223372036854775807ZQBzTaZQEkFKQEbKQDxMKxSQFuQFt4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQGy")
            const(char)[] formatValueRandomizedLongGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTmVmi0VmN1ZQpTaZQCzFKQCqKQCmMKxSQEjQEi4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFn")
            const(char)[] formatValueRandomizedUlongGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTsVsN32768Vsi32767ZQxTaZQDhFKQCyKQCuMKxSQErQEq4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFv")
            const(char)[] formatValueRandomizedShortGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTtVti0Vti65535ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedUshortGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTwVwi0Vwi65535ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedDcharGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTtVti0Vti65535ZQtTaZQDeFKQCuKQCqMKxSQExQEw4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFgZv")
            void formatObjectRandomizedUshortGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTkVki0Vki4294967295ZQyTaZQDjFKQCzKQCvMKxSQFcQFb4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFlZv")
            void formatObjectRandomizedUintGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTaVai0Vai255ZQrTaZQDcFKQCsKQCoMKxSQEvQEu4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFeZv")
            void formatObjectRandomizedCharGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTdVde0P0VdeFF0AA7A2BF5094CP75ZQBiTaZQDuFKQDkKQDgMKxSQFnQFm4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFwZv")
            void formatObjectRandomizedDoubleGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTfVfe0P0VfeFF0AA7A2BF5094CP75ZQBiTaZQDuFKQDkKQDgMKxSQFnQFm4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFwZv")
            void formatObjectRandomizedFloatGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTgVgN128Vgi127ZQtTaZQDeFKQCuKQCqMKxSQExQEw4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFgZv")
            void formatObjectRandomizedByteGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenThVhi0Vhi255ZQrTaZQDcFKQCsKQCoMKxSQEvQEu4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFeZv")
            void formatObjectRandomizedUbyteGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTiViN2147483648Vii2147483647ZQBhTaZQDtFKQDjKQDfMKxSQFmQFl4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFvZv")
            void formatObjectRandomizedIntGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTlVlN9223372036854775808Vli9223372036854775807ZQBzTaZQElFKQEbKQDxMKxSQGeQGd4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQGnZv")
            void formatObjectRandomizedLongGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTmVmi0VmN1ZQpTaZQDaFKQCqKQCmMKxSQEtQEs4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFcZv")
            void formatObjectRandomizedUlongGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTsVsN32768Vsi32767ZQxTaZQDiFKQCyKQCuMKxSQFbQFa4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFkZv")
            void formatObjectRandomizedShortGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTuVui0Vui65535ZQtTaZQDeFKQCuKQCqMKxSQExQEw4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFgZv")
            void formatObjectRandomizedWcharGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTwVwi0Vwi65535ZQtTaZQDeFKQCuKQCqMKxSQExQEw4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFMQFgZv")
            void formatObjectRandomizedDcharGenMessage(scope const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTaVai0Vai255ZQrTaZQDyFKQDoKQCoMKxSQFrQFq4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedCharGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTdVde0P0VdeFF0AA7A2BF5094CP75ZQBiTaZQEqFKQEgKQDgMKxSQGjQGi4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedDoubleGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTfVfe0P0VfeFF0AA7A2BF5094CP75ZQBiTaZQEqFKQEgKQDgMKxSQGjQGi4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedFloatGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTgVgN128Vgi127ZQtTaZQEaFKQDqKQCqMKxSQFtQFs4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedByteGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenThVhi0Vhi255ZQrTaZQDyFKQDoKQCoMKxSQFrQFq4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedUbyteGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTsVsN32768Vsi32767ZQxTaZQEeFKQDuKQCuMKxSQFxQFw4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedShortGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTtVti0Vti65535ZQtTaZQEaFKQDqKQCqMKxSQFtQFs4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedUshortGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTuVui0Vui65535ZQtTaZQEaFKQDqKQCqMKxSQFtQFs4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedWcharGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D3std6format8internal5write__T12formatObjectTSQBt5array__T8AppenderTAyaZQoTS13unit_threaded10randomized3gen__T3GenTwVwi0Vwi65535ZQtTaZQEaFKQDqKQCqMKxSQFtQFs4spec__T10FormatSpecTaZQpZ18__lambda_L2179_C40MFNaNbNfMAxaZv")
            void formatObjectAppenderRandomizedDcharGenMessage(scope const(char)[] value)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTdVde0P0VdeFF0AA7A2BF5094CP75ZQBi8__mixin28toStringMFNaNbNiNeMDFAxaZvZv")
            void randomizedDoubleGenToString(scope void delegate(const(char)[]) sink)
                @trusted @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTaVai0Vai255ZQr8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedCharGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTfVfe0P0VfeFF0AA7A2BF5094CP75ZQBi8__mixin28toStringMFNaNbNiNeMDFAxaZvZv")
            void randomizedFloatGenToString(scope void delegate(const(char)[]) sink)
                @trusted @nogc nothrow pure
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTgVgN128Vgi127ZQt8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedByteGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenThVhi0Vhi255ZQr8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedUbyteGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTiViN2147483648Vii2147483647ZQBh8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedIntGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTkVki0Vki4294967295ZQy8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedUintGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTlVlN9223372036854775808Vli9223372036854775807ZQBz8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedLongGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTmVmi0VmN1ZQp8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedUlongGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTsVsN32768Vsi32767ZQx8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedShortGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTtVti0Vti65535ZQt8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedUshortGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTuVui0Vui65535ZQt8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedWcharGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D13unit_threaded10randomized3gen__T3GenTwVwi0Vwi65535ZQt8__mixin28toStringMFNeMDFAxaZvZv")
            void randomizedDcharGenToString(scope void delegate(const(char)[]) sink)
                @trusted
            {
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTgVgN128Vgi127ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedByteGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTaVai0Vai255ZQrTaZQDbFKQCsKQCoMKxSQElQEk4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFp")
            const(char)[] formatValueRandomizedCharGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T11formatValueTDFAxaZvTS13unit_threaded10randomized3gen__T3GenTuVui0Vui65535ZQtTaZQDdFKQCuKQCqMKxSQEnQEm4spec__T10FormatSpecTaZQpZ21__dgliteral_L1261_C16MFNaNbNiNfZQFr")
            const(char)[] formatValueRandomizedWcharGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTaZQBdFKQrMxAaaZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteCharMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTaZQBdFKQrMxAaaZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteCharMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTgZQBdFKQrMxAagZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteByteMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTgZQBdFKQrMxAagZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteByteMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaThZQBdFKQrMxAahZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUbyteMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaThZQBdFKQrMxAahZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUbyteMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTiZQBdFKQrMxAaiZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteIntMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTiZQBdFKQrMxAaiZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteIntMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTkZQBdFKQrMxAakZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUintMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTkZQBdFKQrMxAakZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUintMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTlZQBdFKQrMxAalZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteLongMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTmZQBdFKQrMxAamZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUlongMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTsZQBdFKQrMxAasZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteShortMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTsZQBdFKQrMxAasZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteShortMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTtZQBdFKQrMxAatZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUshortMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTuZQBdFKQrMxAauZ20__dgliteral_L545_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteWcharMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTwTwTwZQBhFKQvMxAawwwZ20__dgliteral_L545_C21MFNaNbNiNfZQCk")
            const(char)[] formattedWriteDcharDcharDcharMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTwTwTwZQBhFKQvMxAawwwZ20__dgliteral_L615_C21MFNaNbNiNfZQCk")
            const(char)[] formattedWriteDcharDcharDcharMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTmZQBdFKQrMxAamZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUlongMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTtZQBdFKQrMxAatZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteUshortMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTlZQBdFKQrMxAalZ20__dgliteral_L615_C21MFNaNbNiNfZQCe")
            const(char)[] formattedWriteLongMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTlVlN9223372036854775808Vli9223372036854775807ZQBzZQErFKQEfMxAaQEcQEbZ20__dgliteral_L545_C21MFNaNbNiNfZQFy")
            const(char)[] formattedWriteRandomizedLongGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTmVmi0VmN1ZQpZQDgFKQCuMxAaQCrQCqZ20__dgliteral_L545_C21MFNaNbNiNfZQEn")
            const(char)[] formattedWriteRandomizedUlongGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTsVsN32768Vsi32767ZQxZQDoFKQDcMxAaQCzQCyZ20__dgliteral_L615_C21MFNaNbNiNfZQEv")
            const(char)[] formattedWriteRandomizedShortGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenThVhi0Vhi255ZQrZQDiFKQCwMxAaQCtQCsZ20__dgliteral_L615_C21MFNaNbNiNfZQEp")
            const(char)[] formattedWriteRandomizedUbyteGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTbZQhZQCyFKQCmMxAaQCjQCiZ20__dgliteral_L545_C21MFNaNbNiNfZQEf")
            const(char)[] formattedWriteRandomizedBoolGenMessage()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAdVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedDoubleArrayGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAdVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedDoubleArrayGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAfVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedFloatArrayGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAfVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedFloatArrayGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAhVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedUbyteArrayGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAhVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedUbyteArrayGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAiVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedIntArrayGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAlVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedLongArrayGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAlVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedLongArrayGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAtVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedUshortArrayGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTAtVmi1Vmi1024ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedUshortArrayGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTaVai0Vai255ZQrZQDiFKQCwMxAaQCtQCsZ20__dgliteral_L545_C21MFNaNbNiNfZQEp")
            const(char)[] formattedWriteRandomizedCharGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTaVai0Vai255ZQrZQDiFKQCwMxAaQCtQCsZ20__dgliteral_L615_C21MFNaNbNiNfZQEp")
            const(char)[] formattedWriteRandomizedCharGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTbZQhZQCyFKQCmMxAaQCjQCiZ20__dgliteral_L615_C21MFNaNbNiNfZQEf")
            const(char)[] formattedWriteRandomizedBoolGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTdVde0P0VdeFF0AA7A2BF5094CP75ZQBiZQEaFKQDoMxAaQDlQDkZ20__dgliteral_L545_C21MFNaNbNiNfZQFh")
            const(char)[] formattedWriteRandomizedDoubleGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTdVde0P0VdeFF0AA7A2BF5094CP75ZQBiZQEaFKQDoMxAaQDlQDkZ20__dgliteral_L615_C21MFNaNbNiNfZQFh")
            const(char)[] formattedWriteRandomizedDoubleGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTfVfe0P0VfeFF0AA7A2BF5094CP75ZQBiZQEaFKQDoMxAaQDlQDkZ20__dgliteral_L615_C21MFNaNbNiNfZQFh")
            const(char)[] formattedWriteRandomizedFloatGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTgVgN128Vgi127ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedByteGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTgVgN128Vgi127ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedByteGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenThVhi0Vhi255ZQrZQDiFKQCwMxAaQCtQCsZ20__dgliteral_L545_C21MFNaNbNiNfZQEp")
            const(char)[] formattedWriteRandomizedUbyteGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTiViN2147483648Vii2147483647ZQBhZQDzFKQDnMxAaQDkQDjZ20__dgliteral_L545_C21MFNaNbNiNfZQFg")
            const(char)[] formattedWriteRandomizedIntGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTiViN2147483648Vii2147483647ZQBhZQDzFKQDnMxAaQDkQDjZ20__dgliteral_L615_C21MFNaNbNiNfZQFg")
            const(char)[] formattedWriteRandomizedIntGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTkVki0Vki4294967295ZQyZQDpFKQDdMxAaQDaQCzZ20__dgliteral_L545_C21MFNaNbNiNfZQEw")
            const(char)[] formattedWriteRandomizedUintGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTlVlN9223372036854775808Vli9223372036854775807ZQBzZQErFKQEfMxAaQEcQEbZ20__dgliteral_L615_C21MFNaNbNiNfZQFy")
            const(char)[] formattedWriteRandomizedLongGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTmVmi0VmN1ZQpZQDgFKQCuMxAaQCrQCqZ20__dgliteral_L615_C21MFNaNbNiNfZQEn")
            const(char)[] formattedWriteRandomizedUlongGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTsVsN32768Vsi32767ZQxZQDoFKQDcMxAaQCzQCyZ20__dgliteral_L545_C21MFNaNbNiNfZQEv")
            const(char)[] formattedWriteRandomizedShortGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTtVti0Vti65535ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedUshortGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTtVti0Vti65535ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedUshortGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTuVui0Vui65535ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedWcharGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTuVui0Vui65535ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedWcharGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTwVwi0Vwi65535ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L545_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedDcharGenMessageL545()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D3std6format5write__T14formattedWriteTDFAxaZvTaTAyaTS13unit_threaded10randomized3gen__T3GenTwVwi0Vwi65535ZQtZQDkFKQCyMxAaQCvQCuZ20__dgliteral_L615_C21MFNaNbNiNfZQEr")
            const(char)[] formattedWriteRandomizedDcharGenMessageL615()
                @safe @nogc nothrow pure
            {
                return "";
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTsTsTsZQtFKsKsZ16__lambda_L54_C20MFNaNbNiNeZPSQDgQDeQCy__TQCsTsTsTsZQDcFKsKsZ1S")
            void* emplaceRefShortShortShortPayload()
                @trusted @nogc nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTlTlTlZQtFKlKlZ16__lambda_L54_C20MFNaNbNiNeZPSQDgQDeQCy__TQCsTlTlTlZQDcFKlKlZ1S")
            void* emplaceRefLongLongLongPayload()
                @trusted @nogc nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTlTlTmZQtFKlKmZ16__lambda_L54_C20MFNaNbNiNeZPSQDgQDeQCy__TQCsTlTlTmZQDcFKlKmZ1S")
            void* emplaceRefLongLongUlongPayload()
                @trusted @nogc nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTdTdTmZQtFKdKmZ16__lambda_L54_C20MFNaNbNiNeZPSQDgQDeQCy__TQCsTdTdTmZQDcFKdKmZ1S")
            void* emplaceRefDoubleDoubleUlongPayload()
                @trusted @nogc nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTdTdTmZQtFKdKmZ1S9__xtoHashFNbNeKxSQCvQCtQCn__TQChTdTdTmZQCrFKdKmZQBzZm")
            ulong emplaceRefDoubleDoubleUlongHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTdTdTmZQtFKdKmZ1S11__xopEqualsMxFKxSQCwQCuQCo__TQCiTdTdTmZQCsFKdKmZQCaZb")
            bool emplaceRefDoubleDoubleUlongEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTfTfTmZQtFKfKmZ16__lambda_L54_C20MFNaNbNiNeZPSQDgQDeQCy__TQCsTfTfTmZQDcFKfKmZ1S")
            void* emplaceRefFloatFloatUlongPayload()
                @trusted @nogc nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTfTfTmZQtFKfKmZ1S9__xtoHashFNbNeKxSQCvQCtQCn__TQChTfTfTmZQCrFKfKmZQBzZm")
            ulong emplaceRefFloatFloatUlongHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTfTfTmZQtFKfKmZ1S11__xopEqualsMxFKxSQCwQCuQCo__TQCiTfTfTmZQCsFKfKmZQCaZb")
            bool emplaceRefFloatFloatUlongEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTeTeTmZQtFKeKmZ16__lambda_L54_C20MFNaNbNiNeZPSQDgQDeQCy__TQCsTeTeTmZQDcFKeKmZ1S")
            void* emplaceRefRealRealUlongPayload()
                @trusted @nogc nothrow pure
            {
                return null;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTeTeTmZQtFKeKmZ1S9__xtoHashFNbNeKxSQCvQCtQCn__TQChTeTeTmZQCrFKeKmZQBzZm")
            ulong emplaceRefRealRealUlongHash(scope const(void)* value)
                @trusted nothrow
            {
                return 0;
            }

            pragma(mangle, "_D4core8internal8lifetime__T10emplaceRefTeTeTmZQtFKeKmZ1S11__xopEqualsMxFKxSQCwQCuQCo__TQCiTeTeTmZQCsFKeKmZQCaZb")
            bool emplaceRefRealRealUlongEquals(scope const(void)* value, scope const(void)* expected)
                @trusted nothrow
            {
                return true;
            }

            pragma(mangle, "_D8cerealed10cerealiser__T14CerealiserImplTS3std5array__T8AppenderTAhZQnZQBv__T18registerChildClassTC5tests7classes12DerivedClassZQBzFNfZ17__lambda_L146_C47FNaNbNfKSQGhQGb__TQFsTQFfZQGaC6ObjectZv")
            void registerChildClassDerivedClass(void* cereal, void* object)
                @safe nothrow pure
            {
            }

            pragma(mangle, "_D5tests7classes10DummyClass7__ClassZ")
            __gshared void* dummyClassClassInfo;

            pragma(mangle, "_D3std5range10primitives__T5frontTiZQjFNaNbNcNdNiNfNkMANgiZNgi")
            ref int frontIntArray(ref int[] range)
                @safe @nogc nothrow pure
            {
                return range[0];
            }

            pragma(mangle, "_D3std5range10primitives__T8popFrontTiZQmFNaNbNiNfMKANgiZv")
            void popFrontIntArray(ref int[] range)
                @safe @nogc nothrow pure
            {
                range = range[1 .. $];
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAxiZQlFNaNbNdNiNfMKQtZb")
            bool emptyConstIntArray(ref const(int)[] range)
                @safe @nogc nothrow pure
            {
                return range.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T5emptyTAuZQkFNaNbNdNiNfMQrZb")
            bool emptyWcharArray(wchar[] range)
                @safe @nogc nothrow pure
            {
                return range.length == 0;
            }

            pragma(mangle, "_D3std5range10primitives__T3putTSQBf5array__T8AppenderTAyaZQoTAuZQBmFNaNfKQBqQpZv")
            void putAppenderStringWcharArray(ref SupportAppenderString appender, wchar[] value)
                @safe pure
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTSQBf5array__T8AppenderTAyaZQoTuZQBlFNaNfKQBpuZv")
            void putAppenderStringWchar(ref SupportAppenderString appender, wchar value)
                @safe pure
            {
            }

            pragma(mangle, "_D4core8internal5newaa__T9_newEntryTiTdTiZQrFKiZ16__lambda_L176_C9MFNaNbNiNeZv")
            void newaaNewEntryIntDoubleIntLambda()
                @trusted @nogc nothrow
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTAuZQqFKQpQjZv")
            void putDelegateWcharArray(ref void delegate(const(char)[]) sink, wchar[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTAaZQqFKQpQjZv")
            void putDelegateCharArray(ref void delegate(const(char)[]) sink, char[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTAwZQqFKQpQjZv")
            void putDelegateDcharArray(ref void delegate(const(char)[]) sink, dchar[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTAyaZQrFKQqQkZv")
            void putDelegateString(ref void delegate(const(char)[]) sink, string value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTQgZQqFKQpQpZv")
            void putDelegateConstCharArray(ref void delegate(const(char)[]) sink, const(char)[] value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTaZQpFKQoaZv")
            void putDelegateChar(ref void delegate(const(char)[]) sink, char value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTxaZQqFKQpxaZv")
            void putDelegateConstChar(ref void delegate(const(char)[]) sink, const(char) value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTyaZQqFKQpyaZv")
            void putDelegateImmutableChar(ref void delegate(const(char)[]) sink, immutable(char) value)
                @safe
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTDFAxaZvTxwZQqFKQpxwZv")
            void putDelegateConstDchar(ref void delegate(const(char)[]) sink, const(dchar) value)
                @safe
            {
            }

            pragma(mangle, "_D3std3uni__T14graphemeStrideTuZQtFNaNfMxAumZm")
            ulong graphemeStrideWchar(const(wchar)[] value, ulong index)
                @safe pure
            {
                return 1;
            }

            pragma(mangle, "_D4core8internal5cast___T7_d_castTC5tests7classes12DerivedClassTCQBeQBb9BaseClassZQCfFNaNbNiNeQBeZPv")
            void* castDerivedClassFromBaseClass(void* object)
                @safe @nogc nothrow pure
            {
                return object;
            }

            pragma(mangle, "_D4core8internal5cast___T7_d_castTC5tests7classes12DerivedClassTC6ObjectZQBwFNaNbNiNeQvZPv")
            void* castDerivedClassFromObject(void* object)
                @safe @nogc nothrow pure
            {
                return object;
            }
        },
    );

    auto parsed = parseModule(moduleName ~ ".d", source);
    if (parsed.diagnostics.hasErrors)
        throw new Exception("DMD codegen support module failed to parse.");

    return parsed.module_;
}

private string nestedNestedTypeInfoInitDefinitions(in uint maxIdx) @safe {
    import std.conv: text;

    string ret;
    foreach (idx; 0 .. maxIdx + 1) {
        const moduleName = text("quickbite_dmd_codegen_support_", idx);
        ret ~= text(
            "pragma(mangle, \"", nestedNestedBucketArrayTypeInfoInitMangle(moduleName), "\")\n",
            "__gshared ubyte[1] nestedNestedBucketTypeInfoInit_", idx, ";\n",
            "pragma(mangle, \"", nestedNestedImplFlagsTypeInfoInitMangle(moduleName), "\")\n",
            "__gshared ubyte[1] nestedNestedFlagsTypeInfoInit_", idx, ";\n",
        );
    }

    return ret;
}

private string nestedNestedAaLengthDefinitions(in uint maxIdx) @safe {
    import std.conv: text;

    string ret;
    foreach (idx; 0 .. maxIdx + 1) {
        const moduleName = text("quickbite_dmd_codegen_support_", idx);
        ret ~= text(
            "pragma(mangle, \"", nestedNestedAaLengthMangle(moduleName), "\")\n",
            "size_t nestedNestedAaLength_", idx, "()\n",
            "    @safe @nogc nothrow pure\n",
            "{\n",
            "    return 0;\n",
            "}\n",
        );
    }

    return ret;
}

private string nestedNestedAaLengthMangle(in string moduleName) @safe {
    import std.conv: text;

    const moduleNameLength = text(moduleName.length);
    return text(
        "_D4core8internal5newaa__T4ImplTiTxS",
        moduleNameLength,
        moduleName,
        "12NestedNestedZ",
        nestedNestedImplFlagsTypeInfoBackref(moduleName.length),
        "6lengthMxFNaNbNdNiNfZm",
    );
}

private string nestedNestedBucketArrayTypeInfoInitMangle(in string moduleName) @safe {
    import std.conv: text;

    const moduleNameLength = text(moduleName.length);
    const typeInfoNameLength = text(47 + moduleNameLength.length + moduleName.length + 18);
    return text(
        "_D", typeInfoNameLength,
        "TypeInfo_AxS4core8internal5newaa__T6BucketTiTxS",
        moduleNameLength,
        moduleName,
        "12NestedNestedZ",
        nestedNestedBucketTypeInfoBackref(moduleName.length),
        "6__initZ",
    );
}

private string nestedNestedImplFlagsTypeInfoInitMangle(in string moduleName) @safe {
    import std.conv: text;

    const moduleNameLength = text(moduleName.length);
    const typeInfoNameLength = text(49 + moduleNameLength.length + moduleName.length + 18);
    return text(
        "_D", typeInfoNameLength,
        "TypeInfo_E4core8internal5newaa__T4ImplTiTxS",
        moduleNameLength,
        moduleName,
        "12NestedNestedZ",
        nestedNestedImplFlagsTypeInfoBackref(moduleName.length),
        "5Flags6__initZ",
    );
}

private string nestedNestedBucketTypeInfoBackref(in size_t moduleNameLength) @safe {
    import std.conv: text;

    return text("QC", cast(char) (cast(uint) 'a' + moduleNameLength - 23));
}

private string nestedNestedImplFlagsTypeInfoBackref(in size_t moduleNameLength) @safe {
    import std.conv: text;

    return text("QC", cast(char) (cast(uint) 'a' + moduleNameLength - 25));
}

private void resetObjState(imported!"dmd.dmodule".Module[] modules) @trusted {
    bool[void*] seen;
    resetGlobalObjState(seen);
    foreach (module_; modules)
        resetObjState(module_, seen);
}

private void resetGlobalObjState(
    ref bool[void*] seen,
) @trusted {
    import dmd.dmodule: Module;

    foreach (module_; Module.amodules)
        if (!module_.isUnitThreadedModule)
            resetObjState(module_, seen);
}

private void resetObjState(
    imported!"dmd.dsymbol".Dsymbol symbol,
    ref bool[void*] seen,
) @trusted {
    import dmd.dsymbol: foreachDsymbol, PASS;

    if (!symbol)
        return;

    const key = cast(void*) symbol;
    if (key in seen)
        return;

    seen[key] = true;
    resetBackendSymbol(symbol.csym);
    symbol.csym = null;
    if (symbol.semanticRun > PASS.semantic3done)
        symbol.semanticRun = PASS.semantic3done;

    if (auto declaration = symbol.isDeclaration)
        resetTypeObjState(declaration.type);

    if (auto variable = symbol.isVarDeclaration)
        resetInitializerObjState(variable._init, seen);

    if (auto typeInfo = symbol.isTypeInfoDeclaration) {
        resetTypeObjState(typeInfo.tinfo);
        if (auto typeStruct = typeInfo.tinfo.isTypeStruct)
            resetObjState(typeStruct.sym, seen);
    }

    if (auto aggregate = symbol.isAggregateDeclaration) {
        aggregate.sinit = null;
        resetObjState(aggregate.aggrDtor, seen);
        resetObjState(aggregate.dtor, seen);
        resetObjState(aggregate.tidtor, seen);
        resetObjState(aggregate.fieldDtor, seen);
    }

    if (auto class_ = symbol.isClassDeclaration) {
        if (class_.vtblsym)
            class_.vtblsym.csym = null;
        resetObjState(class_.vclassinfo, seen);
    }

    if (auto struct_ = symbol.isStructDeclaration) {
        resetObjState(struct_.postblit, seen);
        resetObjState(struct_.xeq, seen);
        resetObjState(struct_.xcmp, seen);
        resetObjState(struct_.xhash, seen);
    }

    if (auto templateInstance = symbol.isTemplateInstance)
        templateInstance.restoreTemplateNext;

    if (auto module_ = symbol.isModule)
        resetObjState(module_.decldefs, seen);

    if (auto attribute = symbol.isAttribDeclaration)
        if (attribute.isStorageClassDeclaration
            || attribute.isVisibilityDeclaration
            || attribute.isStaticIfDeclaration)
            resetObjState(attribute.decl, seen);

    if (auto scopeSymbol = symbol.isScopeDsymbol)
        resetObjState(scopeSymbol.members, seen);

    if (auto function_ = symbol.isFuncDeclaration) {
        function_.skipCodegen = false;
        if (auto literal = function_.isFuncLiteralDeclaration)
            literal.deferToObj = false;
        if (auto unitTest = function_.isUnitTestDeclaration)
            unitTest.deferredNested.setDim(0);
        resetObjState(function_.vthis, seen);
        resetObjState(function_.v_arguments, seen);
        resetObjState(function_.v_argptr, seen);
        if (function_.parameters)
            foreach (parameter; *function_.parameters)
                resetObjState(parameter, seen);
        resetFunctionBodyObjState(function_, seen);
    }
}

private void resetInitializerObjState(
    imported!"dmd.init".Initializer initializer,
    ref bool[void*] seen,
) @trusted {
    if (!initializer)
        return;

    if (auto expInitializer = initializer.isExpInitializer) {
        resetExpressionObjState(expInitializer.exp, seen);
    } else if (auto arrayInitializer = initializer.isArrayInitializer) {
        foreach (index; arrayInitializer.index)
            resetExpressionObjState(index, seen);
        foreach (value; arrayInitializer.value)
            resetInitializerObjState(value, seen);
    } else if (auto structInitializer = initializer.isStructInitializer) {
        foreach (value; structInitializer.value)
            resetInitializerObjState(value, seen);
    }
}

private void resetExpressionObjState(
    imported!"dmd.expression".Expression expression,
    ref bool[void*] seen,
) @trusted {
    import dmd.dtemplate: isType;
    import dmd.expression:
        DeclarationExp,
        DsymbolExp,
        Expression,
        FuncExp,
        SymbolExp,
        TypeidExp,
        VarExp;
    import dmd.visitor: StoppableVisitor;
    import dmd.visitor.postorder: walkPostorder;

    if (!expression)
        return;

    extern (C++) final class ResetVisitor : StoppableVisitor {
        alias visit = typeof(super).visit;

        bool[void*]* seen;

        override void visit(Expression expression) {
            resetTypeObjState(expression.type);
        }

        override void visit(DeclarationExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.declaration, *seen);
        }

        override void visit(DsymbolExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.s, *seen);
        }

        override void visit(FuncExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.fd, *seen);
        }

        override void visit(SymbolExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.var, *seen);
        }

        override void visit(TypeidExp expression) {
            resetTypeObjState(expression.type);
            resetTypeObjState(isType(expression.obj));
        }

        override void visit(VarExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.var, *seen);
        }
    }

    scope visitor = new ResetVisitor;
    visitor.seen = &seen;
    walkPostorder(expression, visitor);
}

private void resetFunctionBodyObjState(
    imported!"dmd.func".FuncDeclaration function_,
    ref bool[void*] seen,
) @trusted {
    import dmd.astenums: STMT;
    import dmd.expression: Expression;
    import dmd.statement: Statement;

    void resetExpression(Expression expression) {
        resetExpressionObjState(expression, seen);
    }

    void resetStatement(Statement statement) {
        if (!statement)
            return;

        switch (statement.stmt) {
            case STMT.Exp:
                resetExpression(statement.isExpStatement.exp);
                break;
            case STMT.DtorExp:
                resetExpression(statement.isDtorExpStatement.exp);
                break;
            case STMT.Compound:
                foreach (child; *statement.isCompoundStatement.statements)
                    resetStatement(child);
                break;
            case STMT.CompoundDeclaration:
                foreach (child; *statement.isCompoundDeclarationStatement.statements)
                    resetStatement(child);
                break;
            case STMT.Scope:
                resetStatement(statement.isScopeStatement.statement);
                break;
            case STMT.While:
                resetExpression(statement.isWhileStatement.condition);
                resetStatement(statement.isWhileStatement._body);
                break;
            case STMT.Do:
                resetStatement(statement.isDoStatement._body);
                resetExpression(statement.isDoStatement.condition);
                break;
            case STMT.For:
                resetStatement(statement.isForStatement._init);
                resetExpression(statement.isForStatement.condition);
                resetExpression(statement.isForStatement.increment);
                resetStatement(statement.isForStatement._body);
                break;
            case STMT.If:
                resetExpression(statement.isIfStatement.condition);
                resetStatement(statement.isIfStatement.ifbody);
                resetStatement(statement.isIfStatement.elsebody);
                break;
            case STMT.ScopeGuard:
                resetStatement(statement.isScopeGuardStatement.statement);
                break;
            case STMT.Foreach:
                resetExpression(statement.isForeachStatement.aggr);
                resetStatement(statement.isForeachStatement._body);
                break;
            case STMT.ForeachRange:
                resetExpression(statement.isForeachRangeStatement.lwr);
                resetExpression(statement.isForeachRangeStatement.upr);
                resetStatement(statement.isForeachRangeStatement._body);
                break;
            case STMT.Switch:
                resetExpression(statement.isSwitchStatement.condition);
                resetStatement(statement.isSwitchStatement._body);
                break;
            case STMT.Case:
                resetExpression(statement.isCaseStatement.exp);
                resetStatement(statement.isCaseStatement.statement);
                break;
            case STMT.Default:
                resetStatement(statement.isDefaultStatement.statement);
                break;
            case STMT.Return:
                resetExpression(statement.isReturnStatement.exp);
                break;
            case STMT.With: {
                auto withStatement = statement.isWithStatement;
                resetExpression(withStatement.exp);
                resetObjState(withStatement.wthis, seen);
                resetStatement(withStatement._body);
                break;
            }
            case STMT.TryCatch:
                resetStatement(statement.isTryCatchStatement._body);
                foreach (catch_; *statement.isTryCatchStatement.catches) {
                    resetObjState(catch_.var, seen);
                    resetStatement(catch_.handler);
                }
                break;
            case STMT.TryFinally:
                resetStatement(statement.isTryFinallyStatement._body);
                resetStatement(statement.isTryFinallyStatement.finalbody);
                break;
            case STMT.Throw:
                resetExpression(statement.isThrowStatement.exp);
                break;
            case STMT.Label:
                resetStatement(statement.isLabelStatement.statement);
                break;
            case STMT.Debug:
                resetStatement(statement.isDebugStatement.statement);
                break;
            case STMT.Forwarding:
                resetStatement(statement.isForwardingStatement.statement);
                break;
            case STMT.UnrolledLoop:
                foreach (child; *statement.isUnrolledLoopStatement.statements)
                    resetStatement(child);
                break;
            default:
                break;
        }
    }

    if (!function_.fbody)
        return;

    resetStatement(function_.fbody);
}

private void resetBackendSymbol(void* csym) @trusted {
    import dmd.backend.cc: Symbol;
    import dmd.backend.symbol: symbol_reset;
    import dmd.backend.symtab: SYMIDX;

    if (!csym)
        return;

    auto symbol = cast(Symbol*) csym;
    // DMD caches backend symbols on frontend declarations after object
    // generation. Reusing those symbols in the next in-process codegen pass
    // makes the backend believe it already owns an object-file symbol number,
    // which can produce stale references or duplicate emitted definitions.
    symbol_reset(*symbol);
    symbol.Ssymnum = SYMIDX.max;
}

private void resetTypeObjState(imported!"dmd.mtype".Type type) @trusted {
    if (!type)
        return;

    bool[void*] seen;
    resetTypeObjState(type, seen);
    bool[void*] typesSeen;
    resetTypeAggregateInitializers(type, typesSeen);
}

private void resetTypeObjState(
    imported!"dmd.mtype".Type type,
    ref bool[void*] seen,
) @trusted {
    if (!type)
        return;

    const key = cast(void*) type;
    if (key in seen)
        return;

    import dmd.dsymbol: PASS;

    seen[key] = true;
    if (auto typeInfo = type.vtinfo) {
        resetBackendSymbol(typeInfo.csym);
        typeInfo.csym = null;
        // TypeInfo declarations may be floating (not in any module's members),
        // so resetObjState won't visit them. Reset semanticRun here so
        // toObjFile re-emits instead of short-circuiting on PASS.obj.
        if (typeInfo.semanticRun > PASS.semantic3done)
            typeInfo.semanticRun = PASS.semantic3done;
    }

    if (!type.isTypeAArray)
        type.vtinfo = null;
    type.ctype = null;

    resetTypeObjState(type.nextOf, seen);
    if (auto associative = type.isTypeAArray)
        resetTypeObjState(associative.index, seen);
    if (auto funcType = type.isTypeFunction)
        if (funcType.parameterList.parameters)
            foreach (param; *funcType.parameterList.parameters)
                if (param)
                    resetTypeObjState(param.type, seen);
}

private void resetTypeAggregateInitializers(
    imported!"dmd.mtype".Type type,
    ref bool[void*] typesSeen,
) @trusted {
    if (!type)
        return;

    const key = cast(void*) type;
    if (key in typesSeen)
        return;

    typesSeen[key] = true;

    if (auto typeStruct = type.isTypeStruct)
        resetBzeroInitializer(typeStruct.sym.sinit);
    if (auto typeClass = type.isTypeClass)
        resetBzeroInitializer(typeClass.sym.sinit);
    if (auto typeEnum = type.isTypeEnum)
        resetBzeroInitializer(typeEnum.sym.sinit);

    resetTypeAggregateInitializers(type.nextOf, typesSeen);
    if (auto associative = type.isTypeAArray)
        resetTypeAggregateInitializers(associative.index, typesSeen);
}

private void resetBzeroInitializer(ref void* initializer) @trusted {
    import core.stdc.string: strcmp;
    import dmd.backend.cc: Symbol;

    if (!initializer)
        return;

    auto symbol = cast(Symbol*) initializer;
    // Aggregate default initializers can cache the backend's zero-fill helper.
    // If the next generated object reuses that cached `__bzeroBytes`, the
    // linker may see two weak symbols with different sizes and reject the
    // shared library before the generated unittest can be loaded.
    if (strcmp(symbol.Sident.ptr, "__bzeroBytes") == 0)
        initializer = null;
}

private void resetObjState(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref bool[void*] seen,
) @trusted {
    import dmd.dsymbol: foreachDsymbol;

    foreachDsymbol(symbols, (symbol) => resetObjState(symbol, seen));
}

private void restoreTemplateNext(
    imported!"dmd.dtemplate".TemplateInstance templateInstance,
) @trusted {
    const key = cast(void*) templateInstance;
    if (templateInstance.tnext) {
        if (key !in _templateNextByInstance)
            _templateNextByInstance[key] = templateInstance.tnext;
        return;
    }

    if (auto next = key in _templateNextByInstance)
        templateInstance.tnext = *next;
}

private void throwIfDmdErrors() @trusted {
    import dmd.errors: diagnostics, ErrorKind;
    import dmd.globals: global;
    import std.algorithm.iteration: filter, map;
    import std.array: array, join;

    if (global.errors == 0)
        return;

    const messages = diagnostics
        .filter!(diagnostic => diagnostic.kind == ErrorKind.error)
        .map!(diagnostic => diagnostic.message)
        .array;

    if (messages.length == 0)
        throw new Exception("DMD codegen failed without a diagnostic message.");

    throw new Exception(messages.join("\n"));
}

private imported!"dmd.dmodule".Module[] collectSourceModules(
    imported!"dmd.dmodule".Module root,
    in string[] sourceImportPaths,
) @trusted {
    import dmd.dmodule: Module;

    Module[] modules;
    bool[void*] seen;

    collectSourceModule(root, root, sourceImportPaths, modules, seen, true);
    collectBackendRuntimeSupportModules(modules, seen);
    return modules;
}

private void collectBackendRuntimeSupportModules(
    ref imported!"dmd.dmodule".Module[] modules,
    ref bool[void*] seen,
) @trusted {
    auto sourceModules = modules.dup; // const fails: DMD Module handles are mutated downstream.
    bool[void*] visited;

    foreach (module_; sourceModules)
        collectBackendRuntimeSupportImports(module_, modules, seen, visited);
    collectGlobalBackendRuntimeSupportModules(modules, seen);
}

private void collectGlobalBackendRuntimeSupportModules(
    ref imported!"dmd.dmodule".Module[] modules,
    ref bool[void*] seen,
) @trusted {
    import dmd.dmodule: Module;

    foreach (module_; Module.amodules) {
        if (!module_.isGlobalBackendRuntimeSupportModule)
            continue;

        const key = cast(void*) module_;
        if (key in seen)
            continue;

        seen[key] = true;
        modules ~= module_;
    }
}

private void collectBackendRuntimeSupportImports(
    imported!"dmd.dmodule".Module module_,
    ref imported!"dmd.dmodule".Module[] modules,
    ref bool[void*] seen,
    ref bool[void*] visited,
) @trusted {
    if (!module_ || module_.isUnitThreadedModule)
        return;

    const visitedKey = cast(void*) module_;
    if (visitedKey in visited)
        return;

    visited[visitedKey] = true;
    foreach (importedModule; module_.aimports) {
        if (!importedModule || importedModule.isUnitThreadedModule)
            continue;

        if (!importedModule.isBackendRuntimeSupportModule)
            continue;

        const key = cast(void*) importedModule;
        if (!(key in seen)) {
            seen[key] = true;
            modules ~= importedModule;
        }
        collectBackendRuntimeSupportImports(importedModule, modules, seen, visited);
    }
}

private void collectSourceModule(
    imported!"dmd.dmodule".Module root,
    imported!"dmd.dmodule".Module module_,
    in string[] sourceImportPaths,
    ref imported!"dmd.dmodule".Module[] modules,
    ref bool[void*] seen,
    in bool isRoot,
) @trusted {
    if (!module_)
        return;

    const key = cast(void*) module_;
    if (key in seen)
        return;

    if (!isRoot && !module_.shouldCompileImportedSource(sourceImportPaths))
        return;

    seen[key] = true;
    modules ~= module_;
    foreach (importedModule; module_.aimports)
        collectSourceModule(root, importedModule, sourceImportPaths, modules, seen, false);
}

private bool shouldCompileImportedSource(
    imported!"dmd.dmodule".Module module_,
    in string[] sourceImportPaths,
) @trusted {
    import std.path: absolutePath, buildNormalizedPath;

    const path = module_.srcfile.toString.idup.absolutePath.buildNormalizedPath;
    foreach (importPath; sourceImportPaths) {
        const importPathAbs = importPath.absolutePath.buildNormalizedPath;
        if (!path.isUnderPath(importPathAbs))
            continue;

        if (module_.isUnitThreadedModule)
            return false;

        return true;
    }

    return false;
}

private bool isUnitThreadedModule(imported!"dmd.dmodule".Module module_) @trusted {
    import std.algorithm.searching: startsWith;
    import std.string: fromStringz;

    const name = module_.toPrettyChars.fromStringz;
    return name == "unit_threaded" || name.startsWith("unit_threaded.");
}

private bool isBackendRuntimeSupportModule(imported!"dmd.dmodule".Module module_) @trusted {
    import std.string: fromStringz;

    const name = module_.toPrettyChars.fromStringz;
    return module_.isGlobalBackendRuntimeSupportModule
        || name == "std.conv"
        || name == "std.format.spec"
        || name == "std.format.write"
        || name == "std.format.internal.write";
}

private bool isGlobalBackendRuntimeSupportModule(imported!"dmd.dmodule".Module module_) @trusted {
    import std.string: fromStringz;

    const name = module_.toPrettyChars.fromStringz;
    return name == "core.internal.array.appending"
        || name == "core.internal.array.capacity"
        || name == "core.internal.array.construction"
        || name == "core.internal.array.utils"
        || name == "core.internal.convert"
        || name == "core.internal.hash"
        || name == "core.internal.lifetime"
        || name == "core.internal.newaa"
        || name == "core.lifetime";
}

private bool isUnaccumulatedSnippetSourceFile(
    imported!"dmd.dmodule".Module module_,
) @trusted {
    return module_.hasSnippetSourceFile
        && cast(void*) module_ !in _accumulatedModules;
}

// parseModule receives readText(path) contents, so DMD records the module's
// source file as "snippet_N.d" instead of the original benchmark file path.
private bool hasSnippetSourceFile(
    imported!"dmd.dmodule".Module module_,
) @trusted {
    import std.algorithm.searching: startsWith;
    import std.string: fromStringz;

    const src = module_.srcfile.toString.fromStringz;
    return src.startsWith("snippet_");
}

// Returns true if the module's source file is under the package root of any
// configured import path.  "Package root" is one level above a trailing
// "source" or "src" component, otherwise the import path itself.  This lets us
// include sibling directories (e.g. cerealed/tests/ when the import path is
// cerealed/src/) while excluding system modules (/usr/include/dlang/dmd/).
private bool isUnderAnyImportPackageRoot(
    imported!"dmd.dmodule".Module module_,
    in string[] importPaths,
) @trusted {
    import std.path: absolutePath, buildNormalizedPath;

    const path = module_.srcfile.toString.idup.absolutePath.buildNormalizedPath;
    foreach (importPath; importPaths) {
        const root = importPath.importPackageRoot.absolutePath.buildNormalizedPath;
        if (path.isUnderPath(root))
            return true;
    }
    return false;
}

// Returns true when the module's source file lives under an import path that is
// backed by a static archive.  Those modules are already linked from the
// archive; generating objects for them too would cause duplicate-symbol errors.
private bool isArchiveBackedModule(
    imported!"dmd.dmodule".Module module_,
    in string[] importPaths,
) @trusted {
    import std.path: absolutePath, buildNormalizedPath;

    const path = module_.srcfile.toString.idup.absolutePath.buildNormalizedPath;
    foreach (importPath; importPaths) {
        if (importPath.linkFileForImportPath.length == 0)
            continue; // not archive-backed
        const importPathAbs = importPath.absolutePath.buildNormalizedPath;
        if (path.isUnderPath(importPathAbs))
            return true;
    }
    return false;
}

private bool isUnitThreadedTemplateInstance(
    imported!"dmd.dtemplate".TemplateInstance templateInstance,
) @trusted {
    if (!templateInstance.tempdecl)
        return false;

    if (auto module_ = templateInstance.tempdecl.symbolModule)
        return module_.isUnitThreadedModule;

    return false;
}

private imported!"dmd.dmodule".Module symbolModule(
    imported!"dmd.dsymbol".Dsymbol symbol,
) @trusted {
    for (auto current = symbol; current; current = current.toParent)
        if (auto module_ = current.isModule)
            return module_;

    return null;
}

private string importPackageRoot(in string importPath) @safe {
    import std.path: baseName, dirName;

    const name = importPath.baseName;
    if (name == "source" || name == "src")
        return importPath.dirName;

    return importPath;
}

private bool isUnderPath(in string path, in string parent) @safe {
    import std.algorithm.searching: startsWith;
    import std.path: relativePath;

    const relative = path.relativePath(parent);
    return relative != ".." && !relative.startsWith(".." ~ "/");
}

private void semantic3Dependencies(
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    import dmd.dmodule: Module;
    import dmd.dsymbolsem:
        dsymbolSemantic,
        importAll,
        runDeferredSemantic,
        runDeferredSemantic2,
        runDeferredSemantic3;
    import dmd.dsymbol: PASS;
    import dmd.semantic2: semantic2;
    import dmd.semantic3: semantic3;

    // Mark every known module as its own root before running deferred semantic
    // passes.  runDeferredSemantic* calls appendToModuleMember which uses
    // importedFrom to determine root ownership; if only fixture modules are
    // marked root, deferred template instances from other modules get placed
    // into the fixture's members instead of their own.
    foreach (m; Module.amodules)
        m.importedFrom = m;

    foreach (module_; modules) {
        module_.importedFrom = module_;
        importAll(module_, null);
    }

    foreach (module_; modules)
        if (module_.semanticRun < PASS.semanticdone)
            dsymbolSemantic(module_, null);
    runDeferredSemantic;

    foreach (module_; modules)
        if (module_.semanticRun < PASS.semantic2done)
            semantic2(module_, null);
    runDeferredSemantic2;

    foreach (module_; modules) {
        if (module_.semanticRun < PASS.semantic3done)
            semantic3(module_, null);
    }
    runDeferredSemantic3;
}

private void link(in string[] objPaths, in string soPath, in string[] linkFiles) @safe {
    import std.process: execute;
    import std.conv: text;

    auto command = [ // const fails: mutated via ~= below.
        "dmd", "-shared", "-fPIC",
    ];
    version (QuickbiteRuntimeLoadLibrary) {
        command ~= "-defaultlib=libphobos2.so";
        command ~= ["-L=-z", "-L=defs"];
    }
    command ~= [
        "-of=" ~ soPath,
        // Accumulated objects from earlier fixture runs may define the same
        // strong symbol as the current run's objects (e.g. ModuleInfo, static
        // initialisers).  All duplicate definitions are identical; pick the
        // first and silence the linker error.
        "-L=--allow-multiple-definition",
    ];
    command ~= objPaths;
    if (linkFiles.length != 0)
        command ~= "-L=--start-group";
    command ~= linkFiles;
    if (linkFiles.length != 0)
        command ~= "-L=--end-group";

    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text("dmd link failed: ", result.output));
}

private void loadAndRunTests(
    in string soPath,
    imported!"dmd.dmodule".Module module_,
) @trusted {
    import core.sys.posix.dlfcn: dlerror, dlsym;
    import std.conv: text;
    import std.string: fromStringz, toStringz;

    void* handle;
    version (QuickbiteRuntimeLoadLibrary) {
        import core.runtime: Runtime;

        handle = Runtime.loadLibrary(soPath);
    } else {
        import core.sys.posix.dlfcn: dlopen, RTLD_GLOBAL, RTLD_NOW;

        handle = dlopen(soPath.toStringz, RTLD_NOW | RTLD_GLOBAL);
    }
    if (!handle)
        throw new Exception(text("dlopen failed: ", dlerror.fromStringz));
    keepLoadedHandle(handle);

    const modtestSym = modtestSymbol(module_);
    auto fn = cast(void function()) dlsym(handle, modtestSym.toStringz);
    if (fn) {
        try {
            fn();
        } catch (Throwable throwable) {
            // DMD's generated __modtest runner can throw from any unittest
            // failure: druntime turns failed asserts into AssertError, and
            // user code can throw directly from the unittest body.
            throwUnittestRunnerThrowable(throwable);
        }
    }
}

private void throwUnittestRunnerThrowable(Throwable throwable) @safe pure {
    if (auto exception = cast(Exception) throwable)
        throw new Exception(exception.msg.idup);

    throw new Exception("Unittest assertion failed.");
}

private string modtestSymbol(
    imported!"dmd.dmodule".Module module_,
) @trusted {
    import core.demangle: mangleFunc;
    import std.conv: text;
    import std.exception: assumeUnique;
    import std.string: fromStringz;

    const modtestName = text(module_.toPrettyChars.fromStringz, ".__modtest");
    return mangleFunc!(void function())(modtestName).assumeUnique;
}

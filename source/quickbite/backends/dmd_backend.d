module quickbite.backends.dmd_backend;

// Link-order forcing mechanism: this intentionally-unused import pulls
// dmd.lib into the link before the frontend library so the linker can resolve
// the Library.factory and Library.setFilename references that
// dmd.glue.generateCodeAndWrite makes when writeLibrary=true.  We always pass
// writeLibrary=false, so these paths are unreachable at runtime, but the
// symbols must be present for static linking.
import dmd.lib: Library;

private:

__gshared bool _backendInit;
__gshared bool _loadedHandlesCleanupRegistered;
__gshared size_t _loadedHandlesCapacity;
__gshared size_t _loadedHandlesLength;
__gshared void** _loadedHandles;
__gshared uint _tempCounter;

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
            throw new Exception("Failed to remember DMD backend shared library handle.");

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

public final class DmdBackend : imported!"quickbite.executor".Executor {
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
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;

    const idx = atomicFetchAdd(_tempCounter, 1u);
    const tmpDir = buildPath(tempDir, text("quickbite_dmd_", idx));
    mkdirRecurse(tmpDir);
    // Temporarily kept for unresolved-symbol inspection while finishing green phase.
    // scope(exit) rmdirRecurse(tmpDir);

    const objPath = buildPath(tmpDir, "module.o");
    const soPath  = buildPath(tmpDir, "module.so");

    withCompilerLock(() {
        ensureBackendInit;
        generateObj(module_, objPath, sourceImportPaths, idx);
    });

    link(objPath, soPath, linkFiles.withInferredLinkFiles(sourceImportPaths));
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

private void ensureBackendInit() @trusted {
    import dmd.dmsc: backend_init;
    import dmd.dmdparams: DMDparams, PIC;
    import dmd.glue: ObjcGlue_initialize;
    import dmd.globals: global;
    import dmd.target: target;

    if (_backendInit)
        return;

    DMDparams driverParams;
    driverParams.pic = PIC.pic;
    backend_init(global.params, driverParams, target);
    ObjcGlue_initialize;
    _backendInit = true;
}

private void generateObj(
    imported!"dmd.dmodule".Module module_,
    in string objPath,
    in string[] sourceImportPaths,
    in uint idx,
) @trusted {
    import dmd.glue: generateCodeAndWrite;
    import dmd.globals: global;
    import dmd.root.filename: FileName;

    auto modules = collectSourceModules(module_, sourceImportPaths);
    modules ~= dmdBackendSupportModule(idx);
    semantic3Dependencies(modules);
    throwIfDmdErrors;
    resetObjState(modules);
    module_.objfile = FileName(objPath);
    generateCodeAndWrite(modules, [], "", "", false, true, true, false, false);
    throwIfDmdErrors;
}

private imported!"dmd.dmodule".Module dmdBackendSupportModule(in uint idx) @trusted {
    import dmd.frontend: parseModule;
    import std.conv: text;

    const moduleName = text("quickbite_dmd_backend_support_", idx);
    const source = text(
        "module ", moduleName, ";\n",
        q{
            import std.array: Appender;
            import std.range: iota;

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
            ubyte[] arrayIotaUbyte(typeof(iota(cast(ubyte) 0, cast(ubyte) 0)) value)
            {
                ubyte[] ret;
                foreach (item; value)
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
            auto iotaUbyte(ubyte end)
            {
                return iota(cast(ubyte) 0, end);
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
            void putAppenderStringWcharArray(ref Appender!string appender, wchar[] value)
                @safe pure
            {
            }

            pragma(mangle, "_D3std5range10primitives__T3putTSQBf5array__T8AppenderTAyaZQoTuZQBlFNaNfKQBpuZv")
            void putAppenderStringWchar(ref Appender!string appender, wchar value)
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
        throw new Exception("DMD backend support module failed to parse.");

    return parsed.module_;
}

private string nestedNestedTypeInfoInitDefinitions(in uint maxIdx) @safe {
    import std.conv: text;

    string ret;
    foreach (idx; 0 .. maxIdx + 1) {
        const moduleName = text("quickbite_dmd_backend_support_", idx);
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
        const moduleName = text("quickbite_dmd_backend_support_", idx);
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
    auto root = modules[0];
    resetGlobalObjState(root, seen, modules);
    foreach (module_; modules)
        resetObjState(module_, root, seen, modules);
}

private void resetGlobalObjState(
    imported!"dmd.dmodule".Module root,
    ref bool[void*] seen,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    import dmd.dmodule: Module;

    foreach (module_; Module.amodules)
        if (!module_.isUnitThreadedModule)
            resetObjState(module_, root, seen, modules);
}

private void resetObjState(
    imported!"dmd.dsymbol".Dsymbol symbol,
    imported!"dmd.dmodule".Module root,
    ref bool[void*] seen,
    imported!"dmd.dmodule".Module[] modules,
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
        resetInitializerObjState(variable._init, root, seen, modules);

    if (auto typeInfo = symbol.isTypeInfoDeclaration) {
        resetTypeObjState(typeInfo.tinfo);
        if (auto typeStruct = typeInfo.tinfo.isTypeStruct)
            resetObjState(typeStruct.sym, root, seen, modules);
    }

    if (auto aggregate = symbol.isAggregateDeclaration) {
        aggregate.sinit = null;
        resetObjState(aggregate.aggrDtor, root, seen, modules);
        resetObjState(aggregate.dtor, root, seen, modules);
        resetObjState(aggregate.tidtor, root, seen, modules);
        resetObjState(aggregate.fieldDtor, root, seen, modules);
    }

    if (auto class_ = symbol.isClassDeclaration) {
        if (class_.vtblsym)
            class_.vtblsym.csym = null;
        resetObjState(class_.vclassinfo, root, seen, modules);
    }

    if (auto struct_ = symbol.isStructDeclaration) {
        resetObjState(struct_.postblit, root, seen, modules);
        resetObjState(struct_.xeq, root, seen, modules);
        resetObjState(struct_.xcmp, root, seen, modules);
        resetObjState(struct_.xhash, root, seen, modules);
    }

    if (auto templateInstance = symbol.isTemplateInstance)
        templateInstance.makeRootTemplateInstance(root, modules);

    if (auto module_ = symbol.isModule)
        resetObjState(module_.decldefs, root, seen, modules);

    if (auto scopeSymbol = symbol.isScopeDsymbol)
        resetObjState(scopeSymbol.members, root, seen, modules);

    if (auto function_ = symbol.isFuncDeclaration) {
        resetObjState(function_.vthis, root, seen, modules);
        resetObjState(function_.v_arguments, root, seen, modules);
        resetObjState(function_.v_argptr, root, seen, modules);
        if (function_.parameters)
            foreach (parameter; *function_.parameters)
                resetObjState(parameter, root, seen, modules);
        resetFunctionBodyObjState(function_, root, seen, modules);
    }
}

private void resetInitializerObjState(
    imported!"dmd.init".Initializer initializer,
    imported!"dmd.dmodule".Module root,
    ref bool[void*] seen,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    if (!initializer)
        return;

    if (auto expInitializer = initializer.isExpInitializer) {
        resetExpressionObjState(expInitializer.exp, root, seen, modules);
    } else if (auto arrayInitializer = initializer.isArrayInitializer) {
        foreach (index; arrayInitializer.index)
            resetExpressionObjState(index, root, seen, modules);
        foreach (value; arrayInitializer.value)
            resetInitializerObjState(value, root, seen, modules);
    } else if (auto structInitializer = initializer.isStructInitializer) {
        foreach (value; structInitializer.value)
            resetInitializerObjState(value, root, seen, modules);
    }
}

private void resetExpressionObjState(
    imported!"dmd.expression".Expression expression,
    imported!"dmd.dmodule".Module root,
    ref bool[void*] seen,
    imported!"dmd.dmodule".Module[] modules,
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

        imported!"dmd.dmodule".Module root;
        bool[void*]* seen;
        imported!"dmd.dmodule".Module[] modules;

        override void visit(Expression expression) {
            resetTypeObjState(expression.type);
        }

        override void visit(DeclarationExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.declaration, root, *seen, modules);
        }

        override void visit(DsymbolExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.s, root, *seen, modules);
        }

        override void visit(FuncExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.fd, root, *seen, modules);
        }

        override void visit(SymbolExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.var, root, *seen, modules);
        }

        override void visit(TypeidExp expression) {
            resetTypeObjState(expression.type);
            resetTypeObjState(isType(expression.obj));
        }

        override void visit(VarExp expression) {
            resetTypeObjState(expression.type);
            resetObjState(expression.var, root, *seen, modules);
        }
    }

    scope visitor = new ResetVisitor;
    visitor.root = root;
    visitor.seen = &seen;
    visitor.modules = modules;
    walkPostorder(expression, visitor);
}

private void resetFunctionBodyObjState(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.dmodule".Module root,
    ref bool[void*] seen,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    import dmd.astenums: STMT;
    import dmd.expression: Expression;
    import dmd.statement: Statement;

    void resetExpression(Expression expression) {
        resetExpressionObjState(expression, root, seen, modules);
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
                resetObjState(withStatement.wthis, root, seen, modules);
                resetStatement(withStatement._body);
                break;
            }
            case STMT.TryCatch:
                resetStatement(statement.isTryCatchStatement._body);
                foreach (catch_; *statement.isTryCatchStatement.catches) {
                    resetObjState(catch_.var, root, seen, modules);
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
    import dmd.backend.symtab: SYMIDX;

    if (!csym)
        return;

    (cast(Symbol*) csym).Ssymnum = SYMIDX.max;
}

private void resetTypeObjState(imported!"dmd.mtype".Type type) @trusted {
    if (!type)
        return;

    bool[void*] seen;
    resetTypeObjState(type, seen);
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

    seen[key] = true;
    if (auto typeInfo = type.vtinfo) {
        resetBackendSymbol(typeInfo.csym);
        typeInfo.csym = null;
    }

    if (!type.isTypeAArray)
        type.vtinfo = null;
    type.ctype = null;

    resetTypeObjState(type.nextOf, seen);
    if (auto associative = type.isTypeAArray)
        resetTypeObjState(associative.index, seen);
}

private void resetObjState(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    imported!"dmd.dmodule".Module root,
    ref bool[void*] seen,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    import dmd.dsymbol: foreachDsymbol;

    foreachDsymbol(symbols, (symbol) => resetObjState(symbol, root, seen, modules));
}

private void makeRootTemplateInstance(
    imported!"dmd.dtemplate".TemplateInstance templateInstance,
    imported!"dmd.dmodule".Module root,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    if (templateInstance.isUnitThreadedTemplateInstance)
        return;
    if (!templateInstance.canRootTemplateInstance(modules))
        return;

    templateInstance.minst = root;

    if (auto primary = templateInstance.inst) {
        if (primary.isUnitThreadedTemplateInstance)
            return;
        if (!primary.canRootTemplateInstance(modules))
            return;

        primary.minst = root;
    }
}

private bool canRootTemplateInstance(
    imported!"dmd.dtemplate".TemplateInstance templateInstance,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    if (templateInstance.referencesNonCurrentSourceModule(modules))
        return false;

    if (!templateInstance.minst)
        return true;

    return templateInstance.minst.isCurrentCodegenModule(modules)
        || templateInstance.minst.isBackendRuntimeSupportModule;
}

private bool referencesNonCurrentSourceModule(
    imported!"dmd.dtemplate".TemplateInstance templateInstance,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    import dmd.dmodule: Module;
    import std.algorithm.searching: canFind, startsWith;
    import std.string: fromStringz;

    const instanceName = templateInstance.toChars.fromStringz;
    foreach (module_; Module.amodules) {
        if (module_.isCurrentCodegenModule(modules)
            || module_.isBackendRuntimeSupportModule
            || module_.isUnitThreadedModule)
            continue;

        const moduleName = module_.toPrettyChars.fromStringz;
        if (moduleName.startsWith("core.")
            || moduleName.startsWith("std.")
            || moduleName == "object")
            continue;

        if (instanceName.canFind(moduleName))
            return true;
    }

    return false;
}

private bool isCurrentCodegenModule(
    imported!"dmd.dmodule".Module module_,
    imported!"dmd.dmodule".Module[] modules,
) @trusted {
    foreach (current; modules)
        if (current is module_)
            return true;

    return false;
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
        throw new Exception("DMD backend code generation failed without a diagnostic message.");

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

        if (importPath.linkFileForImportPath.length == 0)
            throw new Exception("DMD backend does not support imported source modules.");

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
    import dmd.dsymbolsem:
        dsymbolSemantic,
        importAll,
        runDeferredSemantic,
        runDeferredSemantic2,
        runDeferredSemantic3;
    import dmd.dsymbol: PASS;
    import dmd.semantic2: semantic2;
    import dmd.semantic3: semantic3;

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

private void link(in string objPath, in string soPath, in string[] linkFiles) @safe {
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
        objPath,
    ];
    command ~= linkFiles;

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

module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayEvalResult;
    import dmd.func: FuncDeclaration;

    private const string[] _archiveImportPaths;

    public alias eval = Evaluator.eval;

    public this() @safe @nogc nothrow pure {
        _archiveImportPaths = null;
    }

    // `archivePaths` are prebuilt static libraries (`.a`) already defining
    // the modules under `archiveImportPaths`; a call to one of those
    // modules' functions goes through the native bridge to the archive's own
    // compiled symbol instead of the bytecode compiler (see
    // `isArchiveBackedFunction`, core/compiler.d).
    public this(
        const string[] archivePaths,
        const string[] archiveImportPaths,
    ) {
        loadArchiveDependencyImages(archivePaths);
        _archiveImportPaths = archiveImportPaths.dup;
    }

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.bytecode.core.compiler: compile;
        import quickbite.backends.bytecode.core.machine: run;
        import quickbite.backends.bytecode.core.reify: reify;

        return displayEvalResult(() {
            auto compilation = compile(function_, _archiveImportPaths);
            auto result =
                run(*compilation.program, compilation.compileFunction);
            return reify(
                result.bytes,
                compilation.program.functions[0].returnType,
                compilation.program.data,
                result.heap,
                compilation.program.literalBlocks,
            );
        }, function_);
    }
}

// A static archive cannot be `dlopen`ed directly; link its object members
// whole (nothing else on this link references them, so a normal link would
// discard them as unreferenced) into one throwaway shared library, then load
// that the same way any other dependency image is loaded
// (`quickbite.ffi.loadDependencyImages`, `dlsym(RTLD_DEFAULT, ...)`).
private void loadArchiveDependencyImages(in string[] archivePaths) {
    import core.atomic: atomicFetchAdd;
    import core.sys.posix.unistd: getpid;
    import quickbite.ffi: loadDependencyImages;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;
    import std.process: execute;

    if (archivePaths.length == 0)
        return;

    const index = atomicFetchAdd(_archiveImageCounter, 1u);
    const dir =
        buildPath(tempDir, text("quickbite_bytecode_archive_", getpid, "_", index));
    mkdirRecurse(dir);
    // `loadDependencyImages` maps the file via `dlopen` below, which keeps it
    // valid after this directory is removed.
    scope(exit) rmdirRecurse(dir);
    const imagePath = buildPath(dir, "archive.so");

    // The system linker directly, not `dmd`: `dmd` reorders any `.a` it sees
    // among its own `-L=` flags to the end of its own generated link command,
    // after the flags surrounding it, which would separate `libdep.a` from
    // the `--whole-archive`/`--no-whole-archive` pair meant to bracket it.
    const command = [
        "cc", "-shared", "-o", imagePath, "-Wl,--whole-archive",
    ] ~ archivePaths.dup ~ ["-Wl,--no-whole-archive"];
    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text(
            "failed to build a loadable image from archive(s) ",
            archivePaths, ": ", result.output,
        ));

    loadDependencyImages([imagePath]);
}

private __gshared uint _archiveImageCounter;

module quickbite.frontend.compiler;

private:

public alias ParsedModule = imported!"std.typecons".Tuple!(
    imported!"dmd.dmodule".Module,
    "module_",
    imported!"dmd.frontend".Diagnostics,
    "diagnostics",
);

// DMD owns process-global compiler state; `Compiler` serializes access with a
// mutex and is initialized once for this process.
__gshared Compiler compiler;
// DMD registers modules by filename, so each parse call needs a unique name.
// TODO: bench harness re-runs grow this monotonically and DMD retains
// process-global semantic state keyed off the name. At small fixture counts
// the bias is below stddev, but as the fixture set grows we will need either
// a deinitializeDMD/initDMD reset between runs or a way to evict the
// registered module from DMD's tables.
private shared uint _moduleCounter;

shared static this() {
    compiler = new Compiler;
}

shared static ~this() {
    compiler.shutdown;
}

public ParsedModule parseModule(in string source) {
    return compiler.parseModule(source);
}

public void addImportPath(in string path) {
    import dmd.frontend: addImport;
    addImport(path);
}

public void withCompilerLock(scope void delegate() action) {
    compiler.withLock(action);
}

public imported!"quickbite.ir.module_".Module lowerModule(
    imported!"dmd.dmodule".Module module_,
) {
    import quickbite.frontend.lowering;

    return quickbite.frontend.lowering.lowerModule(module_);
}

final class Compiler {
    private bool initialized;
    private imported!"core.sync.mutex".Mutex mutex;

    private this() {
        import core.sync.mutex: Mutex;
        import dmd.errors: diagnostics, fatalErrorHandler;
        import dmd.frontend: addImport, findImportPaths, initDMD;
        import dmd.globals: global;
        import std.algorithm.iteration: each;

        mutex = new Mutex;
        initDMD;
        // Prepend the druntime that matches the DMD-as-library version.
        // The system druntime may be a different version and lack hooks
        // (e.g. `_d_arraysetlengthTImpl`) that DMD-as-library expects.
        // Deriving the path from the DMD frontend module's source location
        // ensures we always use the bundled druntime regardless of the
        // user's system druntime version.
        addImport(dmdDruntimeSrcPath);
        findImportPaths.each!addImport;

        // Prevent DMD from calling exit() when too many cascading errors
        // accumulate.  parseModule already checks global.errors after
        // fullSemantic and throws an Exception, so returning true here is safe.
        // This is intentionally process-global: the correct response to a DMD
        // fatal error in any quickbite test is a thrown Exception, not a
        // process abort that silently kills all subsequent tests.
        fatalErrorHandler = () => true;

        global.params.useUnitTests = true;
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;
        initialized = true;
    }

    void shutdown() {
        import dmd.frontend: deinitializeDMD;

        mutex.lock;
        scope(exit) mutex.unlock;

        if (!initialized)
            return;

        deinitializeDMD;
        initialized = false;
    }

    void withLock(scope void delegate() action) {
        import dmd.errors: diagnostics;
        import dmd.globals: global;

        mutex.lock;
        scope(exit) {
            global.errors = 0;
            global.warnings = 0;
            diagnostics.length = 0;
            mutex.unlock;
        }
        action();
    }

    ParsedModule parseModule(in string source) {
        import core.atomic: atomicFetchAdd;
        import dmd.errors: diagnostics;
        import dmd.frontend: fullSemantic, dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.conv: text;

        mutex.lock;
        scope(exit) mutex.unlock;

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const fileName = text(
            "snippet_",
            atomicFetchAdd(_moduleCounter, 1u),
            ".d",
        );

        ParsedModule parsed = dmdParseModule(fileName, source);
        if (parsed.diagnostics.hasErrors)
            throw new Exception(diagnosticMessage);

        parsed.module_.fullSemantic;
        if (global.errors != 0)
            throw new Exception(diagnosticMessage);

        return parsed;
    }
}

// Returns the path to the druntime `src` directory bundled with the
// DMD-as-library dub package.  DMD-as-library's `fullSemantic` resolves
// runtime hooks such as `_d_arraysetlengthTImpl` from `object.d` in the
// import path.  The system druntime may be a different version and may
// not contain those hooks, so we derive the path from the location of
// the DMD frontend source file (which is inside the same dub package).
//
// Example: the frontend lives at
//   .dub/packages/dmd/2.111.0/dmd/compiler/src/dmd/frontend.d
// The druntime src is at:
//   .dub/packages/dmd/2.111.0/dmd/druntime/src
//
// The transformation: strip the trailing `compiler/src/dmd/<file>.d`
// part (4 path components) and append `druntime/src`.
string dmdDruntimeSrcPath() {
    import dmd.frontend: dmdParseModule = parseModule;
    import std.path: buildPath, dirName;

    // __traits(getLocation, ...) returns a tuple (file, line, col);
    // take the first element.
    const frontendFile = __traits(getLocation, dmdParseModule)[0];
    // Go up 4 directories from frontend.d to reach the package root:
    //   frontend.d -> compiler/src/dmd/ -> compiler/src/ -> compiler/ -> pkg/
    const packageRoot = frontendFile
        .dirName  // compiler/src/dmd/
        .dirName  // compiler/src/
        .dirName  // compiler/
        .dirName; // package root (e.g. .dub/packages/dmd/2.111.0/dmd)
    return buildPath(packageRoot, "druntime", "src");
}

string diagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;
    import std.algorithm.iteration: filter, map;
    import std.array: array, join;

    const messages = diagnostics
        .filter!(diagnostic => diagnostic.kind == ErrorKind.error)
        .map!(diagnostic => diagnostic.message)
        .array;

    if (messages.length == 0)
        return "DMD reported an error without a diagnostic message.";

    return messages.join("\n");
}

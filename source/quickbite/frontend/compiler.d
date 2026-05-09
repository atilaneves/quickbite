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

public ParsedModule parseFile(in string filePath, in string[] importPaths) {
    return compiler.parseFile(filePath, importPaths);
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
        // Prepend a patched druntime that has both:
        //   - `_d_arraysetlengthTImpl` (in bundled 2.111, absent in system 2.112)
        //   - `_d_newarrayU` re-exported from object.d (in system 2.112, absent
        //     in bundled 2.111, but needed by system phobos std/array.d)
        // The patched path contains a copy of the bundled object.d with the
        // missing `_d_newarrayU` public import added.  All other bundled
        // druntime files are still resolved from dmdDruntimeSrcPath.
        addImport(patchedDruntimePath);
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

    ParsedModule parseFile(in string filePath, in string[] importPaths) {
        import dmd.errors: diagnostics;
        import dmd.frontend: addImport, fullSemantic, dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.file: readText;

        mutex.lock;
        scope(exit) mutex.unlock;

        foreach (importPath; importPaths)
            addImport(importPath);

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const content = readText(filePath);
        ParsedModule parsed = dmdParseModule(filePath, content);
        if (parsed.diagnostics.hasErrors)
            throw new Exception(diagnosticMessage);

        parsed.module_.fullSemantic;
        if (global.errors != 0)
            throw new Exception(diagnosticMessage);

        return parsed;
    }
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

// Returns a temporary directory containing a patched `object.d` that adds
// a missing `public import core.internal.array.construction : _d_newarrayU;`
// re-export.  This re-export is present in the system druntime (>= 2.112) and
// is required by the system phobos `std/array.d`, but the bundled druntime
// (2.111) does not have it.  By placing this directory first in the import
// path, `std/array.d` can resolve `_d_newarrayU` from the patched `object.d`
// while still getting `_d_arraysetlengthTImpl` from the bundled druntime.
//
// The directory is created once per process in a temporary location and is
// intentionally leaked (never deleted): the OS cleans it on process
// exit, and creating/deleting it for every compiler initialisation would be
// racy.
string patchedDruntimePath() {
    import core.sys.posix.unistd: getpid;
    import std.conv: text;
    import std.file: mkdirRecurse, readText, tempDir, write;
    import std.path: buildPath;
    import std.string: indexOf;

    const bundledObjectD = buildPath(dmdDruntimeSrcPath, "object.d");
    const content = readText(bundledObjectD);

    // Check whether the re-export is already present; if so, reuse bundled.
    const needle = "public import core.internal.array.construction : _d_newarrayU;";
    if (content.indexOf(needle) >= 0)
        return dmdDruntimeSrcPath;

    // Insert the missing re-export after the existing `_d_newarrayT` line.
    const anchor = "public import core.internal.array.construction : _d_newarrayT;";
    const anchorIdx = content.indexOf(anchor);
    if (anchorIdx < 0)
        return dmdDruntimeSrcPath; // Cannot patch; fall back to bundled.

    const afterAnchor = anchorIdx + anchor.length;
    const patched = content[0 .. afterAnchor] ~ "\n" ~ needle ~ content[afterAnchor .. $];

    // Write the patched object.d into a per-process temp directory so
    // concurrent dub test runs don't trample each other.
    const patchDir = buildPath(tempDir, text("quickbite-druntime-", getpid));
    mkdirRecurse(patchDir);
    write(buildPath(patchDir, "object.d"), patched);
    return patchDir;
}

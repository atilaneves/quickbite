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
    return compiler.parseModule(source, []);
}

public ParsedModule parseModule(in string source, in string[] importPaths) {
    return compiler.parseModule(source, importPaths);
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
    // Cache parsed modules keyed by source content.  Running three backends
    // against the same cerealed test file must call dmdParseModule exactly
    // once; subsequent calls with the same source return the cached module.
    // The cache is populated only after dmdParseModule + fullSemantic both
    // succeed, so callers never receive a partially-semantic'd module.
    //
    // ParsedModule contains an immutable Diagnostics field, so it cannot be
    // stored directly in an AA (D AAs require assignability).  We store the
    // DMD Module class (a reference type) keyed by source and reconstruct
    // a ParsedModule on every cache hit.
    private imported!"dmd.dmodule".Module[string] sourceCache;
    // DMD registers modules before fullSemantic can fail.  Cache failures by
    // source too, so later backends rethrow the same frontend error instead of
    // reparsing into a duplicate module-name conflict.
    private string[string] sourceErrorCache;

    private this() {
        import core.sync.mutex: Mutex;
        import dmd.errors: diagnostics, fatalErrorHandler;
        import dmd.frontend: addImport, findImportPaths, initDMD;
        import dmd.globals: global;
        import std.algorithm.iteration: each;

        mutex = new Mutex;
        initDMD;
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

    ParsedModule parseModule(in string source, in string[] importPaths) {
        import core.atomic: atomicFetchAdd;
        import dmd.errors: diagnostics;
        import dmd.frontend: addImport, fullSemantic, dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.conv: text;

        mutex.lock;
        scope(exit) mutex.unlock;

        foreach (importPath; importPaths)
            addImport(importPath);

        // Return cached result if this source was already parsed and
        // semantically analysed successfully.
        if (auto cached = source in sourceCache) {
            ParsedModule result;
            result.module_ = *cached;
            return result;
        }

        if (auto cachedError = source in sourceErrorCache)
            throw new Exception(*cachedError);

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const fileName = text(
            "snippet_",
            atomicFetchAdd(_moduleCounter, 1u),
            ".d",
        );

        ParsedModule parsed = dmdParseModule(fileName, source);
        if (parsed.diagnostics.hasErrors) {
            const message = diagnosticMessage;
            sourceErrorCache[source] = message;
            throw new Exception(message);
        }

        parsed.module_.fullSemantic;
        if (global.errors != 0) {
            const message = diagnosticMessage;
            sourceErrorCache[source] = message;
            throw new Exception(message);
        }

        // Cache only after both parsing and full semantic analysis succeed,
        // so callers always receive a fully-verified module.
        sourceCache[source] = parsed.module_;

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

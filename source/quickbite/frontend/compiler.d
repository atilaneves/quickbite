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

public ParsedModule parseModule(in string source) @trusted {
    return compiler.parseModule(source, []);
}

public ParsedModule parseModule(
    in string source,
    in string[] importPaths,
) @trusted {
    return compiler.parseModule(source, importPaths);
}

public void withCompilerLock(scope void delegate() action) @trusted {
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
    // Keyed by source content and import paths; prevents re-registering the
    // same module in DMD's process-global table when multiple backends parse
    // the same file with the same import context.
    private imported!"dmd.dmodule".Module[string] sourceCache;

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

        const key = cacheKey(source, importPaths);
        if (auto cached = key in sourceCache) {
            ParsedModule result;
            result.module_ = *cached;
            return result;
        }

        const originalPathLength = global.path.length;
        scope(exit) global.path.setDim(originalPathLength);
        foreach (importPath; importPaths)
            addImport(importPath);

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const fileName = text(
            "snippet_",
            atomicFetchAdd(_moduleCounter, 1u),
            ".d",
        );

        ParsedModule parsed = dmdParseModule(fileName, source);
        if (parsed.module_ !is null)
            sourceCache[key] = parsed.module_;

        if (parsed.diagnostics.hasErrors)
            throw new Exception(diagnosticMessage);

        parsed.module_.fullSemantic;
        if (global.errors != 0)
            throw new Exception(diagnosticMessage);

        return parsed;
    }

    private string cacheKey(in string source, in string[] importPaths) const {
        import std.array: join;
        import std.conv: text;

        return text(source, "\0", importPaths.join("\0"));
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

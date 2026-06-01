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

public ParsedModule parseModule(
    in string source,
    in string[] importPaths,
) {
    return compiler.parseModule(source, importPaths);
}

public ParsedModule parseModuleUncached(
    in string source,
    in string[] importPaths,
) {
    return compiler.parseModuleUncached(source, importPaths);
}

public ParsedModule parseModuleWithCheckActionContext(in string source) {
    return compiler.parseModuleWithCheckActionContext(source, []);
}

public ParsedModule parseModuleWithCheckActionContext(
    in string source,
    in string[] importPaths,
) {
    return compiler.parseModuleWithCheckActionContext(source, importPaths);
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
    // Keyed by source content and import paths; prevents re-registering the
    // same module in DMD's process-global table when multiple executors parse
    // the same file with the same import context.
    private imported!"dmd.dmodule".Module[string] sourceCache;

    private this() {
        import core.sync.mutex: Mutex;

        mutex = new Mutex;
        initializeDmdState;
        initialized = true;
    }

    private void initializeDmdState() {
        import dmd.common.charactertables:
            IdentifierCharLookup,
            IdentifierTable;
        import dmd.errors: diagnostics, fatalErrorHandler;
        import dmd.frontend: addImport, findImportPaths, initDMD;
        import dmd.globals: global;
        import std.algorithm.iteration: each;

        initDMD;
        findImportPaths.each!addImport;

        // Prevent DMD from calling exit() when too many cascading errors
        // accumulate.  parseModule already checks global.errors after
        // fullSemantic and throws an Exception, so returning true here is safe.
        // This is intentionally process-global: the correct response to a DMD
        // fatal error in any quickbite test is a thrown Exception, not a
        // process abort that silently kills all subsequent tests.
        fatalErrorHandler = () => true;

        // Silence DMD's direct stderr printing; diagnostics are still captured
        // in the `diagnostics` array and surfaced via thrown exceptions.
        import dmd.console: Color;
        import dmd.errors: diagnosticHandler;
        import dmd.location: SourceLoc;
        import core.stdc.stdarg: va_list;

        diagnosticHandler = (
            const ref SourceLoc loc,
            Color, const(char)* header,
            const(char)* fmt,
            va_list args,
            const(char)* p1,
            const(char)* p2,
        )
        {
            import dmd.errors: Diagnostic, ErrorKind, diagnostics;
            import core.stdc.stdarg: va_copy, va_end;
            import core.stdc.stdio: vsnprintf;
            import core.stdc.string: strcmp;
            import std.string: fromStringz;

            if (!header || strcmp(header, "Error: ") != 0)
                return true;

            va_list copy;
            va_copy(copy, args);
            scope(exit) va_end(copy);

            const size = vsnprintf(null, 0, fmt, args);
            if (size <= 0) return true;

            auto buf = new char[size + 1];
            vsnprintf(buf.ptr, size + 1, fmt, copy);
            string message = buf[0 .. size].idup;

            if (p2) message = fromStringz(p2).idup ~ " " ~ message;
            if (p1) message = fromStringz(p1).idup ~ " " ~ message;

            diagnostics ~= Diagnostic(loc, message, ErrorKind.error);
            return true;
        };

        // Disable the error limit so DMD never prints "error limit (N) reached"
        // directly to stderr (a fprintf path that bypasses diagnosticHandler).
        global.params.v.errorLimit = 0;

        global.compileEnv.cCharLookupTable =
            IdentifierCharLookup.forTable(IdentifierTable.LR);
        global.compileEnv.dCharLookupTable =
            IdentifierCharLookup.forTable(IdentifierTable.LR);
        global.params.useUnitTests = true;
        global.params.allInst = true;
        resetErrors;
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
        resetErrors;
        scope(exit) {
            resetErrors;
            mutex.unlock;
        }
        action();
    }

    ParsedModule parseModule(in string source, in string[] importPaths) {
        mutex.lock;
        scope(exit) mutex.unlock;

        return parseModuleLocked(source, importPaths, null, true);
    }

    ParsedModule parseModuleUncached(
        in string source,
        in string[] importPaths,
    ) {
        mutex.lock;
        scope(exit) mutex.unlock;

        return parseModuleLocked(source, importPaths, null, false);
    }

    ParsedModule parseModuleWithCheckActionContext(
        in string source,
        in string[] importPaths,
    ) {
        import dmd.astenums: CHECKACTION;
        import dmd.globals: global;

        mutex.lock;
        scope(exit) mutex.unlock;

        const originalCheckAction = global.params.checkAction;
        global.params.checkAction = CHECKACTION.context;
        scope(exit) global.params.checkAction = originalCheckAction;

        return parseModuleLocked(source, importPaths, "checkaction=context", true);
    }

    private ParsedModule parseModuleLocked(
        in string source,
        in string[] importPaths,
        in string cacheSalt,
        in bool useCache,
    ) {
        import core.atomic: atomicFetchAdd;
        import dmd.errors: diagnostics;
        import dmd.frontend:
            addImport,
            fullSemantic,
            dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.conv: text;

        const key = cacheKey(source, importPaths, cacheSalt);
        if (useCache)
        if (auto cached = key in sourceCache) {
            ParsedModule result;
            result.module_ = *cached;
            return result;
        }

        const originalPathLength = global.path.length;
        scope(exit) global.path.setDim(originalPathLength);
        foreach (importPath; importPaths)
            addImport(importPath);

        resetErrors;

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

        if (useCache)
            sourceCache[key] = parsed.module_;

        return parsed;
    }

    private string cacheKey(
        in string source,
        in string[] importPaths,
        in string cacheSalt,
    ) const {
        import std.array: join;
        import std.conv: text;

        return text(source, "\0", importPaths.join("\0"), "\0", cacheSalt);
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

private void resetErrors() {
    import dmd.globals: global;
    import dmd.errors: diagnostics;
    global.errors = 0;
    global.warnings = 0;
    diagnostics.length = 0;
}

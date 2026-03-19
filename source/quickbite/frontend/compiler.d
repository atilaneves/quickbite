module quickbite.frontend.compiler;

private:

__gshared Compiler compiler;

shared static this() {
    compiler = new Compiler;
}

shared static ~this() {
    compiler.shutdown();
}

public auto parseModule(in string source) {
    return compiler.parseModule(source);
}

final class Compiler {
    private bool initialized;
    private imported!"core.sync.mutex".Mutex mutex;

    private this() {
        import core.sync.mutex: Mutex;
        import dmd.errors: diagnostics;
        import dmd.frontend: addImport, findImportPaths, initDMD;
        import dmd.globals: global;
        import std.algorithm.iteration: each;

        mutex = new Mutex;
        initDMD();
        findImportPaths.each!addImport;

        global.params.useUnitTests = true;
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;
        initialized = true;
    }

    void shutdown() {
        import dmd.frontend: deinitializeDMD;

        mutex.lock();
        scope(exit) mutex.unlock();

        if (!initialized)
            return;

        deinitializeDMD();
        initialized = false;
    }

    auto parseModule(in string source) {
        import dmd.errors: diagnostics;
        import dmd.frontend: fullSemantic, dmdParseModule = parseModule;
        import dmd.globals: global;
        import std.string: replace;
        import std.uuid: randomUUID;

        mutex.lock();
        scope(exit) mutex.unlock();

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const fileName = "snippet_" ~ randomUUID().toString.replace("-", "") ~ ".d";

        auto parsed = dmdParseModule(fileName, source);
        if (parsed.diagnostics.hasErrors())
            throw new Exception(diagnosticMessage());

        parsed.module_.fullSemantic();
        if (global.errors != 0)
            throw new Exception(diagnosticMessage());

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

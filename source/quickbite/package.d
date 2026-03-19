module quickbite;

private:

__gshared Compiler compiler;

shared static this() {
    compiler = new Compiler;
}

shared static ~this() {
    compiler.shutdown();
}

public void runTests(in string source) {
    auto parsed = compiler.parseModule(source);
    executeUnitTests(parsed.module_);
}

final class Compiler {
    private bool initialized;
    private imported!"core.sync.mutex".Mutex mutex;

    private this() {
        import dmd.errors: diagnostics;
        import dmd.frontend: addImport, findImportPaths, initDMD;
        import dmd.globals: global;
        import std.algorithm.iteration: each;
        import core.sync.mutex: Mutex;

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

void executeUnitTests(imported!"dmd.dmodule".Module module_) {
    foreach (member; *module_.members) {
        if (auto unitTest = member.isUnitTestDeclaration())
            executeStatement(unitTest.fbody);
    }
}

long executeFunction(imported!"dmd.func".FuncDeclaration function_) {
    import std.typecons: Nullable;

    const result = executeStatement(function_.fbody);
    if (result.isNull)
        throw new Exception("Unsupported function body.");

    return result.get;
}

imported!"std.typecons".Nullable!long executeStatement(
    imported!"dmd.statement".Statement statement,
) {
    import std.typecons: Nullable, nullable;

    if (auto compound = statement.isCompoundStatement()) {
        foreach (child; *compound.statements) {
            const result = executeStatement(child);
            if (!result.isNull)
                return result;
        }

        return Nullable!long.init;
    }

    if (auto expressionStatement = statement.isExpStatement()) {
        evaluateExpression(expressionStatement.exp);
        return Nullable!long.init;
    }

    if (auto returnStatement = statement.isReturnStatement()) {
        return nullable(evaluateExpression(returnStatement.exp));
    }

    throw new Exception("Unsupported statement.");
}

long evaluateExpression(imported!"dmd.expression".Expression expression) {
    if (auto integer = expression.isIntegerExp())
        return integer.getInteger();

    if (auto call = expression.isCallExp()) {
        if (call.arguments !is null && call.arguments.length != 0)
            throw new Exception("Unsupported call.");

        if (call.f is null)
            throw new Exception("Unsupported callee.");

        return executeFunction(call.f);
    }

    if (auto equal = expression.isEqualExp())
        return evaluateExpression(equal.e1) == evaluateExpression(equal.e2);

    if (auto assert_ = expression.isAssertExp()) {
        if (!evaluateExpression(assert_.e1))
            throw new Exception("Unittest assertion failed.");

        return 0;
    }

    throw new Exception("Unsupported expression.");
}

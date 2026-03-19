module quickbite;

import core.sync.mutex: Mutex;

__gshared Mutex dmdMutex;

shared static this() {
    dmdMutex = new Mutex;
}

void runTests(string source) {
    import dmd.errors: diagnostics;
    import dmd.frontend: addImport, deinitializeDMD, findImportPaths,
        fullSemantic, initDMD, parseModule;
    import dmd.globals: global;
    import std.algorithm.iteration: each;
    import std.conv: to;

    dmdMutex.lock();
    scope(exit) dmdMutex.unlock();

    static size_t snippetCounter;
    initDMD();
    scope(exit) deinitializeDMD();
    findImportPaths.each!addImport;

    global.params.useUnitTests = true;
    global.errors = 0;
    global.warnings = 0;
    diagnostics.length = 0;

    ++snippetCounter;
    const fileName = "snippet" ~ snippetCounter.to!string ~ ".d";

    auto parsed = parseModule(fileName, source);
    if (parsed.diagnostics.hasErrors())
        throw new Exception(diagnosticMessage());

    parsed.module_.fullSemantic();
    if (global.errors != 0)
        throw new Exception(diagnosticMessage());

    executeUnitTests(parsed.module_);
}

private:

import dmd.dmodule: Module;
import dmd.dsymbol: Dsymbol;
import dmd.expression: AssertExp, CallExp, EqualExp, Expression, IntegerExp;
import dmd.func: FuncDeclaration;
import dmd.statement: CompoundStatement, ExpStatement, ReturnStatement, Statement;
import std.array: array, join;
import std.algorithm.iteration: filter, map;

struct StatementResult
{
    bool didReturn;
    long value;
}

string diagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;

    const messages = diagnostics
        .filter!(diagnostic => diagnostic.kind == ErrorKind.error)
        .map!(diagnostic => diagnostic.message)
        .array;

    if (messages.length == 0)
        return "DMD reported an error without a diagnostic message.";

    return messages.join("\n");
}

void executeUnitTests(Module module_) {
    foreach (member; *module_.members) {
        if (auto unitTest = member.isUnitTestDeclaration())
            executeStatement(unitTest.fbody);
    }
}

long executeFunction(FuncDeclaration function_) {
    const result = executeStatement(function_.fbody);
    if (!result.didReturn)
        throw new Exception("Unsupported function body.");

    return result.value;
}

StatementResult executeStatement(Statement statement) {
    if (auto compound = statement.isCompoundStatement()) {
        foreach (child; *compound.statements) {
            const result = executeStatement(child);
            if (result.didReturn)
                return result;
        }

        return StatementResult.init;
    }

    if (auto expressionStatement = statement.isExpStatement()) {
        evaluateExpression(expressionStatement.exp);
        return StatementResult.init;
    }

    if (auto returnStatement = statement.isReturnStatement()) {
        return StatementResult(
            true,
            evaluateExpression(returnStatement.exp),
        );
    }

    throw new Exception("Unsupported statement.");
}

long evaluateExpression(Expression expression) {
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

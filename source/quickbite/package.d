module quickbite;

public void runTests(in string source) {
    import quickbite.frontend.compiler;

    auto parsed = quickbite.frontend.compiler.parseModule(source);
    executeUnitTests(parsed.module_);
}

private:

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
)
{
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

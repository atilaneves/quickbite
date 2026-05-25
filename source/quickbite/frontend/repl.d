module quickbite.frontend.repl;

private:

public imported!"quickbite.executor".Repl.CellResult evalReplCell(
    imported!"quickbite.executor".Executor executor,
    scope void delegate(in string transcript, in string input) runVoidCell,
    in string transcript,
    in string input,
) {
    import quickbite.executor: Repl;

    if (isExpressionCell(input))
        return Repl.CellResult.value_(executor.eval(transcript ~ input));

    runVoidCell(transcript, input);
    return Repl.CellResult.void_;
}

public bool isExpressionCell(in string input) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.parse: ParseStatementFlags, Parser;
    import quickbite.frontend.compiler: withCompilerLock;

    bool result;
    withCompilerLock(() {
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        scope parser = new Parser!ASTCodegen(
            null,
            input,
            false,
            global.errorSinkNull,
            &global.compileEnv,
            true,
        );

        parser.nextToken;
        const expression = statementExpression(
            parser.parseStatement(ParseStatementFlags.semiOk),
        );
        result = expression !is null &&
            expression.isDeclarationExp is null &&
            global.errors == 0;
    });

    return result;
}

private imported!"dmd.expression".Expression statementExpression(
    imported!"dmd.statement".Statement statement,
) {
    if (statement is null)
        return null;

    auto expressionStatement = statement.isExpStatement;
    if (expressionStatement is null)
        return null;

    return expressionStatement.exp;
}

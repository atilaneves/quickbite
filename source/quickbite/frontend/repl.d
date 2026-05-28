module quickbite.frontend.repl;

private:

public enum ReplCellKind {
    noDisplay,
    expression,
}

public struct ReplCell {
    public ReplCellKind kind;
    public string source;
    private string history;
}

public struct ReplSession {
    private string transcript;
    private uint valueCellCount;

    public ReplCell submit(in string input) {
        import std.conv: text;

        if (!isExpressionCell(input))
            return ReplCell(
                ReplCellKind.noDisplay,
                transcript ~ input,
                input ~ "\n",
            );

        return ReplCell(
            ReplCellKind.expression,
            transcript ~ input,
            text(
                "auto __quickbite_repl_value_",
                valueCellCount,
                " = ",
                input,
                ";\n",
            ),
        );
    }

    public void accept(in ReplCell cell) {
        transcript ~= cell.history;
        if (cell.kind == ReplCellKind.expression)
            ++valueCellCount;
    }
}

public imported!"quickbite.executor".Repl.CellResult evalReplCell(
    imported!"quickbite.executor".Executor executor,
    in string transcript,
    in string input,
) {
    import quickbite.executor: Repl;

    if (isExpressionCell(input))
        return Repl.CellResult.value_(executor.eval(transcript ~ input));

    executor.runVoidReplCell(transcript, input);
    return Repl.CellResult.void_;
}

bool isExpressionCell(in string input) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.parse: Parser;
    import dmd.tokens: TOK;
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
        const expression = parser.parseExpression;
        result = expression !is null &&
            expression.isDeclarationExp is null &&
            parser.token.value == TOK.endOfFile &&
            global.errors == 0;
    });

    return result;
}

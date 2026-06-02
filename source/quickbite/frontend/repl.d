module quickbite.frontend.repl;

private:

public enum ReplCellKind {
    incomplete,
    noDisplay,
    expression,
    typeExpression,
}

public struct ReplCell {
    public ReplCellKind kind;
    public string source;
    public imported!"quickbite.frontend.cell".EvalCell evalCell;
}

public struct ReplSession {
    private imported!"quickbite.frontend.cell".EvalSession evalSession;

    public ReplCell submit(in string input) {
        if (isTypeExpressionCell(input)) {
            auto cell = evalSession.submit(input ~ ".stringof");
            return ReplCell(ReplCellKind.typeExpression, cell.source, cell);
        }

        auto cell = evalSession.submit(input);
        return ReplCell(replCellKind(cell.kind), cell.source, cell);
    }

    public void accept(in ReplCell cell) {
        if (cell.kind != ReplCellKind.typeExpression)
            evalSession.accept(cell.evalCell);
    }

    public void loadModuleSource(in string source) {
        evalSession.loadModuleSource(source);
    }

    public string loadedModuleSource() const @safe pure {
        return evalSession.loadedModuleSource;
    }
}

private ReplCellKind replCellKind(
    in imported!"quickbite.frontend.cell".EvalCellKind kind,
) @safe pure {
    import quickbite.frontend.cell: EvalCellKind;

    final switch (kind) with (EvalCellKind) {
        case incomplete:
            return ReplCellKind.incomplete;
        case noDisplay:
            return ReplCellKind.noDisplay;
        case expression:
            return ReplCellKind.expression;
    }
}

private bool isTypeExpressionCell(in string input) {
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

        const source = input ~ '\0';
        scope parser = new Parser!ASTCodegen(
            null,
            source,
            false,
            global.errorSink,
            &global.compileEnv,
            true,
        );

        parser.nextToken;
        const expression = parser.parseExpression;
        result = expression !is null &&
            expression.isTypeExp !is null &&
            parser.token.value != TOK.semicolon &&
            global.errors == 0;
    });

    return result;
}

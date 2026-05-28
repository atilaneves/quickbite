module quickbite.frontend.repl;

private:

public enum ReplCellKind {
    incomplete,
    noDisplay,
    expression,
}

public struct ReplCell {
    public ReplCellKind kind;
    public string source;
    private ReplHistoryTarget historyTarget;
    private string history;
}

private enum ReplHistoryTarget {
    local,
    module_,
}

public struct ReplSession {
    private string localTranscript;
    private string moduleTranscript;
    private uint valueCellCount;

    public ReplCell submit(in string input) {
        import std.conv: text;

        if (isIncompleteCell(input))
            return ReplCell(ReplCellKind.incomplete);

        if (isModuleDeclarationCell(input))
            return ReplCell(
                ReplCellKind.noDisplay,
                replSource(moduleTranscript ~ input ~ "\n", localTranscript),
                ReplHistoryTarget.module_,
                input ~ "\n",
            );

        if (!isExpressionCell(input))
            return ReplCell(
                ReplCellKind.noDisplay,
                replSource(moduleTranscript, localTranscript ~ input ~ "\n"),
                ReplHistoryTarget.local,
                input ~ "\n",
            );

        return ReplCell(
            ReplCellKind.expression,
            replSource(moduleTranscript, localTranscript ~ "return " ~ input ~ ";"),
            ReplHistoryTarget.local,
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
        final switch (cell.historyTarget) with (ReplHistoryTarget) {
            case local:
                localTranscript ~= cell.history;
                break;
            case module_:
                moduleTranscript ~= cell.history;
                break;
        }

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

private bool isExpressionCell(in string input) {
    if (isDeclarationCell(input))
        return false;

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
            parser.token.value != TOK.semicolon &&
            global.errors == 0;
    });

    return result;
}

private bool isModuleDeclarationCell(in string input) {
    import dmd.errors: diagnostics;
    import dmd.frontend: parseModule;
    import dmd.globals: global;
    import std.conv: text;
    import quickbite.frontend.compiler: withCompilerLock;

    bool result;
    withCompilerLock(() {
        import core.atomic: atomicFetchAdd;

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        auto parsed = parseModule(
            text("repl_cell_", atomicFetchAdd(_replModuleCounter, 1u), ".d"),
            input,
        );
        result = !parsed.diagnostics.hasErrors &&
            parsed.module_.members !is null &&
            parsed.module_.members.length != 0 &&
            allFunctionDeclarations(parsed.module_.members) &&
            global.errors == 0;
    });

    return result;
}

private bool isDeclarationCell(in string input) {
    return isModuleDeclarationCell(input);
}

private bool isIncompleteCell(in string input) {
    import dmd.errors: diagnostics;
    import dmd.frontend: parseModule;
    import dmd.globals: global;
    import std.conv: text;
    import quickbite.frontend.compiler: withCompilerLock;

    bool result;
    withCompilerLock(() {
        import core.atomic: atomicFetchAdd;

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        auto parsed = parseModule(
            text("repl_cell_", atomicFetchAdd(_replModuleCounter, 1u), ".d"),
            input,
        );
        result = parsed.diagnostics.hasErrors &&
            parsed.module_.members !is null &&
            parsed.module_.members.length != 0 &&
            allFunctionDeclarations(parsed.module_.members) &&
            hasDiagnosticAtEnd(input);
    });

    return result;
}

private bool allFunctionDeclarations(imported!"dmd.dsymbol".Dsymbols* declarations) {
    foreach (declaration; *declarations) {
        if (declaration.isFuncDeclaration is null)
            return false;
    }

    return true;
}

private bool hasDiagnosticAtEnd(in string input) {
    import dmd.errors: diagnostics, ErrorKind;

    foreach (diagnostic; diagnostics) {
        if (diagnostic.kind == ErrorKind.error &&
            diagnostic.loc.fileOffset == input.length)
            return true;
    }

    return false;
}

private string replSource(in string moduleTranscript, in string localTranscript) {
    return moduleTranscript ~ "auto f() { " ~ localTranscript ~ " }";
}

private __gshared uint _replModuleCounter;

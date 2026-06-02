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
    private ReplHistoryTarget historyTarget;
    private string history;
}

public ReplCell evalCell(in string source) {
    return ReplCell(
        ReplCellKind.expression,
        replSource(null, evalLocalTranscript(source)),
        ReplHistoryTarget.local,
        "",
    );
}

public imported!"dmd.func".FuncDeclaration replFunction(in ReplCell cell) {
    import quickbite.frontend.compiler: parseModule;

    return trailingFunctionDeclaration(parseModule(cell.source).module_);
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

        if (!isExpressionCell(input)) {
            if (const diagnostic = statementSyntaxDiagnostic(input))
                throw new Exception(diagnostic);

            return ReplCell(
                ReplCellKind.noDisplay,
                replSource(moduleTranscript, localTranscript ~ input ~ "\n"),
                ReplHistoryTarget.local,
                input ~ "\n",
            );
        }

        if (isTypeExpressionCell(input))
            return ReplCell(
                ReplCellKind.typeExpression,
                replSource(
                    moduleTranscript,
                    localTranscript ~ "return " ~ input ~ ".stringof;",
                ),
                ReplHistoryTarget.local,
                "",
            );

        const source = replSource(
            moduleTranscript,
            localTranscript ~ "return " ~ input ~ ";",
        );
        return ReplCell(
            ReplCellKind.expression,
            source,
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

    public void loadModuleSource(in string source) {
        moduleTranscript ~= source ~ "\n";
    }

    public string loadedModuleSource() const @safe pure {
        return moduleTranscript;
    }
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
            expression.isDeclarationExp is null &&
            parser.token.value != TOK.semicolon &&
            global.errors == 0;
    });

    return result;
}

private string statementSyntaxDiagnostic(in string input) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.parse: Parser;
    import quickbite.frontend.compiler: withCompilerLock;

    string result;
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
        parser.parseStatement(0);
        if (global.errors != 0)
            result = firstDiagnosticMessage;
    });

    return result;
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
            allReplModuleDeclarations(parsed.module_.members) &&
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

private bool allReplModuleDeclarations(imported!"dmd.dsymbol".Dsymbols* declarations) {
    foreach (declaration; *declarations) {
        if (!isReplModuleDeclaration(declaration))
            return false;
    }

    return true;
}

private bool isReplModuleDeclaration(imported!"dmd.dsymbol".Dsymbol declaration) {
    return declaration.isFuncDeclaration !is null ||
        declaration.isImport !is null ||
        declaration.isUnitTestDeclaration !is null;
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

private string firstDiagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;

    foreach (diagnostic; diagnostics) {
        if (diagnostic.kind == ErrorKind.error)
            return diagnostic.message;
    }

    return "DMD reported an error without a diagnostic message.";
}

private string evalLocalTranscript(in string source) {
    const sourceWithTerminator = source ~ ";";
    const returnOffset = finalExpressionStatementOffset(sourceWithTerminator);
    return sourceWithTerminator[0 .. returnOffset] ~
        "return " ~
        sourceWithTerminator[returnOffset .. $];
}

private uint finalExpressionStatementOffset(in string source) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.errorsink: ErrorSinkNull;
    import dmd.globals: global;
    import dmd.parse: Parser, ParseStatementFlags;
    import dmd.statement: Statement;
    import dmd.tokens: TOK;
    import quickbite.frontend.compiler: resetErrors, withCompilerLock;

    uint result;
    bool found;
    withCompilerLock(() {
        resetErrors;

        auto errorSink = new ErrorSinkNull;
        scope parser = new Parser!ASTCodegen(
            null,
            source ~ '\0',
            false,
            errorSink,
            &global.compileEnv,
            true,
        );

        parser.nextToken;

        Statement statement;
        while (parser.token.value != TOK.endOfFile) {
            statement = parser.parseStatement(ParseStatementFlags.semiOk);
            if (global.errors != 0)
                throw new Exception(firstDiagnosticMessage);
        }

        auto expression = statement is null ? null : statement.isExpStatement;
        if (expression is null ||
            expression.exp is null ||
            expression.exp.isDeclarationExp !is null)
            throw new Exception("Eval source must end with an expression.");

        result = expression.loc.fileOffset;
        found = true;
    });

    if (!found)
        throw new Exception("Eval source must end with an expression.");

    return result;
}

private imported!"dmd.func".FuncDeclaration trailingFunctionDeclaration(
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members !is null) {
        foreach_reverse (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ !is null)
                return function_;
        }
    }

    throw new Exception("Missing REPL wrapper function.");
}

private string replSource(in string moduleTranscript, in string localTranscript) {
    return moduleTranscript ~ "auto f() { " ~ localTranscript ~ " }";
}

private __gshared uint _replModuleCounter;

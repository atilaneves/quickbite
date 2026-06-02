module quickbite.frontend.cell;

private:

public enum EvalCellKind {
    incomplete,
    noDisplay,
    expression,
}

public struct EvalCell {
    public EvalCellKind kind;
    public string source;
    private EvalHistoryTarget historyTarget;
    private string history;
}

private enum EvalHistoryTarget {
    local,
    module_,
}

public struct EvalSession {
    private string localTranscript;
    private string moduleTranscript;
    private uint valueCellCount;

    public EvalCell submit(in string input) {
        return submitImpl(input, true);
    }

    public EvalCell submitComplete(in string input) {
        return submitImpl(input, false);
    }

    private EvalCell submitImpl(
        in string input,
        in bool allowIncomplete,
    ) {
        import std.conv: text;

        if (allowIncomplete && isIncompleteCell(input))
            return EvalCell(EvalCellKind.incomplete);

        if (isModuleDeclarationCell(input))
            return EvalCell(
                EvalCellKind.noDisplay,
                evalSource(moduleTranscript ~ input ~ "\n", localTranscript),
                EvalHistoryTarget.module_,
                input ~ "\n",
            );

        if (!isExpressionCell(input)) {
            if (const diagnostic = statementSyntaxDiagnostic(input))
                throw new Exception(diagnostic);

            return EvalCell(
                EvalCellKind.noDisplay,
                evalSource(moduleTranscript, localTranscript ~ input ~ "\n"),
                EvalHistoryTarget.local,
                input ~ "\n",
            );
        }

        const source = evalSource(
            moduleTranscript,
            localTranscript ~ "return " ~ input ~ ";",
        );
        return EvalCell(
            EvalCellKind.expression,
            source,
            EvalHistoryTarget.local,
            text(
                "auto __quickbite_repl_value_",
                valueCellCount,
                " = ",
                input,
                ";\n",
            ),
        );
    }

    public void accept(in EvalCell cell) {
        final switch (cell.historyTarget) with (EvalHistoryTarget) {
            case local:
                localTranscript ~= cell.history;
                break;
            case module_:
                moduleTranscript ~= cell.history;
                break;
        }

        if (cell.kind == EvalCellKind.expression)
            ++valueCellCount;
    }

    public void loadModuleSource(in string source) {
        moduleTranscript ~= source ~ "\n";
    }

    public string loadedModuleSource() const @safe pure {
        return moduleTranscript;
    }
}

public imported!"dmd.func".FuncDeclaration parseEvalFunction(in string source) {
    import quickbite.frontend.compiler: parseModule;
    import std.string: lineSplitter;

    EvalSession session;
    foreach (line; source.lineSplitter) {
        const cell = session.submitComplete(line);
        final switch (cell.kind) with (EvalCellKind) {
            case incomplete:
                throw new Exception("Incomplete eval input.");
            case noDisplay:
                session.accept(cell);
                break;
            case expression:
                return evalFunction(parseModule(cell.source).module_);
        }
    }

    throw new Exception("Eval input did not end with an expression.");
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
            text("eval_cell_", atomicFetchAdd(_evalModuleCounter, 1u), ".d"),
            input,
        );
        result = !parsed.diagnostics.hasErrors &&
            parsed.module_.members !is null &&
            parsed.module_.members.length != 0 &&
            allEvalModuleDeclarations(parsed.module_.members) &&
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
            text("eval_cell_", atomicFetchAdd(_evalModuleCounter, 1u), ".d"),
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

private bool allEvalModuleDeclarations(
    imported!"dmd.dsymbol".Dsymbols* declarations,
) {
    foreach (declaration; *declarations) {
        if (!isEvalModuleDeclaration(declaration))
            return false;
    }

    return true;
}

private bool isEvalModuleDeclaration(
    imported!"dmd.dsymbol".Dsymbol declaration,
) {
    return declaration.isFuncDeclaration !is null ||
        declaration.isImport !is null ||
        declaration.isUnitTestDeclaration !is null;
}

private bool allFunctionDeclarations(
    imported!"dmd.dsymbol".Dsymbols* declarations,
) {
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

private string evalSource(
    in string moduleTranscript,
    in string localTranscript,
) {
    return moduleTranscript ~ "auto f() { " ~ localTranscript ~ " }";
}

private imported!"dmd.func".FuncDeclaration evalFunction(
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ !is null && function_.ident.toString == "f")
                return function_;
        }
    }

    throw new Exception("Missing eval function.");
}

private __gshared uint _evalModuleCounter;

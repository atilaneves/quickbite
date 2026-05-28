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

private enum ReplHistoryTarget {
    none,
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

        if (isTypeExpressionCell(moduleTranscript, localTranscript, input))
            return ReplCell(
                ReplCellKind.typeExpression,
                typeReplSource(moduleTranscript, localTranscript, input),
                ReplHistoryTarget.none,
                null,
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
            case none:
                break;
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

private bool isTypeExpressionCell(
    in string moduleTranscript,
    in string localTranscript,
    in string input,
) {
    import quickbite.frontend.compiler: parseModule;

    try {
        auto parsed = parseModule(typeReplSource(
            moduleTranscript,
            localTranscript,
            input,
        ));
        const alias_ = replTypeAlias(parsed.module_);
        return alias_ !is null && alias_.type !is null;
    } catch (Exception) {
        return false;
    }
}

private imported!"dmd.declaration".AliasDeclaration replTypeAlias(
    imported!"dmd.dmodule".Module module_,
) {
    auto function_ = replFunction(module_);
    if (function_ is null)
        return null;

    imported!"dmd.declaration".AliasDeclaration result;
    foreachStatement(function_.fbody, (statement) {
        if (result !is null)
            return;

        auto expressionStatement = statement.isExpStatement;
        if (expressionStatement is null)
            return;

        auto declarationExpression = expressionStatement.exp.isDeclarationExp;
        if (declarationExpression is null)
            return;

        auto alias_ = declarationExpression.declaration.isAliasDeclaration;
        if (alias_ !is null && alias_.ident.toString == "__quickbite_repl_type")
            result = alias_;
    });

    return result;
}

private imported!"dmd.func".FuncDeclaration replFunction(
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members is null)
        return null;

    foreach (member; *module_.members) {
        auto function_ = member.isFuncDeclaration;
        if (function_ !is null && function_.ident.toString == "f")
            return function_;
    }

    return null;
}

private void foreachStatement(
    imported!"dmd.statement".Statement statement,
    scope void delegate(imported!"dmd.statement".Statement) visit,
) {
    if (statement is null)
        return;

    visit(statement);

    auto compound = statement.isCompoundStatement;
    if (compound is null || compound.statements is null)
        return;

    foreach (child; *compound.statements)
        foreachStatement(child, visit);
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
        declaration.isImport !is null;
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

private string typeReplSource(
    in string moduleTranscript,
    in string localTranscript,
    in string input,
) {
    return replSource(
        moduleTranscript,
        localTranscript ~ "alias __quickbite_repl_type = " ~ input ~ ";",
    );
}

private __gshared uint _replModuleCounter;

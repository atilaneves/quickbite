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
    public imported!"dmd.func".FuncDeclaration function_;
    private EvalHistoryTarget historyTarget;
    private string history;
}

public struct EvalSourceParseResult {
    public string source;
    public imported!"dmd.func".FuncDeclaration function_;
}

private struct LoadedModuleSource {
    public string source;
    public string filePath;
}

private enum EvalHistoryTarget {
    local,
    module_,
}

public struct EvalSession {
    private string[] importPaths;
    private string localTranscript;
    private LoadedModuleSource[] loadedModuleSources;
    private string moduleTranscript;
    private uint valueCellCount;

    public this(in string[] importPaths) {
        this.importPaths = importPaths.dup;
    }

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

        if (isModuleDeclarationCell(input)) {
            const source = evalSource(
                moduleSource(moduleTranscript ~ input ~ "\n"),
                localTranscript,
            );
            return evalCellFromSource(
                EvalCellKind.noDisplay,
                source,
                importPaths,
                EvalHistoryTarget.module_,
                input ~ "\n",
            );
        }

        if (!isExpressionCell(input)) {
            if (const diagnostic = statementSyntaxDiagnostic(input))
                throw new Exception(diagnostic);

            const source = evalSource(
                moduleSource,
                localTranscript ~ input ~ "\n",
            );
            return evalCellFromSource(
                EvalCellKind.noDisplay,
                source,
                importPaths,
                EvalHistoryTarget.local,
                input ~ "\n",
            );
        }

        const source = evalSource(
            moduleSource,
            localTranscript ~ "return " ~ input ~ ";",
        );
        return evalCellFromSource(
            EvalCellKind.expression,
            source,
            importPaths,
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
        loadedModuleSources ~= LoadedModuleSource(source, null);
    }

    public void loadModuleFile(in string filePath, in string source) {
        loadedModuleSources ~= LoadedModuleSource(source, filePath);
    }

    public string loadedModuleSource() const @safe pure {
        return moduleSource;
    }

    private string moduleSource() const @safe pure {
        return moduleSource(moduleTranscript);
    }

    private string moduleSource(in string replModuleTranscript) const
    @safe pure {
        if (loadedModuleSources.length == 0)
            return replModuleTranscript;

        string result;
        foreach (ref loadedModuleSource; loadedModuleSources)
            result ~= loadedModuleSource.toSource;

        return result ~ replLineDirective ~ replModuleTranscript;
    }
}

private string toSource(ref const LoadedModuleSource loadedModuleSource)
@safe pure {
    if (loadedModuleSource.filePath.length == 0)
        return loadedModuleSource.source ~ "\n";

    return lineDirective(loadedModuleSource.filePath) ~
        loadedModuleSource.source ~
        "\n";
}

private string replLineDirective() @safe pure {
    return lineDirective("<repl>");
}

private string lineDirective(in string filePath) @safe pure {
    return `#line 1 "` ~ escapedLineDirectiveFilePath(filePath) ~ `"` ~ "\n";
}

private string escapedLineDirectiveFilePath(in string filePath) @safe pure {
    string result;
    foreach (character; filePath) {
        if (character == '\\' || character == '"')
            result ~= '\\';
        result ~= character;
    }

    return result;
}

public EvalSourceParseResult parseEvalSource(in string source) {
    import quickbite.frontend.compiler: parseModule;

    const evalSource = completeEvalSource(source);
    try {
        auto moduleResult = parseModule(evalSource);
        return EvalSourceParseResult(
            evalSource,
            evalFunction(moduleResult.module_),
        );
    } catch (Exception exception) {
        throw new Exception(withCandidateSignatures(evalSource, exception.msg));
    }
}

public string withCandidateSignatures(
    in string source,
    in string diagnostic,
) {
    import std.array: join;
    import std.conv: text;

    const signatures = candidateSignatures(source);
    if (signatures.length == 0)
        return diagnostic;

    if (signatures.length == 1)
        return text(diagnostic, "\nCandidate: ", signatures[0]);

    return text(diagnostic, "\nCandidates:\n- ", signatures.join("\n- "));
}

private EvalCell evalCellFromSource(
    in EvalCellKind kind,
    in string source,
    in string[] importPaths,
    in EvalHistoryTarget historyTarget,
    in string history,
) {
    import quickbite.frontend.compiler: parseModule;

    try {
        auto moduleResult = parseModule(source, importPaths);
        return EvalCell(
            kind,
            source,
            evalFunction(moduleResult.module_),
            historyTarget,
            history,
        );
    } catch (Exception exception) {
        throw new Exception(withCandidateSignatures(source, exception.msg));
    }
}

private string[] candidateSignatures(in string source) {
    import core.atomic: atomicFetchAdd;
    import dmd.errors: diagnostics;
    import dmd.frontend: dmdParseModule = parseModule;
    import dmd.globals: global;
    import quickbite.frontend.compiler: withCompilerLock;
    import std.conv: text;

    string[] result;
    withCompilerLock(() {
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        auto moduleResult = dmdParseModule(
            text(
                "eval_diagnostic_",
                atomicFetchAdd(_diagnosticModuleCounter, 1u),
                ".d",
            ),
            source,
        );
        if (moduleResult.diagnostics.hasErrors)
            return;

        auto call = evalReturnCall(moduleResult.module_);
        if (call is null)
            return;

        auto callee = call.e1.isIdentifierExp;
        if (callee is null)
            return;

        auto candidates = candidateFunctions(moduleResult.module_, callee.ident);
        if (candidates.length == 0)
            return;

        completeSemanticForDiagnostics(moduleResult.module_);
        if (
            !callArgumentsHaveTypes(call) ||
            hasMatchingCandidate(call, candidates)
        )
            return;

        result = candidateSignatures(candidates);
    });

    return result;
}

private imported!"dmd.expression".CallExp evalReturnCall(
    imported!"dmd.dmodule".Module module_,
) {
    auto function_ = evalFunction(module_);
    if (function_.fbody is null)
        return null;

    if (auto return_ = function_.fbody.isReturnStatement)
        return return_.exp is null ? null : return_.exp.isCallExp;

    auto compound = function_.fbody.isCompoundStatement;
    if (compound is null || compound.statements is null)
        return null;

    for (size_t index = compound.statements.length; index > 0; --index) {
        auto statement = (*compound.statements)[index - 1];
        if (statement is null)
            continue;

        if (auto return_ = statement.isReturnStatement)
            return return_.exp is null ? null : return_.exp.isCallExp;
    }

    return null;
}

private imported!"dmd.func".FuncDeclaration[] candidateFunctions(
    imported!"dmd.dmodule".Module module_,
    imported!"dmd.identifier".Identifier identifier,
) {
    imported!"dmd.func".FuncDeclaration[] result;
    if (module_.members is null)
        return result;

    foreach (member; *module_.members) {
        auto function_ = member.isFuncDeclaration;
        if (function_ !is null && function_.ident is identifier)
            appendOverloads(result, function_);
    }

    return result;
}

private void appendOverloads(
    ref imported!"dmd.func".FuncDeclaration[] functions,
    imported!"dmd.func".FuncDeclaration function_,
) {
    auto current = function_;
    while (current !is null) {
        functions ~= current;
        auto next = current.overnext;
        current = next is null ? null : next.isFuncDeclaration;
    }
}

private void completeSemanticForDiagnostics(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.errors: diagnostics;
    import dmd.frontend: fullSemantic;
    import dmd.globals: global;

    global.errors = 0;
    global.warnings = 0;
    diagnostics.length = 0;

    const oldGagged = global.startGagging;
    module_.fullSemantic;
    global.endGagging(oldGagged);

    global.errors = 0;
    global.warnings = 0;
    diagnostics.length = 0;
}

private bool callArgumentsHaveTypes(
    imported!"dmd.expression".CallExp call,
) {
    if (call.arguments is null)
        return true;

    foreach (argument; *call.arguments) {
        if (argument is null || argument.type is null)
            return false;
    }

    return true;
}

private bool hasMatchingCandidate(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration[] candidates,
) {
    import dmd.astenums: MATCH;
    import dmd.typesem: callMatch;

    foreach (candidate; candidates) {
        auto type = candidate.type is null
            ? null
            : candidate.type.isTypeFunction;
        if (type is null)
            continue;

        if (callMatch(
            candidate,
            type,
            null,
            call.argumentList,
            0,
            null,
            candidate._scope,
        ) > MATCH.nomatch)
            return true;
    }

    return false;
}

private string[] candidateSignatures(
    imported!"dmd.func".FuncDeclaration[] candidates,
) {
    string[] result;
    foreach (candidate; candidates)
        result ~= fullSignature(candidate);

    return result;
}

private string fullSignature(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.string: fromStringz;

    return fromStringz(function_.toFullSignature).idup;
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

        const source = input ~ ";\0";
        scope parser = new Parser!ASTCodegen(
            null,
            source,
            false,
            global.errorSink,
            &global.compileEnv,
            true,
        );

        parser.nextToken;
        const statement = parser.parseStatement(0);
        const expression = statement is null ? null : statement.isExpStatement;
        result = expression !is null &&
            expression.exp !is null &&
            expression.exp.isDeclarationExp is null &&
            parser.token.value == TOK.endOfFile &&
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

        auto moduleResult = parseModule(
            text("eval_cell_", atomicFetchAdd(_evalModuleCounter, 1u), ".d"),
            input,
        );
        result = !moduleResult.diagnostics.hasErrors &&
            moduleResult.module_.members !is null &&
            moduleResult.module_.members.length != 0 &&
            allEvalModuleDeclarations(moduleResult.module_.members) &&
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

        auto moduleResult = parseModule(
            text("eval_cell_", atomicFetchAdd(_evalModuleCounter, 1u), ".d"),
            input,
        );
        result = moduleResult.diagnostics.hasErrors &&
            moduleResult.module_.members !is null &&
            moduleResult.module_.members.length != 0 &&
            allFunctionDeclarations(moduleResult.module_.members) &&
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
    if (declaration.isImport !is null)
        return true;

    if (declaration.isUnitTestDeclaration !is null)
        return true;

    if (isEvalFunctionDeclaration(declaration))
        return true;

    return false;
}

private bool isEvalFunctionDeclaration(
    imported!"dmd.dsymbol".Dsymbol declaration,
) {
    auto function_ = declaration.isFuncDeclaration;
    return function_ !is null && function_.fbody !is null;
}

private bool allFunctionDeclarations(
    imported!"dmd.dsymbol".Dsymbols* declarations,
) {
    foreach (declaration; *declarations) {
        if (!isEvalFunctionDeclaration(declaration))
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

private string completeEvalSource(in string source) {
    const expressionStart = finalExpressionStart(source);
    return evalSource(
        null,
        source[0 .. expressionStart] ~
            "return " ~
            source[expressionStart .. $] ~
            ";",
    );
}

private size_t finalExpressionStart(in string source) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.parse: Parser;
    import dmd.tokens: TOK;
    import quickbite.frontend.compiler: withCompilerLock;

    size_t result = size_t.max;
    withCompilerLock(() {
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const parseSource = source ~ ";\0";
        scope parser = new Parser!ASTCodegen(
            null,
            parseSource,
            false,
            global.errorSink,
            &global.compileEnv,
            true,
        );

        parser.nextToken;
        while (parser.token.value != TOK.endOfFile) {
            auto statement = parser.parseStatement(0);
            if (statement is null)
                break;

            auto expression = statement.isExpStatement;
            if (expression !is null &&
                expression.exp !is null &&
                expression.exp.isDeclarationExp is null)
                result = statement.loc.fileOffset;
            else
                result = size_t.max;
        }

        if (global.errors != 0)
            result = size_t.max;
    });

    if (result == size_t.max)
        throw new Exception("Eval input did not end with an expression.");

    return result;
}

private imported!"dmd.func".FuncDeclaration evalFunction(
    imported!"dmd.dmodule".Module module_,
) {
    imported!"dmd.func".FuncDeclaration result;
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ is null)
                continue;

            result = function_;
        }
    }

    if (result is null)
        throw new Exception("Missing eval function.");

    return result;
}

private __gshared uint _evalModuleCounter;
private __gshared uint _diagnosticModuleCounter;

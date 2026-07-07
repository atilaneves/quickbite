module quickbite.frontend.cell;

private:


public struct Cell {
    public enum Kind {
        incomplete,
        noDisplay,
        expression,
    }

    public Kind kind;
    public string source;
    public imported!"dmd.func".FuncDeclaration function_;
    private EvalHistoryTarget historyTarget;
    private string history;
    private string[] declaredNames;
    private string[] moduleFunctionSignatures;
    private string[] promotedLocalNames;
    private TranscriptCell[] promotedLocalCells;
    public bool displayIsFormatted;
}

public struct EvalSourceParseResult {
    public string source;
    public imported!"dmd.func".FuncDeclaration function_;
}

private struct LoadedModuleSource {
    public string source;
    public string filePath;
}

private struct TranscriptCell {
    public string source;
    public Cell.Kind kind;
    public string[] declaredNames;
    public string[] functionSignatures;
    public uint cellNumber;
}

private enum EvalHistoryTarget {
    local,
    module_,
}

public struct EvalSession {
    private string[] importPaths;
    private TranscriptCell[] localCells;
    private LoadedModuleSource[] loadedModuleSources;
    private TranscriptCell[] moduleCells;
    private uint evalCellCount;
    private uint valueCellCount;
    private bool formatExpressionCells;

    public this(in string[] importPaths, in bool formatExpressionCells = false) {
        this.formatExpressionCells = formatExpressionCells;
        this.importPaths = formatExpressionCells
            ? importPaths.withReplPreludeImportPath
            : importPaths.dup;
    }

    public Cell submit(in string input) {
        return submitImpl(input, true);
    }

    public Cell submitComplete(in string input) {
        return submitImpl(input, false);
    }

    public bool isTypeExpressionCell(in string input) {
        return isReplTypeExpressionCell(input, moduleSource, importPaths);
    }

    // The resolved type name for a type-expression cell, or null when the type
    // cannot be resolved in the frontend. Equals `input.stringof` evaluated by
    // a backend (DMD computes a type's `.stringof` via the same `Type.toChars`
    // this returns), letting the REPL answer `:t`/type cells without a backend
    // round-trip.
    public string typeExpressionName(in string input) {
        return resolvedTypeExpressionName(input, moduleSource, importPaths);
    }

    private Cell submitImpl(
        in string input,
        in bool allowIncomplete,
    ) {
        import std.conv: text;

        const evalFunctionName = syntheticEvalFunctionName(evalCellCount);
        if (allowIncomplete && isIncompleteCell(input))
            return Cell(Cell.Kind.incomplete);

        if (isModuleDeclarationCell(input)) {
            const moduleFunctionSignatures = functionDeclarationSignatures(input);
            const promotedLocalNames = referencedLocalDeclaredNames(
                input,
                localCells,
                moduleFunctionSignatures,
            );
            const promotedLocalCells = cellsDeclaringNames(
                localCells,
                promotedLocalNames,
            );
            const moduleCells = moduleCellsWithReplacements(
                moduleCells,
                moduleFunctionSignatures,
            );
            const localCells = localCellsWithoutDeclaredNames(
                localCells,
                promotedLocalNames,
            );
            const source = evalSource(
                moduleSource(
                    transcriptSource(moduleCells) ~
                    transcriptSource(promotedLocalCells) ~
                    input ~
                    "\n",
                ),
                transcriptSource(localCells),
                evalFunctionName,
            );
            return evalCellFromSource(
                Cell.Kind.noDisplay,
                source,
                importPaths,
                EvalHistoryTarget.module_,
                input ~ "\n",
                [],
                moduleFunctionSignatures,
                promotedLocalNames,
                promotedLocalCells,
            );
        }

        if (!isExpressionCell(input)) {
            if (const diagnostic = statementSyntaxDiagnostic(input))
                throw new Exception(diagnostic);

            const declaredNames = localVariableDeclarationNames(input);
            const history = input.isStandalonePragmaMessageStatement ?
                null :
                input ~ "\n";
            const localCells = localCellsWithRebindings(
                localCells,
                declaredNames,
            );
            const source = evalSource(
                moduleSource,
                localTranscriptSource(localCells) ~ input ~ "\n",
                evalFunctionName,
            );
            return evalCellFromSource(
                Cell.Kind.noDisplay,
                source,
                importPaths,
                EvalHistoryTarget.local,
                history,
                declaredNames,
                [],
                [],
                [],
            );
        }

        const rawSource = evalSource(
            moduleSource,
            localTranscriptSource ~ expressionReturnSource(
                input,
                false,
            ),
            evalFunctionName,
        );
        const formatExpression = formatExpressionCells &&
            expressionReturnNeedsPreludeFormat(rawSource, importPaths);
        const source = formatExpression
            ? evalSource(
                moduleSource,
                localTranscriptSource ~ expressionReturnSource(input, true),
                evalFunctionName,
            )
            : rawSource;
        return evalCellFromSource(
            Cell.Kind.expression,
            source,
            importPaths,
            EvalHistoryTarget.local,
            expressionHistory(input, valueCellCount),
            [],
            [],
            [],
            [],
            formatExpression,
        );
    }

    public void accept(in Cell cell) {
        const cellNumber = evalCellCount + 1;
        final switch (cell.historyTarget) with (EvalHistoryTarget) {
            case local:
                localCells = localCellsWithRebindings(
                    localCells,
                    cell.declaredNames,
                );
                localCells ~= TranscriptCell(
                    cell.history,
                    cell.kind,
                    cell.declaredNames.dup,
                    [],
                    cellNumber,
                );
                break;
            case module_:
                localCells = localCellsWithoutDeclaredNames(
                    localCells,
                    cell.promotedLocalNames,
                );
                foreach (ref promotedCell; cell.promotedLocalCells)
                    moduleCells ~= TranscriptCell(
                        promotedCell.source,
                        promotedCell.kind,
                        promotedCell.declaredNames.dup,
                        promotedCell.functionSignatures.dup,
                        promotedCell.cellNumber,
                    );
                moduleCells = moduleCellsWithReplacements(
                    moduleCells,
                    cell.moduleFunctionSignatures.dup,
                );
                moduleCells ~= TranscriptCell(
                    cell.history,
                    cell.kind,
                    [],
                    cell.moduleFunctionSignatures.dup,
                    cellNumber,
                );
                break;
        }

        ++evalCellCount;
        if (cell.kind == Cell.Kind.expression)
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
        return moduleSource(transcriptSource(moduleCells));
    }

    private string localTranscriptSource() const @safe pure {
        return transcriptSource(localCells) ~ valueCellCount.latestValueBinding;
    }

    private string localTranscriptSource(
        const(TranscriptCell)[] cells,
    ) const @safe pure {
        return transcriptSource(cells) ~ valueCellCount.latestValueBinding;
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

private string latestValueBinding(in uint valueCellCount) @safe pure {
    import std.conv: text;

    if (valueCellCount == 0)
        return null;

    return text(
        "alias it = __quickbite_repl_value_",
        valueCellCount - 1,
        ";\n",
    );
}

private string expressionHistory(
    in string input,
    in uint valueCellCount,
) @safe pure {
    import std.conv: text;

    const valueSource = input == "it" && valueCellCount != 0
        ? text("__quickbite_repl_value_", valueCellCount - 1)
        : input;

    return text(
        "auto __quickbite_repl_value_",
        valueCellCount,
        " = ",
        valueSource,
        ";\n",
    );
}

private string expressionReturnSource(
    in string input,
    in bool formatExpression,
) @safe pure {
    if (!formatExpression)
        return "return " ~ input ~ ";";

    return
        "import quickbite.repl_prelude: __quickbiteFormat;\n" ~
        "return __quickbiteFormat(" ~ input ~ ");";
}

private bool expressionReturnNeedsPreludeFormat(
    in string source,
    in string[] importPaths,
) {
    import dmd.astenums: TY;
    import dmd.dmodule: Module;
    import quickbite.frontend.compiler: parseSnippet;

    Module module_;
    try {
        module_ = parseSnippet(source, importPaths).module_;
    } catch (Exception) {
        return false;
    }

    auto type = evalFunction(module_).type;
    auto functionType = type is null ? null : type.isTypeFunction;
    if (functionType is null || functionType.next is null)
        return false;

    auto returnType = functionType.next;
    if (returnType is null)
        return false;

    return typeNeedsPreludeFormat(returnType);
}

private bool typeNeedsPreludeFormat(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type.ty == TY.Tenum)
        return true;

    auto baseType = type.toBasetype;
    with (TY) switch (baseType.ty) {
        case Taarray:
            return true;
        case Tarray, Tsarray:
            return arrayElementNeedsPreludeFormat(baseType);
        case Tstruct:
            return structNeedsPreludeFormat(baseType);
        default:
            return false;
    }
}

private bool structNeedsPreludeFormat(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto structType = type.isTypeStruct;
    foreach (field; structType.sym.fields)
        if (field !is null && field.type !is null) {
            if (field.type.ty == TY.Tenum)
                return true;

            auto fieldType = field.type.toBasetype;
            with (TY) switch (fieldType.ty) {
                case Tint64, Tuns64:
                    return true;
                case Tclass:
                    return true;
                case Tdelegate:
                    return true;
                case Taarray:
                    return true;
                case Tarray, Tsarray:
                    return arrayElementNeedsPreludeFormat(fieldType);
                case Tpointer:
                    if (field.isThisDeclaration is null)
                        return true;
                    break;
                default:
                    break;
            }
        }

    return false;
}

private bool arrayElementNeedsPreludeFormat(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto elementType = type.nextOf;
    if (elementType is null)
        return false;

    if (elementType.ty == TY.Tenum)
        return true;

    with (TY) switch (elementType.toBasetype.ty) {
        case Tchar, Twchar, Tdchar:
            return true;
        case Tint64, Tuns64:
            return true;
        default:
            return false;
    }
}

private string[] withReplPreludeImportPath(in string[] importPaths) @safe pure {
    auto result = importPaths.dup;
    result ~= quickbiteSourceImportPath;
    return result;
}

private string quickbiteSourceImportPath() @safe pure {
    enum suffix = "/quickbite/frontend/cell.d";
    enum filePath = __FILE_FULL_PATH__;

    static assert(filePath.length > suffix.length);
    static assert(filePath[$ - suffix.length .. $] == suffix);

    return filePath[0 .. $ - suffix.length];
}

private string toSource(ref const LoadedModuleSource loadedModuleSource)
@safe pure {
    if (loadedModuleSource.filePath.length == 0)
        return loadedModuleSource.source ~ "\n";

    return lineDirective(loadedModuleSource.filePath) ~
        loadedModuleSource.source ~
        "\n";
}

private string transcriptSource(
    const(TranscriptCell)[] cells,
) @safe pure {
    string result;
    foreach (ref cell; cells) {
        if (cell.source.length == 0)
            continue;

        result ~= replCellLineDirective(cell.cellNumber) ~ cell.source;
    }

    return result;
}

private TranscriptCell[] moduleCellsWithReplacements(
    const(TranscriptCell)[] moduleCells,
    in string[] functionSignatures,
) @safe pure {
    TranscriptCell[] result;
    foreach (ref cell; moduleCells) {
        if (hasFunctionSignature(cell, functionSignatures))
            continue;

        result ~= TranscriptCell(
            cell.source,
            cell.kind,
            cell.declaredNames.dup,
            cell.functionSignatures.dup,
            cell.cellNumber,
        );
    }

    return result;
}

private TranscriptCell[] localCellsWithRebindings(
    const(TranscriptCell)[] localCells,
    in string[] declaredNames,
) {
    import std.conv: text;

    TranscriptCell[] result;
    foreach (ref cell; localCells)
        result ~= TranscriptCell(
            cell.source,
            cell.kind,
            cell.declaredNames.dup,
            cell.functionSignatures.dup,
            cell.cellNumber,
        );

    foreach (declaredName; declaredNames) {
        const index = latestCellDeclaring(result, declaredName);
        if (index == size_t.max)
            continue;

        const hiddenName = text(
            "__quickbite_repl_local_",
            result[index].cellNumber,
            "_",
            declaredName,
        );
        foreach (cellIndex; index .. result.length) {
            result[cellIndex].source = rewriteIdentifierTokens(
                result[cellIndex].source,
                declaredName,
                hiddenName,
            );
            foreach (ref name; result[cellIndex].declaredNames) {
                if (name == declaredName)
                    name = hiddenName;
            }
        }
    }

    return result;
}

private TranscriptCell[] localCellsWithoutDeclaredNames(
    const(TranscriptCell)[] localCells,
    in string[] declaredNames,
) @safe pure {
    TranscriptCell[] result;
    foreach (ref cell; localCells) {
        if (declaresAnyName(cell, declaredNames))
            continue;

        result ~= TranscriptCell(
            cell.source,
            cell.kind,
            cell.declaredNames.dup,
            cell.functionSignatures.dup,
            cell.cellNumber,
        );
    }

    return result;
}

private TranscriptCell[] cellsDeclaringNames(
    const(TranscriptCell)[] cells,
    in string[] declaredNames,
) @safe pure {
    TranscriptCell[] result;
    foreach (ref cell; cells) {
        if (!declaresAnyName(cell, declaredNames))
            continue;

        result ~= TranscriptCell(
            cell.source,
            cell.kind,
            cell.declaredNames.dup,
            cell.functionSignatures.dup,
            cell.cellNumber,
        );
    }

    return result;
}

private bool declaresAnyName(
    ref const TranscriptCell cell,
    in string[] declaredNames,
) @safe pure {
    foreach (declaredName; declaredNames) {
        if (cellDeclares(cell, declaredName))
            return true;
    }

    return false;
}

private size_t latestCellDeclaring(
    const(TranscriptCell)[] cells,
    in string declaredName,
) @safe pure {
    for (size_t index = cells.length; index > 0; --index) {
        if (cellDeclares(cells[index - 1], declaredName))
            return index - 1;
    }

    return size_t.max;
}

private bool cellDeclares(
    ref const TranscriptCell cell,
    in string declaredName,
) @safe pure {
    foreach (cellDeclaredName; cell.declaredNames) {
        if (cellDeclaredName == declaredName)
            return true;
    }

    return false;
}

private bool hasFunctionSignature(
    ref const TranscriptCell cell,
    in string[] functionSignatures,
) @safe pure {
    foreach (cellSignature; cell.functionSignatures) {
        foreach (signature; functionSignatures) {
            if (cellSignature == signature)
                return true;
        }
    }

    return false;
}

private string replCellLineDirective(in uint cellNumber) @safe pure {
    import std.conv: text;

    return lineDirective(text("<repl cell ", cellNumber, ">"));
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
    import quickbite.frontend.compiler: parseSnippet;

    const evalSource = completeEvalSource(source);
    try {
        auto moduleResult = parseSnippet(evalSource);
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

private Cell evalCellFromSource(
    in Cell.Kind kind,
    in string source,
    in string[] importPaths,
    in EvalHistoryTarget historyTarget,
    in string history,
    in string[] declaredNames,
    in string[] moduleFunctionSignatures,
    in string[] promotedLocalNames,
    in TranscriptCell[] promotedLocalCells,
    in bool displayIsFormatted = false,
) {
    import quickbite.frontend.compiler: parseSnippet;

    try {
        auto moduleResult = parseSnippet(source, importPaths);
        return Cell(
            kind,
            source,
            evalFunction(moduleResult.module_),
            historyTarget,
            history,
            declaredNames.dup,
            moduleFunctionSignatures.dup,
            promotedLocalNames.dup,
            copyTranscriptCells(promotedLocalCells),
            displayIsFormatted,
        );
    } catch (Exception exception) {
        throw new Exception(withCandidateSignatures(source, exception.msg));
    }
}

private TranscriptCell[] copyTranscriptCells(
    const(TranscriptCell)[] cells,
) @safe pure {
    TranscriptCell[] result;
    foreach (ref cell; cells)
        result ~= TranscriptCell(
            cell.source,
            cell.kind,
            cell.declaredNames.dup,
            cell.functionSignatures.dup,
            cell.cellNumber,
        );

    return result;
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
        const isExpressionStatement = expression !is null &&
            expression.exp !is null &&
            expression.exp.isDeclarationExp is null;
        const isMixinExpressionStatement = statement !is null &&
            statement.isMixinStatement !is null;
        result = (isExpressionStatement || isMixinExpressionStatement) &&
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

private string[] localVariableDeclarationNames(in string input) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.parse: Parser;
    import dmd.tokens: TOK;
    import quickbite.frontend.compiler: withCompilerLock;

    string[] result;
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
        auto statement = parser.parseStatement(0);
        auto expression = statement is null ? null : statement.isExpStatement;
        auto declaration = expression is null || expression.exp is null
            ? null
            : expression.exp.isDeclarationExp;
        auto variable = declaration is null
            ? null
            : declaration.declaration.isVarDeclaration;
        if (
            variable !is null &&
            variable.ident !is null &&
            parser.token.value == TOK.endOfFile &&
            global.errors == 0
        )
            result ~= variable.ident.toString.idup;
    });

    return result;
}

private string rewriteIdentifierTokens(
    in string source,
    in string from,
    in string to,
) {
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.lexer: Lexer;
    import dmd.tokens: TOK;
    import quickbite.frontend.compiler: withCompilerLock;

    string result;
    withCompilerLock(() {
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const parseSource = source ~ '\0';
        scope lexer = new Lexer(
            null,
            parseSource.ptr,
            0,
            parseSource.length - 1,
            false,
            false,
            global.errorSink,
            &global.compileEnv,
        );

        size_t copied;
        for (lexer.nextToken; lexer.token.value != TOK.endOfFile;
            lexer.nextToken) {
            if (
                lexer.token.value != TOK.identifier ||
                lexer.token.ident.toString != from
            )
                continue;

            const offset = cast(size_t)(lexer.token.ptr - parseSource.ptr);
            result ~= source[copied .. offset];
            result ~= to;
            copied = offset + from.length;
        }

        result ~= source[copied .. $];
    });

    return result;
}

private bool isStandalonePragmaMessageStatement(in string input) {
    import dmd.astcodegen: ASTCodegen;
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.id: Id;
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
        auto statement = parser.parseStatement(0);
        auto pragma_ = statement is null ? null : statement.isPragmaStatement;
        result = pragma_ !is null &&
            pragma_.ident is Id.msg &&
            parser.token.value == TOK.endOfFile &&
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

private string[] functionDeclarationSignatures(in string input) {
    import dmd.errors: diagnostics;
    import dmd.frontend: parseModule;
    import dmd.globals: global;
    import std.conv: text;
    import quickbite.frontend.compiler: withCompilerLock;

    string[] result;
    withCompilerLock(() {
        import core.atomic: atomicFetchAdd;

        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        auto moduleResult = parseModule(
            text("eval_cell_", atomicFetchAdd(_evalModuleCounter, 1u), ".d"),
            input,
        );
        if (
            moduleResult.diagnostics.hasErrors ||
            moduleResult.module_.members is null
        )
            return;

        foreach (declaration; *moduleResult.module_.members) {
            if (
                isEvalFunctionDeclaration(declaration) &&
                declaration.isUnitTestDeclaration is null &&
                declaration.ident !is null
            ) {
                auto function_ = declaration.isFuncDeclaration;
                result ~= replacementFunctionSignature(function_);
            }
        }
    });

    return result;
}

private string[] referencedLocalDeclaredNames(
    in string input,
    const(TranscriptCell)[] localCells,
    in string[] moduleFunctionSignatures,
) {
    if (moduleFunctionSignatures.length == 0)
        return [];

    string[] result;
    foreach (ref cell; localCells) {
        foreach (declaredName; cell.declaredNames) {
            if (
                !contains(result, declaredName) &&
                referencesIdentifier(input, declaredName)
            )
                result ~= declaredName;
        }
    }

    return result;
}

private bool contains(in string[] values, in string value) @safe pure {
    foreach (candidate; values) {
        if (candidate == value)
            return true;
    }

    return false;
}

private bool referencesIdentifier(in string source, in string identifier) {
    import dmd.errors: diagnostics;
    import dmd.globals: global;
    import dmd.lexer: Lexer;
    import dmd.tokens: TOK;
    import quickbite.frontend.compiler: withCompilerLock;

    bool result;
    withCompilerLock(() {
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        const parseSource = source ~ '\0';
        scope lexer = new Lexer(
            null,
            parseSource.ptr,
            0,
            parseSource.length - 1,
            false,
            false,
            global.errorSink,
            &global.compileEnv,
        );

        for (lexer.nextToken; lexer.token.value != TOK.endOfFile;
            lexer.nextToken) {
            if (
                lexer.token.value == TOK.identifier &&
                lexer.token.ident.toString == identifier
            ) {
                result = true;
                return;
            }
        }
    });

    return result;
}

private string replacementFunctionSignature(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    auto type = function_.type is null
        ? null
        : function_.type.isTypeFunction;
    return text(function_.ident.toString, "(", parameterSignature(type), ")");
}

private string parameterSignature(imported!"dmd.mtype".TypeFunction type) {
    import std.array: join;
    import std.conv: text;

    if (type is null)
        return null;

    string[] parameters;
    foreach (index; 0 .. type.parameterList.length) {
        auto parameter = type.parameterList[index];
        parameters ~= parameter.type is null
            ? null
            : parameter.type.typeSyntax;
    }

    return text(parameters.join(","), "/", type.parameterList.varargs);
}

private string typeSyntax(imported!"dmd.mtype".Type type) {
    import std.string: fromStringz;

    return fromStringz(type.toChars).idup;
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
            allEvalModuleDeclarations(moduleResult.module_.members) &&
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

    if (declaration.isAliasDeclaration !is null)
        return true;

    if (isEvalFunctionDeclaration(declaration))
        return true;

    if (declaration.isAggregateDeclaration !is null)
        return true;

    if (declaration.isEnumDeclaration !is null)
        return true;

    if (declaration.isTemplateDeclaration !is null)
        return true;

    return false;
}

private bool isReplTypeExpressionCell(
    in string input,
    in string moduleSource,
    in string[] importPaths,
) {
    return isParsedTypeExpressionCell(input) ||
        isResolvedTypeAliasCell(input, moduleSource, importPaths);
}

private bool isParsedTypeExpressionCell(in string input) {
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
            parser.token.value == TOK.endOfFile &&
            global.errors == 0;
    });

    return result;
}

private bool isResolvedTypeAliasCell(
    in string input,
    in string moduleSource,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseSnippetUncached;

    try {
        auto moduleResult = parseSnippetUncached(
            moduleSource ~ typeExpressionProbeSource(input),
            importPaths,
        );
        return syntheticTypeAlias(moduleResult.module_) !is null;
    } catch (Exception) {
        return false;
    }
}

private string resolvedTypeExpressionName(
    in string input,
    in string moduleSource,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseSnippetUncached;

    try {
        auto moduleResult = parseSnippetUncached(
            moduleSource ~ typeExpressionProbeSource(input),
            importPaths,
        );
        auto alias_ = syntheticTypeAlias(moduleResult.module_);
        return alias_ is null ? null : typeName(alias_.type);
    } catch (Exception) {
        return null;
    }
}

private string typeName(imported!"dmd.mtype".Type type) {
    import std.string: fromStringz;

    // @trusted: DMD's Type.toChars is not @safe; it reads the already-resolved
    // type and returns a borrowed C string we immediately copy with idup.
    static const(char)* toChars(imported!"dmd.mtype".Type type) @trusted {
        return type.toChars;
    }

    return fromStringz(toChars(type)).idup;
}

private string typeExpressionProbeSource(in string input) @safe pure {
    return "alias __quickbite_repl_type_expression_probe = " ~ input ~ ";\n";
}

private imported!"dmd.declaration".AliasDeclaration syntheticTypeAlias(
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members is null || module_.members.length == 0)
        return null;

    auto declaration = (*module_.members)[module_.members.length - 1];
    auto alias_ = declaration.isAliasDeclaration;
    return alias_ !is null && alias_.type !is null ? alias_ : null;
}

private bool isEvalFunctionDeclaration(
    imported!"dmd.dsymbol".Dsymbol declaration,
) {
    auto function_ = declaration.isFuncDeclaration;
    return function_ !is null && function_.fbody !is null;
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
    in string functionName,
) {
    return moduleTranscript ~ "auto " ~ functionName ~ "() { " ~
        localTranscript ~ " }";
}

private string completeEvalSource(in string source) {
    const expressionStart = finalExpressionStart(source);
    return evalSource(
        null,
        source[0 .. expressionStart] ~
            "return " ~
            source[expressionStart .. $] ~
            ";",
        syntheticEvalFunctionName(nextEvalFunctionIndex),
    );
}

private string syntheticEvalFunctionName(in uint index) @safe pure {
    import std.conv: text;

    return text("__quickbite_repl_eval_", index, "__");
}

private uint nextEvalFunctionIndex() {
    import core.atomic: atomicFetchAdd;

    return atomicFetchAdd(_evalFunctionCounter, 1u);
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
private __gshared uint _evalFunctionCounter;

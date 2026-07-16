module quickbite.frontend.dmd.functions;

private:

public bool hasNoAvailableSource(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.fbody is null;
}

// An `extern __gshared` global whose definition lives in a compiled dependency
// image: it is in the data segment, has no local initializer, and is declared
// `extern`. Reading it means resolving the native symbol (ffi.md §35.2a).
public bool isExternDataSymbol(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: STC;

    return variable.isDataseg &&
        variable._init is null &&
        (variable.storage_class & STC.extern_) != STC.none;
}

public string noAvailableSourceMessage(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    return text(
        "`",
        function_.toChars,
        "` cannot be interpreted at compile time, ",
        "because it has no available source code",
    );
}

// DMD consumes the individual statements inside a CompoundAsmStatement during
// semantic3 and keeps their lowered representation in backend-private data.
// Preserve every token before that boundary so non-native backends can
// recognise only the exact instruction subsets they implement without
// importing DMD backend internals.
public struct InlineAsmToken {
    public string kind;
    public string spelling;
}

private InlineAsmToken[][][
    imported!"dmd.statement".CompoundAsmStatement
] _inlineAsmInstructions;
private InlineAsmToken[][][InlineAsmSourceLocation]
    _inlineAsmInstructionsByLocation;
private bool[imported!"dmd.dmodule".Module] _inlineAsmReparsedModules;

private struct InlineAsmSourceLocation {
    string filename;
    uint line;
    uint column;
    uint fileOffset;
}

public void snapshotInlineAsmInstructions() {
    import dmd.dmodule: Module;

    bool[imported!"dmd.dsymbol".Dsymbol] visited;
    foreach (index; 0 .. Module.amodules.length) {
        auto module_ = Module.amodules[index];
        reparseInlineAsmInstructions(module_);
        snapshotSymbols(module_.members, visited);
    }
}

public const(InlineAsmToken[][]) inlineAsmInstructions(
    imported!"dmd.statement".CompoundAsmStatement statement,
) {
    const saved = statement in _inlineAsmInstructions;
    if (saved !is null)
        return *saved;
    const byLocation = inlineAsmSourceLocation(statement) in
        _inlineAsmInstructionsByLocation;
    return byLocation is null ? null : *byLocation;
}

private void snapshotSymbols(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    ref bool[imported!"dmd.dsymbol".Dsymbol] visited,
) {
    if (symbols is null)
        return;
    for (size_t index; index < symbols.length; ++index) {
        auto symbol = (*symbols)[index];
        if (symbol is null || (symbol in visited) !is null)
            continue;
        visited[symbol] = true;

        if (auto function_ = symbol.isFuncDeclaration)
            snapshotStatement(function_.fbody);

        if (auto attributes = symbol.isAttribDeclaration)
            snapshotSymbols(attributes.decl, visited);

        if (auto scope_ = symbol.isScopeDsymbol)
            snapshotSymbols(scope_.members, visited);
    }
}

// Imported modules can be loaded and have template bodies consumed entirely
// within one deferred-semantic pass. Reparse each retained source buffer once
// as syntax only, indexing asm by source location; instantiated syntax copies
// retain that location and therefore find the preserved instruction stream.
private void reparseInlineAsmInstructions(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.errorsink: ErrorSinkNull;
    import dmd.globals: global;
    import dmd.lexer: Lexer;
    import dmd.tokens: TOK;

    if (module_ is null || module_.src.length == 0 ||
        (module_ in _inlineAsmReparsedModules) !is null)
        return;
    _inlineAsmReparsedModules[module_] = true;

    auto errorSink = new ErrorSinkNull;
    const rawSource = cast(const(char)[]) module_.src;
    const source = rawSource[$ - 1] == '\0'
        ? rawSource
        : rawSource ~ '\0';
    scope lexer = new Lexer(
        module_.srcfile.toChars,
        source.ptr,
        0,
        source.length - 1,
        false,
        false,
        errorSink,
        &global.compileEnv,
    );

    auto token = lexer.nextToken;
    while (token != TOK.endOfFile) {
        if (token != TOK.asm_) {
            token = lexer.nextToken;
            continue;
        }

        const location = inlineAsmSourceLocation(lexer.token.loc);
        token = lexer.nextToken;
        while (token != TOK.leftCurly && token != TOK.endOfFile)
            token = lexer.nextToken;
        if (token == TOK.endOfFile)
            break;

        InlineAsmToken[][] instructions;
        InlineAsmToken[] instruction;
        for (token = lexer.nextToken;
                token != TOK.rightCurly && token != TOK.endOfFile;
                token = lexer.nextToken) {
            if (token == TOK.semicolon) {
                if (instruction.length != 0)
                    instructions ~= instruction;
                instruction = null;
            } else
                instruction ~= inlineAsmToken(lexer.token);
        }
        if (instruction.length != 0)
            instructions ~= instruction;
        if (instructions.length != 0)
            _inlineAsmInstructionsByLocation[location] = instructions;
        if (token != TOK.endOfFile)
            token = lexer.nextToken;
    }
}

private void snapshotStatement(imported!"dmd.statement".Statement statement) {
    if (statement is null)
        return;

    if (auto asm_ = statement.isCompoundAsmStatement) {
        InlineAsmToken[][] instructions;
        foreach (child; *asm_.statements) {
            auto instruction = child is null ? null : child.isAsmStatement;
            if (instruction is null)
                continue;
            InlineAsmToken[] tokens;
            for (auto token = instruction.tokens;
                    token !is null; token = token.next)
                tokens ~= inlineAsmToken(*token);
            instructions ~= tokens;
        }
        if (instructions.length != 0) {
            _inlineAsmInstructions[asm_] = instructions;
            _inlineAsmInstructionsByLocation[inlineAsmSourceLocation(asm_)] =
                instructions;
        }
        return;
    }

    if (auto scope_ = statement.isScopeStatement) {
        snapshotStatement(scope_.statement);
        return;
    }
    if (auto compound = statement.isCompoundStatement) {
        foreach (child; *compound.statements)
            snapshotStatement(child);
        return;
    }
    if (auto if_ = statement.isIfStatement) {
        snapshotStatement(if_.ifbody);
        snapshotStatement(if_.elsebody);
        return;
    }
    if (auto for_ = statement.isForStatement) {
        snapshotStatement(for_._init);
        snapshotStatement(for_._body);
        return;
    }
    if (auto do_ = statement.isDoStatement) {
        snapshotStatement(do_._body);
        return;
    }
    if (auto while_ = statement.isWhileStatement) {
        snapshotStatement(while_._body);
        return;
    }
    if (auto tryFinally = statement.isTryFinallyStatement) {
        snapshotStatement(tryFinally._body);
        snapshotStatement(tryFinally.finalbody);
        return;
    }
    if (auto tryCatch = statement.isTryCatchStatement) {
        snapshotStatement(tryCatch._body);
        foreach (catch_; *tryCatch.catches)
            snapshotStatement(catch_.handler);
        return;
    }
    if (auto with_ = statement.isWithStatement) {
        snapshotStatement(with_._body);
        return;
    }
    if (auto label = statement.isLabelStatement) {
        snapshotStatement(label.statement);
        return;
    }
    if (auto switch_ = statement.isSwitchStatement) {
        snapshotStatement(switch_._body);
        return;
    }
    if (auto case_ = statement.isCaseStatement) {
        snapshotStatement(case_.statement);
        return;
    }
    if (auto default_ = statement.isDefaultStatement)
        snapshotStatement(default_.statement);
}

private InlineAsmToken inlineAsmToken(
    ref imported!"dmd.tokens".Token token,
) {
    import dmd.tokens: Token;

    return InlineAsmToken(
        Token.toString(token.value).idup,
        token.toString.idup,
    );
}

private InlineAsmSourceLocation inlineAsmSourceLocation(
    imported!"dmd.statement".CompoundAsmStatement statement,
) {
    return inlineAsmSourceLocation(statement.loc);
}

private InlineAsmSourceLocation inlineAsmSourceLocation(
    imported!"dmd.location".Loc location,
) {
    import dmd.location: SourceLoc;

    const source = SourceLoc(location);
    return InlineAsmSourceLocation(
        source.filename.idup,
        source.line,
        source.column,
        source.fileOffset,
    );
}

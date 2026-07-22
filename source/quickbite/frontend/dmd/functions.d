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

// The inline-asm shim preserves semantic `AsmStatement` tokens by source
// location, so snapshot them from the post-semantic AST. This includes AST
// bodies materialized by mixins, without reparsing source text.
public struct InlineAsmToken {
    public string kind;
    public string spelling;
}

private InlineAsmToken[][][
    imported!"dmd.statement".CompoundAsmStatement
] _inlineAsmInstructions;

public void snapshotInlineAsmInstructions() {
    import dmd.dmodule: Module;

    bool[imported!"dmd.dsymbol".Dsymbol] visited;
    foreach (index; 0 .. Module.amodules.length) {
        auto module_ = Module.amodules[index];
        snapshotSymbols(module_.members, visited);
    }
}

public const(InlineAsmToken[][]) inlineAsmInstructions(
    imported!"dmd.statement".CompoundAsmStatement statement,
) {
    const saved = statement in _inlineAsmInstructions;
    return saved is null ? null : *saved;
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

private void snapshotStatement(imported!"dmd.statement".Statement statement) {
    if (statement is null)
        return;

    if (auto asm_ = statement.isCompoundAsmStatement) {
        import dmd.iasm: inlineAsmTokens;

        InlineAsmToken[][] instructions;
        foreach (child; *asm_.statements) {
            auto tokens = child is null ? null : inlineAsmTokens(child.loc);
            if (tokens is null)
                continue;
            InlineAsmToken[] instruction;
            for (auto token = tokens;
                    token !is null; token = token.next)
                instruction ~= inlineAsmToken(*token);
            instructions ~= instruction;
        }
        if (instructions.length != 0)
            _inlineAsmInstructions[asm_] = instructions;
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

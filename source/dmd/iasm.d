module dmd.iasm;

private:

import dmd.dmodule: Module;
import dmd.dscope: Scope;
import dmd.dsymbol: CAsmDeclaration;
import dmd.expression: Expression;
import dmd.location: Loc, SourceLoc;
import dmd.statement: AsmStatement, ExpStatement, Statement;
import dmd.tokens: Token;

// Shim for dmd:frontend 2.112.x, whose library references backend inline-asm
// semantic functions while excluding the real backend module. The real inline
// assembler is not vendored, so this shim cannot turn the asm tokens into
// machine code: native codegen would emit an empty body and silently produce
// garbage (libdparse's SSE4.2 lexer is one such case). Record the enclosing
// module instead so the native backend can refuse it with a clear error rather
// than miscompile it. Keep each semantic `AsmStatement` in a side table while
// replacing it with an AST no-op: the bytecode frontend snapshots those tokens
// from the post-semantic `CompoundAsmStatement`, including mixin bodies.
public Statement asmSemantic(AsmStatement statement, Scope* scope_) {
    if (statement.tokens && scope_.func !is null) {
        scope_.func.hasInlineAsm = true;
        if (auto module_ = scope_.func.getModule)
            _inlineAsmModules[module_] = true;
        _inlineAsmStatements[inlineAsmSourceLocation(statement.loc)] =
            statement;
    }

    return new ExpStatement(statement.loc, cast(Expression) null);
}

public void asmSemantic(CAsmDeclaration declaration, Scope* scope_) {
}

// Whether a module holds any inline-asm statement, observed during its
// semantic3. The native codegen backend cannot emit inline asm (see above) and
// uses this to reject such a module before codegen.
// @trusted: reads process-global state, but the frontend is single-threaded
// (versions "unitUnthreaded"), so no other thread can mutate the map.
public bool moduleHasInlineAsm(Module module_) @trusted nothrow {
    return (module_ in _inlineAsmModules) !is null;
}

private __gshared bool[Module] _inlineAsmModules;

// The side table keeps the original statement (and therefore its linked token
// list) alive after semantic3 replaces the AST child with an empty statement.
// @trusted: reads process-global frontend state while unitUnthreaded keeps all
// frontend work on one thread.
public Token* inlineAsmTokens(Loc location) @trusted {
    auto saved = inlineAsmSourceLocation(location) in _inlineAsmStatements;
    return saved is null ? null : (*saved).tokens;
}

private __gshared AsmStatement[InlineAsmSourceLocation] _inlineAsmStatements;

private struct InlineAsmSourceLocation {
    string filename;
    uint line;
    uint column;
    uint fileOffset;
}

private InlineAsmSourceLocation inlineAsmSourceLocation(Loc location) {
    const source = SourceLoc(location);
    return InlineAsmSourceLocation(
        source.filename.idup,
        source.line,
        source.column,
        source.fileOffset,
    );
}

// dmd:lexer 2.112.x references Edition.init without emitting it.
pragma(mangle, "_D3dmd8astenums7Edition6__initZ")
public __gshared ushort editionInit = 2023;

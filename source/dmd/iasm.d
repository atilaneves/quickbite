module dmd.iasm;

private:

import dmd.dscope: Scope;
import dmd.dsymbol: CAsmDeclaration;
import dmd.statement: AsmStatement, Statement;

// Shim for dmd:frontend 2.112.x, whose library references backend inline-asm
// semantic functions while excluding the real backend module.
public Statement asmSemantic(AsmStatement statement, Scope* scope_) {
    if (statement.tokens && scope_.func !is null)
        scope_.func.hasInlineAsm = true;

    return null;
}

public void asmSemantic(CAsmDeclaration declaration, Scope* scope_) {
}

// dmd:lexer 2.112.x references Edition.init without emitting it.
pragma(mangle, "_D3dmd8astenums7Edition6__initZ")
public __gshared ushort editionInit = 2023;

// Stub for dmd.iasm required by dmd:frontend 2.112.x.
// The real iasm package is excluded from the dmd:frontend dub sub-package;
// this stub satisfies the linker references from dsymbolsem.d and
// statementsem.d with no-op bodies (same as version(NoBackend) behaviour).
//
// Also provides _D3dmd8astenums7Edition6__initZ (Edition.init = 2023) which
// is referenced by the lexer TypeInfo but not emitted by the library build —
// a bug in dmd:lexer 2.112.x where Edition changed from ubyte to ushort.
module dmd.iasm;

import dmd.dscope : Scope;
import dmd.dsymbol : CAsmDeclaration;
import dmd.statement : AsmStatement, Statement;

// Provide the missing Edition.init data symbol for dmd:lexer 2.112.x.
// Edition : ushort { v2023 = 2023, ... }; Edition.init = v2023 = 2023.
pragma(mangle, "_D3dmd8astenums7Edition6__initZ")
public __gshared ushort _editionInit = 2023;

// No-op stub: the quickbite frontend does not process inline asm.
public Statement asmSemantic(AsmStatement s, Scope* sc) {
    return null;
}

// No-op stub: the quickbite frontend does not process C inline asm.
public void asmSemantic(CAsmDeclaration ad, Scope* sc) {
}

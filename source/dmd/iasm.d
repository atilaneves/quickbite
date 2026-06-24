module dmd.iasm;

private:

import dmd.dmodule: Module;
import dmd.dscope: Scope;
import dmd.dsymbol: CAsmDeclaration;
import dmd.statement: AsmStatement, Statement;

// Shim for dmd:frontend 2.112.x, whose library references backend inline-asm
// semantic functions while excluding the real backend module. The real inline
// assembler is not vendored, so this shim cannot turn the asm tokens into
// machine code: native codegen would emit an empty body and silently produce
// garbage (libdparse's SSE4.2 lexer is one such case). Record the enclosing
// module instead so the native backend can refuse it with a clear error rather
// than miscompile it. Recording here catches asm at any nesting depth, since
// asmSemantic sees every asm statement during semantic3.
public Statement asmSemantic(AsmStatement statement, Scope* scope_) {
    if (statement.tokens && scope_.func !is null) {
        scope_.func.hasInlineAsm = true;
        if (auto module_ = scope_.func.getModule)
            _inlineAsmModules[module_] = true;
    }

    return null;
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

// dmd:lexer 2.112.x references Edition.init without emitting it.
pragma(mangle, "_D3dmd8astenums7Edition6__initZ")
public __gshared ushort editionInit = 2023;

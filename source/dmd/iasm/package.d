module dmd.iasm;


private:


import dmd.dscope: Scope;
import dmd.dsymbol: CAsmDeclaration;
import dmd.expression: AssertExp, Expression, IntegerExp, StringExp;
import dmd.func: FuncDeclaration;
import dmd.mtype: Type;
import dmd.statement:
    AsmStatement, ErrorStatement, ExpStatement, InlineAsmStatement, Statement;
import dmd.statementsem: statementSemantic;
import dmd.target: target;
import dmd.tokens: TOK;

version (MARS) {
    import dmd.iasm.dmdaarch64: inlineAsmAArch64Semantic;
    import dmd.iasm.dmdx86: inlineAsmSemantic;
}

public Statement asmSemantic(AsmStatement statement, Scope* scope_) {
    FuncDeclaration function_ = scope_.parent.isFuncDeclaration;
    assert(function_ !is null);

    if (statement.tokens is null)
        return null;

    scope_.func.hasInlineAsm = true;

    version (MARS) {
        if (statement.tokens.value == TOK.string_) {
            // `const` would qualify the class reference passed to ExpStatement.
            auto expression = new AssertExp(
                statement.loc,
                new IntegerExp(statement.loc, 0, Type.tint32),
                new StringExp(
                    statement.loc,
                    "Gnu Asm not supported - compile this function with gcc or clang",
                ),
            );
            return statementSemantic(
                new ExpStatement(statement.loc, expression),
                scope_,
            );
        }

        auto inline_ = new InlineAsmStatement(statement.loc, statement.tokens);
        inline_.caseSensitive = statement.caseSensitive;
        return target.isAArch64
            ? inlineAsmAArch64Semantic(inline_, scope_)
            : inlineAsmSemantic(inline_, scope_);
    } else version (NoBackend) {
        return null;
    } else {
        statement.error("D inline assembler statements are not supported");
        return new ErrorStatement;
    }
}

public void asmSemantic(CAsmDeclaration declaration, Scope* scope_) {
    version (MARS) {
        import dmd.errors: error;

        error(
            declaration.code.loc,
            "Gnu Asm not supported - compile this file with gcc or clang",
        );
    }
}

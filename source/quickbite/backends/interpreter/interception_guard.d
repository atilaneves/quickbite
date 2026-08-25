// Native leaves have no interpretable D source, or contain inline assembly
// that the frontend-only session cannot resolve. This predicate classifies
// those leaves without authorizing a name-based handler.
module quickbite.backends.interpreter.interception_guard;

private:

public void enforceInterceptionPolicy(
    imported!"dmd.func".FuncDeclaration function_,
    in string interceptorName,
) {
    import std.conv: text;

    assert(
        isLegalInterception(function_),
        text(
            "Native-leaf classification violation: `",
            interceptorName,
            "` selected `",
            function_ is null ? "<null>" : text(function_.toPrettyChars),
            "`, which has interpretable D source. Execute that source instead.",
        ),
    );
}

public bool isLegalInterception(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.frontend.dmd.functions: hasNoAvailableSource;

    return
        function_ !is null &&
        (
            hasNoAvailableSource(function_) ||
            bodyContainsAsm(function_)
        );
}

// DMD does not expose a direct body-contains-asm query. The frontend-only
// build retains the CompoundAsmStatement wrapper but not its resolved
// instruction nodes, so walk for that wrapper with DMD's statement visitor.
public bool bodyContainsAsm(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import core.lifetime: emplace;
    import dmd.statement: CompoundStatement;
    import dmd.visitor.statement_rewrite_walker: StatementRewriteWalker;

    if (function_.fbody is null)
        return false;

    extern (C++) final class AsmStatementFinder: StatementRewriteWalker {
        alias visit = typeof(super).visit;

        bool found;

        override void visit(CompoundStatement statement) {
            found = found || statement.isCompoundAsmStatement !is null;
            super.visit(statement);
        }
    }

    align(__traits(classInstanceAlignment, AsmStatementFinder))
        ubyte[__traits(classInstanceSize, AsmStatementFinder)] storage;
    scope finder = emplace!AsmStatementFinder(storage[]);
    finder.visitStmt(function_.fbody);
    return finder.found;
}

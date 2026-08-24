// Mechanical enforcement of ai/plans/interpreter.md's temporary
// interception boundary. New name-based interception is not permitted.
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
            "Interception policy violation (ai/plans/interpreter.md §8): `",
            interceptorName,
            "` intercepted `",
            function_ is null ? "<null>" : text(function_.toPrettyChars),
            "`, which is not one of the two recorded retirement blockers. ",
            "Execute the D source or real native hook instead.",
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
            isRetainedInterception(function_) ||
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

private bool isRetainedInterception(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    const prettyName = text(function_.toPrettyChars);
    return isStringForeachApplyName(prettyName) ||
        isInterpreterBuiltinName(function_);
}

private bool isStringForeachApplyName(in string prettyName) {
    import std.algorithm: canFind;

    return
        prettyName.canFind("_aApplycd1") ||
        prettyName.canFind("_aApplywd1") ||
        prettyName.canFind("_aApplydc1") ||
        prettyName.canFind("_aApplyRwd1");
}

private bool isInterpreterBuiltinName(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.interpreter.builtins:
        InterpreterBuiltin, tryInterpreterBuiltin;

    InterpreterBuiltin builtin;
    return tryInterpreterBuiltin(function_, builtin);
}

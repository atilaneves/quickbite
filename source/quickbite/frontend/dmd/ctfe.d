module quickbite.frontend.dmd.ctfe;

private:


public string ctfeDiagnostic(
    imported!"dmd.func".FuncDeclaration function_,
) {
    string diagnostic;
    interpretCtfeWithDiagnostic(callExpression(function_), diagnostic);
    return diagnostic;
}

private imported!"dmd.expression".Expression interpretCtfeWithDiagnostic(
    imported!"dmd.expression".Expression expression,
    out string diagnostic,
) {
    import quickbite.frontend.compiler: resetErrors, withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;
    import dmd.globals: global;

    imported!"dmd.expression".Expression result;
    withCompilerLock(() {
        resetErrors;
        diagnostics.length = 0;
        result = ctfeInterpret(expression);
        if (result.isErrorExp !is null || global.errors != 0)
            diagnostic = diagnosticMessage;
    });

    return result;
}

private string diagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;
    import std.algorithm.iteration: filter, map;
    import std.array: array, join;

    const messages = diagnostics
        .filter!(diagnostic => diagnostic.kind == ErrorKind.error)
        .map!(diagnostic => diagnostic.message)
        .array;

    if (messages.length == 0)
        return "DMD reported an error without a diagnostic message.";

    return messages.join("\n");
}

private imported!"dmd.expression".CallExp callExpression(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.arraytypes: Expressions;
    import dmd.expression: CallExp, VarExp;
    import dmd.location: Loc;
    import dmd.mtype: TypeFunction;

    auto varExp = new VarExp(Loc.initial, function_);
    varExp.type = function_.type;
    auto callExp = new CallExp(Loc.initial, varExp, new Expressions);
    auto tf = cast(TypeFunction) function_.type;
    callExp.type = tf.next;
    callExp.f = function_;

    return callExp;
}

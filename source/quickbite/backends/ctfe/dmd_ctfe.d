module quickbite.backends.ctfe.dmd_ctfe;


private:


public class Ctfe: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: displayEvalResult, Evaluator, EvalResult,
        ReplSession;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    public alias eval = Evaluator.eval;

    public override bool supportsReplPreludeFormatter() const
    @safe @nogc nothrow pure {
        return true;
    }

    public override EvalResult eval(FuncDeclaration function_) {
        string diagnostic;
        auto interpreted = interpretCtfeWithDiagnostic(
            callExpression(function_),
            diagnostic,
        );
        return diagnostic.length == 0
            ? displayEvalResult(() => ctfeDisplay(interpreted, function_), function_)
            : EvalResult(EvalResult.Diagnostic(diagnostic));
    }

    protected override EvalResult executeUnitTest(
        UnitTestDeclaration unitTest,
    ) {
        string diagnostic;
        interpretCtfeWithDiagnostic(callExpression(unitTest), diagnostic);
        return diagnostic.length == 0
            ? EvalResult("")
            : EvalResult(EvalResult.Diagnostic(diagnostic));
    }

    public override ReplSession createReplSession() {
        return new CtfeReplSession(this);
    }

    public override EvalResult evalFormattedDisplay(FuncDeclaration function_) {
        string diagnostic;
        auto interpreted = interpretCtfeWithDiagnostic(
            callExpression(function_),
            diagnostic,
        );
        if (diagnostic.length != 0)
            return EvalResult(EvalResult.Diagnostic(diagnostic));

        try
            return EvalResult(ctfeStringDisplay(interpreted));
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
    }
}

private imported!"dmd.expression".StringExp ctfeString(
    imported!"dmd.expression".Expression expression,
) {
    if (auto string_ = expression.isStringExp)
        return string_;

    if (auto construct = expression.isConstructExp)
        return ctfeString(construct.e2);

    return null;
}

private string ctfeStringDisplay(imported!"dmd.expression".Expression expression) {
    if (auto string_ = ctfeString(expression)) {
        import quickbite.frontend.dmd.string_literals: stringChars;

        return stringChars(string_).idup;
    }

    if (auto array = expression.isArrayLiteralExp)
        return ctfeCharArrayDisplay(array);

    throw new Exception("Prelude formatter returned a non-string value.");
}

private string ctfeCharArrayDisplay(
    imported!"dmd.expression".ArrayLiteralExp array,
) {
    char[] chars;
    foreach (index; 0 .. array.elements.length)
        chars ~= ctfeChar(array[index]);

    return chars.idup;
}

private char ctfeChar(imported!"dmd.expression".Expression expression) {
    if (auto construct = expression.isConstructExp)
        return ctfeChar(construct.e2);

    if (auto integer = expression.isIntegerExp)
        return cast(char) integer.getInteger;

    throw new Exception("Prelude formatter returned a non-character string element.");
}

private string ctfeDisplay(
    imported!"dmd.expression".Expression expression,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.frontend.dmd.types: isCharacterArrayType;

    auto returnType = function_.type is null ? null : function_.type.nextOf;
    return isCharacterArrayType(returnType)
        ? ctfeStringDisplay(expression)
        : expressionChars(expression);
}

private class CtfeReplSession: imported!"quickbite.backends.evaluator".ReplSession {
    private Ctfe _ctfe;

    public this(Ctfe ctfe) {
        _ctfe = ctfe;
    }

    public override imported!"quickbite.backends.evaluator".EvalResult submit(
        imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        if (cell.evalCell.displayIsFormatted)
            return _ctfe.evalFormattedDisplay(cell.evalCell.function_);

        return _ctfe.eval(cell.evalCell);
    }
}

private imported!"dmd.expression".Expression interpretCtfeWithDiagnostic(
    imported!"dmd.expression".Expression expression,
    out string diagnostic,
) {
    import quickbite.frontend.compiler: resetErrors, withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.globals: global;

    imported!"dmd.expression".Expression result;
    withCompilerLock(() {
        resetErrors;
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

private string expressionChars(imported!"dmd.expression".Expression expression) @trusted {
    import std.string: fromStringz;

    return expression.toChars.fromStringz.idup;
}

private __gshared uint _diagnosticModuleCounter;

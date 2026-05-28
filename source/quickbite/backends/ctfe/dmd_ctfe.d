module quickbite.backends.ctfe.dmd_ctfe;


private:


public class Ctfe: imported!"quickbite.backend".Backend {
    import quickbite.lang: Value;

    public override Value eval(in string str) {
        return ctfeValue(interpretCtfe(evalCall(str)));
    }

    public override Value evalRepl(
        in imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        import quickbite.frontend.repl: ReplCellKind;

        final switch (cell.kind) with (ReplCellKind) {
            case incomplete:
                throw new Exception("Incomplete REPL cell reached CTFE backend.");
            case noDisplay:
                if (const failure = ctfeFailureMessage(
                    callExpression(replFunction(cell.source)),
                ))
                    throw new Exception(failure);
                return Value.void_;
            case expression:
                return evalReplSource(cell.source);
        }
    }

    public override void runParsedTests(
        imported!"dmd.dmodule".Module module_,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            if (const failure = ctfeFailureMessage(callExpression(unitTest)))
                throw new Exception(failure);
        });
    }

    public bool canHandle(
        imported!"dmd.dmodule".Module module_,
    ) {
        import dmd.expression: AssignExp, VarExp;
        import dmd.visitor: SemanticTimeTransitiveVisitor;

        extern (C++) final class SupportVisitor : SemanticTimeTransitiveVisitor {
            alias visit = typeof(super).visit;

            private bool _reads = true;
            bool supported = true;

            override void visit(AssignExp expression) {
                const wasReading = _reads;

                _reads = false;
                if (expression.e1 !is null)
                    expression.e1.accept(this);

                _reads = true;
                if (expression.e2 !is null)
                    expression.e2.accept(this);

                _reads = wasReading;
            }

            override void visit(VarExp expression) {
                if (!_reads)
                    return;

                auto variable = expression.var.isVarDeclaration;
                if (variable is null)
                    return;

                if (variable.isDataseg && !variable.isCTFE &&
                    !variable.isConst && !variable.isImmutable)
                    supported = false;
            }
        }

        scope visitor = new SupportVisitor;
        module_.accept(visitor);
        return visitor.supported;
    }
}

private string ctfeFailureMessage(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;

    string result;
    withCompilerLock(() {
        diagnostics.length = 0;
        if (ctfeInterpret(expression).isErrorExp !is null)
            result = diagnosticMessage;
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

private imported!"dmd.expression".CallExp evalCall(in string str) {
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(evalSource(str));
    return callExpression(functionDeclaration(parsed.module_, "f"));
}

private imported!"quickbite.lang".Value evalReplSource(in string source) {
    try
        return ctfeValue(interpretCtfe(callExpression(replFunction(source))));
    catch (Exception exception)
        throw new Exception(withCandidateSignatures(source, exception.msg));
}

private string evalSource(in string str) {
    import std.string: lastIndexOf;

    const lastNl = str.lastIndexOf('\n');
    const prior  = lastNl < 0 ? "" : str[0 .. lastNl + 1];
    const last   = lastNl < 0 ? str : str[lastNl + 1 .. $];
    return "auto f() { " ~ prior ~ "return " ~ last ~ "; }";
}

private imported!"dmd.func".FuncDeclaration replFunction(in string source) {
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(source);
    return functionDeclaration(parsed.module_, "f");
}

private imported!"dmd.func".FuncDeclaration functionDeclaration(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ !is null && function_.ident.toString == name)
                return function_;
        }
    }

    throw new Exception("Missing CTFE function.");
}

private string withCandidateSignatures(
    in string source,
    in string diagnostic,
) {
    import std.array: join;
    import std.conv: text;

    const signatures = candidateSignatures(source);
    if (signatures.length == 0)
        return diagnostic;

    if (signatures.length == 1)
        return text(diagnostic, "\nCandidate: ", signatures[0]);

    return text(diagnostic, "\nCandidates:\n- ", signatures.join("\n- "));
}

private string[] candidateSignatures(in string source) {
    import core.atomic: atomicFetchAdd;
    import dmd.errors: diagnostics;
    import dmd.frontend: dmdParseModule = parseModule;
    import dmd.globals: global;
    import quickbite.frontend.compiler: withCompilerLock;
    import std.conv: text;

    string[] result;
    withCompilerLock(() {
        global.errors = 0;
        global.warnings = 0;
        diagnostics.length = 0;

        auto parsed = dmdParseModule(
            text(
                "repl_diagnostic_",
                atomicFetchAdd(_diagnosticModuleCounter, 1u),
                ".d",
            ),
            source,
        );
        if (parsed.diagnostics.hasErrors)
            return;

        auto call = replReturnCall(parsed.module_);
        if (call is null)
            return;

        auto callee = call.e1.isIdentifierExp;
        if (callee is null)
            return;

        auto candidates = candidateFunctions(parsed.module_, callee.ident);
        if (candidates.length == 0)
            return;

        completeSemanticForDiagnostics(parsed.module_);
        if (!callArgumentsHaveTypes(call) || hasMatchingCandidate(call, candidates))
            return;

        result = candidateSignatures(candidates);
    });

    return result;
}

private imported!"dmd.func".FuncDeclaration[] candidateFunctions(
    imported!"dmd.dmodule".Module module_,
    imported!"dmd.identifier".Identifier identifier,
) {
    imported!"dmd.func".FuncDeclaration[] result;
    if (module_.members is null)
        return result;

    foreach (member; *module_.members) {
        auto function_ = member.isFuncDeclaration;
        if (function_ !is null && function_.ident is identifier)
            appendOverloads(result, function_);
    }

    return result;
}

private void appendOverloads(
    ref imported!"dmd.func".FuncDeclaration[] functions,
    imported!"dmd.func".FuncDeclaration function_,
) {
    auto current = function_;
    while (current !is null) {
        functions ~= current;
        auto next = current.overnext;
        current = next is null ? null : next.isFuncDeclaration;
    }
}

private void completeSemanticForDiagnostics(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.errors: diagnostics;
    import dmd.frontend: fullSemantic;
    import dmd.globals: global;

    global.errors = 0;
    global.warnings = 0;
    diagnostics.length = 0;

    const oldGagged = global.startGagging;
    module_.fullSemantic;
    global.endGagging(oldGagged);

    global.errors = 0;
    global.warnings = 0;
    diagnostics.length = 0;
}

private bool callArgumentsHaveTypes(
    imported!"dmd.expression".CallExp call,
) {
    if (call.arguments is null)
        return true;

    foreach (argument; *call.arguments) {
        if (argument is null || argument.type is null)
            return false;
    }

    return true;
}

private bool hasMatchingCandidate(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.func".FuncDeclaration[] candidates,
) {
    import dmd.astenums: MATCH;
    import dmd.typesem: callMatch;

    foreach (candidate; candidates) {
        auto type = candidate.type is null ? null : candidate.type.isTypeFunction;
        if (type is null)
            continue;

        if (callMatch(
            candidate,
            type,
            null,
            call.argumentList,
            0,
            null,
            candidate._scope,
        ) > MATCH.nomatch)
            return true;
    }

    return false;
}

private string[] candidateSignatures(
    imported!"dmd.func".FuncDeclaration[] candidates,
) {
    string[] result;
    foreach (candidate; candidates)
        result ~= fullSignature(candidate);

    return result;
}

private imported!"dmd.expression".CallExp replReturnCall(
    imported!"dmd.dmodule".Module module_,
) {
    auto function_ = findFunctionDeclaration(module_, "f");
    if (function_ is null || function_.fbody is null)
        return null;

    if (auto return_ = function_.fbody.isReturnStatement)
        return return_.exp is null ? null : return_.exp.isCallExp;

    auto compound = function_.fbody.isCompoundStatement;
    if (compound is null || compound.statements is null)
        return null;

    for (size_t index = compound.statements.length; index > 0; --index) {
        auto statement = (*compound.statements)[index - 1];
        if (statement is null)
            continue;

        if (auto return_ = statement.isReturnStatement)
            return return_.exp is null ? null : return_.exp.isCallExp;
    }

    return null;
}

private imported!"dmd.func".FuncDeclaration findFunctionDeclaration(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ !is null && function_.ident.toString == name)
                return function_;
        }
    }

    return null;
}

private string fullSignature(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    import std.string: fromStringz;

    return fromStringz(function_.toFullSignature).idup;
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

private imported!"dmd.expression".Expression interpretCtfe(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;

    imported!"dmd.expression".Expression result;
    withCompilerLock(() {
        result = ctfeInterpret(expression);
    });
    return result;
}

private imported!"quickbite.lang".Value ctfeValue(
    imported!"dmd.expression".Expression expression,
) {
    if (auto integer = expression.isIntegerExp)
        return integerValue(integer);

    if (auto real_ = expression.isRealExp)
        return realValue(real_);

    if (auto string_ = expression.isStringExp)
        return stringValue(string_);

    if (auto array = expression.isArrayLiteralExp)
        return arrayValue(array);

    throw new Exception("Unsupported CTFE eval result.");
}

private imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const value = integer.getInteger;
    const type = integer.type is null ? null : integer.type.toBasetype;
    if (type is null)
        return Value(cast(long) value);

    switch (type.ty) with (TY) {
        case Tbool:
            return Value(value != 0);
        case Tint8:
            return Value(cast(byte) value);
        case Tuns8:
            return Value(cast(ubyte) value);
        case Tint16:
            return Value(cast(short) value);
        case Tuns16:
            return Value(cast(ushort) value);
        case Tint32:
            return Value(cast(int) value);
        case Tuns32:
            return Value(cast(uint) value);
        case Tint64:
            return Value(cast(long) value);
        case Tuns64:
            return Value(cast(ulong) value);
        case Tchar:
            return Value(cast(char) value);
        case Twchar:
            return Value(cast(wchar) value);
        case Tdchar:
            return Value(cast(dchar) value);
        default:
            return Value(cast(long) value);
    }
}

private imported!"quickbite.lang".Value realValue(
    imported!"dmd.expression".RealExp real_,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const type = real_.type is null ? null : real_.type.toBasetype;
    if (type !is null && type.ty == TY.Tfloat32)
        return Value(cast(float) real_.toReal);

    if (type !is null && type.ty == TY.Tfloat64)
        return Value(cast(double) real_.toReal);

    return Value(cast(real) real_.toReal);
}

private imported!"quickbite.lang".Value stringValue(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.lang: Value;

    char[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits)
        values ~= cast(char) string_.getIndex(index);

    return Value(values);
}

private imported!"quickbite.lang".Value arrayValue(
    imported!"dmd.expression".ArrayLiteralExp array,
) {
    import quickbite.lang: Value;

    long[] values;
    foreach (index; 0 .. array.elements.length)
        values ~= cast(long) array[index].isIntegerExp.getInteger;

    return Value(values);
}

private __gshared uint _diagnosticModuleCounter;

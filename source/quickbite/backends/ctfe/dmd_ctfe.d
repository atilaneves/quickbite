module quickbite.backends.ctfe.dmd_ctfe;


private:


public class Ctfe: imported!"quickbite.backends".Backend {
    import quickbite.backends:
        TestCaseResult,
        TestOutcome,
        TestRunResult,
        TestSummary;
    import quickbite.lang: Value;

    public override Value eval(in string str) {
        return ctfeValue(interpretCtfe(evalCall(str)));
    }

    public override Value evalRepl(
        imported!"quickbite.frontend.cell".EvalCell cell,
    ) {
        import quickbite.frontend.cell: EvalCellKind;

        final switch (cell.kind) with (EvalCellKind) {
            case incomplete:
                throw new Exception(
                    "Incomplete REPL cell reached CTFE backend.",
                );
            case noDisplay:
                if (const failure = ctfeFailureMessage(
                    callExpression(cell.function_),
                ))
                    throw new Exception(failure);
                return Value.void_;
            case expression:
                return evalReplSource(cell);
        }
    }

    public override void runTests(
        imported!"dmd.dmodule".Module module_,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            if (const failure = ctfeFailureMessage(callExpression(unitTest)))
                throw new Exception(failure);
        });
    }

    public override TestRunResult runTestResults(
        imported!"dmd.dmodule".Module module_,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestRunResult result;
        foreachUnitTestDeclaration(module_, (unitTest) {
            ++result.summary.total;
            if (const failure = ctfeFailureMessage(callExpression(unitTest))) {
                ++result.summary.failed;
                result.cases ~= TestCaseResult(
                    TestOutcome.failed,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    failure,
                );
            } else {
                ++result.summary.passed;
                result.cases ~= TestCaseResult(
                    TestOutcome.passed,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    null,
                );
            }
        });
        return result;
    }

    public override TestSummary runTestSummary(
        imported!"dmd.dmodule".Module module_,
    ) {
        return runTestResults(module_).summary;
    }
}

private string symbolName(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) @trusted {
    import std.string: fromStringz;

    return unitTest.ident.toChars.fromStringz.idup;
}

private string locChars(imported!"dmd.location".Loc loc) @trusted {
    import std.string: fromStringz;

    return loc.toChars.fromStringz.idup;
}

private string ctfeFailureMessage(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;
    import dmd.globals: global;

    string result;
    withCompilerLock(() {
        diagnostics.length = 0;
        if (ctfeInterpret(expression).isErrorExp !is null || global.errors != 0)
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
    import quickbite.frontend.cell: parseEvalSource;

    return callExpression(parseEvalSource(str).function_);
}

private imported!"quickbite.lang".Value evalReplSource(
    imported!"quickbite.frontend.cell".EvalCell cell,
) {
    try
        return ctfeValue(interpretCtfeOrThrow(callExpression(cell.function_)));
    catch (Exception exception) {
        import quickbite.frontend.cell: withCandidateSignatures;

        throw new Exception(
            withCandidateSignatures(cell.source, exception.msg),
        );
    }
}

private imported!"quickbite.lang".Value evalReplTypeSource(
    imported!"quickbite.frontend.cell".EvalCell cell,
) {
    import std.conv: text;
    import quickbite.lang: Value;

    auto interpreted = interpretCtfe(callExpression(cell.function_));
    auto string_ = interpreted.isStringExp;
    if (string_ is null)
        throw new Exception(text(
            "Unsupported CTFE type result: ",
            interpreted.op,
        ));

    return Value.typeName(stringChars(string_).idup);
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

private imported!"dmd.expression".Expression interpretCtfeOrThrow(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.frontend.compiler: resetErrors, withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.globals: global;

    imported!"dmd.expression".Expression result;
    withCompilerLock(() {
        resetErrors;
        result = ctfeInterpret(expression);
        if (result.isErrorExp !is null || global.errors != 0)
            throw new Exception(diagnosticMessage);
    });
    return result;
}

private imported!"quickbite.lang".Value ctfeValue(
    imported!"dmd.expression".Expression expression,
) {
    import std.conv: text;
    import quickbite.lang: Value;

    if (auto integer = expression.isIntegerExp)
        return integerValue(integer);

    if (auto real_ = expression.isRealExp)
        return realValue(real_);

    if (auto string_ = expression.isStringExp)
        return stringValue(string_);

    if (auto null_ = expression.isNullExp)
        return Value.null_();

    if (auto construct = expression.isConstructExp)
        return ctfeValue(construct.e2);

    if (auto array = expression.isArrayLiteralExp)
        return arrayValue(array);

    if (auto struct_ = expression.isStructLiteralExp)
        return structValue(struct_);

    throw new Exception(text("Unsupported CTFE eval result: ", expression.op));
}

private imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
) {
    import quickbite.frontend.dmd_values: frontendIntegerValue = integerValue;

    return frontendIntegerValue(integer);
}

private imported!"quickbite.lang".Value realValue(
    imported!"dmd.expression".RealExp real_,
) {
    import quickbite.frontend.dmd_values: frontendRealValue = realValue;

    return frontendRealValue(real_);
}

private imported!"quickbite.lang".Value stringValue(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.lang: Value;

    return Value(stringChars(string_));
}

private char[] stringChars(
    imported!"dmd.expression".StringExp string_,
) {
    char[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits)
        values ~= cast(char) string_.getIndex(index);

    return values;
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

private imported!"quickbite.lang".Value structValue(
    imported!"dmd.expression".StructLiteralExp struct_,
) {
    import quickbite.lang: Value;

    Value[] fields;
    if (struct_.elements !is null) {
        foreach (element; *struct_.elements) {
            if (element is null)
                continue;

            fields ~= ctfeValue(element);
        }
    }

    return Value.structValue(
        struct_.sd.ident.toString.idup,
        fields,
    );
}

private __gshared uint _diagnosticModuleCounter;

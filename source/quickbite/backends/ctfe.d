module quickbite.backends.ctfe;


private:


public class Ctfe: imported!"quickbite.backend".Backend {
    import quickbite.lang: Value;

    public override Value eval(in string str) {
        return ctfeValue(interpretCtfe(evalCall(str)));
    }

    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        auto parsed = parseModule(source);
        foreachUnitTestDeclaration(parsed.module_, (unitTest) {
            runCtfe(unitTest);
        });
    }
}

private void runCtfe(imported!"dmd.declaration".UnitTestDeclaration unitTest) {
    const failure = ctfeFailureMessage(unitTest);
    if (failure.length != 0)
        throw new Exception(failure);
}

private string ctfeFailureMessage(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;
    import dmd.globals: global;

    string failure;
    withCompilerLock(() {
        diagnostics.length = 0;
        global.errors = 0;
        if (ctfeInterpret(unitTestCallExpression(unitTest)).isErrorExp !is null ||
            global.errors != 0)
            failure = ctfeDiagnosticMessage;
    });

    if (failure == "Unittest assertion failed.")
        if (const message = directAssertFailureMessage(unitTest.fbody))
            return message;

    return failure;
}

private imported!"dmd.expression".CallExp unitTestCallExpression(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import dmd.arraytypes: Expressions;
    import dmd.expression: CallExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.location: Loc;
    import dmd.mtype: Type;

    FuncDeclaration function_ = unitTest;
    auto varExp = new VarExp(Loc.initial, function_);
    varExp.type = function_.type;
    auto callExp = new CallExp(Loc.initial, varExp, new Expressions);
    callExp.type = Type.tvoid;
    callExp.f = function_;

    return callExp;
}

private string ctfeDiagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;
    import std.string: startsWith;

    foreach (diagnostic; diagnostics) {
        if (diagnostic.kind == ErrorKind.error &&
            !diagnostic.message.startsWith("`assert"))
            return diagnostic.message;
    }

    return "Unittest assertion failed.";
}

private string directAssertFailureMessage(
    imported!"dmd.statement".Statement statement,
) {
    if (statement is null)
        return null;

    if (auto scope_ = statement.isScopeStatement)
        return directAssertFailureMessage(scope_.statement);

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null || compound.statements.length == 0)
            return null;
        return directAssertFailureMessage((*compound.statements)[$ - 1]);
    }

    auto expressionStatement = statement.isExpStatement;
    if (expressionStatement is null)
        return null;

    auto assert_ = expressionStatement.exp.isAssertExp;
    if (assert_ is null || assert_.msg !is null)
        return null;

    import dmd.tokens: EXP;

    auto equal = assert_.e1.isEqualExp;
    if (equal is null)
        return null;

    const comparison = equal.op == EXP.notEqual ? "!=" : "==";
    long left;
    long right;
    if (!ctfeIntegerValue(equal.e1, left) || !ctfeIntegerValue(equal.e2, right))
        return null;

    import quickbite.unittest_assertions:
        AssertionMessageMode,
        failedAssertionMessage;

    return failedAssertionMessage(
        AssertionMessageMode.context,
        left,
        right,
        comparison,
    );
}

private bool ctfeIntegerValue(
    imported!"dmd.expression".Expression expression,
    out long value,
) {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;
    import dmd.globals: global;

    bool found;
    withCompilerLock(() {
        diagnostics.length = 0;
        global.errors = 0;
        auto result = ctfeInterpret(expression);
        if (auto integer = result.isIntegerExp) {
            value = cast(long) integer.getInteger;
            found = true;
        }
    });

    return found;
}

private imported!"dmd.expression".CallExp evalCall(in string str) {
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(evalSource(str));
    return callExpression(functionDeclaration(parsed.module_, "f"));
}

private string evalSource(in string str) {
    import std.string: lastIndexOf;

    const lastNl = str.lastIndexOf('\n');
    const prior  = lastNl < 0 ? "" : str[0 .. lastNl + 1];
    const last   = lastNl < 0 ? str : str[lastNl + 1 .. $];
    return "auto f() { " ~ prior ~ "return " ~ last ~ "; }";
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
    import dmd.errors: diagnostics;

    imported!"dmd.expression".Expression result;
    withCompilerLock(() {
        diagnostics.length = 0;
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

module quickbite.backends.ctfe;


private:


public class Ctfe: imported!"quickbite.backend".Backend {
    import quickbite.lang: Value;

    public override Value eval(in string str) {
        return ctfeValue(interpretCtfe(evalCall(str)));
    }

    public override void runTests(in string moduleSource) {
        import quickbite.frontend.compiler: parseModuleWithCheckActionContext;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        auto parsed = parseModuleWithCheckActionContext(moduleSource);
        foreachUnitTestDeclaration(parsed.module_, (unitTest) {
            if (const failure = ctfeFailureMessage(unitTest))
                throw new Exception(failure);
        });
    }
}

private string ctfeFailureMessage(
    imported!"dmd.func".UnitTestDeclaration unitTest,
) {
    const failure = ctfeFailureMessage(callExpression(unitTest));
    if (!hasUnsupportedFloatingPointDiagnostic(failure))
        return failure;

    if (const message = floatingPointPlaceholderFailureMessage(
        failure,
        unitTest.fbody,
    ))
        return message;

    return failure;
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

private bool hasUnsupportedFloatingPointDiagnostic(in string diagnostic)
@safe pure nothrow {
    import std.algorithm.searching: canFind;

    return diagnostic.canFind("<float not supported>") ||
        diagnostic.canFind("<double not supported>") ||
        diagnostic.canFind("<real not supported>");
}

private string floatingPointPlaceholderFailureMessage(
    in string failure,
    imported!"dmd.statement".Statement statement,
) {
    const operator = unsupportedFloatingPointComparison(failure);
    if (operator is null)
        return null;

    const values = floatingPointLocalValues(statement);
    if (values.length != 2)
        return null;

    import std.conv: text;
    return text(values[0], " ", operator, " ", values[1]);
}

private string unsupportedFloatingPointComparison(in string failure)
@safe pure nothrow {
    import std.algorithm.searching: endsWith, startsWith;

    enum placeholders = [
        "<float not supported>",
        "<double not supported>",
        "<real not supported>",
    ];

    foreach (left; placeholders)
    foreach (right; placeholders) {
        const prefix = left ~ " ";
        const suffix = " " ~ right;
        if (!failure.startsWith(prefix) || !failure.endsWith(suffix))
            continue;

        const operator = failure[prefix.length .. $ - suffix.length];
        if (isComparisonOperator(operator))
            return operator;
    }

    return null;
}

private bool isComparisonOperator(in string operator) @safe pure nothrow {
    switch (operator) {
        case "==":
        case "!=":
        case "<":
        case "<=":
        case ">":
        case ">=":
            return true;
        default:
            return false;
    }
}

private real[] floatingPointLocalValues(
    imported!"dmd.statement".Statement statement,
) {
    if (statement is null)
        return [];

    if (auto scope_ = statement.isScopeStatement)
        return floatingPointLocalValues(scope_.statement);

    if (auto compoundDeclaration = statement.isCompoundDeclarationStatement) {
        if (compoundDeclaration.statements is null)
            return [];

        real[] values;
        foreach (child; *compoundDeclaration.statements)
            values ~= floatingPointLocalValues(child);
        return values;
    }

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null)
            return [];

        real[] values;
        foreach (child; *compound.statements)
            values ~= floatingPointLocalValues(child);
        return values;
    }

    auto expressionStatement = statement.isExpStatement;
    if (expressionStatement is null)
        expressionStatement = statement.isDtorExpStatement;
    if (expressionStatement is null)
        return [];

    auto declaration = expressionStatement.exp.isDeclarationExp;
    if (declaration is null)
        return [];

    auto variable = declaration.declaration.isVarDeclaration;
    if (variable is null || variable.ident is null ||
        variable.type is null || !isFloatingPointType(variable.type))
        return [];

    auto initializer = variable._init.isExpInitializer;
    if (initializer is null)
        return [];

    if (auto real_ = unwrappedInitializerExpression(initializer.exp).isRealExp)
        return [real_.toReal];

    return [];
}

private imported!"dmd.expression".Expression unwrappedInitializerExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (auto construct = expression.isConstructExp)
        return construct.e2;

    return expression;
}

private bool isFloatingPointType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    with (TY) switch (type.toBasetype.ty) {
        case Tfloat32:
        case Tfloat64:
        case Tfloat80:
            return true;
        default:
            return false;
    }
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

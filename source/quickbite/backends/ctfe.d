module quickbite.backends.ctfe;


private:


public class Ctfe: imported!"quickbite.backend".Backend {
    import quickbite.lang: Value;

    public override Value eval(in string str) {
        return ctfeValue(interpretCtfe(evalCall(str)));
    }

    public override void runTests(in string moduleSource) {
        import quickbite.frontend.compiler: parseModule;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        auto parsed = parseModule(moduleSource);
        foreachUnitTestDeclaration(parsed.module_, (unitTest) {
            if (interpretCtfe(callExpression(unitTest)).isErrorExp !is null)
                throw new Exception(assertFailureMessage(unitTest.fbody));
        });
    }
}

private string assertFailureMessage(
    imported!"dmd.statement".Statement statement,
) {
    if (auto compound = statement.isCompoundStatement)
        return assertFailureMessage((*compound.statements)[$ - 1]);

    auto equal = statement.isExpStatement.exp.isAssertExp.e1.isEqualExp;
    import std.conv: text;

    return text(
        ctfeAssertionValue(equal.e1),
        " != ",
        ctfeAssertionValue(equal.e2),
    );
}

private string ctfeAssertionValue(
    imported!"dmd.expression".Expression expression,
) {
    import std.array: split;

    return ctfeValue(interpretCtfe(expression)).toString.split(":")[0];
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

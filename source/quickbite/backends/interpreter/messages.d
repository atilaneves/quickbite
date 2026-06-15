module quickbite.backends.interpreter.messages;

private:

public string uninitializedVariableMessage(
    imported!"dmd.declaration".VarDeclaration variable,
    imported!"dmd.func".FuncDeclaration currentFunction,
) {
    import std.conv: text;

    const functionName =
        currentFunction is null ? "<unknown>" : currentFunction.ident.toString;

    return text(
        "cannot read uninitialized variable `.",
        functionName,
        ".",
        variable.ident.toString,
        "` in ctfe",
    );
}

public string indexOutOfBoundsMessage(
    in size_t index,
    in size_t length,
    in bool isSlice,
) @safe pure {
    import std.conv: text;

    return isSlice
        ? text("index ", index, " exceeds array length ", length)
        : text("array index ", index, " is out of bounds `[0..", length, "]`");
}

public string missingKeyMessage(
    imported!"dmd.expression".Expression key,
    imported!"dmd.expression".Expression aa,
) {
    import std.conv: text;

    return text(
        "key `",
        text(key.toChars),
        "` not found in associative array `",
        text(aa.toChars),
        "`",
    );
}

public bool isTruthy(in imported!"quickbite.lang".Value value) {
    import quickbite.lang: Value;

    if (value == Value.null_)
        return false;

    if (value.isPointer)
        return true;

    if (value == Value(false))
        return false;

    if (value == Value(true))
        return true;

    return value.castTo!bool == Value(true);
}

public T[] stringCodeUnits(T)(imported!"dmd.expression".StringExp string_) {
    T[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits)
        values ~= cast(T) string_.getIndex(index);

    return values;
}

public char[] stringChars(imported!"dmd.expression".StringExp string_) {
    import std.utf: encode;

    char[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits) {
        const codeUnit = string_.getIndex(index);
        if (string_.sz == 1) {
            values ~= cast(char) codeUnit;
        } else {
            char[4] encoded;
            const length = encode(encoded, cast(dchar) codeUnit);
            values ~= encoded[0 .. length];
        }
    }

    return values;
}

public string thrownExceptionMessage(
    imported!"dmd.expression".Expression expression,
) {
    auto new_ = expression is null ? null : expression.isNewExp;
    if (new_ is null || new_.arguments is null || new_.arguments.length == 0)
        return "Unittest assertion failed.";

    auto message = (*new_.arguments)[0].isStringExp;
    if (message is null)
        return "Unittest assertion failed.";

    return stringChars(message).idup;
}

public string receiverName(imported!"dmd.expression".Expression receiver) {
    auto var = receiver.isVarExp;
    if (var is null)
        return "null";

    return var.var.ident.toString.idup;
}

public bool isClassExpression(
    imported!"dmd.expression".Expression expression,
) {
    import dmd.astenums: TY;

    const type = expression.type is null ? null : expression.type.toBasetype;
    return type !is null && type.ty == TY.Tclass;
}

public bool isBoolValue(in imported!"quickbite.lang".Value value) {
    import quickbite.lang: Value;

    return value == Value(false) || value == Value(true);
}

public bool isBoolExpression(
    imported!"dmd.expression".Expression expression,
) {
    import dmd.astenums: TY;

    if (auto cast_ = expression.isCastExp)
        if (isBoolExpression(cast_.e1))
            return true;

    auto type = expression.type;
    if (auto cast_ = expression.isCastExp)
        type = cast_.to;

    return type !is null && type.toBasetype.ty == TY.Tbool;
}

public bool isLogicalNotExpression(
    imported!"dmd.expression".Expression expression,
) {
    while (auto cast_ = expression.isCastExp)
        expression = cast_.e1;

    if (auto comma = expression.isCommaExp)
        return isLogicalNotExpression(comma.e2);

    if (auto var = expression.isVarExp) {
        auto variable = var.var.isVarDeclaration;
        if (variable is null ||
            variable._init is null ||
            variable._init.isExpInitializer is null)
            return false;

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp)
            initializer = blit.e2;

        return isLogicalNotExpression(initializer);
    }

    return expression.isNotExp !is null;
}

public bool isLogicalExpression(
    imported!"dmd.expression".Expression expression,
) {
    while (auto cast_ = expression.isCastExp)
        expression = cast_.e1;

    if (auto comma = expression.isCommaExp)
        return isLogicalExpression(comma.e2);

    if (auto var = expression.isVarExp) {
        auto variable = var.var.isVarDeclaration;
        if (variable is null ||
            variable._init is null ||
            variable._init.isExpInitializer is null)
            return false;

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp)
            initializer = blit.e2;

        return isLogicalExpression(initializer);
    }

    return expression.isLogicalExp !is null;
}

private imported!"dmd.expression".IdentityExp identityExpression(
    imported!"dmd.expression".Expression expression,
) {
    while (auto cast_ = expression.isCastExp)
        expression = cast_.e1;

    if (auto comma = expression.isCommaExp)
        return identityExpression(comma.e2);

    if (auto identity = expression.isIdentityExp)
        return identity;

    if (auto var = expression.isVarExp) {
        auto variable = var.var.isVarDeclaration;
        if (variable is null ||
            variable._init is null ||
            variable._init.isExpInitializer is null)
            return null;

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp)
            initializer = blit.e2;

        return identityExpression(initializer);
    }

    return null;
}

public bool isVariableMessage(
    imported!"dmd.expression".Expression expression,
) {
    if (expression.isVarExp !is null)
        return true;

    if (auto cast_ = expression.isCastExp)
        return cast_.e1.isVarExp !is null;

    return false;
}

public bool isCharExpression(
    imported!"dmd.expression".Expression expression,
) {
    import dmd.astenums: TY;

    const type = expression.type is null ? null : expression.type.toBasetype;
    return type !is null && type.ty == TY.Tchar;
}

public bool isUnsignedLongExpression(
    imported!"dmd.expression".Expression expression,
) {
    import dmd.astenums: TY;

    const type = expression.type is null ? null : expression.type.toBasetype;
    return type !is null && type.ty == TY.Tuns64;
}

public string invertedEqualityOperator(in char[] operator) {
    if (operator == "==")
        return "!=";

    if (operator == "!=")
        return "==";

    if (operator == "<")
        return ">=";

    if (operator == "<=")
        return ">";

    if (operator == ">")
        return "<=";

    if (operator == ">=")
        return "<";

    return null;
}

public string equalityOperandMessage(
    in imported!"quickbite.lang".Value value,
    in bool useBoolMessage,
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.frontend.dmd.types: isIntegralExpression;
    import quickbite.lang: Value;
    import std.conv: text;

    if (useBoolMessage)
        return text(isTruthy(value));

    if (isCharExpression(expression))
        return text("'", value.asChar, "'");

    if (isUnsignedLongExpression(expression))
        return text(value.asLong);

    if (isIntegralExpression(expression))
        return text(value.asLong);

    if (value.isFloatingScalar)
        return value.dText;

    return text(value);
}

public string assertMessage(
    imported!"dmd.expression".Expression expression,
    scope imported!"quickbite.lang".Value delegate(imported!"dmd.expression".Expression) eval,
) {
    import quickbite.lang: Value;

    if (auto literal = expression.isStringExp)
        return literal.peekString.idup;

    if (expression.isVarExp !is null)
        return eval(expression).asCharArrayString;

    if (auto cast_ = expression.isCastExp)
        if (cast_.e1.isVarExp !is null)
            return eval(expression).asCharArrayString;

    assert(0);
}

public string dmdAssertFailBoolMessage(
    imported!"dmd.expression".Expression expression,
) {
    auto call = expression.isCallExp;
    if (call is null ||
        call.f is null ||
        call.f.ident.toString != "_d_assert_fail" ||
        call.arguments is null)
        return null;

    return dmdAssertFailBoolMessageFromCall(call);
}

public string dmdAssertFailBoolMessage(
    imported!"dmd.expression".CallExp call,
) {
    return dmdAssertFailBoolMessageFromCall(call);
}

private string dmdAssertFailBoolMessageFromCall(
    imported!"dmd.expression".CallExp call,
) {
    import std.conv: text;

    if (call.arguments.length != 3)
        return null;

    auto operator = (*call.arguments)[0].isStringExp;
    if (operator is null)
        return null;

    const operatorText = operator.peekString.idup;
    if (operatorText != "==" && operatorText != "!=")
        return null;

    auto left = (*call.arguments)[1].isIntegerExp;
    auto right = (*call.arguments)[2].isIntegerExp;
    if (left is null || right is null)
        return null;

    if (isCharExpression(left) || isCharExpression(right))
        return null;

    const inverseOperator = operatorText == "==" ? "!=" : "==";
    if (left.toInteger > 1 || right.toInteger > 1)
        return text(
            left.toInteger,
            " ",
            inverseOperator,
            " ",
            right.toInteger,
        );

    return text(
        left.toInteger != 0,
        " ",
        inverseOperator,
        " ",
        right.toInteger != 0,
    );
}

public string dmdAssertFailMessage(
    imported!"dmd.expression".Expression expression,
    scope imported!"quickbite.lang".Value delegate(imported!"dmd.expression".Expression) eval,
) {
    import dmd.id: Id;
    import quickbite.lang: Value;
    import std.conv: text;

    auto call = expression.isCallExp;
    if (call is null ||
        call.f is null ||
        call.f.ident != Id._d_assert_fail ||
        call.arguments is null ||
        call.arguments.length != 3)
        return null;

    auto operatorLiteral = (*call.arguments)[0].isStringExp;
    if (operatorLiteral is null)
        return null;

    const operator = invertedEqualityOperator(operatorLiteral.peekString);
    if (operator is null)
        return null;

    auto left = (*call.arguments)[1];
    auto right = (*call.arguments)[2];
    if (auto message = dmdAssertFailIdentityMessage(left, right, eval))
        return message;

    const useBoolMessage =
        isBoolExpression(left) ||
        isBoolExpression(right) ||
        isLogicalNotExpression(left) ||
        isLogicalNotExpression(right) ||
        isLogicalExpression(left) ||
        isLogicalExpression(right);
    const leftValue = eval(left);
    const rightValue = eval(right);

    return text(
        equalityOperandMessage(leftValue, useBoolMessage, left),
        " ",
        operator,
        " ",
        equalityOperandMessage(rightValue, useBoolMessage, right),
    );
}

private string dmdAssertFailIdentityMessage(
    imported!"dmd.expression".Expression left,
    imported!"dmd.expression".Expression right,
    scope imported!"quickbite.lang".Value delegate(imported!"dmd.expression".Expression) eval,
) {
    if (auto identity = identityExpression(left)) {
        if (assertExpectedTrue(right))
            return identityFailureMessage(identity, eval);
    }

    if (auto identity = identityExpression(right)) {
        if (assertExpectedTrue(left))
            return identityFailureMessage(identity, eval);
    }

    return null;
}

private bool assertExpectedTrue(imported!"dmd.expression".Expression expression) {
    if (auto integer = expression.isIntegerExp)
        return integer.toInteger == 1;

    return false;
}

private string identityFailureMessage(
    imported!"dmd.expression".IdentityExp identity,
    scope imported!"quickbite.lang".Value delegate(imported!"dmd.expression".Expression) eval,
) {
    import dmd.tokens: EXP;
    import std.conv: text;

    const operator = identity.op == EXP.notIdentity ? "is" : "!is";
    return text(
        identityOperandMessage(eval(identity.e1)),
        " ",
        operator,
        " ",
        identityOperandMessage(eval(identity.e2)),
    );
}

private string identityOperandMessage(in imported!"quickbite.lang".Value value) {
    import quickbite.lang: Value;
    import std.conv: text;

    if (value == Value.null_)
        return "`null`";

    return text(value);
}

public string equalFailureMessage(
    imported!"dmd.expression".EqualExp equal,
    scope imported!"quickbite.lang".Value delegate(imported!"dmd.expression".Expression) eval,
) {
    import dmd.tokens: EXP;
    import quickbite.lang: Value;
    import std.conv: text;

    const operator = equal.op == EXP.notEqual ? "==" : "!=";
    const left = eval(equal.e1);
    const right = eval(equal.e2);
    const useBoolMessage =
        isBoolValue(left) ||
        isBoolValue(right) ||
        isBoolExpression(equal.e1) ||
        isBoolExpression(equal.e2) ||
        isLogicalNotExpression(equal.e1) ||
        isLogicalNotExpression(equal.e2) ||
        isLogicalExpression(equal.e1) ||
        isLogicalExpression(equal.e2);
    return text(
        equalityOperandMessage(left, useBoolMessage, equal.e1),
        " ",
        operator,
        " ",
        equalityOperandMessage(right, useBoolMessage, equal.e2),
    );
}

public string assertFailureMessage(
    imported!"dmd.expression".AssertExp assert_,
    in bool runningCalledFunction,
    scope imported!"quickbite.lang".Value delegate(imported!"dmd.expression".Expression) eval,
) {
    import quickbite.lang: Value;
    import std.conv: text;

    if (assert_.msg !is null) {
        if (assert_.msg.isStringExp !is null)
            return assertMessage(assert_.msg, eval);

        if (auto message = dmdAssertFailBoolMessage(assert_.msg))
            return message;
    }

    if (assert_.msg !is null) {
        const message = dmdAssertFailMessage(assert_.msg, eval);
        if (message !is null)
            return message;

        if (isVariableMessage(assert_.msg))
            return assertMessage(assert_.msg, eval);
    }

    if (auto integer = assert_.e1.isIntegerExp)
        if (!isBoolExpression(integer))
            return "`assert(0)` failed";

    if (auto not = assert_.e1.isNotExp) {
        if (isBoolExpression(not.e1) || isLogicalExpression(not.e1))
            return text(
                equalityOperandMessage(eval(not.e1), true, not.e1),
                " == true",
            );
    }

    if (auto equal = assert_.e1.isEqualExp)
        return equalFailureMessage(equal, eval);

    if (auto identity = identityExpression(assert_.e1))
        return identityFailureMessage(identity, eval);

    if (assert_.e1.isIntegerExp is null && isBoolExpression(assert_.e1)) {
        return text(isTruthy(eval(assert_.e1)), " != true");
    }

    if (runningCalledFunction) {
        if (auto integer = assert_.e1.isIntegerExp) {
            if (integer.toInteger == 0)
                return "`assert(0)` failed";
        }
    }

    return "`assert(false)` failed";
}

public string indexOutOfBoundsMessage(
    in ulong index,
    in ulong length,
) @safe pure {
    import std.conv: text;

    return text(
        "array index ",
        index,
        " is out of bounds `[0..",
        length,
        "]`",
    );
}

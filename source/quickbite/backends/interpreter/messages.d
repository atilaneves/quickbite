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
    in bool runningCalledFunction,
) @safe pure {
    import std.conv: text;

    if (isSlice)
        return text("index ", index, " exceeds array length ", length);

    return runningCalledFunction
        ? compiledIndexOutOfBoundsMessage(index, length)
        : text("array index ", index, " is out of bounds `[0..", length, "]`");
}

// Read a boolean-typed place's truthiness. `eval`'s formatters only ever
// call this once DMD has fixed the operand's type, the same precondition
// `Walker.conditionTruthy` (impl.d) relies on for its own scalar switch.
public bool isTruthy(imported!"quickbite.backends.interpreter.place".Place value) {
    import dmd.astenums: TY;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tbool: return value.loadNativeScalar!bool;
        case Tint8: return value.loadNativeScalar!byte != 0;
        case Tuns8, Tchar: return value.loadNativeScalar!ubyte != 0;
        case Tint16: return value.loadNativeScalar!short != 0;
        case Tuns16, Twchar: return value.loadNativeScalar!ushort != 0;
        case Tint32: return value.loadNativeScalar!int != 0;
        case Tuns32, Tdchar: return value.loadNativeScalar!uint != 0;
        case Tint64: return value.loadNativeScalar!long != 0;
        case Tuns64: return value.loadNativeScalar!ulong != 0;
        case Tfloat32: return value.loadNativeScalar!float != 0;
        case Tfloat64: return value.loadNativeScalar!double != 0;
        case Tfloat80: return value.loadNativeScalar!real != 0;
        case Tpointer, Tclass, Taarray:
            return value.deref.address !is null;
        default:
            throw new Exception("Unsupported diagnostic operand type.");
    }
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

    import quickbite.frontend.dmd.string_literals: stringChars;

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

public bool isBoolValue(imported!"quickbite.backends.interpreter.place".Place value) {
    import dmd.astenums: TY;

    return value.type.toBasetype.ty == TY.Tbool;
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
    imported!"quickbite.backends.interpreter.place".Place value,
    in bool useBoolMessage,
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.frontend.dmd.types:
        isCharacterArrayType, isIntegralExpression;
    import std.conv: text;

    if (useBoolMessage)
        return text(isTruthy(value));

    if (isCharExpression(expression))
        return text("'", value.loadNativeScalar!char, "'");

    if (isUnsignedLongExpression(expression))
        return text(asLongValue(value));

    if (isIntegralExpression(expression))
        return text(asLongValue(value));

    auto basetype = expression.type.toBasetype;
    const isArray = basetype.isTypeDArray !is null || basetype.isTypeSArray !is null;

    if (isArray && isCharacterArrayType(expression.type))
        return `"` ~ charArrayString(value) ~ `"`;

    if (isArray)
        return nativeArrayText(value);

    return scalarText(value);
}

// The signed-reinterpretation `asLongValue` deliberately mirrors: every
// integral operand -- signed or unsigned, any width -- prints through the
// same `long` cast an assert diagnostic has always used here, even though
// `scalarText`'s own unsigned case (reached only once this function has
// ruled an operand out as non-integral) prints the true unsigned decimal
// value instead.
private long asLongValue(imported!"quickbite.backends.interpreter.place".Place value) {
    import dmd.astenums: TY;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tint8: return value.loadNativeScalar!byte;
        case Tuns8: return value.loadNativeScalar!ubyte;
        case Tint16: return value.loadNativeScalar!short;
        case Tuns16: return value.loadNativeScalar!ushort;
        case Tint32: return value.loadNativeScalar!int;
        case Tuns32: return value.loadNativeScalar!uint;
        case Tint64: return value.loadNativeScalar!long;
        case Tuns64: return cast(long) value.loadNativeScalar!ulong;
        default:
            throw new Exception("Expected integer-compatible scalar.");
    }
}

private string nativeArrayText(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    string result = "[";
    foreach (index; 0 .. value.arrayLength) {
        if (index)
            result ~= ", ";
        auto element = value.index(index);
        auto elementType = element.type.toBasetype;
        result ~= elementType.isTypeDArray !is null || elementType.isTypeSArray !is null
            ? nativeArrayText(element)
            : scalarText(element);
    }
    return result ~ "]";
}

private string scalarText(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    import dmd.astenums: TY;
    import std.conv: text;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tbool:
            return text(value.loadNativeScalar!bool);
        case Tchar, Twchar, Tdchar:
            return characterUtf8(value);
        case Tint8, Tint16, Tint32, Tint64:
            return text(asLongValue(value));
        case Tuns8:
            return text(value.loadNativeScalar!ubyte);
        case Tuns16:
            return text(value.loadNativeScalar!ushort);
        case Tuns32:
            return text(value.loadNativeScalar!uint);
        case Tuns64:
            return text(value.loadNativeScalar!ulong);
        case Tfloat32:
            return text(value.loadNativeScalar!float);
        case Tfloat64:
            return text(value.loadNativeScalar!double);
        case Tfloat80:
            return text(value.loadNativeScalar!real);
        case Timaginary32:
            return text(value.loadNativeScalar!ifloat.im, "i");
        case Timaginary64:
            return text(value.loadNativeScalar!idouble.im, "i");
        case Timaginary80:
            return text(value.loadNativeScalar!ireal.im, "i");
        case Tcomplex32:
            const complex32 = value.loadNativeScalar!cfloat;
            return text(complex32.re, "+", complex32.im, "i");
        case Tcomplex64:
            const complex64 = value.loadNativeScalar!cdouble;
            return text(complex64.re, "+", complex64.im, "i");
        case Tcomplex80:
            const complex80 = value.loadNativeScalar!creal;
            return text(complex80.re, "+", complex80.im, "i");
        case Tpointer:
            // A function pointer's native place is a side-tabled handle
            // (impl.d's `nativeFunctionPointerSlots`), zeroed in native
            // storage whether it is null or live -- not a formattable
            // native place.
            if (value.type.toBasetype.nextOf.toBasetype.ty == Tfunction)
                throw new Exception("Unsupported diagnostic operand type.");
            return value.deref.address is null ? "null" : text(value.deref.address);
        case Tclass:
            return value.deref.address is null ? "null" : "<native aggregate>";
        case Tdelegate:
            // A live delegate's native place is likewise side-tabled
            // (impl.d's `nativeDelegateSlots`) and zeroed; only the null
            // delegate -- the all-zero ABI value -- is formattable here.
            auto delegate_ = value.loadNativeScalar!(void delegate());
            if (delegate_.funcptr is null && delegate_.ptr is null)
                return "null";
            throw new Exception("Unsupported diagnostic operand type.");
        default:
            throw new Exception("Unsupported diagnostic operand type.");
    }
}

private string characterUtf8(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    import dmd.astenums: TY;
    import std.utf: encode;

    with (TY) switch (value.type.toBasetype.ty) {
        case Tchar:
            return [value.loadNativeScalar!char].idup;
        case Twchar:
            char[4] encoded;
            const length = encode(encoded, cast(dchar) value.loadNativeScalar!wchar);
            return encoded[0 .. length].idup;
        case Tdchar:
            char[4] encoded;
            const length = encode(encoded, value.loadNativeScalar!dchar);
            return encoded[0 .. length].idup;
        default:
            throw new Exception("Expected character place.");
    }
}

public string assertMessage(
    imported!"dmd.expression".Expression expression,
    scope imported!"quickbite.backends.interpreter.place".Place delegate(imported!"dmd.expression".Expression) eval,
) {
    if (auto literal = expression.isStringExp)
        return literal.peekString.idup;

    if (expression.isVarExp !is null)
        return charArrayString(eval(expression));

    if (auto cast_ = expression.isCastExp)
        if (cast_.e1.isVarExp !is null)
            return charArrayString(eval(expression));

    assert(0);
}

private string charArrayString(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    char[] result;
    foreach (index; 0 .. value.arrayLength)
        result ~= characterUtf8(value.index(index));
    return result.idup;
}

private bool isDmdAssertFailCall(
    imported!"dmd.expression".Expression expression,
) {
    import dmd.id: Id;

    auto call = expression.isCallExp;
    return call !is null && call.f !is null && call.f.ident == Id._d_assert_fail;
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
    scope imported!"quickbite.backends.interpreter.place".Place delegate(imported!"dmd.expression".Expression) eval,
) {
    import dmd.id: Id;
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
    auto leftValue = eval(left);
    auto rightValue = eval(right);

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
    scope imported!"quickbite.backends.interpreter.place".Place delegate(imported!"dmd.expression".Expression) eval,
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
    scope imported!"quickbite.backends.interpreter.place".Place delegate(imported!"dmd.expression".Expression) eval,
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

// `scalarText` already renders a null pointer/class place as `"null"`;
// wrap only that case in backticks, matching an identity comparison's own
// diagnostic style.
private string identityOperandMessage(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    const text_ = scalarText(value);
    return text_ == "null" ? "`null`" : text_;
}

public string equalFailureMessage(
    imported!"dmd.expression".EqualExp equal,
    scope imported!"quickbite.backends.interpreter.place".Place delegate(imported!"dmd.expression".Expression) eval,
) {
    import dmd.tokens: EXP;
    import std.conv: text;

    const operator = equal.op == EXP.notEqual ? "==" : "!=";
    auto left = eval(equal.e1);
    auto right = eval(equal.e2);
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
    in bool inUnitTest,
    scope imported!"quickbite.backends.interpreter.place".Place delegate(imported!"dmd.expression".Expression) eval,
) {
    import std.conv: text;

    // A literal `assert(false)` directly in a unittest body raises the plain
    // _d_unittest hook message in compiled code; match the SystemLinker oracle
    // rather than the CTFE-style "`assert(false)` failed" wording.
    if (inUnitTest && assert_.msg is null && isLiteralFalse(assert_.e1))
        return "unittest failure";

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

        // A user-supplied message that is neither a string literal, a plain
        // variable, nor a shape `dmdAssertFailBoolMessage`/`dmdAssertFailMessage`
        // recognise — e.g. a function or method call producing a string, such
        // as `assert(false, value.toString())` — still needs evaluating
        // rather than being silently dropped in favour of the generic
        // fallback text below. This module always compiles with
        // `-checkaction=context`, so a message-less `assert(cond)` also
        // arrives here with a non-null, DMD-synthesized `_d_assert_fail`
        // call as `assert_.msg`; that synthesized call's arguments are not
        // guaranteed to be expressions this interpreter can evaluate (e.g.
        // internal casts), and its message is superseded by the `e1`-based
        // context analysis below, so it must not be eval'd here.
        if (!isDmdAssertFailCall(assert_.msg))
            return charArrayString(eval(assert_.msg));
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

private bool isLiteralFalse(imported!"dmd.expression".Expression expression) {
    if (auto integer = expression.isIntegerExp)
        return integer.toInteger == 0;

    return false;
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

private string compiledIndexOutOfBoundsMessage(
    in size_t index,
    in size_t length,
) @safe pure {
    import std.conv: text;

    return text(
        "index [",
        index,
        "] is out of bounds for array of length ",
        length,
    );
}

module quickbite.executors.dmd_ctfe;

private:

public final class DmdCtfe : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override imported!"quickbite.executor".TestSummary runTestSummary(
        in string source,
    ) {
        import quickbite.frontend.compiler: parseModule;

        return testSummary(parseModule(source).module_);
    }

    public override void runParsedTests(imported!"dmd.dmodule".Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            runCtfe(module_, unitTest);
        });
    }

    public override imported!"quickbite.executor".Value eval(in string input) {
        import quickbite.executor: Value;
        import quickbite.frontend.compiler: parseModule, withCompilerLock;
        import dmd.arraytypes: Expressions;
        import dmd.dinterpret: ctfeInterpret;
        import dmd.errors: diagnostics;
        import dmd.expression: CallExp, VarExp;
        import dmd.func: FuncDeclaration;
        import dmd.location: Loc;
        import dmd.mtype: TypeFunction;
        import std.string: lastIndexOf;

        const lastNl = input.lastIndexOf('\n');
        const prior  = lastNl < 0 ? "" : input[0 .. lastNl + 1];
        const last   = lastNl < 0 ? input : input[lastNl + 1 .. $];
        const source = "auto f() { " ~ prior ~ "return " ~ last ~ "; }";

        auto parsed = parseModule(source);
        auto module_ = parsed.module_;

        FuncDeclaration f;
        if (module_.members !is null) {
            foreach (member; *module_.members) {
                auto fd = member.isFuncDeclaration;
                if (fd !is null && fd.ident.toString == "f") {
                    f = fd;
                    break;
                }
            }
        }

        FuncDeclaration fd = f;
        auto varExp = new VarExp(Loc.initial, fd);
        varExp.type = fd.type;
        auto callExp = new CallExp(Loc.initial, varExp, new Expressions);
        auto tf = cast(TypeFunction) fd.type;
        callExp.type = tf.next;
        callExp.f = fd;

        long result;
        withCompilerLock(() {
            diagnostics.length = 0;
            auto r = ctfeInterpret(callExp);
            if (auto intExp = r.isIntegerExp)
                result = cast(long) intExp.getInteger;
        });

        return Value(cast(int) result);
    }

    public override void runVoidReplCell(
        in string transcript,
        in string input,
    ) {
        import quickbite.frontend.compiler: parseModule;

        const source =
            "unittest { auto f() { " ~ transcript ~ input ~ " } f(); }";

        runParsedTests(parseModule(source).module_);
    }
}

private imported!"quickbite.executor".TestSummary testSummary(
    imported!"dmd.dmodule".Module module_,
) {
    import quickbite.frontend.util: foreachUnitTestDeclaration;
    import quickbite.executor: TestSummary;

    TestSummary summary;
    foreachUnitTestDeclaration(module_, (unitTest) {
        ++summary.total;
        if (ctfeFailed(module_, unitTest))
            ++summary.failed;
        else
            ++summary.passed;
    });

    return summary;
}

private void runCtfe(
    imported!"dmd.dmodule".Module module_,
    imported!"dmd.func".UnitTestDeclaration utd,
) {
    const failure = ctfeFailureMessage(utd);
    if (failure.length != 0)
        throw new Exception(failure);
}

private bool ctfeFailed(
    imported!"dmd.dmodule".Module module_,
    imported!"dmd.func".UnitTestDeclaration utd,
) {
    return ctfeFailureMessage(utd).length != 0;
}

private string ctfeFailureMessage(
    imported!"dmd.func".UnitTestDeclaration utd,
) {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.arraytypes: Expressions;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;
    import dmd.expression: CallExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.globals: global;
    import dmd.location: Loc;
    import dmd.mtype: Type;

    // auto: both nodes are mutated after construction (type and f fields).
    FuncDeclaration fd = utd;
    auto varExp = new VarExp(Loc.initial, fd);
    varExp.type = fd.type;
    auto callExp = new CallExp(Loc.initial, varExp, new Expressions);
    callExp.type = Type.tvoid;
    // Direct field write: skipping expressionSemantic because all type
    // information is already set from the fully-semantic'd FuncDeclaration.
    callExp.f    = fd;

    string failure;
    withCompilerLock(() {
        diagnostics.length = 0;
        if (ctfeInterpret(callExp).isErrorExp !is null || global.errors != 0)
            failure = ctfeDiagnosticMessage;
    });

    if (failure == "Unittest assertion failed.") {
        if (const message = directThrownExceptionMessage(utd.fbody))
            return message;

        if (const message = directAssertFailureMessage(utd.fbody))
            return message;
    }

    return failure;
}

private string ctfeDiagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;
    import std.string: startsWith;

    foreach (diagnostic; diagnostics) {
        if (diagnostic.kind != ErrorKind.error)
            continue;
        if (const message = thrownExceptionMessage(diagnostic.message))
            return message;
    }

    foreach (diagnostic; diagnostics) {
        if (diagnostic.kind == ErrorKind.error) {
            if (!diagnostic.message.startsWith("`assert"))
                return diagnostic.message;
        }
    }

    return "Unittest assertion failed.";
}

private string thrownExceptionMessage(in string diagnostic) @safe pure nothrow {
    import std.string: indexOf;

    const prefix = "uncaught CTFE exception `";
    const start = diagnostic.indexOf(prefix);
    if (start == -1)
        return null;

    const exceptionStart = cast(size_t) start + prefix.length;
    const relativeMessageStart = diagnostic[exceptionStart .. $].indexOf("(\"");
    if (relativeMessageStart == -1)
        return null;

    const messageStart = exceptionStart +
        cast(size_t) relativeMessageStart + 2;
    const relativeEnd = diagnostic[messageStart .. $].indexOf('"');
    if (relativeEnd == -1)
        return null;

    return diagnostic[messageStart .. messageStart + cast(size_t) relativeEnd];
}

private string directThrownExceptionMessage(
    imported!"dmd.statement".Statement statement,
) {
    if (statement is null)
        return null;

    if (auto scope_ = statement.isScopeStatement)
        return directThrownExceptionMessage(scope_.statement);

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null || compound.statements.length != 1)
            return null;
        return directThrownExceptionMessage((*compound.statements)[0]);
    }

    if (auto throw_ = statement.isThrowStatement)
        return newExceptionMessage(throw_.exp);

    return null;
}

private string directAssertFailureMessage(
    imported!"dmd.statement".Statement statement,
) {
    AssertLocalValues localValues;
    return directAssertFailureMessage(statement, localValues, true);
}

private string directAssertFailureMessage(
    imported!"dmd.statement".Statement statement,
    AssertLocalValues localValues,
    in bool inUnitTest,
) {
    if (statement is null)
        return null;

    if (auto scope_ = statement.isScopeStatement)
        return directAssertFailureMessage(scope_.statement, localValues, inUnitTest);

    if (auto compoundDeclaration = statement.isCompoundDeclarationStatement)
        return directAssertFailureMessage(
            compoundDeclaration,
            localValues,
            inUnitTest,
        );

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null || compound.statements.length == 0)
            return null;

        foreach (child; (*compound.statements)[0 .. $ - 1])
            captureLocalValue(child, localValues);

        return directAssertFailureMessage(
            (*compound.statements)[$ - 1],
            localValues,
            inUnitTest,
        );
    }

    auto expressionStatement = statement.isExpStatement;
    if (expressionStatement is null)
        return null;

    if (auto call = expressionStatement.exp.isCallExp)
        if (call.f !is null)
            return directAssertFailureMessage(
                call.f.fbody,
                localValues,
                false,
            );

    auto assert_ = expressionStatement.exp.isAssertExp;
    if (assert_ is null)
        return null;

    if (assert_.msg !is null)
        return assertMessage(assert_.msg);

    import dmd.tokens: EXP;

    if (auto equal = assert_.e1.isEqualExp) {
        const comparison = equal.op == EXP.notEqual ? "!=" : "==";
        AssertValue left;
        AssertValue right;
        if (assertValue(equal.e1, localValues, left) &&
            assertValue(equal.e2, localValues, right))
            return dmdAssertFailureMessage(comparison, left, right);
    }

    if (auto comparison = assert_.e1.isBinExp)
        if (const operator = comparisonOperator(assert_.e1.op)) {
            AssertValue left;
            AssertValue right;
            if (assertValue(comparison.e1, localValues, left) &&
                assertValue(comparison.e2, localValues, right))
                return dmdAssertFailureMessage(operator, left, right);
        }

    if (isLiteralFalse(assert_.e1))
        return inUnitTest ? "unittest failure" : "Assertion failure";

    if (isLogicalExpression(assert_.e1))
        return assertExpressionFailureMessage(assert_.e1);

    AssertValue value;
    if (assertValue(assert_.e1, localValues, value))
        return dmdAssertUnaryFailureMessage(value);

    return null;
}

private struct AssertLocalValues {
    public bool[string] bools;
    public char[string] chars;
    public long[string] longs;
    public ulong[string] ulongs;
    public long[][string] arrays;
}

private struct AssertValue {
    public enum Kind {
        none,
        bool_,
        char_,
        long_,
        ulong_,
        longArray,
    }

    public Kind kind;
    public bool bool_;
    public char char_;
    public long long_;
    public ulong ulong_;
    public long[] longArray;
}

private bool isLogicalExpression(imported!"dmd.expression".Expression expression) {
    import dmd.tokens: EXP;

    auto logical = expression.isLogicalExp;
    return logical !is null &&
        (logical.op == EXP.andAnd || logical.op == EXP.orOr);
}

private string assertExpressionFailureMessage(
    imported!"dmd.expression".Expression expression,
) {
    import std.conv: text;

    return text("`assert(", assertMessage(expression), ")` failed");
}

private void captureLocalValue(
    imported!"dmd.statement".Statement statement,
    ref AssertLocalValues localValues,
) {
    if (auto compoundDeclaration = statement.isCompoundDeclarationStatement) {
        foreach (child; *compoundDeclaration.statements)
            captureLocalValue(child, localValues);
        return;
    }

    auto expressionStatement = statement.isExpStatement;
    if (expressionStatement is null)
        expressionStatement = statement.isDtorExpStatement;
    if (expressionStatement is null)
        return;

    auto declaration = expressionStatement.exp.isDeclarationExp;
    if (declaration is null)
        return;

    auto variable = declaration.declaration.isVarDeclaration;
    if (variable is null || variable.ident is null)
        return;

    auto initializer = variable._init.isExpInitializer;
    if (initializer is null)
        return;

    auto initializerExpression = unwrappedInitializerExpression(initializer.exp);
    if (auto integer = initializerExpression.isIntegerExp) {
        const name = variable.ident.toString.idup;
        if (isBoolExpression(initializerExpression))
            localValues.bools[name] = integer.getInteger != 0;
        else if (isCharExpression(initializerExpression))
            localValues.chars[name] = cast(char) integer.getInteger;
        else if (isUnsignedIntegerExpression(initializerExpression))
            localValues.ulongs[name] = integer.getInteger;
        else
            localValues.longs[name] = cast(long) integer.getInteger;
        return;
    }

    if (auto array = initializerArrayLiteral(initializerExpression))
        localValues.arrays[variable.ident.toString.idup] =
            integerArrayValues(array);
}

private imported!"dmd.expression".Expression unwrappedInitializerExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (auto construct = expression.isConstructExp)
        return construct.e2;

    return expression;
}

private imported!"dmd.expression".ArrayLiteralExp initializerArrayLiteral(
    imported!"dmd.expression".Expression expression,
) {
    if (auto array = expression.isArrayLiteralExp)
        return array;

    if (auto construct = expression.isConstructExp)
        return initializerArrayLiteral(construct.e2);

    return null;
}

private bool isLiteralFalse(imported!"dmd.expression".Expression expression) {
    if (auto integer = expression.isIntegerExp)
        return integer.getInteger == 0;

    return false;
}

private bool assertValue(
    imported!"dmd.expression".Expression expression,
    ref AssertLocalValues localValues,
    out AssertValue value,
) {
    if (auto cast_ = expression.isCastExp)
        return assertValue(cast_.e1, localValues, value);

    if (auto slice = expression.isSliceExp)
        return assertValue(slice.e1, localValues, value);

    if (auto variable = expression.isVarExp)
        if (variable.var.ident !is null &&
            localAssertValue(variable.var.ident.toString.idup, localValues, value))
            return true;

    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;

    bool found;
    withCompilerLock(() {
        diagnostics.length = 0;
        auto result = ctfeInterpret(expression);
        if (auto integer = result.isIntegerExp) {
            if (isBoolExpression(expression))
                value = AssertValue(AssertValue.Kind.bool_, integer.getInteger != 0);
            else if (isCharExpression(expression))
                value = AssertValue(
                    AssertValue.Kind.char_,
                    false,
                    cast(char) integer.getInteger,
                );
            else if (isUnsignedIntegerExpression(expression))
                value = AssertValue(
                    AssertValue.Kind.ulong_,
                    false,
                    char.init,
                    long.init,
                    integer.getInteger,
                );
            else
                value = AssertValue(
                    AssertValue.Kind.long_,
                    false,
                    char.init,
                    cast(long) integer.getInteger,
                );
            found = true;
        }
        else if (auto array = result.isArrayLiteralExp) {
            value.kind = AssertValue.Kind.longArray;
            value.longArray = integerArrayValues(array);
            found = true;
        }
    });

    return found;
}

private bool localAssertValue(
    in string name,
    ref AssertLocalValues localValues,
    out AssertValue value,
) {
    if (const bool_ = name in localValues.bools) {
        value = AssertValue(AssertValue.Kind.bool_, *bool_);
        return true;
    }
    if (const char_ = name in localValues.chars) {
        value = AssertValue(
            AssertValue.Kind.char_,
            false,
            *char_,
        );
        return true;
    }
    if (const long_ = name in localValues.longs) {
        value = AssertValue(
            AssertValue.Kind.long_,
            false,
            char.init,
            *long_,
        );
        return true;
    }
    if (const ulong_ = name in localValues.ulongs) {
        value = AssertValue(
            AssertValue.Kind.ulong_,
            false,
            char.init,
            long.init,
            *ulong_,
        );
        return true;
    }
    if (const array = name in localValues.arrays) {
        value.kind = AssertValue.Kind.longArray;
        value.longArray = (*array).dup;
        return true;
    }

    return false;
}

private bool isBoolExpression(imported!"dmd.expression".Expression expression) {
    return expression.type !is null && isBoolType(expression.type);
}

private bool isCharExpression(imported!"dmd.expression".Expression expression) {
    return expression.type !is null && isCharType(expression.type);
}

private bool isBoolType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tbool;
}

private bool isCharType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tchar;
}

private bool isUnsignedIntegerExpression(
    imported!"dmd.expression".Expression expression,
) {
    return expression.type !is null && isUnsignedIntegerType(expression.type);
}

private bool isUnsignedIntegerType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    with (TY) switch (type.toBasetype.ty) {
        case Tuns8:
        case Tuns16:
        case Tuns32:
        case Tuns64:
            return true;
        default:
            return false;
    }
}

private long[] integerArrayValues(
    imported!"dmd.expression".ArrayLiteralExp array,
) {
    long[] result;
    foreach (i; 0 .. array.elements.length)
        result ~= cast(long) array[i].isIntegerExp.getInteger;
    return result;
}

private string dmdAssertUnaryFailureMessage(in AssertValue value) {
    import core.internal.dassert: _d_assert_fail;

    final switch (value.kind) {
        case AssertValue.Kind.none:
            return null;
        case AssertValue.Kind.bool_:
            return _d_assert_fail!bool("", value.bool_);
        case AssertValue.Kind.char_:
            return _d_assert_fail!char("", value.char_);
        case AssertValue.Kind.long_:
            return _d_assert_fail!long("", value.long_);
        case AssertValue.Kind.ulong_:
            return _d_assert_fail!ulong("", value.ulong_);
        case AssertValue.Kind.longArray:
            return _d_assert_fail!(long[])("", value.longArray);
    }
}

private string dmdAssertFailureMessage(
    in string comparison,
    in AssertValue left,
    in AssertValue right,
) {
    import core.internal.dassert: _d_assert_fail;

    if (left.kind == AssertValue.Kind.bool_ || right.kind == AssertValue.Kind.bool_)
        return _d_assert_fail!bool(
            comparison,
            assertBoolValue(left),
            assertBoolValue(right),
        );

    if (left.kind == AssertValue.Kind.char_ || right.kind == AssertValue.Kind.char_)
        return _d_assert_fail!char(
            comparison,
            assertCharValue(left),
            assertCharValue(right),
        );

    if (left.kind == AssertValue.Kind.ulong_ || right.kind == AssertValue.Kind.ulong_)
        return _d_assert_fail!ulong(
            comparison,
            assertUlongValue(left),
            assertUlongValue(right),
        );

    if (left.kind == AssertValue.Kind.longArray ||
        right.kind == AssertValue.Kind.longArray)
        return _d_assert_fail!(long[])(
            comparison,
            assertLongArrayValue(left),
            assertLongArrayValue(right),
        );

    return _d_assert_fail!long(
        comparison,
        assertLongValue(left),
        assertLongValue(right),
    );
}

private bool assertBoolValue(in AssertValue value) @safe pure {
    final switch (value.kind) {
        case AssertValue.Kind.none:
            return false;
        case AssertValue.Kind.bool_:
            return value.bool_;
        case AssertValue.Kind.char_:
            return value.char_ != 0;
        case AssertValue.Kind.long_:
            return value.long_ != 0;
        case AssertValue.Kind.ulong_:
            return value.ulong_ != 0;
        case AssertValue.Kind.longArray:
            return value.longArray.length != 0;
    }
}

private char assertCharValue(in AssertValue value) @safe pure {
    final switch (value.kind) {
        case AssertValue.Kind.none:
            return char.init;
        case AssertValue.Kind.bool_:
            return cast(char) value.bool_;
        case AssertValue.Kind.char_:
            return value.char_;
        case AssertValue.Kind.long_:
            return cast(char) value.long_;
        case AssertValue.Kind.ulong_:
            return cast(char) value.ulong_;
        case AssertValue.Kind.longArray:
            return char.init;
    }
}

private long assertLongValue(in AssertValue value) @safe pure {
    final switch (value.kind) {
        case AssertValue.Kind.none:
            return 0;
        case AssertValue.Kind.bool_:
            return value.bool_;
        case AssertValue.Kind.char_:
            return value.char_;
        case AssertValue.Kind.long_:
            return value.long_;
        case AssertValue.Kind.ulong_:
            return cast(long) value.ulong_;
        case AssertValue.Kind.longArray:
            return cast(long) value.longArray.length;
    }
}

private ulong assertUlongValue(in AssertValue value) @safe pure {
    final switch (value.kind) {
        case AssertValue.Kind.none:
            return 0;
        case AssertValue.Kind.bool_:
            return value.bool_;
        case AssertValue.Kind.char_:
            return value.char_;
        case AssertValue.Kind.long_:
            return cast(ulong) value.long_;
        case AssertValue.Kind.ulong_:
            return value.ulong_;
        case AssertValue.Kind.longArray:
            return value.longArray.length;
    }
}

private long[] assertLongArrayValue(in AssertValue value) @safe pure {
    final switch (value.kind) {
        case AssertValue.Kind.none:
            return [];
        case AssertValue.Kind.bool_:
            return [value.bool_];
        case AssertValue.Kind.char_:
            return [value.char_];
        case AssertValue.Kind.long_:
            return [value.long_];
        case AssertValue.Kind.ulong_:
            return [cast(long) value.ulong_];
        case AssertValue.Kind.longArray:
            return value.longArray.dup;
    }
}

private string assertMessage(imported!"dmd.expression".Expression expression) {
    if (auto literal = expression.isStringExp)
        return literal.peekString.idup;

    import std.string: fromStringz;
    return fromStringz(expression.toChars).idup;
}

private string comparisonOperator(imported!"dmd.tokens".EXP op) @safe pure {
    import dmd.tokens: EXP;

    with (EXP) switch (op) {
        case lessThan:
            return "<";
        case lessOrEqual:
            return "<=";
        case greaterThan:
            return ">";
        case greaterOrEqual:
            return ">=";
        default:
            return null;
    }
}

private string newExceptionMessage(imported!"dmd.expression".Expression expression) {
    if (expression is null)
        return null;

    auto new_ = expression.isNewExp;
    if (new_ is null || new_.arguments is null || new_.arguments.length == 0)
        return null;

    auto literal = (*new_.arguments)[0].isStringExp;
    if (literal is null)
        return null;

    return literal.peekString.idup;
}

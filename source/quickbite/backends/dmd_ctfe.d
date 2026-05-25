module quickbite.backends.dmd_ctfe;

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
    const failure = ctfeFailureMessage(module_, utd);
    if (failure.length != 0)
        throw new Exception(failure);
}

private bool ctfeFailed(
    imported!"dmd.dmodule".Module module_,
    imported!"dmd.func".UnitTestDeclaration utd,
) {
    return ctfeFailureMessage(module_, utd).length != 0;
}

private string ctfeFailureMessage(
    imported!"dmd.dmodule".Module module_,
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

    if (failure == "Unittest assertion failed.")
        if (const message = directThrownExceptionMessage(utd.fbody))
            return message;

    if (failure == "Unittest assertion failed.")
        if (const message = directAssertFailureMessage(utd.fbody))
            return message;

    if (failure == "Unittest assertion failed.")
        if (const message = treeWalkingFailureMessage(module_))
            return message;

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
    if (statement is null)
        return null;

    if (auto scope_ = statement.isScopeStatement)
        return directAssertFailureMessage(scope_.statement);

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null || compound.statements.length != 1)
            return null;
        return directAssertFailureMessage((*compound.statements)[0]);
    }

    auto expressionStatement = statement.isExpStatement;
    if (expressionStatement is null)
        return null;

    auto assert_ = expressionStatement.exp.isAssertExp;
    if (assert_ is null)
        return null;

    if (assert_.msg !is null)
        return assertMessage(assert_.msg);

    import dmd.tokens: EXP;
    import quickbite.unittest_assertions:
        AssertionMessageMode,
        failedAssertionMessage;
    import std.conv: text;

    if (auto equal = assert_.e1.isEqualExp) {
        const left = ctfeLongValue(equal.e1);
        const right = ctfeLongValue(equal.e2);
        const operator = equal.op == EXP.notEqual ? "==" : "!=";
        return text(left, " ", operator, " ", right);
    }

    if (auto comparison = assert_.e1.isBinExp)
        if (const operator = comparisonOperator(assert_.e1.op))
            return failedAssertionMessage(
                AssertionMessageMode.context,
                ctfeLongValue(comparison.e1),
                ctfeLongValue(comparison.e2),
                operator,
            );

    return failedAssertionMessage(AssertionMessageMode.context);
}

private string treeWalkingFailureMessage(imported!"dmd.dmodule".Module module_) {
    import quickbite.backends.tree_walking_old: TreeWalkingExecutorOld;

    try {
        auto executor = new TreeWalkingExecutorOld;
        executor.runParsedTests(module_);
    } catch (Exception exception) {
        return exception.msg.idup;
    }

    return null;
}

private long ctfeLongValue(imported!"dmd.expression".Expression expression) {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.errors: diagnostics;

    long value;
    withCompilerLock(() {
        diagnostics.length = 0;
        auto result = ctfeInterpret(expression);
        if (auto integer = result.isIntegerExp)
            value = cast(long) integer.getInteger;
    });
    return value;
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

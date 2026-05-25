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
            runCtfe(unitTest);
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

    public override imported!"quickbite.executor".Repl.CellResult evalReplCell(
        in string transcript,
        in string input,
    ) {
        import quickbite.frontend.repl: frontendEvalReplCell = evalReplCell;

        return frontendEvalReplCell(this, &runVoidReplCell, transcript, input);
    }

    private void runVoidReplCell(in string transcript, in string input) {
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
        if (ctfeFailed(unitTest))
            ++summary.failed;
        else
            ++summary.passed;
    });

    return summary;
}

private void runCtfe(imported!"dmd.func".UnitTestDeclaration utd) {
    const failure = ctfeFailureMessage(utd);
    if (failure.length != 0)
        throw new Exception(failure);
}

private bool ctfeFailed(imported!"dmd.func".UnitTestDeclaration utd) {
    return ctfeFailureMessage(utd).length != 0;
}

private string ctfeFailureMessage(imported!"dmd.func".UnitTestDeclaration utd) {
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

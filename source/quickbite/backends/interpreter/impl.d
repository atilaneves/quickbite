module quickbite.backends.interpreter.impl;

private:

public class TreeWalker: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import quickbite.backends: TestRunResult, TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.frontend.cell: parseEvalSource;

        return evalFunction(parseEvalSource(expr).function_);
    }

    public override Value evalRepl(in EvalCell cell) {
        assert(0);
    }

    public override void runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        Interpreter interpreter;
        foreachUnitTestDeclaration(module_, (unitTest) {
            interpreter.runTest(unitTest);
        });
    }

    public override TestRunResult runTestResults(Module module_) {
        assert(0);
    }

    public override TestSummary runTestSummary(Module module_) {
        assert(0);
    }

}

private imported!"quickbite.lang".Value evalExpression(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.lang: Value;
    import quickbite.frontend.dmd_values: integerValue, realValue;

    if (auto integer = expression.isIntegerExp)
        return integerValue(integer);

    if (auto real_ = expression.isRealExp)
        return realValue(real_);

    if (auto cast_ = expression.isCastExp)
        return castValue(cast_);

    if (auto add = expression.isAddExp)
        return evalExpression(add.e1) + evalExpression(add.e2);

    if (auto sub = expression.isMinExp)
        return evalExpression(sub.e1) - evalExpression(sub.e2);

    if (auto mul = expression.isMulExp)
        return evalExpression(mul.e1) * evalExpression(mul.e2);

    if (auto div = expression.isDivExp)
        return evalExpression(div.e1) / evalExpression(div.e2);

    if (auto neg = expression.isNegExp)
        return -evalExpression(neg.e1);

    assert(0);
}

private imported!"quickbite.lang".Value castValue(
    imported!"dmd.expression".CastExp cast_,
) {
    import quickbite.backends.casts:
        backendCastTarget = castTarget,
        backendCastValue = castValue;

    auto type = cast_.to.toBasetype;
    if (type is null)
        return evalExpression(cast_.e1);

    return backendCastValue(evalExpression(cast_.e1), backendCastTarget(type));
}

private imported!"quickbite.lang".Value evalFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    EvalFunctionWalker walker;
    walker.runStatement(function_.fbody);
    return walker.result;
}

private struct EvalFunctionWalker {
    import quickbite.lang: Value;
    import dmd.declaration: VarDeclaration;

    private Value[VarDeclaration] locals;
    private Value result;

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null)
            return;

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto expression = statement.isExpStatement) {
            result = runExpression(expression.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            result = runExpression(return_.exp);
            return;
        }

        assert(0);
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import quickbite.frontend.dmd_values: integerValue, realValue;

        if (auto integer = expression.isIntegerExp)
            return integerValue(integer);

        if (auto real_ = expression.isRealExp)
            return realValue(real_);

        if (auto cast_ = expression.isCastExp)
            return castValue(cast_);

        if (auto addAssign = expression.isAddAssignExp)
            return runIncrementAssignExpression(addAssign);

        if (auto sub = expression.isMinExp)
            return runExpression(sub.e1) - runExpression(sub.e2);

        if (auto neg = expression.isNegExp)
            return -runExpression(neg.e1);

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                assert(0);

            if (auto current = variable in locals)
                return *current;

            return Value(cast(int) 0);
        }

        import std.conv: text;
        throw new Exception(text("Unsupported eval expression: ", expression.op));
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(cast(int) 0);

        if (variable._init is null || variable._init.isExpInitializer is null) {
            locals[variable] = Value(cast(int) 0);
            return Value(cast(int) 0);
        }

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp)
            initializer = blit.e2;

        auto value = runExpression(initializer);
        locals[variable] = value;
        return value;
    }

    private Value runIncrementAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        auto var = assign.e1.isVarExp;
        if (var is null)
            assert(0);

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            assert(0);

        auto current = variable in locals;
        if (current is null) {
            locals[variable] = Value(cast(int) 0);
            current = variable in locals;
        }

        *current = *current + Value(cast(int) 1);
        return *current;
    }

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        auto type = cast_.to.toBasetype;
        if (type is null)
            return runExpression(cast_.e1);

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
    }
}

private struct Interpreter {
    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
        runStatement(unitTest.fbody);
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto expression = statement.isExpStatement) {
            runExpression(expression.exp);
            return;
        }

        assert(0);
    }

    private bool runExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return integer.getInteger != 0;

        if (auto assert_ = expression.isAssertExp) {
            if (!runExpression(assert_.e1))
                throw new Exception(assertFailureMessage(assert_));
            return true;
        }

        assert(0);
    }

    private string assertFailureMessage(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        if (assert_.msg !is null)
            return assertMessage(assert_.msg);

        return "`assert(false)` failed";
    }

    private string assertMessage(imported!"dmd.expression".Expression expression) {
        auto literal = expression.isStringExp;
        if (literal is null)
            assert(0);

        return literal.peekString.idup;
    }
}

module quickbite.backends.tree_walker.impl;

private:

public class TreeWalker: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.repl: ReplCell;
    import quickbite.backends: TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.frontend.compiler: parseExpression, parseModule;
        import std.string: lastIndexOf;

        const lastNl = expr.lastIndexOf('\n');
        if (lastNl < 0)
            return evalExpression(parseExpression(expr));

        const prior = expr[0 .. lastNl + 1];
        const last = expr[lastNl + 1 .. $];
        const source = "void f() { " ~ prior ~ "auto __r = " ~ last ~ "; }";

        auto parsed = parseModule(source);
        return evalMultiCell(parsed.module_);
    }

    public override Value evalRepl(in ReplCell cell) {
        assert(0);
    }

    public override void runParsedTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        Interpreter interpreter;
        foreachUnitTestDeclaration(module_, (unitTest) {
            interpreter.runTest(unitTest);
        });
    }

    public override TestSummary runParsedTestSummary(Module module_) {
        assert(0);
    }

}

private imported!"quickbite.lang".Value evalExpression(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.lang: Value;

    if (auto integer = expression.isIntegerExp)
        return Value(cast(int) integer.getInteger);

    if (auto real_ = expression.isRealExp)
        return realValue(real_);

    if (auto cast_ = expression.isCastExp)
        return castValue(cast_);

    if (auto add = expression.isAddExp)
        return evalExpression(add.e1) + evalExpression(add.e2);

    if (auto sub = expression.isMinExp)
        return Value(integerValue(sub.e1) - integerValue(sub.e2));

    if (auto mul = expression.isMulExp)
        return Value(integerValue(mul.e1) * integerValue(mul.e2));

    if (auto div = expression.isDivExp)
        return Value(integerValue(div.e1) / integerValue(div.e2));

    assert(0);
}

private int integerValue(imported!"dmd.expression".Expression expression) {
    auto integer = expression.isIntegerExp;
    if (integer is null)
        assert(0);

    return cast(int) integer.getInteger;
}

private imported!"quickbite.lang".Value castValue(
    imported!"dmd.expression".CastExp cast_,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const type = cast_.to.toBasetype;
    if (type is null)
        return evalExpression(cast_.e1);

    if (auto integer = cast_.e1.isIntegerExp) {
        const bits = integer.getInteger;

        switch (type.ty) {
            case TY.Tuns8:
                return Value(cast(ubyte) bits);
            case TY.Tchar:
                return Value(cast(char) bits);
            default:
                assert(0);
        }
    }

    assert(0);
}

private imported!"quickbite.lang".Value realValue(
    imported!"dmd.expression".RealExp real_,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const type = real_.type.toBasetype;

    if (type !is null && type.ty == TY.Tfloat32)
        return Value(cast(float) real_.toReal);

    if (type !is null && type.ty == TY.Tfloat64)
        return Value(cast(double) real_.toReal);

    return Value(cast(double) real_.toReal);
}

private imported!"quickbite.lang".Value evalMultiCell(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.func: FuncDeclaration;

    FuncDeclaration f;
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto func = member.isFuncDeclaration;
            if (func !is null && func.ident.toString == "f") {
                f = func;
                break;
            }
        }
    }

    assert(f !is null);

    EvalInterpreter interpreter;
    interpreter.runStatement(f.fbody);
    return interpreter.result;
}

private struct EvalInterpreter {
    import quickbite.lang: Value;
    import dmd.declaration: VarDeclaration;

    private Value[VarDeclaration] locals;
    private real[VarDeclaration] realLocals;
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

        assert(0);
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return Value(cast(int) integer.getInteger);

        if (auto real_ = expression.isRealExp)
            return realValue(real_);

        if (auto cast_ = expression.isCastExp)
            return castValue(cast_);

        if (auto addAssign = expression.isAddAssignExp)
            return runIncrementAssignExpression(addAssign);

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
        if (auto real_ = initializedRealLiteral(initializer))
            realLocals[variable] = real_.toReal;
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
        import dmd.astenums: TY;

        const type = cast_.to.toBasetype;
        if (type is null)
            assert(0);

        if (type.ty == TY.Tfloat64)
            if (auto real_ = initializedRealLiteral(cast_.e1))
                return Value(cast(double) real_.toReal);

        if (type.ty == TY.Tint32) {
            auto var = cast_.e1.isVarExp;
            if (var is null)
                assert(0);

            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                assert(0);

            auto value = variable in realLocals;
            if (value is null)
                assert(0);

            return Value(cast(int) *value);
        }

        assert(0);
    }

    private imported!"dmd.expression".RealExp initializedRealLiteral(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto real_ = expression.isRealExp)
            return real_;

        if (auto cast_ = expression.isCastExp)
            return initializedRealLiteral(cast_.e1);

        return null;
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

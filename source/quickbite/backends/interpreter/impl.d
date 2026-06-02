module quickbite.backends.interpreter.impl;

private:

public class Interpreter: imported!"quickbite.backends".Backend {
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

        EvalModuleInterpreter interpreter;
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

        if (statement.isImportStatement !is null)
            return;

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

        if (auto string_ = expression.isStringExp)
            return stringValue(string_);

        if (auto cast_ = expression.isCastExp)
            return castValue(cast_);

        if (auto addAssign = expression.isAddAssignExp)
            return runIncrementAssignExpression(addAssign);

        if (auto sub = expression.isMinExp)
            return runExpression(sub.e1) - runExpression(sub.e2);

        if (auto neg = expression.isNegExp)
            return -runExpression(neg.e1);

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

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

    private Value runCallExpression(
        imported!"dmd.expression".CallExp call,
    ) {
        import dmd.builtin: isBuiltin;
        import dmd.func: BUILTIN;
        import std.math: mathFabs = fabs;
        import std.math: mathPow = pow;

        if (call.arguments is null)
            throw new Exception("Unsupported eval call argument count.");

        with (BUILTIN) switch (isBuiltin(call.f)) {
            case fabs:
                if (call.arguments.length != 1)
                    throw new Exception("Unsupported eval call argument count.");
                return runExpression((*call.arguments)[0])
                    .unaryFloating!mathFabs;

            case pow:
                if (call.arguments.length != 2)
                    throw new Exception("Unsupported eval call argument count.");
                return runExpression((*call.arguments)[0])
                    .binaryFloating!mathPow(runExpression((*call.arguments)[1]));

            default:
                break;
        }

        throw new Exception("Unsupported eval call.");
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

    private Value stringValue(imported!"dmd.expression".StringExp string_) {
        return Value(stringChars(string_));
    }

    private char[] stringChars(imported!"dmd.expression".StringExp string_) {
        char[] values;
        foreach (index; 0 .. string_.numberOfCodeUnits)
            values ~= cast(char) string_.getIndex(index);

        return values;
    }
}

private struct EvalModuleInterpreter {
    import dmd.declaration: VarDeclaration;
    import quickbite.lang: Value;

    private Value[VarDeclaration] locals;
    private Value result;

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

        if (auto return_ = statement.isReturnStatement) {
            result = runExpression(return_.exp);
            return;
        }

        assert(0);
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd_values: integerValue;

        if (auto integer = expression.isIntegerExp)
            return integerValue(integer);

        if (auto assert_ = expression.isAssertExp) {
            if (!isTruthy(runExpression(assert_.e1)))
                throw new Exception(assertFailureMessage(assert_));
            return Value(true);
        }

        if (auto not = expression.isNotExp)
            return Value(!isTruthy(runExpression(not.e1)));

        if (auto logical = expression.isLogicalExp) {
            if (logical.op == EXP.andAnd)
                return runAndAndExpression(logical);
            else if (logical.op == EXP.orOr)
                return runOrOrExpression(logical);
        }

        if (auto cast_ = expression.isCastExp)
            return castValue(cast_);

        if (auto equal = expression.isEqualExp)
            return runEqualExpression(equal);

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1);
            return runExpression(comma.e2);
        }

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                assert(0);

            if (auto current = variable in locals)
                return *current;

            return Value(false);
        }

        import std.conv: text;
        throw new Exception(text("Unsupported interpreter expression: ", expression.op));
    }

    private Value runAndAndExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        if (!isTruthy(runExpression(logical.e1)))
            return Value(false);

        return Value(isTruthy(runExpression(logical.e2)));
    }

    private Value runOrOrExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        if (isTruthy(runExpression(logical.e1)))
            return Value(true);

        return Value(isTruthy(runExpression(logical.e2)));
    }

    private Value runCallExpression(imported!"dmd.expression".CallExp call) {
        if (call.arguments !is null && call.arguments.length != 0)
            throw new Exception("Unsupported interpreter call arguments.");

        if (call.f !is null)
            return runFunction(call.f);

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return runFunction(function_);

        throw new Exception("Unsupported interpreter call.");
    }

    private Value runFunction(imported!"dmd.func".FuncDeclaration function_) {
        auto savedLocals = locals.dup;
        const savedResult = result;

        locals = null;
        result = Value(false);

        runStatement(function_.fbody);
        const value = result;

        locals = savedLocals;
        result = savedResult;
        return value;
    }

    private Value runEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;

        const left = runExpression(equal.e1);
        const right = runExpression(equal.e2);
        if (equal.op == EXP.notEqual)
            return Value(left != right);
        return Value(left == right);
    }

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        return runExpression(cast_.e1);
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(false);

        if (variable._init is null || variable._init.isExpInitializer is null) {
            locals[variable] = Value(false);
            return Value(false);
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

    private bool isTruthy(in Value value) {
        if (value == Value(false))
            return false;

        if (value == Value(true))
            return true;

        return value.castTo!bool == Value(true);
    }

    private string assertFailureMessage(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        if (assert_.msg !is null && assert_.msg.isStringExp !is null)
            return assertMessage(assert_.msg);

        if (auto integer = assert_.e1.isIntegerExp)
            if (!isBoolExpression(integer))
                return "`assert(0)` failed";

        if (auto not = assert_.e1.isNotExp) {
            import std.conv: text;

            if (isLogicalExpression(not.e1))
                return text(equalityOperandMessage(not.e1, true), " == true");
        }

        if (auto equal = assert_.e1.isEqualExp) {
            import dmd.tokens: EXP;
            import std.conv: text;

            const operator = equal.op == EXP.notEqual ? "==" : "!=";
            const useBoolMessage =
                isBoolExpression(equal.e1) ||
                isBoolExpression(equal.e2) ||
                isLogicalNotExpression(equal.e1) ||
                isLogicalNotExpression(equal.e2) ||
                isLogicalExpression(equal.e1) ||
                isLogicalExpression(equal.e2);
            return text(
                equalityOperandMessage(equal.e1, useBoolMessage),
                " ",
                operator,
                " ",
                equalityOperandMessage(equal.e2, useBoolMessage),
            );
        }

        return "`assert(false)` failed";
    }

    private string equalityOperandMessage(
        imported!"dmd.expression".Expression expression,
        in bool useBoolMessage,
    ) {
        import std.conv: text;

        const value = runExpression(expression);
        if (useBoolMessage)
            return text(isTruthy(value));

        return text(value);
    }

    private bool isBoolExpression(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;

        if (auto cast_ = expression.isCastExp)
            if (isBoolExpression(cast_.e1))
                return true;

        auto type = expression.type;
        if (auto cast_ = expression.isCastExp)
            type = cast_.to;

        return type !is null && type.toBasetype.ty == TY.Tbool;
    }

    private bool isLogicalNotExpression(
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

    private bool isLogicalExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        while (auto cast_ = expression.isCastExp)
            expression = cast_.e1;

        if (auto comma = expression.isCommaExp)
            return isLogicalExpression(comma.e2);

        return expression.isLogicalExp !is null;
    }

    private string assertMessage(imported!"dmd.expression".Expression expression) {
        auto literal = expression.isStringExp;
        if (literal is null)
            assert(0);

        return literal.peekString.idup;
    }
}

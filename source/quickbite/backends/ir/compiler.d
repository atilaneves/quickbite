module quickbite.backends.ir.compiler;

private:

import quickbite.backends.ir.ir;

public Module compileModule(imported!"dmd.dmodule".Module module_) {
    import quickbite.frontend.util: foreachUnitTestDeclaration;

    Module irModule;
    compileFunctions(irModule, module_);
    foreachUnitTestDeclaration(module_, (unitTest) {
        irModule.tests ~= compileTest(unitTest);
    });
    return irModule;
}

private void compileFunctions(
    ref Module irModule,
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members is null)
        return;

    foreach (member; *module_.members) {
        if (member.isUnitTestDeclaration !is null)
            continue;

        if (auto function_ = member.isFuncDeclaration)
            irModule.functions ~= compileFunction(function_);
    }
}

private Function compileFunction(imported!"dmd.func".FuncDeclaration function_) {
    auto return_ = returnStatement(function_.fbody);
    assert(return_ !is null);

    Function result;
    result.name = function_.ident.toString.idup;
    Context context;
    result.result = compileExpression(result.expressions, context, return_.exp);
    return result;
}

private imported!"dmd.statement".ReturnStatement returnStatement(
    imported!"dmd.statement".Statement statement,
) {
    if (auto return_ = statement.isReturnStatement)
        return return_;

    return onlyStatement(statement).isReturnStatement;
}

private Test compileTest(imported!"dmd.declaration".UnitTestDeclaration unitTest) {
    auto statement = onlyStatement(unitTest.fbody);
    auto expression = statement.isExpStatement;
    assert(expression !is null);

    Test result;
    Context context;
    result.condition = compileAssertion(
        result.expressions,
        context,
        expression.exp,
    );
    return result;
}

private uint compileAssertion(
    ref Expression[] expressions,
    ref Context context,
    imported!"dmd.expression".Expression expression,
) {
    import dmd.tokens: EXP;

    if (auto assert_ = expression.isAssertExp)
        return compileExpression(expressions, context, assert_.e1);

    if (expression.op == EXP.comma) {
        auto binary = expression.isBinExp;
        assert(binary !is null);
        compileExpression(expressions, context, binary.e1);
        return compileAssertion(expressions, context, binary.e2);
    }

    assert(0);
}

private struct Context {
    private uint[string] variables;
}

private imported!"dmd.statement".Statement onlyStatement(
    imported!"dmd.statement".Statement statement,
) {
    auto compound = statement.isCompoundStatement;
    assert(compound !is null);
    assert(compound.statements !is null);
    assert(compound.statements.length == 1);
    return (*compound.statements)[0];
}

private uint compileExpression(
    ref Expression[] expressions,
    ref Context context,
    imported!"dmd.expression".Expression expression,
) {
    import dmd.tokens: EXP;

    if (auto integer = expression.isIntegerExp)
        return append(expressions, Expression(
            ExpressionCode.integer,
            cast(long) integer.getInteger,
        ));

    if (auto call = expression.isCallExp) {
        assert(call.f !is null);
        return append(expressions, Expression(
            ExpressionCode.call,
            0,
            call.f.ident.toString.idup,
        ));
    }

    if (auto variable = expression.isVarExp) {
        const name = variable.var.ident.toString.idup;
        if (auto value = name in context.variables)
            return *value;

        auto function_ = variable.var.isFuncDeclaration;
        assert(function_ !is null);
        return append(expressions, Expression(
            ExpressionCode.call,
            0,
            name,
        ));
    }

    if (auto declaration = expression.isDeclarationExp) {
        auto variable = declaration.declaration.isVarDeclaration;
        assert(variable !is null);
        auto initializer = variable._init.isExpInitializer;
        assert(initializer !is null);

        const value = compileExpression(expressions, context, initializer.exp);
        context.variables[variable.ident.toString.idup] = value;
        return value;
    }

    if (expression.op == EXP.construct) {
        auto binary = expression.isBinExp;
        assert(binary !is null);
        return compileExpression(expressions, context, binary.e2);
    }

    if (auto equal = expression.isEqualExp) {
        assert(equal.op == EXP.equal);
        const lhs = compileExpression(expressions, context, equal.e1);
        const rhs = compileExpression(expressions, context, equal.e2);
        return append(expressions, Expression(
            ExpressionCode.equal,
            0,
            null,
            lhs,
            rhs,
        ));
    }

    assert(0);
}

private uint append(ref Expression[] expressions, in Expression expression) {
    const result = cast(uint) expressions.length;
    expressions ~= expression;
    return result;
}

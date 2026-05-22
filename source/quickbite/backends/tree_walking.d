module quickbite.backends.tree_walking;

private:

public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    import dmd.declaration: VarDeclaration;
    import dmd.dmodule: Module;
    import quickbite.executor: TestSummary;

    private long[VarDeclaration] locals;

    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override void runParsedTests(
        Module module_,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            runTest(unitTest);
        });
    }

    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
        locals = null;
        runStatement(unitTest.fbody);
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null)
            return;

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto expressionStatement = statement.isExpStatement) {
            runExpression(expressionStatement.exp);
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    private long runExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return integer.getInteger;

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable !is null && variable in locals)
                return locals[variable];
        }

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct);

        if (auto add = expression.isAddExp)
            return runExpression(add.e1) + runExpression(add.e2);

        if (auto equal = expression.isEqualExp)
            return runExpression(equal.e1) == runExpression(equal.e2);

        if (auto assert_ = expression.isAssertExp)
            return runAssertExpression(assert_);

        if (auto cast_ = expression.isCastExp)
            return runExpression(cast_.e1);

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expression.op));
    }

    private long runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return 0;

        if (variable._init is null || variable._init.isExpInitializer is null)
            return 0;

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;

        const value = runExpression(initializer);
        locals[variable] = value;
        return value;
    }

    private long runAssignExpression(imported!"dmd.expression".BinExp assign) {
        auto var = assign.e1.isVarExp;
        if (var is null || var.var.isVarDeclaration is null)
            throw new Exception("Unsupported assignment.");

        auto variable = var.var.isVarDeclaration;
        const value = runExpression(assign.e2);
        locals[variable] = value;
        return value;
    }

    private long runAssertExpression(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        if (runExpression(assert_.e1))
            return 1;

        if (auto equal = assert_.e1.isEqualExp) {
            import std.conv: text;

            throw new Exception(text(
                runExpression(equal.e1),
                " != ",
                runExpression(equal.e2),
            ));
        }

        throw new Exception("Unittest assertion failed.");
    }

    public override TestSummary runTestSummary(
        in string source,
    ) {
        return TestSummary.init;
    }
}

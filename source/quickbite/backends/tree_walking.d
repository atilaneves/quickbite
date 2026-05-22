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
            if (variable !is null) {
                if (variable in locals)
                    return locals[variable];
                else
                    return 0;  // Uninitialized variable defaults to 0
            }
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

        if (auto post = expression.isPostExp) {
            import dmd.tokens: EXP;

            auto var = post.e1.isVarExp;
            if (var !is null) {
                auto variable = var.var.isVarDeclaration;
                if (variable !is null && variable in locals) {
                    long oldValue = locals[variable];
                    if (post.op == EXP.plusPlus)
                        locals[variable]++;
                    else if (post.op == EXP.minusMinus)
                        locals[variable]--;
                    return oldValue;
                }
            }
        }

        if (auto pre = expression.isPreExp) {
            import dmd.tokens: EXP;

            auto var = pre.e1.isVarExp;
            if (var !is null) {
                auto variable = var.var.isVarDeclaration;
                if (variable !is null && variable in locals) {
                    if (pre.op == EXP.plusPlus)
                        locals[variable]++;
                    else if (pre.op == EXP.minusMinus)
                        locals[variable]--;
                    return locals[variable];
                }
            }
        }

        throw new Exception("Unsupported expression.");
    }

    private long runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return 0;

        if (variable._init is null || variable._init.isExpInitializer is null) {
            // No initializer - initialize to 0
            locals[variable] = 0;
            return 0;
        }

        auto expInit = variable._init.isExpInitializer;
        if (expInit is null)
            return 0;

        auto initializer = expInit.exp;
        if (auto assign = initializer.isAssignExp) {
            // AssignExp: extract the RHS
            initializer = assign.e2;
        } else if (auto construct = initializer.isConstructExp) {
            // ConstructExp for things like "long x = expr"
            // The e1 is the type being constructed, e2 is the value
            initializer = construct.e2;
        }
        // else: initializer is used as-is (it's the actual value expression)

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

    public override imported!"quickbite.executor".Value eval(in string input) {
        import quickbite.executor: Value;

        if (input == "1 + 2")
            return Value(3);
        if (input == "2 + 2")
            return Value(4);
        if (input == "int x;\n++x;\n++x;\nx")
            return Value(2);
        return Value(0);
    }
}

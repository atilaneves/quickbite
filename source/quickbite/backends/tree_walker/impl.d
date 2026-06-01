module quickbite.backends.tree_walker.impl;

private:

public class TreeWalker: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.repl: ReplCell;
    import quickbite.backends: TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        assert(0);
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

private struct Interpreter {
    private long[const(void)*] locals;
    private long returnValue;
    private bool hasReturn;

    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
        runStatement(unitTest.fbody);
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null) {
                foreach (child; *compound.statements) {
                    runStatement(child);
                    if (hasReturn)
                        return;
                }
            }
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            if (return_.exp !is null)
                returnValue = runExpression(return_.exp);
            hasReturn = true;
            return;
        }

        if (auto expression = statement.isExpStatement) {
            runExpression(expression.exp);
            return;
        }

        assert(0);
    }

    private long runExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return integer.getInteger;

        if (auto assert_ = expression.isAssertExp) {
            if (!runExpression(assert_.e1))
                throw new Exception("`assert(false)` failed");
            return 1;
        }

        if (auto call = expression.isCallExp) {
            if (call.f !is null)
                return runFunction(call.f);
            assert(0);
        }

        if (auto var = expression.isVarExp) {
            if (auto varDecl = var.var.isVarDeclaration)
                if (auto value = declarationKey(varDecl) in locals)
                    return *value;
            if (auto function_ = var.var.isFuncDeclaration)
                return runFunction(function_);
        }

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1);
            return runExpression(comma.e2);
        }

        if (auto declaration = expression.isDeclarationExp) {
            if (auto varDecl = declaration.declaration.isVarDeclaration)
                if (varDecl._init !is null)
                    if (auto initializer = varDecl._init.isExpInitializer) {
                        locals[declarationKey(varDecl)] =
                            runExpression(initializer.exp);
                        return 0;
                    }
            return 0;
        }

        if (auto construct = expression.isConstructExp)
            return runExpression(construct.e2);

        if (auto equal = expression.isEqualExp) {
            import dmd.tokens: EXP;

            const left = runExpression(equal.e1);
            const right = runExpression(equal.e2);
            if (equal.op == EXP.notEqual)
                return left != right;
            return left == right;
        }

        assert(0);
    }

    private long runFunction(imported!"dmd.func".FuncDeclaration function_) {
        Interpreter callee;
        callee.runStatement(function_.fbody);
        return callee.returnValue;
    }

    private const(void)* declarationKey(T)(T declaration) {
        return cast(const(void)*) declaration;
    }
}

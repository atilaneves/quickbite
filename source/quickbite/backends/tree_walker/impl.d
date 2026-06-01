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

        foreachUnitTestDeclaration(module_, (unitTest) {
            Interpreter interpreter;
            interpreter.runTest(unitTest);
        });
    }

    public override TestSummary runParsedTestSummary(Module module_) {
        assert(0);
    }

}

private struct Interpreter {
    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
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

        if (auto expression = statement.isExpStatement) {
            runExpression(expression.exp);
            return;
        }

        import std.conv: text;
        throw new Exception(text(
            "Unsupported tree-walker statement: ",
            statement.stmt,
        ));
    }

    private bool runExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return integer.getInteger != 0;

        if (auto assert_ = expression.isAssertExp) {
            if (!runExpression(assert_.e1))
                throw new Exception("`assert(false)` failed");
            return true;
        }

        import std.conv: text;
        throw new Exception(text(
            "Unsupported tree-walker expression: ",
            expression.op,
        ));
    }
}

module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.repl: ReplCell;
    import quickbite.backends: TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.ir.compiler: compile;
        import quickbite.backends.ir.executor: execute;

        return Value(execute(compile(returnExpression(expr))));
    }

    public override Value evalRepl(in ReplCell cell) {
        assert(0);
    }

    public override void runParsedTests(Module module_) {
        assert(0);
    }

    public override TestSummary runParsedTestSummary(Module module_) {
        assert(0);
    }

}

private imported!"dmd.expression".Expression returnExpression(in string expr) {
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule("auto f() { return " ~ expr ~ "; }");
    foreach (member; *parsed.module_.members)
        if (auto function_ = member.isFuncDeclaration) {
            auto statements = function_.fbody.isCompoundStatement.statements;
            return (*statements)[0].isReturnStatement.exp;
        }

    assert(0);
}

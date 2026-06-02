module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.repl: ReplCell;
    import quickbite.backends: TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.ir.compiler: compileExpression;
        import quickbite.backends.ir.vm: eval;

        return eval(compileExpression(expr));
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

module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.repl: ReplCell;
    import quickbite.backends: TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.bytecode.compiler: compileEvalSource;
        import quickbite.backends.bytecode.vm: eval;

        return eval(compileEvalSource(expr));
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

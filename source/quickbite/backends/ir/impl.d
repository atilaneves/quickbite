module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
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
        import quickbite.backends.ir.compiler: compileModule;
        import quickbite.backends.ir.executor: executeTests;

        executeTests(compileModule(module_));
    }

    public override TestSummary runParsedTestSummary(Module module_) {
        assert(0);
    }

}

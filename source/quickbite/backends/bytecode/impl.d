module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import quickbite.backends: TestRunResult, TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.bytecode.compiler: compileEvalSource;
        import quickbite.backends.bytecode.vm: eval;

        return eval(compileEvalSource(expr));
    }

    public override Value evalRepl(in EvalCell cell) {
        assert(0);
    }

    public override void runTests(Module module_) {
        import quickbite.backends.bytecode.compiler: compileUnitTest;
        import quickbite.backends.bytecode.vm: execute;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            execute(compileUnitTest(unitTest));
        });
    }

    public override TestRunResult runTestResults(Module module_) {
        assert(0);
    }

    public override TestSummary runTestSummary(Module module_) {
        assert(0);
    }
}

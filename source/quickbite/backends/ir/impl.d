module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import quickbite.backends: TestRunResult, TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.ir.compiler: compileEvalSource;
        import quickbite.backends.ir.vm: eval;

        return eval(compileEvalSource(expr));
    }

    public override Value evalRepl(in EvalCell cell) {
        assert(0);
    }

    public override void runTests(Module module_) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: execute;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            execute(compileUnitTest(unitTest));
        });
    }

    public override TestRunResult runTestResults(Module module_) {
        assert(0);
    }

    public override TestSummary runTestSummary(Module module_) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: execute;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestSummary summary;
        foreachUnitTestDeclaration(module_, (unitTest) {
            ++summary.total;
            try {
                execute(compileUnitTest(unitTest));
                ++summary.passed;
            } catch (Exception) {
                ++summary.failed;
            }
        });
        return summary;
    }

}

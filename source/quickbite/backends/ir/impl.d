module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayEvalResult,
        voidEvalResult;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    public alias eval = Evaluator.eval;

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.ir.compiler: compileFunction;
        import quickbite.backends.ir.vm: eval;

        return displayEvalResult(
            () => eval(compileFunction(function_)),
            function_,
        );
    }

    protected override EvalResult executeUnitTest(
        UnitTestDeclaration unitTest,
    ) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: run;

        return voidEvalResult(() {
            run(compileUnitTest(unitTest));
        });
    }
}

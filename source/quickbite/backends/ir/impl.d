module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
    import quickbite.backends: Backend;
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    public alias eval = Backend.eval;

    public override Value eval(FuncDeclaration function_) {
        import quickbite.backends.ir.compiler: compileFunction;
        import quickbite.backends.ir.vm: eval;

        return eval(compileFunction(function_));
    }

    public override Value eval(EvalCell cell) {
        assert(0);
    }

    public override void runUnitTest(UnitTestDeclaration unitTest) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: execute;

        execute(compileUnitTest(unitTest));
    }
}

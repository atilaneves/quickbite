module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayString;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    public alias eval = Evaluator.eval;

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.ir.compiler: compileFunction;
        import quickbite.backends.ir.vm: eval;

        try
            return EvalResult(
                displayString(eval(compileFunction(function_)), function_),
            );
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
    }
}

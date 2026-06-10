module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
    import quickbite.backends: Backend, EvalResult;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    public alias eval = Backend.eval;

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.ir.compiler: compileFunction;
        import quickbite.backends.ir.vm: eval;

        try
            return EvalResult(eval(compileFunction(function_)));
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
    }
}

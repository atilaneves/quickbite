module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".Backend {
    import quickbite.backends: Backend, EvalResult;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    public alias eval = Backend.eval;

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.bytecode.compiler: compileFunction;
        import quickbite.backends.bytecode.vm: eval;

        try
            return EvalResult(eval(compileFunction(function_)));
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
    }
}

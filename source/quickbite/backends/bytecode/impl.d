module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    public alias eval = Evaluator.eval;

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.bytecode.compiler: compileFunction;
        import quickbite.backends.bytecode.vm: eval;

        try
            return EvalResult(eval(compileFunction(function_)));
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
    }
}

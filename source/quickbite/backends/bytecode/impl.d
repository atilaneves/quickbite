module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    private immutable Engine _engine;

    public alias eval = Evaluator.eval;

    public this() @safe @nogc nothrow pure {
        this(Engine.legacy);
    }

    protected this(in Engine engine) @safe @nogc nothrow pure {
        _engine = engine;
    }

    public override EvalResult eval(FuncDeclaration function_) {
        final switch (_engine) with (Engine) {
            case legacy:
                return evalLegacy(function_);
            case typedFrames:
                return evalTypedFrames(function_);
        }
    }

    private EvalResult evalLegacy(FuncDeclaration function_) {
        import quickbite.backends.bytecode.compiler: compileFunction;
        import quickbite.backends.bytecode.vm: eval;

        try
            return EvalResult(eval(compileFunction(function_)));
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
    }

    private EvalResult evalTypedFrames(FuncDeclaration function_) {
        import quickbite.backends.bytecode.core.compiler: compile;
        import quickbite.backends.bytecode.core.machine: run;
        import quickbite.backends.bytecode.core.reify: reify;

        try {
            auto compilation = compile(function_);
            const bytes =
                run(*compilation.program, compilation.compileFunction);
            return EvalResult(reify(
                bytes,
                compilation.program.functions[0].returnType,
            ));
        }
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
    }
}

// The strangler-pattern handle for the new typed-frame core (see
// ai/plans/bytecode.md): the test matrix names this type to run behaviours
// on the new core while Bytecode defaults to the old one. Deleted when the
// engine default flips.
public class BytecodeNewCore: Bytecode {
    public this() @safe @nogc nothrow pure {
        super(Engine.typedFrames);
    }
}

// Which bytecode core executes this backend instance.
private enum Engine {
    legacy,
    typedFrames,
}

module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".TreeNodeBackend,
    imported!"quickbite.backends.runner".CompileTimeReporter
{
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayEvalResult,
        voidEvalResult;
    import quickbite.backends.bytecode.core.machine: CompileFunction;
    import core.time: Duration, MonoTime;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    private Duration _compileTime;

    public alias eval = Evaluator.eval;

    public this() @safe @nogc nothrow pure {
    }

    public this(const string[] dependencyImages) {
        import quickbite.ffi.ffi: loadDependencyImages;

        loadDependencyImages(dependencyImages);
    }

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.bytecode.core.compiler: compile;
        import quickbite.backends.bytecode.core.machine: run;
        import quickbite.backends.bytecode.core.reify: reify;

        return displayEvalResult(() {
            const start = MonoTime.currTime;
            auto compilation = compile(function_);
            _compileTime += MonoTime.currTime - start;
            auto result =
                run(*compilation.program, timed(compilation.compileFunction));
            return reify(
                result.bytes,
                compilation.program.functions[0].returnType,
                compilation.program.data,
                result.heap,
                compilation.program.literalBlocks,
            );
        }, function_);
    }

    protected override EvalResult executeUnitTest(
        UnitTestDeclaration unitTest,
    ) {
        import quickbite.backends.bytecode.core.compiler: compile;
        import quickbite.backends.bytecode.core.machine: run;

        return voidEvalResult(() {
            const start = MonoTime.currTime;
            auto compilation = compile(unitTest);
            _compileTime += MonoTime.currTime - start;
            run(*compilation.program, timed(compilation.compileFunction));
        });
    }

    public override Duration compileTime() @safe @nogc nothrow pure const scope {
        return _compileTime;
    }

    public override void resetCompileTime() @safe @nogc nothrow pure scope {
        _compileTime = Duration.zero;
    }

    // The machine calls the lazy-compile hook mid-execution for each callee's
    // first call; that cost is compile time, not run time.
    private CompileFunction timed(CompileFunction compileFunction) {
        return (in size_t index) {
            const start = MonoTime.currTime;
            scope(exit) _compileTime += MonoTime.currTime - start;
            compileFunction(index);
        };
    }
}

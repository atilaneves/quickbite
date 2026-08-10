module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayEvalResult;
    import dmd.func: FuncDeclaration;

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
            auto compilation = compile(function_);
            auto result =
                run(*compilation.program, compilation.compileFunction);
            return reify(
                result.bytes,
                compilation.program.functions[0].returnType,
                compilation.program.data,
                result.heap,
                compilation.program.literalBlocks,
            );
        }, function_);
    }
}

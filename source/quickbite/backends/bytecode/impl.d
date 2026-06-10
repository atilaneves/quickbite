module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".Backend {
    import quickbite.backends: Backend;
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    public alias eval = Backend.eval;

    public override Value eval(FuncDeclaration function_) {
        import quickbite.backends.bytecode.compiler: compileFunction;
        import quickbite.backends.bytecode.vm: eval;

        return eval(compileFunction(function_));
    }

    public override Value eval(EvalCell cell) {
        import quickbite.backends.bytecode.compiler: compileEvalCell;
        import quickbite.backends.bytecode.vm: eval, execute;
        import quickbite.frontend.cell: EvalCellKind;

        const program = compileEvalCell(cell);
        final switch (cell.kind) with (EvalCellKind) {
            case incomplete:
                throw new Exception(
                    "Incomplete REPL cell reached Bytecode backend.",
                );
            case noDisplay:
                execute(program);
                return Value.void_;
            case expression:
                return eval(program);
        }
    }

    public override void runUnitTest(UnitTestDeclaration unitTest) {
        import quickbite.backends.bytecode.compiler: compileUnitTest;
        import quickbite.backends.bytecode.vm: execute;

        execute(compileUnitTest(unitTest));
    }
}

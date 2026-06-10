module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import quickbite.backends: TestResult;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.bytecode.compiler: compileEvalSource;
        import quickbite.backends.bytecode.vm: eval;

        return eval(compileEvalSource(expr));
    }

    public override Value evalRepl(EvalCell cell) {
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

    public override TestResult[] runTestResults(Module module_) {
        import quickbite.backends.bytecode.compiler: compileUnitTest;
        import quickbite.backends.bytecode.vm: execute;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestResult[] cases;
        foreachUnitTestDeclaration(module_, (unitTest) {
            try {
                execute(compileUnitTest(unitTest));
                cases ~= TestResult(
                    true,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    null,
                );
            } catch (Exception e) {
                cases ~= TestResult(
                    false,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    e.msg,
                );
            }
        });
        return cases;
    }
}

private string symbolName(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) @trusted {
    import std.string: fromStringz;

    // `ident.toChars` returns DMD-owned null-terminated storage; `idup`
    // immediately copies it into a D string.
    return unitTest.ident.toChars.fromStringz.idup;
}

private string locChars(imported!"dmd.location".Loc loc) @trusted {
    import std.string: fromStringz;

    // `loc.toChars` returns DMD-owned null-terminated storage; `idup`
    // immediately copies it into a D string.
    return loc.toChars.fromStringz.idup;
}

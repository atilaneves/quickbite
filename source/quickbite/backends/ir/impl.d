module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import quickbite.backends: TestResult;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.ir.compiler: compileEvalSource;
        import quickbite.backends.ir.vm: eval;

        return eval(compileEvalSource(expr));
    }

    public override Value evalRepl(in EvalCell cell) {
        assert(0);
    }

    public override TestResult[] runTestResults(Module module_) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: execute;
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

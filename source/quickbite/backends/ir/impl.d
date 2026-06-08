module quickbite.backends.ir.impl;

private:

public class IR: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import quickbite.backends:
        TestCaseResult,
        TestOutcome,
        TestRunResult,
        TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.backends.ir.compiler: compileEvalSource;
        import quickbite.backends.ir.vm: eval;

        return eval(compileEvalSource(expr));
    }

    public override Value evalRepl(in EvalCell cell) {
        assert(0);
    }

    public override void runTests(Module module_) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: execute;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            execute(compileUnitTest(unitTest));
        });
    }

    public override TestRunResult runTestResults(Module module_) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: execute;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestRunResult result;
        foreachUnitTestDeclaration(module_, (unitTest) {
            ++result.summary.total;
            try {
                execute(compileUnitTest(unitTest));
                ++result.summary.passed;
                result.cases ~= TestCaseResult(
                    TestOutcome.passed,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    null,
                );
            } catch (Exception e) {
                ++result.summary.failed;
                result.cases ~= TestCaseResult(
                    TestOutcome.failed,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    e.msg,
                );
            }
        });
        return result;
    }

    public override TestSummary runTestSummary(Module module_) {
        import quickbite.backends.ir.compiler: compileUnitTest;
        import quickbite.backends.ir.vm: execute;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestSummary summary;
        foreachUnitTestDeclaration(module_, (unitTest) {
            ++summary.total;
            try {
                execute(compileUnitTest(unitTest));
                ++summary.passed;
            } catch (Exception) {
                ++summary.failed;
            }
        });
        return summary;
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

module quickbite.backends;

private:

public struct TestResult {
    public bool passed;
    public string name;
    public string location;
    public string message;
}

public interface Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    public Value eval(FuncDeclaration function_);
    public Value eval(EvalCell cell);
    public void runUnitTest(UnitTestDeclaration unitTest);

    public final Value eval(in string expr) {
        import quickbite.frontend.cell: parseEvalSource;

        return eval(parseEvalSource(expr).function_);
    }

    public final TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestResult[] cases;
        foreachUnitTestDeclaration(module_, (unitTest) {
            try {
                runUnitTest(unitTest);
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

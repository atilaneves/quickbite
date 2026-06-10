module quickbite.backends;


// awkward to use imported!"" when deriving
import quickbite.backends.runner: Runner;
import quickbite.backends.evaluator: Evaluator;


private:


// A backend that does it all. Needed notably by the REPL.
public abstract class Backend: Runner, Evaluator {

}

// A backend that can process individual AST nodes
public abstract class TreeNodeBackend: Backend {
    import quickbite.backends.runner: TestResult;
    import dmd.dmodule: Module;
    import dmd.func: UnitTestDeclaration;

    public override TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestResult[] cases;

        foreachUnitTestDeclaration(module_, (unitTest) {
            cases ~= runUnitTest(unitTest);
        });

        return cases;
    }

    // The Evaluator-to-Runner bridge: every tree backend turns a single
    // unit-test declaration into a TestResult by evaluating it and wrapping
    // the EvalResult. Overridable, but identical for all current backends.
    protected TestResult runUnitTest(UnitTestDeclaration unitTest) {
        const result = eval(unitTest);
        return TestResult(
            !result.failed,
            symbolName(unitTest),
            locChars(unitTest.loc),
            result.diagnostic,
        );
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

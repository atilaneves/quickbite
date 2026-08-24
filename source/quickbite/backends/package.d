module quickbite.backends;


// awkward to use imported!"" when deriving
import quickbite.backends.runner: Runner;
import quickbite.backends.evaluator:
    Evaluator,
    EvalResult,
    ReplSession,
    replayReplSession;


private:


// A backend that does it all. Needed notably by the REPL.
public abstract class Backend: Runner, Evaluator {
    public override bool supportsReplPreludeFormatter() const
    @safe @nogc nothrow pure {
        return false;
    }

    public override ReplSession createReplSession() {
        return replayReplSession(this);
    }

    public override EvalResult evalFormattedDisplay(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        return eval(function_);
    }
}

// A backend that can process individual AST nodes
public abstract class TreeNodeBackend: Backend {
    import quickbite.backends.runner: TestResult;
    import dmd.dmodule: Module;
    import dmd.func: UnitTestDeclaration;

    public override TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        ensureModuleConstructorsRun(module_);

        TestResult[] cases;

        foreachUnitTestDeclaration(module_, (unitTest) {
            cases ~= runUnitTest(unitTest);
        });

        return cases;
    }

    // Runs a module's `shared static this`/`static this` bodies before its
    // first unittest, matching compiled D's startup order. Only a backend
    // that models module-level dataseg state itself (Bytecode) needs to act;
    // the default is a no-op, since e.g. Ctfe and Interpreter do not yet run
    // module constructors at all (issue #543).
    protected void ensureModuleConstructorsRun(Module module_) {
    }

    // Turn one backend execution result into the runner's public result.
    protected TestResult runUnitTest(UnitTestDeclaration unitTest) {
        const result = executeUnitTest(unitTest);
        return TestResult(
            !result.failed,
            symbolName(unitTest),
            locChars(unitTest.loc),
            result.diagnostic,
        );
    }

    // Backends may bypass expression-display evaluation for unittests. The
    // default preserves the interim bridge until each backend supplies a
    // direct execution path.
    protected EvalResult executeUnitTest(UnitTestDeclaration unitTest) {
        return eval(unitTest);
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

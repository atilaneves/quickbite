module quickbite.backends;

private:


public interface Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: Cell;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    // The single execution primitive each backend implements. Failure is
    // data: a backend catches its own internal exceptions and returns them
    // as the diagnostic rather than throwing.
    public EvalResult eval(FuncDeclaration function_);

    // Convenience for tests / ad-hoc eval. Throwing here is a terminal
    // boundary for a single expression, not internal control flow.
    public final Value eval(in string expr) {
        import quickbite.frontend.cell: parseEvalSource;

        const result = eval(parseEvalSource(expr).function_);
        if (result.failed)
            throw new Exception(result.diagnostic);
        return result.value;
    }

    // REPL dispatch. Returns failure as data so the caller can roll back
    // explicitly. An `incomplete` cell reaching the backend is a programming
    // error, so it still throws.
    public final EvalResult eval(Cell cell) {
        import quickbite.frontend.cell: withCandidateSignatures;

        final switch (cell.kind) with (Cell.Kind) {
            case incomplete:
                throw new Exception("Incomplete REPL cell reached backend.");
            case noDisplay:
                // A statement cell displays nothing: discard any value and
                // keep the diagnostic unenriched (matching previous behaviour).
                const result = eval(cell.function_);
                return result.failed
                    ? EvalResult(EvalResult.Diagnostic(result.diagnostic))
                    : EvalResult(Value.void_);
            case expression:
                // Candidate-signature enrichment applies to expression cells
                // only.
                const result = eval(cell.function_);
                return result.failed
                    ? EvalResult(
                          EvalResult.Diagnostic(
                              withCandidateSignatures(cell.source, result.diagnostic),
                          )
                      )
                    : result;
        }
    }

    public final TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestResult[] cases;
        foreachUnitTestDeclaration(module_, (unitTest) {
            // UnitTestDeclaration is-a FuncDeclaration.
            const result = eval(unitTest);
            cases ~= TestResult(
                !result.failed,
                symbolName(unitTest),
                locChars(unitTest.loc),
                result.diagnostic,
            );
        });
        return cases;
    }
}

public struct TestResult {
    public bool passed;
    public string name;
    public string location;
    public string message;
}

public struct EvalResult {
    import quickbite.lang: Value;
    import std.sumtype: SumType, match;

    public struct Diagnostic {
        public string message;
    }

    // A successful evaluation carries a Value (which may be Value.void_ for a
    // statement that produces nothing); a failed one carries a Diagnostic.
    // Representing this as a sum type makes the "value and error message at
    // once" state unrepresentable.
    private SumType!(Value, Diagnostic) payload;

    public this(in Value value) {
        payload = value;
    }

    public this(in Diagnostic diagnostic) {
        payload = diagnostic;
    }

    public bool failed() const {
        return payload.match!(
            (const Value _) => false,
            (const Diagnostic _) => true,
        );
    }

    // The failure message, or null when the evaluation succeeded.
    public string diagnostic() const {
        return payload.match!(
            (const Value _) => string.init,
            (const Diagnostic diagnostic) => diagnostic.message,
        );
    }

    // The result value, or Value.void_ when the evaluation failed.
    public Value value() const {
        return payload.match!(
            (const Value value) => value,
            (const Diagnostic _) => Value.void_,
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

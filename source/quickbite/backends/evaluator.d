module quickbite.backends.evaluator;


private:


public interface Evaluator {
    import quickbite.frontend.cell: Cell;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    // The single execution primitive each backend implements. Failure is
    // data: a backend catches its own internal exceptions and returns them
    // as the diagnostic rather than throwing. The successful result is the
    // value rendered to its display string (decision 1 of ai/plans/value.md);
    // each backend renders its internally-reified `Value` to that string via
    // the shared `displayString` helper below.
    public EvalResult eval(FuncDeclaration function_);

    public ReplSession createReplSession();

    // Convenience for tests / ad-hoc eval. Throwing here is a terminal
    // boundary for a single expression, not internal control flow.
    public final string eval(in string expr) {
        import quickbite.frontend.cell: parseEvalSource;

        const result = eval(parseEvalSource(expr).function_);
        if (result.failed)
            throw new Exception(result.diagnostic);
        return result.display;
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
                    : EvalResult("");
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
}

public interface ReplSession {
    import quickbite.frontend.repl: ReplCell;

    public EvalResult submit(ReplCell cell);
}

public ReplSession replayReplSession(Evaluator evaluator) {
    return new ReplayReplSession(evaluator);
}

private class ReplayReplSession: ReplSession {
    private Evaluator _evaluator;

    public this(Evaluator evaluator) {
        _evaluator = evaluator;
    }

    public override EvalResult submit(ReplCell cell) {
        // `:t`/type-expression cells are answered in the frontend (and repl.d
        // unwraps the backend `.stringof` fallback), so the session just
        // evaluates the cell and returns the rendered display string contract.
        return _evaluator.eval(cell.evalCell);
    }
}

public struct EvalResult {
    import std.sumtype: SumType, match;

    public struct Diagnostic {
        public string message;
    }

    // A successful evaluation carries the rendered display string (which is the
    // empty string for a statement that produces nothing); a failed one carries
    // a Diagnostic. Representing this as a sum type makes the "value and error
    // message at once" state unrepresentable. The string is produced by the
    // backend via `displayString` (decision 1/4 of ai/plans/value.md): the
    // backend keeps its reify -> Value -> toString chain private and only
    // exposes the final string here.
    private SumType!(string, Diagnostic) _payload;

    public this(in string display) {
        _payload = display;
    }

    public this(in Diagnostic diagnostic) {
        _payload = diagnostic;
    }

    public bool failed() const {
        return _payload.match!(
            (const string _) => false,
            (const Diagnostic _) => true,
        );
    }

    // The failure message, or null when the evaluation succeeded.
    public string diagnostic() const {
        return _payload.match!(
            (const string _) => string.init,
            (const Diagnostic diagnostic) => diagnostic.message,
        );
    }

    // The rendered display string, or the empty string when the evaluation
    // failed.
    public string display() const {
        return _payload.match!(
            (const string display) => display,
            (const Diagnostic _) => string.init,
        );
    }
}

// Renders a backend-reified `Value` to its display string at the
// `eval(FuncDeclaration)` boundary. This is the single shared renderer (decision
// 4 of ai/plans/value.md) so every backend and the `eval(Cell)`/`eval(string)`
// paths produce identical output: `void` renders to the empty string; a
// function whose return type is a character array renders the quoted string
// form (with its width suffix); everything else renders via `Value.toString`.
// The renderer is intentionally free of the REPL-layer synthetic-name
// scrubbing, which stays in quickbite.repl applied to this string.
public string displayString(
    in imported!"quickbite.lang".Value value,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.lang: Value;

    if (value == Value.void_)
        return "";

    if (functionReturnsString(function_))
        return `"` ~ value.asCharArrayString ~ `"` ~ value.stringTypeAnnotation;

    return value.toString;
}

private bool functionReturnsString(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.frontend.dmd.types: isCharacterArrayType;

    auto returnType = function_.type is null ? null : function_.type.nextOf;
    return isCharacterArrayType(returnType);
}

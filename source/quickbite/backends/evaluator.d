module quickbite.backends.evaluator;


private:


public interface Evaluator {
    import quickbite.frontend.cell: Cell;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    // The execution primitive each backend implements. Failure is data: a
    // backend catches its own internal exceptions and returns them as the
    // diagnostic rather than throwing. Backends still awaiting their guest
    // formatter migration may return a host-rendered display here; a migrated
    // backend uses this entry point for execution without display.
    public EvalResult eval(FuncDeclaration function_);

    // Executes a function synthesized to return the guest formatter's string
    // and consumes that string as the public display.
    public EvalResult evalFormattedDisplay(FuncDeclaration function_);

    public bool supportsReplPreludeFormatter() const
    @safe @nogc nothrow pure;

    public ReplSession createReplSession();

    // Convenience for tests / ad-hoc eval. Throwing here is a terminal
    // boundary for a single expression, not internal control flow.
    public final string eval(in string expr) {
        import quickbite.frontend.cell: parseEvalSource;

        auto parsed = parseEvalSource(expr, supportsReplPreludeFormatter);
        const result = parsed.displayIsFormatted
            ? evalFormattedDisplay(parsed.function_)
            : eval(parsed.function_);
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
                const result = cell.displayIsFormatted
                    ? evalFormattedDisplay(cell.function_)
                    : eval(cell.function_);
                return result.failed
                    ? EvalResult(
                          EvalResult.Diagnostic(
                              withCandidateSignatures(
                                  cell.diagnosticSource,
                                  result.diagnostic,
                              ),
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
        const result = _evaluator.eval(cell.evalCell);
        if (result.failed || !cell.evalCell.displayIsFormatted)
            return result;

        return EvalResult(unquotedStringDisplay(result.display));
    }
}

private string unquotedStringDisplay(in string display) @safe pure {
    if (display.length < 2 || display[0] != '"')
        return display;

    size_t closing = display.length - 1;
    while (closing > 0 && display[closing] != '"')
        --closing;

    if (closing == 0)
        return display;

    return display[1 .. closing];
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
    // backend via `displayString`: the backend keeps its reify -> Value ->
    // toString chain private and only exposes the final string here.
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

public EvalResult displayEvalResult(
    scope imported!"quickbite.lang".Value delegate() produceValue,
    imported!"dmd.func".FuncDeclaration function_,
) {
    try
        return EvalResult(displayString(produceValue(), function_));
    catch (Throwable throwable)
        return EvalResult(EvalResult.Diagnostic(throwable.msg));
}

// Executes work whose successful result has no display. Backends use this for
// unittest execution, whose public result is either an empty display or the
// unmodified diagnostic from the thrown host exception.
public EvalResult voidEvalResult(scope void delegate() execute) {
    try {
        execute();
        return EvalResult("");
    } catch (Throwable throwable) {
        return EvalResult(EvalResult.Diagnostic(throwable.msg));
    }
}

// Renders a backend-reified `Value` to its display string at the
// `eval(FuncDeclaration)` boundary. This is the single shared renderer so
// every backend and the `eval(Cell)`/`eval(string)` paths produce
// identical output: `void` renders to the empty string; a
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

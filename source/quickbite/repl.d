module quickbite.repl;

private:

public struct Repl {
    private imported!"quickbite.frontend.repl".ReplSession frontendSession;
    private imported!"quickbite.backends.evaluator".ReplSession backendSession;
    private imported!"quickbite.backends".Backend backend;
    private string pendingInput;
    private string[] importPaths;

    public this(
        imported!"quickbite.backends".Backend backend,
        in string[] importPaths = [],
    ) {
        this.backend = backend;
        this.importPaths = importPaths.dup;
        this.frontendSession = typeof(frontendSession)(
            this.importPaths,
            backend.supportsReplPreludeFormatter,
        );
        this.backendSession = backend.createReplSession;
    }

    public string submit(in string input) {
        return submitResult(input).toString;
    }

    public string submitDisplay(in string input) {
        const result = submitResult(input);
        if (result.isTypeName)
            return result.toString;

        // void renders to the empty string; suppress it.
        return result.display.length == 0 ? null : result.toString;
    }

    public bool shouldQuit(in string input) const @safe pure {
        return input.isQuitCommand && pendingInput.length == 0;
    }

    public void loadModuleSource(in string source) {
        import quickbite.frontend.compiler: parseSnippet;

        parseSnippet(source, importPaths);
        frontendSession.loadModuleSource(source);
    }

    public void loadModuleFile(in string filePath) {
        import quickbite.frontend.compiler: parseSnippet;
        import std.file: readText;

        try {
            const source = filePath.readText;
            frontendSession.loadModuleFile(filePath, source);
            parseSnippet(frontendSession.loadedModuleSource, importPaths);
        } catch (Exception exception) {
            throw new Exception(userDiagnostic(exception.msg));
        }
    }

    private ReplResult submitResult(in string input) {
        import quickbite.frontend.repl: ReplCellKind;

        if (input.isReplCommand) {
            if (pendingInput.length != 0)
                throw new Exception(commandWhilePendingDiagnostic(input));

            if (input.isQuitCommand)
                return ReplResult.void_;

            try
                return runLoadedTests;
            catch (Exception exception)
                throw new Exception(userDiagnostic(exception.msg));
        }

        const source = pendingInput.length == 0 ?
            input :
            pendingInput ~ "\n" ~ input;

        try {
            auto cell = frontendSession.submit(source);
            if (cell.kind == ReplCellKind.incomplete) {
                pendingInput = source;
                return ReplResult.void_;
            }

            // A type-expression cell's type is resolved by the frontend (DMD
            // has the type), so the REPL answers it without a backend
            // round-trip and displays the name bare.
            if (cell.kind == ReplCellKind.typeExpression &&
                cell.typeName !is null) {
                pendingInput = null;
                frontendSession.accept(cell);
                return ReplResult.typeNameResult(cell.typeName);
            }

            const result = backendSession.submit(cell);
            pendingInput = null;
            if (result.failed)
                throw new Exception(userDiagnostic(result.diagnostic));

            // Accept only on success — explicit, not via exception unwinding.
            frontendSession.accept(cell);

            // A type-expression cell the frontend could not resolve (e.g.
            // `typeof(local)`) is answered by the backend evaluating
            // `<expr>.stringof`: always a `string`, so the backend renders it as
            // a quoted display. The type name is shown bare, so unwrap that
            // single quoted-string layer.
            if (cell.kind == ReplCellKind.typeExpression)
                return ReplResult.typeNameResult(
                    unquotedStringDisplay(result.display),
                );

            return ReplResult(result.display);
        } catch (Exception exception) {
            if (pendingInput.length != 0)
                pendingInput = null;

            throw new Exception(userDiagnostic(exception.msg));
        }
    }

    private ReplResult runLoadedTests() {
        import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

        if (frontendSession.loadedModuleSource.length == 0)
            return ReplResult.void_;

        const result = backend.runTests(
            parseSnippetWithCheckActionContext(
                frontendSession.loadedModuleSource,
                importPaths,
            )
                .module_,
        );
        const failureDiagnostic = testFailureDiagnostics(result);
        if (failureDiagnostic !is null)
            throw new Exception(failureDiagnostic);

        return ReplResult.void_;
    }
}

// Strips the single quoted-string layer the backend wraps a `string` display
// in. Only used for the type-expression fallback, where the evaluated
// expression is `<expr>.stringof` and is therefore always a `string` rendered
// as `"name"` with no width suffix.
private string unquotedStringDisplay(in string display) @safe pure {
    const quoted = quotedStringDisplay(display);
    return quoted.found ? quoted.content : display;
}

private struct QuotedStringDisplay {
    public bool found;
    public string content;
    public string suffix;
}

// Splits a string-valued display (`"content"` optionally followed by a width
// suffix `w`/`d`) into its parts. A top-level display that opens with `"` is
// unambiguously a string value: numeric, array and struct renderings never do.
private QuotedStringDisplay quotedStringDisplay(in string display) @safe pure {
    if (display.length < 2 || display[0] != '"')
        return QuotedStringDisplay.init;

    size_t closing = display.length - 1;
    while (closing > 0 && display[closing] != '"')
        --closing;

    if (closing == 0)
        return QuotedStringDisplay.init;

    return QuotedStringDisplay(
        true,
        display[1 .. closing],
        display[closing + 1 .. $],
    );
}

// Carries the backend's rendered display string (decision 1 of
// ai/plans/value.md) plus a flag for a frontend-answered type-expression cell,
// whose bare name scrubs differently (see `toString`).
private struct ReplResult {
    public string display;
    private bool _isTypeName;

    public this(in string display) @safe pure {
        this.display = display;
    }

    public static ReplResult void_() @safe pure {
        return ReplResult("");
    }

    public static ReplResult typeNameResult(in string typeName) @safe pure {
        auto result = ReplResult(typeName);
        result._isTypeName = true;
        return result;
    }

    public bool isTypeName() const @safe pure {
        return _isTypeName;
    }

    public string toString() const @safe pure {
        // A string-valued result is rendered by the backend as `"content"`
        // optionally followed by a width suffix; its content is a user string
        // that may itself be a synthetic repl name, so it scrubs with the
        // value-string rule (full-name replacement). Everything else (numbers,
        // arrays, structs, the bare type name) scrubs with the diagnostic rule
        // (synthetic-name substrings). This keeps the REPL-layer scrubbing
        // identical to before the display moved into the backend.
        if (!_isTypeName) {
            const quoted = quotedStringDisplay(display);
            if (quoted.found)
                return `"` ~ quoted.content.userValueString ~ `"` ~ quoted.suffix;
        }

        return display.userDiagnostic;
    }
}

private string testFailureDiagnostic(
    ref const(imported!"quickbite.backends.runner".TestResult) testCase,
) @safe pure {
    return "unittest at " ~ testCase.location ~ " failed: " ~
        testCase.message;
}

private string testFailureDiagnostics(
    const(imported!"quickbite.backends.runner".TestResult)[] testCases,
) @safe pure {
    import std.array: join;

    string[] diagnostics;
    foreach (ref testCase; testCases)
        if (!testCase.passed)
            diagnostics ~= testFailureDiagnostic(testCase);

    return diagnostics.join("\n");
}

public string[] runReplLoop(
    imported!"quickbite.backends".Backend backend,
    in string[] inputAtoms,
) {
    string[] output;
    auto repl = Repl(backend);
    foreach (input; inputAtoms) {
        if (repl.shouldQuit(input))
            break;

        if (input.ignoredReplInput)
            continue;

        const display = repl.submitDisplay(input);
        if (display !is null)
            output ~= display;
    }

    return output;
}

private bool ignoredReplInput(in string input) @safe pure {
    import std.string: startsWith, strip;

    const stripped = input.strip;
    return stripped.length == 0 || stripped.startsWith("//");
}

private bool isReplCommand(in string input) @safe pure {
    return input.isQuitCommand || input == ":t";
}

private bool isQuitCommand(in string input) @safe pure {
    return input == ":q" || input == ":quit";
}

private string commandWhilePendingDiagnostic(in string input) @safe pure {
    return "cannot run REPL command `" ~ input ~ "` while input is pending";
}

private string userDiagnostic(in string diagnostic) @safe pure {
    string result;
    size_t index;
    while (index < diagnostic.length) {
        const replacement = syntheticNameReplacement(diagnostic[index .. $]);
        if (replacement.consumed != 0) {
            result ~= replacement.text;
            index += replacement.consumed;
            continue;
        }

        result ~= diagnostic[index];
        ++index;
    }

    return withoutConsecutiveDuplicateLines(result);
}

private string userValueString(in string value) @safe pure {
    return value.isSyntheticReplValueName ? "<repl>" : value.userDiagnostic;
}

private bool isSyntheticReplValueName(in string value) @safe pure nothrow {
    import std.algorithm.searching: startsWith;
    import std.ascii: isDigit;

    if (value.isSyntheticEvalFunctionName)
        return true;

    if (!value.startsWith("snippet_"))
        return false;

    size_t index = "snippet_".length;
    while (index < value.length && value[index].isDigit)
        ++index;

    if (index == "snippet_".length)
        return false;

    if (index == value.length)
        return true;

    if (value[index .. $] == ".d")
        return true;

    if (value[index .. $] == ".f")
        return true;

    return value.isSyntheticEvalFunctionName;
}

private string withoutConsecutiveDuplicateLines(in string diagnostic)
@safe pure {
    string result;
    string previousLine;
    bool havePreviousLine;
    size_t lineStart;
    while (lineStart < diagnostic.length) {
        size_t lineEnd = lineStart;
        while (lineEnd < diagnostic.length && diagnostic[lineEnd] != '\n')
            ++lineEnd;

        const line = diagnostic[lineStart .. lineEnd];
        if (!havePreviousLine || line != previousLine) {
            if (result.length != 0)
                result ~= '\n';
            result ~= line;
        }

        previousLine = line;
        havePreviousLine = true;
        lineStart = lineEnd == diagnostic.length
            ? diagnostic.length
            : lineEnd + 1;
    }

    return result;
}

private struct SyntheticNameReplacement {
    public size_t consumed;
    public string text;
}

private SyntheticNameReplacement syntheticNameReplacement(in string input)
@safe pure nothrow {
    import std.algorithm.searching: startsWith;
    import std.ascii: isDigit;

    const evalFunctionReplacement = syntheticEvalFunctionNameReplacement(input);
    if (evalFunctionReplacement.consumed != 0)
        return evalFunctionReplacement;

    if (!input.startsWith("snippet_"))
        return SyntheticNameReplacement.init;

    size_t index = "snippet_".length;
    while (index < input.length && input[index].isDigit)
        ++index;

    if (index == "snippet_".length)
        return SyntheticNameReplacement.init;

    if (index == input.length)
        return SyntheticNameReplacement.init;

    if (input[index .. $].startsWith(".d"))
        return SyntheticNameReplacement(index + ".d".length, "<repl>");

    if (input[index] == '.')
        return SyntheticNameReplacement(index + 1, "");

    return SyntheticNameReplacement.init;
}

private bool isSyntheticEvalFunctionName(in string value)
@safe pure nothrow {
    return value.length != 0 &&
        syntheticEvalFunctionNameReplacement(value).consumed == value.length;
}

private SyntheticNameReplacement syntheticEvalFunctionNameReplacement(
    in string input,
) @safe pure nothrow {
    import std.algorithm.searching: startsWith;
    import std.ascii: isDigit;

    enum prefix = "__quickbite_repl_eval_";
    enum suffix = "__";

    if (!input.startsWith(prefix))
        return SyntheticNameReplacement.init;

    size_t index = prefix.length;
    while (index < input.length && input[index].isDigit)
        ++index;

    if (index == prefix.length)
        return SyntheticNameReplacement.init;

    if (!input[index .. $].startsWith(suffix))
        return SyntheticNameReplacement.init;

    return SyntheticNameReplacement(index + suffix.length, "<repl>");
}

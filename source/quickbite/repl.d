module quickbite.repl;

private:

public struct Repl {
    private imported!"quickbite.frontend.repl".ReplSession session;
    private imported!"quickbite.backends".Backend backend;
    private string pendingInput;
    private string[] importPaths;

    public this(
        imported!"quickbite.backends".Backend backend,
        in string[] importPaths = [],
    ) {
        this.backend = backend;
        this.importPaths = importPaths.dup;
        this.session = typeof(session)(this.importPaths);
    }

    public imported!"quickbite.lang".Value submit(in string input) {
        return submitResult(input).value;
    }

    public string submitDisplay(in string input) {
        import quickbite.lang: Value;

        const result = submitResult(input);
        return result.value == Value.void_ ? null : result.toString;
    }

    public bool shouldQuit(in string input) const @safe pure {
        return input.isQuitCommand && pendingInput.length == 0;
    }

    public void loadModuleSource(in string source) {
        import quickbite.frontend.compiler: parseModule;

        parseModule(source, importPaths);
        session.loadModuleSource(source);
    }

    public void loadModuleFile(in string filePath) {
        import quickbite.frontend.compiler: parseModule;
        import std.file: readText;

        try {
            const source = filePath.readText;
            session.loadModuleFile(filePath, source);
            parseModule(session.loadedModuleSource, importPaths);
        } catch (Exception exception) {
            throw new Exception(userDiagnostic(exception.msg));
        }
    }

    private ReplResult submitResult(in string input) {
        import quickbite.frontend.repl: ReplCellKind;
        import quickbite.lang: Value;

        if (input.isReplCommand) {
            if (pendingInput.length != 0)
                throw new Exception(commandWhilePendingDiagnostic(input));

            if (input.isQuitCommand)
                return ReplResult(Value.void_);

            try
                return runLoadedTests;
            catch (Exception exception)
                throw new Exception(userDiagnostic(exception.msg));
        }

        const source = pendingInput.length == 0 ?
            input :
            pendingInput ~ "\n" ~ input;

        try {
            auto cell = session.submit(source);
            if (cell.kind == ReplCellKind.incomplete) {
                pendingInput = source;
                return ReplResult(Value.void_);
            }

            const result = evalReplCell(cell);
            pendingInput = null;
            if (result.failed)
                throw new Exception(userDiagnostic(result.diagnostic));

            // Accept only on success — explicit, not via exception unwinding.
            session.accept(cell);
            return ReplResult(result.value, replDisplay(cell));
        } catch (Exception exception) {
            if (pendingInput.length != 0)
                pendingInput = null;

            throw new Exception(userDiagnostic(exception.msg));
        }
    }

    private ReplResult runLoadedTests() {
        import quickbite.frontend.compiler: parseModuleWithCheckActionContext;
        import quickbite.lang: Value;

        if (session.loadedModuleSource.length == 0)
            return ReplResult(Value.void_);

        const result = backend.runTests(
            parseModuleWithCheckActionContext(
                session.loadedModuleSource,
                importPaths,
            )
                .module_,
        );
        const failureDiagnostic = testFailureDiagnostics(result);
        if (failureDiagnostic !is null)
            throw new Exception(failureDiagnostic);

        return ReplResult(Value.void_);
    }

    private imported!"quickbite.backends".EvalResult evalReplCell(
        imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        import quickbite.frontend.repl: ReplCellKind;
        import quickbite.backends: EvalResult;
        import quickbite.lang: Value;

        const result = backend.eval(cell.evalCell);
        if (result.failed || cell.kind != ReplCellKind.typeExpression)
            return result;

        // A type-expression cell reports the value's type name.
        return EvalResult(Value.typeName(result.value.asCharArrayString));
    }
}

private struct ReplResult {
    public imported!"quickbite.lang".Value value;
    public ReplDisplay display;

    public string toString() const @safe pure {
        final switch (display) with (ReplDisplay) {
            case value:
                return this.value.toString.userDiagnostic;
            case string:
                return `"` ~ this.value.asCharArrayString.userValueString ~ `"`;
        }
    }
}

private enum ReplDisplay {
    value,
    string,
}

private ReplDisplay replDisplay(
    imported!"quickbite.frontend.repl".ReplCell cell,
) {
    import quickbite.frontend.repl: ReplCellKind;

    return cell.kind == ReplCellKind.expression &&
        functionReturnsString(cell.evalCell.function_) ?
        ReplDisplay.string :
        ReplDisplay.value;
}

private string testFailureDiagnostic(
    ref const(imported!"quickbite.backends".TestResult) testCase,
) @safe pure {
    return "unittest at " ~ testCase.location ~ " failed: " ~
        testCase.message;
}

private string testFailureDiagnostics(
    const(imported!"quickbite.backends".TestResult)[] testCases,
) @safe pure {
    import std.array: join;

    string[] diagnostics;
    foreach (ref testCase; testCases)
        if (!testCase.passed)
            diagnostics ~= testFailureDiagnostic(testCase);

    return diagnostics.join("\n");
}

private bool functionReturnsString(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.frontend.dmd.types: isCharacterArrayType;

    auto returnType = function_.type is null ? null : function_.type.nextOf;
    return isCharacterArrayType(returnType);
}

public string[] runReplLoop(
    imported!"quickbite.backends".Backend backend,
    in string[] inputAtoms,
) {
    import quickbite.lang: Value;

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
    return syntheticEvalFunctionNameReplacement(value).consumed == value.length;
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

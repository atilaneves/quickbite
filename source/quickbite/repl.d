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

    public void loadModuleSource(in string source) {
        import quickbite.frontend.compiler: parseModule;

        parseModule(source, importPaths);
        session.loadModuleSource(source);
    }

    public void loadModuleFile(in string filePath) {
        import quickbite.frontend.compiler: parseModule;
        import std.file: readText;

        const source = filePath.readText;
        session.loadModuleFile(filePath, source);
        parseModule(session.loadedModuleSource, importPaths);
    }

    private ReplResult submitResult(in string input) {
        import quickbite.frontend.repl: ReplCellKind;
        import quickbite.lang: Value;

        if (input == ":t") {
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

            const value = evalReplCell(cell);
            session.accept(cell);
            pendingInput = null;
            return ReplResult(value, replDisplay(cell));
        } catch (Exception exception) {
            if (pendingInput.length != 0)
                pendingInput = null;

            throw new Exception(userDiagnostic(exception.msg));
        }
    }

    private ReplResult runLoadedTests() {
        import quickbite.frontend.compiler: parseModuleWithCheckActionContext;
        import quickbite.lang: Value;

        const result = backend.runTestResults(
            parseModuleWithCheckActionContext(
                session.loadedModuleSource,
                importPaths,
            )
                .module_,
        );
        const failureDiagnostic = testFailureDiagnostics(result.cases);
        if (failureDiagnostic !is null)
            throw new Exception(failureDiagnostic);

        return ReplResult(Value.void_);
    }

    private imported!"quickbite.lang".Value evalReplCell(
        imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        import quickbite.frontend.repl: ReplCellKind;
        import quickbite.lang: Value;

        const value = backend.evalRepl(cell.evalCell);
        if (cell.kind == ReplCellKind.typeExpression)
            return Value.typeName(value.asCharArrayString);

        return value;
    }
}

private struct ReplResult {
    public imported!"quickbite.lang".Value value;
    public ReplDisplay display;

    public string toString() const @safe pure {
        final switch (display) with (ReplDisplay) {
            case value:
                return this.value.toString;
            case string:
                return `"` ~ this.value.asCharArrayString ~ `"`;
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

private bool failed(
    ref const(imported!"quickbite.backends".TestCaseResult) testCase,
) @safe pure nothrow {
    import quickbite.backends: TestOutcome;

    return testCase.outcome == TestOutcome.failed;
}

private string testFailureDiagnostic(
    ref const(imported!"quickbite.backends".TestCaseResult) testCase,
) @safe pure {
    return "unittest at " ~ testCase.location ~ " failed: " ~
        testCase.message;
}

private string testFailureDiagnostics(
    const(imported!"quickbite.backends".TestCaseResult)[] testCases,
) @safe pure {
    import std.array: join;

    string[] diagnostics;
    foreach (ref testCase; testCases)
        if (testCase.failed)
            diagnostics ~= testFailureDiagnostic(testCase);

    return diagnostics.join("\n");
}

private bool functionReturnsString(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: TY;

    auto returnType = function_.type is null ? null : function_.type.nextOf;
    if (returnType is null)
        return false;

    auto array = returnType.toBasetype.isTypeDArray;
    if (array is null || array.nextOf is null)
        return false;

    switch (array.nextOf.toBasetype.ty) with (TY) {
        case Tchar:
        case Twchar:
        case Tdchar:
            return true;
        default:
            return false;
    }
}

public string[] runReplLoop(
    imported!"quickbite.backends".Backend backend,
    in string[] inputAtoms,
) {
    import quickbite.lang: Value;

    string[] output;
    auto repl = Repl(backend);
    foreach (input; inputAtoms) {
        if (input == ":q" || input == ":quit")
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

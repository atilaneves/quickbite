module quickbite.repl;

private:

public struct Repl {
    private imported!"quickbite.frontend.repl".ReplSession session;
    private imported!"quickbite.backends".Backend backend;
    private string pendingInput;

    public this(imported!"quickbite.backends".Backend backend) {
        this.backend = backend;
    }

    public imported!"quickbite.lang".Value submit(in string input) {
        return submitResult(input).value;
    }

    public string submitDisplay(in string input) {
        import quickbite.lang: Value;

        const result = submitResult(input);
        return result.value == Value.void_ ? null : result.toString;
    }

    private ReplResult submitResult(in string input) {
        import quickbite.frontend.repl: ReplCellKind;
        import quickbite.lang: Value;

        if (input == ":t")
            return runLoadedTests;

        const source = pendingInput.length == 0 ?
            input :
            pendingInput ~ "\n" ~ input;
        const cell = session.submit(source);
        if (cell.kind == ReplCellKind.incomplete) {
            pendingInput = source;
            return ReplResult(Value.void_);
        }

        const value = evalReplCell(cell);
        session.accept(cell);
        pendingInput = null;
        return ReplResult(value, replDisplay(cell));
    }

    private ReplResult runLoadedTests() {
        import quickbite.frontend.compiler: parseModule;
        import quickbite.lang: Value;

        backend.runParsedTests(parseModule(session.loadedModuleSource).module_);
        return ReplResult(Value.void_);
    }

    private imported!"quickbite.lang".Value evalReplCell(
        in imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        try
            return backend.evalRepl(cell);
        catch (Exception exception)
            throw new Exception(userDiagnostic(exception.msg));
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
    in imported!"quickbite.frontend.repl".ReplCell cell,
) {
    import quickbite.frontend.repl: ReplCellKind;

    return cell.kind == ReplCellKind.expression && replFunctionReturnsString(cell.source) ?
        ReplDisplay.string :
        ReplDisplay.value;
}

private bool replFunctionReturnsString(in string source) {
    import quickbite.frontend.compiler: parseModule;

    return functionReturnsString(functionDeclaration(parseModule(source).module_));
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

    return array.nextOf.toBasetype.ty == TY.Tchar;
}

private imported!"dmd.func".FuncDeclaration functionDeclaration(
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ !is null && function_.ident.toString == "f")
                return function_;
        }
    }

    throw new Exception("Missing REPL function.");
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

        const display = repl.submitDisplay(input);
        if (display !is null)
            output ~= display;
    }

    return output;
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
        lineStart = lineEnd == diagnostic.length ? diagnostic.length : lineEnd + 1;
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

module quickbite.repl;

private:

public struct Repl {
    private imported!"quickbite.frontend.repl".ReplSession session;
    private imported!"quickbite.backend".Backend backend;
    private string pendingInput;

    public this(imported!"quickbite.backend".Backend backend) {
        this.backend = backend;
    }

    public imported!"quickbite.lang".Value submit(in string input) {
        import quickbite.frontend.repl: ReplCellKind;
        import quickbite.lang: Value;

        const source = pendingInput.length == 0 ?
            input :
            pendingInput ~ "\n" ~ input;
        const cell = session.submit(source);
        if (cell.kind == ReplCellKind.incomplete) {
            pendingInput = source;
            return Value.void_;
        }

        const value = evalReplCell(cell);
        session.accept(cell);
        pendingInput = null;
        return value;
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

public string[] runReplLoop(
    imported!"quickbite.backend".Backend backend,
    in string[] inputAtoms,
) {
    import quickbite.lang: Value;

    string[] output;
    auto repl = Repl(backend);
    foreach (input; inputAtoms) {
        if (input == ":q" || input == ":quit")
            break;

        const value = repl.submit(input);
        if (value != Value.void_)
            output ~= value.toString;
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

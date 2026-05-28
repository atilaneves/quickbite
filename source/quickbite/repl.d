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

        const value = backend.evalRepl(cell);
        session.accept(cell);
        pendingInput = null;
        return value;
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

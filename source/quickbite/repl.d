module quickbite.repl;

private:

public struct Repl {
    private imported!"quickbite.frontend.repl".ReplSession session;
    private imported!"quickbite.backend".Backend backend;

    public this(imported!"quickbite.backend".Backend backend) {
        this.backend = backend;
    }

    public imported!"quickbite.lang".Value submit(in string input) {
        const cell = session.submit(input);
        const value = backend.evalRepl(cell);
        session.accept(cell);
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

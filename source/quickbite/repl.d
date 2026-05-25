module quickbite.repl;

private:

public string[] runReplLoop(
    imported!"quickbite.executor".Executor executor,
    in string[] inputAtoms,
) {
    string[] output;
    foreach (input; inputAtoms) {
        if (input == ":q" || input == ":quit")
            break;

        output ~= executor.eval(input).toString;
    }

    return output;
}

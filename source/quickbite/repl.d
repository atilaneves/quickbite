module quickbite.repl;

private:

public string[] runReplLoop(
    imported!"quickbite.executor".Executor executor,
    in string[] inputAtoms,
) {
    string[] output;
    string transcript;
    foreach (input; inputAtoms) {
        if (input == ":q" || input == ":quit")
            break;

        if (input.isNoDisplayCell) {
            executor.eval(transcript ~ input ~ "\n0");
            transcript ~= input ~ "\n";
            continue;
        }

        output ~= executor.eval(transcript ~ input).toString;
    }

    return output;
}

private bool isNoDisplayCell(in string input) {
    import std.string: stripRight;

    return input.stripRight.endsWithSemicolon;
}

private bool endsWithSemicolon(in string input) {
    return input.length != 0 && input[$ - 1] == ';';
}

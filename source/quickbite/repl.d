module quickbite.repl;

private:

public string[] runReplLoop(
    imported!"quickbite.executor".Executor executor,
    in string[] inputAtoms,
) {
    import quickbite.frontend.repl: evalReplCell;
    import quickbite.executor: Repl;
    import std.conv: text;

    string[] output;
    string transcript;
    uint valueCellCount;
    foreach (input; inputAtoms) {
        if (input == ":q" || input == ":quit")
            break;

        const result = evalReplCell(executor, transcript, input);
        with (Repl.CellStatus) {
            final switch (result.status) {
                case incomplete:
                    break;
                case void_:
                    transcript ~= input ~ "\n";
                    break;
                case value:
                    transcript ~= text(
                        "auto __quickbite_repl_value_",
                        valueCellCount++,
                        " = ",
                        input,
                        ";\n",
                    );
                    output ~= result.value.toString;
                    break;
            }
        }
    }

    return output;
}

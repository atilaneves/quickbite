module repl.main;

private:

public int main(string[] args) {
    import quickbite: ExecutorBackend, executor;
    import quickbite.executor: Repl;
    import std.conv: text;
    import std.stdio: stdin, writeln;

    auto active = executor(ExecutorBackend.ir);

    if (args.length == 3 && args[1] == "-c") {
        active.evalReplCell("", args[2]);
        return 0;
    }

    writeln("Quickbite REPL");
    writePrompt;

    string transcript;
    uint valueCellCount;
    foreach (line; stdin.byLineCopy) {
        if (line == ":q" || line == ":quit")
            break;

        try {
            const result = active.evalReplCell(transcript, line);
            with (Repl.CellStatus) {
                final switch (result.status) {
                    case incomplete:
                        break;
                    case void_:
                        transcript ~= line ~ "\n";
                        break;
                    case value:
                        transcript ~= text(
                            "auto __quickbite_repl_value_",
                            valueCellCount++,
                            " = ",
                            line,
                            ";\n",
                        );
                        writeln(result.value.toString);
                        break;
                }
            }
        } catch (Exception e) {
            writeln(e.msg);
        } catch (Error e) {
            writeln(e.msg);
            return 1;
        }
        writePrompt;
    }

    return 0;
}

private void writePrompt() {
    import std.stdio: stdout, write;

    write("> ");
    stdout.flush;
}

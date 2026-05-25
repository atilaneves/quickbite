module repl.main;

private:

public int main(string[] args) {
    import quickbite: ExecutorBackend, executor;
    import std.stdio: stdin, writeln;

    auto active = executor(ExecutorBackend.ir);

    if (args.length == 3 && args[1] == "-c") {
        active.eval(args[2]);
        return 0;
    }

    writeln("Quickbite REPL");
    writePrompt;

    foreach (line; stdin.byLineCopy) {
        if (line == ":q" || line == ":quit")
            break;

        try {
            writeln(active.eval(line).toString);
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

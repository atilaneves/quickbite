module repl.main;

private:

public int main() {
    import quickbite: ExecutorBackend, executor;
    import quickbite.repl: runReplLoop;
    import std.stdio: stdin, writeln;

    auto active = executor(ExecutorBackend.ir);
    string[] inputAtoms;

    foreach (line; stdin.byLineCopy) {
        inputAtoms ~= line;
    }

    foreach (line; runReplLoop(active, inputAtoms))
        writeln(line);

    return 0;
}

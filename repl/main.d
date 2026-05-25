module repl.main;

private:

public int main() {
    import quickbite: ExecutorBackend, executor;
    import std.stdio: stdin, writeln;

    auto active = executor(ExecutorBackend.ir);

    foreach (line; stdin.byLineCopy) {
        if (line == ":q" || line == ":quit")
            break;

        writeln(active.eval(line));
    }

    return 0;
}

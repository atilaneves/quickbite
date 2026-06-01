module repl.main;

private:

public int main(string[] args) {
    import quickbite.backends.ctfe: Ctfe;
    import quickbite.repl: Repl;
    import quickbite.repl_cli: parseReplArgs;
    import std.stdio: stderr, stdin, writeln;

    const options = parseReplArgs(args);
    if (options.status != 0) {
        stderr.writeln(options.diagnostic);
        return options.status;
    }

    if (options.options.showHelp) {
        writeln(options.diagnostic);
        return 0;
    }

    auto repl = Repl(new Ctfe);

    if (options.options.hasCommand) {
        repl.submit(options.options.command);
        return 0;
    }

    if (options.options.hasFile) {
        import std.file: readText;
        repl.submit(readText(options.options.file));
        return 0;
    }

    writeln("Quickbite REPL");
    if (stdinIsTerminal)
        return runInteractiveRepl(repl);

    foreach (line; stdin.byLineCopy) {
        if (line == ":q" || line == ":quit")
            break;

        if (!submit(repl, line))
            return 1;
    }

    return 0;
}

private bool stdinIsTerminal() {
    import core.sys.posix.unistd: isatty;
    import std.stdio: stdin;

    return stdin.isOpen && isatty(stdin.fileno) != 0;
}

private int runInteractiveRepl(ref imported!"quickbite.repl".Repl repl) {
    import gnu.readline: readline, rl_free;
    import std.string: fromStringz;

    while (true) {
        char* rawLine = readline("> ");
        if (rawLine is null)
            return 0;

        scope (exit)
            rl_free(rawLine);

        const line = rawLine.fromStringz.idup;
        if (line == ":q" || line == ":quit")
            return 0;

        if (line.length != 0)
            add_history(rawLine);

        if (!submit(repl, line))
            return 1;
    }
}

extern (C) private void add_history(const(char)* line);

private bool submit(ref imported!"quickbite.repl".Repl repl, in string line) {
    import quickbite.lang: Value;
    import std.stdio: writeln;

    try {
        const value = repl.submit(line);
        if (value != Value.void_)
            writeln(value.toString);
    } catch (Exception e) {
        writeln(e.msg);
    } catch (Error e) {
        writeln(e.msg);
        return false;
    }

    return true;
}

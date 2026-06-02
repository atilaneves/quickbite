module repl.main;

private:

public int main(string[] args) {
    import quickbite.backends.ctfe: Ctfe;
    import quickbite.repl: Repl;
    import quickbite.repl_cli: parseReplArgs;
    import std.stdio: stderr, stdin, writeln;
    import std.string: strip;

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

    if (options.options.hasFile) {
        import std.file: readText;

        foreach (file; options.options.files)
            repl.loadModuleFile(file, readText(file));
    }

    if (options.options.hasCommand)
        return submit(repl, options.options.command, FailureMode.exit) ? 0 : 1;

    if (options.options.hasFile && !options.options.liveAfterFiles)
        return 0;

    if (stdinIsTerminal) {
        writeln("Quickbite REPL");
        return runInteractiveRepl(repl);
    }

    foreach (line; stdin.byLineCopy) {
        if (line == ":q" || line == ":quit")
            break;

        if (line.strip.length == 0)
            continue;

        if (!submit(repl, line, FailureMode.exit))
            return 1;
    }

    return 0;
}

private bool stdinIsTerminal() {
    import core.sys.posix.unistd: isatty;
    import std.stdio: stdin;

    return stdin.isOpen && isatty(stdin.fileno) != 0;
}

private bool stdoutIsTerminal() {
    import core.sys.posix.unistd: isatty;
    import std.stdio: stdout;

    return stdout.isOpen && isatty(stdout.fileno) != 0;
}

private int runInteractiveRepl(ref imported!"quickbite.repl".Repl repl) {
    import gnu.readline: readline, rl_free;
    import std.string: fromStringz;
    import std.string: strip;

    while (true) {
        char* rawLine = readline("> ");
        if (rawLine is null)
            return 0;

        scope (exit)
            rl_free(rawLine);

        const line = rawLine.fromStringz.idup;
        if (line == ":q" || line == ":quit")
            return 0;

        if (line.strip.length != 0)
            add_history(rawLine);

        if (!submit(repl, line, FailureMode.continue_))
            return 1;
    }
}

extern (C) private void add_history(const(char)* line);

private enum FailureMode {
    exit,
    continue_,
}

private bool submit(
    ref imported!"quickbite.repl".Repl repl,
    in string line,
    in FailureMode failureMode,
) {
    import std.stdio: writeln;

    try {
        const display = repl.submitDisplay(line);
        if (display !is null)
            writeln(display);
    } catch (Exception e) {
        writeln(errorDiagnostic(e.msg));
        return failureMode == FailureMode.continue_;
    } catch (Error e) {
        writeln(errorDiagnostic(e.msg));
        return false;
    }

    return true;
}

private string errorDiagnostic(in string diagnostic) {
    return errorLabel ~ " " ~ diagnostic;
}

private string errorLabel() {
    import colorize: color, fg;

    return stdoutIsTerminal ? "Error:".color(fg.red) : "Error:";
}

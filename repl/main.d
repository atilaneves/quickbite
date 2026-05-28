module repl.main;

private:

public int main(string[] args) {
    import quickbite.backends.ctfe: Ctfe;
    import quickbite.lang: Value;
    import quickbite.repl: Repl;
    import quickbite.repl_cli: parseReplArgs;
    import std.stdio: stderr, stdin, writeln;

    const options = parseReplArgs(args);
    if (options.status != 0) {
        stderr.writeln(options.diagnostic);
        return options.status;
    }

    auto repl = Repl(new Ctfe);

    if (options.options.hasCommand) {
        repl.submit(options.options.command);
        return 0;
    }

    writeln("Quickbite REPL");
    writePrompt;

    foreach (line; stdin.byLineCopy) {
        if (line == ":q" || line == ":quit")
            break;

        try {
            const value = repl.submit(line);
            if (value != Value.void_)
                writeln(value.toString);
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

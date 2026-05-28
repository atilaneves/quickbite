module quickbite.repl_cli;

private:

public enum ReplBackendName {
    ctfe,
}

public struct ReplOptions {
    public ReplBackendName backend;
    public bool hasCommand;
    public string command;
}

public struct ReplCliResult {
    public int status;
    public string diagnostic;
    public ReplOptions options;
}

public ReplCliResult parseReplArgs(in string[] args) @safe pure {
    ReplCliResult result;
    result.options.backend = ReplBackendName.ctfe;

    size_t index = 1;
    while (index < args.length) {
        const arg = args[index];
        if (arg == "-c") {
            if (index + 1 >= args.length)
                return failure("missing command after -c");

            result.options.hasCommand = true;
            result.options.command = args[index + 1];
            index += 2;
        } else if (arg == "--backend" || arg == "-b") {
            if (index + 1 >= args.length)
                return failure("missing backend after " ~ arg);

            if (args[index + 1] != "ctfe")
                return failure("unknown backend: " ~ args[index + 1]);

            result.options.backend = ReplBackendName.ctfe;
            index += 2;
        } else {
            return failure("unknown option: " ~ arg);
        }
    }

    return result;
}

private ReplCliResult failure(in string diagnostic) @safe pure {
    return ReplCliResult(1, diagnostic);
}

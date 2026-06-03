module quickbite.repl_cli;

private:

public enum ReplBackendName {
    ctfe,
}

public struct ReplOptions {
    public ReplBackendName backend;
    public bool hasCommand;
    public string command;
    public string[] importPaths;
    public bool showHelp;
    public bool hasFile;
    public string file;
    public string[] files;
    public bool liveAfterFiles;
}

public struct ReplCliResult {
    public int status;
    public string diagnostic;
    public ReplOptions options;
}

public ReplCliResult parseReplArgs(string[] args) {
    import std.getopt;

    ReplCliResult result;
    result.options.backend = ReplBackendName.ctfe;
    string backendName = "ctfe";

    GetoptResult helpInfo;
    try {
        helpInfo = getopt(
            args,
            "c", "Run a D expression.", (string _, string val) {
                result.options.hasCommand = true;
                result.options.command = val;
            },
            "I", "Add import path.", (string _, string val) {
                result.options.importPaths ~= val;
            },
            "b|backend", "Select backend (default: ctfe).", &backendName,
            "l", "Start the REPL after loading file arguments.",
                &result.options.liveAfterFiles,
        );
    } catch (GetOptException e) {
        return ReplCliResult(1, e.msg);
    }

    if (helpInfo.helpWanted) {
        result.options.showHelp = true;
        result.diagnostic = helpText;
        return result;
    }

    if (backendName != "ctfe")
        return ReplCliResult(1, "unknown backend: " ~ backendName);

    if (args.length > 1) {
        result.options.hasFile = true;
        result.options.file = args[1];
        result.options.files = args[1 .. $];
    }

    return result;
}

private enum helpText =
    "Usage: repl [options] [file.d ...]\n" ~
    "\n" ~
    "Options:\n" ~
    "  -c <command>          Run a D expression\n" ~
    "  -I <path>             Add import path\n" ~
    "  -b, --backend <name>  Select backend (default: ctfe)\n" ~
    "  -l                   Start the REPL after loading file arguments\n" ~
    "  -h, --help            Show this help\n";

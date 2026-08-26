module quickbite.repl.cli;

private:

public enum ReplBackendName {
    ctfe,
    bytecode,
    ir,
    interpreter,
    systemLinker,
    llvmJit,
}

public struct ReplOptions {
    public ReplBackendName backend;
    public bool hasCommand;
    public string command;
    public string[] importPaths;
    public string dubPkg;
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
            "dub", "Add a dub package's import paths (transitive).",
                &result.options.dubPkg,
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

    if (!parseBackendName(backendName, result.options.backend))
        return ReplCliResult(
            1,
            "unknown backend: " ~ backendName ~ "\n" ~
                "valid backends: " ~ validBackendNames,
        );

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
    "  --dub <name>          Add a dub package's import paths (transitive)\n" ~
    "  -b, --backend <name>  Select backend (default: ctfe)\n" ~
    "                        valid: " ~ validBackendNames ~ "\n" ~
    "  -l                   Start the REPL after loading file arguments\n" ~
    "  -h, --help            Show this help\n";

private enum validBackendNames =
    "ctfe, bytecode, ir, interpreter, system-linker, llvmjit";

private bool parseBackendName(
    in string input,
    out ReplBackendName backend,
) @safe pure nothrow {
    switch (input) with (ReplBackendName) {
        case "ctfe":
            backend = ctfe;
            return true;
        case "bytecode":
            backend = bytecode;
            return true;
        case "ir":
            backend = ir;
            return true;
        case "interpreter":
            backend = interpreter;
            return true;
        case "system-linker":
            backend = systemLinker;
            return true;
        case "llvmjit":
            backend = llvmJit;
            return true;
        default:
            return false;
    }
}

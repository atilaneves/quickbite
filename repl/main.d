module repl.main;

private:

import std.datetime.stopwatch: Duration;

public int main(string[] args) {
    import quickbite.frontend.compiler: DubMode, initialize;
    import quickbite.repl: Repl;
    import quickbite.repl.cli: parseReplArgs;
    import std.stdio: stderr, stdin, writeln;

    // The REPL evaluates single snippets, so it is the single-snippet world.
    initialize(DubMode.no);

    const options = parseReplArgs(args);
    if (options.status != 0) {
        stderr.writeln(options.diagnostic);
        return options.status;
    }

    if (options.options.showHelp) {
        writeln(options.diagnostic);
        return 0;
    }

    auto importPaths = options.options.importPaths.dup;
    if (options.options.dubPkg.length > 0) {
        import quickbite.dub: dubImportPaths;
        try
            importPaths ~= dubImportPaths(options.options.dubPkg);
        catch (Exception e) {
            stderr.writeln(errorDiagnostic(e.msg));
            return 1;
        }
    }

    auto repl = Repl(
        newReplBackend(options.options.backend),
        importPaths,
    );

    if (options.options.hasFile) {
        try {
            foreach (file; options.options.files)
                repl.loadModuleFile(file);
        } catch (Exception e) {
            writeln(errorDiagnostic(e.msg));
            return 1;
        }
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
        if (repl.shouldQuit(line))
            break;

        if (line.ignoredReplInput)
            continue;

        if (!submit(repl, line, FailureMode.continue_))
            return 1;
    }

    return 0;
}

private imported!"quickbite.backends".Backend newReplBackend(
    imported!"quickbite.repl.cli".ReplBackendName backend,
) {
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.backends.ctfe: Ctfe;
    import quickbite.backends.interpreter: Interpreter;
    import quickbite.backends.ir: IR;
    import quickbite.backends.native: LLVMJit, SystemLinker;
    import quickbite.repl.cli: ReplBackendName;

    final switch (backend) with (ReplBackendName) {
        case ctfe:
            return new Ctfe;
        case bytecode:
            return new Bytecode;
        case ir:
            return new IR;
        case interpreter:
            return new Interpreter;
        case systemLinker:
            return new SystemLinker;
        case llvmJit:
            return new LLVMJit;
    }
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
    import std.string: fromStringz, toStringz;

    const historyPath = historyFilePath;
    loadHistory(historyPath);
    scope (exit)
        saveHistory(historyPath);

    Duration lastElapsed;
    while (true) {
        const prompt = replPrompt(lastElapsed);
        auto rawLine = readline(prompt.toStringz);
        if (rawLine is null)
            return 0;

        scope (exit)
            rl_free(rawLine);

        const line = rawLine.fromStringz.idup;
        if (repl.shouldQuit(line))
            return 0;

        if (line.ignoredReplInput)
            continue;

        add_history(rawLine);

        const result = submitTimed(repl, line, FailureMode.continue_);
        lastElapsed = result.elapsed;
        if (!result.keepGoing)
            return 1;
    }
}

extern (C) private void add_history(const(char)* line);

// Cap on both the in-memory history list and the on-disk file.
private enum maxHistoryEntries = 1000;

// Where REPL history lives across sessions. QUICKBITE_HISTORY overrides it
// (handy for tests); otherwise it follows the XDG state directory.
private string historyFilePath() {
    import std.path: buildPath;
    import std.process: environment;

    const override_ = environment.get("QUICKBITE_HISTORY", "");
    if (override_.length != 0)
        return override_;

    const stateHome = environment.get("XDG_STATE_HOME", "");
    const base = stateHome.length != 0
        ? stateHome
        : buildPath(environment.get("HOME", ""), ".local", "state");
    return buildPath(base, "quickbite", "history");
}

private void loadHistory(in string path) {
    import std.string: toStringz;

    using_history;
    stifle_history(maxHistoryEntries);
    read_history(path.toStringz);
}

private void saveHistory(in string path) {
    import std.file: mkdirRecurse;
    import std.path: dirName;
    import std.string: toStringz;

    try
        mkdirRecurse(path.dirName);
    catch (Exception)
        return;

    const cPath = path.toStringz;
    write_history(cPath);
    history_truncate_file(cPath, maxHistoryEntries);
}

extern (C) private void using_history();
extern (C) private void stifle_history(int max);
extern (C) private int read_history(const(char)* filename);
extern (C) private int write_history(const(char)* filename);
extern (C) private int history_truncate_file(const(char)* filename, int lines);

private bool ignoredReplInput(in string input) @safe pure {
    import std.string: startsWith, strip;

    const stripped = input.strip;
    return stripped.length == 0 || stripped.startsWith("//");
}

private enum FailureMode {
    exit,
    continue_,
}

private bool submit(
    ref imported!"quickbite.repl".Repl repl,
    in string line,
    in FailureMode failureMode,
) {
    return submitTimed(repl, line, failureMode).keepGoing;
}

private struct SubmitResult {
    public bool keepGoing;
    public Duration elapsed;
}

private SubmitResult submitTimed(
    ref imported!"quickbite.repl".Repl repl,
    in string line,
    in FailureMode failureMode,
) {
    import std.datetime.stopwatch: StopWatch;
    import std.stdio: writeln;

    StopWatch stopwatch;
    stopwatch.start;
    try {
        const display = repl.submitDisplay(line);
        if (display !is null)
            writeln(display);
    } catch (Exception e) {
        const elapsed = stopwatch.peek;
        writeln(errorDiagnostic(e.msg));
        return SubmitResult(failureMode == FailureMode.continue_, elapsed);
    } catch (Error e) {
        const elapsed = stopwatch.peek;
        writeln(errorDiagnostic(e.msg));
        return SubmitResult(false, elapsed);
    }

    return SubmitResult(true, stopwatch.peek);
}

private string replPrompt(in Duration elapsed) {
    import std.format: format;

    return "[%6.1f ms] > ".format(elapsed.total!"hnsecs" / 10_000.0);
}

private string errorDiagnostic(in string diagnostic) {
    return errorLabel ~ " " ~ diagnostic;
}

private string errorLabel() {
    import colorize: color, fg;

    return stdoutIsTerminal ? "Error:".color(fg.red) : "Error:";
}

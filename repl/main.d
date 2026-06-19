module repl.main;

private:

import std.datetime.stopwatch: Duration;

public int main(string[] args) {
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
    imported!"quickbite.repl_cli".ReplBackendName backend,
) {
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.backends.ctfe: Ctfe;
    import quickbite.backends.interpreter: Interpreter;
    import quickbite.backends.ir: IR;
    import quickbite.backends.native: LLVMJit, SystemLinker;
    import quickbite.repl_cli: ReplBackendName;

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

module ut.backends.repl;


import ut.backends;


@("repl.loop.evaluatesExpressionCellsUntilQuit")
unittest {
    import quickbite.repl: runReplLoop;

    foreach (backend; matureExecutorBackends) {
        const output = runReplLoop(
            executor(backend),
            ["1", "2", ":q"],
        );

        output.should == ["1", "2"];
    }
}

@("repl.loop.declarationCellsPersistWithoutDisplay")
unittest {
    import quickbite.repl: runReplLoop;

    foreach (backend; matureExecutorBackends) {
        const output = runReplLoop(
            executor(backend),
            ["int x;", "x", ":q"],
        );

        output.should == ["0"];
    }
}

@("repl.loop.expressionSideEffectsPersist")
unittest {
    import quickbite.repl: runReplLoop;

    foreach (backend; matureExecutorBackends) {
        const output = runReplLoop(
            executor(backend),
            ["int x;", "x++", "x", ":q"],
        );

        output.should == ["0", "1"];
    }
}

@("repl.binary.cEvaluatesExpressionCellSilently")
unittest {
    import std.process: execute;

    const result = execute([replExecutable, "-c", "1 + 2"]);
    result.status.should == 0;
    result.output.should == "";
}

@("repl.binary.continuesAfterFrontendDiagnostic")
unittest {
    import std.algorithm.searching: canFind;
    import std.process: Redirect, pipeProcess, wait;

    auto repl = pipeProcess(
        [replExecutable],
        Redirect.stdin | Redirect.stdout,
    );

    repl.stdin.write("int x\n1\n:q\n");
    repl.stdin.close;

    string output;
    foreach (line; repl.stdout.byLine)
        output ~= line.idup ~ "\n";

    wait(repl.pid).should == 0;
    output.canFind(
        "semicolon needed to end declaration of `x` instead of `}`",
    ).should == true;
    output.canFind("> 1\n>").should == true;
}

private string replExecutable() {
    static bool built;
    if (!built) {
        import std.process: execute;

        const result = execute(["dub", "build", "-c", "repl"]);
        result.status.should == 0;
        built = true;
    }

    return "bin/repl";
}

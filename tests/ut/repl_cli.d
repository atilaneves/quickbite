module ut.repl_cli;


import ut;


private:

@("repl.cli.defaultBackendIsCtfe")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["repl"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.ctfe;
}

@("repl.cli.acceptsLongCtfeBackendOption")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["repl", "--backend", "ctfe"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.ctfe;
}

@("repl.cli.acceptsShortCtfeBackendOption")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["repl", "-b", "ctfe"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.ctfe;
}

@("repl.cli.rejectsUnknownBackend")
unittest {
    import quickbite.repl_cli: parseReplArgs;

    const result = parseReplArgs(["repl", "--backend", "ir"]);

    result.status.should == 1;
    result.diagnostic.should == "unknown backend: ir";
}

@("repl.cli.acceptsHelpFlag")
unittest {
    import quickbite.repl_cli: parseReplArgs;
    import std.algorithm: canFind;

    const result = parseReplArgs(["repl", "--help"]);

    result.status.should == 0;
    result.diagnostic.canFind("Usage").should == true;
}

@("repl.cli.helpDiagnosticDocumentsFlagNames")
unittest {
    import quickbite.repl_cli: parseReplArgs;
    import std.algorithm: canFind;

    const result = parseReplArgs(["repl", "--help"]);

    result.status.should == 0;
    result.diagnostic.canFind("-c").should == true;
}

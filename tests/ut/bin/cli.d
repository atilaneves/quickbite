module ut.bin.cli;


import ut;


private:

@("repl.cli.defaultBackendIsCtfe")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["qb"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.ctfe;
}

@("repl.cli.acceptsLongCtfeBackendOption")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["qb", "--backend", "ctfe"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.ctfe;
}

@("repl.cli.acceptsShortCtfeBackendOption")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["qb", "-b", "ctfe"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.ctfe;
}

@("repl.cli.acceptsSystemLinkerBackendOption")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["qb", "--backend", "system-linker"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.systemLinker;
}

@("repl.cli.acceptsLLVMJitBackendOption")
unittest {
    import quickbite.repl_cli: ReplBackendName, parseReplArgs;

    const result = parseReplArgs(["qb", "--backend", "llvmjit"]);

    result.status.should == 0;
    result.options.backend.should == ReplBackendName.llvmJit;
}

@("repl.cli.rejectsUnknownBackend")
unittest {
    import quickbite.repl_cli: parseReplArgs;

    const result = parseReplArgs(["qb", "--backend", "nonsense"]);

    result.status.should == 1;
    result.diagnostic.should ==
        "unknown backend: nonsense\n" ~
        "valid backends: ctfe, bytecode, ir, interpreter, " ~
        "system-linker, llvmjit";
}

@("repl.cli.unknownBackendDiagnosticListsValidBackends")
unittest {
    import quickbite.repl_cli: parseReplArgs;

    const result = parseReplArgs(["qb", "-b", "nonsense"]);

    result.status.should == 1;
    "unknown backend: nonsense".should.be in result.diagnostic;
    ("valid backends: ctfe, bytecode, ir, interpreter, system-linker, " ~
        "llvmjit").should.be in result.diagnostic;
}

@("repl.cli.acceptsHelpFlag")
unittest {
    import quickbite.repl_cli: parseReplArgs;

    const result = parseReplArgs(["repl", "--help"]);

    result.status.should == 0;
    "Usage".should.be in result.diagnostic;
}

@("repl.cli.helpDiagnosticDocumentsFlagNames")
unittest {
    import quickbite.repl_cli: parseReplArgs;

    const result = parseReplArgs(["repl", "--help"]);

    result.status.should == 0;
    "-c".should.be in result.diagnostic;
}

module ut.backends.repl;


import ut.backends;


private:

static foreach (backend; backends) {
    @("repl.backend.evaluatesExpressionCellsUntilQuit." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["1", "2", ":q"],
        );

        output.should == ["1: int", "2: int"];
    }

    @("repl.backend.declarationCellsPersistWithoutDisplay." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int x;", "x", ":q"],
        );

        output.should == ["0: int"];
    }

    @("repl.backend.expressionSideEffectsPersist." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int x;", "x++", "x", ":q"],
        );

        output.should == ["0: int", "1: int"];
    }

    @("repl.backend.statementsExecuteImmediately." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int x;", "++x;", "x", ":q"],
        );

        output.should == ["1: int"];
    }

    @("repl.backend.noDisplayCellsReturnVoid." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int x;").should == Value.void_;
        repl.submit("++x;").should == Value.void_;
        repl.submit("x").should == Value(1);
    }
}

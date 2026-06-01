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

    @("repl.backend.functionDeclarationsPersistWithoutSemicolon." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int twice(int i) { return i * 2; }", "twice(21)", ":q"],
        );

        output.should == ["42: int"];
    }

    @("repl.backend.multilineFunctionDeclarationsBufferUntilComplete." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "int thrice(int i) {",
                "return i * 3;",
                "}",
                "thrice(14)",
                ":q",
            ],
        );

        output.should == ["42: int"];
    }

    @("repl.backend.importDeclarationsPersistWithoutDisplay." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["import std.algorithm;", "min(3, 1)", ":q"],
        );

        output.should == ["1: int"];
    }

    @("repl.backend.displaysFiniteRangeResults." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "import std.algorithm;",
                "int[] xs = [1, 2, 3];",
                "xs.map!(x => x * 2)",
                ":q",
            ],
        );

        output.should == ["MapResult([1, 2, 3], null)"];
    }

    @("repl.backend.typeofCellsDisplayTypeName." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int i;", "typeof(i)", ":q"],
        );

        output.should == ["int"];
    }

    @("repl.backend.noDisplayCellsReturnVoid." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int x;").should == Value.void_;
        repl.submit("++x;").should == Value.void_;
        repl.submit("x").should == Value(1);
    }

    @("repl.backend.duplicateDeclarationsHideSyntheticNames." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int twice(int i) { return i; }");
        void duplicateDeclaration() {
            repl.submit("int twice(int i) { return i; }");
        }
        duplicateDeclaration.shouldThrow.msg.should ==
            "function `twice(int i)` conflicts with previous declaration at <repl>(1)";
    }

    @("repl.backend.functionCallMismatchShowsCandidateSignature." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int twice(int i) { return i * 2; }");
        void mismatch() {
            repl.submit(`twice("foo")`);
        }
        mismatch.shouldThrow.msg.should ==
            "function `twice` is not callable using argument types `(string)`\n" ~
            "Candidate: int twice(int i)";
    }

    @("repl.backend.functionCallMismatchShowsOverloadSignatures." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int twice(int i) { return i * 2; }");
        repl.submit("string twice(string value) { return value ~ value; }");
        void mismatch() {
            repl.submit("twice(1.5)");
        }
        mismatch.shouldThrow.msg.should ==
            "none of the overloads of `twice` are callable using argument types `(double)`\n" ~
            "Candidates:\n" ~
            "- int twice(int i)\n" ~
            "- string twice(string value)";
    }
}

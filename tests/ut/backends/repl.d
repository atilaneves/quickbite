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

    @("repl.backend.importStdExposesPhobosSymbols." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "import std;",
                "[1, 2, 3].map!(a => a * 2).array",
                ":q",
            ],
        );

        output.should == ["[2, 4, 6]"];
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

    @("repl.backend.displaysStringValues." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [`"hello"`, ":q"],
        );

        output.should == [`"hello"`];
    }

    @("repl.backend.noDisplayCellsReturnVoid." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int x;").should == Value.void_;
        repl.submit("++x;").should == Value.void_;
        repl.submit("x").should == Value(1);
    }

    @("repl.backend.runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int good = 41;").should == Value.void_;
        repl.submit("import core.stdc.stdlib;").should == Value.void_;
        void allocateAtCompileTime() {
            repl.submit("auto ptr = malloc(42);");
        }
        allocateAtCompileTime.shouldThrowWithMessage(
            "`malloc` cannot be interpreted at compile time, because it has no available source code",
        );
        repl.submit("good + 1").should == Value(42);
    }

    @("repl.backend.runtimeErrorsReportOneDiagnostic." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        void divideByZero() {
            repl.submit("1 / 0");
        }
        divideByZero.shouldThrow.msg.should == "divide by 0";

        void outOfBoundsIndex() {
            repl.submit("[1, 2, 3][10]");
        }
        outOfBoundsIndex.shouldThrow.msg.should ==
            "array index 10 is out of bounds `[1, 2, 3][0 .. 3]`";
    }

    @("repl.backend.expressionCtfeErrorsReportDiagnostics." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("auto arr = [1,2,3];").should == Value.void_;
        void outOfBoundsIndex() {
            repl.submit("arr[99]");
        }
        outOfBoundsIndex.shouldThrow.msg.should ==
            "array index 99 is out of bounds `[0..3]`";
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

    @("repl.backend.failedModuleNoDisplayCellsDoNotPoisonSession." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int twice(int i) { return i * 2; }").should == Value.void_;
        void duplicateDeclaration() {
            repl.submit("int twice(int i) { return i; }");
        }
        duplicateDeclaration.shouldThrow.msg.should ==
            "function `twice(int i)` conflicts with previous declaration at <repl>(1)";
        repl.submit("twice(21)").should == Value(42);
    }

    @("repl.backend.syntaxErrorsHideWrapperInternals." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        void syntaxError() {
            repl.submit("1 +");
        }
        syntaxError.shouldThrow.msg.should ==
            "expression expected, not `End of File`";
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

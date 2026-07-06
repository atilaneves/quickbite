module ut.bin.repl;


import ut.backends;
import quickbite.repl_prelude: __quickbiteFormat;


@("repl.formatter.rendersIntegerLiteralAtCompileTime")
@safe pure unittest {
    enum actual = __quickbiteFormat(42);

    actual.should == "42";
}

@("repl.formatter.rendersCharacterLiteralAtCompileTime")
@safe pure unittest {
    enum actual = __quickbiteFormat('a');

    actual.should == "'a'";
}

@("repl.formatter.rendersWideCharactersAsCharacterLiteralsAtCompileTime")
@safe pure unittest {
    __quickbiteFormat(cast(wchar) 'a').should == "'a'";
    __quickbiteFormat(cast(dchar) 'a').should == "'a'";
}

@("repl.formatter.rendersStringLiteralAtCompileTime")
@safe pure unittest {
    enum actual = __quickbiteFormat("quickbite");

    actual.should == `"quickbite"`;
}

@("repl.formatter.rendersWideStringLiteralSuffixesAtCompileTime")
@safe pure unittest {
    __quickbiteFormat("wide"w).should == `"wide"w`;
    __quickbiteFormat("wide"d).should == `"wide"d`;
}

@("repl.formatter.rendersWholeDoubleWithDecimalPointAtCompileTime")
@safe pure unittest {
    enum actual = __quickbiteFormat(3.0);

    actual.should == "3.0";
}

@("repl.formatter.rendersScalarLiteralSuffixesAtCompileTime")
@safe pure unittest {
    __quickbiteFormat(3u).should == "3u";
    __quickbiteFormat(3L).should == "3L";
    __quickbiteFormat(3UL).should == "3UL";
    __quickbiteFormat(3.0f).should == "3.0f";
    __quickbiteFormat(3.0L).should == "3.0L";
}

@("repl.formatter.rendersArrayElementsWithLiteralSuffixesAtCompileTime")
@safe pure unittest {
    __quickbiteFormat([1, 2]).should == "[1, 2]";
    __quickbiteFormat([1u, 2u]).should == "[1u, 2u]";
    __quickbiteFormat([1L, 2L]).should == "[1L, 2L]";
    __quickbiteFormat([1.0f, 2.0f]).should == "[1.0f, 2.0f]";
    __quickbiteFormat(["a"w, "b"w]).should == `["a"w, "b"w]`;
}

@("repl.frontend.typeofExpressionWithTrailingTokensIsNotTypeCell")
unittest {
    import quickbite.frontend.repl: ReplCellKind, ReplSession;

    auto session = ReplSession([]);

    session.submit("typeof(1) + 2").kind.should == ReplCellKind.expression;
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.localDeclarationsCanRebindNames." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "auto x = 41;",
                "x + 1",
                "auto x = 1;",
                "x + 1",
                ":q",
            ],
        );

        output.should == ["42", "2"];
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.localRebindingPreservesInterveningReferences." ~
        backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "auto x = 41;",
                "auto y = x + 1;",
                "auto x = 1;",
                "y",
                "x",
                ":q",
            ],
        );

        output.should == ["42", "1"];
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.evaluatesExpressionCellsUntilQuit." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["1", "2", ":q"],
        );

        output.should == ["1", "2"];
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.skipsCommentOnlyLines." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["// just a comment", "1 + 2", ":q"],
        );

        output.should == ["3"];
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.evaluatesStandaloneMixinExpression." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [`mixin("1 + 2")`, ":q"],
        );

        output.should == ["3"];
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.lastValueBindingDisplaysLatestExpressionValue." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["41 + 1", "it", "it", ":q"],
        );

        output.should == ["42", "42", "42"];
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.failedExpressionDoesNotAdvanceLastValueBinding." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("1").should == "1";
        void submitFailure() {
            repl.submit("unknownIdentifier");
        }
        submitFailure.shouldThrowWithMessage(
            "undefined identifier `unknownIdentifier`",
        );
        repl.submit("it").should == "1";
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    SystemLinker,
    BytecodeNewCore,
)) {
    @("repl.backend.declarationCellsPersistWithoutDisplay." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int x;", "x", ":q"],
        );

        output.should == ["0"];
    }
}

static foreach (backend; AliasSeq!(Interpreter)) {
    @("repl.backend.moduleLevelVariablesAreVisibleToFunctions." ~
        backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int counter;").should == "";
        repl.submit("int get() { return counter; }").should == "";
        repl.submit("counter = 5;").should == "";
        repl.submit("get()").should == "5";
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("repl.backend.moduleLevelVariablesRejectCtfeMutation." ~
        backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int counter;").should == "";
        repl.submit("int get() { return counter; }").should == "";
        void mutateCounter() {
            repl.submit("counter = 5;");
        }
        mutateCounter.shouldThrowWithMessage(
            "static variable `counter` cannot be read at compile time",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.expressionSideEffectsPersist." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int x;", "x++", "x", ":q"],
        );

        output.should == ["0", "1"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.statementsExecuteImmediately." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int x;", "++x;", "x", ":q"],
        );

        output.should == ["1"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.functionDeclarationsPersistWithoutSemicolon." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int twice(int i) { return i * 2; }", "twice(21)", ":q"],
        );

        output.should == ["42"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.replacesSameSignatureFunctionDeclarations." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "int answer() { return 41; }",
                "int answer() { return 42; }",
                "answer()",
                ":q",
            ],
        );

        output.should == ["42"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.preservesFunctionOverloads." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "int twice(int i) { return i * 2; }",
                "long twice(long value) { return value * 3; }",
                "twice(21)",
                "twice(14L)",
                ":q",
            ],
        );

        output.should == ["42", "42L"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.userDefinedFunctionDoesNotCollideWithWrapper." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int f() { return 41; }", "f() + 1", ":q"],
        );

        output.should == ["42"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.templateFunctionDeclarationsPersistWithoutDisplay." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "T identity(T)(T x) { return x; }",
                "identity(42)",
                ":q",
            ],
        );

        output.should == ["42"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
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

        output.should == ["42"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.multilineStructDeclarationsBufferUntilComplete." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct StructCell {",
                "int value;",
                "}",
                "StructCell(42).value",
                ":q",
            ],
        );

        output.should == ["42"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.failedBufferedDeclarationDoesNotPoisonSession." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int dup() {").should == "";
        repl.submit("return unknown;").should == "";
        void completeRejectedDeclaration() {
            repl.submit("}");
        }
        completeRejectedDeclaration.shouldThrowWithMessage(
            "undefined identifier `unknown`",
        );
        repl.submit("42").should == "42";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.commandsDoNotAbandonPendingInput." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int answer() {").should == "";
        void quitWhilePending() {
            repl.submit(":q");
        }
        quitWhilePending.shouldThrowWithMessage(
            "cannot run REPL command `:q` while input is pending",
        );
        repl.submit("return 42;").should == "";
        repl.submit("}").should == "";
        repl.submit("answer()").should == "42";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.importDeclarationsPersistWithoutDisplay." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["import std.algorithm;", "min(3, 1)", ":q"],
        );

        output.should == ["1"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

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

        output.should == ["MapResult([1, 2, 3])"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.displaysUndisplayablePlaceholderForFunctionLiterals." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["delegate int(){ return 42; }", ":q"],
        );

        output.should == ["<undisplayable>"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.displaysFilteredArrayResults." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "import std;",
                "iota(5).filter!(x => x % 2 == 0).array",
                ":q",
            ],
        );

        output.should == ["[0, 2, 4]"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.displaysNestedArrayResults." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["[[1, 2], [3, 4]]", ":q"],
        );

        output.should == ["[[1, 2], [3, 4]]"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.displaysStaticStringArrayResults." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [`string[2] xs = ["a", "b"];`, "xs", ":q"],
        );

        output.should == [`["a", "b"]`];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.displaysNestedEmptyStringValues." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [`string[] values = ["", "a"];`, "values", ":q"],
        );

        output.should == [`["", "a"]`];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.displaysWideStringValues." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [`"wide"w`, `"wide"d`, `"\U0001F600"d`, `""w`, `""d`, ":q"],
        );

        output.should == [
            `"wide"w`,
            `"wide"d`,
            `"` ~ "\U0001F600" ~ `"d`,
            `""w`,
            `""d`,
        ];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("repl.backend.displaysWideCharacterArrayValues." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                `[cast(wchar) 'a', cast(wchar) 'b']`,
                `[cast(dchar) 'a', cast(dchar) 'b']`,
                ":q",
            ],
        );

        output.should == [`"ab"w`, `"ab"d`];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.displaysAssocArrayResults." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["[1: 10, 2: 20]", ":q"],
        );

        output.should == ["[1:10, 2:20]"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.displaysEnumValues." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "enum E { a = 7, b = 8 }",
                "E.a",
                "[E.a, E.b]",
                "cast(int) E.a",
                ":q",
            ],
        );

        output.should == [
            "E.a",
            "[E.a, E.b]",
            "7",
        ];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.typeofCellsDisplayTypeName." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["int i;", "typeof(i)", ":q"],
        );

        output.should == ["int"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.typeAliasCellsDisplayTypeName." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "string",
                "alias MyInt = int;",
                "MyInt",
                "struct Widget { int value; }",
                "Widget",
                ":q",
            ],
        );

        output.should == ["string", "int", "Widget"];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.displaysStringValues." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [`"hello"`, ":q"],
        );

        output.should == [`"hello"`];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.specialTokenValuesHideWrapperInternals." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            ["__FILE__", "__FUNCTION__", "__MODULE__", ":q"],
        );

        output.should == [`"<repl>"`, `"<repl>"`, `"<repl>"`];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.numericScalarDisplayUsesDLiteralSuffixes." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "42",
                "cast(uint) 42",
                "42L",
                "42UL",
                "3.8",
                "3.8f",
                "cast(byte) 42",
                "cast(short) 42",
                "cast(ubyte) 42",
                "cast(ushort) 42",
                "cast(real) 3.8",
                ":q",
            ],
        );

        output.should == [
            "42",
            "42u",
            "42L",
            "42UL",
            "3.8",
            "3.8f",
            "42",
            "42",
            "42",
            "42",
            "3.8L",
        ];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {

    @("repl.backend.characterScalarDisplayCollapsesToCharLiteral." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "'a'",
                "cast(wchar) 'a'",
                "cast(dchar) 'a'",
                "'\U0001F600'",
                ":q",
            ],
        );

        output.should == [
            "'a'",
            "'a'",
            "'a'",
            "'\U0001F600'",
        ];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {

    @("repl.backend.wholeFloatingScalarDisplayKeepsDecimalPoint." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "3.0",
                "3.0f",
                "cast(real) 3.0",
                ":q",
            ],
        );

        output.should == [
            "3.0",
            "3.0f",
            "3.0L",
        ];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.noDisplayCellsReturnVoid." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int x;").should == "";
        repl.submit("++x;").should == "";
        repl.submit("x").should == "1";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.runLoadedUnittestBlocks." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("unittest { assert(2 + 2 == 4); }").should == "";
        repl.submit(":t").should == "";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.runLoadedTestsWithNothingLoadedReturnsVoid." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit(":t").should == "";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.loadedUnittestFailuresReportReplLocation." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("unittest { assert(1 == 2); }").should == "";
        void runTests() {
            repl.submit(":t");
        }
        runTests.shouldThrow.msg.should ==
            "unittest at <repl cell 1>(1) failed: 1 != 2";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.laterLoadedUnittestFailuresReportReplLocation." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("unittest { assert(2 == 2); }").should == "";
        repl.submit("int value() { return 41; }").should == "";
        repl.submit("unittest { assert(value() == 42); }").should == "";
        void runTests() {
            repl.submit(":t");
        }
        runTests.shouldThrow.msg.should ==
            "unittest at <repl cell 3>(1) failed: 41 != 42";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.runLoadedTestsReportsEveryFailedUnittest." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit(q{
            unittest {
                assert(1 == 2);
            }
        });
        repl.submit(q{
            unittest {
                assert(3 == 4);
            }
        });

        void runTests() {
            repl.submit(":t");
        }

        const message = runTests.shouldThrow.msg;
        "unittest at <repl cell 1>(2) failed: 1 != 2".should.be in message;
        "unittest at <repl cell 2>(2) failed: 3 != 4".should.be in message;
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.runLoadedFileUnittestBlocks." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.loadModuleSource("unittest { assert(2 + 2 == 4); }");
        repl.submit(":t").should == "";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.loadedSourceDoesNotAdvanceTypedReplLocations." ~
        backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.loadModuleSource("int loadedValue() { return 41; }\n");
        repl.submit("unittest { assert(1 == 2); }").should == "";
        void runTests() {
            repl.submit(":t");
        }
        runTests.shouldThrow.msg.should ==
            "unittest at <repl cell 1>(1) failed: 1 != 2";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.loadedFileUnittestFailuresReportFileLocation." ~
        backend.stringof)
    unittest {
        import quickbite.repl: Repl;
        import std.file: remove, tempDir, write;
        import std.path: buildPath;

        const filePath = buildPath(
            tempDir,
            "quickbite-repl-loaded-file-failure.d",
        );
        filePath.write(q{
            int loadedValue() {
                return 41;
            }

            unittest {
                assert(loadedValue() == 42);
            }
        });
        scope (exit) filePath.remove;

        auto repl = Repl(newBackend!backend);

        repl.loadModuleFile(filePath);
        void runTests() {
            repl.submit(":t");
        }
        runTests.shouldThrow.msg.should ==
            "unittest at " ~ filePath ~ "(6) failed: 41 != 42";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.loadModuleFileErrorsHideSyntheticNames." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;
        import std.algorithm.searching: canFind;
        import std.file: remove, tempDir, write;
        import std.path: buildPath;

        const filePath = buildPath(
            tempDir,
            "quickbite-repl-duplicate-load.d",
        );
        filePath.write(q{
            int answer() {
                return 42;
            }
        });
        scope (exit) filePath.remove;

        auto repl = Repl(newBackend!backend);

        repl.loadModuleFile(filePath);
        void duplicateLoad() {
            repl.loadModuleFile(filePath);
        }
        const message = duplicateLoad.shouldThrow.msg;
        message.canFind("snippet_").should == false;
        message.canFind("answer").should == true;
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {

    @("repl.backend.runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int good = 41;").should == "";
        repl.submit("import core.stdc.stdlib;").should == "";
        void allocateAtCompileTime() {
            repl.submit("auto ptr = malloc(42);");
        }
        allocateAtCompileTime.shouldThrowWithMessage(
            "`malloc` cannot be interpreted at compile time, because it has no available source code",
        );
        repl.submit("good + 1").should == "42";
    }
}

static foreach (backend; AliasSeq!(Interpreter)) {

    @("repl.backend.runtimeOnlyCellsUseResidentNativeCalls." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int good = 41;").should == "";
        repl.submit("import core.stdc.stdlib;").should == "";
        repl.submit("free(malloc(42));").should == "";
        repl.submit("good + 1").should == "42";
    }

    @("repl.backend.runtimeOnlyFileOpenReportsNativeBoundary." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("import std;");
        void openFile() {
            repl.submit(`auto f = File("/tmp/foo.txt", "w");`);
        }

        openFile.shouldThrow.msg.should ==
            "`fopen64` cannot be interpreted at compile time, because it has no available source code\n" ~
            "`malloc` cannot be interpreted at compile time, because it has no available source code";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.expressionCtfeErrorsReportDiagnostics." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("auto arr = [1,2,3];").should == "";
        void outOfBoundsIndex() {
            repl.submit("arr[99]");
        }
        outOfBoundsIndex.shouldThrow.msg.should ==
            "array index 99 is out of bounds `[0..3]`";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.duplicateDeclarationsHideSyntheticNames." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("struct Twice { }");
        void duplicateDeclaration() {
            repl.submit("struct Twice { }");
        }
        const message = duplicateDeclaration.shouldThrow.msg;
        "at <repl cell 1>(1)".should.be in message;
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.failedModuleNoDisplayCellsDoNotPoisonSession." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        repl.submit("int twice(int i) { return i * 2; }").should == "";
        void rejectedReplacement() {
            repl.submit("int twice(int i) { return unknown; }");
        }
        rejectedReplacement.shouldThrowWithMessage(
            "undefined identifier `unknown`",
        );
        repl.submit("twice(21)").should == "42";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

    @("repl.backend.diagnosticsHideSyntheticWrapperNames." ~ backend.stringof)
    unittest {
        import quickbite.repl: Repl;

        auto repl = Repl(newBackend!backend);

        void failWithFunctionName() {
            repl.submit(`assert(false, __FUNCTION__);`);
        }
        failWithFunctionName.shouldThrow.msg.should == "<repl>";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {

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

// Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.structValueRendersTypeNameAndFields." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct Point { int x; int y; }",
                "int a = 1;",
                "int b = 2;",
                "Point(a, b)",
                ":q",
            ],
        );

        output.should == ["Point(1, 2)"];
    }
}

// Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.arrayOfStructsRendersEachElement." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct Point { int x; int y; }",
                "int a = 1;",
                "int b = 2;",
                "[Point(a, b), Point(b, a)]",
                ":q",
            ],
        );

        output.should == ["[Point(1, 2), Point(2, 1)]"];
    }
}

// The Interpreter keeps the null field (`Callbacks(7, null)`) instead of
// omitting it; Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("repl.backend.nullFunctionPointerFieldIsOmitted." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct Callbacks { int id; void function() onDone; }",
                "int a = 7;",
                "Callbacks(a, null)",
                ":q",
            ],
        );

        output.should == ["Callbacks(7)"];
    }
}

// The Interpreter keeps the null field (`Handler(9, null)`) instead of
// omitting it; Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("repl.backend.nullDelegateFieldIsOmitted." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct Handler { int id; void delegate() onEvent; }",
                "int a = 9;",
                "Handler(a, null)",
                ":q",
            ],
        );

        output.should == ["Handler(9)"];
    }
}

// Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.nullClassFieldRendersAsNull." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct Node { int id; Object payload; }",
                "int a = 5;",
                "Node(a, null)",
                ":q",
            ],
        );

        output.should == ["Node(5, null)"];
    }
}

// Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.nullPointerFieldRendersAsNull." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct Link { int id; int* next; }",
                "int a = 4;",
                "Link(a, null)",
                ":q",
            ],
        );

        output.should == ["Link(4, null)"];
    }
}

// Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.nestedStructOmitsSyntheticContextField." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        // dmd synthesises a void* context field for the nested struct;
        // it must not appear in the rendered value.
        const output = runReplLoop(
            newBackend!backend,
            [
                "auto makeNested(int seed) { struct Inner { int v; int doubled() { return v * seed; } } Inner i; i.v = seed; return i; }",
                "int a = 3;",
                "makeNested(a)",
                ":q",
            ],
        );

        output.should == ["Inner(3)"];
    }
}

// Bytecode reports struct literals as an unsupported expression.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("repl.backend.assocArrayWithStructValuesRendersEntries." ~ backend.stringof)
    unittest {
        import quickbite.repl: runReplLoop;

        const output = runReplLoop(
            newBackend!backend,
            [
                "struct Point { int x; int y; }",
                "int a = 1;",
                "int b = 2;",
                "[a: Point(a, b)]",
                ":q",
            ],
        );

        output.should == ["[1:Point(1, 2)]"];
    }
}

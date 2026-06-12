module ut.backends.runner.ct.diagnostics;


import ut.backends;
import std.algorithm.searching: canFind;
import std.exception: collectExceptionMsg;


static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker)) {
    @("voidFunctionReturnsToCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            void foo() {}

            unittest {
                foo;
                // Keep this runtime-shaped so DMD does not constant-fold it
                // before the backend sees the equality expression.
                assert(one == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("intLessThanOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 < bound);
            }
        }).shouldThrowWithMessage("42 >= 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("intLessOrEqualOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 <= bound);
            }
        }).shouldThrowWithMessage("43 > 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("intGreaterThanOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 > bound);
            }
        }).shouldThrowWithMessage("42 <= 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("intGreaterOrEqualOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(41 >= bound);
            }
        }).shouldThrowWithMessage("41 < 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("intNotEqualOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(bound != 42);
            }
        }).shouldThrowWithMessage("42 == 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("ok." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("oops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("okFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                return 7;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("localIntReturnOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("voidFunctionOops." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                assert(0);
            }

            unittest {
                foo;
            }
        }).shouldThrowWithMessage("`assert(0)` failed");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, BytecodeNewCore, SystemLinker)) {
    @("functionParametersOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 3) == 42);
            }
        }).shouldThrowWithMessage("43 != 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, BytecodeNewCore, SystemLinker)) {
    @("tenFunctionParametersOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(
                int first,
                int second,
                int third,
                int fourth,
                int fifth,
                int sixth,
                int seventh,
                int eighth,
                int ninth,
                int tenth,
            ) {
                return first + second + third + fourth + fifth +
                    sixth + seventh + eighth + ninth + tenth;
            }

            unittest {
                assert(answer(1, 2, 3, 4, 5, 6, 7, 8, 9, 11) == 42);
            }
        }).shouldThrowWithMessage("56 != 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, BytecodeNewCore, SystemLinker)) {
    @("functionParameterOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("ifElseOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(2) == 42);
            }
        }).shouldThrowWithMessage("43 != 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("refParameterOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, BytecodeNewCore, SystemLinker)) {
    @("inFunctionParametersOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 3);
            }
        }).shouldThrowWithMessage("43 != 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("refSizeTParameterOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("explicitAssertMessageOverridesContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(1 == 2, "oops");
            }
        }).shouldThrowWithMessage("oops");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("literalFalseAssertionMatchesDmd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(false);
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("runtimeBoolAssertionContextMatchesDmd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool nope() {
                return false;
            }

            unittest {
                assert(nope());
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, BytecodeNewCore, SystemLinker)) {
    @("boolAssertionContextMatchesDmd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool a = true;
                assert(a == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, BytecodeNewCore, SystemLinker)) {
    @("charAssertionContextMatchesDmd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char a = 'a';
                assert(a == 'b');
            }
        }).shouldThrowWithMessage("'a' != 'b'");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker)) {
    @("dynamicAssertMessageMatchesDmd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                string msg = "oops";
                assert(false, msg);
            }
        }).shouldThrowWithMessage("oops");
    }
}

// SystemLinker deliberately excluded from the three null-class-dereference
// blocks below: a compiled null dereference is a real SIGSEGV that would kill
// the test runner (ai/plans/dmd-backend.md, slice 3).
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("nullClassMethodCallReportsDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Thing {
                int value() {
                    return 42;
                }
            }

            unittest {
                Thing thing;
                assert(thing.value == 42);
            }
        }).shouldThrowWithMessage(
            "function call through null class reference `null`");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("nullClassFieldReadReportsDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Thing {
                int value;
            }

            unittest {
                Thing thing;
                assert(thing.value == 42);
            }
        }).shouldThrowWithMessage(
            "class `thing` is `null` and cannot be dereferenced");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("typeidNullClassReferenceReportsDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Thing {}

            unittest {
                Thing thing;
                assert(typeid(thing) is typeid(Thing));
            }
        }).shouldThrowWithMessage(
            "null pointer dereference evaluating typeid. `thing` is `null`");
    }
}

// SystemLinker deliberately excluded: reading a void-initialized scalar is a
// CTFE-only diagnostic; compiled code just reads whatever is in the slot
// (ai/plans/dmd-backend.md, slice 3).
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("voidInitializedScalarReadReportsUninitialized." ~ backend.stringof)
    unittest {
        const message = collectExceptionMsg!Exception(
            runBackendSourceFixtureTests!backend(q{
                int answer() {
                    int value = void;
                    return value;
                }

                unittest {
                    assert(answer == 42);
                }
            }));

        message.canFind("cannot read uninitialized variable `").should == true;
        message.canFind(".answer.value` in ctfe").should == true;
    }
}

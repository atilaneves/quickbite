module ut.backends.runner.ct.diagnostics;


import ut.backends;
import std.algorithm.searching: canFind;
import std.exception: collectExceptionMsg;


@("assignmentThroughRefReturningCall.Interpreter")
@Tags(Interpreter.stringof)
unittest {
    runBackendSourceFixtureTests!Interpreter(q{
        unittest {
            import core.stdc.stdlib: realloc, free;

            auto ptr = cast(ubyte*) realloc(null, 8);
            scope(exit) free(ptr);
            assert(ptr !is null);

            struct Box {
                int value;

                ref int slot() {
                    return value;
                }
            }

            Box box;
            box.slot() = 42;
            assert(box.value == 42);
        }
    });
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, IR)) {
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

// Compiled `assert(0)` in a non-unittest function raises the plain _d_assert
// message "Assertion failure" (checkaction=context adds no operands for a
// literal condition); "`assert(0)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(Bytecode, SystemLinker, LLVMJit)) {
    @("voidFunctionOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                assert(0);
            }

            unittest {
                foo;
            }
        }).shouldThrowWithMessage("Assertion failure");
    }
}

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    IR,
    SystemLinker,
    LLVMJit,
)) {
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

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    IR,
    SystemLinker,
    LLVMJit,
)) {
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

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    IR,
    SystemLinker,
    LLVMJit,
)) {
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

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    IR,
    SystemLinker,
    LLVMJit,
)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(
    Ctfe,
    Interpreter,
    Bytecode,
    IR,
    SystemLinker,
)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, IR)) {
    @("literalFalseAssertionMatchesDmd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(false);
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }
}

// Compiled `assert(false)` in a unittest body raises the plain _d_unittest
// hook message "unittest failure"; "`assert(false)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("literalFalseAssertionMatchesDmd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(false);
            }
        }).shouldThrowWithMessage("unittest failure");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("assertMessageDoesNotEvaluateOnSuccess." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string message() {
                assert(0);
            }

            unittest {
                assert(true, message);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("uintGreaterOrEqualUsesUnsignedComparison." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint value() {
                return uint.max;
            }

            unittest {
                assert(value >= 0u);
            }
        });
    }
}

// SystemLinker deliberately excluded from the three null-class-dereference
// blocks below: a compiled null dereference is a real SIGSEGV that would kill
// the test runner (ai/plans/dmd-backend.md, slice 3).
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, IR)) {
    @("nullClassNotIdentityUsesNotEqualPolarity." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Thing {}

            unittest {
                Thing thing;
                assert(thing !is null);
            }
        }).shouldThrowWithMessage("`null` is `null`");
    }
}

// A void-initialized *struct* may be returned whole and then have its fields
// assigned, matching DMD CTFE (and compiled code). DMD's void diagnostic is
// field-granular: only reads of still-void scalars/fields are reported, not the
// whole-aggregate read that `return res;` performs. Mirrors Phobos
// `trustedVoidInit`, which the interpreter previously rejected before reaching
// any libc call. Bytecode supports this whole-aggregate path; IR does not yet
// support it.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("voidInitializedStructReturnedWholeIsUsable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair { int first; int second; }

            Pair voidPair() {
                Pair res = void;
                return res;
            }

            int combine(in int a, in int b) {
                auto p = voidPair();
                p.first = a;
                p.second = b;
                return p.first + p.second;
            }

            unittest {
                assert(combine(20, 22) == 42);
            }
        });
    }
}

// Ctfe diverges from SystemLinker/compiled D here: reading a
// void-initialized scalar is a CTFE-only diagnostic, while compiled code just
// reads whatever is in the slot.
static foreach (backend; AliasSeq!(Ctfe)) {
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

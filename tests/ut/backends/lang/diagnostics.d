module ut.backends.lang.diagnostics;


import ut.backends;
import std.algorithm.searching: canFind;
import std.exception: collectExceptionMsg;


private:

static foreach (backend; backends) {
    @("voidFunctionReturnsToCaller." ~ backend.stringof)
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

static foreach (backend; backendsWith!Interpreter) {
    @("intLessThanOops." ~ backend.stringof)
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

    @("intLessOrEqualOops." ~ backend.stringof)
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

    @("intGreaterThanOops." ~ backend.stringof)
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

static foreach (backend; backends) {
    @("intGreaterOrEqualOops." ~ backend.stringof)
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

    @("intNotEqualOops." ~ backend.stringof)
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

    @("ok." ~ backend.stringof)
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

    @("oops." ~ backend.stringof)
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

    @("okFailureMessage.0." ~ backend.stringof)
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

    @("localIntReturnOops." ~ backend.stringof)
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

    @("functionParametersOops." ~ backend.stringof)
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

    @("functionParameterOops." ~ backend.stringof)
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

    @("refParameterOops." ~ backend.stringof)
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

    @("ifElseOops." ~ backend.stringof)
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

    @("inFunctionParametersOops." ~ backend.stringof)
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

    @("refSizeTParameterOops." ~ backend.stringof)
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

static foreach (backend; backendsWith!Interpreter) {
    @("explicitAssertMessageOverridesContext." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(1 == 2, "oops");
            }
        }).shouldThrowWithMessage("oops");
    }

    @("literalFalseAssertionMatchesDmd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(false);
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }
}

static foreach (backend; backends) {
    @("runtimeBoolAssertionContextMatchesDmd." ~ backend.stringof)
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

    @("boolAssertionContextMatchesDmd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool a = true;
                assert(a == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("charAssertionContextMatchesDmd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char a = 'a';
                assert(a == 'b');
            }
        }).shouldThrowWithMessage("'a' != 'b'");
    }

    @("dynamicAssertMessageMatchesDmd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                string msg = "oops";
                assert(false, msg);
            }
        }).shouldThrowWithMessage("oops");
    }

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

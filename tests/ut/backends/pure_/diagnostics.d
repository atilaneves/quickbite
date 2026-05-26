module ut.backends.pure_.diagnostics;


import ut.backends;


private:

import std.conv: text;
import ut.backends:
    experimentalBackendTestsEnabled,
    matureExecutorBackends;
import unit_threaded;


static foreach (backend; matureExecutorBackends ~ [
    ExecutorBackend.bytecode,
    ExecutorBackend.treeWalking,
]) {
    @("voidFunctionReturnsToCaller." ~ backend.text)
    unittest {
        q{
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
        }.expectBackendFailure(backend, "1 != 2");
    }

    @("intLessThanOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 < bound);
            }
        }.expectBackendFailure(backend, "42 >= 42");
    }

    @("intLessOrEqualOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 <= bound);
            }
        }.expectBackendFailure(backend, "43 > 42");
    }

    @("intGreaterThanOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 > bound);
            }
        }.expectBackendFailure(backend, "42 <= 42");
    }

    @("intGreaterOrEqualOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(41 >= bound);
            }
        }.expectBackendFailure(backend, "41 < 42");
    }

    @("intNotEqualOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(bound != 42);
            }
        }.expectBackendFailure(backend, "42 == 42");
    }
}

private void expectBackendFailure(
    in string source,
    in ExecutorBackend backend,
    in string extraBackendMessage,
) {
    bool threw;
    try {
        runTests(source, backend);
    } catch (Exception exception) {
        threw = true;
        if (
            backend == ExecutorBackend.bytecode ||
            backend == ExecutorBackend.treeWalking
        ) {
            exception.msg.should == extraBackendMessage;
        }
    }
    threw.should == true;
}

static foreach (backend; matureExecutorBackends) {
    @("ok." ~ backend.text)
    unittest {
        if (backend != ExecutorBackend.dmdCodegenRam || experimentalBackendTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 42);
                }
            }, backend);
        }
    }

    @("oops." ~ backend.text)
    unittest {
        if (backend != ExecutorBackend.dmdCodegenRam || experimentalBackendTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 43);
                }
            }, backend).shouldThrowWithMessage("42 != 43");
        }
    }

    @("localIntReturnOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 43);
            }
        }, backend).shouldThrowWithMessage("42 != 43");
    }

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("voidFunctionOops." ~ backend.text)
        unittest {
            runTests(q{
                void foo() {
                    assert(0);
                }

                unittest {
                    foo;
                }
            }, backend).shouldThrowWithMessage("Assertion failure");
        }
    }

    @("functionParametersOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 3) == 42);
            }
        }, backend).shouldThrowWithMessage("43 != 42");
    }

    @("functionParameterOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 43);
            }
        }, backend).shouldThrowWithMessage("42 != 43");
    }

    @("refParameterOops." ~ backend.text)
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            enum expected = "41 != 43";
        else
            enum expected = "42 != 43";

        runTests(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 43);
            }
        }, backend).shouldThrowWithMessage(expected);
    }

    @("ifElseOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(2) == 42);
            }
        }, backend).shouldThrowWithMessage("43 != 42");
    }

    @("inFunctionParametersOops." ~ backend.text)
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            enum expected = "Unittest assertion failed.";
        else
            enum expected = "43 != 42";

        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 3);
            }
        }, backend).shouldThrowWithMessage(expected);
    }

    @("refSizeTParameterOops." ~ backend.text)
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            enum expected = "41 != 43";
        else
            enum expected = "42 != 43";

        runTests(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 43);
            }
        }, backend).shouldThrowWithMessage(expected);
    }
}

static foreach (backend; [
    ExecutorBackend.bytecode,
    ExecutorBackend.treeWalking,
]) {
    @(backend.text ~ " explicit assert message overrides context")
    unittest {
        runTests(q{
            unittest {
                assert(1 == 2, "oops");
            }
        }, backend).shouldThrowWithMessage("oops");
    }
}

@("literal false assertion matches DMD")
unittest {
    runTests(q{
        unittest {
            assert(false);
        }
    }).shouldThrowWithMessage("unittest failure");
}

@("runtime bool assertion context matches DMD")
unittest {
    runTests(q{
        bool nope() {
            return false;
        }

        unittest {
            assert(nope());
        }
    }).shouldThrowWithMessage("false != true");
}

@("bool assertion context matches DMD.dmdCtfe")
unittest {
    runTests(q{
        unittest {
            bool a = true;
            assert(a == false);
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("true != false");
}

@("char assertion context matches DMD.dmdCtfe")
unittest {
    runTests(q{
        unittest {
            char a = 'a';
            assert(a == 'b');
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("'a' != 'b'");
}

@("dynamic assert message matches DMD")
unittest {
    runTests(q{
        unittest {
            string msg = "oops";
            assert(false, msg);
        }
    }).shouldThrowWithMessage("oops");
}

@("dynamic assert message matches DMD.dmdCtfe")
unittest {
    runTests(q{
        unittest {
            string msg = "oops";
            assert(false, msg);
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("oops");
}

@("treeWalkingOld assertion context does not reevaluate equality operands")
unittest {
    runTests(q{
        unittest {
            int value;
            assert(++value == 0);
        }
    }, ExecutorBackend.treeWalkingOld).shouldThrowWithMessage("1 != 0");
}

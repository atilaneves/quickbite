module ut.executors.pure_.lang.diagnostics;


import ut.executors;


private:

import std.conv: text;
import ut.executors:
    experimentalExecutorTestsEnabled,
    matureExecutorNames;
import unit_threaded;


static foreach (executorName; matureExecutorNames ~ [
    ExecutorName.bytecode,
    ExecutorName.treeWalking,
]) {
    @("voidFunctionReturnsToCaller." ~ executorName.text)
    unittest {
        q{
            int one() {
                return 1;
            }

            void foo() {}

            unittest {
                foo;
                // Keep this runtime-shaped so DMD does not constant-fold it
                // before the executor sees the equality expression.
                assert(one == 2);
            }
        }.expectBackendFailure(executorName, "1 != 2");
    }

    @("intLessThanOops." ~ executorName.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(42 < bound);
            }
        }.expectBackendFailure(executorName, "42 >= 42");
    }

    @("intLessOrEqualOops." ~ executorName.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(43 <= bound);
            }
        }.expectBackendFailure(executorName, "43 > 42");
    }

    @("intGreaterThanOops." ~ executorName.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(42 > bound);
            }
        }.expectBackendFailure(executorName, "42 <= 42");
    }

    @("intGreaterOrEqualOops." ~ executorName.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(41 >= bound);
            }
        }.expectBackendFailure(executorName, "41 < 42");
    }

    @("intNotEqualOops." ~ executorName.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(bound != 42);
            }
        }.expectBackendFailure(executorName, "42 == 42");
    }
}

private void expectBackendFailure(
    in string source,
    in ExecutorName executorName,
    in string extraBackendMessage,
) {
    bool threw;
    try {
        runTests(source, executorName);
    } catch (Exception exception) {
        threw = true;
        if (
            executorName == ExecutorName.bytecode ||
            executorName == ExecutorName.treeWalking
        ) {
            exception.msg.should == extraBackendMessage;
        }
    }
    threw.should == true;
}

static foreach (executorName; matureExecutorNames) {
    @("ok." ~ executorName.text)
    unittest {
        if (executorName != ExecutorName.dmdCodegenRam || experimentalExecutorTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 42);
                }
            }, executorName);
        }
    }

    @("oops." ~ executorName.text)
    unittest {
        if (executorName != ExecutorName.dmdCodegenRam || experimentalExecutorTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 43);
                }
            }, executorName).shouldThrowWithMessage("42 != 43");
        }
    }

    @("localIntReturnOops." ~ executorName.text)
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 43);
            }
        }, executorName).shouldThrowWithMessage("42 != 43");
    }

    static if (executorName != ExecutorName.treeWalkingOld) {
        @("voidFunctionOops." ~ executorName.text)
        unittest {
            runTests(q{
                void foo() {
                    assert(0);
                }

                unittest {
                    foo;
                }
            }, executorName).shouldThrowWithMessage("Assertion failure");
        }
    }

    @("functionParametersOops." ~ executorName.text)
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 3) == 42);
            }
        }, executorName).shouldThrowWithMessage("43 != 42");
    }

    @("functionParameterOops." ~ executorName.text)
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 43);
            }
        }, executorName).shouldThrowWithMessage("42 != 43");
    }

    @("refParameterOops." ~ executorName.text)
    unittest {
        static if (executorName == ExecutorName.dmdCtfe)
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
        }, executorName).shouldThrowWithMessage(expected);
    }

    @("ifElseOops." ~ executorName.text)
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
        }, executorName).shouldThrowWithMessage("43 != 42");
    }

    @("inFunctionParametersOops." ~ executorName.text)
    unittest {
        static if (executorName == ExecutorName.dmdCtfe)
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
        }, executorName).shouldThrowWithMessage(expected);
    }

    @("refSizeTParameterOops." ~ executorName.text)
    unittest {
        static if (executorName == ExecutorName.dmdCtfe)
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
        }, executorName).shouldThrowWithMessage(expected);
    }
}

static foreach (executorName; [
    ExecutorName.bytecode,
    ExecutorName.treeWalking,
]) {
    @(executorName.text ~ " explicit assert message overrides context")
    unittest {
        runTests(q{
            unittest {
                assert(1 == 2, "oops");
            }
        }, executorName).shouldThrowWithMessage("oops");
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
    }, ExecutorName.dmdCtfe).shouldThrowWithMessage("true != false");
}

@("char assertion context matches DMD.dmdCtfe")
unittest {
    runTests(q{
        unittest {
            char a = 'a';
            assert(a == 'b');
        }
    }, ExecutorName.dmdCtfe).shouldThrowWithMessage("'a' != 'b'");
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
    }, ExecutorName.dmdCtfe).shouldThrowWithMessage("oops");
}

@("treeWalkingOld assertion context does not reevaluate equality operands")
unittest {
    runTests(q{
        unittest {
            int value;
            assert(++value == 0);
        }
    }, ExecutorName.treeWalkingOld).shouldThrowWithMessage("1 != 0");
}

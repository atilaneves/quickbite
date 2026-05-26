module ut.executors.pure_.lang.logic;


import ut.executors;


private:

import std.conv: text;
import ut.executors:
    dmdCodegenRamExecutorNames,
    experimentalExecutorTestsEnabled,
    matureExecutorNames;
import unit_threaded;


static foreach (executorName; matureExecutorNames ~ [
    ExecutorName.bytecode,
    ExecutorName.treeWalking,
]) {
    @("assertNonzeroIntCondition." ~ executorName.text)
    unittest {
        runTests(q{
            int mask() {
                return 2;
            }

            unittest {
                assert(0x28 | mask);
            }
        }, executorName);
    }
}

static foreach (executorName; matureExecutorNames) {
    @("logicalNot." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                bool isReady = false;
                assert(!isReady);
            }
        }, executorName);
    }

    @("logicalNotCall." ~ executorName.text)
    unittest {
        runTests(q{
            bool isReady() {
                return false;
            }

            unittest {
                assert(!isReady);
            }
        }, executorName);
    }

    @("logicalAnd." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                bool right = true;
                assert(left && right);
            }
        }, executorName);
    }

    @("logicalAndCall." ~ executorName.text)
    unittest {
        runTests(q{
            bool left() {
                return true;
            }

            bool right() {
                return true;
            }

            unittest {
                assert(left && right);
            }
        }, executorName);
    }

    @("logicalAndShortCircuit." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0));
            }
        }, executorName);
    }

    @("logicalAndCallShortCircuit." ~ executorName.text)
    unittest {
        runTests(q{
            bool isReady() {
                return false;
            }

            bool failIfCalled() {
                assert(0);
                return true;
            }

            unittest {
                assert(!(isReady && failIfCalled));
            }
        }, executorName);
    }

    @("logicalOrBoolResult." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                assert((2 || false) == true);
            }
        }, executorName);
    }

    @("logicalOr." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                bool right = true;
                assert(left || right);
            }
        }, executorName);
    }

    static if (executorName != ExecutorName.treeWalkingOld) {
        @("logicalOrOops." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    bool left = false;
                    bool right = false;
                    assert(left || right);
                }
            }, executorName).shouldThrowWithMessage("`assert(left || right)` failed");
        }
    }

    @("logicalOrShortCircuit." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(left || 42 / zero == 0);
            }
        }, executorName);
    }
}

static foreach (executorName; dmdCodegenRamExecutorNames) {
    @(text("logicalAnd.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 42;
                }

                unittest {
                    assert(input > 41 && input < 43);
                }
            }, executorName);
        }
    }
}

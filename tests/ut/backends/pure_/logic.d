module ut.backends.pure_.logic;


import ut.backends;


private:

import std.conv: text;
import ut.backends:
    dmdCodegenRamExecutorBackends,
    experimentalBackendTestsEnabled,
    matureExecutorBackends;
import unit_threaded;


static foreach (backend; matureExecutorBackends ~ [
    ExecutorBackend.bytecode,
    ExecutorBackend.treeWalking,
]) {
    @("assertNonzeroIntCondition." ~ backend.text)
    unittest {
        runTests(q{
            int mask() {
                return 2;
            }

            unittest {
                assert(0x28 | mask);
            }
        }, backend);
    }
}

static foreach (backend; matureExecutorBackends) {
    @("logicalNot." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                bool isReady = false;
                assert(!isReady);
            }
        }, backend);
    }

    @("logicalNotCall." ~ backend.text)
    unittest {
        runTests(q{
            bool isReady() {
                return false;
            }

            unittest {
                assert(!isReady);
            }
        }, backend);
    }

    @("logicalAnd." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                bool right = true;
                assert(left && right);
            }
        }, backend);
    }

    @("logicalAndCall." ~ backend.text)
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
        }, backend);
    }

    @("logicalAndShortCircuit." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0));
            }
        }, backend);
    }

    @("logicalAndCallShortCircuit." ~ backend.text)
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
        }, backend);
    }

    @("logicalOrBoolResult." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                assert((2 || false) == true);
            }
        }, backend);
    }

    @("logicalOr." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                bool right = true;
                assert(left || right);
            }
        }, backend);
    }

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("logicalOrOops." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    bool left = false;
                    bool right = false;
                    assert(left || right);
                }
            }, backend).shouldThrowWithMessage("`assert(left || right)` failed");
        }
    }

    @("logicalOrShortCircuit." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(left || 42 / zero == 0);
            }
        }, backend);
    }
}

static foreach (backend; dmdCodegenRamExecutorBackends) {
    @(text("logicalAnd.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 42;
                }

                unittest {
                    assert(input > 41 && input < 43);
                }
            }, backend);
        }
    }
}

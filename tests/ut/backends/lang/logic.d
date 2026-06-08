module ut.backends.lang.logic;


import ut.backends;


static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("assertNonzeroIntCondition." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 2;
            }

            unittest {
                assert(0x28 | mask);
            }
        });
    }
    @("assertNonzeroIntConditionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 2;
            }

            unittest {
                assert((0x28 | mask) == 0x2b);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
    @("assertNonzeroIntConditionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 1;
            }

            unittest {
                assert((0x28 | mask) == 0x2a);
            }
        }).shouldThrowWithMessage("41 != 42");
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("logicalAndCallFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool left() {
                return true;
            }

            bool right() {
                return false;
            }

            unittest {
                assert(left && right);
            }
        }).shouldThrowWithMessage("`assert(left && right)` failed");
    }
    @("logicalAndCallFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool left() {
                return true;
            }

            bool right() {
                return true;
            }

            unittest {
                assert((left && right) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
    @("logicalAndCall." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool left() {
                return true;
            }

            bool right() {
                return true;
            }

            unittest {
                assert(left && right);
            }
        });
    }
    @("logicalAndShortCircuitFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert((left && 42 / zero == 0) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
    @("logicalAndShortCircuitFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
    @("logicalAndCallShortCircuit." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
    @("logicalAndCallShortCircuitFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isReady() {
                return false;
            }

            bool failIfCalled() {
                assert(0);
                return true;
            }

            unittest {
                assert((isReady && failIfCalled) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
    @("logicalAndCallShortCircuitFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isReady() {
                return true;
            }

            bool failIfCalled() {
                assert(0);
                return true;
            }

            unittest {
                assert(!(isReady && failIfCalled));
            }
        }).shouldThrowWithMessage("`assert(0)` failed");
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("logicalOrBoolResult." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert((2 || false) == true);
            }
        });
    }
    @("logicalOrBoolResultFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert((2 || false) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
    @("logicalOrBoolResultFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool zero() {
                return false;
            }

            unittest {
                bool left = zero;
                assert((left || false) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
    @("logicalOrFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                bool right = true;
                assert((left || right) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
    @("logicalOrFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                bool right = false;
                assert((left || right) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
    @("logicalOrOops." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                bool right = false;
                assert(left || right);
            }
        }).shouldThrowWithMessage("`assert(left || right)` failed");
    }
    @("logicalOrShortCircuit." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(left || 42 / zero == 0);
            }
        });
    }
    @("logicalOrShortCircuitFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert((left || 42 / zero == 0) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
    @("logicalOrShortCircuitFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(!(left || 42 / zero == 0));
            }
        }).shouldThrowWithMessage("true == true");
    }
    @("logicalAndComparisonOperands." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 42;
            }

            unittest {
                assert(input > 41 && input < 43);
            }
        });
    }
    @("logicalAndComparisonOperandsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 42;
            }

            unittest {
                assert((input > 41 && input < 43) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
    @("logicalAndComparisonOperandsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 41;
            }

            unittest {
                assert((input > 41 && input < 43) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
    @("logicalOr." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                bool right = true;
                assert(left || right);
            }
        });
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("logicalAndShortCircuit." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0));
            }
        });
    }

    @("logicalAndFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                bool right = false;
                assert((left && right) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("logicalAndFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                bool right = true;
                assert((left && right) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("logicalAnd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                bool right = true;
                assert(left && right);
            }
        });
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("logicalNotCallFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isReady() {
                return false;
            }

            unittest {
                assert(!isReady == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("logicalNotCallFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isReady() {
                return true;
            }

            unittest {
                assert(!isReady == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("logicalNotFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool isReady = true;
                assert(!isReady == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("logicalNotFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool isReady = false;
                assert(!isReady == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("logicalNotCall." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isReady() {
                return false;
            }

            unittest {
                assert(!isReady);
            }
        });
    }

    @("logicalNot." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool isReady = false;
                assert(!isReady);
            }
        });
    }
}

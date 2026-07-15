module ut.backends.runner.lang.logic;


import ut.backends;


static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("assertNonzeroIntCondition." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("assertNonzeroIntConditionFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("assertNonzeroIntConditionFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndCallFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndCallFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndCall." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndShortCircuitFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert((left && 42 / zero == 0) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndShortCircuitFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndCallShortCircuit." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndCallShortCircuitFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

// Ctfe diverges from SystemLinker here: CTFE-evaluated `assert(0)` raises the
// message "`assert(0)` failed", so this block characterizes Ctfe (and the
// interpretation backends) rather than the SystemLinker oracle below.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, IR)) {
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

// Compiled `assert(0)` in a non-unittest function raises the plain _d_assert
// message "Assertion failure"; "`assert(0)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(Bytecode, SystemLinker, LLVMJit)) {
    @("logicalAndCallShortCircuitFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
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
        }).shouldThrowWithMessage("Assertion failure");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrBoolResult." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert((2 || false) == true);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrBoolResultFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert((2 || false) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrBoolResultFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                bool right = true;
                assert((left || right) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                bool right = false;
                assert((left || right) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                bool right = false;
                assert(left || right);
            }
        }).shouldThrowWithMessage("`assert(left || right)` failed");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrShortCircuit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(left || 42 / zero == 0);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrShortCircuitFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert((left || 42 / zero == 0) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOrShortCircuitFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(!(left || 42 / zero == 0));
            }
        }).shouldThrowWithMessage("true == true");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalOr." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndComparisonOperands." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndComparisonOperandsFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndComparisonOperandsFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalAndShortCircuit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0));
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalAndFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                bool right = false;
                assert((left && right) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalAndFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool left = true;
                bool right = true;
                assert((left && right) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalAnd." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {
    @("logicalNotCallFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalNotCallFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalNotFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool isReady = true;
                assert(!isReady == true);
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalNotFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool isReady = false;
                assert(!isReady == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalNotCall." ~ backend.stringof)
    @Tags(backend.stringof)
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
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR, SystemLinker, LLVMJit)) {

    @("logicalNot." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                bool isReady = false;
                assert(!isReady);
            }
        });
    }
}

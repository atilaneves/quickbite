module ut.backends.pure_.exceptions;


import ut.backends;


private:

import std.conv: text;
import ut.backends: matureExecutorBackends;
import unit_threaded;


static foreach (backend; matureExecutorBackends) {
    @("throwingTest." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                throw new Exception("boom");
            }
        }, backend).shouldThrowWithMessage("boom");
    }

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("catchExceptionDoesNotCatchAssertFailure." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    try {
                        assert(false);
                    } catch (Exception) {
                    }
                }
            }, backend).shouldThrowWithMessage("unittest failure");
        }
    }

    @("catchExceptionCatchesThrownException." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                }
            }
        }, backend);
    }

    static if (backend == ExecutorBackend.ir) {
        @("catchExceptionCatchesThrownExceptionFromCalledFunction." ~ backend.text)
        unittest {
            runTests(q{
                void f() {
                    throw new Exception("expected");
                }

                unittest {
                    int value;
                    try {
                        f;
                    } catch (Exception) {
                        value = 42;
                    }
                    assert(value == 42);
                }
            }, backend);
        }

        @("catchExceptionCatchesThrowAfterCalleeSideEffect." ~ backend.text)
        unittest {
            runTests(q{
                int marker;

                void f() {
                    marker = 1;
                    throw new Exception("expected");
                }

                unittest {
                    assert(marker == 0);

                    int caught;
                    try {
                        f;
                    } catch (Exception) {
                        caught = 1;
                    }

                    assert(caught == 1);
                    assert(marker == 1);
                }
            }, backend);
        }

        @("catchExceptionCatchesNestedBranchThrowFromCalledFunction." ~ backend.text)
        unittest {
            runTests(q{
                int marker;

                void g(bool shouldThrow) {
                    if (shouldThrow) {
                        marker = 1;
                        throw new Exception("expected");
                    }

                    marker = 2;
                }

                void f() {
                    g(true);
                    marker = 3;
                }

                unittest {
                    assert(marker == 0);

                    g(false);
                    assert(marker == 2);

                    int caught;
                    try {
                        f;
                    } catch (Exception) {
                        caught = 1;
                    }

                    assert(caught == 1);
                    assert(marker == 1);
                }
            }, backend);
        }

        @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunction." ~ backend.text)
        unittest {
            runTests(q{
                int marker;

                void f(int value) {
                    if (value == 1) {
                        marker = 1;
                        throw new Exception("expected");
                    }

                    marker = 2;
                }

                unittest {
                    assert(marker == 0);

                    int caught;
                    int runtimeValue = caught + 1;
                    try {
                        f(runtimeValue);
                    } catch (Exception) {
                        caught = 1;
                    }

                    // Runtime data selects the branch, so lowering cannot
                    // prove the throw path syntactically.
                    assert(caught == 1);
                    assert(marker == 1);
                }
            }, backend);
        }
    }

    @("throwPreservesExceptionMessage." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                throw new Exception("domain failure");
            }
        }, backend).shouldThrowWithMessage("domain failure");
    }

    static if (backend != ExecutorBackend.dmdCtfe) {
        @("finallyRunsAfterReturn." ~ backend.text)
        unittest {
            runTests(q{
                int value;

                int setAndReturn() {
                    try {
                        return 1;
                    } finally {
                        value = 42;
                    }
                }

                unittest {
                    assert(setAndReturn == 1);
                    assert(value == 42);
                }
            }, backend);
        }
    }

    static if (backend == ExecutorBackend.ir) {
        @("finallyReturnCapturesValueBeforeFinally." ~ backend.text)
        unittest {
            runTests(q{
                int value;

                int readThenMutate() {
                    try {
                        return value;
                    } finally {
                        value = 2;
                    }
                }

                unittest {
                    value = 1;
                    assert(readThenMutate == 1);
                    assert(value == 2);
                }
            }, backend);
        }

        @("finallyBranchReturnsCaptureValueBeforeFinally." ~ backend.text)
        unittest {
            runTests(q{
                int value;

                int readBranchThenMutate(bool chooseFirst) {
                    try {
                        if (chooseFirst)
                            return value + 10;
                        else
                            return value + 20;
                    } finally {
                        value = 2;
                    }
                }

                unittest {
                    value = 1;
                    assert(readBranchThenMutate(true) == 11);
                    assert(value == 2);

                    value = 3;
                    assert(readBranchThenMutate(false) == 23);
                    assert(value == 2);
                }
            }, backend);
        }
    }

    @("catchHandlerRuns." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 42;
                }
                assert(value == 42);
            }
        }, backend);
    }
}

module ut.executors.pure_.lang.exceptions;


import ut.executors;


private:

import std.conv: text;
import ut.executors: matureExecutorNames;
import unit_threaded;


static foreach (executorName; matureExecutorNames) {
    @("throwingTest." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                throw new Exception("boom");
            }
        }, executorName).shouldThrowWithMessage("boom");
    }

    static if (executorName != ExecutorName.treeWalkingOld) {
        @("catchExceptionDoesNotCatchAssertFailure." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    try {
                        assert(false);
                    } catch (Exception) {
                    }
                }
            }, executorName).shouldThrowWithMessage("unittest failure");
        }
    }

    @("catchExceptionCatchesThrownException." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                }
            }
        }, executorName);
    }

    static if (executorName == ExecutorName.ir) {
        @("catchExceptionCatchesThrownExceptionFromCalledFunction." ~ executorName.text)
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
            }, executorName);
        }

        @("catchExceptionCatchesThrowAfterCalleeSideEffect." ~ executorName.text)
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
            }, executorName);
        }

        @("catchExceptionCatchesNestedBranchThrowFromCalledFunction." ~ executorName.text)
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
            }, executorName);
        }

        @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunction." ~ executorName.text)
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
            }, executorName);
        }
    }

    @("throwPreservesExceptionMessage." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                throw new Exception("domain failure");
            }
        }, executorName).shouldThrowWithMessage("domain failure");
    }

    static if (executorName != ExecutorName.dmdCtfe) {
        @("finallyRunsAfterReturn." ~ executorName.text)
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
            }, executorName);
        }
    }

    static if (executorName == ExecutorName.ir) {
        @("finallyReturnCapturesValueBeforeFinally." ~ executorName.text)
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
            }, executorName);
        }

        @("finallyBranchReturnsCaptureValueBeforeFinally." ~ executorName.text)
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
            }, executorName);
        }
    }

    @("catchHandlerRuns." ~ executorName.text)
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
        }, executorName);
    }
}

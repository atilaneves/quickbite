module ut.backends.pure_.lang.exceptions;


import ut.backends;


private:

static foreach (backend; backends) {
    @("throwingTest." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                throw new Exception("boom");
            }
        }).shouldThrowWithMessage("uncaught CTFE exception `object.Exception(\"boom\")`");
    }

    @("catchExceptionDoesNotCatchAssertFailure." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                try {
                    assert(false);
                } catch (Exception) {
                }
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }

    @("catchExceptionCatchesThrownException." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 42;
                }
                assert(value == 42);
            }
        });
    }

    @("catchExceptionCatchesThrownExceptionFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 42;
                }
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("catchExceptionCatchesThrownExceptionFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 7;
                }
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("catchExceptionCatchesThrownExceptionFromCalledFunction." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
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
        });
    }

    @("catchExceptionCatchesThrownExceptionFromCalledFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
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
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("catchExceptionCatchesThrownExceptionFromCalledFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void f() {
                throw new Exception("expected");
            }

            unittest {
                int value;
                try {
                    f;
                } catch (Exception) {
                    value = 7;
                }
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("catchExceptionCatchesThrowAfterCalleeSideEffect." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void f(ref int marker) {
                marker = 1;
                throw new Exception("expected");
            }

            unittest {
                int marker;
                assert(marker == 0);

                int caught;
                try {
                    f(marker);
                } catch (Exception) {
                    caught = 1;
                }

                assert(caught == 1);
                assert(marker == 1);
            }
        });
    }

    @("catchExceptionCatchesThrowAfterCalleeSideEffectFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void f(ref int marker) {
                marker = 1;
                throw new Exception("expected");
            }

            unittest {
                int marker;

                int caught;
                try {
                    f(marker);
                } catch (Exception) {
                    caught = 1;
                }

                assert(caught == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("catchExceptionCatchesThrowAfterCalleeSideEffectFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void f(ref int marker) {
                marker = 1;
                throw new Exception("expected");
            }

            unittest {
                int marker;

                int caught;
                try {
                    f(marker);
                } catch (Exception) {
                    caught = 1;
                }

                assert(marker == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("catchExceptionCatchesNestedBranchThrowFromCalledFunction." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void g(ref int marker, bool shouldThrow) {
                if (shouldThrow) {
                    marker = 1;
                    throw new Exception("expected");
                }

                marker = 2;
            }

            void f(ref int marker) {
                g(marker, true);
                marker = 3;
            }

            unittest {
                int marker;
                assert(marker == 0);

                g(marker, false);
                assert(marker == 2);

                int caught;
                try {
                    f(marker);
                } catch (Exception) {
                    caught = 1;
                }

                assert(caught == 1);
                assert(marker == 1);
            }
        });
    }

    @("catchExceptionCatchesNestedBranchThrowFromCalledFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void g(ref int marker, bool shouldThrow) {
                if (shouldThrow) {
                    marker = 1;
                    throw new Exception("expected");
                }

                marker = 2;
            }

            void f(ref int marker) {
                g(marker, true);
                marker = 3;
            }

            unittest {
                int marker;

                g(marker, false);
                assert(marker == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("catchExceptionCatchesNestedBranchThrowFromCalledFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void g(ref int marker, bool shouldThrow) {
                if (shouldThrow) {
                    marker = 1;
                    throw new Exception("expected");
                }

                marker = 2;
            }

            void f(ref int marker) {
                g(marker, true);
                marker = 3;
            }

            unittest {
                int marker;

                int caught;
                try {
                    f(marker);
                } catch (Exception) {
                    caught = 1;
                }

                assert(marker == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunction." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void f(ref int marker, int value) {
                if (value == 1) {
                    marker = 1;
                    throw new Exception("expected");
                }

                marker = 2;
            }

            unittest {
                int marker;
                assert(marker == 0);

                int caught;
                int runtimeValue = caught + 1;
                try {
                    f(marker, runtimeValue);
                } catch (Exception) {
                    caught = 1;
                }

                // Runtime data selects the branch, so lowering cannot
                // prove the throw path syntactically.
                assert(caught == 1);
                assert(marker == 1);
            }
        });
    }

    @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void f(ref int marker, int value) {
                if (value == 1) {
                    marker = 1;
                    throw new Exception("expected");
                }

                marker = 2;
            }

            unittest {
                int marker;
                int caught;
                int runtimeValue = caught + 1;
                try {
                    f(marker, runtimeValue);
                } catch (Exception) {
                    caught = 1;
                }

                assert(caught == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            void f(ref int marker, int value) {
                if (value == 1) {
                    marker = 1;
                    throw new Exception("expected");
                }

                marker = 2;
            }

            unittest {
                int marker;
                int caught;
                int runtimeValue = caught + 1;
                try {
                    f(marker, runtimeValue);
                } catch (Exception) {
                    caught = 1;
                }

                assert(marker == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("throwPreservesExceptionMessage." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                throw new Exception("domain failure");
            }
        }).shouldThrowWithMessage(
            "uncaught CTFE exception `object.Exception(\"domain failure\")`"
        );
    }

    @("finallyRunsAfterReturn." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int setAndReturn(ref int value) {
                try {
                    return 1;
                } finally {
                    value = 42;
                }
            }

            unittest {
                int value;
                assert(setAndReturn(value) == 1);
                assert(value == 42);
            }
        });
    }

    @("finallyRunsAfterReturnFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int setAndReturn(ref int value) {
                try {
                    return 1;
                } finally {
                    value = 42;
                }
            }

            unittest {
                int value;
                assert(setAndReturn(value) == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("finallyRunsAfterReturnFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int setAndReturn(ref int value) {
                try {
                    return 1;
                } finally {
                    value = 42;
                }
            }

            unittest {
                int value;
                setAndReturn(value);
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("finallyReturnCapturesValueBeforeFinally." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int readThenMutate(ref int value) {
                try {
                    return value;
                } finally {
                    value = 2;
                }
            }

            unittest {
                int value = 1;
                assert(readThenMutate(value) == 1);
                assert(value == 2);
            }
        });
    }

    @("finallyReturnCapturesValueBeforeFinallyFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int readThenMutate(ref int value) {
                try {
                    return value;
                } finally {
                    value = 2;
                }
            }

            unittest {
                int value = 1;
                assert(readThenMutate(value) == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("finallyReturnCapturesValueBeforeFinallyFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int readThenMutate(ref int value) {
                try {
                    return value;
                } finally {
                    value = 2;
                }
            }

            unittest {
                int value = 1;
                readThenMutate(value);
                assert(value == 1);
            }
        }).shouldThrowWithMessage("2 != 1");
    }

    @("finallyBranchReturnsCaptureValueBeforeFinally." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int readBranchThenMutate(ref int value, bool chooseFirst) {
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
                int value = 1;
                assert(readBranchThenMutate(value, true) == 11);
                assert(value == 2);

                value = 3;
                assert(readBranchThenMutate(value, false) == 23);
                assert(value == 2);
            }
        });
    }

    @("finallyBranchReturnsCaptureValueBeforeFinallyFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int readBranchThenMutate(ref int value, bool chooseFirst) {
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
                int value = 1;
                assert(readBranchThenMutate(value, true) == 12);
            }
        }).shouldThrowWithMessage("11 != 12");
    }

    @("finallyBranchReturnsCaptureValueBeforeFinallyFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int readBranchThenMutate(ref int value, bool chooseFirst) {
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
                int value = 3;
                assert(readBranchThenMutate(value, false) == 24);
            }
        }).shouldThrowWithMessage("23 != 24");
    }

    @("catchHandlerRuns." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 42;
                }
                assert(value == 42);
            }
        });
    }

    @("catchHandlerRunsFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 42;
                }
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("catchHandlerRunsFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 7;
                }
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

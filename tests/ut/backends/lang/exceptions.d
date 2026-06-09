module ut.backends.lang.exceptions;


import ut.backends;


static foreach (backend; backends) {
    @("throwingTest." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("boom");
            }
        }).shouldThrowWithMessage("uncaught CTFE exception `object.Exception(\"boom\")`");
    }
}

static foreach (backend; backends) {

    @("catchExceptionDoesNotCatchAssertFailure." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                try {
                    assert(false);
                } catch (Exception) {
                }
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrownException." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrownExceptionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrownExceptionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

static foreach (backend; backends) {

    @("catchExceptionBindsCaughtObject." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int length;
                try {
                    throw new Exception("expected");
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }
                assert(length == 8);
            }
        });
    }
}

static foreach (backend; backends) {

    @("catchExceptionBindsCaughtObjectFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int length;
                try {
                    throw new Exception("expected");
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }
                assert(length == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("catchExceptionBindsCaughtObjectFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int length;
                try {
                    throw new Exception("other");
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }
                assert(length == 8);
            }
        }).shouldThrowWithMessage("5 != 8");
    }
}

static foreach (backend; backends) {

    @("catchSkipsNonMatchingSiblingException." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Expected : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            class Other : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            unittest {
                int value = 1;
                try {
                    throw new Expected("expected");
                } catch (Other) {
                    value = 100;
                } catch (Exception caught) {
                    value += cast(int) caught.msg.length;
                }
                assert(value == 9);
            }
        });
    }
}

static foreach (backend; backends) {

    @("catchSkipsNonMatchingSiblingExceptionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Expected : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            class Other : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            unittest {
                int value = 1;
                try {
                    throw new Expected("expected");
                } catch (Other) {
                    value = 100;
                } catch (Exception caught) {
                    value += cast(int) caught.msg.length;
                }
                assert(value == 10);
            }
        }).shouldThrowWithMessage("9 != 10");
    }
}

static foreach (backend; backends) {

    @("catchSkipsNonMatchingSiblingExceptionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Expected : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            class Other : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            unittest {
                int value = 1;
                try {
                    throw new Expected("other");
                } catch (Other) {
                    value = 100;
                } catch (Exception caught) {
                    value += cast(int) caught.msg.length;
                }
                assert(value == 9);
            }
        }).shouldThrowWithMessage("6 != 9");
    }
}

static foreach (backend; backends) {

    @("throwExpressionInConditionalIsCaught." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string makeMessage(int value) {
                return value == 7 ? "expected" : "other";
            }

            int choose(int value, bool shouldThrow) {
                return shouldThrow
                    ? throw new Exception(makeMessage(value))
                    : value + 1;
            }

            unittest {
                int seed;
                int normal = choose(seed + 7, seed != 0);
                assert(normal == 8);

                int length;
                try {
                    choose(normal - 1, normal == 8);
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }

                assert(length == 8);
            }
        });
    }
}

static foreach (backend; backends) {

    @("throwExpressionInConditionalIsCaughtFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string makeMessage(int value) {
                return value == 7 ? "expected" : "other";
            }

            int choose(int value, bool shouldThrow) {
                return shouldThrow
                    ? throw new Exception(makeMessage(value))
                    : value + 1;
            }

            unittest {
                int seed;
                int normal = choose(seed + 7, seed != 0);

                int length;
                try {
                    choose(normal - 1, normal == 8);
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }

                assert(length == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("throwExpressionInConditionalIsCaughtFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string makeMessage(int value) {
                return value == 7 ? "expected" : "other";
            }

            int choose(int value, bool shouldThrow) {
                return shouldThrow
                    ? throw new Exception(makeMessage(value))
                    : value + 1;
            }

            unittest {
                int seed;
                int normal = choose(seed + 7, seed != 0);
                assert(normal == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrownExceptionFromCalledFunction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrownExceptionFromCalledFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrownExceptionFromCalledFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrowAfterCalleeSideEffect." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrowAfterCalleeSideEffectFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesThrowAfterCalleeSideEffectFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesNestedBranchThrowFromCalledFunction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesNestedBranchThrowFromCalledFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesNestedBranchThrowFromCalledFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchExceptionCatchesRuntimeBranchThrowFromCalledFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("throwPreservesExceptionMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("domain failure");
            }
        }).shouldThrowWithMessage(
            "uncaught CTFE exception `object.Exception(\"domain failure\")`"
        );
    }
}

static foreach (backend; backends) {

    @("tryFinallyRunsFinalbody." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                int step = value + 2;
                try {
                    value = step + 3;
                } finally {
                    value += step * 4;
                }

                assert(value == 13);
            }
        });
    }
}

static foreach (backend; backends) {

    @("tryFinallyRunsFinalbodyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                int step = value + 2;
                try {
                    value = step + 3;
                } finally {
                    value += step * 4;
                }

                assert(value == 14);
            }
        }).shouldThrowWithMessage("13 != 14");
    }
}

static foreach (backend; backends) {

    @("tryFinallyRunsFinalbodyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                int step = value + 3;
                try {
                    value = step + 3;
                } finally {
                    value += step * 4;
                }

                assert(value == 13);
            }
        }).shouldThrowWithMessage("18 != 13");
    }
}

static foreach (backend; backends) {

    @("tryFinallyRunsFinalbodyBeforeCatch." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                int length;
                int step = value + 2;
                try {
                    try {
                        value = step + 3;
                        throw new Exception("expected");
                    } finally {
                        value += step * 4;
                    }
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }

                assert(length == 8);
                assert(value == 13);
            }
        });
    }
}

static foreach (backend; backends) {

    @("tryFinallyRunsFinalbodyBeforeCatchFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                int length;
                int step = value + 2;
                try {
                    try {
                        value = step + 3;
                        throw new Exception("expected");
                    } finally {
                        value += step * 4;
                    }
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }

                assert(length == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("tryFinallyRunsFinalbodyBeforeCatchFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                int length;
                int step = value + 2;
                try {
                    try {
                        value = step + 3;
                        throw new Exception("expected");
                    } finally {
                        value += step * 4;
                    }
                } catch (Exception caught) {
                    length = cast(int) caught.msg.length;
                }

                assert(value == 14);
            }
        }).shouldThrowWithMessage("13 != 14");
    }
}

static foreach (backend; backends) {

    @("tryFinallyGotoWithinBodyRunsFinallyOnce." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(1);
                try {
                    total += bump(2);
                    goto resumed;
                    total += bump(99);
                resumed:
                    total += bump(3);
                } finally {
                    total += bump(4);
                }

                assert(total == 14);
            }
        });
    }
}

static foreach (backend; backends) {

    @("tryFinallyGotoWithinBodyRunsFinallyOnceFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(1);
                try {
                    total += bump(2);
                    goto resumed;
                    total += bump(99);
                resumed:
                    total += bump(3);
                } finally {
                    total += bump(4);
                }

                assert(total == 15);
            }
        }).shouldThrowWithMessage("14 != 15");
    }
}

static foreach (backend; backends) {

    @("tryFinallyGotoWithinBodyRunsFinallyOnceFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(2);
                try {
                    total += bump(2);
                    goto resumed;
                    total += bump(99);
                resumed:
                    total += bump(3);
                } finally {
                    total += bump(4);
                }

                assert(total == 14);
            }
        }).shouldThrowWithMessage("15 != 14");
    }
}

static foreach (backend; backends) {

    @("tryFinallyGotoOutOfBodyRunsFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(1);
                try {
                    total += bump(2);
                    goto outside;
                    total += bump(99);
                } finally {
                    total += bump(3);
                }

            outside:
                total += bump(4);
                assert(total == 14);
            }
        });
    }
}

static foreach (backend; backends) {

    @("tryFinallyGotoOutOfBodyRunsFinallyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(1);
                try {
                    total += bump(2);
                    goto outside;
                    total += bump(99);
                } finally {
                    total += bump(3);
                }

            outside:
                total += bump(4);
                assert(total == 15);
            }
        }).shouldThrowWithMessage("14 != 15");
    }
}

static foreach (backend; backends) {

    @("tryFinallyGotoOutOfBodyRunsFinallyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(2);
                try {
                    total += bump(2);
                    goto outside;
                    total += bump(99);
                } finally {
                    total += bump(3);
                }

            outside:
                total += bump(4);
                assert(total == 14);
            }
        }).shouldThrowWithMessage("15 != 14");
    }
}

static foreach (backend; backends) {

    @("finallyRunsAfterReturn." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyRunsAfterReturnFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyRunsAfterReturnFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyReturnCapturesValueBeforeFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyReturnCapturesValueBeforeFinallyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyReturnCapturesValueBeforeFinallyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyBranchReturnsCaptureValueBeforeFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyBranchReturnsCaptureValueBeforeFinallyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("finallyBranchReturnsCaptureValueBeforeFinallyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchHandlerGotoResumesInsideHandler." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    total += bump(1);
                    goto handled;
                    total += bump(99);
                handled:
                    total += bump(3);
                }

                assert(total == 6);
            }
        });
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoResumesInsideHandlerFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    total += bump(1);
                    goto handled;
                    total += bump(99);
                handled:
                    total += bump(3);
                }

                assert(total == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoResumesInsideHandlerFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    total += bump(2);
                    goto handled;
                    total += bump(99);
                handled:
                    total += bump(3);
                }

                assert(total == 6);
            }
        }).shouldThrowWithMessage("7 != 6");
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoLeavesHandler." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(1);
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    total += bump(2);
                    goto outside;
                    total += bump(99);
                }

            outside:
                total += bump(3);
                assert(total == 9);
            }
        });
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoLeavesHandlerFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(1);
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    total += bump(2);
                    goto outside;
                    total += bump(99);
                }

            outside:
                total += bump(3);
                assert(total == 10);
            }
        }).shouldThrowWithMessage("9 != 10");
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoLeavesHandlerFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(2);
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    total += bump(2);
                    goto outside;
                    total += bump(99);
                }

            outside:
                total += bump(3);
                assert(total == 9);
            }
        }).shouldThrowWithMessage("10 != 9");
    }
}

static foreach (backend; backends) {

    @("finallyThrowChainsBodyException." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int length(string value) {
                return cast(int) value.length;
            }

            unittest {
                int encoded;
                try {
                    try {
                        throw new Exception("body");
                    } finally {
                        throw new Exception("finally");
                    }
                } catch (Exception caught) {
                    encoded = length(caught.msg) * 10
                        + length(caught.next.msg);
                }

                assert(encoded == 47);
            }
        });
    }
}

static foreach (backend; backends) {

    @("finallyThrowChainsBodyExceptionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int length(string value) {
                return cast(int) value.length;
            }

            unittest {
                int encoded;
                try {
                    try {
                        throw new Exception("body");
                    } finally {
                        throw new Exception("finally");
                    }
                } catch (Exception caught) {
                    encoded = length(caught.msg) * 10
                        + length(caught.next.msg);
                }

                assert(encoded == 48);
            }
        }).shouldThrowWithMessage("47 != 48");
    }
}

static foreach (backend; backends) {

    @("finallyThrowChainsBodyExceptionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int length(string value) {
                return cast(int) value.length;
            }

            unittest {
                int encoded;
                try {
                    try {
                        throw new Exception("other");
                    } finally {
                        throw new Exception("finally");
                    }
                } catch (Exception caught) {
                    encoded = length(caught.msg) * 10
                        + length(caught.next.msg);
                }

                assert(encoded == 47);
            }
        }).shouldThrowWithMessage("57 != 47");
    }
}

static foreach (backend; backends) {

    @("catchHandlerRuns." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchHandlerRunsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("catchHandlerRunsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

module ut.backends.runner.ct.exceptions;


import ut.backends;


/++
    Throwing and basic catch semantics.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("exception.uncaughtThrowReportsMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("boom");
            }
        }).shouldThrowWithMessage(
            "uncaught CTFE exception `object.Exception(\"boom\")`",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("exception.uncaughtThrowPreservesExceptionMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("domain failure");
            }
        }).shouldThrowWithMessage(
            "uncaught CTFE exception `object.Exception(\"domain failure\")`",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("exception.catchExceptionDoesNotCatchAssertFailure." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchExceptionCatchesThrownException." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchExceptionBindsCaughtObject." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchSkipsNonMatchingSiblingException." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Interpreter, Bytecode, and IR all report TryCatch as an unsupported
// statement.
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchByBaseReadsDerivedField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class MyError : Exception {
                int code;

                this(int c) {
                    super("boom");
                    code = c;
                }
            }

            int run(int seed) {
                try {
                    if (seed > 0) throw new MyError(seed + 40);
                    return 0;
                } catch (Exception e) {
                    return (cast(MyError) e).code;
                }
            }

            unittest {
                assert(run(2) == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.throwExpressionInConditionalIsCaught." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchExceptionCatchesThrownExceptionFromCalledFunction." ~
        backend.stringof)
    @Tags(backend.stringof)
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


/++
    Throws from callees after side effects.
+/
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchThrowAfterCalleeSideEffect." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchNestedBranchThrowFromCalledFunction." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.catchRuntimeBranchThrowFromCalledFunction." ~ backend.stringof)
    @Tags(backend.stringof)
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

                // Runtime data selects the branch, so lowering cannot prove the
                // throw path syntactically.
                assert(caught == 1);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("exception.throwAfterRuntimeBranchPreservesRefSideEffect." ~
        backend.stringof)
    @Tags(backend.stringof)
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

                assert(caught == 1);
                assert(marker == 1);
            }
        });
    }
}


/++
    Finally.
+/
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.runsFinalbody." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.runsFinalbodyBeforeCatch." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.runsAfterReturn." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.returnCapturesValueBeforeFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.branchReturnsCaptureValueBeforeFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.throwChainsBodyException." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Goto through try/finally and catch handlers.
+/
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.gotoWithinBodyRunsFinallyOnce." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("finally.gotoOutOfBodyRunsFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("catch.gotoResumesInsideHandler." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("catch.gotoLeavesHandler." ~ backend.stringof)
    @Tags(backend.stringof)
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

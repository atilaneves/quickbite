module ut.backends.runner.lang.exceptions;


import ut.backends;


/++
    Throwing and basic catch semantics.
+/
// Ctfe diverges: it wraps the throw in an "uncaught CTFE exception" message
// rather than reporting the exception's own message. SystemLinker (compiled
// code with -checkaction=context) reports "boom" directly.
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

// Compiled code (dmd -unittest -checkaction=context) reports the exception's
// own message; the "uncaught CTFE exception" wrapper is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (CTFE wraps in \"uncaught CTFE exception\" message)"),
)) {
    @("exception.uncaughtThrowReportsMessage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("boom");
            }
        }).shouldThrowWithMessage("boom");
    }
}

// Ctfe diverges: see exception.uncaughtThrowReportsMessage above.
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

// Compiled code reports the exception's own message (see above).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (CTFE wraps in \"uncaught CTFE exception\" message)"),
)) {
    @("exception.uncaughtThrowPreservesExceptionMessage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("domain failure");
            }
        }).shouldThrowWithMessage("domain failure");
    }
}

// Ctfe diverges: a literal `assert(false)` failure is reported as
// "`assert(false)` failed", whereas compiled code raises the plain
// _d_unittest hook message "unittest failure".
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

// Compiled `assert(false)` in a unittest body raises the plain _d_unittest
// hook message "unittest failure"; "`assert(false)` failed" is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (`assert(false)` failed is CTFE-only)"),
)) {
    @("exception.catchExceptionDoesNotCatchAssertFailure." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                try {
                    assert(false);
                } catch (Exception) {
                }
            }
        }).shouldThrowWithMessage("unittest failure");
    }
}

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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


// Returning from a function exits its scope-failure handler. A later exception
// in the caller must not run the returned function's failure statement.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "CTFE wraps uncaught exception messages"),
)) {
    @("exception.returnFromTryRemovesHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int protectedReturn() {
                scope(failure) throw new Exception("stale");
                return 7;
            }

            unittest {
                assert(protectedReturn == 7);
                throw new Exception("later");
            }
        }).shouldThrowWithMessage("later");
    }
}

// A `return` inside a `catch`-protected try body must drop that try's
// handler before an enclosing `finally` runs, even though the enclosing
// `finally` is itself lexically inside the same protected try body: the
// `finally`'s own throw must reach whatever wraps the whole
// try/catch/finally, not the sibling catch it is textually nested beside.
// A stale handler would route the finally's throw into that catch instead,
// running the finally a second time (once for the try body's own return,
// once more for the catch body's) before the throw finally escapes with the
// same message either way, so `finallyRuns` -- not just the message --
// tells the two apart.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a module-level variable mutated across a "
        ~ "function call: `static variable 'finallyRuns' cannot be read "
        ~ "at compile time`, reproduced with stock dmd on the same shape"),
)) {
    @("exception.returnPopsHandlerBeforeEnclosingFinallyRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int finallyRuns;

            // The `if (cond) throw` keeps the compiler from proving the try
            // body can never throw and eliding the catch entirely -- it
            // still runs the `return` path below at runtime.
            int f(bool cond) {
                try {
                    try {
                        if (cond)
                            throw new Exception("nope");
                        return 1;
                    } catch (Exception) {
                        return 2;
                    }
                } finally {
                    finallyRuns++;
                    throw new Exception("fin");
                }
            }

            unittest {
                try {
                    f(false);
                    assert(0, "expected an exception");
                } catch (Exception e) {
                    assert(e.msg == "fin");
                    assert(finallyRuns == 1);
                }
            }
        });
    }
}

// A `break` out of a `catch`-protected try body must drop that try's handler:
// once the loop containing it has finished, a later exception must not be
// caught by a handler for a try body no loop iteration is inside any more.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "see sibling pin above (CTFE wraps in \"uncaught CTFE exception\" "
        ~ "message)"),
)) {
    @("exception.breakPopsCatchProtectedTryHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            // The `if (cond) throw` keeps the compiler from proving the try
            // body can never throw and eliding the catch entirely -- the
            // `break` below is what actually runs at runtime.
            void g(bool cond) {
                foreach (i; 0 .. 3) {
                    try {
                        if (cond)
                            throw new Exception("nope");
                        if (i == 0)
                            break;
                    } catch (Exception) {
                        assert(0, "stale");
                    }
                }
                throw new Exception("later");
            }

            unittest {
                g(false);
            }
        }).shouldThrowWithMessage("later");
    }
}

// A runtime bounds failure creates a RangeError object whose reference remains
// an ordinary class value when passed to native code. The native function must
// receive the same object pointer that compiled D passes.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call body-less _d_print_throwable"),
)) {
    @("exception.nativeFunctionAcceptsCaughtRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.exception: RangeError;

            extern(C) void _d_print_throwable(Throwable);

            unittest {
                int[] values;

                try {
                    auto ignored = values[0];
                } catch (RangeError error) {
                    _d_print_throwable(error);
                }
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("exception.catchBindingIdentityMatchesPointerDereference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                Exception* p;

                try {
                    throw new Exception("x");
                } catch (Exception e) {
                    p = &e;
                    assert(*p is e);
                }
            }
        });
    }
}

static foreach (backend; Matrix!()) {
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

// Bytecode and IR both report TryCatch as an unsupported statement.
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
    @("exception.returnFromTryDoesNotCatchLaterThrow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int returnFromTry(int seed) {
                try {
                    if (seed == 0)
                        return seed + 1;
                    throw new Exception("unexpected");
                } catch (Exception) {
                    return -1;
                }
            }

            int throwLater(int value) {
                if (value == 0)
                    throw new Exception("later");
                return value;
            }

            unittest {
                int seed;
                int value = returnFromTry(seed);

                assert(value == 1);
                throwLater(value - 1);
            }
        }).shouldThrow;
    }
}


/++
    Finally.
+/
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
    @("finally.runsOnceWhenCatchExits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int run(bool rethrow) {
                int finallyRuns;
                int caughtCount;

                try {
                    try {
                        throw new Exception("body");
                    } catch (Exception e) {
                        caughtCount += 1;
                        if (rethrow)
                            throw e;
                        else
                            throw new Exception("from catch");
                    } finally {
                        finallyRuns += 1;
                    }
                } catch (Exception e) {
                }

                return caughtCount * 100 + finallyRuns;
            }

            unittest {
                assert(run(true) == 101);
                assert(run(false) == 101);
            }
        });
    }
}

// A `finally` between the throw site and the catch that actually matches
// must run even when a nearer, sibling catch's type does not match the
// thrown exception at runtime -- the throw skips it for the outer handler,
// and the finally in between is not exempt just because *some* catch was
// lexically nearer.
static foreach (backend; Matrix!()) {
    @("finally.runsWhenNearerCatchTypeMismatches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Special : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            int run() {
                int order;

                try {
                    try {
                        try {
                            throw new Exception("x");
                        } catch (Special e) {
                            order += 1;
                        }
                    } finally {
                        order += 10;
                    }
                } catch (Exception e) {
                    order += 100;
                }

                return order;
            }

            unittest {
                assert(run() == 110);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
    @("exception.rethrowPropagatesToOuterHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int run(int seed) {
                try {
                    try {
                        if (seed > 0) throw new Exception("rethrown");
                        return 0;
                    } catch (Exception e) {
                        throw e;
                    }
                } catch (Exception e) {
                    if (e.msg == "rethrown") return seed + 40;
                    return -1;
                }
            }

            unittest {
                assert(run(2) == 42);
            }
        });
    }
}

// Bytecode and IR both report TryCatch as an unsupported statement.
static foreach (backend; Matrix!()) {
    @("exception.multipleCatchClausesSelectByDynamicType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class FormatError : Exception {
                this(string message) { super(message); }
            }

            int classify(int seed) {
                try {
                    if (seed == 1) throw new FormatError("format");
                    throw new Exception("plain");
                } catch (FormatError e) {
                    return 10;
                } catch (Exception e) {
                    return 20;
                }
            }

            unittest {
                assert(classify(1) == 10);
                assert(classify(2) == 20);
            }
        });
    }
}

// Bytecode and IR both report TryCatch as an unsupported statement.
static foreach (backend; Matrix!()) {
    @("exception.errorIsNotCaughtByExceptionHandler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int run(int seed) {
                try {
                    try {
                        if (seed > 0) throw new Error("fatal");
                        return 0;
                    } catch (Exception e) {
                        return 1;
                    }
                } catch (Error e) {
                    return 2;
                }
            }

            unittest {
                assert(run(1) == 2);
            }
        });
    }
}

module ut.backends.parity;


import ut.backends;


private:

import std.conv: text;
import ut.backends:
    dmdCodegenRamExecutorBackends,
    experimentalBackendTestsEnabled,
    matureExecutorBackends;
import unit_threaded;


static foreach (backend; matureExecutorBackends) {
    @("throwingTest." ~ backend.text)
    unittest {
        if (backend != ExecutorBackend.dmdCodegenRam || experimentalBackendTestsEnabled) {
            runTests(q{
                unittest {
                    throw new Exception("boom");
                }
            }, backend).shouldThrowWithMessage("boom");
        }
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

                    // Unlike earlier catch-call tests, runtime data selects
                    // the branch, so lowering cannot prove the throw path
                    // syntactically.
                    assert(caught == 1);
                    assert(marker == 1);
                }
            }, backend);
        }
    }

    @("throwPreservesExceptionMessage." ~ backend.text)
    unittest {
        expectRunTestsFailure(q{
            unittest {
                throw new Exception("domain failure");
            }
        }, backend, "domain failure");
    }

    @("shouldThrowFailsWhenExpressionDoesNotThrow." ~ backend.text)
    unittest {
        import ut.dub_paths: dubImportPaths;

        expectRunTestsFailure(q{
            import unit_threaded;

            unittest {
                shouldThrow(1);
            }
        }, dubImportPaths, backend);
    }

    @("shouldThrowWithMessageChecksMessage." ~ backend.text)
    unittest {
        import ut.dub_paths: dubImportPaths;

        expectRunTestsFailure(q{
            import unit_threaded;

            void throwActual() {
                throw new Exception("actual");
            }

            unittest {
                shouldThrowWithMessage(throwActual, "expected");
            }
        }, dubImportPaths, backend);
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

    static if (backend == ExecutorBackend.ir) {
        @("evaluatesRuntimePowDoubleInputs." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: pow;

                unittest {
                    double base = 2.0;
                    double exponent = 4.0;
                    assert(pow(base, exponent) == 16.0);

                    base = 9.0;
                    exponent = 0.5;
                    double root = pow(base, exponent);
                    assert(root > 2.999);
                    assert(root < 3.001);

                    base = 4.0;
                    exponent = -1.0;
                    assert(pow(base, exponent) == 0.25);
                }
            }, backend);
        }

        @("doesNotTreatUserNamedPowAsMathIntrinsic." ~ backend.text)
        unittest {
            runTests(q{
                double pow(double base, double exponent) {
                    return base + exponent;
                }

                unittest {
                    double base = 2.0;
                    double exponent = 4.0;
                    assert(pow(base, exponent) == 6.0);
                }
            }, backend);
        }

        @("evaluatesRuntimeSqrtInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: sqrt;

                unittest {
                    double input = 9.0;
                    assert(sqrt(input) == 3.0);
                }
            }, backend);
        }

        @("evaluatesDifferentRuntimeSqrtInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: sqrt;

                unittest {
                    double input = 16.0;
                    assert(sqrt(input) == 4.0);
                }
            }, backend);
        }

        @("evaluatesRuntimeNonIntegerSqrtInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: sqrt;

                unittest {
                    double input = 2.25;
                    assert(sqrt(input) == 1.5);
                }
            }, backend);
        }

        @("evaluatesRuntimeNonPerfectSqrtInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: sqrt;

                unittest {
                    double input = 2.0;
                    double result = sqrt(input);
                    assert(result > 1.414);
                    assert(result < 1.415);
                }
            }, backend);
        }

        @("evaluatesRuntimeFabsDoubleInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: fabs;

                unittest {
                    double first = -3.5;
                    double second = -12.25;
                    assert(fabs(first) == 3.5);
                    assert(fabs(second) == 12.25);
                }
            }, backend);
        }

        @("evaluatesRuntimeFabsPositiveDoubleInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: fabs;

                unittest {
                    double input = 7.75;
                    assert(fabs(input) == 7.75);
                }
            }, backend);
        }

        @("evaluatesRuntimeIsNaNDoubleInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: isNaN;

                unittest {
                    double notANumber = double.nan;
                    double finite = 21.0;

                    assert(isNaN(notANumber));
                    assert(!isNaN(finite));
                }
            }, backend);
        }

        @("evaluatesRuntimeIsInfinityDoubleInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: isInfinity;

                unittest {
                    double input = double.infinity;
                    assert(isInfinity(input));

                    input = -double.infinity;
                    assert(isInfinity(input));

                    input = double.max;
                    assert(!isInfinity(input));

                    input = double.nan;
                    assert(!isInfinity(input));
                }
            }, backend);
        }

        @("evaluatesRuntimeSignbitDoubleInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: signbit;

                unittest {
                    double input = -0.0;
                    assert(signbit(input) != 0);

                    input = 0.0;
                    assert(signbit(input) == 0);

                    input = -12.25;
                    assert(signbit(input) != 0);

                    input = 12.25;
                    assert(signbit(input) == 0);
                }
            }, backend);
        }

        @("evaluatesRuntimeSignbitNanInput." ~ backend.text)
        unittest {
            runTests(q{
                import std.math: signbit;

                unittest {
                    double input = -double.nan;
                    assert(signbit(input) != 0);

                    input = double.nan;
                    assert(signbit(input) == 0);
                }
            }, backend);
        }

        @("doesNotTreatUserNamedIsNaNAsMathIntrinsic." ~ backend.text)
        unittest {
            runTests(q{
                bool isNaN(double value) {
                    return true;
                }

                unittest {
                    double input = 21.0;
                    assert(isNaN(input));
                }
            }, backend);
        }

        @("callsUserNamedIsNaNForNanInput." ~ backend.text)
        unittest {
            runTests(q{
                bool isNaN(double value) {
                    return false;
                }

                unittest {
                    double input = double.nan;
                    assert(!isNaN(input));
                }
            }, backend);
        }

        @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsics." ~ backend.text)
        unittest {
            runTests(q{
                double sqrt(double value) {
                    return value + 1.0;
                }

                double fabs(double value) {
                    return value + 2.0;
                }

                unittest {
                    double input = 9.0;
                    assert(sqrt(input) == 10.0);
                    assert(fabs(input) == 11.0);
                }
            }, backend);
        }
    }

}

@("dmdCtfe fallback reports the failing unittest, not tree-walker support")
unittest {
    runTests(q{
        void set(out int x) {
            x = 42;
        }

        unittest {
            int x;
            set(x);
            assert(x == 42);
        }

        bool nope() {
            return false;
        }

        void fail() {
            assert(nope());
        }

        unittest {
            fail();
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("false != true");
}

@("unitThreadedCheckRunsPredicate.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    expectRunTestsFailure(q{
        import unit_threaded;

        unittest {
            check!((int value) => false);
        }
    }, dubImportPaths, ExecutorBackend.treeWalkingOld, "Property failed. Seed: 1. Input: 1");
}

private void expectRunTestsFailure(
    in string source,
    in ExecutorBackend backend,
    in string expectedMessage,
) {
    string[] importPaths;
    expectRunTestsFailure(source, importPaths, backend, expectedMessage);
}

private void expectRunTestsFailure(
    in string source,
    in string[] importPaths,
    in ExecutorBackend backend,
) {
    bool threw;
    try {
        runTests(source, importPaths, backend);
    } catch (Exception) {
        threw = true;
    }
    threw.should == true;
}

private void expectRunTestsFailure(
    in string source,
    in string[] importPaths,
    in ExecutorBackend backend,
    in string expectedMessage,
) {
    bool threw;
    try {
        runTests(source, importPaths, backend);
    } catch (Exception exception) {
        threw = true;
        exception.msg.should == expectedMessage;
    }
    threw.should == true;
}

static foreach (backend; dmdCodegenRamExecutorBackends) {
    @(text("ok.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 42);
                }
            }, backend);
        }
    }

    @(text("assertionContext.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    int expected = 43;
                    assert(answer == expected);
                }
            }, backend).shouldThrowWithMessage("42 != 43");
        }
    }

    @(text("throwingTest.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                unittest {
                    throw new Exception("boom");
                }
            }, backend).shouldThrowWithMessage("boom");
        }
    }

    @(text("__gsharedIntRead.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                __gshared int value = 41;

                int answer() {
                    return value + 1;
                }

                unittest {
                    assert(answer == 42);
                }
            }, backend);
        }
    }

    @(text("moduleIntRead.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int value = 41;

                int answer() {
                    // Unlike __gshared, default module variables are D TLS.
                    // The RAM backend must handle DMD's TLS relocation path
                    // instead of only the normal global/GOT access shape.
                    return value + 1;
                }

                unittest {
                    assert(answer == 42);
                }
            }, backend);
        }
    }

    @(text("zeroInitializedModuleIntRead.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int value;

                int answer() {
                    return value + 1;
                }

                unittest {
                    assert(answer == 1);
                }
            }, backend);
        }
    }

    @(text("userDefinedTlsGetAddrCall.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                __gshared int calls;

                extern(C) void __tls_get_addr() {
                    calls = 41;
                }

                void answer() {
                    __tls_get_addr();
                }

                unittest {
                    calls = 1;
                    answer();
                    assert(calls == 41);
                }
            }, backend);
        }
    }

}

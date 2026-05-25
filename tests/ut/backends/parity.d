module ut.backends.parity;


import ut.backends;


private:

import std.conv: text;
import std.meta: AliasSeq;
import ut.backends:
    dmdCodegenRamExecutorBackends,
    experimentalBackendTestsEnabled,
    matureExecutorBackends;
import unit_threaded;


static foreach (backend; matureExecutorBackends ~ [
    ExecutorBackend.bytecode,
    ExecutorBackend.treeWalking,
]) {
    @("voidFunctionReturnsToCaller." ~ backend.text)
    unittest {
        q{
            int one() {
                return 1;
            }

            void foo() {}

            unittest {
                foo;
                // Keep this runtime-shaped so DMD does not constant-fold it
                // before the backend sees the equality expression.
                assert(one == 2);
            }
        }.expectBackendFailure(backend, "1 != 2");
    }

    @("intAddition." ~ backend.text)
    unittest {
        runTests(q{
            int one() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the addition before the backend sees it.
                return one + 41;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("intSubtraction." ~ backend.text)
    unittest {
        runTests(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the subtraction before the backend sees it.
                return 44 - two;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("intMultiplication." ~ backend.text)
    unittest {
        runTests(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the multiplication before the backend sees it.
                return 21 * two;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("intDivision." ~ backend.text)
    unittest {
        runTests(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the division before the backend sees it.
                return 84 / two;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("intModulo." ~ backend.text)
    unittest {
        runTests(q{
            int divisor() {
                return 44;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the modulo before the backend sees it.
                return 86 % divisor;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("intShiftRight." ~ backend.text)
    unittest {
        runTests(q{
            int shift() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the right shift before the backend sees it.
                return 0x80 >> shift;
            }

            unittest {
                assert(answer == 0x20);
            }
        }, backend);
    }

    @("intShiftLeft." ~ backend.text)
    unittest {
        runTests(q{
            int shift() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the left shift before the backend sees it.
                return 0x10 << shift;
            }

            unittest {
                assert(answer == 0x20);
            }
        }, backend);
    }

    @("intBitwiseOr." ~ backend.text)
    unittest {
        runTests(q{
            int mask() {
                return 0x06;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise OR before the backend sees it.
                return 0x2a | mask;
            }

            unittest {
                assert(answer == 0x2e);
            }
        }, backend);
    }

    @("intBitwiseAnd." ~ backend.text)
    unittest {
        runTests(q{
            int mask() {
                return 0x2f;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise AND before the backend sees it.
                return mask & 0x3a;
            }

            unittest {
                assert(answer == 0x2a);
            }
        }, backend);
    }

    @("intBitwiseXor." ~ backend.text)
    unittest {
        runTests(q{
            int mask() {
                return 0x04;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise XOR before the backend sees it.
                return 0x2e ^ mask;
            }

            unittest {
                assert(answer == 0x2a);
            }
        }, backend);
    }

    @("intLessThan." ~ backend.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(41 < bound);
            }
        }, backend);
    }

    @("intLessThanOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 < bound);
            }
        }.expectBackendFailure(backend, "42 >= 42");
    }

    @("intLessOrEqual." ~ backend.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 <= bound);
            }
        }, backend);
    }

    @("intLessOrEqualOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 <= bound);
            }
        }.expectBackendFailure(backend, "43 > 42");
    }

    @("intGreaterThan." ~ backend.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 > bound);
            }
        }, backend);
    }

    @("intGreaterThanOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 > bound);
            }
        }.expectBackendFailure(backend, "42 <= 42");
    }

    @("intGreaterOrEqual." ~ backend.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 >= bound);
            }
        }, backend);
    }

    @("intGreaterOrEqualOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(41 >= bound);
            }
        }.expectBackendFailure(backend, "41 < 42");
    }

    @("intNotEqual." ~ backend.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 != bound);
            }
        }, backend);
    }

    @("intNotEqualOops." ~ backend.text)
    unittest {
        q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(bound != 42);
            }
        }.expectBackendFailure(backend, "42 == 42");
    }

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

private void expectBackendFailure(
    in string source,
    in ExecutorBackend backend,
    in string extraBackendMessage,
) {
    bool threw;
    try {
        runTests(source, backend);
    } catch (Exception exception) {
        threw = true;
        if (
            backend == ExecutorBackend.bytecode ||
            backend == ExecutorBackend.treeWalking
        ) {
            exception.msg.should == extraBackendMessage;
        }
    }
    threw.should == true;
}

static foreach (backend; matureExecutorBackends) {
    @("ok." ~ backend.text)
    unittest {
        if (backend != ExecutorBackend.dmdCodegenRam || experimentalBackendTestsEnabled) {
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

    @("oops." ~ backend.text)
    unittest {
        if (backend != ExecutorBackend.dmdCodegenRam || experimentalBackendTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 43);
                }
            }, backend).shouldThrowWithMessage("42 != 43");
        }
    }

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

    @("distinguishesFloatingPointValues." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                double left = 1.5;
                double right = 2.5;
                assert(left != right);
            }
        }, backend);
    }

    @("supportsContinue." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int sum;
                for (int i = 0; i < 4; ++i) {
                    if (i == 2)
                        continue;
                    sum += i;
                }
                assert(sum == 4);
            }
        }, backend);
    }

    @("supportsSwitch." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value = 2;
                int result;
                switch (value) {
                    case 1:
                        result = 10;
                        break;
                    case 2:
                        result = 20;
                        break;
                    default:
                        result = 30;
                        break;
                }
                assert(result == 20);
            }
        }, backend);
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

    @("evaluatesPow." ~ backend.text)
    unittest {
        runTests(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 8.0);
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

    @("functionPointerHashCollisionDetected." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                // bAB and a_a produce the same Bernstein hash (602706).
                static int bAB() {
                    return 1;
                }

                static int a_a() {
                    return 2;
                }

                int function() fp = &a_a;
                assert(fp() == 2);
            }
        }, backend);
    }

    @("nestedSliceWritesPropagateToOriginalArray." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 4];
                int[] s2 = s[0 .. 2];
                s2[0] = 99;
                assert(a[1] == 99);
            }
        }, backend);
    }

    static if (backend == ExecutorBackend.ir) {
        @("nestedSliceAppendWritesThroughOuterSliceToOriginalArray." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    int[] a = [0, 1, 2, 3, 4];
                    int[] s = a[1 .. 3];
                    int[] s2 = s[1 .. 2];
                    s2 ~= 99;
                    assert(a[3] == 99);
                }
            }, backend);
        }
    }

    @("localIntReturn." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("localIntReturnOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 43);
            }
        }, backend).shouldThrowWithMessage("42 != 43");
    }

    @("voidFunction." ~ backend.text)
    unittest {
        runTests(q{
            void foo() {}

            unittest {
                foo;
            }
        }, backend);
    }

    @("structMethodPostIncrementsSizeTField." ~ backend.text)
    unittest {
        runTests(q{
            struct Cursor {
                size_t pos;

                size_t next() {
                    return pos++;
                }
            }

            unittest {
                Cursor cursor;
                assert(cursor.next == 0);
                assert(cursor.pos == 1);
            }
        }, backend);
    }

    @("structMethodReadsArrayFieldAtPostIncrementedField." ~ backend.text)
    unittest {
        runTests(q{
            struct Reader {
                ubyte[] bytes;
                size_t pos;

                ubyte next() {
                    return bytes[pos++];
                }
            }

            unittest {
                Reader reader;
                reader.bytes = [42];
                assert(reader.next == 42);
                assert(reader.pos == 1);
            }
        }, backend);
    }

    @("foreachArray." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                int sum = 0;
                foreach (x; arr)
                    sum = sum + x;
                assert(sum == 6);
            }
        }, backend);
    }

    @("foreachEmptyArray." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                int count = 0;
                foreach (x; arr)
                    count = count + 1;
                assert(count == 0);
            }
        }, backend);
    }

    @("whileNeverRuns." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                while (i > 0) {
                    i = i + 1;
                }
                return 42;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("whileRunsOnce." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 1) {
                    result = 42;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("while_." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 6) {
                    result = result + 7;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("voidFunctionExplicitReturn." ~ backend.text)
    unittest {
        runTests(q{
            void foo() {
                return;
            }

            unittest {
                foo;
            }
        }, backend);
    }

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("voidFunctionOops." ~ backend.text)
        unittest {
            runTests(q{
                void foo() {
                    assert(0);
                }

                unittest {
                    foo;
                }
            }, backend).shouldThrowWithMessage("Assertion failure");
        }
    }

    @("intUnaryMinus." ~ backend.text)
    unittest {
        runTests(q{
            int input() {
                return 42;
            }

            int answer() {
                return -input;
            }

            unittest {
                assert(answer == -42);
            }
        }, backend);
    }

    @("intBitwiseComplement." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x2a;
                assert(~value == -0x2b);
            }
        }, backend);
    }

    @("intOrAssign." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x28u;
                value |= 0x02u;
                assert(value == 0x2au);
            }
        }, backend);
    }

    @("intSubtractAssign." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 44;
                value -= 2;
                assert(value == 42);
            }
        }, backend);
    }

    @("intAddAssign." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 40;
                value += 2;
                assert(value == 42);
            }
        }, backend);
    }

    @("ubyteAddAssignWrapsOnStore." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte value = 255;
                value += 1;
                assert(value == 0);
            }
        }, backend);
    }

    @("ubyteArrayAppendAssign." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto values = [0x2au];
                values ~= 0x2bu;
                assert(values.length == 2);
            }
        }, backend);
    }

    @("ubyteArrayIndexRead." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                assert(values[1] == 0x2au);
            }
        }, backend);
    }

    @("ubyteArrayIndexWrite." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];
                values[1] = 0x2au;
                assert(values[1] == 0x2au);
            }
        }, backend);
    }

    @("refUbyteArrayParameterAppend." ~ backend.text)
    unittest {
        runTests(q{
            void appendAnswer(ref ubyte[] values) {
                values ~= 0x2au;
            }

            unittest {
                ubyte[] values = [];
                appendAnswer(values);
                assert(values.length == 1);
                assert(values[0] == 0x2au);
            }
        }, backend);
    }

    @("functionParameter." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 42);
            }
        }, backend);
    }

    @("functionParameters." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 2) == 42);
            }
        }, backend);
    }

    @("functionParametersOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 3) == 42);
            }
        }, backend).shouldThrowWithMessage("43 != 42");
    }

    @("functionParameterOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 43);
            }
        }, backend).shouldThrowWithMessage("42 != 43");
    }

    @("refParameter." ~ backend.text)
    unittest {
        runTests(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 42);
            }
        }, backend);
    }

    static if (backend != ExecutorBackend.dmdCtfe) {
        @("refParameterOops." ~ backend.text)
        unittest {
            runTests(q{
                void addOne(ref int value) {
                    value = value + 1;
                }

                unittest {
                    int value = 41;
                    addOne(value);
                    assert(value == 43);
                }
            }, backend).shouldThrowWithMessage("42 != 43");
        }
    }

    @("ulongHighBitLessThan." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL < value);
            }
        }, backend);
    }

    @("ifBodyAssignment." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    value = 2;

                return value;
            }

            unittest {
                assert(answer(1) == 2);
            }
        }, backend);
    }

    @("ifElse." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 43);
            }
        }, backend);
    }

    @("ifElseOops." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(2) == 42);
            }
        }, backend).shouldThrowWithMessage("43 != 42");
    }

    @("ifElseUntakenBranch." ~ backend.text)
    unittest {
        runTests(q{
            int zero() {
                return 0;
            }

            int answer(bool left) {
                if (left)
                    return 42;
                else
                    return 42 / zero;
            }

            unittest {
                assert(answer(true) == 42);
            }
        }, backend);
    }

    @("earlyReturn." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 43);
            }
        }, backend);
    }

    @("multipleEarlyReturns." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 41;

                if (value == 2)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 41);
                assert(answer(2) == 42);
                assert(answer(3) == 43);
            }
        }, backend);
    }

    @("inFunctionParameters." ~ backend.text)
    unittest {
        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 2);
            }
        }, backend);
    }

    static if (backend != ExecutorBackend.dmdCtfe) {
        @("inFunctionParametersOops." ~ backend.text)
        unittest {
            runTests(q{
                void check(in int left, in int right) {
                    assert(left + right == 42);
                }

                unittest {
                    check(40, 3);
                }
            }, backend).shouldThrowWithMessage("43 != 42");
        }
    }

    @("multipleRefParameters." ~ backend.text)
    unittest {
        runTests(q{
            void add(int left, ref int right) {
                right = left + right;
            }

            unittest {
                int value = 2;
                add(40, value);
                assert(value == 42);
            }
        }, backend);
    }

    @("refSizeTParameter." ~ backend.text)
    unittest {
        runTests(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 42);
            }
        }, backend);
    }

    static if (backend != ExecutorBackend.dmdCtfe) {
        @("refSizeTParameterOops." ~ backend.text)
        unittest {
            runTests(q{
                void advance(ref size_t pos) {
                    pos = pos + 1;
                }

                unittest {
                    size_t pos = 41;
                    advance(pos);
                    assert(pos == 43);
                }
            }, backend).shouldThrowWithMessage("42 != 43");
        }
    }

    @("longLiteral." ~ backend.text)
    unittest {
        runTests(q{
            long answer() {
                return 2_147_483_648L;
            }

            unittest {
                assert(answer > 0L);
            }
        }, backend);
    }

    @("ulongHighBitLessOrEqual." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL <= value);
            }
        }, backend);
    }

    @("ulongHighBitGreaterOrEqual." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value >= 0UL);
            }
        }, backend);
    }

    @("ulongHighBitGreaterThan." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value > 0UL);
            }
        }, backend);
    }

    @("structPassedToFunction." ~ backend.text)
    unittest {
        runTests(q{
            struct Point {
                int x;
                int y;
            }

            int sum(Point p) {
                return p.x + p.y;
            }

            unittest {
                Point p;
                p.x = 21;
                p.y = 21;
                assert(sum(p) == 42);
            }
        }, backend);
    }

    @("scalarStructPassedToFunction." ~ backend.text)
    unittest {
        runTests(q{
            struct Value {
                int value;
            }

            int read(Value wrapper) {
                return wrapper.value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 42;
                assert(read(wrapper) == 42);
            }
        }, backend);
    }

    @("structByValueMutationDoesNotLeak." ~ backend.text)
    unittest {
        runTests(q{
            struct Point { int x; }
            void mutate(Point p) { p.x = 99; }
            unittest {
                Point p;
                p.x = 5;
                mutate(p);
                assert(p.x == 5);
            }
        }, backend);
    }

    @("structByValueArrayFieldMutationDoesNotLeak." ~ backend.text)
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                mutate(buffer);
                assert(buffer.bytes.length == 0);
            }
        }, backend);
    }

    @("structByValueArrayFieldElementMutationLeaks." ~ backend.text)
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes[0] = 99;
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [cast(ubyte) 1];
                mutate(buffer);
                assert(buffer.bytes[0] == 99);
            }
        }, backend);
    }

    @("scalarStructField." ~ backend.text)
    unittest {
        runTests(q{
            struct Value {
                int value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 42;
                assert(wrapper.value == 42);
            }
        }, backend);
    }

    @("arrayLength." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                assert(arr.length == 3);
            }
        }, backend);
    }

    @("emptyArrayLength." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                assert(arr.length == 0);
            }
        }, backend);
    }

    @("arrayEqualTrue." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 3];
                assert(a[] == b[]);
            }
        }, backend);
    }

    static if (backend != ExecutorBackend.ir) {
        @("arrayEqualFalse." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    ubyte[] a = [1, 2, 3];
                    ubyte[] b = [1, 2, 4];
                    assert(a[] == b[]);
                }
            }, backend).shouldThrowWithMessage("[1, 2, 3] != [1, 2, 4]");
        }
    }

    @("castUbyteRuntimeValueTruncates." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                assert(cast(ubyte) value == 2);
            }
        }, backend);
    }

    @("ubyteLocalTruncatesOnStore." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int source = 258;
                ubyte value = cast(ubyte) source;
                assert(value == 2);
            }
        }, backend);
    }

    @("ubyteArrayLiteralTruncatesElements." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];
                assert(arr[0] == 2);
            }
        }, backend);
    }

    @("struct_." ~ backend.text)
    unittest {
        runTests(q{
            struct Point {
                int x;
                int y;
            }

            int answer() {
                Point p;
                p.x = 21;
                p.y = 21;
                return p.x + p.y;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("structFieldDefaultsToZero." ~ backend.text)
    unittest {
        runTests(q{
            struct Point {
                int x;
                int y;
            }

            int answer() {
                Point p;
                p.x = 42;
                return p.x + p.y;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("structArrayFieldDefaultsToEmpty." ~ backend.text)
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            unittest {
                Buffer buffer;
                assert(buffer.bytes.length == 0);
            }
        }, backend);
    }

    @("refStructArrayFieldParameter." ~ backend.text)
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void append42(ref ubyte[] output) {
                output ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                append42(buffer.bytes);
                assert(buffer.bytes.length == 1);
                assert(buffer.bytes[0] == 42);
            }
        }, backend);
    }

    @("structMethodReadsField." ~ backend.text)
    unittest {
        runTests(q{
            struct Box {
                int value;

                int get() {
                    return value;
                }
            }

            unittest {
                Box box;
                box.value = 42;
                assert(box.get == 42);
            }
        }, backend);
    }

    @("structMethodPassesFieldByRef." ~ backend.text)
    unittest {
        runTests(q{
            void append42(ref ubyte[] output) {
                output ~= cast(ubyte) 42;
            }

            struct Buffer {
                ubyte[] bytes;

                void append() {
                    append42(bytes);
                }
            }

            unittest {
                Buffer buffer;
                buffer.append;
                assert(buffer.bytes.length == 1);
                assert(buffer.bytes[0] == 42);
            }
        }, backend);
    }

    @("structTemplateMethodPassesFieldByRef." ~ backend.text)
    unittest {
        runTests(q{
            void appendValue(T)(T value, ref ubyte[] output) {
                output ~= cast(ubyte) value;
            }

            struct Buffer {
                ubyte[] bytes;

                void append(T)(T value) {
                    appendValue(value, bytes);
                }
            }

            unittest {
                Buffer buffer;
                buffer.append(42);
                assert(buffer.bytes.length == 1);
                assert(buffer.bytes[0] == 42);
            }
        }, backend);
    }

    @("structMethodIndexWritesArrayField." ~ backend.text)
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;

                void patchFirst() {
                    bytes[0] = cast(ubyte) 42;
                }
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [0];
                buffer.patchFirst;
                assert(buffer.bytes[0] == 42);
            }
        }, backend);
    }

    @("structMethodAppendsArrayField." ~ backend.text)
    unittest {
        runTests(q{
            struct Writer {
                ubyte[] bytes;

                void put(ubyte value) {
                    bytes ~= value;
                }
            }

            unittest {
                Writer writer;
                writer.put(cast(ubyte) 42);
                assert(writer.bytes.length == 1);
                assert(writer.bytes[0] == 42);
            }
        }, backend);
    }

    @("structMethodCallsStructMethod." ~ backend.text)
    unittest {
        runTests(q{
            struct Writer {
                ubyte[] bytes;

                void write(ubyte value) {
                    append(value);
                }

                void append(ubyte value) {
                    bytes ~= value;
                }
            }

            unittest {
                Writer writer;
                writer.write(42);

                assert(writer.bytes.length == 1);
                assert(writer.bytes[0] == 42);
            }
        }, backend);
    }

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

static foreach (backend; [
    ExecutorBackend.bytecode,
    ExecutorBackend.treeWalking,
]) {
    @(backend.text ~ " explicit assert message overrides context")
    unittest {
        runTests(q{
            unittest {
                assert(1 == 2, "oops");
            }
        }, backend).shouldThrowWithMessage("oops");
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

@("literal false assertion matches DMD")
unittest {
    runTests(q{
        unittest {
            assert(false);
        }
    }).shouldThrowWithMessage("unittest failure");
}

@("runtime bool assertion context matches DMD")
unittest {
    runTests(q{
        bool nope() {
            return false;
        }

        unittest {
            assert(nope());
        }
    }).shouldThrowWithMessage("false != true");
}

@("bool assertion context matches DMD.dmdCtfe")
unittest {
    runTests(q{
        unittest {
            bool a = true;
            assert(a == false);
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("true != false");
}

@("char assertion context matches DMD.dmdCtfe")
unittest {
    runTests(q{
        unittest {
            char a = 'a';
            assert(a == 'b');
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("'a' != 'b'");
}

@("dynamic assert message matches DMD")
unittest {
    runTests(q{
        unittest {
            string msg = "oops";
            assert(false, msg);
        }
    }).shouldThrowWithMessage("oops");
}

@("dynamic assert message matches DMD.dmdCtfe")
unittest {
    runTests(q{
        unittest {
            string msg = "oops";
            assert(false, msg);
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("oops");
}

@("treeWalkingOld assertion context does not reevaluate equality operands")
unittest {
    runTests(q{
        unittest {
            int value;
            assert(++value == 0);
        }
    }, ExecutorBackend.treeWalkingOld).shouldThrowWithMessage("1 != 0");
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

    @(text("localIntReturn.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int value() {
                    int ret = 42;
                    return ret;
                }

                unittest {
                    assert(value == 42);
                }
            }, backend);
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

    @(text("intAddition.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 40;
                }

                unittest {
                    int value = input;
                    assert(value + 2 == 42);
                }
            }, backend);
        }
    }

    @(text("intSubtraction.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 44;
                }

                unittest {
                    int value = input;
                    assert(value - 2 == 42);
                }
            }, backend);
        }
    }

    @(text("intMultiplication.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 21;
                }

                unittest {
                    int value = input;
                    assert(value * 2 == 42);
                }
            }, backend);
        }
    }

    @(text("intDivision.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 84;
                }

                unittest {
                    int value = input;
                    assert(value / 2 == 42);
                }
            }, backend);
        }
    }

    @(text("intModulo.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 44;
                }

                unittest {
                    int value = input;
                    assert(value % 43 == 1);
                }
            }, backend);
        }
    }

    @(text("intBitwiseAnd.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                unittest {
                    int value = 0x2f;
                    assert((value & 0x2a) == 0x2a);
                }
            }, backend);
        }
    }

    @(text("intBitwiseOr.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                unittest {
                    int value = 0x28;
                    assert((value | 0x02) == 0x2a);
                }
            }, backend);
        }
    }

    @(text("intGreaterThan.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 42;
                }

                unittest {
                    assert(input > 41);
                }
            }, backend);
        }
    }

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

    @(text("functionParameter.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int identity(int value) {
                    return value;
                }

                unittest {
                    assert(identity(42) == 42);
                }
            }, backend);
        }
    }

    @(text("ifElse.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 1;
                }

                unittest {
                    int value;
                    if (input == 1)
                        value = 42;
                    else
                        value = 7;
                    assert(value == 42);
                }
            }, backend);
        }
    }

    @(text("while_.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                unittest {
                    int value;
                    while (value < 42)
                        value += 7;
                    assert(value == 42);
                }
            }, backend);
        }
    }
}

static foreach (backend; matureExecutorBackends ~ [ExecutorBackend.treeWalking]) {
    @("arrayLiteralElements." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int[] arr = [1, 2];
                assert(arr[0] == 1);
                assert(arr[1] == 2);
            }
        }, backend);
    }

    @("arrayLiteralVariableElements." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int a = 10;
                int b = 20;
                int[] arr = [a, b];
                assert(arr[0] == 10);
                assert(arr[1] == 20);
            }
        }, backend);
    }

    @("uninitializedDynamicArrayLength." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values;
                assert(values.length == 0);
            }
        }, backend);
    }

    @("foreachRange." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int sum;
                foreach (i; 0 .. 3)
                    sum += i;
                assert(sum == 3);
            }
        }, backend);
    }

    @("lessThan." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value = 2;
                assert(value < 3);
            }
        }, backend);
    }

    @("localDynamicArrayAppend." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values;
                ubyte value = 42;
                values ~= value;
                assert(values.length == 1);
                assert(values[0] == value);
            }
        }, backend);
    }

    @("refDynamicArrayParameterAppend." ~ backend.text)
    unittest {
        runTests(q{
            void append(ref ubyte[] values, ubyte value) {
                values ~= value;
            }

            unittest {
                ubyte[] values;
                ubyte value = 42;
                append(values, value);
                assert(values.length == 1);
                assert(values[0] == value);
            }
        }, backend);
    }

    @("structConstructorStoresDynamicArrayParameter." ~ backend.text)
    unittest {
        runTests(q{
            struct Box {
                int[] values;

                this(int[] input) {
                    store(input);
                }

                void store(int[] input) {
                    values = input;
                }
            }

            unittest {
                int first = 40;
                int second = first + 2;
                int[] input = [first, second];

                auto box = Box(input);

                assert(box.values.length == input.length);
                assert(box.values[0] == first);
                assert(box.values[1] == second);
            }
        }, backend);
    }

    @("dynamicArraySliceFromRuntimeBounds." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 1;
                size_t stop = values.length;

                const tail = values[start .. stop];

                assert(tail.length == 1);
                assert(tail[0] == second);
            }
        }, backend);
    }

    @("dynamicArrayReturnValue." ~ backend.text)
    unittest {
        runTests(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                const result = identity(values);

                assert(result.length == 2);
                assert(result[0] == first);
                assert(result[1] == second);
            }
        }, backend);
    }

    @("dynamicArraySliceReturnValue." ~ backend.text)
    unittest {
        runTests(q{
            ubyte[] tail(ubyte[] values, size_t start, size_t stop) {
                return values[start .. stop];
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 1;
                size_t stop = values.length;

                const result = tail(values, start, stop);

                assert(result.length == 1);
                assert(result[0] == second);
            }
        }, backend);
    }

    @("dynamicArrayReturnValueIndexesCallResult." ~ backend.text)
    unittest {
        runTests(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                assert(identity(values)[1] == second);
            }
        }, backend);
    }

    @("dynamicArrayStructFieldReturnValue." ~ backend.text)
    unittest {
        runTests(q{
            struct Box {
                ubyte[] values;

                this(ubyte[] input) {
                    values = input;
                }

                ubyte[] get() {
                    return values;
                }
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                auto box = Box(values);

                const result = box.get;

                assert(result.length == 2);
                assert(result[0] == first);
                assert(result[1] == second);
            }
        }, backend);
    }

    @("dynamicArrayReturnValueAssignsStructField." ~ backend.text)
    unittest {
        runTests(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            struct Box {
                ubyte[] values;

                this(ubyte[] input) {
                    values = input;
                }

                void set(ubyte[] input) {
                    values = identity(input);
                }
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                ubyte[] replacement = [second, first];
                auto box = Box(values);

                box.set(replacement);

                assert(box.values.length == 2);
                assert(box.values[0] == second);
                assert(box.values[1] == first);
            }
        }, backend);
    }

    @("dynamicArrayStructFieldReturnValueIndexesCallResult." ~ backend.text)
    unittest {
        runTests(q{
            struct Box {
                ubyte[] values;

                this(ubyte[] input) {
                    values = input;
                }

                ubyte[] get() {
                    return values;
                }
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                auto box = Box(values);

                assert(box.get[1] == second);
            }
        }, backend);
    }

    @("postIncrementSizeTIndex." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;
                assert(values[index++] == 0x29u);
                assert(index == 1);
            }
        }, backend);
    }

    @("structMethodPostIncrementsSizeTField." ~ backend.text)
    unittest {
        runTests(q{
            struct Cursor {
                size_t position;

                size_t read() {
                    return position++;
                }
            }

            unittest {
                Cursor cursor;
                size_t start = 1;
                cursor.position = start;

                assert(cursor.read == start);
                assert(cursor.position == start + 1);
            }
        }, backend);
    }

    @("structMethodReadsArrayFieldAtPostIncrementedField." ~ backend.text)
    unittest {
        runTests(q{
            struct Reader {
                ubyte[] bytes;
                size_t position;

                ubyte read() {
                    return bytes[position++];
                }
            }

            unittest {
                Reader reader;
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                reader.bytes = [first, second];
                reader.position = reader.bytes.length - 1;

                const value = reader.read;

                assert(value == second);
                assert(reader.position == reader.bytes.length);
            }
        }, backend);
    }

    @("rightShift." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                uint value = 8;
                uint amount = 1;
                assert((value >> amount) == 4);
            }
        }, backend);
    }

    @("multiplication." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value = 7;
                int factor = 6;
                assert(value * factor == 42);
            }
        }, backend);
    }

    @("castUbyteTruncates." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                uint value = 0x102;
                assert(cast(ubyte) value == 0x02);
            }
        }, backend);
    }

    @("subtraction." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int a = 5;
                int b = a - 3;
                assert(b == 2);
            }
        }, backend);
    }

    @("subtractionDifferentValues." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int a = 10;
                int b = a - 7;
                assert(b == 3);
            }
        }, backend);
    }

    @("freeFunctionCallWithReturn." ~ backend.text)
    unittest {
        runTests(q{
            int add(int a, int b) {
                return a + b;
            }

            unittest {
                int result = add(1, 2);
                assert(result == 3);
            }
        }, backend);
    }

    @("freeFunctionCallWithReturnDifferentValues." ~ backend.text)
    unittest {
        runTests(q{
            int sub(int a, int b) {
                return a - b;
            }

            unittest {
                int result = sub(10, 3);
                assert(result == 7);
            }
        }, backend);
    }

    @("freeFunctionCallWithArrayParam." ~ backend.text)
    unittest {
        runTests(q{
            int firstElement(int[] arr) {
                return arr[0];
            }

            unittest {
                int[] arr = [42];
                int result = firstElement(arr);
                assert(result == 42);
            }
        }, backend);
    }

    @("freeFunctionCallWithArrayParamSecondElement." ~ backend.text)
    unittest {
        runTests(q{
            int secondElement(int[] arr) {
                return arr[1];
            }

            unittest {
                int[] arr = [10, 20];
                int result = secondElement(arr);
                assert(result == 20);
            }
        }, backend);
    }

    @("preIncrement." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int x = 5;
                ++x;
                assert(x == 6);
            }
        }, backend);
    }

    @("preIncrementDifferentValue." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int x = 10;
                ++x;
                assert(x == 11);
            }
        }, backend);
    }

    @("refParamWriteback." ~ backend.text)
    unittest {
        runTests(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 5;
                increment(value);
                assert(value == 6);
            }
        }, backend);
    }

    @("refParamWritebackDifferentValue." ~ backend.text)
    unittest {
        runTests(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 10;
                increment(value);
                assert(value == 11);
            }
        }, backend);
    }
}

@("structMethodReturnDoesNotSkipCallerStatements.treeWalking")
unittest {
    runTests(q{
        struct Worker {
            void stop() {
                return;
            }
        }

        unittest {
            Worker worker;
            worker.stop;
            assert(false);
        }
    }, ExecutorBackend.treeWalking).shouldThrowWithMessage("Unittest assertion failed.");
}

static foreach (backend; matureExecutorBackends) {
    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong)) {
        @("integralType." ~ T.stringof ~ "." ~ backend.text)
        unittest {
            import std.conv: text;

            runTests(
                text(
                    "alias T = ",
                    T.stringof,
                    ";",
                    q{
                    static if (is(T == byte))
                        enum expected = -126;
                    else
                        enum expected = 130;

                    T identity(T value) {
                        return value;
                    }

                    int input() {
                        return 130;
                    }

                    unittest {
                        T value = cast(T) input;
                        assert(identity(value) == value);
                        assert(value == expected);
                    }
                }),
                backend,
            );
        }
    }
}

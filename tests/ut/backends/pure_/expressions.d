module ut.backends.pure_.expressions;


import ut.backends;


private:

import std.conv: text;
import std.meta: AliasSeq;
import ut.backends:
    dmdCodegenRamExecutorBackends,
    experimentalBackendTestsEnabled,
    matureExecutorBackends;


static foreach (backend; matureExecutorBackends ~ [
    ExecutorBackend.bytecode,
    ExecutorBackend.treeWalking,
]) {
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

}

static foreach (backend; matureExecutorBackends) {
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

    @("evaluatesPow." ~ backend.text)
    unittest {
        runTests(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 8.0);
            }
        }, backend);
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

    @("ulongHighBitLessThan." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL < value);
            }
        }, backend);
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

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("ulongDoubleComparisonUsesNumericUnsignedValue." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    ulong integer = 0x8000_0000_0000_0000UL;
                    double floating = 9_223_372_036_854_775_808.0;

                    assert(integer == floating);
                    assert(integer <= floating);
                    assert(integer >= floating);
                    assert(!(integer < floating));
                    assert(!(integer > floating));
                }
            }, backend);
        }
    }

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("castsFloatingValueNumerically." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    double input = 7.75;
                    assert(cast(int) input == 7);
                }
            }, backend);
        }
    }

    static if (backend == ExecutorBackend.ir) {
        @("intToFloatCastUsesFloatPrecision." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    int input = 16_777_217;
                    float converted = cast(float) input;

                    assert(converted == 16_777_216.0f);
                    assert(converted != 16_777_217.0);
                }
            }, backend);
        }
    }

    static if (backend == ExecutorBackend.ir) {
        @("ulongToRealCastPreservesRealPrecision." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    ulong input = ulong.max;
                    real converted = cast(real) input;

                    assert(converted == 18_446_744_073_709_551_615.0L);
                    assert(converted != cast(real) cast(double) input);
                }
            }, backend);
        }
    }

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("integerFloatEqualityIsNumeric." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    long integer = 0x3ff0_0000_0000_0000L;
                    double floating = 1.0;

                    assert(integer != floating);
                }
            }, backend);
        }
    }

    static if (backend != ExecutorBackend.treeWalkingOld) {
        @("realComparisonPreservesRealPrecision." ~ backend.text)
        unittest {
            runTests(q{
                unittest {
                    real left = real.max;
                    real right = real.infinity;

                    assert(left < right);
                }
            }, backend);
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
}

static foreach (backend; dmdCodegenRamExecutorBackends) {
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
}

static foreach (backend; matureExecutorBackends ~ [ExecutorBackend.treeWalking]) {
    @("lessThan." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value = 2;
                assert(value < 3);
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

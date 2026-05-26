module ut.executors.pure_.lang.expressions;


import ut.executors;


private:

import std.conv: text;
import std.meta: AliasSeq;
import ut.executors:
    dmdCodegenRamExecutorNames,
    experimentalExecutorTestsEnabled,
    matureExecutorNames;


static foreach (executorName; matureExecutorNames ~ [
    ExecutorName.bytecode,
    ExecutorName.treeWalking,
]) {
    @("intAddition." ~ executorName.text)
    unittest {
        runTests(q{
            int one() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the addition before the executor sees it.
                return one + 41;
            }

            unittest {
                assert(answer == 42);
            }
        }, executorName);
    }

    @("intSubtraction." ~ executorName.text)
    unittest {
        runTests(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the subtraction before the executor sees it.
                return 44 - two;
            }

            unittest {
                assert(answer == 42);
            }
        }, executorName);
    }

    @("intMultiplication." ~ executorName.text)
    unittest {
        runTests(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the multiplication before the executor sees it.
                return 21 * two;
            }

            unittest {
                assert(answer == 42);
            }
        }, executorName);
    }

    @("intDivision." ~ executorName.text)
    unittest {
        runTests(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the division before the executor sees it.
                return 84 / two;
            }

            unittest {
                assert(answer == 42);
            }
        }, executorName);
    }

    @("intModulo." ~ executorName.text)
    unittest {
        runTests(q{
            int divisor() {
                return 44;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the modulo before the executor sees it.
                return 86 % divisor;
            }

            unittest {
                assert(answer == 42);
            }
        }, executorName);
    }

    @("intShiftRight." ~ executorName.text)
    unittest {
        runTests(q{
            int shift() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the right shift before the executor sees it.
                return 0x80 >> shift;
            }

            unittest {
                assert(answer == 0x20);
            }
        }, executorName);
    }

    @("intShiftLeft." ~ executorName.text)
    unittest {
        runTests(q{
            int shift() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the left shift before the executor sees it.
                return 0x10 << shift;
            }

            unittest {
                assert(answer == 0x20);
            }
        }, executorName);
    }

    @("intBitwiseOr." ~ executorName.text)
    unittest {
        runTests(q{
            int mask() {
                return 0x06;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise OR before the executor sees it.
                return 0x2a | mask;
            }

            unittest {
                assert(answer == 0x2e);
            }
        }, executorName);
    }

    @("intBitwiseAnd." ~ executorName.text)
    unittest {
        runTests(q{
            int mask() {
                return 0x2f;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise AND before the executor sees it.
                return mask & 0x3a;
            }

            unittest {
                assert(answer == 0x2a);
            }
        }, executorName);
    }

    @("intBitwiseXor." ~ executorName.text)
    unittest {
        runTests(q{
            int mask() {
                return 0x04;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise XOR before the executor sees it.
                return 0x2e ^ mask;
            }

            unittest {
                assert(answer == 0x2a);
            }
        }, executorName);
    }

    @("intLessThan." ~ executorName.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(41 < bound);
            }
        }, executorName);
    }

    @("intLessOrEqual." ~ executorName.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(42 <= bound);
            }
        }, executorName);
    }

    @("intGreaterThan." ~ executorName.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(43 > bound);
            }
        }, executorName);
    }

    @("intGreaterOrEqual." ~ executorName.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(42 >= bound);
            }
        }, executorName);
    }

    @("intNotEqual." ~ executorName.text)
    unittest {
        runTests(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the executor sees it.
                assert(43 != bound);
            }
        }, executorName);
    }

}

static foreach (executorName; matureExecutorNames) {
    @("distinguishesFloatingPointValues." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                double left = 1.5;
                double right = 2.5;
                assert(left != right);
            }
        }, executorName);
    }

    @("evaluatesPow." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 8.0);
            }
        }, executorName);
    }

    @("intUnaryMinus." ~ executorName.text)
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
        }, executorName);
    }

    @("intBitwiseComplement." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x2a;
                assert(~value == -0x2b);
            }
        }, executorName);
    }

    @("intOrAssign." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x28u;
                value |= 0x02u;
                assert(value == 0x2au);
            }
        }, executorName);
    }

    @("intSubtractAssign." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 44;
                value -= 2;
                assert(value == 42);
            }
        }, executorName);
    }

    @("intAddAssign." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 40;
                value += 2;
                assert(value == 42);
            }
        }, executorName);
    }

    @("ubyteAddAssignWrapsOnStore." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte value = 255;
                value += 1;
                assert(value == 0);
            }
        }, executorName);
    }

    @("ulongHighBitLessThan." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL < value);
            }
        }, executorName);
    }

    @("longLiteral." ~ executorName.text)
    unittest {
        runTests(q{
            long answer() {
                return 2_147_483_648L;
            }

            unittest {
                assert(answer > 0L);
            }
        }, executorName);
    }

    @("ulongHighBitLessOrEqual." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL <= value);
            }
        }, executorName);
    }

    @("ulongHighBitGreaterOrEqual." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value >= 0UL);
            }
        }, executorName);
    }

    @("ulongHighBitGreaterThan." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value > 0UL);
            }
        }, executorName);
    }

    static if (executorName != ExecutorName.treeWalkingOld) {
        @("ulongDoubleComparisonUsesNumericUnsignedValue." ~ executorName.text)
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
            }, executorName);
        }
    }

    static if (executorName != ExecutorName.treeWalkingOld) {
        @("castsFloatingValueNumerically." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    double input = 7.75;
                    assert(cast(int) input == 7);
                }
            }, executorName);
        }
    }

    static if (executorName == ExecutorName.ir) {
        @("intToFloatCastUsesFloatPrecision." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    int input = 16_777_217;
                    float converted = cast(float) input;

                    assert(converted == 16_777_216.0f);
                    assert(converted != 16_777_217.0);
                }
            }, executorName);
        }
    }

    static if (executorName == ExecutorName.ir) {
        @("ulongToRealCastPreservesRealPrecision." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    ulong input = ulong.max;
                    real converted = cast(real) input;

                    assert(converted == 18_446_744_073_709_551_615.0L);
                    assert(converted != cast(real) cast(double) input);
                }
            }, executorName);
        }
    }

    static if (executorName != ExecutorName.treeWalkingOld) {
        @("integerFloatEqualityIsNumeric." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    long integer = 0x3ff0_0000_0000_0000L;
                    double floating = 1.0;

                    assert(integer != floating);
                }
            }, executorName);
        }
    }

    static if (executorName != ExecutorName.treeWalkingOld) {
        @("realComparisonPreservesRealPrecision." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    real left = real.max;
                    real right = real.infinity;

                    assert(left < right);
                }
            }, executorName);
        }
    }

    @("castUbyteRuntimeValueTruncates." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                assert(cast(ubyte) value == 2);
            }
        }, executorName);
    }

    @("ubyteLocalTruncatesOnStore." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int source = 258;
                ubyte value = cast(ubyte) source;
                assert(value == 2);
            }
        }, executorName);
    }
}

static foreach (executorName; dmdCodegenRamExecutorNames) {
    @(text("intAddition.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 40;
                }

                unittest {
                    int value = input;
                    assert(value + 2 == 42);
                }
            }, executorName);
        }
    }

    @(text("intAddAssign.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 40;
                }

                unittest {
                    int value = input;
                    value += 2;
                    assert(value == 42);
                }
            }, executorName);
        }
    }

    @(text("intSubtraction.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 44;
                }

                unittest {
                    int value = input;
                    assert(value - 2 == 42);
                }
            }, executorName);
        }
    }

    @(text("intMultiplication.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 21;
                }

                unittest {
                    int value = input;
                    assert(value * 2 == 42);
                }
            }, executorName);
        }
    }

    @(text("intDivision.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 84;
                }

                unittest {
                    int value = input;
                    assert(value / 2 == 42);
                }
            }, executorName);
        }
    }

    @(text("intModulo.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 44;
                }

                unittest {
                    int value = input;
                    assert(value % 43 == 1);
                }
            }, executorName);
        }
    }

    @(text("intBitwiseAnd.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                unittest {
                    int value = 0x2f;
                    assert((value & 0x2a) == 0x2a);
                }
            }, executorName);
        }
    }

    @(text("intBitwiseOr.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                unittest {
                    int value = 0x28;
                    assert((value | 0x02) == 0x2a);
                }
            }, executorName);
        }
    }

    @(text("intGreaterThan.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int input() {
                    return 42;
                }

                unittest {
                    assert(input > 41);
                }
            }, executorName);
        }
    }
}

static foreach (executorName; matureExecutorNames ~ [ExecutorName.treeWalking]) {
    @("lessThan." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int value = 2;
                assert(value < 3);
            }
        }, executorName);
    }

    @("rightShift." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                uint value = 8;
                uint amount = 1;
                assert((value >> amount) == 4);
            }
        }, executorName);
    }

    @("multiplication." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int value = 7;
                int factor = 6;
                assert(value * factor == 42);
            }
        }, executorName);
    }

    @("castUbyteTruncates." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                uint value = 0x102;
                assert(cast(ubyte) value == 0x02);
            }
        }, executorName);
    }

    @("subtraction." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int a = 5;
                int b = a - 3;
                assert(b == 2);
            }
        }, executorName);
    }

    @("subtractionDifferentValues." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int a = 10;
                int b = a - 7;
                assert(b == 3);
            }
        }, executorName);
    }

    @("preIncrement." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int x = 5;
                ++x;
                assert(x == 6);
            }
        }, executorName);
    }

    @("preIncrementDifferentValue." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int x = 10;
                ++x;
                assert(x == 11);
            }
        }, executorName);
    }
}

static foreach (executorName; matureExecutorNames) {
    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong)) {
        @("integralType." ~ T.stringof ~ "." ~ executorName.text)
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
                executorName,
            );
        }
    }
}

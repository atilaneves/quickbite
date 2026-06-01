module ut.backends.pure_.lang.expressions;


import ut.backends;
import quickbite.backends.ir: IR;
import dmd.target: CPU, target;


private void runSse2BackendSourceFixtureTests(T)(in string moduleSource) {
    const originalCpu = target.cpu;
    target.cpu = CPU.sse2;
    scope(exit) target.cpu = originalCpu;

    runBackendSourceFixtureTests!T(moduleSource);
}


static foreach (backend; backendsWith!IR) {
    @("intAddition." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {
    @("intAdditionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the addition before the backend sees it.
                return one + 41;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intAdditionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the addition before the backend sees it.
                return two + 5;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("intSubtraction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intSubtractionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the subtraction before the backend sees it.
                return 44 - two;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intSubtractionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the subtraction before the backend sees it.
                return 9 - two;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("intMultiplication." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intMultiplicationFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the multiplication before the backend sees it.
                return 21 * two;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intMultiplicationFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the multiplication before the backend sees it.
                return two * 3;
            }

            unittest {
                assert(answer == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }

    @("intDivision." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intDivisionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the division before the backend sees it.
                return 84 / two;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intDivisionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the division before the backend sees it.
                return 14 / two;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("intModulo." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intModuloFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int divisor() {
                return 44;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the modulo before the backend sees it.
                return 86 % divisor;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intModuloFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int divisor() {
                return 44;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the modulo before the backend sees it.
                return 51 % divisor;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("intShiftRight." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intShiftRightFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int shift() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the right shift before the backend sees it.
                return 0x80 >> shift;
            }

            unittest {
                assert(answer == 0x21);
            }
        }).shouldThrowWithMessage("32 != 33");
    }

    @("intShiftRightFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int shift() {
                return 4;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the right shift before the backend sees it.
                return 0x80 >> shift;
            }

            unittest {
                assert(answer == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }

    @("intShiftLeft." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intShiftLeftFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int shift() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the left shift before the backend sees it.
                return 0x10 << shift;
            }

            unittest {
                assert(answer == 0x21);
            }
        }).shouldThrowWithMessage("32 != 33");
    }

    @("intShiftLeftFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int shift() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the left shift before the backend sees it.
                return 0x04 << shift;
            }

            unittest {
                assert(answer == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }

    @("intBitwiseOr." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intBitwiseOrFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 0x06;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise OR before the backend sees it.
                return 0x2a | mask;
            }

            unittest {
                assert(answer == 0x2f);
            }
        }).shouldThrowWithMessage("46 != 47");
    }

    @("intBitwiseOrFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 0x06;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise OR before the backend sees it.
                return 0x01 | mask;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("intBitwiseAnd." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intBitwiseAndFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 0x2f;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise AND before the backend sees it.
                return mask & 0x3a;
            }

            unittest {
                assert(answer == 0x2b);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intBitwiseAndFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 0x2f;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise AND before the backend sees it.
                return mask & 0x07;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("intBitwiseXor." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("intBitwiseXorFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 0x04;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise XOR before the backend sees it.
                return 0x2e ^ mask;
            }

            unittest {
                assert(answer == 0x2b);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intBitwiseXorFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int mask() {
                return 0x04;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the bitwise XOR before the backend sees it.
                return 0x03 ^ mask;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("intLessThan." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(41 < bound);
            }
        });
    }

    @("intLessThanFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 < bound);
            }
        }).shouldThrowWithMessage("42 >= 42");
    }

    @("intLessOrEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 <= bound);
            }
        });
    }

    @("intLessOrEqualFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 <= bound);
            }
        }).shouldThrowWithMessage("43 > 42");
    }

    @("intGreaterThan." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 > bound);
            }
        });
    }

    @("intGreaterThanFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 > bound);
            }
        }).shouldThrowWithMessage("42 <= 42");
    }

    @("intGreaterOrEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 >= bound);
            }
        });
    }

    @("intGreaterOrEqualFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(41 >= bound);
            }
        }).shouldThrowWithMessage("41 < 42");
    }

    @("intNotEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(43 != bound);
            }
        });
    }

    @("intNotEqualFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the comparison before the backend sees it.
                assert(42 != bound);
            }
        }).shouldThrowWithMessage("42 == 42");
    }
}

static foreach (backend; backends) {
    @("distinguishesFloatingPointValues." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double left = 1.5;
                double right = 2.5;
                assert(left != right);
            }
        });
    }

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("distinguishesFloatingPointValuesFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double left = 1.5;
                double right = 2.5;
                assert(left == right);
            }
        }).shouldThrowWithMessage("1.5 != 2.5");
    }

    @("evaluatesPow." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 8.0);
            }
        });
    }

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesPowFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 9.0);
            }
        }).shouldThrowWithMessage("8 != 9");
    }

    @("intUnaryMinus." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 42;
            }

            int answer() {
                return -input;
            }

            unittest {
                assert(answer == -42);
            }
        });
    }

    @("intUnaryMinusFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 42;
            }

            int answer() {
                return -input;
            }

            unittest {
                assert(answer == -43);
            }
        }).shouldThrowWithMessage("-42 != -43");
    }

    @("intBitwiseComplement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x2a;
                assert(~value == -0x2b);
            }
        });
    }

    @("intBitwiseComplementFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x2a;
                assert(~value == -0x2c);
            }
        }).shouldThrowWithMessage("-43 != -44");
    }

    @("intOrAssign." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x28u;
                value |= 0x02u;
                assert(value == 0x2au);
            }
        });
    }

    @("intOrAssignFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x28u;
                value |= 0x02u;
                assert(value == 0x2bu);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intSubtractAssign." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 44;
                value -= 2;
                assert(value == 42);
            }
        });
    }

    @("intSubtractAssignFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 44;
                value -= 2;
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intAddAssign." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 40;
                value += 2;
                assert(value == 42);
            }
        });
    }

    @("intAddAssignFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 40;
                value += 2;
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("commaExpressionSequencesOperands." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 2;
            }

            int answer() {
                int value = seed;
                value += 3, ++value;
                return value;
            }

            unittest {
                assert(answer == 6);
            }
        });
    }

    @("commaExpressionSequencesOperandsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 2;
            }

            int answer() {
                int value = seed;
                value += 3, ++value;
                return value;
            }

            unittest {
                assert(answer == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }

    @("commaExpressionSequencesOperandsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 4;
            }

            int answer() {
                int value = seed;
                value += 3, ++value;
                return value;
            }

            unittest {
                assert(answer == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }

    @("typeidClassReferenceUsesDynamicClass." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {}
            class Child : Base {}

            int classify(int seed) {
                Base value = new Child;
                return typeid(value) is typeid(Child) ? seed + 4 : seed;
            }

            unittest {
                assert(classify(3) == 7);
            }
        });
    }

    @("typeidClassReferenceUsesDynamicClassFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {}
            class Child : Base {}

            int classify(int seed) {
                Base value = new Child;
                return typeid(value) is typeid(Child) ? seed + 4 : seed;
            }

            unittest {
                assert(classify(3) == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("typeidClassReferenceUsesDynamicClassFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {}
            class Child : Base {}

            int classify(int seed) {
                Base value = new Child;
                return typeid(value) is typeid(Child) ? seed + 4 : seed;
            }

            unittest {
                assert(classify(4) == 7);
            }
        }).shouldThrowWithMessage("8 != 7");
    }

    @("classVirtualCallUsesDynamicClass." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {
                int score() {
                    return 0;
                }
            }

            class Child : Base {
                int field;

                this(int field) {
                    this.field = field;
                }

                override int score() {
                    return field + 3;
                }
            }

            int classify(int seed) {
                Base value = new Child(seed + 4);
                return value.score;
            }

            unittest {
                assert(classify(5) == 12);
            }
        });
    }

    @("classVirtualCallUsesDynamicClassFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {
                int score() {
                    return 0;
                }
            }

            class Child : Base {
                int field;

                this(int field) {
                    this.field = field;
                }

                override int score() {
                    return field + 3;
                }
            }

            int classify(int seed) {
                Base value = new Child(seed + 4);
                return value.score;
            }

            unittest {
                assert(classify(5) == 13);
            }
        }).shouldThrowWithMessage("12 != 13");
    }

    @("classVirtualCallUsesDynamicClassFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {
                int score() {
                    return 0;
                }
            }

            class Child : Base {
                int field;

                this(int field) {
                    this.field = field;
                }

                override int score() {
                    return field + 3;
                }
            }

            int classify(int seed) {
                Base value = new Child(seed + 4);
                return value.score;
            }

            unittest {
                assert(classify(2) == 12);
            }
        }).shouldThrowWithMessage("9 != 12");
    }

    @("typeidTypeNameReturnsIdentifier." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Widget {}

            string typeName(int seed) {
                string name = typeid(Widget).name;
                return seed == name.length ? "" : name;
            }

            unittest {
                assert(typeName(0) == "Widget");
            }
        });
    }

    @("typeidTypeNameReturnsIdentifierFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Widget {}

            string typeName(int seed) {
                string name = typeid(Widget).name;
                return seed == name.length ? "" : name;
            }

            unittest {
                assert(typeName(0) == "onlineapp.Widget");
            }
        }).shouldThrowWithMessage(`"Widget" != "onlineapp.Widget"`);
    }

    @("nestedDelegateCallUsesCapturedValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int apply(int seed) {
                int captured = seed + 2;

                int nested(int value) {
                    captured += value;
                    return captured;
                }

                int delegate(int) dg = &nested;
                return dg(5) + dg(1);
            }

            unittest {
                assert(apply(3) == 21);
            }
        });
    }

    @("nestedDelegateCallUsesCapturedValueFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int apply(int seed) {
                int captured = seed + 2;

                int nested(int value) {
                    captured += value;
                    return captured;
                }

                int delegate(int) dg = &nested;
                return dg(5) + dg(1);
            }

            unittest {
                assert(apply(3) == 22);
            }
        }).shouldThrowWithMessage("21 != 22");
    }

    @("nestedDelegateCallUsesCapturedValueFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int apply(int seed) {
                int captured = seed + 2;

                int nested(int value) {
                    captured += value;
                    return captured;
                }

                int delegate(int) dg = &nested;
                return dg(5) + dg(1);
            }

            unittest {
                assert(apply(4) == 21);
            }
        }).shouldThrowWithMessage("23 != 21");
    }

    @("structMemberDelegateCallUsesReceiver." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int field;

                int value(int input) {
                    return field + input;
                }
            }

            int apply(int seed) {
                Counter counter = Counter(seed + 2);
                int delegate(int) dg = &counter.value;
                return dg(5);
            }

            unittest {
                assert(apply(3) == 10);
            }
        });
    }

    @("structMemberDelegateCallUsesReceiverFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int field;

                int value(int input) {
                    return field + input;
                }
            }

            int apply(int seed) {
                Counter counter = Counter(seed + 2);
                int delegate(int) dg = &counter.value;
                return dg(5);
            }

            unittest {
                assert(apply(3) == 11);
            }
        }).shouldThrowWithMessage("10 != 11");
    }

    @("structMemberDelegateCallUsesReceiverFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int field;

                int value(int input) {
                    return field + input;
                }
            }

            int apply(int seed) {
                Counter counter = Counter(seed + 2);
                int delegate(int) dg = &counter.value;
                return dg(5);
            }

            unittest {
                assert(apply(4) == 10);
            }
        }).shouldThrowWithMessage("11 != 10");
    }

    @("delegatePtrPropertyIsRejectedAtCtfe." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int runtimeSeed(int seed) {
                return seed + 1;
            }

            void* delegateContext(int seed) {
                int captured = runtimeSeed(seed);

                int nested() {
                    captured += 2;
                    return captured;
                }

                int delegate() dg = &nested;
                return dg.ptr;
            }

            unittest {
                auto context = delegateContext(3);
                assert(context is null);
            }
        }).shouldThrowWithMessage(
            "`dg.ptr` cannot be evaluated at compile time");
    }

    @("delegateFuncptrPropertyIsRejectedAtCtfe." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int runtimeSeed(int seed) {
                return seed + 1;
            }

            int function() delegateFunction(int seed) {
                int captured = runtimeSeed(seed);

                int nested() {
                    captured += 2;
                    return captured;
                }

                int delegate() dg = &nested;
                return dg.funcptr;
            }

            unittest {
                auto funcptr = delegateFunction(3);
                assert(funcptr !is null);
            }
        }).shouldThrowWithMessage(
            "`dg.funcptr` cannot be evaluated at compile time");
    }

    @("ubyteAddAssignWrapsOnStore." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte value = 255;
                value += 1;
                assert(value == 0);
            }
        });
    }

    @("ubyteAddAssignWrapsOnStoreFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte value = 255;
                value += 1;
                assert(value == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }

    @("ulongHighBitLessThan." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL < value);
            }
        });
    }

    @("ulongHighBitLessThanFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL >= value);
            }
        }).shouldThrowWithMessage("0 < 9255003132036915216");
    }

    @("longLiteral." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long answer() {
                return 2_147_483_648L;
            }

            unittest {
                assert(answer > 0L);
            }
        });
    }

    @("longLiteralFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long answer() {
                return 2_147_483_648L;
            }

            unittest {
                assert(answer <= 0L);
            }
        }).shouldThrowWithMessage("2147483648 > 0");
    }

    @("ulongHighBitLessOrEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL <= value);
            }
        });
    }

    @("ulongHighBitLessOrEqualFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL > value);
            }
        }).shouldThrowWithMessage("0 <= 9255003132036915216");
    }

    @("ulongHighBitGreaterOrEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value >= 0UL);
            }
        });
    }

    @("ulongHighBitGreaterOrEqualFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value < 0UL);
            }
        }).shouldThrowWithMessage("9255003132036915216 >= 0");
    }

    @("ulongHighBitGreaterThan." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value > 0UL);
            }
        });
    }

    @("ulongHighBitGreaterThanFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value <= 0UL);
            }
        }).shouldThrowWithMessage("9255003132036915216 > 0");
    }

    @("ulongDoubleComparisonUsesNumericUnsignedValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ulong integer = 0x8000_0000_0000_0000UL;
                double floating = 9_223_372_036_854_775_808.0;

                assert(integer == floating);
                assert(integer <= floating);
                assert(integer >= floating);
                assert(!(integer < floating));
                assert(!(integer > floating));
            }
        });
    }

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("ulongDoubleComparisonUsesNumericUnsignedValueFailureMessage." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ulong integer = 0x8000_0000_0000_0000UL;
                double floating = 9_223_372_036_854_775_808.0;

                assert(integer != floating);
            }
        }).shouldThrowWithMessage("9223372036854775808 == 9.22337e+18");
    }

    @("castsFloatingValueNumerically." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double input = 7.75;
                assert(cast(int) input == 7);
            }
        });
    }

    @("castsFloatingValueNumericallyFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double input = 7.75;
                assert(cast(int) input == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @ShouldFail(
        "DMD CTFE returns <float not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("intToFloatCastUsesFloatPrecision." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int input = 16_777_217;
                float converted = cast(float) input;

                assert(converted == 16_777_216.0f);
                assert(converted != 16_777_217.0);
            }
        });
    }

    @ShouldFail(
        "DMD CTFE returns <float not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("intToFloatCastUsesFloatPrecisionFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int input = 16_777_217;
                float converted = cast(float) input;

                assert(converted != 16_777_216.0);
            }
        }).shouldThrowWithMessage("1.67772e+07 == 1.67772e+07");
    }

    @ShouldFail(
        "DMD CTFE returns <real not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("ulongToRealCastPreservesRealPrecision." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ulong input = ulong.max;
                real converted = cast(real) input;

                assert(converted == 18_446_744_073_709_551_615.0L);
                assert(converted != cast(real) cast(double) input);
            }
        });
    }

    @ShouldFail(
        "DMD CTFE returns <real not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("ulongToRealCastPreservesRealPrecisionFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ulong input = ulong.max;
                real converted = cast(real) input;

                assert(converted != 18_446_744_073_709_551_615.0L);
            }
        }).shouldThrowWithMessage(
            "18446744073709551615 == 18446744073709551615",
        );
    }

    @("integerFloatEqualityIsNumeric." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                long integer = 0x3ff0_0000_0000_0000L;
                double floating = 1.0;

                assert(integer != floating);
            }
        });
    }

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("integerFloatEqualityIsNumericFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                long integer = 0x3ff0_0000_0000_0000L;
                double floating = 1.0;

                assert(integer == floating);
            }
        }).shouldThrowWithMessage("4607182418800017408 != 1");
    }

    @("realComparisonPreservesRealPrecision." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                real left = real.max;
                real right = real.infinity;

                assert(left < right);
            }
        });
    }

    @ShouldFail(
        "DMD CTFE returns <real not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("realComparisonPreservesRealPrecisionFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                real left = real.max;
                real right = real.infinity;

                assert(left >= right);
            }
        }).shouldThrowWithMessage("1.18973e+4932 < inf");
    }

    @("castUbyteRuntimeValueTruncates." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;
                assert(cast(ubyte) value == 2);
            }
        });
    }

    @("castUbyteRuntimeValueTruncatesFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;
                assert(cast(ubyte) value == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("hexStringCastToUshortArrayUsesBigEndianWords." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ushort[] words = cast(ushort[]) x"12345678";

                assert(words.length == 2);
                assert(words[0] == 0x1234);
                assert(words[1] == 0x5678);
            }
        });
    }

    @("hexStringCastToUshortArrayUsesBigEndianWordsFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ushort[] words = cast(ushort[]) x"12345678";

                assert(words[0] == 0x3412);
            }
        }).shouldThrowWithMessage("4660 != 13330");
    }

    @("hexStringCastToUshortArrayUsesBigEndianWordsFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ushort[] words = cast(ushort[]) x"12345678";

                assert(words[1] == 0x7856);
            }
        }).shouldThrowWithMessage("22136 != 30806");
    }

    @("ubyteLocalTruncatesOnStore." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int source = 258;
                ubyte value = cast(ubyte) source;
                assert(value == 2);
            }
        });
    }

    @("ubyteLocalTruncatesOnStoreFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int source = 258;
                ubyte value = cast(ubyte) source;
                assert(value == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("sliceCastToPointerDereferencesFirstElement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                auto tail = values[start .. $];
                int* p = cast(int*) tail;

                assert(*p == values[start]);
            }
        });
    }

    @("sliceCastToPointerDereferencesFirstElementFailureMessage." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                auto tail = values[start .. $];
                int* p = cast(int*) tail;

                assert(*p == values[start + 1]);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("arrayPointerCastDereferencesFirstElement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1];
                int* original = &values[0];
                void* erased = cast(void*) original;
                int* restored = cast(int*) erased;

                assert(*restored == 41);
                assert(*(restored + 1) == 42);
            }
        });
    }

    @("arrayPointerCastDereferencesFirstElementFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1];
                int* original = &values[0];
                void* erased = cast(void*) original;
                int* restored = cast(int*) erased;

                assert(*restored == 42);
            }
        }).shouldThrowWithMessage("41 != 42");
    }

    @("arrayPointerCastDereferencesFirstElementFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1];
                int* original = &values[0];
                void* erased = cast(void*) original;
                int* restored = cast(int*) erased;

                assert(*(restored + 1) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("pointerCastToBoolReflectsNullness." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1];
                int* present = &values[0];
                int* missing = null;

                assert(cast(bool) present == true);
                assert(cast(bool) missing == false);
            }
        });
    }

    @("pointerCastToBoolReflectsNullnessFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1];
                int* present = &values[0];

                assert(cast(bool) present == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("pointerCastToBoolReflectsNullnessFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int* missing = null;

                assert(cast(bool) missing == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("conditionalExpressionTreatsNonNullPointerAsTrue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int classify(int seed) {
                int[] values = [seed, seed + 1];
                int* p = &values[0];

                return p ? *p + 1 : 0;
            }

            unittest {
                assert(classify(41) == 42);
            }
        });
    }

    @("conditionalExpressionTreatsNonNullPointerAsTrueFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int classify(int seed) {
                int[] values = [seed, seed + 1];
                int* p = &values[0];

                return p ? *p + 1 : 0;
            }

            unittest {
                assert(classify(41) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("conditionalExpressionTreatsNonNullPointerAsTrueFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int classify(int seed) {
                int[] values = [seed, seed + 1];
                int* p = &values[0];

                return p ? *p + 1 : 0;
            }

            unittest {
                assert(classify(7) == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }

    @("newScalarPointerDereferencesRuntimeValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 40;
                seed += 2;

                auto p = new int(seed);
                ++(*p);

                assert(*p == seed + 1);
            }
        });
    }

    @("newScalarPointerDereferencesRuntimeValueFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 40;
                seed += 2;

                auto p = new int(seed);
                ++(*p);

                assert(*p == seed);
            }
        }).shouldThrowWithMessage("43 != 42");
    }

    @("newScalarPointerDereferencesRuntimeValueFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 7;
                seed += 1;

                auto p = new int(seed);
                ++(*p);

                assert(*p == seed);
            }
        }).shouldThrowWithMessage("9 != 8");
    }

    @("vectorScalarCastSplatsToStaticArray." ~ backend.stringof)
    unittest {
        runSse2BackendSourceFixtureTests!backend(q{
            alias Int4 = __vector(int[4]);

            int seed(int value) {
                return value;
            }

            int[4] splat(int input) {
                int scalar = seed(input);
                Int4 vector = cast(Int4) scalar;
                return vector.array;
            }

            unittest {
                int[4] values = splat(7);

                assert(values[0] == 7);
                assert(values[1] == 7);
                assert(values[2] == 7);
                assert(values[3] == 7);
            }
        });
    }

    @("vectorScalarCastSplatsToStaticArrayFailureMessage.0." ~
        backend.stringof)
    unittest {
        runSse2BackendSourceFixtureTests!backend(q{
            alias Int4 = __vector(int[4]);

            int seed(int value) {
                return value;
            }

            int[4] splat(int input) {
                int scalar = seed(input);
                Int4 vector = cast(Int4) scalar;
                return vector.array;
            }

            unittest {
                int[4] values = splat(7);

                assert(values[2] == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("vectorScalarCastSplatsToStaticArrayFailureMessage.1." ~
        backend.stringof)
    unittest {
        runSse2BackendSourceFixtureTests!backend(q{
            alias Int4 = __vector(int[4]);

            int seed(int value) {
                return value;
            }

            int[4] splat(int input) {
                int scalar = seed(input);
                Int4 vector = cast(Int4) scalar;
                return vector.array;
            }

            unittest {
                int[4] values = splat(3);

                assert(values[0] == 7);
            }
        }).shouldThrowWithMessage("3 != 7");
    }
}

module ut.backends.pure_.lang.expressions;


import ut.backends;


static foreach (backend; backends) {
    @("intAddition." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
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

    @("intAdditionFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
        newBackend!backend.runTests(q{
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
}

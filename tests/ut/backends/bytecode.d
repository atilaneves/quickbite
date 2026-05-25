module ut.backends.bytecode;


import ut.backends;


@("voidFunctionReturnsToCaller.bytecode")
unittest {
    runTests(q{
        int one() {
            return 1;
        }

        void foo() {}

        unittest {
            foo;
            // Keep this runtime-shaped so DMD does not constant-fold it before
            // bytecode sees the equality expression.
            assert(one == 2);
        }
    }, ExecutorBackend.bytecode).shouldThrowWithMessage("1 != 2");
}

@("intAddition.bytecode")
unittest {
    runTests(q{
        int one() {
            return 1;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // addition before bytecode sees it.
            return one + 41;
        }

        unittest {
            assert(answer == 42);
        }
    }, ExecutorBackend.bytecode);
}

@("intSubtraction.bytecode")
unittest {
    runTests(q{
        int two() {
            return 2;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // subtraction before bytecode sees it.
            return 44 - two;
        }

        unittest {
            assert(answer == 42);
        }
    }, ExecutorBackend.bytecode);
}

@("intMultiplication.bytecode")
unittest {
    runTests(q{
        int two() {
            return 2;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // multiplication before bytecode sees it.
            return 21 * two;
        }

        unittest {
            assert(answer == 42);
        }
    }, ExecutorBackend.bytecode);
}

@("intDivision.bytecode")
unittest {
    runTests(q{
        int two() {
            return 2;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // division before bytecode sees it.
            return 84 / two;
        }

        unittest {
            assert(answer == 42);
        }
    }, ExecutorBackend.bytecode);
}

@("intModulo.bytecode")
unittest {
    runTests(q{
        int divisor() {
            return 44;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // modulo before bytecode sees it.
            return 86 % divisor;
        }

        unittest {
            assert(answer == 42);
        }
    }, ExecutorBackend.bytecode);
}

@("intShiftRight.bytecode")
unittest {
    runTests(q{
        int shift() {
            return 2;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // right shift before bytecode sees it.
            return 0x80 >> shift;
        }

        unittest {
            assert(answer == 0x20);
        }
    }, ExecutorBackend.bytecode);
}

@("intShiftLeft.bytecode")
unittest {
    runTests(q{
        int shift() {
            return 1;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // left shift before bytecode sees it.
            return 0x10 << shift;
        }

        unittest {
            assert(answer == 0x20);
        }
    }, ExecutorBackend.bytecode);
}

@("intBitwiseOr.bytecode")
unittest {
    runTests(q{
        int mask() {
            return 0x06;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // bitwise OR before bytecode sees it.
            return 0x2a | mask;
        }

        unittest {
            assert(answer == 0x2e);
        }
    }, ExecutorBackend.bytecode);
}

@("intBitwiseAnd.bytecode")
unittest {
    runTests(q{
        int mask() {
            return 0x2f;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // bitwise AND before bytecode sees it.
            return mask & 0x3a;
        }

        unittest {
            assert(answer == 0x2a);
        }
    }, ExecutorBackend.bytecode);
}

@("intBitwiseXor.bytecode")
unittest {
    runTests(q{
        int mask() {
            return 0x04;
        }

        int answer() {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // bitwise XOR before bytecode sees it.
            return 0x2e ^ mask;
        }

        unittest {
            assert(answer == 0x2a);
        }
    }, ExecutorBackend.bytecode);
}

@("intLessThan.bytecode")
unittest {
    runTests(q{
        int bound() {
            return 42;
        }

        unittest {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // comparison before bytecode sees it.
            assert(41 < bound);
        }
    }, ExecutorBackend.bytecode);
}

@("intLessThanOops.bytecode")
unittest {
    runTests(q{
        int bound() {
            return 42;
        }

        unittest {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // comparison before bytecode sees it.
            assert(42 < bound);
        }
    }, ExecutorBackend.bytecode).shouldThrowWithMessage("0 != 1");
}

@("intLessOrEqual.bytecode")
unittest {
    runTests(q{
        int bound() {
            return 42;
        }

        unittest {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // comparison before bytecode sees it.
            assert(42 <= bound);
        }
    }, ExecutorBackend.bytecode);
}

@("intGreaterThan.bytecode")
unittest {
    runTests(q{
        int bound() {
            return 42;
        }

        unittest {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // comparison before bytecode sees it.
            assert(43 > bound);
        }
    }, ExecutorBackend.bytecode);
}

@("intGreaterThanOops.bytecode")
unittest {
    runTests(q{
        int bound() {
            return 42;
        }

        unittest {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // comparison before bytecode sees it.
            assert(42 > bound);
        }
    }, ExecutorBackend.bytecode).shouldThrowWithMessage("0 != 1");
}

@("intGreaterOrEqual.bytecode")
unittest {
    runTests(q{
        int bound() {
            return 42;
        }

        unittest {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // comparison before bytecode sees it.
            assert(42 >= bound);
        }
    }, ExecutorBackend.bytecode);
}

@("intNotEqual.bytecode")
unittest {
    runTests(q{
        int bound() {
            return 42;
        }

        unittest {
            // Keep one operand runtime-shaped so DMD does not constant-fold the
            // comparison before bytecode sees it.
            assert(43 != bound);
        }
    }, ExecutorBackend.bytecode);
}

@("assertNonzeroIntCondition.bytecode")
unittest {
    runTests(q{
        int mask() {
            return 2;
        }

        unittest {
            assert(0x28 | mask);
        }
    }, ExecutorBackend.bytecode);
}

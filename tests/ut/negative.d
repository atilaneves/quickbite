module ut.negative;

import quickbite;
import unit_threaded;

@("negative.voidFunction")
unittest {
    q{
        void foo() {
            int value;
        }

        unittest {
            foo;
        }
    }.runTests.shouldThrowWithMessage("Unsupported expression: declaration");
}

@("negative.multiStatementBody")
unittest {
    q{
        int answer() {
            int value;
            return value;
        }

        unittest {
            assert(answer == 0);
        }
    }.runTests.shouldThrowWithMessage("Unsupported expression: declaration");
}

@("negative.nonLiteralReturn")
unittest {
    q{
        int value;

        int answer() {
            return value;
        }

        unittest {
            assert(answer == 0);
        }
    }.runTests.shouldThrowWithMessage("Unsupported expression: value");
}

@("negative.unsupportedAssert")
unittest {
    q{
        unittest {
            int value;
            assert(value);
        }
    }.runTests.shouldThrowWithMessage("Unsupported expression: declaration");
}

@("negative.outParameter")
unittest {
    q{
        void setAnswer(out int value) {
            value = 42;
        }

        unittest {
            int value = 0;
            setAnswer(value);
            assert(value == 42);
        }
    }.runTests.shouldThrowWithMessage("Unsupported function parameters.");
}

@("negative.multipleOutParameters")
unittest {
    q{
        void add(int left, out int right) {
            right = left + 2;
        }

        unittest {
            int value = 0;
            add(40, value);
            assert(value == 42);
        }
    }.runTests.shouldThrowWithMessage("Unsupported function parameters.");
}

@("negative.ifBodyAssignment")
unittest {
    q{
        int answer(int value) {
            if (value == 1)
                value = 2;

            return value;
        }

        unittest {
            assert(answer(1) == 2);
        }
    }.runTests.shouldThrowWithMessage("Unsupported if-branch: expected return");
}

@("negative.divisionByZero")
unittest {
    q{
        int answer() {
            int zero = 0;
            return 42 / zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests.shouldThrowWithMessage("Integer division by zero.");
}

@("negative.divisionByZeroCall")
unittest {
    q{
        int zero() {
            return 0;
        }

        int answer() {
            return 42 / zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests.shouldThrowWithMessage("Integer division by zero.");
}

@("negative.moduloByZero")
unittest {
    q{
        int answer() {
            int zero = 0;
            return 42 % zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests.shouldThrowWithMessage("Integer modulo by zero.");
}

@("negative.moduloByZeroCall")
unittest {
    q{
        int zero() {
            return 0;
        }

        int answer() {
            return 42 % zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests.shouldThrowWithMessage("Integer modulo by zero.");
}

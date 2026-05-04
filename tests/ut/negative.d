module ut.negative;


import quickbite;
import unit_threaded;


@("negative.voidFunction")
unittest {
    q{
        void foo() {}

        unittest {
            foo();
        }
    }.runTests.shouldThrowWithMessage("Unsupported function body.");
}

@("negative.multiStatementBody")
unittest {
    q{
        int answer() {
            int value;
            return value;
        }

        unittest {
            assert(answer() == 0);
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
            assert(answer() == 0);
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

@("negative.multipleCallArgs")
unittest {
    q{
        int answer(int left, int right) {
            return left + right;
        }

        unittest {
            assert(answer(40, 2) == 42);
        }
    }.runTests.shouldThrowWithMessage("Unsupported call.");
}

@("negative.notEqual")
unittest {
    q{
        int answer() {
            return 1;
        }

        unittest {
            assert(answer != 2);
        }
    }.runTests.shouldThrowWithMessage("Unsupported expression: notEqual");
}

@("negative.divisionByZero")
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

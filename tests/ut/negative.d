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
    }.runTests().shouldThrowWithMessage("Unsupported function body.");
}

@("negative.multiStatementBody")
unittest {
    q{
        int answer() {
            int value = 42;
            return value;
        }

        unittest {
            assert(answer() == 42);
        }
    }.runTests().shouldThrowWithMessage("Unsupported expression.");
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
    }.runTests().shouldThrowWithMessage("Unsupported expression.");
}

@("negative.unsupportedAssert")
unittest {
    q{
        unittest {
            int value;
            assert(value);
        }
    }.runTests().shouldThrowWithMessage("Unsupported expression.");
}

@("negative.callWithArgs")
unittest {
    q{
        int answer(int value) {
            return value;
        }

        unittest {
            assert(answer(42) == 42);
        }
    }.runTests().shouldThrowWithMessage("Unsupported call.");
}

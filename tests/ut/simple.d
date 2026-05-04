module ut.simple;

import quickbite;
import unit_threaded;

@("simple.ok")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests();
}

@("simple.localIntReturn")
unittest {
    q{
        int answer() {
            int value = 42;
            return value;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests();
}

@("simple.localIntReturnOops")
unittest {
    q{
        int answer() {
            int value = 42;
            return value;
        }

        unittest {
            assert(answer == 43);
        }
    }.runTests().shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.oops")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 43);
        }
    }.runTests().shouldThrowWithMessage("Unittest assertion failed.");
}

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
            assert(answer() == 42);
        }
    }.runTests();
}

@("simple.oops")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer() == 43);
        }
    }.runTests().shouldThrowWithMessage("Unittest assertion failed.");
}

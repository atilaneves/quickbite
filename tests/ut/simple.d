module ut.simple;

import quickbite;
import unit_threaded;

@("simple")
unittest
{
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer() == 42);
        }
    }.runTests();
}

@("simple fails")
unittest
{
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer() == 43);
        }
    }.runTests().shouldThrowWithMessage("Unittest assertion failed.");
}

module tests.simple;

import quickbite;
import unit_threaded;
import unit_threaded.integration: Sandbox;

@("simple")
unittest
{
    with (immutable Sandbox())
    {
        writeFile(
            "test.d",
            q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 42);
                }
            }
        );

        shouldExist("test.d");
    }
}

module ut.ir;

import quickbite;
import unit_threaded;

@("ir.scalarStructPassedToFunction")
unittest {
    q{
        struct Value {
            int value;
        }

        int read(Value wrapper) {
            return wrapper.value;
        }

        unittest {
            Value wrapper;
            wrapper.value = 42;
            assert(read(wrapper) == 42);
        }
    }.runTests(ExecutorBackend.ir);
}


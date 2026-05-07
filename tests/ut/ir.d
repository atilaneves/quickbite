module ut.ir;

import quickbite;
import unit_threaded;

@("ir.ulongHighBitLessOrEqual")
unittest {
    q{
        unittest {
            auto value = 0x8070605040302010UL;
            assert(0UL <= value);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.ulongHighBitGreaterOrEqual")
unittest {
    q{
        unittest {
            auto value = 0x8070605040302010UL;
            assert(value >= 0UL);
        }
    }.runTests(ExecutorBackend.ir);
}

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


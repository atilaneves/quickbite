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

@("ir.logicalOrShortCircuit")
unittest {
    q{
        unittest {
            bool left = true;
            int zero = 0;
            assert(left || 42 / zero == 0);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.logicalOr")
unittest {
    q{
        unittest {
            bool left = false;
            bool right = true;
            assert(left || right);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.logicalOrOops")
unittest {
    q{
        unittest {
            bool left = false;
            bool right = false;
            assert(left || right);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Unittest assertion failed.");
}

module ut.ir;

import quickbite;
import unit_threaded;

@("ir.intBitwiseOr")
unittest {
    q{
        unittest {
            auto left = 40;
            auto right = 2;
            assert((left | right) == 42);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.intSubtractAssign")
unittest {
    q{
        unittest {
            auto value = 44;
            value -= 2;
            assert(value == 42);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.intUnaryMinus")
unittest {
    q{
        int input() {
            return 42;
        }

        int answer() {
            return -input;
        }

        unittest {
            assert(answer == -42);
        }
    }.runTests(ExecutorBackend.ir);
}

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

@("ir.logicalNot")
unittest {
    q{
        unittest {
            bool isReady = false;
            assert(!isReady);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.logicalNotCall")
unittest {
    q{
        bool isReady() {
            return false;
        }

        unittest {
            assert(!isReady);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.logicalAnd")
unittest {
    q{
        unittest {
            bool left = true;
            bool right = true;
            assert(left && right);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.logicalAndCall")
unittest {
    q{
        bool left() {
            return true;
        }

        bool right() {
            return true;
        }

        unittest {
            assert(left && right);
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.logicalAndShortCircuit")
unittest {
    q{
        unittest {
            bool left = false;
            int zero = 0;
            assert(!(left && 42 / zero == 0));
        }
    }.runTests(ExecutorBackend.ir);
}

@("ir.logicalAndCallShortCircuit")
unittest {
    q{
        bool isReady() {
            return false;
        }

        bool failIfCalled() {
            assert(0);
            return true;
        }

        unittest {
            assert(!(isReady && failIfCalled));
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

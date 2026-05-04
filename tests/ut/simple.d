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
    }.runTests;
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
    }.runTests;
}

@("simple.intAddition")
unittest {
    q{
        int answer() {
            int value = 40;
            return value + 2;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests;
}

@("simple.intSubtraction")
unittest {
    q{
        int answer() {
            int value = 44;
            return value - 2;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests;
}

@("simple.intMultiplication")
unittest {
    q{
        int answer() {
            int value = 21;
            return value * 2;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests;
}

@("simple.intDivision")
unittest {
    q{
        int answer() {
            int value = 84;
            return value / 2;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests;
}

@("simple.intModulo")
unittest {
    q{
        int answer() {
            int value = 86;
            return value % 44;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests;
}

@("simple.functionParameter")
unittest {
    q{
        int answer(int value) {
            return value + 1;
        }

        unittest {
            assert(answer(41) == 42);
        }
    }.runTests;
}

@("simple.intLessThan")
unittest {
    q{
        int answer() {
            return 41;
        }

        unittest {
            assert(answer < 42);
        }
    }.runTests;
}

@("simple.intLessThanOops")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer < 42);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.functionParameterOops")
unittest {
    q{
        int answer(int value) {
            return value + 1;
        }

        unittest {
            assert(answer(41) == 43);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
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
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
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
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

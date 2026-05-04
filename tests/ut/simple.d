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

@("simple.voidFunction")
unittest {
    q{
        void foo() {}

        unittest {
            foo;
        }
    }.runTests;
}

@("simple.voidFunctionOops")
unittest {
    q{
        void foo() {
            assert(0);
        }

        unittest {
            foo;
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
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

@("simple.functionParameters")
unittest {
    q{
        int answer(int left, int right) {
            return left + right;
        }

        unittest {
            assert(answer(40, 2) == 42);
        }
    }.runTests;
}

@("simple.functionParametersOops")
unittest {
    q{
        int answer(int left, int right) {
            return left + right;
        }

        unittest {
            assert(answer(40, 3) == 42);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.inFunctionParameters")
unittest {
    q{
        void check(in int left, in int right) {
            assert(left + right == 42);
        }

        unittest {
            check(40, 2);
        }
    }.runTests;
}

@("simple.inFunctionParametersOops")
unittest {
    q{
        void check(in int left, in int right) {
            assert(left + right == 42);
        }

        unittest {
            check(40, 3);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.refParameter")
unittest {
    q{
        void addOne(ref int value) {
            value = value + 1;
        }

        unittest {
            int value = 41;
            addOne(value);
            assert(value == 42);
        }
    }.runTests;
}

@("simple.refParameterOops")
unittest {
    q{
        void addOne(ref int value) {
            value = value + 1;
        }

        unittest {
            int value = 41;
            addOne(value);
            assert(value == 43);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.multipleRefParameters")
unittest {
    q{
        void add(int left, ref int right) {
            right = left + right;
        }

        unittest {
            int value = 2;
            add(40, value);
            assert(value == 42);
        }
    }.runTests;
}

@("simple.refSizeTParameter")
unittest {
    q{
        void advance(ref size_t pos) {
            pos = pos + 1;
        }

        unittest {
            size_t pos = 41;
            advance(pos);
            assert(pos == 42);
        }
    }.runTests;
}

@("simple.refSizeTParameterOops")
unittest {
    q{
        void advance(ref size_t pos) {
            pos = pos + 1;
        }

        unittest {
            size_t pos = 41;
            advance(pos);
            assert(pos == 43);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

static foreach (T; imported!"std.meta".AliasSeq!(byte, ubyte, short, ushort)) {
    @("simple.integralType." ~ T.stringof)
    unittest {
        import std.conv: text;

        text(
            "alias T = ",
            T.stringof,
            ";",
            q{
            static if (is(T == byte))
                enum expected = -126;
            else
                enum expected = 130;

            T identity(T value) {
                return value;
            }

            int input() {
                return 130;
            }

            unittest {
                T value = cast(T) input;
                assert(identity(value) == value);
                assert(value == expected);
            }
        }).runTests;
    }
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

@("simple.intLessOrEqual")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer <= 42);
        }
    }.runTests;
}

@("simple.intLessOrEqualOops")
unittest {
    q{
        int answer() {
            return 43;
        }

        unittest {
            assert(answer <= 42);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.intGreaterThan")
unittest {
    q{
        int answer() {
            return 43;
        }

        unittest {
            assert(answer > 42);
        }
    }.runTests;
}

@("simple.intGreaterThanOops")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer > 42);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.intGreaterOrEqual")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer >= 42);
        }
    }.runTests;
}

@("simple.intGreaterOrEqualOops")
unittest {
    q{
        int answer() {
            return 41;
        }

        unittest {
            assert(answer >= 42);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.intNotEqual")
unittest {
    q{
        int answer() {
            return 41;
        }

        unittest {
            assert(answer != 42);
        }
    }.runTests;
}

@("simple.intNotEqualOops")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer != 42);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.ifElse")
unittest {
    q{
        int answer(int value) {
            if (value == 1)
                return 42;
            else
                return 43;
        }

        unittest {
            assert(answer(1) == 42);
            assert(answer(2) == 43);
        }
    }.runTests;
}

@("simple.ifElseOops")
unittest {
    q{
        int answer(int value) {
            if (value == 1)
                return 42;
            else
                return 43;
        }

        unittest {
            assert(answer(2) == 42);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("simple.earlyReturn")
unittest {
    q{
        int answer(int value) {
            if (value == 1)
                return 42;

            return 43;
        }

        unittest {
            assert(answer(1) == 42);
            assert(answer(2) == 43);
        }
    }.runTests;
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

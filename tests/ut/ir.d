module ut.ir;

import quickbite;
import unit_threaded;

@("ir.ok")
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

@("ir.localIntReturn")
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

@("ir.voidFunction")
unittest {
    q{
        void foo() {}

        unittest {
            foo;
        }
    }.runTests;
}

@("ir.voidFunctionOops")
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

@("ir.intAddition")
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

@("ir.intSubtraction")
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
    }.runTests;
}

@("ir.intMultiplication")
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

@("ir.intDivision")
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

@("ir.intModulo")
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

@("ir.intShiftRight")
unittest {
    q{
        unittest {
            // DMD constant-folds all-literal shifts before IR lowering.
            const value = 168;
            const shift = 2;
            assert(value >> shift == 42);
        }
    }.runTests;
}

@("ir.intShiftLeft")
unittest {
    q{
        unittest {
            // DMD constant-folds all-literal shifts and const locals before
            // IR lowering. Mutable locals keep the shift in the lowered AST,
            // so auto is intentional here.
            auto value = 21;
            auto shift = 1;
            assert(value << shift == 42);
        }
    }.runTests;
}

@("ir.intBitwiseOr")
unittest {
    q{
        unittest {
            // DMD constant-folds all-literal bit operations and const locals
            // before IR lowering. Mutable locals keep the bit operation in the
            // lowered AST, so auto is intentional here.
            auto left = 40;
            auto right = 2;
            assert((left | right) == 42);
        }
    }.runTests;
}

@("ir.intBitwiseAnd")
unittest {
    q{
        unittest {
            // DMD constant-folds all-literal bit operations and const locals
            // before IR lowering. Mutable locals keep the bit operation in the
            // lowered AST, so auto is intentional here.
            auto left = 46;
            auto right = 58;
            assert((left & right) == 42);
        }
    }.runTests;
}

@("ir.intBitwiseXor")
unittest {
    q{
        unittest {
            // DMD constant-folds all-literal bit operations and const locals
            // before IR lowering. Mutable locals keep the bit operation in the
            // lowered AST, so auto is intentional here.
            auto left = 0x2e;
            auto right = 0x04;
            assert((left ^ right) == 0x2a);
        }
    }.runTests;
}

@("ir.intBitwiseComplement")
unittest {
    q{
        unittest {
            // DMD constant-folds all-literal bit operations and const locals
            // before IR lowering. Mutable locals keep the bit operation in the
            // lowered AST, so auto is intentional here.
            auto value = 0x2a;
            assert(~value == -0x2b);
        }
    }.runTests;
}

@("ir.intOrAssign")
unittest {
    q{
        unittest {
            // Compound assignment requires a mutable local; auto is intentional
            // because const cannot be assigned to.
            auto value = 0x28u;
            value |= 0x02u;
            assert(value == 0x2au);
        }
    }.runTests;
}

@("ir.intAddAssign")
unittest {
    q{
        unittest {
            // Compound assignment requires a mutable local; auto is intentional
            // because const cannot be assigned to.
            auto value = 40;
            value += 2;
            assert(value == 42);
        }
    }.runTests;
}

@("ir.intSubtractAssign")
unittest {
    q{
        unittest {
            // Compound assignment requires a mutable local; auto is intentional
            // because const cannot be assigned to.
            auto value = 44;
            value -= 2;
            assert(value == 42);
        }
    }.runTests;
}

@("ir.ubyteArrayAppendAssign")
unittest {
    q{
        unittest {
            // Compound assignment requires a mutable local; auto is intentional
            // because const cannot be assigned to.
            auto values = [0x2au];
            values ~= 0x2bu;
            assert(values.length == 2);
        }
    }.runTests;
}

@("ir.ubyteArrayIndexRead")
unittest {
    q{
        unittest {
            // The explicit type is intentional: this exercises ubyte[] rather
            // than the uint[] inferred from unsigned integer literals.
            ubyte[] values = [0x29u, 0x2au];
            assert(values[1] == 0x2au);
        }
    }.runTests;
}

@("ir.ubyteArrayIndexWrite")
unittest {
    q{
        unittest {
            // The explicit type is intentional: this exercises ubyte[] rather
            // than the uint[] inferred from unsigned integer literals.
            ubyte[] values = [0x29u, 0x00u];
            values[1] = 0x2au;
            assert(values[1] == 0x2au);
        }
    }.runTests;
}

@("ir.postIncrementSizeTIndex")
unittest {
    q{
        unittest {
            ubyte[] values = [0x29u, 0x2au];
            size_t index = 0;
            assert(values[index++] == 0x29u);
            assert(index == 1);
        }
    }.runTests;
}

@("ir.scalarStructField")
unittest {
    q{
        struct Value {
            int value;
        }

        unittest {
            Value wrapper;
            wrapper.value = 42;
            assert(wrapper.value == 42);
        }
    }.runTests;
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
    }.runTests;
}

@("ir.refUbyteArrayParameterAppend")
unittest {
    q{
        void appendAnswer(ref ubyte[] values) {
            values ~= 0x2au;
        }

        unittest {
            // The explicit type is intentional: this exercises ubyte[] rather
            // than an inferred array type.
            ubyte[] values = [];
            appendAnswer(values);
            assert(values.length == 1);
            assert(values[0] == 0x2au);
        }
    }.runTests;
}

@("ir.minicerealEncodeUbyte")
unittest {
    import std.file: readText;

    (
        readText("tests/minicereal.d") ~ q{
            unittest {
                ubyte[] output;
                encode!ubyte(0x2au, output);
                assert(output.length == 1);
                assert(output[0] == 0x2au);
            }
        }
    ).runTests;
}

@("ir.functionParameter")
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

@("ir.functionParameters")
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

@("ir.functionParametersOops")
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

@("ir.inFunctionParameters")
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

@("ir.inFunctionParametersOops")
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

@("ir.refParameter")
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

@("ir.refParameterOops")
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

@("ir.multipleRefParameters")
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

@("ir.refSizeTParameter")
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

@("ir.refSizeTParameterOops")
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

static foreach (T; imported!"std.meta".AliasSeq!(
    byte,
    ubyte,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,
)) {
    @("ir.integralType." ~ T.stringof)
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

@("ir.longLiteral")
unittest {
    q{
        long answer() {
            return 2_147_483_648L;
        }

        unittest {
            assert(answer > 0L);
        }
    }.runTests;
}

@("ir.intLessThan")
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

@("ir.intLessThanOops")
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

@("ir.intLessOrEqual")
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

@("ir.intLessOrEqualOops")
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

@("ir.intGreaterThan")
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

@("ir.intGreaterThanOops")
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

@("ir.intGreaterOrEqual")
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

@("ir.intGreaterOrEqualOops")
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

@("ir.intNotEqual")
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

@("ir.intNotEqualOops")
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

@("ir.logicalNot")
unittest {
    q{
        unittest {
            bool isReady = false;
            assert(!isReady);
        }
    }.runTests;
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
    }.runTests;
}

@("ir.logicalAnd")
unittest {
    q{
        unittest {
            bool left = true;
            bool right = true;
            assert(left && right);
        }
    }.runTests;
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
    }.runTests;
}

@("ir.logicalAndShortCircuit")
unittest {
    q{
        unittest {
            bool left = false;
            int zero = 0;
            assert(!(left && 42 / zero == 0));
        }
    }.runTests;
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
    }.runTests;
}

@("ir.logicalOrShortCircuit")
unittest {
    q{
        unittest {
            bool left = true;
            int zero = 0;
            assert(left || 42 / zero == 0);
        }
    }.runTests;
}

@("ir.logicalOrBoolResult")
unittest {
    q{
        unittest {
            assert((2 || false) == true);
        }
    }.runTests;
}

@("ir.logicalOr")
unittest {
    q{
        unittest {
            bool left = false;
            bool right = true;
            assert(left || right);
        }
    }.runTests;
}

@("ir.logicalOrOops")
unittest {
    q{
        unittest {
            bool left = false;
            bool right = false;
            assert(left || right);
        }
    }.runTests.shouldThrowWithMessage("Unittest assertion failed.");
}

@("ir.ifElse")
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

@("ir.ifElseOops")
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

@("ir.ifElseUntakenBranch")
unittest {
    q{
        int zero() {
            return 0;
        }

        int answer(bool left) {
            if (left)
                return 42;
            else
                return 42 / zero;
        }

        unittest {
            assert(answer(true) == 42);
        }
    }.runTests;
}

@("ir.earlyReturn")
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

@("ir.multipleEarlyReturns")
unittest {
    q{
        int answer(int value) {
            if (value == 1)
                return 41;

            if (value == 2)
                return 42;

            return 43;
        }

        unittest {
            assert(answer(1) == 41);
            assert(answer(2) == 42);
            assert(answer(3) == 43);
        }
    }.runTests;
}

@("ir.functionParameterOops")
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

@("ir.localIntReturnOops")
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

@("ir.oops")
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

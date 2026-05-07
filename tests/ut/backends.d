module ut.backends;

private:

import quickbite: ExecutorBackend, runTests;
import std.conv: to;
import std.meta: AliasSeq;
import std.traits: EnumMembers;
import unit_threaded;

static foreach (b; EnumMembers!ExecutorBackend) {
    @(b.to!string ~ ".ok")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".oops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer == 43);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".localIntReturn")
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".localIntReturnOops")
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 43);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".voidFunction")
    unittest {
        runTests(q{
            void foo() {}

            unittest {
                foo;
            }
        }, b);
    }

    @(b.to!string ~ ".voidFunctionOops")
    unittest {
        runTests(q{
            void foo() {
                assert(0);
            }

            unittest {
                foo;
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".intAddition")
    unittest {
        runTests(q{
            int answer() {
                int value = 40;
                return value + 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intSubtraction")
    unittest {
        runTests(q{
            int answer() {
                int value = 44;
                return value - 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intMultiplication")
    unittest {
        runTests(q{
            int answer() {
                int value = 21;
                return value * 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intDivision")
    unittest {
        runTests(q{
            int answer() {
                int value = 84;
                return value / 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intModulo")
    unittest {
        runTests(q{
            int answer() {
                int value = 86;
                return value % 44;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intShiftRight")
    unittest {
        runTests(q{
            unittest {
                const value = 168;
                const shift = 2;
                assert(value >> shift == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intShiftLeft")
    unittest {
        runTests(q{
            unittest {
                auto value = 21;
                auto shift = 1;
                assert(value << shift == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intBitwiseOr")
    unittest {
        runTests(q{
            unittest {
                auto left = 40;
                auto right = 2;
                assert((left | right) == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intBitwiseAnd")
    unittest {
        runTests(q{
            unittest {
                auto left = 46;
                auto right = 58;
                assert((left & right) == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intBitwiseXor")
    unittest {
        runTests(q{
            unittest {
                auto left = 0x2e;
                auto right = 0x04;
                assert((left ^ right) == 0x2a);
            }
        }, b);
    }

    @(b.to!string ~ ".intUnaryMinus")
    unittest {
        runTests(q{
            int input() {
                return 42;
            }

            int answer() {
                return -input;
            }

            unittest {
                assert(answer == -42);
            }
        }, b);
    }

    @(b.to!string ~ ".intBitwiseComplement")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x2a;
                assert(~value == -0x2b);
            }
        }, b);
    }

    @(b.to!string ~ ".intOrAssign")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x28u;
                value |= 0x02u;
                assert(value == 0x2au);
            }
        }, b);
    }

    @(b.to!string ~ ".intSubtractAssign")
    unittest {
        runTests(q{
            unittest {
                auto value = 44;
                value -= 2;
                assert(value == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intAddAssign")
    unittest {
        runTests(q{
            unittest {
                auto value = 40;
                value += 2;
                assert(value == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".ubyteArrayAppendAssign")
    unittest {
        runTests(q{
            unittest {
                auto values = [0x2au];
                values ~= 0x2bu;
                assert(values.length == 2);
            }
        }, b);
    }

    @(b.to!string ~ ".ubyteArrayIndexRead")
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                assert(values[1] == 0x2au);
            }
        }, b);
    }

    @(b.to!string ~ ".ubyteArrayIndexWrite")
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];
                values[1] = 0x2au;
                assert(values[1] == 0x2au);
            }
        }, b);
    }

    @(b.to!string ~ ".postIncrementSizeTIndex")
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;
                assert(values[index++] == 0x29u);
                assert(index == 1);
            }
        }, b);
    }

    @(b.to!string ~ ".refUbyteArrayParameterAppend")
    unittest {
        runTests(q{
            void appendAnswer(ref ubyte[] values) {
                values ~= 0x2au;
            }

            unittest {
                ubyte[] values = [];
                appendAnswer(values);
                assert(values.length == 1);
                assert(values[0] == 0x2au);
            }
        }, b);
    }

    @(b.to!string ~ ".functionParameter")
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".functionParameters")
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 2) == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".functionParametersOops")
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 3) == 42);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".functionParameterOops")
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 43);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".refParameter")
    unittest {
        runTests(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".refParameterOops")
    unittest {
        runTests(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 43);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".intLessThan")
    unittest {
        runTests(q{
            int answer() {
                return 41;
            }

            unittest {
                assert(answer < 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intLessThanOops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer < 42);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".intLessOrEqual")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer <= 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intLessOrEqualOops")
    unittest {
        runTests(q{
            int answer() {
                return 43;
            }

            unittest {
                assert(answer <= 42);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".intGreaterThan")
    unittest {
        runTests(q{
            int answer() {
                return 43;
            }

            unittest {
                assert(answer > 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intGreaterThanOops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer > 42);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".intGreaterOrEqual")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer >= 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intGreaterOrEqualOops")
    unittest {
        runTests(q{
            int answer() {
                return 41;
            }

            unittest {
                assert(answer >= 42);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".intNotEqual")
    unittest {
        runTests(q{
            int answer() {
                return 41;
            }

            unittest {
                assert(answer != 42);
            }
        }, b);
    }

    @(b.to!string ~ ".intNotEqualOops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer != 42);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".ulongHighBitLessThan")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL < value);
            }
        }, b);
    }

    @(b.to!string ~ ".ifElse")
    unittest {
        runTests(q{
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
        }, b);
    }

    @(b.to!string ~ ".ifElseOops")
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(2) == 42);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".ifElseUntakenBranch")
    unittest {
        runTests(q{
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
        }, b);
    }

    @(b.to!string ~ ".earlyReturn")
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 43);
            }
        }, b);
    }

    @(b.to!string ~ ".multipleEarlyReturns")
    unittest {
        runTests(q{
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
        }, b);
    }

    @(b.to!string ~ ".inFunctionParameters")
    unittest {
        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 2);
            }
        }, b);
    }

    @(b.to!string ~ ".inFunctionParametersOops")
    unittest {
        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 3);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".multipleRefParameters")
    unittest {
        runTests(q{
            void add(int left, ref int right) {
                right = left + right;
            }

            unittest {
                int value = 2;
                add(40, value);
                assert(value == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".refSizeTParameter")
    unittest {
        runTests(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".refSizeTParameterOops")
    unittest {
        runTests(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 43);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".longLiteral")
    unittest {
        runTests(q{
            long answer() {
                return 2_147_483_648L;
            }

            unittest {
                assert(answer > 0L);
            }
        }, b);
    }

    @(b.to!string ~ ".ulongHighBitGreaterThan")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value > 0UL);
            }
        }, b);
    }

    @(b.to!string ~ ".scalarStructField")
    unittest {
        runTests(q{
            struct Value {
                int value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 42;
                assert(wrapper.value == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".arrayLength")
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                assert(arr.length == 3);
            }
        }, b);
    }

    @(b.to!string ~ ".emptyArrayLength")
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                assert(arr.length == 0);
            }
        }, b);
    }

    @(b.to!string ~ ".arrayEqualTrue")
    unittest {
        runTests(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 3];
                assert(a[] == b[]);
            }
        }, b);
    }

    @(b.to!string ~ ".arrayEqualFalse")
    unittest {
        runTests(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 4];
                assert(a[] == b[]);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".castUbyteTruncates")
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                assert(cast(ubyte) value == 2);
            }
        }, b);
    }

    @(b.to!string ~ ".ubyteLocalTruncatesOnStore")
    unittest {
        runTests(q{
            unittest {
                int source = 258;
                ubyte value = cast(ubyte) source;
                assert(value == 2);
            }
        }, b);
    }

    @(b.to!string ~ ".ubyteArrayLiteralTruncatesElements")
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];
                assert(arr[0] == 2);
            }
        }, b);
    }

    @(b.to!string ~ ".struct_")
    unittest {
        runTests(q{
            struct Point {
                int x;
                int y;
            }

            int answer() {
                Point p;
                p.x = 21;
                p.y = 21;
                return p.x + p.y;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".structFieldDefaultsToZero")
    unittest {
        runTests(q{
            struct Point {
                int x;
                int y;
            }

            int answer() {
                Point p;
                p.x = 42;
                return p.x + p.y;
            }

            unittest {
                assert(answer == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".structArrayFieldDefaultsToEmpty")
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            unittest {
                Buffer buffer;
                assert(buffer.bytes.length == 0);
            }
        }, b);
    }

    @(b.to!string ~ ".refStructArrayFieldParameter")
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void append42(ref ubyte[] output) {
                output ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                append42(buffer.bytes);
                assert(buffer.bytes.length == 1);
                assert(buffer.bytes[0] == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".structMethodReadsField")
    unittest {
        runTests(q{
            struct Box {
                int value;

                int get() {
                    return value;
                }
            }

            unittest {
                Box box;
                box.value = 42;
                assert(box.get == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".structMethodPassesFieldByRef")
    unittest {
        runTests(q{
            void append42(ref ubyte[] output) {
                output ~= cast(ubyte) 42;
            }

            struct Buffer {
                ubyte[] bytes;

                void append() {
                    append42(bytes);
                }
            }

            unittest {
                Buffer buffer;
                buffer.append;
                assert(buffer.bytes.length == 1);
                assert(buffer.bytes[0] == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".structTemplateMethodPassesFieldByRef")
    unittest {
        runTests(q{
            void appendValue(T)(T value, ref ubyte[] output) {
                output ~= cast(ubyte) value;
            }

            struct Buffer {
                ubyte[] bytes;

                void append(T)(T value) {
                    appendValue(value, bytes);
                }
            }

            unittest {
                Buffer buffer;
                buffer.append(42);
                assert(buffer.bytes.length == 1);
                assert(buffer.bytes[0] == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".structMethodIndexWritesArrayField")
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;

                void patchFirst() {
                    bytes[0] = cast(ubyte) 42;
                }
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [0];
                buffer.patchFirst;
                assert(buffer.bytes[0] == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".structMethodAppendsArrayField")
    unittest {
        runTests(q{
            struct Writer {
                ubyte[] bytes;

                void put(ubyte value) {
                    bytes ~= value;
                }
            }

            unittest {
                Writer writer;
                writer.put(cast(ubyte) 42);
                assert(writer.bytes.length == 1);
                assert(writer.bytes[0] == 42);
            }
        }, b);
    }

    @(b.to!string ~ ".logicalNot")
    unittest {
        runTests(q{
            unittest {
                bool isReady = false;
                assert(!isReady);
            }
        }, b);
    }

    @(b.to!string ~ ".logicalNotCall")
    unittest {
        runTests(q{
            bool isReady() {
                return false;
            }

            unittest {
                assert(!isReady);
            }
        }, b);
    }

    @(b.to!string ~ ".logicalAnd")
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                bool right = true;
                assert(left && right);
            }
        }, b);
    }

    @(b.to!string ~ ".logicalAndCall")
    unittest {
        runTests(q{
            bool left() {
                return true;
            }

            bool right() {
                return true;
            }

            unittest {
                assert(left && right);
            }
        }, b);
    }

    @(b.to!string ~ ".logicalAndShortCircuit")
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0));
            }
        }, b);
    }

    @(b.to!string ~ ".logicalAndCallShortCircuit")
    unittest {
        runTests(q{
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
        }, b);
    }

    @(b.to!string ~ ".logicalOrBoolResult")
    unittest {
        runTests(q{
            unittest {
                assert((2 || false) == true);
            }
        }, b);
    }

    @(b.to!string ~ ".logicalOr")
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                bool right = true;
                assert(left || right);
            }
        }, b);
    }

    @(b.to!string ~ ".logicalOrOops")
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                bool right = false;
                assert(left || right);
            }
        }, b).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(b.to!string ~ ".logicalOrShortCircuit")
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(left || 42 / zero == 0);
            }
        }, b);
    }
}

static foreach (b; EnumMembers!ExecutorBackend) {
    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong)) {
        @(b.to!string ~ ".integralType." ~ T.stringof)
        unittest {
            import std.conv: text;

            runTests(
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
                }),
                b,
            );
        }
    }
}

module ut.language;

private:

import quickbite: ExecutorBackend, runTests;
import std.conv: text;
import std.meta: AliasSeq;
import std.traits: EnumMembers;
import unit_threaded;

static foreach (backend; EnumMembers!ExecutorBackend) {
    @(backend.text ~ ".ok")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".oops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer == 43);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".throwingTest")
    unittest {
        runTests(q{
            unittest {
                throw new Exception("boom");
            }
        }, backend).shouldThrowWithMessage("boom");
    }

    @(backend.text ~ ".catchExceptionDoesNotCatchAssertFailure")
    unittest {
        runTests(q{
            unittest {
                try {
                    assert(false);
                } catch (Exception) {
                }
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".catchExceptionCatchesThrownException")
    unittest {
        runTests(q{
            unittest {
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                }
            }
        }, backend);
    }

    @(backend.text ~ ".throwPreservesExceptionMessage")
    unittest {
        expectRunTestsFailure(q{
            unittest {
                throw new Exception("domain failure");
            }
        }, backend, "domain failure");
    }

    @(backend.text ~ ".shouldThrowFailsWhenExpressionDoesNotThrow")
    unittest {
        import ut.dub_paths: dubImportPaths;

        expectRunTestsFailure(q{
            import unit_threaded;

            unittest {
                shouldThrow(1);
            }
        }, dubImportPaths, backend);
    }

    @(backend.text ~ ".shouldThrowWithMessageChecksMessage")
    unittest {
        import ut.dub_paths: dubImportPaths;

        expectRunTestsFailure(q{
            import unit_threaded;

            void throwActual() {
                throw new Exception("actual");
            }

            unittest {
                shouldThrowWithMessage(throwActual, "expected");
            }
        }, dubImportPaths, backend);
    }

    @(backend.text ~ ".distinguishesFloatingPointValues")
    unittest {
        runTests(q{
            unittest {
                double left = 1.5;
                double right = 2.5;
                assert(left != right);
            }
        }, backend);
    }

    @(backend.text ~ ".supportsContinue")
    unittest {
        runTests(q{
            unittest {
                int sum;
                for (int i = 0; i < 4; ++i) {
                    if (i == 2)
                        continue;
                    sum += i;
                }
                assert(sum == 4);
            }
        }, backend);
    }

    @(backend.text ~ ".supportsSwitch")
    unittest {
        runTests(q{
            unittest {
                int value = 2;
                int result;
                switch (value) {
                    case 1:
                        result = 10;
                        break;
                    case 2:
                        result = 20;
                        break;
                    default:
                        result = 30;
                        break;
                }
                assert(result == 20);
            }
        }, backend);
    }

    static if (backend != ExecutorBackend.dmdCtfe) {
        @(backend.text ~ ".finallyRunsAfterReturn")
        unittest {
            runTests(q{
                int value;

                int setAndReturn() {
                    try {
                        return 1;
                    } finally {
                        value = 42;
                    }
                }

                unittest {
                    assert(setAndReturn == 1);
                    assert(value == 42);
                }
            }, backend);
        }
    }

    @(backend.text ~ ".catchHandlerRuns")
    unittest {
        runTests(q{
            unittest {
                int value;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    value = 42;
                }
                assert(value == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".evaluatesPow")
    unittest {
        runTests(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 8.0);
            }
        }, backend);
    }

    @(backend.text ~ ".functionPointerHashCollisionDetected")
    unittest {
        runTests(q{
            unittest {
                // bAB and a_a produce the same Bernstein hash (602706).
                static int bAB() {
                    return 1;
                }

                static int a_a() {
                    return 2;
                }

                int function() fp = &a_a;
                assert(fp() == 2);
            }
        }, backend);
    }

    @(backend.text ~ ".nestedSliceWritesPropagateToOriginalArray")
    unittest {
        runTests(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 4];
                int[] s2 = s[0 .. 2];
                s2[0] = 99;
                assert(a[1] == 99);
            }
        }, backend);
    }

    @(backend.text ~ ".localIntReturn")
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".localIntReturnOops")
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 43);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".voidFunction")
    unittest {
        runTests(q{
            void foo() {}

            unittest {
                foo;
            }
        }, backend);
    }

    @(backend.text ~ ".structMethodPostIncrementsSizeTField")
    unittest {
        runTests(q{
            struct Cursor {
                size_t pos;

                size_t next() {
                    return pos++;
                }
            }

            unittest {
                Cursor cursor;
                assert(cursor.next == 0);
                assert(cursor.pos == 1);
            }
        }, backend);
    }

    @(backend.text ~ ".structMethodReadsArrayFieldAtPostIncrementedField")
    unittest {
        runTests(q{
            struct Reader {
                ubyte[] bytes;
                size_t pos;

                ubyte next() {
                    return bytes[pos++];
                }
            }

            unittest {
                Reader reader;
                reader.bytes = [42];
                assert(reader.next == 42);
                assert(reader.pos == 1);
            }
        }, backend);
    }

    @(backend.text ~ ".foreachArray")
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                int sum = 0;
                foreach (x; arr)
                    sum = sum + x;
                assert(sum == 6);
            }
        }, backend);
    }

    @(backend.text ~ ".foreachEmptyArray")
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                int count = 0;
                foreach (x; arr)
                    count = count + 1;
                assert(count == 0);
            }
        }, backend);
    }

    @(backend.text ~ ".whileNeverRuns")
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                while (i > 0) {
                    i = i + 1;
                }
                return 42;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".whileRunsOnce")
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 1) {
                    result = 42;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".while_")
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 6) {
                    result = result + 7;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".voidFunctionExplicitReturn")
    unittest {
        runTests(q{
            void foo() {
                return;
            }

            unittest {
                foo;
            }
        }, backend);
    }

    @(backend.text ~ ".voidFunctionOops")
    unittest {
        runTests(q{
            void foo() {
                assert(0);
            }

            unittest {
                foo;
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".intAddition")
    unittest {
        runTests(q{
            int answer() {
                int value = 40;
                return value + 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intSubtraction")
    unittest {
        runTests(q{
            int answer() {
                int value = 44;
                return value - 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intMultiplication")
    unittest {
        runTests(q{
            int answer() {
                int value = 21;
                return value * 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intDivision")
    unittest {
        runTests(q{
            int answer() {
                int value = 84;
                return value / 2;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intModulo")
    unittest {
        runTests(q{
            int answer() {
                int value = 86;
                return value % 44;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intShiftRight")
    unittest {
        runTests(q{
            unittest {
                const value = 168;
                const shift = 2;
                assert(value >> shift == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intShiftLeft")
    unittest {
        runTests(q{
            unittest {
                auto value = 21;
                auto shift = 1;
                assert(value << shift == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intBitwiseOr")
    unittest {
        runTests(q{
            unittest {
                auto left = 40;
                auto right = 2;
                assert((left | right) == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intBitwiseAnd")
    unittest {
        runTests(q{
            unittest {
                auto left = 46;
                auto right = 58;
                assert((left & right) == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intBitwiseXor")
    unittest {
        runTests(q{
            unittest {
                auto left = 0x2e;
                auto right = 0x04;
                assert((left ^ right) == 0x2a);
            }
        }, backend);
    }

    @(backend.text ~ ".intUnaryMinus")
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
        }, backend);
    }

    @(backend.text ~ ".intBitwiseComplement")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x2a;
                assert(~value == -0x2b);
            }
        }, backend);
    }

    @(backend.text ~ ".intOrAssign")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x28u;
                value |= 0x02u;
                assert(value == 0x2au);
            }
        }, backend);
    }

    @(backend.text ~ ".intSubtractAssign")
    unittest {
        runTests(q{
            unittest {
                auto value = 44;
                value -= 2;
                assert(value == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intAddAssign")
    unittest {
        runTests(q{
            unittest {
                auto value = 40;
                value += 2;
                assert(value == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".ubyteArrayAppendAssign")
    unittest {
        runTests(q{
            unittest {
                auto values = [0x2au];
                values ~= 0x2bu;
                assert(values.length == 2);
            }
        }, backend);
    }

    @(backend.text ~ ".ubyteArrayIndexRead")
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                assert(values[1] == 0x2au);
            }
        }, backend);
    }

    @(backend.text ~ ".ubyteArrayIndexWrite")
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];
                values[1] = 0x2au;
                assert(values[1] == 0x2au);
            }
        }, backend);
    }

    @(backend.text ~ ".postIncrementSizeTIndex")
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;
                assert(values[index++] == 0x29u);
                assert(index == 1);
            }
        }, backend);
    }

    @(backend.text ~ ".refUbyteArrayParameterAppend")
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
        }, backend);
    }

    @(backend.text ~ ".functionParameter")
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".functionParameters")
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 2) == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".functionParametersOops")
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 3) == 42);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".functionParameterOops")
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 43);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".refParameter")
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
        }, backend);
    }

    @(backend.text ~ ".refParameterOops")
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
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".intLessThan")
    unittest {
        runTests(q{
            int answer() {
                return 41;
            }

            unittest {
                assert(answer < 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intLessThanOops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer < 42);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".intLessOrEqual")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer <= 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intLessOrEqualOops")
    unittest {
        runTests(q{
            int answer() {
                return 43;
            }

            unittest {
                assert(answer <= 42);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".intGreaterThan")
    unittest {
        runTests(q{
            int answer() {
                return 43;
            }

            unittest {
                assert(answer > 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intGreaterThanOops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer > 42);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".intGreaterOrEqual")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer >= 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intGreaterOrEqualOops")
    unittest {
        runTests(q{
            int answer() {
                return 41;
            }

            unittest {
                assert(answer >= 42);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".intNotEqual")
    unittest {
        runTests(q{
            int answer() {
                return 41;
            }

            unittest {
                assert(answer != 42);
            }
        }, backend);
    }

    @(backend.text ~ ".intNotEqualOops")
    unittest {
        runTests(q{
            int answer() {
                return 42;
            }

            unittest {
                assert(answer != 42);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".ulongHighBitLessThan")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL < value);
            }
        }, backend);
    }

    @(backend.text ~ ".ifBodyAssignment")
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    value = 2;

                return value;
            }

            unittest {
                assert(answer(1) == 2);
            }
        }, backend);
    }

    @(backend.text ~ ".ifElse")
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
        }, backend);
    }

    @(backend.text ~ ".ifElseOops")
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
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".ifElseUntakenBranch")
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
        }, backend);
    }

    @(backend.text ~ ".earlyReturn")
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
        }, backend);
    }

    @(backend.text ~ ".multipleEarlyReturns")
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
        }, backend);
    }

    @(backend.text ~ ".inFunctionParameters")
    unittest {
        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 2);
            }
        }, backend);
    }

    @(backend.text ~ ".inFunctionParametersOops")
    unittest {
        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 3);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".multipleRefParameters")
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
        }, backend);
    }

    @(backend.text ~ ".refSizeTParameter")
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
        }, backend);
    }

    @(backend.text ~ ".refSizeTParameterOops")
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
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".longLiteral")
    unittest {
        runTests(q{
            long answer() {
                return 2_147_483_648L;
            }

            unittest {
                assert(answer > 0L);
            }
        }, backend);
    }

    @(backend.text ~ ".ulongHighBitLessOrEqual")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(0UL <= value);
            }
        }, backend);
    }

    @(backend.text ~ ".ulongHighBitGreaterOrEqual")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value >= 0UL);
            }
        }, backend);
    }

    @(backend.text ~ ".ulongHighBitGreaterThan")
    unittest {
        runTests(q{
            unittest {
                auto value = 0x8070605040302010UL;
                assert(value > 0UL);
            }
        }, backend);
    }

    @(backend.text ~ ".structPassedToFunction")
    unittest {
        runTests(q{
            struct Point {
                int x;
                int y;
            }

            int sum(Point p) {
                return p.x + p.y;
            }

            unittest {
                Point p;
                p.x = 21;
                p.y = 21;
                assert(sum(p) == 42);
            }
        }, backend);
    }

    @(backend.text ~ ".scalarStructPassedToFunction")
    unittest {
        runTests(q{
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
        }, backend);
    }

    @(backend.text ~ ".structByValueMutationDoesNotLeak")
    unittest {
        runTests(q{
            struct Point { int x; }
            void mutate(Point p) { p.x = 99; }
            unittest {
                Point p;
                p.x = 5;
                mutate(p);
                assert(p.x == 5);
            }
        }, backend);
    }

    @(backend.text ~ ".structByValueArrayFieldMutationDoesNotLeak")
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                mutate(buffer);
                assert(buffer.bytes.length == 0);
            }
        }, backend);
    }

    @(backend.text ~ ".structByValueArrayFieldElementMutationLeaks")
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes[0] = 99;
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [cast(ubyte) 1];
                mutate(buffer);
                assert(buffer.bytes[0] == 99);
            }
        }, backend);
    }

    @(backend.text ~ ".scalarStructField")
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
        }, backend);
    }

    @(backend.text ~ ".arrayLength")
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                assert(arr.length == 3);
            }
        }, backend);
    }

    @(backend.text ~ ".emptyArrayLength")
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                assert(arr.length == 0);
            }
        }, backend);
    }

    @(backend.text ~ ".arrayEqualTrue")
    unittest {
        runTests(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 3];
                assert(a[] == b[]);
            }
        }, backend);
    }

    @(backend.text ~ ".arrayEqualFalse")
    unittest {
        runTests(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 4];
                assert(a[] == b[]);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".castUbyteTruncates")
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                assert(cast(ubyte) value == 2);
            }
        }, backend);
    }

    @(backend.text ~ ".ubyteLocalTruncatesOnStore")
    unittest {
        runTests(q{
            unittest {
                int source = 258;
                ubyte value = cast(ubyte) source;
                assert(value == 2);
            }
        }, backend);
    }

    @(backend.text ~ ".ubyteArrayLiteralTruncatesElements")
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];
                assert(arr[0] == 2);
            }
        }, backend);
    }

    @(backend.text ~ ".struct_")
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
        }, backend);
    }

    @(backend.text ~ ".structFieldDefaultsToZero")
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
        }, backend);
    }

    @(backend.text ~ ".structArrayFieldDefaultsToEmpty")
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            unittest {
                Buffer buffer;
                assert(buffer.bytes.length == 0);
            }
        }, backend);
    }

    @(backend.text ~ ".refStructArrayFieldParameter")
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
        }, backend);
    }

    @(backend.text ~ ".structMethodReadsField")
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
        }, backend);
    }

    @(backend.text ~ ".structMethodPassesFieldByRef")
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
        }, backend);
    }

    @(backend.text ~ ".structTemplateMethodPassesFieldByRef")
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
        }, backend);
    }

    @(backend.text ~ ".structMethodIndexWritesArrayField")
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
        }, backend);
    }

    @(backend.text ~ ".structMethodAppendsArrayField")
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
        }, backend);
    }

    @(backend.text ~ ".logicalNot")
    unittest {
        runTests(q{
            unittest {
                bool isReady = false;
                assert(!isReady);
            }
        }, backend);
    }

    @(backend.text ~ ".logicalNotCall")
    unittest {
        runTests(q{
            bool isReady() {
                return false;
            }

            unittest {
                assert(!isReady);
            }
        }, backend);
    }

    @(backend.text ~ ".logicalAnd")
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                bool right = true;
                assert(left && right);
            }
        }, backend);
    }

    @(backend.text ~ ".logicalAndCall")
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
        }, backend);
    }

    @(backend.text ~ ".logicalAndShortCircuit")
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                int zero = 0;
                assert(!(left && 42 / zero == 0));
            }
        }, backend);
    }

    @(backend.text ~ ".logicalAndCallShortCircuit")
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
        }, backend);
    }

    @(backend.text ~ ".logicalOrBoolResult")
    unittest {
        runTests(q{
            unittest {
                assert((2 || false) == true);
            }
        }, backend);
    }

    @(backend.text ~ ".logicalOr")
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                bool right = true;
                assert(left || right);
            }
        }, backend);
    }

    @(backend.text ~ ".logicalOrOops")
    unittest {
        runTests(q{
            unittest {
                bool left = false;
                bool right = false;
                assert(left || right);
            }
        }, backend).shouldThrowWithMessage("Unittest assertion failed.");
    }

    @(backend.text ~ ".logicalOrShortCircuit")
    unittest {
        runTests(q{
            unittest {
                bool left = true;
                int zero = 0;
                assert(left || 42 / zero == 0);
            }
        }, backend);
    }
}

@("treeWalking.unitThreadedCheckRunsPredicate")
unittest {
    import ut.dub_paths: dubImportPaths;

    expectRunTestsFailure(q{
        import unit_threaded;

        unittest {
            check!((int value) => false);
        }
    }, dubImportPaths, ExecutorBackend.treeWalking, "Property failed. Seed: 1. Input: 1");
}

private void expectRunTestsFailure(
    in string source,
    in ExecutorBackend backend,
    in string expectedMessage,
) {
    string[] importPaths;
    expectRunTestsFailure(source, importPaths, backend, expectedMessage);
}

private void expectRunTestsFailure(
    in string source,
    in string[] importPaths,
    in ExecutorBackend backend,
) {
    bool threw;
    try {
        runTests(source, importPaths, backend);
    } catch (Exception) {
        threw = true;
    }
    threw.should == true;
}

private void expectRunTestsFailure(
    in string source,
    in string[] importPaths,
    in ExecutorBackend backend,
    in string expectedMessage,
) {
    bool threw;
    try {
        runTests(source, importPaths, backend);
    } catch (Exception exception) {
        threw = true;
        exception.msg.should == expectedMessage;
    }
    threw.should == true;
}

static foreach (backend; EnumMembers!ExecutorBackend) {
    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong)) {
        @(backend.text ~ ".integralType." ~ T.stringof)
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
                backend,
            );
        }
    }
}

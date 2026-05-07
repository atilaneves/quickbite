module ut.tree_walking;

import quickbite: ExecutorBackend, runTests;
import quickbite.backends.tree_walking: TreeWalkingExecutor;
import unit_threaded;

@("treeWalking.minicerealEncodeUbyte")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                ubyte[] buf;
                encode(cast(ubyte) 42, buf);
                assert(buf.length == 1);
                assert(buf[0] == 42);
            }
        },
    );
}

@("treeWalking.minicerealDecodeUbyte")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                ubyte[] buf = [42];
                size_t pos = 0;
                assert(decode!ubyte(buf, pos) == 42);
                assert(pos == 1);
            }
        },
    );
}

@("treeWalking.minicerealRoundTripNegativeInt")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                const value = -42;
                ubyte[] buf;
                encode(value, buf);
                size_t pos = 0;
                assert(decode!int(buf, pos) == value);
            }
        },
    );
}

@("treeWalking.minicerealStructRoundTripInt")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                Minicereal cereal;
                cereal.put(42);
                size_t pos = 0;
                assert(cereal.get!int(pos) == 42);
                assert(pos == 4);
            }
        },
    );
}

@("treeWalking.minicerealStructDecodeKnownInt")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [4, 3, 2, 1];
                size_t pos = 0;
                assert(cereal.get!int(pos) == 0x01020304);
                assert(pos == 4);
            }
        },
    );
}

@("treeWalking.minicerealStructAppendByte")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                Minicereal cereal;
                cereal.bytes ~= cast(ubyte) 42;
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 42);
                assert(pos == 1);
            }
        },
    );
}

@("treeWalking.minicerealStructEncodeKnownInt")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                Minicereal cereal;
                cereal.put(0x01020304);
                assert(cereal.bytes[] == [4, 3, 2, 1]);
            }
        },
    );
}

@("treeWalking.minicerealStructBoundedSliceBytes")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [1, 2, 3, 4];
                ubyte[] expected = [2, 3];
                assert(cereal.bytes[1 .. 3] == expected[]);
            }
        },
    );
}

@("treeWalking.bitwiseAndMasksLowByte")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            uint value = 0x01020304;
            assert((value & 0xff) == 4);
        }
    });
}

@("treeWalking.bitwiseXorFlipsMaskedByte")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            uint value = 0x01020304;
            assert((value ^ 0xff) == 0x010203fb);
        }
    });
}

@("treeWalking.bitwiseComplementFlipsMaskedByte")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            uint value = 0xffff_ff00;
            assert((~value & 0xff) == 0xff);
        }
    });
}

@("treeWalking.minicerealStructIndexWriteByte")
unittest {
    import std.file: readText;

    (new TreeWalkingExecutor).runTests(
        readText("tests/minicereal.d") ~ q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [0];
                cereal.bytes[0] = cast(ubyte) 42;
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 42);
            }
        },
    );
}

@("treeWalking.structMethodIndexWritesArrayField")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structMethodPostIncrementsSizeTField")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structMethodReadsArrayFieldAtPostIncrementedField")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structMethodAppendsArrayField")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.ok")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.publicApi")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests(ExecutorBackend.treeWalking);
}

@("treeWalking.localIntReturn")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int value = 42;
            return value;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.localIntReturnOops")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int value = 42;
            return value;
        }

        unittest {
            assert(answer == 43);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.oops")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 43);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.voidFunction")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        void foo() {}

        unittest {
            foo;
        }
    });
}

@("treeWalking.voidFunctionExplicitReturn")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        void foo() {
            return;
        }

        unittest {
            foo;
        }
    });
}

@("treeWalking.refParameter")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int setTo43(ref int value) {
            value = 43;
            return 0;
        }

        unittest {
            int value = 42;
            setTo43(value);
            assert(value == 43);
        }
    });
}

@("treeWalking.refArrayParameter")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        void append42(ref ubyte[] output) {
            output ~= cast(ubyte) 42;
        }

        unittest {
            ubyte[] output;
            append42(output);
            assert(output.length == 1);
            assert(output[0] == 42);
        }
    });
}

@("treeWalking.externalCallee")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        extern int externalFunc();

        unittest {
            externalFunc;
        }
    }).shouldThrowWithMessage("No function body to execute.");
}

@("treeWalking.externalCalleeWithArg")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        extern int externalFunc(int value);

        unittest {
            externalFunc(42);
        }
    }).shouldThrowWithMessage("No function body to execute.");
}

@("treeWalking.externalCalleeArgNotEvaluated")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        extern int externalFunc(int value);

        int boom() {
            assert(false);
            return 0;
        }

        unittest {
            externalFunc(boom);
        }
    }).shouldThrowWithMessage("No function body to execute.");
}

@("treeWalking.uninitializedDecl")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int value;
            return value;
        }

        unittest {
            assert(answer == 0);
        }
    }).shouldThrowWithMessage("Unsupported expression: declaration");
}

@("treeWalking.nonLiteralReturn")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int value;

        int answer() {
            return value;
        }

        unittest {
            assert(answer == 0);
        }
    }).shouldThrowWithMessage("Unsupported expression: value");
}

@("treeWalking.callWithArgs")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer(int value) {
            return value;
        }

        unittest {
            assert(answer(42) == 42);
        }
    });
}

@("treeWalking.if_")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int one() { return 1; }

        int answer() {
            if (one == 1)
                return 42;
            return 0;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.ifElse")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int one() { return 1; }

        int answer() {
            if (one == 2)
                return 0;
            else
                return 42;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.ifFalseNoElse")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int one() { return 1; }

        int answer() {
            if (one == 2)
                return 0;
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.while_")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.whileNeverRuns")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.whileRunsOnce")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.struct_")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structFieldDefaultsToZero")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structArrayFieldDefaultsToEmpty")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        struct Buffer {
            ubyte[] bytes;
        }

        unittest {
            Buffer buffer;
            assert(buffer.bytes.length == 0);
        }
    });
}

@("treeWalking.refStructArrayFieldParameter")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structMethodReadsField")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structMethodPassesFieldByRef")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structTemplateMethodPassesFieldByRef")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    });
}

@("treeWalking.structPassedToFunction")
unittest {
    (new TreeWalkingExecutor).runTests(q{
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
    }).shouldThrowWithMessage("Unsupported expression: p");
}

@("treeWalking.notEqual")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three != 5);
        }
    });
}

@("treeWalking.notEqualFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three != 3);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.lessThan")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three < 5);
        }
    });
}

@("treeWalking.ulongHighBitLessThan")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            // `auto` is intentional: const locals can be folded by DMD before
            // the tree walker sees the unsigned comparison.
            auto value = 0x8070605040302010UL;
            assert(0UL < value);
        }
    });
}

@("treeWalking.ulongHighBitGreaterThan")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            // `auto` is intentional: const locals can be folded by DMD before
            // the tree walker sees the unsigned comparison.
            auto value = 0x8070605040302010UL;
            assert(value > 0UL);
        }
    });
}

@("treeWalking.lessThanFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five < 3);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.lessThanFailsAtBoundary")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five < 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.greaterThan")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five > 3);
        }
    });
}

@("treeWalking.greaterThanFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three > 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.greaterThanFailsAtBoundary")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five > 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.lessOrEqual")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three <= 5);
            assert(three <= 3);
        }
    });
}

@("treeWalking.lessOrEqualFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five <= 3);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.greaterOrEqual")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five >= 3);
            assert(five >= 5);
        }
    });
}

@("treeWalking.greaterOrEqualFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three >= 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.addition")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int forty() { return 40; }

        int answer() {
            return forty + 2;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.subtraction")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int fifty() { return 50; }

        int answer() {
            return fifty - 8;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.multiplication")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int six() { return 6; }

        int answer() {
            return six * 7;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.division")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int eightyfour() { return 84; }

        int answer() {
            return eightyfour / 2;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.modulo")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int fortyfive() { return 45; }

        int answer() {
            return fortyfive % 3;
        }

        unittest {
            assert(answer == 0);
        }
    });
}

@("treeWalking.rightShift")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        uint input() { return 0b10101000; }

        unittest {
            assert((input >> 2) == 0b00101010);
        }
    });
}

@("treeWalking.leftShift")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        uint input() { return 0b00101010; }

        unittest {
            assert((input << 2) == 0b10101000);
        }
    });
}

@("treeWalking.bitwiseOrAssign")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            // `auto` is intentional: compound assignment needs a mutable local.
            auto value = 0b00101000u;
            value |= 0b10000000u;
            assert(value == 0b10101000u);
        }
    });
}

@("treeWalking.postIncrement")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            // `auto` is intentional: post-increment needs a mutable local.
            auto pos = 0u;
            assert(pos++ == 0u);
            assert(pos == 1u);
        }
    });
}

@("treeWalking.arrayLength")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [1, 2, 3];
            assert(arr.length == 3);
        }
    });
}

@("treeWalking.emptyArrayLength")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [];
            assert(arr.length == 0);
        }
    });
}

@("treeWalking.arrayIndexRead")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [10, 20, 30];
            assert(arr[1] == 20);
        }
    });
}

@("treeWalking.arrayIndexWrite")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [10, 20, 30];
            arr[1] = 42;
            assert(arr[1] == 42);
        }
    });
}

@("treeWalking.arrayAppend")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr;
            arr ~= cast(ubyte) 42;
            assert(arr.length == 1);
            assert(arr[0] == 42);
        }
    });
}

@("treeWalking.castUbyteTruncates")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            int value = 258;
            assert(cast(ubyte) value == 2);
        }
    });
}

@("treeWalking.ubyteLocalTruncatesOnStore")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            int source = 258;
            ubyte value = cast(ubyte) source;
            assert(value == 2);
        }
    });
}

@("treeWalking.ubyteArrayLiteralTruncatesElements")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            int value = 258;
            ubyte[] arr = [cast(ubyte) value];
            assert(arr[0] == 2);
        }
    });
}

@("treeWalking.arrayEqualTrue")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] a = [1, 2, 3];
            ubyte[] b = [1, 2, 3];
            assert(a[] == b[]);
        }
    });
}

@("treeWalking.arrayEqualFalse")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] a = [1, 2, 3];
            ubyte[] b = [1, 2, 4];
            assert(a[] == b[]);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.foreachArray")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [1, 2, 3];
            int sum = 0;
            foreach (x; arr)
                sum = sum + x;
            assert(sum == 6);
        }
    });
}

@("treeWalking.foreachEmptyArray")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [];
            int count = 0;
            foreach (x; arr)
                count = count + 1;
            assert(count == 0);
        }
    });
}

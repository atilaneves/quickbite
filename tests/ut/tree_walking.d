module ut.tree_walking;

import quickbite.backends.tree_walking: TreeWalkingExecutor;
import unit_threaded;

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

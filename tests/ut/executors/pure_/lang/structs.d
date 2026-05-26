module ut.executors.pure_.lang.structs;


import ut.executors;


private:

import std.conv: text;
import ut.executors: matureExecutorNames;


static foreach (executorName; matureExecutorNames) {
    @("structMethodPostIncrementsSizeTField." ~ executorName.text)
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
        }, executorName);
    }

    @("structMethodReadsArrayFieldAtPostIncrementedField." ~ executorName.text)
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
        }, executorName);
    }

    @("structPassedToFunction." ~ executorName.text)
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
        }, executorName);
    }

    @("scalarStructPassedToFunction." ~ executorName.text)
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
        }, executorName);
    }

    @("structByValueMutationDoesNotLeak." ~ executorName.text)
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
        }, executorName);
    }

    @("structByValueArrayFieldMutationDoesNotLeak." ~ executorName.text)
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
        }, executorName);
    }

    @("structByValueArrayFieldElementMutationLeaks." ~ executorName.text)
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
        }, executorName);
    }

    @("scalarStructField." ~ executorName.text)
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
        }, executorName);
    }

    @("struct_." ~ executorName.text)
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
        }, executorName);
    }

    @("structFieldDefaultsToZero." ~ executorName.text)
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
        }, executorName);
    }

    @("structArrayFieldDefaultsToEmpty." ~ executorName.text)
    unittest {
        runTests(q{
            struct Buffer {
                ubyte[] bytes;
            }

            unittest {
                Buffer buffer;
                assert(buffer.bytes.length == 0);
            }
        }, executorName);
    }

    @("refStructArrayFieldParameter." ~ executorName.text)
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
        }, executorName);
    }

    @("structMethodReadsField." ~ executorName.text)
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
        }, executorName);
    }

    @("structMethodPassesFieldByRef." ~ executorName.text)
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
        }, executorName);
    }

    @("structTemplateMethodPassesFieldByRef." ~ executorName.text)
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
        }, executorName);
    }

    @("structMethodIndexWritesArrayField." ~ executorName.text)
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
        }, executorName);
    }

    @("structMethodAppendsArrayField." ~ executorName.text)
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
        }, executorName);
    }

    @("structMethodCallsStructMethod." ~ executorName.text)
    unittest {
        runTests(q{
            struct Writer {
                ubyte[] bytes;

                void write(ubyte value) {
                    append(value);
                }

                void append(ubyte value) {
                    bytes ~= value;
                }
            }

            unittest {
                Writer writer;
                writer.write(42);

                assert(writer.bytes.length == 1);
                assert(writer.bytes[0] == 42);
            }
        }, executorName);
    }
}

static foreach (executorName; matureExecutorNames ~ [ExecutorName.treeWalking]) {
    @("structConstructorStoresDynamicArrayParameter." ~ executorName.text)
    unittest {
        runTests(q{
            struct Box {
                int[] values;

                this(int[] input) {
                    store(input);
                }

                void store(int[] input) {
                    values = input;
                }
            }

            unittest {
                int first = 40;
                int second = first + 2;
                int[] input = [first, second];

                auto box = Box(input);

                assert(box.values.length == input.length);
                assert(box.values[0] == first);
                assert(box.values[1] == second);
            }
        }, executorName);
    }

    @("dynamicArrayStructFieldReturnValue." ~ executorName.text)
    unittest {
        runTests(q{
            struct Box {
                ubyte[] values;

                this(ubyte[] input) {
                    values = input;
                }

                ubyte[] get() {
                    return values;
                }
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                auto box = Box(values);

                const result = box.get;

                assert(result.length == 2);
                assert(result[0] == first);
                assert(result[1] == second);
            }
        }, executorName);
    }

    @("dynamicArrayReturnValueAssignsStructField." ~ executorName.text)
    unittest {
        runTests(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            struct Box {
                ubyte[] values;

                this(ubyte[] input) {
                    values = input;
                }

                void set(ubyte[] input) {
                    values = identity(input);
                }
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                ubyte[] replacement = [second, first];
                auto box = Box(values);

                box.set(replacement);

                assert(box.values.length == 2);
                assert(box.values[0] == second);
                assert(box.values[1] == first);
            }
        }, executorName);
    }

    @("dynamicArrayStructFieldReturnValueIndexesCallResult." ~ executorName.text)
    unittest {
        runTests(q{
            struct Box {
                ubyte[] values;

                this(ubyte[] input) {
                    values = input;
                }

                ubyte[] get() {
                    return values;
                }
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                auto box = Box(values);

                assert(box.get[1] == second);
            }
        }, executorName);
    }

    @("structMethodPostIncrementsSizeTField." ~ executorName.text)
    unittest {
        runTests(q{
            struct Cursor {
                size_t position;

                size_t read() {
                    return position++;
                }
            }

            unittest {
                Cursor cursor;
                size_t start = 1;
                cursor.position = start;

                assert(cursor.read == start);
                assert(cursor.position == start + 1);
            }
        }, executorName);
    }

    @("structMethodReadsArrayFieldAtPostIncrementedField." ~ executorName.text)
    unittest {
        runTests(q{
            struct Reader {
                ubyte[] bytes;
                size_t position;

                ubyte read() {
                    return bytes[position++];
                }
            }

            unittest {
                Reader reader;
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                reader.bytes = [first, second];
                reader.position = reader.bytes.length - 1;

                const value = reader.read;

                assert(value == second);
                assert(reader.position == reader.bytes.length);
            }
        }, executorName);
    }
}

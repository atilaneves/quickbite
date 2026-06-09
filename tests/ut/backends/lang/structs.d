module ut.backends.lang.structs;


import ut.backends;


static foreach (backend; backends) {
    @("structMethodPostIncrementsSizeTField." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structMethodPostIncrementsSizeTFieldFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Cursor {
                size_t pos;

                size_t next() {
                    return pos++;
                }
            }

            unittest {
                Cursor cursor;
                assert(cursor.next == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }
}

static foreach (backend; backends) {

    @("structMethodPostIncrementsSizeTFieldFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Cursor {
                size_t pos;

                size_t next() {
                    return pos++;
                }
            }

            unittest {
                Cursor cursor;
                cursor.next;
                assert(cursor.pos == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("structMethodReadsArrayFieldAtPostIncrementedField." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structMethodReadsArrayFieldAtPostIncrementedFieldFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(reader.next == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structMethodReadsArrayFieldAtPostIncrementedFieldFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                ubyte[] bytes;
                size_t pos;

                ubyte next() {
                    return bytes[pos++];
                }
            }

            unittest {
                Reader reader;
                reader.bytes = [41, 42];
                reader.pos = 1;
                assert(reader.next == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structPassedToFunction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("structPassedToFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(sum(p) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structPassedToFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
            }

            int sum(Point p) {
                return p.x + p.y;
            }

            unittest {
                Point p;
                p.x = 10;
                p.y = 32;
                assert(sum(p) == 41);
            }
        }).shouldThrowWithMessage("42 != 41");
    }
}

static foreach (backend; backends) {

    @("scalarStructPassedToFunction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("scalarStructPassedToFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Value {
                int value;
            }

            int read(Value wrapper) {
                return wrapper.value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 42;
                assert(read(wrapper) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("scalarStructPassedToFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Value {
                int value;
            }

            int read(Value wrapper) {
                return wrapper.value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 7;
                assert(read(wrapper) == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structByValueMutationDoesNotLeak." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; }
            void mutate(Point p) { p.x = 99; }
            unittest {
                Point p;
                p.x = 5;
                mutate(p);
                assert(p.x == 5);
            }
        });
    }
}

static foreach (backend; backends) {

    @("structByValueMutationDoesNotLeakFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; }
            void mutate(Point p) { p.x = 99; }
            unittest {
                Point p;
                p.x = 5;
                mutate(p);
                assert(p.x == 99);
            }
        }).shouldThrowWithMessage("5 != 99");
    }
}

static foreach (backend; backends) {

    @("structByValueMutationDoesNotLeakFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; }
            void mutate(Point p) { p.x = 99; }
            unittest {
                Point p;
                p.x = 7;
                mutate(p);
                assert(p.x == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structByValueArrayFieldMutationDoesNotLeak." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("structByValueArrayFieldMutationDoesNotLeakFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                mutate(buffer);
                assert(buffer.bytes.length == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }
}

static foreach (backend; backends) {

    @("structByValueArrayFieldMutationDoesNotLeakFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [cast(ubyte) 7];
                mutate(buffer);
                assert(buffer.bytes.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("structByValueArrayFieldElementMutationLeaks." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("structByValueArrayFieldElementMutationLeaksFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(buffer.bytes[0] == 1);
            }
        }).shouldThrowWithMessage("99 != 1");
    }
}

static foreach (backend; backends) {

    @("structByValueArrayFieldElementMutationLeaksFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes[0] = 42;
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [cast(ubyte) 1];
                mutate(buffer);
                assert(buffer.bytes[0] == 99);
            }
        }).shouldThrowWithMessage("42 != 99");
    }
}

static foreach (backend; backends) {

    @("scopeDestructorRunsAtCtfe." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[] sink;

                ~this() {
                    sink[0] += 3;
                }
            }

            int result(int seed) {
                int[] sink = [seed];
                {
                    S s = S(sink);
                }
                return sink[0];
            }

            unittest {
                assert(result(4) == 7);
            }
        });
    }
}

static foreach (backend; backends) {

    @("scopeDestructorRunsAtCtfeFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[] sink;

                ~this() {
                    sink[0] += 3;
                }
            }

            int result(int seed) {
                int[] sink = [seed];
                {
                    S s = S(sink);
                }
                return sink[0];
            }

            unittest {
                assert(result(4) == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("scopeDestructorRunsAtCtfeFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[] sink;

                ~this() {
                    sink[0] += 3;
                }
            }

            int result(int seed) {
                int[] sink = [seed];
                {
                    S s = S(sink);
                }
                return sink[0];
            }

            unittest {
                assert(result(7) == 11);
            }
        }).shouldThrowWithMessage("10 != 11");
    }
}

static foreach (backend; backends) {

    @("structStaticArrayCopyRunsPostblitAndDtors." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Tracker {
                int* postblits;
                int* dtors;

                this(this) {
                    ++*postblits;
                }

                ~this() {
                    ++*dtors;
                }
            }

            unittest {
                int postblits = 0;
                int dtors = 0;
                {
                    Tracker[2] source;
                    source[0].postblits = &postblits;
                    source[0].dtors = &dtors;
                    source[1].postblits = &postblits;
                    source[1].dtors = &dtors;

                    Tracker[2] copy = source;

                    assert(postblits == 2);
                    assert(dtors == 0);
                }

                assert(dtors == 4);
            }
        });
    }
}

static foreach (backend; backends) {

    @("structStaticArrayCopyRunsPostblitAndDtorsFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Tracker {
                int* postblits;
                int* dtors;

                this(this) {
                    ++*postblits;
                }

                ~this() {
                    ++*dtors;
                }
            }

            unittest {
                int postblits = 0;
                int dtors = 0;
                {
                    Tracker[2] source;
                    source[0].postblits = &postblits;
                    source[0].dtors = &dtors;
                    source[1].postblits = &postblits;
                    source[1].dtors = &dtors;

                    Tracker[2] copy = source;

                    assert(postblits == 3);
                }
            }
        }).shouldThrowWithMessage("2 != 3");
    }
}

static foreach (backend; backends) {

    @("structStaticArrayCopyRunsPostblitAndDtorsFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Tracker {
                int* postblits;
                int* dtors;

                this(this) {
                    ++*postblits;
                }

                ~this() {
                    ++*dtors;
                }
            }

            unittest {
                int postblits = 0;
                int dtors = 0;
                {
                    Tracker[2] source;
                    source[0].postblits = &postblits;
                    source[0].dtors = &dtors;
                    source[1].postblits = &postblits;
                    source[1].dtors = &dtors;

                    Tracker[2] copy = source;

                    assert(dtors == 1);
                }
            }
        }).shouldThrowWithMessage("0 != 1");
    }
}

static foreach (backend; backends) {

    @("scalarStructField." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Value {
                int value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 42;
                assert(wrapper.value == 42);
            }
        });
    }
}

static foreach (backend; backends) {

    @("scalarStructFieldFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Value {
                int value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 42;
                assert(wrapper.value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("scalarStructFieldFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Value {
                int value;
            }

            unittest {
                Value wrapper;
                wrapper.value = 7;
                assert(wrapper.value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("struct_." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("struct_FailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("struct_FailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
            }

            int answer() {
                Point p;
                p.x = 3;
                p.y = 4;
                return p.x + p.y;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("withStructInstanceUsesRuntimeShapedFields." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
            }

            int total(Point point) {
                auto scale = 2;
                with (point) {
                    x += scale;
                    y += x;
                    return x + y;
                }
            }

            unittest {
                Point point;
                point.x = 3;
                point.y = 5;
                assert(total(point) == 15);
            }
        });
    }
}

static foreach (backend; backends) {

    @("withStructInstanceUsesRuntimeShapedFieldsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
            }

            int total(Point point) {
                auto scale = 2;
                with (point) {
                    x += scale;
                    y += x;
                    return x + y;
                }
            }

            unittest {
                Point point;
                point.x = 3;
                point.y = 5;
                assert(total(point) == 18);
            }
        }).shouldThrowWithMessage("15 != 18");
    }
}

static foreach (backend; backends) {

    @("withStructInstanceUsesRuntimeShapedFieldsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
            }

            int total(Point point) {
                auto scale = 2;
                with (point) {
                    x += scale;
                    y += x;
                    return x + y;
                }
            }

            unittest {
                Point point;
                point.x = 4;
                point.y = 1;
                assert(total(point) == 12);
            }
        }).shouldThrowWithMessage("13 != 12");
    }
}

static foreach (backend; backends) {

    @("withStructLocalGotoRestartsInsideBody." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
            }

            int jumpInsideWith(int seed) {
                Point point;
                point.x = seed;
                with (point) {
                    goto target;
                    x += 100;
                target:
                    x += 1;
                }
                return point.x;
            }

            unittest {
                assert(jumpInsideWith(41) == 42);
            }
        });
    }
}

static foreach (backend; backends) {

    @("withStructLocalGotoRestartsInsideBodyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
            }

            int jumpInsideWith(int seed) {
                Point point;
                point.x = seed;
                with (point) {
                    goto target;
                    x += 100;
                target:
                    x += 1;
                }
                return point.x;
            }

            unittest {
                assert(jumpInsideWith(41) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("withStructLocalGotoRestartsInsideBodyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
            }

            int jumpInsideWith(int seed) {
                Point point;
                point.x = seed;
                with (point) {
                    goto target;
                    x += 100;
                target:
                    x += 1;
                }
                return point.x;
            }

            unittest {
                assert(jumpInsideWith(7) == 108);
            }
        }).shouldThrowWithMessage("8 != 108");
    }
}

static foreach (backend; backends) {

    @("withEnumExecutesBody." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum Mode {
                off = 2,
                on = 5,
            }

            int selectedTotal(int seed) {
                int total = seed;
                with (Mode) {
                    total += cast(int) on;
                    total += cast(int) off;
                }
                return total;
            }

            unittest {
                assert(selectedTotal(3) == 10);
            }
        });
    }
}

static foreach (backend; backends) {

    @("withEnumExecutesBodyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum Mode {
                off = 2,
                on = 5,
            }

            int selectedTotal(int seed) {
                int total = seed;
                with (Mode) {
                    total += cast(int) on;
                    total += cast(int) off;
                }
                return total;
            }

            unittest {
                assert(selectedTotal(3) == 11);
            }
        }).shouldThrowWithMessage("10 != 11");
    }
}

static foreach (backend; backends) {

    @("withEnumExecutesBodyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum Mode {
                off = 2,
                on = 5,
            }

            int selectedTotal(int seed) {
                int total = seed;
                with (Mode) {
                    total += cast(int) on;
                    total += cast(int) off;
                }
                return total;
            }

            unittest {
                assert(selectedTotal(4) == 10);
            }
        }).shouldThrowWithMessage("11 != 10");
    }
}

static foreach (backend; backends) {

    @("structFieldDefaultsToZero." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structFieldDefaultsToZeroFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structFieldDefaultsToZeroFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
            }

            int answer() {
                Point p;
                p.x = 7;
                return p.x + p.y;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structArrayFieldDefaultsToEmpty." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            unittest {
                Buffer buffer;
                assert(buffer.bytes.length == 0);
            }
        });
    }
}

static foreach (backend; backends) {

    @("structArrayFieldDefaultsToEmptyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            unittest {
                Buffer buffer;
                assert(buffer.bytes.length == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }
}

static foreach (backend; backends) {

    @("structArrayFieldDefaultsToEmptyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [cast(ubyte) 42];
                assert(buffer.bytes.length == 0);
            }
        }).shouldThrowWithMessage("1 != 0");
    }
}

static foreach (backend; backends) {

    @("refStructArrayFieldParameter." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("refStructArrayFieldParameterFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void append42(ref ubyte[] output) {
                output ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                append42(buffer.bytes);
                assert(buffer.bytes.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("refStructArrayFieldParameterFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void append42(ref ubyte[] output) {
                output ~= cast(ubyte) 42;
            }

            unittest {
                Buffer buffer;
                append42(buffer.bytes);
                assert(buffer.bytes[0] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structMethodReadsField." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structMethodReadsFieldFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Box {
                int value;

                int get() {
                    return value;
                }
            }

            unittest {
                Box box;
                box.value = 42;
                assert(box.get == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structMethodReadsFieldFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Box {
                int value;

                int get() {
                    return value;
                }
            }

            unittest {
                Box box;
                box.value = 7;
                assert(box.get == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structMethodPassesFieldByRef." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structMethodPassesFieldByRefFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(buffer.bytes.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("structMethodPassesFieldByRefFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(buffer.bytes[0] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structTemplateMethodPassesFieldByRef." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structTemplateMethodPassesFieldByRefFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(buffer.bytes.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("structTemplateMethodPassesFieldByRefFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                buffer.append(7);
                assert(buffer.bytes[0] == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structMethodIndexWritesArrayField." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structMethodIndexWritesArrayFieldFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(buffer.bytes[0] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structMethodIndexWritesArrayFieldFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;

                void patchFirst() {
                    bytes[0] = cast(ubyte) 7;
                }
            }

            unittest {
                Buffer buffer;
                buffer.bytes = [0];
                buffer.patchFirst;
                assert(buffer.bytes[0] == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structMethodAppendsArrayField." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
}

static foreach (backend; backends) {

    @("structMethodAppendsArrayFieldFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void put(ubyte value) {
                    bytes ~= value;
                }
            }

            unittest {
                Writer writer;
                writer.put(cast(ubyte) 42);
                assert(writer.bytes.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("structMethodAppendsArrayFieldFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void put(ubyte value) {
                    bytes ~= value;
                }
            }

            unittest {
                Writer writer;
                writer.put(cast(ubyte) 7);
                assert(writer.bytes[0] == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structMethodCallsStructMethod." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("structMethodCallsStructMethodFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(writer.bytes.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("structMethodCallsStructMethodFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                writer.write(7);

                assert(writer.bytes[0] == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("structConstructorStoresDynamicArrayParameter." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("structConstructorStoresDynamicArrayParameterFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(box.values.length == input.length + 1);
            }
        }).shouldThrowWithMessage("2 != 3");
    }
}

static foreach (backend; backends) {

    @("structConstructorStoresDynamicArrayParameterFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(box.values[1] == first);
            }
        }).shouldThrowWithMessage("42 != 40");
    }
}

static foreach (backend; backends) {

    @("newStructPointerInitializesFields." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int a;
                int b;
            }

            unittest {
                int seed = 20;
                auto p = new Pair(seed, seed + 1);

                assert(p.a + p.b == seed + seed + 1);
            }
        });
    }
}

static foreach (backend; backends) {

    @("newStructPointerInitializesFieldsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int a;
                int b;
            }

            unittest {
                int seed = 20;
                auto p = new Pair(seed, seed + 1);

                assert(p.a + p.b == seed + seed + 2);
            }
        }).shouldThrowWithMessage("41 != 42");
    }
}

static foreach (backend; backends) {

    @("newStructPointerInitializesFieldsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int a;
                int b;
            }

            unittest {
                int seed = 7;
                auto p = new Pair(seed, seed + 1);

                assert(p.a + p.b == seed);
            }
        }).shouldThrowWithMessage("15 != 7");
    }
}

static foreach (backend; backends) {

    @("newStructAllocatesMutableInstance." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int a;
                int b;
            }

            int next(int value) {
                return value + 1;
            }

            unittest {
                int seed = 20;
                auto p = new Pair(seed, next(seed));

                p.a += p.b;
                p.b = next(p.a);

                assert(p.a + p.b == seed * 4 + 3);
            }
        });
    }
}

static foreach (backend; backends) {

    @("newStructAllocatesMutableInstanceFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int a;
                int b;
            }

            int next(int value) {
                return value + 1;
            }

            unittest {
                int seed = 20;
                auto p = new Pair(seed, next(seed));

                p.a += p.b;
                p.b = next(p.a);

                assert(p.a + p.b == seed * 4 + 4);
            }
        }).shouldThrowWithMessage("83 != 84");
    }
}

static foreach (backend; backends) {

    @("newStructAllocatesMutableInstanceFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int a;
                int b;
            }

            int next(int value) {
                return value + 1;
            }

            unittest {
                int seed = 7;
                auto p = new Pair(seed, next(seed));

                p.a += p.b;
                p.b = next(p.a);

                assert(p.a + p.b == seed * 4);
            }
        }).shouldThrowWithMessage("31 != 28");
    }
}

static foreach (backend; backends) {

    @("newStructPointerRunsConstructor." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Box {
                int value;

                this(int seed) {
                    value = seed + 2;
                }
            }

            unittest {
                int seed = 40;
                auto p = new Box(seed);

                assert(p.value == seed + 2);
            }
        });
    }
}

static foreach (backend; backends) {

    @("newStructPointerRunsConstructorFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Box {
                int value;

                this(int seed) {
                    value = seed + 2;
                }
            }

            unittest {
                int seed = 40;
                auto p = new Box(seed);

                assert(p.value == seed + 3);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("newStructPointerRunsConstructorFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Box {
                int value;

                this(int seed) {
                    value = seed + 2;
                }
            }

            unittest {
                int seed = 7;
                auto p = new Box(seed);

                assert(p.value == seed);
            }
        }).shouldThrowWithMessage("9 != 7");
    }
}

static foreach (backend; backends) {

    @("nestedStructReadsCapturedLocalThroughDefaultInit." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 40;
                int bump = 2;

                struct Inner {
                    int readBase() {
                        return seed;
                    }
                }

                Inner inner;
                seed += bump;

                assert(inner.readBase == seed);
            }
        });
    }
}

static foreach (backend; backends) {

    @("structLiteralFillsStaticArrayFieldFromScalar." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[3] values;
            }

            unittest {
                int seed = 40;
                seed += 2;

                auto s = S(seed);

                assert(s.values[0] == seed);
                assert(s.values[1] == seed);
                assert(s.values[2] == seed);
            }
        });
    }
}

static foreach (backend; backends) {

    @("structLiteralFillsStaticArrayFieldFromScalarFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[3] values;
            }

            unittest {
                int seed = 40;
                seed += 2;

                auto s = S(seed);

                assert(s.values[1] == seed + 1);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

static foreach (backend; backends) {

    @("structLiteralFillsStaticArrayFieldFromScalarFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[3] values;
            }

            unittest {
                int seed = 7;
                seed += 1;

                auto s = S(seed);

                assert(s.values[2] == seed + 1);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("structLiteralDefaultsMissingFieldToZero." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int first;
                int second;
            }

            unittest {
                int seed = 40;
                seed += 2;

                auto pair = Pair(seed);

                assert(pair.first == seed);
                assert(pair.second == 0);
            }
        });
    }
}

static foreach (backend; backends) {

    @("dynamicArrayStructFieldReturnValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("dynamicArrayStructFieldReturnValueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(result.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }
}

static foreach (backend; backends) {

    @("dynamicArrayStructFieldReturnValueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(result[1] == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }
}

static foreach (backend; backends) {

    @("dynamicArrayReturnValueAssignsStructField." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("dynamicArrayReturnValueAssignsStructFieldFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(box.values.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }
}

static foreach (backend; backends) {

    @("dynamicArrayReturnValueAssignsStructFieldFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(box.values[0] == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }
}

static foreach (backend; backends) {

    @("dynamicArrayStructFieldReturnValueIndexesCallResult." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("dynamicArrayStructFieldReturnValueIndexesCallResultFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(box.get[1] == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }
}

static foreach (backend; backends) {

    @("dynamicArrayStructFieldReturnValueIndexesCallResultFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                ubyte first = cast(ubyte) 7;
                ubyte second = cast(ubyte)(first + 1);
                ubyte[] values = [first, second];
                auto box = Box(values);

                assert(box.get[1] == first);
            }
        }).shouldThrowWithMessage("8 != 7");
    }
}

static foreach (backend; backends) {

    @("structMethodPostIncrementsSizeTFieldRuntimeValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("structMethodPostIncrementsSizeTFieldRuntimeValueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(cursor.read == start + 1);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("structMethodPostIncrementsSizeTFieldRuntimeValueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Cursor {
                size_t position;

                size_t read() {
                    return position++;
                }
            }

            unittest {
                Cursor cursor;
                size_t start = 7;
                cursor.position = start;
                cursor.read;

                assert(cursor.position == start + 2);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("structMethodReadsArrayFieldAtPostIncrementedFieldRuntimeValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}

static foreach (backend; backends) {

    @("structMethodReadsArrayFieldAtPostIncrementedFieldRuntimeValueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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

                assert(value == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }
}

static foreach (backend; backends) {

    @("structMethodReadsArrayFieldAtPostIncrementedFieldRuntimeValueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                ubyte[] bytes;
                size_t position;

                ubyte read() {
                    return bytes[position++];
                }
            }

            unittest {
                Reader reader;
                ubyte first = cast(ubyte) 7;
                ubyte second = cast(ubyte)(first + 1);
                reader.bytes = [first, second];
                reader.position = reader.bytes.length - 1;

                const value = reader.read;

                assert(value == first);
            }
        }).shouldThrowWithMessage("8 != 7");
    }
}

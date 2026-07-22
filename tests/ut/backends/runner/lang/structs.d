module ut.backends.runner.lang.structs;


import ut.backends;


/++
    Struct fields, defaults, and basic value construction.
+/
static foreach (backend; Matrix!()) {
    @("struct.scalarFieldReadWrite." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.multipleScalarFields." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("struct.tupleofForeachRefReadsAndWritesFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Record {
                int number;
                bool enabled;
                char marker;
            }

            unittest {
                int seed = 40;
                seed += 2;
                char marker = 'a';

                auto record = Record(seed, false, marker);
                int visited;

                foreach (ref field; record.tupleof) {
                    ++visited;

                    static if (is(typeof(field) == int)) {
                        assert(field == seed);
                        field += 1;
                    } else static if (is(typeof(field) == bool)) {
                        assert(!field);
                        field = true;
                    } else static if (is(typeof(field) == char)) {
                        assert(field == marker);
                        field = 'z';
                    } else {
                        static assert(false);
                    }
                }

                assert(visited == 3);
                assert(record.number == seed + 1);
                assert(record.enabled);
                assert(record.marker == 'z');
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.scalarFieldsDefaultToZero." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.arrayFieldDefaultsToEmpty." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.literalDefaultsMissingFieldToZero." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.literalFillsStaticArrayFieldFromScalar." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Static-array-of-structs element assignment.
+/
// compileStaticArrayElementAssign (5662306d) took a struct-typed
// static-array element assignment's copy width from the element's opcode
// scalar type, which is void_ for aggregates, so it copied zero bytes and
// silently discarded the write.
static foreach (backend; Matrix!()) {
    @("struct.staticArrayOfStructsElementAssignmentWritesFields." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct P {
                int a;
                int b;
            }

            unittest {
                int a = 3;
                int b = 4;
                P[2] arr;

                arr[1] = P(a, b);

                assert(arr[1].a == a);
                assert(arr[1].b == b);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.staticArrayOfStructsElementAssignmentsAreIndependent." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct P {
                int a;
                int b;
            }

            unittest {
                int a0 = 1;
                int b0 = 2;
                int a1 = 3;
                int b1 = 4;
                P[2] arr;

                arr[0] = P(a0, b0);
                arr[1] = P(a1, b1);

                assert(arr[0].a == a0);
                assert(arr[0].b == b0);
                assert(arr[1].a == a1);
                assert(arr[1].b == b1);
            }
        });
    }
}


/++
    Struct literal string fields.
+/
// compileStructLiteralInto's generic field-copy branch (203e1984) copied
// size(scalarType(fieldType)) bytes per field, which is 0 for a string
// field, so a literal's string descriptor was never written and read back
// as whatever the zeroed block or leftover data-segment bytes gave.
static foreach (backend; Matrix!()) {
    @("struct.literalStringFieldRoundTrips." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                string s;
            }

            unittest {
                string seed = "hi";
                auto x = S(seed);

                assert(x.s == "hi");
                assert(x.s.length == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.literalStringFieldCopiedToLocalPreservesLength." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                string s;
            }

            unittest {
                string seed = "hi";
                auto x = S(seed);
                string t = x.s;

                assert(t.length == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.literalStringFieldReturnedFromFunctionPreservesLength." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                string s;
            }

            string f() {
                string seed = "hi";
                auto x = S(seed);
                return x.s;
            }

            unittest {
                assert(f().length == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.literalWithMixedScalarStringAndFloatingFields." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct M {
                int i;
                string s;
                double d;
            }

            unittest {
                int seed = 1;
                string label = "ab";
                double weight = 2.5;

                auto m = M(seed, label, weight);

                assert(m.i == seed && m.s == label && m.d == weight);
            }
        });
    }
}


/++
    Passing structs by value.
+/
static foreach (backend; Matrix!()) {
    @("struct.scalarStructPassedToFunction." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.multiFieldStructPassedToFunction." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.byValueScalarFieldMutationDoesNotLeak." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
            }

            void mutate(Point p) {
                p.x = 99;
            }

            unittest {
                Point p;
                p.x = 5;

                mutate(p);

                assert(p.x == 5);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.byValueArrayDescriptorMutationDoesNotLeak." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                ubyte[] bytes;
            }

            void mutate(Buffer buffer) {
                buffer.bytes ~= cast(ubyte) 42;
            }

            unittest {
                Buffer empty;
                mutate(empty);

                assert(empty.bytes.length == 0);

                Buffer nonEmpty;
                nonEmpty.bytes = [cast(ubyte) 7];
                mutate(nonEmpty);

                assert(nonEmpty.bytes.length == 1);
                assert(nonEmpty.bytes[0] == 7);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.byValueArrayElementMutationLeaksThroughSlice." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Struct methods.
+/
static foreach (backend; Matrix!()) {
    @("struct.methodReadsField." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodPostIncrementsSizeTField." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodPostIncrementsRuntimeSizeTField." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodReadsArrayFieldAtPostIncrementedField." ~
        backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodReadsArrayFieldAtRuntimePostIncrementedField." ~
        backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodIndexWritesArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodAppendsArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodCallsStructMethod." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Ref parameters involving struct fields.
+/
static foreach (backend; Matrix!()) {
    @("struct.arrayFieldPassedByRef." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.methodPassesFieldByRef." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.templateMethodPassesFieldByRef." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Constructors, `new`, and mutable struct pointers.
+/
static foreach (backend; Matrix!()) {
    @("struct.constructorStoresDynamicArrayParameter." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("struct.templatedConstructorPreservesDynamicArrayField." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                ubyte[] bytes;

                this(T)(T[] input) {
                    bytes = input;
                }
            }

            unittest {
                ubyte seed = 40;
                seed += 2;

                auto reader = Reader([seed]);

                assert(reader.bytes.length == 1);
                assert(reader.bytes[0] == seed);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.newPointerInitializesFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int a;
                int b;
            }

            unittest {
                int seed = 20;
                auto p = new Pair(seed, seed + 1);

                assert(p.a == seed);
                assert(p.b == seed + 1);
                assert(p.a + p.b == seed + seed + 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.newPointerAllocatesMutableInstance." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.newPointerRunsConstructor." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Struct constructor call used as a value.
+/
// structBaseOffsetOrMaterialise's CallExp branch (a6f0c15d) used
// compileCall(call).offset as a struct constructor call's (`S(args)`)
// result location. DMD types `S(args)` as the constructed struct even
// though its `__ctor` is declared void, so compileCall's destination for
// it was the shared void-call dummy slot (frame offset 0), not the
// constructed value, which actually lives at the call's own receiver
// offset. The dummy slot being a fixed offset means a naive fixture with
// no other frame value at offset 0 reads back the constructed field
// correctly by coincidence; each fixture below carries an extra
// runtime parameter (`other`) so the field read is checked against a
// distinct value the dummy slot could plausibly alias, not just `seed`
// itself.
static foreach (backend; Matrix!()) {
    @("struct.constructorCallUsedAsValueReadsConstructedField." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;

                this(int v) {
                    x = v;
                }
            }

            bool check(int other) {
                int seed = 42;
                auto x = S(seed).x;
                return x == seed && x != other;
            }

            unittest {
                assert(check(1));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.constructorCallReassignedToExistingLocalReadsConstructedField." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;

                this(int v) {
                    x = v;
                }
            }

            bool check(int other) {
                S s;
                int seed = 7;
                s = S(seed);
                return s.x == seed && s.x != other;
            }

            unittest {
                assert(check(99));
            }
        });
    }
}


/++
    Dynamic array struct field return values.
+/
static foreach (backend; Matrix!()) {
    @("struct.dynamicArrayFieldReturnValue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.dynamicArrayReturnValueAssignsField." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("struct.dynamicArrayFieldReturnValueIndexesCallResult." ~
        backend.stringof)
    @Tags(backend.stringof)
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


/++
    `with`.
+/
static foreach (backend; Matrix!()) {
    @("with.structInstanceUsesRuntimeShapedFields." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("with.structLocalGotoRestartsInsideBody." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("with.enumExecutesBody." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Destructors, postblits, and lifetime effects.
+/
static foreach (backend; Matrix!()) {
    @("struct.scopeDestructorRunsAtCtfe." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "static-array copy postblit dereferences a null counter pointer"),
)) {
    @("struct.staticArrayCopyRunsPostblitAndDtors." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Nested structs.
+/
static foreach (backend; Matrix!()) {
    @("struct.nestedReadsCapturedLocalThroughDefaultInit." ~ backend.stringof)
    @Tags(backend.stringof)
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

// A plain nested named function reading the enclosing method's `this` (not a
// capturing lambda) through a module-level (non-function-nested) struct.
static foreach (backend; Matrix!()) {
    @("struct.nestedFunctionReadsCapturedThisField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int f;

                int m() {
                    int helper() {
                        return this.f;
                    }
                    return helper();
                }
            }

            unittest {
                S s;
                s.f = 10;

                assert(s.m == 10);
            }
        });
    }
}

// Sibling of the fixture above, but `helper` also reads an enclosing local
// (`x`), not just `this`. Bytecode currently throws its own clean diagnostic
// on the captured-local read rather than producing a wrong value: no closure
// environment is built for a function claimed as this-receiver-shaped, so `x`
// never resolves.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws \"Unsupported variable in bytecode core: x\" for the captured local read"),
)) {
    @("struct.nestedFunctionReadsCapturedLocalAndThisField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int f;

                int m() {
                    int x = 3;

                    int helper() {
                        return x + this.f;
                    }

                    return helper();
                }
            }

            unittest {
                S s;
                s.f = 10;

                assert(s.m == 13);
            }
        });
    }
}

// Bytecode ("Unsupported bytecode assignment target.") and IR (unmapped struct
// type assert) cannot run struct-typed fields yet.
static foreach (backend; Matrix!()) {
    @("struct.fieldChainReadsInnerStructMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int v;
            }

            struct Outer {
                Inner inner;
            }

            Outer make(int seed) {
                Outer o;
                o.inner.v = seed + 2;
                return o;
            }

            unittest {
                Outer outer = make(40);

                assert(outer.inner.v == 42);
            }
        });
    }
}


/++
    Struct equality.
+/
// Bytecode ("Unsupported bytecode assignment target.") and IR (unmapped struct
// type assert) cannot run struct equality yet.
static foreach (backend; Matrix!()) {
    @("struct.defaultEqualityComparesFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
            }

            Point make(int seed) {
                Point p;
                p.x = seed;
                p.y = seed + 1;
                return p;
            }

            unittest {
                assert(make(3) == make(3));
                assert(make(3) != make(4));
            }
        });
    }
}

// Same VM-backend limitations as struct.defaultEqualityComparesFields above.
static foreach (backend; Matrix!()) {
    @("struct.customOpEquals." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct CaseId {
                int id;

                bool opEquals(in CaseId other) const {
                    return id == other.id;
                }
            }

            CaseId make(int seed) {
                CaseId c;
                c.id = seed;
                return c;
            }

            unittest {
                assert(make(7) == make(7));
                assert(make(7) != make(8));
            }
        });
    }
}

// Bytecode ("Unsupported bytecode assignment target."), Bytecode
// ("Unsupported type in bytecode core: Rank"), and IR (unmapped struct type
// assert) cannot run struct-typed values yet.
static foreach (backend; Matrix!()) {
    @("struct.opCmpOrdersValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Rank {
                int level;

                int opCmp(in Rank other) const {
                    return level - other.level;
                }
            }

            Rank make(int seed) {
                Rank r;
                r.level = seed;
                return r;
            }

            unittest {
                assert(make(1) < make(2));
                assert(make(2) > make(1));
                assert(make(3) >= make(3));
                assert(make(3) <= make(3));
            }
        });
    }
}

// Same VM-backend limitations as struct.opCmpOrdersValues above.
static foreach (backend; Matrix!()) {
    @("struct.opBinaryAddsOperands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Money {
                int cents;

                Money opBinary(string op: "+")(in Money other) const {
                    Money result;
                    result.cents = cents + other.cents;
                    return result;
                }
            }

            Money make(int seed) {
                Money m;
                m.cents = seed;
                return m;
            }

            unittest {
                assert((make(40) + make(2)).cents == 42);
            }
        });
    }
}

// Same VM-backend limitations as struct.opCmpOrdersValues above.
static foreach (backend; Matrix!()) {
    @("struct.opIndexSelectsElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int first;
                int second;

                int opIndex(in int index) const {
                    return index == 0 ? first : second;
                }
            }

            Pair make(int seed) {
                Pair p;
                p.first = seed;
                p.second = seed + 1;
                return p;
            }

            unittest {
                assert(make(5)[0] == 5);
                assert(make(5)[1] == 6);
            }
        });
    }
}

// Same VM-backend limitations as struct.opCmpOrdersValues above.
static foreach (backend; Matrix!()) {
    @("struct.opUnaryNegatesValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Score {
                int value;

                Score opUnary(string op: "-")() const {
                    Score result;
                    result.value = -value;
                    return result;
                }
            }

            Score make(int seed) {
                Score s;
                s.value = seed;
                return s;
            }

            unittest {
                assert((-make(7)).value == -7);
            }
        });
    }
}

// Same VM-backend limitations as struct.opCmpOrdersValues above.
static foreach (backend; Matrix!()) {
    @("struct.opAssignFromScalar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Setting {
                int value;

                void opAssign(in int newValue) {
                    value = newValue;
                }
            }

            int seed(int value) {
                return value;
            }

            unittest {
                Setting s;
                s = seed(42);
                assert(s.value == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.voidInitialisedFieldSliceAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                char[16] bytes;
            }

            size_t fill(string source) {
                Buffer buffer = void;

                buffer.bytes[0 .. source.length] = source[];
                buffer.bytes[source.length] = 0;

                return source.length;
            }

            unittest {
                assert(fill("hello") == 5);
            }
        });
    }
}

// DMD emits the char[16] default init as a sparse ArrayLiteralExp: every
// element null, the char.init value carried in `basis`.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "static-array struct field storage does not support a sparse array-literal initializer"),
)) {
    @("struct.staticCharArrayFieldDefaultInit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct HasBuffer {
                char[16] buf;
            }

            unittest {
                HasBuffer b;

                assert(b.buf[0] == char.init);
                assert(b.buf[15] == char.init);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("struct.defaultInitPreservesStaticCharArrayAndScalarFieldDefaults." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Header {
                char[2] label = "OK";
                int revision = 42;
            }

            unittest {
                Header header;

                assert(header.label[0] == 'O');
                assert(header.label[1] == 'K');
                assert(header.revision == 42);
            }
        });
    }
}

// DMD lowers a `Tuple` construction's field assignment into a `TupleExp` in
// expression position (per-field assignments). The interpreter evaluates the
// prefix `e0` then each element in order.
static foreach (backend; Matrix!()) {
    @("struct.tupleConstructionFromLocals." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.typecons: Tuple;

            unittest {
                int first = 1;
                int second = 2;
                auto pair = Tuple!(int, int)(first, second);
                assert(pair[0] == 1);
                assert(pair[1] == 2);
            }
        });
    }
}

// The dependency-free distillation: `target.tupleof = source.tupleof` lowers to
// a `TupleExp` of per-field assignments, the same root construct.
static foreach (backend; Matrix!()) {
    @("struct.tupleofAssignmentCopiesFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                int head;
                long tail;
            }

            unittest {
                auto source = Pair(2, 3L);
                Pair target;
                target.tupleof = source.tupleof;
                assert(target.head == 2);
                assert(target.tail == 3);
            }
        });
    }
}

// cerealed's `grainWithLengthInBytesAttr` grows an array-typed FIELD of a
// `ref` struct parameter with `__traits(getMember, val, member).length++;`.
// dmd lowers postfix `.length++` on a field access through a synthetic `ref`
// local (`ref int[] __tmp = h.arr; ... _d_arraysetlengthT(__tmp, ...)`),
// unlike plain `.length = .length + 1`, which resizes the field directly.
// Keep this fixture's index deliberately `$`-free (`arr[arr.length - 1]`): a
// distinct `$`/`lengthVar`-ordering bug in the assignment-target path
// (`Walker.runIndexAssignExpression`'s `DotVarExp` branch) affects
// `h.arr[$ - 1] = ...` and is exercised separately (see the fixture below),
// not fixed here, to keep this fixture pinned to the one root it exposes.
static foreach (backend; Matrix!()) {
    @("struct.postfixLengthIncrementGrowsRefParamArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder { int[] arr; }

            void growByOne(ref Holder h) {
                h.arr.length++;
                h.arr[h.arr.length - 1] = 7;
            }

            unittest {
                Holder h;
                growByOne(h);
                assert(h.arr.length == 1);
                assert(h.arr[0] == 7);
            }
        });
    }
}

// This is the `$`/`lengthVar`-ordering bug named in the fixture above:
// `Walker.runIndexAssignExpression`'s `DotVarExp` branch (impl.d) used to
// evaluate `index.e2` before running `index.e1`/seeding `index.lengthVar`,
// so `$` inside an index-ASSIGN target through a struct FIELD (`h.arr[$ -
// 1] = ...`) read a stale/default-zero length and underflowed. This is
// the write-path counterpart of the read-path fix in
// `dynamicArray.dollarReflectsLengthAfterInPlaceGrowth` (arrays.d).
static foreach (backend; Matrix!()) {
    @("struct.dollarInIndexAssignReflectsFieldLengthAfterGrowth." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder { int[] arr; }

            void fillLast(ref Holder h) {
                h.arr.length = 3;
                h.arr[$ - 1] = 9;
            }

            unittest {
                Holder h;
                fillLast(h);
                assert(h.arr.length == 3);
                assert(h.arr[2] == 9);
            }
        });
    }
}

// cerealed's cereal.d (`ubyte b = void; cereal.grain(b);` inside the
// isOutputRange `grain(U, C, T)` template, then `val.put(b)`) writes a
// void-initialised local through two nested `ref`-forwarding calls before
// reading it back.
static foreach (backend; Matrix!()) {
    @("refArgument.voidLocalIsReadableAfterNestedRefWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void writeByte(ref ubyte val) {
                val = 42;
            }

            void grain(ref ubyte val) {
                writeByte(val);
            }

            ubyte readGrain() {
                ubyte b = void;
                grain(b);
                return b;
            }

            unittest {
                assert(readGrain() == 42);
            }
        });
    }
}

// cerealed's `shouldEqual(*dec.value!(int*), *i)` (pointers.d's
// `pointer.to.int` test) passes a dereferenced decode-and-return-a-pointer
// call as a `ref` argument to a comparison function that never assigns to
// its parameter. `Walker.writeBackRefArguments` (impl.d) wrote back through
// every `ref` argument unconditionally, even when the callee never touched
// it; for a `PtrExp` argument, `writeLocation`'s `*ptr = ...` branch
// re-evaluates `ptr.e1` to find the write destination, re-running
// `decodeNext()` a second time on an already-exhausted decoder and throwing
// a bogus `RangeError` instead of the intended comparison. Real D never
// re-evaluates a `ref` argument's lvalue after the call: it binds the
// address once. Root: skip the write-back (and its re-evaluation) whenever
// the parameter's value is unchanged after the call.
static foreach (backend; Matrix!()) {
    @("refArgument.sideEffectingPointerDerefNotReEvaluatedWhenUnwritten." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Decoder {
                int[] values;

                int* decodeNext() {
                    auto value = new int;
                    *value = values[0];
                    values = values[1 .. $];
                    return value;
                }
            }

            void compare(ref int actual, ref int expected) {
                assert(actual == expected);
            }

            unittest {
                auto dec = Decoder([4]);
                int expected = 4;
                compare(*dec.decodeNext(), expected);
                assert(dec.values.length == 0);
            }
        });
    }
}

// Sibling of the fix just above: the unchanged-
// parameter skip check compared `Value`s with plain `==`, which is wrong for
// floating scalars two ways. `-0.0 == 0.0` is true, so a callee that
// genuinely rewrites a negative zero to a positive zero got its write-back
// silently dropped (a regression, not merely a missed optimisation) — this
// fixture pins that case. `Walker.identicalValues` (impl.d) now compares
// floating scalars by bit pattern (D's `is` semantics), matching real D's
// actual `-0.0`/`+0.0` distinction, and defers to `==` for everything else.
static foreach (backend; Matrix!()) {
    @("refArgument.floatWriteBackSkipComparesBitPatternNotEquality." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void setPositiveZero(ref double x) {
                x = 0.0;
            }

            double negativeZero() {
                return -0.0;
            }

            unittest {
                double d = negativeZero;
                setPositiveZero(d);
                assert(1.0 / d == double.infinity);
            }
        });
    }
}

// `frame_layout`'s reference slot for a `ref`/`out` parameter (`value.md`'s
// Remaining work item 5) composes the caller-side address of a `ref`
// argument's own lvalue at bind time and stores it in the callee's frame,
// purely as an internal, bind-time-verified shadow -- authority stays
// boxed, so every fixture below only re-confirms `SystemLinker`-oracle
// behaviour that already worked, now exercised through the new wiring.
static foreach (backend; Matrix!()) {
    @("refArgument.scalarParameterMutatedByCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void increment(ref int x) {
                x = x + 1;
            }

            unittest {
                int value = 41;
                increment(value);
                assert(value == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("refArgument.structParameterMutatedByCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }

            void moveBy(ref Point p, int dx, int dy) {
                p.x = p.x + dx;
                p.y = p.y + dy;
            }

            unittest {
                Point p = Point(1, 2);
                moveBy(p, 10, 20);
                assert(p.x == 11);
                assert(p.y == 22);
            }
        });
    }
}

// The caller-side base resolver (`impl.d`'s `callerReferenceBase`) must
// resolve a `ref` argument's dataseg (`__gshared`) root variable through
// the shared `moduleTable`, not the caller's own `_activationFrame` (a
// dataseg variable owns no frame slot at all -- `frame_layout.
// isAliasingLocal`). `Ctfe` cannot read or write dataseg storage at all
// (compile-time execution has no such storage to access, the same
// pre-existing limitation `dataseg.moduleScalarAndStructMirroredAcrossWrites`
// in expressions.d already pins); `Bytecode` refuses a dataseg variable as
// a `ref` argument.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
    Omit!(Bytecode, Because.refusal,
        "Unsupported ref argument in bytecode core: counter"),
)) {
    @("refArgument.datasegVariableArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            __gshared int counter;

            void bump(ref int x) {
                x = x + 1;
            }

            unittest {
                counter = 5;
                bump(counter);
                assert(counter == 6);
            }
        });
    }
}

// An indexed element (`IndexExp` over a constant index -- `impl.d`'s
// `constantIndex` only accepts DMD's own already-folded integer constant,
// never a runtime-evaluated one, to avoid evaluating a side-effecting
// index a second time) composes through `lvalue_place.placeOfLvalue`'s
// existing `IndexExp` shape. `Bytecode` answers a wrong value rather than
// refusing, pinned below.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.diverges,
        "a write through a `ref` argument written `arr[1]` never reaches " ~
        "element 1"),
)) {
    @("refArgument.indexedElementArgumentComposesReferenceSlot." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                int[3] arr = [1, 2, 3];
                setTo(arr[1], 99);
                assert(arr[0] == 1);
                assert(arr[1] == 99);
                assert(arr[2] == 3);
            }
        });
    }
}

// The `Because.diverges` pin the fixture above owes: Bytecode's own actual
// answer, hand-listed because no `SystemLinker`-oracle expectation applies
// to it. Element 1 still holds its initializer after the write, while the
// elements either side of it are untouched.
static foreach (backend; AliasSeq!(Bytecode)) {
    @("refArgument.indexedElementArgumentLeavesTheElementUnwritten." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                int[3] arr = [1, 2, 3];
                setTo(arr[1], 99);
                assert(arr[0] == 1);
                assert(arr[1] == 99);
                assert(arr[2] == 3);
            }
        }).shouldThrowWithMessage("2 != 99");
    }
}

// A struct field (`DotVarExp`) composes through `lvalue_place.
// placeOfLvalue`'s existing field shape.
static foreach (backend; Matrix!()) {
    @("refArgument.fieldArgumentComposesReferenceSlot." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder { int value; }

            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                Holder h;
                setTo(h.value, 77);
                assert(h.value == 77);
            }
        });
    }
}

// A ternary/conditional expression (`CondExp`) is a legal `ref` argument
// in D (its lvalue-ness follows whichever branch is taken), but an lvalue
// shape `lvalue_place.placeOfLvalue` does not compose (it throws, by its
// own documented contract -- "every other lvalue shape refuses rather
// than guesses"); `impl.d`'s `bindReferenceSlot` must decline silently --
// leaving the reference slot unfilled -- rather than propagate that
// throw, and boxed authority (unaffected either way) must still produce
// the correct, oracle-matching result. `Bytecode` answers a wrong value
// rather than refusing, pinned below.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.diverges,
        "a write through a `ref` argument written `cond ? a : b` never " ~
        "reaches `a`"),
)) {
    @("refArgument.nonComposingShapeArgumentDeclinesSilently." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                int a = 1;
                int b = 2;
                bool cond = true;
                setTo(cond ? a : b, 55);
                assert(a == 55);
                assert(b == 2);
            }
        });
    }
}

// The `Because.diverges` pin the fixture above owes: Bytecode's own actual
// answer, hand-listed because no `SystemLinker`-oracle expectation applies
// to it. `a` still holds its initializer after the call.
static foreach (backend; AliasSeq!(Bytecode)) {
    @("refArgument.nonComposingShapeArgumentLeavesTheTargetUnwritten." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                int a = 1;
                int b = 2;
                bool cond = true;
                setTo(cond ? a : b, 55);
                assert(a == 55);
                assert(b == 2);
            }
        }).shouldThrowWithMessage("1 != 55");
    }
}

// Recursion forwards the SAME `ref` parameter into the next activation's
// own `ref` argument: `impl.d`'s `callerReferenceBase` must resolve a
// `VarExp` that is itself the caller's own `ref` parameter by reading
// THROUGH its already-filled reference slot (`FrameBlock.
// hasReferenceSlot`/`referenceSlotValue`), not by treating the slot's own
// address as the target -- otherwise every recursive level would bind to
// the slot one level up instead of the original root storage.
static foreach (backend; Matrix!()) {
    @("refArgument.recursionForwardsRefParameterAcrossActivations." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void incAndRecurse(ref int x, int depth) {
                x = x + 1;
                if (depth > 0)
                    incAndRecurse(x, depth - 1);
            }

            unittest {
                int value = 0;
                incAndRecurse(value, 3);
                assert(value == 4);
            }
        });
    }
}

// A class-typed receiver's field as a `ref` argument, where the class local's
// own mirror DECLINED (`C` has a non-composable `int[]` field, so
// `mirrorClassToFrame` never establishes a body for it and the frame slot
// stays GC-zeroed). `impl.d`'s `bindReferenceSlot` composed
// `receiver.deref.field(x)` off that zeroed slot -- `null + fieldOffset`,
// non-null and so past the `address is null` guard -- and then dereferenced
// it in `assertReferenceBind`: SIGSEGV on a perfectly legal program.
// Composition must consult what the write side actually DID for the base
// variable, not assume a slot it never filled. `Bytecode` refuses a class
// field as a `ref` argument.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "Unsupported ref argument in bytecode core: holder.value"),
)) {
    @("refArgument.classFieldArgumentWithDeclinedClassMirror." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Holder {
                int[] elements;
                int value;
            }

            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                auto holder = new Holder;
                setTo(holder.value, 88);
                assert(holder.value == 88);
            }
        });
    }
}

// The boxed-carrier sibling of the fixture above: a pointer to a struct local
// whose own mirror never established storage the composition can reach, with
// the field reached through the pointer (`PtrExp`/`DotVarExp`). Same rule --
// the address is composed from a slot the write side may never have filled,
// so composition must decline rather than deref whatever the slot happens to
// hold. `Bytecode` refuses a pointer-carried field as a `ref` argument.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "Unsupported ref argument in bytecode core: (*carrier).value"),
)) {
    @("refArgument.pointerCarriedFieldArgumentComposesSafely." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int[] elements;
                int value;
            }

            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                Holder holder;
                Holder* carrier = &holder;
                setTo(carrier.value, 66);
                assert(holder.value == 66);
            }
        });
    }
}

// A cell-promoted local (address taken, so `scalarCells` -- not the frame slot
// -- is authoritative for it) passed as a `ref` argument. The frame slot is
// deliberately left stale by `writeBackLocalPointerTargets`, while the boxed
// argument is read THROUGH the cell, so bind-time verification compared a
// stale slot against a fresh value and asserted "reference slot bind diverged
// from boxed argument" on a correct program. Verification must skip exactly
// where `assertFrameMirror` already skips.
static foreach (backend; Matrix!()) {
    @("refArgument.cellPromotedLocalArgumentSkipsBindVerification." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void bump(int* q) {
                *q = 2;
            }

            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                int value = 1;
                int* pointer = &value;
                bump(pointer);
                assert(value == 2);
                setTo(value, 3);
                assert(value == 3);
            }
        });
    }
}

// Non-crashing sibling of the declined-mirror crash above: the class local's
// mirror was established, then DECLINED later (two bindings referencing the
// same object make the class identity aliased), so the object body stops being
// updated and holds a stale field. Composing an address off that body and
// verifying against the boxed argument then fires "reference slot bind
// diverged from boxed argument" on a correct program: the verify decision must
// re-derive the write side's own current decline, not merely "was it ever
// established". `Bytecode` refuses a class field as a `ref` argument.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "Unsupported ref argument in bytecode core: first.value"),
)) {
    @("refArgument.classFieldArgumentAfterAliasedIdentityDecline." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Holder {
                int value;
            }

            void setTo(ref int x, int value) {
                x = value;
            }

            unittest {
                auto first = new Holder;
                first.value = 1;
                auto second = first;
                first.value = 2;
                setTo(first.value, 3);
                assert(first.value == 3);
                assert(second.value == 3);
            }
        });
    }
}

// The cross-activation sibling of the fixture above: `parent`'s mirror is
// established and no cell owns it, so bind-time composition happily walks
// through its body -- but the nested `child` body it reaches is SHARED, and
// `bump`'s own parameter mirror already rewrote it to 7 in an activation
// that has since returned, while the caller's boxed `parent` still says 6.
// Composition crossing a class body must therefore decline verification the
// same way the ordinary read path does, or the bind asserts "reference slot
// bind diverged from boxed argument" on a correct program. `Bytecode`
// refuses a class field as a `ref` argument.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "Unsupported ref argument in bytecode core: parent.child.x"),
)) {
    @("refArgument.nestedClassFieldArgumentAfterCalleeRewroteSharedBody." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            void bump(Child c) {
                c.x = c.x + 1;
            }

            void setTo(ref int y, int value) {
                y = value;
            }

            unittest {
                auto parent = new Parent;
                parent.child = new Child;
                parent.child.x = 6;
                bump(parent.child);
                setTo(parent.child.x, 9);
                assert(parent.child.x == 9);
            }
        });
    }
}

// cerealed's `@ArrayLength` field decode (`Unit[] units; ... foreach(ref e;
// units) cereal.grain(e);` inside a `ref Packet val` parameter) writes each
// element's fields through a hidden temporary dmd's foreach-to-for lowering
// introduces: `T[] __r = val.units[]; for (...; ) { ref Unit e = __r[__k]; }`.
// `Walker.recordSliceAlias` (impl.d) only recognised the sliced aggregate
// (`slice.e1`) when it was a plain local `VarExp`, so a `DotVarExp` aggregate
// (a struct field, here `val.units`) left `__r` untracked as a slice alias:
// writes to `e`'s fields updated the interpreter's local snapshot of `__r`
// but never propagated back to `val.units`, so the caller's array element
// silently kept its default value.
static foreach (backend; Matrix!()) {
    @("struct.foreachRefOverFieldArrayPersistsElementWrites." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Item { ushort a; ubyte b; }
            struct Container { Item[] items; }

            void fill(ref Item item, ubyte hi, ubyte lo, ubyte b) {
                item.a = cast(ushort) ((hi << 8) | lo);
                item.b = b;
            }

            void fillAll(ref Container container, ubyte[] bytes) {
                container.items.length = 2;
                size_t i;
                foreach (ref item; container.items) {
                    fill(item, bytes[i], bytes[i + 1], bytes[i + 2]);
                    i += 3;
                }
            }

            unittest {
                Container container;
                fillAll(container, [0, 6, 2, 0, 7, 3]);
                assert(container.items[0].a == 6);
                assert(container.items[0].b == 2);
                assert(container.items[1].a == 7);
                assert(container.items[1].b == 3);
            }
        });
    }
}

// Repeated forwarding of the same ref-foreach element must preserve its
// identity across every ref parameter. Each mutation therefore reaches the
// same array element instead of competing through independent snapshots.
static foreach (backend; Matrix!()) {
    @("struct.foreachRefRepeatedArgumentPreservesAlias." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Item {
                int x;
                int y;
            }

            void mutate(ref Item first, ref Item second) {
                first.x = 1;
                second.y = 2;
            }

            unittest {
                Item[] items;
                items.length = 1;

                foreach (ref item; items)
                    mutate(item, item);

                assert(items[0].x == 1);
                assert(items[0].y == 2);
            }
        });
    }
}

// Two ref parameters bound from the same plain variable denote one storage
// location, so taking either parameter's address must produce equal pointers.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve repeated ref-argument address identity"),
)) {
    @("struct.repeatedRefArgumentPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int value;
            }

            void verify(ref S first, ref S second) {
                assert(&first == &second);
            }

            unittest {
                S value = S(42);
                verify(value, value);
            }
        });
    }
}

// cerealed's decode of an enum-typed struct field (structs.d's `EnumStruct`
// and `MqttFixedHeader` tests) writes the decoded byte through the field
// without going through an enum-typed literal `IntegerExp`, so `Walker.
// runExpression`'s `Value.enumValue` tagging (impl.d, only reached for an
// `IntegerExp` whose type is `Tenum`) never applies to it: the field ends up
// holding a plain scalar `Value` instead of the `EnumValue` variant a literal
// `Enum.Member` reference produces. Both variants carry the identical numeric
// value. dmd lowers a POD struct's `==` (no user `opEquals`) into an `is`
// expression rather than leaving it an `EqualExp` — confirmed with a
// throwaway trace of `assert_.e1.op` in the `AssertExp` branch, reverted
// before commit — so `Walker.runIdentityExpression` ran the comparison, not
// `runEqualExpression`/`equalValues`: it used a raw `left == right` (`Value`'s
// own `opEquals`, a strict `SumType` compare) with no per-field recursion or
// numeric-scalar coercion, so an `EnumValue`-tagged field never equalled a
// same-valued plain-scalar field even though real D's memberwise struct
// equality does. This is the simplest reproduction: a struct's
// default-initialised enum field (a plain scalar `Value`, per
// `defaultValue`'s `toBasetype`-driven dispatch) against the same enum
// member from a literal-constructed struct. No cast, pointer, or cereal
// machinery needed.
static foreach (backend; Matrix!()) {
    @("struct.equalityComparesEnumFieldByValueAcrossOrigin." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum Enum { Foo, Bar, Baz }
            struct Holder { Enum e; }

            unittest {
                Holder defaultInit;
                auto literal = Holder(Enum.Foo);
                assert(defaultInit == literal);
            }
        });
    }
}

// cerealed's decode of a `@disable this()` struct (decode.d's "Types with
// @disable this can be encoded/decoded" test) uses the `T val = void;`
// property-getter overload (`Decerealiser.value`, `cerealed/decerealiser.d`)
// because `T()` does not compile; `grain(this, val)` then reaches the
// struct's single field only through a nested `ref`-forwarding call
// (`grainAllMembersImpl` -> `grainAggregateMember` -> `grain(__traits(
// getMember, val, member))`), matching this fixture's `writeByte(val.i)`
// inside `grainField`. `Walker.bindFunctionParameters` (impl.d) bound a
// `ref` parameter to the caller's deferred `Value.void_` placeholder
// without marking the parameter itself `uninitializedLocals` in the
// callee's own frame, so a nested `DotVarExp` field read through it saw
// a bare `Value.void_` instead of the materialised default struct
// `runExpression`'s `VarExp` branch already produces for a directly
// uninitialized local.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "nested ref forwarding sees the void-initialized local before materialization"),
)) {
    @("refArgument.voidStructLocalFieldWritableThroughNestedRefWrite." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder { ubyte i; }

            void writeByte(ref ubyte val) {
                val = 42;
            }

            void grainField(ref Holder val) {
                writeByte(val.i);
            }

            ubyte readField() {
                Holder val = void;
                grainField(val);
                return val.i;
            }

            unittest {
                assert(readField() == 42);
            }
        });
    }
}

// Once `foreach (v; a)` has promoted an `arrayCells` entry for `a`
// (`promoteSliceArrayCell` needs no address-of at all), a member-function
// write to that same array reached through a
// struct field (`Holder(a).bump()`, funnelled through
// `writeThroughThisStructArrayFieldAlias`) updated only the boxed mirror,
// never `a`'s promoted cell. `a[0]` reads through the cell-authoritative
// path and so kept answering with the stale, pre-`bump` value.
// `SystemLinker` is the oracle (dynamic arrays share backing storage, so
// `Holder(a).values` aliases `a` and `bump`'s write is visible through
// `a[0]`); other backends omitted per the omit-don't-pin convention
// (unconfirmed there).
static foreach (backend; Matrix!(
)) {
    @("struct.memberFunctionArrayFieldWriteRefreshesSourceArrayCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            struct Holder {
                int[] values;

                void bump() {
                    values[0] += ninetyNine();
                }
            }

            int f() {
                int[] a = [one(), two()];
                int total;
                foreach (v; a)
                    total += v;
                auto h = Holder(a);
                h.bump();
                return a[0];
            }

            unittest {
                assert(f() == 100);
            }
        });
    }
}

// Commit `ff93e303` added
// `child.structFieldPointerWritebacks.remove(variable)` in
// `writeBackStructFieldPointerTargets` as "behaviour-neutral hardening" --
// it is not neutral. An intermediate member-function frame (`Poker.poke`,
// which dups `locals`/`structCells` from its own `this`-bound child
// `Walker`) passes the writeback check at `deposit`'s return and clears the
// flag on ITS OWN throwaway duped copy, so the flag never reaches the frame
// that owns `s` -- a member-function frame has no `writeBackNestedLocals` of
// its own, so the refresh dies with the frame instead of propagating up to
// `f`. Before any production change, Interpreter's `s.x` read 3 (the
// pre-write value) instead of 42. SystemLinker is the oracle; other
// backends omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!(
)) {
    @("struct.memberFunctionForwardsPointerWriteToOwningFrame." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int three() {
                return 3;
            }

            int fortyTwo() {
                return 42;
            }

            struct S {
                int x;
            }

            struct Poker {
                void poke(int* p) {
                    deposit(p);
                }
            }

            void deposit(int* p) {
                *p = fortyTwo();
            }

            int f() {
                S s = S(three());
                int* p = &s.x;
                Poker k;
                k.poke(p);
                return s.x;
            }

            unittest {
                assert(f() == 42);
            }
        });
    }
}

// SystemLinker (the oracle) zero-initializes a union's whole storage block
// from its FIRST declared member's own default value, so an untouched
// sibling scalar reads the first member's bits reinterpreted as its own
// type: here `U`'s first member `float f`'s default is NaN
// (`0x7FC00000`), so `u.i` reads that same bit pattern, not `int.init`
// (`0`). `Ctfe` is deliberately omitted (omit-don't-pin, `ai/mistakes.md`):
// real DMD's own CTFE engine refuses this exact read with `reinterpretation
// through overlapped field 'i' is not allowed in CTFE` -- a genuine
// Ctfe/SystemLinker divergence in DMD itself, not something this repo's
// backends can or should paper over.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this exact read with " ~
        "\"reinterpretation through overlapped field 'i' is not allowed " ~
        "in CTFE\""),
)) {
    @("union.untouchedSiblingDefaultsFromFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                float f;
                int i;
            }

            unittest {
                U u;
                assert(u.i == 0x7FC00000);
            }
        });
    }
}

// DMD flattens an ANONYMOUS union's members into the enclosing struct's own
// `fields` at OVERLAPPING offsets (`ai/plans/value.md`'s Unions section: the
// offsets are the aliasing truth). The enclosing declaration is still a
// plain struct, so treating its fields as independent, non-overlapping
// storage writes both members in declaration order over the same bytes and
// lets the last one win. `real` and `long` never re-derive each other, so
// after `s.l = 42` the boxed `r` is still NaN while the bytes read `42` --
// two members whose snapshots genuinely contradict, which is exactly what
// an explicit union's own stricter gate exists to refuse.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped anonymous-union field"),
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("union.anonymousUnionInStructSurvivesRefBindToOverlappingMember." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                union {
                    real r;
                    long l;
                }
            }

            real observe(ref real x) {
                return x;
            }

            unittest {
                S s;
                s.l = 42;
                observe(s.r);
                assert(s.l == 42);
            }
        });
    }
}


// The same flattened anonymous union one level down, as a member of an
// EXPLICIT union: the enclosing union's own coherence question is asked of
// each member's type, and `S`'s flattened members are both native scalars,
// so nothing but the overlapping-offsets check distinguishes `S` from an
// ordinary two-field struct. Writing through `u.s.a` and binding it by
// `ref` afterwards exercises both the member write and the reference bind
// that the enclosing union's members must agree about.
static foreach (backend; Matrix!()) {
    @("union.anonymousUnionInStructMemberOfUnion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                union {
                    int a;
                    float b;
                }
            }

            union U {
                S s;
                long l;
            }

            int observe(ref int x) {
                return x;
            }

            unittest {
                U u;
                u.s.a = 7;
                assert(observe(u.s.a) == 7);
                assert(u.s.a == 7);
            }
        });
    }
}


// An untouched plain-struct sibling reads the same first-member default bits
// as a scalar sibling. The struct's scalar field spans the first float's NaN
// representation, so independently defaulting the struct would incorrectly
// produce zero.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped struct field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this union struct initializer"),
)) {
    @("union.untouchedStructSiblingDefaultsFromFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Payload {
                int bits;
            }

            union U {
                float value;
                Payload payload;
            }

            unittest {
                U value;
                assert(value.payload.bits == 0x7FC00000);
            }
        });
    }
}

// An untouched static array of scalar-field structs reads the same first-
// member default bits as a plain-struct sibling. Independently defaulting the
// array would incorrectly produce a zero-initialized struct element.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped static-array field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this union static-array-of-struct initializer"),
)) {
    @("union.untouchedStructArraySiblingDefaultsFromFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Payload {
                int bits;
            }

            union U {
                float value;
                Payload[1] payloads;
            }

            unittest {
                U value;
                assert(value.payloads[0].bits == 0x7FC00000);
            }
        });
    }
}

// An untouched nested-union sibling reads the outer union's first-member
// default bytes through its own scalar member. Independently defaulting the
// nested union would incorrectly produce zero.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped nested-union field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this nested-union initializer"),
)) {
    @("union.untouchedNestedUnionSiblingDefaultsFromFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union Payload {
                int bits;
                float value;
            }

            union U {
                float value;
                Payload payload;
            }

            unittest {
                U value;
                assert(value.payload.bits == 0x7FC00000);
            }
        });
    }
}

// A nested union in the first member initializes the outer union's shared
// block from its own first-member default bits. Its scalar sibling therefore
// sees the nested float's NaN representation instead of an independent zero.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped scalar field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this nested-union initializer"),
)) {
    @("union.untouchedSiblingDefaultsFromNestedUnionFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union Payload {
                float value;
                int bits;
            }

            union U {
                Payload payload;
                int bits;
            }

            unittest {
                U value;
                assert(value.bits == 0x7FC00000);
            }
        });
    }
}

// A nested scalar-leaf static array in the first union member initializes
// the same overlapping block as its one-level counterpart. Its first float's
// default NaN bits are therefore visible through the untouched scalar sibling.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped scalar field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this nested-static-array union initializer"),
)) {
    @("union.untouchedSiblingDefaultsFromNestedArrayFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                float[1][1] values;
                int bits;
            }

            unittest {
                U value;
                assert(value.bits == 0x7FC00000);
            }
        });
    }
}

// A static array of scalar-field structs in the first union member still
// initializes the union's shared block from its leaves. Its first float's
// default NaN bits are therefore visible through the scalar sibling.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped scalar field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this static-array-of-struct union initializer"),
)) {
    @("union.untouchedSiblingDefaultsFromStructArrayFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Payload {
                float value;
            }

            union U {
                Payload[1] payloads;
                int bits;
            }

            unittest {
                U value;
                assert(value.bits == 0x7FC00000);
            }
        });
    }
}

// A nested static array of scalar-field structs in the first union member
// initializes the same shared bytes as its one-level counterpart. The first
// struct leaf's default float bits are visible through the scalar sibling.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped scalar field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this nested-array-of-struct union initializer"),
)) {
    @("union.untouchedSiblingDefaultsFromNestedStructArrayFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Payload {
                float value;
            }

            union U {
                Payload[1][1] payloads;
                int bits;
            }

            unittest {
                U value;
                assert(value.bits == 0x7FC00000);
            }
        });
    }
}

// An untouched scalar-element static-array sibling reads the same first-
// member default bits as scalar and plain-struct siblings. Independently
// defaulting the array would incorrectly produce zero.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped static-array field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this union static-array initializer"),
)) {
    @("union.untouchedArraySiblingDefaultsFromFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                float value;
                int[1] bits;
            }

            unittest {
                U value;
                assert(value.bits[0] == 0x7FC00000);
            }
        });
    }
}

// An untouched nested static-array sibling reads the first member's default
// bits through its scalar leaf. Independently defaulting either array level
// would incorrectly produce zero.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped nested static-array field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this union nested-static-array initializer"),
)) {
    @("union.untouchedNestedArraySiblingDefaultsFromFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                float value;
                int[1][1] bits;
            }

            unittest {
                U value;
                assert(value.bits[0][0] == 0x7FC00000);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this exact read with " ~
        "\"reinterpretation through overlapped field 'f' is not allowed " ~
        "in CTFE\""),
)) {
    @("union.writeThroughOneMemberIsVisibleThroughAnother." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                int i;
                float f;
            }

            unittest {
                U u;
                int bits = 1065353216;
                u.i = bits;
                assert(u.f == 1.0f);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this exact read with " ~
        "\"reinterpretation through overlapped field 'f' is not allowed " ~
        "in CTFE\""),
)) {
    @("union.addressTakenFieldSeesWriteThroughSiblingMember." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                int i;
                float f;
            }

            unittest {
                U u;
                int* p = &u.i;
                float value = 1.0f;
                u.f = value;
                assert(*p == 1065353216);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this exact read with " ~
        "\"cannot read uninitialized variable 'a' in CTFE\""),
)) {
    @("union.writeThroughScalarMemberIsVisibleThroughStructMember." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct P {
                int a;
                int b;
            }

            union U {
                P p;
                long l;
            }

            unittest {
                U u;
                int low = 7;
                int high = 13;
                long bits = (cast(long) high << 32) | cast(long) low;
                u.l = bits;
                assert(u.p.a == low && u.p.b == high);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this exact read with " ~
        "\"'u.a[0]' is used before initialized\""),
)) {
    @("union.writeThroughScalarMemberIsVisibleThroughArrayMember." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                int[2] a;
                long l;
            }

            unittest {
                U u;
                int low = 7;
                int high = 13;
                long bits = (cast(long) high << 32) | cast(long) low;
                u.l = bits;
                assert(u.a[0] == low && u.a[1] == high);
            }
        });
    }
}

// The WRITTEN-side counterpart of the fixture above: assigning the WHOLE
// static-array member and reading an overlapping scalar sibling back.
// fa6b5e12's own follow-up flagged this direction as unwidened --
// `withUnionFieldWrite` only handles a scalar-or-struct WRITTEN member, so
// `u.a = [...]` fell through its `!writtenScalar && !writtenStruct` decline
// and left `u.l` on its stale prior value.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this exact read with " ~
        "\"reinterpretation through overlapped field 'l' is not allowed " ~
        "in CTFE\""),
)) {
    @("union.writeThroughArrayMemberIsVisibleThroughScalarMember." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                int[2] a;
                long l;
            }

            unittest {
                U u;
                int low = 7;
                int high = 13;
                u.a = [low, high];
                long bits = (cast(long) high << 32) | cast(long) low;
                assert(u.l == bits);
            }
        });
    }
}

// `withUnionFieldWrite` allocated a FRESH, ZEROED transient cell and seeded
// ONLY the just-written member's own bytes before re-deriving every
// sibling's FULL extent from it -- any sibling WIDER than the written
// member read zeros in the bytes outside the written member's extent
// instead of the union's PRIOR bytes there. Here `a` (8 bytes) is written
// first, then the narrower `i` (4 bytes, aliasing only `a[0]`) is written;
// `a[1]` (the tail outside `i`'s extent) must keep its prior value, not
// read back as zero. `Ctfe` is omitted (omit-don't-pin, `ai/mistakes.md`):
// real DMD's own CTFE engine refuses this overlapped-field read exactly as
// the other write-then-read-a-sibling union fixtures above already found.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this overlapped-field read " ~
        "exactly as the other write-then-read-a-sibling union fixtures " ~
        "above already found"),
)) {
    @("union.writeThroughScalarMemberPreservesWiderArraySiblingTail." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seven() {
                return 7;
            }

            int thirteen() {
                return 13;
            }

            int nine() {
                return 9;
            }

            union U {
                int[2] a;
                int i;
            }

            unittest {
                U u;
                u.a = [seven(), thirteen()];
                u.i = nine();
                assert(u.a[1] == thirteen());
            }
        });
    }
}

// The aggregate-first-member counterpart of
// `union.untouchedSiblingDefaultsFromFirstMemberBits`: `379ef066`'s own
// follow-up flagged that when the FIRST declared member is itself an
// aggregate (here a struct with one scalar field), an untouched sibling
// still fell back to its own independent `defaultValue` instead of
// reinterpreting the first member's default bytes. `P`'s single field
// `x`'s default is NaN (`0x7FC00000`), so `u.i` must read that same bit
// pattern. `Ctfe` is omitted (omit-don't-pin, `ai/mistakes.md`): real
// DMD's own CTFE engine refuses this exact read with the same
// `reinterpretation through overlapped field 'i' is not allowed in CTFE`
// diagnostic as the scalar-first-member sibling fixture.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses this exact read with the " ~
        "same \"reinterpretation through overlapped field 'i' is not " ~
        "allowed in CTFE\" diagnostic as the scalar-first-member " ~
        "sibling fixture"),
)) {
    @("union.untouchedSiblingDefaultsFromStructFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct P {
                float x;
            }

            union U {
                P p;
                int i;
            }

            unittest {
                U u;
                assert(u.i == 0x7FC00000);
            }
        });
    }
}

// A scalar-element static array in the first union member initializes the
// whole overlapping block, just as a scalar or plain-struct first member
// does. Its first float's default NaN bits are therefore visible through the
// untouched scalar sibling.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped scalar field"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support this static-array union initializer"),
)) {
    @("union.untouchedSiblingDefaultsFromArrayFirstMemberBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                float[1] values;
                int bits;
            }

            unittest {
                U value;
                assert(value.bits == 0x7FC00000);
            }
        });
    }
}


// An empty union is legal D: `U u;` declares a one-byte local with no
// member to read. Picking a "widest member" out of an empty member list
// and indexing it kills the whole interpreter with a
// `core.exception.RangeError` on a perfectly ordinary program -- the
// native-layout mirror is a verified shadow of the boxed value and must
// never be the reason a program dies.
static foreach (backend; Matrix!()) {
    @("union.emptyUnionLocalRunsToCompletion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {}

            int twice(int i) {
                U u;
                return i * 2;
            }

            unittest {
                int three = 3;
                assert(twice(three) == 6);
            }
        });
    }
}


// A `real` union member is one no boxed union write path re-derives from a
// sibling's bytes (`real` is deliberately not `native_scalar.
// isNativeScalarType`), so the boxed `Value` for `u` carries `r = real.nan`
// alongside `l = 42` -- two entries that cannot both describe the same
// bytes. Reading `l` back must still give the value just written.
static foreach (backend; Matrix!()) {
    @("union.writeThroughLongMemberSurvivesRealSibling." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                real r;
                long l;
            }

            unittest {
                U u;
                long bits = 42;
                u.l = bits;
                assert(u.l == 42);
            }
        });
    }
}


// The pointer sibling of the fixture above: a pointer union member is not
// re-derived from a sibling's bytes either, so `p` stays `null` in the
// boxed `Value` after `u.l` is written. `p` and `l` are the same width, so
// a "widest member wins" native write would break the tie in `p`'s favour
// and zero the bytes `l` was just given.
static foreach (backend; Matrix!()) {
    @("union.writeThroughLongMemberSurvivesPointerSibling." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            union U {
                int* p;
                long l;
            }

            unittest {
                U u;
                long bits = 42;
                u.l = bits;
                assert(u.l == 42);
            }
        });
    }
}


// The padded-widest-member shape: `S` is 16 bytes with 7 bytes of padding
// after `b`, so a native write that composes `S` field by field never
// touches bytes 9..15 -- bytes the same-width sibling `x` reads as live
// data.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "real DMD's own CTFE engine refuses reinterpretation through the " ~
        "overlapped field"),
)) {
    @("union.writeThroughPaddedStructMemberLeavesArraySiblingTailIntact." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long l;
                byte b;
            }

            union U {
                S s;
                ubyte[16] x;
            }

            unittest {
                U u;
                ubyte marker = 0xFF;
                u.x[12] = marker;
                long bits = 42;
                u.s.l = bits;
                assert(u.x[12] == 0xFF);
            }
        });
    }
}


// A union whose members are all place-composable in isolation but one of
// which is a floating-base enum: the mirror's union arm writes only the
// widest member, and `E` ties with `long` at 8 bytes so first-declared `E`
// wins the tie -- a write `place_value.writeValue` refuses for a
// floating-base enum. Declaring `u` at all takes that path, so the union
// gate must decline this shape rather than let the refusal escape as an
// exception out of the mirror.
static foreach (backend; Matrix!()) {
    @("union.floatingBaseEnumMemberDoesNotEscapeTheMirror." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum E : double { a = 1.5 }

            union U {
                E e;
                long l;
            }

            unittest {
                U u;
                assert(u.e == E.a);
            }
        });
    }
}


// The same shape one level down through a static array: `E[2]` ties with
// `long[2]` at 16 bytes and wins the tie, so the widest-member write
// composes down to a floating-base enum element.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "Unsupported static-array struct field in bytecode core: [1.5, 1.5]"),
)) {
    @("union.floatingBaseEnumArrayMemberDoesNotEscapeTheMirror." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum E : double { a = 1.5 }

            union U {
                E[2] e;
                long[2] l;
            }

            unittest {
                U u;
                assert(u.e[0] == E.a);
            }
        });
    }
}


// And one level down through a struct field: `S` ties with `long` at 8
// bytes and wins the tie, so the widest-member write composes down to a
// floating-base enum field.
static foreach (backend; Matrix!()) {
    @("union.floatingBaseEnumStructMemberDoesNotEscapeTheMirror." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum E : double { a = 1.5 }

            struct S {
                E e;
            }

            union U {
                S s;
                long l;
            }

            unittest {
                U u;
                assert(u.s.e == E.a);
            }
        });
    }
}

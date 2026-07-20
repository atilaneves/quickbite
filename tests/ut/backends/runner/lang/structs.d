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

static foreach (backend; Matrix!()) {
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
// Bytecode ("Unsupported struct initializer in bytecode core: b")
// cannot run struct default initializers yet.
static foreach (backend; Matrix!()) {
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
static foreach (backend; AliasSeq!(Bytecode, Interpreter, SystemLinker)) {
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
static foreach (backend; Matrix!()) {
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
    Omit!(Bytecode, Because.unconfirmed,
        "\"Unsupported struct initializer in bytecode core: u\""),
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
    Omit!(Bytecode, Because.unconfirmed,
        "\"Unsupported left shift in bytecode core: " ~
        "cast(long)high << 32\""),
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
    Omit!(Bytecode, Because.unconfirmed,
        "\"Unsupported left shift in bytecode core: " ~
        "cast(long)high << 32\""),
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
    Omit!(Bytecode, Because.unconfirmed,
        "\"Unsupported type in bytecode core: int[2]\""),
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
    Omit!(Bytecode, Because.unconfirmed,
        "\"Unsupported type in bytecode core: int[2]\""),
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
    Omit!(Bytecode, Because.unconfirmed,
        "\"Unsupported struct initializer in bytecode core: u\""),
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

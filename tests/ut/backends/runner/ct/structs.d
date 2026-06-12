module ut.backends.runner.ct.structs;


import ut.backends;


/++
    Struct fields, defaults, and basic value construction.
+/
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

// Interpreter ("Expected struct."), Bytecode ("Unsupported bytecode assignment
// target."), and IR (unmapped struct type assert) cannot run struct-typed
// fields yet.
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
// Interpreter ("Expected struct."), Bytecode ("Unsupported bytecode assignment
// target."), and IR (unmapped struct type assert) cannot run struct equality
// yet.
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

// Interpreter ("Expected struct."), Bytecode ("Unsupported bytecode assignment
// target."), BytecodeNewCore ("Unsupported type in bytecode core: Rank"), and
// IR (unmapped struct type assert) cannot run struct-typed values yet.
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

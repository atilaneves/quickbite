module ut.backends.runner.ct.structs;


import ut.backends;


/++
    Struct fields, defaults, and basic value construction.
+/
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

// cerealed's `grainWithLengthInBytesAttr` (ffi.md/interpreter.md §9.7,
// 2026-07-13 follow-up) grows an array-typed FIELD of a `ref` struct
// parameter with `__traits(getMember, val, member).length++;`. dmd lowers
// postfix `.length++` on a field access through a synthetic `ref` local
// (`ref int[] __tmp = h.arr; ... _d_arraysetlengthT(__tmp, ...)`), unlike
// plain `.length = .length + 1`, which resizes the field directly. Keep
// this fixture's index deliberately `$`-free (`arr[arr.length - 1]`): a
// distinct `$`/`lengthVar`-ordering bug in the assignment-target path
// (`Walker.runIndexAssignExpression`'s `DotVarExp` branch) affects
// `h.arr[$ - 1] = ...` and is tracked separately in interpreter.md §9.7,
// not fixed here, to keep this fixture pinned to the one root it exposes.
// `Bytecode` omitted: still red there (under active development), per
// interpreter.md §8's omit-don't-pin rule for matrix width.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
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

// The third root named in the fixture above (interpreter.md §9.7):
// `Walker.runIndexAssignExpression`'s `DotVarExp` branch (impl.d) used to
// evaluate `index.e2` before running `index.e1`/seeding `index.lengthVar`,
// so `$` inside an index-ASSIGN target through a struct FIELD (`h.arr[$ -
// 1] = ...`) read a stale/default-zero length and underflowed. This is
// the write-path counterpart of the read-path fix in
// `dynamicArray.dollarReflectsLengthAfterInPlaceGrowth` (arrays.d).
// `Bytecode` omitted: `$` is not implemented there (`Unsupported variable
// in bytecode core: $`), per interpreter.md §8's omit-don't-pin rule.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
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
// reading it back. interpreter.md §9.7 (void-init `ref`-argument reads).
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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
// the parameter's value is unchanged after the call. interpreter.md §9.7.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

// cerealed's `@ArrayLength` field decode (`Unit[] units; ... foreach(ref e;
// units) cereal.grain(e);` inside a `ref Packet val` parameter) writes each
// element's fields through a hidden temporary dmd's foreach-to-for lowering
// introduces: `T[] __r = val.units[]; for (...; ) { ref Unit e = __r[__k]; }`.
// `Walker.recordSliceAlias` (impl.d) only recognised the sliced aggregate
// (`slice.e1`) when it was a plain local `VarExp`, so a `DotVarExp` aggregate
// (a struct field, here `val.units`) left `__r` untracked as a slice alias:
// writes to `e`'s fields updated the interpreter's local snapshot of `__r`
// but never propagated back to `val.units`, so the caller's array element
// silently kept its default value. interpreter.md §9.7. `Bytecode` omitted:
// it segfaults on this fixture (under active development, omit-don't-pin).
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
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
// machinery needed. interpreter.md §9.7.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
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

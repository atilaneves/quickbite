module ut.backends.runner.lang.cerealed;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("projects.cerealed.dynamicArrayAppenderPreservesRuntimeByte." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void write(ubyte value) {
                    bytes ~= value;
                }
            }

            unittest {
                Writer writer;
                ubyte value = cast(ubyte) 40;
                value += 2;

                writer.write(value);

                assert(writer.bytes.length == 1);
                assert(writer.bytes[0] == value);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("refCursorReadAdvancesPosition." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte readByte(ubyte[] bytes, ref size_t position) {
                const value = bytes[position];
                ++position;
                return value;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] input = [first, second];
                size_t position = input.length - 1;

                const value = readByte(input, position);

                assert(value == second);
                assert(position == input.length);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("postIncrementCursorReadAdvancesPosition." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte readByte(ubyte[] bytes, ref size_t position) {
                return bytes[position++];
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] input = [first, second];
                size_t position = input.length - 1;

                const value = readByte(input, position);

                assert(value == second);
                assert(position == input.length);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("templateLengthPrefixUsesRequestedWidth." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void writeLength(T)(ref ubyte[] bytes, size_t length) {
                const narrowed = cast(T) length;

                foreach (i; 0 .. T.sizeof)
                    bytes ~= cast(ubyte)(narrowed >> (i * 8));
            }

            unittest {
                ubyte[] bytes;
                size_t length = 250;
                length += 8;

                writeLength!ushort(bytes, length);

                assert(bytes.length == 2);
                assert(bytes[0] == 2);
                assert(bytes[1] == 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("decodeBoolReadsSequentialBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                ubyte[] bytes;
                size_t index;

                bool readBool() {
                    return bytes[index++] == 1;
                }
            }

            unittest {
                auto reader = Reader([1, 0, 1, 0, 0, 1]);

                assert(reader.readBool == true);
                assert(reader.readBool == false);
                assert(reader.readBool == true);
                assert(reader.readBool == false);
                assert(reader.readBool == false);
                assert(reader.readBool == true);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("encodeIntWritesBigEndianBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void writeInt(int value) {
                    foreach_reverse (i; 0 .. int.sizeof)
                        bytes ~= cast(ubyte)(value >> (i * 8));
                }
            }

            unittest {
                Writer writer;
                int first = 3;
                int second = -1_000_000;

                writer.writeInt(first);
                writer.writeInt(second);

                assert(
                    writer.bytes ==
                    [0x0, 0x0, 0x0, 0x3, 0xff, 0xf0, 0xbd, 0xc0]
                );
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("roundTripBoolBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void writeBool(bool value) {
                    bytes ~= value ? 1 : 0;
                }
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                bool readBool() {
                    return bytes[index++] == 1;
                }
            }

            unittest {
                Writer writer;
                bool[] values = [true, true, false, false, true];

                foreach (value; values)
                    writer.writeBool(value);

                auto reader = Reader(writer.bytes);

                foreach (value; values)
                    assert(reader.readBool == value);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("roundTripEnumBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            private enum MyEnum {
                foo,
                bar,
                baz,
            }

            struct Writer {
                ubyte[] bytes;

                void writeEnum(MyEnum value) {
                    const intValue = cast(int) value;

                    foreach_reverse (i; 0 .. int.sizeof)
                        bytes ~= cast(ubyte)(intValue >> (i * 8));
                }
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                MyEnum readEnum() {
                    int intValue;

                    foreach (_; 0 .. int.sizeof) {
                        intValue <<= 8;
                        intValue |= bytes[index++];
                    }

                    return cast(MyEnum) intValue;
                }
            }

            unittest {
                Writer writer;
                writer.writeEnum(MyEnum.bar);
                writer.writeEnum(MyEnum.baz);
                writer.writeEnum(MyEnum.foo);

                assert(
                    writer.bytes ==
                    [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0]
                );

                auto reader = Reader(writer.bytes);

                assert(reader.readEnum == MyEnum.bar);
                assert(reader.readEnum == MyEnum.baz);
                assert(reader.readEnum == MyEnum.foo);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("exampleFooRoundTripBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Foo {
                int i;
            }

            ubyte[] cerealize(Foo value) {
                ubyte[] bytes;

                foreach_reverse (i; 0 .. int.sizeof)
                    bytes ~= cast(ubyte)(value.i >> (i * 8));

                return bytes;
            }

            T decerealize(T)(const(ubyte)[] bytes) if (is(T == Foo)) {
                int value;

                foreach (byte_; bytes) {
                    value <<= 8;
                    value |= byte_;
                }

                return T(value);
            }

            unittest {
                auto foo = Foo(5);
                auto bytes = foo.cerealize;

                assert(bytes == [0, 0, 0, 5]);
                assert(bytes.decerealize!Foo == foo);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("multidimensionalArrayWritesNestedLengths." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void writeLength(ref ubyte[] bytes, size_t length) {
                const narrowed = cast(ushort) length;

                foreach_reverse (i; 0 .. ushort.sizeof)
                    bytes ~= cast(ubyte)(narrowed >> (i * 8));
            }

            void writeInt(ref ubyte[] bytes, int value) {
                foreach_reverse (i; 0 .. int.sizeof)
                    bytes ~= cast(ubyte)(value >> (i * 8));
            }

            ubyte[] encode(int[][] values) {
                ubyte[] bytes;

                writeLength(bytes, values.length);

                foreach (row; values) {
                    writeLength(bytes, row.length);

                    foreach (value; row)
                        writeInt(bytes, value);
                }

                return bytes;
            }

            unittest {
                int[][] values = [
                    [3, 5, 6],
                    [-3, 6, int.max, int.min],
                ];

                assert(values.encode == [
                    0, 2,
                        0, 3,
                            0, 0, 0, 3,
                            0, 0, 0, 5,
                            0, 0, 0, 6,
                        0, 4,
                            255, 255, 255, 253,
                              0,   0,   0,   6,
                            127, 255, 255, 255,
                            128,   0,   0,   0,
                ]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("nestedStructWritesAssociativeArrayChild." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Nested {
                Nested[int] aa;
            }

            void writeLength(ref ubyte[] bytes, size_t length) {
                const narrowed = cast(ushort) length;

                foreach_reverse (i; 0 .. ushort.sizeof)
                    bytes ~= cast(ubyte)(narrowed >> (i * 8));
            }

            void writeInt(ref ubyte[] bytes, int value) {
                foreach_reverse (i; 0 .. int.sizeof)
                    bytes ~= cast(ubyte)(value >> (i * 8));
            }

            void writeNested(ref ubyte[] bytes, Nested nested) {
                writeLength(bytes, nested.aa.length);

                foreach (key, value; nested.aa) {
                    writeInt(bytes, key);
                    writeNested(bytes, value);
                }
            }

            ubyte[] encode(Nested[] nesteds) {
                ubyte[] bytes;

                writeLength(bytes, nesteds.length);

                foreach (nested; nesteds)
                    writeNested(bytes, nested);

                return bytes;
            }

            unittest {
                auto nesteds = [Nested([7: Nested()])];

                assert(nesteds.encode == [
                    0, 1,
                        0, 1,
                            0, 0, 0, 7,
                            0, 0,
                ]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointerToIntWritesPointeeBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void writeInt(ref ubyte[] bytes, int value) {
                foreach_reverse (i; 0 .. int.sizeof)
                    bytes ~= cast(ubyte)(value >> (i * 8));
            }

            ubyte[] encode(int* value) {
                ubyte[] bytes;

                writeInt(bytes, *value);

                return bytes;
            }

            unittest {
                auto value = new int;
                *value = 4;

                assert(value.encode == [0, 0, 0, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("ubyteArrayRoundTripUsesUbyteLength." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void writeArray(ref ubyte[] bytes, ubyte[] values) {
                bytes ~= cast(ubyte) values.length;

                foreach (value; values)
                    bytes ~= value;
            }

            ubyte[] readArray(ubyte[] bytes, ref size_t index) {
                const length = bytes[index++];
                ubyte[] values;

                foreach (_; 0 .. length)
                    values ~= bytes[index++];

                return values;
            }

            unittest {
                ubyte[] values = [3, 1, 4, 1, 5, 9];
                ubyte[] bytes;

                writeArray(bytes, values);

                assert(bytes.length == values.length + ubyte.sizeof);
                assert(bytes[0] == values.length);

                size_t index;

                assert(readArray(bytes, index) == values);
                assert(index == bytes.length);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("protocolUnitLengthFieldRoundTrip." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Unit {
                ushort us;
                ubyte ub1;
                ubyte ub2;
            }

            struct Packet {
                ubyte ub1;
                ushort length;
                ubyte ub2;
                Unit[] units;
            }

            void writeUshort(ref ubyte[] bytes, ushort value) {
                foreach_reverse (i; 0 .. ushort.sizeof)
                    bytes ~= cast(ubyte)(value >> (i * 8));
            }

            ushort readUshort(ubyte[] bytes, ref size_t index) {
                ushort value;

                foreach (_; 0 .. ushort.sizeof) {
                    value <<= 8;
                    value |= bytes[index++];
                }

                return value;
            }

            ubyte[] encode(Packet packet) {
                ubyte[] bytes;

                bytes ~= packet.ub1;
                writeUshort(bytes, packet.length);
                bytes ~= packet.ub2;

                foreach (unit; packet.units) {
                    writeUshort(bytes, unit.us);
                    bytes ~= unit.ub1;
                    bytes ~= unit.ub2;
                }

                return bytes;
            }

            Packet decode(ubyte[] bytes) {
                size_t index;
                Packet packet;

                packet.ub1 = bytes[index++];
                packet.length = readUshort(bytes, index);
                packet.ub2 = bytes[index++];

                foreach (_; 0 .. packet.length)
                    packet.units ~= Unit(
                        readUshort(bytes, index),
                        bytes[index++],
                        bytes[index++],
                    );

                return packet;
            }

            unittest {
                auto packet = Packet(
                    3,
                    4,
                    9,
                    [
                        Unit(7, 1, 2),
                        Unit(6, 2, 3),
                        Unit(5, 4, 5),
                        Unit(4, 9, 8),
                    ],
                );
                ubyte[] bytes = [
                    3, 0, 4, 9,
                    0, 7, 1, 2,
                    0, 6, 2, 3,
                    0, 5, 4, 5,
                    0, 4, 9, 8,
                ];

                assert(packet.encode == bytes);
                assert(bytes.decode == packet);
                assert(bytes.decode.units.length == bytes.decode.length);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("bitPackedStructHeaderRoundTrip." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct ProtoHeader {
                ubyte bits3;
                ubyte bits1;
                uint bits4;
                ubyte bits8;
            }

            ubyte[] encode(ProtoHeader header) {
                return [
                    cast(ubyte)(
                        ((header.bits3 & 0x7) << 5) |
                        ((header.bits1 & 0x1) << 4) |
                        (header.bits4 & 0xf)
                    ),
                    header.bits8,
                ];
            }

            ProtoHeader decode(const(ubyte)[] bytes) {
                return ProtoHeader(
                    cast(ubyte)((bytes[0] >> 5) & 0x7),
                    cast(ubyte)((bytes[0] >> 4) & 0x1),
                    cast(uint)(bytes[0] & 0xf),
                    bytes[1],
                );
            }

            unittest {
                ubyte base = 5;
                ++base;
                const header = ProtoHeader(
                    base,
                    cast(ubyte)(base - 5),
                    cast(uint)(base - 3),
                    cast(ubyte)(base + 248),
                );

                const encoded = header.encode;

                assert(encoded == [0xd3, 254]);
                assert(encoded.decode == header);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inputRangeWritesLengthAndValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct CounterRange {
                ubyte current;
                ubyte stop;

                @property bool empty() {
                    return current == stop;
                }

                @property ubyte front() {
                    return current;
                }

                void popFront() {
                    ++current;
                }

                @property ulong length() {
                    return stop - current;
                }
            }

            void writeLength(ref ubyte[] bytes, ulong length) {
                const narrowed = cast(ushort) length;

                foreach_reverse (i; 0 .. ushort.sizeof)
                    bytes ~= cast(ubyte)(narrowed >> (i * 8));
            }

            ubyte[] encode(CounterRange range) {
                ubyte[] bytes;

                writeLength(bytes, range.length);

                while (!range.empty) {
                    bytes ~= range.front;
                    range.popFront;
                }

                return bytes;
            }

            unittest {
                auto range = CounterRange(cast(ubyte) 0, cast(ubyte) 5);

                assert(range.encode == [0, 5, 0, 1, 2, 3, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("resetReaderRestoresOriginalOrNewBytes." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                ubyte[] originalBytes;
                ubyte[] bytes;

                int readInt() {
                    int value;

                    foreach (_; 0 .. int.sizeof) {
                        value <<= 8;
                        value |= bytes[0];
                        bytes = bytes[1 .. $];
                    }

                    return value;
                }

                short readShort() {
                    short value;

                    foreach (_; 0 .. short.sizeof) {
                        value <<= 8;
                        value |= bytes[0];
                        bytes = bytes[1 .. $];
                    }

                    return value;
                }

                void reset() {
                    bytes = originalBytes;
                }

                void reset(ubyte[] newBytes) {
                    originalBytes = newBytes;
                    bytes = newBytes;
                }
            }

            unittest {
                ubyte[] bytes1 = [1, 2, 3, 5, 8, 13];
                auto reader = Reader(bytes1, bytes1);

                assert(reader.readInt == 0x01020305);
                assert(reader.bytes == [8, 13]);

                assert(reader.readShort == 0x080d);
                assert(reader.bytes.length == 0);

                reader.reset;

                assert(reader.bytes == bytes1);

                ubyte[] bytes2 = [3, 6, 9, 12];
                reader.reset(bytes2);

                assert(reader.bytes == bytes2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArrayRoundTripOmitsLengthPrefix." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void writeInt(ref ubyte[] bytes, int value) {
                foreach_reverse (i; 0 .. int.sizeof)
                    bytes ~= cast(ubyte)(value >> (i * 8));
            }

            int readInt(ubyte[] bytes, ref size_t index) {
                int value;

                foreach (_; 0 .. int.sizeof) {
                    value <<= 8;
                    value |= bytes[index++];
                }

                return value;
            }

            ubyte[] encode(int[2] values) {
                ubyte[] bytes;

                foreach (value; values)
                    writeInt(bytes, value);

                return bytes;
            }

            int[2] decode(ubyte[] bytes) {
                int[2] values;
                size_t index;

                foreach (ref value; values)
                    value = readInt(bytes, index);

                return values;
            }

            unittest {
                int[2] original;
                original[0] = 34;
                original[1] = 45;

                ubyte[] bytes = original.encode;

                assert(bytes == [
                    0, 0, 0, 34,
                    0, 0, 0, 45,
                ]);
                assert(bytes.length == original.length * int.sizeof);
                assert(bytes.decode == original);
            }
        });
    }
}


/++
    Project-shaped diagnostics.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("roundTripEnumExhaustionReportsBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            private enum MyEnum {
                foo,
                bar,
                baz,
            }

            struct Writer {
                ubyte[] bytes;

                void writeEnum(MyEnum value) {
                    const intValue = cast(int) value;

                    foreach_reverse (i; 0 .. int.sizeof)
                        bytes ~= cast(ubyte)(intValue >> (i * 8));
                }
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                MyEnum readEnum() {
                    int intValue;

                    foreach (_; 0 .. int.sizeof) {
                        intValue <<= 8;
                        intValue |= bytes[index++];
                    }

                    return cast(MyEnum) intValue;
                }
            }

            unittest {
                Writer writer;
                writer.writeEnum(MyEnum.bar);
                writer.writeEnum(MyEnum.baz);
                writer.writeEnum(MyEnum.foo);

                auto reader = Reader(writer.bytes);
                reader.readEnum;
                reader.readEnum;
                reader.readEnum;

                reader.readEnum;
            }
        }).shouldThrowWithMessage("array index 12 is out of bounds `[0..12]`");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text; the
// backtick-range wording in the Ctfe block above is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "CTFE emits backtick-range wording, see sibling pin above"),
)) {
    @("roundTripEnumExhaustionReportsBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            private enum MyEnum {
                foo,
                bar,
                baz,
            }

            struct Writer {
                ubyte[] bytes;

                void writeEnum(MyEnum value) {
                    const intValue = cast(int) value;

                    foreach_reverse (i; 0 .. int.sizeof)
                        bytes ~= cast(ubyte)(intValue >> (i * 8));
                }
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                MyEnum readEnum() {
                    int intValue;

                    foreach (_; 0 .. int.sizeof) {
                        intValue <<= 8;
                        intValue |= bytes[index++];
                    }

                    return cast(MyEnum) intValue;
                }
            }

            unittest {
                Writer writer;
                writer.writeEnum(MyEnum.bar);
                writer.writeEnum(MyEnum.baz);
                writer.writeEnum(MyEnum.foo);

                auto reader = Reader(writer.bytes);
                reader.readEnum;
                reader.readEnum;
                reader.readEnum;

                reader.readEnum;
            }
        }).shouldThrowWithMessage(
            "index [12] is out of bounds for array of length 12",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("roundTripBoolExhaustionReportsBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void writeBool(bool value) {
                    bytes ~= value ? 1 : 0;
                }
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                bool readBool() {
                    return bytes[index++] == 1;
                }
            }

            unittest {
                Writer writer;
                bool[] values = [true, true, false, false, true];

                foreach (value; values)
                    writer.writeBool(value);

                auto reader = Reader(writer.bytes);

                foreach (value; values)
                    reader.readBool;

                reader.readBool;
            }
        }).shouldThrowWithMessage("array index 5 is out of bounds `[0..5]`");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text (see above).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "CTFE emits backtick-range wording, see sibling pin above"),
)) {
    @("roundTripBoolExhaustionReportsBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void writeBool(bool value) {
                    bytes ~= value ? 1 : 0;
                }
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                bool readBool() {
                    return bytes[index++] == 1;
                }
            }

            unittest {
                Writer writer;
                bool[] values = [true, true, false, false, true];

                foreach (value; values)
                    writer.writeBool(value);

                auto reader = Reader(writer.bytes);

                foreach (value; values)
                    reader.readBool;

                reader.readBool;
            }
        }).shouldThrowWithMessage(
            "index [5] is out of bounds for array of length 5",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("decodeBoolExhaustionReportsBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                ubyte[] bytes;
                size_t index;

                bool readBool() {
                    return bytes[index++] == 1;
                }
            }

            unittest {
                auto reader = Reader([1, 0, 1, 0, 0, 1]);

                foreach (_; 0 .. 6)
                    reader.readBool;

                reader.readBool;
            }
        }).shouldThrowWithMessage("array index 6 is out of bounds `[0..6]`");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text (see above).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "CTFE emits backtick-range wording, see sibling pin above"),
)) {
    @("decodeBoolExhaustionReportsBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                ubyte[] bytes;
                size_t index;

                bool readBool() {
                    return bytes[index++] == 1;
                }
            }

            unittest {
                auto reader = Reader([1, 0, 1, 0, 0, 1]);

                foreach (_; 0 .. 6)
                    reader.readBool;

                reader.readBool;
            }
        }).shouldThrowWithMessage(
            "index [6] is out of bounds for array of length 6",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("arrayTooShortExceptionMessageIncludesBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.conv: text;

            void failIfTooShort(ubyte[] bytes, ulong length) {
                const needed = length;
                if (needed > bytes.length)
                    throw new Exception(text(
                        "Not enough bytes left to decerealise ubyte[] of ",
                        length,
                        " elements\n",
                        "Bytes left: ",
                        bytes.length,
                        ", Needed: ",
                        needed,
                        ", bytes: ",
                        bytes,
                    ));
            }

            unittest {
                try {
                    failIfTooShort([1, 2], 8);
                    assert(false);
                } catch (Exception exception) {
                    assert(
                        exception.msg ==
                        "Not enough bytes left to decerealise ubyte[] of 8 elements\n" ~
                        "Bytes left: 2, Needed: 8, bytes: [1, 2]",
                        exception.msg,
                    );
                }
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Bytecode, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("stdConvTextRendersCharArrayExpressionRaw." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.array: array;
            import std.conv: text;

            unittest {
                try {
                    throw new Exception("cerealed bytes".idup);
                } catch (Exception exception) {
                    const rendered = exception.msg.array.dup.text;

                    assert(rendered == "cerealed bytes", rendered);
                }
            }
        });
    }
}



/++
    Known project-shaped gaps.
+/
static foreach (backend; Matrix!()) {
    @("encodeFloatReinterpretsBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;

                void writeFloat(float value) {
                    const intValue = *cast(uint*) &value;

                    foreach_reverse (i; 0 .. intValue.sizeof)
                        bytes ~= cast(ubyte)(intValue >> (i * 8));
                }
            }

            unittest {
                Writer writer;
                float value = 1.0f;

                writer.writeFloat(value);

                assert(writer.bytes.length == 4);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @ShouldFail(
        "DMD CTFE cannot read a static child-class registry at compile time",
    )
    @("classSerialisationReadsStaticChildRegistry." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Message {
                ubyte value;

                this(ubyte value) {
                    this.value = value;
                }
            }

            struct Writer {
                static void delegate(ref Writer, Object)[string] childWriters;
                ubyte[] bytes;

                void writeObject(Object object) {
                    const key = object.classinfo.name;
                    childWriters[key](this, object);
                }
            }

            unittest {
                Writer.childWriters[Message.classinfo.name] =
                    (ref Writer writer, Object object) {
                        auto message = cast(Message) object;
                        writer.bytes ~= message.value;
                    };

                Writer writer;
                auto message = new Message(cast(ubyte) 42);

                writer.writeObject(message);

                assert(writer.bytes.length == 1);
                assert(writer.bytes[0] == 42);
            }
        });
    }
}

// Compiled code reads the static child-class registry fine; the Ctfe
// @ShouldFail limitation above is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "DMD CTFE cannot read a static child-class registry at compile time, see @ShouldFail pin above"),
)) {
    @("classSerialisationReadsStaticChildRegistry." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Message {
                ubyte value;

                this(ubyte value) {
                    this.value = value;
                }
            }

            struct Writer {
                static void delegate(ref Writer, Object)[string] childWriters;
                ubyte[] bytes;

                void writeObject(Object object) {
                    const key = object.classinfo.name;
                    childWriters[key](this, object);
                }
            }

            unittest {
                Writer.childWriters[Message.classinfo.name] =
                    (ref Writer writer, Object object) {
                        auto message = cast(Message) object;
                        writer.bytes ~= message.value;
                    };

                Writer writer;
                auto message = new Message(cast(ubyte) 42);

                writer.writeObject(message);

                assert(writer.bytes.length == 1);
                assert(writer.bytes[0] == 42);
            }
        });
    }
}

static foreach (backend; Matrix!(
)) {
    @("lazyForwardedAssertionThunkRunsExpression." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool threw(lazy int expression) {
                try {
                    expression;
                    return false;
                } catch (Exception) {
                    return true;
                }
            }

            void shouldThrow(lazy int expression) {
                assert(threw(expression));
            }

            int fail() {
                throw new Exception("expected");
            }

            unittest {
                shouldThrow(fail);
            }
        });
    }
}

// A `lazy` parameter is a delegate over the caller's live frame: reading a
// dynamic-array local from inside the thunk must see the caller's actual
// backing storage, not an empty default (ai/plans/interpreter.md §9.10).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("lazyArgumentReadsCallerDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte runIt(lazy ubyte expression) { return expression; }

            unittest {
                ubyte[] bytes = [1, 2, 3];
                assert(runIt(bytes[1]) == 2);
            }
        });
    }
}

// The owed §9.10 fixture: a `lazy` argument forwarded through two more
// layers, evaluated multiple times, over a struct-typed caller local whose
// scalar field (`index`) mutates between evaluations. Each mutation must be
// visible to the *next* evaluation, matching a `lazy` parameter's real
// closure-over-the-caller-frame semantics.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Bytecode, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("decodeLazyForwardedRangeErrorSeesReaderState." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.exception : RangeError;

            void shouldNotThrow(lazy ulong expression) {
                try {
                    expression;
                } catch (Throwable throwable) {
                    assert(false, throwable.msg);
                }
            }

            void shouldThrowRangeError(lazy ubyte expression) {
                assert(forwardedShouldThrowRangeError(expression));
            }

            bool forwardedShouldThrowRangeError(lazy ubyte expression) {
                try {
                    expression;
                } catch (RangeError) {
                    return true;
                }

                return false;
            }

            struct Reader {
                ubyte[] bytes;
                size_t index;

                ulong read64() {
                    ulong encoded;

                    foreach (_; 0 .. ulong.sizeof) {
                        encoded <<= 8;
                        encoded |= bytes[index++];
                    }

                    return encoded;
                }

                ubyte readByte() {
                    return bytes[index++];
                }
            }

            unittest {
                auto reader = Reader([
                    0x3f, 0xf0, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                    0x40, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                ]);

                shouldNotThrow(reader.read64);
                shouldNotThrow(reader.read64);
                shouldThrowRangeError(reader.readByte);
            }
        });
    }
}

// A `lazy` argument's thunk runs on the callee's own interpreter frame, but
// it is a delegate over the *caller's* live frame: `x++` inside `lazy e`
// must mutate the caller's `x`, and the caller's next read of `x` must see
// the mutation without the interpreter's own frame/boxed-local mirror
// diverging (ai/plans/interpreter.md).
static foreach (backend; Matrix!(
    // The bytecode core compiles a `lazy` argument's thunk without the
    // outer local's own slot in scope, so `x++` there falls outside the
    // `_locals` lookup its post-increment compilation depends on.
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("lazyArgumentMutatesCallerLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int forceLazy(lazy int e) { return e; }

            unittest {
                int x = 1;
                const r = forceLazy(x++);
                assert(r == 1);
                assert(x == 2);
            }
        });
    }
}

// The struct-field sibling of the fixture above: the mutated caller local is
// a struct (frame-covered as a whole composed value, not a bare scalar), so
// the frame mirror this exercises is the aggregate write path rather than
// the scalar one.
static foreach (backend; Matrix!(
    // Same bytecode-core gap as the fixture above, over a struct field
    // instead of a bare scalar.
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("lazyArgumentMutatesCallerStructField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int value;
            }

            int forceLazy(lazy int e) { return e; }

            unittest {
                Counter counter = Counter(1);
                const r = forceLazy(counter.value++);
                assert(r == 1);
                assert(counter.value == 2);
            }
        });
    }
}

// The owed §9.10 fixture, distilled to a raw pointer-slice reproduction: a
// pointer slice shrunk to `[0 .. 0]` must retain its backing allocation, so
// a regrow through `.ptr` still sees the original storage rather than a
// stale empty block. This is exactly what `std.array.Appender.clear`
// (`_data.arr = _data.arr.ptr[0 .. 0]`) followed by `put`'s regrowth
// (`arr.ptr[0 .. len + 1]`) does, but the fixture deliberately avoids
// instantiating Phobos' `Appender`: that instantiation was the suite's
// only `Appender!(ubyte[])` use and the sole source of the
// `emplaceInitializer!(Appender!(ubyte[]).Data)` template instances that fed
// the `link-set-pollution.md` flake (see the cross-track observation in
// §9.10 below).  The raw construct also runs on `Bytecode`, which the
// Phobos-based body could not express, so the matrix widens by one backend.
static foreach (backend; Matrix!()) {
    @("appenderClearKeepsPointerSliceBackingAllocation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2, 3, 4];
                auto shrunk = arr.ptr[0 .. 0];
                auto regrown = shrunk.ptr[0 .. 1];
                assert(regrown[0] == 1);
            }
        });
    }
}

// The owed §9.10 fixture: a class reference passed by value to a function
// that mutates a field must leave the mutation visible to the caller, since
// a class is a reference type. The callee and caller reach the same
// authoritative object cell; no by-value parameter writeback is involved.
static foreach (backend; Matrix!()) {
    @("classReferencePassedByValueMutatesObject." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Box {
                int value;
            }

            void fill(Box box) {
                box.value = 42;
            }

            unittest {
                auto box = new Box;

                fill(box);

                assert(box.value == 42);
            }
        });
    }
}

// The §9.10 shim-deletion ratchet: a class parameter shares the referenced
// object's identity with its argument, but the parameter variable itself is
// passed by value. Rebinding that variable must therefore leave the caller's
// variable pointing at the original object. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("classReferencePassedByValueDoesNotRebindCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Box {
                int value;
            }

            void replace(Box box) {
                box = new Box;
                box.value = 99;
            }

            unittest {
                auto box = new Box;
                box.value = 42;

                replace(box);

                assert(box.value == 42);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("grainBitsBoolWritesScalar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Reader {
                uint next;

                void grainBits(ref uint value, int bits) {
                    value = next;
                }
            }

            void grainBitsT(C, T)(ref C cereal, ref T value, int bits) {
                uint realValue = value;
                cereal.grainBits(realValue, bits);
                value = cast(T) realValue;
            }

            unittest {
                auto reader = Reader(1);
                bool value;

                grainBitsT(reader, value, 1);

                assert(value == true);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArrayTruthinessControlsEnforceFallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int classify(ubyte[] bytes) {
                int result;

                if (bytes)
                    result += 1;
                else
                    result += 10;

                result += bytes ? 2 : 20;

                if (!bytes)
                    result += 100;

                return result;
            }

            unittest {
                ubyte[] nullBytes;
                ubyte[] emptyBytes = [];
                ubyte[] fullBytes = [cast(ubyte) 42];

                assert(classify(nullBytes) == 130);
                assert(classify(emptyBytes) == 130);
                assert(classify(fullBytes) == 3);
            }
        });
    }
}

// `emplaceRef` must write through a scalar array-element reference. This also
// ratchets the interpreter's real `core.internal.lifetime.emplaceRef` body;
// no name-based interception is permitted.
static foreach (backend; Matrix!()) {
    @("emplaceRefWritesArrayElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.internal.lifetime : emplaceRef;

            unittest {
                char[] message;
                message.length = 2;

                emplaceRef(message[0], 'o');
                emplaceRef(message[1], 'k');

                assert(message == "ok");
            }
        });
    }
}

// `emplaceRef` on a struct element with a postblit must run it exactly once,
// matching compiled construction semantics. Interpreter reaches the real
// body and writes the value, but still skips the postblit (`0 != 1`).
// Bytecode must preserve this one postblit while its `emplaceRef` wrapper
// writes the indexed destination.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed, "diverges pending value.md native-layout track; no characterization pin yet"),
)) {
    @("emplaceRefSkipsPostblitForStructElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.internal.lifetime : emplaceRef;

            struct Counter {
                int value;
                int postblitCount;

                this(this) {
                    postblitCount++;
                }
            }

            unittest {
                Counter[] counters;
                counters.length = 1;

                Counter source;
                source.value = 42;

                emplaceRef(counters[0], source);

                assert(counters[0].value == 42);
                assert(counters[0].postblitCount == 1);
            }
        });
    }
}

// `emplaceRef`'s 0-arg form overwrites the destination with `T.init` through
// the real druntime body.
static foreach (backend; Matrix!()) {
    @("emplaceRefDefaultInitializesArrayElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.internal.lifetime : emplaceRef;

            unittest {
                char[] message;
                message.length = 1;
                message[0] = 'x';

                emplaceRef(message[0]);

                assert(message[0] == char.init);
            }
        });
    }
}

// `wchar.init` is `0xFFFF`, unlike the all-zero default initialization of
// most scalar elements. This keeps the zero-argument `emplaceRef` path honest
// about materialising the element type's real `.init` value.
static foreach (backend; Matrix!()) {
    @("emplaceRefDefaultInitializesWcharArrayElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.internal.lifetime : emplaceRef;

            unittest {
                wchar[] values;
                values.length = 1;
                values[0] = 'x';

                emplaceRef(values[0]);

                assert(values[0] == wchar.init);
            }
        });
    }
}

// `emplaceRef`'s multi-arg form forwards its arguments to the destination's
// constructor through the real druntime body.
// Bytecode covers its narrow indexed-array struct-constructor path here.
static foreach (backend; Matrix!()) {
    @("emplaceRefForwardsConstructorArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.internal.lifetime : emplaceRef;

            struct Point {
                int x;
                int y;

                this(int x_, int y_) {
                    x = x_;
                    y = y_;
                }
            }

            unittest {
                Point[] points;
                points.length = 1;

                emplaceRef(points[0], 1, 2);

                assert(points[0].x == 1);
                assert(points[0].y == 2);
            }
        });
    }
}

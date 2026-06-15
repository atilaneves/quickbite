module ut.backends.runner.ct.cerealed;


import ut.backends;


static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.refCursorReadAdvancesPosition." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.postIncrementCursorReadAdvancesPosition." ~
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.templateLengthPrefixUsesRequestedWidth." ~
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.decodeBoolReadsSequentialBytes." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.encodeIntWritesBigEndianBytes." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.roundTripBoolBytes." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.roundTripEnumBytes." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.exampleFooRoundTripBytes." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.multidimensionalArrayWritesNestedLengths." ~
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.nestedStructWritesAssociativeArrayChild." ~
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.pointerToIntWritesPointeeBytes." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.ubyteArrayRoundTripUsesUbyteLength." ~
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.protocolUnitLengthFieldRoundTrip." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.bitPackedStructHeaderRoundTrip." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.inputRangeWritesLengthAndValues." ~ backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.resetReaderRestoresOriginalOrNewBytes." ~
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

static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.staticArrayRoundTripOmitsLengthPrefix." ~
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
    @("projects.cerealed.roundTripEnumExhaustionReportsBoundsDiagnostic." ~
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
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("projects.cerealed.roundTripEnumExhaustionReportsBoundsDiagnostic." ~
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
    @("projects.cerealed.roundTripBoolExhaustionReportsBoundsDiagnostic." ~
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
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("projects.cerealed.roundTripBoolExhaustionReportsBoundsDiagnostic." ~
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
    @("projects.cerealed.decodeBoolExhaustionReportsBoundsDiagnostic." ~
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
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("projects.cerealed.decodeBoolExhaustionReportsBoundsDiagnostic." ~
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



/++
    Known project-shaped gaps.
+/
static foreach (backend; AliasSeq!(Ctfe, SystemLinker)) {
    @("projects.cerealed.encodeFloatReinterpretsBytes." ~ backend.stringof)
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
    @("projects.cerealed.classSerialisationReadsStaticChildRegistry." ~
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
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("projects.cerealed.classSerialisationReadsStaticChildRegistry." ~
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


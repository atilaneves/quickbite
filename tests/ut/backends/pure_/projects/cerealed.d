module ut.backends.pure_.projects.cerealed;


import ut.backends;


private:

static foreach (backend; backends) {
    @("projects.cerealed.dynamicArrayAppenderPreservesRuntimeByte." ~ backend.stringof)
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

    @("projects.cerealed.dynamicArrayAppenderPreservesRuntimeByteFailureMessage.0." ~ backend.stringof)
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

                assert(writer.bytes.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("projects.cerealed.dynamicArrayAppenderPreservesRuntimeByteFailureMessage.1." ~ backend.stringof)
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

                assert(writer.bytes[0] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("projects.cerealed.refCursorReadAdvancesPosition." ~ backend.stringof)
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

    @("projects.cerealed.refCursorReadAdvancesPositionFailureMessage.0." ~ backend.stringof)
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

                assert(value == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }

    @("projects.cerealed.refCursorReadAdvancesPositionFailureMessage.1." ~ backend.stringof)
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

                readByte(input, position);

                assert(position == input.length - 1);
            }
        }).shouldThrowWithMessage("2 != 1");
    }

    @("projects.cerealed.postIncrementCursorReadAdvancesPosition." ~ backend.stringof)
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

    @("projects.cerealed.postIncrementCursorReadAdvancesPositionFailureMessage.0." ~ backend.stringof)
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

                assert(value == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }

    @("projects.cerealed.postIncrementCursorReadAdvancesPositionFailureMessage.1." ~ backend.stringof)
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

                readByte(input, position);

                assert(position == input.length - 1);
            }
        }).shouldThrowWithMessage("2 != 1");
    }

    @("projects.cerealed.templateLengthPrefixUsesRequestedWidth." ~ backend.stringof)
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

    @("projects.cerealed.templateLengthPrefixUsesRequestedWidthFailureMessage.0." ~ backend.stringof)
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

                assert(bytes.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("projects.cerealed.templateLengthPrefixUsesRequestedWidthFailureMessage.1." ~ backend.stringof)
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

                assert(bytes[1] == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("projects.cerealed.decodeBoolReadsSequentialBytes." ~ backend.stringof)
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

    @("projects.cerealed.encodeIntWritesBigEndianBytes." ~ backend.stringof)
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

    @("projects.cerealed.roundTripBoolBytes." ~ backend.stringof)
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

    @("projects.cerealed.roundTripEnumBytes." ~ backend.stringof)
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

    @ShouldFail(
        "DMD CTFE reports enum byte exhaustion as an uncaught bounds " ~
        "error instead of catchable RangeError",
    )
    @("projects.cerealed.roundTripEnumExhaustionThrowsRangeError." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.exception: RangeError;

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

                try {
                    reader.readEnum;
                    assert(false);
                } catch (RangeError) {
                }
            }
        });
    }

    @ShouldFail(
        "DMD CTFE reports byte round-trip exhaustion as an uncaught " ~
        "bounds error instead of catchable RangeError",
    )
    @("projects.cerealed.roundTripBoolExhaustionThrowsRangeError." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.exception: RangeError;

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

                try {
                    reader.readBool;
                    assert(false);
                } catch (RangeError) {
                }
            }
        });
    }

    @("projects.cerealed.encodeFloatReinterpretsBytes." ~ backend.stringof)
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

    @ShouldFail(
        "DMD CTFE reports bool byte exhaustion as an uncaught bounds " ~
        "error instead of catchable RangeError",
    )
    @("projects.cerealed.decodeBoolExhaustionThrowsRangeError." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.exception: RangeError;

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

                try {
                    reader.readBool;
                    assert(false);
                } catch (RangeError) {
                }
            }
        });
    }

    @ShouldFail(
        "DMD CTFE cannot read a static child-class registry at compile time",
    )
    @("projects.cerealed.classSerialisationReadsStaticChildRegistry." ~ backend.stringof)
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

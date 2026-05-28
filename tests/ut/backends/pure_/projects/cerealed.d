module ut.backends.pure_.projects.cerealed;


import ut.backends;
import ut.dub_paths: dubImportPaths;


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
            import cerealed.decerealiser;

            unittest {
                auto cereal = Decerealiser([1, 0, 1, 0, 0, 1]);

                assert(cereal.value!bool == true);
                assert(cereal.value!bool == false);
                assert(cereal.value!bool == true);
                assert(cereal.value!bool == false);
                assert(cereal.value!bool == false);
                assert(cereal.value!bool == true);
            }
        }, dubImportPaths);
    }

    @("projects.cerealed.encodeIntWritesBigEndianBytes." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import cerealed.cerealiser;

            unittest {
                auto cereal = Cerealiser();
                int first = 3;
                int second = -1_000_000;

                cereal ~= first;
                cereal ~= second;

                assert(
                    cereal.bytes ==
                    [0x0, 0x0, 0x0, 0x3, 0xff, 0xf0, 0xbd, 0xc0]
                );
            }
        }, dubImportPaths);
    }

    @("projects.cerealed.roundTripBoolBytes." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import cerealed.cerealiser;
            import cerealed.decerealiser;

            unittest {
                auto enc = Cerealiser();
                bool[] values = [true, true, false, false, true];
                foreach (value; values)
                    enc ~= value;

                auto dec = Decerealiser(enc.bytes);
                foreach (value; values)
                    assert(dec.value!bool == value);
            }
        }, dubImportPaths);
    }

    @ShouldFail(
        "DMD CTFE reports cerealed round-trip exhaustion as an uncaught " ~
        "bounds error instead of catchable RangeError",
    )
    @("projects.cerealed.roundTripBoolExhaustionThrowsRangeError." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import cerealed.cerealiser;
            import cerealed.decerealiser;
            import core.exception: RangeError;

            unittest {
                auto enc = Cerealiser();
                bool[] values = [true, true, false, false, true];
                foreach (value; values)
                    enc ~= value;

                auto dec = Decerealiser(enc.bytes);
                foreach (value; values)
                    dec.value!bool;

                try {
                    dec.value!ubyte;
                    assert(false);
                } catch (RangeError) {
                }
            }
        }, dubImportPaths);
    }

    @ShouldFail(
        "DMD CTFE does not support cerealed's float pointer " ~
        "reinterpretation cast",
    )
    @("projects.cerealed.encodeFloatReinterpretsBytes." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import cerealed.cerealiser;

            unittest {
                auto cereal = Cerealiser();
                float value = 1.0f;

                cereal ~= value;

                assert(cereal.bytes.length == 4);
            }
        }, dubImportPaths);
    }

    @ShouldFail(
        "DMD CTFE reports cerealed bool exhaustion as an uncaught bounds " ~
        "error instead of catchable RangeError",
    )
    @("projects.cerealed.decodeBoolExhaustionThrowsRangeError." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import cerealed.decerealiser;
            import core.exception: RangeError;

            unittest {
                auto cereal = Decerealiser([1, 0, 1, 0, 0, 1]);
                foreach (_; 0 .. 6)
                    cereal.value!bool;

                try {
                    cereal.value!bool;
                    assert(false);
                } catch (RangeError) {
                }
            }
        }, dubImportPaths);
    }

    @ShouldFail(
        "DMD CTFE cannot read cerealed's static child-class registry " ~
        "`_childCerealisers` at compile time",
    )
    @("projects.cerealed.classSerialisationReadsStaticChildRegistry." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import cerealed.cerealiser;

            class Message {
                ubyte value;

                this(ubyte value) {
                    this.value = value;
                }
            }

            unittest {
                auto enc = Cerealiser();
                auto message = new Message(cast(ubyte) 42);

                enc ~= message;

                assert(enc.bytes.length == 1);
                assert(enc.bytes[0] == 42);
            }
        }, dubImportPaths);
    }
}

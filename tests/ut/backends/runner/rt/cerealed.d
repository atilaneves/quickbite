module ut.backends.runner.rt.cerealed;


import ut.backends;


// Compiled bounds checks raise druntime's ArrayIndexError text; the
// backtick-range wording is CTFE-only.
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

// Compiled code reads the static child-class registry fine; the limitation
// above is CTFE-only.
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

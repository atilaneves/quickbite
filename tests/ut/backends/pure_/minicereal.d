module ut.backends.pure_.minicereal;


import ut.backends;
import std.conv: text;


static foreach (backend; matureExecutorBackends) {
    @("minicerealFile." ~ backend.text)
    unittest {
        import std.file: readText;

        readText("tests/minicereal.d").runTests(backend);
    }

    @("minicerealEncodeUbyte." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    ubyte[] output;
                    encode!ubyte(0x2au, output);
                    assert(output.length == 1);
                    assert(output[0] == 0x2au);
                }
            }
        ).runTests(backend);
    }

    @("minicerealDecodeUbyte." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    ubyte[] buf = [0x2au];
                    size_t pos = 0;
                    assert(decode!ubyte(buf, pos) == 0x2au);
                    assert(pos == 1);
                }
            }
        ).runTests(backend);
    }

    @("minicerealDecodeUbyteAtOffset." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    ubyte[] input = [0x99u, 0x2au];
                    size_t pos = 1;
                    assert(decode!ubyte(input, pos) == 0x2au);
                    assert(pos == 2);
                }
            }
        ).runTests(backend);
    }

    @("minicerealDecodeNegativeInt." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    ubyte[] input = [0xffu, 0xffu, 0xffu, 0xffu];
                    size_t pos = 0;
                    assert(decode!int(input, pos) == -1);
                    assert(pos == 4);
                }
            }
        ).runTests(backend);
    }

    @("minicerealRoundTripNegativeInt." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    const value = -42;
                    ubyte[] buf;
                    encode(value, buf);
                    size_t pos = 0;
                    assert(decode!int(buf, pos) == value);
                }
            }
        ).runTests(backend);
    }

    @("minicerealEncodeHighBitUlongBytes." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    ubyte[] buf;
                    encode(0x8070605040302010UL, buf);
                    ubyte[] expected = [
                        0x10u,
                        0x20u,
                        0x30u,
                        0x40u,
                        0x50u,
                        0x60u,
                        0x70u,
                        0x80u,
                    ];
                    assert(buf == expected);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructDefaultBytes." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    assert(cereal.bytes.length == 0);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructBytesAppend." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.bytes ~= 0x2au;
                    assert(cereal.bytes.length == 1);
                    assert(cereal.bytes[0] == 0x2au);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructAppendByte." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.bytes ~= cast(ubyte) 42;
                    size_t pos = 0;
                    assert(cereal.get!ubyte(pos) == 42);
                    assert(pos == 1);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructIndexWriteByte." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.bytes = [0];
                    cereal.bytes[0] = cast(ubyte) 42;
                    size_t pos = 0;
                    assert(cereal.get!ubyte(pos) == 42);
                }
            }
        ).runTests(backend);
    }

    @("minicerealPutUbyte." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put!ubyte(0x2au);
                    assert(cereal.bytes.length == 1);
                    assert(cereal.bytes[0] == 0x2au);
                }
            }
        ).runTests(backend);
    }

    @("minicerealPutUbyteBytesEqual." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put!ubyte(0x2au);
                    ubyte[] expected = [0x2au];
                    assert(cereal.bytes == expected);
                }
            }
        ).runTests(backend);
    }

    @("minicerealPutMultipleIntegralWidths." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put!ubyte(0x2au);
                    cereal.put!ushort(0x1234u);
                    ubyte[] expected = [0x2au, 0x34u, 0x12u];
                    assert(cereal.bytes == expected);
                }
            }
        ).runTests(backend);
    }

    @("minicerealPutIntBytesSliceEqual." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put(0x01020304);
                    ubyte[] expected = [4u, 3u, 2u, 1u];
                    assert(cereal.bytes[] == expected);
                }
            }
        ).runTests(backend);
    }

    @("minicerealPutUshortMiddleBytesSliceEqual." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put!ubyte(0x99u);
                    cereal.put!ushort(0x1234u);
                    ubyte[] expected = [0x34u, 0x12u];
                    assert(cereal.bytes[1 .. 3] == expected);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructBoundedSliceBytes." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.bytes = [1, 2, 3, 4];
                    ubyte[] expected = [2, 3];
                    assert(cereal.bytes[1 .. 3] == expected[]);
                }
            }
        ).runTests(backend);
    }

    @("minicerealPutIntTailBytesDollarSliceEqual." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put!ubyte(0x99u);
                    cereal.put(0x01020304);
                    ubyte[] expected = [4u, 3u, 2u, 1u];
                    assert(cereal.bytes[$ - 4 .. $] == expected);
                }
            }
        ).runTests(backend);
    }

    @("minicerealRoundTripUbyte." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put!ubyte(0x2au);
                    size_t pos = 0;
                    assert(cereal.get!ubyte(pos) == 0x2au);
                    assert(pos == 1);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructRoundTripInt." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put(42);
                    size_t pos = 0;
                    assert(cereal.get!int(pos) == 42);
                    assert(pos == 4);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructDecodeKnownInt." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.bytes = [4u, 3u, 2u, 1u];
                    size_t pos = 0;
                    assert(cereal.get!int(pos) == 0x01020304);
                    assert(pos == 4);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructRoundTripHighBitUlong." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    const value = 0x8070605040302010UL;
                    Minicereal cereal;
                    cereal.put(value);
                    size_t pos = 0;
                    const decoded = cereal.get!ulong(pos);
                    assert(decoded == value);
                    assert(decoded > 0UL);
                    assert(pos == 8);
                }
            }
        ).runTests(backend);
    }

    @("minicerealStructRoundTripsIntegralTypes." ~ backend.text)
    unittest {
        import std.file: readText;

        (
            readText("tests/minicereal.d") ~ q{
                unittest {
                    Minicereal cereal;
                    cereal.put!ubyte(0x2au);
                    cereal.put!byte(cast(byte) -42);
                    cereal.put!ushort(0x1234u);
                    cereal.put!short(cast(short) -1234);
                    cereal.put!uint(0x01020304u);
                    cereal.put!int(-0x01020304);
                    cereal.put!ulong(0x8070605040302010UL);
                    cereal.put!long(-0x0102030405060708L);

                    size_t pos = 0;
                    assert(cereal.get!ubyte(pos) == 0x2au);
                    assert(cereal.get!byte(pos) == cast(byte) -42);
                    assert(cereal.get!ushort(pos) == 0x1234u);
                    assert(cereal.get!short(pos) == cast(short) -1234);
                    assert(cereal.get!uint(pos) == 0x01020304u);
                    assert(cereal.get!int(pos) == -0x01020304);
                    assert(cereal.get!ulong(pos) == 0x8070605040302010UL);
                    assert(cereal.get!long(pos) == -0x0102030405060708L);
                    assert(pos == cereal.bytes.length);
                }
            }
        ).runTests(backend);
    }
}

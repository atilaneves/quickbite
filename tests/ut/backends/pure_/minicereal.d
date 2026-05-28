module ut.backends.pure_.minicereal;


import std.file: readText;
import ut.backends;


private:

static foreach (backend; backends) {
    @("minicerealFile." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource);
    }

    @("minicerealFileFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                int value = 42;
                assert(value == 43);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealFileFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] values = [0x2au];
                ubyte[] expected = [0x2bu];
                assert(values == expected);
            }
        })).shouldThrowWithMessage("[42] != [43]");
    }

    @("minicerealEncodeUbyte." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] output;
                encode!ubyte(0x2au, output);
                assert(output.length == 1);
                assert(output[0] == 0x2au);
            }
        }));
    }

    @("minicerealEncodeUbyteFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] output;
                encode!ubyte(0x2au, output);
                assert(output.length == 2);
            }
        })).shouldThrowWithMessage("1 != 2");
    }

    @("minicerealEncodeUbyteFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] output;
                encode!ubyte(0x2au, output);
                assert(output[0] == 0x2bu);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealDecodeUbyte." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] buf = [0x2au];
                size_t pos = 0;
                assert(decode!ubyte(buf, pos) == 0x2au);
                assert(pos == 1);
            }
        }));
    }

    @("minicerealDecodeUbyteFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] buf = [0x2au];
                size_t pos = 0;
                assert(decode!ubyte(buf, pos) == 0x2bu);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealDecodeUbyteFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] buf = [0x2au];
                size_t pos = 0;
                decode!ubyte(buf, pos);
                assert(pos == 2);
            }
        })).shouldThrowWithMessage("1 != 2");
    }

    @("minicerealDecodeUbyteAtOffset." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] input = [0x99u, 0x2au];
                size_t pos = 1;
                assert(decode!ubyte(input, pos) == 0x2au);
                assert(pos == 2);
            }
        }));
    }

    @("minicerealDecodeUbyteAtOffsetFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] input = [0x99u, 0x2au];
                size_t pos = 1;
                assert(decode!ubyte(input, pos) == 0x2bu);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealDecodeUbyteAtOffsetFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] input = [0x99u, 0x2au];
                size_t pos = 1;
                decode!ubyte(input, pos);
                assert(pos == 3);
            }
        })).shouldThrowWithMessage("2 != 3");
    }

    @("minicerealDecodeNegativeInt." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] input = [0xffu, 0xffu, 0xffu, 0xffu];
                size_t pos = 0;
                assert(decode!int(input, pos) == -1);
                assert(pos == 4);
            }
        }));
    }

    @("minicerealDecodeNegativeIntFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] input = [0xffu, 0xffu, 0xffu, 0xffu];
                size_t pos = 0;
                assert(decode!int(input, pos) == 0);
            }
        })).shouldThrowWithMessage("-1 != 0");
    }

    @("minicerealDecodeNegativeIntFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] input = [0xffu, 0xffu, 0xffu, 0xffu];
                size_t pos = 0;
                decode!int(input, pos);
                assert(pos == 5);
            }
        })).shouldThrowWithMessage("4 != 5");
    }

    @("minicerealRoundTripNegativeInt." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                const value = -42;
                ubyte[] buf;
                encode(value, buf);
                size_t pos = 0;
                assert(decode!int(buf, pos) == value);
            }
        }));
    }

    @("minicerealRoundTripNegativeIntFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                const value = -42;
                ubyte[] buf;
                encode(value, buf);
                size_t pos = 0;
                assert(decode!int(buf, pos) == -41);
            }
        })).shouldThrowWithMessage("-42 != -41");
    }

    @("minicerealRoundTripNegativeIntFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                const value = -7;
                ubyte[] buf;
                encode(value, buf);
                size_t pos = 0;
                assert(decode!int(buf, pos) == -6);
            }
        })).shouldThrowWithMessage("-7 != -6");
    }

    @("minicerealEncodeHighBitUlongBytes." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
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
        }));
    }

    @("minicerealEncodeHighBitUlongBytesFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] buf;
                encode(0x8070605040302010UL, buf);
                ubyte[] expected = [
                    0x11u,
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
        })).shouldThrowWithMessage(
            "[16, 32, 48, 64, 80, 96, 112, 128] != " ~
            "[17, 32, 48, 64, 80, 96, 112, 128]",
        );
    }

    @("minicerealEncodeHighBitUlongBytesFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                ubyte[] buf;
                encode(0x0102030405060708UL, buf);
                ubyte[] expected = [9u, 7u, 6u, 5u, 4u, 3u, 2u, 1u];
                assert(buf == expected);
            }
        })).shouldThrowWithMessage(
            "[8, 7, 6, 5, 4, 3, 2, 1] != [9, 7, 6, 5, 4, 3, 2, 1]",
        );
    }

    @("minicerealStructDefaultBytes." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                assert(cereal.bytes.length == 0);
            }
        }));
    }

    @("minicerealStructDefaultBytesFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                assert(cereal.bytes.length == 1);
            }
        })).shouldThrowWithMessage("0 != 1");
    }

    @("minicerealStructDefaultBytesFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                ubyte[] expected = [0x2au];
                assert(cereal.bytes == expected);
            }
        })).shouldThrowWithMessage("[] != [42]");
    }

    @("minicerealStructBytesAppend." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes ~= 0x2au;
                assert(cereal.bytes.length == 1);
                assert(cereal.bytes[0] == 0x2au);
            }
        }));
    }

    @("minicerealStructBytesAppendFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes ~= 0x2au;
                assert(cereal.bytes.length == 2);
            }
        })).shouldThrowWithMessage("1 != 2");
    }

    @("minicerealStructBytesAppendFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes ~= 0x2au;
                assert(cereal.bytes[0] == 0x2bu);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealStructAppendByte." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes ~= cast(ubyte) 42;
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 42);
                assert(pos == 1);
            }
        }));
    }

    @("minicerealStructAppendByteFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes ~= cast(ubyte) 42;
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 43);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealStructAppendByteFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes ~= cast(ubyte) 42;
                size_t pos = 0;
                cereal.get!ubyte(pos);
                assert(pos == 2);
            }
        })).shouldThrowWithMessage("1 != 2");
    }

    @("minicerealStructIndexWriteByte." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [0];
                cereal.bytes[0] = cast(ubyte) 42;
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 42);
            }
        }));
    }

    @("minicerealStructIndexWriteByteFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [0];
                cereal.bytes[0] = cast(ubyte) 42;
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 43);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealStructIndexWriteByteFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [0];
                cereal.bytes[0] = cast(ubyte) 7;
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 8);
            }
        })).shouldThrowWithMessage("7 != 8");
    }

    @("minicerealPutUbyte." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                assert(cereal.bytes.length == 1);
                assert(cereal.bytes[0] == 0x2au);
            }
        }));
    }

    @("minicerealPutUbyteFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                assert(cereal.bytes.length == 2);
            }
        })).shouldThrowWithMessage("1 != 2");
    }

    @("minicerealPutUbyteFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                assert(cereal.bytes[0] == 0x2bu);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealPutUbyteBytesEqual." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                ubyte[] expected = [0x2au];
                assert(cereal.bytes == expected);
            }
        }));
    }

    @("minicerealPutUbyteBytesEqualFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                ubyte[] expected = [0x2bu];
                assert(cereal.bytes == expected);
            }
        })).shouldThrowWithMessage("[42] != [43]");
    }

    @("minicerealPutUbyteBytesEqualFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x07u);
                ubyte[] expected = [0x08u];
                assert(cereal.bytes == expected);
            }
        })).shouldThrowWithMessage("[7] != [8]");
    }

    @("minicerealPutMultipleIntegralWidths." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                cereal.put!ushort(0x1234u);
                ubyte[] expected = [0x2au, 0x34u, 0x12u];
                assert(cereal.bytes == expected);
            }
        }));
    }

    @("minicerealPutMultipleIntegralWidthsFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                cereal.put!ushort(0x1234u);
                ubyte[] expected = [0x2bu, 0x34u, 0x12u];
                assert(cereal.bytes == expected);
            }
        })).shouldThrowWithMessage("[42, 52, 18] != [43, 52, 18]");
    }

    @("minicerealPutMultipleIntegralWidthsFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                cereal.put!ushort(0x1234u);
                ubyte[] expected = [0x2au, 0x35u, 0x12u];
                assert(cereal.bytes == expected);
            }
        })).shouldThrowWithMessage("[42, 52, 18] != [42, 53, 18]");
    }

    @("minicerealPutIntBytesSliceEqual." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put(0x01020304);
                ubyte[] expected = [4u, 3u, 2u, 1u];
                assert(cereal.bytes[] == expected);
            }
        }));
    }

    @("minicerealPutIntBytesSliceEqualFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put(0x01020304);
                ubyte[] expected = [5u, 3u, 2u, 1u];
                assert(cereal.bytes[] == expected);
            }
        })).shouldThrowWithMessage("[4, 3, 2, 1] != [5, 3, 2, 1]");
    }

    @("minicerealPutIntBytesSliceEqualFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put(0x01020304);
                ubyte[] expected = [4u, 4u, 2u, 1u];
                assert(cereal.bytes[] == expected);
            }
        })).shouldThrowWithMessage("[4, 3, 2, 1] != [4, 4, 2, 1]");
    }

    @("minicerealPutUshortMiddleBytesSliceEqual." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x99u);
                cereal.put!ushort(0x1234u);
                ubyte[] expected = [0x34u, 0x12u];
                assert(cereal.bytes[1 .. 3] == expected);
            }
        }));
    }

    @("minicerealPutUshortMiddleBytesSliceEqualFailureMessage.0." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x99u);
                cereal.put!ushort(0x1234u);
                ubyte[] expected = [0x35u, 0x12u];
                assert(cereal.bytes[1 .. 3] == expected);
            }
        })).shouldThrowWithMessage("[52, 18] != [53, 18]");
    }

    @("minicerealPutUshortMiddleBytesSliceEqualFailureMessage.1." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x99u);
                cereal.put!ushort(0x1234u);
                ubyte[] expected = [0x34u, 0x13u];
                assert(cereal.bytes[1 .. 3] == expected);
            }
        })).shouldThrowWithMessage("[52, 18] != [52, 19]");
    }

    @("minicerealStructBoundedSliceBytes." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [1, 2, 3, 4];
                ubyte[] expected = [2, 3];
                assert(cereal.bytes[1 .. 3] == expected[]);
            }
        }));
    }

    @("minicerealStructBoundedSliceBytesFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [1, 2, 3, 4];
                ubyte[] expected = [2, 4];
                assert(cereal.bytes[1 .. 3] == expected[]);
            }
        })).shouldThrowWithMessage("[2, 3] != [2, 4]");
    }

    @("minicerealStructBoundedSliceBytesFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [1, 2, 3, 4];
                ubyte[] expected = [1, 3];
                assert(cereal.bytes[1 .. 3] == expected[]);
            }
        })).shouldThrowWithMessage("[2, 3] != [1, 3]");
    }

    @("minicerealPutIntTailBytesDollarSliceEqual." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x99u);
                cereal.put(0x01020304);
                ubyte[] expected = [4u, 3u, 2u, 1u];
                assert(cereal.bytes[$ - 4 .. $] == expected);
            }
        }));
    }

    @("minicerealPutIntTailBytesDollarSliceEqualFailureMessage.0." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x99u);
                cereal.put(0x01020304);
                ubyte[] expected = [5u, 3u, 2u, 1u];
                assert(cereal.bytes[$ - 4 .. $] == expected);
            }
        })).shouldThrowWithMessage("[4, 3, 2, 1] != [5, 3, 2, 1]");
    }

    @("minicerealPutIntTailBytesDollarSliceEqualFailureMessage.1." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x99u);
                cereal.put(0x01020304);
                ubyte[] expected = [4u, 3u, 2u, 2u];
                assert(cereal.bytes[$ - 4 .. $] == expected);
            }
        })).shouldThrowWithMessage("[4, 3, 2, 1] != [4, 3, 2, 2]");
    }

    @("minicerealRoundTripUbyte." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 0x2au);
                assert(pos == 1);
            }
        }));
    }

    @("minicerealRoundTripUbyteFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                size_t pos = 0;
                assert(cereal.get!ubyte(pos) == 0x2bu);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealRoundTripUbyteFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put!ubyte(0x2au);
                size_t pos = 0;
                cereal.get!ubyte(pos);
                assert(pos == 2);
            }
        })).shouldThrowWithMessage("1 != 2");
    }

    @("minicerealStructRoundTripInt." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put(42);
                size_t pos = 0;
                assert(cereal.get!int(pos) == 42);
                assert(pos == 4);
            }
        }));
    }

    @("minicerealStructRoundTripIntFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put(42);
                size_t pos = 0;
                assert(cereal.get!int(pos) == 43);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealStructRoundTripIntFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.put(42);
                size_t pos = 0;
                cereal.get!int(pos);
                assert(pos == 5);
            }
        })).shouldThrowWithMessage("4 != 5");
    }

    @("minicerealStructDecodeKnownInt." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [4u, 3u, 2u, 1u];
                size_t pos = 0;
                assert(cereal.get!int(pos) == 0x01020304);
                assert(pos == 4);
            }
        }));
    }

    @("minicerealStructDecodeKnownIntFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [4u, 3u, 2u, 1u];
                size_t pos = 0;
                assert(cereal.get!int(pos) == 0x01020305);
            }
        })).shouldThrowWithMessage("16909060 != 16909061");
    }

    @("minicerealStructDecodeKnownIntFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                Minicereal cereal;
                cereal.bytes = [4u, 3u, 2u, 1u];
                size_t pos = 0;
                cereal.get!int(pos);
                assert(pos == 5);
            }
        })).shouldThrowWithMessage("4 != 5");
    }

    @("minicerealStructRoundTripHighBitUlong." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
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
        }));
    }

    @("minicerealStructRoundTripHighBitUlongFailureMessage.0." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                const value = 0x8070605040302010UL;
                Minicereal cereal;
                cereal.put(value);
                size_t pos = 0;
                const decoded = cereal.get!ulong(pos);
                assert(decoded == value + 1);
            }
        })).shouldThrowWithMessage(
            "9255003132036915216 != 9255003132036915217",
        );
    }

    @("minicerealStructRoundTripHighBitUlongFailureMessage.1." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
            unittest {
                const value = 0x8070605040302010UL;
                Minicereal cereal;
                cereal.put(value);
                size_t pos = 0;
                cereal.get!ulong(pos);
                assert(pos == 9);
            }
        })).shouldThrowWithMessage("8 != 9");
    }

    @("minicerealStructRoundTripsIntegralTypes." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
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
        }));
    }

    @("minicerealStructRoundTripsIntegralTypesFailureMessage.0." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
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
                assert(cereal.get!ubyte(pos) == 0x2bu);
            }
        })).shouldThrowWithMessage("42 != 43");
    }

    @("minicerealStructRoundTripsIntegralTypesFailureMessage.1." ~
        backend.stringof)
    unittest {
        newBackend!backend.runTests(minicerealSource(q{
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
                cereal.get!ubyte(pos);
                cereal.get!byte(pos);
                cereal.get!ushort(pos);
                cereal.get!short(pos);
                cereal.get!uint(pos);
                cereal.get!int(pos);
                cereal.get!ulong(pos);
                cereal.get!long(pos);
                assert(pos == cereal.bytes.length + 1);
            }
        })).shouldThrowWithMessage("30 != 31");
    }
}

private string minicerealSource(in string suffix = "") {
    return readText("tests/minicereal.d") ~ suffix;
}

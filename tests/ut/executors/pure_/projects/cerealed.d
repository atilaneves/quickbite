module ut.executors.pure_.projects.cerealed;


import ut.executors.pure_.projects;
import std.conv: text;


private:

static foreach (executorName; projectExecutorNames) {
    @("projects.cerealed.dynamicArrayAppenderPreservesRuntimeByte." ~ executorName.text)
    unittest {
        q{
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
        }.runTests(executorName);
    }

    @("projects.cerealed.refCursorReadAdvancesPosition." ~ executorName.text)
    unittest {
        q{
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
        }.runTests(executorName);
    }

    @("projects.cerealed.postIncrementCursorReadAdvancesPosition." ~ executorName.text)
    unittest {
        q{
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
        }.runTests(executorName);
    }

    @("projects.cerealed.templateLengthPrefixUsesRequestedWidth." ~ executorName.text)
    unittest {
        q{
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
        }.runTests(executorName);
    }
}

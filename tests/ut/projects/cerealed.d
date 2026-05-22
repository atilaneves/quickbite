module ut.projects.cerealed;

private:

import ut.projects;

static foreach (backend; projectBackends) {
    @(backend.text ~ ".projects.cerealed.dynamicArrayAppenderPreservesRuntimeByte")
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
        }.runTests(backend);
    }

    @(backend.text ~ ".projects.cerealed.refCursorReadAdvancesPosition")
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
        }.runTests(backend);
    }

    @(backend.text ~ ".projects.cerealed.templateLengthPrefixUsesRequestedWidth")
    unittest {
        if (backend.bailsOutNewTreeWalker)
            return;

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
        }.runTests(backend);
    }
}

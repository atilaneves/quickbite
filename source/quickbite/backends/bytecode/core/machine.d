module quickbite.backends.bytecode.core.machine;

private:

// Executes the program's entry function and returns the raw bytes of its
// result (empty for void).
package(quickbite.backends.bytecode) ubyte[] run(
    in imported!"quickbite.backends.bytecode.core.program".Program program,
) @safe pure {
    import quickbite.backends.bytecode.core.program: Op, size;
    import std.bitmanip: nativeToLittleEndian;

    const entry = program.functions[0];
    auto frame = new ubyte[](entry.frameSize);
    size_t ip;

    while (true) {
        const instruction = entry.code[ip];
        final switch (instruction.op) with (Op) {
            case loadConstant:
                const ubyte[ulong.sizeof] bytes =
                    nativeToLittleEndian(program.constants[instruction.b]);
                frame[instruction.a .. instruction.a + instruction.c] =
                    bytes[0 .. instruction.c];
                ++ip;
                break;

            case ret:
                const resultSize = size(entry.returnType);
                return frame[
                    instruction.a .. instruction.a + resultSize
                ].dup;
        }
    }
}

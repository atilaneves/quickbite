module quickbite.backends.bytecode.core.machine;

private:

// Compiles the function with the given index into the running program; the
// machine invokes it on the first call to a not-yet-compiled function.
package(quickbite.backends.bytecode) alias CompileFunction =
    void delegate(in size_t index);

// Executes the program's entry function and returns the raw bytes of its
// result (empty for void).
package(quickbite.backends.bytecode) ubyte[] run(
    ref imported!"quickbite.backends.bytecode.core.program".Program program,
    scope CompileFunction compileFunction,
) {
    import quickbite.backends.bytecode.core.program: Op, size;

    auto stack = new ubyte[](program.functions[0].frameSize);
    Frame[] frames;
    size_t functionIndex = 0;
    size_t base = 0;
    size_t ip;

    while (true) {
        const instruction = program.functions[functionIndex].code[ip];
        final switch (instruction.op) with (Op) {
            case loadConstant:
                const ubyte[ulong.sizeof] bytes =
                    littleEndianBytes(program.constants[instruction.b]);
                stack[
                    base + instruction.a .. base + instruction.a + instruction.c
                ] = bytes[0 .. instruction.c];
                ++ip;
                break;

            case copy:
                stack[
                    base + instruction.a .. base + instruction.a + instruction.c
                ] = stack[
                    base + instruction.b .. base + instruction.b + instruction.c
                ];
                ++ip;
                break;

            case signExtend1to4:
                const ubyte[int.sizeof] signWidened = littleEndianBytes(
                    cast(int) littleEndianScalar!byte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = signWidened;
                ++ip;
                break;

            case zeroExtend1to4:
                const ubyte[int.sizeof] zeroWidened = littleEndianBytes(
                    cast(int) littleEndianScalar!ubyte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = zeroWidened;
                ++ip;
                break;

            case signExtend4to8:
                const ubyte[long.sizeof] extended = littleEndianBytes(
                    cast(long) littleEndianScalar!int(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = extended;
                ++ip;
                break;

            case addInt4:
                const ubyte[int.sizeof] sum = littleEndianBytes(
                    littleEndianScalar!int(stack, base + instruction.b) +
                    littleEndianScalar!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = sum;
                ++ip;
                break;

            case equal1, equal2, equal4, equal8:
                const operandSize = equalOperandSize(instruction.op);
                stack[base + instruction.a] =
                    stack[base + instruction.b .. base + instruction.b + operandSize]
                    == stack[base + instruction.c .. base + instruction.c + operandSize];
                ++ip;
                break;

            case jump:
                ip = instruction.a;
                break;

            case jumpIfFalse:
                ip = stack[base + instruction.a] == 0 ? instruction.b : ip + 1;
                break;

            case call:
                if (program.functions[instruction.a].code.length == 0)
                    compileFunction(instruction.a);

                const calleeBase =
                    base + program.functions[functionIndex].frameSize;
                const callee = program.functions[instruction.a];
                if (stack.length < calleeBase + callee.frameSize)
                    stack.length = calleeBase + callee.frameSize;

                stack[calleeBase .. calleeBase + callee.parameterBytes] =
                    stack[
                        base + instruction.b
                        .. base + instruction.b + callee.parameterBytes
                    ];
                frames ~= Frame(functionIndex, ip + 1, base, instruction.c);
                functionIndex = instruction.a;
                base = calleeBase;
                ip = 0;
                break;

            case assertTrue:
                if (stack[base + instruction.a] == 0)
                    throw new Exception(assertMessage(
                        program.assertDiagnostics[instruction.b],
                        stack[base .. $],
                    ));

                ++ip;
                break;

            case ret:
                const resultSize =
                    size(program.functions[functionIndex].returnType);
                if (frames.length == 0)
                    return stack[
                        base + instruction.a
                        .. base + instruction.a + resultSize
                    ].dup;

                const frame = frames[$ - 1];
                frames.length -= 1;
                stack[
                    frame.base + frame.destination
                    .. frame.base + frame.destination + resultSize
                ] = stack[
                    base + instruction.a .. base + instruction.a + resultSize
                ];
                functionIndex = frame.functionIndex;
                base = frame.base;
                ip = frame.ip;
                break;
        }
    }
}

private struct Frame {
    size_t functionIndex;
    size_t ip;
    size_t base;
    ushort destination;
}

private uint equalOperandSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;

    switch (op) with (Op) {
        case equal1: return 1;
        case equal2: return 2;
        case equal4: return 4;
        case equal8: return 8;
        default: assert(0, "Not an equality opcode.");
    }
}

private string assertMessage(
    in imported!"quickbite.backends.bytecode.core.program".AssertDiagnostic
        diagnostic,
    in ubyte[] frame,
) @safe pure {
    import std.conv: text;

    return text(
        operandText(frame, diagnostic.lhs, diagnostic.operandType),
        " ",
        invertedOperator(diagnostic.operator),
        " ",
        operandText(frame, diagnostic.rhs, diagnostic.operandType),
    );
}

private string invertedOperator(in string operator) @safe @nogc nothrow pure {
    switch (operator) {
        case "==": return "!=";
        default: assert(0, "Unsupported assert operator.");
    }
}

private string operandText(
    in ubyte[] frame,
    in size_t offset,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType, isSigned, size;
    import std.conv: text;

    ulong raw;
    foreach_reverse (value; frame[offset .. offset + size(type)])
        raw = (raw << 8) | value;

    final switch (type) with (ScalarType) {
        case bool_:
            return raw == 0 ? "false" : "true";
        case char_:
            return text("'", cast(char) raw, "'");
        case void_, byte_, ubyte_, short_, ushort_, int_, uint_, long_, ulong_,
            wchar_, dchar_:
            break;
    }

    if (!isSigned(type))
        return text(raw);

    const shift = 64 - 8 * size(type);
    const signed = (cast(long) (raw << shift)) >> shift;
    return text(signed);
}

private ubyte[T.sizeof] littleEndianBytes(T)(in T value)
    @safe @nogc nothrow pure
{
    ubyte[T.sizeof] bytes;
    const raw = cast(ulong) value;
    foreach (i; 0 .. T.sizeof)
        bytes[i] = cast(ubyte) ((raw >> (8 * i)) & 0xff);

    return bytes;
}

private T littleEndianScalar(T)(
    in ubyte[] stack,
    in size_t offset,
) @safe @nogc nothrow pure {
    ulong raw;
    foreach (i; 0 .. T.sizeof)
        raw |= cast(ulong) stack[offset + i] << (8 * i);

    return cast(T) raw;
}

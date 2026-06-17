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
                    scalarBytes(program.constants[instruction.b]);
                stack[
                    base + instruction.a .. base + instruction.a + instruction.c
                ] = bytes[0 .. instruction.c];
                ++ip;
                break;

            case loadStringSlice:
                // Write the slice descriptor: data offset then length, each a
                // little-endian uint. reify reads it back at the boundary.
                stack[base + instruction.a .. base + instruction.a + uint.sizeof]
                    = scalarBytes(cast(uint) instruction.b);
                stack[
                    base + instruction.a + uint.sizeof
                    .. base + instruction.a + 2 * uint.sizeof
                ] = scalarBytes(cast(uint) instruction.c);
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
                const ubyte[int.sizeof] signWidened = scalarBytes(
                    cast(int) scalarValue!byte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = signWidened;
                ++ip;
                break;

            case zeroExtend1to4:
                const ubyte[int.sizeof] zeroWidened = scalarBytes(
                    cast(int) scalarValue!ubyte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = zeroWidened;
                ++ip;
                break;

            case signExtend4to8:
                const ubyte[long.sizeof] extended = scalarBytes(
                    cast(long) scalarValue!int(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = extended;
                ++ip;
                break;

            case convertDoubleToInt:
                const ubyte[int.sizeof] converted = scalarBytes(
                    cast(int) floatValue!double(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = converted;
                ++ip;
                break;

            case addInt4:
                const ubyte[int.sizeof] sum = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) +
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = sum;
                ++ip;
                break;

            case bitOrInt4:
                const ubyte[int.sizeof] bits = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) |
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = bits;
                ++ip;
                break;

            case divInt4:
                const ubyte[int.sizeof] quotient = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) /
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = quotient;
                ++ip;
                break;

            case notBool:
                stack[base + instruction.a] =
                    stack[base + instruction.b] == 0 ? 1 : 0;
                ++ip;
                break;

            case normaliseBool:
                stack[base + instruction.a] =
                    stack[base + instruction.b] == 0 ? 0 : 1;
                ++ip;
                break;

            case lessThan4:
                stack[base + instruction.a] =
                    scalarValue!int(stack, base + instruction.b) <
                    scalarValue!int(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThan4:
                stack[base + instruction.a] =
                    scalarValue!int(stack, base + instruction.b) >
                    scalarValue!int(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case addFloat:
                const ubyte[float.sizeof] sum = floatBytes(
                    floatValue!float(stack, base + instruction.b) +
                    floatValue!float(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = sum;
                ++ip;
                break;

            case addDouble:
                const ubyte[double.sizeof] sum = floatBytes(
                    floatValue!double(stack, base + instruction.b) +
                    floatValue!double(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = sum;
                ++ip;
                break;

            case subFloat:
                const ubyte[float.sizeof] difference = floatBytes(
                    floatValue!float(stack, base + instruction.b) -
                    floatValue!float(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = difference;
                ++ip;
                break;

            case subDouble:
                const ubyte[double.sizeof] difference = floatBytes(
                    floatValue!double(stack, base + instruction.b) -
                    floatValue!double(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = difference;
                ++ip;
                break;

            case negateFloat:
                const ubyte[float.sizeof] negated = floatBytes(
                    -floatValue!float(stack, base + instruction.b),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = negated;
                ++ip;
                break;

            case negateDouble:
                const ubyte[double.sizeof] negated = floatBytes(
                    -floatValue!double(stack, base + instruction.b),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = negated;
                ++ip;
                break;

            case fabsFloat:
                import std.math: fabs;
                const ubyte[float.sizeof] result = floatBytes(
                    fabs(floatValue!float(stack, base + instruction.b)),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = result;
                ++ip;
                break;

            case powFloat:
                import std.math: pow;
                // Round through float so the stored result matches a compiled
                // pow(float, float) byte-for-byte.
                const ubyte[float.sizeof] result = floatBytes(cast(float) pow(
                    floatValue!float(stack, base + instruction.b),
                    floatValue!float(stack, base + instruction.c),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = result;
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

            case jumpIfTrue:
                ip = stack[base + instruction.a] != 0 ? instruction.b : ip + 1;
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

            case assertTrueVerbatim:
                if (stack[base + instruction.a] == 0)
                    throw new Exception(
                        program.assertDiagnostics[instruction.b].operator,
                    );

                ++ip;
                break;

            case assertNonzeroInt4:
                if (scalarValue!int(stack, base + instruction.a) == 0)
                    throw new Exception(assertMessage(
                        program.assertDiagnostics[instruction.b],
                        stack[base .. $],
                    ));

                ++ip;
                break;

            case halt:
                throw new Exception("Assertion failure");

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

    // A truth assert (`assert(x)`) carries the empty operator and renders the
    // single operand against the literal `true` it was implicitly compared to.
    if (diagnostic.operator == "")
        return text(
            operandText(frame, diagnostic.lhs, diagnostic.operandType),
            " != true",
        );

    // A logical-not assert (`assert(!x)`) carries the "!" operator and renders
    // the un-negated operand against the `true` it failed to differ from.
    if (diagnostic.operator == "!")
        return text(
            operandText(frame, diagnostic.lhs, diagnostic.operandType),
            " == true",
        );

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
        case float_:
            return text(floatValue!float(frame, offset));
        case double_:
            return text(floatValue!double(frame, offset));
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

private ubyte[T.sizeof] scalarBytes(T)(in T value)
    @safe @nogc nothrow pure
{
    ubyte[T.sizeof] bytes;
    const raw = cast(ulong) value;
    foreach (i; 0 .. T.sizeof)
        bytes[i] = cast(ubyte) ((raw >> (8 * i)) & 0xff);

    return bytes;
}

private T scalarValue(T)(
    in ubyte[] stack,
    in size_t offset,
) @safe @nogc nothrow pure {
    ulong raw;
    foreach (i; 0 .. T.sizeof)
        raw |= cast(ulong) stack[offset + i] << (8 * i);

    return cast(T) raw;
}

// Floating values are reinterpreted, not numerically converted: their bytes
// are the IEEE-754 bit pattern, so read and write them as raw bits.
private T floatValue(T)(
    in ubyte[] stack,
    in size_t offset,
) @safe @nogc nothrow pure
if (is(T == float) || is(T == double)) {
    import std.bitmanip: littleEndianToNative;

    ubyte[T.sizeof] raw = stack[offset .. offset + T.sizeof];
    return littleEndianToNative!T(raw);
}

private ubyte[T.sizeof] floatBytes(T)(in T value) @safe @nogc nothrow pure
if (is(T == float) || is(T == double)) {
    import std.bitmanip: nativeToLittleEndian;

    return nativeToLittleEndian(value);
}

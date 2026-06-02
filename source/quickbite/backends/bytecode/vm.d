module quickbite.backends.bytecode.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.bytecode.instructions".Program program,
) {
    import quickbite.backends.bytecode.instructions: CastTarget, Op;
    import quickbite.lang: Value;

    Value[] stack;
    Value[] locals;

    foreach (instruction; program.instructions) {
        final switch (instruction.op) {
            case Op.literal:
                stack ~= instruction.value;
                break;

            case Op.loadLocal:
                if (instruction.operand >= locals.length)
                    throw new Exception("Bytecode local out of bounds");

                stack ~= locals[instruction.operand];
                break;

            case Op.initializeLocal:
                if (instruction.operand >= locals.length)
                    locals.length = instruction.operand + 1;

                locals[instruction.operand] = instruction.value;
                break;

            case Op.storeLocal:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                if (instruction.operand >= locals.length)
                    locals.length = instruction.operand + 1;

                locals[instruction.operand] = stack[$ - 1];
                stack.length -= 1;
                break;

            case Op.incrementLocal:
                if (instruction.operand >= locals.length)
                    throw new Exception("Bytecode local out of bounds");

                locals[instruction.operand] = locals[instruction.operand] +
                    instruction.value;
                break;

            case Op.cast_:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                final switch (cast(CastTarget) instruction.operand) {
                    case CastTarget.byte_:
                        stack[$ - 1] = stack[$ - 1].castTo!byte;
                        break;

                    case CastTarget.ubyte_:
                        stack[$ - 1] = stack[$ - 1].castTo!ubyte;
                        break;

                    case CastTarget.short_:
                        stack[$ - 1] = stack[$ - 1].castTo!short;
                        break;

                    case CastTarget.ushort_:
                        stack[$ - 1] = stack[$ - 1].castTo!ushort;
                        break;

                    case CastTarget.int_:
                        stack[$ - 1] = stack[$ - 1].castTo!int;
                        break;

                    case CastTarget.uint_:
                        stack[$ - 1] = stack[$ - 1].castTo!uint;
                        break;

                    case CastTarget.long_:
                        stack[$ - 1] = stack[$ - 1].castTo!long;
                        break;

                    case CastTarget.ulong_:
                        stack[$ - 1] = stack[$ - 1].castTo!ulong;
                        break;
                }
                break;

            case Op.add:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs + rhs;
                break;

            case Op.subtract:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs - rhs;
                break;

            case Op.multiply:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs * rhs;
                break;

            case Op.divide:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs / rhs;
                break;

            case Op.negate:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = -stack[$ - 1];
                break;

            case Op.fabs:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = stack[$ - 1].fabs;
                break;

            case Op.pow:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs.pow(rhs);
                break;
        }
    }

    if (stack.length != 1)
        throw new Exception("Bytecode program did not leave exactly one value");

    return stack[0];
}

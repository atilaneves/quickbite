module quickbite.backends.bytecode.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.bytecode.instructions".Program program,
) {
    auto result = run(program);
    if (result.stack.length != 1)
        throw new Exception("Bytecode program did not leave exactly one value");

    return result.stack[0];
}

package void execute(
    in imported!"quickbite.backends.bytecode.instructions".Program program,
) {
    auto result = run(program);
    if (result.stack.length != 0)
        throw new Exception("Bytecode test left values on the stack");
}

private RunResult run(
    in imported!"quickbite.backends.bytecode.instructions".Program program,
) {
    import quickbite.backends.bytecode.builtins:
        BytecodeBuiltin, binaryBuiltinCall, unaryBuiltinCall;
    import quickbite.backends.bytecode.instructions: Op;
    import quickbite.backends.casts: CastTarget, castValue;
    import quickbite.lang: Value;

    Value[] stack;
    Value[] locals;
    Frame[] frames;
    size_t ip;

    while (ip < program.instructions.length) {
        const instruction = program.instructions[ip];
        final switch (instruction.op) {
            case Op.literal:
                stack ~= instruction.value;
                ++ip;
                break;

            case Op.call:
                if (instruction.operand >= program.functions.length)
                    throw new Exception("Bytecode function out of bounds");

                const function_ = program.functions[instruction.operand];
                Value[] calleeLocals;
                calleeLocals.length = function_.parameterCount;
                foreach_reverse (index; 0 .. function_.parameterCount) {
                    if (stack.length < 1)
                        throw new Exception("Bytecode stack underflow");

                    calleeLocals[index] = stack[$ - 1];
                    stack.length -= 1;
                }

                frames ~= Frame(ip + 1, locals);
                locals = calleeLocals;
                ip = function_.entry;
                break;

            case Op.loadLocal:
                if (instruction.operand >= locals.length)
                    throw new Exception("Bytecode local out of bounds");

                stack ~= locals[instruction.operand];
                ++ip;
                break;

            case Op.initializeLocal:
                if (instruction.operand >= locals.length)
                    locals.length = instruction.operand + 1;

                locals[instruction.operand] = instruction.value;
                ++ip;
                break;

            case Op.storeLocal:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                if (instruction.operand >= locals.length)
                    locals.length = instruction.operand + 1;

                locals[instruction.operand] = stack[$ - 1];
                stack.length -= 1;
                ++ip;
                break;

            case Op.incrementLocal:
                if (instruction.operand >= locals.length)
                    throw new Exception("Bytecode local out of bounds");

                locals[instruction.operand] = locals[instruction.operand] +
                    instruction.value;
                ++ip;
                break;

            case Op.cast_:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = castValue(
                    stack[$ - 1],
                    cast(CastTarget) instruction.operand,
                );
                ++ip;
                break;

            case Op.equal:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs == rhs);
                ++ip;
                break;

            case Op.add:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs + rhs;
                ++ip;
                break;

            case Op.subtract:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs - rhs;
                ++ip;
                break;

            case Op.multiply:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs * rhs;
                ++ip;
                break;

            case Op.divide:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs / rhs;
                ++ip;
                break;

            case Op.negate:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = -stack[$ - 1];
                ++ip;
                break;

            case Op.unaryNativeCall:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = unaryBuiltinCall(
                    cast(BytecodeBuiltin) instruction.operand,
                    stack[$ - 1],
                );
                ++ip;
                break;

            case Op.binaryNativeCall:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= binaryBuiltinCall(
                    cast(BytecodeBuiltin) instruction.operand,
                    lhs,
                    rhs,
                );
                ++ip;
                break;

            case Op.assertCompare:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                if (lhs != rhs)
                    throw new Exception(assertCompareMessage(lhs, rhs));

                ++ip;
                break;

            case Op.assertTrue:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                const value = stack[$ - 1];
                stack.length -= 1;
                if (value.asLong == 0)
                    throw new Exception("Unittest assertion failed.");

                ++ip;
                break;

            case Op.throw_:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                const value = stack[$ - 1];
                throw new Exception(value.asCharArrayString);

            case Op.ret:
                if (frames.length == 0)
                    return RunResult(stack);

                auto frame = frames[$ - 1];
                frames.length -= 1;
                locals = frame.locals;
                ip = frame.returnIp;
                break;

            case Op.halt:
                return RunResult(stack);
                break;
        }
    }

    return RunResult(stack);
}

private struct RunResult {
    imported!"quickbite.lang".Value[] stack;
}

private struct Frame {
    size_t returnIp;
    imported!"quickbite.lang".Value[] locals;
}

private string assertCompareMessage(
    in imported!"quickbite.lang".Value lhs,
    in imported!"quickbite.lang".Value rhs,
) @safe pure {
    import std.conv: text;

    return text(lhs.asLong, " != ", rhs.asLong);
}

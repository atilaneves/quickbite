module quickbite.backends.bytecode.vm;

private:

import quickbite.backends.bytecode.program: BytecodeModule, BytecodeValue, OpCode;

public void execute(BytecodeModule module_) {
    BytecodeValue[] stack;
    BytecodeValue[] locals;
    size_t[] returnAddresses;
    size_t ip;

    while (ip < module_.code.length) {
        const instruction = module_.code[ip];
        final switch (instruction.op) with (OpCode) {
            case pushValue:
                stack ~= instruction.valueOperand;
                ++ip;
                break;
            case loadLocal:
                stack ~= locals[instruction.indexOperand];
                ++ip;
                break;
            case storeLocal:
                const index = instruction.indexOperand;
                if (locals.length <= index)
                    locals.length = index + 1;
                locals[index] = stack.popValue;
                ++ip;
                break;
            case call:
                returnAddresses ~= ip + 1;
                ip = module_.functionEntries[instruction.indexOperand];
                break;
            case add:
                const right = stack.popValue;
                const left = stack.popValue;
                stack ~= BytecodeValue(left.asInt + right.asInt);
                ++ip;
                break;
            case equal:
                const right = stack.popValue;
                const left = stack.popValue;
                stack ~= BytecodeValue(left.asInt == right.asInt ? 1 : 0);
                ++ip;
                break;
            case assertTrue:
                if (stack.popValue.asInt == 0)
                    throw new Exception("bytecode assertion failed");
                ++ip;
                break;
            case ret:
                ip = returnAddresses.popSize;
                break;
            case halt:
                return;
        }
    }
}

private BytecodeValue popValue(ref BytecodeValue[] stack) {
    const value = stack[$ - 1];
    stack = stack[0 .. $ - 1];
    return value;
}

private size_t popSize(ref size_t[] stack) {
    const value = stack[$ - 1];
    stack = stack[0 .. $ - 1];
    return value;
}

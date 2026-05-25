module quickbite.backends.bytecode.opcode;

private:

public enum OpCode : ubyte {
    pushInteger,
    call,
    add,
    subtract,
    multiply,
    divide,
    modulo,
    shiftRight,
    shiftLeft,
    bitwiseOr,
    bitwiseAnd,
    bitwiseXor,
    equal,
    notEqual,
    lessThan,
    lessOrEqual,
    greaterThan,
    greaterOrEqual,
    assertEqual,
    ret,
    halt,
}

public struct Instruction {
    public OpCode op;
    public long operand;
}

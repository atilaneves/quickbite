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
    equal,
    assertEqual,
    ret,
    halt,
}

public struct Instruction {
    public OpCode op;
    public long operand;
}

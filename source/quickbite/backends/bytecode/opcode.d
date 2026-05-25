module quickbite.backends.bytecode.opcode;

private:

public enum OpCode : ubyte {
    pushInteger,
    call,
    equal,
    assertTrue,
    ret,
    halt,
}

public struct Instruction {
    public OpCode op;
    public long operand;
}

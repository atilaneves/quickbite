module quickbite.backends.bytecode.module_;

private:

public enum OpCode : ubyte {
    pushInt,
    loadLocal,
    storeLocal,
    call,
    add,
    equal,
    assertTrue,
    ret,
    halt,
}

public alias BytecodeInt = int;

public struct Instruction {
    public OpCode op;
    public BytecodeInt integerOperand;
    public size_t indexOperand;
}

public struct BytecodeModule {
    public Instruction[] code;
    public size_t[] functionEntries;
    public size_t localCount;
}

public Instruction pushInt(in BytecodeInt value) @safe pure {
    return Instruction(OpCode.pushInt, value);
}

public Instruction indexInstruction(in OpCode op, in size_t index) @safe pure {
    return Instruction(op, BytecodeInt.init, index);
}

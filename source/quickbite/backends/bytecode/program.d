module quickbite.backends.bytecode.program;

private:

public enum OpCode : ubyte {
    pushValue,
    loadLocal,
    storeLocal,
    call,
    add,
    equal,
    assertTrue,
    ret,
    halt,
}

public alias BytecodeValue = imported!"quickbite.lang".Value;

public struct Instruction {
    public OpCode op;
    public BytecodeValue valueOperand;
    public size_t indexOperand;
}

public struct BytecodeModule {
    public Instruction[] code;
    public size_t[] functionEntries;
    public size_t variableCount;
}

public Instruction pushValue(in BytecodeValue value) @safe pure {
    return Instruction(OpCode.pushValue, value);
}

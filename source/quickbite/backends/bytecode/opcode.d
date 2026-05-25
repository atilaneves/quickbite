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
    setAssertMessage,
    assertCompare,
    assertTrue,
    ret,
    halt,
}

public struct Instruction {
    import quickbite.executor: Value;

    public OpCode op;
    public long operand;
    public Value valueOperand;

    public this(in OpCode op) @safe pure {
        this.op = op;
    }

    public this(in OpCode op, in long operand) @safe pure {
        this.op = op;
        this.operand = operand;
        this.valueOperand = Value(operand);
    }

    public this(in OpCode op, in Value operand) @safe pure {
        this.op = op;
        this.valueOperand = operand;
        this.operand = operand.asLong;
    }
}

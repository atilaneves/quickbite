module quickbite.ir.instruction;

private:

import std.sumtype: SumType;

// Value-producing IR instructions write to an explicit temporary.
public struct ConstInt {
    uint destination;
    int value;
}

public struct Call {
    uint destination;
    string calleeName;
    uint[] arguments;
}

public struct BinaryOp {
    uint destination;
    uint left;
    uint right;
    Operation operation;
}

public enum Operation {
    add,
    subtract,
    multiply,
    divide,
    modulo,
    equal,
    notEqual,
    lessThan,
    lessOrEqual,
    greaterThan,
    greaterOrEqual,
}

public struct UnaryOp {
    uint destination;
    uint source;
    UnaryOperation operation;
}

public enum UnaryOperation {
    negate,
}

public struct Select {
    uint destination;
    uint condition;
    uint ifTrue;
    uint ifFalse;
}

public struct Copy {
    uint destination;
    uint source;
}

public struct CastInt {
    uint destination;
    uint source;
    IntegerType target;
}

public enum IntegerType {
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
}

public struct Assert_ {
    uint condition;
}

public alias Instruction = SumType!(
    ConstInt,
    Call,
    BinaryOp,
    UnaryOp,
    Select,
    Copy,
    CastInt,
    Assert_,
);

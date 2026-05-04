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

public struct Assert_ {
    uint condition;
}

public alias Instruction = SumType!(
    ConstInt,
    Call,
    BinaryOp,
    Select,
    Copy,
    Assert_,
);

module quickbite.ir.instruction;

private:

import std.sumtype: SumType;

// Value-producing IR instructions write to an explicit temporary.
public struct ConstInt {
    uint destination;
    int value;
}

public struct Add {
    uint destination;
    uint left;
    uint right;
}

public struct Subtract {
    uint destination;
    uint left;
    uint right;
}

public struct Multiply {
    uint destination;
    uint left;
    uint right;
}

public struct Divide {
    uint destination;
    uint left;
    uint right;
}

public struct Modulo {
    uint destination;
    uint left;
    uint right;
}

public struct Call {
    uint destination;
    string calleeName;
}

public struct Equal {
    uint destination;
    uint left;
    uint right;
}

public struct Assert_ {
    uint condition;
}

public alias Instruction = SumType!(
    ConstInt,
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,
    Call,
    Equal,
    Assert_,
);

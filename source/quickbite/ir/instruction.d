module quickbite.ir.instruction;

private:

import std.sumtype: SumType;

public struct ConstInt {
    // Value-producing IR instructions write to an explicit temporary.
    uint destination;
    int value;
}

public struct Add {
    // Value-producing IR instructions write to an explicit temporary.
    uint destination;
    uint left;
    uint right;
}

public struct Call {
    // Value-producing IR instructions write to an explicit temporary.
    uint destination;
    string calleeName;
}

public struct Equal {
    // Value-producing IR instructions write to an explicit temporary.
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
    Call,
    Equal,
    Assert_,
);

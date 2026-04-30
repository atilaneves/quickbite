module quickbite.ir.instruction;

private:

import std.sumtype: SumType;

public struct ConstInt {
    uint destination;
    int value;
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
    Call,
    Equal,
    Assert_,
);

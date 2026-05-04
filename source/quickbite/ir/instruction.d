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
    uint[] arguments;
}

public struct Equal {
    uint destination;
    uint left;
    uint right;
}

public struct NotEqual {
    uint destination;
    uint left;
    uint right;
}

public struct LessThan {
    uint destination;
    uint left;
    uint right;
}

public struct LessOrEqual {
    uint destination;
    uint left;
    uint right;
}

public struct GreaterThan {
    uint destination;
    uint left;
    uint right;
}

public struct GreaterOrEqual {
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
    NotEqual,
    LessThan,
    LessOrEqual,
    GreaterThan,
    GreaterOrEqual,
    Assert_,
);

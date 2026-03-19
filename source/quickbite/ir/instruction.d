module quickbite.ir.instruction;

private:

public enum Kind {
    constInt,
    call,
    equal,
    assert_,
}

public struct Instruction {
    Kind kind;
    uint destination;
    int value;
    string calleeName;
    uint left;
    uint right;
    uint condition;
}

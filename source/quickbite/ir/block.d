module quickbite.ir.block;

private:

public enum TerminatorKind {
    return_,
    returnVoid,
}

public struct Terminator {
    TerminatorKind kind;
    uint value;
}

public struct Block {
    import quickbite.ir.instruction: Instruction;

    Instruction[] instructions;
    Terminator terminator;
}

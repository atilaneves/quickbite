module quickbite.ir.block;

private:

public enum TerminatorKind {
    return_,
    returnVoid,
}

public struct Terminator {
    public TerminatorKind kind;
    public uint value;
}

public struct Block {
    public imported!"quickbite.ir.instruction".Instruction[] instructions;
    public Terminator terminator;
}

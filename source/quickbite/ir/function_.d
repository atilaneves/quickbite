module quickbite.ir.function_;

private:

public struct Function {
    import quickbite.ir.instruction: Instruction;

    string name;
    Instruction[] instructions;
    uint returnValue;
}

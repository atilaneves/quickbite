module quickbite.ir.function_;

private:

public struct Function {
    import quickbite.ir.instruction: Instruction;

    string name;
    Instruction[] instructions;
    bool hasReturnValue;
    uint numParameters;
    bool[] refParameters;
    // Lets the VM allocate all temporary registers before execution.
    uint numTemporaries;
}

module quickbite.ir.function_;

private:

public struct Function {
    import quickbite.ir.instruction: Instruction;

    string name;
    Instruction[] instructions;
    bool hasReturnValue;
    uint returnValue;
    uint numParameters;
    // Lets the VM allocate all temporary registers before execution.
    uint numTemporaries;
}

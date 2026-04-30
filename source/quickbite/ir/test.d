module quickbite.ir.test;

private:

public struct Test {
    import quickbite.ir.instruction: Instruction;

    Instruction[] instructions;
    // Lets the VM allocate all temporary registers before execution.
    uint numTemporaries;
}

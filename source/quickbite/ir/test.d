module quickbite.ir.test;

private:

public struct Test {
    import quickbite.ir.instruction: Instruction;

    Instruction[] instructions;
    // Unittest bodies use the same temporary register allocation as functions.
    uint numTemporaries;
}

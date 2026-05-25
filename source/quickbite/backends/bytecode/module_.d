module quickbite.backends.bytecode.module_;

private:

package(quickbite.backends.bytecode) struct BytecodeModule {
    import dmd.func: FuncDeclaration;
    import quickbite.backends.bytecode.opcode: Instruction;

    public Instruction[] code;
    public FuncDeclaration[] functions;
    public size_t[FuncDeclaration] functionIndexes;
    public size_t[FuncDeclaration] functionEntries;
}

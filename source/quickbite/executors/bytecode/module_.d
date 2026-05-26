module quickbite.executors.bytecode.module_;

private:

package(quickbite.executors.bytecode) struct BytecodeModule {
    import dmd.func: FuncDeclaration;
    import quickbite.executors.bytecode.opcode: Instruction;

    public Instruction[] code;
    public FuncDeclaration[] functions;
    public size_t[FuncDeclaration] functionIndexes;
    public size_t[FuncDeclaration] functionEntries;
    public string[] assertMessages;
}

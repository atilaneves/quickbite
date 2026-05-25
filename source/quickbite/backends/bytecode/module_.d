module quickbite.backends.bytecode.module_;

private:

import dmd.func: FuncDeclaration;
import quickbite.backends.bytecode.opcode: Instruction;

package(quickbite.backends.bytecode) struct BytecodeModule {
    public Instruction[] code;
    public FuncDeclaration[] functions;
    public size_t[FuncDeclaration] functionIndexes;
    public size_t[FuncDeclaration] functionEntries;
}

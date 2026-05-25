module quickbite.backends.bytecode.module_;

private:

import dmd.func: FuncDeclaration;
import quickbite.backends.bytecode.opcode: Instruction;

public struct BytecodeModule {
    public Instruction[] code;
    public FuncDeclaration[] functions;
    public size_t[FuncDeclaration] functionIndexes;
    public size_t[FuncDeclaration] functionEntries;
}

public struct Emitter {
    private BytecodeModule* module_;

    public this(return scope BytecodeModule* module_) @safe @nogc nothrow {
        this.module_ = module_;
    }

    public size_t position() const @safe @nogc nothrow {
        return module_.code.length;
    }

    public void emit(in Instruction instruction) {
        module_.code ~= instruction;
    }
}

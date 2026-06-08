module quickbite.backends.bytecode.instructions;

private:

package enum Op: ubyte {
    literal,
    call,
    loadLocal,
    initializeLocal,
    storeLocal,
    incrementLocal,
    cast_,
    equal,
    add,
    subtract,
    multiply,
    divide,
    negate,
    unaryNativeCall,
    binaryNativeCall,
    assertCompare,
    assertTrue,
    ret,
    halt,
}

package struct Instruction {
    Op op;
    imported!"quickbite.lang".Value value;
    size_t operand;
}

package struct Function {
    // Offset in Program.instructions where this function's bytecode starts.
    size_t entry;
    size_t parameterCount;
}

package struct Program {
    Instruction[] instructions;
    Function[] functions;
}

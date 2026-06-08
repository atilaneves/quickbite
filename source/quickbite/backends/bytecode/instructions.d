module quickbite.backends.bytecode.instructions;

private:

package enum Op: ubyte {
    literal,
    call,
    jump,
    jumpIfFalse,
    pop,
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
    bitOr,
    lessThan,
    greaterThan,
    not_,
    negate,
    unaryNativeCall,
    binaryNativeCall,
    assertCompare,
    assertFalse,
    assertTrue,
    throw_,
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

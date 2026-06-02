module quickbite.backends.bytecode.instructions;

private:

package enum Op: ubyte {
    literal,
    loadLocal,
    initializeLocal,
    storeLocal,
    incrementLocal,
    cast_,
    add,
    subtract,
    multiply,
    divide,
    negate,
    fabs,
    pow,
}

package struct Instruction {
    Op op;
    imported!"quickbite.lang".Value value;
    size_t operand;
}

package struct Program {
    Instruction[] instructions;
}

module quickbite.backends.bytecode.instructions;

private:

package enum Op: ubyte {
    literal,
    loadLocal,
    initializeLocal,
    incrementLocal,
    add,
    subtract,
    multiply,
    divide,
}

package struct Instruction {
    Op op;
    imported!"quickbite.lang".Value value;
    size_t operand;
}

package struct Program {
    Instruction[] instructions;
}

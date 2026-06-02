module quickbite.backends.bytecode.instructions;

private:

package enum Op: ubyte {
    literal,
    add,
    subtract,
    multiply,
    divide,
}

package struct Instruction {
    Op op;
    imported!"quickbite.lang".Value value;
}

package struct Program {
    Instruction[] instructions;
}

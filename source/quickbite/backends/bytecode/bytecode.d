module quickbite.backends.bytecode.bytecode;

private:

package enum Op: ubyte {
    literal,
}

package struct Instruction {
    Op op;
    imported!"quickbite.lang".Value value;
}

package struct Program {
    Instruction[] instructions;
}

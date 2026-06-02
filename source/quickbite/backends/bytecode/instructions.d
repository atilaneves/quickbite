module quickbite.backends.bytecode.instructions;

private:

package enum Op: ubyte {
    literal,
    loadLocal,
    initializeLocal,
    storeLocal,
    cast_,
    add,
    subtract,
    multiply,
    divide,
    negate,
    unaryNativeCall,
    binaryNativeCall,
}

// Operand domain for Op.cast_; kept separate from raw size_t operands so cast
// targets cannot be confused with local-slot indices or native-call ids.
package enum CastTarget: size_t {
    byte_,
    ubyte_,
    short_,
    ushort_,
    int_,
    uint_,
    long_,
    ulong_,
}

// Temporary escape hatch for resolved external calls while bytecode has no
// general D function-call support. These are host-implemented calls, not
// language primitives; delete this enum once calls compile through bytecode.
package enum NativeFunction: size_t {
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

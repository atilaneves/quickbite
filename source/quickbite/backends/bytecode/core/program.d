module quickbite.backends.bytecode.core.program;

private:

// The static type of a frame slot or function result. The compiler maps DMD
// types to these tags at emit time; no runtime value carries a tag.
package(quickbite.backends.bytecode) enum ScalarType: ubyte {
    void_,
    int_,
}

package(quickbite.backends.bytecode) uint size(in ScalarType type)
    @safe @nogc nothrow pure
{
    final switch (type) with (ScalarType) {
        case void_:
            return 0;
        case int_:
            return int.sizeof;
    }
}

// Fixed-width instruction: an opcode and up to three 16-bit operands (frame
// byte offsets, constant pool indices, function indices).
package(quickbite.backends.bytecode) enum Op: ubyte {
    loadConstant, // a: destination frame offset, b: constant index, c: size
    ret, // a: frame offset of the return value
}

package(quickbite.backends.bytecode) struct Instruction {
    Op op;
    ushort a;
    ushort b;
    ushort c;
}

package(quickbite.backends.bytecode) struct CompiledFunction {
    Instruction[] code;
    uint frameSize;
    ScalarType returnType;
}

package(quickbite.backends.bytecode) struct Program {
    CompiledFunction[] functions; // index 0 is the entry function
    ulong[] constants; // raw bits; loadConstant copies the low `c` bytes
}

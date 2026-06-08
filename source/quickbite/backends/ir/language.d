module quickbite.backends.ir.language;

private:

package enum Type {
    bool_,
    byte_,
    ubyte_,
    char_,
    short_,
    ushort_,
    int_,
    uint_,
    long_,
    ulong_,
    float_,
    double_,
    real_,
    ptr,
}

package struct Value {
    public uint id;
    public Type type;
}

package enum BinaryOperation {
    add,
    sub,
    mul,
    div,
}

package enum UnaryOperation {
    neg,
}

package struct Const {
    public ulong bits;
    public Value destination;
}

package struct Cast {
    public uint source;
    public Type sourceType;
    public Value destination;
}

package struct UnaryOp {
    public UnaryOperation operation;
    public Type type;
    public uint source;
    public Value destination;
}

package struct BinaryOp {
    public BinaryOperation operation;
    public Type type;
    public uint lhs;
    public uint rhs;
    public Value destination;
}

package alias Instruction = imported!"std.sumtype".SumType!(
    Const,
    Cast,
    UnaryOp,
    BinaryOp,
);

package struct Branch {
    public uint target;
    public uint[] args;
}

package struct CondBranch {
    public uint condition;
    public uint trueTarget;
    public uint[] trueArgs;
    public uint falseTarget;
    public uint[] falseArgs;
}

package struct ReturnValue {
    public uint value;
}

package struct ReturnVoid {
}

package alias Terminator = imported!"std.sumtype".SumType!(
    Branch,
    CondBranch,
    ReturnValue,
    ReturnVoid,
);

package struct Block {
    public uint id;
    public Value[] params;
    public Instruction[] instructions;
    public Terminator terminator;
    public bool hasExceptionSuccessor;
    public uint exceptionSuccessor;
}

package struct Function {
    public Block[] blocks;
    public Type returnType;
    public uint valueCount;
}

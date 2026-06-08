module quickbite.backends.ir.language;

private:

package enum Type {
    i1,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
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

package struct Const {
    public ulong bits;
    public Value destination;
}

package struct BinaryOp {
    public BinaryOperation operation;
    public Type type;
    public uint lhs;
    public uint rhs;
    public Value destination;
}

package alias Instruction = imported!"std.sumtype".SumType!(Const, BinaryOp);

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

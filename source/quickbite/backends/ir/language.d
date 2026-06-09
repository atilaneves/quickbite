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

package enum ResultKind {
    bool_,
    byte_,
    ubyte_,
    short_,
    ushort_,
    int_,
    uint_,
    long_,
    ulong_,
    char_,
    float_,
    double_,
    string_,
}

package struct Value {
    public uint id;
    public Type type;
    public ResultKind resultKind;
}

package enum BinaryOperation {
    add,
    subtract,
    multiply,
    divide,
    bitwiseOr,
    pow,
    equal,
}

package enum UnaryOperation {
    negate,
    not_,
}

package enum UnaryIntrinsicOperation {
    fabs,
}

package struct Const {
    public ulong bits;
    public Value result;
}

package struct StringConst {
    public string elements;
    public Value result;
}

package struct BinaryOp {
    public BinaryOperation operation;
    public Type type;
    public uint lhs;
    public uint rhs;
    public Value result;
}

package struct UnaryOp {
    public UnaryOperation operation;
    public Type type;
    public uint source;
    public Value result;
}

package struct UnaryIntrinsicOp {
    public UnaryIntrinsicOperation operation;
    public Type type;
    public uint source;
    public Value result;
}

package struct Cast {
    public Type sourceType;
    public Type targetType;
    public uint source;
    public Value result;
}

package struct Call {
    public uint functionIndex;
    public uint[] arguments;
    public Value result;
}

package struct AssertTrue {
    public uint condition;
    public string message;
}

package struct AssertFalse {
    public uint condition;
}

package struct AssertCompare {
    public BinaryOperation operation;
    public Type type;
    public ResultKind resultKind;
    public uint lhs;
    public uint rhs;
}

package struct ThrowException {
    public string message;
}

package struct Load {
    public uint local;
    public Value result;
}

package struct Store {
    public uint local;
    public Type type;
    public uint value;
}

package alias Instruction = imported!"std.sumtype".SumType!(
    Const,
    StringConst,
    BinaryOp,
    UnaryOp,
    UnaryIntrinsicOp,
    Cast,
    Call,
    AssertTrue,
    AssertFalse,
    AssertCompare,
    ThrowException,
    Load,
    Store,
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
    public ResultKind returnType;
    public uint valueCount;
    public uint localCount;
    public uint parameterCount;
    public Function[] functions;
}

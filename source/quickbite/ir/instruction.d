module quickbite.ir.instruction;

private:

import std.sumtype: SumType;

// Value-producing IR instructions write to an explicit temporary.
public struct ConstInt {
    uint destination;
    long value;
}

public struct Call {
    uint destination;
    string calleeName;
    uint[] arguments;
}

public struct BinaryOp {
    uint destination;
    uint left;
    uint right;
    Operation operation;
}

public enum Operation {
    add,
    subtract,
    multiply,
    divide,
    modulo,
    leftShift,
    rightShift,
    bitwiseAnd,
    bitwiseOr,
    bitwiseXor,
    equal,
    notEqual,
    lessThan,
    unsignedLessThan,
    lessOrEqual,
    unsignedLessOrEqual,
    greaterThan,
    greaterOrEqual,
    unsignedGreaterOrEqual,
    unsignedGreaterThan,
}

public struct UnaryOp {
    uint destination;
    uint source;
    UnaryOperation operation;
}

public enum UnaryOperation {
    negate,
    not,
    complement,
}

public struct Select {
    uint destination;
    uint condition;
    uint ifTrue;
    uint ifFalse;
}

public struct JumpIfFalse {
    uint condition;
    uint offset;
}

public struct JumpIfTrue {
    uint condition;
    uint offset;
}

public struct Copy {
    uint destination;
    uint source;
}

public struct CastInt {
    uint destination;
    uint source;
    IntegerType target;
}

public enum IntegerType {
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
}

public struct Assert_ {
    uint condition;
}

public struct ArrayLiteral {
    uint destination;
    uint[] elements;
}

public struct ArrayAppend {
    uint array;
    uint value;
}

public struct ArrayLength {
    uint destination;
    uint array;
}

public struct ArrayIndex {
    uint destination;
    uint array;
    uint index;
}

public struct ArraySet {
    uint array;
    uint index;
    uint value;
}

public struct ArrayEqual {
    uint destination;
    uint left;
    uint right;
}

public struct ArraySlice {
    uint destination;
    uint array;
    uint lower;
    uint upper;
}

public struct StructNew {
    uint destination;
}

public struct StructGet {
    uint destination;
    uint struct_;
    string fieldName;
}

public struct StructSet {
    uint struct_;
    string fieldName;
    uint value;
}

public struct ReturnValue {
    uint value;
}

public alias Instruction = SumType!(
    ConstInt,
    Call,
    BinaryOp,
    UnaryOp,
    Select,
    JumpIfFalse,
    JumpIfTrue,
    Copy,
    CastInt,
    Assert_,
    ArrayLiteral,
    ArrayAppend,
    ArrayLength,
    ArrayIndex,
    ArraySet,
    ArrayEqual,
    ArraySlice,
    StructNew,
    StructGet,
    StructSet,
    ReturnValue,
);

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
    bitScanReverse,
}

public struct Select {
    uint destination;
    uint condition;
    uint ifTrue;
    uint ifFalse;
}

public struct JumpIfFalse {
    uint condition;
    int offset;
}

public struct JumpIfTrue {
    uint condition;
    int offset;
}

public struct Jump {
    int offset;
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

public struct AssocArrayLiteral {
    uint destination;
    uint[] keys;
    uint[] values;
}

public struct AssocArrayLength {
    uint destination;
    uint array;
}

public struct AssocArrayKeys {
    uint destination;
    uint array;
}

public struct AssocArrayValues {
    uint destination;
    uint array;
}

public struct AssocArrayIndex {
    uint destination;
    uint array;
    uint key;
}

public struct AssocArrayValuePointer {
    uint destination;
    uint array;
    uint key;
}

public struct AssocArraySet {
    uint array;
    uint key;
    uint value;
}

public struct ArrayCopy {
    uint destination;
    uint source;
}

public struct ArrayReferenceCopy {
    uint destination;
    uint source;
}

public struct ArrayAppend {
    uint array;
    uint value;
}

public struct ArrayAppendArray {
    uint array;
    uint value;
}

public struct ArrayLength {
    uint destination;
    uint array;
}

public struct ArraySetLength {
    uint array;
    uint length;
}

public struct ArrayConcat {
    uint destination;
    uint left;
    uint right;
}

public struct ArrayIndex {
    uint destination;
    uint array;
    uint index;
}

public struct ArrayElementPointer {
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

public struct ReturnVoid {
}

public alias Instruction = SumType!(
    ConstInt,
    Call,
    BinaryOp,
    UnaryOp,
    Select,
    JumpIfFalse,
    JumpIfTrue,
    Jump,
    Copy,
    CastInt,
    Assert_,
    ArrayLiteral,
    AssocArrayLiteral,
    AssocArrayLength,
    AssocArrayKeys,
    AssocArrayValues,
    AssocArrayIndex,
    AssocArrayValuePointer,
    AssocArraySet,
    ArrayCopy,
    ArrayReferenceCopy,
    ArrayAppend,
    ArrayAppendArray,
    ArrayLength,
    ArraySetLength,
    ArrayConcat,
    ArrayIndex,
    ArrayElementPointer,
    ArraySet,
    ArrayEqual,
    ArraySlice,
    StructNew,
    StructGet,
    StructSet,
    ReturnValue,
    ReturnVoid,
);

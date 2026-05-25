module quickbite.ir.instruction;

private:

import std.sumtype: SumType;

// Value-producing IR instructions write to an explicit temporary.
public struct ConstInt {
    import quickbite.executor: Value;

    uint destination;
    Value value;

    public this(in uint destination, in long value) @safe pure {
        this(destination, Value(value));
    }

    public this(in uint destination, in Value value) @safe pure {
        this.destination = destination;
        this.value = value;
    }
}

public struct Call {
    uint destination;
    string calleeName;
    uint[] arguments;
}

public struct IndirectCall {
    uint destination;
    uint callee;
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
    addDouble,
    powDouble,
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
    fabsDouble,
    isInfinityDouble,
    isNaNDouble,
    signbitDouble,
    sqrtDouble,
    floatToUintBits,
    doubleToUlongBits,
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

// Executes the next bodyLength instructions as the protected body and the
// following handlerLength instructions as the catch handler.
public struct TryCatch {
    uint bodyLength;
    uint handlerLength;
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
    char_,
    wchar_,
    dchar_,
}

public struct Assert_ {
    import quickbite.unittest_assertions: AssertionMessageMode;

    uint condition;
    string message;
    bool hasMessageValue;
    uint messageValue;
    AssertionMessageMode messageMode;
    bool hasComparisonContext;
    uint left;
    uint right;
    Operation comparison;

    public this(in uint condition, in string message) @safe pure {
        this.condition = condition;
        this.message = message;
        this.messageMode = AssertionMessageMode.plain;
    }

    public static Assert_ userAssert(
        in uint condition,
        in string message = null,
    ) @safe pure {
        Assert_ assert_;
        assert_.condition = condition;
        assert_.message = message;
        assert_.messageMode = AssertionMessageMode.context;
        return assert_;
    }

    public static Assert_ userComparisonAssert(
        in uint condition,
        in string message,
        in uint left,
        in uint right,
        in Operation comparison,
    ) @safe pure {
        auto assert_ = userAssert(condition, message);
        assert_.hasComparisonContext = true;
        assert_.left = left;
        assert_.right = right;
        assert_.comparison = comparison;
        return assert_;
    }

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

public struct StaticAssocArray {
    uint destination;
    string name;
}

public struct StaticArray {
    uint destination;
    string name;
}

public struct StaticInt {
    uint destination;
    string name;
}

public struct StaticArraySet {
    string name;
    uint value;
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
    uint depth;
}

public struct ArrayCanFind {
    uint destination;
    uint haystack;
    uint needle;
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
    IndirectCall,
    BinaryOp,
    UnaryOp,
    Select,
    JumpIfFalse,
    JumpIfTrue,
    Jump,
    TryCatch,
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
    StaticAssocArray,
    StaticArray,
    StaticInt,
    StaticArraySet,
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
    ArrayCanFind,
    ArraySlice,
    StructNew,
    StructGet,
    StructSet,
    ReturnValue,
    ReturnVoid,
);

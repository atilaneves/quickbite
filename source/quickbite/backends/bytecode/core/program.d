module quickbite.backends.bytecode.core.program;

private:

// The static type of a frame slot or function result. The compiler maps DMD
// types to these tags at emit time; no runtime value carries a tag.
package(quickbite.backends.bytecode) enum ScalarType: ubyte {
    void_,
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
    wchar_,
    dchar_,
    float_,
    double_,
    real_,
}

package(quickbite.backends.bytecode) uint size(in ScalarType type)
    @safe @nogc nothrow pure
{
    final switch (type) with (ScalarType) {
        case void_:
            return 0;
        case bool_, byte_, ubyte_, char_:
            return 1;
        case short_, ushort_, wchar_:
            return 2;
        case int_, uint_, dchar_, float_:
            return 4;
        case long_, ulong_, double_:
            return 8;
        case real_:
            return real.sizeof;
    }
}

// The static type of a function result. Today either a scalar or a string;
// the array slice is the leading edge of the future array subsystem, so its
// own tag rather than overloading ScalarType. A string result is a slice
// descriptor (byte offset and length into Program.data).
package(quickbite.backends.bytecode) struct ResultType {
    ScalarType scalar;
    bool isString;
}

// Bytes of a string-slice descriptor laid out in the frame: a uint offset
// into Program.data followed by a uint length.
package(quickbite.backends.bytecode) enum stringSliceSize = 8;

package(quickbite.backends.bytecode) uint size(in ResultType type)
    @safe @nogc nothrow pure
{
    return type.isString ? stringSliceSize : size(type.scalar);
}

package(quickbite.backends.bytecode) bool isSigned(in ScalarType type)
    @safe @nogc nothrow pure
{
    final switch (type) with (ScalarType) {
        case byte_, short_, int_, long_:
            return true;
        case void_, bool_, ubyte_, ushort_, uint_, ulong_,
            char_, wchar_, dchar_, float_, double_, real_:
            return false;
    }
}

// Fixed-width instruction: an opcode and up to three 16-bit operands (frame
// byte offsets, constant pool indices, function indices).
package(quickbite.backends.bytecode) enum Op: ubyte {
    loadConstant, // a: destination frame offset, b: constant index, c: size
    loadRealConstant, // a: destination frame offset, b: real constant index
    loadStringSlice, // a: destination frame offset, b: data offset, c: length
    copy, // a: destination frame offset, b: source frame offset, c: size
    signExtend1to4, // a: destination frame offset, b: source frame offset
    zeroExtend1to4, // a: destination frame offset, b: source frame offset
    signExtend4to8, // a: destination frame offset, b: source frame offset
    convertDoubleToInt, // a: destination frame offset, b: source (truncates)
    addInt4, // a: destination frame offset, b: lhs, c: rhs
    addInt8, // a: destination frame offset, b: lhs, c: rhs (8-byte integer)
    bitOrInt4, // a: destination frame offset, b: lhs, c: rhs
    divInt4, // a: destination frame offset, b: lhs, c: rhs (signed division)
    notBool, // a: destination (one boolean byte), b: source (inner == 0 ? 1 : 0)
    normaliseBool, // a: destination (one boolean byte), b: source (!= 0 ? 1 : 0)
    lessThan4, // a: destination (one boolean byte), b: lhs, c: rhs (signed <)
    greaterThan4, // a: destination (one boolean byte), b: lhs, c: rhs (signed >)
    lessOrEqual4, // a: destination (one boolean byte), b: lhs, c: rhs (signed <=)
    greaterOrEqual4, // a: destination (one boolean byte), b: lhs, c: rhs (signed >=)
    // a: destination (one boolean byte), b: lhs, c: rhs (unsigned >=)
    greaterOrEqualUnsigned4,
    notEqual4, // a: destination (one boolean byte), b: lhs, c: rhs (4-byte !=)
    equalFloat, // a: destination (one boolean byte), b: lhs, c: rhs
    equalDouble,
    equalReal,
    notEqualFloat,
    notEqualDouble,
    notEqualReal,
    lessThanFloat,
    lessThanDouble,
    lessThanReal,
    greaterThanFloat,
    greaterThanDouble,
    greaterThanReal,
    lessOrEqualFloat,
    lessOrEqualDouble,
    lessOrEqualReal,
    greaterOrEqualFloat,
    greaterOrEqualDouble,
    greaterOrEqualReal,
    addFloat, // a: destination frame offset, b: lhs, c: rhs
    addDouble, // a: destination frame offset, b: lhs, c: rhs
    subFloat, // a: destination frame offset, b: lhs, c: rhs
    subDouble, // a: destination frame offset, b: lhs, c: rhs
    negateFloat, // a: destination frame offset, b: source
    negateDouble, // a: destination frame offset, b: source
    negateReal, // a: destination frame offset, b: source
    fabsFloat, // a: destination frame offset, b: source (std.math.fabs)
    fabsDouble, // a: destination frame offset, b: source (std.math.fabs)
    fabsReal, // a: destination frame offset, b: source (std.math.fabs)
    powFloat, // a: destination frame offset, b: base, c: exponent (std.math.pow)
    powDouble, // a: destination frame offset, b: base, c: exponent
    powDoubleToReal, // a: destination frame offset, b: base, c: exponent
    powReal, // a: destination frame offset, b: base, c: exponent
    sqrtFloat, // a: destination frame offset, b: source (std.math.sqrt)
    sqrtDouble, // a: destination frame offset, b: source (std.math.sqrt)
    sqrtReal, // a: destination frame offset, b: source (std.math.sqrt)
    isNaNFloat, // a: destination bool offset, b: source (std.math.isNaN)
    isNaNDouble, // a: destination bool offset, b: source (std.math.isNaN)
    isNaNReal, // a: destination bool offset, b: source (std.math.isNaN)
    isInfinityFloat, // a: destination bool offset, b: source
    isInfinityDouble, // a: destination bool offset, b: source
    isInfinityReal, // a: destination bool offset, b: source
    signbitFloat, // a: destination int offset, b: source (std.math.signbit)
    signbitDouble, // a: destination int offset, b: source (std.math.signbit)
    signbitReal, // a: destination int offset, b: source (std.math.signbit)
    equal1, // a: destination (one boolean byte), b: lhs, c: rhs
    equal2,
    equal4,
    equal8,
    jump, // a: absolute instruction index
    jumpIfFalse, // a: condition frame offset, b: absolute instruction index
    jumpIfTrue, // a: condition frame offset, b: absolute instruction index
    call, // a: function index, b: argument area frame offset, c: destination
    assertTrue, // a: condition frame offset, b: assert diagnostic index
    // a: condition frame offset, b: assert diagnostic index (verbatim message)
    assertTrueVerbatim,
    assertNonzeroInt4, // a: int frame offset, b: assert diagnostic index
    halt, // unconditional abort throwing the plain "Assertion failure" message
    // unconditional abort throwing the "unittest failure" message, for a
    // literal-false assert lexically inside a unittest body
    haltUnittest,
    throwString, // a: frame offset of a string-slice descriptor
    ret, // a: frame offset of the return value
}

package(quickbite.backends.bytecode) struct Instruction {
    Op op;
    ushort a;
    ushort b;
    ushort c;
}

// A scalar pass-by-reference parameter: its slot in the callee frame holds the
// referenced value, but the matching word in the caller's argument area holds
// the caller-frame offset of the argument. The machine dereferences that
// offset on entry and writes the slot back to it on return.
package(quickbite.backends.bytecode) struct RefParameter {
    ushort offset; // the parameter's frame offset (also its argument-area word)
    ScalarType type; // the referenced scalar's type, giving the value's size
}

package(quickbite.backends.bytecode) struct CompiledFunction {
    Instruction[] code; // empty until the function is (lazily) compiled
    uint frameSize;
    uint parameterBytes;
    ResultType returnType;
    RefParameter[] refParameters; // empty for functions with no ref parameters
}

// How to render a failed assertion: read both operands from the frame and
// format them per their static type around the inverted operator.
package(quickbite.backends.bytecode) struct AssertDiagnostic {
    string operator; // the asserted relation, e.g. "=="
    ushort lhs;
    ushort rhs;
    ScalarType operandType;
}

package(quickbite.backends.bytecode) struct Program {
    CompiledFunction[] functions; // index 0 is the entry function
    ulong[] constants; // raw bits; loadConstant copies the low `c` bytes
    ubyte[real.sizeof][] realConstants; // raw bytes for 16-byte real literals
    ubyte[] data; // read-only segment holding string-literal bytes
    AssertDiagnostic[] assertDiagnostics;
}

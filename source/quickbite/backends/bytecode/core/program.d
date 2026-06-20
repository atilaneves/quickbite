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

// The static type of a function result: a scalar, a string, or a dynamic
// array. A string result is a slice descriptor (byte offset and length into
// Program.data); a dynamic-array result is a 16-byte {ptr, length} descriptor
// (its backing memory stays alive through the machine's `heap` root), with
// `elementType` giving the element scalar.
package(quickbite.backends.bytecode) struct ResultType {
    ScalarType scalar;
    bool isString;
    bool isArray;
    ScalarType elementType;
}

// Bytes of a string-slice descriptor laid out in the frame: a uint offset
// into Program.data followed by a uint length.
package(quickbite.backends.bytecode) enum stringSliceSize = 8;

// Bytes of a dynamic-array slice descriptor laid out in the frame: a native
// `void* ptr` into VM-owned heap memory followed by a `size_t length`, matching
// the x86-64 ABI representation of a `T[]`.
package(quickbite.backends.bytecode) enum sliceDescriptorSize =
    2 * size_t.sizeof;

package(quickbite.backends.bytecode) uint size(in ResultType type)
    @safe @nogc nothrow pure
{
    if (type.isArray)
        return sliceDescriptorSize;
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
    // Copy `c` bytes from the read-only data segment at offset `b` into the
    // inline static-array slot at frame offset `a` (a value-type byte copy).
    loadStaticArray,
    // Allocate `b * c` bytes of VM-owned writable heap, then write the slice
    // descriptor {ptr, length} into the frame: a: descriptor offset, b: element
    // size, c: element count (the length).
    allocArray,
    // Allocate `elementSize * length` bytes of VM-owned writable heap, filled
    // with the element type's default-init byte, where `length` is a size_t read
    // from frame offset c, then write the slice descriptor {ptr, length} into the
    // frame at offset a. Operand b packs the fill byte in its high 8 bits and the
    // element size in its low 8 bits (`(fill << 8) | elementSize`); the fill is
    // 0x00 for most types and 0xFF for `char`. Backs `new T[](runtimeLength)`.
    allocArrayDynamic,
    // Allocate a two-dimensional array `new T[][](rows, cols)`: an outer block of
    // `rows` 16-byte slice descriptors, each pointing at a fresh inner block of
    // `cols` default-filled `T` elements. a: outer descriptor offset; b: packs
    // the inner element's default-init fill byte (high 8 bits) and element size
    // (low 8 bits); c: frame offset of an adjacent {rows, cols} size_t pair. Each
    // inner block is rooted in `heap`. Backs `new T[][](rows, cols)`.
    allocArray2D,
    // Resize the dynamic array whose descriptor is at frame offset a to the
    // size_t length read from frame offset c (`arr.length = n`). Allocate a fresh
    // block, copy the `min(oldLength, newLength)` existing elements, fill any
    // growth with the element's default-init byte, root the block, and overwrite
    // the descriptor with {newPtr, newLength}. Operand b packs the fill byte
    // (high 8 bits) and element size (low 8 bits), like allocArrayDynamic.
    setArrayLength,
    // Write a null slice descriptor {ptr = 0, length = 0} to frame offset a.
    nullSlice,
    // Read the length word of the slice descriptor at frame offset b into the
    // size_t slot at frame offset a.
    sliceLength,
    // Read element `c` (a size_t index in a frame slot) of the slice descriptor
    // at offset b into the 1- or 4-byte element slot at frame offset a, bounds
    // checked against the descriptor length.
    indexLoad1,
    indexLoad4,
    // Read a 16-byte slice-descriptor element (`int[][]`'s element) at size_t
    // index `c` of the outer descriptor at offset b into the descriptor slot at
    // frame offset a, bounds checked against the outer length.
    indexLoad16,
    // Write the 1- or 4-byte element slot at frame offset a into element `c`
    // (a size_t index in a frame slot) of the slice descriptor at offset b,
    // bounds checked against the descriptor length.
    indexStore1,
    indexStore4,
    // Write the 16-byte slice descriptor at frame offset a into element `c` (a
    // size_t index in a frame slot) of the outer descriptor at offset b, bounds
    // checked against the outer length. Backs storing an inner array into an
    // array-of-arrays element.
    indexStore16,
    // Form a sub-slice descriptor sharing the source's backing memory:
    // a: destination descriptor offset, b: source descriptor offset, c: offset
    // of an adjacent {lo, hi} pair of size_t bounds. The new descriptor is
    // {srcPtr + lo * elemSize, hi - lo}; the element size is fixed by the
    // opcode (1 or 4 bytes), matching the indexLoad/indexStore split.
    subSlice1,
    subSlice4,
    // Copy elements from the source slice descriptor at frame offset b into the
    // destination slice descriptor at frame offset a, write-through to the
    // destination's backing memory. The two lengths must match; overlapping
    // backing ranges abort with the plain "Range violation" message. The
    // element size is fixed by the opcode (1 or 4 bytes), matching the
    // indexLoad/indexStore split.
    sliceCopy1,
    sliceCopy4,
    // Compare the two slice descriptors at frame offsets b and c, writing one
    // boolean byte to frame offset a: true iff their lengths and all element
    // bytes are equal. The element size is fixed by the opcode (1 or 4 bytes).
    sliceEqual1,
    sliceEqual4,
    // Append the element at frame offset b to the dynamic-array slice descriptor
    // at frame offset a: allocate a fresh heap block of (length + 1) elements,
    // copy the existing elements, write the new element, root the block, and
    // overwrite the descriptor with {newPtr, length + 1}. Reallocating (rather
    // than growing in place) matches compiled D, so a slice of an array is not
    // corrupted by appending to a neighbour. The element size is fixed by the
    // opcode (1 or 4 bytes), matching the indexLoad/indexStore split.
    appendElement1,
    appendElement4,
    // Concatenate the two slice descriptors at frame offsets b and c into a
    // fresh heap block holding all of b's elements followed by all of c's, then
    // write the descriptor {newPtr, len(b) + len(c)} to frame offset a. The
    // block is rooted in `heap`. Both operands are copied, so the originals are
    // untouched (`a ~ b` makes a NEW array). The element size is fixed by the
    // opcode (1 or 4 bytes), matching the indexLoad/indexStore split.
    concatArrays1,
    concatArrays4,
    // Duplicate the slice descriptor at frame offset b into a fresh heap block
    // holding an independent copy of all its elements, then write the
    // descriptor {newPtr, length} to frame offset a. The block is rooted in
    // `heap`. Mutating either array leaves the other intact (`arr.dup` /
    // `arr.idup`). The element size is fixed by the opcode (1 or 4 bytes).
    dupArray1,
    dupArray4,
    copy, // a: destination frame offset, b: source frame offset, c: size
    signExtend1to4, // a: destination frame offset, b: source frame offset
    zeroExtend1to4, // a: destination frame offset, b: source frame offset
    signExtend4to8, // a: destination frame offset, b: source frame offset
    convertDoubleToInt, // a: destination frame offset, b: source (truncates)
    addInt4, // a: destination frame offset, b: lhs, c: rhs
    addInt8, // a: destination frame offset, b: lhs, c: rhs (8-byte integer)
    subInt4, // a: destination frame offset, b: lhs, c: rhs
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

// A pass-by-reference parameter: its slot in the callee frame holds the
// referenced value (a scalar, or a 16-byte slice descriptor for a `ref T[]`),
// but the matching word in the caller's argument area holds the caller-frame
// offset of the argument. The machine dereferences that offset on entry and
// writes the slot back to it on return.
package(quickbite.backends.bytecode) struct RefParameter {
    ushort offset; // the parameter's frame offset (also its argument-area word)
    uint valueSize; // bytes of the referenced value, copied in and written back
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
    // When set, lhs/rhs are slice-descriptor offsets and operandType is the
    // element type; the operands render as `[e0, e1, ...]`.
    bool isArray;
}

package(quickbite.backends.bytecode) struct Program {
    CompiledFunction[] functions; // index 0 is the entry function
    ulong[] constants; // raw bits; loadConstant copies the low `c` bytes
    ubyte[real.sizeof][] realConstants; // raw bytes for 16-byte real literals
    ubyte[] data; // read-only segment holding string-literal bytes
    AssertDiagnostic[] assertDiagnostics;
}

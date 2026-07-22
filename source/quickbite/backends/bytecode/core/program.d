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

package(quickbite.backends.bytecode) struct StructDisplayField {
    enum Kind: ubyte {
        scalarField,
        nullableWord,
        nullableDelegate,
    }

    uint offset;
    Kind kind;
    ScalarType type;
    string[ulong] enumMembers;
}

// The static type of a function result: a scalar, a string, a dynamic array,
// or a by-value struct. A string result is a slice descriptor (byte offset and
// length into Program.data); a dynamic-array result is a 16-byte {ptr, length}
// descriptor (its backing memory stays alive through the machine's `heap`
// root), with `elementType` giving the element scalar. A struct result is an
// inline block of `structSize` bytes copied back to the caller's destination on
// return (NRVO-style), just like any other frame block.
package(quickbite.backends.bytecode) struct ResultType {
    ScalarType scalar;
    bool isString;
    bool isArray;
    ScalarType elementType;
    bool arrayElementsAreArrays;
    bool isStruct;
    uint structSize;
    bool isUndisplayable;
    bool isStaticArray;
    uint arrayLength;
    bool arrayElementsAreStrings;
    string[ulong] enumMembers;
    string[ulong] elementEnumMembers;
    string structName;
    StructDisplayField[] structFields;
    bool arrayElementsAreStructs;
    uint elementStructSize;
    string elementStructName;
    StructDisplayField[] elementStructFields;

    static ResultType scalarResult(
        in ScalarType scalar,
        string[ulong] enumMembers = null,
    ) @safe pure {
        ResultType result;
        result.scalar = scalar;
        result.enumMembers = enumMembers;
        return result;
    }

    static ResultType scalarArrayResult(
        in ScalarType elementType,
        string[ulong] enumMembers = null,
    ) @safe pure {
        ResultType result;
        result.scalar = ScalarType.void_;
        result.isArray = true;
        result.elementType = elementType;
        result.enumMembers = enumMembers;
        return result;
    }
}

// Bytes of a string-slice descriptor laid out in the frame: a uint offset
// into Program.data followed by a uint length.
package(quickbite.backends.bytecode) enum stringSliceSize = 8;

// Bytes of a dynamic-array slice descriptor laid out in the frame: a native
// `void* ptr` into VM-owned heap memory followed by a `size_t length`. The
// native bridge reverses these fields to D's ABI `{length, ptr}` descriptor.
package(quickbite.backends.bytecode) enum sliceDescriptorSize =
    2 * size_t.sizeof;

// A native (libc) call's argument area is N contiguous slots of this
// stride, one per argument, laid out at
// `argumentArea + index * nativeArgumentSlotSize` regardless of each
// argument's own width, so the marshaller can locate argument `index` without
// knowing the widths of the arguments before it. The stride accommodates the
// widest bridge value, currently a two-word dynamic-array descriptor.
package(quickbite.backends.bytecode) enum nativeArgumentSlotSize =
    sliceDescriptorSize;

// Sentinel for an instruction operand that would otherwise carry an optional
// catch-object frame offset or exception class id.
package(quickbite.backends.bytecode) enum noCatchObjectField = ushort.max;
package(quickbite.backends.bytecode) enum noExceptionClass = ushort.max;

package(quickbite.backends.bytecode) uint size(in ResultType type)
    @safe @nogc nothrow pure
{
    if (type.isStruct)
        return type.structSize;
    if (type.isUndisplayable)
        return 0;
    if (type.isStaticArray)
        return type.structSize;
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
    loadDataPointer, // a: destination frame offset, b: data offset
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
    // Allocate `c` bytes of VM-owned writable heap for a single `new S` struct
    // block, copy the initialised block of `c` bytes from frame offset b into it,
    // root it in `heap`, and write the raw `size_t` heap pointer into the 8-byte
    // frame slot at offset a. Backs `new Struct(...)`; field access through the
    // pointer reads and writes the heap block via pointerLoad/pointerStore.
    allocStruct,
    // Allocate `c` bytes for a `new C` class object, write the class metadata
    // index `b` into its first native word, root it in `heap`, and write the raw
    // object pointer into the frame slot at offset `a`.
    allocClass,
    // Resize the dynamic array whose descriptor is at frame offset a to the
    // size_t length read from frame offset c (`arr.length = n`). Allocate a fresh
    // block, copy the `min(oldLength, newLength)` existing elements, fill any
    // growth with the element's default-init byte, root the block, and overwrite
    // the descriptor with {newPtr, newLength}. Operand b packs the fill byte
    // (high 8 bits) and element size (low 8 bits), like allocArrayDynamic.
    setArrayLength,
    // Resize the dynamic array whose descriptor is at frame offset a using the
    // `d`-byte default-init block at frame offset b for each grown element.
    // The new length is read from frame offset c. Backs `S[].length = n` when
    // `S.init` is not a uniform byte fill.
    setArrayLengthFromTemplate,
    // Write a null slice descriptor {ptr = 0, length = 0} to frame offset a.
    nullSlice,
    // Expand the compact string descriptor {dataOffset, length} at frame offset
    // b into a native dynamic-array descriptor {data.ptr + dataOffset, length}
    // at frame offset a. The backing data remains the immutable program segment.
    stringSliceToArray,
    // Form a sub-slice of a compact string descriptor without ever expanding it
    // to a native pointer: a: destination compact descriptor offset, b: source
    // compact descriptor offset, c: offset of an adjacent {lo, hi} pair of
    // size_t bounds. The new descriptor is {srcDataOffset + lo, hi - lo}, both
    // still uint offsets into the program data segment. Bounds checked against
    // the source length. Keeps a `string` sub-slice in the compact
    // representation every other compact-string consumer (`.ptr`, `.length`,
    // indexing) expects; `stringSliceToArray` above only ever expands a
    // *read*, never a value stored back into another compact `string` slot.
    stringSubSlice,
    // Read the length word of the slice descriptor at frame offset b into the
    // size_t slot at frame offset a.
    sliceLength,
    // Read element `c` (a size_t index in a frame slot) of the slice descriptor
    // at offset b into the element slot at frame offset a, bounds checked
    // against the descriptor length. The element size is fixed by the opcode.
    indexLoad1,
    indexLoad2,
    indexLoad4,
    indexLoad8,
    // Read a 16-byte slice-descriptor element (`int[][]`'s element) at size_t
    // index `c` of the outer descriptor at offset b into the descriptor slot at
    // frame offset a, bounds checked against the outer length.
    indexLoad16,
    // Write the element slot at frame offset a into element `c` (a size_t index
    // in a frame slot) of the slice descriptor at offset b, bounds checked
    // against the descriptor length. The element size is fixed by the opcode.
    indexStore1,
    indexStore2,
    indexStore4,
    indexStore8,
    // Write the 16-byte slice descriptor at frame offset a into element `c` (a
    // size_t index in a frame slot) of the outer descriptor at offset b, bounds
    // checked against the outer length. Backs storing an inner array into an
    // array-of-arrays element.
    indexStore16,
    // Check that the size_t index at frame offset a is less than the size_t
    // length at frame offset b, raising `indexLoad`/`indexStore`'s exact
    // "index [n] is out of bounds for array of length N" diagnostic
    // otherwise. Backs bounds checking for a static-array element pointer,
    // which unlike a slice descriptor carries no length word of its own.
    checkStaticArrayIndex,
    // Form a sub-slice descriptor sharing the source's backing memory:
    // a: destination descriptor offset, b: source descriptor offset, c: offset
    // of an adjacent {lo, hi} pair of size_t bounds. The new descriptor is
    // {srcPtr + lo * elemSize, hi - lo}; the element size is fixed by the
    // opcode, matching the indexLoad/indexStore split.
    subSlice1,
    subSlice2,
    subSlice4,
    subSlice8,
    subSlice16,
    // Copy elements from the source slice descriptor at frame offset b into the
    // destination slice descriptor at frame offset a, write-through to the
    // destination's backing memory. The two lengths must match; overlapping
    // backing ranges abort with the plain "Range violation" message. The
    // element size is fixed by the opcode (1 or 4 bytes), matching the
    // indexLoad/indexStore split.
    sliceCopy1,
    sliceCopy4,
    // Fill every 4-byte element of the destination slice descriptor at frame
    // offset a with the scalar value at frame offset b.
    sliceFill4,
    // Compare the two slice descriptors at frame offsets b and c, writing one
    // boolean byte to frame offset a: true iff their lengths and all element
    // bytes are equal. The element size is fixed by the opcode (1 or 4 bytes).
    sliceEqual1,
    sliceEqual4,
    // Compare the two 8-byte string-slice descriptors {dataOffset, length} at
    // frame offsets b and c against the read-only data segment, writing one
    // boolean byte to frame offset a: true iff equal length and identical
    // bytes. Distinct from sliceEqual* because a string descriptor holds a
    // data-segment offset, not a native pointer.
    stringSliceEqual,
    // Append the element at frame offset b to the dynamic-array slice descriptor
    // at frame offset a: allocate a fresh heap block of (length + 1) elements,
    // copy the existing elements, write the new element, root the block, and
    // overwrite the descriptor with {newPtr, length + 1}. Reallocating (rather
    // than growing in place) matches compiled D, so a slice of an array is not
    // corrupted by appending to a neighbour. The element size is fixed by the
    // opcode (1 or 4 bytes), matching the indexLoad/indexStore split.
    appendElement1,
    appendElement2, // 2-byte element (wchar): backs `wchar[] ~= w`
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
    dupArray2, // 2-byte element (wchar): backs `wstring s = wcharArray.idup`
    dupArray4,
    // Element-wise `dest[] = left[] + right[]` over three slice descriptors at
    // frame offsets a (dest), b (left), c (right): add each pair of 4-byte
    // integer elements and write the sum through the destination's backing
    // memory. All three lengths must match. Backs the druntime arrayOp ["+","="]
    // lowering.
    arrayAddAssign4,
    // Read the element at `[pointer + index * elementSize]` into the 1- or
    // 4-byte slot at frame offset a, where the raw `size_t` pointer value is at
    // frame offset b and the `size_t` index at frame offset c. Backs `*p` (index
    // 0) and `p[i]` through a pointer into VM-owned heap memory; unchecked, like
    // compiled D. The element size is fixed by the opcode (1 or 4 bytes).
    pointerLoad1,
    pointerLoad2,
    pointerLoad4,
    pointerLoad8,
    pointerLoad16,
    // Atomically read the 8-byte element at `[pointer + index * 8]` into the
    // slot at frame offset a. The atomic-load inline-asm lowering uses this
    // only after exact whole-sequence validation.
    atomicLoad8,
    // Write the 1- or 4-byte slot at frame offset a to `[pointer + index *
    // elementSize]`, where the raw `size_t` pointer value is at frame offset b
    // and the `size_t` index at frame offset c. Backs `*p = v` (index 0) and
    // `p[i] = v` through a pointer into VM-owned memory; unchecked, like compiled
    // D. The element size is fixed by the opcode (1 or 4 bytes).
    pointerStore1,
    pointerStore4,
    pointerStore8,
    pointerStore16,
    // Form a slice descriptor {pointer + lo * elementSize, hi - lo} at frame
    // offset a from the raw `size_t` pointer value at frame offset b and an
    // adjacent {lo, hi} pair of `size_t` bounds at frame offset c. Backs
    // `p[lo .. hi]`; unchecked against the original block, like compiled D. The
    // element size is fixed by the opcode (1 or 4 bytes).
    pointerSlice1,
    pointerSlice2,
    pointerSlice4,
    pointerSlice8,
    // a: destination (one boolean byte), b: lhs, c: rhs (unsigned 8-byte
    // comparison). Back raw pointer-value relations `p < q`, `p <= q`, `p > q`,
    // `p >= q`, which compare as `size_t`.
    lessThanUnsigned8,
    lessOrEqualUnsigned8,
    greaterThanUnsigned8,
    greaterOrEqualUnsigned8,
    copy, // a: destination frame offset, b: source frame offset, c: size
    // Copy `c` bytes from the mutable module-data segment at offset b into
    // frame offset a. Backs reads of scalar and default-null class references.
    loadModule,
    // Copy `c` bytes from frame offset a into the mutable module-data segment
    // at offset b. Backs writes to scalar and default-null class references.
    storeModule,
    // Write the native address of mutable module-data offset b as a raw `size_t`
    // word into frame offset a. Backs `&moduleScalar`.
    moduleAddress,
    // Write the absolute stack index of the current frame's base (`base`) as a
    // raw `size_t` word into frame offset a. Backs a nested struct's hidden
    // context pointer (`vthis`), which records the enclosing function's frame so
    // the struct's methods can read captured enclosing locals. A stable index
    // (not a native address) survives the stack array's reallocation on growth.
    frameBaseIndex,
    // Read `c` bytes from the absolute stack index held in the size_t slot at
    // frame offset b into frame offset a. Backs a captured enclosing local read
    // through a nested struct's context: `stack[contextBase + var.offset]`, with
    // the base+offset already summed into the slot at b.
    frameLoad,
    // Write `c` bytes from frame offset a to the absolute stack index held in
    // the size_t slot at frame offset b. Backs writes to captured enclosing
    // locals through the same context index used by frameLoad.
    frameStore,
    // Write the native address of the current frame slot at offset b as a raw
    // `size_t` pointer word into frame offset a. Backs `&local` (`int* p = &x`):
    // the stack's reserved capacity keeps the address stable across the calls
    // that grow the stack before the pointer is dereferenced.
    frameAddress,
    // Write the native address of the absolute stack index held in frame slot b
    // into frame slot a. Backs `.ptr` of a captured static array.
    frameIndexAddress,
    signExtend1to4, // a: destination frame offset, b: source frame offset
    zeroExtend1to4, // a: destination frame offset, b: source frame offset
    signExtend2to4, // a: destination frame offset, b: source frame offset
    zeroExtend2to4, // a: destination frame offset, b: source (wchar -> dchar)
    signExtend4to8, // a: destination frame offset, b: source frame offset
    zeroExtend4to8, // a: destination frame offset, b: source frame offset
    convertDoubleToInt, // a: destination frame offset, b: source (truncates)
    // a: destination (float) frame offset, b: source frame offset, c: source
    // integer size in bytes (1/2/4/8) OR'd with `unsignedConvertFlag` for an
    // unsigned source. Numerically widens an integer to a float.
    convertIntToFloat,
    // a: destination (double) frame offset, b: source frame offset, c: source
    // integer size in bytes (1/2/4/8) OR'd with `unsignedConvertFlag` for an
    // unsigned source. Numerically widens an integer to a double. Backs
    // `cast(double)intExpr` (e.g. `double d = seed;`).
    convertIntToDouble,
    // a: destination (real) frame offset, b: source frame offset, c: source
    // integer size in bytes (1/2/4/8) OR'd with `unsignedConvertFlag` for an
    // unsigned source. Numerically widens an integer to a real.
    convertIntToReal,
    convertFloatToDouble, // a: destination frame offset, b: source frame offset
    convertFloatToReal, // a: destination frame offset, b: source frame offset
    convertDoubleToReal, // a: destination frame offset, b: source frame offset
    addInt4, // a: destination frame offset, b: lhs, c: rhs
    addInt8, // a: destination frame offset, b: lhs, c: rhs (8-byte integer)
    subInt8, // a: destination frame offset, b: lhs, c: rhs (8-byte integer)
    mulInt4, // a: destination frame offset, b: lhs, c: rhs (4-byte integer)
    mulInt8, // a: destination frame offset, b: lhs, c: rhs (8-byte integer)
    // a: product followed by carry, b: lhs, c: rhs (unsigned integer)
    mulUnsignedInt4WithCarry,
    mulUnsignedInt8WithCarry,
    divInt8, // a: destination frame offset, b: lhs, c: rhs (signed 8-byte div)
    divUnsignedInt8, // a: destination, b: lhs, c: rhs (unsigned 8-byte div)
    modUnsignedInt8, // a: destination, b: lhs, c: rhs (unsigned 8-byte mod)
    modInt8, // a: destination, b: lhs, c: rhs (signed 8-byte mod)
    subInt4, // a: destination frame offset, b: lhs, c: rhs
    bitOrInt4, // a: destination frame offset, b: lhs, c: rhs
    bitOrInt8, // a: destination frame offset, b: lhs, c: rhs
    divInt4, // a: destination frame offset, b: lhs, c: rhs (signed division)
    modInt4, // a: destination frame offset, b: lhs, c: rhs (signed remainder)
    divUnsignedInt4, // a: destination, b: lhs, c: rhs (unsigned 4-byte div)
    modUnsignedInt4, // a: destination, b: lhs, c: rhs (unsigned 4-byte mod)
    shlInt4, // a: destination frame offset, b: lhs, c: rhs
    shrInt4, // a: destination frame offset, b: lhs, c: rhs (signed shift)
    ushrInt4, // a: destination frame offset, b: lhs, c: rhs (zero-fill shift)
    shlInt8, // a: destination frame offset, b: lhs, c: rhs (8-byte integer)
    shrInt8, // a: destination frame offset, b: lhs, c: rhs (signed shift)
    ushrInt8, // a: destination frame offset, b: lhs, c: rhs (zero-fill shift)
    bitAndInt4, // a: destination frame offset, b: lhs, c: rhs
    bitAndInt8, // a: destination frame offset, b: lhs, c: rhs
    bitXorInt4, // a: destination frame offset, b: lhs, c: rhs
    bitNotInt4, // a: destination frame offset, b: source
    notBool, // a: destination (one boolean byte), b: source (inner == 0 ? 1 : 0)
    normaliseBool, // a: destination (one boolean byte), b: source (!= 0 ? 1 : 0)
    lessThan4, // a: destination (one boolean byte), b: lhs, c: rhs (signed <)
    greaterThan4, // a: destination (one boolean byte), b: lhs, c: rhs (signed >)
    lessOrEqual4, // a: destination (one boolean byte), b: lhs, c: rhs (signed <=)
    greaterOrEqual4, // a: destination (one boolean byte), b: lhs, c: rhs (signed >=)
    // a: destination (one boolean byte), b: lhs, c: rhs (unsigned <)
    lessThanUnsigned4,
    // a: destination (one boolean byte), b: lhs, c: rhs (unsigned <=)
    lessOrEqualUnsigned4,
    // a: destination (one boolean byte), b: lhs, c: rhs (unsigned >)
    greaterThanUnsigned4,
    // a: destination (one boolean byte), b: lhs, c: rhs (unsigned >=)
    greaterOrEqualUnsigned4,
    lessThan8, // a: destination (one boolean byte), b: lhs, c: rhs (signed <)
    greaterThan8, // a: destination (one boolean byte), b: lhs, c: rhs (signed >)
    lessOrEqual8, // a: destination (one boolean byte), b: lhs, c: rhs (signed <=)
    greaterOrEqual8, // a: destination (one boolean byte), b: lhs, c: rhs (signed >=)
    notEqual4, // a: destination (one boolean byte), b: lhs, c: rhs (4-byte !=)
    notEqual8, // a: destination (one boolean byte), b: lhs, c: rhs (8-byte !=)
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
    divDouble, // a: destination frame offset, b: lhs, c: rhs
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
    // a: frame offset of a size_t slot holding the callee's function index,
    // b: argument area frame offset, c: destination. Backs an indirect call
    // through a function pointer (`fp()`), where the callee is not known until
    // run time; otherwise identical to `call`.
    callIndirect,
    // a: destination size_t slot, b: class-object pointer slot, c: statically
    // selected function index. Looks up the object's dynamic class and writes
    // the overriding function index, or c when no override is registered.
    classVirtualFunction,
    // a: class-object pointer slot, b: diagnostic data offset, c: data length.
    throwIfNullClassReference,
    nativeCall, // a: native-call index, b: argument area, c: destination
    assertTrue, // a: condition frame offset, b: assert diagnostic index
    // a: condition frame offset, b: assert diagnostic index (verbatim message)
    assertTrueVerbatim,
    assertNonzeroInt4, // a: integer frame offset, b: assert diagnostic index
    halt, // unconditional abort throwing the plain "Assertion failure" message
    // unconditional abort throwing the "unittest failure" message, for a
    // literal-false assert lexically inside a unittest body
    haltUnittest,
    // Associative-array hooks operating on VM-owned maps. A `T[K]` local's
    // 8-byte slot holds a `size_t` handle: a 1-based index into the machine's
    // map table, or 0 for a not-yet-created (empty) map. The current map table
    // stores int keys and int-sized values; wider `aaValues` elements are
    // zero-extended when materialised for narrow struct-handle cases.
    aaNew, // a: handle slot; create a fresh empty map and write its handle
    aaLength, // a: size_t result, b: handle slot; entry count (0 if handle 0)
    // a: handle slot, b: key slot, c: value slot; insert/overwrite. Creates the
    // map on first insert into an empty (handle-0) local, writing the handle back.
    aaInsert,
    // a: size_t pointer result, b: handle slot, c: key slot; the address of the
    // value for the key (into VM-owned memory) or 0 when the key is absent. Both
    // the `m[k]` rvalue read and `k in m` lower to this: DMD's `m[k]` lowering
    // wraps it in a null check that raises "Range violation" on a missing key.
    aaGetRvalue,
    aaIn,
    // a: bool result, b: handle slot, c: key slot; remove the key, result true
    // iff it was present.
    aaRemove,
    // a: bool result, b: handle slot, c: handle slot; entry-set equality.
    aaEqual,
    aaDup, // a: handle slot result, b: handle slot; an independent copy
    // a: 16-byte slice-descriptor result, b: handle slot, c: element byte size;
    // a fresh heap block holding a copy of the map's keys / values.
    aaKeys,
    aaValues,
    // a: frame offset of a string-slice descriptor, b: thrown exception-class
    // id (`noExceptionClass` for non-D `Throwable` diagnostics).
    throwString,
    // Throw the class-reference pointer held in frame offset `a`. With an active
    // handler, redirect to it and bind the pointer into the catch slot recorded
    // by `pushHandler`; with none, raise the object's `msg` field when known.
    throwObject,
    // UTF transcode backing `foreach`/`foreach_reverse` over a string whose
    // element width differs from the loop variable (druntime's `_aApply*`
    // family). a: 16-byte slice-descriptor result holding the decoded elements
    // in a fresh heap block; b: the transcode mode (see `TranscodeMode`);
    // c: 16-byte source slice descriptor of the string's code units. Mirrors the
    // interpreter's decode/encode helpers byte-for-byte.
    transcodeUtf,
    // Push a catch-handler group onto the machine's handler stack: a: first
    // `Program.catchClauses` index, b: catch-clause count. A later throw
    // selects the first matching catch in the innermost matching group (popping
    // the whole group) instead of propagating as a host exception.
    pushHandler,
    // Pop the innermost catch-handler group on normal completion of a try body.
    popHandler,
    ret, // a: frame offset of the return value
}

// `transcodeUtf` modes (operand `b`): the source/target code-unit transcode a
// mismatched-width string `foreach` performs, named after druntime's helpers.
package(quickbite.backends.bytecode) enum TranscodeMode: ushort {
    utf8ToDchar, // `_aApplycd1`: char source decoded to dchar elements
    utf16ToDchar, // `_aApplywd1`: wchar source decoded to dchar (surrogate pairs)
    dcharToUtf8, // `_aApplydc1`: dchar source encoded to char (UTF-8) elements
    utf16ToDcharReverse, // `_aApplyRwd1`: wchar source decoded to dchar, reversed
}

// OR'd into a `convertIntToDouble` instruction's `c` (the source byte width) to
// mark the source integer as unsigned (zero-extended, not sign-extended). Width
// is at most 8, so bit 8 is free for the flag.
package(quickbite.backends.bytecode) enum unsignedConvertFlag = 0x100;

package(quickbite.backends.bytecode) struct Instruction {
    Op op;
    ushort a;
    ushort b;
    ushort c;
    ushort d;
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

package(quickbite.backends.bytecode) struct NativeCall {
    imported!"dmd.func".FuncDeclaration function_;
    imported!"dmd.mtype".Type[] argumentTypes;
    // Per-argument frame offset of the pointed-to local for an out-parameter
    // argument (e.g. strtod's `&endptr`); `noOutParameterOffset` marks an
    // argument that is not one.
    ushort[] outParameterOffsets;
}

// Sentinel `NativeCall.outParameterOffsets` entry for an argument that is not
// an out parameter.
package(quickbite.backends.bytecode) enum noOutParameterOffset = ushort.max;

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
    bool isString;
    bool lhsIsNull;
    bool rhsIsNull;
}

package(quickbite.backends.bytecode) struct VirtualFunction {
    ushort baseFunction;
    ushort function_;
}

package(quickbite.backends.bytecode) struct ClassInfo {
    ushort baseClass = noExceptionClass;
    ushort msgOffset = ushort.max;
    VirtualFunction[] virtualFunctions;
}

package(quickbite.backends.bytecode) struct CatchClause {
    ushort catchClass = noExceptionClass;
    ushort objectOffset = noCatchObjectField;
    ushort messageOffset = noCatchObjectField;
    ushort nextMessageOffset = noCatchObjectField;
    ushort handlerIp;
}

package(quickbite.backends.bytecode) struct Program {
    CompiledFunction[] functions; // index 0 is the entry function
    ulong[] constants; // raw bits; loadConstant copies the low `c` bytes
    ubyte[real.sizeof][] realConstants; // raw bytes for 16-byte real literals
    ubyte[] data; // read-only segment holding string-literal bytes
    ubyte[] moduleData; // mutable VM-owned storage for module-level variables
    AssertDiagnostic[] assertDiagnostics;
    NativeCall[] nativeCalls;
    ClassInfo[] classes;
    ushort rangeErrorClass = noExceptionClass;
    CatchClause[] catchClauses;
}

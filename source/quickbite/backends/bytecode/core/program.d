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

// The static type of a function result: a scalar, a dynamic array (`string`
// included, its basetype is also `Tarray`), or a by-value struct. A
// dynamic-array result is a 16-byte {length, ptr} descriptor — for a
// literal-initialised `string`, pointing into the immutable program data
// segment; otherwise into the machine's `heap` root, which keeps its backing
// memory alive — with `elementType` giving the element scalar. A struct
// result is an inline block of `structSize` bytes copied back to the
// caller's destination on return (NRVO-style), just like any other frame
// block.
package(quickbite.backends.bytecode) struct ResultType {
    ScalarType scalar;
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
    // A delegate result is a 16-byte `{functionIndex, context}` pair, real
    // data the caller must receive -- unlike `isUndisplayable`, which only
    // means the REPL cannot render it. `size()` below must check this before
    // `isUndisplayable`.
    bool isDelegate;

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

// Bytes of a dynamic-array slice descriptor laid out in the frame: a
// `size_t length` followed by a native `void* ptr` into VM-owned heap
// memory, the same order compiled D lays a slice out in, so the native
// bridge hands a descriptor across unchanged.
package(quickbite.backends.bytecode) enum sliceDescriptorSize =
    2 * size_t.sizeof;

// Byte offset of a slice descriptor's `ptr` field relative to the
// descriptor's own base offset `base` (a frame slot, module-data offset, or
// a descriptor-sized buffer's start) — the one place the `{length, ptr}`
// layout `sliceDescriptorSize` documents is expressed as field offsets, so
// compiler.d, machine.d, and reify.d compute them the same way instead of
// re-deriving `base` / `base + size_t.sizeof` inline. Pairs with
// `sliceDescriptorLengthOffset`.
package(quickbite.backends.bytecode) size_t sliceDescriptorPtrOffset(
    in size_t base,
) @safe @nogc nothrow pure {
    return base + size_t.sizeof;
}

// Byte offset of a slice descriptor's `length` field relative to the
// descriptor's base offset `base`. See `sliceDescriptorPtrOffset`.
package(quickbite.backends.bytecode) size_t sliceDescriptorLengthOffset(
    in size_t base,
) @safe @nogc nothrow pure {
    return base;
}

// A native (libc) call's argument area is N contiguous slots of this
// stride, one per argument, laid out at
// `argumentArea + index * nativeArgumentSlotSize` regardless of each
// argument's own width, so `native_call.d` can locate argument `index`
// without knowing the widths of the arguments before it. The stride
// accommodates the widest bridge value, currently a two-word dynamic-array
// descriptor.
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
    if (type.isDelegate)
        return sliceDescriptorSize; // {functionIndex, context}, same width
    if (type.isUndisplayable)
        return 0;
    if (type.isStaticArray)
        return type.structSize;
    if (type.isArray)
        return sliceDescriptorSize;
    return size(type.scalar);
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
    // a: destination frame offset, b: `literalBlocks` index. Writes the raw
    // native address of `literalBlocks[b].ptr` — a block that never moves —
    // into the frame; unlike `data`, an append-growable array, a fresh
    // per-literal block keeps this pointer valid even after later literals
    // are compiled.
    loadDataPointer,
    // Copy `c` bytes from the read-only data segment at offset `b` into the
    // inline static-array slot at frame offset `a` (a value-type byte copy).
    loadStaticArray,
    // Allocate `b * c` bytes of VM-owned writable heap, then write the slice
    // descriptor {length, ptr} into the frame: a: descriptor offset, b: element
    // size, c: element count (the length).
    allocArray,
    // Allocate `elementSize * length` bytes of VM-owned writable heap, filled
    // with the element type's default-init byte, where `length` is a size_t read
    // from frame offset c, then write the slice descriptor {length, ptr} into the
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
    // Write a null slice descriptor {length = 0, ptr = 0} to frame offset a.
    nullSlice,
    // Write a native dynamic-array descriptor {c, literalBlocks[b].ptr}
    // directly into frame offset a, from a literal's `literalBlocks` index
    // (b) and length in elements (c). Every `string` value — literal or not
    // — is an ordinary 16-byte {length, ptr} descriptor identical to any
    // other `T[]`; this is simply the literal-load opcode for that shape. The
    // pointer is `literalBlocks[b].ptr`, not `data.ptr + b`: `data` is one
    // append-growable array that reallocates (and moves) as later literals
    // are compiled, but each `literalBlocks` entry is its own block that
    // never moves once allocated, so a descriptor materialised from it stays
    // valid across any later lazy compilation.
    loadStringLiteral,
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
    // Same as `indexLoad1`/etc, for an element width not covered by a fixed
    // opcode (e.g. a struct element wider than 16 bytes): the byte width is
    // operand d instead of being implied by the opcode.
    indexLoadN,
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
    // Same as `indexStore1`/etc, for an element width not covered by a fixed
    // opcode (e.g. a struct element wider than 16 bytes): the byte width is
    // operand d instead of being implied by the opcode.
    indexStoreN,
    // Check that the size_t index at frame offset a is less than the size_t
    // length at frame offset b, raising `indexLoad`/`indexStore`'s exact
    // "index [n] is out of bounds for array of length N" diagnostic
    // otherwise. Backs bounds checking for a static-array element pointer,
    // which unlike a slice descriptor carries no length word of its own.
    checkStaticArrayIndex,
    // Form a sub-slice descriptor sharing the source's backing memory:
    // a: destination descriptor offset, b: source descriptor offset, c: offset
    // of an adjacent {lo, hi} pair of size_t bounds. The new descriptor is
    // {hi - lo, srcPtr + lo * elemSize}; the element size is fixed by the
    // opcode, matching the indexLoad/indexStore split.
    subSlice1,
    subSlice2,
    subSlice4,
    subSlice8,
    subSlice16,
    // Same as `subSlice1`/etc, for an element width not covered by a fixed
    // opcode (e.g. a struct element wider than 16 bytes): the byte width is
    // operand d instead of being implied by the opcode.
    subSliceN,
    // Copy elements from the source slice descriptor at frame offset b into the
    // destination slice descriptor at frame offset a, write-through to the
    // destination's backing memory. The two lengths must match; overlapping
    // backing ranges abort with the plain "Range violation" message. The
    // element size is fixed by the opcode (1, 2, 4, 8, or 16 bytes), matching
    // the indexLoad/indexStore split; 16 bytes is a whole slice-descriptor
    // element, e.g. a `T[][]` row.
    sliceCopy1,
    sliceCopy2,
    sliceCopy4,
    sliceCopy8,
    sliceCopy16,
    // Same as `sliceCopy1`/etc, for an element width not covered by a fixed
    // opcode: the byte width is operand c instead of being implied by the
    // opcode.
    sliceCopyN,
    // Fill every element of the destination slice descriptor at frame offset
    // a with the scalar value at frame offset b. The element size is fixed by
    // the opcode (1, 2, 4, or 8 bytes).
    sliceFill1,
    sliceFill2,
    sliceFill4,
    sliceFill8,
    // Same as `sliceFill1`/etc, for an element width not covered by a fixed
    // opcode (e.g. a struct/static-array element broadcast across the
    // range): the byte width is operand c instead of being implied by the
    // opcode, and the source at frame offset b is that many bytes wide
    // rather than a narrow scalar.
    sliceFillN,
    // Compare the two slice descriptors at frame offsets b and c, writing one
    // boolean byte to frame offset a: true iff their lengths and all element
    // bytes are equal. The element size is fixed by the opcode (1, 2, 4, or 8
    // bytes).
    sliceEqual1,
    sliceEqual2, // 2-byte element (wchar/short): backs `wstring == wstring`
    sliceEqual4,
    sliceEqual8, // 8-byte element (long/double/pointer arrays)
    // Numeric element equality for descriptors whose physical element types
    // differ. Operands d/e are the left/right ScalarType values; the machine
    // applies D's integer promotions instead of comparing mismatched bytes.
    sliceEqualNumeric,
    // Structural comparison for an array-of-arrays, any nesting depth
    // (`int[][] == int[][]`, `int[][][] == int[][][]`, ...): the descriptors
    // at frame offsets b and c hold rows that are themselves 16-byte slice
    // descriptors (and, below that, rows of rows, down to `depth` levels), so
    // a raw `sliceEqual*` over the outer descriptor would compare each row's
    // `.ptr` rather than its content. Compare outer lengths, then compare
    // every row's own length, recursing one level deeper per row until
    // `depth` levels of descriptors have been unwrapped, then compare the
    // innermost row's element bytes. Operand d is the nesting depth (2 for
    // `int[][]`, 3 for `int[][][]`, ...); operand e is the innermost (leaf)
    // element byte width (not 16).
    sliceEqualNested,
    // Concatenate the two slice descriptors at frame offsets b and c into a
    // fresh heap block holding all of b's elements followed by all of c's, then
    // write the descriptor {len(b) + len(c), newPtr} to frame offset a. The
    // block is rooted in `heap`. Both operands are copied, so the originals are
    // untouched (`a ~ b` makes a NEW array). The element size is fixed by the
    // opcode (1, 4, or 16 bytes), matching the indexLoad/indexStore split.
    concatArrays1,
    concatArrays4,
    concatArrays16, // 16-byte descriptor element: concatenating two arrays
                     // whose element is itself an array (`int[][]`/
                     // `int[N][]`), where each row is its own heap-backed
                     // sub-array addressed by a stored descriptor
    // Same as `concatArrays1`/etc, for an element width not covered by a
    // fixed opcode (e.g. a struct element wider than 16 bytes): the byte
    // width is operand d instead of being implied by the opcode.
    concatArraysN,

    // Duplicate the slice descriptor at frame offset b into a fresh heap block
    // holding an independent copy of all its elements, then write the
    // descriptor {length, newPtr} to frame offset a. The block is rooted in
    // `heap`. Mutating either array leaves the other intact (`arr.dup` /
    // `arr.idup`). The element size is fixed by the opcode (1, 2, 4, 8, or 16
    // bytes), matching the indexLoad/indexStore split; 16 bytes is a whole
    // slice-descriptor element, e.g. a `T[][]` row (`.dup` is shallow, so
    // copying the outer descriptors as opaque 16-byte blocks is correct).
    dupArray1,
    dupArray2, // 2-byte element (wchar): backs `wstring s = wcharArray.idup`
    dupArray4,
    dupArray8, // 8-byte element: long/double/pointer arrays
    dupArray16,
    // Same as `dupArray1`/etc, for an element width not covered by a fixed
    // opcode (e.g. a struct element wider than 16 bytes): the byte width is
    // operand c instead of being implied by the opcode.
    dupArrayN,
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
    // Same as `pointerLoad1`/etc, for an element width not covered by a
    // fixed opcode (e.g. a struct element wider than 16 bytes): the byte
    // width is operand d instead of being implied by the opcode. Backs `*p`
    // and `p[i]` for such a pointee.
    pointerLoadN,
    // Atomically read the 4- or 8-byte element at `[pointer + index * size]`
    // into the slot at frame offset a. The atomic-load inline-asm lowering
    // uses these only after exact whole-sequence validation.
    atomicLoad4,
    atomicLoad8,
    // Atomically exchange the 4-byte value at the pointer in slot b with the
    // 4-byte value in slot c, writing the previous value to slot a. The
    // exact `lock; xchg` inline-asm lowering uses this after validation.
    atomicExchange4,
    // Atomically add the 4-byte value in slot c to the word at the pointer in
    // slot b, writing the pre-addition value to slot a. The exact `lock;
    // xadd` inline-asm lowering uses this after validation.
    atomicFetchAdd4,
    // 8-byte counterpart of `atomicFetchAdd4`.
    atomicFetchAdd8,
    // Write the 1- or 4-byte slot at frame offset a to `[pointer + index *
    // elementSize]`, where the raw `size_t` pointer value is at frame offset b
    // and the `size_t` index at frame offset c. Backs `*p = v` (index 0) and
    // `p[i] = v` through a pointer into VM-owned memory; unchecked, like compiled
    // D. The element size is fixed by the opcode (1 or 4 bytes).
    pointerStore1,
    pointerStore2,
    pointerStore4,
    pointerStore8,
    pointerStore16,
    // Same as `pointerStore1`/etc, for an element width not covered by a
    // fixed opcode (e.g. a struct element wider than 16 bytes): the byte
    // width is operand d instead of being implied by the opcode. Backs `*p
    // = v` and `p[i] = v` for such a pointee.
    pointerStoreN,
    // Write `[pointer + index * elementSize]` as a raw native address into
    // frame offset a. The pointer value lives at b, the size_t index at c,
    // and d is the element byte width. This is the address primitive shared
    // by pointer- and slice-backed compiler places.
    pointerAddress,
    // Form a slice descriptor {hi - lo, pointer + lo * elementSize} at frame
    // offset a from the raw `size_t` pointer value at frame offset b and an
    // adjacent {lo, hi} pair of `size_t` bounds at frame offset c. Backs
    // `p[lo .. hi]`; unchecked against the original block, like compiled D. The
    // element size is fixed by the opcode (1, 2, 4, 8, or 16 bytes).
    pointerSlice1,
    pointerSlice2,
    pointerSlice4,
    pointerSlice8,
    pointerSlice16,
    // Same as `pointerSlice1`/etc, for an element width not covered by a fixed
    // opcode (e.g. a struct element wider than 16 bytes): the byte width is
    // operand d instead of being implied by the opcode.
    pointerSliceN,
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
    signExtend1to2, // a: destination frame offset, b: source frame offset
    zeroExtend1to2, // a: destination frame offset, b: source frame offset
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
    bitXorInt8, // a: destination frame offset, b: lhs, c: rhs
    bitNotInt4, // a: destination frame offset, b: source
    bitNotInt8, // a: destination frame offset, b: source
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
    // through a function pointer (`fp()`) or a delegate-typed value
    // (a local, a PARAMETER, or `d()` on a delegate local), where the callee
    // is not known until run time; otherwise identical to `call`. A
    // struct-receiver callee's whole receiver block travels as the pair's
    // pointer-width context word, matching every other delegate shape.
    callIndirect,
    // a: destination size_t slot, b: class-object pointer slot, c: statically
    // selected function index. Looks up the object's dynamic class and writes
    // the overriding function index, or c when no override is registered.
    classVirtualFunction,
    // a: destination size_t slot, b: class-object pointer slot. Reads the
    // object's dynamic VM class and writes its host TypeInfo mirror.
    classTypeInfo,
    // a: destination string descriptor, b: class-object pointer slot. Reads
    // the object's dynamic VM class and writes its fully qualified D name.
    className,
    // a: class-object pointer slot, b: diagnostic data offset, c: data length.
    throwIfNullClassReference,
    nativeCall, // a: native-call index, b: argument area, c: destination
    halt, // unconditional abort throwing the plain "Assertion failure" message
    // unconditional abort throwing the "unittest failure" message, for a
    // literal-false assert lexically inside a unittest body
    haltUnittest,
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

// The `indexLoad`/`indexStore` family's one op<->width table: each fixed
// width the pair supports, alongside the load and store opcode for that
// width, declared once. compiler.d's `indexLoadOp`/`indexStoreOp`
// width->opcode selectors and machine.d's element-width Op->width derivation
// both walk this same table (`indexLoadOp`/`indexStoreOp`/`indexElementWidth`
// below), so the two directions cannot independently drift out of sync the
// way two hand-written switches could. `indexLoad16`/`indexStore16`'s width
// is `sliceDescriptorSize`, not a bare `16` literal, since that is what they
// actually move (an inner array-of-arrays element).
private struct IndexOpWidth {
    uint width;
    Op loadOp;
    Op storeOp;
}

private immutable IndexOpWidth[] indexOpWidths = [
    IndexOpWidth(1, Op.indexLoad1, Op.indexStore1),
    IndexOpWidth(2, Op.indexLoad2, Op.indexStore2),
    IndexOpWidth(4, Op.indexLoad4, Op.indexStore4),
    IndexOpWidth(8, Op.indexLoad8, Op.indexStore8),
    IndexOpWidth(sliceDescriptorSize, Op.indexLoad16, Op.indexStore16),
];

// The `indexLoadN`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width if the table above has one, else the
// `N` variant (which carries the width in its own `d` operand instead).
package(quickbite.backends.bytecode) Op indexLoadOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; indexOpWidths)
        if (entry.width == width)
            return entry.loadOp;
    return Op.indexLoadN;
}

// See `indexLoadOp`; the store-side counterpart sharing the same table.
package(quickbite.backends.bytecode) Op indexStoreOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; indexOpWidths)
        if (entry.width == width)
            return entry.storeOp;
    return Op.indexStoreN;
}

// The reverse direction: the fixed byte width a fixed-width `indexLoad*`/
// `indexStore*` opcode operates on. Not valid for `indexLoadN`/`indexStoreN`,
// whose width is a runtime operand rather than implied by the opcode.
package(quickbite.backends.bytecode) uint indexElementWidth(in Op op)
    @safe @nogc nothrow pure
in (op != Op.indexLoadN && op != Op.indexStoreN)
{
    foreach (entry; indexOpWidths)
        if (entry.loadOp == op || entry.storeOp == op)
            return entry.width;
    assert(0, "Not a fixed-width indexLoad/indexStore opcode.");
}

// The `pointerLoad`/`pointerStore`/`pointerSlice` family's one op<->width
// table, the same pattern as `indexOpWidths` above but with three opcodes per
// width instead of two (a raw-pointer dereference also has a slice-taking
// form). compiler.d's `pointerLoadOp`/`pointerStoreOp`/`pointerSliceOp`
// width->opcode selectors and machine.d's element-size Op->width derivation
// (`pointerElementWidth` below) both walk this same table, so the two
// directions cannot independently drift out of sync.
private struct PointerOpWidth {
    uint width;
    Op loadOp;
    Op storeOp;
    Op sliceOp;
}

private immutable PointerOpWidth[] pointerOpWidths = [
    PointerOpWidth(1, Op.pointerLoad1, Op.pointerStore1, Op.pointerSlice1),
    PointerOpWidth(2, Op.pointerLoad2, Op.pointerStore2, Op.pointerSlice2),
    PointerOpWidth(4, Op.pointerLoad4, Op.pointerStore4, Op.pointerSlice4),
    PointerOpWidth(8, Op.pointerLoad8, Op.pointerStore8, Op.pointerSlice8),
    PointerOpWidth(16, Op.pointerLoad16, Op.pointerStore16, Op.pointerSlice16),
];

// The `pointerLoadN`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width if the table above has one, else the
// `N` variant (which carries the width in its own operand instead).
package(quickbite.backends.bytecode) Op pointerLoadOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; pointerOpWidths)
        if (entry.width == width)
            return entry.loadOp;
    return Op.pointerLoadN;
}

// See `pointerLoadOp`; the store-side counterpart sharing the same table.
package(quickbite.backends.bytecode) Op pointerStoreOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; pointerOpWidths)
        if (entry.width == width)
            return entry.storeOp;
    return Op.pointerStoreN;
}

// See `pointerLoadOp`; the slice-side counterpart sharing the same table.
package(quickbite.backends.bytecode) Op pointerSliceOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; pointerOpWidths)
        if (entry.width == width)
            return entry.sliceOp;
    return Op.pointerSliceN;
}

// The reverse direction: the fixed byte width a fixed-width `pointerLoad*`/
// `pointerStore*`/`pointerSlice*` opcode operates on. Not valid for the `N`
// variants, whose width is a runtime operand rather than implied by the
// opcode.
package(quickbite.backends.bytecode) uint pointerElementWidth(in Op op)
    @safe @nogc nothrow pure
in (op != Op.pointerLoadN && op != Op.pointerStoreN && op != Op.pointerSliceN)
{
    foreach (entry; pointerOpWidths)
        if (entry.loadOp == op || entry.storeOp == op || entry.sliceOp == op)
            return entry.width;
    assert(0, "Not a fixed-width pointerLoad/pointerStore/pointerSlice opcode.");
}

// The `subSlice` family's one op<->width table, the same pattern as
// `indexOpWidths`/`pointerOpWidths` above but with a single opcode per width
// (forming a sub-slice descriptor is one operation, not a load/store/slice
// split). compiler.d's `subSliceOp` width->opcode selector and machine.d's
// element-size Op->width derivation (`subSliceElementWidth` below) both walk
// this same table, so the two directions cannot independently drift out of
// sync.
private struct SubSliceOpWidth {
    uint width;
    Op op;
}

private immutable SubSliceOpWidth[] subSliceOpWidths = [
    SubSliceOpWidth(1, Op.subSlice1),
    SubSliceOpWidth(2, Op.subSlice2),
    SubSliceOpWidth(4, Op.subSlice4),
    SubSliceOpWidth(8, Op.subSlice8),
    SubSliceOpWidth(16, Op.subSlice16),
];

// The `subSlice`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width if the table above has one, else the `N`
// variant (which carries the width in its own `d` operand instead).
package(quickbite.backends.bytecode) Op subSliceOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; subSliceOpWidths)
        if (entry.width == width)
            return entry.op;
    return Op.subSliceN;
}

// The reverse direction: the fixed byte width a fixed-width `subSlice*`
// opcode operates on. Not valid for `subSliceN`, whose width is a runtime
// operand rather than implied by the opcode.
package(quickbite.backends.bytecode) uint subSliceElementWidth(in Op op)
    @safe @nogc nothrow pure
in (op != Op.subSliceN)
{
    foreach (entry; subSliceOpWidths)
        if (entry.op == op)
            return entry.width;
    assert(0, "Not a fixed-width subSlice opcode.");
}

// The `dupArray` family's one op<->width table, the same pattern as
// `subSliceOpWidths` above (a single opcode per width, since duplicating an
// array's elements into a fresh heap block is a single operation).
// compiler.d's `dupArrayOp` width->opcode selector and machine.d's
// element-size Op->width derivation (`dupArrayWidth` below) both walk this
// same table, so the two directions cannot independently drift out of sync.
private struct DupArrayOpWidth {
    uint width;
    Op op;
}

private immutable DupArrayOpWidth[] dupArrayOpWidths = [
    DupArrayOpWidth(1, Op.dupArray1),
    DupArrayOpWidth(2, Op.dupArray2),
    DupArrayOpWidth(4, Op.dupArray4),
    DupArrayOpWidth(8, Op.dupArray8),
    DupArrayOpWidth(16, Op.dupArray16),
];

// The `dupArray`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width if the table above has one, else the `N`
// variant (which carries the width in its own `c` operand instead).
package(quickbite.backends.bytecode) Op dupArrayOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; dupArrayOpWidths)
        if (entry.width == width)
            return entry.op;
    return Op.dupArrayN;
}

// The reverse direction: the fixed byte width a fixed-width `dupArray*`
// opcode operates on. Not valid for `dupArrayN`, whose width is a runtime
// operand rather than implied by the opcode.
package(quickbite.backends.bytecode) uint dupArrayWidth(in Op op)
    @safe @nogc nothrow pure
in (op != Op.dupArrayN)
{
    foreach (entry; dupArrayOpWidths)
        if (entry.op == op)
            return entry.width;
    assert(0, "Not a fixed-width dupArray opcode.");
}

// The `concatArrays` family's one op<->width table, the same pattern as
// `dupArrayOpWidths` above (a single opcode per width, since concatenating
// two arrays is a single operation). Unlike the other families, only 1, 4,
// and 16 bytes get a fixed-width opcode (matching indexLoad/indexStore's own
// omission of 2 and 8 for this family). compiler.d's `concatArraysOp`
// width->opcode selector and machine.d's element-size Op->width derivation
// (`concatArraysWidth` below) both walk this same table, so the two
// directions cannot independently drift out of sync.
private struct ConcatArraysOpWidth {
    uint width;
    Op op;
}

private immutable ConcatArraysOpWidth[] concatArraysOpWidths = [
    ConcatArraysOpWidth(1, Op.concatArrays1),
    ConcatArraysOpWidth(4, Op.concatArrays4),
    ConcatArraysOpWidth(16, Op.concatArrays16),
];

// The `concatArrays`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width if the table above has one, else the `N`
// variant (which carries the width in its own `d` operand instead).
package(quickbite.backends.bytecode) Op concatArraysOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; concatArraysOpWidths)
        if (entry.width == width)
            return entry.op;
    return Op.concatArraysN;
}

// The reverse direction: the fixed byte width a fixed-width `concatArrays*`
// opcode operates on. Not valid for `concatArraysN`, whose width is a
// runtime operand rather than implied by the opcode.
package(quickbite.backends.bytecode) uint concatArraysWidth(in Op op)
    @safe @nogc nothrow pure
in (op != Op.concatArraysN)
{
    foreach (entry; concatArraysOpWidths)
        if (entry.op == op)
            return entry.width;
    assert(0, "Not a fixed-width concatArrays opcode.");
}

// The `sliceCopy` family's one op<->width table, the same pattern as
// `dupArrayOpWidths` above (a single opcode per width). All five fixed
// widths get an opcode, matching indexLoad/indexStore's own 1/2/4/8/16 split
// (a generic slice copy has to move `T[][]` rows too, not just scalars).
// compiler.d's `sliceCopyOp` width->opcode selector and machine.d's
// element-size Op->width derivation (`sliceCopyWidth` below) both walk this
// same table, so the two directions cannot independently drift out of sync.
private struct SliceCopyOpWidth {
    uint width;
    Op op;
}

private immutable SliceCopyOpWidth[] sliceCopyOpWidths = [
    SliceCopyOpWidth(1, Op.sliceCopy1),
    SliceCopyOpWidth(2, Op.sliceCopy2),
    SliceCopyOpWidth(4, Op.sliceCopy4),
    SliceCopyOpWidth(8, Op.sliceCopy8),
    SliceCopyOpWidth(sliceDescriptorSize, Op.sliceCopy16),
];

// The `sliceCopy`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width if the table above has one, else the `N`
// variant (which carries the width in its own `c` operand instead).
package(quickbite.backends.bytecode) Op sliceCopyOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; sliceCopyOpWidths)
        if (entry.width == width)
            return entry.op;
    return Op.sliceCopyN;
}

// The reverse direction: the fixed byte width a fixed-width `sliceCopy*`
// opcode operates on. Not valid for `sliceCopyN`, whose width is a runtime
// operand rather than implied by the opcode.
package(quickbite.backends.bytecode) uint sliceCopyWidth(in Op op)
    @safe @nogc nothrow pure
    in (op != Op.sliceCopyN)
{
    foreach (entry; sliceCopyOpWidths)
        if (entry.op == op)
            return entry.width;
    assert(0, "Not a fixed-width sliceCopy opcode.");
}

// The `sliceFill` family's one op<->width table, the same pattern as
// `sliceCopyOpWidths` above but with only four fixed widths (1, 2, 4, 8):
// the broadcast source is a scalar (or, for `sliceFillN`, an arbitrary-width
// aggregate carried via operand `c`), never a 16-byte slice-descriptor
// element, so there is no `sliceFill16`. compiler.d's `sliceFillOp`
// width->opcode selector and machine.d's element-size Op->width derivation
// (`sliceFillWidth` below) both walk this same table, so the two directions
// cannot independently drift out of sync.
private struct SliceFillOpWidth {
    uint width;
    Op op;
}

private immutable SliceFillOpWidth[] sliceFillOpWidths = [
    SliceFillOpWidth(1, Op.sliceFill1),
    SliceFillOpWidth(ushort.sizeof, Op.sliceFill2),
    SliceFillOpWidth(uint.sizeof, Op.sliceFill4),
    SliceFillOpWidth(ulong.sizeof, Op.sliceFill8),
];

// The `sliceFill`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width if the table above has one, else the `N`
// variant (which carries the width in its own `c` operand instead, and reads
// a `c`-byte-wide source rather than a narrow scalar).
package(quickbite.backends.bytecode) Op sliceFillOp(in uint width)
    @safe @nogc nothrow pure
{
    foreach (entry; sliceFillOpWidths)
        if (entry.width == width)
            return entry.op;
    return Op.sliceFillN;
}

// The reverse direction: the fixed byte width a fixed-width `sliceFill*`
// opcode operates on. Not valid for `sliceFillN`, whose width is a runtime
// operand rather than implied by the opcode.
package(quickbite.backends.bytecode) uint sliceFillWidth(in Op op)
    @safe @nogc nothrow pure
    in (op != Op.sliceFillN)
{
    foreach (entry; sliceFillOpWidths)
        if (entry.op == op)
            return entry.width;
    assert(0, "Not a fixed-width sliceFill opcode.");
}

// The `sliceEqual` family's one op<->width table, the same pattern as
// `sliceFillOpWidths` above (the same four fixed widths, 1/2/4/8: a 16-byte
// slice-descriptor element, e.g. a `T[][]` row, is structural rather than
// flat-byte equality and goes through `Op.sliceEqualNested` instead). Unlike
// every other width-suffixed family, there is no `N` variant: every element
// width the front end can produce a `==` for is one of these four, so
// `sliceEqualOp` below throws rather than falling back. compiler.d's
// `sliceEqualOp` width->opcode selector and machine.d's element-size
// Op->width derivation (`sliceEqualWidth` below) both walk this same table,
// so the two directions cannot independently drift out of sync.
private struct SliceEqualOpWidth {
    uint width;
    Op op;
}

private immutable SliceEqualOpWidth[] sliceEqualOpWidths = [
    SliceEqualOpWidth(1, Op.sliceEqual1),
    SliceEqualOpWidth(2, Op.sliceEqual2),
    SliceEqualOpWidth(4, Op.sliceEqual4),
    SliceEqualOpWidth(8, Op.sliceEqual8),
];

// The `sliceEqual`-family width->opcode selector: `width` bytes uses the
// fixed-width opcode for that width, or throws if the front end ever hands
// it a width none of the four opcodes cover (there is no `N` variant; see
// `sliceEqualOpWidths` above).
package(quickbite.backends.bytecode) Op sliceEqualOp(in uint width) @safe pure
{
    foreach (entry; sliceEqualOpWidths)
        if (entry.width == width)
            return entry.op;
    import std.conv: text;
    throw new Exception(text(
        "Unsupported array element size in bytecode core: ", width,
    ));
}

// The reverse direction: the fixed byte width a fixed-width `sliceEqual*`
// opcode operates on.
package(quickbite.backends.bytecode) uint sliceEqualWidth(in Op op)
    @safe @nogc nothrow pure
{
    foreach (entry; sliceEqualOpWidths)
        if (entry.op == op)
            return entry.width;
    assert(0, "Not a fixed-width sliceEqual opcode.");
}

package(quickbite.backends.bytecode) struct Instruction {
    Op op;
    ushort a;
    ushort b;
    ushort c;
    ushort d;
    // The innermost row's own element byte width for `Op.sliceEqualNested`.
    ushort e;
}

package(quickbite.backends.bytecode) struct CompiledFunction {
    Instruction[] code; // empty until the function is (lazily) compiled
    uint frameSize;
    uint parameterBytes;
    ResultType returnType;
    bool hasThis;
    // Set only for a native-leaf function reached through a function-pointer
    // value (`&f` where `f.fbody is null`, taken e.g. by
    // `core.internal.dassert`'s `assumeFakeAttributes` closing over a
    // druntime hook like `GC.inFinalizer`): an index into `Program.nativeCalls`
    // instead of `noNativeCallIndex`. The guest function-pointer VALUE stays a
    // plain index into `Program.functions`, uniform with an ordinary
    // VM-compiled entry -- `code` simply never gets a body, and
    // `Op.call`/`Op.callIndirect` check this field to route through
    // `Program.nativeCalls` instead of interpreting `code`.
    size_t nativeCallIndex = noNativeCallIndex;
}

// Sentinel `CompiledFunction.nativeCallIndex` for an ordinary VM-compiled
// function (not a native-leaf reached through a function pointer).
package(quickbite.backends.bytecode) enum noNativeCallIndex = size_t.max;

// Sentinel `NativeCall` receiver offset for a call with no hidden receiver.
package(quickbite.backends.bytecode) enum noReceiverOffset = ushort.max;

package(quickbite.backends.bytecode) struct NativeCall {
    imported!"dmd.func".FuncDeclaration function_;
    imported!"dmd.mtype".Type[] argumentTypes;
    // A host class receiver crosses the FFI boundary as its raw object pointer.
    // `nativeClassReceiverType` is null for an ordinary native function call.
    ushort nativeClassReceiverOffset = noReceiverOffset;
    imported!"dmd.mtype".TypeClass nativeClassReceiverType;
    // A native struct method receives a pointer to the VM's inline receiver
    // block as its hidden `this` argument.
    ushort nativeStructReceiverOffset = noReceiverOffset;
    imported!"dmd.mtype".TypeStruct nativeStructReceiverType;
    // Empty for a direct call (`tryCompileNativeCall`'s own registrations):
    // each argument then sits at the uniform `index * nativeArgumentSlotSize`
    // stride `prepareNativeInvocation` assumes. A native-leaf function
    // reached through a function-pointer value instead carries its callee's
    // real dense parameter-frame offsets here (`ParameterLayout.offsets`,
    // the same layout `Op.call`/`Op.callIndirect` already placed the
    // argument bytes at) -- the argument area an indirect call builds is the
    // ordinary VM typed-frame parameter layout, not a native argument area,
    // so its per-argument addresses are computed differently.
    ushort[] argumentOffsets;
}

package(quickbite.backends.bytecode) struct VirtualFunction {
    ushort baseFunction;
    ushort function_;
}

package(quickbite.backends.bytecode) struct ClassInfo {
    ushort baseClass = noExceptionClass;
    ushort msgOffset = ushort.max;
    size_t nativeTypeInfo;
    VirtualFunction[] virtualFunctions;
    string name;
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
    // Stable per-literal blocks backing `Op.loadStringLiteral` and
    // `Op.loadDataPointer`: each entry is its own GC allocation that never
    // moves, unlike `data`, an append-growable array whose base address
    // shifts (and invalidates any pointer baked from it) every time a later
    // literal is compiled and appended.
    ubyte[][] literalBlocks;
    ubyte[] moduleData; // mutable VM-owned storage for module-level variables
    NativeCall[] nativeCalls;
    ClassInfo[] classes;
    // Roots the host TypeInfo mirrors used by `typeid` on VM class objects.
    imported!"object".TypeInfo[] nativeTypeInfos;
    ushort rangeErrorClass = noExceptionClass;
    CatchClause[] catchClauses;
}

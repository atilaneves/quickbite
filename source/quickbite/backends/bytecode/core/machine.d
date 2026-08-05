module quickbite.backends.bytecode.core.machine;

private:

// Compiles the function with the given index into the running program; the
// machine invokes it on the first call to a not-yet-compiled function.
package(quickbite.backends.bytecode) alias CompileFunction =
    void delegate(in size_t index);

// Bytes reserved upfront for the VM call stack so growing it for callee frames
// reuses the same block: raw `&local` pointers stay valid across calls.
private enum stackCapacity = 4 * 1024 * 1024;

package(quickbite.backends.bytecode) struct RunResult {
    ubyte[] bytes;
    ubyte[][] heap;
}

// Executes the program's entry function and returns the raw bytes of its
// result (empty for void), plus heap roots for result descriptors.
package(quickbite.backends.bytecode) RunResult run(
    ref imported!"quickbite.backends.bytecode.core.program".Program program,
    scope CompileFunction compileFunction,
) {
    import core.exception: RangeError;
    import quickbite.backends.bytecode.core.program:
        appendElementWidth, CatchClause, ClassInfo,
        concatArraysWidth, dupArrayWidth, indexElementWidth, Op,
        noCatchObjectField, noExceptionClass, noOutParameterOffset,
        pointerElementWidth, size, sliceCopyWidth, sliceDescriptorSize,
        sliceEqualWidth, subSliceElementWidth;

    // Reserve a generous fixed capacity so growing `stack` for callee frames
    // never reallocates: a raw `&local` pointer (`int* p = &x`) stored in a
    // struct field or heap and dereferenced later must stay valid across the
    // intervening calls that grow the stack.
    auto stack = new ubyte[](program.functions[0].frameSize);
    stack.reserve(stackCapacity);
    // Lazy compilation can add module slots while this machine is running, so
    // access the program-owned segment directly. The compiler reserves its
    // maximum addressable capacity before execution, keeping raw addresses
    // produced by `moduleAddress` stable as the visible length grows.
    ref moduleData = program.moduleData;
    // VM-owned writable heap blocks backing dynamic arrays. Holding the GC
    // slices here keeps the memory the slice descriptors point at alive; the
    // descriptors store the raw `block.ptr` as a native pointer.
    ubyte[][] heap;
    // Blocks whose appendable status entered this run through a native-layout
    // slice descriptor write. Ordinary VM-owned arrays keep copy-on-append.
    size_t[] appendablePointers;
    // VM-owned `int[int]` maps backing associative-array locals. A local's
    // 8-byte slot holds a 1-based index into this table (0 meaning a not-yet-
    // created empty map); the table roots every map's keys and values.
    AssocArray[] maps;
    Frame[] frames;
    // Active catch handlers, innermost last. A `pushHandler` records the catch
    // body's location (instruction index plus the frame it runs in); a
    // `throwString` with any handler active redirects to the innermost one
    // (popping it) instead of propagating as a host exception.
    Handler[] handlers;
    size_t functionIndex = 0;
    size_t base = 0;
    size_t ip;

    while (true) {
        try {
            if (frames.length != 0)
                synchronizeRefAliases(stack, frames[$ - 1], base);
            const instruction = program.functions[functionIndex].code[ip];
            final switch (instruction.op) with (Op) {
            case loadConstant:
                const ubyte[ulong.sizeof] bytes =
                    scalarBytes(program.constants[instruction.b]);
                stack[
                    base + instruction.a .. base + instruction.a + instruction.c
                ] = bytes[0 .. instruction.c];
                ++ip;
                break;

            case loadRealConstant:
                stack[base + instruction.a
                    .. base + instruction.a + real.sizeof] =
                    program.realConstants[instruction.b][];
                ++ip;
                break;

            case loadDataPointer:
                writeRawPointer(
                    stack,
                    base + instruction.a,
                    cast(size_t) program.literalBlocks[instruction.b].ptr,
                );
                ++ip;
                break;

            case loadStaticArray:
                // Copy the static array's bytes from the read-only data
                // segment into its inline frame slot.
                stack[
                    base + instruction.a .. base + instruction.a + instruction.c
                ] = program.data[
                    instruction.b .. instruction.b + instruction.c
                ];
                ++ip;
                break;

            case allocArray:
                // Allocate writable backing memory, root it in `heap`, and
                // write the descriptor {ptr, length} into the frame slot.
                auto block = new ubyte[](instruction.b * instruction.c);
                heap ~= block;
                writeSliceDescriptor(
                    stack, base + instruction.a, block, instruction.c,
                );
                ++ip;
                break;

            case allocArrayDynamic:
                // The length is a runtime size_t in a frame slot; operand b packs
                // the default-init fill byte (high 8 bits) and the element size
                // (low 8 bits). Allocate a fresh block of that many elements,
                // fill it with the default byte, root it, and write the
                // descriptor.
                const dynamicLength =
                    scalarValue!size_t(stack, base + instruction.c);
                const dynamicElementSize = instruction.b & 0xff;
                const dynamicFill = cast(ubyte) (instruction.b >> 8);
                auto dynamicBlock =
                    new ubyte[](dynamicElementSize * dynamicLength);
                dynamicBlock[] = dynamicFill;
                heap ~= dynamicBlock;
                writeSliceDescriptor(
                    stack, base + instruction.a, dynamicBlock, dynamicLength,
                );
                ++ip;
                break;

            case allocArray2D:
                // {rows, cols} live in an adjacent size_t pair at frame offset c;
                // operand b packs the inner element's fill byte and size. Build
                // the outer block of `rows` descriptors, each pointing at a fresh
                // inner block of `cols` filled elements; root every block.
                const rows = scalarValue!size_t(stack, base + instruction.c);
                const cols = scalarValue!size_t(
                    stack, base + instruction.c + size_t.sizeof,
                );
                const innerElementSize = instruction.b & 0xff;
                const innerFill = cast(ubyte) (instruction.b >> 8);
                auto outerBlock = new ubyte[](rows * sliceDescriptorSize);
                heap ~= outerBlock;
                foreach (row; 0 .. rows) {
                    auto innerBlock = new ubyte[](innerElementSize * cols);
                    innerBlock[] = innerFill;
                    heap ~= innerBlock;
                    writeSliceDescriptor(
                        outerBlock, row * sliceDescriptorSize, innerBlock, cols,
                    );
                }
                writeSliceDescriptor(
                    stack, base + instruction.a, outerBlock, rows,
                );
                ++ip;
                break;

            case allocStruct:
                // Allocate a fresh heap block for a single `new S` struct,
                // copy the initialised block of `c` bytes from the frame in,
                // root it, and write the raw heap pointer into the frame slot.
                auto structBlock = new ubyte[](instruction.c);
                structBlock[] = stack[
                    base + instruction.b .. base + instruction.b + instruction.c
                ];
                heap ~= structBlock;
                writeBlockPointer(stack, base + instruction.a, structBlock);
                ++ip;
                break;

            case allocClass:
                auto classBlock = new ubyte[](instruction.c);
                classBlock[0 .. size_t.sizeof] =
                    scalarBytes(cast(size_t) instruction.b)[];
                heap ~= classBlock;
                writeBlockPointer(stack, base + instruction.a, classBlock);
                ++ip;
                break;

            case setArrayLength:
                heap ~= resizeArray(
                    stack,
                    base + instruction.a,
                    instruction.b & 0xff,
                    cast(ubyte) (instruction.b >> 8),
                    scalarValue!size_t(stack, base + instruction.c),
                );
                ++ip;
                break;

            case setArrayLengthFromTemplate:
                heap ~= resizeArrayWithTemplate(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    instruction.d,
                    scalarValue!size_t(stack, base + instruction.c),
                );
                ++ip;
                break;

            case nullSlice:
                stack[
                    base + instruction.a
                    .. base + instruction.a + 2 * size_t.sizeof
                ] = 0;
                ++ip;
                break;

            case loadStringLiteral:
                writeSliceDescriptorPointer(
                    stack,
                    base + instruction.a,
                    cast(size_t) program.literalBlocks[instruction.b].ptr,
                    instruction.c,
                );
                ++ip;
                break;

            case sliceLength:
                stack[
                    base + instruction.a .. base + instruction.a + size_t.sizeof
                ] = stack[
                    base + instruction.b + size_t.sizeof
                    .. base + instruction.b + 2 * size_t.sizeof
                ];
                ++ip;
                break;

            case indexLoad1, indexLoad2, indexLoad4, indexLoad8, indexLoad16,
                indexLoadN:
                const loadSize = instruction.op == indexLoadN
                    ? instruction.d
                    : indexElementWidth(instruction.op);
                const loadElement = elementAddress(
                    stack, base + instruction.b,
                    scalarValue!size_t(stack, base + instruction.c),
                    loadSize,
                );
                readHeapElement(
                    stack[
                        base + instruction.a .. base + instruction.a + loadSize
                    ],
                    loadElement,
                );
                ++ip;
                break;

            case indexStore1, indexStore2, indexStore4, indexStore8,
                indexStore16, indexStoreN:
                const storeSize = instruction.op == indexStoreN
                    ? instruction.d
                    : indexElementWidth(instruction.op);
                // Non-const: the heap element is written through this pointer.
                auto storeElement = elementAddress(
                    stack, base + instruction.b,
                    scalarValue!size_t(stack, base + instruction.c),
                    storeSize,
                );
                writeHeapElement(
                    storeElement,
                    stack[
                        base + instruction.a .. base + instruction.a + storeSize
                    ],
                );
                ++ip;
                break;

            case checkStaticArrayIndex:
                enforceIndexInBounds(
                    scalarValue!size_t(stack, base + instruction.a),
                    scalarValue!size_t(stack, base + instruction.b),
                );
                ++ip;
                break;

            case subSlice1, subSlice2, subSlice4, subSlice8, subSlice16,
                subSliceN:
                const subElementSize = instruction.op == subSliceN
                    ? instruction.d
                    : subSliceElementWidth(instruction.op);
                const lo = scalarValue!size_t(stack, base + instruction.c);
                const hi = scalarValue!size_t(
                    stack, base + instruction.c + size_t.sizeof,
                );
                validateSubSlice(
                    stack,
                    base + instruction.b,
                    lo,
                    hi,
                );
                const sourcePointer =
                    scalarValue!size_t(stack, base + instruction.b);
                writeSliceDescriptorPointer(
                    stack,
                    base + instruction.a,
                    sourcePointer + lo * subElementSize,
                    hi - lo,
                );
                ++ip;
                break;

            case sliceCopy1, sliceCopy2, sliceCopy4, sliceCopy8, sliceCopy16,
                sliceCopyN:
                copySlice(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    instruction.op == sliceCopyN
                        ? instruction.c
                        : sliceCopyWidth(instruction.op),
                );
                ++ip;
                break;

            case rowRangeCopy:
                copyRowRange(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    instruction.c,
                );
                ++ip;
                break;

            case sliceFill1:
                fillSlice1(stack, base + instruction.a, base + instruction.b);
                ++ip;
                break;

            case sliceFill2:
                fillSlice2(stack, base + instruction.a, base + instruction.b);
                ++ip;
                break;

            case sliceFill4:
                fillSlice4(stack, base + instruction.a, base + instruction.b);
                ++ip;
                break;

            case sliceFill8:
                fillSlice8(stack, base + instruction.a, base + instruction.b);
                ++ip;
                break;

            case sliceFillN:
                fillSliceN(
                    stack, base + instruction.a, base + instruction.b,
                    instruction.c,
                );
                ++ip;
                break;

            case sliceEqual1, sliceEqual2, sliceEqual4, sliceEqual8:
                stack[base + instruction.a] = slicesEqual(
                    stack,
                    base + instruction.b,
                    base + instruction.c,
                    sliceEqualWidth(instruction.op),
                ) ? 1 : 0;
                ++ip;
                break;

            case sliceEqualNested:
                stack[base + instruction.a] = nestedSlicesEqual(
                    stack,
                    base + instruction.b,
                    base + instruction.c,
                    instruction.d,
                    instruction.e,
                ) ? 1 : 0;
                ++ip;
                break;

            case appendElement1, appendElement2, appendElement4, appendElement8,
                appendElement16, appendElementN:
                auto appended = appendElement(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    instruction.op == appendElementN
                        ? instruction.c
                        : appendElementWidth(instruction.op),
                    heap,
                    appendablePointers,
                );
                heap ~= appended;
                ++ip;
                break;

            case concatArrays1, concatArrays4, concatArrays16, concatArraysN:
                heap ~= concatArrays(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    base + instruction.c,
                    instruction.op == concatArraysN
                        ? instruction.d
                        : concatArraysWidth(instruction.op),
                );
                ++ip;
                break;

            case dupArray1, dupArray2, dupArray4, dupArray8, dupArray16,
                dupArrayN:
                heap ~= dupArray(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    instruction.op == dupArrayN
                        ? instruction.c
                        : dupArrayWidth(instruction.op),
                );
                ++ip;
                break;

            case arrayAddAssign4:
                applyArrayAddAssign4(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    base + instruction.c,
                );
                ++ip;
                break;

            case pointerLoad1, pointerLoad2, pointerLoad4, pointerLoad8,
                pointerLoad16, pointerLoadN:
                const pointerLoadSize = instruction.op == pointerLoadN
                    ? instruction.d
                    : pointerElementWidth(instruction.op);
                const pointerLoadAddress =
                    scalarValue!size_t(stack, base + instruction.b) +
                    scalarValue!size_t(stack, base + instruction.c) *
                        pointerLoadSize;
                readHeapElement(
                    stack[
                        base + instruction.a
                        .. base + instruction.a + pointerLoadSize
                    ],
                    cast(const(ubyte)*) pointerLoadAddress,
                );
                ++ip;
                break;

            case atomicLoad4:
                const atomicLoadAddress =
                    scalarValue!size_t(stack, base + instruction.b) +
                    scalarValue!size_t(stack, base + instruction.c) *
                        uint.sizeof;
                const ubyte[uint.sizeof] atomicLoadValue = scalarBytes(
                    atomicLoadDword(cast(const(ubyte)*) atomicLoadAddress),
                );
                stack[
                    base + instruction.a
                    .. base + instruction.a + uint.sizeof
                ] = atomicLoadValue;
                ++ip;
                break;

            case atomicLoad8:
                const atomicLoadAddress =
                    scalarValue!size_t(stack, base + instruction.b) +
                    scalarValue!size_t(stack, base + instruction.c) *
                        ulong.sizeof;
                const ubyte[ulong.sizeof] atomicLoadValue = scalarBytes(
                    atomicLoadWord(cast(const(ubyte)*) atomicLoadAddress),
                );
                stack[
                    base + instruction.a
                    .. base + instruction.a + ulong.sizeof
                ] = atomicLoadValue;
                ++ip;
                break;

            case atomicExchange4:
                const atomicExchangeAddress = scalarValue!size_t(
                    stack, base + instruction.b,
                );
                const atomicExchangeValue = scalarValue!uint(
                    stack, base + instruction.c,
                );
                const ubyte[uint.sizeof] atomicExchangeResult = scalarBytes(
                    atomicExchangeDword(
                        cast(ubyte*) atomicExchangeAddress,
                        atomicExchangeValue,
                    ),
                );
                stack[
                    base + instruction.a
                    .. base + instruction.a + uint.sizeof
                ] = atomicExchangeResult;
                ++ip;
                break;

            case atomicFetchAdd4:
                const atomicFetchAddAddress = scalarValue!size_t(
                    stack, base + instruction.b,
                );
                const atomicFetchAddValue = scalarValue!uint(
                    stack, base + instruction.c,
                );
                const ubyte[uint.sizeof] atomicFetchAddResult = scalarBytes(
                    atomicFetchAddDword(
                        cast(ubyte*) atomicFetchAddAddress,
                        atomicFetchAddValue,
                    ),
                );
                stack[
                    base + instruction.a
                    .. base + instruction.a + uint.sizeof
                ] = atomicFetchAddResult;
                ++ip;
                break;

            case atomicFetchAdd8:
                const atomicFetchAddAddress = scalarValue!size_t(
                    stack, base + instruction.b,
                );
                const atomicFetchAddValue = scalarValue!ulong(
                    stack, base + instruction.c,
                );
                const ubyte[ulong.sizeof] atomicFetchAddResult = scalarBytes(
                    atomicFetchAddWord(
                        cast(ubyte*) atomicFetchAddAddress,
                        atomicFetchAddValue,
                    ),
                );
                stack[
                    base + instruction.a
                    .. base + instruction.a + ulong.sizeof
                ] = atomicFetchAddResult;
                ++ip;
                break;

            case pointerStore1, pointerStore2, pointerStore4, pointerStore8,
                pointerStore16, pointerStoreN:
                const pointerStoreSize = instruction.op == pointerStoreN
                    ? instruction.d
                    : pointerElementWidth(instruction.op);
                const pointerStoreAddress =
                    scalarValue!size_t(stack, base + instruction.b) +
                    scalarValue!size_t(stack, base + instruction.c) *
                        pointerStoreSize;
                writeHeapElement(
                    cast(ubyte*) pointerStoreAddress,
                    stack[
                        base + instruction.a
                        .. base + instruction.a + pointerStoreSize
                    ],
                );
                ++ip;
                break;

            case pointerSlice1, pointerSlice2, pointerSlice4, pointerSlice8,
                pointerSlice16, pointerSliceN:
                const pointerSliceSize = instruction.op == pointerSliceN
                    ? instruction.d
                    : pointerElementWidth(instruction.op);
                const sliceLo = scalarValue!size_t(stack, base + instruction.c);
                const sliceHi = scalarValue!size_t(
                    stack, base + instruction.c + size_t.sizeof,
                );
                writeSliceDescriptorPointer(
                    stack,
                    base + instruction.a,
                    scalarValue!size_t(stack, base + instruction.b) +
                        sliceLo * pointerSliceSize,
                    sliceHi - sliceLo,
                );
                ++ip;
                break;

            case copy:
                // A self-copy (identical source and destination, e.g. a
                // redundant temporary write `x = x`) is a no-op; skip it, since
                // a slice-to-itself assignment would abort as overlapping.
                if (instruction.a != instruction.b)
                    stack[
                        base + instruction.a
                        .. base + instruction.a + instruction.c
                    ] = stack[
                        base + instruction.b
                        .. base + instruction.b + instruction.c
                    ];
                ++ip;
                break;

            case loadModule:
                stack[
                    base + instruction.a
                    .. base + instruction.a + instruction.c
                ] = moduleData[instruction.b .. instruction.b + instruction.c];
                ++ip;
                break;

            case storeModule:
                moduleData[instruction.b .. instruction.b + instruction.c] =
                    stack[
                        base + instruction.a
                        .. base + instruction.a + instruction.c
                    ];
                ++ip;
                break;

            case moduleAddress:
                writeRawPointer(
                    stack,
                    base + instruction.a,
                    cast(size_t) (moduleData.ptr + instruction.b),
                );
                ++ip;
                break;

            case frameBaseIndex:
                writeScalar!size_t(stack, base + instruction.a, base);
                ++ip;
                break;

            case frameLoad: {
                const sourceIndex =
                    scalarValue!size_t(stack, base + instruction.b);
                stack[
                    base + instruction.a .. base + instruction.a + instruction.c
                ] = stack[sourceIndex .. sourceIndex + instruction.c];
                ++ip;
                break;
            }

            case frameStore: {
                const destinationIndex =
                    scalarValue!size_t(stack, base + instruction.b);
                stack[destinationIndex .. destinationIndex + instruction.c] =
                    stack[
                        base + instruction.a
                        .. base + instruction.a + instruction.c
                    ];
                ++ip;
                break;
            }

            case frameAddress:
                writeFrameAddress(
                    stack, base + instruction.a, base + instruction.b,
                );
                ++ip;
                break;

            case frameIndexAddress:
                writeFrameAddress(
                    stack,
                    base + instruction.a,
                    scalarValue!size_t(stack, base + instruction.b),
                );
                ++ip;
                break;

            case refParameterAddress:
                writeFrameAddress(
                    stack,
                    base + instruction.a,
                    refParameterCallerAddress(
                        frames[$ - 1], base, instruction.b,
                    ),
                );
                ++ip;
                break;

            case signExtend1to2:
                const ubyte[short.sizeof] signWidenedShort = scalarBytes(
                    cast(short) scalarValue!byte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + short.sizeof]
                    = signWidenedShort;
                ++ip;
                break;

            case zeroExtend1to2:
                const ubyte[ushort.sizeof] zeroWidenedShort = scalarBytes(
                    cast(ushort) scalarValue!ubyte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + ushort.sizeof]
                    = zeroWidenedShort;
                ++ip;
                break;

            case signExtend1to4:
                const ubyte[int.sizeof] signWidened = scalarBytes(
                    cast(int) scalarValue!byte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = signWidened;
                ++ip;
                break;

            case zeroExtend1to4:
                const ubyte[int.sizeof] zeroWidened = scalarBytes(
                    cast(int) scalarValue!ubyte(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = zeroWidened;
                ++ip;
                break;

            case signExtend2to4:
                const ubyte[int.sizeof] shortWidened = scalarBytes(
                    cast(int) scalarValue!short(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = shortWidened;
                ++ip;
                break;

            case zeroExtend2to4:
                const ubyte[int.sizeof] wideWidened = scalarBytes(
                    cast(int) scalarValue!ushort(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = wideWidened;
                ++ip;
                break;

            case signExtend4to8:
                const ubyte[long.sizeof] extended = scalarBytes(
                    cast(long) scalarValue!int(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = extended;
                ++ip;
                break;

            case zeroExtend4to8:
                const ubyte[ulong.sizeof] zeroExtended = scalarBytes(
                    cast(ulong) scalarValue!uint(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + ulong.sizeof]
                    = zeroExtended;
                ++ip;
                break;

            case convertDoubleToInt:
                const ubyte[int.sizeof] converted = scalarBytes(
                    cast(int) floatValue!double(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = converted;
                ++ip;
                break;

            case convertIntToFloat:
                stack[
                    base + instruction.a .. base + instruction.a + float.sizeof
                ] = floatBytes(cast(float) integerToReal(
                    stack, base + instruction.b, instruction.c,
                ));
                ++ip;
                break;

            case convertIntToDouble:
                stack[
                    base + instruction.a .. base + instruction.a + double.sizeof
                ] = floatBytes(cast(double) integerToReal(
                    stack, base + instruction.b, instruction.c,
                ));
                ++ip;
                break;

            case convertIntToReal:
                stack[
                    base + instruction.a .. base + instruction.a + real.sizeof
                ] = floatBytes(integerToReal(
                    stack, base + instruction.b, instruction.c,
                ));
                ++ip;
                break;

            case convertFloatToDouble:
                stack[
                    base + instruction.a .. base + instruction.a + double.sizeof
                ] = floatBytes(cast(double) floatValue!float(
                    stack, base + instruction.b,
                ));
                ++ip;
                break;

            case convertFloatToReal:
                stack[
                    base + instruction.a .. base + instruction.a + real.sizeof
                ] = floatBytes(cast(real) floatValue!float(
                    stack, base + instruction.b,
                ));
                ++ip;
                break;

            case convertDoubleToReal:
                stack[
                    base + instruction.a .. base + instruction.a + real.sizeof
                ] = floatBytes(cast(real) floatValue!double(
                    stack, base + instruction.b,
                ));
                ++ip;
                break;

            case addInt4:
                const ubyte[int.sizeof] sum = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) +
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = sum;
                ++ip;
                break;

            case addInt8:
                const ubyte[long.sizeof] sum = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) +
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = sum;
                ++ip;
                break;

            case subInt8:
                const ubyte[long.sizeof] difference8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) -
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = difference8;
                ++ip;
                break;

            case mulInt4:
                const ubyte[int.sizeof] product4 = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) *
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = product4;
                ++ip;
                break;

            case mulInt8:
                const ubyte[long.sizeof] product8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) *
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = product8;
                ++ip;
                break;

            case mulUnsignedInt4WithCarry:
                const lhs4 = scalarValue!uint(stack, base + instruction.b);
                const rhs4 = scalarValue!uint(stack, base + instruction.c);
                const wideProduct4 = cast(ulong) lhs4 * rhs4;
                const ubyte[uint.sizeof] unsignedProduct4 = scalarBytes(
                    cast(uint) wideProduct4,
                );
                stack[
                    base + instruction.a
                    .. base + instruction.a + uint.sizeof
                ] = unsignedProduct4;
                stack[base + instruction.a + uint.sizeof] =
                    wideProduct4 > uint.max;
                ++ip;
                break;

            case mulUnsignedInt8WithCarry:
                const lhs8 = scalarValue!ulong(stack, base + instruction.b);
                const rhs8 = scalarValue!ulong(stack, base + instruction.c);
                const hasCarry8 = lhs8 != 0 && rhs8 > ulong.max / lhs8;
                const ubyte[ulong.sizeof] unsignedProduct8 = scalarBytes(
                    lhs8 * rhs8,
                );
                stack[
                    base + instruction.a
                    .. base + instruction.a + ulong.sizeof
                ] = unsignedProduct8;
                stack[base + instruction.a + ulong.sizeof] = hasCarry8;
                ++ip;
                break;

            case divInt8:
                const ubyte[long.sizeof] quotient8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) /
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = quotient8;
                ++ip;
                break;

            case divUnsignedInt8:
                const ubyte[ulong.sizeof] unsignedQuotient8 = scalarBytes(
                    scalarValue!ulong(stack, base + instruction.b) /
                    scalarValue!ulong(stack, base + instruction.c),
                );
                stack[
                    base + instruction.a .. base + instruction.a + ulong.sizeof
                ] = unsignedQuotient8;
                ++ip;
                break;

            case modUnsignedInt8:
                const ubyte[ulong.sizeof] unsignedRemainder8 = scalarBytes(
                    scalarValue!ulong(stack, base + instruction.b) %
                    scalarValue!ulong(stack, base + instruction.c),
                );
                stack[
                    base + instruction.a .. base + instruction.a + ulong.sizeof
                ] = unsignedRemainder8;
                ++ip;
                break;

            case modInt8:
                const ubyte[long.sizeof] remainder8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) %
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[
                    base + instruction.a .. base + instruction.a + long.sizeof
                ] = remainder8;
                ++ip;
                break;

            case subInt4:
                const ubyte[int.sizeof] difference = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) -
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = difference;
                ++ip;
                break;

            case bitOrInt4:
                const ubyte[int.sizeof] bits = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) |
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = bits;
                ++ip;
                break;

            case bitOrInt8:
                const ubyte[long.sizeof] bits = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) |
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = bits;
                ++ip;
                break;

            case divInt4:
                const ubyte[int.sizeof] quotient = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) /
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = quotient;
                ++ip;
                break;

            case modInt4:
                const ubyte[int.sizeof] remainder = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) %
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = remainder;
                ++ip;
                break;

            case divUnsignedInt4:
                const ubyte[uint.sizeof] unsignedQuotient4 = scalarBytes(
                    scalarValue!uint(stack, base + instruction.b) /
                    scalarValue!uint(stack, base + instruction.c),
                );
                stack[
                    base + instruction.a .. base + instruction.a + uint.sizeof
                ] = unsignedQuotient4;
                ++ip;
                break;

            case modUnsignedInt4:
                const ubyte[uint.sizeof] unsignedRemainder4 = scalarBytes(
                    scalarValue!uint(stack, base + instruction.b) %
                    scalarValue!uint(stack, base + instruction.c),
                );
                stack[
                    base + instruction.a .. base + instruction.a + uint.sizeof
                ] = unsignedRemainder4;
                ++ip;
                break;

            case shlInt4:
                const ubyte[int.sizeof] leftShifted = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) <<
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = leftShifted;
                ++ip;
                break;

            case shrInt4:
                const ubyte[int.sizeof] rightShifted = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) >>
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = rightShifted;
                ++ip;
                break;

            case ushrInt4:
                const ubyte[int.sizeof] unsignedRightShifted = scalarBytes(
                    cast(int) (scalarValue!uint(stack, base + instruction.b) >>
                        scalarValue!int(stack, base + instruction.c)),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = unsignedRightShifted;
                ++ip;
                break;

            case shlInt8:
                const ubyte[long.sizeof] leftShifted8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) <<
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = leftShifted8;
                ++ip;
                break;

            case shrInt8:
                const ubyte[long.sizeof] rightShifted = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) >>
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = rightShifted;
                ++ip;
                break;

            case ushrInt8:
                const ubyte[long.sizeof] unsignedRightShifted = scalarBytes(
                    cast(long) (scalarValue!ulong(
                        stack, base + instruction.b,
                    ) >> scalarValue!int(stack, base + instruction.c)),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = unsignedRightShifted;
                ++ip;
                break;

            case bitAndInt4:
                const ubyte[int.sizeof] andBits = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) &
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = andBits;
                ++ip;
                break;

            case bitAndInt8:
                const ubyte[long.sizeof] andBits8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) &
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = andBits8;
                ++ip;
                break;

            case bitXorInt4:
                const ubyte[int.sizeof] xorBits = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) ^
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = xorBits;
                ++ip;
                break;

            case bitNotInt4:
                const ubyte[int.sizeof] complement = scalarBytes(
                    ~scalarValue!int(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = complement;
                ++ip;
                break;

            case notBool:
                stack[base + instruction.a] =
                    stack[base + instruction.b] == 0 ? 1 : 0;
                ++ip;
                break;

            case normaliseBool:
                stack[base + instruction.a] =
                    stack[base + instruction.b] == 0 ? 0 : 1;
                ++ip;
                break;

            case lessThan4:
                stack[base + instruction.a] =
                    scalarValue!int(stack, base + instruction.b) <
                    scalarValue!int(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThan4:
                stack[base + instruction.a] =
                    scalarValue!int(stack, base + instruction.b) >
                    scalarValue!int(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessOrEqual4:
                stack[base + instruction.a] =
                    scalarValue!int(stack, base + instruction.b) <=
                    scalarValue!int(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterOrEqual4:
                stack[base + instruction.a] =
                    scalarValue!int(stack, base + instruction.b) >=
                    scalarValue!int(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessThanUnsigned4:
                stack[base + instruction.a] =
                    scalarValue!uint(stack, base + instruction.b) <
                    scalarValue!uint(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessOrEqualUnsigned4:
                stack[base + instruction.a] =
                    scalarValue!uint(stack, base + instruction.b) <=
                    scalarValue!uint(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThanUnsigned4:
                stack[base + instruction.a] =
                    scalarValue!uint(stack, base + instruction.b) >
                    scalarValue!uint(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterOrEqualUnsigned4:
                stack[base + instruction.a] =
                    scalarValue!uint(stack, base + instruction.b) >=
                    scalarValue!uint(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessThan8:
                stack[base + instruction.a] =
                    scalarValue!long(stack, base + instruction.b) <
                    scalarValue!long(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThan8:
                stack[base + instruction.a] =
                    scalarValue!long(stack, base + instruction.b) >
                    scalarValue!long(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessOrEqual8:
                stack[base + instruction.a] =
                    scalarValue!long(stack, base + instruction.b) <=
                    scalarValue!long(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterOrEqual8:
                stack[base + instruction.a] =
                    scalarValue!long(stack, base + instruction.b) >=
                    scalarValue!long(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessThanUnsigned8:
                stack[base + instruction.a] =
                    scalarValue!size_t(stack, base + instruction.b) <
                    scalarValue!size_t(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessOrEqualUnsigned8:
                stack[base + instruction.a] =
                    scalarValue!size_t(stack, base + instruction.b) <=
                    scalarValue!size_t(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThanUnsigned8:
                stack[base + instruction.a] =
                    scalarValue!size_t(stack, base + instruction.b) >
                    scalarValue!size_t(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterOrEqualUnsigned8:
                stack[base + instruction.a] =
                    scalarValue!size_t(stack, base + instruction.b) >=
                    scalarValue!size_t(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case notEqual4:
                stack[base + instruction.a] =
                    scalarValue!int(stack, base + instruction.b) !=
                    scalarValue!int(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case notEqual8:
                stack[base + instruction.a] =
                    scalarValue!size_t(stack, base + instruction.b) !=
                    scalarValue!size_t(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case equalFloat:
                stack[base + instruction.a] =
                    floatValue!float(stack, base + instruction.b) ==
                    floatValue!float(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case equalDouble:
                stack[base + instruction.a] =
                    floatValue!double(stack, base + instruction.b) ==
                    floatValue!double(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case equalReal:
                stack[base + instruction.a] =
                    floatValue!real(stack, base + instruction.b) ==
                    floatValue!real(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case notEqualFloat:
                stack[base + instruction.a] =
                    floatValue!float(stack, base + instruction.b) !=
                    floatValue!float(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case notEqualDouble:
                stack[base + instruction.a] =
                    floatValue!double(stack, base + instruction.b) !=
                    floatValue!double(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case notEqualReal:
                stack[base + instruction.a] =
                    floatValue!real(stack, base + instruction.b) !=
                    floatValue!real(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessThanFloat:
                stack[base + instruction.a] =
                    floatValue!float(stack, base + instruction.b) <
                    floatValue!float(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessThanDouble:
                stack[base + instruction.a] =
                    floatValue!double(stack, base + instruction.b) <
                    floatValue!double(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessThanReal:
                stack[base + instruction.a] =
                    floatValue!real(stack, base + instruction.b) <
                    floatValue!real(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThanFloat:
                stack[base + instruction.a] =
                    floatValue!float(stack, base + instruction.b) >
                    floatValue!float(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThanDouble:
                stack[base + instruction.a] =
                    floatValue!double(stack, base + instruction.b) >
                    floatValue!double(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterThanReal:
                stack[base + instruction.a] =
                    floatValue!real(stack, base + instruction.b) >
                    floatValue!real(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessOrEqualFloat:
                stack[base + instruction.a] =
                    floatValue!float(stack, base + instruction.b) <=
                    floatValue!float(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessOrEqualDouble:
                stack[base + instruction.a] =
                    floatValue!double(stack, base + instruction.b) <=
                    floatValue!double(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case lessOrEqualReal:
                stack[base + instruction.a] =
                    floatValue!real(stack, base + instruction.b) <=
                    floatValue!real(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterOrEqualFloat:
                stack[base + instruction.a] =
                    floatValue!float(stack, base + instruction.b) >=
                    floatValue!float(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterOrEqualDouble:
                stack[base + instruction.a] =
                    floatValue!double(stack, base + instruction.b) >=
                    floatValue!double(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case greaterOrEqualReal:
                stack[base + instruction.a] =
                    floatValue!real(stack, base + instruction.b) >=
                    floatValue!real(stack, base + instruction.c) ? 1 : 0;
                ++ip;
                break;

            case addFloat:
                const ubyte[float.sizeof] sum = floatBytes(
                    floatValue!float(stack, base + instruction.b) +
                    floatValue!float(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = sum;
                ++ip;
                break;

            case addDouble:
                const ubyte[double.sizeof] sum = floatBytes(
                    floatValue!double(stack, base + instruction.b) +
                    floatValue!double(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = sum;
                ++ip;
                break;

            case subFloat:
                const ubyte[float.sizeof] difference = floatBytes(
                    floatValue!float(stack, base + instruction.b) -
                    floatValue!float(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = difference;
                ++ip;
                break;

            case divDouble:
                const ubyte[double.sizeof] quotient = floatBytes(
                    floatValue!double(stack, base + instruction.b) /
                    floatValue!double(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = quotient;
                ++ip;
                break;

            case subDouble:
                const ubyte[double.sizeof] difference = floatBytes(
                    floatValue!double(stack, base + instruction.b) -
                    floatValue!double(stack, base + instruction.c),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = difference;
                ++ip;
                break;

            case negateFloat:
                const ubyte[float.sizeof] negated = floatBytes(
                    -floatValue!float(stack, base + instruction.b),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = negated;
                ++ip;
                break;

            case negateDouble:
                const ubyte[double.sizeof] negated = floatBytes(
                    -floatValue!double(stack, base + instruction.b),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = negated;
                ++ip;
                break;

            case negateReal:
                const ubyte[real.sizeof] negated = floatBytes(
                    -floatValue!real(stack, base + instruction.b),
                );
                stack[base + instruction.a
                    .. base + instruction.a + real.sizeof] = negated;
                ++ip;
                break;

            case fabsFloat:
                import std.math: fabs;
                const ubyte[float.sizeof] result = floatBytes(
                    fabs(floatValue!float(stack, base + instruction.b)),
                );
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = result;
                ++ip;
                break;

            case fabsDouble:
                import std.math: fabs;
                const ubyte[double.sizeof] result = floatBytes(
                    fabs(floatValue!double(stack, base + instruction.b)),
                );
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = result;
                ++ip;
                break;

            case fabsReal:
                import std.math: fabs;
                const ubyte[real.sizeof] result = floatBytes(
                    fabs(floatValue!real(stack, base + instruction.b)),
                );
                stack[base + instruction.a
                    .. base + instruction.a + real.sizeof] = result;
                ++ip;
                break;

            case powFloat:
                import std.math: pow;
                // Round through float so the stored result matches a compiled
                // pow(float, float) byte-for-byte.
                const ubyte[float.sizeof] result = floatBytes(cast(float) pow(
                    floatValue!float(stack, base + instruction.b),
                    floatValue!float(stack, base + instruction.c),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = result;
                ++ip;
                break;

            case powDouble:
                import std.math: pow;
                const ubyte[double.sizeof] result = floatBytes(cast(double) pow(
                    floatValue!double(stack, base + instruction.b),
                    floatValue!double(stack, base + instruction.c),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = result;
                ++ip;
                break;

            case powDoubleToReal:
                import std.math: pow;
                const ubyte[real.sizeof] result = floatBytes(cast(real) pow(
                    floatValue!double(stack, base + instruction.b),
                    floatValue!double(stack, base + instruction.c),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + real.sizeof] = result;
                ++ip;
                break;

            case powReal:
                import std.math: pow;
                const ubyte[real.sizeof] result = floatBytes(pow(
                    floatValue!real(stack, base + instruction.b),
                    floatValue!real(stack, base + instruction.c),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + real.sizeof] = result;
                ++ip;
                break;

            case sqrtFloat:
                import std.math: sqrt;
                const ubyte[float.sizeof] result = floatBytes(cast(float) sqrt(
                    floatValue!float(stack, base + instruction.b),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + float.sizeof] = result;
                ++ip;
                break;

            case sqrtDouble:
                import std.math: sqrt;
                const ubyte[double.sizeof] result = floatBytes(cast(double) sqrt(
                    floatValue!double(stack, base + instruction.b),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + double.sizeof] = result;
                ++ip;
                break;

            case sqrtReal:
                import std.math: sqrt;
                const ubyte[real.sizeof] result = floatBytes(sqrt(
                    floatValue!real(stack, base + instruction.b),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + real.sizeof] = result;
                ++ip;
                break;

            case isNaNFloat:
                import std.math: isNaN;
                stack[base + instruction.a] =
                    isNaN(floatValue!float(stack, base + instruction.b))
                        ? 1
                        : 0;
                ++ip;
                break;

            case isNaNDouble:
                import std.math: isNaN;
                stack[base + instruction.a] =
                    isNaN(floatValue!double(stack, base + instruction.b))
                        ? 1
                        : 0;
                ++ip;
                break;

            case isNaNReal:
                import std.math: isNaN;
                stack[base + instruction.a] =
                    isNaN(floatValue!real(stack, base + instruction.b))
                        ? 1
                        : 0;
                ++ip;
                break;

            case isInfinityFloat:
                import std.math: isInfinity;
                stack[base + instruction.a] =
                    isInfinity(floatValue!float(stack, base + instruction.b))
                        ? 1
                        : 0;
                ++ip;
                break;

            case isInfinityDouble:
                import std.math: isInfinity;
                stack[base + instruction.a] =
                    isInfinity(floatValue!double(stack, base + instruction.b))
                        ? 1
                        : 0;
                ++ip;
                break;

            case isInfinityReal:
                import std.math: isInfinity;
                stack[base + instruction.a] =
                    isInfinity(floatValue!real(stack, base + instruction.b))
                        ? 1
                        : 0;
                ++ip;
                break;

            case signbitFloat:
                import std.math: signbit;
                const ubyte[int.sizeof] result = scalarBytes(cast(int) signbit(
                    floatValue!float(stack, base + instruction.b),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + int.sizeof] = result;
                ++ip;
                break;

            case signbitDouble:
                import std.math: signbit;
                const ubyte[int.sizeof] result = scalarBytes(cast(int) signbit(
                    floatValue!double(stack, base + instruction.b),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + int.sizeof] = result;
                ++ip;
                break;

            case signbitReal:
                import std.math: signbit;
                const ubyte[int.sizeof] result = scalarBytes(cast(int) signbit(
                    floatValue!real(stack, base + instruction.b),
                ));
                stack[base + instruction.a
                    .. base + instruction.a + int.sizeof] = result;
                ++ip;
                break;

            case equal1, equal2, equal4, equal8:
                const operandSize = equalOperandSize(instruction.op);
                stack[base + instruction.a] =
                    stack[base + instruction.b .. base + instruction.b + operandSize]
                    == stack[base + instruction.c .. base + instruction.c + operandSize];
                ++ip;
                break;

            case jump:
                ip = instruction.a;
                break;

            case jumpIfFalse:
                ip = stack[base + instruction.a] == 0 ? instruction.b : ip + 1;
                break;

            case jumpIfTrue:
                ip = stack[base + instruction.a] != 0 ? instruction.b : ip + 1;
                break;

            case classVirtualFunction:
                const objectPointer =
                    scalarValue!size_t(stack, base + instruction.b);
                const classIndex = objectPointer == 0
                    ? noExceptionClass
                    : objectClassIndex(objectPointer);
                writeScalar!size_t(
                    stack,
                    base + instruction.a,
                    virtualFunction(
                        program.classes, classIndex, instruction.c,
                    ),
                );
                ++ip;
                break;

            case classTypeInfo:
                const typeInfoObject = scalarValue!size_t(
                    stack, base + instruction.b,
                );
                const typeInfoClass = typeInfoObject == 0
                    ? noExceptionClass
                    : objectClassIndex(typeInfoObject);
                const nativeTypeInfo = typeInfoClass < program.classes.length
                    ? program.classes[typeInfoClass].nativeTypeInfo
                    : 0;
                writeScalar!size_t(
                    stack,
                    base + instruction.a,
                    nativeTypeInfo,
                );
                ++ip;
                break;

            case throwIfNullClassReference:
                if (scalarValue!size_t(stack, base + instruction.a) == 0)
                    throw new Exception(stringFromData(
                        program.data, instruction.b, instruction.c,
                    ));
                ++ip;
                break;

            case call, callIndirect, callIndirectDynamic:
                // A direct `call` carries the callee's function index in
                // `instruction.a`; an indirect `callIndirect`/
                // `callIndirectDynamic` reads it from the size_t slot at that
                // frame offset (the function-pointer or delegate value).
                const calleeIndex = instruction.op == call
                    ? instruction.a
                    : cast(ushort) scalarValue!size_t(
                        stack, base + instruction.a,
                    );

                if (program.functions[calleeIndex].code.length == 0)
                    compileFunction(calleeIndex);

                // `callIndirectDynamic` built its argument area from a
                // delegate-typed parameter's declared type alone, assuming a
                // pointer-sized context word; a struct-receiver callee needs
                // its whole receiver block there instead, so trusting that
                // convention would misread the context word as a bogus
                // caller-frame offset. Reject it rather than corrupt memory.
                if (instruction.op == callIndirectDynamic &&
                    program.functions[calleeIndex].hasThis)
                    throw new Exception(
                        "Unsupported delegate-parameter call in bytecode " ~
                        "core: the callee is a struct-receiver method",
                    );

                const calleeBase =
                    base + program.functions[functionIndex].frameSize;
                const callee = program.functions[calleeIndex];
                if (stack.length < calleeBase + callee.frameSize)
                    stack.length = calleeBase + callee.frameSize;

                stack[calleeBase .. calleeBase + callee.parameterBytes] =
                    stack[
                        base + instruction.b
                        .. base + instruction.b + callee.parameterBytes
                    ];

                // Each scalar `ref` parameter's slot currently holds the
                // caller-frame offset of its argument (copied with the rest of
                // the argument block). Record that offset for writeback on
                // return, then replace the slot with the referenced value.
                RefWriteback[] refWritebacks;
                foreach (refParameter; callee.refParameters) {
                    const valueSize = refParameter.valueSize;
                    const callerOffset = base + scalarValue!uint(
                        stack, calleeBase + refParameter.offset,
                    );
                    refWritebacks ~= RefWriteback(
                        callerOffset, refParameter.offset, valueSize,
                    );
                    stack[
                        calleeBase + refParameter.offset
                        .. calleeBase + refParameter.offset + valueSize
                    ] = stack[callerOffset .. callerOffset + valueSize];
                }

                // Mutable because execution advances each group's byte image.
                auto refAliases = refAliasGroups(
                    stack, refWritebacks, calleeBase,
                );

                frames ~= Frame(
                    functionIndex, ip + 1, base, instruction.c,
                    refWritebacks, refAliases,
                );
                functionIndex = calleeIndex;
                base = calleeBase;
                ip = 0;
                break;

            case nativeCall:
                import quickbite.frontend.dmd.functions:
                    noAvailableSourceMessage;
                import quickbite.ffi: callNative, callNativeClassMember;

                auto native = program.nativeCalls[instruction.a];
                auto marshaller = new BytecodeNativeMarshaller(
                    stack,
                    base + instruction.b,
                    base + instruction.c,
                    base,
                    native.outParameterOffsets,
                    native.nativeClassReceiverOffset,
                );
                bool[] addressOfLocalArguments;
                addressOfLocalArguments.length = native.outParameterOffsets.length;
                foreach (index, offset; native.outParameterOffsets)
                    addressOfLocalArguments[index] =
                        offset != noOutParameterOffset;
                const called = native.nativeClassReceiverType is null
                    ? callNative(
                        native.function_, marshaller, native.argumentTypes,
                        addressOfLocalArguments,
                    )
                    : callNativeClassMember(
                        native.function_, native.nativeClassReceiverType,
                        marshaller, native.argumentTypes,
                        addressOfLocalArguments,
                    );
                if (!called)
                    throw new Exception(noAvailableSourceMessage(
                        native.function_,
                    ));
                ++ip;
                break;

            case assertTrue:
                if (stack[base + instruction.a] == 0)
                    throw new Exception(assertMessage(
                        program.assertDiagnostics[instruction.b],
                        stack[base .. $],
                    ));

                ++ip;
                break;

            case assertTrueVerbatim:
                if (stack[base + instruction.a] == 0)
                    throw new Exception(
                        program.assertDiagnostics[instruction.b].operator,
                    );

                ++ip;
                break;

            case assertNonzeroInt4:
                // The operand width follows its scalar type: a `bool` is a
                // single frame byte, an `int` four. Reading only `size(type)`
                // bytes avoids treating a zero `bool` as nonzero because of
                // adjacent frame bytes.
                const nonzeroDiagnostic =
                    program.assertDiagnostics[instruction.b];
                if (isZeroSlot(
                        stack,
                        base + instruction.a,
                        size(nonzeroDiagnostic.operandType),
                    ))
                    throw new Exception(assertMessage(
                        nonzeroDiagnostic,
                        stack[base .. $],
                    ));

                ++ip;
                break;

            case halt:
                throw new Exception("Assertion failure");

            case haltUnittest:
                throw new Exception("unittest failure");

            case aaNew:
                maps ~= AssocArray.init;
                writeScalar!size_t(stack, base + instruction.a, maps.length);
                ++ip;
                break;

            case aaLength: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                const count = handle == 0 ? 0 : maps[handle - 1].count;
                writeScalar!size_t(stack, base + instruction.a, count);
                ++ip;
                break;
            }

            case aaInsert: {
                auto handle = scalarValue!size_t(stack, base + instruction.a);
                if (handle == 0) {
                    maps ~= AssocArray.init;
                    handle = maps.length;
                    writeScalar!size_t(stack, base + instruction.a, handle);
                }
                const width = instruction.d;
                const mode =
                    assocArrayKeyMode(instruction.e, program.assocArrayKeyLayouts);
                const keyWidth = mode.keyWidth;
                maps[handle - 1].insert(
                    stack[
                        base + instruction.b .. base + instruction.b + keyWidth
                    ],
                    mode.keyIsArray,
                    keyWidth,
                    stack[base + instruction.c .. base + instruction.c + width],
                    mode.layoutFields,
                );
                ++ip;
                break;
            }

            case aaGetOrInsert: {
                auto handle = scalarValue!size_t(stack, base + instruction.a);
                if (handle == 0) {
                    maps ~= AssocArray.init;
                    handle = maps.length;
                    writeScalar!size_t(stack, base + instruction.a, handle);
                }
                const width = instruction.d;
                const mode =
                    assocArrayKeyMode(instruction.e, program.assocArrayKeyLayouts);
                const keyWidth = mode.keyWidth;
                maps[handle - 1].insertDefault(
                    stack[
                        base + instruction.b .. base + instruction.b + keyWidth
                    ],
                    mode.keyIsArray,
                    keyWidth,
                    stack[base + instruction.c .. base + instruction.c + width],
                    mode.layoutFields,
                );
                ++ip;
                break;
            }

            case aaGetRvalue, aaIn: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                const width = instruction.d;
                const mode =
                    assocArrayKeyMode(instruction.e, program.assocArrayKeyLayouts);
                const keyWidth = mode.keyWidth;
                const key = stack[
                    base + instruction.c .. base + instruction.c + keyWidth
                ];
                auto slot = handle == 0
                    ? null
                    : maps[handle - 1].find(
                        key, mode.keyIsArray, keyWidth, width, mode.layoutFields,
                    );
                writeScalar!size_t(
                    stack, base + instruction.a, cast(size_t) slot,
                );
                ++ip;
                break;
            }

            case aaRemove: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                const width = instruction.d;
                const mode =
                    assocArrayKeyMode(instruction.e, program.assocArrayKeyLayouts);
                const keyWidth = mode.keyWidth;
                const key = stack[
                    base + instruction.c .. base + instruction.c + keyWidth
                ];
                const removed = handle != 0 && maps[handle - 1].remove(
                    key, mode.keyIsArray, keyWidth, width, mode.layoutFields,
                );
                writeScalar!bool(stack, base + instruction.a, removed);
                ++ip;
                break;
            }

            case aaEqual: {
                const left = scalarValue!size_t(stack, base + instruction.b);
                const right = scalarValue!size_t(stack, base + instruction.c);
                const width = instruction.d;
                const mode =
                    assocArrayKeyMode(instruction.e, program.assocArrayKeyLayouts);
                // Bound to named locals rather than passed as ternary
                // expressions directly: the ternary-argument shape crashes
                // this DMD version's code generator once `AssocArray` grew a
                // third field (`count`) -- reproduced in isolation; unrelated
                // to any of this function's own logic.
                const leftMap = left == 0 ? AssocArray.init : maps[left - 1];
                const rightMap =
                    right == 0 ? AssocArray.init : maps[right - 1];
                const equal = assocArrayEqual(
                    leftMap, rightMap, mode.keyIsArray, mode.keyWidth, width,
                    mode.layoutFields,
                );
                writeScalar!bool(stack, base + instruction.a, equal);
                ++ip;
                break;
            }

            case aaDup: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                maps ~= handle == 0
                    ? AssocArray.init : copyAssocArray(maps[handle - 1]);
                writeScalar!size_t(stack, base + instruction.a, maps.length);
                ++ip;
                break;
            }

            case aaKeys, aaValues: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                const outputElementSize =
                    instruction.c == 0 ? int.sizeof : instruction.c;
                const length = handle == 0
                    ? 0
                    : maps[handle - 1].count;
                auto block = new ubyte[](length * outputElementSize);
                if (handle != 0)
                    // The map's own keys/values are already packed at this
                    // exact stride (the compiler emits the same static
                    // key/value type width at every access site for a given
                    // map), so copy them verbatim rather than re-widening a
                    // narrower scalar.
                    block[] = instruction.op == aaKeys
                        ? maps[handle - 1].keys[]
                        : maps[handle - 1].values[];
                heap ~= block;
                writeSliceDescriptor(
                    stack, base + instruction.a, block, length,
                );
                ++ip;
                break;
            }

            case pushHandler:
                handlers ~= Handler(
                    functionIndex, base, frames.length, instruction.a,
                    instruction.b,
                );
                ++ip;
                break;

            case popHandler:
                handlers.length -= 1;
                ++ip;
                break;

            case throwString:
                const selected = selectHandler(
                    handlers,
                    program.catchClauses,
                    program.classes,
                    instruction.b,
                );
                if (!selected.matched)
                    throw new Exception(stringFromSlice(
                        stack,
                        base + instruction.a,
                    ));

                const handler = selected.handler;
                const clause = selected.clause;
                if (clause.objectOffset != noCatchObjectField) {
                    auto objectBlock = exceptionObjectFromString(
                        instruction.b,
                        stack,
                        base + instruction.a,
                        program.classes,
                    );
                    heap ~= objectBlock;
                    stack[
                        handler.base + clause.objectOffset
                        .. handler.base + clause.objectOffset
                            + size_t.sizeof
                    ] = scalarBytes(cast(size_t) objectBlock.ptr)[];
                }
                if (clause.messageOffset != noCatchObjectField)
                    writeStringSliceFromData(
                        stack,
                        handler.base + clause.messageOffset,
                        stack,
                        base + instruction.a,
                    );
                if (clause.nextMessageOffset != noCatchObjectField) {
                    if (instruction.c == noCatchObjectField)
                        stack[
                            handler.base + clause.nextMessageOffset
                            .. handler.base + clause.nextMessageOffset
                                + sliceDescriptorSize
                        ] = 0;
                    else
                        writeStringSliceFromData(
                            stack,
                            handler.base + clause.nextMessageOffset,
                            stack,
                            base + instruction.c,
                        );
                }
                writeBackUnwoundFrames(
                    stack, frames, base, handler.frameDepth,
                );
                functionIndex = handler.functionIndex;
                base = handler.base;
                ip = clause.handlerIp;
                break;

            case throwObject:
                const objectPointer =
                    scalarValue!size_t(stack, base + instruction.a);
                const classIndex = objectPointer == 0
                    ? noExceptionClass
                    : objectClassIndex(objectPointer);
                const selected = selectHandler(
                    handlers,
                    program.catchClauses,
                    program.classes,
                    classIndex,
                );
                if (!selected.matched)
                    throw new Exception(exceptionMessage(
                        objectPointer, program.classes,
                    ));

                const handler = selected.handler;
                const clause = selected.clause;
                if (clause.objectOffset != noCatchObjectField)
                    stack[
                        handler.base + clause.objectOffset
                        .. handler.base + clause.objectOffset
                            + size_t.sizeof
                    ] = scalarBytes(objectPointer)[];
                if (clause.messageOffset != noCatchObjectField)
                    writeStringSliceFromObject(
                        stack,
                        handler.base + clause.messageOffset,
                        objectPointer,
                        program.classes,
                    );
                if (clause.nextMessageOffset != noCatchObjectField)
                    stack[
                        handler.base + clause.nextMessageOffset
                        .. handler.base + clause.nextMessageOffset
                            + sliceDescriptorSize
                    ] = 0;
                writeBackUnwoundFrames(
                    stack, frames, base, handler.frameDepth,
                );
                functionIndex = handler.functionIndex;
                base = handler.base;
                ip = clause.handlerIp;
                break;

            case transcodeUtf: {
                auto block = transcodeUtfString(
                    stack, base + instruction.c, instruction.b,
                );
                heap ~= block.elements;
                writeSliceDescriptor(
                    stack, base + instruction.a, block.elements, block.length,
                );
                ++ip;
                break;
            }

            case ret:
                const resultSize =
                    size(program.functions[functionIndex].returnType);
                if (frames.length == 0)
                    return RunResult(
                        stack[
                            base + instruction.a
                            .. base + instruction.a + resultSize
                        ].dup,
                        heap,
                    );

                const frame = frames[$ - 1];
                frames.length -= 1;

                writeBackRefParameters(stack, frame, base);

                stack[
                    frame.base + frame.destination
                    .. frame.base + frame.destination + resultSize
                ] = stack[
                    base + instruction.a .. base + instruction.a + resultSize
                ];
                functionIndex = frame.functionIndex;
                base = frame.base;
                ip = frame.ip;
                break;
            }
        } catch (RangeError error) {
            const selected = selectHandler(
                handlers,
                program.catchClauses,
                program.classes,
                program.rangeErrorClass,
            );
            if (!selected.matched)
                throw error;

            const handler = selected.handler;
            const clause = selected.clause;
            if (clause.objectOffset != noCatchObjectField)
                throw error;
            writeBackUnwoundFrames(stack, frames, base, handler.frameDepth);
            functionIndex = handler.functionIndex;
            base = handler.base;
            ip = clause.handlerIp;
        }
    }
}

private void writeBackUnwoundFrames(
    ubyte[] stack,
    ref Frame[] frames,
    size_t base,
    in size_t frameDepth,
) {
    size_t calleeBase = base;
    while (frames.length > frameDepth) {
        const frame = frames[$ - 1];
        writeBackRefParameters(stack, frame, calleeBase);
        frames.length -= 1;
        calleeBase = frame.base;
    }
}

private void writeBackRefParameters(
    ubyte[] stack,
    in Frame frame,
    in size_t calleeBase,
) {
    foreach (writeback; frame.refWritebacks)
        stack[
            writeback.callerOffset .. writeback.callerOffset + writeback.size
        ] = stack[
            calleeBase + writeback.calleeOffset
            .. calleeBase + writeback.calleeOffset + writeback.size
        ];
}

private SelectedHandler selectHandler(
    ref Handler[] handlers,
    in imported!"quickbite.backends.bytecode.core.program".CatchClause[]
        clauses,
    in imported!"quickbite.backends.bytecode.core.program".ClassInfo[] classes,
    in ushort thrownClass,
) @safe {
    while (handlers.length != 0) {
        const handler = handlers[$ - 1];
        handlers.length -= 1;
        foreach (index; 0 .. handler.catchCount) {
            const clause = clauses[handler.catchStart + index];
            if (classMatches(thrownClass, clause.catchClass, classes))
                return SelectedHandler(true, handler, clause);
        }
    }

    return SelectedHandler.init;
}

private bool classMatches(
    in ushort thrownClass,
    in ushort catchClass,
    in imported!"quickbite.backends.bytecode.core.program".ClassInfo[] classes,
) @safe {
    import quickbite.backends.bytecode.core.program: noExceptionClass;

    if (thrownClass == noExceptionClass)
        return catchClass == noExceptionClass;
    if (catchClass == noExceptionClass)
        return true;

    ushort current = thrownClass;
    while (current != noExceptionClass) {
        if (current == catchClass)
            return true;
        if (current >= classes.length)
            return false;
        current = classes[current].baseClass;
    }

    return false;
}

private ushort virtualFunction(
    in imported!"quickbite.backends.bytecode.core.program".ClassInfo[] classes,
    in ushort classIndex,
    in ushort baseFunction,
) @safe {
    import quickbite.backends.bytecode.core.program: noExceptionClass;

    if (classIndex == noExceptionClass || classIndex >= classes.length)
        return baseFunction;

    foreach (candidate; classes[classIndex].virtualFunctions)
        if (candidate.baseFunction == baseFunction)
            return candidate.function_;

    return baseFunction;
}

// Decode/transcode the string slice descriptor at `sourceOffset` per `mode`
// into a fresh heap block of target code units, mirroring druntime's `_aApply*`
// foreach helpers. Returns the block (for rooting in `heap`) and the element
// count. The source descriptor is a native {ptr, length}; `length` is the
// source code-unit count, scaled by the mode's source element size.
private auto transcodeUtfString(
    in ubyte[] stack,
    in size_t sourceOffset,
    in ushort mode,
) @trusted {
    import quickbite.backends.bytecode.core.program: TranscodeMode;
    import std.utf: decode, encode;

    struct Block { ubyte[] elements; size_t length; }

    const pointer = scalarValue!size_t(stack, sourceOffset);
    const length = scalarValue!size_t(stack, sourceOffset + size_t.sizeof);

    // dchar elements (the decode targets) are 4 bytes; char elements (the
    // encode target) are 1 byte.
    ubyte[] result;
    size_t count;

    void appendDchar(in dchar value) {
        auto encoded = new ubyte[](dchar.sizeof);
        writeScalar!uint(encoded, 0, cast(uint) value);
        result ~= encoded;
        ++count;
    }

    with (TranscodeMode) final switch (cast(TranscodeMode) mode) {
        case utf8ToDchar:
            auto source =
                cast(const(char)[]) (cast(const(ubyte)*) pointer)[0 .. length];
            for (size_t index; index < source.length;)
                appendDchar(decode(source, index));
            break;

        case utf16ToDchar, utf16ToDcharReverse:
            auto units =
                (cast(const(wchar)*) pointer)[0 .. length];
            auto source = units.idup;
            dchar[] decoded;
            for (size_t index; index < source.length;)
                decoded ~= decode(source, index);
            if (cast(TranscodeMode) mode == utf16ToDcharReverse) {
                import std.algorithm: reverse;
                decoded.reverse;
            }
            foreach (value; decoded)
                appendDchar(value);
            break;

        case dcharToUtf8:
            auto source =
                (cast(const(dchar)*) pointer)[0 .. length];
            foreach (value; source) {
                char[4] encoded;
                const used = encode(encoded, value);
                foreach (unit; encoded[0 .. used]) {
                    result ~= cast(ubyte) unit;
                    ++count;
                }
            }
            break;
    }

    return Block(result, count);
}

// `offset` holds an ordinary {ptr, length} descriptor, so the string's bytes
// are read straight through the pointer, exactly like any other array read.
// Safe because `pointer`/`length` were themselves produced by the VM's own
// slice-descriptor writers (heap allocation or the program's data segment),
// never by untrusted input, so the read stays within a block the VM itself
// owns.
private string stringFromSlice(
    in ubyte[] stack,
    in size_t offset,
) @trusted pure {
    const pointer = scalarValue!size_t(stack, offset);
    const length = scalarValue!size_t(stack, offset + size_t.sizeof);
    return (cast(const(char)*) pointer)[0 .. length].idup;
}

private string stringFromData(
    in ubyte[] data,
    in size_t dataOffset,
    in size_t length,
) @safe pure {
    return (cast(const(char)[]) data[dataOffset .. dataOffset + length]).idup;
}

private string exceptionMessage(
    in size_t objectPointer,
    in imported!"quickbite.backends.bytecode.core.program".ClassInfo[] classes,
) @trusted {
    if (objectPointer == 0)
        return "null";

    const object = cast(const(ubyte)*) objectPointer;
    const classIndex = objectScalarValue!size_t(object);
    if (classIndex >= classes.length ||
        classes[classIndex].msgOffset == ushort.max)
        return "Uncaught exception";

    return stringFromObjectSlice(object + classes[classIndex].msgOffset);
}

private ubyte[] exceptionObjectFromString(
    in ushort classIndex,
    in ubyte[] source,
    in size_t sourceOffset,
    in imported!"quickbite.backends.bytecode.core.program".ClassInfo[] classes,
) @trusted {
    import quickbite.backends.bytecode.core.program: sliceDescriptorSize;

    const messageOffset = classIndex < classes.length &&
        classes[classIndex].msgOffset != ushort.max
        ? classes[classIndex].msgOffset
        : cast(ushort) size_t.sizeof;
    auto object = new ubyte[](messageOffset + sliceDescriptorSize);
    object[0 .. size_t.sizeof] = scalarBytes(cast(size_t) classIndex)[];
    object[messageOffset .. messageOffset + sliceDescriptorSize] =
        source[sourceOffset .. sourceOffset + sliceDescriptorSize];
    return object;
}

private ushort objectClassIndex(in size_t objectPointer) @trusted {
    return cast(ushort) objectScalarValue!size_t(cast(const(ubyte)*) objectPointer);
}

private string stringFromObjectSlice(in ubyte* descriptor) @trusted {
    const pointer = objectScalarValue!size_t(descriptor);
    const length = objectScalarValue!size_t(descriptor + size_t.sizeof);
    return (cast(const(char)*) pointer)[0 .. length].idup;
}

private void writeStringSliceFromObject(
    ref ubyte[] destination,
    in size_t destinationOffset,
    in size_t objectPointer,
    in imported!"quickbite.backends.bytecode.core.program".ClassInfo[] classes,
) @trusted {
    import quickbite.backends.bytecode.core.program: sliceDescriptorSize;

    if (objectPointer == 0)
        return;

    const object = cast(const(ubyte)*) objectPointer;
    const classIndex = objectScalarValue!size_t(object);
    if (classIndex >= classes.length ||
        classes[classIndex].msgOffset == ushort.max)
        return;

    const descriptor = object + classes[classIndex].msgOffset;
    destination[
        destinationOffset .. destinationOffset + sliceDescriptorSize
    ] = descriptor[0 .. sliceDescriptorSize];
}

// Copy a real {ptr, length} string descriptor into a frame slot.
private void writeStringSliceFromData(
    ref ubyte[] destination,
    in size_t destinationOffset,
    in ubyte[] source,
    in size_t sourceOffset,
) @safe {
    import quickbite.backends.bytecode.core.program: sliceDescriptorSize;

    destination[
        destinationOffset .. destinationOffset + sliceDescriptorSize
    ] = source[sourceOffset .. sourceOffset + sliceDescriptorSize];
}

// Write a slice descriptor {ptr, length} at `offset`: the heap block's native
// address followed by the element count, each a little-endian size_t.
private void writeSliceDescriptor(
    ref ubyte[] stack,
    in size_t offset,
    in ubyte[] block,
    in size_t length,
) @trusted {
    import std.bitmanip: nativeToLittleEndian;
    import quickbite.backends.bytecode.core.program:
        sliceDescriptorLengthOffset, sliceDescriptorPtrOffset;

    const ptrOffset = sliceDescriptorPtrOffset(offset);
    const lengthOffset = sliceDescriptorLengthOffset(offset);
    stack[ptrOffset .. ptrOffset + size_t.sizeof] =
        nativeToLittleEndian(cast(size_t) block.ptr);
    stack[lengthOffset .. lengthOffset + size_t.sizeof] =
        nativeToLittleEndian(length);
}

// Write a heap block's native address as a raw `size_t` pointer word at
// `offset` (a `new S` struct pointer slot); the block is rooted in `heap`, so
// it stays alive while field access reads and writes it through the pointer.
private void writeBlockPointer(
    ref ubyte[] stack,
    in size_t offset,
    in ubyte[] block,
) @trusted {
    import std.bitmanip: nativeToLittleEndian;

    stack[offset .. offset + size_t.sizeof] =
        nativeToLittleEndian(cast(size_t) block.ptr);
}

private void writeRawPointer(
    ref ubyte[] stack,
    in size_t offset,
    in size_t pointer,
) @safe {
    import std.bitmanip: nativeToLittleEndian;

    stack[offset .. offset + size_t.sizeof] = nativeToLittleEndian(pointer);
}

// Write the native address of the frame slot at `slotOffset` as a raw `size_t`
// pointer word into `offset`. Backs `&local`; the stack's reserved capacity
// keeps the address valid across the calls that grow the stack.
private void writeFrameAddress(
    ref ubyte[] stack,
    in size_t offset,
    in size_t slotOffset,
) @trusted {
    import std.bitmanip: nativeToLittleEndian;

    stack[offset .. offset + size_t.sizeof] =
        nativeToLittleEndian(cast(size_t) &stack[slotOffset]);
}

// Write a slice descriptor {ptr, length} at `offset` from an already-computed
// native pointer (a sub-slice into an existing block), rather than a fresh
// heap block. The backing memory is rooted by the original block's `heap`
// entry, so the sub-slice shares and stays alive through that root.
private void writeSliceDescriptorPointer(
    ref ubyte[] stack,
    in size_t offset,
    in size_t pointer,
    in size_t length,
) @safe {
    import std.bitmanip: nativeToLittleEndian;
    import quickbite.backends.bytecode.core.program:
        sliceDescriptorLengthOffset, sliceDescriptorPtrOffset;

    const ptrOffset = sliceDescriptorPtrOffset(offset);
    const lengthOffset = sliceDescriptorLengthOffset(offset);
    stack[ptrOffset .. ptrOffset + size_t.sizeof] = nativeToLittleEndian(pointer);
    stack[lengthOffset .. lengthOffset + size_t.sizeof] =
        nativeToLittleEndian(length);
}

private void validateSubSlice(
    in ubyte[] stack,
    in size_t sourceOffset,
    in size_t lo,
    in size_t hi,
) @safe {
    import std.conv: text;

    if (lo > hi)
        throw new Exception(text(
            "slice [", lo, " .. ", hi,
            "] has a larger lower index than upper index",
        ));

    const length = scalarValue!size_t(
        stack,
        sourceOffset + size_t.sizeof,
    );
    if (hi > length)
        throw new Exception(text(
            "slice [", lo, " .. ", hi,
            "] extends past source array of length ", length,
        ));
}

// Duplicate the slice descriptor at `sourceOffset` into a fresh heap block
// holding an independent copy of its elements, and write the descriptor
// {newPtr, length} at `descriptorOffset`. Returns the new block so the caller
// can root it in `heap`.
private ubyte[] dupArray(
    ref ubyte[] stack,
    in size_t descriptorOffset,
    in size_t sourceOffset,
    in uint elementSize,
) @trusted {
    const length = scalarValue!size_t(stack, sourceOffset + size_t.sizeof);
    const pointer = scalarValue!size_t(stack, sourceOffset);
    const byteCount = length * elementSize;

    auto block = new ubyte[](byteCount);
    block[] = (cast(const(ubyte)*) pointer)[0 .. byteCount];

    writeSliceDescriptor(stack, descriptorOffset, block, length);
    return block;
}

// Concatenate the slice descriptors at `leftOffset` and `rightOffset` into a
// fresh heap block of `len(left) + len(right)` elements, copying both operands'
// elements in order, and write the descriptor {newPtr, total} at
// `descriptorOffset`. Returns the new block so the caller can root it in `heap`.
// Both operands are copied, leaving the originals untouched.
private ubyte[] concatArrays(
    ref ubyte[] stack,
    in size_t descriptorOffset,
    in size_t leftOffset,
    in size_t rightOffset,
    in uint elementSize,
) @trusted {
    const leftLength = scalarValue!size_t(stack, leftOffset + size_t.sizeof);
    const rightLength = scalarValue!size_t(stack, rightOffset + size_t.sizeof);
    const leftPointer = scalarValue!size_t(stack, leftOffset);
    const rightPointer = scalarValue!size_t(stack, rightOffset);
    const leftBytes = leftLength * elementSize;
    const rightBytes = rightLength * elementSize;

    auto block = new ubyte[](leftBytes + rightBytes);
    block[0 .. leftBytes] =
        (cast(const(ubyte)*) leftPointer)[0 .. leftBytes];
    block[leftBytes .. leftBytes + rightBytes] =
        (cast(const(ubyte)*) rightPointer)[0 .. rightBytes];

    writeSliceDescriptor(
        stack, descriptorOffset, block, leftLength + rightLength,
    );
    return block;
}

private extern(C) bool gc_expandArrayUsed(
    void[] slice,
    size_t newUsed,
    bool atomic,
) pure nothrow;

// Append the element at `elementOffset` to the slice descriptor at
// `descriptorOffset`. Use druntime's appendable-block bookkeeping first so a
// prior `reserve` can grow the slice in place; otherwise allocate and copy.
// `appendablePointers` is keyed by the backing block's base address (from
// `GC.query`, which resolves an interior pointer to its block), not the
// descriptor's own pointer, so a later append through an interior slice (e.g.
// `arr[2 .. $]`) recognises the same block a prior append already proved
// appendable and grows in place too; `gc_expandArrayUsed` itself (real
// druntime bookkeeping) still refuses if the slice is not at the block's used
// boundary. Returns the resulting block so the caller can root it in `heap`.
private ubyte[] appendElement(
    ref ubyte[] stack,
    in size_t descriptorOffset,
    in size_t elementOffset,
    in uint elementSize,
    in ubyte[][] heap,
    ref size_t[] appendablePointers,
) @trusted {
    import core.memory: GC;

    const length = scalarValue!size_t(stack, descriptorOffset + size_t.sizeof);
    const pointer = scalarValue!size_t(stack, descriptorOffset);
    const oldBytes = length * elementSize;
    const newBytes = (length + 1) * elementSize;
    const blockInfo = GC.query(cast(void*) pointer);
    const blockBase = cast(size_t) blockInfo.base;
    const canGrowInPlace = containsPointer(appendablePointers, blockBase) ||
        (!heapContainsPointer(heap, pointer) &&
            (blockInfo.attr & GC.BlkAttr.APPENDABLE) != 0);

    if (pointer != 0 &&
        canGrowInPlace &&
        gc_expandArrayUsed(
            (cast(void*) pointer)[0 .. oldBytes], newBytes, false)) {
        if (!containsPointer(appendablePointers, blockBase))
            appendablePointers ~= blockBase;
        auto block = (cast(ubyte*) pointer)[0 .. newBytes];
        block[oldBytes .. newBytes] =
            stack[elementOffset .. elementOffset + elementSize];
        writeSliceDescriptor(stack, descriptorOffset, block, length + 1);
        return block;
    }

    auto block = new ubyte[](newBytes);
    const source = (cast(const(ubyte)*) pointer)[0 .. oldBytes];
    block[0 .. oldBytes] = source[];
    block[oldBytes .. newBytes] =
        stack[elementOffset .. elementOffset + elementSize];

    writeSliceDescriptor(stack, descriptorOffset, block, length + 1);
    return block;
}

private bool heapContainsPointer(in ubyte[][] heap, in size_t pointer)
    @trusted @nogc nothrow pure
{
    foreach (block; heap) {
        const begin = cast(size_t) block.ptr;
        if (pointer >= begin && pointer < begin + block.length)
            return true;
    }
    return false;
}

private bool containsPointer(in size_t[] pointers, in size_t pointer)
    @safe @nogc nothrow pure
{
    foreach (candidate; pointers)
        if (candidate == pointer)
            return true;
    return false;
}

// Resize the dynamic array at `descriptorOffset` to `newLength` elements
// (`arr.length = n`). A fresh block is allocated, the `min(oldLength, newLength)`
// existing elements copied in, and any growth filled with the element's
// default-init byte; the descriptor is overwritten with {newPtr, newLength}.
// Returns the new block so the caller can root it in `heap`.
private ubyte[] resizeArray(
    ref ubyte[] stack,
    in size_t descriptorOffset,
    in uint elementSize,
    in ubyte fill,
    in size_t newLength,
) @trusted {
    import std.algorithm.comparison: min;

    const oldLength = scalarValue!size_t(stack, descriptorOffset + size_t.sizeof);
    const pointer = scalarValue!size_t(stack, descriptorOffset);

    auto block = new ubyte[](newLength * elementSize);
    block[] = fill;
    const keptBytes = min(oldLength, newLength) * elementSize;
    block[0 .. keptBytes] = (cast(const(ubyte)*) pointer)[0 .. keptBytes];

    writeSliceDescriptor(stack, descriptorOffset, block, newLength);
    return block;
}

// Resize an array of aggregates whose default initializer is a non-uniform
// byte block. Existing elements are retained while each newly grown element is
// copied from the compiler-materialized `T.init` template in the current frame.
private ubyte[] resizeArrayWithTemplate(
    ref ubyte[] stack,
    in size_t descriptorOffset,
    in size_t templateOffset,
    in uint elementSize,
    in size_t newLength,
) @trusted {
    import std.algorithm.comparison: min;

    const oldLength = scalarValue!size_t(stack, descriptorOffset + size_t.sizeof);
    const pointer = scalarValue!size_t(stack, descriptorOffset);
    auto block = new ubyte[](newLength * elementSize);
    const keptBytes = min(oldLength, newLength) * elementSize;
    block[0 .. keptBytes] = (cast(const(ubyte)*) pointer)[0 .. keptBytes];
    foreach (index; oldLength .. newLength)
        block[index * elementSize .. (index + 1) * elementSize] =
            stack[templateOffset .. templateOffset + elementSize];

    writeSliceDescriptor(stack, descriptorOffset, block, newLength);
    return block;
}

// True iff the two slice descriptors hold the same length and identical element
// bytes.
private bool slicesEqual(
    in ubyte[] stack,
    in size_t leftOffset,
    in size_t rightOffset,
    in uint elementSize,
) @trusted {
    const leftLength = scalarValue!size_t(stack, leftOffset + size_t.sizeof);
    const rightLength = scalarValue!size_t(stack, rightOffset + size_t.sizeof);
    if (leftLength != rightLength)
        return false;

    const leftPointer = scalarValue!size_t(stack, leftOffset);
    const rightPointer = scalarValue!size_t(stack, rightOffset);
    const byteCount = leftLength * elementSize;
    return (cast(const(ubyte)*) leftPointer)[0 .. byteCount] ==
        (cast(const(ubyte)*) rightPointer)[0 .. byteCount];
}

// True iff two array-of-arrays descriptors are structurally equal, at any
// nesting `depth` (2 for `int[][]`, 3 for `int[][][]`, ...): same outer
// length, and every row (itself a 16-byte `{ptr, length}` slice descriptor,
// separately heap-allocated on each side) recursively equal one level
// deeper, down to the innermost row's element bytes (`innerElementSize`
// each). Unlike `slicesEqual`, this never compares a row's raw descriptor
// bytes -- two separately-constructed but content-equal rows have different
// `.ptr` values, so that would compare identity, not content. `depth == 2`
// (the original, one-level-only shape) reduces to a single row iteration
// with an immediate byte compare, unchanged from before.
private bool nestedSlicesEqual(
    in ubyte[] stack,
    in size_t leftOffset,
    in size_t rightOffset,
    in uint depth,
    in uint innerElementSize,
) @trusted {
    const leftLength = scalarValue!size_t(stack, leftOffset + size_t.sizeof);
    const rightLength = scalarValue!size_t(stack, rightOffset + size_t.sizeof);
    if (leftLength != rightLength)
        return false;

    const leftPointer = scalarValue!size_t(stack, leftOffset);
    const rightPointer = scalarValue!size_t(stack, rightOffset);
    return nestedRowsEqual(
        leftPointer, rightPointer, leftLength, depth - 1, innerElementSize,
    );
}

// Compares `length` paired left/right elements starting at the two raw
// pointers, `stepsRemaining` row-descriptor levels above the innermost
// element bytes. At `stepsRemaining == 0` the pointers already address
// plain element bytes (a scalar/string row, or a struct/static-array row --
// whatever `innerElementSize` measures) and this is a flat byte compare:
// the base case, identical to `nestedSlicesEqual`'s original one-level
// body. Otherwise each of the `length` elements is itself a 16-byte
// `{ptr, length}` row descriptor -- independently lengthed, since arrays
// can be ragged at every level -- so each row's own length is checked
// before recursing one level deeper into it.
private bool nestedRowsEqual(
    in size_t leftPointer,
    in size_t rightPointer,
    in size_t length,
    in uint stepsRemaining,
    in uint innerElementSize,
) @trusted {
    import quickbite.backends.bytecode.core.program: sliceDescriptorSize;

    if (stepsRemaining == 0) {
        const byteCount = length * innerElementSize;
        return (cast(const(ubyte)*) leftPointer)[0 .. byteCount] ==
            (cast(const(ubyte)*) rightPointer)[0 .. byteCount];
    }

    foreach (index; 0 .. length) {
        const leftRow = leftPointer + index * sliceDescriptorSize;
        const rightRow = rightPointer + index * sliceDescriptorSize;

        const leftRowLength =
            *cast(const(size_t)*) (leftRow + size_t.sizeof);
        const rightRowLength =
            *cast(const(size_t)*) (rightRow + size_t.sizeof);
        if (leftRowLength != rightRowLength)
            return false;

        const leftRowPointer = *cast(const(size_t)*) leftRow;
        const rightRowPointer = *cast(const(size_t)*) rightRow;
        if (!nestedRowsEqual(
            leftRowPointer, rightRowPointer, leftRowLength,
            stepsRemaining - 1, innerElementSize,
        ))
            return false;
    }
    return true;
}

// Copy the source slice's elements into the destination slice's backing
// memory, write-through. The lengths must match; overlapping ranges abort with
// druntime's plain "Range violation" message.
private void copySlice(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t sourceOffset,
    in uint elementSize,
) @trusted {
    import std.conv: text;

    const destinationPointer = scalarValue!size_t(stack, destinationOffset);
    const destinationLength =
        scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    const sourcePointer = scalarValue!size_t(stack, sourceOffset);
    const sourceLength =
        scalarValue!size_t(stack, sourceOffset + size_t.sizeof);

    if (destinationLength != sourceLength)
        throw new Exception(text(
            "Array lengths don't match for copy: ",
            sourceLength, " != ", destinationLength,
        ));

    // D permits an empty slice assignment through a null pointer: no element
    // address is formed, so neither null descriptor is dereferenced.
    if (destinationLength == 0)
        return;

    const byteCount = destinationLength * elementSize;
    if (sourcePointer < destinationPointer + byteCount &&
        destinationPointer < sourcePointer + byteCount)
        throw new Exception("Range violation");

    auto destination = (cast(ubyte*) destinationPointer)[0 .. byteCount];
    const source = (cast(const(ubyte)*) sourcePointer)[0 .. byteCount];
    destination[] = source[];
}

// Copy a range of `T[N][]` rows: write each source row's `rowByteSize`
// bytes of content into the matching destination row's own existing
// heap-allocated block, one row at a time. The destination and source
// "elements" here are 16-byte `{ptr, length}` row descriptors pointing at
// separately heap-allocated `T[N]` blocks (this VM's `T[N][]` row
// representation, not compiled D's contiguous layout -- see "Live hazards
// and divergences" in ai/plans/bytecode.md), so `copySlice`'s flat by-value
// descriptor copy would alias every destination row to the source's block
// instead of writing into each row's own storage. The lengths must match,
// matching `copySlice`'s check and message.
private void copyRowRange(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t sourceOffset,
    in uint rowByteSize,
) @trusted {
    import std.conv: text;
    import quickbite.backends.bytecode.core.program: sliceDescriptorSize;

    const destinationPointer = scalarValue!size_t(stack, destinationOffset);
    const destinationLength =
        scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    const sourcePointer = scalarValue!size_t(stack, sourceOffset);
    const sourceLength =
        scalarValue!size_t(stack, sourceOffset + size_t.sizeof);

    if (destinationLength != sourceLength)
        throw new Exception(text(
            "Array lengths don't match for copy: ",
            sourceLength, " != ", destinationLength,
        ));

    // The row *blocks* pointed at by each 16-byte slot never overlap (each
    // is its own separate heap allocation), but the two ranges of row
    // *slots* -- 16 bytes apiece, contiguous in the same outer backing
    // array -- can, exactly as compiled D's contiguous `T[N][]` rows would
    // (`arr[0 .. 2] = arr[1 .. 3]`): matches `copySlice`'s overlap check
    // and "Range violation" message on that outer slot memory.
    const outerByteCount = destinationLength * sliceDescriptorSize;
    if (sourcePointer < destinationPointer + outerByteCount &&
        destinationPointer < sourcePointer + outerByteCount)
        throw new Exception("Range violation");

    foreach (i; 0 .. destinationLength) {
        const destRowPointer = *cast(const(size_t)*)
            (destinationPointer + i * sliceDescriptorSize);
        const sourceRowPointer = *cast(const(size_t)*)
            (sourcePointer + i * sliceDescriptorSize);
        auto destRow = (cast(ubyte*) destRowPointer)[0 .. rowByteSize];
        const sourceRow =
            (cast(const(ubyte)*) sourceRowPointer)[0 .. rowByteSize];
        destRow[] = sourceRow[];
    }
}

// The compiler supplies a valid native slice descriptor and a 1-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice1(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const destinationPointer =
        scalarValue!size_t(stack, destinationOffset);
    const destinationLength =
        scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    auto destination = (cast(ubyte*) destinationPointer)[0 .. destinationLength];
    destination[] = scalarValue!ubyte(stack, valueOffset);
}

// The compiler supplies a valid native slice descriptor and a 2-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice2(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const destinationPointer =
        scalarValue!size_t(stack, destinationOffset);
    const destinationLength =
        scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    auto destination = (cast(ushort*) destinationPointer)[0 .. destinationLength];
    destination[] = scalarValue!ushort(stack, valueOffset);
}

// The compiler supplies a valid native slice descriptor and a 4-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice4(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const destinationPointer =
        scalarValue!size_t(stack, destinationOffset);
    const destinationLength =
        scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    auto destination = (cast(uint*) destinationPointer)[0 .. destinationLength];
    destination[] = scalarValue!uint(stack, valueOffset);
}

// The compiler supplies a valid native slice descriptor and an 8-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice8(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const destinationPointer =
        scalarValue!size_t(stack, destinationOffset);
    const destinationLength =
        scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    auto destination = (cast(ulong*) destinationPointer)[0 .. destinationLength];
    destination[] = scalarValue!ulong(stack, valueOffset);
}

// Same as `fillSlice1`/etc, for an element width not covered by a fixed
// opcode (a struct or static-array element): broadcast the source's own
// `elementSize` bytes into each destination element, byte for byte, the way
// compiled D's array-fill lowering does for a non-scalar element.
private void fillSliceN(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
    in uint elementSize,
) @trusted {
    const destinationPointer =
        scalarValue!size_t(stack, destinationOffset);
    const destinationLength =
        scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    auto destination =
        (cast(ubyte*) destinationPointer)[0 .. destinationLength * elementSize];
    const source = stack[valueOffset .. valueOffset + elementSize];
    foreach (i; 0 .. destinationLength)
        destination[i * elementSize .. (i + 1) * elementSize] = source;
}

// Element-wise `dest[] = left[] + right[]` over 4-byte integer elements,
// writing each sum through the destination's backing memory. All three lengths
// must match (`dest[] = a[] + b[]` requires equal lengths).
private void applyArrayAddAssign4(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t leftOffset,
    in size_t rightOffset,
) @trusted {
    import std.conv: text;

    const length = scalarValue!size_t(stack, destinationOffset + size_t.sizeof);
    const leftLength = scalarValue!size_t(stack, leftOffset + size_t.sizeof);
    const rightLength = scalarValue!size_t(stack, rightOffset + size_t.sizeof);
    if (leftLength != length || rightLength != length)
        throw new Exception(text(
            "Array lengths don't match for array operation: ",
            length, ", ", leftLength, ", ", rightLength,
        ));

    auto destination = cast(int*) scalarValue!size_t(stack, destinationOffset);
    const left = cast(const(int)*) scalarValue!size_t(stack, leftOffset);
    const right = cast(const(int)*) scalarValue!size_t(stack, rightOffset);
    foreach (index; 0 .. length)
        destination[index] = left[index] + right[index];
}

// Throw druntime's array-bounds message if `index` is not less than
// `length`. The single check `elementAddress` (slice-descriptor indexing)
// and `Op.checkStaticArrayIndex` (static-array indexing) both call, so every
// bounds failure raises byte-for-byte the same diagnostic.
private void enforceIndexInBounds(in size_t index, in size_t length) @safe pure {
    import core.exception: ArrayIndexError;

    if (index >= length)
        throw new ArrayIndexError(index, length);
}

// The native address of element `index` within the slice descriptor at
// `descriptorOffset`, bounds checked against the descriptor's length word.
private ubyte* elementAddress(
    in ubyte[] stack,
    in size_t descriptorOffset,
    in size_t index,
    in uint elementSize,
) @trusted {
    const length = scalarValue!size_t(stack, descriptorOffset + size_t.sizeof);
    enforceIndexInBounds(index, length);

    const pointer = scalarValue!size_t(stack, descriptorOffset);
    return cast(ubyte*) (pointer + index * elementSize);
}

private void readHeapElement(ubyte[] destination, in ubyte* element)
    @trusted
{
    destination[] = element[0 .. destination.length];
}

// @trusted: `atomicLoad` reads exactly one aligned machine word from the raw
// address produced by VM pointer operations; the recognised inline-asm source
// has already restricted this use to a 4- or 8-byte atomic load.
private uint atomicLoadDword(in const(ubyte)* address) @trusted {
    import core.atomic: atomicLoad;

    return atomicLoad(*cast(shared(uint)*) address);
}

private ulong atomicLoadWord(in const(ubyte)* address) @trusted {
    import core.atomic: atomicLoad;

    return cast(ulong) atomicLoad(*cast(shared(ulong)*) address);
}

// @trusted: `atomicExchange` reads and writes exactly one aligned 4-byte word
// through the raw address produced by the validated DRuntime inline-asm
// lowering.
private uint atomicExchangeDword(ubyte* address, in uint value) @trusted {
    import core.atomic: atomicExchange;

    return atomicExchange(cast(shared(uint)*) address, value);
}

// @trusted: `atomicFetchAdd` reads and writes exactly one aligned 4-byte word
// through the raw address produced by the validated DRuntime inline-asm
// lowering.
private uint atomicFetchAddDword(ubyte* address, in uint value) @trusted {
    import core.atomic: atomicFetchAdd;

    return atomicFetchAdd(*cast(shared(uint)*) address, value);
}

// @trusted: `atomicFetchAdd` reads and writes exactly one aligned 8-byte word
// through the raw address produced by the validated DRuntime inline-asm
// lowering.
private ulong atomicFetchAddWord(ubyte* address, in ulong value) @trusted {
    import core.atomic: atomicFetchAdd;

    return atomicFetchAdd(*cast(shared(ulong)*) address, value);
}

private void writeHeapElement(ubyte* element, in ubyte[] source) @trusted {
    element[0 .. source.length] = source[];
}

private struct Frame {
    size_t functionIndex;
    size_t ip;
    size_t base;
    ushort destination;
    RefWriteback[] refWritebacks; // empty unless the callee has ref parameters
    RefAlias[] refAliases;
}

// An active catch handler: where to resume (the catch body's instruction index
// and the function it lives in) and the call-stack depth its frame sits at, so
// a throw can restore the frame state before jumping to the catch body.
private struct Handler {
    size_t functionIndex;
    size_t base;
    size_t frameDepth;
    ushort catchStart;
    ushort catchCount;
}

private struct SelectedHandler {
    bool matched;
    Handler handler;
    imported!"quickbite.backends.bytecode.core.program".CatchClause clause;
}

// A pending scalar `ref` writeback: copy `size` bytes from the callee
// parameter slot (relative to the callee base) back to an absolute caller-frame
// offset on return.
private struct RefWriteback {
    size_t callerOffset; // absolute stack offset of the referenced caller slot
    ushort calleeOffset; // the parameter slot's offset within the callee frame
    uint size;
}

// A `ref` parameter's identity is its caller storage, not its callee mirror.
// The writeback record already preserves that absolute stack offset. Two
// parameters that alias one caller lvalue therefore naturally have identical
// addresses, while `synchronizeRefAliases` continues to keep their mirror
// values coherent during execution.
private size_t refParameterCallerAddress(
    in Frame frame,
    in size_t base,
    in ushort calleeOffset,
) @safe pure {
    foreach (writeback; frame.refWritebacks)
        if (writeback.calleeOffset == calleeOffset)
            return writeback.callerOffset;
    return base + calleeOffset;
}

// Parameter slots that denote the same caller storage. The bytecode compiler
// addresses parameters as frame slots, so keep aliased slots coherent between
// instructions to give every parameter the identity of that shared storage.
private struct RefAlias {
    ushort[] calleeOffsets;
    ubyte[] bytes;
}

private RefAlias[] refAliasGroups(
    in ubyte[] stack,
    in RefWriteback[] writebacks,
    in size_t calleeBase,
) {
    RefAlias[] aliases;
    foreach (writebackIndex, writeback; writebacks) {
        ushort[] offsets;
        foreach (candidateIndex, candidate; writebacks)
            if (candidate.callerOffset == writeback.callerOffset &&
                candidate.size == writeback.size &&
                candidateIndex >= writebackIndex)
                offsets ~= candidate.calleeOffset;
        if (offsets.length < 2)
            continue;

        bool alreadyGrouped;
        foreach (previousIndex; 0 .. writebackIndex)
            if (writebacks[previousIndex].callerOffset ==
                    writeback.callerOffset &&
                writebacks[previousIndex].size == writeback.size)
                alreadyGrouped = true;
        if (alreadyGrouped)
            continue;

        aliases ~= RefAlias(
            offsets,
            stack[
                calleeBase + writeback.calleeOffset
                .. calleeBase + writeback.calleeOffset + writeback.size
            ].dup,
        );
    }
    return aliases;
}

private void synchronizeRefAliases(
    ubyte[] stack,
    ref Frame frame,
    in size_t calleeBase,
) {
    foreach (ref group; frame.refAliases)
        foreach (offset; group.calleeOffsets) {
            const begin = calleeBase + offset;
            if (stack[begin .. begin + group.bytes.length] == group.bytes)
                continue;

            group.bytes[] = stack[begin .. begin + group.bytes.length];
            foreach (destination; group.calleeOffsets)
                stack[
                    calleeBase + destination
                    .. calleeBase + destination + group.bytes.length
                ] = group.bytes[];
        }
}

private uint equalOperandSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;

    switch (op) with (Op) {
        case equal1: return 1;
        case equal2: return 2;
        case equal4: return 4;
        case equal8: return 8;
        default: assert(0, "Not an equality opcode.");
    }
}

private string assertMessage(
    in imported!"quickbite.backends.bytecode.core.program".AssertDiagnostic
        diagnostic,
    in ubyte[] frame,
) @safe {
    import std.conv: text;

    // A truth assert (`assert(x)`) carries the empty operator and renders the
    // single operand against the literal `true` it was implicitly compared to.
    if (diagnostic.operator == "")
        return text(
            operandText(frame, diagnostic.lhs, diagnostic.operandType),
            " != true",
        );

    // A logical-not assert (`assert(!x)`) carries the "!" operator and renders
    // the un-negated operand against the `true` it failed to differ from.
    if (diagnostic.operator == "!")
        return text(
            operandText(frame, diagnostic.lhs, diagnostic.operandType),
            " == true",
        );

    if (diagnostic.isArray)
        return text(
            arrayOperandText(
                frame, diagnostic.lhs, diagnostic.operandType,
                diagnostic.elementNestingDepth,
            ),
            " ",
            invertedOperator(diagnostic.operator),
            " ",
            arrayOperandText(
                frame, diagnostic.rhs, diagnostic.operandType,
                diagnostic.elementNestingDepth,
            ),
        );

    if (diagnostic.isString)
        return text(
            stringOperandText(frame, diagnostic.lhs),
            " ",
            invertedOperator(diagnostic.operator),
            " ",
            stringOperandText(frame, diagnostic.rhs),
        );

    const lhs = diagnostic.lhsIsNull
        ? "`null`"
        : operandText(frame, diagnostic.lhs, diagnostic.operandType);
    const rhs = diagnostic.rhsIsNull
        ? "`null`"
        : operandText(frame, diagnostic.rhs, diagnostic.operandType);
    return text(
        lhs,
        " ",
        invertedOperator(diagnostic.operator),
        " ",
        rhs,
    );
}

private string stringOperandText(
    in ubyte[] frame,
    in size_t offset,
) @safe {
    import std.conv: text;

    return text(`"`, stringFromSlice(frame, offset), `"`);
}

// Render a dynamic-array operand as `[e0, e1, ...]`, reading the slice
// descriptor at `offset` and formatting each element by its scalar type.
// When `elementNestingDepth` is nonzero (an array-of-arrays operand), each
// element is itself a 16-byte slice descriptor, rendered by a recursive
// call one nesting level shallower, until depth reaches zero and the
// elements are plain `elementType` scalars -- matching DMD's own
// `[[e0, e1], ...]` rendering at any nesting depth, not just one level.
private string arrayOperandText(
    in ubyte[] frame,
    in size_t offset,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType
        elementType,
    in uint elementNestingDepth = 0,
) @trusted {
    import quickbite.backends.bytecode.core.program: size, sliceDescriptorSize;
    import std.array: appender;
    import std.conv: text;

    const elementIsArray = elementNestingDepth > 0;
    const pointer = scalarValue!size_t(frame, offset);
    const length = scalarValue!size_t(frame, offset + size_t.sizeof);
    const elementSize = elementIsArray ? sliceDescriptorSize : size(elementType);
    const elements = (cast(const(ubyte)*) pointer)[0 .. length * elementSize];

    auto result = appender("[");
    foreach (index; 0 .. length) {
        if (index != 0)
            result ~= ", ";
        result ~= elementIsArray
            ? arrayOperandText(
                elements, index * elementSize, elementType,
                elementNestingDepth - 1,
            )
            : operandText(elements, index * elementSize, elementType);
    }
    result ~= "]";
    return result[];
}

private string invertedOperator(in string operator) @safe @nogc nothrow pure {
    switch (operator) {
        case "==": return "!=";
        case "!=": return "==";
        case "<": return ">=";
        case "<=": return ">";
        case ">": return "<=";
        case ">=": return "<";
        case "is": return "!is";
        case "!is": return "is";
        default: assert(0, "Unsupported assert operator.");
    }
}

private string operandText(
    in ubyte[] frame,
    in size_t offset,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType, isSigned, size;
    import std.conv: text;

    ulong raw;
    foreach_reverse (value; frame[offset .. offset + size(type)])
        raw = (raw << 8) | value;

    final switch (type) with (ScalarType) {
        case bool_:
            return raw == 0 ? "false" : "true";
        case char_:
            return text("'", cast(char) raw, "'");
        case float_:
            return text(floatValue!float(frame, offset));
        case double_:
            return text(floatValue!double(frame, offset));
        case real_:
            return text(floatValue!real(frame, offset));
        case void_, byte_, ubyte_, short_, ushort_, int_, uint_, long_, ulong_,
            wchar_, dchar_:
            break;
    }

    if (!isSigned(type))
        return text(raw);

    const shift = 64 - 8 * size(type);
    const signed = (cast(long) (raw << shift)) >> shift;
    return text(signed);
}

private ubyte[T.sizeof] scalarBytes(T)(in T value)
    @safe @nogc nothrow pure
{
    ubyte[T.sizeof] bytes;
    const raw = cast(ulong) value;
    foreach (i; 0 .. T.sizeof)
        bytes[i] = cast(ubyte) ((raw >> (8 * i)) & 0xff);

    return bytes;
}

private T objectScalarValue(T)(in ubyte* source) @trusted
    if (T.sizeof <= ulong.sizeof)
{
    T value;
    (cast(ubyte*) &value)[0 .. T.sizeof] = source[0 .. T.sizeof];
    return value;
}

// True when every byte of the `width`-byte frame slot at `offset` is zero,
// i.e. the operand is zero regardless of its scalar width.
private bool isZeroSlot(
    in ubyte[] stack,
    in size_t offset,
    in size_t width,
) @safe @nogc nothrow pure {
    foreach (b; stack[offset .. offset + width])
        if (b != 0)
            return false;

    return true;
}

private T scalarValue(T)(
    in ubyte[] stack,
    in size_t offset,
) @safe @nogc nothrow pure {
    ulong raw;
    foreach (i; 0 .. T.sizeof)
        raw |= cast(ulong) stack[offset + i] << (8 * i);

    return cast(T) raw;
}

// Read an integer source at `offset` and convert it to `real`, honouring its
// byte width (1/2/4/8) and signedness (the `unsignedConvertFlag` bit in
// `widthAndFlag`). Backs the integer-to-floating conversion opcodes.
private real integerToReal(
    in ubyte[] stack,
    in size_t offset,
    in size_t widthAndFlag,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: unsignedConvertFlag;

    const width = widthAndFlag & (unsignedConvertFlag - 1);
    if (widthAndFlag & unsignedConvertFlag)
        switch (width) {
            case 1: return scalarValue!ubyte(stack, offset);
            case 2: return scalarValue!ushort(stack, offset);
            case 4: return scalarValue!uint(stack, offset);
            default: return scalarValue!ulong(stack, offset);
        }
    switch (width) {
        case 1: return scalarValue!byte(stack, offset);
        case 2: return scalarValue!short(stack, offset);
        case 4: return scalarValue!int(stack, offset);
        default: return scalarValue!long(stack, offset);
    }
}

// Write the low `T.sizeof` bytes of `value` little-endian into `stack` at
// `offset`. `bool` writes a single 0/1 byte.
private void writeScalar(T)(
    ref ubyte[] stack,
    in size_t offset,
    in T value,
) @safe @nogc nothrow pure {
    static if (is(T == bool)) {
        stack[offset] = value ? 1 : 0;
    } else {
        const raw = cast(ulong) value;
        foreach (i; 0 .. T.sizeof)
            stack[offset + i] = cast(ubyte) (raw >> (8 * i));
    }
}

// How to compare a key block, decoded from an AA opcode's `Instruction.e`
// operand (`assocArrayKeyMeta`, compiler.d): either the two simple whole-key
// modes `assocArrayKeyIsArrayFlag` already distinguished (all raw bytes, or
// one whole {ptr, length} descriptor compared by content), or -- when
// `assocArrayKeyIsStructLayoutFlag` is set -- a struct key mixing both kinds
// of field in one block, whose per-field layout lives in
// `Program.assocArrayKeyLayouts` (too much to fit in the operand itself).
// `layoutFields` is empty for the two simple modes; when nonempty it takes
// over from `keyIsArray` entirely (`keysEqual` below).
private struct AssocArrayKeyMode {
    bool keyIsArray;
    size_t keyWidth;
    const(imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField)[]
        layoutFields;
}

private AssocArrayKeyMode assocArrayKeyMode(
    in ushort meta,
    in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyLayout[]
        layouts,
) @safe nothrow pure {
    import quickbite.backends.bytecode.core.program:
        assocArrayKeyIsArrayFlag, assocArrayKeyIsStructLayoutFlag;

    if (meta & assocArrayKeyIsStructLayoutFlag) {
        const layout = layouts[meta & (assocArrayKeyIsStructLayoutFlag - 1)];
        return AssocArrayKeyMode(false, layout.width, layout.fields);
    }
    return AssocArrayKeyMode(
        (meta & assocArrayKeyIsArrayFlag) != 0,
        meta & (assocArrayKeyIsArrayFlag - 1),
        null,
    );
}

// A VM-owned `V[K]` map, stored as parallel insertion-ordered keys and
// values. Insertion order does not match druntime's hash order, but the
// tests only sum keys/values and compare entry sets, so order is immaterial.
// `keys` and `values` each pack their entries as fixed-width raw byte blocks,
// the same way a dynamic array carries its own element size: neither width
// is stored on `AssocArray` itself, only passed in by the caller (the
// compiler emits the same static key/value type width at every access site
// for a given map, so a single map's entries are always consistently
// strided). `count` tracks the entry count directly rather than deriving it
// from `keys.length`/`values.length` divided by a width, since `aaLength`
// reads it back with no width operand at all.
private struct AssocArray {
    ubyte[] keys;
    ubyte[] values;
    size_t count;

    // The address of the `valueWidth`-byte value block stored for `key`, or
    // null when absent. Held pointers stay valid until the next insert
    // reallocates `values`. `layoutFields` is nonempty only for a struct key
    // mixing content- and raw-compared fields (`assocArrayKeyMode`); empty
    // for every other key, which compares by `keyIsArray` instead.
    ubyte* find(
        in ubyte[] key,
        in bool keyIsArray,
        in size_t keyWidth,
        in size_t valueWidth,
        in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField[]
            layoutFields = null,
    ) @trusted nothrow pure {
        const index = findIndex(key, keyIsArray, keyWidth, layoutFields);
        return index == size_t.max ? null : &values[index * valueWidth];
    }

    // `value.length` is the entry width; the same width is passed to every
    // other access for this map.
    void insert(
        in ubyte[] key,
        in bool keyIsArray,
        in size_t keyWidth,
        in const(ubyte)[] value,
        in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField[]
            layoutFields = null,
    ) @safe nothrow pure {
        const index = findIndex(key, keyIsArray, keyWidth, layoutFields);
        if (index != size_t.max) {
            values[index * value.length .. (index + 1) * value.length] =
                value[];
            return;
        }
        keys ~= key;
        values ~= value;
        ++count;
    }

    // Like `insert`, but an already-present key's existing value bytes are
    // left untouched -- only a newly created entry gets `value`. Backs
    // `Op.aaGetOrInsert` (`_d_aaGetY`'s find-or-default-insert), where an
    // existing entry may be read back as an intermediate value for further
    // indexing (`a[1][2] = 3`'s `a[1]`) before any write actually happens;
    // `insert`'s unconditional overwrite would clobber it with the caller's
    // placeholder bytes first.
    void insertDefault(
        in ubyte[] key,
        in bool keyIsArray,
        in size_t keyWidth,
        in const(ubyte)[] value,
        in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField[]
            layoutFields = null,
    ) @safe nothrow pure {
        const index = findIndex(key, keyIsArray, keyWidth, layoutFields);
        if (index != size_t.max)
            return;
        keys ~= key;
        values ~= value;
        ++count;
    }

    bool remove(
        in ubyte[] key,
        in bool keyIsArray,
        in size_t keyWidth,
        in size_t valueWidth,
        in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField[]
            layoutFields = null,
    ) @safe nothrow pure {
        const index = findIndex(key, keyIsArray, keyWidth, layoutFields);
        if (index == size_t.max)
            return false;
        keys = keys[0 .. index * keyWidth] ~ keys[(index + 1) * keyWidth .. $];
        values = values[0 .. index * valueWidth] ~
            values[(index + 1) * valueWidth .. $];
        --count;
        return true;
    }

    private size_t findIndex(
        in ubyte[] key,
        in bool keyIsArray,
        in size_t keyWidth,
        in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField[]
            layoutFields = null,
    ) @safe nothrow pure const {
        foreach (index; 0 .. count)
            if (keysEqual(
                keys[index * keyWidth .. (index + 1) * keyWidth],
                key,
                keyIsArray,
                layoutFields,
            ))
                return index;
        return size_t.max;
    }
}

// True iff two same-length key blocks represent the same associative-array
// key. A scalar key (bool/int/long/double/...) compares its raw bytes
// directly -- exactly how a plain `int` key always compared. A `string` key
// (`keyIsArray`, set only by `assocArrayKeyIsArray` in compiler.d) instead
// compares the bytes its {ptr, length} descriptor points at: two
// separately-constructed but content-equal strings have different backing
// pointers, so a raw descriptor-byte compare would wrongly treat them as
// distinct keys, silently miscomparing.
// `layoutFields` (nonempty only for a struct key mixing content- and
// raw-compared fields, `assocArrayKeyMode`) takes over entirely from
// `keyIsArray` when present: each field compares by its own rule --
// `descriptorContentEqual` for a plain `string` field, raw bytes for
// anything else -- mirroring `compileStructIdentity`'s (compiler.d)
// field-by-field pattern for `==`.
private bool keysEqual(
    in ubyte[] left,
    in ubyte[] right,
    in bool keyIsArray,
    in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField[]
        layoutFields = null,
) @trusted @nogc nothrow pure {
    if (layoutFields.length) {
        foreach (field; layoutFields) {
            const leftField =
                left[field.offset .. field.offset + field.width];
            const rightField =
                right[field.offset .. field.offset + field.width];
            if (field.isArray) {
                if (!descriptorContentEqual(leftField, rightField))
                    return false;
            } else if (leftField != rightField) {
                return false;
            }
        }
        return true;
    }

    if (!keyIsArray)
        return left == right;

    return descriptorContentEqual(left, right);
}

// True iff the {ptr, length} slice descriptors at the start of `left`/
// `right` point at equal-content byte ranges -- content, not identity: two
// separately-constructed but content-equal strings/arrays have different
// backing pointers, so a raw descriptor-byte compare would wrongly treat
// them as distinct.
private bool descriptorContentEqual(
    in ubyte[] left,
    in ubyte[] right,
) @trusted @nogc nothrow pure {
    const leftLength = scalarValue!size_t(left, size_t.sizeof);
    const rightLength = scalarValue!size_t(right, size_t.sizeof);
    if (leftLength != rightLength)
        return false;

    const leftPointer = scalarValue!size_t(left, 0);
    const rightPointer = scalarValue!size_t(right, 0);
    return (cast(const(ubyte)*) leftPointer)[0 .. leftLength] ==
        (cast(const(ubyte)*) rightPointer)[0 .. leftLength];
}

private final class BytecodeNativeMarshaller:
    imported!"quickbite.ffi".NativeMarshaller
{
    import dmd.mtype: Type;
    import quickbite.ffi: NativeMarshaller;

    private ubyte[] _stack;
    private size_t _argument;
    private size_t _destination;
    private size_t _base;
    private const(ushort)[] _outParameterOffsets;
    private ushort _nativeClassReceiverOffset;

    public this(
        ubyte[] stack,
        in size_t argument,
        in size_t destination,
        in size_t base,
        in ushort[] outParameterOffsets,
        in ushort nativeClassReceiverOffset,
    ) {
        _stack = stack;
        _argument = argument;
        _destination = destination;
        _base = base;
        _outParameterOffsets = outParameterOffsets;
        _nativeClassReceiverOffset = nativeClassReceiverOffset;
    }

    public bool canRepresent(Type type, in NativeMarshaller.Direction direction) {
        import dmd.astenums: TY;
        const ty = type.toBasetype.ty;
        if (ty == TY.Tvoid)
            return direction == NativeMarshaller.Direction.fromNative;
        // A by-value struct only crosses back out of a native call (the
        // return value); the compiler emits no struct-by-value argument
        // shape today.
        if (ty == TY.Tstruct)
            return direction == NativeMarshaller.Direction.fromNative;
        return ty == TY.Tbool || ty == TY.Tint32 || ty == TY.Tuns32 ||
            ty == TY.Tint64 || ty == TY.Tuns64 || ty == TY.Tfloat64 ||
            ty == TY.Tpointer || ty == TY.Tclass || ty == TY.Tarray;
    }

    public bool canRepresentOutCell(Type pointedToType) {
        // The bytecode marshaller has no special out-cell handling (ffi.md
        // §35.10), so require the pointed-to type to cross both directions.
        with (NativeMarshaller.Direction)
            return canRepresent(pointedToType, toNative) &&
                canRepresent(pointedToType, fromNative);
    }

    public void fillArgument(
        ubyte[] buffer,
        Type type,
        in size_t index,
        in bool stableString,
        ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers,
    ) {
        import quickbite.backends.bytecode.core.program:
            nativeArgumentSlotSize;

        // The argument area is N contiguous fixed-stride slots (see
        // `nativeArgumentSlotSize` in program.d, established by
        // `allocateNativeArgumentArea` in compiler.d); argument `index` lives
        // at `_argument + index * nativeArgumentSlotSize` regardless of its
        // own width. `buffer` is sized to the argument type's native ABI
        // width (4 bytes for `int`, 8 for a pointer); copy exactly that many,
        // not a fixed 8.
        const slot = _argument + index * nativeArgumentSlotSize;
        import dmd.astenums: TY;
        if (type.toBasetype.ty == TY.Tarray) {
            assert(buffer.length == 2 * size_t.sizeof);
            buffer[0 .. size_t.sizeof] = _stack[
                slot + size_t.sizeof .. slot + 2 * size_t.sizeof
            ];
            buffer[size_t.sizeof .. 2 * size_t.sizeof] = _stack[
                slot .. slot + size_t.sizeof
            ];
            return;
        }
        buffer[] = _stack[slot .. slot + buffer.length];
    }

    // @trusted: the stack reserve at run start prevents reallocation while the
    // native call is active, so these frame-slot pointers stay valid for
    // libffi. Out parameters point directly at the target local; ordinary
    // arguments point at their fixed-stride argument slot.
    public const(void)* argumentAddress(in size_t index, Type type) @trusted {
        import dmd.astenums: TY;
        import quickbite.backends.bytecode.core.program:
            nativeArgumentSlotSize, noOutParameterOffset;

        const outParameter = _outParameterOffsets[index];
        if (outParameter != noOutParameterOffset)
            return null;
        if (type.toBasetype.ty == TY.Tarray)
            return null;

        const slot = _argument + index * nativeArgumentSlotSize;
        if (isPointerToPointer(type)) {
            auto target = *cast(void**) &_stack[slot];
            if (target !is null)
                return target;
        }

        return &_stack[slot];
    }

    public void readResult(Type type, in ubyte[] buffer) {
        import dmd.astenums: TY;

        // The FFI slice layout (`ffiSliceType`, ffi/core.d) is
        // {length, pointer}; the VM's own slice descriptor
        // (`writeSliceDescriptor`, machine.d) is {pointer, length}. Swap the
        // two words instead of a straight copy, matching `fillArgument`'s
        // reverse swap for a `void[]`-typed argument.
        if (type.toBasetype.ty == TY.Tarray) {
            _stack[_destination .. _destination + size_t.sizeof] =
                buffer[size_t.sizeof .. 2 * size_t.sizeof];
            _stack[
                _destination + size_t.sizeof .. _destination + 2 * size_t.sizeof
            ] = buffer[0 .. size_t.sizeof];
            return;
        }

        // `buffer` is padded to at least ffi_arg width (8 bytes); copy exactly
        // the return type's native size (4 for `int`, 8 for `long`), not a
        // fixed 4.
        const resultSize = nativeResultSize(type);
        _stack[_destination .. _destination + resultSize] =
            buffer[0 .. resultSize];
    }

    // @trusted: for direct handoff, libffi writes no more than the result slot
    // can hold. Narrow results use the core's padded buffer and copy-out path.
    public void* resultAddress(Type type) @trusted {
        import dmd.astenums: TY;
        import quickbite.ffi.libffi: ffi_arg;

        // A slice return needs the field-order swap in `readResult`, so it
        // always goes through the buffer path, never the direct zero-copy
        // handoff.
        if (type.toBasetype.ty == TY.Tarray)
            return null;

        // A struct return's destination is already sized and aligned to the
        // struct's own layout (`emitNativeCall`); libffi copies back exactly
        // that many bytes for a struct return, unlike a narrow scalar return,
        // which needs the padded `ffi_arg`-wide buffer below.
        if (type.toBasetype.ty == TY.Tstruct)
            return &_stack[_destination];

        if (nativeResultSize(type) < ffi_arg.sizeof)
            return null;

        return &_stack[_destination];
    }

    private static size_t nativeResultSize(Type type) {
        import dmd.astenums: TY;
        switch (type.toBasetype.ty) with (TY) {
            case Tvoid:
                // `callNativeImpl` (ffi/core.d) calls `readResult` even for a
                // void-returning callee; there is no result to copy back.
                return 0;
            case Tbool:
                return bool.sizeof;
            case Tint32:
                return int.sizeof;
            case Tint64:
                return long.sizeof;
            case Tuns64:
                return ulong.sizeof;
            case Tfloat64:
                return double.sizeof;
            case Tpointer:
                return (void*).sizeof;
            case Tarray:
                return 2 * size_t.sizeof;
            default:
                throw new Exception("Unsupported native result type.");
        }
    }

    private static bool isPointerToPointer(Type type) {
        import dmd.astenums: TY;

        auto basetype = type.toBasetype;
        return basetype.ty == TY.Tpointer &&
            basetype.nextOf.toBasetype.ty == TY.Tpointer;
    }

    public void fillReceiver(ubyte[] buffer, Type type, in bool stableString,
        ref const(char)*[] keepAlive, ref ubyte[][] keepAliveBuffers)
    { unsupportedNativeCall; }

    public void writeRefResult(Type type, void* address, in bool stableString,
        ref const(char)*[] keepAlive, ref ubyte[][] keepAliveBuffers)
    { unsupportedNativeCall; }

    // Write the callee's out-cell bytes back into the pointed-to local's
    // frame slot (`_outParameterOffsets[index]`, set by `emitNativeCall`).
    public void writeOutParameter(in size_t index, Type pointedToType,
        in ubyte[] cell)
    {
        const slot = _base + outParameterOffset(index);
        _stack[slot .. slot + cell.length] = cell[];
    }

    // Seed the out cell with the pointed-to local's current value (ffi.md
    // §35.6), e.g. `endptr`'s null pre-call value, which strtod ignores.
    public void fillOutParameterCell(ubyte[] cell, Type pointedToType,
        in size_t index, in bool stableString, ref const(char)*[] keepAlive,
        ref ubyte[][] keepAliveBuffers)
    {
        const slot = _base + outParameterOffset(index);
        cell[] = _stack[slot .. slot + cell.length];
    }

    // `noOutParameterOffset` marks an argument that isn't an out parameter;
    // used as a frame offset it would silently corrupt the stack.
    private size_t outParameterOffset(in size_t index) {
        import quickbite.backends.bytecode.core.program: noOutParameterOffset;

        if (_outParameterOffsets[index] == noOutParameterOffset)
            unsupportedNativeCall;
        return _outParameterOffsets[index];
    }

    public const(void)* receiverObjectPointer() {
        import quickbite.backends.bytecode.core.program: noOutParameterOffset;

        if (_nativeClassReceiverOffset == noOutParameterOffset)
            return null;
        return cast(const(void)*) scalarValue!size_t(
            _stack, _base + _nativeClassReceiverOffset,
        );
    }

    public void invokeClosure(in size_t argumentIndex, Type returnType,
        Type[] parameterTypes, void*[] argumentBuffers, ubyte[] resultBuffer)
    { unsupportedNativeCall; }

    public size_t durableInboundCallbackId(in size_t argumentIndex)
    { unsupportedNativeCall; return 0; }

    private void unsupportedNativeCall() {
        throw new Exception("Unsupported bytecode native call shape.");
    }
}

private AssocArray copyAssocArray(AssocArray source) @safe nothrow pure {
    return AssocArray(source.keys.dup, source.values.dup, source.count);
}

// Entry-set equality: equal counts and, for every key in `left`, an equal
// `valueWidth`-byte value in `right`. Order-independent, matching `V[K]` `==`.
private bool assocArrayEqual(
    in AssocArray left,
    in AssocArray right,
    in bool keyIsArray,
    in size_t keyWidth,
    in size_t valueWidth,
    in imported!"quickbite.backends.bytecode.core.program".AssocArrayKeyField[]
        layoutFields = null,
) @trusted nothrow pure {
    if (left.count != right.count)
        return false;
    foreach (index; 0 .. left.count) {
        const key = left.keys[index * keyWidth .. (index + 1) * keyWidth];
        auto slot = (cast() right).find(
            key, keyIsArray, keyWidth, valueWidth, layoutFields,
        );
        const entry =
            left.values[index * valueWidth .. (index + 1) * valueWidth];
        if (slot is null || slot[0 .. valueWidth] != entry)
            return false;
    }
    return true;
}

// Floating values are reinterpreted, not numerically converted: their bytes
// are the IEEE-754 bit pattern, so read and write them as raw bits.
private T floatValue(T)(
    in ubyte[] stack,
    in size_t offset,
) @safe @nogc nothrow pure
if (is(T == float) || is(T == double) || is(T == real)) {
    static if (is(T == real))
        return realFromBytes(stack[offset .. offset + T.sizeof]);
    else {
        import std.bitmanip: littleEndianToNative;

        ubyte[T.sizeof] raw = stack[offset .. offset + T.sizeof];
        return littleEndianToNative!T(raw);
    }
}

private ubyte[T.sizeof] floatBytes(T)(in T value) @safe @nogc nothrow pure
if (is(T == float) || is(T == double) || is(T == real)) {
    static if (is(T == real))
        return realToBytes(value);
    else {
        import std.bitmanip: nativeToLittleEndian;

        return nativeToLittleEndian(value);
    }
}

private real realFromBytes(in ubyte[] bytes) @safe @nogc nothrow pure {
    union RealBytes {
        real value;
        ubyte[real.sizeof] bytes;
    }

    RealBytes raw;
    raw.bytes[] = bytes[0 .. real.sizeof];
    return raw.value;
}

private ubyte[real.sizeof] realToBytes(in real value)
    @safe @nogc nothrow pure
{
    union RealBytes {
        real value;
        ubyte[real.sizeof] bytes;
    }

    RealBytes raw;
    raw.value = value;
    return raw.bytes;
}

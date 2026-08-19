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
        CatchClause, ClassInfo,
        indexElementWidth, markScanned, Op, ScalarType,
        noCatchObjectField, noExceptionClass, noNativeCallIndex,
        pointerElementWidth, size, sliceCopyWidth, sliceDescriptorLengthOffset,
        sliceDescriptorPtrOffset, sliceDescriptorSize,
        sliceEqualWidth, subSliceElementWidth;

    // Reserve a generous fixed capacity so growing `stack` for callee frames
    // never reallocates: a raw `&local` pointer (`int* p = &x`) stored in a
    // struct field or heap and dereferenced later must stay valid across the
    // intervening calls that grow the stack.
    auto stack = new ubyte[](program.functions[0].frameSize);
    stack.reserve(stackCapacity);
    // Guest locals and temporaries -- including slice/class/struct pointers
    // a real druntime allocation hook returned -- live here as raw bytes;
    // scan them like compiled D scans its own stack frames. A callee-frame
    // growth past the reserved capacity can still move `stack` to a fresh
    // `NO_SCAN` block, so the growth site re-marks it too.
    markScanned(stack);
    // Lazy compilation can add module slots while this machine is running, so
    // access the program-owned segment directly. The compiler reserves its
    // maximum addressable capacity before execution, keeping raw addresses
    // produced by `moduleAddress` stable as the visible length grows.
    ref moduleData = program.moduleData;
    // VM-owned writable heap blocks backing dynamic arrays. Holding the GC
    // slices here keeps the memory the slice descriptors point at alive; the
    // descriptors store the raw `block.ptr` as a native pointer.
    ubyte[][] heap;
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
                // write the descriptor {length, ptr} into the frame slot.
                auto block = new ubyte[](instruction.b * instruction.c);
                markScanned(block);
                heap ~= block;
                writeSliceDescriptor(
                    stack, base + instruction.a, block, instruction.c,
                );
                ++ip;
                break;

            case allocStruct:
                // Allocate a fresh heap block for a single `new S` struct,
                // copy the initialised block of `c` bytes from the frame in,
                // root it, and write the raw heap pointer into the frame slot.
                auto structBlock = new ubyte[](instruction.c);
                markScanned(structBlock);
                structBlock[] = stack[
                    base + instruction.b .. base + instruction.b + instruction.c
                ];
                heap ~= structBlock;
                writeBlockPointer(stack, base + instruction.a, structBlock);
                ++ip;
                break;

            case allocClass:
                auto classBlock = new ubyte[](instruction.c);
                markScanned(classBlock);
                classBlock[0 .. size_t.sizeof] =
                    scalarBytes(cast(size_t) instruction.b)[];
                heap ~= classBlock;
                writeBlockPointer(stack, base + instruction.a, classBlock);
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
                const sliceLengthOffset =
                    sliceDescriptorLengthOffset(base + instruction.b);
                stack[
                    base + instruction.a .. base + instruction.a + size_t.sizeof
                ] = stack[
                    sliceLengthOffset .. sliceLengthOffset + size_t.sizeof
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
                const sourcePointer = scalarValue!size_t(
                    stack, sliceDescriptorPtrOffset(base + instruction.b),
                );
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

            case sliceEqualNumeric:
                stack[base + instruction.a] = numericSlicesEqual(
                    stack,
                    base + instruction.b,
                    base + instruction.c,
                    cast(ScalarType) instruction.d,
                    cast(ScalarType) instruction.e,
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

            case pointerAddress:
                const pointer = scalarValue!size_t(
                    stack, base + instruction.b,
                );
                const index = scalarValue!size_t(
                    stack, base + instruction.c,
                );
                writeScalar(
                    stack,
                    base + instruction.a,
                    pointer + index * instruction.d,
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

            case bitXorInt8:
                const ubyte[long.sizeof] xorBits8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) ^
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = xorBits8;
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

            case bitNotInt8:
                const ubyte[long.sizeof] complement8 = scalarBytes(
                    ~scalarValue!long(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = complement8;
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

            case className:
                const objectPointer =
                    scalarValue!size_t(stack, base + instruction.b);
                const classIndex = objectPointer == 0
                    ? noExceptionClass
                    : objectClassIndex(objectPointer);
                const name = classIndex < program.classes.length
                    ? program.classes[classIndex].name
                    : "";
                writeSliceDescriptorPointer(
                    stack,
                    base + instruction.a,
                    cast(size_t) name.ptr,
                    name.length,
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

            case call, callIndirect:
                // A direct `call` carries the callee's function index in
                // `instruction.a`; an indirect `callIndirect` reads it from
                // the size_t slot at that frame offset (the function-pointer
                // or delegate value). Either way it is a plain index into
                // `program.functions`, uniform whether the callee turns out
                // to be VM-compiled or a native leaf.
                const calleeIndex = instruction.op == call
                    ? instruction.a
                    : cast(ushort) scalarValue!size_t(
                        stack, base + instruction.a,
                    );

                // `registerFunction` records a native-leaf callee's (`&f`
                // where `f` is body-less, e.g. `core.internal.dassert`'s
                // `assumeFakeAttributes` taking the address of
                // `GC.inFinalizer`) matching `program.nativeCalls` entry
                // here instead of ever giving it VM bytecode: dispatch
                // through the same `callNative` bridge a direct native call
                // uses, synchronously, with no VM call frame to push. Its
                // `argumentOffsets` are this call's own dense typed-frame
                // argument layout (the same one a VM-targeted call below
                // would copy verbatim into the callee's frame), not
                // `Op.nativeCall`'s own per-argument staging layout -- both
                // are `NativeCall.argumentOffsets` entries, just built by
                // different compile-time paths.
                if (program.functions[calleeIndex].nativeCallIndex !=
                    noNativeCallIndex)
                {
                    import quickbite.frontend.dmd.functions:
                        noAvailableSourceMessage;
                    import quickbite.backends.bytecode.core.native_call:
                        callNative;

                    auto native = &program.nativeCalls[
                        program.functions[calleeIndex].nativeCallIndex
                    ];
                    if (!callNative(
                            *native,
                            stack,
                            base,
                            base + instruction.b,
                            base + instruction.c,
                        ))
                        throw new Exception(
                            noAvailableSourceMessage(native.function_),
                        );
                    ++ip;
                    break;
                }

                if (program.functions[calleeIndex].code.length == 0)
                    compileFunction(calleeIndex);

                const calleeBase =
                    base + program.functions[functionIndex].frameSize;
                const callee = program.functions[calleeIndex];
                if (stack.length < calleeBase + callee.frameSize) {
                    // Growth past the reserved capacity can relocate `stack`
                    // to a fresh `NO_SCAN` block; re-mark it scanned so the
                    // GC keeps seeing guest pointers stored in its frames.
                    const stackPtrBeforeGrowth = stack.ptr;
                    stack.length = calleeBase + callee.frameSize;
                    if (stack.ptr !is stackPtrBeforeGrowth)
                        markScanned(stack);
                }

                stack[calleeBase .. calleeBase + callee.parameterBytes] =
                    stack[
                        base + instruction.b
                        .. base + instruction.b + callee.parameterBytes
                    ];

                frames ~= Frame(
                    functionIndex, ip + 1, base, instruction.c,
                );
                functionIndex = calleeIndex;
                base = calleeBase;
                ip = 0;
                break;

            case nativeCall:
                import quickbite.frontend.dmd.functions:
                    noAvailableSourceMessage;
                import quickbite.backends.bytecode.core.native_call: callNative;

                // A pointer, not `const`: `callNative` takes the call by
                // mutable ref, since it reads the callee's type through
                // dmd's non-const `Type` accessors.
                auto native = &program.nativeCalls[instruction.a];
                if (!callNative(
                        *native,
                        stack,
                        base,
                        base + instruction.b,
                        base + instruction.c,
                    ))
                    throw new Exception(
                        noAvailableSourceMessage(native.function_),
                    );
                ++ip;
                break;

            case halt:
                throw new Exception("Assertion failure");

            case haltUnittest:
                throw new Exception("unittest failure");

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
                frames.length = handler.frameDepth;
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
                frames.length = handler.frameDepth;
                functionIndex = handler.functionIndex;
                base = handler.base;
                ip = clause.handlerIp;
                break;

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
            // The bounds check raised a genuine, natively-laid-out
            // `RangeError` instance -- hand its own pointer to the guest
            // catch rather than a VM-synthesised lookalike, so native code
            // the guest passes it to (e.g. `_d_print_throwable`) sees the
            // same object compiled D would have passed.
            if (clause.objectOffset != noCatchObjectField) {
                stack[
                    handler.base + clause.objectOffset
                    .. handler.base + clause.objectOffset + size_t.sizeof
                ] = scalarBytes(cast(size_t) cast(void*) error)[];
                writeSliceDescriptorPointer(
                    stack,
                    handler.base + clause.messageOffset,
                    cast(size_t) error.msg.ptr,
                    error.msg.length,
                );
                stack[
                    handler.base + clause.nextMessageOffset
                    .. handler.base + clause.nextMessageOffset
                        + sliceDescriptorSize
                ] = 0;
            }
            frames.length = handler.frameDepth;
            functionIndex = handler.functionIndex;
            base = handler.base;
            ip = clause.handlerIp;
        }
    }
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

// A slice descriptor's decoded {pointer, length} pair, read in one call
// instead of a separate `sliceDescriptorPtrOffset`/`sliceDescriptorLengthOffset`
// pair at each call site.
private struct SliceDescriptorView { size_t pointer; size_t length; }

// Reads a descriptor at `offset` in `stack` (a frame slot, module-data
// offset, or a descriptor-sized buffer's start).
private SliceDescriptorView readSliceDescriptor(
    in ubyte[] stack,
    in size_t offset,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program:
        sliceDescriptorLengthOffset, sliceDescriptorPtrOffset;

    return SliceDescriptorView(
        scalarValue!size_t(stack, sliceDescriptorPtrOffset(offset)),
        scalarValue!size_t(stack, sliceDescriptorLengthOffset(offset)),
    );
}

// Reads a descriptor embedded directly in native memory at `base` (e.g. a
// `T[N][]` row descriptor addressed by a pointer already read out of the
// VM stack), rather than at an offset into the VM's own `ubyte[] stack`.
private SliceDescriptorView readSliceDescriptor(
    in size_t base,
) @trusted {
    import quickbite.backends.bytecode.core.program:
        sliceDescriptorLengthOffset, sliceDescriptorPtrOffset;

    return SliceDescriptorView(
        *cast(const(size_t)*) (base + sliceDescriptorPtrOffset(0)),
        *cast(const(size_t)*) (base + sliceDescriptorLengthOffset(0)),
    );
}

// Decode/transcode the string slice descriptor at `sourceOffset` per `mode`
// into a fresh heap block of target code units, mirroring druntime's `_aApply*`
// foreach helpers. Returns the block (for rooting in `heap`) and the element
// count. The source descriptor is a native {length, ptr}; `length` is the
// source code-unit count, scaled by the mode's source element size.
private auto transcodeUtfString(
    in ubyte[] stack,
    in size_t sourceOffset,
    in ushort mode,
) @trusted {
    import quickbite.backends.bytecode.core.program: TranscodeMode;
    import std.utf: decode, encode;

    struct Block { ubyte[] elements; size_t length; }

    const descriptor = readSliceDescriptor(stack, sourceOffset);
    const pointer = descriptor.pointer;
    const length = descriptor.length;

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

// `offset` holds an ordinary {length, ptr} descriptor, so the string's bytes
// are read straight through the pointer, exactly like any other array read.
// Safe because `pointer`/`length` were themselves produced by the VM's own
// slice-descriptor writers (heap allocation or the program's data segment),
// never by untrusted input, so the read stays within a block the VM itself
// owns.
private string stringFromSlice(
    in ubyte[] stack,
    in size_t offset,
) @trusted pure {
    const descriptor = readSliceDescriptor(stack, offset);
    return (cast(const(char)*) descriptor.pointer)[0 .. descriptor.length].idup;
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
    import quickbite.backends.bytecode.core.program:
        markScanned, sliceDescriptorSize;

    const messageOffset = classIndex < classes.length &&
        classes[classIndex].msgOffset != ushort.max
        ? classes[classIndex].msgOffset
        : cast(ushort) size_t.sizeof;
    auto object = new ubyte[](messageOffset + sliceDescriptorSize);
    markScanned(object);
    object[0 .. size_t.sizeof] = scalarBytes(cast(size_t) classIndex)[];
    object[messageOffset .. messageOffset + sliceDescriptorSize] =
        source[sourceOffset .. sourceOffset + sliceDescriptorSize];
    return object;
}

private ushort objectClassIndex(in size_t objectPointer) @trusted {
    return cast(ushort) objectScalarValue!size_t(cast(const(ubyte)*) objectPointer);
}

private string stringFromObjectSlice(in ubyte* descriptor) @trusted {
    import quickbite.backends.bytecode.core.program:
        sliceDescriptorLengthOffset, sliceDescriptorPtrOffset;

    const pointer =
        objectScalarValue!size_t(descriptor + sliceDescriptorPtrOffset(0));
    const length =
        objectScalarValue!size_t(descriptor + sliceDescriptorLengthOffset(0));
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

// Copy a real {length, ptr} string descriptor into a frame slot.
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

// Write a slice descriptor {length, ptr} at `offset`: the element count
// followed by the heap block's native address, each a little-endian size_t.
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

// Write a slice descriptor {length, ptr} at `offset` from an already-computed
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
    import quickbite.backends.bytecode.core.program: sliceDescriptorLengthOffset;
    import std.conv: text;

    if (lo > hi)
        throw new Exception(text(
            "slice [", lo, " .. ", hi,
            "] has a larger lower index than upper index",
        ));

    const length = scalarValue!size_t(
        stack,
        sliceDescriptorLengthOffset(sourceOffset),
    );
    if (hi > length)
        throw new Exception(text(
            "slice [", lo, " .. ", hi,
            "] extends past source array of length ", length,
        ));
}

// True iff the two slice descriptors hold the same length and identical element
// bytes.
private bool slicesEqual(
    in ubyte[] stack,
    in size_t leftOffset,
    in size_t rightOffset,
    in uint elementSize,
) @trusted {
    const left = readSliceDescriptor(stack, leftOffset);
    const right = readSliceDescriptor(stack, rightOffset);
    if (left.length != right.length)
        return false;

    const byteCount = left.length * elementSize;
    return (cast(const(ubyte)*) left.pointer)[0 .. byteCount] ==
        (cast(const(ubyte)*) right.pointer)[0 .. byteCount];
}

private bool numericSlicesEqual(
    in ubyte[] stack,
    in size_t leftOffset,
    in size_t rightOffset,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType leftType,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType rightType,
) @safe {
    import quickbite.backends.bytecode.core.program: size;

    const left_ = readSliceDescriptor(stack, leftOffset);
    const right_ = readSliceDescriptor(stack, rightOffset);
    if (left_.length != right_.length)
        return false;

    const leftLength = left_.length;
    const rightLength = right_.length;
    const leftPointer = left_.pointer;
    const rightPointer = right_.pointer;
    const leftWidth = size(leftType);
    const rightWidth = size(rightType);
    const leftElements = numericSliceBytes(
        leftPointer, leftLength, leftWidth,
    );
    const rightElements = numericSliceBytes(
        rightPointer, rightLength, rightWidth,
    );
    foreach (index; 0 .. leftLength) {
        const left = numericElement(leftElements, index, leftWidth);
        const right = numericElement(rightElements, index, rightWidth);
        if (!numericElementsEqual(
                left, leftType, right, rightType,
            ))
            return false;
    }
    return true;
}

// @trusted: compiler-produced numeric slice descriptors point only into the
// reserved VM stack, VM heap blocks rooted for the duration of `run`, or
// program-owned storage whose reserved capacity keeps its address stable.
// Their element count matches the backing allocation and `width` is the
// descriptor's ScalarType width. The overflow assertion therefore guards the
// byte-count calculation before constructing the raw-pointer slice; safe
// callers can subsequently read only within that checked extent. Empty slices
// return before touching their possibly-null pointer.
private const(ubyte)[] numericSliceBytes(
    in size_t pointer,
    in size_t length,
    in uint width,
) @trusted pure {
    if (length == 0)
        return null;

    assert(width != 0);
    assert(length <= size_t.max / width);
    return (cast(const(ubyte)*) pointer)[0 .. length * width];
}

private ulong numericElement(
    in ubyte[] elements,
    in size_t index,
    in uint width,
) @safe pure {
    const offset = index * width;
    const bytes = elements[offset .. offset + width];
    ulong result;
    foreach_reverse (byte_; bytes)
        result = (result << 8) | byte_;
    return result;
}

private bool numericElementsEqual(
    in ulong left,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType leftType,
    in ulong right,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType rightType,
) @safe pure {
    import quickbite.backends.bytecode.core.program: isSigned, size;

    const leftWidth = size(leftType);
    const rightWidth = size(rightType);
    if (leftWidth < int.sizeof && rightWidth < int.sizeof)
        return signedElement(left, leftType) == signedElement(right, rightType);

    const commonUnsigned = leftWidth == rightWidth
        ? !isSigned(leftType) || !isSigned(rightType)
        : leftWidth > rightWidth
        ? !isSigned(leftType)
        : !isSigned(rightType);
    if (commonUnsigned) {
        // `extendedUnsignedElement` sign-extends a signed side's own value
        // to 64 bits (via `signedElement`), so `int(-1)` and `uint.max` --
        // the same bit pattern at the common 32-bit width -- diverge at 64
        // bits (0xFFFF...FFFF vs 0x0000_0000_FFFF_FFFF). Mask both sides
        // down to the common width before comparing so only the bits that
        // actually exist in both operands' representations are compared.
        import std.algorithm: max;

        const commonWidth = max(leftWidth, rightWidth, uint.sizeof);
        const mask = commonWidth >= ulong.sizeof
            ? ulong.max
            : (1UL << (commonWidth * 8)) - 1;
        return (extendedUnsignedElement(left, leftType) & mask) ==
            (extendedUnsignedElement(right, rightType) & mask);
    }
    return signedElement(left, leftType) == signedElement(right, rightType);
}

private long signedElement(
    in ulong value,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: isSigned, size;

    if (!isSigned(type))
        return cast(long) value;
    switch (size(type)) {
        case 1: return cast(byte) value;
        case 2: return cast(short) value;
        case 4: return cast(int) value;
        case 8: return cast(long) value;
        default: assert(0, "Unsupported numeric array element width");
    }
}

private ulong extendedUnsignedElement(
    in ulong value,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    return cast(ulong) signedElement(value, type);
}

// True iff two array-of-arrays descriptors are structurally equal, given the
// number of further `Tarray`-row levels below this outer descriptor
// (`steps`: 1 for `int[][]`, 2 for `int[][][]`, 0 for `int[2][]` -- see
// `arrayNestingDepth`): same outer length, and every row (itself a 16-byte
// `{length, ptr}` slice descriptor, separately heap-allocated on each side,
// for each of `steps` further levels) recursively equal one level deeper,
// down to the innermost element bytes (`innerElementSize` each). Unlike
// `slicesEqual`, this never compares a row's raw descriptor bytes -- two
// separately-constructed but content-equal rows have different `.ptr`
// values, so that would compare identity, not content. `steps == 0` (a
// `Tarray` of scalars/structs, or a `Tarray` of inline `Tsarray` rows) reduces
// to a single byte comparison of `outer.length * innerElementSize` bytes at
// the outer's own pointer -- correct either way, since a `Tsarray` row's
// real D layout already stores its bytes right there.
private bool nestedSlicesEqual(
    in ubyte[] stack,
    in size_t leftOffset,
    in size_t rightOffset,
    in uint steps,
    in uint innerElementSize,
) @trusted {
    const left = readSliceDescriptor(stack, leftOffset);
    const right = readSliceDescriptor(stack, rightOffset);
    if (left.length != right.length)
        return false;

    return nestedRowsEqual(
        left.pointer, right.pointer, left.length, steps, innerElementSize,
    );
}

// Compares `length` paired left/right elements starting at the two raw
// pointers, `stepsRemaining` row-descriptor levels above the innermost
// element bytes. At `stepsRemaining == 0` the pointers already address
// plain element bytes (a scalar/string row, or a struct/static-array row --
// whatever `innerElementSize` measures) and this is a single byte
// comparison over `length * innerElementSize` bytes: the base case,
// identical to `nestedSlicesEqual`'s original one-level body. Otherwise
// each of the `length` elements is itself a 16-byte
// `{length, ptr}` row descriptor -- independently lengthed, since arrays
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
        const leftRow = readSliceDescriptor(
            leftPointer + index * sliceDescriptorSize,
        );
        const rightRow = readSliceDescriptor(
            rightPointer + index * sliceDescriptorSize,
        );
        if (leftRow.length != rightRow.length)
            return false;

        if (!nestedRowsEqual(
            leftRow.pointer, rightRow.pointer, leftRow.length,
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

    const destination_ = readSliceDescriptor(stack, destinationOffset);
    const source_ = readSliceDescriptor(stack, sourceOffset);
    const destinationPointer = destination_.pointer;
    const destinationLength = destination_.length;
    const sourcePointer = source_.pointer;
    const sourceLength = source_.length;

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

// The compiler supplies a valid native slice descriptor and a 1-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice1(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const descriptor = readSliceDescriptor(stack, destinationOffset);
    auto destination =
        (cast(ubyte*) descriptor.pointer)[0 .. descriptor.length];
    destination[] = scalarValue!ubyte(stack, valueOffset);
}

// The compiler supplies a valid native slice descriptor and a 2-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice2(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const descriptor = readSliceDescriptor(stack, destinationOffset);
    auto destination =
        (cast(ushort*) descriptor.pointer)[0 .. descriptor.length];
    destination[] = scalarValue!ushort(stack, valueOffset);
}

// The compiler supplies a valid native slice descriptor and a 4-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice4(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const descriptor = readSliceDescriptor(stack, destinationOffset);
    auto destination =
        (cast(uint*) descriptor.pointer)[0 .. descriptor.length];
    destination[] = scalarValue!uint(stack, valueOffset);
}

// The compiler supplies a valid native slice descriptor and an 8-byte scalar
// slot; the trusted boundary only forms the corresponding typed host slice.
private void fillSlice8(
    ref ubyte[] stack,
    in size_t destinationOffset,
    in size_t valueOffset,
) @trusted {
    const descriptor = readSliceDescriptor(stack, destinationOffset);
    auto destination =
        (cast(ulong*) descriptor.pointer)[0 .. descriptor.length];
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
    const descriptor = readSliceDescriptor(stack, destinationOffset);
    auto destination = (cast(ubyte*) descriptor.pointer)[
        0 .. descriptor.length * elementSize
    ];
    const source = stack[valueOffset .. valueOffset + elementSize];
    foreach (i; 0 .. descriptor.length)
        destination[i * elementSize .. (i + 1) * elementSize] = source;
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
    const descriptor = readSliceDescriptor(stack, descriptorOffset);
    enforceIndexInBounds(index, descriptor.length);

    return cast(ubyte*) (descriptor.pointer + index * elementSize);
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

    return atomicLoad(*atomicAddress!uint(address));
}

private ulong atomicLoadWord(in const(ubyte)* address) @trusted {
    import core.atomic: atomicLoad;

    return cast(ulong) atomicLoad(*atomicAddress!ulong(address));
}

// @trusted: `atomicExchange` reads and writes exactly one aligned 4-byte word
// through the raw address produced by the validated DRuntime inline-asm
// lowering.
private uint atomicExchangeDword(ubyte* address, in uint value) @trusted {
    import core.atomic: atomicExchange;

    return atomicExchange(atomicAddress!uint(address), value);
}

// @trusted: `atomicFetchAdd` reads and writes exactly one aligned 4-byte word
// through the raw address produced by the validated DRuntime inline-asm
// lowering.
private uint atomicFetchAddDword(ubyte* address, in uint value) @trusted {
    import core.atomic: atomicFetchAdd;

    return atomicFetchAdd(*atomicAddress!uint(address), value);
}

// @trusted: `atomicFetchAdd` reads and writes exactly one aligned 8-byte word
// through the raw address produced by the validated DRuntime inline-asm
// lowering.
private ulong atomicFetchAddWord(ubyte* address, in ulong value) @trusted {
    import core.atomic: atomicFetchAdd;

    return atomicFetchAdd(*atomicAddress!ulong(address), value);
}

// @trusted: the atomic opcode wrappers pass only aligned native addresses
// produced by the validated DRuntime inline-asm lowering. Restricting the
// cast here keeps raw pointer conversion out of the atomic operations.
private shared(T)* atomicAddress(T)(in const(ubyte)* address) @trusted
    if (is(T == uint) || is(T == ulong))
{
    return cast(shared(T)*) address;
}

private void writeHeapElement(ubyte* element, in ubyte[] source) @trusted {
    element[0 .. source.length] = source[];
}

private struct Frame {
    size_t functionIndex;
    size_t ip;
    size_t base;
    ushort destination;
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

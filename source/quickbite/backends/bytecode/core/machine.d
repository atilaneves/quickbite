module quickbite.backends.bytecode.core.machine;

private:

// Compiles the function with the given index into the running program; the
// machine invokes it on the first call to a not-yet-compiled function.
package(quickbite.backends.bytecode) alias CompileFunction =
    void delegate(in size_t index);

// Bytes reserved upfront for the VM call stack so growing it for callee frames
// reuses the same block: raw `&local` pointers stay valid across calls.
private enum stackCapacity = 4 * 1024 * 1024;

// Executes the program's entry function and returns the raw bytes of its
// result (empty for void).
package(quickbite.backends.bytecode) ubyte[] run(
    ref imported!"quickbite.backends.bytecode.core.program".Program program,
    scope CompileFunction compileFunction,
) {
    import quickbite.backends.bytecode.core.program:
        Op, size, sliceDescriptorSize;

    // Reserve a generous fixed capacity so growing `stack` for callee frames
    // never reallocates: a raw `&local` pointer (`int* p = &x`) stored in a
    // struct field or heap and dereferenced later must stay valid across the
    // intervening calls that grow the stack.
    auto stack = new ubyte[](program.functions[0].frameSize);
    stack.reserve(stackCapacity);
    // VM-owned writable heap blocks backing dynamic arrays. Holding the GC
    // slices here keeps the memory the slice descriptors point at alive; the
    // descriptors store the raw `block.ptr` as a native pointer.
    ubyte[][] heap;
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

            case loadStringSlice:
                // Write the slice descriptor: data offset then length, each a
                // little-endian uint. reify reads it back at the boundary.
                stack[base + instruction.a .. base + instruction.a + uint.sizeof]
                    = scalarBytes(cast(uint) instruction.b);
                stack[
                    base + instruction.a + uint.sizeof
                    .. base + instruction.a + 2 * uint.sizeof
                ] = scalarBytes(cast(uint) instruction.c);
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

            case nullSlice:
                stack[
                    base + instruction.a
                    .. base + instruction.a + 2 * size_t.sizeof
                ] = 0;
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

            case indexLoad1, indexLoad4, indexLoad16:
                const loadSize = elementSize(instruction.op);
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

            case indexStore1, indexStore4, indexStore16:
                const storeSize = elementSize(instruction.op);
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

            case subSlice1, subSlice4:
                const subElementSize = subSliceElementSize(instruction.op);
                const lo = scalarValue!size_t(stack, base + instruction.c);
                const hi = scalarValue!size_t(
                    stack, base + instruction.c + size_t.sizeof,
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

            case sliceCopy1, sliceCopy4:
                copySlice(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    sliceCopyElementSize(instruction.op),
                );
                ++ip;
                break;

            case sliceEqual1, sliceEqual4:
                stack[base + instruction.a] = slicesEqual(
                    stack,
                    base + instruction.b,
                    base + instruction.c,
                    sliceCopyElementSize(instruction.op),
                ) ? 1 : 0;
                ++ip;
                break;

            case stringSliceEqual:
                stack[base + instruction.a] = stringSlicesEqual(
                    stack,
                    base + instruction.b,
                    base + instruction.c,
                    program.data,
                ) ? 1 : 0;
                ++ip;
                break;

            case appendElement1, appendElement2, appendElement4:
                heap ~= appendElement(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    appendElementSize(instruction.op),
                );
                ++ip;
                break;

            case concatArrays1, concatArrays4:
                heap ~= concatArrays(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    base + instruction.c,
                    concatElementSize(instruction.op),
                );
                ++ip;
                break;

            case dupArray1, dupArray2, dupArray4:
                heap ~= dupArray(
                    stack,
                    base + instruction.a,
                    base + instruction.b,
                    dupArrayElementSize(instruction.op),
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

            case pointerLoad1, pointerLoad4:
                const pointerLoadSize = pointerElementSize(instruction.op);
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

            case pointerStore1, pointerStore4:
                const pointerStoreSize = pointerElementSize(instruction.op);
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

            case pointerSlice1, pointerSlice4:
                const pointerSliceSize = pointerElementSize(instruction.op);
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

            case frameAddress:
                writeFrameAddress(
                    stack, base + instruction.a, base + instruction.b,
                );
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

            case convertDoubleToInt:
                const ubyte[int.sizeof] converted = scalarBytes(
                    cast(int) floatValue!double(stack, base + instruction.b),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = converted;
                ++ip;
                break;

            case convertIntToDouble:
                stack[
                    base + instruction.a .. base + instruction.a + double.sizeof
                ] = floatBytes(integerToDouble(
                    stack, base + instruction.b, instruction.c,
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

            case divInt8:
                const ubyte[long.sizeof] quotient8 = scalarBytes(
                    scalarValue!long(stack, base + instruction.b) /
                    scalarValue!long(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + long.sizeof]
                    = quotient8;
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

            case divInt4:
                const ubyte[int.sizeof] quotient = scalarBytes(
                    scalarValue!int(stack, base + instruction.b) /
                    scalarValue!int(stack, base + instruction.c),
                );
                stack[base + instruction.a .. base + instruction.a + int.sizeof]
                    = quotient;
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

            case greaterOrEqualUnsigned4:
                stack[base + instruction.a] =
                    scalarValue!uint(stack, base + instruction.b) >=
                    scalarValue!uint(stack, base + instruction.c) ? 1 : 0;
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

            case call, callIndirect:
                // A direct `call` carries the callee's function index in
                // `instruction.a`; an indirect `callIndirect` reads it from the
                // size_t slot at that frame offset (the function-pointer value).
                const calleeIndex = instruction.op == call
                    ? instruction.a
                    : cast(ushort) scalarValue!size_t(
                        stack, base + instruction.a,
                    );

                if (program.functions[calleeIndex].code.length == 0)
                    compileFunction(calleeIndex);

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

                frames ~= Frame(
                    functionIndex, ip + 1, base, instruction.c, refWritebacks,
                );
                functionIndex = calleeIndex;
                base = calleeBase;
                ip = 0;
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
                const count = handle == 0 ? 0 : maps[handle - 1].keys.length;
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
                maps[handle - 1].insert(
                    scalarValue!int(stack, base + instruction.b),
                    scalarValue!int(stack, base + instruction.c),
                );
                ++ip;
                break;
            }

            case aaGetRvalue, aaIn: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                const key = scalarValue!int(stack, base + instruction.c);
                auto slot = handle == 0 ? null : maps[handle - 1].find(key);
                writeScalar!size_t(
                    stack, base + instruction.a, cast(size_t) slot,
                );
                ++ip;
                break;
            }

            case aaRemove: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                const key = scalarValue!int(stack, base + instruction.c);
                const removed = handle != 0 && maps[handle - 1].remove(key);
                writeScalar!bool(stack, base + instruction.a, removed);
                ++ip;
                break;
            }

            case aaEqual: {
                const left = scalarValue!size_t(stack, base + instruction.b);
                const right = scalarValue!size_t(stack, base + instruction.c);
                const equal = assocArrayEqual(
                    left == 0 ? AssocArray.init : maps[left - 1],
                    right == 0 ? AssocArray.init : maps[right - 1],
                );
                writeScalar!bool(stack, base + instruction.a, equal);
                ++ip;
                break;
            }

            case aaDup: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                maps ~= handle == 0
                    ? AssocArray.init : maps[handle - 1].dup;
                writeScalar!size_t(stack, base + instruction.a, maps.length);
                ++ip;
                break;
            }

            case aaKeys, aaValues: {
                const handle = scalarValue!size_t(stack, base + instruction.b);
                const elements = handle == 0
                    ? null
                    : (instruction.op == aaKeys
                        ? maps[handle - 1].keys
                        : maps[handle - 1].values);
                auto block = new ubyte[](elements.length * int.sizeof);
                foreach (index, element; elements)
                    writeScalar!int(block, index * int.sizeof, element);
                heap ~= block;
                writeSliceDescriptor(
                    stack, base + instruction.a, block, elements.length,
                );
                ++ip;
                break;
            }

            case pushHandler:
                handlers ~= Handler(
                    functionIndex, base, frames.length, instruction.a,
                );
                ++ip;
                break;

            case popHandler:
                handlers.length -= 1;
                ++ip;
                break;

            case throwString:
                // With a catch handler active, redirect to it (popping it):
                // restore the handler's frame and jump to the catch body. With
                // none, the throw escapes as a host exception (an uncaught
                // throw or a synthesised diagnostic).
                if (handlers.length == 0)
                    throw new Exception(stringFromSlice(
                        stack,
                        base + instruction.a,
                        program.data,
                    ));

                const handler = handlers[$ - 1];
                handlers.length -= 1;
                frames.length = handler.frameDepth;
                functionIndex = handler.functionIndex;
                base = handler.base;
                ip = handler.handlerIp;
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
                    return stack[
                        base + instruction.a
                        .. base + instruction.a + resultSize
                    ].dup;

                const frame = frames[$ - 1];
                frames.length -= 1;

                // Write each scalar `ref` parameter's final value back to the
                // caller-frame slot it referenced.
                foreach (writeback; frame.refWritebacks)
                    stack[
                        writeback.callerOffset
                        .. writeback.callerOffset + writeback.size
                    ] = stack[
                        base + writeback.calleeOffset
                        .. base + writeback.calleeOffset + writeback.size
                    ];

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
    }
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

private string stringFromSlice(
    in ubyte[] stack,
    in size_t offset,
    in ubyte[] data,
) @safe pure {
    const dataOffset = scalarValue!uint(stack, offset);
    const length = scalarValue!uint(stack, offset + uint.sizeof);
    return (cast(const(char)[]) data[dataOffset .. dataOffset + length]).idup;
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

    stack[offset .. offset + size_t.sizeof] =
        nativeToLittleEndian(cast(size_t) block.ptr);
    stack[offset + size_t.sizeof .. offset + 2 * size_t.sizeof] =
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

    stack[offset .. offset + size_t.sizeof] = nativeToLittleEndian(pointer);
    stack[offset + size_t.sizeof .. offset + 2 * size_t.sizeof] =
        nativeToLittleEndian(length);
}

private uint elementSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, sliceDescriptorSize;
    if (op == Op.indexLoad16 || op == Op.indexStore16)
        return sliceDescriptorSize;
    return op == Op.indexLoad1 || op == Op.indexStore1 ? 1 : 4;
}

private uint pointerElementSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return op == Op.pointerLoad1 || op == Op.pointerSlice1 ||
        op == Op.pointerStore1 ? 1 : 4;
}

private uint subSliceElementSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return op == Op.subSlice1 ? 1 : 4;
}

private uint sliceCopyElementSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return op == Op.sliceCopy1 || op == Op.sliceEqual1 ? 1 : 4;
}

private uint appendElementSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    if (op == Op.appendElement1)
        return 1;
    return op == Op.appendElement2 ? 2 : 4;
}

private uint concatElementSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return op == Op.concatArrays1 ? 1 : 4;
}

private uint dupArrayElementSize(
    in imported!"quickbite.backends.bytecode.core.program".Op op,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    if (op == Op.dupArray1)
        return 1;
    return op == Op.dupArray2 ? 2 : 4;
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

// Append the element at `elementOffset` to the slice descriptor at
// `descriptorOffset`, reallocating its backing memory. A fresh block of
// `(length + 1)` elements is allocated, the existing elements copied in, and the
// new element written at the end; the descriptor is overwritten with the new
// {ptr, length + 1}. Returns the new block so the caller can root it in `heap`.
// Reallocating rather than growing in place matches compiled D: a slice into the
// old block keeps pointing at the untouched original.
private ubyte[] appendElement(
    ref ubyte[] stack,
    in size_t descriptorOffset,
    in size_t elementOffset,
    in uint elementSize,
) @trusted {
    const length = scalarValue!size_t(stack, descriptorOffset + size_t.sizeof);
    const pointer = scalarValue!size_t(stack, descriptorOffset);

    auto block = new ubyte[]((length + 1) * elementSize);
    const source = (cast(const(ubyte)*) pointer)[0 .. length * elementSize];
    block[0 .. length * elementSize] = source[];
    block[length * elementSize .. (length + 1) * elementSize] =
        stack[elementOffset .. elementOffset + elementSize];

    writeSliceDescriptor(stack, descriptorOffset, block, length + 1);
    return block;
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

// True iff the two string-slice descriptors {dataOffset, length} hold the same
// length and identical bytes within the read-only data segment.
private bool stringSlicesEqual(
    in ubyte[] stack,
    in size_t leftOffset,
    in size_t rightOffset,
    in ubyte[] data,
) @safe pure {
    const leftDataOffset = scalarValue!uint(stack, leftOffset);
    const leftLength = scalarValue!uint(stack, leftOffset + uint.sizeof);
    const rightDataOffset = scalarValue!uint(stack, rightOffset);
    const rightLength = scalarValue!uint(stack, rightOffset + uint.sizeof);
    return data[leftDataOffset .. leftDataOffset + leftLength] ==
        data[rightDataOffset .. rightDataOffset + rightLength];
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

    const byteCount = destinationLength * elementSize;
    if (sourcePointer < destinationPointer + byteCount &&
        destinationPointer < sourcePointer + byteCount)
        throw new Exception("Range violation");

    auto destination = (cast(ubyte*) destinationPointer)[0 .. byteCount];
    const source = (cast(const(ubyte)*) sourcePointer)[0 .. byteCount];
    destination[] = source[];
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

// The native address of element `index` within the slice descriptor at
// `descriptorOffset`, bounds checked against the descriptor's length word.
private ubyte* elementAddress(
    in ubyte[] stack,
    in size_t descriptorOffset,
    in size_t index,
    in uint elementSize,
) @trusted {
    import std.conv: text;

    const length = scalarValue!size_t(stack, descriptorOffset + size_t.sizeof);
    if (index >= length)
        throw new Exception(text(
            "index [", index, "] is out of bounds for array of length ",
            length,
        ));

    const pointer = scalarValue!size_t(stack, descriptorOffset);
    return cast(ubyte*) (pointer + index * elementSize);
}

private void readHeapElement(ubyte[] destination, in ubyte* element)
    @trusted
{
    destination[] = element[0 .. destination.length];
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
}

// An active catch handler: where to resume (the catch body's instruction index
// and the function it lives in) and the call-stack depth its frame sits at, so
// a throw can restore the frame state before jumping to the catch body.
private struct Handler {
    size_t functionIndex;
    size_t base;
    size_t frameDepth;
    size_t handlerIp;
}

// A pending scalar `ref` writeback: copy `size` bytes from the callee
// parameter slot (relative to the callee base) back to an absolute caller-frame
// offset on return.
private struct RefWriteback {
    size_t callerOffset; // absolute stack offset of the referenced caller slot
    ushort calleeOffset; // the parameter slot's offset within the callee frame
    uint size;
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
            arrayOperandText(frame, diagnostic.lhs, diagnostic.operandType),
            " ",
            invertedOperator(diagnostic.operator),
            " ",
            arrayOperandText(frame, diagnostic.rhs, diagnostic.operandType),
        );

    return text(
        operandText(frame, diagnostic.lhs, diagnostic.operandType),
        " ",
        invertedOperator(diagnostic.operator),
        " ",
        operandText(frame, diagnostic.rhs, diagnostic.operandType),
    );
}

// Render a dynamic-array operand as `[e0, e1, ...]`, reading the slice
// descriptor at `offset` and formatting each element by its scalar type.
private string arrayOperandText(
    in ubyte[] frame,
    in size_t offset,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType
        elementType,
) @trusted {
    import quickbite.backends.bytecode.core.program: size;
    import std.array: appender;
    import std.conv: text;

    const pointer = scalarValue!size_t(frame, offset);
    const length = scalarValue!size_t(frame, offset + size_t.sizeof);
    const elementSize = size(elementType);
    const elements = (cast(const(ubyte)*) pointer)[0 .. length * elementSize];

    auto result = appender("[");
    foreach (index; 0 .. length) {
        if (index != 0)
            result ~= ", ";
        result ~= operandText(
            elements, index * elementSize, elementType,
        );
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

// Read an integer source at `offset` and convert it to `double`, honouring its
// byte width (1/2/4/8) and signedness (the `unsignedConvertFlag` bit in
// `widthAndFlag`). Backs `convertIntToDouble`.
private double integerToDouble(
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

// A VM-owned `int[int]` map, stored as parallel insertion-ordered keys and
// values. Insertion order does not match druntime's hash order, but the tests
// only sum keys/values and compare entry sets, so order is immaterial.
private struct AssocArray {
    int[] keys;
    int[] values;

    // The address of the value stored for `key`, or null when absent. Held
    // pointers stay valid until the next insert reallocates `values`.
    int* find(in int key) @trusted @nogc nothrow pure {
        foreach (index, existing; keys)
            if (existing == key)
                return &values[index];
        return null;
    }

    void insert(in int key, in int value) @safe nothrow pure {
        if (auto slot = find(key)) {
            *slot = value;
            return;
        }
        keys ~= key;
        values ~= value;
    }

    bool remove(in int key) @safe nothrow pure {
        foreach (index, existing; keys)
            if (existing == key) {
                keys = keys[0 .. index] ~ keys[index + 1 .. $];
                values = values[0 .. index] ~ values[index + 1 .. $];
                return true;
            }
        return false;
    }

    AssocArray dup() @safe nothrow pure const {
        return AssocArray(keys.dup, values.dup);
    }
}

// Entry-set equality: equal counts and, for every key in `left`, an equal value
// in `right`. Order-independent, matching `int[int]` `==`.
private bool assocArrayEqual(in AssocArray left, in AssocArray right)
    @trusted @nogc nothrow pure
{
    if (left.keys.length != right.keys.length)
        return false;
    foreach (index, key; left.keys) {
        auto slot = (cast() right).find(key);
        if (slot is null || *slot != left.values[index])
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

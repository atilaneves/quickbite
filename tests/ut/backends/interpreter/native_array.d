module ut.backends.interpreter.native_array;


import ut;
import quickbite.backends.interpreter.native_array: NativeArray;
import quickbite.backends.interpreter.native_block: NativeBlock;
import dmd.mtype: Type;

private:


@("NativeArray.allocate.strideFollowsElementTypeInt32")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.stride.should == 4;
}


@("NativeArray.allocate.strideFollowsElementTypeInt64")
unittest {
    auto array = NativeArray.allocate(Type.tint64, 3);

    array.stride.should == 8;
}


@("NativeArray.allocate.blockByteLengthIsLengthTimesStride")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.block.byteLength.should == 12;
}


@("NativeArray.allocate.reportsRequestedLength")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.length.should == 3;
}


@("NativeArray.allocate.reportsElementType")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    (array.elementType is Type.tint32).should == true;
}


@("NativeArray.allocate.reportsOwnedOwnership")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.ownership.should == NativeBlock.Ownership.owned;
}


@("NativeArray.allocate.elementsAreZeroInitialised")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    foreach (i; 0 .. array.length)
        foreach (byte_; array.element(i))
            byte_.should == 0;
}


@("NativeArray.element.writeIsVisibleReadingSameIndexBack")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.element(1)[0] = 42;

    array.element(1)[0].should == 42;
}


@("NativeArray.element.writeDoesNotDisturbNextElement")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.element(1)[0] = 42;

    array.element(2)[0].should == 0;
}


@("NativeArray.element.outOfRangeIndexThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.element(3).shouldThrow!Exception;
}


@("NativeArray.element.wrappingIndexThrowsInsteadOfAliasingAnotherElement")
unittest {
    auto array = NativeArray.allocate(Type.tint64, 4);
    array.element(1)[0] = 42;

    // without the bounds check, index * stride wraps to 8 == element 1's
    // byte offset, and this silently returned element 1's bytes instead of
    // failing.
    const wrappingIndex = size_t.max / 8 + 2;

    array.element(wrappingIndex).shouldThrow;
}


@("NativeArray.allocate.zeroLengthArrayIsLegal")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 0);

    array.length.should == 0;
    array.block.byteLength.should == 0;
}


@("NativeArray.allocate.overflowingLengthTimesStrideThrows")
unittest {
    // An 8-byte element type (`tint64`) and this count wraps
    // `length * stride` to 8 -- a tiny block that would otherwise allocate
    // silently under a handle that claims a huge `length`.
    const count = size_t.max / 8 + 2;

    NativeArray.allocate(Type.tint64, count).shouldThrow!Exception;
}


@("NativeArray.allocate.pointerBearingElementTypeYieldsScannedBlock")
unittest {
    import core.memory: GC;

    auto array = NativeArray.allocate(Type.tvoidptr, 3);
    const attr = GC.getAttr(GC.addrOf(array.block.address));

    (attr & GC.BlkAttr.NO_SCAN).should == 0;
    array.scan.should == NativeBlock.Scan.conservative;
}


@("NativeArray.allocate.nonPointerElementTypeYieldsNoScanBlock")
unittest {
    import core.memory: GC;

    auto array = NativeArray.allocate(Type.tint32, 3);
    const attr = GC.getAttr(GC.addrOf(array.block.address));

    (attr & GC.BlkAttr.NO_SCAN).should == GC.BlkAttr.NO_SCAN;
    array.scan.should == NativeBlock.Scan.no;
}


@("NativeArray.writeSliceHeader.reinterpretedSliceHasElementCountAndBlockAddress")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    align(size_t.alignof) ubyte[NativeArray.sliceHeaderByteLength] header;

    array.writeSliceHeader(header[]);
    auto slice = *cast(int[]*) header.ptr;

    slice.length.should == 3;
    (cast(void*) slice.ptr).should == array.block.address;
}


@("NativeArray.writeSliceHeader.reinterpretedSliceAliasesElementStorage")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    align(size_t.alignof) ubyte[NativeArray.sliceHeaderByteLength] header;
    array.writeSliceHeader(header[]);
    auto slice = *cast(int[]*) header.ptr;

    slice[1] = 42;

    (*cast(int*) array.element(1).ptr).should == 42;
}


@("NativeArray.writeSliceHeader.elementWriteIsVisibleThroughReinterpretedSlice")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    align(size_t.alignof) ubyte[NativeArray.sliceHeaderByteLength] header;
    array.writeSliceHeader(header[]);
    auto slice = *cast(int[]*) header.ptr;

    *cast(int*) array.element(2).ptr = 7;

    slice[2].should == 7;
}


@("NativeArray.writeSliceHeader.distinctElementsThroughReinterpretedSlice")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    align(size_t.alignof) ubyte[NativeArray.sliceHeaderByteLength] header;
    array.writeSliceHeader(header[]);
    auto slice = *cast(int[]*) header.ptr;

    slice[0] = 1;
    slice[1] = 2;

    slice[0].should == 1;
    slice[1].should == 2;
}


@("NativeArray.writeSliceHeader.zeroLengthArrayWritesZeroLength")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 0);
    align(size_t.alignof) ubyte[NativeArray.sliceHeaderByteLength] header;

    array.writeSliceHeader(header[]);
    auto slice = *cast(int[]*) header.ptr;

    slice.length.should == 0;
}


@("NativeArray.writeSliceHeader.wrongDestinationLengthThrowsWithoutCorruptingAdjacentBytes")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    ubyte[NativeArray.sliceHeaderByteLength + 2] buffer;
    buffer[] = 0xAA;

    array.writeSliceHeader(buffer[1 .. $ - 2]).shouldThrow!Exception;

    foreach (b; buffer)
        b.should == 0xAA;
}


@("NativeArray.allocate.capacityIsAtLeastLength")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    (array.capacity >= array.length).should == true;
}


@("NativeArray.allocate.zeroLengthCapacityIsZero")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 0);

    array.capacity.should == 0;
}


@("NativeArray.reserve.withinCapacityLeavesAddressUnchanged")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    const address = array.block.address;

    array.reserve(array.capacity);

    array.block.address.should == address;
}


@("NativeArray.reserve.farBeyondCapacityYieldsCapacityAtLeastRequested")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    const n = 100_000;

    array.reserve(n);

    (array.capacity >= n).should == true;
}


@("NativeArray.reserve.elementValuesSurviveAReallocatingReserve")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    array.element(0)[0] = 10;
    array.element(1)[0] = 20;
    array.element(2)[0] = 30;

    array.reserve(100_000);

    array.element(0)[0].should == 10;
    array.element(1)[0].should == 20;
    array.element(2)[0].should == 30;
}


@("NativeArray.reserve.doesNotChangeLength")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.reserve(100_000);

    array.length.should == 3;
}


@("NativeArray.reserve.zeroLengthArrayYieldsCapacityAtLeastRequested")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 0);
    const n = 100_000;

    array.reserve(n);

    (array.capacity >= n).should == true;
}


@("NativeArray.reserve.reallocationKeepsConservativeScanPolicy")
unittest {
    import core.memory: GC;

    auto array = NativeArray.allocate(Type.tvoidptr, 3);

    array.reserve(100_000);

    array.scan.should == NativeBlock.Scan.conservative;
    const attr = GC.getAttr(GC.addrOf(array.block.address));
    (attr & GC.BlkAttr.NO_SCAN).should == 0;
}


// The two success paths of `reserve` (in-place GC.extend, or reallocate)
// must leave the handle in the same observable state: `block.byteLength`
// exactly `n * stride`, and every byte beyond the live `length * stride`
// zero. This pins that unified post-condition regardless of which path
// actually ran.
@("NativeArray.reserve.blockByteLengthEqualsRequestedCapacityTimesStride")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    const n = 100_000;

    array.reserve(n);

    array.block.byteLength.should == n * array.stride;
}


@("NativeArray.reserve.reservedTailBeyondLengthIsZero")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    array.element(0)[0] = 10;
    array.element(1)[0] = 20;
    array.element(2)[0] = 30;

    array.reserve(100_000);

    const liveBytes = array.length * array.stride;
    foreach (byte_; array.block.bytes[liveBytes .. $])
        byte_.should == 0;
}


@("NativeArray.reserve.overflowingLengthTimesStrideThrows")
unittest {
    // An 8-byte element type (`tint64`) and 3 elements means 24 live bytes.
    // This `n` wraps `n * stride` to exactly 24 -- the same live byte
    // count -- so a raw (unchecked) multiply would let `reserve` silently
    // "succeed" with a block no bigger than the one it already has, while
    // the caller believes it reserved room for size_t.max/2 elements.
    // `reserve` reuses the same overflow-checked `byteLength` helper as
    // `allocate`, so it throws instead.
    auto array = NativeArray.allocate(Type.tint64, 3);
    const n = size_t.max / 2 + 4;

    array.reserve(n).shouldThrow!Exception;
}


// A default-constructed `NativeArray.init` has no element type, hence no
// stride (`_stride == 0`). Before the fix, `capacity` computed
// `_block.trueByteSize / _stride` unconditionally -- 0 / 0, a hardware
// division trap that kills the process instead of failing cleanly. This
// pins the honest answer: a handle with no element type has no capacity.
@("NativeArray.init.capacityIsZero")
unittest {
    NativeArray array;

    array.capacity.should == 0;
}


// Pins the pre-existing `.init`-tolerance that the `capacity` fix relies
// on: a default-constructed handle already reports a sane `length`.
@("NativeArray.init.lengthIsZero")
unittest {
    NativeArray array;

    array.length.should == 0;
}


// `reserve` on a strideless handle must not silently "succeed" with
// `capacity == 0 < n` -- growing an array with no element type is a
// programming error, not a no-op, so it fails loudly instead.
@("NativeArray.reserve.onInitHandleThrows")
unittest {
    NativeArray array;

    array.reserve(1).shouldThrow!Exception;
}


@("NativeArray.borrow.reportsBorrowedOwnership")
@system
unittest {
    auto backing = new int[3];
    auto array = NativeArray.borrow(Type.tint32, backing.ptr, backing.length);

    array.ownership.should == NativeBlock.Ownership.borrowed;
}


@("NativeArray.borrow.reportsRequestedLength")
@system
unittest {
    auto backing = new int[3];
    auto array = NativeArray.borrow(Type.tint32, backing.ptr, backing.length);

    array.length.should == 3;
}


@("NativeArray.borrow.strideFollowsElementType")
@system
unittest {
    auto backing = new int[3];
    auto array = NativeArray.borrow(Type.tint32, backing.ptr, backing.length);

    array.stride.should == 4;
}


@("NativeArray.borrow.reportsElementType")
@system
unittest {
    auto backing = new int[3];
    auto array = NativeArray.borrow(Type.tint32, backing.ptr, backing.length);

    (array.elementType is Type.tint32).should == true;
}


@("NativeArray.borrow.elementWriteIsVisibleInOriginalMemory")
@system
unittest {
    auto backing = new int[3];
    auto array = NativeArray.borrow(Type.tint32, backing.ptr, backing.length);

    array.element(1)[0] = 42;

    backing[1].should == 42;
}


@("NativeArray.borrow.overflowingLengthTimesStrideThrows")
@system
unittest {
    // Same shape as `NativeArray.allocate.overflowingLengthTimesStrideThrows`:
    // an 8-byte element type (`tint64`) and this count wraps
    // `length * stride` to 8, which `borrow` must reject rather than
    // silently handing back a block far smaller than the claimed length.
    auto backing = new long[3];
    const count = size_t.max / 8 + 2;

    NativeArray.borrow(Type.tint64, backing.ptr, count).shouldThrow!Exception;
}


// A borrowed block can never legitimately be reallocated: the memory is
// owned elsewhere, so silently adopting a new block would detach the
// handle from memory its owner still holds.
@("NativeArray.reserve.onBorrowedArrayThrows")
@system
unittest {
    auto backing = new int[3];
    auto array = NativeArray.borrow(Type.tint32, backing.ptr, backing.length);

    array.reserve(100).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "reserve: cannot reallocate a borrowed block; its memory "
        ~ "is owned elsewhere",
    );
}


// `reserve(0)` (or any `n` already within capacity) is a legitimate no-op
// on any array, mirroring compiled D's `arr.reserve(n)`, which never
// touches storage it doesn't need to grow -- even a borrowed array must
// not throw for a request that touches nothing.
@("NativeArray.reserve.zeroOnBorrowedArrayIsANoOp")
@system
unittest {
    auto backing = new int[3];
    auto array = NativeArray.borrow(Type.tint32, backing.ptr, backing.length);
    const address = array.block.address;

    array.reserve(0);

    array.block.address.should == address;
}

module ut.backends.interpreter.native_array;


import ut;
import ut.backends.interpreter: structTypeOf;
import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.native_struct: NativeStruct;
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
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);

    array.writeSliceHeader(dest, 0);
    auto slice = *cast(int[]*) dest.address;

    slice.length.should == 3;
    (cast(void*) slice.ptr).should == array.block.address;
}


@("NativeArray.writeSliceHeader.reinterpretedSliceAliasesElementStorage")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    array.writeSliceHeader(dest, 0);
    auto slice = *cast(int[]*) dest.address;

    slice[1] = 42;

    (*cast(int*) array.element(1).ptr).should == 42;
}


@("NativeArray.writeSliceHeader.elementWriteIsVisibleThroughReinterpretedSlice")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    array.writeSliceHeader(dest, 0);
    auto slice = *cast(int[]*) dest.address;

    *cast(int*) array.element(2).ptr = 7;

    slice[2].should == 7;
}


@("NativeArray.writeSliceHeader.distinctElementsThroughReinterpretedSlice")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    array.writeSliceHeader(dest, 0);
    auto slice = *cast(int[]*) dest.address;

    slice[0] = 1;
    slice[1] = 2;

    slice[0].should == 1;
    slice[1].should == 2;
}


@("NativeArray.writeSliceHeader.zeroLengthArrayWritesZeroLength")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 0);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);

    array.writeSliceHeader(dest, 0);
    auto slice = *cast(int[]*) dest.address;

    slice.length.should == 0;
}


@("NativeArray.writeSliceHeader.outOfBoundsByteOffsetThrowsWithoutCorruptingDestinationBytes")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength + 2, NativeBlock.Scan.conservative);
    dest.bytes[] = 0xAA;

    array.writeSliceHeader(dest, 4).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "writeSliceHeader: byteOffset + sliceHeaderByteLength "
        ~ "does not fit within dest.byteLength",
    );

    foreach (b; dest.bytes)
        b.should == 0xAA;
}


@("NativeArray.writeSliceHeader.byteOffsetNearSizeTMaxOverflowsInsteadOfWrapping")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);

    // byteOffset + sliceHeaderByteLength overflows size_t and would wrap to
    // a tiny value that fits `dest.byteLength` if computed with a plain `+`
    // instead of `core.checkedint.addu`.
    array.writeSliceHeader(dest, size_t.max - 1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "writeSliceHeader: byteOffset + sliceHeaderByteLength "
        ~ "does not fit within dest.byteLength",
    );
}


@("NativeArray.writeSliceHeader.nonZeroByteOffsetLandsHeaderAtOffsetAndLeavesSurroundingBytesUntouched")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength + 8, NativeBlock.Scan.conservative);
    dest.bytes[] = 0xAA;
    const byteOffset = 4;

    array.writeSliceHeader(dest, byteOffset);

    foreach (b; dest.bytes[0 .. byteOffset])
        b.should == 0xAA;
    foreach (b; dest.bytes[byteOffset + NativeArray.sliceHeaderByteLength .. $])
        b.should == 0xAA;
    auto slice = *cast(int[]*) (dest.bytes.ptr + byteOffset);
    slice.length.should == 3;
    (cast(void*) slice.ptr).should == array.block.address;
}


@("NativeArray.writeSliceHeader.ownedGCPointerIntoNoScanDestinationThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.no);

    array.writeSliceHeader(dest, 0).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "writeSliceHeader: dest is not scanned by the GC, but "
        ~ "this array's block address is a live GC pointer",
    );
}


// A zero-length array's block address is `null` (`GC.calloc(0, ...)`
// returns `null`); writing a null pointer into an unscanned destination
// loses nothing, so this deliberately stays legal.
@("NativeArray.writeSliceHeader.zeroLengthArrayNullPointerIntoNoScanDestinationIsLegal")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 0);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.no);

    array.writeSliceHeader(dest, 0);
    auto slice = *cast(int[]*) dest.address;

    slice.length.should == 0;
}


// A borrowed source array wrapping genuinely non-GC memory (here,
// `malloc`'d, not `new int[3]` -- which IS GC memory and would defeat the
// point of this fixture) is not GC memory the collector tracks in the
// first place, so `dest`'s scan policy cannot make it any more or less
// visible; keeping that memory alive is the borrower/owner's job, per
// `NativeBlock.borrow`'s own contract, not this function's. The check is
// keyed on `core.memory.GC.addrOf` returning `null` for this address, not
// on `NativeBlock.Ownership` -- see
// `borrowedSubRangeOfGCMemoryIntoNoScanDestinationThrows` below for the
// borrowed-but-GC-visible case this same rule must reject.
@("NativeArray.writeSliceHeader.borrowedNonGCSourceAddressIntoNoScanDestinationIsLegal")
@system
unittest {
    import core.stdc.stdlib: malloc, free;

    auto backing = cast(int*) malloc(int.sizeof * 3);
    scope(exit) free(backing);
    auto array = NativeArray.borrow(Type.tint32, backing, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.no);

    array.writeSliceHeader(dest, 0);
    auto slice = *cast(int[]*) dest.address;

    slice.length.should == 3;
    (cast(void*) slice.ptr).should == array.block.address;
}


// The hole `writeSliceHeader`'s old ownership-keyed check left open: a
// `NativeBlock.subRange` is `Ownership.borrowed`, exactly like memory
// wrapped by `NativeBlock.borrow`, but its address can be live GC memory --
// here, a zero-offset sub-range whose address IS the parent's own owned GC
// block. Writing that address into a `Scan.no` destination must throw:
// the parent block would then be reachable only through unscanned bytes,
// making it collectable while still logically in use.
@("NativeArray.writeSliceHeader.borrowedSubRangeOfGCMemoryIntoNoScanDestinationThrows")
unittest {
    auto parent = NativeBlock.allocate(3 * int.sizeof, NativeBlock.Scan.no);
    auto array = NativeArray.adopt(parent.subRange(0, 3 * int.sizeof), Type.tint32, 3);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.no);

    array.writeSliceHeader(dest, 0).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "writeSliceHeader: dest is not scanned by the GC, but "
        ~ "this array's block address is a live GC pointer",
    );
}


// `readSliceHeaderBytes` is `public`, reachable from any `@safe` caller
// anywhere -- not just its two known callers (`NativeArray.sliceElement`,
// `NativeStruct.sliceField`), which always pass exactly
// `sliceHeaderByteLength` bytes. Before the fix, the only length
// enforcement was an `in (src.length == ...)` contract, which `-release`
// strips -- a 3-byte slice would then `memcpy` `size_t.sizeof +
// (void*).sizeof` bytes out of `src.ptr`, reading past the end of whatever
// 3-byte slice was handed in. This pins the boundary actually holding: an
// unconditional, un-strippable check that throws instead.
@("NativeArray.readSliceHeaderBytes.wrongLengthThrows")
unittest {
    ubyte[3] src;

    readSliceHeaderBytes(src[]).shouldThrow!Exception;
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

    // Full 4-byte store, not `element(1)[0] = ...`: writing only byte 0 of a
    // 4-byte `int` would be endian-dependent (and rely on the block already
    // being zeroed for the other three bytes to read back as 0).
    *cast(int*) array.element(1).ptr = 42;

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


// `adopt` must route `length` through the same overflow-checked
// `byteLength(length, stride)` helper `allocate`/`borrow` already use --
// otherwise `element`'s wrap-free argument (which rests on that routing)
// breaks for an adopted array. A non-overflowing but too-large `length`
// pins the new "does it fit the block" comparison directly.
@("NativeArray.adopt.lengthTimesStrideExceedingBlockByteLengthThrows")
unittest {
    NativeArray.adopt(
        NativeBlock.allocate(16, NativeBlock.Scan.no),
        Type.tint64,
        3, // 3 * 8 == 24 > the block's 16 bytes
    ).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "adopt: length * stride does not fit within block's byteLength",
    );
}


// The exact shape of the post-merge `element` wrap regression
// (`NativeArray.element.wrappingIndexThrowsInsteadOfAliasingAnotherElement`
// above), but reached through `adopt` instead of `allocate`. Before this
// guard, `adopt` never called `byteLength` at all, so this length -- which
// overflows `length * stride` under a raw multiply -- was silently
// accepted into a 16-byte block, and only `element`'s own bounds check
// stood between a wrapping `index * stride` and a silently aliased
// element. `adopt` now computes `byteLength(length, stride)` itself, so
// construction throws immediately instead.
@("NativeArray.adopt.wrappingLengthThrowsInsteadOfRevivingElementIndexWrapBug")
unittest {
    NativeArray.adopt(
        NativeBlock.allocate(16, NativeBlock.Scan.no),
        Type.tint64,
        size_t.max / 8 + 2,
    ).shouldThrow!Exception;
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


// A default-constructed `NativeArray.init` has no element type, hence no
// stride (`_stride == 0`) -- the same reachable handle `reserve`/`setLength`
// already guard. Before the fix, `slice(0, 0)` on it did NOT throw:
// `begin > end` and `end > _length` both pass trivially (0, 0, 0 are all
// equal), `_block.subRange(0, 0)` on the null block succeeds (an empty
// sub-range of an empty block), and `NativeArray.adopt` then computed
// `typeByteSize(_elementType)` with `_elementType is null` -- a null `Type`
// dereference in `dmd.typesem.size`, segfaulting `@safe` code instead of
// throwing. `0, 0` is deliberately chosen: it is the narrowest possible
// call that already satisfies every OTHER check `slice` performs, so
// nothing but the missing strideless guard stands between it and `adopt`.
@("NativeArray.slice.onInitHandleThrows")
unittest {
    NativeArray array;

    array.slice(0, 0).shouldThrow!Exception;
}


@("NativeArray.slice.writeThroughSliceIsVisibleReadingParentAtBegin")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(1, 3);

    sub.element(0)[0] = 42;

    array.element(1)[0].should == 42;
}


@("NativeArray.slice.writeThroughParentAtBeginIsVisibleReadingSlice")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(1, 3);

    array.element(1)[0] = 42;

    sub.element(0)[0].should == 42;
}


@("NativeArray.slice.lengthIsEndMinusBegin")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(1, 3);

    sub.length.should == 2;
}


@("NativeArray.slice.elementZeroSharesAddressWithParentElementAtBegin")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(1, 3);

    sub.element(0).ptr.should == array.element(1).ptr;
}


@("NativeArray.slice.reportsBorrowedOwnership")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(1, 3);

    sub.ownership.should == NativeBlock.Ownership.borrowed;
}


@("NativeArray.slice.capacityIsZero")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(1, 3);

    sub.capacity.should == 0;
}


// A sub-range cannot be independently grown -- the memory belongs to the
// parent block, exactly as for any other borrowed array.
@("NativeArray.slice.reserveNonZeroThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(1, 3);

    sub.reserve(1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "reserve: cannot reallocate a borrowed block; its memory "
        ~ "is owned elsewhere",
    );
}


@("NativeArray.slice.scanMatchesParentForPointerBearingElementType")
unittest {
    auto array = NativeArray.allocate(Type.tvoidptr, 5);
    auto sub = array.slice(1, 3);

    sub.scan.should == NativeBlock.Scan.conservative;
    sub.scan.should == array.scan;
}


@("NativeArray.slice.beginGreaterThanEndThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);

    array.slice(3, 1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "slice: begin > end",
    );
}


@("NativeArray.slice.endGreaterThanLengthThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);

    array.slice(0, 6).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "slice: end > length",
    );
}


@("NativeArray.slice.emptySliceAtEndOfArrayIsLegalAndZeroLength")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(5, 5);

    sub.length.should == 0;
    sub.block.byteLength.should == 0;
}


@("NativeArray.slice.emptySliceInMiddleOfArrayIsLegalAndZeroLength")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    auto sub = array.slice(2, 2);

    sub.length.should == 0;
    sub.block.byteLength.should == 0;
}


// Pins the measured druntime fact the `slice` doc comment relies on: for
// this file's usual 3-`int32` fixture, the block's 12 live bytes round up
// to a 16-byte GC bin, so the `xs[$ .. $]` slice's past-the-end address
// still resolves as GC-visible (an interior pointer of the same bin) via
// `core.memory.GC.addrOf`, rather than being treated as outside any GC
// allocation. This is `subRange`/`slice` mechanics plus GC bin rounding,
// not a guarantee `slice` itself makes or checks.
@("NativeArray.slice.emptyEndSliceBlockAddressResolvesToParentBaseUnderCurrentBinSlack")
unittest {
    import core.memory: GC;

    auto array = NativeArray.allocate(Type.tint32, 3);
    auto sub = array.slice(3, 3);

    (GC.addrOf(sub.block.address) is null).should == false;
    GC.addrOf(sub.block.address).should == array.block.address;
}


@("NativeArray.slice.sliceOfSliceComposesOffsets")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 10);
    auto once = array.slice(2, 8);
    auto twice = once.slice(1, 4);

    twice.length.should == 3;
    twice.element(0).ptr.should == array.element(3).ptr;
}


@("NativeArray.slice.sliceOfSliceWriteIsVisibleInOriginalArray")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 10);
    auto once = array.slice(2, 8);
    auto twice = once.slice(1, 4);

    twice.element(0)[0] = 99;

    array.element(3)[0].should == 99;
}


// `reserve` first, establishing real, committed capacity (`block.
// byteLength == 8 * stride`) through its own already-tested reallocating
// path -- this is the honest way to get `setLength` room to grow into
// without moving the block, since a bare `GC.sizeOf` bin-rounding "slack"
// beyond what `block.byteLength` already spans is NOT something `setLength`
// claims to use without an explicit `reserve` (see `setLength`'s own
// comment on why its trigger is `block.byteLength`, not `capacity`).
@("NativeArray.setLength.growWithinAlreadyReservedCapacityLeavesAddressUnchanged")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    array.reserve(8);
    const address = array.block.address;

    array.setLength(6);

    array.block.address.should == address;
}


@("NativeArray.setLength.growWithinAlreadyReservedCapacityZeroesNewElements")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    array.reserve(8);
    array.element(0)[0] = 10;
    array.element(1)[0] = 20;
    array.element(2)[0] = 30;

    array.setLength(6);

    foreach (i; 3 .. 6)
        array.element(i)[0].should == 0;
}


@("NativeArray.setLength.growBeyondBlockByteLengthPreservesElementsAcrossReallocation")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    array.element(0)[0] = 10;
    array.element(1)[0] = 20;
    array.element(2)[0] = 30;

    array.setLength(100_000);

    array.block.byteLength.should == 100_000 * array.stride;
    array.element(0)[0].should == 10;
    array.element(1)[0].should == 20;
    array.element(2)[0].should == 30;
}


@("NativeArray.setLength.growBeyondBlockByteLengthTailIsZero")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.setLength(100_000);

    const liveBytes = 3 * array.stride;
    foreach (byte_; array.block.bytes[liveBytes .. $])
        byte_.should == 0;
}


@("NativeArray.setLength.shrinkUpdatesLength")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);

    array.setLength(2);

    array.length.should == 2;
}


// Shrink touches no storage: the block's address, `capacity`, and every
// byte -- including the ones now past the new length -- are untouched.
@("NativeArray.setLength.shrinkLeavesAddressCapacityAndBytesUnchanged")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    array.element(2)[0] = 3;
    const address = array.block.address;
    const capacity = array.capacity;
    const blockByteLength = array.block.byteLength;

    array.setLength(2);

    array.block.address.should == address;
    array.capacity.should == capacity;
    array.block.byteLength.should == blockByteLength;
    array.block.bytes[8 .. 12].should == [3, 0, 0, 0];
}


// The tricky case this container must get right: `reserve` only zeroes
// bytes past whatever `block.byteLength` was at the moment IT ran, and a
// shrink never touches `block.byteLength` at all -- so the bytes between a
// shrunk length and the block's own still-live span are stale leftovers
// from before the shrink, not fresh room anything already zeroed. Growing
// back must zero them itself. Compiled D agrees (checked against a
// compiled probe): shrinking `[1, 2, 3, 4, 5]` to length 2 then growing
// back to 5 reads back `[1, 2, 0, 0, 0]`, never the original `3, 4, 5` --
// `_d_arraysetlengthT_` (core/internal/array/capacity.d) always re-zeroes
// from the CURRENT (possibly already-shrunk) length up to the new one,
// regardless of whether the allocation itself needed to grow.
@("NativeArray.setLength.shrinkThenGrowBackRezeroesStaleBytesWithoutReallocating")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    array.element(0)[0] = 1;
    array.element(1)[0] = 2;
    array.element(2)[0] = 3;
    array.element(3)[0] = 4;
    array.element(4)[0] = 5;
    const address = array.block.address;

    array.setLength(2);
    array.setLength(5);

    array.block.address.should == address;
    array.element(0)[0].should == 1;
    array.element(1)[0].should == 2;
    array.element(2)[0].should == 0;
    array.element(3)[0].should == 0;
    array.element(4)[0].should == 0;
}


@("NativeArray.setLength.sameLengthIsANoOp")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);
    array.element(0)[0] = 42;
    const address = array.block.address;

    array.setLength(3);

    array.length.should == 3;
    array.block.address.should == address;
    array.element(0)[0].should == 42;
}


@("NativeArray.setLength.onInitHandleZeroThrows")
unittest {
    NativeArray array;

    array.setLength(0).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "setLength: element stride is zero, so the array cannot be "
        ~ "resized",
    );
}


@("NativeArray.setLength.onInitHandleNonZeroThrows")
unittest {
    NativeArray array;

    array.setLength(3).shouldThrow!Exception;
}


@("NativeArray.setLength.overflowingLengthTimesStrideThrows")
unittest {
    // Same shape as `NativeArray.reserve.overflowingLengthTimesStrideThrows`:
    // this count wraps `length * stride` back to a small, in-range value
    // under a raw multiply, which `setLength` must reject rather than
    // silently truncating the block it grows to.
    auto array = NativeArray.allocate(Type.tint64, 3);
    const n = size_t.max / 8 + 4;

    array.setLength(n).shouldThrow!Exception;
}


// A pure length change touches no storage, so it stays legal on a
// `borrowed` handle such as a `NativeArray.slice` result -- there is no
// ownership question to ask when nothing is being grown. The parent's own
// live elements (2 and 3, outside `sub`'s new length-1 span but still
// inside its unchanged `block.byteLength`) must stay untouched: shrinking
// `sub` is a fact about `sub._length` alone, never about the bytes.
@("NativeArray.setLength.onBorrowedShrinkSucceedsAndLeavesParentUntouched")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    array.element(1)[0] = 2;
    array.element(2)[0] = 3;
    array.element(3)[0] = 4;
    auto sub = array.slice(1, 4);
    const address = sub.block.address;

    sub.setLength(1);

    sub.length.should == 1;
    sub.block.address.should == address;
    sub.element(0)[0].should == 2;
    array.element(2)[0].should == 3;
    array.element(3)[0].should == 4;
}


// This used to be `NativeArray.setLength.
// onSliceGrowWithinBlockByteLengthSucceedsAndIsVisibleInParent`, and used
// to succeed: `sub`'s own `block.byteLength` is exactly its original
// length * stride (no slack), so shrinking it to 1 element then growing it
// back to 3 stayed within bytes `subRange`'s own construction had already
// verified belonged to `sub`. That was unsound -- `slice` is a real,
// bidirectional aliasing view, so the regrowth's re-zeroing was visible
// through the PARENT too, silently zeroing elements 2 and 3, which the
// parent never asked to have touched; this test's own prior assertions
// pinned exactly that. Checked against compiled D rather than assumed
// which behaviour is actually right: `_d_arraysetlengthT_` only reuses a
// block in place via `gc_expandArrayUsed`, whose real implementation,
// `expandArrayUsed` (core/internal/gc/impl/conservative/gc.d ~1491), only
// succeeds when the block's already-stored allocation length matches the
// slice's own current length -- an old-length comparison inside
// `__setArrayAllocLengthImpl` (core/internal/gc/blockmeta.d). The sibling
// `reserveArrayCapacity` (same file, ~1605, used by `reserve`'s own
// capacity query, not `setLength`'s grow path) spells out the identical
// principle explicitly as `existingUsed != blockUsed`. Neither check lives
// in `core/internal/array/appending.d`, which only declares/calls the
// `gc_expandArrayUsed` hook -- i.e. only the block's current single
// tracked TAIL owner may extend in place. A shrunk-then-regrown compiled-D
// sub-slice fails that check and gets a brand-new block instead, leaving
// the original bytes untouched (confirmed against a compiled probe: `a[1
// .. 4]` shrunk to length 1 then grown back to 3 gets a NEW address, and
// `a` itself is unchanged). A `NativeArray` handle has no equivalent "am I
// the current tail owner" bookkeeping, so growth on ANY borrowed handle
// now throws unconditionally, regardless of `_block.byteLength` -- which
// also merges in the plain, never-shrunk case this file used to pin
// separately as `setLength.onSliceGrowBeyondBlockByteLengthThrows`: that
// scenario hits the identical `n > _length && ownership == borrowed` check
// with the identical message, so this shrink-then-regrow shape (the
// trickier, previously-unsound case) already exercises it too.
@("NativeArray.setLength.onBorrowedShrinkThenGrowBackThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 5);
    array.element(1)[0] = 2;
    array.element(2)[0] = 3;
    array.element(3)[0] = 4;
    auto sub = array.slice(1, 4);
    sub.setLength(1);

    sub.setLength(3).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "setLength: cannot grow a borrowed array; SystemLinker "
        ~ "reallocates a fresh block for a guest `s.length = n` on a "
        ~ "slice rather than growing it in place, so growth-and-rebind "
        ~ "belongs to the call site, not this container",
    );
    array.element(2)[0].should == 3;
    array.element(3)[0].should == 4;
}


// Oracle: `Point`'s field offsets come from the host compiler's own layout
// of the identical struct declared below, exactly as `native_struct.d`'s
// `S` fixture is its own tests' oracle. `byte tag; int x;` leaves 3 padding
// bytes before `x`, so a naive "no padding" implementation would fail the
// offset tests below.
struct Point {
    byte tag;
    int x;
}


@("NativeArray.structElement.writeThroughElementViewIsVisibleInParentElementBytes")
unittest {
    auto type = structTypeOf(q{ struct Point { byte tag; int x; } }, "Point");
    auto array = NativeArray.allocate(type, 3);

    array.structElement(1).field(1)[] = [0x11, 0x22, 0x33, 0x44];

    array.element(1)[Point.x.offsetof .. Point.x.offsetof + int.sizeof]
        .should == [0x11, 0x22, 0x33, 0x44];
}


@("NativeArray.structElement.writeThroughParentElementBytesIsVisibleThroughElementView")
unittest {
    auto type = structTypeOf(q{ struct Point { byte tag; int x; } }, "Point");
    auto array = NativeArray.allocate(type, 3);

    array.element(1)[Point.x.offsetof .. Point.x.offsetof + int.sizeof] =
        [0x11, 0x22, 0x33, 0x44];

    array.structElement(1).field(1).should == [0x11, 0x22, 0x33, 0x44];
}


// The centrepiece: the element view's field offsets are `Point`'s OWN
// offsets, relative to the element (`Point.x.offsetof`), not to the array's
// base -- proving the sub-range is anchored at `index * stride`, and that
// stride (`typeByteSize(Point)`) is `Point.sizeof` with no extra
// inter-element padding, exactly as the host compiler lays out `Point[3]`.
@("NativeArray.structElement.fieldOffsetsAreRelativeToTheElementNotTheArrayBase")
unittest {
    auto type = structTypeOf(q{ struct Point { byte tag; int x; } }, "Point");
    auto array = NativeArray.allocate(type, 3);

    array.structElement(2).field(1).ptr.should ==
        array.element(2).ptr + Point.x.offsetof;
}


@("NativeArray.structElement.elementTypeNotStructThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.structElement(1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "structElement: elementType is not a struct",
    );
}


@("NativeArray.structElement.outOfRangeIndexThrows")
unittest {
    auto type = structTypeOf(q{ struct Point { byte tag; int x; } }, "Point");
    auto array = NativeArray.allocate(type, 3);

    array.structElement(3).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "structElement: index out of range",
    );
}


@("NativeArray.structElement.reportsBorrowedOwnership")
unittest {
    auto type = structTypeOf(q{ struct Point { byte tag; int x; } }, "Point");
    auto array = NativeArray.allocate(type, 3);

    array.structElement(1).ownership.should == NativeBlock.Ownership.borrowed;
}


// An element view is not an independent allocation -- nothing about it can
// be grown -- exactly like `NativeStruct.arrayField`'s zero-offset
// sub-range view (`capacityIsZeroForZeroOffsetSubRangeView`) and
// `NativeArray.slice`'s own `capacityIsZero`. `NativeStruct` has no
// `capacity` reader of its own (only `NativeArray` divides `trueByteSize`
// by a stride), so this is pinned directly on the block.
@("NativeArray.structElement.blockTrueByteSizeIsZero")
unittest {
    auto type = structTypeOf(q{ struct Point { byte tag; int x; } }, "Point");
    auto array = NativeArray.allocate(type, 3);

    array.structElement(1).block.trueByteSize.should == 0;
}


@("NativeArray.structElement.scanMatchesParentForPointerBearingElementType")
unittest {
    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto array = NativeArray.allocate(type, 3);

    array.structElement(1).scan.should == NativeBlock.Scan.conservative;
    array.structElement(1).scan.should == array.scan;
}


// Composition one level deeper: a struct-typed element's own `structField`
// still works through the element view, proving `structElement` composes
// with `NativeStruct.structField` exactly as any other `NativeStruct` does
// -- neither has a special case for "my block came from an array element".
// A write through the doubly-nested view must land at
// `Outer.inner.offsetof + Inner.y.offsetof` bytes past the ARRAY ELEMENT's
// own base, mirroring `NativeStruct.structField`'s own
// `writeThroughNestedFieldViewLandsAtOffsetRelativeToParentInHostCompilerBytes`
// test.
struct Inner {
    int x;
    long y;
}


struct Outer {
    int a;
    Inner inner;
}


@("NativeArray.structElement.structFieldViewStillWorksThroughElementView")
unittest {
    auto type = structTypeOf(
        q{ struct Inner { int x; long y; } struct Outer { int a; Inner inner; } },
        "Outer",
    );
    auto array = NativeArray.allocate(type, 2);

    array.structElement(1).structField(1).field(1)[] = [1, 2, 3, 4, 5, 6, 7, 8];

    const offset = Outer.inner.offsetof + Inner.y.offsetof;
    array.element(1)[offset .. offset + long.sizeof]
        .should == [1, 2, 3, 4, 5, 6, 7, 8];
}


// Composition one level deeper, the array-field case: a static-array-typed
// element field still works through the element view too, mirroring
// `NativeStruct.arrayField`'s own
// `writeThroughViewIsVisibleAtHostCompilerOffsetForElement2` test.
struct Holder {
    int[3] xs;
}


@("NativeArray.structElement.arrayFieldViewStillWorksThroughElementView")
@system
unittest {
    auto type = structTypeOf(q{ struct Holder { int[3] xs; } }, "Holder");
    auto array = NativeArray.allocate(type, 2);

    *cast(int*) array.structElement(1).arrayField(0).element(2).ptr = 42;

    auto guest = *cast(Holder*) array.element(1).ptr;
    guest.xs[2].should == 42;
}


// The symmetric gap `structElement`'s own plan note named: an array whose
// `elementType` is itself a static array (`int[3][4]`) had no element-view
// accessor, the way `NativeStruct.arrayField` already has for a
// static-array-typed *field*. `Int3Holder.xs`'s own field type -- `int[3]`,
// straight from the host compiler via the same `NativeStruct.
// fieldDeclaration` DMD nodes `NativeStruct.arrayField` reads internally --
// is this fixture's `elementType` oracle; `Int3x4` pins the whole array's
// byte length against the host compiler's own `int[3][4].sizeof`.
struct Int3Holder {
    int[3] xs;
}


alias Int3x4 = int[3][4];


@("NativeArray.arrayElement.lengthAndStrideMatchElementTypeAndByteLengthMatchesHostCompilerInt3x4Sizeof")
unittest {
    auto holderType = structTypeOf(q{ struct Int3Holder { int[3] xs; } }, "Int3Holder");
    auto elementType = NativeStruct.allocate(holderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 4);

    array.arrayElement(1).length.should == 3;
    array.arrayElement(1).stride.should == int.sizeof;
    array.block.byteLength.should == Int3x4.sizeof;
}


@("NativeArray.arrayElement.writeThroughElementViewIsVisibleInParentElementBytes")
unittest {
    auto holderType = structTypeOf(q{ struct Int3Holder { int[3] xs; } }, "Int3Holder");
    auto elementType = NativeStruct.allocate(holderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 4);

    array.arrayElement(1).element(2)[] = [0x11, 0x22, 0x33, 0x44];

    array.element(1)[2 * int.sizeof .. 3 * int.sizeof]
        .should == [0x11, 0x22, 0x33, 0x44];
}


@("NativeArray.arrayElement.writeThroughParentElementBytesIsVisibleThroughElementView")
unittest {
    auto holderType = structTypeOf(q{ struct Int3Holder { int[3] xs; } }, "Int3Holder");
    auto elementType = NativeStruct.allocate(holderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 4);

    array.element(1)[2 * int.sizeof .. 3 * int.sizeof] = [0x11, 0x22, 0x33, 0x44];

    array.arrayElement(1).element(2).should == [0x11, 0x22, 0x33, 0x44];
}


@("NativeArray.arrayElement.elementTypeNotStaticArrayThrows")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.arrayElement(1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "arrayElement: elementType is not a static array",
    );
}


@("NativeArray.arrayElement.outOfRangeIndexThrows")
unittest {
    auto holderType = structTypeOf(q{ struct Int3Holder { int[3] xs; } }, "Int3Holder");
    auto elementType = NativeStruct.allocate(holderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 4);

    array.arrayElement(4).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "arrayElement: index out of range",
    );
}


// Mirrors `NativeArray.structElement.reportsBorrowedOwnership`: an
// element view shares the parent's block rather than owning an
// independent allocation, exactly as for a struct-typed element.
@("NativeArray.arrayElement.reportsBorrowedOwnership")
unittest {
    auto holderType = structTypeOf(q{ struct Int3Holder { int[3] xs; } }, "Int3Holder");
    auto elementType = NativeStruct.allocate(holderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 4);

    array.arrayElement(1).ownership.should == NativeBlock.Ownership.borrowed;
}


// Mirrors `NativeArray.structElement.blockTrueByteSizeIsZero`: an array
// element is not an independent allocation, so nothing about it can be
// grown -- pinned directly on the block, as `NativeArray` has no other
// `capacity`-style reader that would apply to a nested `NativeArray` view.
@("NativeArray.arrayElement.blockTrueByteSizeIsZero")
unittest {
    auto holderType = structTypeOf(q{ struct Int3Holder { int[3] xs; } }, "Int3Holder");
    auto elementType = NativeStruct.allocate(holderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 4);

    array.arrayElement(1).block.trueByteSize.should == 0;
}


// The other half of the symmetric gap: an array whose `elementType` is a
// dynamic array (`int[][]`) had no element-view accessor either, the way
// `NativeStruct.sliceField` already has for a dynamic-array-typed *field*.
// `SliceHolder.xs`'s own field type -- `int[]` -- is this fixture's
// `elementType` oracle, exactly mirroring `Int3Holder` above.
struct SliceHolder {
    int[] xs;
}


// The centrepiece for read-back: `sliceElement` reconstructs a `NativeArray`
// from the header `writeSliceHeader` wrote into element 1's bytes, aliasing
// the SAME element block rather than copying it -- a write through the
// read-back handle must be visible through the original `elements` handle
// too, mirroring `NativeStruct.sliceField.
// roundTripAliasesWriteSliceHeaderSourceArray` exactly.
@("NativeArray.sliceElement.roundTripAliasesWriteSliceHeaderSourceArray")
@system
unittest {
    auto sliceHolderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto elementType = NativeStruct.allocate(sliceHolderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 2);
    auto elements = NativeArray.allocate(Type.tint32, 3);
    *cast(int*) elements.element(0).ptr = 1;
    *cast(int*) elements.element(1).ptr = 2;
    *cast(int*) elements.element(2).ptr = 3;
    elements.writeSliceHeader(array.block, 1 * array.stride);

    auto readBack = array.sliceElement(1);
    readBack.length.should == 3;

    *cast(int*) readBack.element(1).ptr = 99;
    (*cast(int*) elements.element(1).ptr).should == 99;
}


// An element that was never written keeps the block's zero-initialised
// `{ length: 0, ptr: null }` bytes -- the same header a default-initialised
// `int[]` guest variable has -- and must read back as a real, empty array
// rather than throwing, mirroring `NativeStruct.sliceField.
// zeroLengthNullHeaderReadsBackAsEmptyBorrowedArray`.
@("NativeArray.sliceElement.zeroLengthNullHeaderReadsBackAsEmptyBorrowedArray")
@system
unittest {
    auto sliceHolderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto elementType = NativeStruct.allocate(sliceHolderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 2);

    auto readBack = array.sliceElement(0);

    readBack.length.should == 0;
    readBack.ownership.should == NativeBlock.Ownership.borrowed;
}


@("NativeArray.sliceElement.elementTypeNotDynamicArrayThrows")
@system
unittest {
    auto array = NativeArray.allocate(Type.tint32, 3);

    array.sliceElement(1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "sliceElement: elementType is not a dynamic array",
    );
}


@("NativeArray.sliceElement.outOfRangeIndexThrows")
@system
unittest {
    auto sliceHolderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto elementType = NativeStruct.allocate(sliceHolderType).fieldDeclaration(0).type;
    auto array = NativeArray.allocate(elementType, 2);

    array.sliceElement(2).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "sliceElement: index out of range",
    );
}

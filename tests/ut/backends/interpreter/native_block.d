module ut.backends.interpreter.native_block;


import ut;
import quickbite.backends.interpreter.native_block: NativeBlock;

private:


@("NativeBlock.allocate.hasRequestedByteLength")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);

    block.byteLength.should == 4;
}


@("NativeBlock.allocate.isZeroInitialised")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);

    foreach (byte_; block.bytes)
        byte_.should == 0;
}


@("NativeBlock.allocate.addressIsStableAcrossCopies")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);
    NativeBlock[] copies;
    copies ~= block;
    auto copy = copies[0];

    copy.address.should == block.address;
}


@("NativeBlock.allocate.mutationThroughOneCopyIsVisibleThroughAnother")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);
    NativeBlock[] copies;
    copies ~= block;
    auto copy = copies[0];

    copy.bytes[0] = 42;

    block.bytes[0].should == 42;
}


@("NativeBlock.borrow.writesThroughToCallerMemory")
@system
unittest {
    ubyte[4] callerOwned = [1, 2, 3, 4];
    auto block = NativeBlock.borrow(callerOwned.ptr, callerOwned.length);

    block.bytes[0] = 99;

    callerOwned[0].should == 99;
}


@("NativeBlock.borrow.reportsBorrowedOwnership")
@system
unittest {
    ubyte[4] callerOwned = [1, 2, 3, 4];
    auto block = NativeBlock.borrow(callerOwned.ptr, callerOwned.length);

    block.ownership.should == NativeBlock.Ownership.borrowed;
}


@("NativeBlock.allocate.reportsOwnedOwnership")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);

    block.ownership.should == NativeBlock.Ownership.owned;
}


@("NativeBlock.allocate.zeroLengthIsLegal")
unittest {
    auto block = NativeBlock.allocate(0, NativeBlock.Scan.no);

    block.byteLength.should == 0;
}


@("NativeBlock.allocate.noScanCarriesNoScanAttribute")
unittest {
    import core.memory: GC;

    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);
    const attr = GC.getAttr(GC.addrOf(block.address));

    (attr & GC.BlkAttr.NO_SCAN).should == GC.BlkAttr.NO_SCAN;
}


@("NativeBlock.allocate.conservativeScanDoesNotCarryNoScanAttribute")
unittest {
    import core.memory: GC;

    auto block = NativeBlock.allocate(4, NativeBlock.Scan.conservative);
    const attr = GC.getAttr(GC.addrOf(block.address));

    (attr & GC.BlkAttr.NO_SCAN).should == 0;
}


@("NativeBlock.allocate.recordsNoScanPolicy")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);

    block.scan.should == NativeBlock.Scan.no;
}


@("NativeBlock.allocate.recordsConservativeScanPolicy")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.conservative);

    block.scan.should == NativeBlock.Scan.conservative;
}


@("NativeBlock.borrow.recordsNoScanPolicy")
@system
unittest {
    ubyte[4] callerOwned = [1, 2, 3, 4];
    auto block = NativeBlock.borrow(callerOwned.ptr, callerOwned.length);

    block.scan.should == NativeBlock.Scan.no;
}


@("NativeBlock.allocate.trueByteSizeIsAtLeastRequestedByteLength")
unittest {
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);

    (block.trueByteSize >= block.byteLength).should == true;
}


@("NativeBlock.borrow.trueByteSizeIsZero")
@system
unittest {
    ubyte[4] callerOwned = [1, 2, 3, 4];
    auto block = NativeBlock.borrow(callerOwned.ptr, callerOwned.length);

    block.trueByteSize.should == 0;
}


@("NativeBlock.allocate.zeroLengthTrueByteSizeIsZero")
unittest {
    auto block = NativeBlock.allocate(0, NativeBlock.Scan.no);

    block.trueByteSize.should == 0;
}


@("NativeBlock.tryExtendTo.smallBlockCannotExtendAndIsLeftUntouched")
unittest {
    // A small (small-bin) GC allocation can never be extended in place --
    // druntime's `GC.extend` only ever grows large-object (page) blocks
    // (core/internal/gc/impl/conservative/gc.d, ~line 843: `!pool.
    // isLargeObject` returns 0 unconditionally). That makes this
    // deterministic rather than allocator-state-dependent: `tryExtendTo`
    // must return false and leave the block's address and byte length
    // exactly as they were.
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);
    const address = block.address;

    block.tryExtendTo(100_000).should == false;

    block.address.should == address;
    block.byteLength.should == 4;
}


@("NativeBlock.tryExtendTo.nonGrowingRequestReturnsFalseAndLeavesBlockUnchanged")
unittest {
    // `newByteLength <= byteLength` is not a growth request. Both the
    // equal-length and shrinking cases must report false and leave the
    // block untouched -- without that guard, the shrinking case computes
    // `newByteLength - oldByteLength`, which wraps to a huge value.
    auto block = NativeBlock.allocate(4, NativeBlock.Scan.no);
    block.bytes[] = [1, 2, 3, 4];
    const address = block.address;

    block.tryExtendTo(4).should == false; // equal length
    block.byteLength.should == 4;
    block.bytes.should == [1, 2, 3, 4];
    block.address.should == address;

    block.tryExtendTo(2).should == false; // shrinking
    block.byteLength.should == 4;
    block.bytes.should == [1, 2, 3, 4];
    block.address.should == address;
}


@("NativeBlock.subRange.byteLengthIsRequestedLength")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);

    block.subRange(4, 8).byteLength.should == 8;
}


@("NativeBlock.subRange.writeThroughSubRangeIsVisibleInParent")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);
    auto sub = block.subRange(4, 8);

    sub.bytes[0] = 42;

    block.bytes[4].should == 42;
}


@("NativeBlock.subRange.writeThroughParentIsVisibleInSubRange")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);
    auto sub = block.subRange(4, 8);

    block.bytes[4] = 99;

    sub.bytes[0].should == 99;
}


@("NativeBlock.subRange.carriesParentsConservativeScanPolicy")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.conservative);

    block.subRange(4, 8).scan.should == NativeBlock.Scan.conservative;
}


@("NativeBlock.subRange.carriesParentsNoScanPolicy")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);

    block.subRange(4, 8).scan.should == NativeBlock.Scan.no;
}


@("NativeBlock.subRange.reportsBorrowedOwnership")
unittest {
    // Not an independent allocation: it cannot legitimately be grown or
    // reallocated in place (`GC.extend`/`GC.calloc` operate on whole
    // allocations, not a byte range in the middle of one), which is
    // exactly `borrowed`'s existing contract -- the owner here is the
    // parent block itself.
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);

    block.subRange(4, 8).ownership.should == NativeBlock.Ownership.borrowed;
}


// `GC.sizeOf` on an interior pointer -- not the head of an allocation --
// returns 0, per its own documented contract (see `trueByteSize`'s
// comment above). A non-zero-offset sub-range's address is never the head
// of the parent's allocation, so this pins that `trueByteSize` reports
// that same honest "I don't know" here, rather than the parent's true
// size, which would otherwise mislead a caller (e.g. `NativeArray.
// capacity`, which divides `trueByteSize` by stride) into believing a
// sub-range has room to grow in place when it does not -- `NativeArray.
// reserve` already separately refuses to reallocate any `borrowed` block
// regardless of what `trueByteSize`/`capacity` report.
@("NativeBlock.subRange.trueByteSizeIsZeroForAnInteriorOffset")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);

    block.subRange(4, 8).trueByteSize.should == 0;
}


@("NativeBlock.subRange.outOfBoundsThrowsWithoutCorruptingParentBytes")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);
    block.bytes[] = 0xAA;

    block.subRange(12, 8).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_block.NativeBlock."
        ~ "subRange: byteOffset + byteLength does not fit within this "
        ~ "block's byteLength",
    );

    foreach (b; block.bytes)
        b.should == 0xAA;
}


@("NativeBlock.subRange.byteOffsetNearSizeTMaxOverflowsInsteadOfWrapping")
unittest {
    auto block = NativeBlock.allocate(16, NativeBlock.Scan.no);

    // byteOffset + byteLength overflows size_t and would wrap to a tiny
    // value that fits `byteLength` if computed with a plain `+` instead of
    // `core.checkedint.addu`.
    block.subRange(size_t.max - 1, 8).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_block.NativeBlock."
        ~ "subRange: byteOffset + byteLength does not fit within this "
        ~ "block's byteLength",
    );
}

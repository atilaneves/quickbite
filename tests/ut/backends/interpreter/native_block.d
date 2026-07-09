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

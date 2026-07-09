module ut.backends.interpreter.native_block;


import ut;
import quickbite.backends.interpreter.native_block: NativeBlock;

private:


@("NativeBlock.allocate.hasRequestedByteLength")
unittest {
    auto block = NativeBlock.allocate(4);

    block.byteLength.should == 4;
}


@("NativeBlock.allocate.isZeroInitialised")
unittest {
    auto block = NativeBlock.allocate(4);

    foreach (byte_; block.bytes)
        byte_.should == 0;
}


@("NativeBlock.allocate.addressIsStableAcrossCopies")
unittest {
    auto block = NativeBlock.allocate(4);
    NativeBlock[] copies;
    copies ~= block;
    auto copy = copies[0];

    copy.address.should == block.address;
}


@("NativeBlock.allocate.mutationThroughOneCopyIsVisibleThroughAnother")
unittest {
    auto block = NativeBlock.allocate(4);
    NativeBlock[] copies;
    copies ~= block;
    auto copy = copies[0];

    copy.bytes[0] = 42;

    block.bytes[0].should == 42;
}


@("NativeBlock.borrow.writesThroughToCallerMemory")
unittest {
    ubyte[4] callerOwned = [1, 2, 3, 4];
    auto block = NativeBlock.borrow(callerOwned.ptr, callerOwned.length);

    block.bytes[0] = 99;

    callerOwned[0].should == 99;
}


@("NativeBlock.borrow.reportsBorrowedOwnership")
unittest {
    ubyte[4] callerOwned = [1, 2, 3, 4];
    auto block = NativeBlock.borrow(callerOwned.ptr, callerOwned.length);

    block.ownership.should == NativeBlock.Ownership.borrowed;
}


@("NativeBlock.allocate.reportsOwnedOwnership")
unittest {
    auto block = NativeBlock.allocate(4);

    block.ownership.should == NativeBlock.Ownership.owned;
}

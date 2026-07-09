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

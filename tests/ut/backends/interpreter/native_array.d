module ut.backends.interpreter.native_array;


import ut;
import quickbite.backends.interpreter.native_array: NativeArray;
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

    array.ownership.should == array.block.ownership;
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
    import core.exception: ArraySliceError;

    auto array = NativeArray.allocate(Type.tint32, 3);

    array.element(3).shouldThrow!ArraySliceError;
}


@("NativeArray.allocate.zeroLengthArrayIsLegal")
unittest {
    auto array = NativeArray.allocate(Type.tint32, 0);

    array.length.should == 0;
    array.block.byteLength.should == 0;
}

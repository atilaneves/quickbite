module ut.backends.interpreter.place_value;


import ut;
import ut.backends.interpreter: structTypeOf, classTypeOf;
import quickbite.backends.interpreter.place_value: readValue, writeValue, isPlaceComposable;
import quickbite.backends.interpreter.place: Place, placeAt;
import quickbite.backends.interpreter.layout: fieldByteOffset, structFields, typeByteSize;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.native_scalar: writeScalar;
import quickbite.lang: Value;
import dmd.mtype: Type;
import dmd.typesem: sarrayOf, pointerTo;

private:


// `P.y` follows `P.x` with the host compiler's own alignment padding, so a
// round trip through `writeValue`/`readValue` must land `y` at its own
// offset independently of `x` -- the same padding trap `Place.field`'s own
// tests pin, exercised here through the whole-value composition instead of
// one field's `Place` directly.
@("place_value.writeValue.readValue.structRoundTripsFlatScalarFields")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    // Runtime-computed, not bare literals passed straight to `Value`.
    int writtenX = 3;
    writtenX = writtenX * 5 + 1;
    long writtenY = 1000L;
    writtenY = writtenY * 7 + 2;

    auto written = Value.structValue("P", [Value(writtenX), Value(writtenY)]);

    writeValue(root, written);

    readValue(root).should == written;
}


// A struct-typed field (`Q.p`) must recurse one level into its own fields
// rather than being treated as an opaque byte span -- the whole-value
// counterpart of `NativeStruct.structField`'s aliasing.
@("place_value.writeValue.readValue.structRoundTripsNestedStructField")
unittest {
    auto type = structTypeOf(q{
        struct P { int x; long y; }
        struct Q { P p; int z; }
    }, "Q");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    int writtenX = 4;
    writtenX = writtenX * 3 + 2;
    long writtenY = 500L;
    writtenY = writtenY * 9 + 5;
    int writtenZ = 7;
    writtenZ = writtenZ * 2 + 1;

    auto written = Value.structValue("Q", [
        Value.structValue("P", [Value(writtenX), Value(writtenY)]),
        Value(writtenZ),
    ]);

    writeValue(root, written);

    readValue(root).should == written;
}


// A static-array-typed field (`H.xs`) must recurse element by element,
// through `Place.index`'s own inline stride arithmetic -- the whole-value
// counterpart of `NativeStruct.arrayField`'s aliasing.
@("place_value.writeValue.readValue.structRoundTripsStaticArrayField")
unittest {
    auto type = structTypeOf(q{ struct H { int[3] xs; } }, "H");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    int first = 1;
    first = first * 6 + 1;
    int second = 2;
    second = second * 6 + 2;
    int third = 3;
    third = third * 6 + 3;

    auto written = Value.structValue(
        "H",
        [Value.arrayValue([Value(first), Value(second), Value(third)])],
    );

    writeValue(root, written);

    readValue(root).should == written;
}


// Cross-checks `readValue`'s field composition against an entirely
// independent path: `native_scalar.writeScalar` writes straight into `P.y`'s
// own bytes at `layout.fieldByteOffset`, never going through `Place`/
// `writeValue` at all, and `readValue` must still see it at the same field.
@("place_value.readValue.reflectsScalarWrittenDirectlyViaNativeScalarAtFieldOffset")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto fields = structFields(type);
    auto yField = fields[1];

    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    long writtenY = 42L;
    writtenY = writtenY * 11 + 3;

    const offset = fieldByteOffset(yField);
    writeScalar(yField.type, block.bytes[offset .. offset + typeByteSize(yField.type)], Value(writtenY));

    readValue(root).structFieldAt(1).asLong.should == writtenY;
}


@("place_value.readValue.writeValue.classTypeThrows")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    auto place = Place(null, classType);

    readValue(place).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}


// `writeValue`'s own slice case stays unsupported -- slice write needs
// backing-storage allocation, out of scope for `writeValue` (see its header
// comment); `readValue`'s own slice case is exercised separately below, now
// that it reconstructs a slice from its native header + elements rather than
// throwing.
@("place_value.writeValue.sliceTypeThrows")
unittest {
    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto place = Place(null, sliceType);

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}


// The read-side counterpart of `Place.index`'s own slice-place test
// (`Place.index.sliceElementAddressesFollowTheHeadersPointerAndScalarStore
// LoadRoundTrips`): a slice place's own address holds a native `{ length,
// ptr }` header, and `readValue` must read that header back and recurse
// once per element via `Place.index`, exactly as it already does for a
// static array's inline elements.
@("place_value.readValue.sliceRoundTripsNativeElements")
unittest {
    import quickbite.backends.interpreter.native_array: NativeArray;

    auto holderType = structTypeOf(q{ struct SliceHolder { int[] s; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;

    auto elements = NativeBlock.allocate(3 * int.sizeof, NativeBlock.Scan.no);
    auto elementsArray = NativeArray.adopt(elements, sliceType.nextOf, 3);

    int first = 2;
    first = first * 4 + 1;
    int second = 5;
    second = second * 3 + 2;
    int third = 9;
    third = third * 2 + 3;

    writeScalar(sliceType.nextOf, elementsArray.element(0), Value(first));
    writeScalar(sliceType.nextOf, elementsArray.element(1), Value(second));
    writeScalar(sliceType.nextOf, elementsArray.element(2), Value(third));

    auto headerBlock = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    elementsArray.writeSliceHeader(headerBlock, 0);

    auto root = placeAt(headerBlock, sliceType);

    readValue(root).should == Value.arrayValue([Value(first), Value(second), Value(third)]);
}


// The struct-element counterpart of the above: a slice's element type is
// itself a non-union struct, so each element must recurse through
// `readValue`'s own struct branch rather than being read as flat bytes --
// the whole-value analogue of `NativeArray.structElement`'s aliasing.
@("place_value.readValue.sliceOfStructsRoundTripsNativeElements")
unittest {
    auto holderType = structTypeOf(q{
        struct SlicePoint { int x; int y; }
        struct SlicePointsHolder { SlicePoint[] s; }
    }, "SlicePointsHolder");
    auto sliceType = structFields(holderType)[0].type;

    import quickbite.backends.interpreter.native_array: NativeArray;

    auto elements = NativeBlock.allocate(2 * typeByteSize(sliceType.nextOf), NativeBlock.Scan.no);
    auto elementsArray = NativeArray.adopt(elements, sliceType.nextOf, 2);

    auto headerBlock = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    elementsArray.writeSliceHeader(headerBlock, 0);

    auto root = placeAt(headerBlock, sliceType);

    int firstX = 1;
    firstX = firstX * 3 + 1;
    int firstY = 2;
    firstY = firstY * 3 + 2;
    int secondX = 3;
    secondX = secondX * 3 + 3;
    int secondY = 4;
    secondY = secondY * 3 + 4;

    auto firstPoint = Value.structValue("SlicePoint", [Value(firstX), Value(firstY)]);
    auto secondPoint = Value.structValue("SlicePoint", [Value(secondX), Value(secondY)]);

    writeValue(root.index(0), firstPoint);
    writeValue(root.index(1), secondPoint);

    readValue(root).should == Value.arrayValue([firstPoint, secondPoint]);
}


@("place_value.readValue.writeValue.unionTypeThrows")
unittest {
    auto unionType = structTypeOf(q{ union U { int x; long y; } }, "U");
    auto place = Place(null, unionType);

    readValue(place).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}


@("place_value.isPlaceComposable.trueForNativeScalar")
unittest {
    isPlaceComposable(Type.tint32).should == true;
}


@("place_value.isPlaceComposable.trueForNonUnionStruct")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    isPlaceComposable(type).should == true;
}


@("place_value.isPlaceComposable.trueForNestedNonUnionStruct")
unittest {
    auto type = structTypeOf(q{
        struct P { int x; long y; }
        struct Q { P p; int z; }
    }, "Q");
    isPlaceComposable(type).should == true;
}


@("place_value.isPlaceComposable.trueForStaticArrayOfScalars")
unittest {
    isPlaceComposable(Type.tint32.sarrayOf(3)).should == true;
}


@("place_value.isPlaceComposable.trueForStructWithStaticArrayField")
unittest {
    auto type = structTypeOf(q{ struct H { int[3] xs; } }, "H");
    isPlaceComposable(type).should == true;
}


@("place_value.isPlaceComposable.falseForClass")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    isPlaceComposable(classType).should == false;
}


@("place_value.isPlaceComposable.falseForStructWithSliceField")
unittest {
    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    isPlaceComposable(holderType).should == false;
}


// `isPlaceComposable` still gates the write-side mirror, which stays
// slice-free even though `readValue` itself now reconstructs a slice --
// pinned directly on the slice type, not only via a struct field of one.
@("place_value.isPlaceComposable.falseForSlice")
unittest {
    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    isPlaceComposable(sliceType).should == false;
}


@("place_value.isPlaceComposable.falseForUnion")
unittest {
    auto unionType = structTypeOf(q{ union U { int x; long y; } }, "U");
    isPlaceComposable(unionType).should == false;
}


@("place_value.isPlaceComposable.falseForPointer")
unittest {
    isPlaceComposable(Type.tint32.pointerTo).should == false;
}

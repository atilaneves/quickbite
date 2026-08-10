module ut.backends.interpreter.place_value;


import ut;
import ut.backends.interpreter: structTypeOf, classTypeOf, enumTypeOf;
import quickbite.backends.interpreter.place_value:
    readValue, writeValue, isPlaceComposable;
import quickbite.backends.interpreter.place: Place, placeAt;
import quickbite.backends.interpreter.layout:
    fieldByteOffset, structFields, typeByteSize, classInstanceByteSize;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.native_scalar: writeScalar;
import quickbite.backends.interpreter.aggregate_value: AggregateValue;
import quickbite.backends.interpreter.runtime_value: Value;
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

    const readBack = readValue(root);
    AggregateValue.isStruct(readBack).should == true;
    AggregateValue.fieldAt(readBack, 0).should == Value(writtenX);
    AggregateValue.fieldAt(readBack, 1).should == Value(writtenY);
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

    const readBack = readValue(root);
    AggregateValue.isStruct(readBack).should == true;
    const nested = AggregateValue.fieldAt(readBack, 0);
    AggregateValue.isStruct(nested).should == true;
    AggregateValue.fieldAt(nested, 0).should == Value(writtenX);
    AggregateValue.fieldAt(nested, 1).should == Value(writtenY);
    AggregateValue.fieldAt(readBack, 1).should == Value(writtenZ);
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

    const readBack = readValue(root);
    AggregateValue.isStruct(readBack).should == true;
    const elements = AggregateValue.fieldAt(readBack, 0);
    AggregateValue.isArray(elements).should == true;
    AggregateValue.elementAt(elements, 0).should == Value(first);
    AggregateValue.elementAt(elements, 1).should == Value(second);
    AggregateValue.elementAt(elements, 2).should == Value(third);
}


// An enum-typed place must read back as a `Value.enumValue` qualified with
// the member's own name (`Colour.green`), not the plain integral `Value`
// `native_scalar.readScalar` alone would give -- the enum-tagging gap this
// slice closes (`ai/plans/value.md` "Remaining work" item 5).
@("place_value.readValue.enumMemberValueReadsBackTaggedWithItsQualifiedName")
unittest {
    auto type = enumTypeOf(q{ enum Colour : int { red, green, blue } }, "Colour");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    writeScalar(type, block.bytes, Value(1));

    readValue(root).should == Value.enumValue("Colour.green", 1);
}


// A value with no owning member reads back in the non-member `cast(E)N`
// form `value.md`'s Display format spec rule 5 gives, rather than a
// qualified member name that doesn't exist.
@("place_value.readValue.nonMemberEnumValueReadsBackInCastForm")
unittest {
    auto type = enumTypeOf(q{ enum Colour : int { red, green, blue } }, "Colour");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    writeScalar(type, block.bytes, Value(5));

    readValue(root).should == Value.enumValue("cast(Colour)5", 5);
}


// `writeValue` already stores an enum's underlying bits correctly (its
// `isNativeScalarType` arm goes through `native_scalar.writeScalar` ->
// `scalarLong` -> `Value.asLong`'s `EnumValue` arm); this pins the full
// round trip through the now enum-aware `readValue`.
@("place_value.writeValue.readValue.enumValueRoundTrips")
unittest {
    auto type = enumTypeOf(q{ enum Colour : int { red, green, blue } }, "Colour");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    auto written = Value.enumValue("Colour.blue", 2);

    writeValue(root, written);

    readValue(root).should == written;
}


// An enum-typed struct field must compose the same way a scalar field
// does, tagged correctly on the read side rather than losing its enum
// name inside the recursion.
@("place_value.writeValue.readValue.structRoundTripsEnumField")
unittest {
    auto type = structTypeOf(q{
        enum Colour : int { red, green, blue }
        struct S { Colour colour; int x; }
    }, "S");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    int writtenX = 3;
    writtenX = writtenX * 4 + 1;

    auto written = Value.structValue(
        "S", [Value.enumValue("Colour.blue", 2), Value(writtenX)]);

    writeValue(root, written);

    const readBack = readValue(root);
    AggregateValue.isStruct(readBack).should == true;
    AggregateValue.fieldAt(readBack, 0).should == Value.enumValue("Colour.blue", 2);
    AggregateValue.fieldAt(readBack, 1).should == Value(writtenX);
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

    AggregateValue.fieldAt(readValue(root), 1).asLong.should == writtenY;
}


// A class place stores only an object body address or null. A `void` value
// carries neither, so it must refuse before touching this bare place.
@("place_value.writeValue.classTypeThrows")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    auto place = Place(null, classType);

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: class place "
        ~ "requires an object pointer or null",
    );
}


// A null stored reference -- the zero-filled default `NativeBlock.allocate`
// gives every fresh slot -- reads back as `Value.null_`, not an attempt to
// read fields through a null object-body address.
@("place_value.readValue.classReferenceNullReadsBackAsNull")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    auto referenceSlot = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    auto place = placeAt(referenceSlot, classType);

    readValue(place).should == Value.null_;
}


// The round trip `writeValue`'s slice arm exists for: allocates new backing
// storage sized to `value.length`, writes every element into it, then
// writes the `{ length, ptr }` header into `place` -- `readValue` must then
// see back exactly what was written, through its own independent header +
// element read (`ai/plans/value.md` "Remaining work" item 5).
@("place_value.writeValue.readValue.sliceRoundTripsElementsAndLength")
unittest {
    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto place = placeAt(block, sliceType);

    int first = 2;
    first = first * 5 + 1;
    int second = 3;
    second = second * 5 + 2;
    int third = 4;
    third = third * 5 + 3;

    auto written = Value.arrayValue([Value(first), Value(second), Value(third)]);

    writeValue(place, written);

    auto readBack = readValue(place);
    AggregateValue.elementCount(readBack).should == 3;
    AggregateValue.elementAt(readBack, 0).should == Value(first);
    AggregateValue.elementAt(readBack, 1).should == Value(second);
    AggregateValue.elementAt(readBack, 2).should == Value(third);
}


// A zero-length array is the legal exception `writeSliceHeader` carves out
// for an unscanned destination (`native_array.d`'s own contract): its block
// address is `null` (`NativeArray.allocate`'s own `GC.calloc(0, ...)`), so
// writing a null pointer loses nothing. Pinned directly on the written
// header's own bytes, not only on the round trip, since a wrong non-null
// `ptr` alongside a correct `length` of 0 would still read back equal.
@("place_value.writeValue.readValue.sliceRoundTripsZeroLengthArray")
unittest {
    import quickbite.backends.interpreter.native_array: readSliceHeaderBytes;

    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto place = placeAt(block, sliceType);

    writeValue(place, Value.arrayValue([]));

    auto header = readSliceHeaderBytes(block.bytes);
    header.length.should == 0;
    (header.ptr is null).should == true;

    AggregateValue.length(readValue(place)).should == 0;
}


// A slice element type that is itself a non-union struct must compose
// through `writeValue`'s own struct arm during the element write, exactly
// as `readValue`'s slice arm already does when reading elements back --
// the write-side counterpart of `place_value.readValue.
// sliceOfStructsRoundTripsNativeElements`, but through `writeValue`'s own
// allocation this time rather than a hand-built fixture.
@("place_value.writeValue.readValue.sliceOfStructsRoundTrips")
unittest {
    auto holderType = structTypeOf(q{
        struct SlicePoint { int x; int y; }
        struct SlicePointsHolder { SlicePoint[] s; }
    }, "SlicePointsHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto place = placeAt(block, sliceType);

    int firstX = 1;
    firstX = firstX * 3 + 1;
    int firstY = 2;
    firstY = firstY * 3 + 2;
    int secondX = 3;
    secondX = secondX * 3 + 3;
    int secondY = 4;
    secondY = secondY * 3 + 4;

    auto written = Value.arrayValue([
        Value.structValue("SlicePoint", [Value(firstX), Value(firstY)]),
        Value.structValue("SlicePoint", [Value(secondX), Value(secondY)]),
    ]);

    writeValue(place, written);

    auto readBack = readValue(place);
    AggregateValue.elementCount(readBack).should == 2;
    auto readFirst = AggregateValue.elementAt(readBack, 0);
    AggregateValue.fieldAt(readFirst, 0).should == Value(firstX);
    AggregateValue.fieldAt(readFirst, 1).should == Value(firstY);
    auto readSecond = AggregateValue.elementAt(readBack, 1);
    AggregateValue.fieldAt(readSecond, 0).should == Value(secondX);
    AggregateValue.fieldAt(readSecond, 1).should == Value(secondY);
}


// Writing a SHORTER array over a place that already holds a longer one
// must leave a header describing the NEW length, not the old one --
// `writeSliceValue` always allocates fresh backing storage sized to the
// incoming value rather than growing/shrinking whatever was there before
// (a written header is a snapshot, per `value.md`'s Containers contract),
// so the old, now-unreferenced array is simply left for the GC.
@("place_value.writeValue.readValue.sliceRewriteWithShorterArrayReplacesHeader")
unittest {
    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto place = placeAt(block, sliceType);

    writeValue(place, Value.arrayValue([Value(1), Value(2), Value(3), Value(4), Value(5)]));

    auto written = Value.arrayValue([Value(9), Value(8)]);
    writeValue(place, written);

    auto readBack = readValue(place);
    AggregateValue.length(readBack).should == 2;
    AggregateValue.elementAt(readBack, 0).should == Value(9);
    AggregateValue.elementAt(readBack, 1).should == Value(8);
}


// An element value `writeValue` cannot compose (a class-typed `void` value,
// here -- a class place accepts only an object body address or null) must
// refuse the WHOLE slice write, not silently leave part of
// the array written -- `place`'s own header is the LAST thing
// `writeSliceValue` writes, so a throw partway through the element loop
// must leave `place` exactly as it was beforehand, still describing
// whatever array was there first.
@("place_value.writeValue.sliceWithNonComposableElementTypeRefusesWholeWrite")
unittest {
    auto holderType = structTypeOf(q{
        class SliceElementClass { int x; }
        struct SliceHolder { SliceElementClass[] cs; }
    }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto place = placeAt(block, sliceType);

    auto original = Value.arrayValue([]);
    writeValue(place, original);

    writeValue(place, Value.arrayValue([Value.void_])).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: class place "
        ~ "requires an object pointer or null",
    );

    AggregateValue.length(readValue(place)).should == 0;
}


// The newly allocated backing storage's own scan attribute must match
// `layout.typeHasPointers` over the ELEMENT type, chosen once at
// allocation by `NativeArray.allocate` itself -- asserted directly on the
// real GC attribute (`value.md`'s Containers contract: "do not write
// `GC.collect`-survival tests for scan policy... assert the scan attribute
// directly"), not inferred from whether a collection happens to survive.
// `int` elements carry no pointers, so the array's block must be `NO_SCAN`.
@("place_value.writeValue.sliceElementBlockIsNoScanForPointerFreeElements")
unittest {
    import core.memory: GC;
    import quickbite.backends.interpreter.native_array: readSliceHeaderBytes;

    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto place = placeAt(block, sliceType);

    writeValue(place, Value.arrayValue([Value(1), Value(2)]));

    auto header = readSliceHeaderBytes(block.bytes);
    (GC.addrOf(header.ptr) is null).should == false;
    const attr = GC.getAttr(GC.addrOf(header.ptr));
    (attr & GC.BlkAttr.NO_SCAN).should == GC.BlkAttr.NO_SCAN;
}


// The pointer-bearing counterpart of the test above: a slice-of-slices
// element type (`int[]`) itself carries a pointer (its own `{ length, ptr }`
// header), so the outer array's block must be conservatively scanned or
// the inner arrays' own blocks become invisible to the collector. Also
// exercises `writeSliceValue` recursing into its own element write for a
// nested slice element, through the same generic `writeValue` dispatch
// every other element type already goes through.
@("place_value.writeValue.readValue.sliceElementBlockIsConservativeForPointerBearingElements")
unittest {
    import core.memory: GC;
    import quickbite.backends.interpreter.native_array: readSliceHeaderBytes;

    auto holderType = structTypeOf(q{ struct SliceHolder { int[][] xss; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto place = placeAt(block, sliceType);

    auto written = Value.arrayValue([
        Value.arrayValue([Value(1), Value(2)]),
        Value.arrayValue([Value(3)]),
    ]);

    writeValue(place, written);

    auto header = readSliceHeaderBytes(block.bytes);
    const attr = GC.getAttr(GC.addrOf(header.ptr));
    (attr & GC.BlkAttr.NO_SCAN).should == 0;

    const readBack = readValue(place);
    AggregateValue.isArray(readBack).should == true;
    AggregateValue.elementCount(readBack).should == 2;
    foreach (rowIndex; 0 .. AggregateValue.elementCount(readBack)) {
        const row = AggregateValue.elementAt(readBack, rowIndex);
        AggregateValue.isArray(row).should == true;
        AggregateValue.elementCount(row).should == written[rowIndex].length;
        foreach (columnIndex; 0 .. AggregateValue.elementCount(row))
            AggregateValue.elementAt(row, columnIndex).should ==
                written[rowIndex][columnIndex];
    }
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

    auto readBack = readValue(root);
    AggregateValue.elementCount(readBack).should == 3;
    AggregateValue.elementAt(readBack, 0).should == Value(first);
    AggregateValue.elementAt(readBack, 1).should == Value(second);
    AggregateValue.elementAt(readBack, 2).should == Value(third);
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

    auto readBack = readValue(root);
    readBack.isNativeAggregate.should == true;
    AggregateValue.elementCount(readBack).should == 2;

    auto readFirst = AggregateValue.elementAt(readBack, 0);
    AggregateValue.fieldAt(readFirst, 0).should == Value(firstX);
    AggregateValue.fieldAt(readFirst, 1).should == Value(firstY);
    auto readSecond = AggregateValue.elementAt(readBack, 1);
    AggregateValue.fieldAt(readSecond, 0).should == Value(secondX);
    AggregateValue.fieldAt(readSecond, 1).should == Value(secondY);
}


// A union composes as overlapping bytes: writing `i` (the whole 4-byte
// member) directly through its own `Place.field` must be visible,
// reinterpreted, through the narrower sibling `s` when the WHOLE union is
// read back -- the value.md "Unions" example made concrete, and the read
// side (`structValueAt`'s union arm, via `readValue`) needs no write
// through the top-level union `Value` at all to prove this: `Place.field`'s
// own offset arithmetic already lands both members at the same address.
@("place_value.readValue.unionWritingIntMemberIsVisibleThroughShortSiblingReinterpreted")
unittest {
    auto unionType = structTypeOf(q{ union U { int i; short s; } }, "U");
    auto fields = structFields(unionType);
    auto block = NativeBlock.allocate(typeByteSize(unionType), NativeBlock.Scan.no);
    auto root = placeAt(block, unionType);

    int writtenI = 7;
    writtenI = writtenI * 100_000 + 3;

    writeValue(root.field(fields[0]), Value(writtenI));

    AggregateValue.fieldAt(readValue(root), 1).asLong.should == cast(short) writtenI;
}


// The narrow-to-wide direction of the same reinterpretation: `s` (2 bytes)
// written alone leaves the block's remaining bytes at whatever `place`
// already held (zero, straight off `NativeBlock.allocate`) -- so `i`,
// read back, is `s`'s own bits zero-extended into the wider type, not
// sign-extended the way a `cast(int)` from `short` would be. A NEGATIVE
// short is what makes those two answers differ at all.
@("place_value.readValue.unionWritingShortMemberIsVisibleThroughIntSiblingReinterpreted")
unittest {
    auto unionType = structTypeOf(q{ union U { int i; short s; } }, "U");
    auto fields = structFields(unionType);
    auto block = NativeBlock.allocate(typeByteSize(unionType), NativeBlock.Scan.no);
    auto root = placeAt(block, unionType);

    short writtenS = -3;
    writtenS = cast(short)(writtenS * 1000 - 7);

    writeValue(root.field(fields[1]), Value(writtenS));

    AggregateValue.fieldAt(readValue(root), 0).asLong.should == cast(int) cast(ushort) writtenS;
    AggregateValue.fieldAt(readValue(root), 0).asLong.shouldNotEqual(cast(int) writtenS);
}


// The whole-union write side: `writeValue` on the union's OWN place, given
// `structValueAt`'s struct-shaped `Value` (one entry per declared member,
// already mutually consistent -- see `writeUnionValue`'s own header
// comment), round-trips through the WIDEST declared member's bytes alone.
// Here the widest member (`i`) is also the FIRST declared, the simplest
// case value.md's own union example gives.
@("place_value.writeValue.readValue.unionRoundTripsThroughWidestFirstDeclaredMember")
unittest {
    auto unionType = structTypeOf(q{ union U { int i; short s; } }, "U");
    auto block = NativeBlock.allocate(typeByteSize(unionType), NativeBlock.Scan.no);
    auto root = placeAt(block, unionType);

    int writtenI = 11;
    writtenI = writtenI * 100_000 + 13;

    auto written = Value.structValue("U", [Value(writtenI), Value(cast(short) writtenI)]);

    writeValue(root, written);

    const readBack = readValue(root);
    AggregateValue.isStruct(readBack).should == true;
    AggregateValue.fieldAt(readBack, 0).should == Value(writtenI);
    AggregateValue.fieldAt(readBack, 1).should == Value(cast(short) writtenI);
}


// `writeUnionValue` must find the WIDEST member by its own byte size, not
// just take the first declared one -- here the first-declared member (`s`)
// is the NARROWER one, so a write that (wrongly) picked it would only ever
// touch 2 of the block's 4 bytes, losing `i`'s own upper bytes (nonzero:
// `writtenI` is picked above 65536 so this would fail if that bug were
// reintroduced) on the round trip.
@("place_value.writeValue.readValue.unionRoundTripsThroughWidestMemberRegardlessOfDeclarationOrder")
unittest {
    auto unionType = structTypeOf(q{ union U { short s; int i; } }, "U");
    auto block = NativeBlock.allocate(typeByteSize(unionType), NativeBlock.Scan.no);
    auto root = placeAt(block, unionType);

    int writtenI = 11;
    writtenI = writtenI * 100_000 + 13;

    auto written = Value.structValue("U", [Value(cast(short) writtenI), Value(writtenI)]);

    writeValue(root, written);

    auto readBack = readValue(root);
    AggregateValue.fieldAt(readBack, 0).should == Value(cast(short) writtenI);
    AggregateValue.fieldAt(readBack, 1).should == Value(writtenI);
}


// DMD flattens an anonymous union's members directly into the enclosing
// struct's own fields, at overlapping offsets (`value.md`'s Unions
// section) -- `S` itself is not a `UnionDeclaration`, so this already goes
// through the plain (non-union) struct arm of `readValue`/`writeValue`,
// unchanged by this slice; the point of this fixture is that nothing about
// that generic per-field composition assumes fields never overlap, so the
// flattened case already round-trips correctly with no union-specific code
// needed at all.
@("place_value.writeValue.readValue.anonymousUnionFlattenedIntoStructRoundTrips")
unittest {
    auto type = structTypeOf(q{
        struct S {
            union { int i; short s; }
            int tag;
        }
    }, "S");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    int writtenI = 5;
    writtenI = writtenI * 100_000 + 17;
    int writtenTag = 9;
    writtenTag = writtenTag * 3 + 1;

    auto written = Value.structValue(
        "S", [Value(writtenI), Value(cast(short) writtenI), Value(writtenTag)]);

    writeValue(root, written);

    auto readBack = readValue(root);
    AggregateValue.fieldAt(readBack, 0).should == Value(writtenI);
    AggregateValue.fieldAt(readBack, 1).should == Value(cast(short) writtenI);
    AggregateValue.fieldAt(readBack, 2).should == Value(writtenTag);
}


// A NAMED union-typed field (unlike the anonymous case above) stays ONE
// field of its enclosing struct, at that field's own offset -- exercising
// this slice's new union arm through one extra level of `Place.field`
// nesting, the union counterpart of `structRoundTripsNestedStructField`.
@("place_value.writeValue.readValue.unionFieldNestedInsideStructComposesAtRightOffset")
unittest {
    auto type = structTypeOf(q{
        union U { int i; short s; }
        struct Outer { int tag; U u; }
    }, "Outer");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    int writtenTag = 4;
    writtenTag = writtenTag * 6 + 1;
    int writtenI = 8;
    writtenI = writtenI * 100_000 + 19;

    auto written = Value.structValue("Outer", [
        Value(writtenTag),
        Value.structValue("U", [Value(writtenI), Value(cast(short) writtenI)]),
    ]);

    writeValue(root, written);

    auto readBack = readValue(root);
    AggregateValue.fieldAt(readBack, 0).should == Value(writtenTag);
    auto unionValue = AggregateValue.fieldAt(readBack, 1);
    AggregateValue.fieldAt(unionValue, 0).should == Value(writtenI);
    AggregateValue.fieldAt(unionValue, 1).should == Value(cast(short) writtenI);
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


// A union whose declared members are all native scalars is composable --
// `readValue`/`writeValue` compose it exactly as they do a struct's own
// fields (`allFieldsComposable`, shared between the two arms).
@("place_value.isPlaceComposable.trueForUnionWithComposableMembers")
unittest {
    auto unionType = structTypeOf(q{ union U { int x; long y; } }, "U");
    isPlaceComposable(unionType).should == true;
}


// One non-composable member (a slice, here -- a pointer no longer
// disqualifies a member, see `isPlaceComposable.trueForPointer`) refuses
// the WHOLE union, exactly as one non-composable field refuses a whole
// class body (`isClassBodyComposable`'s own inherited-field test) --
// `writeValue`'s union arm would otherwise recurse into that member via
// `writeUnionValue` (were it ever the widest) or `readValue`'s union arm
// via `structValueAt` (always, since every member is read), either of
// which would throw.
@("place_value.isPlaceComposable.falseForUnionWithNonComposableMember")
unittest {
    auto unionType = structTypeOf(q{ union U { int x; int[] p; } }, "U");
    isPlaceComposable(unionType).should == false;
}


// A pointer's own bytes ARE the host address (`ai/plans/value.md`
// decision 15): the TYPE always composes as a leaf (`readValue`/
// `writeValue`'s pointer arms), so `isPlaceComposable` -- a type-shape
// question -- answers `true` unconditionally. `impl.d`'s `mirrorToFrame`/
// `assertFrameMirror` still decline a VALUE that is not itself a host
// address, through their own shared `placeShapeMatches` gate, not through
// this predicate.
@("place_value.isPlaceComposable.trueForPointer")
unittest {
    isPlaceComposable(Type.tint32.pointerTo).should == true;
}


// A pointer place's own bytes ARE the host address (`ai/plans/value.md`
// decision 15) -- writing a `Value.pointerValue` and reading it back
// must round-trip that exact address, with no element recursion at all.
@("place_value.writeValue.readValue.pointerRoundTripsHostAddress")
unittest {
    auto pointerType = Type.tint32.pointerTo;
    auto block = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, pointerType);

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto written = Value.pointerValue(pointee.address);

    writeValue(root, written);

    readValue(root).should == written;
}


// A stored `null` address reads back as `Value.null_` -- the same value
// `impl.d` produces for a `null` pointer literal (`isNullExp`'s non-array
// arm) -- not an invented `pointerValue(null)` shape.
@("place_value.writeValue.readValue.pointerRoundTripsNull")
unittest {
    auto pointerType = Type.tint32.pointerTo;
    auto block = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, pointerType);

    writeValue(root, Value.null_);

    readValue(root).should == Value.null_;
}


// A struct with a pointer field composes through the same per-field
// `writeValue`/`readValue` recursion as any other struct -- and the block
// backing it must be conservatively scanned, the mechanical fact
// `NativeStruct.allocate` already derives from `layout.typeHasPointers`
// (`value.md`'s Containers contract: never defaulted). Asserted directly
// on the GC attribute, not inferred from a `GC.collect` survival, per that
// same contract.
@("place_value.writeValue.readValue.structWithPointerFieldComposesAndBlockIsConservativelyScanned")
unittest {
    import core.memory: GC;
    import quickbite.backends.interpreter.native_struct: NativeStruct;

    auto type = structTypeOf(q{ struct PointerHolder { int* p; int x; } }, "PointerHolder");
    auto native = NativeStruct.allocate(type);
    auto root = placeAt(native.block, type);

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);

    int writtenX = 3;
    writtenX = writtenX * 4 + 1;

    auto written = Value.structValue(
        "PointerHolder", [Value.pointerValue(pointee.address), Value(writtenX)]);

    writeValue(root, written);

    auto readBack = readValue(root);
    AggregateValue.fieldAt(readBack, 0).should == Value.pointerValue(pointee.address);
    AggregateValue.fieldAt(readBack, 1).should == Value(writtenX);

    const attr = GC.getAttr(native.block.address);
    (attr & GC.BlkAttr.NO_SCAN).should == 0;
}


// A static array of pointers composes element by element, through
// `Place.index`'s inline stride arithmetic, exactly like a static array of
// any other place-composable element.
@("place_value.writeValue.readValue.staticArrayOfPointersComposes")
unittest {
    auto arrayType = Type.tint32.pointerTo.sarrayOf(2);
    auto block = NativeBlock.allocate(typeByteSize(arrayType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, arrayType);

    auto first = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto second = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);

    auto written = Value.arrayValue([
        Value.pointerValue(first.address),
        Value.pointerValue(second.address),
    ]);

    writeValue(root, written);

    auto readBack = readValue(root);
    AggregateValue.elementAt(readBack, 0).should == Value.pointerValue(first.address);
    AggregateValue.elementAt(readBack, 1).should == Value.pointerValue(second.address);
}


// Pointer places accept exactly the sole data-pointer carrier: a host address.
// The stored bytes must preserve that address without an identity side table.
@("place_value.writeValue.pointerHostAddressRoundTripsWithoutIdentityCarrier")
unittest {
    auto pointerType = Type.tint32.pointerTo;
    auto block = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, pointerType);

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto pointer = Value.pointerValue(pointee.address);
    writeValue(root, pointer);

    readValue(root).should == pointer;
}


// `Place.deref` already follows a pointer place's own stored address to
// the pointee; this proves the round trip end to end: `writeValue` stores
// a pointee's own address, `readValue` reads that same address back out
// boxed, and a NEW place composed straight from the read-back address
// reaches the identical pointee value -- the point of storing a host
// address at all, per decision 15.
@("place_value.writeValue.readValue.derefThroughWrittenPointerReachesPointeeValue")
unittest {
    auto pointerType = Type.tint32.pointerTo;
    auto block = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, pointerType);

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    int writtenPointee = 9;
    writtenPointee = writtenPointee * 3 + 2;
    writeScalar(pointerType.nextOf, pointee.bytes, Value(writtenPointee));

    writeValue(root, Value.pointerValue(pointee.address));

    auto readBack = readValue(root);
    auto pointeePlace = Place(readBack.pointerAddress, pointerType.nextOf);

    readValue(pointeePlace).asLong.should == writtenPointee;
}


// `real` is a composable place LEAF (its own codec, not `native_scalar`'s
// -- see `readValue`'s own header comment) -- and the whole point of the
// type: `written` needs `real`'s full mantissa, so truncating it to
// `double` and back loses bits (`written == back` below is `false`),
// proving this round trip actually exercises the WIDER type rather than
// merely agreeing with what a `double` codec would already give.
@("place_value.writeValue.readValue.realRoundTripsValueDoubleCannotRepresentExactly")
unittest {
    auto type = Type.tfloat80;
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    real one = 1;
    one = one * 1 + 0;
    real written = one + real.epsilon;

    // A genuine `double`-typed local, not a chained inline cast -- DMD does
    // not always force a real memory-width round trip for the latter, so it
    // can silently keep the FULL `real` precision through both casts
    // (observed on this host/compiler), defeating the point of this guard.
    const double narrowed = written;
    const back = cast(real) narrowed;
    (written == back).should == false;

    writeValue(root, Value(written));

    readValue(root).should == Value(written);
}


// `P.r` follows `P.c` with the host compiler's own `real.alignof` padding
// (16 on this host), so a round trip through `writeValue`/`readValue` must
// land `r` at DMD's own field offset independently of `c` -- the `real`
// counterpart of `structRoundTripsFlatScalarFields`.
@("place_value.writeValue.readValue.structRoundTripsRealFieldAtItsOwnOffset")
unittest {
    auto type = structTypeOf(q{ struct P { char c; real r; } }, "P");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    real one = 1;
    one = one * 1 + 0;
    real writtenR = one + real.epsilon;

    auto written = Value.structValue("P", [Value('x'), Value(writtenR)]);

    writeValue(root, written);

    const readBack = readValue(root);
    AggregateValue.isStruct(readBack).should == true;
    AggregateValue.fieldAt(readBack, 0).should == Value('x');
    AggregateValue.fieldAt(readBack, 1).should == Value(writtenR);
}


// A static array of `real` composes element by element, through `Place.
// index`'s inline stride arithmetic at DMD's own `real` stride (16 bytes
// on this host) -- the `real` counterpart of `staticArrayOfPointersComposes`.
@("place_value.writeValue.readValue.staticArrayOfRealComposesWithDmdOwnStride")
unittest {
    auto arrayType = Type.tfloat80.sarrayOf(2);
    auto block = NativeBlock.allocate(typeByteSize(arrayType), NativeBlock.Scan.no);
    auto root = placeAt(block, arrayType);

    real one = 1;
    one = one * 1 + 0;
    real first = one + real.epsilon;
    real two = 2;
    two = two * 1 + 0;
    real second = two + real.epsilon;

    auto written = Value.arrayValue([Value(first), Value(second)]);

    writeValue(root, written);

    auto readBack = readValue(root);
    AggregateValue.elementAt(readBack, 0).should == Value(first);
    AggregateValue.elementAt(readBack, 1).should == Value(second);
}


// The property the verified frame mirror's whole-slot RAW BYTE comparison
// depends on (`ai/plans/value.md`'s Layout authority contract): writing
// the SAME `real` value twice must produce IDENTICAL bytes, padding
// included, not merely an equal `real` on read-back. Asserted directly on
// the block's own raw bytes, not only on the round-tripped `Value`, since
// two different padding patterns could still both read back correctly
// (`readRealBits` never inspects the padding) while still breaking the
// mirror's byte-for-byte comparison.
//
// Both writes go into a destination pre-filled with a DIFFERENT non-zero
// pattern, and the padding is asserted zero rather than merely equal: an
// all-zero destination and a padding-preserving write agree by accident,
// so a write that copies only the significant bytes has to show up here.
@("place_value.writeValue.realWriteZeroesPaddingSoTwoWritesAreByteIdentical")
unittest {
    // x87 extended precision on this host: 10 significant bytes of the 16
    // `real` occupies, the rest padding (`writeRealBits`' own comment).
    enum significantByteLength = 10;

    auto type = Type.tfloat80;
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    real one = 1;
    one = one * 1 + 0;
    real written = one + real.epsilon;

    block.bytes[] = ubyte(0xab);
    writeValue(root, Value(written));
    auto firstBytes = block.bytes.dup;

    block.bytes[] = ubyte(0xcd);
    writeValue(root, Value(written));

    block.bytes.should == firstBytes;
    firstBytes[significantByteLength .. $].should ==
        new ubyte[firstBytes.length - significantByteLength];
}


@("place_value.isPlaceComposable.trueForReal")
unittest {
    isPlaceComposable(Type.tfloat80).should == true;
}


// `enum E : real` and `enum E : double` are legal D, and `writeValue` can
// Floating-base enums use their underlying floating scalar as the execution
// carrier. Typed native storage retains the enum type, so reads and writes
// still preserve the complete guest representation without forcing the
// integral-only `Value.enumValue` tag.
@("place_value.isPlaceComposable.trueForRealBasedEnum")
unittest {
    auto enumType = enumTypeOf(q{ enum E: real { a = 1.0L } }, "E");
    isPlaceComposable(enumType).should == true;
}


@("place_value.isPlaceComposable.trueForDoubleBasedEnum")
unittest {
    auto enumType = enumTypeOf(q{ enum E: double { a = 1.0 } }, "E");
    isPlaceComposable(enumType).should == true;
}


@("place_value.readValue.realBasedEnumReturnsUnderlyingScalar")
unittest {
    auto enumType = enumTypeOf(q{ enum E: real { a = 1.0L } }, "E");
    auto block = NativeBlock.allocate(typeByteSize(enumType), NativeBlock.Scan.no);
    auto root = placeAt(block, enumType);

    readValue(root).should == Value(0.0L);
}


@("place_value.writeValue.readValue.doubleBasedEnumRoundTripsUnderlyingScalar")
unittest {
    auto enumType = enumTypeOf(q{ enum E: double { a = 1.0 } }, "E");
    auto block = NativeBlock.allocate(typeByteSize(enumType), NativeBlock.Scan.no);
    auto root = placeAt(block, enumType);

    double written = 0.5;
    written = written + 0.5;

    writeValue(root, Value(written));

    readValue(root).should == Value(written);
}


// Floating-base enum leaves also compose when nested in a struct.
@("place_value.isPlaceComposable.trueForStructWithRealBasedEnumField")
unittest {
    auto type = structTypeOf(q{
        enum E: real { a = 1.0L }
        struct S { int tag; E e; }
    }, "S");
    isPlaceComposable(type).should == true;
}


// A `real` union member is one no boxed union write path re-derives from a
// sibling's bytes, so a union carrying one can hold entries that contradict
// each other: after `u.l = 42`, `impl.d`'s `withUnionFieldWrite` leaves
// `r` on its own default, `real.nan`. `real` being the wider member,
// writing it would splat NaN's bytes over the `l` the guest just assigned
// -- and the verify side, recomputing through the same `writeValue`, would
// land on the identical wrong bytes and see nothing. So the whole union
// declines instead.
@("place_value.isPlaceComposable.falseForUnionWithRealMember")
unittest {
    auto unionType = structTypeOf(q{ union U { real r; long l; } }, "U");
    isPlaceComposable(unionType).should == false;
}


// The pointer sibling of the case above: a pointer member is not
// re-derived either, and at the same width as `long` the first-declared
// tie-break picks it, storing `null` over the just-written `l`.
@("place_value.isPlaceComposable.falseForUnionWithPointerMember")
unittest {
    auto unionType = structTypeOf(q{ union U { int* p; long l; } }, "U");
    isPlaceComposable(unionType).should == false;
}


// A nested union member is skipped by `withUnionFieldWrite`'s sibling
// re-derivation exactly like `real` and a pointer are, so the outer union
// declines for the same reason -- and would anyway, since writing a nested
// union covers only ITS own widest member, not the outer union's extent.
@("place_value.isPlaceComposable.falseForUnionWithNestedUnionMember")
unittest {
    auto unionType = structTypeOf(q{
        union Inner { int i; short s; }
        union U { Inner inner; long l; }
    }, "U");
    isPlaceComposable(unionType).should == false;
}


// The widest member must cover every byte a sibling reads: `S` is 16 bytes
// with 7 of padding after `b`, so composing it field by field never touches
// bytes 9..15 -- which `x` reads as live data. The tie at 16 goes to the
// first-declared `S`, so this is not a case a different tie-break rescues.
@("place_value.isPlaceComposable.falseForUnionWhoseWidestMemberIsPadded")
unittest {
    auto unionType = structTypeOf(q{
        struct S { long l; byte b; }
        union U { S s; ubyte[16] x; }
    }, "U");
    isPlaceComposable(unionType).should == false;
}


// The same union with the padding removed composes: `S`'s two fields tile
// its whole 8 bytes, so writing `S` writes every byte `l` reads back.
@("place_value.isPlaceComposable.trueForUnionWhoseWidestMemberTilesItsExtent")
unittest {
    auto unionType = structTypeOf(q{
        struct S { int a; int b; }
        union U { S s; long l; }
    }, "U");
    isPlaceComposable(unionType).should == true;
}


// The same union with `S` grown an ANONYMOUS union of its own: DMD
// flattens `a` and `b` into `S`'s own fields at the same offset, so `S`
// does not compose (`allFieldsComposable`'s overlap gate), and a member
// that does not compose is not one the union write path re-derives
// coherently either. Both flattened members are native scalars, so nothing
// but the overlap check stops the member walk -- which is why this shape,
// and not the `real`/`long` neighbours above, is the one that reached
// `isUnionMemberReDerivable`'s "re-derivable implies composable" `out`
// contract and made the contract itself assert on a program the oracle
// runs.
@("place_value.isPlaceComposable.falseForUnionWithAnonymousUnionBearingStructMember")
unittest {
    auto unionType = structTypeOf(q{
        struct S { union { int a; float b; } }
        union U { S s; long l; }
    }, "U");
    isPlaceComposable(unionType).should == false;
}


// `union U {}` is legal D. It has no member for the single-member write to
// pick, so it declines -- rather than indexing an empty member list, which
// kills the whole interpreter with a `core.exception.ArrayIndexError` (an
// `Error`) the first time a guest program declares one.
@("place_value.isPlaceComposable.falseForEmptyUnion")
unittest {
    auto unionType = structTypeOf(q{ union U {} }, "U");
    isPlaceComposable(unionType).should == false;
}


// `writeValue` must agree with `isPlaceComposable` exactly, so a declined
// union is refused rather than half-written -- and refused with a plain
// `Exception`, the module's own decline shape, never an `Error`.
@("place_value.writeValue.declinesEmptyUnion")
unittest {
    auto unionType = structTypeOf(q{ union U {} }, "U");
    auto block = NativeBlock.allocate(typeByteSize(unionType), NativeBlock.Scan.no);
    auto root = placeAt(block, unionType);

    writeValue(root, Value.structValue("U", [])).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: union place "
        ~ "whose single widest-member write cannot stand in for the whole union",
    );
}


// The write-side half of `falseForUnionWithRealMember`: reached directly
// (not through `impl.d`'s gate), the writer declines the same shape the
// predicate does instead of writing `real.nan`'s bytes over `l`'s 42.
@("place_value.writeValue.declinesUnionWithRealMember")
unittest {
    auto unionType = structTypeOf(q{ union U { real r; long l; } }, "U");
    auto block = NativeBlock.allocate(typeByteSize(unionType), NativeBlock.Scan.no);
    auto root = placeAt(block, unionType);

    long writtenL = 21;
    writtenL = writtenL * 2;

    writeValue(root, Value.structValue("U", [Value(real.nan), Value(writtenL)]))
        .shouldThrowWithMessage(
            "quickbite.backends.interpreter.place_value.writeValue: union place "
            ~ "whose single widest-member write cannot stand in for the whole union",
        );
}


// No capability, no class: a caller with no identity namespace of its own
// receives the native body address, which is the authoritative identity.
@("place_value.readValue.returnsClassBodyAddressWithoutAnIdentityCapability")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    auto bodyBlock = NativeBlock.allocate(
        classInstanceByteSize(classType.sym), NativeBlock.Scan.conservative);

    auto referenceSlot = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    *cast(void**) referenceSlot.address = bodyBlock.address;
    auto referencePlace = placeAt(referenceSlot, classType);

    readValue(referencePlace).should == Value.pointerValue(bodyBlock.address);
}


// A boxed null slice is a length of zero, not an error. `Value.length`
// itself throws "Expected array." for `Value.null_`, which would otherwise
// make `writeValue` refuse a value the read side hands straight back: a
// `{ 0, null }` header reads as an empty array, never as `Value.null_`.
@("place_value.writeValue.readValue.nullSliceWritesAnEmptySlice")
unittest {
    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto block = NativeBlock.allocate(typeByteSize(sliceType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, sliceType);

    writeValue(root, Value.null_);

    AggregateValue.length(readValue(root)).should == 0;
}

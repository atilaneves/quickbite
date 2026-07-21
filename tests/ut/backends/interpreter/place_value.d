module ut.backends.interpreter.place_value;


import ut;
import ut.backends.interpreter: structTypeOf, classTypeOf, enumTypeOf;
import quickbite.backends.interpreter.place_value:
    readValue, writeValue, writeClassBody, isPlaceComposable, isClassBodyComposable;
import quickbite.backends.interpreter.place: Place, placeAt;
import quickbite.backends.interpreter.layout:
    fieldByteOffset, structFields, typeByteSize, classFields, classInstanceByteSize,
    classQualifiedName, classHierarchyNames, fieldName;
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


// Unlike `readValue`, `writeValue` still refuses a class-typed place
// outright -- writing one would mean storing a reference, and the only
// legal reference for an object identity is the address `object_table.
// ObjectTable` handed out for it, which this module has no access to (see
// `writeValue`'s own header comment). `writeValue` never touches `place`'s
// address before reaching this refusal, so a bare `Place(null, classType)`
// is safe here, unlike the class-composing tests below, which need a real
// allocated slot.
@("place_value.writeValue.classTypeThrows")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    auto place = Place(null, classType);

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
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


// The round trip this slice exists for: `writeClassBody` writes a boxed
// class `Value`'s fields into an already-allocated object body, and
// `readValue`, reached through a place holding a reference to that body,
// reads the identical fields back out -- plus the identity fact decision
// 15 makes the point of this redesign: the body's own address, not a
// minted counter.
@("place_value.writeClassBody.readValue.objectBodyRoundTripsItsFields")
unittest {
    auto classType = classTypeOf(q{ class C { int x; long y; } }, "C");
    auto bodyBlock = NativeBlock.allocate(
        classInstanceByteSize(classType.sym), NativeBlock.Scan.conservative);
    auto bodyPlace = placeAt(bodyBlock, classType);

    // Runtime-computed, not bare literals passed straight to `Value`.
    int writtenX = 3;
    writtenX = writtenX * 5 + 1;
    long writtenY = 1000L;
    writtenY = writtenY * 7 + 2;

    auto fields = classFields(classType.sym);
    auto written = Value.classValue(
        classQualifiedName(classType.sym),
        classHierarchyNames(classType.sym),
        [fieldName(fields[0]), fieldName(fields[1])],
        [Value(writtenX), Value(writtenY)],
        cast(size_t) bodyBlock.address,
    );

    writeClassBody(bodyPlace, written);

    auto referenceSlot = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    *cast(void**) referenceSlot.address = bodyBlock.address;
    auto referencePlace = placeAt(referenceSlot, classType);

    readValue(referencePlace).should == written;
}


// A derived class's body includes its base class's own fields, in DMD's
// own base-to-derived order (`layout.classFields`'s own contract) -- the
// class-body counterpart of `object_table.d`'s identical inheritance test.
@("place_value.writeClassBody.readValue.inheritedFieldsRoundTripInDmdOrder")
unittest {
    auto classType = classTypeOf(
        q{
            class Base { int baseField; }
            class Derived: Base { long derivedField; }
        },
        "Derived",
    );
    auto bodyBlock = NativeBlock.allocate(
        classInstanceByteSize(classType.sym), NativeBlock.Scan.conservative);
    auto bodyPlace = placeAt(bodyBlock, classType);

    int writtenBase = 2;
    writtenBase = writtenBase * 4 + 1;
    long writtenDerived = 300L;
    writtenDerived = writtenDerived * 6 + 3;

    auto fields = classFields(classType.sym);
    auto written = Value.classValue(
        classQualifiedName(classType.sym),
        classHierarchyNames(classType.sym),
        [fieldName(fields[0]), fieldName(fields[1])],
        [Value(writtenBase), Value(writtenDerived)],
        cast(size_t) bodyBlock.address,
    );

    writeClassBody(bodyPlace, written);

    auto referenceSlot = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    *cast(void**) referenceSlot.address = bodyBlock.address;
    auto referencePlace = placeAt(referenceSlot, classType);

    auto read = readValue(referencePlace);
    read.should == written;
    read.classFieldAt(0).asLong.should == writtenBase;
    read.classFieldAt(1).asLong.should == writtenDerived;
}


// A class field of struct, static-array, and enum type all compose the
// same way a struct's own fields do (`readValue`'s class arm recurses
// through the identical `readValue` a struct field already uses).
@("place_value.writeClassBody.readValue.structStaticArrayAndEnumFieldsCompose")
unittest {
    auto classType = classTypeOf(
        q{
            enum Colour: int { red, green, blue }
            struct P { int a; int b; }
            class C { P p; int[3] xs; Colour colour; }
        },
        "C",
    );
    auto bodyBlock = NativeBlock.allocate(
        classInstanceByteSize(classType.sym), NativeBlock.Scan.conservative);
    auto bodyPlace = placeAt(bodyBlock, classType);

    int writtenA = 1;
    writtenA = writtenA * 3 + 1;
    int writtenB = 2;
    writtenB = writtenB * 3 + 2;
    int first = 4;
    first = first * 2 + 1;
    int second = 5;
    second = second * 2 + 2;
    int third = 6;
    third = third * 2 + 3;

    auto fields = classFields(classType.sym);
    auto written = Value.classValue(
        classQualifiedName(classType.sym),
        classHierarchyNames(classType.sym),
        [fieldName(fields[0]), fieldName(fields[1]), fieldName(fields[2])],
        [
            Value.structValue("P", [Value(writtenA), Value(writtenB)]),
            Value.arrayValue([Value(first), Value(second), Value(third)]),
            Value.enumValue("Colour.green", 1),
        ],
        cast(size_t) bodyBlock.address,
    );

    writeClassBody(bodyPlace, written);

    auto referenceSlot = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    *cast(void**) referenceSlot.address = bodyBlock.address;
    auto referencePlace = placeAt(referenceSlot, classType);

    readValue(referencePlace).should == written;
}


@("place_value.isClassBodyComposable.trueForScalarStructStaticArrayAndEnumFields")
unittest {
    auto classType = classTypeOf(
        q{
            enum Colour: int { red, green, blue }
            struct P { int a; }
            class C { P p; int[3] xs; Colour colour; int y; }
        },
        "C",
    );

    isClassBodyComposable(classType.sym).should == true;
}


// A slice-typed field still answers `false`, even though `writeValue` can
// now compose a slice on its own: `isClassBodyComposable` (like `
// isPlaceComposable`, which it recurses through per field) is the
// eligibility gate for the verified FRAME mirror, not a claim about what
// `writeValue` itself can do -- a slice local's frame slot mirrors only
// its native header (`impl.d`'s `mirrorSliceToFrame`), never the full
// place composition this predicate gates, so a slice-bearing class body
// stays off that path regardless.
@("place_value.isClassBodyComposable.falseForClassWithSliceField")
unittest {
    auto classType = classTypeOf(q{ class C { int[] xs; } }, "C");

    isClassBodyComposable(classType.sym).should == false;
}


// Inherited fields count too: a base class field that is itself not
// composable (here, a slice -- a pointer no longer disqualifies a field,
// see `isPlaceComposable.trueForPointer`) makes the WHOLE derived body
// refused, since `writeClassBody` writes every field `layout.classFields`
// returns, inherited ones included.
@("place_value.isClassBodyComposable.falseForInheritedNonComposableField")
unittest {
    auto classType = classTypeOf(
        q{
            class Base { int[] p; }
            class Derived: Base { int x; }
        },
        "Derived",
    );

    isClassBodyComposable(classType.sym).should == false;
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

    readValue(place).should == written;
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

    readValue(place).should == Value.arrayValue([]);
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

    readValue(place).should == written;
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

    readValue(place).should == written;
}


// An element type `writeValue` cannot compose (a class element, here --
// see `writeValue`'s own header comment for why class-typed places always
// refuse) must refuse the WHOLE slice write, not silently leave part of
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

    writeValue(place, Value.arrayValue([Value.null_])).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );

    readValue(place).should == original;
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

    readValue(place).should == written;
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

    readValue(root).structFieldAt(1).asLong.should == cast(short) writtenI;
}


// The narrow-to-wide direction of the same reinterpretation: `s` (2 bytes)
// written alone leaves the block's remaining bytes at whatever `place`
// already held (zero, straight off `NativeBlock.allocate`) -- so `i`,
// read back, is `s`'s own bits zero-extended into the wider type, not
// sign-extended the way a `cast(int)` from `short` would be.
@("place_value.readValue.unionWritingShortMemberIsVisibleThroughIntSiblingReinterpreted")
unittest {
    auto unionType = structTypeOf(q{ union U { int i; short s; } }, "U");
    auto fields = structFields(unionType);
    auto block = NativeBlock.allocate(typeByteSize(unionType), NativeBlock.Scan.no);
    auto root = placeAt(block, unionType);

    short writtenS = 3;
    writtenS = cast(short)(writtenS * 1000 + 7);

    writeValue(root.field(fields[1]), Value(writtenS));

    readValue(root).structFieldAt(0).asLong.should == cast(int) cast(ushort) writtenS;
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

    readValue(root).should == written;
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

    readValue(root).should == written;
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

    readValue(root).should == written;
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

    readValue(root).should == written;
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
// decision 15) -- writing a `Value.nativePointerValue` and reading it back
// must round-trip that exact address, with no element recursion at all.
@("place_value.writeValue.readValue.pointerRoundTripsHostAddress")
unittest {
    auto pointerType = Type.tint32.pointerTo;
    auto block = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, pointerType);

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto written = Value.nativePointerValue(pointee.address);

    writeValue(root, written);

    readValue(root).should == written;
}


// A stored `null` address reads back as `Value.null_` -- the same value
// `impl.d` produces for a `null` pointer literal (`isNullExp`'s non-array
// arm) -- not an invented `nativePointerValue(null)` shape.
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
        "PointerHolder", [Value.nativePointerValue(pointee.address), Value(writtenX)]);

    writeValue(root, written);

    readValue(root).should == written;

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
        Value.nativePointerValue(first.address),
        Value.nativePointerValue(second.address),
    ]);

    writeValue(root, written);

    readValue(root).should == written;
}


// Unlike a native pointer or `Value.null_`, a boxed pointer carrier with no
// host address of its own (here, `Value.localPointerValue`, the boxed-era
// allocation-id carrier) has nothing `writeValue` can store -- it must
// refuse the write, value-dependently, and leave `place`'s existing
// address untouched rather than fabricate one.
@("place_value.writeValue.pointerWithBoxedNonHostAddressValueRefusesAndLeavesDestinationUnchanged")
unittest {
    auto pointerType = Type.tint32.pointerTo;
    auto block = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.conservative);
    auto root = placeAt(block, pointerType);

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto original = Value.nativePointerValue(pointee.address);
    writeValue(root, original);

    writeValue(root, Value.localPointerValue(7)).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: pointer "
        ~ "place requires a Value holding a host address (a native pointer "
        ~ "or null), not a boxed pointer carrier with no host address to "
        ~ "store",
    );

    readValue(root).should == original;
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

    writeValue(root, Value.nativePointerValue(pointee.address));

    auto readBack = readValue(root);
    auto pointeePlace = Place(readBack.asNativePointer, pointerType.nextOf);

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

    readValue(root).should == written;
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

    readValue(root).should == written;
}


// The property the verified frame mirror's whole-slot RAW BYTE comparison
// depends on (`ai/plans/value.md`'s Layout authority contract): writing
// the SAME `real` value twice must produce IDENTICAL bytes, padding
// included, not merely an equal `real` on read-back. Asserted directly on
// the block's own raw bytes, not only on the round-tripped `Value`, since
// two different padding patterns could still both read back correctly
// (`readRealBits` never inspects the padding) while still breaking the
// mirror's byte-for-byte comparison.
@("place_value.writeValue.realWritePaddingIsDeterministicAcrossTwoWrites")
unittest {
    auto type = Type.tfloat80;
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    real one = 1;
    one = one * 1 + 0;
    real written = one + real.epsilon;

    writeValue(root, Value(written));
    auto firstBytes = block.bytes.dup;

    writeValue(root, Value(written));
    auto secondBytes = block.bytes.dup;

    firstBytes.should == secondBytes;
}


@("place_value.isPlaceComposable.trueForReal")
unittest {
    isPlaceComposable(Type.tfloat80).should == true;
}

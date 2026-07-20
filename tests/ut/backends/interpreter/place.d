module ut.backends.interpreter.place;


import ut;
import ut.backends.interpreter: structTypeOf, classTypeOf, parseFunction;
import quickbite.backends.interpreter.place: Place, placeAt;
import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, structFields, typeByteSize;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.frame_layout: computeFrameLayout;
import quickbite.backends.interpreter.frame_block: FrameBlock;
import quickbite.lang: Value;

private:


struct P {
    int x;
    long y;
}


// The centrepiece for `field`: `P.y` follows `P.x` with the host compiler's
// own alignment padding (`int` then `long` leaves 4 padding bytes before
// `y`), so a naive "pack fields with no padding" implementation would put
// `y` at the wrong address. Store/load-back through each field's own
// `Place` must also be independent of the other: writing `y` must not
// perturb `x`'s bytes.
@("Place.field.addressesMatchLayoutOffsetsAndScalarStoreLoadRoundTripsIndependently")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto fields = structFields(type);
    auto xField = fields[0];
    auto yField = fields[1];

    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    auto xPlace = root.field(xField);
    auto yPlace = root.field(yField);

    xPlace.address.should == block.address;
    (cast(size_t) yPlace.address).should == cast(size_t) block.address + fieldByteOffset(yField);
    fieldByteOffset(yField).should == P.y.offsetof;

    // Runtime-computed, not bare literals passed straight to `Value`.
    int writtenX = 3;
    writtenX = writtenX * 5 + 1;
    long writtenY = 1000L;
    writtenY = writtenY * 7 + 2;

    xPlace.storeScalar(Value(writtenX));
    yPlace.storeScalar(Value(writtenY));

    xPlace.loadScalar.asLong.should == writtenX;
    yPlace.loadScalar.asLong.should == writtenY;

    // Overwriting `y` must leave `x`'s already-stored bytes untouched.
    long overwrittenY = writtenY + 11;
    yPlace.storeScalar(Value(overwrittenY));

    xPlace.loadScalar.asLong.should == writtenX;
    yPlace.loadScalar.asLong.should == overwrittenY;
}


struct ArrayHolder {
    int[4] xs;
}


// The centrepiece for `index`: element 0 sits at the array's own base
// address, and element 2 follows at `2 * int.sizeof` -- the same stride
// `NativeArray.element` computes, applied here to a bare `Place` address.
@("Place.index.staticArrayElementAddressesMatchStrideAndScalarStoreLoadRoundTrips")
unittest {
    auto holderType = structTypeOf(q{ struct ArrayHolder { int[4] xs; } }, "ArrayHolder");
    auto arrayType = structFields(holderType)[0].type;

    auto block = NativeBlock.allocate(typeByteSize(arrayType), NativeBlock.Scan.no);
    auto root = placeAt(block, arrayType);

    root.index(0).address.should == block.address;
    (cast(size_t) root.index(2).address).should == cast(size_t) block.address + 2 * int.sizeof;

    int written = 6;
    written = written * 9 + 4;
    root.index(2).storeScalar(Value(written));

    root.index(2).loadScalar.asLong.should == written;

    // Element 2's write must not perturb element 0.
    root.index(0).loadScalar.asLong.should == 0;
}


struct PointerHolder {
    int* p;
}


// The centrepiece for `index` on a POINTER place: the place's own address
// holds a stored `int*`, not element bytes -- element 0 sits at the STORED
// pointer's own address, and element 2 follows at that same address plus
// `2 * int.sizeof`, never at any offset from the pointer PLACE's own
// address (which holds only the 8-byte pointer value itself).
@("Place.index.pointerElementAddressesFollowTheStoredPointerAndScalarStoreLoadRoundTrips")
unittest {
    auto holderType = structTypeOf(q{ struct PointerHolder { int* p; } }, "PointerHolder");
    auto pointerType = structFields(holderType)[0].type;

    auto ints = NativeBlock.allocate(4 * int.sizeof, NativeBlock.Scan.no);
    auto pointerBlock = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.no);
    *(cast(void**) pointerBlock.address) = ints.address;

    auto root = placeAt(pointerBlock, pointerType);

    root.index(0).address.should == ints.address;
    (cast(size_t) root.index(2).address).should == cast(size_t) ints.address + 2 * int.sizeof;

    int written = 6;
    written = written * 9 + 4;
    root.index(2).storeScalar(Value(written));

    root.index(2).loadScalar.asLong.should == written;

    // Element 2's write must not perturb element 0.
    root.index(0).loadScalar.asLong.should == 0;
}


// The centrepiece for `deref` on a POINTER place: the place's own address
// holds a stored `int*`, and `deref` must land ON the stored pointer's own
// address, at the pointee's element type -- a scalar round trip through the
// deref'd place must reach the same bytes `index(0)` already does.
@("Place.deref.pointerPlaceFollowsTheStoredPointerToThePointeeAndScalarRoundTrips")
unittest {
    auto holderType = structTypeOf(q{ struct PointerHolder { int* p; } }, "PointerHolder");
    auto pointerType = structFields(holderType)[0].type;

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto pointerBlock = NativeBlock.allocate(typeByteSize(pointerType), NativeBlock.Scan.no);
    *(cast(void**) pointerBlock.address) = pointee.address;

    auto root = placeAt(pointerBlock, pointerType);
    auto dereffed = root.deref;

    dereffed.address.should == pointee.address;
    (dereffed.type is pointerType.nextOf).should == true;

    int written = 4;
    written = written * 5 + 3;
    dereffed.storeScalar(Value(written));

    root.index(0).loadScalar.asLong.should == written;
}


class C {
    int x;
    long y;
}


// The centrepiece for `deref` on a CLASS place: a class variable's own
// address holds a stored REFERENCE to its object body, not the object's
// bytes -- `deref` must land on that referenced object body,
// keeping the class type so a following `.field` composes at
// `objectAddress + fieldByteOffset(field)`, DMD's own class field offset.
// The object body block here is sized and laid out from
// `layout.classFields`/`fieldByteOffset` alone (never a guessed offset).
// `C.x.offsetof`/`C.y.offsetof`/`__traits(classInstanceSize, C)` are the
// HOST compiler's own numbers for an identically-shaped class (its own
// object header included, unlike a struct's `.offsetof`) -- cross-checking
// against them is what proves the parsed snippet's `fieldByteOffset`/
// `typeByteSize` numbers are DMD's own, not a guess this test made up.
@("Place.deref.classPlaceFollowsTheStoredReferenceToTheObjectBodyAndFieldsComposeAtDmdOffsets")
unittest {
    auto classType = classTypeOf(q{ class C { int x; long y; } }, "C");
    auto fields = classFields(classType.sym);
    auto xField = fields[0];
    auto yField = fields[1];

    fieldByteOffset(xField).should == C.x.offsetof;
    fieldByteOffset(yField).should == C.y.offsetof;

    size_t bodyByteSize;
    foreach (field; fields) {
        const end = fieldByteOffset(field) + typeByteSize(field.type);
        if (end > bodyByteSize)
            bodyByteSize = end;
    }
    bodyByteSize.should == __traits(classInstanceSize, C);

    auto body_ = NativeBlock.allocate(bodyByteSize, NativeBlock.Scan.no);

    auto referenceBlock = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    *(cast(void**) referenceBlock.address) = body_.address;

    auto root = placeAt(referenceBlock, classType);
    auto dereffed = root.deref;

    dereffed.address.should == body_.address;
    (dereffed.type is classType).should == true;

    int writtenX = 2;
    writtenX = writtenX * 6 + 1;
    long writtenY = 100L;
    writtenY = writtenY * 3 + 4;

    dereffed.field(xField).storeScalar(Value(writtenX));
    dereffed.field(yField).storeScalar(Value(writtenY));

    (cast(size_t) dereffed.field(xField).address).should == cast(size_t) body_.address + fieldByteOffset(xField);
    (cast(size_t) dereffed.field(yField).address).should == cast(size_t) body_.address + fieldByteOffset(yField);

    dereffed.field(xField).loadScalar.asLong.should == writtenX;
    dereffed.field(yField).loadScalar.asLong.should == writtenY;
}


@("Place.deref.nonPointerNonClassPlaceThrows")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    root.deref.shouldThrowWithMessage(
        "quickbite.backends.interpreter.place.Place.deref: only a "
        ~ "pointer or class place can be dereferenced",
    );
}


struct SliceHolder {
    int[] s;
}


// The centrepiece for `index` on a SLICE place: the place's own address
// holds a `{ length, ptr }` header -- element `i` sits at the header's own
// `ptr` field plus `i * int.sizeof`, never at any offset from the header's
// own address (which holds only the 16-byte header itself).
@("Place.index.sliceElementAddressesFollowTheHeadersPointerAndScalarStoreLoadRoundTrips")
unittest {
    import quickbite.backends.interpreter.native_array: NativeArray;

    auto holderType = structTypeOf(q{ struct SliceHolder { int[] s; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;

    auto elements = NativeBlock.allocate(3 * int.sizeof, NativeBlock.Scan.no);
    auto elementsArray = NativeArray.adopt(elements, sliceType.nextOf, 3);

    auto headerBlock = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    elementsArray.writeSliceHeader(headerBlock, 0);

    auto root = placeAt(headerBlock, sliceType);

    root.index(0).address.should == elements.address;
    (cast(size_t) root.index(1).address).should == cast(size_t) elements.address + int.sizeof;
    (cast(size_t) root.index(2).address).should == cast(size_t) elements.address + 2 * int.sizeof;

    int written = 3;
    written = written * 8 + 5;
    root.index(1).storeScalar(Value(written));

    root.index(1).loadScalar.asLong.should == written;

    // Element 1's write must not perturb elements 0 or 2.
    root.index(0).loadScalar.asLong.should == 0;
    root.index(2).loadScalar.asLong.should == 0;

    root.index(3).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place.Place.index: "
        ~ "index out of range for slice place",
    );
}


@("Place.loadScalar.nonScalarPlaceThrows")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    root.loadScalar.shouldThrowWithMessage(
        "quickbite.backends.interpreter.place.Place.loadScalar: "
        ~ "type is not a native scalar type",
    );
}


@("Place.storeScalar.nonScalarPlaceThrows")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    root.storeScalar(Value(1)).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place.Place.storeScalar: "
        ~ "type is not a native scalar type",
    );
}


@("Place.placeAt.frameBlockSlotAddressAndDeclaredTypeMatchTheVariablesOwnSlot")
unittest {
    auto function_ = parseFunction(
        q{ void quickbitePlaceFrameSlot(int a, long b) {} },
        "quickbitePlaceFrameSlot",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);
    auto a = (*function_.parameters)[0];
    auto b = (*function_.parameters)[1];

    auto aPlace = placeAt(frame, a);
    auto bPlace = placeAt(frame, b);

    aPlace.address.should == frame.slotAddress(a);
    bPlace.address.should == frame.slotAddress(b);

    // Runtime-computed, not a bare literal passed straight to `Value`.
    int writtenA = 2;
    writtenA = writtenA * 21;

    aPlace.storeScalar(Value(writtenA));

    aPlace.loadScalar.asLong.should == writtenA;
}

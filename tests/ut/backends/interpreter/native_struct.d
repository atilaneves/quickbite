module ut.backends.interpreter.native_struct;


import ut;
import ut.backends.interpreter: structTypeOf;
import quickbite.backends.interpreter.native_struct: NativeStruct;
import quickbite.backends.interpreter.native_array: NativeArray;
import quickbite.backends.interpreter.native_block: NativeBlock;
import dmd.mtype: Type;

private:


// Oracle: `S`'s field offsets and byte size come from the host compiler's
// own layout of the identical struct declared below, not a hand-written
// expectation -- a naive "sum the field sizes" implementation would fail
// here, since `byte a; int b;` leaves 3 padding bytes before `b`.
struct S {
    byte a;
    int b;
    long c;
}


@("NativeStruct.allocate.byteSizeMatchesHostCompilerSizeofDespitePadding")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.byteSize.should == S.sizeof;
}


@("NativeStruct.allocate.fieldCountMatchesDeclarationCount")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.fieldCount.should == 3;
}


@("NativeStruct.field.viewOffsetAndLengthMatchHostCompilerOffsetofAndSizeof")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.field(0).length.should == byte.sizeof;
    struct_.field(1).length.should == int.sizeof;
    struct_.field(2).length.should == long.sizeof;

    struct_.field(0).ptr.should == struct_.block.bytes.ptr + S.a.offsetof;
    struct_.field(1).ptr.should == struct_.block.bytes.ptr + S.b.offsetof;
    struct_.field(2).ptr.should == struct_.block.bytes.ptr + S.c.offsetof;
}


@("NativeStruct.field.writeThroughFieldViewIsVisibleAtItsOwnBlockOffset")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    // A recognisable byte pattern written through the field view must show
    // up at the block's own offset -- proving `field` aliases the block
    // rather than copying it.
    struct_.field(1)[] = [0x11, 0x22, 0x33, 0x44];

    struct_.block.bytes[S.b.offsetof .. S.b.offsetof + int.sizeof]
        .should == [0x11, 0x22, 0x33, 0x44];
}


@("NativeStruct.field.writeThroughBlockOffsetIsVisibleThroughFieldView")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.block.bytes[S.c.offsetof .. S.c.offsetof + long.sizeof] =
        [1, 2, 3, 4, 5, 6, 7, 8];

    struct_.field(2).should == [1, 2, 3, 4, 5, 6, 7, 8];
}


@("NativeStruct.field.outOfRangeIndexThrows")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.field(3).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "field: index out of range",
    );
}


@("NativeStruct.fieldByteOffset.matchesHostCompilerOffsetofForEachField")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.fieldByteOffset(0).should == S.a.offsetof;
    struct_.fieldByteOffset(1).should == S.b.offsetof;
    struct_.fieldByteOffset(2).should == S.c.offsetof;
}


@("NativeStruct.fieldByteOffset.outOfRangeIndexThrows")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.fieldByteOffset(3).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "fieldByteOffset: index out of range",
    );
}


struct E {
}


@("NativeStruct.allocate.emptyStructByteSizeMatchesHostCompilerSizeof")
unittest {
    auto type = structTypeOf(q{ struct E {} }, "E");
    auto struct_ = NativeStruct.allocate(type);

    // D gives an empty struct `.sizeof == 1`.
    struct_.byteSize.should == E.sizeof;
}


@("NativeStruct.allocate.emptyStructHasNoFields")
unittest {
    auto type = structTypeOf(q{ struct E {} }, "E");
    auto struct_ = NativeStruct.allocate(type);

    struct_.fieldCount.should == 0;
}


struct WithSlice {
    int[] xs;
}


@("NativeStruct.allocate.pointerBearingFieldYieldsScannedBlock")
unittest {
    import core.memory: GC;

    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);
    const attr = GC.getAttr(GC.addrOf(struct_.block.address));

    (attr & GC.BlkAttr.NO_SCAN).should == 0;
    struct_.scan.should == NativeBlock.Scan.conservative;
}


@("NativeStruct.allocate.allScalarFieldsYieldNoScanBlock")
unittest {
    import core.memory: GC;

    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);
    const attr = GC.getAttr(GC.addrOf(struct_.block.address));

    (attr & GC.BlkAttr.NO_SCAN).should == GC.BlkAttr.NO_SCAN;
    struct_.scan.should == NativeBlock.Scan.no;
}


// The centrepiece: a struct's `int[]` field gets a real D slice header,
// written by `NativeArray.writeSliceHeader` at the field's own
// `fieldByteOffset`, and read back by reinterpreting the struct's block
// bytes as the host compiler's own `WithSlice` -- the same
// host-compiler-as-oracle discipline `native_array.d`'s reinterpret tests
// use to pin slice field order, now applied across the array/struct
// composition. `WithSlice` gets its `Scan.conservative` block from
// `typeHasPointers` (pinned above by
// `allocate.pointerBearingFieldYieldsScannedBlock`), which is exactly what
// `writeSliceHeader`'s scanned-destination check demands -- the two
// contracts were written independently and this is where they meet.
//
// This is honestly just a header-round-trips-as-a-host-slice test, not a
// liveness test: no `GC.collect` is attempted here (unlike an earlier
// version of this test). D's GC conservatively scans the stack and
// registers, so a collect afterwards cannot distinguish "the element block
// is kept alive by the scanned struct field" from "a stale pointer
// bit-pattern happens to still sit in an unreused stack slot" -- it would
// pass even with a wrong scan policy, proving nothing. The real,
// deterministic test of the scan policy itself is
// `allocate.pointerBearingFieldYieldsScannedBlock` above, which asserts
// `Scan.conservative` directly rather than inferring it from survival
// after a collection.
@("NativeStruct.field.writeSliceHeaderIntoSliceFieldReinterpretsAsHostCompilerSlice")
@system
unittest {
    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);
    auto elements = NativeArray.allocate(Type.tint32, 3);
    // Full 4-byte stores, not `element(i)[0] = ...`: writing only byte 0 of
    // a 4-byte `int` would be endian-dependent (and rely on the block
    // already being zeroed for the other three bytes to read back as 0).
    *cast(int*) elements.element(0).ptr = 1;
    *cast(int*) elements.element(1).ptr = 2;
    *cast(int*) elements.element(2).ptr = 3;
    elements.writeSliceHeader(struct_.block, struct_.fieldByteOffset(0));

    auto guest = *cast(WithSlice*) struct_.block.address;
    guest.xs.should == [1, 2, 3];
}


// A struct with only scalar fields gets a `Scan.no` block (pinned above by
// `allocate.allScalarFieldsYieldNoScanBlock`); writing a slice header into
// it must throw exactly as it would into any other unscanned destination --
// this is the other half of the contract meeting: a struct whose fields
// don't need scanning is not a legal slice-header destination.
@("NativeStruct.field.writeSliceHeaderIntoScalarOnlyStructFieldThrows")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);
    auto elements = NativeArray.allocate(Type.tint32, 3);

    elements.writeSliceHeader(struct_.block, struct_.fieldByteOffset(0)).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "writeSliceHeader: dest is not scanned by the GC, but "
        ~ "this array's block address is a live GC pointer",
    );
}


struct Header {
    long tag;
    int[] xs;
}


// Exercises `fieldByteOffset` at a non-zero offset for real: `xs` is the
// second field, so the header write must land past `tag`, leave `tag`
// untouched, and the reinterpret oracle must confirm both fields.
@("NativeStruct.field.writeSliceHeaderAtNonZeroOffsetLeavesOtherFieldUntouched")
@system
unittest {
    auto type = structTypeOf(q{ struct Header { long tag; int[] xs; } }, "Header");
    auto struct_ = NativeStruct.allocate(type);
    *cast(long*) struct_.field(0).ptr = 99;

    {
        auto elements = NativeArray.allocate(Type.tint32, 2);
        // Full 4-byte stores, not `element(i)[0] = ...`: writing only byte 0
        // of a 4-byte `int` would be endian-dependent (and rely on the block
        // already being zeroed for the other three bytes to read back as 0).
        *cast(int*) elements.element(0).ptr = 7;
        *cast(int*) elements.element(1).ptr = 8;
        elements.writeSliceHeader(struct_.block, struct_.fieldByteOffset(1));
    }

    auto guest = *cast(Header*) struct_.block.address;
    guest.tag.should == 99;
    guest.xs.should == [7, 8];
}


@("NativeStruct.borrow.reportsBorrowedOwnership")
@system
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    S backing;
    auto struct_ = NativeStruct.borrow(type, &backing);

    struct_.ownership.should == NativeBlock.Ownership.borrowed;
}


@("NativeStruct.borrow.writeThroughFieldViewReachesOriginalMemory")
@system
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    S backing;
    auto struct_ = NativeStruct.borrow(type, &backing);

    struct_.field(1)[] = [0x11, 0x22, 0x33, 0x44];

    (cast(ubyte*) &backing.b)[0 .. 4].should == [0x11, 0x22, 0x33, 0x44];
}


struct Inner {
    int x;
    long y;
}


struct Outer {
    int a;
    Inner inner;
}


// The centrepiece for struct-in-struct: `outer.structField(1)` is not a
// separate block, it is a sub-range of `Outer`'s one block at DMD's own
// offset for `inner`, laid out with `Inner`'s own field offsets relative
// to that sub-range. A write through the nested view's field 1 (`Inner.y`)
// must land at `Outer.inner.offsetof + Inner.y.offsetof` in the *parent's*
// bytes -- proving the nested view aliases the parent rather than copying
// it, and that its own field offsets are relative to the sub-range, not
// to the parent's block from byte 0.
@("NativeStruct.structField.writeThroughNestedFieldViewLandsAtOffsetRelativeToParentInHostCompilerBytes")
unittest {
    auto type = structTypeOf(
        q{ struct Inner { int x; long y; } struct Outer { int a; Inner inner; } },
        "Outer",
    );
    auto outer = NativeStruct.allocate(type);

    outer.structField(1).field(1)[] = [1, 2, 3, 4, 5, 6, 7, 8];

    const offset = Outer.inner.offsetof + Inner.y.offsetof;
    outer.block.bytes[offset .. offset + long.sizeof].should == [1, 2, 3, 4, 5, 6, 7, 8];
}


@("NativeStruct.structField.reportsBorrowedOwnershipEvenThoughParentIsOwned")
unittest {
    auto type = structTypeOf(
        q{ struct Inner { int x; long y; } struct Outer { int a; Inner inner; } },
        "Outer",
    );
    auto outer = NativeStruct.allocate(type);

    outer.ownership.should == NativeBlock.Ownership.owned;
    outer.structField(1).ownership.should == NativeBlock.Ownership.borrowed;
}


struct InnerWithSlice {
    int[] xs;
}


struct OuterWithSlice {
    int a;
    InnerWithSlice inner;
}


// A struct-in-struct view shares the parent's `Scan` policy exactly:
// `Scan` is an attribute of the whole underlying GC allocation, chosen
// once at `allocate` time from whether *any* field, at any nesting depth,
// carries pointers -- not a per-sub-range attribute the view could
// legitimately disagree with its parent about.
@("NativeStruct.structField.sharesParentConservativeScanPolicy")
unittest {
    auto type = structTypeOf(
        q{ struct InnerWithSlice { int[] xs; } struct OuterWithSlice { int a; InnerWithSlice inner; } },
        "OuterWithSlice",
    );
    auto outer = NativeStruct.allocate(type);

    outer.scan.should == NativeBlock.Scan.conservative;
    outer.structField(1).scan.should == NativeBlock.Scan.conservative;
}


@("NativeStruct.structField.indexOfNonStructFieldThrows")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.structField(1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "structField: field is not a struct",
    );
}


@("NativeStruct.structField.outOfRangeIndexThrows")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.structField(3).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "structField: index out of range",
    );
}


struct Holder {
    int[3] xs;
}


// The oracle for "inline, not a slice header": a slice-header field
// (`{ size_t length; int* ptr; }`) would make `Holder.sizeof == 16`;
// `int[3]` packed inline is `Holder.sizeof == 12`, three `int`s and
// nothing else.
@("NativeStruct.allocate.staticArrayFieldByteSizeIsInlineNotASliceHeader")
unittest {
    auto type = structTypeOf(q{ struct Holder { int[3] xs; } }, "Holder");
    auto struct_ = NativeStruct.allocate(type);

    struct_.byteSize.should == Holder.sizeof;
    Holder.sizeof.should == 12;
}


@("NativeStruct.arrayField.lengthAndStrideMatchHostCompilerElementCountAndElementSizeof")
unittest {
    auto type = structTypeOf(q{ struct Holder { int[3] xs; } }, "Holder");
    auto struct_ = NativeStruct.allocate(type);
    auto xs = struct_.arrayField(0);

    xs.length.should == 3;
    xs.stride.should == int.sizeof;
}


// Writing element 2 through the array view must land at
// `Holder.xs.offsetof + 2 * int.sizeof` in the parent's bytes -- read back
// by reinterpreting the struct's block as the host compiler's own
// `Holder`, the same oracle discipline the slice-header tests above use.
@("NativeStruct.arrayField.writeThroughViewIsVisibleAtHostCompilerOffsetForElement2")
@system
unittest {
    auto type = structTypeOf(q{ struct Holder { int[3] xs; } }, "Holder");
    auto struct_ = NativeStruct.allocate(type);
    auto xs = struct_.arrayField(0);

    *cast(int*) xs.element(2).ptr = 42;

    auto guest = *cast(Holder*) struct_.block.address;
    guest.xs[2].should == 42;
}


@("NativeStruct.arrayField.indexOfDynamicArrayFieldThrows")
unittest {
    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);

    struct_.arrayField(0).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "arrayField: field is not a static array",
    );
}


// `Holder.xs` is field 0 -- a ZERO-offset sub-range of `struct_`'s block --
// so its address IS the parent's own base pointer: a real 16-byte GC bin
// for this 12-byte struct. Without `NativeBlock.trueByteSize`'s borrowed
// guard, `GC.sizeOf` on that base address would report the bin size (16),
// making `capacity` claim 4 elements of phantom growth room on a view that
// cannot legitimately grow at all (`reserve` refuses to reallocate any
// borrowed block).
@("NativeStruct.arrayField.capacityIsZeroForZeroOffsetSubRangeView")
unittest {
    auto type = structTypeOf(q{ struct Holder { int[3] xs; } }, "Holder");
    auto struct_ = NativeStruct.allocate(type);
    auto xs = struct_.arrayField(0);

    xs.capacity.should == 0;
}


@("NativeStruct.arrayField.outOfRangeIndexThrows")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto struct_ = NativeStruct.allocate(type);

    struct_.arrayField(3).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "arrayField: index out of range",
    );
}


// `arrayField`'s array is a *borrowed* sub-range of `struct_`'s own owned GC
// block (`NativeBlock.subRange`'s `Ownership.borrowed`), but that block is
// still live GC memory -- exactly the case `writeSliceHeader`'s scanned-
// destination check must not wave through just because the source's
// `Ownership` is `borrowed`. `Holder` has no pointer-bearing fields, so
// `struct_` itself is `Scan.no`; that is irrelevant here -- the hazard is
// writing `xs`'s (GC-visible) block address into `dest`, a *different*,
// unscanned block, which would leave the struct's own bytes reachable only
// through unscanned storage.
@("NativeStruct.arrayField.writeSliceHeaderOfBorrowedSubRangeIntoNoScanDestinationThrows")
unittest {
    auto type = structTypeOf(q{ struct Holder { int[3] xs; } }, "Holder");
    auto struct_ = NativeStruct.allocate(type);
    auto xs = struct_.arrayField(0);
    auto dest = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.no);

    xs.writeSliceHeader(dest, 0).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_array.NativeArray."
        ~ "writeSliceHeader: dest is not scanned by the GC, but "
        ~ "this array's block address is a live GC pointer",
    );
}

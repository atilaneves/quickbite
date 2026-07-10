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


// The centrepiece for read-back: `sliceField` reconstructs a `NativeArray`
// from the header `writeSliceHeader` wrote, aliasing the SAME element
// block rather than copying it -- a write through the read-back handle
// must be visible through the original `elements` handle too.
@("NativeStruct.sliceField.roundTripAliasesWriteSliceHeaderSourceArray")
@system
unittest {
    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);
    auto elements = NativeArray.allocate(Type.tint32, 3);
    *cast(int*) elements.element(0).ptr = 1;
    *cast(int*) elements.element(1).ptr = 2;
    *cast(int*) elements.element(2).ptr = 3;
    elements.writeSliceHeader(struct_.block, struct_.fieldByteOffset(0));

    auto readBack = struct_.sliceField(0);
    readBack.length.should == 3;

    *cast(int*) readBack.element(1).ptr = 99;
    (*cast(int*) elements.element(1).ptr).should == 99;
}


// The honest contract, pinned directly rather than inferred from a
// `GC.collect` survival test: per this plan's own "ownership vs
// GC-visibility" note, a collect afterwards cannot distinguish a correct
// scan policy from a stale stack bit pattern, so it proves nothing and is
// deliberately not used here. `ownership`/`scan`/`capacity` come from
// `NativeBlock.borrow`'s own contract regardless of the fact that the
// pointed-to element block is, in this test, a real, conservatively
// scanned GC allocation kept alive by the (scanned) struct field itself.
@("NativeStruct.sliceField.readBackArrayReportsBorrowedOwnershipAndNoScanRegardlessOfElementBlockScanPolicy")
@system
unittest {
    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);
    auto elements = NativeArray.allocate(Type.tint32, 3);
    elements.writeSliceHeader(struct_.block, struct_.fieldByteOffset(0));

    auto readBack = struct_.sliceField(0);

    readBack.ownership.should == NativeBlock.Ownership.borrowed;
    readBack.scan.should == NativeBlock.Scan.no;
    readBack.capacity.should == 0;
}


// Exercises `fieldByteOffset` at a non-zero offset for real (`xs` is the
// second field of `Header`, mirroring the write-side non-zero-offset test
// above), and confirms the sibling `tag` field is untouched, against the
// host compiler's own `Header.xs` as the oracle for the read-back length
// and elements.
@("NativeStruct.sliceField.nonZeroOffsetMatchesHostCompilerSliceLeavingSiblingFieldUntouched")
@system
unittest {
    auto type = structTypeOf(q{ struct Header { long tag; int[] xs; } }, "Header");
    auto struct_ = NativeStruct.allocate(type);
    *cast(long*) struct_.field(0).ptr = 99;
    auto elements = NativeArray.allocate(Type.tint32, 2);
    *cast(int*) elements.element(0).ptr = 7;
    *cast(int*) elements.element(1).ptr = 8;
    elements.writeSliceHeader(struct_.block, struct_.fieldByteOffset(1));

    auto guest = *cast(Header*) struct_.block.address;
    auto xs = struct_.sliceField(1);

    xs.length.should == guest.xs.length;
    (*cast(int*) xs.element(0).ptr).should == guest.xs[0];
    (*cast(int*) xs.element(1).ptr).should == guest.xs[1];
    guest.tag.should == 99;
}


// A field that was never written keeps the block's zero-initialised
// `{ length: 0, ptr: null }` bytes -- the same header a default-initialised
// `int[]` guest variable has -- and must read back as a real, empty array
// rather than throwing.
@("NativeStruct.sliceField.zeroLengthNullHeaderReadsBackAsEmptyBorrowedArray")
@system
unittest {
    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);

    auto xs = struct_.sliceField(0);

    xs.length.should == 0;
    xs.ownership.should == NativeBlock.Ownership.borrowed;
}


@("NativeStruct.sliceField.outOfRangeIndexThrows")
@system
unittest {
    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);

    struct_.sliceField(1).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "sliceField: index out of range",
    );
}


@("NativeStruct.sliceField.indexOfStaticArrayFieldThrows")
@system
unittest {
    auto type = structTypeOf(q{ struct Holder { int[3] xs; } }, "Holder");
    auto struct_ = NativeStruct.allocate(type);

    struct_.sliceField(0).shouldThrowWithMessage(
        "quickbite.backends.interpreter.native_struct.NativeStruct."
        ~ "sliceField: field is not a dynamic array",
    );
}


// item 7's "unions and overlapping fields" open question: a D `union` is a
// `TypeStruct` whose `sym` is DMD's `UnionDeclaration` (`dstruct.d`'s
// `UnionDeclaration` extends `StructDeclaration` and adds nothing to
// `fields`/`structsize`/`hasPointerField` -- only its `kind()` differs), so
// `structTypeOf` -- whose search loop uses `member.isStructDeclaration`,
// which DMD itself defines to accept a `DSYM.unionDeclaration` node too
// (`dsymbol.d`) -- finds a top-level `union` unmodified; no change to that
// helper was needed. `U`'s own layout is the host-compiler oracle for the
// four tests below, exactly as `S`'s is for the struct tests above.
union U {
    size_t i;
    void* p;
}


@("NativeStruct.allocate.unionFieldOffsetsAreAllZeroMatchingHostCompilerOffsetof")
unittest {
    auto type = structTypeOf(q{ union U { size_t i; void* p; } }, "U");
    auto union_ = NativeStruct.allocate(type);

    union_.fieldCount.should == 2;
    U.i.offsetof.should == 0;
    U.p.offsetof.should == 0;
    union_.fieldByteOffset(0).should == U.i.offsetof;
    union_.fieldByteOffset(1).should == U.p.offsetof;
}


@("NativeStruct.allocate.unionByteSizeMatchesHostCompilerSizeof")
unittest {
    auto type = structTypeOf(q{ union U { size_t i; void* p; } }, "U");
    auto union_ = NativeStruct.allocate(type);

    union_.byteSize.should == U.sizeof;
}


// The centrepiece: `i` and `p` alias the SAME bytes at offset 0 (pinned
// above against `U.i.offsetof`/`U.p.offsetof`), so a write through one
// member's `field` view must be visible through the other's -- unmodified
// `NativeStruct.field` behaviour, since it only ever reads DMD's own
// `offset`/byte-size for whichever index is asked for and has no
// struct-vs-union branch to get wrong.
@("NativeStruct.field.writeThroughOneUnionMemberIsVisibleThroughTheOther")
unittest {
    auto type = structTypeOf(q{ union U { size_t i; void* p; } }, "U");
    auto union_ = NativeStruct.allocate(type);

    union_.field(0)[] = [1, 2, 3, 4, 5, 6, 7, 8];

    union_.field(1).should == [1, 2, 3, 4, 5, 6, 7, 8];
}


// Scan-policy rounding: `U` has a `void*` member, so `layout.
// typeHasPointers` (DMD's `hasPointerField`, computed by ORing every
// field's own `hasPointers` regardless of overlap) reports true, and
// `NativeStruct.allocate` picks `Scan.conservative` exactly as it would for
// a struct with a pointer field. That is the only safe rounding for a
// block whose `Scan` attribute covers its whole byte range, not
// per-member: scanning `i`'s bytes as a possible pointer when `i` is
// really holding an unrelated `size_t` is, at worst, a false-positive
// retention (the GC keeps some address-shaped garbage integer's target
// alive a little longer than needed) -- annoying, never unsound. Rounding
// the other way -- `Scan.no` because SOME member is a non-pointer scalar --
// would be a false negative: whenever `p` is the union's live member, its
// target becomes invisible to the collector and can be freed while `p`
// still points at it, a use-after-free. A block-wide `Scan` attribute has
// no way to be selectively right for both members at once, so it must
// round toward the safe failure mode (retain), never the unsafe one
// (collect-while-reachable).
@("NativeStruct.allocate.unionWithPointerMemberYieldsScannedBlock")
unittest {
    import core.memory: GC;

    auto type = structTypeOf(q{ union U { size_t i; void* p; } }, "U");
    auto union_ = NativeStruct.allocate(type);
    const attr = GC.getAttr(GC.addrOf(union_.block.address));

    (attr & GC.BlkAttr.NO_SCAN).should == 0;
    union_.scan.should == NativeBlock.Scan.conservative;
}


// Overlapping fields also arise from an ANONYMOUS union inside an ordinary
// struct -- DMD flattens an anonymous union's members directly into the
// enclosing struct's own `fields` (`dsymbolsem.d`'s `AnonDeclaration.
// setFieldOffset` recurses into its members with the SAME `ad`, resetting
// its own `FieldState.offset` back to 0 after each member so every member
// starts from the anonymous union's own base offset) rather than nesting a
// separate `TypeStruct` -- so there is no second aggregate for
// `NativeStruct` to descend into here; `i` and `f` are just two more
// top-level fields of `WithAnonymousUnion`, at the same offset as each
// other. Anonymous-union members are also promoted into the enclosing
// struct's own name scope, so `WithAnonymousUnion.i`/`.f.offsetof` name
// them directly, exactly like `WithAnonymousUnion.tag.offsetof` does.
struct WithAnonymousUnion {
    int tag;
    union {
        int i;
        float f;
    }
}


@("NativeStruct.allocate.anonymousUnionMembersAreFlattenedIntoParentFieldsAtOverlappingOffsets")
unittest {
    auto type = structTypeOf(
        q{ struct WithAnonymousUnion { int tag; union { int i; float f; } } },
        "WithAnonymousUnion",
    );
    auto struct_ = NativeStruct.allocate(type);

    struct_.fieldCount.should == 3;
    struct_.fieldByteOffset(0).should == WithAnonymousUnion.tag.offsetof;
    struct_.fieldByteOffset(1).should == WithAnonymousUnion.i.offsetof;
    struct_.fieldByteOffset(2).should == WithAnonymousUnion.f.offsetof;
    WithAnonymousUnion.i.offsetof.should == WithAnonymousUnion.f.offsetof;
}


// The authoritative overlap fact, per item 7's guardrail ("DMD-derived
// layout facts stay the source of truth; the interpreter must not grow a
// second set of D layout rules"): DMD's own `VarDeclaration.overlapped`,
// computed by `dsymbolsem.d`'s `checkOverlappedFields` from the fields'
// own offset/size ranges -- not a second, hand-rolled "do these offsets
// coincide" check of this codebase's own. `tag` overlaps nothing; `i` and
// `f` overlap each other.
@("NativeStruct.allocate.anonymousUnionMembersAreMarkedOverlappedByDmdItself")
unittest {
    auto type = structTypeOf(
        q{ struct WithAnonymousUnion { int tag; union { int i; float f; } } },
        "WithAnonymousUnion",
    );
    auto struct_ = NativeStruct.allocate(type);

    struct_.fieldDeclaration(0).overlapped.should == false;
    struct_.fieldDeclaration(1).overlapped.should == true;
    struct_.fieldDeclaration(2).overlapped.should == true;
}


// A write through one anonymous-union member's `field` view is visible
// through the other's, and leaves the non-overlapping `tag` field
// untouched -- unmodified `NativeStruct.field` behaviour again, since
// `WithAnonymousUnion` is an ordinary (if DMD-flattened) `TypeStruct` as
// far as this accessor is concerned.
@("NativeStruct.field.writeThroughOneAnonymousUnionMemberIsVisibleThroughTheOtherTagUntouched")
unittest {
    auto type = structTypeOf(
        q{ struct WithAnonymousUnion { int tag; union { int i; float f; } } },
        "WithAnonymousUnion",
    );
    auto struct_ = NativeStruct.allocate(type);

    struct_.field(1)[] = [1, 2, 3, 4];

    struct_.field(2).should == [1, 2, 3, 4];
    struct_.field(0).should == [0, 0, 0, 0];
}

module ut.backends.interpreter.native_struct;


import ut;
import quickbite.backends.interpreter.native_struct: NativeStruct;
import quickbite.backends.interpreter.native_array: NativeArray;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.frontend.compiler: parseSnippet;
import dmd.mtype: TypeStruct, Type;

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
// The element block is allocated and written to inside a nested scope, so
// by the time `GC.collect` runs, the only surviving reference to it is
// through the (conservatively scanned) struct field itself, not a
// `NativeArray` handle still live on this frame -- otherwise this would
// pass merely because `elements` was still on the stack.
@("NativeStruct.field.writeSliceHeaderIntoSliceFieldReinterpretsAsHostCompilerSlice")
@system
unittest {
    import core.memory: GC;

    auto type = structTypeOf(q{ struct WithSlice { int[] xs; } }, "WithSlice");
    auto struct_ = NativeStruct.allocate(type);

    {
        auto elements = NativeArray.allocate(Type.tint32, 3);
        elements.element(0)[0] = 1;
        elements.element(1)[0] = 2;
        elements.element(2)[0] = 3;
        elements.writeSliceHeader(struct_.block, struct_.fieldByteOffset(0));
    }
    GC.collect;

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
        elements.element(0)[0] = 7;
        elements.element(1)[0] = 8;
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


// Parses `source`, finds the `struct` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeStruct`.
TypeStruct structTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto struct_ = member.isStructDeclaration)
            if (struct_.ident.toString == name)
                return cast(TypeStruct) struct_.type;

    assert(false, "struct `" ~ name ~ "` not found in parsed snippet");
}

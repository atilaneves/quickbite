module ut.backends.interpreter.native_struct;


import ut;
import quickbite.backends.interpreter.native_struct: NativeStruct;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.frontend.compiler: parseSnippet;
import dmd.mtype: TypeStruct;

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

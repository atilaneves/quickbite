module ut.backends.interpreter.layout;


import ut;
import quickbite.backends.interpreter.layout:
    typeByteSize, typeHasPointers, structFields, fieldByteOffset;
import quickbite.frontend.compiler: parseSnippet;
import dmd.mtype: Type, TypeStruct;

private:


@("typeByteSize.int32IsFourBytes")
unittest {
    typeByteSize(Type.tint32).should == 4;
}


@("typeByteSize.int64IsEightBytes")
unittest {
    typeByteSize(Type.tint64).should == 8;
}


@("typeByteSize.unsizedTypeThrows")
unittest {
    typeByteSize(Type.terror).shouldThrow;
}


@("typeByteSize.unsizedTypeThrowsMessageNamesTheType")
unittest {
    typeByteSize(Type.terror).shouldThrowWithMessage(
        "quickbite.backends.interpreter.layout.typeByteSize: no size "
        ~ "for type `_error_`",
    );
}


@("typeHasPointers.pointerTypeReportsPointers")
unittest {
    typeHasPointers(Type.tvoidptr).should == true;
}


@("typeHasPointers.plainIntegralReportsNoPointers")
unittest {
    typeHasPointers(Type.tint32).should == false;
}


// Oracle: `S`'s field offsets and size come from the host compiler's own
// layout of the identical struct declared below, not a hand-written
// expectation -- a naive "sum the field sizes" implementation would fail
// here, since `byte a; int b;` leaves 3 padding bytes before `b`.
struct S {
    byte a;
    int b;
    long c;
}


@("structFields.fieldOffsetsMatchHostCompilerOffsetofDespitePadding")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");
    auto fields = structFields(type);

    fieldByteOffset(fields[0]).should == S.a.offsetof;
    fieldByteOffset(fields[1]).should == S.b.offsetof;
    fieldByteOffset(fields[2]).should == S.c.offsetof;
}


@("typeByteSize.structSizeMatchesHostCompilerSizeofDespitePadding")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");

    typeByteSize(type).should == S.sizeof;
}


@("structFields.fieldCountMatchesDeclarationCount")
unittest {
    auto type = structTypeOf(q{ struct S { byte a; int b; long c; } }, "S");

    structFields(type).length.should == 3;
}


struct E {
}


@("structFields.emptyStructHasNoFields")
unittest {
    auto type = structTypeOf(q{ struct E {} }, "E");

    structFields(type).length.should == 0;
}


@("typeByteSize.emptyStructSizeMatchesHostCompilerSizeof")
unittest {
    auto type = structTypeOf(q{ struct E {} }, "E");

    // D gives an empty struct `.sizeof == 1`.
    typeByteSize(type).should == E.sizeof;
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

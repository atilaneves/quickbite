module ut.backends.interpreter.layout;


import ut;
import ut.backends.interpreter: structTypeOf, enumTypeOf;
import quickbite.backends.interpreter.layout:
    typeByteSize, typeHasPointers, structFields, fieldByteOffset,
    enumMemberQualifiedName;
import dmd.mtype: Type;

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


@("enumMemberQualifiedName.returnsTheQualifiedNameOfTheMatchingMember")
unittest {
    auto type = enumTypeOf(q{ enum Colour : int { red, green, blue } }, "Colour");

    enumMemberQualifiedName(type, 1).should == "Colour.green";
}


// The first-declared member wins when a value has no unique owner -- DMD
// itself allows an explicit duplicate value (`blue = 1` here reuses
// `green`'s value), and this function must pick one deterministically
// rather than depend on undefined behaviour if iteration order ever
// changed.
@("enumMemberQualifiedName.picksTheFirstDeclaredMemberWhenValuesAreDuplicated")
unittest {
    auto type = enumTypeOf(
        q{ enum Colour : int { red, green, blue = 1 } }, "Colour");

    enumMemberQualifiedName(type, 1).should == "Colour.green";
}


@("enumMemberQualifiedName.returnsNullForAValueNoMemberHas")
unittest {
    auto type = enumTypeOf(q{ enum Colour : int { red, green, blue } }, "Colour");

    enumMemberQualifiedName(type, 5).length.should == 0;
}

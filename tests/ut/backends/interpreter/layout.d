module ut.backends.interpreter.layout;


import ut;
import ut.backends.interpreter: structTypeOf, enumTypeOf, classTypeOf;
import quickbite.backends.interpreter.layout:
    typeByteSize, typeHasPointers, structFields, fieldByteOffset,
    enumMemberQualifiedName, classInstanceByteSize;
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


// Oracle: `C`'s instance size, including the vtable pointer/monitor header
// DMD lays down at the front of every class object, comes from the host
// compiler's own `__traits(classInstanceSize, ...)` for the identical
// class declared below -- a naive "sum the field ends" implementation
// would under-count by omitting that header.
class C {
    int x;
}


@("classInstanceByteSize.matchesHostCompilerClassInstanceSizeIncludingVtableAndMonitor")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");

    classInstanceByteSize(classType.sym).should == __traits(classInstanceSize, C);
}


// Oracle: `Derived`'s instance size folds in its base class `Base`'s own
// field plus the shared vtable/monitor header, not just the fields
// `Derived` itself newly declares.
class Base {
    int baseField;
}
class Derived: Base {
    long derivedField;
}


@("classInstanceByteSize.includesInheritedFields")
unittest {
    auto classType = classTypeOf(
        q{
            class Base { int baseField; }
            class Derived: Base { long derivedField; }
        },
        "Derived",
    );

    classInstanceByteSize(classType.sym).should == __traits(classInstanceSize, Derived);
}


// Oracle: `Empty`'s instance size is the vtable/monitor header alone --
// `__traits(classInstanceSize, ...)` for the identical class declared
// below. A "sum the field ends" implementation has no fields to sum here
// and gives 0, under-sizing the object down to nothing rather than the
// header every class instance actually carries.
class Empty {
}


@("classInstanceByteSize.fieldlessClassSizeIsTheHeaderAloneNotZero")
unittest {
    auto classType = classTypeOf(q{ class Empty {} }, "Empty");

    classInstanceByteSize(classType.sym).should == __traits(classInstanceSize, Empty);
    (classInstanceByteSize(classType.sym) > 0).should == true;
}


// An enum whose base type is not integral has no member constant this
// function can ask DMD for as an integer: `Expression.toInteger` on a
// `StringExp` member does not answer, it EMITS "integer constant expression
// expected" into DMD's global error state and returns 0 -- so an unguarded
// walk would both dirty the compiler's own diagnostics from inside a read
// and label a `value` of 0 with the first such member's name. `global.errors`
// is the observable half of that: it must be untouched.
@("enumMemberQualifiedName.declinesANonIntegralBaseWithoutDirtyingDmdsErrorState")
unittest {
    import dmd.globals: global;

    auto type = enumTypeOf(
        q{ enum Name : string { first = "a", second = "b" } }, "Name");

    const errorsBefore = global.errors;
    enumMemberQualifiedName(type, 0).length.should == 0;
    global.errors.should == errorsBefore;
}

module ut.backends.interpreter.object_table;


import ut;
import ut.backends.interpreter: classTypeOf;
import quickbite.backends.interpreter.object_table: ObjectTable;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, typeByteSize;
import quickbite.backends.interpreter.native_scalar: writeScalar, readScalar;
import quickbite.backends.interpreter.runtime_value: Value;
import std.algorithm.searching: canFind;
import std.conv: text;
import std.exception: collectExceptionMsg;

private:


@("ObjectTable.storageFor.stableAddressAcrossRepeatedCallsForTheSameIdentity")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    ObjectTable table;

    auto first = table.storageFor(1, classType.sym);
    auto second = table.storageFor(1, classType.sym);

    second.should == first;
}


@("ObjectTable.storageFor.distinctIdentitiesGetDistinctBodies")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    ObjectTable table;

    auto first = table.storageFor(1, classType.sym);
    auto second = table.storageFor(2, classType.sym);

    (first != second).should == true;
}


// Oracle: `Derived`'s instance size, including its base class `Base`'s
// own field and the vtable/monitor header DMD lays down at the front of
// every class object, comes from the host compiler's own `__traits
// (classInstanceSize, ...)` for the identical hierarchy declared below --
// not a hand-derived sum of field ends, which would omit that header.
class Base {
    int baseField;
}
class Derived: Base {
    long derivedField;
}

// The identical hierarchy as source, for `classTypeOf` -- kept as one
// shared string so both tests below parse the SAME declarations the host
// `Base`/`Derived` above are compiled from, rather than two hand-typed
// (and possibly drifting) copies.
private enum classHierarchySource = q{
    class Base { int baseField; }
    class Derived: Base { long derivedField; }
};


@("ObjectTable.storageFor.blockByteLengthMatchesDmdInstanceSizeIncludingInheritedFields")
unittest {
    auto classType = classTypeOf(classHierarchySource, "Derived");
    ObjectTable table;

    table.storageFor(1, classType.sym);

    table[1].byteLength.should == __traits(classInstanceSize, Derived);
}


// The bug this defense-in-depth guard closes: `storageFor` sizes an
// identity's body block from whichever caller's `class_` shows up FIRST
// (`Base`, here), and without the guard would hand that same block back
// UNCHANGED to a later caller passing a WIDER class (`Derived`) for the
// SAME identity -- silently, since `place.Place` has no bounds check of its
// own and `writeClassBody` would go on to write `Derived`'s wider field
// layout through it. `impl.d`'s `classBodyShapeMatches` is the actual gate that
// keeps this from happening in the real mirror pipeline (it declines
// whenever a static type's name disagrees with the boxed value's own
// dynamic one, before either mirror direction ever reaches `storageFor`);
// this is only the low-level backstop, proven directly here by calling
// `storageFor` the same mismatched way a caller bug would.
@("ObjectTable.storageFor.widerSecondCallForTheSameIdentityThrows")
unittest {
    auto baseType = classTypeOf(classHierarchySource, "Base");
    auto derivedType = classTypeOf(classHierarchySource, "Derived");
    ObjectTable table;

    table.storageFor(1, baseType.sym);

    // `classQualifiedName`'s snippet module prefix varies per run
    // (`runner/lang/expressions.d`'s own `typeid.typeNameReturnsIdentifier`
    // test notes the identical fact), so this matches the stable suffix
    // rather than the whole message; the byte counts come from the same
    // `__traits(classInstanceSize, ...)` oracle the test above uses, not
    // hand-derived literals.
    const message = collectExceptionMsg!Exception(table.storageFor(1, derivedType.sym));
    message.canFind(text(
        "storageFor: identity 1's already-allocated body is ",
        __traits(classInstanceSize, Base), " bytes, but ",
    )).should == true;
    message.canFind(text(
        ".Derived needs ", __traits(classInstanceSize, Derived),
        " -- a caller passed a class narrower or wider than the one this ",
        "identity was first allocated for",
    )).should == true;
}


@("ObjectTable.storageFor.objectBodyGetsConservativeScanPolicy")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    ObjectTable table;

    table.storageFor(1, classType.sym);

    table[1].scan.should == NativeBlock.Scan.conservative;
}


@("ObjectTable.storageFor.fieldWriteReadRoundTripsAtItsDmdOffset")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    ObjectTable table;

    auto address = table.storageFor(1, classType.sym);
    auto field = classFields(classType.sym)[0];
    auto offset = fieldByteOffset(field);
    auto bytes = (cast(ubyte*) address)[offset .. offset + typeByteSize(field.type)];

    // Runtime-computed, not a bare literal passed straight to `Value`.
    int written = 3;
    written = written * 7 + 1;

    writeScalar(field.type, bytes, Value(written));

    readScalar(field.type, bytes).asLong.should == written;
}


// `generation` answers "has anyone rewritten this body since I last looked"
// (`impl.d`'s `classMirrorGenerations`/`assertClassBodyValue`), so every
// call that hands an address out has to bump it -- a second mirror write for
// a SHARED identity is exactly what the consumer needs to hear about. A call
// that THROWS handed nothing out and wrote nothing, so it must stay silent:
// bumping there tells every other binding its snapshot is stale on the
// strength of a call that did nothing at all.
@("ObjectTable.generation.bumpsForEveryCallThatHandsAnAddressOutButNotForARefusedOne")
unittest {
    auto baseType = classTypeOf(classHierarchySource, "Base");
    auto derivedType = classTypeOf(classHierarchySource, "Derived");
    ObjectTable table;

    table.generation(1).should == 0;

    table.storageFor(1, baseType.sym);
    const afterAllocation = table.generation(1);
    (afterAllocation > 0).should == true;

    table.storageFor(1, baseType.sym);
    table.generation(1).should == afterAllocation + 1;

    const beforeRefusal = table.generation(1);
    table.storageFor(1, derivedType.sym).shouldThrow!Exception;
    table.generation(1).should == beforeRefusal;
}

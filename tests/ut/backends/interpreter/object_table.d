module ut.backends.interpreter.object_table;


import ut;
import ut.backends.interpreter: classTypeOf;
import quickbite.backends.interpreter.object_table: ObjectTable;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, typeByteSize;
import quickbite.backends.interpreter.native_scalar: writeScalar, readScalar;
import quickbite.lang: Value;

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


@("ObjectTable.storageFor.blockByteLengthMatchesDmdInstanceSizeIncludingInheritedFields")
unittest {
    auto classType = classTypeOf(
        q{
            class Base { int baseField; }
            class Derived: Base { long derivedField; }
        },
        "Derived",
    );
    ObjectTable table;

    table.storageFor(1, classType.sym);

    table[1].byteLength.should == __traits(classInstanceSize, Derived);
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

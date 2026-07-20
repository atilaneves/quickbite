module ut.backends.interpreter.place_value;


import ut;
import ut.backends.interpreter: structTypeOf;
import quickbite.frontend.compiler: parseSnippet;
import quickbite.backends.interpreter.place_value: readValue, writeValue;
import quickbite.backends.interpreter.place: Place, placeAt;
import quickbite.backends.interpreter.layout: fieldByteOffset, structFields, typeByteSize;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.native_scalar: writeScalar;
import quickbite.lang: Value;
import dmd.mtype: TypeClass;

private:


// Parses `source`, finds the `class` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeClass` -- the class-typed sibling of `ut.backends.interpreter.
// structTypeOf`/`enumTypeOf`, needed here only for the unsupported-at-place
// fixtures below.
TypeClass classTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto class_ = member.isClassDeclaration)
            if (class_.ident.toString == name) {
                auto classType = class_.type.isTypeClass;
                assert(classType !is null, "class `" ~ name ~ "`'s type is not a TypeClass");
                return classType;
            }

    assert(false, "class `" ~ name ~ "` not found in parsed snippet");
}


struct P {
    int x;
    long y;
}


// `P.y` follows `P.x` with the host compiler's own alignment padding, so a
// round trip through `writeValue`/`readValue` must land `y` at its own
// offset independently of `x` -- the same padding trap `Place.field`'s own
// tests pin, exercised here through the whole-value composition instead of
// one field's `Place` directly.
@("place_value.writeValue.readValue.structRoundTripsFlatScalarFields")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    // Runtime-computed, not bare literals passed straight to `Value`.
    int writtenX = 3;
    writtenX = writtenX * 5 + 1;
    long writtenY = 1000L;
    writtenY = writtenY * 7 + 2;

    auto written = Value.structValue("P", [Value(writtenX), Value(writtenY)]);

    writeValue(root, written);

    readValue(root).should == written;
}


struct Q {
    P p;
    int z;
}


// A struct-typed field (`Q.p`) must recurse one level into its own fields
// rather than being treated as an opaque byte span -- the whole-value
// counterpart of `NativeStruct.structField`'s aliasing.
@("place_value.writeValue.readValue.structRoundTripsNestedStructField")
unittest {
    auto type = structTypeOf(q{
        struct P { int x; long y; }
        struct Q { P p; int z; }
    }, "Q");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    int writtenX = 4;
    writtenX = writtenX * 3 + 2;
    long writtenY = 500L;
    writtenY = writtenY * 9 + 5;
    int writtenZ = 7;
    writtenZ = writtenZ * 2 + 1;

    auto written = Value.structValue("Q", [
        Value.structValue("P", [Value(writtenX), Value(writtenY)]),
        Value(writtenZ),
    ]);

    writeValue(root, written);

    readValue(root).should == written;
}


struct H {
    int[3] xs;
}


// A static-array-typed field (`H.xs`) must recurse element by element,
// through `Place.index`'s own inline stride arithmetic -- the whole-value
// counterpart of `NativeStruct.arrayField`'s aliasing.
@("place_value.writeValue.readValue.structRoundTripsStaticArrayField")
unittest {
    auto type = structTypeOf(q{ struct H { int[3] xs; } }, "H");
    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    int first = 1;
    first = first * 6 + 1;
    int second = 2;
    second = second * 6 + 2;
    int third = 3;
    third = third * 6 + 3;

    auto written = Value.structValue(
        "H",
        [Value.arrayValue([Value(first), Value(second), Value(third)])],
    );

    writeValue(root, written);

    readValue(root).should == written;
}


// Cross-checks `readValue`'s field composition against an entirely
// independent path: `native_scalar.writeScalar` writes straight into `P.y`'s
// own bytes at `layout.fieldByteOffset`, never going through `Place`/
// `writeValue` at all, and `readValue` must still see it at the same field.
@("place_value.readValue.reflectsScalarWrittenDirectlyViaNativeScalarAtFieldOffset")
unittest {
    auto type = structTypeOf(q{ struct P { int x; long y; } }, "P");
    auto fields = structFields(type);
    auto yField = fields[1];

    auto block = NativeBlock.allocate(typeByteSize(type), NativeBlock.Scan.no);
    auto root = placeAt(block, type);

    long writtenY = 42L;
    writtenY = writtenY * 11 + 3;

    const offset = fieldByteOffset(yField);
    writeScalar(yField.type, block.bytes[offset .. offset + typeByteSize(yField.type)], Value(writtenY));

    readValue(root).structFieldAt(1).asLong.should == writtenY;
}


@("place_value.readValue.writeValue.classTypeThrows")
unittest {
    auto classType = classTypeOf(q{ class C { int x; } }, "C");
    auto place = Place(null, classType);

    readValue(place).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}


@("place_value.readValue.writeValue.sliceTypeThrows")
unittest {
    auto holderType = structTypeOf(q{ struct SliceHolder { int[] xs; } }, "SliceHolder");
    auto sliceType = structFields(holderType)[0].type;
    auto place = Place(null, sliceType);

    readValue(place).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}


@("place_value.readValue.writeValue.unionTypeThrows")
unittest {
    auto unionType = structTypeOf(q{ union U { int x; long y; } }, "U");
    auto place = Place(null, unionType);

    readValue(place).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );

    writeValue(place, Value.void_).shouldThrowWithMessage(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}

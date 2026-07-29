module ut.backends.interpreter.native_scalar;


import ut;
import ut.backends.interpreter: enumTypeOf;
import quickbite.backends.interpreter.native_scalar:
    isNativeScalarType, readScalar, writeScalar;
import quickbite.backends.interpreter.layout: typeByteSize;
import quickbite.backends.interpreter.runtime_value: Value;
import dmd.mtype: Type;

private:


@("isNativeScalarType.trueForBool")
unittest {
    isNativeScalarType(Type.tbool).should == true;
}


@("isNativeScalarType.trueForEveryIntegralWidth")
unittest {
    foreach (type; [
        Type.tint8, Type.tuns8,
        Type.tint16, Type.tuns16,
        Type.tint32, Type.tuns32,
        Type.tint64, Type.tuns64,
    ])
        isNativeScalarType(type).should == true;
}


@("isNativeScalarType.trueForEveryCharacterWidth")
unittest {
    foreach (type; [Type.tchar, Type.twchar, Type.tdchar])
        isNativeScalarType(type).should == true;
}


@("isNativeScalarType.trueForFloatAndDouble")
unittest {
    isNativeScalarType(Type.tfloat32).should == true;
    isNativeScalarType(Type.tfloat64).should == true;
}


// `real` is deliberately unsupported: its 80-bit extended-precision layout
// is host- and ABI-specific padding, not a portable byte-for-byte native
// scalar (see native_scalar.d's header comment).
@("isNativeScalarType.falseForReal")
unittest {
    isNativeScalarType(Type.tfloat80).should == false;
}


@("isNativeScalarType.falseForPointer")
unittest {
    isNativeScalarType(Type.tvoidptr).should == false;
}


@("isNativeScalarType.trueForAnEnumWithAnIntegralBaseType")
unittest {
    auto type = enumTypeOf(q{ enum E : int { a, b, c } }, "E");

    isNativeScalarType(type).should == true;
}


@("writeScalar.thenReadScalar.roundTripsEachIntegralWidth")
unittest {
    foreach (type; [
        Type.tint8, Type.tuns8,
        Type.tint16, Type.tuns16,
        Type.tint32, Type.tuns32,
        Type.tint64, Type.tuns64,
    ]) {
        auto bytes = new ubyte[](typeByteSize(type));
        writeScalar(type, bytes, Value(42));

        readScalar(type, bytes).asLong.should == 42;
    }
}


// The round-trip tests above are byte-order-symmetric: a codec that
// consistently reversed bytes on both write and read would still pass every
// one of them (write-reversed then read-reversed cancels out). This instead
// pins `writeScalar`'s OUTPUT bytes directly against the host compiler's own
// in-memory layout for a multi-byte value, catching that class of bug.
// `impl.d`'s differently-typed scalar-cell dereference reads the leading
// target-width bytes, so byte position -- not just round-trip value --
// matters.
@("writeScalar.producesTheHostCompilersOwnByteLayoutNotJustARoundTrip")
unittest {
    uint u = 0x1122_3344;
    auto bytes = new ubyte[](typeByteSize(Type.tuns32));
    writeScalar(Type.tuns32, bytes, Value(u));

    bytes.should == (cast(ubyte*) &u)[0 .. uint.sizeof];
}


@("writeScalar.thenReadScalar.roundTripsBool")
unittest {
    auto bytes = new ubyte[](1);
    writeScalar(Type.tbool, bytes, Value(true));

    readScalar(Type.tbool, bytes).asLong.should == 1;
}


@("writeScalar.thenReadScalar.roundTripsChar")
unittest {
    auto bytes = new ubyte[](1);
    writeScalar(Type.tchar, bytes, Value('x'));

    readScalar(Type.tchar, bytes).asChar.should == 'x';
}


@("writeScalar.thenReadScalar.roundTripsWchar")
unittest {
    auto bytes = new ubyte[](2);
    writeScalar(Type.twchar, bytes, Value(cast(wchar) 0x1234));

    readScalar(Type.twchar, bytes).asLong.should == 0x1234;
}


@("writeScalar.thenReadScalar.roundTripsDchar")
unittest {
    auto bytes = new ubyte[](4);
    writeScalar(Type.tdchar, bytes, Value(cast(dchar) 0x1F600));

    readScalar(Type.tdchar, bytes).asLong.should == 0x1F600;
}


@("writeScalar.thenReadScalar.roundTripsFloat")
unittest {
    auto bytes = new ubyte[](4);
    writeScalar(Type.tfloat32, bytes, Value(1.5f));

    readScalar(Type.tfloat32, bytes).asReal.should == cast(real) 1.5f;
}


@("writeScalar.thenReadScalar.roundTripsDouble")
unittest {
    auto bytes = new ubyte[](8);
    writeScalar(Type.tfloat64, bytes, Value(1.5));

    readScalar(Type.tfloat64, bytes).asReal.should == cast(real) 1.5;
}


@("writeScalar.thenReadScalar.roundTripsAnEnumValue")
unittest {
    auto type = enumTypeOf(q{ enum E : int { a, b, c } }, "E");

    auto bytes = new ubyte[](4);
    writeScalar(type, bytes, Value(2));

    readScalar(type, bytes).asLong.should == 2;
}


// The host compiler is the oracle for what "reinterpret these bytes at a
// different type" means: writing a `float`'s bits and reading them back as
// `uint` must match `*cast(uint*) &f` in real, compiled D.
@("writeScalar.floatBytesReadBackAsUintMatchTheHostCompilersOwnReinterpretCast")
unittest {
    float f = 1.5f;
    const expected = *cast(uint*) &f;

    auto bytes = new ubyte[](4);
    writeScalar(Type.tfloat32, bytes, Value(f));

    readScalar(Type.tuns32, bytes).asLong.should == expected;
}


// Same oracle, for `double`/`ulong` -- the other pair the pointer-dereference
// path once hardcoded by name.
@("writeScalar.doubleBytesReadBackAsUlongMatchTheHostCompilersOwnReinterpretCast")
unittest {
    double d = 1.5;
    const expected = *cast(ulong*) &d;

    auto bytes = new ubyte[](8);
    writeScalar(Type.tfloat64, bytes, Value(d));

    readScalar(Type.tuns64, bytes).asLong.should == expected;
}


// `impl.d`'s scalar-cell dereference takes a STRICT-NARROWING path (target
// strictly narrower than source) through the source's leading bytes. Pin it
// at the codec level: write a wider scalar, read a narrower type back from
// its leading bytes, and match the host compiler's own narrowing reinterpret
// cast.
@("writeScalar.thenReadScalar.narrowerTargetReadsLeadingBytesMatchingHostCompilersReinterpretCast")
unittest {
    uint i = 0x1234_5678;
    const expected = *cast(ushort*) &i;

    auto bytes = new ubyte[](typeByteSize(Type.tuns32));
    writeScalar(Type.tuns32, bytes, Value(i));

    readScalar(Type.tuns16, bytes[0 .. typeByteSize(Type.tuns16)])
        .asLong.should == expected;
}


@("writeScalar.destLengthNotMatchingTypeByteSizeThrows")
unittest {
    auto bytes = new ubyte[](3);

    writeScalar(Type.tint32, bytes, Value(1)).shouldThrow!Exception;
}


@("readScalar.srcLengthNotMatchingTypeByteSizeThrows")
unittest {
    auto bytes = new ubyte[](3);

    readScalar(Type.tint32, bytes).shouldThrow!Exception;
}


@("writeScalar.unsupportedTypeThrows")
unittest {
    auto bytes = new ubyte[](8);

    writeScalar(Type.tvoidptr, bytes, Value.pointerValue(null))
        .shouldThrow!Exception;
}


@("readScalar.unsupportedTypeThrows")
unittest {
    auto bytes = new ubyte[](8);

    readScalar(Type.tvoidptr, bytes).shouldThrow!Exception;
}


// `impl.d`'s `scalarBytes`/`scalarFromBytes` splat a scalar's native bytes
// out into a `Value[]` of individually-boxed `ubyte` bytes (for pointer byte
// slices and single-byte pointer writebacks) and reassemble the same way;
// these tests exercise that exact splat/reassemble composition on top of
// `writeScalar`/`readScalar` directly, one byte-boxing step removed from
// `impl.d`'s own (private, untestable-in-isolation) helpers.
@("writeScalar.thenReadScalar.roundTripsThroughAnIndividuallyBoxedByteArray")
unittest {
    auto raw = new ubyte[](typeByteSize(Type.tint32));
    writeScalar(Type.tint32, raw, Value(0x1234_5678));

    Value[] boxedBytes;
    foreach (byte_; raw)
        boxedBytes ~= Value(byte_);

    auto reassembled = new ubyte[](boxedBytes.length);
    foreach (index, byte_; boxedBytes)
        reassembled[index] = cast(ubyte) byte_.asLong;

    readScalar(Type.tint32, reassembled).asLong.should == 0x1234_5678;
}


// The newly-succeeding case: `float`/`double` through the same boxed-byte
// splat/reassemble composition. `impl.d`'s old hand-written
// `scalarFromBytes` threw "Unsupported scalar byte writeback." for these
// two types; nothing in `tests/` pinned that throw, so routing through
// this codec instead now succeeds here too, matching `SystemLinker`.
@("writeScalar.thenReadScalar.roundTripsFloatAndDoubleThroughAnIndividuallyBoxedByteArray")
unittest {
    foreach (type; [Type.tfloat32, Type.tfloat64]) {
        auto raw = new ubyte[](typeByteSize(type));
        writeScalar(type, raw, Value(1.5));

        Value[] boxedBytes;
        foreach (byte_; raw)
            boxedBytes ~= Value(byte_);

        auto reassembled = new ubyte[](boxedBytes.length);
        foreach (index, byte_; boxedBytes)
            reassembled[index] = cast(ubyte) byte_.asLong;

        readScalar(type, reassembled).asReal.should == cast(real) 1.5;
    }
}

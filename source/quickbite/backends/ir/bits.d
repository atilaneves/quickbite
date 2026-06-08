module quickbite.backends.ir.bits;

private:

// @trusted: reads the bytes of a local float as a same-sized uint for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
package ulong floatBits(in float value) @trusted pure nothrow {
    static assert(float.sizeof == uint.sizeof);
    return *cast(uint*) &value;
}

package ulong floatingBits(in float value) @safe pure nothrow {
    return floatBits(value);
}

// @trusted: reads the bytes of a local uint as a same-sized float after
// retrieving an f32 value from IR raw scalar storage. The pointer is used only
// for this immediate read and never escapes.
package float floatFromBits(in ulong value) @trusted pure nothrow {
    static assert(float.sizeof == uint.sizeof);
    const bits = cast(uint) value;
    return *cast(float*) &bits;
}

// @trusted: reads the bytes of a local double as a same-sized ulong for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
package ulong doubleBits(in double value) @trusted pure nothrow {
    static assert(double.sizeof == ulong.sizeof);
    return *cast(ulong*) &value;
}

package ulong floatingBits(in double value) @safe pure nothrow {
    return doubleBits(value);
}

// @trusted: reads the bytes of a local ulong as a same-sized double after
// retrieving an f64 value from IR raw scalar storage. The pointer is used only
// for this immediate read and never escapes.
package double doubleFromBits(in ulong bits) @trusted pure nothrow {
    static assert(double.sizeof == ulong.sizeof);
    return *cast(double*) &bits;
}

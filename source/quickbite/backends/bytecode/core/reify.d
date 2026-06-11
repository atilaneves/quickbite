module quickbite.backends.bytecode.core.reify;

private:

// Reifies raw result bytes into a Value using the static result type — the
// only place the new core constructs a Value.
package(quickbite.backends.bytecode) imported!"quickbite.lang".Value reify(
    in ubyte[] bytes,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe pure {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import quickbite.lang: Value;

    final switch (type) with (ScalarType) {
        case void_:
            return Value.void_;
        case int_:
            return Value(scalar!int(bytes));
    }
}

private T scalar(T)(in ubyte[] bytes) @safe pure {
    import std.bitmanip: littleEndianToNative;

    const ubyte[T.sizeof] raw = bytes[0 .. T.sizeof];
    return littleEndianToNative!T(raw);
}

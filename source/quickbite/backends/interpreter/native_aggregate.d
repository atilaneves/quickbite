module quickbite.backends.interpreter.native_aggregate;


private:


// Owned or borrowed guest aggregate storage. Guest aggregate bits live in
// `_storage` at their DMD type's native layout. The
// block handle roots the allocation; copying this value never copies guest
// bytes and therefore preserves aliasing for structs, static arrays, slice
// headers, class bodies, and associative-array handles alike.
//
// A dynamic-array aggregate stores its ordinary `{ length, ptr }` header in
// `_storage`. A slice aggregate retains its owned backing block; a class
// aggregate retains its body. This host-only retention never changes guest
// layout or identity: the guest handle remains the header/reference slot.
public struct NativeAggregate {
    import dmd.mtype: Type;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    private Type _type;
    private NativeBlock _storage;
    private NativeBlock _retained;

    // Fresh storage for a whole value of `type`, for a construction that
    // writes the value into it. The bytes read zero until it does -- not
    // `type`'s default value -- so only that construction may observe them.
    // The scan policy is chosen once here, from the whole type, per
    // `NativeBlock`'s own allocation contract.
    public static NativeAggregate allocate(Type type) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;

        return NativeAggregate(
            type,
            NativeBlock.allocate(
                typeByteSize(type),
                typeHasPointers(type)
                    ? NativeBlock.Scan.conservative
                    : NativeBlock.Scan.no,
            ),
        );
    }

    public this(Type type, NativeBlock storage) pure nothrow @safe {
        _type = type;
        _storage = storage;
    }

    public this(Type type, NativeBlock storage, NativeBlock retained) pure nothrow @safe {
        _type = type;
        _storage = storage;
        _retained = retained;
    }

    public inout(Type) type() inout pure nothrow @nogc @safe {
        return _type;
    }

    public inout(NativeBlock) storage() inout pure nothrow @nogc @safe {
        return _storage;
    }

    public inout(NativeBlock) retained() inout pure nothrow @nogc @safe {
        return _retained;
    }

    public inout(void)* address() inout pure nothrow @nogc @safe {
        return _storage.address;
    }

    // Keep accidental host rendering opaque. Expression display executes the
    // guest formatter before the result crosses the interpreter boundary.
    public string toString() const pure nothrow @safe {
        return "<native aggregate>";
    }
}

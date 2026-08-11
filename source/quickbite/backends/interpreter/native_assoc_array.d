module quickbite.backends.interpreter.native_assoc_array;


private:


// Quickbite's native AA body.  The guest representation is only a pointer to
// this GC allocation; the body owns separately typed native blocks for keys
// and values, so `_d_aaGetY` can return a real, stable value-slot address.
//
// This is deliberately not druntime's private AA layout.  Walker execution
// intercepts the druntime templates before they run, and the guest never
// dereferences the handle except through those operations.  Depending on the
// private druntime table would couple the no-emit backend to a compiler
// runtime ABI without buying any language behaviour.
public struct NativeAssocArray {
    import dmd.mtype: Type;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    private enum size_t magic = 0x5142495445414141;

    private size_t _magic = magic;
    private Type _keyType;
    private Type _valueType;
    private NativeBlock[] _keys;
    private NativeBlock[] _values;

    public this(Type keyType, Type valueType) pure nothrow @safe {
        _keyType = keyType;
        _valueType = valueType;
    }

    public size_t length() const pure nothrow @safe {
        return _keys.length;
    }

    public bool isQuickbiteHeader() const pure nothrow @safe {
        return _magic == magic;
    }

    public inout(Type) keyType() inout pure nothrow @safe {
        return _keyType;
    }

    public inout(Type) valueType() inout pure nothrow @safe {
        return _valueType;
    }

    public bool contains(void* keyAddress) @safe {
        return find(keyAddress) !is size_t.max;
    }

    public void* valueAddress(void* keyAddress) @safe {
        const index = find(keyAddress);
        return index == size_t.max ? null : _values[index].address;
    }

    // `_d_aaGetY`'s operation: returns an existing value slot or appends a
    // zero-initialised typed slot and reports that it was absent.  The slot is
    // a NativeBlock allocation, so its address remains stable as the header's
    // dynamic arrays reallocate.
    public void* getOrAdd(void* keyAddress, out bool found) @safe {
        const index = find(keyAddress);
        if (index != size_t.max) {
            found = true;
            return _values[index].address;
        }

        found = false;
        _keys ~= copyAt(_keyType, keyAddress);
        _values ~= allocateFor(_valueType);
        return _values[$ - 1].address;
    }

    public bool remove(void* keyAddress) @safe {
        const index = find(keyAddress);
        if (index == size_t.max)
            return false;

        _keys = _keys[0 .. index] ~ _keys[index + 1 .. $];
        _values = _values[0 .. index] ~ _values[index + 1 .. $];
        return true;
    }

    public NativeBlock keyAt(in size_t index) @safe {
        return _keys[index];
    }

    public NativeBlock valueAt(in size_t index) @safe {
        return _values[index];
    }

    private size_t find(void* keyAddress) @safe {
        foreach (index, key; _keys)
            if (keysEqual(key.address, keyAddress, _keyType))
                return index;
        return size_t.max;
    }
}


// Allocates the one-word guest AA value and the typed GC header it points to.
// The guest slot is conservatively scanned, so the header and every block it
// owns remain reachable without a parallel object or alias table.
public imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate allocateValue(
    imported!"dmd.mtype".Type type,
) @safe {
    import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    auto aaType = baseTypeOf(type).isTypeAArray;
    if (aaType is null)
        throw new Exception("Native associative-array value needs a Taarray type.");

    auto header = new NativeAssocArray(aaType.index, aaType.next);
    auto storage = NativeBlock.allocate(void*.sizeof, NativeBlock.Scan.conservative);
    writeHeader(storage.address, header);
    return NativeAggregate(type, storage);
}


public NativeAssocArray* headerAt(void* address) @safe {
    return readHeader(address);
}


// Allocates a type-shaped typed slot.  The choice of conservative scanning is
// made from the complete DMD type, never from an AA-specific approximation.
private imported!"quickbite.backends.interpreter.native_block".NativeBlock allocateFor(
    imported!"dmd.mtype".Type type,
) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    return NativeBlock.allocate(
        typeByteSize(type),
        typeHasPointers(type) ? NativeBlock.Scan.conservative : NativeBlock.Scan.no,
    );
}


private imported!"quickbite.backends.interpreter.native_block".NativeBlock copyAt(
    imported!"dmd.mtype".Type type,
    void* address,
) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize;

    auto result = allocateFor(type);
    result.bytes[] = addressBytes(address, typeByteSize(type))[];
    return result;
}


// The caller's address is a Place derived from a DMD-sized guest object; this
// single raw view is only used to copy that exact byte length into a fresh
// NativeBlock.
private ubyte[] addressBytes(void* address, in size_t length) pure nothrow @trusted {
    return (cast(ubyte*) address)[0 .. length];
}


private bool keysEqual(
    void* lhs,
    void* rhs,
    imported!"dmd.mtype".Type type,
) @safe {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.layout: structFields;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.place_value: readValue;

    // Class and pointer AA keys compare the reference value, not the object
    // contents. `readValue` intentionally composes a class body, so keep
    // these reference-shaped key types at this direct address comparison.
    if (type.isTypeClass !is null || type.isTypePointer !is null)
        return readWord(lhs) == readWord(rhs);

    const left = readValue(Place(lhs, type));
    const right = readValue(Place(rhs, type));
    if (type.isTypeDArray !is null) {
        if (AggregateValue.elementCount(left) != AggregateValue.elementCount(right))
            return false;
        foreach (index; 0 .. AggregateValue.elementCount(left))
            if (AggregateValue.elementAt(left, index) !=
                AggregateValue.elementAt(right, index))
                return false;
        return true;
    }

    if (auto structType = type.isTypeStruct) {
        foreach (field; structFields(structType))
            if (!keysEqual(
                Place(lhs, type).field(field).address,
                Place(rhs, type).field(field).address,
                field.type,
            ))
                return false;
        return true;
    }

    return left == right;
}


private imported!"dmd.mtype".Type baseTypeOf(imported!"dmd.mtype".Type type) @trusted {
    return type.toBasetype;
}


// A guest AA handle is exactly one pointer-width word.  Both helpers are
// confined here so callers cannot reinterpret unrelated guest storage as a
// Quickbite header.
private void writeHeader(void* address, NativeAssocArray* header) pure nothrow @trusted {
    *(cast(NativeAssocArray**) address) = header;
}


private NativeAssocArray* readHeader(void* address) pure nothrow @trusted {
    return *(cast(NativeAssocArray**) address);
}


private void* readWord(void* address) pure nothrow @trusted {
    return *(cast(void**) address);
}

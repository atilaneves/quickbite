module quickbite.backends.interpreter.place;


private:


// An addressable location: a host address plus the static DMD `Type` at
// that address, nothing more. `field`/`index` below compute another
// `Place` by address arithmetic over DMD's own offsets/strides, read
// straight from `layout.d` -- never a second, hand-rolled copy of DMD's
// layout rules. Scalar load/store at a place go through `native_scalar.
// d`'s codec, the interpreter's single scalar<->bytes authority; an
// aggregate place has no single scalar value of its own and is addressed
// by composing `field`/`index` down to scalar leaves instead.
public struct Place {
    import dmd.mtype: Type;
    import dmd.declaration: VarDeclaration;

    private void* _address;
    private Type _type;

    public this(void* address, Type type) pure nothrow @nogc @safe {
        _address = address;
        _type = type;
    }

    public inout(void)* address() inout pure nothrow @nogc @safe {
        return _address;
    }

    public inout(Type) type() inout pure nothrow @nogc @safe {
        return _type;
    }

    // A `Place` at `field`'s own byte offset within this place, with
    // `field`'s own declared type -- `layout.fieldByteOffset` reads DMD's
    // own `VarDeclaration.offset` verbatim, the same number for a struct
    // field or a class field alike. That offset is only meaningful once
    // the enclosing aggregate has been laid out; for a struct field that
    // is a precondition on the caller (satisfied by obtaining `field` from
    // `layout.structFields`, which already forces it), not something this
    // function forces itself -- mirroring `NativeStruct.field`'s identical
    // reliance on an already-forced offset.
    public Place field(VarDeclaration field) @safe {
        import quickbite.backends.interpreter.layout: fieldByteOffset;

        return Place(placeAdd(_address, fieldByteOffset(field)), fieldType(field));
    }

    // A `Place` at element `i` of this place's static array: address +
    // i * stride, with the element type -- the same stride arithmetic
    // `NativeArray.element` performs over its own block, applied here to a
    // bare address whose static-array elements sit inline. `i` is bounds-
    // checked against the array's fixed DMD element count
    // (`layout.staticArrayLength`). A pointer's or slice's elements do not
    // sit at this place's own address -- they live behind the pointer value
    // (or the slice descriptor's `ptr`) stored here -- so element access for
    // those composes from the elements-base place the stored pointer names,
    // not from this descriptor address; that path arrives with place-
    // yielding lvalue evaluation and is refused here rather than reading the
    // descriptor's own bytes as if they were elements.
    public Place index(in size_t i) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, staticArrayLength;

        auto array = _type.isTypeSArray;
        if (array is null)
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.index: only a "
                ~ "static-array place indexes inline; a pointer or slice "
                ~ "place indexes through its stored pointer",
            );

        assert(i < staticArrayLength(array), "index out of range for static array place");
        return Place(placeAdd(_address, i * typeByteSize(array.next)), array.next);
    }

    // Reads the scalar at this place's address, at this place's own
    // static type, via `native_scalar.readScalar` -- this primitive never
    // grows a second scalar<->bytes codec. Only a native scalar type
    // (`native_scalar.isNativeScalarType`) is legal here; a non-scalar
    // place refuses rather than guessing at a byte interpretation.
    public imported!"quickbite.lang".Value loadScalar() @safe {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType, readScalar;
        import quickbite.backends.interpreter.layout: typeByteSize;

        if (!isNativeScalarType(_type))
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.loadScalar: "
                ~ "type is not a native scalar type",
            );

        return readScalar(_type, placeBytes(_address, typeByteSize(_type)));
    }

    // The inverse of `loadScalar`: writes `value`'s bits into this
    // place's address at this place's own static type, via `native_scalar.
    // writeScalar`. Refuses the same way `loadScalar` does for a
    // non-scalar place.
    public void storeScalar(in imported!"quickbite.lang".Value value) @safe {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType, writeScalar;
        import quickbite.backends.interpreter.layout: typeByteSize;

        if (!isNativeScalarType(_type))
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.storeScalar: "
                ~ "type is not a native scalar type",
            );

        writeScalar(_type, placeBytes(_address, typeByteSize(_type)), value);
    }
}


// A `Place` at a `NativeBlock`'s own address, at `type` -- the block's
// address is stable for as long as any handle can reach it (`NativeBlock`'s
// own contract), which is exactly what a `Place` needs.
public Place placeAt(
    imported!"quickbite.backends.interpreter.native_block".NativeBlock block,
    imported!"dmd.mtype".Type type,
) @safe {
    return Place(block.address, type);
}


// A `Place` at `variable`'s own slot in `frame` -- `FrameBlock.slotAddress`
// already asserts `variable` owns a slot in this activation; this just
// pairs that address with the local's own declared type.
public Place placeAt(
    imported!"quickbite.backends.interpreter.frame_block".FrameBlock frame,
    imported!"dmd.declaration".VarDeclaration variable,
) @safe {
    return Place(frame.slotAddress(variable), fieldType(variable));
}


// `VarDeclaration.type` is a plain field, but `VarDeclaration` (an
// `extern (C++)` class) is not itself `@safe`-annotated; this is the
// `@trusted` boundary, mirroring `frame_layout.d`'s/`frame_block.d`'s own
// `variableType` helper.
private imported!"dmd.mtype".Type fieldType(
    imported!"dmd.declaration".VarDeclaration variable,
) @trusted {
    return variable.type;
}


// Pointer arithmetic on a raw address is not `@safe`; this is the
// `@trusted` boundary, mirroring `frame_block.d`'s `slotAddressImpl`.
// `offset` is always a DMD-derived field offset or array-stride product
// computed from this same address's own static type, so `address + offset`
// stays within whatever allocation `address` was formed from.
private void* placeAdd(void* address, in size_t offset) pure nothrow @trusted {
    return address + offset;
}


// Reinterpreting a raw address as a byte range is not `@safe`; this is
// the `@trusted` boundary, mirroring `native_block.d`'s `resliceBytes`.
// `length` is always `layout.typeByteSize` for this place's own static
// type, so the returned slice spans exactly the bytes that type occupies
// at `address` -- never more.
private ubyte[] placeBytes(void* address, in size_t length) pure nothrow @trusted {
    return (cast(ubyte*) address)[0 .. length];
}

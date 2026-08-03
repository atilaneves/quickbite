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
        import quickbite.backends.interpreter.layout: fieldByteOffset, declaredType;

        return Place(placeAdd(_address, fieldByteOffset(field)), declaredType(field));
    }

    // A `Place` at element `i`, with the element type -- three cases,
    // matching how each type actually stores its elements:
    //
    // - Static array (`Type.isTypeSArray`): elements sit inline at this
    //   place's own address, so `index` is address + i * stride, the same
    //   stride arithmetic `NativeArray.element` performs over its own block.
    //   `i` is bounds-checked against the array's fixed DMD element count
    //   (`layout.staticArrayLength`).
    // - Pointer (`Type.isTypePointer`): this place's own address holds a
    //   stored `T*` value, not element bytes -- `index` follows that stored
    //   pointer, then applies stride arithmetic from there. No bounds check:
    //   a raw pointer's extent is unknown, the same "no bounds check"
    //   contract `NativeBlock.borrow` documents for its own raw-pointer
    //   input.
    // - Slice (`Type.isTypeDArray`): this place's own address holds a
    //   `{ length, ptr }` header (`native_array.d`'s own layout) -- `index`
    //   reads `ptr` back out of that header, then applies stride arithmetic
    //   from there, the same "follow the stored pointer" shape as the
    //   pointer case above but through the header's `ptr` field instead of
    //   the place's address directly. `i` is bounds-checked against the
    //   header's own `length` field, since a slice (unlike a raw pointer)
    //   actually carries that fact.
    //
    // Every other type is refused.
    public Place index(in size_t i) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, staticArrayLength;
        import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;

        if (auto pointer = _type.isTypePointer)
            return Place(
                placeAdd(readStoredPointer(_address), i * typeByteSize(pointer.next)),
                pointer.next,
            );

        if (auto slice = _type.isTypeDArray) {
            auto header = readSliceHeaderBytes(placeBytes(_address, NativeArray.sliceHeaderByteLength));
            if (i >= header.length)
                throw new Exception(
                    "quickbite.backends.interpreter.place.Place.index: "
                    ~ "index out of range for slice place",
                );
            return Place(
                placeAdd(header.ptr, i * typeByteSize(slice.next)),
                slice.next,
            );
        }

        auto array = _type.isTypeSArray;
        if (array is null)
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.index: only a "
                ~ "static-array, pointer, or slice place can be indexed",
            );

        if (i >= staticArrayLength(array))
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.index: "
                ~ "index out of range for static array place",
            );
        return Place(placeAdd(_address, i * typeByteSize(array.next)), array.next);
    }

    // The data pointer stored in a slice header. Unlike `index`, this is
    // defined for an empty slice: `array.ptr` observes its retained backing
    // address without dereferencing an element.
    public void* sliceDataPointer() @safe {
        import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;

        if (_type.isTypeDArray is null)
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.sliceDataPointer: "
                ~ "only a slice place has a data pointer",
            );
        return readSliceHeaderBytes(
            placeBytes(_address, NativeArray.sliceHeaderByteLength),
        ).ptr;
    }

    // A `Place` at the location this place's own stored pointer/reference
    // points to -- two cases, matching how each type stores that reference:
    //
    // - Pointer (`Type.isTypePointer`): this place's own address holds a
    //   stored `T*` value, exactly as `index`'s pointer branch reads it --
    //   `deref` returns a `Place` at that stored address, with the pointee's
    //   own type (`pointer.next`).
    // - Class (`Type.isTypeClass`): a class variable holds a reference to
    //   its object body, so this place's own address holds that stored
    //   reference -- `deref` returns a `Place` at the object body's own
    //   address, keeping THIS place's class type (rather than some separate
    //   "object body" type) so a following `.field(classField)` composes at
    //   `objectAddress + fieldByteOffset(field)`: DMD's class field offsets
    //   are already relative to the object's own start.
    //
    // No bounds/null check either way: a raw pointer/reference's validity is
    // the caller's concern, the same contract `index`'s pointer branch
    // already carries. Every other type is refused -- only a pointer or
    // class place holds a stored address to follow.
    public Place deref() @safe {
        if (auto pointer = _type.isTypePointer)
            return Place(readStoredPointer(_address), pointer.next);

        if (_type.isTypeClass)
            return Place(readStoredPointer(_address), _type);

        throw new Exception(
            "quickbite.backends.interpreter.place.Place.deref: only a "
            ~ "pointer or class place can be dereferenced",
        );
    }

    // The write side of `deref`'s class case, and now also of a pointer
    // place's own slot: stores `reference` -- a class object body's own
    // address, a pointer's own host address, or `null` -- as the
    // reference/pointer this place's own address holds. A caller here
    // already knows the address to store (an `object_table.ObjectTable`
    // lookup for a class, or a boxed `Value`'s own host address for a
    // pointer -- `place_value.writeValue`'s pointer arm, the call site that
    // retires the "no call site yet" gap this comment used to record)
    // rather than one following it FROM somewhere else. A stored class
    // reference or pointer value is itself just a pointer-width bit
    // pattern, the same width `deref`'s class case and `index`'s pointer
    // case already read back out via `readStoredPointer` -- this is that
    // read's exact inverse. Only a pointer or class place is legal here;
    // every other type is refused.
    //
    // A live GC pointer stored into a destination the collector does not
    // scan is the same corruption `native_array.NativeArray.
    // writeSliceHeader(void*)` refuses for a slice header -- the stored
    // address becomes invisible to the GC, so its target can be collected
    // while the guest still reaches it through this place -- so this
    // refuses it on the same terms, reading both facts mechanically
    // (`core.memory.GC.addrOf`/`GC.getAttr`, `referenceIsScanned` below)
    // rather than from any caller-supplied label. Like that one, this never
    // fires for a legitimate call site: every destination a `Place` is
    // composed from (a frame slot, a struct/class body, an array element)
    // whose type transitively contains a pointer or class reference was
    // allocated `NativeBlock.Scan.conservative` for exactly that reason,
    // per DMD's own `hasPointers` (`value.md`'s Containers contract). A
    // `null` reference and a non-GC (FFI/foreign) address are both fine
    // anywhere: there is nothing for the collector to lose track of.
    public void storeReference(void* reference) @safe {
        if (_type.isTypePointer is null && _type.isTypeClass is null)
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.storeReference: "
                ~ "only a pointer or class place can store a reference",
            );

        if (referenceIsGcOwned(reference) && !destinationIsScanned(_address))
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.storeReference: "
                ~ "this place is not scanned by the GC, but `reference` is a "
                ~ "live GC pointer",
            );

        writeStoredPointer(_address, reference);
    }

    // Reads the scalar at this place's address, at this place's own
    // static type, via `native_scalar.readScalar` -- this primitive never
    // grows a second scalar<->bytes codec. Only a native scalar type
    // (`native_scalar.isNativeScalarType`) is legal here; a non-scalar
    // place refuses rather than guessing at a byte interpretation.
    public imported!"quickbite.backends.interpreter.runtime_value".Value loadScalar() @safe {
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
    public void storeScalar(in imported!"quickbite.backends.interpreter.runtime_value".Value value) @safe {
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


// A `Place` at `variable`'s binding in `frame` -- `FrameBlock.bindingAddress`
// is the one decoder for both inline owning slots and reference slots, and
// this just pairs that resolved address with the local's own declared type.
public Place placeAt(
    imported!"quickbite.backends.interpreter.frame_block".FrameBlock frame,
    imported!"dmd.declaration".VarDeclaration variable,
) @safe {
    import quickbite.backends.interpreter.layout: declaredType;

    return Place(frame.bindingAddress(variable), declaredType(variable));
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


// Reading the pointer value stored at a POINTER place's own address is not
// `@safe`: `address` holds a raw `T*`/`void*` bit pattern, and reinterpreting
// it as a `void**` to load that value cannot be verified by the compiler.
// This is `Place.index`'s `@trusted` boundary for the pointer case, mirroring
// `placeAdd`/`placeBytes` above; the loaded pointer itself is untrusted data
// -- `Place.index` does no more with it than the same stride arithmetic
// `placeAdd` already performs on any other address.
private void* readStoredPointer(void* address) pure nothrow @trusted {
    return *cast(void**) address;
}


// Whether `reference` is an address the GC owns, so that storing it
// somewhere unscanned would genuinely lose it -- `GC.addrOf` resolves a GC
// address to its own allocation's base and answers `null` for foreign
// memory and for `null` itself. The source-side half of `storeReference`'s
// check, mirroring `native_array.d`'s identical `GC.addrOf(_block.address)`
// test. `GC.addrOf` is not `@safe`; this is the `@trusted` boundary.
private bool referenceIsGcOwned(void* reference) @trusted {
    import core.memory: GC;

    return GC.addrOf(reference) !is null;
}


// The destination-side half: whether `address` sits inside a block the GC
// actually scans. Only a resolved GC block WITHOUT the `NO_SCAN` attribute
// counts, matching `NativeBlock.Scan.conservative`; foreign memory and an
// explicitly `NO_SCAN` block both answer `false`, matching `Scan.no`. The
// same derivation as `native_array.d`'s own `destinationIsScanned`, kept
// here rather than shared because `place.d` deliberately depends on
// `native_array` only for slice-header layout, not the other way round.
private bool destinationIsScanned(void* address) @trusted {
    import core.memory: GC;

    const base = GC.addrOf(address);
    return base !is null && (GC.getAttr(base) & GC.BlkAttr.NO_SCAN) == 0;
}


// The write side of `readStoredPointer`: writing a pointer value through a
// `void**` reinterpret is not `@safe` either. This is `Place.
// storeReference`'s `@trusted` boundary, mirroring `readStoredPointer`
// above exactly.
private void writeStoredPointer(void* address, void* reference) pure nothrow @trusted {
    *cast(void**) address = reference;
}

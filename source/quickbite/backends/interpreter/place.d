module quickbite.backends.interpreter.place;


private:


// Distinguishes an index's guest-visible bounds violation from other host
// failures while composing a `Place`.
public class IndexOutOfBoundsException: Exception {
    public this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe {
        super(message, file, line);
    }
}


// An addressable location: a host address plus the static DMD `Type` at
// that address, nothing more. `field`/`index` below compute another
// `Place` by address arithmetic over DMD's own offsets/strides, read
// straight from `layout.d` -- never a second, hand-rolled copy of DMD's
// layout rules. Typed scalar loads/stores at a place go through
// `native_scalar.d`; an aggregate place has no single scalar value of its own
// and is addressed by composing `field`/`index` down to scalar leaves instead.
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
                throw new IndexOutOfBoundsException(
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
            throw new IndexOutOfBoundsException(
                "quickbite.backends.interpreter.place.Place.index: "
                ~ "index out of range for static array place",
            );
        return Place(placeAdd(_address, i * typeByteSize(array.next)), array.next);
    }

    // Read only the length stored at an
    // addressable array place. This avoids materialising the complete array
    // merely to select its length.
    public size_t arrayLength() @safe {
        import quickbite.backends.interpreter.layout: staticArrayLength;
        import quickbite.backends.interpreter.native_array:
            NativeArray, readSliceHeaderBytes;

        if (auto array = _type.isTypeSArray)
            return staticArrayLength(array);
        if (_type.isTypeDArray !is null)
            return readSliceHeaderBytes(
                placeBytes(_address, NativeArray.sliceHeaderByteLength),
            ).length;

        throw new Exception(
            "quickbite.backends.interpreter.place.Place.arrayLength: only a "
            ~ "static-array or slice place has a length",
        );
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

        // An AA place holds interpreted druntime's own `Impl*` handle, the
        // same one-word stored-reference shape a class place holds for its
        // object body.
        if (_type.isTypeAArray)
            return Place(readStoredPointer(_address), _type);

        throw new Exception(
            "quickbite.backends.interpreter.place.Place.deref: only a "
            ~ "pointer, class, or associative-array place can be "
            ~ "dereferenced",
        );
    }

    // The write side of `deref`'s class case, and now also of a pointer
    // place's own slot: stores `reference` -- a class object body's own
    // address, a pointer's own host address, or `null` -- as the
    // reference/pointer this place's own address holds. A caller here
    // already knows the native body or pointee address to store rather than
    // one following it FROM somewhere else. A stored class
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
        if (
            _type.isTypePointer is null &&
            _type.isTypeClass is null &&
            _type.isTypeAArray is null
        )
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.storeReference: "
                ~ "only a pointer, class, or associative-array place can "
                ~ "store a reference",
            );

        if (referenceIsGcOwned(reference) && !destinationIsScanned(_address))
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.storeReference: "
                ~ "this place is not scanned by the GC, but `reference` is a "
                ~ "live GC pointer",
            );

        writeStoredPointer(_address, reference);
    }

    // Reads the scalar at this place's address, at this place's own static
    // type. The compatibility boundary boxes the result only after
    // `native_scalar.readNativeScalar` has read it into the statically
    // selected host local. Only a native scalar type is legal here; a
    // non-scalar place refuses rather than guessing at a byte interpretation.
    public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult loadScalar() @safe {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.expression_result: ExpressionResult;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, nativeScalarKindOf, readNativeScalar;
        import quickbite.backends.interpreter.layout: typeByteSize;

        if (!isNativeScalarType(_type))
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.loadScalar: "
                ~ "type is not a native scalar type",
            );

        const bytes = placeBytes(_address, typeByteSize(_type));
        switch (nativeScalarKindOf(_type)) with (TY) {
            case Tbool:
                return ExpressionResult(readNativeScalar!bool(_type, bytes));
            case Tchar:
                return ExpressionResult(readNativeScalar!char(_type, bytes));
            case Twchar:
                return ExpressionResult(readNativeScalar!wchar(_type, bytes));
            case Tdchar:
                return ExpressionResult(readNativeScalar!dchar(_type, bytes));
            case Tint8:
                return ExpressionResult(readNativeScalar!byte(_type, bytes));
            case Tuns8:
                return ExpressionResult(readNativeScalar!ubyte(_type, bytes));
            case Tint16:
                return ExpressionResult(readNativeScalar!short(_type, bytes));
            case Tuns16:
                return ExpressionResult(readNativeScalar!ushort(_type, bytes));
            case Tint32:
                return ExpressionResult(readNativeScalar!int(_type, bytes));
            case Tuns32:
                return ExpressionResult(readNativeScalar!uint(_type, bytes));
            case Tint64:
                return ExpressionResult(readNativeScalar!long(_type, bytes));
            case Tuns64:
                return ExpressionResult(readNativeScalar!ulong(_type, bytes));
            case Tfloat32:
                return ExpressionResult(readNativeScalar!float(_type, bytes));
            case Tfloat64:
                return ExpressionResult(readNativeScalar!double(_type, bytes));
            default:
                throw new Exception(
                    "quickbite.backends.interpreter.place.Place.loadScalar: "
                    ~ "unsupported native scalar type",
                );
        }
    }

    // The inverse of `loadScalar`: casts `value` to this place's static type,
    // then writes it through the typed native scalar operation. Refuses the
    // same way `loadScalar` does for a non-scalar place.
    public void storeScalar(in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value) @safe {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        if (!isNativeScalarType(_type))
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.storeScalar: "
                ~ "type is not a native scalar type",
            );

        storeScalarCast(value);
    }

    // @trusted: `runtime_casts` is @system because it reads DMD type data.
    // This bridge passes this Place's already-held address and static type to
    // it; the cast writes through `storeNativeScalar`, which verifies the
    // destination width before its bounded memcpy.
    private void storeScalarCast(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @trusted {
        import dmd.astenums: TY;

        switch (_type.toBasetype.ty) with (TY) {
            case Tbool: storeNativeScalar(value.castTo!bool.asLong != 0); return;
            case Tint8: storeNativeScalar(cast(byte) value.castTo!byte.asLong); return;
            case Tuns8: storeNativeScalar(cast(ubyte) value.castTo!ubyte.asLong); return;
            case Tchar: storeNativeScalar(cast(char) value.castTo!char.asLong); return;
            case Tint16: storeNativeScalar(cast(short) value.castTo!short.asLong); return;
            case Tuns16: storeNativeScalar(cast(ushort) value.castTo!ushort.asLong); return;
            case Twchar: storeNativeScalar(cast(wchar) value.castTo!wchar.asLong); return;
            case Tint32: storeNativeScalar(cast(int) value.castTo!int.asLong); return;
            case Tuns32: storeNativeScalar(cast(uint) value.castTo!uint.asLong); return;
            case Tdchar: storeNativeScalar(cast(dchar) value.castTo!dchar.asLong); return;
            case Tint64: storeNativeScalar(value.castTo!long.asLong); return;
            case Tuns64: storeNativeScalar(cast(ulong) value.castTo!ulong.asLong); return;
            case Tfloat32: storeNativeScalar(cast(float) value.castTo!float.asReal); return;
            case Tfloat64: storeNativeScalar(cast(double) value.castTo!double.asReal); return;
            case Tfloat80: storeNativeScalar(value.castTo!real.asReal); return;
            case Timaginary32: storeNativeScalar(cast(ifloat) value.castToImaginary.imaginaryPart); return;
            case Timaginary64: storeNativeScalar(cast(idouble) value.castToImaginary.imaginaryPart); return;
            case Timaginary80: storeNativeScalar(cast(ireal) value.castToImaginary.imaginaryPart); return;
            case Tcomplex32: {
                const casted = value.castToComplex;
                storeNativeScalar(
                    cast(cfloat) casted.complexRealPart.asReal +
                        cast(float) casted.complexImaginaryPart.asReal * 1.0fi,
                );
                return;
            }
            case Tcomplex64: {
                const casted = value.castToComplex;
                storeNativeScalar(
                    cast(cdouble) casted.complexRealPart.asReal +
                        cast(double) casted.complexImaginaryPart.asReal * 1.0i,
                );
                return;
            }
            case Tcomplex80: {
                const casted = value.castToComplex;
                storeNativeScalar(
                    cast(creal) casted.complexRealPart.asReal +
                        cast(real) casted.complexImaginaryPart.asReal * 1.0Li,
                );
                return;
            }
            default:
                throw new Exception("Unsupported scalar cast destination.");
        }
    }

    public void storeNativeScalar(T)(in T value) @safe {
        import quickbite.backends.interpreter.native_scalar: writeNativeScalar;
        import quickbite.backends.interpreter.layout: typeByteSize;

        writeNativeScalar(_type, placeBytes(_address, typeByteSize(_type)), value);
    }

    // Read a scalar into the caller's statically selected host type. This is
    // intentionally a typed operation: it is not a replacement value
    // carrier. The caller selects T from the DMD expression type.
    public T loadNativeScalar(T)() @trusted {
        import core.stdc.string: memcpy;
        import quickbite.backends.interpreter.layout: typeByteSize;

        if (typeByteSize(_type) != T.sizeof)
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.loadNativeScalar: "
                ~ "destination size does not match the scalar type",
            );

        T value;
        // @trusted: the checked byte size proves that this copy writes only
        // the scalar local, and memcpy handles an unaligned place address.
        memcpy(&value, _address, T.sizeof);
        return value;
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

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

    // Read the address stored in a pointer, class-reference, or
    // associative-array place. The result is the native address itself;
    // callers that need the pointed-to value compose another typed `Place`
    // from it.
    public void* loadReference() @safe {
        if (
            _type.isTypePointer is null &&
            _type.isTypeClass is null &&
            _type.isTypeAArray is null
        )
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.loadReference: "
                ~ "only a pointer, class, or associative-array place stores "
                ~ "a reference",
            );

        return readStoredPointer(_address);
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

    // Copy one complete native-layout value into this typed destination,
    // bytes only: unlike `copyPlaceValue` (`impl.d`), this performs no
    // out-of-band metadata copy/clear, so it is safe only where the caller
    // has already accounted for that separately -- `copyPlaceValue` itself,
    // pairing this with `copyStoredMetadata`, and `copyFromNative` below,
    // whose own callers move a value that can never carry symbolic
    // TypeName/delegate/function-pointer metadata (see each call site's own
    // comment). `package` visibility keeps every caller inside this
    // interpreter backend, where that precondition can be audited; a
    // metadata-bearing type reaching this directly from outside the package
    // would silently leak a stale side-table entry. The byte copy keeps
    // aggregate padding and overlap intact. A class reference is a one-word
    // slot, so derived and base class places can copy that slot despite
    // their distinct static types.
    package void copyFromUnchecked(Place source) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize;

        const classReference = isClassType(source.type) && isClassType(_type);
        if (!sameBaseType(source.type, _type) && !classReference)
            throw new Exception(
                "quickbite.backends.interpreter.place.Place.copyFromUnchecked: "
                ~ "type mismatch " ~ typeName(source.type)
                ~ " -> " ~ typeName(_type),
            );

        copyPlaceBytes(_address, source.address, typeByteSize(_type));
    }

    // Copy an owned aggregate into this place. A catch variable is a
    // pointer-typed slot even when its source is a class reference, so it
    // stores the referenced body rather than the source reference slot.
    // `copyFromUnchecked`, not `copyPlaceValue`: `place_value.writeValue`
    // (this function's sole caller) already dispatches a native-aggregate
    // value to here ahead of every metadata-bearing arm (TypeName,
    // delegate, function pointer), so `sourceType` is always a plain
    // aggregate or a class reference, never a type this module's
    // out-of-band tables key on.
    public void copyFromNative(
        imported!"dmd.mtype".Type sourceType,
        void* sourceAddress,
    ) @safe {
        if (isClassType(sourceType) && _type.isTypePointer !is null) {
            storeReference(Place(sourceAddress, sourceType).deref.address);
            return;
        }

        copyFromUnchecked(Place(sourceAddress, sourceType));
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

    public long loadSignedScalar() @safe {
        import dmd.astenums: TY;

        auto type = scalarBaseType(_type);
        with (TY) switch (type.ty) {
            case Tbool: return loadNativeScalar!bool;
            case Tint8: return loadNativeScalar!byte;
            case Tuns8: return loadNativeScalar!ubyte;
            case Tchar: return loadNativeScalar!char;
            case Tint16: return loadNativeScalar!short;
            case Tuns16: return loadNativeScalar!ushort;
            case Twchar: return loadNativeScalar!wchar;
            case Tint32: return loadNativeScalar!int;
            case Tuns32: return loadNativeScalar!uint;
            case Tdchar: return loadNativeScalar!dchar;
            case Tint64: return loadNativeScalar!long;
            case Tuns64: return cast(long) loadNativeScalar!ulong;
            default:
                throw new Exception("Place.loadSignedScalar needs an integer scalar.");
        }
    }

    public ulong loadUnsignedScalar() @safe {
        import dmd.astenums: TY;

        auto type = scalarBaseType(_type);
        with (TY) switch (type.ty) {
            case Tbool: return loadNativeScalar!bool;
            case Tint8: return cast(ulong) loadNativeScalar!byte;
            case Tuns8: return loadNativeScalar!ubyte;
            case Tchar: return loadNativeScalar!char;
            case Tint16: return cast(ulong) loadNativeScalar!short;
            case Tuns16: return loadNativeScalar!ushort;
            case Twchar: return loadNativeScalar!wchar;
            case Tint32: return cast(ulong) loadNativeScalar!int;
            case Tuns32: return loadNativeScalar!uint;
            case Tdchar: return loadNativeScalar!dchar;
            case Tint64: return cast(ulong) loadNativeScalar!long;
            case Tuns64: return loadNativeScalar!ulong;
            default:
                throw new Exception("Place.loadUnsignedScalar needs an integer scalar.");
        }
    }

    public real loadRealScalar() @safe {
        import dmd.astenums: TY;

        auto type = scalarBaseType(_type);
        with (TY) switch (type.ty) {
            case Tbool: return loadNativeScalar!bool;
            case Tint8: return loadNativeScalar!byte;
            case Tuns8: return loadNativeScalar!ubyte;
            case Tchar: return loadNativeScalar!char;
            case Tint16: return loadNativeScalar!short;
            case Tuns16: return loadNativeScalar!ushort;
            case Twchar: return loadNativeScalar!wchar;
            case Tint32: return loadNativeScalar!int;
            case Tuns32: return loadNativeScalar!uint;
            case Tdchar: return loadNativeScalar!dchar;
            case Tint64: return loadNativeScalar!long;
            case Tuns64: return loadNativeScalar!ulong;
            case Tfloat32: return loadNativeScalar!float;
            case Tfloat64: return loadNativeScalar!double;
            case Tfloat80: return loadNativeScalar!real;
            case Timaginary32: return loadNativeScalar!ifloat.im;
            case Timaginary64: return loadNativeScalar!idouble.im;
            case Timaginary80: return loadNativeScalar!ireal.im;
            case Tcomplex32: return loadNativeScalar!cfloat.re;
            case Tcomplex64: return loadNativeScalar!cdouble.re;
            case Tcomplex80: return loadNativeScalar!creal.re;
            default:
                throw new Exception("Place.loadRealScalar needs a numeric scalar.");
        }
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


// `Type.toBasetype` is not @safe; this keeps the class-reference check at a
// narrow DMD boundary.
private bool isClassType(imported!"dmd.mtype".Type type) @trusted {
    return type.toBasetype.isTypeClass !is null;
}


// DMD's immutable type graph supplies this read-only base-type query, but its
// API is not annotated `@safe`.
private imported!"dmd.mtype".Type scalarBaseType(
    imported!"dmd.mtype".Type type,
) @trusted {
    auto base = type.toBasetype;
    auto enumType = base.isTypeEnum;
    return enumType is null ? base : enumType.toBasetype2;
}


// DMD interns base types, while modifiers and aliases can give two different
// Type objects for the same guest-layout value. A native copy needs layout
// identity, not wrapper object identity.
private bool sameBaseType(
    imported!"dmd.mtype".Type lhs,
    imported!"dmd.mtype".Type rhs,
) @trusted {
    import dmd.astenums: TY;
    import dmd.typesem: mutableOf, unSharedOf;

    auto lhsVector = lhs.toBasetype.isTypeVector;
    auto rhsVector = rhs.toBasetype.isTypeVector;
    if (lhsVector !is null || rhsVector !is null)
        return lhsVector !is null && rhsVector !is null &&
            mutableOf(lhsVector.basetype).unSharedOf.equals(
                mutableOf(rhsVector.basetype).unSharedOf,
            );

    auto lhsPointer = lhs.toBasetype.isTypePointer;
    auto rhsPointer = rhs.toBasetype.isTypePointer;
    if (lhsPointer !is null || rhsPointer !is null)
        return lhsPointer !is null && rhsPointer !is null &&
            sameBaseType(lhsPointer.next, rhsPointer.next);

    auto lhsArray = lhs.toBasetype.isTypeDArray;
    auto rhsArray = rhs.toBasetype.isTypeDArray;
    if (lhsArray !is null && rhsArray !is null) {
        if (lhsArray.next.toBasetype.ty == TY.Tvoid)
            return true;
        if (rhsArray.next.toBasetype.ty == TY.Tvoid)
            return true;
        return sameBaseType(lhsArray.next, rhsArray.next);
    }

    // A druntime AA hook signature templated on `inout` sees the
    // interpreted value's key and value types through that qualifier,
    // diverging from the guest-declared unqualified types even though the
    // layout is identical; compare key and value structurally, as the
    // TypeDArray arm above does for its element type. Unlike a dynamic
    // array, an AA literal cannot elide its key/value types to `void`, so
    // there is no wildcard case to mirror here.
    auto lhsAArray = lhs.toBasetype.isTypeAArray;
    auto rhsAArray = rhs.toBasetype.isTypeAArray;
    if (lhsAArray !is null && rhsAArray !is null)
        return sameBaseType(lhsAArray.index, rhsAArray.index) &&
            sameBaseType(lhsAArray.next, rhsAArray.next);

    return mutableOf(lhs.toBasetype).unSharedOf.equals(
        mutableOf(rhs.toBasetype).unSharedOf,
    );
}


// DMD owns the null-terminated type spelling for the lifetime of the AST;
// copying it makes the diagnostic independent of that internal buffer.
private string typeName(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return type.toChars.fromStringz.idup;
}


// Both addresses come from DMD-sized storage of compatible static types,
// checked by `Place.copyFromUnchecked` before this boundary. `memmove`
// preserves overlap, aggregate padding, and union bytes without field
// traversal.
private void copyPlaceBytes(
    void* destination,
    void* source,
    in size_t length,
) pure nothrow @trusted {
    import core.stdc.string: memmove;

    memmove(destination, source, length);
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

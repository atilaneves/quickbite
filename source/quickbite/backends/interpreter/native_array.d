module quickbite.backends.interpreter.native_array;


private:


// A D dynamic array's runtime representation is `{ size_t length; T* ptr; }`
// -- length at offset 0, pointer at offset `size_t.sizeof`. This is a
// language ABI fact, not a per-type layout fact DMD exposes as offsets, so
// it is stated once here and guarded by the host compiler's own slice
// layout rather than hand-rolled.
static assert((void[]).sizeof == 2 * size_t.sizeof);


// The array-native block handle skeleton (ai/plans/value.md item 7's
// "Next PR"): an interpreter-owned array value carrying a stable block, the
// DMD element type, length, and stride. `allocate` picks the block's GC scan
// policy from whether the element type carries pointers; there is no
// separate root-registration token or lifecycle to track (see
// `NativeBlock.Scan` and ai/plans/value.md's "GC roots" note).
public struct NativeArray {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import dmd.mtype: Type;

    private NativeBlock _block;
    private Type _elementType;
    private size_t _length;
    private size_t _stride;

    // Allocates one block of `length * stride` zeroed bytes, `stride` being
    // `elementType`'s DMD byte size. Elements are contiguous at
    // `index * stride`, which is D's own array layout -- no invented
    // padding. The block's scan policy follows `elementType`: pointer-
    // bearing elements get a conservatively scanned block so the GC can
    // still find what they point to; everything else is `NO_SCAN`. Not
    // `nothrow`: `typeByteSize` throws on an unsized type.
    public static NativeArray allocate(
        imported!"dmd.mtype".Type elementType,
        in size_t length,
    ) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;

        const stride = typeByteSize(elementType);
        const scan = typeHasPointers(elementType)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no;
        return NativeArray(
            NativeBlock.allocate(length * stride, scan),
            elementType,
            length,
            stride,
        );
    }

    public inout(imported!"dmd.mtype".Type) elementType() inout pure nothrow @nogc @safe {
        return _elementType;
    }

    public size_t length() const pure nothrow @nogc @safe {
        return _length;
    }

    public size_t stride() const pure nothrow @nogc @safe {
        return _stride;
    }

    public NativeBlock.Ownership ownership() const pure nothrow @nogc @safe {
        return _block.ownership;
    }

    public inout(NativeBlock) block() inout pure nothrow @nogc @safe {
        return _block;
    }

    // The bytes of element `index`: an interior view into the block at
    // `index * stride .. (index + 1) * stride`. An out-of-range `index`
    // fails via ordinary D slice bounds checking on `block.bytes`, not a
    // hand-rolled check.
    public inout(ubyte)[] element(in size_t index) inout pure @safe {
        const start = index * _stride;
        return _block.bytes[start .. start + _stride];
    }

    // The byte length of a D dynamic-array slice header (`{ length, ptr }`):
    // `writeSliceHeader`'s destination must be exactly this many bytes.
    public enum size_t sliceHeaderByteLength = (void[]).sizeof;

    // Writes this array's slice header -- `{ length, ptr }` -- into `dest`,
    // the storage location of the guest's `T[]` variable (the destination
    // aliases the element block; it is not a snapshot). `dest` must be
    // exactly `sliceHeaderByteLength` bytes; a mismatched length throws
    // rather than truncating into, or overwriting past, `dest`. The written
    // `ptr` is the element block's address (legitimately `null` for a
    // zero-length array, see `NativeBlock.allocate(0)`); the written
    // `length` is the element count, not a byte length.
    public void writeSliceHeader(ubyte[] dest) const @safe {
        if (dest.length != sliceHeaderByteLength)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "writeSliceHeader: destination must be exactly "
                ~ "sliceHeaderByteLength bytes",
            );

        writeSliceHeaderBytes(dest, _length, _block.address);
    }
}

// Writing a raw pointer's bit pattern into a byte range is not @safe; this
// is the @trusted boundary. `memcpy` (rather than a pointer-typed store)
// avoids relying on `dest` being size_t-aligned, which a caller-supplied
// `ubyte[]` is not guaranteed to be.
private void writeSliceHeaderBytes(
    ubyte[] dest,
    in size_t length,
    const(void)* ptr,
) @trusted
in (dest.length == NativeArray.sliceHeaderByteLength) {
    import core.stdc.string: memcpy;

    memcpy(dest.ptr, &length, size_t.sizeof);
    memcpy(dest.ptr + size_t.sizeof, &ptr, (void*).sizeof);
}

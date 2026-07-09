module quickbite.backends.interpreter.native_array;


private:


// The array-native block handle skeleton (ai/plans/value.md item 7's
// "Next PR"): an interpreter-owned array value carrying a stable block, the
// DMD element type, length, and stride. GC root state is a later commit --
// deliberately absent here.
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
}

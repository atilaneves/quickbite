module quickbite.backends.interpreter.frame_block;


private:


// The per-activation GC storage for a `FrameLayout`: one block sized to
// `layout.byteLength`, holding every owning local's slot at the layout's
// own packed offset. Mirrors how `NativeStruct` pairs a block with the DMD
// layout it was built from, reusing the same block/offset machinery rather
// than growing a second one.
public struct FrameBlock {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.frame_layout: FrameLayout;
    import dmd.declaration: VarDeclaration;

    private NativeBlock _block;
    private FrameLayout _layout;

    // Allocates one block of `layout.byteLength` bytes. The scan policy is
    // `NativeBlock.Scan.conservative` if any slotted local's type carries
    // pointers, `NativeBlock.Scan.no` otherwise -- computed explicitly here,
    // never defaulted, since an under-scanned block holding a guest pointer
    // becomes a use-after-free once the GC can no longer see what it points
    // to (`NativeBlock.allocate`'s own contract). A zero-slot activation
    // (`layout.byteLength == 0`, no owning locals) still allocates a real,
    // zero-length block, with `Scan.no` falling out naturally: an empty
    // slot set has no pointer-carrying local to find.
    public static FrameBlock allocate(FrameLayout layout) @safe {
        const scan = frameHasPointers(layout)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no;
        return FrameBlock(NativeBlock.allocate(layout.byteLength, scan), layout);
    }

    // The host address of `variable`'s slot: this block's base address plus
    // the layout's own offset for that slot, mirroring how `NativeStruct.
    // field` indexes into its block at a DMD-derived field offset. Calling
    // this on a local with no slot (an aliasing `ref`/`out`/`lazy` parameter
    // or `ref` body local, never assigned one by `computeFrameLayout`) is a
    // programming error -- asserted directly rather than silently returning
    // an address that belongs to some other slot.
    public void* slotAddress(VarDeclaration variable) @safe {
        assert(_layout.has(variable), "variable has no frame slot");
        return slotAddressImpl(_block.address, _layout[variable].offset);
    }

    // Whether this activation owns a frame slot for `variable`, so a
    // caller can guard `slotAddress` (and anything built on it) instead of
    // hitting its assert for an aliasing local.
    public bool hasSlot(VarDeclaration variable) const @safe {
        return _layout.has(variable);
    }

    public size_t byteLength() const pure nothrow @nogc @safe {
        return _block.byteLength;
    }

    public inout(NativeBlock) block() inout pure nothrow @nogc @safe {
        return _block;
    }
}


// Pointer arithmetic on a raw block address is not `@safe`; this is the
// `@trusted` boundary. `offset` is always one of `layout`'s own packed slot
// offsets, so `base + offset` stays within the block `base` was allocated
// with -- the same guarantee `NativeStruct.field`'s block indexing relies
// on for its own DMD-derived offsets.
private void* slotAddressImpl(void* base, in size_t offset) pure nothrow @trusted {
    return base + offset;
}


// Whether any of `layout`'s slotted locals has a pointer-carrying type.
private bool frameHasPointers(
    imported!"quickbite.backends.interpreter.frame_layout".FrameLayout layout,
) @safe {
    import quickbite.backends.interpreter.layout: typeHasPointers, declaredType;

    foreach (variable, slot; layout.slots)
        if (typeHasPointers(declaredType(variable)))
            return true;

    return false;
}

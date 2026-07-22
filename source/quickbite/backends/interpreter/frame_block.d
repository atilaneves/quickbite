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
    // programming error, refused by the `in` contract rather than silently
    // returning an address that belongs to some other slot. `@trusted` for
    // the pointer arithmetic on the raw block address: the offset is one of
    // the layout's own packed slot offsets, so `base + offset` stays within
    // the block `base` was allocated with -- the same guarantee
    // `NativeStruct.field`'s block indexing relies on for its own
    // DMD-derived offsets.
    public void* slotAddress(VarDeclaration variable) @trusted
    in (_layout.has(variable), "variable has no frame slot") {
        return _block.address + _layout[variable].offset;
    }

    // `variable`'s slot offset from this block's own base address, i.e.
    // `slotAddress(variable) - block.address` without the pointer
    // subtraction: the layout's own packed offset for that slot, the same
    // number `slotAddress` already adds to the block's base. Same
    // precondition as `slotAddress`, enforced by the same `in` contract.
    public size_t slotOffset(VarDeclaration variable) const @safe
    in (_layout.has(variable), "variable has no frame slot") {
        return _layout[variable].offset;
    }

    // Whether this activation owns a frame slot for `variable` (of EITHER
    // kind), so a caller can guard `slotAddress` (and anything built on
    // it) instead of hitting its `in` contract for an aliasing local.
    public bool hasSlot(VarDeclaration variable) const @safe {
        return _layout.has(variable);
    }

    // Whether `variable` owns an OWNING slot specifically: inline storage
    // of its own declared type, as opposed to a REFERENCE slot holding a
    // caller-supplied address (`hasReferenceSlot` below) or no slot at
    // all. The verified frame mirror (`impl.d`'s `mirrorToFrame`/
    // `assertFrameMirror`) gates on this, never on `hasSlot` alone: a
    // reference slot's bytes are an address, not a `place_value`
    // composition of `variable`'s own declared type, so mirroring it the
    // same way would write the wrong bytes into the wrong-sized slot.
    public bool hasOwningSlot(VarDeclaration variable) const @safe {
        return _layout.has(variable)
            && _layout[variable].kind == FrameLayout.Slot.Kind.owning;
    }

    // The REFERENCE-slot sibling of `hasOwningSlot` above: whether
    // `variable` is a `ref`/`out` parameter with a pointer-width slot
    // holding the caller-supplied address it binds to.
    public bool hasReferenceSlot(VarDeclaration variable) const @safe {
        return _layout.has(variable)
            && _layout[variable].kind == FrameLayout.Slot.Kind.reference;
    }

    // The address `variable`'s own reference slot currently holds --
    // `slotAddress`'s raw pointer READ, for a caller that already knows
    // (via `hasReferenceSlot`) this is a reference slot rather than
    // owning storage. Not `@safe`: reinterpreting the slot's raw bytes as
    // a stored `void*` cannot be verified by the compiler, the same
    // boundary `place.d`'s own `readStoredPointer` crosses for an
    // identically-shaped read.
    //
    // THROWS on a caller that got that wrong, rather than stating it as an
    // `in` contract the way `slotAddress`/`slotOffset` above do, for the
    // reason `object_table.ObjectTable.storageFor` gives at length for its
    // own size check: `-release` strips a contract, and that is precisely
    // the build where silent memory corruption matters most. The
    // distinction from those two is not taste. Their contract is belt and
    // braces -- the very next thing they do is `_layout[variable]`, an
    // associative-array lookup that raises `RangeError` on a missing key in
    // every build, so a slotless caller cannot get past them quietly. This
    // pair has no such backstop: an OWNING slot IS in the layout, so the
    // lookup succeeds and the pointer-width write below lands inside a slot
    // that may be narrower than eight bytes, silently overwriting the
    // neighbouring local packed after it. The only thing standing between
    // that and a caller bug is this check, so it must survive `-release`.
    public void* referenceSlotValue(VarDeclaration variable) @trusted {
        if (!hasReferenceSlot(variable))
            throw new Exception(
                "quickbite.backends.interpreter.frame_block.FrameBlock."
                ~ "referenceSlotValue: variable has no reference slot",
            );

        return *cast(void**) slotAddress(variable);
    }

    // The address to which `variable` is bound in this activation. An
    // OWNING slot binds directly to its inline storage; a REFERENCE slot
    // binds to the caller address it holds. This is intentionally only a
    // mechanical decoding of the frame's existing slot representation: it
    // neither owns storage nor decides which representation is authoritative.
    // A caller with no slot is refused rather than inventing an address.
    public void* bindingAddress(VarDeclaration variable) @trusted {
        if (hasOwningSlot(variable))
            return slotAddress(variable);

        if (hasReferenceSlot(variable))
            return referenceSlotValue(variable);

        throw new Exception(
            "quickbite.backends.interpreter.frame_block.FrameBlock."
            ~ "bindingAddress: variable has no frame slot",
        );
    }

    // The write side of `referenceSlotValue` above: stores `address` as
    // the caller-supplied address `variable`'s own reference slot binds
    // to. Same `@trusted` boundary, and the same throw for the same reason
    // -- more sharply so, since this is the write half.
    public void setReferenceSlot(VarDeclaration variable, void* address) @trusted {
        if (!hasReferenceSlot(variable))
            throw new Exception(
                "quickbite.backends.interpreter.frame_block.FrameBlock."
                ~ "setReferenceSlot: variable has no reference slot",
            );

        *cast(void**) slotAddress(variable) = address;
    }

    public size_t byteLength() const pure nothrow @nogc @safe {
        return _block.byteLength;
    }

    public inout(NativeBlock) block() inout pure nothrow @nogc @safe {
        return _block;
    }
}


// Whether any of `layout`'s slots needs the GC to scan for a pointer: a
// REFERENCE slot always does -- what it holds IS an address, regardless of
// the parameter's own declared type -- and an OWNING slot does exactly
// when its own declared type does (unchanged).
private bool frameHasPointers(
    imported!"quickbite.backends.interpreter.frame_layout".FrameLayout layout,
) @safe {
    import quickbite.backends.interpreter.frame_layout: FrameLayout;
    import quickbite.backends.interpreter.layout: typeHasPointers, declaredType;

    foreach (variable, slot; layout.slots) {
        if (slot.kind == FrameLayout.Slot.Kind.reference)
            return true;
        if (typeHasPointers(declaredType(variable)))
            return true;
    }

    return false;
}

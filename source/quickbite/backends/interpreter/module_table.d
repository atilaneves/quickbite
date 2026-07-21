module quickbite.backends.interpreter.module_table;


private:


// The module-lifetime GC storage for module-level guest state: each
// static/global `VarDeclaration` is bound to its own `NativeBlock`, sized
// to its own declared type. Unlike `FrameBlock`, which packs every
// per-activation local's slot into one shared block, a module variable
// gets a block all to itself -- module vars have no activation to pack
// against, and each one's storage must outlive any particular call the way
// an activation's frame does not.
public struct ModuleTable {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import dmd.declaration: VarDeclaration;

    private NativeBlock[VarDeclaration] _blocks;

    // The stable address of `variable`'s own module-lifetime block. The
    // first call for a given `variable` allocates its block, sized to
    // `variable`'s own type with a scan policy from `layout.
    // typeHasPointers`; every later call for the same `variable` returns
    // that same block's address, unchanged.
    public void* storageFor(VarDeclaration variable) @safe {
        if (auto block = variable in _blocks)
            return block.address;

        auto block = allocateBlock(variable);
        _blocks[variable] = block;
        return block.address;
    }

    public bool has(VarDeclaration variable) const pure nothrow @safe {
        return (variable in _blocks) !is null;
    }

    // The `NativeBlock` bound to `variable`, once `storageFor` has
    // allocated it -- exposed for callers that need the block's own
    // properties (`byteLength`, `scan`), not just its bare address.
    // `inout`, not `const`: `NativeBlock` holds a `ubyte[]` field, and a
    // `const` return would need to strip that field's constness to convert
    // back to a plain `NativeBlock`, the same reason `FrameBlock.block`
    // returns `inout` rather than `const`.
    public inout(NativeBlock) opIndex(VarDeclaration variable) inout pure @safe {
        return _blocks[variable];
    }
}


// Allocates `variable`'s own block: sized to its declared type, scanned
// conservatively if that type carries pointers, `no` otherwise -- computed
// explicitly, never defaulted, since an under-scanned block holding a
// guest pointer becomes a use-after-free once the GC can no longer see
// what it points to (`NativeBlock.allocate`'s own contract). Mirrors
// `FrameBlock.allocate`'s scan-policy choice, applied to one variable's own
// type rather than a whole activation's slot set. A `variable` whose type
// DMD cannot size (`layout.typeIsSized` false) is a programming error --
// asserted directly rather than allocating a guessed size, matching
// `FrameBlock.slotAddress`'s assert style.
private imported!"quickbite.backends.interpreter.native_block".NativeBlock allocateBlock(
    imported!"dmd.declaration".VarDeclaration variable,
) @safe {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers, typeIsSized, declaredType;

    auto type = declaredType(variable);
    assert(typeIsSized(type), "variable has no sized type for module storage");

    const scan = typeHasPointers(type) ? NativeBlock.Scan.conservative : NativeBlock.Scan.no;
    return NativeBlock.allocate(typeByteSize(type), scan);
}

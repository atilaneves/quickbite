module quickbite.backends.interpreter.object_table;


private:


// The object-lifetime GC storage for class instances: each class object's
// body gets its own `NativeBlock`, keyed by the object's own stable
// identity (`quickbite.lang.Value.classIdentity`, minted once per boxed
// class object -- see `impl.d`'s `classObjectCells`) rather than by any
// variable that happens to reference it. Unlike `ModuleTable`, which keys
// on a `VarDeclaration` because a module variable IS its own storage, many
// variables (and struct/array fields, slice elements, ...) can hold
// references to the SAME object, and every one of them must resolve to
// the SAME block -- decision 15's "a class variable holds a reference
// (address) to an object block owned by object identity"
// (`ai/plans/value.md`).
public struct ObjectTable {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import dmd.dclass: ClassDeclaration;

    private NativeBlock[size_t] _blocks;

    // The stable address of the object body identified by `identity`. The
    // first call for a given `identity` allocates its block, sized and
    // scanned from `class_`'s own DMD layout; every later call for the
    // same `identity` returns that same block's address, unchanged.
    // `class_` is consulted only on that first call -- an object's runtime
    // class is fixed at construction, so a later call for an
    // already-allocated identity needs no class to size against.
    public void* storageFor(size_t identity, ClassDeclaration class_) @safe {
        if (auto block = identity in _blocks)
            return block.address;

        auto block = allocateBlock(class_);
        _blocks[identity] = block;
        return block.address;
    }

    public bool has(size_t identity) const pure nothrow @safe {
        return (identity in _blocks) !is null;
    }

    // The `NativeBlock` bound to `identity`, once `storageFor` has
    // allocated it -- exposed for callers that need the block's own
    // properties (`byteLength`, `scan`), not just its bare address.
    // `inout`, not `const`: `NativeBlock` holds a `ubyte[]` field, and a
    // `const` return would need to strip that field's constness to convert
    // back to a plain `NativeBlock`, the same reason `ModuleTable.opIndex`
    // returns `inout` rather than `const`.
    public inout(NativeBlock) opIndex(size_t identity) inout pure @safe {
        return _blocks[identity];
    }
}


// Allocates the body for a fresh class object: sized from `class_`'s own
// DMD instance size (`layout.classInstanceByteSize`, DMD's own
// `structsize` -- already includes the vtable pointer and monitor header),
// always scanned conservatively.
//
// Conservative scanning is not a default here, it is the ONLY legal
// choice: every class instance begins with a vtable pointer (and a
// monitor field) at offset 0 regardless of what its own declared fields'
// types are, so a class body always contains at least one GC pointer the
// collector must see -- true even for a class with zero user-declared
// fields. That is unlike `ModuleTable.allocateBlock`, which chooses
// between `no`/`conservative` from `layout.typeHasPointers` because a
// plain variable's storage has no such guaranteed header; a class body
// has no non-pointer-carrying case to check for; `no` would be wrong even
// then. `NativeBlock.allocate` takes no scan default on purpose --
// under-scanning is the unsafe direction -- so this states the choice
// explicitly rather than only implying it by never calling `no`.
private imported!"quickbite.backends.interpreter.native_block".NativeBlock allocateBlock(
    imported!"dmd.dclass".ClassDeclaration class_,
) @safe {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.layout: classInstanceByteSize;

    return NativeBlock.allocate(classInstanceByteSize(class_), NativeBlock.Scan.conservative);
}

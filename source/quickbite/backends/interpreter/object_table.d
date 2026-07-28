module quickbite.backends.interpreter.object_table;


private:


public struct ObjectTable {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import dmd.dclass: ClassDeclaration;

    private NativeBlock[size_t] _blocks;

    // Bumped by every `storageFor` call for `identity` that actually hands
    // out an address, first allocation or not -- a monotonic "who last
    // touched this body" token. Every real
    // caller (`impl.d`'s `mirrorClassToFrame`, directly for a variable's own
    // top-level identity, and `resolveObjectBody` for a class-typed field's
    // nested one) always follows the call with an actual write into the
    // returned address (`place_value.writeClassBody`'s own recursion), so a
    // call here always means "this identity's body is about to be
    // rewritten" -- bumping unconditionally, not only on first allocation,
    // is what lets `generation` answer "has anyone rewritten this body
    // since I last looked" for a SHARED identity two independent mirror
    // writes (different variables, or different activations) can each
    // reach. See `generation`'s own comment for the consumer. A call that
    // THROWS handed no address out and so had no write follow it -- hence
    // `scope(success)` rather than an unconditional bump, so a refused call
    // does not tell every other binding its snapshot is stale.
    private size_t[size_t] _generations;

    // The stable address of the object body identified by `identity`. The
    // first call for a given `identity` allocates its block, sized and
    // scanned from `class_`'s own DMD layout; every later call for the
    // same `identity` returns that same block's address, unchanged.
    // `class_` is consulted only on that first call -- an object's runtime
    // class is fixed at construction, so a later call for an
    // already-allocated identity needs no class to size against.
    //
    // The size check below is defense in depth, not the primary guard: a
    // caller reaching here with a `class_` whose size disagrees with
    // another caller's for the SAME `identity` is a caller bug --
    // `impl.d`'s `classBodyShapeMatches`/`classBodyShapeMatchesImpl` are
    // the actual gate that keeps every caller's `class_` for a given
    // identity equal to that identity's own dynamic class (their own
    // header comments carry the full story -- silent GC-heap corruption
    // otherwise: a `Base`-typed mirror allocating first and a
    // `Derived`-typed mirror for the SAME identity following would get
    // that same too-small block back unchanged, and the composition this
    // address is handed to (`place_value.writeClassBody`) has no bounds
    // check of its own). Checked as an exact size MISMATCH, not only a
    // too-small one: once the primary gate holds, every caller's `class_`
    // for a given identity is the SAME class, so its instance size is
    // exactly the cached block's size every time, never merely no-larger
    // -- a caller passing a class one field NARROWER (memory-safe by
    // itself) is just as much evidence of the invariant having broken as
    // one field wider. Throwing rather than an `in` contract, which
    // `-release` strips -- precisely the build this kind of silent
    // corruption matters most in -- because a violation here is an
    // internal invariant broken by a caller, not guest-reachable input;
    // the same "throw for a broken invariant" idiom `quickbite.backends.interpreter.runtime_value.Value`'s
    // own variant accessors already use (e.g. `classTypeName` on a
    // non-class `Value`).
    public void* storageFor(size_t identity, ClassDeclaration class_) @safe {
        import quickbite.backends.interpreter.layout:
            classInstanceByteSize, classQualifiedName;
        import std.conv: text;

        scope(success) _generations[identity] = _generations.get(identity, 0) + 1;

        if (auto block = identity in _blocks) {
            if (block.byteLength != classInstanceByteSize(class_))
                throw new Exception(text(
                    "quickbite.backends.interpreter.object_table.ObjectTable"
                    ~ ".storageFor: identity ", identity, "'s already-",
                    "allocated body is ", block.byteLength, " bytes, but ",
                    classQualifiedName(class_), " needs ",
                    classInstanceByteSize(class_), " -- a caller passed a ",
                    "class narrower or wider than the one this identity ",
                    "was first allocated for",
                ));

            return block.address;
        }

        auto block = allocateBlock(class_);
        _blocks[identity] = block;
        return block.address;
    }

    public bool has(size_t identity) const pure nothrow @safe {
        return (identity in _blocks) !is null;
    }

    // `identity`'s current write generation -- 0 for an identity `storageFor`
    // has never been called for. A caller that recorded `generation(identity)`
    // right after its own write and later sees a DIFFERENT value here knows
    // some OTHER `storageFor` call -- another variable's mirror, another
    // activation's, it makes no difference which since the table is shared
    // for the whole execution (`impl.d`'s `classObjectTable` field comment)
    // -- has rewritten this identity's body since; see `impl.d`'s
    // `classMirrorGenerations`/`assertClassBodyValue` for the consumer.
    public size_t generation(size_t identity) const pure @safe {
        return _generations.get(identity, 0);
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

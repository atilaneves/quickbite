module quickbite.backends.interpreter.native_struct;


private:


// The struct-native block handle (ai/plans/value.md item 7's struct phase,
// "a struct is one block laid out with DMD field offsets"): an
// interpreter-owned struct value carrying a stable block and the DMD
// `TypeStruct`, reusing the same block/offset machinery `NativeArray`
// established for arrays. `allocate` picks the block's GC scan policy from
// whether the struct type carries pointers, exactly as `NativeArray.
// allocate` does for element types; a field's byte offset and byte size are
// both DMD's own numbers (`layout.fieldByteOffset`/`layout.typeByteSize`),
// never recomputed here.
public struct NativeStruct {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import dmd.mtype: TypeStruct;
    import dmd.declaration: VarDeclaration;

    private NativeBlock _block;
    private TypeStruct _type;
    private VarDeclaration[] _fields;

    // Allocates one block of `layout.typeByteSize(type)` bytes -- DMD's own
    // `structsize`, padding included. This never sums field sizes itself:
    // that would be a second, driftable copy of DMD's own layout (item 7's
    // guardrail). The block's scan policy follows `layout.
    // typeHasPointers(type)` exactly as `NativeArray.allocate` chooses it
    // from the element type: a struct with any pointer/slice/class/AA field
    // gets a conservatively scanned block, since a block's scan policy is
    // one attribute for its whole byte range, not per field. Not `nothrow`:
    // `typeByteSize` throws if DMD ever reported `type` as unsized (in
    // practice unreachable for a real `TypeStruct`, but not this
    // function's contract to assume).
    public static NativeStruct allocate(TypeStruct type) @safe {
        import quickbite.backends.interpreter.layout:
            typeByteSize, typeHasPointers, structFields;

        const scan = typeHasPointers(type)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no;
        return NativeStruct(
            NativeBlock.allocate(typeByteSize(type), scan),
            type,
            structFields(type),
        );
    }

    // Wraps memory owned elsewhere -- an interpreter-owned struct value
    // over caller-supplied storage (later: FFI/host memory).
    //
    // Precondition (caller-enforced, unverifiable here): `ptr` points to at
    // least `layout.typeByteSize(type)` valid, live bytes that outlive
    // every handle derived from this struct. This is a raw-memory
    // constructor -- it fabricates a block from a caller-supplied pointer
    // it cannot itself verify -- and so cannot be `@safe`; the FFI seam
    // that supplies `ptr` is the `@trusted` boundary that vouches for the
    // precondition, exactly as for `NativeBlock.borrow`/`NativeArray.
    // borrow`.
    public static NativeStruct borrow(TypeStruct type, void* ptr) @system {
        import quickbite.backends.interpreter.layout: typeByteSize, structFields;

        return NativeStruct(
            NativeBlock.borrow(ptr, typeByteSize(type)),
            type,
            structFields(type),
        );
    }

    public inout(TypeStruct) type() inout pure nothrow @nogc @safe {
        return _type;
    }

    public size_t byteSize() const pure nothrow @nogc @safe {
        return _block.byteLength;
    }

    public NativeBlock.Ownership ownership() const pure nothrow @nogc @safe {
        return _block.ownership;
    }

    public NativeBlock.Scan scan() const pure nothrow @nogc @safe {
        return _block.scan;
    }

    public inout(NativeBlock) block() inout pure nothrow @nogc @safe {
        return _block;
    }

    public size_t fieldCount() const pure nothrow @nogc @safe {
        return _fields.length;
    }

    // The DMD `VarDeclaration` for field `index`, in declaration order.
    // Bounds-checked against `fieldCount` first, matching `field`'s own
    // discipline below.
    public inout(VarDeclaration) fieldDeclaration(in size_t index) inout pure @safe {
        if (index >= _fields.length)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "fieldDeclaration: index out of range",
            );

        return _fields[index];
    }

    // The bytes of field `index`: an interior view into the block at DMD's
    // own `offset .. offset + fieldByteSize`. `index` is checked against
    // `fieldCount` first, before `fieldDeclaration`, `layout.
    // fieldByteOffset`, or `layout.typeByteSize` are ever consulted --
    // matching `NativeArray.element`'s discipline of failing on a bad index
    // before any arithmetic runs on it, rather than after. Unlike
    // `NativeArray.element`, there is no overflow to reason about in the
    // arithmetic itself: `offset` and `fieldByteSize` are both DMD's own
    // numbers, not a product of two caller-controlled values, and DMD
    // guarantees every field lies fully within `structsize` -- the same
    // guarantee `typeByteSize` reports as the block's own byte length. That
    // guarantee is relied on here, not re-derived: this does not re-check
    // `offset + fieldByteSize <= block.byteLength` itself. Not `inout`: DMD's
    // `VarDeclaration`/`Type` nodes are accessed unqualified throughout this
    // codebase (`layout.fieldByteOffset`/`typeByteSize` take plain, not
    // `const`/`inout`, arguments), so this only operates on a mutable
    // `NativeStruct`, matching that convention rather than casting a
    // qualifier away to force one.
    public ubyte[] field(in size_t index) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, fieldByteOffset;

        if (index >= _fields.length)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "field: index out of range",
            );

        // `auto`, not `const`: `layout.fieldByteOffset` takes a plain,
        // unqualified `VarDeclaration`, matching how DMD nodes are handled
        // everywhere else in this codebase.
        auto declaration = _fields[index];
        const offset = fieldByteOffset(declaration);
        const fieldSize = typeByteSize(declaration.type);
        return _block.bytes[offset .. offset + fieldSize];
    }
}

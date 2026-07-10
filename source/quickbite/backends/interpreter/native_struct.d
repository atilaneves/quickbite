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
    import quickbite.backends.interpreter.native_array: NativeArray;
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

    // The DMD byte offset of field `index`, verbatim from `layout.
    // fieldByteOffset`. `index` is bounds-checked against `fieldCount`
    // first, matching `fieldDeclaration`/`field`'s own discipline above --
    // a caller must not reach DMD's own offset lookup on an index that
    // isn't a real field. This is what a slice-header write into a struct
    // field needs directly: `array.writeSliceHeader(s.block,
    // s.fieldByteOffset(i))`. Not `const`, for the same reason as `field`
    // above: `layout.fieldByteOffset` takes a plain, unqualified
    // `VarDeclaration`, matching how DMD nodes are handled everywhere else
    // in this codebase.
    public size_t fieldByteOffset(in size_t index) @safe {
        import quickbite.backends.interpreter.layout: layoutFieldByteOffset = fieldByteOffset;

        if (index >= _fields.length)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "fieldByteOffset: index out of range",
            );

        return layoutFieldByteOffset(_fields[index]);
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

    // Views field `index` -- a struct-typed field -- as its own
    // `NativeStruct`, sharing the parent's block rather than copying it:
    // a nested struct field is not a separate allocation, it is a
    // `NativeBlock.subRange` of the parent at DMD's own offset for that
    // field, laid out with the nested type's own field offsets relative to
    // that sub-range. A write through the returned handle is visible in
    // the parent's bytes and vice versa. `index` is bounds-checked first,
    // matching every other field accessor's discipline of failing on a bad
    // index before any offset/size arithmetic runs on it; a field whose
    // type is not a struct throws its own message before any of that
    // arithmetic either, since `structFields`/`typeByteSize` would be
    // meaningless applied to the wrong DMD type.
    public NativeStruct structField(in size_t index) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, fieldByteOffset, structFields;

        if (index >= _fields.length)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "structField: index out of range",
            );

        auto declaration = _fields[index];
        auto structType = declaration.type.isTypeStruct;
        if (structType is null)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "structField: field is not a struct",
            );

        const offset = fieldByteOffset(declaration);
        const fieldSize = typeByteSize(structType);
        return NativeStruct(_block.subRange(offset, fieldSize), structType, structFields(structType));
    }

    // Views field `index` -- a static-array-typed field (DMD's
    // `TypeSArray`, e.g. `int[3]`) -- as a `NativeArray` over the same
    // block: this field's bytes ARE the array's storage, inline in the
    // parent's block, not a slice header pointing elsewhere. `index` is
    // bounds-checked first, and a field whose type is not a static array
    // throws its own message before any offset/size/length arithmetic
    // runs, exactly mirroring `structField`'s discipline above.
    public NativeArray arrayField(in size_t index) @safe {
        import quickbite.backends.interpreter.layout:
            typeByteSize, fieldByteOffset, staticArrayLength;

        if (index >= _fields.length)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "arrayField: index out of range",
            );

        auto declaration = _fields[index];
        auto arrayType = declaration.type.isTypeSArray;
        if (arrayType is null)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "arrayField: field is not a static array",
            );

        const offset = fieldByteOffset(declaration);
        const fieldSize = typeByteSize(arrayType);
        const length = staticArrayLength(arrayType);
        return NativeArray.adopt(_block.subRange(offset, fieldSize), arrayType.next, length);
    }
}

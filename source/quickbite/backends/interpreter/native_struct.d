module quickbite.backends.interpreter.native_struct;


private:


// The struct-native block handle -- a struct is one block laid out with
// DMD field offsets: an interpreter-owned struct value carrying a stable
// block and the DMD
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
    // that would be a second, driftable copy of DMD's own layout. The
    // block's scan policy follows `layout.
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

    // Adopts an existing block rather than allocating a new one -- mirrors
    // `NativeArray.adopt`: a caller already has a block (e.g. `NativeArray.
    // structElement`'s `NativeBlock.subRange` of an array's own block at
    // `index * stride`) and wants to view it as a `NativeStruct` without
    // copying or allocating a byte.
    //
    // Unlike `allocate`/`borrow`, `block` already exists at a byte length
    // this factory did not choose, so that byte length must be checked
    // rather than trusted: `block.byteLength` must be at least
    // `layout.typeByteSize(type)`, or a struct view over too few bytes
    // would let a field near the end of `structsize` read/write past the
    // block's own real storage -- `NativeArray.adopt`'s identical "does it
    // fit" discipline for its own `length * stride`, applied here to one
    // struct's `structsize` instead.
    //
    // A block LARGER than `typeByteSize(type)` is accepted, exactly as
    // `NativeArray.adopt` accepts a block larger than `length * stride`:
    // the extra bytes are none of this factory's business, they belong to
    // whatever the block's own owner uses them for. `byteSize` (`_block.
    // byteLength`) then honestly reports the adopted block's own real byte
    // length, which need not equal `typeByteSize(type)` -- exactly as
    // `NativeArray.block.byteLength` need not equal `length * stride` for
    // an adopted array.
    public static NativeStruct adopt(NativeBlock block, TypeStruct type) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, structFields;

        const size = typeByteSize(type);
        if (size > block.byteLength)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "adopt: typeByteSize(type) does not fit within block's byteLength",
            );

        return NativeStruct(block, type, structFields(type));
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
        import quickbite.backends.interpreter.layout: typeByteSize, fieldByteOffset;

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
        return NativeStruct.adopt(_block.subRange(offset, fieldSize), structType);
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

    // Views field `index` -- a dynamic-array-typed field (DMD's
    // `TypeDArray`, e.g. `int[]`) -- as a `NativeArray` over the element
    // block its stored slice header currently points at. Unlike
    // `structField`/`arrayField` above, this is NOT a `NativeBlock.subRange`
    // of the parent's own block: a slice header's `ptr` names a separately
    // tracked allocation somewhere else entirely (wherever `writeSliceHeader`
    // last wrote it from), so the only way to view "the elements this field
    // currently points at" is to read the `{ length, ptr }` bytes back out
    // of the field and reconstruct a handle from them -- exactly
    // `NativeArray.borrow`'s job, under the same caller-enforced,
    // unverifiable precondition `borrow` already documents (here, the
    // precondition is vouched for by whoever last wrote a valid header into
    // this field, typically `writeSliceHeader` itself). That unverifiable
    // reconstruction is why this is `@system`, unlike `structField`/
    // `arrayField`: those only ever slice an already-verified block with
    // ordinary bounds-checked D; this reconstructs a slice from a pointer
    // this code reads out of memory and cannot itself verify. The raw
    // two-value read itself is behind a small helper, `readSliceHeaderBytes`
    // -- living in `native_array.d`, alongside `sliceHeaderByteLength`/
    // `writeSliceHeaderBytes`, the other two pieces of that module's own
    // slice-header layout, and shared with `NativeArray.sliceElement`'s
    // identical read-back need -- marked `@trusted` rather than `@system`:
    // copying two fixed-size values out of an already bounds-checked byte
    // range into local storage cannot itself violate memory safety no
    // matter what bit pattern they contain -- it never dereferences the
    // pointer it reads. Only USING that pointer to reconstruct a slice
    // (`NativeArray.borrow`, below) is where the real, unverifiable trust
    // happens, and that call stays in this function, not the helper.
    //
    // `index` is bounds-checked first, matching every other field
    // accessor's discipline; a field whose type is not a dynamic array
    // throws its own message before any header bytes are read, since
    // `TypeDArray.next` would be meaningless applied to the wrong DMD type.
    //
    // The contract for the read-back header:
    //
    // - A zero-length/null header (`{ length: 0, ptr: null }` -- a
    //   struct's zero-initialised block before anything ever wrote to the
    //   field) reads back as a real, empty `NativeArray`: `NativeArray.
    //   borrow(elementType, null, 0)` is legal for the same reason
    //   `NativeBlock.borrow`'s own null/zero-length case already is.
    // - The returned array's `ownership` is always `borrowed`: this field
    //   does not own the element block, it only names it, so `reserve` on
    //   the returned handle throws exactly as for any other borrowed
    //   array.
    // - Its `scan`/`capacity` are `Scan.no`/`0` unconditionally, per
    //   `NativeBlock.borrow`'s own contract -- even when the pointed-to
    //   block is a real, conservatively-scanned GC allocation that this
    //   very struct field keeps alive (per `writeSliceHeader`'s
    //   scanned-destination contract, that is the only way the field
    //   could legally hold a live GC pointer at all). That is not
    //   dishonest: `NativeBlock.borrow` cannot know, from a bare
    //   pointer/length pair, that the memory it wraps happens to be GC
    //   memory this same interpreter also owns elsewhere -- it makes the
    //   same conservative "assume nothing" choice for every borrowed
    //   block, GC-backed or not. Who keeps the element block alive is
    //   unchanged by any of this: the struct field itself, via the GC's
    //   own scan of it (or, for an unscanned struct, whatever else still
    //   references it) -- never the handle returned here, which has
    //   nothing of its own to grow or free either way.
    // - This aliases, not snapshots: the returned `NativeArray` wraps the
    //   SAME address `writeSliceHeader` wrote, not a copy of its bytes. A
    //   write through the returned array is visible through any other
    //   array handle over the same block (including the one
    //   `writeSliceHeader` was called on), and vice versa, for as long as
    //   this field's header keeps pointing at that address. Nothing here
    //   re-reads the field on later access: a handle returned by an
    //   earlier `sliceField` call goes stale exactly like any other stale
    //   pointer once the field is overwritten or the element block moves
    //   (e.g. a grown, owned array reallocated elsewhere by `NativeArray.
    //   reserve`).
    public NativeArray sliceField(in size_t index) @system {
        import quickbite.backends.interpreter.layout: fieldByteOffset;
        import quickbite.backends.interpreter.native_array: readSliceHeaderBytes;

        if (index >= _fields.length)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "sliceField: index out of range",
            );

        auto declaration = _fields[index];
        auto arrayType = declaration.type.isTypeDArray;
        if (arrayType is null)
            throw new Exception(
                "quickbite.backends.interpreter.native_struct.NativeStruct."
                ~ "sliceField: field is not a dynamic array",
            );

        const offset = fieldByteOffset(declaration);
        // `auto`, not `const`: `header.ptr` is passed on to `NativeArray.
        // borrow`, which takes a mutable `void*` -- `const` here would
        // narrow it to `const(void*)` and fail to match that parameter.
        auto header = readSliceHeaderBytes(
            _block.bytes[offset .. offset + NativeArray.sliceHeaderByteLength]);

        return NativeArray.borrow(arrayType.next, header.ptr, header.length);
    }
}

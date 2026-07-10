module quickbite.backends.interpreter.native_array;


private:


// A D dynamic array's runtime representation is `{ size_t length; T* ptr; }`
// -- length at offset 0, pointer at offset `size_t.sizeof`. This assert only
// guards the total header size, `2 * size_t.sizeof`; it says nothing about
// field order. The order is pinned separately, at runtime, by the
// `writeSliceHeader` reinterpret tests in
// tests/ut/backends/interpreter/native_array.d, which write a header and
// read it back as a real `int[]` against the host compiler's own slice
// layout.
static assert((void[]).sizeof == 2 * size_t.sizeof);


// The array-native block handle skeleton (ai/plans/value.md item 7's
// "Next PR"): an interpreter-owned array value carrying a stable block, the
// DMD element type, length, and stride. `allocate` picks the block's GC scan
// policy from whether the element type carries pointers; there is no
// separate root-registration token or lifecycle to track (see
// `NativeBlock.Scan` and ai/plans/value.md's "GC roots" note).
public struct NativeArray {
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.native_struct: NativeStruct;
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
    // `nothrow`: `typeByteSize` throws on an unsized type, and an
    // overflowing `length * stride` throws rather than silently wrapping
    // to a too-small block underneath a handle that still claims `length`.
    public static NativeArray allocate(
        Type elementType,
        in size_t length,
    ) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;

        const stride = typeByteSize(elementType);
        const scan = typeHasPointers(elementType)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no;
        return NativeArray(
            NativeBlock.allocate(byteLength(length, stride), scan),
            elementType,
            length,
            stride,
        );
    }

    // Wraps memory owned elsewhere -- an interpreter-owned array value over
    // caller-supplied storage (later: FFI/host memory) -- computing
    // `stride` from `elementType` exactly as `allocate` does, and reusing
    // the same overflow-checked `byteLength` for the borrowed byte span.
    //
    // Precondition (caller-enforced, unverifiable here): `ptr` points to at
    // least `length * stride` valid, live bytes that outlive every handle
    // derived from this array. This is a raw-memory constructor -- it
    // fabricates a slice from a caller-supplied pointer/length it cannot
    // itself verify -- and so cannot be `@safe`; the FFI seam that
    // supplies `ptr` is the `@trusted` boundary that vouches for the
    // precondition, exactly as for `NativeBlock.borrow`.
    public static NativeArray borrow(
        Type elementType,
        void* ptr,
        in size_t length,
    ) @system {
        import quickbite.backends.interpreter.layout: typeByteSize;

        const stride = typeByteSize(elementType);
        return NativeArray(
            NativeBlock.borrow(ptr, byteLength(length, stride)),
            elementType,
            length,
            stride,
        );
    }

    // Adopts an existing block rather than allocating a new one -- a
    // static-array-typed struct field's bytes are already storage (a
    // `NativeBlock.subRange` of the enclosing struct's own block); this
    // views them as an array without copying or allocating a byte.
    // `length` comes from the caller (`layout.staticArrayLength` for a
    // static-array field) since a bare `NativeBlock` carries bytes, not a D
    // array length; `stride` is still computed from `elementType`, exactly
    // as `allocate`/`borrow` do, so it never becomes a second, driftable
    // copy of DMD's own element size.
    //
    // Unlike `allocate`/`borrow`, `block` already exists at a fixed byte
    // length that `adopt` did not choose, so a caller-supplied `length`
    // that does not actually fit `block` must be rejected here rather than
    // silently accepted: `element`'s own wrap-free bounds-check argument
    // rests on `length * stride` never having been allowed to outrun the
    // block's real bytes in the first place (see `element`'s comment).
    // Reuses the same overflow-checked `byteLength` helper `allocate`/
    // `borrow` already route through, so an overflowing `length * stride`
    // is rejected the same way there; a non-overflowing but too-large
    // product is rejected by the explicit comparison below.
    public static NativeArray adopt(
        NativeBlock block,
        Type elementType,
        in size_t length,
    ) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize;

        const stride = typeByteSize(elementType);
        const bytes = byteLength(length, stride);
        if (bytes > block.byteLength)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "adopt: length * stride does not fit within block's byteLength",
            );

        return NativeArray(block, elementType, length, stride);
    }

    public inout(Type) elementType() inout pure nothrow @nogc @safe {
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

    public NativeBlock.Scan scan() const pure nothrow @nogc @safe {
        return _block.scan;
    }

    public inout(NativeBlock) block() inout pure nothrow @nogc @safe {
        return _block;
    }

    // The bytes of element `index`: an interior view into the block at
    // `index * stride .. (index + 1) * stride`. `index` is checked against
    // `_length` first, and only then multiplied by `_stride`: every
    // construction path (`allocate`, `borrow`, `adopt`) already routes
    // `_length * _stride` through the overflow-checked `byteLength` helper,
    // so once `index < _length` holds, `index * _stride < _length *
    // _stride` is provably wrap-free too -- there is no need for a second
    // overflow check on the multiply itself.
    // Without the bounds check first, a large enough `index` makes
    // `index * _stride` wrap and land inside the block, silently aliasing
    // a different element instead of failing.
    public inout(ubyte)[] element(in size_t index) inout pure @safe {
        if (index >= _length)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "element: index out of range",
            );

        const start = index * _stride;
        return _block.bytes[start .. start + _stride];
    }

    // A sub-range view over elements `[begin, end)` -- the handle-level
    // expression of a guest `xs[1 .. 3]` -- aliasing the SAME element block
    // at `begin * stride`, never a copy: a write through the returned
    // handle is visible through this array and vice versa, for as long as
    // both stay live.
    //
    // Routes through `NativeBlock.subRange` rather than `NativeBlock.
    // borrow`/a raw pointer: `begin`/`end` are checked below against this
    // array's own already-verified `_length`, and slicing an interior byte
    // range of an already-verified block is ordinary bounds-checked D --
    // exactly `subRange`'s own "nested aggregate field" argument (see its
    // comment), applied here to a sub-range of elements instead of a
    // sub-range of struct fields. That is why this stays `@safe`, unlike
    // `NativeStruct.sliceField`'s reconstruction of a handle from a raw
    // pointer read back out of memory, which cannot be verified the same
    // way.
    //
    // Bounds: `begin <= end <= length`, each its own thrown `Exception`,
    // checked before either is multiplied by `_stride`. No separate
    // overflow check is needed on `begin * stride`/`end * stride`
    // themselves: every construction path (`allocate`, `borrow`, `adopt`)
    // already routes `length * stride` through the overflow-checked
    // `byteLength` helper, so once `end <= _length` holds, `end * _stride
    // <= _length * _stride` is provably wrap-free -- exactly `element`'s own
    // argument (see its comment) -- and `begin <= end` then makes `begin *
    // _stride <= end * _stride` wrap-free too, since it is bounded by the
    // same already-wrap-free product.
    //
    // The returned array is `Ownership.borrowed` -- via `NativeArray.adopt`
    // over `NativeBlock.subRange`'s own `borrowed` block, per this
    // function's own instructions to build the handle that way rather than
    // by hand -- so `reserve` on it throws and `capacity` is 0, exactly as
    // for any other borrowed array. That is the honest answer today: a
    // sub-range is not an independent allocation, so it has nothing of its
    // own to grow. What this deliberately does NOT model: compiled D lets
    // you append to a slice (`xs[1 .. 3] ~= x`), which reallocates a NEW
    // block for the RESULT rather than growing `xs` in place, and does not
    // disturb `xs` at all. That guest-level `~=` semantics is a question
    // for whatever interpreter call site eventually evaluates `~=` on a
    // `NativeArray` handle -- build a fresh owned array and rebind the
    // guest variable to it, exactly as compiled D does -- not for this
    // container: `reserve` throwing on a borrowed handle is the correct
    // low-level primitive regardless of what a higher-level guest operation
    // later decides to do about it. There is no such call site yet (see
    // ai/plans/value.md item 7).
    //
    // `begin == end` (including `begin == end == length`, D's legal `xs[$
    // .. $]`) is legal and returns a real zero-length array; `scan` is
    // carried forward from this array's own block by `subRange` unchanged,
    // exactly as for any other sub-range, so it is not re-derived here.
    // Its block's address is NOT null the way a zero-length *allocated*
    // array's is (`NativeBlock.allocate`/`NativeArray.allocate` route
    // through `GC.calloc(0, ...)`, which returns `null`): `subRange` slices
    // `_bytes`, so a zero-length sub-range's address is `begin * stride`
    // bytes past this array's own base -- for `begin == length`, a
    // past-the-end pointer, still a valid (if unused) address inside or
    // just past the parent's real GC allocation. Whether `core.memory.GC.
    // addrOf` of that address resolves as GC-visible (the fact `
    // writeSliceHeader`'s scanned-destination check asks, should some later
    // caller pass this handle to it) is not a fixed answer: `addrOf`
    // resolves an interior pointer to its allocation's base, so it depends
    // on how much slack the GC's bin rounding left past the block's own
    // live bytes past `begin` -- measured directly against druntime (not
    // assumed): a 3-`int32` block's 12 live bytes round up to a 16-byte
    // bin, leaving 4 bytes of slack, so `GC.addrOf` of THAT block's
    // past-the-end pointer resolves non-null, to the same base address; a
    // block whose live bytes exactly fill its bin (e.g. exactly 16, 32, ...
    // bytes) would answer differently. `slice` itself never asks this
    // question -- it only calls `subRange`/`adopt`, neither of which
    // touches `GC.addrOf` -- so this is not a decision `slice` makes, only
    // a fact worth pinning rather than assuming for whichever caller later
    // passes the resulting handle onward; see `NativeArray.slice.
    // emptyEndSliceBlockAddressResolvesToParentBaseUnderCurrentBinSlack`
    // for the actual measured answer at this file's fixture size.
    public NativeArray slice(in size_t begin, in size_t end) @safe {
        // A strideless handle (`NativeArray.init`, `_stride == 0`) gets a
        // guard of its own, checked first -- the same reachable hole
        // `reserve`/`setLength` already close (see `reserve`'s comment for
        // the ordering rationale this mirrors): without it, `slice(0, 0)`
        // passes both checks below trivially (`begin == end == _length ==
        // 0`), `_block.subRange(0, 0)` succeeds on the null block, and
        // `NativeArray.adopt` below then calls `typeByteSize(_elementType)`
        // with `_elementType is null` -- a null `Type` dereference that
        // segfaults instead of throwing. A handle with no element type is
        // not a properly constructed array, a more fundamental defect than
        // any question of what range it is being asked to slice, so this is
        // checked ahead of -- and unconditionally of -- `begin`/`end`
        // themselves.
        if (_stride == 0)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "slice: element stride is zero, so the array cannot be "
                ~ "sliced",
            );

        if (begin > end)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "slice: begin > end",
            );

        if (end > _length)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "slice: end > length",
            );

        const count = end - begin;
        return NativeArray.adopt(
            _block.subRange(begin * _stride, count * _stride), _elementType, count);
    }

    // Views element `index` -- an array whose `elementType` is a struct --
    // as its own `NativeStruct`, sharing this array's own block rather than
    // copying it: an element of an array is not an independent allocation,
    // it is a `NativeBlock.subRange` of this array's block at `index *
    // stride`, laid out with the element type's own field offsets relative
    // to that sub-range, not to the array's base. A write through the
    // returned handle is visible in this array's `element(index)` bytes and
    // vice versa, for as long as both stay live -- the same aliasing
    // discipline `NativeStruct.structField` already established for a
    // struct-typed struct field, applied here to a struct-typed array
    // element.
    //
    // `index` is bounds-checked against `_length` first, before any offset
    // arithmetic runs on it, matching `element`'s own discipline above --
    // and reusing its wrap-free argument rather than re-deriving one: every
    // construction path already routes `length * stride` through the
    // overflow-checked `byteLength` helper, so once `index < _length`
    // holds, `index * _stride` is provably wrap-free (see `element`'s own
    // comment). A field whose `elementType` is not a struct
    // (`Type.isTypeStruct` returns null) throws its own message before the
    // sub-range is ever taken, since `NativeStruct.adopt`'s own layout
    // machinery would be meaningless applied to the wrong DMD type.
    //
    // Routes through `NativeBlock.subRange` -- never the `@system`
    // raw-pointer `NativeBlock.borrow` path -- for exactly `slice`'s own
    // reason (see its comment): `index * stride .. index * stride +
    // stride` is a sub-range of an already-verified block, ordinary
    // bounds-checked D, not a pointer this code would need to reconstruct
    // and cannot itself verify. The handle itself is built with
    // `NativeStruct.adopt` over that sub-range, which re-derives
    // `typeByteSize(elementType)` and re-checks it fits, rather than
    // constructed by hand.
    //
    // The element's stride is `typeByteSize(elementType)` -- DMD's own
    // `structsize`, padding included, computed once at construction and
    // reused here as `_stride` rather than recomputed -- which is exactly
    // why `index * stride` lands on a correctly-aligned, correctly-sized
    // struct element and why D packs an array of structs back-to-back with
    // no inter-element padding beyond each element's own `structsize`
    // (verified against the host compiler: a `Point[3]`'s element 1 sits at
    // exactly `Point.sizeof` bytes past element 0, pinned by this file's
    // `structElement.fieldOffsetsAreRelativeToTheElementNotTheArrayBase`
    // test below).
    //
    // The returned `NativeStruct` is `Ownership.borrowed`, via `adopt`'s
    // own `NativeBlock.subRange`-backed construction: an array element is
    // not an independent allocation, so its `block.trueByteSize` is 0 and
    // nothing about it can be grown -- correct, since growing "one element"
    // in place is not a meaningful operation; growing the ARRAY is
    // `NativeArray.reserve`/`setLength`'s job, not this view's. `scan` is
    // carried forward from this array's own block by `subRange` unchanged,
    // exactly as for `slice`/`NativeStruct.structField` -- `Scan` is an
    // attribute of the whole underlying GC allocation, not of any one
    // element's view into it, so an element view has no legitimate way to
    // disagree with its parent about it.
    public NativeStruct structElement(in size_t index) @safe {
        if (index >= _length)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "structElement: index out of range",
            );

        auto structType = _elementType.isTypeStruct;
        if (structType is null)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "structElement: elementType is not a struct",
            );

        const start = index * _stride;
        return NativeStruct.adopt(_block.subRange(start, _stride), structType);
    }

    // Views element `index` -- an array whose `elementType` is itself a
    // static array (DMD's `TypeSArray`, e.g. `int[3]`, making this array
    // `int[3][4]`) -- as its own `NativeArray` over the SAME inline bytes:
    // this element's bytes ARE the nested array's storage, `stride` bytes at
    // `index * stride` inside this array's own block, not a slice header
    // pointing elsewhere. This is `structElement`'s own argument (see its
    // comment) applied to a static-array-typed element instead of a
    // struct-typed one -- a write through the returned handle is visible in
    // this array's `element(index)` bytes and vice versa, for as long as
    // both stay live.
    //
    // `index` is bounds-checked against `_length` first, before any offset
    // arithmetic runs on it, reusing `element`'s own wrap-free argument
    // rather than re-deriving one (see `element`'s comment). An
    // `elementType` that is not a static array (`Type.isTypeSArray` returns
    // null) throws its own message before the sub-range is ever taken,
    // since `layout.staticArrayLength`/`NativeArray.adopt`'s own layout
    // machinery would be meaningless applied to the wrong DMD type.
    //
    // Routes through `NativeBlock.subRange` -- never the `@system`
    // raw-pointer `NativeBlock.borrow` path -- for exactly `structElement`'s
    // own reason: `index * stride .. index * stride + stride` is a
    // sub-range of an already-verified block, ordinary bounds-checked D, not
    // a pointer this code would need to reconstruct and cannot itself
    // verify. That is why this stays `@safe`, unlike `sliceElement` below.
    // The handle itself is built with `NativeArray.adopt` over that
    // sub-range, `length` from `layout.staticArrayLength(elementType)`
    // (DMD's own element count for the nested static-array type -- a bare
    // `NativeBlock` carries bytes, not a D array length) and the nested
    // array's own element type from `elementType.next`, rather than
    // constructed by hand.
    //
    // The returned `NativeArray` is `Ownership.borrowed`, via `adopt`'s own
    // `NativeBlock.subRange`-backed construction: an array element is not an
    // independent allocation, so its `block.trueByteSize` is 0 and nothing
    // about it can be grown -- growing the OUTER array is `reserve`/
    // `setLength`'s job, not this view's. `scan` is carried forward from
    // this array's own block by `subRange` unchanged, exactly as for
    // `structElement`/`slice` -- `Scan` is an attribute of the whole
    // underlying GC allocation, not of any one element's view into it.
    public NativeArray arrayElement(in size_t index) @safe {
        import quickbite.backends.interpreter.layout: staticArrayLength;

        if (index >= _length)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "arrayElement: index out of range",
            );

        auto arrayType = _elementType.isTypeSArray;
        if (arrayType is null)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "arrayElement: elementType is not a static array",
            );

        const start = index * _stride;
        const length = staticArrayLength(arrayType);
        return NativeArray.adopt(_block.subRange(start, _stride), arrayType.next, length);
    }

    // Views element `index` -- an array whose `elementType` is a dynamic
    // array (DMD's `TypeDArray`, e.g. `int[]`, making this array `int[][]`)
    // -- as a `NativeArray` over the element block its stored slice header
    // currently points at. Unlike `arrayElement` above, this element's
    // bytes are NOT the nested array's storage: they ARE a slice header
    // (`{ length, ptr }`) naming a separately tracked block somewhere else
    // entirely (wherever `writeSliceHeader` last wrote it from), exactly
    // `NativeStruct.sliceField`'s own situation (see its comment) applied to
    // an array element's bytes instead of a struct field's. The only way to
    // view "the elements this slot currently points at" is to read that
    // header back out of memory and reconstruct a handle from it via
    // `NativeArray.borrow`, under the same caller-enforced, unverifiable
    // precondition `borrow`/`sliceField` already document -- here, vouched
    // for by whoever last wrote a valid header into this element. That
    // unverifiable reconstruction from a pointer read out of memory, rather
    // than a sub-range of an already-verified block, is why this is
    // `@system`, unlike `arrayElement`/`structElement` above.
    //
    // `index` is bounds-checked against `_length` first, reusing `element`'s
    // own wrap-free argument rather than re-deriving one, and before any
    // header bytes are read. An `elementType` that is not a dynamic array
    // (`Type.isTypeDArray` returns null) throws its own message before any
    // of that, since `TypeDArray.next` would be meaningless applied to the
    // wrong DMD type.
    //
    // Reuses `readSliceHeaderBytes` -- the exact same header-reading helper
    // `NativeStruct.sliceField` uses, moved here alongside
    // `sliceHeaderByteLength`/`writeSliceHeaderBytes`, the other two pieces
    // of this module's own slice-header layout -- rather than a second
    // `memcpy` of the same two fields.
    //
    // The contract for the read-back header, ownership, and scan is
    // identical to `sliceField`'s own (see its comment in full): a
    // zero-length/null header reads back as a real, empty `NativeArray`;
    // the returned array's `ownership` is always `borrowed` (this element
    // does not own the pointed-to block, only names it) and its `scan`/
    // `capacity` are `Scan.no`/`0` unconditionally, per `NativeBlock.
    // borrow`'s own contract, even when the pointed-to block is a real,
    // conservatively-scanned GC allocation this same element keeps alive;
    // and this aliases, not snapshots -- the returned handle wraps the SAME
    // address `writeSliceHeader` wrote, so a write through it is visible
    // through any other handle over the same block, and it goes stale
    // exactly as any other stale pointer once this element's header is
    // overwritten or the pointed-to block moves.
    public NativeArray sliceElement(in size_t index) @system {
        if (index >= _length)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "sliceElement: index out of range",
            );

        auto arrayType = _elementType.isTypeDArray;
        if (arrayType is null)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "sliceElement: elementType is not a dynamic array",
            );

        const start = index * _stride;
        auto header = readSliceHeaderBytes(_block.bytes[start .. start + sliceHeaderByteLength]);

        return NativeArray.borrow(arrayType.next, header.ptr, header.length);
    }

    // The byte length of a D dynamic-array slice header (`{ length, ptr }`):
    // how many bytes `writeSliceHeader` writes at its `byteOffset` into a
    // destination block, which need not be exactly this many bytes itself
    // -- the destination is often a field inside a larger block.
    public enum size_t sliceHeaderByteLength = (void[]).sizeof;

    // Writes this array's slice header -- `{ length, ptr }` -- into `dest`
    // at `byteOffset`, the storage location of the guest's `T[]` variable
    // (the destination aliases the element block; it is not a snapshot).
    // The destination is a `(NativeBlock, byteOffset)` pair rather than a
    // bare `ubyte[]` because a slice header's real destination is often a
    // *field* inside a larger block -- a struct's `T[]` field -- not the
    // whole block; `dest` being self-describing is also what makes the
    // second invariant below checkable at all, which a bare `ubyte[]`
    // could never answer.
    //
    // Two invariants are enforced, each its own thrown `Exception`:
    //
    // 1. Bounds. `byteOffset + sliceHeaderByteLength` must fit within
    //    `dest.byteLength`, computed with `core.checkedint.addu` rather
    //    than a plain `+` -- `byteOffset` is caller-supplied, and a value
    //    near `size_t.max` could otherwise wrap the sum back into range
    //    and pass a bounds check it should fail.
    //
    // 2. Scanned destination. Writing this array's block address into a
    //    destination the GC never scans (`Scan.no`) would make the element
    //    block invisible to the collector, which could then free it while
    //    the guest's `T[]` variable still points at it -- exactly the
    //    hazard `NativeBlock.Scan` exists to avoid for the block itself.
    //
    //    This is keyed on whether this array's block address is
    //    *GC-visible* -- a mechanical fact read directly from
    //    `core.memory.GC.addrOf`, which returns non-null for
    //    a pointer into any GC allocation, INCLUDING an interior pointer
    //    into a larger one (it returns that allocation's base address) --
    //    never from this array's `NativeBlock.Ownership`. Ownership
    //    answers a different question ("may this block legitimately be
    //    reallocated/extended?"), not "is this address one the GC can
    //    lose track of?". Those two questions used to have the same
    //    answer, because the only way to get a `borrowed` block was
    //    `NativeBlock.borrow`, wrapping genuinely non-GC (FFI/host)
    //    memory. `NativeBlock.subRange` broke that coincidence: a
    //    sub-range is `borrowed` (it cannot be grown/reallocated
    //    independently of its parent) but its address can very well be
    //    live GC memory -- e.g. `NativeStruct.arrayField`'s view of a
    //    struct's own inline array field. Keying this check on ownership
    //    would let such a sub-range's address be written into an unscanned
    //    destination and silently escape the collector's view, which is
    //    exactly the hazard this check exists to prevent. So this throws
    //    exactly when `GC.addrOf(_block.address) !is null` and
    //    `dest.scan != Scan.conservative`. One case stays legal despite a
    //    `Scan.no` destination:
    //      - A zero-length array's block address is `null`
    //        (`GC.calloc(0, ...)` returns `null`, and `GC.addrOf(null)` is
    //        also `null` per its own contract); writing a null pointer
    //        into an unscanned destination loses nothing, since there is
    //        nothing there for the GC to lose track of.
    //    Genuinely non-GC memory -- `malloc`'d, FFI, or any other memory a
    //    `borrowed` block wraps that was never a GC allocation in the
    //    first place -- also reports `GC.addrOf(...) is null`, so it stays
    //    legal for exactly the reason the old ownership-keyed exemption
    //    was actually written for: keeping that memory alive is the
    //    borrower/owner's job (`NativeBlock.borrow`'s own contract), not
    //    this destination's scan policy's.
    //
    // The written `ptr` is the element block's address; the written
    // `length` is the element count, not a byte length.
    public void writeSliceHeader(NativeBlock dest, in size_t byteOffset) const @safe {
        import core.checkedint: addu;
        import core.memory: GC;

        bool overflow;
        const end = addu(byteOffset, sliceHeaderByteLength, overflow);
        if (overflow || end > dest.byteLength)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "writeSliceHeader: byteOffset + sliceHeaderByteLength "
                ~ "does not fit within dest.byteLength",
            );

        if (GC.addrOf(_block.address) !is null
            && dest.scan != NativeBlock.Scan.conservative)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "writeSliceHeader: dest is not scanned by the GC, but "
                ~ "this array's block address is a live GC pointer",
            );

        writeSliceHeaderBytes(dest.bytes[byteOffset .. end], _length, _block.address);
    }

    // How many `_stride`-sized elements the block's true GC allocation
    // could hold, derived from `NativeBlock.trueByteSize` rather than
    // stored -- the GC already knows this fact, so a separate `_capacity`
    // field would be a second, driftable copy of it (item 7's guardrail).
    // For an owned array this is `>= length` (the GC's bin size rounds up
    // from the requested `length * stride`); for a borrowed or
    // zero-length array `_block.trueByteSize` is 0, so this is 0 too --
    // unconditionally for `borrowed`, per `trueByteSize`'s own explicit
    // `Ownership` guard (not merely an interior-pointer side effect of
    // `GC.sizeOf`, which alone would still leak a zero-offset sub-range's
    // parent's true bin size here). `_stride == 0` is `NativeArray.init`'s
    // own case: a default-
    // constructed handle has no element type, hence no stride, hence no
    // capacity -- asking is not an error, mirroring `length` and `block`,
    // which are already `.init`-tolerant in exactly this way. Guard it
    // explicitly rather than dividing: `allocate` never produces a zero
    // stride, but nothing stops a bare `NativeArray.init` from existing
    // (an array field, `NativeArray[]` growth, ...), and dividing by a
    // zero stride there would be a hardware trap, not a thrown exception,
    // in a function that claims `@safe nothrow @nogc`.
    public size_t capacity() const nothrow @nogc @safe {
        return _stride == 0 ? 0 : _block.trueByteSize / _stride;
    }

    // Guarantees capacity for at least `n` elements, mirroring compiled D's
    // `arr.reserve(n)`. A no-op when `n <= capacity`: the block's address
    // and every existing element are untouched. Otherwise grows through
    // real storage via `growBlockTo` (below) -- trying first `NativeBlock.
    // tryExtendTo` to extend the existing GC allocation in place, that path
    // leaving the address unchanged; if extension fails, allocating a new
    // block of the required byte length with this array's own scan policy,
    // copying the live `length * stride` bytes across, and adopting the new
    // block, where the address legitimately changes. Per item 7's
    // Address-stability bullet, that is correct -- stale pointers into the
    // old block go stale exactly as compiled D loses append capacity on
    // reallocation, and no boxed/old-block value is ever copied back as the
    // authority. Both paths leave the SAME observable state: `block.
    // byteLength == n * stride` and every byte beyond the live `length *
    // stride` is zero -- `tryExtendTo` establishes that itself on the
    // extend path, and `NativeBlock.allocate`'s `GC.calloc` zeroes the
    // whole new block on the reallocating path, so an extended block is
    // indistinguishable from a freshly allocated one. A borrowed block
    // cannot legitimately be reallocated -- we don't own that memory, so
    // silently adopting a new block here would detach the handle from
    // memory its owner still holds, while that owner keeps reading and
    // writing the original address. Reaching the reallocating path with
    // `_block.ownership == borrowed` now throws instead (see `NativeArray.
    // borrow`).
    //
    // That guard sits after the `n <= capacity` no-op, not before it:
    // `reserve(0)`, like any `n` already within capacity, is a legitimate
    // no-op on any array -- borrowed or not -- exactly like compiled D's
    // `arr.reserve(n)`, which never touches storage it doesn't need to
    // grow. A borrowed block's `capacity` is always 0 -- unconditionally,
    // per `NativeBlock.trueByteSize`'s explicit `Ownership` guard (see
    // `capacity`'s comment) -- so that no-op is only reached for a
    // borrowed array when `n == 0`; any `n >= 1` falls through to the
    // borrowed guard, which is the right place for it, since only then is
    // a reallocation actually being requested. Not `nothrow`: `byteLength`
    // throws on overflow; not `@nogc`/`pure`: the reallocating path
    // allocates.
    //
    // A strideless handle (`NativeArray.init`, `_stride == 0`) gets a
    // guard of its own, checked first: `byteLength(n, 0)` never overflows
    // (`mulu` with a zero operand can't), so without this check `reserve`
    // would "grow" to 0 bytes, copy 0 live bytes, and return normally with
    // `capacity == 0 < n` -- silently violating its own documented
    // postcondition. Growing an array whose element stride is zero (so it
    // has no capacity to grow) is a programming error, not a no-op, so
    // this fails loudly instead, and it is checked ahead of the borrowed
    // guard: a strideless handle is not even a properly constructed array,
    // a more fundamental defect than an otherwise-valid borrowed one. In
    // practice the two never overlap on a reachable handle -- `borrow`
    // always computes a real, non-zero stride from `elementType`, exactly
    // as `allocate` does -- but the ordering still names which failure is
    // reported first should that ever change.
    public void reserve(in size_t n) @safe {
        if (_stride == 0)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "reserve: element stride is zero, so the array has no "
                ~ "capacity to grow",
            );

        if (n <= capacity)
            return;

        if (_block.ownership == NativeBlock.Ownership.borrowed)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "reserve: cannot reallocate a borrowed block; its memory "
                ~ "is owned elsewhere",
            );

        growBlockTo(byteLength(n, _stride));
    }

    // The shared tail of `reserve`'s and `setLength`'s own grow paths:
    // grows this array's block to span at least `requiredBytes`, trying
    // `NativeBlock.tryExtendTo` first (extend in place, address unchanged),
    // and falling back to a fresh, same-scan-policy allocation plus a copy
    // of the live `length * stride` bytes when extension fails -- see
    // `reserve`'s own comment for the address-stability and zeroing
    // argument this establishes; factored out here once `setLength` needed
    // the identical machinery under a DIFFERENT trigger condition than
    // `reserve`'s (see `setLength`'s own comment for why). Both callers
    // have already ruled out a borrowed block reaching here; neither calls
    // this on one.
    private void growBlockTo(in size_t requiredBytes) @safe {
        if (_block.tryExtendTo(requiredBytes))
            return;

        auto newBlock = NativeBlock.allocate(requiredBytes, _block.scan);
        const liveBytes = _length * _stride;
        newBlock.bytes[0 .. liveBytes] = _block.bytes[0 .. liveBytes];
        _block = newBlock;
    }

    // Resizes this array to `n` elements: the handle-level expression of a
    // guest `arr.length = n`. Checked against compiled D's own
    // `_d_arraysetlengthT`/`_d_arraysetlengthT_` (core/internal/array/
    // capacity.d, read from the local druntime source) rather than assumed.
    //
    // Shrink (`n <= _length`): only `_length` falls -- the block's address,
    // `capacity`, and every byte (including the ones now past the new
    // length) are untouched. This matches compiled D's own shrink path
    // exactly: `_d_arraysetlengthT_` does `if (newlength <= arr.length) {
    // arr = arr[0 .. newlength]; return newlength; }`, a pure slice
    // truncation with no GC call at all -- and it stays legal on a
    // `borrowed` handle, including a `NativeArray.slice` result: a pure
    // length change touches no storage, so there is no ownership question
    // to ask. It is also why compiled D's classic footgun -- `arr.length
    // --; arr ~= x;` silently overwriting what used to be the popped
    // element -- is real: `~=` (`core/internal/array/appending.d`'s
    // `_d_arrayappendcTX_`) can reuse that untouched tail in place via
    // `gc_expandArrayUsed`'s "used size" bookkeeping, with NO zeroing of
    // its own (the caller is about to fill the appended slot immediately)
    // -- unlike `setLength`'s own grow path below, which always zeroes.
    //
    // Grow (`n > _length`) on a `borrowed` handle throws unconditionally,
    // never touching storage -- a deliberate narrowing (review finding,
    // 2026-07-10) of an earlier version of this function, which instead
    // allowed growth within the handle's own already-verified `_block.
    // byteLength` (e.g. growing a shrunk `NativeArray.slice` back within
    // its original span). That version was unsound: because `slice` is a
    // real, bidirectional aliasing view, re-zeroing on such a regrowth was
    // visible through the PARENT too -- growing a shrunk CHILD slice
    // zeroed bytes the parent (or a sibling slice over the same block)
    // still considered live, which this function's own former test
    // demonstrated. It also directly contradicted `NativeArray.adopt`'s
    // (and `NativeStruct.adopt`'s) own documented promise that a block's
    // slack bytes beyond what a handle claims "are none of this factory's
    // business" -- growing into those slack bytes from a DIFFERENT handle
    // is exactly the factory's business being violated.
    //
    // This was checked against compiled D rather than assumed which
    // behaviour is actually correct: a guest `s.length = n` growing a
    // slice does NOT reuse the parent's storage in general.
    // `_d_arraysetlengthT_` reaches `gc_expandArrayUsed`, whose real
    // implementation, `expandArrayUsed` (`core/internal/gc/impl/
    // conservative/gc.d`, ~line 1491), only succeeds when the block's
    // already-stored allocation length matches the slice's own current
    // length -- an old-length comparison inside `__setArrayAllocLengthImpl`
    // (`core/internal/gc/blockmeta.d`). The sibling `reserveArrayCapacity`
    // (same file, ~line 1605, used by `reserve`'s own capacity query, not
    // `setLength`'s grow path) spells out the identical principle
    // explicitly as `existingUsed != blockUsed`. Either way: only the
    // block's current single tracked TAIL owner may extend in place; every
    // other live slice over the same block, including one that was just
    // shrunk, fails that check and gets a brand-new block instead, leaving
    // the original bytes -- and every other handle over them -- untouched.
    // Confirmed against a compiled probe: `a[1 .. 4]`
    // shrunk to length 1 then grown back to 3 gets a NEW address, and `a`
    // itself is unchanged. A `NativeArray` handle has no equivalent "am I
    // the current tail owner" bookkeeping, so it has no sound way to
    // decide which one of potentially several live borrowed views over the
    // same block is safe to grow into -- meaning no call site could ever
    // have legitimately used the old grow-within-byteLength branch anyway.
    // Growth-and-rebind of a borrowed handle is therefore a call-site
    // operation, never this container's, exactly as `slice`'s own comment
    // already says `~=` is -- there is no such call site yet.
    //
    // Grow on an OWNED handle is unaffected by the narrowing above -- an
    // owned handle's `_block` is its own real allocation, never shared
    // with another live view, so there is no other handle's bytes to put
    // at risk. Every byte from the OLD `_length * stride` up to the new
    // `n * stride` is zeroed, whether or not the block itself needed to
    // grow to hold them. This is NOT implied by `reserve`'s own zeroing:
    // `reserve` only zeroes bytes past whatever `_block.byteLength` was at
    // the moment it ran, and a shrink never touches `_block.byteLength` at
    // all -- so if this array was shrunk and is now growing back to (or
    // within) its old span, the bytes between the new `_length` and the
    // block's own already-live span are stale leftovers from before the
    // shrink, not fresh room `reserve` ever zeroed. Compiled D only
    // matches this for a zero-init element type: `_d_arraysetlengthT_`'s
    // own zeroing is gated, `static if (__traits(isZeroInit, T)) memset(
    // cast(void*)(cast(ubyte*)newdata + oldsize), 0, newsize - oldsize)`
    // (core/internal/array/capacity.d, local druntime source, ~line 338);
    // a non-zero-init `T` instead gets `T.init` emplaced into each new
    // element -- e.g. `char`'s `0xFF`, `float`'s `NaN` -- never a zero
    // byte. This function zeroes every new byte unconditionally regardless
    // of element type -- a defensible container-level choice matching
    // `NativeBlock.allocate`'s own calloc-zeroed model, but one that
    // agrees with compiled D only for zero-init element types, which is
    // every current fixture's element type; making a guest `char[]` grow
    // expose `0xFF` rather than `0`, to match `SystemLinker`, is left as
    // an open question for whatever future call site wires `setLength`
    // up, not this container's job. Confirmed against a compiled probe on
    // `int[]` (a zero-init element type, so it does not exercise the
    // non-zero-init gap above): shrinking `[1, 2, 3, 4, 5]` to length 2
    // then growing back to 5 reads back `[1, 2, 0, 0, 0]`, never the
    // original `3, 4, 5`.
    // `setLength.shrinkThenGrowBackRezeroesStaleBytesWithoutReallocating`
    // pins this for an owned array without reallocating (`_block.
    // byteLength` already covered the regrown span).
    //
    // Strideless (`NativeArray.init`, `_stride == 0`): mirrors `reserve`'s
    // own guard, in the same position -- checked first, unconditionally,
    // before even asking whether `n` would grow or shrink anything.
    // `reserve` throws even for `reserve(0)` on a strideless handle, for
    // the reason given there: a handle with no element type is not a
    // properly constructed array, a more fundamental defect than any
    // question of growing or shrinking it. `setLength(0)` on `NativeArray.
    // init` throws for the identical reason, even though `0 == _length`
    // would otherwise make it a trivial no-op.
    //
    // `n * stride` is computed with the existing overflow-checked
    // `byteLength` helper (`allocate`/`reserve`/`adopt`'s own), never
    // re-derived, and only inside the grow branch -- a shrink or no-op
    // never multiplies anything.
    //
    // What this does NOT do: update any slice header a prior
    // `writeSliceHeader` call already wrote from this array. A header is a
    // snapshot of `{ length, ptr }` taken at write time, not a live view of
    // this handle; once `setLength` reallocates, any previously written
    // header still names the OLD address and length, exactly as stale as
    // any other pointer into a moved block -- compiled D's own slices go
    // stale the same way once a variable's `.length` is reassigned out from
    // under an earlier alias. Keeping such a header in sync is the call
    // site's problem, the moment it rebinds the guest variable this array
    // backs, not this container's -- there is no such call site yet.
    public void setLength(in size_t n) @safe {
        if (_stride == 0)
            throw new Exception(
                "quickbite.backends.interpreter.native_array.NativeArray."
                ~ "setLength: element stride is zero, so the array cannot "
                ~ "be resized",
            );

        if (n > _length) {
            if (_block.ownership == NativeBlock.Ownership.borrowed)
                throw new Exception(
                    "quickbite.backends.interpreter.native_array."
                    ~ "NativeArray.setLength: cannot grow a borrowed "
                    ~ "array; SystemLinker reallocates a fresh block for a "
                    ~ "guest `s.length = n` on a slice rather than growing "
                    ~ "it in place, so growth-and-rebind belongs to the "
                    ~ "call site, not this container",
                );

            const requiredBytes = byteLength(n, _stride);

            if (requiredBytes > _block.byteLength)
                growBlockTo(requiredBytes);

            _block.bytes[_length * _stride .. requiredBytes] = 0;
        }

        _length = n;
    }
}

// `length * stride` computed with overflow checking: an overflowing
// product would otherwise wrap to a small byte count, and `NativeBlock.
// allocate` would then silently succeed with a block far too small for
// the handle's `length`. Throws rather than returning an inconsistent
// handle, matching `layout.typeByteSize`'s failure style. Called from
// `allocate`, `reserve`, and `adopt`, so the message names the operation
// (`length * stride`), not any one caller.
private size_t byteLength(in size_t length, in size_t stride) pure @safe {
    import core.checkedint: mulu;

    bool overflow;
    const bytes = mulu(length, stride, overflow);
    if (overflow)
        throw new Exception(
            "quickbite.backends.interpreter.native_array.NativeArray."
            ~ "byteLength: length * stride overflows size_t",
        );

    return bytes;
}

// Writing a raw pointer's bit pattern into a byte range is not @safe; this
// is the @trusted boundary. `memcpy` (rather than a pointer-typed store)
// avoids relying on `dest` being size_t-aligned, which a block's byte
// range at an arbitrary `byteOffset` is not guaranteed to be. The `in`
// contract below is stripped under `-release`, so this function's safety
// actually rests on its sole caller, `NativeArray.writeSliceHeader`, whose
// unconditional throws validate the destination's bounds and scan policy
// before calling here -- not on the contract.
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

// The two values a D dynamic-array slice header holds, read back out of a
// field's or an element's bytes rather than written -- the counterpart to
// `writeSliceHeaderBytes` above. `public`, not `private`: this is the read
// half of this module's own slice-header layout (alongside
// `sliceHeaderByteLength`/`writeSliceHeaderBytes`), shared by
// `NativeArray.sliceElement` above and `NativeStruct.sliceField`, which
// would otherwise need a second, driftable `memcpy` of the same two fields.
public struct SliceHeaderBytes {
    size_t length;
    void* ptr;
}

// Reads a slice header's bytes back as `{ length, ptr }` -- the exact
// layout `writeSliceHeaderBytes` writes (length at offset 0, pointer at
// offset `size_t.sizeof`; see this file's own `static assert` pinning
// `(void[]).sizeof == 2 * size_t.sizeof`). `memcpy`, not a pointer-typed
// load, for the same alignment reason `writeSliceHeaderBytes` gives: `src`
// is an interior view into a block at an arbitrary byte offset, not
// guaranteed to be `size_t`-aligned.
//
// This only copies two fixed-size values out of an already bounds-checked
// byte range into local storage -- it never dereferences `ptr`, so nothing
// here can violate memory safety no matter what bit pattern the bytes
// contain, PROVIDED `src` is actually `sliceHeaderByteLength` bytes long.
// That length is this function's own responsibility to enforce, not its
// caller's: unlike `writeSliceHeaderBytes` above (`private`, safety resting
// entirely on its sole caller's own prior checks), this function is
// `public` -- reachable from any `@safe` caller anywhere, not just its two
// known callers (`NativeArray.sliceElement`, `NativeStruct.sliceField`),
// which happen to always pass exactly the right length today. An `in`
// contract alone is not enough: contracts are stripped under `-release`, so
// a mismatched `src` would then `memcpy` `sliceHeaderByteLength` bytes out
// of a shorter slice's `ptr`, reading past its end -- exactly the
// `@trusted` boundary NOT actually holding that this fixes. The explicit
// throw below runs unconditionally, in every build mode, so the length
// this function's safety depends on is genuinely enforced rather than
// merely documented. That is this function's own `@trusted` boundary in
// full: reading exactly `sliceHeaderByteLength` bytes out of a range this
// function has itself just verified is that long is always safe; USING the
// resulting `ptr` to reconstruct a slice (`NativeArray.sliceElement`/
// `NativeStruct.sliceField`, via `NativeArray.borrow`) is where the real,
// unverifiable trust happens, which is why those callers -- not this
// helper -- are `@system`.
public SliceHeaderBytes readSliceHeaderBytes(in ubyte[] src) @trusted {
    import core.stdc.string: memcpy;

    if (src.length != NativeArray.sliceHeaderByteLength)
        throw new Exception(
            "quickbite.backends.interpreter.native_array."
            ~ "readSliceHeaderBytes: src.length does not match "
            ~ "sliceHeaderByteLength",
        );

    SliceHeaderBytes header;
    memcpy(&header.length, src.ptr, size_t.sizeof);
    memcpy(&header.ptr, src.ptr + size_t.sizeof, (void*).sizeof);
    return header;
}

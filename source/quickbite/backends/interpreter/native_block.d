module quickbite.backends.interpreter.native_block;


private:


// A stable byte range: an address that never moves while any handle can
// reach it. Owned blocks are GC memory the interpreter allocates; borrowed
// blocks wrap memory owned elsewhere (later: FFI/host memory) and write
// through to it. Copying a `NativeBlock` copies the handle, not the bytes:
// every copy sees the same stable address.
public struct NativeBlock {
    public enum Ownership {
        owned,
        borrowed,
    }

    // Whether the GC must scan this block's bytes for pointers on
    // collect. `no` is the common case (scalars, non-pointer aggregates);
    // a block whose element type carries pointers must allocate
    // `conservative`, or its targets become invisible to the GC and can be
    // collected while still reachable through this block.
    public enum Scan {
        no,
        conservative,
    }

    private ubyte[] _bytes;
    private Ownership _ownership;
    private Scan _scan;

    // Zero-initialised GC memory the interpreter owns, allocated with the
    // required scan policy. D's GC is non-moving, so the address is stable
    // for as long as any handle can reach it. There is no registration
    // token and no destruction hook: the scan policy is an allocation
    // attribute, chosen once and never revisited. No default: `no` is the
    // dangerous choice (an under-scanned block holding guest pointers is a
    // use-after-free once the GC can no longer see what it points to), so a
    // forgotten argument must not silently pick it. `Scan` over `bool`
    // because the call site reads as `Scan.conservative`/`Scan.no`, not an
    // unlabelled `true`/`false`.
    public static NativeBlock allocate(
        in size_t byteLength,
        in Scan scan,
    ) pure nothrow @safe {
        return NativeBlock(allocateBytes(byteLength, scan), Ownership.owned, scan);
    }

    // Wraps memory owned elsewhere. Allocates nothing; writes through
    // `bytes` reach the original memory.
    //
    // Precondition (caller-enforced, unverifiable here): `ptr` points to
    // at least `byteLength` valid, live bytes that outlive every handle
    // derived from this block. This is a raw-memory constructor and so
    // cannot be `@safe`; the FFI seam that supplies `ptr` is the
    // `@trusted` boundary that vouches for the precondition.
    //
    // Recorded scan policy is always `no`: this memory is not a D GC
    // allocation, so the GC never scans it regardless of what policy is
    // asked for -- there is no attribute to set. That makes a borrowed
    // block's bytes exactly as invisible to the collector as `malloc`'d C
    // memory: a GC-owned pointer written into them is unreachable as far
    // as the GC is concerned, and stays alive only if something else
    // (typically the borrowed memory's own owner) keeps it alive. Solving
    // that is the borrower's problem -- per the precondition above, not
    // something this block can fix by itself.
    public static NativeBlock borrow(void* ptr, in size_t byteLength) pure nothrow @system {
        return NativeBlock(borrowedBytes(ptr, byteLength), Ownership.borrowed, Scan.no);
    }

    public size_t byteLength() const pure nothrow @nogc @safe {
        return _bytes.length;
    }

    public Ownership ownership() const pure nothrow @nogc @safe {
        return _ownership;
    }

    public Scan scan() const pure nothrow @nogc @safe {
        return _scan;
    }

    // Read/write access to the block's bytes.
    public inout(ubyte)[] bytes() inout pure nothrow @nogc @safe {
        return _bytes;
    }

    // A raw pointer, produced only at this edge (FFI/intrinsics); never
    // the ownership token.
    public inout(void)* address() inout pure nothrow @nogc @safe {
        return blockAddress(_bytes);
    }

    // The true byte size of this block's underlying GC allocation, read
    // from `core.memory.GC.sizeOf` -- the GC's own bin size, not a size we
    // invent or cache ourselves (item 7's guardrail: layout facts stay the
    // GC/DMD's single source of truth, never a second copy of our own).
    // Per `GC.sizeOf`'s own doc comment (core/memory.d, ~line 721): memory
    // not allocated by this GC, the interior of a block, or a null
    // pointer, all honestly report 0. That makes this 0 for a *borrowed*
    // block (never GC memory) and for a *zero-length* block (its `address`
    // is null, since `GC.calloc(0, ...)` returns null) -- both are real,
    // expected zeros, not something to paper over. Not `pure`: the
    // `const scope void*` overload of `GC.sizeOf` used below (see
    // `trueByteSizeOf`) is itself not `pure` (druntime marks it
    // `/* FIXME pure */`); reaching the other, `pure`, `void*` overload
    // would need casting away `address`'s constness, which would fake a
    // purity this function doesn't have.
    public size_t trueByteSize() const nothrow @nogc @safe {
        return trueByteSizeOf(address);
    }

    // Tries to grow this block's allocation in place to `newByteLength`.
    // This only ever grows the block: a `newByteLength` that does not
    // exceed the current `byteLength` is not a growth request, so it
    // returns false without touching the block -- "I did not extend" is
    // the honest answer for a no-op request, and it keeps the subtraction
    // below (`newByteLength - oldByteLength`) provably wrap-free rather
    // than relying on the GC to refuse an absurd (wrapped) size. Beyond
    // that guard, returns false if the GC cannot extend it, in which case
    // the caller must reallocate. On success the block spans exactly
    // `newByteLength` bytes and the newly available tail is zeroed, so an
    // extended block is indistinguishable from a freshly allocated one of
    // the same size -- `GC.extend` itself leaves extension bytes
    // uninitialised. The block's scan attribute (`NO_SCAN` vs
    // conservative) needs no update: `GC.extend` grows the same
    // underlying allocation rather than creating a new one, so whatever
    // attribute was set at `allocate` time still applies. A null
    // `address` -- this block's own zero-length case, since
    // `GC.calloc(0, ...)` returns null -- simply makes the GC report
    // "cannot extend" (see `extendBlock`'s comment below), so this
    // returns false and the caller reallocates; no special-casing needed
    // here.
    public bool tryExtendTo(in size_t newByteLength) pure nothrow @safe {
        const oldByteLength = _bytes.length;
        if (newByteLength <= oldByteLength)
            return false;

        auto ptr = address;
        const extended = extendBlock(ptr, newByteLength - oldByteLength);
        if (extended == 0)
            return false;

        _bytes = resliceBytes(ptr, newByteLength);
        _bytes[oldByteLength .. $] = 0;
        return true;
    }
}

// Building a slice view over caller-owned memory needs raw pointer
// indexing. `borrow` is `@system`, so this needs no `@trusted`: it is
// already only reachable from `@system`/`@trusted` callers.
private ubyte[] borrowedBytes(void* ptr, in size_t byteLength) pure nothrow @system {
    return (cast(ubyte*) ptr)[0 .. byteLength];
}

// `GC.calloc` is not `@safe` (it returns an unbounded raw pointer); this is
// the `@trusted` boundary. `GC.calloc` zeroes the requested bytes (verified
// against the local druntime source, core/internal/gc/impl/conservative/
// gc.d: `calloc` memsets before returning) and `NO_SCAN` is set only for
// the no-scan policy, so a conservatively scanned block stays visible to
// the GC for exactly as long as it is reachable. `GC.calloc(0, ...)`
// returns `null`; slicing it `[0 .. 0]` is still a legal empty slice.
private ubyte[] allocateBytes(in size_t byteLength, in NativeBlock.Scan scan) pure nothrow @trusted {
    import core.memory: GC;

    const attributes = scan == NativeBlock.Scan.no ? GC.BlkAttr.NO_SCAN : GC.BlkAttr.NONE;
    auto ptr = cast(ubyte*) GC.calloc(byteLength, attributes);
    return ptr[0 .. byteLength];
}

// `.ptr` on a slice is rejected in `@safe` code (dmd flags the possible
// past-the-end pointer for an empty slice); contain that here.
private inout(void)* blockAddress(inout(ubyte)[] bytes) pure nothrow @nogc @trusted {
    return bytes.ptr;
}

// `GC.sizeOf` takes a raw, unbounded pointer; this is the @trusted
// boundary. Uses the `const scope void*` overload rather than the `pure`
// `void*` one: `NativeBlock.address` returns `inout(void)*`, which resolves
// to `const(void)*` from a `const` method, matching this parameter exactly
// with no cast needed.
private size_t trueByteSizeOf(const scope void* ptr) nothrow @nogc @trusted {
    import core.memory: GC;

    return GC.sizeOf(ptr);
}

// `GC.extend` takes a raw, unbounded pointer and is not `@safe`; this is
// the `@trusted` boundary. Passing `p == null` -- this block's own
// zero-length case, since `GC.calloc(0, ...)` returns null -- is exactly
// the precondition druntime documents: `p` is "a pointer to the root of a
// valid memory block or to null" (core/memory.d, ~line 610), and
// internally `findPool(null)` finds no pool and returns 0, so a null `p`
// just reports "cannot extend" rather than misbehaving. Returns the
// extended block's byte size, or zero if no extension occurred
// (core/memory.d, ~line 618).
private size_t extendBlock(void* p, in size_t extension) pure nothrow @trusted {
    import core.memory: GC;

    return GC.extend(p, extension, extension);
}

// Reinterpreting a raw pointer as a slice is not `@safe`; this is the
// `@trusted` boundary. Called only after `tryExtendTo`'s own guard has
// confirmed `newByteLength` is strictly greater than the block's prior
// byte length, and `extendBlock` has confirmed the GC extended the
// allocation at `ptr` to accommodate at least that many bytes (per
// `GC.extend`'s documented contract: it returns 0 or the extended size,
// never a size short of the requested minimum) -- so the slice this
// returns stays within that (now larger) allocation. Provable from
// `tryExtendTo`'s own guard and `GC.extend`'s contract alone; it does not
// rest on any allocator implementation detail (e.g. how a shrinking or
// no-op request happens to be rejected), because that case never reaches
// here at all.
private ubyte[] resliceBytes(void* ptr, in size_t newByteLength) pure nothrow @trusted {
    return (cast(ubyte*) ptr)[0 .. newByteLength];
}

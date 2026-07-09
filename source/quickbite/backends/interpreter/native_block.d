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
        return NativeBlock(allocateBytes(byteLength, scan), Ownership.owned);
    }

    // Wraps memory owned elsewhere. Allocates nothing; writes through
    // `bytes` reach the original memory.
    //
    // Precondition (caller-enforced, unverifiable here): `ptr` points to
    // at least `byteLength` valid, live bytes that outlive every handle
    // derived from this block. This is a raw-memory constructor and so
    // cannot be `@safe`; the FFI seam that supplies `ptr` is the
    // `@trusted` boundary that vouches for the precondition.
    public static NativeBlock borrow(void* ptr, in size_t byteLength) pure nothrow @system {
        return NativeBlock(borrowedBytes(ptr, byteLength), Ownership.borrowed);
    }

    public size_t byteLength() const pure nothrow @nogc @safe {
        return _bytes.length;
    }

    public Ownership ownership() const pure nothrow @nogc @safe {
        return _ownership;
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

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

    private ubyte[] _bytes;
    private Ownership _ownership;

    // Zero-initialised GC memory the interpreter owns. D's GC is
    // non-moving and a `ubyte[]` allocation is NO_SCAN, so the address is
    // stable for as long as any handle can reach it.
    public static NativeBlock allocate(in size_t byteLength) pure nothrow @safe {
        return NativeBlock(new ubyte[](byteLength), Ownership.owned);
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

// `.ptr` on a slice is rejected in `@safe` code (dmd flags the possible
// past-the-end pointer for an empty slice); contain that here.
private inout(void)* blockAddress(inout(ubyte)[] bytes) pure nothrow @nogc @trusted {
    return bytes.ptr;
}

module quickbite.backends.interpreter.scratch_array;

private:


// @trusted: callers pass the base slice of a GC allocation they exclusively
// own as lexical scratch. They call this only after every consumer has copied
// the scratch values into its durable result, and the slice is cleared before
// freeing so it cannot be reused through this owner.
public void releaseScratchArray(T)(ref T[] values) @trusted pure nothrow @nogc {
    import core.memory: GC;

    auto storage = values.ptr;
    values = null;
    GC.free(storage);
}

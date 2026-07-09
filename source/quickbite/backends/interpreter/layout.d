module quickbite.backends.interpreter.layout;


private:


// Layout facts read directly from DMD: byte size and whether a type carries
// pointers the GC must scan. This module computes none of these itself --
// every value returned is DMD's own number, verbatim. Per ai/plans/value.md
// item 7's guardrail: DMD-derived layout facts stay the source of truth; the
// interpreter must not grow a second set of D layout rules.

// The byte size DMD assigns to `type`. Throws if DMD reports `type` as
// unsized (DMD's `SIZE_INVALID` sentinel), e.g. `Type.terror`.
public size_t typeByteSize(imported!"dmd.mtype".Type type) @safe {
    return typeByteSizeImpl(type);
}

// `dmd.typesem.size` is not @safe/pure/nothrow; this is the @trusted
// boundary -- it only reads DMD's own computed size, no arithmetic of our
// own.
private size_t typeByteSizeImpl(imported!"dmd.mtype".Type type) @trusted {
    import dmd.mtype: SIZE_INVALID;
    import dmd.typesem: size;

    const bytes = type.size;
    if (bytes == SIZE_INVALID)
        throw new Exception(
            "quickbite.backends.interpreter.layout.typeByteSize: no size "
            ~ "for type",
        );

    return cast(size_t) bytes;
}


// Whether the GC must scan `type` for pointers.
public bool typeHasPointers(imported!"dmd.mtype".Type type) @safe {
    return typeHasPointersImpl(type);
}

// `dmd.typesem.hasPointers` is not @safe/pure/nothrow; this is the
// @trusted boundary.
private bool typeHasPointersImpl(imported!"dmd.mtype".Type type) @trusted {
    import dmd.typesem: hasPointers;

    return type.hasPointers;
}

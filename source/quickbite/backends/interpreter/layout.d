module quickbite.backends.interpreter.layout;


private:


// Layout facts read directly from DMD: byte size and whether a type carries
// pointers the GC must scan. This module computes none of these itself --
// every value returned is DMD's own number, verbatim, on a 64-bit host (see
// the `static assert` below). Per ai/plans/value.md item 7's guardrail:
// DMD-derived layout facts stay the source of truth; the interpreter must
// not grow a second set of D layout rules.

// `dmd.mtype.Type.size` returns `uinteger_t`, a `ulong` regardless of host
// width (`dmd.globals`). `typeByteSizeImpl` narrows that to `size_t`; on a
// 64-bit host the cast is a no-op, but on a 32-bit host it would silently
// truncate a DMD-reported size above 4 GiB. This assert turns that
// truncation into a build break instead of letting it happen silently,
// matching `native_array.d`'s slice-header `static assert` habit.
static assert(size_t.sizeof == 8,
    "layout.typeByteSize assumes a 64-bit host; DMD type sizes are 64-bit");

// The byte size DMD assigns to `type`. Throws if DMD reports `type` as
// unsized (DMD's `SIZE_INVALID` sentinel), e.g. `Type.terror`.
public size_t typeByteSize(imported!"dmd.mtype".Type type) @safe {
    return typeByteSizeImpl(type);
}

// `dmd.typesem.size` is not @safe/pure/nothrow; this is the @trusted
// boundary -- it only reads DMD's own computed size, no arithmetic of our
// own. The error path also trusts `Type.toChars` to return a
// NUL-terminated string from DMD's arena (DMD's `OutBuffer.extractChars`
// appends the terminator before returning); `fromStringz.idup` copies it
// into GC memory immediately, so nothing dangles.
private size_t typeByteSizeImpl(imported!"dmd.mtype".Type type) @trusted {
    import dmd.mtype: SIZE_INVALID;
    import dmd.typesem: size;
    import std.string: fromStringz;

    const bytes = type.size;
    if (bytes == SIZE_INVALID)
        throw new Exception(
            "quickbite.backends.interpreter.layout.typeByteSize: no size "
            ~ "for type `" ~ type.toChars.fromStringz.idup ~ "`",
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


// `type`'s fields, in declaration order, as DMD's own `VarDeclaration`s
// (`TypeStruct.sym.fields`, sliced to a plain array). Takes a `TypeStruct`
// rather than a `Type` so the type system -- not a runtime cast -- rejects
// a non-struct caller; `Type.isTypeStruct` narrows a bare `Type` for callers
// that only have one. Field offsets are only meaningful once DMD has laid
// the struct out -- before `determineSize`/`finalizeSize` runs, `sym.fields`
// can still be empty. `typeByteSize` already forces exactly that layout pass
// (`Type.size` on a `Tstruct` calls `aggregateDeclSize`, which calls
// `determineSize` -> `determineFields` + `finalizeSize`) and already throws
// on `SIZE_INVALID`, so calling it first reuses DMD's own layout logic
// instead of duplicating it. `TypeStruct` converts to `Type` implicitly, so
// this costs no cast.
public imported!"dmd.declaration".VarDeclaration[] structFields(
    imported!"dmd.mtype".TypeStruct type,
) @safe {
    typeByteSize(type);
    return type.sym.fields[];
}


// The byte offset DMD assigned `field` within its enclosing struct's block
// (`VarDeclaration.offset`), verbatim. Only meaningful once the enclosing
// struct has been laid out -- i.e. for a `field` obtained from
// `structFields`, which already forces that.
public uint fieldByteOffset(imported!"dmd.declaration".VarDeclaration field) @safe {
    return field.offset;
}

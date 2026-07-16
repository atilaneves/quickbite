module quickbite.backends.interpreter.layout;


private:


// Layout facts read directly from DMD: byte size and whether a type carries
// pointers the GC must scan. This module computes none of these itself --
// every value returned is DMD's own number, verbatim, on a 64-bit host (see
// the `static assert` below). DMD-derived layout facts stay the source of
// truth; the interpreter must not grow a second set of D layout rules.

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

// The returned slice is safe for a caller to cache past this call: once
// `typeByteSize` above forces layout, `sizeok == Sizeok.done` freezes
// `sym.fields` (`dsymbolsem.d`'s `determineSize`/`determineFields` both
// early-return on that state), and DMD never frees AST memory, so the
// slice's backing storage stays valid for the process lifetime. A future
// DMD that re-lays-out or appends fields after `sizeok` is done would
// invalidate a cache built on this.
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


// The element count DMD recorded for a static-array type (`TypeSArray.
// dim`), read via `dim.toUInteger` -- DMD's own authoritative source for
// "how many elements this static array type has", not re-derived from a
// byte-size division. `typeByteSize(type) / typeByteSize(type.next)` would
// give the same answer for every real static-array type (D packs array
// elements back-to-back with no inter-element padding), but that is an
// indirect derivation through two other DMD numbers plus an assumption
// about packing, whereas `dim` is the one field that IS the count --
// reading it directly keeps DMD as the single source of truth for this
// fact, the same way `fieldByteOffset` above reads `VarDeclaration.offset`
// directly rather than re-deriving it from anything else.
public size_t staticArrayLength(imported!"dmd.mtype".TypeSArray type) @safe {
    return staticArrayLengthImpl(type);
}

// `Expression.toUInteger` is not @safe/pure/nothrow; this is the @trusted
// boundary -- it only reads DMD's own already-computed integer constant
// for `dim` (a `TypeSArray`'s dimension is semantically analysed down to a
// constant by the time `structFields`/`typeByteSize` have forced layout),
// narrowing it with the same cast-only trust `typeByteSizeImpl` above
// applies to `Type.size`.
private size_t staticArrayLengthImpl(imported!"dmd.mtype".TypeSArray type) @trusted {
    return cast(size_t) type.dim.toUInteger;
}


// `class_`'s fields, in base-to-derived declaration order: walks
// `baseClass` from `class_` up to the root, then emits each level's own
// `fields` starting from the root and working back down, so a derived
// class's fields follow its base class's fields, matching the layout the
// interpreter's class `Value`s use. Unlike `structFields` above, this does
// NOT force layout first -- a class's `fields` are populated by semantic
// analysis (`dsymbolsem.d`) before the interpreter ever runs, so there is
// no `sizeok`-gated state to force here the way a struct's is.
public imported!"dmd.declaration".VarDeclaration[] classFields(
    imported!"dmd.dclass".ClassDeclaration class_,
) @safe pure nothrow {
    return classFieldsImpl(class_);
}

// `ClassDeclaration.baseClass` and appending to an `Array!VarDeclaration`
// via `~=` are not @safe (both walk raw DMD pointers); this is the
// @trusted boundary -- it only walks and copies DMD's own already-
// populated `fields` arrays, the same "read DMD's own state, no
// arithmetic of our own" trust the other `@trusted` impls above apply.
// Both calls happen to also be `pure`/`nothrow`, so those attributes
// carry through unlike the other impls above, which cannot claim them.
private imported!"dmd.declaration".VarDeclaration[] classFieldsImpl(
    imported!"dmd.dclass".ClassDeclaration class_,
) @trusted pure nothrow {
    imported!"dmd.dclass".ClassDeclaration[] classes;
    for (auto current = class_; current !is null; current = current.baseClass)
        classes ~= current;

    imported!"dmd.declaration".VarDeclaration[] fields;
    foreach_reverse (current; classes)
        foreach (field; current.fields)
            fields ~= field;

    return fields;
}

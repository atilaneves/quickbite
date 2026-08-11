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


// Whether DMD can report a byte size for `type` at all -- `false` for
// DMD's `SIZE_INVALID` sentinel (e.g. `Type.terror`), `true` otherwise.
// Callers that must skip an unsized type without treating an exception as
// control flow (`typeByteSize` throws on that same condition) check this
// first instead.
public bool typeIsSized(imported!"dmd.mtype".Type type) @safe {
    return typeIsSizedImpl(type);
}

// `dmd.typesem.size` is not @safe/pure/nothrow; this is the @trusted
// boundary -- it only reads DMD's own computed size, the same call
// `typeByteSizeImpl` above trusts, but compares it against the sentinel
// instead of throwing.
private bool typeIsSizedImpl(imported!"dmd.mtype".Type type) @trusted {
    import dmd.mtype: SIZE_INVALID;
    import dmd.typesem: size;

    return type.size != SIZE_INVALID;
}


// The alignment DMD assigns `type` (`Type.alignsize`), verbatim -- the
// same "DMD's own number, no arithmetic of our own" contract `typeByteSize`
// applies to `Type.size`.
public uint typeAlignment(imported!"dmd.mtype".Type type) @safe {
    return typeAlignmentImpl(type);
}

// `Type.alignsize` is not @safe/pure/nothrow (it forces layout for an
// aggregate type, same as `Type.size`); this is the @trusted boundary.
private uint typeAlignmentImpl(imported!"dmd.mtype".Type type) @trusted {
    return type.alignsize;
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


// `variable`'s declared type (`VarDeclaration.type`), verbatim.
public imported!"dmd.mtype".Type declaredType(
    imported!"dmd.declaration".VarDeclaration variable,
) @safe {
    return declaredTypeImpl(variable);
}

// `VarDeclaration.type` is a plain field read, but `VarDeclaration` (an
// `extern (C++)` class) is not itself `@safe`-annotated; this is the
// `@trusted` boundary for reading it.
private imported!"dmd.mtype".Type declaredTypeImpl(
    imported!"dmd.declaration".VarDeclaration variable,
) @trusted {
    return variable.type;
}


// `class_`'s fields, in base-to-derived declaration order: walks
// `baseClass` from `class_` up to the root, then emits each level's own
// `fields` starting from the root and working back down, so a derived
// class's fields follow its base class's fields, matching the layout the
// interpreter's native class bodies use. Unlike `structFields` above, this
// does NOT force layout first -- a class's `fields` are populated by semantic
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


// The byte size DMD assigns to `class_`'s own object layout -- the same
// "DMD's own number, no arithmetic of our own" contract `typeByteSize`
// applies to `Type.size`. Unlike summing `fieldByteOffset(field) +
// typeByteSize(field.type)` over `classFields`, this already includes the
// vtable pointer (and monitor) DMD lays down at the front of every class
// object -- a field-end sum omits that header and under-sizes the object.
//
// Read through DMD's own FORCING accessor (`dsymbolsem.size`, which routes
// an `AggregateDeclaration` through `determineSize`), never the bare
// `structsize` field, for the same reason `structFields` above calls
// `typeByteSize` before touching `sym.fields`: pre-`finalizeSize` state is
// real, and `structsize` reads 0 in it. Native class allocation uses this
// size directly, so a stale zero would make later `Place.field`
// composition write outside its block. Throws on DMD's `SIZE_INVALID`
// sentinel, exactly as
// `typeByteSize` does.
public size_t classInstanceByteSize(
    imported!"dmd.dclass".ClassDeclaration class_,
) @safe {
    return classInstanceByteSizeImpl(class_);
}

// `dmd.dsymbolsem.size` is not @safe/pure/nothrow; this is the `@trusted`
// boundary -- it only forces and reads DMD's own computed instance size, no
// arithmetic of our own, the same trust `typeByteSizeImpl` above gives
// `Type.size` (including for its error path's `toPrettyChars`, a
// NUL-terminated string from DMD's arena that `fromStringz.idup` copies into
// GC memory immediately).
private size_t classInstanceByteSizeImpl(
    imported!"dmd.dclass".ClassDeclaration class_,
) @trusted {
    import dmd.dsymbolsem: size;
    import dmd.location: Loc;
    import dmd.mtype: SIZE_INVALID;
    import std.string: fromStringz;

    const bytes = size(class_, Loc.initial);
    if (bytes == SIZE_INVALID)
        throw new Exception(
            "quickbite.backends.interpreter.layout.classInstanceByteSize: no "
            ~ "instance size for class `"
            ~ class_.toPrettyChars.fromStringz.idup ~ "`",
        );

    return cast(size_t) bytes;
}


// `field`'s own declared name (`VarDeclaration.ident`), verbatim.
public string fieldName(
    imported!"dmd.declaration".VarDeclaration field,
) @safe {
    return fieldNameImpl(field);
}

// `VarDeclaration.ident` is not @safe (an extern (C++) member); this is
// the trusted read-only DMD boundary.
private string fieldNameImpl(
    imported!"dmd.declaration".VarDeclaration field,
) @trusted {
    return field.ident is null ? "" : field.ident.toString.idup;
}


// The qualified name (`"E.b"`) DMD gives the member of enum `type` whose
// value equals `value`, or `null` when no member carries it -- the same
// qualification `value.md`'s Display format spec rule 5 requires ("E.b",
// never a bare "b"). Reads `TypeEnum.sym.members`/`EnumMember` directly,
// DMD's own enum member declarations, rather than re-deriving membership
// from anything else; a caller that gets `null` back renders the
// non-member `cast(E)N` form instead (this function does not, since that
// is a display decision, not a DMD fact).
//
// An enum whose base type is not integral answers `null` outright, decided
// here on DMD's own `TypeEnum.isIntegral` (which forces and consults the
// enum's `memtype`) rather than left to a caller. Comparing `value` against
// a non-integral member's own constant means asking DMD for that constant as
// an integer, and `Expression.toInteger` is not a query: for a member DMD
// cannot answer for -- a `StringExp`, an `ArrayLiteralExp`, a
// `StructLiteralExp` -- its base implementation EMITS an error ("integer
// constant expression expected") into DMD's global error state and returns
// 0. That would make a read mutate the compiler's own diagnostics, and would
// then match every such member against a `value` of 0, labelling it with a
// name it does not carry. A comparison this module cannot make honestly is
// one it declines.
public string enumMemberQualifiedName(
    imported!"dmd.mtype".TypeEnum type,
    in long value,
) @safe {
    return enumMemberQualifiedNameImpl(type, value);
}

// `EnumDeclaration.members` and `EnumMember.value`/`.ident` are not
// @safe/pure/nothrow -- an extern (C++) class's fields and methods, the
// same caveat `declaredTypeImpl` above gives for `VarDeclaration.type`;
// this is the @trusted boundary. It only walks DMD's own already-populated
// member list and reads each member's own already-computed constant value
// and identifier -- no arithmetic of our own, the same "read DMD's own
// state, no arithmetic of our own" trust `place_value.d`'s
// `structTypeNameImpl` gives for reading a struct's own name.
private string enumMemberQualifiedNameImpl(
    imported!"dmd.mtype".TypeEnum type,
    in long value,
) @trusted {
    import std.conv: text;

    if (type.sym is null || type.sym.members is null)
        return null;

    if (!type.isIntegral)
        return null;

    foreach (symbol; *type.sym.members) {
        auto member = symbol.isEnumMember;
        if (member is null)
            continue;

        if (cast(long) member.value.toInteger == value)
            return text(type.sym.ident.toString, ".", member.ident.toString);
    }

    return null;
}

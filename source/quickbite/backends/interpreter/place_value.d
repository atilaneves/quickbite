module quickbite.backends.interpreter.place_value;


private:


// Reconstructs the whole guest value at `place`, composing `Place.field`/
// `Place.index` down to scalar leaves rather than reading `place`'s bytes as
// one flat span: a native scalar type reads through `Place.loadScalar`
// directly; a non-union struct type recurses once per `layout.structFields`
// field, in declaration order; a static-array type recurses once per
// `layout.staticArrayLength` element; a slice (`Type.isTypeDArray`) reads its
// native `{ length, ptr }` header (`native_array.readSliceHeaderBytes`) and
// recurses once per element via `Place.index`, which already follows the
// header's stored `ptr` -- the read side of a slice's place-composed shape.
// A union is the SAME field-by-field recursion as a non-union struct
// (`structValueAt` below serves both), and needs no union-specific
// arithmetic to get that right: every member's `layout.fieldByteOffset` is
// already the union's own overlapping offset (0 for a top-level union's
// members, DMD's own flattened offsets for an anonymous union's), so
// composing each member independently through its OWN `Place.field` is
// already reinterpretation of the identical underlying bytes at each
// member's own type -- exactly what `SystemLinker` gives, with no
// reconciliation step to perform because there is nothing to reconcile:
// the bytes are simply read again, at a different type, per member. A
// class (`Type.isTypeClass`) is the odd one out: unlike every other case
// above, this place's own bytes are not the object's bytes, only a stored
// reference to them (`Place.deref` already documents this) -- so the class
// arm below composes the object's body through that reference rather than
// this place directly. Anything else -- pointer, `real` -- still has no
// place-composed shape: a pointer's elements live behind a stored address
// with no length to recurse over, and `real` is outside `native_scalar`'s
// codec (see its own header comment) -- so those throw rather than
// guessing at a byte interpretation.
public imported!"quickbite.lang".Value readValue(
    imported!"quickbite.backends.interpreter.place".Place place,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout:
        staticArrayLength, enumMemberQualifiedName;
    import quickbite.lang: Value;

    auto type = place.type;

    // An enum-typed place must come back tagged (`Value.enumValue`), not as
    // the plain integral `Value` `native_scalar.readScalar` returns for it
    // (it dispatches on the resolved base type, so an enum's own tagging is
    // invisible to that codec) -- checked before the `isNativeScalarType`
    // arm below, which would otherwise catch every enum type first since an
    // enum's base type is itself a native scalar. `place.loadScalar` reads
    // the underlying bits through that same codec; `layout.
    // enumMemberQualifiedName` is DMD's own answer for which member (if
    // any) owns those bits, qualified per `value.md`'s Display format spec
    // rule 5 ("E.b"); a value matching no member renders that same spec's
    // non-member form (`cast(E)N`) instead.
    auto enumType = type.isTypeEnum;
    if (enumType !is null) {
        const bits = place.loadScalar.asLong;
        const qualifiedName = enumMemberQualifiedName(enumType, bits);
        return Value.enumValue(
            qualifiedName.length != 0 ? qualifiedName : nonMemberEnumName(enumType, bits),
            bits,
        );
    }

    if (isNativeScalarType(type))
        return place.loadScalar;

    auto structType = nonUnionStructOf(type);
    if (structType !is null)
        return structValueAt(place, structType);

    auto unionType = unionStructOf(type);
    if (unionType !is null)
        return structValueAt(place, unionType);

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null) {
        Value[] elements;
        foreach (i; 0 .. staticArrayLength(arrayType))
            elements ~= readValue(place.index(i));

        return Value.arrayValue(elements);
    }

    auto sliceType = type.isTypeDArray;
    if (sliceType !is null) {
        import quickbite.backends.interpreter.native_array:
            NativeArray, readSliceHeaderBytes;

        auto header = readSliceHeaderBytes(
            sliceHeaderBytes(place.address, NativeArray.sliceHeaderByteLength));

        Value[] elements;
        foreach (i; 0 .. header.length)
            elements ~= readValue(place.index(i));

        return Value.arrayValue(elements);
    }

    auto classType = type.isTypeClass;
    if (classType !is null) {
        import quickbite.backends.interpreter.layout:
            classFields, classQualifiedName, classHierarchyNames, fieldName;

        // `place.deref` follows this place's own stored reference and keeps
        // the class type, giving a place at the object body's own address
        // (`place.d`'s own contract) -- a null reference (no object bound
        // yet) reads back as `Value.null_` rather than attempting to read
        // fields through a null address.
        auto bodyPlace = place.deref;
        if (bodyPlace.address is null)
            return Value.null_;

        string[] fieldNames;
        Value[] fields;
        foreach (field; classFields(classType.sym)) {
            fieldNames ~= fieldName(field);
            fields ~= readValue(bodyPlace.field(field));
        }

        // Identity IS the body's own address (`ai/plans/value.md` decision
        // 15): unlike the boxed walker's minted `classIdentity` counter,
        // native storage already has a stable, unique fact for "which
        // object is this" -- the address `object_table.ObjectTable` handed
        // out for it -- so there is nothing left to invent here.
        return Value.classValue(
            classQualifiedName(classType.sym),
            classHierarchyNames(classType.sym),
            fieldNames,
            fields,
            cast(size_t) bodyPlace.address,
        );
    }

    throw new Exception(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );
}


// The shared field-by-field composition `readValue` uses for BOTH a
// non-union struct and a union at `place`: read each of `structType`'s own
// `layout.structFields`, in declaration order, through its own `Place.
// field`. For a plain struct this reads non-overlapping bytes, one field
// each; for a union every field's `Place.field` lands at the SAME
// overlapping offset(s) (DMD's own fact, `value.md`'s Unions section), so
// this reads every member as its own reinterpretation of those identical
// bytes -- no union-specific arithmetic needed, because `Place.field`'s
// offset arithmetic already IS the aliasing truth. `readValue`'s recursion
// makes each field's own value tagged/typed correctly (an enum, a nested
// struct or union, ...), matching the boxed walker's own struct-shaped
// `Value` for a union (`impl.d`'s `withUnionFieldWrite`, which likewise
// stores a union's `Value` as `Value.structValue` with one entry per
// declared member, never a smaller "only the live member" shape).
private imported!"quickbite.lang".Value structValueAt(
    imported!"quickbite.backends.interpreter.place".Place place,
    imported!"dmd.mtype".TypeStruct structType,
) @safe {
    import quickbite.backends.interpreter.layout: structFields;
    import quickbite.lang: Value;

    Value[] fields;
    foreach (field; structFields(structType))
        fields ~= readValue(place.field(field));

    return Value.structValue(structTypeName(structType), fields);
}


// The inverse of `readValue`: writes `value`'s scalar leaves into `place`
// through the identical field-by-field/element-by-element composition --
// scalar leaves via `Place.storeScalar`, everything else unsupported for
// exactly the reasons `readValue`'s own comment gives, with one addition: a
// class-typed place stays refused here too, even though `readValue` now
// composes one. Reading a class only needs the reference this place already
// stores (`Place.deref` follows it); writing one would need to STORE a
// reference, and the only legal reference for a given object identity is
// the address `object_table.ObjectTable` handed out for it when the object
// was created -- knowledge this module has no access to, and should not
// guess at. That wiring (minting/looking up an identity's body address and
// storing it here) belongs to whichever later slice connects class locals
// to `impl.d`'s frame mirror, not to this place-composition layer. Writing
// an already-allocated body's OWN fields (once its address is known) is
// `writeClassBody` below, the write-side counterpart of `readValue`'s class
// arm. A union-typed place writes ONE member's bytes rather than recursing
// every field the way a non-union struct does -- see `writeUnionValue`'s
// own header comment for why, and for the limits of that choice.
public void writeValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    in imported!"quickbite.lang".Value value,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout: structFields, staticArrayLength;

    auto type = place.type;

    if (isNativeScalarType(type)) {
        place.storeScalar(value);
        return;
    }

    auto structType = nonUnionStructOf(type);
    if (structType !is null) {
        foreach (index, field; structFields(structType))
            writeValue(place.field(field), value.structFieldAt(index));
        return;
    }

    auto unionType = unionStructOf(type);
    if (unionType !is null) {
        writeUnionValue(place, unionType, value);
        return;
    }

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null) {
        foreach (i; 0 .. staticArrayLength(arrayType))
            writeValue(place.index(i), value[i]);
        return;
    }

    throw new Exception(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}


// `value` is `structValueAt`'s own shape for a union -- one entry per
// declared member, built by independently reinterpreting the SAME
// underlying bytes at each member's own type (`readValue`'s union arm), or
// (from the boxed walker) `impl.d`'s `withUnionFieldWrite`, which
// re-derives every sibling from the just-written member's bytes before
// this is ever reached. Either source already has every entry agreeing
// bit-for-bit as reinterpretations of one another, over each entry's own
// byte width -- there is no OTHER way to construct a union-shaped `Value`
// in this codebase. Writing every entry back, field by field, the way the
// non-union struct arm of `writeValue` does, would make the LAST declared
// member win regardless of which one the caller actually meant, and worse,
// a member narrower than a later sibling would leave that sibling's own
// trailing bytes as whatever was already at `place` rather than what
// `value` says they should be.
//
// The honest single-write semantics: write the WIDEST declared member's
// own bytes (`layout.typeByteSize`). A D union's own storage is exactly
// its widest member's size (plus any trailing padding no member ever
// reads), so writing the widest member in one shot covers the union's
// entire live extent -- every narrower sibling then reads back correctly
// by reinterpreting a subrange of those same bytes, with nothing left
// over to reconcile. This is exact, not approximate, given the
// bit-for-bit agreement above; ties are broken by picking the first
// declared member at the max width, an arbitrary but deterministic choice
// (agreement makes any tied member's own bytes identical to write).
//
// The one thing this does NOT attempt: a `value` whose entries were
// assembled to deliberately disagree has no well-defined union byte
// pattern in the first place -- compiled D has no such value, a union
// assignment is always one physical block of bytes -- so this picks ONE
// member's bytes and leaves every other entry in `value` unconsulted,
// rather than guessing at a reconciliation this module has no basis for.
private void writeUnionValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    imported!"dmd.mtype".TypeStruct unionType,
    in imported!"quickbite.lang".Value value,
) @safe {
    import quickbite.backends.interpreter.layout: structFields, declaredType, typeByteSize;

    auto fields = structFields(unionType);

    size_t widestIndex = 0;
    size_t widestSize = 0;
    foreach (index, field; fields) {
        const size = typeByteSize(declaredType(field));
        if (size > widestSize) {
            widestSize = size;
            widestIndex = index;
        }
    }

    writeValue(place.field(fields[widestIndex]), value.structFieldAt(widestIndex));
}


// Writes a boxed class `Value`'s fields into an already-allocated object
// body -- the write-side counterpart of `readValue`'s class arm, and the
// inverse of the same field composition: `bodyPlace` is a place AT the
// object body's own address, keeping the class type (the same shape
// `Place.deref` produces, and `object_table.ObjectTable.storageFor`'s
// address paired with `place.placeAt` gives directly), not a place holding
// a reference to it. There is no reference to store here -- unlike
// `writeValue`, which refuses a class-typed place because it would have to
// invent or look up that reference -- so this has no such gap: the body's
// own address is already `bodyPlace.address`, supplied by whoever called
// this (`object_table.ObjectTable`, eventually via `impl.d`'s wiring).
public void writeClassBody(
    imported!"quickbite.backends.interpreter.place".Place bodyPlace,
    in imported!"quickbite.lang".Value value,
) @safe {
    import quickbite.backends.interpreter.layout: classFields;

    auto classType = bodyPlace.type.isTypeClass;
    if (classType is null)
        throw new Exception(
            "quickbite.backends.interpreter.place_value.writeClassBody: "
            ~ "bodyPlace must be a class-typed place",
        );

    foreach (index, field; classFields(classType.sym))
        writeValue(bodyPlace.field(field), value.classFieldAt(index));
}


// Whether `type` is one `readValue`/`writeValue` compose down to scalar
// leaves without throwing: a native scalar; a non-union struct all of whose
// `layout.structFields` field types are themselves place-composable; a
// union all of whose declared members are themselves place-composable
// (`allFieldsComposable`, shared with the struct case immediately above --
// a union's own fields are exactly as composable as a struct's, since
// `readValue`/`writeValue`'s union arms recurse the identical per-field
// composition); or a static array whose element type (`.next`) is
// place-composable. Recurses the identical dispatch `readValue`/
// `writeValue` use (`isNativeScalarType`, `nonUnionStructOf`,
// `unionStructOf`, `isTypeSArray`) so this predicate can never drift from
// what those two actually accept -- false for a class, slice/dynamic array,
// pointer, or `real`, the same set their own header comment gives; a
// union with ANY such member (a slice, class, pointer, or `real` field)
// answers `false` for the WHOLE union, exactly like `isClassBodyComposable`
// declining a whole class body over one non-composable field.
public bool isPlaceComposable(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

    if (isNativeScalarType(type))
        return true;

    auto structType = nonUnionStructOf(type);
    if (structType !is null)
        return allFieldsComposable(structType);

    auto unionType = unionStructOf(type);
    if (unionType !is null)
        return allFieldsComposable(unionType);

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null)
        return isPlaceComposable(arrayType.next);

    return false;
}


// Whether every one of `structType`'s own `layout.structFields` (in
// declaration order, base struct or union alike -- `layout.structFields`
// does not distinguish) is itself `isPlaceComposable` -- the one place
// `isPlaceComposable`'s own struct and union arms both recurse through, so
// the two cannot drift from each other any more than `isClassBodyComposable`
// can drift from `isPlaceComposable` itself.
private bool allFieldsComposable(imported!"dmd.mtype".TypeStruct structType) @safe {
    import quickbite.backends.interpreter.layout: structFields, declaredType;

    foreach (field; structFields(structType))
        if (!isPlaceComposable(declaredType(field)))
            return false;

    return true;
}


// Whether `class_`'s own fields (`layout.classFields`, base-to-derived) are
// all `isPlaceComposable` -- the class-body sibling of `isPlaceComposable`
// itself, answering "can `readValue`'s class arm and `writeClassBody` round
// trip this class's body without throwing", the same round-trip meaning
// `isPlaceComposable` already carries for a struct's fields. Deliberately
// reuses `isPlaceComposable` per field rather than growing a parallel
// dispatch, for the identical anti-drift reason `isPlaceComposable`'s own
// header gives: a field whose type is itself a class answers `false` here
// too (`isPlaceComposable` already says so), matching `writeClassBody`'s
// own field-by-field `writeValue` calls, which refuse a class-typed field
// exactly as `writeValue` refuses any class-typed place.
public bool isClassBodyComposable(
    imported!"dmd.dclass".ClassDeclaration class_,
) @safe {
    import quickbite.backends.interpreter.layout: classFields, declaredType;

    foreach (field; classFields(class_))
        if (!isPlaceComposable(declaredType(field)))
            return false;

    return true;
}


// `type` narrowed to `TypeStruct`, but only when it is not a union -- the
// shared "does `readValue`/`writeValue`/`isPlaceComposable` treat this as a
// field-composed struct" check all three recurse through, so the one place
// that decides "struct, not union" cannot drift between them.
private imported!"dmd.mtype".TypeStruct nonUnionStructOf(
    imported!"dmd.mtype".Type type,
) @safe {
    auto structType = type.isTypeStruct;
    return structType !is null && structType.sym.isUnionDeclaration is null
        ? structType
        : null;
}


// `nonUnionStructOf`'s mirror image: `type` narrowed to `TypeStruct`, but
// only when it IS a union (DMD reports a union as a `TypeStruct` whose
// `sym` is a `UnionDeclaration` -- `value.md`'s Unions section, the same
// durable fact `nonUnionStructOf` reads from the opposite side). The one
// place `readValue`/`writeValue`/`isPlaceComposable` decide "union, not a
// plain struct" -- so, symmetrically, this cannot drift from
// `nonUnionStructOf` either: exactly one of the two ever returns non-null
// for a given `TypeStruct`.
private imported!"dmd.mtype".TypeStruct unionStructOf(
    imported!"dmd.mtype".Type type,
) @safe {
    auto structType = type.isTypeStruct;
    return structType !is null && structType.sym.isUnionDeclaration !is null
        ? structType
        : null;
}


// Reinterpreting a raw address as a byte range is not `@safe`; this is the
// `@trusted` boundary, mirroring `place.d`'s own `placeBytes`. `length` is
// always `NativeArray.sliceHeaderByteLength`, so the returned slice spans
// exactly the header bytes at `address` -- never more.
private ubyte[] sliceHeaderBytes(void* address, in size_t length) pure nothrow @trusted {
    return (cast(ubyte*) address)[0 .. length];
}


// `structType`'s own declared name (`StructDeclaration.ident`), verbatim --
// the same derivation `quickbite.frontend.dmd.values`'s struct default-value
// builder already uses to name a struct `Value` built straight from a
// `TypeStruct`, with no existing `Value` to borrow a type name from.
private string structTypeName(
    imported!"dmd.mtype".TypeStruct structType,
) @safe {
    return structTypeNameImpl(structType);
}

// `StructDeclaration.ident` is a plain field read, but `StructDeclaration`
// (an `extern (C++)` class) is not itself `@safe`-annotated; this is the
// `@trusted` boundary for reading it, mirroring `layout.d`'s
// `declaredTypeImpl`.
private string structTypeNameImpl(
    imported!"dmd.mtype".TypeStruct structType,
) @trusted {
    return structType.sym.ident is null ? "" : structType.sym.ident.toString.idup;
}


// The non-member enum rendering `value.md`'s Display format spec rule 5
// gives for a `value` that matches no member of `enumType`: `cast(E)N`.
// `readValue`'s enum arm falls back to this once `layout.
// enumMemberQualifiedName` answers empty.
private string nonMemberEnumName(
    imported!"dmd.mtype".TypeEnum enumType,
    in long value,
) @safe {
    import std.conv: text;

    return text("cast(", enumTypeName(enumType), ")", value);
}


// `enumType`'s own bare name (`EnumDeclaration.ident`), verbatim -- the
// same derivation `structTypeName` above uses for a struct's own name,
// needed here only to build the `cast(E)N` non-member form (the member
// case gets its own "E" prefix from `layout.enumMemberQualifiedName`).
private string enumTypeName(
    imported!"dmd.mtype".TypeEnum enumType,
) @safe {
    return enumTypeNameImpl(enumType);
}

// `EnumDeclaration.ident` is a plain field read, but `EnumDeclaration` (an
// `extern (C++)` class) is not itself `@safe`-annotated; this is the
// `@trusted` boundary for reading it, mirroring `structTypeNameImpl` above.
private string enumTypeNameImpl(
    imported!"dmd.mtype".TypeEnum enumType,
) @trusted {
    return enumType.sym.ident is null ? "" : enumType.sym.ident.toString.idup;
}

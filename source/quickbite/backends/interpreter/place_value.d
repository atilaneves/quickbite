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
// A class (`Type.isTypeClass`) is the odd one out: unlike every other case
// above, this place's own bytes are not the object's bytes, only a stored
// reference to them (`Place.deref` already documents this) -- so the class
// arm below composes the object's body through that reference rather than
// this place directly. Anything else -- pointer, union, `real` -- still has
// no place-composed shape: a pointer's elements live behind a stored
// address with no length to recurse over, a union has no single field
// layout to recurse over, and `real` is outside `native_scalar`'s codec (see
// its own header comment) -- so those throw rather than guessing at a byte
// interpretation.
public imported!"quickbite.lang".Value readValue(
    imported!"quickbite.backends.interpreter.place".Place place,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout:
        structFields, staticArrayLength, enumMemberQualifiedName;
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
    if (structType !is null) {
        Value[] fields;
        foreach (field; structFields(structType))
            fields ~= readValue(place.field(field));

        return Value.structValue(structTypeName(structType), fields);
    }

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
// arm.
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
// `layout.structFields` field types are themselves place-composable; or a
// static array whose element type (`.next`) is place-composable. Recurses
// the identical dispatch `readValue`/`writeValue` use (`isNativeScalarType`,
// `nonUnionStructOf`, `isTypeSArray`) so this predicate can never drift from
// what those two actually accept -- false for a class, slice/dynamic array,
// pointer, union, or `real`, the same set their own header comment gives.
public bool isPlaceComposable(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout: structFields, declaredType;

    if (isNativeScalarType(type))
        return true;

    auto structType = nonUnionStructOf(type);
    if (structType !is null) {
        foreach (field; structFields(structType))
            if (!isPlaceComposable(declaredType(field)))
                return false;

        return true;
    }

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null)
        return isPlaceComposable(arrayType.next);

    return false;
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

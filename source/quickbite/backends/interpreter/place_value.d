module quickbite.backends.interpreter.place_value;


private:


// Reconstructs the whole guest value at `place`, composing `Place.field`/
// `Place.index` down to scalar leaves rather than reading `place`'s bytes as
// one flat span: a native scalar type reads through `Place.loadScalar`
// directly; a non-union struct type recurses once per `layout.structFields`
// field, in declaration order; a static-array type recurses once per
// `layout.staticArrayLength` element. Anything else -- class, slice/dynamic
// array, pointer, union, `real` -- has no such place-composed shape: a class
// needs object identity beyond its own bytes, a slice/pointer's elements
// live behind a stored address rather than inline at this place, a union has
// no single field layout to recurse over, and `real` is outside `native_
// scalar`'s codec (see its own header comment) -- so those throw rather than
// guessing at a byte interpretation.
public imported!"quickbite.lang".Value readValue(
    imported!"quickbite.backends.interpreter.place".Place place,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout: structFields, staticArrayLength;
    import quickbite.lang: Value;

    auto type = place.type;

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

    throw new Exception(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );
}


// The inverse of `readValue`: writes `value`'s scalar leaves into `place`
// through the identical field-by-field/element-by-element composition --
// scalar leaves via `Place.storeScalar`, everything else unsupported for
// exactly the reasons `readValue`'s own comment gives.
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

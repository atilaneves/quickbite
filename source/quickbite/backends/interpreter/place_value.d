module quickbite.backends.interpreter.place_value;


private:


// Reads scalars through their codecs and copies aggregate places as complete
// native-layout values. Struct padding, union overlap, inline arrays, slice
// headers, and AA handles therefore stay bytes rather than being decomposed
// into ExpressionResult trees. A class place is a reference slot, so its
// arm returns the stored object-body address.
// A pointer (`Type.isTypePointer`) is a composable
// LEAF, not a recursion: this place's own bytes ARE the host address
// (`ai/plans/value.md` decision 15, "there is exactly one data-pointer
// representation -- the host address"), so the pointer arm below reads
// exactly that address back out via `Place.deref.address` (the same
// stored-pointer read `Place.index`'s own pointer case already performs)
// and wraps it, with no element recursion -- a pointer's pointee is not
// part of ITS value the way a slice's or static array's elements are.
// `real` (`TY.Tfloat80`) is ALSO a composable leaf, but through its OWN
// codec below (`isRealType`/`readRealBits`/`writeRealBits`), not
// `native_scalar`'s: `native_scalar` deliberately excludes `real` because
// `native_call_adapter.d` routes exact-size scalar arms through its
// `writeScalar`/`readScalar`, and widening that shared codec would change
// shipping FFI behaviour, out of scope for this place-composition layer
// (`ai/plans/value.md`'s decision 15 -- host layout IS the spec on THIS
// host, not a hazard to refuse -- is what makes a place-local codec
// honest here). See `readRealBits`/`writeRealBits`'s own header comments
// for the padding-determinism contract of native place writes.
public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult readValue(
    imported!"quickbite.backends.interpreter.place".Place place,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout:
        staticArrayLength, enumMemberQualifiedName, typeByteSize;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    auto type = place.type;

    if (isNullType(type))
        return ExpressionResult.null_;

    // An enum-typed place must come back tagged (`ExpressionResult.enumValue`), not as
    // the plain integral `ExpressionResult` `native_scalar.readScalar` returns for it
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
        if (isFloatingBaseEnum(type)) {
            auto baseType = floatingEnumBaseType(enumType);
            if (isRealType(baseType))
                return ExpressionResult(readRealBits(place.address, typeByteSize(baseType)));

            if (auto componentType = imaginaryComponentType(baseType)) {
                import quickbite.backends.interpreter.place: Place;
                return ExpressionResult.imaginaryValue(
                    Place(place.address, componentType).loadScalar.asReal,
                );
            }

            import quickbite.backends.interpreter.place: Place;
            return Place(place.address, baseType).loadScalar;
        }

        const bits = place.loadScalar.asLong;
        const qualifiedName = enumMemberQualifiedName(enumType, bits);
        return ExpressionResult.enumValue(
            qualifiedName.length != 0 ? qualifiedName : nonMemberEnumName(enumType, bits),
            bits,
        );
    }

    if (isNativeScalarType(type))
        return place.loadScalar;

    if (isRealType(type))
        return ExpressionResult(readRealBits(place.address, typeByteSize(type)));

    if (auto componentType = imaginaryComponentType(type))
        return ExpressionResult.imaginaryValue(
            readValue(componentPlace(place, componentType, 0)).asReal,
        );

    if (auto componentType = complexComponentType(type))
        return ExpressionResult.complexValue(
            readValue(componentPlace(place, componentType, 0)).asReal,
            readValue(componentPlace(place, componentType, 1)).asReal,
        );

    auto structType = nonUnionStructOf(type);
    if (structType !is null)
        return AggregateValue.copyFromAddress(type, place.address);

    auto unionType = unionStructOf(type);
    if (unionType !is null)
        return AggregateValue.copyFromAddress(type, place.address);

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null)
        return AggregateValue.copyFromAddress(type, place.address);

    if (type.isTypeVector !is null)
        return AggregateValue.copyFromAddress(type, place.address);

    auto sliceType = type.isTypeDArray;
    if (sliceType !is null)
        return AggregateValue.copyFromAddress(type, place.address);

    // An associative-array place stores only Quickbite's native header
    // pointer.  Copy that pointer-sized value as one aggregate handle; AA
    // lookup/mutation stays in the interpreter's native_assoc_array hooks.
    if (type.isTypeAArray !is null)
        return bytesAreZero(place.address, typeByteSize(type))
            ? ExpressionResult.null_
            : AggregateValue.copyFromAddress(type, place.address);

    // A class slot's stored body address is the class value's identity.
    if (type.isTypeClass !is null) {
        auto body = place.deref.address;
        return body is null ? ExpressionResult.null_ : ExpressionResult.pointerValue(body);
    }

    // A pointer place's own bytes are the stored host address itself
    // (`ai/plans/value.md` decision 15) -- `place.deref` already reads
    // exactly that address back out (its pointer arm returns a `Place` at
    // the pointee whose OWN `.address` is that stored value), so reusing it
    // needs no parallel raw-address accessor. A stored `null` address reads
    // back as `ExpressionResult.null_`, matching `impl.d`'s own null-pointer-literal
    // value (`isNullExp`'s non-array arm) rather than inventing a
    // `pointerValue(null)` shape nothing else in the walker produces.
    auto pointerType = type.isTypePointer;
    if (pointerType !is null) {
        auto address = place.deref.address;
        return address is null ? ExpressionResult.null_ : ExpressionResult.pointerValue(address);
    }

    if (type.isTypeDelegate !is null && bytesAreZero(
        place.address,
        typeByteSize(type),
    ))
        return ExpressionResult.null_;

    throw new Exception(
        "quickbite.backends.interpreter.place_value.readValue: unsupported at place",
    );
}


private bool bytesAreZero(
    const(void)* address,
    in size_t length,
) pure nothrow @trusted {
    const bytes = (cast(const(ubyte)*) address)[0 .. length];
    foreach (octet; bytes)
        if (octet != 0)
            return false;
    return true;
}


// True for `real` (`TY.Tfloat80`), resolving an enum's base type the same
// way `native_scalar.d`'s own `nativeScalarKindOf` does. That makes
// `enum E : real` answer `true` here as well, which is a fact about the
// BITS, not a claim that such an enum composes: `isFloatingBaseEnum` below
// declines it before this is consulted, because the read side has no enum
// `ExpressionResult` to give back for a floating one. `@trusted`: `Type.
// toBasetype` is not `@safe`, mirroring `native_scalar.d`'s identical
// boundary for the identical call. `public`: `valueMatchesPlace` needs the
// same check to decide whether a transient `ExpressionResult` reaching a
// `real`-typed place is numeric before `writeValue`; sharing it prevents the
// compatibility check and codec from drifting apart.
public bool isRealType(imported!"dmd.mtype".Type type) @trusted {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tfloat80;
}


// An imaginary scalar has the native layout of its matching floating
// component. Keeping that relationship typed lets the ordinary float codecs
// own the bytes while ExpressionResult retains the imaginary value category.
private imported!"dmd.mtype".Type imaginaryComponentType(
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.astenums: TY;
    import dmd.mtype: Type;

    switch (type.toBasetype.ty) with (TY) {
    case Timaginary32:
        return Type.tfloat32;
    case Timaginary64:
        return Type.tfloat64;
    case Timaginary80:
        return Type.tfloat80;
    default:
        return null;
    }
}


// A complex scalar is laid out as two adjacent components of its matching
// real type. Keep that type relationship in one place so reads, writes, and
// composability cannot disagree about the native representation.
private imported!"dmd.mtype".Type complexComponentType(
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.astenums: TY;
    import dmd.mtype: Type;

    switch (type.toBasetype.ty) {
    case TY.Tcomplex32:
        return Type.tfloat32;
    case TY.Tcomplex64:
        return Type.tfloat64;
    case TY.Tcomplex80:
        return Type.tfloat80;
    default:
        return null;
    }
}


private imported!"quickbite.backends.interpreter.place".Place componentPlace(
    imported!"quickbite.backends.interpreter.place".Place place,
    imported!"dmd.mtype".Type componentType,
    in size_t index,
) @trusted {
    import quickbite.backends.interpreter.layout: typeByteSize;
    import quickbite.backends.interpreter.place: Place;

    return Place(
        cast(void*) (cast(ubyte*) place.address + index * typeByteSize(componentType)),
        componentType,
    );
}


// `Type.toBasetype` is not @safe; this keeps the class-reference check at the
// same narrow DMD boundary as `isRealType` above.
private bool isClassType(imported!"dmd.mtype".Type type) @trusted {
    return type.toBasetype.isTypeClass !is null;
}


// The AA carrier is a header pointer, whose layout does not change when D
// propagates qualifiers into the key/value types.
private bool isAssocArrayType(imported!"dmd.mtype".Type type) @trusted {
    return type.toBasetype.isTypeAArray !is null;
}


// `Type.toBasetype` is not `@safe`; the null type has one value and its
// native place is therefore always the all-zero representation.
private bool isNullType(imported!"dmd.mtype".Type type) @trusted {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tnull;
}


// DMD interns base types, while modifiers and aliases can give two different
// Type objects for the same guest-layout value. The byte-copy gate cares about
// that layout identity, not the wrapper object identity.
private bool sameBaseType(
    imported!"dmd.mtype".Type lhs,
    imported!"dmd.mtype".Type rhs,
) @trusted {
    import dmd.astenums: TY;
    import dmd.typesem: mutableOf;

    auto lhsVector = lhs.toBasetype.isTypeVector;
    auto rhsVector = rhs.toBasetype.isTypeVector;
    if (lhsVector !is null || rhsVector !is null)
        return lhsVector !is null && rhsVector !is null &&
            mutableOf(lhsVector.basetype).equals(mutableOf(rhsVector.basetype));

    // `mutableOf` removes the outer qualifier, but DMD is not required to
    // intern the resulting wrapper (notably for a const AA field).  Semantic
    // type equality is the layout identity here; pointer identity rejects a
    // valid `long[string]` -> `const(long[string])` aggregate copy.
    // A dynamic-array qualifier can instead live on its element (`inout(int)[]`
    // versus `int[]`). The header layout is identical, and the element
    // qualifier does not change the header copied at this boundary.
    auto lhsArray = lhs.toBasetype.isTypeDArray;
    auto rhsArray = rhs.toBasetype.isTypeDArray;
    if (lhsArray !is null && rhsArray !is null) {
        // The frontend represents an untyped empty/null slice carrier as
        // `void[]`. Its value is only the ABI header, so copying that empty
        // header into a concretely typed slice slot is the typed
        // materialization step, not an element-layout conversion.
        if (lhsArray.next.toBasetype.ty == TY.Tvoid)
            return true;
        // Any dynamic array implicitly converts to `void[]` (compiled D
        // covariance, e.g. passing a `string` argument to a `void[]`
        // parameter such as `std.array.overlap`/`doesPointTo`'s scratch
        // range). The header layout -- {length, ptr} -- is element-type
        // agnostic, so the same byte copy below is correct either way.
        if (rhsArray.next.toBasetype.ty == TY.Tvoid)
            return true;
        // Compare the element layouts recursively. For a nested dynamic
        // array, qualifying the inner slice header (`int[]` ->
        // `const(int[])`) does not qualify its `int` elements and does not
        // change either header's representation. A one-level `mutableOf`
        // comparison retains that inner wrapper qualifier and rejects the
        // ordinary implicit conversion `int[][]` -> `const(int[])[]`.
        return sameBaseType(lhsArray.next, rhsArray.next);
    }

    return mutableOf(lhs.toBasetype).equals(mutableOf(rhs.toBasetype));
}


// DMD owns the null-terminated type spelling for the lifetime of the AST;
// copying it makes the diagnostic independent of that internal buffer.
private string typeName(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return type.toChars.fromStringz.idup;
}


// Whether a non-aggregate ExpressionResult can be encoded at `type`. Native
// aggregates use their typed storage directly and are handled before this
// scalar compatibility gate at execution boundaries.
public bool valueMatchesPlace(
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
) @safe {
    if (!isPlaceComposable(type))
        return false;

    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    if (isNullType(type))
        return value == ExpressionResult.null_;

    if (isNativeScalarType(type))
        return value.isNumericScalar || value.isCharacter;

    // `real` is `isPlaceComposable` but not a native scalar. Its expression
    // representation is always numeric (never character), matching
    // `writeValue`'s `writeRealBits` arm.
    if (isRealType(type))
        return value.isNumericScalar;

    if (imaginaryComponentType(type) !is null)
        return value.isImaginaryScalar;

    if (complexComponentType(type) !is null)
        return value.isComplexScalar;

    if (type.isTypePointer !is null)
        return value.isPointer || value == ExpressionResult.null_;

    // A scalar destined for a static-array place is a broadcast fill --
    // ordinary D semantics for `T[N] x = scalar;` (declaration) and its
    // reassignment form when it reaches this generic scalar path rather than
    // the dedicated slice-assignment or struct-literal-field broadcasts,
    // which already accept the identical shape. Recursing into the element
    // type answers the same question `writeValue`'s own `Tsarray` arm below
    // relies on before broadcasting.
    if (auto arrayType = type.isTypeSArray)
        return valueMatchesPlace(arrayType.next, value);

    return false;
}


// True for an enum whose base type is a floating one -- `enum E : double`
// and `enum E : real` are both legal D. ExpressionResult has no floating enum
// tag, so typed places carry their underlying floating scalar directly; that
// is still a complete and lossless guest representation for reads, writes,
// and union overlap.
//
// `TypeEnum.isFloating` forwards to the enum's own member type (DMD's own
// override), so this needs no separate base-type resolution. `@trusted`:
// neither `isFloating` nor `Type.isTypeEnum` is `@safe`-annotated, the
// same boundary `isRealType` above draws for `toBasetype`.
private bool isFloatingBaseEnum(imported!"dmd.mtype".Type type) @trusted {
    auto enumType = type.isTypeEnum;
    return enumType !is null && enumType.isFloating;
}


private imported!"dmd.mtype".Type floatingEnumBaseType(
    imported!"dmd.mtype".TypeEnum type,
) @trusted {
    return type.toBasetype2;
}


// The scalar leaf `writeValue` actually writes: `native_scalar.
// isNativeScalarType` dispatches on an enum's BASE type, so it answers
// `true` for `enum E : double`, whose typed place carries the underlying
// scalar bits directly. This keeps union-member reconstruction on the same
// read/write representation.
private bool isWritableNativeScalar(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

    return isNativeScalarType(type);
}


// Reads `length` bytes at `address` back as a `real` -- the inverse of
// `writeRealBits` below. An x87 extended-precision LOAD only reads the
// significant bytes (10 of them on this host); it never inspects the
// trailing padding bytes, so a plain `memcpy` into a same-sized local is
// exact -- the identical shape `native_scalar.d`'s own read side uses for
// `float`/`double`, just kept here instead (see `readValue`'s own header
// comment for why). `@trusted`: reinterpreting `address` as a byte range
// and `memcpy`-ing it into a `real` local is not `@safe`. The `in`
// contract is stripped under `-release`; this function's actual safety
// rests on its sole caller, `readValue`, always passing `layout.
// typeByteSize(type)` for a `real`-typed place, which is `real.sizeof` on
// every host this interpreter runs on (DMD's own `Target.realsize`,
// decision 15's "host layout is the spec").
private real readRealBits(const(void)* address, in size_t length) @trusted
in (length == real.sizeof)
{
    import core.stdc.string: memcpy;

    real bits;
    memcpy(&bits, address, length);
    return bits;
}


// Writes `value` into `length` bytes at `address`, with the padding bytes
// (6 of them on this host, past the 10 significant ones) DETERMINISTIC --
// always zero -- rather than whatever was already at `address`. The
// native storage must preserve deterministic padding bytes, so two writes of
// the same `real` produce identical byte representations. What guarantees that
// is
// composing the bytes in a fresh LOCAL and copying the whole local over,
// never assigning into the destination in place: `place_value.d`'s own
// `writeRealBits` unit test writes the same value into two destinations
// pre-filled with different non-zero patterns and asserts the padding is
// zero in both, which is what would fail if any byte of the destination
// survived a write. The `memset` is belt and braces on top of that: on this
// host `bits = value` already emits a full 16-byte copy, so it leaves
// nothing of `bits` uninitialised -- but nothing in the language promises
// that, and the `memset` costs nothing. `@trusted` and the `in` contract:
// the same reasoning as `readRealBits` above, mirrored for the write side.
private void writeRealBits(void* address, in size_t length, in real value) @trusted
in (length == real.sizeof)
{
    import core.stdc.string: memcpy, memset;

    real bits = void;
    memset(&bits, 0, bits.sizeof);
    bits = value;
    memcpy(address, &bits, length);
}


// Writes native aggregates as complete byte spans and scalar carriers through
// their codecs. Aggregate layout never comes from ExpressionResult structure.
// Null slices, AAs, delegates, pointers, and class references retain their
// ABI all-zero or address representation.
public void writeValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout: typeByteSize;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    auto type = place.type;

    if (value.isNativeAggregate) {
        auto source = AggregateValue.native(value);
        // DMD uses a pointer-typed slot for a catch variable even though the
        // caught value is a class reference. Store the referenced object body,
        // not the address of the native class-reference carrier.
        if (isClassType(source.type) && type.isTypePointer !is null) {
            place.storeReference(Place(source.address, source.type).deref.address);
            return;
        }
        // Class assignment stores only the reference slot, so a derived
        // native class value may initialise a base-class slot just as a D
        // reference does. Other aggregates still require their exact native
        // layout type before copying their complete byte span.
        const classReference = isClassType(source.type) && isClassType(type);
        // An AA value is solely its header handle.  Qualifying an AA qualifies
        // its value type (`const(long[string])`), not that one-word handle,
        // so a qualified destination is a valid copy without pretending its
        // key/value storage has the same DMD type.
        const assocArrayHandle = isAssocArrayType(source.type) && isAssocArrayType(type);
        if (!sameBaseType(source.type, type) && !classReference && !assocArrayHandle)
            throw new Exception(
                "quickbite.backends.interpreter.place_value.writeValue: "
                ~ "native aggregate type mismatch " ~ typeName(source.type)
                ~ " -> " ~ typeName(type),
            );
        copyAggregateBytes(place.address, source.address, typeByteSize(type));
        return;
    }

    if (isNullType(type)) {
        if (value != ExpressionResult.null_)
            throw new Exception(
                "quickbite.backends.interpreter.place_value.writeValue: "
                ~ "null place requires a null ExpressionResult",
            );
        zeroBytes(place.address, typeByteSize(type));
        return;
    }

    if (isFloatingBaseEnum(type)) {
        auto enumType = type.isTypeEnum;
        auto baseType = floatingEnumBaseType(enumType);
        if (isRealType(baseType))
            writeRealBits(place.address, typeByteSize(baseType), value.asReal);
        else if (auto componentType = imaginaryComponentType(baseType))
            writeValue(
                Place(place.address, componentType),
                ExpressionResult(value.imaginaryPart),
            );
        else
            place.storeScalar(value);
        return;
    }

    if (isNativeScalarType(type)) {
        place.storeScalar(value);
        return;
    }

    if (isRealType(type)) {
        writeRealBits(place.address, typeByteSize(type), value.asReal);
        return;
    }

    if (auto componentType = imaginaryComponentType(type)) {
        writeValue(
            componentPlace(place, componentType, 0),
            ExpressionResult(value.imaginaryPart),
        );
        return;
    }

    if (auto componentType = complexComponentType(type)) {
        writeValue(
            componentPlace(place, componentType, 0),
            value.complexRealPart,
        );
        writeValue(
            componentPlace(place, componentType, 1),
            value.complexImaginaryPart,
        );
        return;
    }

    if (type.isTypeDArray !is null && value == ExpressionResult.null_) {
        zeroBytes(place.address, typeByteSize(type));
        return;
    }

    auto pointerType = type.isTypePointer;
    if (pointerType !is null) {
        if (!value.isPointer && value != ExpressionResult.null_)
            throw new Exception(
                "quickbite.backends.interpreter.place_value.writeValue: "
                ~ "pointer place requires a pointer ExpressionResult or null",
            );

        place.storeReference(pointerAddress(value));
        return;
    }

    auto classType = type.isTypeClass;
    if (classType !is null) {
        if (!value.isPointer && value != ExpressionResult.null_)
            throw new Exception(
                "quickbite.backends.interpreter.place_value.writeValue: "
                ~ "class place requires an object pointer or null",
            );
        place.storeReference(pointerAddress(value));
        return;
    }

    if (type.isTypeAArray !is null && value == ExpressionResult.null_) {
        zeroBytes(place.address, typeByteSize(type));
        return;
    }

    if (type.isTypeDelegate !is null && value == ExpressionResult.null_) {
        zeroBytes(place.address, typeByteSize(type));
        return;
    }

    // A scalar reaching a static-array place (already screened non-aggregate
    // by the `value.isNativeAggregate` arm above) is a broadcast fill --
    // ordinary D semantics for `T[N] x = scalar;`, mirroring
    // `Walker.structLiteralFieldValue`'s identical broadcast for a struct's
    // own array-typed field. Each element write recurses back through this
    // same function, so a multidimensional static array (whose element type
    // is itself a `Tsarray`) broadcasts all the way down to the scalar leaf.
    if (auto arrayType = type.isTypeSArray) {
        import quickbite.backends.interpreter.layout: staticArrayLength;

        foreach (index; 0 .. staticArrayLength(arrayType))
            writeValue(place.index(index), value);
        return;
    }

    throw new Exception(
        "quickbite.backends.interpreter.place_value.writeValue: unsupported at place",
    );
}


// A null delegate is the all-zero `{ context, function }` ABI value.  Live
// interpreted delegates are intentionally not encoded here: the walker keeps
// those in its callable slot table because no native function address exists
// for them.
private void zeroBytes(void* address, in size_t length) pure nothrow @trusted {
    import core.stdc.string: memset;

    memset(address, 0, length);
}


// `ExpressionResult.pointerAddress` is not `@safe`; this is the `@trusted` boundary.
// Called only once `writeValue`'s pointer or class arm has already checked
// `value` is `isPointer` or `ExpressionResult.null_`, so this never reaches
// `pointerAddress`'s own throwing arm -- it always returns a real host
// address, or `null`.
private void* pointerAddress(in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value) @trusted {
    return value.pointerAddress;
}


// The structural capability predicate below remains conservative for callers
// that need to know whether a type can be decomposed into scalar leaves. It is
// not an aggregate execution representation: aggregate reads and writes copy
// native storage as one value.
private ptrdiff_t widestUnionFieldIndex(
    imported!"dmd.mtype".TypeStruct unionType,
) @safe {
    import quickbite.backends.interpreter.layout: structFields, declaredType, typeByteSize;

    ptrdiff_t widestIndex = -1;
    size_t widestSize = 0;
    foreach (index, field; structFields(unionType)) {
        const size = typeByteSize(declaredType(field));
        if (widestIndex < 0 || size > widestSize) {
            widestSize = size;
            widestIndex = index;
        }
    }

    return widestIndex;
}


// A union is scalar-leaf composable only when it has a member covering the
// complete extent and every sibling can be derived through the same leaf set.
private bool isComposableUnion(imported!"dmd.mtype".TypeStruct unionType) @safe {
    import quickbite.backends.interpreter.layout: structFields, declaredType;

    const widestIndex = widestUnionFieldIndex(unionType);
    if (widestIndex < 0)
        return false;

    auto fields = structFields(unionType);
    foreach (field; fields)
        if (!isUnionMemberReDerivable(declaredType(field)))
            return false;

    return writeCoversWholeType(declaredType(fields[widestIndex]));
}


// Only native scalar leaves, static arrays of them, and disjoint plain structs
// recursively composed from them belong to that conservative set.
private bool isUnionMemberReDerivable(imported!"dmd.mtype".Type type) @safe
out (result; !result || isPlaceComposable(type))
{
    import quickbite.backends.interpreter.layout: structFields, declaredType;

    if (isWritableNativeScalar(type))
        return true;

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null)
        return isWritableNativeScalar(arrayType.next);

    auto structType = nonUnionStructOf(type);
    if (structType is null)
        return false;

    // The same gate `allFieldsComposable` applies to a struct's own fields
    // (its header comment), applied here for the same reason and to keep
    // the subset property the `out` contract above states: a struct
    // bearing an ANONYMOUS union has both of DMD's flattened members in
    // `structFields` at the same offset, and when they are native scalars
    // -- unlike the `real`/`long` pair, which stops at
    // `isWritableNativeScalar` -- the walk below would otherwise call the
    // whole struct re-derivable while `isPlaceComposable` declines it.
    // Over-declining is the right bias: overlapping fields do not form the
    // disjoint scalar-leaf composition this predicate promises.
    auto fields = structFields(structType);
    if (!fieldsAreDisjoint(fields))
        return false;

    foreach (field; fields)
        if (!isUnionMemberReDerivable(declaredType(field)))
            return false;

    return true;
}


// Whether scalar leaves tile every one of `layout.typeByteSize(type)`'s bytes.
// Only the conservative union-shape classifier needs this fact (see
// `isComposableUnion`). Aggregate `writeValue` does not use this walk: it
// copies the complete typed byte span.
//
// A native scalar, a `real`, and a pointer each write exactly their own
// `typeByteSize` (`native_scalar.writeScalar`, `writeRealBits`,
// `Place.storeReference`). A static array's elements tile its whole extent,
// D's own rule that a static array's size is exactly its length times its
// element size, so only the element type is in question. A non-union struct
// covers its extent only when its fields leave no gap: DMD's own
// `layout.fieldByteOffset`s must run consecutively from 0 and the last one
// must end at the struct's own size, which alignment padding (interior or
// trailing) breaks. Every other shape -- a union, a slice, a class --
// answers `false`.
private bool writeCoversWholeType(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.layout:
        structFields, declaredType, fieldByteOffset, typeByteSize;

    if (
        isWritableNativeScalar(type) || isRealType(type) ||
        complexComponentType(type) !is null || type.isTypePointer !is null
    )
        return true;

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null)
        return writeCoversWholeType(arrayType.next);

    auto structType = nonUnionStructOf(type);
    if (structType is null)
        return false;

    size_t covered = 0;
    foreach (field; structFields(structType)) {
        if (fieldByteOffset(field) != covered)
            return false;

        auto fieldType = declaredType(field);
        if (!writeCoversWholeType(fieldType))
            return false;

        covered += typeByteSize(fieldType);
    }

    return covered == typeByteSize(structType);
}


public bool isPlaceComposable(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

    if (isNativeScalarType(type))
        return true;

    if (isRealType(type))
        return true;

    if (imaginaryComponentType(type) !is null)
        return true;

    if (complexComponentType(type) !is null)
        return true;

    auto structType = nonUnionStructOf(type);
    if (structType !is null)
        return allFieldsComposable(structType);

    auto unionType = unionStructOf(type);
    if (unionType !is null)
        return isComposableUnion(unionType);

    auto arrayType = type.isTypeSArray;
    if (arrayType !is null)
        return isPlaceComposable(arrayType.next);

    if (type.isTypePointer !is null)
        return true;

    if (isNullType(type))
        return true;

    return false;
}


// Whether every one of `structType`'s own `layout.structFields` (in
// declaration order) belongs to the conservative scalar-leaf shape described
// by `isPlaceComposable`. A union asks the stricter `isComposableUnion`
// instead, for the reason that function's header gives.
//
// "In declaration order, one field each" is only true while those fields
// occupy DISJOINT bytes, so `fieldsAreDisjoint` gates the whole walk: DMD
// flattens an ANONYMOUS union's members into the enclosing struct's own
// `structFields` at OVERLAPPING offsets (`value.md`'s Unions section --
// and it is the offsets that are consulted here, never `overlapped`, since
// that flag is a derived fact about them, not a second source of truth).
// The enclosing declaration is still a plain `StructDeclaration`, so without
// this check the classifier would treat the flattened members as disjoint
// leaves even though a write through either member changes the same bytes.
private bool allFieldsComposable(imported!"dmd.mtype".TypeStruct structType) @safe {
    import quickbite.backends.interpreter.layout: structFields, declaredType;

    auto fields = structFields(structType);
    if (!fieldsAreDisjoint(fields))
        return false;

    foreach (field; fields)
        if (!isPlaceComposable(declaredType(field)))
            return false;

    return true;
}


// Whether no two of `fields` share a byte -- each field's own
// `layout.fieldByteOffset` plus its declared type's own
// `layout.typeByteSize`, DMD's numbers verbatim, compared pairwise.
// Answering `false` is a deliberately conservative classification: any
// overlap refuses the whole enclosing type rather than trying to group the
// overlapping members back into the anonymous union DMD flattened and asking
// `isComposableUnion` of that group. A true union's own `structFields` all sit
// at offset 0 and would fail this outright, which is why a union asks
// `isComposableUnion` directly.
private bool fieldsAreDisjoint(
    imported!"dmd.declaration".VarDeclaration[] fields,
) @safe {
    import quickbite.backends.interpreter.layout:
        declaredType, fieldByteOffset, typeByteSize;

    foreach (i, field; fields) {
        const start = fieldByteOffset(field);
        const end = start + typeByteSize(declaredType(field));

        foreach (other; fields[i + 1 .. $]) {
            const otherStart = fieldByteOffset(other);
            const otherEnd = otherStart + typeByteSize(declaredType(other));

            if (start < otherEnd && otherStart < end)
                return false;
        }
    }

    return true;
}


// `type` narrowed to `TypeStruct`, but only when it is not a union. Reads,
// writes, and the structural classifier share this distinction so the one
// place deciding "struct, not union" cannot drift between them.
private imported!"dmd.mtype".TypeStruct nonUnionStructOf(
    imported!"dmd.mtype".Type type,
) @safe {
    auto structType = baseTypeOf(type).isTypeStruct;
    return structType !is null && structType.sym.isUnionDeclaration is null
        ? structType
        : null;
}


// `nonUnionStructOf`'s mirror image: `type` narrowed to `TypeStruct`, but
// only when it IS a union (DMD reports a union as a `TypeStruct` whose
// `sym` is a `UnionDeclaration` -- `value.md`'s Unions section, the same
// durable fact `nonUnionStructOf` reads from the opposite side). The one
// place reads, writes, and the structural classifier decide "union, not a
// plain struct" -- so, symmetrically, this cannot drift from
// `nonUnionStructOf` either: exactly one of the two ever returns non-null
// for a given `TypeStruct`.
private imported!"dmd.mtype".TypeStruct unionStructOf(
    imported!"dmd.mtype".Type type,
) @safe {
    auto structType = baseTypeOf(type).isTypeStruct;
    return structType !is null && structType.sym.isUnionDeclaration !is null
        ? structType
        : null;
}


// Struct dispatch ignores top-level qualifiers; the DMD base-type query is
// confined to this boundary so all struct paths make the same decision.
private imported!"dmd.mtype".Type baseTypeOf(
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.typesem: mutableOf;

    return mutableOf(type.toBasetype);
}


// Reinterpreting a raw address as a byte range is not `@safe`; this is the
// `@trusted` boundary, mirroring `place.d`'s own `placeBytes`. `length` is
// always `NativeArray.sliceHeaderByteLength`, so the returned slice spans
// exactly the header bytes at `address` -- never more.
// Both addresses come from DMD-sized aggregate storage of the identical
// static type, checked by `writeValue` before this boundary.  Copying exactly
// that size is the whole-value assignment operation; recursive field writes
// would recreate field-by-field aggregate traversal and lose union/padding
// bits.
private void copyAggregateBytes(
    void* destination,
    void* source,
    in size_t length,
) pure nothrow @trusted {
    import core.stdc.string: memcpy;

    memcpy(destination, source, length);
}


// `structType`'s own declared name (`StructDeclaration.ident`), verbatim --
// the same derivation `quickbite.frontend.dmd.values`'s struct default-value
// builder already uses to name a struct `ExpressionResult` built straight from a
// `TypeStruct`, with no existing `ExpressionResult` to borrow a type name from.
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

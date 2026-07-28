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
// this place directly, delegating to `readClassValue` (own header comment)
// for the recursion, since a class field can itself point at another
// object -- an object GRAPH, not only a single object -- and that
// recursion needs a cycle guard a plain `readValue` call does not carry.
// A pointer (`Type.isTypePointer`) is a composable
// LEAF, not a recursion: this place's own bytes ARE the host address
// (`ai/plans/value.md` decision 15, "there is exactly one data-pointer
// representation -- the host address"), so the pointer arm below reads
// exactly that address back out via `Place.deref.address` (the same
// stored-pointer read `Place.index`'s own pointer case already performs)
// and boxes it, with no element recursion -- a pointer's pointee is not
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
// for the padding-determinism argument the verified frame mirror's
// whole-slot byte comparison depends on.
//
// `identityOfObjectBody` is the caller-supplied capability the class arm
// needs and no other arm does: a boxed `Value.classValue` carries an
// IDENTITY, and which namespace an identity lives in is the caller's fact,
// not this module's. `impl.d` mints identities as small counters and
// `object_table.ObjectTable` maps counter to body address; a `Value`
// carrying a raw address where a counter is expected passes
// `ObjectTable.storageFor`'s non-zero guard and silently allocates a
// SECOND body for the same object, duplicating it and breaking both
// aliasing and generation tracking. So this takes the address-to-identity
// translation the same way `writeClassBody` takes the inverse one
// (`resolveObjectBody`) instead of minting a `cast(size_t) address`
// nothing else in the codebase would recognise. `null` (the default, for
// the majority of call sites whose place holds no class at all) makes the
// class arm decline rather than guess.
public imported!"quickbite.backends.interpreter.runtime_value".Value readValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    size_t delegate(void* bodyAddress) @safe identityOfObjectBody = null,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout:
        staticArrayLength, enumMemberQualifiedName, typeByteSize;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

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
        if (isFloatingBaseEnum(type)) {
            auto baseType = floatingEnumBaseType(enumType);
            if (isRealType(baseType))
                return Value(readRealBits(place.address, typeByteSize(baseType)));

            import quickbite.backends.interpreter.place: Place;
            return Place(place.address, baseType).loadScalar;
        }

        const bits = place.loadScalar.asLong;
        const qualifiedName = enumMemberQualifiedName(enumType, bits);
        return Value.enumValue(
            qualifiedName.length != 0 ? qualifiedName : nonMemberEnumName(enumType, bits),
            bits,
        );
    }

    if (isNativeScalarType(type))
        return place.loadScalar;

    if (isRealType(type))
        return Value(readRealBits(place.address, typeByteSize(type)));

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
    // lookup/mutation stays in the interpreter's native_assoc_array hooks,
    // never in recursive RuntimeValue entries.
    if (type.isTypeAArray !is null)
        return AggregateValue.copyFromAddress(type, place.address);

    // Native-authority class slots expose the stored object body address
    // directly. The legacy mirror supplies an identity capability and keeps
    // its boxed graph reconstruction below; it is not allowed to mint a
    // second identity for a native body.
    if (type.isTypeClass !is null) {
        if (identityOfObjectBody is null) {
            auto body = place.deref.address;
            return body is null ? Value.null_ : Value.pointerValue(body);
        }
        return readClassValue(place, null, identityOfObjectBody);
    }

    // A pointer place's own bytes are the stored host address itself
    // (`ai/plans/value.md` decision 15) -- `place.deref` already reads
    // exactly that address back out (its pointer arm returns a `Place` at
    // the pointee whose OWN `.address` is that stored value), so reusing it
    // needs no parallel raw-address accessor. A stored `null` address reads
    // back as `Value.null_`, matching `impl.d`'s own null-pointer-literal
    // value (`isNullExp`'s non-array arm) rather than inventing a
    // `pointerValue(null)` shape nothing else in the walker produces.
    auto pointerType = type.isTypePointer;
    if (pointerType !is null) {
        auto address = place.deref.address;
        return address is null ? Value.null_ : Value.pointerValue(address);
    }

    if (type.isTypeDelegate !is null && bytesAreZero(
        place.address,
        typeByteSize(type),
    ))
        return Value.null_;

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


// The class-composing recursion `readValue`'s class arm delegates to,
// carrying `visiting` -- the set of object-body addresses already being
// read along the CURRENT reference chain -- so a live cycle
// (`class Node { Node next; }` with `a.next.next is a`) declines with a
// clear exception instead of recursing forever. `place` is at a class-typed
// place (a stored reference, `place`'s own contract), exactly the shape
// `readValue`'s class arm and a class-typed FIELD's own place share, which
// is what lets this function call itself directly for a nested class field
// rather than routing back through the generic `readValue` dispatch (kept
// simple below: only a class-typed field recurses through `readClassValue`;
// every other field type recurses through `readValue` unchanged, since a
// struct or array field can never reintroduce a class reference into this
// chain -- `writeValue`'s own struct/array arms refuse a class-typed field
// outright, see their header comment, so no native storage this codebase
// ever writes can carry one except directly, through another class-typed
// field).
//
// `visiting` is keyed by the body's OWN address -- the storage fact, which
// is what a cycle actually is (the same body reached twice down one
// reference chain), and deliberately NOT the identity handed back below,
// which lives in the caller's namespace and needs no cycle meaning at all.
// It is a genuine "currently being read" set, not a "read at all" set: an
// address is removed once its own subtree finishes (`scope(exit)`), so two
// SIBLING fields referencing the SAME object (a DAG, not a cycle) each
// still compose independently, matching `object_table.ObjectTable`'s own
// "one identity, one address" guarantee rather than needing a second one
// here.
//
// `identityOfObjectBody` translates that address into the identity the
// CALLER's own object table uses -- see `readValue`'s own header comment
// for why this module must not mint one itself. A caller that supplies
// none has no class namespace to speak of, so this declines rather than
// producing a `Value.classValue` whose identity nothing can resolve.
private imported!"quickbite.backends.interpreter.runtime_value".Value readClassValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    bool[size_t] visiting,
    size_t delegate(void* bodyAddress) @safe identityOfObjectBody,
) @safe {
    import quickbite.backends.interpreter.layout:
        classFields, classQualifiedName, classHierarchyNames, fieldName;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    // `place.deref` follows this place's own stored reference and keeps
    // the class type, giving a place at the object body's own address
    // (`place.d`'s own contract) -- a null reference (no object bound
    // yet) reads back as `Value.null_` rather than attempting to read
    // fields through a null address. Checked before the capability below:
    // "no object bound yet" needs no identity to answer.
    auto bodyPlace = place.deref;
    if (bodyPlace.address is null)
        return Value.null_;

    if (identityOfObjectBody is null)
        throw new Exception(
            "quickbite.backends.interpreter.place_value.readValue: "
            ~ "a class place needs an identityOfObjectBody capability to "
            ~ "name the object it reads",
        );

    const bodyKey = cast(size_t) bodyPlace.address;
    if (bodyKey in visiting)
        throw new Exception(
            "quickbite.backends.interpreter.place_value.readValue: "
            ~ "cyclic class object graph",
        );
    visiting[bodyKey] = true;
    scope(exit) visiting.remove(bodyKey);

    const identity = identityOfObjectBody(bodyPlace.address);

    auto classType = place.type.isTypeClass;
    string[] fieldNames;
    Value[] fields;
    foreach (field; classFields(classType.sym)) {
        fieldNames ~= fieldName(field);

        auto fieldPlace = bodyPlace.field(field);
        fields ~= fieldPlace.type.isTypeClass !is null
            ? readClassValue(fieldPlace, visiting, identityOfObjectBody)
            : readValue(fieldPlace, identityOfObjectBody);
    }

    // `classQualifiedName(classType.sym)` names `classType` -- `place`'s
    // own STATIC type, not necessarily the object's dynamic one -- unlike
    // `impl.d`'s `classDefaultValue`, invoked once at `new` with the class
    // actually being constructed, which is where every `Value.classValue`
    // this codebase mints its `classTypeName` from today; casts pass it
    // through unchanged rather than re-deriving it. `impl.d`'s
    // `classBodyShapeMatches` (the class mirror's write/verify gate) now
    // trusts `classTypeName` as the object's genuine dynamic class, so a
    // `Value` reaching there from THIS function through a place statically
    // narrower than the real object (were one ever routed into a shared
    // identity `classBodyShapeMatches` checks) would carry a name that
    // undersells the object's real class and wrongly MATCH where the gate
    // should decline.
    return AggregateValue.reconstructClass(
        classQualifiedName(classType.sym),
        classHierarchyNames(classType.sym),
        fieldNames,
        fields,
        identity,
    );
}


// True for `real` (`TY.Tfloat80`), resolving an enum's base type the same
// way `native_scalar.d`'s own `nativeScalarKindOf` does. That makes
// `enum E : real` answer `true` here as well, which is a fact about the
// BITS, not a claim that such an enum composes: `isFloatingBaseEnum` below
// declines it before this is consulted, because the read side has no enum
// `Value` to give back for a floating one. `@trusted`: `Type.
// toBasetype` is not `@safe`, mirroring `native_scalar.d`'s identical
// boundary for the identical call. `public`: `impl.d`'s `placeShapeMatches`
// needs the identical check, to decide whether a boxed `Value` reaching a
// `real`-typed place is itself a numeric scalar before calling `writeValue`
// -- reusing this rather than growing a second `Tfloat80` check keeps the
// two from drifting apart the same way `isNativeScalarType` already does
// for every native scalar type.
public bool isRealType(imported!"dmd.mtype".Type type) @trusted {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tfloat80;
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
        return mutableOf(lhsArray.next).equals(mutableOf(rhsArray.next));
    }

    return mutableOf(lhs.toBasetype).equals(mutableOf(rhs.toBasetype));
}


// DMD owns the null-terminated type spelling for the lifetime of the AST;
// copying it makes the diagnostic independent of that internal buffer.
private string typeName(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return type.toChars.fromStringz.idup;
}


// Whether `value` has exactly the recursive boxed shape `writeValue` can
// encode at `type`: a native scalar, `real`, struct/union, static array, or
// host-address pointer. This is the value-side counterpart to
// `isPlaceComposable`'s type-side gate, and deliberately calls it itself so
// mirror writers and scratch verifiers cannot disagree about whether a
// `writeValue` call is safe. A mismatch is ordinary control flow for the
// boxed-era mirror: callers leave the shadow untouched rather than relying on
// `writeValue` to throw after a partial recursive write.
public bool valueMatchesPlace(
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) @safe {
    if (!isPlaceComposable(type))
        return false;

    return valueMatchesComposablePlace(type, value);
}


// `valueMatchesPlace` has already established that `type` is composable.
// Keeping that type-side recursion outside this value-side recursion avoids
// re-walking every nested aggregate at each leaf.
private bool valueMatchesComposablePlace(
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout:
        declaredType, staticArrayLength, structFields;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    if (isNativeScalarType(type))
        return value.isNumericScalar || value.isCharacter;

    // `real` is `isPlaceComposable` but not a native scalar. Its boxed
    // representation is always numeric (never character), matching
    // `writeValue`'s `writeRealBits` arm.
    if (isRealType(type))
        return value.isNumericScalar;

    auto structType = type.isTypeStruct;
    if (structType !is null) {
        if (!AggregateValue.isStruct(value))
            return false;

        auto fields = structFields(structType);
        if (AggregateValue.fieldCount(value) != fields.length)
            return false;

        foreach (index, field; fields)
            if (!valueMatchesComposablePlace(
                declaredType(field),
                AggregateValue.fieldAt(value, index),
            ))
                return false;

        return true;
    }

    if (type.isTypePointer !is null)
        return value.isPointer || value == Value.null_;

    auto arrayType = type.isTypeSArray;
    assert(arrayType !is null, "valueMatchesPlace: composable type");
    if (!AggregateValue.isArray(value))
        return false;

    const length = staticArrayLength(arrayType);
    if (AggregateValue.elementCount(value) != length)
        return false;

    foreach (i; 0 .. length)
        if (!valueMatchesComposablePlace(arrayType.next, AggregateValue.elementAt(value, i)))
            return false;

    return true;
}


// True for an enum whose base type is a floating one -- `enum E : double`
// and `enum E : real` are both legal D. RuntimeValue has no floating enum
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
// verified frame mirror compares whole slots RAW BYTE by raw byte
// (`ai/plans/value.md`'s Layout authority contract), so two writes of the
// same `real` must produce identical bytes, padding included, or `impl.d`'s
// `assertFrameMirror` fires as a hard failure. What guarantees that is
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
private imported!"quickbite.backends.interpreter.runtime_value".Value structValueAt(
    imported!"quickbite.backends.interpreter.place".Place place,
    imported!"dmd.mtype".TypeStruct structType,
    size_t delegate(void* bodyAddress) @safe identityOfObjectBody,
) @safe {
    import quickbite.backends.interpreter.layout: structFields;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    Value[] fields;
    foreach (field; structFields(structType))
        fields ~= readValue(place.field(field), identityOfObjectBody);

    return AggregateValue.reconstructStruct(structTypeName(structType), fields);
}


// The inverse of `readValue`: writes `value`'s scalar leaves into `place`
// through the identical field-by-field/element-by-element composition --
// scalar leaves via `Place.storeScalar`, a slice-typed place through
// `writeSliceValue` below (new backing storage, elements written, then the
// `{ length, ptr }` header written into `place` last -- see its own header
// comment for the ordering argument and the storage's lifetime), and
// everything else unsupported for exactly the reasons `readValue`'s own
// comment gives, with one addition: a class-typed place stays refused here
// too, even though `readValue` now composes one. Reading a class only needs
// the reference this place already stores (`Place.deref` follows it);
// writing one would need to STORE a reference, and the only legal
// reference for a given object identity is the address `object_table.
// ObjectTable` handed out for it when the object was created -- knowledge
// this module has no access to, and should not guess at. That wiring
// (minting/looking up an identity's body address and storing it here)
// belongs to whichever later slice connects class locals to `impl.d`'s
// frame mirror, not to this place-composition layer. Writing an
// already-allocated body's OWN fields (once its address is known) is
// `writeClassBody` below, the write-side counterpart of `readValue`'s class
// arm. A union-typed place writes ONE member's bytes rather than recursing
// every field the way a non-union struct does, and refuses outright the
// unions that single write cannot honestly stand in for -- see
// `writeUnionValue`/`isComposableUnion`'s own header comments. A
// pointer-typed place composes symmetrically with `readValue`'s pointer
// arm: `Value.isPointer` carries a host address and `Value.null_` carries
// the null address. `real` is a plain leaf here too
// (`writeRealBits`, via `isRealType`) -- see `readValue`'s own header
// comment for why it lives in this module rather than `native_scalar`'s
// shared codec.
public void writeValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
    import quickbite.backends.interpreter.layout:
        structFields, staticArrayLength, typeByteSize;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.runtime_value: Value;

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

    if (isFloatingBaseEnum(type))
    {
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

    auto structType = nonUnionStructOf(type);
    if (structType !is null) {
        foreach (index, field; structFields(structType))
            writeValue(place.field(field), AggregateValue.fieldAt(value, index));
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
            writeValue(place.index(i), AggregateValue.elementAt(value, i));
        return;
    }

    auto sliceType = type.isTypeDArray;
    if (sliceType !is null) {
        writeSliceValue(place, sliceType, value);
        return;
    }

    auto pointerType = type.isTypePointer;
    if (pointerType !is null) {
        if (!value.isPointer && value != Value.null_)
            throw new Exception(
                "quickbite.backends.interpreter.place_value.writeValue: "
                ~ "pointer place requires a pointer Value or null",
            );

        place.storeReference(pointerAddress(value));
        return;
    }

    auto classType = type.isTypeClass;
    if (classType !is null) {
        if (!value.isPointer && value != Value.null_)
            throw new Exception(
                "quickbite.backends.interpreter.place_value.writeValue: "
                ~ "class place requires an object pointer or null",
            );
        place.storeReference(pointerAddress(value));
        return;
    }

    if (type.isTypeDelegate !is null && value == Value.null_) {
        zeroBytes(place.address, typeByteSize(type));
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


// `Value.pointerAddress` is not `@safe`; this is the `@trusted` boundary.
// Called only once `writeValue`'s pointer or class arm has already checked
// `value` is `isPointer` or `Value.null_`, so this never reaches
// `pointerAddress`'s own throwing arm -- it always returns a real host
// address, or `null`.
private void* pointerAddress(in imported!"quickbite.backends.interpreter.runtime_value".Value value) @trusted {
    return value.pointerAddress;
}


// The inverse of `readValue`'s slice arm: allocates NEW backing storage
// (`native_array.NativeArray.allocate`, sized to `value.length`) for the
// elements rather than reusing whatever `place`'s own header already
// pointed at -- a written slice header is always a snapshot (`value.md`'s
// Containers contract), so there is no existing backing storage here to
// grow or reuse even when a shorter or longer array already lived at
// `place`. `NativeArray.allocate` itself picks the new block's scan policy
// from `layout.typeHasPointers` over `elementType` alone -- chosen once,
// at allocation, never defaulted, exactly the Containers contract's own
// rule; this function makes no separate scan decision of its own.
//
// Elements are written through the identical composition `readValue`'s
// slice arm reads them back through -- `Place.index`, not hand-rolled
// stride arithmetic over `array`'s block a second time. Since `array`'s
// own header does not exist anywhere yet (it is not `place`'s header:
// writing that is this function's LAST step, below), a throwaway scratch
// header block gives a `Place` for `.index` to follow: `array.
// writeSliceHeader(scratchHeader, 0)` writes `array`'s `{ length, ptr }`
// into it, then `elements.index(i)` reads that SAME header back out
// exactly as any other slice place's `.index` would, landing on element
// `i`'s real address inside `array`'s own block. The scratch header itself
// is never read again once this function returns; only `array`'s block
// survives, addressed from `place`'s own header instead.
//
// The header write into `place` itself comes LAST, after every element
// has already been written successfully into `array` -- storage nothing
// else can yet see, since no guest-visible location points at it until
// then. An element `writeValue` cannot compose -- a class or `real`
// element (or a nested aggregate containing one) throws from deep in that
// recursion, before `place`'s own header
// is ever touched -- so a non-composable element refuses the WHOLE write,
// leaving `place` exactly as it was, never a partially written array
// visible through it.
//
// Lifetime: once this function returns, the only thing keeping `array`'s
// block reachable from a GC root is `place`'s own header, just written --
// which only actually keeps it alive if `place` itself lives inside a
// block the collector scans. The final `array.writeSliceHeader(place.
// address)` call enforces exactly that: it refuses to write a live GC
// pointer into a destination the GC does not scan (see its own header
// comment in `native_array.d`), the one case this function deliberately
// does NOT paper over -- a genuinely unscanned destination is a caller
// bug (every real caller's destination is scanned already, per that
// comment's own argument), not a case for this function to route around.
//
// `Value.null_` -- a null slice, `int[] xs = null` -- is a length of zero,
// not an error: `Value.length` itself throws "Expected array." for it,
// which would make this arm refuse a value `readValue`'s own slice arm
// hands straight back (it reads a `{ 0, null }` header as an empty array,
// never as `Value.null_`). Treating it as empty is what makes the two
// directions agree; D itself draws no observable distinction between a
// null and an empty slice beyond `is null`, which no header this module
// writes can carry back anyway.
private void writeSliceValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    imported!"dmd.mtype".TypeDArray sliceType,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) @safe {
    import quickbite.backends.interpreter.native_array: NativeArray;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    const length = value == Value.null_ ? 0 : AggregateValue.elementCount(value);

    auto elementType = sliceType.next;
    auto array = NativeArray.allocate(elementType, length);

    auto scratchHeader = NativeBlock.allocate(
        NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    array.writeSliceHeader(scratchHeader, 0);
    auto elements = Place(scratchHeader.address, sliceType);

    foreach (i; 0 .. length)
        writeValue(elements.index(i), AggregateValue.elementAt(value, i));

    array.writeSliceHeader(place.address);
}


// `value` is `structValueAt`'s own shape for a union -- one entry per
// declared member -- and this writes exactly ONE of those entries: the
// WIDEST declared member's own bytes, leaving every other entry
// unconsulted. Writing every entry back field by field, the way the
// non-union struct arm of `writeValue` does, would make the LAST declared
// member win regardless of which one the caller actually meant, and a
// member narrower than a later sibling would leave that sibling's own
// trailing bytes as whatever was already at `place` rather than what
// `value` says they should be. Ties are broken by picking the first
// declared member at the max width, an arbitrary but deterministic choice.
//
// Writing one member and ignoring the rest is only HONEST when both halves
// of `isComposableUnion` below hold -- every other entry is genuinely a
// reinterpretation of the written member's bytes, and the written member
// covers every byte any member reads. That predicate is `isPlaceComposable`'s
// own union arm, so a union this declines is never written by
// `impl.d`'s mirror and never verified by it either; the assertion below
// pins that agreement for a direct caller, and it throws (a decline, an
// `Exception`) rather than indexing an empty member list the way an
// earlier version of this function did for `union U {}`, which killed the
// whole interpreter with an `ArrayIndexError` -- an `Error`, on an
// ordinary D program the mirror is only supposed to shadow.
private void writeUnionValue(
    imported!"quickbite.backends.interpreter.place".Place place,
    imported!"dmd.mtype".TypeStruct unionType,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) @safe {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.layout: structFields;

    if (!isComposableUnion(unionType))
        throw new Exception(
            "quickbite.backends.interpreter.place_value.writeValue: "
            ~ "union place whose single widest-member write cannot stand "
            ~ "in for the whole union",
        );

    const widestIndex = widestUnionFieldIndex(unionType);
    writeValue(
        place.field(structFields(unionType)[widestIndex]),
        AggregateValue.fieldAt(value, widestIndex),
    );
}


// Which of `unionType`'s own `layout.structFields` `writeUnionValue`
// writes: the first declared member of maximum `layout.typeByteSize`.
// `-1` when there are none at all -- `union U {}` is legal D, and a union
// with no member has no byte pattern for a single-member write to stand in
// for, so `isComposableUnion` declines it rather than letting the write
// index a member that does not exist.
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


// Whether `writeUnionValue`'s "write the widest member, ignore every other
// entry" semantics is actually equivalent to writing the union -- the
// shared gate `isPlaceComposable`'s union arm and `writeUnionValue` itself
// both ask, so a declined union is neither written nor verified. Three
// conditions, each closing a way the single write silently loses bytes the
// boxed `Value` claims:
//
// - There IS a widest member (`widestUnionFieldIndex >= 0`).
// - Every member is one both boxed union writers keep a faithful
//   reinterpretation of its siblings (`isUnionMemberReDerivable`). Without
//   this the ignored entries are not redundant, they are contradictory:
//   `union U { real r; long l; }` after `u.l = 42` carries `r = real.nan`
//   (nothing re-derives a `real` sibling), and `real` being the wider
//   member, the write would splat NaN's bytes over the `l` the guest just
//   assigned.
// - The widest member's own `writeValue` covers every byte of its type
//   (`writeCoversWholeType`). Without this a padded widest member leaves
//   bytes a same-width sibling reads as live data untouched:
//   `union U { S s; ubyte[16] x; }` with `struct S { long l; byte b; }`
//   ties at 16, `s` wins, and its field-by-field write never touches bytes
//   9..15 -- which are `x[9 .. 16]`.
//
// A union this declines is one whose boxed value stays the sole authority,
// costing mirror coverage and nothing else. The alternative -- writing the
// widest member anyway -- is invisible to the verified mirror's byte
// assertion, since the verify side recomputes through this same function
// and lands on the identical wrong bytes, and becomes a wrong answer the
// moment native storage becomes the authority.
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


// Whether a union member of `type` is one every boxed union write path in
// this codebase re-derives from the union's own bytes, so that the boxed
// `Value`'s entry for it can never contradict its siblings. The set is
// deliberately a subset of `isPlaceComposable`'s -- a member answering
// `true` here always composes, which the `out` contract below checks
// rather than leaving it as a claim two functions must independently
// honour: a native scalar `writeValue` writes (`isWritableNativeScalar`),
// a static array of those, or a non-union struct built recursively from
// them.
//
// The excluded shapes are excluded because `impl.d`'s `withUnionFieldWrite`
// -- the walker's only union field-write path -- re-derives exactly a
// native-scalar, non-union-struct, or scalar-element-static-array sibling
// and leaves every other member on its own prior boxed value. `real` is
// deliberately not `native_scalar.isNativeScalarType` (that module's own
// header comment), a pointer is not a scalar at all, and a nested union is
// skipped explicitly there -- so all three keep a stale entry across a
// sibling's write. `impl.d`'s union DEFAULT path
// (`unionSiblingDefaultFieldValue`) declines the same shapes and defaults
// them independently, which is how `union U { real r; long l; }` gets a
// `real.nan` entry beside a zero `long` one before any write at all.
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
    // Over-declining is the right bias: the union merely stays unmirrored,
    // whereas accepting it routes `u.s.b = 1.5f` through the non-union
    // receiver path, leaves the boxed sibling stale, and a later `ref`
    // bind verifies that stale snapshot against the sibling's bytes.
    auto fields = structFields(structType);
    if (!fieldsAreDisjoint(fields))
        return false;

    foreach (field; fields)
        if (!isUnionMemberReDerivable(declaredType(field)))
            return false;

    return true;
}


// Whether `writeValue` at a place of `type` writes every one of
// `layout.typeByteSize(type)` bytes -- a fact about THIS module's own
// writer, recursing the identical dispatch `writeValue` does so the two
// cannot drift. Only the union arm needs it (see `isComposableUnion`):
// everywhere else a byte no field or element owns is padding nothing reads,
// and both the mirror slot and `assertFrameMirror`'s comparison scratch
// start out zeroed (`NativeBlock.allocate`'s own contract), so untouched
// padding compares equal on both sides.
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

    if (isWritableNativeScalar(type) || isRealType(type) || type.isTypePointer !is null)
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


// Writes a boxed class `Value`'s fields into an already-allocated object
// body -- the write-side counterpart of `readValue`'s class arm, and the
// inverse of the same field composition: `bodyPlace` is a place AT the
// object body's own address, keeping the class type (the same shape
// `Place.deref` produces, and `object_table.ObjectTable.storageFor`'s
// address paired with `place.placeAt` gives directly), not a place holding
// a reference to it. There is no reference to store here -- unlike
// `writeValue`, which refuses a class-typed place because it would have to
// invent or look up that reference -- so this has no such gap for THIS
// object's own fields: the body's own address is already `bodyPlace.
// address`, supplied by whoever called this (`object_table.ObjectTable`).
//
// A class-typed FIELD is a second, nested instance of that exact gap one
// level down -- writing a reference into the field's own slot needs an
// object-body address for THAT identity too. `resolveObjectBody` is the
// explicit capability that closes it: a caller-supplied identity-to-address
// function (`impl.d` satisfies it from its own `classObjectTable`, the
// identical `ObjectTable` this function's own top-level address already
// came from), rather than this module importing the walker or holding any
// table of its own -- the same "caller supplies a resolver, this module
// stays pure composition" shape `lvalue_place.placeOfLvalue`'s own
// `resolveBase`/`evalIndex` parameters already use. A `null` field value
// stores a `null` reference and recurses no further, matching `readValue`'s
// own null-reference short circuit. A non-`null` field value that is not a
// class object, or carries no real identity (`classIdentity == 0`), has
// nothing this function can resolve, so it throws rather than guessing.
//
// Cycle guard: `writeClassBodyImpl` threads a `visiting` set exactly like
// `readClassValue`'s own (see its header comment for the DFS "currently
// being written" reasoning) so a live cycle declines with a clear exception
// instead of recursing forever. Unlike `writeSliceValue`'s "never touch the
// destination until every element is written" guarantee, a cycle detected
// here may have already written PRECEDING fields (of this object or an
// ancestor's) before the throw -- an all-or-nothing guarantee would need a
// separate, side-effect-free pre-pass this module has no reason to grow,
// since `writeClassBody`'s only real call site (`impl.d`'s
// `mirrorClassToFrame`) already runs the pure, cycle-aware
// `classBodyShapeMatches` gate first and never reaches a cycle here at all;
// this function's own guard exists so a direct call (this module's own
// tests) still terminates rather than overflowing the stack.
public void writeClassBody(
    imported!"quickbite.backends.interpreter.place".Place bodyPlace,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    void* delegate(size_t identity, imported!"dmd.dclass".ClassDeclaration class_) @safe
        resolveObjectBody,
) @safe {
    writeClassBodyImpl(bodyPlace, value, resolveObjectBody, null);
}

private void writeClassBodyImpl(
    imported!"quickbite.backends.interpreter.place".Place bodyPlace,
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    void* delegate(size_t identity, imported!"dmd.dclass".ClassDeclaration class_) @safe
        resolveObjectBody,
    bool[size_t] visiting,
) @safe {
    import quickbite.backends.interpreter.layout: classFields;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    auto classType = bodyPlace.type.isTypeClass;
    if (classType is null)
        throw new Exception(
            "quickbite.backends.interpreter.place_value.writeClassBody: "
            ~ "bodyPlace must be a class-typed place",
        );

    const identity = cast(size_t) bodyPlace.address;
    if (identity in visiting)
        throw new Exception(
            "quickbite.backends.interpreter.place_value.writeClassBody: "
            ~ "cyclic class object graph",
        );
    visiting[identity] = true;
    scope(exit) visiting.remove(identity);

    foreach (index, field; classFields(classType.sym)) {
        auto fieldPlace = bodyPlace.field(field);
        auto fieldValue = AggregateValue.classFieldAt(value, index);

        if (fieldPlace.type.isTypeClass is null) {
            writeValue(fieldPlace, fieldValue);
            continue;
        }

        if (fieldValue == Value.null_) {
            fieldPlace.storeReference(null);
            continue;
        }

        if (!AggregateValue.isClass(fieldValue) || fieldValue.classIdentity == 0)
            throw new Exception(
                "quickbite.backends.interpreter.place_value.writeClassBody: "
                ~ "class-typed field requires a Value holding a class "
                ~ "object with a real identity, or null",
            );

        auto nestedClassType = fieldPlace.type.isTypeClass;
        auto nestedAddress =
            resolveObjectBody(fieldValue.classIdentity, nestedClassType.sym);
        fieldPlace.storeReference(nestedAddress);
        writeClassBodyImpl(
            Place(nestedAddress, fieldPlace.type), fieldValue, resolveObjectBody, visiting,
        );
    }
}


public bool isPlaceComposable(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

    if (isNativeScalarType(type))
        return true;

    if (isRealType(type))
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

    return false;
}


// Whether every one of `structType`'s own `layout.structFields` (in
// declaration order) is itself `isPlaceComposable` -- what
// `isPlaceComposable`'s struct arm asks, which is exactly what
// `writeValue`'s own struct arm needs, since it recurses once per field.
// A union asks the stricter `isComposableUnion` instead, for the reason
// that function's header gives.
//
// "In declaration order, one field each" is only true while those fields
// occupy DISJOINT bytes, so `fieldsAreDisjoint` gates the whole walk: DMD
// flattens an ANONYMOUS union's members into the enclosing struct's own
// `structFields` at OVERLAPPING offsets (`value.md`'s Unions section --
// and it is the offsets that are consulted here, never `overlapped`, since
// that flag is a derived fact about them, not a second source of truth).
// The enclosing declaration is still a plain `StructDeclaration`, so
// without this check the struct arm would treat the flattened members as
// independent storage, write every one of them over the same bytes in
// declaration order, and let the last win -- while the boxed `Value` keeps
// one entry per member, entries that for `union { real r; long l; }` after
// `s.l = 42` genuinely contradict each other (nothing re-derives a `real`
// sibling). A later `ref` bind composed into that storage then verifies a
// DIFFERENT member's snapshot against those bytes and asserts on a program
// the oracle runs.
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
// Answering `false` is a decline, and a deliberately over-eager one: any
// overlap at all refuses the whole enclosing type rather than trying to
// group the overlapping members back into the anonymous union DMD
// flattened and asking `isComposableUnion` of that group. An unmirrored
// local costs only coverage of storage nothing reads yet, while getting
// the grouping wrong crashes a correct program -- and the group that
// would most often pass such a gate is the one `writeValue` has no place
// to write through anyway, since a flattened member has no union-typed
// `Place` of its own. A true union's own `structFields` all sit at offset
// 0 and would fail this outright, which is why only the plain-struct and
// class-body arms ask it; a union asks `isComposableUnion`.
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


// Whether `class_`'s own fields (`layout.classFields`, base-to-derived) are
// all `isPlaceComposable` -- the class-body sibling of `isPlaceComposable`
// itself, answering "can `readValue`'s class arm and `writeClassBody` round
// trip this class's body without throwing", the same round-trip meaning
// `isPlaceComposable` already carries for a struct's fields. Deliberately
// reuses `isPlaceComposable` per field rather than growing a parallel
// dispatch, for the identical anti-drift reason `isPlaceComposable`'s own
// header gives.
//
// A field whose type is itself a class is the one exception, answering
// `true` unconditionally rather than delegating to `isPlaceComposable`
// (which still, deliberately, answers `false` for a class type -- see its
// own header comment: that predicate gates the plain composable-local
// mirror, unrelated to this one). `writeClassBody` now has a resolver
// capability to write a class-typed field's own reference (its own header
// comment), so the field's TYPE always composes; what can still fail is a
// VALUE-level fact -- an unresolvable identity, or a cycle -- neither of
// which this predicate can see (it takes a `ClassDeclaration`, not a
// `Value`), and neither of which is a TYPE question in the first place.
// `impl.d`'s `classBodyShapeMatches` is the value-level counterpart that
// catches those, called identically alongside this predicate by both
// `mirrorClassToFrame` and `assertClassFrameMirror` before either ever
// reaches `writeClassBody`. Answering `true` here unconditionally, rather
// than recursing into the referenced class's OWN `isClassBodyComposable`,
// is also what keeps this a plain, terminating TYPE-shape walk: DMD class
// declarations are free to reference themselves directly
// (`class Node { Node next; }`), and a class's own field TYPES form no
// well-founded recursion to bottom out on the way `isPlaceComposable`'s
// struct/array recursion does (a struct cannot contain itself by value,
// but a class field naming its own class is completely ordinary D).
public bool isClassBodyComposable(
    imported!"dmd.dclass".ClassDeclaration class_,
) @safe {
    import quickbite.backends.interpreter.layout: classFields, declaredType;

    auto fields = classFields(class_);

    // The class-body sibling of `allFieldsComposable`'s own identical gate
    // (its header comment): a class can declare an anonymous union too, and
    // DMD flattens its members into `classFields` at overlapping offsets
    // exactly as it does into a struct's.
    if (!fieldsAreDisjoint(fields))
        return false;

    foreach (field; fields) {
        auto fieldType = declaredType(field);
        if (fieldType.isTypeClass !is null)
            continue;

        if (!isPlaceComposable(fieldType))
            return false;
    }

    return true;
}


// `type` narrowed to `TypeStruct`, but only when it is not a union -- the
// shared "does `readValue`/`writeValue`/`isPlaceComposable` treat this as a
// field-composed struct" check all three recurse through, so the one place
// that decides "struct, not union" cannot drift between them.
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
// place `readValue`/`writeValue`/`isPlaceComposable` decide "union, not a
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
private ubyte[] sliceHeaderBytes(void* address, in size_t length) pure nothrow @trusted {
    return (cast(ubyte*) address)[0 .. length];
}


// Both addresses come from DMD-sized aggregate storage of the identical
// static type, checked by `writeValue` before this boundary.  Copying exactly
// that size is the whole-value assignment operation; recursive field writes
// would recreate a boxed aggregate traversal and lose union/padding bits.
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

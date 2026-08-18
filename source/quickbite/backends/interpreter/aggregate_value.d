module quickbite.backends.interpreter.aggregate_value;


private:


private alias NativeAggregate = imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate;

// Aggregate expression results always own or borrow DMD-layout storage. This
// surface keeps their typed construction and access separate from scalar
// ExpressionResult operations.
public struct AggregateValue {
    // Start an array construction in storage that the caller already owns.
    // Static-array elements are inline in that storage. A dynamic array needs
    // only its newly allocated backing block and header; the caller then
    // constructs each element through the header's typed indexed places.
    public static void initializeArray(
        imported!"quickbite.backends.interpreter.place".Place destination,
        in size_t length,
    ) @safe {
        import quickbite.backends.interpreter.layout: staticArrayLength;
        import quickbite.backends.interpreter.native_array: NativeArray;

        auto type = baseTypeOf(destination.type);
        if (auto staticArray = type.isTypeSArray) {
            if (length != staticArrayLength(staticArray))
                throw new Exception(
                    "AggregateValue.initializeArray static-array length mismatch.",
                );
            return;
        }

        auto dynamicArray = type.isTypeDArray;
        if (dynamicArray is null)
            throw new Exception("AggregateValue.initializeArray needs an array place.");

        NativeArray.allocate(dynamicArray.next, length)
            .writeSliceHeader(destination.address);
    }

    // Write a slice view into caller-owned header storage. The data address
    // remains the source array's address, so this does not rebuild elements or
    // detach aliases from the source cell.
    public static void initializeBorrowedArray(
        imported!"quickbite.backends.interpreter.place".Place destination,
        in size_t length,
        void* address,
    ) @safe {
        auto dynamicArray = baseTypeOf(destination.type).isTypeDArray;
        if (dynamicArray is null)
            throw new Exception(
                "AggregateValue.initializeBorrowedArray needs a slice place.",
            );

        borrowArray(dynamicArray.next, address, length)
            .writeSliceHeader(destination.address);
    }

    // Allocate the native owner for an array value. Callers construct each
    // element through the returned owner's typed places, in source order.
    // No expression carrier or element snapshot participates in that work.
    public static NativeAggregate allocateArray(
        imported!"dmd.mtype".Type type,
        in size_t length,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: placeAt;

        auto base = baseTypeOf(type);
        if (base.isTypeSArray !is null) {
            auto aggregate = NativeAggregate.allocate(type);
            initializeArray(placeAt(aggregate.storage, type), length);
            return aggregate;
        }

        auto slice = base.isTypeDArray;
        if (slice is null)
            throw new Exception("AggregateValue.allocateArray needs an array type.");

        auto backing = NativeArray.allocate(slice.next, length);
        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        backing.writeSliceHeader(header, 0);
        return NativeAggregate(type, header, backing.block);
    }

    // Construct a slice header that borrows an established native address.
    // The header is new, but its data remains the supplied address; callers
    // retain an owner when the address needs one.
    public static NativeAggregate borrowArrayOwner(
        imported!"dmd.mtype".Type type,
        in size_t length,
        const(void)* address,
        imported!"quickbite.backends.interpreter.native_block".NativeBlock retained =
            imported!"quickbite.backends.interpreter.native_block".NativeBlock.init,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        auto slice = baseTypeOf(type).isTypeDArray;
        if (slice is null)
            throw new Exception("AggregateValue.borrowArrayOwner needs a slice type.");

        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        borrowArray(slice.next, cast(void*) address, length).writeSliceHeader(header, 0);
        return retained.address is null
            ? NativeAggregate(type, header)
            : NativeAggregate(type, header, retained);
    }

    // Compatibility adapter for the aggregate-value unit test. Production
    // struct construction writes fields into their final typed places through
    // `Walker.constructStructLiteral` and never uses this field snapshot.
    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult reconstructStruct(
        imported!"dmd.mtype".Type type,
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult[] fields,
    ) @safe {
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: placeAt;
        import quickbite.backends.interpreter.place_value: writeValue;
        import quickbite.backends.interpreter.expression_result: ExpressionResult;
        import std.conv: text;

        auto structType = baseTypeOf(type).isTypeStruct;
        if (structType is null || fields.length != structFields(structType).length)
            throw new Exception(text(
                "AggregateValue.reconstructStruct field count mismatch: expected ",
                structType is null ? 0 : structFields(structType).length,
                ", got ",
                fields.length,
                ".",
            ));

        auto aggregate = NativeAggregate.allocate(type);
        auto destination = placeAt(aggregate.storage, type);
        foreach (index, field; structFields(structType))
            writeValue(destination.field(field), fields[index]);
        return ExpressionResult.nativeAggregateValue(aggregate);
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult reconstructArray(
        imported!"dmd.mtype".Type type,
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult[] elements,
    ) @safe {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;
        import quickbite.backends.interpreter.expression_result: ExpressionResult;

        auto aggregate = allocateArray(type, elements.length);
        auto destination = Place(aggregate.address, type);
        foreach (index, element; elements)
            writeValue(destination.index(index), element);
        return ExpressionResult.nativeAggregateValue(aggregate);
    }

    // Allocate the reference slot and body as one native owner. The caller
    // keeps it native while it initializes the body and records its identity.
    public static NativeAggregate allocateClass(
        imported!"dmd.mtype".Type type,
    ) @safe {
        import quickbite.backends.interpreter.layout: classInstanceByteSize;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;

        auto classType = baseTypeOf(type).isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception("AggregateValue.allocateClass needs a class type.");
        auto body = NativeBlock.allocate(
            classInstanceByteSize(classType.sym),
            NativeBlock.Scan.conservative,
        );
        auto reference = NativeBlock.allocate(
            (void*).sizeof,
            NativeBlock.Scan.conservative,
        );
        Place(reference.address, type).storeReference(body.address);
        return NativeAggregate(type, reference, body);
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult reconstructNativeArray(
        imported!"dmd.mtype".Type type,
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult[] elements,
        const(void)* address,
    ) @safe {
        import quickbite.backends.interpreter.expression_result: ExpressionResult;

        return ExpressionResult.nativeAggregateValue(
            borrowArrayOwner(type, elements.length, address),
        );
    }

    // An untyped view of an aggregate's own storage: the slice denotes the
    // same bytes rather than a copy, so writes through it are visible in the
    // source, and the source block is retained to keep the view valid.
    public static NativeAggregate nativeAggregateByteSlice(
        NativeAggregate source,
        imported!"dmd.mtype".Type type,
    ) @safe {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        auto slice = baseTypeOf(type).isTypeDArray;
        if (slice is null)
            throw new Exception(
                "AggregateValue.nativeAggregateByteSlice needs a slice type.",
            );

        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        borrowArray(
            slice.next,
            source.address,
            typeByteSize(source.type),
        ).writeSliceHeader(header, 0);
        return NativeAggregate(
            type,
            header,
            source.storage,
        );
    }

    // A class instance's initializer bytes are the object body itself viewed
    // as an untyped span. The result borrows the body rather than copying it
    // and retains that block, so the view stays valid for as long as it is
    // reachable.
    public static NativeAggregate classBodyByteSlice(
        NativeAggregate source,
        imported!"dmd.mtype".Type type,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        auto slice = baseTypeOf(type).isTypeDArray;
        if (slice is null || baseTypeOf(source.type).isTypeClass is null)
            throw new Exception(
                "AggregateValue.classBodyByteSlice needs class and slice types.",
            );

        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        borrowArray(
            slice.next,
            source.retained.address,
            source.retained.byteLength,
        ).writeSliceHeader(header, 0);
        return NativeAggregate(
            type,
            header,
            source.retained,
        );
    }

    public static NativeAggregate slice(
        NativeAggregate aggregate,
        imported!"dmd.mtype".Type resultType,
        in size_t lower,
        in size_t upper,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: placeAt;

        if (lower > upper || upper > placeAt(aggregate.storage, aggregate.type).arrayLength)
            throw new Exception("AggregateValue.slice range is invalid.");

        auto sourceType = baseTypeOf(aggregate.type).isTypeDArray;
        auto sourceStaticArray = baseTypeOf(aggregate.type).isTypeSArray;
        auto resultSlice = baseTypeOf(resultType).isTypeDArray;
        if ((sourceType is null && sourceStaticArray is null) || resultSlice is null)
            throw new Exception("AggregateValue.slice needs dynamic-array types.");

        // A static-array slice has no stored header to borrow from. Compose
        // its first selected element from the typed inline storage and retain
        // that storage behind the dynamic result header, so `s.arr[]` remains
        // a view of `s` rather than a recursive array copy.
        if (sourceStaticArray !is null) {
            import quickbite.backends.interpreter.place: Place;

            auto header = NativeBlock.allocate(
                NativeArray.sliceHeaderByteLength,
                NativeBlock.Scan.conservative,
            );
            borrowArray(
                resultSlice.next,
                Place(aggregate.address, aggregate.type).index(lower).address,
                upper - lower,
            ).writeSliceHeader(header, 0);
            return NativeAggregate(
                resultType,
                header,
                aggregate.storage,
            );
        }

        auto source = readSliceHeader(aggregate.storage);
        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        borrowArray(
            resultSlice.next,
            addressOffset(source.ptr, lower * elementByteSize(sourceType.next)),
            upper - lower,
        ).writeSliceHeader(header, 0);
        return NativeAggregate(
            resultType,
            header,
            aggregate.retained,
        );
    }

    public static imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate native(
        imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        return value.nativeAggregate;
    }

    // Copies the complete native-layout value at `address` into a freshly
    // rooted native owner. It is the by-value read operation for struct,
    // static-array, slice-header, class-reference, and AA-handle places.
    public static NativeAggregate copyFromAddress(
        imported!"dmd.mtype".Type type,
        void* address,
        imported!"quickbite.backends.interpreter.native_block".NativeBlock retained =
            imported!"quickbite.backends.interpreter.native_block".NativeBlock.init,
    ) @safe {
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;

        auto aggregate = NativeAggregate.allocate(type);
        aggregate.storage.bytes[] = bytesAt(address, aggregate.storage.byteLength)[];
        return retained.address is null
            ? aggregate
            : NativeAggregate(type, aggregate.storage, retained);
    }

    // The source is an ABI buffer whose caller has already established as at
    // least this Type's DMD byte size.  Copying it as one span retains union
    // overlap, padding, and slice headers without imposing a field model on
    // the ABI boundary.
    public static NativeAggregate copyFromBytes(
        imported!"dmd.mtype".Type type,
        in ubyte[] bytes,
    ) @safe {
        auto aggregate = NativeAggregate.allocate(type);
        if (bytes.length < aggregate.storage.byteLength)
            throw new Exception("AggregateValue.copyFromBytes source is too short.");
        aggregate.storage.bytes[] = bytes[0 .. aggregate.storage.byteLength];
        return aggregate;
    }

    public static bool isStruct(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        return value.isNativeAggregate &&
            baseTypeOf(native(value).type).isTypeStruct !is null;
    }

    public static bool isArray(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        if (!value.isNativeAggregate)
            return false;
        auto type = baseTypeOf(native(value).type);
        return type.isTypeSArray !is null || type.isTypeDArray !is null;
    }

    // Aggregate reads stay behind this boundary and use native-layout handles
    // in one place. Scalars deliberately remain ExpressionResult operations.
    // An associative-array's `.length` is never read through here: `aa.length`
    // is always lowered to a call to `object._d_aaLen!(K, V)(aa)`
    // (`TypeAArray.dotExp`, typesem.d) before the interpreter sees it, and an
    // AA value itself is a plain pointer handle, never a native aggregate.
    public static size_t length(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.length needs a native aggregate.");
        auto aggregate = native(value);
        auto type = baseTypeOf(aggregate.type);
        if (type.isTypeSArray !is null || type.isTypeDArray !is null)
            return elementCount(value);
        throw new Exception("AggregateValue.length needs an array aggregate.");
    }

    public static size_t fieldCount(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        import quickbite.backends.interpreter.layout: structFields;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.fieldCount needs a native struct.");
        return structFields(baseTypeOf(native(value).type).isTypeStruct).length;
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult fieldAt(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in size_t index,
    ) @safe {
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.fieldAt needs a native struct.");
        auto aggregate = native(value);
        return readValue(Place(aggregate.address, aggregate.type).field(
            structFields(baseTypeOf(aggregate.type).isTypeStruct)[index],
        ));
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult classFieldAt(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in size_t index,
    ) @safe {
        import quickbite.backends.interpreter.layout: classFields;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.classFieldAt needs a native class.");
        auto aggregate = native(value);
        auto classType = baseTypeOf(aggregate.type).isTypeClass;
        return readValue(Place(nativeClassBodyAddress(value), aggregate.type).field(
            classFields(classType.sym)[index],
        ));
    }

    public static size_t elementCount(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;
        import quickbite.backends.interpreter.layout: staticArrayLength;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.elementCount needs a native array.");
        auto aggregate = native(value);
        auto type = baseTypeOf(aggregate.type);
        if (auto staticArray = type.isTypeSArray)
            return staticArrayLength(staticArray);
        if (type.isTypeDArray !is null)
            return readSliceHeaderBytes(
                aggregate.storage.bytes[0 .. NativeArray.sliceHeaderByteLength],
            ).length;
        throw new Exception("AggregateValue.elementCount needs an array aggregate.");
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult elementAt(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in size_t index,
    ) @safe {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;
        import quickbite.backends.interpreter.expression_result: ExpressionResult;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.elementAt needs a native array.");
        auto aggregate = native(value);
        auto element = Place(aggregate.address, aggregate.type).index(index);
        // `void` has no value to decode, so an element of a `void[]` is just
        // the byte at that position -- which is all a `void[]` copy (allocator
        // storage, an initializer image) ever moves.
        auto array = baseTypeOf(aggregate.type).isTypeDArray;
        return array !is null && baseTypeOf(array.next).ty == TY.Tvoid
            ? ExpressionResult(byteAt(element.address))
            : readValue(element);
    }

    // The native aggregate owns the complete static-array bytes or the
    // dynamic-array header whose data pointer Place.index follows. This is
    // the one address-of route for aggregate elements; it does not create a
    // detached element snapshot.
    public static void* elementAddress(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in size_t index,
    ) @safe {
        import quickbite.backends.interpreter.place: Place;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.elementAddress needs a native aggregate.");
        auto aggregate = native(value);
        return Place(aggregate.address, aggregate.type).index(index).address;
    }

    public static void* nativeClassBodyAddress(NativeAggregate aggregate) @safe {
        import quickbite.backends.interpreter.place: Place;

        if (baseTypeOf(aggregate.type).isTypeClass is null)
            throw new Exception("AggregateValue.nativeClassBodyAddress needs a class aggregate.");
        return Place(aggregate.address, aggregate.type).deref.address;
    }

    public static void* nativeClassBodyAddress(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.nativeClassBodyAddress needs a native aggregate.");
        return nativeClassBodyAddress(native(value));
    }

    public static bool hasClassFieldNamed(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in string name,
    ) @safe {
        import quickbite.backends.interpreter.layout: classFields, fieldName;

        if (!value.isNativeAggregate)
            return false;
        auto classType = baseTypeOf(native(value).type).isTypeClass;
        foreach (field; classFields(classType.sym))
            if (fieldName(field) == name)
                return true;
        return false;
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult classFieldNamed(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in string name,
    ) @safe {
        import quickbite.backends.interpreter.layout: classFields, fieldName;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.classFieldNamed needs a native class.");
        auto classType = baseTypeOf(native(value).type).isTypeClass;
        foreach (index, field; classFields(classType.sym))
            if (fieldName(field) == name)
                return classFieldAt(value, index);
        throw new Exception("AggregateValue.classFieldNamed: no such class field.");
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult withClassFieldNamed(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in string name,
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult field,
    ) {
        import quickbite.backends.interpreter.layout: classFields, fieldName;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.withClassFieldNamed needs a native class.");
        auto aggregate = native(value);
        auto classType = baseTypeOf(aggregate.type).isTypeClass;
        foreach (declaration; classFields(classType.sym))
            if (fieldName(declaration) == name) {
                writeValue(
                    Place(nativeClassBodyAddress(value), aggregate.type).field(declaration),
                    field,
                );
                return value;
            }
        throw new Exception("AggregateValue.withClassFieldNamed: no such class field.");
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult withArrayElement(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult element,
    ) {
        import dmd.astenums: TY;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.withArrayElement needs a native array.");
        auto aggregate = native(value);
        auto place = Place(aggregate.address, aggregate.type).index(index);
        // `void` has no value the place codec could store, so writing an
        // element of a `void[]` retypes the place to `ubyte` and stores the
        // raw byte instead -- matching how `elementAt` above reads one.
        if (place.type.toBasetype.ty == TY.Tvoid)
            place = Place(place.address, Type.tuns8);
        writeValue(place, element);
        return value;
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult withAppendedArrayElement(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult element,
    ) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        if (!value.isNativeAggregate)
            throw new Exception(
                "AggregateValue.withAppendedArrayElement needs a native array.",
            );

        const length = elementCount(value);
        auto appended = withArrayLength(value, length + 1);
        auto aggregate = native(appended);
        writeValue(Place(aggregate.address, aggregate.type).index(length), element);
        return appended;
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult withArrayLength(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in size_t newLength,
    ) {
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.expression_result: ExpressionResult;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.withArrayLength needs a native array.");

        auto aggregate = native(value);
        auto slice = baseTypeOf(aggregate.type).isTypeDArray;
        if (slice is null)
            throw new Exception("AggregateValue.withArrayLength needs a dynamic array.");

        const oldLength = elementCount(value);
        auto array = NativeArray.borrow(
            slice.next,
            cast(void*) Place(aggregate.address, aggregate.type).sliceDataPointer,
            oldLength,
        );
        if (newLength <= oldLength) {
            array.setLength(newLength);
            array.writeSliceHeader(aggregate.address);
            return value;
        }

        if (array.tryExpandUsedTo(newLength)) {
            array.writeSliceHeader(aggregate.address);
            return value;
        }

        auto grown = NativeArray.allocate(slice.next, newLength);
        grown.block.bytes[0 .. array.block.byteLength] = array.block.bytes[];
        grown.writeSliceHeader(aggregate.address);
        return ExpressionResult.nativeAggregateValue(NativeAggregate(
            aggregate.type,
            aggregate.storage,
            grown.block,
        ));
    }

    public static imported!"quickbite.backends.interpreter.expression_result".ExpressionResult withStructField(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult field,
    ) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;
        import quickbite.backends.interpreter.layout: structFields;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.withStructField needs a native struct.");
        auto aggregate = native(value);
        writeValue(
            Place(aggregate.address, aggregate.type).field(
                structFields(baseTypeOf(aggregate.type).isTypeStruct)[index],
            ),
            field,
        );
        return value;
    }

    public static const(void)* nativeArrayAddress(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;

        if (!value.isNativeAggregate)
            return null;
        auto aggregate = native(value);
        if (baseTypeOf(aggregate.type).isTypeDArray is null)
            return null;
        return readSliceHeaderBytes(
            aggregate.storage.bytes[0 .. NativeArray.sliceHeaderByteLength],
        ).ptr;
    }
}


// DMD's Type API is not annotated @safe; this is a read-only type query.
private imported!"dmd.mtype".Type baseTypeOf(imported!"dmd.mtype".Type type) @trusted {
    return type.toBasetype;
}


// The caller supplies a live DMD-sized guest object and copies exactly its
// established byte length into owned NativeBlock storage.
private ubyte[] bytesAt(void* address, in size_t length) pure nothrow @trusted {
    return (cast(ubyte*) address)[0 .. length];
}


// `Place.index` produced this address by bounds-checking the index against
// the slice header's own length, so the single byte at it is readable guest
// storage.
private ubyte byteAt(void* address) pure nothrow @trusted {
    return *cast(ubyte*) address;
}


// The caller owns the header destination and vouches that this guest address
// remains live for the resulting borrowed slice view.
private imported!"quickbite.backends.interpreter.native_array".NativeArray borrowArray(
    imported!"dmd.mtype".Type elementType,
    void* address,
    in size_t length,
) @trusted {
    import quickbite.backends.interpreter.native_array: NativeArray;

    return NativeArray.borrow(elementType, address, length);
}


private imported!"quickbite.backends.interpreter.native_array".SliceHeaderBytes readSliceHeader(
    imported!"quickbite.backends.interpreter.native_block".NativeBlock block,
) @safe {
    import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;

    return readSliceHeaderBytes(block.bytes[0 .. NativeArray.sliceHeaderByteLength]);
}


private size_t elementByteSize(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize;

    return typeByteSize(type);
}


// The offset was bounds-checked against the source slice before this byte
// address calculation, and is already scaled by the DMD element size.
private void* addressOffset(void* address, in size_t offset) pure nothrow @trusted {
    return cast(ubyte*) address + offset;
}

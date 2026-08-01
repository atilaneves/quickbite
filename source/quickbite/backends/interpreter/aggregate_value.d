module quickbite.backends.interpreter.aggregate_value;


private:


private alias NativeAggregate = imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate;

// The boxed aggregate boundary.  `RuntimeValue` still owns the interim
// recursive representation, while consumers reconstruct and visit aggregate
// rvalues through this narrow surface.  The native-handle migration replaces
// this surface's implementation without making `place` depend on a new
// `RuntimeValue` alternative.
public struct AggregateValue {
    // Typed constructors are the authority-switch entry points.  Their Type
    // parameter is mandatory: aggregate layout never comes from a display
    // name or the recursive shape of a RuntimeValue.
    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructStruct(
        imported!"dmd.mtype".Type type,
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] fields,
    ) @safe {
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: placeAt;
        import quickbite.backends.interpreter.place_value: writeValue;
        import quickbite.backends.interpreter.runtime_value: Value;
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

        auto aggregate = allocateAggregate(type);
        auto destination = placeAt(aggregate.storage, type);
        foreach (index, field; structFields(structType))
            writeValue(destination.field(field), fields[index]);
        return Value.nativeAggregateValue(aggregate);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructArray(
        imported!"dmd.mtype".Type type,
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] elements,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;
        import quickbite.backends.interpreter.runtime_value: Value;

        auto base = baseTypeOf(type);
        if (base.isTypeSArray !is null) {
            auto aggregate = allocateAggregate(type);
            auto destination = Place(aggregate.address, type);
            foreach (index, element; elements)
                writeValue(destination.index(index), element);
            return Value.nativeAggregateValue(aggregate);
        }

        auto slice = base.isTypeDArray;
        if (slice is null)
            throw new Exception("AggregateValue.reconstructArray needs an array type.");

        auto backing = NativeArray.allocate(slice.next, elements.length);
        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        backing.writeSliceHeader(header, 0);
        auto destination = Place(header.address, type);
        foreach (index, element; elements)
            writeValue(destination.index(index), element);
        return Value.nativeAggregateValue(NativeAggregate(type, header, backing.block));
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructAssocArray(
        imported!"dmd.mtype".Type type,
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] keys,
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] values,
    ) @safe {
        import quickbite.backends.interpreter.native_assoc_array: allocateValue, headerAt;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;
        import quickbite.backends.interpreter.runtime_value: Value;

        if (keys.length != values.length)
            throw new Exception("AggregateValue.reconstructAssocArray key/value count mismatch.");

        auto aggregate = allocateValue(type);
        auto header = headerAt(aggregate.address);
        foreach (index, key; keys) {
            auto keySlot = allocateTypedBlock(header.keyType);
            writeValue(Place(keySlot.address, header.keyType), key);
            bool found;
            auto valueAddress = header.getOrAdd(keySlot.address, found);
            writeValue(Place(valueAddress, header.valueType), values[index]);
        }
        return Value.nativeAggregateValue(aggregate);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value allocateClass(
        imported!"dmd.mtype".Type type,
    ) @safe {
        import quickbite.backends.interpreter.layout: classInstanceByteSize;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.runtime_value: Value;

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
        return Value.nativeAggregateValue(NativeAggregate(type, reference, body));
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value borrowClass(
        imported!"dmd.mtype".Type type,
        void* bodyAddress,
    ) @trusted {
        import quickbite.backends.interpreter.layout: classInstanceByteSize;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.runtime_value: Value;

        auto classType = baseTypeOf(type).isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception("AggregateValue.borrowClass needs a class type.");
        auto reference = NativeBlock.allocate(
            (void*).sizeof,
            NativeBlock.Scan.conservative,
        );
        Place(reference.address, type).storeReference(bodyAddress);
        auto body = NativeBlock.borrow(
            bodyAddress,
            classInstanceByteSize(classType.sym),
        );
        return Value.nativeAggregateValue(NativeAggregate(type, reference, body));
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructNativeArray(
        imported!"dmd.mtype".Type type,
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] elements,
        const(void)* address,
    ) @safe {
        return reconstructNativeArrayWithLength(type, elements.length, address);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructNativeArrayWithLength(
        imported!"dmd.mtype".Type type,
        in size_t length,
        const(void)* address,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.runtime_value: Value;

        auto slice = baseTypeOf(type).isTypeDArray;
        if (slice is null)
            throw new Exception("AggregateValue.reconstructNativeArray needs a slice type.");

        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        borrowArray(slice.next, cast(void*) address, length).writeSliceHeader(header, 0);
        return Value.nativeAggregateValue(NativeAggregate(type, header));
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value slice(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        imported!"dmd.mtype".Type resultType,
        in size_t lower,
        in size_t upper,
    ) @safe {
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.runtime_value: Value;

        if (!value.isNativeAggregate)
            throw new Exception("Native AggregateValue.slice needs a native aggregate.");
        if (lower > upper || upper > elementCount(value))
            throw new Exception("AggregateValue.slice range is invalid.");

        auto aggregate = native(value);
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
            return Value.nativeAggregateValue(NativeAggregate(
                resultType,
                header,
                aggregate.storage,
            ));
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
        return Value.nativeAggregateValue(NativeAggregate(
            resultType,
            header,
            aggregate.retained,
        ));
    }

    // `RuntimeValue.nativeAggregate` currently lacks a const overload; this
    // cast only restores mutability to read the copied handle, never guest
    // storage, and its tagged accessor still rejects every other alternative.
    public static imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate native(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @trusted {
        return (cast(imported!"quickbite.backends.interpreter.runtime_value".Value) value)
            .nativeAggregate;
    }

    // Copies the complete native-layout value at `address` into a freshly
    // rooted aggregate result.  It is the by-value read operation for struct,
    // static-array, slice-header, class-reference, and AA-handle places.
    public static imported!"quickbite.backends.interpreter.runtime_value".Value copyFromAddress(
        imported!"dmd.mtype".Type type,
        void* address,
        imported!"quickbite.backends.interpreter.native_block".NativeBlock retained =
            imported!"quickbite.backends.interpreter.native_block".NativeBlock.init,
    ) @safe {
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
        import quickbite.backends.interpreter.runtime_value: Value;

        auto aggregate = allocateAggregate(type);
        aggregate.storage.bytes[] = bytesAt(address, aggregate.storage.byteLength)[];
        return Value.nativeAggregateValue(retained.address is null
            ? aggregate
            : NativeAggregate(type, aggregate.storage, retained));
    }

    // The source is an ABI buffer whose caller has already established as at
    // least this Type's DMD byte size.  Copying it as one span retains union
    // overlap, padding, and slice headers; reconstructing fields here would
    // reintroduce recursive aggregate reification at the FFI boundary.
    public static imported!"quickbite.backends.interpreter.runtime_value".Value copyFromBytes(
        imported!"dmd.mtype".Type type,
        in ubyte[] bytes,
    ) @safe {
        import quickbite.backends.interpreter.runtime_value: Value;

        auto aggregate = allocateAggregate(type);
        if (bytes.length < aggregate.storage.byteLength)
            throw new Exception("AggregateValue.copyFromBytes source is too short.");
        aggregate.storage.bytes[] = bytes[0 .. aggregate.storage.byteLength];
        return Value.nativeAggregateValue(aggregate);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructStruct(
        in string typeName,
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] fields,
    ) @safe pure {
        import quickbite.backends.interpreter.runtime_value: Value;

        return Value.structValue(typeName, fields);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructArray(
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] elements,
    ) @safe pure {
        import quickbite.backends.interpreter.runtime_value: Value;

        return Value.arrayValue(elements);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value slice(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t lower,
        in size_t upper,
    ) @safe pure {
        return value.arraySlice(lower, upper);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructClass(
        in string typeName,
        in string[] typeNames,
        in string[] fieldNames,
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] fields,
        in size_t identity = 0,
    ) @safe pure {
        import quickbite.backends.interpreter.runtime_value: Value;

        return Value.classValue(typeName, typeNames, fieldNames, fields, identity);
    }

    public static bool isStruct(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate)
            return baseTypeOf(native(value).type).isTypeStruct !is null;
        return value.isStruct;
    }

    public static bool isArray(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate) {
            auto type = baseTypeOf(native(value).type);
            return type.isTypeSArray !is null || type.isTypeDArray !is null;
        }
        return value.isArray;
    }

    public static bool isClass(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        return value.isNativeAggregate
            ? baseTypeOf(native(value).type).isTypeClass !is null
            : value.isClassObject;
    }

    // Aggregate reads stay behind this boundary so the authority switch can
    // replace recursive RuntimeValue access with native-layout handles in one
    // place. Scalars deliberately remain RuntimeValue operations.
    public static size_t length(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate) {
            auto aggregate = native(value);
            auto type = baseTypeOf(aggregate.type);
            if (type.isTypeAArray !is null) {
                import quickbite.backends.interpreter.native_assoc_array: headerAt;

                return headerAt(aggregate.address).length;
            }
            if (type.isTypeSArray !is null || type.isTypeDArray !is null)
                return elementCount(value);
        }
        return value.length;
    }

    public static size_t classIdentity(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        // Native class identity is its body address, consumed directly by
        // pointer paths. The boxed object-table namespace deliberately has
        // no entry for it, so legacy class-cell callers see no usable ID.
        return value.isNativeAggregate ? 0 : value.classIdentity;
    }

    public static string classTypeName(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: classQualifiedName;

            return classQualifiedName(baseTypeOf(native(value).type).isTypeClass.sym);
        }
        return value.classTypeName;
    }

    public static size_t fieldCount(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: structFields;

            return structFields(baseTypeOf(native(value).type).isTypeStruct).length;
        }
        return value.structFieldCount;
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value fieldAt(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: structFields;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: readValue;

            auto aggregate = native(value);
            return readValue(Place(aggregate.address, aggregate.type).field(
                structFields(baseTypeOf(aggregate.type).isTypeStruct)[index],
            ));
        }
        return value.structFieldAt(index);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value classFieldAt(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: classFields;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: readValue;

            auto aggregate = native(value);
            auto classType = baseTypeOf(aggregate.type).isTypeClass;
            return readValue(Place(nativeClassBodyAddress(value), aggregate.type).field(
                classFields(classType.sym)[index],
            ));
        }
        return value.classFieldAt(index);
    }

    public static size_t elementCount(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;
            import quickbite.backends.interpreter.layout: staticArrayLength;

            auto aggregate = native(value);
            auto type = baseTypeOf(aggregate.type);
            if (auto staticArray = type.isTypeSArray)
                return staticArrayLength(staticArray);
            if (type.isTypeDArray !is null)
                return readSliceHeaderBytes(
                    aggregate.storage.bytes[0 .. NativeArray.sliceHeaderByteLength],
                ).length;
        }
        return value.length;
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value elementAt(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: readValue;

            auto aggregate = native(value);
            return readValue(Place(aggregate.address, aggregate.type).index(index));
        }
        return value[index];
    }

    // The native aggregate owns the complete static-array bytes or the
    // dynamic-array header whose data pointer Place.index follows. This is
    // the one address-of route for aggregate elements; it does not mint an
    // allocation id or create a boxed element snapshot.
    public static void* elementAddress(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
    ) @safe {
        import quickbite.backends.interpreter.place: Place;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.elementAddress needs a native aggregate.");
        auto aggregate = native(value);
        return Place(aggregate.address, aggregate.type).index(index).address;
    }

    public static void* nativeClassBodyAddress(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        import quickbite.backends.interpreter.place: Place;

        if (!value.isNativeAggregate)
            throw new Exception("AggregateValue.nativeClassBodyAddress needs a native aggregate.");
        auto aggregate = native(value);
        if (baseTypeOf(aggregate.type).isTypeClass is null)
            throw new Exception("AggregateValue.nativeClassBodyAddress needs a class aggregate.");
        return Place(aggregate.address, aggregate.type).deref.address;
    }

    public static bool hasClassFieldNamed(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: classFields, fieldName;

            auto classType = baseTypeOf(native(value).type).isTypeClass;
            foreach (field; classFields(classType.sym))
                if (fieldName(field) == name)
                    return true;
            return false;
        }
        return value.hasClassFieldNamed(name);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value classFieldNamed(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: classFields, fieldName;

            auto classType = baseTypeOf(native(value).type).isTypeClass;
            foreach (index, field; classFields(classType.sym))
                if (fieldName(field) == name)
                    return classFieldAt(value, index);
            throw new Exception("AggregateValue.classFieldNamed: no such class field.");
        }
        return value.classFieldNamed(name);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withClassFieldNamed(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
        in imported!"quickbite.backends.interpreter.runtime_value".Value field,
    ) {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: classFields, fieldName;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: writeValue;

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
        return value.withClassFieldNamed(name, field);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withAppendedClassField(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
        in imported!"quickbite.backends.interpreter.runtime_value".Value field,
    ) pure {
        return value.withAppendedClassField(name, field);
    }

    public static string[] classTypeNames(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate)
            return nativeClassTypeNames(
                baseTypeOf(native(value).type).isTypeClass.sym,
            );
        return value.classTypeNames;
    }

    public static bool hasClassType(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
    ) @safe {
        if (value.isNativeAggregate) {
            foreach (typeName; classTypeNames(value))
                if (typeName == name)
                    return true;
            return false;
        }
        return value.classHasType(name);
    }

    // DMD's class/interface links are extern(C++) fields without @safe
    // annotations; this read-only graph walk copies every identifier.
    private static string[] nativeClassTypeNames(
        imported!"dmd.dclass".ClassDeclaration class_,
    ) @trusted {
        string[] names;
        for (auto current = class_; current !is null; current = current.baseClass) {
            names ~= current.ident is null ? "" : current.ident.toString.idup;
            foreach (interface_; current.interfaces)
                appendInterfaceTypeNames(names, interface_.sym);
        }
        return names;
    }

    // Same trusted read-only DMD interface graph boundary as the caller.
    private static void appendInterfaceTypeNames(
        ref string[] names,
        imported!"dmd.dclass".ClassDeclaration interface_,
    ) @trusted {
        if (interface_ is null)
            return;
        names ~= interface_.ident is null ? "" : interface_.ident.toString.idup;
        foreach (base; interface_.interfaces)
            appendInterfaceTypeNames(names, base.sym);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withArrayElement(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.runtime_value".Value element,
    ) {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: writeValue;

            auto aggregate = native(value);
            writeValue(Place(aggregate.address, aggregate.type).index(index), element);
            return value;
        }
        return value.withArrayElement(index, element);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withAppendedArrayElement(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in imported!"quickbite.backends.interpreter.runtime_value".Value element,
    ) {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.native_array: NativeArray;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: writeValue;
            import quickbite.backends.interpreter.runtime_value: Value;

            auto aggregate = native(value);
            auto slice = baseTypeOf(aggregate.type).isTypeDArray;
            if (slice !is null) {
                import core.memory: GC;
                import quickbite.backends.interpreter.layout: typeByteSize;

                const length = elementCount(value);
                auto address = cast(void*) Place(
                    aggregate.address,
                    aggregate.type,
                ).sliceDataPointer;
                const stride = typeByteSize(slice.next);
                const capacity = address is null || stride == 0
                    ? 0
                    : GC.sizeOf(address) / stride;
                if (length < capacity) {
                    auto array = NativeArray.borrow(slice.next, address, length + 1);
                    writeValue(Place(array.element(length).ptr, slice.next), element);
                    array.writeSliceHeader(aggregate.address);
                    return value;
                }
            }

            Value[] elements;
            foreach (index; 0 .. elementCount(value))
                elements ~= elementAt(value, index);
            elements ~= element;
            return reconstructArray(aggregate.type, elements);
        }
        return value.withAppendedArrayElement(element);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withStructField(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.runtime_value".Value field,
    ) {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: writeValue;
            import quickbite.backends.interpreter.layout: structFields;

            auto aggregate = native(value);
            writeValue(
                Place(aggregate.address, aggregate.type).field(
                    structFields(baseTypeOf(aggregate.type).isTypeStruct)[index],
                ),
                field,
            );
            return value;
        }
        return value.withStructField(index, field);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withClassField(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.runtime_value".Value field,
    ) {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.layout: classFields;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: writeValue;

            auto aggregate = native(value);
            auto classType = baseTypeOf(aggregate.type).isTypeClass;
            writeValue(
                Place(nativeClassBodyAddress(value), aggregate.type).field(
                    classFields(classType.sym)[index],
                ),
                field,
            );
            return value;
        }
        return value.withClassField(index, field);
    }

    public static const(void)* nativeArrayAddress(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe {
        if (value.isNativeAggregate) {
            import quickbite.backends.interpreter.native_array: NativeArray, readSliceHeaderBytes;

            auto aggregate = native(value);
            if (baseTypeOf(aggregate.type).isTypeDArray is null)
                return null;
            return readSliceHeaderBytes(
                aggregate.storage.bytes[0 .. NativeArray.sliceHeaderByteLength],
            ).ptr;
        }
        return null;
    }
}


private NativeAggregate allocateAggregate(imported!"dmd.mtype".Type type) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    return NativeAggregate(
        type,
        NativeBlock.allocate(
            typeByteSize(type),
            typeHasPointers(type) ? NativeBlock.Scan.conservative : NativeBlock.Scan.no,
        ),
    );
}


private imported!"quickbite.backends.interpreter.native_block".NativeBlock allocateTypedBlock(
    imported!"dmd.mtype".Type type,
) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;

    return NativeBlock.allocate(
        typeByteSize(type),
        typeHasPointers(type) ? NativeBlock.Scan.conservative : NativeBlock.Scan.no,
    );
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

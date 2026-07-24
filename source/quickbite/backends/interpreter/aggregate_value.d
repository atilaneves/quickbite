module quickbite.backends.interpreter.aggregate_value;


private:


// The boxed aggregate boundary.  `RuntimeValue` still owns the interim
// recursive representation, while consumers reconstruct and visit aggregate
// rvalues through this narrow surface.  The native-handle migration replaces
// this surface's implementation without making `place` depend on a new
// `RuntimeValue` alternative.
public struct AggregateValue {
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

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructNativeArray(
        in imported!"quickbite.backends.interpreter.runtime_value".Value[] elements,
        const(void)* address,
    ) @safe pure {
        import quickbite.backends.interpreter.runtime_value: Value;

        return Value.nativeArrayValue(elements, address);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value reconstructNativeArrayWithLength(
        in size_t length,
        const(void)* address,
    ) @safe pure {
        import quickbite.backends.interpreter.runtime_value: Value;

        return Value.nativeArrayValueWithLength(length, address);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value slice(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t lower,
        in size_t upper,
        const(void)* nativeAddress,
    ) @safe pure {
        return value.arraySlice(lower, upper, nativeAddress);
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
    ) @safe pure nothrow {
        return value.isStruct;
    }

    public static bool isArray(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure nothrow {
        return value.isArray;
    }

    public static bool isClass(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure nothrow {
        return value.isClassObject;
    }

    // Aggregate reads stay behind this boundary so the authority switch can
    // replace recursive RuntimeValue access with native-layout handles in one
    // place. Scalars deliberately remain RuntimeValue operations.
    public static size_t length(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure {
        return value.length;
    }

    public static size_t classIdentity(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure {
        return value.classIdentity;
    }

    public static string classTypeName(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure {
        return value.classTypeName;
    }

    public static size_t fieldCount(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure {
        return value.structFieldCount;
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value fieldAt(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
    ) @safe pure {
        return value.structFieldAt(index);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value classFieldAt(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
    ) @safe pure {
        return value.classFieldAt(index);
    }

    public static size_t elementCount(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure {
        return value.length;
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value elementAt(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
    ) @safe pure {
        return value[index];
    }

    public static bool hasClassFieldNamed(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
    ) @safe pure nothrow {
        return value.hasClassFieldNamed(name);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value classFieldNamed(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
    ) @safe pure {
        return value.classFieldNamed(name);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withClassFieldNamed(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
        in imported!"quickbite.backends.interpreter.runtime_value".Value field,
    ) pure {
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
    ) @safe pure {
        return value.classTypeNames;
    }

    public static bool hasClassType(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in string name,
    ) @safe pure nothrow {
        return value.classHasType(name);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withArrayElement(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.runtime_value".Value element,
    ) pure {
        return value.withArrayElement(index, element);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withAppendedArrayElement(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in imported!"quickbite.backends.interpreter.runtime_value".Value element,
    ) pure {
        return value.withAppendedArrayElement(element);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withStructField(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.runtime_value".Value field,
    ) pure {
        return value.withStructField(index, field);
    }

    public static imported!"quickbite.backends.interpreter.runtime_value".Value withClassField(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
        in size_t index,
        in imported!"quickbite.backends.interpreter.runtime_value".Value field,
    ) pure {
        return value.withClassField(index, field);
    }

    public static const(void)* nativeArrayAddress(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure {
        return value.arrayNativeAddress;
    }
}

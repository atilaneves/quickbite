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

    public static const(void)* nativeArrayAddress(
        in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    ) @safe pure {
        return value.arrayNativeAddress;
    }
}

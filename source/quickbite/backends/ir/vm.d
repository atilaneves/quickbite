module quickbite.backends.ir.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.ir.language".Function function_,
) {
    import quickbite.backends.ir.language:
        BinaryOp,
        BinaryOperation,
        Cast,
        Const,
        ReturnValue,
        Type,
        UnaryOp,
        UnaryOperation;
    import quickbite.lang: Value;
    import std.sumtype: match;

    // Raw scalar storage; each instruction's IR type decides how to interpret
    // these bits.
    ulong[] valueBits;
    valueBits.length = function_.valueCount;
    foreach (instruction; function_.blocks[0].instructions) {
        instruction.match!(
            (const Const const_) {
                valueBits[const_.destination.id] = const_.bits;
            },
            (const Cast cast_) {
                valueBits[cast_.destination.id] = castBits(
                    valueBits[cast_.source],
                    cast_.sourceType,
                    cast_.destination.type,
                );
            },
            (const UnaryOp unary) {
                final switch (unary.operation) with (UnaryOperation) {
                    case neg:
                        final switch (unary.type) with (Type) {
                            case int_:
                                valueBits[unary.destination.id] =
                                    -cast(int) valueBits[unary.source];
                                break;
                            case bool_:
                            case byte_:
                            case ubyte_:
                            case char_:
                            case short_:
                            case ushort_:
                            case uint_:
                            case long_:
                            case ulong_:
                            case float_:
                            case double_:
                            case real_:
                            case ptr:
                                assert(0);
                        }
                        break;
                }
            },
            (const BinaryOp binary) {
                final switch (binary.operation) with (BinaryOperation) {
                    case add:
                        final switch (binary.type) with (Type) {
                            case int_:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] +
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case float_:
                                valueBits[binary.destination.id] = floatBits(
                                    floatFromBits(valueBits[binary.lhs]) +
                                    floatFromBits(valueBits[binary.rhs]),
                                );
                                break;
                            case bool_:
                            case byte_:
                            case ubyte_:
                            case char_:
                            case short_:
                            case ushort_:
                            case uint_:
                            case long_:
                            case ulong_:
                            case double_:
                            case real_:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case sub:
                        final switch (binary.type) with (Type) {
                            case int_:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] -
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case bool_:
                            case byte_:
                            case ubyte_:
                            case char_:
                            case short_:
                            case ushort_:
                            case uint_:
                            case long_:
                            case ulong_:
                            case float_:
                            case double_:
                            case real_:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case mul:
                        final switch (binary.type) with (Type) {
                            case int_:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] *
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case bool_:
                            case byte_:
                            case ubyte_:
                            case char_:
                            case short_:
                            case ushort_:
                            case uint_:
                            case long_:
                            case ulong_:
                            case float_:
                            case double_:
                            case real_:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case div:
                        final switch (binary.type) with (Type) {
                            case int_:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] /
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case bool_:
                            case byte_:
                            case ubyte_:
                            case char_:
                            case short_:
                            case ushort_:
                            case uint_:
                            case long_:
                            case ulong_:
                            case float_:
                            case double_:
                            case real_:
                            case ptr:
                                assert(0);
                        }
                        break;
                }
            },
        );
    }

    return function_.blocks[0].terminator.match!(
        (const ReturnValue return_) {
            final switch (function_.returnType) with (Type) {
                case bool_:
                    return Value(valueBits[return_.value] != 0);
                case byte_:
                    return Value(cast(byte) valueBits[return_.value]);
                case ubyte_:
                    return Value(cast(ubyte) valueBits[return_.value]);
                case char_:
                    return Value(cast(char) valueBits[return_.value]);
                case short_:
                    return Value(cast(short) valueBits[return_.value]);
                case ushort_:
                    return Value(cast(ushort) valueBits[return_.value]);
                case int_:
                    return Value(cast(int) valueBits[return_.value]);
                case uint_:
                    return Value(cast(uint) valueBits[return_.value]);
                case long_:
                    return Value(cast(long) valueBits[return_.value]);
                case ulong_:
                    return Value(cast(ulong) valueBits[return_.value]);
                case float_:
                    return Value(floatFromBits(valueBits[return_.value]));
                case double_:
                    return Value(doubleFromBits(valueBits[return_.value]));
                case real_:
                case ptr:
                    assert(0);
            }
        },
        (_) {
            assert(0);
            return Value.void_;
        },
    );
}

private ulong castBits(
    in ulong source,
    in imported!"quickbite.backends.ir.language".Type sourceType,
    in imported!"quickbite.backends.ir.language".Type targetType,
) @safe pure {
    import quickbite.backends.ir.language: Type;

    final switch (targetType) with (Type) {
        case bool_:
            return integerBits(source, sourceType) != 0;
        case byte_:
            return cast(byte) integerBits(source, sourceType);
        case ubyte_:
            return cast(ubyte) integerBits(source, sourceType);
        case char_:
            return cast(char) integerBits(source, sourceType);
        case short_:
            return cast(short) integerBits(source, sourceType);
        case ushort_:
            return cast(ushort) integerBits(source, sourceType);
        case int_:
            return cast(int) integerBits(source, sourceType);
        case uint_:
            return cast(uint) integerBits(source, sourceType);
        case long_:
            return cast(long) integerBits(source, sourceType);
        case ulong_:
            return cast(ulong) integerBits(source, sourceType);
        case float_:
        case double_:
        case real_:
        case ptr:
            assert(0);
    }
}

private long integerBits(
    in ulong source,
    in imported!"quickbite.backends.ir.language".Type sourceType,
) @safe pure {
    import quickbite.backends.ir.language: Type;

    final switch (sourceType) with (Type) {
        case bool_:
            return source != 0;
        case byte_:
            return cast(byte) source;
        case ubyte_:
            return cast(ubyte) source;
        case char_:
            return cast(char) source;
        case short_:
            return cast(short) source;
        case ushort_:
            return cast(ushort) source;
        case int_:
            return cast(int) source;
        case uint_:
            return cast(uint) source;
        case long_:
            return cast(long) source;
        case ulong_:
            return cast(long) source;
        case float_:
        case double_:
        case real_:
        case ptr:
            assert(0);
    }
}

// @trusted: reads the bytes of a local float as a same-sized uint for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
private ulong floatBits(in float value) @trusted pure nothrow {
    static assert(float.sizeof == uint.sizeof);
    return *cast(uint*) &value;
}

// @trusted: reads the bytes of a local uint as a same-sized float after
// retrieving an f32 value from IR raw scalar storage. The pointer is used only
// for this immediate read and never escapes.
private float floatFromBits(in ulong value) @trusted pure nothrow {
    static assert(float.sizeof == uint.sizeof);
    const bits = cast(uint) value;
    return *cast(float*) &bits;
}

// @trusted: reads the bytes of a local ulong as a same-sized double after
// retrieving an f64 value from IR raw scalar storage. The pointer is used only
// for this immediate read and never escapes.
private double doubleFromBits(in ulong value) @trusted pure nothrow {
    static assert(double.sizeof == ulong.sizeof);
    return *cast(double*) &value;
}

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
        Load,
        ResultType,
        ReturnValue,
        Store,
        UnaryOp,
        UnaryOperation,
        Type;
    import quickbite.lang: Value;
    import std.sumtype: match;

    // Raw scalar storage; each instruction's IR type decides how to interpret
    // these bits.
    ulong[] valueBits;
    valueBits.length = function_.valueCount;
    ulong[] localBits;
    localBits.length = function_.localCount;
    foreach (instruction; function_.blocks[0].instructions) {
        instruction.match!(
            (const Const const_) {
                valueBits[const_.destination.id] = const_.bits;
            },
            (const Cast cast_) {
                final switch (cast_.sourceType) with (Type) {
                    case f64:
                        final switch (cast_.targetType) with (Type) {
                            case i32:
                                valueBits[cast_.destination.id] =
                                    cast(int) doubleFromBits(
                                        valueBits[cast_.source],
                                    );
                                break;
                            case i1:
                            case i8:
                            case i16:
                            case i64:
                            case f32:
                            case f64:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case i32:
                        final switch (cast_.targetType) with (Type) {
                            case i8:
                                valueBits[cast_.destination.id] =
                                    cast(byte) cast(int) valueBits[
                                        cast_.source
                                    ];
                                break;
                            case i16:
                                valueBits[cast_.destination.id] =
                                    cast(short) cast(int) valueBits[
                                        cast_.source
                                    ];
                                break;
                            case i32:
                                valueBits[cast_.destination.id] =
                                    cast(int) valueBits[cast_.source];
                                break;
                            case i64:
                                valueBits[cast_.destination.id] =
                                    cast(long) cast(int) valueBits[
                                        cast_.source
                                    ];
                                break;
                            case i1:
                            case f32:
                            case f64:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case i1:
                    case i8:
                    case i16:
                    case i64:
                    case f32:
                    case ptr:
                        assert(0);
                }
            },
            (const Load load) {
                valueBits[load.destination.id] = localBits[load.local];
            },
            (const UnaryOp unary) {
                final switch (unary.operation) with (UnaryOperation) {
                    case negate:
                        final switch (unary.type) with (Type) {
                            case f64:
                                valueBits[unary.destination.id] = doubleBits(
                                    -doubleFromBits(valueBits[unary.source]),
                                );
                                break;
                            case i1:
                            case i8:
                            case i16:
                            case i32:
                            case i64:
                            case f32:
                            case ptr:
                                assert(0);
                        }
                        break;
                }
            },
            (const Store store) {
                final switch (store.type) with (Type) {
                    case i32:
                        localBits[store.local] = valueBits[store.value];
                        break;
                    case f64:
                        localBits[store.local] = valueBits[store.value];
                        break;
                    case i1:
                    case i8:
                    case i16:
                    case i64:
                    case f32:
                    case ptr:
                        assert(0);
                }
            },
            (const BinaryOp binary) {
                final switch (binary.operation) with (BinaryOperation) {
                    case add:
                        final switch (binary.type) with (Type) {
                            case i32:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] +
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case f32:
                                valueBits[binary.destination.id] = floatBits(
                                    floatFromBits(valueBits[binary.lhs]) +
                                    floatFromBits(valueBits[binary.rhs]),
                                );
                                break;
                            case i1:
                            case i8:
                            case i16:
                            case i64:
                            case f64:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case subtract:
                        final switch (binary.type) with (Type) {
                            case i32:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] -
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case f64:
                                valueBits[binary.destination.id] = doubleBits(
                                    doubleFromBits(valueBits[binary.lhs]) -
                                    doubleFromBits(valueBits[binary.rhs]),
                                );
                                break;
                            case i1:
                            case i8:
                            case i16:
                            case i64:
                            case f32:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case multiply:
                        final switch (binary.type) with (Type) {
                            case i32:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] *
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case i1:
                            case i8:
                            case i16:
                            case i64:
                            case f32:
                            case f64:
                            case ptr:
                                assert(0);
                        }
                        break;
                    case divide:
                        final switch (binary.type) with (Type) {
                            case i32:
                                valueBits[binary.destination.id] =
                                    cast(int) valueBits[binary.lhs] /
                                    cast(int) valueBits[binary.rhs];
                                break;
                            case i1:
                            case i8:
                            case i16:
                            case i64:
                            case f32:
                            case f64:
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
            final switch (function_.returnType) with (ResultType) {
                case bool_:
                    return Value(cast(bool) valueBits[return_.value]);
                case byte_:
                    return Value(cast(byte) valueBits[return_.value]);
                case ubyte_:
                    return Value(cast(ubyte) valueBits[return_.value]);
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
                case char_:
                    return Value(cast(char) valueBits[return_.value]);
                case float_:
                    return Value(floatFromBits(valueBits[return_.value]));
                case double_:
                    return Value(doubleFromBits(valueBits[return_.value]));
            }
        },
        (_) {
            assert(0);
            return Value.void_;
        },
    );
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

// @trusted: reads the bytes of a local double as a same-sized ulong for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
private ulong doubleBits(in double value) @trusted pure nothrow {
    static assert(double.sizeof == ulong.sizeof);
    return *cast(ulong*) &value;
}

// @trusted: reads the bytes of a local ulong as a same-sized double after
// retrieving an f64 value from IR raw scalar storage. The pointer is used only
// for this immediate read and never escapes.
private double doubleFromBits(in ulong bits) @trusted pure nothrow {
    static assert(double.sizeof == ulong.sizeof);
    return *cast(double*) &bits;
}

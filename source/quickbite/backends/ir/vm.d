module quickbite.backends.ir.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.ir.language".Function function_,
) {
    import quickbite.backends.ir.language:
        BinaryOp,
        BinaryOperation,
        Const,
        ReturnValue,
        Type;
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
            final switch (function_.returnType) with (Type) {
                case i32:
                    return Value(cast(int) valueBits[return_.value]);
                case f32:
                    return Value(floatFromBits(valueBits[return_.value]));
                case i1:
                case i8:
                case i16:
                case i64:
                case f64:
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

module quickbite.backends.ir.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.ir.language".Function function_,
) {
    Machine machine;
    machine.init(function_);
    machine.execute(function_, []);

    return machine.result(function_);
}

package void execute(in imported!"quickbite.backends.ir.language".Function function_) {
    Machine machine;
    machine.init(function_);
    machine.execute(function_, []);
}

private struct Machine {
    import quickbite.backends.ir.bits:
        doubleBits,
        doubleFromBits,
        floatBits,
        floatFromBits;
    import quickbite.backends.ir.language:
        BinaryOp,
        BinaryOperation,
        AssertCompare,
        AssertTrue,
        Cast,
        Call,
        Const,
        Function,
        Instruction,
        Load,
        ResultKind,
        ReturnValue,
        StringConst,
        Store,
        Type,
        UnaryIntrinsicOp,
        UnaryIntrinsicOperation,
        UnaryOp,
        UnaryOperation;
    import quickbite.lang: Value;
    import std.sumtype: match;

    private ulong[] scalarValues;
    private string[] stringValues;
    private ulong[] localScalarValues;
    private const(Function)[] functions;

    private void init(in Function function_) {
        functions = function_.functions;
        reserveStorage(function_);
        foreach (child; function_.functions)
            reserveStorage(child);
    }

    private void reserveStorage(in Function function_) {
        if (scalarValues.length < function_.valueCount)
            scalarValues.length = function_.valueCount;
        if (stringValues.length < function_.valueCount)
            stringValues.length = function_.valueCount;
        if (localScalarValues.length < function_.localCount)
            localScalarValues.length = function_.localCount;
    }

    private ulong execute(in Function function_, in uint[] arguments) {
        foreach (i, argument; arguments)
            localScalarValues[i] = scalarValues[argument];

        foreach (instruction; function_.blocks[0].instructions)
            execute(instruction);

        return function_.blocks[0].terminator.match!(
            (const ReturnValue return_) => scalarValues[return_.value],
            (_) {
                assert(0);
                return ulong.init;
            },
        );
    }

    private void execute(const Instruction instruction) {
        instruction.match!(
            (const Const const_) => execute(const_),
            (const StringConst const_) => execute(const_),
            (const Cast cast_) => execute(cast_),
            (const Call call) => execute(call),
            (const AssertTrue assert_) => execute(assert_),
            (const AssertCompare assert_) => execute(assert_),
            (const Load load) => execute(load),
            (const UnaryOp unary) => execute(unary),
            (const UnaryIntrinsicOp intrinsic) => execute(intrinsic),
            (const Store store) => execute(store),
            (const BinaryOp binary) => execute(binary),
        );
    }

    private void execute(const Const const_) {
        scalarValues[const_.result.id] = const_.bits;
    }

    private void execute(const StringConst const_) {
        stringValues[const_.result.id] = const_.elements;
    }

    private void execute(const Cast cast_) {
        final switch (cast_.sourceType) with (Type) {
            case f64:
                castF64(cast_);
                break;
            case i32:
            case i8:
            case i16:
            case i64:
                castInteger(cast_);
                break;
            case i1:
            case f32:
            case ptr:
                assert(0);
        }
    }

    private void execute(const Call call) {
        scalarValues[call.result.id] =
            execute(functions[call.functionIndex], call.arguments);
    }

    private void execute(const AssertTrue assert_) {
        if (scalarValues[assert_.condition] == 0) {
            import quickbite.unittest_assertions:
                AssertionMessageMode,
                failedAssertionMessage;

            throw new Exception(failedAssertionMessage(
                AssertionMessageMode.context,
            ));
        }
    }

    private void execute(const AssertCompare assert_) {
        if (compare(assert_))
            return;

        import quickbite.unittest_assertions:
            AssertionMessageMode,
            failedAssertionMessage;

        throw new Exception(failedAssertionMessage(
            AssertionMessageMode.context,
            assertionInteger(assert_.type, assert_.resultKind, assert_.lhs),
            assertionInteger(assert_.type, assert_.resultKind, assert_.rhs),
            comparisonOperator(assert_.operation),
        ));
    }

    private void castF64(const Cast cast_) {
        final switch (cast_.targetType) with (Type) {
            case i32:
                scalarValues[cast_.result.id] =
                    cast(int) doubleFromBits(scalarValues[cast_.source]);
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
    }

    private void castInteger(const Cast cast_) {
        const source = scalarValues[cast_.source];
        final switch (cast_.targetType) with (Type) {
            case i8:
                scalarValues[cast_.result.id] =
                    cast_.result.resultKind == ResultKind.ubyte_ ?
                    cast(ubyte) source :
                    cast(byte) source;
                break;
            case i16:
                scalarValues[cast_.result.id] =
                    cast_.result.resultKind == ResultKind.ushort_ ?
                    cast(ushort) source :
                    cast(short) source;
                break;
            case i32:
                scalarValues[cast_.result.id] =
                    cast_.result.resultKind == ResultKind.uint_ ?
                    cast(uint) source :
                    cast(int) source;
                break;
            case i64:
                scalarValues[cast_.result.id] =
                    cast_.result.resultKind == ResultKind.ulong_ ?
                    cast(ulong) source :
                    cast(long) source;
                break;
            case i1:
            case f32:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private void execute(const Load load) {
        scalarValues[load.result.id] = localScalarValues[load.local];
    }

    private void execute(const UnaryOp unary) {
        final switch (unary.operation) with (UnaryOperation) {
            case negate:
                executeNegate(unary);
                break;
        }
    }

    private void executeNegate(const UnaryOp unary) {
        final switch (unary.type) with (Type) {
            case f64:
                scalarValues[unary.result.id] =
                    doubleBits(-doubleFromBits(scalarValues[unary.source]));
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
    }

    private void execute(const UnaryIntrinsicOp intrinsic) {
        final switch (intrinsic.operation) with (UnaryIntrinsicOperation) {
            case fabs:
                executeFabs(intrinsic);
                break;
        }
    }

    private void executeFabs(const UnaryIntrinsicOp intrinsic) {
        import std.math: fabs;

        final switch (intrinsic.type) with (Type) {
            case f32:
                scalarValues[intrinsic.result.id] = floatBits(
                    fabs(floatFromBits(scalarValues[intrinsic.source])),
                );
                break;
            case i1:
            case i8:
            case i16:
            case i32:
            case i64:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private void execute(const Store store) {
        final switch (store.type) with (Type) {
            case i32:
            case i8:
            case i16:
            case i64:
            case f64:
            case f32:
                localScalarValues[store.local] = scalarValues[store.value];
                break;
            case i1:
            case ptr:
                assert(0);
        }
    }

    private void execute(const BinaryOp binary) {
        final switch (binary.operation) with (BinaryOperation) {
            case add:
                executeAdd(binary);
                break;
            case subtract:
                executeSubtract(binary);
                break;
            case multiply:
                executeMultiply(binary);
                break;
            case divide:
                executeDivide(binary);
                break;
            case pow:
                executePow(binary);
                break;
            case equal:
                executeEqual(binary);
                break;
        }
    }

    private void executeAdd(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] +
                    cast(int) scalarValues[binary.rhs];
                break;
            case f32:
                scalarValues[binary.result.id] = floatBits(
                    floatFromBits(scalarValues[binary.lhs]) +
                    floatFromBits(scalarValues[binary.rhs]),
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
    }

    private void executeSubtract(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] -
                    cast(int) scalarValues[binary.rhs];
                break;
            case f64:
                scalarValues[binary.result.id] = doubleBits(
                    doubleFromBits(scalarValues[binary.lhs]) -
                    doubleFromBits(scalarValues[binary.rhs]),
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
    }

    private void executeMultiply(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] *
                    cast(int) scalarValues[binary.rhs];
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
    }

    private void executeDivide(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] /
                    cast(int) scalarValues[binary.rhs];
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
    }

    private void executePow(const BinaryOp binary) {
        import std.math: pow;

        final switch (binary.type) with (Type) {
            case f32:
                scalarValues[binary.result.id] = floatBits(
                    pow(
                        floatFromBits(scalarValues[binary.lhs]),
                        floatFromBits(scalarValues[binary.rhs]),
                    ),
                );
                break;
            case i1:
            case i8:
            case i16:
            case i32:
            case i64:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private void executeEqual(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i8:
                if (binary.result.resultKind == ResultKind.ubyte_)
                    scalarValues[binary.result.id] =
                        cast(ubyte) scalarValues[binary.lhs] ==
                        cast(ubyte) scalarValues[binary.rhs];
                else
                    scalarValues[binary.result.id] =
                        cast(byte) scalarValues[binary.lhs] ==
                        cast(byte) scalarValues[binary.rhs];
                break;
            case i16:
                if (binary.result.resultKind == ResultKind.ushort_)
                    scalarValues[binary.result.id] =
                        cast(ushort) scalarValues[binary.lhs] ==
                        cast(ushort) scalarValues[binary.rhs];
                else
                    scalarValues[binary.result.id] =
                        cast(short) scalarValues[binary.lhs] ==
                        cast(short) scalarValues[binary.rhs];
                break;
            case i32:
                if (binary.result.resultKind == ResultKind.uint_)
                    scalarValues[binary.result.id] =
                        cast(uint) scalarValues[binary.lhs] ==
                        cast(uint) scalarValues[binary.rhs];
                else
                    scalarValues[binary.result.id] =
                        cast(int) scalarValues[binary.lhs] ==
                        cast(int) scalarValues[binary.rhs];
                break;
            case i64:
                if (binary.result.resultKind == ResultKind.ulong_)
                    scalarValues[binary.result.id] =
                        cast(ulong) scalarValues[binary.lhs] ==
                        cast(ulong) scalarValues[binary.rhs];
                else
                    scalarValues[binary.result.id] =
                        cast(long) scalarValues[binary.lhs] ==
                        cast(long) scalarValues[binary.rhs];
                break;
            case i1:
            case f32:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private bool compare(const AssertCompare assert_) {
        final switch (assert_.operation) with (BinaryOperation) {
            case equal:
                return assertionInteger(
                    assert_.type,
                    assert_.resultKind,
                    assert_.lhs,
                ) == assertionInteger(
                    assert_.type,
                    assert_.resultKind,
                    assert_.rhs,
                );
            case add:
            case subtract:
            case multiply:
            case divide:
            case pow:
                assert(0);
        }
    }

    private long assertionInteger(
        in Type type,
        in ResultKind kind,
        in uint value,
    ) {
        final switch (type) with (Type) {
            case i8:
                return kind == ResultKind.ubyte_ ?
                    cast(long) cast(ubyte) scalarValues[value] :
                    cast(long) cast(byte) scalarValues[value];
            case i16:
                return kind == ResultKind.ushort_ ?
                    cast(long) cast(ushort) scalarValues[value] :
                    cast(long) cast(short) scalarValues[value];
            case i32:
                return kind == ResultKind.uint_ ?
                    cast(long) cast(uint) scalarValues[value] :
                    cast(long) cast(int) scalarValues[value];
            case i64:
                return kind == ResultKind.ulong_ ?
                    cast(long) cast(ulong) scalarValues[value] :
                    cast(long) scalarValues[value];
            case i1:
            case f32:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private string comparisonOperator(in BinaryOperation operation) @safe pure {
        final switch (operation) with (BinaryOperation) {
            case equal:
                return "==";
            case add:
            case subtract:
            case multiply:
            case divide:
            case pow:
                assert(0);
        }
    }

    private Value result(in Function function_) {
        return function_.blocks[0].terminator.match!(
            (const ReturnValue return_) {
                return result(function_.returnType, return_.value);
            },
            (_) {
                assert(0);
                return Value.void_;
            },
        );
    }

    private Value result(in ResultKind kind, in uint valueId) {
        final switch (kind) with (ResultKind) {
            case bool_:
                return Value(cast(bool) scalarValues[valueId]);
            case byte_:
                return Value(cast(byte) scalarValues[valueId]);
            case ubyte_:
                return Value(cast(ubyte) scalarValues[valueId]);
            case short_:
                return Value(cast(short) scalarValues[valueId]);
            case ushort_:
                return Value(cast(ushort) scalarValues[valueId]);
            case int_:
                return Value(cast(int) scalarValues[valueId]);
            case uint_:
                return Value(cast(uint) scalarValues[valueId]);
            case long_:
                return Value(cast(long) scalarValues[valueId]);
            case ulong_:
                return Value(cast(ulong) scalarValues[valueId]);
            case char_:
                return Value(cast(char) scalarValues[valueId]);
            case float_:
                return Value(floatFromBits(scalarValues[valueId]));
            case double_:
                return Value(doubleFromBits(scalarValues[valueId]));
            case string_:
                return Value(stringValues[valueId]);
        }
    }
}

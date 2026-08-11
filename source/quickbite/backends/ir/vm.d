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

package void run(
    in imported!"quickbite.backends.ir.language".Function function_,
) {
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
        AssertFalse,
        AssertTrue,
        Branch,
        Cast,
        Call,
        CondBranch,
        Const,
        Function,
        Instruction,
        Load,
        RefWriteback,
        ResultKind,
        ReturnVoid,
        ReturnValue,
        StringConst,
        Store,
        ThrowException,
        ThrowIfNull,
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
    private string[] localStringValues;
    private bool[] localInitializedValues;
    private const(Function)[] functions;
    private uint returnedValueId;

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
        if (localStringValues.length < function_.localCount)
            localStringValues.length = function_.localCount;
        if (localInitializedValues.length < function_.localCount)
            localInitializedValues.length = function_.localCount;
    }

    private ulong execute(in Function function_, in uint[] arguments) {
        localInitializedValues[0 .. function_.localCount] = false;
        foreach (i, argument; arguments) {
            localScalarValues[i] = scalarValues[argument];
            localInitializedValues[i] = true;
        }

        uint blockIndex;
        const(uint)[] blockArguments;
        while (true) {
            const block = function_.blocks[blockIndex];
            foreach (i, argument; blockArguments)
                scalarValues[block.params[i].id] = scalarValues[argument];
            blockArguments = null;

            foreach (instruction; block.instructions)
                execute(instruction);

            bool returned;
            ulong result;
            block.terminator.match!(
                (const ReturnValue return_) {
                    returned = true;
                    returnedValueId = return_.value;
                    result = scalarValues[return_.value];
                },
                (const ReturnVoid return_) {
                    returned = true;
                },
                (const Branch branch) {
                    blockIndex = branch.target;
                    blockArguments = branch.args;
                },
                (const CondBranch branch) {
                    if (scalarValues[branch.condition] != 0) {
                        blockIndex = branch.trueTarget;
                        blockArguments = branch.trueArgs;
                    } else {
                        blockIndex = branch.falseTarget;
                        blockArguments = branch.falseArgs;
                    }
                },
            );
            if (returned)
                return result;
        }
    }

    private void execute(const Instruction instruction) {
        instruction.match!(
            (const Const const_) => execute(const_),
            (const StringConst const_) => execute(const_),
            (const Cast cast_) => execute(cast_),
            (const Call call) => execute(call),
            (const AssertTrue assert_) => execute(assert_),
            (const AssertFalse assert_) => execute(assert_),
            (const AssertCompare assert_) => execute(assert_),
            (const ThrowException throw_) => execute(throw_),
            (const ThrowIfNull throw_) => execute(throw_),
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
            case i1:
                castI1(cast_);
                break;
            case i32:
            case i8:
            case i16:
            case i64:
                castInteger(cast_);
                break;
            case f32:
            case ptr:
                assert(0);
        }
    }

    private void execute(const Call call) {
        // Needs mutable array storage when restored after callee execution.
        auto callerScalarValues = scalarValues.dup;
        auto callerStringValues = stringValues.dup;
        auto callerLocalScalarValues = localScalarValues.dup;
        auto callerLocalStringValues = localStringValues.dup;
        auto callerLocalInitializedValues = localInitializedValues.dup;
        const result = execute(functions[call.functionIndex], call.arguments);
        const writebackValues = refWritebackValues(call.refWritebacks);
        scalarValues = callerScalarValues;
        stringValues = callerStringValues;
        localScalarValues = callerLocalScalarValues;
        localStringValues = callerLocalStringValues;
        localInitializedValues = callerLocalInitializedValues;
        foreach (i, writeback; call.refWritebacks) {
            localScalarValues[writeback.callerLocal] = writebackValues[i];
            localInitializedValues[writeback.callerLocal] = true;
        }
        if (call.hasResult)
            scalarValues[call.result.id] = result;
    }

    private ulong[] refWritebackValues(const RefWriteback[] writebacks) {
        ulong[] values;
        foreach (writeback; writebacks) {
            final switch (writeback.type) with (Type) {
                case i32:
                case i8:
                case i16:
                case i64:
                case f64:
                case f32:
                case i1:
                    values ~= localScalarValues[writeback.parameterLocal];
                    break;
                case ptr:
                    assert(0);
            }
        }
        return values;
    }

    private void execute(const AssertTrue assert_) {
        if (scalarValues[assert_.condition] == 0) {
            throw new Exception(assertMessage(
                assert_.message,
                assert_.hasMessageValue,
                assert_.messageValue,
            ));
        }
    }

    private void execute(const AssertFalse assert_) {
        if (scalarValues[assert_.condition] != 0)
            throw new Exception(assertMessage(
                "true == true",
                assert_.hasMessageValue,
                assert_.messageValue,
            ));
    }

    private void castI1(const Cast cast_) {
        final switch (cast_.result.type) with (Type) {
            case i1:
                scalarValues[cast_.result.id] =
                    scalarValues[cast_.source] != 0;
                break;
            case i8:
            case i16:
            case i32:
            case i64:
            case f32:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private void execute(const AssertCompare assert_) {
        if (assertCompareSucceeded(assert_))
            return;

        if (assert_.resultKind == ResultKind.class_) {
            import std.conv: text;

            if (assert_.hasMessageValue)
                throw new Exception(stringValues[assert_.messageValue]);

            throw new Exception(text(
                "`null` ",
                inverseIdentityOperator(assert_.operation),
                " `null`",
            ));
        }

        if (assert_.resultKind == ResultKind.bool_) {
            import std.conv: text;

            if (assert_.hasMessageValue)
                throw new Exception(stringValues[assert_.messageValue]);

            throw new Exception(text(
                assertionBool(assert_.lhs),
                " ",
                inverseComparisonOperator(assert_.operation),
                " ",
                assertionBool(assert_.rhs),
            ));
        }

        if (assert_.resultKind == ResultKind.char_) {
            import std.conv: text;

            if (assert_.hasMessageValue)
                throw new Exception(stringValues[assert_.messageValue]);

            throw new Exception(text(
                "'",
                cast(char) scalarValues[assert_.lhs],
                "' ",
                inverseComparisonOperator(assert_.operation),
                " '",
                cast(char) scalarValues[assert_.rhs],
                "'",
            ));
        }

        import quickbite.unittest_assertions:
            AssertionMessageMode,
            failedAssertionMessage;

        if (assert_.hasMessageValue)
            throw new Exception(stringValues[assert_.messageValue]);

        throw new Exception(failedAssertionMessage(
            AssertionMessageMode.context,
            assertionInteger(assert_.type, assert_.resultKind, assert_.lhs),
            assertionInteger(assert_.type, assert_.resultKind, assert_.rhs),
            comparisonOperator(assert_.operation),
        ));
    }

    private bool assertCompareSucceeded(in AssertCompare assert_) {
        final switch (assert_.operation) with (BinaryOperation) {
            case equal:
                return valuesEqual(assert_.type, assert_.lhs, assert_.rhs);
            case notEqual:
                return !valuesEqual(assert_.type, assert_.lhs, assert_.rhs);
            case lessThan:
            case lessOrEqual:
            case greaterThan:
            case greaterOrEqual:
                return orderedCompareSucceeded(assert_);
            case add:
            case subtract:
            case multiply:
            case divide:
            case bitwiseOr:
            case pow:
                assert(0);
        }
    }

    private bool valuesEqual(
        in Type type,
        in uint lhsValue,
        in uint rhsValue,
    ) {
        final switch (type) with (Type) {
            case i1:
                return cast(bool) scalarValues[lhsValue] ==
                    cast(bool) scalarValues[rhsValue];
            case i8:
                return cast(ubyte) scalarValues[lhsValue] ==
                    cast(ubyte) scalarValues[rhsValue];
            case i16:
                return cast(ushort) scalarValues[lhsValue] ==
                    cast(ushort) scalarValues[rhsValue];
            case i32:
                return cast(uint) scalarValues[lhsValue] ==
                    cast(uint) scalarValues[rhsValue];
            case i64:
            case ptr:
                return scalarValues[lhsValue] == scalarValues[rhsValue];
            case f32:
            case f64:
                assert(0);
        }
    }

    private bool orderedCompareSucceeded(in AssertCompare assert_) {
        final switch (assert_.type) with (Type) {
            case i8:
                return useUnsignedComparison(assert_.resultKind) ?
                    compareUnsigned(
                        cast(ubyte) scalarValues[assert_.lhs],
                        cast(ubyte) scalarValues[assert_.rhs],
                        assert_.operation,
                    ) :
                    compareSigned(
                        cast(byte) scalarValues[assert_.lhs],
                        cast(byte) scalarValues[assert_.rhs],
                        assert_.operation,
                    );
            case i16:
                return useUnsignedComparison(assert_.resultKind) ?
                    compareUnsigned(
                        cast(ushort) scalarValues[assert_.lhs],
                        cast(ushort) scalarValues[assert_.rhs],
                        assert_.operation,
                    ) :
                    compareSigned(
                        cast(short) scalarValues[assert_.lhs],
                        cast(short) scalarValues[assert_.rhs],
                        assert_.operation,
                    );
            case i32:
                return useUnsignedComparison(assert_.resultKind) ?
                    compareUnsigned(
                        cast(uint) scalarValues[assert_.lhs],
                        cast(uint) scalarValues[assert_.rhs],
                        assert_.operation,
                    ) :
                    compareSigned(
                        cast(int) scalarValues[assert_.lhs],
                        cast(int) scalarValues[assert_.rhs],
                        assert_.operation,
                    );
            case i64:
                return useUnsignedComparison(assert_.resultKind) ?
                    compareUnsigned(
                        scalarValues[assert_.lhs],
                        scalarValues[assert_.rhs],
                        assert_.operation,
                    ) :
                    compareSigned(
                        cast(long) scalarValues[assert_.lhs],
                        cast(long) scalarValues[assert_.rhs],
                        assert_.operation,
                    );
            case i1:
            case f32:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private bool useUnsignedComparison(in ResultKind kind) @safe pure nothrow {
        final switch (kind) with (ResultKind) {
            case ubyte_:
            case ushort_:
            case uint_:
            case ulong_:
            case char_:
                return true;
            case bool_:
            case byte_:
            case short_:
            case int_:
            case long_:
            case float_:
            case double_:
            case string_:
            case class_:
                return false;
        }
    }

    private bool compareSigned(
        in long lhs,
        in long rhs,
        in BinaryOperation operation,
    ) @safe pure nothrow {
        final switch (operation) with (BinaryOperation) {
            case lessThan:
                return lhs < rhs;
            case lessOrEqual:
                return lhs <= rhs;
            case greaterThan:
                return lhs > rhs;
            case greaterOrEqual:
                return lhs >= rhs;
            case add:
            case subtract:
            case multiply:
            case divide:
            case bitwiseOr:
            case pow:
            case equal:
            case notEqual:
                assert(0);
        }
    }

    private bool compareUnsigned(
        in ulong lhs,
        in ulong rhs,
        in BinaryOperation operation,
    ) @safe pure nothrow {
        final switch (operation) with (BinaryOperation) {
            case lessThan:
                return lhs < rhs;
            case lessOrEqual:
                return lhs <= rhs;
            case greaterThan:
                return lhs > rhs;
            case greaterOrEqual:
                return lhs >= rhs;
            case add:
            case subtract:
            case multiply:
            case divide:
            case bitwiseOr:
            case pow:
            case equal:
            case notEqual:
                assert(0);
        }
    }

    private void execute(const ThrowException throw_) {
        throw new Exception(throw_.message);
    }

    private void execute(const ThrowIfNull throw_) {
        if (scalarValues[throw_.value] == 0)
            throw new Exception(throw_.message);
    }

    private void castF64(const Cast cast_) {
        final switch (cast_.result.type) with (Type) {
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
        final switch (cast_.result.type) with (Type) {
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
                scalarValues[cast_.result.id] = source != 0;
                break;
            case f32:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private void execute(const Load load) {
        if (load.uninitializedMessage !is null &&
            !localInitializedValues[load.local])
            throw new Exception(load.uninitializedMessage);

        if (load.result.resultKind == ResultKind.string_) {
            stringValues[load.result.id] = localStringValues[load.local];
            return;
        }

        scalarValues[load.result.id] = localScalarValues[load.local];
    }

    private void execute(const UnaryOp unary) {
        final switch (unary.operation) with (UnaryOperation) {
            case negate:
                executeNegate(unary);
                break;
            case not_:
                scalarValues[unary.result.id] =
                    scalarValues[unary.source] == 0;
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
            case i1:
                localScalarValues[store.local] = scalarValues[store.value];
                localInitializedValues[store.local] = true;
                break;
            case ptr:
                localStringValues[store.local] = stringValues[store.value];
                localInitializedValues[store.local] = true;
                break;
        }
    }

    private string assertMessage(
        in string fallback,
        in bool hasMessageValue,
        in uint messageValue,
    ) {
        return hasMessageValue ? stringValues[messageValue] : fallback;
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
            case bitwiseOr:
                executeBitwiseOr(binary);
                break;
            case pow:
                executePow(binary);
                break;
            case equal:
                executeEqual(binary);
                break;
            case notEqual:
                executeNotEqual(binary);
                break;
            case lessThan:
                executeLessThan(binary);
                break;
            case lessOrEqual:
                executeLessOrEqual(binary);
                break;
            case greaterThan:
                executeGreaterThan(binary);
                break;
            case greaterOrEqual:
                executeGreaterOrEqual(binary);
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
            case i64:
                scalarValues[binary.result.id] =
                    scalarValues[binary.lhs] + scalarValues[binary.rhs];
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

    private void executeBitwiseOr(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] |
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

    // Integer equality is signedness-agnostic once both operands are
    // truncated to the operation width.
    private void executeEqual(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i8:
                scalarValues[binary.result.id] =
                    cast(ubyte) scalarValues[binary.lhs] ==
                    cast(ubyte) scalarValues[binary.rhs];
                break;
            case i16:
                scalarValues[binary.result.id] =
                    cast(ushort) scalarValues[binary.lhs] ==
                    cast(ushort) scalarValues[binary.rhs];
                break;
            case i32:
                scalarValues[binary.result.id] =
                    cast(uint) scalarValues[binary.lhs] ==
                    cast(uint) scalarValues[binary.rhs];
                break;
            case i64:
                scalarValues[binary.result.id] =
                    scalarValues[binary.lhs] == scalarValues[binary.rhs];
                break;
            case i1:
                scalarValues[binary.result.id] =
                    cast(bool) scalarValues[binary.lhs] ==
                    cast(bool) scalarValues[binary.rhs];
                break;
            case ptr:
                scalarValues[binary.result.id] =
                    scalarValues[binary.lhs] == scalarValues[binary.rhs];
                break;
            case f32:
            case f64:
                assert(0);
        }
    }

    private void executeNotEqual(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i8:
                scalarValues[binary.result.id] =
                    cast(ubyte) scalarValues[binary.lhs] !=
                    cast(ubyte) scalarValues[binary.rhs];
                break;
            case i16:
                scalarValues[binary.result.id] =
                    cast(ushort) scalarValues[binary.lhs] !=
                    cast(ushort) scalarValues[binary.rhs];
                break;
            case i32:
                scalarValues[binary.result.id] =
                    cast(uint) scalarValues[binary.lhs] !=
                    cast(uint) scalarValues[binary.rhs];
                break;
            case i64:
                scalarValues[binary.result.id] =
                    scalarValues[binary.lhs] != scalarValues[binary.rhs];
                break;
            case i1:
                scalarValues[binary.result.id] =
                    cast(bool) scalarValues[binary.lhs] !=
                    cast(bool) scalarValues[binary.rhs];
                break;
            case ptr:
                scalarValues[binary.result.id] =
                    scalarValues[binary.lhs] != scalarValues[binary.rhs];
                break;
            case f32:
            case f64:
                assert(0);
        }
    }

    private void executeLessThan(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] <
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

    private void executeLessOrEqual(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] <=
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

    private void executeGreaterThan(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] >
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

    private void executeGreaterOrEqual(const BinaryOp binary) {
        final switch (binary.type) with (Type) {
            case i32:
                scalarValues[binary.result.id] =
                    cast(int) scalarValues[binary.lhs] >=
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
                return scalarValues[value] == 0 ? 0 : 1;
            case f32:
            case f64:
            case ptr:
                assert(0);
        }
    }

    private bool assertionBool(in uint value) {
        return scalarValues[value] != 0;
    }

    private string inverseComparisonOperator(in BinaryOperation operation)
        @safe pure
    {
        final switch (operation) with (BinaryOperation) {
            case equal:
                return "!=";
            case notEqual:
                return "==";
            case lessThan:
                return ">=";
            case lessOrEqual:
                return ">";
            case greaterThan:
                return "<=";
            case greaterOrEqual:
                return "<";
            case add:
            case subtract:
            case multiply:
            case divide:
            case bitwiseOr:
            case pow:
                assert(0);
        }
    }

    private string inverseIdentityOperator(in BinaryOperation operation)
        @safe pure
    {
        final switch (operation) with (BinaryOperation) {
            case equal:
                return "!is";
            case notEqual:
                return "is";
            case lessThan:
            case lessOrEqual:
            case greaterThan:
            case greaterOrEqual:
            case add:
            case subtract:
            case multiply:
            case divide:
            case bitwiseOr:
            case pow:
                assert(0);
        }
    }

    private string comparisonOperator(in BinaryOperation operation) @safe pure {
        final switch (operation) with (BinaryOperation) {
            case equal:
                return "==";
            case notEqual:
                return "!=";
            case lessThan:
                return "<";
            case lessOrEqual:
                return "<=";
            case greaterThan:
                return ">";
            case greaterOrEqual:
                return ">=";
            case add:
            case subtract:
            case multiply:
            case divide:
            case bitwiseOr:
            case pow:
                assert(0);
        }
    }

    private Value result(in Function function_) {
        return result(function_.returnType, returnedValueId);
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
            case class_:
                assert(0);
        }
    }
}

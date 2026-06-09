module quickbite.backends.bytecode.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.bytecode.instructions".Program program,
) {
    auto result = run(program);
    if (result.stack.length != 1)
        throw new Exception("Bytecode program did not leave exactly one value");

    return result.stack[0];
}

package void execute(
    in imported!"quickbite.backends.bytecode.instructions".Program program,
) {
    auto result = run(program);
    if (result.stack.length != 0)
        throw new Exception("Bytecode test left values on the stack");
}

private RunResult run(
    in imported!"quickbite.backends.bytecode.instructions".Program program,
) {
    import quickbite.backends.bytecode.builtins:
        BytecodeBuiltin, binaryBuiltinCall, unaryBuiltinCall;
    import quickbite.backends.bytecode.instructions: Op;
    import quickbite.backends.casts: CastTarget, castValue;
    import quickbite.lang: Value;

    Value[] stack;
    size_t[] refStack;
    Value[] locals;
    Frame[] frames;
    size_t ip;

    while (ip < program.instructions.length) {
        const instruction = program.instructions[ip];
        final switch (instruction.op) {
            case Op.literal:
                stack ~= instruction.value;
                ++ip;
                break;

            case Op.call:
                if (instruction.operand >= program.functions.length)
                    throw new Exception("Bytecode function out of bounds");

                const function_ = program.functions[instruction.operand];
                Value[] calleeLocals;
                RefArgument[] refArguments;
                calleeLocals.length = function_.parameterCount;
                foreach_reverse (index; 0 .. function_.parameterCount) {
                    if (stack.length < 1)
                        throw new Exception("Bytecode stack underflow");

                    calleeLocals[index] = stack[$ - 1];
                    stack.length -= 1;

                    if (function_.refParameters[index]) {
                        if (refStack.length < 1)
                            throw new Exception("Bytecode ref stack underflow");

                        refArguments ~= RefArgument(index, refStack[$ - 1]);
                        refStack.length -= 1;
                    }
                }

                frames ~= Frame(ip + 1, locals, refArguments);
                locals = calleeLocals;
                ip = function_.entry;
                break;

            case Op.jump:
                ip = instruction.operand;
                break;

            case Op.jumpIfFalse:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                if (stack[$ - 1].castTo!bool == Value(false))
                    ip = instruction.operand;
                else
                    ++ip;
                break;

            case Op.pop:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack.length -= 1;
                ++ip;
                break;

            case Op.loadLocal:
                if (instruction.operand >= locals.length)
                    throw new Exception("Bytecode local out of bounds");

                if (locals[instruction.operand] == Value.void_)
                    throw new Exception(instruction.value.asCharArrayString);

                stack ~= locals[instruction.operand];
                ++ip;
                break;

            case Op.loadLocalReference:
                if (instruction.operand >= locals.length)
                    throw new Exception("Bytecode local out of bounds");

                stack ~= locals[instruction.operand];
                refStack ~= instruction.operand;
                ++ip;
                break;

            case Op.initializeLocal:
                if (instruction.operand >= locals.length)
                    locals.length = instruction.operand + 1;

                locals[instruction.operand] = instruction.value;
                ++ip;
                break;

            case Op.storeLocal:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                if (instruction.operand >= locals.length)
                    locals.length = instruction.operand + 1;

                locals[instruction.operand] = stack[$ - 1];
                stack.length -= 1;
                ++ip;
                break;

            case Op.incrementLocal:
                if (instruction.operand >= locals.length)
                    throw new Exception("Bytecode local out of bounds");

                locals[instruction.operand] = locals[instruction.operand] +
                    instruction.value;
                ++ip;
                break;

            case Op.cast_:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = castValue(
                    stack[$ - 1],
                    cast(CastTarget) instruction.operand,
                );
                ++ip;
                break;

            case Op.equal:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs == rhs);
                ++ip;
                break;

            case Op.notEqual:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs != rhs);
                ++ip;
                break;

            case Op.add:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs + rhs;
                ++ip;
                break;

            case Op.subtract:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs - rhs;
                ++ip;
                break;

            case Op.multiply:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs * rhs;
                ++ip;
                break;

            case Op.divide:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs / rhs;
                ++ip;
                break;

            case Op.bitOr:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs.asLong | rhs.asLong);
                ++ip;
                break;

            case Op.lessThan:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs.asLong < rhs.asLong);
                ++ip;
                break;

            case Op.lessOrEqual:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs.asLong <= rhs.asLong);
                ++ip;
                break;

            case Op.greaterThan:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs.asLong > rhs.asLong);
                ++ip;
                break;

            case Op.greaterOrEqual:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= Value(lhs.asLong >= rhs.asLong);
                ++ip;
                break;

            case Op.not_:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = Value(stack[$ - 1].castTo!bool == Value(false));
                ++ip;
                break;

            case Op.negate:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = -stack[$ - 1];
                ++ip;
                break;

            case Op.unaryNativeCall:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                stack[$ - 1] = unaryBuiltinCall(
                    cast(BytecodeBuiltin) instruction.operand,
                    stack[$ - 1],
                );
                ++ip;
                break;

            case Op.binaryNativeCall:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= binaryBuiltinCall(
                    cast(BytecodeBuiltin) instruction.operand,
                    lhs,
                    rhs,
                );
                ++ip;
                break;

            case Op.throwIfNullClassMethod:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                if (stack[$ - 1] == Value.null_)
                    throw new Exception(
                        "function call through null class reference `null`",
                    );

                ++ip;
                break;

            case Op.throwIfNullClassField:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                if (stack[$ - 1] == Value.null_)
                    throw new Exception(instruction.value.asCharArrayString);

                ++ip;
                break;

            case Op.assertCompare:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                const rhs = stack[$ - 1];
                const lhs = stack[$ - 2];
                stack.length -= 2;

                const comparison = cast(Op) instruction.operand;
                if (!comparisonHolds(lhs, rhs, comparison))
                    throw new Exception(assertCompareMessage(
                        lhs,
                        rhs,
                        comparison,
                    ));

                ++ip;
                break;

            case Op.assertFalse:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                const value = stack[$ - 1].castTo!bool;
                stack.length -= 1;
                if (value != Value(false))
                    throw new Exception(assertFalseMessage(value));

                ++ip;
                break;

            case Op.assertTrue:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                const value = stack[$ - 1];
                stack.length -= 1;
                if (value.asLong == 0) {
                    if (instruction.value != Value.void_)
                        throw new Exception(
                            instruction.value.asCharArrayString,
                        );

                    throw new Exception(assertTrueMessage(value));
                }

                ++ip;
                break;

            case Op.throw_:
                if (stack.length < 1)
                    throw new Exception("Bytecode stack underflow");

                const value = stack[$ - 1];
                throw new Exception(value.asCharArrayString);

            case Op.ret:
                if (frames.length == 0)
                    return RunResult(stack);

                auto frame = frames[$ - 1];
                frames.length -= 1;
                foreach (refArgument; frame.refArguments) {
                    if (refArgument.parameterIndex >= locals.length)
                        throw new Exception("Bytecode local out of bounds");

                    if (refArgument.callerLocalIndex >= frame.locals.length)
                        throw new Exception("Bytecode local out of bounds");

                    frame.locals[refArgument.callerLocalIndex] =
                        locals[refArgument.parameterIndex];
                }
                locals = frame.locals;
                ip = frame.returnIp;
                break;

            case Op.halt:
                return RunResult(stack);
                break;
        }
    }

    return RunResult(stack);
}

private struct RunResult {
    imported!"quickbite.lang".Value[] stack;
}

private struct Frame {
    size_t returnIp;
    imported!"quickbite.lang".Value[] locals;
    RefArgument[] refArguments;
}

private struct RefArgument {
    size_t parameterIndex;
    size_t callerLocalIndex;
}

private string assertCompareMessage(
    in imported!"quickbite.lang".Value lhs,
    in imported!"quickbite.lang".Value rhs,
    in imported!"quickbite.backends.bytecode.instructions".Op comparison,
) @safe pure {
    import std.conv: text;

    const displayOperandsAsChars = lhs.isChar && rhs.isChar;
    return text(
        compareOperandMessage(lhs, displayOperandsAsChars),
        " ",
        inverseComparisonOperator(comparison),
        " ",
        compareOperandMessage(rhs, displayOperandsAsChars),
    );
}

private bool comparisonHolds(
    in imported!"quickbite.lang".Value lhs,
    in imported!"quickbite.lang".Value rhs,
    in imported!"quickbite.backends.bytecode.instructions".Op comparison,
) @safe pure {
    import quickbite.backends.bytecode.instructions: Op;

    final switch (comparison) {
        case Op.equal:
            return lhs == rhs;
        case Op.notEqual:
            return lhs != rhs;
        case Op.lessThan:
            return lhs.asReal < rhs.asReal;
        case Op.lessOrEqual:
            return lhs.asReal <= rhs.asReal;
        case Op.greaterThan:
            return lhs.asReal > rhs.asReal;
        case Op.greaterOrEqual:
            return lhs.asReal >= rhs.asReal;
        case Op.literal:
        case Op.call:
        case Op.jump:
        case Op.jumpIfFalse:
        case Op.pop:
        case Op.loadLocal:
        case Op.loadLocalReference:
        case Op.initializeLocal:
        case Op.storeLocal:
        case Op.incrementLocal:
        case Op.cast_:
        case Op.add:
        case Op.subtract:
        case Op.multiply:
        case Op.divide:
        case Op.bitOr:
        case Op.not_:
        case Op.negate:
        case Op.unaryNativeCall:
        case Op.binaryNativeCall:
        case Op.throwIfNullClassMethod:
        case Op.throwIfNullClassField:
        case Op.assertCompare:
        case Op.assertFalse:
        case Op.assertTrue:
        case Op.throw_:
        case Op.ret:
        case Op.halt:
            assert(0, "Unsupported bytecode assert comparison.");
    }
}

private string inverseComparisonOperator(
    in imported!"quickbite.backends.bytecode.instructions".Op comparison,
) @safe pure {
    import quickbite.backends.bytecode.instructions: Op;

    final switch (comparison) {
        case Op.equal:
            return "!=";
        case Op.notEqual:
            return "==";
        case Op.lessThan:
            return ">=";
        case Op.lessOrEqual:
            return ">";
        case Op.greaterThan:
            return "<=";
        case Op.greaterOrEqual:
            return "<";
        case Op.literal:
        case Op.call:
        case Op.jump:
        case Op.jumpIfFalse:
        case Op.pop:
        case Op.loadLocal:
        case Op.loadLocalReference:
        case Op.initializeLocal:
        case Op.storeLocal:
        case Op.incrementLocal:
        case Op.cast_:
        case Op.add:
        case Op.subtract:
        case Op.multiply:
        case Op.divide:
        case Op.bitOr:
        case Op.not_:
        case Op.negate:
        case Op.unaryNativeCall:
        case Op.binaryNativeCall:
        case Op.throwIfNullClassMethod:
        case Op.throwIfNullClassField:
        case Op.assertCompare:
        case Op.assertFalse:
        case Op.assertTrue:
        case Op.throw_:
        case Op.ret:
        case Op.halt:
            assert(0, "Unsupported bytecode assert comparison.");
    }
}

private string assertFalseMessage(
    in imported!"quickbite.lang".Value value,
) @safe pure {
    import std.conv: text;

    return text(compareOperandMessage(value), " == true");
}

private string assertTrueMessage(
    in imported!"quickbite.lang".Value value,
) @safe pure {
    import std.conv: text;

    return text(compareOperandMessage(value), " != true");
}

private string compareOperandMessage(
    in imported!"quickbite.lang".Value value,
    in bool displayChar = false,
) @safe pure {
    import std.conv: text;

    if (value == imported!"quickbite.lang".Value(false))
        return "false";

    if (value == imported!"quickbite.lang".Value(true))
        return "true";

    if (displayChar)
        return text("'", value.asChar, "'");

    if (value.isIntegerCompatibleScalar)
        return text(value.asLong);

    return text(value);
}

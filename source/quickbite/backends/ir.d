module quickbite.backends.ir;

private:

public final class IrExecutor : imported!"quickbite.executor".Executor {
    public void runTests(in string source) {
        source.runIrTests;
    }
}

public void runIrTests(in string source) {
    import quickbite.frontend.compiler: ParsedModule, lowerModule, parseModule;

    ParsedModule parsed = parseModule(source);
    const loweredModule = lowerModule(parsed.module_);
    executeUnitTests(loweredModule);
}

void executeUnitTests(in imported!"quickbite.ir.module_".Module module_) @safe pure {
    foreach (test; module_.tests) {
        executeInstructions(
            module_,
            test.instructions,
            test.numTemporaries,
        );
    }
}

long executeFunction(
    in imported!"quickbite.ir.module_".Module module_,
    in string calleeName,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
) @safe pure {
    // Current lowered modules are tiny; add an index when benchmarks show this.
    foreach (function_; module_.functions) {
        if (function_.name == calleeName)
            return executeFunctionBody(
                module_,
                function_.instructions,
                function_.hasReturnValue,
                function_.numParameters,
                function_.refParameters,
                function_.numTemporaries,
                callerTemporaries,
                argumentIndices,
            );
    }

    throw new Exception("Unsupported callee.");
}

long executeFunctionBody(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in bool hasReturnValue,
    in uint numParameters,
    in bool[] refParameters,
    in uint numTemporaries,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
) @safe pure {
    const arguments = argumentValues(callerTemporaries, argumentIndices);
    ExecutionResult result = executeInstructions(
        module_,
        instructions,
        numTemporaries,
        numParameters,
        arguments,
    );
    writeRefArguments(
        result.temporaries,
        refParameters,
        callerTemporaries,
        argumentIndices,
    );
    if (!hasReturnValue)
        return 0;

    if (!result.hasReturn)
        throw new Exception("IR: missing return");

    return readTemporaryValue(result.temporaries, result.returnValue);
}

struct ExecutionResult {
    long[] temporaries;
    bool hasReturn;
    uint returnValue;
}

ExecutionResult executeInstructions(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint numTemporaries,
    in uint numParameters = 0,
    in long[] arguments = [],
) @safe pure {
    long[] temporaries = new long[numTemporaries];
    long[][] arrays;
    writeArguments(temporaries, numParameters, arguments);

    ExecutionResult result;
    result.temporaries = temporaries;

    uint instructionPointer;
    while (instructionPointer < instructions.length) {
        const effect = executeInstruction(
            module_,
            instructions[instructionPointer],
            temporaries,
            arrays,
        );
        if (effect.hasReturn) {
            result.hasReturn = true;
            result.returnValue = effect.returnValue;
            return result;
        }

        instructionPointer += effect.offset;
    }

    return result;
}

struct InstructionEffect {
    uint offset;
    bool hasReturn;
    uint returnValue;
}

InstructionEffect executeInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction instruction,
    ref long[] temporaries,
    ref long[][] arrays,
) @safe pure {
    import quickbite.ir.instruction: ArrayAppend, ArrayIndex, ArrayLength, ArraySet,
        ArrayLiteral, Assert_, BinaryOp, Call, CastInt, ConstInt, Copy, JumpIfFalse,
        JumpIfTrue, ReturnValue, Select, UnaryOp;
    import std.sumtype: match;

    return instruction.match!(
        (ConstInt instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                instruction.value;
            return nextInstruction;
        },
        (const Call instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                executeFunction(
                    module_,
                    instruction.calleeName,
                    temporaries,
                    instruction.arguments,
                );
            return nextInstruction;
        },
        (BinaryOp instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                instruction.operation,
            );
            return nextInstruction;
        },
        (UnaryOp instruction) {
            executeUnaryInstruction(
                temporaries,
                instruction.destination,
                instruction.source,
                instruction.operation,
            );
            return nextInstruction;
        },
        (Select instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                readTemporaryValue(
                    temporaries,
                    instruction.condition,
                )
                    ? readTemporaryValue(temporaries, instruction.ifTrue)
                    : readTemporaryValue(temporaries, instruction.ifFalse);
            return nextInstruction;
        },
        (JumpIfFalse instruction) {
            if (!readTemporaryValue(temporaries, instruction.condition))
                return jump(instruction.offset + 1);

            return nextInstruction;
        },
        (JumpIfTrue instruction) {
            if (readTemporaryValue(temporaries, instruction.condition))
                return jump(instruction.offset + 1);

            return nextInstruction;
        },
        (Copy instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                readTemporaryValue(temporaries, instruction.source);
            return nextInstruction;
        },
        (CastInt instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                castInteger(
                    readTemporaryValue(temporaries, instruction.source),
                    instruction.target,
                );
            return nextInstruction;
        },
        (Assert_ instruction) {
            if (!readTemporaryValue(temporaries, instruction.condition))
                throw new Exception("Unittest assertion failed.");

            return nextInstruction;
        },
        (const ArrayLiteral instruction) {
            long[] values;
            foreach (element; instruction.elements)
                values ~= readTemporaryValue(temporaries, element);

            arrays ~= values;
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (arrays.length - 1);
            return nextInstruction;
        },
        (ArrayAppend instruction) {
            arrays[arrayIndex(temporaries, instruction.array)] ~=
                readTemporaryValue(temporaries, instruction.value);
            return nextInstruction;
        },
        (ArrayLength instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) arrays[arrayIndex(temporaries, instruction.array)].length;
            return nextInstruction;
        },
        (ArrayIndex instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                arrays[arrayIndex(temporaries, instruction.array)][
                    arrayIndex(temporaries, instruction.index)
                ];
            return nextInstruction;
        },
        (ArraySet instruction) {
            arrays[arrayIndex(temporaries, instruction.array)][
                arrayIndex(temporaries, instruction.index)
            ] = readTemporaryValue(temporaries, instruction.value);
            return nextInstruction;
        },
        (ReturnValue instruction) {
            return returnFromFunction(instruction.value);
        },
    );
}

InstructionEffect nextInstruction() @safe pure nothrow @nogc {
    return InstructionEffect(1);
}

InstructionEffect jump(in uint offset) @safe pure nothrow @nogc {
    return InstructionEffect(offset);
}

InstructionEffect returnFromFunction(in uint value) @safe pure nothrow @nogc {
    return InstructionEffect(0, true, value);
}

long castInteger(
    in long value,
    in imported!"quickbite.ir.instruction".IntegerType target,
) @safe pure nothrow @nogc {
    final switch (target) {
        case imported!"quickbite.ir.instruction".IntegerType.i8:
            return cast(byte) value;
        case imported!"quickbite.ir.instruction".IntegerType.u8:
            return cast(ubyte) value;
        case imported!"quickbite.ir.instruction".IntegerType.i16:
            return cast(short) value;
        case imported!"quickbite.ir.instruction".IntegerType.u16:
            return cast(ushort) value;
        case imported!"quickbite.ir.instruction".IntegerType.i32:
            return cast(int) value;
        case imported!"quickbite.ir.instruction".IntegerType.u32:
            return cast(uint) value;
        case imported!"quickbite.ir.instruction".IntegerType.i64:
            return cast(long) value;
        case imported!"quickbite.ir.instruction".IntegerType.u64:
            return cast(ulong) value;
    }
}

void writeArguments(
    ref long[] temporaries,
    in uint numParameters,
    in long[] arguments,
) @safe pure {
    if (arguments.length != numParameters)
        throw new Exception("Unsupported call.");

    foreach (index, argument; arguments)
        writeTemporaryValue(temporaries, cast(uint) index) = argument;
}

void writeRefArguments(
    in long[] calleeTemporaries,
    in bool[] refParameters,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
) @safe pure {
    foreach (index, isRef; refParameters) {
        if (!isRef)
            continue;

        writeTemporaryValue(callerTemporaries, argumentIndices[index]) =
            readTemporaryValue(calleeTemporaries, cast(uint) index);
    }
}

long[] argumentValues(in long[] temporaries, in uint[] arguments) @safe pure {
    long[] result;

    foreach (argument; arguments)
        result ~= readTemporaryValue(temporaries, argument);

    return result;
}

void executeBinaryInstruction(
    ref long[] temporaries,
    in uint destination,
    in uint left,
    in uint right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    const leftValue = readTemporaryValue(temporaries, left);
    const rightValue = readTemporaryValue(temporaries, right);
    long result;

    final switch (operation) {
        case imported!"quickbite.ir.instruction".Operation.add:
            result = leftValue + rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.subtract:
            result = leftValue - rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.multiply:
            result = leftValue * rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.divide:
            enforceNonZeroDivisor(rightValue, "Integer division by zero.");
            result = leftValue / rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.modulo:
            enforceNonZeroDivisor(rightValue, "Integer modulo by zero.");
            result = leftValue % rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.leftShift:
            result = leftValue << rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.rightShift:
            result = leftValue >> rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.bitwiseAnd:
            result = leftValue & rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.bitwiseOr:
            result = leftValue | rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.bitwiseXor:
            result = leftValue ^ rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.equal:
            result = leftValue == rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.notEqual:
            result = leftValue != rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.lessThan:
            result = leftValue < rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.lessOrEqual:
            result = leftValue <= rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.greaterThan:
            result = leftValue > rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.greaterOrEqual:
            result = leftValue >= rightValue;
            break;
    }

    writeTemporaryValue(temporaries, destination) = result;
}

void executeUnaryInstruction(
    ref long[] temporaries,
    in uint destination,
    in uint source,
    in imported!"quickbite.ir.instruction".UnaryOperation operation,
) @safe pure {
    const sourceValue = readTemporaryValue(temporaries, source);

    final switch (operation) {
        case imported!"quickbite.ir.instruction".UnaryOperation.negate:
            writeTemporaryValue(temporaries, destination) = -sourceValue;
            break;
        case imported!"quickbite.ir.instruction".UnaryOperation.not:
            writeTemporaryValue(temporaries, destination) = !sourceValue;
            break;
        case imported!"quickbite.ir.instruction".UnaryOperation.complement:
            writeTemporaryValue(temporaries, destination) = ~sourceValue;
            break;
    }
}

void enforceNonZeroDivisor(in long value, in string message) @safe pure {
    if (value == 0)
        throw new Exception(message);
}

long readTemporaryValue(in long[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

ref long writeTemporaryValue(ref long[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

size_t arrayIndex(in long[] temporaries, in uint temporary) @safe pure {
    const value = readTemporaryValue(temporaries, temporary);
    if (value < 0)
        throw new Exception("IR: array index out of range");

    return cast(size_t) value;
}

void enforceTemporaryIndex(in ulong length, in uint index) @safe pure {
    if (index >= length)
        throw new Exception("IR: temporary index out of range");
}

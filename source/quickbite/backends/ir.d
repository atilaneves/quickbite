module quickbite.backends.ir;

private:

public final class IrExecutor : imported!"quickbite.executor".Executor {
    public void runTests(in string source) {
        source.runIrTests;
    }
}

public void runIrTests(in string source) {
    import quickbite.frontend.compiler: ParsedModule, lowerModule, parseModule;

    // Keep `parsed` mutable: lowerModule consumes DMD's mutable Module type.
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
                function_.returnValue,
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
    in uint returnValue,
    in uint numParameters,
    in bool[] refParameters,
    in uint numTemporaries,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
) @safe pure {
    const arguments = argumentValues(callerTemporaries, argumentIndices);
    const temporaries = executeInstructions(
        module_,
        instructions,
        numTemporaries,
        numParameters,
        arguments,
    );
    writeRefArguments(
        temporaries,
        refParameters,
        callerTemporaries,
        argumentIndices,
    );
    if (!hasReturnValue)
        return 0;

    return readTemporaryValue(temporaries, returnValue);
}

long[] executeInstructions(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint numTemporaries,
    in uint numParameters = 0,
    in long[] arguments = [],
) @safe pure {
    auto temporaries = new long[numTemporaries];
    writeArguments(temporaries, numParameters, arguments);

    foreach (instruction; instructions) {
        executeInstruction(
            module_,
            instruction,
            temporaries,
        );
    }

    return temporaries;
}

void executeInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction instruction,
    ref long[] temporaries,
) @safe pure {
    import quickbite.ir.instruction: Assert_, BinaryOp, Call, CastInt, ConstInt,
        Copy, Select;
    import std.sumtype: match;

    instruction.match!(
        (ConstInt instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                instruction.value;
        },
        (const Call instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                executeFunction(
                    module_,
                    instruction.calleeName,
                    temporaries,
                    instruction.arguments,
                );
        },
        (BinaryOp instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                instruction.operation,
            );
        },
        (Select instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                readTemporaryValue(
                    temporaries,
                    instruction.condition,
                )
                    ? readTemporaryValue(temporaries, instruction.ifTrue)
                    : readTemporaryValue(temporaries, instruction.ifFalse);
        },
        (Copy instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                readTemporaryValue(temporaries, instruction.source);
        },
        (CastInt instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                castInteger(
                    readTemporaryValue(temporaries, instruction.source),
                    instruction.target,
                );
        },
        (Assert_ instruction) {
            if (!readTemporaryValue(temporaries, instruction.condition))
                throw new Exception("Unittest assertion failed.");
        },
    );
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
        case imported!"quickbite.ir.instruction".IntegerType.i32:
            return cast(int) value;
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

long[] argumentValues(ref long[] temporaries, in uint[] arguments) @safe pure {
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

void enforceTemporaryIndex(in ulong length, in uint index) @safe pure {
    if (index >= length)
        throw new Exception("IR: temporary index out of range");
}

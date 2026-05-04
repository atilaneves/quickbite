module quickbite.backends.ir;

private:

public void runIrTests(in string source) {
    import quickbite.frontend.compiler;

    // Keep `parsed` mutable: lowerModule consumes DMD's mutable Module type.
    auto parsed = quickbite.frontend.compiler.parseModule(source);
    const loweredModule = quickbite.frontend.compiler.lowerModule(parsed.module_);
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
    in long[] arguments,
) @safe pure {
    // Current lowered modules are tiny; add an index when benchmarks show this.
    foreach (function_; module_.functions) {
        if (function_.name == calleeName)
            return executeFunctionBody(
                module_,
                function_.instructions,
                function_.returnValue,
                function_.numParameters,
                function_.numTemporaries,
                arguments,
            );
    }

    throw new Exception("Unsupported callee.");
}

long executeFunctionBody(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint returnValue,
    in uint numParameters,
    in uint numTemporaries,
    in long[] arguments,
) @safe pure {
    const temporaries = executeInstructions(
        module_,
        instructions,
        numTemporaries,
        numParameters,
        arguments,
    );
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
    import quickbite.ir.instruction: Add, Assert_, Call, ConstInt, Equal,
        Divide, GreaterOrEqual, GreaterThan, LessOrEqual, LessThan, Modulo,
        Multiply, NotEqual, Select, Subtract;
    import std.sumtype: match;

    instruction.match!(
        (ConstInt instruction) {
            temporaryValue(temporaries, instruction.destination) =
                instruction.value;
        },
        (Add instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.add,
            );
        },
        (Subtract instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.subtract,
            );
        },
        (Multiply instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.multiply,
            );
        },
        (Divide instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.divide,
            );
        },
        (Modulo instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.modulo,
            );
        },
        (const Call instruction) {
            temporaryValue(temporaries, instruction.destination) =
                executeFunction(
                    module_,
                    instruction.calleeName,
                    argumentValues(temporaries, instruction.arguments),
                );
        },
        (Equal instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.equal,
            );
        },
        (NotEqual instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.notEqual,
            );
        },
        (LessThan instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.lessThan,
            );
        },
        (LessOrEqual instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.lessOrEqual,
            );
        },
        (GreaterThan instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.greaterThan,
            );
        },
        (GreaterOrEqual instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                BinaryOperation.greaterOrEqual,
            );
        },
        (Select instruction) {
            temporaryValue(temporaries, instruction.destination) =
                temporaryValue(
                    temporaries,
                    instruction.condition,
                )
                    ? temporaryValue(temporaries, instruction.ifTrue)
                    : temporaryValue(temporaries, instruction.ifFalse);
        },
        (Assert_ instruction) {
            if (!temporaryValue(temporaries, instruction.condition))
                throw new Exception("Unittest assertion failed.");
        },
    );
}

void writeArguments(
    ref long[] temporaries,
    in uint numParameters,
    in long[] arguments,
) @safe pure {
    if (arguments.length != numParameters)
        throw new Exception("Unsupported call.");

    foreach (index, argument; arguments)
        temporaryValue(temporaries, cast(uint) index) = argument;
}

long[] argumentValues(ref long[] temporaries, in uint[] arguments) @safe pure {
    long[] result;

    foreach (argument; arguments)
        result ~= temporaryValue(temporaries, argument);

    return result;
}

enum BinaryOperation {
    add,
    subtract,
    multiply,
    divide,
    modulo,
    equal,
    notEqual,
    lessThan,
    lessOrEqual,
    greaterThan,
    greaterOrEqual,
}

void executeBinaryInstruction(
    ref long[] temporaries,
    in uint destination,
    in uint left,
    in uint right,
    in BinaryOperation operation,
) @safe pure {
    const leftValue = temporaryValue(temporaries, left);
    const rightValue = temporaryValue(temporaries, right);
    long result;

    final switch (operation) {
        case BinaryOperation.add:
            result = leftValue + rightValue;
            break;
        case BinaryOperation.subtract:
            result = leftValue - rightValue;
            break;
        case BinaryOperation.multiply:
            result = leftValue * rightValue;
            break;
        case BinaryOperation.divide:
            enforceNonZeroDivisor(rightValue, "Integer division by zero.");
            result = leftValue / rightValue;
            break;
        case BinaryOperation.modulo:
            enforceNonZeroDivisor(rightValue, "Integer modulo by zero.");
            result = leftValue % rightValue;
            break;
        case BinaryOperation.equal:
            result = leftValue == rightValue;
            break;
        case BinaryOperation.notEqual:
            result = leftValue != rightValue;
            break;
        case BinaryOperation.lessThan:
            result = leftValue < rightValue;
            break;
        case BinaryOperation.lessOrEqual:
            result = leftValue <= rightValue;
            break;
        case BinaryOperation.greaterThan:
            result = leftValue > rightValue;
            break;
        case BinaryOperation.greaterOrEqual:
            result = leftValue >= rightValue;
            break;
    }

    temporaryValue(temporaries, destination) = result;
}

void enforceNonZeroDivisor(in long value, in string message) @safe pure {
    if (value == 0)
        throw new Exception(message);
}

long readTemporaryValue(in long[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

ref long temporaryValue(ref long[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

void enforceTemporaryIndex(in ulong length, in uint index) @safe pure {
    if (index >= length)
        throw new Exception("IR: temporary index out of range");
}

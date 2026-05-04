module quickbite.backends.ir;


import quickbite.executor;


final class IrExecutor : Executor {
    void runTests(in string source) {
        import quickbite.frontend.compiler;

        // Keep `parsed` mutable: lowerModule consumes DMD's mutable
        // Module type.
        auto parsed = quickbite.frontend.compiler.parseModule(source);
        const loweredModule = quickbite.frontend.compiler.lowerModule(parsed.module_);
        executeUnitTests(loweredModule);
    }
}

private:

void executeUnitTests(in imported!"quickbite.ir.module_".Module module_) @safe pure {
    foreach (test; module_.tests) {
        executeTest(
            module_,
            test.instructions,
            test.numTemporaries,
        );
    }
}

long executeFunction(
    in imported!"quickbite.ir.module_".Module module_,
    in string calleeName,
) @safe pure {
    foreach (function_; module_.functions) {
        if (function_.name == calleeName)
            return executeFunctionBody(
                module_,
                function_.instructions,
                function_.returnValue,
                function_.numTemporaries,
            );
    }

    throw new Exception("Unsupported callee.");
}

void executeTest(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint numTemporaries,
) @safe pure {
    executeInstructions(module_, instructions, numTemporaries);
}

long executeFunctionBody(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint returnValue,
    in uint numTemporaries,
) @safe pure {
    auto temporaries = executeInstructions(module_, instructions, numTemporaries);
    return temporaryValue(temporaries, returnValue);
}

long[] executeInstructions(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint numTemporaries,
) @safe pure {
    long[] temporaries = new long[](numTemporaries);

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
        Divide, Modulo, Multiply, Subtract;
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
        (Call instruction) {
            temporaryValue(temporaries, instruction.destination) =
                executeFunction(
                    module_,
                    instruction.calleeName,
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
        (Assert_ instruction) {
            if (!temporaryValue(temporaries, instruction.condition))
                throw new Exception("Unittest assertion failed.");
        },
    );
}

enum BinaryOperation {
    add,
    subtract,
    multiply,
    divide,
    modulo,
    equal,
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
            result = leftValue / rightValue;
            break;
        case BinaryOperation.modulo:
            result = leftValue % rightValue;
            break;
        case BinaryOperation.equal:
            result = leftValue == rightValue;
            break;
    }

    temporaryValue(temporaries, destination) = result;
}

ref long temporaryValue(ref long[] temporaries, in uint index) @safe pure {
    assert(index < temporaries.length, "IR: temporary index out of range");
    return temporaries[index];
}

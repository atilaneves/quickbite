module quickbite;


private:


public void runTests(in string source) {
    import quickbite.frontend.compiler;

    // Keep `parsed` mutable: lowerModule consumes DMD's mutable
    // Module type.
    auto parsed = quickbite.frontend.compiler.parseModule(source);
    const loweredModule = quickbite.frontend.compiler.lowerModule(parsed.module_);
    executeUnitTests(loweredModule);
}

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
    long[] temporaries = new long[](numTemporaries);

    foreach (instruction; instructions) {
        executeInstruction(
            module_,
            instruction,
            temporaries,
        );
    }
}

long executeFunctionBody(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint returnValue,
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

    return temporaryValue(temporaries, returnValue);
}

void executeInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction instruction,
    ref long[] temporaries,
) @safe pure {
    import quickbite.ir.instruction: Assert_, Call, ConstInt, Equal;
    import std.sumtype: match;

    instruction.match!(
        (ConstInt instruction) {
            temporaryValue(temporaries, instruction.destination) =
                instruction.value;
        },
        (Call instruction) {
            temporaryValue(temporaries, instruction.destination) =
                executeFunction(
                    module_,
                    instruction.calleeName,
                );
        },
        (Equal instruction) {
            temporaryValue(temporaries, instruction.destination) =
                temporaryValue(temporaries, instruction.left) ==
                temporaryValue(temporaries, instruction.right);
        },
        (Assert_ instruction) {
            if (!temporaryValue(temporaries, instruction.condition))
                throw new Exception("Unittest assertion failed.");
        },
    );
}

ref long temporaryValue(ref long[] temporaries, in uint index) @safe pure {
    assert(index < temporaries.length, "IR: temporary index out of range");
    return temporaries[index];
}

module quickbite;


private:


public void runTests(in string source) {
    import quickbite.frontend.compiler;

    auto parsed = quickbite.frontend.compiler.parseModule(source);
    auto loweredModule = quickbite.frontend.compiler.lowerModule(parsed.module_);
    executeUnitTests(loweredModule);
}

void executeUnitTests(in imported!"quickbite.ir.module_".Module module_) @safe pure {
    foreach (test; module_.tests) {
        executeTest(
            module_,
            test.instructions,
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
            );
    }

    throw new Exception("Unsupported callee.");
}

void executeTest(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
) @safe pure {
    long[] temporaries;

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
) @safe pure {
    long[] temporaries;

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
    import quickbite.ir.instruction: Kind;

    final switch (instruction.kind) {
        case Kind.constInt:
            temporaryValue(temporaries, instruction.destination) = instruction.value;
            return;

        case Kind.call:
            temporaryValue(temporaries, instruction.destination) = executeFunction(
                module_,
                instruction.calleeName,
            );
            return;

        case Kind.equal:
            temporaryValue(temporaries, instruction.destination) =
                temporaryValue(temporaries, instruction.left) ==
                temporaryValue(temporaries, instruction.right);
            return;

        case Kind.assert_:
            if (!temporaryValue(temporaries, instruction.condition))
                throw new Exception("Unittest assertion failed.");

            return;
    }
}

ref long temporaryValue(ref long[] temporaries, in uint index) @safe pure {
    import std.algorithm.comparison: max;

    const requiredLength = max(
        temporaries.length,
        index + 1,
    );
    temporaries.length = requiredLength;
    return temporaries[index];
}

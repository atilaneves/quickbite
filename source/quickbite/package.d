module quickbite;


private:


public void runTests(in string source) {
    import quickbite.frontend.compiler;

    auto parsed = quickbite.frontend.compiler.parseModule(source);
    auto loweredModule = quickbite.frontend.compiler.lowerModule(parsed.module_);
    executeUnitTests(loweredModule);
}


void executeUnitTests(imported!"quickbite.ir.module_".Module module_) {
    foreach (test; module_.tests) {
        executeBlock(
            module_,
            test.entry,
        );
    }
}

long executeFunction(
    imported!"quickbite.ir.module_".Module module_,
    in string calleeName,
) {
    foreach (function_; module_.functions) {
        if (function_.name == calleeName)
            return executeBlock(module_, function_.entry);
    }

    throw new Exception("Unsupported callee.");
}

long executeBlock(
    imported!"quickbite.ir.module_".Module module_,
    imported!"quickbite.ir.block".Block block,
)
{
    long[] temporaries;

    foreach (instruction; block.instructions) {
        executeInstruction(
            module_,
            instruction,
            temporaries,
        );
    }

    if (block.terminator.kind == imported!"quickbite.ir.block".TerminatorKind.return_)
        return temporaryValue(temporaries, block.terminator.value);

    return 0;
}

void executeInstruction(
    imported!"quickbite.ir.module_".Module module_,
    imported!"quickbite.ir.instruction".Instruction instruction,
    ref long[] temporaries,
) {
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

ref long temporaryValue(ref long[] temporaries, in uint index) {
    import std.algorithm.comparison: max;

    const requiredLength = max(
        temporaries.length,
        index + 1,
    );
    temporaries.length = requiredLength;
    return temporaries[index];
}

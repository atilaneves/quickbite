module quickbite.backends.bytecode.executor;

private:

private class AssertionFailure : Exception {
    public this(in string message) @safe pure {
        super(message);
    }
}

public final class BytecodeExecutor : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override void runParsedTests(imported!"dmd.dmodule".Module module_) {
        import quickbite.backends.bytecode.compiler: compileBytecode;
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            auto bytecode = compileBytecode(unitTest);
            bytecode.execute;
        });
    }

    public override imported!"quickbite.executor".TestSummary runTestSummary(
        in string source,
    ) {
        import quickbite.frontend.compiler: parseModule;

        return testSummary(parseModule(source).module_);
    }
}

private imported!"quickbite.executor".TestSummary testSummary(
    imported!"dmd.dmodule".Module module_,
) {
    import quickbite.backends.bytecode.compiler: compileBytecode;
    import quickbite.executor: TestSummary;
    import quickbite.frontend.util: foreachUnitTestDeclaration;

    TestSummary summary;
    foreachUnitTestDeclaration(module_, (unitTest) {
        ++summary.total;
        try {
            auto bytecode = compileBytecode(unitTest);
            bytecode.execute;
            ++summary.passed;
        } catch (Exception) {
            ++summary.failed;
        }
    });
    return summary;
}

private void execute(ref imported!"quickbite.backends.bytecode.module_".BytecodeModule module_) {
    import quickbite.backends.bytecode.opcode: OpCode;

    long[] stack;
    size_t[] returnAddresses;
    size_t ip;

    while (ip < module_.code.length) {
        const instruction = module_.code[ip];
        final switch (instruction.op) {
            case OpCode.pushInteger:
                stack ~= instruction.operand;
                ++ip;
                break;
            case OpCode.call:
                returnAddresses ~= ip + 1;
                ip = module_.functionEntries[
                    module_.functions[cast(size_t) instruction.operand]
                ];
                break;
            case OpCode.add:
                const right = stack.popValue;
                const left = stack.popValue;
                stack ~= left + right;
                ++ip;
                break;
            case OpCode.equal:
                const right = stack.popValue;
                const left = stack.popValue;
                stack ~= left == right;
                ++ip;
                break;
            case OpCode.assertEqual:
                const right = stack.popValue;
                const left = stack.popValue;
                if (left != right) {
                    import std.conv: text;

                    throw new AssertionFailure(text(left, " != ", right));
                }
                ++ip;
                break;
            case OpCode.ret:
                ip = returnAddresses.popSize;
                break;
            case OpCode.halt:
                return;
        }
    }
}

private long popValue(ref long[] stack) @safe {
    import std.exception: enforce;

    enforce(stack.length != 0, "Bytecode stack underflow.");
    const value = stack[$ - 1];
    stack = stack[0 .. $ - 1];
    return value;
}

private size_t popSize(ref size_t[] stack) @safe {
    import std.exception: enforce;

    enforce(stack.length != 0, "Bytecode return stack underflow.");
    const value = stack[$ - 1];
    stack = stack[0 .. $ - 1];
    return value;
}

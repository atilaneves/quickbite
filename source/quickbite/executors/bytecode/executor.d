module quickbite.executors.bytecode.executor;

private:

private class AssertionFailure : Exception {
    public this(in string message) @safe pure {
        super(message);
    }
}

public final class BytecodeExecutor : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        runTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        runTests(parseModule(source, importPaths).module_);
    }

    public override void runTests(imported!"dmd.dmodule".Module module_) {
        import quickbite.executors.bytecode.compiler: compileBytecode;
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

    public override imported!"quickbite.executor".Value eval(in string input) {
        throw new Exception("eval not yet implemented for bytecode");
    }
}

private imported!"quickbite.executor".TestSummary testSummary(
    imported!"dmd.dmodule".Module module_,
) {
    import quickbite.executors.bytecode.compiler: compileBytecode;
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

private void execute(ref imported!"quickbite.executors.bytecode.module_".BytecodeModule module_) {
    import quickbite.executors.bytecode.opcode: OpCode;
    import quickbite.executor: Value;

    Value[] stack;
    size_t[] returnAddresses;
    string explicitAssertMessage;
    size_t ip;

    while (ip < module_.code.length) {
        const instruction = module_.code[ip];
        final switch (instruction.op) {
            case OpCode.pushValue:
                stack ~= instruction.valueOperand;
                ++ip;
                break;
            case OpCode.call:
                returnAddresses ~= ip + 1;
                ip = module_.functionEntries[
                    module_.functions[cast(size_t) instruction.operand]
                ];
                break;
            case OpCode.add:
                stack.executeBinaryOperation!((left, right) => left + right);
                ++ip;
                break;
            case OpCode.subtract:
                stack.executeBinaryOperation!((left, right) => left - right);
                ++ip;
                break;
            case OpCode.multiply:
                stack.executeBinaryOperation!((left, right) => left * right);
                ++ip;
                break;
            case OpCode.divide:
                stack.executeBinaryOperation!((left, right) => left / right);
                ++ip;
                break;
            case OpCode.modulo:
                stack.executeBinaryOperation!((left, right) => left % right);
                ++ip;
                break;
            case OpCode.shiftRight:
                stack.executeBinaryOperation!((left, right) => left >> right);
                ++ip;
                break;
            case OpCode.shiftLeft:
                stack.executeBinaryOperation!((left, right) => left << right);
                ++ip;
                break;
            case OpCode.bitwiseOr:
                stack.executeBinaryOperation!((left, right) => left | right);
                ++ip;
                break;
            case OpCode.bitwiseAnd:
                stack.executeBinaryOperation!((left, right) => left & right);
                ++ip;
                break;
            case OpCode.bitwiseXor:
                stack.executeBinaryOperation!((left, right) => left ^ right);
                ++ip;
                break;
            case OpCode.equal:
                const right = stack.popValue;
                const left = stack.popValue;
                stack ~= Value(left == right);
                ++ip;
                break;
            case OpCode.notEqual:
                const right = stack.popValue;
                const left = stack.popValue;
                stack ~= Value(left != right);
                ++ip;
                break;
            case OpCode.lessThan:
                stack.executeBinaryOperation!((left, right) => left < right);
                ++ip;
                break;
            case OpCode.lessOrEqual:
                stack.executeBinaryOperation!((left, right) => left <= right);
                ++ip;
                break;
            case OpCode.greaterThan:
                stack.executeBinaryOperation!((left, right) => left > right);
                ++ip;
                break;
            case OpCode.greaterOrEqual:
                stack.executeBinaryOperation!((left, right) => left >= right);
                ++ip;
                break;
            case OpCode.setAssertMessage:
                explicitAssertMessage = module_.assertMessages[
                    cast(size_t) instruction.operand
                ];
                ++ip;
                break;
            case OpCode.assertCompare:
                const right = stack.popValue;
                const left = stack.popValue;
                const comparison = cast(OpCode) instruction.operand;
                if (!comparisonHolds(left, right, comparison)) {
                    if (explicitAssertMessage !is null)
                        throw new AssertionFailure(explicitAssertMessage);

                    import quickbite.unittest_assertions:
                        AssertionMessageMode,
                        failedAssertionMessage;

                    throw new AssertionFailure(failedAssertionMessage(
                        AssertionMessageMode.context,
                        left,
                        right,
                        comparisonOperator(comparison),
                    ));
                }
                explicitAssertMessage = null;
                ++ip;
                break;
            case OpCode.assertTrue:
                const value = stack.popValue;
                if (!value) {
                    if (explicitAssertMessage !is null)
                        throw new AssertionFailure(explicitAssertMessage);

                    import quickbite.unittest_assertions:
                        AssertionMessageMode,
                        failedAssertionMessage;

                    throw new AssertionFailure(failedAssertionMessage(
                        AssertionMessageMode.context,
                    ));
                }
                explicitAssertMessage = null;
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

private struct ComparisonSpec {
    public string op;
    public string symbol;
}

private enum comparisonSpecs = [
    ComparisonSpec("equal", "=="),
    ComparisonSpec("notEqual", "!="),
    ComparisonSpec("lessThan", "<"),
    ComparisonSpec("lessOrEqual", "<="),
    ComparisonSpec("greaterThan", ">"),
    ComparisonSpec("greaterOrEqual", ">="),
];

private bool comparisonHolds(
    in imported!"quickbite.executor".Value left,
    in imported!"quickbite.executor".Value right,
    in imported!"quickbite.executors.bytecode.opcode".OpCode op,
) @safe pure {
    import quickbite.executors.bytecode.opcode: OpCode;

    with (OpCode) switch (op) {
        static foreach (comparison; comparisonSpecs) {
            mixin("case " ~ comparison.op ~ ":");
                static if (comparison.symbol == "==") {
                    return left == right;
                } else static if (comparison.symbol == "!=") {
                    return left != right;
                } else {
                    return mixin(
                        "left.asLong " ~ comparison.symbol ~ " right.asLong"
                    );
                }
        }
        default:
            return false;
    }
}

private string comparisonOperator(
    in imported!"quickbite.executors.bytecode.opcode".OpCode op,
) @safe pure {
    import quickbite.executors.bytecode.opcode: OpCode;

    with (OpCode) switch (op) {
        static foreach (comparison; comparisonSpecs) {
            mixin("case " ~ comparison.op ~ ":");
                return comparison.symbol;
        }
        default:
            return "==";
    }
}

private void executeBinaryOperation(alias operation)(ref imported!"quickbite.executor".Value[] stack) @safe {
    const right = stack.popValue;
    const left = stack.popValue;
    const result = operation(left.asLong, right.asLong);
    static if (is(typeof(result) == bool)) {
        stack ~= imported!"quickbite.executor".Value(result);
    } else {
        stack ~= integerBinaryResult(left, right, result);
    }
}

private imported!"quickbite.executor".Value integerBinaryResult(
    in imported!"quickbite.executor".Value left,
    in imported!"quickbite.executor".Value right,
    in long result,
) @safe pure {
    import quickbite.executor: Value;

    if (
        left == Value(cast(int) left.asLong) &&
        right == Value(cast(int) right.asLong)
    ) {
        return Value(cast(int) result);
    }

    return Value(result);
}

private imported!"quickbite.executor".Value popValue(
    ref imported!"quickbite.executor".Value[] stack,
) @safe {
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

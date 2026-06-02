module quickbite.executors.ir;

private:

import quickbite.executor: Value;

private class UnittestAssertionFailure : Exception {
    public this() @safe pure {
        super("Unittest assertion failed.");
    }

    public this(in string message) @safe pure {
        super(message);
    }
}

private class UserThrownException : Exception {
    public this(in string message) @safe pure {
        super(message);
    }
}

public final class IrExecutor : imported!"quickbite.executor".Executor {
    import dmd.dmodule: Module;
    import quickbite.executor: TestSummary;

    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        auto moduleResult = parseModule(source);
        runTests(moduleResult.module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        auto moduleResult = parseModule(source, importPaths);
        runTests(moduleResult.module_);
    }

    public override void runTests(Module module_) {
        import quickbite.frontend.compiler: lowerModule;

        const loweredModule = lowerModule(module_);
        executeUnitTests(loweredModule);
    }

    public override TestSummary runTestSummary(
        in string source,
    ) {
        import quickbite.frontend.compiler: lowerModule, parseModule;

        // Keep the result mutable: the DMD frontend owns mutable Module state.
        auto moduleResult = parseModule(source);
        const loweredModule = lowerModule(moduleResult.module_);
        return testSummary(loweredModule);
    }

    public override imported!"quickbite.executor".Value eval(in string input) {
        import quickbite.executor: Value;
        import quickbite.frontend.compiler: lowerModule, parseModule;
        import std.string: lastIndexOf;

        const lastNl = input.lastIndexOf('\n');
        const prior  = lastNl < 0 ? "" : input[0 .. lastNl + 1];
        const last   = lastNl < 0 ? input : input[lastNl + 1 .. $];
        const source =
            "auto f() { " ~ prior ~ "return " ~ last ~ "; }\n" ~
            "unittest { f(); }";

        auto moduleResult = parseModule(source);
        const loweredModule = lowerModule(moduleResult.module_);

        // f is the first (and only) non-test function in the lowered module
        if (loweredModule.functions.length == 0)
            return Value(0);

        ExecutionContext context;
        Value[] callerTemporaries;
        const result = executeFunction(
            loweredModule,
            loweredModule.functions[0].name,
            callerTemporaries,
            [],
            context,
        );

        return result;
    }
}

private void executeUnitTests(in imported!"quickbite.ir.module_".Module module_) @safe pure {
    foreach (index, test; module_.tests) {
        try {
            executeUnitTest(module_, test);
        } catch (UnittestAssertionFailure exception) {
            throw exception;
        } catch (UserThrownException exception) {
            throw exception;
        } catch (Exception exception) {
            import std.conv: text;

            throw new Exception(text(
                "Unittest ",
                index,
                " failed: ",
                exception.msg,
            ));
        }
    }
}

private imported!"quickbite.executor".TestSummary testSummary(
    in imported!"quickbite.ir.module_".Module module_,
) @safe {
    import quickbite.executor: TestSummary;

    TestSummary summary;
    foreach (test; module_.tests) {
        ++summary.total;
        try {
            executeUnitTest(module_, test);
            ++summary.passed;
        } catch (Exception) {
            ++summary.failed;
        }
    }

    return summary;
}

private void executeUnitTest(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.test".Test test,
) @safe pure {
    ExecutionContext context;
    executeInstructions(
        module_,
        test.instructions,
        test.numTemporaries,
        0,
        [],
        context,
    );
}

private Value executeFunction(
    in imported!"quickbite.ir.module_".Module module_,
    in string calleeName,
    ref Value[] callerTemporaries,
    in uint[] argumentIndices,
    ref ExecutionContext context,
) @safe pure {
    // Current lowered modules are tiny; add an index when benchmarks show this.
    foreach (function_; module_.functions) {
        if (function_.name == calleeName) {
            try {
                return executeFunctionBody(
                    module_,
                    function_.instructions,
                    function_.hasReturnValue,
                    function_.numParameters,
                    function_.refParameters,
                    function_.numTemporaries,
                    callerTemporaries,
                    argumentIndices,
                    context,
                );
            } catch (UnittestAssertionFailure exception) {
                throw exception;
            } catch (UserThrownException exception) {
                throw exception;
            } catch (Exception exception) {
                throw internalExecutionFailure(
                    "function",
                    calleeName,
                    exception,
                );
            }
        }
    }

    throw new Exception("Unsupported callee.");
}

private Value executeFunctionPointer(
    in imported!"quickbite.ir.module_".Module module_,
    in Value callee,
    ref Value[] callerTemporaries,
    in uint[] argumentIndices,
    ref ExecutionContext context,
) @safe pure {
    // Current lowered modules are tiny; add an index when benchmarks show this.
    foreach (functionIndex, function_; module_.functions) {
        if ((cast(long) functionIndex) + 1 == callee.asLong)
            return executeFunctionBody(
                module_,
                function_.instructions,
                function_.hasReturnValue,
                function_.numParameters,
                function_.refParameters,
                function_.numTemporaries,
                callerTemporaries,
                argumentIndices,
                context,
            );
    }

    throw new Exception("Unsupported function pointer callee.");
}

private Value executeFunctionBody(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in bool hasReturnValue,
    in uint numParameters,
    in bool[] refParameters,
    in uint numTemporaries,
    ref Value[] callerTemporaries,
    in uint[] argumentIndices,
    ref ExecutionContext context,
) @safe pure {
    const arguments = argumentValues(callerTemporaries, argumentIndices);
    ExecutionResult result = executeInstructions(
        module_,
        instructions,
        numTemporaries,
        numParameters,
        arguments,
        context,
    );
    writeRefArguments(
        result.temporaries,
        refParameters,
        callerTemporaries,
        argumentIndices,
    );
    if (!hasReturnValue)
        return Value(0);

    if (!result.hasReturn)
        throw new Exception("IR: missing return");

    return readTemporaryValue(result.temporaries, result.returnValue);
}

struct ExecutionResult {
    Value[] temporaries;
    bool hasReturn;
    uint returnValue;
}

struct ExecutionContext {
    // IR temporaries store array and struct references as indexes into these
    // tables. Index 0 is reserved for null/invalid references; allocated
    // values are stored at non-zero indexes.
    Value[][] arrays;
    Value[string][] structs;
    AssocArray[] assocArrays;
    Value[string] staticArrays;
    Value[string] staticAssocArrays;
    ArrayAlias[] arrayAliases;
    size_t[] safeAppendArrays;
}

struct AssocArray {
    // Keep keys and values in parallel arrays so key scans touch a compact
    // contiguous range; a KeyValue[] would interleave values into that walk.
    Value[] keys;
    Value[] values;
}

struct ArrayAlias {
    // A synthetic one-element array can stand in for an array element,
    // associative-array value, or slice. Mutations through `array` propagate
    // back to the represented storage below.
    size_t array;
    // Original dynamic array for element pointers and slices.
    size_t sourceArray;
    // Original associative array for associative value pointers.
    size_t assocArray;
    // Element index, slice lower bound, or associative-array key.
    Value key;
    bool isAssociative;
    bool isSlice;
}

private ExecutionResult executeInstructions(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint numTemporaries,
    in uint numParameters = 0,
    in Value[] arguments = [],
    ref ExecutionContext context,
) @safe pure {
    Value[] temporaries = new Value[numTemporaries];
    writeArguments(temporaries, numParameters, arguments);
    reserveNullArrayHandle(context.arrays);
    reserveNullStructHandle(context.structs);

    ExecutionResult result;
    result.temporaries = temporaries;

    uint instructionPointer;
    while (instructionPointer < instructions.length) {
        InstructionEffect effect;
        try {
            effect = executeInstruction(
                module_,
                instructions,
                instructionPointer,
                temporaries,
                context,
            );
        } catch (UnittestAssertionFailure exception) {
            throw exception;
        } catch (UserThrownException exception) {
            throw exception;
        } catch (Exception exception) {
            throw internalExecutionFailure(
                "instruction",
                instructionPointer,
                exception,
            );
        }
        if (effect.hasReturn) {
            result.hasReturn = true;
            result.returnValue = effect.returnValue;
            return result;
        }

        instructionPointer += effect.offset;
    }

    return result;
}

private Exception internalExecutionFailure(
    in string scope_,
    in string name,
    in Exception exception,
) @safe pure {
    import std.conv: text;

    // Internal executor failures need IR execution context for debugging; user
    // exceptions and unittest assertion failures are rethrown before this.
    return new Exception(text(scope_, " ", name, " failed: ", exception.msg));
}

private Exception internalExecutionFailure(
    in string scope_,
    in uint index,
    in Exception exception,
) @safe pure {
    import std.conv: text;

    return new Exception(text(scope_, " ", index, " failed: ", exception.msg));
}

private void reserveNullStructHandle(ref Value[string][] structs) @safe pure {
    if (structs.length == 0)
        structs ~= (Value[string]).init;
}

private void reserveNullArrayHandle(ref Value[][] arrays) @safe pure {
    if (arrays.length == 0)
        arrays ~= [];
}

struct InstructionEffect {
    // signed so backward Jumps (loops) can produce a negative delta.
    int offset;
    bool hasReturn;
    uint returnValue;
}

private InstructionEffect executeInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint instructionPointer,
    ref Value[] temporaries,
    ref ExecutionContext context,
) @safe pure {
    import instruction_ = quickbite.ir.instruction;
    import std.sumtype: match;

    const instruction = instructions[instructionPointer];

    with (context)
    with (instruction_)
    return instruction.match!(
        (ConstInt instruction) =>
            executeConstIntInstruction(temporaries, instruction),
        (const Call instruction) =>
            executeCallInstruction(module_, temporaries, context, instruction),
        (const IndirectCall instruction) =>
            executeIndirectCallInstruction(module_, temporaries, context, instruction),
        (BinaryOp instruction) =>
            executeBinaryOpInstruction(temporaries, instruction),
        (UnaryOp instruction) =>
            executeUnaryOpInstruction(temporaries, instruction),
        (Select instruction) =>
            executeSelectInstruction(temporaries, instruction),
        (JumpIfFalse instruction) =>
            executeJumpIfFalseInstruction(temporaries, instruction),
        (JumpIfTrue instruction) =>
            executeJumpIfTrueInstruction(temporaries, instruction),
        (Jump instruction) =>
            executeJumpInstruction(instruction),
        (const TryCatch instruction) =>
            executeTryCatchInstruction(
                module_,
                instructions,
                instructionPointer,
                temporaries,
                context,
                instruction,
            ),
        (Copy instruction) =>
            executeCopyInstruction(temporaries, instruction),
        (CastInt instruction) =>
            executeCastIntInstruction(temporaries, instruction),
        (Assert_ instruction) =>
            executeAssertInstruction(temporaries, context, instruction),
        (const ArrayLiteral instruction) =>
            executeArrayLiteralInstruction(temporaries, context, instruction),
        (const AssocArrayLiteral instruction) =>
            executeAssocArrayLiteralInstruction(temporaries, context, instruction),
        (AssocArrayLength instruction) =>
            executeAssocArrayLengthInstruction(temporaries, context, instruction),
        (AssocArrayKeys instruction) =>
            executeAssocArrayKeysInstruction(temporaries, context, instruction),
        (AssocArrayValues instruction) =>
            executeAssocArrayValuesInstruction(temporaries, context, instruction),
        (AssocArrayIndex instruction) =>
            executeAssocArrayIndexInstruction(temporaries, context, instruction),
        (AssocArrayValuePointer instruction) =>
            executeAssocArrayValuePointerInstruction(temporaries, context, instruction),
        (const StaticAssocArray instruction) =>
            executeStaticAssocArrayInstruction(temporaries, context, instruction),
        (const StaticArray instruction) =>
            executeStaticArrayInstruction(temporaries, context, instruction),
        (const StaticInt instruction) =>
            executeStaticIntInstruction(temporaries, context, instruction),
        (const StaticArraySet instruction) =>
            executeStaticArraySetInstruction(temporaries, context, instruction),
        (AssocArraySet instruction) =>
            executeAssocArraySetInstruction(temporaries, context, instruction),
        (ArrayCopy instruction) =>
            executeArrayCopyInstruction(temporaries, context, instruction),
        (ArrayReferenceCopy instruction) =>
            executeArrayReferenceCopyInstruction(temporaries, context, instruction),
        (ArrayAppend instruction) =>
            executeArrayAppendInstruction(temporaries, context, instruction),
        (ArrayAppendArray instruction) =>
            executeArrayAppendArrayInstruction(temporaries, context, instruction),
        (ArrayAssumeSafeAppend instruction) =>
            executeArrayAssumeSafeAppendInstruction(temporaries, context, instruction),
        (ArrayLength instruction) =>
            executeArrayLengthInstruction(temporaries, context, instruction),
        (ArraySetLength instruction) =>
            executeArraySetLengthInstruction(temporaries, context, instruction),
        (ArrayConcat instruction) =>
            executeArrayConcatInstruction(temporaries, context, instruction),
        (ArrayIndex instruction) =>
            executeArrayIndexInstruction(temporaries, context, instruction),
        (ArrayElementPointer instruction) =>
            executeArrayElementPointerInstruction(temporaries, context, instruction),
        (ArraySet instruction) =>
            executeArraySetInstruction(temporaries, context, instruction),
        (ArrayEqual instruction) =>
            executeArrayEqualInstruction(temporaries, context, instruction),
        (ArrayCanFind instruction) =>
            executeArrayCanFindInstruction(temporaries, context, instruction),
        (ArraySlice instruction) =>
            executeArraySliceInstruction(temporaries, context, instruction),
        (StructNew instruction) =>
            executeStructNewInstruction(temporaries, context, instruction),
        (const StructGet instruction) =>
            executeStructGetInstruction(temporaries, context, instruction),
        (const StructSet instruction) =>
            executeStructSetInstruction(temporaries, context, instruction),
        (ReturnValue instruction) =>
            executeReturnValueInstruction(instruction),
        (ReturnVoid instruction) =>
            executeReturnVoidInstruction(instruction),
    );
}

private InstructionEffect executeConstIntInstruction(
    ref Value[] temporaries,
    in imported!"quickbite.ir.instruction".ConstInt instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        instruction.value;
    return nextInstruction;
}

private InstructionEffect executeCallInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".Call instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        executeFunction(
            module_,
            instruction.calleeName,
            temporaries,
            instruction.arguments,
            context,
        );
    return nextInstruction;
}

private InstructionEffect executeIndirectCallInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".IndirectCall instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        executeFunctionPointer(
            module_,
            readTemporaryValue(temporaries, instruction.callee),
            temporaries,
            instruction.arguments,
            context,
        );
    return nextInstruction;
}

private InstructionEffect executeBinaryOpInstruction(
    ref Value[] temporaries,
    in imported!"quickbite.ir.instruction".BinaryOp instruction,
) @safe pure {
    executeBinaryInstruction(
        temporaries,
        instruction.destination,
        instruction.left,
        instruction.right,
        instruction.operation,
    );
    return nextInstruction;
}

private InstructionEffect executeUnaryOpInstruction(
    ref Value[] temporaries,
    in imported!"quickbite.ir.instruction".UnaryOp instruction,
) @safe pure {
    executeUnaryInstruction(
        temporaries,
        instruction.destination,
        instruction.source,
        instruction.operation,
    );
    return nextInstruction;
}

private InstructionEffect executeSelectInstruction(
    ref Value[] temporaries,
    in imported!"quickbite.ir.instruction".Select instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        readTemporaryValue(
            temporaries,
            instruction.condition,
        ).isTruthy
            ? readTemporaryValue(temporaries, instruction.ifTrue)
            : readTemporaryValue(temporaries, instruction.ifFalse);
    return nextInstruction;
}

private InstructionEffect executeJumpIfFalseInstruction(
    in Value[] temporaries,
    in imported!"quickbite.ir.instruction".JumpIfFalse instruction,
) @safe pure {
    if (!readTemporaryValue(temporaries, instruction.condition).isTruthy)
        return jump(instruction.offset + 1);

    return nextInstruction;
}

private InstructionEffect executeJumpIfTrueInstruction(
    in Value[] temporaries,
    in imported!"quickbite.ir.instruction".JumpIfTrue instruction,
) @safe pure {
    if (readTemporaryValue(temporaries, instruction.condition).isTruthy)
        return jump(instruction.offset + 1);

    return nextInstruction;
}

private InstructionEffect executeJumpInstruction(
    in imported!"quickbite.ir.instruction".Jump instruction,
) @safe pure {
    return jump(instruction.offset);
}

private InstructionEffect executeTryCatchInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint instructionPointer,
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".TryCatch instruction,
) @safe pure {
    const bodyStart = instructionPointer + 1;
    const handlerStart = bodyStart + instruction.bodyLength;
    const tryCatchEnd = handlerStart + instruction.handlerLength;

    try {
        const effect = executeInstructionRange(
            module_,
            instructions,
            bodyStart,
            handlerStart,
            temporaries,
            context,
        );
        if (effect.hasReturn)
            return effect;
    } catch (UserThrownException) {
        const effect = executeInstructionRange(
            module_,
            instructions,
            handlerStart,
            tryCatchEnd,
            temporaries,
            context,
        );
        if (effect.hasReturn)
            return effect;
    }

    return jump(cast(int) (tryCatchEnd - instructionPointer));
}

private InstructionEffect executeInstructionRange(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint start,
    in uint end,
    ref Value[] temporaries,
    ref ExecutionContext context,
) @safe pure {
    uint instructionPointer = start;
    while (instructionPointer < end) {
        InstructionEffect effect;
        try {
            effect = executeInstruction(
                module_,
                instructions,
                instructionPointer,
                temporaries,
                context,
            );
        } catch (UnittestAssertionFailure exception) {
            throw exception;
        } catch (UserThrownException exception) {
            throw exception;
        } catch (Exception exception) {
            throw internalExecutionFailure(
                "instruction",
                instructionPointer,
                exception,
            );
        }
        if (effect.hasReturn)
            return effect;

        instructionPointer += effect.offset;
    }

    return nextInstruction;
}

private InstructionEffect executeCopyInstruction(
    ref Value[] temporaries,
    in imported!"quickbite.ir.instruction".Copy instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        readTemporaryValue(temporaries, instruction.source);
    return nextInstruction;
}

private InstructionEffect executeCastIntInstruction(
    ref Value[] temporaries,
    in imported!"quickbite.ir.instruction".CastInt instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        castInteger(
            readTemporaryValue(temporaries, instruction.source),
            instruction.target,
        );
    return nextInstruction;
}

private InstructionEffect executeAssertInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".Assert_ instruction,
) @safe pure {
    return executeAssertInstruction(
        temporaries,
        context,
        instruction.condition,
        instruction,
    );
}

private InstructionEffect executeAssertInstruction(
    in Value[] temporaries,
    ref ExecutionContext context,
    in uint condition,
    in imported!"quickbite.ir.instruction".Assert_ instruction,
) @safe pure {
    if (readTemporaryValue(temporaries, condition))
        return nextInstruction;

    if (const exceptionMessage = thrownExceptionMessage(instruction.message))
        throw new UserThrownException(exceptionMessage);

    throw new UnittestAssertionFailure(assertionFailureMessage(
        temporaries,
        context,
        instruction,
    ));
}

private string assertionFailureMessage(
    in Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".Assert_ instruction,
) @safe pure {
    if (instruction.message.length != 0)
        return instruction.message;

    if (instruction.hasMessageValue)
        return arrayMessage(context.arrays[
            arrayIndex(temporaries, instruction.messageValue)
        ]);

    import quickbite.unittest_assertions: failedAssertionMessage;

    if (!instruction.hasComparisonContext)
        return "false != true";

    return failedAssertionMessage(
        instruction.messageMode,
        readTemporaryValue(temporaries, instruction.left),
        readTemporaryValue(temporaries, instruction.right),
        assertionOperator(instruction.comparison),
    );
}

private string arrayMessage(in Value[] values) @safe pure {
    char[] message;
    foreach (value; values)
        message ~= cast(char) value.asLong;
    return message.idup;
}

private string assertionInverseOperator(
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    switch (assertionOperator(operation)) {
        case "==":
            return "!=";
        case "!=":
            return "==";
        case "<":
            return ">=";
        case "<=":
            return ">";
        case ">":
            return "<=";
        case ">=":
            return "<";
        default:
            return "!=";
    }
}

private string assertionOperator(
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    with (Operation) final switch (operation) {
        case equal:
            return "==";
        case notEqual:
            return "!=";
        case lessThan:
        case unsignedLessThan:
            return "<";
        case lessOrEqual:
        case unsignedLessOrEqual:
            return "<=";
        case greaterThan:
        case unsignedGreaterThan:
            return ">";
        case greaterOrEqual:
        case unsignedGreaterOrEqual:
            return ">=";
        case add:
        case addDouble:
        case powDouble:
        case subtract:
        case multiply:
        case divide:
        case modulo:
        case leftShift:
        case rightShift:
        case bitwiseAnd:
        case bitwiseOr:
        case bitwiseXor:
            return "==";
    }
}

private InstructionEffect executeArrayLiteralInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayLiteral instruction,
) @safe pure {
    return executeArrayLiteralInstruction(
        temporaries,
        instruction.destination,
        instruction.elements,
        context,
    );
}

private InstructionEffect executeArrayLiteralInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint[] elements,
    ref ExecutionContext context,
) @safe pure {
    Value[] values;
    foreach (element; elements)
        values ~= readTemporaryValue(temporaries, element);

    context.arrays ~= values;
    writeTemporaryValue(temporaries, destination) =
        cast(long) (context.arrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeAssocArrayLiteralInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".AssocArrayLiteral instruction,
) @safe pure {
    return executeAssocArrayLiteralInstruction(
        temporaries,
        instruction.destination,
        instruction.keys,
        instruction.values,
        context,
    );
}

private InstructionEffect executeAssocArrayLiteralInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint[] keys,
    in uint[] values,
    ref ExecutionContext context,
) @safe pure {
    AssocArray assocArray;
    foreach (key; keys)
        assocArray.keys ~= readTemporaryValue(temporaries, key);
    foreach (value; values)
        assocArray.values ~= readTemporaryValue(temporaries, value);

    context.assocArrays ~= assocArray;
    writeTemporaryValue(temporaries, destination) =
        cast(long) (context.assocArrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeAssocArrayLengthInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".AssocArrayLength instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) context.assocArrays[
            assocArrayIndex(temporaries, instruction.array)
        ].keys.length;
    return nextInstruction;
}

private InstructionEffect executeAssocArrayKeysInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".AssocArrayKeys instruction,
) @safe pure {
    context.arrays ~= context.assocArrays[
        assocArrayIndex(temporaries, instruction.array)
    ].keys;
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) (context.arrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeAssocArrayValuesInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".AssocArrayValues instruction,
) @safe pure {
    context.arrays ~= context.assocArrays[
        assocArrayIndex(temporaries, instruction.array)
    ].values;
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) (context.arrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeAssocArrayIndexInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".AssocArrayIndex instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        assocArrayValue(
            context.assocArrays[assocArrayIndex(temporaries, instruction.array)],
            readTemporaryValue(temporaries, instruction.key),
        );
    return nextInstruction;
}

private InstructionEffect executeAssocArrayValuePointerInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".AssocArrayValuePointer instruction,
) @safe pure {
    return executeAssocArrayValuePointerInstruction(
        temporaries,
        instruction.destination,
        instruction.array,
        instruction.key,
        context,
    );
}

private InstructionEffect executeAssocArrayValuePointerInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint arrayTemporary,
    in uint keyTemporary,
    ref ExecutionContext context,
) @safe pure {
    const array = assocArrayIndex(temporaries, arrayTemporary);
    const key = readTemporaryValue(temporaries, keyTemporary);
    context.arrays ~= [
        assocArrayValue(
            context.assocArrays[array],
            key,
        ),
    ];
    const pointer = context.arrays.length - 1;
    context.arrayAliases ~= ArrayAlias(pointer, 0, array, key, true, false);
    writeTemporaryValue(temporaries, destination) = cast(long) pointer;
    return nextInstruction;
}

private InstructionEffect executeStaticAssocArrayInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StaticAssocArray instruction,
) @safe pure {
    return executeStaticAssocArrayInstruction(
        temporaries,
        instruction.destination,
        instruction.name,
        context,
    );
}

private InstructionEffect executeStaticAssocArrayInstruction(
    ref Value[] temporaries,
    in uint destination,
    in string name,
    ref ExecutionContext context,
) @safe pure {
    if (auto array = name in context.staticAssocArrays) {
        writeTemporaryValue(temporaries, destination) = *array;
        return nextInstruction;
    }

    context.assocArrays ~= AssocArray.init;
    const array = cast(long) (context.assocArrays.length - 1);
    context.staticAssocArrays[name] = array;
    writeTemporaryValue(temporaries, destination) = array;
    return nextInstruction;
}

private InstructionEffect executeStaticArrayInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StaticArray instruction,
) @safe pure {
    return executeStaticArrayInstruction(
        temporaries,
        instruction.destination,
        instruction.name,
        context,
    );
}

private InstructionEffect executeStaticArrayInstruction(
    ref Value[] temporaries,
    in uint destination,
    in string name,
    ref ExecutionContext context,
) @safe pure {
    if (auto array = name in context.staticArrays) {
        writeTemporaryValue(temporaries, destination) = *array;
        return nextInstruction;
    }

    context.arrays ~= [];
    const array = cast(long) (context.arrays.length - 1);
    context.staticArrays[name] = array;
    writeTemporaryValue(temporaries, destination) = array;
    return nextInstruction;
}

private InstructionEffect executeStaticIntInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StaticInt instruction,
) @safe pure {
    if (auto value = instruction.name in context.staticArrays) {
        writeTemporaryValue(temporaries, instruction.destination) = *value;
        return nextInstruction;
    }

    writeTemporaryValue(temporaries, instruction.destination) = 0;
    return nextInstruction;
}

private InstructionEffect executeStaticArraySetInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StaticArraySet instruction,
) @safe pure {
    context.staticArrays[instruction.name] =
        readTemporaryValue(temporaries, instruction.value);
    return nextInstruction;
}

private InstructionEffect executeAssocArraySetInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".AssocArraySet instruction,
) @safe pure {
    writeAssocArrayValue(
        context.assocArrays[assocArrayIndex(temporaries, instruction.array)],
        readTemporaryValue(temporaries, instruction.key),
        readTemporaryValue(temporaries, instruction.value),
    );
    return nextInstruction;
}

private InstructionEffect executeArrayCopyInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayCopy instruction,
) @safe pure {
    context.arrays ~= copyArrayValue(
        context.arrays,
        arrayIndex(temporaries, instruction.source),
    );
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) (context.arrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeArrayReferenceCopyInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayReferenceCopy instruction,
) @safe pure {
    context.arrays ~= referenceArrayValue(
        context.arrays,
        arrayIndex(temporaries, instruction.source),
    );
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) (context.arrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeArrayAppendInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayAppend instruction,
) @safe pure {
    appendArrayValue(
        context,
        arrayIndex(temporaries, instruction.array),
        readTemporaryValue(temporaries, instruction.value),
    );
    return nextInstruction;
}

private InstructionEffect executeArrayAppendArrayInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayAppendArray instruction,
) @safe pure {
    appendArrayValues(
        context,
        arrayIndex(temporaries, instruction.array),
        context.arrays[arrayIndex(temporaries, instruction.value)],
    );
    return nextInstruction;
}

private InstructionEffect executeArrayAssumeSafeAppendInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayAssumeSafeAppend instruction,
) @safe pure {
    const array = arrayIndex(temporaries, instruction.array);
    foreach (safeAppendArray; context.safeAppendArrays)
        if (safeAppendArray == array)
            return nextInstruction;

    context.safeAppendArrays ~= array;
    return nextInstruction;
}

private InstructionEffect executeArrayLengthInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayLength instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) context.arrays[
            arrayIndex(temporaries, instruction.array)
        ].length;
    return nextInstruction;
}

private InstructionEffect executeArraySetLengthInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArraySetLength instruction,
) @safe pure {
    context.arrays[arrayIndex(temporaries, instruction.array)].length =
        arrayIndex(temporaries, instruction.length);
    return nextInstruction;
}

private InstructionEffect executeArrayConcatInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayConcat instruction,
) @safe pure {
    context.arrays ~=
        context.arrays[arrayIndex(temporaries, instruction.left)] ~
        context.arrays[arrayIndex(temporaries, instruction.right)];
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) (context.arrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeArrayIndexInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayIndex instruction,
) @safe pure {
    return executeArrayIndexInstruction(
        temporaries,
        instruction.destination,
        instruction.array,
        instruction.index,
        context,
    );
}

private InstructionEffect executeArrayIndexInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint arrayTemporary,
    in uint indexTemporary,
    ref ExecutionContext context,
) @safe pure {
    const array = arrayIndex(temporaries, arrayTemporary);
    const index = arrayIndex(temporaries, indexTemporary);
    if (array >= context.arrays.length) {
        if (index == 0) {
            writeTemporaryValue(temporaries, destination) =
                readTemporaryValue(temporaries, arrayTemporary);
            return nextInstruction;
        }

        import std.conv: text;

        throw new Exception(text(
            "IR: array handle ",
            array,
            " out of range, arrays = ",
            context.arrays,
            ", temporaries = ",
            temporaries,
        ));
    }
    if (index >= context.arrays[array].length) {
        import std.conv: text;

        throw new Exception(text(
            "IR: array index ",
            index,
            " out of range for array ",
            array,
            " length ",
            context.arrays[array].length,
            ", arrays = ",
            context.arrays,
            ", temporaries = ",
            temporaries,
        ));
    }
    writeTemporaryValue(temporaries, destination) = context.arrays[array][index];
    return nextInstruction;
}

private InstructionEffect executeArrayElementPointerInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayElementPointer instruction,
) @safe pure {
    return executeArrayElementPointerInstruction(
        temporaries,
        instruction.destination,
        instruction.array,
        instruction.index,
        context,
    );
}

private InstructionEffect executeArrayElementPointerInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint arrayTemporary,
    in uint indexTemporary,
    ref ExecutionContext context,
) @safe pure {
    const array = arrayIndex(temporaries, arrayTemporary);
    const index = arrayIndex(temporaries, indexTemporary);
    context.arrays ~= [context.arrays[array][index]];
    const pointer = context.arrays.length - 1;
    context.arrayAliases ~= ArrayAlias(
        pointer,
        array,
        0,
        Value(cast(long) index),
        false,
        false,
    );
    writeTemporaryValue(temporaries, destination) = cast(long) pointer;
    return nextInstruction;
}

private InstructionEffect executeArraySetInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArraySet instruction,
) @safe pure {
    writeArrayValue(
        context.arrays,
        arrayIndex(temporaries, instruction.array),
        arrayIndex(temporaries, instruction.index),
        readTemporaryValue(temporaries, instruction.value),
    );
    updateArrayAlias(
        temporaries,
        instruction.array,
        instruction.index,
        instruction.value,
        context,
    );
    return nextInstruction;
}

private InstructionEffect executeArrayEqualInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayEqual instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        arraysEqual(
            context.arrays,
            arrayIndex(temporaries, instruction.left),
            arrayIndex(temporaries, instruction.right),
            instruction.depth,
        );
    return nextInstruction;
}

private InstructionEffect executeArrayCanFindInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayCanFind instruction,
) @safe pure {
    import std.algorithm.searching: countUntil;
    import quickbite.ir.instruction: Operation;

    writeTemporaryValue(temporaries, instruction.destination) =
        context.arrays[arrayIndex(temporaries, instruction.haystack)]
        .countUntil!((left, right) =>
            compareScalarValues(left, right, Operation.equal))(
            context.arrays[arrayIndex(temporaries, instruction.needle)],
        ) >= 0;
    return nextInstruction;
}

private InstructionEffect executeArraySliceInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArraySlice instruction,
) @safe pure {
    return executeArraySliceInstruction(
        temporaries,
        instruction.destination,
        instruction.array,
        instruction.lower,
        instruction.upper,
        context,
    );
}

private InstructionEffect executeArraySliceInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint arrayTemporary,
    in uint lowerTemporary,
    in uint upperTemporary,
    ref ExecutionContext context,
) @safe pure {
    const array = arrayIndex(temporaries, arrayTemporary);
    const lower = arrayIndex(temporaries, lowerTemporary);
    const upper = arrayIndex(temporaries, upperTemporary);
    context.arrays ~= context.arrays[array][lower .. upper];
    const slice = context.arrays.length - 1;
    // Explicit type: auto keeps `array` const, but nested aliases rewrite this.
    size_t sourceArray = array;
    auto sourceLower = Value(cast(long) lower); // Rewritten below for nested slices.
    foreach (alias_; context.arrayAliases) {
        if (alias_.array != array || !alias_.isSlice)
            continue;

        sourceArray = alias_.sourceArray;
        sourceLower = Value(alias_.key.asLong + cast(long) lower);
        break;
    }
    context.arrayAliases ~= ArrayAlias(
        slice,
        sourceArray,
        0,
        sourceLower,
        false,
        true,
    );
    writeTemporaryValue(temporaries, destination) = cast(long) slice;
    return nextInstruction;
}

private InstructionEffect executeStructNewInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StructNew instruction,
) @safe pure {
    context.structs ~= (Value[string]).init;
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) (context.structs.length - 1);
    return nextInstruction;
}

private InstructionEffect executeStructGetInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StructGet instruction,
) @safe pure {
    return executeStructGetInstruction(
        temporaries,
        instruction.destination,
        instruction.struct_,
        instruction.fieldName,
        context,
    );
}

private InstructionEffect executeStructGetInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint structTemporary,
    in string fieldName,
    ref ExecutionContext context,
) @safe pure {
    const index = structIndex(temporaries, structTemporary);
    if (fieldName == "length" && index < context.arrays.length) {
        if (index >= context.structs.length || "length" !in context.structs[index]) {
            writeTemporaryValue(temporaries, destination) =
                cast(long) context.arrays[index].length;
            return nextInstruction;
        }
    }
    if (index >= context.structs.length) {
        import std.conv: text;

        throw new Exception(text(
            "IR: struct handle ",
            index,
            " out of range, structs = ",
            context.structs,
            ", temporaries = ",
            temporaries,
        ));
    }
    Value value;
    if (auto stored = fieldName in context.structs[index])
        value = *stored;

    writeTemporaryValue(temporaries, destination) = value;
    return nextInstruction;
}

private InstructionEffect executeStructSetInstruction(
    ref Value[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StructSet instruction,
) @safe pure {
    context.structs[structIndex(temporaries, instruction.struct_)][
        instruction.fieldName
    ] = readTemporaryValue(temporaries, instruction.value);
    return nextInstruction;
}

private InstructionEffect executeReturnValueInstruction(
    in imported!"quickbite.ir.instruction".ReturnValue instruction,
) @safe pure nothrow @nogc {
    return returnFromFunction(instruction.value);
}

private InstructionEffect executeReturnVoidInstruction(
    in imported!"quickbite.ir.instruction".ReturnVoid instruction,
) @safe pure nothrow @nogc {
    return returnFromVoid;
}

private InstructionEffect nextInstruction() @safe pure nothrow @nogc {
    return InstructionEffect(1);
}

private string thrownExceptionMessage(in string message) @safe pure nothrow {
    enum prefix = "throw ";
    if (message.length < prefix.length || message[0 .. prefix.length] != prefix)
        return null;

    return message[prefix.length .. $];
}

private InstructionEffect jump(in int offset) @safe pure nothrow @nogc {
    return InstructionEffect(offset);
}

private InstructionEffect returnFromFunction(in uint value) @safe pure nothrow @nogc {
    return InstructionEffect(0, true, value);
}

private InstructionEffect returnFromVoid() @safe pure nothrow @nogc {
    return InstructionEffect(0, true);
}

private Value castInteger(
    in Value source,
    in imported!"quickbite.ir.instruction".IntegerType target,
) @safe pure {
    import quickbite.ir.instruction: IntegerType;

    if (source.isFloating)
        return castFloatingToInteger(source.asDouble, target);

    const value = source.asLong;
    with (IntegerType)
    final switch (target) {
        case i8:
            return Value(cast(byte) value);
        case u8:
            return Value(cast(ubyte) value);
        case i16:
            return Value(cast(short) value);
        case u16:
            return Value(cast(ushort) value);
        case i32:
            return Value(cast(int) value);
        case u32:
            return Value(cast(uint) value);
        case i64:
            return Value(cast(long) value);
        case u64:
            return Value(cast(ulong) value);
        case char_:
            return Value(cast(char) value);
        case wchar_:
            return Value(cast(wchar) value);
        case dchar_:
            return Value(cast(dchar) value);
    }
}

private Value castFloatingToInteger(
    in double source,
    in imported!"quickbite.ir.instruction".IntegerType target,
) @safe pure {
    import quickbite.ir.instruction: IntegerType;

    with (IntegerType)
    final switch (target) {
        case i8:
            return Value(cast(byte) source);
        case u8:
            return Value(cast(ubyte) source);
        case i16:
            return Value(cast(short) source);
        case u16:
            return Value(cast(ushort) source);
        case i32:
            return Value(cast(int) source);
        case u32:
            return Value(cast(uint) source);
        case i64:
            return Value(cast(long) source);
        case u64:
            return Value(cast(ulong) source);
        case char_:
            return Value(cast(char) source);
        case wchar_:
            return Value(cast(wchar) source);
        case dchar_:
            return Value(cast(dchar) source);
    }
}

private void writeArguments(
    ref Value[] temporaries,
    in uint numParameters,
    in Value[] arguments,
) @safe pure {
    if (arguments.length != numParameters)
        throw new Exception("Unsupported call.");

    foreach (index, argument; arguments)
        writeTemporaryValue(temporaries, cast(uint) index) = argument;
}

private void writeRefArguments(
    in Value[] calleeTemporaries,
    in bool[] refParameters,
    ref Value[] callerTemporaries,
    in uint[] argumentIndices,
) @safe pure {
    foreach (index, isRef; refParameters) {
        if (!isRef)
            continue;

        writeTemporaryValue(callerTemporaries, argumentIndices[index]) =
            readTemporaryValue(calleeTemporaries, cast(uint) index);
    }
}

private Value[] argumentValues(in Value[] temporaries, in uint[] arguments) @safe pure {
    Value[] result;

    foreach (argument; arguments)
        result ~= readTemporaryValue(temporaries, argument);

    return result;
}

private void executeBinaryInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint left,
    in uint right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    const leftValue = readTemporaryValue(temporaries, left);
    const rightValue = readTemporaryValue(temporaries, right);
    long integerResult;
    Value result;
    bool hasResult;

    with (Operation)
    final switch (operation) {
        case add:
            integerResult = leftValue.asLong + rightValue.asLong;
            break;
        case addDouble:
            result = Value(leftValue.asDouble + rightValue.asDouble);
            hasResult = true;
            break;
        case powDouble:
            import std.math: pow;

            if (leftValue.isFloat32 && rightValue.isFloat32) {
                result = Value(pow(
                    cast(float) leftValue.asDouble,
                    cast(float) rightValue.asDouble,
                ));
                hasResult = true;
                break;
            }

            result = Value(pow(leftValue.asDouble, rightValue.asDouble));
            hasResult = true;
            break;
        case subtract:
            if (leftValue.isFloating || rightValue.isFloating) {
                result = Value(leftValue.asDouble - rightValue.asDouble);
                hasResult = true;
                break;
            }

            integerResult = leftValue.asLong - rightValue.asLong;
            break;
        case multiply:
            if (leftValue.isFloating || rightValue.isFloating) {
                result = Value(leftValue.asDouble * rightValue.asDouble);
                hasResult = true;
                break;
            }

            integerResult = leftValue.asLong * rightValue.asLong;
            break;
        case divide:
            if (leftValue.isFloating || rightValue.isFloating) {
                result = Value(leftValue.asDouble / rightValue.asDouble);
                hasResult = true;
                break;
            }

            const rightLong = rightValue.asLong;
            enforceNonZeroDivisor(rightLong);
            integerResult = leftValue.asLong / rightLong;
            break;
        case modulo:
            const rightLong = rightValue.asLong;
            enforceNonZeroDivisor(rightLong);
            integerResult = leftValue.asLong % rightLong;
            break;
        case leftShift:
            integerResult = leftValue.asLong << rightValue.asLong;
            break;
        case rightShift:
            integerResult = leftValue.asLong >> rightValue.asLong;
            break;
        case bitwiseAnd:
            integerResult = leftValue.asLong & rightValue.asLong;
            break;
        case bitwiseOr:
            integerResult = leftValue.asLong | rightValue.asLong;
            break;
        case bitwiseXor:
            integerResult = leftValue.asLong ^ rightValue.asLong;
            break;
        case equal:
            integerResult = compareScalarValues(leftValue, rightValue, operation);
            break;
        case notEqual:
            integerResult = compareScalarValues(leftValue, rightValue, operation);
            break;
        case lessThan:
            integerResult = compareScalarValues(leftValue, rightValue, operation);
            break;
        case unsignedLessThan:
            integerResult =
                compareUnsignedScalarValues(leftValue, rightValue, operation);
            break;
        case lessOrEqual:
            integerResult = compareScalarValues(leftValue, rightValue, operation);
            break;
        case unsignedLessOrEqual:
            integerResult =
                compareUnsignedScalarValues(leftValue, rightValue, operation);
            break;
        case greaterThan:
            integerResult = compareScalarValues(leftValue, rightValue, operation);
            break;
        case greaterOrEqual:
            integerResult = compareScalarValues(leftValue, rightValue, operation);
            break;
        case unsignedGreaterOrEqual:
            integerResult =
                compareUnsignedScalarValues(leftValue, rightValue, operation);
            break;
        case unsignedGreaterThan:
            integerResult =
                compareUnsignedScalarValues(leftValue, rightValue, operation);
            break;
    }

    writeTemporaryValue(temporaries, destination) =
        hasResult ? result : Value(integerResult);
}

private bool compareScalarValues(
    in Value left,
    in Value right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    if (operation == Operation.equal)
        return scalarValuesEqual(left, right);

    if (operation == Operation.notEqual)
        return !scalarValuesEqual(left, right);

    if (left.isFloating || right.isFloating)
        return compareReals(left.asReal, right.asReal, operation);

    return compareLongs(left.asLong, right.asLong, operation);
}

private bool scalarValuesEqual(in Value left, in Value right) @safe pure {
    if (left.isFloating || right.isFloating)
        return left.asReal == right.asReal;

    return left.asLong == right.asLong;
}

private bool compareUnsignedScalarValues(
    in Value left,
    in Value right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    if (left.isFloating || right.isFloating)
        return compareReals(
            unsignedComparisonReal(left),
            unsignedComparisonReal(right),
            operation,
        );

    return compareUlongs(
        cast(ulong) left.asLong,
        cast(ulong) right.asLong,
        operation,
    );
}

private real unsignedComparisonReal(in Value value) @safe pure {
    if (value.isFloating)
        return value.asReal;

    return cast(real) cast(ulong) value.asLong;
}

private bool compareReals(
    in real left,
    in real right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    with (Operation) final switch (operation) {
        case equal:
            return left == right;
        case notEqual:
            return left != right;
        case lessThan:
        case unsignedLessThan:
            return left < right;
        case lessOrEqual:
        case unsignedLessOrEqual:
            return left <= right;
        case greaterThan:
        case unsignedGreaterThan:
            return left > right;
        case greaterOrEqual:
        case unsignedGreaterOrEqual:
            return left >= right;
        case add:
        case addDouble:
        case powDouble:
        case subtract:
        case multiply:
        case divide:
        case modulo:
        case leftShift:
        case rightShift:
        case bitwiseAnd:
        case bitwiseOr:
        case bitwiseXor:
            throw new Exception("Unsupported floating comparison operation.");
    }
}

private bool compareUlongs(
    in ulong left,
    in ulong right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    with (Operation) final switch (operation) {
        case unsignedLessThan:
            return left < right;
        case unsignedLessOrEqual:
            return left <= right;
        case unsignedGreaterThan:
            return left > right;
        case unsignedGreaterOrEqual:
            return left >= right;
        case equal:
        case notEqual:
        case lessThan:
        case lessOrEqual:
        case greaterThan:
        case greaterOrEqual:
        case add:
        case addDouble:
        case powDouble:
        case subtract:
        case multiply:
        case divide:
        case modulo:
        case leftShift:
        case rightShift:
        case bitwiseAnd:
        case bitwiseOr:
        case bitwiseXor:
            throw new Exception("Unsupported unsigned comparison operation.");
    }
}

private bool compareLongs(
    in long left,
    in long right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    with (Operation) final switch (operation) {
        case equal:
            return left == right;
        case notEqual:
            return left != right;
        case lessThan:
            return left < right;
        case lessOrEqual:
            return left <= right;
        case greaterThan:
            return left > right;
        case greaterOrEqual:
            return left >= right;
        case unsignedLessThan:
        case unsignedLessOrEqual:
        case unsignedGreaterOrEqual:
        case unsignedGreaterThan:
        case add:
        case addDouble:
        case powDouble:
        case subtract:
        case multiply:
        case divide:
        case modulo:
        case leftShift:
        case rightShift:
        case bitwiseAnd:
        case bitwiseOr:
        case bitwiseXor:
            throw new Exception("Unsupported integer comparison operation.");
    }
}

private Value[] copyArrayValue(in Value[][] arrays, in size_t handle) @safe pure {
    if (handle < arrays.length)
        return arrays[handle].dup;

    if (handle == 0)
        return [];

    throw arrayHandleException(arrays, handle);
}

private Value[] referenceArrayValue(ref Value[][] arrays, in size_t handle) @safe pure {
    if (handle < arrays.length)
        return arrays[handle];

    if (handle == 0)
        return [];

    throw arrayHandleException(arrays, handle);
}

private void executeUnaryInstruction(
    ref Value[] temporaries,
    in uint destination,
    in uint source,
    in imported!"quickbite.ir.instruction".UnaryOperation operation,
) @safe pure {
    import quickbite.ir.instruction: UnaryOperation;

    const sourceValue = readTemporaryValue(temporaries, source);
    long integerResult;
    Value result;

    with (UnaryOperation)
    final switch (operation) {
        case negate:
            if (sourceValue.isFloating) {
                result = Value(-sourceValue.asDouble);
                break;
            }

            integerResult = -sourceValue.asLong;
            break;
        case not:
            integerResult = !sourceValue.isTruthy;
            break;
        case complement:
            integerResult = ~sourceValue.asLong;
            break;
        case bitScanReverse:
            integerResult = bitScanReverseValue(sourceValue.asLong);
            break;
        case fabsDouble:
            import std.math: fabs;

            if (sourceValue.isFloat32) {
                result = Value(fabs(cast(float) sourceValue.asDouble));
                break;
            }

            result = Value(fabs(sourceValue.asDouble));
            break;
        case isInfinityDouble:
            import std.math: isInfinity;

            integerResult = isInfinity(sourceValue.asDouble) ? 1 : 0;
            break;
        case isNaNDouble:
            import std.math: isNaN;

            integerResult = isNaN(sourceValue.asDouble) ? 1 : 0;
            break;
        case signbitDouble:
            integerResult =
                (cast(ulong) doubleBits(sourceValue.asDouble) & (1UL << 63)) != 0;
            break;
        case sqrtDouble:
            import std.math: sqrt;

            result = Value(sqrt(sourceValue.asDouble));
            break;
        case floatToUintBits:
            result = Value(floatBits(cast(float) sourceValue.asDouble));
            break;
        case uintBitsToFloat:
            result = Value(floatFromBits(cast(uint) sourceValue.asLong));
            break;
        case doubleToUlongBits:
            result = Value(cast(ulong) doubleBits(sourceValue.asDouble));
            break;
        case ulongBitsToDouble:
            result = Value(doubleFromBits(sourceValue.asLong));
            break;
        case ulongToDouble:
            result = Value(cast(double) cast(ulong) sourceValue.asLong);
            break;
        case longToFloat:
            result = Value(cast(float) sourceValue.asLong);
            break;
        case ulongToReal:
            result = Value(cast(real) cast(ulong) sourceValue.asLong);
            break;
    }

    writeTemporaryValue(temporaries, destination) =
        result == Value.init ? Value(integerResult) : result;
}

private long doubleBits(in double value) @trusted pure nothrow {
    return cast(long) *cast(ulong*) &value;
}

private uint floatBits(in float value) @trusted pure nothrow {
    return *cast(uint*) &value;
}

private float floatFromBits(in uint value) @trusted pure nothrow {
    return *cast(float*) &value;
}

private double doubleFromBits(in long value) @trusted pure nothrow {
    return *cast(double*) &value;
}

private long bitScanReverseValue(in long sourceValue) @safe pure nothrow @nogc {
    // Implements the IR UnaryOperation.bitScanReverse semantics. core.bitop.bsr
    // is avoided here because this VM needs the explicit zero result below.
    const bits = cast(ulong) sourceValue;
    foreach_reverse (index; 0 .. 64) {
        const mask = 1UL << index;
        if ((bits & mask) != 0)
            return cast(long) index;
    }

    return -1;
}

private void enforceNonZeroDivisor(in long value) @safe pure {
    if (value == 0)
        throw new UnittestAssertionFailure;
}

private Value readTemporaryValue(in Value[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

private ref Value writeTemporaryValue(ref Value[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

private size_t arrayIndex(in Value[] temporaries, in uint temporary) @safe pure {
    return readTemporaryValue(temporaries, temporary).asIndex;
}

private bool arraysEqual(
    in Value[][] arrays,
    in size_t left,
    in size_t right,
    in uint depth,
) @safe pure {
    import std.algorithm.comparison: equal;
    import quickbite.ir.instruction: Operation;

    enforceArrayHandle(arrays, left);
    enforceArrayHandle(arrays, right);
    if (depth <= 1)
        return equal!((leftValue, rightValue) =>
            compareScalarValues(leftValue, rightValue, Operation.equal))(
            arrays[left],
            arrays[right],
        );

    return equal!((leftValue, rightValue) => arraysEqual(
            arrays,
            arrayHandle(leftValue),
            arrayHandle(rightValue),
            depth - 1,
        ))(arrays[left], arrays[right]);
}

private void enforceArrayHandle(
    in Value[][] arrays,
    in size_t handle,
) @safe pure {
    if (handle >= arrays.length)
        throw arrayHandleException(arrays, handle);
}

private Exception arrayHandleException(
    in Value[][] arrays,
    in size_t handle,
) @safe pure {
    import std.conv: text;

    return new Exception(text(
        "IR: array handle ",
        handle,
        " out of range, arrays = ",
        arrays,
    ));
}

private size_t arrayHandle(in Value value) @safe pure {
    // Array references are stored in IR temporaries as signed integer indexes.
    // Convert only after rejecting negative values so callers can index the
    // array table with size_t.
    return value.asIndex;
}

private size_t assocArrayIndex(in Value[] temporaries, in uint temporary) @safe pure {
    return readTemporaryValue(temporaries, temporary).asIndex;
}

private Value assocArrayValue(in AssocArray array, in Value key) @safe pure {
    import quickbite.ir.instruction: Operation;

    foreach (index, existingKey; array.keys)
        if (compareScalarValues(existingKey, key, Operation.equal))
            return array.values[index];

    return Value(0);
}

private void writeAssocArrayValue(
    ref AssocArray array,
    in Value key,
    in Value value,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    foreach (index, existingKey; array.keys) {
        if (!compareScalarValues(existingKey, key, Operation.equal))
            continue;

        array.values[index] = value;
        return;
    }

    array.keys ~= key;
    array.values ~= value;
}

private void appendArrayValues(
    ref ExecutionContext context,
    in size_t array,
    in Value[] values,
) @safe pure {
    foreach (value; values)
        appendArrayValue(context, array, value);
}

private void appendArrayValue(
    ref ExecutionContext context,
    in size_t array,
    in Value value,
) @safe pure {
    const index = context.arrays[array].length;
    context.arrays[array] ~= value;
    if (arrayAllowsSafeAppend(context, array))
        updateSliceArrayAlias(context, array, index, value);
}

private bool arrayAllowsSafeAppend(
    in ExecutionContext context,
    in size_t array,
) @safe pure {
    foreach (safeAppendArray; context.safeAppendArrays)
        if (safeAppendArray == array)
            return true;

    return false;
}

private void updateSliceArrayAlias(
    ref ExecutionContext context,
    in size_t array,
    in size_t index,
    in Value value,
) @safe pure {
    foreach (alias_; context.arrayAliases) {
        if (alias_.array != array || !alias_.isSlice)
            continue;

        const sourceIndex = cast(size_t) (alias_.key.asLong + cast(long) index);
        writeArrayValue(context.arrays, alias_.sourceArray, sourceIndex, value);
        return;
    }
}

private void writeArrayValue(
    ref Value[][] arrays,
    in size_t array,
    in size_t index,
    in Value value,
) @safe pure {
    if (array >= arrays.length) {
        throw arrayHandleException(arrays, array);
    }
    if (index < arrays[array].length) {
        arrays[array][index] = value;
        return;
    }

    if (index != arrays[array].length)
        throw new Exception("IR: array index out of range");

    arrays[array] ~= value;
}

private void updateArrayAlias(
    in Value[] temporaries,
    in uint arrayTemporary,
    in uint indexTemporary,
    in uint valueTemporary,
    ref ExecutionContext context,
) @safe pure {
    const array = arrayIndex(temporaries, arrayTemporary);
    const index = arrayIndex(temporaries, indexTemporary);
    foreach (alias_; context.arrayAliases) {
        if (alias_.array != array)
            continue;

        const value = readTemporaryValue(temporaries, valueTemporary);
        if (alias_.isSlice) {
            writeArrayValue(
                context.arrays,
                alias_.sourceArray,
                cast(size_t) (alias_.key.asLong + cast(long) index),
                value,
            );
        } else if (alias_.isAssociative && index == 0) {
            writeAssocArrayValue(
                context.assocArrays[alias_.assocArray],
                alias_.key,
                value,
            );
        } else if (index == 0) {
            context.arrays[alias_.sourceArray][alias_.key.asIndex] = value;
        }
        return;
    }
}

private size_t structIndex(in Value[] temporaries, in uint temporary) @safe pure {
    return readTemporaryValue(temporaries, temporary).asIndex;
}

private void enforceTemporaryIndex(in ulong length, in uint index) @safe pure {
    if (index >= length)
        throw new Exception("IR: temporary index out of range");
}

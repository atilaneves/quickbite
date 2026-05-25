module quickbite.backends.ir;

private:

private class UnittestAssertionFailure : Exception {
    public this() @safe pure {
        super("Unittest assertion failed.");
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

        auto parsed = parseModule(source);
        runParsedTests(parsed.module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        auto parsed = parseModule(source, importPaths);
        runParsedTests(parsed.module_);
    }

    public override void runParsedTests(Module module_) {
        import quickbite.frontend.compiler: lowerModule;

        const loweredModule = lowerModule(module_);
        executeUnitTests(loweredModule);
    }

    public override TestSummary runTestSummary(
        in string source,
    ) {
        import quickbite.frontend.compiler: lowerModule, parseModule;

        // Keep `parsed` mutable: the DMD frontend owns mutable Module state.
        auto parsed = parseModule(source);
        const loweredModule = lowerModule(parsed.module_);
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

        auto parsed = parseModule(source);
        const loweredModule = lowerModule(parsed.module_);

        // f is the first (and only) non-test function in the lowered module
        if (loweredModule.functions.length == 0)
            return Value(0);

        ExecutionContext context;
        long[] callerTemporaries;
        const result = executeFunction(
            loweredModule,
            loweredModule.functions[0].name,
            callerTemporaries,
            [],
            context,
        );

        return Value(cast(int) result);
    }

    public override imported!"quickbite.executor".Repl.CellResult evalReplCell(
        in string transcript,
        in string input,
    ) {
        import quickbite.executor: Repl;
        import quickbite.frontend.repl: isExpressionCell;

        if (isExpressionCell(input))
            return Repl.CellResult.value_(eval(transcript ~ input));

        runVoidReplCell(transcript, input);
        return Repl.CellResult.void_;
    }

    private void runVoidReplCell(in string transcript, in string input) {
        import quickbite.frontend.compiler: lowerModule, parseModule;

        const source =
            "unittest { auto f() { " ~ transcript ~ input ~ " } f(); }";

        auto parsed = parseModule(source);
        const loweredModule = lowerModule(parsed.module_);
        executeUnitTests(loweredModule);
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

private long executeFunction(
    in imported!"quickbite.ir.module_".Module module_,
    in string calleeName,
    ref long[] callerTemporaries,
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

private long executeFunctionPointer(
    in imported!"quickbite.ir.module_".Module module_,
    in long callee,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
    ref ExecutionContext context,
) @safe pure {
    // Current lowered modules are tiny; add an index when benchmarks show this.
    foreach (functionIndex, function_; module_.functions) {
        if ((cast(long) functionIndex) + 1 == callee)
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

private long executeFunctionBody(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in bool hasReturnValue,
    in uint numParameters,
    in bool[] refParameters,
    in uint numTemporaries,
    ref long[] callerTemporaries,
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

struct ExecutionContext {
    // IR temporaries store array and struct references as indexes into these
    // tables. Index 0 is reserved for null/invalid references; allocated
    // values are stored at non-zero indexes.
    long[][] arrays;
    long[string][] structs;
    AssocArray[] assocArrays;
    long[string] staticArrays;
    long[string] staticAssocArrays;
    ArrayAlias[] arrayAliases;
}

struct AssocArray {
    // Keep keys and values in parallel arrays so key scans touch a compact
    // contiguous range; a KeyValue[] would interleave values into that walk.
    long[] keys;
    long[] values;
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
    long key;
    bool isAssociative;
    bool isSlice;
}

private ExecutionResult executeInstructions(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint numTemporaries,
    in uint numParameters = 0,
    in long[] arguments = [],
    ref ExecutionContext context,
) @safe pure {
    long[] temporaries = new long[numTemporaries];
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

    // Internal backend failures need IR execution context for debugging; user
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

private void reserveNullStructHandle(ref long[string][] structs) @safe pure {
    if (structs.length == 0)
        structs ~= (long[string]).init;
}

private void reserveNullArrayHandle(ref long[][] arrays) @safe pure {
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
    ref long[] temporaries,
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
            executeAssertInstruction(temporaries, instruction),
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
    ref long[] temporaries,
    in imported!"quickbite.ir.instruction".ConstInt instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        instruction.value;
    return nextInstruction;
}

private InstructionEffect executeCallInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
    in imported!"quickbite.ir.instruction".Select instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        readTemporaryValue(
            temporaries,
            instruction.condition,
        )
            ? readTemporaryValue(temporaries, instruction.ifTrue)
            : readTemporaryValue(temporaries, instruction.ifFalse);
    return nextInstruction;
}

private InstructionEffect executeJumpIfFalseInstruction(
    in long[] temporaries,
    in imported!"quickbite.ir.instruction".JumpIfFalse instruction,
) @safe pure {
    if (!readTemporaryValue(temporaries, instruction.condition))
        return jump(instruction.offset + 1);

    return nextInstruction;
}

private InstructionEffect executeJumpIfTrueInstruction(
    in long[] temporaries,
    in imported!"quickbite.ir.instruction".JumpIfTrue instruction,
) @safe pure {
    if (readTemporaryValue(temporaries, instruction.condition))
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
    in imported!"quickbite.ir.instruction".Copy instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        readTemporaryValue(temporaries, instruction.source);
    return nextInstruction;
}

private InstructionEffect executeCastIntInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
    in imported!"quickbite.ir.instruction".Assert_ instruction,
) @safe pure {
    return executeAssertInstruction(
        temporaries,
        instruction.condition,
        instruction.message,
    );
}

private InstructionEffect executeAssertInstruction(
    in long[] temporaries,
    in uint condition,
    in string message,
) @safe pure {
    if (readTemporaryValue(temporaries, condition))
        return nextInstruction;

    if (const exceptionMessage = thrownExceptionMessage(message))
        throw new UserThrownException(exceptionMessage);

    throw new UnittestAssertionFailure;
}

private InstructionEffect executeArrayLiteralInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
    in uint destination,
    in uint[] elements,
    ref ExecutionContext context,
) @safe pure {
    long[] values;
    foreach (element; elements)
        values ~= readTemporaryValue(temporaries, element);

    context.arrays ~= values;
    writeTemporaryValue(temporaries, destination) =
        cast(long) (context.arrays.length - 1);
    return nextInstruction;
}

private InstructionEffect executeAssocArrayLiteralInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StaticArraySet instruction,
) @safe pure {
    context.staticArrays[instruction.name] =
        readTemporaryValue(temporaries, instruction.value);
    return nextInstruction;
}

private InstructionEffect executeAssocArraySetInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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

private InstructionEffect executeArrayLengthInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArraySetLength instruction,
) @safe pure {
    context.arrays[arrayIndex(temporaries, instruction.array)].length =
        arrayIndex(temporaries, instruction.length);
    return nextInstruction;
}

private InstructionEffect executeArrayConcatInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
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
        cast(long) index,
        false,
        false,
    );
    writeTemporaryValue(temporaries, destination) = cast(long) pointer;
    return nextInstruction;
}

private InstructionEffect executeArraySetInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    ref long[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".ArrayCanFind instruction,
) @safe pure {
    writeTemporaryValue(temporaries, instruction.destination) =
        arrayCanFind(
            context.arrays[arrayIndex(temporaries, instruction.haystack)],
            context.arrays[arrayIndex(temporaries, instruction.needle)],
        );
    return nextInstruction;
}

private InstructionEffect executeArraySliceInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    auto sourceLower = cast(long) lower; // Rewritten below for nested slices.
    foreach (alias_; context.arrayAliases) {
        if (alias_.array != array || !alias_.isSlice)
            continue;

        sourceArray = alias_.sourceArray;
        sourceLower = alias_.key + cast(long) lower;
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
    ref long[] temporaries,
    ref ExecutionContext context,
    in imported!"quickbite.ir.instruction".StructNew instruction,
) @safe pure {
    context.structs ~= (long[string]).init;
    writeTemporaryValue(temporaries, instruction.destination) =
        cast(long) (context.structs.length - 1);
    return nextInstruction;
}

private InstructionEffect executeStructGetInstruction(
    ref long[] temporaries,
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
    ref long[] temporaries,
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
    long value;
    if (auto stored = fieldName in context.structs[index])
        value = *stored;

    writeTemporaryValue(temporaries, destination) = value;
    return nextInstruction;
}

private InstructionEffect executeStructSetInstruction(
    ref long[] temporaries,
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

private long castInteger(
    in long value,
    in imported!"quickbite.ir.instruction".IntegerType target,
) @safe pure nothrow @nogc {
    import quickbite.ir.instruction: IntegerType;

    with (IntegerType)
    final switch (target) {
        case i8:
            return cast(byte) value;
        case u8:
            return cast(ubyte) value;
        case i16:
            return cast(short) value;
        case u16:
            return cast(ushort) value;
        case i32:
            return cast(int) value;
        case u32:
            return cast(uint) value;
        case i64:
            return cast(long) value;
        case u64:
            return cast(ulong) value;
    }
}

private void writeArguments(
    ref long[] temporaries,
    in uint numParameters,
    in long[] arguments,
) @safe pure {
    if (arguments.length != numParameters)
        throw new Exception("Unsupported call.");

    foreach (index, argument; arguments)
        writeTemporaryValue(temporaries, cast(uint) index) = argument;
}

private void writeRefArguments(
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

private long[] argumentValues(in long[] temporaries, in uint[] arguments) @safe pure {
    long[] result;

    foreach (argument; arguments)
        result ~= readTemporaryValue(temporaries, argument);

    return result;
}

private void executeBinaryInstruction(
    ref long[] temporaries,
    in uint destination,
    in uint left,
    in uint right,
    in imported!"quickbite.ir.instruction".Operation operation,
) @safe pure {
    import quickbite.ir.instruction: Operation;

    const leftValue = readTemporaryValue(temporaries, left);
    const rightValue = readTemporaryValue(temporaries, right);
    long result;

    with (Operation)
    final switch (operation) {
        case add:
            result = leftValue + rightValue;
            break;
        case addDouble:
            result = doubleBits(
                doubleFromBits(leftValue) + doubleFromBits(rightValue),
            );
            break;
        case powDouble:
            import std.math: pow;

            result = doubleBits(
                pow(doubleFromBits(leftValue), doubleFromBits(rightValue)),
            );
            break;
        case subtract:
            result = leftValue - rightValue;
            break;
        case multiply:
            result = leftValue * rightValue;
            break;
        case divide:
            enforceNonZeroDivisor(rightValue);
            result = leftValue / rightValue;
            break;
        case modulo:
            enforceNonZeroDivisor(rightValue);
            result = leftValue % rightValue;
            break;
        case leftShift:
            result = leftValue << rightValue;
            break;
        case rightShift:
            result = leftValue >> rightValue;
            break;
        case bitwiseAnd:
            result = leftValue & rightValue;
            break;
        case bitwiseOr:
            result = leftValue | rightValue;
            break;
        case bitwiseXor:
            result = leftValue ^ rightValue;
            break;
        case equal:
            result = leftValue == rightValue;
            break;
        case notEqual:
            result = leftValue != rightValue;
            break;
        case lessThan:
            result = leftValue < rightValue;
            break;
        case unsignedLessThan:
            result = cast(ulong) leftValue < cast(ulong) rightValue;
            break;
        case lessOrEqual:
            result = leftValue <= rightValue;
            break;
        case unsignedLessOrEqual:
            result = cast(ulong) leftValue <= cast(ulong) rightValue;
            break;
        case greaterThan:
            result = leftValue > rightValue;
            break;
        case greaterOrEqual:
            result = leftValue >= rightValue;
            break;
        case unsignedGreaterOrEqual:
            result = cast(ulong) leftValue >= cast(ulong) rightValue;
            break;
        case unsignedGreaterThan:
            result = cast(ulong) leftValue > cast(ulong) rightValue;
            break;
    }

    writeTemporaryValue(temporaries, destination) = result;
}

private bool arrayCanFind(in long[] haystack, in long[] needle) @safe pure {
    import std.algorithm.searching: canFind;

    return haystack.canFind(needle);
}

private long[] copyArrayValue(in long[][] arrays, in size_t handle) @safe pure {
    if (handle < arrays.length)
        return arrays[handle].dup;

    if (handle == 0)
        return [];

    throw arrayHandleException(arrays, handle);
}

private long[] referenceArrayValue(ref long[][] arrays, in size_t handle) @safe pure {
    if (handle < arrays.length)
        return arrays[handle];

    if (handle == 0)
        return [];

    throw arrayHandleException(arrays, handle);
}

private void executeUnaryInstruction(
    ref long[] temporaries,
    in uint destination,
    in uint source,
    in imported!"quickbite.ir.instruction".UnaryOperation operation,
) @safe pure {
    import quickbite.ir.instruction: UnaryOperation;

    const sourceValue = readTemporaryValue(temporaries, source);
    long result;

    with (UnaryOperation)
    final switch (operation) {
        case negate:
            result = -sourceValue;
            break;
        case not:
            result = !sourceValue;
            break;
        case complement:
            result = ~sourceValue;
            break;
        case bitScanReverse:
            result = bitScanReverseValue(sourceValue);
            break;
        case fabsDouble:
            import std.math: fabs;

            result = doubleBits(fabs(doubleFromBits(sourceValue)));
            break;
        case isInfinityDouble:
            import std.math: isInfinity;

            result = isInfinity(doubleFromBits(sourceValue)) ? 1 : 0;
            break;
        case isNaNDouble:
            import std.math: isNaN;

            result = isNaN(doubleFromBits(sourceValue)) ? 1 : 0;
            break;
        case signbitDouble:
            result = (cast(ulong) sourceValue & (1UL << 63)) != 0;
            break;
        case sqrtDouble:
            import std.math: sqrt;

            result = doubleBits(sqrt(doubleFromBits(sourceValue)));
            break;
    }

    writeTemporaryValue(temporaries, destination) = result;
}

private long doubleBits(in double value) @trusted pure nothrow {
    return cast(long) *cast(ulong*) &value;
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

private long readTemporaryValue(in long[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

private ref long writeTemporaryValue(ref long[] temporaries, in uint index) @safe pure {
    enforceTemporaryIndex(temporaries.length, index);
    return temporaries[index];
}

private size_t arrayIndex(in long[] temporaries, in uint temporary) @safe pure {
    const value = readTemporaryValue(temporaries, temporary);
    if (value < 0)
        throw new Exception("IR: array index out of range");

    return cast(size_t) value;
}

private bool arraysEqual(
    in long[][] arrays,
    in size_t left,
    in size_t right,
    in uint depth,
) @safe pure {
    import std.algorithm.comparison: equal;

    enforceArrayHandle(arrays, left);
    enforceArrayHandle(arrays, right);
    if (depth <= 1)
        return equal(arrays[left], arrays[right]);

    return equal!((leftValue, rightValue) => arraysEqual(
            arrays,
            arrayHandle(leftValue),
            arrayHandle(rightValue),
            depth - 1,
        ))(arrays[left], arrays[right]);
}

private void enforceArrayHandle(
    in long[][] arrays,
    in size_t handle,
) @safe pure {
    if (handle >= arrays.length)
        throw arrayHandleException(arrays, handle);
}

private Exception arrayHandleException(
    in long[][] arrays,
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

private size_t arrayHandle(in long value) @safe pure {
    // Array references are stored in IR temporaries as signed integer indexes.
    // Convert only after rejecting negative values so callers can index the
    // array table with size_t.
    if (value < 0)
        throw new Exception("IR: array handle out of range");

    return cast(size_t) value;
}

private size_t assocArrayIndex(in long[] temporaries, in uint temporary) @safe pure {
    const value = readTemporaryValue(temporaries, temporary);
    if (value < 0)
        throw new Exception("IR: associative array index out of range");

    return cast(size_t) value;
}

private long assocArrayValue(in AssocArray array, in long key) @safe pure {
    foreach (index, existingKey; array.keys)
        if (existingKey == key)
            return array.values[index];

    return 0;
}

private void writeAssocArrayValue(
    ref AssocArray array,
    in long key,
    in long value,
) @safe pure {
    foreach (index, existingKey; array.keys) {
        if (existingKey != key)
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
    in long[] values,
) @safe pure {
    foreach (value; values)
        appendArrayValue(context, array, value);
}

private void appendArrayValue(
    ref ExecutionContext context,
    in size_t array,
    in long value,
) @safe pure {
    const index = context.arrays[array].length;
    context.arrays[array] ~= value;
    updateSliceArrayAlias(context, array, index, value);
}

private void updateSliceArrayAlias(
    ref ExecutionContext context,
    in size_t array,
    in size_t index,
    in long value,
) @safe pure {
    foreach (alias_; context.arrayAliases) {
        if (alias_.array != array || !alias_.isSlice)
            continue;

        const sourceIndex = cast(size_t) (alias_.key + cast(long) index);
        writeArrayValue(context.arrays, alias_.sourceArray, sourceIndex, value);
        return;
    }
}

private void writeArrayValue(
    ref long[][] arrays,
    in size_t array,
    in size_t index,
    in long value,
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
    in long[] temporaries,
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
                cast(size_t) (alias_.key + cast(long) index),
                value,
            );
        } else if (alias_.isAssociative && index == 0) {
            writeAssocArrayValue(
                context.assocArrays[alias_.assocArray],
                alias_.key,
                value,
            );
        } else if (index == 0) {
            context.arrays[alias_.sourceArray][cast(size_t) alias_.key] = value;
        }
        return;
    }
}

private size_t structIndex(in long[] temporaries, in uint temporary) @safe pure {
    const value = readTemporaryValue(temporaries, temporary);
    if (value < 0)
        throw new Exception("IR: struct index out of range");

    return cast(size_t) value;
}

private void enforceTemporaryIndex(in ulong length, in uint index) @safe pure {
    if (index >= length)
        throw new Exception("IR: temporary index out of range");
}

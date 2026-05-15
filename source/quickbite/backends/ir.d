module quickbite.backends.ir;

private:

private enum unittestAssertionFailureMessage = "Unittest assertion failed.";

public final class IrExecutor : imported!"quickbite.executor".Executor {
    public void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        auto parsed = parseModule(source);
        runParsedTests(parsed.module_);
    }

    public void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        auto parsed = parseModule(source, importPaths);
        runParsedTests(parsed.module_);
    }

    public void runParsedTests(imported!"dmd.dmodule".Module module_) {
        import quickbite.frontend.compiler: lowerModule;

        const loweredModule = lowerModule(module_);
        executeUnitTests(loweredModule);
    }

    public imported!"quickbite.executor".TestSummary runTestSummary(
        in string source,
    ) {
        import quickbite.frontend.compiler: lowerModule, parseModule;

        // Keep `parsed` mutable: the DMD frontend owns mutable Module state.
        auto parsed = parseModule(source);
        const loweredModule = lowerModule(parsed.module_);
        return testSummary(loweredModule);
    }
}

void executeUnitTests(in imported!"quickbite.ir.module_".Module module_) @safe pure {
    foreach (index, test; module_.tests) {
        try {
            executeUnitTest(module_, test);
        } catch (Exception exception) {
            if (isUnittestAssertionFailure(exception))
                throw exception;

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

private bool isUnittestAssertionFailure(in Exception exception) @safe pure nothrow {
    return exception.msg == unittestAssertionFailureMessage;
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
    long[][] arrays;
    long[string][] structs;
    AssocArray[] assocArrays;
    long[string] staticArrays;
    long[string] staticAssocArrays;
    ArrayAlias[] arrayAliases;
    executeInstructions(
        module_,
        test.instructions,
        test.numTemporaries,
        0,
        [],
        arrays,
        structs,
        assocArrays,
        staticArrays,
        staticAssocArrays,
        arrayAliases,
    );
}

long executeFunction(
    in imported!"quickbite.ir.module_".Module module_,
    in string calleeName,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
    ref long[][] arrays,
    ref long[string][] structs,
    ref AssocArray[] assocArrays,
    ref long[string] staticArrays,
    ref long[string] staticAssocArrays,
    ref ArrayAlias[] arrayAliases,
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
                    arrays,
                    structs,
                    assocArrays,
                    staticArrays,
                    staticAssocArrays,
                    arrayAliases,
                );
            } catch (Exception exception) {
                if (isUnittestAssertionFailure(exception))
                    throw exception;

                import std.conv: text;

                throw new Exception(text(
                    "function ",
                    calleeName,
                    " failed: ",
                    exception.msg,
                ));
            }
        }
    }

    throw new Exception("Unsupported callee.");
}

long executeFunctionPointer(
    in imported!"quickbite.ir.module_".Module module_,
    in long callee,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
    ref long[][] arrays,
    ref long[string][] structs,
    ref AssocArray[] assocArrays,
    ref long[string] staticArrays,
    ref long[string] staticAssocArrays,
    ref ArrayAlias[] arrayAliases,
) @safe pure {
    // Current lowered modules are tiny; add an index when benchmarks show this.
    foreach (function_; module_.functions) {
        if (functionPointerValue(function_.name) == callee)
            return executeFunctionBody(
                module_,
                function_.instructions,
                function_.hasReturnValue,
                function_.numParameters,
                function_.refParameters,
                function_.numTemporaries,
                callerTemporaries,
                argumentIndices,
                arrays,
                structs,
                assocArrays,
                staticArrays,
                staticAssocArrays,
                arrayAliases,
            );
    }

    throw new Exception("Unsupported function pointer callee.");
}

long executeFunctionBody(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in bool hasReturnValue,
    in uint numParameters,
    in bool[] refParameters,
    in uint numTemporaries,
    ref long[] callerTemporaries,
    in uint[] argumentIndices,
    ref long[][] arrays,
    ref long[string][] structs,
    ref AssocArray[] assocArrays,
    ref long[string] staticArrays,
    ref long[string] staticAssocArrays,
    ref ArrayAlias[] arrayAliases,
) @safe pure {
    const arguments = argumentValues(callerTemporaries, argumentIndices);
    ExecutionResult result = executeInstructions(
        module_,
        instructions,
        numTemporaries,
        numParameters,
        arguments,
        arrays,
        structs,
        assocArrays,
        staticArrays,
        staticAssocArrays,
        arrayAliases,
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

struct AssocArray {
    long[] keys;
    long[] values;
}

struct ArrayAlias {
    size_t array;
    size_t sourceArray;
    size_t assocArray;
    long key;
    bool isAssociative;
    bool isSlice;
}

ExecutionResult executeInstructions(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint numTemporaries,
    in uint numParameters = 0,
    in long[] arguments = [],
    ref long[][] arrays,
    ref long[string][] structs,
    ref AssocArray[] assocArrays,
    ref long[string] staticArrays,
    ref long[string] staticAssocArrays,
    ref ArrayAlias[] arrayAliases,
) @safe pure {
    long[] temporaries = new long[numTemporaries];
    writeArguments(temporaries, numParameters, arguments);
    reserveNullArrayHandle(arrays);
    reserveNullStructHandle(structs);

    ExecutionResult result;
    result.temporaries = temporaries;

    uint instructionPointer;
    while (instructionPointer < instructions.length) {
        InstructionEffect effect;
        try {
            effect = executeInstruction(
                module_,
                instructions[instructionPointer],
                temporaries,
                arrays,
                structs,
                assocArrays,
                staticArrays,
                staticAssocArrays,
                arrayAliases,
            );
        } catch (Exception exception) {
            if (isUnittestAssertionFailure(exception))
                throw exception;

            import std.conv: text;

            throw new Exception(text(
                "instruction ",
                instructionPointer,
                " failed: ",
                exception.msg,
            ));
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

void reserveNullStructHandle(ref long[string][] structs) @safe pure {
    if (structs.length == 0)
        structs ~= (long[string]).init;
}

void reserveNullArrayHandle(ref long[][] arrays) @safe pure {
    if (arrays.length == 0)
        arrays ~= [];
}

struct InstructionEffect {
    // signed so backward Jumps (loops) can produce a negative delta.
    int offset;
    bool hasReturn;
    uint returnValue;
}

InstructionEffect executeInstruction(
    in imported!"quickbite.ir.module_".Module module_,
    in imported!"quickbite.ir.instruction".Instruction instruction,
    ref long[] temporaries,
    ref long[][] arrays,
    ref long[string][] structs,
    ref AssocArray[] assocArrays,
    ref long[string] staticArrays,
    ref long[string] staticAssocArrays,
    ref ArrayAlias[] arrayAliases,
) @safe pure {
    import quickbite.ir.instruction: ArrayAppend, ArrayAppendArray, ArrayConcat,
        ArrayCanFind, ArrayCopy, ArrayElementPointer, ArrayEqual, ArrayIndex,
        ArrayLength, ArrayLiteral, ArrayReferenceCopy, ArraySet, ArraySetLength,
        ArraySlice, AssocArrayIndex, AssocArrayKeys, AssocArrayLength,
        AssocArrayLiteral, AssocArraySet, AssocArrayValuePointer, AssocArrayValues,
        Assert_,
        BinaryOp, Call, CastInt, ConstInt, Copy, IndirectCall, Jump,
        JumpIfFalse, JumpIfTrue, ReturnValue, ReturnVoid, Select, StaticAssocArray,
        StaticArray, StaticArraySet, StructGet,
        StructNew, StructSet, UnaryOp;
    import std.sumtype: match;

    return instruction.match!(
        (ConstInt instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                instruction.value;
            return nextInstruction;
        },
        (const Call instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                executeFunction(
                    module_,
                    instruction.calleeName,
                    temporaries,
                    instruction.arguments,
                    arrays,
                    structs,
                    assocArrays,
                    staticArrays,
                    staticAssocArrays,
                    arrayAliases,
                );
            return nextInstruction;
        },
        (const IndirectCall instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                executeFunctionPointer(
                    module_,
                    readTemporaryValue(temporaries, instruction.callee),
                    temporaries,
                    instruction.arguments,
                    arrays,
                    structs,
                    assocArrays,
                    staticArrays,
                    staticAssocArrays,
                    arrayAliases,
                );
            return nextInstruction;
        },
        (BinaryOp instruction) {
            executeBinaryInstruction(
                temporaries,
                instruction.destination,
                instruction.left,
                instruction.right,
                instruction.operation,
            );
            return nextInstruction;
        },
        (UnaryOp instruction) {
            executeUnaryInstruction(
                temporaries,
                instruction.destination,
                instruction.source,
                instruction.operation,
            );
            return nextInstruction;
        },
        (Select instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                readTemporaryValue(
                    temporaries,
                    instruction.condition,
                )
                    ? readTemporaryValue(temporaries, instruction.ifTrue)
                    : readTemporaryValue(temporaries, instruction.ifFalse);
            return nextInstruction;
        },
        (JumpIfFalse instruction) {
            if (!readTemporaryValue(temporaries, instruction.condition))
                return jump(instruction.offset + 1);

            return nextInstruction;
        },
        (JumpIfTrue instruction) {
            if (readTemporaryValue(temporaries, instruction.condition))
                return jump(instruction.offset + 1);

            return nextInstruction;
        },
        (Jump instruction) {
            return jump(instruction.offset);
        },
        (Copy instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                readTemporaryValue(temporaries, instruction.source);
            return nextInstruction;
        },
        (CastInt instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                castInteger(
                    readTemporaryValue(temporaries, instruction.source),
                    instruction.target,
                );
            return nextInstruction;
        },
        (Assert_ instruction) {
            if (!readTemporaryValue(temporaries, instruction.condition)) {
                throw new Exception(unittestAssertionFailureMessage);
            }

            return nextInstruction;
        },
        (const ArrayLiteral instruction) {
            long[] values;
            foreach (element; instruction.elements)
                values ~= readTemporaryValue(temporaries, element);

            arrays ~= values;
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (arrays.length - 1);
            return nextInstruction;
        },
        (const AssocArrayLiteral instruction) {
            AssocArray values;
            foreach (key; instruction.keys)
                values.keys ~= readTemporaryValue(temporaries, key);
            foreach (value; instruction.values)
                values.values ~= readTemporaryValue(temporaries, value);

            assocArrays ~= values;
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (assocArrays.length - 1);
            return nextInstruction;
        },
        (AssocArrayLength instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) assocArrays[
                    assocArrayIndex(temporaries, instruction.array)
                ].keys.length;
            return nextInstruction;
        },
        (AssocArrayKeys instruction) {
            arrays ~= assocArrays[
                assocArrayIndex(temporaries, instruction.array)
            ].keys;
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (arrays.length - 1);
            return nextInstruction;
        },
        (AssocArrayValues instruction) {
            arrays ~= assocArrays[
                assocArrayIndex(temporaries, instruction.array)
            ].values;
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (arrays.length - 1);
            return nextInstruction;
        },
        (AssocArrayIndex instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                assocArrayValue(
                    assocArrays[assocArrayIndex(temporaries, instruction.array)],
                    readTemporaryValue(temporaries, instruction.key),
                );
            return nextInstruction;
        },
        (AssocArrayValuePointer instruction) {
            const array = assocArrayIndex(temporaries, instruction.array);
            const key = readTemporaryValue(temporaries, instruction.key);
            arrays ~= [
                assocArrayValue(
                    assocArrays[array],
                    key,
                ),
            ];
            const pointer = arrays.length - 1;
            arrayAliases ~= ArrayAlias(pointer, 0, array, key, true, false);
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) pointer;
            return nextInstruction;
        },
        (const StaticAssocArray instruction) {
            if (auto array = instruction.name in staticAssocArrays) {
                writeTemporaryValue(temporaries, instruction.destination) =
                    *array;
                return nextInstruction;
            }

            assocArrays ~= AssocArray.init;
            const array = cast(long) (assocArrays.length - 1);
            staticAssocArrays[instruction.name] = array;
            writeTemporaryValue(temporaries, instruction.destination) = array;
            return nextInstruction;
        },
        (const StaticArray instruction) {
            if (auto array = instruction.name in staticArrays) {
                writeTemporaryValue(temporaries, instruction.destination) =
                    *array;
                return nextInstruction;
            }

            arrays ~= [];
            const array = cast(long) (arrays.length - 1);
            staticArrays[instruction.name] = array;
            writeTemporaryValue(temporaries, instruction.destination) = array;
            return nextInstruction;
        },
        (const StaticArraySet instruction) {
            staticArrays[instruction.name] =
                readTemporaryValue(temporaries, instruction.value);
            return nextInstruction;
        },
        (AssocArraySet instruction) {
            writeAssocArrayValue(
                assocArrays[assocArrayIndex(temporaries, instruction.array)],
                readTemporaryValue(temporaries, instruction.key),
                readTemporaryValue(temporaries, instruction.value),
            );
            return nextInstruction;
        },
        (ArrayCopy instruction) {
            arrays ~= copyArrayValue(
                arrays,
                arrayIndex(temporaries, instruction.source),
            );
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (arrays.length - 1);
            return nextInstruction;
        },
        (ArrayReferenceCopy instruction) {
            arrays ~= referenceArrayValue(
                arrays,
                arrayIndex(temporaries, instruction.source),
            );
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (arrays.length - 1);
            return nextInstruction;
        },
        (ArrayAppend instruction) {
            appendArrayValue(
                arrays,
                arrayIndex(temporaries, instruction.array),
                readTemporaryValue(temporaries, instruction.value),
                arrayAliases,
            );
            return nextInstruction;
        },
        (ArrayAppendArray instruction) {
            appendArrayValues(
                arrays,
                arrayIndex(temporaries, instruction.array),
                arrays[arrayIndex(temporaries, instruction.value)],
                arrayAliases,
            );
            return nextInstruction;
        },
        (ArrayLength instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) arrays[arrayIndex(temporaries, instruction.array)].length;
            return nextInstruction;
        },
        (ArraySetLength instruction) {
            arrays[arrayIndex(temporaries, instruction.array)].length =
                arrayIndex(temporaries, instruction.length);
            return nextInstruction;
        },
        (ArrayConcat instruction) {
            arrays ~= arrays[arrayIndex(temporaries, instruction.left)] ~
                arrays[arrayIndex(temporaries, instruction.right)];
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (arrays.length - 1);
            return nextInstruction;
        },
        (ArrayIndex instruction) {
            const array = arrayIndex(temporaries, instruction.array);
            const index = arrayIndex(temporaries, instruction.index);
            if (array >= arrays.length) {
                if (index == 0) {
                    writeTemporaryValue(temporaries, instruction.destination) =
                        readTemporaryValue(temporaries, instruction.array);
                    return nextInstruction;
                }

                import std.conv: text;

                throw new Exception(text(
                    "IR: array handle ",
                    array,
                    " out of range, arrays = ",
                    arrays,
                    ", temporaries = ",
                    temporaries,
                ));
            }
            if (index >= arrays[array].length) {
                import std.conv: text;

                throw new Exception(text(
                    "IR: array index ",
                    index,
                    " out of range for array ",
                    array,
                    " length ",
                    arrays[array].length,
                    ", arrays = ",
                    arrays,
                    ", temporaries = ",
                    temporaries,
                ));
            }
            writeTemporaryValue(temporaries, instruction.destination) =
                arrays[array][index];
            return nextInstruction;
        },
        (ArrayElementPointer instruction) {
            const array = arrayIndex(temporaries, instruction.array);
            const index = arrayIndex(temporaries, instruction.index);
            arrays ~= [arrays[array][index]];
            const pointer = arrays.length - 1;
            arrayAliases ~= ArrayAlias(
                pointer,
                array,
                0,
                cast(long) index,
                false,
                false,
            );
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) pointer;
            return nextInstruction;
        },
        (ArraySet instruction) {
            arrays[arrayIndex(temporaries, instruction.array)][
                arrayIndex(temporaries, instruction.index)
            ] = readTemporaryValue(temporaries, instruction.value);
            updateArrayAlias(
                temporaries,
                instruction,
                arrayAliases,
                arrays,
                assocArrays,
            );
            return nextInstruction;
        },
        (ArrayEqual instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                arraysEqual(
                    arrays,
                    arrayIndex(temporaries, instruction.left),
                    arrayIndex(temporaries, instruction.right),
                    instruction.depth,
                );
            return nextInstruction;
        },
        (ArrayCanFind instruction) {
            writeTemporaryValue(temporaries, instruction.destination) =
                arrayCanFind(
                    arrays[arrayIndex(temporaries, instruction.haystack)],
                    arrays[arrayIndex(temporaries, instruction.needle)],
                );
            return nextInstruction;
        },
        (ArraySlice instruction) {
            const array = arrayIndex(temporaries, instruction.array);
            const lower = arrayIndex(temporaries, instruction.lower);
            const upper = arrayIndex(temporaries, instruction.upper);
            arrays ~= arrays[array][lower .. upper];
            const slice = arrays.length - 1;
            arrayAliases ~= ArrayAlias(
                slice,
                array,
                0,
                cast(long) lower,
                false,
                true,
            );
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) slice;
            return nextInstruction;
        },
        (StructNew instruction) {
            structs ~= (long[string]).init;
            writeTemporaryValue(temporaries, instruction.destination) =
                cast(long) (structs.length - 1);
            return nextInstruction;
        },
        (const StructGet instruction) {
            const index = structIndex(temporaries, instruction.struct_);
            if (instruction.fieldName == "length" && index < arrays.length) {
                if (index >= structs.length || "length" !in structs[index]) {
                    writeTemporaryValue(temporaries, instruction.destination) =
                        cast(long) arrays[index].length;
                    return nextInstruction;
                }
            }
            if (index >= structs.length) {
                import std.conv: text;

                throw new Exception(text(
                    "IR: struct handle ",
                    index,
                    " out of range, structs = ",
                    structs,
                    ", temporaries = ",
                    temporaries,
                ));
            }
            long value;
            if (auto stored = instruction.fieldName in structs[index])
                value = *stored;

            writeTemporaryValue(temporaries, instruction.destination) = value;
            return nextInstruction;
        },
        (const StructSet instruction) {
            structs[structIndex(temporaries, instruction.struct_)][
                instruction.fieldName
            ] = readTemporaryValue(temporaries, instruction.value);
            return nextInstruction;
        },
        (ReturnValue instruction) {
            return returnFromFunction(instruction.value);
        },
        (ReturnVoid instruction) {
            return returnFromVoid;
        },
    );
}

InstructionEffect nextInstruction() @safe pure nothrow @nogc {
    return InstructionEffect(1);
}

InstructionEffect jump(in int offset) @safe pure nothrow @nogc {
    return InstructionEffect(offset);
}

InstructionEffect returnFromFunction(in uint value) @safe pure nothrow @nogc {
    return InstructionEffect(0, true, value);
}

InstructionEffect returnFromVoid() @safe pure nothrow @nogc {
    return InstructionEffect(0, true);
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
        case imported!"quickbite.ir.instruction".IntegerType.i16:
            return cast(short) value;
        case imported!"quickbite.ir.instruction".IntegerType.u16:
            return cast(ushort) value;
        case imported!"quickbite.ir.instruction".IntegerType.i32:
            return cast(int) value;
        case imported!"quickbite.ir.instruction".IntegerType.u32:
            return cast(uint) value;
        case imported!"quickbite.ir.instruction".IntegerType.i64:
            return cast(long) value;
        case imported!"quickbite.ir.instruction".IntegerType.u64:
            return cast(ulong) value;
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

long[] argumentValues(in long[] temporaries, in uint[] arguments) @safe pure {
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
            enforceNonZeroDivisor(rightValue, "Unittest assertion failed.");
            result = leftValue / rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.modulo:
            enforceNonZeroDivisor(rightValue, "Unittest assertion failed.");
            result = leftValue % rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.leftShift:
            result = leftValue << rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.rightShift:
            result = leftValue >> rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.bitwiseAnd:
            result = leftValue & rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.bitwiseOr:
            result = leftValue | rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.bitwiseXor:
            result = leftValue ^ rightValue;
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
        case imported!"quickbite.ir.instruction".Operation.unsignedLessThan:
            result = cast(ulong) leftValue < cast(ulong) rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.lessOrEqual:
            result = leftValue <= rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.unsignedLessOrEqual:
            result = cast(ulong) leftValue <= cast(ulong) rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.greaterThan:
            result = leftValue > rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.greaterOrEqual:
            result = leftValue >= rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.unsignedGreaterOrEqual:
            result = cast(ulong) leftValue >= cast(ulong) rightValue;
            break;
        case imported!"quickbite.ir.instruction".Operation.unsignedGreaterThan:
            result = cast(ulong) leftValue > cast(ulong) rightValue;
            break;
    }

    writeTemporaryValue(temporaries, destination) = result;
}

bool arrayCanFind(in long[] haystack, in long[] needle) @safe pure {
    if (needle.length == 0)
        return true;

    if (needle.length > haystack.length)
        return false;

    foreach (start; 0 .. haystack.length - needle.length + 1)
        if (haystack[start .. start + needle.length] == needle)
            return true;

    return false;
}

long[] copyArrayValue(in long[][] arrays, in size_t handle) @safe pure {
    if (handle < arrays.length)
        return arrays[handle].dup;

    if (handle == 0)
        return [];

    throw new Exception("IR: array handle out of range");
}

long[] referenceArrayValue(ref long[][] arrays, in size_t handle) @safe pure {
    if (handle < arrays.length)
        return arrays[handle];

    if (handle == 0)
        return [];

    throw new Exception("IR: array handle out of range");
}

void executeUnaryInstruction(
    ref long[] temporaries,
    in uint destination,
    in uint source,
    in imported!"quickbite.ir.instruction".UnaryOperation operation,
) @safe pure {
    const sourceValue = readTemporaryValue(temporaries, source);

    final switch (operation) {
        case imported!"quickbite.ir.instruction".UnaryOperation.negate:
            writeTemporaryValue(temporaries, destination) = -sourceValue;
            break;
        case imported!"quickbite.ir.instruction".UnaryOperation.not:
            writeTemporaryValue(temporaries, destination) = !sourceValue;
            break;
        case imported!"quickbite.ir.instruction".UnaryOperation.complement:
            writeTemporaryValue(temporaries, destination) = ~sourceValue;
            break;
        case imported!"quickbite.ir.instruction".UnaryOperation.bitScanReverse:
            writeTemporaryValue(temporaries, destination) =
                bitScanReverse(sourceValue);
            break;
    }
}

long bitScanReverse(in long sourceValue) @safe pure nothrow @nogc {
    const bits = cast(ulong) sourceValue;
    foreach_reverse (index; 0 .. 64) {
        const mask = 1UL << index;
        if ((bits & mask) != 0)
            return cast(long) index;
    }

    return -1;
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

size_t arrayIndex(in long[] temporaries, in uint temporary) @safe pure {
    const value = readTemporaryValue(temporaries, temporary);
    if (value < 0)
        throw new Exception("IR: array index out of range");

    return cast(size_t) value;
}

bool arraysEqual(
    in long[][] arrays,
    in size_t left,
    in size_t right,
    in uint depth,
) @safe pure {
    enforceArrayHandle(arrays, left);
    enforceArrayHandle(arrays, right);
    if (depth <= 1)
        return arrays[left] == arrays[right];

    if (arrays[left].length != arrays[right].length)
        return false;

    foreach (index; 0 .. arrays[left].length) {
        if (!arraysEqual(
            arrays,
            arrayHandle(arrays[left][index]),
            arrayHandle(arrays[right][index]),
            depth - 1,
        ))
            return false;
    }

    return true;
}

private void enforceArrayHandle(
    in long[][] arrays,
    in size_t handle,
) @safe pure {
    if (handle >= arrays.length)
        throw new Exception("IR: array handle out of range");
}

private size_t arrayHandle(in long value) @safe pure {
    if (value < 0)
        throw new Exception("IR: array handle out of range");

    return cast(size_t) value;
}

size_t assocArrayIndex(in long[] temporaries, in uint temporary) @safe pure {
    const value = readTemporaryValue(temporaries, temporary);
    if (value < 0)
        throw new Exception("IR: associative array index out of range");

    return cast(size_t) value;
}

long assocArrayValue(in AssocArray array, in long key) @safe pure {
    foreach (index, existingKey; array.keys)
        if (existingKey == key)
            return array.values[index];

    return 0;
}

void writeAssocArrayValue(
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

long functionPointerValue(in string name) @safe pure nothrow @nogc {
    long result = 17;
    foreach (immutable char character; name)
        result = result * 31 + cast(long) character;

    return result == 0 ? 1 : result;
}

void appendArrayValues(
    ref long[][] arrays,
    in size_t array,
    in long[] values,
    in ArrayAlias[] arrayAliases,
) @safe pure {
    foreach (value; values)
        appendArrayValue(arrays, array, value, arrayAliases);
}

void appendArrayValue(
    ref long[][] arrays,
    in size_t array,
    in long value,
    in ArrayAlias[] arrayAliases,
) @safe pure {
    const index = arrays[array].length;
    arrays[array] ~= value;
    updateSliceArrayAlias(arrays, array, index, value, arrayAliases);
}

void updateSliceArrayAlias(
    ref long[][] arrays,
    in size_t array,
    in size_t index,
    in long value,
    in ArrayAlias[] arrayAliases,
) @safe pure {
    foreach (alias_; arrayAliases) {
        if (alias_.array != array || !alias_.isSlice)
            continue;

        const sourceIndex = cast(size_t) (alias_.key + cast(long) index);
        writeArrayValue(arrays, alias_.sourceArray, sourceIndex, value);
        return;
    }
}

void writeArrayValue(
    ref long[][] arrays,
    in size_t array,
    in size_t index,
    in long value,
) @safe pure {
    if (index < arrays[array].length) {
        arrays[array][index] = value;
        return;
    }

    if (index != arrays[array].length)
        throw new Exception("IR: array index out of range");

    arrays[array] ~= value;
}

void updateArrayAlias(
    in long[] temporaries,
    in imported!"quickbite.ir.instruction".ArraySet instruction,
    in ArrayAlias[] arrayAliases,
    ref long[][] arrays,
    ref AssocArray[] assocArrays,
) @safe pure {
    const array = arrayIndex(temporaries, instruction.array);
    const index = arrayIndex(temporaries, instruction.index);
    foreach (alias_; arrayAliases) {
        if (alias_.array != array)
            continue;

        const value = readTemporaryValue(temporaries, instruction.value);
        if (alias_.isSlice) {
            writeArrayValue(
                arrays,
                alias_.sourceArray,
                cast(size_t) (alias_.key + cast(long) index),
                value,
            );
        } else if (alias_.isAssociative && index == 0) {
            writeAssocArrayValue(
                assocArrays[alias_.assocArray],
                alias_.key,
                value,
            );
        } else if (index == 0) {
            arrays[alias_.sourceArray][cast(size_t) alias_.key] = value;
        }
        return;
    }
}

size_t structIndex(in long[] temporaries, in uint temporary) @safe pure {
    const value = readTemporaryValue(temporaries, temporary);
    if (value < 0)
        throw new Exception("IR: struct index out of range");

    return cast(size_t) value;
}

void enforceTemporaryIndex(in ulong length, in uint index) @safe pure {
    if (index >= length)
        throw new Exception("IR: temporary index out of range");
}

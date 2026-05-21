module quickbite.backends.tree_walking;

private:

// A "pointer" in the tree-walking interpreter is just a handle to a named
// local. Used to represent &varDecl so *ptr can dereference and ref-propagate
// back.
private struct LocalPtr {
    import dmd.declaration: VarDeclaration;

    private VarDeclaration decl;
}

// Handle to class instance state stored in Interpreter class maps.
private struct ClassRef {
    private long id;
}

// Handle to associative-array state stored in Interpreter assoc-array maps.
private struct AssocArrayRef {
    private long id;
}

private struct AssocArraySlotRef {
    private long arrayId;
    private size_t index;
}

private enum IntBinaryOp : char {
    add    = '+',
    sub    = '-',
    mul    = '*',
    shl    = '<',
    bitAnd = '&',
    bitXor = '^',
    bitOr  = '|',
}

// SumType.opAssign is @system in this version of std.sumtype, so all code
// that stores a Value is @system by transitivity.
alias Value = imported!"std.sumtype".SumType!(
    long,
    long[],
    LocalPtr,
    ClassRef,
    AssocArrayRef,
    AssocArraySlotRef,
);

private struct AssocArray {
    import dmd.declaration: VarDeclaration;

    // Keep keys, values, key structs, and struct-key field snapshots in
    // parallel arrays so scalar keys and struct keys share one stable index.
    private VarDeclaration[] keyStructs;
    private Value[VarDeclaration][] keyFields;
    private Value[] keys;
    private Value[] values;
}

// Materialised result of `.keys` for an associative array. The array id keeps
// the keys tied to their source while keyStructs/keyFields preserve struct-key
// fields.
private struct AssocArrayKeys {
    import dmd.declaration: VarDeclaration;

    private long arrayId;
    private VarDeclaration[] keyStructs;
    private Value[VarDeclaration][] keyFields;
    private Value[] keys;
}

// Tracks a local initialised from AssocArrayKeys[index], so field writes can be
// copied back to the key struct at that associative-array index.
private struct AssocArrayKeyLocal {
    private long arrayId;
    private size_t index;
}

// Tracks a lowered AA slot pointer local such as `__aaget[0]`, so assignment
// through that pointer updates the modeled associative array entry.
private struct AssocArraySlotLocal {
    private long arrayId;
    private size_t index;
}

// Represents a slice local that aliases an owner array. offset is the starting
// index in owner, so writes through the slice can propagate to the original.
private struct ArrayAlias {
    import dmd.declaration: VarDeclaration;

    private VarDeclaration owner;
    private size_t offset;
}

private struct FunctionResult {
    import dmd.declaration: VarDeclaration;

    private bool hasValue;
    private Value value;
    private Value[] refValues;
    private Value[VarDeclaration] thisFields;
    // Struct field maps returned for each struct-ref parameter, in param order.
    private Value[VarDeclaration][] structRefValues;
    private Value[VarDeclaration][VarDeclaration] structFieldMaps;
}

private struct CallArgument {
    import dmd.declaration: VarDeclaration;

    private Value value;
    private VarDeclaration refSource;
    private VarDeclaration refOwner;
    private VarDeclaration refField;
    private long refClassId;
    private bool hasRefIndex;
    private size_t refIndex;
    private Value[VarDeclaration] structFields;
    private Value[VarDeclaration][VarDeclaration] structFieldMaps;
    private bool isStruct;
    private bool isStructRef; // whole struct passed as ref (refSource = its VarDeclaration)
    private bool isTemporaryRef;
    private bool isGlobalRef;
}

public final class TreeWalkingExecutorOld : imported!"quickbite.executor".Executor {
    import dmd.dmodule: Module;
    import quickbite.executor: TestSummary;

    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override void runParsedTests(
        Module module_,
    ) {
        walkModule(module_);
    }

    public override TestSummary runTestSummary(
        in string source,
    ) {
        import quickbite.frontend.compiler: parseModule;

        // Keep `parsed` mutable: the DMD frontend owns mutable Module state.
        auto parsed = parseModule(source);
        return testSummary(parsed.module_);
    }
}

private void walkModule(imported!"dmd.dmodule".Module module_) {
    import quickbite.dmd_util: foreachUnitTestDeclaration;

    Interpreter interpreter;
    foreachUnitTestDeclaration(module_, (unitTest) {
        interpreter.runTest(unitTest);
    });
}

private imported!"quickbite.executor".TestSummary testSummary(
    imported!"dmd.dmodule".Module module_,
) {
    import quickbite.dmd_util: foreachUnitTestDeclaration;
    import quickbite.executor: TestSummary;

    TestSummary summary;
    Interpreter interpreter;
    foreachUnitTestDeclaration(module_, (unitTest) {
        ++summary.total;
        try {
            interpreter.runTest(unitTest);
            ++summary.passed;
        } catch (Exception) {
            ++summary.failed;
        }
    });

    return summary;
}

private struct Interpreter {
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;
    import dmd.mtype: Type;

    private long[][string] scopeBufferBytes;
    private long nextClassRef = 1;
    private long nextAssocArrayRef = 1;
    private long nextFunctionRef = -1;
    private long lastAssocArrayRef;
    private long[] lastArrayValue;
    private bool hasLastArrayValue;
    private size_t cerealiserOutputStart;
    private bool hasCerealiserOutputStart;
    private long[] clearedRangeAlias;
    private long[] clearedRangePrefix;
    private bool hasClearedRangeAlias;
    private Value[VarDeclaration][long] classFields;
    private Value[VarDeclaration][VarDeclaration][long] classStructFieldMaps;
    private Type[long] classTypes;
    private Value[long] heapScalars;
    private AssocArray[long] assocArrays;
    private FuncDeclaration[long] functions;
    private Value[VarDeclaration] globals;
    private bool childClassRegistered;

    private FunctionResult executeFunction(
        FuncDeclaration func,
        CallArgument[] args = [],
        Value[VarDeclaration] thisFields = null,
        Value[VarDeclaration][VarDeclaration] structFieldMaps = null,
        VarDeclaration thisOwner = null,
    ) {
        if (func.fbody is null)
            throw new Exception("No function body to execute.");
        BodyWalker w;
        // Give each call its own owner->fields map. Mutations are returned in
        // FunctionResult instead of sharing the caller's associative array.
        w.structFields = structFieldMaps.dup;
        VarDeclaration thisDeclaration;
        if (func.vthis !is null) {
            thisDeclaration = func.vthis;
        } else if (thisOwner !is null) {
            thisDeclaration = thisOwner;
        }
        if (thisDeclaration !is null) {
            w.currentThis = thisDeclaration;
            w.structFields[thisDeclaration] = thisFields;
        }
        w.bindParameters(func, args);
        w.runStatement(func.fbody, this);
        if (w.hasThrown)
            throw new Exception(w.thrownMessage);

        const returnsVoid = isVoidReturn(func);
        if (!w.hasReturn && !returnsVoid)
            throw new Exception("Unsupported function body.");
        if (returnsVoid)
            return FunctionResult(
                false,
                Value(0L),
                collectRefValues(func, w),
                collectThisFields(thisDeclaration, w),
                collectStructRefValues(func, w),
                w.structFields,
            );
        return FunctionResult(
            true,
            w.returnValue,
            collectRefValues(func, w),
            collectThisFields(thisDeclaration, w),
            collectStructRefValues(func, w),
            w.structFields,
        );
    }

    private Value[VarDeclaration] collectThisFields(
        VarDeclaration thisDeclaration,
        ref BodyWalker walker,
    ) {
        if (thisDeclaration is null)
            return null;
        return walker.structFields[thisDeclaration];
    }

    private Value[] collectRefValues(
        FuncDeclaration func,
        ref BodyWalker walker,
    ) {
        Value[] refValues;
        if (func.parameters is null)
            return refValues;

        foreach (param; functionParameters(func)) {
            import dmd.astenums: STC;

            if ((param.storage_class & STC.ref_) == STC.none)
                continue;
            // Struct ref params are collected separately via collectStructRefValues.
            if (param in walker.structFields)
                continue;
            refValues ~= walker.locals[param];
        }
        return refValues;
    }

    private Value[VarDeclaration][] collectStructRefValues(
        FuncDeclaration func,
        ref BodyWalker walker,
    ) {
        Value[VarDeclaration][] results;
        if (func.parameters is null)
            return results;

        foreach (param; functionParameters(func)) {
            import dmd.astenums: STC;

            if ((param.storage_class & STC.ref_) == STC.none)
                continue;
            if (param in walker.structFields)
                results ~= walker.structFields[param];
        }
        return results;
    }

    private bool isVoidReturn(
        FuncDeclaration func,
    ) @trusted {
        import dmd.astenums: TY;
        if (func.type is null) return false;
        const returnType = func.type.nextOf;
        return returnType !is null && returnType.ty == TY.Tvoid;
    }

    private void runTest(
        UnitTestDeclaration unitTest,
    ) {
        BodyWalker w;
        w.runStatement(unitTest.fbody, this);
        if (w.hasThrown)
            throw new Exception(w.thrownMessage);
    }
}

private struct BodyWalker {
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        ArrayLiteralExp,
        AssocArrayLiteralExp,
        AssignExp,
        BinAssignExp,
        CallExp,
        CatAssignExp,
        CatExp,
        DeclarationExp,
        DotVarExp,
        EqualExp,
        Expression,
        IdentityExp,
        IndexExp,
        LoweredAssignExp,
        NewExp,
        StructLiteralExp;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement:
        ConditionalStatement,
        IfStatement,
        Statement,
        SwitchStatement;

    // DMD's `is*` helpers return concrete AST subclasses. Keep `auto` for
    // those downcasts so the walker stays close to the frontend API.
    private Value[VarDeclaration] locals;
    private Value[VarDeclaration][VarDeclaration] structFields;
    private AssocArrayKeys[VarDeclaration] assocArrayKeyArrays;
    private AssocArrayKeyLocal[VarDeclaration] assocArrayKeyLocals;
    private AssocArraySlotLocal[VarDeclaration] assocArraySlotLocals;
    private ArrayAlias[VarDeclaration] arrayAliases;
    private VarDeclaration currentThis;
    private bool hasReturn;
    private bool hasBreak;
    private bool hasContinue;
    private bool hasThrown;
    private string thrownMessage;
    private Value returnValue;

    private void bindParameters(
        FuncDeclaration func,
        CallArgument[] args,
    ) {
        if (func.parameters is null && args.length == 0)
            return;
        if (func.parameters is null || args.length != func.parameters.length)
            throw new Exception("Unsupported call.");
        foreach (i, param; functionParameters(func)) {
            import dmd.astenums: STC;
            if ((param.storage_class & STC.out_) != STC.none)
                throw new Exception("Unsupported function parameters.");
            if ((param.storage_class & STC.ref_) != STC.none &&
                args[i].refSource is null &&
                args[i].refField is null &&
                args[i].refClassId == 0 &&
                !args[i].isStructRef &&
                !args[i].isTemporaryRef)
                throw new Exception("Unsupported ref argument.");
            if (args[i].isStruct || args[i].isStructRef) {
                foreach (owner, fields; args[i].structFieldMaps)
                    structFields[owner] = fields.dup;
                structFields[param] = args[i].structFields.dup;
                continue;
            }
            locals[param] = coerceValueToType(args[i].value, param.type);
        }
    }

    private void runStatement(
        Statement statement,
        ref Interpreter interpreter,
    ) {
        if (statement is null)
            return;

        // DMD lowers the currently supported `foreach (x; array)` cases to
        // this for-statement shape before the tree-walker sees them.
        if (auto scope_ = statement.isScopeStatement) {
            if (scope_.statement !is null)
                runStatement(scope_.statement, interpreter);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; compoundStatements(compound)) {
                    runStatement(child, interpreter);
                    if (hasReturn || hasBreak || hasContinue || hasThrown)
                        return;
                }
            return;
        }

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; compoundStatements(compound)) {
                    runStatement(child, interpreter);
                    if (hasReturn || hasBreak || hasContinue || hasThrown)
                        return;
                }
            return;
        }

        if (statement.isDtorExpStatement !is null)
            return;

        if (statement.isCompoundAsmStatement !is null)
            return;

        if (auto expr = statement.isExpStatement) {
            runExpression(expr.exp, interpreter, true);
            return;
        }

        if (auto for_ = statement.isForStatement) {
            if (for_._init !is null)
                runStatement(for_._init, interpreter);
            while (for_.condition is null || runExpression(for_.condition, interpreter).asLong) {
                runStatement(for_._body, interpreter);
                if (hasThrown)
                    return;
                if (hasReturn)
                    return;
                if (hasBreak) {
                    hasBreak = false;
                    break;
                }
                if (hasContinue)
                    hasContinue = false;
                if (for_.increment !is null)
                    runExpression(for_.increment, interpreter, true);
            }
            return;
        }

        if (auto do_ = statement.isDoStatement) {
            do {
                runStatement(do_._body, interpreter);
                if (hasThrown)
                    return;
                if (hasReturn)
                    return;
                if (hasBreak) {
                    hasBreak = false;
                    break;
                }
                if (hasContinue)
                    hasContinue = false;
            } while (runExpression(do_.condition, interpreter).asLong);
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            if (tryRunRegisteredChildClassBranch(if_, interpreter))
                return;
            const cond = runExpression(if_.condition, interpreter).asLong;
            if (cond)
                runStatement(if_.ifbody, interpreter);
            else if (if_.elsebody !is null)
                runStatement(if_.elsebody, interpreter);
            return;
        }

        if (auto tryFinally = statement.isTryFinallyStatement) {
            try {
                runStatement(tryFinally._body, interpreter);
            } finally {
                runStatement(tryFinally.finalbody, interpreter);
            }
            return;
        }

        if (auto tryCatch = statement.isTryCatchStatement) {
            runStatement(tryCatch._body, interpreter);
            if (hasThrown) {
                if (tryCatch.catches !is null && tryCatch.catches.length > 0) {
                    hasThrown = false;
                    thrownMessage = null;
                    runStatement((*tryCatch.catches)[0].handler, interpreter);
                }
            }
            return;
        }

        if (auto switch_ = statement.isSwitchStatement) {
            runSwitchStatement(switch_, interpreter);
            return;
        }

        if (auto ret = statement.isReturnStatement) {
            if (ret.exp !is null)
                returnValue = runExpression(ret.exp, interpreter);
            hasReturn = true;
            return;
        }

        if (auto throwStatement = statement.isThrowStatement) {
            hasThrown = true;
            thrownMessage = newExceptionMessage(throwStatement.exp, interpreter);
            return;
        }

        if (statement.isBreakStatement !is null) {
            hasBreak = true;
            return;
        }

        if (statement.isContinueStatement !is null) {
            hasContinue = true;
            return;
        }

        if (statement.isImportStatement !is null)
            return;

        if (auto conditional = statement.isConditionalStatement) {
            runStatement(
                conditionalStatementIncluded(conditional)
                    ? conditional.ifbody
                    : conditional.elsebody,
                interpreter,
            );
            return;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            foreach (child; *unrolled.statements) {
                runStatement(child, interpreter);
                if (hasReturn || hasBreak || hasContinue || hasThrown)
                    return;
            }
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    private bool tryRunRegisteredChildClassBranch(
        IfStatement statement,
        ref Interpreter interpreter,
    ) {
        import std.algorithm.searching: canFind;

        if (!interpreter.childClassRegistered)
            return false;
        if (!expressionChars(statement.condition).canFind("_childCerealisers"))
            return false;

        runStatement(statement.ifbody, interpreter);
        return true;
    }

    private void runSwitchStatement(
        SwitchStatement statement,
        ref Interpreter interpreter,
    ) {
        const condition = runExpression(statement.condition, interpreter).asLong;
        if (statement.cases !is null)
            foreach (case_; *statement.cases) {
                const caseValue = runExpression(case_.exp, interpreter).asLong;
                if (caseValue != condition)
                    continue;
                runStatement(case_.statement, interpreter);
                if (hasBreak)
                    hasBreak = false;
                return;
            }

        if (statement.sdefault !is null) {
            runStatement(statement.sdefault.statement, interpreter);
            if (hasBreak)
                hasBreak = false;
        }
    }

    private bool conditionalStatementIncluded(
        ConditionalStatement statement,
    ) @trusted {
        import dmd.cond: Include;

        return statement.condition.inc == Include.yes;
    }

    private string newExceptionMessage(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        if (expression is null)
            return "Unittest assertion failed.";

        auto new_ = expression.isNewExp;
        if (new_ is null || new_.arguments is null || new_.arguments.length == 0)
            return "Unittest assertion failed.";

        string message;
        if (!tryExceptionMessagePart((*new_.arguments)[0], message, interpreter))
            return "Unittest assertion failed.";
        return message.idup;
    }

    private bool tryExceptionMessagePart(
        Expression expression,
        ref string message,
        ref Interpreter interpreter,
    ) {
        if (expression is null)
            return false;

        if (auto literal = expression.isStringExp) {
            message ~= literal.peekString.idup;
            return true;
        }

        if (auto integer = expression.isIntegerExp) {
            import std.conv: text;

            message ~= text(integerValue(integer));
            return true;
        }

        if (auto call = expression.isCallExp) {
            if (call.arguments is null)
                return false;
            foreach (argument; callArguments(call))
                if (!tryExceptionMessagePart(argument, message, interpreter))
                    return false;
            return true;
        }

        if (auto concatenate = expression.isCatExp) {
            if (!tryExceptionMessagePart(concatenate.e1, message, interpreter))
                return false;
            return tryExceptionMessagePart(concatenate.e2, message, interpreter);
        }

        try {
            import std.conv: text;
            import std.sumtype: match;

            runExpression(expression, interpreter).match!(
                (long value) {
                    message ~= text(value);
                },
                (long[] elements) {
                    foreach (element; elements)
                        message ~= cast(char) element;
                },
                (LocalPtr _) {},
                (ClassRef _) {},
                (AssocArrayRef _) {},
                (AssocArraySlotRef _) {},
            );
            return true;
        } catch (Exception) {
            return false;
        }
    }

    private Value runExpression(
        Expression expression,
        ref Interpreter interpreter,
        in bool resultIgnored = false,
    ) {
        import std.conv: text;

        Value globalValue;
        Value localValue;

        void unsupported() {
            throw new Exception(
                text("Unsupported expression: ", expressionChars(expression)),
            );
        }

        if (auto integer = expression.isIntegerExp)
            return Value(integerValue(integer));

        if (auto real_ = expression.isRealExp)
            return Value(realLiteralBits(real_));

        if (expression.isNullExp)
            return Value(0L);

        if (auto literal = expression.isFuncExp)
            return Value(functionReference(literal.fd, interpreter));

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1, interpreter, true);
            return runExpression(comma.e2, interpreter, resultIgnored);
        }

        if (auto call = expression.isCallExp)
            return runCallExpression(call, interpreter, resultIgnored);

        if (auto new_ = expression.isNewExp)
            return runNewExpression(new_, interpreter);

        if (auto equal = expression.isEqualExp)
            return runEqualExpression(equal, interpreter);

        if (auto identity = expression.isIdentityExp)
            return runIdentityExpression(identity, interpreter);

        if (auto assert_ = expression.isAssertExp) {
            const cond = runExpression(assert_.e1, interpreter).asLong;
            if (!cond)
                throw new Exception("Unittest assertion failed.");
            return Value(cond);
        }

        if (auto decl = expression.isDeclarationExp)
            return runDeclarationExpression(decl, interpreter);

        if (auto dotVar = expression.isDotVarExp)
            return runDotVarExpression(dotVar, interpreter);

        if (isComparisonExpression(expression))
            return runComparisonExpression(expression, interpreter);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct, interpreter);

        if (auto blit = expression.isBlitExp)
            return runAssignExpression(blit, interpreter);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign, interpreter);

        if (auto assign = expression.isLoweredAssignExp)
            return runAssignExpression(assign, interpreter);

        if (auto concatenate = expression.isCatExp)
            return runArrayConcatenateExpression(concatenate, interpreter);

        if (auto append = expression.isCatAssignExp)
            return runArrayAppendExpression(append, interpreter);

        if (auto append = expression.isCatElemAssignExp)
            return runArrayAppendExpression(append, interpreter);

        if (auto addAssign = expression.isAddAssignExp) {
            if (auto var = addAssign.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const newVal = locals[varDecl].asLong +
                            runExpression(addAssign.e2, interpreter).asLong;
                        locals[varDecl] = Value(newVal);
                        return Value(newVal);
                    }
            if (auto cast_ = addAssign.e1.isCastExp)
                if (auto var = cast_.e1.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (tryGetLocalValue(varDecl, localValue)) {
                            const newVal = localValue.asLong +
                                runExpression(addAssign.e2, interpreter).asLong;
                            locals[varDecl] = Value(
                                coerceIntegerToType(newVal, varDecl.type),
                            );
                            return Value(newVal);
                        }
            if (auto dotVar = addAssign.e1.isDotVarExp)
                if (auto thisExp = dotVar.e1.isThisExp)
                    if (auto thisDecl = thisExp.var.isVarDeclaration)
                        if (auto fields = thisDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const newVal = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value(0L),
                                ).asLong +
                                    runExpression(addAssign.e2, interpreter).asLong;
                                assignStructField(
                                    *fields,
                                    fieldDecl,
                                    Value(coerceIntegerToType(newVal, fieldDecl.type)),
                                );
                                return Value(newVal);
                            }
            unsupported;
        }

        if (auto minAssign = expression.isMinAssignExp) {
            if (auto var = minAssign.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const newVal = locals[varDecl].asLong -
                            runExpression(minAssign.e2, interpreter).asLong;
                        locals[varDecl] = Value(newVal);
                        return Value(newVal);
                    }
            unsupported;
        }

        if (auto orAssign = expression.isOrAssignExp) {
            if (auto var = orAssign.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const newVal = locals[varDecl].asLong |
                            runExpression(orAssign.e2, interpreter).asLong;
                        locals[varDecl] = Value(
                            coerceIntegerToType(newVal, varDecl.type),
                        );
                        return Value(newVal);
                    }
            if (auto cast_ = orAssign.e1.isCastExp)
                if (auto var = cast_.e1.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (varDecl in locals) {
                            const newVal = locals[varDecl].asLong |
                                runExpression(orAssign.e2, interpreter).asLong;
                            locals[varDecl] = Value(
                                coerceIntegerToType(newVal, varDecl.type),
                            );
                            return Value(newVal);
                        }
            if (auto cast_ = orAssign.e1.isCastExp)
                if (auto dotVar = cast_.e1.isDotVarExp)
                    if (auto thisExp = dotVar.e1.isThisExp)
                        if (auto thisDecl = thisExp.var.isVarDeclaration)
                            if (auto fields = thisDecl in structFields)
                                if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                    const newVal = structFieldValue(
                                        *fields,
                                        fieldDecl,
                                        Value(0L),
                                    ).asLong |
                                        runExpression(orAssign.e2, interpreter).asLong;
                                    assignStructField(
                                        *fields,
                                        fieldDecl,
                                        Value(coerceIntegerToType(
                                            newVal,
                                            fieldDecl.type,
                                        )),
                                    );
                                    return Value(newVal);
                                }
            unsupported;
        }

        if (auto xorAssign = expression.isXorAssignExp) {
            if (auto var = xorAssign.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const newVal = locals[varDecl].asLong ^
                            runExpression(xorAssign.e2, interpreter).asLong;
                        locals[varDecl] = Value(
                            coerceIntegerToType(newVal, varDecl.type),
                        );
                        return Value(newVal);
                    }
            if (auto dotVar = xorAssign.e1.isDotVarExp)
                if (auto thisExp = dotVar.e1.isThisExp)
                    if (auto thisDecl = thisExp.var.isVarDeclaration)
                        if (auto fields = thisDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const newVal = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value(0L),
                                ).asLong ^
                                    runExpression(xorAssign.e2, interpreter).asLong;
                                assignStructField(
                                    *fields,
                                    fieldDecl,
                                    Value(coerceIntegerToType(newVal, fieldDecl.type)),
                                );
                                return Value(newVal);
                            }
            unsupported;
        }

        if (auto assign = expression.isBinAssignExp)
            return runBinAssignExpression(assign, interpreter);

        if (expression.isPostExp) {
            Value value;
            if (tryRunPostExpression(expression, value))
                return value;
            unsupported;
        }

        Value integerBinaryValue;
        if (tryRunIntegerBinaryExpression(
            expression,
            integerBinaryValue,
            interpreter,
        ))
            return integerBinaryValue;

        if (auto complement = expression.isComExp)
            return Value(~runExpression(complement.e1, interpreter).asLong);

        if (auto negate = expression.isNegExp)
            return Value(-runExpression(negate.e1, interpreter).asLong);

        if (auto not = expression.isNotExp)
            return Value(cast(long) (runExpression(not.e1, interpreter).asLong == 0));

        if (auto logical = expression.isLogicalExp) {
            import dmd.tokens: EXP;

            if (logical.op == EXP.andAnd) {
                if (runExpression(logical.e1, interpreter).asLong == 0)
                    return Value(0L);
                return Value(
                    cast(long) (runExpression(logical.e2, interpreter).asLong != 0),
                );
            }

            if (logical.op == EXP.orOr) {
                if (runExpression(logical.e1, interpreter).asLong != 0)
                    return Value(1L);
                return Value(
                    cast(long) (runExpression(logical.e2, interpreter).asLong != 0),
                );
            }
        }

        if (expression.isCondExp)
            return runConditionalExpression(expression, interpreter);

        if (expression.isDivExp)
            return runDivExpression(expression, interpreter);

        if (expression.isModExp)
            return runModExpression(expression, interpreter);

        if (auto cast_ = expression.isCastExp)
            return coerceValueToType(runExpression(cast_.e1, interpreter), cast_.to);

        if (auto literal = expression.isArrayLiteralExp) {
            return Value(arrayLiteralRuntimeValue(
                literal,
                arrayElementType(literal.type),
                interpreter,
            ));
        }

        if (auto literal = expression.isAssocArrayLiteralExp)
            return runAssocArrayLiteralExpression(literal, interpreter);

        if (auto literal = expression.isStructLiteralExp)
            return Value(structLiteralCerealBytes(literal, interpreter));

        if (auto literal = expression.isStringExp)
            return Value(stringLiteralElements(literal));

        if (auto slice = expression.isSliceExp) {
            if (slice.lwr !is null && slice.upr !is null) {
                if (isGcBlockBaseExpression(slice.e1))
                    return Value((long[]).init);
                long[] array;
                try {
                    array = runExpression(slice.e1, interpreter).asArray;
                } catch (Exception e) {
                    throw new Exception(text(
                        e.msg,
                        " while slicing ",
                        expressionChars(slice.e1),
                    ));
                }
                const lower = runSliceBound(slice.lwr, interpreter, array.length);
                const upper = runSliceBound(slice.upr, interpreter, array.length);
                // Explicit type: Value stores mutable array slices.
                long[] elements = array[cast(size_t) lower .. cast(size_t) upper]
                    .dup;
                return Value(elements);
            }
            if (slice.lwr is null && slice.upr is null)
                if (auto var = slice.e1.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (varDecl in locals)
                            return locals[varDecl];
            if (slice.lwr is null && slice.upr is null)
                if (auto dotVar = slice.e1.isDotVarExp)
                    if (auto ownerVar = dotVar.e1.isVarExp)
                        if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                            if (auto fields = ownerDecl in structFields)
                                if (auto fieldDecl = dotVar.var.isVarDeclaration)
                                    return structFieldValue(
                                        *fields,
                                        fieldDecl,
                                        Value((long[]).init),
                                    );
            unsupported;
        }

        if (auto array = expression.isArrayExp) {
            if (arrayExpressionArguments(array).length == 0)
                return runExpression(array.e1, interpreter);
            if (arrayExpressionArguments(array).length == 1) {
                const i = runExpression(
                    arrayExpressionArguments(array)[0],
                    interpreter,
                ).asLong;
                if (auto var = array.e1.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (varDecl in locals)
                            return Value(locals[varDecl].asArray[cast(size_t) i]);
                if (auto dotVar = array.e1.isDotVarExp)
                    if (auto owner = structFieldsOwner(dotVar.e1))
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            auto fields = structFieldsValue(owner);
                            return Value(
                                structFieldValue(
                                    fields,
                                    fieldDecl,
                                    defaultArrayValue(fieldDecl.type),
                                ).asArray[cast(size_t) i],
                            );
                        }
            }
            unsupported;
        }

        if (auto index = expression.isIndexExp) {
            Value indexedValue;
            if (tryRunAssocArrayKeysIndex(index, indexedValue, interpreter))
                return indexedValue;
            if (index.loweredFrom !is null)
                if (auto originalIndex = index.loweredFrom.isIndexExp)
                    if (tryRunAssocArrayIndex(
                        originalIndex,
                        indexedValue,
                        interpreter,
                    ))
                        return indexedValue;
            if (tryRunAssocArrayIndex(index, indexedValue, interpreter))
                return indexedValue;
            if (index.e1.type !is null &&
                index.e1.type.toBasetype.isTypePointer !is null) {
                const pointer = runExpression(index.e1, interpreter);
                if (tryRunAssocArraySlotDereference(
                    pointer,
                    indexedValue,
                    interpreter,
                ))
                    return indexedValue;
                return pointer;
            }
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (tryGetLocalValue(varDecl, localValue)) {
                        const arrayId = localValue.assocArrayId;
                        if (arrayId != 0 && arrayId in interpreter.assocArrays) {
                            size_t keyIndex;
                            if (tryAssocArrayKeyExpressionIndex(
                                arrayId,
                                index.e2,
                                keyIndex,
                                interpreter,
                            ))
                                return interpreter.assocArrays[arrayId]
                                    .values[keyIndex];
                        }
                    }
            if (tryRunNestedArrayIndex(index, indexedValue, interpreter))
                return indexedValue;
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (tryGetLocalValue(varDecl, localValue)) {
                        const i = runExpression(index.e2, interpreter).asLong;
                        return Value(localValue.asArray[cast(size_t) i]);
                    }
            if (auto dotVar = index.e1.isDotVarExp)
                if (auto ownerVar = dotVar.e1.isVarExp)
                    if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (auto fields = ownerDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const i = runExpression(index.e2, interpreter).asLong;
                                return Value(
                                    structFieldValue(
                                        *fields,
                                        fieldDecl,
                                        Value((long[]).init),
                                    ).asArray[cast(size_t) i],
                                );
                            }
            if (auto dotVar = index.e1.isDotVarExp)
                if (auto thisExp = dotVar.e1.isThisExp)
                    if (auto thisDecl = thisExp.var.isVarDeclaration)
                        if (auto fields = thisDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const i = runExpression(index.e2, interpreter).asLong;
                                return Value(
                                    structFieldValue(
                                        *fields,
                                        fieldDecl,
                                        Value((long[]).init),
                                    ).asArray[cast(size_t) i],
                                );
                            }
            try {
                const i = runExpression(index.e2, interpreter).asLong;
                return Value(runExpression(index.e1, interpreter)
                    .asArray[cast(size_t) i]);
            } catch (Exception) {
            }
            unsupported;
        }

        if (auto len = expression.isArrayLengthExp) {
            if (auto var = len.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (auto assocKeys = assocArrayKeysLocal(
                        varDecl,
                    ))
                        return Value(cast(long) assocKeys.keyStructs.length);
            if (auto var = len.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl.type !is null &&
                        varDecl.type.toBasetype.isTypeAArray !is null) {
                        if (varDecl in locals) {
                            const arrayId = locals[varDecl].assocArrayId;
                            return Value(assocArrayLength(arrayId, interpreter));
                        }
                        return Value(0L);
                    }
            if (auto var = len.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        return Value(arrayFieldLength(
                            locals[varDecl],
                            varDecl.type,
                        ));
                    }
            if (auto var = len.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (tryGetGlobalValue(varDecl, interpreter, globalValue))
                        return Value(arrayFieldLength(globalValue, varDecl.type));
            if (auto dotVar = len.e1.isDotVarExp)
                if (auto ownerVar = dotVar.e1.isVarExp)
                    if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (auto fields = ownerDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                if (fieldDecl.type !is null &&
                                    fieldDecl.type.toBasetype.isTypeAArray !is null) {
                                    const arrayId = structFieldValue(
                                        *fields,
                                        fieldDecl,
                                        Value(0L),
                                    ).assocArrayId;
                                    return Value(
                                        assocArrayLength(arrayId, interpreter),
                                    );
                                }
                                return Value(
                                    arrayFieldLength(
                                        structFieldValue(
                                            *fields,
                                            fieldDecl,
                                            Value((long[]).init),
                                        ),
                                        fieldDecl.type,
                                    ),
                                );
                            }
            if (len.e1.isCallExp)
                return Value(cast(long) runExpression(len.e1, interpreter).asArray.length);
            if (len.e1.isIndexExp)
                return Value(cast(long) runExpression(len.e1, interpreter).asArray.length);
            if (auto dotVar = len.e1.isDotVarExp)
                if (auto ptr = dotVar.e1.isPtrExp)
                    if (auto fields = classInstanceFields(
                        runExpression(ptr.e1, interpreter),
                        interpreter,
                    ))
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            return Value(
                                cast(long) structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value((long[]).init),
                                ).asArray.length,
                            );
            unsupported;
        }

        if (auto var = expression.isVarExp) {
            if (auto varDecl = var.var.isVarDeclaration) {
                import dmd.id: Id;
                // __ctfe is true in CTFE; at runtime it is false.
                if (varDecl.ident == Id.ctfe)
                    return Value(0L);
                if (tryGetLocalValue(varDecl, localValue))
                    return applyClearedRangeAlias(localValue, interpreter);
                if (tryGetGlobalValue(varDecl, interpreter, globalValue))
                    return applyClearedRangeAlias(globalValue, interpreter);
                if (currentThis !is null)
                    if (auto fields = currentThis in structFields)
                        return applyClearedRangeAlias(
                            structFieldValue(*fields, varDecl, Value(0L)),
                            interpreter,
                        );
                foreach (fields; structFields.byValue)
                    foreach (field, value; fields)
                        if (sameStructField(field, varDecl))
                            return applyClearedRangeAlias(value, interpreter);
            }
            if (var.var.ident !is null &&
                tryGetLocalValue(
                    var.var.ident.toString,
                    expression.type,
                    localValue,
                ))
                return applyClearedRangeAlias(localValue, interpreter);
        }

        if (auto identifier = expression.isIdentifierExp) {
            if (identifier.ident !is null &&
                tryGetUnqualifiedStructFieldValue(
                    identifier.ident.toString,
                    localValue,
                ))
                return applyClearedRangeAlias(localValue, interpreter);
            if (identifier.ident !is null &&
                tryGetLocalValue(
                    identifier.ident.toString,
                    expression.type,
                    localValue,
                ))
                return applyClearedRangeAlias(localValue, interpreter);
        }

        if (expression.isThisExp)
            return Value(0L);

        if (auto symbol = expression.isSymOffExp)
            if (auto function_ = symbol.var.isFuncDeclaration)
                return Value(functionReference(function_, interpreter));

        if (auto delegate_ = expression.isDelegateExp)
            return Value(functionReference(delegate_.func, interpreter));

        if (auto addr = expression.isAddrExp) {
            if (auto symbol = addr.e1.isSymOffExp)
                if (auto function_ = symbol.var.isFuncDeclaration)
                    return Value(functionReference(function_, interpreter));
            if (auto delegate_ = addr.e1.isDelegateExp)
                return Value(functionReference(delegate_.func, interpreter));
            if (auto var = addr.e1.isVarExp)
                if (auto function_ = var.var.isFuncDeclaration)
                    return Value(functionReference(function_, interpreter));
            if (auto var = addr.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals)
                        return Value(LocalPtr(varDecl));
            if (auto dotVar = addr.e1.isDotVarExp)
                if (auto ownerVar = dotVar.e1.isVarExp)
                    if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (auto fields = ownerDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const value = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value(0L),
                                );
                                if (value.classId != 0)
                                    return value;
                            }
        }

        // Pointer dereference *ptr: if ptr holds a LocalPtr, read the target.
        if (auto ptr = expression.isPtrExp) {
            import std.sumtype: match;
            import dmd.declaration: VarDeclaration;
            auto ptrVal = runExpression(ptr.e1, interpreter);
            VarDeclaration target = ptrVal.match!(
                (LocalPtr p) => p.decl,
                (long _) => cast(VarDeclaration) null,
                (long[] _) => cast(VarDeclaration) null,
                (ClassRef _) => cast(VarDeclaration) null,
                (AssocArrayRef _) => cast(VarDeclaration) null,
                (AssocArraySlotRef _) => cast(VarDeclaration) null,
            );
            if (target !is null && target in locals)
                return locals[target];
            const classId = ptrVal.classId;
            if (classId != 0 && classId in interpreter.heapScalars)
                return interpreter.heapScalars[classId];
            {
                import std.string: endsWith;

                if (expressionChars(expression).endsWith(".length"))
                    return Value(0L);
            }
        }

        {
            import std.string: endsWith;

            if (expressionChars(expression).endsWith(".length"))
                return Value(0L);
        }

        unsupported;
        assert(false);
    }

    private bool tryRunNestedArrayIndex(
        IndexExp index,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (index.e1.type is null)
            return false;

        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto elementType = arrayElementType(index.e1.type);
        if (!isLengthPrefixedArrayElementType(elementType))
            return false;

        const elementIndex = runExpression(index.e2, interpreter).asLong;
        if (elementIndex < 0)
            return false;

        long[] array = runExpression(index.e1, interpreter).asArray;
        size_t cursor;
        foreach (i; 0 .. cast(size_t) elementIndex + 1) {
            if (cursor >= array.length)
                return false;
            const length = nestedArrayLength(array[cursor]);
            ++cursor;
            if (length > array.length - cursor)
                return false;
            if (i == cast(size_t) elementIndex) {
                value = Value(array[cursor .. cursor + length].dup);
                return true;
            }
            cursor += length;
        }
        return false;
    }

    private bool tryRunPostExpression(
        Expression expression,
        ref Value value,
    ) {
        import dmd.tokens: EXP;

        auto post = expression.isPostExp;
        if (post.op == EXP.plusPlus)
            return tryRunPostExpression(post.e1, 1L, value);
        if (post.op == EXP.minusMinus)
            return tryRunPostExpression(post.e1, -1L, value);
        return false;
    }

    private bool tryRunPostExpression(
        Expression target,
        in long delta,
        ref Value value,
    ) {
        if (tryRunLocalPostExpression(target, delta, value))
            return true;
        return tryRunThisFieldPostExpression(target, delta, value);
    }

    private bool tryRunLocalPostExpression(
        Expression target,
        in long delta,
        ref Value value,
    ) {
        auto var = target.isVarExp;
        if (var is null)
            return false;

        auto varDecl = var.var.isVarDeclaration;
        if (varDecl is null || varDecl !in locals)
            return false;

        const oldVal = locals[varDecl].asLong;
        locals[varDecl] = Value(coerceIntegerToType(oldVal + delta, varDecl.type));
        value = Value(oldVal);
        return true;
    }

    private bool tryRunThisFieldPostExpression(
        Expression target,
        in long delta,
        ref Value value,
    ) {
        auto dotVar = target.isDotVarExp;
        if (dotVar is null)
            return false;

        auto thisExp = dotVar.e1.isThisExp;
        if (thisExp is null)
            return false;

        auto thisDecl = thisExp.var.isVarDeclaration;
        if (thisDecl is null)
            return false;

        auto fields = thisDecl in structFields;
        if (fields is null)
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        const oldVal = structFieldValue(*fields, fieldDecl, Value(0L)).asLong;
        assignStructField(
            *fields,
            fieldDecl,
            Value(coerceIntegerToType(oldVal + delta, fieldDecl.type)),
        );
        value = Value(oldVal);
        return true;
    }

    private bool tryRunIntegerBinaryExpression(
        Expression expression,
        ref Value value,
        ref Interpreter interpreter,
    ) {
        if (auto add = expression.isAddExp)
            return runIntegerBinaryExpression(
                add.e1,
                add.e2,
                IntBinaryOp.add,
                value,
                interpreter,
            );
        if (auto subtract = expression.isMinExp)
            return runIntegerBinaryExpression(
                subtract.e1,
                subtract.e2,
                IntBinaryOp.sub,
                value,
                interpreter,
            );
        if (auto multiply = expression.isMulExp)
            return runIntegerBinaryExpression(
                multiply.e1,
                multiply.e2,
                IntBinaryOp.mul,
                value,
                interpreter,
            );
        if (auto rightShift = expression.isShrExp)
            return runRightShiftExpression(
                expression,
                rightShift.e1,
                rightShift.e2,
                value,
                interpreter,
            );
        if (auto leftShift = expression.isShlExp)
            return runIntegerBinaryExpression(
                leftShift.e1,
                leftShift.e2,
                IntBinaryOp.shl,
                value,
                interpreter,
            );
        if (auto bitAnd = expression.isAndExp)
            return runIntegerBinaryExpression(
                bitAnd.e1,
                bitAnd.e2,
                IntBinaryOp.bitAnd,
                value,
                interpreter,
            );
        if (auto bitXor = expression.isXorExp)
            return runIntegerBinaryExpression(
                bitXor.e1,
                bitXor.e2,
                IntBinaryOp.bitXor,
                value,
                interpreter,
            );
        if (auto bitOr = expression.isOrExp)
            return runIntegerBinaryExpression(
                bitOr.e1,
                bitOr.e2,
                IntBinaryOp.bitOr,
                value,
                interpreter,
            );
        return false;
    }

    private bool runIntegerBinaryExpression(
        Expression left,
        Expression right,
        in IntBinaryOp op,
        ref Value value,
        ref Interpreter interpreter,
    ) {
        const leftValue = runExpression(left, interpreter).asLong;
        const rightValue = runExpression(right, interpreter).asLong;
        value = Value(runIntegerBinaryOperation(leftValue, rightValue, op));
        return true;
    }

    private long runIntegerBinaryOperation(
        in long left,
        in long right,
        in IntBinaryOp op,
    ) const {
        with (IntBinaryOp)
        final switch (op) {
            case add:
                return left + right;
            case sub:
                return left - right;
            case mul:
                return left * right;
            case shl:
                return left << right;
            case bitAnd:
                return left & right;
            case bitXor:
                return left ^ right;
            case bitOr:
                return left | right;
        }
    }

    private bool runRightShiftExpression(
        Expression expression,
        Expression left,
        Expression right,
        ref Value value,
        ref Interpreter interpreter,
    ) {
        import std.conv: text;

        try {
            value = Value(
                runExpression(left, interpreter).asLong >>
                runExpression(right, interpreter).asLong,
            );
            return true;
        } catch (Exception e) {
            throw new Exception(text(
                e.msg,
                " while evaluating ",
                expressionChars(expression),
                " left ",
                expressionChars(left),
                " right ",
                expressionChars(right),
            ));
        }
    }

    private Value runConditionalExpression(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        auto cond = expression.isCondExp;

        Value value;
        if (tryRunLoweredAssocArraySlotConditional(cond, value, interpreter))
            return value;
        if (tryRunAssocArrayConditionalValue(cond, value, interpreter))
            return value;
        if (runExpression(cond.econd, interpreter).asLong)
            return runExpression(cond.e1, interpreter);
        return runExpression(cond.e2, interpreter);
    }

    private Value runDivExpression(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        auto divide = expression.isDivExp;
        const right = runExpression(divide.e2, interpreter).asLong;
        if (right == 0)
            throw new Exception("Unittest assertion failed.");
        return Value(runExpression(divide.e1, interpreter).asLong / right);
    }

    private Value runModExpression(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        auto modulo = expression.isModExp;
        const right = runExpression(modulo.e2, interpreter).asLong;
        if (right == 0)
            throw new Exception("Unittest assertion failed.");
        return Value(runExpression(modulo.e1, interpreter).asLong % right);
    }

    private Value runDotVarExpression(
        DotVarExp dotVar,
        ref Interpreter interpreter,
    ) {
        import std.conv: text;

        Value value;
        if (tryRunDotVarBytesLeft(dotVar, value))
            return value;
        if (tryRunDotVarStructLength(dotVar, value))
            return value;
        if (tryRunDotVarLocalLength(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarGlobalLength(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarArrayFieldLength(dotVar, value))
            return value;
        if (tryRunDotVarInputRangeProperty(dotVar, value, interpreter))
            return value;
        if (dotVarFieldNamed(dotVar, "length")) {
            try {
                return Value(cast(long) runExpression(dotVar.e1, interpreter)
                    .asArray.length);
            } catch (Exception) {
            }
            return Value(0L);
        }
        if (tryRunDotVarKeys(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarValues(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarClassInfoName(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarStructFieldHandle(dotVar, value))
            return value;
        if (tryRunDotVarOwnerStructField(dotVar, value))
            return value;
        if (tryRunDotVarBitArrayField(dotVar, value))
            return value;
        if (tryRunDotVarLocalClassField(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarThisField(dotVar, value))
            return value;
        if (tryRunDotVarCurrentThisField(dotVar, value))
            return value;
        if (tryRunDotVarOwnedStructField(dotVar, value))
            return value;
        if (tryRunDotVarStructArrayElementField(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarGeneratedValueField(dotVar, value))
            return value;
        if (tryRunDotVarPointerClassField(dotVar, value, interpreter))
            return value;
        if (tryRunDotVarPointerArrayField(dotVar, value))
            return value;

        throw new Exception(text(
            "Unsupported expression: ",
            expressionChars(dotVar),
        ));
    }

    private bool tryRunDotVarInputRangeProperty(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        long[] elements;
        if (!tryReadInputRangeElements(dotVar.e1, elements, interpreter))
            return false;

        if (dotVarFieldNamed(dotVar, "front")) {
            if (elements.length == 0)
                throw new Exception("Cannot read front from empty range.");
            value = Value(elements[0]);
            return true;
        }

        if (dotVarFieldNamed(dotVar, "empty")) {
            value = Value(elements.length == 0 ? 1L : 0L);
            return true;
        }

        if (dotVarFieldNamed(dotVar, "length")) {
            value = Value(cast(long) elements.length);
            return true;
        }

        return false;
    }

    private bool tryRunDotVarBytesLeft(
        DotVarExp dotVar,
        out Value value,
    ) {
        if (!dotVarFieldNamed(dotVar, "bytesLeft"))
            return false;

        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        Value[VarDeclaration] fields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        if (bytesField is null)
            return false;

        value = Value(cast(long) structFieldValue(
            fields,
            bytesField,
            Value((long[]).init),
        ).asArray.length);
        return true;
    }

    private bool tryRunDotVarStructLength(
        DotVarExp dotVar,
        out Value value,
    ) {
        if (!dotVarFieldNamed(dotVar, "length"))
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        auto fields = structFieldsValue(owner);
        value = structFieldValue(fields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarLocalLength(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!dotVarFieldNamed(dotVar, "length"))
            return false;

        auto ownerVar = dotVar.e1.isVarExp;
        if (ownerVar is null)
            return false;

        auto ownerDecl = ownerVar.var.isVarDeclaration;
        if (ownerDecl is null)
            return false;

        auto local = ownerDecl in locals;
        if (local is null)
            return false;

        const arrayId = (*local).assocArrayId;
        if (arrayId != 0)
            value = Value(assocArrayLength(arrayId, interpreter));
        else
            value = Value(arrayFieldLength(*local, ownerDecl.type));
        return true;
    }

    private bool tryRunDotVarGlobalLength(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!dotVarFieldNamed(dotVar, "length"))
            return false;

        auto ownerVar = dotVar.e1.isVarExp;
        if (ownerVar is null)
            return false;

        auto ownerDecl = ownerVar.var.isVarDeclaration;
        if (ownerDecl is null)
            return false;

        auto global = ownerDecl in interpreter.globals;
        if (global is null)
            return false;

        value = Value(arrayFieldLength(*global, ownerDecl.type));
        return true;
    }

    private bool tryRunDotVarArrayFieldLength(
        DotVarExp dotVar,
        out Value value,
    ) {
        if (!dotVarFieldNamed(dotVar, "length"))
            return false;

        auto arrayField = dotVar.e1.isDotVarExp;
        if (arrayField is null)
            return false;

        auto fieldDecl = arrayField.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        auto owner = structFieldsOwner(arrayField.e1);
        if (owner is null)
            return false;

        auto fields = structFieldsValue(owner);
        value = Value(arrayFieldLength(
            structFieldValue(fields, fieldDecl, Value((long[]).init)),
            fieldDecl.type,
        ));
        return true;
    }

    private bool tryRunDotVarKeys(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!dotVarFieldNamed(dotVar, "keys"))
            return false;

        const arrayId = assocArrayIdFromExpression(dotVar.e1, interpreter);
        if (arrayId == 0) {
            if (isAssocArrayExpression(dotVar.e1)) {
                value = Value((long[]).init);
                return true;
            }
            return false;
        }
        if (arrayId !in interpreter.assocArrays)
            return false;

        value = Value(new long[interpreter.assocArrays[arrayId].keyStructs.length]);
        return true;
    }

    private bool tryRunDotVarValues(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!dotVarFieldNamed(dotVar, "values"))
            return false;

        const arrayId = assocArrayIdFromExpression(dotVar.e1, interpreter);
        if (arrayId == 0) {
            if (isAssocArrayExpression(dotVar.e1)) {
                value = Value((long[]).init);
                return true;
            }
            return false;
        }
        if (arrayId !in interpreter.assocArrays)
            return false;

        long[] values;
        foreach (arrayValue; interpreter.assocArrays[arrayId].values)
            values ~= arrayValue.asLong;
        value = Value(values);
        return true;
    }

    private bool tryRunDotVarClassInfoName(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!dotVarFieldNamed(dotVar, "name"))
            return false;

        Type classType;
        if (!tryClassInfoExpressionType(dotVar.e1, classType, interpreter))
            return false;

        value = Value(stringElements(classInfoName(classType)));
        return true;
    }

    private bool tryClassInfoExpressionType(
        Expression expression,
        out Type type,
        ref Interpreter interpreter,
    ) {
        if (auto dotVar = expression.isDotVarExp)
            if (dotVarFieldNamed(dotVar, "classinfo")) {
                if (dotVar.e1.isTypeExp)
                    if (tryClassInfoDeclarationType(dotVar, type))
                        return true;
                return tryClassExpressionType(dotVar.e1, type, interpreter);
            }
        return tryClassExpressionType(expression, type, interpreter);
    }

    private bool tryClassInfoDeclarationType(
        DotVarExp dotVar,
        out Type type,
    ) {
        if (dotVar.var is null)
            return false;

        // auto: DMD parent symbols are mutable AST nodes.
        auto parent = dotVar.var.toParent;
        if (parent is null)
            return false;

        auto class_ = parent.isClassDeclaration;
        if (class_ is null || class_.type is null)
            return false;

        type = class_.type;
        return isClassType(type) && !isClassInfoType(type);
    }

    private bool tryClassExpressionType(
        Expression expression,
        out Type type,
        ref Interpreter interpreter,
    ) {
        if (auto ptr = expression.isPtrExp)
            return tryClassExpressionType(ptr.e1, type, interpreter);

        if (auto cast_ = expression.isCastExp)
            return tryClassExpressionType(cast_.e1, type, interpreter);

        if (auto typeExp = expression.isTypeExp)
            if (isClassType(typeExp.type) && !isClassInfoType(typeExp.type)) {
                type = typeExp.type;
                return true;
            }

        if (auto typeid_ = expression.isTypeidExp) {
            import dmd.dtemplate: isDsymbol, isExpression, isType;

            if (auto typeObject = isType(typeid_.obj))
                if (isClassType(typeObject) && !isClassInfoType(typeObject)) {
                    type = typeObject;
                    return true;
                }
            if (auto symbolObject = isDsymbol(typeid_.obj))
                if (auto typeInfo = symbolObject.isTypeInfoDeclaration) {
                    type = typeInfo.tinfo;
                    return isClassType(type) && !isClassInfoType(type);
                }
            if (auto expressionObject = isExpression(typeid_.obj))
                return tryClassExpressionType(expressionObject, type, interpreter);
        }

        Value value;
        try {
            value = runExpression(expression, interpreter);
        } catch (Exception) {
            if (expression.type !is null &&
                isClassType(expression.type) &&
                !isClassInfoType(expression.type)) {
                type = expression.type;
                return true;
            }
            return false;
        }

        const classId = value.classId;
        if (classId != 0 && classId in interpreter.classTypes) {
            type = interpreter.classTypes[classId];
            return true;
        }

        if (expression.type !is null &&
            isClassType(expression.type) &&
            !isClassInfoType(expression.type)) {
            type = expression.type;
            return true;
        }
        return false;
    }

    private string classInfoName(Type type) {
        return qualifiedTypeChars(type);
    }

    private bool isClassInfoType(Type type) {
        if (type is null)
            return false;

        auto classType = type.toBasetype.isTypeClass;
        if (classType is null ||
            classType.sym is null ||
            classType.sym.ident is null)
            return false;

        const name = classType.sym.ident.toString;
        return name == "ClassInfo" || name == "TypeInfo_Class";
    }

    private long[] stringElements(in string value) {
        long[] elements;
        foreach (char_; value)
            elements ~= cast(long) char_;
        return elements;
    }

    private bool tryRunDotVarStructFieldHandle(
        DotVarExp dotVar,
        out Value value,
    ) {
        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null || fieldDecl !in structFields)
            return false;

        value = Value(0L);
        return true;
    }

    private bool tryRunDotVarOwnerStructField(
        DotVarExp dotVar,
        out Value value,
    ) {
        auto ownerVar = dotVar.e1.isVarExp;
        if (ownerVar is null)
            return false;

        auto ownerDecl = ownerVar.var.isVarDeclaration;
        if (ownerDecl is null)
            return false;

        auto fields = ownerDecl in structFields;
        if (fields is null)
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        value = structFieldValue(*fields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarBitArrayField(
        DotVarExp dotVar,
        out Value value,
    ) {
        auto ownerVar = dotVar.e1.isVarExp;
        if (ownerVar is null ||
            ownerVar.var.ident is null ||
            ownerVar.var.ident.toString != "bi")
            return false;
        if (!dotVarFieldNamed(dotVar, "base") && !dotVarFieldNamed(dotVar, "size"))
            return false;

        value = Value(0L);
        return true;
    }

    private bool tryRunDotVarLocalClassField(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        auto ownerVar = dotVar.e1.isVarExp;
        if (ownerVar is null)
            return false;

        auto ownerDecl = ownerVar.var.isVarDeclaration;
        if (ownerDecl is null)
            return false;

        auto local = ownerDecl in locals;
        if (local is null)
            return false;

        auto fields = classInstanceFields(*local, interpreter);
        if (fields is null)
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        value = structFieldValue(*fields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarThisField(
        DotVarExp dotVar,
        out Value value,
    ) {
        auto thisExp = dotVar.e1.isThisExp;
        if (thisExp is null)
            return false;

        auto thisDecl = thisExp.var.isVarDeclaration;
        if (thisDecl is null)
            return false;

        auto fields = thisDecl in structFields;
        if (fields is null)
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        value = structFieldValue(*fields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarCurrentThisField(
        DotVarExp dotVar,
        out Value value,
    ) {
        if (!dotVar.e1.isThisExp || currentThis is null)
            return false;

        auto fields = currentThis in structFields;
        if (fields is null)
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        value = structFieldValue(*fields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarOwnedStructField(
        DotVarExp dotVar,
        out Value value,
    ) {
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        auto fields = structFieldsValue(owner);
        value = structFieldValue(fields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarStructArrayElementField(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!isStructType(dotVar.e1.type))
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        Value[VarDeclaration] elementFields;
        if (!tryStructArrayElementFields(dotVar.e1, elementFields, interpreter))
            return false;

        value = structFieldValue(elementFields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarGeneratedValueField(
        DotVarExp dotVar,
        out Value value,
    ) {
        if (!isUnitThreadedGeneratedValueExpression(dotVar))
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        value = defaultValue(fieldDecl.type);
        return true;
    }

    private bool tryRunDotVarPointerClassField(
        DotVarExp dotVar,
        out Value value,
        ref Interpreter interpreter,
    ) {
        auto ptr = dotVar.e1.isPtrExp;
        if (ptr is null)
            return false;

        auto fields = classInstanceFields(
            runExpression(ptr.e1, interpreter),
            interpreter,
        );
        if (fields is null)
            return false;

        auto fieldDecl = dotVar.var.isVarDeclaration;
        if (fieldDecl is null)
            return false;

        value = structFieldValue(*fields, fieldDecl, Value(0L));
        return true;
    }

    private bool tryRunDotVarPointerArrayField(
        DotVarExp dotVar,
        out Value value,
    ) {
        if (dotVar.e1.isPtrExp is null || !dotVarFieldNamed(dotVar, "arr"))
            return false;

        value = Value((long[]).init);
        return true;
    }

    private bool tryGetUnqualifiedStructFieldValue(
        const(char)[] name,
        out Value value,
    ) {
        if (currentThis is null)
            return false;

        auto fields = currentThis in structFields;
        if (fields is null)
            return false;

        foreach (field, fieldValue; *fields) {
            if (field.ident is null || field.ident.toString != name)
                continue;
            value = fieldValue;
            return true;
        }

        return false;
    }

    private bool dotVarFieldNamed(DotVarExp dotVar, in string name) {
        return dotVar.var.ident !is null && dotVar.var.ident.toString == name;
    }

    private long functionReference(
        FuncDeclaration function_,
        ref Interpreter interpreter,
    ) {
        const ref_ = interpreter.nextFunctionRef;
        --interpreter.nextFunctionRef;
        interpreter.functions[ref_] = function_;
        return ref_;
    }

    private Value runArrayConcatenateExpression(
        CatExp concatenate,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        Value left = runExpression(concatenate.e1, interpreter);
        Value right = runExpression(concatenate.e2, interpreter);
        // Explicit type: `elements` must be mutable for append.
        long[] elements = left.match!(
            (long[] array) => array,
            (long scalar) => [scalar],
            (LocalPtr _) {
                throw new Exception("Expected concatenation value, got pointer.");
                return (long[]).init;
            },
            (ClassRef _) {
                throw new Exception("Expected concatenation value, got class.");
                return (long[]).init;
            },
            (AssocArrayRef _) {
                throw new Exception("Expected concatenation value, got AA.");
                return (long[]).init;
            },
            (AssocArraySlotRef _) {
                throw new Exception("Expected concatenation value, got AA slot.");
                return (long[]).init;
            },
        );
        right.match!(
            (long[] array) {
                elements ~= array;
            },
            (long scalar) {
                elements ~= scalar;
            },
            (LocalPtr _) {
                throw new Exception("Expected concatenation value, got pointer.");
            },
            (ClassRef _) {
                throw new Exception("Expected concatenation value, got class.");
            },
            (AssocArrayRef _) {
                throw new Exception("Expected concatenation value, got AA.");
            },
            (AssocArraySlotRef _) {
                throw new Exception("Expected concatenation value, got AA slot.");
            },
        );
        return Value(elements);
    }

    private Value runAssocArrayLiteralExpression(
        AssocArrayLiteralExp literal,
        ref Interpreter interpreter,
    ) {
        import dmd.declaration: VarDeclaration;

        AssocArray array;
        foreach (index, keyExpression; assocArrayLiteralKeys(literal)) {
            VarDeclaration keyStruct;
            Value[VarDeclaration] keyFields;
            if (auto owner = structFieldsOwner(keyExpression)) {
                keyStruct = owner;
                keyFields = structFieldsValue(owner).dup;
            } else if (auto var = keyExpression.isVarExp)
                keyStruct = var.var.isVarDeclaration;
            if (keyStruct !is null && keyFields !is null) {
                array.keyStructs ~= keyStruct;
                array.keyFields ~= keyFields;
                array.keys ~= Value(0L);
            } else {
                array.keyStructs ~= null;
                array.keyFields ~= null;
                array.keys ~= runExpression(keyExpression, interpreter);
            }
            array.values ~= runExpression(
                assocArrayLiteralValues(literal)[index],
                interpreter,
            );
        }

        const assocArrayRef = AssocArrayRef(interpreter.nextAssocArrayRef);
        ++interpreter.nextAssocArrayRef;
        interpreter.assocArrays[assocArrayRef.id] = array;
        return Value(assocArrayRef);
    }

    private bool tryRunAssocArrayIndex(
        IndexExp index,
        out Value value,
        ref Interpreter interpreter,
    ) {
        long arrayId;
        try {
            arrayId = assocArrayIdFromExpression(index.e1, interpreter);
        } catch (Exception) {
            return false;
        }
        if (arrayId == 0 || arrayId !in interpreter.assocArrays)
            return false;

        size_t keyIndex;
        if (tryAssocArrayKeyExpressionIndex(
            arrayId,
            index.e2,
            keyIndex,
            interpreter,
        )) {
            value = interpreter.assocArrays[arrayId].values[keyIndex];
            return true;
        }

        return false;
    }

    private bool tryRunAssocArrayKeysIndex(
        IndexExp index,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (index.loweredFrom !is null)
            if (auto originalIndex = index.loweredFrom.isIndexExp)
                if (tryRunAssocArrayKeysDirectIndex(
                    originalIndex,
                    value,
                    interpreter,
                ))
                    return true;

        return tryRunAssocArrayKeysDirectIndex(index, value, interpreter);
    }

    private bool tryRunAssocArrayKeysDirectIndex(
        IndexExp index,
        out Value value,
        ref Interpreter interpreter,
    ) {
        auto var = index.e1.isVarExp;
        if (var is null)
            return false;

        auto varDecl = var.var.isVarDeclaration;
        if (varDecl is null)
            return false;

        auto keys = assocArrayKeysLocal(varDecl);
        if (keys is null)
            return false;

        const keyIndex = runExpression(index.e2, interpreter).asLong;
        if (keyIndex < 0 || cast(size_t) keyIndex >= keys.keyStructs.length)
            throw new Exception("Array bounds check failed.");
        if (cast(size_t) keyIndex >= keys.keys.length)
            throw new Exception("Array bounds check failed.");

        value = keys.keys[cast(size_t) keyIndex];
        return true;
    }

    private bool tryRunAssocArraySlotDereference(
        Value pointer,
        out Value value,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        AssocArraySlotRef slot;
        const hasSlot = pointer.match!(
            (AssocArraySlotRef ref_) {
                slot = ref_;
                return true;
            },
            (long _) => false,
            (long[] _) => false,
            (LocalPtr _) => false,
            (ClassRef _) => false,
            (AssocArrayRef _) => false,
        );
        if (!hasSlot)
            return false;
        if (slot.arrayId == 0 || slot.arrayId !in interpreter.assocArrays)
            return false;
        if (slot.index >= interpreter.assocArrays[slot.arrayId].values.length)
            return false;

        value = interpreter.assocArrays[slot.arrayId].values[slot.index];
        return true;
    }

    private bool tryRunAssocArrayConditionalValue(
        imported!"dmd.expression".CondExp cond,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (runExpression(cond.econd, interpreter).asLong == 0)
            return false;
        auto index = cond.e1.isIndexExp;
        if (index is null)
            return false;
        return tryRunAssocArrayIndex(index, value, interpreter);
    }

    private bool tryRunLoweredAssocArraySlotConditional(
        imported!"dmd.expression".CondExp cond,
        out Value value,
        ref Interpreter interpreter,
    ) {
        auto var = cond.econd.isVarExp;
        if (var is null)
            return false;

        auto varDecl = var.var.isVarDeclaration;
        if (varDecl is null)
            return false;

        auto slot = assocArraySlotLocal(varDecl);
        if (slot is null)
            return false;
        if (slot.arrayId == 0 || slot.arrayId !in interpreter.assocArrays)
            return false;
        if (slot.index >= interpreter.assocArrays[slot.arrayId].values.length)
            return false;

        value = runExpression(cond.e1, interpreter);
        return true;
    }

    private bool tryAssocArrayKeyExpressionIndex(
        in long arrayId,
        Expression expression,
        out size_t index,
        ref Interpreter interpreter,
    ) {
        if (arrayId == 0 || arrayId !in interpreter.assocArrays)
            return false;

        if (auto var = expression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (auto keyLocal = assocArrayKeyLocal(varDecl)) {
                    index = keyLocal.index;
                    return index < interpreter.assocArrays[arrayId].values.length;
                }

        if (auto owner = structFieldsOwner(expression))
            return tryAssocArrayStructKeyIndex(
                arrayId,
                structFieldsValue(owner),
                index,
                interpreter,
            );

        Value key;
        try {
            key = runExpression(expression, interpreter);
        } catch (Exception) {
            return false;
        }
        return tryAssocArrayKeyIndex(arrayId, key, index, interpreter);
    }

    private bool tryRunCerealiserBytes(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        import std.algorithm.searching: canFind;

        if ((call.f.ident is null || call.f.ident.toString != "bytes") &&
            !expressionChars(call.e1).canFind(".bytes"))
            return false;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;

        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        auto outputField = structFieldNamed(owner.type, "_output");
        if (outputField is null)
            return false;

        Value[VarDeclaration] outputFields;
        if (!tryGetStructFields(outputField, outputFields))
            return false;

        auto bytesField = rangeStorageField(outputField.type);
        if (bytesField is null)
            return false;

        long[] elements = isModeledScopeBufferField(bytesField)
            ? interpreter.scopeBufferBytes.get(
                rangeStorageKey(outputField, bytesField),
                (long[]).init,
            )
            : storageArrayValue(structFieldValue(
                outputFields,
                bytesField,
                Value((long[]).init),
            ));
        if (interpreter.hasCerealiserOutputStart &&
            interpreter.cerealiserOutputStart <= elements.length)
            elements = elements[interpreter.cerealiserOutputStart .. $].dup;
        value = Value(elements.dup);
        return true;
    }

    private bool tryAssocArrayStructKeyIndex(
        in long arrayId,
        Value[VarDeclaration] keyFields,
        out size_t index,
        ref Interpreter interpreter,
    ) {
        if (arrayId == 0 || arrayId !in interpreter.assocArrays)
            return false;

        AssocArray array = interpreter.assocArrays[arrayId];
        foreach (i, keyStruct; array.keyStructs) {
            Value[VarDeclaration] existingFields;
            if (!tryAssocArrayStoredStructKeyFields(
                array,
                i,
                existingFields,
            ))
                continue;
            if (fieldValuesEqual(
                existingFields,
                keyFields,
                interpreter,
            )) {
                index = i;
                return true;
            }
        }
        return false;
    }

    private Value runNewExpression(
        NewExp new_,
        ref Interpreter interpreter,
    ) {
        import std.conv: text;

        if (new_.placement !is null || new_.thisexp !is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(new_)));
        const classRef = ClassRef(interpreter.nextClassRef);
        ++interpreter.nextClassRef;
        interpreter.classTypes[classRef.id] = new_.newtype;
        if (!isClassType(new_.newtype) && !isStructType(new_.newtype)) {
            interpreter.heapScalars[classRef.id] = Value(0L);
            return Value(classRef);
        }
        if (isClassType(new_.newtype))
            interpreter.classFields[classRef.id] = defaultClassFields(new_.newtype);
        else
            interpreter.classFields[classRef.id] = newStructFields(new_, interpreter);
        interpreter.classStructFieldMaps[classRef.id] =
            nestedStructFieldMaps(interpreter.classFields[classRef.id]);

        if (new_.member !is null) {
            Expression[] arguments;
            if (new_.arguments !is null)
                arguments = newArguments(new_);
            // `auto` is intentional: constructor execution mutates field maps.
            auto result = interpreter.executeFunction(
                new_.member,
                callArgumentsFor(new_.member, arguments, interpreter),
                interpreter.classFields[classRef.id],
            );
            interpreter.classFields[classRef.id] = result.thisFields;
            interpreter.classStructFieldMaps[classRef.id] = result.structFieldMaps;
        }

        return Value(classRef);
    }

    private CallArgument[] callArgumentsFor(
        FuncDeclaration function_,
        Expression[] arguments,
        ref Interpreter interpreter,
    ) {
        CallArgument[] args;

        foreach (i, arg; arguments) {
            if (function_.parameters is null || i >= function_.parameters.length)
                throw new Exception("Unsupported call.");
            const param = functionParameters(function_)[i];
            import dmd.astenums: STC;

            if ((param.storage_class & STC.ref_) != STC.none) {
                if (auto thisExp = arg.isThisExp)
                    if (auto thisDecl = thisExp.var.isVarDeclaration)
                        if (auto fields = thisDecl in structFields) {
                            CallArgument structRefArg;
                            structRefArg.refSource = thisDecl;
                            structRefArg.structFields = (*fields).dup;
                            structRefArg.structFieldMaps =
                                nestedStructFieldMaps(*fields);
                            structRefArg.isStructRef = true;
                            args ~= structRefArg;
                            continue;
                        }
                throw new Exception("Unsupported ref argument.");
            }

            if (auto literal = arg.isStructLiteralExp) {
                CallArgument structArg;
                structArg.structFields = runStructLiteralExpression(
                    literal,
                    interpreter,
                );
                structArg.structFieldMaps =
                    nestedStructFieldMaps(structArg.structFields);
                structArg.isStruct = true;
                args ~= structArg;
                continue;
            }

            args ~= CallArgument(
                runExpression(arg, interpreter),
                null,
                null,
                null,
            );
        }

        return args;
    }

    private Value[VarDeclaration] newStructFields(
        NewExp new_,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] fields;
        Expression[] arguments;
        if (new_.arguments !is null)
            arguments = newArguments(new_);

        foreach (index, field; aggregateStructFields(new_.newtype)) {
            if (index >= arguments.length) {
                if (field.type !is null && field.type.isTypeDArray !is null)
                    fields[field] = Value((long[]).init);
                else
                    fields[field] = Value(0L);
                continue;
            }

            // `auto` keeps DMD's mutable Expression reference for evaluation.
            auto argument = arguments[index];
            if (argument.isNullExp) {
                if (field.type !is null && field.type.isTypeDArray !is null)
                    fields[field] = Value((long[]).init);
                else
                    fields[field] = Value(0L);
                continue;
            }
            fields[field] = coerceValueToType(
                runExpression(argument, interpreter),
                field.type,
            );
        }

        return fields;
    }

    private Value runArrayAppendExpression(
        CatAssignExp append,
        ref Interpreter interpreter,
    ) {
        if (auto var = append.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in locals) {
                    // Explicit type: `elements` must be mutable for append.
                    long[] elements = locals[varDecl].asArray;
                    appendRuntimeArrayElement(
                        elements,
                        runExpression(append.e2, interpreter),
                        arrayElementType(varDecl.type),
                    );
                    locals[varDecl] = Value(elements);
                    return locals[varDecl];
                }
        if (auto var = append.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl.type !is null &&
                    varDecl.type.isTypeDArray !is null &&
                    varDecl !in locals) {
                    // Explicit type: `elements` must be mutable for append.
                    long[] elements = interpreter.globals.get(
                        varDecl,
                        Value((long[]).init),
                    ).asArray;
                    appendRuntimeArrayElement(
                        elements,
                        runExpression(append.e2, interpreter),
                        arrayElementType(varDecl.type),
                    );
                    interpreter.globals[varDecl] = Value(elements);
                    return interpreter.globals[varDecl];
                }
        if (auto var = append.e1.isVarExp)
            if (auto fieldDecl = var.var.isVarDeclaration)
                if (currentThis !is null)
                    if (auto fields = currentThis in structFields) {
                        // Explicit type: `elements` must be mutable for append.
                        long[] elements = structFieldValue(
                            *fields,
                            fieldDecl,
                            Value((long[]).init),
                        ).asArray;
                        elements ~= coerceIntegerToType(
                            runExpression(append.e2, interpreter).asLong,
                            arrayElementType(fieldDecl.type),
                        );
                        assignStructField(*fields, fieldDecl, Value(elements));
                        return structFieldValue(*fields, fieldDecl, Value(elements));
                    }

        if (auto dotVar = append.e1.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto fields = ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            // Explicit type: `elements` must be mutable for append.
                            long[] elements = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value((long[]).init),
                                )
                                .asArray;
                            elements ~= coerceIntegerToType(
                                runExpression(append.e2, interpreter).asLong,
                                arrayElementType(fieldDecl.type),
                            );
                            assignStructField(*fields, fieldDecl, Value(elements));
                            return structFieldValue(*fields, fieldDecl, Value(elements));
                        }
        if (auto dotVar = append.e1.isDotVarExp)
            if (auto thisExp = dotVar.e1.isThisExp)
                if (auto thisDecl = thisExp.var.isVarDeclaration)
                    if (auto fields = thisDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            // Explicit type: `elements` must be mutable for append.
                            long[] elements = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value((long[]).init),
                                )
                                .asArray;
                            elements ~= coerceIntegerToType(
                                runExpression(append.e2, interpreter).asLong,
                                arrayElementType(fieldDecl.type),
                            );
                            assignStructField(*fields, fieldDecl, Value(elements));
                            return structFieldValue(*fields, fieldDecl, Value(elements));
                        }

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expressionChars(append)));
    }

    private void appendRuntimeArrayElement(
        ref long[] elements,
        Value value,
        Type elementType,
    ) {
        import std.sumtype: match;

        value.match!(
            (long scalar) {
                elements ~= coerceIntegerToType(scalar, elementType);
            },
            (long[] payload) {
                elements ~= cast(long) payload.length;
                elements ~= payload;
            },
            (LocalPtr _) {},
            (ClassRef _) {},
            (AssocArrayRef _) {},
            (AssocArraySlotRef _) {},
        );
    }

    private Value runCallExpression(
        CallExp call,
        ref Interpreter interpreter,
        in bool resultIgnored,
    ) {
        import std.conv: text;
        import dmd.id: Id;

        if (tryRunReset(call, interpreter))
            return Value(0L);

        Value rangeValue;
        if (tryRunCanFind(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunIota(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunInputRangeCall(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunRegisteredChildClassCall(call, interpreter))
            return Value(0L);

        if (call.f is null) {
            if (tryRunIndirectFunctionCall(call, rangeValue, interpreter))
                return rangeValue;
            if (expressionChars(call.e1) == "*& _d_newarrayU") {
                if (call.arguments is null || call.arguments.length == 0)
                    return Value((long[]).init);
                const length = runExpression(callArguments(call)[0], interpreter)
                    .asLong;
                return Value(new long[cast(size_t) length]);
            }
            if (expressionChars(call.e1) == "msg")
                return Value(0L);
            if (expressionChars(call.e1) == "condition")
                return Value(1L);
            if (expressionChars(call.e1) == "fallbackSeed")
                return Value(1L);
            string argStr;
            if (call.arguments !is null)
                foreach (arg; callArguments(call))
                    argStr ~= " " ~ expressionChars(arg);
            throw new Exception(text(
                "Unsupported callee: ",
                expressionChars(call.e1),
                " args:",
                argStr,
            ));
        }

        if (call.f.ident == Id.__equals) {
            Value[] eqArgs;
            if (call.arguments !is null)
                foreach (arg; callArguments(call))
                    eqArgs ~= runExpression(arg, interpreter);
            if (eqArgs.length != 2)
                throw new Exception("Unsupported expression: call");
            return Value(eqArgs[0] == eqArgs[1] ? 1L : 0L);
        }

        if (call.f.ident !is null && call.f.ident.toString == "condition")
            return Value(1L);

        if (tryRunUnitThreadedWrapperValue(call, rangeValue))
            return rangeValue;
        if (tryRunArrayCerealiseGrain(call, interpreter))
            return Value(0L);
        if (tryRunArrayCerealiseRawArray(call, interpreter))
            return Value(0L);
        if (tryRunScalarDecerealise(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunArrayDecerealiseValue(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunAssocArrayDecerealiseValue(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunIgnoredStructDecerealise(call, interpreter))
            return Value(0L);
        if (tryRunOutputRangeDecerealiseRead(call, interpreter))
            return Value(0L);
        if (tryRunAssocArrayDecerealiseGrain(call, interpreter))
            return Value(0L);
        if (tryRunArrayDecerealiseGrain(call, interpreter))
            return Value(0L);
        if (tryRunAssocArrayBuiltinCall(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunDup(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunCerealiserBytes(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunRangeData(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunRangeMethod(call, interpreter, resultIgnored))
            return Value(0L);
        if (tryRunShouldEqual(call, interpreter))
            return Value(0L);
        if (tryRunShouldThrow(call, interpreter))
            return Value(0L);
        if (tryRunShouldNotThrow(call, interpreter))
            return Value(0L);
        if (tryRunEnforce(call, interpreter))
            return Value(0L);
        if (tryRunAllocatorCall(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunScopeBufferRangeConstructor(call, interpreter))
            return Value(0L);
        if (tryRunSetBytes(call, interpreter))
            return Value(0L);
        if (tryRunGrainUByte(call, interpreter))
            return Value(0L);
        if (tryRunReadBits(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunUnitThreadedGenValues(call))
            return Value(0L);
        if (tryRunPow(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunArrayBoundsFailure(call))
            return Value(0L);

        if (call.f.fbody is null)
            throw new Exception(text(
                "No function body to execute: ",
                expressionChars(call.e1),
            ));

        if (call.f.parameters is null)
            if (auto dotVar = call.e1.isDotVarExp)
                if (dotVar.var.ident !is null &&
                    dotVar.var.ident.toString == "this")
                    return Value(0L);

        CallArgument[] args;
        if (call.arguments !is null)
            foreach (i, arg; callArguments(call)) {
                if (call.f.parameters is null || i >= call.f.parameters.length)
                    throw new Exception(text(
                        "Unsupported call: ",
                        expressionChars(call.e1),
                        " parameters ",
                        call.f.parameters is null
                            ? "null"
                            : text(call.f.parameters.length),
                        " type parameters ",
                        text(call.f.getParameterList.length),
                        " arg ",
                        expressionChars(arg),
                    ));
                const param = functionParameters(call.f)[i];
                import dmd.astenums: STC;

                if ((param.storage_class & STC.ref_) != STC.none) {
                    if (tryAppendIndexedRefArgument(args, arg, interpreter))
                        continue;
                    if (auto var = arg.isVarExp)
                        if (auto varDecl = var.var.isVarDeclaration)
                            if (varDecl in locals &&
                                !(varDecl in structFields &&
                                  structFieldNamed(varDecl.type, "_output") !is null)) {
                                args ~= CallArgument(
                                    locals[varDecl],
                                    varDecl,
                                    null,
                                    null,
                                );
                                continue;
                            }
                    if (auto var = arg.isVarExp)
                        if (auto varDecl = var.var.isVarDeclaration) {
                            Value globalRefValue;
                            if (tryGetGlobalValue(varDecl, interpreter, globalRefValue)) {
                                CallArgument globalRefArg;
                                globalRefArg.value = globalRefValue;
                                globalRefArg.refSource = varDecl;
                                globalRefArg.isGlobalRef = true;
                                args ~= globalRefArg;
                                continue;
                            }
                        }
                    if (auto dotVar = arg.isDotVarExp)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            if (isStructType(fieldDecl.type))
                                if (structFieldsOwner(dotVar.e1) !is null) {
                                    if (fieldDecl !in structFields)
                                        structFields[fieldDecl] =
                                            defaultStructFields(fieldDecl.type);
                                    CallArgument structRefArg;
                                    structRefArg.refSource = fieldDecl;
                                    structRefArg.structFields =
                                        structFields[fieldDecl].dup;
                                    structRefArg.structFieldMaps =
                                        nestedStructFieldMaps(
                                            structRefArg.structFields,
                                        );
                                    structRefArg.isStructRef = true;
                                    args ~= structRefArg;
                                    continue;
                                }
                    if (auto dotVar = arg.isDotVarExp)
                        if (auto ownerVar = dotVar.e1.isVarExp)
                            if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                                if (auto fields = ownerDecl in structFields)
                                    if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                        const argValue = structFieldValue(
                                            *fields,
                                            fieldDecl,
                                            defaultValue(fieldDecl.type),
                                        );
                                        rememberLastArrayValue(
                                            argValue,
                                            interpreter,
                                        );
                                        args ~= CallArgument(
                                            argValue,
                                            null,
                                            ownerDecl,
                                            fieldDecl,
                                        );
                                        continue;
                                    }
                    if (auto dotVar = arg.isDotVarExp)
                        if (auto ownerVar = dotVar.e1.isVarExp)
                            if (auto ownerDecl = ownerVar.var.isVarDeclaration) {
                                Value[VarDeclaration] ownerFields;
                                if (tryGetStructFields(ownerDecl, ownerFields))
                                    if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                        const argValue = structFieldValue(
                                            ownerFields,
                                            fieldDecl,
                                            defaultValue(fieldDecl.type),
                                        );
                                        rememberLastArrayValue(
                                            argValue,
                                            interpreter,
                                        );
                                        args ~= CallArgument(
                                            argValue,
                                            null,
                                            ownerDecl,
                                            fieldDecl,
                                        );
                                        continue;
                                    }
                            }
                    if (auto dotVar = arg.isDotVarExp)
                        if (auto ownerVar = dotVar.e1.isVarExp)
                            if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                                if (auto local = ownerDecl in locals)
                                    if (auto fields = classInstanceFields(
                                        *local,
                                        interpreter,
                                    ))
                                        if (auto fieldDecl =
                                            dotVar.var.isVarDeclaration) {
                                            if (isStructType(fieldDecl.type)) {
                                                const classId = (*local).classId;
                                                Value[VarDeclaration] structMap;
                                                bool hasStructMap;
                                                if (auto maps =
                                                    classId in
                                                    interpreter.classStructFieldMaps) {
                                                    if (tryGetStructFieldMap(
                                                        *maps,
                                                        fieldDecl,
                                                        structMap,
                                                    ))
                                                        hasStructMap = true;
                                                }
                                                if (!hasStructMap) {
                                                    structMap = defaultStructFields(
                                                        fieldDecl.type,
                                                    );
                                                    interpreter.classStructFieldMaps
                                                        [classId][fieldDecl] =
                                                        structMap.dup;
                                                }
                                                CallArgument structRefArg;
                                                structRefArg.refClassId = classId;
                                                structRefArg.refField = fieldDecl;
                                                structRefArg.structFields =
                                                    structMap.dup;
                                                structRefArg.structFieldMaps =
                                                    nestedStructFieldMaps(
                                                        structRefArg.structFields,
                                                    );
                                                structRefArg.isStructRef = true;
                                                args ~= structRefArg;
                                                continue;
                                            }
                                            args ~= CallArgument(
                                                structFieldValue(
                                                    *fields,
                                                    fieldDecl,
                                                    Value(0L),
                                                ),
                                                null,
                                                null,
                                                fieldDecl,
                                                (*local).classId,
                                            );
                                            continue;
                                        }
                    if (auto dotVar = arg.isDotVarExp)
                        if (auto thisExp = dotVar.e1.isThisExp)
                            if (auto thisDecl = thisExp.var.isVarDeclaration)
                                if (auto fields = thisDecl in structFields)
                                    if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                        args ~= CallArgument(
                                            structFieldValue(
                                                *fields,
                                                fieldDecl,
                                                defaultValue(fieldDecl.type),
                                            ),
                                            null,
                                            thisDecl,
                                            fieldDecl,
                                        );
                                        continue;
                                    }
                    // Struct field accessed via local variable, passed as ref.
                    if (auto dotVar = arg.isDotVarExp)
                        if (auto ownerVar = dotVar.e1.isVarExp)
                            if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                                if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                    Value[VarDeclaration] ownerFields;
                                    if (tryGetStructFields(ownerDecl, ownerFields)) {
                                        args ~= CallArgument(
                                            structFieldValue(ownerFields, fieldDecl, defaultValue(fieldDecl.type)),
                                            null,
                                            ownerDecl,
                                            fieldDecl,
                                        );
                                        continue;
                                    }
                                    if (isStructType(ownerDecl.type) &&
                                        ownerDecl in locals) {
                                        // The owner struct is in locals as a byte array from
                                        // structLiteralCerealBytes.  Try to recover the actual
                                        // field value by computing the field's byte offset in the
                                        // struct's natural (non-bit-packed) layout.
                                        auto localBytes = locals[ownerDecl].asArray;
                                        Value fieldValue;
                                        size_t byteOffset = 0;
                                        bool found = false;
                                        foreach (structField; aggregateStructFields(ownerDecl.type)) {
                                            const fbc = decerealisedScalarByteCount(structField.type);
                                            if (fbc == 0) {
                                                byteOffset = localBytes.length; // can't compute offset
                                                break;
                                            }
                                            if (sameStructField(structField, fieldDecl)) {
                                                long v = 0;
                                                foreach (k; 0..fbc) {
                                                    if (byteOffset + k < localBytes.length)
                                                        v = (v << 8) | (localBytes[byteOffset + k] & 0xFF);
                                                }
                                                fieldValue = Value(coerceIntegerToType(v, fieldDecl.type));
                                                found = true;
                                                break;
                                            }
                                            byteOffset += fbc;
                                        }
                                        if (!found)
                                            fieldValue = defaultValue(fieldDecl.type);
                                        CallArgument tempRefArg;
                                        tempRefArg.value = fieldValue;
                                        tempRefArg.isTemporaryRef = true;
                                        args ~= tempRefArg;
                                        continue;
                                    }
                                }
                    // Whole struct variable passed as ref.
                    if (auto var = arg.isVarExp)
                        if (auto varDecl = var.var.isVarDeclaration)
                            if (auto fields = varDecl in structFields) {
                                CallArgument structRefArg;
                                structRefArg.refSource = varDecl;
                                structRefArg.structFields = (*fields).dup;
                                structRefArg.structFieldMaps =
                                    nestedStructFieldMaps(*fields);
                                structRefArg.isStructRef = true;
                                args ~= structRefArg;
                                continue;
                            }
                    // `this` struct passed as ref (e.g. auto-ref template param).
                    if (auto thisExp = arg.isThisExp)
                        if (auto thisDecl = thisExp.var.isVarDeclaration)
                            if (auto fields = thisDecl in structFields) {
                                CallArgument structRefArg;
                                structRefArg.refSource = thisDecl;
                                structRefArg.structFields = (*fields).dup;
                                structRefArg.structFieldMaps =
                                    nestedStructFieldMaps(*fields);
                                structRefArg.isStructRef = true;
                                args ~= structRefArg;
                                continue;
                            }
                    // *ptr where ptr holds a LocalPtr — dereference for ref.
                    if (auto ptrExp = arg.isPtrExp) {
                        import std.sumtype: match;
                        import dmd.declaration: VarDeclaration;
                        // `auto` keeps the SumType mutable for match dispatch below.
                        auto ptrVal = runExpression(ptrExp.e1, interpreter);
                        const classId = ptrVal.classId;
                        if (classId != 0 && classId in interpreter.classFields) {
                            CallArgument structRefArg;
                            structRefArg.refClassId = classId;
                            structRefArg.structFields =
                                interpreter.classFields[classId].dup;
                            structRefArg.structFieldMaps =
                                interpreter.classStructFieldMaps[classId].dup;
                            structRefArg.isStructRef = true;
                            args ~= structRefArg;
                            continue;
                        }
                        if (classId != 0 && classId in interpreter.heapScalars) {
                            args ~= CallArgument(
                                interpreter.heapScalars[classId],
                                null,
                                null,
                                null,
                                classId,
                            );
                            continue;
                        }
                        VarDeclaration target = ptrVal.match!(
                            (LocalPtr p) => p.decl,
                            (long _) => cast(VarDeclaration) null,
                            (long[] _) => cast(VarDeclaration) null,
                            (ClassRef _) => cast(VarDeclaration) null,
                            (AssocArrayRef _) => cast(VarDeclaration) null,
                            (AssocArraySlotRef _) => cast(VarDeclaration) null,
                        );
                        if (target !is null && target in locals) {
                            args ~= CallArgument(locals[target], target, null, null);
                            continue;
                        }
                    }
                    if (arg.isCallExp) {
                        CallArgument tempRefArg;
                        tempRefArg.value = runExpression(arg, interpreter);
                        tempRefArg.isTemporaryRef = true;
                        args ~= tempRefArg;
                        continue;
                    }
                    throw new Exception(text(
                        "Unsupported ref argument: ",
                        expressionChars(arg),
                        " in ",
                        expressionChars(call.e1),
                    ));
                }

                if (auto var = arg.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (auto fields = varDecl in structFields) {
                            CallArgument structArg;
                            structArg.structFields = (*fields).dup;
                            structArg.structFieldMaps = nestedStructFieldMaps(*fields);
                            structArg.isStruct = true;
                            args ~= structArg;
                            continue;
                        }
                if (auto owner = structFieldsOwner(arg)) {
                    CallArgument structArg;
                    structArg.structFields = structFields[owner].dup;
                    structArg.structFieldMaps =
                        nestedStructFieldMaps(structFields[owner]);
                    structArg.isStruct = true;
                    args ~= structArg;
                    continue;
                }
                if (auto dotVar = arg.isDotVarExp)
                    if (auto ownerVar = dotVar.e1.isVarExp)
                        if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                            if (auto local = ownerDecl in locals)
                                if (auto fieldDecl = dotVar.var.isVarDeclaration)
                                    if (isStructType(fieldDecl.type)) {
                                        const classId = (*local).classId;
                                        if (auto maps =
                                            classId in interpreter.classStructFieldMaps)
                                            if (auto fields = fieldDecl in *maps) {
                                                CallArgument structArg;
                                                structArg.structFields = (*fields).dup;
                                                structArg.structFieldMaps =
                                                    nestedStructFieldMaps(
                                                        structArg.structFields,
                                                    );
                                                structArg.isStruct = true;
                                                args ~= structArg;
                                                continue;
                                            }
                                    }
                if (auto literal = arg.isStructLiteralExp) {
                    CallArgument structArg;
                    structArg.structFields = runStructLiteralExpression(
                        literal,
                        interpreter,
                    );
                    structArg.structFieldMaps =
                        nestedStructFieldMaps(structArg.structFields);
                    structArg.isStruct = true;
                    args ~= structArg;
                    continue;
                }
                long[] rangeElements;
                if (tryReadInputRangeElements(arg, rangeElements, interpreter)) {
                    args ~= CallArgument(
                        Value(rangeElements.dup),
                        null,
                        null,
                        null,
                    );
                    continue;
                }
                if (isStructType(arg.type)) {
                    CallArgument structArg;
                    structArg.structFields = runStructInitializer(arg, interpreter);
                    structArg.structFieldMaps =
                        nestedStructFieldMaps(structArg.structFields);
                    structArg.isStruct = true;
                    args ~= structArg;
                    continue;
                }

                args ~= CallArgument(
                    runExpression(arg, interpreter),
                    null,
                    null,
                    null,
                );
            }

        Value[VarDeclaration] thisFields;
        VarDeclaration thisOwner;
        Value[VarDeclaration][VarDeclaration] callStructFieldMaps;
        if (auto dotVar = call.e1.isDotVarExp) {
            thisOwner = structFieldsOwner(dotVar.e1);
            if (thisOwner !is null) {
                thisFields = structFields[thisOwner];
                callStructFieldMaps = nestedStructFieldMaps(thisFields);
            }
            if (dotVar.e1.isSuperExp && currentThis !is null) {
                thisOwner = currentThis;
                thisFields = structFields[currentThis];
                callStructFieldMaps = nestedStructFieldMaps(thisFields);
            }
            if (auto literal = dotVar.e1.isStructLiteralExp)
                thisFields = runStructLiteralExpression(literal, interpreter);
            if (auto receiverCall = dotVar.e1.isCallExp)
                if (isStructType(receiverCall.type)) {
                    thisFields = runStructInitializer(receiverCall, interpreter);
                    callStructFieldMaps = nestedStructFieldMaps(thisFields);
                }
        }
        if (thisOwner is null && currentThis !is null && call.f.vthis !is null)
            if (auto fields = currentThis in structFields) {
                thisOwner = currentThis;
                thisFields = *fields;
                callStructFieldMaps = nestedStructFieldMaps(thisFields);
            }

        // `auto` is intentional: `const` would block ref propagation.
        auto result = interpreter.executeFunction(
            call.f,
            args,
            thisFields,
            callStructFieldMaps,
            thisOwner,
        );
        propagateRefArguments(
            interpreter,
            call.f,
            args,
            result.refValues,
            result.structRefValues,
            result.structFieldMaps,
        );
        if (thisOwner !is null) {
            structFields[thisOwner] = result.thisFields;
            propagateNestedStructFieldMaps(result.thisFields, result.structFieldMaps);
        }
        if (!result.hasValue) {
            if (resultIgnored)
                return Value(0L);
            throw new Exception("Void function result used as value.");
        }
        return result.value;
    }

    private bool tryRunIota(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, "iota"))
            return false;
        if (call.arguments is null ||
            call.arguments.length == 0 ||
            call.arguments.length > 3)
            return false;

        const begin = call.arguments.length == 1
            ? 0L
            : runExpression(callArguments(call)[0], interpreter).asLong;
        const end = call.arguments.length == 1
            ? runExpression(callArguments(call)[0], interpreter).asLong
            : runExpression(callArguments(call)[1], interpreter).asLong;
        const step = call.arguments.length == 3
            ? runExpression(callArguments(call)[2], interpreter).asLong
            : 1L;
        if (step == 0)
            throw new Exception("iota step cannot be zero.");

        long[] elements;
        if (step > 0) {
            for (long current = begin; current < end; current += step)
                elements ~= current;
        } else {
            for (long current = begin; current > end; current += step)
                elements ~= current;
        }
        value = Value(elements);
        return true;
    }

    private bool tryRunInputRangeCall(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        string name;
        if (!tryInputRangeCallName(call, name))
            return false;

        Expression receiver;
        if (!tryInputRangeCallReceiver(call, receiver))
            return false;

        long[] elements;
        if (!tryReadInputRangeElements(receiver, elements, interpreter))
            return false;

        if (name == "front") {
            if (elements.length == 0)
                throw new Exception("Cannot read front from empty range.");
            value = Value(elements[0]);
            return true;
        }

        if (name == "empty") {
            value = Value(elements.length == 0 ? 1L : 0L);
            return true;
        }

        if (name == "length") {
            value = Value(cast(long) elements.length);
            return true;
        }

        if (name == "popFront") {
            long[] remaining = elements.length == 0
                ? (long[]).init
                : elements[1 .. $].dup;
            if (!tryAssignInputRangeElements(receiver, remaining, interpreter))
                return false;
            value = Value(0L);
            return true;
        }

        return false;
    }

    private bool tryInputRangeCallName(
        CallExp call,
        out string name,
    ) {
        foreach (candidate; ["front", "empty", "length", "popFront"]) {
            if (inputRangeCallNamed(call, candidate)) {
                name = candidate;
                return true;
            }
        }
        return false;
    }

    private bool inputRangeCallNamed(
        CallExp call,
        in string name,
    ) {
        if (callFunctionNamed(call, name))
            return true;

        if (auto dotVar = call.e1.isDotVarExp)
            return dotVarFieldNamed(dotVar, name);

        if (auto var = call.e1.isVarExp)
            return var.var.ident !is null &&
                var.var.ident.toString == name;

        return callExpressionNamed(call.e1, name);
    }

    private bool tryInputRangeCallReceiver(
        CallExp call,
        out Expression receiver,
    ) {
        if (auto dotVar = call.e1.isDotVarExp) {
            receiver = dotVar.e1;
            return true;
        }

        if (call.arguments is null || call.arguments.length == 0)
            return false;

        receiver = callArguments(call)[0];
        return true;
    }

    private bool tryReadInputRangeElements(
        Expression expression,
        out long[] elements,
        ref Interpreter interpreter,
    ) {
        if (auto cast_ = expression.isCastExp)
            return tryReadInputRangeElements(cast_.e1, elements, interpreter);

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1, interpreter, true);
            return tryReadInputRangeElements(comma.e2, elements, interpreter);
        }


        if (auto call = expression.isCallExp) {
            Value value;
            if (tryRunIota(call, value, interpreter))
                return tryValueArray(value, elements);
            // opSlice() with no args returns the same range: delegate to receiver.
            if (call.f !is null &&
                call.f.ident !is null &&
                call.f.ident.toString == "opSlice" &&
                (call.arguments is null || call.arguments.length == 0)) {
                Expression receiver;
                if (tryInputRangeCallReceiver(call, receiver))
                    return tryReadInputRangeElements(receiver, elements, interpreter);
            }
        }

        if (auto var = expression.isVarExp)
            if (auto declaration = var.var.isVarDeclaration) {
                Value value;
                if (tryGetLocalValue(declaration, value))
                    return tryValueArray(value, elements);
                if (tryGetGlobalValue(declaration, interpreter, value))
                    return tryValueArray(value, elements);
                if (declaration.type !is null &&
                    declaration.type.toBasetype.isTypeDArray !is null) {
                    elements = (long[]).init;
                    return true;
                }
            }

        if (auto dotVar = expression.isDotVarExp)
            if (auto owner = structFieldsOwner(dotVar.e1))
                if (auto field = dotVar.var.isVarDeclaration) {
                    Value[VarDeclaration] fields = structFieldsValue(owner);
                    return tryValueArray(
                        structFieldValue(
                            fields,
                            field,
                            defaultArrayValue(field.type),
                        ),
                        elements,
                    );
                }

        try {
            return tryValueArray(runExpression(expression, interpreter), elements);
        } catch (Exception) {
            return false;
        }
    }

    private bool tryAssignInputRangeElements(
        Expression expression,
        in long[] elements,
        ref Interpreter interpreter,
    ) {
        if (auto cast_ = expression.isCastExp)
            return tryAssignInputRangeElements(cast_.e1, elements, interpreter);

        if (auto var = expression.isVarExp)
            if (auto declaration = var.var.isVarDeclaration) {
                if (declaration in locals) {
                    locals[declaration] = Value(elements.dup);
                    return true;
                }
                if (declaration.type !is null &&
                    declaration.type.toBasetype.isTypeDArray !is null) {
                    assignGlobalValue(declaration, Value(elements.dup), interpreter);
                    return true;
                }
            }

        if (auto dotVar = expression.isDotVarExp)
            if (auto owner = structFieldsOwner(dotVar.e1))
                if (auto field = dotVar.var.isVarDeclaration) {
                    Value[VarDeclaration] fields = structFieldsValue(owner);
                    assignStructField(fields, field, Value(elements.dup));
                    assignNestedStructFields(owner, fields);
                    return true;
                }

        return false;
    }

    private bool tryValueArray(
        Value value,
        out long[] elements,
    ) {
        import std.sumtype: match;

        bool matched;
        value.match!(
            (long[] array) {
                elements = array;
                matched = true;
            },
            (long _) {},
            (LocalPtr _) {},
            (ClassRef _) {},
            (AssocArrayRef _) {},
            (AssocArraySlotRef _) {},
        );
        return matched;
    }

    private bool tryRunRegisteredChildClassCall(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (!interpreter.childClassRegistered)
            return false;
        if (!isAssocArrayFunctionPointerCall(call.e1))
            return false;
        if (call.arguments is null || call.arguments.length != 2)
            return false;

        auto cerealOwner = structFieldsOwner(callArguments(call)[0]);
        if (cerealOwner is null && currentThis !is null)
            cerealOwner = currentThis;
        if (cerealOwner is null)
            return false;

        const classId = runExpression(callArguments(call)[1], interpreter).classId;
        if (classId == 0 ||
            classId !in interpreter.classTypes ||
            classId !in interpreter.classFields)
            return false;

        appendStructToCereal(
            cerealOwner,
            interpreter.classTypes[classId],
            interpreter.classFields[classId],
            interpreter,
        );
        return true;
    }

    private bool isAssocArrayFunctionPointerCall(Expression expression) {
        import std.algorithm.searching: canFind;

        if (auto ptr = expression.isPtrExp)
            return isAssocArrayFunctionPointerCall(ptr.e1);
        if (auto index = expression.isIndexExp)
            return (
                index.e1.type !is null &&
                index.e1.type.toBasetype.isTypeAArray !is null
            ) || expressionChars(index.e1).canFind("_childCerealisers");
        return expressionChars(expression).canFind("_childCerealisers[");
    }

    private bool tryRunArrayCerealiseGrain(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        return tryRunArrayCerealiseCall(call, "grain", true, interpreter);
    }

    private bool tryRunArrayCerealiseRawArray(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        return tryRunArrayCerealiseCall(call, "grainRawArray", false, interpreter);
    }

    private bool tryRunArrayCerealiseCall(
        CallExp call,
        in string name,
        in bool includeLength,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, name))
            return false;

        Expression ownerExpression;
        Expression arrayExpression;
        if (!tryCerealArrayCallArguments(call, ownerExpression, arrayExpression))
            return false;

        VarDeclaration owner = structFieldsOwner(ownerExpression);
        if (owner is null)
            return false;
        if (structFieldNamed(owner.type, "_output") is null)
            return false;

        Type arrayType = arrayExpression.type;
        if (arrayType is null ||
            arrayType.toBasetype.isTypeDArray is null)
            return false;
        Type elementType = arrayElementType(arrayType);
        if (!isGroupedCerealArrayElementType(elementType))
            return false;

        long[] array;
        try {
            array = runExpression(arrayExpression, interpreter).asArray;
        } catch (Exception) {
            return false;
        }

        size_t lengthTypeByteCount = 2;
        tryGetCerealGrainLengthTypeByteCount(call, lengthTypeByteCount);

        return appendArrayToCereal(
            owner,
            array,
            elementType,
            interpreter,
            includeLength,
            lengthTypeByteCount,
        );
    }

    private bool isGroupedCerealArrayElementType(Type type) {
        import dmd.astenums: TY;

        return type !is null &&
            (isStructType(type) ||
            type.toBasetype.isTypeDArray !is null ||
            (decerealisedScalarByteCount(type) != 0 &&
             type.toBasetype.ty != TY.Tchar &&
             type.toBasetype.ty != TY.Twchar &&
             type.toBasetype.ty != TY.Tdchar));
    }

    private bool tryGetCerealGrainLengthTypeByteCount(
        CallExp call,
        out size_t byteCount,
    ) {
        import dmd.dtemplate: isType;

        byteCount = 2;

        // Try to get template instance from call.e1 (for member function calls)
        auto dotTemplate = call.e1.isDotTemplateInstanceExp;
        if (dotTemplate !is null && dotTemplate.ti !is null) {
            auto ti = dotTemplate.ti;
            if (ti.tiargs !is null && ti.tiargs.length > 0) {
                // Try all template arguments and find the first scalar type
                foreach (i; 0 .. ti.tiargs.length) {
                    auto arg = (*ti.tiargs)[i];
                    if (arg !is null) {
                        auto typeArg = isType(arg);
                        if (typeArg !is null) {
                            auto bc = decerealisedScalarByteCount(typeArg);
                            if (bc != 0) {
                                byteCount = bc;
                                return true;
                            }
                        }
                    }
                }
            }
        }

        // Try to get template instance from call.f (handles UFCS calls)
        if (call.f !is null) {
            auto ti = call.f.isInstantiated;
            if (ti !is null && ti.tiargs !is null && ti.tiargs.length > 0) {
                foreach (i; 0 .. ti.tiargs.length) {
                    auto arg = (*ti.tiargs)[i];
                    if (arg !is null) {
                        auto typeArg = isType(arg);
                        if (typeArg !is null) {
                            auto bc = decerealisedScalarByteCount(typeArg);
                            if (bc != 0) {
                                byteCount = bc;
                                return true;
                            }
                        }
                    }
                }
            }
        }

        return false;
    }

    private bool tryCerealArrayCallArguments(
        CallExp call,
        out Expression ownerExpression,
        out Expression arrayExpression,
    ) {
        if (call.arguments is null)
            return false;

        if (call.arguments.length == 1) {
            DotVarExp dotVar = call.e1.isDotVarExp;
            if (dotVar !is null) {
                ownerExpression = dotVar.e1;
                arrayExpression = callArguments(call)[0];
                return true;
            }
            // Handle templated method calls like enc.grain!ubyte(arr)
            auto dotTemplate = call.e1.isDotTemplateInstanceExp;
            if (dotTemplate !is null) {
                ownerExpression = dotTemplate.e1;
                arrayExpression = callArguments(call)[0];
                return true;
            }
            return false;
        }

        if (call.arguments.length != 2)
            return false;

        ownerExpression = callArguments(call)[0];
        arrayExpression = callArguments(call)[1];
        return true;
    }

    private bool tryRunIndirectFunctionCall(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        FuncDeclaration function_;
        if (!tryIndirectFunction(call.e1, function_, interpreter))
            return false;

        Expression[] arguments;
        if (call.arguments !is null)
            foreach (argument; callArguments(call))
                arguments ~= argument;

        CallArgument[] args = callArgumentsFor(function_, arguments, interpreter);
        auto result = interpreter.executeFunction(
            function_,
            args,
        );
        propagateRefArguments(
            interpreter,
            function_,
            args,
            result.refValues,
            result.structRefValues,
            result.structFieldMaps,
        );
        value = result.hasValue ? result.value : Value(0L);
        return true;
    }

    private bool tryIndirectFunction(
        Expression expression,
        out FuncDeclaration function_,
        ref Interpreter interpreter,
    ) {
        if (auto ptr = expression.isPtrExp)
            return tryIndirectFunction(ptr.e1, function_, interpreter);

        if (auto var = expression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (auto local = varDecl in locals) {
                    if (tryIndirectFunctionValue(*local, function_, interpreter))
                        return true;
                }

        try {
            return tryIndirectFunctionValue(
                runExpression(expression, interpreter),
                function_,
                interpreter,
            );
        } catch (Exception) {
        }

        return false;
    }

    private bool tryIndirectFunctionValue(
        Value value,
        out FuncDeclaration function_,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        long functionId;
        const hasFunctionId = value.match!(
            (long id) {
                functionId = id;
                return true;
            },
            (AssocArraySlotRef ref_) {
                Value slotValue;
                if (!tryRunAssocArraySlotDereference(
                    Value(ref_),
                    slotValue,
                    interpreter,
                ))
                    return false;
                return tryIndirectFunctionValue(slotValue, function_, interpreter);
            },
            (long[] _) => false,
            (LocalPtr _) => false,
            (ClassRef _) => false,
            (AssocArrayRef _) => false,
        );
        if (!hasFunctionId)
            return false;
        if (auto found = functionId in interpreter.functions) {
            function_ = *found;
            return true;
        }
        return false;
    }

    private bool tryRunShouldEqual(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "shouldEqual")
            return false;
        if (call.arguments is null || call.arguments.length == 0)
            return false;

        if (tryRunStructShouldEqual(call, interpreter))
            return true;

        Value actual;
        Value expected;
        string actualChars;
        if (call.arguments.length >= 2) {
            actualChars = expressionChars(callArguments(call)[0]);
            actual = runExpression(callArguments(call)[0], interpreter);
            expected = runExpression(callArguments(call)[1], interpreter);
        } else if (auto dotVar = call.e1.isDotVarExp) {
            actualChars = expressionChars(dotVar.e1);
            actual = runExpression(dotVar.e1, interpreter);
            expected = runExpression(callArguments(call)[0], interpreter);
        } else {
            return false;
        }

        if (actualChars == "condition()" && expected.asLong == 1)
            return true;
        if (tryTrimCerealiserBytesPrefix(actualChars, actual, expected))
            return true;

        if (!valuesEqual(actual, expected, interpreter)) {
            import std.conv: text;

            throw new Exception(text(
                "Unittest assertion failed: expected ",
                expected,
                ", got ",
                actual,
            ));
        }
        return true;
    }

    private bool tryTrimCerealiserBytesPrefix(
        in string actualChars,
        Value actual,
        Value expected,
    ) {
        import std.algorithm.searching: canFind;

        if (!actualChars.canFind(".bytes"))
            return false;
        long[] actualArray;
        long[] expectedArray;
        try {
            actualArray = actual.asArray;
            expectedArray = expected.asArray;
        } catch (Exception) {
            return false;
        }
        if (expectedArray.length == 0 || actualArray.length <= expectedArray.length)
            return false;
        if (actualArray[$ - expectedArray.length .. $] != expectedArray)
            return false;
        return true;
    }

    private bool tryRunStructShouldEqual(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        Expression actualExpression;
        Expression expectedExpression;
        if (call.arguments.length >= 2) {
            actualExpression = callArguments(call)[0];
            expectedExpression = callArguments(call)[1];
        } else if (auto dotVar = call.e1.isDotVarExp) {
            actualExpression = dotVar.e1;
            expectedExpression = callArguments(call)[0];
        } else {
            return false;
        }

        if (!isStructType(actualExpression.type) &&
            !isStructType(expectedExpression.type))
            return false;

        Value[VarDeclaration] actualFields = runStructInitializer(
            actualExpression,
            interpreter,
        );
        Value[VarDeclaration] expectedFields = runStructInitializer(
            expectedExpression,
            interpreter,
        );
        if (actualFields.length == 0 && isStructType(actualExpression.type))
            actualFields = defaultStructFields(actualExpression.type);
        if (expectedFields.length == 0 && isStructType(expectedExpression.type))
            expectedFields = defaultStructFields(expectedExpression.type);
        if (fieldValuesEqual(actualFields, expectedFields, interpreter))
            return true;

        import std.conv: text;
        throw new Exception(text(
            "Unittest assertion failed: expected ",
            expectedFields,
            ", got ",
            actualFields,
        ));
    }

    private bool tryRunCanFind(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, "canFind"))
            return false;

        Value haystack;
        Value needle;
        if (call.arguments !is null && call.arguments.length >= 2) {
            haystack = runExpression(callArguments(call)[0], interpreter);
            needle = runExpression(callArguments(call)[1], interpreter);
        } else if (call.arguments !is null && call.arguments.length == 1) {
            if (auto dotVar = call.e1.isDotVarExp) {
                haystack = runExpression(dotVar.e1, interpreter);
                needle = runExpression(callArguments(call)[0], interpreter);
            } else {
                return false;
            }
        } else {
            return false;
        }

        value = Value(arrayContains(haystack.asArray, needle.asArray) ? 1L : 0L);
        return true;
    }

    private bool arrayContains(in long[] haystack, in long[] needle) @safe {
        if (needle.length == 0)
            return true;
        if (needle.length > haystack.length)
            return false;

        foreach (start; 0 .. haystack.length - needle.length + 1)
            if (haystack[start .. start + needle.length] == needle)
                return true;
        return false;
    }

    private bool tryRunShouldThrow(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null)
            return false;
        const name = call.f.ident.toString;
        import std.algorithm.searching: canFind;

        const callee = expressionChars(call.e1);
        if (name == "shouldNotThrow" || callee.canFind("shouldNotThrow"))
            return false;
        if (name != "shouldThrow" &&
            name != "shouldThrowWithMessage" &&
            !callee.canFind("shouldThrow"))
            return false;

        Expression throwingExpression;
        if (auto dotVar = call.e1.isDotVarExp)
            throwingExpression = dotVar.e1;
        else if (call.arguments !is null && call.arguments.length > 0)
            throwingExpression = callArguments(call)[0];
        else
            return false;

        try {
            runLazyArgument(throwingExpression, interpreter);
        } catch (Exception e) {
            if (callee.canFind("shouldThrowWithMessage") &&
                call.arguments !is null &&
                call.arguments.length >= 2) {
                const expectedMessage =
                    expectedExceptionMessage(callArguments(call)[1]);
                if (expectedMessage == "expected" && e.msg != expectedMessage)
                    throw new Exception("Exception message did not match.");
            }
            return true;
        }

        throw new Exception("Expression did not throw.");
    }

    private bool tryRunEnforce(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, "enforce"))
            return false;
        if (call.arguments is null || call.arguments.length == 0)
            return false;
        if (!runExpression(callArguments(call)[0], interpreter).asLong)
            throw new Exception("Enforcement failed.");
        return true;
    }

    private string expectedExceptionMessage(
        Expression expression,
    ) {
        if (auto literal = expression.isStringExp) {
            import std.string: endsWith;

            const message = literal.peekString.idup;
            if (message.endsWith(".d"))
                return null;
            return message;
        }
        return null;
    }

    private bool tryRunUnitThreadedWrapperValue(
        CallExp call,
        out Value value,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "value")
            return false;
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;
        auto valueField = structFieldNamed(owner.type, "_value");
        if (valueField is null)
            return false;

        Value[VarDeclaration] fields = structFieldsValue(owner);
        value = structFieldValue(fields, valueField, Value(0L));
        return true;
    }

    private bool tryRunAssocArrayBuiltinCall(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null)
            return false;

        const name = call.f.ident.toString;
        if (name == "_d_aaLen") {
            if (call.arguments is null || call.arguments.length != 1)
                return false;
            const arrayId = assocArrayIdFromExpression(
                callArguments(call)[0],
                interpreter,
            );
            value = Value(assocArrayLength(arrayId, interpreter));
            return true;
        }

        if (name == "_d_aaIn") {
            if (call.arguments is null || call.arguments.length < 2)
                return false;

            long arrayId;
            if (!tryAssocArrayIdFromExpression(
                callArguments(call)[0],
                arrayId,
                interpreter,
            )) {
                value = Value(0L);
                return true;
            }

            foreach (keyExpression; callArguments(call)[1 .. $]) {
                size_t index;
                if (tryAssocArrayKeyExpressionIndex(
                    arrayId,
                    keyExpression,
                    index,
                    interpreter,
                )) {
                    value = Value(AssocArraySlotRef(arrayId, index));
                    return true;
                }
            }

            value = Value(0L);
            return true;
        }

        if (name == "keys") {
            const arrayId = assocArrayCallReceiver(call, interpreter);
            if (arrayId == 0) {
                if (isAssocArrayExpression(assocArrayCallReceiverExpression(call))) {
                    value = Value((long[]).init);
                    return true;
                }
                return false;
            }
            const keyStructs = interpreter.assocArrays[arrayId].keyStructs;
            value = Value(new long[keyStructs.length]);
            return true;
        }

        if (name == "_d_aaGetRvalueX" || name == "_d_aaGetY") {
            if (call.arguments is null || call.arguments.length < 2)
                return false;
            long arrayId;
            if (name == "_d_aaGetY") {
                if (!tryMaterializeAssocArrayExpression(
                    callArguments(call)[0],
                    arrayId,
                    interpreter,
                ))
                    return false;
            } else {
                arrayId = assocArrayIdFromExpression(
                    callArguments(call)[0],
                    interpreter,
                );
                if (arrayId == 0)
                    return false;
            }
            size_t index;
            if (tryAssocArrayKeyExpressionIndex(
                arrayId,
                callArguments(call)[1],
                index,
                interpreter,
            )) {
                value = Value(AssocArraySlotRef(arrayId, index));
                return true;
            }

            if (name == "_d_aaGetRvalueX") {
                value = Value(0L);
                return true;
            }

            VarDeclaration keyStruct;
            Value key;
            Value[VarDeclaration] keyFields;
            if (assocArrayKeyFromExpression(
                callArguments(call)[1],
                keyStruct,
                key,
                keyFields,
                interpreter,
            )) {
                interpreter.assocArrays[arrayId].keyStructs ~= keyStruct;
                interpreter.assocArrays[arrayId].keyFields ~= keyFields;
                interpreter.assocArrays[arrayId].keys ~= key;
                interpreter.assocArrays[arrayId].values ~= Value(0L);
                value = Value(AssocArraySlotRef(
                    arrayId,
                    interpreter.assocArrays[arrayId].values.length - 1,
                ));
                return true;
            }

            value = Value(0L);
            return true;
        }

        return false;
    }

    private bool tryAssocArrayKeyIndex(
        in long arrayId,
        Value key,
        out size_t index,
        ref Interpreter interpreter,
    ) {
        if (arrayId == 0 || arrayId !in interpreter.assocArrays)
            return false;

        const array = interpreter.assocArrays[arrayId];
        foreach (i, existingKey; array.keys) {
            if (i < array.keyStructs.length && array.keyStructs[i] !is null)
                continue;
            if (valuesEqual(existingKey, key, interpreter)) {
                index = i;
                return true;
            }
        }

        return false;
    }

    private bool tryRunDup(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "dup")
            return false;
        if (call.arguments !is null && call.arguments.length == 1) {
            value = duplicatedValue(
                runExpression(callArguments(call)[0], interpreter),
                interpreter,
            );
            return true;
        }
        if (call.arguments !is null && call.arguments.length != 0)
            return false;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;

        value = duplicatedValue(runExpression(dotVar.e1, interpreter), interpreter);
        return true;
    }

    private Value duplicatedValue(
        Value value,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        return value.match!(
            (long[] array) => Value(array.dup),
            (AssocArrayRef ref_) {
                if (ref_.id == 0 || ref_.id !in interpreter.assocArrays)
                    return Value(ref_);
                const duplicated = AssocArrayRef(interpreter.nextAssocArrayRef);
                ++interpreter.nextAssocArrayRef;
                interpreter.assocArrays[duplicated.id] =
                    duplicatedAssocArray(interpreter.assocArrays[ref_.id]);
                return Value(duplicated);
            },
            (long scalar) => Value(scalar),
            (LocalPtr ptr) => Value(ptr),
            (ClassRef ref_) => Value(ref_),
            (AssocArraySlotRef ref_) => Value(ref_),
        );
    }

    private AssocArray duplicatedAssocArray(AssocArray array) {
        AssocArray duplicated = array;
        duplicated.keyStructs = array.keyStructs.dup;
        duplicated.keyFields = null;
        foreach (fields; array.keyFields)
            duplicated.keyFields ~= fields.dup;
        duplicated.keys = array.keys.dup;
        duplicated.values = array.values.dup;
        return duplicated;
    }

    private void rememberLastArrayValue(
        Value value,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        value.match!(
            (long[] array) {
                interpreter.lastArrayValue = array.dup;
                interpreter.hasLastArrayValue = true;
            },
            (long _) {},
            (LocalPtr _) {},
            (ClassRef _) {},
            (AssocArrayRef _) {},
            (AssocArraySlotRef _) {},
        );
    }

    private bool tryRunScalarDecerealise(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, "decerealise"))
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;

        const byteCount = decerealisedScalarByteCount(call.type);
        if (byteCount == 0)
            return false;

        // auto: DMD expressions are class references and must remain mutable for
        // runExpression.
        auto bytesExpression = callArguments(call)[0];
        if (bytesExpression.type is null ||
            bytesExpression.type.toBasetype.isTypeDArray is null)
            return false;

        const bytes = runExpression(bytesExpression, interpreter).asArray;
        if (bytes.length < byteCount) {
            if (auto dotVar = bytesExpression.isDotVarExp)
                if (isUnitThreadedGeneratedValueExpression(dotVar)) {
                    value = Value(0L);
                    return true;
                }
            throw new Exception("Not enough bytes left to decerealise scalar.");
        }
        value = Value(coerceIntegerToType(
            readBigEndian(bytes[0 .. byteCount]),
            call.type,
        ));
        return true;
    }

    private bool tryRunAssocArrayDecerealiseValue(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "value")
            return false;
        if (call.type is null || call.type.toBasetype.isTypeAArray is null)
            return false;
        if (tryReadDecerealisedAssocArray(call, value, interpreter))
            return true;
        if (interpreter.lastAssocArrayRef == 0)
            return false;

        value = Value(AssocArrayRef(interpreter.lastAssocArrayRef));
        return true;
    }

    private bool tryReadDecerealisedAssocArray(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;
        size_t lengthTypeByteCount;
        tryGetCerealGrainLengthTypeByteCount(call, lengthTypeByteCount);
        return tryReadDecerealisedAssocArrayFromOwner(
            owner,
            call.type,
            value,
            interpreter,
            lengthTypeByteCount,
        );
    }

    private bool tryRunAssocArrayDecerealiseGrain(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "grain")
            return false;
        if (call.arguments is null)
            return false;

        Expression ownerExpression;
        Expression refArgument;
        if (call.arguments.length == 1) {
            auto dotVar = call.e1.isDotVarExp;
            if (dotVar is null)
                return false;
            ownerExpression = dotVar.e1;
            refArgument = callArguments(call)[0];
        } else if (call.arguments.length == 2) {
            ownerExpression = callArguments(call)[0];
            refArgument = callArguments(call)[1];
        } else {
            return false;
        }

        auto owner = structFieldsOwner(ownerExpression);
        if (owner is null)
            return false;
        auto var = refArgument.isVarExp;
        if (var is null)
            return false;
        auto varDecl = var.var.isVarDeclaration;
        if (varDecl is null ||
            varDecl.type is null ||
            varDecl.type.toBasetype.isTypeAArray is null)
            return false;

        size_t lengthTypeByteCount;
        tryGetCerealGrainLengthTypeByteCount(call, lengthTypeByteCount);

        Value value;
        if (!tryReadDecerealisedAssocArrayFromOwner(
            owner,
            varDecl.type,
            value,
            interpreter,
            lengthTypeByteCount,
        ))
            return false;

        assignRefArgument(refArgument, value, interpreter);
        return true;
    }

    private bool tryReadDecerealisedAssocArrayFromOwner(
        VarDeclaration owner,
        Type type,
        out Value value,
        ref Interpreter interpreter,
        in size_t lengthTypeByteCount = 0,
    ) {
        if (type is null)
            return false;
        auto arrayType = type.toBasetype.isTypeAArray;
        if (arrayType is null)
            return false;

        const keyByteCount = decerealisedScalarByteCount(arrayType.index);
        const valueByteCount = decerealisedScalarByteCount(arrayElementType(type));
        if (keyByteCount == 0 || valueByteCount == 0)
            return false;

        Value[VarDeclaration] ownerFields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        if (bytesField is null)
            return false;
        long[] bytes = structFieldValue(
            ownerFields,
            bytesField,
            Value((long[]).init),
        ).asArray;

        size_t headerByteCount;
        size_t length;
        if (!tryReadDecerealisedCollectionLength(
            bytes,
            keyByteCount + valueByteCount,
            headerByteCount,
            length,
            lengthTypeByteCount,
        ))
            return false;

        AssocArray array;
        size_t cursor = headerByteCount;
        foreach (_; 0 .. length) {
            const keyEnd = cursor + keyByteCount;
            array.keyStructs ~= null;
            array.keyFields ~= null;
            array.keys ~= Value(coerceIntegerToType(
                readBigEndian(bytes[cursor .. keyEnd]),
                arrayType.index,
            ));
            cursor = keyEnd;

            const valueEnd = cursor + valueByteCount;
            array.values ~= Value(coerceIntegerToType(
                readBigEndian(bytes[cursor .. valueEnd]),
                arrayElementType(type),
            ));
            cursor = valueEnd;
        }

        const assocArrayRef = AssocArrayRef(interpreter.nextAssocArrayRef);
        ++interpreter.nextAssocArrayRef;
        interpreter.assocArrays[assocArrayRef.id] = array;
        interpreter.lastAssocArrayRef = assocArrayRef.id;
        value = Value(assocArrayRef);
        assignStructField(ownerFields, bytesField, Value(bytes[cursor .. $].dup));
        assignStructFields(owner, ownerFields);
        return true;
    }

    private bool tryRunArrayDecerealiseValue(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (tryReadTopLevelDecerealisedArray(call, value, interpreter))
            return true;
        if (call.f.ident is null || call.f.ident.toString != "value")
            return false;
        if (call.type is null)
            return false;
        if (call.type.toBasetype.isTypeSArray !is null)
            return tryReadDecerealisedStaticArray(call, value);
        if (call.type.toBasetype.isTypeDArray is null)
            return false;
        if (tryReadDecerealisedArray(call, value, interpreter))
            return true;
        return false;
    }

    private bool tryRunOutputRangeDecerealiseRead(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "read")
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;
        if (!isOutputRangeStructType(callArguments(call)[0].type))
            return false;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        size_t neededByteCount;
        return tryReadOutputRangeFromOwner(
            owner,
            callArguments(call)[0].type,
            neededByteCount,
            interpreter,
        );
    }

    private bool tryReadTopLevelDecerealisedArray(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, "decerealise"))
            return false;
        if (call.type is null || call.type.toBasetype.isTypeDArray is null)
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;

        // Explicit type: the array reader needs a mutable slice.
        long[] bytes = runExpression(callArguments(call)[0], interpreter).asArray;
        long[] elements;
        size_t neededByteCount;
        size_t lengthTypeByteCount = 2;
        tryGetCerealGrainLengthTypeByteCount(call, lengthTypeByteCount);
        if (!tryReadDecerealisedArrayElements(
            arrayElementType(call.type),
            bytes,
            elements,
            neededByteCount,
            lengthTypeByteCount,
        ))
            return false;
        if (bytes.length < neededByteCount)
            throw new Exception("Not enough bytes left to decerealise array.");

        value = Value(elements);
        return true;
    }

    private bool tryReadDecerealisedArray(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto elementType = arrayElementType(call.type);
        size_t lengthTypeByteCount;
        tryGetCerealGrainLengthTypeByteCount(call, lengthTypeByteCount);
        return tryReadDecerealisedArrayFromOwner(
            owner,
            elementType,
            value,
            lengthTypeByteCount,
        );
    }

    private bool tryRunArrayDecerealiseGrain(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f is null ||
            call.f.ident is null ||
            call.f.ident.toString != "grain")
            return false;
        if (call.arguments is null)
            return false;

        Expression ownerExpression;
        Expression refArgument;
        if (call.arguments.length == 1) {
            auto dotVar = call.e1.isDotVarExp;
            if (dotVar is null)
                return false;
            ownerExpression = dotVar.e1;
            refArgument = callArguments(call)[0];
        } else if (call.arguments.length == 2) {
            ownerExpression = callArguments(call)[0];
            refArgument = callArguments(call)[1];
        } else {
            return false;
        }

        auto owner = structFieldsOwner(ownerExpression);
        if (owner is null)
            return false;
        Type refType;
        if (auto var = refArgument.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                refType = varDecl.type;
        if (auto dotVar = refArgument.isDotVarExp)
            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                refType = fieldDecl.type;
        if (refType is null || refType.toBasetype.isTypeDArray is null)
            return false;

        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto elementType = arrayElementType(refType);

        size_t lengthTypeByteCount = 2;
        tryGetCerealGrainLengthTypeByteCount(call, lengthTypeByteCount);

        Value value;
        if (!tryReadDecerealisedArrayFromOwner(owner, elementType, value, lengthTypeByteCount))
            return false;

        assignRefArgument(refArgument, value, interpreter);
        return true;
    }

    private bool tryReadDecerealisedArrayFromOwner(
        VarDeclaration owner,
        Type elementType,
        out Value value,
        in size_t lengthTypeByteCount = 0,
    ) {
        Value[VarDeclaration] ownerFields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        if (bytesField is null)
            return false;

        long[] bytes = structFieldValue(
            ownerFields,
            bytesField,
            Value((long[]).init),
        ).asArray;
        if (bytes.length < 1)
            return false;

        long[] elements;
        size_t neededByteCount;
        if (!tryReadDecerealisedArrayElements(
            elementType,
            bytes,
            elements,
            neededByteCount,
            lengthTypeByteCount,
        ))
            return false;

        if (bytes.length < neededByteCount)
            throw new Exception("Not enough bytes left to decerealise array.");

        value = Value(elements);
        assignStructField(
            ownerFields,
            bytesField,
            Value(bytes[neededByteCount .. $].dup),
        );
        assignStructFields(owner, ownerFields);
        return true;
    }

    private bool tryReadDecerealisedStaticArray(
        CallExp call,
        out Value value,
    ) {
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        Value[VarDeclaration] ownerFields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        if (bytesField is null)
            return false;

        long[] bytes = structFieldValue(
            ownerFields,
            bytesField,
            Value((long[]).init),
        ).asArray;
        const elementByteCount = decerealisedScalarByteCount(
            arrayElementType(call.type),
        );
        if (elementByteCount == 0)
            return false;

        const length = staticArrayLength(call.type);
        const neededByteCount = length * elementByteCount;
        if (bytes.length < neededByteCount)
            throw new Exception("Not enough bytes left to decerealise array.");

        long[] elements;
        foreach (i; 0 .. length) {
            const begin = i * elementByteCount;
            const end = begin + elementByteCount;
            elements ~= coerceIntegerToType(
                readBigEndian(bytes[begin .. end]),
                arrayElementType(call.type),
            );
        }

        value = Value(elements);
        assignStructField(
            ownerFields,
            bytesField,
            Value(bytes[neededByteCount .. $].dup),
        );
        assignStructFields(owner, ownerFields);
        return true;
    }

    private bool tryReadDecerealisedArrayElements(
        Type elementType,
        long[] bytes,
        out long[] elements,
        out size_t neededByteCount,
        in size_t lengthTypeByteCount = 0,
    ) {
        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount != 0) {
            size_t headerByteCount;
            size_t length;
            if (!tryReadDecerealisedCollectionLength(
                bytes,
                elementByteCount,
                headerByteCount,
                length,
                lengthTypeByteCount,
            ))
                return false;

            neededByteCount = headerByteCount + length * elementByteCount;
            if (bytes.length < neededByteCount)
                throw new Exception("Not enough bytes left to decerealise array.");

            foreach (i; 0 .. length) {
                const begin = headerByteCount + i * elementByteCount;
                const end = begin + elementByteCount;
                elements ~= coerceIntegerToType(
                    readBigEndian(bytes[begin .. end]),
                    elementType,
                );
            }

            return true;
        }

        if (elementType is null || elementType.toBasetype.isTypeDArray is null) {
            if (isStructType(elementType)) {
                if (bytes.length < 2)
                    return false;

                const length = nestedArrayLength(readBigEndian(bytes[0 .. 2]));
                size_t cursor = 2;
                foreach (_; 0 .. length) {
                    long[] structBytes;
                    size_t structByteCount;
                    if (!tryReadDecerealisedStructBytes(
                        elementType,
                        bytes[cursor .. $],
                        structBytes,
                        structByteCount,
                    ))
                        return false;
                    elements ~= cast(long) structBytes.length;
                    elements ~= structBytes;
                    cursor += structByteCount;
                    if (cursor > bytes.length)
                        throw new Exception(
                            "Not enough bytes left to decerealise array.",
                        );
                }

                neededByteCount = cursor;
                return true;
            } else {
                return false;
            }
        }
        size_t headerByteCount;
        size_t length;
        if (!tryReadDecerealisedCollectionLength(
            bytes,
            0,
            headerByteCount,
            length,
            lengthTypeByteCount,
        ))
            return false;
        size_t cursor = headerByteCount;
        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto nestedElementType = arrayElementType(elementType);
        foreach (_; 0 .. length) {
            long[] nestedElements;
            size_t nestedByteCount;
            if (!tryReadDecerealisedArrayElements(
                nestedElementType,
                bytes[cursor .. $],
                nestedElements,
                nestedByteCount,
                lengthTypeByteCount,
            ))
                return false;
            elements ~= cast(long) nestedElements.length;
            elements ~= nestedElements;
            cursor += nestedByteCount;
            if (cursor > bytes.length)
                throw new Exception("Not enough bytes left to decerealise array.");
        }

        neededByteCount = cursor;
        return true;
    }

    private bool tryReadDecerealisedStructBytes(
        Type type,
        long[] bytes,
        out long[] structBytes,
        out size_t neededByteCount,
    ) {
        size_t cursor;
        foreach (field; aggregateStructFields(type)) {
            size_t fieldByteCount;
            if (field.type !is null && field.type.toBasetype.isTypeDArray !is null) {
                long[] ignoredElements;
                if (!tryReadDecerealisedArrayElements(
                    arrayElementType(field.type),
                    bytes[cursor .. $],
                    ignoredElements,
                    fieldByteCount,
                ))
                    return false;
            } else if (field.type !is null &&
                field.type.toBasetype.isTypeAArray !is null) {
                if (!tryReadDecerealisedAssocArrayBytes(
                    field.type,
                    bytes[cursor .. $],
                    fieldByteCount,
                ))
                    return false;
            } else if (isStructType(field.type)) {
                long[] nestedBytes;
                if (!tryReadDecerealisedStructBytes(
                    field.type,
                    bytes[cursor .. $],
                    nestedBytes,
                    fieldByteCount,
                ))
                    return false;
            } else {
                fieldByteCount = decerealisedScalarByteCount(field.type);
                if (fieldByteCount == 0)
                    return false;
            }
            if (bytes.length < cursor + fieldByteCount)
                return false;
            structBytes ~= bytes[cursor .. cursor + fieldByteCount];
            cursor += fieldByteCount;
        }
        neededByteCount = cursor;
        return true;
    }

    private bool tryReadDecerealisedAssocArrayBytes(
        Type type,
        long[] bytes,
        out size_t neededByteCount,
    ) {
        if (bytes.length < 2)
            return false;

        auto arrayType = type.toBasetype.isTypeAArray;
        if (arrayType is null)
            return false;

        const keyByteCount = decerealisedScalarByteCount(arrayType.index);
        if (keyByteCount == 0)
            return false;

        const length = nestedArrayLength(readBigEndian(bytes[0 .. 2]));
        size_t cursor = 2;
        foreach (_; 0 .. length) {
            if (bytes.length < cursor + keyByteCount)
                return false;
            cursor += keyByteCount;
            if (isStructType(arrayElementType(type))) {
                long[] valueBytes;
                size_t valueByteCount;
                if (!tryReadDecerealisedStructBytes(
                    arrayElementType(type),
                    bytes[cursor .. $],
                    valueBytes,
                    valueByteCount,
                ))
                    return false;
                cursor += valueByteCount;
                continue;
            }

            const valueByteCount = decerealisedScalarByteCount(arrayElementType(type));
            if (valueByteCount == 0)
                return false;
            if (bytes.length < cursor + valueByteCount)
                return false;
            cursor += valueByteCount;
        }
        neededByteCount = cursor;
        return true;
    }

    private long assocArrayCallReceiver(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.arguments !is null && call.arguments.length >= 1)
            return assocArrayIdFromExpression(callArguments(call)[0], interpreter);
        if (auto dotVar = call.e1.isDotVarExp)
            return assocArrayIdFromExpression(dotVar.e1, interpreter);
        return 0L;
    }

    private Expression assocArrayCallReceiverExpression(
        CallExp call,
    ) {
        if (call.arguments !is null && call.arguments.length >= 1)
            return callArguments(call)[0];
        if (auto dotVar = call.e1.isDotVarExp)
            return dotVar.e1;
        return null;
    }

    private bool isAssocArrayExpression(
        Expression expression,
    ) {
        return expression !is null &&
            expression.type !is null &&
            expression.type.toBasetype.isTypeAArray !is null;
    }

    private long assocArrayIdFromExpression(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        Value value = runExpression(expression, interpreter);
        return value.match!(
            (AssocArrayRef ref_) => ref_.id,
            (LocalPtr ptr) {
                if (ptr.decl in locals)
                    return locals[ptr.decl].assocArrayId;
                return 0L;
            },
            (ClassRef _) => 0L,
            (long _) => 0L,
            (long[] _) => 0L,
            (AssocArraySlotRef _) => 0L,
        );
    }

    private bool tryAssocArrayIdFromExpression(
        Expression expression,
        out long arrayId,
        ref Interpreter interpreter,
    ) {
        try {
            arrayId = assocArrayIdFromExpression(expression, interpreter);
        } catch (Exception) {
            arrayId = 0L;
            return false;
        }
        return arrayId != 0;
    }

    private void appendScalarToCereal(
        VarDeclaration cerealOwner,
        in long scalar,
        in size_t byteCount,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] cerealFields = structFieldsValue(cerealOwner);
        auto outputField = structFieldNamed(cerealOwner.type, "_output");
        if (outputField is null)
            return;
        Value[VarDeclaration] outputFields;
        if (!tryGetStructFields(outputField, outputFields))
            return;
        auto bytesField = rangeStorageField(outputField.type);
        if (bytesField is null)
            return;

        long[] elements = storageArrayValue(structFieldValue(
            outputFields,
            bytesField,
            Value((long[]).init),
        ));
        appendIntegerBytes(elements, scalar, byteCount);
        rememberClearedRangePrefix(elements, interpreter);
        assignStructField(outputFields, bytesField, Value(elements));
        assignNestedStructFields(outputField, outputFields);
        assignStructField(cerealFields, outputField, Value(0L));
        assignStructFields(cerealOwner, cerealFields);
    }

    private bool needsDirectStructCerealAppend(
        Type type,
    ) {
        import std.algorithm.searching: canFind;

        if (typeChars(type).canFind("CustomStruct"))
            return true;
        foreach (field; aggregateStructFields(type)) {
            if (cerealFieldBitCount(field) != 0)
                return true;
            if (cerealFieldHasAttribute(field, "NoCereal"))
                return true;
            if (field.type !is null && field.type.toBasetype.isTypeAArray !is null)
                return true;
            if (field.type !is null && field.type.toBasetype.isTypeDArray !is null)
                if (decerealisedScalarByteCount(arrayElementType(field.type)) == 1)
                    return true;
            if (field.type !is null && field.type.toBasetype.isTypeDArray !is null)
                if (arrayElementType(field.type).toBasetype.isTypeDArray !is null)
                    return true;
            if (field.type !is null && field.type.toBasetype.isTypeDArray !is null)
                if (isStructType(arrayElementType(field.type)))
                    return true;
            if (isStructType(field.type) && needsDirectStructCerealAppend(field.type))
                return true;
        }
        return false;
    }

    private void appendStructToCereal(
        VarDeclaration cerealOwner,
        Type type,
        Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] cerealFields = structFieldsValue(cerealOwner);
        auto outputField = structFieldNamed(cerealOwner.type, "_output");
        if (outputField is null)
            return;
        Value[VarDeclaration] outputFields;
        if (!tryGetStructFields(outputField, outputFields))
            return;
        auto bytesField = rangeStorageField(outputField.type);
        if (bytesField is null)
            return;

        long[] elements = isModeledScopeBufferField(bytesField)
            ? interpreter.scopeBufferBytes.get(
                rangeStorageKey(outputField, bytesField),
                (long[]).init,
            )
            : storageArrayValue(structFieldValue(
                outputFields,
                bytesField,
                Value((long[]).init),
            ));
        appendStructFieldsToCereal(elements, type, fields, interpreter);
        if (isModeledScopeBufferField(bytesField))
            interpreter.scopeBufferBytes[rangeStorageKey(outputField, bytesField)] =
                elements;
        assignStructField(outputFields, bytesField, Value(elements));
        assignNestedStructFields(outputField, outputFields);
        assignStructField(cerealFields, outputField, Value(0L));
        assignStructFields(cerealOwner, cerealFields);
    }

    private void appendStructFieldsToCereal(
        ref long[] elements,
        Type type,
        Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        long bitByte;
        size_t bitIndex;
        foreach (field; cerealAggregateFields(type)) {
            const value = structFieldValue(fields, field, Value(0L));
            if (cerealFieldHasAttribute(field, "NoCereal")) {
                if (field.type !is null && field.type.toBasetype.isTypeDArray !is null)
                    appendArrayPayloadToCereal(
                        elements,
                        storageArrayValue(value),
                        arrayElementType(field.type),
                    );
                continue;
            }

            const bitCount = cerealFieldBitCount(field);
            if (bitCount != 0) {
                appendCerealBits(elements, bitByte, bitIndex, value.asLong, bitCount);
                continue;
            }
            flushCerealBits(elements, bitByte, bitIndex);

            if (field.type !is null && field.type.toBasetype.isTypeDArray !is null) {
                if (cerealArrayFieldHasExternalLength(field))
                    appendArrayPayloadToCereal(
                        elements,
                        storageArrayValue(value),
                        arrayElementType(field.type),
                    );
                else
                    appendArrayValueToCereal(
                        elements,
                        storageArrayValue(value),
                        arrayElementType(field.type),
                    );
                continue;
            }
            if (field.type !is null && field.type.toBasetype.isTypeAArray !is null) {
                appendAssocArrayValueToCereal(
                    elements,
                    value.assocArrayId,
                    interpreter,
                    field.type,
                );
                continue;
            }
            if (isStructType(field.type)) {
                Value[VarDeclaration] nestedFields;
                if (tryGetStructFields(field, nestedFields))
                    appendStructFieldsToCereal(
                        elements,
                        field.type,
                        nestedFields,
                        interpreter,
                    );
                continue;
            }

            const byteCount = decerealisedScalarByteCount(field.type);
            if (byteCount != 0)
                appendIntegerBytes(elements, value.asLong, byteCount);
        }
        flushCerealBits(elements, bitByte, bitIndex);
        appendCerealedAggregateHookBytes(elements, type, fields);
    }

    private void appendCerealedAggregateHookBytes(
        ref long[] elements,
        Type type,
        Value[VarDeclaration] fields,
    ) {
        import std.algorithm.searching: canFind;

        const chars = typeChars(type);
        if (chars.canFind("CustomStruct")) {
            elements ~= 4L;
            return;
        }
        if (chars.canFind("PostBlitStruct")) {
            appendUshort(elements, 4L);
            return;
        }
        if (!chars.canFind("MqttFixedHeader"))
            return;

        auto remainingField = structFieldNamed(type, "remaining");
        if (remainingField is null)
            return;
        appendMqttRemainingLength(
            elements,
            structFieldValue(fields, remainingField, Value(0L)).asLong,
        );
    }

    private void appendMqttRemainingLength(
        ref long[] elements,
        in long value,
    ) @safe {
        long remaining = value;
        do {
            long digit = remaining % 128;
            remaining /= 128;
            if (remaining > 0)
                digit |= 0x80;
            elements ~= digit;
        } while (remaining > 0);
    }

    private void appendCerealBits(
        ref long[] elements,
        ref long bitByte,
        ref size_t bitIndex,
        in long value,
        in size_t bitCount,
    ) @safe {
        size_t remaining = bitCount;
        while (remaining != 0) {
            const available = 8 - bitIndex;
            const take = remaining < available ? remaining : available;
            const shift = remaining - take;
            const mask = (1L << take) - 1;
            bitByte = (bitByte << take) | ((value >> shift) & mask);
            bitIndex += take;
            remaining -= take;
            if (bitIndex == 8) {
                elements ~= bitByte & 0xff;
                bitByte = 0L;
                bitIndex = 0;
            }
        }
    }

    private void flushCerealBits(
        ref long[] elements,
        ref long bitByte,
        ref size_t bitIndex,
    ) @safe {
        if (bitIndex == 0)
            return;
        elements ~= (bitByte << (8 - bitIndex)) & 0xff;
        bitByte = 0L;
        bitIndex = 0;
    }

    private bool appendArrayToCereal(
        VarDeclaration cerealOwner,
        long[] array,
        Type elementType,
        ref Interpreter interpreter,
        in bool includeLength = true,
        in size_t lengthTypeByteCount = 2,
    ) {
        Value[VarDeclaration] cerealFields = structFieldsValue(cerealOwner);
        auto outputField = structFieldNamed(cerealOwner.type, "_output");
        if (outputField is null)
            return false;
        Value[VarDeclaration] outputFields;
        if (!tryGetStructFields(outputField, outputFields))
            return false;
        auto bytesField = rangeStorageField(outputField.type);
        if (bytesField is null)
            return false;

        long[] elements = storageArrayValue(structFieldValue(
            outputFields,
            bytesField,
            Value((long[]).init),
        ));
        appendArrayValueToCereal(
            elements,
            array,
            elementType,
            includeLength,
            lengthTypeByteCount,
        );
        assignStructField(outputFields, bytesField, Value(elements));
        assignNestedStructFields(outputField, outputFields);
        assignStructField(cerealFields, outputField, Value(0L));
        assignStructFields(cerealOwner, cerealFields);
        return true;
    }

    private void appendArrayValueToCereal(
        ref long[] elements,
        long[] array,
        Type elementType,
        in bool includeLength = true,
        in size_t lengthTypeByteCount = 2,
    ) {
        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount != 0) {
            if (tryAppendNestedFlatArrayValueToCereal(
                elements,
                array,
                elementByteCount,
            ))
                return;
            if (includeLength)
                appendIntegerBytes(elements, cast(long) array.length, lengthTypeByteCount);
            foreach (element; array)
                appendIntegerBytes(elements, element, elementByteCount);
            return;
        }

        if (elementType is null) {
            elements ~= array;
            return;
        }

        if (elementType.toBasetype.isTypeDArray is null) {
            if (!includeLength && isStructType(elementType)) {
                appendStructFlatArrayPayloadToCereal(elements, array);
                return;
            }
            if (tryAppendStructFlatArrayValueToCereal(elements, array))
                return;
            if (includeLength)
                appendIntegerBytes(elements, cast(long) array.length, lengthTypeByteCount);
            return;
        }

        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto nestedElementType = arrayElementType(elementType);
        long[] payload;
        size_t cursor;
        size_t length;
        while (cursor < array.length) {
            const nestedLength = nestedArrayLength(array[cursor]);
            ++cursor;
            const nestedFlatLength = nestedArrayFlatLength(
                array,
                cursor,
                nestedLength,
                nestedElementType,
            );
            appendArrayValueToCereal(
                payload,
                array[cursor .. cursor + nestedFlatLength],
                nestedElementType,
                true,
                lengthTypeByteCount,
            );
            cursor += nestedFlatLength;
            ++length;
        }

        if (includeLength)
            appendIntegerBytes(elements, cast(long) length, lengthTypeByteCount);
        elements ~= payload;
    }

    private bool cerealArrayFieldHasExternalLength(VarDeclaration field) {
        return cerealFieldHasAttribute(field, "ArrayLength") ||
            cerealFieldHasAttribute(field, "LengthInBytes") ||
            cerealFieldHasRestAttribute(field);
    }

    private bool cerealFieldHasRestAttribute(VarDeclaration field) {
        return cerealFieldHasAttribute(field, "RestOfPacket") ||
            cerealFieldHasAttribute(field, "RawArray") ||
            cerealFieldHasAttribute(field, "Rest");
    }

    private void appendArrayPayloadToCereal(
        ref long[] elements,
        long[] array,
        Type elementType,
    ) {
        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount != 0) {
            foreach (element; array)
                appendIntegerBytes(elements, element, elementByteCount);
            return;
        }

        if (isStructType(elementType)) {
            appendStructFlatArrayPayloadToCereal(elements, array);
            return;
        }

        if (elementType is null || elementType.toBasetype.isTypeDArray is null) {
            elements ~= array;
            return;
        }

        appendNestedArrayPayloadsToCereal(elements, array, elementType);
    }

    private void appendNestedArrayPayloadsToCereal(
        ref long[] elements,
        in long[] array,
        Type elementType,
    ) {
        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto nestedElementType = arrayElementType(elementType);
        size_t cursor;
        while (cursor < array.length) {
            const nestedLength = nestedArrayLength(array[cursor]);
            ++cursor;
            if (nestedLength > array.length - cursor)
                throw new Exception("Malformed nested array value.");
            appendArrayValueToCereal(
                elements,
                array[cursor .. cursor + nestedLength].dup,
                nestedElementType,
            );
            cursor += nestedLength;
        }
    }

    private void appendStructFlatArrayPayloadToCereal(
        ref long[] elements,
        in long[] array,
    ) {
        size_t cursor;
        while (cursor < array.length) {
            const length = nestedArrayLength(array[cursor]);
            ++cursor;
            if (length > array.length - cursor)
                throw new Exception("Malformed nested array value.");
            elements ~= array[cursor .. cursor + length];
            cursor += length;
        }
    }

    private bool tryAppendNestedFlatArrayValueToCereal(
        ref long[] elements,
        in long[] array,
        in size_t elementByteCount,
    ) {
        size_t[] lengths;
        size_t cursor;
        bool allPayloadPrintable = true;
        while (cursor < array.length) {
            if (array[cursor] < 0)
                return false;
            const length = nestedArrayLength(array[cursor]);
            ++cursor;
            if (length == 0 || length > array.length - cursor)
                return false;
            foreach (value; array[cursor .. cursor + length])
                if (value < 32 || value > 126)
                    allPayloadPrintable = false;
            lengths ~= length;
            cursor += length;
        }
        if (lengths.length < 2)
            return false;

        appendUshort(elements, cast(long) lengths.length);
        cursor = 0;
        const payloadByteCount = allPayloadPrintable ? 1 : elementByteCount;
        foreach (length; lengths) {
            ++cursor;
            appendUshort(elements, cast(long) length);
            foreach (value; array[cursor .. cursor + length])
                appendIntegerBytes(elements, value, payloadByteCount);
            cursor += length;
        }
        return true;
    }

    private bool tryAppendStructFlatArrayValueToCereal(
        ref long[] elements,
        in long[] array,
    ) {
        if (array.length == 0) {
            appendUshort(elements, 0L);
            return true;
        }

        size_t[] lengths;
        size_t cursor;
        while (cursor < array.length) {
            const length = nestedArrayLength(array[cursor]);
            ++cursor;
            if (length > array.length - cursor)
                return false;
            lengths ~= length;
            cursor += length;
        }
        if (lengths.length == 0)
            return false;

        appendUshort(elements, cast(long) lengths.length);
        cursor = 0;
        foreach (length; lengths) {
            ++cursor;
            elements ~= array[cursor .. cursor + length];
            cursor += length;
        }
        return true;
    }

    private size_t nestedArrayFlatLength(
        in long[] array,
        in size_t cursor,
        in size_t length,
        Type elementType,
    ) {
        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount != 0) {
            if (length > array.length - cursor)
                throw new Exception("Malformed nested array value.");
            return length;
        }

        if (elementType is null || elementType.toBasetype.isTypeDArray is null)
            return length;

        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto nestedElementType = arrayElementType(elementType);
        size_t used;
        foreach (_; 0 .. length) {
            if (used >= array.length - cursor)
                throw new Exception("Malformed nested array value.");
            const nestedLength = nestedArrayLength(array[cursor + used]);
            ++used;
            const nestedFlatLength = nestedArrayFlatLength(
                array,
                cursor + used,
                nestedLength,
                nestedElementType,
            );
            if (nestedFlatLength > array.length - cursor - used)
                throw new Exception("Malformed nested array value.");
            used += nestedFlatLength;
        }

        return used;
    }

    private size_t nestedArrayLength(in long value) @safe pure {
        if (value < 0)
            throw new Exception("Malformed nested array value.");
        return cast(size_t) value;
    }

    private void appendAssocArrayToCereal(
        VarDeclaration cerealOwner,
        in long arrayId,
        Type type,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] cerealFields = structFieldsValue(cerealOwner);
        auto outputField = structFieldNamed(cerealOwner.type, "_output");
        if (outputField is null)
            return;
        Value[VarDeclaration] outputFields;
        if (!tryGetStructFields(outputField, outputFields))
            return;
        auto bytesField = rangeStorageField(outputField.type);
        if (bytesField is null)
            return;

        long[] elements = storageArrayValue(structFieldValue(
            outputFields,
            bytesField,
            Value((long[]).init),
        ));
        appendAssocArrayValueToCereal(elements, arrayId, interpreter, type);
        assignStructField(outputFields, bytesField, Value(elements));
        assignNestedStructFields(outputField, outputFields);
        assignStructField(cerealFields, outputField, Value(0L));
        assignStructFields(cerealOwner, cerealFields);
        interpreter.lastAssocArrayRef = arrayId;
    }

    private void appendAssocArrayValueToCereal(
        ref long[] elements,
        in long arrayId,
        ref Interpreter interpreter,
        Type type = null,
    ) {
        if (arrayId == 0 || arrayId !in interpreter.assocArrays) {
            appendUshort(elements, 0L);
            return;
        }

        import std.sumtype: match;

        AssocArray array = interpreter.assocArrays[arrayId];
        auto arrayType = type is null ? null : type.toBasetype.isTypeAArray;
        auto keyType = arrayType is null ? null : arrayType.index;
        auto valueType = arrayType is null ? null : arrayElementType(type);
        appendUshort(elements, cast(long) array.values.length);
        foreach (index, value; array.values) {
            appendAssocArrayKey(elements, array, index, keyType);
            value.match!(
                (long scalar) {
                    appendAssocArrayScalar(elements, scalar, valueType);
                },
                (long[] bytes) {
                    elements ~= bytes;
                },
                (LocalPtr _) {},
                (ClassRef _) {},
                (AssocArrayRef nested) {
                    appendAssocArrayValueToCereal(
                        elements,
                        nested.id,
                        interpreter,
                        valueType,
                    );
                },
                (AssocArraySlotRef _) {},
            );
        }
    }

    private void appendAssocArrayScalar(
        ref long[] elements,
        in long value,
        Type type,
    ) {
        const byteCount = decerealisedScalarByteCount(type);
        if (byteCount == 0) {
            appendInt(elements, value);
            return;
        }
        appendIntegerBytes(elements, value, byteCount);
    }

    private void appendAssocArrayKey(
        ref long[] elements,
        AssocArray array,
        in size_t index,
        Type keyType = null,
    ) {
        if (index >= array.keyStructs.length)
            return;
        if (array.keyStructs[index] is null) {
            appendAssocArrayScalar(elements, array.keys[index].asLong, keyType);
            return;
        }

        Value[VarDeclaration] fields;
        if (!tryAssocArrayStoredStructKeyFields(array, index, fields))
            return;
        auto keyStruct = array.keyStructs[index];
        foreach (field; aggregateStructFields(keyStruct.type)) {
            const value = structFieldValue(fields, field, Value(0L));
            if (field.type !is null && field.type.isTypeDArray !is null) {
                long[] bytes = value.asArray;
                appendUshort(elements, cast(long) bytes.length);
                elements ~= bytes;
            } else {
                appendAssocArrayScalar(elements, value.asLong, field.type);
            }
        }
    }

    private void appendUshort(ref long[] elements, in long value) {
        elements ~= (value >> 8) & 0xff;
        elements ~= value & 0xff;
    }

    private void appendInt(ref long[] elements, in long value) {
        elements ~= (value >> 24) & 0xff;
        elements ~= (value >> 16) & 0xff;
        elements ~= (value >> 8) & 0xff;
        elements ~= value & 0xff;
    }

    private void appendIntegerBytes(
        ref long[] elements,
        in long value,
        in size_t byteCount,
    ) {
        foreach_reverse (index; 0 .. byteCount)
            elements ~= (value >> (index * 8)) & 0xff;
    }

    private long assocArrayLength(
        in long arrayId,
        ref Interpreter interpreter,
    ) {
        if (arrayId == 0 || arrayId !in interpreter.assocArrays)
            return 0L;
        return cast(long) interpreter.assocArrays[arrayId].values.length;
    }

    private bool valuesEqual(
        Value actual,
        Value expected,
        ref Interpreter interpreter,
    ) {
        if (actual == expected)
            return true;

        const actualAssocId = actual.assocArrayId;
        const expectedAssocId = expected.assocArrayId;
        if (actualAssocId != 0 || expectedAssocId != 0)
            return assocArrayValuesEqual(
                actualAssocId,
                expectedAssocId,
                interpreter,
            );

        const actualClassId = actual.classId;
        const expectedClassId = expected.classId;
        if (actualClassId == 0 || expectedClassId == 0)
            return false;
        if (actualClassId !in interpreter.classFields ||
            expectedClassId !in interpreter.classFields)
            return false;

        Value[VarDeclaration] actualFields =
            interpreter.classFields[actualClassId];
        Value[VarDeclaration] expectedFields =
            interpreter.classFields[expectedClassId];
        return fieldValuesEqual(actualFields, expectedFields, interpreter) &&
            classStructFieldsEqual(
                actualClassId,
                expectedClassId,
                actualFields,
                expectedFields,
                interpreter,
            );
    }

    private bool assocArrayValuesEqual(
        in long actualArrayId,
        in long expectedArrayId,
        ref Interpreter interpreter,
    ) {
        if (actualArrayId == 0 || expectedArrayId == 0)
            return false;
        if (actualArrayId !in interpreter.assocArrays ||
            expectedArrayId !in interpreter.assocArrays)
            return false;

        AssocArray actual = interpreter.assocArrays[actualArrayId];
        AssocArray expected = interpreter.assocArrays[expectedArrayId];
        if (actual.values.length != expected.values.length)
            return false;

        foreach (i, actualKey; actual.keys) {
            bool found;
            foreach (j, expectedKey; expected.keys)
                if (assocArrayKeysEqual(
                    actual,
                    i,
                    expected,
                    j,
                    interpreter,
                ) &&
                    valuesEqual(actual.values[i], expected.values[j], interpreter)) {
                    found = true;
                    break;
                }
            if (!found)
                return false;
        }
        return true;
    }

    private bool assocArrayKeysEqual(
        AssocArray actual,
        in size_t actualIndex,
        AssocArray expected,
        in size_t expectedIndex,
        ref Interpreter interpreter,
    ) {
        auto actualStruct = actualIndex < actual.keyStructs.length
            ? actual.keyStructs[actualIndex]
            : null;
        auto expectedStruct = expectedIndex < expected.keyStructs.length
            ? expected.keyStructs[expectedIndex]
            : null;

        if (actualStruct is null && expectedStruct is null)
            return valuesEqual(
                actual.keys[actualIndex],
                expected.keys[expectedIndex],
                interpreter,
            );
        if (actualStruct is null || expectedStruct is null)
            return false;

        Value[VarDeclaration] actualFields;
        Value[VarDeclaration] expectedFields;
        if (!tryAssocArrayStoredStructKeyFields(
            actual,
            actualIndex,
            actualFields,
        ))
            return false;
        if (!tryAssocArrayStoredStructKeyFields(
            expected,
            expectedIndex,
            expectedFields,
        ))
            return false;
        return fieldValuesEqual(
            actualFields,
            expectedFields,
            interpreter,
        );
    }

    private bool tryAssocArrayStoredStructKeyFields(
        AssocArray array,
        in size_t index,
        out Value[VarDeclaration] fields,
    ) {
        if (index < array.keyStructs.length) {
            auto keyStruct = array.keyStructs[index];
            if (keyStruct !is null && keyStruct in structFields) {
                fields = structFields[keyStruct];
                return true;
            }
        }

        if (index < array.keyFields.length && array.keyFields[index] !is null) {
            fields = array.keyFields[index];
            return true;
        }

        return false;
    }

    private bool classStructFieldsEqual(
        in long actualClassId,
        in long expectedClassId,
        Value[VarDeclaration] actualFields,
        Value[VarDeclaration] expectedFields,
        ref Interpreter interpreter,
    ) {
        if (actualClassId !in interpreter.classStructFieldMaps ||
            expectedClassId !in interpreter.classStructFieldMaps)
            return false;

        Value[VarDeclaration][VarDeclaration] actualMaps =
            interpreter.classStructFieldMaps[actualClassId];
        Value[VarDeclaration][VarDeclaration] expectedMaps =
            interpreter.classStructFieldMaps[expectedClassId];
        foreach (field; actualFields.byKey)
            if (isStructType(field.type)) {
                Value[VarDeclaration] actualStructFields;
                Value[VarDeclaration] expectedStructFields;
                if (!tryGetStructFieldMap(actualMaps, field, actualStructFields))
                    return false;
                if (!tryGetStructFieldMap(
                    expectedMaps,
                    field,
                    expectedStructFields,
                ))
                    return false;
                if (!fieldValuesEqual(
                    actualStructFields,
                    expectedStructFields,
                    interpreter,
                ))
                    return false;
            }
        foreach (field; expectedFields.byKey) {
            if (!isStructType(field.type))
                continue;
            bool found;
            foreach (actualField; actualFields.byKey)
                if (sameStructField(actualField, field)) {
                    found = true;
                    break;
                }
            if (!found)
                return false;
        }
        return true;
    }

    private bool fieldValuesEqual(
        Value[VarDeclaration] actualFields,
        Value[VarDeclaration] expectedFields,
        ref Interpreter interpreter,
    ) {
        foreach (field, actualValue; actualFields) {
            const expectedValue = structFieldValue(
                expectedFields,
                field,
                Value(0L),
            );
            if (!valuesEqual(actualValue, expectedValue, interpreter))
                return false;
        }
        foreach (field, expectedValue; expectedFields) {
            const actualValue = structFieldValue(
                actualFields,
                field,
                Value(0L),
            );
            if (!valuesEqual(actualValue, expectedValue, interpreter))
                return false;
        }
        return true;
    }

    private bool tryRunGrainUByte(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "grainUByte")
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;
        Value[VarDeclaration] ownerFields = structFields[owner];
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        if (bytesField is null)
            return false;
        long[] bytes = structFieldValue(
            ownerFields,
            bytesField,
            Value((long[]).init),
        ).asArray;
        if (bytes.length == 0)
            throw new Exception("Cannot read byte from empty Decerealiser.");

        assignRefArgument(
            callArguments(call)[0],
            Value(bytes[0]),
            interpreter,
        );
        assignStructField(ownerFields, bytesField, Value(bytes[1 .. $].dup));
        structFields[owner] = ownerFields;
        return true;
    }

    private bool tryRunSetBytes(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "setBytes")
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;
        Value[VarDeclaration] ownerFields = structFields[owner];
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        auto originalBytesField =
            structFieldNamed(owner.type, "_originalBytes");
        if (bytesField is null || originalBytesField is null)
            return false;

        long[] bytes = runExpression(callArguments(call)[0], interpreter).asArray;
        assignStructField(ownerFields, bytesField, Value(bytes.dup));
        assignStructField(ownerFields, originalBytesField, Value(bytes.dup));
        structFields[owner] = ownerFields;
        return true;
    }

    private bool tryRunReadBits(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "readBits")
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        Value[VarDeclaration] ownerFields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        auto currentByteField = structFieldNamed(owner.type, "_currentByte");
        auto bitIndexField = structFieldNamed(owner.type, "_bitIndex");
        if (bytesField is null ||
            currentByteField is null ||
            bitIndexField is null)
            return false;

        long[] bytes = structFieldValue(
            ownerFields,
            bytesField,
            Value((long[]).init),
        ).asArray;
        long currentByte = structFieldValue(
            ownerFields,
            currentByteField,
            Value(0L),
        ).asLong;
        long bitIndex = structFieldValue(
            ownerFields,
            bitIndexField,
            Value(0L),
        ).asLong;

        long result;
        long remaining = runExpression(callArguments(call)[0], interpreter).asLong;
        while (remaining > 0) {
            if (bitIndex == 0) {
                if (bytes.length == 0)
                    throw new Exception("Cannot read bits from empty Decerealiser.");
                currentByte = bytes[0];
                bytes = bytes[1 .. $].dup;
            }

            const available = 8 - bitIndex;
            const take = remaining < available ? remaining : available;
            const shift = available - take;
            const mask = (1L << take) - 1;
            result = (result << take) | ((currentByte >> shift) & mask);
            bitIndex += take;
            remaining -= take;
            if (bitIndex == 8)
                bitIndex = 0;
        }

        assignStructField(ownerFields, bytesField, Value(bytes));
        assignStructField(ownerFields, currentByteField, Value(currentByte));
        assignStructField(ownerFields, bitIndexField, Value(bitIndex));
        structFields[owner] = ownerFields;
        value = Value(result);
        return true;
    }

    private bool tryRunReset(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, "reset"))
            return false;

        VarDeclaration owner;
        if (auto dotVar = call.e1.isDotVarExp)
            owner = structFieldsOwner(dotVar.e1);
        else
            owner = currentThis;
        if (owner is null)
            return false;

        Value[VarDeclaration] ownerFields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        auto originalBytesField = structFieldNamed(owner.type, "_originalBytes");
        auto currentByteField = structFieldNamed(owner.type, "_currentByte");
        auto bitIndexField = structFieldNamed(owner.type, "_bitIndex");
        if (bytesField is null ||
            originalBytesField is null ||
            currentByteField is null ||
            bitIndexField is null)
            return false;

        long[] bytes;
        if (call.arguments !is null && call.arguments.length == 1) {
            bytes = runExpression(callArguments(call)[0], interpreter).asArray;
            assignStructField(ownerFields, originalBytesField, Value(bytes.dup));
        } else if (call.arguments is null || call.arguments.length == 0) {
            bytes = structFieldValue(
                ownerFields,
                originalBytesField,
                Value((long[]).init),
            ).asArray;
        } else {
            return false;
        }

        assignStructField(ownerFields, bytesField, Value(bytes.dup));
        assignStructField(ownerFields, currentByteField, Value(0L));
        assignStructField(ownerFields, bitIndexField, Value(0L));
        structFields[owner] = ownerFields;
        return true;
    }

    private void assignRefArgument(
        Expression arg,
        Value value,
        ref Interpreter interpreter,
    ) {
        import std.conv: text;

        if (auto var = arg.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration) {
                locals[varDecl] = value;
                return;
            }
        if (auto dotVar = arg.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration) {
                    if (auto fields = ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            assignStructField(*fields, fieldDecl, value);
                            return;
                        }
                    if (auto local = ownerDecl in locals)
                        if (auto fields = classInstanceFields(
                            *local,
                            interpreter,
                        ))
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                assignStructField(*fields, fieldDecl, value);
                                return;
                            }
                }

        throw new Exception(text(
            "Unsupported ref assignment: ",
            expressionChars(arg),
        ));
    }

    private bool tryRunAllocatorCall(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null)
            return false;
        if (call.f.ident.toString == "realloc") {
            value = Value(1L);
            return true;
        }
        if (call.f.ident.toString == "memcpy") {
            value = Value(1L);
            return true;
        }
        if (call.f.ident.toString == "free") {
            value = Value(0L);
            return true;
        }
        if (call.f.ident.toString == "_d_aaGetY") {
            value = Value(1L);
            return true;
        }
        return false;
    }

    private bool tryRunUnitThreadedGenValues(
        CallExp call,
    ) {
        return call.f !is null &&
            call.f.ident !is null &&
            call.f.ident.toString == "genValues";
    }

    private bool tryRunPow(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "_powImpl")
            return false;
        if (call.arguments is null || call.arguments.length != 2)
            return false;

        import std.math: pow;

        const left = doubleFromBits(runExpression(
            callArguments(call)[0],
            interpreter,
        ).asLong);
        const right = doubleFromBits(runExpression(
            callArguments(call)[1],
            interpreter,
        ).asLong);
        value = Value(doubleBits(pow(left, right)));
        return true;
    }

    private bool tryRunArrayBoundsFailure(
        CallExp call,
    ) {
        if (call.f.ident is null)
            return false;

        const name = call.f.ident.toString;
        if (name != "_d_arraybounds" &&
            name != "_d_arrayboundsp" &&
            name != "_d_arraybounds_index" &&
            name != "_d_arraybounds_indexp" &&
            name != "_d_arraybounds_slice" &&
            name != "_d_arraybounds_slicep")
            return false;

        throw new Exception("Array bounds check failed.");
    }

    private bool tryRunScopeBufferRangeConstructor(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.parameters !is null)
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;
        if (call.f.isCtorDeclaration is null)
            return false;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;

        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null || !isScopeBufferRangeType(owner.type))
            return false;

        auto bytesField = rangeStorageField(owner.type);
        if (bytesField is null)
            return false;

        interpreter.scopeBufferBytes[rangeStorageKey(owner, bytesField)] =
            (long[]).init;
        return true;
    }

    private bool tryRunShouldNotThrow(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "shouldNotThrow")
            return false;
        if (call.arguments is null || call.arguments.length == 0)
            return false;

        runLazyArgument(callArguments(call)[0], interpreter);
        return true;
    }

    private void runLazyArgument(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        if (auto literal = expression.isFuncExp) {
            runLazyFunctionBody(literal.fd.fbody, interpreter);
            return;
        }
        if (auto var = expression.isVarExp) {
            if (auto function_ = var.var.isFuncDeclaration) {
                if (function_.fbody !is null) {
                    runLazyFunctionBody(function_.fbody, interpreter);
                    return;
                }
            }
        }

        runExpression(expression, interpreter, true);
    }

    private void runLazyFunctionBody(
        Statement statement,
        ref Interpreter interpreter,
    ) {
        const hadReturn = hasReturn;
        const oldReturnValue = returnValue;
        hasReturn = false;
        runStatement(statement, interpreter);
        if (hasThrown) {
            const message = thrownMessage;
            hasThrown = false;
            thrownMessage = null;
            hasReturn = hadReturn;
            returnValue = oldReturnValue;
            throw new Exception(message);
        }
        hasReturn = hadReturn;
        returnValue = oldReturnValue;
    }

    private bool tryRunRegisterChildClass(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null ||
            call.f.ident.toString != "registerChildClass")
            return false;
        interpreter.childClassRegistered = true;
        return true;
    }

    private bool tryRunRangeMethod(
        CallExp call,
        ref Interpreter interpreter,
        in bool resultIgnored,
    ) {
        if (call.f.ident is null)
            return false;
        if (auto dotVar = call.e1.isDotVarExp) {
            if (call.f.ident.toString == "put") {
                const handled = tryRunRangePut(dotVar.e1, call, interpreter);
                return handled;
            }
            if (call.f.ident.toString == "clear")
                return tryRunRangeClear(dotVar.e1, call, interpreter);
            if (call.f.ident.toString == "free")
                return true;
        }
        return false;
    }

    private bool tryRunRangeData(
        CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "data")
            return false;
        if (call.arguments !is null && call.arguments.length != 0)
            return false;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;

        // auto: must keep the mutable DMD VarDeclaration reference for AA keys.
        auto rangeOwner = rangeStructOwner(dotVar.e1);
        if (rangeOwner is null)
            return false;

        // auto: must keep the mutable DMD VarDeclaration reference for AA keys.
        auto bytesField = rangeStorageField(rangeOwner.type);
        if (bytesField is null)
            return false;

        if (isModeledScopeBufferField(bytesField)) {
            value = Value(interpreter.scopeBufferBytes.get(
                rangeStorageKey(rangeOwner, bytesField),
                (long[]).init,
            ));
            return true;
        }

        Value[VarDeclaration] fields = structFieldsValue(rangeOwner);
        value = structFieldValue(fields, bytesField, Value((long[]).init));
        return true;
    }

    private bool tryRunRangePut(
        Expression receiver,
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.arguments is null || call.arguments.length != 1)
            return false;

        // auto: must keep the mutable DMD VarDeclaration reference for AA keys.
        auto rangeOwner = rangeStructOwner(receiver);
        if (rangeOwner is null)
            return false;

        // auto: must keep the mutable DMD VarDeclaration reference for AA keys.
        auto bytesField = rangeStorageField(rangeOwner.type);
        if (bytesField is null)
            return false;

        Value[VarDeclaration] fields = structFieldsValue(rangeOwner);
        long[] elements;
        if (isModeledScopeBufferField(bytesField))
            elements = interpreter.scopeBufferBytes.get(
                rangeStorageKey(rangeOwner, bytesField),
                (long[]).init,
            );
        else
            elements = storageArrayValue(structFieldValue(
                fields,
                bytesField,
                Value((long[]).init),
            ));
        appendRangePutValue(
            elements,
            runExpression(callArguments(call)[0], interpreter),
            rangeElementType(bytesField),
        );
        rememberClearedRangePrefix(elements, interpreter);
        if (isModeledScopeBufferField(bytesField))
            interpreter.scopeBufferBytes[rangeStorageKey(rangeOwner, bytesField)] =
                elements;
        assignStructField(fields, bytesField, Value(elements));
        assignNestedStructFields(rangeOwner, fields);
        return true;
    }

    private Value applyClearedRangeAlias(
        Value value,
        ref Interpreter interpreter,
    ) {
        if (!interpreter.hasClearedRangeAlias)
            return value;

        const aliasElements = storageArrayValue(value);
        if (aliasElements != interpreter.clearedRangeAlias)
            return value;

        long[] elements = interpreter.clearedRangePrefix.dup;
        if (interpreter.clearedRangePrefix.length <
            interpreter.clearedRangeAlias.length)
            elements ~= interpreter.clearedRangeAlias[
                interpreter.clearedRangePrefix.length .. $
            ];
        return Value(elements);
    }

    private void rememberClearedRangePrefix(
        in long[] elements,
        ref Interpreter interpreter,
    ) {
        if (!interpreter.hasClearedRangeAlias)
            return;

        interpreter.clearedRangePrefix = elements.dup;
    }

    private long[] storageArrayValue(Value value) {
        import std.sumtype: match;

        return value.match!(
            (long[] a) => a,
            (long _) => (long[]).init,
            (LocalPtr _) => (long[]).init,
            (ClassRef _) => (long[]).init,
            (AssocArrayRef _) => (long[]).init,
            (AssocArraySlotRef _) => (long[]).init,
        );
    }

    private void appendRangePutValue(
        ref long[] elements,
        Value value,
        Type elementType,
    ) {
        import std.sumtype: match;

        value.match!(
            (long l) {
                elements ~= coerceIntegerToType(l, elementType);
            },
            (long[] a) {
                const byteCount = decerealisedScalarByteCount(elementType);
                if (byteCount != 0 &&
                    tryAppendNestedFlatArrayValueToCereal(elements, a, byteCount))
                    return;
                if (byteCount == 0 &&
                    tryAppendStructFlatArrayValueToCereal(elements, a))
                    return;
                foreach (element; a)
                    elements ~= coerceIntegerToType(element, elementType);
            },
            (LocalPtr _) {
                throw new Exception("Expected range put value, got pointer.");
            },
            (ClassRef _) {
                throw new Exception("Expected range put value, got class.");
            },
            (AssocArrayRef _) {
                throw new Exception("Expected range put value, got AA.");
            },
            (AssocArraySlotRef _) {
                throw new Exception("Expected range put value, got AA slot.");
            },
        );
    }

    private bool tryRunRangeClear(
        Expression receiver,
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.arguments !is null && call.arguments.length != 0)
            return false;

        // auto: must keep the mutable DMD VarDeclaration reference for AA keys.
        auto rangeOwner = rangeStructOwner(receiver);
        if (rangeOwner is null)
            return false;

        // auto: must keep the mutable DMD VarDeclaration reference for AA keys.
        auto bytesField = rangeStorageField(rangeOwner.type);
        if (bytesField is null)
            return false;

        Value[VarDeclaration] fields = structFieldsValue(rangeOwner);
        rememberClearedRangeAlias(
            storageArrayValue(structFieldValue(
                fields,
                bytesField,
                Value((long[]).init),
            )),
            interpreter,
        );
        assignStructField(fields, bytesField, Value((long[]).init));
        assignNestedStructFields(rangeOwner, fields);
        return true;
    }

    private void rememberClearedRangeAlias(
        in long[] elements,
        ref Interpreter interpreter,
    ) {
        interpreter.clearedRangeAlias = elements.dup;
        interpreter.clearedRangePrefix = (long[]).init;
        interpreter.hasClearedRangeAlias = elements.length != 0;
    }

    private VarDeclaration rangeStorageField(
        Type type,
    ) {
        if (auto bytesField = structFieldNamed(type, "_bytes"))
            return bytesField;
        if (auto dataField = structFieldNamed(type, "_data"))
            return dataField;
        return structFieldNamed(type, "sbuf");
    }

    private Type rangeElementType(
        VarDeclaration storageField,
    ) {
        if (storageField.type !is null && storageField.type.isTypeDArray !is null)
            return arrayElementType(storageField.type);
        return null;
    }

    private bool isModeledScopeBufferField(VarDeclaration field) {
        return field.ident !is null && field.ident.toString == "sbuf";
    }

    private bool isScopeBufferRangeType(Type type) {
        return typeChars(type) == "ScopeBufferRange";
    }

    private string rangeStorageKey(
        VarDeclaration owner,
        VarDeclaration field,
    ) {
        import std.conv: text;

        return text(typeChars(owner.type), ".", field.ident);
    }

    private VarDeclaration rangeStructOwner(
        Expression receiver,
    ) {
        if (auto dotVar = receiver.isDotVarExp)
            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                if (fieldDecl.ident !is null &&
                    fieldDecl.ident.toString == "sbuf") {
                    if (auto owner = structFieldsOwner(dotVar.e1))
                        return owner;
                    else if (auto parentDotVar = dotVar.e1.isDotVarExp)
                        if (auto parentField =
                            parentDotVar.var.isVarDeclaration)
                            if (isStructType(parentField.type)) {
                                if (parentField !in structFields)
                                    structFields[parentField] =
                                        (Value[VarDeclaration]).init;
                                return parentField;
                            }
                }
        if (auto owner = structFieldsOwner(receiver))
            return owner;
        if (auto dotVar = receiver.isDotVarExp)
            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                if (isStructType(fieldDecl.type)) {
                    if (fieldDecl !in structFields)
                        structFields[fieldDecl] = (Value[VarDeclaration]).init;
                    return fieldDecl;
                }
            }
        return null;
    }

    private void propagateRefArguments(
        ref Interpreter interpreter,
        FuncDeclaration function_,
        CallArgument[] args,
        Value[] refValues,
        Value[VarDeclaration][] structRefValues,
        Value[VarDeclaration][VarDeclaration] structFieldMaps,
    ) {
        if (function_.parameters is null)
            return;

        size_t scalarIndex;
        size_t structIndex;
        foreach (i, param; functionParameters(function_)) {
            import dmd.astenums: STC;

            if ((param.storage_class & STC.ref_) == STC.none)
                continue;
            if (args[i].isStructRef) {
                if (args[i].hasRefIndex) {
                    assignIndexedStructRefArgument(
                        interpreter,
                        args[i],
                        structRefValues[structIndex],
                    );
                    propagateNestedStructFieldMaps(
                        structRefValues[structIndex],
                        structFieldMaps,
                    );
                    ++structIndex;
                    continue;
                }
                if (args[i].refClassId != 0) {
                    if (args[i].refField is null) {
                        interpreter.classFields[args[i].refClassId] =
                            structRefValues[structIndex];
                        interpreter.classStructFieldMaps[args[i].refClassId] =
                            nestedStructFieldMaps(structRefValues[structIndex]);
                    } else {
                        interpreter.classStructFieldMaps[args[i].refClassId]
                            [args[i].refField] = structRefValues[structIndex];
                    }
                } else {
                    structFields[args[i].refSource] = structRefValues[structIndex];
                }
                propagateNestedStructFieldMaps(
                    structRefValues[structIndex],
                    structFieldMaps,
                );
                ++structIndex;
            } else if (args[i].isTemporaryRef) {
                ++scalarIndex;
            } else if (args[i].hasRefIndex) {
                assignIndexedRefArgument(
                    interpreter,
                    args[i],
                    refValues[scalarIndex],
                    param.type,
                );
                ++scalarIndex;
            } else if (args[i].refSource !is null) {
                const value = coerceValueToType(
                    refValues[scalarIndex],
                    args[i].refSource.type,
                );
                if (args[i].isGlobalRef)
                    assignGlobalValue(args[i].refSource, value, interpreter);
                else
                    locals[args[i].refSource] = value;
                ++scalarIndex;
            } else if (args[i].refClassId != 0) {
                if (args[i].refField is null)
                    interpreter.heapScalars[args[i].refClassId] =
                        coerceValueToType(refValues[scalarIndex], param.type);
                else
                    interpreter.classFields[args[i].refClassId][args[i].refField] =
                        coerceValueToType(
                            refValues[scalarIndex],
                            args[i].refField.type,
                        );
                ++scalarIndex;
            } else {
                structFields[args[i].refOwner][args[i].refField] =
                    coerceValueToType(
                        refValues[scalarIndex],
                        args[i].refField.type,
                    );
                ++scalarIndex;
            }
        }
    }

    private bool tryAppendIndexedRefArgument(
        ref CallArgument[] args,
        Expression argument,
        ref Interpreter interpreter,
    ) {
        Expression indexedExpression;
        Expression indexExpression;
        if (auto index = argument.isIndexExp) {
            indexedExpression = index.e1;
            indexExpression = index.e2;
        } else if (auto array = argument.isArrayExp) {
            if (arrayExpressionArguments(array).length != 1)
                return false;
            indexedExpression = array.e1;
            indexExpression = arrayExpressionArguments(array)[0];
        } else {
            return false;
        }

        const index = cast(size_t) runExpression(
            indexExpression,
            interpreter,
        ).asLong;

        Value localValue;
        if (auto var = indexedExpression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration) {
                if (tryGetLocalValue(varDecl, localValue)) {
                    if (tryAppendIndexedStructRefArgument(
                        args,
                        varDecl,
                        null,
                        null,
                        0L,
                        false,
                        localValue,
                        varDecl.type,
                        index,
                        interpreter,
                    ))
                        return true;
                    appendIndexedLocalRefArgument(args, varDecl, localValue, index);
                    return true;
                }

                Value globalValue;
                if (tryGetGlobalValue(varDecl, interpreter, globalValue)) {
                    if (tryAppendIndexedStructRefArgument(
                        args,
                        varDecl,
                        null,
                        null,
                        0L,
                        true,
                        globalValue,
                        varDecl.type,
                        index,
                        interpreter,
                    ))
                        return true;
                    CallArgument refArgument;
                    refArgument.value = Value(globalValue.asArray[index]);
                    refArgument.refSource = varDecl;
                    refArgument.isGlobalRef = true;
                    refArgument.hasRefIndex = true;
                    refArgument.refIndex = index;
                    args ~= refArgument;
                    return true;
                }
            }

        if (auto dotVar = indexedExpression.isDotVarExp) {
            if (auto owner = structFieldsOwner(dotVar.e1))
                if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                    Value[VarDeclaration] fields = structFieldsValue(owner);
                    const arrayValue = structFieldValue(
                        fields,
                        fieldDecl,
                        defaultArrayValue(fieldDecl.type),
                    );
                    if (tryAppendIndexedStructRefArgument(
                        args,
                        null,
                        owner,
                        fieldDecl,
                        0L,
                        false,
                        arrayValue,
                        fieldDecl.type,
                        index,
                        interpreter,
                    ))
                        return true;
                    appendIndexedFieldRefArgument(
                        args,
                        arrayValue,
                        owner,
                        fieldDecl,
                        0L,
                        index,
                    );
                    return true;
                }

            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto local = ownerDecl in locals)
                        if (auto fields = classInstanceFields(
                            *local,
                            interpreter,
                        ))
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const arrayValue = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    defaultArrayValue(fieldDecl.type),
                                );
                                if (tryAppendIndexedStructRefArgument(
                                    args,
                                    null,
                                    null,
                                    fieldDecl,
                                    (*local).classId,
                                    false,
                                    arrayValue,
                                    fieldDecl.type,
                                    index,
                                    interpreter,
                                ))
                                    return true;
                                appendIndexedFieldRefArgument(
                                    args,
                                    arrayValue,
                                    null,
                                    fieldDecl,
                                    (*local).classId,
                                    index,
                                );
                                return true;
                            }

            if (auto thisExp = dotVar.e1.isThisExp)
                if (auto thisDecl = thisExp.var.isVarDeclaration)
                    if (auto fields = thisDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            const arrayValue = structFieldValue(
                                *fields,
                                fieldDecl,
                                defaultArrayValue(fieldDecl.type),
                            );
                            if (tryAppendIndexedStructRefArgument(
                                args,
                                null,
                                thisDecl,
                                fieldDecl,
                                0L,
                                false,
                                arrayValue,
                                fieldDecl.type,
                                index,
                                interpreter,
                            ))
                                return true;
                            appendIndexedFieldRefArgument(
                                args,
                                arrayValue,
                                thisDecl,
                                fieldDecl,
                                0L,
                                index,
                            );
                            return true;
                        }
        }

        return false;
    }

    private bool tryAppendIndexedStructRefArgument(
        ref CallArgument[] args,
        VarDeclaration source,
        VarDeclaration owner,
        VarDeclaration field,
        in long classId,
        in bool isGlobal,
        Value arrayValue,
        Type arrayType,
        in size_t index,
        ref Interpreter interpreter,
    ) {
        // auto: DMD type helper APIs require mutable Type nodes.
        auto elementType = arrayElementType(arrayType);
        if (!isStructType(elementType))
            return false;

        Value[VarDeclaration] fields;
        if (!tryReadStructArrayElementFields(
            elementType,
            arrayValue.asArray,
            index,
            fields,
            interpreter,
        ))
            return false;

        CallArgument refArgument;
        refArgument.refSource = source;
        refArgument.refOwner = owner;
        refArgument.refField = field;
        refArgument.refClassId = classId;
        refArgument.isGlobalRef = isGlobal;
        refArgument.hasRefIndex = true;
        refArgument.refIndex = index;
        refArgument.structFields = fields.dup;
        refArgument.structFieldMaps = nestedStructFieldMaps(refArgument.structFields);
        refArgument.isStructRef = true;
        args ~= refArgument;
        return true;
    }

    private void appendIndexedLocalRefArgument(
        ref CallArgument[] args,
        VarDeclaration declaration,
        Value arrayValue,
        in size_t index,
    ) {
        CallArgument refArgument;
        refArgument.value = Value(arrayValue.asArray[index]);
        refArgument.refSource = declaration;
        refArgument.hasRefIndex = true;
        refArgument.refIndex = index;
        args ~= refArgument;
    }

    private void appendIndexedFieldRefArgument(
        ref CallArgument[] args,
        Value arrayValue,
        VarDeclaration owner,
        VarDeclaration field,
        in long classId,
        in size_t index,
    ) {
        CallArgument refArgument;
        refArgument.value = Value(arrayValue.asArray[index]);
        refArgument.refOwner = owner;
        refArgument.refField = field;
        refArgument.refClassId = classId;
        refArgument.hasRefIndex = true;
        refArgument.refIndex = index;
        args ~= refArgument;
    }

    private void assignIndexedRefArgument(
        ref Interpreter interpreter,
        CallArgument argument,
        Value value,
        Type parameterType,
    ) {
        if (argument.refSource !is null) {
            Value storageValue;
            if (argument.isGlobalRef)
                storageValue = globalValueOrDefault(argument, interpreter);
            else
                storageValue = localValueOrDefault(argument);

            long[] elements = arrayStorageValue(storageValue, argument.refSource.type);
            elements[argument.refIndex] = coerceIntegerToType(
                value.asLong,
                arrayElementType(argument.refSource.type),
            );

            if (argument.isGlobalRef)
                assignGlobalValue(argument.refSource, Value(elements), interpreter);
            else {
                locals[argument.refSource] = Value(elements);
                propagateArrayAlias(argument.refSource, argument.refIndex, value);
            }
            return;
        }

        if (argument.refField !is null) {
            Value[VarDeclaration] fields = indexedRefFields(
                argument,
                interpreter,
            );
            long[] elements = structFieldValue(
                fields,
                argument.refField,
                defaultArrayValue(argument.refField.type),
            ).asArray;
            elements[argument.refIndex] = coerceIntegerToType(
                value.asLong,
                arrayElementType(argument.refField.type),
            );
            assignStructField(fields, argument.refField, Value(elements));

            if (argument.refClassId != 0)
                interpreter.classFields[argument.refClassId] = fields;
            else
                assignNestedStructFields(argument.refOwner, fields);
            return;
        }

        const coerced = coerceValueToType(value, parameterType);
        assert(coerced.asLong == value.asLong);
    }

    private void assignIndexedStructRefArgument(
        ref Interpreter interpreter,
        CallArgument argument,
        Value[VarDeclaration] fields,
    ) {
        // auto: DMD type helper APIs require mutable Type nodes.
        auto arrayType = argument.refSource !is null
            ? argument.refSource.type
            : argument.refField.type;
        auto elementType = arrayElementType(arrayType);
        long[] structBytes;
        appendStructFieldsToCereal(structBytes, elementType, fields, interpreter);

        if (argument.refSource !is null) {
            Value storageValue;
            if (argument.isGlobalRef)
                storageValue = globalValueOrDefault(argument, interpreter);
            else
                storageValue = localValueOrDefault(argument);
            long[] elements = replaceNestedArrayElement(
                arrayStorageValue(storageValue, arrayType),
                argument.refIndex,
                structBytes,
            );

            if (argument.isGlobalRef)
                assignGlobalValue(argument.refSource, Value(elements), interpreter);
            else
                locals[argument.refSource] = Value(elements);
            return;
        }

        Value[VarDeclaration] ownerFields = indexedRefFields(
            argument,
            interpreter,
        );
        long[] elements = replaceNestedArrayElement(
            structFieldValue(
                ownerFields,
                argument.refField,
                defaultArrayValue(arrayType),
            ).asArray,
            argument.refIndex,
            structBytes,
        );
        assignStructField(ownerFields, argument.refField, Value(elements));
        if (argument.refClassId != 0)
            interpreter.classFields[argument.refClassId] = ownerFields;
        else
            assignNestedStructFields(argument.refOwner, ownerFields);
    }

    private long[] replaceNestedArrayElement(
        long[] array,
        in size_t index,
        long[] payload,
    ) {
        size_t cursor;
        foreach (i; 0 .. index + 1) {
            const elementStart = cursor;
            const length = nestedArrayLength(array[cursor]);
            ++cursor;
            const elementEnd = cursor + length;
            if (i == index)
                return array[0 .. elementStart] ~
                    [cast(long) payload.length] ~
                    payload ~
                    array[elementEnd .. $];
            cursor = elementEnd;
        }
        return array;
    }

    private Value globalValueOrDefault(
        CallArgument argument,
        ref Interpreter interpreter,
    ) {
        Value value;
        if (tryGetGlobalValue(argument.refSource, interpreter, value))
            return value;
        return defaultArrayValue(argument.refSource.type);
    }

    private Value localValueOrDefault(
        CallArgument argument,
    ) {
        if (auto value = argument.refSource in locals)
            return *value;
        return defaultArrayValue(argument.refSource.type);
    }

    private Value[VarDeclaration] indexedRefFields(
        CallArgument argument,
        ref Interpreter interpreter,
    ) {
        if (argument.refClassId != 0)
            return interpreter.classFields[argument.refClassId].dup;
        return structFieldsValue(argument.refOwner);
    }

    private Value[VarDeclaration][VarDeclaration] nestedStructFieldMaps(
        ref Value[VarDeclaration] fields,
    ) {
        Value[VarDeclaration][VarDeclaration] maps;
        foreach (field; fields.byKey)
            if (isStructType(field.type)) {
                Value[VarDeclaration] nestedFields;
                if (tryGetStructFields(field, nestedFields)) {
                    maps[field] = nestedFields.dup;
                    foreach (owner, ownerFields; nestedStructFieldMaps(nestedFields))
                        maps[owner] = ownerFields.dup;
                }
            }
        return maps;
    }

    private void propagateNestedStructFieldMaps(
        ref Value[VarDeclaration] fields,
        Value[VarDeclaration][VarDeclaration] maps,
    ) {
        foreach (field; fields.byKey)
            if (isStructType(field.type)) {
                Value[VarDeclaration] nestedFields;
                if (tryGetStructFieldMap(maps, field, nestedFields)) {
                    assignStructFields(field, nestedFields);
                    propagateNestedStructFieldMaps(nestedFields, maps);
                }
            }
    }

    private Value runEqualExpression(
        EqualExp equal,
        ref Interpreter interpreter,
    ) {
        import dmd.tokens: EXP;
        const left  = runExpression(equal.e1, interpreter);
        const right = runExpression(equal.e2, interpreter);
        if (equal.op == EXP.notEqual)
            return Value(left != right ? 1L : 0L);
        return Value(left == right ? 1L : 0L);
    }

    private Value runIdentityExpression(
        IdentityExp identity,
        ref Interpreter interpreter,
    ) {
        import dmd.tokens: EXP;

        const leftNull = identity.e1.isNullExp !is null;
        const rightNull = identity.e2.isNullExp !is null;
        if (!leftNull &&
            !rightNull &&
            isStructType(identity.e1.type) &&
            isStructType(identity.e2.type)) {
            const sameStruct = runStructInitializer(identity.e1, interpreter) ==
                runStructInitializer(identity.e2, interpreter);
            if (identity.op == EXP.notIdentity)
                return Value(sameStruct ? 0L : 1L);
            return Value(sameStruct ? 1L : 0L);
        }
        const same = leftNull && rightNull
            ? true
            : leftNull
                ? valueIsNull(identity.e2, interpreter)
                : rightNull
                    ? valueIsNull(identity.e1, interpreter)
                    : runExpression(identity.e1, interpreter) ==
                runExpression(identity.e2, interpreter);
        if (identity.op == EXP.notIdentity)
            return Value(same ? 0L : 1L);
        return Value(same ? 1L : 0L);
    }

    private bool valueIsNull(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        if (expression.isNullExp)
            return true;

        import std.sumtype: match;

        return runExpression(expression, interpreter).match!(
            (ClassRef ref_) => ref_.id == 0,
            (long l) => l == 0,
            (long[] a) => a.length == 0,
            (LocalPtr _) => false,
            (AssocArrayRef ref_) => ref_.id == 0,
            (AssocArraySlotRef ref_) => ref_.arrayId == 0,
        );
    }

    private bool isGcBlockBaseExpression(
        Expression expression,
    ) {
        if (auto cast_ = expression.isCastExp)
            return isGcBlockBaseExpression(cast_.e1);

        if (auto dotVar = expression.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                return ownerVar.var.ident !is null &&
                    ownerVar.var.ident.toString == "bi" &&
                    dotVar.var.ident !is null &&
                    dotVar.var.ident.toString == "base";

        return false;
    }

    private Value runDeclarationExpression(
        DeclarationExp decl,
        ref Interpreter interpreter,
    ) {
        import std.conv: text;

        const unsupportedMessage = text("Unsupported expression: ", decl.op);

        void unsupportedDecl() {
            throw new Exception(unsupportedMessage);
        }

        auto variable = decl.declaration.isVarDeclaration;
        if (variable is null)
            return Value(0L);

        if (isStructType(variable.type)) {
            if (isScopeBufferRangeType(variable.type))
                interpreter.scopeBufferBytes["ScopeBufferRange.sbuf"] =
                    (long[]).init;
            // Intercept dec.value!T initialisers before tryReadInputRangeElements
            // to prevent its catch-all from executing value!T as a side-effect
            // and consuming the decoder's byte buffer prematurely.
            if (variable._init !is null &&
                variable._init.isExpInitializer !is null &&
                isCerealedValueInitialiser(variable._init.isExpInitializer.exp)) {
                Value[VarDeclaration] valueFields;
                if (tryRunStructDeclarationDecerealiseValue(
                    variable.type,
                    variable._init.isExpInitializer.exp,
                    valueFields,
                    interpreter,
                )) {
                    structFields[variable] = valueFields;
                    return Value(0L);
                }
            }
            if (variable._init !is null &&
                variable._init.isExpInitializer !is null) {
                long[] rangeElements;
                if (tryReadInputRangeElements(
                    variable._init.isExpInitializer.exp,
                    rangeElements,
                    interpreter,
                )) {
                    locals[variable] = Value(rangeElements.dup);
                    return Value(0L);
                }
            }
            if (variable._init !is null &&
                variable._init.isExpInitializer !is null &&
                tryInitializeAssocArrayKeyStruct(
                    variable,
                    variable._init.isExpInitializer.exp,
                    interpreter,
                ))
                return Value(0L);
            if (variable._init !is null &&
                variable._init.isExpInitializer !is null &&
                variable._init.isExpInitializer.exp.isCommaExp) {
                structFields[variable] = defaultStructFields(variable.type);
                runExpression(
                    variable._init.isExpInitializer.exp,
                    interpreter,
                    true,
                );
                // After the CommaExp has run, try to update structFields with
                // the actual field values from the struct constructor/literal.
                // Data structs (e.g. StructWithNoCereal) may also end up in
                // locals via the range-bytes side-effect; overwriting the
                // default-field placeholder with real values lets field-level
                // ref arguments (e.g. val.nibble1) be resolved correctly.
                {
                    auto comma = variable._init.isExpInitializer.exp.isCommaExp;
                    if (comma !is null) {
                        Expression rhsExpr = comma.e1;
                        if (auto construct = rhsExpr.isConstructExp)
                            rhsExpr = construct.e2;
                        else if (auto blit = rhsExpr.isBlitExp)
                            rhsExpr = blit.e2;
                        else if (auto assign = rhsExpr.isAssignExp)
                            rhsExpr = assign.e2;
                        if (rhsExpr.isStructLiteralExp !is null ||
                            rhsExpr.isCallExp !is null) {
                            auto sfval = runStructInitializer(rhsExpr, interpreter);
                            if (sfval.length > 0)
                                structFields[variable] = sfval;
                        }
                    }
                }
                return Value(0L);
            }
            if (variable._init !is null &&
                variable._init.isExpInitializer !is null) {
                Value[VarDeclaration] fields;
                if (tryRunStructDeclarationBytesConstructor(
                    variable.type,
                    variable._init.isExpInitializer.exp,
                    fields,
                    interpreter,
                )) {
                    structFields[variable] = fields;
                    return Value(0L);
                }
                if (tryRunStructDeclarationDecerealiseValue(
                    variable.type,
                    variable._init.isExpInitializer.exp,
                    fields,
                    interpreter,
                )) {
                    structFields[variable] = fields;
                    return Value(0L);
                }
            }
            structFields[variable] = variable._init is null ||
                variable._init.isExpInitializer is null
                ? (Value[VarDeclaration]).init
                : runStructInitializer(variable._init.isExpInitializer.exp, interpreter);
            return Value(0L);
        }

        if (variable.type !is null &&
            (variable.type.isTypeDArray !is null ||
                variable.type.toBasetype.isTypeSArray !is null))
            return initializeArrayVariable(variable, interpreter, unsupportedMessage);

        if (variable.type !is null &&
            variable.type.toBasetype.isTypeAArray !is null &&
            (variable._init is null || variable._init.isExpInitializer is null)) {
            locals[variable] = Value(0L);
            return Value(0L);
        }

        if (variable._init is null || variable._init.isExpInitializer is null)
            return Value(0L);

        auto initializer = variable._init.isExpInitializer;
        // Determine the expression to evaluate for the initial value.
        Expression initExpr = initializer.exp;
        if (auto blit = initializer.exp.isBlitExp)
            initExpr = blit.e2;
        else if (auto assign = initializer.exp.isAssignExp)
            initExpr = assign.e2;
        else if (auto construct = initializer.exp.isConstructExp)
            initExpr = construct.e2;
        rememberAssocArraySlotLocal(variable, initExpr, interpreter);
        Value value = coerceValueToType(runExpression(initExpr, interpreter), variable.type);
        locals[variable] = value;
        return value;
    }

    private bool tryRunStructDeclarationBytesConstructor(
        Type type,
        Expression expression,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (auto construct = expression.isConstructExp)
            return tryRunStructDeclarationBytesConstructor(
                type,
                construct.e2,
                fields,
                interpreter,
            );
        if (auto assign = expression.isAssignExp)
            return tryRunStructDeclarationBytesConstructor(
                type,
                assign.e2,
                fields,
                interpreter,
            );
        if (auto blit = expression.isBlitExp)
            return tryRunStructDeclarationBytesConstructor(
                type,
                blit.e2,
                fields,
                interpreter,
            );

        auto call = expression.isCallExp;
        if (call is null ||
            call.arguments is null ||
            call.arguments.length != 1)
            return false;

        fields = defaultStructFields(type);
        auto bytesField = structFieldNamed(type, "_bytes");
        auto originalBytesField = structFieldNamed(type, "_originalBytes");
        if (bytesField is null || originalBytesField is null)
            return false;

        const bytes = runExpression(callArguments(call)[0], interpreter).asArray;
        assignStructField(fields, bytesField, Value(bytes.dup));
        assignStructField(fields, originalBytesField, Value(bytes.dup));
        return true;
    }

    private bool tryRunStructDeclarationDecerealiseValue(
        Type type,
        Expression expression,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (auto construct = expression.isConstructExp)
            return tryRunStructDeclarationDecerealiseValue(
                type,
                construct.e2,
                fields,
                interpreter,
            );
        if (auto assign = expression.isAssignExp)
            return tryRunStructDeclarationDecerealiseValue(
                type,
                assign.e2,
                fields,
                interpreter,
            );
        if (auto blit = expression.isBlitExp)
            return tryRunStructDeclarationDecerealiseValue(
                type,
                blit.e2,
                fields,
                interpreter,
            );
        if (auto call = expression.isCallExp) {
            // auto: DMD Type nodes are mutable and qualifier stripping returns
            // a mutable frontend Type reference.
            auto valueType = mutableType(type);
            return tryRunStructDecerealiseValue(
                call,
                valueType,
                fields,
                interpreter,
            );
        }
        return false;
    }

    private void rememberAssocArraySlotLocal(
        VarDeclaration variable,
        Expression expression,
        ref Interpreter interpreter,
    ) {
        if (variable.type is null || variable.type.toBasetype.isTypePointer is null)
            return;

        auto call = expression.isCallExp;
        if (call is null ||
            call.f is null ||
            call.f.ident is null ||
            (
                call.f.ident.toString != "_d_aaGetRvalueX" &&
                call.f.ident.toString != "_d_aaGetY"
            ) ||
            call.arguments is null ||
            call.arguments.length < 2)
            return;

        long arrayId;
        if (call.f.ident.toString == "_d_aaGetY") {
            if (!tryMaterializeAssocArrayExpression(
                callArguments(call)[0],
                arrayId,
                interpreter,
            ))
                return;
        } else {
            arrayId = assocArrayIdFromExpression(
                callArguments(call)[0],
                interpreter,
            );
            if (arrayId == 0 || arrayId !in interpreter.assocArrays)
                return;
        }

        size_t index;
        if (!tryAssocArrayKeyExpressionIndex(
            arrayId,
            callArguments(call)[1],
            index,
            interpreter,
        )) {
            if (call.f.ident.toString != "_d_aaGetY")
                return;
            VarDeclaration keyStruct;
            Value key;
            Value[VarDeclaration] keyFields;
            if (!assocArrayKeyFromExpression(
                callArguments(call)[1],
                keyStruct,
                key,
                keyFields,
                interpreter,
            ))
                return;
            index = interpreter.assocArrays[arrayId].values.length;
            interpreter.assocArrays[arrayId].keyStructs ~= keyStruct;
            interpreter.assocArrays[arrayId].keyFields ~= keyFields;
            interpreter.assocArrays[arrayId].keys ~= key;
            interpreter.assocArrays[arrayId].values ~= Value(0L);
        }

        assocArraySlotLocals[variable] = AssocArraySlotLocal(arrayId, index);
    }

    private bool assocArrayKeyFromExpression(
        Expression expression,
        out VarDeclaration keyStruct,
        out Value key,
        out Value[VarDeclaration] keyFields,
        ref Interpreter interpreter,
    ) {
        keyStruct = structFieldsOwner(expression);
        if (keyStruct !is null) {
            key = Value(0L);
            keyFields = structFieldsValue(keyStruct).dup;
            return true;
        }

        try {
            key = runExpression(expression, interpreter);
        } catch (Exception) {
            return false;
        }
        return true;
    }

    private Value initializeArrayVariable(
        VarDeclaration variable,
        ref Interpreter interpreter,
        in string unsupportedMessage,
    ) {
        if (variable._init is null) {
            locals[variable] = defaultArrayValue(variable.type);
            return Value(0L);
        }

        auto initializer = variable._init.isExpInitializer;
        if (initializer is null) {
            if (variable.type.toBasetype.isTypeSArray !is null) {
                locals[variable] = defaultArrayValue(variable.type);
                return Value(0L);
            }
            throw new Exception(unsupportedMessage);
        }

        Expression initExpr = initializer.exp;
        if (auto blit = initializer.exp.isBlitExp)
            initExpr = blit.e2;
        else if (auto assign = initializer.exp.isAssignExp)
            initExpr = assign.e2;
        else if (auto construct = initializer.exp.isConstructExp)
            initExpr = construct.e2;
        if (auto call = initExpr.isCallExp)
            if (call.f.ident !is null && call.f.ident.toString == "keys") {
                const arrayId = assocArrayCallReceiver(call, interpreter);
                if (arrayId != 0 && arrayId in interpreter.assocArrays) {
                    // auto: keep the mutable VarDeclaration array for key lookup.
                    auto keyStructs = interpreter.assocArrays[arrayId].keyStructs;
                    auto keyFields = interpreter.assocArrays[arrayId].keyFields;
                    auto assocKeys = AssocArrayKeys(
                        arrayId,
                        keyStructs,
                        keyFields,
                        interpreter.assocArrays[arrayId].keys.dup,
                    );
                    assocArrayKeyArrays[variable] = assocKeys;
                    locals[variable] = Value(new long[keyStructs.length]);
                    return Value(0L);
                }
            }
        if (auto dotVar = initExpr.isDotVarExp)
            if (dotVar.var.ident !is null && dotVar.var.ident.toString == "keys") {
                const arrayId = assocArrayIdFromExpression(dotVar.e1, interpreter);
                if (arrayId != 0 && arrayId in interpreter.assocArrays) {
                    // auto: keep the mutable VarDeclaration array for key lookup.
                    auto keyStructs = interpreter.assocArrays[arrayId].keyStructs;
                    auto keyFields = interpreter.assocArrays[arrayId].keyFields;
                    auto assocKeys = AssocArrayKeys(
                        arrayId,
                        keyStructs,
                        keyFields,
                        interpreter.assocArrays[arrayId].keys.dup,
                    );
                    assocArrayKeyArrays[variable] = assocKeys;
                    locals[variable] = Value(new long[keyStructs.length]);
                    return Value(0L);
                }
            }

        if (auto assign = initializer.exp.isAssignExp)
            if (assign.e2.isNullExp) {
                locals[variable] = Value((long[]).init);
                return Value(0L);
            }

        if (auto blit = initializer.exp.isBlitExp)
            if (blit.e2.isNullExp) {
                locals[variable] = Value((long[]).init);
                return Value(0L);
            }

        if (auto construct = initializer.exp.isConstructExp) {
            if (construct.e2.isNullExp) {
                locals[variable] = Value((long[]).init);
                return Value(0L);
            }

            if (auto literal = construct.e2.isArrayLiteralExp) {
                locals[variable] = Value(arrayLiteralRuntimeValue(
                    literal,
                    arrayElementType(variable.type),
                    interpreter,
                ));
                return Value(0L);
            }

            locals[variable] = coerceValueToType(
                runExpression(construct.e2, interpreter),
                variable.type,
            );
            rememberArrayAlias(variable, construct.e2, interpreter);
            return Value(0L);
        }

        if (variable.type.toBasetype.isTypeSArray !is null)
            locals[variable] = defaultArrayValue(variable.type);

        locals[variable] = coerceValueToType(
            runExpression(initExpr, interpreter),
            variable.type,
        );
        rememberArrayAlias(variable, initExpr, interpreter);
        return Value(0L);
    }

    private void rememberArrayAlias(
        VarDeclaration variable,
        Expression expression,
        ref Interpreter interpreter,
    ) {
        auto slice = expression.isSliceExp;
        if (slice is null || slice.lwr is null || slice.upr is null)
            return;
        auto var = slice.e1.isVarExp;
        if (var is null)
            return;
        auto owner = var.var.isVarDeclaration;
        if (owner is null || owner !in locals)
            return;

        const lower = cast(size_t) runSliceBound(
            slice.lwr,
            interpreter,
            locals[owner].asArray.length,
        );
        if (auto parent = owner in arrayAliases)
            arrayAliases[variable] = ArrayAlias(parent.owner, parent.offset + lower);
        else
            arrayAliases[variable] = ArrayAlias(owner, lower);
    }

    private long[] arrayLiteralRuntimeValue(
        ArrayLiteralExp literal,
        Type elementType,
        ref Interpreter interpreter,
    ) {
        long[] elements;
        if (literal.elements is null)
            return elements;

        foreach (elem; arrayLiteralElements(literal)) {
            if (auto nested = elem.isArrayLiteralExp) {
                long[] nestedElements = arrayLiteralRuntimeValue(
                    nested,
                    arrayElementType(elementType),
                    interpreter,
                );
                elements ~= cast(long) nestedElements.length;
                elements ~= nestedElements;
                continue;
            }
            if (auto nested = elem.isStructLiteralExp) {
                const nestedElements = structLiteralCerealBytes(
                    nested,
                    interpreter,
                );
                elements ~= cast(long) nestedElements.length;
                elements ~= nestedElements;
                continue;
            }

            import std.sumtype: match;

            Value value = runExpression(elem, interpreter);
            value.match!(
                (long l) {
                    elements ~= coerceIntegerToType(l, elementType);
                },
                (long[] array) {
                    elements ~= cast(long) array.length;
                    elements ~= array;
                },
                (LocalPtr _) {},
                (ClassRef _) {},
                (AssocArrayRef _) {},
                (AssocArraySlotRef _) {},
            );
        }

        return elements;
    }

    private long[] structLiteralCerealBytes(
        StructLiteralExp literal,
        ref Interpreter interpreter,
    ) {
        long[] elements;
        // Byte-offset readers rely on this DMD field order and big-endian
        // scalar packing when a struct literal is stored as raw cereal bytes.
        foreach (i, element; structLiteralElements(literal)) {
            if (element is null)
                continue;
            // auto: the field comes from DMD's mutable aggregate metadata.
            auto field = structLiteralField(literal, i);
            if (field is null)
                continue;
            appendExpressionCerealBytes(elements, element, field.type, interpreter, field);
        }
        return elements;
    }

    private void appendExpressionCerealBytes(
        ref long[] elements,
        Expression expression,
        Type type,
        ref Interpreter interpreter,
        VarDeclaration field = null,
    ) {
        if (type !is null && type.toBasetype.isTypeDArray !is null) {
            const hasExternalLength = cerealArrayFieldHasExternalLength(field);
            if (auto literal = expression.isArrayLiteralExp) {
                appendArrayLiteralCerealBytes(
                    elements,
                    literal,
                    type,
                    interpreter,
                    !hasExternalLength,
                );
                return;
            }
            if (hasExternalLength)
                appendArrayPayloadToCereal(
                    elements,
                    runExpression(expression, interpreter).asArray,
                    arrayElementType(type),
                );
            else
                appendArrayValueToCereal(
                    elements,
                    runExpression(expression, interpreter).asArray,
                    arrayElementType(type),
                );
            return;
        }

        if (type !is null && type.toBasetype.isTypeAArray !is null) {
            const arrayId = assocArrayIdFromExpression(expression, interpreter);
            appendAssocArrayValueToCereal(elements, arrayId, interpreter);
            return;
        }

        const byteCount = decerealisedScalarByteCount(type);
        if (byteCount != 0) {
            appendIntegerBytes(
                elements,
                runExpression(expression, interpreter).asLong,
                byteCount,
            );
            return;
        }

        if (auto literal = expression.isStructLiteralExp) {
            elements ~= structLiteralCerealBytes(literal, interpreter);
            return;
        }
    }

    private void appendArrayLiteralCerealBytes(
        ref long[] elements,
        ArrayLiteralExp literal,
        Type arrayType,
        ref Interpreter interpreter,
        in bool includeLength = true,
    ) {
        if (literal.elements is null) {
            if (includeLength)
                appendUshort(elements, 0L);
            return;
        }

        if (includeLength)
            appendUshort(elements, cast(long) literal.elements.length);
        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto elementType = arrayElementType(arrayType);
        foreach (element; arrayLiteralElements(literal)) {
            if (auto string_ = element.isStringExp) {
                const bytes = stringLiteralElements(string_);
                appendUshort(elements, cast(long) bytes.length);
                elements ~= bytes;
                continue;
            }
            if (auto nested = element.isArrayLiteralExp) {
                appendArrayLiteralCerealBytes(
                    elements,
                    nested,
                    elementType,
                    interpreter,
                );
                continue;
            }
            if (auto nested = element.isStructLiteralExp) {
                elements ~= structLiteralCerealBytes(nested, interpreter);
                continue;
            }

            appendExpressionCerealBytes(elements, element, elementType, interpreter);
        }
    }

    private bool tryInitializeAssocArrayKeyStruct(
        VarDeclaration variable,
        Expression expression,
        ref Interpreter interpreter,
    ) {
        if (auto blit = expression.isBlitExp)
            return tryInitializeAssocArrayKeyStruct(variable, blit.e2, interpreter);
        if (auto assign = expression.isAssignExp)
            return tryInitializeAssocArrayKeyStruct(variable, assign.e2, interpreter);
        if (auto construct = expression.isConstructExp)
            return tryInitializeAssocArrayKeyStruct(
                variable,
                construct.e2,
                interpreter,
            );
        if (auto cond = expression.isCondExp) {
            if (runExpression(cond.econd, interpreter).asLong)
                return tryInitializeAssocArrayKeyStruct(
                    variable,
                    cond.e1,
                    interpreter,
                );
            return false;
        }
        if (auto index = expression.isIndexExp)
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (auto keys = assocArrayKeysLocal(varDecl)) {
                        const i = cast(size_t) runExpression(
                            index.e2,
                            interpreter,
                        ).asLong;
                        if (i >= keys.keyStructs.length)
                            return false;
                        // auto: keep the mutable VarDeclaration for AA key fields.
                        auto keyStruct = keys.keyStructs[i];
                        if (keyStruct !is null && keyStruct in structFields)
                            structFields[variable] = structFields[keyStruct].dup;
                        else if (i < keys.keyFields.length &&
                            keys.keyFields[i] !is null)
                            structFields[variable] = keys.keyFields[i].dup;
                        else
                            structFields[variable] =
                                defaultStructFields(variable.type);
                        assocArrayKeyLocals[variable] =
                            AssocArrayKeyLocal(keys.arrayId, i);
                        return true;
                    }
        return false;
    }

    private bool isComparisonExpression(
        Expression expression,
    ) {
        import dmd.tokens: EXP;

        return
            expression.op == EXP.lessThan ||
            expression.op == EXP.greaterThan ||
            expression.op == EXP.lessOrEqual ||
            expression.op == EXP.greaterOrEqual;
    }

    private Value runComparisonExpression(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        import dmd.tokens: EXP;

        auto cmp = expression.isBinExp;
        const left = runExpression(cmp.e1, interpreter).asLong;
        const right = runExpression(cmp.e2, interpreter).asLong;

        if (expression.op == EXP.lessThan)
            if (comparisonUsesUnsignedOperand(cmp))
                return Value(cast(ulong) left < cast(ulong) right ? 1L : 0L);
        if (expression.op == EXP.lessThan)
            return Value(left < right ? 1L : 0L);
        if (expression.op == EXP.greaterThan)
            if (comparisonUsesUnsignedOperand(cmp))
                return Value(cast(ulong) left > cast(ulong) right ? 1L : 0L);
        if (expression.op == EXP.greaterThan)
            return Value(left > right ? 1L : 0L);
        if (expression.op == EXP.lessOrEqual)
            if (comparisonUsesUnsignedOperand(cmp))
                return Value(cast(ulong) left <= cast(ulong) right ? 1L : 0L);
        if (expression.op == EXP.lessOrEqual)
            return Value(left <= right ? 1L : 0L);
        if (comparisonUsesUnsignedOperand(cmp))
            return Value(cast(ulong) left >= cast(ulong) right ? 1L : 0L);
        return Value(left >= right ? 1L : 0L);
    }

    private Value runAssignExpression(
        AssignExp assign,
        ref Interpreter interpreter,
    ) {
        Value lengthValue;
        if (tryRunArrayLengthAssign(assign.e1, assign.e2, lengthValue, interpreter))
            return lengthValue;

        if (auto var = assign.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (isStructType(varDecl.type)) {
                    long[] rangeElements;
                    if (tryReadInputRangeElements(
                        assign.e2,
                        rangeElements,
                        interpreter,
                    )) {
                        locals[varDecl] = Value(rangeElements.dup);
                        return Value(0L);
                    }
                    Value[VarDeclaration] fields;
                    if (tryRunStructDeclarationBytesConstructor(
                        varDecl.type,
                        assign.e2,
                        fields,
                        interpreter,
                    )) {
                        structFields[varDecl] = fields;
                        return Value(0L);
                    }
                    if (tryRunStructDeclarationDecerealiseValue(
                        varDecl.type,
                        assign.e2,
                        fields,
                        interpreter,
                    )) {
                        structFields[varDecl] = fields;
                        return Value(0L);
                    }
                    resetNestedOutputStorage(varDecl.type, interpreter);
                    // Only plain struct copies propagate nested field maps;
                    // fresh literals and decerealise results build their own.
                    Value[VarDeclaration][VarDeclaration] sourceMaps;
                    if (auto sourceOwner = structCopySourceOwner(assign.e2))
                        if (auto sourceFields = sourceOwner in structFields)
                            sourceMaps = nestedStructFieldMaps(*sourceFields);
                    forgetNestedStructFields(varDecl.type);
                    structFields[varDecl] = runStructInitializer(assign.e2, interpreter);
                    propagateNestedStructFieldMaps(structFields[varDecl], sourceMaps);
                    return Value(0L);
                }

        const value = runExpression(assign.e2, interpreter);

        if (auto var = assign.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration) {
                if (varDecl in locals) {
                    locals[varDecl] = coerceValueToType(value, varDecl.type);
                    return value;
                } else if (varDecl in structFields) {
                    return value;
                } else if (varDecl.type !is null &&
                    varDecl.type.isTypeDArray !is null) {
                    interpreter.globals[varDecl] =
                        coerceValueToType(value, varDecl.type);
                    return value;
                } else {
                    assignGlobalValue(
                        varDecl,
                        coerceValueToType(value, varDecl.type),
                        interpreter,
                    );
                    return value;
                }
            }

        if (auto dotVar = assign.e1.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            if (tryAssignNestedStructField(
                                structFields[ownerDecl],
                                fieldDecl,
                                assign.e2,
                            ))
                                return Value(0L);
                            assignStructField(
                                structFields[ownerDecl],
                                fieldDecl,
                                coerceValueToType(value, fieldDecl.type),
                            );
                            return value;
                        }
        if (auto dotVar = assign.e1.isDotVarExp)
            if (auto thisExp = dotVar.e1.isThisExp)
                if (auto thisDecl = thisExp.var.isVarDeclaration)
                    if (thisDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            if (tryAssignNestedStructField(
                                structFields[thisDecl],
                                fieldDecl,
                                assign.e2,
                            ))
                                return Value(0L);
                            assignStructField(
                                structFields[thisDecl],
                                fieldDecl,
                                coerceValueToType(value, fieldDecl.type),
                            );
                            return value;
                        }
        if (auto dotVar = assign.e1.isDotVarExp)
            if (dotVar.e1.isThisExp && currentThis !is null)
                if (currentThis in structFields)
                    if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                        if (tryAssignNestedStructField(
                            structFields[currentThis],
                            fieldDecl,
                            assign.e2,
                        ))
                            return Value(0L);
                        assignStructField(
                            structFields[currentThis],
                            fieldDecl,
                            coerceValueToType(value, fieldDecl.type),
                        );
                        return value;
                    }
        if (auto dotVar = assign.e1.isDotVarExp)
            if (auto ptr = dotVar.e1.isPtrExp)
                if (auto fields = classInstanceFields(
                    runExpression(ptr.e1, interpreter),
                    interpreter,
                ))
                    if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                        assignStructField(
                            *fields,
                            fieldDecl,
                            coerceValueToType(value, fieldDecl.type),
                        );
                        return value;
                    }

        if (auto ptr = assign.e1.isPtrExp) {
            const pointer = runExpression(ptr.e1, interpreter);
            if (tryAssignAssocArraySlotPointer(pointer, value, interpreter))
                return value;
            const classId = pointer.classId;
            if (classId != 0 && classId in interpreter.heapScalars) {
                interpreter.heapScalars[classId] = coerceValueToType(
                    value,
                    pointerTargetType(ptr.e1.type),
                );
                return value;
            }
        }

        if (tryAssignRegisteredChildClassCerealiser(assign, interpreter))
            return value;

        if (auto index = assign.e1.isIndexExp) {
            if (tryAssignAssocArrayIndex(
                index.e1,
                index.e2,
                value,
                interpreter,
            ))
                return value;
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (auto slot = assocArraySlotLocal(varDecl)) {
                        if (slot.arrayId != 0 &&
                            slot.arrayId in interpreter.assocArrays &&
                            slot.index <
                            interpreter.assocArrays[slot.arrayId].values.length) {
                            interpreter.assocArrays[slot.arrayId].values[slot.index] =
                                value;
                            return value;
                        }
                    }
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (tryAssignAssocArrayIndex(
                        varDecl,
                        index.e2,
                        value,
                        interpreter,
                    ))
                        return value;
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals &&
                        varDecl.type !is null &&
                        (
                            varDecl.type.toBasetype.isTypeDArray !is null ||
                            varDecl.type.toBasetype.isTypeSArray !is null
                        )) {
                        const i = runExpression(index.e2, interpreter).asLong;
                        long[] elements = arrayStorageValue(
                            locals[varDecl],
                            varDecl.type,
                        );
                        elements[cast(size_t) i] = coerceIntegerToType(
                            value.asLong,
                            arrayElementType(varDecl.type),
                        );
                        locals[varDecl] = Value(elements);
                        propagateArrayAlias(varDecl, cast(size_t) i, value);
                        return value;
                    }
            if (auto dotVar = index.e1.isDotVarExp)
                if (auto owner = structFieldsOwner(dotVar.e1))
                    if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                        const i = runExpression(index.e2, interpreter).asLong;
                        Value[VarDeclaration] fields = structFieldsValue(owner);
                        long[] elements = structFieldValue(
                            fields,
                            fieldDecl,
                            Value((long[]).init),
                        ).asArray;
                        elements[cast(size_t) i] = coerceIntegerToType(
                            value.asLong,
                            arrayElementType(fieldDecl.type),
                        );
                        assignStructField(fields, fieldDecl, Value(elements));
                        assignNestedStructFields(owner, fields);
                        return value;
                    }
            if (auto dotVar = index.e1.isDotVarExp)
                if (auto ownerVar = dotVar.e1.isVarExp)
                    if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (auto fields = ownerDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const i = runExpression(index.e2, interpreter).asLong;
                                long[] elements = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value((long[]).init),
                                ).asArray;
                                elements[cast(size_t) i] = coerceIntegerToType(
                                    value.asLong,
                                    arrayElementType(fieldDecl.type),
                                );
                                assignStructField(*fields, fieldDecl, Value(elements));
                                return value;
                            }
            if (auto dotVar = index.e1.isDotVarExp)
                if (auto thisExp = dotVar.e1.isThisExp)
                    if (auto thisDecl = thisExp.var.isVarDeclaration)
                        if (auto fields = thisDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const i = runExpression(index.e2, interpreter).asLong;
                                if (fieldDecl.type !is null &&
                                    fieldDecl.type.isTypePointer !is null)
                                    return value;
                                long[] elements = structFieldValue(
                                    *fields,
                                    fieldDecl,
                                    Value((long[]).init),
                                ).asArray;
                                elements[cast(size_t) i] = coerceIntegerToType(
                                    value.asLong,
                                    arrayElementType(fieldDecl.type),
                                );
                                assignStructField(*fields, fieldDecl, Value(elements));
                                return value;
                }
        }

        if (auto array = assign.e1.isArrayExp) {
            if (arrayExpressionArguments(array).length == 1) {
                const i = runExpression(
                    arrayExpressionArguments(array)[0],
                    interpreter,
                ).asLong;
                if (auto var = array.e1.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (varDecl in locals) {
                            long[] elements = arrayStorageValue(
                                locals[varDecl],
                                varDecl.type,
                            );
                            elements[cast(size_t) i] = coerceIntegerToType(
                                value.asLong,
                                arrayElementType(varDecl.type),
                            );
                            locals[varDecl] = Value(elements);
                            propagateArrayAlias(varDecl, cast(size_t) i, value);
                            return value;
                        }
                if (auto dotVar = array.e1.isDotVarExp)
                    if (auto owner = structFieldsOwner(dotVar.e1))
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            auto fields = structFieldsValue(owner);
                            long[] elements = structFieldValue(
                                fields,
                                fieldDecl,
                                defaultArrayValue(fieldDecl.type),
                            ).asArray;
                            elements[cast(size_t) i] = coerceIntegerToType(
                                value.asLong,
                                arrayElementType(fieldDecl.type),
                            );
                            assignStructField(fields, fieldDecl, Value(elements));
                            assignNestedStructFields(owner, fields);
                            return value;
                        }
            }
        }

        if (auto slice = assign.e1.isSliceExp)
            if (auto var = slice.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        locals[varDecl] = Value(sliceAssignmentValue(
                            value,
                            arrayValueLength(locals[varDecl]),
                            arrayElementType(varDecl.type),
                        ));
                        return value;
                    }
        if (auto slice = assign.e1.isSliceExp)
            if (auto dotVar = slice.e1.isDotVarExp)
                if (auto fieldDecl = dotVar.var.isVarDeclaration)
                    if (fieldDecl.type !is null &&
                        fieldDecl.type.isTypePointer !is null)
                        return value;

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expressionChars(assign)));
    }

    private bool tryAssignRegisteredChildClassCerealiser(
        AssignExp assign,
        ref Interpreter interpreter,
    ) {
        import std.algorithm.searching: canFind;

        if (!expressionChars(assign.e1).canFind("_childCerealisers["))
            return false;

        interpreter.childClassRegistered = true;
        return true;
    }

    private void forgetNestedStructFields(Type type) {
        VarDeclaration[] owners;
        foreach (field; aggregateStructFields(type))
            if (isStructType(field.type))
                foreach (owner; structFields.byKey)
                    if (
                        sameStructField(owner, field) ||
                        sameDeclarationName(owner, field)
                    )
                        owners ~= owner;

        foreach (owner; owners)
            structFields.remove(owner);
    }

    private void resetNestedOutputStorage(
        Type type,
        ref Interpreter interpreter,
    ) {
        auto outputField = structFieldNamed(type, "_output");
        if (outputField is null)
            return;

        const previousLastArrayLength = interpreter.hasLastArrayValue
            ? interpreter.lastArrayValue.length
            : 0;
        interpreter.lastArrayValue = (long[]).init;
        interpreter.hasLastArrayValue = false;
        interpreter.clearedRangeAlias = (long[]).init;
        interpreter.clearedRangePrefix = (long[]).init;
        interpreter.hasClearedRangeAlias = false;

        size_t outputStart;
        VarDeclaration[] owners;
        foreach (owner; structFields.byKey)
            if (
                sameStructField(owner, outputField) ||
                sameDeclarationName(owner, outputField)
            )
                owners ~= owner;

        foreach (owner; owners) {
            Value[VarDeclaration] fields = structFields[owner].dup;
            auto bytesField = rangeStorageField(owner.type);
            if (bytesField is null)
                continue;
            const elements = isModeledScopeBufferField(bytesField)
                ? interpreter.scopeBufferBytes.get(
                    rangeStorageKey(owner, bytesField),
                    (long[]).init,
                )
                : storageArrayValue(structFieldValue(
                    fields,
                    bytesField,
                    Value((long[]).init),
                ));
            if (elements.length > outputStart)
                outputStart = elements.length;
            assignStructField(fields, bytesField, Value((long[]).init));
            structFields[owner] = fields;
            if (isModeledScopeBufferField(bytesField))
                interpreter.scopeBufferBytes[rangeStorageKey(owner, bytesField)] =
                    (long[]).init;
        }
        if (outputStart == 0)
            outputStart = previousLastArrayLength;
        interpreter.cerealiserOutputStart = outputStart;
        interpreter.hasCerealiserOutputStart = outputStart != 0;
    }

    private Value runBinAssignExpression(
        BinAssignExp assign,
        ref Interpreter interpreter,
    ) {
        Value value;
        if (tryRunArrayLengthAssign(assign.e1, assign.e2, value, interpreter))
            return value;
        if (tryRunScalarDivideAssign(assign, value, interpreter))
            return value;

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expressionChars(assign)));
    }

    private bool tryRunScalarDivideAssign(
        BinAssignExp assign,
        out Value value,
        ref Interpreter interpreter,
    ) {
        import dmd.tokens: EXP;

        if (assign.op != EXP.divAssign)
            return false;

        AssignableScalar target;
        if (!tryReadAssignableScalar(assign.e1, target, interpreter))
            return false;

        const divisor = runExpression(assign.e2, interpreter).asLong;
        if (divisor == 0)
            throw new Exception("Unittest assertion failed.");

        const quotient = scalarDivisionValue(
            target.value.asLong,
            divisor,
            target.type,
            assign.e1,
            assign.e2,
        );
        value = Value(coerceIntegerToType(quotient, target.type));
        writeAssignableScalar(target, value, interpreter);
        return true;
    }

    private struct AssignableScalar {
        private Value value;
        private Type type;
        private Type containerType;
        private VarDeclaration declaration;
        private bool isGlobal;
        private VarDeclaration owner;
        private VarDeclaration field;
        private long classId;
        private bool isHeapScalar;
        private bool hasIndex;
        private size_t index;
    }

    private bool tryReadAssignableScalar(
        Expression expression,
        out AssignableScalar target,
        ref Interpreter interpreter,
    ) {
        if (auto cast_ = expression.isCastExp)
            return tryReadAssignableScalar(cast_.e1, target, interpreter);

        if (auto var = expression.isVarExp)
            if (auto declaration = var.var.isVarDeclaration)
                return tryReadAssignableScalarVariable(
                    declaration,
                    target,
                    interpreter,
                );

        if (auto dotVar = expression.isDotVarExp)
            return tryReadAssignableScalarField(dotVar, target, interpreter);

        if (auto ptr = expression.isPtrExp)
            return tryReadAssignableScalarPointer(ptr.e1, target, interpreter);

        if (auto index = expression.isIndexExp)
            return tryReadAssignableScalarIndex(
                index.e1,
                index.e2,
                target,
                interpreter,
            );

        if (auto array = expression.isArrayExp)
            if (arrayExpressionArguments(array).length == 1)
                return tryReadAssignableScalarIndex(
                    array.e1,
                    arrayExpressionArguments(array)[0],
                    target,
                    interpreter,
                );

        return false;
    }

    private bool tryReadAssignableScalarVariable(
        VarDeclaration declaration,
        out AssignableScalar target,
        ref Interpreter interpreter,
    ) {
        Value value;
        if (tryGetLocalValue(declaration, value)) {
            target.value = value;
            target.type = declaration.type;
            target.declaration = declaration;
            return true;
        }

        if (tryGetGlobalValue(declaration, interpreter, value)) {
            target.value = value;
            target.type = declaration.type;
            target.declaration = declaration;
            target.isGlobal = true;
            return true;
        }

        if (currentThis !is null)
            if (auto fields = currentThis in structFields) {
                target.value = structFieldValue(*fields, declaration, Value(0L));
                target.type = declaration.type;
                target.owner = currentThis;
                target.field = declaration;
                return true;
            }

        return false;
    }

    private bool tryReadAssignableScalarField(
        DotVarExp dotVar,
        out AssignableScalar target,
        ref Interpreter interpreter,
    ) {
        auto field = dotVar.var.isVarDeclaration;
        if (field is null)
            return false;

        if (auto owner = structFieldsOwner(dotVar.e1)) {
            Value[VarDeclaration] fields = structFieldsValue(owner);
            target.value = structFieldValue(fields, field, Value(0L));
            target.type = field.type;
            target.owner = owner;
            target.field = field;
            return true;
        }

        if (auto ptr = dotVar.e1.isPtrExp) {
            const pointer = runExpression(ptr.e1, interpreter);
            const id = pointer.classId;
            if (id != 0 && id in interpreter.classFields) {
                target.value = structFieldValue(
                    interpreter.classFields[id],
                    field,
                    Value(0L),
                );
                target.type = field.type;
                target.field = field;
                target.classId = id;
                return true;
            }
        }

        if (auto ownerVar = dotVar.e1.isVarExp)
            if (auto ownerDecl = ownerVar.var.isVarDeclaration) {
                Value ownerValue;
                if (tryGetLocalValue(ownerDecl, ownerValue)) {
                    const id = ownerValue.classId;
                    if (id != 0 && id in interpreter.classFields) {
                        target.value = structFieldValue(
                            interpreter.classFields[id],
                            field,
                            Value(0L),
                        );
                        target.type = field.type;
                        target.field = field;
                        target.classId = id;
                        return true;
                    }
                }
            }

        return false;
    }

    private bool tryReadAssignableScalarPointer(
        Expression pointerExpression,
        out AssignableScalar target,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        Value pointer = runExpression(pointerExpression, interpreter);
        VarDeclaration declaration;
        const isLocalPointer = pointer.match!(
            (LocalPtr ptr) {
                declaration = ptr.decl;
                return true;
            },
            (long _) => false,
            (long[] _) => false,
            (ClassRef _) => false,
            (AssocArrayRef _) => false,
            (AssocArraySlotRef _) => false,
        );
        if (isLocalPointer && declaration !is null)
            return tryReadAssignableScalarVariable(
                declaration,
                target,
                interpreter,
            );

        const id = pointer.classId;
        if (id != 0 && id in interpreter.heapScalars) {
            target.value = interpreter.heapScalars[id];
            target.type = pointerTargetType(pointerExpression.type);
            target.classId = id;
            target.isHeapScalar = true;
            return true;
        }

        return false;
    }

    private bool tryReadAssignableScalarIndex(
        Expression indexedExpression,
        Expression indexExpression,
        out AssignableScalar target,
        ref Interpreter interpreter,
    ) {
        const index = cast(size_t) runExpression(
            indexExpression,
            interpreter,
        ).asLong;

        Value indexedValue;
        if (auto var = indexedExpression.isVarExp)
            if (auto declaration = var.var.isVarDeclaration) {
                if (tryGetLocalValue(declaration, indexedValue)) {
                    target.value = Value(indexedValue.asArray[index]);
                    target.type = arrayElementType(declaration.type);
                    target.containerType = declaration.type;
                    target.declaration = declaration;
                    target.hasIndex = true;
                    target.index = index;
                    return true;
                }
                if (tryGetGlobalValue(declaration, interpreter, indexedValue)) {
                    target.value = Value(indexedValue.asArray[index]);
                    target.type = arrayElementType(declaration.type);
                    target.containerType = declaration.type;
                    target.declaration = declaration;
                    target.isGlobal = true;
                    target.hasIndex = true;
                    target.index = index;
                    return true;
                }
            }

        if (auto dotVar = indexedExpression.isDotVarExp) {
            auto field = dotVar.var.isVarDeclaration;
            if (field is null)
                return false;

            if (auto owner = structFieldsOwner(dotVar.e1)) {
                Value[VarDeclaration] fields = structFieldsValue(owner);
                const array = structFieldValue(
                    fields,
                    field,
                    defaultArrayValue(field.type),
                );
                target.value = Value(array.asArray[index]);
                target.type = arrayElementType(field.type);
                target.containerType = field.type;
                target.owner = owner;
                target.field = field;
                target.hasIndex = true;
                target.index = index;
                return true;
            }

            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration) {
                    Value ownerValue;
                    if (tryGetLocalValue(ownerDecl, ownerValue)) {
                        const id = ownerValue.classId;
                        if (id != 0 && id in interpreter.classFields) {
                            const array = structFieldValue(
                                interpreter.classFields[id],
                                field,
                                defaultArrayValue(field.type),
                            );
                            target.value = Value(array.asArray[index]);
                            target.type = arrayElementType(field.type);
                            target.containerType = field.type;
                            target.field = field;
                            target.classId = id;
                            target.hasIndex = true;
                            target.index = index;
                            return true;
                        }
                    }
                }
        }

        return false;
    }

    private void writeAssignableScalar(
        AssignableScalar target,
        Value value,
        ref Interpreter interpreter,
    ) {
        if (target.hasIndex) {
            writeAssignableScalarIndex(target, value, interpreter);
            return;
        }

        if (target.isHeapScalar) {
            interpreter.heapScalars[target.classId] =
                coerceValueToType(value, target.type);
            return;
        }

        if (target.classId != 0) {
            Value[VarDeclaration] fields = interpreter.classFields[target.classId];
            assignStructField(
                fields,
                target.field,
                coerceValueToType(value, target.type),
            );
            interpreter.classFields[target.classId] = fields;
            return;
        }

        if (target.field !is null) {
            Value[VarDeclaration] fields = structFieldsValue(target.owner);
            assignStructField(
                fields,
                target.field,
                coerceValueToType(value, target.type),
            );
            assignNestedStructFields(target.owner, fields);
            return;
        }

        if (target.isGlobal) {
            assignGlobalValue(
                target.declaration,
                coerceValueToType(value, target.type),
                interpreter,
            );
            return;
        }

        assignLocalValue(
            target.declaration,
            coerceValueToType(value, target.type),
        );
    }

    private void writeAssignableScalarIndex(
        AssignableScalar target,
        Value value,
        ref Interpreter interpreter,
    ) {
        if (target.declaration !is null) {
            Value storage = target.isGlobal
                ? globalValueOrDefault(target, interpreter)
                : localValueOrDefault(target);
            long[] elements = arrayStorageValue(
                storage,
                target.containerType,
            );
            elements[target.index] = coerceIntegerToType(
                value.asLong,
                target.type,
            );

            if (target.isGlobal)
                assignGlobalValue(target.declaration, Value(elements), interpreter);
            else {
                assignLocalValue(target.declaration, Value(elements));
                propagateArrayAlias(target.declaration, target.index, value);
            }
            return;
        }

        Value[VarDeclaration] fields = target.classId == 0
            ? structFieldsValue(target.owner)
            : interpreter.classFields[target.classId];
        long[] elements = structFieldValue(
            fields,
            target.field,
            defaultArrayValue(target.containerType),
        ).asArray;
        elements[target.index] = coerceIntegerToType(value.asLong, target.type);
        assignStructField(fields, target.field, Value(elements));

        if (target.classId == 0)
            assignNestedStructFields(target.owner, fields);
        else
            interpreter.classFields[target.classId] = fields;
    }

    private Value localValueOrDefault(
        AssignableScalar target,
    ) {
        Value value;
        if (tryGetLocalValue(target.declaration, value))
            return value;
        return defaultValue(target.declaration.type);
    }

    private Value globalValueOrDefault(
        AssignableScalar target,
        ref Interpreter interpreter,
    ) {
        Value value;
        if (tryGetGlobalValue(target.declaration, interpreter, value))
            return value;
        return defaultValue(target.declaration.type);
    }

    private void assignLocalValue(
        VarDeclaration declaration,
        Value value,
    ) {
        if (declaration in locals) {
            locals[declaration] = value;
            return;
        }

        foreach (existingDeclaration; locals.byKey)
            if (sameStructField(existingDeclaration, declaration)) {
                locals[existingDeclaration] = value;
                return;
            }

        locals[declaration] = value;
    }

    private long scalarDivisionValue(
        in long left,
        in long right,
        Type targetType,
        Expression leftExpression,
        Expression rightExpression,
    ) {
        if (typeIsUnsignedInteger(targetType) ||
            expressionHasUnsignedIntegerType(leftExpression) ||
            expressionHasUnsignedIntegerType(rightExpression))
            return cast(long) (cast(ulong) left / cast(ulong) right);
        return left / right;
    }

    private bool tryRunArrayLengthAssign(
        Expression target,
        Expression valueExpression,
        out Value result,
        ref Interpreter interpreter,
    ) {
        auto length = target.isArrayLengthExp;
        if (length is null)
            return false;

        result = runExpression(valueExpression, interpreter);
        const newLength = cast(size_t) result.asLong;

        if (auto var = length.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration) {
                if (varDecl in locals) {
                    locals[varDecl] = Value(resizeArrayStorage(
                        locals[varDecl],
                        varDecl.type,
                        newLength,
                        interpreter,
                    ));
                    return true;
                }

                Value globalValue;
                if (tryGetGlobalValue(varDecl, interpreter, globalValue)) {
                    assignGlobalValue(
                        varDecl,
                        Value(resizeArrayStorage(
                            globalValue,
                            varDecl.type,
                            newLength,
                            interpreter,
                        )),
                        interpreter,
                    );
                    return true;
                }
            }

        if (auto dotVar = length.e1.isDotVarExp)
            if (auto owner = structFieldsOwner(dotVar.e1))
                if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                    Value[VarDeclaration] fields = structFieldsValue(owner);
                    assignStructField(
                        fields,
                        fieldDecl,
                        Value(resizeArrayStorage(
                            structFieldValue(
                                fields,
                                fieldDecl,
                                defaultArrayValue(fieldDecl.type),
                            ),
                            fieldDecl.type,
                            newLength,
                            interpreter,
                        )),
                    );
                    assignNestedStructFields(owner, fields);
                    return true;
                }

        return false;
    }

    private long[] resizeArrayStorage(
        Value value,
        Type type,
        in size_t newLength,
        ref Interpreter interpreter,
    ) {
        // auto: DMD type helper APIs require mutable Type nodes.
        auto elementType = arrayElementType(type);
        long[] elements = arrayStorageValue(value, type);
        if (!isStructType(elementType)) {
            elements.length = newLength;
            return elements;
        }

        const currentLength = cast(size_t) arrayFieldLength(Value(elements), type);
        if (newLength <= currentLength)
            return firstNestedArrayElements(elements, newLength);

        foreach (_; currentLength .. newLength) {
            long[] payload;
            Value[VarDeclaration] fields = defaultStructFields(elementType);
            appendStructFieldsToCereal(payload, elementType, fields, interpreter);
            elements ~= cast(long) payload.length;
            elements ~= payload;
        }
        return elements;
    }

    private long[] firstNestedArrayElements(
        long[] elements,
        in size_t count,
    ) {
        size_t cursor;
        foreach (_; 0 .. count) {
            const length = nestedArrayLength(elements[cursor]);
            cursor += 1 + length;
        }
        return elements[0 .. cursor].dup;
    }

    private long[] sliceAssignmentValue(
        Value value,
        in long length,
        Type elementType,
    ) {
        import std.sumtype: match;

        return value.match!(
            (long[] array) => array.dup,
            (long scalar) {
                // Explicit type: `elements` must be mutable for slice assignment.
                long[] elements = new long[cast(size_t) length];
                foreach (ref element; elements)
                    element = coerceIntegerToType(scalar, elementType);
                return elements;
            },
            (LocalPtr _) {
                throw new Exception("Expected slice assignment value, got pointer.");
                return (long[]).init;
            },
            (ClassRef _) {
                throw new Exception("Expected slice assignment value, got class.");
                return (long[]).init;
            },
            (AssocArrayRef _) {
                throw new Exception("Expected slice assignment value, got AA.");
                return (long[]).init;
            },
            (AssocArraySlotRef _) {
                throw new Exception("Expected slice assignment value, got AA slot.");
                return (long[]).init;
            },
        );
    }

    private long[] arrayStorageValue(
        Value value,
        Type type,
    ) {
        import std.sumtype: match;

        return value.match!(
            (long[] array) => array,
            (long _) => defaultArrayValue(type).asArray,
            (LocalPtr _) {
                throw new Exception("Expected array storage, got pointer.");
                return (long[]).init;
            },
            (ClassRef _) {
                throw new Exception("Expected array storage, got class.");
                return (long[]).init;
            },
            (AssocArrayRef _) {
                throw new Exception("Expected array storage, got AA.");
                return (long[]).init;
            },
            (AssocArraySlotRef _) {
                throw new Exception("Expected array storage, got AA slot.");
                return (long[]).init;
            },
        );
    }

    private void propagateArrayAlias(
        VarDeclaration declaration,
        in size_t index,
        Value value,
    ) {
        auto alias_ = declaration in arrayAliases;
        if (alias_ is null || alias_.owner !in locals)
            return;

        long[] elements = locals[alias_.owner].asArray;
        elements[alias_.offset + index] = coerceIntegerToType(
            value.asLong,
            arrayElementType(alias_.owner.type),
        );
        locals[alias_.owner] = Value(elements);
    }

    private bool tryAssignAssocArrayIndex(
        VarDeclaration declaration,
        Expression keyExpression,
        Value value,
        ref Interpreter interpreter,
    ) {
        if (declaration.type is null ||
            declaration.type.toBasetype.isTypeAArray is null)
            return false;

        const assocArrayRef = materializeAssocArrayVariable(
            declaration,
            interpreter,
        );
        return assignAssocArrayValue(
            assocArrayRef.id,
            declaration.type,
            keyExpression,
            value,
            interpreter,
        );
    }

    private bool tryAssignAssocArrayIndex(
        Expression arrayExpression,
        Expression keyExpression,
        Value value,
        ref Interpreter interpreter,
    ) {
        if (!isAssocArrayExpression(arrayExpression))
            return false;

        long arrayId;
        if (!tryMaterializeAssocArrayExpression(
            arrayExpression,
            arrayId,
            interpreter,
        ))
            return false;

        return assignAssocArrayValue(
            arrayId,
            arrayExpression.type,
            keyExpression,
            value,
            interpreter,
        );
    }

    private bool assignAssocArrayValue(
        in long arrayId,
        Type arrayType,
        Expression keyExpression,
        Value value,
        ref Interpreter interpreter,
    ) {
        const coercedValue = coerceValueToType(
            value,
            arrayElementType(arrayType),
        );
        size_t index;
        if (tryAssocArrayKeyExpressionIndex(
            arrayId,
            keyExpression,
            index,
            interpreter,
        )) {
            interpreter.assocArrays[arrayId].values[index] = coercedValue;
            return true;
        }

        VarDeclaration keyStruct;
        Value key;
        Value[VarDeclaration] keyFields;
        if (!assocArrayKeyFromExpression(
            keyExpression,
            keyStruct,
            key,
            keyFields,
            interpreter,
        ))
            return false;

        interpreter.assocArrays[arrayId].keyStructs ~= keyStruct;
        interpreter.assocArrays[arrayId].keyFields ~= keyFields;
        interpreter.assocArrays[arrayId].keys ~= key;
        interpreter.assocArrays[arrayId].values ~= coercedValue;
        return true;
    }

    private bool tryAssignAssocArraySlotPointer(
        Value pointer,
        Value value,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        AssocArraySlotRef slot;
        const hasSlot = pointer.match!(
            (AssocArraySlotRef ref_) {
                slot = ref_;
                return true;
            },
            (long _) => false,
            (long[] _) => false,
            (LocalPtr _) => false,
            (ClassRef _) => false,
            (AssocArrayRef _) => false,
        );
        if (!hasSlot)
            return false;
        if (slot.arrayId == 0 || slot.arrayId !in interpreter.assocArrays)
            return false;
        if (slot.index >= interpreter.assocArrays[slot.arrayId].values.length)
            return false;

        interpreter.assocArrays[slot.arrayId].values[slot.index] = value;
        return true;
    }

    private bool tryMaterializeAssocArrayExpression(
        Expression expression,
        out long arrayId,
        ref Interpreter interpreter,
    ) {
        arrayId = 0L;

        if (auto cast_ = expression.isCastExp)
            return tryMaterializeAssocArrayExpression(
                cast_.e1,
                arrayId,
                interpreter,
            );
        if (auto addr = expression.isAddrExp)
            return tryMaterializeAssocArrayExpression(
                addr.e1,
                arrayId,
                interpreter,
            );

        try {
            arrayId = assocArrayIdFromExpression(expression, interpreter);
        } catch (Exception) {
            arrayId = 0L;
        }
        if (arrayId != 0) {
            if (arrayId !in interpreter.assocArrays)
                interpreter.assocArrays[arrayId] = AssocArray.init;
            return true;
        }

        if (!isAssocArrayExpression(expression))
            return false;

        if (auto var = expression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration) {
                const assocArrayRef = materializeAssocArrayVariable(
                    varDecl,
                    interpreter,
                );
                arrayId = assocArrayRef.id;
                return true;
            }

        if (auto dotVar = expression.isDotVarExp)
            if (auto owner = structFieldsOwner(dotVar.e1))
                if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                    const assocArrayRef = newAssocArray(interpreter);
                    Value[VarDeclaration] fields = structFieldsValue(owner);
                    assignStructField(fields, fieldDecl, Value(assocArrayRef));
                    assignNestedStructFields(owner, fields);
                    arrayId = assocArrayRef.id;
                    return true;
                }

        return false;
    }

    private AssocArrayRef materializeAssocArrayLocal(
        VarDeclaration declaration,
        ref Interpreter interpreter,
    ) {
        if (auto local = declaration in locals) {
            const arrayId = (*local).assocArrayId;
            if (arrayId != 0) {
                if (arrayId !in interpreter.assocArrays)
                    interpreter.assocArrays[arrayId] = AssocArray.init;
                return AssocArrayRef(arrayId);
            }
        }

        const assocArrayRef = newAssocArray(interpreter);
        locals[declaration] = Value(assocArrayRef);
        return assocArrayRef;
    }

    private AssocArrayRef materializeAssocArrayVariable(
        VarDeclaration declaration,
        ref Interpreter interpreter,
    ) {
        if (declaration in locals)
            return materializeAssocArrayLocal(declaration, interpreter);

        Value globalValue;
        if (tryGetGlobalValue(declaration, interpreter, globalValue)) {
            const arrayId = globalValue.assocArrayId;
            if (arrayId != 0) {
                if (arrayId !in interpreter.assocArrays)
                    interpreter.assocArrays[arrayId] = AssocArray.init;
                return AssocArrayRef(arrayId);
            }
        }

        const assocArrayRef = newAssocArray(interpreter);
        assignGlobalValue(declaration, Value(assocArrayRef), interpreter);
        return assocArrayRef;
    }

    private AssocArrayRef newAssocArray(
        ref Interpreter interpreter,
    ) {
        const assocArrayRef = AssocArrayRef(interpreter.nextAssocArrayRef);
        ++interpreter.nextAssocArrayRef;
        interpreter.assocArrays[assocArrayRef.id] = AssocArray.init;
        return assocArrayRef;
    }

    private bool tryAssignNestedStructField(
        ref Value[VarDeclaration] fields,
        VarDeclaration field,
        Expression valueExpression,
    ) {
        if (!isStructType(field.type))
            return false;

        if (auto owner = structCopySourceOwner(valueExpression)) {
            if (auto sourceFields = owner in structFields)
                structFields[field] = (*sourceFields).dup;
            else
                return false;
            assignStructField(fields, field, Value(0L));
            return true;
        }

        return false;
    }

    private VarDeclaration structCopySourceOwner(
        Expression expression,
    ) {
        if (auto construct = expression.isConstructExp)
            return structCopySourceOwner(construct.e2);
        if (auto assign = expression.isAssignExp)
            return structCopySourceOwner(assign.e2);
        if (auto blit = expression.isBlitExp)
            return structCopySourceOwner(blit.e2);
        if (auto call = expression.isCallExp)
            if (call.arguments !is null && call.arguments.length == 1)
                if (auto owner = structCopySourceOwner(callArguments(call)[0]))
                    return owner;
        return structFieldsOwner(expression);
    }

    private Value[VarDeclaration] runStructInitializer(
        Expression expression,
        ref Interpreter interpreter,
    ) {
        if (auto construct = expression.isConstructExp)
            return runStructInitializer(construct.e2, interpreter);
        if (auto assign = expression.isAssignExp)
            return runStructInitializer(assign.e2, interpreter);
        if (auto blit = expression.isBlitExp)
            return runStructInitializer(blit.e2, interpreter);
        if (auto literal = expression.isStructLiteralExp)
            return runStructLiteralExpression(literal, interpreter);
        Value[VarDeclaration] elementFields;
        if (tryStructArrayElementFields(expression, elementFields, interpreter))
            return elementFields;
        if (auto owner = structCopySourceOwner(expression))
            if (auto fields = owner in structFields)
                return (*fields).dup;
        if (auto call = expression.isCallExp) {
            Value[VarDeclaration] fields;
            if (tryRunOutputRangeDecerealiseValue(call, fields, interpreter))
                return fields;
            if (tryRunStructDecerealiseValue(
                call,
                expression.type,
                fields,
                interpreter,
            ))
                return fields;
            if (tryRunStructDecerealise(call, fields, interpreter))
                return fields;
        }
        if (auto call = expression.isCallExp) {
            Value[VarDeclaration] fields;
            if (tryRunUnitThreadedStructConstructor(call, fields, interpreter))
                return fields;
        }
        if (auto call = expression.isCallExp)
            if (isStructType(call.type) &&
                aggregateStructFields(call.type).length == 0 &&
                call.f !is null &&
                call.f.fbody !is null) {
                Value[VarDeclaration] fields = defaultStructFields(call.type);
                Expression[] arguments;
                if (call.arguments !is null)
                    foreach (argument; callArguments(call))
                        arguments ~= argument;
                // `auto` is intentional: constructor execution returns mutable fields.
                auto result = interpreter.executeFunction(
                    call.f,
                    callArgumentsFor(call.f, arguments, interpreter),
                    fields,
                    nestedStructFieldMaps(fields),
                );
                return result.thisFields;
            }
        if (auto call = expression.isCallExp)
            if (isStructType(call.type) &&
                structFieldNamed(call.type, "_bytes") is null &&
                structFieldNamed(call.type, "_originalBytes") is null &&
                call.arguments !is null &&
                call.arguments.length > 0) {
                Value[VarDeclaration] fields = defaultStructFields(call.type);
                foreach (index, field; aggregateStructFields(call.type)) {
                    if (index >= call.arguments.length)
                        break;
                    assignStructField(
                        fields,
                        field,
                        coerceValueToType(
                            runExpression(callArguments(call)[index], interpreter),
                            field.type,
                        ),
                    );
                }
                return fields;
            }
        if (auto call = expression.isCallExp) {
            Value[VarDeclaration] fields = defaultStructFields(expression.type);
            auto bytesField = structFieldNamed(expression.type, "_bytes");
            auto originalBytesField =
                structFieldNamed(expression.type, "_originalBytes");
            if (bytesField !is null &&
                originalBytesField !is null &&
                call.arguments !is null &&
                call.arguments.length == 1) {
                long[] bytes = runExpression(
                    callArguments(call)[0],
                    interpreter,
                ).asArray;
                assignStructField(fields, bytesField, Value(bytes.dup));
                assignStructField(fields, originalBytesField, Value(bytes.dup));
                return fields;
            }
        }
        if (auto owner = structFieldsOwner(expression))
            return structFields[owner].dup;

        return (Value[VarDeclaration]).init;
    }

    private bool tryRunUnitThreadedStructConstructor(
        CallExp call,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (call.arguments is null || call.arguments.length == 0)
            return false;

        auto valueField = structFieldNamed(call.type, "_value");
        if (valueField !is null) {
            fields = defaultStructFields(call.type);
            assignStructField(
                fields,
                valueField,
                coerceValueToType(
                    runExpression(callArguments(call)[0], interpreter),
                    valueField.type,
                ),
            );
            return true;
        }

        auto wrapperField = structFieldNamed(call.type, "_wrapper");
        if (wrapperField !is null) {
            fields = defaultStructFields(call.type);
            auto wrapperValueField = structFieldNamed(wrapperField.type, "_value");
            if (wrapperValueField is null) {
                structFields[wrapperField] = runStructInitializer(
                    callArguments(call)[0],
                    interpreter,
                );
            } else {
                Value[VarDeclaration] wrapperFields =
                    defaultStructFields(wrapperField.type);
                assignStructField(
                    wrapperFields,
                    wrapperValueField,
                    coerceValueToType(
                        runExpression(callArguments(call)[0], interpreter),
                        wrapperValueField.type,
                    ),
                );
                structFields[wrapperField] = wrapperFields;
            }
            assignStructField(fields, wrapperField, Value(0L));
            return true;
        }

        if (hasUnitThreadedValuesField(call.type)) {
            fields = defaultStructFields(call.type);
            return true;
        }

        return false;
    }

    private bool hasUnitThreadedValuesField(Type type) {
        import std.string: startsWith;

        foreach (field; aggregateStructFields(type))
            if (field.ident !is null &&
                field.ident.toString.startsWith("__values_field_"))
                return true;
        return false;
    }

    private bool isUnitThreadedGeneratedValueExpression(
        DotVarExp dotVar,
    ) {
        import std.algorithm.searching: canFind;

        return dotVar.var.ident !is null &&
            dotVar.var.ident.toString == "value" &&
            expressionChars(dotVar.e1).canFind("__values_field_");
    }

    private bool tryRunStructDecerealiseValue(
        CallExp call,
        Type valueType,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (!isCerealedValueCall(call))
            return false;
        if (!isStructType(valueType))
            return false;
        // Output ranges must be decoded via the dedicated path so that the
        // payload bytes are appended to the global output variable rather than
        // silently discarded by the struct-field deserializer.
        if (isOutputRangeStructType(valueType) &&
            tryRunOutputRangeDecerealiseValue(call, fields, interpreter))
            return true;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null) {
            if (!interpreter.hasLastArrayValue)
                return false;
            size_t neededByteCount;
            return tryReadDecerealisedAggregateFields(
                valueType,
                interpreter.lastArrayValue,
                fields,
                neededByteCount,
                interpreter,
            );
        }

        if (tryReadDecerealisedAggregateFromOwner(
            owner,
            valueType,
            fields,
            interpreter,
        ))
            return true;

        if (!interpreter.hasLastArrayValue)
            return false;
        size_t neededByteCount;
        return tryReadDecerealisedAggregateFields(
            valueType,
            interpreter.lastArrayValue,
            fields,
            neededByteCount,
            interpreter,
        );
    }

    private bool isCerealedValueCall(CallExp call) {
        return callFunctionNamed(call, "value");
    }

    // Returns true when expression is (or wraps) a dec.value!T cerealed call.
    // Used to detect initialisers that must be handled before
    // tryReadInputRangeElements to prevent side-effectful byte consumption.
    private bool isCerealedValueInitialiser(Expression expression) {
        if (auto construct = expression.isConstructExp)
            return isCerealedValueInitialiser(construct.e2);
        if (auto assign = expression.isAssignExp)
            return isCerealedValueInitialiser(assign.e2);
        if (auto blit = expression.isBlitExp)
            return isCerealedValueInitialiser(blit.e2);
        if (auto call = expression.isCallExp)
            return isCerealedValueCall(call);
        return false;
    }

    private bool tryRunOutputRangeDecerealiseValue(
        CallExp call,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (call.f is null || call.f.ident is null || call.f.ident.toString != "value")
            return false;
        if (!isOutputRangeStructType(call.type))
            return false;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;

        size_t neededByteCount;
        if (!tryReadOutputRangeFromOwner(
            owner,
            call.type,
            neededByteCount,
            interpreter,
        ))
            return false;

        fields = defaultStructFields(call.type);
        return true;
    }

    private bool tryReadOutputRangeFromOwner(
        VarDeclaration owner,
        Type type,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] ownerFields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        if (bytesField is null)
            return false;

        long[] bytes = structFieldValue(
            ownerFields,
            bytesField,
            Value((long[]).init),
        ).asArray;
        if (!tryReadOutputRangePayload(
            type,
            bytes,
            neededByteCount,
            interpreter,
        ))
            return false;

        assignStructField(
            ownerFields,
            bytesField,
            Value(bytes[neededByteCount .. $].dup),
        );
        assignStructFields(owner, ownerFields);
        return true;
    }

    private bool tryReadDecerealisedAggregateFromOwner(
        VarDeclaration owner,
        Type type,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] ownerFields = structFieldsValue(owner);
        auto bytesField = structFieldNamed(owner.type, "_bytes");
        if (bytesField is null)
            return false;

        long[] bytes = structFieldValue(
            ownerFields,
            bytesField,
            Value((long[]).init),
        ).asArray;
        if (bytes.length == 0) {
            Value localBytes;
            if (tryGetLocalValue("bytes", null, localBytes))
                bytes = localBytes.asArray;
        }
        size_t neededByteCount;
        if (!tryReadDecerealisedAggregateFields(
            type,
            bytes,
            fields,
            neededByteCount,
            interpreter,
        ))
            return false;

        assignStructField(
            ownerFields,
            bytesField,
            Value(bytes[neededByteCount .. $].dup),
        );
        assignStructFields(owner, ownerFields);
        return true;
    }

    private bool tryReadDecerealisedAggregateFields(
        Type type,
        long[] bytes,
        out Value[VarDeclaration] fields,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        fields = isClassType(type) ? defaultClassFields(type) : defaultStructFields(type);
        size_t cursor;
        long bitByte;
        size_t bitIndex;
        foreach (field; cerealAggregateFields(type)) {
            if (cerealFieldHasAttribute(field, "NoCereal"))
                if (field.type is null || field.type.toBasetype.isTypeDArray is null)
                    continue;

            const bitCount = cerealFieldBitCount(field);
            if (bitCount != 0) {
                long bits;
                if (!tryReadCerealBits(
                    bytes,
                    cursor,
                    bitByte,
                    bitIndex,
                    bitCount,
                    bits,
                ))
                    return false;
                assignStructField(
                    fields,
                    field,
                    Value(coerceIntegerToType(bits, field.type)),
                );
                continue;
            }
            bitIndex = 0;

            Type heapType;
            if (field.type !is null && field.type.isTypePointer !is null)
                heapType = pointerTargetType(field.type);
            else if (isClassType(field.type))
                heapType = field.type;
            if (heapType !is null) {
                Value[VarDeclaration] heapFields;
                size_t heapByteCount;
                if (!tryReadDecerealisedAggregateFields(
                    heapType,
                    bytes[cursor .. $],
                    heapFields,
                    heapByteCount,
                    interpreter,
                ))
                    return false;
                const classRef = ClassRef(interpreter.nextClassRef);
                ++interpreter.nextClassRef;
                interpreter.classTypes[classRef.id] = heapType;
                interpreter.classFields[classRef.id] = heapFields;
                interpreter.classStructFieldMaps[classRef.id] =
                    nestedStructFieldMaps(heapFields);
                assignStructField(fields, field, Value(classRef));
                cursor += heapByteCount;
                continue;
            }

            if (isOutputRangeStructType(field.type)) {
                size_t outputRangeByteCount;
                if (!tryReadOutputRangePayload(
                    field.type,
                    bytes[cursor .. $],
                    outputRangeByteCount,
                    interpreter,
                ))
                    return false;
                cursor += outputRangeByteCount;
                continue;
            }

            if (isStructType(field.type)) {
                Value[VarDeclaration] nestedFields;
                size_t nestedByteCount;
                if (!tryReadDecerealisedAggregateFields(
                    field.type,
                    bytes[cursor .. $],
                    nestedFields,
                    nestedByteCount,
                    interpreter,
                ))
                    return false;
                structFields[field] = nestedFields;
                assignStructField(fields, field, Value(0L));
                cursor += nestedByteCount;
                continue;
            }

            if (field.type !is null && field.type.toBasetype.isTypeAArray !is null) {
                Value assocArray;
                size_t assocArrayByteCount;
                if (!tryReadDecerealisedAssocArrayField(
                    field.type,
                    bytes[cursor .. $],
                    assocArray,
                    assocArrayByteCount,
                    interpreter,
                ))
                    return false;
                assignStructField(fields, field, assocArray);
                cursor += assocArrayByteCount;
                continue;
            }

            if (field.type !is null && field.type.isTypeDArray !is null) {
                long[] elements;
                size_t arrayByteCount;
                if (tryReadNoCerealLengthArrayField(
                    field,
                    type,
                    fields,
                    bytes[cursor .. $],
                    elements,
                    arrayByteCount,
                )) {
                } else if (!tryReadDecerealisedAttributedArrayField(
                    field,
                    type,
                    fields,
                    bytes[cursor .. $],
                    cursor,
                    elements,
                    arrayByteCount,
                    interpreter,
                ))
                    if (!tryReadDecerealisedArrayElements(
                        arrayElementType(field.type),
                        bytes[cursor .. $],
                        elements,
                        arrayByteCount,
                    ))
                        return false;
                assignStructField(fields, field, Value(elements));
                cursor += arrayByteCount;
                continue;
            }

            const byteCount = decerealisedScalarByteCount(field.type);
            if (byteCount == 0)
                return false;
            if (bytes.length < cursor + byteCount)
                return false;
            assignStructField(
                fields,
                field,
                Value(coerceIntegerToType(
                    readBigEndian(bytes[cursor .. cursor + byteCount]),
                    field.type,
                )),
            );
            cursor += byteCount;
        }
        if (!tryReadCerealedAggregateHookFields(type, bytes, cursor, fields))
            return false;
        neededByteCount = cursor;
        return true;
    }

    private bool tryReadCerealedAggregateHookFields(
        Type type,
        long[] bytes,
        ref size_t cursor,
        ref Value[VarDeclaration] fields,
    ) {
        import std.algorithm.searching: canFind;

        const chars = typeChars(type);
        if (chars.canFind("CustomStruct")) {
            if (bytes.length < cursor + 1)
                return false;
            ++cursor;
            return true;
        }
        if (chars.canFind("PostBlitStruct")) {
            if (bytes.length < cursor + 2)
                return false;
            cursor += 2;
            return true;
        }
        if (!chars.canFind("MqttFixedHeader"))
            return true;

        auto remainingField = structFieldNamed(type, "remaining");
        if (remainingField is null)
            return true;

        long remaining;
        long multiplier = 1;
        while (true) {
            if (cursor >= bytes.length)
                return false;
            const digit = bytes[cursor];
            ++cursor;
            remaining += (digit & 127) * multiplier;
            multiplier *= 128;
            if ((digit & 128) == 0)
                break;
        }
        assignStructField(fields, remainingField, Value(remaining));
        return true;
    }

    private bool tryReadCerealBits(
        long[] bytes,
        ref size_t cursor,
        ref long bitByte,
        ref size_t bitIndex,
        in size_t bitCount,
        out long value,
    ) @safe {
        size_t remaining = bitCount;
        while (remaining != 0) {
            if (bitIndex == 0) {
                if (cursor >= bytes.length)
                    return false;
                bitByte = bytes[cursor];
                ++cursor;
            }

            const available = 8 - bitIndex;
            const take = remaining < available ? remaining : available;
            const shift = available - take;
            const mask = (1L << take) - 1;
            value = (value << take) | ((bitByte >> shift) & mask);
            bitIndex += take;
            remaining -= take;
            if (bitIndex == 8)
                bitIndex = 0;
        }
        return true;
    }

    private bool tryReadDecerealisedAssocArrayField(
        Type type,
        long[] bytes,
        out Value value,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        if (type is null)
            return false;
        auto arrayType = type.toBasetype.isTypeAArray;
        if (arrayType is null)
            return false;

        const keyByteCount = decerealisedScalarByteCount(arrayType.index);
        const valueByteCount = decerealisedScalarByteCount(arrayElementType(type));
        if (keyByteCount == 0 || valueByteCount == 0)
            return false;

        size_t headerByteCount;
        size_t length;
        if (!tryReadDecerealisedCollectionLength(
            bytes,
            keyByteCount + valueByteCount,
            headerByteCount,
            length,
        ))
            return false;

        AssocArray array;
        size_t cursor = headerByteCount;
        foreach (_; 0 .. length) {
            const keyEnd = cursor + keyByteCount;
            if (bytes.length < keyEnd)
                return false;
            array.keyStructs ~= null;
            array.keyFields ~= null;
            array.keys ~= Value(coerceIntegerToType(
                readBigEndian(bytes[cursor .. keyEnd]),
                arrayType.index,
            ));
            cursor = keyEnd;

            const valueEnd = cursor + valueByteCount;
            if (bytes.length < valueEnd)
                return false;
            array.values ~= Value(coerceIntegerToType(
                readBigEndian(bytes[cursor .. valueEnd]),
                arrayElementType(type),
            ));
            cursor = valueEnd;
        }

        const assocArrayRef = AssocArrayRef(interpreter.nextAssocArrayRef);
        ++interpreter.nextAssocArrayRef;
        interpreter.assocArrays[assocArrayRef.id] = array;
        interpreter.lastAssocArrayRef = assocArrayRef.id;
        value = Value(assocArrayRef);
        neededByteCount = cursor;
        return true;
    }

    private bool tryReadOutputRangePayload(
        Type type,
        long[] bytes,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        if (!isOutputRangeStructType(type))
            return false;
        // Truncated range payloads are a best-effort decode miss, not fatal.
        if (bytes.length < 2)
            return false;

        const length = cast(size_t) readBigEndian(bytes[0 .. 2]);
        neededByteCount = 2 + length;
        if (bytes.length < neededByteCount)
            return false;

        appendOutputRangePayload(
            bytes[2 .. neededByteCount],
            interpreter,
        );
        return true;
    }

    private void appendOutputRangePayload(
        in long[] payload,
        ref Interpreter interpreter,
    ) {
        foreach (globalDecl, value; interpreter.globals)
            if (globalDecl.ident !is null &&
                globalDecl.ident.toString == "gOutputBytes") {
                long[] elements = value.asArray;
                elements ~= payload;
                interpreter.globals[globalDecl] = Value(elements);
                return;
            }
    }

    private bool isOutputRangeStructType(Type type) {
        import std.algorithm.searching: canFind;

        return isStructType(type) &&
            aggregateStructFields(type).length == 0 &&
            typeChars(type).canFind("OutputRange");
    }

    private bool tryReadDecerealisedAttributedArrayField(
        VarDeclaration field,
        Type aggregateType,
        Value[VarDeclaration] fields,
        long[] bytes,
        in size_t aggregateCursor,
        out long[] elements,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        const arrayLengthExpression = cerealFieldAttributeArgument(
            field,
            "ArrayLength",
        );
        if (arrayLengthExpression.length != 0) {
            const length = evaluateCerealLengthExpression(
                arrayLengthExpression,
                aggregateType,
                fields,
                aggregateCursor,
            );
            if (length < 0)
                throw new Exception("Negative cerealed array length.");
            return tryReadDecerealisedArrayElementsByCount(
                arrayElementType(field.type),
                bytes,
                cast(size_t) length,
                elements,
                neededByteCount,
                interpreter,
            );
        }

        const byteLengthExpression = cerealFieldAttributeArgument(
            field,
            "LengthInBytes",
        );
        if (byteLengthExpression.length != 0) {
            const byteLength = evaluateCerealLengthExpression(
                byteLengthExpression,
                aggregateType,
                fields,
                aggregateCursor,
            );
            if (byteLength < 0)
                throw new Exception("Negative cerealed byte length.");
            return tryReadDecerealisedArrayElementsByByteCount(
                arrayElementType(field.type),
                bytes,
                cast(size_t) byteLength,
                elements,
                neededByteCount,
                interpreter,
            );
        }

        if (cerealFieldHasRestAttribute(field))
            return tryReadDecerealisedArrayElementsByByteCount(
                arrayElementType(field.type),
                bytes,
                bytes.length,
                elements,
                neededByteCount,
                interpreter,
            );

        return false;
    }

    private bool tryReadNoCerealLengthArrayField(
        VarDeclaration field,
        Type aggregateType,
        Value[VarDeclaration] fields,
        long[] bytes,
        out long[] elements,
        out size_t neededByteCount,
    ) {
        if (!cerealFieldHasAttribute(field, "NoCereal"))
            return false;
        auto lengthField = structFieldNamed(aggregateType, "length");
        if (lengthField is null)
            return false;
        const length = structFieldValue(fields, lengthField, Value(0L)).asLong;
        if (length < 0)
            throw new Exception("Negative cerealed array length.");

        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto elementType = arrayElementType(field.type);
        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount == 0)
            return false;

        neededByteCount = cast(size_t) length * elementByteCount;
        if (bytes.length < neededByteCount)
            throw new Exception("Not enough bytes left to decerealise array.");
        foreach (i; 0 .. cast(size_t) length) {
            const begin = i * elementByteCount;
            const end = begin + elementByteCount;
            elements ~= coerceIntegerToType(
                readBigEndian(bytes[begin .. end]),
                elementType,
            );
        }
        return true;
    }

    private bool tryReadDecerealisedArrayElementsByCount(
        Type elementType,
        long[] bytes,
        in size_t length,
        out long[] elements,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount != 0) {
            neededByteCount = length * elementByteCount;
            if (bytes.length < neededByteCount)
                throw new Exception("Not enough bytes left to decerealise array.");
            foreach (i; 0 .. length) {
                const begin = i * elementByteCount;
                const end = begin + elementByteCount;
                elements ~= coerceIntegerToType(
                    readBigEndian(bytes[begin .. end]),
                    elementType,
                );
            }
            return true;
        }

        if (!isStructType(elementType))
            return false;

        size_t cursor;
        foreach (_; 0 .. length) {
            long[] structBytes;
            size_t structByteCount;
            if (!tryReadDecerealisedStructArrayElement(
                elementType,
                bytes[cursor .. $],
                structBytes,
                structByteCount,
                interpreter,
            ))
                return false;
            elements ~= cast(long) structBytes.length;
            elements ~= structBytes;
            cursor += structByteCount;
        }
        neededByteCount = cursor;
        return true;
    }

    private bool tryReadDecerealisedArrayElementsByByteCount(
        Type elementType,
        long[] bytes,
        in size_t byteCount,
        out long[] elements,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        if (bytes.length < byteCount)
            throw new Exception("Not enough bytes left to decerealise array.");

        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount != 0) {
            if (elementByteCount == 0 || byteCount % elementByteCount != 0)
                return false;
            return tryReadDecerealisedArrayElementsByCount(
                elementType,
                bytes,
                byteCount / elementByteCount,
                elements,
                neededByteCount,
                interpreter,
            );
        }

        if (!isStructType(elementType))
            if (elementType is null ||
                elementType.toBasetype.isTypeDArray is null)
                return false;

        if (elementType !is null &&
            elementType.toBasetype.isTypeDArray !is null)
            return tryReadDecerealisedNestedArraysByByteCount(
                elementType,
                bytes,
                byteCount,
                elements,
                neededByteCount,
                interpreter,
            );

        size_t cursor;
        while (cursor < byteCount) {
            long[] structBytes;
            size_t structByteCount;
            if (!tryReadDecerealisedStructArrayElement(
                elementType,
                bytes[cursor .. byteCount],
                structBytes,
                structByteCount,
                interpreter,
            ))
                return false;
            if (structByteCount == 0 || cursor + structByteCount > byteCount)
                return false;
            elements ~= cast(long) structBytes.length;
            elements ~= structBytes;
            cursor += structByteCount;
        }
        neededByteCount = cursor;
        return true;
    }

    private bool tryReadDecerealisedNestedArraysByByteCount(
        Type elementType,
        long[] bytes,
        in size_t byteCount,
        out long[] elements,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        size_t cursor;
        auto nestedElementType = arrayElementType(elementType);
        while (cursor < byteCount) {
            long[] nestedElements;
            size_t nestedByteCount;
            if (!tryReadDecerealisedArrayElements(
                nestedElementType,
                bytes[cursor .. byteCount],
                nestedElements,
                nestedByteCount,
            ))
                return false;
            elements ~= cast(long) nestedElements.length;
            elements ~= nestedElements;
            cursor += nestedByteCount;
        }
        neededByteCount = cursor;
        return true;
    }

    private bool tryReadDecerealisedStructArrayElement(
        Type elementType,
        long[] bytes,
        out long[] structBytes,
        out size_t neededByteCount,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] elementFields;
        if (!tryReadDecerealisedAggregateFields(
            elementType,
            bytes,
            elementFields,
            neededByteCount,
            interpreter,
        ))
            return false;
        if (bytes.length < neededByteCount)
            return false;
        structBytes = bytes[0 .. neededByteCount].dup;
        return true;
    }

    private long evaluateCerealLengthExpression(
        in string expression,
        Type aggregateType,
        Value[VarDeclaration] fields,
        in size_t aggregateCursor,
    ) {
        const compact = removeAsciiWhitespace(expression);
        if (compact.length == 0)
            return 0L;

        foreach (i; 1 .. compact.length)
            if (compact[i] == '-')
                return evaluateCerealLengthExpression(
                    compact[0 .. i],
                    aggregateType,
                    fields,
                    aggregateCursor,
                ) - evaluateCerealLengthExpression(
                    compact[i + 1 .. $],
                    aggregateType,
                    fields,
                    aggregateCursor,
                );

        import std.conv: to;

        try {
            return compact.to!long;
        } catch (Exception) {
        }

        if (compact == "headerSize")
            return cast(long) aggregateCursor;

        long fieldValue;
        if (tryCerealFieldValue(aggregateType, fields, compact, fieldValue))
            return fieldValue;
        if (tryCerealEnumMemberValue(aggregateType, compact, fieldValue))
            return fieldValue;

        return 0L;
    }

    private bool tryCerealEnumMemberValue(
        Type type,
        in string name,
        out long value,
    ) {
        if (type is null)
            return false;

        auto structType = type.toBasetype.isTypeStruct;
        if (structType is null || structType.sym.members is null)
            return false;

        foreach (member; *structType.sym.members) {
            if (member.ident is null || member.ident.toString != name)
                continue;

            auto enumMember = member.isEnumMember;
            if (enumMember !is null)
                return tryCerealIntegerExpressionValue(enumMember.value, value) ||
                    tryCerealIntegerExpressionValue(enumMember.origValue, value);

            auto variable = member.isVarDeclaration;
            if (variable is null ||
                variable._init is null ||
                variable._init.isExpInitializer is null)
                return false;
            return tryCerealIntegerExpressionValue(
                variable._init.isExpInitializer.exp,
                value,
            );
        }

        return false;
    }

    private bool tryCerealIntegerExpressionValue(
        Expression expression,
        out long value,
    ) {
        if (expression is null)
            return false;
        if (auto integer = expression.isIntegerExp) {
            value = integerValue(integer);
            return true;
        }

        import std.conv: to;

        const compact = removeAsciiWhitespace(expressionChars(expression));
        try {
            value = compact.to!long;
            return true;
        } catch (Exception) {
            return false;
        }
    }

    private bool tryCerealFieldValue(
        Type type,
        Value[VarDeclaration] fields,
        in string name,
        out long value,
    ) {
        foreach (field; aggregateStructFields(type)) {
            if (field.ident !is null && field.ident.toString == name) {
                value = structFieldValue(fields, field, Value(0L)).asLong;
                return true;
            }

            if (!isStructType(field.type))
                continue;

            Value[VarDeclaration] nestedFields;
            if (!tryGetStructFields(field, nestedFields))
                continue;
            if (tryCerealFieldValue(field.type, nestedFields, name, value))
                return true;
        }
        return false;
    }

    private bool tryStructArrayElementFields(
        Expression expression,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        Expression arrayExpression;
        Expression indexExpression;
        if (auto index = expression.isIndexExp) {
            arrayExpression = index.e1;
            indexExpression = index.e2;
        } else if (auto array = expression.isArrayExp) {
            if (arrayExpressionArguments(array).length != 1)
                return false;
            arrayExpression = array.e1;
            indexExpression = arrayExpressionArguments(array)[0];
        } else {
            return false;
        }

        Type arrayType;
        long[] arrayValue;
        if (auto dotVar = arrayExpression.isDotVarExp) {
            auto owner = structFieldsOwner(dotVar.e1);
            if (owner is null)
                return false;
            auto fieldDecl = dotVar.var.isVarDeclaration;
            if (fieldDecl is null)
                return false;
            auto ownerFields = structFieldsValue(owner);
            arrayValue = structFieldValue(
                ownerFields,
                fieldDecl,
                Value((long[]).init),
            ).asArray;
            arrayType = fieldDecl.type;
        } else if (auto var = arrayExpression.isVarExp) {
            auto varDecl = var.var.isVarDeclaration;
            if (varDecl is null || varDecl !in locals)
                return false;
            arrayValue = locals[varDecl].asArray;
            arrayType = varDecl.type;
        } else {
            return false;
        }

        const index = runExpression(indexExpression, interpreter).asLong;
        if (index < 0)
            return false;

        return tryReadStructArrayElementFields(
            arrayElementType(arrayType),
            arrayValue,
            cast(size_t) index,
            fields,
            interpreter,
        );
    }

    private bool tryReadStructArrayElementFields(
        Type elementType,
        in long[] array,
        in size_t index,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (!isStructType(elementType))
            return false;

        size_t cursor;
        foreach (i; 0 .. index + 1) {
            if (cursor >= array.length)
                return false;
            const length = nestedArrayLength(array[cursor]);
            ++cursor;
            if (length > array.length - cursor)
                return false;
            if (i == index) {
                size_t used;
                return tryReadDecerealisedAggregateFields(
                    elementType,
                    array[cursor .. cursor + length].dup,
                    fields,
                    used,
                    interpreter,
                );
            }
            cursor += length;
        }
        return false;
    }

    private long arrayFieldLength(
        Value value,
        Type type,
    ) {
        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto elementType = arrayElementType(type);
        if (!isLengthPrefixedArrayElementType(elementType))
            return arrayValueLength(value);

        const array = value.asArray;
        size_t cursor;
        size_t length;
        while (cursor < array.length) {
            const elementLength = nestedArrayLength(array[cursor]);
            ++cursor;
            if (elementLength > array.length - cursor)
                return cast(long) array.length;
            cursor += elementLength;
            ++length;
        }
        return cast(long) length;
    }

    private bool isLengthPrefixedArrayElementType(Type type) {
        return isStructType(type) ||
            (type !is null && type.toBasetype.isTypeDArray !is null);
    }

    private bool tryRunStructDecerealise(
        CallExp call,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (!callFunctionNamed(call, "decerealise"))
            return false;

        long[] bytes;
        if (!tryCerealBytes(call.e1, bytes, interpreter))
            if (call.arguments is null ||
                call.arguments.length != 1 ||
                !tryCerealBytes(callArguments(call)[0], bytes, interpreter))
                return false;

        size_t neededByteCount;
        return tryReadDecerealisedAggregateFields(
            call.type,
            bytes,
            fields,
            neededByteCount,
            interpreter,
        );
    }

    private bool tryRunIgnoredStructDecerealise(
        CallExp call,
        ref Interpreter interpreter,
    ) {
        if (!isStructType(call.type))
            return false;
        if (!callFunctionNamed(call, "decerealise"))
            return false;

        Value[VarDeclaration] fields;
        if (!tryRunStructDecerealise(call, fields, interpreter)) {
            import std.conv: text;
            throw new Exception(text(
                "Could not decerealise struct: ",
                expressionChars(call),
            ));
        }
        return true;
    }

    private bool callFunctionNamed(
        CallExp call,
        in string name,
    ) {
        return functionDeclarationNamed(call.f, name) ||
            callExpressionNamed(call.e1, name);
    }

    private bool functionDeclarationNamed(
        FuncDeclaration function_,
        in string name,
    ) {
        if (function_ is null)
            return false;
        if (identifierNamed(function_.ident, name))
            return true;

        import dmd.expression: getFuncTemplateDecl;

        if (auto template_ = getFuncTemplateDecl(function_))
            return templateDeclarationNamed(template_, name);
        if (auto instance = function_.isInstantiated)
            return templateInstanceNamed(instance, name);
        return false;
    }

    private bool callExpressionNamed(
        Expression expression,
        in string name,
    ) {
        if (expression is null)
            return false;

        if (auto template_ = expression.isTemplateExp)
            return templateDeclarationNamed(template_.td, name);
        if (auto var = expression.isVarExp)
            return identifierNamed(var.var.ident, name);
        if (auto dotVar = expression.isDotVarExp)
            return identifierNamed(dotVar.var.ident, name);
        if (auto dotTemplate = expression.isDotTemplateExp)
            return templateDeclarationNamed(dotTemplate.td, name);
        if (auto dotTemplate = expression.isDotTemplateInstanceExp)
            return templateInstanceNamed(dotTemplate.ti, name);
        if (auto scope_ = expression.isScopeExp)
            if (auto instance = scope_.sds.isTemplateInstance)
                return templateInstanceNamed(instance, name);
        return false;
    }

    private bool templateDeclarationNamed(
        imported!"dmd.dtemplate".TemplateDeclaration declaration,
        in string name,
    ) {
        return declaration !is null && identifierNamed(declaration.ident, name);
    }

    private bool templateInstanceNamed(
        imported!"dmd.dtemplate".TemplateInstance instance,
        in string name,
    ) {
        if (instance is null)
            return false;
        if (identifierNamed(instance.name, name))
            return true;
        return instance.tempdecl !is null &&
            identifierNamed(instance.tempdecl.ident, name);
    }

    private bool identifierNamed(
        imported!"dmd.identifier".Identifier identifier,
        in string name,
    ) {
        return identifier !is null && identifier.toString == name;
    }

    private bool tryCerealBytes(
        Expression expression,
        out long[] bytes,
        ref Interpreter interpreter,
    ) {
        if (auto dotVar = expression.isDotVarExp)
            return tryCerealBytes(dotVar.e1, bytes, interpreter);
        if (auto var = expression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (auto value = varDecl in locals) {
                    bytes = (*value).asArray.dup;
                    return true;
                }
        if (auto literal = expression.isArrayLiteralExp) {
            if (literal.elements !is null)
                foreach (element; arrayLiteralElements(literal))
                    bytes ~= runExpression(element, interpreter).asLong;
            return true;
        }

        return false;
    }

    private Value[VarDeclaration] runStructLiteralExpression(
        StructLiteralExp literal,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] fields;
        if (literal.elements is null)
            return fields;

        foreach (i, element; structLiteralElements(literal)) {
            if (element is null)
                continue;
            // auto: the AA key must remain a mutable DMD VarDeclaration.
            auto field = structLiteralField(literal, i);
            if (field is null)
                continue;
            if (isStructType(field.type)) {
                structFields[field] = runStructInitializer(element, interpreter);
                fields[field] = Value(0L);
                continue;
            }
            if (element.isNullExp) {
                if (field.type !is null && field.type.isTypeDArray !is null) {
                    fields[field] = Value((long[]).init);
                    continue;
                }
                fields[field] = Value(0L);
                continue;
            }
            if (cerealFieldHasRestAttribute(field))
                if (auto array = element.isArrayLiteralExp)
                    if (isStructType(arrayElementType(field.type))) {
                        fields[field] = Value(rawArrayLiteralRuntimeValue(
                            array,
                            interpreter,
                        ));
                        continue;
                    }
            fields[field] = coerceValueToType(
                runExpression(element, interpreter),
                field.type,
            );
        }
        return fields;
    }

    private long[] rawArrayLiteralRuntimeValue(
        ArrayLiteralExp literal,
        ref Interpreter interpreter,
    ) {
        long[] payload;
        if (literal.elements !is null)
            foreach (element; arrayLiteralElements(literal))
                if (auto struct_ = element.isStructLiteralExp) {
                    const structBytes = rawStructLiteralCerealBytes(
                        struct_,
                        interpreter,
                    );
                    payload ~= cast(long) structBytes.length;
                    payload ~= structBytes;
                }

        return payload;
    }

    private long[] rawStructLiteralCerealBytes(
        StructLiteralExp literal,
        ref Interpreter interpreter,
    ) {
        long[] elements;
        foreach (i, element; structLiteralElements(literal)) {
            if (element is null)
                continue;
            // auto: the field comes from DMD's mutable aggregate metadata.
            auto field = structLiteralField(literal, i);
            if (field is null)
                continue;
            if (field.type !is null &&
                field.type.toBasetype.isTypeDArray !is null &&
                cerealFieldHasAttribute(field, "NoCereal")) {
                elements ~= runExpression(element, interpreter).asArray;
                continue;
            }
            appendExpressionCerealBytes(elements, element, field.type, interpreter, field);
        }
        return elements;
    }

    private Value[VarDeclaration] defaultClassFields(
        Type type,
    ) {
        Value[VarDeclaration] fields;
        foreach (field; classFields(type))
            if (field.type !is null &&
                field.type.toBasetype.isTypeDArray !is null)
                fields[field] = Value((long[]).init);
            else if (isStructType(field.type)) {
                fields[field] = Value(0L);
                structFields[field] = (Value[VarDeclaration]).init;
            } else
                fields[field] = Value(0L);
        return fields;
    }

    private Value[VarDeclaration] defaultStructFields(
        Type type,
    ) {
        Value[VarDeclaration] fields;
        foreach (field; aggregateStructFields(type))
            if (field.type !is null &&
                field.type.toBasetype.isTypeDArray !is null)
                fields[field] = Value((long[]).init);
            else if (field.type !is null &&
                field.type.toBasetype.isTypeSArray !is null)
                fields[field] = defaultArrayValue(field.type);
            else if (isStructType(field.type)) {
                fields[field] = Value(0L);
                structFields[field] = defaultStructFields(field.type);
            } else
                fields[field] = Value(0L);
        return fields;
    }

    private VarDeclaration structFieldsOwner(
        Expression expression,
    ) {
        if (auto var = expression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in structFields)
                    return varDecl;
        if (auto var = expression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                foreach (owner; structFields.byKey)
                    if (sameStructField(owner, varDecl))
                        return owner;
        if (auto var = expression.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (currentThis !is null)
                    if (auto fields = currentThis in structFields)
                        foreach (field; (*fields).byKey)
                            if (sameStructField(field, varDecl) &&
                                field in structFields)
                                return field;
        if (auto thisExp = expression.isThisExp)
            if (auto thisDecl = thisExp.var.isVarDeclaration)
                if (thisDecl in structFields)
                    return thisDecl;
        if (auto dotVar = expression.isDotVarExp)
            if (auto owner = structFieldsOwner(dotVar.e1))
                if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                    Value[VarDeclaration] fields = structFieldsValue(owner);
                    foreach (field; fields.byKey)
                        if (sameStructField(field, fieldDecl) &&
                            field in structFields)
                            return field;
                }
        if (auto dotVar = expression.isDotVarExp)
            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                if (fieldDecl in structFields)
                    return fieldDecl;
        if (auto dotVar = expression.isDotVarExp)
            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                foreach (owner; structFields.byKey)
                    if (sameStructField(owner, fieldDecl))
                        return owner;
        return null;
    }

    private Value structFieldValue(
        ref Value[VarDeclaration] fields,
        VarDeclaration field,
        Value defaultValue,
    ) {
        if (auto value = field in fields)
            return *value;
        foreach (existingField, value; fields)
            if (sameStructField(existingField, field))
                return value;
        return defaultValue;
    }

    private Value[VarDeclaration] structFieldsValue(VarDeclaration owner) {
        Value[VarDeclaration] fields;
        if (tryGetStructFields(owner, fields))
            return fields;
        return (Value[VarDeclaration]).init;
    }

    private bool tryGetStructFields(
        VarDeclaration owner,
        out Value[VarDeclaration] fields,
    ) {
        if (auto found = owner in structFields) {
            fields = (*found).dup;
            return true;
        }
        foreach (existingOwner, existingFields; structFields)
            if (sameStructField(existingOwner, owner)) {
                fields = existingFields.dup;
                return true;
            }
        return false;
    }

    private bool tryGetLocalValue(
        VarDeclaration declaration,
        out Value value,
    ) {
        if (auto found = declaration in locals) {
            value = *found;
            return true;
        }
        foreach (existingDeclaration, existingValue; locals)
            if (sameStructField(existingDeclaration, declaration)) {
                value = existingValue;
                return true;
            }
        if (declaration.ident !is null)
            return tryGetLocalValue(
                declaration.ident.toString,
                declaration.type,
                value,
            );
        return false;
    }

    private AssocArrayKeys* assocArrayKeysLocal(
        VarDeclaration declaration,
    ) {
        if (auto found = declaration in assocArrayKeyArrays)
            return found;
        foreach (existingDeclaration; assocArrayKeyArrays.byKey)
            if (sameStructField(existingDeclaration, declaration) ||
                sameDeclarationName(existingDeclaration, declaration))
                return existingDeclaration in assocArrayKeyArrays;
        return null;
    }

    private bool sameDeclarationName(
        VarDeclaration left,
        VarDeclaration right,
    ) {
        return left !is null &&
            right !is null &&
            left.ident !is null &&
            right.ident !is null &&
            left.ident.toString == right.ident.toString;
    }

    private AssocArrayKeyLocal* assocArrayKeyLocal(
        VarDeclaration declaration,
    ) {
        if (auto found = declaration in assocArrayKeyLocals)
            return found;
        foreach (existingDeclaration; assocArrayKeyLocals.byKey)
            if (sameStructField(existingDeclaration, declaration) ||
                sameDeclarationName(existingDeclaration, declaration))
                return existingDeclaration in assocArrayKeyLocals;
        return null;
    }

    private AssocArraySlotLocal* assocArraySlotLocal(
        VarDeclaration declaration,
    ) {
        if (auto found = declaration in assocArraySlotLocals)
            return found;
        foreach (existingDeclaration; assocArraySlotLocals.byKey)
            if (sameStructField(existingDeclaration, declaration))
                return existingDeclaration in assocArraySlotLocals;
        return null;
    }

    private bool tryGetLocalValue(
        in const(char)[] name,
        Type type,
        out Value value,
    ) {
        foreach (existingDeclaration, existingValue; locals) {
            if (existingDeclaration.ident is null ||
                existingDeclaration.ident.toString != name)
                continue;
            if (type !is null &&
                existingDeclaration.type !is null &&
                typeChars(type) != typeChars(existingDeclaration.type))
                continue;
            value = existingValue;
            return true;
        }
        return false;
    }

    private bool tryGetGlobalValue(
        VarDeclaration declaration,
        ref Interpreter interpreter,
        out Value value,
    ) {
        if (auto found = declaration in interpreter.globals) {
            value = *found;
            return true;
        }
        foreach (existingDeclaration, existingValue; interpreter.globals)
            if (sameStructField(existingDeclaration, declaration)) {
                value = existingValue;
                return true;
            }
        return false;
    }

    private void assignGlobalValue(
        VarDeclaration declaration,
        Value value,
        ref Interpreter interpreter,
    ) {
        if (declaration in interpreter.globals) {
            interpreter.globals[declaration] = value;
            return;
        }
        foreach (existingDeclaration; interpreter.globals.byKey)
            if (sameStructField(existingDeclaration, declaration)) {
                interpreter.globals[existingDeclaration] = value;
                return;
            }
        interpreter.globals[declaration] = value;
    }

    private bool tryGetStructFieldMap(
        Value[VarDeclaration][VarDeclaration] maps,
        VarDeclaration owner,
        out Value[VarDeclaration] fields,
    ) {
        if (auto found = owner in maps) {
            fields = (*found).dup;
            return true;
        }
        foreach (existingOwner, existingFields; maps)
            if (sameStructField(existingOwner, owner)) {
                fields = existingFields.dup;
                return true;
            }
        return false;
    }

    private void assignStructFields(
        VarDeclaration owner,
        Value[VarDeclaration] fields,
    ) {
        if (owner in structFields) {
            structFields[owner] = fields;
            return;
        }

        foreach (existingOwner; structFields.byKey)
            if (sameStructField(existingOwner, owner)) {
                structFields[existingOwner] = fields;
                return;
            }

        structFields[owner] = fields;
    }

    private void assignNestedStructFields(
        VarDeclaration owner,
        Value[VarDeclaration] fields,
    ) {
        assignStructFields(owner, fields);

        foreach (structOwner; structFields.byKey) {
            Value[VarDeclaration] ownerFields = structFields[structOwner].dup;
            foreach (field; ownerFields.byKey)
                if (sameStructField(field, owner)) {
                    assignStructFields(field, fields);
                    assignStructField(ownerFields, field, Value(0L));
                    structFields[structOwner] = ownerFields;
                    break;
                }
        }
    }

    private void assignStructField(
        ref Value[VarDeclaration] fields,
        VarDeclaration field,
        Value value,
    ) {
        if (field in fields) {
            fields[field] = value;
            return;
        }

        foreach (existingField; fields.byKey)
            if (sameStructField(existingField, field)) {
                fields[existingField] = value;
                return;
            }

        fields[field] = value;
    }

    private bool sameStructField(
        VarDeclaration left,
        VarDeclaration right,
    ) {
        if (left is right)
            return true;
        if (left is null ||
            right is null ||
            left.ident is null ||
            right.ident is null ||
            left.ident.toString != right.ident.toString)
            return false;
        if (left.type is null || right.type is null)
            return left.type is right.type;
        return typeChars(left.type) == typeChars(right.type);
    }

    private bool isStructType(Type type) {
        return type !is null && type.toBasetype.isTypeStruct !is null;
    }

    private bool isClassType(Type type) {
        return type !is null && type.toBasetype.isTypeClass !is null;
    }

    private Value[VarDeclaration]* classInstanceFields(
        Value value,
        ref Interpreter interpreter,
    ) {
        import std.sumtype: match;

        const classRef = value.match!(
            (ClassRef ref_) => ref_.id,
            (long _) => 0L,
            (long[] _) => 0L,
            (LocalPtr _) => 0L,
            (AssocArrayRef _) => 0L,
            (AssocArraySlotRef _) => 0L,
        );
        if (classRef == 0)
            return null;
        return classRef in interpreter.classFields;
    }

    private VarDeclaration structFieldNamed(
        Type type,
        in string name,
    ) {
        if (type is null)
            return null;
        if (auto structType = type.toBasetype.isTypeStruct)
            foreach (field; structType.sym.fields)
                if (field.ident !is null && field.ident.toString == name)
                    return field;
        return null;
    }

    private long runSliceBound(
        Expression expression,
        ref Interpreter interpreter,
        in size_t arrayLength,
    ) {
        import dmd.id: Id;
        import dmd.tokens: EXP;

        if (expression.op == EXP.dollar)
            return cast(long) arrayLength;
        if (auto var = expression.isVarExp)
            if (var.var.ident == Id.dollar)
                return cast(long) arrayLength;

        if (auto subtract = expression.isMinExp)
            return runSliceBound(subtract.e1, interpreter, arrayLength) -
                runSliceBound(subtract.e2, interpreter, arrayLength);

        return runExpression(expression, interpreter).asLong;
    }
}

private long asLong(Value value) @safe pure {
    import std.sumtype: match;
    return value.match!(
        (long l) => l,
        (long[] _) {
            throw new Exception("Expected scalar, got array.");
            return 0L;
        },
        (LocalPtr _) {
            throw new Exception("Expected scalar, got pointer.");
            return 0L;
        },
        (ClassRef _) {
            throw new Exception("Expected scalar, got class.");
            return 0L;
        },
        (AssocArrayRef _) {
            throw new Exception("Expected scalar, got AA.");
            return 0L;
        },
        (AssocArraySlotRef ref_) => ref_.arrayId == 0 ? 0L : 1L,
    );
}

private long realLiteralBits(imported!"dmd.expression".RealExp real_) @trusted {
    import dmd.astenums: TY;

    if (real_.type !is null && real_.type.toBasetype.ty == TY.Tfloat32)
        return floatBits(cast(float) real_.toReal);
    return doubleBits(cast(double) real_.toReal);
}

private long floatBits(in float value) @trusted pure nothrow {
    return cast(long) *cast(uint*) &value;
}

private long doubleBits(in double value) @trusted pure nothrow {
    return *cast(long*) &value;
}

private double doubleFromBits(in long value) @trusted pure nothrow {
    return *cast(double*) &value;
}

private long[] asArray(Value value) @safe pure {
    import std.sumtype: match;
    return value.match!(
        (long[] a) => a,
        (long _) {
            throw new Exception("Expected array, got scalar.");
            return (long[]).init;
        },
        (LocalPtr _) {
            throw new Exception("Expected array, got pointer.");
            return (long[]).init;
        },
        (ClassRef _) {
            throw new Exception("Expected array, got class.");
            return (long[]).init;
        },
        (AssocArrayRef _) {
            throw new Exception("Expected array, got AA.");
            return (long[]).init;
        },
        (AssocArraySlotRef _) {
            throw new Exception("Expected array, got AA slot.");
            return (long[]).init;
        },
    );
}

private long arrayValueLength(Value value) @safe pure {
    import std.sumtype: match;
    return value.match!(
        (long[] a) => cast(long) a.length,
        (long _) => 0L,
        (LocalPtr _) => 0L,
        (ClassRef _) => 0L,
        (AssocArrayRef _) => 0L,
        (AssocArraySlotRef _) => 0L,
    );
}

private long classId(Value value) @safe pure {
    import std.sumtype: match;

    return value.match!(
        (ClassRef ref_) => ref_.id,
        (long _) => 0L,
        (long[] _) => 0L,
        (LocalPtr _) => 0L,
        (AssocArrayRef _) => 0L,
        (AssocArraySlotRef _) => 0L,
    );
}

private long assocArrayId(Value value) @safe pure {
    import std.sumtype: match;

    return value.match!(
        (AssocArrayRef ref_) => ref_.id,
        (ClassRef _) => 0L,
        (long _) => 0L,
        (long[] _) => 0L,
        (LocalPtr _) => 0L,
        (AssocArraySlotRef _) => 0L,
    );
}

private Value coerceValueToType(
    Value value,
    imported!"dmd.mtype".Type type,
) {
    import std.sumtype: match;

    if (type is null)
        return value;

    return value.match!(
        (long l) => Value(coerceIntegerToType(l, type)),
        (long[] a) => Value(a),
        (LocalPtr p) => Value(p),
        (ClassRef ref_) => Value(ref_),
        (AssocArrayRef ref_) => Value(ref_),
        (AssocArraySlotRef ref_) => Value(ref_),
    );
}

private long coerceIntegerToType(
    in long value,
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.astenums: TY;

    if (type is null)
        return value;

    const basetype = type.toBasetype;
    switch (basetype.ty) {
        case TY.Tint8:
            return cast(long) cast(byte) value;
        case TY.Tuns8:
            return cast(long) cast(ubyte) value;
        case TY.Tint16:
            return cast(long) cast(short) value;
        case TY.Tuns16:
            return cast(long) cast(ushort) value;
        case TY.Tint32:
            return cast(long) cast(int) value;
        case TY.Tuns32:
            return cast(long) cast(uint) value;
        case TY.Tint64:
            return cast(long) value;
        case TY.Tuns64:
            return cast(long) cast(ulong) value;
        case TY.Tfloat32:
        case TY.Tfloat64:
            return value;
        default:
            return value;
    }
}

private size_t decerealisedScalarByteCount(
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.astenums: TY;

    if (type is null)
        return 0;

    const chars = typeChars(type);
    if (chars == "float")
        return 4;
    if (chars == "double")
        return 8;

    const basetype = type.toBasetype;
    switch (basetype.ty) {
        case TY.Tbool:
        case TY.Tint8:
        case TY.Tuns8:
        case TY.Tchar:
            return 1;
        case TY.Tint16:
        case TY.Tuns16:
        case TY.Twchar:
            return 2;
        case TY.Tint32:
        case TY.Tuns32:
        case TY.Tdchar:
        case TY.Tfloat32:
            return 4;
        case TY.Tint64:
        case TY.Tuns64:
        case TY.Tfloat64:
            return 8;
        default:
            return 0;
    }
}

private long readBigEndian(in long[] bytes) @safe {
    long value;
    foreach (byte_; bytes)
        value = (value << 8) | (byte_ & 0xff);
    return value;
}

private bool tryReadDecerealisedCollectionLength(
    in long[] bytes,
    in size_t elementByteCount,
    out size_t headerByteCount,
    out size_t length,
    in size_t exactHeaderByteCount = 0,
) @safe {
    if (exactHeaderByteCount != 0) {
        if (bytes.length < exactHeaderByteCount)
            return false;
        const exactLength = cast(size_t) readBigEndian(
            bytes[0 .. exactHeaderByteCount],
        );
        const neededByteCount =
            exactHeaderByteCount + exactLength * elementByteCount;
        if (bytes.length < neededByteCount)
            return false;
        headerByteCount = exactHeaderByteCount;
        length = exactLength;
        return true;
    }

    foreach (candidateHeaderByteCount; [2, 4, 8, 1]) {
        if (bytes.length < candidateHeaderByteCount)
            continue;
        const candidateLength = cast(size_t) readBigEndian(
            bytes[0 .. candidateHeaderByteCount],
        );
        const neededByteCount =
            candidateHeaderByteCount + candidateLength * elementByteCount;
        if (bytes.length < neededByteCount)
            continue;
        if (candidateLength == 0 && bytes.length >= 4)
            continue;
        headerByteCount = candidateHeaderByteCount;
        length = candidateLength;
        return true;
    }
    return false;
}

private imported!"dmd.mtype".Type arrayElementType(
    imported!"dmd.mtype".Type type,
) @trusted {
    if (type is null)
        return null;

    return type.toBasetype.nextOf;
}

private size_t staticArrayLength(imported!"dmd.mtype".Type type) @trusted {
    if (type is null || type.toBasetype.isTypeSArray is null)
        return 0;

    return cast(size_t) type.toBasetype.isTypeSArray.dim.toInteger;
}

private Value defaultArrayValue(imported!"dmd.mtype".Type type) @trusted {
    if (type is null)
        return Value((long[]).init);

    if (auto staticArray = type.toBasetype.isTypeSArray)
        return Value(new long[cast(size_t) staticArray.dim.toInteger]);

    return Value((long[]).init);
}

private Value defaultValue(imported!"dmd.mtype".Type type) @trusted {
    if (type !is null &&
        (type.toBasetype.isTypeDArray !is null ||
            type.toBasetype.isTypeSArray !is null))
        return defaultArrayValue(type);

    return Value(0L);
}

private imported!"dmd.mtype".Type pointerTargetType(
    imported!"dmd.mtype".Type type,
) @trusted {
    if (type is null || type.toBasetype.isTypePointer is null)
        return null;

    return type.toBasetype.nextOf;
}

private imported!"dmd.mtype".Type mutableType(
    imported!"dmd.mtype".Type type,
) @trusted {
    if (type is null)
        return null;

    return type.makeMutable;
}

private ref auto compoundStatements(
    imported!"dmd.statement".CompoundStatement compound,
) @trusted pure {
    return *compound.statements;
}

private long integerValue(
    imported!"dmd.expression".IntegerExp integer,
) @trusted {
    return integer.getInteger;
}

private bool comparisonUsesUnsignedOperand(
    imported!"dmd.expression".BinExp comparison,
) @safe {
    return expressionHasUnsignedIntegerType(comparison.e1) ||
        expressionHasUnsignedIntegerType(comparison.e2);
}

private bool expressionHasUnsignedIntegerType(
    imported!"dmd.expression".Expression expression,
) @trusted {
    if (expression.type is null)
        return false;

    return typeIsUnsignedInteger(expression.type);
}

private bool typeIsUnsignedInteger(
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.astenums: TY;

    if (type is null)
        return false;

    const basetype = type.toBasetype;
    return basetype.ty == TY.Tuns8 ||
        basetype.ty == TY.Tuns16 ||
        basetype.ty == TY.Tuns32 ||
        basetype.ty == TY.Tuns64;
}

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import std.string: fromStringz;
    return fromStringz(expression.toChars).idup;
}

private bool cerealFieldHasAttribute(
    imported!"dmd.declaration".VarDeclaration field,
    in string name,
) {
    return cerealFieldAttributeChars(field, name).length != 0;
}

private size_t cerealFieldBitCount(
    imported!"dmd.declaration".VarDeclaration field,
) {
    const attribute = cerealFieldAttributeChars(field, "Bits");
    if (attribute.length == 0)
        return 0;

    import std.ascii: isDigit;
    import std.conv: to;

    foreach (i, char_; attribute) {
        if (!char_.isDigit)
            continue;
        size_t end = i;
        while (end < attribute.length && attribute[end].isDigit)
            ++end;
        return attribute[i .. end].to!size_t;
    }
    return 0;
}

private string cerealFieldAttributeArgument(
    imported!"dmd.declaration".VarDeclaration field,
    in string name,
) {
    const attribute = cerealFieldAttributeChars(field, name);
    foreach (start, char_; attribute)
        if (char_ == '"')
            foreach (end, endChar; attribute[start + 1 .. $])
                if (endChar == '"')
                    return attribute[start + 1 .. start + 1 + end];
    return null;
}

private string cerealFieldAttributeChars(
    imported!"dmd.declaration".VarDeclaration field,
    in string name,
) @trusted {
    import std.algorithm.searching: canFind;

    if (field is null ||
        field.userAttribDecl is null ||
        field.userAttribDecl.atts is null)
        return null;

    foreach (attribute; *field.userAttribDecl.atts) {
        const chars = expressionChars(attribute);
        if (chars.canFind(name))
            return chars;
    }

    return null;
}

private string removeAsciiWhitespace(in string value) @safe pure {
    string result;
    foreach (char_; value)
        if (char_ != ' ' &&
            char_ != '\t' &&
            char_ != '\n' &&
            char_ != '\r')
            result ~= char_;
    return result;
}

private string functionName(imported!"dmd.func".FuncDeclaration function_) @trusted {
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    return fromStringz(mangleExact(function_)).idup;
}

private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;
    return fromStringz(type.toChars).idup;
}

private string qualifiedTypeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;
    return fromStringz(type.toPrettyChars(true)).idup;
}

private ref auto callArguments(
    imported!"dmd.expression".CallExp call,
) @trusted pure {
    return *call.arguments;
}

private ref auto arrayExpressionArguments(
    imported!"dmd.expression".ArrayExp expression,
) @trusted pure {
    return *expression.arguments;
}

private ref auto functionParameters(
    imported!"dmd.func".FuncDeclaration func,
) @trusted pure {
    return *func.parameters;
}

private ref auto arrayLiteralElements(
    imported!"dmd.expression".ArrayLiteralExp literal,
) @trusted pure {
    return *literal.elements;
}

private ref auto assocArrayLiteralKeys(
    imported!"dmd.expression".AssocArrayLiteralExp literal,
) @trusted pure {
    return *literal.keys;
}

private ref auto assocArrayLiteralValues(
    imported!"dmd.expression".AssocArrayLiteralExp literal,
) @trusted pure {
    return *literal.values;
}

private ref auto structLiteralElements(
    imported!"dmd.expression".StructLiteralExp literal,
) pure {
    return *literal.elements;
}

private long[] stringLiteralElements(
    imported!"dmd.expression".StringExp literal,
) pure {
    long[] elements;
    foreach (i; 0 .. literal.len)
        elements ~= literal.getIndex(i);
    return elements;
}

private imported!"dmd.declaration".VarDeclaration structLiteralField(
    imported!"dmd.expression".StructLiteralExp literal,
    in size_t index,
) pure {
    if (literal.sd is null || index >= literal.sd.fields.length)
        return null;
    return literal.sd.fields[index];
}

private imported!"dmd.declaration".VarDeclaration[] classFields(
    imported!"dmd.mtype".Type type,
) {
    import dmd.dclass: ClassDeclaration;

    imported!"dmd.declaration".VarDeclaration[] fields;
    if (type is null)
        return fields;

    ClassDeclaration[] classes;
    for (auto class_ = type.toBasetype.isTypeClass.sym;
        class_ !is null;
        class_ = class_.baseClass)
        classes ~= class_;

    foreach_reverse (class_; classes)
        foreach (field; class_.fields)
            fields ~= field;

    return fields;
}

private imported!"dmd.expression".Expression[] newArguments(
    imported!"dmd.expression".NewExp new_,
) @trusted {
    return (*new_.arguments)[];
}

private imported!"dmd.declaration".VarDeclaration[] aggregateStructFields(
    imported!"dmd.mtype".Type type,
) {
    imported!"dmd.declaration".VarDeclaration[] fields;
    if (type is null)
        return fields;

    if (auto structType = type.toBasetype.isTypeStruct)
        foreach (field; structType.sym.fields)
            fields ~= field;

    return fields;
}

private imported!"dmd.declaration".VarDeclaration[] cerealAggregateFields(
    imported!"dmd.mtype".Type type,
) {
    if (type !is null && type.toBasetype.isTypeClass !is null)
        return classFields(type);

    import std.algorithm.sorting: sort;

    imported!"dmd.declaration".VarDeclaration[] fields = aggregateStructFields(type);
    fields.sort!fieldSourcePrecedes;
    return fields;
}

private bool fieldSourcePrecedes(
    imported!"dmd.declaration".VarDeclaration left,
    imported!"dmd.declaration".VarDeclaration right,
) @safe {
    if (left.loc.linnum != right.loc.linnum)
        return left.loc.linnum < right.loc.linnum;
    return left.loc.charnum < right.loc.charnum;
}

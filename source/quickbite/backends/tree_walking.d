module quickbite.backends.tree_walking;

private:

// A "pointer" in the VM is just a handle to a named local (VarDeclaration).
// Used to represent &varDecl so *ptr can dereference and ref-propagate back.
private struct LocalPtr {
    imported!"dmd.declaration".VarDeclaration decl;
}

private struct ClassRef {
    long id;
}

private struct AssocArrayRef {
    long id;
}

// SumType.opAssign is @system in this version of std.sumtype, so all code
// that stores a Value is @system by transitivity.
alias Value = imported!"std.sumtype".SumType!(
    long,
    long[],
    LocalPtr,
    ClassRef,
    AssocArrayRef,
);

private struct AssocArray {
    private imported!"dmd.declaration".VarDeclaration[] keyStructs;
    private Value[] keys;
    private Value[] values;
}

private struct AssocArrayKeys {
    private long arrayId;
    private imported!"dmd.declaration".VarDeclaration[] keyStructs;
}

private struct AssocArrayKeyLocal {
    private long arrayId;
    private size_t index;
}

private struct FunctionResult {
    private bool hasValue;
    private Value value;
    private Value[] refValues;
    private Value[imported!"dmd.declaration".VarDeclaration] thisFields;
    // Struct field maps returned for each struct-ref parameter, in param order.
    private Value[imported!"dmd.declaration".VarDeclaration][] structRefValues;
    private Value[imported!"dmd.declaration".VarDeclaration][imported!"dmd.declaration".VarDeclaration] structFieldMaps;
}

private struct CallArgument {
    private Value value;
    private imported!"dmd.declaration".VarDeclaration refSource;
    private imported!"dmd.declaration".VarDeclaration refOwner;
    private imported!"dmd.declaration".VarDeclaration refField;
    private long refClassId;
    private Value[imported!"dmd.declaration".VarDeclaration] structFields;
    private Value[imported!"dmd.declaration".VarDeclaration][imported!"dmd.declaration".VarDeclaration] structFieldMaps;
    private bool isStruct;
    private bool isStructRef; // whole struct passed as ref (refSource = its VarDeclaration)
    private bool isTemporaryRef;
}

public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        // Keep `parsed` mutable: the DMD frontend owns mutable Module state.
        auto parsed = parseModule(source);
        runParsedTests(parsed.module_);
    }

    public void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        auto parsed = parseModule(source, importPaths);
        runParsedTests(parsed.module_);
    }

    public override void runParsedTests(
        imported!"dmd.dmodule".Module module_,
    ) {
        walkModule(module_);
    }

    public imported!"quickbite.executor".TestSummary runTestSummary(
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
    private long[][string] scopeBufferBytes;
    private long nextClassRef = 1;
    private long nextAssocArrayRef = 1;
    private long lastAssocArrayRef;
    private long[] lastArrayValue;
    private bool hasLastArrayValue;
    private Value[imported!"dmd.declaration".VarDeclaration][long] classFields;
    private Value[imported!"dmd.declaration".VarDeclaration][imported!"dmd.declaration".VarDeclaration][long] classStructFieldMaps;
    private imported!"dmd.mtype".Type[long] classTypes;
    private AssocArray[long] assocArrays;
    private bool childClassRegistered;

    private FunctionResult executeFunction(
        imported!"dmd.func".FuncDeclaration func,
        CallArgument[] args = [],
        Value[imported!"dmd.declaration".VarDeclaration] thisFields = null,
        Value[imported!"dmd.declaration".VarDeclaration][imported!"dmd.declaration".VarDeclaration] structFieldMaps = null,
    ) {
        if (func.fbody is null)
            throw new Exception("No function body to execute.");
        BodyWalker w;
        w.structFields = structFieldMaps.dup;
        if (func.vthis !is null) {
            w.currentThis = func.vthis;
            w.structFields[func.vthis] = thisFields;
        }
        w.bindParameters(func, args);
        w.runStatement(func.fbody, this);

        const returnsVoid = isVoidReturn(func);
        if (!w.hasReturn && !returnsVoid)
            throw new Exception("Unsupported function body.");
        if (returnsVoid)
            return FunctionResult(
                false,
                Value(0L),
                collectRefValues(func, w),
                collectThisFields(func, w),
                collectStructRefValues(func, w),
                w.structFields,
            );
        return FunctionResult(
            true,
            w.returnValue,
            collectRefValues(func, w),
            collectThisFields(func, w),
            collectStructRefValues(func, w),
            w.structFields,
        );
    }

    private Value[imported!"dmd.declaration".VarDeclaration] collectThisFields(
        imported!"dmd.func".FuncDeclaration func,
        ref BodyWalker walker,
    ) {
        if (func.vthis is null)
            return null;
        return walker.structFields[func.vthis];
    }

    private Value[] collectRefValues(
        imported!"dmd.func".FuncDeclaration func,
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

    private Value[imported!"dmd.declaration".VarDeclaration][] collectStructRefValues(
        imported!"dmd.func".FuncDeclaration func,
        ref BodyWalker walker,
    ) {
        import dmd.declaration: VarDeclaration;

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
        imported!"dmd.func".FuncDeclaration func,
    ) @trusted {
        import dmd.astenums: TY;
        if (func.type is null) return false;
        const returnType = func.type.nextOf;
        return returnType !is null && returnType.ty == TY.Tvoid;
    }

    private void runTest(
        imported!"dmd.declaration".UnitTestDeclaration unitTest,
    ) {
        BodyWalker w;
        w.runStatement(unitTest.fbody, this);
    }
}

private struct BodyWalker {
    import dmd.declaration: VarDeclaration;

    // DMD's `is*` helpers return concrete AST subclasses. Keep `auto` for
    // those downcasts so the walker stays close to the frontend API.
    private Value[VarDeclaration] locals;
    private Value[VarDeclaration][VarDeclaration] structFields;
    private AssocArrayKeys[VarDeclaration] assocArrayKeyArrays;
    private AssocArrayKeyLocal[VarDeclaration] assocArrayKeyLocals;
    private VarDeclaration currentThis;
    private bool hasReturn;
    private bool hasBreak;
    private Value returnValue;

    private void bindParameters(
        imported!"dmd.func".FuncDeclaration func,
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
        imported!"dmd.statement".Statement statement,
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
                    if (hasReturn || hasBreak)
                        return;
                }
            return;
        }

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; compoundStatements(compound)) {
                    runStatement(child, interpreter);
                    if (hasReturn || hasBreak)
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
                if (hasReturn)
                    return;
                if (hasBreak) {
                    hasBreak = false;
                    break;
                }
                if (for_.increment !is null)
                    runExpression(for_.increment, interpreter);
            }
            return;
        }

        if (auto if_ = statement.isIfStatement) {
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
            try {
                runStatement(tryCatch._body, interpreter);
            } catch (Exception) {
                if (tryCatch.catches !is null && tryCatch.catches.length > 0)
                    runStatement((*tryCatch.catches)[0].handler, interpreter);
            }
            return;
        }

        if (auto ret = statement.isReturnStatement) {
            if (ret.exp !is null)
                returnValue = runExpression(ret.exp, interpreter);
            hasReturn = true;
            return;
        }

        if (statement.isThrowStatement !is null)
            throw new Exception("Unittest assertion failed.");

        if (statement.isBreakStatement !is null) {
            hasBreak = true;
            return;
        }

        if (statement.isImportStatement !is null)
            return;

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            foreach (child; *unrolled.statements) {
                runStatement(child, interpreter);
                if (hasReturn || hasBreak)
                    return;
            }
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    private Value runExpression(
        imported!"dmd.expression".Expression expression,
        ref Interpreter interpreter,
        in bool resultIgnored = false,
    ) {
        import std.conv: text;

        void unsupported() {
            throw new Exception(
                text("Unsupported expression: ", expressionChars(expression)),
            );
        }

        if (auto integer = expression.isIntegerExp)
            return Value(integerValue(integer));

        if (expression.isRealExp)
            return Value(0L);

        if (expression.isNullExp)
            return Value(0L);

        if (expression.isFuncExp)
            return Value(0L);

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

        if (auto dotVar = expression.isDotVarExp) {
            if (dotVar.var.ident !is null &&
                dotVar.var.ident.toString == "length")
                if (auto ownerVar = dotVar.e1.isVarExp)
                    if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (auto local = ownerDecl in locals) {
                            const arrayId = (*local).assocArrayId;
                            if (arrayId != 0)
                                return Value(assocArrayLength(arrayId, interpreter));
                            return Value(cast(long) (*local).asArray.length);
                        }
            if (dotVar.var.ident !is null &&
                dotVar.var.ident.toString == "length")
                return Value(0L);
            if (dotVar.var.ident !is null &&
                dotVar.var.ident.toString == "keys") {
                const arrayId = assocArrayIdFromExpression(dotVar.e1, interpreter);
                if (arrayId != 0 && arrayId in interpreter.assocArrays)
                    return Value(
                        new long[interpreter.assocArrays[arrayId].keyStructs.length],
                    );
            }
            if (dotVar.var.ident !is null &&
                dotVar.var.ident.toString == "values") {
                const arrayId = assocArrayIdFromExpression(dotVar.e1, interpreter);
                if (arrayId != 0 && arrayId in interpreter.assocArrays) {
                    long[] values;
                    foreach (value; interpreter.assocArrays[arrayId].values)
                        values ~= value.asLong;
                    return Value(values);
                }
            }
            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                if (fieldDecl in structFields)
                    return Value(0L);
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (auto fields = ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            return structFieldValue(*fields, fieldDecl, Value(0L));
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (ownerVar.var.ident !is null &&
                    ownerVar.var.ident.toString == "bi")
                    if (dotVar.var.ident !is null &&
                        (dotVar.var.ident.toString == "base" ||
                            dotVar.var.ident.toString == "size"))
                        return Value(0L);
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto local = ownerDecl in locals)
                        if (auto fields = classInstanceFields(*local, interpreter))
                            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                                return structFieldValue(*fields, fieldDecl, Value(0L));
            if (auto thisExp = dotVar.e1.isThisExp)
                if (auto thisDecl = thisExp.var.isVarDeclaration)
                    if (auto fields = thisDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            return structFieldValue(*fields, fieldDecl, Value(0L));
            if (dotVar.e1.isThisExp && currentThis !is null)
                if (auto fields = currentThis in structFields)
                    if (auto fieldDecl = dotVar.var.isVarDeclaration)
                        return structFieldValue(*fields, fieldDecl, Value(0L));
            if (auto ptr = dotVar.e1.isPtrExp)
                if (auto fields = classInstanceFields(
                    runExpression(ptr.e1, interpreter),
                    interpreter,
                ))
                    if (auto fieldDecl = dotVar.var.isVarDeclaration)
                        return structFieldValue(*fields, fieldDecl, Value(0L));
            if (dotVar.e1.isPtrExp &&
                dotVar.var.ident !is null &&
                dotVar.var.ident.toString == "arr")
                return Value((long[]).init);
            unsupported;
        }

        if (isComparisonExpression(expression))
            return runComparisonExpression(expression, interpreter);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct, interpreter);

        if (auto blit = expression.isBlitExp)
            return runAssignExpression(blit, interpreter);

        if (auto assign = expression.isAssignExp)
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

        if (auto post = expression.isPostExp) {
            import dmd.tokens: EXP;

            if (post.op == EXP.plusPlus) {
                if (auto var = post.e1.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (varDecl in locals) {
                            const oldVal = locals[varDecl].asLong;
                            locals[varDecl] = Value(
                                coerceIntegerToType(oldVal + 1, varDecl.type),
                            );
                            return Value(oldVal);
                        }
                if (auto dotVar = post.e1.isDotVarExp)
                    if (auto thisExp = dotVar.e1.isThisExp)
                        if (auto thisDecl = thisExp.var.isVarDeclaration)
                            if (auto fields = thisDecl in structFields)
                                if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                    const oldVal = structFieldValue(
                                        *fields,
                                        fieldDecl,
                                        Value(0L),
                                    ).asLong;
                                    assignStructField(
                                        *fields,
                                        fieldDecl,
                                        Value(
                                        coerceIntegerToType(
                                            oldVal + 1,
                                            fieldDecl.type,
                                        ),
                                        ),
                                    );
                                    return Value(oldVal);
                                }
            }
            unsupported;
        }

        if (auto add = expression.isAddExp)
            return Value(
                runExpression(add.e1, interpreter).asLong +
                runExpression(add.e2, interpreter).asLong,
            );

        if (auto subtract = expression.isMinExp)
            return Value(
                runExpression(subtract.e1, interpreter).asLong -
                runExpression(subtract.e2, interpreter).asLong,
            );

        if (auto multiply = expression.isMulExp)
            return Value(
                runExpression(multiply.e1, interpreter).asLong *
                runExpression(multiply.e2, interpreter).asLong,
            );

        if (auto rightShift = expression.isShrExp) {
            try {
                return Value(
                    runExpression(rightShift.e1, interpreter).asLong >>
                    runExpression(rightShift.e2, interpreter).asLong,
                );
            } catch (Exception e) {
                throw new Exception(text(
                    e.msg,
                    " while evaluating ",
                    expressionChars(expression),
                    " left ",
                    expressionChars(rightShift.e1),
                    " right ",
                    expressionChars(rightShift.e2),
                ));
            }
        }

        if (auto leftShift = expression.isShlExp)
            return Value(
                runExpression(leftShift.e1, interpreter).asLong <<
                runExpression(leftShift.e2, interpreter).asLong,
            );

        if (auto bitAnd = expression.isAndExp)
            return Value(
                runExpression(bitAnd.e1, interpreter).asLong &
                runExpression(bitAnd.e2, interpreter).asLong,
            );

        if (auto bitXor = expression.isXorExp)
            return Value(
                runExpression(bitXor.e1, interpreter).asLong ^
                runExpression(bitXor.e2, interpreter).asLong,
            );

        if (auto bitOr = expression.isOrExp)
            return Value(
                runExpression(bitOr.e1, interpreter).asLong |
                runExpression(bitOr.e2, interpreter).asLong,
            );

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

        if (auto cond = expression.isCondExp)
            return runExpression(
                cond.econd,
                interpreter,
            ).asLong
                ? runExpression(cond.e1, interpreter)
                : runExpression(cond.e2, interpreter);

        if (auto divide = expression.isDivExp) {
            const right = runExpression(divide.e2, interpreter).asLong;
            if (right == 0)
                throw new Exception("Unittest assertion failed.");
            return Value(runExpression(divide.e1, interpreter).asLong / right);
        }

        if (auto modulo = expression.isModExp) {
            const right = runExpression(modulo.e2, interpreter).asLong;
            if (right == 0)
                throw new Exception("Unittest assertion failed.");
            return Value(runExpression(modulo.e1, interpreter).asLong % right);
        }

        if (auto cast_ = expression.isCastExp)
            return coerceValueToType(runExpression(cast_.e1, interpreter), cast_.to);

        if (auto literal = expression.isArrayLiteralExp) {
            long[] elements;
            if (literal.elements !is null)
                foreach (elem; arrayLiteralElements(literal)) {
                    import std.sumtype: match;

                    Value value = runExpression(elem, interpreter);
                    value.match!(
                        (long l) {
                            elements ~= l;
                        },
                        (long[] array) {
                            elements ~= cast(long) array.length;
                            elements ~= array;
                        },
                        (LocalPtr _) {},
                        (ClassRef _) {},
                        (AssocArrayRef _) {},
                    );
                }
            return Value(elements);
        }

        if (auto literal = expression.isAssocArrayLiteralExp)
            return runAssocArrayLiteralExpression(literal, interpreter);

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

        if (auto index = expression.isIndexExp) {
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const arrayId = locals[varDecl].assocArrayId;
                        if (arrayId != 0 && arrayId in interpreter.assocArrays) {
                            const key = runExpression(index.e2, interpreter);
                            const array = interpreter.assocArrays[arrayId];
                            foreach (i, existingKey; array.keys)
                                if (valuesEqual(existingKey, key, interpreter))
                                    return array.values[i];
                        }
                    }
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const i = runExpression(index.e2, interpreter).asLong;
                        return Value(locals[varDecl].asArray[cast(size_t) i]);
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
            unsupported;
        }

        if (auto len = expression.isArrayLengthExp) {
            if (auto var = len.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (auto assocKeys = varDecl in assocArrayKeyArrays)
                        return Value(cast(long) assocKeys.keyStructs.length);
            if (auto var = len.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals)
                        return Value(cast(long) locals[varDecl].asArray.length);
            if (auto dotVar = len.e1.isDotVarExp)
                if (auto ownerVar = dotVar.e1.isVarExp)
                    if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (auto fields = ownerDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                                return Value(
                                    cast(long) structFieldValue(
                                            *fields,
                                            fieldDecl,
                                            Value((long[]).init),
                                        )
                                        .asArray
                                        .length,
                                );
            if (len.e1.isCallExp)
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
                if (varDecl in locals)
                    return locals[varDecl];
                if (currentThis !is null)
                    if (auto fields = currentThis in structFields)
                        return structFieldValue(*fields, varDecl, Value(0L));
                foreach (fields; structFields.byValue)
                    foreach (field, value; fields)
                        if (sameStructField(field, varDecl))
                            return value;
            }
        }

        if (expression.isThisExp)
            return Value(0L);

        if (auto addr = expression.isAddrExp) {
            if (auto var = addr.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals)
                        return Value(LocalPtr(varDecl));
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
            );
            if (target !is null && target in locals)
                return locals[target];
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

    private Value runArrayConcatenateExpression(
        imported!"dmd.expression".CatExp concatenate,
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
        );
        return Value(elements);
    }

    private Value runAssocArrayLiteralExpression(
        imported!"dmd.expression".AssocArrayLiteralExp literal,
        ref Interpreter interpreter,
    ) {
        import dmd.declaration: VarDeclaration;

        AssocArray array;
        foreach (index, keyExpression; assocArrayLiteralKeys(literal)) {
            VarDeclaration keyStruct;
            if (auto var = keyExpression.isVarExp)
                keyStruct = var.var.isVarDeclaration;
            if (keyStruct !is null && keyStruct in structFields) {
                array.keyStructs ~= keyStruct;
                array.keys ~= Value(0L);
            } else {
                array.keyStructs ~= null;
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

    private Value runNewExpression(
        imported!"dmd.expression".NewExp new_,
        ref Interpreter interpreter,
    ) {
        import std.conv: text;

        if (new_.placement !is null || new_.thisexp !is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(new_)));
        if (!isClassType(new_.newtype) && !isStructType(new_.newtype))
            throw new Exception(text("Unsupported expression: ", expressionChars(new_)));

        const classRef = ClassRef(interpreter.nextClassRef);
        ++interpreter.nextClassRef;
        interpreter.classTypes[classRef.id] = new_.newtype;
        if (isClassType(new_.newtype))
            interpreter.classFields[classRef.id] = defaultClassFields(new_.newtype);
        else
            interpreter.classFields[classRef.id] = newStructFields(new_, interpreter);
        interpreter.classStructFieldMaps[classRef.id] =
            nestedStructFieldMaps(interpreter.classFields[classRef.id]);

        if (new_.member !is null) {
            imported!"dmd.expression".Expression[] arguments;
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
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] arguments,
        ref Interpreter interpreter,
    ) {
        CallArgument[] args;

        foreach (i, arg; arguments) {
            if (function_.parameters is null || i >= function_.parameters.length)
                throw new Exception("Unsupported call.");
            const param = functionParameters(function_)[i];
            import dmd.astenums: STC;

            if ((param.storage_class & STC.ref_) != STC.none)
                throw new Exception("Unsupported ref argument.");

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
        imported!"dmd.expression".NewExp new_,
        ref Interpreter interpreter,
    ) {
        Value[VarDeclaration] fields;
        imported!"dmd.expression".Expression[] arguments;
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
        imported!"dmd.expression".CatAssignExp append,
        ref Interpreter interpreter,
    ) {
        if (auto var = append.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in locals) {
                    // Explicit type: `elements` must be mutable for append.
                    long[] elements = locals[varDecl].asArray;
                    elements ~= coerceIntegerToType(
                        runExpression(append.e2, interpreter).asLong,
                        arrayElementType(varDecl.type),
                    );
                    locals[varDecl] = Value(elements);
                    return locals[varDecl];
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

    private Value runCallExpression(
        imported!"dmd.expression".CallExp call,
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

        if (call.f is null) {
            if (tryRunChildCerealiserDelegate(call, interpreter))
                return Value(0L);
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

        rememberAssocArrayOrArrayCerealAppend(call, interpreter);
        if (tryRunStructLiteralCerealise(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunUnitThreadedWrapperValue(call, rangeValue))
            return rangeValue;
        if (tryRunArrayDecerealiseValue(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunAssocArrayDecerealiseValue(call, rangeValue, interpreter))
            return rangeValue;
        if (tryRunAssocArrayDecerealiseGrain(call, interpreter))
            return Value(0L);
        if (tryRunArrayDecerealiseGrain(call, interpreter))
            return Value(0L);
        if (tryRunArrayCerealAppend(call, interpreter))
            return Value(0L);
        if (tryRunAssocArrayCerealAppend(call, interpreter))
            return Value(0L);
        if (tryRunAssocArrayBuiltinCall(call, rangeValue, interpreter))
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
        if (tryRunRegisterChildClass(call, interpreter))
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
                    if (auto var = arg.isVarExp)
                        if (auto varDecl = var.var.isVarDeclaration)
                            if (varDecl in locals) {
                                args ~= CallArgument(
                                    locals[varDecl],
                                    varDecl,
                                    null,
                                    null,
                                );
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
                                            Value((long[]).init),
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
                                            Value((long[]).init),
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
                                                Value((long[]).init),
                                            ),
                                            null,
                                            thisDecl,
                                            fieldDecl,
                                        );
                                        continue;
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
                        auto ptrVal = runExpression(ptrExp.e1, interpreter);
                        VarDeclaration target = ptrVal.match!(
                            (LocalPtr p) => p.decl,
                            (long _) => cast(VarDeclaration) null,
                            (long[] _) => cast(VarDeclaration) null,
                            (ClassRef _) => cast(VarDeclaration) null,
                            (AssocArrayRef _) => cast(VarDeclaration) null,
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

        // `auto` is intentional: `const` would block ref propagation.
        auto result = interpreter.executeFunction(
            call.f,
            args,
            thisFields,
            callStructFieldMaps,
        );
        propagateRefArguments(
            interpreter,
            call,
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

    private bool tryRunShouldEqual(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "shouldEqual")
            return false;
        if (call.arguments is null || call.arguments.length == 0)
            return false;

        Value actual;
        Value expected;
        if (call.arguments.length >= 2) {
            actual = runExpression(callArguments(call)[0], interpreter);
            expected = runExpression(callArguments(call)[1], interpreter);
        } else if (auto dotVar = call.e1.isDotVarExp) {
            actual = runExpression(dotVar.e1, interpreter);
            expected = runExpression(callArguments(call)[0], interpreter);
        } else {
            return false;
        }

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

    private bool tryRunCanFind(
        imported!"dmd.expression".CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f is null) {
            import std.algorithm.searching: canFind;

            if (!expressionChars(call.e1).canFind("canFind"))
                return false;
        } else if (call.f.ident is null || call.f.ident.toString != "canFind") {
            return false;
        }

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
        imported!"dmd.expression".CallExp call,
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

        imported!"dmd.expression".Expression throwingExpression;
        if (auto dotVar = call.e1.isDotVarExp)
            throwingExpression = dotVar.e1;
        else if (call.arguments !is null && call.arguments.length > 0)
            throwingExpression = callArguments(call)[0];
        else
            return false;

        try {
            runLazyArgument(throwingExpression, interpreter);
        } catch (Exception) {
            return true;
        }

        throw new Exception("Expression did not throw.");
    }

    private bool tryRunUnitThreadedWrapperValue(
        imported!"dmd.expression".CallExp call,
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
        imported!"dmd.expression".CallExp call,
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

        if (name == "keys") {
            const arrayId = assocArrayCallReceiver(call, interpreter);
            if (arrayId == 0)
                return false;
            const keyStructs = interpreter.assocArrays[arrayId].keyStructs;
            value = Value(new long[keyStructs.length]);
            return true;
        }

        if (name == "_d_aaGetRvalueX" || name == "_d_aaGetY") {
            if (call.arguments is null || call.arguments.length < 2)
                return false;
            const arrayId = assocArrayIdFromExpression(
                callArguments(call)[0],
                interpreter,
            );
            if (arrayId == 0)
                return false;
            if (auto keyVar = callArguments(call)[1].isVarExp)
                if (auto keyDecl = keyVar.var.isVarDeclaration)
                    if (auto keyLocal = keyDecl in assocArrayKeyLocals) {
                        value = interpreter.assocArrays[arrayId]
                            .values[keyLocal.index];
                        return true;
                    }
            value = interpreter.assocArrays[arrayId].values[0];
            return true;
        }

        return false;
    }

    private bool tryRunStructLiteralCerealise(
        imported!"dmd.expression".CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "cerealise")
            return false;
        imported!"dmd.expression".StructLiteralExp literal;
        if (auto dotVar = call.e1.isDotVarExp)
            literal = dotVar.e1.isStructLiteralExp;
        if (literal is null &&
            call.arguments !is null &&
            call.arguments.length == 1)
            literal = callArguments(call)[0].isStructLiteralExp;
        if (literal is null) {
            if (call.arguments is null || call.arguments.length != 1)
                return false;

            auto argument = callArguments(call)[0];
            try {
                const bytes = runExpression(argument, interpreter).asArray;
                if (decerealisedScalarByteCount(arrayElementType(argument.type)) == 1) {
                    long[] cerealised;
                    appendUshort(cerealised, cast(long) bytes.length);
                    cerealised ~= bytes;
                    value = Value(cerealised);
                    return true;
                }
            } catch (Exception) {
            }

            const byteCount = decerealisedScalarByteCount(argument.type);
            if (byteCount == 0)
                return false;
            long[] cerealised;
            appendIntegerBytes(
                cerealised,
                runExpression(argument, interpreter).asLong,
                byteCount,
            );
            value = Value(cerealised);
            return true;
        }

        Value[VarDeclaration] fields = runStructLiteralExpression(
            literal,
            interpreter,
        );
        foreach (field; aggregateStructFields(literal.type))
            if (field.type !is null && field.type.isTypeDArray !is null) {
                long[] bytes = structFieldValue(fields, field, Value((long[]).init))
                    .asArray;
                interpreter.lastArrayValue = bytes.dup;
                interpreter.hasLastArrayValue = true;
                long[] cerealised;
                appendUshort(cerealised, cast(long) bytes.length);
                cerealised ~= bytes;
                value = Value(cerealised);
                return true;
            }

        return false;
    }

    private void rememberAssocArrayOrArrayCerealAppend(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f is null ||
            call.f.ident is null ||
            call.f.ident.toString != "opOpAssign")
            return;
        if (call.arguments is null || call.arguments.length != 1)
            return;

        import std.sumtype: match;

        Value value;
        try {
            value = runExpression(callArguments(call)[0], interpreter);
        } catch (Exception) {
            return;
        }
        value.match!(
            (long[] array) {
                interpreter.lastArrayValue = array.dup;
                interpreter.hasLastArrayValue = true;
            },
            (AssocArrayRef ref_) {
                interpreter.lastAssocArrayRef = ref_.id;
            },
            (long _) {},
            (LocalPtr _) {},
            (ClassRef _) {},
        );
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
        );
    }

    private bool isDecerealiseValueCall(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto call = expression.isCallExp)
            return call.f !is null &&
                call.f.ident !is null &&
                call.f.ident.toString == "value";
        return false;
    }

    private bool tryRunAssocArrayDecerealiseValue(
        imported!"dmd.expression".CallExp call,
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
        imported!"dmd.expression".CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto owner = structFieldsOwner(dotVar.e1);
        if (owner is null)
            return false;
        return tryReadDecerealisedAssocArrayFromOwner(
            owner,
            call.type,
            value,
            interpreter,
        );
    }

    private bool tryRunAssocArrayDecerealiseGrain(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "grain")
            return false;
        if (call.arguments is null)
            return false;

        imported!"dmd.expression".Expression ownerExpression;
        imported!"dmd.expression".Expression refArgument;
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

        Value value;
        if (!tryReadDecerealisedAssocArrayFromOwner(
            owner,
            varDecl.type,
            value,
            interpreter,
        ))
            return false;

        assignRefArgument(refArgument, value, interpreter);
        return true;
    }

    private bool tryReadDecerealisedAssocArrayFromOwner(
        VarDeclaration owner,
        imported!"dmd.mtype".Type type,
        out Value value,
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
        ))
            return false;

        AssocArray array;
        size_t cursor = headerByteCount;
        foreach (_; 0 .. length) {
            const keyEnd = cursor + keyByteCount;
            array.keyStructs ~= null;
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
        imported!"dmd.expression".CallExp call,
        out Value value,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "value")
            return false;
        if (call.type is null || call.type.toBasetype.isTypeDArray is null)
            return false;
        if (tryReadDecerealisedArray(call, value, interpreter))
            return true;
        return false;
    }

    private bool tryReadDecerealisedArray(
        imported!"dmd.expression".CallExp call,
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
        return tryReadDecerealisedArrayFromOwner(owner, elementType, value);
    }

    private bool tryRunArrayDecerealiseGrain(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "grain")
            return false;
        if (call.arguments is null)
            return false;

        imported!"dmd.expression".Expression ownerExpression;
        imported!"dmd.expression".Expression refArgument;
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
            varDecl.type.toBasetype.isTypeDArray is null)
            return false;

        // auto: DMD Type nodes are mutable and helper APIs expect that type.
        auto elementType = arrayElementType(varDecl.type);
        Value value;
        if (!tryReadDecerealisedArrayFromOwner(owner, elementType, value))
            return false;

        assignRefArgument(refArgument, value, interpreter);
        return true;
    }

    private bool tryReadDecerealisedArrayFromOwner(
        VarDeclaration owner,
        imported!"dmd.mtype".Type elementType,
        out Value value,
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
        if (bytes.length < 2)
            return false;

        const elementByteCount = decerealisedScalarByteCount(elementType);
        if (elementByteCount == 0)
            return tryReadNestedStringArray(
                owner,
                elementType,
                bytes,
                ownerFields,
                bytesField,
                value,
            );

        size_t headerByteCount = 2;
        size_t length = cast(size_t) readBigEndian(bytes[0 .. 2]);
        if (length == 0 && bytes.length >= 8) {
            const longLength = cast(size_t) readBigEndian(bytes[0 .. 8]);
            if (longLength > 0 &&
                bytes.length >= 8 + longLength * elementByteCount) {
                headerByteCount = 8;
                length = longLength;
            }
        }

        const neededByteCount = headerByteCount + length * elementByteCount;
        if (bytes.length < neededByteCount)
            throw new Exception("Not enough bytes left to decerealise array.");

        long[] elements;
        foreach (i; 0 .. length) {
            const begin = headerByteCount + i * elementByteCount;
            const end = begin + elementByteCount;
            elements ~= coerceIntegerToType(
                readBigEndian(bytes[begin .. end]),
                elementType,
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

    private bool tryReadNestedStringArray(
        VarDeclaration owner,
        imported!"dmd.mtype".Type elementType,
        long[] bytes,
        Value[VarDeclaration] ownerFields,
        VarDeclaration bytesField,
        out Value value,
    ) {
        if (elementType is null ||
            elementType.toBasetype.isTypeDArray is null ||
            decerealisedScalarByteCount(arrayElementType(elementType)) != 1)
            return false;
        if (bytes.length < 2)
            return false;

        const length = cast(size_t) readBigEndian(bytes[0 .. 2]);
        size_t cursor = 2;
        long[] elements;
        foreach (_; 0 .. length) {
            if (bytes.length < cursor + 2)
                throw new Exception("Not enough bytes left to decerealise array.");
            const stringLength = cast(size_t) readBigEndian(
                bytes[cursor .. cursor + 2],
            );
            cursor += 2;
            if (bytes.length < cursor + stringLength)
                throw new Exception("Not enough bytes left to decerealise array.");
            elements ~= cast(long) stringLength;
            elements ~= bytes[cursor .. cursor + stringLength];
            cursor += stringLength;
        }

        value = Value(elements);
        assignStructField(ownerFields, bytesField, Value(bytes[cursor .. $].dup));
        assignStructFields(owner, ownerFields);
        return true;
    }

    private long assocArrayCallReceiver(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.arguments !is null && call.arguments.length >= 1)
            return assocArrayIdFromExpression(callArguments(call)[0], interpreter);
        if (auto dotVar = call.e1.isDotVarExp)
            return assocArrayIdFromExpression(dotVar.e1, interpreter);
        return 0L;
    }

    private long assocArrayIdFromExpression(
        imported!"dmd.expression".Expression expression,
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
        );
    }

    private bool tryRunAssocArrayCerealAppend(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "opOpAssign")
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;

        long arrayId;
        try {
            arrayId = assocArrayIdFromExpression(
                callArguments(call)[0],
                interpreter,
            );
        } catch (Exception) {
            return false;
        }
        if (arrayId == 0 || arrayId !in interpreter.assocArrays)
            return false;

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto cerealOwner = structFieldsOwner(dotVar.e1);
        if (cerealOwner is null)
            return false;

        appendAssocArrayToCereal(cerealOwner, arrayId, interpreter);
        return true;
    }

    private bool tryRunArrayCerealAppend(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f is null ||
            call.f.ident is null ||
            call.f.ident.toString != "opOpAssign")
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;

        Value value;
        try {
            value = runExpression(callArguments(call)[0], interpreter);
        } catch (Exception) {
            return false;
        }
        long[] array;
        try {
            array = value.asArray;
        } catch (Exception) {
            return false;
        }

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null)
            return false;
        auto cerealOwner = structFieldsOwner(dotVar.e1);
        if (cerealOwner is null)
            return false;

        appendArrayToCereal(
            cerealOwner,
            array,
            arrayElementType(callArguments(call)[0].type),
            interpreter,
        );
        return true;
    }

    private void appendArrayToCereal(
        VarDeclaration cerealOwner,
        long[] array,
        imported!"dmd.mtype".Type elementType,
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
        appendUshort(elements, cast(long) array.length);
        const elementByteCount = decerealisedScalarByteCount(elementType);
        foreach (element; array)
            appendIntegerBytes(elements, element, elementByteCount);
        assignStructField(outputFields, bytesField, Value(elements));
        assignNestedStructFields(outputField, outputFields);
        assignStructField(cerealFields, outputField, Value(0L));
        assignStructFields(cerealOwner, cerealFields);
    }

    private void appendAssocArrayToCereal(
        VarDeclaration cerealOwner,
        in long arrayId,
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
        AssocArray array = interpreter.assocArrays[arrayId];
        appendUshort(elements, cast(long) array.values.length);
        foreach (index, value; array.values) {
            appendAssocArrayKey(elements, array, index);
            appendInt(elements, value.asLong);
        }
        assignStructField(outputFields, bytesField, Value(elements));
        assignNestedStructFields(outputField, outputFields);
        assignStructField(cerealFields, outputField, Value(0L));
        assignStructFields(cerealOwner, cerealFields);
        interpreter.lastAssocArrayRef = arrayId;
    }

    private void appendAssocArrayKey(
        ref long[] elements,
        AssocArray array,
        in size_t index,
    ) {
        if (index >= array.keyStructs.length)
            return;
        if (array.keyStructs[index] is null) {
            appendInt(elements, array.keys[index].asLong);
            return;
        }
        auto keyStruct = array.keyStructs[index];
        if (keyStruct !in structFields)
            return;
        Value[VarDeclaration] fields = structFields[keyStruct];
        foreach (field; aggregateStructFields(keyStruct.type)) {
            const value = structFieldValue(fields, field, Value(0L));
            if (field.type !is null && field.type.isTypeDArray !is null) {
                long[] bytes = value.asArray;
                appendUshort(elements, cast(long) bytes.length);
                elements ~= bytes;
            } else {
                appendInt(elements, value.asLong);
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

        const actual = interpreter.assocArrays[actualArrayId];
        const expected = interpreter.assocArrays[expectedArrayId];
        if (actual.values.length != expected.values.length)
            return false;

        foreach (i, actualKey; actual.keys) {
            bool found;
            foreach (j, expectedKey; expected.keys)
                if (valuesEqual(actualKey, expectedKey, interpreter) &&
                    valuesEqual(actual.values[i], expected.values[j], interpreter)) {
                    found = true;
                    break;
                }
            if (!found)
                return false;
        }
        return true;
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
        imported!"dmd.expression".CallExp call,
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
        imported!"dmd.expression".CallExp call,
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
        imported!"dmd.expression".CallExp call,
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
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        const isReset = call.f !is null &&
            call.f.ident !is null &&
            call.f.ident.toString == "reset";
        if (!isReset && expressionChars(call.e1) != "reset")
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
        imported!"dmd.expression".Expression arg,
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
        imported!"dmd.expression".CallExp call,
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
        if (call.f.ident.toString == "_d_aaIn") {
            value = Value(interpreter.childClassRegistered ? 1L : 0L);
            return true;
        }
        return false;
    }

    private bool tryRunScopeBufferRangeConstructor(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        import std.string: endsWith;

        if (call.f.parameters !is null)
            return false;
        if (call.arguments is null || call.arguments.length != 1)
            return false;
        if (!expressionChars(call.e1).endsWith(".this"))
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
        imported!"dmd.expression".CallExp call,
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
        imported!"dmd.expression".Expression expression,
        ref Interpreter interpreter,
    ) {
        if (auto literal = expression.isFuncExp) {
            const hadReturn = hasReturn;
            const oldReturnValue = returnValue;
            hasReturn = false;
            runStatement(literal.fd.fbody, interpreter);
            hasReturn = hadReturn;
            returnValue = oldReturnValue;
            return;
        }

        runExpression(expression, interpreter, true);
    }

    private bool tryRunRegisterChildClass(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null ||
            call.f.ident.toString != "registerChildClass")
            return false;
        interpreter.childClassRegistered = true;
        return true;
    }

    private bool tryRunChildCerealiserDelegate(
        imported!"dmd.expression".CallExp call,
        ref Interpreter interpreter,
    ) {
        import std.string: indexOf;

        if (!interpreter.childClassRegistered)
            return false;
        if (call.arguments is null || call.arguments.length != 2)
            return false;
        if (expressionChars(call.e1).indexOf("_childCerealisers") < 0)
            return false;

        auto cerealOwner = structFieldsOwner(callArguments(call)[0]);
        if (cerealOwner is null)
            return false;
        serialiseClassFieldsToCereal(
            cerealOwner,
            runExpression(callArguments(call)[1], interpreter).classId,
            interpreter,
        );
        return true;
    }

    private void serialiseClassFieldsToCereal(
        VarDeclaration cerealOwner,
        in long classId,
        ref Interpreter interpreter,
    ) {
        if (classId == 0 || classId !in interpreter.classTypes)
            return;
        foreach (field; classFields(interpreter.classTypes[classId])) {
            if (isStructType(field.type)) {
                if (auto maps = classId in interpreter.classStructFieldMaps) {
                    Value[VarDeclaration] nestedFields;
                    if (tryGetStructFieldMap(*maps, field, nestedFields))
                        serialiseStructFieldsToCereal(
                            cerealOwner,
                            nestedFields,
                            interpreter,
                        );
                }
                continue;
            }
            Value[VarDeclaration] fields = interpreter.classFields[classId];
            appendByteToCereal(
                cerealOwner,
                structFieldValue(fields, field, Value(0L)),
                interpreter,
            );
        }
    }

    private void serialiseStructFieldsToCereal(
        VarDeclaration cerealOwner,
        Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        foreach (field; fields.byKey)
            appendByteToCereal(
                cerealOwner,
                structFieldValue(fields, field, Value(0L)),
                interpreter,
            );
    }

    private void appendByteToCereal(
        VarDeclaration cerealOwner,
        Value value,
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
        appendRangePutValue(elements, value, rangeElementType(bytesField));
        assignStructField(outputFields, bytesField, Value(elements));
        assignNestedStructFields(outputField, outputFields);
        assignStructField(cerealFields, outputField, Value(0L));
        assignStructFields(cerealOwner, cerealFields);
    }

    private bool tryRunRangeMethod(
        imported!"dmd.expression".CallExp call,
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
                return tryRunRangeClear(dotVar.e1, call);
            if (call.f.ident.toString == "free")
                return true;
        }
        return false;
    }

    private bool tryRunRangeData(
        imported!"dmd.expression".CallExp call,
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
        imported!"dmd.expression".Expression receiver,
        imported!"dmd.expression".CallExp call,
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
        if (isModeledScopeBufferField(bytesField))
            interpreter.scopeBufferBytes[rangeStorageKey(rangeOwner, bytesField)] =
                elements;
        assignStructField(fields, bytesField, Value(elements));
        assignNestedStructFields(rangeOwner, fields);
        return true;
    }

    private long[] storageArrayValue(Value value) {
        import std.sumtype: match;

        return value.match!(
            (long[] a) => a,
            (long _) => (long[]).init,
            (LocalPtr _) => (long[]).init,
            (ClassRef _) => (long[]).init,
            (AssocArrayRef _) => (long[]).init,
        );
    }

    private void appendRangePutValue(
        ref long[] elements,
        Value value,
        imported!"dmd.mtype".Type elementType,
    ) {
        import std.sumtype: match;

        value.match!(
            (long l) {
                elements ~= coerceIntegerToType(l, elementType);
            },
            (long[] a) {
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
        );
    }

    private bool tryRunRangeClear(
        imported!"dmd.expression".Expression receiver,
        imported!"dmd.expression".CallExp call,
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
        assignStructField(fields, bytesField, Value((long[]).init));
        assignNestedStructFields(rangeOwner, fields);
        return true;
    }

    private VarDeclaration rangeStorageField(
        imported!"dmd.mtype".Type type,
    ) {
        if (auto bytesField = structFieldNamed(type, "_bytes"))
            return bytesField;
        if (auto dataField = structFieldNamed(type, "_data"))
            return dataField;
        return structFieldNamed(type, "sbuf");
    }

    private imported!"dmd.mtype".Type rangeElementType(
        VarDeclaration storageField,
    ) {
        if (storageField.type !is null && storageField.type.isTypeDArray !is null)
            return arrayElementType(storageField.type);
        return null;
    }

    private bool isModeledScopeBufferField(VarDeclaration field) {
        return field.ident !is null && field.ident.toString == "sbuf";
    }

    private bool isScopeBufferRangeType(imported!"dmd.mtype".Type type) {
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
        imported!"dmd.expression".Expression receiver,
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
        imported!"dmd.expression".CallExp call,
        CallArgument[] args,
        Value[] refValues,
        Value[imported!"dmd.declaration".VarDeclaration][] structRefValues,
        Value[imported!"dmd.declaration".VarDeclaration][imported!"dmd.declaration".VarDeclaration] structFieldMaps,
    ) {
        if (call.f.parameters is null)
            return;

        size_t scalarIndex;
        size_t structIndex;
        foreach (i, param; functionParameters(call.f)) {
            import dmd.astenums: STC;

            if ((param.storage_class & STC.ref_) == STC.none)
                continue;
            if (args[i].isStructRef) {
                if (args[i].refClassId != 0) {
                    interpreter.classStructFieldMaps[args[i].refClassId]
                        [args[i].refField] = structRefValues[structIndex];
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
            } else if (args[i].refSource !is null) {
                locals[args[i].refSource] = coerceValueToType(
                    refValues[scalarIndex],
                    args[i].refSource.type,
                );
                ++scalarIndex;
            } else if (args[i].refClassId != 0) {
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
        imported!"dmd.expression".EqualExp equal,
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
        imported!"dmd.expression".IdentityExp identity,
        ref Interpreter interpreter,
    ) {
        import dmd.tokens: EXP;

        const leftNull = identity.e1.isNullExp !is null;
        const rightNull = identity.e2.isNullExp !is null;
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
        imported!"dmd.expression".Expression expression,
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
        );
    }

    private bool isGcBlockBaseExpression(
        imported!"dmd.expression".Expression expression,
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
        imported!"dmd.expression".DeclarationExp decl,
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
                return Value(0L);
            }
            structFields[variable] = variable._init is null ||
                variable._init.isExpInitializer is null
                ? (Value[VarDeclaration]).init
                : runStructInitializer(variable._init.isExpInitializer.exp, interpreter);
            return Value(0L);
        }

        if (variable.type !is null && variable.type.isTypeDArray !is null)
            return initializeArrayVariable(variable, interpreter, unsupportedMessage);

        if (variable.type !is null &&
            variable.type.toBasetype.isTypeAArray !is null &&
            interpreter.lastAssocArrayRef != 0) {
            locals[variable] = Value(AssocArrayRef(interpreter.lastAssocArrayRef));
            return locals[variable];
        }

        if (variable._init is null || variable._init.isExpInitializer is null)
            return Value(0L);

        auto initializer = variable._init.isExpInitializer;
        // Determine the expression to evaluate for the initial value.
        imported!"dmd.expression".Expression initExpr = initializer.exp;
        if (auto blit = initializer.exp.isBlitExp)
            initExpr = blit.e2;
        else if (auto assign = initializer.exp.isAssignExp)
            initExpr = assign.e2;
        else if (auto construct = initializer.exp.isConstructExp)
            initExpr = construct.e2;
        Value value = coerceValueToType(runExpression(initExpr, interpreter), variable.type);
        locals[variable] = value;
        return value;
    }

    private Value initializeArrayVariable(
        VarDeclaration variable,
        ref Interpreter interpreter,
        in string unsupportedMessage,
    ) {
        if (variable._init is null) {
            locals[variable] = Value((long[]).init);
            return Value(0L);
        }

        auto initializer = variable._init.isExpInitializer;
        if (initializer is null)
            throw new Exception(unsupportedMessage);

        imported!"dmd.expression".Expression initExpr = initializer.exp;
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
                    assocArrayKeyArrays[variable] =
                        AssocArrayKeys(arrayId, keyStructs);
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
                    assocArrayKeyArrays[variable] =
                        AssocArrayKeys(arrayId, keyStructs);
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
                long[] elements;
                if (literal.elements !is null)
                    foreach (elem; arrayLiteralElements(literal))
                        elements ~= coerceIntegerToType(
                            runExpression(elem, interpreter).asLong,
                            arrayElementType(variable.type),
                        );
                locals[variable] = Value(elements);
                return Value(0L);
            }

            locals[variable] = coerceValueToType(
                runExpression(construct.e2, interpreter),
                variable.type,
            );
            return Value(0L);
        }

        locals[variable] = coerceValueToType(
            runExpression(initializer.exp, interpreter),
            variable.type,
        );
        return Value(0L);
    }

    private bool tryInitializeAssocArrayKeyStruct(
        VarDeclaration variable,
        imported!"dmd.expression".Expression expression,
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
                    if (auto keys = varDecl in assocArrayKeyArrays) {
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
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        return
            expression.op == EXP.lessThan ||
            expression.op == EXP.greaterThan ||
            expression.op == EXP.lessOrEqual ||
            expression.op == EXP.greaterOrEqual;
    }

    private Value runComparisonExpression(
        imported!"dmd.expression".Expression expression,
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
        imported!"dmd.expression".AssignExp assign,
        ref Interpreter interpreter,
    ) {
        if (auto var = assign.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in structFields) {
                    structFields[varDecl] = runStructInitializer(assign.e2, interpreter);
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

        if (auto index = assign.e1.isIndexExp) {
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const i = runExpression(index.e2, interpreter).asLong;
                        locals[varDecl].asArray[cast(size_t) i] =
                            coerceIntegerToType(
                                value.asLong,
                                arrayElementType(varDecl.type),
                            );
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

        if (auto slice = assign.e1.isSliceExp)
            if (auto var = slice.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        locals[varDecl] = Value(value.asArray.dup);
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

    private bool tryAssignNestedStructField(
        ref Value[VarDeclaration] fields,
        VarDeclaration field,
        imported!"dmd.expression".Expression valueExpression,
    ) {
        if (!isStructType(field.type))
            return false;

        if (auto owner = structCopySourceOwner(valueExpression)) {
            structFields[field] = structFields[owner].dup;
            assignStructField(fields, field, Value(0L));
            return true;
        }

        return false;
    }

    private VarDeclaration structCopySourceOwner(
        imported!"dmd.expression".Expression expression,
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
        imported!"dmd.expression".Expression expression,
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
        if (auto owner = structCopySourceOwner(expression))
            return structFields[owner].dup;
        if (auto call = expression.isCallExp) {
            Value[VarDeclaration] fields;
            if (tryRunStructDecerealise(call, fields, interpreter))
                return fields;
        }
        if (auto call = expression.isCallExp) {
            Value[VarDeclaration] fields;
            if (tryRunUnitThreadedStructConstructor(call, fields, interpreter))
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
        imported!"dmd.expression".CallExp call,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (call.arguments is null || call.arguments.length != 1)
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

        return false;
    }

    private bool tryRunStructDecerealise(
        imported!"dmd.expression".CallExp call,
        out Value[VarDeclaration] fields,
        ref Interpreter interpreter,
    ) {
        if (call.f.ident is null || call.f.ident.toString != "decerealise")
            return false;

        long[] bytes;
        if (!tryCerealBytes(call.e1, bytes, interpreter))
            if (call.arguments is null ||
                call.arguments.length != 1 ||
                !tryCerealBytes(callArguments(call)[0], bytes, interpreter))
                return false;

        fields = defaultStructFields(call.type);
        size_t index;
        foreach (field; aggregateStructFields(call.type)) {
            if (field.type !is null && field.type.isTypeDArray !is null) {
                if (bytes.length < index + 2)
                    return false;
                const length = cast(size_t) (
                    (bytes[index] << 8) | bytes[index + 1]
                );
                index += 2;
                if (bytes.length < index + length)
                    return false;
                assignStructField(
                    fields,
                    field,
                    Value(bytes[index .. index + length].dup),
                );
                index += length;
                continue;
            }
            if (bytes.length < index + 4)
                return false;
            assignStructField(
                fields,
                field,
                Value(
                    (bytes[index] << 24) |
                    (bytes[index + 1] << 16) |
                    (bytes[index + 2] << 8) |
                    bytes[index + 3],
                ),
            );
            index += 4;
        }
        return true;
    }

    private bool tryCerealBytes(
        imported!"dmd.expression".Expression expression,
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

        return false;
    }

    private Value[VarDeclaration] runStructLiteralExpression(
        imported!"dmd.expression".StructLiteralExp literal,
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
            fields[field] = coerceValueToType(
                runExpression(element, interpreter),
                field.type,
            );
        }
        return fields;
    }

    private Value[VarDeclaration] defaultClassFields(
        imported!"dmd.mtype".Type type,
    ) {
        Value[VarDeclaration] fields;
        foreach (field; classFields(type))
            if (field.type !is null && field.type.isTypeDArray !is null)
                fields[field] = Value((long[]).init);
            else if (isStructType(field.type)) {
                fields[field] = Value(0L);
                structFields[field] = (Value[VarDeclaration]).init;
            } else
                fields[field] = Value(0L);
        return fields;
    }

    private Value[VarDeclaration] defaultStructFields(
        imported!"dmd.mtype".Type type,
    ) {
        Value[VarDeclaration] fields;
        foreach (field; aggregateStructFields(type))
            if (field.type !is null && field.type.isTypeDArray !is null)
                fields[field] = Value((long[]).init);
            else if (isStructType(field.type)) {
                fields[field] = Value(0L);
                structFields[field] = defaultStructFields(field.type);
            } else
                fields[field] = Value(0L);
        return fields;
    }

    private VarDeclaration structFieldsOwner(
        imported!"dmd.expression".Expression expression,
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
            if (auto fieldDecl = dotVar.var.isVarDeclaration)
                if (fieldDecl in structFields)
                    return fieldDecl;
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

    private bool isStructType(imported!"dmd.mtype".Type type) {
        return type !is null && type.toBasetype.isTypeStruct !is null;
    }

    private bool isClassType(imported!"dmd.mtype".Type type) {
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
        );
        if (classRef == 0)
            return null;
        return classRef in interpreter.classFields;
    }

    private VarDeclaration structFieldNamed(
        imported!"dmd.mtype".Type type,
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
        imported!"dmd.expression".Expression expression,
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
    );
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
) @safe {
    foreach (candidateHeaderByteCount; [2, 4, 8]) {
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
    import dmd.astenums: TY;

    if (expression.type is null)
        return false;

    const type = expression.type.toBasetype;
    return type.ty == TY.Tuns8 ||
        type.ty == TY.Tuns16 ||
        type.ty == TY.Tuns32 ||
        type.ty == TY.Tuns64;
}

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import std.string: fromStringz;
    return fromStringz(expression.toChars).idup;
}

private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;
    return fromStringz(type.toChars).idup;
}

private ref auto callArguments(
    imported!"dmd.expression".CallExp call,
) @trusted pure {
    return *call.arguments;
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

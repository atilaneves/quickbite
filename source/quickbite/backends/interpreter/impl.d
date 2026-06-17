module quickbite.backends.interpreter.impl;


private:


public class Interpreter: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayEvalResult;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    public alias eval = Evaluator.eval;

    public override EvalResult eval(FuncDeclaration function_) {
        return displayEvalResult(() {
            Walker walker;
            walker.inUnitTest = function_.isUnitTestDeclaration !is null;
            walker.runStatement(function_.fbody);
            return walker.result;
        }, function_);
    }
}

private bool isTransparentArrayCastTarget(imported!"dmd.mtype".Type type) {
    import quickbite.frontend.dmd.types: isArrayType;

    return isArrayType(type);
}

private enum LoopControl {
    none,
    break_,
    continue_,
}

private struct ArrayElementAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t index;
}

private class InterpretedException: Exception {
    public imported!"quickbite.lang".Value object;

    public this(in imported!"quickbite.lang".Value object) {
        const message = object.classFieldNamed("msg").asCharArrayString;
        super(message);
        this.object = object;
    }
}

private string statementLabel(imported!"dmd.identifier".Identifier identifier) {
    return identifier is null ? null : identifier.toString.idup;
}

private struct Walker {
    import dmd.declaration: VarDeclaration;
    import dmd.expression: DivExp, ModExp;
    import dmd.func: FuncDeclaration;
    import dmd.statement: Statement;
    import quickbite.frontend.dmd.values: defaultValue;
    import quickbite.lang: Value;

    private Value[VarDeclaration] locals;
    private VarDeclaration[size_t] localPointers;
    private size_t[VarDeclaration] localPointerIds;
    private size_t nextLocalPointerId;
    private FuncDeclaration[size_t] functionPointers;
    private size_t[FuncDeclaration] functionPointerIds;
    private size_t nextFunctionPointerId;
    private RuntimeDelegate[size_t] delegates;
    private bool[VarDeclaration] uninitializedLocals;
    private SliceAlias[VarDeclaration] sliceAliases;
    private ArrayElementAlias[VarDeclaration] arrayElementAliases;
    private AssocArraySlotAlias[VarDeclaration] assocArraySlotAliases;
    private StructArrayFieldAliases[VarDeclaration] structArrayFieldAliases;
    private size_t[VarDeclaration] arrayAllocations;
    private VarDeclaration[size_t] arrayAllocationVariables;
    private VarDeclaration[VarDeclaration] staticArrayCopySources;
    private VarDeclaration lastStaticArrayCopySource;
    private Value[] lastStaticArrayCopySourceValues;
    private FuncDeclaration lastStaticArrayCopyDestructor;
    private size_t allocationCount;
    private Value result;
    private bool runningCalledFunction;
    private bool inUnitTest;
    private FuncDeclaration currentFunction;
    private Value thisValue;
    private bool hasThis;
    private Value pendingFinallyBodyException;
    private bool hasPendingFinallyBodyException;
    private StructArrayFieldAliases thisStructArrayFieldAliases;
    private bool returned;
    private Statement pendingGotoTarget;
    private Statement pendingSwitchTarget;
    private LoopControl loopControl;
    private string loopControlLabel;

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null)
            return;

        if (returned || loopControl != LoopControl.none)
            return;

        if (statement is pendingSwitchTarget)
            pendingSwitchTarget = null;

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    if (skipUntilSwitchTarget(child))
                        continue;
                    if (skipUntilGotoTarget(child))
                        continue;
                    runStatement(child);
                    if (returned || loopControl != LoopControl.none)
                        break;
                }
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    if (skipUntilSwitchTarget(child))
                        continue;
                    if (skipUntilGotoTarget(child))
                        continue;
                    runStatement(child);
                    if (returned || loopControl != LoopControl.none)
                        break;
                }
            return;
        }

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto tryFinally = statement.isTryFinallyStatement) {
            Exception bodyException;
            try {
                runStatement(tryFinally._body);
            } catch (Throwable exception) {
                bodyException = cast(Exception) exception;
                if (bodyException is null)
                    throw exception;
            }

            const savedReturned = returned;
            const savedResult = result;
            const savedLoopControl = loopControl;
            const savedLoopControlLabel = loopControlLabel;
            returned = false;
            loopControl = LoopControl.none;
            loopControlLabel = null;
            const savedPendingFinallyBodyException = pendingFinallyBodyException;
            const savedHasPendingFinallyBodyException =
                hasPendingFinallyBodyException;
            if (auto bodyInterpreted = cast(InterpretedException) bodyException) {
                pendingFinallyBodyException = bodyInterpreted.object;
                hasPendingFinallyBodyException = true;
            }
            scope(exit) {
                pendingFinallyBodyException = savedPendingFinallyBodyException;
                hasPendingFinallyBodyException =
                    savedHasPendingFinallyBodyException;
            }
            try {
                runStatement(tryFinally.finalbody);
            } catch (Exception exception) {
                auto finalException = cast(InterpretedException) exception;
                if (finalException is null)
                    throw exception;
                if (auto bodyInterpreted = cast(InterpretedException) bodyException) {
                    bodyInterpreted.object = chainExceptionObject(
                        bodyInterpreted.object,
                        finalException.object,
                    );
                    throw bodyInterpreted;
                }
                throw finalException;
            }
            if (!returned && loopControl == LoopControl.none) {
                returned = savedReturned;
                if (returned)
                    result = savedResult;
                loopControl = savedLoopControl;
                loopControlLabel = savedLoopControlLabel;
                if (bodyException !is null)
                    throw bodyException;
            }
            return;
        }

        if (auto tryCatch = statement.isTryCatchStatement) {
            runTryCatchStatement(tryCatch);
            return;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            if (unrolled.statements !is null)
                foreach (child; *unrolled.statements) {
                    if (skipUntilSwitchTarget(child))
                        continue;
                    if (skipUntilGotoTarget(child))
                        continue;
                    runStatement(child);
                    if (returned || loopControl != LoopControl.none)
                        break;
                }
            return;
        }

        if (auto goto_ = statement.isGotoStatement) {
            if (goto_.label is null || goto_.label.statement is null)
                throw new Exception("Unsupported eval statement: Goto");

            auto label = goto_.label.statement;
            pendingGotoTarget = label.gotoTarget is null
                ? label.statement
                : label.gotoTarget;
            return;
        }

        if (auto label = statement.isLabelStatement) {
            runLabeledStatement(label);
            return;
        }

        if (statement.isImportStatement !is null)
            return;

        if (auto expression = statement.isExpStatement) {
            if (expression.exp is null)
                return;
            result = runExpression(expression.exp);
            return;
        }

        if (auto dtor = statement.isDtorExpStatement) {
            result = runExpression(dtor.exp);
            runStaticArrayCopySourceDestructor(dtor.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            if (return_.exp !is null)
                result = runExpression(return_.exp);
            returned = true;
            return;
        }

        if (auto for_ = statement.isForStatement) {
            runForStatement(for_);
            return;
        }

        if (auto do_ = statement.isDoStatement) {
            runDoStatement(do_);
            return;
        }

        if (auto switch_ = statement.isSwitchStatement) {
            runSwitchStatement(switch_);
            return;
        }

        if (auto case_ = statement.isCaseStatement) {
            if (case_.statement is statement)
                throw new Exception("Unsupported eval statement: Case");
            runStatement(case_.statement);
            return;
        }

        if (auto default_ = statement.isDefaultStatement) {
            if (default_.statement is statement)
                throw new Exception("Unsupported eval statement: Default");
            runStatement(default_.statement);
            return;
        }

        if (auto caseRange = statement.isCaseRangeStatement) {
            if (caseRange.statement is statement)
                throw new Exception("Unsupported eval statement: CaseRange");
            runStatement(caseRange.statement);
            return;
        }

        if (auto gotoCase = statement.isGotoCaseStatement) {
            if (gotoCase.cs is null)
                throw new Exception("Unsupported eval statement: GotoCase");
            pendingSwitchTarget = gotoCase.cs;
            return;
        }

        if (auto gotoDefault = statement.isGotoDefaultStatement) {
            if (gotoDefault.sw is null || gotoDefault.sw.sdefault is null)
                throw new Exception("Unsupported eval statement: GotoDefault");
            pendingSwitchTarget = gotoDefault.sw.sdefault;
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            import quickbite.backends.interpreter.messages: isTruthy;

            if (isTruthy(runExpression(if_.condition)))
                runStatement(if_.ifbody);
            else
                runStatement(if_.elsebody);
            return;
        }

        if (auto break_ = statement.isBreakStatement) {
            loopControl = LoopControl.break_;
            loopControlLabel = statementLabel(break_.ident);
            return;
        }

        if (auto continue_ = statement.isContinueStatement) {
            loopControl = LoopControl.continue_;
            loopControlLabel = statementLabel(continue_.ident);
            return;
        }

        if (auto with_ = statement.isWithStatement) {
            runWithStatement(with_);
            return;
        }

        if (auto throw_ = statement.isThrowStatement) {
            throwInterpretedException(throw_.exp);
        }

        import std.conv: text;
        throw new Exception(text("Unsupported eval statement: ", statement.stmt));
    }

    pragma(inline, false)
    private void runTryCatchStatement(
        imported!"dmd.statement".TryCatchStatement tryCatch,
    ) {
        try {
            runStatement(tryCatch._body);
        } catch (Exception exception) {
            auto interpreted = cast(InterpretedException) exception;
            if (interpreted is null)
                throw exception;

            auto catch_ = matchingCatch(tryCatch, interpreted.object);
            if (catch_ is null)
                throw exception;

            bindCatchVariable(catch_, interpreted.object);
            runStatement(catch_.handler);
        }
    }

    private imported!"dmd.statement".Catch matchingCatch(
        imported!"dmd.statement".TryCatchStatement tryCatch,
        in Value object,
    ) {
        if (tryCatch.catches is null || tryCatch.catches.length == 0)
            return null;

        foreach (catch_; *tryCatch.catches)
            if (catchMatches(catch_, object))
                return catch_;

        return null;
    }

    private bool catchMatches(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (catch_.type is null)
            return true;

        auto classType = catch_.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return false;

        return object.classHasType(className(classType.sym));
    }

    private void bindCatchVariable(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (catch_.var is null)
            return;

        locals[catch_.var] = object;
        uninitializedLocals.remove(catch_.var);
    }

    private void throwInterpretedException(
        imported!"dmd.expression".Expression expression,
    ) {
        auto object = runExpression(expression);
        if (!object.isClassObject)
            throw new Exception("Unsupported throw expression.");
        if (hasPendingFinallyBodyException)
            throw new InterpretedException(chainExceptionObject(
                pendingFinallyBodyException,
                object,
            ));

        throw new InterpretedException(object);
    }

    private Value chainExceptionObject(in Value thrown, in Value next) const {
        if (!thrown.isClassObject || !thrown.hasClassFieldNamed("_nextInChainPtr"))
            return thrown;

        return thrown.withClassFieldNamed("_nextInChainPtr", next);
    }

    private bool isThrowableConstructor(
        imported!"dmd.func".FuncDeclaration function_,
    ) const {
        auto class_ = function_.parent is null
            ? null
            : function_.parent.isClassDeclaration;
        if (class_ is null)
            return false;

        const name = className(class_);
        if (name == "Throwable" || name == "Exception" || name == "Error")
            return true;

        return false;
    }

    private Value applyThrowableConstructor(
        in Value object,
        in Value[] arguments,
    ) const {
        if (!object.isClassObject || arguments.length == 0)
            return object;

        auto result = object.withClassFieldNamed("msg", arguments[0]);
        if (
            arguments.length >= 4 &&
            arguments[3].isClassObject &&
            result.hasClassFieldNamed("_nextInChainPtr")
        )
            result = result.withClassFieldNamed("_nextInChainPtr", arguments[3]);

        return result;
    }

    private Value runThisConstructorCall(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
    ) {
        if (!hasThis || !thisValue.isClassObject || !isThrowableConstructor(function_))
            throw new Exception("Unsupported eval call.");

        thisValue = applyThrowableConstructor(thisValue, arguments);
        return thisValue;
    }

    private bool isThisOrSuperExpression(
        imported!"dmd.expression".Expression expression,
    ) const {
        return
            expression.isThisExp !is null ||
            expression.isSuperExp !is null;
    }

    private bool isThisOrSuperMemberCall(
        imported!"dmd.expression".CallExp call,
    ) const {
        auto dot = call.e1.isDotVarExp;
        if (dot is null)
            return false;

        return isThisOrSuperExpression(dot.e1);
    }

    private bool skipUntilSwitchTarget(Statement statement) {
        if (pendingSwitchTarget is null)
            return false;

        if (statement is pendingSwitchTarget) {
            pendingSwitchTarget = null;
            return false;
        }

        if (statementContainsSwitchTarget(statement))
            return false;

        return true;
    }

    private bool statementContainsSwitchTarget(Statement statement) {
        if (pendingSwitchTarget is null || statement is null)
            return false;

        if (statement is pendingSwitchTarget)
            return true;

        if (auto scope_ = statement.isScopeStatement)
            return statementContainsSwitchTarget(scope_.statement);

        if (auto label = statement.isLabelStatement)
            return statementContainsSwitchTarget(label.statement);

        if (auto case_ = statement.isCaseStatement)
            return statementContainsSwitchTarget(case_.statement);

        if (auto default_ = statement.isDefaultStatement)
            return statementContainsSwitchTarget(default_.statement);

        if (auto caseRange = statement.isCaseRangeStatement)
            return statementContainsSwitchTarget(caseRange.statement);

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    if (statementContainsSwitchTarget(child))
                        return true;
            return false;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    if (statementContainsSwitchTarget(child))
                        return true;
            return false;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            if (unrolled.statements !is null)
                foreach (child; *unrolled.statements)
                    if (statementContainsSwitchTarget(child))
                        return true;
            return false;
        }

        return false;
    }

    private bool skipUntilGotoTarget(Statement statement) {
        if (pendingGotoTarget is null)
            return false;

        if (statement is pendingGotoTarget) {
            pendingGotoTarget = null;
            return false;
        }

        if (auto label = statement.isLabelStatement) {
            if (
                label.statement is pendingGotoTarget ||
                label.gotoTarget is pendingGotoTarget
            ) {
                pendingGotoTarget = null;
                return false;
            }
        }

        return true;
    }

    private void runLabeledStatement(imported!"dmd.statement".LabelStatement label) {
        const name = statementLabel(label.ident);

        if (auto for_ = label.statement.isForStatement)
            runForStatement(for_, name);
        else if (auto do_ = label.statement.isDoStatement)
            runDoStatement(do_, name);
        else
            runStatement(label.statement);

        if (
            loopControl == LoopControl.break_ &&
            loopControlLabel !is null &&
            loopControlLabel == name
        )
            clearLoopControl;
    }

    // For `with(expr)` where expr is a struct lvalue, DMD semantic creates a
    // `wthis` pointer-to-struct temporary and rewrites field accesses in the
    // body to go through `*wthis`.  We seed locals with a pointer value wrapping
    // the struct, run the body (mutations flow through writeLocation's PtrExp
    // arm back into locals[wthis]), then write the final value back to the
    // original expression.  For `with(EnumType)`, wthis is null; DMD resolves
    // enum member references in the body at semantic time, so running the body
    // as-is suffices.
    private void runWithStatement(
        imported!"dmd.statement".WithStatement with_,
    ) {
        if (with_.wthis !is null) {
            const structValue = runExpression(with_.exp);
            locals[with_.wthis] = Value.pointerValue(structValue);
            runStatement(with_._body);
            if (auto updated = with_.wthis in locals)
                writeLocation(
                    with_.exp,
                    updated.isLocalPointer
                        ? localPointerTarget(*updated)
                        : updated.pointerTarget,
                );
        } else {
            runStatement(with_._body);
        }
    }

    private void runSwitchStatement(
        imported!"dmd.statement".SwitchStatement switch_,
    ) {
        auto target = switchTarget(switch_);
        if (target is null)
            return;

        auto savedPendingSwitchTarget = pendingSwitchTarget;
        pendingSwitchTarget = target;

        while (
            !returned &&
            loopControl == LoopControl.none &&
            pendingSwitchTarget !is null
        ) {
            auto targetBeforeRun = pendingSwitchTarget;
            runStatement(switch_._body);
            if (pendingSwitchTarget is targetBeforeRun)
                throw new Exception("Unsupported eval statement: Switch");
        }

        if (loopControl == LoopControl.break_ && loopControlLabel is null)
            clearLoopControl;

        pendingSwitchTarget = savedPendingSwitchTarget;
    }

    private Statement switchTarget(
        imported!"dmd.statement".SwitchStatement switch_,
    ) {
        if (switch_.cases !is null) {
            const condition = runExpression(switch_.condition);
            foreach (case_; *switch_.cases) {
                if (case_ is null)
                    continue;
                if (caseMatches(case_, condition))
                    return case_;
            }
        }

        return switch_.sdefault;
    }

    private bool caseMatches(
        imported!"dmd.statement".CaseStatement case_,
        in Value condition,
    ) {
        if (case_.exp !is null && runExpression(case_.exp) == condition)
            return true;

        auto range = case_.statement is null
            ? null
            : case_.statement.isCaseRangeStatement;
        if (range is null)
            return false;

        const value = condition.asLong;
        return
            value >= runExpression(range.first).asLong &&
            value <= runExpression(range.last).asLong;
    }

    private void runForStatement(
        imported!"dmd.statement".ForStatement for_,
        in string label = null,
    ) {
        import quickbite.backends.interpreter.messages: isTruthy;

        runStatement(for_._init);

        while (
            !returned &&
            loopControl == LoopControl.none &&
            (for_.condition is null || isTruthy(runExpression(for_.condition)))
        ) {
            runStatement(for_._body);
            if (returned)
                break;
            if (loopControl == LoopControl.break_) {
                if (loopControlLabel is null || loopControlLabel == label)
                    clearLoopControl;
                break;
            }
            if (loopControl == LoopControl.continue_) {
                if (loopControlLabel !is null && loopControlLabel != label)
                    break;
                clearLoopControl;
            }
            if (for_.increment !is null)
                runExpression(for_.increment);
        }
    }

    private void runDoStatement(
        imported!"dmd.statement".DoStatement do_,
        in string label = null,
    ) {
        import quickbite.backends.interpreter.messages: isTruthy;

        do {
            runStatement(do_._body);
            if (returned)
                break;
            if (loopControl == LoopControl.break_) {
                if (loopControlLabel is null || loopControlLabel == label)
                    clearLoopControl;
                break;
            }
            if (loopControl == LoopControl.continue_) {
                if (loopControlLabel !is null && loopControlLabel != label)
                    break;
                clearLoopControl;
            }
        } while (isTruthy(runExpression(do_.condition)));
    }

    private void clearLoopControl() {
        loopControl = LoopControl.none;
        loopControlLabel = null;
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.values: integerValue, realValue;

        if (auto integer = expression.isIntegerExp) {
            if (integer.type !is null && integer.type.ty == TY.Tenum)
                return Value.enumValue(
                    expressionChars(integer),
                    cast(long) integer.getInteger,
                );
            return integerValue(integer);
        }

        if (auto real_ = expression.isRealExp)
            return realValue(real_);

        if (expression.isNullExp !is null)
            return Value.null_;

        if (auto string_ = expression.isStringExp) {
            import quickbite.frontend.dmd.string_literals: stringValue;

            return stringValue(string_);
        }

        if (auto array = expression.isArrayLiteralExp)
            return arrayValue(array);

        if (auto assocArray = expression.isAssocArrayLiteralExp)
            return assocArrayValue(assocArray);

        if (auto struct_ = expression.isStructLiteralExp)
            return structLiteralValue(struct_);

        if (auto assert_ = expression.isAssertExp) {
            import quickbite.backends.interpreter.messages:
                assertFailureMessage,
                isTruthy;

            if (!isTruthy(runExpression(assert_.e1)))
                throw new Exception(
                    assertFailureMessage(assert_, runningCalledFunction, inUnitTest, &runExpression),
                );
            return Value(true);
        }

        if (auto not = expression.isNotExp) {
            import quickbite.backends.interpreter.messages: isTruthy;

            return Value(!isTruthy(runExpression(not.e1)));
        }

        if (auto logical = expression.isLogicalExp) {
            if (logical.op == EXP.andAnd)
                return runLogicalAndExpression(logical);
            if (logical.op == EXP.orOr)
                return runLogicalOrExpression(logical);
        }

        if (auto cast_ = expression.isCastExp) {
            log("cast expression: ", cast_);
            return castValue(cast_);
        }

        if (auto equal = expression.isEqualExp)
            return runEqualExpression(equal);

        if (auto identity = expression.isIdentityExp)
            return runIdentityExpression(identity);

        if (
            expression.op == EXP.lessThan ||
            expression.op == EXP.lessOrEqual ||
            expression.op == EXP.greaterThan ||
            expression.op == EXP.greaterOrEqual
        ) {
            auto comparison = cast(imported!"dmd.expression".CmpExp) expression;
            if (comparison is null)
                assert(0);

            return runComparisonExpression(comparison);
        }

        if (auto conditional = expression.isCondExp)
            return runConditionalExpression(conditional);

        if (auto throw_ = expression.isThrowExp) {
            throwInterpretedException(throw_.e1);
            return Value.void_;
        }

        if (auto post = expression.isPostExp)
            return runPostIncrementExpression(post);

        if (auto addAssign = expression.isAddAssignExp)
            return runAddAssignExpression(addAssign);

        if (auto add = expression.isAddExp)
            return runAddExpression(add);

        if (auto sub = expression.isMinExp)
            return runMinExpression(sub);

        if (auto mul = expression.isMulExp)
            return runExpression(mul.e1) * runExpression(mul.e2);

        if (auto div = expression.isDivExp)
            return runDivExpression(div);

        if (auto mod = expression.isModExp)
            return runModExpression(mod);

        if (auto leftShift = expression.isShlExp)
            return runIntegerBinaryExpression(leftShift, "<<");

        if (auto rightShift = expression.isShrExp)
            return runIntegerBinaryExpression(rightShift, ">>");

        if (auto unsignedRightShift = expression.isUshrExp)
            return runIntegerBinaryExpression(unsignedRightShift, ">>>");

        if (auto neg = expression.isNegExp)
            return -runExpression(neg.e1);

        if (auto complement = expression.isComExp)
            return runIntegerComplementExpression(complement);

        if (auto pow = expression.isPowExp)
            return runPowExpression(pow);

        if (auto cat = expression.isCatExp)
            return runConcatenateExpression(cat);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

        if (auto lowered = expression.isLoweredAssignExp)
            return runLoweredAssignExpression(lowered);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct);

        if (auto blit = expression.isBlitExp)
            return runAssignExpression(blit);

        if (expression.op == EXP.concatenateElemAssign) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0);

            return runArrayAppendAssignExpression(assign);
        }

        if (isScalarCompoundAssignExpression(expression)) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0);

            return runCompoundAssignExpression(assign);
        }

        if (auto bitOr = expression.isOrExp)
            return runIntegerBinaryExpression(bitOr, "|");

        if (auto bitAnd = expression.isAndExp)
            return runIntegerBinaryExpression(bitAnd, "&");

        if (auto bitXor = expression.isXorExp)
            return runIntegerBinaryExpression(bitXor, "^");

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1);
            return runExpression(comma.e2);
        }

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

        if (auto delegate_ = expression.isDelegateExp)
            return runDelegateExpression(delegate_);

        if (expression.isFuncExp)
            return Value.undisplayable;

        if (auto arrayLength = expression.isArrayLengthExp)
            return Value(runExpression(arrayLength.e1).length);

        if (auto slice = expression.isSliceExp)
            return runSliceExpression(slice);

        if (auto index = expression.isIndexExp)
            return runIndexExpression(index);

        if (auto new_ = expression.isNewExp)
            return runNewExpression(new_);

        if (auto symbol = expression.isSymOffExp) {
            if (auto variable = symbol.var.isVarDeclaration)
                return localPointerValue(variable);
            if (auto function_ = symbol.var.isFuncDeclaration)
                return functionPointerValue(function_);
        }

        if (auto pointer = expression.isPtrExp)
            return runPointerExpression(pointer);

        if (auto address = expression.isAddrExp)
            return runAddressExpression(address);

        if (auto delegatePointer = expression.isDelegatePtrExp)
            return runDelegatePointerExpression(delegatePointer);

        if (auto delegateFunctionPointer = expression.isDelegateFuncptrExp)
            return runDelegateFunctionPointerExpression(delegateFunctionPointer);

        if (auto dotIdentifier = expression.isDotIdExp)
            return runDotIdentifierExpression(dotIdentifier);

        if (auto dot = expression.isDotVarExp)
            return runDotVarExpression(dot);

        if (auto vector = expression.isVectorExp)
            return runVectorExpression(vector);

        if (auto vectorArray = expression.isVectorArrayExp)
            return runExpression(vectorArray.e1);

        if (expression.isThisExp !is null) {
            if (!hasThis)
                throw new Exception("Unsupported eval expression: this");
            return thisValue;
        }

        if (expression.isSuperExp !is null) {
            if (!hasThis)
                throw new Exception("Unsupported eval expression: super");
            return thisValue;
        }

        if (auto typeid_ = expression.isTypeidExp)
            return runTypeidExpression(typeid_);

        if (auto identifier = expression.isIdentifierExp) {
            const name = identifier.ident is null
                ? ""
                : identifier.ident.toString.idup;

            // DMD-generated exception support can leave the magic __ctfe flag
            // as an identifier instead of lowering it to a VarExp.
            if (name == "__ctfe")
                return Value(true);

            if (
                hasThis &&
                thisValue.isClassObject &&
                thisValue.hasClassFieldNamed(name)
            )
                return thisValue.classFieldNamed(name);
        }

        if (auto var = expression.isVarExp) {
            import dmd.id: Id;

            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                assert(0);

            // the magic __ctfe variable is true under AST interpretation,
            // matching dmd's own interpreter; the language requires both
            // __ctfe branches to be observably equivalent
            if (variable.ident is Id.ctfe)
                return Value(true);

            if (variable in uninitializedLocals) {
                import quickbite.backends.interpreter.messages: uninitializedVariableMessage;
                import quickbite.frontend.dmd.types: isStaticArrayType, isStructType;

                // DMD's void diagnostic is field-granular: reading a whole
                // void-initialized aggregate (as `S res = void; return res;`
                // does) materialises a default value; only a still-void scalar
                // read is reported. Match that so patterns like Phobos
                // `trustedVoidInit` evaluate up to any real libc call.
                if (isStructType(variable.type) || isStaticArrayType(variable.type))
                    return defaultValue(variable);

                throw new Exception(uninitializedVariableMessage(variable, currentFunction));
            }

            if (auto current = variable in locals)
                return *current;

            return defaultValue(variable);
        }

        import std.conv: text;
        throw new Exception(text("Unsupported eval expression: ", expression.op));
    }

    private Value runLogicalAndExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        import quickbite.backends.interpreter.messages: isTruthy;

        const left = isTruthy(runExpression(logical.e1));
        if (!left)
            return Value(false);

        const right = isTruthy(runExpression(logical.e2));
        return Value(right);
    }

    private Value runLogicalOrExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        import quickbite.backends.interpreter.messages: isTruthy;

        const left = isTruthy(runExpression(logical.e1));
        if (left)
            return Value(true);

        const right = isTruthy(runExpression(logical.e2));
        return Value(right);
    }

    private Value runComparisonExpression(
        imported!"dmd.expression".CmpExp comparison,
    ) {
        import dmd.tokens: EXP;

        const leftValue = runExpression(comparison.e1);
        const rightValue = runExpression(comparison.e2);

        if (leftValue.isPointer && rightValue.isPointer)
            return runPointerComparison(comparison.op, leftValue, rightValue);

        const left = leftValue.asReal;
        const right = rightValue.asReal;

        if (comparison.op == EXP.lessThan)
            return Value(left < right);
        if (comparison.op == EXP.lessOrEqual)
            return Value(left <= right);
        if (comparison.op == EXP.greaterThan)
            return Value(left > right);
        return Value(left >= right);
    }

    // ordered comparisons between pointers into unrelated allocations are
    // false both ways, matching CTFE
    private Value runPointerComparison(
        in imported!"dmd.tokens".EXP op,
        in Value left,
        in Value right,
    ) {
        import dmd.tokens: EXP;

        if (!left.pointerSameAllocation(right))
            return Value(false);

        const difference = left.pointerOffsetDifference(right);

        if (op == EXP.lessThan)
            return Value(difference < 0);
        if (op == EXP.lessOrEqual)
            return Value(difference <= 0);
        if (op == EXP.greaterThan)
            return Value(difference > 0);
        return Value(difference >= 0);
    }

    private Value runAddExpression(imported!"dmd.expression".AddExp add) {
        const left = runExpression(add.e1);
        const right = runExpression(add.e2);

        if (left.isPointer)
            return left.pointerOffsetBy(
                pointerElementOffset(add.type, right.asLong),
            );

        if (right.isPointer)
            return right.pointerOffsetBy(
                pointerElementOffset(add.type, left.asLong),
            );

        return left + right;
    }

    private Value runMinExpression(imported!"dmd.expression".MinExp sub) {
        const left = runExpression(sub.e1);
        const right = runExpression(sub.e2);

        // DMD lowers `p - q` to `(p - q) / elementSize`; return the byte
        // difference so the lowered division yields the element difference
        if (left.isPointer && right.isPointer)
            return Value(
                left.pointerOffsetDifference(right) *
                pointerElementSize(sub.e1.type),
            );

        if (left.isPointer)
            return left.pointerOffsetBy(
                -pointerElementOffset(sub.type, right.asLong),
            );

        return left - right;
    }

    private Value runDivExpression(DivExp div) {
        const left = runExpression(div.e1);
        const right = runExpression(div.e2);
        rejectIntMinMinusOneOverflow(left, right, "/");
        return left / right;
    }

    private Value runModExpression(ModExp mod) {
        const left = runExpression(mod.e1);
        const right = runExpression(mod.e2);
        rejectIntMinMinusOneOverflow(left, right, "%");
        return left % right;
    }

    private void rejectIntMinMinusOneOverflow(
        in Value left,
        in Value right,
        in string operator,
    ) const {
        import std.conv: text;

        if (left != Value(int.min) || right != Value(-1))
            return;

        throw new Exception(text(
            "integer overflow: `int.min ",
            operator,
            " -1`\ncannot compare `__error` at compile time",
        ));
    }

    // DMD semantic scales pointer arithmetic operands to byte offsets
    private long pointerElementOffset(
        imported!"dmd.mtype".Type pointerType,
        in long byteOffset,
    ) {
        const elementSize = pointerElementSize(pointerType);
        if (byteOffset % elementSize != 0)
            throw new Exception("Unsupported pointer arithmetic offset.");

        return byteOffset / elementSize;
    }

    private long pointerElementSize(imported!"dmd.mtype".Type pointerType) {
        import dmd.typesem: size;

        auto element = pointerType is null
            ? null
            : pointerType.toBasetype.nextOf;
        const elementSize = element is null ? 0 : cast(long) element.size;
        if (elementSize <= 0)
            throw new Exception("Unsupported pointer element type.");

        return elementSize;
    }

    private Value runAddressExpression(
        imported!"dmd.expression".AddrExp address,
    ) {
        import std.conv: text;

        if (auto symbol = address.e1.isSymOffExp) {
            if (auto variable = symbol.var.isVarDeclaration)
                return localPointerValue(variable);
            if (auto function_ = symbol.var.isFuncDeclaration)
                return functionPointerValue(function_);
        }

        // `&val` of a `ref` parameter is emitted as AddrExp(VarExp), not the
        // SymOffExp produced for a plain local; point at the parameter's slot
        if (auto var = address.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                return localPointerValue(variable);

        if (auto delegate_ = address.e1.isDelegateExp)
            return runDelegateExpression(delegate_);

        auto index = address.e1.isIndexExp;
        if (index is null)
            throw new Exception(
                text("Unsupported eval expression: ", address.op),
            );

        const offset = runExpression(index.e2).asLong;
        return arrayPointer(index.e1, offset, address.op);
    }

    private Value arrayPointer(
        imported!"dmd.expression".Expression array,
        in long offset,
        in imported!"dmd.tokens".EXP op,
    ) {
        import std.conv: text;

        auto var = array.isVarExp;
        if (var is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        auto current = variable in locals;
        if (current is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        return Value.arrayPointerValue(
            arrayElements(*current),
            allocationId(variable),
            offset,
        );
    }

    private Value localPointerValue(VarDeclaration variable) {
        if (auto id = variable in localPointerIds)
            return Value.localPointerValue(*id);

        const id = ++nextLocalPointerId;
        localPointerIds[variable] = id;
        localPointers[id] = variable;
        return Value.localPointerValue(id);
    }

    private Value functionPointerValue(FuncDeclaration function_) {
        if (auto id = function_ in functionPointerIds)
            return Value.functionPointerValue(*id);

        const id = ++nextFunctionPointerId;
        functionPointerIds[function_] = id;
        functionPointers[id] = function_;
        return Value.functionPointerValue(id);
    }

    private Value newFunctionPointerValue(FuncDeclaration function_) {
        const id = ++nextFunctionPointerId;
        functionPointers[id] = function_;
        return Value.functionPointerValue(id);
    }

    private Value runDelegateExpression(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        if (delegate_.func is null)
            throw new Exception("Unsupported eval expression: delegate_");

        const functionPointer = newFunctionPointerValue(delegate_.func);
        const contextPointer = delegateContextPointer(delegate_);

        RuntimeDelegate runtime;
        runtime.function_ = delegate_.func;
        runtime.functionPointerId = functionPointer.functionPointerId;
        runtime.contextPointer = contextPointer;
        if (isMemberFunction(delegate_.func)) {
            if (delegate_.e1 is null)
                throw new Exception("Unsupported eval expression: delegate_");

            runtime.receiver = runExpression(delegate_.e1);
            runtime.hasReceiver = true;
        }

        delegates[functionPointer.functionPointerId] = runtime;
        return functionPointer;
    }

    private Value delegateContextPointer(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        if (delegate_.e1 !is null) {
            if (auto var = delegate_.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    return localPointerValue(variable);
        }

        return Value.pointerValue(Value.void_);
    }

    private Value runPointerExpression(
        imported!"dmd.expression".PtrExp pointer,
    ) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        const value = runExpression(pointer.e1);
        if (value.isFunctionPointer)
            return value;

        if (isStaticArrayType(pointer.type))
            return staticArrayPointerView(value, pointer.type);

        if (!value.isLocalPointer)
            return value.pointerTarget;

        auto variable = value.localPointerId in localPointers;
        if (variable is null)
            throw new Exception("Unsupported interpreter pointer target.");

        if (auto current = (*variable) in locals)
            return *current;

        return defaultValue(*variable);
    }

    private Value staticArrayPointerView(
        in Value pointer,
        imported!"dmd.mtype".Type staticArrayType,
    ) {
        auto staticArray = staticArrayType.toBasetype.isTypeSArray;
        const length = cast(size_t) staticArray.dim.toInteger;
        const target = pointerTargetValue(pointer);
        if (target.isArray)
            return target;

        Value[] elements;
        foreach (index; 0 .. length)
            elements ~= pointer.pointerIndex(index);

        return Value.arrayValue(elements);
    }

    private Value[] arrayElements(in Value value) {
        Value[] elements;
        foreach (index; 0 .. value.length)
            elements ~= value[index];

        return elements;
    }

    // pointers into the same array local share an opaque allocation id so
    // that identity and ordering survive the copy-on-write value model
    private size_t allocationId(VarDeclaration variable) {
        if (auto id = variable in arrayAllocations)
            return *id;

        arrayAllocations[variable] = ++allocationCount;
        arrayAllocationVariables[arrayAllocations[variable]] = variable;
        return arrayAllocations[variable];
    }

    private Value runConditionalExpression(
        imported!"dmd.expression".CondExp conditional,
    ) {
        import quickbite.backends.interpreter.messages: isTruthy;

        return isTruthy(runExpression(conditional.econd)) ?
            runExpression(conditional.e1) :
            runExpression(conditional.e2);
    }

    private Value runIdentityExpression(
        imported!"dmd.expression".IdentityExp identity,
    ) {
        import dmd.tokens: EXP;

        const left = runExpression(identity.e1);
        const right = runExpression(identity.e2);
        const same = left == right;
        if (identity.op == EXP.notIdentity)
            return Value(!same);

        return Value(same);
    }

    private Value runCallExpression(imported!"dmd.expression".CallExp call) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.builtins:
            binaryBuiltinCall,
            interpreterBuiltinArgumentCount,
            tryInterpreterBuiltin,
            unaryBuiltinCall;

        if (call.f !is null) {
            import dmd.funcsem: functionSemantic3;
            functionSemantic3(call.f);
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins: InterpreterBuiltin;

            InterpreterBuiltin builtin;
            if (
                tryInterpreterBuiltin(call.f, builtin) &&
                call.arguments !is null &&
                call.arguments.length == interpreterBuiltinArgumentCount(builtin)
            ) {
                with (InterpreterBuiltin) final switch (builtin) {
                    case fabs:
                    case isInfinity:
                    case signbit:
                    case sqrt:
                        return unaryBuiltinCall(
                            builtin,
                            runExpression((*call.arguments)[0]),
                        );

                    case pow:
                        return binaryBuiltinCall(
                            builtin,
                            runExpression((*call.arguments)[0]),
                            runExpression((*call.arguments)[1]),
                        );
                }
            }
        }

        if (call.f !is null && isDruntimeArrayOpAddAssign(call.f))
            return runArrayOpAddAssignCall(call);

        if (call.f !is null && functionName(call.f) == "memcpy") {
            if (call.arguments is null || call.arguments.length < 2)
                throw new Exception("Unsupported eval call.");
            const destination = runExpression((*call.arguments)[0]);
            Value[] source;
            const sourcePointer = runExpression((*call.arguments)[1]);
            foreach (index; 0 .. sourcePointer.pointerLength)
                source ~= sourcePointer.pointerIndex(index);

            if (source.length != 0 && source[0].isStruct) {
                writePointerElements((*call.arguments)[0], destination, source);
                recordStaticArrayCopySource(destination, sourcePointer);
                return destination;
            }

            return destination;
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins:
                AssocArrayHook, tryAssocArrayHook;

            AssocArrayHook assocArrayHook;
            if (tryAssocArrayHook(call.f, assocArrayHook))
                return runAssocArrayHookCall(call, assocArrayHook);
        }

        if (call.f !is null && !call.f.needThis) {
            import quickbite.frontend.dmd.functions:
                hasNoAvailableSource, noAvailableSourceMessage;

            if (hasNoAvailableSource(call.f))
                throw new Exception(noAvailableSourceMessage(call.f));
        }

        auto stringForeachApply = call.f is null
            ? callExpressionFunction(call.e1)
            : call.f;
        if (
            stringForeachApply !is null &&
            isStringForeachApplyCall(stringForeachApply)
        )
            return runStringForeachApplyCall(call, stringForeachApply);

        Value[] arguments;
        Expression[] argumentExpressions;
        if (call.arguments !is null) {
            foreach (argument; *call.arguments) {
                arguments ~= runExpression(argument);
                argumentExpressions ~= argument;
            }
        }

        if (auto dot = call.e1.isDotVarExp) {
            const receiver = runExpression(dot.e1);
            if (receiver == Value.null_)
                throw new Exception(
                    "function call through null class reference `null`",
                );

            if (call.f !is null && call.f.needThis) {
                import quickbite.frontend.dmd.functions:
                    hasNoAvailableSource, noAvailableSourceMessage;

                if (
                    call.f.isCtorDeclaration !is null &&
                    isThisOrSuperMemberCall(call)
                )
                    return runThisConstructorCall(call.f, arguments);

                auto function_ = resolveMemberFunction(call.f, receiver);
                if (hasNoAvailableSource(function_))
                    throw new Exception(noAvailableSourceMessage(function_));
                return runMemberFunction(
                    function_,
                    dot.e1,
                    receiver,
                    arguments,
                    argumentExpressions,
                );
            }
        }

        if (call.f !is null) {
            import quickbite.frontend.dmd.functions:
                hasNoAvailableSource, noAvailableSourceMessage;

            if (hasNoAvailableSource(call.f))
                throw new Exception(noAvailableSourceMessage(call.f));
            return runFunction(call.f, arguments, argumentExpressions);
        }

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return runFunction(function_, arguments, argumentExpressions);

        if (auto function_ = functionPointerExpressionFunction(call.e1)) {
            if (isZeroFormalCall(function_) && arguments.length == 5) {
                if (functionName(function_) == "enforceRawArraysConformableNogc")
                    return Value(false);

                throw new Exception("Unsupported eval call.");
            }
            return runFunction(function_, arguments, argumentExpressions);
        }

        const callee = runExpression(call.e1);
        if (callee.isFunctionPointer && callee.functionPointerId in delegates)
            return runDelegateCall(callee, arguments, argumentExpressions);

        if (callee.isFunctionPointer) {
            auto function_ = callee.functionPointerId in functionPointers;
            if (function_ is null)
                throw new Exception("Unsupported eval call.");
            return runFunction(*function_, arguments, argumentExpressions);
        }

        throw new Exception("Unsupported eval call.");
    }

    private Value runDelegateCall(
        in Value callee,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        auto runtime = callee.functionPointerId in delegates;
        if (runtime is null)
            throw new Exception("Unsupported eval call.");

        if (runtime.hasReceiver)
            return runMemberFunction(
                runtime.function_,
                null,
                delegateReceiver(*runtime),
                arguments,
                argumentExpressions,
            );

        return runFunction(runtime.function_, arguments, argumentExpressions);
    }

    private Value delegateReceiver(in RuntimeDelegate runtime) {
        if (runtime.contextPointer.isLocalPointer)
            return localPointerTarget(runtime.contextPointer);

        return runtime.receiver;
    }

    private Value runDelegatePointerExpression(
        imported!"dmd.expression".DelegatePtrExp expression,
    ) {
        return delegateProperty(runExpression(expression.e1), "ptr");
    }

    private Value runDelegateFunctionPointerExpression(
        imported!"dmd.expression".DelegateFuncptrExp expression,
    ) {
        return delegateProperty(runExpression(expression.e1), "funcptr");
    }

    private bool isStringForeachApplyCall(FuncDeclaration function_) const {
        import std.algorithm: canFind;

        const name = functionName(function_);
        return
            name.canFind("_aApplycd1") ||
            name.canFind("_aApplywd1") ||
            name.canFind("_aApplydc1") ||
            name.canFind("_aApplyRwd1");
    }

    private FuncDeclaration callExpressionFunction(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto var = expression.isVarExp)
            return var.var.isFuncDeclaration;

        return functionPointerExpressionFunction(expression);
    }

    private Value runStringForeachApplyCall(
        imported!"dmd.expression".CallExp call,
        FuncDeclaration function_,
    ) {
        if (call.arguments is null || call.arguments.length != 2)
            throw new Exception("Unsupported eval call.");

        auto body = functionPointerExpressionFunction((*call.arguments)[1]);
        if (body is null)
            throw new Exception("Unsupported eval call.");

        foreach (value; stringForeachApplyElements(
            functionName(function_),
            runExpression((*call.arguments)[0]),
        )) {
            const result = runFunction(body, [value], [null]);
            if (result != Value.void_ && result.asLong != 0)
                return result;
        }

        return Value(0);
    }

    private Value[] stringForeachApplyElements(
        in string helper,
        in Value source,
    ) {
        import std.algorithm: canFind, reverse;

        if (helper.canFind("_aApplycd1"))
            return decodedUtf8Dchars(source);

        if (helper.canFind("_aApplywd1"))
            return decodedUtf16Dchars(source);

        if (helper.canFind("_aApplydc1"))
            return utf8EncodedDstringChars(source);

        if (helper.canFind("_aApplyRwd1")) {
            auto values = decodedUtf16Dchars(source);
            values.reverse;
            return values;
        }

        throw new Exception("Unsupported eval call.");
    }

    private Value[] decodedUtf8Dchars(in Value source) {
        import std.utf: decode;

        string encoded;
        foreach (index; 0 .. source.length)
            encoded ~= cast(char) source[index].castTo!long.asLong;

        Value[] values;
        size_t index;
        while (index < encoded.length)
            values ~= Value(decode(encoded, index));

        return values;
    }

    private Value[] decodedUtf16Dchars(in Value source) {
        import std.utf: decode;

        wstring encoded;
        foreach (index; 0 .. source.length)
            encoded ~= cast(wchar) source[index].castTo!long.asLong;

        Value[] values;
        size_t index;
        while (index < encoded.length)
            values ~= Value(decode(encoded, index));

        return values;
    }

    private Value[] utf8EncodedDstringChars(in Value source) {
        import std.utf: encode;

        Value[] values;
        foreach (index; 0 .. source.length) {
            char[4] encoded;
            const length = encode(
                encoded,
                cast(dchar) source[index].castTo!long.asLong,
            );
            foreach (unit; encoded[0 .. length])
                values ~= Value(unit);
        }

        return values;
    }

    private FuncDeclaration resolveMemberFunction(
        FuncDeclaration function_,
        in Value receiver,
    ) {
        if (!receiver.isClassObject)
            return function_;

        auto class_ = dynamicClass(receiver);
        if (class_ is null)
            return function_;

        if (auto override_ = overridingFunction(class_, function_))
            return override_;

        if (auto vtbl = vtblFunction(class_, function_))
            return vtbl;

        if (auto candidate = matchingMemberFunction(class_, function_))
            return candidate;

        return function_;
    }

    private imported!"dmd.dclass".ClassDeclaration dynamicClass(in Value value) {
        return dynamicClassDeclarationByName(value.classTypeName);
    }

    private imported!"dmd.dclass".ClassDeclaration dynamicClassDeclarationByName(
        in string name,
    ) {
        auto scope_ = currentFunction is null
            ? null
            : currentFunction.toParent.isScopeDsymbol;
        while (scope_ !is null) {
            if (auto class_ = classDeclarationByNameInScope(scope_, name))
                return class_;
            auto parent = scope_.toParent;
            scope_ = parent is null ? null : parent.isScopeDsymbol;
        }

        return null;
    }

    private bool isZeroFormalCall(FuncDeclaration function_) const {
        return function_.parameters is null || function_.parameters.length == 0;
    }

    private FuncDeclaration functionPointerExpressionFunction(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto function_ = expression.isFuncExp)
            return function_.fd;

        if (auto delegate_ = expression.isDelegateExp)
            return delegate_.func;

        if (auto address = expression.isAddrExp)
            return functionPointerExpressionFunction(address.e1);

        if (auto ptr = expression.isPtrExp)
            return functionPointerExpressionFunction(ptr.e1);

        if (auto symbol = expression.isSymOffExp)
            return symbol.var.isFuncDeclaration;

        return null;
    }

    // DMD lowers `sums[] = left[] + right[]` to a druntime
    // `core.internal.array.operations.arrayOp` template call; interpret the
    // element-wise semantics directly instead of executing the druntime body.
    private bool isDruntimeArrayOpAddAssign(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import dmd.dtemplate: isExpression;
        import std.algorithm: startsWith;
        import std.conv: text;

        auto instance = function_.parent is null
            ? null
            : function_.parent.isTemplateInstance;
        if (instance is null || instance.tiargs is null)
            return false;

        if (
            !text(function_.toPrettyChars)
                .startsWith("core.internal.array.operations.arrayOp!(")
        )
            return false;

        string[] operators;
        foreach (argument; *instance.tiargs) {
            auto expression = isExpression(argument);
            if (expression is null)
                continue;

            auto literal = expression.isStringExp;
            if (literal is null)
                return false;

            operators ~= literal.peekString.idup;
        }

        return operators == ["+", "="];
    }

    private Value runArrayOpAddAssignCall(
        imported!"dmd.expression".CallExp call,
    ) {
        if (call.arguments is null || call.arguments.length != 3)
            throw new Exception("Unsupported eval call.");

        auto target = (*call.arguments)[0].isSliceExp;
        if (target is null)
            throw new Exception("Unsupported eval call.");

        const left = runExpression((*call.arguments)[1]);
        const right = runExpression((*call.arguments)[2]);
        if (left.length != right.length)
            throw new Exception("Unsupported eval call.");

        Value[] elements;
        foreach (index; 0 .. left.length)
            elements ~= left[index] + right[index];

        return writeBackSliceElements(target, elements);
    }

    private Value writeBackSliceElements(
        imported!"dmd.expression".SliceExp slice,
        Value[] elements,
    ) {
        auto var = slice.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported eval call.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported eval call.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported eval call.");

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? current.length
            : cast(size_t) runExpression(slice.upr).asLong;
        if (upper - lower != elements.length)
            throw new Exception("Unsupported eval call.");

        Value[] updated;
        foreach (index; 0 .. current.length)
            updated ~= index >= lower && index < upper
                ? elements[index - lower]
                : (*current)[index];

        locals[variable] = Value.arrayValue(updated);
        uninitializedLocals.remove(variable);
        return locals[variable];
    }

    // DMD lowers associative array operations to druntime template hooks in
    // `core.internal.newaa` and `object`; interpret the semantics directly
    // instead of executing the druntime hook bodies.
    private Value runAssocArrayHookCall(
        imported!"dmd.expression".CallExp call,
        in imported!"quickbite.backends.interpreter.builtins".AssocArrayHook hook,
    ) {
        import quickbite.backends.interpreter.builtins: AssocArrayHook;

        if (call.arguments is null)
            throw new Exception("Unsupported eval call.");

        with (AssocArrayHook) final switch (hook) {
            case length:
                requireArgumentCount(call, 1);
                return Value(runExpression((*call.arguments)[0]).length);

            case getRvalue:
                requireArgumentCount(call, 2);
                return runAssocArrayReadCall(call);

            case getLvalue:
                requireArgumentCount(call, 3);
                return runAssocArrayLvalueCall(call);

            case in_:
                requireArgumentCount(call, 2);
                return runAssocArrayInCall(call);

            case remove:
                requireArgumentCount(call, 2);
                return runAssocArrayRemoveCall(call);

            case equal:
                requireArgumentCount(call, 2);
                return Value(
                    runExpression((*call.arguments)[0]) ==
                    runExpression((*call.arguments)[1]),
                );

            case dup:
                requireArgumentCount(call, 1);
                return runExpression((*call.arguments)[0]);

            case keys:
                requireArgumentCount(call, 1);
                return runExpression((*call.arguments)[0]).assocArrayKeys;

            case values:
                requireArgumentCount(call, 1);
                return runExpression((*call.arguments)[0]).assocArrayValues;

            case apply2:
                requireArgumentCount(call, 2);
                return runAssocArrayApply2Call(call);
        }
    }

    private void requireArgumentCount(
        imported!"dmd.expression".CallExp call,
        in size_t count,
    ) {
        if (call.arguments is null || call.arguments.length != count)
            throw new Exception("Unsupported eval call.");
    }

    private Value runAssocArrayReadCall(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.messages: missingKeyMessage;

        const aa = runExpression((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        if (!aa.assocArrayContains(key))
            throw new Exception(missingKeyMessage(
                (*call.arguments)[1],
                (*call.arguments)[0],
            ));

        return Value.pointerValue(aa.assocArrayElement(key));
    }

    // `aa[key] = value` lowers to a write through the slot pointer returned
    // by `_d_aaGetY(aa, key, found)`; the write-back happens via the slot
    // alias recorded for the pointer variable
    private Value runAssocArrayLvalueCall(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = runExpression((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);
        const contains = aa.assocArrayContains(key);

        if (auto found = (*call.arguments)[2].isVarExp)
            if (auto foundVariable = found.var.isVarDeclaration)
                locals[foundVariable] = Value(contains);

        return Value.pointerValue(
            contains
                ? aa.assocArrayElement(key)
                : defaultValue(call.type.toBasetype.nextOf),
        );
    }

    private Value runAssocArrayInCall(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = runExpression((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        return aa.assocArrayContains(key)
            ? Value.pointerValue(aa.assocArrayElement(key))
            : Value.null_;
    }

    private Value runAssocArrayRemoveCall(
        imported!"dmd.expression".CallExp call,
    ) {
        auto var = (*call.arguments)[0].isVarExp;
        if (var is null)
            throw new Exception("Unsupported eval call.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported eval call.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported eval call.");

        const key = runExpression((*call.arguments)[1]);
        const removed = current.assocArrayContains(key);
        locals[variable] = current.withoutAssocArrayKey(key);
        return Value(removed);
    }

    private Value runAssocArrayApply2Call(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = runExpression((*call.arguments)[0]);
        const keys = aa.assocArrayKeys;
        const values = aa.assocArrayValues;
        auto body = functionPointerExpressionFunction((*call.arguments)[1]);
        const delegate_ = body is null
            ? runExpression((*call.arguments)[1])
            : Value.void_;

        foreach (index; 0 .. keys.length) {
            const arguments = [keys[index], values[index]];
            const result = body is null
                ? runDelegateCall(delegate_, arguments, [null, null])
                : runFunction(body, arguments, [null, null], true);
            if (result.asLong != 0)
                return result;
        }

        return Value(0);
    }

    private Value runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in bool captureLocals = false,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.locals = (captureLocals || function_.isNested)
            ? locals.dup
            : datasegLocals;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.allocationCount = allocationCount;
        child.staticArrayCopySources = staticArrayCopySources.dup;
        child.lastStaticArrayCopySource = lastStaticArrayCopySource;
        child.lastStaticArrayCopySourceValues = lastStaticArrayCopySourceValues.dup;
        child.lastStaticArrayCopyDestructor = lastStaticArrayCopyDestructor;
        child.bindFunctionParameters(function_, arguments);

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackFunctionState(
                function_,
                argumentExpressions,
                child,
                captureLocals,
            );
            throw exception;
        }
        writeBackFunctionState(
            function_,
            argumentExpressions,
            child,
            captureLocals,
        );
        return child.result;
    }

    private Value runMemberFunction(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        in Value receiver,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.locals = locals.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.allocationCount = allocationCount;
        child.staticArrayCopySources = staticArrayCopySources.dup;
        child.lastStaticArrayCopySource = lastStaticArrayCopySource;
        child.lastStaticArrayCopySourceValues = lastStaticArrayCopySourceValues.dup;
        child.lastStaticArrayCopyDestructor = lastStaticArrayCopyDestructor;
        if (receiverExpression !is null)
            if (auto var = receiverExpression.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    if (auto aliases = variable in structArrayFieldAliases) {
                        child.thisStructArrayFieldAliases = *aliases;
                        foreach (_, sourceVariable; aliases.sources)
                            if (auto value = sourceVariable in locals)
                                child.locals[sourceVariable] = *value;
                    }
        // For constructor calls, DMD may blit the target variable to zero
        // before the ctor runs (e.g. `box = 0 , box.this(input)`), so the
        // receiver evaluates to a non-struct scalar.  Seed `thisValue` from
        // the struct's proper default in that case so the ctor body can write
        // fields.  When the receiver is already a valid struct (e.g.
        // MapResult created from a StructLiteralExp with elements), use it
        // as-is to preserve any hidden context fields.
        if (function_.isCtorDeclaration !is null && !receiver.isStruct) {
            import dmd.dstruct: StructDeclaration;

            auto structDecl = function_.parent is null
                ? null
                : function_.parent.isStructDeclaration;
            child.thisValue = structDecl !is null
                ? defaultValue(structDecl.type)
                : receiver;
        } else {
            child.thisValue = receiver;
        }
        child.hasThis = true;
        child.bindFunctionParameters(function_, arguments);

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackMemberFunctionState(
                function_,
                receiverExpression,
                argumentExpressions,
                child,
            );
            throw exception;
        }
        writeBackMemberFunctionState(
            function_,
            receiverExpression,
            argumentExpressions,
            child,
        );

        if (function_.isCtorDeclaration !is null)
            return child.thisValue;

        return child.result;
    }

    private void writeBackFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in bool captureLocals = false,
    ) {
        nextLocalPointerId = child.nextLocalPointerId;
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        allocationCount = child.allocationCount;
        arrayAllocations = child.arrayAllocations;
        arrayAllocationVariables = child.arrayAllocationVariables;
        staticArrayCopySources = child.staticArrayCopySources;
        lastStaticArrayCopySource = child.lastStaticArrayCopySource;
        lastStaticArrayCopySourceValues = child.lastStaticArrayCopySourceValues.dup;
        lastStaticArrayCopyDestructor = child.lastStaticArrayCopyDestructor;
        writeBackNestedLocals(function_, child, captureLocals);
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
        writeBackRefArguments(function_, argumentExpressions, child);
        writeBackByValueStructArguments(function_, argumentExpressions, child);
    }

    private void writeBackMemberFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        nextLocalPointerId = child.nextLocalPointerId;
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        allocationCount = child.allocationCount;
        arrayAllocations = child.arrayAllocations;
        arrayAllocationVariables = child.arrayAllocationVariables;
        staticArrayCopySources = child.staticArrayCopySources;
        lastStaticArrayCopySource = child.lastStaticArrayCopySource;
        lastStaticArrayCopySourceValues = child.lastStaticArrayCopySourceValues.dup;
        lastStaticArrayCopyDestructor = child.lastStaticArrayCopyDestructor;
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
        writeBackRefArguments(function_, argumentExpressions, child);
        writeBackThisStructArrayFieldAliases(child);
        child.returned = false;
        writeBackThis(receiverExpression, child.thisValue);
    }

    private void writeBackNestedLocals(
        imported!"dmd.func".FuncDeclaration function_,
        ref Walker child,
        in bool captureLocals = false,
    ) {
        if (!captureLocals && !function_.isNested)
            return;

        foreach (variable, value; child.locals)
            if (variable in locals)
                locals[variable] = value;
    }

    private void writeBackGlobals(ref Walker child) {
        foreach (variable, value; child.locals) {
            if (variable.isDataseg)
                locals[variable] = value;
        }
    }

    private void writeBackLocalPointerTargets(ref Walker child) {
        foreach (_, variable; child.localPointers) {
            if (auto value = variable in child.locals)
                locals[variable] = *value;
        }
    }

    private void runDestructor(
        imported!"dmd.func".FuncDeclaration function_,
        in Value receiver,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.locals = locals.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.allocationCount = allocationCount;
        child.staticArrayCopySources = staticArrayCopySources.dup;
        child.lastStaticArrayCopySource = lastStaticArrayCopySource;
        child.lastStaticArrayCopySourceValues = lastStaticArrayCopySourceValues.dup;
        child.lastStaticArrayCopyDestructor = lastStaticArrayCopyDestructor;
        child.thisValue = receiver;
        child.hasThis = true;

        child.runStatement(function_.fbody);
        nextLocalPointerId = child.nextLocalPointerId;
        allocationCount = child.allocationCount;
        arrayAllocations = child.arrayAllocations;
        arrayAllocationVariables = child.arrayAllocationVariables;
        staticArrayCopySources = child.staticArrayCopySources;
        lastStaticArrayCopySource = child.lastStaticArrayCopySource;
        lastStaticArrayCopySourceValues = child.lastStaticArrayCopySourceValues.dup;
        lastStaticArrayCopyDestructor = child.lastStaticArrayCopyDestructor;
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
    }

    private Value[VarDeclaration] datasegLocals() {
        Value[VarDeclaration] result;
        foreach (variable, value; locals) {
            if (variable.isDataseg)
                result[variable] = value;
        }

        return result;
    }

    private void writeBackThisStructArrayFieldAliases(ref Walker child) {
        foreach (_, sourceVariable; child.thisStructArrayFieldAliases.sources) {
            if (auto value = sourceVariable in child.locals)
                locals[sourceVariable] = *value;
        }
    }

    private void writeBackThis(
        imported!"dmd.expression".Expression receiver,
        in Value value,
    ) {
        // mutations of `this` persist only through lvalue receivers; rvalue
        // temporaries such as struct literals discard them, matching D
        if (!isWritableLocation(receiver))
            return;

        writeLocation(receiver, value);
    }

    private bool isWritableLocation(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression is null)
            return false;

        return
            expression.isVarExp !is null ||
            expression.isDotVarExp !is null ||
            expression.isThisExp !is null;
    }

    private void bindFunctionParameters(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
    ) {
        if (arguments.length == 0) {
            if (function_.parameters !is null && function_.parameters.length != 0)
                throw new Exception("Unsupported interpreter call arguments.");
            return;
        }

        if (
            function_.parameters is null ||
            function_.parameters.length != arguments.length
        )
            throw new Exception("Unsupported interpreter call arguments.");

        foreach (index, parameter; *function_.parameters)
            locals[parameter] = arguments[index];
    }

    private void writeBackRefArguments(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (!parameter.isReference)
                continue;

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            if (argument is null || !isWritableLocation(argument))
                continue;

            if (auto value = parameter in child.locals)
                writeLocation(argument, *value);
        }
    }

    // D slices passed inside a by-value struct share their backing array with
    // the caller.  Write back element mutations (up to the original length)
    // so that element writes inside the callee are visible to the caller,
    // while descriptor changes (append, reassignment) do not leak.
    private void writeBackByValueStructArguments(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (parameter.isReference)
                continue;

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            if (argument is null || !isWritableLocation(argument))
                continue;

            auto finalParam = parameter in child.locals;
            if (finalParam is null || !finalParam.isStruct)
                continue;

            const original = runExpression(argument);
            if (!original.isStruct)
                continue;

            const fieldCount = original.structFieldCount;
            if (finalParam.structFieldCount != fieldCount)
                continue;

            Value updatedStruct = original;
            bool anyChange;
            foreach (fieldIndex; 0 .. fieldCount) {
                const origField = original.structFieldAt(fieldIndex);
                const finalField = finalParam.structFieldAt(fieldIndex);
                if (!origField.isArray || !finalField.isArray)
                    continue;

                const origLen = origField.length;
                const finalLen = finalField.length;
                const copyLen = origLen < finalLen ? origLen : finalLen;
                if (copyLen == 0)
                    continue;

                Value updatedField = origField;
                foreach (elemIdx; 0 .. copyLen)
                    updatedField = updatedField.withArrayElement(elemIdx, finalField[elemIdx]);

                updatedStruct = updatedStruct.withStructField(fieldIndex, updatedField);
                anyChange = true;
            }

            if (anyChange)
                writeLocation(argument, updatedStruct);
        }
    }

    private Value runEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;

        const left = runExpression(equal.e1);
        const right = runExpression(equal.e2);
        const same = equalValues(left, right);
        if (equal.op == EXP.notEqual)
            return Value(!same);
        return Value(same);
    }

    private bool equalValues(in Value left, in Value right) {
        if (left.isNumericScalar && right.isNumericScalar)
            return left.asReal == right.asReal;

        if (left.isArray && right.isArray)
            return equalArrayValues(left, right);

        return left == right;
    }

    private bool equalArrayValues(in Value left, in Value right) {
        if (left.length != right.length)
            return false;

        foreach (index; 0 .. left.length)
            if (!equalValues(left[index], right[index]))
                return false;

        return true;
    }

    private bool isScalarCompoundAssignExpression(
        imported!"dmd.expression".Expression expression,
    ) const {
        import dmd.tokens: EXP;

        switch (expression.op) with (EXP) {
            case minAssign:
            case mulAssign:
            case divAssign:
            case modAssign:
            case leftShiftAssign:
            case rightShiftAssign:
            case unsignedRightShiftAssign:
            case andAssign:
            case orAssign:
            case xorAssign:
                return true;

            default:
                return false;
        }
    }

    private Value runCompoundAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        const left = runExpression(assign.e1);
        const right = runExpression(assign.e2);
        const value = compoundAssignedValue(assign, left, right);
        writeLocation(assign.e1, value);
        return runExpression(assign.e1);
    }

    private Value compoundAssignedValue(
        imported!"dmd.expression".BinExp assignment,
        in Value left,
        in Value right,
    ) {
        import dmd.tokens: EXP;

        switch (assignment.op) {
            case EXP.addAssign:
                if (left.isPointer)
                    return left.pointerOffsetBy(
                        pointerElementOffset(assignment.e1.type, right.asLong),
                    );
                return left + right;

            case EXP.minAssign:
                return left - right;

            case EXP.mulAssign:
                return left * right;

            case EXP.divAssign:
                rejectIntMinMinusOneOverflow(left, right, "/");
                return left / right;

            case EXP.modAssign:
                rejectIntMinMinusOneOverflow(left, right, "%");
                return left % right;

            case EXP.leftShiftAssign:
                return runIntegerBinaryValue(assignment, left, right, "<<");

            case EXP.rightShiftAssign:
                return runIntegerBinaryValue(assignment, left, right, ">>");

            case EXP.unsignedRightShiftAssign:
                return runIntegerBinaryValue(assignment, left, right, ">>>");

            case EXP.andAssign:
                return runIntegerBinaryValue(assignment, left, right, "&");

            case EXP.orAssign:
                return runIntegerBinaryValue(assignment, left, right, "|");

            case EXP.xorAssign:
                return runIntegerBinaryValue(assignment, left, right, "^");

            default:
                throw new Exception("Unsupported eval compound assignment.");
        }
    }

    private Value runPowExpression(imported!"dmd.expression".PowExp pow) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const base = runExpression(pow.e1);
        auto exponent = runExpression(pow.e2).asLong;
        if (exponent < 0)
            throw new Exception("Unsupported negative integer exponent.");

        Value result = backendCastValue(Value(1), backendCastTarget(pow.type));
        Value factor = backendCastValue(base, backendCastTarget(pow.type));
        while (exponent != 0) {
            if ((exponent & 1) != 0)
                result = result * factor;
            exponent >>= 1;
            if (exponent != 0)
                factor = factor * factor;
        }

        return backendCastValue(result, backendCastTarget(pow.type));
    }

    private Value runIntegerComplementExpression(
        imported!"dmd.expression".ComExp complement,
    ) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        return backendCastValue(
            Value(~runExpression(complement.e1).asLong),
            backendCastTarget(complement.type),
        );
    }

    private Value runIntegerBinaryExpression(
        imported!"dmd.expression".BinExp expression,
        in string operator,
    ) {
        return runIntegerBinaryValue(
            expression,
            runExpression(expression.e1),
            runExpression(expression.e2),
            operator,
        );
    }

    private Value runIntegerBinaryValue(
        imported!"dmd.expression".BinExp expression,
        in Value leftValue,
        in Value rightValue,
        in string operator,
    ) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const left = leftValue.asLong;
        const right = rightValue.asLong;
        long result;
        switch (operator) {
            case "<<":
                result = left << right;
                break;

            case ">>":
                result = left >> right;
                break;

            case ">>>":
                return backendCastValue(
                    Value(unsignedShiftRight(leftValue, expression.e1.type, right)),
                    backendCastTarget(expression.type),
                );

            case "&":
                result = left & right;
                break;

            case "|":
                result = left | right;
                break;

            case "^":
                result = left ^ right;
                break;

            default:
                assert(0);
        }

        return backendCastValue(Value(result), backendCastTarget(expression.type));
    }

    private ulong unsignedShiftRight(
        in Value value,
        imported!"dmd.mtype".Type type,
        in long shift,
    ) {
        import dmd.astenums: TY;

        auto basetype = type is null ? null : type.toBasetype;
        if (basetype is null)
            return cast(ulong) value.asLong >> shift;

        switch (basetype.ty) with (TY) {
            case Tint8:
            case Tuns8:
            case Tchar:
                return cast(ubyte) value.asLong >> shift;

            case Tint16:
            case Tuns16:
            case Twchar:
                return cast(ushort) value.asLong >> shift;

            case Tint32:
            case Tuns32:
            case Tdchar:
                return cast(uint) value.asLong >> shift;

            case Tint64:
            case Tuns64:
                return cast(ulong) value.asLong >> shift;

            default:
                throw new Exception("Unsupported unsigned right shift operand.");
        }
    }

    private Value runDotVarExpression(imported!"dmd.expression".DotVarExp dot) {
        import quickbite.backends.interpreter.messages: receiverName;
        import std.conv: text;

        if (declarationName(dot.var) == "classinfo")
            return runClassInfoExpression(dot);

        if (declarationName(dot.var) == "name")
            if (auto typeid_ = dot.e1.isTypeidExp)
                return Value(typeInfoName(typeidObjectType(typeid_)));

        if (declarationName(dot.var) == "name")
            if (auto symbol = dot.e1.isSymOffExp)
                if (auto type = symbolOffsetTypeInfoType(symbol))
                    return Value(typeInfoName(type));

        if (declarationName(dot.var) == "name")
            if (dot.e1.isPtrExp !is null)
                return runClassInfoNameOwnerExpression(dot.e1);

        const receiver = runExpression(dot.e1);
        if (receiver == Value.null_)
            throw new Exception(text(
                "class `",
                receiverName(dot.e1),
                "` is `null` and cannot be dereferenced",
            ));

        if (receiver.isFunctionPointer && receiver.functionPointerId in delegates)
            return delegateProperty(receiver, declarationName(dot.var));

        if (receiver.isTypeName && declarationName(dot.var) == "name")
            return Value(receiver.asTypeNameString);

        if (dot.var.isVarDeclaration !is null) {
            const target = receiver.isLocalPointer
                ? localPointerTarget(receiver)
                : receiver;
            if (target.isClassObject)
                return target.classFieldAt(classFieldIndex(dot, target));
            return target.structFieldAt(structFieldIndex(dot));
        }

        throw new Exception("Unsupported interpreter field read.");
    }

    private Value runClassInfoExpression(
        imported!"dmd.expression".DotVarExp classInfo,
    ) {
        if (classInfo.e1.isTypeExp is null) {
            const receiver = runExpression(classInfo.e1);
            if (receiver.isClassObject)
                return Value.typeName(receiver.classTypeName);
        }

        return Value.typeName(typeInfoName(classInfo.e1.type));
    }

    private Value runClassInfoNameOwnerExpression(
        imported!"dmd.expression".Expression ownerExpression,
    ) {
        const receiver = runExpression(classInfoNameOwnerExpression(ownerExpression));
        if (receiver.isClassObject)
            return Value(receiver.classTypeName);

        throw new Exception("Unsupported interpreter field read.");
    }

    private imported!"dmd.expression".Expression classInfoNameOwnerExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto pointer = expression.isPtrExp)
            return classInfoNameOwnerExpression(pointer.e1);

        return expression;
    }

    private Value runDotIdentifierExpression(
        imported!"dmd.expression".DotIdExp dot,
    ) {
        const receiver = runExpression(dot.e1);
        const name = dot.ident is null ? "" : dot.ident.toString;
        if (name == "re")
            return receiver.complexRealPart;
        if (name == "im")
            return receiver.complexImaginaryPart;

        throw new Exception("Unsupported interpreter property read.");
    }

    private Value delegateProperty(in Value receiver, in string name) {
        auto runtime = receiver.functionPointerId in delegates;
        if (runtime is null)
            throw new Exception("Unsupported interpreter field read.");

        if (name == "ptr")
            return runtime.contextPointer;

        if (name == "funcptr")
            return Value.functionPointerValue(runtime.functionPointerId);

        throw new Exception("Unsupported interpreter field read.");
    }

    private Value runTypeidExpression(
        imported!"dmd.expression".TypeidExp typeid_,
    ) {
        import dmd.dtemplate: isExpression;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.messages: isClassExpression, receiverName;
        import std.conv: text;

        auto expression = isExpression(typeid_.obj);
        if (expression is null) {
            auto type = cast(Type) typeid_.obj;
            if (type is null)
                throw new Exception("Unsupported interpreter typeid expression.");

            return typeidValue(typeid_, typeInfoName(type));
        }

        const value = runExpression(expression);
        if (value == Value.null_ || (isClassExpression(expression) &&
            value == Value(false)))
            throw new Exception(text(
                "null pointer dereference evaluating typeid. `",
                receiverName(expression),
                "` is `null`",
            ));

        if (value.isClassObject)
            return typeidValue(typeid_, value.classTypeName);

        return typeidValue(typeid_, typeInfoName(expression.type));
    }

    private Value typeidValue(
        imported!"dmd.expression".TypeidExp typeid_,
        in string name,
    ) {
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        return isCharacterArrayType(typeid_.type)
            ? Value(name)
            : Value.typeName(name);
    }

    private Value runVectorExpression(
        imported!"dmd.expression".VectorExp vector,
    ) {
        auto staticArray = vector.to.basetype.toBasetype.isTypeSArray;
        if (staticArray is null)
            throw new Exception("Unsupported interpreter vector expression.");

        const value = runExpression(vector.e1);
        const length = cast(size_t) staticArray.dim.toInteger;

        Value[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        return Value.arrayValue(elements);
    }

    private Value runAssignExpression(imported!"dmd.expression".BinExp assign) {
        if (auto pointer = assign.e1.isPtrExp)
            if (isAssocArraySlotPointer(pointer.e1))
                return runAssocArraySlotAssignExpression(pointer.e1, assign.e2);

        if (auto index = assign.e1.isIndexExp)
            return runIndexAssignExpression(index, assign.e2);

        if (auto slice = assign.e1.isSliceExp)
            return runSliceAssignExpression(slice, assign.e2);

        const value = runExpression(assign.e2);
        writeLocation(assign.e1, value);
        return value;
    }

    private void writeLocation(
        imported!"dmd.expression".Expression target,
        in Value value,
    ) {
        if (auto cast_ = target.isCastExp) {
            writeLocation(cast_.e1, value);
            return;
        }

        if (auto var = target.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported interpreter assignment target.");

            locals[variable] = storageValue(variable.type, value);
            writeThroughArrayElementAlias(variable, locals[variable]);
            uninitializedLocals.remove(variable);
            if ((variable in arrayElementAliases) is null) {
                sliceAliases.remove(variable);
                structArrayFieldAliases.remove(variable);
            }
            return;
        }

        if (target.isThisExp !is null && hasThis) {
            thisValue = value;
            return;
        }

        if (target.isSuperExp !is null && hasThis) {
            thisValue = value;
            return;
        }

        if (auto dot = target.isDotVarExp) {
            const receiver = runExpression(dot.e1);
            if (receiver.isLocalPointer) {
                const targetValue = localPointerTarget(receiver);
                writeLocation(dot.e1, targetValue.isClassObject
                    ? targetValue.withClassField(classFieldIndex(dot, targetValue), value)
                    : targetValue.withStructField(structFieldIndex(dot), value));
                return;
            }

            writeLocation(dot.e1, receiver.isClassObject
                ? receiver.withClassField(classFieldIndex(dot, receiver), value)
                : receiver.withStructField(structFieldIndex(dot), value));
            return;
        }

        if (auto index = target.isIndexExp) {
            writeIndexLocation(index, value);
            return;
        }

        // `*ptr = value`: update the pointer variable so its target holds value.
        if (auto ptr = target.isPtrExp) {
            const pointer = runExpression(ptr.e1);
            if (pointer.isLocalPointer) {
                auto variable = pointer.localPointerId in localPointers;
                if (variable is null)
                    throw new Exception("Unsupported interpreter assignment target.");

                locals[*variable] = value;
                uninitializedLocals.remove(*variable);
                return;
            }

            if (writeThroughArrayPointer(pointer, value))
                return;

            writeLocation(ptr.e1, pointer.withPointerTarget(value));
            return;
        }

        import std.conv: text;
        throw new Exception(
            text("Unsupported interpreter assignment target: ", target.op),
        );
    }

    private Value storageValue(
        imported!"dmd.mtype".Type type,
        in Value value,
    ) {
        import quickbite.backends.casts:
            backendCastValue = castValue,
            CastTarget,
            tryCastTarget;
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        if (type is null)
            return value;

        if (value.isTypeName && isCharacterArrayType(type))
            return Value(value.asTypeNameString);

        CastTarget target;
        if (!tryCastTarget(type, target))
            return value;

        return backendCastValue(value, target);
    }

    private bool writeThroughArrayPointer(in Value pointer, in Value value) {
        if (!pointer.isPointer || pointer.pointerAllocation == 0)
            return false;

        auto variable = pointer.pointerAllocation in arrayAllocationVariables;
        if (variable is null)
            return false;

        auto current = *variable in locals;
        if (current is null)
            return false;

        locals[*variable] = current.withArrayElement(
            cast(size_t) pointer.pointerElementOffset,
            value,
        );
        uninitializedLocals.remove(*variable);
        return true;
    }

    private void writeIndexLocation(
        imported!"dmd.expression".IndexExp index,
        in Value value,
    ) {
        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;

        if (auto dot = index.e1.isDotVarExp) {
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const updatedArray = receiver.structFieldAt(fieldIndex)
                .withArrayElement(arrayIndex, value);
            writeLocation(dot.e1, receiver.withStructField(fieldIndex, updatedArray));
            if (dot.e1.isThisExp !is null)
                writeThroughThisStructArrayFieldAlias(fieldIndex, arrayIndex, value);
            return;
        }

        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        locals[variable] = current.withArrayElement(arrayIndex, value);
        writeThroughSliceAlias(variable, arrayIndex, value);
        uninitializedLocals.remove(variable);
    }

    private size_t structFieldIndex(imported!"dmd.expression".DotVarExp dot) {
        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception("Unsupported interpreter field access.");

        auto structType = receiverStructType(dot.e1);
        if (structType is null || structType.sym is null)
            throw new Exception("Unsupported interpreter field access.");

        foreach (index; 0 .. structType.sym.fields.length)
            if (structType.sym.fields[index] is field)
                return index;

        throw new Exception("Unsupported interpreter field access.");
    }

    private size_t classFieldIndex(imported!"dmd.expression".DotVarExp dot) {
        return classFieldIndex(dot, Value.void_);
    }

    private size_t classFieldIndex(
        imported!"dmd.expression".DotVarExp dot,
        in Value receiver,
    ) {
        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception("Unsupported interpreter field access.");

        auto class_ = receiver.isClassObject
            ? dynamicClass(receiver)
            : null;
        if (class_ is null) {
            auto classType = receiverClassType(dot.e1);
            class_ = classType is null ? null : classType.sym;
        }
        if (class_ is null)
            throw new Exception("Unsupported interpreter field access.");

        foreach (index, candidate; classFields(class_))
            if (candidate is field)
                return index;

        throw new Exception("Unsupported interpreter field access.");
    }

    private Value runIndexAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        if (isPointerType(index.e1.type))
            return runAssocArraySlotAssignExpression(index.e1, rhs);

        if (auto outer = index.e1.isIndexExp)
            return runNestedIndexAssignExpression(outer, index, rhs);

        if (auto dot = index.e1.isDotVarExp) {
            const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
            const value = runExpression(rhs);
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const updatedArray = receiver.structFieldAt(fieldIndex).withArrayElement(arrayIndex, value);
            writeLocation(dot.e1, receiver.withStructField(fieldIndex, updatedArray));
            return value;
        }

        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
        const value = runExpression(rhs);
        locals[variable] = current.withArrayElement(arrayIndex, value);
        writeThroughSliceAlias(variable, arrayIndex, value);
        uninitializedLocals.remove(variable);
        return value;
    }

    private Value runAssocArraySlotAssignExpression(
        imported!"dmd.expression".Expression pointer,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = pointer.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto alias_ = variable in assocArraySlotAliases;
        if (alias_ is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto source = alias_.source in locals;
        const current = source is null
            ? defaultLocalValue(alias_.source)
            : *source;

        auto function_ = functionPointerExpressionFunction(rhs);
        const value = function_ is null
            ? runExpression(rhs)
            : functionPointerValue(function_);
        locals[alias_.source] = current.withAssocArrayEntry(alias_.key, value);
        uninitializedLocals.remove(alias_.source);
        return value;
    }

    private bool isAssocArraySlotPointer(
        imported!"dmd.expression".Expression pointer,
    ) {
        auto var = pointer.isVarExp;
        if (var is null)
            return false;

        auto variable = var.var.isVarDeclaration;
        return variable !is null &&
            (variable in assocArraySlotAliases) !is null;
    }

    private Value runNestedIndexAssignExpression(
        imported!"dmd.expression".IndexExp outer,
        imported!"dmd.expression".IndexExp inner,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = outer.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const outerIndex = cast(size_t) runExpression(outer.e2).asLong;
        const innerIndex = cast(size_t) runExpression(inner.e2).asLong;
        const value = runExpression(rhs);
        locals[variable] = current.withArrayElement(
            outerIndex,
            (*current)[outerIndex].withArrayElement(innerIndex, value),
        );
        uninitializedLocals.remove(variable);
        return value;
    }

    private Value runSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = slice.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? current.length
            : cast(size_t) runExpression(slice.upr).asLong;

        rejectOverlappingSliceAssignment(variable, rhs, lower, upper, current.length);

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);

        Value[] elements;
        foreach (index; 0 .. current.length)
            elements ~= index < lower || index >= upper
                ? (*current)[index]
                : block ? copyArrayValue(value) : value[index - lower];

        locals[variable] = Value.arrayValue(elements);
        uninitializedLocals.remove(variable);
        return value;
    }

    private void rejectOverlappingSliceAssignment(
        VarDeclaration variable,
        imported!"dmd.expression".Expression rhs,
        in size_t lower,
        in size_t upper,
        in size_t length,
    ) {
        auto source = rhs.isSliceExp;
        if (source is null)
            return;

        auto var = source.e1.isVarExp;
        if (var is null)
            return;

        if (var.var.isVarDeclaration !is variable)
            return;

        const sourceLower = source.lwr is null
            ? 0
            : cast(size_t) runExpression(source.lwr).asLong;
        const sourceUpper = source.upr is null
            ? length
            : cast(size_t) runExpression(source.upr).asLong;

        if (lower < sourceUpper && sourceLower < upper) {
            import std.conv: text;

            throw new Exception(text(
                "overlapping slice assignment `[", lower, "..", upper,
                "] = [", sourceLower, "..", sourceUpper, "]`",
            ));
        }
    }

    private bool isBlockSliceAssignment(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: arrayElementType, isArrayType;

        auto elementType = arrayElementType(slice.type);
        if (elementType is null || !isArrayType(elementType))
            return false;

        return rhs.type !is null &&
            rhs.type.toBasetype.equals(elementType.toBasetype);
    }

    private Value copyArrayValue(in Value value) {
        Value[] elements;
        foreach (index; 0 .. value.length)
            elements ~= value[index];

        return Value.arrayValue(elements);
    }

    private Value runLoweredAssignExpression(
        imported!"dmd.expression".LoweredAssignExp assign,
    ) {
        import quickbite.frontend.dmd.types: arrayElementType, isDynamicArrayType;
        import std.conv: text;

        auto arrayLength = assign.e1.isArrayLengthExp;
        if (arrayLength is null)
            throw new Exception(text("Unsupported eval expression: ", assign.op));

        auto var = arrayLength.e1.isVarExp;
        if (var is null)
            throw new Exception(text("Unsupported eval expression: ", assign.op));

        auto variable = var.var.isVarDeclaration;
        if (variable is null || !isDynamicArrayType(variable.type))
            throw new Exception(text("Unsupported eval expression: ", assign.op));

        auto current = variable in locals;
        if (current is null)
            throw new Exception(text("Unsupported eval expression: ", assign.op));

        const lengthValue = runExpression(assign.e2);
        const newLength = cast(size_t) lengthValue.asLong;

        Value[] elements;
        foreach (index; 0 .. newLength)
            elements ~= index < current.length
                ? (*current)[index]
                : defaultValue(arrayElementType(variable.type));

        locals[variable] = Value.arrayValue(elements);
        uninitializedLocals.remove(variable);
        sliceAliases.remove(variable);
        return lengthValue;
    }

    private Value runConcatenateExpression(imported!"dmd.expression".CatExp cat) {
        return Value.arrayValue(
            concatenationElements(cat.e1) ~ concatenationElements(cat.e2),
        );
    }

    private Value[] concatenationElements(
        imported!"dmd.expression".Expression operand,
    ) {
        import quickbite.frontend.dmd.types: isArrayType;

        const value = runExpression(operand);
        if (!isArrayType(operand.type))
            return [value];

        Value[] elements;
        foreach (index; 0 .. value.length)
            elements ~= value[index];

        return elements;
    }

    private Value runArrayAppendAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (auto dot = assign.e1.isDotVarExp) {
            const appended = runExpression(assign.e1).withAppendedArrayElement(
                runExpression(assign.e2),
            );
            writeLocation(assign.e1, appended);
            return appended;
        }

        if (auto index = assign.e1.isIndexExp)
            return runIndexedArrayAppendAssignExpression(index, assign.e2);

        auto var = assign.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter array append target.");

        const value = runExpression(assign.e2);
        locals[variable] = current.withAppendedArrayElement(value);
        uninitializedLocals.remove(variable);
        sliceAliases.remove(variable);
        return locals[variable];
    }

    private Value runIndexedArrayAppendAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter array append target.");

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
        const appended = (*current)[arrayIndex]
            .withAppendedArrayElement(runExpression(rhs));
        locals[variable] = current.withArrayElement(arrayIndex, appended);
        uninitializedLocals.remove(variable);
        return appended;
    }

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;
        import quickbite.frontend.dmd.types: isPointerType;
        import dmd.astenums: TY;

        auto type = cast_.to.toBasetype;
        if (type is null)
            return runExpression(cast_.e1);

        if (type.ty == TY.Tvoid) {
            runExpression(cast_.e1);
            return Value.void_;
        }

        if (type.ty == TY.Tclass)
            return classCastValue(cast_);

        if (type.ty == TY.Tident) {
            Value value;
            if (tryIdentifierClassCastValue(cast_, value))
                return value;
        }

        if (isTransparentArrayCastTarget(type))
            return runExpression(cast_.e1);

        if (type.ty == TY.Tbool)
            return boolCastValue(cast_);

        if (isPointerType(type))
            return pointerCastValue(cast_);

        if (auto integer = cast_.e1.isIntegerExp)
            if (integer.type !is null && integer.type.ty == TY.Tenum) {
                import quickbite.frontend.dmd.values: castIntegerValue;

                return castIntegerValue(integer, type.ty);
            }

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
    }

    private Value boolCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const value = runExpression(cast_.e1);
        if (value.isPointer)
            return Value(true);
        if (value == Value.null_)
            return Value(false);

        return backendCastValue(value, backendCastTarget(cast_.to));
    }

    private Value classCastValue(imported!"dmd.expression".CastExp cast_) {
        const value = runExpression(cast_.e1);
        if (value == Value.null_)
            return value;

        auto classType = cast_.to.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception("Unsupported class cast target.");

        return value.classHasType(className(classType.sym))
            ? value
            : Value.null_;
    }

    private bool tryIdentifierClassCastValue(
        imported!"dmd.expression".CastExp cast_,
        out Value result,
    ) {
        import std.algorithm: canFind;

        if (!typeChars(cast_.to).canFind("Throwable"))
            return false;

        const value = runExpression(cast_.e1);
        if (value == Value.null_) {
            result = value;
            return true;
        }

        if (!value.isClassObject)
            return false;

        result = value.classHasType("Throwable")
            ? value
            : Value.null_;
        return true;
    }

    // DMD semantic lowers `array.ptr` to `cast(T*) array`
    private Value pointerCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.frontend.dmd.types: isArrayType;
        import std.conv: text;

        if (isArrayType(cast_.e1.type))
            return arrayPointer(cast_.e1, 0, cast_.op);

        const value = runExpression(cast_.e1);
        if (value.isPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    private Value arrayValue(
        imported!"dmd.expression".ArrayLiteralExp array,
    ) {
        Value[] values;
        if (array.elements !is null)
            foreach (element; *array.elements)
                values ~= runExpression(element);

        return Value.arrayValue(values);
    }

    private Value structLiteralValue(
        imported!"dmd.expression".StructLiteralExp literal,
    ) {
        Value[] fields;
        if (literal.elements !is null)
            foreach (index, element; *literal.elements)
                fields ~= element is null
                    ? structLiteralDefaultFieldValue(literal, index)
                    : structLiteralFieldValue(literal, index, runExpression(element));

        return Value.structValue(structLiteralName(literal), fields);
    }

    private Value structLiteralDefaultFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
    ) {
        auto field = structLiteralField(literal, index);
        return field is null ? Value.void_ : defaultValue(field);
    }

    private Value structLiteralFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
        in Value value,
    ) {
        import quickbite.frontend.dmd.types: isAssocArrayType;

        auto field = structLiteralField(literal, index);
        if (field is null)
            return value;

        if (value == Value.null_ && isAssocArrayType(field.type))
            return Value.assocArrayValue([], []);

        auto staticArray = field.type is null ? null : field.type.toBasetype.isTypeSArray;
        if (staticArray is null || value.isArray)
            return value;

        const length = cast(size_t) staticArray.dim.toInteger;
        Value[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        return Value.arrayValue(elements);
    }

    // duplicate keys keep the last value, as in compiled D
    private Value assocArrayValue(
        imported!"dmd.expression".AssocArrayLiteralExp assocArray,
    ) {
        auto value = Value.assocArrayValue([], []);
        foreach (index; 0 .. assocArray.keys.length)
            value = value.withAssocArrayEntry(
                runExpression((*assocArray.keys)[index]),
                runExpression((*assocArray.values)[index]),
            );

        return value;
    }

    private Value runSliceExpression(imported!"dmd.expression".SliceExp slice) {
        size_t lower;
        return runSliceExpression(slice, lower);
    }

    private Value runSliceExpression(
        imported!"dmd.expression".SliceExp slice,
        out size_t lower,
    ) {
        const source = runExpression(slice.e1);
        if (slice.lengthVar !is null)
            locals[slice.lengthVar] = Value(source.length);
        lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;

        if (source.isPointer) {
            if (slice.upr is null) {
                import std.conv: text;
                throw new Exception(
                    text("Unsupported eval expression: ", slice.op),
                );
            }

            const upper = cast(size_t) runExpression(slice.upr).asLong;
            return source.pointerSlice(lower, upper);
        }

        const upper = slice.upr is null
            ? source.length
            : cast(size_t) runExpression(slice.upr).asLong;

        Value[] values;
        foreach (index; lower .. upper)
            values ~= source[index];

        return Value.arrayValue(values);
    }

    private Value runIndexExpression(imported!"dmd.expression".IndexExp index) {
        size_t arrayIndex;
        return runIndexExpression(index, arrayIndex);
    }

    private Value runIndexExpression(
        imported!"dmd.expression".IndexExp index,
        out size_t arrayIndex,
    ) {
        import quickbite.frontend.dmd.types:
            isArrayType,
            isAssocArrayType,
            isPointerType;

        if (isAssocArrayType(index.e1.type)) {
            arrayIndex = 0;
            return runExpression(index.e1)
                .assocArrayElement(runExpression(index.e2));
        }

        // matches CTFE, which formats the index as unsigned
        arrayIndex = cast(size_t) cast(ulong) runExpression(index.e2).asLong;
        const source = runExpression(index.e1);
        if (index.lengthVar !is null)
            locals[index.lengthVar] = Value(source.length);

        // covers both array-backed pointers and druntime hook results such
        // as `_d_aaGetRvalueX` slot pointers, which DMD dereferences with a
        // zero index
        if (isPointerType(index.e1.type)) {
            if (source.isLocalPointer)
                return localPointerTarget(source);
            return source.pointerIndex(arrayIndex);
        }

        if (isArrayType(index.e1.type) && arrayIndex >= source.length) {
            import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;

            throw new Exception(indexOutOfBoundsMessage(
                arrayIndex,
                source.length,
                isSliceValue(index.e1),
                runningCalledFunction,
            ));
        }

        return source[arrayIndex];
    }

    private bool isSliceValue(imported!"dmd.expression".Expression expression) {
        if (expression.isSliceExp !is null)
            return true;

        auto var = expression.isVarExp;
        if (var is null)
            return false;

        auto variable = var.var.isVarDeclaration;
        return variable !is null && (variable in sliceAliases) !is null;
    }

    private Value localPointerTarget(in Value pointer) {
        auto variable = pointer.localPointerId in localPointers;
        if (variable is null)
            throw new Exception("Unsupported interpreter pointer target.");

        if (auto current = (*variable) in locals)
            return *current;

        return defaultValue(*variable);
    }

    private Value pointerTargetValue(in Value pointer) {
        if (pointer.isLocalPointer)
            return localPointerTarget(pointer);
        if (!pointer.isPointer) {
            throw new Exception("Expected pointer.");
        }

        return pointer.pointerTarget;
    }

    private void writePointerTarget(
        imported!"dmd.expression".Expression expression,
        in Value pointer,
        in Value value,
    ) {
        if (pointer.isLocalPointer) {
            auto variable = pointer.localPointerId in localPointers;
            if (variable is null)
                throw new Exception("Unsupported interpreter pointer target.");

            locals[*variable] = storageValue((*variable).type, value);
            uninitializedLocals.remove(*variable);
            return;
        }

        if (auto address = expression.isAddrExp) {
            writeLocation(address.e1, value);
            return;
        }

        if (auto cast_ = expression.isCastExp) {
            writePointerTarget(cast_.e1, pointer, value);
            return;
        }

        writeLocation(expression, pointer.withPointerTarget(value));
    }

    private void writePointerElements(
        imported!"dmd.expression".Expression expression,
        in Value pointer,
        in Value[] values,
    ) {
        if (auto cast_ = expression.isCastExp) {
            writePointerElements(cast_.e1, pointer, values);
            return;
        }

        writeLocation(expression, pointer.withPointerElements(values));
    }

    private void recordStaticArrayCopySource(
        in Value destination,
        in Value source,
    ) {
        if (!destination.isPointer || !source.isPointer)
            return;

        auto destinationVariable = destination.pointerAllocation in
            arrayAllocationVariables;
        auto sourceVariable = source.pointerAllocation in
            arrayAllocationVariables;
        if (destinationVariable is null)
            return;

        VarDeclaration sourceDeclaration;
        if (sourceVariable !is null)
            sourceDeclaration = *sourceVariable;
        else
            sourceDeclaration = matchingStaticArrayVariable(source);

        lastStaticArrayCopySourceValues = sourceValues(source);
        lastStaticArrayCopyDestructor = staticArrayDestructor(*destinationVariable);

        if (sourceDeclaration is null)
            return;

        staticArrayCopySources[*destinationVariable] = sourceDeclaration;
        lastStaticArrayCopySource = sourceDeclaration;
    }

    private VarDeclaration matchingStaticArrayVariable(in Value source) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        foreach (variable, value; locals) {
            if (!isStaticArrayType(variable.type))
                continue;

            if (value.length != source.pointerLength)
                continue;

            bool matches = true;
            foreach (index; 0 .. value.length)
                if (value[index] != source.pointerIndex(index)) {
                    matches = false;
                    break;
                }

            if (matches)
                return variable;
        }

        return null;
    }

    private void runStaticArrayCopySourceDestructor(
        imported!"dmd.expression".Expression expression,
    ) {
        auto call = expression is null ? null : expression.isCallExp;
        if (call is null || call.f is null || functionName(call.f) != "__ArrayDtor")
            return;

        if (call.arguments is null || call.arguments.length == 0)
            return;

        auto slice = (*call.arguments)[0].isSliceExp;
        if (slice is null)
            return;

        auto var = slice.e1.isVarExp;
        if (var is null)
            return;

        auto destination = var.var.isVarDeclaration;
        if (destination is null)
            return;

        auto source = destination in staticArrayCopySources;
        if (source is null) {
            if (lastStaticArrayCopySource is null) {
                if (lastStaticArrayCopySourceValues.length == 0) {
                    destroyStaticArrayVariable(destination);
                    return;
                } else {
                    destroyStaticArrayValues(
                        lastStaticArrayCopyDestructor,
                        lastStaticArrayCopySourceValues,
                    );
                    lastStaticArrayCopySourceValues = [];
                    lastStaticArrayCopyDestructor = null;
                    return;
                }
            }

            destroyStaticArrayVariable(lastStaticArrayCopySource);
            lastStaticArrayCopySource = null;
            lastStaticArrayCopySourceValues = [];
            lastStaticArrayCopyDestructor = null;
            return;
        }

        destroyStaticArrayVariable(*source);
        staticArrayCopySources.remove(destination);
        lastStaticArrayCopySourceValues = [];
        lastStaticArrayCopyDestructor = null;
    }

    private Value[] sourceValues(in Value source) {
        Value[] values;
        foreach (index; 0 .. source.pointerLength)
            values ~= source.pointerIndex(index);
        return values;
    }

    private void destroyStaticArrayValues(
        imported!"dmd.func".FuncDeclaration destructor,
        in Value[] values,
    ) {
        if (destructor is null)
            return;

        foreach (value; values)
            runDestructor(destructor, value);
    }

    private imported!"dmd.func".FuncDeclaration staticArrayDestructor(
        VarDeclaration variable,
    ) {
        auto staticArray = variable.type.toBasetype.isTypeSArray;
        if (staticArray is null)
            return null;

        auto structType = staticArray.nextOf.toBasetype.isTypeStruct;
        return structType is null ? null : structType.sym.dtor;
    }

    private void destroyStaticArrayVariable(VarDeclaration variable) {
        auto current = variable in locals;
        if (current is null)
            return;

        auto staticArray = variable.type.toBasetype.isTypeSArray;
        if (staticArray is null)
            return;

        auto structType = staticArray.nextOf.toBasetype.isTypeStruct;
        if (structType is null || structType.sym.dtor is null)
            return;

        const length = (*current).isPointer
            ? (*current).pointerLength
            : (*current).length;
        foreach (index; 0 .. length) {
            const value = (*current).isPointer
                ? (*current).pointerIndex(index)
                : (*current)[index];
            runDestructor(structType.sym.dtor, value);
        }
    }

    private imported!"dmd.expression".Expression addressTarget(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto cast_ = expression.isCastExp)
            return addressTarget(cast_.e1);

        if (auto address = expression.isAddrExp)
            return address.e1;

        return null;
    }

    private Value runNewExpression(imported!"dmd.expression".NewExp new_) {
        import dmd.astenums: TY;
        import quickbite.frontend.dmd.types: isDynamicArrayType, isPointerType, isStructType;
        import std.conv: text;

        if (new_.placement !is null || new_.thisexp !is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        if (new_.type.toBasetype.ty == TY.Tclass)
            return runNewClassExpression(new_);

        if (
            isPointerType(new_.type) &&
            isStructType(new_.type.toBasetype.nextOf)
        )
            return runNewStructPointerExpression(new_);

        if (isPointerType(new_.type))
            return runNewScalarPointerExpression(new_);

        if (
            !isDynamicArrayType(new_.type) ||
            new_.member !is null ||
            new_.arguments is null ||
            new_.arguments.length == 0
        )
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        size_t[] lengths;
        foreach (argument; *new_.arguments)
            lengths ~= cast(size_t) runExpression(argument).asLong;

        return newArrayValue(new_.type, lengths);
    }

    private Value runNewScalarPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        if (new_.member !is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        auto targetType = new_.type.toBasetype.nextOf;
        Value value = defaultValue(targetType);
        if (new_.arguments !is null) {
            if (new_.arguments.length != 1)
                throw new Exception(text("Unsupported eval expression: ", new_.op));

            value = runExpression((*new_.arguments)[0]);
        }

        return Value.arrayPointerValue([value], ++allocationCount, 0);
    }

    // Handles `new T(args)` where T is a struct type, returning a `T*` value.
    // When new_.member is null (no user-defined constructor) the arguments are
    // used as positional aggregate field initialisers.  When new_.member is a
    // constructor the constructor body is executed with a default-initialised
    // receiver and the post-construction `this` value is used.
    private Value runNewStructPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto targetType = new_.type.toBasetype.nextOf;
        Value structVal = defaultValue(targetType);

        if (new_.member !is null) {
            // User-defined constructor: run it and capture the resulting this.
            Value[] arguments;
            if (new_.arguments !is null)
                foreach (argument; *new_.arguments)
                    arguments ~= runExpression(argument);

            Walker child;
            child.runningCalledFunction = true;
            child.currentFunction = new_.member;
            child.result = Value(false);
            child.thisValue = structVal;
            child.hasThis = true;
            child.bindFunctionParameters(new_.member, arguments);
            child.runStatement(new_.member.fbody);
            structVal = child.thisValue;
        } else if (new_.arguments !is null) {
            // Aggregate initialiser: assign arguments positionally to fields.
            auto structType = targetType.isTypeStruct;
            foreach (index, argument; *new_.arguments) {
                if (index >= structType.sym.fields.length)
                    throw new Exception(text(
                        "Unsupported eval expression: ", new_.op,
                    ));
                structVal = structVal.withStructField(
                    index,
                    runExpression(argument),
                );
            }
        }

        return Value.pointerValue(structVal);
    }

    private Value runNewClassExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto allocationType = new_.newtype is null ? new_.type : new_.newtype;
        auto classType = allocationType.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        Value[] arguments;
        if (new_.arguments !is null)
            foreach (argument; *new_.arguments)
                arguments ~= runExpression(argument);

        auto object = classDefaultValue(classType.sym);
        if (new_.member is null)
            return object;

        if (isThrowableConstructor(new_.member))
            return applyThrowableConstructor(object, arguments);

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = new_.member;
        child.result = Value(false);
        child.locals = locals.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.thisValue = object;
        child.hasThis = true;
        child.bindFunctionParameters(new_.member, arguments);
        child.runStatement(new_.member.fbody);
        nextLocalPointerId = child.nextLocalPointerId;
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        return child.thisValue;
    }

    private Value newArrayValue(
        imported!"dmd.mtype".Type type,
        in size_t[] lengths,
    ) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.types: arrayElementType;
        import std.conv: text;

        // `auto` because DMD returns a mutable class reference
        auto elementType = arrayElementType(type);
        if (elementType is null)
            throw new Exception(text("Unsupported eval expression: ", EXP.new_));

        Value[] elements;
        foreach (_; 0 .. lengths[0])
            elements ~= lengths.length > 1
                ? newArrayValue(elementType, lengths[1 .. $])
                : defaultValue(elementType);

        return Value.arrayValue(elements);
    }

    private void recordSliceAlias(
        VarDeclaration variable,
        imported!"dmd.expression".SliceExp slice,
        in size_t lower,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        // pointer slices snapshot the allocation; they do not alias a local
        if (isPointerType(slice.e1.type)) {
            sliceAliases.remove(variable);
            return;
        }

        auto var = slice.e1.isVarExp;
        if (var is null) {
            sliceAliases.remove(variable);
            return;
        }

        auto source = var.var.isVarDeclaration;
        if (source is null) {
            sliceAliases.remove(variable);
            return;
        }

        if (auto alias_ = source in sliceAliases)
            sliceAliases[variable] = SliceAlias(
                alias_.source,
                alias_.lower + lower,
            );
        else
            sliceAliases[variable] = SliceAlias(source, lower);
    }

    private void writeThroughSliceAlias(
        VarDeclaration variable,
        in size_t index,
        in Value value,
    ) {
        auto alias_ = variable in sliceAliases;
        if (alias_ is null)
            return;

        auto source = alias_.source in locals;
        if (source is null)
            throw new Exception("Unsupported interpreter slice assignment target.");

        locals[alias_.source] = source.withArrayElement(alias_.lower + index, value);
        uninitializedLocals.remove(alias_.source);
    }

    private void writeThroughThisStructArrayFieldAlias(
        in size_t fieldIndex,
        in size_t index,
        in Value value,
    ) {
        auto sourceVariable = fieldIndex in thisStructArrayFieldAliases.sources;
        if (sourceVariable is null)
            return;

        auto source = *sourceVariable in locals;
        if (source is null)
            throw new Exception("Unsupported interpreter struct field alias target.");

        locals[*sourceVariable] = source.withArrayElement(index, value);
        uninitializedLocals.remove(*sourceVariable);
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(false);

        if (variable._init !is null && variable._init.isVoidInitializer !is null) {
            uninitializedLocals[variable] = true;
            return Value.void_;
        }

        if (variable._init is null || variable._init.isExpInitializer is null) {
            const value = defaultLocalValue(variable);
            locals[variable] = value;
            structArrayFieldAliases.remove(variable);
            return value;
        }

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp) {
            import quickbite.frontend.dmd.types: isStaticArrayType, isStructType;

            // DMD default-initialises static array locals with `variable[] = 0`
            // or, for synthesized lifetime code, `variable = 0`.
            if (
                isStaticArrayType(variable.type) &&
                (
                    blit.e1.isSliceExp !is null ||
                    blit.e2.isIntegerExp !is null
                )
            ) {
                const value = defaultValue(variable);
                locals[variable] = value;
                uninitializedLocals.remove(variable);
                sliceAliases.remove(variable);
                structArrayFieldAliases.remove(variable);
                return value;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                const value = defaultValue(variable);
                locals[variable] = value;
                uninitializedLocals.remove(variable);
                sliceAliases.remove(variable);
                structArrayFieldAliases.remove(variable);
                return value;
            }

            initializer = blit.e2;
        }

        if (initializer.isVoidInitExp !is null) {
            uninitializedLocals[variable] = true;
            return Value.void_;
        }

        import quickbite.frontend.dmd.types: isAssocArrayType, isDynamicArrayType;

        if (initializer.isNullExp !is null && isDynamicArrayType(variable.type)) {
            auto value = Value.arrayValue([]);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            structArrayFieldAliases.remove(variable);
            return value;
        }

        if (initializer.isNullExp !is null && isAssocArrayType(variable.type)) {
            auto value = Value.assocArrayValue([], []);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            structArrayFieldAliases.remove(variable);
            return value;
        }

        if (auto slice = initializer.isSliceExp) {
            size_t lower;
            auto value = runSliceExpression(slice, lower);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            arrayElementAliases.remove(variable);
            recordSliceAlias(variable, slice, lower);
            structArrayFieldAliases.remove(variable);
            return value;
        }

        auto indexInitializer = initializer.isIndexExp;
        const isArrayElementAlias = isRefVariable(variable) &&
            indexInitializer !is null;
        size_t arrayElementAliasIndex;
        auto value = storageValue(
            variable.type,
            isArrayElementAlias
                ? runIndexExpression(indexInitializer, arrayElementAliasIndex)
                : runExpression(initializer),
        );
        locals[variable] = value;
        uninitializedLocals.remove(variable);
        if (isArrayElementAlias)
            recordArrayElementAlias(variable, indexInitializer, arrayElementAliasIndex);
        else {
            arrayElementAliases.remove(variable);
            sliceAliases.remove(variable);
        }
        recordStructArrayFieldAliases(variable, initializer);
        recordAssocArraySlotAlias(variable, initializer);
        return value;
    }

    private Value defaultLocalValue(VarDeclaration variable) {
        import quickbite.frontend.dmd.types: isAssocArrayType;

        if (isAssocArrayType(variable.type))
            return Value.assocArrayValue([], []);

        return defaultValue(variable);
    }

    private void recordStructArrayFieldAliases(
        VarDeclaration variable,
        imported!"dmd.expression".Expression initializer,
    ) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        auto literal = initializer.isStructLiteralExp;
        if (literal is null || literal.elements is null) {
            structArrayFieldAliases.remove(variable);
            return;
        }

        StructArrayFieldAliases aliases;
        foreach (index, element; *literal.elements) {
            if (element is null)
                continue;

            auto var = element.isVarExp;
            if (var is null)
                continue;

            auto source = var.var.isVarDeclaration;
            if (source is null)
                continue;

            if (!isDynamicArrayType(source.type))
                continue;

            aliases.sources[index] = source;
        }

        if (aliases.sources.length == 0)
            structArrayFieldAliases.remove(variable);
        else
            structArrayFieldAliases[variable] = aliases;
    }

    private void recordArrayElementAlias(
        VarDeclaration variable,
        imported!"dmd.expression".IndexExp index,
        in size_t arrayIndex,
    ) {
        auto var = index.e1.isVarExp;
        if (var is null) {
            arrayElementAliases.remove(variable);
            return;
        }

        auto source = var.var.isVarDeclaration;
        if (source is null) {
            arrayElementAliases.remove(variable);
            return;
        }

        arrayElementAliases[variable] = ArrayElementAlias(
            source,
            arrayIndex,
        );
    }

    private void writeThroughArrayElementAlias(
        VarDeclaration variable,
        in Value value,
    ) {
        auto alias_ = variable in arrayElementAliases;
        if (alias_ is null)
            return;

        auto source = alias_.source in locals;
        if (source is null)
            throw new Exception("Unsupported interpreter array element alias target.");

        locals[alias_.source] = source.withArrayElement(alias_.index, value);
        writeThroughSliceAlias(alias_.source, alias_.index, value);
        uninitializedLocals.remove(alias_.source);
    }

    private bool isRefVariable(VarDeclaration variable) const {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.ref_) != STC.none;
    }

    private void recordAssocArraySlotAlias(
        VarDeclaration variable,
        imported!"dmd.expression".Expression initializer,
    ) {
        import quickbite.backends.interpreter.builtins:
            AssocArrayHook, tryAssocArrayHook;

        assocArraySlotAliases.remove(variable);

        auto call = initializer.isCallExp;
        if (call is null || call.f is null || call.arguments is null ||
            call.arguments.length != 3)
            return;

        AssocArrayHook hook;
        if (!tryAssocArrayHook(call.f, hook) || hook != AssocArrayHook.getLvalue)
            return;

        auto var = (*call.arguments)[0].isVarExp;
        if (var is null)
            return;

        auto source = var.var.isVarDeclaration;
        if (source is null)
            return;

        assocArraySlotAliases[variable] = AssocArraySlotAlias(
            source,
            runExpression((*call.arguments)[1]),
        );
    }

    private Value runPostIncrementExpression(
        imported!"dmd.expression".PostExp post,
    ) {
        import dmd.tokens: EXP;

        const delta = post.op == EXP.plusPlus
            ? Value(cast(int) 1)
            : post.op == EXP.minusMinus
                ? Value(cast(int) -1)
                : Value.void_;
        if (delta == Value.void_)
            throw new Exception("Unsupported eval post expression.");

        if (auto var = post.e1.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported eval post expression target.");

            auto current = variable in locals;
            const oldValue = current is null ? defaultValue(variable) : *current;
            writeLocation(post.e1, oldValue + delta);
            return oldValue;
        }

        if (post.e1.isDotVarExp !is null) {
            const oldValue = runExpression(post.e1);
            writeLocation(post.e1, oldValue + delta);
            return oldValue;
        }

        if (auto pointer = post.e1.isPtrExp) {
            const target = runExpression(pointer.e1);
            const oldValue = pointerTargetValue(target);
            writePointerTarget(pointer.e1, target, oldValue + delta);
            return oldValue;
        }

        throw new Exception("Unsupported eval post expression target.");
    }

    private Value runAddAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (!runExpression(assign.e1).isLocalPointer)
            return runCompoundAssignExpression(assign);

        const left = runExpression(assign.e1);
        const right = runExpression(assign.e2);
        if (left.isLocalPointer) {
            const value = localPointerTarget(left) + right;
            writePointerTarget(assign.e1, left, value);
            return value;
        }

        const value = left.isPointer
            ? left.pointerOffsetBy(pointerElementOffset(assign.e1.type, right.asLong))
            : left + right;
        writeLocation(assign.e1, value);
        return value;
    }
}


private imported!"dmd.mtype".TypeStruct receiverStructType(
    imported!"dmd.expression".Expression receiver,
) {
    if (receiver.type is null)
        return null;

    return receiver.type.toBasetype.isTypeStruct;
}


private imported!"dmd.mtype".TypeClass receiverClassType(
    imported!"dmd.expression".Expression receiver,
) {
    if (receiver.type is null)
        return null;

    return receiver.type.toBasetype.isTypeClass;
}


private imported!"quickbite.lang".Value classDefaultValue(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    import quickbite.frontend.dmd.values: defaultValue;
    import quickbite.lang: Value;

    string[] fieldNames;
    Value[] fields;
    foreach (field; classFields(class_)) {
        fieldNames ~= variableName(field);
        fields ~= defaultValue(field.type);
    }

    return Value.classValue(
        classInfoName(class_),
        classTypeNames(class_),
        fieldNames,
        fields,
    );
}


private imported!"dmd.declaration".VarDeclaration[] classFields(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    imported!"dmd.dclass".ClassDeclaration[] classes;
    for (auto current = class_; current !is null; current = current.baseClass)
        classes ~= current;

    imported!"dmd.declaration".VarDeclaration[] fields;
    foreach_reverse (current; classes)
        foreach (field; current.fields)
            fields ~= field;

    return fields;
}


private imported!"dmd.func".FuncDeclaration overridingFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (current; classHierarchy(class_))
        if (current.members !is null)
            foreach (member; *current.members)
                if (auto function_ = member.isFuncDeclaration)
                    if (overridesFunction(function_, base))
                        return function_;

    return null;
}


private bool overridesFunction(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (override_; function_.foverrides) {
        if (override_ is base)
            return true;
        if (overridesFunction(override_, base))
            return true;
    }

    return false;
}


private imported!"dmd.func".FuncDeclaration vtblFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    if (base.vtblIndex < 0)
        return null;

    const index = cast(size_t) base.vtblIndex;
    if (index >= class_.vtbl.length)
        return null;

    return class_.vtbl[index].isFuncDeclaration;
}


private imported!"dmd.func".FuncDeclaration matchingMemberFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (current; classHierarchy(class_))
        if (current.members !is null)
            foreach (member; *current.members)
                if (auto function_ = member.isFuncDeclaration)
                    if (sameFunctionSignature(function_, base))
                        return function_;

    return null;
}


private bool sameFunctionSignature(
    imported!"dmd.func".FuncDeclaration candidate,
    imported!"dmd.func".FuncDeclaration base,
) {
    if (functionName(candidate) != functionName(base))
        return false;

    if (
        candidate.type !is null &&
        base.type !is null &&
        candidate.type.equals(base.type)
    )
        return true;

    if (candidate.parameters is null || base.parameters is null)
        return candidate.parameters is base.parameters;

    if (candidate.parameters.length != base.parameters.length)
        return false;

    foreach (index, parameter; *candidate.parameters) {
        auto baseParameter = (*base.parameters)[index];
        if (parameter.type is null || baseParameter.type is null)
            return false;
        if (!parameter.type.equals(baseParameter.type))
            return false;
    }

    return true;
}


private imported!"dmd.dclass".ClassDeclaration[] classHierarchy(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    imported!"dmd.dclass".ClassDeclaration[] classes;
    for (auto current = class_; current !is null; current = current.baseClass)
        classes ~= current;
    return classes;
}


private imported!"dmd.dclass".ClassDeclaration classDeclarationByNameInScope(
    imported!"dmd.dsymbol".ScopeDsymbol scope_,
    in string name,
) {
    import dmd.dsymbol: foreachDsymbol;

    imported!"dmd.dclass".ClassDeclaration found;
    foreachDsymbol(scope_.members, (symbol) {
        if (auto class_ = symbol.isClassDeclaration) {
            if (className(class_) == name || classInfoName(class_) == name) {
                found = class_;
                return 1;
            }
        }

        if (auto nested = symbol.isScopeDsymbol)
            if (auto class_ = classDeclarationByNameInScope(nested, name)) {
                found = class_;
                return 1;
            }

        return 0;
    });

    return found;
}


private string[] classTypeNames(imported!"dmd.dclass".ClassDeclaration class_) {
    string[] names;
    foreach (current; classHierarchy(class_)) {
        names ~= className(current);
        foreach (interface_; current.interfaces)
            appendInterfaceTypeNames(names, interface_.sym);
    }

    return names;
}


private void appendInterfaceTypeNames(
    ref string[] names,
    imported!"dmd.dclass".ClassDeclaration interface_,
) {
    if (interface_ is null)
        return;

    names ~= className(interface_);
    foreach (base; interface_.interfaces)
        appendInterfaceTypeNames(names, base.sym);
}


private string className(imported!"dmd.dclass".ClassDeclaration class_) @safe {
    return class_.ident is null ? "" : class_.ident.toString.idup;
}


private string typeInfoName(imported!"dmd.mtype".Type type) {
    if (type is null)
        return "";

    auto classType = type.toBasetype.isTypeClass;
    if (classType !is null && classType.sym !is null)
        return classInfoName(classType.sym);

    return typeChars(type);
}


private imported!"dmd.mtype".Type typeidObjectType(
    imported!"dmd.expression".TypeidExp typeid_,
) {
    if (auto type = cast(imported!"dmd.mtype".Type) typeid_.obj)
        return type;

    if (auto expression = cast(imported!"dmd.expression".Expression) typeid_.obj)
        return expression.type;

    return null;
}


private imported!"dmd.mtype".Type symbolOffsetTypeInfoType(
    imported!"dmd.expression".SymOffExp symbol,
) {
    auto typeInfo = symbol.var.isTypeInfoDeclaration;
    return typeInfo is null ? null : typeInfo.tinfo;
}


// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string classInfoName(imported!"dmd.dclass".ClassDeclaration class_) @trusted {
    import std.string: fromStringz;

    return class_.toPrettyChars.fromStringz.idup;
}


private string variableName(
    imported!"dmd.declaration".VarDeclaration variable,
) @safe {
    return variable.ident is null ? "" : variable.ident.toString.idup;
}


private string structLiteralName(
    imported!"dmd.expression".StructLiteralExp literal,
) @safe {
    return literal.sd is null ? "" : literal.sd.ident.toString.idup;
}


private imported!"dmd.declaration".VarDeclaration structLiteralField(
    imported!"dmd.expression".StructLiteralExp literal,
    in size_t index,
) @safe {
    if (literal.sd is null || index >= literal.sd.fields.length)
        return null;

    return literal.sd.fields[index];
}


// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string expressionChars(imported!"dmd.expression".Expression expression) @trusted {
    import std.string: fromStringz;

    return expression.toChars.fromStringz.idup;
}

// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return type.toChars.fromStringz.idup;
}

// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string for the lifetime of the DMD function declaration.
private string functionName(imported!"dmd.func".FuncDeclaration function_) @trusted {
    import std.string: fromStringz;

    return function_.toChars.fromStringz.idup;
}


private struct SliceAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t lower;
}


private struct StructArrayFieldAliases {
    public imported!"dmd.declaration".VarDeclaration[size_t] sources;
}


private struct AssocArraySlotAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public imported!"quickbite.lang".Value key;
}


private struct RuntimeDelegate {
    public imported!"dmd.func".FuncDeclaration function_;
    public size_t functionPointerId;
    public imported!"quickbite.lang".Value contextPointer;
    public imported!"quickbite.lang".Value receiver;
    public bool hasReceiver;
}


private bool isMemberFunction(imported!"dmd.func".FuncDeclaration function_) {
    if (function_ is null || function_.parent is null)
        return false;

    return
        function_.parent.isStructDeclaration !is null ||
        function_.parent.isClassDeclaration !is null;
}


private string declarationName(
    imported!"dmd.declaration".Declaration declaration,
) @safe {
    return declaration.ident is null ? "" : declaration.ident.toString.idup;
}


private void log(A...)(auto ref A args) {
    version(unittest) {
        import unit_threaded;
        writelnUt(args);
    }
}

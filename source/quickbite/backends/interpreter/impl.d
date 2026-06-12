module quickbite.backends.interpreter.impl;


private:


public class Interpreter: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.backends.runner: ExecutionMode;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    public alias eval = Evaluator.eval;

    public this(in ExecutionMode mode = ExecutionMode.runtime) @safe @nogc nothrow pure {
        super(mode);
    }

    public override EvalResult eval(FuncDeclaration function_) {
        Walker walker;
        try
            walker.runStatement(function_.fbody);
        catch (Exception exception)
            return EvalResult(EvalResult.Diagnostic(exception.msg));
        return EvalResult(walker.result);
    }
}

private bool isTransparentArrayCastTarget(imported!"dmd.mtype".Type type) {
    import quickbite.frontend.dmd.types: isArrayType;

    return isArrayType(type);
}

private struct Walker {
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import quickbite.frontend.dmd.values: defaultValue;
    import quickbite.lang: Value;

    private Value[VarDeclaration] locals;
    private bool[VarDeclaration] uninitializedLocals;
    private SliceAlias[VarDeclaration] sliceAliases;
    private AssocArraySlotAlias[VarDeclaration] assocArraySlotAliases;
    private size_t[VarDeclaration] arrayAllocations;
    private size_t allocationCount;
    private Value result;
    private bool runningCalledFunction;
    private FuncDeclaration currentFunction;
    private Value thisValue;
    private bool hasThis;
    private bool returned;

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null || returned)
            return;

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            if (unrolled.statements !is null)
                foreach (child; *unrolled.statements)
                    runStatement(child);
            return;
        }

        if (statement.isImportStatement !is null)
            return;

        if (auto expression = statement.isExpStatement) {
            result = runExpression(expression.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            if (return_.exp !is null)
                result = runExpression(return_.exp);
            returned = true;
            return;
        }

        if (auto for_ = statement.isForStatement) {
            import quickbite.backends.interpreter.messages: isTruthy;

            runStatement(for_._init);
            while (
                !returned &&
                (for_.condition is null || isTruthy(runExpression(for_.condition)))
            ) {
                runStatement(for_._body);
                if (returned)
                    break;
                if (for_.increment !is null)
                    runExpression(for_.increment);
            }
            return;
        }

        if (auto do_ = statement.isDoStatement) {
            import quickbite.backends.interpreter.messages: isTruthy;

            do {
                runStatement(do_._body);
                if (returned)
                    break;
            } while (isTruthy(runExpression(do_.condition)));
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

        if (auto for_ = statement.isForStatement) {
            runForStatement(for_);
            return;
        }

        if (auto throw_ = statement.isThrowStatement) {
            import quickbite.backends.interpreter.messages: thrownExceptionMessage;

            throw new Exception(thrownExceptionMessage(throw_.exp));
        }

        import std.conv: text;
        throw new Exception(text("Unsupported eval statement: ", statement.stmt));
    }

    // DMD lowers `foreach` over arrays to a `for` loop; `break` and
    // `continue` are not supported
    private void runForStatement(imported!"dmd.statement".ForStatement for_) {
        import quickbite.backends.interpreter.messages: isTruthy;

        runStatement(for_._init);

        while (for_.condition is null || isTruthy(runExpression(for_.condition))) {
            runStatement(for_._body);
            if (for_.increment !is null)
                runExpression(for_.increment);
        }
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.values: integerValue, realValue;

        if (auto integer = expression.isIntegerExp) {
            if (integer.type !is null && integer.type.ty == TY.Tenum)
                return Value.enumValue(expressionChars(integer));
            return integerValue(integer);
        }

        if (auto real_ = expression.isRealExp)
            return realValue(real_);

        if (expression.isNullExp !is null)
            return Value.null_;

        if (auto string_ = expression.isStringExp)
            return stringValue(string_);

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
                    assertFailureMessage(assert_, runningCalledFunction, &runExpression),
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
            return runExpression(div.e1) / runExpression(div.e2);

        if (auto mod = expression.isModExp)
            return runExpression(mod.e1) % runExpression(mod.e2);

        if (auto neg = expression.isNegExp)
            return -runExpression(neg.e1);

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

        if (auto bitOr = expression.isOrExp)
            return runBitwiseOrExpression(bitOr);

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1);
            return runExpression(comma.e2);
        }

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

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

        if (auto pointer = expression.isPtrExp)
            return runExpression(pointer.e1).pointerTarget;

        if (auto address = expression.isAddrExp)
            return runAddressExpression(address);

        if (auto dot = expression.isDotVarExp)
            return runDotVarExpression(dot);

        if (expression.isThisExp !is null) {
            if (!hasThis)
                throw new Exception("Unsupported eval expression: this");
            return thisValue;
        }

        if (auto typeid_ = expression.isTypeidExp)
            return runTypeidExpression(typeid_);

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

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins:
                AssocArrayHook, tryAssocArrayHook;

            AssocArrayHook assocArrayHook;
            if (tryAssocArrayHook(call.f, assocArrayHook))
                return runAssocArrayHookCall(call, assocArrayHook);
        }

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

                if (hasNoAvailableSource(call.f))
                    throw new Exception(noAvailableSourceMessage(call.f));
                return runMemberFunction(
                    call.f,
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

        throw new Exception("Unsupported eval call.");
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

    private Value runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.bindFunctionParameters(function_, arguments);

        child.runStatement(function_.fbody);
        writeBackRefArguments(function_, argumentExpressions, child);
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
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindFunctionParameters(function_, arguments);

        child.runStatement(function_.fbody);
        writeBackRefArguments(function_, argumentExpressions, child);
        writeBackThis(receiverExpression, child.thisValue);

        if (function_.isCtorDeclaration !is null)
            return child.thisValue;

        return child.result;
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

    private Value runEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;

        const left = runExpression(equal.e1);
        const right = runExpression(equal.e2);
        if (equal.op == EXP.notEqual)
            return Value(left != right);
        return Value(left == right);
    }

    private Value runBitwiseOrExpression(imported!"dmd.expression".OrExp bitOr) {
        const left = runExpression(bitOr.e1).asLong;
        const right = runExpression(bitOr.e2).asLong;
        return Value(cast(int) (left | right));
    }

    private Value runDotVarExpression(imported!"dmd.expression".DotVarExp dot) {
        import quickbite.backends.interpreter.messages: receiverName;
        import std.conv: text;

        const receiver = runExpression(dot.e1);
        if (receiver == Value.null_)
            throw new Exception(text(
                "class `",
                receiverName(dot.e1),
                "` is `null` and cannot be dereferenced",
            ));

        if (dot.var.isVarDeclaration !is null)
            return receiver.structFieldAt(structFieldIndex(dot));

        throw new Exception("Unsupported interpreter field read.");
    }

    private Value runTypeidExpression(
        imported!"dmd.expression".TypeidExp typeid_,
    ) {
        import dmd.dtemplate: isExpression;
        import quickbite.backends.interpreter.messages: isClassExpression, receiverName;
        import std.conv: text;

        auto expression = isExpression(typeid_.obj);
        if (expression is null)
            throw new Exception("Unsupported interpreter typeid expression.");

        const value = runExpression(expression);
        if (value == Value.null_ || (isClassExpression(expression) &&
            value == Value(false)))
            throw new Exception(text(
                "null pointer dereference evaluating typeid. `",
                receiverName(expression),
                "` is `null`",
            ));

        throw new Exception("Unsupported interpreter typeid expression.");
    }

    private Value runAssignExpression(imported!"dmd.expression".BinExp assign) {
        if (auto pointer = assign.e1.isPtrExp)
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
        if (auto var = target.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported interpreter assignment target.");

            locals[variable] = value;
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            return;
        }

        if (target.isThisExp !is null && hasThis) {
            thisValue = value;
            return;
        }

        if (auto dot = target.isDotVarExp) {
            writeLocation(
                dot.e1,
                runExpression(dot.e1).withStructField(structFieldIndex(dot), value),
            );
            return;
        }

        import std.conv: text;
        throw new Exception(
            text("Unsupported interpreter assignment target: ", target.op),
        );
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

    private Value runIndexAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        if (isPointerType(index.e1.type))
            return runAssocArraySlotAssignExpression(index.e1, rhs);

        if (auto outer = index.e1.isIndexExp)
            return runNestedIndexAssignExpression(outer, index, rhs);

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
        if (source is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const value = runExpression(rhs);
        locals[alias_.source] = source.withAssocArrayEntry(alias_.key, value);
        return value;
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

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;
        import quickbite.frontend.dmd.types: isPointerType;

        auto type = cast_.to.toBasetype;
        if (type is null)
            return runExpression(cast_.e1);

        if (isTransparentArrayCastTarget(type))
            return runExpression(cast_.e1);

        if (isPointerType(type))
            return pointerCastValue(cast_);

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
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

    private Value stringValue(imported!"dmd.expression".StringExp string_) {
        import quickbite.backends.interpreter.messages: stringChars;

        return Value.stringValue(stringChars(string_));
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
            foreach (element; *literal.elements)
                fields ~= element is null ? Value.void_ : runExpression(element);

        return Value.structValue(structLiteralName(literal), fields);
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

            return source.pointerSlice(
                lower,
                cast(size_t) runExpression(slice.upr).asLong,
            );
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
        import quickbite.frontend.dmd.types: isArrayType, isPointerType;

        const source = runExpression(index.e1);
        if (index.lengthVar !is null)
            locals[index.lengthVar] = Value(source.length);

        // matches CTFE, which formats the index as unsigned
        const arrayIndex = cast(size_t) cast(ulong) runExpression(index.e2).asLong;

        // covers both array-backed pointers and druntime hook results such
        // as `_d_aaGetRvalueX` slot pointers, which DMD dereferences with a
        // zero index
        if (isPointerType(index.e1.type))
            return source.pointerIndex(arrayIndex);

        if (isArrayType(index.e1.type) && arrayIndex >= source.length) {
            import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;

            throw new Exception(indexOutOfBoundsMessage(
                arrayIndex,
                source.length,
                isSliceValue(index.e1),
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

    private Value runNewExpression(imported!"dmd.expression".NewExp new_) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;
        import std.conv: text;

        if (
            !isDynamicArrayType(new_.type) ||
            new_.placement !is null ||
            new_.thisexp !is null ||
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
            const value = defaultValue(variable);
            locals[variable] = value;
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
            if (isStaticArrayType(variable.type) && blit.e1.isSliceExp !is null) {
                const value = defaultValue(variable);
                locals[variable] = value;
                uninitializedLocals.remove(variable);
                sliceAliases.remove(variable);
                return value;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                const value = defaultValue(variable);
                locals[variable] = value;
                uninitializedLocals.remove(variable);
                sliceAliases.remove(variable);
                return value;
            }

            initializer = blit.e2;
        }

        if (initializer.isVoidInitExp !is null) {
            uninitializedLocals[variable] = true;
            return Value.void_;
        }

        import quickbite.frontend.dmd.types: isDynamicArrayType;

        if (initializer.isNullExp !is null && isDynamicArrayType(variable.type)) {
            auto value = Value.arrayValue([]);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            return value;
        }

        if (auto slice = initializer.isSliceExp) {
            size_t lower;
            auto value = runSliceExpression(slice, lower);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            recordSliceAlias(variable, slice, lower);
            return value;
        }

        auto value = runExpression(initializer);
        locals[variable] = value;
        uninitializedLocals.remove(variable);
        sliceAliases.remove(variable);
        recordAssocArraySlotAlias(variable, initializer);
        return value;
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

        if (post.op != EXP.plusPlus)
            throw new Exception("Unsupported eval post expression.");

        auto var = post.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported eval post expression target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported eval post expression target.");

        auto current = variable in locals;
        const oldValue = current is null ? defaultValue(variable) : *current;
        locals[variable] = oldValue + Value(cast(int) 1);
        return oldValue;
    }

    private Value runAddAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        const value = runExpression(assign.e1) + runExpression(assign.e2);
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


private string structLiteralName(
    imported!"dmd.expression".StructLiteralExp literal,
) @safe {
    return literal.sd is null ? "" : literal.sd.ident.toString.idup;
}


// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string expressionChars(imported!"dmd.expression".Expression expression) @trusted {
    import std.string: fromStringz;

    return expression.toChars.fromStringz.idup;
}


private struct SliceAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t lower;
}


private struct AssocArraySlotAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public imported!"quickbite.lang".Value key;
}


private void log(A...)(auto ref A args) {
    version(unittest) {
        import unit_threaded;
        writelnUt(args);
    }
}

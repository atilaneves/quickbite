module quickbite.backends.tree_walking;

private:

// SumType.opAssign is @system in this version of std.sumtype, so all code
// that stores a Value is @system by transitivity.
alias Value = imported!"std.sumtype".SumType!(long, long[]);

private struct FunctionResult {
    private bool hasValue;
    private Value value;
    private Value[] refValues;
    private Value[imported!"dmd.declaration".VarDeclaration] thisFields;
}

private struct CallArgument {
    private Value value;
    private imported!"dmd.declaration".VarDeclaration refSource;
    private imported!"dmd.declaration".VarDeclaration refOwner;
    private imported!"dmd.declaration".VarDeclaration refField;
}

public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler;

        // Keep `parsed` mutable: the DMD frontend owns mutable Module state.
        auto parsed = quickbite.frontend.compiler.parseModule(source);
        walkModule(parsed.module_);
    }
}

private void walkModule(imported!"dmd.dmodule".Module module_) {
    if (module_.members is null)
        return;

    Interpreter interpreter;
    foreach (member; moduleMembers(module_)) {
        if (auto unitTest = member.isUnitTestDeclaration)
            interpreter.runTest(unitTest);
    }
}

private struct Interpreter {
    private FunctionResult executeFunction(
        imported!"dmd.func".FuncDeclaration func,
        CallArgument[] args = [],
        Value[imported!"dmd.declaration".VarDeclaration] thisFields = null,
    ) {
        if (func.fbody is null)
            throw new Exception("No function body to execute.");
        BodyWalker w;
        if (func.vthis !is null)
            w.structFields[func.vthis] = thisFields;
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
            );
        return FunctionResult(
            true,
            w.returnValue,
            collectRefValues(func, w),
            collectThisFields(func, w),
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

            if ((param.storage_class & STC.ref_) != STC.none)
                refValues ~= walker.locals[param];
        }
        return refValues;
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
    private bool hasReturn;
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
            if ((param.storage_class & (STC.out_ | STC.lazy_)) != STC.none)
                throw new Exception("Unsupported parameter storage class.");
            if ((param.storage_class & STC.ref_) != STC.none &&
                args[i].refSource is null &&
                args[i].refField is null)
                throw new Exception("Unsupported ref argument.");
            locals[param] = args[i].value;
        }
    }

    private void runStatement(
        imported!"dmd.statement".Statement statement,
        ref Interpreter interpreter,
    ) {
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
                    if (hasReturn)
                        return;
                }
            return;
        }

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; compoundStatements(compound)) {
                    runStatement(child, interpreter);
                    if (hasReturn)
                        return;
                }
            return;
        }

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

        if (auto ret = statement.isReturnStatement) {
            if (ret.exp !is null)
                returnValue = runExpression(ret.exp, interpreter);
            hasReturn = true;
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

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1, interpreter, true);
            return runExpression(comma.e2, interpreter, resultIgnored);
        }

        if (auto call = expression.isCallExp)
            return runCallExpression(call, interpreter, resultIgnored);

        if (auto equal = expression.isEqualExp)
            return runEqualExpression(equal, interpreter);

        if (auto assert_ = expression.isAssertExp) {
            const cond = runExpression(assert_.e1, interpreter).asLong;
            if (!cond)
                throw new Exception("Unittest assertion failed.");
            return Value(cond);
        }

        if (auto decl = expression.isDeclarationExp)
            return runDeclarationExpression(decl, interpreter);

        if (auto dotVar = expression.isDotVarExp) {
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto fields = ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            return (*fields).get(fieldDecl, Value(0L));
            if (auto thisExp = dotVar.e1.isThisExp)
                if (auto thisDecl = thisExp.var.isVarDeclaration)
                    if (auto fields = thisDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            return (*fields).get(fieldDecl, Value(0L));
            unsupported;
        }

        if (isComparisonExpression(expression))
            return runComparisonExpression(expression, interpreter);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign, interpreter);

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
                                    const oldVal = (*fields)
                                        .get(fieldDecl, Value(0L))
                                        .asLong;
                                    (*fields)[fieldDecl] = Value(
                                        coerceIntegerToType(
                                            oldVal + 1,
                                            fieldDecl.type,
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

        if (auto rightShift = expression.isShrExp)
            return Value(
                runExpression(rightShift.e1, interpreter).asLong >>
                runExpression(rightShift.e2, interpreter).asLong,
            );

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

        if (auto divide = expression.isDivExp) {
            const right = runExpression(divide.e2, interpreter).asLong;
            if (right == 0)
                throw new Exception("Division by zero.");
            return Value(runExpression(divide.e1, interpreter).asLong / right);
        }

        if (auto modulo = expression.isModExp) {
            const right = runExpression(modulo.e2, interpreter).asLong;
            if (right == 0)
                throw new Exception("Division by zero.");
            return Value(runExpression(modulo.e1, interpreter).asLong % right);
        }

        if (auto cast_ = expression.isCastExp)
            return coerceValueToType(runExpression(cast_.e1, interpreter), cast_.to);

        if (auto literal = expression.isArrayLiteralExp) {
            long[] elements;
            if (literal.elements !is null)
                foreach (elem; arrayLiteralElements(literal))
                    elements ~= runExpression(elem, interpreter).asLong;
            return Value(elements);
        }

        if (auto slice = expression.isSliceExp) {
            if (slice.lwr !is null && slice.upr !is null) {
                const array = runExpression(slice.e1, interpreter).asArray;
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
                                    return (*fields)
                                        .get(fieldDecl, Value((long[]).init));
            unsupported;
        }

        if (auto index = expression.isIndexExp) {
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
                                    (*fields)[fieldDecl].asArray[cast(size_t) i],
                                );
                            }
            if (auto dotVar = index.e1.isDotVarExp)
                if (auto thisExp = dotVar.e1.isThisExp)
                    if (auto thisDecl = thisExp.var.isVarDeclaration)
                        if (auto fields = thisDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const i = runExpression(index.e2, interpreter).asLong;
                                return Value(
                                    (*fields)[fieldDecl].asArray[cast(size_t) i],
                                );
                            }
            unsupported;
        }

        if (auto len = expression.isArrayLengthExp) {
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
                                    cast(long) (*fields)
                                        .get(fieldDecl, Value((long[]).init))
                                        .asArray
                                        .length,
                                );
            unsupported;
        }

        if (auto var = expression.isVarExp) {
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in locals)
                    return locals[varDecl];
        }

        unsupported;
        assert(false);
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

        if (auto dotVar = append.e1.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto fields = ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            // Explicit type: `elements` must be mutable for append.
                            long[] elements = (*fields)
                                .get(fieldDecl, Value((long[]).init))
                                .asArray;
                            elements ~= coerceIntegerToType(
                                runExpression(append.e2, interpreter).asLong,
                                arrayElementType(fieldDecl.type),
                            );
                            structFields[ownerDecl][fieldDecl] = Value(elements);
                            return structFields[ownerDecl][fieldDecl];
                        }
        if (auto dotVar = append.e1.isDotVarExp)
            if (auto thisExp = dotVar.e1.isThisExp)
                if (auto thisDecl = thisExp.var.isVarDeclaration)
                    if (auto fields = thisDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            // Explicit type: `elements` must be mutable for append.
                            long[] elements = (*fields)
                                .get(fieldDecl, Value((long[]).init))
                                .asArray;
                            elements ~= coerceIntegerToType(
                                runExpression(append.e2, interpreter).asLong,
                                arrayElementType(fieldDecl.type),
                            );
                            structFields[thisDecl][fieldDecl] = Value(elements);
                            return structFields[thisDecl][fieldDecl];
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

        if (call.f is null) {
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

        if (call.f.fbody is null)
            throw new Exception("No function body to execute.");

        CallArgument[] args;
        if (call.arguments !is null)
            foreach (i, arg; callArguments(call)) {
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
                                        args ~= CallArgument(
                                            (*fields)
                                                .get(fieldDecl, Value((long[]).init)),
                                            null,
                                            ownerDecl,
                                            fieldDecl,
                                        );
                                        continue;
                                    }
                    if (auto dotVar = arg.isDotVarExp)
                        if (auto thisExp = dotVar.e1.isThisExp)
                            if (auto thisDecl = thisExp.var.isVarDeclaration)
                                if (auto fields = thisDecl in structFields)
                                    if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                        args ~= CallArgument(
                                            (*fields)
                                                .get(fieldDecl, Value((long[]).init)),
                                            null,
                                            thisDecl,
                                            fieldDecl,
                                        );
                                        continue;
                                    }
                    throw new Exception("Unsupported ref argument.");
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
        if (auto dotVar = call.e1.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto fields = ownerDecl in structFields) {
                        thisFields = *fields;
                        thisOwner = ownerDecl;
                    }

        // `auto` is intentional: `const` would block ref propagation.
        auto result = interpreter.executeFunction(call.f, args, thisFields);
        propagateRefArguments(call, args, result.refValues);
        if (thisOwner !is null)
            structFields[thisOwner] = result.thisFields;
        if (!result.hasValue) {
            if (resultIgnored)
                return Value(0L);
            throw new Exception("Void function result used as value.");
        }
        return result.value;
    }

    private void propagateRefArguments(
        imported!"dmd.expression".CallExp call,
        CallArgument[] args,
        Value[] refValues,
    ) {
        if (call.f.parameters is null)
            return;

        size_t refIndex;
        foreach (i, param; functionParameters(call.f)) {
            import dmd.astenums: STC;

            if ((param.storage_class & STC.ref_) == STC.none)
                continue;
            if (args[i].refSource !is null)
                locals[args[i].refSource] = refValues[refIndex];
            else
                structFields[args[i].refOwner][args[i].refField] =
                    refValues[refIndex];
            refIndex = refIndex + 1;
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

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp decl,
        ref Interpreter interpreter,
    ) {
        import std.conv: text;

        const unsupportedMessage = text("Unsupported expression: ", decl.op);

        void unsupportedDecl() {
            throw new Exception(unsupportedMessage);
        }

        if (decl.declaration.isAliasDeclaration !is null)
            return Value(0L);

        auto variable = decl.declaration.isVarDeclaration;
        if (variable is null)
            unsupportedDecl;

        if (variable.type !is null && variable.type.isTypeStruct !is null) {
            structFields[variable] = (Value[VarDeclaration]).init;
            return Value(0L);
        }

        if (variable.type !is null && variable.type.isTypeDArray !is null)
            return initializeArrayVariable(variable, interpreter, unsupportedMessage);

        if (variable._init is null)
            unsupportedDecl;
        auto initializer = variable._init.isExpInitializer;
        if (initializer is null)
            unsupportedDecl;
        if (initializer.exp.isAssignExp || initializer.exp.isBlitExp)
            unsupportedDecl;
        auto construct = initializer.exp.isConstructExp;
        Value value = construct !is null
            ? coerceValueToType(runExpression(construct.e2, interpreter), variable.type)
            : coerceValueToType(runExpression(initializer.exp, interpreter), variable.type);
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
            return Value(left <= right ? 1L : 0L);
        return Value(left >= right ? 1L : 0L);
    }

    private Value runAssignExpression(
        imported!"dmd.expression".AssignExp assign,
        ref Interpreter interpreter,
    ) {
        const value = runExpression(assign.e2, interpreter);

        if (auto var = assign.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in locals) {
                    locals[varDecl] = coerceValueToType(value, varDecl.type);
                    return value;
                }

        if (auto dotVar = assign.e1.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            structFields[ownerDecl][fieldDecl] =
                                coerceValueToType(value, fieldDecl.type);
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
                                (*fields)[fieldDecl].asArray[cast(size_t) i] =
                                    coerceIntegerToType(
                                        value.asLong,
                                        arrayElementType(fieldDecl.type),
                                    );
                                return value;
                            }
            if (auto dotVar = index.e1.isDotVarExp)
                if (auto thisExp = dotVar.e1.isThisExp)
                    if (auto thisDecl = thisExp.var.isVarDeclaration)
                        if (auto fields = thisDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                const i = runExpression(index.e2, interpreter).asLong;
                                (*fields)[fieldDecl].asArray[cast(size_t) i] =
                                    coerceIntegerToType(
                                        value.asLong,
                                        arrayElementType(fieldDecl.type),
                                    );
                                return value;
                            }
        }

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expressionChars(assign)));
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
    );
}

private Value coerceValueToType(
    Value value,
    imported!"dmd.mtype".Type type,
) @safe {
    import std.sumtype: match;

    if (type is null)
        return value;

    return value.match!(
        (long l) => Value(coerceIntegerToType(l, type)),
        (long[] a) => Value(a),
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

private imported!"dmd.mtype".Type arrayElementType(
    imported!"dmd.mtype".Type type,
) @trusted {
    if (type is null)
        return null;

    return type.toBasetype.nextOf;
}

private ref auto moduleMembers(
    imported!"dmd.dmodule".Module module_,
) @trusted pure {
    return *module_.members;
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

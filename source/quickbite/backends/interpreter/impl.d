module quickbite.backends.interpreter.impl;


private:


public class Interpreter: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.cell: EvalCell;
    import quickbite.backends:
        TestCaseResult,
        TestOutcome,
        TestRunResult,
        TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        import quickbite.frontend.cell: parseEvalSource;

        return evalFunction(parseEvalSource(expr).function_);
    }

    public override Value evalRepl(EvalCell cell) {
        import quickbite.frontend.cell: EvalCellKind;

        final switch (cell.kind) with (EvalCellKind) {
            case incomplete:
                throw new Exception(
                    "Incomplete REPL cell reached Interpreter backend.",
                );
            case noDisplay:
                evalFunction(cell.function_, true);
                return Value.void_;
            case expression:
                return evalFunction(cell.function_, true);
        }
    }

    public override void runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        Evaluator evaluator;
        evaluator.allowZeroArgumentCalls = true;
        evaluator.allowControlFlow = true;
        foreachUnitTestDeclaration(module_, (unitTest) {
            evaluator.runTest(unitTest);
        });
    }

    public override TestRunResult runTestResults(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestRunResult result;
        Evaluator evaluator;
        evaluator.allowZeroArgumentCalls = true;
        evaluator.allowControlFlow = true;
        foreachUnitTestDeclaration(module_, (unitTest) {
            ++result.summary.total;
            try {
                evaluator.runTest(unitTest);
                ++result.summary.passed;
                result.cases ~= TestCaseResult(
                    TestOutcome.passed,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    null,
                );
            } catch (Exception e) {
                ++result.summary.failed;
                result.cases ~= TestCaseResult(
                    TestOutcome.failed,
                    symbolName(unitTest),
                    locChars(unitTest.loc),
                    e.msg,
                );
            }
        });
        return result;
    }

    public override TestSummary runTestSummary(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestSummary summary;
        Evaluator evaluator;
        evaluator.allowZeroArgumentCalls = true;
        evaluator.allowControlFlow = true;
        foreachUnitTestDeclaration(module_, (unitTest) {
            ++summary.total;
            try {
                evaluator.runTest(unitTest);
                ++summary.passed;
            } catch (Exception) {
                ++summary.failed;
            }
        });
        return summary;
    }

}

private string symbolName(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) @trusted {
    import std.string: fromStringz;

    // `ident.toChars` returns DMD-owned null-terminated storage; `idup`
    // immediately copies it into a D string.
    return unitTest.ident.toChars.fromStringz.idup;
}

private string locChars(imported!"dmd.location".Loc loc) @trusted {
    import std.string: fromStringz;

    // `loc.toChars` returns DMD-owned null-terminated storage; `idup`
    // immediately copies it into a D string.
    return loc.toChars.fromStringz.idup;
}

private bool hasNoAvailableSource(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.fbody is null;
}

private bool isTransparentArrayCastTarget(imported!"dmd.mtype".Type type) {
    import quickbite.frontend.dmd.types: isArrayType;

    return isArrayType(type);
}

private bool typeIsDynamicArray(imported!"dmd.mtype".Type type) {
    return type !is null && type.toBasetype.isTypeDArray !is null;
}

private imported!"quickbite.lang".Value evalFunction(
    imported!"dmd.func".FuncDeclaration function_,
    bool allowZeroArgumentCalls = false,
) {
    Evaluator evaluator;
    evaluator.allowZeroArgumentCalls = allowZeroArgumentCalls;
    evaluator.allowControlFlow = false;
    evaluator.runStatement(function_.fbody);
    return evaluator.result;
}

private struct Evaluator {
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import quickbite.frontend.dmd.values: defaultValue;
    import quickbite.lang: Value;

    private Value[VarDeclaration] locals;
    private bool[VarDeclaration] uninitializedLocals;
    private SliceAlias[VarDeclaration] sliceAliases;
    private Value result;
    private bool runningCalledFunction;
    private FuncDeclaration currentFunction;
    private bool allowZeroArgumentCalls;
    private bool allowControlFlow;

    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
        log("Running test ", unitTest);
        runStatement(unitTest.fbody);
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null)
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

        if (statement.isImportStatement !is null)
            return;

        if (auto expression = statement.isExpStatement) {
            result = runExpression(expression.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            result = runExpression(return_.exp);
            return;
        }

        if (allowControlFlow) {
            if (auto if_ = statement.isIfStatement) {
                import quickbite.backends.interpreter.messages: isTruthy;

                if (isTruthy(runExpression(if_.condition)))
                    runStatement(if_.ifbody);
                else
                    runStatement(if_.elsebody);
                return;
            }

            if (auto throw_ = statement.isThrowStatement) {
                import quickbite.backends.interpreter.messages: thrownExceptionMessage;

                throw new Exception(thrownExceptionMessage(throw_.exp));
            }
        }

        import std.conv: text;
        throw new Exception(text("Unsupported eval statement: ", statement.stmt));
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.values: integerValue, realValue;

        if (auto integer = expression.isIntegerExp)
            return integerValue(integer);

        if (auto real_ = expression.isRealExp)
            return realValue(real_);

        if (expression.isNullExp !is null)
            return Value.null_;

        if (auto string_ = expression.isStringExp)
            return stringValue(string_);

        if (auto array = expression.isArrayLiteralExp)
            return arrayValue(array);

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
            return runIncrementAssignExpression(addAssign);

        if (auto add = expression.isAddExp)
            return runExpression(add.e1) + runExpression(add.e2);

        if (auto sub = expression.isMinExp)
            return runExpression(sub.e1) - runExpression(sub.e2);

        if (auto mul = expression.isMulExp)
            return runExpression(mul.e1) * runExpression(mul.e2);

        if (auto neg = expression.isNegExp)
            return -runExpression(neg.e1);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

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
            return runExpression(index.e1)[
                cast(size_t) runExpression(index.e2).asLong
            ];

        if (auto dot = expression.isDotVarExp)
            return runDotVarExpression(dot);

        if (auto typeid_ = expression.isTypeidExp)
            return runTypeidExpression(typeid_);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                assert(0);

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

        const left = runExpression(comparison.e1).asReal;
        const right = runExpression(comparison.e2).asReal;

        if (comparison.op == EXP.lessThan)
            return Value(left < right);
        if (comparison.op == EXP.lessOrEqual)
            return Value(left <= right);
        if (comparison.op == EXP.greaterThan)
            return Value(left > right);
        return Value(left >= right);
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

        const argumentCount = call.arguments is null ? 0 : call.arguments.length;
        if (argumentCount == 0 && !allowZeroArgumentCalls)
            throw new Exception("Unsupported eval call argument count.");

        Value[] arguments;
        VarDeclaration[] argumentVariables;
        if (call.arguments !is null) {
            foreach (argument; *call.arguments) {
                arguments ~= runExpression(argument);
                argumentVariables ~= argumentVariable(argument);
            }
        }

        if (auto dot = call.e1.isDotVarExp)
            if (runExpression(dot.e1) == Value.null_)
                throw new Exception(
                    "function call through null class reference `null`",
                );

        if (call.f !is null) {
            import quickbite.backends.interpreter.messages: noAvailableSourceMessage;

            if (hasNoAvailableSource(call.f))
                throw new Exception(noAvailableSourceMessage(call.f));
            return runFunction(call.f, arguments, argumentVariables);
        }

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return runFunction(function_, arguments, argumentVariables);

        throw new Exception("Unsupported eval call.");
    }

    private Value runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        VarDeclaration[] argumentVariables,
    ) {
        Evaluator child;
        child.allowZeroArgumentCalls = allowZeroArgumentCalls;
        child.allowControlFlow = allowControlFlow;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.bindFunctionParameters(function_, arguments);

        child.runStatement(function_.fbody);
        child.writeBackRefParameters(function_, argumentVariables, locals);
        return child.result;
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

    private void writeBackRefParameters(
        imported!"dmd.func".FuncDeclaration function_,
        VarDeclaration[] argumentVariables,
        ref Value[VarDeclaration] savedLocals,
    ) {
        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (!parameter.isReference)
                continue;

            if (index >= argumentVariables.length)
                continue;

            auto argumentVariable = argumentVariables[index];
            if (argumentVariable is null)
                continue;

            if (auto value = parameter in locals)
                savedLocals[argumentVariable] = *value;
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

        if (runExpression(dot.e1) == Value.null_)
            throw new Exception(text(
                "class `",
                receiverName(dot.e1),
                "` is `null` and cannot be dereferenced",
            ));

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
        if (auto index = assign.e1.isIndexExp)
            return runIndexAssignExpression(index, assign.e2);

        auto var = assign.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const value = runExpression(assign.e2);
        locals[variable] = value;
        uninitializedLocals.remove(variable);
        sliceAliases.remove(variable);
        return value;
    }

    private Value runIndexAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
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

    private VarDeclaration argumentVariable(
        imported!"dmd.expression".Expression argument,
    ) {
        auto var = argument.isVarExp;
        if (var is null)
            return null;

        return var.var.isVarDeclaration;
    }

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        auto type = cast_.to.toBasetype;
        if (type is null)
            return runExpression(cast_.e1);

        if (isTransparentArrayCastTarget(type))
            return runExpression(cast_.e1);

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
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

    private Value runSliceExpression(imported!"dmd.expression".SliceExp slice) {
        size_t lower;
        return runSliceExpression(slice, lower);
    }

    private Value runSliceExpression(
        imported!"dmd.expression".SliceExp slice,
        out size_t lower,
    ) {
        const source = runExpression(slice.e1);
        lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? source.length
            : cast(size_t) runExpression(slice.upr).asLong;

        Value[] values;
        foreach (index; lower .. upper)
            values ~= source[index];

        return Value.arrayValue(values);
    }

    private void recordSliceAlias(
        VarDeclaration variable,
        imported!"dmd.expression".SliceExp slice,
        in size_t lower,
    ) {
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
        else if (auto blit = initializer.isBlitExp)
            initializer = blit.e2;

        if (initializer.isVoidInitExp !is null) {
            uninitializedLocals[variable] = true;
            return Value.void_;
        }

        if (initializer.isNullExp !is null && typeIsDynamicArray(variable.type)) {
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
        return value;
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

    private Value runIncrementAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        auto var = assign.e1.isVarExp;
        if (var is null)
            assert(0);

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            assert(0);

        auto current = variable in locals;
        if (current is null) {
            locals[variable] = defaultValue(variable);
            current = variable in locals;
        }

        *current = *current + Value(cast(int) 1);
        return *current;
    }
}


private struct SliceAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t lower;
}


private void log(A...)(auto ref A args) {
    version(unittest) {
        import unit_threaded;
        writelnUt(args);
    }
}

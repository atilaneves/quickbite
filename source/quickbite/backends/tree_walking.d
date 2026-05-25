module quickbite.backends.tree_walking;

private:

public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    import dmd.declaration: VarDeclaration;
    import dmd.dmodule: Module;
    import quickbite.executor: TestSummary, Value;

    private Value[VarDeclaration] locals;
    private long[VarDeclaration][VarDeclaration] structScalars;
    private long[][VarDeclaration][VarDeclaration] structArrays;
    private VarDeclaration currentThis;
    private bool didReturn;
    private Value returnValue;

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
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            runTest(unitTest);
        });
    }

    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
        locals = null;
        structScalars = null;
        structArrays = null;
        currentThis = null;
        didReturn = false;
        returnValue = Value(0L);
        runStatement(unitTest.fbody);
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null)
            return;

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    runStatement(child);
                    if (didReturn) return;
                }
            return;
        }

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    runStatement(child);
                    if (didReturn) return;
                }
            return;
        }

        if (auto expressionStatement = statement.isExpStatement) {
            runExpression(expressionStatement.exp);
            return;
        }

        if (auto for_ = statement.isForStatement) {
            runForStatement(for_);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            if (return_.exp !is null)
                returnValue = runExpression(return_.exp);
            didReturn = true;
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    private void runForStatement(imported!"dmd.statement".ForStatement for_) {
        if (for_._init !is null)
            runStatement(for_._init);

        while (for_.condition is null || runExpression(for_.condition).asLong) {
            runStatement(for_._body);
            if (didReturn) return;
            if (for_.increment !is null)
                runExpression(for_.increment);
        }
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1);
            return runExpression(comma.e2);
        }

        if (auto integer = expression.isIntegerExp)
            return Value(integer.getInteger);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable !is null) {
                if (variable in locals)
                    return locals[variable];
                else
                    return Value(0L);  // Uninitialized variable defaults to 0
            }
        }

        if (expression.isThisExp !is null)
            return Value(0L);

        if (auto dotVar = expression.isDotVarExp) {
            long[] array;
            if (structArrayExpressionValue(dotVar, array) ||
                thisStructArrayExpressionValue(dotVar, array))
                return Value(array);

            long value;
            if (scalarStructFieldValue(dotVar, value))
                return Value(value);
        }

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct);

        if (auto blit = expression.isBlitExp)
            return runAssignExpression(blit);

        if (auto add = expression.isAddExp)
            return Value(
                runExpression(add.e1).asLong + runExpression(add.e2).asLong,
            );

        if (auto sub = expression.isMinExp)
            return Value(
                runExpression(sub.e1).asLong - runExpression(sub.e2).asLong,
            );

        if (auto mul = expression.isMulExp)
            return Value(
                runExpression(mul.e1).asLong * runExpression(mul.e2).asLong,
            );

        if (auto div = expression.isDivExp)
            return Value(
                runExpression(div.e1).asLong / runExpression(div.e2).asLong,
            );

        if (isRightShiftExpression(expression)) {
            auto binary = expression.isBinExp;
            return Value(
                runExpression(binary.e1).asLong >>
                    runExpression(binary.e2).asLong,
            );
        }

        if (auto addAssign = expression.isAddAssignExp)
            return Value(runCompoundAssignExpression(addAssign, 1));

        if (auto minAssign = expression.isMinAssignExp)
            return Value(runCompoundAssignExpression(minAssign, -1));

        if (auto post = expression.isPostExp)
            if (isPostMutationExpression(post))
                return runPostMutationExpression(post);

        if (auto equal = expression.isEqualExp)
            return Value(runExpression(equal.e1).asLong ==
                runExpression(equal.e2).asLong ? 1L : 0L);

        if (isLessThanExpression(expression)) {
            auto binary = expression.isBinExp;
            return Value(runExpression(binary.e1).asLong <
                runExpression(binary.e2).asLong ? 1L : 0L);
        }

        if (auto assert_ = expression.isAssertExp)
            return Value(runAssertExpression(assert_));

        if (auto cast_ = expression.isCastExp)
            return coerceValueToType(runExpression(cast_.e1), cast_.to);

        if (auto pre = expression.isPreExp)
            if (isPreMutationExpression(pre))
                return Value(runPreMutationExpression(pre));

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

        if (auto catAssign = expression.isCatAssignExp)
            return runCatAssignExpression(catAssign);

        if (auto catElemAssign = expression.isCatElemAssignExp)
            return runCatAssignExpression(catElemAssign);

        if (auto arrayLength = expression.isArrayLengthExp)
            return Value(cast(long) evalArrayExpression(arrayLength.e1).length);

        long[] array;
        if (sliceArrayExpressionValue(expression, array))
            return Value(array);

        if (auto index = expression.isIndexExp)
            return Value(evalArrayExpression(index.e1)[
                asArrayIndex(runExpression(index.e2))
            ]);

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expression.op));
    }

    private long runCompoundAssignExpression(
        imported!"dmd.expression".BinExp assign,
        in long sign,
    ) {
        auto lhs = assign.e1;
        if (auto cast_ = lhs.isCastExp)
            lhs = cast_.e1;
        if (auto var = lhs.isVarExp)
            if (auto variable = var.var.isVarDeclaration) {
                const value = runExpression(assign.e1).asLong
                    + sign * runExpression(assign.e2).asLong;
                locals[variable] = Value(value);
                return value;
            }

        throw new Exception("Unsupported compound assignment.");
    }

    private Value runPostMutationExpression(
        imported!"dmd.expression".PostExp post,
    ) {
        long value;
        if (postMutationThisField(post, value))
            return Value(value);

        auto var = post.e1.isVarExp;
        if (var is null || var.var.isVarDeclaration is null)
            throw new Exception("Unsupported post expression.");

        auto variable = var.var.isVarDeclaration;
        if (currentThis !is null && variable !in locals) {
            const oldValue = structScalarValue(currentThis, variable);
            structScalars[currentThis][variable] = coerceIntegerToType(
                oldValue + mutationStep(post.op),
                variable.type,
            );
            return Value(oldValue);
        }

        const oldValue = runExpression(post.e1).asLong;
        locals[variable] = Value(coerceIntegerToType(
            oldValue + mutationStep(post.op),
            variable.type,
        ));
        return Value(oldValue);
    }

    private bool postMutationThisField(
        imported!"dmd.expression".PostExp post,
        out long oldValue,
    ) {
        auto dotVar = post.e1.isDotVarExp;
        if (dotVar is null)
            return false;

        if (dotVar.e1.isThisExp is null || currentThis is null)
            return false;

        auto field = dotVar.var.isVarDeclaration;
        if (field is null)
            return false;

        oldValue = structScalarValue(currentThis, field);
        structScalars[currentThis][field] = coerceIntegerToType(
            oldValue + mutationStep(post.op),
            field.type,
        );
        return true;
    }

    private bool isPostMutationExpression(
        imported!"dmd.expression".PostExp post,
    ) {
        return mutationStep(post.op) != 0;
    }

    private long runPreMutationExpression(
        imported!"dmd.expression".PreExp pre,
    ) {
        auto var = pre.e1.isVarExp;
        if (var is null || var.var.isVarDeclaration is null)
            throw new Exception("Unsupported pre expression.");

        auto variable = var.var.isVarDeclaration;
        const value = coerceIntegerToType(
            runExpression(pre.e1).asLong + mutationStep(pre.op),
            variable.type,
        );
        locals[variable] = Value(value);
        return value;
    }

    private bool isPreMutationExpression(
        imported!"dmd.expression".PreExp pre,
    ) {
        return mutationStep(pre.op) != 0;
    }

    private long mutationStep(imported!"dmd.tokens".EXP op) {
        import dmd.tokens: EXP;

        if (op == EXP.plusPlus)
            return 1;
        if (op == EXP.minusMinus)
            return -1;
        return 0;
    }

    private bool isLessThanExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        return expression.op == EXP.lessThan;
    }

    private bool isRightShiftExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        return expression.op == EXP.rightShift;
    }

    private long coerceIntegerToType(
        in long value,
        imported!"dmd.mtype".Type type,
    ) {
        import dmd.astenums: TY;

        if (type is null)
            return value;

        switch (type.toBasetype.ty) {
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
            default:
                return value;
        }
    }

    private Value coerceValueToType(
        Value value,
        imported!"dmd.mtype".Type type,
    ) {
        if (value.isLongArray)
            return Value(value.asLongArray);

        return Value(coerceIntegerToType(value.asLong, type));
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(0L);

        if (variable._init is null || variable._init.isExpInitializer is null)
            return Value(0L);

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp)
            initializer = blit.e2;

        if (initializer.isNullExp) {
            locals[variable] = Value((long[]).init);
            return Value(0L);
        }

        if (auto arrayLit = initializer.isArrayLiteralExp) {
            locals[variable] = Value(evalArrayLiteral(arrayLit));
            return Value(0L);
        }

        long[] array;
        if (tryEvalArrayExpression(initializer, array)) {
            locals[variable] = Value(array);
            return Value(0L);
        }

        auto value = runExpression(initializer);
        locals[variable] = value;
        return value;
    }

    private Value runAssignExpression(imported!"dmd.expression".BinExp assign) {
        auto var = assign.e1.isVarExp;
        if (var !is null)
            if (auto variable = var.var.isVarDeclaration) {
                auto value = coerceValueToType(runExpression(assign.e2), variable.type);
                locals[variable] = value;
                return value;
            }

        long value;
        if (assignStructField(assign, value))
            return Value(value);

        throw new Exception("Unsupported assignment.");
    }

    private bool assignStructField(
        imported!"dmd.expression".BinExp assign,
        out long value,
    ) {
        auto dotVar = assign.e1.isDotVarExp;
        if (dotVar is null)
            return false;

        auto field = dotVar.var.isVarDeclaration;
        if (field is null)
            return false;

        if (dotVar.e1.isThisExp !is null && currentThis !is null) {
            long[] array;
            if (tryEvalArrayExpression(assign.e2, array)) {
                structArrays[currentThis][field] = array;
                value = 0;
                return true;
            }

            const rhs = runExpression(assign.e2);
            if (tryGetArray(rhs, array)) {
                structArrays[currentThis][field] = array;
                value = 0;
                return true;
            }

            value = rhs.asLong;
            structScalars[currentThis][field] = value;
            return true;
        }

        auto instance = dotVar.e1.isVarExp;
        if (instance is null)
            return false;

        auto instanceDecl = instance.var.isVarDeclaration;
        if (instanceDecl is null)
            return false;

        if (auto arrayLit = assign.e2.isArrayLiteralExp) {
            structArrays[instanceDecl][field] = evalArrayLiteral(arrayLit);
            value = 0;
            return true;
        }

        long[] array;
        if (tryEvalArrayExpression(assign.e2, array)) {
            structArrays[instanceDecl][field] = array;
            value = 0;
            return true;
        }

        const rhs = runExpression(assign.e2);
        if (tryGetArray(rhs, array)) {
            structArrays[instanceDecl][field] = array;
            value = 0;
            return true;
        }

        value = rhs.asLong;
        structScalars[instanceDecl][field] = value;
        return true;
    }

    private long[] evalArrayLiteral(
        imported!"dmd.expression".ArrayLiteralExp arrayLit,
    ) {
        long[] elements;
        if (arrayLit.elements !is null)
            foreach (elem; *arrayLit.elements)
                elements ~= runExpression(elem).asLong;
        return elements;
    }

    private bool scalarStructFieldValue(
        imported!"dmd.expression".DotVarExp dotVar,
        out long value,
    ) {
        if (auto instance = dotVar.e1.isVarExp)
            if (auto instanceDecl = instance.var.isVarDeclaration)
                if (auto entry = instanceDecl in structScalars)
                    if (auto field = dotVar.var.isVarDeclaration)
                        if (auto found = field in *entry) {
                            value = *found;
                            return true;
                        }

        return false;
    }

    private long structScalarValue(
        imported!"dmd.declaration".VarDeclaration instance,
        imported!"dmd.declaration".VarDeclaration field,
    ) {
        if (auto entry = instance in structScalars)
            if (auto value = field in *entry)
                return *value;

        return 0;
    }

    private Value runCallExpression(imported!"dmd.expression".CallExp call) {
        if (auto funcVar = call.e1.isVarExp)
            if (auto func = funcVar.var.isFuncDeclaration)
                return runFreeFunctionCall(func, call.arguments);

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null) {
            import std.conv: text;
            throw new Exception(text("Unsupported call: e1 op=", call.e1.op));
        }

        VarDeclaration instanceDecl;
        if (auto instanceVar = dotVar.e1.isVarExp)
            instanceDecl = instanceVar.var.isVarDeclaration;
        else if (dotVar.e1.isThisExp !is null)
            instanceDecl = currentThis;

        if (instanceDecl is null) {
            import std.conv: text;
            throw new Exception(text("Unsupported call target: e1 op=", dotVar.e1.op));
        }

        auto func = dotVar.var.isFuncDeclaration;
        if (func is null)
            throw new Exception("Unsupported call: not a FuncDeclaration.");

        auto args = argumentValues(call.arguments);

        auto savedLocals = locals.dup;
        auto savedThis = currentThis;
        auto savedDidReturn = didReturn;
        auto savedReturnValue = returnValue;
        locals = null;
        currentThis = instanceDecl;
        didReturn = false;
        returnValue = Value(0L);

        if (func.parameters !is null)
            foreach (i, param; *func.parameters) {
                if (i >= args.length) continue;
                locals[param] = args[i];
            }

        runStatement(func.fbody);
        const result = returnValue;

        locals = savedLocals;
        currentThis = savedThis;
        didReturn = savedDidReturn;
        returnValue = savedReturnValue;
        return result;
    }

    private Value runFreeFunctionCall(
        imported!"dmd.func".FuncDeclaration func,
        imported!"dmd.expression".Expressions* arguments,
    ) {
        auto args = argumentValues(arguments);

        auto savedLocals = locals.dup;
        auto savedThis = currentThis;
        auto savedDidReturn = didReturn;
        auto savedReturnValue = returnValue;

        locals = null;
        currentThis = null;
        didReturn = false;
        returnValue = Value(0L);

        if (func.parameters !is null)
            foreach (i, param; *func.parameters) {
                if (i >= args.length) continue;
                locals[param] = args[i];
            }

        runStatement(func.fbody);
        const result = returnValue;

        if (func.parameters !is null && arguments !is null)
            foreach (i, param; *func.parameters) {
                if (!param.isRef) continue;
                if (i >= arguments.length) continue;
                if (auto varExp = (*arguments)[i].isVarExp)
                    if (auto callerVar = varExp.var.isVarDeclaration)
                        if (param in locals)
                            savedLocals[callerVar] = locals[param];
            }

        locals = savedLocals;
        currentThis = savedThis;
        didReturn = savedDidReturn;
        returnValue = savedReturnValue;

        return result;
    }

    private Value[] argumentValues(
        imported!"dmd.expression".Expressions* arguments,
    ) {
        Value[] values;
        if (arguments is null)
            return values;

        foreach (arg; *arguments)
            values ~= argumentValue(arg);

        return values;
    }

    private Value argumentValue(
        imported!"dmd.expression".Expression argument,
    ) {
        return runExpression(argument);
    }

    private Value runCatAssignExpression(
        imported!"dmd.expression".BinExp catAssign,
    ) {
        if (auto var = catAssign.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration) {
                long[] array;
                if (!tryGetArray(locals[variable], array))
                    throw new Exception("Unsupported ~=: expected array lhs.");
                array ~= runExpression(catAssign.e2).asLong;
                locals[variable] = Value(array);
                return Value(0L);
            }

        auto dotVar = catAssign.e1.isDotVarExp;
        if (dotVar is null) {
            import std.conv: text;
            throw new Exception(text("Unsupported ~=: e1 op=", catAssign.e1.op));
        }

        if (dotVar.e1.isThisExp is null) {
            import std.conv: text;
            throw new Exception(text("Unsupported ~=: dotVar.e1 op=", dotVar.e1.op));
        }

        auto field = dotVar.var.isVarDeclaration;
        if (field is null || currentThis is null)
            throw new Exception("Unsupported ~=: no struct context.");

        structArrays[currentThis][field] ~= runExpression(catAssign.e2).asLong;
        return Value(0L);
    }

    private long[] evalArrayExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        long[] value;
        if (tryEvalArrayExpression(expression, value))
            return value;

        if (callArrayExpressionValue(expression, value))
            return value;

        import std.conv: text;
        throw new Exception(text("Unsupported array expression: ", expression.op));
    }

    private bool tryEvalArrayExpression(
        imported!"dmd.expression".Expression expression,
        out long[] value,
    ) {
        if (localArrayExpressionValue(expression, value))
            return true;

        if (sliceArrayExpressionValue(expression, value))
            return true;

        if (structArrayExpressionValue(expression, value))
            return true;

        if (thisStructArrayExpressionValue(expression, value))
            return true;

        if (emptyStructArrayExpressionValue(expression, value))
            return true;

        return false;
    }

    private bool callArrayExpressionValue(
        imported!"dmd.expression".Expression expression,
        out long[] value,
    ) {
        auto call = expression.isCallExp;
        if (call is null)
            return false;

        return tryGetArray(runCallExpression(call), value);
    }

    private bool sliceArrayExpressionValue(
        imported!"dmd.expression".Expression expression,
        out long[] value,
    ) {
        auto slice = expression.isSliceExp;
        if (slice is null || slice.lwr is null || slice.upr is null)
            return false;

        const array = evalArrayExpression(slice.e1);
        const lower = asArrayIndex(runExpression(slice.lwr));
        const upper = asArrayIndex(runExpression(slice.upr));
        value = array[lower .. upper].dup;
        return true;
    }

    private bool localArrayExpressionValue(
        imported!"dmd.expression".Expression expression,
        out long[] value,
    ) {
        auto var = expression.isVarExp;
        if (var is null)
            return false;

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            return false;

        auto stored = variable in locals;
        if (stored is null)
            return false;

        long[] array;
        if (!tryGetArray(*stored, array))
            return false;

        return arrayValue(array, value);
    }

    private bool emptyStructArrayExpressionValue(
        imported!"dmd.expression".Expression expression,
        out long[] value,
    ) {
        auto dotVar = expression.isDotVarExp;
        if (dotVar is null)
            return false;

        auto instanceVar = dotVar.e1.isVarExp;
        if (instanceVar is null)
            return false;

        auto instanceDecl = instanceVar.var.isVarDeclaration;
        if (instanceDecl is null)
            return false;

        auto field = dotVar.var.isVarDeclaration;
        if (field is null)
            return false;

        return arrayValue([], value);
    }

    private bool arrayValue(in long[] source, out long[] value) {
        value = source.dup;
        return true;
    }

    private bool structArrayExpressionValue(
        imported!"dmd.expression".Expression expression,
        out long[] value,
    ) {
        auto dotVar = expression.isDotVarExp;
        if (dotVar is null)
            return false;

        auto instanceVar = dotVar.e1.isVarExp;
        if (instanceVar is null)
            return false;

        auto instanceDecl = instanceVar.var.isVarDeclaration;
        if (instanceDecl is null)
            return false;

        auto field = dotVar.var.isVarDeclaration;
        if (field is null)
            return false;

        return structArrayValue(instanceDecl, field, value);
    }

    private bool thisStructArrayExpressionValue(
        imported!"dmd.expression".Expression expression,
        out long[] value,
    ) {
        auto dotVar = expression.isDotVarExp;
        if (dotVar is null)
            return false;

        if (dotVar.e1.isThisExp is null || currentThis is null)
            return false;

        auto field = dotVar.var.isVarDeclaration;
        if (field is null)
            return false;

        return structArrayValue(currentThis, field, value);
    }

    private bool structArrayValue(
        imported!"dmd.declaration".VarDeclaration instance,
        imported!"dmd.declaration".VarDeclaration field,
        out long[] value,
    ) {
        if (auto entry = instance in structArrays)
            if (auto arr = field in *entry) {
                value = *arr;
                return true;
            }

        return false;
    }

    private long runAssertExpression(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        if (runExpression(assert_.e1).asLong)
            return 1;

        if (auto equal = assert_.e1.isEqualExp) {
            import std.conv: text;

            throw new Exception(text(
                runExpression(equal.e1).asLong,
                " != ",
                runExpression(equal.e2).asLong,
            ));
        }

        throw new Exception("Unittest assertion failed.");
    }

    public override TestSummary runTestSummary(
        in string source,
    ) {
        return TestSummary.init;
    }

    public override imported!"quickbite.executor".Value eval(in string input) {
        import quickbite.executor: Value;
        import quickbite.frontend.compiler: parseModule;
        import dmd.declaration: VarDeclaration;
        import dmd.func: FuncDeclaration;
        import std.string: lastIndexOf;

        const lastNl = input.lastIndexOf('\n');
        const prior  = lastNl < 0 ? "" : input[0 .. lastNl + 1];
        const last   = lastNl < 0 ? input : input[lastNl + 1 .. $];
        const source = "void f() { " ~ prior ~ "auto __r = " ~ last ~ "; }";

        auto parsed = parseModule(source);
        auto module_ = parsed.module_;

        FuncDeclaration f;
        if (module_.members !is null) {
            foreach (member; *module_.members) {
                auto fd = member.isFuncDeclaration;
                if (fd !is null && fd.ident.toString == "f") {
                    f = fd;
                    break;
                }
            }
        }

        resetState;
        runStatement(f.fbody);

        foreach (decl, value; locals) {
            if (decl.ident.toString == "__r")
                return Value(cast(int) value.asLong);
        }

        return Value(0);
    }

    public override void runVoidReplCell(
        in string transcript,
        in string input,
    ) {
        import dmd.func: FuncDeclaration;
        import quickbite.frontend.compiler: parseModule;

        const source = "void f() { " ~ transcript ~ input ~ " }";
        auto parsed = parseModule(source);
        auto module_ = parsed.module_;

        FuncDeclaration f;
        if (module_.members !is null) {
            foreach (member; *module_.members) {
                auto fd = member.isFuncDeclaration;
                if (fd !is null && fd.ident.toString == "f") {
                    f = fd;
                    break;
                }
            }
        }

        resetState;
        runStatement(f.fbody);
    }

    private void resetState() {
        locals = null;
        structScalars = null;
        structArrays = null;
        currentThis = null;
        didReturn = false;
        returnValue = Value(0L);
    }

    private size_t asArrayIndex(Value value) {
        return cast(size_t) value.asLong;
    }

    private bool tryGetArray(Value value, out long[] array) {
        if (!value.isLongArray)
            return false;

        array = value.asLongArray;
        return true;
    }
}

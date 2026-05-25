module quickbite.backends.tree_walking;

private:

public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    import dmd.declaration: VarDeclaration;
    import dmd.dmodule: Module;
    import quickbite.executor: TestSummary;

    private long[VarDeclaration] locals;
    private long[][VarDeclaration] localArrays;
    private long[][VarDeclaration][VarDeclaration] structArrays;
    private VarDeclaration currentThis;
    private bool didReturn;
    private long returnValue;

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
        localArrays = null;
        structArrays = null;
        currentThis = null;
        didReturn = false;
        returnValue = 0;
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

        if (auto return_ = statement.isReturnStatement) {
            if (return_.exp !is null)
                returnValue = runExpression(return_.exp);
            didReturn = true;
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    private long runExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return integer.getInteger;

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable !is null && variable in locals)
                return locals[variable];
        }

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct);

        if (auto add = expression.isAddExp)
            return runExpression(add.e1) + runExpression(add.e2);

        if (auto sub = expression.isMinExp)
            return runExpression(sub.e1) - runExpression(sub.e2);

        if (auto addAssign = expression.isAddAssignExp) {
            auto lhs = addAssign.e1;
            if (auto cast_ = lhs.isCastExp)
                lhs = cast_.e1;
            if (auto var = lhs.isVarExp)
                if (auto variable = var.var.isVarDeclaration) {
                    const value = runExpression(addAssign.e1) + runExpression(addAssign.e2);
                    locals[variable] = value;
                    return value;
                }
        }

        if (auto equal = expression.isEqualExp)
            return runExpression(equal.e1) == runExpression(equal.e2);

        if (auto assert_ = expression.isAssertExp)
            return runAssertExpression(assert_);

        if (auto cast_ = expression.isCastExp)
            return runExpression(cast_.e1);

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

        if (auto catAssign = expression.isCatAssignExp)
            return runCatAssignExpression(catAssign);

        if (auto catElemAssign = expression.isCatElemAssignExp)
            return runCatAssignExpression(catElemAssign);

        if (auto arrayLength = expression.isArrayLengthExp)
            return runArrayExpression(arrayLength.e1).length;

        if (auto index = expression.isIndexExp)
            return runArrayExpression(index.e1)[runExpression(index.e2)];

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expression.op));
    }

    private long runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return 0;

        if (variable._init is null || variable._init.isExpInitializer is null)
            return 0;

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp)
            initializer = blit.e2;

        if (auto arrayLit = initializer.isArrayLiteralExp) {
            long[] elements;
            if (arrayLit.elements !is null)
                foreach (elem; *arrayLit.elements)
                    elements ~= runExpression(elem);
            localArrays[variable] = elements;
            return 0;
        }

        const value = runExpression(initializer);
        locals[variable] = value;
        return value;
    }

    private long runAssignExpression(imported!"dmd.expression".BinExp assign) {
        auto var = assign.e1.isVarExp;
        if (var is null || var.var.isVarDeclaration is null)
            throw new Exception("Unsupported assignment.");

        auto variable = var.var.isVarDeclaration;
        const value = runExpression(assign.e2);
        locals[variable] = value;
        return value;
    }

    private long runCallExpression(imported!"dmd.expression".CallExp call) {
        if (auto funcVar = call.e1.isVarExp)
            if (auto func = funcVar.var.isFuncDeclaration)
                return runFreeFunctionCall(func, call.arguments);

        auto dotVar = call.e1.isDotVarExp;
        if (dotVar is null) {
            import std.conv: text;
            throw new Exception(text("Unsupported call: e1 op=", call.e1.op));
        }

        auto instanceVar = dotVar.e1.isVarExp;
        if (instanceVar is null) {
            import std.conv: text;
            throw new Exception(text("Unsupported call target: e1 op=", dotVar.e1.op));
        }

        auto instanceDecl = instanceVar.var.isVarDeclaration;
        if (instanceDecl is null)
            throw new Exception("Unsupported call: instance is not a VarDeclaration.");

        auto func = dotVar.var.isFuncDeclaration;
        if (func is null)
            throw new Exception("Unsupported call: not a FuncDeclaration.");

        long[] argValues;
        if (call.arguments !is null)
            foreach (arg; *call.arguments)
                argValues ~= runExpression(arg);

        auto savedLocals = locals.dup;
        auto savedThis = currentThis;
        auto savedDidReturn = didReturn;
        auto savedReturnValue = returnValue;
        locals = null;
        currentThis = instanceDecl;
        didReturn = false;
        returnValue = 0;

        if (func.parameters !is null)
            foreach (i, param; *func.parameters)
                if (i < argValues.length)
                    locals[param] = argValues[i];

        runStatement(func.fbody);
        const result = returnValue;

        locals = savedLocals;
        currentThis = savedThis;
        didReturn = savedDidReturn;
        returnValue = savedReturnValue;
        return result;
    }

    private long runFreeFunctionCall(
        imported!"dmd.func".FuncDeclaration func,
        imported!"dmd.expression".Expressions* arguments,
    ) {
        struct ArgValue {
            long scalar;
            long[] array;
            bool isArray;
        }

        ArgValue[] args;
        if (arguments !is null)
            foreach (arg; *arguments) {
                if (auto varExp = arg.isVarExp)
                    if (auto varDecl = varExp.var.isVarDeclaration)
                        if (auto arr = varDecl in localArrays) {
                            args ~= ArgValue(0, *arr, true);
                            continue;
                        }
                args ~= ArgValue(runExpression(arg));
            }

        auto savedLocals = locals.dup;
        auto savedLocalArrays = localArrays.dup;
        auto savedThis = currentThis;
        auto savedDidReturn = didReturn;
        auto savedReturnValue = returnValue;

        locals = null;
        localArrays = null;
        currentThis = null;
        didReturn = false;
        returnValue = 0;

        if (func.parameters !is null)
            foreach (i, param; *func.parameters) {
                if (i >= args.length) continue;
                if (args[i].isArray)
                    localArrays[param] = args[i].array;
                else
                    locals[param] = args[i].scalar;
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
        localArrays = savedLocalArrays;
        currentThis = savedThis;
        didReturn = savedDidReturn;
        returnValue = savedReturnValue;

        return result;
    }

    private long runCatAssignExpression(
        imported!"dmd.expression".BinExp catAssign,
    ) {
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

        structArrays[currentThis][field] ~= runExpression(catAssign.e2);
        return 0;
    }

    private long[] runArrayExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto var = expression.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                if (auto arr = variable in localArrays)
                    return *arr;

        if (auto dotVar = expression.isDotVarExp)
            if (auto instanceVar = dotVar.e1.isVarExp)
                if (auto instanceDecl = instanceVar.var.isVarDeclaration)
                    if (auto field = dotVar.var.isVarDeclaration)
                        if (auto entry = instanceDecl in structArrays)
                            if (auto arr = field in *entry)
                                return *arr;

        if (auto dotVar = expression.isDotVarExp)
            if (auto instanceVar = dotVar.e1.isVarExp)
                if (auto instanceDecl = instanceVar.var.isVarDeclaration)
                    if (auto field = dotVar.var.isVarDeclaration)
                        return [];

        import std.conv: text;
        throw new Exception(text("Unsupported array expression: ", expression.op));
    }

    private long runAssertExpression(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        if (runExpression(assert_.e1))
            return 1;

        if (auto equal = assert_.e1.isEqualExp) {
            import std.conv: text;

            throw new Exception(text(
                runExpression(equal.e1),
                " != ",
                runExpression(equal.e2),
            ));
        }

        throw new Exception("Unittest assertion failed.");
    }

    public override TestSummary runTestSummary(
        in string source,
    ) {
        return TestSummary.init;
    }
}

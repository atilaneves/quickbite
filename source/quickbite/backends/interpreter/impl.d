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

    public override Value evalRepl(in EvalCell cell) {
        assert(0);
    }

    public override void runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        EvalModuleInterpreter interpreter;
        foreachUnitTestDeclaration(module_, (unitTest) {
            interpreter.runTest(unitTest);
        });
    }

    public override TestRunResult runTestResults(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        TestRunResult result;
        EvalModuleInterpreter interpreter;
        foreachUnitTestDeclaration(module_, (unitTest) {
            ++result.summary.total;
            try {
                interpreter.runTest(unitTest);
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
        EvalModuleInterpreter interpreter;
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

private imported!"quickbite.lang".Value evalFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    EvalFunctionWalker walker;
    walker.runStatement(function_.fbody);
    return walker.result;
}

private struct EvalFunctionWalker {
    import quickbite.lang: Value;
    import quickbite.frontend.dmd.values: defaultValue;
    import dmd.declaration: VarDeclaration;

    private Value[VarDeclaration] locals;
    private Value result;

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

        import std.conv: text;
        throw new Exception(text("Unsupported eval statement: ", statement.stmt));
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import quickbite.frontend.dmd.values: integerValue, realValue;

        if (auto integer = expression.isIntegerExp)
            return integerValue(integer);

        if (auto real_ = expression.isRealExp)
            return realValue(real_);

        if (auto string_ = expression.isStringExp)
            return stringValue(string_);

        if (auto cast_ = expression.isCastExp)
            return castValue(cast_);

        if (auto addAssign = expression.isAddAssignExp)
            return runIncrementAssignExpression(addAssign);

        if (auto sub = expression.isMinExp)
            return runExpression(sub.e1) - runExpression(sub.e2);

        if (auto neg = expression.isNegExp)
            return -runExpression(neg.e1);

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                assert(0);

            if (auto current = variable in locals)
                return *current;

            return defaultValue(variable);
        }

        import std.conv: text;
        throw new Exception(text("Unsupported eval expression: ", expression.op));
    }

    private Value runCallExpression(
        imported!"dmd.expression".CallExp call,
    ) {
        import dmd.builtin: isBuiltin;
        import dmd.func: BUILTIN;
        import std.math: mathFabs = fabs;
        import std.math: mathPow = pow;

        if (call.arguments is null || call.arguments.length == 0)
            throw new Exception("Unsupported eval call argument count.");

        with (BUILTIN) switch (isBuiltin(call.f)) {
            case fabs:
                if (call.arguments.length != 1)
                    throw new Exception("Unsupported eval call argument count.");
                return runExpression((*call.arguments)[0])
                    .unaryFloating!mathFabs;

            case pow:
                if (call.arguments.length != 2)
                    throw new Exception("Unsupported eval call argument count.");
                return runExpression((*call.arguments)[0])
                    .binaryFloating!mathPow(runExpression((*call.arguments)[1]));

            default:
                break;
        }

        throw new Exception("Unsupported eval call.");
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(cast(int) 0);

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

        auto value = runExpression(initializer);
        locals[variable] = value;
        return value;
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

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        auto type = cast_.to.toBasetype;
        if (type is null)
            return runExpression(cast_.e1);

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
    }

    private Value stringValue(imported!"dmd.expression".StringExp string_) {
        return Value(stringChars(string_));
    }

    private char[] stringChars(imported!"dmd.expression".StringExp string_) {
        char[] values;
        foreach (index; 0 .. string_.numberOfCodeUnits)
            values ~= cast(char) string_.getIndex(index);

        return values;
    }
}

private struct EvalModuleInterpreter {
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import quickbite.frontend.dmd.values: defaultValue;
    import quickbite.lang: Value;

    private Value[VarDeclaration] locals;
    private bool[VarDeclaration] uninitializedLocals;
    private Value result;
    private bool runningCalledFunction;
    private FuncDeclaration currentFunction;

    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
        log("Running test ", unitTest);
        runStatement(unitTest.fbody);
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto expression = statement.isExpStatement) {
            runExpression(expression.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            result = runExpression(return_.exp);
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            if (isTruthy(runExpression(if_.condition)))
                runStatement(if_.ifbody);
            else
                runStatement(if_.elsebody);
            return;
        }

        if (auto throw_ = statement.isThrowStatement)
            throw new Exception(thrownExceptionMessage(throw_.exp));

        assert(0);
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.values: integerValue;

        if (auto integer = expression.isIntegerExp)
            return integerValue(integer);

        if (expression.isNullExp !is null)
            return Value.null_;

        if (auto string_ = expression.isStringExp)
            return stringValue(string_);

        if (auto assert_ = expression.isAssertExp) {
            if (!isTruthy(runExpression(assert_.e1)))
                throw new Exception(assertFailureMessage(assert_));
            return Value(true);
        }

        if (auto not = expression.isNotExp)
            return Value(!isTruthy(runExpression(not.e1)));

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

        if (auto add = expression.isAddExp)
            return runExpression(add.e1) + runExpression(add.e2);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

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

        if (auto dot = expression.isDotVarExp)
            return runDotVarExpression(dot);

        if (auto typeid_ = expression.isTypeidExp)
            return runTypeidExpression(typeid_);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                assert(0);

            if (variable in uninitializedLocals)
                throw new Exception(uninitializedVariableMessage(variable));

            if (auto current = variable in locals)
                return *current;

            return defaultValue(variable);
        }

        import std.conv: text;
        throw new Exception(text("Unsupported interpreter expression: ", expression.op));
    }

    private Value runLogicalAndExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        const left = isTruthy(runExpression(logical.e1));
        if (!left)
            return Value(false);

        const right = isTruthy(runExpression(logical.e2));
        return Value(right);
    }

    private Value runLogicalOrExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
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

        const left = runExpression(comparison.e1).asLong;
        const right = runExpression(comparison.e2).asLong;

        if (comparison.op == EXP.lessThan)
            return Value(left < right);
        if (comparison.op == EXP.lessOrEqual)
            return Value(left <= right);
        if (comparison.op == EXP.greaterThan)
            return Value(left > right);
        return Value(left >= right);
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

        if (call.f !is null)
            return runFunction(call.f, arguments, argumentVariables);

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return runFunction(function_, arguments, argumentVariables);

        throw new Exception("Unsupported interpreter call.");
    }

    private Value runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        VarDeclaration[] argumentVariables,
    ) {
        auto savedLocals = locals.dup;
        auto savedUninitializedLocals = uninitializedLocals.dup;
        const savedResult = result;
        const savedRunningCalledFunction = runningCalledFunction;
        auto savedCurrentFunction = currentFunction;

        locals = null;
        uninitializedLocals = null;
        result = Value(false);
        runningCalledFunction = true;
        currentFunction = function_;
        bindFunctionParameters(function_, arguments);

        runStatement(function_.fbody);
        const value = result;
        writeBackRefParameters(function_, argumentVariables, savedLocals);

        locals = savedLocals;
        uninitializedLocals = savedUninitializedLocals;
        result = savedResult;
        runningCalledFunction = savedRunningCalledFunction;
        currentFunction = savedCurrentFunction;
        return value;
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
        auto var = assign.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const value = runExpression(assign.e2);
        locals[variable] = value;
        uninitializedLocals.remove(variable);
        return value;
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

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
    }

    private string receiverName(imported!"dmd.expression".Expression receiver) {
        auto var = receiver.isVarExp;
        if (var is null)
            return "null";

        return var.var.ident.toString.idup;
    }

    private bool isClassExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;

        const type = expression.type is null ? null : expression.type.toBasetype;
        return type !is null && type.ty == TY.Tclass;
    }

    private Value stringValue(imported!"dmd.expression".StringExp string_) {
        return Value(stringChars(string_));
    }

    private char[] stringChars(imported!"dmd.expression".StringExp string_) {
        char[] values;
        foreach (index; 0 .. string_.numberOfCodeUnits)
            values ~= cast(char) string_.getIndex(index);

        return values;
    }

    private string thrownExceptionMessage(
        imported!"dmd.expression".Expression expression,
    ) {
        auto new_ = expression is null ? null : expression.isNewExp;
        if (new_ is null || new_.arguments is null || new_.arguments.length == 0)
            return "Unittest assertion failed.";

        auto message = (*new_.arguments)[0].isStringExp;
        if (message is null)
            return "Unittest assertion failed.";

        return stringChars(message).idup;
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

        auto value = runExpression(initializer);
        locals[variable] = value;
        uninitializedLocals.remove(variable);
        return value;
    }

    private string uninitializedVariableMessage(VarDeclaration variable) {
        import std.conv: text;

        const functionName =
            currentFunction is null ? "<unknown>" : currentFunction.ident.toString;

        return text(
            "cannot read uninitialized variable `.",
            functionName,
            ".",
            variable.ident.toString,
            "` in ctfe",
        );
    }

    private bool isTruthy(in Value value) {
        if (value == Value(false))
            return false;

        if (value == Value(true))
            return true;

        return value.castTo!bool == Value(true);
    }

    private string assertFailureMessage(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        if (assert_.msg !is null) {
            if (assert_.msg.isStringExp !is null)
                return assertMessage(assert_.msg);

            if (auto message = dmdAssertFailBoolMessage(assert_.msg))
                return message;
        }

        if (assert_.msg !is null) {
            const message = dmdAssertFailMessage(assert_.msg);
            if (message !is null)
                return message;

            if (isVariableMessage(assert_.msg))
                return assertMessage(assert_.msg);
        }

        if (auto integer = assert_.e1.isIntegerExp)
            if (!isBoolExpression(integer))
                return "`assert(0)` failed";

        if (auto not = assert_.e1.isNotExp) {
            import std.conv: text;

            if (isLogicalExpression(not.e1))
                return text(
                    equalityOperandMessage(runExpression(not.e1), true, not.e1),
                    " == true",
                );
        }

        if (auto equal = assert_.e1.isEqualExp)
            return equalFailureMessage(equal);

        if (assert_.e1.isIntegerExp is null && isBoolExpression(assert_.e1)) {
            import std.conv: text;

            return text(isTruthy(runExpression(assert_.e1)), " != true");
        }

        if (runningCalledFunction) {
            if (auto integer = assert_.e1.isIntegerExp) {
                if (integer.toInteger == 0)
                    return "`assert(0)` failed";
            }
        }

        return "`assert(false)` failed";
    }

    private string equalFailureMessage(
        imported!"dmd.expression".EqualExp equal,
    ) {
        import dmd.tokens: EXP;
        import std.conv: text;

        const operator = equal.op == EXP.notEqual ? "==" : "!=";
        const left = runExpression(equal.e1);
        const right = runExpression(equal.e2);
        const useBoolMessage =
            isBoolValue(left) ||
            isBoolValue(right) ||
            isBoolExpression(equal.e1) ||
            isBoolExpression(equal.e2) ||
            isLogicalNotExpression(equal.e1) ||
            isLogicalNotExpression(equal.e2) ||
            isLogicalExpression(equal.e1) ||
            isLogicalExpression(equal.e2);
        return text(
            equalityOperandMessage(left, useBoolMessage, equal.e1),
            " ",
            operator,
            " ",
            equalityOperandMessage(right, useBoolMessage, equal.e2),
        );
    }

    private string dmdAssertFailMessage(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.id: Id;
        import std.conv: text;

        auto call = expression.isCallExp;
        if (call is null ||
            call.f is null ||
            call.f.ident != Id._d_assert_fail ||
            call.arguments is null ||
            call.arguments.length != 3)
            return null;

        auto operatorLiteral = (*call.arguments)[0].isStringExp;
        if (operatorLiteral is null)
            return null;

        const operator = invertedEqualityOperator(operatorLiteral.peekString);
        if (operator is null)
            return null;

        auto left = (*call.arguments)[1];
        auto right = (*call.arguments)[2];
        const useBoolMessage =
            isBoolExpression(left) ||
            isBoolExpression(right) ||
            isLogicalNotExpression(left) ||
            isLogicalNotExpression(right) ||
            isLogicalExpression(left) ||
            isLogicalExpression(right);
        const leftValue = runExpression(left);
        const rightValue = runExpression(right);

        return text(
            equalityOperandMessage(leftValue, useBoolMessage, left),
            " ",
            operator,
            " ",
            equalityOperandMessage(rightValue, useBoolMessage, right),
        );
    }

    private string invertedEqualityOperator(in char[] operator) {
        if (operator == "==")
            return "!=";

        if (operator == "!=")
            return "==";

        if (operator == "<")
            return ">=";

        if (operator == "<=")
            return ">";

        if (operator == ">")
            return "<=";

        if (operator == ">=")
            return "<";

        return null;
    }

    private string equalityOperandMessage(
        in Value value,
        in bool useBoolMessage,
        imported!"dmd.expression".Expression expression,
    ) {
        import std.conv: text;

        if (useBoolMessage)
            return text(isTruthy(value));

        if (isCharExpression(expression))
            return text("'", value, "'");

        if (isUnsignedLongExpression(expression))
            return text(value.asLong);

        return text(value);
    }

    private bool isCharExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;

        const type = expression.type is null ? null : expression.type.toBasetype;
        return type !is null && type.ty == TY.Tchar;
    }

    private bool isUnsignedLongExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;

        const type = expression.type is null ? null : expression.type.toBasetype;
        return type !is null && type.ty == TY.Tuns64;
    }

    private bool isBoolValue(in Value value) {
        return value == Value(false) || value == Value(true);
    }

    private bool isBoolExpression(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;

        if (auto cast_ = expression.isCastExp)
            if (isBoolExpression(cast_.e1))
                return true;

        auto type = expression.type;
        if (auto cast_ = expression.isCastExp)
            type = cast_.to;

        return type !is null && type.toBasetype.ty == TY.Tbool;
    }

    private bool isLogicalNotExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        while (auto cast_ = expression.isCastExp)
            expression = cast_.e1;

        if (auto comma = expression.isCommaExp)
            return isLogicalNotExpression(comma.e2);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null ||
                variable._init is null ||
                variable._init.isExpInitializer is null)
                return false;

            auto initializer = variable._init.isExpInitializer.exp;
            if (auto assign = initializer.isAssignExp)
                initializer = assign.e2;
            else if (auto construct = initializer.isConstructExp)
                initializer = construct.e2;
            else if (auto blit = initializer.isBlitExp)
                initializer = blit.e2;

            return isLogicalNotExpression(initializer);
        }

        return expression.isNotExp !is null;
    }

    private bool isLogicalExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        while (auto cast_ = expression.isCastExp)
            expression = cast_.e1;

        if (auto comma = expression.isCommaExp)
            return isLogicalExpression(comma.e2);

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null ||
                variable._init is null ||
                variable._init.isExpInitializer is null)
                return false;

            auto initializer = variable._init.isExpInitializer.exp;
            if (auto assign = initializer.isAssignExp)
                initializer = assign.e2;
            else if (auto construct = initializer.isConstructExp)
                initializer = construct.e2;
            else if (auto blit = initializer.isBlitExp)
                initializer = blit.e2;

            return isLogicalExpression(initializer);
        }

        return expression.isLogicalExp !is null;
    }

    private string assertMessage(imported!"dmd.expression".Expression expression) {
        if (auto literal = expression.isStringExp)
            return literal.peekString.idup;

        if (expression.isVarExp !is null)
            return runExpression(expression).asCharArrayString;

        if (auto cast_ = expression.isCastExp)
            if (cast_.e1.isVarExp !is null)
                return runExpression(expression).asCharArrayString;

        assert(0);
    }

    private bool isVariableMessage(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression.isVarExp !is null)
            return true;

        if (auto cast_ = expression.isCastExp)
            return cast_.e1.isVarExp !is null;

        return false;
    }

    private string dmdAssertFailBoolMessage(
        imported!"dmd.expression".Expression expression,
    ) {
        auto call = expression.isCallExp;
        if (call is null ||
            call.f is null ||
            call.f.ident.toString != "_d_assert_fail" ||
            call.arguments is null)
            return null;

        return dmdAssertFailBoolMessage(call);
    }

    private string dmdAssertFailBoolMessage(
        imported!"dmd.expression".CallExp call,
    ) {
        import std.conv: text;

        if (call.arguments.length != 3)
            return null;

        auto operator = (*call.arguments)[0].isStringExp;
        if (operator is null)
            return null;

        const operatorText = operator.peekString.idup;
        if (operatorText != "==" && operatorText != "!=")
            return null;

        auto left = (*call.arguments)[1].isIntegerExp;
        auto right = (*call.arguments)[2].isIntegerExp;
        if (left is null || right is null)
            return null;

        const inverseOperator = operatorText == "==" ? "!=" : "==";
        if (left.toInteger > 1 || right.toInteger > 1)
            return text(
                left.toInteger,
                " ",
                inverseOperator,
                " ",
                right.toInteger,
            );

        return text(
            left.toInteger != 0,
            " ",
            inverseOperator,
            " ",
            right.toInteger != 0,
        );
    }
}

private void log(A...)(auto ref A args) {
    version(unittest) {
        import unit_threaded;
        writelnUt(args);
    }
}

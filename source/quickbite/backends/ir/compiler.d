module quickbite.backends.ir.compiler;

private:

package imported!"quickbite.backends.ir.language".Function compileUnitTest(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    Compiler compiler;
    return compiler.compileEntryFunction(unitTest);
}

package imported!"quickbite.backends.ir.language".Function compileFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    Compiler compiler;
    return compiler.compileEntryFunction(function_);
}

private struct Compiler {
    import dmd.expression:
        AddAssignExp,
        AssignExp,
        BinExp,
        CmpExp,
        Expression,
        IdentityExp;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import quickbite.backends.ir.language:
        BinaryOp,
        BinaryOperation,
        Block,
        AssertCompare,
        AssertFalse,
        AssertTrue,
        Branch,
        Cast,
        Call,
        CondBranch,
        Const,
        Function,
        Instruction,
        Load,
        RefWriteback,
        ResultKind,
        ReturnVoid,
        ReturnValue,
        StringConst,
        Store,
        Terminator,
        ThrowException,
        ThrowIfNull,
        Type,
        UnaryIntrinsicOp,
        UnaryIntrinsicOperation,
        UnaryOp,
        UnaryOperation,
        Value;

    private Instruction[] instructions;
    private uint[VarDeclaration] locals;
    private LocalInfo[VarDeclaration] localInfos;
    private FuncDeclaration[] functions;
    private uint[FuncDeclaration] functionIndices;
    private Function[] compiledFunctions;
    private Block[] blocks;
    private Value[] currentBlockParams;
    private FuncDeclaration currentFunction;
    private uint nextValueId;

    private Function compileEntryFunction(FuncDeclaration function_) {
        auto entry = compileFunctionBody(function_);

        // Compiling discovered functions can discover more callees.
        for (size_t i = 0; i < functions.length; ++i)
            compiledFunctions ~= compileFunctionBody(functions[i]);

        return entry.withFunctions(compiledFunctions);
    }

    private Function compileFunctionBody(FuncDeclaration function_) {
        instructions = null;
        locals = null;
        localInfos = null;
        blocks = null;
        currentBlockParams = null;
        currentFunction = function_;
        nextValueId = 0;
        registerParameters(function_);

        const result = compileStatement(function_.fbody);
        return result.hasValue ?
            makeFunction(result.value) :
            makeVoidFunction;
    }

    private OptionalValue compileStatement(
        imported!"dmd.statement".Statement statement,
    ) {
        if (auto scope_ = statement.isScopeStatement)
            return compileStatement(scope_.statement);

        if (auto compound = statement.isCompoundStatement) {
            OptionalValue result;
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    const childResult = compileStatement(child);
                    if (childResult.hasValue)
                        result = childResult;
                }
            return result;
        }

        if (auto expression = statement.isExpStatement)
            return OptionalValue(compileExpression(expression.exp), true);

        if (auto return_ = statement.isReturnStatement)
            return OptionalValue(compileExpression(return_.exp), true);

        if (auto if_ = statement.isIfStatement)
            return compileIfStatement(if_);

        if (auto throw_ = statement.isThrowStatement)
            return OptionalValue(compileThrow(throw_), true);

        if (statement.isImportStatement)
            return OptionalValue.init;

        import std.conv: text;

        throw new Exception(
            text("Unsupported IR statement: ", statement.stmt),
        );
    }

    private OptionalValue compileIfStatement(
        imported!"dmd.statement".IfStatement if_,
    ) {
        const condition = compileExpression(if_.condition);
        const trueBlock = cast(uint) blocks.length + 1;
        const falseBlock = trueBlock + 1;
        const joinBlock = falseBlock + 1;
        finishBlock(Terminator(
            CondBranch(
                condition.id,
                trueBlock,
                [],
                falseBlock,
                [],
            ),
        ));

        const trueResult = compileStatement(if_.ifbody);
        if (!trueResult.hasValue)
            throw new Exception("Unsupported IR if statement.");

        finishBlock(Terminator(Branch(joinBlock, [trueResult.value.id])));

        const falseResult = compileStatement(if_.elsebody);
        if (!falseResult.hasValue)
            throw new Exception("Unsupported IR if statement.");

        finishBlock(Terminator(Branch(joinBlock, [falseResult.value.id])));

        const result = nextValue(
            trueResult.value.type,
            trueResult.value.resultKind,
        );
        currentBlockParams = [result];
        return OptionalValue(result, true);
    }

    private Value compileThrow(imported!"dmd.statement".ThrowStatement throw_) {
        instructions ~= Instruction(
            ThrowException(newExceptionMessage(throw_.exp)),
        );
        return compileIntegerLiteral(0);
    }

    private Value compileExpression(Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return compileInteger(integer);

        if (expression.isNullExp !is null)
            return compileNull(expression.type);

        if (auto declaration = expression.isDeclarationExp) {
            auto variable = declaration.declaration.isVarDeclaration;
            assert(variable !is null);
            return compileVariableDeclaration(variable);
        }

        if (auto variable = expression.isVarExp) {
            auto declaration = variable.var.isVarDeclaration;
            assert(declaration !is null);
            return compileVariableLoad(declaration);
        }

        if (auto assert_ = expression.isAssertExp) {
            return compileAssert(assert_);
        }

        if (auto comma = expression.isCommaExp) {
            compileExpression(comma.e1);
            return compileExpression(comma.e2);
        }

        if (auto equal = expression.isEqualExp)
            return compileBinaryExpression(equal, equalityOperation(equal));

        if (auto identity = expression.isIdentityExp)
            return compileBinaryExpression(identity, identityOperation(identity));

        if (isComparisonExpression(expression))
            return compileComparisonExpression(castComparisonExpression(expression));

        if (auto logical = expression.isLogicalExp) {
            if (isAndAnd(logical))
                return compileAndAnd(logical);
            if (isOrOr(logical))
                return compileOrOr(logical);
        }

        if (auto cast_ = expression.isCastExp)
            return compileCast(cast_);

        if (auto increment = expression.isPreExp)
            return compilePreIncrement(increment);

        if (auto addAssign = expression.isAddAssignExp)
            return compileAddAssign(addAssign);

        if (auto assign = expression.isAssignExp)
            return compileAssign(assign);

        if (auto real_ = expression.isRealExp)
            return compileReal(real_);

        if (auto string_ = expression.isStringExp)
            return compileString(string_);

        if (auto call = expression.isCallExp)
            return compileIntrinsicCall(call);

        if (auto dot = expression.isDotVarExp)
            return compileDotVarExpression(dot);

        if (auto typeid_ = expression.isTypeidExp)
            return compileTypeid(typeid_);

        if (auto not = expression.isNotExp)
            return compileUnaryExpression(not.e1, UnaryOperation.not_);

        if (auto negate = expression.isNegExp)
            return compileUnaryExpression(negate.e1, UnaryOperation.negate);

        if (auto add = expression.isAddExp)
            return compileBinaryExpression(add, BinaryOperation.add);

        if (auto subtract = expression.isMinExp)
            return compileBinaryExpression(subtract, BinaryOperation.subtract);

        if (auto multiply = expression.isMulExp)
            return compileBinaryExpression(multiply, BinaryOperation.multiply);

        if (auto divide = expression.isDivExp)
            return compileBinaryExpression(divide, BinaryOperation.divide);

        if (auto bitwiseOr = expression.isOrExp)
            return compileBinaryExpression(bitwiseOr, BinaryOperation.bitwiseOr);

        import std.string: fromStringz;

        throw new Exception(
            "Unsupported IR expression `" ~ expression.toChars.fromStringz.idup ~ "`",
        );
    }

    private Value compileIntrinsicCall(imported!"dmd.expression".CallExp call) {
        import quickbite.frontend.dmd.functions:
            hasNoAvailableSource, noAvailableSourceMessage;

        if (auto function_ = callFunction(call))
            if (!isImplementedBuiltin(function_)) {
                compileClassMethodReceiverCheck(call);
                if (hasNoAvailableSource(function_))
                    throw new Exception(noAvailableSourceMessage(function_));
                return compileCall(call, function_);
            }

        assert(call.f !is null);
        assert(call.arguments !is null);

        auto ref arguments = *call.arguments;
        switch (call.f.ident.toString) {
            case "fabs":
                assert(arguments.length == 1);
                return compileUnaryIntrinsic(
                    arguments[0],
                    UnaryIntrinsicOperation.fabs,
                );
            case "pow":
                assert(arguments.length == 2);
                return compileBinaryExpression(
                    arguments[0],
                    arguments[1],
                    BinaryOperation.pow,
                );
            default:
                assert(0);
        }
    }

    private void compileClassMethodReceiverCheck(
        imported!"dmd.expression".CallExp call,
    ) {
        auto dot = call.e1.isDotVarExp;
        if (dot is null)
            return;

        const receiver = compileExpression(dot.e1);
        instructions ~= Instruction(
            ThrowIfNull(
                receiver.id,
                "function call through null class reference `null`",
            ),
        );
    }

    private Value compileDotVarExpression(
        imported!"dmd.expression".DotVarExp dot,
    ) {
        const receiver = compileExpression(dot.e1);
        instructions ~= Instruction(
            ThrowIfNull(
                receiver.id,
                nullClassFieldMessage(dot),
            ),
        );
        instructions ~= Instruction(
            ThrowException("Unsupported IR field read."),
        );
        return compileIntegerLiteral(0);
    }

    private Value compileTypeid(imported!"dmd.expression".TypeidExp typeid_) {
        import dmd.dtemplate: isExpression;

        auto expression = isExpression(typeid_.obj);
        if (expression !is null) {
            const value = compileExpression(expression);
            instructions ~= Instruction(
                ThrowIfNull(
                    value.id,
                    nullTypeidMessage(expression),
                ),
            );
        }

        return compileString("ir.typeid");
    }

    private bool isImplementedBuiltin(FuncDeclaration function_) {
        import dmd.builtin: isBuiltin;
        import dmd.func: BUILTIN;

        with (BUILTIN) switch (isBuiltin(function_)) {
            case fabs:
            case pow:
                return true;

            default:
                return false;
        }
    }

    private Value compileCall(
        imported!"dmd.expression".CallExp call,
        FuncDeclaration function_,
    ) {
        uint[] arguments;
        RefWriteback[] refWritebacks;
        if (call.arguments !is null)
            foreach (i, argument; *call.arguments) {
                arguments ~= compileExpression(argument).id;
                const writeback = refWriteback(function_, i, argument);
                if (writeback.hasValue)
                    refWritebacks ~= writeback.value;
            }

        if (isVoid(call.type)) {
            instructions ~= Instruction(
                Call(
                    functionIndex(function_),
                    arguments,
                    refWritebacks,
                    false,
                    Value.init,
                ),
            );
            return Value.init;
        }

        const result = nextValue(valueType(call.type), resultKind(call.type));
        instructions ~= Instruction(
            Call(
                functionIndex(function_),
                arguments,
                refWritebacks,
                true,
                result,
            ),
        );
        return result;
    }

    private Value compileAssert(imported!"dmd.expression".AssertExp assert_) {
        if (hasLazyAssertMessage(assert_.msg))
            return compileAssertWithLazyMessage(assert_);

        const charResult = compileDmdAssertFailCharMessage(assert_.msg);
        if (charResult.hasValue)
            return charResult.value;

        if (auto equal = assertEqualExpression(assert_.e1))
            return compileAssertCompare(
                equal,
                equalityOperation(equal),
            );

        if (auto identity = assertIdentityExpression(assert_.e1))
            return compileAssertCompare(
                identity,
                identityOperation(identity),
            );

        if (auto comparison = assertComparisonExpression(assert_.e1))
            return compileAssertCompare(
                comparison,
                comparisonOperation(comparison),
            );

        const result = compileDmdAssertFailEqualMessage(assert_.msg);
        if (result.hasValue)
            return result.value;

        if (auto not = assert_.e1.isNotExp) {
            const condition = compileExpression(not.e1);
            instructions ~= Instruction(
                AssertFalse(
                    condition.id,
                    false,
                    0,
                ),
            );
            return condition;
        }

        const condition = compileExpression(assert_.e1);
        if (assert_.e1.isIntegerExp is null &&
            condition.resultKind == ResultKind.bool_)
            return compileAssertCompare(
                condition,
                compileIntegerLiteral(1, Type.i1, ResultKind.bool_),
                BinaryOperation.equal,
            );

        instructions ~= Instruction(
            AssertTrue(
                condition.id,
                assertFailureMessage(assert_.e1),
                false,
                0,
            ),
        );
        return condition;
    }

    private Value compileAssertWithLazyMessage(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        assert(assert_.msg !is null);
        return compileLazyAssertTrue(assert_.e1, assert_.msg);
    }

    private Value compileLazyAssertTrue(
        Expression conditionExpression,
        Expression messageExpression,
    ) {
        const condition = compileExpression(conditionExpression);
        const passBlock = cast(uint) blocks.length + 1;
        const failBlock = passBlock + 1;
        const joinBlock = failBlock + 1;
        finishBlock(Terminator(
            CondBranch(
                condition.id,
                passBlock,
                [],
                failBlock,
                [],
            ),
        ));

        finishBlock(Terminator(Branch(joinBlock, [condition.id])));

        const message = compileExpression(messageExpression);
        instructions ~= Instruction(
            AssertTrue(
                condition.id,
                null,
                true,
                message.id,
            ),
        );
        finishBlock(Terminator(Branch(joinBlock, [condition.id])));

        const result = nextValue(condition.type, condition.resultKind);
        currentBlockParams = [result];
        return result;
    }

    private bool hasLazyAssertMessage(Expression message) {
        return message !is null && !isDmdAssertFailCall(message);
    }

    private bool isDmdAssertFailCall(Expression expression) {
        import dmd.id: Id;

        auto call = expression.isCallExp;
        return call !is null &&
            call.f !is null &&
            call.f.ident == Id._d_assert_fail;
    }

    private OptionalValue compileDmdAssertFailCharMessage(Expression message) {
        if (message is null)
            return OptionalValue.init;

        auto call = message.isCallExp;
        if (call is null || call.arguments is null)
            return OptionalValue.init;

        if (call.arguments.length != 3)
            return OptionalValue.init;

        if (!isCharExpression((*call.arguments)[1]) ||
            !isCharExpression((*call.arguments)[2]))
            return OptionalValue.init;

        auto operator = (*call.arguments)[0].isStringExp;
        if (operator is null)
            return OptionalValue.init;

        const operatorText = operator.peekString;
        if (operatorText != "==" && operatorText != "!=")
            return OptionalValue.init;

        return OptionalValue(
            compileAssertCompare(
                (*call.arguments)[1],
                (*call.arguments)[2],
                operatorText == "==" ?
                    BinaryOperation.equal :
                    BinaryOperation.notEqual,
            ),
            true,
        );
    }

    private OptionalValue compileDmdAssertFailEqualMessage(Expression message) {
        if (message is null)
            return OptionalValue.init;

        auto call = message.isCallExp;
        if (call is null || call.arguments is null)
            return OptionalValue.init;

        if (call.arguments.length != 3)
            return OptionalValue.init;

        auto operator = (*call.arguments)[0].isStringExp;
        if (operator is null)
            return OptionalValue.init;

        const operatorText = operator.peekString;
        if (operatorText != "==" && operatorText != "!=")
            return OptionalValue.init;

        return OptionalValue(
            compileAssertCompare(
                (*call.arguments)[1],
                (*call.arguments)[2],
                operatorText == "==" ?
                    BinaryOperation.equal :
                    BinaryOperation.notEqual,
            ),
            true,
        );
    }

    private Value compileAssertCompare(
        BinExp expression,
        in BinaryOperation operation,
        in OptionalValue message = OptionalValue.init,
    ) {
        return compileAssertCompare(
            expression.e1,
            expression.e2,
            operation,
            message,
        );
    }

    private Value compileAssertCompare(
        Expression lhsExpression,
        Expression rhsExpression,
        in BinaryOperation operation,
        in OptionalValue message = OptionalValue.init,
    ) {
        const lhs = compileExpression(lhsExpression);
        const rhs = compileExpression(rhsExpression);
        return compileAssertCompare(
            lhs,
            rhs,
            operation,
            message,
            assertionResultKind(lhsExpression, rhsExpression, lhs.resultKind),
        );
    }

    private Value compileAssertCompare(
        in Value lhs,
        in Value rhs,
        in BinaryOperation operation,
        in OptionalValue message = OptionalValue.init,
        in ResultKind diagnosticKind = ResultKind.init,
    ) {
        const result = compileBinaryExpression(lhs, rhs, operation);
        const resultKind = diagnosticKind == ResultKind.init ?
            lhs.resultKind :
            diagnosticKind;
        instructions ~= Instruction(
            AssertCompare(
                operation,
                lhs.type,
                resultKind,
                result.id,
                lhs.id,
                rhs.id,
                message.hasValue,
                message.value.id,
            ),
        );
        return result;
    }

    private Value compileVariableDeclaration(VarDeclaration variable) {
        if (variable._init !is null && isVoidInitializer(variable._init)) {
            localIndex(variable);
            localInfos[variable] = LocalInfo(
                valueType(variable.type),
                resultKind(variable.type),
                true,
            );
            return compileDefaultValue(variable.type);
        }

        const value = variable._init is null ?
            compileDefaultValue(variable.type) :
            compileInitializer(variable._init);
        instructions ~= Instruction(
            Store(
                localIndex(variable),
                value.type,
                value.id,
            ),
        );
        localInfos[variable] = LocalInfo(value.type, value.resultKind, false);
        return value;
    }

    private Value compileVariableLoad(VarDeclaration variable) {
        const local = localInfo(variable);
        const result = nextValue(local.type, local.resultKind);
        instructions ~= Instruction(
            Load(
                localIndex(variable),
                result,
                local.uninitialized ?
                    uninitializedVariableMessage(variable, currentFunction) :
                    null,
            ),
        );
        return result;
    }

    private Value compileInitializer(
        imported!"dmd.init".Initializer initializer,
    ) {
        auto expression = initializer.isExpInitializer;
        assert(expression !is null);

        auto initializer_ = initializerExpression(expression.exp);
        if (initializer_.isVoidInitExp !is null)
            return compileDefaultValue(expression.exp.type);

        return compileExpression(initializer_);
    }

    private Value compileCast(imported!"dmd.expression".CastExp cast_) {
        const source = compileExpression(cast_.e1);
        const targetType = valueType(cast_.to);
        if (source.resultKind == ResultKind.string_ && targetType == Type.ptr)
            return source;

        if (source.type == Type.i1 && targetType == Type.i32)
            return source;

        const result = nextValue(targetType, resultKind(cast_.to));
        instructions ~= Instruction(
            Cast(
                source.type,
                source.id,
                result,
            ),
        );
        return result;
    }

    private Value compilePreIncrement(imported!"dmd.expression".PreExp increment) {
        auto variable = increment.e1.isVarExp;
        assert(variable !is null);

        auto declaration = variable.var.isVarDeclaration;
        assert(declaration !is null);

        const lhs = compileVariableLoad(declaration);
        const rhs = compileIntegerLiteral(1);
        const result = nextValue(lhs.type, lhs.resultKind);
        instructions ~= Instruction(
            BinaryOp(
                BinaryOperation.add,
                lhs.type,
                lhs.id,
                rhs.id,
                result,
            ),
        );
        instructions ~= Instruction(
            Store(
                localIndex(declaration),
                result.type,
                result.id,
            ),
        );
        localInfos[declaration] = LocalInfo(
            result.type,
            result.resultKind,
            false,
        );
        return result;
    }

    private Value compileAddAssign(AddAssignExp addAssign) {
        auto variable = addAssign.e1.isVarExp;
        assert(variable !is null);

        auto declaration = variable.var.isVarDeclaration;
        assert(declaration !is null);

        const lhs = compileVariableLoad(declaration);
        const rhs = compileExpression(addAssign.e2);
        const result = nextValue(lhs.type, lhs.resultKind);
        instructions ~= Instruction(
            BinaryOp(
                BinaryOperation.add,
                lhs.type,
                lhs.id,
                rhs.id,
                result,
            ),
        );
        instructions ~= Instruction(
            Store(
                localIndex(declaration),
                result.type,
                result.id,
            ),
        );
        localInfos[declaration] = LocalInfo(
            result.type,
            result.resultKind,
            false,
        );
        return result;
    }

    private Value compileAssign(AssignExp assign) {
        auto variable = assign.e1.isVarExp;
        assert(variable !is null);

        auto declaration = variable.var.isVarDeclaration;
        assert(declaration !is null);

        const result = compileExpression(assign.e2);
        instructions ~= Instruction(
            Store(
                localIndex(declaration),
                result.type,
                result.id,
            ),
        );
        localInfos[declaration] = LocalInfo(
            result.type,
            result.resultKind,
            false,
        );
        return result;
    }

    private Value compileInteger(
        imported!"dmd.expression".IntegerExp integer,
    ) {
        return compileIntegerLiteral(
            integer.getInteger,
            valueType(integer.type),
            resultKind(integer.type),
        );
    }

    private Value compileIntegerLiteral(
        in ulong bits,
        in Type type = Type.i32,
        in ResultKind resultKind = ResultKind.int_,
    ) {
        const result = nextValue(type, resultKind);
        instructions ~= Instruction(
            Const(
                bits,
                result,
            ),
        );
        return result;
    }

    private Value compileNull(imported!"dmd.mtype".Type type) {
        return compileIntegerLiteral(0, valueType(type), resultKind(type));
    }

    private Value compileDefaultValue(imported!"dmd.mtype".Type type) {
        return compileIntegerLiteral(0, valueType(type), resultKind(type));
    }

    private Value compileReal(imported!"dmd.expression".RealExp real_) {
        import dmd.astenums: TY;

        switch (real_.type.toBasetype.ty) with (TY) {
            case Tfloat32:
                return compileRealLiteral!Tfloat32(real_.toReal);
            case Tfloat64:
                return compileRealLiteral!Tfloat64(real_.toReal);
            default:
                assert(0);
        }
    }

    private Value compileRealLiteral(imported!"dmd.astenums".TY type)(
        in real value,
    ) {
        import quickbite.backends.ir.bits: floatingBits;
        import quickbite.frontend.dmd.types: dmdScalarType;

        alias Scalar = dmdScalarType!type;
        const result = nextValue(valueType!type, resultKind!type);
        instructions ~= Instruction(
            Const(
                floatingBits(cast(Scalar) value),
                result,
            ),
        );
        return result;
    }

    private Value compileString(imported!"dmd.expression".StringExp string_) {
        return compileString(string_.peekString.idup);
    }

    private Value compileString(in string value) {
        const result = nextValue(Type.ptr, ResultKind.string_);
        instructions ~= Instruction(
            StringConst(
                value,
                result,
            ),
        );
        return result;
    }

    private Value compileUnaryExpression(
        Expression expression,
        in UnaryOperation operation,
    ) {
        const source = compileExpression(expression);
        const result = nextValue(source.type, source.resultKind);
        instructions ~= Instruction(
            UnaryOp(
                operation,
                source.type,
                source.id,
                result,
            ),
        );
        return result;
    }

    private Value compileUnaryIntrinsic(
        Expression expression,
        in UnaryIntrinsicOperation operation,
    ) {
        const source = compileExpression(expression);
        const result = nextValue(source.type, source.resultKind);
        instructions ~= Instruction(
            UnaryIntrinsicOp(
                operation,
                source.type,
                source.id,
                result,
            ),
        );
        return result;
    }

    private Value compileAndAnd(imported!"dmd.expression".LogicalExp expression) {
        const lhs = compileExpression(expression.e1);
        const rhsBlock = cast(uint) blocks.length + 1;
        const falseBlock = rhsBlock + 1;
        const joinBlock = falseBlock + 1;
        finishBlock(Terminator(
            CondBranch(
                lhs.id,
                rhsBlock,
                [],
                falseBlock,
                [],
            ),
        ));

        const rhs = compileExpression(expression.e2);
        finishBlock(Terminator(Branch(joinBlock, [rhs.id])));

        const false_ = compileIntegerLiteral(0, Type.i1, ResultKind.bool_);
        finishBlock(Terminator(Branch(joinBlock, [false_.id])));

        const result = nextValue(Type.i1, ResultKind.bool_);
        currentBlockParams = [result];
        return result;
    }

    private Value compileOrOr(imported!"dmd.expression".LogicalExp expression) {
        const lhs = compileExpression(expression.e1);
        const trueBlock = cast(uint) blocks.length + 1;
        const rhsBlock = trueBlock + 1;
        const joinBlock = rhsBlock + 1;
        finishBlock(Terminator(
            CondBranch(
                lhs.id,
                trueBlock,
                [],
                rhsBlock,
                [],
            ),
        ));

        const true_ = compileIntegerLiteral(1, Type.i1, ResultKind.bool_);
        finishBlock(Terminator(Branch(joinBlock, [true_.id])));

        const rhs = compileExpression(expression.e2);
        finishBlock(Terminator(Branch(joinBlock, [rhs.id])));

        const result = nextValue(Type.i1, ResultKind.bool_);
        currentBlockParams = [result];
        return result;
    }

    private Value compileBinaryExpression(
        BinExp expression,
        in BinaryOperation operation,
    ) {
        return compileBinaryExpression(expression.e1, expression.e2, operation);
    }

    private Value compileComparisonExpression(CmpExp expression) {
        return compileBinaryExpression(expression, comparisonOperation(expression));
    }

    private Value compileBinaryExpression(
        Expression lhsExpression,
        Expression rhsExpression,
        in BinaryOperation operation,
    ) {
        const lhs = compileExpression(lhsExpression);
        const rhs = compileExpression(rhsExpression);
        return compileBinaryExpression(lhs, rhs, operation);
    }

    private Value compileBinaryExpression(
        in Value lhs,
        in Value rhs,
        in BinaryOperation operation,
    ) {
        const result = isBoolResult(operation) ?
            nextValue(Type.i1, ResultKind.bool_) :
            nextValue(lhs.type, lhs.resultKind);
        instructions ~= Instruction(
            BinaryOp(
                operation,
                lhs.type,
                lhs.id,
                rhs.id,
                result,
            ),
        );
        return result;
    }

    private void finishBlock(Terminator terminator) {
        blocks ~= Block(
            currentBlockParams,
            instructions,
            terminator,
        );
        instructions = null;
        currentBlockParams = null;
    }

    private Value nextValue(
        in Type type,
        in ResultKind resultKind = ResultKind.int_,
    ) @safe @nogc nothrow pure {
        const result = Value(nextValueId, type, resultKind);
        ++nextValueId;
        return result;
    }

    private uint localIndex(VarDeclaration variable) {
        if (auto existing = variable in locals)
            return *existing;

        const index = cast(uint) locals.length;
        locals[variable] = index;
        return index;
    }

    private uint functionIndex(FuncDeclaration function_) {
        if (auto existing = function_ in functionIndices)
            return *existing;

        const index = cast(uint) functions.length;
        functions ~= function_;
        functionIndices[function_] = index;
        return index;
    }

    private FuncDeclaration callFunction(imported!"dmd.expression".CallExp call) {
        if (call.f !is null)
            return call.f;

        if (auto variable = call.e1.isVarExp)
            return variable.var.isFuncDeclaration;

        return null;
    }

    private OptionalRefWriteback refWriteback(
        FuncDeclaration function_,
        in size_t parameterIndex,
        Expression argument,
    ) {
        if (function_.parameters is null ||
            parameterIndex >= function_.parameters.length)
            return OptionalRefWriteback.init;

        auto parameter = (*function_.parameters)[parameterIndex];
        if (!isRefParameter(parameter))
            return OptionalRefWriteback.init;

        auto variable = argument.isVarExp;
        assert(variable !is null);

        auto declaration = variable.var.isVarDeclaration;
        assert(declaration !is null);

        const info = localInfo(declaration);
        return OptionalRefWriteback(
            RefWriteback(
                cast(uint) parameterIndex,
                localIndex(declaration),
                info.type,
            ),
            true,
        );
    }

    private void registerParameters(FuncDeclaration function_) {
        if (function_.parameters is null)
            return;

        foreach (parameter; *function_.parameters) {
            localIndex(parameter);
            localInfos[parameter] = LocalInfo(
                valueType(parameter.type),
                resultKind(parameter.type),
                false,
            );
        }
    }

    private LocalInfo localInfo(VarDeclaration variable) {
        if (auto existing = variable in localInfos)
            return *existing;

        return LocalInfo(
            valueType(variable.type),
            resultKind(variable.type),
            false,
        );
    }

    private Function makeFunction(in Value result) {
        finishBlock(Terminator(ReturnValue(result.id)));
        return Function(
            blocks,
            result.resultKind,
            nextValueId,
            cast(uint) locals.length,
            [],
        );
    }

    private Function makeVoidFunction() {
        finishBlock(Terminator(ReturnVoid()));
        return Function(
            blocks,
            ResultKind.int_,
            nextValueId,
            cast(uint) locals.length,
            [],
        );
    }
}

private bool isVoid(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tvoid;
}

private bool isAndAnd(imported!"dmd.expression".LogicalExp expression) {
    import dmd.tokens: EXP;

    return expression.op == EXP.andAnd;
}

private bool isOrOr(imported!"dmd.expression".LogicalExp expression) {
    import dmd.tokens: EXP;

    return expression.op == EXP.orOr;
}

private bool isComparisonExpression(imported!"dmd.expression".Expression expression) {
    import dmd.tokens: EXP;

    return expression.op == EXP.lessThan ||
        expression.op == EXP.lessOrEqual ||
        expression.op == EXP.greaterThan ||
        expression.op == EXP.greaterOrEqual;
}

private imported!"dmd.expression".CmpExp castComparisonExpression(
    imported!"dmd.expression".Expression expression,
) {
    auto comparison = cast(imported!"dmd.expression".CmpExp) expression;
    if (comparison is null)
        throw new Exception("Unsupported IR comparison expression.");

    return comparison;
}

private bool isBoolResult(
    in imported!"quickbite.backends.ir.language".BinaryOperation operation,
)
    @safe pure nothrow
{
    import quickbite.backends.ir.language: BinaryOperation;

    final switch (operation) with (BinaryOperation) {
        case equal:
        case notEqual:
        case lessThan:
        case lessOrEqual:
        case greaterThan:
        case greaterOrEqual:
            return true;
        case add:
        case subtract:
        case multiply:
        case divide:
        case bitwiseOr:
        case pow:
            return false;
    }
}

private imported!"dmd.expression".EqualExp assertEqualExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (auto equal = expression.isEqualExp)
        return equal;

    if (auto comma = expression.isCommaExp)
        return assertEqualExpression(comma.e2);

    if (auto cast_ = expression.isCastExp)
        return assertEqualExpression(cast_.e1);

    return null;
}

private imported!"dmd.expression".CmpExp assertComparisonExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (isComparisonExpression(expression))
        return castComparisonExpression(expression);

    if (auto comma = expression.isCommaExp)
        return assertComparisonExpression(comma.e2);

    if (auto cast_ = expression.isCastExp)
        return assertComparisonExpression(cast_.e1);

    return null;
}

private imported!"dmd.expression".IdentityExp assertIdentityExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (auto identity = expression.isIdentityExp)
        return identity;

    if (auto comma = expression.isCommaExp)
        return assertIdentityExpression(comma.e2);

    if (auto cast_ = expression.isCastExp)
        return assertIdentityExpression(cast_.e1);

    return null;
}

private imported!"quickbite.backends.ir.language".BinaryOperation equalityOperation(
    imported!"dmd.expression".EqualExp equal,
) @safe pure {
    import dmd.tokens: EXP;
    import quickbite.backends.ir.language: BinaryOperation;

    return equal.op == EXP.notEqual ?
        BinaryOperation.notEqual :
        BinaryOperation.equal;
}

private imported!"quickbite.backends.ir.language".BinaryOperation identityOperation(
    imported!"dmd.expression".IdentityExp identity,
) @safe pure {
    import dmd.tokens: EXP;
    import quickbite.backends.ir.language: BinaryOperation;

    return identity.op == EXP.notIdentity ?
        BinaryOperation.notEqual :
        BinaryOperation.equal;
}

private imported!"quickbite.backends.ir.language".BinaryOperation comparisonOperation(
    imported!"dmd.expression".CmpExp comparison,
) @safe pure {
    import dmd.tokens: EXP;
    import quickbite.backends.ir.language: BinaryOperation;

    with (EXP) switch (comparison.op) {
        case lessThan:
            return BinaryOperation.lessThan;
        case lessOrEqual:
            return BinaryOperation.lessOrEqual;
        case greaterThan:
            return BinaryOperation.greaterThan;
        case greaterOrEqual:
            return BinaryOperation.greaterOrEqual;
        default:
            assert(0);
    }
}

private imported!"quickbite.backends.ir.language".ResultKind assertionResultKind(
    imported!"dmd.expression".Expression lhs,
    imported!"dmd.expression".Expression rhs,
    in imported!"quickbite.backends.ir.language".ResultKind fallback,
) {
    import quickbite.backends.ir.language: ResultKind;

    return isCharExpression(lhs) && isCharExpression(rhs) ?
        ResultKind.char_ :
        fallback;
}

private bool isCharExpression(imported!"dmd.expression".Expression expression) {
    import dmd.astenums: TY;

    if (auto comma = expression.isCommaExp)
        return isCharExpression(comma.e2);

    if (auto cast_ = expression.isCastExp)
        return isCharExpression(cast_.e1);

    const type = expression.type is null ? null : expression.type.toBasetype;
    return type !is null && type.ty == TY.Tchar;
}

private string assertFailureMessage(imported!"dmd.expression".Expression expression) {
    import std.array: replace;
    import std.conv: text;

    return text(
        "`assert(",
        expressionText(expression).replace("()", ""),
        ")` failed",
    );
}

private string expressionText(imported!"dmd.expression".Expression expression) {
    import std.string: fromStringz;

    return expression.toChars.fromStringz.idup;
}

private string nullTypeidMessage(imported!"dmd.expression".Expression expression) {
    import std.conv: text;

    return text(
        "null pointer dereference evaluating typeid. `",
        receiverName(expression),
        "` is `null`",
    );
}

private string nullClassFieldMessage(
    imported!"dmd.expression".DotVarExp dot,
) {
    import std.conv: text;

    return text(
        "class `",
        receiverName(dot.e1),
        "` is `null` and cannot be dereferenced",
    );
}

private string receiverName(imported!"dmd.expression".Expression receiver) {
    auto variable = receiver.isVarExp;
    if (variable is null)
        return "null";

    return variable.var.ident.toString.idup;
}

private imported!"quickbite.backends.ir.language".Function withFunctions(
    imported!"quickbite.backends.ir.language".Function function_,
    imported!"quickbite.backends.ir.language".Function[] functions,
) @safe pure {
    function_.functions = functions;
    return function_;
}

private struct OptionalValue {
    public imported!"quickbite.backends.ir.language".Value value;
    public bool hasValue;
}

private struct OptionalRefWriteback {
    public imported!"quickbite.backends.ir.language".RefWriteback value;
    public bool hasValue;
}

private struct LocalInfo {
    public imported!"quickbite.backends.ir.language".Type type;
    public imported!"quickbite.backends.ir.language".ResultKind resultKind;
    public bool uninitialized;
}

private bool isVoidInitializer(imported!"dmd.init".Initializer initializer) {
    if (initializer.isVoidInitializer !is null)
        return true;

    auto expression = initializer.isExpInitializer;
    return expression !is null &&
        initializerExpression(expression.exp).isVoidInitExp !is null;
}

private string uninitializedVariableMessage(
    imported!"dmd.declaration".VarDeclaration variable,
    imported!"dmd.func".FuncDeclaration currentFunction,
) {
    import quickbite.backends.interpreter.messages:
        uninitializedVariableMessage;

    return uninitializedVariableMessage(variable, currentFunction);
}

private bool isRefParameter(imported!"dmd.declaration".VarDeclaration parameter) {
    import dmd.astenums: STC;

    return (parameter.storage_class & STC.ref_) != STC.none;
}

private imported!"dmd.expression".Expression initializerExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (auto assignment = expression.isAssignExp)
        return assignment.e2;

    if (auto construct = expression.isConstructExp)
        return construct.e2;

    if (auto blit = expression.isBlitExp)
        return blit.e2;

    return expression;
}

private string newExceptionMessage(imported!"dmd.expression".Expression expression) {
    auto new_ = expression is null ? null : expression.isNewExp;
    if (new_ is null || new_.arguments is null || new_.arguments.length == 0)
        throw new Exception("Unsupported IR throw expression.");

    auto message = (*new_.arguments)[0].isStringExp;
    if (message is null)
        throw new Exception("Unsupported IR throw expression.");

    return message.peekString.idup;
}

private imported!"quickbite.backends.ir.language".Type valueType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import quickbite.backends.ir.language: Type;

    switch (type.toBasetype.ty) with (TY) {
        case Tbool:
            return valueType!Tbool;
        case Tint8:
            return valueType!Tint8;
        case Tuns8:
            return valueType!Tuns8;
        case Tchar:
            return valueType!Tchar;
        case Tint16:
            return valueType!Tint16;
        case Tuns16:
            return valueType!Tuns16;
        case Tint32:
            return valueType!Tint32;
        case Tuns32:
            return valueType!Tuns32;
        case Tint64:
            return valueType!Tint64;
        case Tuns64:
            return valueType!Tuns64;
        case Tfloat32:
            return valueType!Tfloat32;
        case Tfloat64:
            return valueType!Tfloat64;
        case Tarray:
            if (isStringType(type))
                return Type.ptr;
            goto default;
        case Tclass:
        case Tnull:
            return Type.ptr;
        default:
            assert(0);
    }
}

private imported!"quickbite.backends.ir.language".Type valueType(
    imported!"dmd.astenums".TY type,
)() {
    import dmd.astenums: TY;
    import quickbite.backends.ir.language: Type;
    import quickbite.frontend.dmd.types: dmdScalarType;

    alias Scalar = dmdScalarType!type;
    static if (type == TY.Tbool)
        return Type.i1;
    else static if (type == TY.Tfloat32)
        return Type.f32;
    else static if (type == TY.Tfloat64)
        return Type.f64;
    else static if (Scalar.sizeof == ubyte.sizeof)
        return Type.i8;
    else static if (Scalar.sizeof == ushort.sizeof)
        return Type.i16;
    else static if (Scalar.sizeof == uint.sizeof)
        return Type.i32;
    else static if (Scalar.sizeof == ulong.sizeof)
        return Type.i64;
    else
        static assert(false, "Unsupported IR scalar type.");
}

private imported!"quickbite.backends.ir.language".ResultKind resultKind(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import quickbite.backends.ir.language: ResultKind;

    switch (type.toBasetype.ty) with (TY) {
        case Tbool:
            return resultKind!Tbool;
        case Tint8:
            return resultKind!Tint8;
        case Tuns8:
            return resultKind!Tuns8;
        case Tchar:
            return resultKind!Tchar;
        case Tint16:
            return resultKind!Tint16;
        case Tuns16:
            return resultKind!Tuns16;
        case Tint32:
            return resultKind!Tint32;
        case Tuns32:
            return resultKind!Tuns32;
        case Tint64:
            return resultKind!Tint64;
        case Tuns64:
            return resultKind!Tuns64;
        case Tfloat32:
            return resultKind!Tfloat32;
        case Tfloat64:
            return resultKind!Tfloat64;
        case Tarray:
            if (isStringType(type))
                return ResultKind.string_;
            goto default;
        case Tclass:
        case Tnull:
            return ResultKind.class_;
        default:
            assert(0);
    }
}

private bool isStringType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type.toBasetype.ty != TY.Tarray)
        return false;

    auto element = type.toBasetype.nextOf;
    return element !is null && element.toBasetype.ty == TY.Tchar;
}

private imported!"quickbite.backends.ir.language".ResultKind resultKind(
    imported!"dmd.astenums".TY type,
)() {
    import quickbite.backends.ir.language: ResultKind;
    import quickbite.frontend.dmd.types: dmdScalarType;

    alias Scalar = dmdScalarType!type;
    static if (is(Scalar == bool))
        return ResultKind.bool_;
    else static if (is(Scalar == byte))
        return ResultKind.byte_;
    else static if (is(Scalar == ubyte))
        return ResultKind.ubyte_;
    else static if (is(Scalar == char))
        return ResultKind.char_;
    else static if (is(Scalar == short))
        return ResultKind.short_;
    else static if (is(Scalar == ushort))
        return ResultKind.ushort_;
    else static if (is(Scalar == int))
        return ResultKind.int_;
    else static if (is(Scalar == uint))
        return ResultKind.uint_;
    else static if (is(Scalar == long))
        return ResultKind.long_;
    else static if (is(Scalar == ulong))
        return ResultKind.ulong_;
    else static if (is(Scalar == float))
        return ResultKind.float_;
    else static if (is(Scalar == double))
        return ResultKind.double_;
    else
        static assert(false, "Unsupported IR result type.");
}

module quickbite.backends.ir.compiler;

private:

package imported!"quickbite.backends.ir.language".Function compileExpression(
    in string expr,
)
{
    import quickbite.frontend.compiler: parseExpression;

    return compileExpression(parseExpression(expr));
}

package imported!"quickbite.backends.ir.language".Function compileEvalSource(
    in string source,
)
{
    import quickbite.frontend.cell: parseEvalSource;

    return compileFunction(parseEvalSource(source).function_);
}

package imported!"quickbite.backends.ir.language".Function compileUnitTest(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    Compiler compiler;
    return compiler.compileEntryFunction(unitTest);
}

private imported!"quickbite.backends.ir.language".Function compileExpression(
    imported!"dmd.expression".Expression expression,
) {
    Compiler compiler;
    const result = compiler.compileExpression(expression);
    return compiler.makeFunction(result);
}

private imported!"quickbite.backends.ir.language".Function compileFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    Compiler compiler;
    return compiler.compileEntryFunction(function_);
}

private struct Compiler {
    import dmd.expression: AddAssignExp, BinExp, CmpExp, Expression;
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
        ResultKind,
        ReturnValue,
        StringConst,
        Store,
        Terminator,
        ThrowException,
        Type,
        UnaryIntrinsicOp,
        UnaryIntrinsicOperation,
        UnaryOp,
        UnaryOperation,
        Value;

    private Instruction[] instructions;
    private uint[VarDeclaration] locals;
    private Value[VarDeclaration] localValues;
    private FuncDeclaration[] functions;
    private uint[FuncDeclaration] functionIndices;
    private Function[] compiledFunctions;
    private Block[] blocks;
    private Value[] currentBlockParams;
    private uint currentBlockId;
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
        localValues = null;
        blocks = null;
        currentBlockParams = null;
        currentBlockId = 0;
        nextValueId = 0;
        registerParameters(function_);

        const result = compileStatement(function_.fbody);
        assert(result.hasValue);
        return makeFunction(result.value, parameterCount(function_));
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

        if (auto throw_ = statement.isThrowStatement)
            return OptionalValue(compileThrow(throw_), true);

        if (statement.isImportStatement)
            return OptionalValue.init;

        import std.conv: text;

        throw new Exception(
            text("Unsupported IR statement: ", statement.stmt),
        );
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

        if (auto declaration = expression.isDeclarationExp) {
            auto variable = declaration.declaration.isVarDeclaration;
            assert(variable !is null);
            compileVariableDeclaration(variable);
            return localValue(variable);
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
            return compileBinaryExpression(equal, BinaryOperation.equal);

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

        if (auto real_ = expression.isRealExp)
            return compileReal(real_);

        if (auto string_ = expression.isStringExp)
            return compileString(string_);

        if (auto call = expression.isCallExp)
            return compileIntrinsicCall(call);

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
        if (auto function_ = callFunction(call))
            if (!isImplementedBuiltin(function_)) {
                if (function_.fbody is null)
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
        if (call.arguments !is null)
            foreach (argument; *call.arguments)
                arguments ~= compileExpression(argument).id;

        const result = nextValue(valueType(call.type), resultKind(call.type));
        instructions ~= Instruction(
            Call(
                functionIndex(function_),
                arguments,
                result,
            ),
        );
        return result;
    }

    private Value compileAssert(imported!"dmd.expression".AssertExp assert_) {
        if (auto equal = assertEqualExpression(assert_.e1))
            return compileAssertCompare(equal, BinaryOperation.equal);

        const result = compileDmdAssertFailEqualMessage(assert_.msg);
        if (result.hasValue)
            return result.value;

        if (auto not = assert_.e1.isNotExp) {
            const condition = compileExpression(not.e1);
            instructions ~= Instruction(AssertFalse(condition.id));
            return condition;
        }

        const condition = compileExpression(assert_.e1);
        instructions ~= Instruction(
            AssertTrue(condition.id, assertFailureMessage(assert_.e1)),
        );
        return condition;
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
        if (operator is null || operator.peekString != "==")
            return OptionalValue.init;

        return OptionalValue(
            compileAssertCompare(
                (*call.arguments)[1],
                (*call.arguments)[2],
                BinaryOperation.equal,
            ),
            true,
        );
    }

    private Value compileAssertCompare(
        BinExp expression,
        in BinaryOperation operation,
    ) {
        return compileAssertCompare(expression.e1, expression.e2, operation);
    }

    private Value compileAssertCompare(
        Expression lhsExpression,
        Expression rhsExpression,
        in BinaryOperation operation,
    ) {
        const lhs = compileExpression(lhsExpression);
        const rhs = compileExpression(rhsExpression);
        const result = compileBinaryExpression(lhs, rhs, operation);
        instructions ~= Instruction(
            AssertCompare(
                operation,
                lhs.type,
                lhs.resultKind,
                lhs.id,
                rhs.id,
            ),
        );
        return result;
    }

    private void compileVariableDeclaration(VarDeclaration variable) {
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
        localValues[variable] = Value(0, value.type, value.resultKind);
    }

    private Value compileVariableLoad(VarDeclaration variable) {
        const local = localValue(variable);
        const result = nextValue(local.type, local.resultKind);
        instructions ~= Instruction(
            Load(
                localIndex(variable),
                result,
            ),
        );
        return result;
    }

    private Value compileInitializer(
        imported!"dmd.init".Initializer initializer,
    ) {
        auto expression = initializer.isExpInitializer;
        assert(expression !is null);

        return compileExpression(initializerExpression(expression.exp));
    }

    private Value compileCast(imported!"dmd.expression".CastExp cast_) {
        const source = compileExpression(cast_.e1);
        const targetType = valueType(cast_.to);
        if (source.type == Type.i1 && targetType == Type.i32)
            return source;

        const result = nextValue(targetType, resultKind(cast_.to));
        instructions ~= Instruction(
            Cast(
                source.type,
                result.type,
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
        const result = nextValue(Type.ptr, ResultKind.string_);
        instructions ~= Instruction(
            StringConst(
                string_.peekString.idup,
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

        currentBlockId = rhsBlock;
        currentBlockParams = null;
        const rhs = compileExpression(expression.e2);
        finishBlock(Terminator(Branch(joinBlock, [rhs.id])));

        currentBlockId = falseBlock;
        currentBlockParams = null;
        const false_ = compileIntegerLiteral(0, Type.i1, ResultKind.bool_);
        finishBlock(Terminator(Branch(joinBlock, [false_.id])));

        currentBlockId = joinBlock;
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

        currentBlockId = trueBlock;
        currentBlockParams = null;
        const true_ = compileIntegerLiteral(1, Type.i1, ResultKind.bool_);
        finishBlock(Terminator(Branch(joinBlock, [true_.id])));

        currentBlockId = rhsBlock;
        currentBlockParams = null;
        const rhs = compileExpression(expression.e2);
        finishBlock(Terminator(Branch(joinBlock, [rhs.id])));

        currentBlockId = joinBlock;
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
        import dmd.tokens: EXP;

        if (expression.op == EXP.lessThan)
            return compileBinaryExpression(expression, BinaryOperation.lessThan);

        if (expression.op == EXP.greaterThan)
            return compileBinaryExpression(expression, BinaryOperation.greaterThan);

        import std.conv: text;
        throw new Exception(text(
            "Unsupported IR comparison: ",
            expression.op,
        ));
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
            currentBlockId,
            currentBlockParams,
            instructions,
            terminator,
            false,
            0,
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

    private uint parameterCount(FuncDeclaration function_) {
        return function_.parameters is null ?
            0 :
            cast(uint) function_.parameters.length;
    }

    private void registerParameters(FuncDeclaration function_) {
        if (function_.parameters is null)
            return;

        foreach (parameter; *function_.parameters) {
            localIndex(parameter);
            localValues[parameter] = Value(
                0,
                valueType(parameter.type),
                resultKind(parameter.type),
            );
        }
    }

    private Value localValue(VarDeclaration variable) {
        if (auto existing = variable in localValues)
            return *existing;

        return Value(0, valueType(variable.type), resultKind(variable.type));
    }

    private Function makeFunction(in Value result, in uint parameterCount = 0) {
        if (blocks.length != 0) {
            blocks ~= Block(
                currentBlockId,
                currentBlockParams,
                instructions,
                Terminator(ReturnValue(result.id)),
                false,
                0,
            );
            return Function(
                blocks,
                result.resultKind,
                nextValueId,
                cast(uint) locals.length,
                parameterCount,
                [],
            );
        }

        return Function(
            [
                Block(
                    0,
                    [],
                    instructions,
                    Terminator(ReturnValue(result.id)),
                    false,
                    0,
                ),
            ],
            result.resultKind,
            nextValueId,
            cast(uint) locals.length,
            parameterCount,
            [],
        );
    }
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
        expression.op == EXP.greaterThan;
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
        case lessThan:
        case greaterThan:
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

private string noAvailableSourceMessage(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    return text(
        "`",
        function_.toChars,
        "` cannot be interpreted at compile time, ",
        "because it has no available source code",
    );
}

private imported!"quickbite.backends.ir.language".Type valueType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;

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
        default:
            assert(0);
    }
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

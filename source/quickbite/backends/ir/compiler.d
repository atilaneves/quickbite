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

private imported!"quickbite.backends.ir.language".Function compileExpression(
    imported!"dmd.expression".Expression expression,
) {
    Compiler compiler;
    const result = compiler.compileExpression(expression);
    return compiler.function_(result);
}

private imported!"quickbite.backends.ir.language".Function compileFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    Compiler compiler;
    const result = compiler.compileStatement(function_.fbody);
    assert(result.hasValue);
    return compiler.function_(result.value);
}

private struct Compiler {
    import dmd.expression: AddAssignExp, BinExp, Expression;
    import dmd.declaration: VarDeclaration;
    import quickbite.backends.ir.language:
        BinaryOp,
        BinaryOperation,
        Block,
        Cast,
        Const,
        Function,
        Instruction,
        Load,
        ResultKind,
        ReturnValue,
        StringConst,
        Store,
        Terminator,
        Type,
        UnaryIntrinsicOp,
        UnaryIntrinsicOperation,
        UnaryOp,
        UnaryOperation,
        Value;

    private Instruction[] instructions;
    private uint[VarDeclaration] locals;
    private Value[VarDeclaration] localValues;
    private uint nextValueId;

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

        if (statement.isImportStatement)
            return OptionalValue.init;

        assert(0);
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

        assert(0);
    }

    private Value compileIntrinsicCall(imported!"dmd.expression".CallExp call) {
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
        const result = nextValue(valueType(cast_.to), resultKind(cast_.to));
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

    private Value compileBinaryExpression(
        BinExp expression,
        in BinaryOperation operation,
    ) {
        return compileBinaryExpression(expression.e1, expression.e2, operation);
    }

    private Value compileBinaryExpression(
        Expression lhsExpression,
        Expression rhsExpression,
        in BinaryOperation operation,
    ) {
        const lhs = compileExpression(lhsExpression);
        const rhs = compileExpression(rhsExpression);
        const result = nextValue(lhs.type, lhs.resultKind);
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

    private Value localValue(VarDeclaration variable) {
        if (auto existing = variable in localValues)
            return *existing;

        return Value(0, valueType(variable.type), resultKind(variable.type));
    }

    private Function function_(in Value result) {
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
        );
    }
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

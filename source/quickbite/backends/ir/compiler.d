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
        ResultType,
        ReturnValue,
        Store,
        Terminator,
        Type,
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

    private void compileVariableDeclaration(VarDeclaration variable) {
        const value = variable._init is null ?
            compileIntegerLiteral(
                0,
                valueType(variable.type),
                resultType(variable.type),
            ) :
            compileInitializer(variable._init);
        instructions ~= Instruction(Store(
            localIndex(variable),
            value.type,
            value.id,
        ));
        localValues[variable] = Value(0, value.type, value.resultType);
    }

    private Value compileVariableLoad(VarDeclaration variable) {
        const local = localValue(variable);
        const destination = nextValue(local.type, local.resultType);
        instructions ~= Instruction(Load(
            localIndex(variable),
            destination,
        ));
        return destination;
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
        const destination = nextValue(valueType(cast_.to), resultType(cast_.to));
        instructions ~= Instruction(Cast(
            source.type,
            destination.type,
            source.id,
            destination,
        ));
        return destination;
    }

    private Value compilePreIncrement(imported!"dmd.expression".PreExp increment) {
        auto variable = increment.e1.isVarExp;
        assert(variable !is null);

        auto declaration = variable.var.isVarDeclaration;
        assert(declaration !is null);

        const lhs = compileVariableLoad(declaration);
        const rhs = compileIntegerLiteral(1);
        const destination = nextValue(lhs.type, lhs.resultType);
        instructions ~= Instruction(BinaryOp(
            BinaryOperation.add,
            lhs.type,
            lhs.id,
            rhs.id,
            destination,
        ));
        instructions ~= Instruction(Store(
            localIndex(declaration),
            destination.type,
            destination.id,
        ));
        return destination;
    }

    private Value compileAddAssign(AddAssignExp addAssign) {
        auto variable = addAssign.e1.isVarExp;
        assert(variable !is null);

        auto declaration = variable.var.isVarDeclaration;
        assert(declaration !is null);

        const lhs = compileVariableLoad(declaration);
        const rhs = compileExpression(addAssign.e2);
        const destination = nextValue(lhs.type, lhs.resultType);
        instructions ~= Instruction(BinaryOp(
            BinaryOperation.add,
            lhs.type,
            lhs.id,
            rhs.id,
            destination,
        ));
        instructions ~= Instruction(Store(
            localIndex(declaration),
            destination.type,
            destination.id,
        ));
        return destination;
    }

    private Value compileInteger(
        imported!"dmd.expression".IntegerExp integer,
    ) {
        return compileIntegerLiteral(
            integer.getInteger,
            valueType(integer.type),
            resultType(integer.type),
        );
    }

    private Value compileIntegerLiteral(
        in ulong bits,
        in Type type = Type.i32,
        in ResultType resultType = ResultType.int_,
    ) {
        const destination = nextValue(type, resultType);
        instructions ~= Instruction(Const(
            bits,
            destination,
        ));
        return destination;
    }

    private Value compileReal(imported!"dmd.expression".RealExp real_) {
        import dmd.astenums: TY;

        switch (real_.type.toBasetype.ty) with (TY) {
            case Tfloat32:
                const destination = nextValue(Type.f32, ResultType.float_);
                instructions ~= Instruction(Const(
                    floatBits(cast(float) real_.toReal),
                    destination,
                ));
                return destination;
            case Tfloat64:
                const destination = nextValue(Type.f64, ResultType.double_);
                instructions ~= Instruction(Const(
                    doubleBits(cast(double) real_.toReal),
                    destination,
                ));
                return destination;
            default:
                assert(0);
        }
    }

    private Value compileBinaryExpression(
        BinExp expression,
        in BinaryOperation operation,
    ) {
        const lhs = compileExpression(expression.e1);
        const rhs = compileExpression(expression.e2);
        const destination = nextValue(lhs.type, lhs.resultType);
        instructions ~= Instruction(BinaryOp(
            operation,
            lhs.type,
            lhs.id,
            rhs.id,
            destination,
        ));
        return destination;
    }

    private Value nextValue(
        in Type type,
        in ResultType resultType = ResultType.int_,
    ) @safe @nogc nothrow pure {
        const result = Value(nextValueId, type, resultType);
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

        return Value(0, valueType(variable.type), resultType(variable.type));
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
            result.resultType,
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

// @trusted: reads the bytes of a local float as a same-sized uint for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
private ulong floatBits(in float value) @trusted pure nothrow {
    static assert(float.sizeof == uint.sizeof);
    return *cast(uint*) &value;
}

// @trusted: reads the bytes of a local double as a same-sized ulong for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
private ulong doubleBits(in double value) @trusted pure nothrow {
    static assert(double.sizeof == ulong.sizeof);
    return *cast(ulong*) &value;
}

private imported!"quickbite.backends.ir.language".Type valueType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import quickbite.backends.ir.language: Type;

    switch (type.toBasetype.ty) with (TY) {
        case Tbool:
            return Type.i1;
        case Tint8:
        case Tuns8:
        case Tchar:
            return Type.i8;
        case Tint16:
        case Tuns16:
            return Type.i16;
        case Tint32:
        case Tuns32:
            return Type.i32;
        case Tint64:
        case Tuns64:
            return Type.i64;
        default:
            assert(0);
    }
}

private imported!"quickbite.backends.ir.language".ResultType resultType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import quickbite.backends.ir.language: ResultType;

    switch (type.toBasetype.ty) with (TY) {
        case Tbool:
            return ResultType.bool_;
        case Tint8:
            return ResultType.byte_;
        case Tuns8:
            return ResultType.ubyte_;
        case Tchar:
            return ResultType.char_;
        case Tint16:
            return ResultType.short_;
        case Tuns16:
            return ResultType.ushort_;
        case Tint32:
            return ResultType.int_;
        case Tuns32:
            return ResultType.uint_;
        case Tint64:
            return ResultType.long_;
        case Tuns64:
            return ResultType.ulong_;
        case Tfloat32:
            return ResultType.float_;
        case Tfloat64:
            return ResultType.double_;
        default:
            assert(0);
    }
}

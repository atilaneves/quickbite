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
        Const,
        Function,
        Instruction,
        Load,
        ReturnValue,
        Store,
        Terminator,
        Type,
        Value;

    private Instruction[] instructions;
    private uint[VarDeclaration] locals;
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
            return Value(0, Type.i32);
        }

        if (auto variable = expression.isVarExp) {
            auto declaration = variable.var.isVarDeclaration;
            assert(declaration !is null);
            return compileVariableLoad(declaration);
        }

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
        const value = compileIntegerLiteral(0);
        instructions ~= Instruction(Store(
            localIndex(variable),
            value.type,
            value.id,
        ));
    }

    private Value compileVariableLoad(VarDeclaration variable) {
        const destination = nextValue(Type.i32);
        instructions ~= Instruction(Load(
            localIndex(variable),
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
        const destination = nextValue(lhs.type);
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
        const destination = nextValue(lhs.type);
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
        return compileIntegerLiteral(integer.getInteger);
    }

    private Value compileIntegerLiteral(in ulong bits) {
        const destination = nextValue(Type.i32);
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
                const destination = nextValue(Type.f32);
                instructions ~= Instruction(Const(
                    floatBits(cast(float) real_.toReal),
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
        const destination = nextValue(lhs.type);
        instructions ~= Instruction(BinaryOp(
            operation,
            lhs.type,
            lhs.id,
            rhs.id,
            destination,
        ));
        return destination;
    }

    private Value nextValue(in Type type) @safe @nogc nothrow pure {
        const result = Value(nextValueId, type);
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
            result.type,
            nextValueId,
            cast(uint) locals.length,
        );
    }
}

private struct OptionalValue {
    public imported!"quickbite.backends.ir.language".Value value;
    public bool hasValue;
}

// @trusted: reads the bytes of a local float as a same-sized uint for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
private ulong floatBits(in float value) @trusted pure nothrow {
    static assert(float.sizeof == uint.sizeof);
    return *cast(uint*) &value;
}

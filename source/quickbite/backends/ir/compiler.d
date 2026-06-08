module quickbite.backends.ir.compiler;

private:

package imported!"quickbite.backends.ir.language".Function compileExpression(
    in string expr,
)
{
    import quickbite.frontend.compiler: parseExpression;

    return compileExpression(parseExpression(expr));
}

private imported!"quickbite.backends.ir.language".Function compileExpression(
    imported!"dmd.expression".Expression expression,
) {
    Compiler compiler;
    const result = compiler.compileExpression(expression);
    return compiler.function_(result);
}

private struct Compiler {
    import dmd.expression: Expression;
    import quickbite.backends.ir.language:
        BinaryOp,
        BinaryOperation,
        Block,
        Const,
        Function,
        Instruction,
        ReturnValue,
        Terminator,
        Type,
        Value;

    private Instruction[] instructions;
    private uint nextValueId;

    private Value compileExpression(Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return compileInteger(integer);

        if (auto add = expression.isAddExp)
            return compileAdd(add);

        assert(0);
    }

    private Value compileInteger(
        imported!"dmd.expression".IntegerExp integer,
    ) {
        const destination = nextValue(Type.i32);
        instructions ~= Instruction(Const(
            integer.getInteger,
            destination,
        ));
        return destination;
    }

    private Value compileAdd(imported!"dmd.expression".AddExp add) {
        const lhs = compileExpression(add.e1);
        const rhs = compileExpression(add.e2);
        const destination = nextValue(Type.i32);
        instructions ~= Instruction(BinaryOp(
            BinaryOperation.add,
            Type.i32,
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
        );
    }
}

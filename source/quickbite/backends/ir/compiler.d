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
    import dmd.expression: BinExp, Expression;
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

        if (auto real_ = expression.isRealExp)
            return compileReal(real_);

        if (auto add = expression.isAddExp)
            return compileBinary(add, BinaryOperation.add);

        if (auto sub = expression.isMinExp)
            return compileBinary(sub, BinaryOperation.sub);

        if (auto mul = expression.isMulExp)
            return compileBinary(mul, BinaryOperation.mul);

        if (auto div = expression.isDivExp)
            return compileBinary(div, BinaryOperation.div);

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

    private Value compileBinary(
        BinExp binary,
        in BinaryOperation operation,
    ) {
        const lhs = compileExpression(binary.e1);
        const rhs = compileExpression(binary.e2);
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

// @trusted: reads the bytes of a local float as a same-sized uint for IR raw
// scalar storage. The pointer is used only for this immediate read and never
// escapes.
private ulong floatBits(in float value) @trusted pure nothrow {
    static assert(float.sizeof == uint.sizeof);
    return *cast(uint*) &value;
}

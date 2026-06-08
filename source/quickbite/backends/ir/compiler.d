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
        Cast,
        Const,
        Function,
        Instruction,
        ReturnValue,
        Terminator,
        Type,
        UnaryOp,
        UnaryOperation,
        Value;

    private Instruction[] instructions;
    private uint nextValueId;

    private Value compileExpression(Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return compileInteger(integer);

        if (auto real_ = expression.isRealExp)
            return compileReal(real_);

        if (auto cast_ = expression.isCastExp)
            return compileCast(cast_);

        if (auto add = expression.isAddExp)
            return compileBinary(add, BinaryOperation.add);

        if (auto sub = expression.isMinExp)
            return compileBinary(sub, BinaryOperation.sub);

        if (auto mul = expression.isMulExp)
            return compileBinary(mul, BinaryOperation.mul);

        if (auto div = expression.isDivExp)
            return compileBinary(div, BinaryOperation.div);

        if (auto neg = expression.isNegExp)
            return compileUnary(neg.e1, UnaryOperation.neg);

        assert(0);
    }

    private Value compileInteger(
        imported!"dmd.expression".IntegerExp integer,
    ) {
        const destination = nextValue(irType(integer.type));
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
                const destination = nextValue(Type.float_);
                instructions ~= Instruction(Const(
                    floatBits(cast(float) real_.toReal),
                    destination,
                ));
                return destination;
            case Tfloat64:
                const destination = nextValue(Type.double_);
                instructions ~= Instruction(Const(
                    doubleBits(cast(double) real_.toReal),
                    destination,
                ));
                return destination;
            default:
                assert(0);
        }
    }

    private Value compileCast(imported!"dmd.expression".CastExp cast_) {
        const source = compileExpression(cast_.e1);
        const destination = nextValue(irType(cast_.to));
        instructions ~= Instruction(Cast(
            source.id,
            source.type,
            destination,
        ));
        return destination;
    }

    private Value compileUnary(
        Expression expression,
        in UnaryOperation operation,
    ) {
        const source = compileExpression(expression);
        const destination = nextValue(source.type);
        instructions ~= Instruction(UnaryOp(
            operation,
            source.type,
            source.id,
            destination,
        ));
        return destination;
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

private imported!"quickbite.backends.ir.language".Type irType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import quickbite.backends.ir.language: Type;

    switch (type.toBasetype.ty) with (TY) {
        case Tbool:
            return Type.bool_;
        case Tint8:
            return Type.byte_;
        case Tuns8:
            return Type.ubyte_;
        case Tchar:
            return Type.char_;
        case Tint16:
            return Type.short_;
        case Tuns16:
            return Type.ushort_;
        case Tint32:
            return Type.int_;
        case Tuns32:
            return Type.uint_;
        case Tint64:
            return Type.long_;
        case Tuns64:
            return Type.ulong_;
        case Tfloat32:
            return Type.float_;
        case Tfloat64:
            return Type.double_;
        case Tfloat80:
            return Type.real_;
        default:
            assert(0);
    }
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

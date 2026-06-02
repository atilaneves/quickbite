module quickbite.backends.ir.compiler;

private:

package imported!"quickbite.backends.ir.language".Expression compileExpression(
    in string expr,
)
{
    import quickbite.frontend.compiler: parseExpression;

    return compileExpression(parseExpression(expr));
}

private imported!"quickbite.backends.ir.language".Expression compileExpression(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.backends.ir.language: Add, Expression, Literal;

    if (auto integer = expression.isIntegerExp)
        return Expression(Literal(integerValue(integer)));

    if (auto add = expression.isAddExp) {
        auto lhs = literalValue(add.e1);
        auto rhs = literalValue(add.e2);

        return Expression(Add(
            Literal(lhs),
            Literal(rhs),
        ));
    }

    assert(0);
}

private imported!"quickbite.lang".Value literalValue(
    imported!"dmd.expression".Expression expression,
)
{
    if (auto integer = expression.isIntegerExp)
        return integerValue(integer);

    if (auto real_ = expression.isRealExp)
        return realValue(real_);

    assert(0);
}

private imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
)
{
    import quickbite.lang: Value;

    return Value(cast(int) integer.getInteger);
}

private imported!"quickbite.lang".Value realValue(
    imported!"dmd.expression".RealExp real_,
)
{
    import quickbite.lang: Value;
    import dmd.astenums: TY;

    assert(real_.type !is null);
    with (TY) switch (real_.type.toBasetype.ty) {
        case Tfloat32:
            return Value(cast(float) real_.toReal);
        default:
            assert(0);
    }
}

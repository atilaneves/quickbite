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
    import quickbite.frontend.dmd_values: integerValue;

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
    import quickbite.frontend.dmd_values: integerValue, realValue;

    if (auto integer = expression.isIntegerExp)
        return integerValue(integer);

    if (auto real_ = expression.isRealExp)
        return realValue(real_);

    assert(0);
}

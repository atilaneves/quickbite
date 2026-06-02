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
        const lhs = add.e1.isIntegerExp;
        const rhs = add.e2.isIntegerExp;
        assert(lhs !is null);
        assert(rhs !is null);

        return Expression(Add(
            Literal(integerValue(lhs)),
            Literal(integerValue(rhs)),
        ));
    }

    assert(0);
}

private imported!"quickbite.lang".Value integerValue(
    const(imported!"dmd.expression".IntegerExp) integer,
)
{
    import quickbite.lang: Value;

    return Value(cast(int) (cast(imported!"dmd.expression".IntegerExp) integer).getInteger);
}

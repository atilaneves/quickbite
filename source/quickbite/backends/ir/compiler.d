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
    import quickbite.backends.ir.language: Expression, Literal;

    if (auto integer = expression.isIntegerExp)
        return Expression(Literal(integerValue(integer)));

    assert(0);
}

private imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
)
{
    import quickbite.lang: Value;

    return Value(cast(int) integer.getInteger);
}

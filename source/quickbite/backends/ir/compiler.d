module quickbite.backends.ir.compiler;

private:

public imported!"quickbite.backends.ir.ir".IntegerLiteral compile(
    imported!"dmd.expression".Expression expression,
) {
    return typeof(return)(cast(int) expression.isIntegerExp.getInteger);
}

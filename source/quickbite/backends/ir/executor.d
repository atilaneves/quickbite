module quickbite.backends.ir.executor;

private:

public void executeTests(in imported!"quickbite.backends.ir.ir".Module module_) {
    foreach (test; module_.tests)
        assert(evaluate(module_, test.expressions, test.condition) != 0);
}

private long executeFunction(
    in imported!"quickbite.backends.ir.ir".Module module_,
    in string functionName,
) {
    foreach (function_; module_.functions)
        if (function_.name == functionName)
            return evaluate(module_, function_.expressions, function_.result);

    assert(0);
}

private long evaluate(
    in imported!"quickbite.backends.ir.ir".Module module_,
    in imported!"quickbite.backends.ir.ir".Expression[] expressions,
    in uint expressionIndex,
) {
    with (imported!"quickbite.backends.ir.ir".ExpressionCode) final switch (
        expressions[expressionIndex].code
    ) {
        case integer:
            return expressions[expressionIndex].integer;
        case call:
            return executeFunction(
                module_,
                expressions[expressionIndex].functionName,
            );
        case equal:
            return evaluate(
                module_,
                expressions,
                expressions[expressionIndex].lhs,
            ) == evaluate(
                module_,
                expressions,
                expressions[expressionIndex].rhs,
            );
    }
}

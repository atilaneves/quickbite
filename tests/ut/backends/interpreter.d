module ut.backends.interpreter;


import ut.backends;


@("zeroArgumentCallReportsArgumentCount.Interpreter")
unittest {
    newBackend!Interpreter.eval("int zero() { return 0; }\nzero")
        .shouldThrowWithMessage("Unsupported eval call argument count.");
}

@("ifStatementReportsUnsupportedEvalStatement.Interpreter")
unittest {
    newBackend!Interpreter.eval("bool input = true;\nif (input) {}\n0")
        .shouldThrowWithMessage("Unsupported eval statement: If");
}

module quickbite.unittest_assertions;

private:

public enum AssertionMessageMode {
    plain,
    context,
}

public string failedAssertionMessage(
    in AssertionMessageMode mode,
) @safe pure {
    final switch (mode) {
        case AssertionMessageMode.plain:
            return "Unittest assertion failed.";
        case AssertionMessageMode.context:
            return "Unittest assertion failed.";
    }
}

public string failedAssertionMessage(
    in AssertionMessageMode mode,
    in long left,
    in long right,
    in string operator,
) @safe pure {
    import quickbite.executor: Value;

    return failedAssertionMessage(mode, Value(left), Value(right), operator);
}

public string failedAssertionMessage(
    in AssertionMessageMode mode,
    in imported!"quickbite.executor".Value left,
    in imported!"quickbite.executor".Value right,
    in string operator,
) @safe pure {
    if (mode == AssertionMessageMode.plain)
        return failedAssertionMessage(mode);

    import std.conv: text;

    return text(left, " ", inverseOperator(operator), " ", right);
}

private string inverseOperator(in string operator) @safe pure {
    switch (operator) {
        case "==":
            return "!=";
        case "!=":
            return "==";
        case "<":
            return ">=";
        case "<=":
            return ">";
        case ">":
            return "<=";
        case ">=":
            return "<";
        default:
            return "!=";
    }
}

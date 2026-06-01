module quickbite.backends.ir.ir;

private:

public struct Module {
    public Function[] functions;
    public Test[] tests;
}

public struct Function {
    public string name;
    public Expression[] expressions;
    public uint result;
}

public struct Test {
    public Expression[] expressions;
    public uint condition;
}

public struct Expression {
    public ExpressionCode code;
    public long integer;
    public string functionName;
    public uint lhs;
    public uint rhs;
}

public enum ExpressionCode {
    integer,
    call,
    equal,
}

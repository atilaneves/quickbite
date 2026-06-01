module quickbite.backends.ir.executor;

private:

public int execute(in imported!"quickbite.backends.ir.ir".IntegerLiteral literal) {
    return literal.value;
}

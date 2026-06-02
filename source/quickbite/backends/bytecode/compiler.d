module quickbite.backends.bytecode.compiler;

private:


package imported!"quickbite.backends.bytecode.instructions".Program compileExpression(
    in string expr
)
{
    import quickbite.frontend.compiler: parseExpression;
    import quickbite.backends.bytecode.instructions: Program;

    return compileExpression(parseExpression(expr));
}

private imported!"quickbite.backends.bytecode.instructions".Program compileExpression(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.backends.bytecode.instructions: Program;

    Program program;
    compileExpression(expression, program);
    return program;
}

private void compileExpression(
    imported!"dmd.expression".Expression expression,
    ref imported!"quickbite.backends.bytecode.instructions".Program program,
)
{
    import quickbite.backends.bytecode.instructions: Instruction, Op;
    import std.string: fromStringz;

    if (auto integer = expression.isIntegerExp) {
        program.instructions ~= Instruction(
            Op.literal,
            integerValue(integer),
        );
        return;
    }

    if (auto add = expression.isAddExp) {
        compileExpression(add.e1, program);
        compileExpression(add.e2, program);
        program.instructions ~= Instruction(Op.add);
        return;
    }

    const msg = "Unsupported expression `" ~ expression.toChars.fromStringz.idup ~ "`";
    throw new Exception(msg);
}


private imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
)
{
    import quickbite.lang: Value;
    import dmd.astenums: TY;

    const bits = integer.getInteger;
    const ty = integer.type.toBasetype.ty;

    switch (ty) {
        default:
            assert(0, "not an integer");

        case TY.Tint8:
            return Value(cast(byte) bits);

        case TY.Tuns8:
            return Value(cast(ubyte) bits);

        case TY.Tint16:
            return Value(cast(short) bits);

        case TY.Tuns16:
            return Value(cast(ushort) bits);

        case TY.Tint32:
            return Value(cast(int) bits);

        case TY.Tuns32:
            return Value(cast(uint) bits);

        case TY.Tint64:
            return Value(cast(long) bits);

        case TY.Tuns64:
            return Value(cast(ulong) bits);
    }
}

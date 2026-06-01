module quickbite.backends.bytecode.compiler;

private:

package imported!"quickbite.backends.bytecode.bytecode".Program compileExpression(
    in string expr,
) {
    import quickbite.frontend.compiler: parseExpression;

    return compileExpression(parseExpression(expr));
}

package imported!"quickbite.backends.bytecode.bytecode".Program compileExpression(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.backends.bytecode.bytecode: Instruction, Op, Program;
    import std.string: fromStringz;

    if (auto integer = expression.isIntegerExp) {
        return Program(
            [
                Instruction(Op.literal, integerValue(integer)),
            ]
        );
    }

    string msg = "Unsupported expression `" ~ expression.toChars.fromStringz.idup ~ "`";
    throw new Exception(msg);
}

private imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
) {
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

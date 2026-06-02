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

package imported!"quickbite.backends.bytecode.instructions".Program compileEvalSource(
    in string source,
)
{
    import quickbite.frontend.compiler: parseModule;

    return compileFunction(functionDeclaration(parseModule(evalSource(source)).module_));
}

private imported!"quickbite.backends.bytecode.instructions".Program compileExpression(
    imported!"dmd.expression".Expression expression,
) {
    Compiler compiler;
    compiler.compileExpression(expression);
    return compiler.program;
}

private imported!"quickbite.backends.bytecode.instructions".Program compileFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    Compiler compiler;
    compiler.compileStatement(function_.fbody);
    return compiler.program;
}

private struct Compiler {
    import quickbite.backends.bytecode.instructions: Instruction, Op, Program;

    private Program program;
    private size_t[imported!"dmd.declaration".VarDeclaration] locals;

    private void compileStatement(imported!"dmd.statement".Statement statement) {
        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    compileStatement(child);
            return;
        }

        if (auto expression = statement.isExpStatement) {
            compileExpression(expression.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            compileExpression(return_.exp);
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported bytecode statement: ", statement.stmt));
    }

    private void compileExpression(
        imported!"dmd.expression".Expression expression,
    )
    {
        import std.string: fromStringz;

        if (auto integer = expression.isIntegerExp) {
            program.instructions ~= Instruction(
                Op.literal,
                integerValue(integer),
            );
            return;
        }

        if (auto declaration = expression.isDeclarationExp) {
            auto variable = declaration.declaration.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported bytecode declaration.");

            compileVariableDeclaration(variable);
            return;
        }

        if (auto variable = expression.isVarExp) {
            auto declaration = variable.var.isVarDeclaration;
            if (declaration is null)
                throw new Exception("Unsupported bytecode variable.");

            compileVariableLoad(declaration);
            return;
        }

        if (auto increment = expression.isPreExp) {
            compilePreIncrement(increment);
            return;
        }

        if (auto addAssign = expression.isAddAssignExp) {
            compileAddAssign(addAssign);
            return;
        }

        if (auto real_ = expression.isRealExp) {
            program.instructions ~= Instruction(
                Op.literal,
                realValue(real_),
            );
            return;
        }

        if (auto add = expression.isAddExp) {
            compileExpression(add.e1);
            compileExpression(add.e2);
            program.instructions ~= Instruction(Op.add);
            return;
        }

        if (auto subtract = expression.isMinExp) {
            compileExpression(subtract.e1);
            compileExpression(subtract.e2);
            program.instructions ~= Instruction(Op.subtract);
            return;
        }

        if (auto multiply = expression.isMulExp) {
            compileExpression(multiply.e1);
            compileExpression(multiply.e2);
            program.instructions ~= Instruction(Op.multiply);
            return;
        }

        if (auto divide = expression.isDivExp) {
            compileExpression(divide.e1);
            compileExpression(divide.e2);
            program.instructions ~= Instruction(Op.divide);
            return;
        }

        const msg = "Unsupported expression `" ~
            expression.toChars.fromStringz.idup ~ "`";
        throw new Exception(msg);
    }

    private size_t localIndex(imported!"dmd.declaration".VarDeclaration variable) {
        if (auto existing = variable in locals)
            return *existing;

        const index = locals.length;
        locals[variable] = index;
        return index;
    }

    private void compileVariableDeclaration(
        imported!"dmd.declaration".VarDeclaration variable,
    ) {
        program.instructions ~= Instruction(
            Op.initializeLocal,
            defaultValue(variable),
            localIndex(variable),
        );
    }

    private void compileVariableLoad(
        imported!"dmd.declaration".VarDeclaration variable,
    ) {
        program.instructions ~= Instruction(
            Op.loadLocal,
            imported!"quickbite.lang".Value.void_,
            localIndex(variable),
        );
    }

    private void compilePreIncrement(
        imported!"dmd.expression".PreExp increment,
    ) {
        auto variable = increment.e1.isVarExp;
        if (variable is null)
            throw new Exception("Unsupported bytecode pre-increment target.");

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception("Unsupported bytecode pre-increment target.");

        program.instructions ~= Instruction(
            Op.incrementLocal,
            imported!"quickbite.lang".Value(1),
            localIndex(declaration),
        );
    }

    private void compileAddAssign(
        imported!"dmd.expression".AddAssignExp addAssign,
    ) {
        auto variable = addAssign.e1.isVarExp;
        if (variable is null)
            throw new Exception("Unsupported bytecode += target.");

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception("Unsupported bytecode += target.");

        auto integer = addAssign.e2.isIntegerExp;
        if (integer is null)
            throw new Exception("Unsupported bytecode += value.");

        program.instructions ~= Instruction(
            Op.incrementLocal,
            integerValue(integer),
            localIndex(declaration),
        );
    }
}


private string evalSource(in string str) {
    import std.string: lastIndexOf;

    const lastNl = str.lastIndexOf('\n');
    const prior  = lastNl < 0 ? "" : str[0 .. lastNl + 1];
    const last   = lastNl < 0 ? str : str[lastNl + 1 .. $];
    return "auto f() { " ~ prior ~ "return " ~ last ~ "; }";
}

private imported!"dmd.func".FuncDeclaration functionDeclaration(
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ !is null && function_.ident.toString == "f")
                return function_;
        }
    }

    throw new Exception("Missing bytecode eval function.");
}

private imported!"quickbite.lang".Value defaultValue(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const type = variable.type.toBasetype;
    with (TY) final switch (type.ty) {
        case Tbool:
            return Value(false);
        case Tint8:
            return Value(cast(byte) 0);
        case Tuns8:
            return Value(cast(ubyte) 0);
        case Tint16:
            return Value(cast(short) 0);
        case Tuns16:
            return Value(cast(ushort) 0);
        case Tint32:
            return Value(0);
        case Tuns32:
            return Value(0u);
        case Tint64:
            return Value(0L);
        case Tuns64:
            return Value(0UL);
        case Tfloat32:
            return Value(0.0f);
        case Tfloat64:
            return Value(0.0);
        case Tfloat80:
            return Value(0.0L);
        case Tchar:
            return Value(char.init);
        case Twchar:
            return Value(wchar.init);
        case Tdchar:
            return Value(dchar.init);
        case Tvoid:
        case Tint128:
        case Tuns128:
        case Timaginary32:
        case Timaginary64:
        case Timaginary80:
        case Tcomplex32:
        case Tcomplex64:
        case Tcomplex80:
        case Tpointer:
        case Tfunction:
        case Tarray:
        case Tsarray:
        case Taarray:
        case Tclass:
        case Tident:
        case Tinstance:
        case Ttypeof:
        case Ttuple:
        case Tslice:
        case Treturn:
        case Terror:
        case Tnull:
        case Tvector:
        case Ttraits:
        case Tmixin:
        case Tnoreturn:
        case Ttag:
        case Tstruct:
        case Tenum:
        case Tdelegate:
        case Treference:
        case Tnone:
            throw new Exception("Unsupported bytecode default value.");
    }
}


private imported!"quickbite.lang".Value realValue(
    imported!"dmd.expression".RealExp real_,
) {
    import quickbite.lang: Value;
    import dmd.astenums: TY;

    const type = real_.type.toBasetype;

    if (type !is null && type.ty == TY.Tfloat32)
        return Value(cast(float) real_.toReal);

    if (type !is null && type.ty == TY.Tfloat64)
        return Value(cast(double) real_.toReal);

    return Value(cast(real) real_.toReal);
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

        case TY.Tbool:
            return Value(bits != 0);

        case TY.Tchar:
            return Value(cast(char) bits);

        case TY.Twchar:
            return Value(cast(wchar) bits);

        case TY.Tdchar:
            return Value(cast(dchar) bits);

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

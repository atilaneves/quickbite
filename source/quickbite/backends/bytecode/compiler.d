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
    import quickbite.frontend.compiler: parseEvalFunction;

    return compileFunction(parseEvalFunction(source));
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
    import quickbite.backends.bytecode.instructions:
        CastTarget, Instruction, Op, Program;
    import quickbite.lang: Value;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.expression:
        AddAssignExp, BinExp, CallExp, CastExp, Expression, PreExp;
    import dmd.statement: Statement;

    private Program program;
    private size_t[VarDeclaration] locals;

    private void compileStatement(Statement statement) {
        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    compileStatement(child);
            return;
        }

        // Imports are semantically resolved before bytecode compilation; eval
        // tests for std.math native calls still leave their import statements
        // in the function body, but they do not emit runtime bytecode.
        if (statement.isImportStatement !is null)
            return;

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
        Expression expression,
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

        if (auto cast_ = expression.isCastExp) {
            compileCast(cast_);
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

        if (auto string_ = expression.isStringExp) {
            program.instructions ~= Instruction(
                Op.literal,
                stringValue(string_),
            );
            return;
        }

        if (auto add = expression.isAddExp) {
            compileBinaryExpression(add, Op.add);
            return;
        }

        if (auto subtract = expression.isMinExp) {
            compileBinaryExpression(subtract, Op.subtract);
            return;
        }

        if (auto multiply = expression.isMulExp) {
            compileBinaryExpression(multiply, Op.multiply);
            return;
        }

        if (auto divide = expression.isDivExp) {
            compileBinaryExpression(divide, Op.divide);
            return;
        }

        if (auto negate = expression.isNegExp) {
            compileExpression(negate.e1);
            program.instructions ~= Instruction(Op.negate);
            return;
        }

        if (auto call = expression.isCallExp) {
            compileCall(call);
            return;
        }

        const msg = "Unsupported expression `" ~
            expression.toChars.fromStringz.idup ~ "`";
        throw new Exception(msg);
    }

    private void compileBinaryExpression(BinExp expression, in Op op) {
        compileExpression(expression.e1);
        compileExpression(expression.e2);
        program.instructions ~= Instruction(op);
    }

    private size_t localIndex(VarDeclaration variable) {
        if (auto existing = variable in locals)
            return *existing;

        const index = locals.length;
        locals[variable] = index;
        return index;
    }

    private void compileVariableDeclaration(
        VarDeclaration variable,
    ) {
        if (variable._init !is null) {
            auto initializer = variable._init.isExpInitializer;
            if (initializer is null)
                throw new Exception("Unsupported bytecode initializer.");

            compileExpression(initializerExpression(initializer.exp));

            program.instructions ~= Instruction(
                Op.storeLocal,
                Value.void_,
                localIndex(variable),
            );
            return;
        }

        program.instructions ~= Instruction(
            Op.initializeLocal,
            defaultValue(variable),
            localIndex(variable),
        );
    }

    private void compileVariableLoad(
        VarDeclaration variable,
    ) {
        program.instructions ~= Instruction(
            Op.loadLocal,
            Value.void_,
            localIndex(variable),
        );
    }

    private void compilePreIncrement(
        PreExp increment,
    ) {
        auto variable = increment.e1.isVarExp;
        if (variable is null)
            throw new Exception("Unsupported bytecode pre-increment target.");

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception("Unsupported bytecode pre-increment target.");

        const index = localIndex(declaration);
        program.instructions ~= Instruction(Op.loadLocal, Value.void_, index);
        program.instructions ~= Instruction(
            Op.literal,
            incrementValue(declaration),
        );
        program.instructions ~= Instruction(Op.add);
        program.instructions ~= Instruction(Op.storeLocal, Value.void_, index);
    }

    private void compileAddAssign(
        AddAssignExp addAssign,
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

        const index = localIndex(declaration);
        program.instructions ~= Instruction(Op.loadLocal, Value.void_, index);
        program.instructions ~= Instruction(Op.literal, integerValue(integer));
        program.instructions ~= Instruction(Op.add);
        program.instructions ~= Instruction(Op.storeLocal, Value.void_, index);
    }

    private void compileCast(CastExp cast_) {
        compileExpression(cast_.e1);

        program.instructions ~= Instruction(
            Op.cast_,
            Value.void_,
            castTarget(cast_),
        );
    }

    private void compileCall(CallExp call) {
        import quickbite.backends.bytecode.builtins:
            bytecodeBuiltin,
            bytecodeBuiltinArgumentCount,
            bytecodeBuiltinIsImplemented;

        const builtin = bytecodeBuiltin(call.f);
        if (!bytecodeBuiltinIsImplemented(builtin))
            throw new Exception("Unsupported bytecode builtin.");

        if (call.arguments is null)
            throw new Exception("Unsupported bytecode builtin call arguments.");

        const expectedArgumentCount = bytecodeBuiltinArgumentCount(builtin);
        if (call.arguments.length != expectedArgumentCount)
            throw new Exception(
                "Unsupported bytecode builtin call argument count.",
            );

        foreach (argument; *call.arguments)
            compileExpression(argument);

        switch (expectedArgumentCount) {
            case 1:
                program.instructions ~= Instruction(
                    Op.unaryNativeCall,
                    Value.void_,
                    cast(size_t) builtin,
                );
                return;

            case 2:
                program.instructions ~= Instruction(
                    Op.binaryNativeCall,
                    Value.void_,
                    cast(size_t) builtin,
                );
                return;

            default:
                break;
        }

        throw new Exception("Unsupported bytecode builtin call.");
    }

    private size_t castTarget(CastExp cast_) {
        import dmd.astenums: TY;

        const type = cast_.type.toBasetype;
        switch (type.ty) {
            case TY.Tint8:
                return CastTarget.byte_;

            case TY.Tuns8:
                return CastTarget.ubyte_;

            case TY.Tint16:
                return CastTarget.short_;

            case TY.Tuns16:
                return CastTarget.ushort_;

            case TY.Tint32:
                return CastTarget.int_;

            case TY.Tuns32:
                return CastTarget.uint_;

            case TY.Tint64:
                return CastTarget.long_;

            case TY.Tuns64:
                return CastTarget.ulong_;

            default:
                break;
        }

        throw new Exception("Unsupported bytecode cast.");
    }

    private Expression initializerExpression(
        Expression expression,
    ) {
        if (auto assignment = expression.isAssignExp)
            return assignment.e2;

        if (auto construct = expression.isConstructExp)
            return construct.e2;

        if (auto blit = expression.isBlitExp)
            return blit.e2;

        return expression;
    }
}


private imported!"quickbite.lang".Value defaultValue(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const type = variable.type.toBasetype;
    with (TY) final switch (type.ty) {
        case Tbool:
            return initialValue!bool;
        case Tint8:
            return initialValue!byte;
        case Tuns8:
            return initialValue!ubyte;
        case Tint16:
            return initialValue!short;
        case Tuns16:
            return initialValue!ushort;
        case Tint32:
            return initialValue!int;
        case Tuns32:
            return initialValue!uint;
        case Tint64:
            return initialValue!long;
        case Tuns64:
            return initialValue!ulong;
        case Tfloat32:
            return initialValue!float;
        case Tfloat64:
            return initialValue!double;
        case Tfloat80:
            return initialValue!real;
        case Tchar:
            return initialValue!char;
        case Twchar:
            return initialValue!wchar;
        case Tdchar:
            return initialValue!dchar;
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

private imported!"quickbite.lang".Value initialValue(T)() {
    import quickbite.lang: Value;

    return Value(T.init);
}

private imported!"quickbite.lang".Value incrementValue(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    const type = variable.type.toBasetype;
    with (TY) final switch (type.ty) {
        case Tint8:
            return Value(cast(byte) 1);
        case Tuns8:
            return Value(cast(ubyte) 1);
        case Tint16:
            return Value(cast(short) 1);
        case Tuns16:
            return Value(cast(ushort) 1);
        case Tint32:
            return Value(1);
        case Tuns32:
            return Value(1u);
        case Tint64:
            return Value(1L);
        case Tuns64:
            return Value(1UL);
        case Tfloat32:
            return Value(1.0f);
        case Tfloat64:
            return Value(1.0);
        case Tfloat80:
            return Value(1.0L);

        case Tbool:
        case Tchar:
        case Twchar:
        case Tdchar:
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
            throw new Exception("Unsupported bytecode pre-increment type.");
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

private imported!"quickbite.lang".Value stringValue(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.lang: Value;

    return Value(string_.peekString.idup);
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

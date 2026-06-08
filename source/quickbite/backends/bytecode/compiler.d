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
    import quickbite.frontend.cell: parseEvalSource;

    return compileFunction(parseEvalSource(source).function_);
}

package imported!"quickbite.backends.bytecode.instructions".Program compileUnitTest(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    Compiler compiler;
    compiler.compileUnitTest(unitTest);
    return compiler.program;
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
        Function,
        Instruction,
        Op,
        Program;
    import quickbite.backends.casts: CastTarget;
    import quickbite.frontend.dmd_values: integerValue, realValue;
    import quickbite.lang: Value;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.expression:
        AddAssignExp, AssertExp, BinExp, CallExp, CastExp, Expression, PreExp;
    import dmd.statement: Statement;

    private Program program;
    private size_t[VarDeclaration] locals;
    // Functions discovered from calls while compiling the unittest body. Their
    // bodies are emitted after the unittest entry code, using the same index as
    // the bytecode function table in Program.functions.
    private FuncDeclaration[] functions;
    private size_t[FuncDeclaration] functionIndices;

    private void compileUnitTest(FuncDeclaration unitTest) {
        compileFunctionBody(unitTest);
        program.instructions ~= Instruction(Op.halt);

        // Compiling one deferred function can discover more called functions,
        // so keep checking the current queue length while draining it.
        for (size_t i = 0; i < functions.length; ++i)
            compileQueuedFunction(i);
    }

    private void compileFunctionBody(FuncDeclaration function_) {
        locals = null;
        registerParameters(function_);
        compileStatement(function_.fbody);
    }

    private void compileQueuedFunction(in size_t index) {
        // `index` selects both the deferred DMD function and the matching
        // bytecode function table entry whose instruction offset is filled in.
        program.functions[index].entry = program.instructions.length;
        compileFunctionBody(functions[index]);
        program.instructions ~= Instruction(Op.ret);
    }

    private void compileStatement(Statement statement) {
        if (statement is null)
            return;

        if (auto scope_ = statement.isScopeStatement) {
            compileStatement(scope_.statement);
            return;
        }

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
            program.instructions ~= Instruction(Op.ret);
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

        if (auto assert_ = expression.isAssertExp) {
            compileAssert(assert_);
            return;
        }

        if (auto comma = expression.isCommaExp) {
            compileExpression(comma.e1);
            compileExpression(comma.e2);
            return;
        }

        if (auto equal = expression.isEqualExp) {
            compileBinaryExpression(equal, Op.equal);
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

        program.instructions ~= Instruction(
            Op.incrementLocal,
            Value(1),
            localIndex(declaration),
        );
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

        program.instructions ~= Instruction(
            Op.incrementLocal,
            integerValue(integer),
            localIndex(declaration),
        );
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
            bytecodeBuiltinArgumentCount;

        auto function_ = callFunction(call);
        if (isImplementedBuiltin(function_)) {
            compileBuiltinCall(call);
            return;
        }

        if (function_ !is null) {
            if (function_.fbody !is null) {
                if (call.arguments !is null)
                    foreach (argument; *call.arguments)
                        compileExpression(argument);

                program.instructions ~= Instruction(
                    Op.call,
                    Value.void_,
                    functionIndex(function_),
                );
                return;
            }
        }

        compileBuiltinCall(call);
    }

    private void compileBuiltinCall(CallExp call) {
        import quickbite.backends.bytecode.builtins:
            bytecodeBuiltin,
            bytecodeBuiltinArgumentCount;

        const builtin = bytecodeBuiltin(call.f);
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

    private bool isImplementedBuiltin(FuncDeclaration function_) {
        import dmd.builtin: isBuiltin;
        import dmd.func: BUILTIN;

        if (function_ is null)
            return false;

        with (BUILTIN) switch (isBuiltin(function_)) {
            case fabs:
            case pow:
                return true;

            default:
                return false;
        }
    }

    private void compileAssert(AssertExp assert_) {
        if (auto equal = assert_.e1.isEqualExp) {
            compileBinaryExpression(equal, Op.assertCompare);
            return;
        }

        compileExpression(assert_.e1);
        program.instructions ~= Instruction(Op.assertTrue);
    }

    private size_t functionIndex(FuncDeclaration function_) {
        if (auto existing = function_ in functionIndices)
            return *existing;

        const index = functions.length;
        functions ~= function_;
        functionIndices[function_] = index;
        program.functions ~= Function(0, parameterCount(function_));
        return index;
    }

    private FuncDeclaration callFunction(CallExp call) {
        if (call.f !is null)
            return call.f;

        if (auto variable = call.e1.isVarExp)
            if (auto function_ = variable.var.isFuncDeclaration)
                return function_;

        return null;
    }

    private size_t parameterCount(FuncDeclaration function_) {
        return function_.parameters is null ? 0 : function_.parameters.length;
    }

    private void registerParameters(FuncDeclaration function_) {
        if (function_.parameters is null)
            return;

        foreach (parameter; *function_.parameters)
            localIndex(parameter);
    }

    private size_t castTarget(CastExp cast_) {
        import quickbite.backends.casts: target = castTarget;

        return target(cast_.type);
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

private imported!"quickbite.lang".Value stringValue(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.lang: Value;

    return Value(stringChars(string_));
}

private char[] stringChars(imported!"dmd.expression".StringExp string_) {
    char[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits)
        values ~= cast(char) string_.getIndex(index);

    return values;
}

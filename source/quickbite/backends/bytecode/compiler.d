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
    import quickbite.frontend.dmd.values: defaultValue, integerValue, realValue;
    import quickbite.lang: Value;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.expression:
        AddAssignExp, AssertExp, BinExp, CallExp, CastExp, CmpExp, Expression,
        LogicalExp, PreExp;
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

        if (auto throw_ = statement.isThrowStatement) {
            compileThrow(throw_);
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

        if (auto logical = expression.isLogicalExp) {
            if (isAndAnd(logical)) {
                compileAndAnd(logical);
                return;
            }

            if (isOrOr(logical)) {
                compileOrOr(logical);
                return;
            }
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

        if (auto bitOr = expression.isOrExp) {
            compileBinaryExpression(bitOr, Op.bitOr);
            return;
        }

        if (isComparisonExpression(expression)) {
            compileComparisonExpression(castComparisonExpression(expression));
            return;
        }

        if (auto not = expression.isNotExp) {
            compileExpression(not.e1);
            program.instructions ~= Instruction(Op.not_);
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

    private void compileComparisonExpression(CmpExp expression) {
        import dmd.tokens: EXP;

        if (expression.op == EXP.lessThan) {
            compileBinaryExpression(expression, Op.lessThan);
            return;
        }

        if (expression.op == EXP.greaterThan) {
            compileBinaryExpression(expression, Op.greaterThan);
            return;
        }

        import std.conv: text;
        throw new Exception(text(
            "Unsupported bytecode comparison: ",
            expression.op,
        ));
    }

    private void compileAndAnd(LogicalExp expression) {
        compileExpression(expression.e1);
        const falseJump = emitJump(Op.jumpIfFalse);
        program.instructions ~= Instruction(Op.pop);

        compileExpression(expression.e2);
        emitBoolCast;
        const endJump = emitJump(Op.jump);

        patchJump(falseJump);
        emitBoolCast;
        patchJump(endJump);
    }

    private void compileOrOr(LogicalExp expression) {
        compileExpression(expression.e1);
        const falseJump = emitJump(Op.jumpIfFalse);

        emitBoolCast;
        const endJump = emitJump(Op.jump);

        patchJump(falseJump);
        program.instructions ~= Instruction(Op.pop);
        compileExpression(expression.e2);
        emitBoolCast;

        patchJump(endJump);
    }

    private bool isAndAnd(LogicalExp expression) {
        import dmd.tokens: EXP;

        return expression.op == EXP.andAnd;
    }

    private bool isOrOr(LogicalExp expression) {
        import dmd.tokens: EXP;

        return expression.op == EXP.orOr;
    }

    private bool isComparisonExpression(Expression expression) {
        import dmd.tokens: EXP;

        return expression.op == EXP.lessThan ||
            expression.op == EXP.greaterThan;
    }

    private CmpExp castComparisonExpression(Expression expression) {
        auto comparison = cast(CmpExp) expression;
        if (comparison is null)
            throw new Exception("Unsupported bytecode comparison expression.");

        return comparison;
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

        emitCast(castTarget(cast_));
    }

    private void emitBoolCast() {
        emitCast(CastTarget.bool_);
    }

    private void emitCast(in CastTarget target) {
        program.instructions ~= Instruction(
            Op.cast_,
            Value.void_,
            target,
        );
    }

    private size_t emitJump(in Op op) {
        program.instructions ~= Instruction(op);
        return program.instructions.length - 1;
    }

    private void patchJump(in size_t instructionIndex) {
        program.instructions[instructionIndex].operand =
            program.instructions.length;
    }

    private void compileCall(CallExp call) {
        auto function_ = callFunction(call);
        if (isImplementedBuiltin(function_)) {
            compileBuiltinCall(call);
            return;
        }

        if (function_ !is null) {
            if (function_.fbody is null)
                throw new Exception(noAvailableSourceMessage(function_));

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
        if (compileDmdAssertFailEqualMessage(assert_.msg))
            return;

        if (auto equal = assert_.e1.isEqualExp) {
            compileBinaryExpression(equal, Op.assertCompare);
            return;
        }

        if (auto not = assert_.e1.isNotExp) {
            compileExpression(not.e1);
            program.instructions ~= Instruction(Op.assertFalse);
            return;
        }

        compileExpression(assert_.e1);
        program.instructions ~= Instruction(
            Op.assertTrue,
            assertMessageValue(assert_),
        );
    }

    private void compileThrow(imported!"dmd.statement".ThrowStatement throw_) {
        auto new_ = throw_.exp.isNewExp;
        if (new_ is null || new_.arguments is null || new_.arguments.length == 0)
            throw new Exception("Unsupported bytecode throw expression.");

        compileExpression((*new_.arguments)[0]);
        program.instructions ~= Instruction(Op.throw_);
    }

    private bool compileDmdAssertFailEqualMessage(Expression message) {
        if (message is null)
            return false;

        auto call = message.isCallExp;
        if (call is null || call.arguments is null)
            return false;

        if (call.arguments.length != 3)
            return false;

        auto operator = (*call.arguments)[0].isStringExp;
        if (operator is null || stringChars(operator) != "==")
            return false;

        compileExpression((*call.arguments)[1]);
        compileExpression((*call.arguments)[2]);
        program.instructions ~= Instruction(Op.assertCompare);
        return true;
    }

    private Value assertMessageValue(AssertExp assert_) {
        import std.string: fromStringz;

        if (assert_.msg !is null) {
            auto string_ = assert_.msg.isStringExp;
            if (string_ !is null)
                return stringValue(string_);
        }

        const message = "`assert(" ~
            assert_.e1.toChars.fromStringz.idup ~
            ")` failed";
        return Value(message.dup);
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

    private CastTarget castTarget(CastExp cast_) {
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

private string noAvailableSourceMessage(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    return text(
        "`",
        function_.toChars,
        "` cannot be interpreted at compile time, ",
        "because it has no available source code",
    );
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

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

package imported!"quickbite.backends.bytecode.instructions".Program compileEvalCell(
    imported!"quickbite.frontend.cell".EvalCell cell,
) {
    return compileFunction(cell.function_);
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
    compiler.compileEntryFunction(function_);
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
        AddAssignExp, AssertExp, AssignExp, BinExp, CallExp, CastExp, CmpExp,
        DotVarExp, Expression, IdentityExp, LogicalExp, PostExp, PreExp,
        TypeidExp;
    import dmd.statement: Statement;

    private Program program;
    private size_t[VarDeclaration] locals;
    // Functions discovered from calls while compiling the unittest body. Their
    // bodies are emitted after the unittest entry code, using the same index as
    // the bytecode function table in Program.functions.
    private FuncDeclaration[] functions;
    private size_t[FuncDeclaration] functionIndices;
    private FuncDeclaration currentFunction;

    private void compileUnitTest(FuncDeclaration unitTest) {
        compileEntryFunction(unitTest);
    }

    private void compileEntryFunction(FuncDeclaration function_) {
        compileFunctionBody(function_);
        program.instructions ~= Instruction(Op.halt);

        // Compiling one deferred function can discover more called functions,
        // so keep checking the current queue length while draining it.
        for (size_t i = 0; i < functions.length; ++i)
            compileQueuedFunction(i);
    }

    private void compileFunctionBody(FuncDeclaration function_) {
        locals = null;
        currentFunction = function_;
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

        if (auto if_ = statement.isIfStatement) {
            compileIfStatement(if_);
            return;
        }

        if (auto throw_ = statement.isThrowStatement) {
            compileThrow(throw_);
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported bytecode statement: ", statement.stmt));
    }

    private void compileIfStatement(
        imported!"dmd.statement".IfStatement if_,
    ) {
        compileExpression(if_.condition);
        const falseJump = emitJump(Op.jumpIfFalse);
        program.instructions ~= Instruction(Op.pop);

        compileStatement(if_.ifbody);
        const endJump = emitJump(Op.jump);

        patchJump(falseJump);
        program.instructions ~= Instruction(Op.pop);
        compileStatement(if_.elsebody);

        patchJump(endJump);
    }

    private void compileExpression(
        Expression expression,
    )
    {
        import std.string: fromStringz;

        if (isUndisplayableFunctionLiteral(expression)) {
            program.instructions ~= Instruction(
                Op.literal,
                Value.undisplayable,
            );
            return;
        }

        if (auto integer = expression.isIntegerExp) {
            program.instructions ~= Instruction(
                Op.literal,
                integerValue(integer),
            );
            return;
        }

        if (expression.isNullExp !is null) {
            program.instructions ~= Instruction(
                Op.literal,
                Value.null_,
            );
            return;
        }

        if (auto declaration = expression.isDeclarationExp) {
            auto variable = declaration.declaration.isVarDeclaration;
            if (variable is null)
                return;

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
            compileBinaryExpression(equal, equalityOp(equal));
            return;
        }

        if (auto identity = expression.isIdentityExp) {
            compileBinaryExpression(identity, identityOp(identity));
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

        if (auto increment = expression.isPostExp) {
            compilePostIncrement(increment);
            return;
        }

        if (auto addAssign = expression.isAddAssignExp) {
            compileAddAssign(addAssign);
            return;
        }

        if (auto assignment = expression.isAssignExp) {
            compileAssign(assignment);
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

        if (auto typeid_ = expression.isTypeidExp) {
            compileTypeid(typeid_);
            return;
        }

        if (auto dot = expression.isDotVarExp) {
            compileDotVarExpression(dot);
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

    private bool isUndisplayableFunctionLiteral(Expression expression) {
        if (expression.isFuncExp !is null)
            return true;

        if (expression.isDelegateExp !is null)
            return true;

        if (auto symbol = expression.isSymOffExp)
            return symbol.var.isFuncDeclaration !is null;

        return false;
    }

    private void compileAssertComparison(BinExp expression, in Op op) {
        compileExpression(expression.e1);
        compileExpression(expression.e2);
        program.instructions ~= Instruction(
            Op.assertCompare,
            Value.void_,
            op,
        );
    }

    private void compileComparisonExpression(CmpExp expression) {
        import dmd.tokens: EXP;

        if (expression.op == EXP.lessThan) {
            compileBinaryExpression(expression, Op.lessThan);
            return;
        }

        if (expression.op == EXP.lessOrEqual) {
            compileBinaryExpression(expression, Op.lessOrEqual);
            return;
        }

        if (expression.op == EXP.greaterThan) {
            compileBinaryExpression(expression, Op.greaterThan);
            return;
        }

        if (expression.op == EXP.greaterOrEqual) {
            compileBinaryExpression(expression, Op.greaterOrEqual);
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
            expression.op == EXP.lessOrEqual ||
            expression.op == EXP.greaterThan ||
            expression.op == EXP.greaterOrEqual;
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
        if (variable._init !is null &&
            variable._init.isVoidInitializer !is null) {
            program.instructions ~= Instruction(
                Op.initializeLocal,
                Value.void_,
                localIndex(variable),
            );
            return;
        }

        if (variable._init !is null) {
            auto initializer = variable._init.isExpInitializer;
            if (initializer is null)
                throw new Exception("Unsupported bytecode initializer.");

            auto expression = initializerExpression(initializer.exp);
            if (expression.isVoidInitExp !is null) {
                program.instructions ~= Instruction(
                    Op.initializeLocal,
                    Value.void_,
                    localIndex(variable),
                );
                return;
            }

            compileExpression(expression);

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
            Value(uninitializedVariableMessage(variable)),
            localIndex(variable),
        );
    }

    private string uninitializedVariableMessage(VarDeclaration variable) {
        import std.conv: text;

        const functionName = currentFunction is null
            ? "<unknown>"
            : currentFunction.ident.toString;

        return text(
            "cannot read uninitialized variable `.",
            functionName,
            ".",
            variable.ident.toString,
            "` in ctfe",
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

    private void compilePostIncrement(
        PostExp increment,
    ) {
        import dmd.tokens: EXP;

        if (increment.op != EXP.plusPlus)
            throw new Exception("Unsupported bytecode post-increment.");

        auto variable = increment.e1.isVarExp;
        if (variable is null)
            throw new Exception("Unsupported bytecode post-increment target.");

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception("Unsupported bytecode post-increment target.");

        compileVariableLoad(declaration);
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

    private void compileAssign(
        AssignExp assignment,
    ) {
        auto variable = assignment.e1.isVarExp;
        if (variable is null)
            throw new Exception("Unsupported bytecode assignment target.");

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception("Unsupported bytecode assignment target.");

        compileExpression(assignment.e2);
        program.instructions ~= Instruction(
            Op.storeLocal,
            Value.void_,
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

            compileClassMethodReceiverCheck(call);

            if (call.arguments !is null)
                foreach (index, argument; *call.arguments)
                    compileCallArgument(function_, index, argument);

            program.instructions ~= Instruction(
                Op.call,
                Value.void_,
                functionIndex(function_),
            );
            return;
        }

        compileBuiltinCall(call);
    }

    private void compileClassMethodReceiverCheck(CallExp call) {
        auto dot = call.e1.isDotVarExp;
        if (dot is null)
            return;

        compileExpression(dot.e1);
        program.instructions ~= Instruction(Op.throwIfNullClassMethod);
        program.instructions ~= Instruction(Op.pop);
    }

    private void compileDotVarExpression(DotVarExp dot) {
        compileExpression(dot.e1);
        program.instructions ~= Instruction(
            Op.throwIfNullClassField,
            Value(nullClassFieldMessage(dot)),
        );
        program.instructions ~= Instruction(Op.pop);
        program.instructions ~= Instruction(
            Op.literal,
            Value("Unsupported bytecode field read."),
        );
        program.instructions ~= Instruction(Op.throw_);
    }

    private void compileTypeid(TypeidExp typeid_) {
        import dmd.dtemplate: isExpression;

        auto expression = isExpression(typeid_.obj);
        if (expression !is null) {
            compileExpression(expression);
            program.instructions ~= Instruction(
                Op.throwIfNullClassField,
                Value(nullTypeidMessage(expression)),
            );
            program.instructions ~= Instruction(Op.pop);
        }

        program.instructions ~= Instruction(
            Op.literal,
            Value.typeName("bytecode.typeid"),
        );
    }

    private string nullTypeidMessage(Expression expression) {
        import std.conv: text;

        return text(
            "null pointer dereference evaluating typeid. `",
            receiverName(expression),
            "` is `null`",
        );
    }

    private string nullClassFieldMessage(DotVarExp dot) {
        import std.conv: text;

        return text(
            "class `",
            receiverName(dot.e1),
            "` is `null` and cannot be dereferenced",
        );
    }

    private string receiverName(Expression receiver) {
        auto variable = receiver.isVarExp;
        if (variable is null)
            return "null";

        return variable.var.ident.toString.idup;
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
            case isinfinity:
            case isnan:
            case pow:
            case sqrt:
                return true;

            default:
                break;
        }

        if (function_.ident !is null && function_.ident.toString == "signbit")
            return true;

        return false;
    }

    private void compileAssert(AssertExp assert_) {
        if (compileDmdAssertFailMessage(assert_.msg))
            return;

        if (compileDynamicAssertMessage(assert_))
            return;

        if (auto equal = assert_.e1.isEqualExp) {
            compileAssertComparison(equal, equalityOp(equal));
            return;
        }

        if (isComparisonExpression(assert_.e1)) {
            import dmd.tokens: EXP;

            auto comparison = castComparisonExpression(assert_.e1);
            if (comparison.op == EXP.lessThan) {
                compileAssertComparison(comparison, Op.lessThan);
                return;
            }

            if (comparison.op == EXP.lessOrEqual) {
                compileAssertComparison(comparison, Op.lessOrEqual);
                return;
            }

            if (comparison.op == EXP.greaterThan) {
                compileAssertComparison(comparison, Op.greaterThan);
                return;
            }

            if (comparison.op == EXP.greaterOrEqual) {
                compileAssertComparison(comparison, Op.greaterOrEqual);
                return;
            }
        }

        if (auto not = assert_.e1.isNotExp) {
            compileExpression(not.e1);
            program.instructions ~= Instruction(Op.assertFalse);
            return;
        }

        compileExpression(assert_.e1);
        program.instructions ~= Instruction(
            Op.assertTrue,
            assertTrueMessageValue(assert_),
        );
    }

    private bool compileDynamicAssertMessage(AssertExp assert_) {
        if (!isVariableAssertMessage(assert_.msg))
            return false;

        compileExpression(assert_.e1);
        const messageJump = emitJump(Op.jumpIfFalse);
        program.instructions ~= Instruction(Op.pop);
        const endJump = emitJump(Op.jump);

        patchJump(messageJump);
        program.instructions ~= Instruction(Op.pop);
        compileAssertMessageExpression(assert_.msg);
        program.instructions ~= Instruction(Op.throw_);

        patchJump(endJump);
        return true;
    }

    private bool isVariableAssertMessage(Expression expression) {
        if (expression is null)
            return false;

        if (expression.isVarExp !is null)
            return true;

        if (auto cast_ = expression.isCastExp)
            return isVariableAssertMessage(cast_.e1);

        return false;
    }

    private void compileAssertMessageExpression(Expression expression) {
        if (auto cast_ = expression.isCastExp) {
            compileAssertMessageExpression(cast_.e1);
            return;
        }

        compileExpression(expression);
    }

    private void compileThrow(imported!"dmd.statement".ThrowStatement throw_) {
        auto new_ = throw_.exp.isNewExp;
        if (new_ is null || new_.arguments is null || new_.arguments.length == 0)
            throw new Exception("Unsupported bytecode throw expression.");

        compileExpression((*new_.arguments)[0]);
        program.instructions ~= Instruction(Op.throw_);
    }

    private bool compileDmdAssertFailMessage(Expression message) {
        if (message is null)
            return false;

        auto call = message.isCallExp;
        if (call is null || call.arguments is null)
            return false;

        if (call.arguments.length != 3)
            return false;

        auto operator = (*call.arguments)[0].isStringExp;
        if (operator is null)
            return false;

        const operatorText = stringChars(operator);
        if (operatorText != "==" && operatorText != "!=")
            return false;

        compileExpression((*call.arguments)[1]);
        compileExpression((*call.arguments)[2]);
        program.instructions ~= Instruction(
            Op.assertCompare,
            Value.void_,
            operatorText == "==" ? Op.equal : Op.notEqual,
        );
        return true;
    }

    private Op equalityOp(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;

        return equal.op == EXP.notEqual ? Op.notEqual : Op.equal;
    }

    private Op identityOp(IdentityExp identity) {
        import dmd.tokens: EXP;

        return identity.op == EXP.notIdentity ? Op.notEqual : Op.equal;
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

    private Value assertTrueMessageValue(AssertExp assert_) {
        if (assert_.msg !is null && assert_.msg.isStringExp is null)
            return Value.void_;

        if (assert_.msg is null && assert_.e1.isIntegerExp is null)
            return Value.void_;

        return assertMessageValue(assert_);
    }

    private size_t functionIndex(FuncDeclaration function_) {
        if (auto existing = function_ in functionIndices)
            return *existing;

        const index = functions.length;
        functions ~= function_;
        functionIndices[function_] = index;
        program.functions ~= Function(
            0,
            parameterCount(function_),
            refParameters(function_),
        );
        return index;
    }

    private void compileCallArgument(
        FuncDeclaration function_,
        in size_t index,
        Expression argument,
    ) {
        if (!parameterIsRef(function_, index)) {
            compileExpression(argument);
            return;
        }

        auto variable = argument.isVarExp;
        if (variable is null)
            throw new Exception("Unsupported bytecode ref argument.");

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception("Unsupported bytecode ref argument.");

        program.instructions ~= Instruction(
            Op.loadLocalReference,
            Value.void_,
            localIndex(declaration),
        );
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

    private bool[] refParameters(FuncDeclaration function_) {
        bool[] result;
        if (function_.parameters is null)
            return result;

        foreach (parameter; *function_.parameters)
            result ~= declarationIsRef(parameter);

        return result;
    }

    private bool parameterIsRef(
        FuncDeclaration function_,
        in size_t index,
    ) {
        if (function_.parameters is null || index >= function_.parameters.length)
            return false;

        return declarationIsRef((*function_.parameters)[index]);
    }

    private void registerParameters(FuncDeclaration function_) {
        if (function_.parameters is null)
            return;

        foreach (parameter; *function_.parameters)
            localIndex(parameter);
    }

    private bool declarationIsRef(VarDeclaration parameter) {
        import dmd.astenums: STC;

        enum refLike = STC.ref_ | STC.out_;
        return (parameter.storage_class & refLike) != STC.none;
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

module quickbite.frontend.lowering;

private:

public imported!"quickbite.ir.module_".Module lowerModule(
    imported!"dmd.dmodule".Module module_,
) @safe {
    return Lowerer(module_).lower;
}

struct Lowerer {
    private imported!"dmd.dmodule".Module sourceModule;
    private imported!"quickbite.ir.module_".Module loweredModule;
    private bool[string] loweredFunctions;

    this(imported!"dmd.dmodule".Module module_) @safe {
        sourceModule = module_;
    }

    imported!"quickbite.ir.module_".Module lower() @safe {
        if (sourceModule.members is null)
            return loweredModule;

        import quickbite.dmd_util: foreachUnitTestDeclaration;
        foreachUnitTestDeclaration(sourceModule, (unitTest) {
            loweredModule.tests ~= lowerTest(unitTest);
        });

        return loweredModule;
    }

    // DMD AST query helpers used below are not const-qualified.
    imported!"quickbite.ir.test".Test lowerTest(
        imported!"dmd.declaration".UnitTestDeclaration unitTest,
    ) @safe {
        import quickbite.ir.instruction: Instruction, ReturnVoid;

        imported!"quickbite.ir.test".Test result;
        BodyLowerer builder;

        builder.currentFunctionName = "<unittest>";
        builder.lowerStatement(unitTest.fbody, this);
        builder.assertNoPendingGotos;
        builder.instructions ~= Instruction(ReturnVoid.init);
        result.instructions = builder.instructions.dup;
        result.numTemporaries = builder.nextTemporary;
        return result;
    }

    // DMD FuncDeclaration methods used for lowering are not const-qualified.
    void ensureFunctionLowered(imported!"dmd.func".FuncDeclaration function_) @safe {
        import quickbite.ir.function_: Function;

        const name = functionName(function_);
        if (name in loweredFunctions)
            return;

        if (function_.fbody is null) {
            import std.conv: text;

            throw new Exception(text("No function body to execute: ", name));
        }

        loweredFunctions[name] = true;

        BodyLowerer builder;
        builder.currentFunctionName = name;
        builder.currentReturnType = functionReturnType(function_);
        const numParameters = builder.lowerParameters(function_);
        builder.lowerStatement(function_.fbody, this);
        builder.assertNoPendingGotos;
        const hasReturnValue = !functionReturnsVoid(function_);

        if (hasReturnValue && !builder.hasReturn) {
            import std.conv: text;

            throw new Exception(text("Unsupported function body: ", name));
        }

        Function result;
        result.name = name;
        result.instructions = builder.instructions.dup;
        result.hasReturnValue = hasReturnValue;
        result.numParameters = numParameters;
        result.refParameters = builder.refParameters.dup;
        result.numTemporaries = builder.nextTemporary;
        loweredModule.functions ~= result;
    }

    // DMD mangling distinguishes template instantiations and overloads.
    string functionName(imported!"dmd.func".FuncDeclaration function_) @trusted {
        import dmd.mangle: mangleExact;
        import std.string: fromStringz;

        return fromStringz(mangleExact(function_)).idup;
    }
}

private bool functionReturnsVoid(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    import dmd.astenums: TY;

    return functionReturnType(function_).ty == TY.Tvoid;
}

private imported!"dmd.mtype".Type functionReturnType(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    return function_.type.nextOf;
}

struct BodyLowerer {
    import dmd.declaration: VarDeclaration;
    import dmd.statement: CaseStatement, DefaultStatement, GotoCaseStatement;

    private struct ArrayElementAlias {
        uint array;
        uint index;
        uint value;
    }

    private struct StructFieldAlias {
        uint struct_;
        string fieldName;
        uint value;
    }

    private uint nextTemporary;
    private uint[VarDeclaration] localTemporaries;
    private ArrayElementAlias[VarDeclaration] arrayElementAliases;
    private ArrayElementAlias[] pendingRefArrayWritebacks;
    private StructFieldAlias[] pendingRefStructWritebacks;
    private uint[string] identifierTemporaries;
    private bool[string] arrayValueNames;
    private bool[VarDeclaration] lazyParameters;
    private bool[string] lazyParameterNames;
    private size_t[string] labelInstructionIndices;
    private size_t[][string] pendingGotoInstructionIndices;
    private size_t[][string] pendingBreakInstructionIndices;
    private size_t[][string] pendingContinueInstructionIndices;
    private size_t[CaseStatement] caseInstructionIndices;
    private size_t[][CaseStatement] pendingCaseInstructionIndices;
    private size_t[][CaseStatement] pendingGotoCaseInstructionIndices;
    private size_t[][DefaultStatement] pendingDefaultInstructionIndices;
    private size_t[][] pendingUnlabelledBreakInstructionIndices;
    private size_t[][] pendingUnlabelledContinueInstructionIndices;
    private uint[] dollarArrays;
    private bool hasThisTemporary;
    private uint thisTemporary;
    private bool[string] thisFieldNames;
    public imported!"quickbite.ir.instruction".Instruction[] instructions;
    public bool[] refParameters;
    public bool hasReturn;
    public string currentFunctionName;
    public imported!"dmd.mtype".Type currentReturnType;

    // DMD Statement downcast helpers are not const-qualified.
    void lowerStatement(
        imported!"dmd.statement".Statement statement,
        ref Lowerer lowerer,
    ) @safe {
        if (statement is null)
            return;

        if (auto scope_ = statement.isScopeStatement) {
            if (scope_.statement !is null)
                lowerStatement(scope_.statement, lowerer);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            const compoundEnteredWithReturn = hasReturn;
            foreach (child; compoundStatements(compound)) {
                lowerStatement(child, lowerer);
                if (!compoundEnteredWithReturn && hasReturn && !hasPendingGotos)
                    return;
            }

            return;
        }

        if (statement.isDtorExpStatement !is null)
            return;

        if (auto expressionStatement = statement.isExpStatement) {
            if (expressionStatement.exp !is null)
                lowerExpression(expressionStatement.exp, lowerer);
            return;
        }

        if (auto returnStatement = statement.isReturnStatement) {
            lowerReturnStatement(returnStatement, lowerer);
            hasReturn = true;
            return;
        }

        if (auto ifStatement = statement.isIfStatement) {
            lowerIfStatement(ifStatement, lowerer);
            return;
        }

        if (auto forStatement = statement.isForStatement) {
            lowerForStatement(forStatement, lowerer);
            return;
        }

        if (auto doStatement = statement.isDoStatement) {
            lowerDoStatement(doStatement, lowerer);
            return;
        }

        if (auto withStatement = statement.isWithStatement) {
            lowerStatement(withStatement._body, lowerer);
            return;
        }

        if (auto tryCatch = statement.isTryCatchStatement) {
            lowerStatement(tryCatch._body, lowerer);
            return;
        }

        if (auto tryFinally = statement.isTryFinallyStatement) {
            lowerStatement(tryFinally._body, lowerer);
            if (!hasReturn)
                lowerStatement(tryFinally.finalbody, lowerer);
            return;
        }

        if (auto switchStatement = statement.isSwitchStatement) {
            lowerSwitchStatement(switchStatement, lowerer);
            return;
        }

        if (auto gotoStatement = statement.isGotoStatement) {
            lowerGotoStatement(gotoStatement);
            return;
        }

        if (auto gotoCase = statement.isGotoCaseStatement) {
            lowerGotoCaseStatement(gotoCase);
            return;
        }

        if (auto gotoDefault = statement.isGotoDefaultStatement) {
            lowerGotoDefaultStatement(gotoDefault);
            return;
        }

        if (auto breakStatement = statement.isBreakStatement) {
            lowerBreakStatement(breakStatement);
            return;
        }

        if (auto continueStatement = statement.isContinueStatement) {
            lowerContinueStatement(continueStatement);
            return;
        }

        if (auto labelStatement = statement.isLabelStatement) {
            lowerLabelStatement(labelStatement, lowerer);
            return;
        }

        if (auto caseStatement = statement.isCaseStatement) {
            lowerCaseStatement(caseStatement, lowerer);
            return;
        }

        if (auto defaultStatement = statement.isDefaultStatement) {
            lowerDefaultStatement(defaultStatement, lowerer);
            return;
        }

        if (statement.isThrowStatement !is null) {
            import quickbite.ir.instruction: Assert_, ConstInt, Instruction;
            const zero = allocateTemporary;
            instructions ~= Instruction(ConstInt(zero, 0));
            instructions ~= Instruction(Assert_(zero));
            hasReturn = true;
            return;
        }

        if (statement.isSwitchErrorStatement !is null) {
            import quickbite.ir.instruction: Assert_, ConstInt, Instruction;
            const zero = allocateTemporary;
            instructions ~= Instruction(ConstInt(zero, 0));
            instructions ~= Instruction(Assert_(zero));
            hasReturn = true;
            return;
        }

        if (statement.isImportStatement !is null)
            return;

        if (auto pragmaStatement = statement.isPragmaStatement) {
            lowerStatement(pragmaStatement._body, lowerer);
            return;
        }

        if (auto conditional = statement.isConditionalStatement) {
            lowerStatement(
                conditionalStatementIncluded(conditional)
                    ? conditional.ifbody
                    : conditional.elsebody,
                lowerer,
            );
            return;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            foreach (child; *unrolled.statements) {
                lowerStatement(child, lowerer);
                if (hasReturn)
                    return;
            }
            return;
        }

        import std.conv: text;

        throw new Exception(text(
            "Unsupported statement in ",
            currentFunctionName,
            ": ",
            statement.stmt,
        ));
    }

    void lowerForStatement(
        imported!"dmd.statement".ForStatement statement,
        ref Lowerer lowerer,
        string label = null,
    ) @safe {
        import quickbite.ir.instruction: Instruction, Jump, JumpIfFalse;

        if (statement._init !is null)
            lowerStatement(statement._init, lowerer);

        const loopStart = instructions.length;

        size_t exitJumpIndex;
        bool hasCondition = statement.condition !is null;
        if (hasCondition) {
            const condition = lowerTruthValue(
                lowerExpression(statement.condition, lowerer),
            );
            exitJumpIndex = instructions.length;
            instructions ~= Instruction(JumpIfFalse(condition, 0));
        }

        pendingUnlabelledBreakInstructionIndices ~= cast(size_t[]) [];
        pendingUnlabelledContinueInstructionIndices ~= cast(size_t[]) [];
        if (statement._body !is null)
            lowerStatement(statement._body, lowerer);

        const continueTarget = instructions.length;
        foreach (jumpIndex; pendingUnlabelledContinueInstructionIndices[$ - 1])
            replaceJumpOffset(
                instructions,
                cast(uint) jumpIndex,
                cast(int) (continueTarget - jumpIndex),
            );
        pendingUnlabelledContinueInstructionIndices.length =
            pendingUnlabelledContinueInstructionIndices.length - 1;
        if (label !is null)
            resolveLabelledContinues(label, continueTarget);

        if (statement.increment !is null)
            lowerExpression(statement.increment, lowerer);

        instructions ~= Instruction(Jump(
            cast(int) loopStart - cast(int) instructions.length,
        ));

        if (hasCondition)
            replaceJumpOffset(
                instructions,
                cast(uint) exitJumpIndex,
                cast(int) (instructions.length - exitJumpIndex - 1),
            );

        const hasUnlabelledBreaks =
            pendingUnlabelledBreakInstructionIndices[$ - 1].length != 0;
        foreach (jumpIndex; pendingUnlabelledBreakInstructionIndices[$ - 1])
            replaceJumpOffset(
                instructions,
                cast(uint) jumpIndex,
                cast(int) (instructions.length - jumpIndex),
            );
        pendingUnlabelledBreakInstructionIndices.length =
            pendingUnlabelledBreakInstructionIndices.length - 1;
        if (!hasCondition && !hasUnlabelledBreaks)
            hasReturn = true;
    }

    void lowerDoStatement(
        imported!"dmd.statement".DoStatement statement,
        ref Lowerer lowerer,
        string label = null,
    ) @safe {
        import quickbite.ir.instruction: Instruction, JumpIfTrue;

        const loopStart = instructions.length;
        pendingUnlabelledBreakInstructionIndices ~= cast(size_t[]) [];
        pendingUnlabelledContinueInstructionIndices ~= cast(size_t[]) [];
        if (statement._body !is null)
            lowerStatement(statement._body, lowerer);

        const continueTarget = instructions.length;
        foreach (jumpIndex; pendingUnlabelledContinueInstructionIndices[$ - 1])
            replaceJumpOffset(
                instructions,
                cast(uint) jumpIndex,
                cast(int) (continueTarget - jumpIndex),
            );
        pendingUnlabelledContinueInstructionIndices.length =
            pendingUnlabelledContinueInstructionIndices.length - 1;
        if (label !is null)
            resolveLabelledContinues(label, continueTarget);

        const condition = lowerTruthValue(lowerExpression(statement.condition, lowerer));
        instructions ~= Instruction(JumpIfTrue(
            condition,
            cast(int) loopStart - cast(int) instructions.length - 1,
        ));

        foreach (jumpIndex; pendingUnlabelledBreakInstructionIndices[$ - 1])
            replaceJumpOffset(
                instructions,
                cast(uint) jumpIndex,
                cast(int) (instructions.length - jumpIndex),
            );
        pendingUnlabelledBreakInstructionIndices.length =
            pendingUnlabelledBreakInstructionIndices.length - 1;
    }

    void lowerSwitchStatement(
        imported!"dmd.statement".SwitchStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: BinaryOp, Instruction, Jump,
            JumpIfTrue, Operation;
        import std.conv: text;

        if (statement.cases is null)
            throw new Exception("Unsupported switch without cases");

        const condition = lowerExpression(statement.condition, lowerer);

        foreach (caseStatement; *statement.cases) {
            const caseValue = lowerExpression(caseStatement.exp, lowerer);
            const matched = allocateTemporary;
            instructions ~= Instruction(BinaryOp(
                matched,
                condition,
                caseValue,
                Operation.equal,
            ));

            const jumpIndex = instructions.length;
            instructions ~= Instruction(JumpIfTrue(matched, 0));
            pendingCaseInstructionIndices[caseStatement] = [jumpIndex];
        }

        size_t skipBodyJumpIndex = size_t.max;
        if (statement.sdefault is null) {
            skipBodyJumpIndex = instructions.length;
            instructions ~= Instruction(Jump(0));
        } else {
            const jumpIndex = instructions.length;
            instructions ~= Instruction(Jump(0));
            pendingDefaultInstructionIndices[statement.sdefault] = [jumpIndex];
        }

        pendingUnlabelledBreakInstructionIndices ~= cast(size_t[]) [];
        lowerStatement(statement._body, lowerer);

        foreach (jumpIndex; pendingUnlabelledBreakInstructionIndices[$ - 1])
            replaceJumpOffset(
                instructions,
                cast(uint) jumpIndex,
                cast(int) (instructions.length - jumpIndex),
            );
        pendingUnlabelledBreakInstructionIndices.length =
            pendingUnlabelledBreakInstructionIndices.length - 1;

        if (skipBodyJumpIndex != size_t.max)
            replaceJumpOffset(
                instructions,
                cast(uint) skipBodyJumpIndex,
                cast(int) (instructions.length - skipBodyJumpIndex),
            );
    }

    void lowerGotoStatement(
        imported!"dmd.statement".GotoStatement statement,
    ) @safe {
        import quickbite.ir.instruction: Instruction, Jump;
        import std.conv: text;

        const label = gotoLabel(statement);

        if (statement.label is null || statement.label.statement is null)
            throw new Exception(text("Unsupported unresolved goto: ", label));

        const jumpIndex = instructions.length;
        if (const labelInstructionIndex = label in labelInstructionIndices) {
            instructions ~= Instruction(Jump(
                cast(int) *labelInstructionIndex - cast(int) jumpIndex,
            ));
            return;
        }

        instructions ~= Instruction(Jump(0));

        if (auto pending = label in pendingGotoInstructionIndices)
            *pending ~= jumpIndex;
        else
            pendingGotoInstructionIndices[label] = [jumpIndex];
    }

    void lowerGotoCaseStatement(GotoCaseStatement statement) @safe {
        import quickbite.ir.instruction: Instruction, Jump;

        if (statement.cs is null)
            throw new Exception("Unsupported unresolved goto case");

        const jumpIndex = instructions.length;
        if (const caseInstructionIndex = statement.cs in caseInstructionIndices) {
            instructions ~= Instruction(Jump(
                cast(int) *caseInstructionIndex - cast(int) jumpIndex,
            ));
            return;
        }

        instructions ~= Instruction(Jump(0));

        if (auto pending = statement.cs in pendingGotoCaseInstructionIndices)
            *pending ~= jumpIndex;
        else
            pendingGotoCaseInstructionIndices[statement.cs] = [jumpIndex];
    }

    void lowerGotoDefaultStatement(
        imported!"dmd.statement".GotoDefaultStatement statement,
    ) @safe {
        import quickbite.ir.instruction: Instruction, Jump;

        const jumpIndex = instructions.length;
        instructions ~= Instruction(Jump(0));

        if (auto pending = statement.sw.sdefault in pendingDefaultInstructionIndices)
            *pending ~= jumpIndex;
        else
            pendingDefaultInstructionIndices[statement.sw.sdefault] = [jumpIndex];
    }

    void lowerBreakStatement(
        imported!"dmd.statement".BreakStatement statement,
    ) @safe {
        import quickbite.ir.instruction: Instruction, Jump;
        import std.conv: text;

        if (statement.ident is null) {
            if (pendingUnlabelledBreakInstructionIndices.length == 0)
                throw new Exception("Unsupported unlabelled break");

            const jumpIndex = instructions.length;
            instructions ~= Instruction(Jump(0));
            pendingUnlabelledBreakInstructionIndices[$ - 1] ~= jumpIndex;
            return;
        }

        const label = breakLabel(statement);
        const jumpIndex = instructions.length;
        instructions ~= Instruction(Jump(0));

        if (auto pending = label in pendingBreakInstructionIndices)
            *pending ~= jumpIndex;
        else
            pendingBreakInstructionIndices[label] = [jumpIndex];
    }

    void lowerContinueStatement(
        imported!"dmd.statement".ContinueStatement statement,
    ) @safe {
        import quickbite.ir.instruction: Instruction, Jump;

        if (statement.ident !is null) {
            const label = continueLabel(statement);
            const jumpIndex = instructions.length;
            instructions ~= Instruction(Jump(0));

            if (auto pending = label in pendingContinueInstructionIndices)
                *pending ~= jumpIndex;
            else
                pendingContinueInstructionIndices[label] = [jumpIndex];
            return;
        }

        if (pendingUnlabelledContinueInstructionIndices.length == 0)
            throw new Exception("Unsupported unlabelled continue");

        const jumpIndex = instructions.length;
        instructions ~= Instruction(Jump(0));
        pendingUnlabelledContinueInstructionIndices[$ - 1] ~= jumpIndex;
    }

    void lowerLabelStatement(
        imported!"dmd.statement".LabelStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        // AA.remove currently needs a mutable key.
        string label = statementLabel(statement);

        labelInstructionIndices[label] = instructions.length;

        if (auto pending = label in pendingGotoInstructionIndices) {
            foreach (jumpIndex; *pending)
                replaceJumpOffset(
                    instructions,
                    cast(uint) jumpIndex,
                    cast(int) (instructions.length - jumpIndex),
                );

            pendingGotoInstructionIndices.remove(label);
        }

        if (auto for_ = statement.statement.isForStatement)
            lowerForStatement(for_, lowerer, label);
        else if (auto do_ = statement.statement.isDoStatement)
            lowerDoStatement(do_, lowerer, label);
        else
            lowerStatement(statement.statement, lowerer);

        if (auto pending = label in pendingBreakInstructionIndices) {
            foreach (jumpIndex; *pending)
                replaceJumpOffset(
                    instructions,
                    cast(uint) jumpIndex,
                    cast(int) (instructions.length - jumpIndex),
                );

            pendingBreakInstructionIndices.remove(label);
        }
    }

    void resolveLabelledContinues(string label, in size_t continueTarget) @safe {
        if (auto pending = label in pendingContinueInstructionIndices) {
            foreach (jumpIndex; *pending)
                replaceJumpOffset(
                    instructions,
                    cast(uint) jumpIndex,
                    cast(int) (continueTarget - jumpIndex),
                );

            pendingContinueInstructionIndices.remove(label);
        }
    }

    void lowerCaseStatement(
        imported!"dmd.statement".CaseStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        import std.conv: text;

        auto pending = statement in pendingCaseInstructionIndices;
        if (pending is null)
            throw new Exception(text(
                "Unsupported case: ",
                expressionChars(statement.exp),
            ));

        foreach (jumpIndex; *pending)
            replaceJumpOffset(
                instructions,
                cast(uint) jumpIndex,
                cast(int) (instructions.length - jumpIndex - 1),
            );

        pendingCaseInstructionIndices.remove(statement);
        caseInstructionIndices[statement] = instructions.length;

        if (auto gotoCasePending = statement in pendingGotoCaseInstructionIndices) {
            foreach (jumpIndex; *gotoCasePending)
                replaceJumpOffset(
                    instructions,
                    cast(uint) jumpIndex,
                    cast(int) (instructions.length - jumpIndex),
                );

            pendingGotoCaseInstructionIndices.remove(statement);
        }

        lowerStatement(statement.statement, lowerer);
    }

    void lowerDefaultStatement(
        imported!"dmd.statement".DefaultStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        auto pending = statement in pendingDefaultInstructionIndices;
        if (pending !is null) {
            foreach (jumpIndex; *pending)
                replaceJumpOffset(
                    instructions,
                    cast(uint) jumpIndex,
                    cast(int) (instructions.length - jumpIndex),
                );

            pendingDefaultInstructionIndices.remove(statement);
        }

        lowerStatement(statement.statement, lowerer);
    }

    void assertNoPendingGotos() @safe {
        if (pendingGotoInstructionIndices.length == 0
            && pendingBreakInstructionIndices.length == 0
            && pendingContinueInstructionIndices.length == 0)
            return;

        import std.conv: text;

        foreach (label, jumpIndices; pendingGotoInstructionIndices)
            throw new Exception(text(
                "Unsupported unresolved goto: ",
                label,
                " (",
                jumpIndices.length,
                ")",
            ));

        foreach (label, jumpIndices; pendingBreakInstructionIndices)
            throw new Exception(text(
                "Unsupported unresolved break: ",
                label,
                " (",
                jumpIndices.length,
                ")",
            ));

        foreach (label, jumpIndices; pendingContinueInstructionIndices)
            throw new Exception(text(
                "Unsupported unresolved continue: ",
                label,
                " (",
                jumpIndices.length,
                ")",
            ));

        foreach (caseStatement, jumpIndices; pendingCaseInstructionIndices)
            throw new Exception(text(
                "Unsupported unresolved switch case: ",
                expressionChars(caseStatement.exp),
                " (",
                jumpIndices.length,
                ")",
            ));

        foreach (caseStatement, jumpIndices; pendingGotoCaseInstructionIndices)
            throw new Exception(text(
                "Unsupported unresolved goto case: ",
                expressionChars(caseStatement.exp),
                " (",
                jumpIndices.length,
                ")",
            ));

        foreach (jumpIndices; pendingDefaultInstructionIndices)
            throw new Exception(text(
                "Unsupported unresolved switch default (",
                jumpIndices.length,
                ")",
            ));
    }

    bool hasPendingGotos() @safe pure nothrow @nogc {
        return pendingGotoInstructionIndices.length != 0
            || pendingCaseInstructionIndices.length != 0
            || pendingGotoCaseInstructionIndices.length != 0
            || pendingDefaultInstructionIndices.length != 0;
    }

    // DMD Expression downcast/accessor helpers are not const-qualified.
    uint lowerExpression(
        imported!"dmd.expression".Expression expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Assert_, Call, ConstInt, Instruction,
            Operation, StaticAssocArray, StructGet, UnaryOp, UnaryOperation;

        if (auto integer = expression.isIntegerExp) {
            const destination = allocateTemporary;
            instructions ~= Instruction(ConstInt(
                destination,
                integerValue(integer),
            ));
            return destination;
        }

        if (auto real_ = expression.isRealExp) {
            const destination = allocateTemporary;
            instructions ~= Instruction(ConstInt(
                destination,
                realLiteralValue(real_),
            ));
            return destination;
        }

        if (expression.isNullExp) {
            if (typeIsAssociativeArray(expression.type)) {
                import quickbite.ir.instruction: AssocArrayLiteral;

                const destination = allocateTemporary;
                instructions ~= Instruction(AssocArrayLiteral(destination, [], []));
                return destination;
            }

            const destination = allocateTemporary;
            instructions ~= Instruction(ConstInt(destination, 0));
            return destination;
        }

        if (expression.isDollarExp)
            return lowerDollar;

        if (auto literal = expression.isArrayLiteralExp)
            return lowerArrayLiteral(literal, lowerer);

        if (auto literal = expression.isStringExp)
            return lowerStringLiteral(literal);

        if (auto literal = expression.isAssocArrayLiteralExp)
            return lowerAssocArrayLiteral(literal, lowerer);

        if (auto slice = expression.isSliceExp)
            return lowerArraySlice(slice, lowerer);

        if (auto call = expression.isCallExp) {
            if (call.f is null) {
                if (callHasNoArguments(call))
                    if (auto variable = call.e1.isVarExp)
                        if (auto function_ = variable.var.isFuncDeclaration) {
                            if (function_.isFuncLiteralDeclaration !is null)
                                return lowerImmediateFunctionLiteralCall(function_, lowerer);

                            lowerer.ensureFunctionLowered(function_);
                            const destination = allocateTemporary;
                            instructions ~= Instruction(Call(
                                destination,
                                lowerer.functionName(function_),
                                [],
                            ));
                            return destination;
                        }
                if (callHasNoArguments(call))
                    if (auto variable = call.e1.isVarExp)
                        if (auto var = variable.var.isVarDeclaration)
                            if ((var in lazyParameters) !is null)
                                return lowerExpression(call.e1, lowerer);
                if (callHasNoArguments(call))
                    if (auto temporary = expressionChars(call.e1) in identifierTemporaries)
                        return *temporary;
                if (callHasNoArguments(call))
                    if (auto identifier = call.e1.isIdentifierExp)
                        if (
                            (identifierName(identifier) in lazyParameterNames) !is null ||
                            (identifierName(identifier) in identifierTemporaries) !is null
                        )
                            return lowerExpression(call.e1, lowerer);

                uint builtinResult;
                if (tryLowerUnresolvedBuiltinCall(call, lowerer, builtinResult))
                    return builtinResult;

                uint indirectResult;
                if (tryLowerFunctionPointerTableCall(call, lowerer, indirectResult))
                    return indirectResult;

                if (tryLowerIndirectFunctionPointerCall(call, lowerer, indirectResult))
                    return indirectResult;

                if (callHasNoArguments(call) && expressionChars(call.e1) == "expr") {
                    const destination = allocateTemporary;
                    instructions ~= Instruction(ConstInt(destination, 0));
                    return destination;
                }

                import std.conv: text;

                throw new Exception(text(
                    "Unsupported callee: ",
                    expressionChars(call.e1),
                    " op=",
                    call.e1.op,
                    " at ",
                    locationChars(call.loc),
                ));
            }

            if (isArrayEqualityCall(call))
                return lowerArrayEqualityCall(call, lowerer);

            uint builtinResult;
            if (tryLowerAssocArrayBuiltinCall(call, lowerer, builtinResult))
                return builtinResult;

            if (tryLowerAppenderBuiltinCall(call, lowerer, builtinResult))
                return builtinResult;

            if (tryLowerDynamicArrayRangeCall(call, lowerer, builtinResult))
                return builtinResult;

            if (tryLowerRuntimeBuiltinCall(call, lowerer, builtinResult))
                return builtinResult;

            if (call.f.isFuncLiteralDeclaration !is null)
                return lowerImmediateFunctionLiteralCall(call.f, call, lowerer);

            uint scopeBufferRangeResult;
            if (
                tryLowerScopeBufferRangeConstructor(
                    call,
                    lowerer,
                    scopeBufferRangeResult,
                )
            )
                return scopeBufferRangeResult;

            uint cerealiserResult;
            if (tryLowerCerealiserImplConstructor(call, lowerer, cerealiserResult))
                return cerealiserResult;

            uint scopeBufferResult;
            if (tryLowerScopeBufferCall(call, lowerer, scopeBufferResult))
                return scopeBufferResult;

            lowerer.ensureFunctionLowered(call.f);
            // `const` would make the array incompatible with Call.arguments.
            // auto: keep the mutable array type for restoring the field below.
            auto savedArrayWritebacks = pendingRefArrayWritebacks;
            auto savedStructWritebacks = pendingRefStructWritebacks;
            pendingRefArrayWritebacks = [];
            pendingRefStructWritebacks = [];
            auto arguments = lowerCallArguments(call, lowerer);
            // auto: ArraySet emission needs mutable element values.
            auto arrayWritebacks = pendingRefArrayWritebacks;
            auto structWritebacks = pendingRefStructWritebacks;
            pendingRefArrayWritebacks = savedArrayWritebacks;
            pendingRefStructWritebacks = savedStructWritebacks;

            const destination = allocateTemporary;
            instructions ~= Instruction(Call(
                destination,
                lowerer.functionName(call.f),
                arguments,
            ));
            foreach (writeback; arrayWritebacks)
                instructions ~= Instruction(imported!"quickbite.ir.instruction".ArraySet(
                    writeback.array,
                    writeback.index,
                    writeback.value,
                ));
            foreach (writeback; structWritebacks)
                instructions ~= Instruction(imported!"quickbite.ir.instruction".StructSet(
                    writeback.struct_,
                    writeback.fieldName,
                    writeback.value,
                ));
            return destination;
        }

        if (auto equal = expression.isEqualExp) {
            import dmd.tokens: EXP;

            if (equal.lowering !is null)
                return lowerExpression(equal.lowering, lowerer);

            if (typeIsDynamicArray(equal.e1.type) && typeIsDynamicArray(equal.e2.type))
                return lowerArrayEqualityExpression(equal, lowerer);

            if (equal.op == EXP.notEqual)
                return lowerBinaryExpression(equal, Operation.notEqual, lowerer);

            return lowerBinaryExpression(equal, Operation.equal, lowerer);
        }

        // DMD has typed accessors for arithmetic expressions but not CmpExp,
        // so comparisons dispatch by operator and then narrow through a
        // checked @trusted cast.
        import dmd.tokens: EXP;

        if (expression.op == EXP.lessThan)
            return lowerComparison(
                castCmpExpression(expression),
                Operation.lessThan,
                Operation.unsignedLessThan,
                lowerer,
            );

        if (expression.op == EXP.lessOrEqual)
            return lowerComparison(
                castCmpExpression(expression),
                Operation.lessOrEqual,
                Operation.unsignedLessOrEqual,
                lowerer,
            );

        if (expression.op == EXP.greaterThan)
            return lowerComparison(
                castCmpExpression(expression),
                Operation.greaterThan,
                Operation.unsignedGreaterThan,
                lowerer,
            );

        if (expression.op == EXP.greaterOrEqual)
            return lowerComparison(
                castCmpExpression(expression),
                Operation.greaterOrEqual,
                Operation.unsignedGreaterOrEqual,
                lowerer,
            );

        if (auto identity = expression.isIdentityExp) {
            if (identity.op == EXP.notIdentity)
                return lowerBinaryExpression(identity, Operation.notEqual, lowerer);

            return lowerBinaryExpression(identity, Operation.equal, lowerer);
        }

        if (auto logical = expression.isLogicalExp) {
            if (logical.op == EXP.andAnd)
                return lowerLogicalAnd(logical, lowerer);

            if (logical.op == EXP.orOr)
                return lowerLogicalOr(logical, lowerer);
        }

        if (auto conditional = expression.isCondExp)
            return lowerConditionalExpression(conditional, lowerer);

        if (auto concatenate = expression.isCatExp)
            return lowerArrayConcatenation(concatenate, lowerer);

        if (auto add = expression.isAddExp)
            return lowerBinaryExpression(add, Operation.add, lowerer);

        if (auto subtract = expression.isMinExp)
            return lowerBinaryExpression(subtract, Operation.subtract, lowerer);

        if (auto multiply = expression.isMulExp)
            return lowerBinaryExpression(multiply, Operation.multiply, lowerer);

        if (auto divide = expression.isDivExp)
            return lowerBinaryExpression(divide, Operation.divide, lowerer);

        if (auto modulo = expression.isModExp)
            return lowerBinaryExpression(modulo, Operation.modulo, lowerer);

        if (auto leftShift = expression.isShlExp)
            return lowerBinaryExpression(leftShift, Operation.leftShift, lowerer);

        if (auto rightShift = expression.isShrExp)
            return lowerBinaryExpression(rightShift, Operation.rightShift, lowerer);

        if (auto and = expression.isAndExp)
            return lowerBinaryExpression(and, Operation.bitwiseAnd, lowerer);

        if (auto or = expression.isOrExp)
            return lowerBinaryExpression(or, Operation.bitwiseOr, lowerer);

        if (auto xor = expression.isXorExp)
            return lowerBinaryExpression(xor, Operation.bitwiseXor, lowerer);

        if (auto negate = expression.isNegExp) {
            const value = lowerExpression(negate.e1, lowerer);
            const destination = allocateTemporary;
            instructions ~= Instruction(UnaryOp(
                destination,
                value,
                UnaryOperation.negate,
            ));
            return destination;
        }

        if (auto positive = expression.isUAddExp)
            return lowerExpression(positive.e1, lowerer);

        if (auto not = expression.isNotExp) {
            const value = lowerExpression(not.e1, lowerer);
            const destination = allocateTemporary;
            instructions ~= Instruction(UnaryOp(
                destination,
                value,
                UnaryOperation.not,
            ));
            return destination;
        }

        if (auto complement = expression.isComExp) {
            const value = lowerExpression(complement.e1, lowerer);
            const destination = allocateTemporary;
            instructions ~= Instruction(UnaryOp(
                destination,
                value,
                UnaryOperation.complement,
            ));
            return destination;
        }

        if (auto cast_ = expression.isCastExp)
            return lowerCast(cast_, lowerer);

        if (auto comma = expression.isCommaExp) {
            lowerExpression(comma.e1, lowerer);
            return lowerExpression(comma.e2, lowerer);
        }

        if (auto tuple = expression.isTupleExp)
            return lowerTupleExpression(tuple, lowerer);

        if (auto length = expression.isArrayLengthExp)
            return lowerArrayLength(length, lowerer);

        if (auto array = expression.isArrayExp)
            return lowerArrayExpression(array, lowerer);

        if (auto index = expression.isIndexExp)
            return lowerArrayIndex(index, lowerer);

        if (auto dot = expression.isDotVarExp)
            return lowerStructFieldRead(dot, lowerer);

        if (auto dot = expression.isDotIdExp)
            return lowerDotIdentifierRead(dot, lowerer);

        if (auto literal = expression.isStructLiteralExp)
            return lowerStructLiteral(literal, lowerer);

        if (auto assert_ = expression.isAssertExp) {
            const condition = lowerExpression(assert_.e1, lowerer);
            instructions ~= Instruction(Assert_(condition));
            return condition;
        }

        if (auto declaration = expression.isDeclarationExp)
            return lowerDeclaration(declaration, lowerer);

        if (auto construct = expression.isConstructExp)
            return lowerAssignment(construct, lowerer);

        if (auto blit = expression.isBlitExp)
            return lowerBlitAssignment(blit, lowerer);

        if (auto assignment = expression.isLoweredAssignExp)
            return lowerAssignment(assignment, lowerer);

        if (auto assignment = expression.isAssignExp)
            return lowerAssignment(assignment, lowerer);

        if (auto orAssign = expression.isOrAssignExp)
            return lowerCompoundAssignment(
                orAssign,
                Operation.bitwiseOr,
                lowerer,
            );

        if (auto andAssign = expression.isAndAssignExp)
            return lowerCompoundAssignment(
                andAssign,
                Operation.bitwiseAnd,
                lowerer,
            );

        if (auto xorAssign = expression.isXorAssignExp)
            return lowerCompoundAssignment(
                xorAssign,
                Operation.bitwiseXor,
                lowerer,
            );

        if (auto addAssign = expression.isAddAssignExp)
            return lowerCompoundAssignment(
                addAssign,
                Operation.add,
                lowerer,
            );

        if (auto subtractAssign = expression.isMinAssignExp)
            return lowerCompoundAssignment(
                subtractAssign,
                Operation.subtract,
                lowerer,
            );

        if (auto multiplyAssign = expression.isMulAssignExp)
            return lowerCompoundAssignment(
                multiplyAssign,
                Operation.multiply,
                lowerer,
            );

        if (auto divideAssign = expression.isDivAssignExp)
            return lowerCompoundAssignment(
                divideAssign,
                Operation.divide,
                lowerer,
            );

        if (auto leftShiftAssign = expression.isShlAssignExp)
            return lowerCompoundAssignment(
                leftShiftAssign,
                Operation.leftShift,
                lowerer,
            );

        if (auto append = expression.isCatAssignExp)
            return lowerArrayAppendAssignment(append, lowerer);

        if (auto append = expression.isCatElemAssignExp)
            return lowerArrayAppendAssignment(append, lowerer);

        if (auto post = expression.isPostExp) {
            import dmd.tokens: EXP;

            if (post.op == EXP.plusPlus || post.op == EXP.minusMinus)
                return lowerPostIncrement(post, lowerer);
        }

        if (auto pre = expression.isPreExp)
            return lowerPreIncrement(pre);

        if (auto function_ = functionPointerExpressionFunction(expression))
            return lowerFunctionPointer(function_, lowerer);

        if (auto addr = expression.isAddrExp) {
            if (auto var = addr.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (auto target = varDecl in localTemporaries)
                        return *target;
            if (auto index = addr.e1.isIndexExp)
                if (!typeIsAssociativeArray(index.e1.type))
                    return lowerArrayElementPointer(index, lowerer);
            import std.conv: text;
            throw new Exception(text("Unsupported address-of: ", expressionChars(addr.e1)));
        }

        if (auto symbol = expression.isSymOffExp) {
            if (auto varDecl = symbol.var.isVarDeclaration)
                if (auto target = varDecl in localTemporaries)
                    return *target;
            import std.conv: text;
            throw new Exception(text("Unsupported symbol offset: ", expressionChars(symbol)));
        }

        // Pointer dereference: *ptr. Peel off the * — the temp that ptr
        // holds already IS the temp index of the pointed-to variable, so
        // reading/passing it is the same as reading/passing the inner expr.
        if (auto ptr = expression.isPtrExp)
            return lowerExpression(ptr.e1, lowerer);

        if (auto new_ = expression.isNewExp)
            return lowerNewExpression(new_, lowerer);

        if (auto this_ = expression.isThisExp) {
            auto temporary = this_.var in localTemporaries;
            if (temporary !is null)
                return *temporary;
            if (hasThisTemporary)
                return thisTemporary;
        }

        if (auto super_ = expression.isSuperExp) {
            auto temporary = super_.var in localTemporaries;
            if (temporary !is null)
                return *temporary;
            if (hasThisTemporary)
                return thisTemporary;
        }

        if (auto identifier = expression.isIdentifierExp) {
            const name = identifierName(identifier);
            if (auto temporary = name in identifierTemporaries)
                return *temporary;

            if (name == "roundingMask") {
                const destination = allocateTemporary;
                instructions ~= Instruction(ConstInt(destination, 0));
                return destination;
            }

            if (name == "__dollar" && dollarArrays.length != 0)
                return lowerDollar;

            if (isThisFieldName(name)) {
                const destination = allocateTemporary;
                instructions ~= Instruction(StructGet(
                    destination,
                    thisTemporary,
                    name,
                ));
                return destination;
            }

            const backingFieldName = "_" ~ name;
            if (isThisFieldName(backingFieldName)) {
                const destination = allocateTemporary;
                instructions ~= Instruction(StructGet(
                    destination,
                    thisTemporary,
                    backingFieldName,
                ));
                return destination;
            }

            import std.conv: text;

            throw new Exception(text(
                "Unsupported expression: ",
                expression.op,
                " ",
                expressionChars(expression),
                " at ",
                locationChars(expression.loc),
            ));
        }

        if (auto variable = expression.isVarExp) {
            if (auto var = variable.var.isVarDeclaration) {
                if (var.ident !is null && var.ident.toString == "__ctfe") {
                    // __ctfe is false at runtime.
                    const destination = allocateTemporary;
                    instructions ~= Instruction(ConstInt(destination, 0));
                    return destination;
                }
                if (auto temporary = var in localTemporaries)
                    return *temporary;
                if (auto temporary = declarationName(var) in identifierTemporaries)
                    return *temporary;
                if (varIsParameter(var))
                    return lowerUnmappedParameter(var);
                if (varIsStatic(var) && typeIsAssociativeArray(var.type)) {
                    const destination = allocateTemporary;
                    instructions ~= Instruction(StaticAssocArray(
                        destination,
                        staticVariableName(var),
                    ));
                    return destination;
                }
            }

            if (expressionChars(expression) == "$")
                return lowerDollar;

            import std.conv: text;

            if (auto var = variable.var.isVarDeclaration)
                throw new Exception(text(
                    "Unsupported expression: ",
                    expressionChars(expression),
                    " storage=",
                    var.storage_class,
                    " type=",
                    var.type is null ? "<null>" : typeChars(var.type),
                    " init=",
                    var._init is null ? "<null>" : initializerChars(var._init),
                ));

            throw new Exception(text("Unsupported expression: ", expressionChars(expression)));
        }

        import std.conv: text;

        throw new Exception(text(
            "Unsupported expression: ",
            expression.op,
            " ",
            expressionChars(expression),
            " at ",
            locationChars(expression.loc),
        ));
    }

    uint lowerBinaryExpression(Expression)(
        Expression expression,
        in imported!"quickbite.ir.instruction".Operation operation,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: BinaryOp, Instruction;

        const left = lowerExpression(expression.e1, lowerer);
        const right = lowerExpression(expression.e2, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            destination,
            left,
            right,
            operation,
        ));
        return destination;
    }

    uint lowerComparison(
        imported!"dmd.expression".CmpExp comparison,
        in imported!"quickbite.ir.instruction".Operation signedOperation,
        in imported!"quickbite.ir.instruction".Operation unsignedOperation,
        ref Lowerer lowerer,
    ) @safe {
        const operation = comparisonUsesUnsignedOperand(comparison)
            ? unsignedOperation
            : signedOperation;
        return lowerBinaryExpression(comparison, operation, lowerer);
    }

    uint lowerArraySlice(
        imported!"dmd.expression".SliceExp slice,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArraySlice, Instruction;
        import std.conv: text;

        if (slice.lwr is null && slice.upr is null)
            return lowerExpression(slice.e1, lowerer);

        if (slice.lwr !is null && slice.upr !is null) {
            const array = lowerExpression(slice.e1, lowerer);
            dollarArrays ~= array;
            const lower = lowerExpression(slice.lwr, lowerer);
            const upper = lowerExpression(slice.upr, lowerer);
            dollarArrays = dollarArrays[0 .. dollarArrays.length - 1];
            const destination = allocateTemporary;
            instructions ~= Instruction(ArraySlice(
                destination,
                array,
                lower,
                upper,
            ));
            return destination;
        }

        throw new Exception(text("Unsupported expression: ", slice.op));
    }

    uint lowerDollar() @safe {
        import quickbite.ir.instruction: ArrayLength, Instruction;

        if (dollarArrays.length == 0)
            throw new Exception("Unsupported expression: $");

        const destination = allocateTemporary;
        instructions ~= Instruction(ArrayLength(
            destination,
            dollarArrays[$ - 1],
        ));
        return destination;
    }

    uint lowerArrayEqualityCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayEqual, Instruction;

        if (call.arguments is null || call.arguments.length != 2)
            throw new Exception("Unsupported array equality.");

        const left = lowerExpression(callArguments(call)[0], lowerer);
        const right = lowerExpression(callArguments(call)[1], lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(ArrayEqual(
            destination,
            left,
            right,
        ));
        return destination;
    }

    uint lowerArrayEqualityExpression(
        imported!"dmd.expression".EqualExp equal,
        ref Lowerer lowerer,
    ) @safe {
        import dmd.tokens: EXP;
        import quickbite.ir.instruction:
            ArrayEqual, Instruction, UnaryOp, UnaryOperation;

        const left = lowerExpression(equal.e1, lowerer);
        const right = lowerExpression(equal.e2, lowerer);
        const equalResult = allocateTemporary;
        instructions ~= Instruction(ArrayEqual(
            equalResult,
            left,
            right,
        ));

        if (equal.op == EXP.equal)
            return equalResult;

        const destination = allocateTemporary;
        instructions ~= Instruction(UnaryOp(
            destination,
            equalResult,
            UnaryOperation.not,
        ));
        return destination;
    }

    uint lowerArrayLiteral(
        imported!"dmd.expression".ArrayLiteralExp literal,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayLiteral, Instruction;

        uint[] elements;
        if (literal.elements !is null)
            foreach (element; arrayLiteralElements(literal))
                elements ~= lowerExpression(element, lowerer);

        const destination = allocateTemporary;
        instructions ~= Instruction(ArrayLiteral(
            destination,
            elements,
        ));
        return destination;
    }

    uint lowerStringLiteral(imported!"dmd.expression".StringExp literal) @safe {
        import quickbite.ir.instruction: ArrayLiteral, ConstInt, Instruction;

        uint[] elements;
        foreach (index; 0 .. stringLiteralLength(literal)) {
            const element = allocateTemporary;
            instructions ~= Instruction(ConstInt(
                element,
                stringLiteralCodeUnit(literal, index),
            ));
            elements ~= element;
        }

        const destination = allocateTemporary;
        instructions ~= Instruction(ArrayLiteral(
            destination,
            elements,
        ));
        return destination;
    }

    uint lowerUnmappedParameter(
        imported!"dmd.declaration".VarDeclaration variable,
    ) @safe {
        if (typeIsDynamicArray(variable.type)) {
            import quickbite.ir.instruction: ArrayLiteral, Instruction;

            const destination = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(destination, []));
            return destination;
        }

        import quickbite.ir.instruction: ConstInt, Instruction;

        const destination = allocateTemporary;
        instructions ~= Instruction(ConstInt(destination, 0));
        return destination;
    }

    uint lowerFunctionPointer(
        imported!"dmd.func".FuncDeclaration function_,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction;

        lowerer.ensureFunctionLowered(function_);
        const destination = allocateTemporary;
        instructions ~= Instruction(ConstInt(
            destination,
            stableIdentifierValue(lowerer.functionName(function_)),
        ));
        return destination;
    }

    uint lowerAssocArrayLiteral(
        imported!"dmd.expression".AssocArrayLiteralExp literal,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArrayLiteral, Instruction;

        uint[] keys;
        uint[] values;
        foreach (index, keyExpression; assocArrayLiteralKeys(literal)) {
            keys ~= lowerExpression(keyExpression, lowerer);
            values ~= lowerExpression(
                assocArrayLiteralValues(literal)[index],
                lowerer,
            );
        }

        const destination = allocateTemporary;
        instructions ~= Instruction(AssocArrayLiteral(
            destination,
            keys,
            values,
        ));
        return destination;
    }

    bool tryLowerUnresolvedBuiltinCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        import quickbite.ir.instruction:
            ArrayLiteral, ArraySetLength, Assert_, BinaryOp, CastInt,
            ConstInt, Instruction, Operation, StructNew, StructSet, UnaryOp,
            UnaryOperation;

        const name = expressionChars(call.e1);

        {
            import std.string: endsWith, startsWith;

            if (name.endsWith(".assumeSafeAppend")) {
                enforceCallArgumentCount(call, 0);
                result = allocateTemporary;
                instructions ~= Instruction(ConstInt(result, 0));
                return true;
            }

            if (name.startsWith("ScopeBuffer!")) {
                enforceCallArgumentCount(call, 1);
                lowerExpression(callArguments(call)[0], lowerer);

                const array = allocateTemporary;
                instructions ~= Instruction(ArrayLiteral(array, []));

                result = allocateTemporary;
                instructions ~= Instruction(StructNew(result));
                instructions ~= Instruction(StructSet(result, "arr", array));
                return true;
            }
        }

        if (name == "getControlState") {
            enforceCallArgumentCount(call, 0);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (name == "isNaN" || name == "isInfinity" || name == "signbit") {
            enforceCallArgumentCount(call, 1);
            lowerExpression(callArguments(call)[0], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (name == "fabs" || name == "sqrt") {
            enforceCallArgumentCount(call, 1);
            result = lowerExpression(callArguments(call)[0], lowerer);
            return true;
        }

        if (name == "pow") {
            enforceCallArgumentCount(call, 2);
            result = lowerExpression(callArguments(call)[0], lowerer);
            lowerExpression(callArguments(call)[1], lowerer);
            return true;
        }

        if (name == "bsr") {
            enforceCallArgumentCount(call, 1);
            const value = lowerExpression(callArguments(call)[0], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(UnaryOp(
                result,
                value,
                UnaryOperation.bitScanReverse,
            ));
            return true;
        }

        if (name == "Split64") {
            enforceCallArgumentCount(call, 1);
            const value = lowerExpression(callArguments(call)[0], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(StructNew(result));

            const lo = allocateTemporary;
            instructions ~= Instruction(CastInt(
                lo,
                value,
                imported!"quickbite.ir.instruction".IntegerType.u32,
            ));
            instructions ~= Instruction(StructSet(result, "lo", lo));

            const shift = allocateTemporary;
            instructions ~= Instruction(ConstInt(shift, 32));
            const shifted = allocateTemporary;
            instructions ~= Instruction(BinaryOp(
                shifted,
                value,
                shift,
                Operation.rightShift,
            ));
            const hi = allocateTemporary;
            instructions ~= Instruction(CastInt(
                hi,
                shifted,
                imported!"quickbite.ir.instruction".IntegerType.u32,
            ));
            instructions ~= Instruction(StructSet(result, "hi", hi));
            return true;
        }

        if (name == "*& _d_newarrayU") {
            result = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(result, []));

            if (call.arguments is null || call.arguments.length == 0)
                return true;

            const length = lowerExpression(callArguments(call)[0], lowerer);
            instructions ~= Instruction(ArraySetLength(result, length));
            return true;
        }

        if (name != "enforceFmt")
            return false;

        enforceCallArgumentCount(call, 1);
        result = lowerTruthValue(lowerExpression(callArguments(call)[0], lowerer));
        instructions ~= Instruction(Assert_(result));
        return true;
    }

    bool tryLowerFunctionPointerTableCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        import quickbite.ir.instruction: BinaryOp, Call, ConstInt, Copy,
            Instruction, Jump, JumpIfFalse, Operation;

        auto pointer = call.e1.isPtrExp;
        if (pointer is null)
            return false;

        auto index = pointer.e1.isIndexExp;
        if (index is null)
            return false;

        auto table = index.e1.isVarExp;
        if (table is null)
            return false;

        auto variable = table.var.isVarDeclaration;
        if (variable is null)
            return false;

        // DMD lowering APIs need mutable function declarations.
        auto functions = functionPointerTableFunctions(variable);
        if (functions.length == 0)
            return false;

        const tableIndex = lowerExpression(index.e2, lowerer);
        // `auto` because the IR call owns a mutable arguments array.
        auto arguments = lowerCallArgumentsForFunction(
            call,
            functions[0],
            lowerer,
        );

        result = allocateTemporary;
        size_t[] endJumpIndices;
        foreach (functionIndex, function_; functions) {
            lowerer.ensureFunctionLowered(function_);

            const caseValue = allocateTemporary;
            instructions ~= Instruction(ConstInt(
                caseValue,
                cast(long) functionIndex,
            ));
            const matched = allocateTemporary;
            instructions ~= Instruction(BinaryOp(
                matched,
                tableIndex,
                caseValue,
                Operation.equal,
            ));

            const nextCaseJumpIndex = instructions.length;
            instructions ~= Instruction(JumpIfFalse(matched, 0));

            const callResult = allocateTemporary;
            instructions ~= Instruction(Call(
                callResult,
                lowerer.functionName(function_),
                arguments,
            ));
            instructions ~= Instruction(Copy(result, callResult));

            const endJumpIndex = instructions.length;
            instructions ~= Instruction(Jump(0));
            endJumpIndices ~= endJumpIndex;

            replaceJumpOffset(
                instructions,
                cast(uint) nextCaseJumpIndex,
                cast(int) (instructions.length - nextCaseJumpIndex - 1),
            );
        }

        foreach (jumpIndex; endJumpIndices)
            replaceJumpOffset(
                instructions,
                cast(uint) jumpIndex,
                cast(int) (instructions.length - jumpIndex),
            );

        return true;
    }

    bool tryLowerIndirectFunctionPointerCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        import quickbite.ir.instruction: IndirectCall, Instruction;

        auto pointer = call.e1.isPtrExp;
        if (pointer is null)
            return false;

        const callee = lowerExpression(pointer.e1, lowerer);
        // `auto` because the IR call owns a mutable arguments array.
        auto arguments = lowerIndirectCallArguments(call, lowerer);
        result = allocateTemporary;
        instructions ~= Instruction(IndirectCall(
            result,
            callee,
            arguments,
        ));
        return true;
    }

    bool tryLowerRuntimeBuiltinCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        import quickbite.ir.instruction:
            ArrayCopy, ArrayLength, ArrayLiteral, Assert_, BinaryOp, ConstInt,
            Instruction, Operation;

        if (functionIdentifier(call.f) == "_d_arraybounds") {
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            instructions ~= Instruction(Assert_(result));
            return true;
        }

        if (isCoreCheckedIntMuluCall(call, lowerer)) {
            enforceCallArgumentCount(call, 3);
            const left = lowerExpression(callArguments(call)[0], lowerer);
            const right = lowerExpression(callArguments(call)[1], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(BinaryOp(
                result,
                left,
                right,
                Operation.multiply,
            ));
            return true;
        }

        if (
            functionIdentifier(call.f) == "_bytesHashAligned" ||
            functionIdentifier(call.f) == "_bytesHashUnaligned"
        ) {
            enforceCallArgumentCount(call, 2);
            const bytes = lowerExpression(callArguments(call)[0], lowerer);
            const seed = lowerExpression(callArguments(call)[1], lowerer);
            const length = allocateTemporary;
            instructions ~= Instruction(ArrayLength(length, bytes));
            result = allocateTemporary;
            instructions ~= Instruction(BinaryOp(
                result,
                seed,
                length,
                Operation.add,
            ));
            return true;
        }

        if (functionIdentifier(call.f) == "memcpy" ||
            functionIdentifier(call.f) == "memset")
        {
            enforceCallArgumentCount(call, 3);
            result = lowerExpression(callArguments(call)[0], lowerer);
            lowerExpression(callArguments(call)[1], lowerer);
            lowerExpression(callArguments(call)[2], lowerer);
            return true;
        }

        if (functionIdentifier(call.f) == "realloc") {
            enforceCallArgumentCount(call, 2);
            lowerExpression(callArguments(call)[0], lowerer);
            lowerExpression(callArguments(call)[1], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (functionIdentifier(call.f) == "fabs") {
            enforceCallArgumentCount(call, 1);
            result = lowerExpression(callArguments(call)[0], lowerer);
            return true;
        }

        if (functionIdentifier(call.f) == "pow") {
            enforceCallArgumentCount(call, 2);
            result = lowerExpression(callArguments(call)[0], lowerer);
            lowerExpression(callArguments(call)[1], lowerer);
            return true;
        }

        if (lowerer.functionName(call.f) == "gc_qalloc") {
            if (call.arguments !is null)
                foreach (argument; callArguments(call))
                    lowerExpression(argument, lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 1));
            return true;
        }

        if (functionIdentifier(call.f) == "getControlState") {
            enforceCallArgumentCount(call, 0);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (functionIdentifier(call.f) == "setControlState") {
            enforceCallArgumentCount(call, 1);
            lowerExpression(callArguments(call)[0], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (functionIdentifier(call.f) == "getIeeeFlags") {
            enforceCallArgumentCount(call, 0);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (functionIdentifier(call.f) == "resetIeeeFlags") {
            enforceCallArgumentCount(call, 0);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (functionIdentifier(call.f) == "isGraphical") {
            enforceCallArgumentCount(call, 1);
            lowerExpression(callArguments(call)[0], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 1));
            return true;
        }

        if (functionIdentifier(call.f) == "text") {
            result = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(result, []));
            return true;
        }

        if (functionIdentifier(call.f) == "shouldThrow") {
            result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return true;
        }

        if (
            (functionIdentifier(call.f) == "dup" ||
                functionIdentifier(call.f) == "idup") &&
            typeIsDynamicArray(call.type)
        ) {
            enforceCallArgumentCount(call, 1);
            const source = lowerExpression(callArguments(call)[0], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(ArrayCopy(result, source));
            return true;
        }

        if (lowerer.functionName(call.f) == "gc_extend") {
            enforceCallArgumentCount(call, 3);
            const minimum = lowerExpression(callArguments(call)[1], lowerer);
            const desired = lowerExpression(callArguments(call)[2], lowerer);
            result = allocateTemporary;
            instructions ~= Instruction(BinaryOp(
                result,
                minimum,
                desired,
                Operation.add,
            ));
            return true;
        }

        return false;
    }

    bool tryLowerAssocArrayBuiltinCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        const name = functionIdentifier(call.f);
        if (name == "_d_aaLen") {
            result = lowerAssocArrayLengthCall(call, lowerer);
            return true;
        }

        if (name == "_aaDup") {
            result = lowerAssocArrayDupCall(call, lowerer);
            return true;
        }

        if (name == "_d_aaGetRvalueX") {
            result = lowerAssocArrayIndexCall(call, lowerer);
            return true;
        }

        if (name == "_d_aaIn") {
            result = lowerAssocArrayIndexCall(call, lowerer);
            return true;
        }

        if (name == "_d_aaGetY") {
            result = lowerAssocArrayValuePointerCall(call, lowerer);
            return true;
        }

        if (name == "_aaGetX") {
            result = lowerAssocArrayGetXCall(call, lowerer);
            return true;
        }

        if (name == "keys" && typeIsDynamicArray(call.type)) {
            result = lowerAssocArrayKeysCall(call, lowerer);
            return true;
        }

        if (name == "values" && typeIsDynamicArray(call.type)) {
            result = lowerAssocArrayValuesCall(call, lowerer);
            return true;
        }

        return false;
    }

    uint lowerAssocArrayLengthCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArrayLength, Instruction;

        enforceCallArgumentCount(call, 1);
        const array = lowerExpression(callArguments(call)[0], lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(AssocArrayLength(
            destination,
            array,
        ));
        return destination;
    }

    uint lowerAssocArrayDupCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        enforceCallArgumentCount(call, 1);
        return lowerExpression(callArguments(call)[0], lowerer);
    }

    uint lowerAssocArrayIndexCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArrayIndex, Instruction;

        enforceCallArgumentCount(call, 2);
        const array = lowerExpression(callArguments(call)[0], lowerer);
        const key = lowerExpression(callArguments(call)[1], lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(AssocArrayIndex(
            destination,
            array,
            key,
        ));
        return destination;
    }

    uint lowerAssocArrayValuePointerCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArrayValuePointer, Instruction;

        enforceCallArgumentCount(call, 2);
        const array = lowerExpression(callArguments(call)[0], lowerer);
        const key = lowerExpression(callArguments(call)[1], lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(AssocArrayValuePointer(
            destination,
            array,
            key,
        ));
        return destination;
    }

    uint lowerAssocArrayGetXCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArrayValuePointer, Instruction;

        enforceCallArgumentCount(call, 4);
        const array = lowerExpression(callArguments(call)[0], lowerer);
        const key = lowerExpression(callArguments(call)[1], lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(AssocArrayValuePointer(
            destination,
            array,
            key,
        ));
        return destination;
    }

    uint lowerAssocArrayKeysCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArrayKeys, Instruction;

        const array = call.arguments !is null && callArguments(call).length >= 1
            ? lowerExpression(callArguments(call)[0], lowerer)
            : lowerCallReceiver(call, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(AssocArrayKeys(
            destination,
            array,
        ));
        return destination;
    }

    uint lowerAssocArrayValuesCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArrayValues, Instruction;

        const array = call.arguments !is null && callArguments(call).length >= 1
            ? lowerExpression(callArguments(call)[0], lowerer)
            : lowerCallReceiver(call, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(AssocArrayValues(
            destination,
            array,
        ));
        return destination;
    }

    bool tryLowerAppenderBuiltinCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        if (!callHasAppenderReceiver(call))
            return false;

        const name = functionIdentifier(call.f);
        if (name == "put" && call.arguments !is null) {
            result = lowerAppenderPutCall(call, lowerer);
            return true;
        }

        if (name == "data" || name == "opSlice") {
            result = lowerAppenderArrayCall(call, lowerer);
            return true;
        }

        return false;
    }

    uint lowerAppenderPutCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayAppend, ArrayAppendArray,
            Instruction;

        enforceCallArgumentCount(call, 1);
        const array = lowerAppenderArray(call, lowerer);
        // DMD expression helpers return mutable AST nodes.
        auto argument = callArguments(call)[0];
        const value = lowerExpression(argument, lowerer);
        if (expressionAppendsArray(argument)) {
            instructions ~= Instruction(ArrayAppendArray(
                array,
                value,
            ));
            return array;
        }

        instructions ~= Instruction(ArrayAppend(
            array,
            value,
        ));
        return array;
    }

    uint lowerAppenderArrayCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        return lowerAppenderArray(call, lowerer);
    }

    bool tryLowerDynamicArrayRangeCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        if (!callHasDynamicArrayRangeReceiver(call))
            return false;

        if (functionIdentifier(call.f) == "clear") {
            result = lowerDynamicArrayRangeClearCall(call, lowerer);
            return true;
        }

        return false;
    }

    uint lowerDynamicArrayRangeClearCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArraySetLength, ConstInt, Instruction,
            StructGet;

        enforceCallArgumentCount(call, 0);
        const receiver = lowerCallReceiver(call, lowerer);
        const array = allocateTemporary;
        instructions ~= Instruction(StructGet(array, receiver, "_bytes"));
        const zero = allocateTemporary;
        instructions ~= Instruction(ConstInt(zero, 0));
        instructions ~= Instruction(ArraySetLength(array, zero));
        return array;
    }

    bool tryLowerScopeBufferRangeConstructor(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        import quickbite.ir.instruction: ArrayLiteral, Instruction, StructNew,
            StructSet;

        if (functionIdentifier(call.f) != "__ctor")
            return false;

        // auto: DMD Type helpers below require the mutable frontend object.
        auto thisType = functionThisStructType(call.f);
        if (thisType is null || typeChars(thisType) != "ScopeBufferRange")
            return false;

        enforceCallArgumentCount(call, 1);
        lowerExpression(callArguments(call)[0], lowerer);

        const array = allocateTemporary;
        instructions ~= Instruction(ArrayLiteral(array, []));

        const scopeBuffer = allocateTemporary;
        instructions ~= Instruction(StructNew(scopeBuffer));
        instructions ~= Instruction(StructSet(scopeBuffer, "arr", array));

        result = allocateTemporary;
        instructions ~= Instruction(StructNew(result));
        lowerDefaultStructFields(result, thisType);
        instructions ~= Instruction(StructSet(result, "sbuf", scopeBuffer));
        return true;
    }

    bool tryLowerCerealiserImplConstructor(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructNew, StructSet;
        import std.string: startsWith;

        if (functionIdentifier(call.f) != "__ctor")
            return false;

        // auto: DMD Type helpers below require the mutable frontend object.
        auto thisType = functionThisStructType(call.f);
        if (thisType is null)
            thisType = call.type;
        if (thisType is null || !typeChars(thisType).startsWith("CerealiserImpl!("))
            return false;
        if (call.arguments is null || callArguments(call).length != 1)
            return false;

        const output = lowerExpression(callArguments(call)[0], lowerer);

        result = allocateTemporary;
        instructions ~= Instruction(StructNew(result));
        lowerDefaultStructFields(result, thisType);
        instructions ~= Instruction(StructSet(result, "_output", output));
        return true;
    }

    bool tryLowerScopeBufferCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
        ref uint result,
    ) @safe {
        if (!callHasScopeBufferReceiver(call))
            return false;

        const name = functionIdentifier(call.f);
        if (name == "put") {
            result = lowerScopeBufferPutCall(call, lowerer);
            return true;
        }

        if (name == "opSlice") {
            result = lowerScopeBufferSliceCall(call, lowerer);
            return true;
        }

        if (name == "data") {
            result = lowerScopeBufferSliceCall(call, lowerer);
            return true;
        }

        if (name == "length") {
            result = lowerScopeBufferLengthCall(call, lowerer);
            return true;
        }

        if (name == "free") {
            result = lowerScopeBufferFreeCall(call, lowerer);
            return true;
        }

        return false;
    }

    uint lowerScopeBufferPutCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayAppend, ArrayAppendArray,
            Instruction;

        enforceCallArgumentCount(call, 1);
        const array = lowerScopeBufferArray(call, lowerer);
        // DMD expression helpers return mutable AST nodes.
        auto argument = callArguments(call)[0];
        const value = lowerExpression(argument, lowerer);
        if (scopeBufferPutAppendsArray(call, argument)) {
            instructions ~= Instruction(ArrayAppendArray(array, value));
            return array;
        }

        instructions ~= Instruction(ArrayAppend(array, value));
        return array;
    }

    bool scopeBufferPutAppendsArray(
        imported!"dmd.expression".CallExp call,
        imported!"dmd.expression".Expression argument,
    ) @safe {
        if (expressionAppendsArray(argument))
            return true;

        if (call.f.parameters is null) {
            // auto: DMD Type helpers below require mutable frontend types.
            auto parameters = functionTypeParameters(call.f);
            if (parameters.length == 0)
                return false;

            return typeIsDynamicArray(parameters[0].type);
        }

        auto parameters = functionParameterSlice(call.f);
        if (parameters.length == 0)
            return false;

        return typeIsDynamicArray(parameters[0].type);
    }

    uint lowerScopeBufferSliceCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArraySlice, Instruction;

        const array = lowerScopeBufferArray(call, lowerer);
        if (call.arguments is null || callArguments(call).length == 0)
            return array;

        enforceCallArgumentCount(call, 2);
        const lower = lowerExpression(callArguments(call)[0], lowerer);
        const upper = lowerExpression(callArguments(call)[1], lowerer);
        const result = allocateTemporary;
        instructions ~= Instruction(ArraySlice(result, array, lower, upper));
        return result;
    }

    uint lowerScopeBufferLengthCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayLength, ArraySetLength,
            Instruction;

        const array = lowerScopeBufferArray(call, lowerer);
        if (call.arguments is null || callArguments(call).length == 0) {
            const result = allocateTemporary;
            instructions ~= Instruction(ArrayLength(result, array));
            return result;
        }

        enforceCallArgumentCount(call, 1);
        const length = lowerExpression(callArguments(call)[0], lowerer);
        instructions ~= Instruction(ArraySetLength(array, length));
        return array;
    }

    uint lowerScopeBufferFreeCall(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction;

        enforceCallArgumentCount(call, 0);
        lowerScopeBufferArray(call, lowerer);
        const result = allocateTemporary;
        instructions ~= Instruction(ConstInt(result, 0));
        return result;
    }

    uint lowerScopeBufferArray(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructGet;

        const scopeBuffer = lowerScopeBufferReceiver(call, lowerer);
        const array = allocateTemporary;
        instructions ~= Instruction(StructGet(array, scopeBuffer, "arr"));
        return array;
    }

    uint lowerScopeBufferReceiver(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructGet;

        const receiver = lowerCallReceiver(call, lowerer);
        if (callHasScopeBufferRangeReceiver(call)) {
            const scopeBuffer = allocateTemporary;
            instructions ~= Instruction(StructGet(scopeBuffer, receiver, "sbuf"));
            return scopeBuffer;
        }

        return receiver;
    }

    uint lowerAppenderArray(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructGet;

        const appender = lowerCallReceiver(call, lowerer);
        const data = allocateTemporary;
        instructions ~= Instruction(StructGet(
            data,
            appender,
            "_data",
        ));
        const array = allocateTemporary;
        instructions ~= Instruction(StructGet(
            array,
            data,
            "arr",
        ));
        return array;
    }

    uint lowerNewExpression(
        imported!"dmd.expression".NewExp new_,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayLiteral, Call, ConstInt,
            Instruction, StructNew, StructSet;
        import std.conv: text;

        if (typeIsClass(new_.newtype)) {
            const destination = allocateTemporary;
            instructions ~= Instruction(StructNew(destination));
            lowerDefaultStructFields(destination, new_.newtype);
            const className = allocateTemporary;
            instructions ~= Instruction(ConstInt(
                className,
                classInfoNameValue(new_.newtype),
            ));
            instructions ~= Instruction(StructSet(
                destination,
                "__classinfo_name",
                className,
            ));
            if (new_.member !is null) {
                lowerer.ensureFunctionLowered(new_.member);
                // `auto` because the IR call owns a mutable arguments array.
                auto arguments = lowerNewClassConstructorArguments(
                    destination,
                    new_,
                    lowerer,
                );
                const ignored = allocateTemporary;
                instructions ~= Instruction(Call(
                    ignored,
                    lowerer.functionName(new_.member),
                    arguments,
                ));
            }
            return destination;
        }

        if (!typeIsPointer(new_.type) || !typeIsStruct(new_.newtype))
            throw new Exception(text("Unsupported expression: ", new_.op));

        const destination = allocateTemporary;
        instructions ~= Instruction(StructNew(destination));
        lowerDefaultStructFields(destination, new_.newtype);

        imported!"dmd.expression".Expression[] arguments;
        if (new_.arguments !is null)
            arguments = newArguments(new_);
        foreach (index, field; structFields(new_.newtype)) {
            uint value;
            if (index < arguments.length)
                value = lowerNewStructArgument(field.type, arguments[index], lowerer);
            else if (typeIsDynamicArray(field.type)) {
                value = allocateTemporary;
                instructions ~= Instruction(ArrayLiteral(value, []));
            } else
                continue;

            instructions ~= Instruction(StructSet(
                destination,
                declarationName(field),
                value,
            ));
        }

        return destination;
    }

    uint lowerStructLiteral(
        imported!"dmd.expression".StructLiteralExp literal,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructNew, StructSet;

        const destination = allocateTemporary;
        instructions ~= Instruction(StructNew(destination));
        lowerDefaultStructFields(destination, literal.type);

        if (literal.elements is null)
            return destination;

        foreach (index, element; structLiteralElements(literal)) {
            if (element is null)
                continue;

            auto field = structLiteralField(literal, index);
            if (field is null)
                continue;
            if (
                typeIsAppender(literal.type) &&
                typePointsToStruct(field.type) &&
                element.isNullExp !is null
            )
                continue;

            const value = lowerExpression(element, lowerer);
            instructions ~= Instruction(StructSet(
                destination,
                declarationName(field),
                value,
            ));
        }

        return destination;
    }

    void lowerDefaultStructFields(
        in uint struct_,
        imported!"dmd.mtype".Type type,
    ) @safe {
        if (typeIsClass(type)) {
            foreach (field; classFields(type))
                lowerDefaultStructField(struct_, type, field);
            return;
        }

        foreach (field; structFields(type))
            lowerDefaultStructField(struct_, type, field);
    }

    void lowerDefaultStructField(
        in uint struct_,
        imported!"dmd.mtype".Type aggregateType,
        imported!"dmd.declaration".VarDeclaration field,
    ) @safe {
        import quickbite.ir.instruction: ArrayLiteral, Instruction, StructNew,
            StructSet;

        uint value;
        if (typeIsDynamicArray(field.type)) {
            value = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(value, []));
        } else if (typeIsStruct(field.type)) {
            value = allocateTemporary;
            instructions ~= Instruction(StructNew(value));
            lowerDefaultStructFields(value, field.type);
        } else if (typeIsAppender(aggregateType) && typePointsToStruct(field.type)) {
            value = allocateTemporary;
            instructions ~= Instruction(StructNew(value));
            lowerDefaultStructFields(value, pointerTarget(field.type));
        } else
            return;

        instructions ~= Instruction(StructSet(
            struct_,
            declarationName(field),
            value,
        ));
    }

    uint lowerNewStructArgument(
        imported!"dmd.mtype".Type fieldType,
        imported!"dmd.expression".Expression argument,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayLiteral, Instruction;

        if (typeIsDynamicArray(fieldType) && argument.isNullExp) {
            const value = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(value, []));
            return value;
        }

        return lowerExpression(argument, lowerer);
    }

    uint[] lowerNewClassConstructorArguments(
        in uint destination,
        imported!"dmd.expression".NewExp new_,
        ref Lowerer lowerer,
    ) @safe {
        uint[] arguments;
        if (functionHasReceiver(new_.member))
            arguments ~= destination;

        if (new_.arguments is null)
            return arguments;

        // Pulled in parallel so non-ref struct constructor parameters get a
        // value copy at the call site, matching direct calls.
        auto parameters = new_.member.parameters !is null
            ? functionParameterSlice(new_.member)
            : null;
        foreach (i, argument; newArguments(new_)) {
            VarDeclaration parameter;
            if (i < parameters.length)
                parameter = parameters[i];

            const source = lowerCallArgument(argument, parameter, lowerer);
            if (i < parameters.length
                && !parameterIsRef(parameters[i])
                && typeIsStruct(argument.type))
            {
                arguments ~= copyStructByValue(argument.type, source);
                continue;
            }
            arguments ~= source;
        }

        return arguments;
    }

    uint lowerLogicalAnd(
        imported!"dmd.expression".LogicalExp expression,
        ref Lowerer lowerer,
    ) @safe {
        const left = lowerTruthValue(lowerExpression(expression.e1, lowerer));
        return lowerShortCircuit(
            expression,
            left,
            left,
            lowerer,
        );
    }

    uint lowerLogicalOr(
        imported!"dmd.expression".LogicalExp expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Copy, Instruction, JumpIfTrue;

        const left = lowerTruthValue(lowerExpression(expression.e1, lowerer));
        const destination = allocateTemporary;
        instructions ~= Instruction(Copy(
            destination,
            left,
        ));

        const jumpIndex = instructions.length;
        instructions ~= Instruction(JumpIfTrue(left, 0));

        const right = lowerTruthValue(lowerExpression(expression.e2, lowerer));
        instructions ~= Instruction(Copy(
            destination,
            right,
        ));
        replaceJumpOffset(
            instructions,
            cast(uint) jumpIndex,
            cast(int) (instructions.length - jumpIndex - 1),
        );
        return destination;
    }

    uint lowerConditionalExpression(
        imported!"dmd.expression".CondExp expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Copy, Instruction, Jump, JumpIfFalse;

        const condition = lowerTruthValue(lowerExpression(expression.econd, lowerer));
        const destination = allocateTemporary;
        const ifFalseJumpIndex = instructions.length;
        instructions ~= Instruction(JumpIfFalse(condition, 0));

        const ifTrue = typeIsPointer(expression.type)
            ? lowerPointerExpression(expression.e1, lowerer)
            : lowerExpression(expression.e1, lowerer);
        instructions ~= Instruction(Copy(destination, ifTrue));
        const skipFalseJumpIndex = instructions.length;
        instructions ~= Instruction(Jump(0));

        replaceJumpOffset(
            instructions,
            cast(uint) ifFalseJumpIndex,
            cast(int) (instructions.length - ifFalseJumpIndex - 1),
        );

        const ifFalse = typeIsPointer(expression.type)
            ? lowerPointerExpression(expression.e2, lowerer)
            : lowerExpression(expression.e2, lowerer);
        instructions ~= Instruction(Copy(destination, ifFalse));
        replaceJumpOffset(
            instructions,
            cast(uint) skipFalseJumpIndex,
            cast(int) (instructions.length - skipFalseJumpIndex),
        );
        return destination;
    }

    uint lowerPointerExpression(
        imported!"dmd.expression".Expression expression,
        ref Lowerer lowerer,
    ) @safe {
        if (auto index = expression.isIndexExp)
            if (typeIsAssociativeArray(index.e1.type)) {
                import quickbite.ir.instruction: AssocArrayValuePointer,
                    Instruction;

                const array = lowerExpression(index.e1, lowerer);
                const key = lowerExpression(index.e2, lowerer);
                const destination = allocateTemporary;
                instructions ~= Instruction(AssocArrayValuePointer(
                    destination,
                    array,
                    key,
                ));
                return destination;
            }

        return lowerExpression(expression, lowerer);
    }

    uint lowerArrayElementPointer(
        imported!"dmd.expression".IndexExp index,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayElementPointer, Instruction;

        const array = lowerExpression(index.e1, lowerer);
        dollarArrays ~= array;
        const indexValue = lowerExpression(index.e2, lowerer);
        dollarArrays = dollarArrays[0 .. dollarArrays.length - 1];
        const destination = allocateTemporary;
        instructions ~= Instruction(ArrayElementPointer(
            destination,
            array,
            indexValue,
        ));
        return destination;
    }

    uint lowerArrayConcatenation(
        imported!"dmd.expression".CatExp expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayConcat, ArrayLiteral, Instruction;

        const left = lowerExpression(expression.e1, lowerer);
        const right = lowerExpression(expression.e2, lowerer);
        const destination = allocateTemporary;
        uint leftArray;
        if (expressionAppendsArray(expression.e1))
            leftArray = left;
        else {
            leftArray = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(leftArray, [left]));
        }
        uint rightArray;
        if (expressionAppendsArray(expression.e2))
            rightArray = right;
        else {
            rightArray = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(rightArray, [right]));
        }
        instructions ~= Instruction(ArrayConcat(
            destination,
            leftArray,
            rightArray,
        ));
        return destination;
    }

    uint lowerImmediateFunctionLiteralCall(
        imported!"dmd.func".FuncDeclaration function_,
        ref Lowerer lowerer,
    ) @safe {
        return lowerImmediateFunctionLiteralCall(function_, null, lowerer);
    }

    uint lowerImmediateFunctionLiteralCall(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction;
        import std.conv: text;

        // auto: associative array snapshots must be restored after inlining.
        auto savedLocalTemporaries = localTemporaries.dup;
        // auto: associative array snapshots must be restored after inlining.
        auto savedIdentifierTemporaries = identifierTemporaries.dup;
        // auto: associative array snapshots must be restored after inlining.
        auto savedArrayValueNames = arrayValueNames.dup;
        withImmediateFunctionLiteralParameters(function_, call, lowerer);

        // DMD expression lowering APIs expect mutable AST node pointers.
        auto expression = immediateFunctionLiteralReturnExpression(function_.fbody);
        if (expression is null) {
            lowerStatement(function_.fbody, lowerer);
            const result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            localTemporaries = savedLocalTemporaries;
            identifierTemporaries = savedIdentifierTemporaries;
            arrayValueNames = savedArrayValueNames;
            return result;
        }

        const result = lowerExpression(expression, lowerer);
        localTemporaries = savedLocalTemporaries;
        identifierTemporaries = savedIdentifierTemporaries;
        arrayValueNames = savedArrayValueNames;
        return result;
    }

    void withImmediateFunctionLiteralParameters(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        if (call is null || call.arguments is null)
            return;

        if (function_.parameters is null) {
            bindImmediateFunctionLiteralTypeParameters(function_, call, lowerer);
            return;
        }

        bindImmediateFunctionLiteralParameters(function_, call, lowerer);
    }

    void bindImmediateFunctionLiteralParameters(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        if (function_.parameters is null) {
            import std.conv: text;

            throw new Exception(text(
                "Unsupported function literal parameters: ",
                functionIdentifier(function_),
            ));
        }

        auto parameters = functionParameterSlice(function_);
        if (parameters.length != callArguments(call).length) {
            import std.conv: text;

            throw new Exception(text(
                "Unsupported function literal argument count: ",
                functionIdentifier(function_),
            ));
        }

        foreach (i, parameter; parameters) {
            const temporary = lowerCallArgument(
                callArguments(call)[i],
                parameter,
                lowerer,
            );
            localTemporaries[parameter] = temporary;
            const name = declarationName(parameter);
            identifierTemporaries[name] = temporary;
            if (typeIsDynamicArray(parameter.type))
                arrayValueNames[name] = true;
        }
    }

    void bindImmediateFunctionLiteralTypeParameters(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        auto parameters = functionTypeParameters(function_);
        if (parameters.length != callArguments(call).length) {
            import std.conv: text;

            throw new Exception(text(
                "Unsupported function literal argument count: ",
                functionIdentifier(function_),
            ));
        }

        foreach (i, parameter; parameters) {
            if (typeParameterHasUnsupportedStorage(parameter)) {
                import std.conv: text;

                throw new Exception(text(
                    "Unsupported function literal parameter: ",
                    functionIdentifier(function_),
                    ".",
                    parameterName(parameter),
                    " storage=",
                    parameter.storageClass,
                ));
            }

            const temporary = lowerExpression(callArguments(call)[i], lowerer);
            const name = parameterName(parameter);
            identifierTemporaries[name] = temporary;
            if (typeIsDynamicArray(parameter.type))
                arrayValueNames[name] = true;
        }
    }

    uint lowerTupleExpression(
        imported!"dmd.expression".TupleExp tuple,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction;

        if (tuple.e0 !is null)
            lowerExpression(tuple.e0, lowerer);

        if (tupleExpressions(tuple).length == 0) {
            const result = allocateTemporary;
            instructions ~= Instruction(ConstInt(result, 0));
            return result;
        }

        uint result;
        foreach (element; tupleExpressions(tuple))
            result = lowerExpression(element, lowerer);
        return result;
    }

    uint lowerShortCircuit(
        imported!"dmd.expression".LogicalExp expression,
        in uint left,
        in uint jumpCondition,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Copy, Instruction, JumpIfFalse;

        const destination = allocateTemporary;
        instructions ~= Instruction(Copy(
            destination,
            left,
        ));

        const jumpIndex = instructions.length;
        instructions ~= Instruction(JumpIfFalse(jumpCondition, 0));

        const right = lowerTruthValue(lowerExpression(expression.e2, lowerer));
        instructions ~= Instruction(Copy(
            destination,
            right,
        ));
        replaceJumpOffset(
            instructions,
            cast(uint) jumpIndex,
            cast(int) (instructions.length - jumpIndex - 1),
        );
        return destination;
    }

    uint lowerTruthValue(in uint source) @safe {
        import quickbite.ir.instruction: Instruction, UnaryOp, UnaryOperation;

        const inverted = allocateTemporary;
        instructions ~= Instruction(UnaryOp(
            inverted,
            source,
            UnaryOperation.not,
        ));

        const destination = allocateTemporary;
        instructions ~= Instruction(UnaryOp(
            destination,
            inverted,
            UnaryOperation.not,
        ));
        return destination;
    }

    uint lowerDeclaration(
        imported!"dmd.expression".DeclarationExp declaration,
        ref Lowerer lowerer,
    ) @safe {
        import std.conv: text;

        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null) {
            import quickbite.ir.instruction: ConstInt, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(ConstInt(value, 0));
            return value;
        }

        if (typeIsStruct(variable.type) && variable._init !is null) {
            if (auto initializer = variable._init.isExpInitializer) {
                import quickbite.ir.instruction: Copy, Instruction, StructNew;

                const destination = allocateTemporary;
                instructions ~= Instruction(StructNew(destination));
                rememberLocalTemporary(variable, destination);
                lowerDefaultStructFields(destination, variable.type);

                if (isDefaultStructInitializer(initializer.exp))
                    return destination;

                const source = lowerInitializerExpression(initializer.exp, lowerer);
                if (source != destination)
                    instructions ~= Instruction(Copy(destination, source));

                return destination;
            }
        }

        if (variable._init !is null) {
            if (auto initializer = variable._init.isExpInitializer) {
                if (parameterIsRef(variable)) {
                    if (auto index = arrayElementAliasIndex(initializer.exp)) {
                        import quickbite.ir.instruction: ArrayIndex, Instruction;

                        const array = lowerExpression(index.e1, lowerer);
                        const indexValue = lowerExpression(index.e2, lowerer);
                        const value = allocateTemporary;
                        instructions ~= Instruction(ArrayIndex(
                            value,
                            array,
                            indexValue,
                        ));
                        rememberLocalTemporary(variable, value);
                        arrayElementAliases[variable] = ArrayElementAlias(
                            array,
                            indexValue,
                            value,
                        );
                        return value;
                    }
                }

                if (auto blit = initializer.exp.isBlitExp) {
                    if (
                        typeIsDynamicArray(variable.type) &&
                        blit.e2.isNullExp !is null
                    ) {
                        import quickbite.ir.instruction: ArrayLiteral, Instruction;
                        const value = allocateTemporary;
                        instructions ~= Instruction(ArrayLiteral(value, []));
                        rememberLocalTemporary(variable, value);
                        return value;
                    }
                    const value = lowerExpression(blit.e2, lowerer);
                    rememberLocalTemporary(variable, value);
                    return value;
                }

                const value = lowerInitializerExpression(initializer.exp, lowerer);
                rememberLocalTemporary(variable, value);
                return value;
            }
        }

        if (typeIsStruct(variable.type)) {
            import quickbite.ir.instruction: Instruction, StructNew;

            const value = allocateTemporary;
            instructions ~= Instruction(StructNew(value));
            rememberLocalTemporary(variable, value);
            lowerDefaultStructFields(value, variable.type);
            return value;
        }

        if (typeIsDynamicArray(variable.type)) {
            import quickbite.ir.instruction: ArrayLiteral, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(value, []));
            rememberLocalTemporary(variable, value);
            return value;
        }

        if (typeIsAssociativeArray(variable.type)) {
            import quickbite.ir.instruction: AssocArrayLiteral, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(AssocArrayLiteral(value, [], []));
            rememberLocalTemporary(variable, value);
            return value;
        }

        import quickbite.ir.instruction: ConstInt, Instruction;

        const value = allocateTemporary;
        instructions ~= Instruction(ConstInt(value, 0));
        rememberLocalTemporary(variable, value);
        return value;
    }

    imported!"dmd.expression".IndexExp arrayElementAliasIndex(
        imported!"dmd.expression".Expression expression,
    ) @safe {
        if (auto construct = expression.isConstructExp)
            return arrayElementAliasIndex(construct.e2);

        return expression.isIndexExp;
    }

    uint lowerInitializerExpression(
        imported!"dmd.expression".Expression expression,
        ref Lowerer lowerer,
    ) @safe {
        auto construct = expression.isConstructExp;
        return construct !is null
            ? lowerExpression(construct.e2, lowerer)
            : lowerExpression(expression, lowerer);
    }

    bool isDefaultStructInitializer(
        imported!"dmd.expression".Expression expression,
    ) @safe {
        if (auto blit = expression.isBlitExp)
            return isZeroInitializer(blit.e2);

        return isZeroInitializer(expression);
    }

    bool isZeroInitializer(
        imported!"dmd.expression".Expression expression,
    ) @safe {
        if (auto integer = expression.isIntegerExp)
            return integerValue(integer) == 0;

        return false;
    }

    uint lowerAssignment(
        imported!"dmd.expression".AssignExp assignment,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Copy, Instruction, StructSet;
        import std.conv: text;

        auto target = assignment.e1;
        while (true) {
            if (auto cast_ = target.isCastExp) {
                target = cast_.e1;
                continue;
            }

            if (auto comma = target.isCommaExp) {
                lowerExpression(comma.e1, lowerer);
                target = comma.e2;
                continue;
            }

            if (auto pointer = target.isPtrExp) {
                if (auto call = pointer.e1.isCallExp)
                    if (isAssocArrayGetCall(call))
                        return lowerAssocArrayIndexAssignment(
                            call,
                            assignment.e2,
                            lowerer,
                        );

                target = pointer.e1;
                continue;
            }

            if (auto address = target.isAddrExp) {
                target = address.e1;
                continue;
            }

            break;
        }

        if (auto slice = target.isSliceExp)
            return lowerArraySliceAssignment(slice, assignment.e2, lowerer);

        if (auto index = target.isIndexExp)
            return lowerArrayIndexAssignment(index, assignment.e2, lowerer);

        if (auto dot = target.isDotVarExp)
            return lowerStructFieldAssignment(dot, assignment.e2, lowerer);

        if (auto length = target.isArrayLengthExp)
            return lowerArrayLengthAssignment(length, assignment.e2, lowerer);

        if (auto identifier = target.isIdentifierExp) {
            const name = identifierName(identifier);
            if (auto destination = name in identifierTemporaries) {
                const source = lowerExpression(assignment.e2, lowerer);
                instructions ~= Instruction(Copy(
                    *destination,
                    source,
                ));
                return *destination;
            } else if (isThisFieldName(name)) {
                const source = lowerExpression(assignment.e2, lowerer);
                instructions ~= Instruction(StructSet(
                    thisTemporary,
                    name,
                    source,
                ));
                return source;
            }
        }

        auto variable = target.isVarExp;
        if (variable is null)
            throw new Exception(text(
                "Unsupported expression: ",
                assignment.op,
                " ",
                expressionChars(target),
                " targetOp=",
                target.op,
            ));

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", assignment.op));

        auto destination = declaration in localTemporaries;
        if (destination is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(target)));

        const source = lowerExpression(assignment.e2, lowerer);
        instructions ~= Instruction(Copy(
            *destination,
            source,
        ));
        return *destination;
    }

    uint lowerBlitAssignment(
        imported!"dmd.expression".BlitExp blit,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Copy, Instruction;
        import std.conv: text;

        auto variable = blit.e1.isVarExp;
        if (variable is null)
            throw new Exception(text(
                "Unsupported expression: ",
                blit.op,
                " ",
                expressionChars(blit.e1),
            ));

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", blit.op));

        auto destination = declaration in localTemporaries;
        const destinationName = declarationName(declaration);
        if (destination is null)
            destination = destinationName in identifierTemporaries;
        if (destination is null && expressionChars(blit.e1) == "result") {
            const temporary = allocateTemporary;
            rememberLocalTemporary(declaration, temporary);
            destination = declaration in localTemporaries;
        }
        if (destination is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(blit.e1)));

        if (typeIsStruct(declaration.type))
            if (auto source = blit.e2.isVarExp)
                if (source.var.isVarDeclaration is null)
                    return *destination;

        const source = lowerExpression(blit.e2, lowerer);
        instructions ~= Instruction(Copy(
            *destination,
            source,
        ));
        return *destination;
    }

    uint lowerPostIncrement(
        imported!"dmd.expression".PostExp post,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction:
            BinaryOp, ConstInt, Copy, Instruction, StructGet, StructSet;
        import std.conv: text;

        if (auto dot = post.e1.isDotVarExp) {
            auto this_ = dot.e1.isThisExp;
            auto owner = dot.e1.isVarExp;
            if (this_ is null && owner is null)
                throw new Exception(text("Unsupported expression: ", post.op));

            auto declaration = this_ !is null
                ? this_.var
                : owner.var.isVarDeclaration;
            if (declaration is null)
                throw new Exception(text("Unsupported expression: ", post.op));

            auto struct_ = declaration in localTemporaries;
            if (struct_ is null)
                throw new Exception(
                    text("Unsupported expression: ", expressionChars(post.e1)),
                );

            auto field = dot.var.isVarDeclaration;
            if (field is null)
                throw new Exception(text("Unsupported expression: ", post.op));

            const result = allocateTemporary;
            instructions ~= Instruction(StructGet(
                result,
                *struct_,
                declarationName(field),
            ));

            const one = allocateTemporary;
            instructions ~= Instruction(ConstInt(one, 1));
            const incremented = allocateTemporary;
            instructions ~= Instruction(BinaryOp(
                incremented,
                result,
                one,
                post.op == imported!"dmd.tokens".EXP.plusPlus
                    ? imported!"quickbite.ir.instruction".Operation.add
                    : imported!"quickbite.ir.instruction".Operation.subtract,
            ));
            instructions ~= Instruction(StructSet(
                *struct_,
                declarationName(field),
                incremented,
            ));
            return result;
        }

        if (auto index = post.e1.isIndexExp)
            if (!typeIsAssociativeArray(index.e1.type))
                return lowerArrayIndexPostIncrement(index, post, lowerer);

        auto variable = post.e1.isVarExp;
        if (variable is null)
            throw new Exception(text(
                "Unsupported expression: ",
                post.op,
                " ",
                expressionChars(post.e1),
            ));

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", post.op));

        auto destination = declaration in localTemporaries;
        if (destination is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(post.e1)));

        const result = allocateTemporary;
        instructions ~= Instruction(Copy(
            result,
            *destination,
        ));

        const one = allocateTemporary;
        instructions ~= Instruction(ConstInt(one, 1));
        const incremented = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            incremented,
            *destination,
            one,
            post.op == imported!"dmd.tokens".EXP.plusPlus
                ? imported!"quickbite.ir.instruction".Operation.add
                : imported!"quickbite.ir.instruction".Operation.subtract,
        ));
        instructions ~= Instruction(Copy(
            *destination,
            incremented,
        ));
        return result;
    }

    uint lowerArrayIndexPostIncrement(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".PostExp post,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction:
            ArrayIndex, ArraySet, BinaryOp, CastInt, ConstInt, Instruction;

        const array = lowerExpression(index.e1, lowerer);
        const indexValue = lowerExpression(index.e2, lowerer);
        const result = allocateTemporary;
        instructions ~= Instruction(ArrayIndex(
            result,
            array,
            indexValue,
        ));

        const one = allocateTemporary;
        instructions ~= Instruction(ConstInt(one, 1));
        const incremented = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            incremented,
            result,
            one,
            post.op == imported!"dmd.tokens".EXP.plusPlus
                ? imported!"quickbite.ir.instruction".Operation.add
                : imported!"quickbite.ir.instruction".Operation.subtract,
        ));
        const stored = allocateTemporary;
        instructions ~= Instruction(CastInt(
            stored,
            incremented,
            integerType(index.type),
        ));
        instructions ~= Instruction(ArraySet(
            array,
            indexValue,
            stored,
        ));
        return result;
    }

    uint lowerPreIncrement(imported!"dmd.expression".PreExp pre) @safe {
        import dmd.tokens: EXP;
        import quickbite.ir.instruction: BinaryOp, ConstInt, Copy, Instruction;
        import std.conv: text;

        auto variable = pre.e1.isVarExp;
        if (variable is null)
            throw new Exception(text("Unsupported expression: ", pre.op));

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", pre.op));

        auto destination = declaration in localTemporaries;
        if (destination is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(pre.e1)));

        const one = allocateTemporary;
        instructions ~= Instruction(ConstInt(one, 1));
        const incremented = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            incremented,
            *destination,
            one,
            pre.op == EXP.prePlusPlus
                ? imported!"quickbite.ir.instruction".Operation.add
                : imported!"quickbite.ir.instruction".Operation.subtract,
        ));
        instructions ~= Instruction(Copy(
            *destination,
            incremented,
        ));
        return *destination;
    }

    uint lowerArrayIndexAssignment(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArraySet, Instruction;

        if (typeIsAssociativeArray(index.e1.type))
            return lowerAssocArrayIndexAssignment(index, sourceExpression, lowerer);

        const array = lowerExpression(index.e1, lowerer);
        const indexValue = lowerExpression(index.e2, lowerer);
        const source = lowerExpression(sourceExpression, lowerer);
        instructions ~= Instruction(ArraySet(
            array,
            indexValue,
            source,
        ));
        return source;
    }

    uint lowerArraySliceAssignment(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayIndex, ArrayLength, ArraySet,
            BinaryOp, ConstInt, Copy, Instruction, Jump, JumpIfFalse, Operation;
        import std.conv: text;

        if (slice.lwr !is null || slice.upr !is null)
            throw new Exception(text("Unsupported expression: ", slice.op));

        const array = lowerExpression(slice.e1, lowerer);
        const source = lowerExpression(sourceExpression, lowerer);
        const length = allocateTemporary;
        instructions ~= Instruction(ArrayLength(length, source));
        const index = allocateTemporary;
        instructions ~= Instruction(ConstInt(index, 0));
        const one = allocateTemporary;
        instructions ~= Instruction(ConstInt(one, 1));

        const loopStart = instructions.length;
        const inRange = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            inRange,
            index,
            length,
            Operation.lessThan,
        ));
        const endJumpIndex = instructions.length;
        instructions ~= Instruction(JumpIfFalse(inRange, 0));
        const value = allocateTemporary;
        instructions ~= Instruction(ArrayIndex(value, source, index));
        instructions ~= Instruction(ArraySet(
            array,
            index,
            value,
        ));
        const nextIndex = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            nextIndex,
            index,
            one,
            Operation.add,
        ));
        instructions ~= Instruction(Copy(
            index,
            nextIndex,
        ));
        instructions ~= Instruction(Jump(
            cast(int) loopStart - cast(int) instructions.length,
        ));
        replaceJumpOffset(
            instructions,
            cast(uint) endJumpIndex,
            cast(int) (instructions.length - endJumpIndex),
        );
        return source;
    }

    uint lowerArrayLengthAssignment(
        imported!"dmd.expression".ArrayLengthExp length,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArraySetLength, Instruction;

        const array = lowerExpression(length.e1, lowerer);
        const source = lowerExpression(sourceExpression, lowerer);
        instructions ~= Instruction(ArraySetLength(
            array,
            source,
        ));
        return source;
    }

    uint lowerAssocArrayIndexAssignment(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArraySet, Instruction;

        const array = lowerExpression(index.e1, lowerer);
        const key = lowerExpression(index.e2, lowerer);
        const source = lowerExpression(sourceExpression, lowerer);
        instructions ~= Instruction(AssocArraySet(
            array,
            key,
            source,
        ));
        return source;
    }

    uint lowerAssocArrayIndexAssignment(
        imported!"dmd.expression".CallExp call,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: AssocArraySet, Instruction;

        enforceCallArgumentCount(call, 2);
        const array = lowerExpression(callArguments(call)[0], lowerer);
        const key = lowerExpression(callArguments(call)[1], lowerer);
        const source = lowerExpression(sourceExpression, lowerer);
        instructions ~= Instruction(AssocArraySet(
            array,
            key,
            source,
        ));
        return source;
    }

    uint lowerStructFieldAssignment(
        imported!"dmd.expression".DotVarExp dot,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructSet;
        import std.conv: text;

        const struct_ = lowerStructOwner(dot, lowerer);

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        const source = lowerExpression(sourceExpression, lowerer);
        instructions ~= Instruction(StructSet(
            struct_,
            declarationName(field),
            source,
        ));
        return source;
    }

    uint lowerStructFieldRead(
        imported!"dmd.expression".DotVarExp dot,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayLength, Instruction, StructGet;
        import std.conv: text;

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        if (declarationName(field) == "classinfo")
            return lowerClassInfoName(dot, lowerer);

        if (declarationName(field) == "name")
            if (auto classInfo = dot.e1.isDotVarExp)
                if (dotVarFieldName(classInfo) == "classinfo")
                    return lowerClassInfoName(classInfo, lowerer);

        if (declarationName(field) == "name")
            if (auto typeid_ = dot.e1.isTypeidExp)
                return lowerTypeInfoName(typeidObjectType(typeid_));

        if (declarationName(field) == "name")
            if (auto symbol = dot.e1.isSymOffExp)
                if (auto type = symbolOffsetTypeInfoType(symbol))
                    return lowerTypeInfoName(type);

        if (declarationName(field) == "name" && dot.e1.isPtrExp !is null)
            return lowerClassInfoNameOwner(dot.e1, lowerer);

        const struct_ = lowerStructOwner(dot, lowerer);

        if (
            declarationName(field) == "length" &&
            (typeIsDynamicArray(dot.e1.type) || !typeIsStruct(dot.e1.type))
        ) {
            const destination = allocateTemporary;
            instructions ~= Instruction(ArrayLength(
                destination,
                struct_,
            ));
            return destination;
        }

        const destination = allocateTemporary;
        instructions ~= Instruction(StructGet(
            destination,
            struct_,
            declarationName(field),
        ));
        return destination;
    }

    uint lowerClassInfoNameOwner(
        imported!"dmd.expression".Expression ownerExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructGet;

        const owner = lowerExpression(ownerExpression, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(StructGet(
            destination,
            owner,
            "__classinfo_name",
        ));
        return destination;
    }

    uint lowerTypeInfoName(imported!"dmd.mtype".Type type) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction;

        const destination = allocateTemporary;
        instructions ~= Instruction(ConstInt(
            destination,
            classInfoNameValue(type),
        ));
        return destination;
    }

    uint lowerDotIdentifierRead(
        imported!"dmd.expression".DotIdExp dot,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction, StructGet;

        if (expressionChars(dot.e1) == "F") {
            const destination = allocateTemporary;
            instructions ~= Instruction(ConstInt(destination, 0));
            return destination;
        }

        if (dot.e1.isTypeExp !is null) {
            const destination = allocateTemporary;
            instructions ~= Instruction(ConstInt(destination, 0));
            return destination;
        }

        const struct_ = lowerExpression(dot.e1, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(StructGet(
            destination,
            struct_,
            identifierName(dot.ident),
        ));
        return destination;
    }

    uint lowerStructOwner(
        imported!"dmd.expression".DotVarExp dot,
        ref Lowerer lowerer,
    ) @safe {
        import std.conv: text;

        auto owner = dot.e1.isVarExp;
        auto this_ = dot.e1.isThisExp;
        if (owner !is null || this_ !is null) {
            auto declaration = owner !is null
                ? owner.var.isVarDeclaration
                : this_.var;
            if (declaration is null)
                throw new Exception(text("Unsupported expression: ", dot.op));

            auto struct_ = declaration in localTemporaries;
            if (struct_ is null)
                throw new Exception(text(
                    "Unsupported expression: ",
                    expressionChars(dot.e1),
                ));

            return *struct_;
        }

        if (typeIsStruct(dot.e1.type) || typePointsToStruct(dot.e1.type))
            return lowerExpression(dot.e1, lowerer);

        throw new Exception(text(
            "Unsupported expression: ",
            dot.op,
            " ",
            expressionChars(dot),
            " owner=",
            expressionChars(dot.e1),
            " field=",
            dotVarFieldName(dot),
        ));
    }

    uint lowerClassInfoName(
        imported!"dmd.expression".DotVarExp classInfo,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction, StructGet;

        if (typeIsClass(classInfo.e1.type)) {
            const owner = lowerExpression(classInfo.e1, lowerer);
            const destination = allocateTemporary;
            instructions ~= Instruction(StructGet(
                destination,
                owner,
                "__classinfo_name",
            ));
            return destination;
        }

        const destination = allocateTemporary;
        instructions ~= Instruction(ConstInt(
            destination,
            classInfoNameValue(classInfo.e1.type),
        ));
        return destination;
    }

    uint lowerCompoundAssignment(
        imported!"dmd.expression".BinAssignExp assignment,
        in imported!"quickbite.ir.instruction".Operation operation,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: BinaryOp, CastInt, Copy, Instruction;
        import std.conv: text;

        auto variable = assignment.e1.isVarExp;
        if (auto cast_ = assignment.e1.isCastExp) {
            if (auto index = cast_.e1.isIndexExp)
                if (!typeIsAssociativeArray(index.e1.type))
                    return lowerArrayIndexCompoundAssignment(
                        index,
                        cast_,
                        assignment.e2,
                        operation,
                        lowerer,
                    );
            if (auto dot = cast_.e1.isDotVarExp)
                return lowerStructFieldCompoundAssignment(
                    dot,
                    assignment.e2,
                    operation,
                    lowerer,
                );
            if (auto nestedCast = cast_.e1.isCastExp)
                if (auto dot = nestedCast.e1.isDotVarExp)
                    return lowerStructFieldCompoundAssignment(
                        dot,
                        assignment.e2,
                        operation,
                        lowerer,
                    );
            variable = cast_.e1.isVarExp;
        }
        if (auto index = assignment.e1.isIndexExp)
            if (!typeIsAssociativeArray(index.e1.type))
                return lowerArrayIndexCompoundAssignment(
                    index,
                    null,
                    assignment.e2,
                    operation,
                    lowerer,
                );
        if (auto dot = assignment.e1.isDotVarExp)
            return lowerStructFieldCompoundAssignment(
                dot,
                assignment.e2,
                operation,
                lowerer,
            );
        if (auto nested = assignment.e1.isOrAssignExp)
            return lowerCompoundAssignment(nested, operation, lowerer);
        if (auto identifier = assignment.e1.isIdentifierExp) {
            const name = identifierName(identifier);
            if (auto destination = name in identifierTemporaries) {
                const source = lowerExpression(assignment.e2, lowerer);
                const result = allocateTemporary;
                instructions ~= Instruction(BinaryOp(
                    result,
                    *destination,
                    source,
                    operation,
                ));
                instructions ~= Instruction(Copy(
                    *destination,
                    result,
                ));
                return *destination;
            }
        }
        if (variable is null)
            throw new Exception(text(
                "Unsupported expression: ",
                assignment.op,
                " ",
                expressionChars(assignment.e1),
            ));

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", assignment.op));

        auto destination = declaration in localTemporaries;
        if (destination is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(assignment.e1)));

        const source = lowerExpression(assignment.e2, lowerer);
        const result = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            result,
            *destination,
            source,
            operation,
        ));
        const stored = allocateTemporary;
        instructions ~= Instruction(CastInt(
            stored,
            result,
            integerType(declaration.type),
        ));
        instructions ~= Instruction(Copy(
            *destination,
            stored,
        ));
        return *destination;
    }

    uint lowerStructFieldCompoundAssignment(
        imported!"dmd.expression".DotVarExp dot,
        imported!"dmd.expression".Expression sourceExpression,
        in imported!"quickbite.ir.instruction".Operation operation,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction:
            BinaryOp, CastInt, Instruction, StructGet, StructSet;
        import std.conv: text;

        const struct_ = lowerStructOwner(dot, lowerer);

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        const current = allocateTemporary;
        const fieldName = declarationName(field);
        instructions ~= Instruction(StructGet(
            current,
            struct_,
            fieldName,
        ));

        const source = lowerExpression(sourceExpression, lowerer);
        const result = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            result,
            current,
            source,
            operation,
        ));
        const stored = allocateTemporary;
        instructions ~= Instruction(CastInt(
            stored,
            result,
            integerType(field.type),
        ));
        instructions ~= Instruction(StructSet(
            struct_,
            fieldName,
            stored,
        ));
        return stored;
    }

    uint lowerArrayIndexCompoundAssignment(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".CastExp cast_,
        imported!"dmd.expression".Expression sourceExpression,
        in imported!"quickbite.ir.instruction".Operation operation,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction:
            ArrayIndex, ArraySet, BinaryOp, CastInt, Instruction;

        const array = lowerExpression(index.e1, lowerer);
        const indexValue = lowerExpression(index.e2, lowerer);
        const element = allocateTemporary;
        instructions ~= Instruction(ArrayIndex(
            element,
            array,
            indexValue,
        ));

        uint current = element;
        if (cast_ !is null) {
            const casted = allocateTemporary;
            instructions ~= Instruction(CastInt(
                casted,
                element,
                castTarget(cast_),
            ));
            current = casted;
        }

        const source = lowerExpression(sourceExpression, lowerer);
        const result = allocateTemporary;
        instructions ~= Instruction(BinaryOp(
            result,
            current,
            source,
            operation,
        ));
        const stored = allocateTemporary;
        instructions ~= Instruction(CastInt(
            stored,
            result,
            integerType(index.type),
        ));
        instructions ~= Instruction(ArraySet(
            array,
            indexValue,
            stored,
        ));
        return stored;
    }

    uint lowerArrayAppendAssignment(
        imported!"dmd.expression".BinAssignExp assignment,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayAppend, ArrayAppendArray,
            Instruction;
        import std.conv: text;

        auto target = assignment.e1;
        while (true) {
            if (auto cast_ = target.isCastExp) {
                target = cast_.e1;
                continue;
            }

            if (auto comma = target.isCommaExp) {
                lowerExpression(comma.e1, lowerer);
                target = comma.e2;
                continue;
            }

            if (auto address = target.isAddrExp) {
                target = address.e1;
                continue;
            }

            break;
        }

        if (auto dot = target.isDotVarExp) {
            const destination = lowerStructFieldRead(dot, lowerer);
            const value = lowerExpression(assignment.e2, lowerer);
            if (assignmentAppendsArray(assignment)) {
                instructions ~= Instruction(ArrayAppendArray(
                    destination,
                    value,
                ));
                return destination;
            }

            instructions ~= Instruction(ArrayAppend(
                destination,
                value,
            ));
            return destination;
        }

        if (auto identifier = target.isIdentifierExp) {
            const name = identifierName(identifier);
            uint destination;
            if (auto temporary = name in identifierTemporaries)
                destination = *temporary;
            else if (
                isThisFieldName(name) ||
                isThisFieldName("_" ~ name)
            )
                destination = lowerExpression(target, lowerer);
            else
                throw new Exception(text(
                    "Unsupported expression: ",
                    assignment.op,
                    " ",
                    expressionChars(target),
                ));

            const value = lowerExpression(assignment.e2, lowerer);
            if (assignmentAppendsArray(assignment)) {
                instructions ~= Instruction(ArrayAppendArray(
                    destination,
                    value,
                ));
                return destination;
            }

            instructions ~= Instruction(ArrayAppend(
                destination,
                value,
            ));
            return destination;
        }

        auto variable = target.isVarExp;
        if (variable is null)
            throw new Exception(text(
                "Unsupported expression: ",
                assignment.op,
                " ",
                expressionChars(target),
            ));

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", assignment.op));

        auto destination = declaration in localTemporaries;
        if (destination is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(target)));

        const value = lowerExpression(assignment.e2, lowerer);
        if (assignmentAppendsArray(assignment)) {
            instructions ~= Instruction(ArrayAppendArray(
                *destination,
                value,
            ));
            return *destination;
        }

        instructions ~= Instruction(ArrayAppend(
            *destination,
            value,
        ));
        return *destination;
    }

    bool assignmentAppendsArray(
        imported!"dmd.expression".BinAssignExp assignment,
    ) @safe {
        return expressionAppendsArray(assignment.e2);
    }

    bool expressionAppendsArray(
        imported!"dmd.expression".Expression expression,
    ) @safe {
        if (auto cast_ = expression.isCastExp)
            return typeIsDynamicArray(cast_.to) ||
                expressionAppendsArray(cast_.e1);

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                return typeIsDynamicArray(declaration.type);

        if (auto identifier = expression.isIdentifierExp)
            if ((identifierName(identifier) in arrayValueNames) !is null)
                return true;

        return typeIsDynamicArray(expression.type) ||
            expression.isArrayExp !is null ||
            expression.isSliceExp !is null ||
            expression.isStringExp !is null;
    }

    uint lowerArrayLength(
        imported!"dmd.expression".ArrayLengthExp length,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayLength, AssocArrayLength,
            Instruction;

        const array = lowerExpression(length.e1, lowerer);
        const destination = allocateTemporary;
        if (typeIsAssociativeArray(length.e1.type)) {
            instructions ~= Instruction(AssocArrayLength(
                destination,
                array,
            ));
            return destination;
        }

        instructions ~= Instruction(ArrayLength(
            destination,
            array,
        ));
        return destination;
    }

    uint lowerArrayIndex(
        imported!"dmd.expression".IndexExp index,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayIndex, AssocArrayIndex,
            AssocArrayValuePointer, Instruction;

        const array = lowerExpression(index.e1, lowerer);
        dollarArrays ~= array;
        const indexValue = lowerExpression(index.e2, lowerer);
        dollarArrays = dollarArrays[0 .. dollarArrays.length - 1];
        const destination = allocateTemporary;
        if (typeIsAssociativeArray(index.e1.type)) {
            if (typeIsPointer(index.type)) {
                instructions ~= Instruction(AssocArrayValuePointer(
                    destination,
                    array,
                    indexValue,
                ));
                return destination;
            }

            instructions ~= Instruction(AssocArrayIndex(
                destination,
                array,
                indexValue,
            ));
            return destination;
        }

        instructions ~= Instruction(ArrayIndex(
            destination,
            array,
            indexValue,
        ));
        return destination;
    }

    uint lowerArrayExpression(
        imported!"dmd.expression".ArrayExp array,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayIndex, AssocArrayIndex,
            AssocArrayValuePointer, Instruction;
        import std.conv: text;

        if (arrayExpressionArguments(array).length == 0)
            if (
                typeIsScopeBuffer(array.e1.type) ||
                typeIsScopeBufferRange(array.e1.type)
            )
                return lowerScopeBufferArrayExpression(array.e1, lowerer);

        if (arrayExpressionArguments(array).length == 0)
            return lowerExpression(array.e1, lowerer);

        if (arrayExpressionArguments(array).length != 1)
            throw new Exception(text("Unsupported expression: ", array.op));

        if (auto interval = arrayExpressionArguments(array)[0].isIntervalExp)
            return lowerArrayIntervalExpression(array.e1, interval, lowerer);

        if (auto index = array.e1.isIndexExp)
            if (typeIsAssociativeArray(index.e1.type)) {
                import quickbite.ir.instruction: AssocArrayValuePointer;

                const assocArray = lowerExpression(index.e1, lowerer);
                const key = lowerExpression(index.e2, lowerer);
                const pointer = allocateTemporary;
                instructions ~= Instruction(AssocArrayValuePointer(
                    pointer,
                    assocArray,
                    key,
                ));

                const indexValue = lowerExpression(
                    arrayExpressionArguments(array)[0],
                    lowerer,
                );
                const destination = allocateTemporary;
                instructions ~= Instruction(ArrayIndex(
                    destination,
                    pointer,
                    indexValue,
                ));
                return destination;
            }

        const arrayValue = lowerExpression(array.e1, lowerer);
        const indexValue = lowerExpression(arrayExpressionArguments(array)[0], lowerer);
        const destination = allocateTemporary;
        if (typeIsAssociativeArray(array.e1.type)) {
            if (typeIsPointer(array.type)) {
                instructions ~= Instruction(AssocArrayValuePointer(
                    destination,
                    arrayValue,
                    indexValue,
                ));
                return destination;
            }

            instructions ~= Instruction(AssocArrayIndex(
                destination,
                arrayValue,
                indexValue,
            ));
            return destination;
        }

        instructions ~= Instruction(ArrayIndex(
            destination,
            arrayValue,
            indexValue,
        ));
        return destination;
    }

    uint lowerScopeBufferArrayExpression(
        imported!"dmd.expression".Expression expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructGet;

        const receiver = lowerExpression(expression, lowerer);
        if (typeIsScopeBufferRange(expression.type)) {
            const scopeBuffer = allocateTemporary;
            instructions ~= Instruction(StructGet(scopeBuffer, receiver, "sbuf"));
            const array = allocateTemporary;
            instructions ~= Instruction(StructGet(array, scopeBuffer, "arr"));
            return array;
        }

        const array = allocateTemporary;
        instructions ~= Instruction(StructGet(array, receiver, "arr"));
        return array;
    }

    uint lowerArrayIntervalExpression(
        imported!"dmd.expression".Expression arrayExpression,
        imported!"dmd.expression".IntervalExp interval,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArraySlice, Instruction;
        import std.conv: text;

        if (interval.lwr !is null && interval.upr !is null) {
            const array = lowerExpression(arrayExpression, lowerer);
            dollarArrays ~= array;
            const lower = lowerExpression(interval.lwr, lowerer);
            const upper = lowerExpression(interval.upr, lowerer);
            dollarArrays = dollarArrays[0 .. dollarArrays.length - 1];
            const destination = allocateTemporary;
            instructions ~= Instruction(ArraySlice(
                destination,
                array,
                lower,
                upper,
            ));
            return destination;
        }

        throw new Exception(text("Unsupported expression: ", interval.op));
    }

    uint lowerCast(
        imported!"dmd.expression".CastExp cast_,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: CastInt, Instruction;

        // Pointer casts are no-ops in the VM: the "pointer" is just a temp
        // index, so reinterpreting its integer type changes nothing.
        if (typeIsPointer(cast_.to))
            return lowerExpression(cast_.e1, lowerer);

        if (typeIsDynamicArray(cast_.to))
            return lowerExpression(cast_.e1, lowerer);

        if (typeIsAssociativeArray(cast_.to))
            return lowerExpression(cast_.e1, lowerer);

        if (typeIsClass(cast_.to))
            return lowerExpression(cast_.e1, lowerer);

        if (typeIsFloating(cast_.to))
            return lowerExpression(cast_.e1, lowerer);

        if (typeIsBool(cast_.to))
            return lowerTruthValue(lowerExpression(cast_.e1, lowerer));

        const source = lowerExpression(cast_.e1, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(CastInt(
            destination,
            source,
            castTarget(cast_),
        ));
        return destination;
    }

    void lowerIfStatement(
        imported!"dmd.statement".IfStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, Jump, JumpIfFalse;

        const condition = lowerTruthValue(lowerExpression(statement.condition, lowerer));
        const ifFalseJumpIndex = instructions.length;
        instructions ~= Instruction(JumpIfFalse(condition, 0));
        const ifTrueReturns = lowerBranch(statement.ifbody, lowerer);

        if (statement.elsebody is null) {
            replaceJumpOffset(
                instructions,
                cast(uint) ifFalseJumpIndex,
                cast(int) (instructions.length - ifFalseJumpIndex - 1),
            );
            hasReturn = false;
            return;
        }

        size_t skipElseJumpIndex = size_t.max;
        if (!ifTrueReturns) {
            skipElseJumpIndex = instructions.length;
            instructions ~= Instruction(Jump(0));
        }

        replaceJumpOffset(
            instructions,
            cast(uint) ifFalseJumpIndex,
            cast(int) (instructions.length - ifFalseJumpIndex - 1),
        );
        const ifFalseReturns = lowerBranch(statement.elsebody, lowerer);

        if (skipElseJumpIndex != size_t.max)
            replaceJumpOffset(
                instructions,
                cast(uint) skipElseJumpIndex,
                cast(int) (instructions.length - skipElseJumpIndex),
            );

        hasReturn = ifTrueReturns && ifFalseReturns;
    }

    bool lowerBranch(
        imported!"dmd.statement".Statement statement,
        ref Lowerer lowerer,
    ) @safe {
        const previousHasReturn = hasReturn;
        hasReturn = false;
        lowerStatement(statement, lowerer);
        const branchHasReturn = hasReturn;
        hasReturn = previousHasReturn;
        return branchHasReturn;
    }

    void lowerReturnStatement(
        imported!"dmd.statement".ReturnStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: CastInt, Instruction, ReturnValue,
            ReturnVoid;

        if (statement.exp is null) {
            instructions ~= Instruction(ReturnVoid.init);
            return;
        }
        const value = lowerExpression(statement.exp, lowerer);
        if (typeIsInteger(currentReturnType)) {
            const castValue = allocateTemporary;
            instructions ~= Instruction(CastInt(
                castValue,
                value,
                integerType(currentReturnType),
            ));
            instructions ~= Instruction(ReturnValue(castValue));
            return;
        }

        instructions ~= Instruction(ReturnValue(value));
    }

    uint lowerParameters(imported!"dmd.func".FuncDeclaration function_) @safe {
        uint numParameters;
        if (function_.vthis !is null) {
            const temporary = allocateTemporary;
            localTemporaries[function_.vthis] = temporary;
            identifierTemporaries[declarationName(function_.vthis)] = temporary;
            rememberThisTemporary(temporary, functionThisType(function_));
            refParameters ~= true;
            ++numParameters;
        } else if (functionThisStructType(function_) !is null) {
            const temporary = allocateTemporary;
            rememberThisTemporary(temporary, functionThisStructType(function_));
            refParameters ~= true;
            ++numParameters;
        }

        if (function_.parameters is null)
            return numParameters + lowerTypeParameters(function_);

        foreach (parameter; functionParameters(function_)) {
            if (parameterHasUnsupportedStorage(parameter)) {
                import std.conv: text;

                throw new Exception(text(
                    "Unsupported function parameter: ",
                    functionIdentifier(function_),
                    ".",
                    declarationName(parameter),
                    " storage=",
                    parameter.storage_class,
                ));
            }

            const temporary = allocateTemporary;
            localTemporaries[parameter] = temporary;
            const name = declarationName(parameter);
            identifierTemporaries[name] = temporary;
            if (typeIsDynamicArray(parameter.type))
                arrayValueNames[name] = true;
            if (name == "this")
                rememberThisTemporary(temporary, structReceiverType(parameter.type));
            if (parameterIsLazy(parameter)) {
                lazyParameters[parameter] = true;
                lazyParameterNames[name] = true;
            }
            refParameters ~= parameterIsRef(parameter);
            ++numParameters;
        }

        return numParameters;
    }

    uint lowerTypeParameters(imported!"dmd.func".FuncDeclaration function_) @safe {
        uint numParameters;
        foreach (parameter; functionTypeParameters(function_)) {
            if (typeParameterHasUnsupportedStorage(parameter)) {
                import std.conv: text;

                throw new Exception(text(
                    "Unsupported function parameter: ",
                    functionIdentifier(function_),
                    ".",
                    parameterName(parameter),
                    " storage=",
                    parameter.storageClass,
                ));
            }

            const temporary = allocateTemporary;
            const name = parameterName(parameter);
            identifierTemporaries[name] = temporary;
            if (typeIsDynamicArray(parameter.type))
                arrayValueNames[name] = true;
            refParameters ~= typeParameterIsRef(parameter);
            ++numParameters;
        }

        return numParameters;
    }

    bool parameterHasUnsupportedStorage(
        imported!"dmd.declaration".VarDeclaration parameter,
    ) @safe {
        import dmd.astenums: STC;

        enum unsupported =
            STC.out_ |
            STC.variadic |
            STC.alias_ |
            STC.auto_;
        return (parameter.storage_class & unsupported) != STC.none;
    }

    bool typeParameterHasUnsupportedStorage(
        imported!"dmd.mtype".Parameter parameter,
    ) @safe {
        import dmd.astenums: STC;

        enum unsupported =
            STC.out_ |
            STC.variadic |
            STC.alias_ |
            STC.auto_ |
            STC.lazy_;
        return (parameter.storageClass & unsupported) != STC.none;
    }

    bool parameterIsRef(imported!"dmd.declaration".VarDeclaration parameter) @safe {
        import dmd.astenums: STC;

        return (parameter.storage_class & STC.ref_) != STC.none;
    }

    bool typeParameterIsRef(imported!"dmd.mtype".Parameter parameter) @safe {
        import dmd.astenums: STC;

        return (parameter.storageClass & STC.ref_) != STC.none;
    }

    bool parameterIsLazy(imported!"dmd.declaration".VarDeclaration parameter) @safe {
        import dmd.astenums: STC;

        return (parameter.storage_class & STC.lazy_) != STC.none;
    }

    uint[] lowerCallArguments(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        return lowerCallArgumentsForFunction(call, call.f, lowerer);
    }

    uint[] lowerCallArgumentsForFunction(
        imported!"dmd.expression".CallExp call,
        imported!"dmd.func".FuncDeclaration function_,
        ref Lowerer lowerer,
    ) @safe {
        uint[] arguments;
        if (functionHasReceiver(function_))
            arguments ~= lowerCallReceiver(call, lowerer);

        if (call.arguments is null)
            return appendMissingTypeFunctionArguments(arguments, function_);

        // Pulled in parallel so we can detect non-ref struct parameters and
        // copy by value at the call site, matching D semantics. `auto`
        // because `parameterIsRef` takes a mutable `VarDeclaration`.
        auto parameters = function_.parameters !is null
            ? functionParameterSlice(function_)
            : null;
        foreach (i, argument; callArguments(call)) {
            VarDeclaration parameter;
            if (i < parameters.length)
                parameter = parameters[i];

            const source = lowerCallArgument(argument, parameter, lowerer);
            if (i < parameters.length && parameterIsRef(parameters[i])) {
                if (auto variable = argument.isVarExp) {
                    if (auto var = variable.var.isVarDeclaration) {
                        if (auto alias_ = var in arrayElementAliases)
                            pendingRefArrayWritebacks ~= *alias_;
                    }
                }
            }
            if (i < parameters.length
                && !parameterIsRef(parameters[i])
                && typeIsStruct(argument.type))
            {
                arguments ~= copyStructByValue(argument.type, source);
                continue;
            }
            arguments ~= source;
        }

        return appendMissingTypeFunctionArguments(arguments, function_);
    }

    uint[] appendMissingTypeFunctionArguments(
        uint[] arguments,
        imported!"dmd.func".FuncDeclaration function_,
    ) @safe {
        import quickbite.ir.instruction: ConstInt, Instruction;

        if (function_.parameters !is null)
            return arguments;

        const expectedArguments = (functionHasReceiver(function_) ? 1 : 0) +
            functionTypeParameters(function_).length;
        while (arguments.length < expectedArguments) {
            const value = allocateTemporary;
            instructions ~= Instruction(ConstInt(value, 0));
            arguments ~= value;
        }

        return arguments;
    }

    uint[] lowerIndirectCallArguments(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        uint[] arguments;
        if (call.arguments is null)
            return arguments;

        foreach (argument; callArguments(call))
            arguments ~= lowerCallArgument(argument, null, lowerer);

        return arguments;
    }

    uint lowerCallArgument(
        imported!"dmd.expression".Expression argument,
        imported!"dmd.declaration".VarDeclaration parameter,
        ref Lowerer lowerer,
    ) @safe {
        if (parameter !is null && parameterIsLazy(parameter))
            if (auto literal = argument.isFuncExp)
                return lowerImmediateFunctionLiteralCall(literal.fd, lowerer);

        if (parameter !is null && parameterIsRef(parameter))
            if (auto dot = argument.isDotVarExp)
                return lowerStructFieldRefArgument(dot, lowerer);

        return lowerExpression(argument, lowerer);
    }

    uint lowerStructFieldRefArgument(
        imported!"dmd.expression".DotVarExp dot,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructGet;
        import std.conv: text;

        const struct_ = lowerStructOwner(dot, lowerer);
        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        const value = allocateTemporary;
        const fieldName = declarationName(field);
        instructions ~= Instruction(StructGet(
            value,
            struct_,
            fieldName,
        ));
        pendingRefStructWritebacks ~= StructFieldAlias(
            struct_,
            fieldName,
            value,
        );
        return value;
    }

    uint copyStructByValue(
        imported!"dmd.mtype".Type type,
        in uint source,
    ) @safe {
        import quickbite.ir.instruction: ArrayReferenceCopy, Instruction,
            StructGet, StructNew, StructSet;

        const destination = allocateTemporary;
        instructions ~= Instruction(StructNew(destination));
        foreach (field; structFields(type)) {
            const fieldValue = allocateTemporary;
            const name = declarationName(field);
            instructions ~= Instruction(StructGet(fieldValue, source, name));
            if (typeIsDynamicArray(field.type)) {
                const copied = allocateTemporary;
                instructions ~= Instruction(ArrayReferenceCopy(copied, fieldValue));
                instructions ~= Instruction(StructSet(destination, name, copied));
                continue;
            }

            instructions ~= Instruction(StructSet(destination, name, fieldValue));
        }
        return destination;
    }

    uint lowerCallReceiver(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        import std.conv: text;

        if (auto dot = call.e1.isDotVarExp)
            return lowerExpression(dot.e1, lowerer);

        if (auto dot = call.e1.isDotTemplateInstanceExp)
            return lowerExpression(dot.e1, lowerer);

        if (call.e1.isVarExp !is null)
            if (call.f.vthis !is null) {
                const receiverName = declarationName(call.f.vthis);
                auto receiver = receiverName in identifierTemporaries;
                if (receiver !is null)
                    return *receiver;
                if (receiverName == "__capture") {
                    import quickbite.ir.instruction: Instruction, StructNew;

                    const emptyCapture = allocateTemporary;
                    instructions ~= Instruction(StructNew(emptyCapture));
                    return emptyCapture;
                }
            }

        if (call.e1.isVarExp !is null && functionThisStructType(call.f) !is null)
            if (hasThisTemporary)
                return thisTemporary;

        throw new Exception(text(
            "Unsupported expression: ",
            call.e1.op,
            " ",
            expressionChars(call.e1),
            " for receiver of ",
            lowerer.functionName(call.f),
            " vthis ",
            call.f.vthis is null ? "<null>" : declarationName(call.f.vthis),
        ));
    }

    void rememberThisTemporary(
        in uint temporary,
        imported!"dmd.mtype".Type type,
    ) @safe {
        hasThisTemporary = true;
        thisTemporary = temporary;

        if (type is null)
            return;

        if (typeIsClass(type)) {
            foreach (field; classFields(type))
                thisFieldNames[declarationName(field)] = true;
            return;
        }

        if (typeIsStruct(type))
            foreach (field; structFields(type))
                thisFieldNames[declarationName(field)] = true;
    }

    bool isThisFieldName(in string name) @safe {
        return hasThisTemporary && (name in thisFieldNames) !is null;
    }

    uint allocateTemporary() @safe pure nothrow @nogc {
        const result = nextTemporary;
        ++nextTemporary;
        return result;
    }

    void rememberLocalTemporary(
        imported!"dmd.declaration".VarDeclaration variable,
        in uint temporary,
    ) @safe {
        localTemporaries[variable] = temporary;
        identifierTemporaries[declarationName(variable)] = temporary;
    }
}

private long integerValue(imported!"dmd.expression".IntegerExp integer) @trusted {
    return integer.getInteger();
}

private long realLiteralValue(imported!"dmd.expression".RealExp real_) @trusted {
    import dmd.astenums: TY;

    const basetype = real_.type.toBasetype;

    if (basetype.ty == TY.Tfloat32) {
        float value = cast(float) real_.toReal();
        return *cast(uint*) &value;
    }

    if (basetype.ty == TY.Tfloat64) {
        double value = cast(double) real_.toReal();
        return cast(long) *cast(ulong*) &value;
    }

    return real_.toInteger();
}

private imported!"dmd.expression".Expression[] arrayExpressionArguments(
    imported!"dmd.expression".ArrayExp expression,
) @trusted {
    return (*expression.arguments)[];
}

private size_t stringLiteralLength(
    imported!"dmd.expression".StringExp literal,
) @trusted {
    return literal.numberOfCodeUnits();
}

private long stringLiteralCodeUnit(
    imported!"dmd.expression".StringExp literal,
    in size_t index,
) @trusted {
    return literal.getIndex(index);
}

private string gotoLabel(imported!"dmd.statement".GotoStatement statement) @safe {
    return statement.ident.toString.idup;
}

private string breakLabel(imported!"dmd.statement".BreakStatement statement) @safe {
    return statement.ident.toString.idup;
}

private string continueLabel(
    imported!"dmd.statement".ContinueStatement statement,
) @safe {
    return statement.ident.toString.idup;
}

private string statementLabel(
    imported!"dmd.statement".LabelStatement statement,
) @safe {
    return statement.ident.toString.idup;
}

private bool conditionalStatementIncluded(
    imported!"dmd.statement".ConditionalStatement statement,
) @trusted {
    import dmd.cond: Include;

    return statement.condition.inc == Include.yes;
}

private void replaceJumpOffset(
    ref imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint index,
    in int offset,
) @safe {
    import quickbite.ir.instruction: Jump, JumpIfFalse, JumpIfTrue;
    import std.sumtype: match;

    instructions[index].match!(
        (ref JumpIfFalse instruction) {
            instruction.offset = offset;
        },
        (ref JumpIfTrue instruction) {
            instruction.offset = offset;
        },
        (ref Jump instruction) {
            instruction.offset = offset;
        },
        (_) {
            assert(0, "Expected jump instruction");
        },
    );
}

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import std.string: fromStringz;

    return fromStringz(expression.toChars()).idup;
}

private imported!"dmd.func".FuncDeclaration[] functionPointerTableFunctions(
    imported!"dmd.declaration".VarDeclaration variable,
) @safe {
    if (variable._init is null)
        return null;

    if (auto initializer = variable._init.isExpInitializer)
        return functionPointerTableFunctions(initializer.exp);

    if (auto initializer = variable._init.isArrayInitializer)
        return functionPointerTableFunctions(initializer);

    return null;
}

private imported!"dmd.func".FuncDeclaration[] functionPointerTableFunctions(
    imported!"dmd.expression".Expression expression,
) @safe {
    if (auto literal = expression.isArrayLiteralExp) {
        imported!"dmd.func".FuncDeclaration[] functions;
        if (literal.elements is null)
            return functions;

        foreach (element; arrayLiteralElements(literal)) {
            // DMD lowering APIs need mutable function declarations.
            auto function_ = functionPointerExpressionFunction(element);
            if (function_ is null)
                return null;
            functions ~= function_;
        }
        return functions;
    }

    return null;
}

private imported!"dmd.func".FuncDeclaration[] functionPointerTableFunctions(
    imported!"dmd.init".ArrayInitializer initializer,
) @safe {
    imported!"dmd.func".FuncDeclaration[] functions;
    foreach (element; arrayInitializerValues(initializer)) {
        if (element is null)
            return null;

        // DMD initializers expose mutable expression nodes.
        auto exp = element.isExpInitializer;
        if (exp is null)
            return null;

        // DMD lowering APIs need mutable function declarations.
        auto function_ = functionPointerExpressionFunction(exp.exp);
        if (function_ is null)
            return null;
        functions ~= function_;
    }
    return functions;
}

private imported!"dmd.func".FuncDeclaration functionPointerExpressionFunction(
    imported!"dmd.expression".Expression expression,
) @safe {
    if (auto function_ = expression.isFuncExp)
        return function_.fd;

    if (auto address = expression.isAddrExp)
        return functionPointerExpressionFunction(address.e1);

    if (auto symbol = expression.isSymOffExp)
        return symbol.var.isFuncDeclaration;

    return null;
}

private string declarationKind(imported!"dmd.dsymbol".Dsymbol symbol) @trusted {
    import std.string: fromStringz;

    return fromStringz(symbol.kind).idup;
}

private string initializerChars(
    imported!"dmd.init".Initializer initializer,
) @trusted {
    import std.string: fromStringz;

    return fromStringz(initializer.toChars()).idup;
}

private string identifierName(
    imported!"dmd.expression".IdentifierExp identifier,
) @trusted {
    return identifier.ident.toString.idup;
}

private string identifierName(
    imported!"dmd.identifier".Identifier identifier,
) @trusted {
    return identifier.toString.idup;
}

private string locationChars(imported!"dmd.location".Loc location) @trusted {
    import std.string: fromStringz;

    return fromStringz(location.toChars()).idup;
}

private imported!"dmd.expression".CmpExp castCmpExpression(
    imported!"dmd.expression".Expression expression,
) @trusted {
    auto result = cast(imported!"dmd.expression".CmpExp) expression;
    assert(result !is null, "Expected DMD CmpExp for comparison operator");
    return result;
}

private bool comparisonUsesUnsignedOperand(
    imported!"dmd.expression".CmpExp comparison,
) @safe {
    return expressionHasUnsignedIntegerType(comparison.e1) ||
        expressionHasUnsignedIntegerType(comparison.e2);
}

private bool expressionHasUnsignedIntegerType(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import dmd.astenums: TY;

    if (expression.type is null)
        return false;

    const type = expression.type.toBasetype;
    return type.ty == TY.Tuns8 ||
        type.ty == TY.Tuns16 ||
        type.ty == TY.Tuns32 ||
        type.ty == TY.Tuns64;
}

private bool typeIsInteger(imported!"dmd.mtype".Type type) @trusted {
    import dmd.astenums: TY;

    if (type is null)
        return false;

    const basetype = type.toBasetype;
    return basetype.ty == TY.Tint8 ||
        basetype.ty == TY.Tuns8 ||
        basetype.ty == TY.Tchar ||
        basetype.ty == TY.Tint16 ||
        basetype.ty == TY.Tuns16 ||
        basetype.ty == TY.Tint32 ||
        basetype.ty == TY.Tuns32 ||
        basetype.ty == TY.Tdchar ||
        basetype.ty == TY.Tint64 ||
        basetype.ty == TY.Tuns64;
}

private bool isArrayEqualityCall(imported!"dmd.expression".CallExp call) @trusted {
    import dmd.id: Id;

    return call.f.ident == Id.__equals;
}

private bool isAssocArrayGetCall(
    imported!"dmd.expression".CallExp call,
) @trusted {
    return call.f !is null && functionIdentifier(call.f) == "_d_aaGetY";
}

private bool isCoreCheckedIntMuluCall(
    imported!"dmd.expression".CallExp call,
    ref Lowerer lowerer,
) @safe {
    import std.string: startsWith;

    return lowerer.functionName(call.f).startsWith(
        "_D4core10checkedint__T4mulu",
    );
}

private string functionIdentifier(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    return function_.ident.toString.idup;
}

private void enforceCallArgumentCount(
    imported!"dmd.expression".CallExp call,
    in size_t expected,
) @safe {
    if (call.arguments is null && expected == 0)
        return;

    if (call.arguments is null || callArguments(call).length < expected)
        throw new Exception("Unsupported call.");
}

private imported!"quickbite.ir.instruction".IntegerType castTarget(
    imported!"dmd.expression".CastExp cast_,
) @trusted {
    return integerType(cast_.to);
}

private imported!"quickbite.ir.instruction".IntegerType integerType(
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.astenums: TY;
    import quickbite.ir.instruction: IntegerType;
    import std.conv: text;

    const basetype = type.toBasetype;

    if (basetype.ty == TY.Tint8)
        return IntegerType.i8;

    if (basetype.ty == TY.Tuns8 || basetype.ty == TY.Tchar)
        return IntegerType.u8;

    if (basetype.ty == TY.Tint16)
        return IntegerType.i16;

    if (basetype.ty == TY.Tuns16)
        return IntegerType.u16;

    if (basetype.ty == TY.Tint32)
        return IntegerType.i32;

    if (basetype.ty == TY.Tuns32 || basetype.ty == TY.Tdchar)
        return IntegerType.u32;

    if (basetype.ty == TY.Tint64)
        return IntegerType.i64;

    if (basetype.ty == TY.Tuns64)
        return IntegerType.u64;

    const name = typeChars(type);
    if (name == "RoundingMode" || name == "ExceptionMask")
        return IntegerType.u32;

    throw new Exception(text("Unsupported cast to: ", name));
}

private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return fromStringz(type.toChars()).idup;
}

private bool typeIsPointer(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.isTypePointer !is null;
}

private bool typeIsBool(imported!"dmd.mtype".Type type) @trusted {
    import dmd.astenums: TY;

    return type !is null && type.toBasetype.ty == TY.Tbool;
}

private bool typeIsAppender(imported!"dmd.mtype".Type type) @trusted {
    import std.algorithm.searching: canFind;

    return type !is null && typeChars(type).canFind("Appender!");
}

private bool typeIsScopeBuffer(imported!"dmd.mtype".Type type) @trusted {
    import std.algorithm.searching: canFind;

    return type !is null && typeChars(type).canFind("ScopeBuffer!");
}

private bool typeIsScopeBufferRange(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && typeChars(type) == "ScopeBufferRange";
}

private bool callHasAppenderReceiver(
    imported!"dmd.expression".CallExp call,
) @trusted {
    if (auto dot = call.e1.isDotVarExp)
        return typeIsAppender(dot.e1.type);

    if (auto dot = call.e1.isDotTemplateInstanceExp)
        return typeIsAppender(dot.e1.type);

    return false;
}

private bool callHasDynamicArrayRangeReceiver(
    imported!"dmd.expression".CallExp call,
) @trusted {
    import std.algorithm.searching: canFind;

    auto thisType = functionThisStructType(call.f);
    if (thisType !is null && typeChars(thisType).canFind("DynamicArrayRange"))
        return true;

    if (auto dot = call.e1.isDotVarExp)
        return dot.e1.type !is null &&
            typeChars(dot.e1.type).canFind("DynamicArrayRange");

    if (auto dot = call.e1.isDotTemplateInstanceExp)
        return dot.e1.type !is null &&
            typeChars(dot.e1.type).canFind("DynamicArrayRange");

    return false;
}

private bool callHasScopeBufferReceiver(
    imported!"dmd.expression".CallExp call,
) @trusted {
    return callHasScopeBufferDirectReceiver(call) ||
        callHasScopeBufferRangeReceiver(call);
}

private bool callHasScopeBufferDirectReceiver(
    imported!"dmd.expression".CallExp call,
) @trusted {
    // auto: DMD Type helpers below require the mutable frontend object.
    auto thisType = functionThisStructType(call.f);
    if (thisType !is null && typeIsScopeBuffer(thisType))
        return true;

    if (auto dot = call.e1.isDotVarExp)
        return typeIsScopeBuffer(dot.e1.type);

    if (auto dot = call.e1.isDotTemplateInstanceExp)
        return typeIsScopeBuffer(dot.e1.type);

    return false;
}

private bool callHasScopeBufferRangeReceiver(
    imported!"dmd.expression".CallExp call,
) @trusted {
    // auto: DMD Type helpers below require the mutable frontend object.
    auto thisType = functionThisStructType(call.f);
    if (thisType !is null && typeIsScopeBufferRange(thisType))
        return true;

    if (auto dot = call.e1.isDotVarExp)
        return typeIsScopeBufferRange(dot.e1.type);

    if (auto dot = call.e1.isDotTemplateInstanceExp)
        return typeIsScopeBufferRange(dot.e1.type);

    return false;
}

private bool typePointsToStruct(imported!"dmd.mtype".Type type) @trusted {
    return type !is null &&
        type.isTypePointer !is null &&
        type.nextOf.isTypeStruct !is null;
}

private bool functionHasReceiver(
    imported!"dmd.func".FuncDeclaration function_,
) @safe {
    return function_.vthis !is null || functionThisStructType(function_) !is null;
}

private imported!"dmd.mtype".Type functionThisStructType(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    // Explicit type keeps DMD's mutable aggregate available for the
    // declaration-kind query below.
    imported!"dmd.aggregate".AggregateDeclaration aggregate = function_.isThis;
    if (aggregate is null || aggregate.isStructDeclaration is null)
        return null;

    return aggregate.type;
}

private imported!"dmd.mtype".Type functionThisType(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    // Explicit type keeps DMD's mutable aggregate available.
    imported!"dmd.aggregate".AggregateDeclaration aggregate = function_.isThis;
    return aggregate is null ? null : aggregate.type;
}

private imported!"dmd.mtype".Type structReceiverType(
    imported!"dmd.mtype".Type type,
) @safe {
    if (typeIsStruct(type))
        return type;

    if (typePointsToStruct(type))
        return pointerTarget(type);

    return null;
}

private imported!"dmd.mtype".Type pointerTarget(
    imported!"dmd.mtype".Type type,
) @trusted {
    return type.nextOf;
}

private bool typeIsStruct(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.isTypeStruct !is null;
}

private bool typeIsClass(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.toBasetype.isTypeClass !is null;
}

private bool typeIsDynamicArray(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.toBasetype.isTypeDArray !is null;
}

private bool typeIsAssociativeArray(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.toBasetype.isTypeAArray !is null;
}

private bool typeIsFloating(imported!"dmd.mtype".Type type) @trusted {
    import dmd.astenums: TY;

    if (type is null)
        return false;

    const basetype = type.toBasetype;
    return basetype.ty == TY.Tfloat32 ||
        basetype.ty == TY.Tfloat64 ||
        basetype.ty == TY.Tfloat80;
}

private bool varIsParameter(
    imported!"dmd.declaration".VarDeclaration declaration,
) @safe {
    import dmd.astenums: STC;

    return (declaration.storage_class & STC.parameter) != STC.none;
}

private bool varIsStatic(
    imported!"dmd.declaration".VarDeclaration declaration,
) @safe {
    import dmd.astenums: STC;

    return (declaration.storage_class & STC.static_) != STC.none;
}

private string staticVariableName(
    imported!"dmd.declaration".VarDeclaration declaration,
) @trusted {
    import std.conv: text;

    return text(declarationName(declaration), ":", typeChars(declaration.type));
}

private ref auto structFields(
    imported!"dmd.mtype".Type type,
) @trusted {
    return type.toBasetype.isTypeStruct.sym.fields;
}

private imported!"dmd.declaration".VarDeclaration[] classFields(
    imported!"dmd.mtype".Type type,
) @trusted {
    imported!"dmd.declaration".VarDeclaration[] fields;
    if (type is null)
        return fields;

    imported!"dmd.dclass".ClassDeclaration[] classes;
    for (auto class_ = type.toBasetype.isTypeClass.sym;
        class_ !is null;
        class_ = class_.baseClass)
        classes ~= class_;

    foreach_reverse (class_; classes)
        foreach (field; class_.fields)
            fields ~= field;

    return fields;
}

private string declarationName(
    imported!"dmd.declaration".VarDeclaration declaration,
) @trusted {
    return declaration.ident.toString.idup;
}

private string dotVarFieldName(
    imported!"dmd.expression".DotVarExp dot,
) @trusted {
    return dot.var.ident.toString.idup;
}

private long classInfoNameValue(imported!"dmd.mtype".Type type) @trusted {
    return stableIdentifierValue(type is null ? "<null>" : typeChars(type));
}

private imported!"dmd.mtype".Type typeidObjectType(
    imported!"dmd.expression".TypeidExp typeid_,
) @trusted {
    if (auto type = cast(imported!"dmd.mtype".Type) typeid_.obj)
        return type;

    if (auto expression = cast(imported!"dmd.expression".Expression) typeid_.obj)
        return expression.type;

    return null;
}

private imported!"dmd.mtype".Type symbolOffsetTypeInfoType(
    imported!"dmd.expression".SymOffExp symbol,
) @trusted {
    auto typeInfo = symbol.var.isTypeInfoDeclaration;
    return typeInfo is null ? null : typeInfo.tinfo;
}

private long stableIdentifierValue(in string value) @safe pure nothrow @nogc {
    long result = 17;
    foreach (immutable char character; value)
        result = result * 31 + cast(long) character;

    return result == 0 ? 1 : result;
}

private string parameterName(imported!"dmd.mtype".Parameter parameter) @trusted {
    return parameter.ident.toString.idup;
}

private ref auto compoundStatements(
    imported!"dmd.statement".CompoundStatement compound,
) @trusted {
    // `isCompoundStatement` returning this node guarantees `statements` is a
    // valid DMD-owned pointer.
    return *compound.statements;
}

private ref auto functionParameters(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    // Caller checked `parameters` for null; DMD owns the array.
    return *function_.parameters;
}

private imported!"dmd.declaration".VarDeclaration[] functionParameterSlice(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    // Caller checked `parameters` for null; DMD owns the array. Slicing
    // avoids `@trusted` at every parameter index access site.
    return (*function_.parameters)[];
}

private imported!"dmd.mtype".Parameter[] functionTypeParameters(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    // `auto` keeps the DMD-owned TypeFunction mutable so its parameter slice
    // matches the mutable DMD APIs used by lowering.
    auto typeFunction = function_.type.toTypeFunction;
    if (typeFunction is null || typeFunction.parameterList.parameters is null)
        return [];

    return (*typeFunction.parameterList.parameters)[];
}

private imported!"dmd.expression".Expression[] callArguments(
    imported!"dmd.expression".CallExp call,
) @trusted {
    // Caller checked `arguments` for null; DMD owns the array. `opSlice`
    // is `@safe`-inferred whereas `opIndex` is not, so returning a slice
    // lets `@safe` callers index without a `@trusted` escape per call site.
    return (*call.arguments)[];
}

private bool callHasNoArguments(
    imported!"dmd.expression".CallExp call,
) @trusted {
    return call.arguments is null || call.arguments.length == 0;
}

private imported!"dmd.expression".Expression immediateFunctionLiteralReturnExpression(
    imported!"dmd.statement".Statement statement,
) @safe {
    if (statement is null)
        return null;

    if (auto scope_ = statement.isScopeStatement)
        return immediateFunctionLiteralReturnExpression(scope_.statement);

    if (auto compound = statement.isCompoundStatement) {
        if (compoundStatements(compound).length != 1)
            return null;

        return immediateFunctionLiteralReturnExpression(
            compoundStatements(compound)[0],
        );
    }

    if (auto return_ = statement.isReturnStatement)
        return return_.exp;

    return null;
}

private ref auto arrayLiteralElements(
    imported!"dmd.expression".ArrayLiteralExp literal,
) @trusted {
    // Caller checked `elements` for null; DMD owns the array.
    return *literal.elements;
}

private ref auto arrayInitializerValues(
    imported!"dmd.init".ArrayInitializer initializer,
) @trusted {
    return initializer.value[];
}

private ref auto structLiteralElements(
    imported!"dmd.expression".StructLiteralExp literal,
) @trusted {
    // Caller checked `elements` for null; DMD owns the array.
    return *literal.elements;
}

private ref auto tupleExpressions(
    imported!"dmd.expression".TupleExp tuple,
) @trusted {
    // Caller checked `exps` for null; DMD owns the array.
    return *tuple.exps;
}

private imported!"dmd.declaration".VarDeclaration structLiteralField(
    imported!"dmd.expression".StructLiteralExp literal,
    in size_t index,
) @trusted {
    if (literal.sd is null || index >= literal.sd.fields.length)
        return null;
    return literal.sd.fields[index];
}

private imported!"dmd.expression".Expression[] assocArrayLiteralKeys(
    imported!"dmd.expression".AssocArrayLiteralExp literal,
) @trusted {
    // DMD guarantees AA literal keys and values are valid, equally sized
    // arrays owned by the frontend.
    return (*literal.keys)[];
}

private imported!"dmd.expression".Expression[] assocArrayLiteralValues(
    imported!"dmd.expression".AssocArrayLiteralExp literal,
) @trusted {
    // DMD guarantees AA literal keys and values are valid, equally sized
    // arrays owned by the frontend.
    return (*literal.values)[];
}

private imported!"dmd.expression".Expression[] newArguments(
    imported!"dmd.expression".NewExp new_,
) @trusted {
    // Caller checked `arguments` for null; DMD owns the array.
    return (*new_.arguments)[];
}

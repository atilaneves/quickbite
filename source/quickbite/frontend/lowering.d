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

    return function_.type.nextOf().ty == TY.Tvoid;
}

struct BodyLowerer {
    import dmd.declaration: VarDeclaration;

    private uint nextTemporary;
    private uint[VarDeclaration] localTemporaries;
    private uint[string] identifierTemporaries;
    private bool[VarDeclaration] lazyParameters;
    private size_t[string] labelInstructionIndices;
    private size_t[][string] pendingGotoInstructionIndices;
    private uint[] dollarArrays;
    public imported!"quickbite.ir.instruction".Instruction[] instructions;
    public bool[] refParameters;
    public bool hasReturn;

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
            foreach (child; compoundStatements(compound)) {
                lowerStatement(child, lowerer);
                if (hasReturn)
                    return;
            }

            return;
        }

        if (auto expressionStatement = statement.isExpStatement) {
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

        if (auto gotoStatement = statement.isGotoStatement) {
            lowerGotoStatement(gotoStatement);
            return;
        }

        if (auto labelStatement = statement.isLabelStatement) {
            lowerLabelStatement(labelStatement, lowerer);
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

        if (statement.isImportStatement !is null)
            return;

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

        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    void lowerForStatement(
        imported!"dmd.statement".ForStatement statement,
        ref Lowerer lowerer,
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

        if (statement._body !is null)
            lowerStatement(statement._body, lowerer);
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
    }

    void lowerDoStatement(
        imported!"dmd.statement".DoStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, JumpIfTrue;

        const loopStart = instructions.length;
        if (statement._body !is null)
            lowerStatement(statement._body, lowerer);

        const condition = lowerTruthValue(lowerExpression(statement.condition, lowerer));
        instructions ~= Instruction(JumpIfTrue(
            condition,
            cast(int) loopStart - cast(int) instructions.length - 1,
        ));
    }

    void lowerGotoStatement(
        imported!"dmd.statement".GotoStatement statement,
    ) @safe {
        import quickbite.ir.instruction: Instruction, Jump;
        import std.conv: text;

        const label = gotoLabel(statement);
        if (label != "__returnLabel")
            throw new Exception(text("Unsupported goto: ", label));

        if (statement.label is null || statement.label.statement is null)
            throw new Exception(text("Unsupported unresolved goto: ", label));

        if (label in labelInstructionIndices)
            throw new Exception(text("Unsupported backward goto: ", label));

        const jumpIndex = instructions.length;
        instructions ~= Instruction(Jump(0));

        if (auto pending = label in pendingGotoInstructionIndices)
            *pending ~= jumpIndex;
        else
            pendingGotoInstructionIndices[label] = [jumpIndex];
    }

    void lowerLabelStatement(
        imported!"dmd.statement".LabelStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        import std.conv: text;

        // AA.remove currently needs a mutable key.
        string label = statementLabel(statement);
        if (label != "__returnLabel")
            throw new Exception(text("Unsupported label: ", label));

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

        lowerStatement(statement.statement, lowerer);
    }

    void assertNoPendingGotos() @safe {
        if (pendingGotoInstructionIndices.length == 0)
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
    }

    // DMD Expression downcast/accessor helpers are not const-qualified.
    uint lowerExpression(
        imported!"dmd.expression".Expression expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Assert_, Call, ConstInt, Instruction,
            Operation, UnaryOp, UnaryOperation;

        if (auto integer = expression.isIntegerExp) {
            const destination = allocateTemporary;
            instructions ~= Instruction(ConstInt(
                destination,
                integerValue(integer),
            ));
            return destination;
        }

        if (expression.isNullExp) {
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
                        if (auto var = variable.var.isVarDeclaration)
                            if ((var in lazyParameters) !is null)
                                return lowerExpression(call.e1, lowerer);

                uint builtinResult;
                if (tryLowerUnresolvedBuiltinCall(call, lowerer, builtinResult))
                    return builtinResult;

                import std.conv: text;

                throw new Exception(text(
                    "Unsupported callee: ",
                    expressionChars(call.e1),
                ));
            }

            if (isArrayEqualityCall(call))
                return lowerArrayEqualityCall(call, lowerer);

            uint builtinResult;
            if (tryLowerAssocArrayBuiltinCall(call, lowerer, builtinResult))
                return builtinResult;

            if (tryLowerAppenderBuiltinCall(call, lowerer, builtinResult))
                return builtinResult;

            if (tryLowerRuntimeBuiltinCall(call, builtinResult))
                return builtinResult;

            if (call.f.isFuncLiteralDeclaration !is null
                && callHasNoArguments(call))
                return lowerImmediateFunctionLiteralCall(call.f, lowerer);

            lowerer.ensureFunctionLowered(call.f);
            // `const` would make the array incompatible with Call.arguments.
            auto arguments = lowerCallArguments(call, lowerer);

            const destination = allocateTemporary;
            instructions ~= Instruction(Call(
                destination,
                lowerer.functionName(call.f),
                arguments,
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

        if (auto length = expression.isArrayLengthExp)
            return lowerArrayLength(length, lowerer);

        if (auto index = expression.isIndexExp)
            return lowerArrayIndex(index, lowerer);

        if (auto dot = expression.isDotVarExp)
            return lowerStructFieldRead(dot, lowerer);

        if (auto assert_ = expression.isAssertExp) {
            const condition = lowerExpression(assert_.e1, lowerer);
            instructions ~= Instruction(Assert_(condition));
            return condition;
        }

        if (auto declaration = expression.isDeclarationExp)
            return lowerDeclaration(declaration, lowerer);

        if (auto blit = expression.isBlitExp)
            return lowerBlitAssignment(blit, lowerer);

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

        if (auto append = expression.isCatElemAssignExp)
            return lowerArrayAppendAssignment(append, lowerer);

        if (auto post = expression.isPostExp) {
            import dmd.tokens: EXP;

            if (post.op == EXP.plusPlus || post.op == EXP.minusMinus)
                return lowerPostIncrement(post, lowerer);
        }

        if (auto pre = expression.isPreExp)
            return lowerPreIncrement(pre);

        if (auto addr = expression.isAddrExp) {
            if (auto var = addr.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (auto target = varDecl in localTemporaries)
                        return *target;
            import std.conv: text;
            throw new Exception(text("Unsupported address-of: ", expressionChars(addr.e1)));
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
        }

        if (auto identifier = expression.isIdentifierExp) {
            if (auto temporary = identifierName(identifier) in identifierTemporaries)
                return *temporary;

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
        import quickbite.ir.instruction: Assert_, Instruction;

        if (expressionChars(call.e1) != "enforceFmt")
            return false;

        enforceCallArgumentCount(call, 1);
        result = lowerTruthValue(lowerExpression(callArguments(call)[0], lowerer));
        instructions ~= Instruction(Assert_(result));
        return true;
    }

    bool tryLowerRuntimeBuiltinCall(
        imported!"dmd.expression".CallExp call,
        ref uint result,
    ) @safe {
        if (functionIdentifier(call.f) != "_d_arraybounds")
            return false;

        import quickbite.ir.instruction: Assert_, ConstInt, Instruction;

        result = allocateTemporary;
        instructions ~= Instruction(ConstInt(result, 0));
        instructions ~= Instruction(Assert_(result));
        return true;
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

        if (name == "_d_aaGetRvalueX" || name == "_d_aaGetY") {
            result = lowerAssocArrayIndexCall(call, lowerer);
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
        import quickbite.ir.instruction: ArrayAppend, Instruction;

        enforceCallArgumentCount(call, 1);
        const array = lowerAppenderArray(call, lowerer);
        const value = lowerExpression(callArguments(call)[0], lowerer);
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
        import quickbite.ir.instruction: ArrayLiteral, Instruction, StructNew,
            StructSet;
        import std.conv: text;

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

    void lowerDefaultStructFields(
        in uint struct_,
        imported!"dmd.mtype".Type type,
    ) @safe {
        import quickbite.ir.instruction: ArrayLiteral, Instruction, StructNew,
            StructSet;

        foreach (field; structFields(type)) {
            uint value;
            if (typeIsDynamicArray(field.type)) {
                value = allocateTemporary;
                instructions ~= Instruction(ArrayLiteral(value, []));
            } else if (typeIsStruct(field.type)) {
                value = allocateTemporary;
                instructions ~= Instruction(StructNew(value));
                lowerDefaultStructFields(value, field.type);
            } else if (typeIsAppender(type) && typePointsToStruct(field.type)) {
                value = allocateTemporary;
                instructions ~= Instruction(StructNew(value));
                lowerDefaultStructFields(value, pointerTarget(field.type));
            } else
                continue;

            instructions ~= Instruction(StructSet(
                struct_,
                declarationName(field),
                value,
            ));
        }
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

        const ifTrue = lowerExpression(expression.e1, lowerer);
        instructions ~= Instruction(Copy(destination, ifTrue));
        const skipFalseJumpIndex = instructions.length;
        instructions ~= Instruction(Jump(0));

        replaceJumpOffset(
            instructions,
            cast(uint) ifFalseJumpIndex,
            cast(int) (instructions.length - ifFalseJumpIndex - 1),
        );

        const ifFalse = lowerExpression(expression.e2, lowerer);
        instructions ~= Instruction(Copy(destination, ifFalse));
        replaceJumpOffset(
            instructions,
            cast(uint) skipFalseJumpIndex,
            cast(int) (instructions.length - skipFalseJumpIndex),
        );
        return destination;
    }

    uint lowerArrayConcatenation(
        imported!"dmd.expression".CatExp expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArrayConcat, Instruction;

        const left = lowerExpression(expression.e1, lowerer);
        const right = lowerExpression(expression.e2, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(ArrayConcat(
            destination,
            left,
            right,
        ));
        return destination;
    }

    uint lowerImmediateFunctionLiteralCall(
        imported!"dmd.func".FuncDeclaration function_,
        ref Lowerer lowerer,
    ) @safe {
        import std.conv: text;

        // DMD expression lowering APIs expect mutable AST node pointers.
        auto expression = immediateFunctionLiteralReturnExpression(function_.fbody);
        if (expression is null)
            throw new Exception(text(
                "Unsupported expression: ",
                function_.ident.toString,
            ));

        return lowerExpression(expression, lowerer);
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

        if (typeIsStruct(variable.type)) {
            import quickbite.ir.instruction: Instruction, StructNew;

            const value = allocateTemporary;
            instructions ~= Instruction(StructNew(value));
            rememberLocalTemporary(variable, value);
            lowerDefaultStructFields(value, variable.type);
            return value;
        }

        if (typeIsDynamicArray(variable.type) && variable._init is null) {
            import quickbite.ir.instruction: ArrayLiteral, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(value, []));
            rememberLocalTemporary(variable, value);
            return value;
        }

        if (variable._init is null || variable._init.isExpInitializer is null) {
            import quickbite.ir.instruction: ConstInt, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(ConstInt(value, 0));
            rememberLocalTemporary(variable, value);
            return value;
        }

        auto initializer = variable._init.isExpInitializer;

        if (auto blit = initializer.exp.isBlitExp) {
            if (typeIsDynamicArray(variable.type) && blit.e2.isNullExp !is null) {
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

        auto construct = initializer.exp.isConstructExp;
        const value = construct !is null
            ? lowerExpression(construct.e2, lowerer)
            : lowerExpression(initializer.exp, lowerer);
        rememberLocalTemporary(variable, value);
        return value;
    }

    uint lowerAssignment(
        imported!"dmd.expression".AssignExp assignment,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Copy, Instruction;
        import std.conv: text;

        if (auto index = assignment.e1.isIndexExp)
            return lowerArrayIndexAssignment(index, assignment.e2, lowerer);

        if (auto dot = assignment.e1.isDotVarExp)
            return lowerStructFieldAssignment(dot, assignment.e2, lowerer);

        if (auto length = assignment.e1.isArrayLengthExp)
            return lowerArrayLengthAssignment(length, assignment.e2, lowerer);

        if (auto pointer = assignment.e1.isPtrExp)
            if (auto call = pointer.e1.isCallExp)
                if (isAssocArrayGetCall(call))
                    return lowerAssocArrayIndexAssignment(
                        call,
                        assignment.e2,
                        lowerer,
                    );

        auto variable = assignment.e1.isVarExp;
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

        auto variable = post.e1.isVarExp;
        if (variable is null)
            throw new Exception(text("Unsupported expression: ", post.op));

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
        import quickbite.ir.instruction: Instruction, StructGet;
        import std.conv: text;

        const struct_ = lowerStructOwner(dot, lowerer);

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        const destination = allocateTemporary;
        instructions ~= Instruction(StructGet(
            destination,
            struct_,
            declarationName(field),
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

        throw new Exception(text("Unsupported expression: ", dot.op));
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
        if (auto nested = assignment.e1.isOrAssignExp)
            return lowerCompoundAssignment(nested, operation, lowerer);
        if (variable is null)
            throw new Exception(text("Unsupported expression: ", assignment.op));

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
        import quickbite.ir.instruction: ArrayAppend, Instruction;
        import std.conv: text;

        if (auto dot = assignment.e1.isDotVarExp) {
            const destination = lowerStructFieldRead(dot, lowerer);
            const value = lowerExpression(assignment.e2, lowerer);
            instructions ~= Instruction(ArrayAppend(
                destination,
                value,
            ));
            return destination;
        }

        auto variable = assignment.e1.isVarExp;
        if (variable is null)
            throw new Exception(text("Unsupported expression: ", assignment.op));

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", assignment.op));

        auto destination = declaration in localTemporaries;
        if (destination is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(assignment.e1)));

        const value = lowerExpression(assignment.e2, lowerer);
        instructions ~= Instruction(ArrayAppend(
            *destination,
            value,
        ));
        return *destination;
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
            Instruction;

        const array = lowerExpression(index.e1, lowerer);
        const indexValue = lowerExpression(index.e2, lowerer);
        const destination = allocateTemporary;
        if (typeIsAssociativeArray(index.e1.type)) {
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

    uint lowerCast(
        imported!"dmd.expression".CastExp cast_,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: CastInt, Instruction;

        // Pointer casts are no-ops in the VM: the "pointer" is just a temp
        // index, so reinterpreting its integer type changes nothing.
        if (typeIsPointer(cast_.to))
            return lowerExpression(cast_.e1, lowerer);

        if (typeIsDynamicArray(cast_.to) && typeIsDynamicArray(cast_.e1.type))
            return lowerExpression(cast_.e1, lowerer);

        if (typeIsAssociativeArray(cast_.to))
            return lowerExpression(cast_.e1, lowerer);

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
        import quickbite.ir.instruction: Instruction, ReturnValue, ReturnVoid;

        if (statement.exp is null) {
            instructions ~= Instruction(ReturnVoid.init);
            return;
        }
        instructions ~= Instruction(ReturnValue(lowerExpression(statement.exp, lowerer)));
    }

    uint lowerParameters(imported!"dmd.func".FuncDeclaration function_) @safe {
        uint numParameters;
        if (function_.vthis !is null) {
            const temporary = allocateTemporary;
            localTemporaries[function_.vthis] = temporary;
            identifierTemporaries[declarationName(function_.vthis)] = temporary;
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
            identifierTemporaries[declarationName(parameter)] = temporary;
            if (parameterIsLazy(parameter))
                lazyParameters[parameter] = true;
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
            identifierTemporaries[parameterName(parameter)] = temporary;
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
        uint[] arguments;
        if (call.f.vthis !is null)
            arguments ~= lowerCallReceiver(call, lowerer);

        if (call.arguments is null)
            return arguments;

        // Pulled in parallel so we can detect non-ref struct parameters and
        // copy by value at the call site, matching D semantics. `auto`
        // because `parameterIsRef` takes a mutable `VarDeclaration`.
        auto parameters = call.f.parameters !is null
            ? functionParameterSlice(call.f)
            : null;
        foreach (i, argument; callArguments(call)) {
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

    uint lowerCallArgument(
        imported!"dmd.expression".Expression argument,
        imported!"dmd.declaration".VarDeclaration parameter,
        ref Lowerer lowerer,
    ) @safe {
        if (parameter !is null && parameterIsLazy(parameter))
            if (auto literal = argument.isFuncExp)
                return lowerImmediateFunctionLiteralCall(literal.fd, lowerer);

        return lowerExpression(argument, lowerer);
    }

    uint copyStructByValue(
        imported!"dmd.mtype".Type type,
        in uint source,
    ) @safe {
        import quickbite.ir.instruction: ArrayCopy, Instruction, StructGet,
            StructNew, StructSet;

        const destination = allocateTemporary;
        instructions ~= Instruction(StructNew(destination));
        foreach (field; structFields(type)) {
            const fieldValue = allocateTemporary;
            const name = declarationName(field);
            instructions ~= Instruction(StructGet(fieldValue, source, name));
            if (typeIsDynamicArray(field.type)) {
                const copied = allocateTemporary;
                instructions ~= Instruction(ArrayCopy(copied, fieldValue));
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

private bool isArrayEqualityCall(imported!"dmd.expression".CallExp call) @trusted {
    import dmd.id: Id;

    return call.f.ident == Id.__equals;
}

private bool isAssocArrayGetCall(
    imported!"dmd.expression".CallExp call,
) @trusted {
    return call.f !is null && functionIdentifier(call.f) == "_d_aaGetY";
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

    throw new Exception(text("Unsupported cast to: ", typeChars(type)));
}

private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return fromStringz(type.toChars()).idup;
}

private bool typeIsPointer(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.isTypePointer !is null;
}

private bool typeIsAppender(imported!"dmd.mtype".Type type) @trusted {
    import std.algorithm.searching: canFind;

    return type !is null && typeChars(type).canFind("Appender!");
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

private bool typePointsToStruct(imported!"dmd.mtype".Type type) @trusted {
    return type !is null &&
        type.isTypePointer !is null &&
        type.nextOf.isTypeStruct !is null;
}

private imported!"dmd.mtype".Type pointerTarget(
    imported!"dmd.mtype".Type type,
) @trusted {
    return type.nextOf;
}

private bool typeIsStruct(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.isTypeStruct !is null;
}

private bool typeIsDynamicArray(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.toBasetype.isTypeDArray !is null;
}

private bool typeIsAssociativeArray(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.toBasetype.isTypeAArray !is null;
}

private ref auto structFields(
    imported!"dmd.mtype".Type type,
) @trusted {
    return type.toBasetype.isTypeStruct.sym.fields;
}

private string declarationName(
    imported!"dmd.declaration".VarDeclaration declaration,
) @trusted {
    return declaration.ident.toString.idup;
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

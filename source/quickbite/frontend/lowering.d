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

        foreach (member; moduleMembers(sourceModule)) {
            if (auto unitTest = member.isUnitTestDeclaration)
                loweredModule.tests ~= lowerTest(unitTest);
        }

        return loweredModule;
    }

    // DMD AST query helpers used below are not const-qualified.
    imported!"quickbite.ir.test".Test lowerTest(
        imported!"dmd.declaration".UnitTestDeclaration unitTest,
    ) @safe {
        imported!"quickbite.ir.test".Test result;
        BodyLowerer builder;

        builder.lowerStatement(unitTest.fbody, this);
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

        loweredFunctions[name] = true;

        BodyLowerer builder;
        const numParameters = builder.lowerParameters(function_);
        builder.lowerStatement(function_.fbody, this);
        const hasReturnValue = !functionReturnsVoid(function_);

        if (hasReturnValue && !builder.hasReturn)
            throw new Exception("Unsupported function body.");

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

// Caller has checked `members` for null; this helper only narrows the
// unchecked DMD pointer dereference.
private ref auto moduleMembers(imported!"dmd.dmodule".Module module_) @trusted {
    return *module_.members;
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
    private uint[] dollarArrays;
    public imported!"quickbite.ir.instruction".Instruction[] instructions;
    public bool[] refParameters;
    public bool hasReturn;

    // DMD Statement downcast helpers are not const-qualified.
    void lowerStatement(
        imported!"dmd.statement".Statement statement,
        ref Lowerer lowerer,
    ) @safe {
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

        import std.conv: text;

        throw new Exception(text("Unsupported statement: ", statement.stmt));
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

        if (expression.isDollarExp)
            return lowerDollar;

        if (auto literal = expression.isArrayLiteralExp)
            return lowerArrayLiteral(literal, lowerer);

        if (auto slice = expression.isSliceExp)
            return lowerArraySlice(slice, lowerer);

        if (auto call = expression.isCallExp) {
            if (call.f is null)
                throw new Exception("Unsupported callee.");

            if (isArrayEqualityCall(call))
                return lowerArrayEqualityCall(call, lowerer);

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

        if (auto logical = expression.isLogicalExp) {
            if (logical.op == EXP.andAnd)
                return lowerLogicalAnd(logical, lowerer);

            if (logical.op == EXP.orOr)
                return lowerLogicalOr(logical, lowerer);
        }

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

        if (auto assignment = expression.isAssignExp)
            return lowerAssignment(assignment, lowerer);

        if (auto orAssign = expression.isOrAssignExp)
            return lowerCompoundAssignment(
                orAssign,
                Operation.bitwiseOr,
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

        if (auto append = expression.isCatElemAssignExp)
            return lowerArrayAppendAssignment(append, lowerer);

        if (auto post = expression.isPostExp) {
            import dmd.tokens: EXP;

            if (post.op == EXP.plusPlus)
                return lowerPostIncrement(post, lowerer);
        }

        if (auto variable = expression.isVarExp) {
            if (auto var = variable.var.isVarDeclaration) {
                if (auto temporary = var in localTemporaries)
                    return *temporary;
            }

            if (expressionChars(expression) == "$")
                return lowerDollar;

            import std.conv: text;

            throw new Exception(text("Unsupported expression: ", expressionChars(expression)));
        }

        import std.conv: text;

        throw new Exception(text("Unsupported expression: ", expression.op));
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
            cast(uint) (instructions.length - jumpIndex - 1),
        );
        return destination;
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
            cast(uint) (instructions.length - jumpIndex - 1),
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
        if (variable is null && declaration.declaration.isAliasDeclaration !is null) {
            import quickbite.ir.instruction: ConstInt, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(ConstInt(value, 0));
            return value;
        }

        if (variable is null)
            throw new Exception(text(
                "Unsupported declaration: ",
                declarationKind(declaration.declaration),
            ));

        if (typeIsStruct(variable.type)) {
            import quickbite.ir.instruction: ArrayLiteral, Instruction, StructNew,
                StructSet;

            const value = allocateTemporary;
            instructions ~= Instruction(StructNew(value));
            localTemporaries[variable] = value;
            foreach (field; structFields(variable.type)) {
                if (!typeIsDynamicArray(field.type))
                    continue;

                const fieldValue = allocateTemporary;
                instructions ~= Instruction(ArrayLiteral(fieldValue, []));
                instructions ~= Instruction(StructSet(
                    value,
                    declarationName(field),
                    fieldValue,
                ));
            }
            return value;
        }

        if (typeIsDynamicArray(variable.type) && variable._init is null) {
            import quickbite.ir.instruction: ArrayLiteral, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(value, []));
            localTemporaries[variable] = value;
            return value;
        }

        if (variable._init is null)
            throw new Exception(text("Unsupported expression: ", declaration.op));

        auto initializer = variable._init.isExpInitializer;
        if (initializer is null)
            throw new Exception(text("Unsupported expression: ", declaration.op));

        if (auto blit = initializer.exp.isBlitExp) {
            if (!typeIsDynamicArray(variable.type) || blit.e2.isNullExp is null)
                throw new Exception(text("Unsupported expression: ", declaration.op));

            import quickbite.ir.instruction: ArrayLiteral, Instruction;

            const value = allocateTemporary;
            instructions ~= Instruction(ArrayLiteral(value, []));
            localTemporaries[variable] = value;
            return value;
        }

        auto construct = initializer.exp.isConstructExp;
        if (construct is null && initializer.exp.isIntegerExp !is null) {
            const value = lowerExpression(initializer.exp, lowerer);
            localTemporaries[variable] = value;
            return value;
        }

        if (construct is null)
            throw new Exception(text("Unsupported expression: ", declaration.op));

        const value = lowerExpression(construct.e2, lowerer);
        localTemporaries[variable] = value;
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

        auto variable = assignment.e1.isVarExp;
        if (variable is null)
            throw new Exception(text("Unsupported expression: ", assignment.op));

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

    uint lowerPostIncrement(
        imported!"dmd.expression".PostExp post,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: BinaryOp, ConstInt, Copy, Instruction;
        import std.conv: text;

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
            imported!"quickbite.ir.instruction".Operation.add,
        ));
        instructions ~= Instruction(Copy(
            *destination,
            incremented,
        ));
        return result;
    }

    uint lowerArrayIndexAssignment(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: ArraySet, Instruction;

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

    uint lowerStructFieldAssignment(
        imported!"dmd.expression".DotVarExp dot,
        imported!"dmd.expression".Expression sourceExpression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, StructSet;
        import std.conv: text;

        auto owner = dot.e1.isVarExp;
        auto this_ = dot.e1.isThisExp;
        if (owner is null && this_ is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        auto declaration = owner !is null
            ? owner.var.isVarDeclaration
            : this_.var;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        auto struct_ = declaration in localTemporaries;
        if (struct_ is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(dot.e1)));

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        const source = lowerExpression(sourceExpression, lowerer);
        instructions ~= Instruction(StructSet(
            *struct_,
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

        auto owner = dot.e1.isVarExp;
        auto this_ = dot.e1.isThisExp;
        if (owner is null && this_ is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        auto declaration = owner !is null
            ? owner.var.isVarDeclaration
            : this_.var;
        if (declaration is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        auto struct_ = declaration in localTemporaries;
        if (struct_ is null)
            throw new Exception(text("Unsupported expression: ", expressionChars(dot.e1)));

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception(text("Unsupported expression: ", dot.op));

        const destination = allocateTemporary;
        instructions ~= Instruction(StructGet(
            destination,
            *struct_,
            declarationName(field),
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
        if (auto cast_ = assignment.e1.isCastExp)
            variable = cast_.e1.isVarExp;
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
        import quickbite.ir.instruction: ArrayLength, Instruction;

        const array = lowerExpression(length.e1, lowerer);
        const destination = allocateTemporary;
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
        import quickbite.ir.instruction: ArrayIndex, Instruction;

        const array = lowerExpression(index.e1, lowerer);
        const indexValue = lowerExpression(index.e2, lowerer);
        const destination = allocateTemporary;
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
        import quickbite.ir.instruction: Instruction, JumpIfFalse;

        const condition = lowerTruthValue(lowerExpression(statement.condition, lowerer));
        const ifFalseJumpIndex = instructions.length;
        instructions ~= Instruction(JumpIfFalse(condition, 0));
        const ifTrueReturns = lowerReturnBranch(statement.ifbody, lowerer);

        if (statement.elsebody is null) {
            replaceJumpOffset(
                instructions,
                cast(uint) ifFalseJumpIndex,
                cast(uint) (instructions.length - ifFalseJumpIndex - 1),
            );
            hasReturn = false;
            return;
        }

        replaceJumpOffset(
            instructions,
            cast(uint) ifFalseJumpIndex,
            cast(uint) (instructions.length - ifFalseJumpIndex - 1),
        );
        const ifFalseReturns = lowerReturnBranch(statement.elsebody, lowerer);
        hasReturn = ifTrueReturns && ifFalseReturns;
    }

    bool lowerReturnBranch(
        imported!"dmd.statement".Statement statement,
        ref Lowerer lowerer,
    ) @safe {
        const previousHasReturn = hasReturn;
        hasReturn = false;
        lowerStatement(statement, lowerer);
        const branchHasReturn = hasReturn;
        hasReturn = previousHasReturn;

        if (!branchHasReturn)
            throw new Exception("Unsupported if-branch: expected return");

        return branchHasReturn;
    }

    void lowerReturnStatement(
        imported!"dmd.statement".ReturnStatement statement,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction, ReturnValue;

        instructions ~= Instruction(ReturnValue(lowerExpression(statement.exp, lowerer)));
    }

    uint lowerParameters(imported!"dmd.func".FuncDeclaration function_) @safe {
        uint numParameters;
        if (function_.vthis !is null) {
            localTemporaries[function_.vthis] = allocateTemporary;
            refParameters ~= true;
            ++numParameters;
        }

        if (function_.parameters is null)
            return numParameters;

        foreach (parameter; functionParameters(function_)) {
            if (parameterHasUnsupportedStorage(parameter))
                throw new Exception("Unsupported function parameters.");

            localTemporaries[parameter] = allocateTemporary;
            refParameters ~= parameterIsRef(parameter);
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
            STC.lazy_ |
            STC.variadic |
            STC.alias_ |
            STC.auto_;
        return (parameter.storage_class & unsupported) != STC.none;
    }

    bool parameterIsRef(imported!"dmd.declaration".VarDeclaration parameter) @safe {
        import dmd.astenums: STC;

        return (parameter.storage_class & STC.ref_) != STC.none;
    }

    uint[] lowerCallArguments(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        uint[] arguments;
        if (call.f.vthis !is null)
            arguments ~= lowerCallReceiver(call, lowerer);

        if (call.arguments !is null)
            foreach (argument; callArguments(call))
                arguments ~= lowerExpression(argument, lowerer);

        return arguments;
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

        throw new Exception(text("Unsupported expression: ", call.e1.op));
    }

    uint allocateTemporary() @safe pure nothrow @nogc {
        const result = nextTemporary;
        ++nextTemporary;
        return result;
    }
}

private long integerValue(imported!"dmd.expression".IntegerExp integer) @trusted {
    return integer.getInteger();
}

private void replaceJumpOffset(
    ref imported!"quickbite.ir.instruction".Instruction[] instructions,
    in uint index,
    in uint offset,
) @safe {
    import quickbite.ir.instruction: JumpIfFalse, JumpIfTrue;
    import std.sumtype: match;

    instructions[index].match!(
        (ref JumpIfFalse instruction) {
            instruction.offset = offset;
        },
        (ref JumpIfTrue instruction) {
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

    const basetype = type.toBasetype;

    if (basetype.ty == TY.Tint8)
        return IntegerType.i8;

    if (basetype.ty == TY.Tuns8)
        return IntegerType.u8;

    if (basetype.ty == TY.Tint16)
        return IntegerType.i16;

    if (basetype.ty == TY.Tuns16)
        return IntegerType.u16;

    if (basetype.ty == TY.Tint32)
        return IntegerType.i32;

    if (basetype.ty == TY.Tuns32)
        return IntegerType.u32;

    if (basetype.ty == TY.Tint64)
        return IntegerType.i64;

    if (basetype.ty == TY.Tuns64)
        return IntegerType.u64;

    throw new Exception("Unsupported cast.");
}

private bool typeIsStruct(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.isTypeStruct !is null;
}

private bool typeIsDynamicArray(imported!"dmd.mtype".Type type) @trusted {
    return type !is null && type.isTypeDArray !is null;
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

private ref auto callArguments(imported!"dmd.expression".CallExp call) @trusted {
    // Caller checked `arguments` for null; DMD owns the array.
    return *call.arguments;
}

private ref auto arrayLiteralElements(
    imported!"dmd.expression".ArrayLiteralExp literal,
) @trusted {
    // Caller checked `elements` for null; DMD owns the array.
    return *literal.elements;
}

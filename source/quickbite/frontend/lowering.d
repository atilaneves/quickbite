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
            if (auto unitTest = member.isUnitTestDeclaration())
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

        if (!builder.hasReturn)
            throw new Exception("Unsupported function body.");

        Function result;
        result.name = name;
        result.instructions = builder.instructions.dup;
        result.returnValue = builder.returnValue;
        result.numParameters = numParameters;
        result.numTemporaries = builder.nextTemporary;
        loweredModule.functions ~= result;
    }

    // DMD Identifier.toString is not const-callable through FuncDeclaration.
    string functionName(imported!"dmd.func".FuncDeclaration function_) @safe {
        return function_.ident.toString().idup;
    }
}

// Caller has checked `members` for null; this helper only narrows the
// unchecked DMD pointer dereference.
private ref auto moduleMembers(imported!"dmd.dmodule".Module module_) @trusted {
    return *module_.members;
}

struct BodyLowerer {
    import dmd.declaration: VarDeclaration;

    private uint nextTemporary;
    private uint[VarDeclaration] localTemporaries;
    public imported!"quickbite.ir.instruction".Instruction[] instructions;
    public bool hasReturn;
    public uint returnValue;

    // DMD Statement downcast helpers are not const-qualified.
    void lowerStatement(
        imported!"dmd.statement".Statement statement,
        ref Lowerer lowerer,
    ) @safe {
        if (auto compound = statement.isCompoundStatement()) {
            foreach (child; compoundStatements(compound)) {
                lowerStatement(child, lowerer);
                if (hasReturn)
                    return;
            }

            return;
        }

        if (auto expressionStatement = statement.isExpStatement()) {
            lowerExpression(expressionStatement.exp, lowerer);
            return;
        }

        if (auto returnStatement = statement.isReturnStatement()) {
            returnValue = lowerExpression(returnStatement.exp, lowerer);
            hasReturn = true;
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
        import quickbite.ir.instruction: Add, Assert_, Call, ConstInt, Equal,
            Divide, Instruction, LessOrEqual, LessThan, Modulo, Multiply,
            Subtract;

        if (auto integer = expression.isIntegerExp()) {
            const destination = allocateTemporary();
            instructions ~= Instruction(ConstInt(
                destination,
                cast(int) integerValue(integer),
            ));
            return destination;
        }

        if (auto call = expression.isCallExp()) {
            auto arguments = lowerCallArguments(call, lowerer);

            if (call.f is null)
                throw new Exception("Unsupported callee.");

            lowerer.ensureFunctionLowered(call.f);

            const destination = allocateTemporary();
            instructions ~= Instruction(Call(
                destination,
                lowerer.functionName(call.f),
                arguments,
            ));
            return destination;
        }

        if (auto equal = expression.isEqualExp) {
            import dmd.tokens: EXP;

            if (equal.op != EXP.equal) {
                import std.conv: text;

                throw new Exception(text("Unsupported expression: ", equal.op));
            }

            return lowerBinaryExpression!Equal(equal, lowerer);
        }

        import dmd.tokens: EXP;

        if (expression.op == EXP.lessThan)
            return lowerBinaryExpression!LessThan(castCmpExpression(expression), lowerer);

        if (expression.op == EXP.lessOrEqual)
            return lowerBinaryExpression!LessOrEqual(castCmpExpression(expression), lowerer);

        if (auto add = expression.isAddExp)
            return lowerBinaryExpression!Add(add, lowerer);

        if (auto subtract = expression.isMinExp)
            return lowerBinaryExpression!Subtract(subtract, lowerer);

        if (auto multiply = expression.isMulExp)
            return lowerBinaryExpression!Multiply(multiply, lowerer);

        if (auto divide = expression.isDivExp)
            return lowerBinaryExpression!Divide(divide, lowerer);

        if (auto modulo = expression.isModExp)
            return lowerBinaryExpression!Modulo(modulo, lowerer);

        if (auto assert_ = expression.isAssertExp()) {
            const condition = lowerExpression(assert_.e1, lowerer);
            instructions ~= Instruction(Assert_(condition));
            return condition;
        }

        if (auto declaration = expression.isDeclarationExp())
            return lowerDeclaration(declaration, lowerer);

        if (auto variable = expression.isVarExp()) {
            if (auto var = variable.var.isVarDeclaration()) {
                if (auto temporary = var in localTemporaries)
                    return *temporary;
            }

            import std.conv: text;

            throw new Exception(text("Unsupported expression: ", expressionChars(expression)));
        }

        import std.conv: text;

        throw new Exception(text("Unsupported expression: ", expression.op));
    }

    uint lowerBinaryExpression(InstructionType, Expression)(
        Expression expression,
        ref Lowerer lowerer,
    ) @safe {
        import quickbite.ir.instruction: Instruction;

        const left = lowerExpression(expression.e1, lowerer);
        const right = lowerExpression(expression.e2, lowerer);
        const destination = allocateTemporary;
        instructions ~= Instruction(InstructionType(
            destination,
            left,
            right,
        ));
        return destination;
    }

    uint lowerDeclaration(
        imported!"dmd.expression".DeclarationExp declaration,
        ref Lowerer lowerer,
    ) @safe {
        import std.conv: text;

        auto variable = declaration.declaration.isVarDeclaration();
        if (variable is null)
            throw new Exception(text("Unsupported expression: ", declaration.op));

        if (variable._init is null)
            throw new Exception(text("Unsupported expression: ", declaration.op));

        auto initializer = variable._init.isExpInitializer();
        if (initializer is null)
            throw new Exception(text("Unsupported expression: ", declaration.op));

        auto construct = initializer.exp.isConstructExp();
        if (construct is null)
            throw new Exception(text("Unsupported expression: ", declaration.op));

        const value = lowerExpression(construct.e2, lowerer);
        localTemporaries[variable] = value;
        return value;
    }

    uint lowerParameters(imported!"dmd.func".FuncDeclaration function_) @safe {
        if (function_.parameters is null)
            return 0;

        if (function_.parameters.length > 1)
            throw new Exception("Unsupported function parameters.");

        foreach (parameter; functionParameters(function_))
            localTemporaries[parameter] = allocateTemporary;

        return nextTemporary;
    }

    uint[] lowerCallArguments(
        imported!"dmd.expression".CallExp call,
        ref Lowerer lowerer,
    ) @safe {
        if (call.arguments is null)
            return [];

        if (call.arguments.length > 1)
            throw new Exception("Unsupported call.");

        uint[] arguments;
        foreach (argument; callArguments(call))
            arguments ~= lowerExpression(argument, lowerer);

        return arguments;
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

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import std.string: fromStringz;

    return fromStringz(expression.toChars()).idup;
}

private imported!"dmd.expression".CmpExp castCmpExpression(
    imported!"dmd.expression".Expression expression,
) @trusted {
    return cast(imported!"dmd.expression".CmpExp) expression;
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

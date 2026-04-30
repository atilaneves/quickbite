module quickbite.frontend.lowering;

private:

public imported!"quickbite.ir.module_".Module lowerModule(
    imported!"dmd.dmodule".Module module_,
) @safe {
    return Lowerer(module_).lower();
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
        builder.lowerStatement(function_.fbody, this);

        if (!builder.hasReturn)
            throw new Exception("Unsupported function body.");

        Function result;
        result.name = name;
        result.instructions = builder.instructions.dup;
        result.returnValue = builder.returnValue;
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
    private uint nextTemporary;
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
        import quickbite.ir.instruction: Assert_, Call, ConstInt, Equal, Instruction;

        if (auto integer = expression.isIntegerExp()) {
            const destination = allocateTemporary();
            instructions ~= Instruction(ConstInt(
                destination,
                cast(int) integerValue(integer),
            ));
            return destination;
        }

        if (auto call = expression.isCallExp()) {
            if (call.arguments !is null && call.arguments.length != 0)
                throw new Exception("Unsupported call.");

            if (call.f is null)
                throw new Exception("Unsupported callee.");

            lowerer.ensureFunctionLowered(call.f);

            const destination = allocateTemporary();
            instructions ~= Instruction(Call(
                destination,
                lowerer.functionName(call.f),
            ));
            return destination;
        }

        if (auto equal = expression.isEqualExp()) {
            const left = lowerExpression(equal.e1, lowerer);
            const right = lowerExpression(equal.e2, lowerer);
            const destination = allocateTemporary();
            instructions ~= Instruction(Equal(
                destination,
                left,
                right,
            ));
            return destination;
        }

        if (auto assert_ = expression.isAssertExp()) {
            const condition = lowerExpression(assert_.e1, lowerer);
            instructions ~= Instruction(Assert_(condition));
            return condition;
        }

        import std.conv: text;

        throw new Exception(text("Unsupported expression: ", expression.op));
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

private ref auto compoundStatements(
    imported!"dmd.statement".CompoundStatement compound,
) @trusted {
    // `isCompoundStatement` returning this node guarantees `statements` is a
    // valid DMD-owned pointer.
    return *compound.statements;
}

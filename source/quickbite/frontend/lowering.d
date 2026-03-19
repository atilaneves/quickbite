module quickbite.frontend.lowering;

private:

public imported!"quickbite.ir.module_".Module lowerModule(
    imported!"dmd.dmodule".Module module_,
)
{
    return Lowerer(module_).lower();
}

struct Lowerer
{
    private imported!"dmd.dmodule".Module sourceModule;
    private imported!"quickbite.ir.module_".Module loweredModule;
    private bool[string] loweredFunctions;

    this(imported!"dmd.dmodule".Module module_)
    {
        sourceModule = module_;
    }

    imported!"quickbite.ir.module_".Module lower()
    {
        if (sourceModule.members is null)
            return loweredModule;

        foreach (member; *sourceModule.members)
        {
            if (auto unitTest = member.isUnitTestDeclaration())
                loweredModule.tests ~= lowerTest(unitTest);
        }

        return loweredModule;
    }

    imported!"quickbite.ir.test".Test lowerTest(
        imported!"dmd.declaration".UnitTestDeclaration unitTest,
    )
    {
        imported!"quickbite.ir.test".Test result;

        result.entry = lowerTestBlock(unitTest.fbody);
        return result;
    }

    imported!"quickbite.ir.block".Block lowerTestBlock(
        imported!"dmd.statement".Statement statement,
    )
    {
        import quickbite.ir.block: Terminator, TerminatorKind;

        auto builder = BodyLowerer(&this);
        builder.lowerStatement(statement);

        imported!"quickbite.ir.block".Block result;
        result.instructions = builder.instructions.dup;
        result.terminator = Terminator(
            TerminatorKind.returnVoid,
            0,
        );
        return result;
    }

    void ensureFunctionLowered(imported!"dmd.func".FuncDeclaration function_)
    {
        import quickbite.ir.block: Terminator, TerminatorKind;
        import quickbite.ir.function_: Function;
        import quickbite.ir.type: Kind, Type;

        const name = functionName(function_);
        if (name in loweredFunctions)
            return;

        loweredFunctions[name] = true;

        auto builder = BodyLowerer(&this);
        builder.lowerStatement(function_.fbody);

        if (!builder.hasReturn)
            throw new Exception("Unsupported function body.");

        Function result;
        result.name = name;
        result.returnType = Type(Kind.int32);
        result.entry.instructions = builder.instructions.dup;
        result.entry.terminator = Terminator(
            TerminatorKind.return_,
            builder.returnValue,
        );
        loweredModule.functions ~= result;
    }

    string functionName(imported!"dmd.func".FuncDeclaration function_)
    {
        return function_.ident.toString().idup;
    }
}

struct BodyLowerer
{
    private Lowerer* lowerer;
    private uint nextTemporary;
    public imported!"quickbite.ir.instruction".Instruction[] instructions;
    public bool hasReturn;
    public uint returnValue;

    this(Lowerer* lowerer_)
    {
        lowerer = lowerer_;
    }

    void lowerStatement(imported!"dmd.statement".Statement statement)
    {
        if (auto compound = statement.isCompoundStatement())
        {
            foreach (child; *compound.statements)
            {
                lowerStatement(child);
                if (hasReturn)
                    return;
            }

            return;
        }

        if (auto expressionStatement = statement.isExpStatement())
        {
            lowerExpression(expressionStatement.exp);
            return;
        }

        if (auto returnStatement = statement.isReturnStatement())
        {
            returnValue = lowerExpression(returnStatement.exp);
            hasReturn = true;
            return;
        }

        throw new Exception("Unsupported statement.");
    }

    uint lowerExpression(imported!"dmd.expression".Expression expression)
    {
        import quickbite.ir.instruction: Instruction, Kind;

        if (auto integer = expression.isIntegerExp())
        {
            const destination = allocateTemporary();

            Instruction instruction;
            instruction.kind = Kind.constInt;
            instruction.destination = destination;
            instruction.value = cast(int) integer.getInteger();
            instructions ~= instruction;
            return destination;
        }

        if (auto call = expression.isCallExp())
        {
            if (call.arguments !is null && call.arguments.length != 0)
                throw new Exception("Unsupported call.");

            if (call.f is null)
                throw new Exception("Unsupported callee.");

            lowerer.ensureFunctionLowered(call.f);

            const destination = allocateTemporary();

            Instruction instruction;
            instruction.kind = Kind.call;
            instruction.destination = destination;
            instruction.calleeName = lowerer.functionName(call.f);
            instructions ~= instruction;
            return destination;
        }

        if (auto equal = expression.isEqualExp())
        {
            const left = lowerExpression(equal.e1);
            const right = lowerExpression(equal.e2);
            const destination = allocateTemporary();

            Instruction instruction;
            instruction.kind = Kind.equal;
            instruction.destination = destination;
            instruction.left = left;
            instruction.right = right;
            instructions ~= instruction;
            return destination;
        }

        if (auto assert_ = expression.isAssertExp())
        {
            const condition = lowerExpression(assert_.e1);

            Instruction instruction;
            instruction.kind = Kind.assert_;
            instruction.condition = condition;
            instructions ~= instruction;
            return condition;
        }

        throw new Exception("Unsupported expression.");
    }

    uint allocateTemporary()
    {
        const result = nextTemporary;
        ++nextTemporary;
        return result;
    }
}

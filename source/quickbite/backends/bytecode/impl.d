module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".Backend {
    import quickbite.lang: Value;
    import quickbite.frontend.repl: ReplCell;
    import quickbite.backends: TestSummary;
    import dmd.dmodule: Module;

    public override Value eval(in string expr) {
        assert(0);
    }

    public override Value evalRepl(in ReplCell cell,
    )
    {
        assert(0);
    }

    public override void runParsedTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            auto bytecode = compileBytecode(unitTest);
            bytecode.execute;
        });
    }

    public override TestSummary runParsedTestSummary(Module module_) {
        assert(0);
    }

}

private enum OpCode : ubyte {
    pushLong,
    loadLocal,
    storeLocal,
    call,
    add,
    equal,
    assertEqual,
    assertTrue,
    ret,
    halt,
}

private struct Instruction {
    public OpCode op;
    public long operand;
}

private struct BytecodeModule {
    import dmd.func: FuncDeclaration;

    public Instruction[] code;
    public FuncDeclaration[] functions;
    public size_t[FuncDeclaration] functionIndexes;
    public size_t[FuncDeclaration] functionEntries;
    public size_t[imported!"dmd.declaration".VarDeclaration] localIndexes;
    public size_t localCount;
}

private BytecodeModule compileBytecode(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    Compiler compiler;
    compiler.compileUnitTest(unitTest);
    return compiler.module_;
}

private struct Compiler {
    private BytecodeModule module_;

    private void compileUnitTest(
        imported!"dmd.declaration".UnitTestDeclaration unitTest,
    ) {
        compileStatement(unitTest.fbody);
        module_.code ~= Instruction(OpCode.halt);

        for (size_t i = 0; i < module_.functions.length; ++i) {
            auto function_ = module_.functions[i];
            module_.functionEntries[function_] = module_.code.length;
            compileStatement(function_.fbody);
            module_.code ~= Instruction(OpCode.ret);
        }
    }

    private void compileStatement(imported!"dmd.statement".Statement statement) {
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

        if (auto expression = statement.isExpStatement) {
            compileExpression(expression.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            compileExpression(return_.exp);
            module_.code ~= Instruction(OpCode.ret);
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported bytecode statement: ", statement.stmt));
    }

    private void compileExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp) {
            module_.code ~= Instruction(OpCode.pushLong, integerValue(integer));
            return;
        }

        if (auto assert_ = expression.isAssertExp) {
            auto equal = assert_.e1.isEqualExp;
            if (equal is null) {
                compileExpression(assert_.e1);
                module_.code ~= Instruction(OpCode.assertTrue);
                return;
            }

            compileExpression(equal.e1);
            compileExpression(equal.e2);
            module_.code ~= Instruction(OpCode.assertEqual);
            return;
        }

        if (auto equal = expression.isEqualExp) {
            compileExpression(equal.e1);
            compileExpression(equal.e2);
            module_.code ~= Instruction(OpCode.equal);
            return;
        }

        if (auto call = expression.isCallExp) {
            if (call.arguments !is null && call.arguments.length != 0)
                throw new Exception("Unsupported bytecode call arguments.");

            module_.code ~= Instruction(OpCode.call, functionIndex(callFunction(call)));
            return;
        }

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported bytecode variable.");

            module_.code ~= Instruction(OpCode.loadLocal, localIndex(variable));
            return;
        }

        import dmd.tokens: EXP;
        if (auto declaration = expression.isDeclarationExp) {
            compileDeclaration(declaration);
            return;
        }

        if (expression.op == EXP.comma) {
            auto binary = expression.isBinExp;
            compileExpression(binary.e1);
            compileExpression(binary.e2);
            return;
        }

        if (expression.op == EXP.add) {
            auto binary = expression.isBinExp;
            compileExpression(binary.e1);
            compileExpression(binary.e2);
            module_.code ~= Instruction(OpCode.add);
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported bytecode expression: ", expression.op));
    }

    private void compileDeclaration(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return;

        if (variable._init is null || variable._init.isExpInitializer is null)
            throw new Exception("Unsupported bytecode declaration.");

        compileExpression(initializerExpression(variable._init.isExpInitializer.exp));
        module_.code ~= Instruction(OpCode.storeLocal, localIndex(variable));
    }

    private long functionIndex(imported!"dmd.func".FuncDeclaration function_) {
        if (auto existing = function_ in module_.functionIndexes)
            return cast(long) *existing;

        const index = module_.functions.length;
        module_.functions ~= function_;
        module_.functionIndexes[function_] = index;
        return cast(long) index;
    }

    private long localIndex(imported!"dmd.declaration".VarDeclaration variable) {
        if (auto existing = variable in module_.localIndexes)
            return cast(long) *existing;

        const index = module_.localCount;
        ++module_.localCount;
        module_.localIndexes[variable] = index;
        return cast(long) index;
    }

    private imported!"dmd.func".FuncDeclaration callFunction(
        imported!"dmd.expression".CallExp call,
    ) {
        if (call.f !is null)
            return call.f;

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return function_;

        throw new Exception("Unsupported bytecode call target.");
    }
}

private imported!"dmd.expression".Expression initializerExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (auto assign = expression.isAssignExp)
        return assign.e2;
    if (auto construct = expression.isConstructExp)
        return construct.e2;
    if (auto blit = expression.isBlitExp)
        return blit.e2;

    return expression;
}

private long integerValue(imported!"dmd.expression".IntegerExp integer) {
    return cast(long) integer.getInteger;
}

private void execute(ref BytecodeModule module_) {
    long[] stack;
    long[] locals;
    size_t[] returnAddresses;
    size_t ip;

    while (ip < module_.code.length) {
        const instruction = module_.code[ip];
        final switch (instruction.op) with (OpCode) {
            case pushLong:
                stack ~= instruction.operand;
                ++ip;
                break;
            case loadLocal:
                stack ~= locals[cast(size_t) instruction.operand];
                ++ip;
                break;
            case storeLocal:
                const index = cast(size_t) instruction.operand;
                if (locals.length <= index)
                    locals.length = index + 1;
                locals[index] = stack.popLong;
                ++ip;
                break;
            case call:
                returnAddresses ~= ip + 1;
                ip = module_.functionEntries[
                    module_.functions[cast(size_t) instruction.operand]
                ];
                break;
            case add:
                const right = stack.popLong;
                const left = stack.popLong;
                stack ~= left + right;
                ++ip;
                break;
            case equal:
                const right = stack.popLong;
                const left = stack.popLong;
                stack ~= left == right;
                ++ip;
                break;
            case assertEqual:
                const right = stack.popLong;
                const left = stack.popLong;
                if (left != right)
                    throw new Exception("bytecode assertion failed");
                ++ip;
                break;
            case assertTrue:
                if (stack.popLong == 0)
                    throw new Exception("bytecode assertion failed");
                ++ip;
                break;
            case ret:
                ip = returnAddresses.popSize;
                break;
            case halt:
                return;
        }
    }
}

private long popLong(ref long[] stack) {
    const value = stack[$ - 1];
    stack = stack[0 .. $ - 1];
    return value;
}

private size_t popSize(ref size_t[] stack) {
    const value = stack[$ - 1];
    stack = stack[0 .. $ - 1];
    return value;
}

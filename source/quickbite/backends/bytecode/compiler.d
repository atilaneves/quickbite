module quickbite.backends.bytecode.compiler;

private:

import quickbite.backends.bytecode.module_:
    BytecodeInt,
    BytecodeModule,
    Instruction,
    OpCode,
    indexInstruction,
    pushInt;

public BytecodeModule compileBytecode(
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    Compiler compiler;
    compiler.compileStatement(unitTest.fbody);
    compiler.module_.code ~= Instruction(OpCode.halt);

    for (size_t i = 0; i < compiler.functions.length; ++i) {
        auto function_ = compiler.functions[i];
        compiler.module_.functionEntries[i] = compiler.module_.code.length;
        compiler.compileStatement(function_.fbody);
        compiler.module_.code ~= Instruction(OpCode.ret);
    }

    return compiler.module_;
}

private struct Compiler {
    private BytecodeModule module_;
    private imported!"dmd.func".FuncDeclaration[] functions;
    private size_t[imported!"dmd.func".FuncDeclaration] functionIndexes;
    private size_t[imported!"dmd.declaration".VarDeclaration] localIndexes;

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
            module_.code ~= pushInt(integerValue(integer));
            return;
        }

        if (auto assert_ = expression.isAssertExp) {
            compileExpression(assert_.e1);
            module_.code ~= Instruction(OpCode.assertTrue);
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

            module_.code ~= indexInstruction(
                OpCode.call,
                functionIndex(callFunction(call)),
            );
            return;
        }

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported bytecode variable.");

            module_.code ~= indexInstruction(OpCode.loadLocal, localIndex(variable));
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
        module_.code ~= indexInstruction(OpCode.storeLocal, localIndex(variable));
    }

    private size_t functionIndex(imported!"dmd.func".FuncDeclaration function_) {
        if (auto existing = function_ in functionIndexes)
            return *existing;

        const index = functions.length;
        functions ~= function_;
        functionIndexes[function_] = index;
        module_.functionEntries ~= size_t.init;
        return index;
    }

    private size_t localIndex(imported!"dmd.declaration".VarDeclaration variable) {
        if (auto existing = variable in localIndexes)
            return *existing;

        const index = module_.localCount;
        ++module_.localCount;
        localIndexes[variable] = index;
        return index;
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

private BytecodeInt integerValue(imported!"dmd.expression".IntegerExp integer) {
    return cast(BytecodeInt) integer.getInteger;
}

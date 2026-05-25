module quickbite.backends.bytecode.compiler;

private:

package(quickbite.backends.bytecode)
imported!"quickbite.backends.bytecode.module_".BytecodeModule compileBytecode(
    imported!"dmd.func".UnitTestDeclaration unitTest,
) {
    Compiler compiler;
    compiler.compileUnitTest(unitTest);
    return compiler.module_;
}

private struct Compiler {
    import quickbite.backends.bytecode.module_: BytecodeModule;
    import quickbite.backends.bytecode.opcode: Instruction, OpCode;

    private BytecodeModule module_;

    private void compileUnitTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
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
            module_.code ~= Instruction(OpCode.pushInteger, integer.getInteger);
            return;
        }

        if (auto assert_ = expression.isAssertExp) {
            if (auto equal = assert_.e1.isEqualExp) {
                compileExpression(equal.e1);
                compileExpression(equal.e2);
                module_.code ~= Instruction(OpCode.assertEqual);
                return;
            }

            compileExpression(assert_.e1);
            module_.code ~= Instruction(OpCode.pushInteger, 1);
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

        import std.conv: text;
        throw new Exception(text("Unsupported bytecode expression: ", expression.op));
    }

    private long functionIndex(imported!"dmd.func".FuncDeclaration function_) {
        if (auto existing = function_ in module_.functionIndexes)
            return cast(long) *existing;

        const index = module_.functions.length;
        module_.functions ~= function_;
        module_.functionIndexes[function_] = index;
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

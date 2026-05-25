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

        if (auto add = expression.isAddExp) {
            compileBinaryExpression(add.e1, add.e2, OpCode.add);
            return;
        }

        if (auto subtract = expression.isMinExp) {
            compileBinaryExpression(subtract.e1, subtract.e2, OpCode.subtract);
            return;
        }

        if (auto multiply = expression.isMulExp) {
            compileBinaryExpression(multiply.e1, multiply.e2, OpCode.multiply);
            return;
        }

        if (auto divide = expression.isDivExp) {
            compileBinaryExpression(divide.e1, divide.e2, OpCode.divide);
            return;
        }

        if (auto modulo = expression.isModExp) {
            compileBinaryExpression(modulo.e1, modulo.e2, OpCode.modulo);
            return;
        }

        if (auto shiftRight = expression.isShrExp) {
            compileBinaryExpression(shiftRight.e1, shiftRight.e2, OpCode.shiftRight);
            return;
        }

        if (auto shiftLeft = expression.isShlExp) {
            compileBinaryExpression(shiftLeft.e1, shiftLeft.e2, OpCode.shiftLeft);
            return;
        }

        if (auto bitwiseOr = expression.isOrExp) {
            compileBinaryExpression(bitwiseOr.e1, bitwiseOr.e2, OpCode.bitwiseOr);
            return;
        }

        if (auto bitwiseAnd = expression.isAndExp) {
            compileBinaryExpression(bitwiseAnd.e1, bitwiseAnd.e2, OpCode.bitwiseAnd);
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

    private void compileBinaryExpression(
        imported!"dmd.expression".Expression left,
        imported!"dmd.expression".Expression right,
        in OpCode op,
    ) {
        compileExpression(left);
        compileExpression(right);
        module_.code ~= Instruction(op);
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

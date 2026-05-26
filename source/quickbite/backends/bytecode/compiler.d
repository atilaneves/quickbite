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
            module_.code ~= Instruction(
                OpCode.pushValue,
                literalValue(integer),
            );
            return;
        }

        if (auto assert_ = expression.isAssertExp) {
            if (assert_.msg !is null)
                compileAssertMessage(assert_.msg);

            OpCode comparison;
            if (assertComparison(assert_.e1, comparison)) {
                auto binary = assert_.e1.isBinExp;
                compileExpression(binary.e1);
                compileExpression(binary.e2);
                module_.code ~= Instruction(
                    OpCode.assertCompare,
                    comparison,
                );
                return;
            }

            compileExpression(assert_.e1);
            compileAssertCondition;
            return;
        }

        if (auto equal = expression.isEqualExp) {
            compileExpression(equal.e1);
            compileExpression(equal.e2);
            module_.code ~= Instruction(equalOpCode(equal));
            return;
        }

        OpCode op;
        if (binaryOpCode(expression, op)) {
            auto binary = expression.isBinExp;
            compileBinaryExpression(binary.e1, binary.e2, op);
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

    private void compileAssertCondition() {
        module_.code ~= Instruction(OpCode.assertTrue);
    }

    private void compileAssertMessage(imported!"dmd.expression".Expression expression) {
        auto literal = expression.isStringExp;
        if (literal is null)
            throw new Exception("Unsupported bytecode assert message.");

        module_.assertMessages ~= literal.peekString.idup;
        module_.code ~= Instruction(
            OpCode.setAssertMessage,
            cast(long) module_.assertMessages.length - 1,
        );
    }

    private bool assertComparison(
        imported!"dmd.expression".Expression expression,
        out OpCode op,
    ) {
        if (auto equal = expression.isEqualExp) {
            op = equalOpCode(equal);
            return true;
        }

        return comparisonOpCode(expression, op);
    }

    private OpCode equalOpCode(imported!"dmd.expression".EqualExp equal) {
        return isNotEqualExpression(equal) ? OpCode.notEqual : OpCode.equal;
    }

    private bool isEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;
        return equal.op == EXP.equal;
    }

    private bool isNotEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;
        return equal.op == EXP.notEqual;
    }

    private bool comparisonOpCode(
        imported!"dmd.expression".Expression expression,
        out OpCode op,
    ) {
        import dmd.tokens: EXP;
        with (EXP) switch (expression.op) {
            case lessThan:
                op = OpCode.lessThan;
                return true;
            case lessOrEqual:
                op = OpCode.lessOrEqual;
                return true;
            case greaterThan:
                op = OpCode.greaterThan;
                return true;
            case greaterOrEqual:
                op = OpCode.greaterOrEqual;
                return true;
            default:
                return false;
        }
    }

    private bool binaryOpCode(
        imported!"dmd.expression".Expression expression,
        out OpCode op,
    ) {
        if (comparisonOpCode(expression, op))
            return true;

        import dmd.tokens: EXP;
        with (EXP) switch (expression.op) {
            case add:
                op = OpCode.add;
                return true;
            case min:
                op = OpCode.subtract;
                return true;
            case mul:
                op = OpCode.multiply;
                return true;
            case div:
                op = OpCode.divide;
                return true;
            case mod:
                op = OpCode.modulo;
                return true;
            case rightShift:
                op = OpCode.shiftRight;
                return true;
            case leftShift:
                op = OpCode.shiftLeft;
                return true;
            case or:
                op = OpCode.bitwiseOr;
                return true;
            case and:
                op = OpCode.bitwiseAnd;
                return true;
            case xor:
                op = OpCode.bitwiseXor;
                return true;
            default:
                return false;
        }
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

private imported!"quickbite.executor".Value literalValue(
    imported!"dmd.expression".IntegerExp integer,
) @trusted {
    import dmd.astenums: TY;
    import quickbite.executor: Value;

    if (integer.type is null)
        return Value(cast(long) integer.getInteger);

    const basetype = integer.type.toBasetype;
    with (TY) switch (basetype.ty) {
        case Tbool:
            return Value(integer.getInteger != 0);
        case Tint8:
            return Value(cast(byte) integer.getInteger);
        case Tuns8:
            return Value(cast(ubyte) integer.getInteger);
        case Tint16:
            return Value(cast(short) integer.getInteger);
        case Tuns16:
            return Value(cast(ushort) integer.getInteger);
        case Tint32:
            return Value(cast(int) integer.getInteger);
        case Tuns32:
            return Value(cast(uint) integer.getInteger);
        case Tint64:
            return Value(cast(long) integer.getInteger);
        case Tuns64:
            return Value(cast(ulong) integer.getInteger);
        case Tchar:
            return Value(cast(char) integer.getInteger);
        case Twchar:
            return Value(cast(wchar) integer.getInteger);
        case Tdchar:
            return Value(cast(dchar) integer.getInteger);
        default:
            return Value(cast(long) integer.getInteger);
    }
}

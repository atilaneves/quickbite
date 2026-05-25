module quickbite.backends.bytecode.compiler;

private:

import dmd.func: FuncDeclaration, UnitTestDeclaration;
import quickbite.backends.bytecode.module_: BytecodeModule, Emitter;
import quickbite.backends.bytecode.opcode: Instruction, OpCode;

public BytecodeModule compileBytecode(UnitTestDeclaration unitTest) {
    BytecodeModule module_;
    auto compiler = Compiler(&module_);
    compiler.compileUnitTest(unitTest);
    return module_;
}

private struct Compiler {
    private BytecodeModule* module_;
    private Emitter emitter;

    public this(return scope BytecodeModule* module_) @safe @nogc nothrow {
        this.module_ = module_;
        this.emitter = Emitter(module_);
    }

    public void compileUnitTest(UnitTestDeclaration unitTest) {
        compileStatement(unitTest.fbody);
        emitter.emit(Instruction(OpCode.halt));

        for (size_t i = 0; i < module_.functions.length; ++i) {
            auto function_ = module_.functions[i];
            module_.functionEntries[function_] = emitter.position;
            compileStatement(function_.fbody);
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
            emitter.emit(Instruction(OpCode.ret));
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported bytecode statement: ", statement.stmt));
    }

    private void compileExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp) {
            emitter.emit(Instruction(OpCode.pushInteger, integer.getInteger));
            return;
        }

        if (auto assert_ = expression.isAssertExp) {
            compileExpression(assert_.e1);
            emitter.emit(Instruction(OpCode.assertTrue));
            return;
        }

        if (auto equal = expression.isEqualExp) {
            compileExpression(equal.e1);
            compileExpression(equal.e2);
            emitter.emit(Instruction(OpCode.equal));
            return;
        }

        if (auto call = expression.isCallExp) {
            if (call.arguments !is null && call.arguments.length != 0)
                throw new Exception("Unsupported bytecode call arguments.");
            emitter.emit(Instruction(OpCode.call, functionIndex(callFunction(call))));
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported bytecode expression: ", expression.op));
    }

    private long functionIndex(FuncDeclaration function_) {
        if (auto existing = function_ in module_.functionIndexes)
            return cast(long) *existing;

        const index = module_.functions.length;
        module_.functions ~= function_;
        module_.functionIndexes[function_] = index;
        return cast(long) index;
    }

    private FuncDeclaration callFunction(imported!"dmd.expression".CallExp call) {
        if (call.f !is null)
            return call.f;

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return function_;

        throw new Exception("Unsupported bytecode call target.");
    }
}

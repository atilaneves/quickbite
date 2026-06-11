module quickbite.backends.bytecode.core.compiler;

private:

// Compiles a semantically analysed entry function (an eval wrapper or a
// unittest declaration) to a typed-frame bytecode program. The only module
// in the new core that sees DMD types.
package(quickbite.backends.bytecode)
imported!"quickbite.backends.bytecode.core.program".Program compile(
    imported!"dmd.func".FuncDeclaration entry,
) {
    Compiler compiler;
    return compiler.compile(entry);
}

private struct Compiler {

    import quickbite.backends.bytecode.core.program:
        CompiledFunction, Instruction, Op, Program, ScalarType, size;
    import dmd.expression: Expression;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Statement;

    private Program _program;
    private Instruction[] _code;
    private uint _frameOffset;
    private size_t[ulong] _constantIndices;

    private Program compile(FuncDeclaration entry) {
        _program.functions.length = 1;
        compileFunctionBody(0, entry);
        return _program;
    }

    private void compileFunctionBody(in size_t index, FuncDeclaration function_) {
        import dmd.mtype: Type;

        _code = null;
        _frameOffset = 0;
        compileStatement(function_.fbody);
        _program.functions[index] = CompiledFunction(
            _code,
            _frameOffset,
            scalarType(returnType(function_)),
        );
    }

    private void compileStatement(Statement statement) {
        import std.conv: text;

        if (auto scope_ = statement.isScopeStatement) {
            compileStatement(scope_.statement);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            foreach (child; *compound.statements)
                compileStatement(child);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            const operand = compileExpression(return_.exp);
            _code ~= Instruction(Op.ret, operand.offset);
            return;
        }

        throw new Exception(text(
            "Unsupported statement in bytecode core: ",
            statementChars(statement),
        ));
    }

    private Operand compileExpression(Expression expression) {
        import std.conv: text;

        if (auto integer = expression.isIntegerExp) {
            const type = scalarType(integer.type);
            const offset = allocate(type);
            _code ~= Instruction(
                Op.loadConstant,
                offset,
                constantIndex(integer.toInteger),
                cast(ushort) size(type),
            );
            return Operand(offset, type);
        }

        throw new Exception(text(
            "Unsupported expression in bytecode core: ",
            expressionChars(expression),
        ));
    }

    private ushort allocate(in ScalarType type) @safe pure {
        const alignment = size(type);
        _frameOffset = (_frameOffset + alignment - 1) & ~(alignment - 1);
        const offset = _frameOffset;
        if (offset > ushort.max)
            throw new Exception("Bytecode frame exceeds 16-bit offsets");

        _frameOffset += size(type);
        return cast(ushort) offset;
    }

    private ushort constantIndex(in ulong bits) @safe pure {
        if (auto existing = bits in _constantIndices)
            return cast(ushort) *existing;

        const index = _program.constants.length;
        _program.constants ~= bits;
        _constantIndices[bits] = index;
        return cast(ushort) index;
    }

    private ScalarType scalarType(Type type) {
        import dmd.astenums: TY;
        import std.conv: text;

        switch (type.toBasetype.ty) with (TY) {
            case Tint32:
                return ScalarType.int_;
            case Tvoid:
                return ScalarType.void_;
            default:
                throw new Exception(text(
                    "Unsupported type in bytecode core: ",
                    typeChars(type),
                ));
        }
    }
}

private struct Operand {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType type;
}

private imported!"dmd.mtype".Type returnType(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.type.nextOf;
}

private string statementChars(imported!"dmd.statement".Statement statement) {
    import std.conv: text;

    return text(statement.toChars);
}

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) {
    import std.conv: text;

    return text(expression.toChars);
}

private string typeChars(imported!"dmd.mtype".Type type) {
    import std.conv: text;

    return text(type.toChars);
}

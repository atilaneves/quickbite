module quickbite.backends.bytecode.core.compiler;

private:

// What the backend needs to run a compiled entry function: the program and
// the lazy-compilation hook the machine calls for not-yet-compiled callees.
package(quickbite.backends.bytecode) struct Compilation {
    imported!"quickbite.backends.bytecode.core.program".Program* program;
    imported!"quickbite.backends.bytecode.core.machine".CompileFunction
        compileFunction;
}

// Compiles a semantically analysed entry function (an eval wrapper or a
// unittest declaration) to a typed-frame bytecode program, compiling the
// entry body eagerly and callees on first call. The only module in the new
// core that sees DMD types.
package(quickbite.backends.bytecode) Compilation compile(
    imported!"dmd.func".FuncDeclaration entry,
) {
    auto compiler = new Compiler;
    compiler.registerFunction(entry);
    compiler.compileFunctionBody(0);
    return Compilation(compiler._program, &compiler.compileFunctionBody);
}

private struct Compiler {

    import quickbite.backends.bytecode.core.program:
        AssertDiagnostic, CompiledFunction, Instruction, Op, Program,
        ScalarType, isSigned, size;
    import dmd.declaration: VarDeclaration;
    import dmd.expression: AssertExp, CallExp, CastExp, Expression, StringExp;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Statement;

    private Program* _program;
    private FuncDeclaration[] _functions;
    private size_t[FuncDeclaration] _functionIndices;
    private Instruction[] _code;
    private uint _frameOffset;
    private ushort[VarDeclaration] _locals;
    private size_t[ulong] _constantIndices;

    private void compileFunctionBody(in size_t index) {
        auto function_ = _functions[index];
        _code = null;
        _locals = null;

        const layout = parameterLayout(function_);
        _frameOffset = layout.blockSize;
        if (function_.parameters !is null)
            foreach (parameterIndex; 0 .. function_.parameters.length)
                _locals[(*function_.parameters)[parameterIndex]] =
                    layout.offsets[parameterIndex];

        compileStatement(function_.fbody);
        // The fall-through return of a void body; unreachable after an
        // explicit return statement.
        _code ~= Instruction(Op.ret);

        _program.functions[index].code = _code;
        _program.functions[index].frameSize = (_frameOffset + 15) & ~15u;
    }

    private ushort registerFunction(FuncDeclaration function_) {
        if (auto existing = function_ in _functionIndices)
            return cast(ushort) *existing;

        if (_program is null)
            _program = new Program;

        const index = _functions.length;
        _functions ~= function_;
        _functionIndices[function_] = index;
        _program.functions ~= CompiledFunction(
            null,
            0,
            parameterLayout(function_).blockSize,
            scalarType(returnType(function_)),
        );
        return cast(ushort) index;
    }

    private void compileStatement(Statement statement) {
        import std.conv: text;

        if (auto scope_ = statement.isScopeStatement) {
            compileStatement(scope_.statement);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            foreach (childIndex; 0 .. compound.statements.length)
                compileStatement((*compound.statements)[childIndex]);
            return;
        }

        if (auto expressionStatement = statement.isExpStatement) {
            if (expressionStatement.exp !is null)
                compileExpression(expressionStatement.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            const operand = compileExpression(return_.exp);
            _code ~= Instruction(Op.ret, operand.offset);
            return;
        }

        throw new Exception(text(
            "Unsupported statement in bytecode core: ",
            statement.stmt,
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

        if (auto variable = expression.isVarExp) {
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _locals)
                    return Operand(*existing, scalarType(declaration.type));

            throw new Exception(text(
                "Unsupported variable in bytecode core: ",
                expressionChars(expression),
            ));
        }

        if (auto declaration = expression.isDeclarationExp) {
            if (auto variable = declaration.declaration.isVarDeclaration) {
                compileVariableDeclaration(variable);
                return Operand.init;
            }

            throw new Exception(text(
                "Unsupported declaration in bytecode core: ",
                expressionChars(expression),
            ));
        }

        if (auto comma = expression.isCommaExp) {
            compileExpression(comma.e1);
            return compileExpression(comma.e2);
        }

        if (auto cast_ = expression.isCastExp)
            return compileCastExpression(cast_);

        if (auto call = expression.isCallExp)
            return compileCall(call);

        if (auto assert_ = expression.isAssertExp) {
            compileAssert(assert_);
            return Operand.init;
        }

        throw new Exception(text(
            "Unsupported expression in bytecode core: ",
            expressionChars(expression),
        ));
    }

    private void compileVariableDeclaration(VarDeclaration variable) {
        import std.conv: text;

        const type = scalarType(variable.type);
        const offset = allocate(type);
        _locals[variable] = offset;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            throw new Exception(text(
                "Unsupported initializer in bytecode core: ",
                declarationChars(variable),
            ));

        const operand =
            compileExpression(initializerExpression(initializer.exp));
        _code ~= Instruction(
            Op.copy,
            offset,
            operand.offset,
            cast(ushort) size(type),
        );
    }

    private Operand compileCastExpression(CastExp cast_) {
        import std.conv: text;

        const source = compileExpression(cast_.e1);
        const target = scalarType(cast_.to);

        if (size(target) <= size(source.type)) {
            const offset = allocate(target);
            _code ~= Instruction(
                Op.copy,
                offset,
                source.offset,
                cast(ushort) size(target),
            );
            return Operand(offset, target);
        }

        return extend(source, target);
    }

    private Operand extend(in Operand source, in ScalarType target) {
        const offset = allocate(target);
        _code ~= Instruction(
            extendOp(size(source.type), size(target), isSigned(source.type)),
            offset,
            source.offset,
        );
        return Operand(offset, target);
    }

    private Operand compileCall(CallExp call) {
        import std.conv: text;

        auto function_ = callFunction(call);
        if (function_ is null || function_.fbody is null)
            throw new Exception(text(
                "Unsupported call in bytecode core: ",
                expressionChars(call),
            ));

        const index = registerFunction(function_);
        const layout = parameterLayout(function_);
        const argumentArea = allocateBytes(layout.blockSize, 8);

        if (call.arguments !is null)
            foreach (argumentIndex; 0 .. call.arguments.length) {
                const operand =
                    compileExpression((*call.arguments)[argumentIndex]);
                _code ~= Instruction(
                    Op.copy,
                    cast(ushort) (argumentArea + layout.offsets[argumentIndex]),
                    operand.offset,
                    cast(ushort) size(operand.type),
                );
            }

        const returnType = _program.functions[index].returnType;
        const destination = returnType == ScalarType.void_
            ? cast(ushort) 0
            : allocate(returnType);
        _code ~= Instruction(Op.call, index, argumentArea, destination);
        return Operand(destination, returnType);
    }

    private void compileAssert(AssertExp assert_) {
        import std.conv: text;

        if (compileLoweredComparisonAssert(assert_))
            return;

        throw new Exception(text(
            "Unsupported assert in bytecode core: ",
            expressionChars(assert_),
        ));
    }

    // DMD with -checkaction=context rewrites `assert(a == b)` into an
    // AssertExp whose message is a `_d_assert_fail` call carrying the
    // operator string and both operands; compile the operands once and
    // assert on their comparison.
    private bool compileLoweredComparisonAssert(AssertExp assert_) {
        if (assert_.msg is null)
            return false;

        auto call = assert_.msg.isCallExp;
        if (call is null || call.arguments is null ||
            call.arguments.length != 3)
            return false;

        auto operator = (*call.arguments)[0].isStringExp;
        if (operator is null || operatorText(operator) != "==")
            return false;

        // D's integer promotions appear only in the rewritten condition, not
        // in the _d_assert_fail operands; replicate them so mixed-width
        // operands compare and render at the comparison width.
        auto lhs = compileExpression((*call.arguments)[1]);
        auto rhs = compileExpression((*call.arguments)[2]);
        if (size(lhs.type) < size(rhs.type))
            lhs = extend(lhs, rhs.type);
        else if (size(rhs.type) < size(lhs.type))
            rhs = extend(rhs, lhs.type);

        const condition = allocateBytes(1, 1);
        _code ~= Instruction(
            equalOp(size(lhs.type)),
            condition,
            lhs.offset,
            rhs.offset,
        );

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic("==", lhs.offset, rhs.offset, lhs.type);
        _code ~= Instruction(
            Op.assertTrue,
            condition,
            cast(ushort) diagnostic,
        );
        return true;
    }

    private ushort allocate(in ScalarType type) @safe pure {
        return allocateBytes(size(type), size(type));
    }

    private ushort allocateBytes(in uint bytes, in uint alignment)
        @safe pure
    {
        _frameOffset = (_frameOffset + alignment - 1) & ~(alignment - 1);
        const offset = _frameOffset;
        if (offset > ushort.max)
            throw new Exception("Bytecode frame exceeds 16-bit offsets");

        _frameOffset += bytes;
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

    private ParameterLayout parameterLayout(FuncDeclaration function_) {
        ParameterLayout layout;
        if (function_.parameters is null)
            return layout;

        foreach (parameterIndex; 0 .. function_.parameters.length) {
            auto parameter = (*function_.parameters)[parameterIndex];
            if (parameter.isReference)
                throw new Exception(
                    "Unsupported ref parameter in bytecode core",
                );

            const type = scalarType(parameter.type);
            const alignment = size(type);
            layout.blockSize =
                (layout.blockSize + alignment - 1) & ~(alignment - 1);
            layout.offsets ~= cast(ushort) layout.blockSize;
            layout.blockSize += size(type);
        }

        return layout;
    }

    private ScalarType scalarType(Type type) {
        import dmd.astenums: TY;
        import std.conv: text;

        switch (type.toBasetype.ty) with (TY) {
            case Tvoid:
                return ScalarType.void_;
            case Tbool:
                return ScalarType.bool_;
            case Tint8:
                return ScalarType.byte_;
            case Tuns8:
                return ScalarType.ubyte_;
            case Tint16:
                return ScalarType.short_;
            case Tuns16:
                return ScalarType.ushort_;
            case Tint32:
                return ScalarType.int_;
            case Tuns32:
                return ScalarType.uint_;
            case Tint64:
                return ScalarType.long_;
            case Tuns64:
                return ScalarType.ulong_;
            case Tchar:
                return ScalarType.char_;
            case Twchar:
                return ScalarType.wchar_;
            case Tdchar:
                return ScalarType.dchar_;
            default:
                throw new Exception(text(
                    "Unsupported type in bytecode core: ",
                    typeChars(type),
                ));
        }
    }
}

private struct ParameterLayout {
    ushort[] offsets;
    uint blockSize;
}

private struct Operand {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType type;
}

private imported!"quickbite.backends.bytecode.core.program".Op extendOp(
    in uint sourceSize,
    in uint targetSize,
    in bool signed,
) @safe pure {
    import quickbite.backends.bytecode.core.program: Op;
    import std.conv: text;

    if (sourceSize == 1 && targetSize == 4)
        return signed ? Op.signExtend1to4 : Op.zeroExtend1to4;

    if (sourceSize == 4 && targetSize == 8 && signed)
        return Op.signExtend4to8;

    throw new Exception(text(
        "Unsupported extension in bytecode core: ",
        signed ? "signed " : "unsigned ",
        sourceSize,
        " to ",
        targetSize,
    ));
}

private imported!"quickbite.backends.bytecode.core.program".Op equalOp(
    in uint operandSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;

    switch (operandSize) {
        case 1: return Op.equal1;
        case 2: return Op.equal2;
        case 4: return Op.equal4;
        case 8: return Op.equal8;
        default: assert(0, "No equality opcode for the operand size.");
    }
}

private imported!"dmd.func".FuncDeclaration callFunction(
    imported!"dmd.expression".CallExp call,
) {
    if (call.f !is null)
        return call.f;

    if (auto variable = call.e1.isVarExp)
        if (auto function_ = variable.var.isFuncDeclaration)
            return function_;

    return null;
}

private imported!"dmd.expression".Expression initializerExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (auto assignment = expression.isAssignExp)
        return assignment.e2;

    if (auto construct = expression.isConstructExp)
        return construct.e2;

    if (auto blit = expression.isBlitExp)
        return blit.e2;

    return expression;
}

private imported!"dmd.mtype".Type returnType(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.type.nextOf;
}

private string operatorText(imported!"dmd.expression".StringExp operator) {
    string result;
    foreach (index; 0 .. operator.numberOfCodeUnits)
        result ~= cast(char) operator.getIndex(index);
    return result;
}

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) {
    import std.conv: text;

    return text(expression.toChars);
}

private string declarationChars(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import std.conv: text;

    return text(variable.toChars);
}

private string typeChars(imported!"dmd.mtype".Type type) {
    import std.conv: text;

    return text(type.toChars);
}

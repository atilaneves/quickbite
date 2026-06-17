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
        ResultType, ScalarType, isSigned, size, stringSliceSize;
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AddAssignExp, AssertExp, BinExp, CallExp, CastExp, CmpExp, DivExp,
        Expression, LogicalExp, NegExp, NotExp, OrExp, RealExp, StringExp;
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
            resultType(returnType(function_)),
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

        if (auto if_ = statement.isIfStatement) {
            compileIfStatement(if_);
            return;
        }

        // An import only brings symbols into scope; semantic has already
        // resolved them, so it emits no code.
        if (statement.isImportStatement !is null)
            return;

        throw new Exception(text(
            "Unsupported statement in bytecode core: ",
            statement.stmt,
        ));
    }

    private void compileIfStatement(imported!"dmd.statement".IfStatement if_) {
        const condition = compileExpression(if_.condition);
        const falseJump = emitJumpIfFalse(condition);

        compileStatement(if_.ifbody);
        const endJump = emitJump;

        patchJump(falseJump);
        if (if_.elsebody !is null)
            compileStatement(if_.elsebody);

        patchJump(endJump);
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

        if (auto real_ = expression.isRealExp) {
            const type = scalarType(real_.type);
            const offset = allocate(type);
            _code ~= Instruction(
                Op.loadConstant,
                offset,
                constantIndex(floatBits(real_, type)),
                cast(ushort) size(type),
            );
            return Operand(offset, type);
        }

        if (auto string_ = expression.isStringExp)
            return compileStringLiteral(string_);

        if (auto negate = expression.isNegExp)
            return compileNegateExpression(negate);

        if (auto not = expression.isNotExp)
            return compileNotExpression(not);

        if (auto subtract = expression.isMinExp)
            return compileSubtractExpression(subtract);

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

        if (auto add = expression.isAddExp)
            return compileAddExpression(add);

        if (auto or = expression.isOrExp)
            return compileOrExpression(or);

        if (auto divide = expression.isDivExp)
            return compileDivideExpression(divide);

        if (auto comparison = comparisonExpression(expression))
            return compileComparisonExpression(comparison);

        if (auto logical = expression.isLogicalExp)
            return compileLogicalExpression(logical);

        if (auto addAssign = expression.isAddAssignExp)
            return compileAddAssignExpression(addAssign);

        if (auto equal = expression.isEqualExp)
            return compileEqualExpression(equal);

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

    // A string literal lives in the read-only data segment; the frame slot
    // holds a slice descriptor (data offset and length). reify rebuilds the
    // string from that descriptor plus the segment at the boundary.
    private Operand compileStringLiteral(StringExp string_) {
        import quickbite.frontend.dmd.string_literals: stringChars;
        import std.conv: text;

        const bytes = cast(const(ubyte)[]) stringChars(string_);
        const dataOffset = _program.data.length;
        if (dataOffset > ushort.max || bytes.length > ushort.max)
            throw new Exception(text(
                "String literal too large for bytecode core: ",
                expressionChars(string_),
            ));
        _program.data ~= bytes;

        const offset = allocateBytes(stringSliceSize, 4);
        _code ~= Instruction(
            Op.loadStringSlice,
            offset,
            cast(ushort) dataOffset,
            cast(ushort) bytes.length,
        );
        return Operand(offset, ScalarType.void_, true);
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

        // Crossing the int/float boundary needs a numeric conversion, not a
        // byte copy or integer extension. Only double -> int is needed today.
        if (source.type == ScalarType.double_ && target == ScalarType.int_) {
            const offset = allocate(target);
            _code ~= Instruction(Op.convertDoubleToInt, offset, source.offset);
            return Operand(offset, target);
        }

        if (isFloating(source.type) != isFloating(target))
            throw new Exception(text(
                "Unsupported numeric cast in bytecode core: ",
                expressionChars(cast_),
            ));

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

    private Operand compileAddExpression(Expression expression) {
        auto add = cast(BinExp) expression; // DMD AST fields are mutable refs.
        assert(add !is null);

        const lhs = compileExpression(add.e1);
        const rhs = compileExpression(add.e2);
        if (lhs.type == ScalarType.float_ && rhs.type == ScalarType.float_)
            return emitBinary(Op.addFloat, lhs, rhs, ScalarType.float_);
        if (lhs.type == ScalarType.double_ && rhs.type == ScalarType.double_)
            return emitBinary(Op.addDouble, lhs, rhs, ScalarType.double_);

        return compileIntBinaryResult(
            add,
            lhs,
            rhs,
            Op.addInt4,
            ScalarType.int_,
            "Unsupported addition in bytecode core: ",
        );
    }

    // D's `|` is integer-typed; only the 4-byte int form is needed today.
    private Operand compileOrExpression(OrExp or) {
        const lhs = compileExpression(or.e1);
        const rhs = compileExpression(or.e2);
        return compileIntBinaryResult(
            or,
            lhs,
            rhs,
            Op.bitOrInt4,
            ScalarType.int_,
            "Unsupported bitwise or in bytecode core: ",
        );
    }

    // D's `/` on int is signed integer division. Only the 4-byte int form is
    // needed today (it appears as the never-executed RHS of a short-circuited
    // `&&`); a runtime divide-by-zero would fault, matching compiled code.
    private Operand compileDivideExpression(DivExp divide) {
        const lhs = compileExpression(divide.e1);
        const rhs = compileExpression(divide.e2);
        return compileIntBinaryResult(
            divide,
            lhs,
            rhs,
            Op.divInt4,
            ScalarType.int_,
            "Unsupported division in bytecode core: ",
        );
    }

    // Integer `<` / `>`; both yield a bool. One opcode per operator, not per
    // operand type. Only the forms `&&` operands produce are needed today.
    private Operand compileComparisonExpression(CmpExp comparison) {
        import dmd.tokens: EXP;
        import std.conv: text;

        const op = () {
            switch (comparison.op) with (EXP) {
                case lessThan: return Op.lessThan4;
                case greaterThan: return Op.greaterThan4;
                default:
                    throw new Exception(text(
                        "Unsupported comparison in bytecode core: ",
                        expressionChars(comparison),
                    ));
            }
        }();

        const lhs = compileExpression(comparison.e1);
        const rhs = compileExpression(comparison.e2);
        return compileIntBinaryResult(
            comparison,
            lhs,
            rhs,
            op,
            ScalarType.bool_,
            "Unsupported comparison in bytecode core: ",
        );
    }

    // `&&` / `||` short-circuit through jumps and write a bool result into one
    // slot on both paths. `&&`: if lhs is false the result is 0 and rhs is
    // never evaluated; otherwise the result is rhs normalised to bool. `||`:
    // mirror image. No value stack; the result lives in a typed frame slot.
    private Operand compileLogicalExpression(LogicalExp logical) {
        import dmd.tokens: EXP;
        import std.conv: text;

        if (logical.op != EXP.andAnd && logical.op != EXP.orOr)
            throw new Exception(text(
                "Unsupported logical expression in bytecode core: ",
                expressionChars(logical),
            ));

        const result = allocate(ScalarType.bool_);
        const lhs = compileExpression(logical.e1);
        const shortCircuitJump = logical.op == EXP.andAnd
            ? emitJumpIfFalse(lhs)
            : emitJumpIfTrue(lhs);

        // The non-short-circuiting path evaluates rhs and normalises it.
        const rhs = compileExpression(logical.e2);
        _code ~= Instruction(Op.normaliseBool, result, rhs.offset);
        const endJump = emitJump;

        // The short-circuit path: `&&` writes 0, `||` writes 1.
        patchJump(shortCircuitJump);
        _code ~= Instruction(
            Op.loadConstant,
            result,
            constantIndex(logical.op == EXP.andAnd ? 0 : 1),
            1,
        );
        patchJump(endJump);

        return Operand(result, ScalarType.bool_);
    }

    private Operand compileSubtractExpression(BinExp subtract) {
        import std.conv: text;

        const lhs = compileExpression(subtract.e1);
        const rhs = compileExpression(subtract.e2);
        if (lhs.type == ScalarType.float_ && rhs.type == ScalarType.float_)
            return emitBinary(Op.subFloat, lhs, rhs, ScalarType.float_);
        if (lhs.type == ScalarType.double_ && rhs.type == ScalarType.double_)
            return emitBinary(Op.subDouble, lhs, rhs, ScalarType.double_);

        throw new Exception(text(
            "Unsupported subtraction in bytecode core: ",
            expressionChars(subtract),
        ));
    }

    private Operand compileNegateExpression(NegExp negate) {
        import std.conv: text;

        const source = compileExpression(negate.e1);
        if (source.type == ScalarType.float_) {
            const offset = allocate(ScalarType.float_);
            _code ~= Instruction(Op.negateFloat, offset, source.offset);
            return Operand(offset, ScalarType.float_);
        }
        if (source.type == ScalarType.double_) {
            const offset = allocate(ScalarType.double_);
            _code ~= Instruction(Op.negateDouble, offset, source.offset);
            return Operand(offset, ScalarType.double_);
        }

        throw new Exception(text(
            "Unsupported negation in bytecode core: ",
            expressionChars(negate),
        ));
    }

    // Logical not always yields a bool regardless of the operand type
    // (`inner == 0 ? 1 : 0`), so a single opcode covers every case; no
    // per-type family.
    private Operand compileNotExpression(NotExp not) {
        const source = compileExpression(not.e1);
        const offset = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.notBool, offset, source.offset);
        return Operand(offset, ScalarType.bool_);
    }

    private Operand emitBinary(
        in Op op,
        in Operand lhs,
        in Operand rhs,
        in ScalarType resultType,
    ) @safe pure {
        const offset = allocate(resultType);
        _code ~= Instruction(op, offset, lhs.offset, rhs.offset);
        return Operand(offset, resultType);
    }

    // DMD lowers `++x` to the compound add-assign `x += 1`. Lower it through
    // the existing add: add the local and the rhs into the local's own frame
    // slot, and yield the local (the new value) as the expression result. No
    // dedicated increment opcode (see PR-123): this is plain `addInt4` with the
    // destination being the lvalue's slot. Scoped to integer local-variable
    // lvalues; anything else is unsupported.
    private Operand compileAddAssignExpression(AddAssignExp addAssign) {
        import std.conv: text;

        auto variable = addAssign.e1.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        auto slot = declaration is null ? null : declaration in _locals;
        const lhs = slot is null
            ? Operand.init
            : Operand(*slot, scalarType(declaration.type));
        const rhs = compileExpression(addAssign.e2);
        if (slot is null ||
            lhs.type != ScalarType.int_ ||
            rhs.type != ScalarType.int_ ||
            scalarType(addAssign.type) != ScalarType.int_)
            throw new Exception(text(
                "Unsupported compound assignment in bytecode core: ",
                expressionChars(addAssign),
            ));

        _code ~= Instruction(Op.addInt4, lhs.offset, lhs.offset, rhs.offset);
        return lhs;
    }

    private Operand compileEqualExpression(Expression expression) {
        auto equal = cast(BinExp) expression; // DMD AST fields are mutable refs.
        assert(equal !is null);
        return compileIntBinaryExpression(
            equal,
            Op.equal4,
            ScalarType.bool_,
            "Unsupported equality in bytecode core: ",
        );
    }

    private Operand compileIntBinaryExpression(
        BinExp expression,
        in Op op,
        in ScalarType resultType,
        in string unsupportedMessage,
    ) {
        const lhs = compileExpression(expression.e1);
        const rhs = compileExpression(expression.e2);
        return compileIntBinaryResult(
            expression, lhs, rhs, op, resultType, unsupportedMessage,
        );
    }

    private Operand compileIntBinaryResult(
        BinExp expression,
        in Operand lhs,
        in Operand rhs,
        in Op op,
        in ScalarType resultType,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        if (lhs.type != ScalarType.int_ ||
            rhs.type != ScalarType.int_ ||
            (resultType == ScalarType.int_ &&
                scalarType(expression.type) != ScalarType.int_))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(expression),
            ));

        const offset = allocate(resultType);
        _code ~= Instruction(op, offset, lhs.offset, rhs.offset);
        return Operand(offset, resultType);
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
        if (function_ !is null)
            if (auto builtin = compileBuiltinCall(call, function_))
                return *builtin;

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
        const destination =
            (!returnType.isString && returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(Op.call, index, argumentArea, destination);
        return Operand(destination, returnType.scalar, returnType.isString);
    }

    // Recognise the std.math builtins eval needs (fabs, pow) via DMD's own
    // builtin classification and emit a VM intrinsic instead of a call. The
    // destination is typed by the call's static return type, so a float
    // argument yields a float result (kept at 4 bytes, displayed with "f").
    private Operand* compileBuiltinCall(
        CallExp call,
        FuncDeclaration function_,
    ) {
        import dmd.builtin: isBuiltin;
        import dmd.func: BUILTIN;

        const resultType = scalarType(callType(call));
        with (BUILTIN) switch (isBuiltin(function_)) {
            case fabs:
                if (resultType != ScalarType.float_)
                    break;
                const argument = compileExpression((*call.arguments)[0]);
                const offset = allocate(ScalarType.float_);
                _code ~= Instruction(Op.fabsFloat, offset, argument.offset);
                return new Operand(offset, ScalarType.float_);

            case pow:
                if (resultType != ScalarType.float_)
                    break;
                const base = compileExpression((*call.arguments)[0]);
                const exponent = compileExpression((*call.arguments)[1]);
                const offset = allocate(ScalarType.float_);
                _code ~= Instruction(
                    Op.powFloat,
                    offset,
                    base.offset,
                    exponent.offset,
                );
                return new Operand(offset, ScalarType.float_);

            default:
                break;
        }

        return null;
    }

    private size_t emitJump() @safe pure {
        const index = _code.length;
        _code ~= Instruction(Op.jump);
        return index;
    }

    private size_t emitJumpIfFalse(in Operand condition) @safe pure {
        const index = _code.length;
        _code ~= Instruction(Op.jumpIfFalse, condition.offset);
        return index;
    }

    private size_t emitJumpIfTrue(in Operand condition) @safe pure {
        const index = _code.length;
        _code ~= Instruction(Op.jumpIfTrue, condition.offset);
        return index;
    }

    private void patchJump(in size_t index) @safe pure {
        _code[index].b = cast(ushort) _code.length;
        if (_code[index].op == Op.jump)
            _code[index].a = _code[index].b;
    }

    private void compileAssert(AssertExp assert_) {
        import std.conv: text;

        if (compileLiteralFalseAssert(assert_))
            return;

        if (compileLoweredComparisonAssert(assert_))
            return;

        if (compileVerbatimStringAssert(assert_))
            return;

        throw new Exception(text(
            "Unsupported assert in bytecode core: ",
            expressionChars(assert_),
        ));
    }

    // `assert(0)` (a compile-time-false literal with no message) in a compiled
    // non-unittest function aborts with the plain _d_assert message
    // "Assertion failure"; DMD emits no contextual operands, so the VM halts
    // without reading any frame slot. (The CTFE "`assert(0)` failed" form is
    // characterised on the interpretation backends, not here.)
    private bool compileLiteralFalseAssert(AssertExp assert_) {
        if (assert_.msg !is null)
            return false;

        auto integer = assert_.e1.isIntegerExp;
        if (integer is null || integer.toInteger != 0)
            return false;

        _code ~= Instruction(Op.halt);
        return true;
    }

    // `assert(cond)` on a non-comparison runtime condition (a `&&`/`||` chain)
    // lowers to an AssertExp whose message is the verbatim DMD string
    // "`assert(<source>)` failed". Compile the condition to a bool and, on
    // failure, throw that exact string rather than synthesising one.
    private bool compileVerbatimStringAssert(AssertExp assert_) {
        import quickbite.frontend.dmd.string_literals: stringChars;

        if (assert_.msg is null)
            return false;

        auto message = assert_.msg.isStringExp;
        if (message is null)
            return false;

        if (assert_.e1.isLogicalExp is null && assert_.e1.isNotExp is null)
            return false;

        const condition = compileExpression(assert_.e1);
        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~= AssertDiagnostic(
            stringChars(message).idup,
            condition.offset,
            condition.offset,
            condition.type,
        );
        _code ~= Instruction(
            Op.assertTrueVerbatim,
            condition.offset,
            cast(ushort) diagnostic,
        );
        return true;
    }

    // DMD with -checkaction=context rewrites `assert(a == b)` into an
    // AssertExp whose message is a `_d_assert_fail` call carrying the
    // operator string and both operands; compile the operands once and
    // assert on their comparison.
    private bool compileLoweredComparisonAssert(AssertExp assert_) {
        if (assert_.msg is null)
            return false;

        auto call = assert_.msg.isCallExp;
        if (call is null || call.arguments is null)
            return false;

        auto operator = (*call.arguments)[0].isStringExp;
        if (operator is null)
            return false;

        // `assert(intExpr)` lowers to `_d_assert_fail("", intExpr)`: a single
        // operand asserted non-zero, rendered "<value> != true" on failure.
        if (call.arguments.length == 2 && operatorText(operator) == "")
            return compileNonzeroAssert((*call.arguments)[1]);

        // `assert(!boolExpr)` lowers to `_d_assert_fail("!", boolExpr)`: the
        // condition holds when `boolExpr` is false, and the failure renders
        // "<value> == true" (the un-negated operand against the `true` it was
        // implicitly compared to).
        if (call.arguments.length == 2 && operatorText(operator) == "!")
            return compileNotAssert((*call.arguments)[1]);

        if (call.arguments.length != 3 || operatorText(operator) != "==")
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

    // `assert(intExpr)`: throw when the int evaluates to zero; the failure
    // renders "<value> != true", so the diagnostic carries only the operand.
    private bool compileNonzeroAssert(Expression expression) {
        import std.conv: text;

        const operand = compileExpression(expression);
        if (operand.type != ScalarType.int_)
            throw new Exception(text(
                "Unsupported truth assert in bytecode core: ",
                expressionChars(expression),
            ));

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic("", operand.offset, operand.offset, operand.type);
        _code ~= Instruction(
            Op.assertNonzeroInt4,
            operand.offset,
            cast(ushort) diagnostic,
        );
        return true;
    }

    // `assert(!boolExpr)`: compile the operand, assert its negation is true
    // (i.e. the operand is false). The diagnostic carries the un-negated
    // operand and renders "<value> == true" via the "!" inverted operator.
    private bool compileNotAssert(Expression expression) {
        import std.conv: text;

        const operand = compileExpression(expression);
        if (operand.type != ScalarType.bool_)
            throw new Exception(text(
                "Unsupported logical-not assert in bytecode core: ",
                expressionChars(expression),
            ));

        const condition = allocateBytes(1, 1);
        _code ~= Instruction(Op.notBool, condition, operand.offset);

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic("!", operand.offset, operand.offset, operand.type);
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

    // A function result is either a scalar or a string slice. Only the string
    // case is non-scalar today (the leading edge of arrays); everything else
    // routes through the scalar path.
    private ResultType resultType(Type type) {
        if (isStringType(type))
            return ResultType(ScalarType.void_, true);

        return ResultType(scalarType(type), false);
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
            case Tfloat32:
                return ScalarType.float_;
            case Tfloat64:
                return ScalarType.double_;
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
    bool isString; // when set, `offset` holds a string-slice descriptor
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

// A `string`/`wstring`/`dstring` (immutable char-element array): the only
// non-scalar result the core lowers today.
private bool isStringType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto base = type.toBasetype;
    if (base.ty != TY.Tarray)
        return false;

    auto element = base.nextOf; // const fails: nextOf is a mutable method.
    if (element is null)
        return false;

    switch (element.toBasetype.ty) with (TY) {
        case Tchar, Twchar, Tdchar:
            return true;
        default:
            return false;
    }
}

private bool isFloating(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    return type == ScalarType.float_ || type == ScalarType.double_;
}

// Lower a float/double literal to the raw bits loadConstant copies: the
// IEEE-754 pattern of the value at the target width sits in the low bytes.
private ulong floatBits(
    imported!"dmd.expression".RealExp real_,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe {
    import quickbite.backends.bytecode.core.program: ScalarType;
    import std.bitmanip: nativeToLittleEndian;

    if (type == ScalarType.float_) {
        const ubyte[float.sizeof] bytes =
            nativeToLittleEndian(cast(float) realValue(real_));
        ulong bits;
        foreach (i; 0 .. float.sizeof)
            bits |= cast(ulong) bytes[i] << (8 * i);
        return bits;
    }

    const ubyte[double.sizeof] bytes =
        nativeToLittleEndian(cast(double) realValue(real_));
    ulong bits;
    foreach (i; 0 .. double.sizeof)
        bits |= cast(ulong) bytes[i] << (8 * i);
    return bits;
}

private real realValue(imported!"dmd.expression".RealExp real_) @trusted {
    // RealExp.value is a dmd longdouble (real_t); reading it is pure data
    // access with no aliasing, but the dmd field accessor is not @safe.
    return cast(real) real_.value;
}

// DMD has no `isCmpExp`; a CmpExp is a BinExp whose op is a relational
// operator. Only `<` / `>` are lowered today (the forms `&&` operands use).
private imported!"dmd.expression".CmpExp comparisonExpression(
    imported!"dmd.expression".Expression expression,
) {
    import dmd.expression: CmpExp;
    import dmd.tokens: EXP;

    if (expression.op != EXP.lessThan && expression.op != EXP.greaterThan)
        return null;

    return cast(CmpExp) expression;
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

private imported!"dmd.mtype".Type callType(
    imported!"dmd.expression".CallExp call,
) {
    return call.type;
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

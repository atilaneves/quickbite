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
    // A literal-false assert directly in a unittest body must throw
    // "unittest failure" (DMD's _d_unittest hook); the same assert in a
    // called function throws "Assertion failure". Only the entry can be a
    // unittest declaration; lazily-compiled callees never are.
    compiler._inUnittestEntry = entry.isUnitTestDeclaration !is null;
    compiler.compileFunctionBody(0);
    return Compilation(compiler._program, &compiler.compileFunctionBody);
}

private struct Compiler {

    import quickbite.backends.bytecode.core.program:
        AssertDiagnostic, CompiledFunction, Instruction, Op, Program,
        RefParameter, ResultType, ScalarType, isSigned, size, stringSliceSize;
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AddAssignExp, ArrayLiteralExp, AssertExp, AssignExp, BinExp, CallExp,
        CastExp, CmpExp, DivExp, Expression, IndexExp, LogicalExp, NegExp,
        NewExp, NotExp, OrExp, RealExp, SliceExp, StringExp;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Statement;

    private Program* _program;
    private FuncDeclaration[] _functions;
    private size_t[FuncDeclaration] _functionIndices;
    private Instruction[] _code;
    private uint _frameOffset;
    private ushort[VarDeclaration] _locals;
    private bool[VarDeclaration] _stringLocals; // locals holding a string slice
    // Locals whose slot is a static array `T[N]` stored inline in the frame;
    // the value records the slot offset for indexing and block copies.
    private ushort[VarDeclaration] _staticArrayLocals;
    private size_t[ulong] _constantIndices;
    private bool _inUnittestEntry; // true only while compiling the entry
                                   // function when it is a UnitTestDeclaration

    private void compileFunctionBody(in size_t index) {
        // Only the entry (index 0) can be a unittest body; any lazily
        // compiled callee is an ordinary function.
        if (index > 0)
            _inUnittestEntry = false;

        auto function_ = _functions[index];
        _code = null;
        _locals = null;
        _stringLocals = null;
        _staticArrayLocals = null;

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
        const layout = parameterLayout(function_);
        _program.functions ~= CompiledFunction(
            null,
            0,
            layout.blockSize,
            resultType(returnType(function_)),
            layout.refParameters.dup,
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

        if (auto throw_ = statement.isThrowStatement) {
            compileThrow(throw_);
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

    private void compileThrow(imported!"dmd.statement".ThrowStatement throw_) {
        import std.conv: text;

        auto new_ = throw_.exp is null ? null : throw_.exp.isNewExp;
        if (!isPlainExceptionNew(new_))
            throw new Exception(text(
                "Unsupported throw expression in bytecode core: ",
                throw_.exp is null ? "<null>" : expressionChars(throw_.exp),
            ));

        auto messageExpression =
            (*new_.arguments)[0]; // DMD Expression APIs require mutable AST.
        const message = compileExpression(messageExpression);
        if (!message.isString)
            throw new Exception(text(
                "Unsupported throw message in bytecode core: ",
                expressionChars(messageExpression),
            ));

        _code ~= Instruction(Op.throwString, message.offset);
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
            if (type == ScalarType.real_) {
                _code ~= Instruction(
                    Op.loadRealConstant,
                    offset,
                    realConstantIndex(real_),
                );
                return Operand(offset, type);
            }

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
                if (auto existing = declaration in _locals) {
                    if (declaration in _stringLocals)
                        return Operand(*existing, ScalarType.void_, true);
                    return Operand(*existing, scalarType(declaration.type));
                }

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

        if (auto assign = expression.isAssignExp)
            return compileAssignExpression(assign);

        if (auto equal = expression.isEqualExp)
            return compileEqualExpression(equal);

        if (auto call = expression.isCallExp)
            return compileCall(call);

        if (auto assert_ = expression.isAssertExp) {
            compileAssert(assert_);
            return Operand.init;
        }

        if (auto index = expression.isIndexExp)
            return compileStaticArrayIndex(index);

        throw new Exception(text(
            "Unsupported expression in bytecode core: ",
            expressionChars(expression),
        ));
    }

    // Read an element of a static array at a compile-time-constant index. The
    // element lives at `slot + index * elementSize` inside the inline block;
    // a scalar element is returned directly, a sub-array element yields a
    // static-array operand for further indexing (`matrix[0][1]`).
    private Operand compileStaticArrayIndex(IndexExp index) {
        const located = locateStaticArrayElement(index);
        return Operand(located.offset, located.type);
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
        import dmd.astenums: TY;
        import std.conv: text;

        // A static array `T[N]` is a value type stored inline in the frame at
        // its DMD-computed size and alignment; no heap, no slice descriptor.
        if (variable.type.toBasetype.ty == TY.Tsarray) {
            compileStaticArrayDeclaration(variable);
            return;
        }

        // A `string` local holds an 8-byte slice descriptor (data offset and
        // length), not a scalar; allocate the descriptor width and copy the
        // initializer's slice into it.
        const isString = isStringType(variable.type);
        const type = isString ? ScalarType.void_ : scalarType(variable.type);
        const slotSize = isString ? stringSliceSize : size(type);
        const offset = allocateBytes(slotSize, isString ? 4 : size(type));
        _locals[variable] = offset;
        if (isString)
            _stringLocals[variable] = true;

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
            cast(ushort) slotSize,
        );
    }

    // A static array `T[N]` occupies `Type.size()` inline frame bytes at its
    // DMD-computed alignment. The frame begins zeroed, so default
    // initialization (`source[] = 0`) emits nothing; a string literal or a
    // copy from another static array copies the bytes into the inline slot.
    private void compileStaticArrayDeclaration(VarDeclaration variable) {
        import std.conv: text;

        const totalSize = cast(uint) staticArraySize(variable.type);
        const offset = allocateBytes(totalSize, staticArrayAlign(variable.type));
        // A static array is tracked only in `_staticArrayLocals`, not
        // `_locals`: the scalar VarExp/assignment paths must not treat its
        // inline block as a scalar slot.
        _staticArrayLocals[variable] = offset;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            throw new Exception(text(
                "Unsupported initializer in bytecode core: ",
                declarationChars(variable),
            ));

        // DMD default-initializes a static array local with `variable[] = 0`
        // (a blit whose target is a whole-array slice). The frame slot is
        // already zero, so this needs no code.
        if (auto blit = initializer.exp.isBlitExp)
            if (blit.e1.isSliceExp !is null && blit.e2.isIntegerExp !is null)
                return;

        auto source = initializerExpression(initializer.exp);

        // `char[N] c = "..."`: copy the literal bytes directly into the inline
        // slot rather than building a slice descriptor.
        if (auto string_ = stringLiteralOf(source)) {
            loadStaticString(offset, totalSize, string_);
            return;
        }

        // `T[N] dest = src`: a value-type block copy of all N*sizeof(T) bytes
        // from the source static array's inline slot into the destination's.
        if (auto sourceOffset = staticArrayOffsetOf(source)) {
            _code ~= Instruction(
                Op.copy,
                offset,
                *sourceOffset,
                cast(ushort) totalSize,
            );
            return;
        }

        throw new Exception(text(
            "Unsupported static array initializer in bytecode core: ",
            declarationChars(variable),
        ));
    }

    // Copy a string literal's bytes into a `char[N]` inline slot. DMD requires
    // the literal length to match N, so the copy fills the whole slot.
    private void loadStaticString(
        in ushort offset,
        in uint totalSize,
        StringExp string_,
    ) {
        import quickbite.frontend.dmd.string_literals: stringChars;
        import std.conv: text;

        const bytes = cast(const(ubyte)[]) stringChars(string_);
        const dataOffset = _program.data.length;
        if (dataOffset > ushort.max || bytes.length != totalSize)
            throw new Exception(text(
                "Unsupported static char-array literal in bytecode core: ",
                expressionChars(string_),
            ));
        _program.data ~= bytes;

        _code ~= Instruction(
            Op.loadStaticArray,
            offset,
            cast(ushort) dataOffset,
            cast(ushort) totalSize,
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

        // 8-byte integer addition (e.g. `size_t`): same operand and result
        // type on both sides, kept at the full width.
        if (isEightByteInteger(lhs.type) &&
            lhs.type == rhs.type &&
            scalarType(add.type) == lhs.type)
            return emitBinary(Op.addInt8, lhs, rhs, lhs.type);

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
                case lessOrEqual: return Op.lessOrEqual4;
                case greaterThan: return Op.greaterThan4;
                case greaterOrEqual: return Op.greaterOrEqual4;
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
        if (source.type == ScalarType.real_) {
            const offset = allocate(ScalarType.real_);
            _code ~= Instruction(Op.negateReal, offset, source.offset);
            return Operand(offset, ScalarType.real_);
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
        // `++x`/`x += n` on an integer local: 4-byte and 8-byte integer widths
        // (size_t is ulong on x86-64, so `++len` lands here) share the lvalue's
        // own slot as the destination. Both sides and the result carry the
        // lvalue's type.
        const lvalueType = scalarType(addAssign.type);
        const addOp = lvalueType == ScalarType.long_ ||
            lvalueType == ScalarType.ulong_
                ? Op.addInt8
                : Op.addInt4;
        if (slot is null ||
            lhs.type != rhs.type ||
            lhs.type != lvalueType ||
            !isIntegerScalar(lvalueType))
            throw new Exception(text(
                "Unsupported compound assignment in bytecode core: ",
                expressionChars(addAssign),
            ));

        _code ~= Instruction(addOp, lhs.offset, lhs.offset, rhs.offset);
        return lhs;
    }

    // `local = expr` for a scalar local lvalue (including a `ref` parameter's
    // slot): evaluate the right-hand side and copy it into the local's slot,
    // yielding the local as the assignment's result. Scoped to local-variable
    // lvalues with a matching scalar type; anything else is unsupported.
    private Operand compileAssignExpression(AssignExp assign) {
        import std.conv: text;

        // `arr[i] = rhs` for a static-array element: write the scalar rhs into
        // the element's inline frame offset.
        if (auto index = assign.e1.isIndexExp)
            if (auto element = tryStaticArrayElement(index))
                return compileStaticArrayElementAssign(*element, assign.e2);

        // `matrix[] = [...]` broadcasts a one-dimensional row literal to each
        // row of a multidimensional static array in place.
        if (auto slice = assign.e1.isSliceExp)
            if (auto broadcast = tryStaticArrayBroadcast(slice, assign.e2))
                return *broadcast;

        auto variable = assign.e1.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        auto slot = declaration is null ? null : declaration in _locals;
        const type = slot is null
            ? ScalarType.void_
            : scalarType(declaration.type);
        const rhs = compileExpression(assign.e2);
        if (slot is null || rhs.type != type)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(assign),
            ));

        _code ~= Instruction(
            Op.copy,
            *slot,
            rhs.offset,
            cast(ushort) size(type),
        );
        return Operand(*slot, type);
    }

    // A located static-array element: its inline frame offset and scalar type.
    private static struct StaticArrayElement {
        ushort offset;
        ScalarType type;
    }

    // Resolve a static-array element access with compile-time-constant indices
    // to its inline frame offset, walking the IndexExp chain from a
    // static-array local. Each level adds `index * Type.size(level.type)` to
    // the base offset.
    private StaticArrayElement locateStaticArrayElement(
        IndexExp index,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        const baseOffset = staticArrayBaseOffset(index.e1);
        auto indexInteger = index.e2.isIntegerExp;
        if (indexInteger is null)
            throw new Exception(text(
                "Unsupported static array index in bytecode core: ",
                expressionChars(index),
            ));

        const elementSize = cast(uint) staticArraySize(index.type);
        const offset = cast(ushort)
            (baseOffset + indexInteger.toInteger * elementSize);
        const elementType = index.type.toBasetype.ty == TY.Tsarray
            ? ScalarType.void_
            : scalarType(index.type);
        return StaticArrayElement(offset, elementType);
    }

    // The inline frame base offset of a static-array sub-expression: either a
    // static-array local (a VarExp) or a further static-array index.
    private ushort staticArrayBaseOffset(Expression expression) {
        import std.conv: text;

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _staticArrayLocals)
                    return *existing;

        if (auto index = expression.isIndexExp)
            return locateStaticArrayElement(index).offset;

        throw new Exception(text(
            "Unsupported static array access in bytecode core: ",
            expressionChars(expression),
        ));
    }

    // Locate a static-array element, or null if `index` is not an access into
    // a known static-array local (so other index forms fall through).
    private StaticArrayElement* tryStaticArrayElement(
        IndexExp index,
    ) {
        if (!indexesStaticArray(index.e1))
            return null;

        auto result = new StaticArrayElement;
        *result = locateStaticArrayElement(index);
        return result;
    }

    private bool indexesStaticArray(Expression expression) {
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                return (declaration in _staticArrayLocals) !is null;

        if (auto index = expression.isIndexExp)
            return indexesStaticArray(index.e1);

        return false;
    }

    private Operand compileStaticArrayElementAssign(
        in StaticArrayElement element,
        Expression rhs,
    ) {
        import std.conv: text;

        const value = compileExpression(rhs);
        if (value.type != element.type)
            throw new Exception(text(
                "Unsupported static array element assignment in bytecode core: ",
                expressionChars(rhs),
            ));

        _code ~= Instruction(
            Op.copy,
            element.offset,
            value.offset,
            cast(ushort) size(element.type),
        );
        return Operand(element.offset, element.type);
    }

    // `matrix[] = [elem, elem+1]`: the whole-array slice of a multidimensional
    // static array assigned a row literal whose type matches the array's
    // element type. Compile the row once into the first row's storage, then
    // copy it into each remaining row (DMD's block slice-assign broadcast).
    private Operand* tryStaticArrayBroadcast(
        SliceExp slice,
        Expression rhs,
    ) {
        auto variable = slice.e1.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        if (declaration is null)
            return null;

        auto slot = declaration in _staticArrayLocals;
        if (slot is null)
            return null;

        // Only the whole-array form `arr[]` (implicit bounds) is needed.
        if (slice.lwr !is null || slice.upr !is null)
            return null;

        auto literal = rhs.isArrayLiteralExp;
        if (literal is null)
            return null;

        // The row literal's type must match the array's element type for a
        // block broadcast; otherwise it is an element-wise assignment.
        auto elementType = declaration.type.toBasetype.nextOf;
        if (elementType is null ||
            rhs.type is null ||
            !sameType(rhs.type, elementType))
            return null;

        const rowSize = cast(uint) staticArraySize(elementType);
        compileStaticArrayLiteral(*slot, elementType, literal);

        const rowCount = cast(uint) (staticArraySize(declaration.type) / rowSize);
        foreach (row; 1 .. rowCount)
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (*slot + row * rowSize),
                *slot,
                cast(ushort) rowSize,
            );

        auto result = new Operand;
        *result = Operand.init;
        return result;
    }

    // Compile an array literal directly into an inline static-array slot,
    // writing each element into its `index * elementSize` offset. Only a
    // one-dimensional literal of scalar elements is needed today.
    private void compileStaticArrayLiteral(
        in ushort offset,
        Type arrayType,
        ArrayLiteralExp literal,
    ) {
        import std.conv: text;

        auto elementType = arrayType.toBasetype.nextOf;
        const elementScalar = scalarType(elementType);
        const elementSize = cast(uint) size(elementScalar);

        if (literal.elements is null)
            throw new Exception(text(
                "Unsupported static array literal in bytecode core: ",
                expressionChars(literal),
            ));

        foreach (elementIndex; 0 .. literal.elements.length) {
            const value = compileExpression((*literal.elements)[elementIndex]);
            if (value.type != elementScalar)
                throw new Exception(text(
                    "Unsupported static array literal element in bytecode core: ",
                    expressionChars(literal),
                ));

            _code ~= Instruction(
                Op.copy,
                cast(ushort) (offset + elementIndex * elementSize),
                value.offset,
                cast(ushort) elementSize,
            );
        }
    }

    // The inline frame offset of a static-array local denoted by an
    // expression (through any casts), or null if it is not one.
    private ushort* staticArrayOffsetOf(Expression expression) {
        if (auto cast_ = expression.isCastExp)
            return staticArrayOffsetOf(cast_.e1);

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _staticArrayLocals)
                    return existing;

        return null;
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
                const slot = cast(ushort)
                    (argumentArea + layout.offsets[argumentIndex]);

                // A `ref` argument passes the caller-frame offset of the
                // referenced local, not its value: the machine dereferences it
                // on entry and writes the slot back to it on return.
                if (layout.isReference[argumentIndex]) {
                    const reference =
                        referenceOffset((*call.arguments)[argumentIndex]);
                    _code ~= Instruction(
                        Op.loadConstant,
                        slot,
                        constantIndex(reference),
                        cast(ushort) size(ScalarType.uint_),
                    );
                    continue;
                }

                const operand =
                    compileExpression((*call.arguments)[argumentIndex]);
                _code ~= Instruction(
                    Op.copy,
                    slot,
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

    // The caller-frame offset of a scalar `ref` argument: the slot of the
    // local being passed by reference. Only a plain local lvalue is supported.
    private ushort referenceOffset(Expression argument) {
        import std.conv: text;

        if (auto variable = argument.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _locals)
                    return *existing;

        throw new Exception(text(
            "Unsupported ref argument in bytecode core: ",
            expressionChars(argument),
        ));
    }

    // Recognise std.math builtins via DMD's own classification and emit a VM
    // intrinsic instead of a call. The destination is typed by the call's
    // static return type; pow(double, double), for example, may be real.
    private Operand* compileBuiltinCall(
        CallExp call,
        FuncDeclaration function_,
    ) {
        import quickbite.backends.bytecode.builtins:
            BytecodeBuiltin, bytecodeBuiltinArgumentCount,
            tryBytecodeBuiltin;
        import std.conv: text;

        BytecodeBuiltin builtin;
        if (!tryBytecodeBuiltin(function_, builtin))
            return null;

        if (call.arguments is null ||
            call.arguments.length != bytecodeBuiltinArgumentCount(builtin))
            throw new Exception(text(
                "Unsupported bytecode builtin call arguments: ",
                expressionChars(call),
            ));

        const resultType = scalarType(callType(call));
        with (BytecodeBuiltin) final switch (builtin) {
            case fabs:
                return heapOperand(compileSameTypeUnaryIntrinsic(
                    call,
                    resultType,
                    Op.fabsFloat,
                    Op.fabsDouble,
                    Op.fabsReal,
                ));

            case isInfinity:
                return heapOperand(compileUnaryIntrinsic(
                    call,
                    ScalarType.bool_,
                    Op.isInfinityFloat,
                    Op.isInfinityDouble,
                    Op.isInfinityReal,
                ));

            case isNaN:
                return heapOperand(compileUnaryIntrinsic(
                    call,
                    ScalarType.bool_,
                    Op.isNaNFloat,
                    Op.isNaNDouble,
                    Op.isNaNReal,
                ));

            case pow:
                return heapOperand(compilePowIntrinsic(call, resultType));

            case signbit:
                if (resultType != ScalarType.int_)
                    throw new Exception(text(
                        "Unsupported signbit result in bytecode core: ",
                        expressionChars(call),
                    ));

                return heapOperand(compileUnaryIntrinsic(
                    call,
                    resultType,
                    Op.signbitFloat,
                    Op.signbitDouble,
                    Op.signbitReal,
                ));

            case sqrt:
                return heapOperand(compileSameTypeUnaryIntrinsic(
                    call,
                    resultType,
                    Op.sqrtFloat,
                    Op.sqrtDouble,
                    Op.sqrtReal,
                ));
        }
    }

    private Operand compileSameTypeUnaryIntrinsic(
        CallExp call,
        in ScalarType resultType,
        in Op floatOp,
        in Op doubleOp,
        in Op realOp,
    ) {
        import std.conv: text;

        const argument = compileExpression((*call.arguments)[0]);
        if (argument.type != resultType)
            throw new Exception(text(
                "Unsupported bytecode builtin return type: ",
                expressionChars(call),
            ));

        return emitUnaryIntrinsic(
            argument,
            resultType,
            unaryFloatingOp(argument.type, floatOp, doubleOp, realOp, call),
        );
    }

    private Operand compileUnaryIntrinsic(
        CallExp call,
        in ScalarType resultType,
        in Op floatOp,
        in Op doubleOp,
        in Op realOp,
    ) {
        const argument = compileExpression((*call.arguments)[0]);
        return emitUnaryIntrinsic(
            argument,
            resultType,
            unaryFloatingOp(argument.type, floatOp, doubleOp, realOp, call),
        );
    }

    private Operand emitUnaryIntrinsic(
        in Operand argument,
        in ScalarType resultType,
        in Op op,
    ) @safe pure {
        const offset = allocate(resultType);
        _code ~= Instruction(op, offset, argument.offset);
        return Operand(offset, resultType);
    }

    private Operand compilePowIntrinsic(
        CallExp call,
        in ScalarType resultType,
    ) {
        import std.conv: text;

        const base = compileExpression((*call.arguments)[0]);
        const exponent = compileExpression((*call.arguments)[1]);
        if (base.type != exponent.type)
            throw new Exception(text(
                "Unsupported pow operands in bytecode core: ",
                expressionChars(call),
            ));

        const op = powOp(base.type, resultType, call);
        const offset = allocate(resultType);
        _code ~= Instruction(op, offset, base.offset, exponent.offset);
        return Operand(offset, resultType);
    }

    private Operand* heapOperand(in Operand operand) @safe {
        auto result = new Operand;
        *result = operand;
        return result;
    }

    private Op unaryFloatingOp(
        in ScalarType type,
        in Op floatOp,
        in Op doubleOp,
        in Op realOp,
        CallExp call,
    ) {
        import std.conv: text;

        final switch (type) with (ScalarType) {
            case float_:
                return floatOp;
            case double_:
                return doubleOp;
            case real_:
                return realOp;
            case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_,
                long_, ulong_, char_, wchar_, dchar_:
                throw new Exception(text(
                    "Unsupported bytecode builtin operand: ",
                    expressionChars(call),
                ));
        }
    }

    private Op powOp(
        in ScalarType argumentType,
        in ScalarType resultType,
        CallExp call,
    ) {
        import std.conv: text;

        if (argumentType == ScalarType.float_ &&
            resultType == ScalarType.float_)
            return Op.powFloat;

        if (argumentType == ScalarType.double_ &&
            resultType == ScalarType.double_)
            return Op.powDouble;

        if (argumentType == ScalarType.double_ &&
            resultType == ScalarType.real_)
            return Op.powDoubleToReal;

        if (argumentType == ScalarType.real_ &&
            resultType == ScalarType.real_)
            return Op.powReal;

        throw new Exception(text(
            "Unsupported pow type in bytecode core: ",
            expressionChars(call),
        ));
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

        if (compileLiteralTrueAssert(assert_))
            return;

        if (compileLiteralFalseAssert(assert_))
            return;

        if (compileLoweredComparisonAssert(assert_))
            return;

        if (compileVerbatimStringAssert(assert_))
            return;

        if (compileExplicitMessageAssert(assert_))
            return;

        throw new Exception(text(
            "Unsupported assert in bytecode core: ",
            expressionChars(assert_),
        ));
    }

    // DMD can fold `assert(1 == 1)` to `assert(true)`. Compiled code emits no
    // runtime check for that case, so the VM emits no bytecode either. A
    // statically-true condition makes any message dead code: it is never
    // evaluated, so `assert(true, message)` likewise emits nothing regardless
    // of `assert_.msg`.
    private bool compileLiteralTrueAssert(AssertExp assert_) {
        auto integer = assert_.e1.isIntegerExp;
        return integer !is null && integer.toInteger != 0;
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

        _code ~= Instruction(_inUnittestEntry ? Op.haltUnittest : Op.halt);
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

    // `assert(cond, message)` with an explicit string message that is neither
    // a `_d_assert_fail` call nor the verbatim-logical-expression form: throw
    // the message string itself on failure. The message is either a `StringExp`
    // literal (`assert(1 == 2, "oops")`, folded to `assert(false, "oops")`) or a
    // (cast-wrapped) `VarExp` over a `string` local whose slot already holds the
    // slice descriptor. A compile-time-false condition (`assert(false, msg)`)
    // throws unconditionally; otherwise the condition is compiled and the throw
    // is skipped when it holds.
    private bool compileExplicitMessageAssert(AssertExp assert_) {
        if (assert_.msg is null)
            return false;

        // `_d_assert_fail` calls and the verbatim-logical string belong to the
        // earlier branches; an explicit message is anything else.
        if (isAssertFailCall(assert_.msg))
            return false;

        auto message = messageSlice(assert_.msg);
        if (message is null)
            return false;

        auto integer = assert_.e1.isIntegerExp;
        if (integer !is null && integer.toInteger == 0) {
            const slice = *message;
            _code ~= Instruction(Op.throwString, slice.offset);
            return true;
        }

        const condition = compileExpression(assert_.e1);
        const skipJump = emitJumpIfTrue(condition);
        const slice = *message;
        _code ~= Instruction(Op.throwString, slice.offset);
        patchJump(skipJump);
        return true;
    }

    // The string-slice operand for an explicit assert message, or null if the
    // expression is not an explicit string message. A `StringExp` literal lands
    // in the data segment via compileStringLiteral; a (cast-wrapped) `VarExp`
    // over a `string` local reuses the local's slice slot.
    private Operand* messageSlice(Expression expression) {
        if (auto cast_ = expression.isCastExp)
            return messageSlice(cast_.e1);

        if (auto string_ = expression.isStringExp) {
            auto slice = new Operand;
            *slice = compileStringLiteral(string_);
            return slice;
        }

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (declaration in _stringLocals)
                    if (auto existing = declaration in _locals)
                        return new Operand(*existing, ScalarType.void_, true);

        return null;
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

        // A `_d_assert_fail` call carries at least the operator-string
        // argument. A bare `message()` call (e.g. `assert(true, message)`)
        // has no arguments and is not this shape, so indexing `[0]` would
        // crash; bail out before touching the empty argument list.
        if (call.arguments.length == 0)
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

        // The 3-argument form carries a relational operator and both operands;
        // `==`, `!=`, `<`, `<=`, `>`, `>=` are asserted on their comparison and
        // render the inverted relation on failure.
        if (call.arguments.length != 3)
            return false;

        const op = operatorText(operator);
        switch (op) {
            case "==", "!=", "<", "<=", ">", ">=":
                break;
            default:
                return false;
        }

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
            comparisonAssertOp(op, lhs.type),
            condition,
            lhs.offset,
            rhs.offset,
        );

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic(op, lhs.offset, rhs.offset, lhs.type);
        _code ~= Instruction(
            Op.assertTrue,
            condition,
            cast(ushort) diagnostic,
        );
        return true;
    }

    // `assert(intExpr)` / `assert(boolExpr)`: throw when the operand evaluates
    // to zero; the failure renders "<value> != true", so the diagnostic carries
    // only the operand. A `bool` operand renders "false != true".
    private bool compileNonzeroAssert(Expression expression) {
        import std.conv: text;

        const operand = compileExpression(expression);
        if (operand.type != ScalarType.int_ && operand.type != ScalarType.bool_)
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

    private ushort realConstantIndex(RealExp real_) @safe {
        const index = _program.realConstants.length;
        if (index > ushort.max)
            throw new Exception("Too many real constants in bytecode core");

        _program.realConstants ~= realBytes(real_);
        return cast(ushort) index;
    }

    private ParameterLayout parameterLayout(FuncDeclaration function_) {
        ParameterLayout layout;
        if (function_.parameters is null)
            return layout;

        foreach (parameterIndex; 0 .. function_.parameters.length) {
            auto parameter = (*function_.parameters)[parameterIndex];

            // A scalar `ref` parameter has a frame slot sized for the
            // referenced value, just like a value parameter; the difference is
            // only in how the argument word is passed and written back.
            const type = scalarType(parameter.type);
            const alignment = size(type);
            layout.blockSize =
                (layout.blockSize + alignment - 1) & ~(alignment - 1);
            layout.offsets ~= cast(ushort) layout.blockSize;
            layout.isReference ~= parameter.isReference;
            if (parameter.isReference)
                layout.refParameters ~=
                    RefParameter(cast(ushort) layout.blockSize, type);
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
            case Tfloat80:
                return ScalarType.real_;
            default:
                throw new Exception(text(
                    "Unsupported type in bytecode core: ",
                    typeChars(type),
                ));
        }
    }
}

private struct ParameterLayout {
    import quickbite.backends.bytecode.core.program: RefParameter;

    ushort[] offsets;
    bool[] isReference; // per parameter: true for a scalar `ref` parameter
    RefParameter[] refParameters; // the slot and type of each `ref` parameter
    uint blockSize;
}

private struct Operand {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType type;
    bool isString; // when set, `offset` holds a string-slice descriptor
}

private bool isPlainExceptionNew(imported!"dmd.expression".NewExp new_) {
    if (new_ is null ||
        new_.placement !is null ||
        new_.thisexp !is null ||
        new_.arguments is null ||
        new_.arguments.length == 0)
        return false;

    auto classType = new_.newtype is null
        ? null
        : new_.newtype.toBasetype.isTypeClass;
    if (classType is null || classType.sym is null)
        return false;

    return classType.sym.ident !is null &&
        classType.sym.ident.toString == "Exception";
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

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingEqualOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    final switch (type) with (ScalarType) {
        case float_: return Op.equalFloat;
        case double_: return Op.equalDouble;
        case real_: return Op.equalReal;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, char_, wchar_, dchar_:
            assert(0, "Not a floating-point type.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingNotEqualOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    final switch (type) with (ScalarType) {
        case float_: return Op.notEqualFloat;
        case double_: return Op.notEqualDouble;
        case real_: return Op.notEqualReal;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, char_, wchar_, dchar_:
            assert(0, "Not a floating-point type.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingComparisonOp(
    in imported!"dmd.tokens".EXP operator,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType
        operandType,
) @safe @nogc nothrow pure {
    import dmd.tokens: EXP;

    switch (operator) with (EXP) {
        case lessThan: return floatingLessThanOp(operandType);
        case lessOrEqual: return floatingLessOrEqualOp(operandType);
        case greaterThan: return floatingGreaterThanOp(operandType);
        case greaterOrEqual: return floatingGreaterOrEqualOp(operandType);
        default: assert(0, "Unsupported floating comparison operator.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingLessThanOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    final switch (type) with (ScalarType) {
        case float_: return Op.lessThanFloat;
        case double_: return Op.lessThanDouble;
        case real_: return Op.lessThanReal;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, char_, wchar_, dchar_:
            assert(0, "Not a floating-point type.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingLessOrEqualOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    final switch (type) with (ScalarType) {
        case float_: return Op.lessOrEqualFloat;
        case double_: return Op.lessOrEqualDouble;
        case real_: return Op.lessOrEqualReal;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, char_, wchar_, dchar_:
            assert(0, "Not a floating-point type.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingGreaterThanOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    final switch (type) with (ScalarType) {
        case float_: return Op.greaterThanFloat;
        case double_: return Op.greaterThanDouble;
        case real_: return Op.greaterThanReal;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, char_, wchar_, dchar_:
            assert(0, "Not a floating-point type.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingGreaterOrEqualOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    final switch (type) with (ScalarType) {
        case float_: return Op.greaterOrEqualFloat;
        case double_: return Op.greaterOrEqualDouble;
        case real_: return Op.greaterOrEqualReal;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, char_, wchar_, dchar_:
            assert(0, "Not a floating-point type.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingAssertOp(
    in string operator,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    switch (operator) {
        case "==": return floatingEqualOp(type);
        case "!=": return floatingNotEqualOp(type);
        case "<": return floatingLessThanOp(type);
        case "<=": return floatingLessOrEqualOp(type);
        case ">": return floatingGreaterThanOp(type);
        case ">=": return floatingGreaterOrEqualOp(type);
        default: assert(0, "Unsupported floating assert operator.");
    }
}

// The comparison opcode for a relational `_d_assert_fail` operator. Floating
// operands use numeric comparison opcodes, including `real`; integer `==`
// reuses the width-tagged equality opcodes, and integer `>=` selects the
// unsigned form for unsigned operands.
private imported!"quickbite.backends.bytecode.core.program".Op
    comparisonAssertOp(
    in string operator,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType
        operandType,
) @safe pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType, isSigned,
        size;

    if (isFloating(operandType))
        return floatingAssertOp(operator, operandType);

    switch (operator) {
        case "==": return equalOp(size(operandType));
        case "!=": return Op.notEqual4;
        case "<": return Op.lessThan4;
        case "<=": return Op.lessOrEqual4;
        case ">": return Op.greaterThan4;
        case ">=":
            return isSigned(operandType)
                ? Op.greaterOrEqual4
                : Op.greaterOrEqualUnsigned4;
        default: assert(0, "Unsupported comparison-assert operator.");
    }
}

// A `_d_assert_fail` lowering: a `CallExp` carrying a leading operator
// `StringExp` and the asserted operands. The explicit-message branch defers
// these to compileLoweredComparisonAssert.
private bool isAssertFailCall(imported!"dmd.expression".Expression expression) {
    auto call = expression.isCallExp;
    if (call is null || call.arguments is null || call.arguments.length == 0)
        return false;

    return (*call.arguments)[0].isStringExp !is null;
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

    return type == ScalarType.float_ ||
        type == ScalarType.double_ ||
        type == ScalarType.real_;
}

private bool isEightByteInteger(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    return type == ScalarType.long_ || type == ScalarType.ulong_;
}

// The integer widths the compound-assign `addInt4`/`addInt8` opcodes cover.
private bool isIntegerScalar(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    return type == ScalarType.int_ ||
        type == ScalarType.uint_ ||
        type == ScalarType.long_ ||
        type == ScalarType.ulong_;
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

private ubyte[real.sizeof] realBytes(
    imported!"dmd.expression".RealExp real_,
) @safe {
    union RealBytes {
        real value;
        ubyte[real.sizeof] bytes;
    }

    RealBytes raw;
    raw.value = cast(real) realValue(real_);
    return raw.bytes;
}

private real realValue(imported!"dmd.expression".RealExp real_) @trusted {
    // RealExp.value is a dmd longdouble (real_t); reading it is pure data
    // access with no aliasing, but the dmd field accessor is not @safe.
    return cast(real) real_.value;
}

// DMD has no `isCmpExp`; a CmpExp is a BinExp whose op is a relational
// operator.
private imported!"dmd.expression".CmpExp comparisonExpression(
    imported!"dmd.expression".Expression expression,
) {
    import dmd.expression: CmpExp;
    import dmd.tokens: EXP;

    switch (expression.op) with (EXP) {
        case lessThan, lessOrEqual, greaterThan, greaterOrEqual:
            return cast(CmpExp) expression;
        default:
            return null;
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

// The inline byte size and alignment of a static array, taken from DMD's
// computed layout rather than reconstructed.
private ulong staticArraySize(imported!"dmd.mtype".Type type) {
    import dmd.typesem: size;
    return size(type.toBasetype);
}

private uint staticArrayAlign(imported!"dmd.mtype".Type type) {
    return type.toBasetype.alignsize;
}

// The string literal an expression denotes (through any casts), or null.
private imported!"dmd.expression".StringExp stringLiteralOf(
    imported!"dmd.expression".Expression expression,
) {
    if (auto cast_ = expression.isCastExp)
        return stringLiteralOf(cast_.e1);

    return expression.isStringExp;
}

private bool sameType(
    imported!"dmd.mtype".Type lhs,
    imported!"dmd.mtype".Type rhs,
) {
    return lhs.toBasetype.equals(rhs.toBasetype);
}

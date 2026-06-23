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
        RefParameter, ResultType, ScalarType, isSigned, size,
        sliceDescriptorSize, stringSliceSize;
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AddAssignExp, AddrExp, ArrayLengthExp, ArrayLiteralExp,
        AssocArrayLiteralExp, AssertExp,
        AssignExp, BinExp, BlitExp, CallExp, CastExp, CatElemAssignExp, CatExp,
        CmpExp, CondExp, ConstructExp, DivExp, DotVarExp, Expression, IndexExp,
        LogicalExp, MulExp,
        FuncExp,
        NegExp, NewExp, NotExp, OrExp, PostExp, PtrExp, RealExp, SliceExp,
        StringExp, StructLiteralExp, SymOffExp;
    import dmd.arraytypes: Expressions;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Statement;

    private Program* _program;
    private FuncDeclaration[] _functions;
    private size_t[FuncDeclaration] _functionIndices;
    private Instruction[] _code;
    private uint _frameOffset;
    // The high-water mark of `_frameOffset` across the current function body.
    // `frameSize` is computed from this peak so transient scopes that reuse
    // frame space (and any `_frameOffset` rewind) never under-size the frame.
    private uint _peakFrameOffset;
    private ushort[VarDeclaration] _locals;
    private bool[VarDeclaration] _stringLocals; // locals holding a string slice
    // Locals whose slot is a static array `T[N]` stored inline in the frame;
    // the value records the slot offset for indexing and block copies.
    private ushort[VarDeclaration] _staticArrayLocals;
    // Locals whose slot holds a dynamic-array slice descriptor {ptr, length};
    // the value records the slot offset and the element scalar type, giving the
    // element size for indexing and heap allocation.
    private DynamicArrayLocal[VarDeclaration] _dynamicArrayLocals;
    // Locals whose slot holds a raw `size_t` pointer value (`T* p`); the value
    // records the pointed-at element scalar, giving the stride for arithmetic,
    // indexing, dereference, and slicing.
    private ScalarType[VarDeclaration] _pointerLocals;
    // Locals whose slot holds an 8-byte associative-array handle (`int[int]`):
    // a 1-based index into the machine's VM-owned map table, 0 until created.
    private bool[VarDeclaration] _assocArrayLocals;
    // Locals (and by-value parameters) whose slot is a struct `S` stored inline
    // in the frame at its DMD-computed size and alignment; the value records the
    // base offset and the struct declaration, giving each field's offset and
    // type for field access and whole-struct block copies.
    private StructLocal[VarDeclaration] _structLocals;
    // Delegate locals (`auto d = () => this.field;`): a 16-byte slot holding a
    // `{functionIndex, context}` pair and the captured lambda, so `d()` reads
    // the index and context back and dispatches indirectly.
    private DelegateLocal[VarDeclaration] _delegateLocals;
    // Locals whose 8-byte slot holds a raw `size_t` pointer to a heap-allocated
    // struct block (`S* p = new S(...)`); the value is the struct declaration,
    // giving each field's offset and type so `p.field` resolves to a load/store
    // through the pointer at `ptr + field.offset`.
    private imported!"dmd.dstruct".StructDeclaration[VarDeclaration]
        _structPointerLocals;
    // The receiver of the method currently being compiled, if any: the base
    // offset of the hidden `this` block in the frame plus the struct
    // declaration, so an unqualified `this.field` resolves against it.
    private StructLocal _thisLocal;
    private bool _hasThis;
    // Synthetic `with` pointers (`S* __withSym = &subject`): each maps to the
    // inline frame base of its struct subject, so `(*__withSym).field` in the
    // body resolves to `subjectBase + field.offset`.
    private ushort[VarDeclaration] _withDerefBases;
    // Resolved label positions (instruction index) by identifier, plus the
    // indices of `jump` instructions awaiting a still-unseen forward label.
    private size_t[const(void)*] _labelTargets;
    private size_t[][const(void)*] _pendingGotos;
    // The loops currently being compiled, innermost last. Each holds the `jump`
    // indices awaiting the loop's exit (`break`) and its continue point
    // (`continue`), plus the label ident of an enclosing `label:` for labeled
    // `break`/`continue`. `break`/`continue` append a jump to the matching
    // loop's list; the loop patches both lists once its targets are known.
    private LoopContext[] _loopStack;
    // While inlining a `_aApply*` foreach body (a delegate returning int, where
    // a nonzero return signals `break`), the indices of `jumpIfTrue` jumps that
    // exit the transcode loop on such a return; null when not in an apply body.
    private size_t[]* _applyBodyExits;
    // The switches currently being compiled, innermost last; each maps its cases
    // and default to body indices for the dispatch chain (see SwitchContext).
    private SwitchContext[] _switchStack;
    // The `try`/`finally` scopes whose try body is currently being compiled,
    // innermost last. A `goto`/`break`/`continue`/fall-through leaving a try body
    // must run that scope's `finally` block first; the exited scopes' finally
    // blocks are re-emitted inline on the exit edge (see `runExitedFinally`).
    private TryFinallyContext[] _tryFinallyStack;
    // The label ident of a `label:` that immediately wraps the next loop, so the
    // loop records it for labeled `break`/`continue`; null otherwise.
    private const(void)* _pendingLoopLabel;
    private size_t[ulong] _constantIndices;
    // Scalar locals' frame offsets, kept across functions (unlike `_locals`,
    // which is reset per function). A nested struct's method reads a captured
    // enclosing local through the struct's context pointer, which records the
    // enclosing frame's base; this map recovers the captured local's offset
    // within that frame at the point the method (a separate function) compiles.
    private ushort[VarDeclaration] _capturedOffsets;
    // The frame offset of the current method's hidden `this` block when it is a
    // nested struct whose first field (`vthis`) holds the enclosing-frame
    // context index; 0 otherwise. Set while compiling such a method.
    private bool _hasNestedContext;
    private bool _inUnittestEntry; // true only while compiling the entry
                                   // function when it is a UnitTestDeclaration
    private ResultType _currentReturnType; // result type of the function whose
                                           // body is currently being compiled

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
        _dynamicArrayLocals = null;
        _pointerLocals = null;
        _assocArrayLocals = null;
        _delegateLocals = null;
        _structLocals = null;
        _structPointerLocals = null;
        _hasThis = false;
        _hasNestedContext = false;
        _thisLocal = StructLocal.init;
        _withDerefBases = null;
        _labelTargets = null;
        _pendingGotos = null;
        _loopStack = null;
        _switchStack = null;
        _tryFinallyStack = null;
        _pendingLoopLabel = null;
        _applyBodyExits = null;

        import dmd.astenums: TY;

        _currentReturnType = _program.functions[index].returnType;
        const layout = parameterLayout(function_);
        _frameOffset = layout.blockSize;
        _peakFrameOffset = layout.blockSize;

        // A struct method receives a hidden `this` block by reference at the
        // start of the argument area; record its base so `this.field` resolves.
        if (layout.hasThis) {
            _hasThis = true;
            _thisLocal = StructLocal(
                layout.thisOffset, thisStructDeclaration(function_),
            );
            _hasNestedContext = _thisLocal.declaration !is null &&
                _thisLocal.declaration.isNested;
        }
        if (function_.parameters !is null)
            foreach (parameterIndex; 0 .. function_.parameters.length) {
                auto parameter = (*function_.parameters)[parameterIndex];
                const offset = layout.offsets[parameterIndex];

                // A non-string dynamic-array parameter is a slice descriptor,
                // tracked like a dynamic-array local rather than a scalar slot.
                if (parameter.type.toBasetype.ty == TY.Tarray &&
                    !isStringType(parameter.type))
                {
                    _dynamicArrayLocals[parameter] = DynamicArrayLocal(
                        offset, dynamicArrayElementType(parameter.type),
                    );
                    continue;
                }

                // A by-value struct parameter is an inline block, tracked like a
                // struct local so field access resolves against its base offset.
                if (parameter.type.toBasetype.ty == TY.Tstruct) {
                    _structLocals[parameter] = StructLocal(
                        offset, structDeclarationOf(parameter.type),
                    );
                    continue;
                }

                // A `string` parameter holds an 8-byte slice descriptor, tracked
                // like a string local so it reads back as a slice, not a scalar.
                if (isStringType(parameter.type)) {
                    _locals[parameter] = offset;
                    _stringLocals[parameter] = true;
                    continue;
                }

                _locals[parameter] = offset;
            }

        compileStatement(function_.fbody);
        // The fall-through return of a void body; unreachable after an
        // explicit return statement.
        _code ~= Instruction(Op.ret);

        _program.functions[index].code = _code;
        _program.functions[index].frameSize = (_peakFrameOffset + 15) & ~15u;
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
            functionResultType(function_),
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

        // A `DtorExpStatement` is the destructor call DMD inserts at a scope
        // exit (`~this()` on a local going out of scope). It is an ExpStatement
        // subclass but `isExpStatement` matches only the plain `Exp` kind, so
        // handle it explicitly: compile its destructor-call expression.
        if (auto dtor = statement.isDtorExpStatement) {
            if (dtor.exp !is null)
                compileExpression(dtor.exp);
            return;
        }

        if (auto expressionStatement = statement.isExpStatement) {
            if (expressionStatement.exp !is null)
                compileExpression(expressionStatement.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            // Inside an inlined `_aApply*` foreach body the delegate returns
            // `int`: 0 to continue, nonzero to `break`. Translate the return
            // into a conditional exit of the transcode loop instead of a `ret`.
            if (_applyBodyExits !is null) {
                const value = compileExpression(return_.exp);
                *_applyBodyExits ~= _code.length;
                _code ~= Instruction(Op.jumpIfTrue, value.offset);
                return;
            }

            if (_currentReturnType.isArray) {
                const descriptor = arrayDescriptorOffset(
                    _currentReturnType.elementType, return_.exp,
                );
                _code ~= Instruction(Op.ret, descriptor);
                return;
            }

            // `return structValue;`: the result block lives at the struct
            // operand's inline base; `ret` copies its `structSize` bytes back to
            // the caller's destination.
            if (_currentReturnType.isStruct) {
                const base = structOperandOffset(return_.exp);
                _code ~= Instruction(Op.ret, base);
                return;
            }

            // A constructor's implicit `return this;` has a void result here
            // (no struct is returned by value yet); emit a bare `ret`.
            if (return_.exp is null ||
                (!_currentReturnType.isString &&
                    _currentReturnType.scalar == ScalarType.void_)) {
                _code ~= Instruction(Op.ret);
                return;
            }

            const operand = compileExpression(return_.exp);
            _code ~= Instruction(Op.ret, operand.offset);
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            compileIfStatement(if_);
            return;
        }

        if (auto for_ = statement.isForStatement) {
            compileForStatement(for_);
            return;
        }

        if (auto do_ = statement.isDoStatement) {
            compileDoStatement(do_);
            return;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            compileUnrolledLoopStatement(unrolled);
            return;
        }

        if (auto throw_ = statement.isThrowStatement) {
            compileThrow(throw_);
            return;
        }

        if (auto tryFinally = statement.isTryFinallyStatement) {
            compileTryFinallyStatement(tryFinally);
            return;
        }

        if (auto tryCatch = statement.isTryCatchStatement) {
            compileTryCatchStatement(tryCatch);
            return;
        }

        if (auto with_ = statement.isWithStatement) {
            compileWithStatement(with_);
            return;
        }

        if (auto label = statement.isLabelStatement) {
            compileLabelStatement(label);
            return;
        }

        if (auto goto_ = statement.isGotoStatement) {
            compileGotoStatement(goto_);
            return;
        }

        if (auto break_ = statement.isBreakStatement) {
            compileBreakStatement(break_);
            return;
        }

        if (auto continue_ = statement.isContinueStatement) {
            compileContinueStatement(continue_);
            return;
        }

        if (auto switch_ = statement.isSwitchStatement) {
            compileSwitchStatement(switch_);
            return;
        }

        if (auto case_ = statement.isCaseStatement) {
            compileCaseStatement(case_);
            return;
        }

        if (auto default_ = statement.isDefaultStatement) {
            compileDefaultStatement(default_);
            return;
        }

        if (auto gotoCase = statement.isGotoCaseStatement) {
            compileGotoCaseStatement(gotoCase);
            return;
        }

        if (auto gotoDefault = statement.isGotoDefaultStatement) {
            compileGotoDefaultStatement(gotoDefault);
            return;
        }

        // DMD appends a `SwitchErrorStatement` to a `final switch` body as the
        // runtime guard for an unmatched value. A final switch over an enum is
        // exhaustive, so the dispatch always matches and this guard is
        // unreachable; emit no code for it.
        if (statement.isSwitchErrorStatement !is null)
            return;

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

    // `with (subject) body`. For a struct subject, DMD binds a synthetic
    // `S* __withSym = &subject` and rewrites the body's unqualified fields to
    // `(*__withSym).field`; record the subject's inline base so those resolve
    // against it. For an enum/type subject there is no runtime binding (DMD has
    // already constant-folded the members), so just compile the body.
    private void compileWithStatement(
        imported!"dmd.statement".WithStatement with_,
    ) {
        if (with_.wthis !is null)
            if (auto base = structBaseOffsetOrNull(with_.exp))
                _withDerefBases[with_.wthis] = *base;

        if (with_._body !is null)
            compileStatement(with_._body);
    }

    // `label:` — record the label's instruction index and patch any forward
    // `goto`s already emitted for it to jump here.
    private void compileLabelStatement(
        imported!"dmd.statement".LabelStatement label,
    ) {
        const target = _code.length;
        _labelTargets[cast(const(void)*) label.ident] = target;

        if (auto pending = cast(const(void)*) label.ident in _pendingGotos) {
            foreach (index; *pending) {
                _code[index].a = cast(ushort) target;
                _code[index].b = cast(ushort) target;
            }
            _pendingGotos.remove(cast(const(void)*) label.ident);
        }

        // A `label:` wrapping a loop names it for labeled `break`/`continue`:
        // hand the ident to the loop so it records it on its loop context.
        if (label.statement !is null) {
            // DMD wraps a labeled `for` as `label: { init?; for }`; the label
            // governs the contained loop, so hand it the ident. The flag
            // survives the leading statements (they never touch it) and the
            // loop consumes it as it enters.
            if (containsLoop(label.statement))
                _pendingLoopLabel = cast(const(void)*) label.ident;
            compileStatement(label.statement);
        }
    }

    private static bool containsLoop(Statement statement) pure nothrow {
        if (statement is null)
            return false;
        if (statement.isForStatement !is null)
            return true;
        if (auto scope_ = statement.isScopeStatement)
            return containsLoop(scope_.statement);
        if (auto compound = statement.isCompoundStatement)
            foreach (childIndex; 0 .. compound.statements.length)
                if (containsLoop((*compound.statements)[childIndex]))
                    return true;
        return false;
    }

    // `goto label;` — an unconditional `jump`. If the label is already known,
    // patch the target now; otherwise record the jump for the label to fix up.
    private void compileGotoStatement(
        imported!"dmd.statement".GotoStatement goto_,
    ) {
        // A goto leaving one or more enclosing `try` bodies must run their
        // `finally` blocks first. Innermost-first, run each scope whose try body
        // does not define the target label (the goto stays within the first
        // scope that does, and within every scope outside it).
        const target = cast(const(void)*) goto_.ident;
        size_t exited;
        foreach_reverse (index; 0 .. _tryFinallyStack.length) {
            if (target in _tryFinallyStack[index].labels)
                break;
            ++exited;
        }
        runExitedFinally(exited);

        const index = emitJump;
        const key = cast(const(void)*) goto_.ident;

        if (auto known = key in _labelTargets) {
            _code[index].a = cast(ushort) *known;
            _code[index].b = cast(ushort) *known;
            return;
        }

        _pendingGotos[key] ~= index;
    }

    // `try { body } finally { final }`: compile the body, then the finally on the
    // fall-through edge. A `goto`/`break`/`continue` that leaves the body runs
    // the finally inline first (see `runExitedFinally`); since no test throws
    // across a `try`/`finally`, no runtime handler is needed for the throw edge.
    private void compileTryFinallyStatement(
        imported!"dmd.statement".TryFinallyStatement tryFinally,
    ) {
        TryFinallyContext context;
        context.finalbody = tryFinally.finalbody;
        context.loopDepth = _loopStack.length;
        if (tryFinally._body !is null)
            collectLabels(tryFinally._body, context.labels);
        _tryFinallyStack ~= context;

        if (tryFinally._body !is null)
            compileStatement(tryFinally._body);

        _tryFinallyStack.length -= 1;

        // The normal fall-through exit also runs the finally.
        if (tryFinally.finalbody !is null)
            compileStatement(tryFinally.finalbody);
    }

    // Re-emit the `finally` blocks of the innermost `count` `try`/`finally`
    // scopes, innermost-first, on an exit edge (a `goto`/`break`/`continue`
    // leaving those scopes). Each finally is compiled with the exited scopes
    // removed from the stack so a transfer inside a finally targets only the
    // surviving outer scopes.
    private void runExitedFinally(in size_t count) {
        foreach (step; 0 .. count) {
            const index = _tryFinallyStack.length - 1 - step;
            auto finalbody = _tryFinallyStack[index].finalbody;
            if (finalbody is null)
                continue;
            auto saved = _tryFinallyStack;
            _tryFinallyStack = _tryFinallyStack[0 .. index];
            compileStatement(finalbody);
            _tryFinallyStack = saved;
        }
    }

    // The labels defined lexically within a statement subtree, used to decide
    // whether a `goto` stays inside an enclosing `try` body. Recurses through
    // every nested statement container so a label inside a switch/loop/if within
    // the try body is found (a `goto` to it does not exit the try).
    private static void collectLabels(
        imported!"dmd.statement".Statement statement,
        ref bool[const(void)*] labels,
    ) {
        if (statement is null)
            return;
        if (auto label = statement.isLabelStatement) {
            labels[cast(const(void)*) label.ident] = true;
            collectLabels(label.statement, labels);
        } else if (auto scope_ = statement.isScopeStatement)
            collectLabels(scope_.statement, labels);
        else if (auto compound = statement.isCompoundStatement) {
            foreach (childIndex; 0 .. compound.statements.length)
                collectLabels((*compound.statements)[childIndex], labels);
        } else if (auto unrolled = statement.isUnrolledLoopStatement) {
            if (unrolled.statements !is null)
                foreach (childIndex; 0 .. unrolled.statements.length)
                    collectLabels((*unrolled.statements)[childIndex], labels);
        } else if (auto if_ = statement.isIfStatement) {
            collectLabels(if_.ifbody, labels);
            collectLabels(if_.elsebody, labels);
        } else if (auto for_ = statement.isForStatement) {
            collectLabels(for_._init, labels);
            collectLabels(for_._body, labels);
        } else if (auto while_ = statement.isWhileStatement)
            collectLabels(while_._body, labels);
        else if (auto do_ = statement.isDoStatement)
            collectLabels(do_._body, labels);
        else if (auto switch_ = statement.isSwitchStatement)
            collectLabels(switch_._body, labels);
        else if (auto case_ = statement.isCaseStatement)
            collectLabels(case_.statement, labels);
        else if (auto default_ = statement.isDefaultStatement)
            collectLabels(default_.statement, labels);
        else if (auto with_ = statement.isWithStatement)
            collectLabels(with_._body, labels);
        else if (auto tryFinally = statement.isTryFinallyStatement) {
            collectLabels(tryFinally._body, labels);
            collectLabels(tryFinally.finalbody, labels);
        } else if (auto tryCatch = statement.isTryCatchStatement) {
            collectLabels(tryCatch._body, labels);
            if (tryCatch.catches !is null)
                foreach (catchIndex; 0 .. tryCatch.catches.length)
                    collectLabels(
                        (*tryCatch.catches)[catchIndex].handler, labels,
                    );
        }
    }

    // `try { body } catch (Exception) { handler }`: register a runtime handler
    // at the catch body, compile the try body, then on normal completion pop the
    // handler and skip the catch. A `throwString` inside the body redirects to
    // the handler (popping it). Scoped to the test surface: a single catch whose
    // type is `Exception` (or a base of it) and whose variable is unnamed.
    private void compileTryCatchStatement(
        imported!"dmd.statement".TryCatchStatement tryCatch,
    ) {
        import std.conv: text;

        if (tryCatch.catches is null || tryCatch.catches.length != 1)
            throw new Exception(text(
                "Unsupported try/catch in bytecode core: ",
                tryCatch.catches is null ? 0 : tryCatch.catches.length,
                " catch clauses",
            ));

        auto catch_ = (*tryCatch.catches)[0];

        // Reserve the handler-registration instruction; its operand (the catch
        // body's instruction index) is patched once the body is emitted.
        const pushIndex = _code.length;
        _code ~= Instruction(Op.pushHandler);

        if (tryCatch._body !is null)
            compileStatement(tryCatch._body);

        // Normal completion of the try body: drop the handler and skip the catch.
        _code ~= Instruction(Op.popHandler);
        const skipCatch = emitJump;

        // The handler entry: a throw inside the body lands here with the handler
        // already popped.
        _code[pushIndex].a = cast(ushort) _code.length;
        if (catch_.handler !is null)
            compileStatement(catch_.handler);

        patchJump(skipCatch);
    }

    // A `for (init; condition; increment) body` loop, the lowering of `foreach`
    // over a dynamic array. Compile the init once, then loop: test the condition
    // and exit when false, run the body, run the increment, and jump back.
    private void compileForStatement(
        imported!"dmd.statement".ForStatement for_,
    ) {
        if (for_._init !is null)
            compileStatement(for_._init);

        const conditionIndex = _code.length;
        const exitJump = for_.condition is null
            ? size_t.max
            : emitJumpIfFalse(compileExpression(for_.condition));

        // Enter the loop: any `label:` immediately wrapping it (consumed here)
        // names this context for labeled `break`/`continue`.
        LoopContext context;
        context.label = _pendingLoopLabel;
        _pendingLoopLabel = null;
        _loopStack ~= context;

        if (for_._body !is null)
            compileStatement(for_._body);

        // `continue` lands on the increment, then falls through to the re-test.
        foreach (index; _loopStack[$ - 1].continuePatches)
            patchJumpTo(index, _code.length);
        if (for_.increment !is null)
            compileExpression(for_.increment);

        _code ~= Instruction(Op.jump, cast(ushort) conditionIndex);

        // `break` lands just past the loop, as does the condition's exit jump.
        foreach (index; _loopStack[$ - 1].breakPatches)
            patchJump(index);
        _loopStack.length -= 1;

        if (exitJump != size_t.max)
            patchJump(exitJump);
    }

    // A `do body while (condition)` loop: the body runs once before any test.
    // Compile the body, then the continue point (the condition test), which
    // jumps back to the body start while true and falls through to exit.
    private void compileDoStatement(
        imported!"dmd.statement".DoStatement do_,
    ) {
        const bodyIndex = _code.length;

        // Enter the loop: any `label:` immediately wrapping it (consumed here)
        // names this context for labeled `break`/`continue`.
        LoopContext context;
        context.label = _pendingLoopLabel;
        _pendingLoopLabel = null;
        _loopStack ~= context;

        if (do_._body !is null)
            compileStatement(do_._body);

        // `continue` lands on the condition test, then re-runs the body if true.
        foreach (index; _loopStack[$ - 1].continuePatches)
            patchJumpTo(index, _code.length);

        const condition = compileExpression(do_.condition);
        _code ~= Instruction(
            Op.jumpIfTrue, condition.offset, cast(ushort) bodyIndex,
        );

        // `break` lands just past the loop.
        foreach (index; _loopStack[$ - 1].breakPatches)
            patchJump(index);
        _loopStack.length -= 1;
    }

    // A `foreach` over a compile-time expression tuple, which DMD has already
    // unrolled into one body copy per tuple element (no runtime iteration
    // variable). `break` exits the whole unrolled block; `continue` jumps to the
    // next unrolled iteration. Each iteration is one statement in `statements`,
    // so a `continue` is patched to the start of the following statement (or to
    // the exit for the last) and `break` to the exit, reusing the loop stack.
    private void compileUnrolledLoopStatement(
        imported!"dmd.statement".UnrolledLoopStatement unrolled,
    ) {
        LoopContext context;
        context.label = _pendingLoopLabel;
        _pendingLoopLabel = null;
        _loopStack ~= context;

        if (unrolled.statements !is null)
            foreach (index; 0 .. unrolled.statements.length) {
                // `continue` in the previous iteration lands on this one's start.
                foreach (patch; _loopStack[$ - 1].continuePatches)
                    patchJumpTo(patch, _code.length);
                _loopStack[$ - 1].continuePatches = null;

                compileStatement((*unrolled.statements)[index]);
            }

        // A `continue` in the final iteration, plus every `break`, lands past the
        // whole unrolled block.
        foreach (patch; _loopStack[$ - 1].continuePatches)
            patchJump(patch);
        foreach (patch; _loopStack[$ - 1].breakPatches)
            patchJump(patch);
        _loopStack.length -= 1;
    }

    // `break;` / `break label;` — emit an exit `jump` and record it on the
    // matching loop's break list for the loop to patch to its exit point.
    private void compileBreakStatement(
        imported!"dmd.statement".BreakStatement break_,
    ) {
        // Unlabeled `break` exits the innermost breakable statement, which
        // includes a switch; a switch's context is a break target like a loop.
        const loop = targetLoopIndex(break_.ident, false);
        runExitedFinally(finallyScopesInsideLoop(loop));
        _loopStack[loop].breakPatches ~= emitJump;
    }

    // `continue;` / `continue label;` — emit a jump and record it on the
    // matching loop's continue list for the loop to patch to its increment.
    private void compileContinueStatement(
        imported!"dmd.statement".ContinueStatement continue_,
    ) {
        // Unlabeled `continue` skips a switch and targets the enclosing loop.
        const loop = targetLoopIndex(continue_.ident, true);
        runExitedFinally(finallyScopesInsideLoop(loop));
        _loopStack[loop].continuePatches ~= emitJump;
    }

    // The count of innermost `try`/`finally` scopes a `break`/`continue` to the
    // loop at `loopIndex` exits: those pushed while inside that loop (their
    // recorded loop depth exceeds the target loop's index).
    private size_t finallyScopesInsideLoop(in size_t loopIndex)
        @safe @nogc nothrow pure
    {
        size_t count;
        foreach_reverse (index; 0 .. _tryFinallyStack.length) {
            if (_tryFinallyStack[index].loopDepth <= loopIndex)
                break;
            ++count;
        }
        return count;
    }

    // The loop a `break`/`continue` targets: for an unlabeled transfer the
    // innermost context (skipping switches when `forContinue`, since a switch is
    // not a continue target), or the context whose `label:` matches a labeled
    // one.
    private size_t targetLoopIndex(
        imported!"dmd.identifier".Identifier ident,
        in bool forContinue,
    ) @safe pure {
        import std.conv: text;

        if (ident is null) {
            foreach_reverse (index; 0 .. _loopStack.length)
                if (!(forContinue && _loopStack[index].isSwitch))
                    return index;
            assert(0, "No enclosing breakable statement in bytecode core.");
        }

        const key = cast(const(void)*) ident;
        foreach_reverse (index; 0 .. _loopStack.length)
            if (_loopStack[index].label is key)
                return index;

        throw new Exception(text(
            "Unresolved loop label in bytecode core: ", ident.toString,
        ));
    }

    // `switch (condition) { cases }` over an integer/enum selector. Lower it to
    // the body followed by a linear dispatch chain (an if-chain of equality
    // tests against each case value, falling through to `default` or past the
    // switch). The body is emitted before the dispatch so each case body's
    // instruction index is known when the dispatch (and any `goto case`/`goto
    // default`) is patched. Entry jumps over the body to the dispatch.
    private void compileSwitchStatement(
        imported!"dmd.statement".SwitchStatement switch_,
    ) {
        // DMD lowers a `string` switch to `object.__switch!(C, caseStrings...)`,
        // whose call returns the matched case's table index (or -1), and rewrites
        // its cases to those integer indices. Lower the selector ourselves to a
        // string-equality chain producing that index, then the integer dispatch
        // below handles the rest unchanged.
        const selector = stringSwitchSelector(switch_.condition) !is null
            ? compileStringSwitchSelector(switch_.condition.isCallExp)
            : compileExpression(switch_.condition);

        // Jump over the body to the dispatch chain at the end.
        const entryJump = emitJump;

        // A switch is a break target (not a continue target); reuse the loop
        // stack so `break` inside a case lands past the switch.
        LoopContext loopContext;
        loopContext.label = _pendingLoopLabel;
        loopContext.isSwitch = true;
        _pendingLoopLabel = null;
        _loopStack ~= loopContext;

        SwitchContext switchContext;
        _switchStack ~= switchContext;

        if (switch_._body !is null)
            compileStatement(switch_._body);

        // The end of a case body falls through to the next case body; the final
        // body must skip the dispatch chain entirely.
        const bodyEndJump = emitJump;

        // The dispatch chain: test the selector against each case value, jumping
        // to that case body on a match; fall through to default or past switch.
        patchJump(entryJump);
        foreach (caseIndex; 0 .. switch_.cases.length) {
            auto case_ = (*switch_.cases)[caseIndex];
            const target = _switchStack[$ - 1].caseIndices[cast(const(void)*) case_];
            const matches = allocate(ScalarType.bool_);
            const value = compileExpression(case_.exp);
            _code ~= Instruction(
                equalOp(size(selector.type)), matches, selector.offset, value.offset,
            );
            _code ~= Instruction(Op.jumpIfTrue, matches, cast(ushort) target);
        }

        // No case matched: a `final switch` covers every value (no default), so
        // its dispatch always matches and falls through unreachably.
        if (switch_.hasDefault)
            _code ~= Instruction(
                Op.jump, cast(ushort) _switchStack[$ - 1].defaultIndex,
            );

        patchJump(bodyEndJump);

        // Resolve `goto case`/`goto default` jumps now that every body index and
        // the default index are known.
        foreach (target, patches; _switchStack[$ - 1].gotoCasePatches)
            foreach (patch; patches)
                patchJumpTo(patch, _switchStack[$ - 1].caseIndices[target]);
        foreach (patch; _switchStack[$ - 1].gotoDefaultPatches)
            patchJumpTo(patch, _switchStack[$ - 1].defaultIndex);

        // `break` inside a case lands here, just past the switch.
        foreach (index; _loopStack[$ - 1].breakPatches)
            patchJump(index);
        _loopStack.length -= 1;
        _switchStack.length -= 1;
    }

    // The `object.__switch!(C, caseStrings...)` template instance behind a
    // lowered string-switch condition, or null if the condition is not one.
    // Its expression arguments are the case strings, indexed positionally.
    private imported!"dmd.dtemplate".TemplateInstance stringSwitchSelector(
        Expression condition,
    ) {
        import dmd.id: Id;

        auto call = condition.isCallExp;
        if (call is null)
            return null;
        auto variable = call.e1.isVarExp;
        if (variable is null)
            return null;
        auto function_ = variable.var.isFuncDeclaration;
        if (function_ is null)
            return null;
        auto instance = function_.parent.isTemplateInstance;
        if (instance is null || instance.name !is Id.__switch)
            return null;
        return instance;
    }

    // Lower `object.__switch!(C, "s0", "s1", ...)(selector)` to a string-equality
    // chain producing the matched case's table index (or -1) in an `int` slot:
    // the integer dispatch then matches it against the cases' integer indices.
    // The case strings are the template instance's expression arguments (the
    // leading argument is the element type); their position is the index DMD
    // assigned each rewritten `CaseStatement.exp`, so positional matching is
    // exact regardless of the table's ordering.
    private Operand compileStringSwitchSelector(
        imported!"dmd.expression".CallExp call,
    ) {
        import dmd.dtemplate: isExpression;

        auto instance = stringSwitchSelector(call);
        const result = allocate(ScalarType.int_);
        _code ~= Instruction(
            Op.loadConstant, result, constantIndex(cast(ulong) -1), 4,
        );

        const selector =
            compileExpression((*call.arguments)[0]); // the runtime string.

        size_t[] matchedJumps;
        int index = 0;
        foreach (argument; *instance.tiargs) {
            auto caseString =
                isExpression(argument) is null ? null
                : isExpression(argument).isStringExp;
            if (caseString is null) // the leading element-type argument.
                continue;

            const literal = compileStringLiteral(caseString);
            const matches = allocate(ScalarType.bool_);
            _code ~= Instruction(
                Op.stringSliceEqual, matches, selector.offset, literal.offset,
            );
            const skip = emitJumpIfFalse(Operand(matches, ScalarType.bool_));
            _code ~= Instruction(
                Op.loadConstant, result, constantIndex(cast(ulong) index), 4,
            );
            matchedJumps ~= emitJump;
            patchJump(skip);
            ++index;
        }
        foreach (jump; matchedJumps)
            patchJump(jump);

        return Operand(result, ScalarType.int_);
    }

    // A `case value:` label: record its body's instruction index for the
    // dispatch and any `goto case value`, then compile the case body.
    private void compileCaseStatement(
        imported!"dmd.statement".CaseStatement case_,
    ) {
        _switchStack[$ - 1].caseIndices[cast(const(void)*) case_] = _code.length;
        if (case_.statement !is null)
            compileStatement(case_.statement);
    }

    // A `default:` label: record its body's instruction index, then compile it.
    private void compileDefaultStatement(
        imported!"dmd.statement".DefaultStatement default_,
    ) {
        _switchStack[$ - 1].defaultIndex = _code.length;
        if (default_.statement !is null)
            compileStatement(default_.statement);
    }

    // `goto case value;` (or `goto case;`, the next case) — an unconditional
    // jump to the resolved target case body. DMD resolves the target into `.cs`,
    // so no value re-matching is needed even for a runtime selector. The target
    // index is only known once the whole body is compiled, so record the jump.
    private void compileGotoCaseStatement(
        imported!"dmd.statement".GotoCaseStatement gotoCase,
    ) {
        _switchStack[$ - 1].gotoCasePatches[cast(const(void)*) gotoCase.cs] ~=
            emitJump;
    }

    // `goto default;` — an unconditional jump to the default case body, patched
    // once the default's index is known.
    private void compileGotoDefaultStatement(
        imported!"dmd.statement".GotoDefaultStatement gotoDefault,
    ) {
        _switchStack[$ - 1].gotoDefaultPatches ~= emitJump;
    }

    private void patchJumpTo(in size_t index, in size_t target) @safe pure {
        _code[index].a = cast(ushort) target;
        _code[index].b = cast(ushort) target;
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
                    if (auto element = declaration in _pointerLocals)
                        return Operand(
                            *existing, ScalarType.ulong_, false, true, *element,
                        );
                    return Operand(*existing, scalarType(declaration.type));
                }

            // A captured enclosing local read inside a nested struct's method
            // (`return seed;`): resolve it through the hidden `this` block's
            // context pointer (vthis at offset 0), which holds the enclosing
            // frame's base index.
            if (_hasNestedContext)
                if (auto declaration = variable.var.isVarDeclaration)
                    if (auto captured = declaration in _capturedOffsets)
                        return loadCapturedLocal(declaration, *captured);

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

            // A nested type declaration (`struct Inner { ... }` inside a
            // function body) is a compile-time construct that emits no runtime
            // code; semantic has already resolved it.
            if (declaration.declaration.isAggregateDeclaration !is null)
                return Operand.init;

            // A static nested function declaration (`static int f() { ... }`
            // inside a function body) introduces no runtime storage. Its body
            // is compiled lazily when `&f` or `f()` first reaches it, so the
            // declaration itself emits no code.
            if (declaration.declaration.isFuncDeclaration !is null)
                return Operand.init;

            throw new Exception(text(
                "Unsupported declaration in bytecode core: ",
                expressionChars(expression),
            ));
        }

        if (auto comma = expression.isCommaExp) {
            compileExpression(comma.e1);
            return compileExpression(comma.e2);
        }

        // A `null` pointer literal (the `(bounds, null)` false branch of `m[k]`):
        // an 8-byte zero pointer slot. The throw in the comma's first operand
        // aborts before this is read.
        if (expression.isNullExp !is null) {
            const offset =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            _code ~= Instruction(
                Op.loadConstant, offset, constantIndex(0),
                cast(ushort) size_t.sizeof,
            );
            return Operand(
                offset, ScalarType.ulong_, false, true, ScalarType.int_,
            );
        }

        if (auto cast_ = expression.isCastExp)
            return compileCastExpression(cast_);

        if (auto add = expression.isAddExp)
            return compileAddExpression(add);

        if (auto or = expression.isOrExp)
            return compileOrExpression(or);

        if (auto multiply = expression.isMulExp)
            return compileMultiplyExpression(multiply);

        if (auto divide = expression.isDivExp)
            return compileDivideExpression(divide);

        if (auto comparison = comparisonExpression(expression))
            return compileComparisonExpression(comparison);

        if (auto logical = expression.isLogicalExp)
            return compileLogicalExpression(logical);

        if (auto addAssign = expression.isAddAssignExp)
            return compileAddAssignExpression(addAssign);

        // `arr.length = n` (and other lowered assignments) arrive as a
        // LoweredAssignExp, whose op is not `EXP.assign`, so isAssignExp misses
        // it; it is still an AssignExp with the original lvalue in e1.
        if (auto lowered = expression.isLoweredAssignExp)
            return compileAssignExpression(lowered);

        if (auto assign = expression.isAssignExp)
            return compileAssignExpression(assign);

        // A field construction inside a constructor body (`this.value = seed +
        // 2`) arrives as a ConstructExp/BlitExp (op `construct`/`blit`), not an
        // AssignExp; route a struct-field-lvalue form through the assign path.
        // A `checkaction=context` assert temporary (`__assertOp3 = make(5)[0]`)
        // is a scalar construction onto a `VarExp` local, also routed here.
        if (auto construct = expression.isConstructExp)
            if (construct.e1.isDotVarExp !is null ||
                construct.e1.isVarExp !is null)
                return compileAssignExpression(construct);
        if (auto blit = expression.isBlitExp)
            if (blit.e1.isDotVarExp !is null ||
                blit.e1.isVarExp !is null)
                return compileAssignExpression(blit);

        // `arr ~= x` (append element) arrives as a CatElemAssignExp (op
        // `concatenateElemAssign`); detect by op, not name. Whole-array
        // `arr ~= other` (op `concatenateAssign`) is a different node and is
        // not handled here.
        if (auto append = expression.isCatElemAssignExp)
            return compileAppendElement(append);

        if (auto equal = expression.isEqualExp)
            return compileEqualExpression(equal);

        // `c ? t : f`: DMD's `m[k]` lowering produces `slot ? slot : (bounds,
        // null)`, a pointer-valued conditional whose false branch raises "Range
        // violation". Compile it as a branch writing one slot on both paths.
        if (auto conditional = expression.isCondExp)
            return compileConditionalExpression(conditional);

        if (auto call = expression.isCallExp)
            return compileCall(call);

        if (auto assert_ = expression.isAssertExp) {
            compileAssert(assert_);
            return Operand.init;
        }

        if (auto post = expression.isPostExp)
            return compilePostIncrement(post);

        if (auto length = expression.isArrayLengthExp)
            return compileArrayLength(length);

        if (auto address = expression.isAddrExp) {
            if (auto pointer = tryAddressOfElement(address))
                return *pointer;
            if (auto pointer = tryAddressOfLocal(address))
                return *pointer;
            // `&f` of a free or static nested function: the function-pointer
            // value is the callee's VM function index in a size_t slot.
            if (auto variable = address.e1.isVarExp)
                if (auto function_ = variable.var.isFuncDeclaration)
                    return functionPointer(function_);
        }

        // `&local` arrives as a `SymOffExp` (symbol plus byte offset): the
        // address of a scalar local's frame slot, yielding an `int*`-style
        // pointer operand.
        if (auto symOff = expression.isSymOffExp) {
            if (auto pointer = tryAddressOfSymbol(symOff))
                return *pointer;
            // `&f` can also arrive as a `SymOffExp` over a function symbol;
            // the function-pointer value is its VM function index.
            if (auto function_ = symOff.var.isFuncDeclaration)
                return functionPointer(function_);
        }

        if (auto deref = expression.isPtrExp)
            return compilePointerDereference(deref);

        if (auto index = expression.isIndexExp) {
            if (auto element = tryPointerIndex(index))
                return *element;
            if (auto element = tryDynamicArrayIndex(index))
                return *element;
            return compileStaticArrayIndex(index);
        }

        // `base.field`: read a struct field from its inline frame offset. A
        // pointer field (`tracker.postblits`) yields a pointer operand over its
        // raw 8-byte address; a scalar field its scalar value.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot)) {
                if (isPointerType(field.type))
                    return Operand(
                        field.offset, ScalarType.ulong_, false, true,
                        scalarType(field.type.toBasetype.nextOf),
                    );
                return Operand(field.offset, scalarType(field.type));
            }

        // `p.field` through a heap struct pointer: load the field at `ptr +
        // field.offset`.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructPointerField(dot))
                return loadStructPointerField(*field);

        if (auto literal = expression.isStructLiteralExp)
            return compileStructLiteralOperand(literal);

        // `new S(args)`: heap-allocate a struct block and yield a `S*` pointer.
        if (auto newExp = expression.isNewExp)
            if (auto pointer = tryNewStruct(newExp))
                return *pointer;

        throw new Exception(text(
            "Unsupported expression in bytecode core: ",
            expressionChars(expression),
        ));
    }

    // A struct literal as an rvalue (a struct-valued expression, e.g. a by-value
    // call argument `read(Value(...))`): materialise the block into a fresh slot.
    private Operand compileStructLiteralOperand(StructLiteralExp literal) {
        const offset = allocateStructBlock(literal.type);
        zeroFrameBlock(offset, cast(uint) staticArraySize(literal.type));
        compileStructLiteralInto(offset, literal);
        return Operand(offset, ScalarType.void_);
    }

    // Read an element of a static array at a compile-time-constant index. The
    // element lives at `slot + index * elementSize` inside the inline block;
    // a scalar element is returned directly, a sub-array element yields a
    // static-array operand for further indexing (`matrix[0][1]`).
    private Operand compileStaticArrayIndex(IndexExp index) {
        const located = locateStaticArrayElement(index);
        return Operand(located.offset, located.type);
    }

    // `i++` on an integer local or struct field: copy the old value to the
    // result slot, then add `e2` (the increment) to the lvalue's slot. Scoped
    // to integer lvalues, matching the compound-assignment path.
    private Operand compilePostIncrement(PostExp post) {
        import dmd.tokens: EXP;
        import std.conv: text;

        ushort lvalueSlot;
        auto lvalueType = ScalarType.void_;

        if (auto variable = post.e1.isVarExp) {
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto slot = declaration in _locals) {
                    lvalueSlot = *slot;
                    lvalueType = scalarType(declaration.type);
                }
        } else if (auto dot = post.e1.isDotVarExp) {
            // `this.pos++` / `box.pos++`: the field lives at its inline offset.
            if (auto field = tryStructField(dot)) {
                lvalueSlot = field.offset;
                lvalueType = scalarType(field.type);
            }
        }

        if (!isIntegerScalar(lvalueType))
            throw new Exception(text(
                "Unsupported post-increment in bytecode core: ",
                expressionChars(post),
            ));

        const result = allocate(lvalueType);
        _code ~= Instruction(
            Op.copy, result, lvalueSlot, cast(ushort) size(lvalueType),
        );

        // `PostExp.e2` is always the literal `1`; `post.op` (`plusPlus` vs
        // `minusMinus`) decides whether we add or subtract it.
        const increment = compileExpression(post.e2);
        const eightByte = lvalueType == ScalarType.long_ ||
            lvalueType == ScalarType.ulong_;
        const stepOp = post.op == EXP.minusMinus
            ? (eightByte ? Op.subInt8 : Op.subInt4)
            : (eightByte ? Op.addInt8 : Op.addInt4);
        _code ~= Instruction(stepOp, lvalueSlot, lvalueSlot, increment.offset);
        return Operand(result, lvalueType);
    }

    // `arr.length` reads the descriptor's length word (a `size_t`) into a fresh
    // slot.
    private Operand compileArrayLength(ArrayLengthExp length) {
        const descriptor = dynamicArrayDescriptor(length.e1);
        const offset = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, offset, descriptor.offset);
        return Operand(offset, ScalarType.ulong_);
    }

    // Read element `index` of a dynamic-array local, or null if `index` is not
    // an access into a known dynamic-array local.
    private Operand* tryDynamicArrayIndex(IndexExp index) {
        // `outer[i][j]` / `local[i]`: the indexed expression is (or materialises
        // to) a known dynamic-array descriptor. This also handles `outer[i]` of
        // an array-of-arrays, whose inner descriptor is materialised here.
        if (auto descriptor = dynamicArrayDescriptorOrNull(index.e1))
            return loadDynamicArrayElement(
                descriptor.offset, descriptor.elementType, index.e2,
            );

        // `makeArray(...)[i]`: the indexed expression is an array-valued call,
        // not a known local. Materialise its descriptor into a fresh slot and
        // index that.
        if (auto descriptorOffset = indexedArrayDescriptor(index.e1))
            return loadDynamicArrayElement(
                descriptorOffset.offset, descriptorOffset.elementType, index.e2,
            );

        return null;
    }

    // The slice descriptor for an array-valued expression that is not a known
    // dynamic-array local (today, an array-returning call), materialised into a
    // fresh frame slot; null otherwise.
    private DynamicArrayLocal* indexedArrayDescriptor(Expression expression) {
        if (dynamicArrayDescriptorOrNull(expression) !is null)
            return null;

        if (!isDynamicArrayArgument(expression))
            return null;

        const elementType = dynamicArrayElementType(expression.type);
        const offset = arrayDescriptorOffset(elementType, expression);
        auto result = new DynamicArrayLocal;
        *result = DynamicArrayLocal(offset, elementType);
        return result;
    }

    // Read element `indexExpr` of the dynamic-array descriptor at frame offset
    // `descriptorOffset`, returning the loaded scalar element.
    private Operand* loadDynamicArrayElement(
        in ushort descriptorOffset,
        in ScalarType elementType,
        Expression indexExpr,
    ) {
        const indexSlot = compileExpression(indexExpr);
        const elementSize = size(elementType);
        const offset = allocateBytes(elementSize, elementSize);
        _code ~= Instruction(
            indexLoadOp(elementSize),
            offset,
            descriptorOffset,
            indexSlot.offset,
        );

        auto result = new Operand;
        *result = Operand(offset, elementType);
        return result;
    }

    // The slice descriptor a dynamic-array expression denotes, throwing if it is
    // not a known dynamic-array local.
    private DynamicArrayLocal dynamicArrayDescriptor(Expression expression) {
        import std.conv: text;

        auto descriptor = dynamicArrayDescriptorOrNull(expression);
        if (descriptor is null)
            throw new Exception(text(
                "Unsupported dynamic array access in bytecode core: ",
                expressionChars(expression),
            ));
        return *descriptor;
    }

    private DynamicArrayLocal* dynamicArrayDescriptorOrNull(
        Expression expression,
    ) {
        import dmd.astenums: TY;

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                return declaration in _dynamicArrayLocals;

        // `base.field` where the field is a dynamic array: its slice descriptor
        // lives at `base + field.offset`, so indexing, `.length`, element-assign
        // and append reuse the existing dynamic-array machinery on that slot.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot))
                if (field.type.toBasetype.ty == TY.Tarray &&
                    !isStringType(field.type)) {
                    auto result = new DynamicArrayLocal;
                    *result = DynamicArrayLocal(
                        field.offset, dynamicArrayElementType(field.type),
                    );
                    return result;
                }

        // `outer[i]` where `outer` is an array-of-arrays (`int[][]`): indexing
        // yields an inner array. Materialise the inner descriptor into a fresh
        // slot and treat it as a (scalar-element) dynamic array.
        if (auto index = expression.isIndexExp)
            return innerArrayDescriptor(index);

        // An array-returning call (`m.keys` / `m.values`): materialise its
        // 16-byte slice-descriptor result into a fresh slot.
        if (expression.isCallExp !is null && isDynamicArrayArgument(expression)) {
            const elementType = dynamicArrayElementType(expression.type);
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileDynamicArrayInto(offset, elementType, expression);
            auto result = new DynamicArrayLocal;
            *result = DynamicArrayLocal(offset, elementType);
            return result;
        }

        return null;
    }

    // `outer[i]` of an array-of-arrays local: load the 16-byte inner descriptor
    // at index `i` into a fresh slot and return a DynamicArrayLocal over it; null
    // if `outer` is not an array-of-arrays local.
    private DynamicArrayLocal* innerArrayDescriptor(IndexExp index) {
        if (auto variable = index.e1.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto outer = declaration in _dynamicArrayLocals)
                    if (outer.elementIsArray) {
                        const indexSlot = compileExpression(index.e2);
                        const offset = allocateBytes(
                            sliceDescriptorSize, size_t.sizeof,
                        );
                        _code ~= Instruction(
                            Op.indexLoad16,
                            offset,
                            outer.offset,
                            indexSlot.offset,
                        );
                        auto result = new DynamicArrayLocal;
                        *result = DynamicArrayLocal(offset, outer.elementType);
                        return result;
                    }

        return null;
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

    // Write a compile-time string into the read-only data segment and emit the
    // slice descriptor, returning the descriptor's frame offset. Used for
    // synthesised diagnostic messages (`throwString`).
    private ushort compileStringLiteralBytes(in string text_) {
        import std.conv: text;

        const bytes = cast(const(ubyte)[]) text_;
        const dataOffset = _program.data.length;
        if (dataOffset > ushort.max || bytes.length > ushort.max)
            throw new Exception(text(
                "String literal too large for bytecode core: ", text_,
            ));
        _program.data ~= bytes;

        const offset = allocateBytes(stringSliceSize, 4);
        _code ~= Instruction(
            Op.loadStringSlice,
            offset,
            cast(ushort) dataOffset,
            cast(ushort) bytes.length,
        );
        return offset;
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

        // A struct `S` is a value type stored inline in the frame at its
        // DMD-computed size and alignment; each field lives at `base +
        // field.offset`.
        if (variable.type.toBasetype.ty == TY.Tstruct) {
            compileStructDeclaration(variable);
            return;
        }

        // A non-string dynamic array `T[]` holds a 16-byte slice descriptor
        // {ptr, length}; its backing memory lives on the VM-owned heap.
        if (variable.type.toBasetype.ty == TY.Tarray &&
            !isStringType(variable.type)) {
            compileDynamicArrayDeclaration(variable);
            return;
        }

        // An associative array `T[K]` holds an 8-byte handle into the machine's
        // VM-owned map table; `int[int]` is the only form the core lowers.
        if (variable.type.toBasetype.ty == TY.Taarray) {
            compileAssocArrayDeclaration(variable);
            return;
        }

        // A pointer local `T* p` holds a raw `size_t` address into VM-owned
        // heap; allocate an 8-byte slot, compile the pointer-valued initializer,
        // and copy its address word in.
        if (isPointerType(variable.type)) {
            compilePointerDeclaration(variable);
            return;
        }

        // A delegate local `auto d = () => this.field;` holds a
        // `{functionIndex, context}` pair; build it from the lambda literal.
        if (variable.type.toBasetype.ty == TY.Tdelegate) {
            compileDelegateDeclaration(variable);
            return;
        }

        // A `string` local holds an 8-byte slice descriptor (data offset and
        // length), not a scalar; allocate the descriptor width and copy the
        // initializer's slice into it.
        const isString = isStringType(variable.type);

        // A `string`/`wstring`/`dstring` initialised from a heap-producing
        // `.idup`/`.dup` is not a read-only data-segment slice but a 16-byte
        // {ptr, length} heap descriptor like an ordinary dynamic array. Store it
        // as a dynamic-array local (char/wchar/dchar element) so its code units
        // read back through the slice machinery; `_aApply*` UTF iteration over
        // such a string then reads the source as a normal slice descriptor.
        if (isString && variable._init !is null)
            if (auto expInit = variable._init.isExpInitializer)
                if (tryArrayDuplication(
                        initializerExpression(expInit.exp)) !is null) {
                    const heapElement =
                        dynamicArrayElementType(variable.type);
                    const heapOffset =
                        allocateBytes(sliceDescriptorSize, size_t.sizeof);
                    _dynamicArrayLocals[variable] =
                        DynamicArrayLocal(heapOffset, heapElement);
                    compileDynamicArrayInto(
                        heapOffset, heapElement,
                        initializerExpression(expInit.exp),
                    );
                    return;
                }

        const type = isString ? ScalarType.void_ : scalarType(variable.type);
        const slotSize = isString ? stringSliceSize : size(type);
        const offset = allocateBytes(slotSize, isString ? 4 : size(type));
        _locals[variable] = offset;
        _capturedOffsets[variable] = offset;
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

    // A pointer local `T* p` holds a raw `size_t` address in an 8-byte frame
    // slot. The initializer is a pointer-valued expression (`arr.ptr`,
    // `&arr[i]`, `p + n`, ...); copy its address word into the slot and record
    // the pointed-at element scalar for later stride and dereference.
    private void compilePointerDeclaration(VarDeclaration variable) {
        import std.conv: text;

        const offset = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            throw new Exception(text(
                "Unsupported initializer in bytecode core: ",
                declarationChars(variable),
            ));

        const pointer =
            compileExpression(initializerExpression(initializer.exp));
        if (!pointer.isPointer)
            throw new Exception(text(
                "Unsupported pointer initializer in bytecode core: ",
                declarationChars(variable),
            ));

        _locals[variable] = offset;
        _pointerLocals[variable] = pointer.pointerElement;
        // A `S* p = new S(...)` pointer addresses a heap struct block; record the
        // struct declaration so `p.field` resolves through the pointer.
        if (auto structDeclaration = structPointerDeclaration(variable.type))
            _structPointerLocals[variable] = structDeclaration;
        _code ~= Instruction(
            Op.copy, offset, pointer.offset, cast(ushort) size_t.sizeof,
        );
    }

    // A delegate value is a `{functionIndex, context}` pair: two `size_t` words,
    // the callee's VM function index and the captured context (the enclosing
    // method's `this` receiver frame offset, passed as the lambda's hidden `this`
    // block on the indirect call).
    private enum delegateValueSize = cast(uint) (2 * size_t.sizeof);

    // A delegate local `auto d = () => this.field;`: a 16-byte `{functionIndex,
    // context}` pair built from the lambda literal initializer, plus a tracking
    // entry recording the lambda so `d()` recovers its layout and result type.
    private void compileDelegateDeclaration(VarDeclaration variable) {
        import std.conv: text;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        auto literal = initializer is null
            ? null
            : initializerExpression(initializer.exp).isFuncExp;
        if (literal is null || literal.fd is null)
            throw new Exception(text(
                "Unsupported delegate initializer in bytecode core: ",
                declarationChars(variable),
            ));

        const offset = allocateBytes(delegateValueSize, size_t.sizeof);
        emitDelegateValue(offset, literal.fd);
        _delegateLocals[variable] = DelegateLocal(offset, literal.fd);
    }

    // Store a `{functionIndex, context}` delegate pair into the 16-byte slot at
    // `offset`: the lambda's registered VM index in the first word, the enclosing
    // method's `this` receiver offset (the captured context) in the second.
    private void emitDelegateValue(in ushort offset, FuncDeclaration lambda) {
        const index = registerFunction(lambda);
        _code ~= Instruction(
            Op.loadConstant, offset, constantIndex(index),
            cast(ushort) size_t.sizeof,
        );
        _code ~= Instruction(
            Op.loadConstant,
            cast(ushort) (offset + size_t.sizeof),
            constantIndex(_thisLocal.offset),
            cast(ushort) size_t.sizeof,
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

        // A static array of structs with elaborate members (`Tracker[2] s;`)
        // default-initializes by blitting the integer `0` over the inline block;
        // the frame starts zeroed, so this needs no code.
        if (auto blit = initializer.exp.isBlitExp)
            if (auto integer = blit.e2.isIntegerExp)
                if (integer.toInteger == 0) {
                    zeroFrameBlock(offset, totalSize);
                    return;
                }

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

        // `T[N] dest = src` for an element type with a postblit lowers to a
        // `_d_arrayctor` call: block-copy each element, then run its postblit.
        if (compileArrayConstructor(offset, variable.type, source))
            return;

        throw new Exception(text(
            "Unsupported static array initializer in bytecode core: ",
            declarationChars(variable),
        ));
    }

    // Intercept DMD's `_d_arrayctor(dest[], src[], null)` lowering of a
    // static-array copy whose element type has a postblit: block-copy the source
    // into `destination`, then run the element postblit on each copied element
    // (`this(this)` increments the test's postblit counter once per element).
    // False if `source` is not a `_d_arrayctor` call.
    private bool compileArrayConstructor(
        in ushort destination,
        Type arrayType,
        Expression source,
    ) {
        auto call = source.isCallExp;
        if (call is null)
            return false;
        auto function_ = callFunction(call);
        if (function_ is null || function_.ident is null ||
            function_.ident.toString != "_d_arrayctor")
            return false;
        if (call.arguments is null || call.arguments.length < 2)
            return false;

        auto elementType = arrayType.toBasetype.nextOf;
        const elementSize = cast(uint) staticArraySize(elementType);
        const count = cast(uint) staticArraySize(arrayType) / elementSize;

        // The source argument is `cast(T[])sourceArray`; the static-array base
        // is under the cast.
        auto sourceArray = (*call.arguments)[1];
        while (auto cast_ = sourceArray.isCastExp)
            sourceArray = cast_.e1;
        auto sourceOffset = staticArrayOffsetOf(sourceArray);
        if (sourceOffset is null)
            return false;

        _code ~= Instruction(
            Op.copy, destination, *sourceOffset,
            cast(ushort) (count * elementSize),
        );

        auto postblit = structDeclarationOf(elementType).postblit;
        if (postblit !is null)
            foreach (i; 0 .. count)
                runStructMethod(
                    cast(ushort) (destination + i * elementSize), postblit,
                );
        return true;
    }

    // `__ArrayDtor(arr[lo .. hi])`: run the element destructor on each element
    // of a static array's inline block (`source` / `copy` going out of scope),
    // in reverse element order (matching DMD), so each `~this()` runs once.
    private Operand compileArrayDtor(CallExp call) {
        import std.conv: text;

        if (call.arguments is null || call.arguments.length != 1)
            throw new Exception(text(
                "Unsupported array destructor in bytecode core: ",
                expressionChars(call),
            ));

        auto slice = (*call.arguments)[0].isSliceExp;
        if (slice is null)
            throw new Exception(text(
                "Unsupported array destructor in bytecode core: ",
                expressionChars(call),
            ));

        auto arrayOffset = staticArrayOffsetOf(slice.e1);
        if (arrayOffset is null)
            throw new Exception(text(
                "Unsupported array destructor in bytecode core: ",
                expressionChars(call),
            ));

        auto arrayType = slice.e1.type;
        auto elementType = arrayType.toBasetype.nextOf;
        const elementSize = cast(uint) staticArraySize(elementType);
        const count = cast(uint) staticArraySize(arrayType) / elementSize;

        auto dtor = structDeclarationOf(elementType).dtor;
        if (dtor !is null)
            foreach_reverse (i; 0 .. count)
                runStructMethod(
                    cast(ushort) (*arrayOffset + i * elementSize), dtor,
                );
        return Operand.init;
    }

    // A struct `S` local occupies `Type.size()` inline frame bytes at its
    // DMD-computed alignment, each field at `base + field.offset`. The block is
    // zeroed first (scalar fields default to 0, dynamic-array fields to an empty
    // `{null, 0}` descriptor), then a struct-literal initializer stores its
    // per-field values; a bare `S s;` leaves the zeroed block.
    private void compileStructDeclaration(VarDeclaration variable) {
        import std.conv: text;

        const offset = allocateStructBlock(variable.type);
        auto declaration = structDeclarationOf(variable.type);
        _structLocals[variable] = StructLocal(offset, declaration);

        zeroFrameBlock(offset, cast(uint) staticArraySize(variable.type));

        // A nested struct carries a hidden context pointer (`vthis`) at offset 0
        // recording the enclosing function's frame, so its methods can read
        // captured enclosing locals. The empty `S()` literal leaves it zero, so
        // set it here to the current frame base index.
        if (declaration.isNested)
            _code ~= Instruction(Op.frameBaseIndex, offset);

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            return;

        // A bare `S s;` default-initialises to `S.init`. DMD represents this as
        // a blit of the integer `0` over the whole struct; for the structs this
        // mode covers, `.init` is all-zero, which the zeroed block already
        // holds, so no further code is needed.
        if (auto blit = initializer.exp.isBlitExp)
            if (blit.e2.isIntegerExp !is null)
                return;

        auto source = initializerExpression(initializer.exp);

        // `auto box = Box(input)` with a constructor lowers to
        // `box = 0 , box.this(input)`: the block is already zeroed above, so run
        // the constructor call, which passes `box`'s block as the hidden `this`.
        if (auto comma = source.isCommaExp)
            if (auto call = comma.e2.isCallExp) {
                compileExpression(call);
                return;
            }

        if (auto literal = source.isStructLiteralExp) {
            compileStructLiteralInto(offset, literal);
            return;
        }

        // `S dest = src` / `S dest = make(...)`: a value-type block copy of the
        // whole struct from its inline base (a local, a nested field, or a
        // materialised struct-valued call) into the declared slot.
        bool resolved;
        const sourceOffset = structBaseOffsetOrMaterialise(source, resolved);
        if (resolved) {
            _code ~= Instruction(
                Op.copy,
                offset,
                sourceOffset,
                cast(ushort) staticArraySize(variable.type),
            );
            return;
        }

        throw new Exception(text(
            "Unsupported struct initializer in bytecode core: ",
            declarationChars(variable),
        ));
    }

    private ushort allocateStructBlock(Type type) {
        return allocateBytes(
            cast(uint) staticArraySize(type), staticArrayAlign(type),
        );
    }

    // Store each provided field of a struct literal into the inline block at
    // `base + field.offset`. Omitted trailing fields keep their zeroed default;
    // a static-array field initialised from a scalar broadcasts that scalar to
    // every element, and a dynamic-array field copies its slice descriptor.
    private void compileStructLiteralInto(
        in ushort base,
        StructLiteralExp literal,
    ) {
        import dmd.astenums: TY;

        if (literal.elements is null)
            return;

        foreach (index; 0 .. literal.elements.length) {
            auto element = (*literal.elements)[index];
            if (element is null || index >= literal.sd.fields.length)
                continue;

            auto field = literal.sd.fields[index];
            const fieldOffset = cast(ushort) (base + field.offset);
            auto fieldType = field.type;

            if (fieldType.toBasetype.ty == TY.Tstruct) {
                if (auto inner = element.isStructLiteralExp)
                    compileStructLiteralInto(fieldOffset, inner);
                continue;
            }

            if (fieldType.toBasetype.ty == TY.Tsarray) {
                storeStaticArrayField(fieldOffset, fieldType, element);
                continue;
            }

            if (fieldType.toBasetype.ty == TY.Tarray &&
                !isStringType(fieldType)) {
                compileDynamicArrayInto(
                    fieldOffset, dynamicArrayElementType(fieldType), element,
                );
                continue;
            }

            const value = compileExpression(element);
            _code ~= Instruction(
                Op.copy,
                fieldOffset,
                value.offset,
                cast(ushort) size(scalarType(fieldType)),
            );
        }
    }

    // Fill a static-array field `T[N]` from a struct-literal element: DMD passes
    // either a scalar to broadcast to every element or an array literal.
    private void storeStaticArrayField(
        in ushort fieldOffset,
        Type fieldType,
        Expression element,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        const elementScalar = scalarType(fieldType.toBasetype.nextOf);
        const elementSize = size(elementScalar);
        const count = cast(uint) staticArraySize(fieldType) / elementSize;

        // `S(seed)` broadcasts a scalar into all elements of the field.
        if (element.type.toBasetype.ty != TY.Tsarray) {
            const value = compileExpression(element);
            foreach (i; 0 .. count)
                _code ~= Instruction(
                    Op.copy,
                    cast(ushort) (fieldOffset + i * elementSize),
                    value.offset,
                    cast(ushort) elementSize,
                );
            return;
        }

        throw new Exception(text(
            "Unsupported static-array struct field in bytecode core: ",
            expressionChars(element),
        ));
    }

    // Write `byteCount` zero bytes into the frame at `offset`, in 8-byte chunks
    // (with a final narrower chunk), to default-init a struct block.
    private void zeroFrameBlock(in ushort offset, in uint byteCount) {
        const zero = compileSizeConstant(0);
        uint written = 0;
        while (written < byteCount) {
            const chunk = byteCount - written >= size_t.sizeof
                ? cast(uint) size_t.sizeof
                : byteCount - written;
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (offset + written),
                zero,
                cast(ushort) chunk,
            );
            written += chunk;
        }
    }

    // The DMD struct declaration of a struct-typed expression/type.
    private imported!"dmd.dstruct".StructDeclaration structDeclarationOf(
        Type type,
    ) {
        import dmd.mtype: TypeStruct;
        return (cast(TypeStruct) type.toBasetype).sym;
    }

    // The struct declaration a method's hidden `this` refers to, or null if the
    // function is not a struct member.
    private imported!"dmd.dstruct".StructDeclaration thisStructDeclaration(
        FuncDeclaration function_,
    ) {
        if (auto aggregate = function_.isThis())
            return aggregate.isStructDeclaration;

        // A nested `delegate` lambda that captures the enclosing method's `this`
        // (`() => this.field`) receives that `this` as its context. DMD models
        // the context as `vthis` (`__capture`, typed `void*`) and resolves the
        // captured field's `ThisExp.var` to the enclosing method's own `vthis`.
        // Give the lambda a hidden `this` block of the enclosing struct so the
        // ordinary receiver ABI carries the context and `this.field` resolves
        // against it.
        return capturedThisStructDeclaration(function_);
    }

    // The enclosing struct whose `this` a capturing delegate lambda reads, or
    // null if `function_` is not such a lambda. The lambda is nested in a struct
    // method and holds a context (`vthis`); the struct is the method's receiver
    // aggregate. Capturing an enclosing *local* (rather than `this`) is not yet
    // modelled -- such a lambda's `this.field` would still route here, but only
    // `this`-capturing lambdas are exercised; a local-capturing one would read
    // the wrong slot, which the leading-edge closures work must address.
    private imported!"dmd.dstruct".StructDeclaration
    capturedThisStructDeclaration(FuncDeclaration function_) {
        auto literal = function_.isFuncLiteralDeclaration;
        if (literal is null || function_.vthis is null)
            return null;

        auto enclosing = enclosingMethodOf(function_);
        if (enclosing is null)
            return null;
        if (auto aggregate = enclosing.isThis())
            return aggregate.isStructDeclaration;
        return null;
    }

    private FuncDeclaration enclosingMethodOf(FuncDeclaration function_) {
        if (auto parent = function_.toParent2)
            return parent.isFuncDeclaration;
        return null;
    }

    // The inline frame base offset of a struct lvalue (a struct local, by-value
    // struct parameter, or the method's hidden `this` receiver), or null if
    // `expression` is not a known struct.
    private ushort* structBaseOffsetOrNull(Expression expression) {
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _structLocals)
                    return &existing.offset;

        // Inside `with (subject)`, the body's unqualified fields appear as
        // `(*__withSym).field`, where `__withSym` is a synthetic `S*` bound to
        // `&subject`. Resolve the dereference back to the subject's inline base.
        if (auto deref = expression.isPtrExp)
            if (auto variable = deref.e1.isVarExp)
                if (auto declaration = variable.var.isVarDeclaration)
                    if (auto existing = declaration in _withDerefBases)
                        return existing;

        // An unqualified `this.field` inside a method resolves against the
        // hidden receiver block.
        if (_hasThis && expression.isThisExp !is null)
            return &_thisLocal.offset;

        return null;
    }

    // The frame offset of the receiver struct block of a method call
    // `receiver.method(args)`. The callee is a `DotVarExp` whose `e1` is the
    // receiver (a struct local, by-value parameter, or the enclosing `this`).
    private ushort methodReceiverOffset(CallExp call) {
        import std.conv: text;

        if (auto dot = call.e1.isDotVarExp)
            return structOperandOffset(dot.e1);

        // An IIFE `(() => this.field)()`: the callee is the lambda directly (a
        // FuncExp), and its hidden `this` block is the enclosing method's own
        // `this` receiver, already present in this frame.
        if (call.e1.isFuncExp !is null && _hasThis)
            return _thisLocal.offset;

        throw new Exception(text(
            "Unsupported method receiver in bytecode core: ",
            expressionChars(call),
        ));
    }

    // The inline frame offset of a struct-valued expression: a struct lvalue's
    // base, or a struct literal materialised into a fresh block.
    private ushort structOperandOffset(Expression expression) {
        import std.conv: text;

        bool resolved;
        const base = structBaseOffsetOrMaterialise(expression, resolved);
        if (resolved)
            return base;

        throw new Exception(text(
            "Unsupported struct value in bytecode core: ",
            expressionChars(expression),
        ));
    }

    // A located struct field: its inline frame offset and DMD type.
    private static struct StructField {
        ushort offset;
        Type type;
    }

    // Resolve `base.field` (a DotVarExp over a struct lvalue) to the field's
    // inline frame offset (`base + field.offset`) and type, or null if the base
    // is not a resolvable struct value.
    private StructField* tryStructField(DotVarExp dot) {
        auto field = dot.var.isVarDeclaration;
        if (field is null)
            return null;

        bool resolved;
        const base = structBaseOffsetOrMaterialise(dot.e1, resolved);
        if (!resolved)
            return null;

        auto result = new StructField;
        *result = StructField(
            cast(ushort) (base + field.offset), field.type,
        );
        return result;
    }

    // The inline frame base of any struct-valued expression: a struct lvalue's
    // base, a nested struct field (`outer.inner` → `base + inner.offset`), or a
    // struct-valued call / comma materialised into a fresh block. Sets `resolved`
    // false (and returns 0) when `expression` is not a struct the core handles.
    private ushort structBaseOffsetOrMaterialise(
        Expression expression,
        out bool resolved,
    ) {
        import dmd.astenums: TY;

        if (auto base = structBaseOffsetOrNull(expression)) {
            resolved = true;
            return *base;
        }

        // `outer.inner` where `inner` is itself a struct-typed field: the inner
        // block lives inline at `outerBase + inner.offset`.
        if (auto dot = expression.isDotVarExp)
            if (auto field = dot.var.isVarDeclaration)
                if (field.type.toBasetype.ty == TY.Tstruct) {
                    bool outerResolved;
                    const outerBase =
                        structBaseOffsetOrMaterialise(dot.e1, outerResolved);
                    if (outerResolved) {
                        resolved = true;
                        return cast(ushort) (outerBase + field.offset);
                    }
                }

        if (expression.type !is null &&
            expression.type.toBasetype.ty == TY.Tstruct) {
            // `arr[i]` element of a static array of structs: the element block
            // lives inline at `arrayBase + i * elementSize`.
            if (auto index = expression.isIndexExp)
                if (staticArrayOffsetOf(index.e1) !is null) {
                    resolved = true;
                    return locateStaticArrayElement(index).offset;
                }

            if (auto call = expression.isCallExp) {
                resolved = true;
                return compileCall(call).offset;
            }
            if (auto literal = expression.isStructLiteralExp) {
                resolved = true;
                return compileStructLiteralOperand(literal).offset;
            }
            if (auto comma = expression.isCommaExp) {
                compileExpression(comma.e1);
                return structBaseOffsetOrMaterialise(comma.e2, resolved);
            }
        }

        resolved = false;
        return 0;
    }

    // Read a captured enclosing local of type `declaration` at `capturedOffset`
    // within the enclosing frame: the nested struct's `this` block holds the
    // enclosing frame's base index in its first field (vthis, offset 0); add the
    // captured offset and load the scalar through it.
    private Operand loadCapturedLocal(
        VarDeclaration declaration,
        in ushort capturedOffset,
    ) {
        const contextBase =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, contextBase, _thisLocal.offset, cast(ushort) size_t.sizeof,
        );
        const sourceIndex =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const offsetConstant = compileSizeConstant(capturedOffset);
        _code ~= Instruction(
            Op.addInt8, sourceIndex, contextBase, offsetConstant,
        );

        const type = scalarType(declaration.type);
        const destination = allocate(type);
        _code ~= Instruction(
            Op.frameLoad, destination, sourceIndex, cast(ushort) size(type),
        );
        return Operand(destination, type);
    }

    // A field accessed through a struct pointer (`p.field` where `p` is a heap
    // `S*`): the frame slot holding the raw `size_t` pointer, the field's byte
    // offset within the block, and its type.
    private static struct StructPointerField {
        ushort pointerSlot;
        ushort fieldOffset;
        Type type;
    }

    // Resolve `p.field` (a DotVarExp over a struct-pointer local) to the
    // pointer's frame slot, the field's byte offset, and its type, or null if
    // `p` is not a known struct-pointer local.
    private StructPointerField* tryStructPointerField(DotVarExp dot) {
        auto field = dot.var.isVarDeclaration;
        if (field is null)
            return null;

        // `p.field` arrives as `(*p).field`: the base is a `PtrExp` over the
        // pointer local, which DMD inserts for member access through a pointer.
        auto base = dot.e1;
        if (auto deref = base.isPtrExp)
            base = deref.e1;

        auto variable = base.isVarExp;
        if (variable is null)
            return null;
        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null || (declaration in _structPointerLocals) is null)
            return null;

        auto pointerSlot = declaration in _locals;
        if (pointerSlot is null)
            return null;

        auto result = new StructPointerField;
        *result = StructPointerField(
            *pointerSlot, cast(ushort) field.offset, field.type,
        );
        return result;
    }

    // Materialise the address `pointerSlot + fieldOffset` of a struct-pointer
    // field into a fresh pointer slot, so the existing `pointerLoad`/
    // `pointerStore` opcodes (index 0) read and write the heap field.
    private ushort structFieldAddress(in StructPointerField field) {
        const fieldPointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const fieldOffset = compileSizeConstant(field.fieldOffset);
        _code ~= Instruction(
            Op.addInt8, fieldPointer, field.pointerSlot, fieldOffset,
        );
        return fieldPointer;
    }

    // `p.field`: read a scalar field through the struct pointer at `ptr +
    // field.offset` into a fresh slot.
    private Operand loadStructPointerField(StructPointerField field) {
        const fieldScalar = scalarType(field.type);
        const elementSize = size(fieldScalar);
        const fieldPointer = structFieldAddress(field);
        const destination = allocateBytes(elementSize, elementSize);
        _code ~= Instruction(
            pointerLoadOp(elementSize),
            destination,
            fieldPointer,
            compileSizeConstant(0),
        );
        return Operand(destination, fieldScalar);
    }

    // `p.field = value`: write `value` (already in a frame slot) through the
    // struct pointer at `ptr + field.offset`.
    private void storeStructPointerField(
        StructPointerField field,
        in ushort valueSlot,
    ) {
        const elementSize = size(scalarType(field.type));
        const fieldPointer = structFieldAddress(field);
        _code ~= Instruction(
            pointerStoreOp(elementSize),
            valueSlot,
            fieldPointer,
            compileSizeConstant(0),
        );
    }

    // `new S(args)`: heap-allocate a single struct block, initialise it (run the
    // constructor, or store each argument into its field for a constructor-less
    // struct), and yield a raw `S*` pointer operand. Null if `newExp` is not a
    // struct `new` (so array/exception `new` fall through).
    private Operand* tryNewStruct(NewExp newExp) {
        import dmd.astenums: TY;

        if (newExp.newtype is null ||
            newExp.newtype.toBasetype.ty != TY.Tstruct)
            return null;

        const blockSize = cast(uint) staticArraySize(newExp.newtype);

        // Build the initialised struct value in a temporary frame block, then
        // copy it into a fresh heap block addressed by the returned pointer.
        const block = allocateStructBlock(newExp.newtype);
        zeroFrameBlock(block, blockSize);

        if (newExp.member !is null)
            runConstructor(block, newExp.member, newExp.arguments);
        else
            initialiseStructFields(block, newExp.newtype, newExp.arguments);

        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.allocStruct, pointer, block, cast(ushort) blockSize,
        );

        auto result = new Operand;
        *result = Operand(
            pointer, ScalarType.ulong_, false, true, ScalarType.void_,
        );
        return result;
    }

    // Store each `new S(args)` argument into its field at `base + field.offset`
    // for a constructor-less struct (`new Pair(a, b)`): the fields are filled in
    // declaration order, matching DMD's field-wise construction.
    private void initialiseStructFields(
        in ushort base,
        Type structType,
        Expressions* arguments,
    ) {
        import dmd.astenums: TY;

        if (arguments is null)
            return;

        auto structDeclaration = structDeclarationOf(structType);
        foreach (index; 0 .. arguments.length) {
            if (index >= structDeclaration.fields.length)
                break;
            auto field = structDeclaration.fields[index];
            const fieldOffset = cast(ushort) (base + field.offset);
            const value = compileExpression((*arguments)[index]);
            _code ~= Instruction(
                Op.copy,
                fieldOffset,
                value.offset,
                cast(ushort) size(scalarType(field.type)),
            );
        }
    }

    // Run a constructor `this(args)` on the struct block at frame offset `base`:
    // pass the block as the hidden `this` receiver (by reference) and the
    // ordinary arguments, mirroring the method-call path. The constructor
    // mutates the block in place, which the caller then copies onto the heap.
    private void runConstructor(
        in ushort base,
        FuncDeclaration constructor,
        Expressions* arguments,
    ) {
        const index = registerFunction(constructor);
        const layout = parameterLayout(constructor);
        const argumentArea = allocateBytes(layout.blockSize, 8);

        // The hidden `this` receiver: store the block's frame offset, which the
        // machine dereferences on entry and writes back on return.
        _code ~= Instruction(
            Op.loadConstant,
            cast(ushort) (argumentArea + layout.thisOffset),
            constantIndex(base),
            cast(ushort) size(ScalarType.uint_),
        );

        if (arguments !is null)
            foreach (argumentIndex; 0 .. arguments.length) {
                const slot = cast(ushort)
                    (argumentArea + layout.offsets[argumentIndex]);
                emitCallArgument(
                    slot,
                    layout.isReference[argumentIndex],
                    (*arguments)[argumentIndex],
                );
            }

        // A constructor's struct result is treated as void (its only effect is
        // mutating the receiver block), so no result slot is needed.
        _code ~= Instruction(Op.call, index, argumentArea, cast(ushort) 0);
    }

    // Run a no-argument struct method (`function_`) on the inline block at frame
    // offset `base`, passing the block as the hidden `this` receiver by
    // reference. Backs the postblit (`this(this)`) and destructor (`~this()`)
    // calls a static-array copy and scope exit insert.
    private void runStructMethod(in ushort base, FuncDeclaration function_) {
        runConstructor(base, function_, null);
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

    // A dynamic array `T[]` local holds a 16-byte slice descriptor in the
    // frame. With no initializer (or a `null` one) it starts as a null slice;
    // an array literal initializer heap-allocates backing memory and writes the
    // descriptor.
    private void compileDynamicArrayDeclaration(VarDeclaration variable) {
        const elementType = dynamicArrayElementType(variable.type);
        const elementIsArray = dynamicArrayElementIsArray(variable.type);
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _dynamicArrayLocals[variable] =
            DynamicArrayLocal(offset, elementType, elementIsArray);

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            _code ~= Instruction(Op.nullSlice, offset);
            return;
        }

        compileDynamicArrayInto(
            offset, elementType, initializerExpression(initializer.exp),
            elementIsArray);
    }

    // An associative array `int[int]` local holds an 8-byte handle into the
    // machine's VM-owned map table. Create a fresh map and, for a literal
    // initializer, insert each entry (later duplicate keys overwrite earlier).
    private void compileAssocArrayDeclaration(VarDeclaration variable) {
        const offset = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _locals[variable] = offset;
        _assocArrayLocals[variable] = true;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            _code ~= Instruction(Op.aaNew, offset);
            return;
        }

        compileAssocArrayInto(
            offset, initializerExpression(initializer.exp),
        );
    }

    // Build an associative-array handle at frame offset `destination`: a fresh
    // map populated from a `[k: v, ...]` literal (or a `.dup` of another map).
    private void compileAssocArrayInto(
        in ushort destination,
        Expression source,
    ) {
        import std.conv: text;

        // `int[int] m;` (or `m = null`): an empty map.
        if (source.isNullExp !is null) {
            _code ~= Instruction(Op.aaNew, destination);
            return;
        }

        // `dest = src.dup`: the `object.dup` hook yields a fresh handle; copy it
        // into the destination slot.
        if (source.isCallExp !is null) {
            const handle = compileExpression(source);
            _code ~= Instruction(
                Op.copy, destination, handle.offset,
                cast(ushort) size_t.sizeof,
            );
            return;
        }

        auto literal = source.isAssocArrayLiteralExp;
        if (literal is null)
            throw new Exception(text(
                "Unsupported associative array initializer in bytecode core: ",
                expressionChars(source),
            ));

        _code ~= Instruction(Op.aaNew, destination);
        foreach (index; 0 .. literal.keys.length) {
            const key = compileExpression((*literal.keys)[index]);
            const value = compileExpression((*literal.values)[index]);
            _code ~= Instruction(
                Op.aaInsert, destination, key.offset, value.offset,
            );
        }
    }

    // Build a dynamic-array slice descriptor at frame offset `destination`. A
    // `null` literal yields a null slice; an array literal heap-allocates a
    // block of `count` elements and stores each element into it.
    private void compileDynamicArrayInto(
        in ushort destination,
        in ScalarType elementType,
        Expression source,
        in bool elementIsArray = false,
    ) {
        import std.conv: text;

        if (source.isNullExp) {
            _code ~= Instruction(Op.nullSlice, destination);
            return;
        }

        // `dest = new T[](length)` / `new T[][](rows, cols)`: heap-allocate a
        // default-filled block of `length` (a runtime size_t) elements; the
        // multidimensional form also fills each element with a fresh inner array.
        if (auto new_ = source.isNewExp) {
            compileNewArrayInto(destination, elementType, new_, elementIsArray);
            return;
        }

        // `dest = arr.dup` / `dest = arr.idup`: an independent copy of `arr` in
        // a fresh heap block, so mutating either side leaves the other intact.
        if (auto duplicate = tryArrayDuplication(source)) {
            compileArrayDuplication(destination, elementType, duplicate);
            return;
        }

        // `dest = src[lo .. hi]` forms a sub-slice sharing the source's
        // backing memory, so writes through `dest` propagate to the original.
        if (auto slice = source.isSliceExp) {
            compileSliceInto(destination, elementType, slice);
            return;
        }

        // `dest = a ~ b` (concatenation): build a fresh heap block holding both
        // operands' elements, leaving the originals untouched.
        if (auto cat = source.isCatExp) {
            compileCatInto(destination, elementType, cat);
            return;
        }

        // `dest = makeArray(...)` copies the call's 16-byte slice-descriptor
        // result into the destination slot; the backing memory is shared.
        if (auto call = source.isCallExp) {
            const result = compileCall(call);
            _code ~= Instruction(
                Op.copy,
                destination,
                result.offset,
                cast(ushort) sliceDescriptorSize,
            );
            return;
        }

        // `dest = src` where `src` is another dynamic-array local, parameter, or
        // `this.field`: copy the 16-byte slice descriptor, sharing the backing
        // memory (D's reference semantics for dynamic-array assignment).
        if (auto descriptor = dynamicArrayDescriptorOrNull(source)) {
            _code ~= Instruction(
                Op.copy,
                destination,
                descriptor.offset,
                cast(ushort) sliceDescriptorSize,
            );
            return;
        }

        auto literal = source.isArrayLiteralExp;
        if (literal is null)
            throw new Exception(text(
                "Unsupported dynamic array initializer in bytecode core: ",
                expressionChars(source),
            ));

        const count = literal.elements is null ? 0 : literal.elements.length;

        // An array-of-arrays literal (`[[..], [..]]`): each element is itself an
        // array, stored as a 16-byte descriptor. Build each inner array into a
        // fresh descriptor slot and store it into the outer block.
        if (elementIsArray) {
            _code ~= Instruction(
                Op.allocArray,
                destination,
                cast(ushort) sliceDescriptorSize,
                cast(ushort) count,
            );

            foreach (elementIndex; 0 .. count) {
                const inner =
                    allocateBytes(sliceDescriptorSize, size_t.sizeof);
                compileDynamicArrayInto(
                    inner, elementType, (*literal.elements)[elementIndex],
                );
                const index = compileSizeConstant(elementIndex);
                _code ~= Instruction(
                    Op.indexStore16,
                    inner,
                    destination,
                    index,
                );
            }
            return;
        }

        const elementSize = size(elementType);
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            const value = compileExpression((*literal.elements)[elementIndex]);
            const index = compileSizeConstant(elementIndex);
            _code ~= Instruction(
                indexStoreOp(elementSize),
                value.offset,
                destination,
                index,
            );
        }
    }

    // `dest = new T[](length)`: evaluate the runtime length into a size_t slot
    // and allocate a default-filled heap block of that many elements, writing
    // the descriptor to `destination`. The length is `new_.arguments[0]`.
    private void compileNewArrayInto(
        in ushort destination,
        in ScalarType elementType,
        NewExp new_,
        in bool elementIsArray = false,
    ) {
        import std.conv: text;

        // `new T[][](rows, cols)`: both lengths arrive in `new_.arguments`; build
        // an outer array of `rows` inner arrays, each of `cols` elements.
        if (elementIsArray) {
            if (new_.arguments is null || new_.arguments.length != 2)
                throw new Exception(text(
                    "Unsupported new array in bytecode core: ",
                    expressionChars(new_),
                ));

            // Materialise rows and cols into an adjacent size_t pair the opcode
            // reads from a single offset.
            const dimensions = allocateBytes(2 * size_t.sizeof, size_t.sizeof);
            const rows = compileExpression((*new_.arguments)[0]);
            _code ~= Instruction(
                Op.copy, dimensions, rows.offset, cast(ushort) size_t.sizeof,
            );
            const cols = compileExpression((*new_.arguments)[1]);
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (dimensions + size_t.sizeof),
                cols.offset,
                cast(ushort) size_t.sizeof,
            );
            _code ~= Instruction(
                Op.allocArray2D,
                destination,
                packedFill(elementType),
                dimensions,
            );
            return;
        }

        if (new_.arguments is null || new_.arguments.length != 1)
            throw new Exception(text(
                "Unsupported new array in bytecode core: ",
                expressionChars(new_),
            ));

        const length = compileExpression((*new_.arguments)[0]);
        _code ~= Instruction(
            Op.allocArrayDynamic,
            destination,
            packedFill(elementType),
            length.offset,
        );
    }

    // Pack the element type's default-init fill byte (high 8 bits) and element
    // size (low 8 bits) for `allocArrayDynamic`. `char.init` is 0xFF; every
    // other element type the core lowers default-inits to all-zero bytes.
    private ushort packedFill(in ScalarType elementType) @safe pure {
        const fill = elementType == ScalarType.char_ ? 0xff : 0x00;
        return cast(ushort) ((fill << 8) | size(elementType));
    }

    // The frame offset of a 16-byte slice descriptor denoting the value of an
    // array-valued expression: a dynamic-array local's slot is returned in
    // place; any other form (slice, literal, call, null) is materialised into a
    // fresh descriptor slot.
    private ushort arrayDescriptorOffset(
        in ScalarType elementType,
        Expression source,
    ) {
        if (auto descriptor = dynamicArrayDescriptorOrNull(source))
            return descriptor.offset;

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileDynamicArrayInto(offset, elementType, source);
        return offset;
    }

    // Emit a sub-slice descriptor into frame offset `destination` from a
    // `SliceExp` over a dynamic-array operand. Lower and upper bounds (default
    // `0` and `source.length` for the whole-slice form `arr[]`) are compiled
    // into an adjacent `{lo, hi}` size_t pair; the subSlice opcode reads them
    // and shares the source's backing memory.
    private void compileSliceInto(
        in ushort destination,
        in ScalarType elementType,
        SliceExp slice,
    ) {
        // `p[lo .. hi]` over a pointer: build the descriptor directly from the
        // raw pointer value and the {lo, hi} element bounds, sharing the heap
        // block `p` points into. The upper bound is always present for a pointer
        // slice (DMD requires it).
        if (isPointerType(slice.e1.type)) {
            compilePointerSliceInto(destination, slice);
            return;
        }

        const descriptor = dynamicArrayDescriptor(slice.e1);

        // Materialise lo and hi into adjacent size_t slots; the opcode reads
        // the pair from the single `bounds` offset.
        const bounds = allocateBytes(2 * size_t.sizeof, size_t.sizeof);
        const lo = slice.lwr is null
            ? compileSizeConstant(0)
            : compileExpression(slice.lwr).offset;
        _code ~= Instruction(
            Op.copy, bounds, lo, cast(ushort) size_t.sizeof,
        );

        const hi = slice.upr is null
            ? sliceLengthSlot(descriptor)
            : compileExpression(slice.upr).offset;
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (bounds + size_t.sizeof),
            hi,
            cast(ushort) size_t.sizeof,
        );

        _code ~= Instruction(
            subSliceOp(size(elementType)),
            destination,
            descriptor.offset,
            bounds,
        );
    }

    // `p[lo .. hi]` over a pointer: write a slice descriptor
    // {p + lo * elementSize, hi - lo} at `destination`, sharing the heap block
    // `p` addresses. lo and hi are element indices (not pre-scaled), compiled
    // into an adjacent {lo, hi} size_t pair the pointerSlice opcode reads.
    private void compilePointerSliceInto(
        in ushort destination,
        SliceExp slice,
    ) {
        const pointer = compileExpression(slice.e1);
        const bounds = allocateBytes(2 * size_t.sizeof, size_t.sizeof);
        const lo = slice.lwr is null
            ? compileSizeConstant(0)
            : compileExpression(slice.lwr).offset;
        _code ~= Instruction(Op.copy, bounds, lo, cast(ushort) size_t.sizeof);
        const hi = compileExpression(slice.upr).offset;
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (bounds + size_t.sizeof),
            hi,
            cast(ushort) size_t.sizeof,
        );

        _code ~= Instruction(
            pointerSliceOp(size(pointer.pointerElement)),
            destination,
            pointer.offset,
            bounds,
        );
    }

    // `dest = a ~ b` (concatenation): materialise each operand into a slice
    // descriptor sharing existing backing memory, then emit a concat that
    // allocates a fresh block holding both in order. An operand of element type
    // (`x ~ arr` / `arr ~ x`) is wrapped into a one-element descriptor first.
    private void compileCatInto(
        in ushort destination,
        in ScalarType elementType,
        CatExp cat,
    ) {
        const left = catOperandDescriptor(elementType, cat.e1);
        const right = catOperandDescriptor(elementType, cat.e2);
        _code ~= Instruction(
            concatArraysOp(size(elementType)),
            destination,
            left,
            right,
        );
    }

    // A 16-byte slice descriptor for one side of a concatenation: an array
    // operand uses its existing descriptor (materialised if needed); an element
    // operand (`x ~ arr`) is stored into a fresh one-element heap block.
    private ushort catOperandDescriptor(
        in ScalarType elementType,
        Expression operand,
    ) {
        import dmd.astenums: TY;

        if (operand.type !is null &&
            operand.type.toBasetype.ty == TY.Tarray)
            return arrayDescriptorOffset(elementType, operand);

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        const elementSize = size(elementType);
        _code ~= Instruction(
            Op.allocArray, offset, cast(ushort) elementSize, 1,
        );
        const value = compileExpression(operand);
        const index = compileSizeConstant(0);
        _code ~= Instruction(
            indexStoreOp(elementSize), value.offset, offset, index,
        );
        return offset;
    }

    // The array operand of an `arr.dup` / `arr.idup` call, or null if `source`
    // is not such a call. Both resolve to an `object.dup`/`object.idup`
    // template CallExp whose callee identifier is `dup`/`idup` and whose single
    // argument is the (cast-wrapped) source array; the AA `.dup` is a distinct
    // `object.dup!(...)` instantiation and is not matched here.
    private Expression tryArrayDuplication(Expression source) {
        auto call = source.isCallExp;
        if (call is null ||
            call.arguments is null ||
            call.arguments.length != 1)
            return null;

        auto function_ = callFunction(call);
        if (function_ is null || function_.ident is null)
            return null;

        const name = function_.ident.toString;
        if (name != "dup" && name != "idup")
            return null;

        auto argument = (*call.arguments)[0];
        if (!isDynamicArrayArgument(argument))
            return null;

        return argument;
    }

    // `dest = arr.dup` / `dest = arr.idup`: materialise the source array's
    // descriptor and emit an opcode that allocates a fresh heap block, copies
    // every element into it, and writes the new descriptor to `destination`.
    private void compileArrayDuplication(
        in ushort destination,
        in ScalarType elementType,
        Expression source,
    ) {
        // The dup argument is the source array wrapped in an
        // implicit-const cast; unwrap it so a known dynamic-array local reuses
        // its descriptor in place rather than failing the cast.
        auto array = source;
        while (auto cast_ = array.isCastExp)
            array = cast_.e1;

        const sourceDescriptor = arrayDescriptorOffset(elementType, array);
        _code ~= Instruction(
            dupArrayOp(size(elementType)),
            destination,
            sourceDescriptor,
        );
    }

    // Read the length word of a dynamic-array descriptor into a fresh size_t
    // slot, for the implicit upper bound of a whole-slice `arr[]`.
    private ushort sliceLengthSlot(in DynamicArrayLocal descriptor) {
        const offset = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, offset, descriptor.offset);
        return offset;
    }

    private Operand compileCastExpression(CastExp cast_) {
        import std.conv: text;

        // `arr.ptr` arrives as a CastExp of the array to `T*`; yield the
        // descriptor's pointer word as a raw `size_t` address.
        if (isPointerType(cast_.to))
            return compileArrayPointer(cast_);

        const source = compileExpression(cast_.e1);
        const target = scalarType(cast_.to);

        // Crossing the int/float boundary needs a numeric conversion, not a
        // byte copy or integer extension. Only double -> int is needed today.
        if (source.type == ScalarType.double_ && target == ScalarType.int_) {
            const offset = allocate(target);
            _code ~= Instruction(Op.convertDoubleToInt, offset, source.offset);
            return Operand(offset, target);
        }

        // `cast(double)intExpr` (e.g. `double d = seed;`): numerically widen any
        // integer operand -- including a call result already materialised into a
        // temp slot by `compileExpression` -- to a double, preserving signedness.
        if (!isFloating(source.type) && target == ScalarType.double_) {
            import quickbite.backends.bytecode.core.program: unsignedConvertFlag;

            const offset = allocate(target);
            const width = cast(ushort) (size(source.type) |
                (isSigned(source.type) ? 0 : unsignedConvertFlag));
            _code ~= Instruction(
                Op.convertIntToDouble, offset, source.offset, width,
            );
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

    // `arr.ptr`: copy the descriptor's pointer word (the address of element 0)
    // into a fresh `size_t` slot, yielding a pointer operand over the element
    // type. `&arr[0]` produces the same address, so the two compare `is`-equal.
    private Operand compileArrayPointer(CastExp cast_) {
        const descriptor = dynamicArrayDescriptor(cast_.e1);
        return pointerToElement(
            descriptor.offset, descriptor.elementType, compileSizeConstant(0),
        );
    }

    // `&arr[i]`: the address of element `i`, i.e. `descriptor.ptr + i * size`,
    // yielding a pointer operand over the element type. Null if the indexed
    // operand is not a known dynamic-array descriptor.
    private Operand* tryAddressOfElement(AddrExp address) {
        auto index = address.e1.isIndexExp;
        if (index is null)
            return null;

        auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
        if (descriptor is null)
            return null;

        const indexSlot = compileExpression(index.e2);
        auto result = new Operand;
        *result = pointerToElement(
            descriptor.offset, descriptor.elementType, indexSlot.offset,
        );
        return result;
    }

    // `&local` / `&base.field`: the native address of a scalar local's frame
    // slot (or a struct field's inline slot), yielding an `int*`-style pointer
    // operand over the pointed-at element type. Null if the operand is not a
    // scalar local or struct field.
    // `&local` as a SymOffExp (`symbolOffset`): the address of a scalar local's
    // frame slot plus the symbol's byte offset, yielding an `int*`-style pointer
    // operand over the pointed-at element type. Null if the symbol is not a
    // scalar local.
    private Operand* tryAddressOfSymbol(SymOffExp symOff) {
        auto declaration = symOff.var.isVarDeclaration;
        if (declaration is null)
            return null;
        auto existing = declaration in _locals;
        if (existing is null)
            return null;

        const slot = cast(ushort) (*existing + symOff.offset);
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.frameAddress, pointer, slot);
        auto result = new Operand;
        *result = Operand(
            pointer, ScalarType.ulong_, false, true,
            scalarType(declaration.type),
        );
        return result;
    }

    // `&f`: a function-pointer value, the callee's VM function index loaded as
    // a size_t into an 8-byte slot. Registering the function makes its body
    // reachable for lazy compilation on the indirect call. The operand is a
    // pointer so a `int function()` local's `compilePointerDeclaration` accepts
    // it; `pointerElement` is irrelevant (the value is never dereferenced).
    private Operand functionPointer(FuncDeclaration function_) {
        const index = registerFunction(function_);
        const offset = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.loadConstant,
            offset,
            constantIndex(index),
            cast(ushort) size_t.sizeof,
        );
        return Operand(
            offset, ScalarType.ulong_, false, true, ScalarType.void_,
        );
    }

    private Operand* tryAddressOfLocal(AddrExp address) {
        import dmd.astenums: TY;

        ushort slot;
        Type pointedType;

        if (auto variable = address.e1.isVarExp) {
            auto declaration = variable.var.isVarDeclaration;
            if (declaration is null)
                return null;
            auto existing = declaration in _locals;
            if (existing is null)
                return null;
            slot = *existing;
            pointedType = declaration.type;
        } else if (auto dot = address.e1.isDotVarExp) {
            auto field = tryStructField(dot);
            if (field is null)
                return null;
            slot = field.offset;
            pointedType = field.type;
        } else
            return null;

        if (pointedType.toBasetype.ty == TY.Tstruct)
            return null;

        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.frameAddress, pointer, slot);
        auto result = new Operand;
        *result = Operand(
            pointer, ScalarType.ulong_, false, true, scalarType(pointedType),
        );
        return result;
    }

    // A pointer operand holding `descriptor.ptr + index * elementSize`: read the
    // descriptor's pointer word, scale the index by the element size, and add.
    private Operand pointerToElement(
        in ushort descriptorOffset,
        in ScalarType elementType,
        in ushort indexSlot,
    ) {
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, pointer, descriptorOffset, cast(ushort) size_t.sizeof,
        );
        return offsetPointer(pointer, elementType, indexSlot);
    }

    // Advance the `size_t` pointer at `pointerOffset` by `index * elementSize`
    // into a fresh pointer slot, the shared scaling for `&arr[i]`, `p + n`, and
    // `n + p`.
    private Operand offsetPointer(
        in ushort pointerOffset,
        in ScalarType elementType,
        in ushort indexSlot,
    ) {
        const scaled = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const stride = compileSizeConstant(size(elementType));
        _code ~= Instruction(Op.mulInt8, scaled, indexSlot, stride);
        const result = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.addInt8, result, pointerOffset, scaled);
        return Operand(result, ScalarType.ulong_, false, true, elementType);
    }

    // `*p`: read the element the pointer addresses (index 0), yielding a scalar
    // operand of the pointed-at element type.
    private Operand compilePointerDereference(PtrExp deref) {
        import std.conv: text;

        const pointer = compileExpression(deref.e1);
        if (!pointer.isPointer)
            throw new Exception(text(
                "Unsupported pointer dereference in bytecode core: ",
                expressionChars(deref),
            ));

        return loadThroughPointer(pointer, compileSizeConstant(0));
    }

    // `p[i]`: read the element at `p + i` through a pointer, yielding a scalar
    // operand of the pointed-at element type. Null if `p` is not a pointer.
    private Operand* tryPointerIndex(IndexExp index) {
        if (!isPointerType(index.e1.type))
            return null;

        const pointer = compileExpression(index.e1);
        const indexSlot = compileExpression(index.e2);
        auto result = new Operand;
        *result = loadThroughPointer(pointer, indexSlot.offset);
        return result;
    }

    // Read `size(elementType)` bytes from `[pointer + index * size]` into a
    // fresh element slot, the shared loader for `*p` and `p[i]`.
    private Operand loadThroughPointer(
        in Operand pointer,
        in ushort indexSlot,
    ) {
        const elementSize = size(pointer.pointerElement);
        const offset = allocateBytes(elementSize, elementSize);
        _code ~= Instruction(
            pointerLoadOp(elementSize), offset, pointer.offset, indexSlot,
        );
        return Operand(offset, pointer.pointerElement);
    }

    private Operand compileAddExpression(Expression expression) {
        auto add = cast(BinExp) expression; // DMD AST fields are mutable refs.
        assert(add !is null);

        // Pointer arithmetic `p + n` / `n + p`: advance the pointer operand by
        // the integer operand scaled by the element size.
        if (isPointerType(add.e1.type) || isPointerType(add.e2.type))
            return compilePointerAdd(add);

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

    // `p + n` / `n + p`: add the integer operand to the raw pointer value,
    // yielding a pointer operand. DMD pre-scales the integer operand to a byte
    // offset (`p + n` arrives as `p + n * elementSize`), so no scaling here.
    private Operand compilePointerAdd(BinExp add) {
        const pointerFirst = isPointerType(add.e1.type);
        const pointer =
            compileExpression(pointerFirst ? add.e1 : add.e2);
        const offset = compileExpression(pointerFirst ? add.e2 : add.e1);
        const result = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.addInt8, result, pointer.offset, offset.offset);
        return Operand(
            result, ScalarType.ulong_, false, true, pointer.pointerElement,
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
    // Integer multiplication. Pointer arithmetic scales its integer operand
    // through an 8-byte `cast(long)n * elementSize`, so the 8-byte form is the
    // one that matters here; the 4-byte form mirrors `addInt4`.
    private Operand compileMultiplyExpression(MulExp multiply) {
        import std.conv: text;

        const lhs = compileExpression(multiply.e1);
        const rhs = compileExpression(multiply.e2);
        if (isEightByteInteger(lhs.type) &&
            isEightByteInteger(rhs.type))
            return emitBinary(Op.mulInt8, lhs, rhs, lhs.type);

        return compileIntBinaryResult(
            multiply,
            lhs,
            rhs,
            Op.mulInt4,
            ScalarType.int_,
            "Unsupported multiplication in bytecode core: ",
        );
    }

    private Operand compileDivideExpression(DivExp divide) {
        // `p - q`: DMD lowers it to `(byteDistance) / elementStride`, a MinExp
        // of two pointers wrapped in a DivExp by the stride. The byte distance
        // and stride are signed 8-byte (`ptrdiff_t`); divide them at that width.
        if (auto difference = divide.e1.isMinExp)
            if (isPointerType(difference.e1.type) &&
                isPointerType(difference.e2.type))
                return compilePointerDifference(divide, difference);

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

    // `p - n`: subtract the integer operand from the raw pointer value, yielding
    // a pointer operand over the same element type. DMD pre-scales the integer
    // operand to a byte offset (`p - n` arrives as `p - n * elementSize`).
    private Operand compilePointerSubtractInteger(BinExp subtract) {
        const pointer = compileExpression(subtract.e1);
        const offset = compileExpression(subtract.e2);
        const result = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.subInt8, result, pointer.offset, offset.offset,
        );
        return Operand(
            result, ScalarType.ulong_, false, true, pointer.pointerElement,
        );
    }

    // The raw byte distance `p - q` between two pointers as a signed 8-byte
    // value; `p - q` wraps this in a DivExp by the element stride.
    private Operand compilePointerDifferenceBytes(BinExp subtract) {
        const lhs = compileExpression(subtract.e1);
        const rhs = compileExpression(subtract.e2);
        const result = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.subInt8, result, lhs.offset, rhs.offset);
        return Operand(result, ScalarType.long_);
    }

    // `p - q`: divide the signed byte distance by the element stride to yield
    // the `ptrdiff_t` element count.
    private Operand compilePointerDifference(
        DivExp divide,
        BinExp difference,
    ) {
        const bytes = compilePointerDifferenceBytes(difference);
        const stride = compileExpression(divide.e2);
        const result = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.divInt8, result, bytes.offset, stride.offset,
        );
        return Operand(result, ScalarType.long_);
    }

    // Integer `<` / `>`; both yield a bool. One opcode per operator, not per
    // operand type. Only the forms `&&` operands produce are needed today.
    private Operand compileComparisonExpression(CmpExp comparison) {
        import dmd.tokens: EXP;
        import std.conv: text;

        // Pointer relations `p < q` etc. compare raw `size_t` pointer values as
        // unsigned, matching compiled pointer code.
        if (isPointerType(comparison.e1.type) ||
            isPointerType(comparison.e2.type))
            return compilePointerComparison(comparison);

        const lhs = compileExpression(comparison.e1);
        const rhs = compileExpression(comparison.e2);

        // 8-byte unsigned comparison (`size_t`/`ulong`, e.g. a `foreach` index
        // against `.length`): use the unsigned 8-byte relation opcodes.
        if (lhs.type == ScalarType.ulong_ && rhs.type == ScalarType.ulong_) {
            const offset = allocate(ScalarType.bool_);
            _code ~= Instruction(
                unsignedComparisonOp8(comparison.op),
                offset, lhs.offset, rhs.offset,
            );
            return Operand(offset, ScalarType.bool_);
        }

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

        return compileIntBinaryResult(
            comparison,
            lhs,
            rhs,
            op,
            ScalarType.bool_,
            "Unsupported comparison in bytecode core: ",
        );
    }

    // `p < q`, `p <= q`, `p > q`, `p >= q`: compare raw `size_t` pointer values
    // as unsigned, yielding a bool.
    private Operand compilePointerComparison(CmpExp comparison) {
        import dmd.tokens: EXP;
        import std.conv: text;

        const op = () {
            switch (comparison.op) with (EXP) {
                case lessThan: return "<";
                case lessOrEqual: return "<=";
                case greaterThan: return ">";
                case greaterOrEqual: return ">=";
                default:
                    throw new Exception(text(
                        "Unsupported comparison in bytecode core: ",
                        expressionChars(comparison),
                    ));
            }
        }();

        const lhs = compileExpression(comparison.e1);
        const rhs = compileExpression(comparison.e2);
        const offset = allocate(ScalarType.bool_);
        _code ~= Instruction(
            pointerComparisonOp(op), offset, lhs.offset, rhs.offset,
        );
        return Operand(offset, ScalarType.bool_);
    }

    // `c ? t : f`: evaluate `c`, branch, and write whichever branch's value into
    // a single result slot. Used for DMD's `m[k]` lowering, whose conditional is
    // pointer-valued (the value's slot, or a null after a bounds throw); the
    // result width and pointer metadata come from the true branch.
    private Operand compileConditionalExpression(
        imported!"dmd.expression".CondExp conditional,
    ) {
        const condition = compileBoolCondition(conditional.econd);
        const result = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);

        const falseJump = emitJumpIfFalse(condition);
        const whenTrue = compileExpression(conditional.e1);
        const valueSize = operandSize(whenTrue);
        _code ~= Instruction(
            Op.copy, result, whenTrue.offset, cast(ushort) valueSize,
        );
        const endJump = emitJump;

        patchJump(falseJump);
        const whenFalse = compileExpression(conditional.e2);
        _code ~= Instruction(
            Op.copy, result, whenFalse.offset, cast(ushort) valueSize,
        );
        patchJump(endJump);

        return Operand(
            result,
            whenTrue.type,
            whenTrue.isString,
            whenTrue.isPointer,
            whenTrue.pointerElement,
        );
    }

    // The byte width an operand occupies in the frame: 8 for a pointer or string
    // descriptor, otherwise its scalar type's size.
    private uint operandSize(in Operand operand) @safe pure {
        if (operand.isPointer)
            return cast(uint) size_t.sizeof;
        if (operand.isString)
            return stringSliceSize;
        return size(operand.type);
    }

    // Normalise an expression to a one-byte bool condition. A pointer condition
    // (`slot ? ...`) is non-null iff its 8-byte value is non-zero, so compare it
    // to a zero constant rather than testing a single byte.
    private Operand compileBoolCondition(Expression expression) {
        const operand = compileExpression(expression);
        if (!operand.isPointer)
            return operand;

        const zero =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.loadConstant, zero, constantIndex(0),
            cast(ushort) size_t.sizeof,
        );
        const result = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.notEqual8, result, operand.offset, zero);
        return Operand(result, ScalarType.bool_);
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

        // Pointer arithmetic `p - n`: step the pointer back by the integer
        // operand scaled by the element size, yielding a pointer operand.
        if (isPointerType(subtract.e1.type) && !isPointerType(subtract.e2.type))
            return compilePointerSubtractInteger(subtract);

        // Raw `p - q` between two pointers: the byte distance, which `p - q`
        // wraps in a DivExp by the element stride to yield the element count.
        if (isPointerType(subtract.e1.type) && isPointerType(subtract.e2.type))
            return compilePointerDifferenceBytes(subtract);

        const lhs = compileExpression(subtract.e1);
        const rhs = compileExpression(subtract.e2);
        if (lhs.type == ScalarType.float_ && rhs.type == ScalarType.float_)
            return emitBinary(Op.subFloat, lhs, rhs, ScalarType.float_);
        if (lhs.type == ScalarType.double_ && rhs.type == ScalarType.double_)
            return emitBinary(Op.subDouble, lhs, rhs, ScalarType.double_);

        // 8-byte integer subtraction (e.g. `size_t`): same operand and result
        // type on both sides, kept at the full width.
        if (isEightByteInteger(lhs.type) &&
            lhs.type == rhs.type &&
            scalarType(subtract.type) == lhs.type)
            return emitBinary(Op.subInt8, lhs, rhs, lhs.type);

        return compileIntBinaryResult(
            subtract,
            lhs,
            rhs,
            Op.subInt4,
            ScalarType.int_,
            "Unsupported subtraction in bytecode core: ",
        );
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

        // Integer negation `-x` is `0 - x`; the result keeps the operand's
        // integer type (a user `opUnary!"-"` body negates a scalar field).
        if (isIntegerScalar(source.type)) {
            const eightByte = isEightByteInteger(source.type);
            const zero = allocate(source.type);
            _code ~= Instruction(
                Op.loadConstant, zero, constantIndex(0),
                cast(ushort) size(source.type),
            );
            const offset = allocate(source.type);
            _code ~= Instruction(
                eightByte ? Op.subInt8 : Op.subInt4,
                offset, zero, source.offset,
            );
            return Operand(offset, source.type);
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

        // `*p += rhs` through a pointer (a postblit's `++*this.postblits`): load
        // `*p`, add the rhs, and store it back through the pointer.
        if (auto deref = addAssign.e1.isPtrExp)
            if (auto store = tryPointerDereferenceAddAssign(deref, addAssign.e2))
                return *store;

        // `arr[i] += rhs` on a dynamic-array element (e.g. a destructor's
        // `this.sink[0] += 3`): load the element, add the rhs, and store it back
        // through the descriptor.
        if (auto index = addAssign.e1.isIndexExp)
            if (auto element = tryDynamicArrayElementAddAssign(index, addAssign.e2))
                return *element;

        // `p.field += rhs` through a heap struct pointer: load the field, add the
        // rhs, and store the result back through the pointer.
        if (auto dot = addAssign.e1.isDotVarExp)
            if (auto field = tryStructPointerField(dot)) {
                const current = loadStructPointerField(*field);
                const rhsValue = compileExpression(addAssign.e2);
                const lvalueType = scalarType(field.type);
                const addOp = lvalueType == ScalarType.long_ ||
                    lvalueType == ScalarType.ulong_
                        ? Op.addInt8
                        : Op.addInt4;
                _code ~= Instruction(
                    addOp, current.offset, current.offset, rhsValue.offset,
                );
                storeStructPointerField(*field, current.offset);
                return Operand(current.offset, lvalueType);
            }

        // `base.field += rhs` on an inline struct field (e.g. a `with (subject)`
        // body's `(*__withSym).field`): add into the field's own frame slot.
        if (auto dot = addAssign.e1.isDotVarExp)
            if (auto field = tryStructField(dot)) {
                const lvalueType = scalarType(field.type);
                const rhsValue = compileExpression(addAssign.e2);
                const addOp = lvalueType == ScalarType.long_ ||
                    lvalueType == ScalarType.ulong_
                        ? Op.addInt8
                        : Op.addInt4;
                _code ~= Instruction(
                    addOp, field.offset, field.offset, rhsValue.offset,
                );
                return Operand(field.offset, lvalueType);
            }

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

        // `arr.length = n`: resize the array in place, preserving existing
        // elements and zero-filling growth. Detected by the ArrayLengthExp
        // lvalue (DMD wraps this in a LoweredAssignExp), not a druntime name.
        if (auto length = assign.e1.isArrayLengthExp)
            return compileArrayLengthAssign(length, assign.e2);

        // `m[k] = v` for an associative array: insert or overwrite the entry in
        // the VM-owned map.
        if (auto index = assign.e1.isIndexExp)
            if (auto store = tryAssocArrayElementAssign(index, assign.e2))
                return *store;

        // `p[i] = rhs` through a pointer (`m[k] = v` lowers to a write through
        // the `_d_aaGetY` slot pointer): write the scalar rhs at `p + i`.
        if (auto index = assign.e1.isIndexExp)
            if (auto store = tryPointerElementAssign(index, assign.e2))
                return *store;

        // `*p = rhs` through a pointer.
        if (auto deref = assign.e1.isPtrExp)
            if (auto store = tryPointerDereferenceAssign(deref, assign.e2))
                return *store;

        // `arr[i] = rhs` for a dynamic-array element: write the scalar rhs into
        // the heap element at `index`.
        if (auto index = assign.e1.isIndexExp)
            if (auto store = tryDynamicArrayElementAssign(index, assign.e2))
                return *store;

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

        // `arr[lo .. hi] = rhs` for a dynamic array: copy the rhs elements into
        // the existing backing memory (write-through to the original array).
        if (auto slice = assign.e1.isSliceExp)
            if (auto copy = tryDynamicArraySliceAssign(slice, assign.e2))
                return *copy;

        // `base.field = rhs`: write into a struct field at its inline offset.
        if (auto dot = assign.e1.isDotVarExp)
            if (auto store = tryStructFieldAssign(dot, assign.e2))
                return *store;

        // `p.field = rhs` through a heap struct pointer: write the scalar rhs at
        // `ptr + field.offset`.
        if (auto dot = assign.e1.isDotVarExp)
            if (auto field = tryStructPointerField(dot)) {
                const value = compileExpression(assign.e2);
                storeStructPointerField(*field, value.offset);
                return Operand(value.offset, scalarType(field.type));
            }

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

    // `base.field = rhs`: write into a struct field at its inline frame offset.
    // A dynamic-array field takes the rhs slice descriptor (or a whole-array
    // literal); a scalar field is a byte copy. Null if the base is not a known
    // struct local, so other assignment forms fall through.
    private Operand* tryStructFieldAssign(DotVarExp dot, Expression rhs) {
        import dmd.astenums: TY;

        auto field = tryStructField(dot);
        if (field is null)
            return null;

        if (field.type.toBasetype.ty == TY.Tarray &&
            !isStringType(field.type)) {
            compileDynamicArrayInto(
                field.offset, dynamicArrayElementType(field.type), rhs,
            );
            auto descriptorResult = new Operand;
            *descriptorResult = Operand(field.offset, ScalarType.void_);
            return descriptorResult;
        }

        // A pointer field `T* p` (`tracker.postblits = &count`) holds an 8-byte
        // raw address; copy the rhs pointer value into the field slot.
        if (isPointerType(field.type)) {
            const value = compileExpression(rhs);
            _code ~= Instruction(
                Op.copy, field.offset, value.offset, cast(ushort) size_t.sizeof,
            );
            auto pointerResult = new Operand;
            *pointerResult = Operand(
                field.offset, ScalarType.ulong_, false, true,
                scalarType(field.type.toBasetype.nextOf),
            );
            return pointerResult;
        }

        const fieldScalar = scalarType(field.type);
        const value = compileExpression(rhs);
        _code ~= Instruction(
            Op.copy, field.offset, value.offset, cast(ushort) size(fieldScalar),
        );
        auto result = new Operand;
        *result = Operand(field.offset, fieldScalar);
        return result;
    }

    // `arr ~= x` (append element): reallocate `arr`'s backing memory with the
    // new element appended and overwrite its descriptor. The lvalue must be a
    // known dynamic-array local (or ref parameter); the appended descriptor
    // yields the array as the expression result.
    // `arr.length = n`: resize `arr` in place. The descriptor is reallocated to
    // `n` elements, existing elements preserved, and growth filled with the
    // element's default-init byte. Yields the new length as the result.
    private Operand compileArrayLengthAssign(
        ArrayLengthExp length,
        Expression newLength,
    ) {
        const descriptor = dynamicArrayDescriptor(length.e1);
        const lengthSlot = compileExpression(newLength);
        _code ~= Instruction(
            Op.setArrayLength,
            descriptor.offset,
            packedFill(descriptor.elementType),
            lengthSlot.offset,
        );
        return Operand(lengthSlot.offset, ScalarType.ulong_);
    }

    private Operand compileAppendElement(CatElemAssignExp append) {
        // `outer[i] ~= x` for an array-of-arrays element: the inner descriptor is
        // materialised into a fresh slot, so the reallocated descriptor must be
        // written back into the outer block's element `i`. Other rows keep their
        // own backing memory untouched.
        if (auto outerElement = outerArrayElement(append.e1)) {
            const value = compileExpression(append.e2);
            const elementSize = size(outerElement.inner.elementType);
            _code ~= Instruction(
                appendElementOp(elementSize),
                outerElement.inner.offset,
                value.offset,
            );
            _code ~= Instruction(
                Op.indexStore16,
                outerElement.inner.offset,
                outerElement.outerOffset,
                outerElement.indexSlot,
            );
            return Operand(
                outerElement.inner.offset, outerElement.inner.elementType,
            );
        }

        const descriptor = dynamicArrayDescriptor(append.e1);
        const value = compileExpression(append.e2);
        const elementSize = size(descriptor.elementType);
        _code ~= Instruction(
            appendElementOp(elementSize),
            descriptor.offset,
            value.offset,
        );
        return Operand(descriptor.offset, descriptor.elementType);
    }

    // An `outer[i]` access into an array-of-arrays local: the outer descriptor
    // offset, the index slot, and the inner descriptor materialised into a fresh
    // slot. Null if `expression` is not such an access. Used to write a
    // reallocated inner descriptor back into the outer block.
    private OuterArrayElement* outerArrayElement(Expression expression) {
        auto index = expression.isIndexExp;
        if (index is null)
            return null;

        auto variable = index.e1.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        auto outer = declaration is null
            ? null
            : declaration in _dynamicArrayLocals;
        if (outer is null || !outer.elementIsArray)
            return null;

        const indexSlot = compileExpression(index.e2);
        const inner = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.indexLoad16, inner, outer.offset, indexSlot.offset,
        );

        auto result = new OuterArrayElement;
        *result = OuterArrayElement(
            outer.offset,
            indexSlot.offset,
            DynamicArrayLocal(inner, outer.elementType),
        );
        return result;
    }

    // `m[k] = v` for an associative array: insert or overwrite the entry in the
    // VM-owned map. Null if `index.e1` is not a known AA local.
    private Operand* tryAssocArrayElementAssign(
        IndexExp index,
        Expression rhs,
    ) {
        auto variable = index.e1.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        if (declaration is null || declaration !in _assocArrayLocals)
            return null;

        const handle = (declaration in _locals);
        const key = compileExpression(index.e2);
        const value = compileExpression(rhs);
        _code ~= Instruction(
            Op.aaInsert, *handle, key.offset, value.offset,
        );

        auto result = new Operand;
        *result = Operand(value.offset, value.type);
        return result;
    }

    // `p[i] = rhs` through a pointer: write the scalar rhs at `p + i * size`.
    // Null if `p` is not a pointer.
    private Operand* tryPointerElementAssign(
        IndexExp index,
        Expression rhs,
    ) {
        if (!isPointerType(index.e1.type))
            return null;

        const pointer = compileExpression(index.e1);
        const indexSlot = compileExpression(index.e2);
        auto result = new Operand;
        *result = storeThroughPointer(pointer, indexSlot.offset, rhs);
        return result;
    }

    // `*p = rhs` through a pointer (`p + 0`). Null if `p` is not a pointer.
    private Operand* tryPointerDereferenceAssign(
        PtrExp deref,
        Expression rhs,
    ) {
        const pointer = compileExpression(deref.e1);
        if (!pointer.isPointer)
            return null;

        auto result = new Operand;
        *result = storeThroughPointer(pointer, compileSizeConstant(0), rhs);
        return result;
    }

    // `*p += rhs` through a pointer: read `*p`, add `rhs`, and write the sum back
    // through the same pointer. Null if `deref.e1` is not a pointer.
    private Operand* tryPointerDereferenceAddAssign(
        PtrExp deref,
        Expression rhs,
    ) {
        const pointer = compileExpression(deref.e1);
        if (!pointer.isPointer)
            return null;

        const zero = compileSizeConstant(0);
        const current = loadThroughPointer(pointer, zero);
        const rhsValue = compileExpression(rhs);
        const addOp = isEightByteInteger(current.type)
            ? Op.addInt8
            : Op.addInt4;
        _code ~= Instruction(
            addOp, current.offset, current.offset, rhsValue.offset,
        );
        _code ~= Instruction(
            pointerStoreOp(size(pointer.pointerElement)),
            current.offset,
            pointer.offset,
            zero,
        );
        auto result = new Operand;
        *result = Operand(current.offset, current.type);
        return result;
    }

    // Write the rhs scalar to `[pointer + index * size]`, the shared store for
    // `*p = v` and `p[i] = v`.
    private Operand storeThroughPointer(
        in Operand pointer,
        in ushort indexSlot,
        Expression rhs,
    ) {
        const value = compileExpression(rhs);
        const elementSize = size(pointer.pointerElement);
        _code ~= Instruction(
            pointerStoreOp(elementSize),
            value.offset,
            pointer.offset,
            indexSlot,
        );
        return Operand(value.offset, pointer.pointerElement);
    }

    // `arr[i] = rhs` for a dynamic-array element: store the scalar rhs into the
    // heap element at runtime index `i`. Null if `arr` is not a known
    // dynamic-array local.
    private Operand* tryDynamicArrayElementAssign(
        IndexExp index,
        Expression rhs,
    ) {
        auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
        if (descriptor is null)
            return null;

        const value = compileExpression(rhs);
        const indexSlot = compileExpression(index.e2);
        const elementSize = size(descriptor.elementType);
        _code ~= Instruction(
            indexStoreOp(elementSize),
            value.offset,
            descriptor.offset,
            indexSlot.offset,
        );

        auto result = new Operand;
        *result = Operand(value.offset, descriptor.elementType);
        return result;
    }

    // `arr[i] += rhs` on a dynamic-array element: load `arr[i]`, add `rhs`, and
    // store the sum back through the descriptor. Null if `index.e1` is not a
    // known dynamic-array descriptor.
    private Operand* tryDynamicArrayElementAddAssign(
        IndexExp index,
        Expression rhs,
    ) {
        auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
        if (descriptor is null)
            return null;

        const elementType = descriptor.elementType;
        const elementSize = size(elementType);
        const indexSlot = compileExpression(index.e2).offset;

        const current = allocateBytes(elementSize, elementSize);
        _code ~= Instruction(
            indexLoadOp(elementSize), current, descriptor.offset, indexSlot,
        );

        const rhsValue = compileExpression(rhs);
        const addOp = isEightByteInteger(elementType)
            ? Op.addInt8
            : Op.addInt4;
        _code ~= Instruction(addOp, current, current, rhsValue.offset);

        _code ~= Instruction(
            indexStoreOp(elementSize), current, descriptor.offset, indexSlot,
        );

        auto result = new Operand;
        *result = Operand(current, elementType);
        return result;
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
        // A sub-array or struct element has no scalar type; callers that handle
        // those use only the offset (a static-array index chain, a struct base).
        const elementType = index.type.toBasetype.ty == TY.Tsarray ||
            index.type.toBasetype.ty == TY.Tstruct
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

        // `base.field` where the field is a static array: its inline block lives
        // at `base + field.offset`.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot))
                return field.offset;

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
        import dmd.astenums: TY;

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                return (declaration in _staticArrayLocals) !is null;

        if (auto index = expression.isIndexExp)
            return indexesStaticArray(index.e1);

        // `base.field` where the field is a static array.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot))
                return field.type.toBasetype.ty == TY.Tsarray;

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

    // `arr[lo .. hi] = rhs` for a dynamic-array local: form the destination
    // sub-slice descriptor sharing `arr`'s backing memory, materialise the rhs
    // into a source descriptor, and emit a write-through element copy. Null if
    // the slice target is not a known dynamic-array local.
    private Operand* tryDynamicArraySliceAssign(
        SliceExp slice,
        Expression rhs,
    ) {
        auto descriptor = dynamicArrayDescriptorOrNull(slice.e1);
        if (descriptor is null)
            return null;

        const elementType = descriptor.elementType;
        const destination = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileSliceInto(destination, elementType, slice);

        const source = compileSourceSlice(elementType, rhs);
        _code ~= Instruction(
            sliceCopyOp(size(elementType)),
            destination,
            source,
        );

        auto result = new Operand;
        *result = Operand.init;
        return result;
    }

    // Materialise the right-hand side of a dynamic-array slice assignment into a
    // slice descriptor slot. A `SliceExp` shares the source's backing memory; an
    // array or string literal heap-allocates a fresh block holding its elements.
    private ushort compileSourceSlice(
        in ScalarType elementType,
        Expression rhs,
    ) {
        import std.conv: text;

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);

        if (auto slice = rhs.isSliceExp) {
            compileSliceInto(offset, elementType, slice);
            return offset;
        }

        if (auto string_ = stringLiteralOf(rhs)) {
            compileStringElementSlice(offset, elementType, string_);
            return offset;
        }

        if (rhs.isArrayLiteralExp !is null) {
            compileDynamicArrayInto(offset, elementType, rhs);
            return offset;
        }

        throw new Exception(text(
            "Unsupported slice-assignment source in bytecode core: ",
            expressionChars(rhs),
        ));
    }

    // Heap-allocate a block of `string_`'s characters and store each into it,
    // leaving a slice descriptor at `offset`. The element size is fixed by the
    // destination element type (1 for char, matching the indexStore split).
    private void compileStringElementSlice(
        in ushort offset,
        in ScalarType elementType,
        StringExp string_,
    ) {
        import quickbite.frontend.dmd.string_literals: stringChars;

        const bytes = cast(const(ubyte)[]) stringChars(string_);
        const elementSize = size(elementType);
        _code ~= Instruction(
            Op.allocArray,
            offset,
            cast(ushort) elementSize,
            cast(ushort) bytes.length,
        );

        foreach (elementIndex, byteValue; bytes) {
            const value = allocate(elementType);
            _code ~= Instruction(
                Op.loadConstant,
                value,
                constantIndex(byteValue),
                cast(ushort) elementSize,
            );
            const index = compileSizeConstant(elementIndex);
            _code ~= Instruction(
                indexStoreOp(elementSize),
                value,
                offset,
                index,
            );
        }
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
        import dmd.astenums: TY;
        import dmd.tokens: EXP;

        auto equal = cast(BinExp) expression; // DMD AST fields are mutable refs.
        assert(equal !is null);

        // `m1 == m2` / `m1 != m2` for associative arrays: compare entry sets via
        // the VM-owned maps. DMD keeps the EqualExp (with an unused lowering to
        // `_d_aaEqual`), so match the operand type here.
        if (equal.e1.type.toBasetype.ty == TY.Taarray) {
            const left = assocArrayHandleOffset(equal.e1);
            const right = assocArrayHandleOffset(equal.e2);
            const offset = allocate(ScalarType.bool_);
            _code ~= Instruction(Op.aaEqual, offset, left, right);
            if (equal.op == EXP.notEqual)
                _code ~= Instruction(Op.notBool, offset, offset);
            return Operand(offset, ScalarType.bool_);
        }

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
        import dmd.astenums: TY;
        import std.conv: text;

        auto function_ = callFunction(call);

        // `_aApply*(string, delegate)` is DMD's lowering of `foreach`/
        // `foreach_reverse` over a UTF string whose loop variable has a different
        // code-unit width: it decodes/transcodes code points and invokes the
        // body delegate per element. Intercept and emit a VM-native transcode
        // loop rather than the unavailable druntime body.
        if (function_ !is null && function_.ident !is null) {
            import quickbite.backends.bytecode.core.program: TranscodeMode;
            TranscodeMode applyMode;
            if (stringForeachApplyMode(function_, applyMode))
                return compileStringForeachApply(call, applyMode);
        }

        // `__ArrayDtor(arr[lo .. hi])` runs the element destructor on each
        // element of a static array going out of scope; intercept and emit the
        // per-element `~this()` calls.
        if (function_ !is null && function_.ident !is null &&
            function_.ident.toString == "__ArrayDtor")
            return compileArrayDtor(call);

        // `dest[] = a[] + b[]` lowers to a druntime arrayOp template call;
        // intercept it at the call site and emit element-wise semantics rather
        // than compiling the druntime body.
        if (function_ !is null && isArrayOpAddAssign(function_))
            return compileArrayOpAddAssign(call);

        if (function_ !is null) {
            const hook = assocArrayHook(function_);
            if (hook != AssocArrayHook.none)
                return compileAssocArrayHook(call, hook);
        }

        // `_d_arraybounds*` is the bounds-failure helper in DMD's `m[k]`
        // lowering (`slot ? slot : (_d_arraybounds(...), null)`); reaching it
        // means the key was absent, so raise the plain "Range violation".
        if (function_ !is null && isArrayBoundsCall(function_))
            return compileRangeViolation;

        if (function_ !is null)
            if (auto builtin = compileBuiltinCall(call, function_))
                return *builtin;

        // `d()` through a delegate local: the callee is a VarExp of a delegate
        // local holding a `{functionIndex, context}` pair. Dispatch indirectly,
        // passing the context as the lambda's hidden `this` block.
        if (function_ is null)
            if (auto delegateLocal = delegateLocalOf(call))
                return compileDelegateCall(*delegateLocal, call);

        // `fp()` through a function-pointer value: the callee is not a named
        // `FuncDeclaration` but a function-pointer expression. Dispatch through
        // the run-time index it holds.
        if (function_ is null && isFunctionPointerCall(call))
            return compileIndirectCall(call);

        if (function_ is null || function_.fbody is null)
            throw new Exception(text(
                "Unsupported call in bytecode core: ",
                expressionChars(call),
            ));

        const index = registerFunction(function_);
        const layout = parameterLayout(function_);
        const argumentArea = allocateBytes(layout.blockSize, 8);

        // A struct method call `receiver.method(args)` passes the receiver as
        // the hidden `this` block (by reference) at the start of the argument
        // area: store the receiver's frame offset there, which the machine
        // dereferences on entry and writes back on return.
        if (layout.hasThis) {
            const receiver = methodReceiverOffset(call);
            _code ~= Instruction(
                Op.loadConstant,
                cast(ushort) (argumentArea + layout.thisOffset),
                constantIndex(receiver),
                cast(ushort) size(ScalarType.uint_),
            );
        }

        if (call.arguments !is null)
            foreach (argumentIndex; 0 .. call.arguments.length) {
                const slot = cast(ushort)
                    (argumentArea + layout.offsets[argumentIndex]);
                emitCallArgument(
                    slot,
                    layout.isReference[argumentIndex],
                    (*call.arguments)[argumentIndex],
                );
            }

        const returnType = _program.functions[index].returnType;
        const destination =
            (!returnType.isString && !returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(Op.call, index, argumentArea, destination);
        return Operand(destination, returnType.scalar, returnType.isString);
    }

    // `_aApply*(s, dg)`: emit a transcode of the source string `s` into a fresh
    // dchar/char element array, then loop over it, running the inlined body
    // delegate once per element with the element bound to the loop variable.
    // A nonzero body return (`break`) exits the loop early. Returns a zero
    // result operand (the apply's int result is unused by the foreach lowering).
    private Operand compileStringForeachApply(
        CallExp call,
        in imported!"quickbite.backends.bytecode.core.program".TranscodeMode mode,
    ) {
        import quickbite.backends.bytecode.core.program: TranscodeMode;
        import std.conv: text;

        if (call.arguments is null || call.arguments.length != 2)
            throw new Exception(text(
                "Unsupported string foreach apply in bytecode core: ",
                expressionChars(call),
            ));

        auto literal = (*call.arguments)[1].isFuncExp;
        if (literal is null || literal.fd is null ||
            literal.fd.fbody is null ||
            literal.fd.parameters is null ||
            literal.fd.parameters.length != 1)
            throw new Exception(text(
                "Unsupported string foreach apply body in bytecode core: ",
                expressionChars(call),
            ));

        // Decode/transcode the source string's code units into a fresh heap
        // block of dchar (or char, for `dcharToUtf8`) elements.
        const elementType = mode == TranscodeMode.dcharToUtf8
            ? ScalarType.char_
            : ScalarType.dchar_;
        const elementSize = size(elementType);
        const source = arrayDescriptorOffset(
            dynamicArrayElementType((*call.arguments)[0].type),
            (*call.arguments)[0],
        );
        const elements = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.transcodeUtf, elements, cast(ushort) mode, source,
        );

        // The loop variable is the delegate's single (`ref`) parameter; bind it
        // to a fresh frame slot the body reads through the ordinary local path.
        auto parameter = (*literal.fd.parameters)[0];
        const variableSlot = allocateBytes(elementSize, elementSize);
        _locals[parameter] = variableSlot;

        // `for (i = 0; i < elements.length; ++i) { var = elements[i]; body }`.
        const index = compileSizeConstant(0);
        const length = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, length, elements);

        const conditionIndex = _code.length;
        const condition = allocate(ScalarType.bool_);
        _code ~= Instruction(
            Op.lessThanUnsigned8, condition, index, length,
        );
        const exitJump = emitJumpIfFalse(Operand(condition, ScalarType.bool_));

        _code ~= Instruction(
            indexLoadOp(elementSize), variableSlot, elements, index,
        );

        size_t[] bodyExits;
        auto previousExits = _applyBodyExits;
        _applyBodyExits = &bodyExits;
        compileStatement(literal.fd.fbody);
        _applyBodyExits = previousExits;

        const one = compileSizeConstant(1);
        _code ~= Instruction(Op.addInt8, index, index, one);
        _code ~= Instruction(Op.jump, cast(ushort) conditionIndex);

        patchJump(exitJump);
        foreach (patch; bodyExits)
            patchJump(patch);

        // The foreach lowering discards the apply's int result; yield zero.
        const result = allocate(ScalarType.int_);
        _code ~= Instruction(
            Op.loadConstant, result, constantIndex(0),
            cast(ushort) size(ScalarType.int_),
        );
        return Operand(result, ScalarType.int_);
    }

    // The delegate local invoked by `d()`, or null if `call` is not a call
    // through a delegate local. The callee is a `VarExp` of a `_delegateLocals`
    // entry.
    private DelegateLocal* delegateLocalOf(CallExp call) {
        auto variable = call.e1 is null ? null : call.e1.isVarExp;
        if (variable is null)
            return null;
        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            return null;
        return declaration in _delegateLocals;
    }

    // `d()` through a delegate local: the lambda's VM index lives in the first
    // word of the delegate slot and its captured context (the enclosing `this`
    // receiver offset) in the second. Pass the context as the lambda's hidden
    // `this` block, then dispatch through `callIndirect` on the index word.
    private Operand compileDelegateCall(
        DelegateLocal delegateLocal,
        CallExp call,
    ) {
        import std.conv: text;

        // Delegate calls with explicit arguments are not exercised; the captured
        // `this` is the only hidden argument these lambdas take.
        if (call.arguments !is null && call.arguments.length > 0)
            throw new Exception(text(
                "Unsupported delegate call with arguments in bytecode core: ",
                expressionChars(call),
            ));

        const layout = parameterLayout(delegateLocal.function_);
        const argumentArea = allocateBytes(layout.blockSize, 8);

        // The captured context word (second pair slot) is the receiver offset
        // the machine dereferences into the lambda's hidden `this` block.
        if (layout.hasThis)
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (argumentArea + layout.thisOffset),
                cast(ushort) (delegateLocal.offset + size_t.sizeof),
                cast(ushort) size(ScalarType.uint_),
            );

        const index = registerFunction(delegateLocal.function_);
        const returnType = _program.functions[index].returnType;
        const destination =
            (!returnType.isString && !returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(
            Op.callIndirect, delegateLocal.offset, argumentArea, destination,
        );
        return Operand(destination, returnType.scalar, returnType.isString);
    }

    // `fp()` through a function-pointer value: load the callee's run-time
    // function index from the pointer slot and dispatch through `callIndirect`.
    // The pointer carries the index (set by `&f`); the machine reads the
    // callee's parameter and result layout from that index, so the call site
    // need only place the arguments and a result slot.
    private Operand compileIndirectCall(CallExp call) {
        import std.conv: text;

        // DMD lowers `fp()` as `(*fp)()`: the callee operand is a `PtrExp` whose
        // dereferenced type is the function type `R function(Args...)`. The
        // callee's result type is that function type's `nextOf`; the pointer
        // slot holding the run-time index is the `PtrExp`'s sub-expression.
        auto deref = call.e1.isPtrExp;
        const returnType = resultType(deref.type.toBasetype.nextOf);

        const pointer = compileExpression(deref.e1);

        // No test exercises arguments through a function pointer; the callee's
        // argument layout is only known at run time, so supporting them safely
        // needs the layout derived from the function-pointer type, not yet done.
        if (call.arguments !is null && call.arguments.length > 0)
            throw new Exception(text(
                "Unsupported function-pointer call with arguments in bytecode "
                ~ "core: ",
                expressionChars(call),
            ));

        // An empty argument area: the callee has no parameters (the only form
        // supported here), so the machine copies zero parameter bytes from it.
        const argumentArea = allocateBytes(0, 8);

        const destination =
            (!returnType.isString && !returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(
            Op.callIndirect, pointer.offset, argumentArea, destination,
        );
        return Operand(destination, returnType.scalar, returnType.isString);
    }

    // Emit a single call argument into `slot` of the argument area: a `ref`
    // argument passes the caller-frame offset (dereferenced on entry, written
    // back on return); a by-value struct block-copies the whole struct; a
    // dynamic array copies its 16-byte descriptor; a scalar copies its value.
    private void emitCallArgument(
        in ushort slot,
        in bool isReference,
        Expression argument,
    ) {
        import dmd.astenums: TY;

        if (isReference) {
            const reference = referenceOffset(argument);
            _code ~= Instruction(
                Op.loadConstant,
                slot,
                constantIndex(reference),
                cast(ushort) size(ScalarType.uint_),
            );
            return;
        }

        if (argument.type !is null &&
            argument.type.toBasetype.ty == TY.Tstruct) {
            const source = structOperandOffset(argument);
            _code ~= Instruction(
                Op.copy,
                slot,
                source,
                cast(ushort) staticArraySize(argument.type),
            );
            return;
        }

        if (isDynamicArrayArgument(argument)) {
            const descriptor = arrayDescriptorOffset(
                dynamicArrayElementType(argument.type), argument,
            );
            _code ~= Instruction(
                Op.copy,
                slot,
                descriptor,
                cast(ushort) sliceDescriptorSize,
            );
            return;
        }

        // A `string` argument is an 8-byte slice descriptor; copy the whole
        // descriptor, not a single scalar byte.
        if (argument.type !is null && isStringType(argument.type)) {
            const operand = compileExpression(argument);
            _code ~= Instruction(
                Op.copy, slot, operand.offset, stringSliceSize,
            );
            return;
        }

        const operand = compileExpression(argument);
        _code ~= Instruction(
            Op.copy,
            slot,
            operand.offset,
            cast(ushort) size(operand.type),
        );
    }

    // Emit a throw of the plain "Range violation" message and yield a null
    // pointer operand, so the `m[k]` lowering's `(_d_arraybounds(...), null)`
    // false branch type-checks (the throw aborts before the null is used).
    private Operand compileRangeViolation() {
        const message = compileStringLiteralBytes("Range violation");
        _code ~= Instruction(Op.throwString, message);
        const offset =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        return Operand(
            offset, ScalarType.ulong_, false, true, ScalarType.int_,
        );
    }

    // An associative-array hook call: operate on the VM-owned map referenced by
    // the AA handle local. Each hook carries the AA as its first argument (a
    // VarExp, or `&aa`/`*aa` around one), and the key/value as later arguments.
    private Operand compileAssocArrayHook(
        CallExp call,
        in AssocArrayHook hook,
    ) {
        import std.conv: text;

        const handle = assocArrayHandleOffset((*call.arguments)[0]);

        with (AssocArrayHook) final switch (hook) {
            case none:
                throw new Exception("Unreachable AA hook.");

            case length: {
                const offset = allocate(ScalarType.ulong_);
                _code ~= Instruction(Op.aaLength, offset, handle);
                return Operand(offset, ScalarType.ulong_);
            }

            case getRvalue: {
                const key = compileExpression((*call.arguments)[1]);
                const offset = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.aaGetRvalue, offset, handle, key.offset,
                );
                return Operand(
                    offset, ScalarType.ulong_, false, true, ScalarType.int_,
                );
            }

            case getLvalue:
                return compileAssocArrayGetLvalue(call, handle);

            case in_: {
                const key = compileExpression((*call.arguments)[1]);
                const offset = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(Op.aaIn, offset, handle, key.offset);
                return Operand(
                    offset, ScalarType.ulong_, false, true, ScalarType.int_,
                );
            }

            case remove: {
                const key = compileExpression((*call.arguments)[1]);
                const offset = allocate(ScalarType.bool_);
                _code ~= Instruction(Op.aaRemove, offset, handle, key.offset);
                return Operand(offset, ScalarType.bool_);
            }

            case equal: {
                const right = assocArrayHandleOffset((*call.arguments)[1]);
                const offset = allocate(ScalarType.bool_);
                _code ~= Instruction(Op.aaEqual, offset, handle, right);
                return Operand(offset, ScalarType.bool_);
            }

            case dup: {
                const offset = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(Op.aaDup, offset, handle);
                return Operand(offset, ScalarType.ulong_);
            }

            case keys:
                return compileAssocArraySlice(Op.aaKeys, handle);

            case values:
                return compileAssocArraySlice(Op.aaValues, handle);
        }
    }

    // `m.keys` / `m.values`: a fresh `int[]` slice descriptor holding a copy of
    // the map's keys / values, rooted on the VM-owned heap.
    private Operand compileAssocArraySlice(in Op op, in ushort handle) {
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(op, offset, handle);
        return Operand(offset, ScalarType.int_);
    }

    // `m[k] = v` lowers to `_d_aaGetY(&m, k)` returning a slot pointer, written
    // through by the surrounding assignment. The core inserts directly and
    // yields a pointer to the (freshly inserted) value's slot so the write lands.
    private Operand compileAssocArrayGetLvalue(
        CallExp call,
        in ushort handle,
    ) {
        const key = compileExpression((*call.arguments)[1]);
        const offset =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.aaInsert, handle, key.offset, key.offset);
        _code ~= Instruction(Op.aaIn, offset, handle, key.offset);
        return Operand(
            offset, ScalarType.ulong_, false, true, ScalarType.int_,
        );
    }

    // The frame offset of an associative-array handle for `expression`: an AA
    // local VarExp, possibly wrapped in `&aa` (AddrExp) or `*aa` (PtrExp) by the
    // hook lowering.
    private ushort assocArrayHandleOffset(Expression expression) {
        import std.conv: text;

        auto inner = expression;
        if (auto address = inner.isAddrExp)
            inner = address.e1;
        if (auto deref = inner.isPtrExp)
            inner = deref.e1;

        if (auto variable = inner.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (declaration in _assocArrayLocals)
                    if (auto slot = declaration in _locals)
                        return *slot;

        throw new Exception(text(
            "Unsupported associative array operand in bytecode core: ",
            expressionChars(expression),
        ));
    }

    // `dest[] = a[] + b[]`: the druntime arrayOp call carries three slice
    // operands. Materialise each into a slice descriptor (the destination shares
    // its backing memory so the sums write through), then emit an element-wise
    // add-assign over the three descriptors.
    private Operand compileArrayOpAddAssign(CallExp call) {
        import std.conv: text;

        if (call.arguments is null || call.arguments.length != 3)
            throw new Exception(text(
                "Unsupported array operation in bytecode core: ",
                expressionChars(call),
            ));

        auto destination = (*call.arguments)[0].isSliceExp;
        if (destination is null)
            throw new Exception(text(
                "Unsupported array operation in bytecode core: ",
                expressionChars(call),
            ));

        const elementType =
            dynamicArrayDescriptor(destination.e1).elementType;
        const destinationSlice = arrayOpSlice(elementType, (*call.arguments)[0]);
        const leftSlice = arrayOpSlice(elementType, (*call.arguments)[1]);
        const rightSlice = arrayOpSlice(elementType, (*call.arguments)[2]);
        _code ~= Instruction(
            Op.arrayAddAssign4, destinationSlice, leftSlice, rightSlice,
        );
        return Operand.init;
    }

    // Materialise one operand of an element-wise array operation into a slice
    // descriptor sharing its source's backing memory. Only the slice form is
    // needed (the lowering wraps each operand in a `[]`).
    private ushort arrayOpSlice(
        in ScalarType elementType,
        Expression operand,
    ) {
        import std.conv: text;

        auto slice = operand.isSliceExp;
        if (slice is null)
            throw new Exception(text(
                "Unsupported array operation operand in bytecode core: ",
                expressionChars(operand),
            ));

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileSliceInto(offset, elementType, slice);
        return offset;
    }

    // The caller-frame offset of a `ref` argument: the slot of the local being
    // passed by reference, whether a scalar local or a dynamic-array local
    // (whose slot holds a 16-byte slice descriptor). Only a plain local lvalue
    // is supported.
    private ushort referenceOffset(Expression argument) {
        import std.conv: text;

        if (auto variable = argument.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto existing = declaration in _locals)
                    return *existing;
                if (auto existing = declaration in _dynamicArrayLocals)
                    return existing.offset;
            }

        // `append42(buffer.bytes)` / `append42(this.bytes)`: a `ref` to a struct
        // field binds to the field's inline slot (`base + field.offset`), so the
        // callee's writeback lands in the caller's struct.
        if (auto dot = argument.isDotVarExp)
            if (auto field = tryStructField(dot))
                return field.offset;

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

        // A struct comparison (`==`, `!=`, `<`, ... over struct operands): DMD
        // has already lowered the condition `assert_.e1` to the authoritative
        // bool (a bitwise `is` for a POD default `==`, an `opEquals`/`opCmp` call
        // otherwise). Compile that condition directly and assert it; the rendered
        // operands are dead code on a passing assert.
        import dmd.astenums: TY;
        if ((*call.arguments)[1].type.toBasetype.ty == TY.Tstruct ||
            (*call.arguments)[2].type.toBasetype.ty == TY.Tstruct)
            return compileBoolConditionAssert(assert_.e1, op);

        // Pointer relations `p < q`, `p == q`, `p is q` (and negations) compare
        // raw `size_t` pointer values; `is`/`!is` arrive only over pointers.
        if (isPointerType((*call.arguments)[1].type) ||
            isPointerType((*call.arguments)[2].type))
            return compilePointerComparisonAssert(
                op, (*call.arguments)[1], (*call.arguments)[2],
            );

        switch (op) {
            case "==", "!=", "<", "<=", ">", ">=":
                break;
            default:
                return false;
        }

        // `assert(m1 == m2)` over associative-array operands compares entry sets
        // via the VM-owned maps.
        if (op == "==" || op == "!=")
            if (tryAssocArrayComparisonAssert(
                    op, (*call.arguments)[1], (*call.arguments)[2]))
                return true;

        // `assert(a[] == b[])` over dynamic-array operands compares the slices
        // element-wise and renders each operand as `[e0, e1, ...]` on failure.
        if (op == "==" || op == "!=")
            if (tryArrayComparisonAssert(
                    op, (*call.arguments)[1], (*call.arguments)[2]))
                return true;

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

    // Assert the already-lowered boolean condition `condition` is true, throwing
    // a verbatim message naming the relation on failure. Used for struct
    // comparisons whose condition DMD has lowered to a bitwise `is`, an
    // `opEquals` call, or an `opCmp` relation; the condition is the authoritative
    // bool, so re-deriving it from the rendered operands is unnecessary.
    private bool compileBoolConditionAssert(
        Expression condition,
        in string op,
    ) {
        import std.conv: text;

        const operand = compileBoolValue(condition);
        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~= AssertDiagnostic(
            text("Assertion failure (", op, ")"),
            operand.offset,
            operand.offset,
            operand.type,
        );
        _code ~= Instruction(
            Op.assertTrueVerbatim, operand.offset, cast(ushort) diagnostic,
        );
        return true;
    }

    // Compile an expression to a one-byte boolean. A struct identity `a is b`
    // (DMD's lowering of a POD struct `==`) compares the two inline blocks
    // byte-wise; everything else is an ordinary boolean expression (an
    // `opEquals` call, an `opCmp` relation, a `&&` chain).
    private Operand compileBoolValue(Expression expression) {
        if (auto identity = expression.isIdentityExp)
            return compileStructIdentity(identity);
        return compileExpression(expression);
    }

    // `a is b` / `a !is b` over struct values (DMD's lowering of a POD struct
    // `==`/`!=`): compare the two inline blocks field by field and combine the
    // per-field results with `&&`, yielding a bool. Field-wise comparison sizes
    // each compare by the field's scalar type, ignoring inter-field padding.
    private Operand compileStructIdentity(
        imported!"dmd.expression".IdentityExp identity,
    ) {
        import dmd.tokens: EXP;

        const left = structOperandOffset(identity.e1);
        const right = structOperandOffset(identity.e2);
        const declaration = structDeclarationOf(identity.e1.type);

        const result = allocate(ScalarType.bool_);
        // Assume equal, then short-circuit to false on the first unequal field.
        _code ~= Instruction(Op.loadConstant, result, constantIndex(1), 1);

        size_t[] falseJumps;
        foreach (field; declaration.fields) {
            const fieldEqual = allocate(ScalarType.bool_);
            _code ~= Instruction(
                equalOp(size(scalarType(cast(Type) field.type))),
                fieldEqual,
                cast(ushort) (left + field.offset),
                cast(ushort) (right + field.offset),
            );
            falseJumps ~= emitJumpIfFalse(Operand(fieldEqual, ScalarType.bool_));
        }

        const endJump = emitJump;
        foreach (jump; falseJumps)
            patchJump(jump);
        _code ~= Instruction(Op.loadConstant, result, constantIndex(0), 1);
        patchJump(endJump);

        if (identity.op == EXP.notIdentity)
            _code ~= Instruction(Op.notBool, result, result);
        return Operand(result, ScalarType.bool_);
    }

    // `assert(p == q)`, `assert(p is q)`, `assert(p < q)`, ... over pointer
    // operands: compile both raw `size_t` pointer values and assert their
    // comparison. `is`/`!is` (identity) compare the same raw addresses as
    // `==`/`!=`; relations compare unsigned, as compiled pointer code does.
    private bool compilePointerComparisonAssert(
        in string op,
        Expression lhs,
        Expression rhs,
    ) {
        import std.conv: text;

        const lhsPointer = compileExpression(lhs);
        const rhsPointer = compileExpression(rhs);
        const condition = allocateBytes(1, 1);
        _code ~= Instruction(
            pointerComparisonOp(op),
            condition,
            lhsPointer.offset,
            rhsPointer.offset,
        );

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~= AssertDiagnostic(
            normalisedPointerOperator(op),
            lhsPointer.offset,
            rhsPointer.offset,
            ScalarType.ulong_,
        );
        _code ~= Instruction(Op.assertTrue, condition, cast(ushort) diagnostic);
        return true;
    }

    // `assert(a[] == b[])` / `assert(a[] != b[])` over dynamic-array operands:
    // build a slice descriptor for each operand, compare them element-wise, and
    // assert the result; on failure each operand renders as `[e0, e1, ...]`.
    // Null if either operand is not a dynamic-array slice.
    private bool tryArrayComparisonAssert(
        in string op,
        Expression lhs,
        Expression rhs,
    ) {
        auto lhsSlice = lhs.isSliceExp;
        auto rhsSlice = rhs.isSliceExp;
        if (lhsSlice is null || rhsSlice is null)
            return false;

        auto lhsDescriptor = dynamicArrayDescriptorOrNull(lhsSlice.e1);
        auto rhsDescriptor = dynamicArrayDescriptorOrNull(rhsSlice.e1);
        if (lhsDescriptor is null || rhsDescriptor is null)
            return false;

        const elementType = lhsDescriptor.elementType;
        const lhsOffset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileSliceInto(lhsOffset, elementType, lhsSlice);
        const rhsOffset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileSliceInto(rhsOffset, elementType, rhsSlice);

        const equal = allocateBytes(1, 1);
        _code ~= Instruction(
            sliceEqualOp(size(elementType)),
            equal,
            lhsOffset,
            rhsOffset,
        );

        // `==` holds when the slices are equal; `!=` holds when negated.
        ushort condition = equal;
        if (op == "!=") {
            condition = allocateBytes(1, 1);
            _code ~= Instruction(Op.notBool, condition, equal);
        }

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic(op, lhsOffset, rhsOffset, elementType, true);
        _code ~= Instruction(
            Op.assertTrue,
            condition,
            cast(ushort) diagnostic,
        );
        return true;
    }

    // `assert(m1 == m2)` / `assert(m1 != m2)` over associative arrays: compare
    // entry sets via the VM-owned maps. False unless both operands are AA-typed.
    private bool tryAssocArrayComparisonAssert(
        in string op,
        Expression lhs,
        Expression rhs,
    ) {
        import dmd.astenums: TY;

        if (lhs.type.toBasetype.ty != TY.Taarray ||
            rhs.type.toBasetype.ty != TY.Taarray)
            return false;

        const left = assocArrayHandleOffset(lhs);
        const right = assocArrayHandleOffset(rhs);
        const equal = allocateBytes(1, 1);
        _code ~= Instruction(Op.aaEqual, equal, left, right);

        // `==` holds when the maps are equal; `!=` holds when negated.
        ushort condition = equal;
        if (op == "!=") {
            condition = allocateBytes(1, 1);
            _code ~= Instruction(Op.notBool, condition, equal);
        }

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic(op, equal, equal, ScalarType.bool_);
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

    private ushort allocateBytes(in uint bytes, in uint alignmentArgument)
        @safe pure
    {
        // A zero alignment (a `void`-typed allocation, e.g. the result slot of a
        // `cast(void)expr` discarding a call result) would mask `_frameOffset`
        // to 0 via `& ~(alignment - 1)`; clamp it to 1 so the frame never
        // rewinds over live locals.
        const alignment = alignmentArgument == 0 ? 1 : alignmentArgument;
        _frameOffset = (_frameOffset + alignment - 1) & ~(alignment - 1);
        const offset = _frameOffset;
        if (offset > ushort.max)
            throw new Exception("Bytecode frame exceeds 16-bit offsets");

        _frameOffset += bytes;
        if (_frameOffset > _peakFrameOffset)
            _peakFrameOffset = _frameOffset;
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
        import dmd.astenums: TY;

        ParameterLayout layout;

        // A struct method takes its receiver as a hidden `this` block at the
        // start of the argument area, passed by reference: the caller stores the
        // receiver's frame offset, the machine copies the block in on entry and
        // writes the (possibly mutated) block back on return, matching `ref this`.
        if (auto structDeclaration = thisStructDeclaration(function_)) {
            auto thisType = structDeclaration.type;
            const structAlign = staticArrayAlign(thisType);
            const structBytes = cast(uint) staticArraySize(thisType);
            layout.blockSize =
                (layout.blockSize + structAlign - 1) & ~(structAlign - 1);
            layout.hasThis = true;
            layout.thisOffset = cast(ushort) layout.blockSize;
            layout.refParameters ~=
                RefParameter(cast(ushort) layout.blockSize, structBytes);
            layout.blockSize += structBytes;
        }

        if (function_.parameters is null)
            return layout;

        foreach (parameterIndex; 0 .. function_.parameters.length) {
            auto parameter = (*function_.parameters)[parameterIndex];

            // A non-string dynamic-array `T[]` parameter holds a 16-byte slice
            // descriptor in the callee frame. By value the caller copies the
            // descriptor in; a `ref T[]` instead passes the caller-frame offset
            // and writes the (possibly reallocated) descriptor back on return,
            // so an append inside the callee is visible to the caller.
            if (parameter.type.toBasetype.ty == TY.Tarray &&
                !isStringType(parameter.type))
            {
                enum descriptorAlign = cast(uint) size_t.sizeof;
                layout.blockSize =
                    (layout.blockSize + descriptorAlign - 1) & ~(descriptorAlign - 1);
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= parameter.isReference;
                if (parameter.isReference)
                    layout.refParameters ~= RefParameter(
                        cast(ushort) layout.blockSize, sliceDescriptorSize,
                    );
                layout.blockSize += sliceDescriptorSize;
                continue;
            }

            // A `string` parameter holds an 8-byte slice descriptor in the
            // callee frame; the caller copies the descriptor in by value.
            if (isStringType(parameter.type)) {
                layout.blockSize =
                    (layout.blockSize + 3) & ~3u;
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= false;
                layout.blockSize += stringSliceSize;
                continue;
            }

            // A by-value struct `S` parameter is a block of `Type.size()` bytes
            // at its DMD alignment in the argument area; the caller block-copies
            // its struct in, so the callee mutates only its private copy.
            if (parameter.type.toBasetype.ty == TY.Tstruct) {
                const structAlign = staticArrayAlign(parameter.type);
                const structBytes = cast(uint) staticArraySize(parameter.type);
                layout.blockSize =
                    (layout.blockSize + structAlign - 1) & ~(structAlign - 1);
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= false;
                layout.blockSize += structBytes;
                continue;
            }

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
                    RefParameter(cast(ushort) layout.blockSize, size(type));
            layout.blockSize += size(type);
        }

        return layout;
    }

    // A function result is either a scalar or a string slice. Only the string
    // case is non-scalar today (the leading edge of arrays); everything else
    // routes through the scalar path.
    private ResultType resultType(Type type) {
        import dmd.astenums: TY;

        if (isStringType(type))
            return ResultType(ScalarType.void_, true);

        // A non-string dynamic array `T[]` result is a 16-byte slice
        // descriptor; `elementType` gives the element size for indexing the
        // returned descriptor.
        if (type.toBasetype.ty == TY.Tarray)
            return ResultType(
                ScalarType.void_,
                false,
                true,
                dynamicArrayElementType(type),
            );

        // A by-value struct result is an inline block of `Type.size()` bytes,
        // copied back to the caller's destination on return like any other frame
        // block; field access then resolves against that destination's base.
        if (type.toBasetype.ty == TY.Tstruct)
            return ResultType(
                ScalarType.void_, false, false, ScalarType.void_,
                true, cast(uint) staticArraySize(type),
            );

        return ResultType(scalarType(type), false);
    }

    // The result type of a whole function. A constructor's nominal result is its
    // struct receiver, but the core consumes it only for side effects (the
    // receiver is passed by reference and mutated in place), so a constructor
    // returns void; every other function uses its declared return type.
    private ResultType functionResultType(FuncDeclaration function_) {
        if (function_.isCtorDeclaration !is null)
            return ResultType(ScalarType.void_, false);
        return resultType(returnType(function_));
    }

    // The element scalar type of a dynamic array `T[]`. For an array-of-arrays
    // (`int[][]`) the element is itself a `T[]`; return its inner element scalar
    // (`int`), the type used to size and index the innermost elements.
    private ScalarType dynamicArrayElementType(Type type) {
        import dmd.astenums: TY;

        auto element = type.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tarray)
            return scalarType(element.toBasetype.nextOf);
        return scalarType(element);
    }

    // True when a dynamic array's element is itself a dynamic array (`int[][]`):
    // each element is a 16-byte slice descriptor rather than a scalar.
    private bool dynamicArrayElementIsArray(Type type) {
        import dmd.astenums: TY;

        return type.toBasetype.nextOf.toBasetype.ty == TY.Tarray;
    }

    // Materialise a compile-time-constant `size_t` index into a frame slot, for
    // opcodes that take their index from a frame slot.
    private ushort compileSizeConstant(in size_t value) @safe pure {
        const offset = allocate(ScalarType.ulong_);
        _code ~= Instruction(
            Op.loadConstant,
            offset,
            constantIndex(value),
            cast(ushort) size(ScalarType.ulong_),
        );
        return offset;
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
    bool hasThis; // a struct method's hidden `this` receiver (passed by ref)
    ushort thisOffset; // frame offset of the hidden `this` block
}

private struct Operand {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType type;
    bool isString; // when set, `offset` holds a string-slice descriptor
    // When set, `offset` holds a raw `size_t` pointer value (8 bytes) into
    // VM-owned heap memory; `pointerElement` is the pointed-at element scalar,
    // giving the stride for arithmetic, indexing, dereference, and slicing.
    bool isPointer;
    imported!"quickbite.backends.bytecode.core.program".ScalarType
        pointerElement;
}

// A dynamic-array local: its slice-descriptor frame offset and the element
// type. `elementType` is the element scalar (for an array-of-arrays it is the
// innermost element scalar); when `elementIsArray` is set the element is itself
// a 16-byte slice descriptor (`int[][]`), so the outer element size is
// `sliceDescriptorSize` and indexing yields an inner descriptor.
private struct DynamicArrayLocal {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType elementType;
    bool elementIsArray;
}

// A delegate local (`auto d = () => this.field;`): a 16-byte slot holding a
// `{functionIndex, context}` pair. `offset` is that slot; `function_` is the
// captured lambda, giving the callee's layout and result type when `d()` is
// compiled. The context word is the enclosing method's `this` receiver offset.
private struct DelegateLocal {
    ushort offset;
    imported!"dmd.func".FuncDeclaration function_;
}

// A loop currently being compiled: the `jump` indices awaiting the loop's exit
// (`break`) and continue point (`continue`), plus the ident of an enclosing
// `label:` for labeled `break`/`continue` (null when unlabeled).
private struct LoopContext {
    size_t[] breakPatches;
    size_t[] continuePatches;
    const(void)* label;
    bool isSwitch; // a switch is a break target but not a continue target
}

// The switch currently being compiled, innermost last. Maps each case (and the
// default) to its body's instruction index for the dispatch chain, and holds
// the `jump` indices of `goto case`/`goto default` awaiting those indices.
private struct SwitchContext {
    size_t[const(void)*] caseIndices; // CaseStatement* -> body index
    size_t defaultIndex = size_t.max;
    size_t[][const(void)*] gotoCasePatches; // target CaseStatement* -> jumps
    size_t[] gotoDefaultPatches;
}

// A `try`/`finally` scope active while its try body is compiled. `finalbody` is
// the DMD `finally` statement, re-emitted inline on each exit edge that leaves
// the body. `labels` is the set of label idents defined inside the try body: a
// `goto` to a label in this set stays inside the scope (no finally), one to a
// label outside it exits the scope. `loopDepth` is `_loopStack.length` at push
// time, so a `break`/`continue` to an enclosing loop knows it exits this scope.
private struct TryFinallyContext {
    imported!"dmd.statement".Statement finalbody;
    bool[const(void)*] labels;
    size_t loopDepth;
}

// A struct local (or by-value struct parameter): the base offset of its inline
// frame block plus the DMD struct declaration giving each field's offset and
// type. A struct is a value type; the whole block is `Type.size()` bytes at
// `Type.alignsize()`, and each field lives at `base + field.offset`.
private struct StructLocal {
    ushort offset;
    imported!"dmd.dstruct".StructDeclaration declaration;
}

// An `outer[i]` element of an array-of-arrays local: the outer descriptor's
// frame offset, the slot holding the index `i`, and the inner descriptor loaded
// into a fresh slot. Reallocating the inner array (an append) must write the new
// inner descriptor back into the outer block at index `i`.
private struct OuterArrayElement {
    ushort outerOffset;
    ushort indexSlot;
    DynamicArrayLocal inner;
}

private imported!"quickbite.backends.bytecode.core.program".Op indexLoadOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.indexLoad1 : Op.indexLoad4;
}

private imported!"quickbite.backends.bytecode.core.program".Op pointerLoadOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.pointerLoad1 : Op.pointerLoad4;
}

private imported!"quickbite.backends.bytecode.core.program".Op pointerStoreOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.pointerStore1 : Op.pointerStore4;
}

private imported!"quickbite.backends.bytecode.core.program".Op pointerSliceOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.pointerSlice1 : Op.pointerSlice4;
}

private imported!"quickbite.backends.bytecode.core.program".Op indexStoreOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.indexStore1 : Op.indexStore4;
}

private imported!"quickbite.backends.bytecode.core.program".Op subSliceOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.subSlice1 : Op.subSlice4;
}

private imported!"quickbite.backends.bytecode.core.program".Op sliceCopyOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.sliceCopy1 : Op.sliceCopy4;
}

private imported!"quickbite.backends.bytecode.core.program".Op sliceEqualOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.sliceEqual1 : Op.sliceEqual4;
}

private imported!"quickbite.backends.bytecode.core.program".Op appendElementOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    if (elementSize == 1)
        return Op.appendElement1;
    return elementSize == 2 ? Op.appendElement2 : Op.appendElement4;
}

private imported!"quickbite.backends.bytecode.core.program".Op concatArraysOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.concatArrays1 : Op.concatArrays4;
}

private imported!"quickbite.backends.bytecode.core.program".Op dupArrayOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    if (elementSize == 1)
        return Op.dupArray1;
    return elementSize == 2 ? Op.dupArray2 : Op.dupArray4;
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

    // `wchar` (and `ushort`) widen to `dchar`/`int` zero-extended; the only
    // signed 2-byte source (`short`) is not exercised here.
    if (sourceSize == 2 && targetSize == 4 && !signed)
        return Op.zeroExtend2to4;

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

// The 8-byte unsigned relational opcode for a `size_t`/`ulong` comparison
// (e.g. a `foreach` index against `.length`).
private imported!"quickbite.backends.bytecode.core.program".Op
    unsignedComparisonOp8(
        in imported!"dmd.tokens".EXP op,
    ) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    import dmd.tokens: EXP;

    switch (op) with (EXP) {
        case lessThan: return Op.lessThanUnsigned8;
        case lessOrEqual: return Op.lessOrEqualUnsigned8;
        case greaterThan: return Op.greaterThanUnsigned8;
        case greaterOrEqual: return Op.greaterOrEqualUnsigned8;
        default: assert(0, "Unsupported unsigned 8-byte comparison operator.");
    }
}

// The comparison opcode for a pointer relation: identity and equality compare
// the raw 8-byte addresses, relations compare them as unsigned `size_t`.
private imported!"quickbite.backends.bytecode.core.program".Op
    pointerComparisonOp(in string operator) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;

    switch (operator) {
        case "==", "is": return Op.equal8;
        case "!=", "!is": return Op.notEqual8;
        case "<": return Op.lessThanUnsigned8;
        case "<=": return Op.lessOrEqualUnsigned8;
        case ">": return Op.greaterThanUnsigned8;
        case ">=": return Op.greaterOrEqualUnsigned8;
        default: assert(0, "Unsupported pointer comparison operator.");
    }
}

// The relational operator a pointer comparison renders in a failure message:
// identity `is`/`!is` render as `==`/`!=`, which `invertedOperator` understands.
private string normalisedPointerOperator(in string operator)
    @safe @nogc nothrow pure {
    switch (operator) {
        case "is": return "==";
        case "!is": return "!=";
        default: return operator;
    }
}

// DMD lowers associative-array operations to druntime template hooks in
// `core.internal.newaa` and `object`; the core intercepts them at the call site
// and operates on its VM-owned map table instead of executing the hook bodies.
private enum AssocArrayHook {
    none,
    length,
    getRvalue,
    getLvalue,
    in_,
    remove,
    equal,
    dup,
    keys,
    values,
}

private AssocArrayHook assocArrayHook(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.algorithm: startsWith;
    import std.conv: text;

    if (function_ is null || function_.parent is null ||
        function_.parent.isTemplateInstance is null)
        return AssocArrayHook.none;

    const name = text(function_.toPrettyChars);
    static immutable hooks = [
        Hook("core.internal.newaa._d_aaLen!(", AssocArrayHook.length),
        Hook("core.internal.newaa._d_aaGetRvalueX!(", AssocArrayHook.getRvalue),
        Hook("core.internal.newaa._d_aaGetY!(", AssocArrayHook.getLvalue),
        Hook("core.internal.newaa._d_aaIn!(", AssocArrayHook.in_),
        Hook("core.internal.newaa._d_aaDel!(", AssocArrayHook.remove),
        Hook("core.internal.newaa._d_aaEqual!(", AssocArrayHook.equal),
        Hook("object.dup!(", AssocArrayHook.dup),
        Hook("object.keys!(", AssocArrayHook.keys),
        Hook("object.values!(", AssocArrayHook.values),
    ];

    foreach (candidate; hooks)
        if (name.startsWith(candidate.prefix))
            return candidate.hook;

    return AssocArrayHook.none;
}

private struct Hook {
    string prefix;
    AssocArrayHook hook;
}

// The druntime `_d_arraybounds*` bounds-failure helper, the false branch of
// DMD's `m[k]` lowering. Matched by name; reaching it means a missing key.
private bool isArrayBoundsCall(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.algorithm: startsWith;

    return function_.ident !is null &&
        function_.ident.toString.startsWith("_d_arraybounds");
}

// True for the druntime `core.internal.array.operations.arrayOp` template
// instantiated with `["+", "="]`, the lowering of `dest[] = a[] + b[]`. Matched
// by pretty name prefix and the template value arguments, like the interpreter.
private bool isArrayOpAddAssign(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.dtemplate: isExpression;
    import std.algorithm: startsWith;
    import std.conv: text;

    auto instance = function_.parent is null
        ? null
        : function_.parent.isTemplateInstance;
    if (instance is null || instance.tiargs is null)
        return false;

    if (!text(function_.toPrettyChars)
            .startsWith("core.internal.array.operations.arrayOp!("))
        return false;

    string[] operators;
    foreach (argument; *instance.tiargs) {
        auto expression = isExpression(argument);
        if (expression is null)
            continue;

        auto literal = expression.isStringExp;
        if (literal is null)
            return false;

        operators ~= operatorText(literal);
    }

    return operators == ["+", "="];
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

    // Only an immutable char element is a `string`/`wstring`/`dstring`; a
    // mutable `char[]` is an ordinary dynamic array with heap-backed storage.
    if (!element.isImmutable)
        return false;

    switch (element.toBasetype.ty) with (TY) {
        case Tchar, Twchar, Tdchar:
            return true;
        default:
            return false;
    }
}

// A non-string dynamic-array `T[]` call argument, passed by value as a 16-byte
// slice descriptor.
private bool isDynamicArrayArgument(
    imported!"dmd.expression".Expression argument,
) {
    import dmd.astenums: TY;

    return argument.type !is null &&
        argument.type.toBasetype.ty == TY.Tarray &&
        !isStringType(argument.type);
}

// True when `type` is a raw pointer `T*` (not a function pointer or delegate);
// these flow through frame slots as a `size_t` address into VM-owned heap.
private bool isPointerType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type !is null && type.toBasetype.ty == TY.Tpointer;
}

// The struct declaration a pointer `S*` points at, or null if `type` is not a
// pointer to a struct.
private imported!"dmd.dstruct".StructDeclaration structPointerDeclaration(
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: TY;
    import dmd.mtype: TypeStruct;

    if (type is null || type.toBasetype.ty != TY.Tpointer)
        return null;
    auto pointed = type.toBasetype.nextOf;
    if (pointed is null || pointed.toBasetype.ty != TY.Tstruct)
        return null;
    return (cast(TypeStruct) pointed.toBasetype).sym;
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

// True iff `function_` is a `_aApply*` UTF-string foreach helper, setting
// `mode` to its transcode. DMD names them by the source/target code-unit widths
// (`c`=char, `w`=wchar, `d`=dchar; an `R` prefix marks `foreach_reverse`).
private bool stringForeachApplyMode(
    imported!"dmd.func".FuncDeclaration function_,
    out imported!"quickbite.backends.bytecode.core.program".TranscodeMode mode,
) {
    import quickbite.backends.bytecode.core.program: TranscodeMode;

    if (function_.ident is null)
        return false;

    with (TranscodeMode) switch (function_.ident.toString) {
        case "_aApplycd1": mode = utf8ToDchar; return true;
        case "_aApplywd1": mode = utf16ToDchar; return true;
        case "_aApplydc1": mode = dcharToUtf8; return true;
        case "_aApplyRwd1": mode = utf16ToDcharReverse; return true;
        default: return false;
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

// `fp()`: the callee is a function-pointer value, not a named function. DMD
// lowers the call through the pointer as `(*fp)()`, so the callee operand is a
// `PtrExp` whose dereferenced type is a function type (`int function()`).
private bool isFunctionPointerCall(imported!"dmd.expression".CallExp call) {
    import dmd.astenums: TY;

    auto deref = call.e1 is null ? null : call.e1.isPtrExp;
    if (deref is null || deref.type is null)
        return false;
    return deref.type.toBasetype.ty == TY.Tfunction;
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

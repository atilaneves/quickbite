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
    in string[] archiveImportPaths = null,
) {
    auto compiler = new Compiler;
    compiler._archiveImportPaths = archiveImportPaths;
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
        AssertDiagnostic, CatchClause, ClassInfo, CompiledFunction,
        Instruction, NativeCall, Op, Program,
        RefParameter, ResultType, ScalarType, StructDisplayField,
        VirtualFunction, isSigned,
        nativeArgumentSlotSize, noCatchObjectField, noExceptionClass,
        noOutParameterOffset, size, sliceDescriptorSize;
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AddAssignExp, AddrExp, ArrayLengthExp, ArrayLiteralExp,
        AssocArrayLiteralExp, AssertExp,
        AssignExp, BinExp, BlitExp, CallExp, CastExp, CatAssignExp,
        CatElemAssignExp, CatExp,
        CmpExp, CondExp, ConstructExp, DelegateFuncptrExp, DelegatePtrExp,
        DivExp, DotIdExp, DotVarExp, Expression,
        IdentityExp, IndexExp, LogicalExp, MulExp, FuncExp, DelegateExp,
        NegExp, NewExp, NotExp, OrExp, PostExp, PtrExp, RealExp, SliceExp,
        StringExp, StructLiteralExp, SymOffExp, ThrowExp, TupleExp, TypeidExp;
    import dmd.arraytypes: Expressions;
    import dmd.dclass: ClassDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Catch, Statement;

    private Program* _program;
    // Import paths whose modules are defined by a separately compiled
    // archive already loaded into the process: a function declared under one
    // of these is compiled as a native call regardless of its parsed body
    // (see `isArchiveBackedFunction`), since that body is a source-rewrite
    // artifact and the archive's own compiled definition is the one that
    // actually runs.
    private const(string)[] _archiveImportPaths;
    private FuncDeclaration[] _functions;
    private size_t[FuncDeclaration] _functionIndices;
    private ushort[imported!"dmd.dclass".ClassDeclaration] _classIndices;
    private Instruction[] _code;
    private uint _frameOffset;
    // The high-water mark of `_frameOffset` across the current function body.
    // `frameSize` is computed from this peak so transient scopes that reuse
    // frame space (and any `_frameOffset` rewind) never under-size the frame.
    private uint _peakFrameOffset;
    private ushort[VarDeclaration] _locals;
    // Locals whose slot is a static array `T[N]` stored inline in the frame;
    // the value records the slot offset for indexing and block copies.
    private ushort[VarDeclaration] _staticArrayLocals;
    // Locals whose slot holds a dynamic-array slice descriptor {ptr, length};
    // the value records the slot offset and the element scalar type, giving the
    // element size for indexing and heap allocation.
    private DynamicArrayLocal[VarDeclaration] _dynamicArrayLocals;
    // Locals whose slot holds a raw `size_t` pointer value (`T* p`); the value
    // records the pointed-at element scalar for opcode selection.
    private ScalarType[VarDeclaration] _pointerLocals;
    // `ref` locals whose slot holds a raw pointer to the aliased storage.
    private ScalarType[VarDeclaration] _refLocalPointers;
    // Locals whose slot holds a `{double re, double im}` cdouble value.
    private bool[VarDeclaration] _complexDoubleLocals;
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
    // Lazy parameters are caller-supplied delegate pairs whose targets are
    // known only at run time.
    private ushort[VarDeclaration] _lazyDelegateLocals;
    private bool[VarDeclaration] _lazyDelegateDeclarations;
    // A delegate-typed parameter's 16-byte `{functionIndex, context}` slot;
    // unlike `_delegateLocals`, its target is a run-time value with no known
    // `FuncDeclaration`, so calling through it uses the declared delegate
    // type's parameter list rather than a specific callee's layout.
    private ushort[VarDeclaration] _delegateParameterLocals;
    private FuncDeclaration[VarDeclaration] _staticDelegateAssocArrays;
    private FuncDeclaration _latestStaticDelegateAssocArrayFunction;
    // Locals whose 8-byte slot holds a raw `size_t` pointer to a heap-allocated
    // struct block (`S* p = new S(...)`); the value is the struct declaration,
    // giving each field's offset and type so `p.field` resolves to a load/store
    // through the pointer at `ptr + field.offset`.
    private imported!"dmd.dstruct".StructDeclaration[VarDeclaration]
        _structPointerLocals;
    private imported!"dmd.dclass".ClassDeclaration[VarDeclaration]
        _classPointerLocals;
    // Named catch variables for the narrow Exception/Throwable object surface:
    // each synthetic object exposes native {ptr, length} string descriptors
    // for `msg` and, when a finally throw chains a body exception, `next.msg`.
    private ExceptionObjectLocal[VarDeclaration] _exceptionObjectLocals;
    // The receiver of the method currently being compiled, if any: the base
    // offset of the hidden `this` block in the frame plus the struct
    // declaration, so an unqualified `this.field` resolves against it.
    private StructLocal _thisLocal;
    private bool _hasThis;
    private ushort _nestedContextOffset = ushort.max;
    private ushort _classThisOffset = ushort.max;
    private bool _hasClassThis;
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
    private ushort _pendingFinallyExceptionMessageOffset = noCatchObjectField;
    private ushort _pendingFinallyExceptionClassIndex = noExceptionClass;
    private ushort _activeDollarLength = ushort.max;
    private size_t[ulong] _constantIndices;
    // Cache for `zeroRealConstantIndex`: every call site wants the same
    // all-zero-bytes `real` pool entry, so remember the first one's index
    // instead of appending a fresh duplicate per call site. `_hasZero...`
    // distinguishes "not yet computed" from a legitimate index 0.
    private bool _hasZeroRealConstantIndex;
    private ushort _zeroRealConstantIndex;
    private ModuleScalarVariable[VarDeclaration] _moduleScalarVariables;
    private ModuleDynamicArrayVariable[VarDeclaration]
        _moduleDynamicArrayVariables;
    private ModuleStructVariable[VarDeclaration] _moduleStructVariables;
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
    // Nesting depth of conditional/repeated statement bodies (`if`/`else`,
    // loop, `switch`, `try`/`catch`/`finally`, `with`) around the statement
    // currently being compiled. Zero means every earlier statement in the
    // current function is guaranteed to have run exactly once before this
    // point, in lexical order.
    private uint _controlFlowDepth;
    // True when the current function has any `label:`/`goto`, which breaks
    // lexical-order dominance: a backward goto can re-enter code the compiler
    // already treated as having run.
    private bool _functionHasLabels;

    private static struct DynamicArrayRefWriteBack {
        ushort valueOffset;
        ushort descriptorOffset;
        ushort indexOffset;
        ushort elementSize;
    }

    private static struct StructPointerRefWriteBack {
        ushort valueOffset;
        ushort pointerOffset;
        ushort valueSize;
    }

    // A scalar `ref` argument bound to a class field (`verify(c.value, ...)`):
    // the field's heap storage has no caller-frame offset of its own, so
    // (mirroring `StructPointerRefWriteBack`) the value is mirrored into a
    // fresh frame slot for the call and copied back through the field's real
    // address afterward. `pointerSlot`/`fieldOffset` are the match key: two
    // arguments reaching the same class instance's same field via the same
    // receiver slot share one mirror slot, so `refAliasGroups` (keyed on that
    // shared caller-frame offset, same as any other ref argument) gives them
    // one identity for the call's duration.
    private static struct ClassFieldRefWriteBack {
        ushort valueOffset;
        ushort addressOffset;
        ushort pointerSlot;
        ushort fieldOffset;
        ushort valueSize;
    }

    // The struct-pointer counterpart of `ClassFieldRefWriteBack`: a scalar
    // `ref` argument reached through a struct pointer (`setTo(carrier.value,
    // ...)` where `carrier` is `Holder*`, which DMD represents as
    // `(*carrier).value`). The field's heap storage has no caller-frame
    // offset of its own either, so the same mirror-and-writeback pattern
    // applies, keyed on the same `pointerSlot`/`fieldOffset` pair.
    private static struct StructPointerFieldRefWriteBack {
        ushort valueOffset;
        ushort addressOffset;
        ushort pointerSlot;
        ushort fieldOffset;
        ushort valueSize;
    }

    // A scalar `ref` argument bound to a `__gshared`/`static` module variable
    // (`bump(counter)`): the variable lives in `_program.moduleData`, a
    // different address space than the frame-relative offsets the ref-slot
    // machinery otherwise passes around, so (mirroring
    // `StructPointerRefWriteBack`) its current value is mirrored into a fresh
    // frame slot for the call and copied back afterward.
    private static struct ModuleScalarRefWriteBack {
        ushort valueOffset;
        ushort moduleOffset;
        ushort valueSize;
    }

    // A `ref` argument bound to a `ref`-local that is itself
    // `_refLocalPointers`-backed (an alias to an array element, a scalar
    // class field, or a field reached through a class/struct slice field's
    // element): the local's own frame slot holds the pointee's runtime
    // address rather than the pointee itself, so (mirroring
    // `ClassFieldRefWriteBack`) the value is mirrored into a fresh frame
    // slot for the call and copied back through that address afterward. The
    // address slot itself is the match key: two arguments naming the same
    // ref-local share one mirror slot.
    private static struct RefLocalPointerRefWriteBack {
        ushort valueOffset;
        ushort addressOffset;
        ushort valueSize;
    }

    // A `ref` argument that dereferences a genuine runtime pointer value
    // (`bump(*p)` where `p` is a plain pointer local/parameter/field holding
    // an address computed earlier, not a folded `*&lvalue`): the pointee's
    // real storage is only reachable through that runtime address, so
    // (mirroring `RefLocalPointerRefWriteBack`) the value is mirrored into a
    // fresh frame slot for the call and written back through the same
    // address afterward.
    private static struct PointerDereferenceRefWriteBack {
        ushort valueOffset;
        ushort addressOffset;
        ushort valueSize;
    }

    private static struct MethodReceiver {
        ushort offset;
        ushort writeBackFrameIndex;
        ushort writeBackSize;
    }

    private void compileFunctionBody(in size_t index) {
        // Only the entry (index 0) can be a unittest body; any lazily
        // compiled callee is an ordinary function.
        if (index > 0)
            _inUnittestEntry = false;

        auto function_ = _functions[index];

        // A receiver-less archive-backed function's direct call always goes
        // through `compileCall`'s native-leaf path and never reaches here;
        // any archive-backed function that does reach `compileFunctionBody`
        // was therefore registered by address instead -- `&s.method`
        // (`emitDelegateValue`), `&freeFunction` (`functionPointer`), or
        // virtual-dispatch table registration. Compiling the body here would
        // run the archive module's stale rewritten source, exactly what
        // this mechanism exists to never do; decline unconditionally,
        // regardless of receiver kind or entry point.
        if (isArchiveBackedFunction(function_)) {
            import std.conv: text;

            throw new Exception(text(
                "`",
                function_.ident is null
                    ? text(function_.toPrettyChars)
                    : function_.ident.toString,
                "` is an archive-backed function reached by address: ",
                "routing it through the native bridge or its stale ",
                "rewritten source is unsupported",
            ));
        }

        _code = null;
        _locals = null;
        _staticArrayLocals = null;
        _dynamicArrayLocals = null;
        _pointerLocals = null;
        _refLocalPointers = null;
        _complexDoubleLocals = null;
        _assocArrayLocals = null;
        _delegateLocals = null;
        _lazyDelegateLocals = null;
        _delegateParameterLocals = null;
        _structLocals = null;
        _structPointerLocals = null;
        _classPointerLocals = null;
        _exceptionObjectLocals = null;
        _hasThis = false;
        _hasClassThis = false;
        _nestedContextOffset = ushort.max;
        _classThisOffset = ushort.max;
        _hasNestedContext = false;
        _thisLocal = StructLocal.init;
        _withDerefBases = null;
        _labelTargets = null;
        _pendingGotos = null;
        _loopStack = null;
        _switchStack = null;
        _tryFinallyStack = null;
        _pendingLoopLabel = null;
        _pendingFinallyExceptionMessageOffset = noCatchObjectField;
        _pendingFinallyExceptionClassIndex = noExceptionClass;
        _activeDollarLength = ushort.max;
        _applyBodyExits = null;
        _controlFlowDepth = 0;
        {
            bool[const(void)*] labels;
            collectLabels(function_.fbody, labels);
            _functionHasLabels = labels.length > 0;
        }

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
            if (function_.vthis !is null)
                _capturedOffsets[function_.vthis] = layout.thisOffset;
            _hasNestedContext = _thisLocal.declaration !is null &&
                _thisLocal.declaration.isNested;
        }
        if (layout.hasNestedContext) {
            _hasNestedContext = true;
            _nestedContextOffset = layout.nestedContextOffset;
        }
        if (layout.hasClassThis) {
            _hasClassThis = true;
            _classThisOffset = layout.classThisOffset;
            // A nested function (an IIFE guarding a `@trusted` block is the
            // common druntime shape) that reads the enclosing class method's
            // `this` receives it through the same captured-frame-offset
            // mechanism as any other captured outer local, mirroring the
            // struct-receiver case just above.
            if (function_.vthis !is null)
                _capturedOffsets[function_.vthis] = layout.classThisOffset;
        }
        if (function_.parameters !is null)
            foreach (parameterIndex; 0 .. function_.parameters.length) {
                auto parameter = (*function_.parameters)[parameterIndex];
                const offset = layout.offsets[parameterIndex];
                _capturedOffsets[parameter] = offset;

                if (parameterIsLazy(parameter)) {
                    _lazyDelegateLocals[parameter] = offset;
                    _lazyDelegateDeclarations[parameter] = true;
                    continue;
                }

                // A dynamic-array parameter (including `string`) is a 16-byte
                // slice descriptor, tracked like a dynamic-array local rather
                // than a scalar slot. `elementIsArray` marks a `T[N][]`/`T[][]`
                // parameter whose elements are themselves heap-allocated inner
                // descriptors, matching how a same-typed local is tracked
                // (`arrayElementIsArray`, below) so a promoted-cell array
                // passed as an argument keeps its authoritative row storage in
                // the callee instead of falling back to a flat scalar stride.
                if (parameter.type.toBasetype.ty == TY.Tarray) {
                    _dynamicArrayLocals[parameter] = DynamicArrayLocal(
                        offset, dynamicArrayElementType(parameter.type),
                        arrayElementIsArray(parameter.type),
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

                // A by-value static-array parameter is an inline block, tracked
                // like a static-array local so indexing resolves against it.
                if (parameter.type.toBasetype.ty == TY.Tsarray) {
                    _staticArrayLocals[parameter] = offset;
                    continue;
                }

                if (parameter.type.toBasetype.ty == TY.Tclass) {
                    _locals[parameter] = offset;
                    _classPointerLocals[parameter] =
                        parameter.type.toBasetype.isTypeClass.sym;
                    continue;
                }

                // A delegate-typed parameter is a caller-supplied 16-byte
                // `{functionIndex, context}` pair whose actual callee is a
                // run-time value; calling through it dispatches by that
                // pair's own function-index word rather than a statically
                // known `FuncDeclaration`.
                if (parameter.type.toBasetype.ty == TY.Tdelegate) {
                    _delegateParameterLocals[parameter] = offset;
                    continue;
                }

                _locals[parameter] = offset;
                if (isPointerType(parameter.type))
                    _pointerLocals[parameter] =
                        pointerElementScalar(parameter.type);
            }

        // A function with a named `out(result)` contract gets a synthesized
        // `result` local (DMD's `vresult`): every `return expr;` in `fbody`
        // is rewritten to `result = expr; goto Lresult;`, with the ensure
        // block and a final `return result;` spliced in after it. Declare it
        // like any other local with no initializer so both the assignment
        // and the later read resolve to the same frame slot.
        if (function_.vresult !is null)
            compileVariableDeclaration(function_.vresult);

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

        import quickbite.frontend.dmd.functions: ensureFunctionBodySemantic;

        ensureFunctionBodySemantic(function_);

        if (_program is null)
        {
            _program = new Program;
            // A running machine executes this segment directly while lazy
            // compilation can append module slots. Reserve every representable
            // byte now so such appends cannot relocate raw module addresses.
            _program.moduleData.reserve(ushort.max);
        }

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
            layout.hasThis,
        );
        return cast(ushort) index;
    }

    private void compileStatement(Statement statement) {
        import std.conv: text;

        // DMD's `scope(exit)`/`scope(success)` lowering (`Statement.scopeCode`)
        // rewrites the original statement's slot in its enclosing
        // `CompoundStatement` to `null`, moving its content into a
        // `TryFinallyStatement` appended right after it; a null statement is
        // that lowering's documented no-op placeholder, not an error.
        if (statement is null)
            return;

        if (auto scope_ = statement.isScopeStatement) {
            compileStatement(scope_.statement);
            return;
        }

        if (auto asm_ = statement.isCompoundAsmStatement) {
            compileInlineAsm(asm_);
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

            compileReturnStatement(return_);
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

    // Compile a statement that a later statement is not guaranteed to run
    // after (an `if`/`else` arm, a loop body, a `switch` body, a `try`/
    // `catch`/`finally` body, or a `with` body): bump the control-flow depth
    // around it so a nested assignment can tell it is not at unconditional
    // straight-line depth.
    private void compileNestedStatement(Statement statement) {
        ++_controlFlowDepth;
        compileStatement(statement);
        --_controlFlowDepth;
    }

    // Decode only the full inline-asm instruction sequences the VM knows. The
    // frontend preserves every token before DMD consumes the asm statements;
    // every other sequence remains explicitly unsupported.
    private void compileInlineAsm(
        imported!"dmd.statement".CompoundAsmStatement compound,
    ) {
        if (tryCompileAtomicLoadAsm(compound))
            return;
        compileUnsignedMultiplyAsm(compound);
    }

    // `core.internal.atomic.atomicLoad` for an 8-byte value on x86_64 uses a
    // locked compare-and-exchange to read `src`, then writes RAX through
    // `resultValuePtr`. This is accepted only as the complete token sequence;
    // it lowers to one host atomic read rather than pretending an ordinary
    // pointer load has the same memory-order semantics.
    private bool tryCompileAtomicLoadAsm(
        imported!"dmd.statement".CompoundAsmStatement compound,
    ) {
        import quickbite.frontend.dmd.functions: inlineAsmInstructions;

        const instructions = inlineAsmInstructions(compound);
        if (instructions.length != 10 ||
            !isAsmIdentifier(instructions[0], 0, "push") ||
            !isAsmIdentifier(instructions[0], 1, "RBX") ||
            instructions[0].length != 2 ||
            !isAsmIdentifier(instructions[1], 0, "mov") ||
            !isAsmIdentifier(instructions[1], 1, "RDX") ||
            !isAsmPunctuation(instructions[1], 2, ",") ||
            !isAsmInteger(instructions[1], 3, "0") ||
            instructions[1].length != 4 ||
            !isAsmIdentifier(instructions[2], 0, "mov") ||
            !isAsmIdentifier(instructions[2], 1, "RAX") ||
            !isAsmPunctuation(instructions[2], 2, ",") ||
            !isAsmInteger(instructions[2], 3, "0") ||
            instructions[2].length != 4 ||
            !isAsmIdentifier(instructions[3], 0, "mov") ||
            !isAsmIdentifier(instructions[3], 1, "RCX") ||
            !isAsmPunctuation(instructions[3], 2, ",") ||
            !isAsmIdentifier(instructions[3], 3, "src") ||
            instructions[3].length != 4 ||
            !isAsmIdentifier(instructions[4], 0, "lock") ||
            instructions[4].length != 1 ||
            !isAsmIdentifier(instructions[5], 0, "cmpxchg") ||
            !isAsmPunctuation(instructions[5], 1, "[") ||
            !isAsmIdentifier(instructions[5], 2, "RCX") ||
            !isAsmPunctuation(instructions[5], 3, "]") ||
            !isAsmPunctuation(instructions[5], 4, ",") ||
            !isAsmIdentifier(instructions[5], 5, "RDX") ||
            instructions[5].length != 6 ||
            !isAsmIdentifier(instructions[6], 0, "lea") ||
            !isAsmIdentifier(instructions[6], 1, "RBX") ||
            !isAsmPunctuation(instructions[6], 2, ",") ||
            !isAsmIdentifier(instructions[6], 3, "resultValuePtr") ||
            instructions[6].length != 4 ||
            !isAsmIdentifier(instructions[7], 0, "mov") ||
            !isAsmIdentifier(instructions[7], 1, "RBX") ||
            !isAsmPunctuation(instructions[7], 2, ",") ||
            !isAsmPunctuation(instructions[7], 3, "[") ||
            !isAsmIdentifier(instructions[7], 4, "RBX") ||
            !isAsmPunctuation(instructions[7], 5, "]") ||
            instructions[7].length != 6 ||
            !isAsmIdentifier(instructions[8], 0, "mov") ||
            !isAsmPunctuation(instructions[8], 1, "[") ||
            !isAsmIdentifier(instructions[8], 2, "RBX") ||
            !isAsmPunctuation(instructions[8], 3, "]") ||
            !isAsmPunctuation(instructions[8], 4, ",") ||
            !isAsmIdentifier(instructions[8], 5, "RAX") ||
            instructions[8].length != 6 ||
            !isAsmIdentifier(instructions[9], 0, "pop") ||
            !isAsmIdentifier(instructions[9], 1, "RBX") ||
            instructions[9].length != 2)
            return false;

        const source = asmPointerLocal("src");
        const result = asmPointerLocal("resultValuePtr");
        if (source.pointerElement != ScalarType.ulong_ ||
            result.pointerElement != ScalarType.ulong_)
            throw new Exception("Unsupported inline asm atomic-load operand.");

        const loaded = allocate(ScalarType.ulong_);
        const zero = compileSizeConstant(0);
        _code ~= Instruction(
            Op.atomicLoad8,
            loaded,
            source.offset,
            zero,
        );
        _code ~= Instruction(Op.pointerStore8, loaded, result.offset, zero);
        return true;
    }

    // Decode the unsigned checked-multiply instruction shape used by portable
    // D source with an x86 runtime fast path.
    private void compileUnsignedMultiplyAsm(
        imported!"dmd.statement".CompoundAsmStatement compound,
    ) {
        import quickbite.frontend.dmd.functions: inlineAsmInstructions;
        import std.conv: text;

        const instructions = inlineAsmInstructions(compound);
        if (instructions.length == 0)
            throw new Exception("Inline asm was not preserved by the frontend.");

        if (instructions.length != 4 ||
            instructions[0].length != 4 ||
            instructions[1].length != 2 ||
            instructions[2].length != 4 ||
            instructions[3].length != 2 ||
            !isAsmIdentifier(instructions[0], 0, "mov") ||
            !isAsmIdentifier(instructions[0], 1, "EAX", "RAX") ||
            !isAsmPunctuation(instructions[0], 2, ",") ||
            !isAsmIdentifier(instructions[0], 3) ||
            !isAsmIdentifier(instructions[1], 0, "mul") ||
            !isAsmIdentifier(instructions[1], 1) ||
            !isAsmIdentifier(instructions[2], 0, "mov") ||
            !isAsmIdentifier(instructions[2], 1) ||
            !isAsmPunctuation(instructions[2], 2, ",") ||
            !isAsmIdentifier(instructions[2], 3) ||
            !isAsmIdentifier(instructions[3], 0, "setc") ||
            !isAsmIdentifier(instructions[3], 1) ||
            instructions[0][1].spelling != instructions[2][3].spelling)
            throw new Exception(text(
                "Unsupported inline asm instruction sequence: ",
                instructions,
            ));

        const source = asmLocal(instructions[0][3].spelling);
        const rhs = asmLocal(instructions[1][1].spelling);
        const destination = asmLocal(instructions[2][1].spelling);
        const carryDestination = asmLocal(instructions[3][1].spelling);
        if (rhs.type != source.type || destination.type != source.type ||
            carryDestination.type != ScalarType.bool_ ||
            (source.type != ScalarType.uint_ &&
                source.type != ScalarType.ulong_) ||
            (size(source.type) == uint.sizeof &&
                instructions[0][1].spelling != "EAX") ||
            (size(source.type) == ulong.sizeof &&
                instructions[0][1].spelling != "RAX"))
            throw new Exception("Unsupported inline asm checked multiply.");

        const result = allocateBytes(
            cast(uint) (size(source.type) + bool.sizeof),
            cast(uint) size(source.type),
        );
        _code ~= Instruction(
            size(source.type) == uint.sizeof
                ? Op.mulUnsignedInt4WithCarry
                : Op.mulUnsignedInt8WithCarry,
            result,
            source.offset,
            rhs.offset,
        );
        _code ~= Instruction(
            Op.copy,
            destination.offset,
            result,
            cast(ushort) size(source.type),
        );
        _code ~= Instruction(
            Op.copy,
            carryDestination.offset,
            cast(ushort) (result + size(source.type)),
            cast(ushort) bool.sizeof,
        );
    }

    private static bool isAsmIdentifier(
        in imported!"quickbite.frontend.dmd.functions".InlineAsmToken[] tokens,
        in size_t index,
        in string spelling = null,
        in string alternativeSpelling = null,
    ) @safe pure nothrow @nogc {
        return index < tokens.length && tokens[index].kind == "identifier" &&
            (spelling is null || tokens[index].spelling == spelling ||
                tokens[index].spelling == alternativeSpelling);
    }

    private static bool isAsmPunctuation(
        in imported!"quickbite.frontend.dmd.functions".InlineAsmToken[] tokens,
        in size_t index,
        in string spelling,
    ) @safe pure nothrow @nogc {
        return index < tokens.length && tokens[index].kind == spelling &&
            tokens[index].spelling == spelling;
    }

    private static bool isAsmInteger(
        in imported!"quickbite.frontend.dmd.functions".InlineAsmToken[] tokens,
        in size_t index,
        in string spelling,
    ) @safe pure nothrow @nogc {
        return index < tokens.length && tokens[index].kind == "int32v" &&
            tokens[index].spelling == spelling;
    }

    private Operand asmPointerLocal(in string name) {
        import std.conv: text;

        foreach (declaration, offset; _locals) {
            if (declaration.ident is null ||
                declaration.ident.toString != name)
                continue;
            if (auto element = declaration in _pointerLocals)
                return Operand(offset, ScalarType.ulong_, true, *element);
            throw new Exception(text("Unsupported inline asm pointer operand: ", name));
        }
        throw new Exception(text("Unsupported inline asm pointer operand: ", name));
    }

    private Operand asmLocal(in string name) {
        import dmd.astenums: TY;
        import std.conv: text;

        foreach (declaration, offset; _locals) {
            if (declaration.ident !is null &&
                declaration.ident.toString == name) {
                const type = declaration.type.toBasetype.ty;
                if (type == TY.Tbool)
                    return Operand(offset, ScalarType.bool_);
                if (type == TY.Tuns32)
                    return Operand(offset, ScalarType.uint_);
                if (type == TY.Tuns64)
                    return Operand(offset, ScalarType.ulong_);
                throw new Exception(text(
                    "Unsupported inline asm operand type: ",
                    typeChars(declaration.type),
                ));
            }
        }
        throw new Exception(text("Unsupported inline asm operand: ", name));
    }

    private void compileIfStatement(imported!"dmd.statement".IfStatement if_) {
        const condition = compileBoolCondition(if_.condition);
        const falseJump = emitJumpIfFalse(condition);

        compileNestedStatement(if_.ifbody);
        const endJump = emitJump;

        patchJump(falseJump);
        if (if_.elsebody !is null)
            compileNestedStatement(if_.elsebody);

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
            compileNestedStatement(with_._body);
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
            compileNestedStatement(tryFinally._body);

        _tryFinallyStack.length -= 1;

        // The normal fall-through exit also runs the finally.
        if (tryFinally.finalbody !is null)
            compileNestedStatement(tryFinally.finalbody);
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
            auto savedException = _pendingFinallyExceptionMessageOffset;
            auto savedExceptionClass = _pendingFinallyExceptionClassIndex;
            compileStatement(finalbody);
            _pendingFinallyExceptionMessageOffset = savedException;
            _pendingFinallyExceptionClassIndex = savedExceptionClass;
            _tryFinallyStack = saved;
        }
    }

    private void compileReturnStatement(
        imported!"dmd.statement".ReturnStatement return_,
    ) {
        ushort result;
        bool hasResult;

        if (_currentReturnType.isArray && _currentReturnType.isStaticArray) {
            // `return arr;` for a `string[N]`/`wstring[N]`/`dstring[N]` result:
            // the `ret` instruction below copies `staticArraySize` inline bytes
            // from `result`, not a 16-byte descriptor — `arrayDescriptorOffset`
            // (the dynamic-array path) would hand back the wrong shape.
            result = staticArrayReturnOffset(return_.exp);
            hasResult = true;
        } else if (_currentReturnType.isArray) {
            result = arrayDescriptorOffset(
                _currentReturnType.elementType,
                return_.exp,
                _currentReturnType.arrayElementsAreArrays,
            );
            hasResult = true;
        } else if (_currentReturnType.isStruct) {
            if (auto staticArray = staticArrayOffsetOf(return_.exp))
                result = *staticArray;
            else
                // `return structValue;`: the result block lives at the struct
                // operand's inline base; `ret` copies its `structSize` bytes
                // back to the caller's destination.
                result = structOperandOffset(return_.exp);
            hasResult = true;
        } else if (return_.exp !is null &&
            !_currentReturnType.isUndisplayable &&
            _currentReturnType.scalar != ScalarType.void_) {
            result = compileExpression(return_.exp).offset;
            hasResult = true;
        }

        if (hasResult && _tryFinallyStack.length != 0) {
            const saved = allocateBytes(size(_currentReturnType), 8);
            _code ~= Instruction(
                Op.copy, saved, result, cast(ushort) size(_currentReturnType),
            );
            result = saved;
        }

        // A `return` leaves every active `try` body in the function. Run the
        // finalizers after the result expression has been captured.
        runExitedFinally(_tryFinallyStack.length);

        _code ~= hasResult ? Instruction(Op.ret, result) : Instruction(Op.ret);
    }

    // The frame offset of a `string[N]`/`wstring[N]`/`dstring[N]`-typed return
    // expression's own `staticArraySize` inline block. Reuses an existing
    // static-array local's own offset directly (the common `return xs;` case);
    // otherwise compiles the expression into a fresh block, mirroring
    // `compileStaticArrayDeclaration`'s own initializer handling.
    private ushort staticArrayReturnOffset(Expression source) {
        import std.conv: text;

        if (auto existing = staticArrayOffsetOf(source))
            return *existing;

        const totalSize = cast(uint) staticArraySize(source.type);
        const offset =
            allocateBytes(totalSize, staticArrayAlign(source.type));

        if (auto literal = arrayLiteralOf(source)) {
            compileStaticArrayLiteral(offset, source.type, literal);
            return offset;
        }

        // A `CallExp` returning a `string[N]`/`int[N]`/... by value leaves its
        // result as an inline `totalSize`-byte block, so copying it is safe.
        // Any other unrecognized shape (ternary, indexing, ...) may hand back
        // a pointer/descriptor or a smaller slot instead; refuse rather than
        // copy the wrong bytes.
        if (source.isCallExp !is null) {
            const value = compileExpression(source);
            _code ~= Instruction(
                Op.copy, offset, value.offset, cast(ushort) totalSize,
            );
            return offset;
        }

        throw new Exception(text(
            "Unsupported static array return in bytecode core: ",
            expressionChars(source),
        ));
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

    // `try { body } catch (...) { handler } ...`: register the ordered catches
    // as one runtime handler group, compile the try body, then on normal
    // completion pop the group and skip the catch bodies. A throw inside the
    // body selects the first catch whose type matches the thrown dynamic class,
    // materialising the caught object's message fields when the catch is named.
    private void compileTryCatchStatement(
        imported!"dmd.statement".TryCatchStatement tryCatch,
    ) {
        import std.conv: text;

        if (tryCatch.catches is null || tryCatch.catches.length == 0)
            throw new Exception(text(
                "Unsupported try/catch in bytecode core: ",
                tryCatch.catches is null ? 0 : tryCatch.catches.length,
                " catch clauses",
            ));

        const catchStart = _program.catchClauses.length;
        foreach (catch_; *tryCatch.catches)
            _program.catchClauses ~= CatchClause(
                catchClass(catch_),
                noCatchObjectField,
                noCatchObjectField,
                noCatchObjectField,
                0,
            );

        _code ~= Instruction(
            Op.pushHandler,
            cast(ushort) catchStart,
            cast(ushort) tryCatch.catches.length,
        );

        if (tryCatch._body !is null)
            compileNestedStatement(tryCatch._body);

        // Normal completion of the try body: drop the handler group and skip the
        // catch bodies.
        _code ~= Instruction(Op.popHandler);
        const skipCatch = emitJump;

        size_t[] exitPatches;
        foreach (catchIndex; 0 .. tryCatch.catches.length) {
            auto catch_ = (*tryCatch.catches)[catchIndex];
            const clauseIndex = catchStart + catchIndex;
            _program.catchClauses[clauseIndex].handlerIp =
                cast(ushort) _code.length;
            if (catch_.var !is null) {
                auto catchObject = allocateExceptionObject(catch_.var);
                _program.catchClauses[clauseIndex].objectOffset =
                    catchObject.objectOffset;
                _program.catchClauses[clauseIndex].messageOffset =
                    catchObject.messageOffset;
                _program.catchClauses[clauseIndex].nextMessageOffset =
                    catchObject.nextMessageOffset;
            }

            compileNestedStatement(catch_.handler);
            if (catch_.var !is null)
                _exceptionObjectLocals.remove(catch_.var);

            exitPatches ~= emitJump;
        }

        patchJump(skipCatch);
        foreach (patch; exitPatches)
            patchJump(patch);
    }

    private ushort catchClass(Catch catch_) {
        import std.conv: text;

        auto type = catch_.type;
        if (type is null && catch_.var !is null)
            type = catch_.var.type;
        if (type is null)
            return noExceptionClass;

        auto class_ = type.toBasetype.isClassHandle;
        if (class_ is null)
            throw new Exception(text(
                "Unsupported catch type in bytecode core: ",
                typeChars(type),
            ));

        return registerClass(class_);
    }

    private ushort registerClass(ClassDeclaration class_) {
        import std.conv: text;

        if (class_ is null)
            return noExceptionClass;
        if (auto existing = class_ in _classIndices)
            return *existing;
        if (_program.classes.length >= ushort.max)
            throw new Exception("Too many classes in bytecode core");

        const index = cast(ushort) _program.classes.length;
        _classIndices[class_] = index;
        _program.classes ~= ClassInfo.init;
        const baseClass = registerClass(class_.baseClass);
        const msgOffset = classFieldOffset(class_, "msg");
        _program.classes[index] = ClassInfo(
            baseClass,
            msgOffset == noCatchObjectField
                ? cast(ushort) size_t.sizeof
                : msgOffset,
            nativeClassTypeInfo(class_),
        );
        if (classInfoName(class_) == "core.exception.RangeError")
            _program.rangeErrorClass = index;
        if (baseClass != noExceptionClass)
            _program.classes[index].virtualFunctions =
                _program.classes[baseClass].virtualFunctions.dup;
        registerVirtualFunctions(class_, _program.classes[index]);
        return index;
    }

    // A VM class object stores its VM class index in its leading word, whereas
    // D `typeid` exposes a real TypeInfo object. Keep one host TypeInfo_Class
    // mirror per VM class so TypeInfo's native virtual methods retain their
    // ordinary compiled-D semantics (notably equality by class name).
    private size_t nativeClassTypeInfo(ClassDeclaration class_) {
        import object: TypeInfo, TypeInfo_Class;

        auto result = new TypeInfo_Class;
        result.name = classInfoName(class_);
        _program.nativeTypeInfos ~= cast(TypeInfo) result;
        return cast(size_t) cast(void*) result;
    }

    private void registerVirtualFunctions(
        ClassDeclaration class_,
        ref ClassInfo info,
    ) {
        foreach (base; virtualBases(class_))
            registerVirtualFunction(class_, base, info);
    }

    private void registerVirtualFunction(
        ClassDeclaration class_,
        FuncDeclaration base,
        ref ClassInfo info,
    ) {
        if (base is null || !supportedVirtualSignature(base))
            return;

        auto target = overridingFunction(class_, base);
        if (target is null || !supportedVirtualSignature(target))
            return;

        const baseIndex = registerFunction(base);
        const targetIndex = registerFunction(target);
        foreach (ref existing; info.virtualFunctions)
            if (existing.baseFunction == baseIndex) {
                existing.function_ = targetIndex;
                return;
            }

        info.virtualFunctions ~= VirtualFunction(baseIndex, targetIndex);
    }

    private ushort classFieldOffset(ClassDeclaration class_, in string name) {
        if (auto field = classFieldNamed(class_, name))
            return cast(ushort) field.offset;

        return noCatchObjectField;
    }

    private VarDeclaration classFieldNamed(
        ClassDeclaration class_,
        in string name,
    ) {
        for (auto current = class_; current !is null; current = current.baseClass)
            foreach (field; current.fields)
                if (isDeclarationNamed(field, name))
                    return field;

        return null;
    }

    private ExceptionObjectLocal allocateExceptionObject(
        VarDeclaration variable,
    ) {
        const objectOffset =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const messageOffset =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        const nextMessageOffset =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);

        auto classType = variable.type.toBasetype.isTypeClass;
        if (classType !is null && classType.sym !is null) {
            _locals[variable] = objectOffset;
            _classPointerLocals[variable] = classType.sym;
        }

        auto object = ExceptionObjectLocal(
            objectOffset, messageOffset, nextMessageOffset,
        );
        _exceptionObjectLocals[variable] = object;
        return object;
    }

    private ExceptionStringField* tryExceptionStringField(DotVarExp dot) {
        auto field = dot.var.isVarDeclaration;
        if (!isDeclarationNamed(field, "msg"))
            return null;

        auto object = exceptionObjectOrNull(dot.e1);
        if (object is null || object.messageOffset == noCatchObjectField)
            return null;

        auto result = new ExceptionStringField;
        *result = ExceptionStringField(object.messageOffset);
        return result;
    }

    private ExceptionObjectLocal* exceptionObjectOrNull(Expression expression) {
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                return declaration in _exceptionObjectLocals;

        if (auto call = expression.isCallExp)
            if (call.arguments is null || call.arguments.length == 0)
                if (auto callee = call.e1.isDotVarExp)
                    return nextExceptionObjectOrNull(callee);

        if (auto dot = expression.isDotVarExp) {
            if (auto object = nextExceptionObjectOrNull(dot))
                return object;
            return null;
        }

        return null;
    }

    private ExceptionObjectLocal* nextExceptionObjectOrNull(DotVarExp dot) {
        if (dot.var is null ||
            dot.var.ident is null ||
            dot.var.ident.toString != "next")
            return null;

        auto object = exceptionObjectOrNull(dot.e1);
        if (object is null ||
            object.nextMessageOffset == noCatchObjectField)
            return null;

        auto result = new ExceptionObjectLocal;
        *result = ExceptionObjectLocal(
            noCatchObjectField,
            object.nextMessageOffset,
            noCatchObjectField,
        );
        return result;
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
            : emitJumpIfFalse(compileBoolCondition(for_.condition));

        // Enter the loop: any `label:` immediately wrapping it (consumed here)
        // names this context for labeled `break`/`continue`.
        LoopContext context;
        context.label = _pendingLoopLabel;
        _pendingLoopLabel = null;
        _loopStack ~= context;

        if (for_._body !is null)
            compileNestedStatement(for_._body);

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
            compileNestedStatement(do_._body);

        // `continue` lands on the condition test, then re-runs the body if true.
        foreach (index; _loopStack[$ - 1].continuePatches)
            patchJumpTo(index, _code.length);

        const condition = compileBoolCondition(do_.condition);
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

                compileNestedStatement((*unrolled.statements)[index]);
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
            compileNestedStatement(switch_._body);

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
        auto selectorExpression = (*call.arguments)[0];
        const elementType = dynamicArrayElementType(selectorExpression.type);
        const compareOp = sliceEqualOp(
            dynamicArrayElementSize(selectorExpression.type, elementType),
        );

        const result = allocate(ScalarType.int_);
        _code ~= Instruction(
            Op.loadConstant, result, constantIndex(cast(ulong) -1), 4,
        );

        // The runtime switch value: an ordinary real descriptor, identical to
        // every other string source, compares against each case string's own
        // real descriptor via the generic `sliceEqualOp`.
        const selector = dynamicArrayDescriptor(selectorExpression);

        size_t[] matchedJumps;
        int index = 0;
        foreach (argument; *instance.tiargs) {
            auto caseString =
                isExpression(argument) is null ? null
                : isExpression(argument).isStringExp;
            if (caseString is null) // the leading element-type argument.
                continue;

            const matches = allocate(ScalarType.bool_);
            const literalOffset = compileStringLiteralPointer(caseString);
            _code ~= Instruction(
                compareOp, matches, selector.offset, literalOffset,
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
        compileThrowExpression(thrownExpression(throw_.exp));
    }

    private Operand compileThrowExpression(ThrowExp throw_) {
        return compileThrowExpression(thrownExpression(throw_), null);
    }

    private Operand compileThrowExpression(Expression expression) {
        return compileThrowExpression(expression, null);
    }

    private Operand compileThrowExpression(
        Expression expression,
        Type resultType,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        auto originalExpression = expression;
        expression = thrownExpression(expression);
        if (expression is null)
            throw new Exception(text(
                "Unsupported throw expression in bytecode core: ",
                "<null>",
            ));

        auto thrownNew = expression.isNewExp;
        if (thrownNew is null)
            thrownNew = nestedNewExpression(originalExpression);
        if (auto new_ = thrownNew) {
            if (auto class_ = thrownClass(new_)) {
                auto messageExpression = thrownMessageExpression(new_);
                if (messageExpression is null)
                    messageExpression =
                        thrownCallMessageExpression(originalExpression);
                if (messageExpression !is null &&
                    messageExpression.type !is null &&
                    isStringType(messageExpression.type))
                {
                    const messageOffset = arrayDescriptorOffset(
                        ScalarType.char_, messageExpression,
                    );
                    emitThrowString(messageOffset, registerClass(class_));
                    const type = throwResultType(resultType);
                    return Operand(allocate(type), type);
                }
            }
        }

        const object = compileExpression(expression);
        if (!object.isPointer)
            throw new Exception(text(
                "Unsupported throw expression in bytecode core: ",
                expressionChars(expression),
            ));

        _code ~= Instruction(Op.throwObject, object.offset);
        const type = throwResultType(resultType);
        return Operand(allocate(type), type);
    }

    private void emitThrowString(in ushort messageOffset, in ushort classIndex) {
        if (_pendingFinallyExceptionMessageOffset != noCatchObjectField) {
            _code ~= Instruction(
                Op.throwString,
                _pendingFinallyExceptionMessageOffset,
                _pendingFinallyExceptionClassIndex,
                messageOffset,
            );
            return;
        }

        const nextMessageOffset = _pendingFinallyExceptionMessageOffset;
        if (_tryFinallyStack.length != 0) {
            auto savedException = _pendingFinallyExceptionMessageOffset;
            auto savedExceptionClass = _pendingFinallyExceptionClassIndex;
            _pendingFinallyExceptionMessageOffset = messageOffset;
            _pendingFinallyExceptionClassIndex = classIndex;
            runExitedFinally(_tryFinallyStack.length);
            _pendingFinallyExceptionMessageOffset = savedException;
            _pendingFinallyExceptionClassIndex = savedExceptionClass;
        }

        _code ~= Instruction(
            Op.throwString,
            messageOffset,
            classIndex,
            nextMessageOffset,
        );
    }

    private ScalarType throwResultType(Type resultType) {
        import dmd.astenums: TY;

        if (resultType is null)
            return ScalarType.void_;
        const ty = resultType.toBasetype.ty;
        return ty == TY.Tvoid || ty == TY.Tnoreturn
            ? ScalarType.void_
            : scalarType(resultType);
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
            if (isImaginaryDoubleType(real_.type))
                return compileImaginaryDoubleLiteral(real_);

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
            return Operand(
                compileStringLiteralPointer(string_), ScalarType.void_,
            );

        if (auto array = expression.isArrayLiteralExp)
            return compileArrayLiteralExpression(array);

        if (auto tuple = expression.isTupleExp) {
            if (tuple.e0 !is null)
                compileExpression(tuple.e0);

            auto result = Operand.init;
            if (tuple.exps !is null)
                foreach (element; *tuple.exps)
                    result = compileExpression(element);
            return result;
        }

        if (auto typeid_ = expression.isTypeidExp)
            return compileTypeidExpression(typeid_);

        if (expression.isThisExp !is null || expression.isSuperExp !is null) {
            if (_hasThis) {
                const offset = allocateStructBlock(expression.type);
                _code ~= Instruction(
                    Op.copy,
                    offset,
                    _thisLocal.offset,
                    cast(ushort) staticArraySize(expression.type),
                );
                return Operand(offset, ScalarType.void_);
            }

            if (_hasNestedContext)
                if (auto this_ = expression.isThisExp)
                    if (auto captured = this_.var in _capturedOffsets)
                        return loadCapturedLocal(this_.var, *captured);

            if (_hasClassThis)
                return Operand(
                    _classThisOffset,
                    ScalarType.ulong_,
                    true,
                    ScalarType.void_,
                );
        }

        if (auto negate = expression.isNegExp)
            return compileNegateExpression(negate);

        if (auto not = expression.isNotExp)
            return compileNotExpression(not);

        if (auto complement = expression.isComExp)
            return compileComplementExpression(complement);

        if (auto subtract = expression.isMinExp)
            return compileSubtractExpression(subtract);

        if (auto variable = expression.isVarExp) {
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto base = declaration in _withDerefBases) {
                    const pointer =
                        allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
                    _code ~= Instruction(Op.frameAddress, pointer, *base);
                    return Operand(
                        pointer,
                        ScalarType.ulong_,
                        true,
                        ScalarType.void_,
                    );
                }

            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _locals) {
                    if (declaration in _structPointerLocals)
                        return Operand(
                            *existing,
                            ScalarType.ulong_,
                            true,
                            ScalarType.void_,
                        );
                    if (auto element = declaration in _refLocalPointers)
                        return loadThroughPointer(
                            Operand(
                                *existing,
                                ScalarType.ulong_,
                                true,
                                *element,
                            ),
                            compileSizeConstant(0),
                        );
                    if (declaration in _complexDoubleLocals)
                        return Operand(
                            *existing,
                            ScalarType.void_,
                            false,
                            ScalarType.void_,
                            true,
                        );
                    if (declaration in _classPointerLocals)
                        return Operand(
                            *existing,
                            ScalarType.ulong_,
                            true,
                            ScalarType.void_,
                        );
                    if (auto element = declaration in _pointerLocals)
                        return Operand(
                            *existing, ScalarType.ulong_, true, *element,
                        );
                    return Operand(*existing, scalarType(declaration.type));
                }
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _staticArrayLocals)
                    return Operand(*existing, ScalarType.void_);
            if (auto descriptor = dynamicArrayDescriptorOrNull(expression))
                return Operand(descriptor.offset, ScalarType.void_);
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _withDerefBases) {
                    const offset =
                        allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
                    _code ~= Instruction(Op.frameAddress, offset, *existing);
                    return Operand(
                        offset, ScalarType.ulong_, true,
                        ScalarType.void_,
                    );
                }

            if (auto declaration = variable.var.isVarDeclaration)
                if (auto moduleVariable =
                        moduleScalarVariableOrNull(declaration)) {
                    const offset = allocate(moduleVariable.type);
                    _code ~= Instruction(
                        Op.loadModule,
                        offset,
                        moduleVariable.offset,
                        cast(ushort) size(moduleVariable.type),
                    );
                    if (moduleVariable.isClassReference)
                        return Operand(
                            offset,
                            ScalarType.ulong_,
                            true,
                            ScalarType.void_,
                        );
                    return Operand(offset, moduleVariable.type);
                }

            // A captured enclosing local read inside a nested struct's method
            // (`return seed;`): resolve it through the hidden `this` block's
            // context pointer (vthis at offset 0), which holds the enclosing
            // frame's base index.
            if (_hasNestedContext)
                if (auto declaration = variable.var.isVarDeclaration)
                    if (auto captured = declaration in _capturedOffsets)
                        return loadCapturedLocal(declaration, *captured);

            if (expressionChars(expression) == "$" &&
                _activeDollarLength != ushort.max)
                return Operand(_activeDollarLength, ScalarType.ulong_);

            if (expressionChars(expression) == "__ctfe") {
                const offset = allocate(ScalarType.bool_);
                _code ~= Instruction(
                    Op.loadConstant,
                    offset,
                    constantIndex(0),
                    cast(ushort) size(ScalarType.bool_),
                );
                return Operand(offset, ScalarType.bool_);
            }

            if (auto declaration = variable.var.isVarDeclaration)
                if (isDeclarationNamed(declaration, "$") ||
                    declaration.isImmutable)
                    if (auto initializer =
                            declaration._init is null
                                ? null
                                : declaration._init.isExpInitializer)
                        return compileExpression(
                            initializerExpression(initializer.exp),
                        );

            throw new Exception(text(
                "Unsupported variable in bytecode core: ",
                expressionChars(expression),
            ));
        }

        if (auto declaration = expression.isDeclarationExp) {
            import std.algorithm: startsWith;

            if (auto variable = declaration.declaration.isVarDeclaration) {
                compileVariableDeclaration(variable);
                return Operand.init;
            }

            // A nested type declaration (`struct Inner { ... }` inside a
            // function body) is a compile-time construct that emits no runtime
            // code; semantic has already resolved it.
            if (declaration.declaration.isAggregateDeclaration !is null)
                return Operand.init;
            if (declaration.declaration.isStorageClassDeclaration !is null &&
                expressionChars(expression).startsWith("static struct "))
                return Operand.init;
            if (declaration.declaration.isAliasDeclaration !is null)
                return Operand.init;
            if (declaration.declaration.isTemplateDeclaration !is null)
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

        if (auto tuple = expression.isTupleExp)
            return compileTupleExpression(tuple);

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
                offset, ScalarType.ulong_, true, ScalarType.int_,
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

        if (auto modulo = expression.isModExp)
            return compileModuloExpression(modulo);

        if (auto leftShift = expression.isShlExp)
            return compileShiftExpression(
                leftShift,
                Op.shlInt4,
                "Unsupported left shift in bytecode core: ",
            );

        if (auto rightShift = expression.isShrExp)
            return compileShiftExpression(
                rightShift,
                Op.shrInt4,
                "Unsupported right shift in bytecode core: ",
            );

        if (auto unsignedRightShift = expression.isUshrExp)
            return compileShiftExpression(
                unsignedRightShift,
                Op.ushrInt4,
                "Unsupported unsigned right shift in bytecode core: ",
            );

        if (auto and = expression.isAndExp)
            return compileAndExpression(and);

        if (auto xor = expression.isXorExp)
            return compileXorExpression(xor);

        if (auto comparison = comparisonExpression(expression))
            return compileComparisonExpression(comparison);

        if (auto logical = expression.isLogicalExp)
            return compileLogicalExpression(logical);

        if (auto addAssign = expression.isAddAssignExp)
            return compileAddAssignExpression(addAssign);

        if (auto subtractAssign = expression.isMinAssignExp)
            return compileLocalIntegerCompoundAssign(
                subtractAssign,
                Op.subInt4,
                Op.subInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto multiplyAssign = expression.isMulAssignExp)
            return compileLocalIntegerCompoundAssign(
                multiplyAssign,
                Op.mulInt4,
                Op.mulInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto rightShiftAssign = expression.isShrAssignExp) {
            if (auto deref = rightShiftAssign.e1.isPtrExp)
                if (auto store = tryPointerDereferenceIntegerCompoundAssign(
                        deref,
                        rightShiftAssign.e2,
                        Op.shrInt4,
                        Op.shrInt4,
                    ))
                    return *store;
            return compileLocalIntegerCompoundAssign(
                rightShiftAssign,
                Op.shrInt4,
                Op.shrInt4,
                "Unsupported compound assignment in bytecode core: ",
            );
        }

        if (auto leftShiftAssign = expression.isShlAssignExp)
            return compileLocalIntegerCompoundAssign(
                leftShiftAssign,
                Op.shlInt4,
                Op.shlInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto orAssign = expression.isOrAssignExp)
            return compileLocalIntegerCompoundAssign(
                orAssign,
                Op.bitOrInt4,
                Op.bitOrInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto andAssign = expression.isAndAssignExp)
            return compileLocalIntegerCompoundAssign(
                andAssign,
                Op.bitAndInt4,
                Op.bitAndInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto xorAssign = expression.isXorAssignExp)
            return compileLocalIntegerCompoundAssign(
                xorAssign,
                Op.bitXorInt4,
                Op.bitXorInt4,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto divideAssign = expression.isDivAssignExp)
            return compileDivOrModCompoundAssign(
                divideAssign,
                false,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto moduloAssign = expression.isModAssignExp)
            return compileDivOrModCompoundAssign(
                moduloAssign,
                true,
                "Unsupported compound assignment in bytecode core: ",
            );

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
        // A static array's default-init fill on function entry (an `out
        // char[4] buf` parameter zeroed to `char.init`) arrives the same way
        // over a `SliceExp` lvalue (`buf[] = '\xff'`).
        if (auto construct = expression.isConstructExp)
            if (construct.e1.isDotVarExp !is null ||
                construct.e1.isVarExp !is null ||
                construct.e1.isSliceExp !is null)
                return compileAssignExpression(construct);
        if (auto blit = expression.isBlitExp)
            if (blit.e1.isDotVarExp !is null ||
                blit.e1.isVarExp !is null ||
                blit.e1.isSliceExp !is null)
                return compileAssignExpression(blit);

        // `arr ~= x` (append element) arrives as a CatElemAssignExp (op
        // `concatenateElemAssign`); whole-array `arr ~= other` arrives as the
        // distinct CatAssignExp (`concatenateAssign`).
        if (auto append = expression.isCatElemAssignExp)
            return compileAppendElement(append);

        if (auto concatenate = expression.isCatAssignExp)
            return compileConcatenationAssign(concatenate);

        if (auto equal = expression.isEqualExp)
            return compileEqualExpression(equal);

        if (auto identity = expression.isIdentityExp)
            return compileIdentityExpression(identity);

        // `c ? t : f`: DMD's `m[k]` lowering produces `slot ? slot : (bounds,
        // null)`, a pointer-valued conditional whose false branch raises "Range
        // violation". Compile it as a branch writing one slot on both paths.
        if (auto conditional = expression.isCondExp)
            return compileConditionalExpression(conditional);

        if (auto throw_ = expression.isThrowExp)
            return compileThrowExpression(throw_);

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

        if (auto vectorArray = expression.isVectorArrayExp)
            if (auto offset = staticArrayOffsetOf(vectorArray.e1))
                return Operand(*offset, ScalarType.void_);

        if (auto address = expression.isAddrExp) {
            if (auto pointer = tryAddressOfElement(address))
                return *pointer;
            if (auto pointer = tryAddressOfLocal(address))
                return *pointer;
            if (auto symbol = address.e1.isSymOffExp)
                if (auto pointer = tryAddressOfSymbol(symbol))
                    return *pointer;
            if (auto pointer = tryAddressOfRefParameterCall(address))
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
            if (auto element = tryClassStaticArrayFieldElement(index))
                return *element;
            if (auto element = tryStaticArrayRuntimeIndex(index))
                return *element;
            return compileStaticArrayIndex(index);
        }

        if (auto slice = expression.isSliceExp) {
            // A `string` sub-slice is an ordinary sub-slice of a real
            // descriptor, identical to any other `T[]`.
            const elementType = dynamicArrayElementType(slice.type);
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileSliceInto(offset, elementType, slice);
            return Operand(offset, ScalarType.void_);
        }

        // `base.field`: read a struct field from its inline frame offset. A
        // pointer field (`tracker.postblits`) yields a pointer operand over its
        // raw 8-byte address; a scalar field its scalar value.
        if (auto dot = expression.isDotVarExp)
            if (auto name = tryTypeidName(dot))
                return *name;

        if (auto dot = expression.isDotVarExp)
            if (auto field = tryExceptionStringField(dot))
                return Operand(field.offset, ScalarType.void_);

        if (auto dot = expression.isDotVarExp)
            if (auto property = tryDelegateProperty(dot))
                return *property;

        if (auto dot = expression.isDotIdExp)
            if (auto property = tryComplexDoubleProperty(dot))
                return *property;

        if (auto dot = expression.isDotVarExp)
            if (auto property = tryComplexDoubleProperty(dot))
                return *property;

        if (auto dot = expression.isDotIdExp)
            if (auto property = tryDelegateProperty(dot))
                return *property;

        if (auto pointer = expression.isDelegatePtrExp)
            if (auto property = tryDelegateProperty(pointer.e1, "ptr"))
                return *property;

        if (auto functionPointer = expression.isDelegateFuncptrExp)
            if (auto property =
                    tryDelegateProperty(functionPointer.e1, "funcptr"))
                return *property;

        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot)) {
                import dmd.astenums: TY;

                // A dynamic-array field (`string` included) holds a 16-byte
                // slice descriptor in its inline slot, not a plain scalar.
                if (field.type.toBasetype.ty == TY.Tarray)
                    return Operand(field.offset, ScalarType.void_);
                if (field.type.toBasetype.ty == TY.Tstruct)
                    return Operand(field.offset, ScalarType.void_);
                if (field.type.toBasetype.ty == TY.Taarray)
                    return Operand(field.offset, ScalarType.ulong_);
                if (field.type.toBasetype.ty == TY.Tclass)
                    return Operand(
                        field.offset, ScalarType.ulong_, true, ScalarType.void_,
                    );
                if (isPointerType(field.type))
                    return Operand(
                        field.offset, ScalarType.ulong_, true,
                        pointerElementScalar(field.type),
                    );
                return Operand(field.offset, scalarType(field.type));
            }

        // `p.field` through a heap struct pointer: load the field at `ptr +
        // field.offset`.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructPointerField(dot))
                return loadStructPointerField(*field);

        if (auto dot = expression.isDotVarExp)
            if (auto field = tryClassPointerField(dot))
                return loadClassPointerField(*field);

        if (auto literal = expression.isStructLiteralExp)
            return compileStructLiteralOperand(literal);

        if (auto literal = expression.isAssocArrayLiteralExp) {
            const offset =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            compileAssocArrayInto(offset, literal);
            return Operand(offset, ScalarType.ulong_);
        }

        if (auto literal = expression.isFuncExp)
            if (literal.fd !is null) {
                _latestStaticDelegateAssocArrayFunction = literal.fd;
                const offset = allocateBytes(delegateValueSize, size_t.sizeof);
                emitDelegateValue(
                    offset,
                    literal.fd,
                    delegateContextOffset(literal.fd, null),
                );
                return Operand(offset, ScalarType.ulong_);
            }

        // `new int(value)`: heap-allocate one scalar value and yield an `int*`.
        if (auto newExp = expression.isNewExp)
            if (auto pointer = tryNewScalar(newExp))
                return *pointer;

        // `new S(args)`: heap-allocate a struct block and yield a `S*` pointer.
        if (auto newExp = expression.isNewExp)
            if (auto pointer = tryNewStruct(newExp))
                return *pointer;

        if (auto newExp = expression.isNewExp)
            if (auto pointer = tryNewClass(newExp))
                return *pointer;

        throw new Exception(text(
            "Unsupported expression in bytecode core: ",
            expressionChars(expression),
        ));
    }

    // DMD lowers tuple construction and `tupleof` assignment to a side-effect
    // prefix followed by ordinary per-element expressions. Evaluate them in
    // source order and preserve the final element's expression value.
    private Operand compileTupleExpression(TupleExp tuple) {
        if (tuple.e0 !is null)
            compileExpression(tuple.e0);

        auto result = Operand.init; // mutated while folding tuple elements
        if (tuple.exps !is null)
            foreach (element; *tuple.exps)
                result = compileExpression(element);
        return result;
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

    // `i++` on an integer local, struct field, or dereferenced pointer: copy
    // the old value to the result slot, then add `e2` (the increment) to the
    // lvalue's slot. Scoped to integer lvalues, matching compound assignment.
    private Operand compilePostIncrement(PostExp post) {
        import dmd.tokens: EXP;
        import std.conv: text;

        // `x++` where `x` is an outer local captured into this function (a
        // `lazy` argument's thunk, or any nested closure): its slot lives in
        // the enclosing frame, not this function's `_locals`.
        if (auto variable = post.e1.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (declaration !in _locals && _hasNestedContext)
                    if (auto captured = declaration in _capturedOffsets)
                        return compileCapturedPostIncrement(
                            declaration, *captured, post,
                        );

        if (auto deref = post.e1.isPtrExp) {
            const pointer = compileExpression(deref.e1);
            if (pointer.isPointer && isIntegerScalar(pointer.pointerElement)) {
                const zero = compileSizeConstant(0);
                const lvalue = loadThroughPointer(pointer, zero);
                const result = allocate(lvalue.type);
                _code ~= Instruction(
                    Op.copy, result, lvalue.offset, cast(ushort) size(lvalue.type),
                );

                const increment = compileExpression(post.e2);
                const stepOp = post.op == EXP.minusMinus
                    ? (isEightByteInteger(lvalue.type) ? Op.subInt8 : Op.subInt4)
                    : (isEightByteInteger(lvalue.type) ? Op.addInt8 : Op.addInt4);
                _code ~= Instruction(
                    stepOp, lvalue.offset, lvalue.offset, increment.offset,
                );
                _code ~= Instruction(
                    pointerStoreOp(size(pointer.pointerElement)),
                    lvalue.offset,
                    pointer.offset,
                    zero,
                );
                return Operand(result, lvalue.type);
            }
        }

        ushort lvalueSlot;
        auto lvalueType = ScalarType.void_;
        StructField* lvalueField;

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
                lvalueField = field;
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
        if (lvalueField !is null)
            writeBackStructField(*lvalueField);
        return Operand(result, lvalueType);
    }

    // `x++` for an outer local `x` captured by this function: read/step/write
    // through the captured-local frame ops instead of an in-place local-slot
    // update, since `x`'s slot is the enclosing frame's, not this one's.
    private Operand compileCapturedPostIncrement(
        VarDeclaration declaration,
        in ushort capturedOffset,
        PostExp post,
    ) {
        import dmd.tokens: EXP;
        import std.conv: text;

        const lvalueType = scalarType(declaration.type);
        if (!isIntegerScalar(lvalueType))
            throw new Exception(text(
                "Unsupported post-increment in bytecode core: ",
                expressionChars(post),
            ));

        const loaded = loadCapturedLocal(declaration, capturedOffset);
        const result = allocate(lvalueType);
        _code ~= Instruction(
            Op.copy, result, loaded.offset, cast(ushort) size(lvalueType),
        );

        const increment = compileExpression(post.e2);
        const eightByte = lvalueType == ScalarType.long_ ||
            lvalueType == ScalarType.ulong_;
        const stepOp = post.op == EXP.minusMinus
            ? (eightByte ? Op.subInt8 : Op.subInt4)
            : (eightByte ? Op.addInt8 : Op.addInt4);
        _code ~= Instruction(
            stepOp, loaded.offset, loaded.offset, increment.offset,
        );
        storeCapturedLocal(declaration, capturedOffset, loaded);
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
        // `outer[i][j]` / `local[i]` / `s[i]`: the indexed expression is (or
        // materialises to) a known dynamic-array descriptor — a `string`
        // included, its real descriptor identical in shape to any other
        // `T[]`. This also handles `outer[i]` of an array-of-arrays, whose
        // inner descriptor is materialised here.
        if (auto descriptor = dynamicArrayDescriptorOrNull(index.e1))
            return loadDynamicArrayElement(
                descriptor.offset, descriptor.elementType, index.e2, index.type,
                descriptor.elementIsArray,
            );

        // `makeArray(...)[i]`: the indexed expression is an array-valued call,
        // not a known local. Materialise its descriptor into a fresh slot and
        // index that.
        if (auto descriptorOffset = indexedArrayDescriptor(index.e1))
            return loadDynamicArrayElement(
                descriptorOffset.offset, descriptorOffset.elementType, index.e2,
                index.type, descriptorOffset.elementIsArray,
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
    // `descriptorOffset`, returning the loaded element. `elementIsArray` marks
    // an array-of-arrays descriptor whose element is itself a 16-byte slice
    // descriptor rather than the `elementType` scalar (which then names only
    // the innermost element for further indexing).
    private Operand* loadDynamicArrayElement(
        in ushort descriptorOffset,
        in ScalarType elementType,
        Expression indexExpr,
        Type resultType,
        in bool elementIsArray = false,
    ) {
        import dmd.astenums: TY;

        const savedDollarLength = _activeDollarLength;
        _activeDollarLength = sliceLengthSlot(DynamicArrayLocal(
            descriptorOffset,
            elementType,
        ));
        const indexSlot = compileExpression(indexExpr);
        _activeDollarLength = savedDollarLength;
        const elementSize = resultType.toBasetype.ty == TY.Tstruct
            ? cast(uint) staticArraySize(resultType)
            : elementIsArray
            ? sliceDescriptorSize
            : size(elementType);
        const alignment = resultType.toBasetype.ty == TY.Tstruct
            ? staticArrayAlign(resultType)
            : elementIsArray
            ? size_t.sizeof
            : elementSize;
        const offset = allocateBytes(elementSize, alignment);
        _code ~= Instruction(
            indexLoadOp(elementSize),
            offset,
            descriptorOffset,
            indexSlot.offset,
        );

        auto result = new Operand;
        *result = resultType.toBasetype.ty == TY.Tstruct || elementIsArray
            ? Operand(offset, ScalarType.void_)
            : isPointerType(resultType)
            ? Operand(
                offset, ScalarType.ulong_, true,
                pointerElementScalar(resultType),
            )
            : Operand(offset, elementType);
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

        if (auto cast_ = expression.isCastExp)
            if (isDynamicArrayArgument(cast_.e1) ||
                isStringType(cast_.e1.type))
                return dynamicArrayDescriptorOrNull(cast_.e1);

        // `typeid(T).name` / `object.classinfo.name`: computed at compile
        // time from the type's own declaration, not read out of a class
        // object's field storage. Checked before the general class-field
        // case below, matching `compileExpression`'s own dispatch order, so
        // a `string name = typeid(T).name;`-shaped source still resolves
        // here rather than falling into a raw field read off whatever
        // pointer `typeid(T)` happens to compile to.
        if (auto dot = expression.isDotVarExp)
            if (auto name = tryTypeidName(dot)) {
                auto result = new DynamicArrayLocal;
                *result = DynamicArrayLocal(name.offset, ScalarType.char_);
                return result;
            }

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto descriptor = declaration in _dynamicArrayLocals)
                    return descriptor;

        // A module-level dynamic array (`byte[] a;`): materialise its
        // 16-byte descriptor from `_program.moduleData` into a fresh frame
        // slot, mirroring `moduleScalarVariableOrNull`'s read but sized for
        // a whole slice descriptor; reassignment writes the slot back
        // through `writeBackThroughModule` (`writeBackDynamicArrayDescriptor`).
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto moduleVariable =
                        moduleDynamicArrayVariableOrNull(declaration)) {
                    const offset =
                        allocateBytes(sliceDescriptorSize, size_t.sizeof);
                    _code ~= Instruction(
                        Op.loadModule,
                        offset,
                        moduleVariable.offset,
                        cast(ushort) sliceDescriptorSize,
                    );
                    auto result = new DynamicArrayLocal;
                    *result = DynamicArrayLocal(
                        offset,
                        moduleVariable.elementType,
                        moduleVariable.elementIsArray,
                    );
                    result.writeBackThroughModule = true;
                    result.moduleOffset = moduleVariable.offset;
                    return result;
                }

        // A string literal: the native {ptr, length} descriptor `Op
        // .loadStringLiteral` writes is already the ordinary shape every
        // other dynamic-array source resolves to.
        if (auto literal = expression.isStringExp)
            if (isStringType(literal.type)) {
                auto result = new DynamicArrayLocal;
                *result = DynamicArrayLocal(
                    compileStringLiteralPointer(literal),
                    dynamicArrayElementType(literal.type),
                );
                return result;
            }

        // `e.msg` / `e.next.msg`: a caught exception's message field is
        // already a real {ptr, length} descriptor at its own frame offset.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryExceptionStringField(dot)) {
                auto result = new DynamicArrayLocal;
                *result = DynamicArrayLocal(field.offset, ScalarType.char_);
                return result;
            }

        if (auto dereference = expression.isPtrExp)
            if (expression.type.toBasetype.ty == TY.Tarray) {
                const pointer = compileExpression(dereference.e1);
                if (!pointer.isPointer)
                    return null;

                const offset =
                    allocateBytes(sliceDescriptorSize, size_t.sizeof);
                _code ~= Instruction(
                    Op.pointerLoad16,
                    offset,
                    pointer.offset,
                    compileSizeConstant(0),
                );
                auto result = new DynamicArrayLocal;
                *result = DynamicArrayLocal(
                    offset,
                    dynamicArrayElementType(expression.type),
                    arrayElementIsArray(expression.type),
                    true,
                    pointer.offset,
                );
                return result;
            }

        if (_hasNestedContext)
            if (auto variable = expression.isVarExp)
                if (auto declaration = variable.var.isVarDeclaration)
                    if (auto captured = declaration in _capturedOffsets)
                        if (declaration.type.toBasetype.ty == TY.Tarray) {
                            const offset = allocateBytes(
                                sliceDescriptorSize, size_t.sizeof,
                            );
                            _code ~= Instruction(
                                Op.frameLoad,
                                offset,
                                capturedFrameIndex(*captured),
                                cast(ushort) sliceDescriptorSize,
                            );
                            auto result = new DynamicArrayLocal;
                            *result = DynamicArrayLocal(
                                offset,
                                dynamicArrayElementType(declaration.type),
                            );
                            result.writeBackThroughFrame = true;
                            result.frameIndexOffset =
                                capturedFrameIndex(*captured);
                            return result;
                        }

        if (auto staticArray = staticArrayOffsetOf(expression)) {
            const elementType = dynamicArrayElementType(expression.type);
            const elementIsArray = arrayElementIsArray(expression.type);
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileStaticArrayAsDynamicInto(offset, elementType, expression);
            auto result = new DynamicArrayLocal;
            *result = DynamicArrayLocal(offset, elementType, elementIsArray);
            result.isStaticArrayView = true;
            result.staticArrayOffset = *staticArray;
            return result;
        }

        // `c.arr` where `arr` is a static-array field of a class instance:
        // the class-field counterpart of the struct-field branch above,
        // redirected through a real runtime pointer since the field's
        // storage lives in the class's own heap block, not this frame.
        if (auto classField = classStaticArrayFieldOf(expression)) {
            const elementType = dynamicArrayElementType(expression.type);
            const elementIsArray = arrayElementIsArray(expression.type);
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            const basePointer = classFieldAddress(*classField);
            compileClassStaticArrayAsDynamicInto(
                offset, elementType, expression.type, basePointer,
            );
            auto result = new DynamicArrayLocal;
            *result = DynamicArrayLocal(offset, elementType, elementIsArray);
            result.isStaticArrayView = true;
            result.staticArrayViewIsClassField = true;
            result.staticArrayOffset = basePointer;
            return result;
        }

        // `base.field` where the field is a dynamic array: its slice descriptor
        // lives at `base + field.offset`, so indexing, `.length`, element-assign
        // and append reuse the existing dynamic-array machinery on that slot.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot))
                if (field.type.toBasetype.ty == TY.Tarray) {
                    auto result = new DynamicArrayLocal;
                    *result = DynamicArrayLocal(
                        field.offset, dynamicArrayElementType(field.type),
                    );
                    result.writeBackStructThroughFrame =
                        field.writeBackThroughFrame;
                    result.structOffset = field.structOffset;
                    result.structFrameIndexOffset = field.frameIndexOffset;
                    result.structSize = field.structSize;
                    return result;
                }

        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructPointerField(dot))
                if (field.type.toBasetype.ty == TY.Tarray) {
                    const pointer = structFieldAddress(*field);
                    const offset =
                        allocateBytes(sliceDescriptorSize, size_t.sizeof);
                    _code ~= Instruction(
                        Op.pointerLoad16,
                        offset,
                        pointer,
                        compileSizeConstant(0),
                    );
                    auto result = new DynamicArrayLocal;
                    *result = DynamicArrayLocal(
                        offset,
                        dynamicArrayElementType(field.type),
                        false,
                        true,
                        pointer,
                    );
                    return result;
                }

        // `box.field` where the field is a dynamic array (a `string`
        // included): its slice descriptor lives at `classPointer +
        // field.offset`, read through the same `Op.pointerLoad16` path as a
        // struct-pointer field.
        if (auto dot = expression.isDotVarExp)
            if (auto field = tryClassPointerField(dot))
                if (field.type.toBasetype.ty == TY.Tarray) {
                    const pointer = classFieldAddress(*field);
                    const offset =
                        allocateBytes(sliceDescriptorSize, size_t.sizeof);
                    _code ~= Instruction(
                        Op.pointerLoad16,
                        offset,
                        pointer,
                        compileSizeConstant(0),
                    );
                    auto result = new DynamicArrayLocal;
                    *result = DynamicArrayLocal(
                        offset,
                        dynamicArrayElementType(field.type),
                        false,
                        true,
                        pointer,
                    );
                    return result;
                }

        // `outer[i]` where `outer` is an array-of-arrays (`int[][]`): indexing
        // yields an inner array. Materialise the inner descriptor into a fresh
        // slot and treat it as a (scalar-element) dynamic array.
        if (auto index = expression.isIndexExp)
            return innerArrayDescriptor(index);

        if (auto slice = expression.isSliceExp) {
            const elementType = dynamicArrayElementType(expression.type);
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileSliceInto(offset, elementType, slice);
            auto result = new DynamicArrayLocal;
            *result = DynamicArrayLocal(offset, elementType);
            return result;
        }

        // An array-returning call (`m.keys` / `m.values`, or a `string`
        // function): materialise its 16-byte slice-descriptor result into a
        // fresh slot.
        if (expression.isCallExp !is null &&
            (isDynamicArrayArgument(expression) ||
                (expression.type !is null && isStringType(expression.type))))
        {
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

    // Compile a string literal directly into an expanded native {ptr, length}
    // descriptor at a fresh frame slot.
    private ushort compileStringLiteralPointer(StringExp string_) {
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        emitLoadStringLiteral(offset, string_);
        return offset;
    }

    // Whether `expression`, after stripping any qualifier casts, is
    // genuinely `string`-typed — a `string` value, not a mutable array
    // (e.g. `char[]`) merely viewed through a `const`/`immutable` cast for a
    // comparison. `wstring`/`dstring` are excluded, matching every other
    // byte-stride-1 consumer (see `isCharStringType`): the outer (possibly
    // cast) type alone cannot tell the two apart, since DMD's own
    // comparison/assert lowering casts a `char[]` operand to `const(char)[]`
    // just as it would a genuine `string`. Used only to pick a diagnostic's
    // rendering (quoted text vs `[e0, e1, ...]`), never a representation.
    private bool isGenuineCharString(Expression expression) {
        if (auto cast_ = expression.isCastExp)
            return isGenuineCharString(cast_.e1);

        // A `VarExp` node's own `.type` can be narrowed to a `const` view at
        // the reference site (DMD's `_d_assert_fail` argument passing does
        // this for a mutable `char[]`, with no wrapping `CastExp` to unwrap)
        // without touching the declaration's own type; consult that instead
        // of the expression's.
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                return isCharStringType(declaration.type);

        return isCharStringType(expression.type);
    }

    // Emit a string literal's bytes into a fresh literal block and an
    // `Op.loadStringLiteral` writing the expanded {ptr, length} descriptor
    // directly into the existing frame slot `destination` (as opposed to
    // `compileStringLiteralPointer`'s fresh one).
    private void emitLoadStringLiteral(
        in ushort destination,
        StringExp string_,
    ) {
        const literal = appendStringLiteral(string_);
        _code ~= Instruction(
            Op.loadStringLiteral,
            destination,
            literal.blockIndex,
            literal.length,
        );
    }

    // Allocate a fresh, stable `literalBlocks` entry holding `string_`'s code
    // units at their declared element width, returning its block index and
    // the code-unit count (not the byte count, which differs for
    // `wchar`/`dchar` literals) — the {index, length} pair every
    // literal-load instruction's operands share. A dedicated GC allocation
    // per literal, rather than an offset into one append-growable array,
    // keeps every earlier literal's pointer valid across the reallocation a
    // later literal's own append would otherwise trigger; it also already
    // lands on the element's own alignment, since a fresh GC block is
    // suitably aligned for any type.
    private StringLiteralData appendStringLiteral(StringExp string_) {
        import quickbite.frontend.dmd.string_literals: stringCodeUnitBytes;
        import std.conv: text;

        const bytes = stringCodeUnitBytes(string_);
        if (bytes.length > ushort.max)
            throw new Exception(text(
                "String literal too large for bytecode core: ",
                expressionChars(string_),
            ));
        _program.literalBlocks ~= bytes.dup;
        const blockIndex = _program.literalBlocks.length - 1;
        if (blockIndex > ushort.max)
            throw new Exception(text(
                "Too many string literals for bytecode core: ",
                expressionChars(string_),
            ));

        return StringLiteralData(
            cast(ushort) blockIndex, cast(ushort) (bytes.length / string_.sz),
        );
    }

    private Operand compileImaginaryDoubleLiteral(RealExp real_) {
        const offset = allocateComplexDouble;
        _code ~= Instruction(
            Op.loadConstant,
            offset,
            constantIndex(0),
            cast(ushort) double.sizeof,
        );
        _code ~= Instruction(
            Op.loadConstant,
            complexImaginaryOffset(offset),
            constantIndex(floatBits(real_, ScalarType.double_)),
            cast(ushort) double.sizeof,
        );
        return complexDoubleOperand(offset);
    }

    private Operand* tryComplexDoubleProperty(DotIdExp dot) {
        if (dot.ident is null)
            return null;

        return tryComplexDoubleProperty(dot.e1, dot.ident.toString);
    }

    private Operand* tryComplexDoubleProperty(DotVarExp dot) {
        if (dot.var is null || dot.var.ident is null)
            return null;

        return tryComplexDoubleProperty(dot.e1, dot.var.ident.toString);
    }

    private Operand* tryComplexDoubleProperty(
        Expression receiver,
        in const(char)[] property,
    ) {
        if (property != "re" && property != "im")
            return null;
        if (receiver.type is null || !isComplexDoubleType(receiver.type))
            return null;

        const value = compileExpression(receiver);
        if (!value.isComplex)
            return null;

        auto result = new Operand;
        *result = Operand(
            property == "im"
                ? complexImaginaryOffset(value.offset)
                : value.offset,
            ScalarType.double_,
        );
        return result;
    }

    // Write a compile-time string into a fresh, stable `literalBlocks` entry
    // and emit its native {ptr, length} descriptor, returning the
    // descriptor's frame offset. Used for synthesised diagnostic messages
    // (`throwString`), whose descriptor a later `throw` dereferences, so it
    // needs the same stable-address storage as a source-level string
    // literal, not the append-growable `data` segment.
    private ushort compileStringLiteralBytes(in string text_) {
        import std.conv: text;

        const bytes = cast(const(ubyte)[]) text_;
        if (bytes.length > ushort.max)
            throw new Exception(text(
                "String literal too large for bytecode core: ", text_,
            ));
        _program.literalBlocks ~= bytes.dup;
        const blockIndex = _program.literalBlocks.length - 1;
        if (blockIndex > ushort.max)
            throw new Exception(text(
                "Too many string literals for bytecode core: ", text_,
            ));

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.loadStringLiteral,
            offset,
            cast(ushort) blockIndex,
            cast(ushort) bytes.length,
        );
        return offset;
    }

    private Operand compileTypeidExpression(TypeidExp typeid_) {
        import dmd.dtemplate: isExpression;
        import dmd.mtype: Type;
        import std.conv: text;

        auto expression = isExpression(typeid_.obj);
        if (expression !is null) {
            const object = compileExpression(expression);
            if (!object.isPointer)
                throw new Exception(text(
                    "Unsupported typeid in bytecode core: ",
                    expressionChars(typeid_),
                ));

            emitNullClassReferenceCheck(
                object.offset,
                text(
                    "null pointer dereference evaluating typeid. `",
                    expressionChars(expression),
                    "` is `null`",
                ),
            );
            const offset = allocate(ScalarType.ulong_);
            _code ~= Instruction(Op.classTypeInfo, offset, object.offset);
            return Operand(offset, ScalarType.ulong_, true);
        }

        auto type = cast(Type) typeid_.obj;
        auto classType = type is null ? null : type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null) {
            const native = nativeTypeInfoAddress(type);
            if (native != 0) {
                const offset = allocate(ScalarType.ulong_);
                _code ~= Instruction(
                    Op.loadConstant,
                    offset,
                    constantIndex(native),
                    cast(ushort) size(ScalarType.ulong_),
                );
                return Operand(
                    offset,
                    ScalarType.ulong_,
                    true,
                    ScalarType.void_,
                );
            }
            throw new Exception(text(
                "Unsupported typeid in bytecode core: ",
                expressionChars(typeid_),
            ));
        }

        const classIndex = registerClass(classType.sym);
        const offset = allocate(ScalarType.ulong_);
        _code ~= Instruction(
            Op.loadConstant,
            offset,
            constantIndex(_program.classes[classIndex].nativeTypeInfo),
            cast(ushort) size(ScalarType.ulong_),
        );
        return Operand(offset, ScalarType.ulong_, true, ScalarType.void_);
    }

    private size_t nativeTypeInfoAddress(Type type) {
        import dmd.astenums: TY;

        if (type is null)
            return 0;
        if (type.toBasetype.ty == TY.Tint32)
            return cast(size_t) cast(void*) typeid(int);
        return 0;
    }

    private Operand* tryTypeidName(DotVarExp dot) {
        if (!isDeclarationNamed(dot.var.isVarDeclaration, "name"))
            return null;

        if (auto typeid_ = dot.e1.isTypeidExp)
            return heapOperand(Operand(
                compileStringLiteralBytes(typeInfoName(typeidObjectType(typeid_))),
                ScalarType.void_,
            ));

        if (auto symbol = dot.e1.isSymOffExp)
            if (auto type = symbolOffsetTypeInfoType(symbol))
                return heapOperand(Operand(
                    compileStringLiteralBytes(typeInfoName(type)),
                    ScalarType.void_,
                ));

        if (auto classinfo = dot.e1.isDotVarExp)
            if (classinfo.var !is null &&
                classinfo.var.ident !is null &&
                classinfo.var.ident.toString == "classinfo")
                return heapOperand(Operand(
                    compileStringLiteralBytes(""),
                    ScalarType.void_,
                ));

        return null;
    }

    private void compileVariableDeclaration(VarDeclaration variable) {
        import dmd.astenums: STC, TY;
        import std.conv: text;

        if ((variable.storage_class & STC.ref_) != STC.none &&
            compileRefLocalDeclaration(variable))
        {
            return;
        }

        // A static array `T[N]` is a value type stored inline in the frame at
        // its DMD-computed size and alignment; no heap, no slice descriptor.
        if (variable.type.toBasetype.ty == TY.Tsarray) {
            compileStaticArrayDeclaration(variable);
            return;
        }

        if (variable.type.toBasetype.ty == TY.Tvector) {
            compileVectorDeclaration(variable);
            return;
        }

        // A struct `S` is a value type stored inline in the frame at its
        // DMD-computed size and alignment; each field lives at `base +
        // field.offset`.
        if (variable.type.toBasetype.ty == TY.Tstruct) {
            compileStructDeclaration(variable);
            return;
        }

        // A dynamic array `T[]` (including `string`) holds a 16-byte slice
        // descriptor {ptr, length}; its backing memory lives on the VM-owned
        // heap, or — for a literal-initialised `string` — the immutable
        // program data segment.
        if (variable.type.toBasetype.ty == TY.Tarray) {
            compileDynamicArrayDeclaration(variable);
            return;
        }

        // An associative array `T[K]` holds an 8-byte handle into the machine's
        // VM-owned map table; `int[int]` is the only form the core lowers.
        if (variable.type.toBasetype.ty == TY.Taarray) {
            compileAssocArrayDeclaration(variable);
            return;
        }

        if (variable.type.toBasetype.ty == TY.Tclass) {
            compileClassPointerDeclaration(variable);
            return;
        }

        if (isComplexDoubleType(variable.type)) {
            compileComplexDoubleDeclaration(variable);
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

        const type = scalarType(variable.type);
        const offset = allocateBytes(size(type), size(type));
        _locals[variable] = offset;
        _capturedOffsets[variable] = offset;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            _code ~= Instruction(
                Op.loadConstant,
                offset,
                constantIndex(0),
                cast(ushort) size(type),
            );
            return;
        }

        const operand =
            compileExpression(initializerExpression(initializer.exp));
        _code ~= Instruction(
            Op.copy,
            offset,
            operand.offset,
            cast(ushort) size(type),
        );
    }

    private bool compileRefLocalDeclaration(VarDeclaration variable) {
        import dmd.astenums: TY;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            return false;

        auto expression = initializerExpression(initializer.exp);
        if (variable.type.toBasetype.ty == TY.Tarray)
            if (auto descriptor = dynamicArrayDescriptorOrNull(expression)) {
                _dynamicArrayLocals[variable] = *descriptor;
                return true;
            }

        // A ref local bound directly to another static-array local (`ref
        // int[2] alias_ = source;`): unlike a plain `int[2] copy = source;`
        // declaration (`compileStaticArrayDeclaration`'s block copy into a
        // fresh frame slot), a ref binding must denote `source`'s own
        // storage. Alias `variable` to the exact same frame offset in
        // `_staticArrayLocals`, so every existing static-array local
        // mechanism (address-of, indexing, whole-array assignment) reads
        // and writes through `source`'s real storage rather than a copy.
        if (variable.type.toBasetype.ty == TY.Tsarray)
            if (auto offset = staticArrayOffsetOf(expression)) {
                _staticArrayLocals[variable] = *offset;
                return true;
            }

        // A ref local bound directly to another struct local (`ref S alias_
        // = source;`): unlike `S copy = source;` (compileStructDeclaration's
        // block copy into a fresh frame slot), a ref binding must denote
        // `source`'s own storage. Alias `variable` to the exact same frame
        // offset (and struct declaration) in `_structLocals`, the struct
        // counterpart of the static-array alias above.
        if (variable.type.toBasetype.ty == TY.Tstruct)
            if (auto plain = expression.isVarExp)
                if (auto declaration = plain.var.isVarDeclaration)
                    if (auto existing = declaration in _structLocals) {
                        _structLocals[variable] = *existing;
                        return true;
                    }

        // A ref local bound directly to another class-typed local (`ref C
        // alias_ = source;`): a class variable's own storage is a scalar
        // reference slot inline in this frame, just like any other scalar
        // local. Alias `variable` to that exact same frame offset rather
        // than copying the pointer value into a fresh slot, so both
        // address-of and assignment through `variable` reach the identical
        // slot `source` uses, not merely its pointee.
        if (variable.type.toBasetype.ty == TY.Tclass)
            if (auto plain = expression.isVarExp)
                if (auto declaration = plain.var.isVarDeclaration)
                    if (auto existing = declaration in _locals) {
                        _locals[variable] = *existing;
                        _classPointerLocals[variable] =
                            variable.type.toBasetype.isTypeClass.sym;
                        return true;
                    }

        if (auto dot = expression.isDotVarExp) {
            // A ref local bound to a field within a class array field's
            // element (`ref int r = c.arr[i].field;`): the class-field
            // counterpart of the array-element case below, checked first
            // since `tryStructField` would otherwise resolve the element
            // through a throwaway copy (its struct-of-structs array-element
            // case has no class-heap counterpart), aliasing the copy instead
            // of the field's real storage.
            if (auto element = tryClassArrayFieldElementFieldPointer(dot)) {
                _locals[variable] = element.pointer;
                _refLocalPointers[variable] = scalarType(element.type);
                return true;
            }

            // A ref local bound to a field within a struct slice field's
            // element (`ref int r = s.arr[i].field;`): the struct-field
            // counterpart of the class case above, checked first for the
            // same reason -- `tryStructField` would otherwise resolve the
            // element through a throwaway copy.
            if (auto element = tryStructSliceFieldElementFieldPointer(dot)) {
                _locals[variable] = element.pointer;
                _refLocalPointers[variable] = scalarType(element.type);
                return true;
            }

            if (auto field = tryStructField(dot)) {
                if (variable.type.toBasetype.ty == TY.Tstruct) {
                    _structLocals[variable] = StructLocal(
                        field.offset,
                        structDeclarationOf(variable.type),
                    );
                    return true;
                }
                _locals[variable] = field.offset;
                return true;
            }

            // A ref local bound directly to a scalar class field: the field's
            // storage lives on the native heap rather than inline in this
            // frame, so (unlike the struct-field case above) the local's slot
            // cannot alias it by frame offset alone. Instead the slot holds
            // the field's runtime heap address, and every read/write/address-
            // of goes through the same `_refLocalPointers` indirection an
            // array-element ref local already uses.
            if (variable.type.toBasetype.ty != TY.Tstruct)
                if (auto field = tryClassPointerField(dot)) {
                    _locals[variable] = classFieldAddress(*field);
                    _refLocalPointers[variable] = scalarType(field.type);
                    return true;
                }
        }

        auto index = expression.isIndexExp;
        if (index is null)
            return false;

        if (index.type.toBasetype.ty == TY.Tstruct) {
            // The associative array stores mutable DMD declaration pointers.
            auto declaration = structDeclarationOf(index.type);
            auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
            if (descriptor is null)
                return false;

            const indexSlot = compileExpression(index.e2);
            const pointer =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            _code ~= Instruction(
                Op.copy,
                pointer,
                descriptor.offset,
                cast(ushort) size_t.sizeof,
            );
            const scaled =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            const stride = compileSizeConstant(
                dynamicArrayElementSize(index.e1.type, ScalarType.void_),
            );
            _code ~= Instruction(Op.mulInt8, scaled, indexSlot.offset, stride);
            _code ~= Instruction(Op.addInt8, pointer, pointer, scaled);
            _locals[variable] = pointer;
            _structPointerLocals[variable] = declaration;
            return true;
        }

        auto pointer = tryPointerToElement(index);
        if (pointer is null)
            return false;

        const offset = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _locals[variable] = offset;
        _refLocalPointers[variable] = pointer.pointerElement;
        _code ~= Instruction(
            Op.copy, offset, pointer.offset, cast(ushort) size_t.sizeof,
        );
        return true;
    }

    private void compileComplexDoubleDeclaration(VarDeclaration variable) {
        const offset = allocateComplexDouble;
        _locals[variable] = offset;
        _complexDoubleLocals[variable] = true;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            zeroFrameBlock(offset, complexDoubleSize);
            return;
        }

        const value =
            compileComplexDoubleOperand(initializerExpression(initializer.exp));
        _code ~= Instruction(
            Op.copy,
            offset,
            value.offset,
            cast(ushort) complexDoubleSize,
        );
    }

    // A pointer local `T* p` holds a raw `size_t` address in an 8-byte frame
    // slot. The initializer is a pointer-valued expression (`arr.ptr`,
    // `&arr[i]`, `p + n`, ...); copy its address word into the slot and record
    // the pointed-at element scalar for later stride and dereference.
    private void compileClassPointerDeclaration(VarDeclaration variable) {
        import std.conv: text;

        const offset = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            throw new Exception(text(
                "Unsupported class initializer in bytecode core: ",
                declarationChars(variable),
            ));

        const pointer =
            compileExpression(initializerExpression(initializer.exp));
        if (!pointer.isPointer)
            throw new Exception(text(
                "Unsupported class initializer in bytecode core: ",
                declarationChars(variable),
            ));

        _locals[variable] = offset;
        _classPointerLocals[variable] =
            variable.type.toBasetype.isTypeClass.sym;
        _capturedOffsets[variable] = offset;
        _code ~= Instruction(
            Op.copy, offset, pointer.offset, cast(ushort) size_t.sizeof,
        );
    }

    private void compilePointerDeclaration(VarDeclaration variable) {
        import dmd.astenums: TY;
        import std.conv: text;

        const offset = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;

        // No initializer, or an explicit `= null` (`NullExp`, typed
        // `typeof(null)` not `T*`): allocate a zeroed native-word slot,
        // taking the element scalar from the declared type.
        if (initializer is null ||
            initializerExpression(initializer.exp).isNullExp !is null) {
            _locals[variable] = offset;
            _pointerLocals[variable] = pointerElementScalar(variable.type);
            _capturedOffsets[variable] = offset;
            _code ~= Instruction(
                Op.loadConstant,
                offset,
                constantIndex(0),
                cast(ushort) size_t.sizeof,
            );
            return;
        }

        const pointer =
            compileExpression(initializerExpression(initializer.exp));
        if (!pointer.isPointer)
            throw new Exception(text(
                "Unsupported pointer initializer in bytecode core: ",
                declarationChars(variable),
            ));

        _locals[variable] = offset;
        auto declaredElement = variable.type.toBasetype.nextOf;
        _pointerLocals[variable] =
            declaredElement !is null &&
            declaredElement.toBasetype.ty == TY.Tdelegate
            ? pointer.pointerElement
            : pointerElementScalar(variable.type);
        _capturedOffsets[variable] = offset;
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

    // A delegate local holds a 16-byte `{functionIndex, context}` pair built
    // from a lambda literal, nested function address, or struct member address.
    // The tracking entry records the callee so `d()` recovers its layout and
    // result type.
    private void compileDelegateDeclaration(VarDeclaration variable) {
        import std.conv: text;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        auto delegate_ = initializer is null
            ? DelegateInitializer.init
            : delegateInitializer(initializerExpression(initializer.exp));
        if (delegate_.function_ is null)
            throw new Exception(text(
                "Unsupported delegate initializer in bytecode core: ",
                declarationChars(variable),
            ));

        const offset = allocateBytes(delegateValueSize, size_t.sizeof);
        emitDelegateValue(offset, delegate_.function_, delegate_.contextOffset);
        _delegateLocals[variable] = DelegateLocal(offset, delegate_.function_);
    }

    // Store a `{functionIndex, context}` delegate pair into the 16-byte slot at
    // `offset`: the callee's registered VM index in the first word, the context
    // word (receiver offset, enclosing frame base, or null) in the second.
    private void emitDelegateValue(
        in ushort offset,
        FuncDeclaration function_,
        in ushort contextOffset,
    ) {
        const index = registerFunction(function_);
        _code ~= Instruction(
            Op.loadConstant, offset, constantIndex(index),
            cast(ushort) size_t.sizeof,
        );
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (offset + size_t.sizeof),
            contextOffset,
            cast(ushort) size_t.sizeof,
        );
    }

    private DelegateInitializer delegateInitializer(Expression initializer) {
        if (auto literal = initializer.isFuncExp)
            if (literal.fd !is null)
                return DelegateInitializer(
                    literal.fd, delegateContextOffset(literal.fd, null),
                );

        if (auto delegate_ = initializer.isDelegateExp)
            if (delegate_.func !is null)
                return DelegateInitializer(
                    delegate_.func,
                    delegateContextOffset(delegate_.func, delegate_.e1),
                );

        if (auto address = initializer.isAddrExp) {
            if (auto variable = address.e1.isVarExp)
                if (auto function_ = variable.var.isFuncDeclaration)
                    return DelegateInitializer(
                        function_, delegateContextOffset(function_, null),
                    );

            if (auto dot = address.e1.isDotVarExp)
                if (auto function_ = dot.var.isFuncDeclaration)
                    return DelegateInitializer(
                        function_, delegateContextOffset(function_, dot.e1),
                    );
        }

        return DelegateInitializer.init;
    }

    // The frame offset of a delegate-typed expression's 16-byte
    // `{functionIndex, context}` pair: an already-materialised delegate
    // local or parameter reuses its own slot; any other delegate expression
    // (a lambda literal, `&freeFunction`, `&receiver.method`) is built fresh.
    private ushort delegateOperandOffset(Expression argument) {
        import std.conv: text;

        while (auto cast_ = argument.isCastExp)
            argument = cast_.e1;

        if (auto variable = argument.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto existing = declaration in _delegateLocals)
                    return existing.offset;
                if (auto existing = declaration in _delegateParameterLocals)
                    return *existing;
            }

        auto delegate_ = delegateInitializer(argument);
        if (delegate_.function_ is null)
            throw new Exception(text(
                "Unsupported delegate argument in bytecode core: ",
                expressionChars(argument),
            ));

        const offset = allocateBytes(delegateValueSize, size_t.sizeof);
        emitDelegateValue(offset, delegate_.function_, delegate_.contextOffset);
        return offset;
    }

    private ushort delegateContextOffset(
        FuncDeclaration function_,
        Expression receiver,
    ) {
        if (thisStructDeclaration(function_) !is null) {
            if (auto address = receiver is null ? null : receiver.isAddrExp)
                receiver = address.e1;
            const receiverOffset = receiver is null
                ? _thisLocal.offset
                : structOperandOffset(receiver);
            return compileSizeConstant(receiverOffset);
        }

        if (needsNestedFrameContext(function_)) {
            const context = allocateBytes(
                cast(uint) size_t.sizeof, size_t.sizeof,
            );
            _code ~= Instruction(Op.frameBaseIndex, context);
            const one = compileSizeConstant(1);
            _code ~= Instruction(Op.addInt8, context, context, one);
            return context;
        }

        return compileSizeConstant(0);
    }

    private Operand* tryDelegateProperty(DotVarExp dot) {
        if (dot.var is null || dot.var.ident is null)
            return null;

        return tryDelegateProperty(dot.e1, dot.var.ident.toString);
    }

    private Operand* tryDelegateProperty(DotIdExp dot) {
        if (dot.ident is null)
            return null;

        return tryDelegateProperty(dot.e1, dot.ident.toString);
    }

    private Operand* tryDelegateProperty(
        Expression receiver,
        in const(char)[] property,
    ) {
        auto variable = receiver.isVarExp;
        if (variable is null)
            return null;

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            return null;

        auto delegateLocal = declaration in _delegateLocals;
        if (delegateLocal is null)
            return null;

        if (property == "funcptr") {
            auto result = new Operand;
            *result = Operand(
                delegateLocal.offset,
                ScalarType.ulong_,
                true,
                ScalarType.void_,
            );
            return result;
        }

        if (property == "ptr") {
            auto result = new Operand;
            *result = Operand(
                cast(ushort) (delegateLocal.offset + size_t.sizeof),
                ScalarType.ulong_,
                true,
                ScalarType.void_,
            );
            return result;
        }

        return null;
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
        _capturedOffsets[variable] = offset;

        if (totalSize == 0)
            return;

        if (variable._init !is null &&
            variable._init.isVoidInitializer !is null)
            return;

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

        if (compileStaticArrayValueInto(offset, variable.type, source))
            return;

        throw new Exception(text(
            "Unsupported static array initializer in bytecode core: ",
            declarationChars(variable),
        ));
    }

    // Block-copies `source`'s value into the `staticArraySize(type)` bytes of
    // static-array storage at `offset`, or returns `false` if `source` is not
    // a recognized static-array value form. Shared by
    // `compileStaticArrayDeclaration`'s initializer handling and whole-value
    // static-array assignment (`arr = rhs;`), which denote the same value
    // forms.
    private bool compileStaticArrayValueInto(
        ushort offset,
        Type type,
        Expression source,
    ) {
        import dmd.astenums: TY;

        const totalSize = cast(uint) staticArraySize(type);

        // `char[N] c = "..."`: copy the literal bytes directly into the inline
        // slot rather than building a slice descriptor.
        if (auto string_ = stringLiteralOf(source)) {
            loadStaticString(offset, totalSize, string_);
            return true;
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
            return true;
        }

        // `T[N] dest = c.arr`: the class-field counterpart of the frame-to-
        // frame copy above -- `arr`'s storage lives in the class's own heap
        // block, addressed through a real runtime pointer
        // (`classFieldAddress`) rather than a frame offset, so the copy
        // reads through that pointer instead. Limited to the sizes
        // `pointerLoadOp` supports, matching every other fixed-size
        // pointer-read block copy in this module.
        if (auto classField = classStaticArrayFieldOf(source))
            if (totalSize == 1 || totalSize == 2 || totalSize == 4 ||
                totalSize == 8 || totalSize == 16)
            {
                _code ~= Instruction(
                    pointerLoadOp(totalSize),
                    offset,
                    classFieldAddress(*classField),
                    compileSizeConstant(0),
                );
                return true;
            }

        if (auto literal = arrayLiteralOf(source)) {
            compileStaticArrayLiteral(offset, type, literal);
            return true;
        }

        if (source.type.toBasetype.ty == TY.Tsarray) {
            const value = compileExpression(source);
            _code ~= Instruction(
                Op.copy,
                offset,
                value.offset,
                cast(ushort) totalSize,
            );
            return true;
        }

        // `T[N] dest = src` for an element type with a postblit lowers to a
        // `_d_arrayctor` call: block-copy each element, then run its postblit.
        if (compileArrayConstructor(offset, type, source))
            return true;

        return false;
    }

    // A vector local is represented as the same inline bytes as its underlying
    // static-array type. This slice only needs scalar splat construction and
    // `.array` extraction.
    private void compileVectorDeclaration(VarDeclaration variable) {
        import std.conv: text;

        auto vectorType = variable.type.toBasetype.isTypeVector;
        assert(vectorType !is null);

        auto arrayType = vectorType.basetype; // DMD Type APIs are mutable.
        const totalSize = cast(uint) staticArraySize(arrayType);
        const offset = allocateBytes(totalSize, staticArrayAlign(arrayType));
        _staticArrayLocals[variable] = offset;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            zeroFrameBlock(offset, totalSize);
            return;
        }

        auto vector = initializerExpression(initializer.exp).isVectorExp;
        if (vector is null)
            throw new Exception(text(
                "Unsupported vector initializer in bytecode core: ",
                declarationChars(variable),
            ));

        auto elementType = arrayType.toBasetype.nextOf;
        const elementScalar = scalarType(elementType);
        const elementSize = cast(uint) size(elementScalar);
        const count = totalSize / elementSize;
        const value = compileExpression(vector.e1);
        foreach (index; 0 .. count)
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (offset + index * elementSize),
                value.offset,
                cast(ushort) elementSize,
            );
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
        _capturedOffsets[variable] = offset;

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

        // DMD lowers `S value;` through the struct's init-symbol VarExp. Its
        // `defaultInitLiteral` describes the actual default bytes, including
        // enum fields and non-zero defaults; use it rather than treating an
        // init-symbol read as a value stored in the frame.
        if (source.isVarExp !is null) {
            import dmd.typesem: defaultInitLiteral;

            auto literal = variable.type.toBasetype.isTypeStruct
                .defaultInitLiteral(variable.loc).isStructLiteralExp;
            if (literal !is null) {
                compileStructLiteralInto(offset, literal);
                return;
            }
        }

        if (source.isVarExp !is null &&
            compileDefaultStructFields(offset, declaration))
            return;

        throw new Exception(text(
            "Unsupported struct initializer in bytecode core: ",
            declarationChars(variable),
        ));
    }

    // DMD lowers `S value;` through an init-symbol VarExp. Materialise each
    // field's explicit initializer at the offset DMD computed for the struct;
    // fields without one retain the frame's zeroed bytes, except `char[N]`,
    // whose implicit value is `char.init`.
    private bool compileDefaultStructFields(
        in ushort base,
        imported!"dmd.dstruct".StructDeclaration declaration,
    ) {
        import dmd.astenums: TY;

        bool materialised;
        foreach (field; declaration.fields) {
            auto fieldType = field.type;
            const fieldOffset = cast(ushort) (base + field.offset);
            auto initializer =
                field._init is null ? null : field._init.isExpInitializer;

            if (fieldType.toBasetype.ty == TY.Tsarray &&
                fieldType.toBasetype.nextOf.toBasetype.ty == TY.Tchar) {
                if (initializer !is null) {
                    auto string_ = stringLiteralOf(
                        initializerExpression(initializer.exp),
                    );
                    if (string_ is null)
                        return false;

                    loadStaticString(
                        fieldOffset,
                        cast(uint) staticArraySize(fieldType),
                        string_,
                    );
                    materialised = true;
                    continue;
                }

                const elementSize = size(ScalarType.char_);
                const elementCount =
                    cast(uint) staticArraySize(fieldType) / elementSize;
                const basis = compileSizeConstant(char.init);
                foreach (index; 0 .. elementCount)
                    _code ~= Instruction(
                        Op.copy,
                        cast(ushort) (fieldOffset + index * elementSize),
                        basis,
                        cast(ushort) elementSize,
                    );
                materialised = true;
                continue;
            }

            if (initializer is null)
                continue;

            const type = scalarType(fieldType);
            const value = compileExpression(
                initializerExpression(initializer.exp),
            );
            _code ~= Instruction(
                Op.copy,
                fieldOffset,
                value.offset,
                cast(ushort) size(type),
            );
            materialised = true;
        }
        return materialised;
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
        import std.conv: text;

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

            if (fieldType.toBasetype.ty == TY.Tarray) {
                compileDynamicArrayInto(
                    fieldOffset, dynamicArrayElementType(fieldType), element,
                );
                continue;
            }

            if (fieldType.toBasetype.ty == TY.Taarray) {
                compileAssocArrayInto(fieldOffset, element);
                continue;
            }

            if (fieldType.toBasetype.ty == TY.Tdelegate) {
                if (isNullLiteral(element))
                    continue;

                throw new Exception(text(
                    "Unsupported non-null delegate struct field in bytecode core: ",
                    expressionChars(element),
                ));
            }

            if (isPointerType(fieldType)) {
                if (isNullLiteral(element))
                    continue;

                const value = compileExpression(element);
                _code ~= Instruction(
                    Op.copy,
                    fieldOffset,
                    value.offset,
                    cast(ushort) size_t.sizeof,
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
    // a string literal, a scalar to broadcast to every element, or an array
    // literal. The array-literal element type may itself be scalar, a nested
    // static array, or a struct; `compileStaticArrayLiteral` recurses through
    // those to their leaves, so the element scalar type is only needed for
    // the scalar-broadcast fallback below, not up front.
    private void storeStaticArrayField(
        in ushort fieldOffset,
        Type fieldType,
        Expression element,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        if (auto string_ = element.isStringExp) {
            loadStaticString(
                fieldOffset,
                cast(uint) staticArraySize(fieldType),
                string_,
            );
            return;
        }

        if (auto literal = arrayLiteralOf(element)) {
            compileStaticArrayLiteral(fieldOffset, fieldType, literal);
            return;
        }

        // `S(seed)` broadcasts a scalar into all elements of the field.
        if (element.type.toBasetype.ty != TY.Tsarray) {
            const elementScalar = scalarType(fieldType.toBasetype.nextOf);
            const elementSize = size(elementScalar);
            const count = cast(uint) staticArraySize(fieldType) / elementSize;
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

        // A nested function that reads the enclosing method's `this` -- a
        // capturing lambda (`() => this.field`) or a plain nested named
        // function (`int helper() { return this.field; }`) -- receives that
        // `this` as its context. DMD models the context as `vthis` (typed
        // `void*`) and resolves the captured field's `ThisExp.var` to the
        // enclosing method's own `vthis`. Give the nested function a hidden
        // `this` block of the enclosing struct so the ordinary receiver ABI
        // carries the context and `this.field` resolves against it.
        return capturedThisStructDeclaration(function_);
    }

    // The enclosing struct whose `this` a nested function reads, or null if
    // `function_` is not such a function. The function is nested in a struct
    // method and holds a context (`vthis`); the struct is the method's
    // receiver aggregate. This claims the receiver shape for any vthis-
    // carrying nested function under a struct method regardless of what else
    // it captures, so a function that ALSO reads an enclosing local (not just
    // `this`) is claimed here too. That is safe rather than silently wrong:
    // claiming this shape skips building a closure environment for the
    // function, so the captured local's own read never resolves and throws
    // its own "Unsupported variable" diagnostic before any receiver value
    // could be used. Capturing an enclosing local is not yet modelled; the
    // leading-edge closures work must address it.
    //
    // A struct declared inside a function (a voldemort type) carries an extra
    // hidden context-pointer field appended after its declared fields
    // (`AggregateDeclaration.isNested`), which shifts every field's runtime
    // offset from the plain by-declaration-order offset this path assumes.
    // Only claim the `this`-receiver shape for a non-nested enclosing struct;
    // a nested one falls back to the "unsupported" diagnostic.
    private imported!"dmd.dstruct".StructDeclaration
    capturedThisStructDeclaration(FuncDeclaration function_) {
        if (function_.vthis is null)
            return null;

        // A nested function with captured outer locals receives a closure
        // context, even when DMD also reports the enclosing struct method's
        // `this` through `vthis`. Do not consume that context as a struct
        // receiver: the captured-variable paths need the hidden frame context.
        if (hasCapturedOuterLocal(function_))
            return null;

        auto enclosing = enclosingMethodOf(function_);
        if (enclosing is null)
            return null;
        auto aggregate = enclosing.isThis();
        if (aggregate is null)
            return null;
        auto structDeclaration = aggregate.isStructDeclaration;
        if (structDeclaration is null || structDeclaration.isNested)
            return null;
        return structDeclaration;
    }

    private bool hasCapturedOuterLocal(FuncDeclaration function_) {
        foreach (variable; function_.outerVars)
            if (variable.isThisDeclaration is null)
                return true;
        return false;
    }

    private bool needsNestedFrameContext(FuncDeclaration function_) {
        return function_.vthis !is null &&
            function_.isThis() is null &&
            capturedThisStructDeclaration(function_) is null;
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
                if (auto existing = declaration in _withDerefBases)
                    return existing;

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

        if (auto dot = call.e1.isDotVarExp) {
            if (auto receiver = refParameterCallReceiverOffset(dot.e1))
                return *receiver;
            return structOperandOffset(dot.e1);
        }

        // An IIFE `(() => this.field)()`: the callee is the lambda directly (a
        // FuncExp), and its hidden `this` block is the enclosing method's own
        // `this` receiver, already present in this frame.
        if (call.e1.isFuncExp !is null && _hasThis)
            return _thisLocal.offset;

        // A direct unqualified call to a nested named function that reads the
        // enclosing method's `this` (`helper()`, where `int helper() { return
        // this.field; }`): the callee is a plain VarExp naming the function,
        // and its hidden `this` block is the enclosing method's own `this`
        // receiver, already present in this frame.
        if (call.e1.isVarExp !is null && _hasThis)
            return _thisLocal.offset;

        throw new Exception(text(
            "Unsupported method receiver in bytecode core: ",
            expressionChars(call),
        ));
    }

    // A captured struct local belongs to the caller frame, whereas a struct
    // method's hidden `this` is an inline block in this frame. Materialise the
    // captured block for the call, then preserve the caller-visible mutation by
    // writing the whole block back once the callee returns.
    private MethodReceiver methodReceiver(CallExp call) {
        import dmd.astenums: TY;

        if (auto dot = call.e1.isDotVarExp)
            if (auto variable = dot.e1.isVarExp)
                if (auto declaration = variable.var.isVarDeclaration)
                    if (_hasNestedContext &&
                        declaration.type.toBasetype.ty == TY.Tstruct &&
                        declaration !in _structLocals)
                        if (auto captured = declaration in _capturedOffsets) {
                            const offset = allocateStructBlock(declaration.type);
                            const frameIndex = capturedFrameIndex(*captured);
                            const blockSize = cast(ushort)
                                staticArraySize(declaration.type);
                            _code ~= Instruction(
                                Op.frameLoad, offset, frameIndex, blockSize,
                            );
                            return MethodReceiver(offset, frameIndex, blockSize);
                        }

        return MethodReceiver(methodReceiverOffset(call), 0, 0);
    }

    // A struct receiver returned by `ref`, or through `&`, from one of the
    // receiver call's own `ref` parameters aliases that caller lvalue. Resolve
    // nested forwarding calls from the inside out, passing each recovered
    // caller slot into call emission so every argument expression runs once.
    private ushort* refParameterCallReceiverOffset(Expression expression) {
        if (auto dereference = expression.isPtrExp)
            expression = dereference.e1;
        if (auto address = expression.isAddrExp)
            expression = address.e1;
        auto call = expression.isCallExp;
        auto function_ = call is null ? null : callFunction(call);
        auto type = function_ is null ? null : function_.type.isTypeFunction;
        if (type is null || call.arguments is null)
            return null;

        auto returned = provenFinalReturnExpression(function_.fbody);
        const returnsAddress = returned !is null &&
            returned.isAddrExp !is null;
        if (!type.isRef && !returnsAddress)
            return null;
        if (auto dereference = returned is null ? null : returned.isPtrExp)
            returned = dereference.e1;
        if (auto address = returned is null ? null : returned.isAddrExp)
            returned = address.e1;
        auto variable = returned is null ? null : returned.isVarExp;
        auto parameter = variable is null ? null : variable.var.isVarDeclaration;
        auto index = parameter is null || !parameter.isReference
            ? null
            : parameterIndex(function_, parameter);
        if (index is null || *index >= call.arguments.length)
            return null;

        auto result = refParameterCallReceiverOffset(
            (*call.arguments)[*index],
        );
        if (result is null) {
            result = new ushort;
            *result = referenceOffset((*call.arguments)[*index]);
        }
        compileCall(call, null, index, result);
        return result;
    }

    // A struct method whose entire body is `return &this.field;` (or the
    // equivalent DMD lowering of `return this.field.ptr;` for a static-array
    // field, an `AddrExp` over a `DotVarExp` on `ThisExp`) returns a pointer
    // that must alias the receiver's own storage. The ordinary call
    // mechanism instead copies the receiver by value into the callee's own
    // frame (so field mutations can be written back) and computes the
    // address relative to that copy; because the machine places every
    // direct callee's frame at the same offset past the caller's own frame
    // (`base + callerFrameSize`), a second sibling call sharing the same
    // caller reuses that exact memory before the first call's returned
    // pointer is read, aliasing the two "receiver" addresses together. Skip
    // the call and compute the address directly against the receiver's own
    // stable caller-frame location instead.
    private Operand* tryReceiverFieldAddressCall(
        CallExp call,
        FuncDeclaration function_,
    ) {
        if (thisStructDeclaration(function_) is null)
            return null;
        if (!isPointerType(call.type))
            return null;
        // Only a bare `return &this.field;` body qualifies: any preceding
        // statement could have side effects (e.g. `++count; return
        // &count;`), and this fast path never calls `compileCall`, so it
        // must not skip anything that runs before the return.
        if (!isBareReturnStatement(function_.fbody))
            return null;
        // A call with arguments would need those argument expressions
        // evaluated; this fast path has no call-argument emission at all.
        if (call.arguments !is null && call.arguments.length > 0)
            return null;

        auto returned = provenFinalReturnExpression(function_.fbody);
        auto address = returned is null ? null : returned.isAddrExp;
        if (address is null)
            return null;
        auto dot = address.e1.isDotVarExp;
        if (dot is null || dot.e1.isThisExp is null)
            return null;
        auto field = dot.var.isVarDeclaration;
        if (field is null || !field.isField)
            return null;

        const receiverOffset = methodReceiverOffset(call);
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.frameAddress,
            pointer,
            cast(ushort) (receiverOffset + field.offset),
        );
        auto result = new Operand;
        *result = Operand(
            pointer, ScalarType.ulong_, true, pointerElementScalar(call.type),
        );
        return result;
    }

    // True when `statement` is exactly a single `return` statement (through
    // any wrapping `ScopeStatement`/single-element `CompoundStatement`), with
    // nothing preceding it. `tryReceiverFieldAddressCall` requires this: it
    // has no mechanism to compile a preceding statement's side effects.
    private bool isBareReturnStatement(Statement statement) {
        if (statement is null)
            return false;
        if (auto scope_ = statement.isScopeStatement)
            return isBareReturnStatement(scope_.statement);
        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements is null || compound.statements.length != 1)
                return false;
            return isBareReturnStatement((*compound.statements)[0]);
        }
        return statement.isReturnStatement !is null;
    }

    private Operand classMethodReceiver(CallExp call) {
        import std.conv: text;

        if (auto dot = call.e1.isDotVarExp) {
            const receiver = compileExpression(dot.e1);
            if (receiver.isPointer) {
                emitNullClassReferenceCheck(
                    receiver.offset,
                    "function call through null class reference `null`",
                );
                return receiver;
            }
        }

        if (_hasClassThis)
            return Operand(
                _classThisOffset,
                ScalarType.ulong_,
                true,
                ScalarType.void_,
            );

        throw new Exception(text(
            "Unsupported class method receiver in bytecode core: ",
            expressionChars(call),
        ));
    }

    // The inline frame offset of a struct-valued expression: a struct lvalue's
    // base, or a struct literal materialised into a fresh block.
    private ushort structOperandOffset(Expression expression) {
        import std.conv: text;

        if (auto dereference = expression.isPtrExp) {
            const pointer = compileExpression(dereference.e1);
            const structSize = cast(uint) staticArraySize(expression.type);
            if (pointer.isPointer &&
                (structSize == 1 || structSize == 2 || structSize == 4 ||
                    structSize == 8 || structSize == 16))
            {
                const offset = allocateBytes(
                    structSize,
                    staticArrayAlign(expression.type),
                );
                _code ~= Instruction(
                    pointerLoadOp(structSize),
                    offset,
                    pointer.offset,
                    compileSizeConstant(0),
                );
                return offset;
            }
        }

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
        bool writeBackThroughFrame;
        ushort structOffset;
        ushort frameIndexOffset;
        ushort structSize;
        bool writeBackThroughModule;
        ushort moduleOffset;
    }

    // Resolve `base.field` (a DotVarExp over a struct lvalue) to the field's
    // inline frame offset (`base + field.offset`) and type, or null if the base
    // is not a resolvable struct value.
    private StructField* tryStructField(DotVarExp dot) {
        auto field = dot.var.isVarDeclaration;
        if (field is null)
            return null;

        // A nested function that reads a struct value from its enclosing
        // frame -- its enclosing method's own `this`, or an outer local (a
        // `lazy` argument thunk's captured struct) -- receives the parent
        // frame as its context. Materialise the native struct block before
        // addressing the field, and retain the parent-frame index so every
        // write through this field can be copied back.
        if (_hasNestedContext)
            if (auto receiver = capturedStructReceiver(dot.e1))
                if (auto captured = receiver in _capturedOffsets) {
                    const structOffset = allocateStructBlock(dot.e1.type);
                    const frameIndexOffset = capturedFrameIndex(*captured);
                    const structSize = cast(ushort) staticArraySize(dot.e1.type);
                    _code ~= Instruction(
                        Op.frameLoad,
                        structOffset,
                        frameIndexOffset,
                        structSize,
                    );
                    auto result = new StructField;
                    *result = StructField(
                        cast(ushort) (structOffset + field.offset),
                        field.type,
                        true,
                        structOffset,
                        frameIndexOffset,
                        structSize,
                    );
                    return result;
                }

        // A module-level (`__gshared`/`static`) struct variable's field
        // (`quickbiteDatasegPoint.x`): materialise the whole block from
        // `_program.moduleData` into a fresh frame slot, the module
        // counterpart of the captured-context branch above; a write through
        // this field writes the whole block back through `Op.storeModule`
        // instead of `Op.frameStore`.
        if (auto variable = dot.e1.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto moduleVariable = moduleStructVariableOrNull(declaration)) {
                    const structOffset = allocateStructBlock(dot.e1.type);
                    _code ~= Instruction(
                        Op.loadModule,
                        structOffset,
                        moduleVariable.offset,
                        moduleVariable.size,
                    );
                    auto result = new StructField;
                    *result = StructField(
                        cast(ushort) (structOffset + field.offset),
                        field.type,
                        false,
                        structOffset,
                        0,
                        moduleVariable.size,
                        true,
                        moduleVariable.offset,
                    );
                    return result;
                }

        bool resolved;
        const base = structBaseOffsetOrMaterialise(dot.e1, resolved);
        if (!resolved)
            return null;

        const nestedThisFieldOffset =
            (dot.e1.isThisExp !is null || dot.e1.isSuperExp !is null) &&
                _hasThis &&
                _thisLocal.declaration !is null &&
                _thisLocal.declaration.isNested
            ? size_t.sizeof
            : 0;
        auto result = new StructField;
        *result = StructField(
            cast(ushort) (base + nestedThisFieldOffset + field.offset),
            field.type,
        );
        return result;
    }

    // The enclosing-frame struct variable `expression` reads as a receiver
    // for field access -- the enclosing method's own `this` (only when this
    // function has none of its own), or an outer local captured into this
    // function (a `lazy` argument thunk's struct-typed local) -- or null if
    // `expression` is not such a receiver. Excludes this function's own
    // struct locals, which resolve directly through `_structLocals` instead.
    private VarDeclaration capturedStructReceiver(Expression expression) {
        import dmd.astenums: TY;

        if (!_hasThis)
            if (auto this_ = expression.isThisExp)
                return this_.var;

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (declaration.type.toBasetype.ty == TY.Tstruct)
                    if (declaration !in _structLocals)
                        return declaration;

        return null;
    }

    // The captured-frame offset of `expression`'s field, when `expression`
    // is a (possibly multi-level) field access chain whose ultimate receiver
    // is a captured outer local (`capturedStructReceiver`) -- `s.field` or
    // `s.inner.field` -- or null if it is not such a chain. This is the
    // offset a captured scalar's own address already resolves through
    // (`tryAddressOfCaptured`); reusing it for a field gives `&s.field` the
    // same real outer-frame storage as `&s` itself, rather than the address
    // of a copy.
    private ushort* capturedFieldFrameOffset(Expression expression) {
        if (auto receiver = capturedStructReceiver(expression))
            if (auto captured = receiver in _capturedOffsets)
                return captured;

        if (auto dot = expression.isDotVarExp)
            if (auto field = dot.var.isVarDeclaration)
                if (auto baseOffset = capturedFieldFrameOffset(dot.e1)) {
                    auto result = new ushort;
                    *result = cast(ushort) (*baseOffset + field.offset);
                    return result;
                }

        return null;
    }

    private void writeBackStructField(in StructField field) {
        if (field.writeBackThroughFrame) {
            _code ~= Instruction(
                Op.frameStore,
                field.structOffset,
                field.frameIndexOffset,
                field.structSize,
            );
            return;
        }

        if (field.writeBackThroughModule)
            _code ~= Instruction(
                Op.storeModule,
                field.structOffset,
                field.moduleOffset,
                field.structSize,
            );
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

        if (_hasNestedContext)
            if (auto variable = expression.isVarExp)
                if (auto declaration = variable.var.isVarDeclaration)
                    if (declaration.type.toBasetype.ty == TY.Tstruct)
                        if (auto captured = declaration in _capturedOffsets) {
                            resolved = true;
                            return loadCapturedLocal(
                                declaration,
                                *captured,
                            ).offset;
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
            // lives inline at `arrayBase + i * elementSize`. Checked before the
            // dynamic-array branch below because `dynamicArrayDescriptorOrNull`
            // also accepts a static-array local (as a materialised read-only
            // view for slicing); resolving through that view here would copy
            // the element into a throwaway temporary, silently discarding any
            // write through the returned offset.
            if (auto index = expression.isIndexExp)
                if (staticArrayOffsetOf(index.e1) !is null) {
                    resolved = true;
                    return locateStaticArrayElement(index).offset;
                }

            // `arr[i]` element of a dynamic array of structs: copy the heap
            // element into a fresh inline block so struct field reads can use
            // normal `base + field.offset` addressing.
            if (auto index = expression.isIndexExp)
                if (auto descriptor = dynamicArrayDescriptorOrNull(index.e1)) {
                    resolved = true;
                    return loadDynamicArrayElement(
                        descriptor.offset,
                        descriptor.elementType,
                        index.e2,
                        expression.type,
                    ).offset;
                }

            if (auto call = expression.isCallExp) {
                resolved = true;

                // `S(args)` through an explicit constructor: DMD types the
                // `CallExp` itself as the constructed struct even though
                // `__ctor` is declared `void`, so `compileCall`'s own
                // destination (the shared void-call dummy slot) is not the
                // constructed value. The value lives at the receiver's frame
                // offset, the same location already passed as the call's
                // hidden `this`; resolve it once and hand it to `compileCall`
                // so the receiver is not evaluated a second time.
                auto function_ = callFunction(call);
                if (function_ !is null && function_.isCtorDeclaration !is null) {
                    const receiver = MethodReceiver(methodReceiverOffset(call));
                    compileCall(call, &receiver);
                    return receiver.offset;
                }

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
    // within the enclosing frame. Nested structs carry the enclosing frame's
    // base index in their hidden `this` block; nested function delegates carry
    // the same raw index in their hidden context slot.
    private Operand loadCapturedLocal(
        VarDeclaration declaration,
        in ushort capturedOffset,
    ) {
        import dmd.astenums: TY;

        if (declaration.type.toBasetype.ty == TY.Tstruct) {
            const destination = allocateStructBlock(declaration.type);
            _code ~= Instruction(
                Op.frameLoad,
                destination,
                capturedFrameIndex(capturedOffset),
                cast(ushort) staticArraySize(declaration.type),
            );
            return Operand(destination, ScalarType.void_);
        }

        const type = scalarType(declaration.type);
        const valueSize = size(type);
        const destination = allocateBytes(valueSize, valueSize);
        _code ~= Instruction(
            Op.frameLoad,
            destination,
            capturedFrameIndex(capturedOffset),
            cast(ushort) valueSize,
        );
        if (declaration.type.toBasetype.ty == TY.Tclass)
            return Operand(
                destination, ScalarType.ulong_, true, ScalarType.void_,
            );
        return Operand(destination, type);
    }

    private void storeCapturedLocal(
        VarDeclaration declaration,
        in ushort capturedOffset,
        in Operand value,
    ) {
        const valueSize = size(scalarType(declaration.type));
        _code ~= Instruction(
            Op.frameStore,
            value.offset,
            capturedFrameIndex(capturedOffset),
            cast(ushort) valueSize,
        );
    }

    private ushort capturedFrameIndex(in ushort capturedOffset) {
        const contextBase =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy,
            contextBase,
            _nestedContextOffset == ushort.max
                ? _thisLocal.offset
                : _nestedContextOffset,
            cast(ushort) size_t.sizeof,
        );
        if (_nestedContextOffset != ushort.max) {
            const one = compileSizeConstant(1);
            _code ~= Instruction(Op.subInt8, contextBase, contextBase, one);
        }
        const sourceIndex =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const offsetConstant = compileSizeConstant(capturedOffset);
        _code ~= Instruction(
            Op.addInt8, sourceIndex, contextBase, offsetConstant,
        );
        return sourceIndex;
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
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        if (structPointerDeclaration(base.type) is null &&
            (declaration is null || declaration !in _structPointerLocals))
            return null;

        const pointer = compileExpression(base);
        if (!pointer.isPointer)
            return null;

        auto result = new StructPointerField;
        *result = StructPointerField(
            pointer.offset, cast(ushort) field.offset, field.type,
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

    // `p.field`: read a scalar or dynamic-array field through the struct
    // pointer at `ptr + field.offset` into a fresh slot.
    private Operand loadStructPointerField(StructPointerField field) {
        import dmd.astenums: TY;

        if (field.type.toBasetype.ty == TY.Tarray) {
            const destination =
                allocateBytes(sliceDescriptorSize, size_t.sizeof);
            _code ~= Instruction(
                Op.pointerLoad16,
                destination,
                structFieldAddress(field),
                compileSizeConstant(0),
            );
            return Operand(destination, ScalarType.void_);
        }

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
        if (field.type.toBasetype.ty == TY.Tclass)
            return Operand(destination, fieldScalar, true, ScalarType.void_);
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

    private static struct ClassPointerField {
        ushort pointerSlot;
        ushort fieldOffset;
        Type type;
    }

    private ClassPointerField* tryClassPointerField(DotVarExp dot) {
        import std.conv: text;

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            return null;

        const receiver = compileExpression(dot.e1);
        if (!receiver.isPointer)
            return null;

        emitNullClassReferenceCheck(
            receiver.offset,
            text(
                "class `", expressionChars(dot.e1),
                "` is `null` and cannot be dereferenced",
            ),
        );
        auto result = new ClassPointerField;
        *result = ClassPointerField(
            receiver.offset, cast(ushort) field.offset, field.type,
        );
        return result;
    }

    private Operand loadClassPointerField(ClassPointerField field) {
        import dmd.astenums: TY;

        if (field.type.toBasetype.ty == TY.Tarray) {
            const destination =
                allocateBytes(sliceDescriptorSize, size_t.sizeof);
            _code ~= Instruction(
                Op.pointerLoad16,
                destination,
                classFieldAddress(field),
                compileSizeConstant(0),
            );
            return Operand(destination, ScalarType.void_);
        }

        // A struct-typed field (`MonitorProxy m_proxy` in `Mutex`) lives
        // inline in the class block rather than behind a separate pointer:
        // its own address is the field's address, with no load to perform.
        // Mark it as a further-dereferenceable pointer so a nested `.field`
        // hop (`this.m_proxy.link`) resolves against it.
        if (field.type.toBasetype.ty == TY.Tstruct)
            return Operand(
                classFieldAddress(field), ScalarType.ulong_, true,
                ScalarType.void_,
            );

        const fieldScalar = scalarType(field.type);
        const elementSize = size(fieldScalar);
        const fieldPointer = classFieldAddress(field);
        const destination = allocateBytes(elementSize, elementSize);
        _code ~= Instruction(
            pointerLoadOp(elementSize),
            destination,
            fieldPointer,
            compileSizeConstant(0),
        );
        if (isPointerType(field.type))
            return Operand(
                destination,
                ScalarType.ulong_,
                true,
                pointerElementScalar(field.type),
            );
        // A class-reference field (`next` in `Node next;`) loads a real
        // pointer: mark it so a further `.field` hop (`a.next.value`) can
        // dereference through it, mirroring how a class-typed local is
        // exposed as a pointer.
        if (field.type.toBasetype.ty == TY.Tclass)
            return Operand(
                destination, ScalarType.ulong_, true, ScalarType.void_,
            );
        return Operand(destination, fieldScalar);
    }

    private ushort classFieldAddress(in ClassPointerField field) {
        const fieldPointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const fieldOffset = compileSizeConstant(field.fieldOffset);
        _code ~= Instruction(
            Op.addInt8, fieldPointer, field.pointerSlot, fieldOffset,
        );
        return fieldPointer;
    }

    // `box.field = value`: write `value` (already in a frame slot) through the
    // class pointer at `ptr + field.offset`.
    private void storeClassPointerField(
        ClassPointerField field,
        in ushort valueSlot,
    ) {
        const elementSize = size(scalarType(field.type));
        const fieldPointer = classFieldAddress(field);
        _code ~= Instruction(
            pointerStoreOp(elementSize),
            valueSlot,
            fieldPointer,
            compileSizeConstant(0),
        );
    }

    private void emitNullClassReferenceCheck(
        in ushort pointerSlot,
        in string message,
    ) {
        import std.conv: text;

        const dataOffset = _program.data.length;
        ubyte[] bytes;
        foreach (character; message)
            bytes ~= cast(ubyte) character;
        if (dataOffset > ushort.max || bytes.length > ushort.max)
            throw new Exception(text(
                "Null class diagnostic too large for bytecode core: ",
                message,
            ));
        _program.data ~= bytes;
        _code ~= Instruction(
            Op.throwIfNullClassReference,
            pointerSlot,
            cast(ushort) dataOffset,
            cast(ushort) bytes.length,
        );
    }

    // `new S(args)`: heap-allocate a single struct block, initialise it (run the
    // constructor, or store each argument into its field for a constructor-less
    // struct), and yield a raw `S*` pointer operand. Null if `newExp` is not a
    // struct `new` (so array/exception `new` fall through).
    private Operand* tryNewScalar(NewExp newExp) {
        import dmd.astenums: TY;
        import std.conv: text;

        if (newExp.newtype is null)
            return null;

        switch (newExp.newtype.toBasetype.ty) with (TY) {
            case Tstruct, Tclass, Tarray, Tsarray, Taarray:
                return null;
            default:
                break;
        }

        const elementType = scalarType(newExp.newtype);
        const elementSize = size(elementType);
        const value = allocateBytes(elementSize, elementSize);

        if (newExp.arguments is null || newExp.arguments.length == 0) {
            _code ~= Instruction(
                Op.loadConstant,
                value,
                constantIndex(0),
                cast(ushort) elementSize,
            );
        } else if (newExp.arguments.length == 1) {
            const initializer = compileExpression((*newExp.arguments)[0]);
            _code ~= Instruction(
                Op.copy,
                value,
                initializer.offset,
                cast(ushort) elementSize,
            );
        } else
            throw new Exception(text(
                "Unsupported scalar new in bytecode core: ",
                expressionChars(newExp),
            ));

        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.allocStruct, pointer, value, cast(ushort) elementSize,
        );

        auto result = new Operand;
        *result = Operand(pointer, ScalarType.ulong_, true, elementType);
        return result;
    }

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
            pointer, ScalarType.ulong_, true, ScalarType.void_,
        );
        return result;
    }

    private Operand* tryNewClass(NewExp newExp) {
        import dmd.astenums: TY;

        if (newExp.newtype is null ||
            newExp.newtype.toBasetype.ty != TY.Tclass)
            return null;

        auto classType = newExp.newtype.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return null;

        const pointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.allocClass,
            pointer,
            registerClass(classType.sym),
            cast(ushort) classType.sym.structsize,
        );
        if (newExp.member !is null)
            runClassConstructor(pointer, newExp.member, newExp.arguments);
        else
            initialiseClassObject(pointer, classType.sym, newExp.arguments);

        auto result = new Operand;
        *result = Operand(
            pointer, ScalarType.ulong_, true, ScalarType.void_,
        );
        return result;
    }

    private void initialiseClassObject(
        in ushort pointer,
        imported!"dmd.dclass".ClassDeclaration class_,
        Expressions* arguments,
    ) {
        import dmd.astenums: TY;

        if (arguments is null || arguments.length == 0)
            return;

        if (auto msg = classFieldNamed(class_, "msg"))
            if ((*arguments)[0].type !is null &&
                isStringType((*arguments)[0].type))
                storeClassField(pointer, msg, (*arguments)[0]);

        size_t argumentIndex;
        foreach (field; class_.fields) {
            if (argumentIndex >= arguments.length)
                break;
            if (field.type.toBasetype.ty == TY.Tclass) {
                ++argumentIndex;
                continue;
            }
            storeClassField(pointer, field, (*arguments)[argumentIndex]);
            ++argumentIndex;
        }
    }

    private void storeClassField(
        in ushort pointer,
        VarDeclaration field,
        Expression valueExpression,
    ) {
        import dmd.astenums: TY;

        const fieldPointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const offset = compileSizeConstant(field.offset);
        _code ~= Instruction(Op.addInt8, fieldPointer, pointer, offset);

        if (field.type.toBasetype.ty == TY.Tarray) {
            const destination =
                allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileDynamicArrayInto(
                destination,
                dynamicArrayElementType(field.type),
                valueExpression,
            );
            _code ~= Instruction(
                Op.pointerStore16,
                destination,
                fieldPointer,
                compileSizeConstant(0),
            );
            return;
        }

        const value = compileExpression(valueExpression);
        _code ~= Instruction(
            pointerStoreOp(size(scalarType(field.type))),
            value.offset,
            fieldPointer,
            compileSizeConstant(0),
        );
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
            if (field.type.toBasetype.ty == TY.Tarray) {
                compileDynamicArrayInto(
                    fieldOffset,
                    dynamicArrayElementType(field.type),
                    (*arguments)[index],
                );
                continue;
            }

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

    private void runClassConstructor(
        in ushort pointer,
        FuncDeclaration constructor,
        Expressions* arguments,
    ) {
        const index = registerFunction(constructor);
        const layout = parameterLayout(constructor);
        const argumentArea = allocateBytes(layout.blockSize, 8);

        _code ~= Instruction(
            Op.copy,
            cast(ushort) (argumentArea + layout.classThisOffset),
            pointer,
            cast(ushort) size_t.sizeof,
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
        const elementIsArray = arrayElementIsArray(variable.type);
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _dynamicArrayLocals[variable] =
            DynamicArrayLocal(offset, elementType, elementIsArray);
        _capturedOffsets[variable] = offset;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            _code ~= Instruction(Op.nullSlice, offset);
            return;
        }

        auto source = initializerExpression(initializer.exp);
        if (auto staticArray = staticArrayViewOffset(source)) {
            _dynamicArrayLocals[variable].isStaticArrayView = true;
            _dynamicArrayLocals[variable].staticArrayOffset = *staticArray;
        } else if (auto classField = classStaticArrayViewFieldOf(source)) {
            _dynamicArrayLocals[variable].isStaticArrayView = true;
            _dynamicArrayLocals[variable].staticArrayViewIsClassField = true;
            _dynamicArrayLocals[variable].staticArrayOffset =
                classFieldAddress(*classField);
        }
        compileDynamicArrayInto(
            offset, elementType, source, elementIsArray);
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
        import dmd.astenums: TY;
        import std.conv: text;

        if (tryStackArrayLiteralSliceInto(destination, elementType, source))
            return;

        if (auto comma = source.isCommaExp) {
            compileExpression(comma.e1);
            compileDynamicArrayInto(
                destination, elementType, comma.e2, elementIsArray,
            );
            return;
        }

        if (source.isNullExp) {
            _code ~= Instruction(Op.nullSlice, destination);
            return;
        }

        if (auto cast_ = source.isCastExp)
            if (isDynamicArrayArgument(cast_.e1) ||
                isStringType(cast_.e1.type)) {
                compileDynamicArrayInto(
                    destination, elementType, cast_.e1, elementIsArray,
                );
                rescaleReinterpretedSliceLength(
                    destination, elementType, elementIsArray, cast_.e1.type,
                );
                return;
            }

        // A bare string literal (`string s = "hi";`, no cast) initialising a
        // `string`/`wstring`/`dstring` destination: point the descriptor
        // directly at the data segment, matching the cast form above,
        // instead of falling to the generic array-literal path below
        // (`compileStringBytesArrayInto`), which heap-copies each code unit
        // — correct only for the mutable `char[]` destination DMD retypes an
        // initialising literal to.
        if (auto literal = source.isStringExp)
            if (isStringType(literal.type)) {
                emitLoadStringLiteral(destination, literal);
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

        if (auto conditional = source.isCondExp) {
            const condition = compileBoolCondition(conditional.econd);
            const falseJump = emitJumpIfFalse(condition);
            compileDynamicArrayInto(
                destination, elementType, conditional.e1, elementIsArray,
            );
            const endJump = emitJump;
            patchJump(falseJump);
            compileDynamicArrayInto(
                destination, elementType, conditional.e2, elementIsArray,
            );
            patchJump(endJump);
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

        if (source.isIndexExp !is null &&
            source.type.toBasetype.ty == TY.Tarray) {
            const value = compileExpression(source);
            _code ~= Instruction(
                Op.copy,
                destination,
                value.offset,
                cast(ushort) sliceDescriptorSize,
            );
            return;
        }

        // Any other string source reaching this far (a runtime
        // `object.classinfo.name`): none of the dedicated cases above
        // matched, and it is not a known dynamic-array descriptor either, so
        // copy the ordinary {ptr, length} descriptor `compileExpression`
        // already resolves it to.
        if (isStringType(source.type)) {
            _code ~= Instruction(
                Op.copy,
                destination,
                compileExpression(source).offset,
                cast(ushort) sliceDescriptorSize,
            );
            return;
        }

        if (auto string_ = stringLiteralOf(source)) {
            compileStringBytesArrayInto(destination, elementType, string_);
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

        const elementSize =
            dynamicArrayElementSize(source.type, elementType, elementIsArray);
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            auto element = (*literal.elements)[elementIndex];
            const value = element.type.toBasetype.ty == TY.Tstruct
                ? Operand(structOperandOffset(element), ScalarType.void_)
                : compileExpression(element);
            const index = compileSizeConstant(elementIndex);
            _code ~= Instruction(
                indexStoreOp(elementSize),
                value.offset,
                destination,
                index,
            );
        }
    }

    // `cast(T2[])x`: D reinterprets `x`'s backing bytes as `T2` elements, so an
    // element-size-changing cast rescales the copied descriptor's element
    // count by the byte-size ratio (`newLength = oldLength * oldElementSize /
    // newElementSize`); the pointer word is untouched. A same-size cast (the
    // common qualifier-only case, e.g. `const(int)[]` to `int[]`) is a no-op
    // here. `void` is a real one-byte D array element
    // (`void.sizeof == 1`), not the bytecode core's "no value" scalar tag, so
    // it is special-cased rather than routed through `size(ScalarType.void_)`.
    // Scoped to a plain scalar-element destination; an array-of-arrays or
    // struct-blob destination (`elementIsArray`, or `elementType == void_`
    // marking a struct/static-array element) keeps the existing pass-through,
    // unaffected by this rescale.
    private void rescaleReinterpretedSliceLength(
        in ushort destination,
        in ScalarType destinationElementType,
        in bool destinationElementIsArray,
        Type sourceType,
    ) {
        import dmd.astenums: TY;

        if (destinationElementIsArray ||
            destinationElementType == ScalarType.void_)
            return;

        auto sourceElement = sourceType.toBasetype.nextOf.toBasetype;
        const sourceElementSize = sourceElement.ty == TY.Tvoid
            ? 1
            : dynamicArrayElementSize(
                sourceType, dynamicArrayElementType(sourceType));
        const destinationElementSize = size(destinationElementType);
        if (sourceElementSize == destinationElementSize)
            return;

        const lengthOffset = cast(ushort) (destination + size_t.sizeof);
        const numerator = compileSizeConstant(sourceElementSize);
        const denominator = compileSizeConstant(destinationElementSize);
        _code ~= Instruction(
            Op.mulInt8, lengthOffset, lengthOffset, numerator,
        );
        _code ~= Instruction(
            Op.divUnsignedInt8, lengthOffset, lengthOffset, denominator,
        );
    }

    private bool tryStackArrayLiteralSliceInto(
        in ushort destination,
        in ScalarType elementType,
        Expression source,
    ) {
        import dmd.astenums: TY;

        auto comma = source.isCommaExp;
        if (comma is null)
            return false;

        auto declaration = comma.e1.isDeclarationExp;
        if (declaration is null)
            return false;

        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null ||
            variable.type is null ||
            variable.type.toBasetype.ty != TY.Tsarray)
            return false;

        if (staticArrayVariableOf(comma.e2) !is variable)
            return false;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            return false;

        auto literal =
            initializerExpression(initializer.exp).isArrayLiteralExp;
        if (literal is null)
            return false;

        const count = literal.elements is null ? 0 : literal.elements.length;

        // A nested array-of-arrays literal (`[[1, 2], [3, 4]]`): each element
        // is itself an array, stored as a 16-byte descriptor, mirroring
        // `compileDynamicArrayInto`'s own array-of-arrays literal handling.
        // `variable.type` (the hoisted stack temp's own declared type) names
        // the literal's true shape; `elementType`'s deepest-leaf-scalar
        // convention can't distinguish this from the flat case on its own.
        if (arrayElementIsArray(variable.type)) {
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
                _code ~= Instruction(
                    Op.indexStore16,
                    inner,
                    destination,
                    compileSizeConstant(elementIndex),
                );
            }
            return true;
        }

        const elementSize = size(elementType);
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            auto value = compileExpression((*literal.elements)[elementIndex]);
            if (size(value.type) < elementSize)
                value = extend(value, elementType);
            _code ~= Instruction(
                indexStoreOp(elementSize),
                value.offset,
                destination,
                compileSizeConstant(elementIndex),
            );
        }
        return true;
    }

    private void compileStaticArrayAsDynamicInto(
        in ushort destination,
        in ScalarType elementType,
        Expression source,
    ) {
        import std.conv: text;

        auto sourceOffset = staticArrayOffsetOf(source);
        if (sourceOffset is null)
            throw new Exception(text(
                "Unsupported dynamic array initializer in bytecode core: ",
                expressionChars(source),
            ));

        auto sourceElementType = source.type.toBasetype.nextOf;
        const sourceElementSize =
            cast(uint) staticArraySize(sourceElementType);
        // A dynamic-array element (`int[][2]`'s `int[]` elements) is a
        // 16-byte slice descriptor; `elementType` names its innermost scalar
        // for indexing further in, not its own native width, so its byte
        // stride must come from DMD's size of the element type, the same as
        // the struct/static-array blob case, never from `size(elementType)`.
        const elementSize = elementType == ScalarType.void_ ||
                arrayElementIsArray(source.type)
            ? sourceElementSize
            : cast(uint) size(elementType);
        if (sourceElementSize < elementSize)
            throw new Exception(text(
                "Unsupported dynamic array initializer in bytecode core: ",
                expressionChars(source),
            ));

        const count =
            cast(uint) staticArraySize(source.type) / sourceElementSize;
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            const index = compileSizeConstant(elementIndex);
            _code ~= Instruction(
                indexStoreOp(elementSize),
                cast(ushort) (*sourceOffset + elementIndex * sourceElementSize),
                destination,
                index,
            );
        }
    }

    // The class-field counterpart of `compileStaticArrayAsDynamicInto`:
    // builds the same throwaway heap copy, but reads each element through
    // `basePointer` (a real runtime pointer, `classFieldAddress`) with
    // `Op.pointerLoad*` instead of a folded frame offset with `Op.copy`,
    // since the source field's storage lives in the class's own heap block.
    private void compileClassStaticArrayAsDynamicInto(
        in ushort destination,
        in ScalarType elementType,
        Type sourceType,
        in ushort basePointer,
    ) {
        auto sourceElementType = sourceType.toBasetype.nextOf;
        const sourceElementSize =
            cast(uint) staticArraySize(sourceElementType);
        const elementSize = elementType == ScalarType.void_ ||
                arrayElementIsArray(sourceType)
            ? sourceElementSize
            : cast(uint) size(elementType);

        const count =
            cast(uint) staticArraySize(sourceType) / sourceElementSize;
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            const elementPointer =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            _code ~= Instruction(
                Op.addInt8,
                elementPointer,
                basePointer,
                compileSizeConstant(elementIndex * sourceElementSize),
            );
            const loaded = allocateBytes(elementSize, elementSize);
            _code ~= Instruction(
                pointerLoadOp(elementSize),
                loaded,
                elementPointer,
                compileSizeConstant(0),
            );
            const index = compileSizeConstant(elementIndex);
            _code ~= Instruction(
                indexStoreOp(elementSize), loaded, destination, index,
            );
        }
    }

    private VarDeclaration staticArrayVariableOf(Expression expression) {
        if (auto cast_ = expression.isCastExp)
            return staticArrayVariableOf(cast_.e1);

        auto variable = expression.isVarExp;
        return variable is null ? null : variable.var.isVarDeclaration;
    }

    private void compileStringBytesArrayInto(
        in ushort destination,
        in ScalarType elementType,
        StringExp string_,
    ) {
        import quickbite.frontend.dmd.string_literals: stringChars;
        import std.conv: text;

        const elementSize = size(elementType);
        if (elementSize == string_.sz) {
            _code ~= Instruction(
                Op.allocArray,
                destination,
                cast(ushort) elementSize,
                cast(ushort) string_.numberOfCodeUnits,
            );

            foreach (elementIndex; 0 .. string_.numberOfCodeUnits) {
                const slot = allocate(elementType);
                _code ~= Instruction(
                    Op.loadConstant,
                    slot,
                    constantIndex(string_.getIndex(elementIndex)),
                    cast(ushort) elementSize,
                );
                _code ~= Instruction(
                    indexStoreOp(elementSize),
                    slot,
                    destination,
                    compileSizeConstant(elementIndex),
                );
            }
            return;
        }

        const bytes = cast(const(ubyte)[]) stringChars(string_);
        if (bytes.length % elementSize != 0)
            throw new Exception(text(
                "Unsupported dynamic array initializer in bytecode core: ",
                expressionChars(string_),
            ));

        const count = bytes.length / elementSize;
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            ulong value;
            foreach (byteIndex; 0 .. elementSize)
                value = (value << 8) |
                    bytes[elementIndex * elementSize + byteIndex];

            const slot = allocate(elementType);
            _code ~= Instruction(
                Op.loadConstant,
                slot,
                constantIndex(value),
                cast(ushort) elementSize,
            );
            _code ~= Instruction(
                indexStoreOp(elementSize),
                slot,
                destination,
                compileSizeConstant(elementIndex),
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
    // size (low 8 bits) for `allocArrayDynamic`. `char.init` and `wchar.init`
    // are all-one bytes; every other element type the core lowers
    // default-inits to all-zero bytes.
    private ushort packedFill(
        in ScalarType elementType,
        in uint elementSize = 0,
    ) @safe pure {
        const fill = elementType == ScalarType.char_ ||
            elementType == ScalarType.wchar_ ? 0xff : 0x00;
        return cast(ushort) ((fill << 8) |
            (elementSize == 0 ? size(elementType) : elementSize));
    }

    // The frame offset of a 16-byte slice descriptor denoting the value of an
    // array-valued expression: a dynamic-array local's slot is returned in
    // place; any other form (slice, literal, call, null) is materialised into a
    // fresh descriptor slot.
    private ushort arrayDescriptorOffset(
        in ScalarType elementType,
        Expression source,
        in bool elementIsArray = false,
    ) {
        if (auto descriptor = dynamicArrayDescriptorOrNull(source))
            return descriptor.offset;

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileDynamicArrayInto(offset, elementType, source, elementIsArray);
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

        // A `string` source is an ordinary dynamic-array descriptor, like any
        // other `T[]`.
        const descriptor = dynamicArrayDescriptor(slice.e1);

        // Materialise lo and hi into adjacent size_t slots; the opcode reads
        // the pair from the single `bounds` offset.
        const bounds = allocateBytes(2 * size_t.sizeof, size_t.sizeof);
        const savedDollarLength = _activeDollarLength;
        _activeDollarLength = sliceLengthSlot(descriptor);
        const lo = slice.lwr is null
            ? compileSizeConstant(0)
            : compileExpression(slice.lwr).offset;
        _code ~= Instruction(
            Op.copy, bounds, lo, cast(ushort) size_t.sizeof,
        );

        const hi = slice.upr is null || isDollarExpression(slice.upr)
            ? _activeDollarLength
            : compileExpression(slice.upr).offset;
        _activeDollarLength = savedDollarLength;
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (bounds + size_t.sizeof),
            hi,
            cast(ushort) size_t.sizeof,
        );

        _code ~= Instruction(
            subSliceOp(
                dynamicArrayElementSize(
                    slice.e1.type,
                    elementType,
                    descriptor.elementIsArray,
                ),
            ),
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
            pointerSliceOp(pointerElementMetadata(slice.e1.type).byteStride),
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
        import dmd.astenums: TY;
        import std.conv: text;

        if (isComplexDoubleType(cast_.e1.type)) {
            const source = compileExpression(cast_.e1);
            if (isDoubleType(cast_.to))
                return Operand(source.offset, ScalarType.double_);
            if (isImaginaryDoubleType(cast_.to))
                return Operand(
                    complexImaginaryOffset(source.offset),
                    ScalarType.double_,
                );
        }

        if (isComplexDoubleType(cast_.to))
            return compileCastToComplexDouble(cast_);

        // `cast(T*)arr` / `arr.ptr`: yield the dynamic-array descriptor's
        // pointer word. `cast(U*)p` repaints an existing pointer value with the
        // target element type without changing the raw address. A string's
        // basetype is also `Tarray` and its descriptor is the ordinary
        // {ptr, length} form, so it takes the same path as any other `T[]`.
        if (isPointerType(cast_.to)) {
            if (isDynamicArrayArgument(cast_.e1) || isStringType(cast_.e1.type))
                return compileArrayPointer(cast_);

            const pointer = compileExpression(cast_.e1);
            if (pointer.isPointer)
                return Operand(
                    pointer.offset, ScalarType.ulong_, true,
                    pointerElementScalar(cast_.to),
                );

            throw new Exception(text(
                "Unsupported pointer cast in bytecode core: ",
                expressionChars(cast_),
            ));
        }

        const source = compileExpression(cast_.e1);
        if (cast_.to.toBasetype.isTypeClass !is null)
            return source;

        // `cast(T2[])x`: a dynamic-array-typed cast target (`dchar[]`, ...).
        // `source` already holds `x`'s slice descriptor; a same-element-size
        // cast (the common qualifier-only case, e.g. `dstring` to `dchar[]`)
        // passes the descriptor straight through, mirroring the class
        // pass-through just above. A genuine element-size reinterpretation
        // needs a fresh descriptor copy so `rescaleReinterpretedSliceLength`
        // can adjust the copy's length without touching `x`'s own descriptor.
        if (cast_.to.toBasetype.ty == TY.Tarray) {
            if (!isDynamicArrayArgument(cast_.e1) && !isStringType(cast_.e1.type))
                throw new Exception(text(
                    "Unsupported array cast in bytecode core: ",
                    expressionChars(cast_),
                ));

            const elementIsArray = arrayElementIsArray(cast_.to);
            const elementType = dynamicArrayElementType(cast_.to);
            const targetElementSize =
                dynamicArrayElementSize(cast_.to, elementType, elementIsArray);
            const sourceElementIsArray = arrayElementIsArray(cast_.e1.type);
            const sourceElementSize = dynamicArrayElementSize(
                cast_.e1.type,
                dynamicArrayElementType(cast_.e1.type),
                sourceElementIsArray,
            );
            if (targetElementSize == sourceElementSize)
                return source;

            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            _code ~= Instruction(
                Op.copy, offset, source.offset, cast(ushort) sliceDescriptorSize,
            );
            rescaleReinterpretedSliceLength(
                offset, elementType, elementIsArray, cast_.e1.type,
            );
            return Operand(offset, ScalarType.void_, false, elementType);
        }

        const target = scalarType(cast_.to);

        // `cast(bool)` on a pointer, integral, or floating source is
        // `source != 0` at the source's own width (DMD folds `x && true`/
        // `x || false`-shaped `LogicalExp`s into exactly this cast);
        // `compileTruthValue` already knows every source kind's zero
        // comparison.
        if (target == ScalarType.bool_ &&
            (source.isPointer || isCompoundIntegerScalar(source.type) ||
                isFloating(source.type)))
            return compileTruthValue(source);

        // Crossing the int/float boundary needs a numeric conversion, not a
        // byte copy or integer extension. Only double -> int is needed today.
        if (source.type == ScalarType.double_ && target == ScalarType.int_) {
            const offset = allocate(target);
            _code ~= Instruction(Op.convertDoubleToInt, offset, source.offset);
            return Operand(offset, target);
        }

        if (isIntegerScalar(source.type) && isFloating(target))
            return convertIntegerToFloating(source, target);

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

    private Operand compileCastToComplexDouble(CastExp cast_) {
        import std.conv: text;

        const source = compileExpression(cast_.e1);
        if (source.isComplex)
            return source;

        if (!isCompoundIntegerScalar(source.type) && !isFloating(source.type))
            throw new Exception(text(
                "Unsupported numeric cast in bytecode core: ",
                expressionChars(cast_),
            ));

        return complexDoubleFromReal(source);
    }

    private Operand convertIntegerToFloating(
        in Operand source,
        in ScalarType target,
    ) {
        import quickbite.backends.bytecode.core.program: unsignedConvertFlag;

        const offset = allocate(target);
        const width = cast(ushort) (size(source.type) |
            (isSigned(source.type) ? 0 : unsignedConvertFlag));
        _code ~= Instruction(
            integerToFloatingOp(target), offset, source.offset, width,
        );
        return Operand(offset, target);
    }

    private Operand convertFloating(
        in Operand source,
        in ScalarType target,
    ) {
        const offset = allocate(target);
        _code ~= Instruction(floatingWidenOp(source.type, target), offset,
            source.offset);
        return Operand(offset, target);
    }

    private ScalarType normaliseNumericOperands(
        ref Operand lhs,
        ref Operand rhs,
        Expression expression,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        if (lhs.type == ScalarType.bool_ && rhs.type == ScalarType.bool_)
            return ScalarType.bool_;

        if (isFloating(lhs.type) || isFloating(rhs.type)) {
            const lhsFloating = isFloating(lhs.type);
            const rhsFloating = isFloating(rhs.type);
            if ((!lhsFloating && !isCompoundIntegerScalar(lhs.type)) ||
                (!rhsFloating && !isCompoundIntegerScalar(rhs.type)))
                throw new Exception(text(
                    unsupportedMessage,
                    expressionChars(expression),
                ));

            const target = commonFloatingType(lhs.type, rhs.type);

            if (!lhsFloating)
                lhs = convertIntegerToFloating(lhs, target);
            else if (lhs.type != target)
                lhs = convertFloating(lhs, target);
            if (!rhsFloating)
                rhs = convertIntegerToFloating(rhs, target);
            else if (rhs.type != target)
                rhs = convertFloating(rhs, target);
            return target;
        }

        if (!isCompoundIntegerScalar(lhs.type) ||
            !isCompoundIntegerScalar(rhs.type))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(expression),
            ));

        if (size(lhs.type) < int.sizeof)
            lhs = extend(lhs, ScalarType.int_);
        if (size(rhs.type) < int.sizeof)
            rhs = extend(rhs, ScalarType.int_);

        if (size(lhs.type) < size(rhs.type))
            lhs = extend(lhs, rhs.type);
        else if (size(rhs.type) < size(lhs.type))
            rhs = extend(rhs, lhs.type);

        return integerComparisonType(lhs.type, rhs.type);
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

        return tryPointerToElement(index);
    }

    private Operand* tryPointerToElement(IndexExp index) {
        import dmd.astenums: TY;

        if (indexesStaticArray(index.e1)) {
            if (index.type.toBasetype.ty == TY.Tsarray ||
                index.type.toBasetype.ty == TY.Tstruct)
                return null;

            auto result = new Operand;
            *result = staticArrayElementPointer(
                staticArrayBaseOffset(index.e1), index.e2, index.type,
                compileSizeConstant(staticArrayLength(index.e1.type)),
            );
            return result;
        }

        // `&c.arr[i]`: the class-field counterpart of the `indexesStaticArray`
        // branch above -- the field's storage lives in the class's own heap
        // block, addressed via `classFieldAddress` (a real runtime pointer)
        // instead of a folded frame offset.
        if (index.e1.isDotVarExp !is null &&
            index.type.toBasetype.ty != TY.Tsarray &&
            index.type.toBasetype.ty != TY.Tstruct)
            if (auto pointer = tryClassStaticArrayElementPointer(index))
                return pointer;

        auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
        if (descriptor is null)
            return null;

        if (descriptor.isStaticArrayView) {
            auto result = new Operand;
            *result =
                staticArrayViewElementPointer(*descriptor, index.e2, index.type);
            return result;
        }

        const savedDollarLength = _activeDollarLength;
        _activeDollarLength = sliceLengthSlot(*descriptor);
        const indexSlot = compileExpression(index.e2);
        _activeDollarLength = savedDollarLength;

        // `&outer[i]` where `outer`'s element is itself a static array
        // (`int[2][]`): each row is materialised as its own separately
        // heap-allocated inner array (`innerArrayDescriptor`), so the row's
        // address is its inner descriptor's `.ptr` field, not a
        // scalar-strided offset into `outer`'s own backing store. DMD
        // pre-folds a further constant leaf index into a byte offset added
        // to this address (`&outer[i][0]` arrives as `&outer[i] + 0`), so
        // this pointer alone is `&outer[i]`.
        if (descriptor.elementIsArray &&
            index.type.toBasetype.ty == TY.Tsarray) {
            auto result = new Operand;
            *result = Operand(
                innerArrayRowPointer(*descriptor, indexSlot.offset),
                ScalarType.ulong_, true, descriptor.elementType,
            );
            return result;
        }

        auto result = new Operand;
        *result = pointerToElement(
            descriptor.offset, descriptor.elementType, indexSlot.offset,
        );
        return result;
    }

    // The runtime address of `outer[i]`'s separately heap-allocated inner row
    // (see `tryPointerToElement`'s `elementIsArray` branch): read the row's
    // own 16-byte slice descriptor out of `outer`'s backing store and take its
    // `.ptr` field. Shared with row assignment so writing a whole new row's
    // worth of values lands in the same heap block a pointer taken earlier
    // still addresses, instead of a fresh, differently addressed block.
    private ushort innerArrayRowPointer(
        in DynamicArrayLocal descriptor,
        in ushort indexSlot,
    ) {
        const inner = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.indexLoad16, inner, descriptor.offset, indexSlot,
        );
        const pointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, pointer, inner, cast(ushort) size_t.sizeof,
        );
        return pointer;
    }

    private Operand staticArrayElementPointer(
        in ushort baseOffset,
        Expression indexExpression,
        Type elementType,
        in ushort lengthSlot,
    ) {
        const basePointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.frameAddress, basePointer, baseOffset);

        const basePointerOperand = Operand(
            basePointer, ScalarType.ulong_, true, ScalarType.void_,
        );
        return advanceStaticArrayPointer(
            basePointerOperand, indexExpression, elementType, lengthSlot,
        );
    }

    // The real element pointer for a `DynamicArrayLocal` static-array view
    // (`__r[i]` inside `foreach (ref e; arr) ...`'s lowered loop): a local's
    // or struct field's base is a frame offset, resolved via
    // `Op.frameAddress` (`staticArrayElementPointer`); a class field's base
    // is already a runtime pointer (`classFieldAddress`), used directly.
    private Operand staticArrayViewElementPointer(
        in DynamicArrayLocal descriptor,
        Expression indexExpression,
        Type elementType,
    ) {
        const lengthSlot = sliceLengthSlot(descriptor);
        if (descriptor.staticArrayViewIsClassField)
            return advanceStaticArrayPointer(
                Operand(
                    descriptor.staticArrayOffset, ScalarType.ulong_, true,
                    ScalarType.void_,
                ),
                indexExpression, elementType, lengthSlot,
            );
        return staticArrayElementPointer(
            descriptor.staticArrayOffset, indexExpression, elementType,
            lengthSlot,
        );
    }

    // Advance a static-array base pointer by `indexExpression * elementType`'s
    // size, bounds checked against the size_t dimension at `lengthSlot`. The
    // result's `pointerElement` is `void_` for a sub-array or struct element
    // (an intermediate view with no scalar load/store opcode of its own),
    // matching `storeThroughPointer`'s convention of deriving such an
    // element's width from DMD's `Type.size()` instead.
    private Operand advanceStaticArrayPointer(
        in Operand basePointer,
        Expression indexExpression,
        Type elementType,
        in ushort lengthSlot,
    ) {
        import dmd.astenums: TY;

        const indexSlot = compileExpression(indexExpression);
        _code ~= Instruction(
            Op.checkStaticArrayIndex, indexSlot.offset, lengthSlot,
        );

        const scaled =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const stride =
            compileSizeConstant(cast(uint) staticArraySize(elementType));
        _code ~= Instruction(Op.mulInt8, scaled, indexSlot.offset, stride);

        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.addInt8, pointer, basePointer.offset, scaled);

        const ty = elementType.toBasetype.ty;
        const pointerElement = ty == TY.Tsarray ||
            ty == TY.Tstruct ||
            ty == TY.Tarray
                ? ScalarType.void_
                : scalarType(elementType);
        return Operand(pointer, ScalarType.ulong_, true, pointerElement);
    }

    // The runtime address of a static-array location: a static-array local's
    // frame slot, a static-array struct field's inline offset, or
    // (recursively) a further index into either. Mirrors
    // `staticArrayBaseOffset`'s walk but computes the address with actual
    // pointer arithmetic instead of folding into a single compile-time
    // offset, so a non-constant index anywhere in the chain (`m[i][j]`) is
    // supported. Null if `expression` does not denote a static-array
    // location at all.
    private Operand* tryStaticArrayRuntimeAddress(Expression expression) {
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto offset = declaration in _staticArrayLocals)
                    return frameAddressOperand(*offset);

        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot))
                return frameAddressOperand(field.offset);

        if (auto index = expression.isIndexExp) {
            auto base = tryStaticArrayRuntimeAddress(index.e1);
            if (base is null)
                return null;

            auto result = new Operand;
            *result = advanceStaticArrayPointer(
                *base, index.e2, index.type,
                compileSizeConstant(staticArrayLength(index.e1.type)),
            );
            return result;
        }

        return null;
    }

    // The runtime address of a static-array local's (or field's) own frame
    // slot, as a pointer operand with no scalar element type of its own yet
    // (the caller advances it by an index, or reads/writes the whole block).
    private Operand* frameAddressOperand(in ushort offset) {
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.frameAddress, pointer, offset);
        auto result = new Operand;
        *result =
            Operand(pointer, ScalarType.ulong_, true, ScalarType.void_);
        return result;
    }

    // True if any index in a static-array `IndexExp` chain (`m[i]`,
    // `m[i][j]`) is not a compile-time constant, in which case the element's
    // address must be computed at runtime (`tryStaticArrayRuntimeAddress`)
    // rather than folded into a fixed frame offset
    // (`locateStaticArrayElement`/`staticArrayBaseOffset`).
    private bool staticArrayChainNeedsRuntimeAddress(IndexExp index) {
        if (index.e2.isIntegerExp is null)
            return true;

        if (auto inner = index.e1.isIndexExp)
            return staticArrayChainNeedsRuntimeAddress(inner);

        return false;
    }

    // `m[i][j]` (or deeper) read where at least one index in the chain is a
    // runtime value: resolve the full chain to a runtime address and load
    // the scalar leaf through it. A fully constant chain is left to
    // `compileStaticArrayIndex`'s cheaper compile-time offset path, and a
    // chain whose result is itself a sub-array/struct view (not yet fully
    // indexed) is left unhandled here. Null if `index` is not a static-array
    // access at all.
    private Operand* tryStaticArrayRuntimeIndex(IndexExp index) {
        import dmd.astenums: TY;

        if (!indexesStaticArray(index.e1))
            return null;

        if (!staticArrayChainNeedsRuntimeAddress(index))
            return null;

        const ty = index.type.toBasetype.ty;
        if (ty == TY.Tsarray || ty == TY.Tstruct || ty == TY.Tarray)
            return null;

        auto pointer = tryStaticArrayRuntimeAddress(index);
        if (pointer is null)
            return null;

        auto result = new Operand;
        *result = loadThroughPointer(*pointer, compileSizeConstant(0));
        return result;
    }

    // `m[i][j] = rhs` (or deeper) where at least one index in the chain is a
    // runtime value: resolve the leaf address at runtime and write through
    // it, the runtime-address counterpart to `tryStaticArrayElement`'s
    // compile-time-offset path. Null if `index` is not a static-array
    // element access, or the chain is fully constant (handled above).
    private Operand* tryStaticArrayRuntimeElementAssign(
        IndexExp index,
        Expression rhs,
    ) {
        if (!indexesStaticArray(index.e1))
            return null;

        if (!staticArrayChainNeedsRuntimeAddress(index))
            return null;

        auto pointer = tryStaticArrayRuntimeAddress(index);
        if (pointer is null)
            return null;

        auto result = new Operand;
        *result = storeThroughPointer(*pointer, compileSizeConstant(0), rhs);
        return result;
    }

    // `c.arr[i]`'s element address: `classFieldAddress(field) + i *
    // elementSize`, computed at runtime since the field's storage lives in
    // the class's own heap block rather than an inline frame offset (unlike
    // the analogous struct-field case `tryStaticArrayElement`/
    // `locateStaticArrayElement` already handle via `tryStructField`). Null
    // if `index.e1` is not a class static-array field access.
    private Operand* tryClassStaticArrayElementPointer(IndexExp index) {
        auto dot = index.e1.isDotVarExp;
        if (dot is null)
            return null;

        auto field = classStaticArrayFieldOf(dot);
        if (field is null)
            return null;

        auto result = new Operand;
        *result = advanceStaticArrayPointer(
            Operand(
                classFieldAddress(*field), ScalarType.ulong_, true,
                ScalarType.void_,
            ),
            index.e2, index.type,
            compileSizeConstant(staticArrayLength(index.e1.type)),
        );
        return result;
    }

    // `c.arr[i]` read for a class static-array field: null (falling through
    // to `tryStaticArrayRuntimeIndex`/`compileStaticArrayIndex`'s struct/local
    // handling, or the "Unsupported" fallback) if `index.e1` is not one, or
    // the element itself is a sub-array/struct (not yet a scalar leaf).
    private Operand* tryClassStaticArrayFieldElement(IndexExp index) {
        import dmd.astenums: TY;

        const ty = index.type.toBasetype.ty;
        if (ty == TY.Tsarray || ty == TY.Tstruct || ty == TY.Tarray)
            return null;

        auto pointer = tryClassStaticArrayElementPointer(index);
        if (pointer is null)
            return null;

        auto result = new Operand;
        *result = loadThroughPointer(*pointer, compileSizeConstant(0));
        return result;
    }

    // `c.arr[i] = rhs` for a class static-array field: the class-field
    // counterpart of `tryStaticArrayElement`/`tryStaticArrayRuntimeElementAssign`.
    // Null if `index.e1` is not one.
    private Operand* tryClassStaticArrayFieldElementAssign(
        IndexExp index,
        Expression rhs,
    ) {
        auto pointer = tryClassStaticArrayElementPointer(index);
        if (pointer is null)
            return null;

        auto result = new Operand;
        *result = storeThroughPointer(*pointer, compileSizeConstant(0), rhs);
        return result;
    }

    // `c.arr[i]`'s element address for a class dynamic-array (slice) field:
    // the slice-field counterpart of `tryClassStaticArrayElementPointer`.
    // Unlike a static-array field, whose element storage lives inline in the
    // class's own heap block, a slice field's element storage lives wherever
    // its own `.ptr` word (loaded through `classFieldAddress`) already
    // points, so that pointer is loaded first and then advanced by `i *
    // elementSize` the same way. Null if `index.e1` is not a class
    // slice-field access.
    private Operand* tryClassSliceFieldElementPointer(IndexExp index) {
        import dmd.astenums: TY;

        auto dot = index.e1.isDotVarExp;
        if (dot is null ||
            dot.e1.type is null ||
            dot.e1.type.toBasetype.ty != TY.Tclass)
            return null;

        auto field = tryClassPointerField(dot);
        if (field is null || field.type.toBasetype.ty != TY.Tarray)
            return null;

        const descriptor = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.pointerLoad16, descriptor, classFieldAddress(*field),
            compileSizeConstant(0),
        );
        const basePointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, basePointer, descriptor, cast(ushort) size_t.sizeof,
        );

        auto result = new Operand;
        *result = advanceStaticArrayPointer(
            Operand(basePointer, ScalarType.ulong_, true, ScalarType.void_),
            index.e2, index.type,
            sliceLengthSlot(DynamicArrayLocal(descriptor, ScalarType.void_)),
        );
        return result;
    }

    // `c.arr[i].field`'s real runtime address for a field within an element
    // of a class array field (static-array or slice) of structs -- the
    // class-field counterpart of `tryStructField`'s struct-of-structs
    // array-element case, which folds to a compile-time frame offset that
    // does not exist for a class field's heap storage. `dot.e1` is the
    // element access (`c.arr[i]`); its real runtime element pointer,
    // computed by `tryClassStaticArrayElementPointer` or
    // `tryClassSliceFieldElementPointer` depending on which kind of array
    // field it is, is advanced by the leaf field's own offset within the
    // element struct. Returned alongside the field's own type so callers can
    // derive the pointed-at scalar type either as a pointer element (`&`) or
    // a `ref`-local's own type. Null if `dot.e1` is not a class array field
    // element access.
    private ClassArrayFieldElementField* tryClassArrayFieldElementFieldPointer(
        DotVarExp dot,
    ) {
        import dmd.astenums: TY;

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            return null;

        auto index = dot.e1.isIndexExp;
        if (index is null)
            return null;

        auto arrayDot = index.e1.isDotVarExp;
        if (arrayDot is null ||
            arrayDot.e1.type is null ||
            arrayDot.e1.type.toBasetype.ty != TY.Tclass)
            return null;

        auto arrayField = arrayDot.var.isVarDeclaration;
        if (arrayField is null)
            return null;

        Operand* elementPointer;
        if (arrayField.type.toBasetype.ty == TY.Tsarray)
            elementPointer = tryClassStaticArrayElementPointer(index);
        else if (arrayField.type.toBasetype.ty == TY.Tarray)
            elementPointer = tryClassSliceFieldElementPointer(index);
        if (elementPointer is null)
            return null;

        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.addInt8, pointer, elementPointer.offset,
            compileSizeConstant(cast(uint) field.offset),
        );
        auto result = new ClassArrayFieldElementField;
        *result = ClassArrayFieldElementField(pointer, field.type);
        return result;
    }

    // A located class array field element field: its real runtime pointer
    // and DMD type, returned by `tryClassArrayFieldElementFieldPointer`.
    private static struct ClassArrayFieldElementField {
        ushort pointer;
        Type type;
    }

    // `a[i].field`'s (or `a[i].outer.field`'s, for any depth of nested
    // struct fields) real runtime address for a field within an element of
    // an array of structs -- needed whenever the element type is a struct:
    // a static-array field element already folds to a real inline frame
    // offset through `structBaseOffsetOrMaterialise`'s
    // `locateStaticArrayElement` branch (so `tryStructField` resolves it
    // correctly on its own), but that same function's dynamic-array branch
    // resolves a slice element through `loadDynamicArrayElement`'s throwaway
    // copy, aliasing a temporary instead of the field's real heap storage.
    // `tryPointerToElement` already derives the real element pointer for
    // `a[i]` alone -- for any receiver it supports, including a bare local,
    // a struct's own slice field, and a class's own slice field -- so this
    // walks the field-access chain down from `dot` to the bottoming-out
    // `IndexExp`, summing every field's own offset, and advances that
    // element pointer by the total. Checked after
    // `tryClassArrayFieldElementFieldPointer`, which already claims the
    // single-field-level class-array-of-structs case. Null if `dot`'s field
    // chain does not bottom out at an array-of-structs element access.
    private StructArrayFieldElementField* tryStructSliceFieldElementFieldPointer(
        DotVarExp dot,
    ) {
        import dmd.astenums: TY;

        uint offset;
        Type leafFieldType;
        auto current = dot;
        for (;;) {
            auto field = current.var.isVarDeclaration;
            if (field is null)
                return null;
            offset += field.offset;
            if (leafFieldType is null)
                leafFieldType = field.type;

            if (auto index = current.e1.isIndexExp) {
                if (index.type.toBasetype.ty != TY.Tstruct)
                    return null;

                auto elementPointer = tryPointerToElement(index);
                if (elementPointer is null)
                    return null;

                const pointer =
                    allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
                _code ~= Instruction(
                    Op.addInt8, pointer, elementPointer.offset,
                    compileSizeConstant(offset),
                );
                auto result = new StructArrayFieldElementField;
                *result = StructArrayFieldElementField(pointer, leafFieldType);
                return result;
            }

            auto next = current.e1.isDotVarExp;
            if (next is null)
                return null;
            current = next;
        }
    }

    // A located struct array field element field: its real runtime pointer
    // and DMD type, returned by `tryStructSliceFieldElementFieldPointer`.
    private static struct StructArrayFieldElementField {
        ushort pointer;
        Type type;
    }

    // `&local` / `&base.field`: the native address of a scalar local's frame
    // slot (or a struct field's inline slot), yielding an `int*`-style pointer
    // operand over the pointed-at element type. Null if the operand is not a
    // scalar local or struct field.
    // `&local` as a SymOffExp (`symbolOffset`): the address of a local's frame
    // slot plus the symbol's byte offset, yielding an `int*`-style pointer
    // operand over the pointed-at element type. Null if the symbol is not a
    // scalar, static-array, or inline-struct local.
    private Operand* tryAddressOfSymbol(SymOffExp symOff) {
        auto declaration = symOff.var.isVarDeclaration;
        if (declaration is null)
            return null;
        auto existing = declaration in _locals;
        auto dynamicArray = declaration in _dynamicArrayLocals;
        auto staticArray = declaration in _staticArrayLocals;
        auto struct_ = declaration in _structLocals;
        if (existing is null && dynamicArray is null &&
            staticArray is null && struct_ is null) {
            if (auto pointer = tryAddressOfCaptured(
                    declaration, symOff.type.toBasetype.nextOf))
                return pointer;
            auto moduleVariable = moduleScalarVariableOrNull(declaration);
            if (moduleVariable is null || symOff.offset != 0)
                return null;

            const pointer = allocateBytes(
                cast(uint) size_t.sizeof,
                size_t.sizeof,
            );
            _code ~= Instruction(
                Op.moduleAddress,
                pointer,
                moduleVariable.offset,
            );
            auto result = new Operand;
            *result = Operand(
                pointer,
                ScalarType.ulong_,
                true,
                moduleVariable.type,
            );
            return result;
        }

        const base = existing !is null
            ? *existing
            : dynamicArray !is null
                ? dynamicArray.offset
                : staticArray !is null
                    ? *staticArray
                    : struct_.offset;
        const slot = cast(ushort) (base + symOff.offset);
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.frameAddress, pointer, slot);
        auto result = new Operand;
        *result = Operand(
            pointer, ScalarType.ulong_, true,
            dynamicArray !is null
                ? ScalarType.void_
                : struct_ is null
                // `existing is null` here means `staticArray` (the outer
                // guard above already ruled out all four being null): a
                // whole static-array local's address, e.g. `&arr` for
                // `int[2] arr`, needs `pointerElementScalar` (which unwraps
                // the array to its element's scalar type) rather than raw
                // `scalarType`, which throws on the array type itself.
                ? (existing is null
                    ? pointerElementScalar(symOff.type)
                    : scalarType(declaration.type))
                : ScalarType.void_,
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
            offset, ScalarType.ulong_, true, ScalarType.void_,
        );
    }

    private Operand* tryAddressOfLocal(AddrExp address) {
        import dmd.astenums: TY;

        ushort slot;
        Type pointedType;
        // A scalar `ref` parameter may share its caller storage with another
        // `ref` parameter of the same call; `refParameterAddress` resolves
        // the shared group's identity slot at runtime, giving `&first ==
        // &second` for two `ref` parameters bound to the same lvalue.
        bool isRefParameter;
        auto target = address.e1;
        while (auto cast_ = target.isCastExp)
            target = cast_.e1;

        if (auto variable = target.isVarExp) {
            auto declaration = variable.var.isVarDeclaration;
            if (declaration is null)
                return null;
            // `isReference` alone is too broad: it is also true for a `ref`
            // *local* (e.g. `ref int r = c.value;`), which never joins a
            // callee's `refAliasGroups` and has no active call frame when
            // addressed at top level, so `refParameterAddress` must only
            // fire for an actual formal parameter.
            isRefParameter = declaration.isReference && declaration.isParameter;
            if (auto descriptor = declaration in _dynamicArrayLocals) {
                slot = descriptor.offset;
                pointedType = declaration.type;
            }
            auto existing = declaration in _locals;
            // A ref local bound to a scalar class field (or array element)
            // stores the pointed-at storage's own runtime address in its
            // slot; that address IS `&variable`, so return it directly
            // rather than computing the address of the slot itself.
            if (existing !is null)
                if (auto element = declaration in _refLocalPointers) {
                    auto result = new Operand;
                    *result = Operand(
                        *existing,
                        ScalarType.ulong_,
                        true,
                        pointerElementScalar(address.type),
                    );
                    return result;
                }
            if (pointedType is null && existing is null) {
                if (auto struct_ = declaration in _structLocals) {
                    slot = struct_.offset;
                    pointedType = declaration.type;
                } else if (auto moduleVariable =
                        moduleScalarVariableOrNull(declaration)) {
                    const pointer = allocateBytes(
                        cast(uint) size_t.sizeof,
                        size_t.sizeof,
                    );
                    _code ~= Instruction(
                        Op.moduleAddress,
                        pointer,
                        moduleVariable.offset,
                    );
                    auto result = new Operand;
                    *result = Operand(
                        pointer,
                        ScalarType.ulong_,
                        true,
                        moduleVariable.type,
                    );
                    return result;
                } else {
                    auto staticArray = declaration in _staticArrayLocals;
                    if (staticArray is null) {
                        return tryAddressOfCaptured(
                            declaration,
                            address.type.toBasetype.nextOf,
                        );
                    }
                    slot = *staticArray;
                    pointedType = address.type.toBasetype.nextOf;
                }
            } else if (pointedType is null) {
                slot = *existing;
                pointedType = declaration.type;
            }
        } else if (auto dot = target.isDotVarExp) {
            // `&c.arr[i].field`: a class array field's element storage has no
            // frame offset for `tryStructField`'s generic struct-field path
            // to fold into (it lives in the class's own heap block, or
            // wherever a slice field's `.ptr` points), so it is checked
            // first, ahead of `tryStructField`'s otherwise-matching but
            // address-unsound copy-based element read.
            if (auto element = tryClassArrayFieldElementFieldPointer(dot)) {
                auto result = new Operand;
                *result = Operand(
                    element.pointer,
                    ScalarType.ulong_,
                    true,
                    pointerElementScalar(address.type),
                );
                return result;
            }
            // `&s.arr[i].field`: the struct-field counterpart of the class
            // case above, checked first for the same reason -- a struct
            // slice field's element storage has no frame offset for
            // `tryStructField`'s generic struct-field path to fold into
            // (only a static-array field's element does).
            if (auto element = tryStructSliceFieldElementFieldPointer(dot)) {
                auto result = new Operand;
                *result = Operand(
                    element.pointer,
                    ScalarType.ulong_,
                    true,
                    pointerElementScalar(address.type),
                );
                return result;
            }
            // `&s.field`/`&s.inner.field` where the ultimate receiver `s` is
            // a captured outer local: `tryStructField`'s captured-receiver
            // branch below reads the field from a fresh block materialised
            // in THIS frame (for ordinary value reads/writes-with-writeback),
            // so taking `Op.frameAddress` of that block's offset would
            // address the copy, not the shared storage a nested function and
            // its enclosing frame must alias. Resolve the field's real
            // address through the same runtime-index mechanism a captured
            // scalar's own address already uses, checked first for that
            // reason.
            if (_hasNestedContext)
                if (auto fieldOffset = capturedFieldFrameOffset(dot)) {
                    const pointer = allocateBytes(
                        cast(uint) size_t.sizeof, size_t.sizeof,
                    );
                    _code ~= Instruction(
                        Op.frameIndexAddress,
                        pointer,
                        capturedFrameIndex(*fieldOffset),
                    );
                    auto result = new Operand;
                    *result = Operand(
                        pointer,
                        ScalarType.ulong_,
                        true,
                        pointerElementScalar(address.type),
                    );
                    return result;
                }
            if (auto field = tryStructField(dot)) {
                slot = field.offset;
                pointedType = field.type;
            } else if (auto field = tryClassPointerField(dot)) {
                auto result = new Operand;
                *result = Operand(
                    classFieldAddress(*field),
                    ScalarType.ulong_,
                    true,
                    pointerElementScalar(address.type),
                );
                return result;
            } else
                return null;
        } else
            return null;

        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            isRefParameter ? Op.refParameterAddress : Op.frameAddress,
            pointer,
            slot,
        );
        auto result = new Operand;
        *result = Operand(
            pointer,
            ScalarType.ulong_,
            true,
            pointerElementScalar(address.type),
        );
        return result;
    }

    private Operand* tryAddressOfCaptured(
        VarDeclaration declaration,
        Type pointedType,
    ) {
        auto captured = declaration in _capturedOffsets;
        if (!_hasNestedContext || captured is null)
            return null;

        const sourceIndex = capturedFrameIndex(*captured);
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.frameIndexAddress, pointer, sourceIndex);
        auto result = new Operand;
        *result = Operand(
            pointer,
            ScalarType.ulong_,
            true,
            scalarType(pointedType),
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
        return Operand(result, ScalarType.ulong_, true, elementType);
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
        if (pointer.pointerElement == ScalarType.void_)
            return pointer;

        return loadThroughPointer(pointer, compileSizeConstant(0));
    }

    // `p[i]`: read the element at `p + i` through a pointer, yielding a scalar
    // operand of the pointed-at element type. Null if `p` is not a pointer.
    private Operand* tryPointerIndex(IndexExp index) {
        if (auto deref = index.e1.isPtrExp) {
            const pointer = compileExpression(deref.e1);
            if (!pointer.isPointer)
                return null;

            const indexSlot = compileExpression(index.e2);
            auto result = new Operand;
            *result = loadThroughPointer(pointer, indexSlot.offset);
            return result;
        }

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

        if (isComplexDoubleType(add.type) ||
            isComplexDoubleType(add.e1.type) ||
            isComplexDoubleType(add.e2.type) ||
            isImaginaryDoubleType(add.e1.type) ||
            isImaginaryDoubleType(add.e2.type))
            return compileComplexDoubleAdd(add);

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

        return compileInt4BinaryResult(
            add,
            lhs,
            rhs,
            Op.addInt4,
            scalarType(add.type),
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
            result, ScalarType.ulong_, true, pointer.pointerElement,
        );
    }

    private Operand compileComplexDoubleAdd(BinExp add) {
        const lhs = compileComplexDoubleOperand(add.e1);
        const rhs = compileComplexDoubleOperand(add.e2);
        const offset = allocateComplexDouble;
        _code ~= Instruction(Op.addDouble, offset, lhs.offset, rhs.offset);
        _code ~= Instruction(
            Op.addDouble,
            complexImaginaryOffset(offset),
            complexImaginaryOffset(lhs.offset),
            complexImaginaryOffset(rhs.offset),
        );
        return complexDoubleOperand(offset);
    }

    private Operand compileComplexDoubleOperand(Expression expression) {
        const value = compileExpression(expression);
        return value.isComplex ? value : complexDoubleFromReal(value);
    }

    private Operand complexDoubleFromReal(in Operand source) {
        Operand realPart;
        if (source.type == ScalarType.double_)
            realPart = source;
        else if (isCompoundIntegerScalar(source.type))
            realPart = convertIntegerToFloating(source, ScalarType.double_);
        else if (source.type == ScalarType.float_)
            realPart = convertFloating(source, ScalarType.double_);
        else
            throw new Exception("Unsupported cdouble operand in bytecode core");

        const offset = allocateComplexDouble;
        _code ~= Instruction(
            Op.copy,
            offset,
            realPart.offset,
            cast(ushort) double.sizeof,
        );
        _code ~= Instruction(
            Op.loadConstant,
            complexImaginaryOffset(offset),
            constantIndex(0),
            cast(ushort) double.sizeof,
        );
        return complexDoubleOperand(offset);
    }

    // D's `|` is integer-typed; the opcodes work on the raw bits, so signed
    // and unsigned operands of the same width share the same operation.
    private Operand compileOrExpression(OrExp or) {
        const lhs = compileExpression(or.e1);
        const rhs = compileExpression(or.e2);
        if (isEightByteInteger(lhs.type) &&
            isEightByteInteger(rhs.type))
            return emitBinary(Op.bitOrInt8, lhs, rhs, scalarType(or.type));

        return compileInt4BinaryResult(
            or,
            lhs,
            rhs,
            Op.bitOrInt4,
            scalarType(or.type),
            "Unsupported bitwise or in bytecode core: ",
        );
    }

    private Operand compileAndExpression(BinExp and) {
        const lhs = compileExpression(and.e1);
        const rhs = compileExpression(and.e2);
        if (isEightByteInteger(lhs.type) &&
            isEightByteInteger(rhs.type))
            return emitBinary(Op.bitAndInt8, lhs, rhs, scalarType(and.type));

        return compileInt4BinaryResult(
            and,
            lhs,
            rhs,
            Op.bitAndInt4,
            scalarType(and.type),
            "Unsupported bitwise and in bytecode core: ",
        );
    }

    private Operand compileXorExpression(BinExp xor) {
        const lhs = compileExpression(xor.e1);
        const rhs = compileExpression(xor.e2);
        return compileInt4BinaryResult(
            xor,
            lhs,
            rhs,
            Op.bitXorInt4,
            scalarType(xor.type),
            "Unsupported bitwise xor in bytecode core: ",
        );
    }

    // Integer multiplication. Pointer arithmetic scales its integer operand
    // through an 8-byte `cast(long)n * elementSize`, so the 8-byte form is the
    // one that matters here; the 4-byte form operates on raw bits like
    // `addInt4`, so signed and unsigned operands share it.
    private Operand compileMultiplyExpression(MulExp multiply) {
        import std.conv: text;

        const lhs = compileExpression(multiply.e1);
        const rhs = compileExpression(multiply.e2);
        if (isEightByteInteger(lhs.type) &&
            isEightByteInteger(rhs.type))
            return emitBinary(Op.mulInt8, lhs, rhs, lhs.type);

        return compileInt4BinaryResult(
            multiply,
            lhs,
            rhs,
            Op.mulInt4,
            scalarType(multiply.type),
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
        if (lhs.type == ScalarType.double_ && rhs.type == ScalarType.double_)
            return emitBinary(Op.divDouble, lhs, rhs, ScalarType.double_);
        if (lhs.type == ScalarType.ulong_ && rhs.type == ScalarType.ulong_)
            return emitBinary(
                Op.divUnsignedInt8, lhs, rhs, ScalarType.ulong_,
            );
        if (lhs.type == ScalarType.long_ && rhs.type == ScalarType.long_)
            return emitBinary(Op.divInt8, lhs, rhs, ScalarType.long_);
        if (lhs.type == ScalarType.uint_ && rhs.type == ScalarType.uint_)
            return emitBinary(
                Op.divUnsignedInt4, lhs, rhs, ScalarType.uint_,
            );

        return compileIntBinaryResult(
            divide,
            lhs,
            rhs,
            Op.divInt4,
            ScalarType.int_,
            "Unsupported division in bytecode core: ",
        );
    }

    private Operand compileModuloExpression(BinExp modulo) {
        const lhs = compileExpression(modulo.e1);
        const rhs = compileExpression(modulo.e2);
        if (lhs.type == ScalarType.ulong_ && rhs.type == ScalarType.ulong_)
            return emitBinary(
                Op.modUnsignedInt8, lhs, rhs, ScalarType.ulong_,
            );
        if (lhs.type == ScalarType.long_ && rhs.type == ScalarType.long_)
            return emitBinary(Op.modInt8, lhs, rhs, ScalarType.long_);
        if (lhs.type == ScalarType.uint_ && rhs.type == ScalarType.uint_)
            return emitBinary(
                Op.modUnsignedInt4, lhs, rhs, ScalarType.uint_,
            );

        return compileIntBinaryResult(
            modulo,
            lhs,
            rhs,
            Op.modInt4,
            ScalarType.int_,
            "Unsupported modulo in bytecode core: ",
        );
    }

    // `x /= y` and `x %= y` on an integer local. Unlike add/sub/mul/shift/or's
    // compound-assign, which reuse one op4/op8 pair regardless of signedness
    // because two's-complement addition and multiplication don't care about
    // sign, division and modulo need the operation's own signedness to pick
    // the opcode, matching the choice `compileDivideExpression`/
    // `compileModuloExpression` make for the binary form. That signedness is
    // not always the lvalue's: DMD performs the division at the usual-
    // arithmetic-conversion type of the two operands and only converts back
    // to the lvalue's type on store, so e.g. `int x; uint u; x /= u;` divides
    // as unsigned even though `x` is signed. DMD exposes that operation type
    // by wrapping `e1` in a `CastExp` to it whenever it differs from the
    // lvalue's declared type (`compoundAssignLocalDeclaration` unwraps that
    // same cast to find the lvalue); reading `assign.e1.type` therefore gives
    // the operation type directly.
    private Operand compileDivOrModCompoundAssign(
        BinExp assign,
        in bool isModulo,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        auto declaration = compoundAssignLocalDeclaration(assign.e1);
        auto slot = compoundAssignLocalSlot(declaration);
        if (slot is null)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const lvalueType = scalarType(declaration.type);
        const rhs = compileExpression(assign.e2);
        if (!isCompoundIntegerScalar(lvalueType) ||
            !isCompoundIntegerScalar(rhs.type))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        if (isEightByteInteger(lvalueType) != isEightByteInteger(rhs.type) ||
            (isEightByteInteger(lvalueType) && rhs.type != lvalueType))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const operationType = scalarType(assign.e1.type);
        if (!isIntegerScalar(operationType))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        Op op;
        if (operationType == ScalarType.ulong_)
            op = isModulo ? Op.modUnsignedInt8 : Op.divUnsignedInt8;
        else if (operationType == ScalarType.long_)
            op = isModulo ? Op.modInt8 : Op.divInt8;
        else if (operationType == ScalarType.uint_)
            op = isModulo ? Op.modUnsignedInt4 : Op.divUnsignedInt4;
        else
            op = isModulo ? Op.modInt4 : Op.divInt4;

        const lhs = integerOperationOperand(
            Operand(*slot, lvalueType),
            operationType,
        );
        const rhsValue = integerOperationOperand(rhs, operationType);
        const destination = size(lvalueType) == size(operationType)
            ? *slot
            : allocate(operationType);
        _code ~= Instruction(op, destination, lhs.offset, rhsValue.offset);
        if (destination != *slot)
            _code ~= Instruction(
                Op.copy,
                *slot,
                destination,
                cast(ushort) size(lvalueType),
            );

        return Operand(*slot, lvalueType);
    }

    private Operand compileShiftExpression(
        BinExp shift,
        in Op op,
        in string unsupportedMessage,
    ) {
        Operand lhs = compileExpression(shift.e1); // may promote narrow ints.
        Operand rhs = compileExpression(shift.e2); // may promote narrow ints.
        if (isEightByteInteger(lhs.type) &&
            isCompoundIntegerScalar(rhs.type) &&
            size(rhs.type) <= int.sizeof &&
            isEightByteInteger(scalarType(shift.type))) {
            if (size(rhs.type) < int.sizeof)
                rhs = extend(rhs, ScalarType.int_);
            const actualOp = op == Op.shrInt4
                ? (isSigned(lhs.type) ? Op.shrInt8 : Op.ushrInt8)
                : op == Op.ushrInt4 ? Op.ushrInt8 : Op.shlInt8;
            return emitBinary(actualOp, lhs, rhs, scalarType(shift.type));
        }
        const actualOp = op == Op.shrInt4 && !isSigned(lhs.type)
            ? Op.ushrInt4
            : op;
        return compileInt4BinaryResult(
            shift,
            lhs,
            rhs,
            actualOp,
            scalarType(shift.type),
            unsupportedMessage,
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
            result, ScalarType.ulong_, true, pointer.pointerElement,
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
        // Pointer relations `p < q` etc. compare raw `size_t` pointer values as
        // unsigned, matching compiled pointer code.
        if (isPointerType(comparison.e1.type) ||
            isPointerType(comparison.e2.type))
            return compilePointerComparison(comparison);

        Operand left = compileExpression(comparison.e1);
        Operand right = compileExpression(comparison.e2);
        const operandType = normaliseNumericOperands(
            left,
            right,
            comparison,
            "Unsupported comparison in bytecode core: ",
        );

        const op = isFloating(operandType)
            ? floatingComparisonOp(comparison.op, operandType)
            : integerComparisonOp(comparison.op, operandType);

        const offset = allocate(ScalarType.bool_);
        _code ~= Instruction(op, offset, left.offset, right.offset);
        return Operand(offset, ScalarType.bool_);
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
        const trueHasValue = hasValue(whenTrue);
        uint valueSize;
        if (trueHasValue) {
            valueSize = operandSize(whenTrue);
            _code ~= Instruction(
                Op.copy, result, whenTrue.offset, cast(ushort) valueSize,
            );
        }
        const endJump = emitJump;

        patchJump(falseJump);
        const whenFalse = compileExpression(conditional.e2);
        if (!trueHasValue)
            valueSize = operandSize(whenFalse);
        if (hasValue(whenFalse))
            _code ~= Instruction(
                Op.copy, result, whenFalse.offset, cast(ushort) valueSize,
            );
        patchJump(endJump);

        const typeSource = trueHasValue ? whenTrue : whenFalse;
        return Operand(
            result,
            typeSource.type,
            typeSource.isPointer,
            typeSource.pointerElement,
        );
    }

    private bool hasValue(in Operand operand) @safe @nogc nothrow pure {
        return operand.isPointer ||
            operand.isComplex ||
            operand.type != ScalarType.void_;
    }

    // The byte width an operand occupies in the frame: 8 for a pointer,
    // otherwise its scalar type's size.
    private uint operandSize(in Operand operand) @safe pure {
        if (operand.isComplex)
            return complexDoubleSize;
        if (operand.isPointer)
            return cast(uint) size_t.sizeof;
        return size(operand.type);
    }

    // Normalise an expression to a one-byte bool condition. Dynamic-array
    // truthiness (strings included — a `string` is just a `T[]`) is `ptr !is
    // null` (D's actual rule: a non-null zero-length slice is still true), so
    // the descriptor's pointer word — not its length — feeds
    // `compileTruthValue`'s pointer branch. `dynamicArrayDescriptorOrNull`
    // resolves a local, literal, struct field, or `.msg` directly to that
    // word's offset; any other shape (e.g. a conditional) is compiled first,
    // which for every `T[]`/string source yields the same {ptr, length}
    // descriptor at its result offset (`compileExpression`'s dynamic-array and
    // conditional-expression paths), so the pointer word is still at that
    // offset. Every other operand goes through `compileTruthValue` directly.
    private Operand compileBoolCondition(Expression expression) {
        if (isStringType(expression.type) || isDynamicArrayArgument(expression)) {
            if (auto descriptor = dynamicArrayDescriptorOrNull(expression))
                return compileTruthValue(
                    Operand(descriptor.offset, ScalarType.void_, true),
                );

            const array = compileExpression(expression);
            return compileTruthValue(
                Operand(array.offset, ScalarType.void_, true),
            );
        }

        return compileTruthValue(compileExpression(expression));
    }

    // An operand's truthiness is `operand != 0` over its own full width:
    // pointers compare at 8 bytes, integral types narrower than `int` widen
    // first so the comparison opcode's fixed read width matches the slot's
    // actual layout (mirrors `==`/`!=`'s operand preparation). A bool
    // operand is already canonical. A floating operand goes through
    // `compileFloatingTruthValue` (`operand != 0.0`); it cannot share this
    // path because its zero constant and comparison opcode are type-specific.
    private Operand compileTruthValue(Operand operand) {
        if (operand.type == ScalarType.bool_)
            return operand;
        if (isFloating(operand.type))
            return compileFloatingTruthValue(operand);
        if (!operand.isPointer && !isCompoundIntegerScalar(operand.type))
            return operand;

        if (!operand.isPointer && size(operand.type) < int.sizeof)
            operand = extend(
                operand,
                isSigned(operand.type) ? ScalarType.int_ : ScalarType.uint_,
            );

        const width = operand.isPointer
            ? size_t.sizeof : size(operand.type);
        const zero = allocateBytes(cast(uint) width, width);
        _code ~= Instruction(
            Op.loadConstant, zero, constantIndex(0), cast(ushort) width,
        );
        const result = allocate(ScalarType.bool_);
        const op = operand.isPointer
            ? Op.notEqual8 : comparisonNotEqualOp(operand.type);
        _code ~= Instruction(op, result, operand.offset, zero);
        return Operand(result, ScalarType.bool_);
    }

    // A `float`/`double` operand's truthiness is `operand != 0.0`, compared
    // against an all-zero-bits constant-pool entry (the IEEE-754 bit pattern
    // for 0.0) at the operand's own width via `comparisonNotEqualOp`'s
    // floating branch. `real_` cannot reuse that constant pool: its width
    // exceeds the pool's 8-byte `ulong` payload, so its zero goes through the
    // dedicated real-constant table and `Op.loadRealConstant`, matching how
    // `real` literals are already loaded.
    private Operand compileFloatingTruthValue(Operand operand) {
        const result = allocate(ScalarType.bool_);
        if (operand.type == ScalarType.real_) {
            const zero = allocate(ScalarType.real_);
            _code ~= Instruction(
                Op.loadRealConstant, zero, zeroRealConstantIndex,
            );
            _code ~= Instruction(Op.notEqualReal, result, operand.offset, zero);
            return Operand(result, ScalarType.bool_);
        }

        const width = size(operand.type);
        const zero = allocate(operand.type);
        _code ~= Instruction(
            Op.loadConstant, zero, constantIndex(0), cast(ushort) width,
        );
        _code ~= Instruction(
            comparisonNotEqualOp(operand.type), result, operand.offset, zero,
        );
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
        const lhs = compileBoolCondition(logical.e1);
        const shortCircuitJump = logical.op == EXP.andAnd
            ? emitJumpIfFalse(lhs)
            : emitJumpIfTrue(lhs);

        // The non-short-circuiting path evaluates rhs and normalises it.
        const rhs = compileBoolCondition(logical.e2);
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

        return compileInt4BinaryResult(
            subtract,
            lhs,
            rhs,
            Op.subInt4,
            scalarType(subtract.type),
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
        const source = compileBoolCondition(not.e1);
        const offset = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.notBool, offset, source.offset);
        return Operand(offset, ScalarType.bool_);
    }

    private Operand compileComplementExpression(Expression complement) {
        import std.conv: text;

        const source = compileExpression(complement.isComExp.e1);
        if (source.type != ScalarType.int_)
            throw new Exception(text(
                "Unsupported bitwise complement in bytecode core: ",
                expressionChars(complement),
            ));

        const offset = allocate(ScalarType.int_);
        _code ~= Instruction(Op.bitNotInt4, offset, source.offset);
        return Operand(offset, ScalarType.int_);
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
        if (auto index = compoundAssignIndex(addAssign.e1))
            if (auto element = tryDynamicArrayElementAddAssign(
                    index,
                    addAssign.e2,
                    scalarType(addAssign.e1.type),
                ))
                return *element;

        // `p.field += rhs` through a heap struct pointer: load the field, add the
        // rhs, and store the result back through the pointer.
        if (auto dot = compoundAssignDotVar(addAssign.e1))
            if (auto field = tryStructPointerField(dot)) {
                const current = loadStructPointerField(*field);
                const rhsValue = compileExpression(addAssign.e2);
                const lvalueType = scalarType(field.type);
                if (!isCompoundIntegerScalar(lvalueType) ||
                    !isCompoundIntegerScalar(rhsValue.type))
                    throw new Exception(text(
                        "Unsupported compound assignment in bytecode core: ",
                        expressionChars(addAssign),
                    ));

                if (isEightByteInteger(lvalueType) !=
                    isEightByteInteger(rhsValue.type))
                    throw new Exception(text(
                        "Unsupported compound assignment in bytecode core: ",
                        expressionChars(addAssign),
                    ));

                const operationType = isEightByteInteger(lvalueType)
                    ? lvalueType
                    : ScalarType.int_;
                const lhs = integerOperationOperand(current, operationType);
                const rhs = integerOperationOperand(rhsValue, operationType);
                const destination = size(lvalueType) == size(operationType)
                    ? current.offset
                    : allocate(operationType);
                const addOp = lvalueType == ScalarType.long_ ||
                    lvalueType == ScalarType.ulong_
                        ? Op.addInt8
                        : Op.addInt4;
                _code ~= Instruction(
                    addOp, destination, lhs.offset, rhs.offset,
                );
                storeStructPointerField(*field, destination);
                if (destination != current.offset)
                    _code ~= Instruction(
                        Op.copy,
                        current.offset,
                        destination,
                        cast(ushort) size(lvalueType),
                    );
                return Operand(current.offset, lvalueType);
            }

        // `p += n` on a local pointer variable (e.g. `Throwable.next`'s own
        // `++newTail`): DMD pre-scales `n` to a byte offset for pointer
        // arithmetic (see `compilePointerAdd`), so a plain 8-byte add into the
        // pointer's own slot advances it correctly.
        if (auto declaration = compoundAssignLocalDeclaration(addAssign.e1))
            if (auto element = declaration in _pointerLocals)
                if (auto slot = compoundAssignLocalSlot(declaration)) {
                    const rhs = compileExpression(addAssign.e2);
                    _code ~= Instruction(Op.addInt8, *slot, *slot, rhs.offset);
                    return Operand(*slot, ScalarType.ulong_, true, *element);
                }

        // `base.field += rhs` on an inline struct field (e.g. a `with (subject)`
        // body's `(*__withSym).field`): add into the field's own frame slot.
        if (auto dot = compoundAssignDotVar(addAssign.e1))
            if (auto field = tryStructField(dot)) {
                const lvalueType = scalarType(field.type);
                const rhsValue = compileExpression(addAssign.e2);
                if (!isCompoundIntegerScalar(lvalueType) ||
                    !isCompoundIntegerScalar(rhsValue.type))
                    throw new Exception(text(
                        "Unsupported compound assignment in bytecode core: ",
                        expressionChars(addAssign),
                    ));

                if (isEightByteInteger(lvalueType) !=
                    isEightByteInteger(rhsValue.type))
                    throw new Exception(text(
                        "Unsupported compound assignment in bytecode core: ",
                        expressionChars(addAssign),
                    ));

                const operationType = isEightByteInteger(lvalueType)
                    ? lvalueType
                    : ScalarType.int_;
                const lhs = integerOperationOperand(
                    Operand(field.offset, lvalueType),
                    operationType,
                );
                const rhs = integerOperationOperand(rhsValue, operationType);
                const destination = size(lvalueType) == size(operationType)
                    ? field.offset
                    : allocate(operationType);
                const addOp = lvalueType == ScalarType.long_ ||
                    lvalueType == ScalarType.ulong_
                        ? Op.addInt8
                        : Op.addInt4;
                _code ~= Instruction(
                    addOp, destination, lhs.offset, rhs.offset,
                );
                if (destination != field.offset)
                    _code ~= Instruction(
                        Op.copy,
                        field.offset,
                        destination,
                        cast(ushort) size(lvalueType),
                    );
                writeBackStructField(*field);
                return Operand(field.offset, lvalueType);
            }

        // `box.field += rhs` through a class reference (e.g. `Throwable.next`'s
        // `++tail._refcount`): load the field, add the rhs, and store the
        // result back through the class pointer. Tried only after the inline
        // struct-field case above, so a struct method's own `this.field += rhs`
        // (`this` is not a class reference there) is handled first.
        if (auto dot = compoundAssignDotVar(addAssign.e1))
            if (auto field = tryClassPointerField(dot)) {
                const current = loadClassPointerField(*field);
                const rhsValue = compileExpression(addAssign.e2);
                const lvalueType = scalarType(field.type);
                if (!isCompoundIntegerScalar(lvalueType) ||
                    !isCompoundIntegerScalar(rhsValue.type))
                    throw new Exception(text(
                        "Unsupported compound assignment in bytecode core: ",
                        expressionChars(addAssign),
                    ));

                if (isEightByteInteger(lvalueType) !=
                    isEightByteInteger(rhsValue.type))
                    throw new Exception(text(
                        "Unsupported compound assignment in bytecode core: ",
                        expressionChars(addAssign),
                    ));

                const operationType = isEightByteInteger(lvalueType)
                    ? lvalueType
                    : ScalarType.int_;
                const lhs = integerOperationOperand(current, operationType);
                const rhs = integerOperationOperand(rhsValue, operationType);
                const destination = size(lvalueType) == size(operationType)
                    ? current.offset
                    : allocate(operationType);
                const addOp = lvalueType == ScalarType.long_ ||
                    lvalueType == ScalarType.ulong_
                        ? Op.addInt8
                        : Op.addInt4;
                _code ~= Instruction(
                    addOp, destination, lhs.offset, rhs.offset,
                );
                storeClassPointerField(*field, destination);
                if (destination != current.offset)
                    _code ~= Instruction(
                        Op.copy,
                        current.offset,
                        destination,
                        cast(ushort) size(lvalueType),
                    );
                return Operand(current.offset, lvalueType);
            }

        // `++x`/`x += n` on an integer local: 4-byte and 8-byte integer widths
        // (size_t is ulong on x86-64, so `++len` lands here) share the lvalue's
        // own slot as the destination. Narrow integer locals promote for the
        // operation and copy only their storage width back, preserving wrapping.
        return compileLocalIntegerCompoundAssign(
            addAssign,
            Op.addInt4,
            Op.addInt8,
            "Unsupported compound assignment in bytecode core: ",
        );
    }

    private Operand compileLocalIntegerCompoundAssign(
        BinExp assign,
        in Op op4,
        in Op op8,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        auto declaration = compoundAssignLocalDeclaration(assign.e1);
        auto slot = compoundAssignLocalSlot(declaration);
        if (slot is null && _hasNestedContext && declaration !is null)
            if (auto captured = declaration in _capturedOffsets)
                return compileCapturedIntegerCompoundAssign(
                    declaration,
                    *captured,
                    assign,
                    op4,
                    op8,
                    unsupportedMessage,
                );
        if (slot is null)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const lvalueType = scalarType(declaration.type);
        const rhs = compileExpression(assign.e2);
        if (!isCompoundIntegerScalar(lvalueType) ||
            !isCompoundIntegerScalar(rhs.type))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const eightByteShift = op8 == Op.shlInt8 ||
            op8 == Op.shrInt8 || op8 == Op.ushrInt8;
        const lvalueIsEightByte = isEightByteInteger(lvalueType);
        const validRhs = lvalueIsEightByte
            ? eightByteShift
                ? size(rhs.type) <= int.sizeof
                : rhs.type == lvalueType
            : !isEightByteInteger(rhs.type);
        if (!validRhs || lvalueIsEightByte && op8 == op4)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const operationType = isEightByteInteger(lvalueType)
            ? lvalueType
            : ScalarType.int_;

        const lhs = integerOperationOperand(
            Operand(*slot, lvalueType),
            operationType,
        );
        const rhsValue = integerOperationOperand(
            rhs,
            isEightByteInteger(lvalueType) && eightByteShift
                ? ScalarType.int_
                : operationType,
        );
        const destination = size(lvalueType) == size(operationType)
            ? *slot
            : allocate(operationType);
        _code ~= Instruction(
            isEightByteInteger(operationType) ? op8 : op4,
            destination,
            lhs.offset,
            rhsValue.offset,
        );
        if (destination != *slot)
            _code ~= Instruction(
                Op.copy,
                *slot,
                destination,
                cast(ushort) size(lvalueType),
            );

        return Operand(*slot, lvalueType);
    }

    private ushort* compoundAssignLocalSlot(VarDeclaration declaration) {
        if (declaration is null)
            return null;
        if (auto slot = declaration in _locals)
            return slot;

        // Inline-asm semantic analysis can leave the surrounding expression
        // referring to the parameter declaration from the function type while
        // `FuncDeclaration.parameters` holds the materialised declaration.
        // Parameter names are unique within a signature, so reconcile those
        // two compiler-owned nodes by identifier.
        foreach (local, offset; _locals)
            if (local.ident is declaration.ident)
                return local in _locals;
        return null;
    }

    private Operand compileCapturedIntegerCompoundAssign(
        VarDeclaration declaration,
        in ushort capturedOffset,
        BinExp assign,
        in Op op4,
        in Op op8,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        const lvalueType = scalarType(declaration.type);
        const rhs = compileExpression(assign.e2);
        if (!isCompoundIntegerScalar(lvalueType) ||
            !isCompoundIntegerScalar(rhs.type))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        if (isEightByteInteger(lvalueType) != isEightByteInteger(rhs.type) ||
            (isEightByteInteger(lvalueType) &&
                (rhs.type != lvalueType || op8 == op4)))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const operationType = isEightByteInteger(lvalueType)
            ? lvalueType
            : ScalarType.int_;
        const current = loadCapturedLocal(declaration, capturedOffset);
        const lhs = integerOperationOperand(current, operationType);
        const rhsValue = integerOperationOperand(rhs, operationType);
        const destination = size(lvalueType) == size(operationType)
            ? current.offset
            : allocate(operationType);
        _code ~= Instruction(
            isEightByteInteger(operationType) ? op8 : op4,
            destination,
            lhs.offset,
            rhsValue.offset,
        );
        const stored = size(lvalueType) == size(operationType)
            ? Operand(destination, lvalueType)
            : Operand(destination, operationType);
        storeCapturedLocal(declaration, capturedOffset, stored);
        return loadCapturedLocal(declaration, capturedOffset);
    }

    private VarDeclaration compoundAssignLocalDeclaration(Expression lvalue) {
        if (auto cast_ = lvalue.isCastExp)
            return compoundAssignLocalDeclaration(cast_.e1);

        auto variable = lvalue.isVarExp;
        return variable is null ? null : variable.var.isVarDeclaration;
    }

    private DotVarExp compoundAssignDotVar(Expression lvalue) {
        if (auto cast_ = lvalue.isCastExp)
            return compoundAssignDotVar(cast_.e1);

        return lvalue.isDotVarExp;
    }

    private IndexExp compoundAssignIndex(Expression lvalue) {
        if (auto cast_ = lvalue.isCastExp)
            return compoundAssignIndex(cast_.e1);

        return lvalue.isIndexExp;
    }

    private Operand integerOperationOperand(
        in Operand operand,
        in ScalarType operationType,
    ) {
        if (operand.type == operationType ||
            size(operand.type) == size(operationType))
            return Operand(operand.offset, operationType);

        return extend(operand, operationType);
    }

    // `local = expr` for a scalar local lvalue (including a `ref` parameter's
    // slot): evaluate the right-hand side and copy it into the local's slot,
    // yielding the local as the assignment's result. Scoped to local-variable
    // lvalues with a matching scalar type; anything else is unsupported.
    private Operand compileAssignExpression(AssignExp assign) {
        import std.conv: text;

        if (auto registryAssign = tryStaticDelegateAssocArrayAssign(assign))
            return *registryAssign;

        // `ref T f(ref T value) { return value; }` used as an assignment
        // target: execute the callee first, then write through the original
        // argument slot rather than its copied callee-frame parameter.
        if (auto call = assign.e1.isCallExp)
            if (auto result = tryRefParameterCallAssign(call, assign.e2))
                return *result;

        // `arr.length = n`: resize the array in place, preserving existing
        // elements and zero-filling growth. Detected by the ArrayLengthExp
        // lvalue (DMD wraps this in a LoweredAssignExp), not a druntime name.
        if (auto length = assign.e1.isArrayLengthExp)
            return compileArrayLengthAssign(length, assign.e2);

        // A dynamic-array `*p = rhs` must copy the full descriptor before the
        // generic pointer-dereference path selects a scalar-width store.
        if (assign.e1.isPtrExp !is null &&
            isDynamicArrayArgument(assign.e1))
            if (auto descriptor = dynamicArrayDescriptorOrNull(assign.e1)) {
                compileDynamicArrayInto(
                    descriptor.offset,
                    descriptor.elementType,
                    assign.e2,
                    descriptor.elementIsArray,
                );
                writeBackDynamicArrayDescriptor(*descriptor);
                return Operand(descriptor.offset, ScalarType.void_);
            }

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

        // `arr[i] = rhs` for a static-array element: write the scalar rhs into
        // the element's inline frame offset.
        if (auto index = assign.e1.isIndexExp)
            if (auto element = tryStaticArrayElement(index))
                return compileStaticArrayElementAssign(*element, assign.e2);

        // `arr[i] = rhs` for a dynamic-array element: write the scalar rhs into
        // the heap element at `index`.
        if (auto index = assign.e1.isIndexExp)
            if (auto store = tryDynamicArrayElementAssign(index, assign.e2))
                return *store;

        // `m[i][j] = rhs` for a nested static-array element where a runtime
        // index appears anywhere in the chain: write through the
        // runtime-computed element address.
        if (auto index = assign.e1.isIndexExp)
            if (auto store =
                    tryStaticArrayRuntimeElementAssign(index, assign.e2))
                return *store;

        // `c.arr[i] = rhs` for a class static-array field element: the
        // class-field counterpart of the two static-array assignments above.
        if (auto index = assign.e1.isIndexExp)
            if (auto store =
                    tryClassStaticArrayFieldElementAssign(index, assign.e2))
                return *store;

        // `arr = rhs;` for a whole static-array-typed local -- including a
        // ref local aliased to one (`staticArrayOffsetOf` resolves both the
        // same way, per `_staticArrayLocals`): block-copy the new value into
        // the local's own frame storage rather than rebinding it. This is
        // the assignment counterpart of `compileStaticArrayDeclaration`'s
        // initializer handling.
        if (assign.e1.isVarExp !is null)
            if (auto offset = staticArrayOffsetOf(assign.e1))
                if (compileStaticArrayValueInto(
                        *offset, assign.e1.type, assign.e2))
                    return Operand(*offset, ScalarType.void_);

        // `matrix[] = [...]` broadcasts a one-dimensional row literal to each
        // row of a multidimensional static array in place.
        if (auto slice = assign.e1.isSliceExp)
            if (auto broadcast = tryStaticArrayBroadcast(slice, assign.e2))
                return *broadcast;

        // `arr[lo .. hi] = rhs` for a static array: write through a real
        // pointer into `arr`'s own frame storage instead of a throwaway heap
        // copy.
        if (auto slice = assign.e1.isSliceExp)
            if (auto store = tryStaticArraySliceAssign(slice, assign.e2))
                return *store;

        // `arr[lo .. hi] = rhs` for a dynamic array: copy the rhs elements into
        // the existing backing memory (write-through to the original array).
        if (auto slice = assign.e1.isSliceExp)
            if (auto copy = tryDynamicArraySliceAssign(slice, assign.e2))
                return *copy;

        // `c.arr[i].field = rhs` (or any nested-field depth): a class array
        // field's element storage lives on the class's own heap block, which
        // has no frame offset for `tryStructField`'s generic struct-field
        // path to fold into; `tryStructFieldAssign` below would resolve it
        // through `structBaseOffsetOrMaterialise`'s throwaway per-read copy
        // and silently discard the write. Checked first for the same reason
        // `tryAddressOfLocal` checks this case ahead of `tryStructField`.
        if (auto dot = assign.e1.isDotVarExp)
            if (auto element = tryClassArrayFieldElementFieldPointer(dot))
                return storeArrayElementFieldPointer(
                    element.pointer, element.type, assign.e2,
                );

        // `a[i].field = rhs` (or `a[i].outer.field = rhs`, any nesting
        // depth): the struct-field counterpart of the class case above --
        // an array-of-structs element's storage lives on the real heap even
        // when the array itself is a bare local or a struct's own slice
        // field, so the same throwaway-copy risk applies.
        if (auto dot = assign.e1.isDotVarExp)
            if (auto element = tryStructSliceFieldElementFieldPointer(dot))
                return storeArrayElementFieldPointer(
                    element.pointer, element.type, assign.e2,
                );

        // `base.field = rhs`: write into a struct field at its inline offset.
        if (auto dot = assign.e1.isDotVarExp)
            if (auto store = tryStructFieldAssign(dot, assign.e2))
                return *store;

        // `p.field = rhs` through a heap struct pointer: write the scalar rhs at
        // `ptr + field.offset`.
        if (auto dot = assign.e1.isDotVarExp)
            if (auto field = tryStructPointerField(dot)) {
                import dmd.astenums: TY;

                if (field.type.toBasetype.ty == TY.Tarray) {
                    const destination =
                        allocateBytes(sliceDescriptorSize, size_t.sizeof);
                    compileDynamicArrayInto(
                        destination,
                        dynamicArrayElementType(field.type),
                        assign.e2,
                    );
                    _code ~= Instruction(
                        Op.pointerStore16,
                        destination,
                        structFieldAddress(*field),
                        compileSizeConstant(0),
                    );
                    return Operand(destination, ScalarType.void_);
                }

                const value = compileExpression(assign.e2);
                storeStructPointerField(*field, value.offset);
                return Operand(value.offset, scalarType(field.type));
            }

        // `box.field = rhs` through a class reference: a dynamic-array field
        // (a `string` included) writes the full 16-byte descriptor; anything
        // else writes the scalar rhs at `class pointer + field.offset`.
        if (auto dot = assign.e1.isDotVarExp)
            if (auto field = tryClassPointerField(dot)) {
                import dmd.astenums: TY;

                if (field.type.toBasetype.ty == TY.Tarray) {
                    const destination =
                        allocateBytes(sliceDescriptorSize, size_t.sizeof);
                    compileDynamicArrayInto(
                        destination,
                        dynamicArrayElementType(field.type),
                        assign.e2,
                    );
                    _code ~= Instruction(
                        Op.pointerStore16,
                        destination,
                        classFieldAddress(*field),
                        compileSizeConstant(0),
                    );
                    return Operand(destination, ScalarType.void_);
                }

                const value = compileExpression(assign.e2);
                const fieldScalar = scalarType(field.type);
                if (value.type != fieldScalar)
                    throw new Exception(text(
                        "Unsupported assignment in bytecode core: ",
                        expressionChars(assign),
                    ));
                const fieldPointer = classFieldAddress(*field);
                _code ~= Instruction(
                    pointerStoreOp(size(fieldScalar)),
                    value.offset,
                    fieldPointer,
                    compileSizeConstant(0),
                );
                return Operand(value.offset, fieldScalar);
            }

        // A `string` local reassignment (`s = rhs;`) is a dynamic-array
        // reassignment like any other `T[]`: `isDynamicArrayArgument` itself
        // still excludes strings (a `string` is never a valid non-`VarExp`
        // assignment target anyway), so a `string`-typed `VarExp` lvalue is
        // admitted alongside it explicitly.
        if (isDynamicArrayArgument(assign.e1) ||
            (assign.e1.isVarExp !is null && isStringType(assign.e1.type)))
            if (auto descriptor = dynamicArrayDescriptorOrNull(assign.e1)) {
                compileDynamicArrayInto(
                    descriptor.offset,
                    descriptor.elementType,
                    assign.e2,
                    descriptor.elementIsArray,
                );
                writeBackDynamicArrayDescriptor(*descriptor);
                return Operand(descriptor.offset, ScalarType.void_);
            }

        auto variable = assign.e1.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        auto slot = declaration is null ? null : declaration in _locals;
        if (slot is null && _hasNestedContext && declaration !is null)
            if (auto captured = declaration in _capturedOffsets)
                return compileCapturedAssign(declaration, *captured, assign);
        if (declaration !is null)
            if (auto destination = declaration in _structLocals) {
                // DMD's zero-init blit marker (an `IntegerExp(0)` retyped to
                // the struct type, e.g. an `out` parameter's synthesized
                // entry zero-init) is not a struct value to read through
                // `structBaseOffsetOrMaterialise` -- it means "zero this
                // block", the same meaning `compileStructDeclaration` already
                // gives it for a fresh local's own initializer.
                if (auto integer = assign.e2.isIntegerExp)
                    if (integer.toInteger == 0) {
                        zeroFrameBlock(
                            destination.offset,
                            cast(uint) staticArraySize(declaration.type),
                        );
                        return Operand(destination.offset, ScalarType.void_);
                    }

                bool resolved;
                const source = structBaseOffsetOrMaterialise(
                    assign.e2,
                    resolved,
                );
                if (resolved) {
                    _code ~= Instruction(
                        Op.copy,
                        destination.offset,
                        source,
                        cast(ushort) staticArraySize(declaration.type),
                    );
                    return Operand(destination.offset, ScalarType.void_);
                }
            }
        if (slot !is null)
            if (auto element = declaration in _refLocalPointers)
                return storeThroughPointer(
                    Operand(
                        *slot,
                        ScalarType.ulong_,
                        true,
                        *element,
                    ),
                    compileSizeConstant(0),
                    assign.e2,
                );
        const type = slot is null
            ? ScalarType.void_
            : scalarType(declaration.type);
        const rhs = compileExpression(assign.e2);
        if (slot is null)
            if (auto moduleVariable =
                    moduleScalarVariableOrNull(declaration)) {
                if (rhs.type != moduleVariable.type)
                    throw new Exception(text(
                        "Unsupported assignment in bytecode core: ",
                        expressionChars(assign),
                    ));

                _code ~= Instruction(
                    Op.storeModule,
                    rhs.offset,
                    moduleVariable.offset,
                    cast(ushort) size(moduleVariable.type),
                );
                return rhs;
            }

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

    private Operand* tryRefParameterCallAssign(
        CallExp call,
        Expression rhs,
    ) {
        import std.conv: text;

        auto function_ = callFunction(call);
        auto type = function_ is null ? null : function_.type.isTypeFunction;
        if (type is null || !type.isRef)
            return null;

        if (auto result = tryMemberRefCallAssign(call, function_, rhs))
            return result;

        if (call.arguments is null)
            return null;

        auto returned = singleReturnExpression(function_.fbody);
        if (auto dereference = returned is null ? null : returned.isPtrExp)
            if (auto conditional = dereference.e1.isCondExp)
                return tryConditionalRefParameterCallAssign(
                    call,
                    function_,
                    conditional,
                    rhs,
                );
        auto variable = returned is null ? null : returned.isVarExp;
        auto parameter = variable is null ? null : variable.var.isVarDeclaration;
        if (parameter is null || !parameter.isReference)
            return null;

        auto parameterIndex = function_.parameters.length;
        foreach (index; 0 .. function_.parameters.length)
            if ((*function_.parameters)[index] is parameter) {
                parameterIndex = index;
                break;
            }
        if (parameterIndex >= call.arguments.length)
            return null;

        // Preserve ordinary call execution, including side effects and the
        // existing ref-parameter writeback, before storing through its caller
        // lvalue.
        compileCall(call);

        const destination = referenceOffset((*call.arguments)[parameterIndex]);
        const value = compileExpression(rhs);
        const scalar = scalarType(parameter.type);
        if (value.type != scalar)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(call),
            ));

        _code ~= Instruction(
            Op.copy, destination, value.offset, cast(ushort) size(scalar),
        );
        auto result = new Operand;
        *result = Operand(value.offset, scalar);
        return result;
    }

    private Operand* tryMemberRefCallAssign(
        CallExp call,
        FuncDeclaration function_,
        Expression rhs,
    ) {
        import std.conv: text;

        if (function_.vthis is null || call.e1.isDotVarExp is null)
            return null;

        if (auto result = tryConditionalMemberRefCallAssign(
                call, function_, rhs,
            ))
            return result;

        auto returned = provenFinalReturnExpression(function_.fbody);
        if (auto dereference = returned is null ? null : returned.isPtrExp)
            returned = dereference.e1;
        ushort* evaluatedReceiver;
        auto destination = memberReturnDestination(
            call,
            function_,
            returned,
            evaluatedReceiver,
        );
        if (destination is null)
            return null;

        const receiver = evaluatedReceiver is null
            ? null
            : new MethodReceiver(*evaluatedReceiver, 0, 0);
        compileCall(call, receiver);
        const value = compileExpression(rhs);
        const scalar = memberReturnScalar(returned);
        if (value.type != scalar)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(call),
            ));

        _code ~= Instruction(
            Op.copy,
            *destination,
            value.offset,
            cast(ushort) size(scalar),
        );
        auto result = new Operand;
        *result = Operand(value.offset, scalar);
        return result;
    }

    private Operand* tryConditionalMemberRefCallAssign(
        CallExp call,
        FuncDeclaration function_,
        Expression rhs,
    ) {
        import std.conv: text;

        auto statement = function_.fbody;
        while (statement !is null) {
            if (auto scope_ = statement.isScopeStatement) {
                statement = scope_.statement;
                continue;
            }
            auto wrapper = statement.isCompoundStatement;
            if (wrapper !is null && wrapper.statements !is null &&
                wrapper.statements.length == 1 &&
                ((*wrapper.statements)[0].isScopeStatement !is null ||
                    (*wrapper.statements)[0].isCompoundStatement !is null)) {
                statement = (*wrapper.statements)[0];
                continue;
            }
            break;
        }
        auto body = statement.isCompoundStatement;
        if (body is null || body.statements is null ||
            body.statements.length != 2)
            return null;

        auto conditional = (*body.statements)[0].isIfStatement;
        if (conditional is null || conditional.elsebody !is null)
            return null;
        auto conditionVariable = conditional.condition.isVarExp;
        auto conditionIndex = conditionVariable is null
            ? null
            : parameterIndex(
                function_, conditionVariable.var.isVarDeclaration,
            );
        auto whenTrue = singleReturnExpression(conditional.ifbody);
        auto whenFalse = singleReturnExpression((*body.statements)[1]);
        if (conditionIndex is null || *conditionIndex >= call.arguments.length)
            return null;

        auto condition = (*call.arguments)[*conditionIndex].isIntegerExp;
        if (condition is null)
            return null;
        auto selected = condition.toInteger == 0 ? whenFalse : whenTrue;
        ushort* evaluatedReceiver;
        auto destination = memberReturnDestination(
            call,
            function_,
            selected,
            evaluatedReceiver,
        );
        if (destination is null)
            return null;

        const receiver = evaluatedReceiver is null
            ? null
            : new MethodReceiver(*evaluatedReceiver, 0, 0);
        compileCall(call, receiver);
        const value = compileExpression(rhs);
        const scalar = memberReturnScalar(selected);
        if (value.type != scalar)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(call),
            ));

        _code ~= Instruction(
            Op.copy, *destination, value.offset, cast(ushort) size(scalar),
        );

        auto result = new Operand;
        *result = Operand(value.offset, scalar);
        return result;
    }

    private ushort* memberReturnDestination(
        CallExp call,
        FuncDeclaration function_,
        Expression returned,
        out ushort* evaluatedReceiver,
    ) {
        if (auto dereference = returned is null ? null : returned.isPtrExp)
            returned = dereference.e1;
        auto variable = returned is null ? null : returned.isVarExp;
        auto dot = returned is null ? null : returned.isDotVarExp;
        auto field = variable !is null
            ? variable.var.isVarDeclaration
            : dot is null ? null : dot.var.isVarDeclaration;
        if (field is null || !field.isField)
            return null;

        auto result = new ushort;
        if (dot is null || dot.e1.isThisExp !is null ||
            dot.e1.isSuperExp !is null) {
            evaluatedReceiver = new ushort;
            *evaluatedReceiver = methodReceiverOffset(call);
            *result = cast(ushort)
                (*evaluatedReceiver + field.offset);
            return result;
        }

        auto base = dot.e1.isVarExp;
        auto parameter = base is null ? null : base.var.isVarDeclaration;
        auto index = parameter is null || !parameter.isReference
            ? null
            : parameterIndex(function_, parameter);
        if (index is null || *index >= call.arguments.length)
            return null;
        *result = cast(ushort)
            (referenceOffset((*call.arguments)[*index]) + field.offset);
        return result;
    }

    private ScalarType memberReturnScalar(Expression returned) {
        if (auto dereference = returned is null ? null : returned.isPtrExp)
            returned = dereference.e1;
        auto variable = returned is null ? null : returned.isVarExp;
        auto dot = returned is null ? null : returned.isDotVarExp;
        auto field = variable !is null
            ? variable.var.isVarDeclaration
            : dot is null ? null : dot.var.isVarDeclaration;
        return scalarType(field.type);
    }

    private Operand* tryConditionalRefParameterCallAssign(
        CallExp call,
        FuncDeclaration function_,
        CondExp conditional,
        Expression rhs,
    ) {
        auto conditionParameter = conditional.econd.isVarExp;
        auto conditionIndex = conditionParameter is null
            ? null
            : parameterIndex(function_, conditionParameter.var.isVarDeclaration);
        auto trueIndex = refReturnParameterIndex(function_, conditional.e1);
        auto falseIndex = refReturnParameterIndex(function_, conditional.e2);
        if (conditionIndex is null || trueIndex is null || falseIndex is null ||
            *conditionIndex >= call.arguments.length ||
            *trueIndex >= call.arguments.length ||
            *falseIndex >= call.arguments.length ||
            (*call.arguments)[*conditionIndex].isIntegerExp is null)
            return null;

        compileCall(call);
        const condition = compileBoolCondition((*call.arguments)[*conditionIndex]);
        const value = compileExpression(rhs);
        const scalar = scalarType(conditional.type.nextOf);
        if (value.type != scalar)
            return null;

        const falseJump = emitJumpIfFalse(condition);
        _code ~= Instruction(
            Op.copy,
            referenceOffset((*call.arguments)[*trueIndex]),
            value.offset,
            cast(ushort) size(scalar),
        );
        const endJump = emitJump;
        patchJump(falseJump);
        _code ~= Instruction(
            Op.copy,
            referenceOffset((*call.arguments)[*falseIndex]),
            value.offset,
            cast(ushort) size(scalar),
        );
        patchJump(endJump);

        auto result = new Operand;
        *result = Operand(value.offset, scalar);
        return result;
    }

    private size_t* refReturnParameterIndex(
        FuncDeclaration function_,
        Expression expression,
    ) {
        if (auto address = expression.isAddrExp)
            expression = address.e1;
        if (auto variable = expression.isVarExp)
            return parameterIndex(function_, variable.var.isVarDeclaration);
        if (auto call = expression.isCallExp) {
            auto called = callFunction(call);
            auto returned = called is null
                ? null
                : singleReturnExpression(called.fbody);
            auto variable = returned is null ? null : returned.isVarExp;
            auto returnedParameter = variable is null
                ? null
                : parameterIndex(called, variable.var.isVarDeclaration);
            if (returnedParameter !is null && call.arguments !is null &&
                *returnedParameter < call.arguments.length)
                return refReturnParameterIndex(
                    function_,
                    (*call.arguments)[*returnedParameter],
                );
        }
        return null;
    }

    private size_t* parameterIndex(
        FuncDeclaration function_,
        VarDeclaration parameter,
    ) {
        if (parameter is null)
            return null;
        foreach (index; 0 .. function_.parameters.length)
            if ((*function_.parameters)[index] is parameter) {
                auto result = new size_t;
                *result = index;
                return result;
            }
        return null;
    }

    // `&refReturning(ref value)` must execute the callee, then point at the
    // caller lvalue the returned ref aliases. This narrow form handles a
    // direct return of one ref parameter.
    private Operand* tryAddressOfRefParameterCall(AddrExp address) {
        auto call = address.e1.isCallExp;
        auto function_ = call is null ? null : callFunction(call);
        auto type = function_ is null ? null : function_.type.isTypeFunction;
        if (type is null || !type.isRef || call.arguments is null)
            return null;

        auto returned = singleReturnExpression(function_.fbody);
        auto variable = returned is null ? null : returned.isVarExp;
        auto parameter = variable is null ? null : variable.var.isVarDeclaration;
        if (parameter is null || !parameter.isReference)
            return null;

        auto parameterIndex = function_.parameters.length;
        foreach (index; 0 .. function_.parameters.length)
            if ((*function_.parameters)[index] is parameter) {
                parameterIndex = index;
                break;
            }
        if (parameterIndex >= call.arguments.length)
            return null;

        compileCall(call);
        const slot = referenceOffset((*call.arguments)[parameterIndex]);
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.frameAddress, pointer, slot);
        auto result = new Operand;
        *result = Operand(
            pointer, ScalarType.ulong_, true, scalarType(parameter.type),
        );
        return result;
    }

    private Operand* tryStaticDelegateAssocArrayAssign(AssignExp assign) {
        auto declaration =
            staticDelegateAssocArrayAssignDeclaration(assign.e1);
        if (declaration is null)
            return null;

        auto delegate_ = delegateInitializer(assign.e2);
        if (delegate_.function_ is null)
            return null;

        _staticDelegateAssocArrays[declaration] = delegate_.function_;

        auto result = new Operand;
        *result = Operand.init;
        return result;
    }

    private VarDeclaration staticDelegateAssocArrayAssignDeclaration(
        Expression expression,
    ) {
        if (auto deref = expression.isPtrExp)
            return staticDelegateAssocArrayAssignDeclaration(deref.e1);

        if (auto index = expression.isIndexExp)
            return staticDelegateAssocArrayDeclaration(index.e1);

        if (auto call = expression.isCallExp) {
            auto function_ = callFunction(call);
            if (function_ !is null &&
                assocArrayHook(function_) == AssocArrayHook.getLvalue)
                return staticDelegateAssocArrayDeclaration(
                    (*call.arguments)[0],
                );
        }

        return null;
    }

    private Operand compileCapturedAssign(
        VarDeclaration declaration,
        in ushort capturedOffset,
        AssignExp assign,
    ) {
        import std.conv: text;

        const type = scalarType(declaration.type);
        const rhs = compileExpression(assign.e2);
        if (rhs.type != type)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(assign),
            ));

        storeCapturedLocal(declaration, capturedOffset, rhs);
        return loadCapturedLocal(declaration, capturedOffset);
    }

    private ModuleScalarVariable* moduleScalarVariableOrNull(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        import dmd.astenums: TY;

        if (declaration.type.toBasetype.ty == TY.Tarray ||
            declaration.type.toBasetype.ty == TY.Tsarray ||
            declaration.type.toBasetype.ty == TY.Taarray ||
            declaration.type.toBasetype.ty == TY.Tstruct ||
            declaration.type.toBasetype.ty == TY.Tdelegate ||
            isPointerType(declaration.type) ||
            isComplexDoubleType(declaration.type))
        {
            return null;
        }

        if (auto existing = declaration in _moduleScalarVariables)
            return existing;

        const isClassReference = declaration.type.toBasetype.ty == TY.Tclass;
        if (isClassReference &&
            !moduleVariableHasDefaultInitializer(declaration))
            return null;

        const type = isClassReference
            ? ScalarType.ulong_
            : scalarType(declaration.type);
        const initializer = isClassReference
            ? null
            : moduleScalarInitializerBytes(declaration, type);
        const offset = allocateModuleBytes(size(type), size(type));
        _moduleScalarVariables[declaration] = ModuleScalarVariable(
            offset,
            type,
            isClassReference,
        );
        _program.moduleData[offset .. offset + initializer.length] = initializer[];
        return declaration in _moduleScalarVariables;
    }

    // A module-level dynamic array (`byte[] a;`) reserves a plain 16-byte
    // native-order slice descriptor slot, the array counterpart of the
    // scalar allocation above; only the default (null) initializer is
    // supported so far, matching `moduleVariableHasDefaultInitializer`'s
    // class-reference use.
    private ModuleDynamicArrayVariable* moduleDynamicArrayVariableOrNull(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        import dmd.astenums: TY;

        if (declaration.type.toBasetype.ty != TY.Tarray)
            return null;

        if (auto existing = declaration in _moduleDynamicArrayVariables)
            return existing;

        if (!moduleVariableHasDefaultInitializer(declaration))
            return null;

        const elementType = dynamicArrayElementType(declaration.type);
        const elementIsArray = arrayElementIsArray(declaration.type);
        const offset = allocateModuleBytes(sliceDescriptorSize, size_t.sizeof);
        _moduleDynamicArrayVariables[declaration] = ModuleDynamicArrayVariable(
            offset,
            elementType,
            elementIsArray,
        );
        return declaration in _moduleDynamicArrayVariables;
    }

    // A module-level struct (`Point p;`) reserves `Type.size()` bytes at
    // `Type.alignsize()` in `_program.moduleData`, the struct counterpart of
    // `ModuleScalarVariable`/`ModuleDynamicArrayVariable`. Unlike those two,
    // field access does not resolve through this function's returned offset
    // directly: `tryStructField` materialises the whole block into a fresh
    // frame slot (`Op.loadModule`) and writes it back (`Op.storeModule`) after
    // any field write, the same pattern already used for a captured struct's
    // context-pointer indirection.
    private ModuleStructVariable* moduleStructVariableOrNull(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        import dmd.astenums: TY;

        if (declaration.type.toBasetype.ty != TY.Tstruct)
            return null;

        if (auto existing = declaration in _moduleStructVariables)
            return existing;

        if (!moduleVariableHasDefaultInitializer(declaration))
            return null;

        const size = cast(ushort) staticArraySize(declaration.type);
        const offset =
            allocateModuleBytes(size, staticArrayAlign(declaration.type));
        _moduleStructVariables[declaration] =
            ModuleStructVariable(offset, size);
        return declaration in _moduleStructVariables;
    }

    private bool moduleVariableHasDefaultInitializer(
        VarDeclaration declaration,
    ) {
        resolveNonRootInitializer(declaration);
        auto initializer = declaration._init is null
            ? null
            : declaration._init.isExpInitializer;
        return initializer is null ||
            initializerExpression(initializer.exp).isNullExp !is null;
    }

    private ubyte[] moduleScalarInitializerBytes(
        VarDeclaration declaration,
        in ScalarType type,
    ) {
        import std.bitmanip: nativeToLittleEndian;
        import std.conv: text;

        resolveNonRootInitializer(declaration);
        auto initializer = declaration._init is null
            ? null
            : declaration._init.isExpInitializer;
        if (initializer is null)
            return null;

        auto expression = initializerExpression(initializer.exp);
        if (auto integer = expression.isIntegerExp) {
            const bytes = nativeToLittleEndian(cast(ulong) integer.toInteger);
            return bytes[0 .. size(type)].dup;
        }

        if (auto real_ = expression.isRealExp) {
            if (type == ScalarType.real_)
                return realBytes(real_).dup;

            const bytes = nativeToLittleEndian(floatBits(real_, type));
            return bytes[0 .. size(type)].dup;
        }

        throw new Exception(text(
            "Unsupported module scalar initializer in bytecode core: ",
            declarationChars(declaration),
        ));
    }

    private void resolveNonRootInitializer(VarDeclaration declaration) {
        import dmd.dsymbol: PASS;

        if (declaration.semanticRun >= PASS.semantic2done)
            return;

        auto mod = declaration.getModule;
        if (mod is null)
            return;

        import dmd.dscope: Scope;
        import dmd.globals: global;
        import dmd.semantic2: semantic2;

        auto scope_ = Scope.createGlobal(mod, global.errorSink);
        semantic2(declaration, scope_);
        scope_ = scope_.pop;
        scope_.pop;
    }

    private ushort allocateModuleBytes(in uint bytes, in uint alignmentArgument)
        @safe pure
    {
        const alignment = alignmentArgument == 0 ? 1 : alignmentArgument;
        auto offset =
            cast(uint) ((_program.moduleData.length + alignment - 1) &
                ~(alignment - 1));
        if (offset > ushort.max)
            throw new Exception("Bytecode module data exceeds 16-bit offsets");

        const end = offset + bytes;
        if (end > ushort.max)
            throw new Exception("Bytecode module data exceeds 16-bit offsets");

        _program.moduleData.length = end;
        return cast(ushort) offset;
    }

    // Write `rhs` at the real runtime address `pointer`, the shared tail of
    // `tryClassArrayFieldElementFieldPointer` and
    // `tryStructSliceFieldElementFieldPointer`'s assignment use: a dynamic-
    // array field takes the rhs slice descriptor, matching
    // `tryClassPointerField`'s own assignment branch; anything else is a
    // scalar byte store at the pointer.
    private Operand storeArrayElementFieldPointer(
        in ushort pointer,
        Type fieldType,
        Expression rhs,
    ) {
        import dmd.astenums: TY;

        if (fieldType.toBasetype.ty == TY.Tarray) {
            const destination =
                allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileDynamicArrayInto(
                destination, dynamicArrayElementType(fieldType), rhs,
            );
            _code ~= Instruction(
                Op.pointerStore16, destination, pointer, compileSizeConstant(0),
            );
            return Operand(destination, ScalarType.void_);
        }

        const value = compileExpression(rhs);
        const fieldScalar = scalarType(fieldType);
        _code ~= Instruction(
            pointerStoreOp(size(fieldScalar)), value.offset, pointer,
            compileSizeConstant(0),
        );
        return Operand(value.offset, fieldScalar);
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

        if (field.type.toBasetype.ty == TY.Tarray) {
            compileDynamicArrayInto(
                field.offset, dynamicArrayElementType(field.type), rhs,
            );
            writeBackStructField(*field);
            auto descriptorResult = new Operand;
            *descriptorResult = Operand(field.offset, ScalarType.void_);
            return descriptorResult;
        }

        if (field.type.toBasetype.ty == TY.Tstruct) {
            const value = structOperandOffset(rhs);
            _code ~= Instruction(
                Op.copy,
                field.offset,
                value,
                cast(ushort) staticArraySize(field.type),
            );
            writeBackStructField(*field);
            auto structResult = new Operand;
            *structResult = Operand(field.offset, ScalarType.void_);
            return structResult;
        }

        // A static-array field `T[N] a` (`u.a = [x, y]`) writes each element
        // inline at `field.offset + index * elementSize`, the same as a
        // static-array local's own whole-array literal assignment.
        if (field.type.toBasetype.ty == TY.Tsarray) {
            if (auto literal = rhs.isArrayLiteralExp) {
                compileStaticArrayLiteral(field.offset, field.type, literal);
                writeBackStructField(*field);
                auto arrayResult = new Operand;
                *arrayResult = Operand(field.offset, ScalarType.void_);
                return arrayResult;
            }
        }

        // A pointer field `T* p` (`tracker.postblits = &count`) holds an 8-byte
        // raw address; copy the rhs pointer value into the field slot.
        if (isPointerType(field.type)) {
            const value = compileExpression(rhs);
            _code ~= Instruction(
                Op.copy, field.offset, value.offset, cast(ushort) size_t.sizeof,
            );
            writeBackStructField(*field);
            auto pointerResult = new Operand;
            *pointerResult = Operand(
                field.offset, ScalarType.ulong_, true,
                pointerElementScalar(field.type),
            );
            return pointerResult;
        }

        const fieldScalar = scalarType(field.type);
        const value = compileExpression(rhs);
        _code ~= Instruction(
            Op.copy, field.offset, value.offset, cast(ushort) size(fieldScalar),
        );
        writeBackStructField(*field);
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
        import dmd.astenums: TY;
        import dmd.typesem: defaultInitLiteral;

        const descriptor = dynamicArrayDescriptor(length.e1);
        const lengthValue = compileExpression(newLength);
        const lengthSlot = allocate(ScalarType.ulong_);
        _code ~= Instruction(
            Op.copy,
            lengthSlot,
            lengthValue.offset,
            cast(ushort) size(lengthValue.type),
        );
        auto element = length.e1.type.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tstruct) {
            const elementSize = cast(uint) staticArraySize(element);
            const initBlock = allocateBytes(elementSize, staticArrayAlign(element));
            zeroFrameBlock(initBlock, elementSize);
            auto literal = element.toBasetype.isTypeStruct.defaultInitLiteral(
                length.loc,
            ).isStructLiteralExp;
            if (literal is null)
                throw new Exception("Unsupported struct array default initializer in bytecode core.");
            compileStructLiteralInto(initBlock, literal);
            _code ~= Instruction(
                Op.setArrayLengthFromTemplate,
                descriptor.offset,
                initBlock,
                lengthSlot,
                cast(ushort) elementSize,
            );
            writeBackDynamicArrayDescriptor(descriptor);
            return Operand(lengthSlot, ScalarType.ulong_);
        }

        _code ~= Instruction(
            Op.setArrayLength,
            descriptor.offset,
            packedFill(
                descriptor.elementType,
                dynamicArrayElementSize(length.e1.type, descriptor.elementType),
            ),
            lengthSlot,
        );
        writeBackDynamicArrayDescriptor(descriptor);
        return Operand(lengthSlot, ScalarType.ulong_);
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
        const elementSize =
            dynamicArrayElementSize(append.e1.type, descriptor.elementType);
        _code ~= Instruction(
            appendElementOp(elementSize),
            descriptor.offset,
            value.offset,
        );
        writeBackDynamicArrayDescriptor(descriptor);
        return Operand(descriptor.offset, descriptor.elementType);
    }

    // `arr ~= other`: concatenate both array descriptors into fresh backing
    // memory, then overwrite the local's descriptor with the result.
    private Operand compileConcatenationAssign(CatAssignExp concatenate) {
        const descriptor = dynamicArrayDescriptor(concatenate.e1);
        const right = arrayDescriptorOffset(
            descriptor.elementType, concatenate.e2,
        );
        const elementSize = dynamicArrayElementSize(
            concatenate.e1.type, descriptor.elementType,
        );
        _code ~= Instruction(
            concatArraysOp(elementSize),
            descriptor.offset,
            descriptor.offset,
            right,
        );
        writeBackDynamicArrayDescriptor(descriptor);
        return Operand(descriptor.offset, descriptor.elementType);
    }

    private void writeBackDynamicArrayDescriptor(
        in DynamicArrayLocal descriptor,
    ) {
        if (descriptor.writeBackThroughFrame)
            _code ~= Instruction(
                Op.frameStore,
                descriptor.offset,
                descriptor.frameIndexOffset,
                cast(ushort) sliceDescriptorSize,
            );

        if (descriptor.writeBackStructThroughFrame)
            _code ~= Instruction(
                Op.frameStore,
                descriptor.structOffset,
                descriptor.structFrameIndexOffset,
                descriptor.structSize,
            );

        if (descriptor.writeBackThroughModule)
            _code ~= Instruction(
                Op.storeModule,
                descriptor.offset,
                descriptor.moduleOffset,
                cast(ushort) sliceDescriptorSize,
            );

        if (!descriptor.writeBackThroughPointer)
            return;

        _code ~= Instruction(
            Op.pointerStore16,
            descriptor.offset,
            descriptor.pointerOffset,
            compileSizeConstant(0),
        );
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
        auto declaration =
            staticDelegateAssocArrayAssignDeclaration(deref);
        if (declaration !is null) {
            auto delegate_ = delegateInitializer(rhs);
            if (delegate_.function_ !is null) {
                _staticDelegateAssocArrays[declaration] = delegate_.function_;

                auto registryResult = new Operand;
                *registryResult = Operand.init;
                return registryResult;
            }
        }

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

    // `*p op= rhs` through an integer pointer: load the current element, run
    // the existing integer opcode, and store the result back through `p`.
    private Operand* tryPointerDereferenceIntegerCompoundAssign(
        PtrExp deref,
        Expression rhs,
        in Op op4,
        in Op op8,
    ) {
        import std.conv: text;

        const pointer = compileExpression(deref.e1);
        if (!pointer.isPointer)
            return null;

        const zero = compileSizeConstant(0);
        const current = loadThroughPointer(pointer, zero);
        const rhsValue = compileExpression(rhs);
        if (!isCompoundIntegerScalar(current.type) ||
            !isCompoundIntegerScalar(rhsValue.type) ||
            isEightByteInteger(current.type) !=
                isEightByteInteger(rhsValue.type) ||
            (isEightByteInteger(current.type) &&
                (rhsValue.type != current.type || op8 == op4)))
            throw new Exception(text(
                "Unsupported compound assignment in bytecode core: ",
                expressionChars(deref),
            ));

        const operationType = isEightByteInteger(current.type)
            ? current.type
            : ScalarType.int_;
        const lhs = integerOperationOperand(current, operationType);
        const rhsOperand = integerOperationOperand(rhsValue, operationType);
        const destination = size(current.type) == size(operationType)
            ? current.offset
            : allocate(operationType);
        const actualOp4 = op4 == Op.shrInt4 && !isSigned(current.type)
            ? Op.ushrInt4
            : op4;
        _code ~= Instruction(
            isEightByteInteger(operationType) ? op8 : actualOp4,
            destination,
            lhs.offset,
            rhsOperand.offset,
        );
        if (destination != current.offset)
            _code ~= Instruction(
                Op.copy,
                current.offset,
                destination,
                cast(ushort) size(current.type),
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

    // Write the rhs to `[pointer + index * size]`, the shared store for
    // `*p = v` and `p[i] = v`. A scalar pointee's width is the opcode type's
    // fixed size; a non-scalar pointee (struct, e.g. `S* p; *p = S(42);`)
    // has no opcode scalar type at all (`pointerElement` is `void_`), so its
    // width must come from DMD's own `Type.size()` for the value actually
    // being written, never guessed from the (absent) scalar type.
    private Operand storeThroughPointer(
        in Operand pointer,
        in ushort indexSlot,
        Expression rhs,
    ) {
        const value = compileExpression(rhs);
        const elementSize = pointer.pointerElement == ScalarType.void_
            ? cast(uint) staticArraySize(rhs.type)
            : size(pointer.pointerElement);
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
        import dmd.astenums: TY;

        auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
        if (descriptor is null)
            return null;

        // A static array indexed by a runtime (non-constant) index resolves
        // here as a descriptor materialised into a throwaway heap copy
        // (`compileStaticArrayAsDynamicInto`); writing through that copy would
        // never reach the real static-array storage. Write through a pointer
        // into the static array's own inline frame offset instead, the same
        // element address `tryPointerToElement` computes for `&arr[i]`.
        if (descriptor.isStaticArrayView) {
            const pointer =
                staticArrayViewElementPointer(*descriptor, index.e2, index.type);
            auto viewResult = new Operand;
            *viewResult =
                storeThroughPointer(pointer, compileSizeConstant(0), rhs);
            return viewResult;
        }

        // `outer[i] = row` where `outer`'s element is itself a static array
        // (`int[2][]`): the row is a separately heap-allocated inner array
        // (`tryPointerToElement`'s `elementIsArray` branch), so the whole-row
        // assignment must write through its existing `.ptr` field rather than
        // storing raw row bytes into `outer`'s own 16-byte-per-row backing
        // store; the latter both corrupts the stored row descriptor and
        // leaves any pointer taken into the row before this assignment
        // (`&outer[i]`) pointing at stale, unwritten memory.
        if (descriptor.elementIsArray &&
            index.type.toBasetype.ty == TY.Tsarray) {
            const savedDollarLength = _activeDollarLength;
            _activeDollarLength = sliceLengthSlot(*descriptor);
            const indexSlot = compileExpression(index.e2);
            _activeDollarLength = savedDollarLength;

            const pointer = Operand(
                innerArrayRowPointer(*descriptor, indexSlot.offset),
                ScalarType.ulong_, true, ScalarType.void_,
            );
            auto rowResult = new Operand;
            *rowResult =
                storeThroughPointer(pointer, compileSizeConstant(0), rhs);
            return rowResult;
        }

        const value = compileExpression(rhs);
        const savedDollarLength = _activeDollarLength;
        _activeDollarLength = sliceLengthSlot(*descriptor);
        const indexSlot = compileExpression(index.e2);
        _activeDollarLength = savedDollarLength;
        const elementSize =
            dynamicArrayElementSize(index.e1.type, descriptor.elementType);
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
        in ScalarType operationType,
    ) {
        import std.conv: text;

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
        if (!isCompoundIntegerScalar(elementType) ||
            !isCompoundIntegerScalar(rhsValue.type) ||
            !isCompoundIntegerScalar(operationType) ||
            isEightByteInteger(operationType) !=
                isEightByteInteger(rhsValue.type) ||
            (isEightByteInteger(operationType) &&
                rhsValue.type != operationType))
            throw new Exception(text(
                "Unsupported compound assignment in bytecode core: ",
                expressionChars(index),
            ));

        const lhs = integerOperationOperand(
            Operand(current, elementType), operationType,
        );
        const right = integerOperationOperand(rhsValue, operationType);
        const destination = elementSize == size(operationType)
            ? current
            : allocate(operationType);
        _code ~= Instruction(
            isEightByteInteger(operationType) ? Op.addInt8 : Op.addInt4,
            destination,
            lhs.offset,
            right.offset,
        );
        if (destination != current)
            _code ~= Instruction(
                Op.copy,
                current,
                destination,
                cast(ushort) elementSize,
            );

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
        const elementType = index.type.toBasetype.ty == TY.Tarray ||
            index.type.toBasetype.ty == TY.Tsarray ||
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
    // a known static-array local (so other index forms fall through), or a
    // nested index in the chain (`m[i][2]`'s `i`) is a runtime value that
    // `locateStaticArrayElement` cannot fold into a compile-time offset
    // (`tryStaticArrayRuntimeElementAssign` handles that case instead).
    private StaticArrayElement* tryStaticArrayElement(
        IndexExp index,
    ) {
        if (index.e2.isIntegerExp is null)
            return null;

        if (!indexesStaticArray(index.e1))
            return null;

        if (staticArrayChainNeedsRuntimeAddress(index))
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

        // A scalar element's width is the opcode type's fixed size; a
        // non-scalar element (struct, e.g. `S[2] arr; arr[1] = S(3, 4);`, or a
        // `string`, both `void_` at this point) has no opcode scalar type at
        // all, so its width comes from DMD's own `Type.size()` for the value
        // actually being written.
        const elementSize = element.type == ScalarType.void_
            ? cast(uint) staticArraySize(rhs.type)
            : size(element.type);
        _code ~= Instruction(
            Op.copy,
            element.offset,
            value.offset,
            cast(ushort) elementSize,
        );
        return Operand(element.offset, element.type);
    }

    // `matrix[] = [elem, elem+1]` or `buf[] = fillValue`: the whole-array
    // slice of a static array assigned a value whose type matches the
    // array's own element type — a row literal for a multidimensional array
    // (DMD's block slice-assign broadcast), or a plain scalar for a one-
    // dimensional array (e.g. DMD's default-init fill of an `out char[4]`
    // parameter, `buf[] = char.init`). Compile the row/value once into the
    // first element's storage, then copy it into each remaining element.
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

        // The rhs's type must match the array's element type for a block
        // broadcast; otherwise it is an element-wise assignment.
        auto elementType = declaration.type.toBasetype.nextOf;
        if (elementType is null ||
            rhs.type is null ||
            !sameType(rhs.type, elementType))
            return null;

        const rowSize = cast(uint) staticArraySize(elementType);
        if (auto literal = rhs.isArrayLiteralExp)
            compileStaticArrayLiteral(*slot, elementType, literal);
        else {
            const value = compileExpression(rhs);
            _code ~= Instruction(
                Op.copy, *slot, value.offset, cast(ushort) rowSize,
            );
        }

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

    // `arr[lo .. hi] = rhs` where `arr` is a static array and the rhs is
    // itself a slice: `arr` otherwise resolves through
    // `dynamicArrayDescriptorOrNull` into a throwaway heap copy
    // (`compileStaticArrayAsDynamicInto`), so writing the destination through
    // that descriptor would never reach `arr`'s real frame storage. Build the
    // destination directly from a real pointer into `arr`'s own memory
    // instead, the same way `tryDynamicArrayElementAssign` already does for a
    // single element (`staticArrayElementPointer`). Null if `slice.e1` is not
    // a static-array location, or its element isn't one of the widths
    // `sliceCopyOp` copies correctly (1 or 4 bytes; wider elements still need
    // general slice-copy support).
    private Operand* tryStaticArraySliceAssign(
        SliceExp slice,
        Expression rhs,
    ) {
        // `tryStaticArrayRuntimeAddress` resolves a `DotVarExp` to any
        // struct field's own frame offset, static array or not (e.g. a
        // `char*` field): guard with the same static-array type check
        // `tryStaticArrayRuntimeIndex`/`tryStaticArrayRuntimeElementAssign`
        // already require, or a non-array field's address would be
        // misread as if it were the field's own array storage.
        if (!indexesStaticArray(slice.e1))
            return null;

        auto base = tryStaticArrayRuntimeAddress(slice.e1);
        if (base is null)
            return null;

        if (arrayElementIsArray(slice.e1.type))
            return null;

        const elementType = dynamicArrayElementType(slice.e1.type);
        const elementSize = size(elementType);
        if (elementSize != 1 && elementSize != 4)
            return null;

        const length = staticArrayLength(slice.e1.type);
        const bounds = allocateBytes(2 * size_t.sizeof, size_t.sizeof);
        const lo = slice.lwr is null
            ? compileSizeConstant(0)
            : compileExpression(slice.lwr).offset;
        _code ~= Instruction(Op.copy, bounds, lo, cast(ushort) size_t.sizeof);
        const hi = slice.upr is null
            ? compileSizeConstant(length)
            : compileExpression(slice.upr).offset;
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (bounds + size_t.sizeof),
            hi,
            cast(ushort) size_t.sizeof,
        );

        // Bounds check `[lo .. hi]` against the array's own known length the
        // same way a dynamic-array sub-slice does (`Op.subSlice*`'s
        // `validateSubSlice`, matching compiled D's `RangeError` wording
        // byte for byte): build a throwaway {pointer, length} descriptor over
        // `base` and go through `subSliceOp` instead of the unchecked
        // `pointerSliceOp`, so an out-of-range bound throws instead of
        // silently writing past the array's frame storage.
        const sourceDescriptor =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, sourceDescriptor, base.offset, cast(ushort) size_t.sizeof,
        );
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (sourceDescriptor + size_t.sizeof),
            compileSizeConstant(length),
            cast(ushort) size_t.sizeof,
        );

        const destination = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            subSliceOp(elementSize), destination, sourceDescriptor, bounds,
        );

        if (elementSize == uint.sizeof &&
            rhs.type !is null &&
            rhs.type.toBasetype.isTypeBasic !is null) {
            const value = compileExpression(rhs);
            _code ~= Instruction(Op.sliceFill4, destination, value.offset);

            auto result = new Operand;
            *result = Operand.init;
            return result;
        }

        const source = compileSourceSlice(elementType, rhs);
        _code ~= Instruction(
            sliceCopyOp(elementSize),
            destination,
            source,
        );

        auto result = new Operand;
        *result = Operand.init;
        return result;
    }

    // `arr[lo .. hi] = rhs` or `p[lo .. hi] = rhs`: form the destination
    // sub-slice descriptor sharing the array or raw pointer's backing memory,
    // materialise the rhs into a source descriptor, and emit a write-through
    // element copy. Null if the slice target is neither shape.
    private Operand* tryDynamicArraySliceAssign(
        SliceExp slice,
        Expression rhs,
    ) {
        auto descriptor = dynamicArrayDescriptorOrNull(slice.e1);
        if (descriptor is null && !isPointerType(slice.e1.type))
            return null;

        const elementType = descriptor is null
            ? dynamicArrayElementType(slice.type)
            : descriptor.elementType;
        const destination = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileSliceInto(destination, elementType, slice);

        if (size(elementType) == uint.sizeof &&
            rhs.type !is null &&
            rhs.type.toBasetype.isTypeBasic !is null) {
            const value = compileExpression(rhs);
            _code ~= Instruction(Op.sliceFill4, destination, value.offset);

            auto result = new Operand;
            *result = Operand.init;
            return result;
        }

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
    // writing each element into its `index * elementSize` offset.
    private void compileStaticArrayLiteral(
        in ushort offset,
        Type arrayType,
        ArrayLiteralExp literal,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        if (literal.elements is null)
            throw new Exception(text(
                "Unsupported static array literal in bytecode core: ",
                expressionChars(literal),
            ));

        auto elementType = arrayType.toBasetype.nextOf;

        // A string element (`string[2]`) is checked before the general
        // Tarray case below, whose element basetype a string also matches:
        // each element must be a literal (`stringLiteralOf` throws
        // otherwise), expanded directly into the native {ptr, length}
        // descriptor its 16-byte slot holds, the same width every other
        // dynamic-array element uses.
        if (isStringType(elementType)) {
            const elementSize = cast(uint) staticArraySize(elementType);
            foreach (elementIndex; 0 .. literal.elements.length) {
                auto string_ = stringLiteralOf((*literal.elements)[elementIndex]);
                if (string_ is null)
                    throw new Exception(text(
                        "Unsupported static array literal element in bytecode core: ",
                        expressionChars(literal),
                    ));

                emitLoadStringLiteral(
                    cast(ushort) (offset + elementIndex * elementSize), string_,
                );
            }
            return;
        }

        if (elementType.toBasetype.ty == TY.Tarray) {
            foreach (elementIndex; 0 .. literal.elements.length) {
                const value = compileExpression(
                    (*literal.elements)[elementIndex],
                );
                _code ~= Instruction(
                    Op.copy,
                    cast(ushort) (offset +
                        elementIndex * sliceDescriptorSize),
                    value.offset,
                    cast(ushort) sliceDescriptorSize,
                );
            }
            return;
        }

        // A nested static-array element (`float[1][1]`) recurses one level
        // down: each element is itself an array literal at its own leaf
        // offset.
        if (elementType.toBasetype.ty == TY.Tsarray) {
            const elementSize = cast(uint) staticArraySize(elementType);
            foreach (elementIndex; 0 .. literal.elements.length) {
                auto element = (*literal.elements)[elementIndex];
                auto nested =
                    arrayLiteralOf(element is null ? literal.basis : element);
                if (nested is null)
                    throw new Exception(text(
                        "Unsupported static array literal element in bytecode core: ",
                        expressionChars(literal),
                    ));

                compileStaticArrayLiteral(
                    cast(ushort) (offset + elementIndex * elementSize),
                    elementType,
                    nested,
                );
            }
            return;
        }

        // A struct element (`Payload[1]`) recurses into its own fields at
        // their own leaf offsets, reusing the same machinery a plain struct
        // field uses.
        if (elementType.toBasetype.ty == TY.Tstruct) {
            const elementSize = cast(uint) staticArraySize(elementType);
            foreach (elementIndex; 0 .. literal.elements.length) {
                auto element = (*literal.elements)[elementIndex];
                auto structLiteral =
                    (element is null ? literal.basis : element)
                        .isStructLiteralExp;
                if (structLiteral is null)
                    throw new Exception(text(
                        "Unsupported static array literal element in bytecode core: ",
                        expressionChars(literal),
                    ));

                compileStructLiteralInto(
                    cast(ushort) (offset + elementIndex * elementSize),
                    structLiteral,
                );
            }
            return;
        }

        const elementScalar = scalarType(elementType);
        const elementSize = cast(uint) size(elementScalar);

        foreach (elementIndex; 0 .. literal.elements.length) {
            auto element = (*literal.elements)[elementIndex];
            const value = compileExpression(
                element is null ? literal.basis : element,
            );
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
        import dmd.astenums: TY;

        if (auto cast_ = expression.isCastExp)
            return staticArrayOffsetOf(cast_.e1);

        if (auto vectorArray = expression.isVectorArrayExp)
            return staticArrayOffsetOf(vectorArray.e1);

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declaration in _staticArrayLocals)
                    return existing;

        if (auto dot = expression.isDotVarExp)
            if (auto field = tryStructField(dot))
                if (field.type.toBasetype.ty == TY.Tsarray)
                    return &field.offset;

        return null;
    }

    private ushort* staticArrayViewOffset(Expression expression) {
        if (auto cast_ = expression.isCastExp)
            return staticArrayViewOffset(cast_.e1);

        if (auto slice = expression.isSliceExp)
            if (slice.lwr is null && slice.upr is null)
                return staticArrayOffsetOf(slice.e1);

        return staticArrayOffsetOf(expression);
    }

    // The class-field counterpart of `staticArrayOffsetOf`: a static-array
    // field reached through a class pointer, or null if `expression` is not
    // one. Unlike a struct's static-array field (an inline frame offset
    // `staticArrayOffsetOf` folds at compile time), the field's storage
    // lives in the class's own heap block, so callers address it through
    // `classFieldAddress` (a real runtime pointer) instead.
    private ClassPointerField* classStaticArrayFieldOf(Expression expression) {
        import dmd.astenums: TY;

        if (auto cast_ = expression.isCastExp)
            return classStaticArrayFieldOf(cast_.e1);

        // The receiver's static type must already be a class before probing
        // further: `tryClassPointerField` unconditionally compiles `dot.e1`
        // to check whether it yields a pointer, which throws for a plain
        // struct local (structs are addressed through `_structLocals`, never
        // `compileExpression`) rather than simply failing to match.
        if (auto dot = expression.isDotVarExp)
            if (dot.e1.type !is null &&
                dot.e1.type.toBasetype.ty == TY.Tclass)
                if (auto field = tryClassPointerField(dot))
                    if (field.type.toBasetype.ty == TY.Tsarray)
                        return field;

        return null;
    }

    private ClassPointerField* classStaticArrayViewFieldOf(
        Expression expression,
    ) {
        if (auto cast_ = expression.isCastExp)
            return classStaticArrayViewFieldOf(cast_.e1);

        if (auto slice = expression.isSliceExp)
            if (slice.lwr is null && slice.upr is null)
                return classStaticArrayFieldOf(slice.e1);

        return classStaticArrayFieldOf(expression);
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

        if (equal.e1.type.toBasetype.ty == TY.Tstruct &&
            equal.e2.type.toBasetype.ty == TY.Tstruct)
            return compileStructIdentity(
                equal.e1.type,
                structOperandOffset(equal.e1),
                structOperandOffset(equal.e2),
                equal.op == EXP.notEqual,
            );

        const bothDynamicArrays = equal.e1.type.toBasetype.ty == TY.Tarray &&
            equal.e2.type.toBasetype.ty == TY.Tarray &&
            dynamicArrayElementType(equal.e1.type) ==
                dynamicArrayElementType(equal.e2.type);
        if (bothDynamicArrays) {
            const elementType = dynamicArrayElementType(equal.e1.type);
            const left =
                arrayDescriptorOffset(elementType, equal.e1);
            const right =
                arrayDescriptorOffset(elementType, equal.e2);
            const offset = allocate(ScalarType.bool_);
            _code ~= Instruction(
                sliceEqualOp(
                    dynamicArrayElementSize(equal.e1.type, elementType),
                ),
                offset,
                left,
                right,
            );
            if (equal.op == EXP.notEqual)
                _code ~= Instruction(Op.notBool, offset, offset);
            return Operand(offset, ScalarType.bool_);
        }

        auto lhs = compileExpression(equal.e1);
        auto rhs = compileExpression(equal.e2);
        if (isCharacterScalar(lhs.type) && isCharacterScalar(rhs.type)) {
            const offset = emitCharacterEquality(
                equal.op == EXP.notEqual ? "!=" : "==",
                lhs,
                rhs,
            );
            return Operand(offset, ScalarType.bool_);
        }

        const operandType = normaliseNumericOperands(
            lhs,
            rhs,
            equal,
            "Unsupported equality in bytecode core: ",
        );

        const op = equal.op == EXP.notEqual
            ? comparisonNotEqualOp(operandType)
            : comparisonEqualOp(operandType);
        const offset = allocate(ScalarType.bool_);
        _code ~= Instruction(op, offset, lhs.offset, rhs.offset);
        return Operand(offset, ScalarType.bool_);
    }

    private Operand compileIdentityExpression(IdentityExp identity) {
        import dmd.tokens: EXP;

        const lhs = compileExpression(identity.e1);
        const rhs = compileExpression(identity.e2);
        const op = identity.op == EXP.notIdentity
            ? Op.notEqual8
            : Op.equal8;
        const offset = allocate(ScalarType.bool_);
        _code ~= Instruction(op, offset, lhs.offset, rhs.offset);
        return Operand(offset, ScalarType.bool_);
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

    private Operand compileInt4BinaryResult(
        BinExp expression,
        Operand lhs,
        Operand rhs,
        in Op op,
        in ScalarType resultType,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        if (!isCompoundIntegerScalar(lhs.type) ||
            !isCompoundIntegerScalar(rhs.type) ||
            size(lhs.type) > int.sizeof ||
            size(rhs.type) > int.sizeof ||
            size(resultType) != int.sizeof)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(expression),
            ));

        if (size(lhs.type) < int.sizeof)
            lhs = extend(lhs, ScalarType.int_);
        if (size(rhs.type) < int.sizeof)
            rhs = extend(rhs, ScalarType.int_);

        const offset = allocate(resultType);
        _code ~= Instruction(op, offset, lhs.offset, rhs.offset);
        return Operand(offset, resultType);
    }

    private Operand extend(in Operand source, in ScalarType target) {
        // No single opcode spans a 1- or 2-byte source straight to an 8-byte
        // target (e.g. `cast(long) someBool`, or a pointer-arithmetic offset
        // scaled from a `bool`-returning call): widen through `int`/`uint`
        // first, keeping the source's own signedness for both hops.
        if (size(source.type) < int.sizeof && size(target) > int.sizeof) {
            const intermediate = isSigned(source.type)
                ? ScalarType.int_
                : ScalarType.uint_;
            return extend(extend(source, intermediate), target);
        }

        const offset = allocate(target);
        _code ~= Instruction(
            extendOp(size(source.type), size(target), isSigned(source.type)),
            offset,
            source.offset,
        );
        return Operand(offset, target);
    }

    private Operand compileCall(
        CallExp call,
        const MethodReceiver* evaluatedMethodReceiver = null,
        const size_t* evaluatedReferenceArgumentIndex = null,
        const ushort* evaluatedReferenceArgumentOffset = null,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        auto function_ = callFunction(call);

        if (function_ !is null)
            if (auto receiverAddress =
                    tryReceiverFieldAddressCall(call, function_))
                return *receiverAddress;

        if (auto expression = immediateLambdaReturn(call))
            return compileExpression(expression);

        if (auto registryCall = tryStaticDelegateAssocArrayCall(call))
            return *registryCall;

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

        if (function_ !is null && function_.ident !is null &&
            function_.ident.toString == "emplace")
            if (auto emplaced = compileEmplace(call))
                return *emplaced;

        if (function_ !is null && function_.ident !is null &&
            function_.ident.toString == "emplaceRef")
            if (auto emplaced = compileEmplaceRef(call))
                return *emplaced;

        if (function_ !is null && function_.ident !is null &&
            function_.ident.toString == "emplaceInitializer")
            return Operand.init;

        // `_d_arraybounds*` is the bounds-failure helper in DMD's `m[k]`
        // lowering (`slot ? slot : (_d_arraybounds(...), null)`); reaching it
        // means the key was absent, so raise the plain "Range violation".
        if (function_ !is null && isArrayBoundsCall(function_))
            return compileRangeViolation;

        if (function_ !is null && isNewArrayRuntimeCall(function_))
            return compileNewArrayRuntimeCall(call);

        if (function_ !is null)
            if (auto builtin = compileBuiltinCall(call, function_))
                return *builtin;

        if (function_ is null)
            if (auto lazyDelegate = lazyDelegateLocalOf(call))
                return compileLazyDelegateCall(*lazyDelegate, call);

        // `d()` through a delegate local: the callee is a VarExp of a delegate
        // local holding a `{functionIndex, context}` pair. Dispatch indirectly,
        // passing the context as the lambda's hidden `this` block.
        if (function_ is null)
            if (auto delegateLocal = delegateLocalOf(call))
                return compileDelegateCall(*delegateLocal, call);

        // `f()` through a delegate-typed PARAMETER: the callee's target is a
        // run-time value with no statically known `FuncDeclaration`, so the
        // call site builds its argument layout from the delegate's declared
        // type instead of a specific callee.
        if (function_ is null)
            if (auto offset = delegateParameterOffsetOf(call))
                return compileDynamicDelegateCall(*offset, call);

        // `fp()` through a function-pointer value: the callee is not a named
        // `FuncDeclaration` but a function-pointer expression. Dispatch through
        // the run-time index it holds.
        if (function_ is null && isFunctionPointerCall(call))
            return compileIndirectCall(call);

        if (function_ is null)
            throw new Exception(text(
                "Unsupported call in bytecode core: ",
                expressionChars(call),
            ));

        if (auto native = tryCompileNativeTypeInfoCall(call, function_))
            return *native;

        const layout = parameterLayout(function_);
        const isArchiveBacked = isArchiveBackedFunction(function_);
        // Neither path below is safe for a receiver-bearing archive-backed
        // method: `tryCompileNativeCall` never resolves a receiver, so a
        // struct method reaches the native call with no `this` argument at
        // all, and a class method (`layout.hasClassThis`, which skips the
        // native-call attempt below) falls through to `registerFunction`
        // and compiles the archive module's stale rewritten source body --
        // exactly what an archive-backed function's whole point is to never
        // do. Decline loudly rather than crash or run the wrong body.
        if (isArchiveBacked && (layout.hasThis || layout.hasClassThis))
            throw new Exception(text(
                "`",
                function_.ident is null
                    ? expressionChars(call)
                    : function_.ident.toString,
                "` is an archive-backed method: routing a receiver-bearing ",
                "call through the native bridge or its stale rewritten ",
                "source is unsupported",
            ));

        const isNativeLeaf = function_.fbody is null || isArchiveBacked;
        if (isNativeLeaf && !layout.hasClassThis)
            if (auto native = tryCompileNativeCall(call, function_, layout))
                return *native;

        if (isNativeLeaf && !layout.hasClassThis)
            throw new Exception(text(
                "`",
                function_.ident is null
                    ? expressionChars(call)
                    : function_.ident.toString,
                "` cannot be interpreted at compile time, ",
                "because it has no available source code",
            ));

        const index = registerFunction(function_);
        const argumentArea = allocateBytes(layout.blockSize, 8);
        Operand classReceiver;
        bool hasClassReceiver;
        MethodReceiver structReceiver;
        bool hasStructReceiver;

        // A struct method call `receiver.method(args)` passes the receiver as
        // the hidden `this` block (by reference) at the start of the argument
        // area: store the receiver's frame offset there, which the machine
        // dereferences on entry and writes back on return.
        if (layout.hasThis) {
            structReceiver = evaluatedMethodReceiver is null
                ? methodReceiver(call)
                : *evaluatedMethodReceiver;
            hasStructReceiver = true;
            _code ~= Instruction(
                Op.loadConstant,
                cast(ushort) (argumentArea + layout.thisOffset),
                constantIndex(structReceiver.offset),
                cast(ushort) size(ScalarType.uint_),
            );
        }

        if (layout.hasClassThis) {
            classReceiver = classMethodReceiver(call);
            hasClassReceiver = true;
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (argumentArea + layout.classThisOffset),
                classReceiver.offset,
                cast(ushort) size_t.sizeof,
            );
        }

        if (layout.hasNestedContext) {
            const context = cast(ushort)
                (argumentArea + layout.nestedContextOffset);
            _code ~= Instruction(Op.frameBaseIndex, context);
            const one = compileSizeConstant(1);
            _code ~= Instruction(Op.addInt8, context, context, one);
        }

        size_t nextArgumentIndex;
        if (!layout.hasThis && !layout.hasClassThis &&
            layout.offsets.length > 0)
            if (auto dot = call.e1.isDotVarExp)
                if (dot.e1.type.toBasetype.ty == TY.Tsarray &&
                    (call.arguments is null
                        ? 1
                        : call.arguments.length + 1) == layout.offsets.length)
                {
                    emitCallArgument(
                        cast(ushort) (argumentArea + layout.offsets[0]),
                        layout.isReference[0],
                        dot.e1,
                    );
                    nextArgumentIndex = 1;
                }

        DynamicArrayRefWriteBack[] dynamicArrayRefWriteBacks;
        StructPointerRefWriteBack[] structPointerRefWriteBacks;
        ClassFieldRefWriteBack[] classFieldRefWriteBacks;
        StructPointerFieldRefWriteBack[] structPointerFieldRefWriteBacks;
        ModuleScalarRefWriteBack[] moduleScalarRefWriteBacks;
        RefLocalPointerRefWriteBack[] refLocalPointerRefWriteBacks;
        PointerDereferenceRefWriteBack[] pointerDereferenceRefWriteBacks;
        if (call.arguments !is null &&
            nextArgumentIndex + call.arguments.length > layout.offsets.length)
            throw new Exception(text(
                "Missing bytecode parameter layout for call: ",
                expressionChars(call),
            ));

        if (call.arguments !is null)
            foreach (argumentIndex; 0 .. call.arguments.length) {
                const slot = cast(ushort)
                    (argumentArea +
                        layout.offsets[nextArgumentIndex + argumentIndex]);
                if (functionParameterIsLazy(
                        function_, nextArgumentIndex + argumentIndex)) {
                    emitLazyCallArgument(slot, (*call.arguments)[argumentIndex]);
                    continue;
                }
                if (layout.isReference[nextArgumentIndex + argumentIndex] &&
                    evaluatedReferenceArgumentIndex !is null &&
                    evaluatedReferenceArgumentOffset !is null &&
                    argumentIndex == *evaluatedReferenceArgumentIndex) {
                    _code ~= Instruction(
                        Op.loadConstant,
                        slot,
                        constantIndex(*evaluatedReferenceArgumentOffset),
                        cast(ushort) size(ScalarType.uint_),
                    );
                    continue;
                }
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitRefLocalPointerArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        refLocalPointerRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitPointerDereferenceRefArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        pointerDereferenceRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitRefReturnedDynamicArrayElementArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        dynamicArrayRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitDynamicArrayRefArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        dynamicArrayRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitStructPointerRefArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        structPointerRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitClassFieldRefArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        classFieldRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitStructPointerFieldRefArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        structPointerFieldRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitModuleScalarRefArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                        moduleScalarRefWriteBacks,
                    ))
                        continue;
                if (layout.isReference[nextArgumentIndex + argumentIndex])
                    if (emitConditionalRefArgument(
                        slot,
                        (*call.arguments)[argumentIndex],
                    ))
                        continue;
                emitCallArgument(
                    slot,
                    layout.isReference[nextArgumentIndex + argumentIndex],
                    (*call.arguments)[argumentIndex],
                );
            }

        const returnType = _program.functions[index].returnType;
        const destination =
            (!returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        if (hasClassReceiver) {
            const functionSlot = allocate(ScalarType.ulong_);
            _code ~= Instruction(
                Op.classVirtualFunction,
                functionSlot,
                classReceiver.offset,
                index,
            );
            _code ~= Instruction(
                Op.callIndirect, functionSlot, argumentArea, destination,
            );
        } else
            _code ~= Instruction(Op.call, index, argumentArea, destination);
        foreach (writeBack; dynamicArrayRefWriteBacks)
            _code ~= Instruction(
                indexStoreOp(writeBack.elementSize),
                writeBack.valueOffset,
                writeBack.descriptorOffset,
                writeBack.indexOffset,
            );
        foreach (writeBack; structPointerRefWriteBacks)
            _code ~= Instruction(
                pointerStoreOp(writeBack.valueSize),
                writeBack.valueOffset,
                writeBack.pointerOffset,
                compileSizeConstant(0),
            );
        foreach (writeBack; classFieldRefWriteBacks)
            _code ~= Instruction(
                pointerStoreOp(writeBack.valueSize),
                writeBack.valueOffset,
                writeBack.addressOffset,
                compileSizeConstant(0),
            );
        foreach (writeBack; structPointerFieldRefWriteBacks)
            _code ~= Instruction(
                pointerStoreOp(writeBack.valueSize),
                writeBack.valueOffset,
                writeBack.addressOffset,
                compileSizeConstant(0),
            );
        foreach (writeBack; refLocalPointerRefWriteBacks)
            _code ~= Instruction(
                pointerStoreOp(writeBack.valueSize),
                writeBack.valueOffset,
                writeBack.addressOffset,
                compileSizeConstant(0),
            );
        foreach (writeBack; pointerDereferenceRefWriteBacks)
            _code ~= Instruction(
                pointerStoreOp(writeBack.valueSize),
                writeBack.valueOffset,
                writeBack.addressOffset,
                compileSizeConstant(0),
            );
        foreach (writeBack; moduleScalarRefWriteBacks)
            _code ~= Instruction(
                Op.storeModule,
                writeBack.valueOffset,
                writeBack.moduleOffset,
                writeBack.valueSize,
            );
        if (hasStructReceiver && structReceiver.writeBackSize != 0)
            _code ~= Instruction(
                Op.frameStore,
                structReceiver.offset,
                structReceiver.writeBackFrameIndex,
                structReceiver.writeBackSize,
            );
        if (isPointerType(call.type))
            return Operand(
                destination, ScalarType.ulong_, true,
                pointerElementScalar(call.type),
            );
        // A class-typed return (e.g. `Throwable.next`'s getter, called from
        // its own setter as `auto n = next;`) yields a class reference, which
        // callers such as `compileClassPointerDeclaration` recognise only via
        // the pointer flag; the pointed-at class comes from the assignment
        // target's own declared type, not from this operand.
        if (call.type !is null && call.type.toBasetype.ty == TY.Tclass)
            return Operand(
                destination, ScalarType.ulong_, true, ScalarType.void_,
            );
        return Operand(destination, returnType.scalar);
    }

    // A function declared under an archive import path is defined by a
    // separately compiled archive already loaded into the process: its
    // parsed body (if any) is a source-rewrite artifact from parsing the
    // snippet's on-disk import, not the definition that actually runs.
    private bool isArchiveBackedFunction(FuncDeclaration function_) {
        import std.algorithm.searching: any, startsWith;
        import std.path: absolutePath, buildNormalizedPath, dirSeparator;

        if (_archiveImportPaths.length == 0)
            return false;

        auto module_ = function_.getModule;
        if (module_ is null)
            return false;

        const path =
            module_.srcfile.toString.idup.absolutePath.buildNormalizedPath;
        // Match whole path components: a bare prefix check would classify a
        // sibling directory like <root>-extra/ as under <root>.
        return _archiveImportPaths.any!((root) {
            const normalised = root.absolutePath.buildNormalizedPath;
            return path == normalised ||
                path.startsWith(normalised ~ dirSeparator);
        });
    }

    // A null return always falls through to the call site's unconditional
    // no-available-source throw, never a different path, so it is safe to
    // emit earlier arguments before a later one turns out unsupported.
    private Operand* tryCompileNativeCall(
        CallExp call,
        FuncDeclaration function_,
        in ParameterLayout layout,
    ) {
        import dmd.astenums: TY;

        const returnTy = function_.type.toBasetype.nextOf.toBasetype.ty;
        if (returnTy != TY.Tbool &&
            returnTy != TY.Tint32 && returnTy != TY.Tint64 &&
            returnTy != TY.Tuns64 &&
            returnTy != TY.Tfloat64 && returnTy != TY.Tvoid &&
            returnTy != TY.Tpointer && returnTy != TY.Tarray &&
            returnTy != TY.Tstruct)
            return null;

        // `call.arguments` is null, not merely empty, for a no-argument call.
        const argumentCount = call.arguments is null ? 0 : call.arguments.length;
        const argumentArea = allocateNativeArgumentArea(argumentCount);
        auto argumentTypes = new Type[argumentCount];
        auto outParameterOffsets = new ushort[argumentCount];
        // Every argument must be a scalar `int`/`long`/`size_t`, a
        // string-literal `const(char)*`, a `&local` out parameter, or a
        // pointer local passed by value; any other shape bails.
        foreach (index; 0 .. argumentCount) {
            auto argument = (*call.arguments)[index];
            const slot = cast(ushort)
                (argumentArea + index * nativeArgumentSlotSize);
            argumentTypes[index] = argument.type.toBasetype;
            outParameterOffsets[index] = noOutParameterOffset;

            const argumentTy = argument.type.toBasetype.ty;
            if (argumentTy == TY.Tint32 || argumentTy == TY.Tint64 ||
                argumentTy == TY.Tuns64) {
                emitCallArgument(slot, false, argument);
                continue;
            }

            if (argumentTy == TY.Tpointer &&
                argument.type.toBasetype.nextOf.toBasetype.ty == TY.Tchar) {
                auto string_ = stringLiteralOf(argument);
                if (string_ is null)
                    emitCallArgument(slot, false, argument);
                else
                    emitStringLiteralArgument(slot, string_);
                continue;
            }

            // A pointer local passed by value (e.g. `free(ptr)`): distinct
            // from the `&local` out-parameter shape below, which records a
            // frame offset for writeback; this copies the local's own value
            // (a native-memory address) into the argument slot.
            if (argumentTy == TY.Tpointer) {
                auto pointerVariable = argument.isVarExp;
                auto pointerDeclaration = pointerVariable is null
                    ? null
                    : pointerVariable.var.isVarDeclaration;
                if (pointerDeclaration !is null &&
                    (pointerDeclaration in _pointerLocals) !is null) {
                    emitCallArgument(slot, false, argument);
                    continue;
                }
            }

            // A `null` literal argument (e.g. `free(null)`) keeps its own
            // `typeof(null)` static type, not the declared pointer type
            // (compilePointerDeclaration's `= null` finding applies here
            // too); take the pointer type from the callee's own parameter
            // instead, and emit a zero pointer value into its slot.
            if (argument.isNullExp !is null) {
                auto parameterList =
                    function_.type.toBasetype.isTypeFunction.parameterList;
                auto parameter = parameterList[index];
                // A defaulted `const TypeInfo ti = null` parameter (the
                // common shape of every `core.memory.GC.*` leaf) has a class
                // reference type, which is pointer-sized and crosses the FFI
                // bridge the same way a raw pointer does.
                if (parameter is null ||
                    (parameter.type.toBasetype.ty != TY.Tpointer &&
                     parameter.type.toBasetype.ty != TY.Tclass))
                    return null;
                argumentTypes[index] = parameter.type.toBasetype;
                _code ~= Instruction(
                    Op.loadConstant, slot, constantIndex(0),
                    cast(ushort) size_t.sizeof,
                );
                continue;
            }

            // `&local` out parameter: `SymOffExp` (as `tryAddressOfSymbol`
            // also matches), zero offset, tracked pointer local. Slot is
            // never read (ffi.md §34.8: type is unconditionally an out
            // parameter); only the frame offset is recorded.
            emitCallArgument(slot, false, argument);
            auto outLocal = addressOfLocalOffset(argument);
            if (outLocal !is null)
                outParameterOffsets[index] = *outLocal;
        }

        return emitNativeCall(
            function_, argumentTypes, argumentArea, outParameterOffsets,
        );
    }

    // A VM class object is not an ABI class object, so ordinary VM method calls
    // must stay in bytecode. `typeid(classExpr)` is deliberately different: it
    // materialises the host TypeInfo mirror above, and its member calls can use
    // the FFI's existing native class-member ABI path.
    private Operand* tryCompileNativeTypeInfoCall(
        CallExp call,
        FuncDeclaration function_,
    ) {
        import dmd.astenums: TY;

        auto dot = call.e1.isDotVarExp;
        if (dot is null || dot.e1.isTypeidExp is null ||
            dot.e1.type is null)
            return null;

        auto receiverType = dot.e1.type.toBasetype.isTypeClass;
        if (receiverType is null)
            return null;

        // D evaluates the receiver before explicit arguments. `typeid(expr)`
        // normally only reads a class reference, but keep that ordering for a
        // receiver expression with side effects.
        const receiver = compileTypeidExpression(dot.e1.isTypeidExp);
        const argumentCount = call.arguments is null ? 0 : call.arguments.length;
        const argumentArea = allocateNativeArgumentArea(argumentCount);
        auto argumentTypes = new Type[argumentCount];
        auto outParameterOffsets = new ushort[argumentCount];
        foreach (index; 0 .. argumentCount) {
            auto argument = (*call.arguments)[index];
            if (argument.type is null)
                return null;
            const argumentTy = argument.type.toBasetype.ty;
            if (argumentTy != TY.Tclass && argumentTy != TY.Tbool &&
                argumentTy != TY.Tint32 && argumentTy != TY.Tint64 &&
                argumentTy != TY.Tuns64)
                return null;

            argumentTypes[index] = argument.type.toBasetype;
            outParameterOffsets[index] = noOutParameterOffset;
            emitCallArgument(
                cast(ushort) (argumentArea + index * nativeArgumentSlotSize),
                false,
                argument,
            );
        }

        return emitNativeCall(
            function_,
            argumentTypes,
            argumentArea,
            outParameterOffsets,
            receiver.offset,
            receiverType,
        );
    }

    private ushort* addressOfLocalOffset(Expression argument) {
        auto target = argument;
        while (auto cast_ = target.isCastExp)
            target = cast_.e1;

        if (auto symOff = target.isSymOffExp) {
            if (symOff.offset != 0)
                return null;
            auto declaration = symOff.var.isVarDeclaration;
            return declaration is null ? null : declaration in _locals;
        }

        auto address = target.isAddrExp;
        if (address is null)
            return null;

        target = address.e1;
        while (auto cast_ = target.isCastExp)
            target = cast_.e1;

        auto variable = target.isVarExp;
        auto declaration = variable is null
            ? null
            : variable.var.isVarDeclaration;
        if (declaration is null)
            return null;
        if (auto local = declaration in _locals)
            return local;
        if (auto struct_ = declaration in _structLocals)
            return &struct_.offset;
        return null;
    }

    // Emit a string literal's bytes plus a NUL terminator into a fresh,
    // stable `literalBlocks` entry, and a `loadDataPointer` instruction
    // pointing `slot` at it. The NUL terminator is an FFI-marshalling
    // concern, not a representation property of the literal: an `extern(C)`
    // parameter expects a `const char*`, so the argument's backing bytes need
    // a terminator the callee can scan for, which a literal lets us bake in
    // up front instead of copying and appending one at the call site.
    private void emitStringLiteralArgument(in ushort slot, StringExp string_) {
        import quickbite.frontend.dmd.string_literals: stringChars;
        import std.conv: text;

        const bytes = cast(const(ubyte)[]) stringChars(string_);
        if (bytes.length + 1 > ushort.max)
            throw new Exception(text(
                "String literal too large for bytecode core: ",
                expressionChars(string_),
            ));
        _program.literalBlocks ~= bytes.dup ~ cast(ubyte) 0;
        const blockIndex = _program.literalBlocks.length - 1;
        if (blockIndex > ushort.max)
            throw new Exception(text(
                "Too many string literals for bytecode core: ",
                expressionChars(string_),
            ));
        _code ~= Instruction(Op.loadDataPointer, slot, cast(ushort) blockIndex);
    }

    // A native call's argument area is N contiguous fixed-stride slots (see
    // `nativeArgumentSlotSize` in program.d), one per argument, regardless of
    // each argument's own width: argument `index` always lives at
    // `argumentArea + index * nativeArgumentSlotSize`.
    private ushort allocateNativeArgumentArea(in size_t argumentCount)
        @safe pure
    {
        return allocateBytes(
            cast(uint) (argumentCount * nativeArgumentSlotSize),
            nativeArgumentSlotSize,
        );
    }

    // Emit the native-call table entry and instruction shared by every native
    // libc call shape: the argument bytes already live at `argumentArea`.
    private Operand* emitNativeCall(
        FuncDeclaration function_,
        Type[] argumentTypes,
        in ushort argumentArea,
        in ushort[] outParameterOffsets,
        in ushort nativeClassReceiverOffset = noOutParameterOffset,
        imported!"dmd.mtype".TypeClass nativeClassReceiverType = null,
    ) {
        import dmd.astenums: TY;

        // `auto`, not `const`: `pointerElementScalar` below needs a mutable
        // `Type` and DMD's `toBasetype`/`nextOf` are non-const methods.
        auto returnType = function_.type.toBasetype.nextOf;
        // A dynamic-array return (e.g. `gc_getArrayUsed`'s `void[]`) has no
        // scalar tag; it is a 16-byte {ptr, length} slice descriptor, the same
        // shape every other array-typed frame slot uses.
        const isArrayReturn = returnType.toBasetype.ty == TY.Tarray;
        // A struct return (e.g. `GC.qalloc`'s `BlkInfo`, libc's `div_t`) is an
        // inline block sized and aligned to the struct's own layout, the same
        // shape every other struct-by-value result uses
        // (`structBaseOffsetOrMaterialise`).
        const isStructReturn = returnType.toBasetype.ty == TY.Tstruct;
        const returnScalar = isArrayReturn || isStructReturn
            ? ScalarType.void_
            : scalarType(returnType.toBasetype);
        const destination = isStructReturn
            ? allocateBytes(
                cast(uint) staticArraySize(returnType),
                staticArrayAlign(returnType),
            )
            : isArrayReturn
                ? allocateBytes(sliceDescriptorSize, size_t.sizeof)
                : allocate(returnScalar);
        const nativeIndex = _program.nativeCalls.length;
        _program.nativeCalls ~=
            NativeCall(
                function_,
                argumentTypes,
                outParameterOffsets.dup,
                nativeClassReceiverOffset,
                nativeClassReceiverType,
            );
        _code ~= Instruction(
            Op.nativeCall,
            cast(ushort) nativeIndex,
            argumentArea,
            destination,
        );
        // A native-memory pointer return (e.g. `malloc`'s `void*`): mark the
        // operand as a pointer holding a raw host address, matching every
        // other pointer-valued operand's shape, so callers such as
        // `compilePointerDeclaration` and pointer comparisons treat it as one.
        if (returnType.toBasetype.ty == TY.Tpointer)
            return new Operand(
                destination, ScalarType.ulong_, true,
                pointerElementScalar(returnType),
            );
        return new Operand(destination, returnScalar);
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
        compileNestedStatement(literal.fd.fbody);
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

    // The frame offset of the delegate-typed PARAMETER invoked by `f(...)`,
    // or null if `call` is not a call through one. Unlike `delegateLocalOf`,
    // there is no known `FuncDeclaration` behind this slot.
    private ushort* delegateParameterOffsetOf(CallExp call) {
        auto variable = call.e1 is null ? null : call.e1.isVarExp;
        if (variable is null)
            return null;
        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            return null;
        return declaration in _delegateParameterLocals;
    }

    private LazyDelegateSource* lazyDelegateLocalOf(CallExp call) {
        if (call.arguments !is null && call.arguments.length != 0)
            return null;

        auto variable = call.e1 is null ? null : call.e1.isVarExp;
        if (variable is null)
            return null;
        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            return null;
        if (auto existing = declaration in _lazyDelegateLocals)
            return new LazyDelegateSource(*existing);
        if (declaration !in _lazyDelegateDeclarations)
            return null;
        if (auto captured = declaration in _capturedOffsets)
            return new LazyDelegateSource(*captured, true);
        return null;
    }

    private Operand compileLazyDelegateCall(
        in LazyDelegateSource source,
        CallExp call,
    ) {
        import std.conv: text;

        if (call.arguments !is null && call.arguments.length != 0)
            throw new Exception(text(
                "Unsupported lazy call arguments in bytecode core: ",
                expressionChars(call),
            ));

        const delegateOffset = source.isCaptured
            ? allocateBytes(delegateValueSize, size_t.sizeof)
            : source.offset;
        if (source.isCaptured)
            _code ~= Instruction(
                Op.frameLoad,
                delegateOffset,
                capturedFrameIndex(source.offset),
                cast(ushort) delegateValueSize,
            );

        const argumentArea = allocateBytes(
            cast(uint) size_t.sizeof, size_t.sizeof,
        );
        _code ~= Instruction(
            Op.copy,
            argumentArea,
            cast(ushort) (delegateOffset + size_t.sizeof),
            cast(ushort) size_t.sizeof,
        );

        const returnType = resultType(call.type);
        const destination =
            (!returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(
            Op.callIndirect, delegateOffset, argumentArea, destination,
        );
        return Operand(destination, returnType.scalar);
    }

    private void emitLazyCallArgument(
        in ushort destination,
        Expression argument,
    ) {
        import std.conv: text;

        if (auto variable = argument.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto source = declaration in _lazyDelegateLocals) {
                    _code ~= Instruction(
                        Op.copy, destination, *source,
                        cast(ushort) delegateValueSize,
                    );
                    return;
                }
                if (declaration in _lazyDelegateDeclarations) {
                    if (auto source = declaration in _capturedOffsets) {
                        _code ~= Instruction(
                            Op.frameLoad, destination,
                            capturedFrameIndex(*source),
                            cast(ushort) delegateValueSize,
                        );
                        return;
                    }
                }
            }

        auto delegate_ = lazyDelegateInitializer(argument);
        if (delegate_.function_ is null)
            throw new Exception(text(
                "Unsupported lazy argument in bytecode core: ",
                expressionChars(argument),
            ));
        emitDelegateValue(destination, delegate_.function_, delegate_.contextOffset);
    }

    private DelegateInitializer lazyDelegateInitializer(Expression initializer) {
        if (auto variable = initializer.isVarExp)
            if (auto function_ = variable.var.isFuncDeclaration)
                return DelegateInitializer(
                    function_, delegateContextOffset(function_, null),
                );

        return delegateInitializer(initializer);
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

        const layout = parameterLayout(delegateLocal.function_);
        const argumentArea = allocateBytes(layout.blockSize, 8);

        // Struct-member delegates store the receiver offset in the pair's
        // context word; the machine dereferences it as the hidden `this` block.
        if (layout.hasThis)
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (argumentArea + layout.thisOffset),
                cast(ushort) (delegateLocal.offset + size_t.sizeof),
                cast(ushort) size(ScalarType.uint_),
            );

        // Local-function delegates store the caller frame's base index in the
        // context word; captured locals load/store through that raw index.
        if (layout.hasNestedContext)
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (argumentArea + layout.nestedContextOffset),
                cast(ushort) (delegateLocal.offset + size_t.sizeof),
                cast(ushort) size_t.sizeof,
            );

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

        const index = registerFunction(delegateLocal.function_);
        const returnType = _program.functions[index].returnType;
        const destination =
            (!returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(
            Op.callIndirect, delegateLocal.offset, argumentArea, destination,
        );
        return Operand(destination, returnType.scalar);
    }

    // `f(...)` through a delegate-typed PARAMETER: the callee is a run-time
    // value, so there is no specific `FuncDeclaration` whose own frame layout
    // the argument area could be built from (as `compileDelegateCall` does
    // for a delegate local). Every callee reachable through a delegate VALUE
    // is either a struct method (a receiver-block context, not modelled
    // here), a class method, or a nested function/lambda -- the latter two
    // both carry a single pointer-sized context word at frame offset 0,
    // ahead of the declared parameters, matching the delegate pair's own
    // `context` word verbatim. Building the argument area from the declared
    // delegate type alone therefore lines up with the real callee's own
    // registered layout for those two shapes.
    private Operand compileDynamicDelegateCall(
        in ushort descriptorOffset,
        CallExp call,
    ) {
        import dmd.astenums: STC;

        auto functionType = call.e1.type.toBasetype.isTypeDelegate
            .next.toBasetype.isTypeFunction;

        ParameterLayout layout;
        layout.blockSize = cast(uint) size_t.sizeof;
        if (functionType.parameterList.parameters !is null)
            foreach (parameter; *functionType.parameterList.parameters) {
                const isReference = (parameter.storageClass &
                    (STC.ref_ | STC.out_ | STC.auto_)) != STC.none;
                appendParameterLayoutEntry(
                    layout, parameter.type, isReference,
                );
            }

        const argumentArea = allocateBytes(layout.blockSize, size_t.sizeof);
        _code ~= Instruction(
            Op.copy,
            argumentArea,
            cast(ushort) (descriptorOffset + size_t.sizeof),
            cast(ushort) size_t.sizeof,
        );

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

        const returnType = resultType(call.type);
        const destination =
            (!returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(
            Op.callIndirectDynamic, descriptorOffset, argumentArea, destination,
        );
        return Operand(destination, returnType.scalar);
    }

    private Operand* tryStaticDelegateAssocArrayCall(CallExp call) {
        import std.algorithm: startsWith;

        auto declaration =
            staticDelegateAssocArrayCallDeclaration(call.e1);
        if (declaration is null &&
            !expressionChars(call.e1).startsWith("childWriters["))
            return null;

        auto function_ = declaration is null
            ? null
            : declaration in _staticDelegateAssocArrays;
        auto target = function_ is null
            ? _latestStaticDelegateAssocArrayFunction
            : *function_;
        if (target is null)
            return null;

        const offset = allocateBytes(delegateValueSize, size_t.sizeof);
        emitDelegateValue(offset, target, compileSizeConstant(0));

        auto result = new Operand;
        *result = compileDelegateCall(DelegateLocal(offset, target), call);
        return result;
    }

    private VarDeclaration staticDelegateAssocArrayCallDeclaration(
        Expression expression,
    ) {
        if (auto deref = expression.isPtrExp)
            return staticDelegateAssocArrayCallDeclaration(deref.e1);

        if (auto index = expression.isIndexExp)
            return staticDelegateAssocArrayDeclaration(index.e1);

        if (auto call = expression.isCallExp) {
            auto function_ = callFunction(call);
            if (function_ !is null &&
                assocArrayHook(function_) == AssocArrayHook.getRvalue)
                return staticDelegateAssocArrayDeclaration(
                    (*call.arguments)[0],
                );
        }

        return null;
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
            (!returnType.isArray &&
                !returnType.isStruct &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        _code ~= Instruction(
            Op.callIndirect, pointer.offset, argumentArea, destination,
        );
        return Operand(destination, returnType.scalar);
    }

    private Operand* compileEmplace(CallExp call) {
        if (call.arguments is null || call.arguments.length < 2)
            return null;

        const destination = compileExpression((*call.arguments)[0]);
        if (!destination.isPointer)
            return null;

        const value = compileExpression((*call.arguments)[1]);
        _code ~= Instruction(
            pointerStoreOp(size(destination.pointerElement)),
            value.offset,
            destination.offset,
            compileSizeConstant(0),
        );

        auto result = new Operand;
        *result = destination;
        return result;
    }

    private Operand* compileEmplaceRef(CallExp call) {
        if (call.arguments is null || call.arguments.length == 0)
            return null;

        auto index = (*call.arguments)[0].isIndexExp;
        if (index is null)
            return null;

        if (call.arguments.length == 1) {
            auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
            if (descriptor is null || descriptor.elementType == ScalarType.void_)
                return null;

            const elementSize = dynamicArrayElementSize(
                index.e1.type, descriptor.elementType,
            );
            if (elementSize > ulong.sizeof)
                return null;

            const value = allocateBytes(elementSize, elementSize);
            _code ~= Instruction(
                Op.loadConstant,
                value,
                constantIndex(
                    descriptor.elementType == ScalarType.char_
                        ? char.init
                        : descriptor.elementType == ScalarType.wchar_
                            ? wchar.init
                            : 0,
                ),
                cast(ushort) elementSize,
            );
            const indexSlot = compileExpression(index.e2);
            _code ~= Instruction(
                indexStoreOp(elementSize),
                value,
                descriptor.offset,
                indexSlot.offset,
            );

            auto result = new Operand;
            *result = Operand(value, descriptor.elementType);
            return result;
        }

        if (index.type !is null &&
            index.type.toBasetype.isTypeStruct !is null)
        {
            auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
            if (descriptor is null)
                return null;

            const elementSize = dynamicArrayElementSize(
                index.e1.type, descriptor.elementType,
            );
            if (elementSize > ulong.sizeof)
                return null;

            if (call.arguments.length == 2) {
                bool sourceResolved;
                const source = structBaseOffsetOrMaterialise(
                    (*call.arguments)[1], sourceResolved,
                );
                if (!sourceResolved)
                    return null;

                const value = allocateStructBlock(index.type);
                _code ~= Instruction(
                    Op.copy,
                    value,
                    source,
                    cast(ushort) elementSize,
                );
                if (auto postblit = structDeclarationOf(index.type).postblit)
                    runStructMethod(value, postblit);

                const indexSlot = compileExpression(index.e2);
                _code ~= Instruction(
                    indexStoreOp(elementSize),
                    value,
                    descriptor.offset,
                    indexSlot.offset,
                );

                auto result = new Operand;
                *result = Operand(value, ScalarType.void_);
                return result;
            }

            auto constructor = structDeclarationOf(index.type).ctor
                .isFuncDeclaration;
            if (constructor is null)
                return null;

            const value = allocateStructBlock(index.type);
            zeroFrameBlock(value, elementSize);
            auto arguments = new Expressions(call.arguments.length - 1);
            foreach (argumentIndex; 0 .. arguments.length)
                (*arguments)[argumentIndex] =
                    (*call.arguments)[argumentIndex + 1];
            runConstructor(
                value,
                constructor,
                arguments,
            );

            const indexSlot = compileExpression(index.e2);
            _code ~= Instruction(
                indexStoreOp(elementSize),
                value,
                descriptor.offset,
                indexSlot.offset,
            );

            auto result = new Operand;
            *result = Operand(value, ScalarType.void_);
            return result;
        }

        if (auto stored =
                tryDynamicArrayElementAssign(index, (*call.arguments)[1]))
            return stored;

        return null;
    }

    private Operand compileNewArrayRuntimeCall(CallExp call) {
        import std.conv: text;

        if (call.arguments is null || call.arguments.length == 0 ||
            (!isDynamicArrayArgument(call) && !isStringType(call.type)))
            throw new Exception(text(
                "Unsupported new array runtime call in bytecode core: ",
                expressionChars(call),
            ));

        const length = compileExpression((*call.arguments)[0]);
        const elementType = dynamicArrayElementType(call.type);
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.allocArrayDynamic,
            offset,
            packedFill(elementType),
            length.offset,
        );
        return Operand(offset, ScalarType.void_);
    }

    private Expression immediateLambdaReturn(CallExp call) {
        auto literal = call.e1 is null ? null : call.e1.isFuncExp;
        if (literal is null ||
            literal.fd is null ||
            call.arguments !is null && call.arguments.length != 0)
            return null;

        return singleReturnExpression(literal.fd.fbody);
    }

    private Expression singleReturnExpression(Statement statement) {
        if (statement is null)
            return null;

        if (auto scope_ = statement.isScopeStatement)
            return singleReturnExpression(scope_.statement);

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements is null || compound.statements.length != 1)
                return null;
            return singleReturnExpression((*compound.statements)[0]);
        }

        if (auto return_ = statement.isReturnStatement)
            return return_.exp;

        return null;
    }

    private Expression provenFinalReturnExpression(Statement statement) {
        if (statement is null)
            return null;

        if (auto scope_ = statement.isScopeStatement)
            return provenFinalReturnExpression(scope_.statement);

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements is null || compound.statements.length == 0)
                return null;
            foreach (preceding; (*compound.statements)[
                    0 .. compound.statements.length - 1
                ])
                if (preceding !is null && preceding.isExpStatement is null &&
                    preceding.isDtorExpStatement is null)
                    return null;
            return provenFinalReturnExpression(
                (*compound.statements)[compound.statements.length - 1],
            );
        }

        if (auto return_ = statement.isReturnStatement)
            return return_.exp;

        return null;
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

        if (argument.type !is null &&
            argument.type.toBasetype.ty == TY.Tsarray) {
            auto source = staticArrayOffsetOf(argument);
            assert(source !is null);
            _code ~= Instruction(
                Op.copy,
                slot,
                *source,
                cast(ushort) staticArraySize(argument.type),
            );
            return;
        }

        if (argument.type !is null &&
            argument.type.toBasetype.ty == TY.Tdelegate) {
            const source = delegateOperandOffset(argument);
            _code ~= Instruction(
                Op.copy, slot, source, cast(ushort) delegateValueSize,
            );
            return;
        }

        if (isDynamicArrayArgument(argument) ||
            (argument.type !is null && isStringType(argument.type))) {
            // A static-array whole slice passed to a callee aliases its frame
            // storage. Keep the general materialisation path below for result
            // values, whose bytes must outlive this VM invocation.
            if (auto source = staticArrayViewOffset(argument)) {
                auto staticArray = argument;
                while (auto cast_ = staticArray.isCastExp)
                    staticArray = cast_.e1;
                if (auto slice = staticArray.isSliceExp)
                    staticArray = slice.e1;
                const element = staticArray.type.toBasetype.nextOf;
                const count = staticArraySize(staticArray.type) /
                    staticArraySize(cast(Type) element);
                _code ~= Instruction(Op.frameAddress, slot, *source);
                _code ~= Instruction(
                    Op.loadConstant,
                    cast(ushort) (slot + size_t.sizeof),
                    constantIndex(count),
                    cast(ushort) size_t.sizeof,
                );
                return;
            }

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

        const operand = compileExpression(argument);
        _code ~= Instruction(
            Op.copy,
            slot,
            operand.offset,
            cast(ushort) size(operand.type),
        );
    }

    // A scalar dynamic-array element has no caller-frame offset for the
    // ordinary ref-parameter machinery to pass. Copy it to a call-local slot,
    // let the callee's existing ref writeback update that slot, then store it
    // back to the same already-evaluated element after the call returns.
    private bool emitDynamicArrayRefArgument(
        in ushort slot,
        Expression argument,
        ref DynamicArrayRefWriteBack[] writeBacks,
    ) {
        auto index = argument.isIndexExp;
        if (index is null)
            return false;

        // A compile-time-constant index into a static array (`arr[1]`)
        // resolves to the element's own inline frame slot in `referenceOffset`
        // instead: `dynamicArrayDescriptorOrNull` below would still answer a
        // descriptor for it (`staticArrayOffsetOf`'s whole-array-viewed-as-
        // dynamic materialisation), but that descriptor is a fresh copy of
        // the array's bytes, not the array's own storage, so writing back
        // through it would never reach the caller's element.
        if (indexesStaticArray(index.e1))
            return false;

        auto descriptor = dynamicArrayDescriptorOrNull(index.e1);
        if (descriptor is null || descriptor.elementType == ScalarType.void_)
            return false;

        return emitDynamicArrayElementRefArgument(
            slot,
            *descriptor,
            index.e1.type,
            index.e2,
            writeBacks,
        );
    }

    // A `ref`-returning wrapper may expose one element of its by-value dynamic
    // array parameter. Run the wrapper for its checks and side effects, then
    // bind the outer ref argument to the corresponding caller descriptor.
    private bool emitRefReturnedDynamicArrayElementArgument(
        in ushort slot,
        Expression argument,
        ref DynamicArrayRefWriteBack[] writeBacks,
    ) {
        auto call = argument.isCallExp;
        auto function_ = call is null ? null : callFunction(call);
        auto type = function_ is null ? null : function_.type.isTypeFunction;
        if (type is null || !type.isRef || call.arguments is null)
            return false;

        auto returned = provenFinalReturnExpression(function_.fbody);
        auto index = returned is null ? null : returned.isIndexExp;
        auto variable = index is null ? null : index.e1.isVarExp;
        auto parameter = variable is null ? null : variable.var.isVarDeclaration;
        auto argumentIndex = parameterIndex(function_, parameter);
        if (argumentIndex is null || *argumentIndex >= call.arguments.length)
            return false;

        auto descriptor = dynamicArrayDescriptorOrNull(
            (*call.arguments)[*argumentIndex],
        );
        if (descriptor is null || descriptor.elementType == ScalarType.void_)
            return false;

        compileCall(call);
        return emitDynamicArrayElementRefArgument(
            slot,
            *descriptor,
            index.e1.type,
            index.e2,
            writeBacks,
        );
    }

    private bool emitDynamicArrayElementRefArgument(
        in ushort slot,
        in DynamicArrayLocal descriptor,
        Type arrayType,
        Expression index,
        ref DynamicArrayRefWriteBack[] writeBacks,
    ) {
        const elementSize = dynamicArrayElementSize(
            arrayType, descriptor.elementType,
        );
        if (elementSize > ulong.sizeof)
            return false;

        const indexOffset = compileExpression(index).offset;
        const valueOffset = allocateBytes(elementSize, elementSize);
        _code ~= Instruction(
            indexLoadOp(elementSize),
            valueOffset,
            descriptor.offset,
            indexOffset,
        );
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(valueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        writeBacks ~= DynamicArrayRefWriteBack(
            valueOffset,
            descriptor.offset,
            indexOffset,
            cast(ushort) elementSize,
        );
        return true;
    }

    private bool emitStructPointerRefArgument(
        in ushort slot,
        Expression argument,
        ref StructPointerRefWriteBack[] writeBacks,
    ) {
        auto variable = argument.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        if (declaration is null || declaration !in _structPointerLocals)
            return false;

        const pointerOffset = _locals[declaration];
        const valueSize = cast(ushort) staticArraySize(argument.type);
        foreach (writeBack; writeBacks)
            if (writeBack.pointerOffset == pointerOffset &&
                writeBack.valueSize == valueSize) {
                _code ~= Instruction(
                    Op.loadConstant,
                    slot,
                    constantIndex(writeBack.valueOffset),
                    cast(ushort) size(ScalarType.uint_),
                );
                return true;
            }

        const valueOffset = allocateBytes(valueSize, valueSize);
        _code ~= Instruction(
            pointerLoadOp(valueSize),
            valueOffset,
            pointerOffset,
            compileSizeConstant(0),
        );
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(valueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        writeBacks ~= StructPointerRefWriteBack(
            valueOffset, pointerOffset, valueSize,
        );
        return true;
    }

    private bool emitModuleScalarRefArgument(
        in ushort slot,
        Expression argument,
        ref ModuleScalarRefWriteBack[] writeBacks,
    ) {
        auto variable = argument.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        if (declaration is null)
            return false;

        auto moduleVariable = moduleScalarVariableOrNull(declaration);
        if (moduleVariable is null)
            return false;

        foreach (writeBack; writeBacks)
            if (writeBack.moduleOffset == moduleVariable.offset) {
                _code ~= Instruction(
                    Op.loadConstant,
                    slot,
                    constantIndex(writeBack.valueOffset),
                    cast(ushort) size(ScalarType.uint_),
                );
                return true;
            }

        const valueSize = cast(ushort) size(moduleVariable.type);
        const valueOffset = allocateBytes(valueSize, valueSize);
        _code ~= Instruction(
            Op.loadModule, valueOffset, moduleVariable.offset, valueSize,
        );
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(valueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        writeBacks ~= ModuleScalarRefWriteBack(
            valueOffset, moduleVariable.offset, valueSize,
        );
        return true;
    }

    // A ternary `ref` argument (`setTo(cond ? a : b, ...)`) is a legal D
    // lvalue whose branch is chosen at runtime, so unlike every other
    // composing shape above there is no single compile-time frame offset to
    // bind. DMD's `keepLvalue` semantic for a `ref`-bound conditional yields
    // `*(cond ? &a : &b)`, each branch folded to a `SymOffExp` by the same
    // `optimize.d` pass `referenceOffsetOrNull`'s `*&p` case documents; a bare
    // `cond ? a : b` is accepted too for any lvalue shape that reaches here
    // unwrapped. Both branches must already resolve to a real caller-frame
    // address; the ref slot is then filled with whichever branch's address
    // the runtime condition selects.
    private bool emitConditionalRefArgument(
        in ushort slot,
        Expression argument,
    ) {
        auto deref = argument.isPtrExp;
        auto conditional = deref is null
            ? argument.isCondExp
            : deref.e1.isCondExp;
        if (conditional is null)
            return false;

        auto trueOffset = conditionalBranchOffsetOrNull(conditional.e1);
        auto falseOffset = conditionalBranchOffsetOrNull(conditional.e2);
        if (trueOffset is null || falseOffset is null)
            return false;

        const condition = compileBoolCondition(conditional.econd);
        const falseJump = emitJumpIfFalse(condition);
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(*trueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        const endJump = emitJump;
        patchJump(falseJump);
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(*falseOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        patchJump(endJump);
        return true;
    }

    // One branch of a `ref`-bound conditional's `*(cond ? &a : &b)` shape:
    // unwrap the branch's own address-of before falling back to
    // `referenceOffsetOrNull` for the underlying lvalue.
    private ushort* conditionalBranchOffsetOrNull(Expression branch) {
        if (auto symOff = branch.isSymOffExp)
            return symOffsetOrNull(symOff);
        if (auto address = branch.isAddrExp)
            return referenceOffsetOrNull(address.e1);
        return referenceOffsetOrNull(branch);
    }

    // A `ref` argument bound to a scalar class field (`verify(c.value, ...)`):
    // mirror the field's current value into a fresh frame slot for the call,
    // matching `emitStructPointerRefArgument`'s pattern for a pointed-at
    // value with no caller-frame offset of its own. Two arguments reaching
    // the same field of the same receiver (matched by `pointerSlot` +
    // `fieldOffset`, both stable across repeated compiles of the same
    // receiver local) share one mirror slot, so the ordinary ref-argument
    // alias grouping (keyed on that shared slot) gives them one identity.
    // Aggregate-typed fields (struct/array) need their own inline or
    // descriptor-copy handling, not a scalar mirror, so this declines them.
    private bool emitClassFieldRefArgument(
        in ushort slot,
        Expression argument,
        ref ClassFieldRefWriteBack[] writeBacks,
    ) {
        import dmd.astenums: TY;

        auto dot = argument.isDotVarExp;
        if (dot is null ||
            dot.e1.type is null ||
            dot.e1.type.toBasetype.ty != TY.Tclass)
            return false;

        auto field = tryClassPointerField(dot);
        if (field is null)
            return false;

        const ty = field.type.toBasetype.ty;
        if (ty == TY.Tstruct || ty == TY.Tsarray || ty == TY.Tarray ||
            ty == TY.Taarray)
            return false;

        const valueSize = cast(ushort) size(scalarType(field.type));
        if (valueSize != 1 && valueSize != 4 && valueSize != 8)
            return false;

        foreach (writeBack; writeBacks)
            if (writeBack.pointerSlot == field.pointerSlot &&
                writeBack.fieldOffset == field.fieldOffset &&
                writeBack.valueSize == valueSize) {
                _code ~= Instruction(
                    Op.loadConstant,
                    slot,
                    constantIndex(writeBack.valueOffset),
                    cast(ushort) size(ScalarType.uint_),
                );
                return true;
            }

        const valueOffset = allocateBytes(valueSize, valueSize);
        const addressOffset = classFieldAddress(*field);
        _code ~= Instruction(
            pointerLoadOp(valueSize),
            valueOffset,
            addressOffset,
            compileSizeConstant(0),
        );
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(valueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        writeBacks ~= ClassFieldRefWriteBack(
            valueOffset,
            addressOffset,
            field.pointerSlot,
            field.fieldOffset,
            valueSize,
        );
        return true;
    }

    // The struct-pointer counterpart of `emitClassFieldRefArgument`: a scalar
    // `ref` argument reached through a struct pointer field
    // (`setTo(carrier.value, ...)`). `tryStructPointerField` resolves DMD's
    // `(*carrier).value` lowering back to the pointer's frame slot and the
    // field's byte offset; the field's heap storage has no caller-frame
    // offset of its own, so it needs the same mirror-into-a-fresh-slot and
    // writeback-through-the-real-address pattern as a class field.
    private bool emitStructPointerFieldRefArgument(
        in ushort slot,
        Expression argument,
        ref StructPointerFieldRefWriteBack[] writeBacks,
    ) {
        import dmd.astenums: TY;

        auto dot = argument.isDotVarExp;
        if (dot is null)
            return false;

        // `with (s) { ... value ... }` lowers an unqualified field to
        // `(*__withSym).value`, the same shape as a genuine struct-pointer
        // field, but `__withSym` aliases `s`'s own frame storage directly
        // (`_withDerefBases`) rather than a heap pointer. Mirroring it into a
        // copy here would give it a different storage identity than a direct
        // `s.value` argument to the same call, breaking their required
        // aliasing; decline so `referenceOffset`'s `_withDerefBases`-aware
        // path resolves it to the real frame offset instead.
        auto base = dot.e1;
        if (auto deref = base.isPtrExp)
            base = deref.e1;
        if (auto variable = base.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (declaration in _withDerefBases)
                    return false;

        auto field = tryStructPointerField(dot);
        if (field is null)
            return false;

        const ty = field.type.toBasetype.ty;
        if (ty == TY.Tstruct || ty == TY.Tsarray || ty == TY.Tarray ||
            ty == TY.Taarray)
            return false;

        const valueSize = cast(ushort) size(scalarType(field.type));
        if (valueSize != 1 && valueSize != 4 && valueSize != 8)
            return false;

        foreach (writeBack; writeBacks)
            if (writeBack.pointerSlot == field.pointerSlot &&
                writeBack.fieldOffset == field.fieldOffset &&
                writeBack.valueSize == valueSize) {
                _code ~= Instruction(
                    Op.loadConstant,
                    slot,
                    constantIndex(writeBack.valueOffset),
                    cast(ushort) size(ScalarType.uint_),
                );
                return true;
            }

        const valueOffset = allocateBytes(valueSize, valueSize);
        const addressOffset = structFieldAddress(*field);
        _code ~= Instruction(
            pointerLoadOp(valueSize),
            valueOffset,
            addressOffset,
            compileSizeConstant(0),
        );
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(valueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        writeBacks ~= StructPointerFieldRefWriteBack(
            valueOffset,
            addressOffset,
            field.pointerSlot,
            field.fieldOffset,
            valueSize,
        );
        return true;
    }

    // A `ref` argument that is itself a `ref`-local aliasing an array
    // element, a scalar class field, or a field reached through a class/
    // struct slice field's element (`_refLocalPointers`): the local's frame
    // slot holds that pointee's runtime address, computed once when the
    // local was declared, rather than the pointee's value. Passing the
    // local's own offset onward (the plain `_locals` path in
    // `referenceOffsetOrNull`) would bind the callee to the address bytes
    // themselves and let any writeback clobber the stored address instead of
    // the pointee, so this mirrors the field-reached-through-a-pointer
    // pattern above: read the current value through the address into a
    // fresh slot for the call, and write it back through that same address
    // afterward.
    private bool emitRefLocalPointerArgument(
        in ushort slot,
        Expression argument,
        ref RefLocalPointerRefWriteBack[] writeBacks,
    ) {
        auto variable = argument.isVarExp;
        if (variable is null)
            return false;

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            return false;

        auto element = declaration in _refLocalPointers;
        if (element is null)
            return false;

        auto existing = declaration in _locals;
        if (existing is null)
            return false;

        const valueSize = cast(ushort) size(*element);
        if (valueSize != 1 && valueSize != 4 && valueSize != 8)
            return false;

        const addressOffset = *existing;
        foreach (writeBack; writeBacks)
            if (writeBack.addressOffset == addressOffset &&
                writeBack.valueSize == valueSize) {
                _code ~= Instruction(
                    Op.loadConstant,
                    slot,
                    constantIndex(writeBack.valueOffset),
                    cast(ushort) size(ScalarType.uint_),
                );
                return true;
            }

        const valueOffset = allocateBytes(valueSize, valueSize);
        _code ~= Instruction(
            pointerLoadOp(valueSize),
            valueOffset,
            addressOffset,
            compileSizeConstant(0),
        );
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(valueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        writeBacks ~= RefLocalPointerRefWriteBack(
            valueOffset, addressOffset, valueSize,
        );
        return true;
    }

    // A `ref` argument that dereferences a genuine runtime pointer value
    // (`bump(*p)` where `p` is a plain pointer local/parameter/field holding
    // an address computed earlier): unlike `*&lvalue`, DMD does not fold this
    // shape into a `SymOffExp` the caller's own storage can be named by a
    // compile-time frame offset, so `referenceOffsetOrNull`'s fallback would
    // otherwise bind the callee to a fresh copy of the pointee instead of the
    // pointee itself. Mirrors `emitRefLocalPointerArgument`: read the current
    // value through the pointer into a fresh slot for the call, and write it
    // back through that same pointer afterward.
    private bool emitPointerDereferenceRefArgument(
        in ushort slot,
        Expression argument,
        ref PointerDereferenceRefWriteBack[] writeBacks,
    ) {
        auto deref = argument.isPtrExp;
        if (deref is null)
            return false;

        // `*&lvalue`: `referenceOffsetOrNull`'s `symOffsetOrNull` branch
        // already cancels the address-of and the dereference back to the
        // lvalue's own storage; that path needs no mirror-and-writeback.
        if (deref.e1.isSymOffExp !is null)
            return false;

        const pointer = compileExpression(deref.e1);
        if (!pointer.isPointer)
            return false;

        const valueSize = cast(ushort) size(pointer.pointerElement);
        if (valueSize != 1 && valueSize != 4 && valueSize != 8)
            return false;

        const addressOffset = pointer.offset;
        foreach (writeBack; writeBacks)
            if (writeBack.addressOffset == addressOffset &&
                writeBack.valueSize == valueSize) {
                _code ~= Instruction(
                    Op.loadConstant,
                    slot,
                    constantIndex(writeBack.valueOffset),
                    cast(ushort) size(ScalarType.uint_),
                );
                return true;
            }

        const valueOffset = allocateBytes(valueSize, valueSize);
        _code ~= Instruction(
            pointerLoadOp(valueSize),
            valueOffset,
            addressOffset,
            compileSizeConstant(0),
        );
        _code ~= Instruction(
            Op.loadConstant,
            slot,
            constantIndex(valueOffset),
            cast(ushort) size(ScalarType.uint_),
        );
        writeBacks ~= PointerDereferenceRefWriteBack(
            valueOffset, addressOffset, valueSize,
        );
        return true;
    }

    // Emit a throw of the plain "Range violation" message and yield a null
    // pointer operand, so the `m[k]` lowering's `(_d_arraybounds(...), null)`
    // false branch type-checks (the throw aborts before the null is used).
    private Operand compileRangeViolation() {
        const message = compileStringLiteralBytes("Range violation");
        _code ~= Instruction(
            Op.throwString, message, noExceptionClass, noCatchObjectField,
        );
        const offset =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        return Operand(
            offset, ScalarType.ulong_, true, ScalarType.int_,
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
                    offset, ScalarType.ulong_, true, ScalarType.int_,
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
                    offset, ScalarType.ulong_, true, ScalarType.int_,
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
                return compileAssocArraySlice(Op.aaKeys, handle, int.sizeof);

            case values:
                return compileAssocArraySlice(
                    Op.aaValues,
                    handle,
                    dynamicArrayElementSize(
                        call.type, dynamicArrayElementType(call.type),
                    ),
                );

            case apply2:
                return compileAssocArrayApply2(call, handle);
        }
    }

    // `m.keys` / `m.values`: a fresh `int[]` slice descriptor holding a copy of
    // the map's keys / values, rooted on the VM-owned heap.
    private Operand compileAssocArraySlice(
        in Op op,
        in ushort handle,
        in uint elementSize,
    ) {
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(op, offset, handle, cast(ushort) elementSize);
        return Operand(offset, ScalarType.int_);
    }

    // `_d_aaApply2(aa, dg)`: DMD's lowering of `foreach (key, value; aa)`.
    // Materialise insertion-ordered key/value slices from the VM-owned map and
    // inline the delegate body once per entry.
    private Operand compileAssocArrayApply2(
        CallExp call,
        in ushort handle,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        if (call.arguments is null || call.arguments.length != 2)
            throw new Exception(text(
                "Unsupported associative array foreach in bytecode core: ",
                expressionChars(call),
            ));

        auto literal = (*call.arguments)[1].isFuncExp;
        if (literal is null || literal.fd is null ||
            literal.fd.fbody is null ||
            literal.fd.parameters is null ||
            literal.fd.parameters.length != 2)
            throw new Exception(text(
                "Unsupported associative array foreach body in bytecode core: ",
                expressionChars(call),
            ));

        auto keyParameter = (*literal.fd.parameters)[0];
        auto valueParameter = (*literal.fd.parameters)[1];
        const valueElementSize = valueParameter.type.toBasetype.ty == TY.Tstruct
            ? cast(uint) staticArraySize(valueParameter.type)
            : size(scalarType(valueParameter.type));

        const keys = compileAssocArraySlice(Op.aaKeys, handle, int.sizeof);
        const values = compileAssocArraySlice(
            Op.aaValues, handle, valueElementSize,
        );

        const keySlot = allocate(ScalarType.int_);
        _locals[keyParameter] = keySlot;

        const valueSlot = allocateBytes(
            valueElementSize,
            valueParameter.type.toBasetype.ty == TY.Tstruct
                ? staticArrayAlign(valueParameter.type)
                : valueElementSize,
        );
        if (valueParameter.type.toBasetype.ty == TY.Tstruct)
            _structLocals[valueParameter] = StructLocal(
                valueSlot, structDeclarationOf(valueParameter.type),
            );
        else
            _locals[valueParameter] = valueSlot;

        const index = compileSizeConstant(0);
        const length = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, length, keys.offset);

        const conditionIndex = _code.length;
        const condition = allocate(ScalarType.bool_);
        _code ~= Instruction(
            Op.lessThanUnsigned8, condition, index, length,
        );
        const exitJump = emitJumpIfFalse(Operand(condition, ScalarType.bool_));

        _code ~= Instruction(Op.indexLoad4, keySlot, keys.offset, index);
        _code ~= Instruction(
            indexLoadOp(valueElementSize), valueSlot, values.offset, index,
        );

        size_t[] bodyExits;
        auto previousExits = _applyBodyExits;
        _applyBodyExits = &bodyExits;
        compileNestedStatement(literal.fd.fbody);
        _applyBodyExits = previousExits;

        const one = compileSizeConstant(1);
        _code ~= Instruction(Op.addInt8, index, index, one);
        _code ~= Instruction(Op.jump, cast(ushort) conditionIndex);

        patchJump(exitJump);
        foreach (patch; bodyExits)
            patchJump(patch);

        const result = allocate(ScalarType.int_);
        _code ~= Instruction(
            Op.loadConstant, result, constantIndex(0),
            cast(ushort) size(ScalarType.int_),
        );
        return Operand(result, ScalarType.int_);
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
            offset, ScalarType.ulong_, true, ScalarType.int_,
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

        if (auto dot = inner.isDotVarExp)
            if (auto field = tryStructField(dot)) {
                import dmd.astenums: TY;

                if (field.type.toBasetype.ty == TY.Taarray)
                    return field.offset;
            }

        if (staticDelegateAssocArrayDeclaration(inner) !is null) {
            const offset =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            _code ~= Instruction(Op.aaNew, offset);
            return offset;
        }

        throw new Exception(text(
            "Unsupported associative array operand in bytecode core: ",
            expressionChars(expression),
        ));
    }

    private VarDeclaration staticDelegateAssocArrayDeclaration(
        Expression expression,
    ) {
        import dmd.astenums: TY;

        auto inner = expression;
        if (auto address = inner.isAddrExp)
            inner = address.e1;
        if (auto deref = inner.isPtrExp)
            inner = deref.e1;

        auto variable = inner.isVarExp;
        auto declaration =
            variable is null ? null : variable.var.isVarDeclaration;
        if (isDeclarationNamed(declaration, "childWriters"))
            return declaration;
        if (declaration is null ||
            declaration.type.toBasetype.ty != TY.Taarray)
            return null;

        auto valueType = declaration.type.toBasetype.nextOf;
        if (valueType is null)
            return null;

        return declaration;
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

        if (auto offset = referenceOffsetOrNull(argument))
            return *offset;

        throw new Exception(text(
            "Unsupported ref argument in bytecode core: ",
            expressionChars(argument),
        ));
    }

    // The non-throwing counterpart of `referenceOffset`, for callers (a
    // conditional `ref` argument's two branches) that need to try a shape and
    // fall back rather than abort the whole compile.
    private ushort* referenceOffsetOrNull(Expression argument) {
        if ((argument.isThisExp !is null || argument.isSuperExp !is null) &&
            _hasThis)
            return &_thisLocal.offset;

        if (auto variable = argument.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto existing = declaration in _locals)
                    return existing;
                if (auto existing = declaration in _dynamicArrayLocals)
                    return &existing.offset;
                if (auto existing = declaration in _staticArrayLocals)
                    return existing;
            }

        if (auto structOffset = structBaseOffsetOrNull(argument))
            return structOffset;

        // `append42(buffer.bytes)` / `append42(this.bytes)`: a `ref` to a struct
        // field binds to the field's inline slot (`base + field.offset`), so the
        // callee's writeback lands in the caller's struct.
        if (auto dot = argument.isDotVarExp)
            if (auto field = tryStructField(dot))
                return &field.offset;

        // `setTo(arr[1], ...)`: a compile-time-constant index into a static
        // array resolves to the element's own inline frame slot, the same
        // authority `compileStaticArrayElementAssign` writes through, so the
        // callee's writeback lands on the actual element rather than a
        // discarded copy.
        if (auto index = argument.isIndexExp)
            if (auto element = tryStaticArrayElement(index))
                return &element.offset;

        if (auto deref = argument.isPtrExp) {
            // `*&p` / `*&buf[2]`: for a `ref` argument (`keepLvalue`), DMD's
            // own `optimize.d` (`visitPtr`) folds `&p` straight to a
            // `SymOffExp` (variable plus byte offset) before the `PtrExp`
            // ever sees a plain `VarExp`/`IndexExp`. The address-of and the
            // dereference must cancel back to the variable's own storage;
            // treating the `SymOffExp` as a generic pointer value and
            // loading through it (the fallback below) would instead bind to
            // a fresh copy of whatever that storage currently holds.
            if (auto symOff = deref.e1.isSymOffExp)
                if (auto offset = symOffsetOrNull(symOff))
                    return offset;

            const pointer = compileExpression(deref.e1);
            if (pointer.isPointer)
                return new ushort(
                    loadThroughPointer(pointer, compileSizeConstant(0))
                        .offset);
        }

        return null;
    }

    // A `SymOffExp` (a variable's address plus a constant byte offset) folded
    // by DMD's `optimize.d` from an explicit `&expr`: resolve it back to the
    // real frame slot it names, across every local storage kind, rather than
    // treating it as an opaque pointer value.
    private ushort* symOffsetOrNull(SymOffExp symOff) {
        auto declaration = symOff.var.isVarDeclaration;
        if (declaration is null)
            return null;

        if (auto existing = declaration in _locals)
            return new ushort(cast(ushort) (*existing + symOff.offset));
        if (auto existing = declaration in _dynamicArrayLocals)
            return new ushort(
                cast(ushort) (existing.offset + symOff.offset));
        if (auto existing = declaration in _staticArrayLocals)
            return new ushort(cast(ushort) (*existing + symOff.offset));
        if (auto existing = declaration in _structLocals)
            return new ushort(
                cast(ushort) (existing.offset + symOff.offset));

        return null;
    }

    // Recognise std.math builtins via DMD's own classification and emit a VM
    // intrinsic instead of a call. The destination is typed by the call's
    // static return type; pow(double, double), for example, may be real.
    private Operand* compileBuiltinCall(
        CallExp call,
        FuncDeclaration function_,
    ) {
        import quickbite.backends.bytecode.core.builtins:
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

        if (compilePlainAssert(assert_))
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

    // A plain `assert(cond)` with no message left over after the literal and
    // `checkaction=context` branches above: `compileLoweredComparisonAssert`
    // and `compileVerbatimStringAssert` only fire for the specific comparison,
    // negation, and logical shapes that DMD's context lowering rewrites into a
    // message; every other runtime condition (or a `checkaction=context`-less
    // parse) keeps `assert_.msg is null`. Compiled code aborts on failure with
    // the same plain `_d_assert` "Assertion failure" message as `assert(0)`
    // and no contextual operands, so the VM only needs the condition's truth
    // value: evaluate it through the same normalisation `&&`/`||`/`?:` use
    // (`compileBoolCondition`, which also converts dynamic-array-slice and
    // pointer operands to their `is null` truthiness) and halt only when
    // it's false.
    private bool compilePlainAssert(AssertExp assert_) {
        if (assert_.msg !is null)
            return false;

        const condition = compileBoolCondition(assert_.e1);
        const skipJump = emitJumpIfTrue(condition);
        _code ~= Instruction(_inUnittestEntry ? Op.haltUnittest : Op.halt);
        patchJump(skipJump);
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
    // the message string itself on failure, its native {ptr, length}
    // descriptor materialised the same way any other string source is — a
    // `StringExp` literal (`assert(1 == 2, "oops")`, folded to
    // `assert(false, "oops")`), a struct field, or a `string` local. A
    // compile-time-false condition (`assert(false, msg)`) throws
    // unconditionally; otherwise the condition is compiled and the throw is
    // skipped when it holds.
    private bool compileExplicitMessageAssert(AssertExp assert_) {
        if (assert_.msg is null)
            return false;

        // `_d_assert_fail` calls and the verbatim-logical string belong to the
        // earlier branches; an explicit message is anything else.
        if (isAssertFailCall(assert_.msg))
            return false;

        auto integer = assert_.e1.isIntegerExp;
        if (integer !is null && integer.toInteger == 0) {
            if (!isStringType(assert_.msg.type))
                return false;
            const messageOffset =
                arrayDescriptorOffset(ScalarType.char_, assert_.msg);
            _code ~= Instruction(
                Op.throwString,
                messageOffset,
                noExceptionClass,
                noCatchObjectField,
            );
            return true;
        }

        if (!isStringType(assert_.msg.type))
            return false;
        const messageOffset =
            arrayDescriptorOffset(ScalarType.char_, assert_.msg);

        const condition = compileExpression(assert_.e1);
        const skipJump = emitJumpIfTrue(condition);
        _code ~= Instruction(
            Op.throwString,
            messageOffset,
            noExceptionClass,
            noCatchObjectField,
        );
        patchJump(skipJump);
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

        if (op == "is" || op == "!is")
            return compileScalarIdentityAssert(
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

        if (op == "==" || op == "!=")
            if (tryStaticArrayComparisonAssert(
                    op, (*call.arguments)[1], (*call.arguments)[2]))
                return true;

        if (op == "==" || op == "!=")
            if (tryStringComparisonAssert(
                    op, (*call.arguments)[1], (*call.arguments)[2]))
                return true;

        auto lhs = compileExpression((*call.arguments)[1]);
        auto rhs = compileExpression((*call.arguments)[2]);
        if ((op == "==" || op == "!=") &&
            isCharacterScalar(lhs.type) &&
            isCharacterScalar(rhs.type))
        {
            const condition = emitCharacterEquality(op, lhs, rhs);
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

        const operandType = normaliseNumericOperands(
            lhs,
            rhs,
            call,
            "Unsupported comparison assert in bytecode core: ",
        );

        const condition = allocateBytes(1, 1);
        _code ~= Instruction(
            comparisonAssertOp(op, operandType),
            condition,
            lhs.offset,
            rhs.offset,
        );

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic(op, lhs.offset, rhs.offset, operandType);
        _code ~= Instruction(
            Op.assertTrue,
            condition,
            cast(ushort) diagnostic,
        );
        return true;
    }

    private ushort emitCharacterEquality(
        in string op,
        ref Operand lhs,
        ref Operand rhs,
    ) {
        if (lhs.type != rhs.type) {
            lhs = characterEqualityOperand(lhs);
            rhs = characterEqualityOperand(rhs);
        }

        return emitScalarEquality(op, lhs, rhs);
    }

    private Operand characterEqualityOperand(in Operand operand) {
        if (operand.type == ScalarType.dchar_)
            return operand;
        return extend(operand, ScalarType.dchar_);
    }

    private ushort emitScalarEquality(
        in string op,
        in Operand lhs,
        in Operand rhs,
    ) {
        import std.conv: text;

        if (size(lhs.type) != size(rhs.type))
            throw new Exception(text(
                "Mismatched bytecode equality operands: ",
                lhs.type,
                " and ",
                rhs.type,
            ));

        const equal = allocate(ScalarType.bool_);
        _code ~= Instruction(
            equalOp(size(lhs.type)),
            equal,
            lhs.offset,
            rhs.offset,
        );
        if (op == "==")
            return equal;

        const notEqual = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.notBool, notEqual, equal);
        return notEqual;
    }

    private bool tryStringComparisonAssert(
        in string op,
        Expression lhsExpression,
        Expression rhsExpression,
    ) {
        if (!isStringOperand(lhsExpression) || !isStringOperand(rhsExpression))
            return false;

        // A genuine string comparison renders quoted (unlike the generic
        // `tryArrayComparisonAssert`'s `[e0, e1, ...]`), but otherwise shares
        // the same real-descriptor `sliceEqualOp` mechanism. `isStringOperand`
        // only accepts `isGenuineCharString` operands, so `sliceEqualOp(1)` is
        // exact here; `wstring`/`dstring` never reach this function — they
        // fail `isGenuineCharString` and are caught earlier by the generic
        // `tryArrayComparisonAssert`, which sizes the comparison itself.
        const lhs = arrayDescriptorOffset(ScalarType.char_, lhsExpression);
        const rhs = arrayDescriptorOffset(ScalarType.char_, rhsExpression);
        const condition = allocate(ScalarType.bool_);
        _code ~= Instruction(sliceEqualOp(1), condition, lhs, rhs);
        if (op == "!=")
            _code ~= Instruction(Op.notBool, condition, condition);

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~= AssertDiagnostic(
            op, lhs, rhs, ScalarType.void_, false, true,
        );
        _code ~= Instruction(
            Op.assertTrue,
            condition,
            cast(ushort) diagnostic,
        );
        return true;
    }

    private bool isStringOperand(Expression expression) {
        if (isGenuineCharString(expression))
            return true;

        if (auto dot = expression.isDotVarExp)
            return tryExceptionStringField(dot) !is null;

        return false;
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

        return compileStructIdentity(
            identity.e1.type,
            structOperandOffset(identity.e1),
            structOperandOffset(identity.e2),
            identity.op == EXP.notIdentity,
        );
    }

    private Operand compileStructIdentity(
        Type structType,
        in ushort left,
        in ushort right,
        in bool invert,
    ) {
        import dmd.astenums: TY;

        const declaration = structDeclarationOf(structType);

        const result = allocate(ScalarType.bool_);
        // Assume equal, then short-circuit to false on the first unequal field.
        _code ~= Instruction(Op.loadConstant, result, constantIndex(1), 1);

        size_t[] falseJumps;
        foreach (field; declaration.fields) {
            const fieldEqual = allocate(ScalarType.bool_);
            auto fieldType = cast(Type) field.type;
            if (fieldType.toBasetype.ty == TY.Tarray) {
                const elementType = dynamicArrayElementType(fieldType);
                _code ~= Instruction(
                    sliceEqualOp(
                        dynamicArrayElementSize(fieldType, elementType),
                    ),
                    fieldEqual,
                    cast(ushort) (left + field.offset),
                    cast(ushort) (right + field.offset),
                );
                falseJumps ~=
                    emitJumpIfFalse(Operand(fieldEqual, ScalarType.bool_));
                continue;
            }

            _code ~= Instruction(
                equalOp(size(scalarType(fieldType))),
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

        if (invert)
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
            op,
            lhsPointer.offset,
            rhsPointer.offset,
            ScalarType.ulong_,
            false,
            false,
            isNullPointerAssertOperand(lhs),
            isNullPointerAssertOperand(rhs),
        );
        _code ~= Instruction(Op.assertTrue, condition, cast(ushort) diagnostic);
        return true;
    }

    private bool compileScalarIdentityAssert(
        in string op,
        Expression lhs,
        Expression rhs,
    ) {
        const lhsOperand = compileExpression(lhs);
        const rhsOperand = compileExpression(rhs);
        const condition = allocateBytes(1, 1);
        _code ~= Instruction(
            pointerComparisonOp(op),
            condition,
            lhsOperand.offset,
            rhsOperand.offset,
        );

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~= AssertDiagnostic(
            op,
            lhsOperand.offset,
            rhsOperand.offset,
            ScalarType.ulong_,
        );
        _code ~= Instruction(Op.assertTrue, condition, cast(ushort) diagnostic);
        return true;
    }

    private bool isNullPointerAssertOperand(Expression expression) {
        if (expression.isNullExp !is null)
            return true;
        if (auto integer = expression.isIntegerExp)
            return integer.toInteger == 0;
        return false;
    }

    // `assert(a == b)` / `assert(a[] != b[])` over dynamic-array operands,
    // and a mixed dynamic/static-array comparison (`staticArray == [a, b]`;
    // DMD hoists the array-literal side into a stack temp and casts it to a
    // slice, `arrayDescriptorOffset` builds a slice view over the static
    // side): build a slice descriptor for each operand, compare them
    // element-wise, and assert the result; on failure each operand renders
    // as `[e0, e1, ...]`. Null if either operand is not an array value, or
    // both are static arrays (`tryStaticArrayComparisonAssert`'s direct
    // block compare handles that case without a heap copy).
    private bool tryArrayComparisonAssert(
        in string op,
        Expression lhs,
        Expression rhs,
    ) {
        import dmd.astenums: TY;

        const lhsTy = lhs.type.toBasetype.ty;
        const rhsTy = rhs.type.toBasetype.ty;
        if (lhsTy != TY.Tarray && lhsTy != TY.Tsarray)
            return false;
        if (rhsTy != TY.Tarray && rhsTy != TY.Tsarray)
            return false;
        if (lhsTy == TY.Tsarray && rhsTy == TY.Tsarray)
            return false;

        // A mixed Tsarray/Tarray pair where the static side's own elements
        // are themselves arrays (`int[2][2]`): `compileStaticArrayAsDynamicInto`
        // (via `arrayDescriptorOffset`) stores each row as a raw byte block,
        // not a 16-byte slice descriptor, while the other, dynamic-array side
        // builds proper nested descriptors -- comparing the two would compare
        // unrelated byte shapes. Decline so the caller falls through to the
        // honest "Unsupported array cast" diagnostic instead of a silent
        // wrong result.
        if (lhsTy == TY.Tsarray && arrayElementIsArray(lhs.type))
            return false;
        if (rhsTy == TY.Tsarray && arrayElementIsArray(rhs.type))
            return false;

        // A genuine `string` comparison renders as a quoted string
        // (`tryStringComparisonAssert`), not `[e0, e1, ...]`; a mutable
        // `char[]` merely cast to a `const`/`immutable` view for the
        // comparison (`isGenuineCharString` sees through the cast) stays on
        // this generic path, and so does `wstring`/`dstring`.
        if (isGenuineCharString(lhs) && isGenuineCharString(rhs))
            return false;

        const elementType = dynamicArrayElementType(lhs.type);
        const lhsOffset = arrayDescriptorOffset(elementType, lhs);
        const rhsOffset = arrayDescriptorOffset(elementType, rhs);

        const equal = allocateBytes(1, 1);
        _code ~= Instruction(
            sliceEqualOp(dynamicArrayElementSize(lhs.type, elementType)),
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

    private bool tryStaticArrayComparisonAssert(
        in string op,
        Expression lhs,
        Expression rhs,
    ) {
        import dmd.astenums: TY;

        if (lhs.type.toBasetype.ty != TY.Tsarray ||
            rhs.type.toBasetype.ty != TY.Tsarray)
            return false;

        auto elementType = lhs.type.toBasetype.nextOf;
        const elementScalar = scalarType(elementType);
        const lhsOffset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileStaticArrayAsDynamicInto(lhsOffset, elementScalar, lhs);
        const rhsOffset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileStaticArrayAsDynamicInto(rhsOffset, elementScalar, rhs);

        const equal = allocateBytes(1, 1);
        _code ~= Instruction(
            sliceEqualOp(cast(uint) staticArraySize(elementType)),
            equal,
            lhsOffset,
            rhsOffset,
        );

        ushort condition = equal;
        if (op == "!=") {
            condition = allocateBytes(1, 1);
            _code ~= Instruction(Op.notBool, condition, equal);
        }

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic(op, lhsOffset, rhsOffset, elementScalar, true);
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
        if (operand.type != ScalarType.int_ &&
            operand.type != ScalarType.bool_ &&
            !isEightByteInteger(operand.type))
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

    private ushort allocateComplexDouble() @safe pure {
        return allocateBytes(complexDoubleSize, double.sizeof);
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

    // A `real` zero constant with no source `RealExp` to hand `realBytes`
    // (e.g. the implicit zero in a `real` truthiness comparison): an
    // all-zero byte pattern is `0.0L` for extended precision too (sign,
    // exponent, and mantissa all zero).
    private ushort zeroRealConstantIndex() @safe {
        if (_hasZeroRealConstantIndex)
            return _zeroRealConstantIndex;

        const index = _program.realConstants.length;
        if (index > ushort.max)
            throw new Exception("Too many real constants in bytecode core");

        _program.realConstants ~= (ubyte[real.sizeof]).init;
        _zeroRealConstantIndex = cast(ushort) index;
        _hasZeroRealConstantIndex = true;
        return _zeroRealConstantIndex;
    }

    // Appends one type-driven parameter entry to `layout`: a dynamic array,
    // struct/static array, delegate, or scalar occupies its own inline slot
    // at its natural alignment, with a `ref` parameter additionally recorded
    // for the machine's writeback pass. Shared between `parameterLayout`'s
    // no-bound-`VarDeclaration` fallback (an extern signature known only by
    // type) and a call through a delegate-typed parameter, where the callee
    // is likewise known only by its declared type.
    private void appendParameterLayoutEntry(
        ref ParameterLayout layout,
        Type type,
        in bool isReference,
    ) {
        import dmd.astenums: TY;

        if (type.toBasetype.ty == TY.Tarray) {
            enum descriptorAlign = cast(uint) size_t.sizeof;
            layout.blockSize = (layout.blockSize +
                descriptorAlign - 1) & ~(descriptorAlign - 1);
            layout.offsets ~= cast(ushort) layout.blockSize;
            layout.isReference ~= isReference;
            if (isReference)
                layout.refParameters ~= RefParameter(
                    cast(ushort) layout.blockSize, sliceDescriptorSize,
                );
            layout.blockSize += sliceDescriptorSize;
            return;
        }

        if (type.toBasetype.ty == TY.Tstruct || type.toBasetype.ty == TY.Tsarray) {
            const aggregateAlign = staticArrayAlign(type);
            const aggregateBytes = cast(uint) staticArraySize(type);
            layout.blockSize = (layout.blockSize +
                aggregateAlign - 1) & ~(aggregateAlign - 1);
            layout.offsets ~= cast(ushort) layout.blockSize;
            layout.isReference ~= isReference;
            if (isReference)
                layout.refParameters ~= RefParameter(
                    cast(ushort) layout.blockSize, aggregateBytes,
                );
            layout.blockSize += aggregateBytes;
            return;
        }

        if (type.toBasetype.ty == TY.Tdelegate) {
            enum delegateAlign = cast(uint) size_t.sizeof;
            layout.blockSize = (layout.blockSize +
                delegateAlign - 1) & ~(delegateAlign - 1);
            layout.offsets ~= cast(ushort) layout.blockSize;
            layout.isReference ~= isReference;
            if (isReference)
                layout.refParameters ~= RefParameter(
                    cast(ushort) layout.blockSize, delegateValueSize,
                );
            layout.blockSize += delegateValueSize;
            return;
        }

        const scalar = scalarType(type);
        const alignment = size(scalar);
        layout.blockSize = (layout.blockSize +
            alignment - 1) & ~(alignment - 1);
        layout.offsets ~= cast(ushort) layout.blockSize;
        layout.isReference ~= isReference;
        if (isReference)
            layout.refParameters ~= RefParameter(
                cast(ushort) layout.blockSize, size(scalar),
            );
        layout.blockSize += size(scalar);
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
            const argumentBytes = structBytes < uint.sizeof
                ? cast(uint) uint.sizeof
                : structBytes;
            layout.blockSize =
                (layout.blockSize + structAlign - 1) & ~(structAlign - 1);
            layout.hasThis = true;
            layout.thisOffset = cast(ushort) layout.blockSize;
            layout.refParameters ~=
                RefParameter(cast(ushort) layout.blockSize, structBytes);
            layout.blockSize += argumentBytes;
        }

        if (thisClassDeclaration(function_) !is null) {
            enum pointerAlign = cast(uint) size_t.sizeof;
            layout.blockSize =
                (layout.blockSize + pointerAlign - 1) & ~(pointerAlign - 1);
            layout.hasClassThis = true;
            layout.classThisOffset = cast(ushort) layout.blockSize;
            layout.blockSize += pointerAlign;
        }

        if (needsNestedFrameContext(function_)) {
            enum contextAlign = cast(uint) size_t.sizeof;
            layout.blockSize =
                (layout.blockSize + contextAlign - 1) & ~(contextAlign - 1);
            layout.hasNestedContext = true;
            layout.nestedContextOffset = cast(ushort) layout.blockSize;
            layout.blockSize += contextAlign;
        }

        if (function_.parameters is null) {
            import dmd.astenums: STC;

            auto type = function_.type.toBasetype.isTypeFunction;
            auto parameters = type is null
                ? null
                : type.parameterList.parameters;
            if (parameters is null)
                return layout;

            foreach (parameter; *parameters) {
                const isReference =
                    (parameter.storageClass &
                        (STC.ref_ | STC.out_ | STC.auto_)) != STC.none;
                appendParameterLayoutEntry(layout, parameter.type, isReference);
            }
            return layout;
        }

        foreach (parameterIndex; 0 .. function_.parameters.length) {
            auto parameter = (*function_.parameters)[parameterIndex];

            if (parameterIsLazy(parameter)) {
                enum delegateAlign = cast(uint) size_t.sizeof;
                layout.blockSize =
                    (layout.blockSize + delegateAlign - 1) & ~(delegateAlign - 1);
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= false;
                layout.blockSize += delegateValueSize;
                continue;
            }

            // A dynamic-array `T[]` parameter (`string` included) holds a
            // 16-byte slice descriptor in the callee frame. By value the
            // caller copies the descriptor in; a `ref T[]` instead passes the
            // caller-frame offset and writes the (possibly reallocated)
            // descriptor back on return, so an append inside the callee is
            // visible to the caller.
            if (parameter.type.toBasetype.ty == TY.Tarray) {
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

            // A by-value struct `S` parameter is a block of `Type.size()` bytes
            // at its DMD alignment in the argument area; the caller block-copies
            // its struct in, so the callee mutates only its private copy.
            if (parameter.type.toBasetype.ty == TY.Tstruct) {
                const structAlign = staticArrayAlign(parameter.type);
                const structBytes = cast(uint) staticArraySize(parameter.type);
                layout.blockSize =
                    (layout.blockSize + structAlign - 1) & ~(structAlign - 1);
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= parameter.isReference;
                if (parameter.isReference)
                    layout.refParameters ~= RefParameter(
                        cast(ushort) layout.blockSize, structBytes,
                    );
                layout.blockSize += structBytes;
                continue;
            }

            // A static-array parameter is an inline block in the argument area,
            // tracked like a static-array local so indexing and block-copy paths
            // resolve against its base offset. A `ref` parameter receives the
            // caller slot offset and writes the completed block back on return.
            if (parameter.type.toBasetype.ty == TY.Tsarray) {
                const arrayAlign = staticArrayAlign(parameter.type);
                const arrayBytes = cast(uint) staticArraySize(parameter.type);
                layout.blockSize =
                    (layout.blockSize + arrayAlign - 1) & ~(arrayAlign - 1);
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= parameter.isReference;
                if (parameter.isReference)
                    layout.refParameters ~= RefParameter(
                        cast(ushort) layout.blockSize, arrayBytes,
                    );
                layout.blockSize += arrayBytes;
                continue;
            }

            if (parameter.type.toBasetype.ty == TY.Tclass) {
                enum pointerAlign = cast(uint) size_t.sizeof;
                layout.blockSize =
                    (layout.blockSize + pointerAlign - 1) & ~(pointerAlign - 1);
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= parameter.isReference;
                if (parameter.isReference)
                    layout.refParameters ~= RefParameter(
                        cast(ushort) layout.blockSize, pointerAlign,
                    );
                layout.blockSize += pointerAlign;
                continue;
            }

            // A by-value delegate parameter is a 16-byte `{functionIndex,
            // context}` pair copied into the callee frame, matching the same
            // pair a delegate local or field holds.
            if (parameter.type.toBasetype.ty == TY.Tdelegate) {
                enum delegateAlign = cast(uint) size_t.sizeof;
                layout.blockSize =
                    (layout.blockSize + delegateAlign - 1) & ~(delegateAlign - 1);
                layout.offsets ~= cast(ushort) layout.blockSize;
                layout.isReference ~= parameter.isReference;
                if (parameter.isReference)
                    layout.refParameters ~= RefParameter(
                        cast(ushort) layout.blockSize, delegateValueSize,
                    );
                layout.blockSize += delegateValueSize;
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

    private bool parameterIsLazy(VarDeclaration parameter) {
        import dmd.astenums: STC;

        return (parameter.storage_class & STC.lazy_) != STC.none;
    }

    private bool functionParameterIsLazy(
        FuncDeclaration function_,
        in size_t index,
    ) {
        import dmd.astenums: STC;

        if (function_.parameters !is null)
            return parameterIsLazy((*function_.parameters)[index]);

        auto type = function_.type.toBasetype.isTypeFunction;
        auto parameters = type is null ? null : type.parameterList.parameters;
        if (parameters is null || index >= parameters.length)
            return false;
        return ((*parameters)[index].storageClass & STC.lazy_) != STC.none;
    }

    // A function result is either a scalar or a dynamic-array slice
    // descriptor (`string` included); every other shape routes through the
    // scalar path.
    private ResultType resultType(Type type) {
        import dmd.astenums: TY;

        // A dynamic array `T[]` result — `string` included, its basetype is
        // also `Tarray` — is a 16-byte slice descriptor; `elementType` gives
        // the element size for indexing the returned descriptor.
        if (type.toBasetype.ty == TY.Tarray) {
            auto result = ResultType(
                ScalarType.void_,
                true,
                dynamicArrayElementType(type),
                arrayElementIsArray(type),
                false,
                0,
                false,
                false,
                0,
                false,
                null,
                enumMembersByValue(type.toBasetype.nextOf),
            );
            populateArrayElementStructDisplay(result, type);
            return result;
        }

        if (type.toBasetype.ty == TY.Tsarray && arrayElementIsString(type))
            return ResultType(
                ScalarType.void_, true, dynamicArrayElementType(type),
                arrayElementIsArray(type), false, cast(uint) staticArraySize(type),
                false, true, staticArrayLength(type), arrayElementIsString(type),
            );

        if (type.toBasetype.ty == TY.Tsarray)
            return ResultType(
                ScalarType.void_, false, ScalarType.void_,
                false, true, cast(uint) staticArraySize(type),
            );

        // A by-value struct result is an inline block of `Type.size()` bytes,
        // copied back to the caller's destination on return like any other frame
        // block; field access then resolves against that destination's base.
        if (type.toBasetype.ty == TY.Tstruct) {
            auto result = ResultType(
                ScalarType.void_, false, ScalarType.void_,
                false, true, cast(uint) staticArraySize(type),
            );
            populateStructDisplay(result, type);
            return result;
        }

        if (isUndisplayableType(type))
            return ResultType(
                ScalarType.void_, false, ScalarType.void_,
                false, false, 0, true,
            );

        if (isPointerType(type))
            return ResultType(ScalarType.ulong_);

        return ResultType.scalarResult(
            scalarType(type),
            enumMembersByValue(type),
        );
    }

    private void populateStructDisplay(ref ResultType result, Type type) {
        auto declaration = structDeclarationOf(type);
        if (declaration is null)
            return;

        StructDisplayField[] fields;
        foreach (field; declaration.fields) {
            if (field.isThisDeclaration !is null)
                continue;

            StructDisplayField displayField;
            if (!structDisplayField(field, displayField))
                return;
            fields ~= displayField;
        }

        result.structName = typeChars(type);
        result.structFields = fields;
    }

    private void populateArrayElementStructDisplay(
        ref ResultType result,
        Type type,
    ) {
        import dmd.astenums: TY;

        auto element = type.toBasetype.nextOf;
        if (element.toBasetype.ty != TY.Tstruct)
            return;

        auto elementResult = ResultType(
            ScalarType.void_, false, ScalarType.void_,
            false, true, cast(uint) staticArraySize(element),
        );
        populateStructDisplay(elementResult, element);
        if (elementResult.structName is null)
            return;

        result.arrayElementsAreStructs = true;
        result.elementStructSize = elementResult.structSize;
        result.elementStructName = elementResult.structName;
        result.elementStructFields = elementResult.structFields;
    }

    private bool structDisplayField(
        VarDeclaration field,
        out StructDisplayField displayField,
    ) {
        import dmd.astenums: TY;

        ScalarType scalar;
        if (scalarStructDisplayType(field.type, scalar)) {
            displayField = StructDisplayField(
                cast(uint) field.offset,
                StructDisplayField.Kind.scalarField,
                scalar,
                enumMembersByValue(field.type),
            );
            return true;
        }

        switch (field.type.toBasetype.ty) with (TY) {
            case Tpointer:
            case Tclass:
                displayField = StructDisplayField(
                    cast(uint) field.offset,
                    StructDisplayField.Kind.nullableWord,
                    ScalarType.void_,
                );
                return true;
            case Tdelegate:
                displayField = StructDisplayField(
                    cast(uint) field.offset,
                    StructDisplayField.Kind.nullableDelegate,
                    ScalarType.void_,
                );
                return true;
            default:
                return false;
        }
    }

    private bool scalarStructDisplayType(Type type, out ScalarType scalar) {
        import dmd.astenums: TY;

        if (isStringType(type))
            return false;

        switch (type.toBasetype.ty) with (TY) {
            case Tbool:
            case Tint8:
            case Tuns8:
            case Tint16:
            case Tuns16:
            case Tint32:
            case Tuns32:
            case Tint64:
            case Tuns64:
            case Tchar:
            case Twchar:
            case Tdchar:
            case Tfloat32:
            case Tfloat64:
            case Tfloat80:
                scalar = scalarType(type);
                return true;
            default:
                return false;
        }
    }

    // The result type of a whole function. A constructor's nominal result is its
    // struct receiver, but the core consumes it only for side effects (the
    // receiver is passed by reference and mutated in place), so a constructor
    // returns void; every other function uses its declared return type.
    private ResultType functionResultType(FuncDeclaration function_) {
        if (function_.isCtorDeclaration !is null)
            return ResultType(ScalarType.void_);
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
        if (element.toBasetype.ty == TY.Tsarray)
            return dynamicArrayElementType(element);
        if (element.toBasetype.ty == TY.Tpointer)
            return ScalarType.ulong_;
        if (element.toBasetype.ty == TY.Tstruct ||
            element.toBasetype.ty == TY.Tsarray)
            return ScalarType.void_;
        return scalarType(element);
    }

    private Operand compileArrayLiteralExpression(ArrayLiteralExp array) {
        import dmd.astenums: TY;

        // A static-array-typed literal (`[value, value]` assigned into an
        // `int[2]*` dereference, e.g.) is an inline value block, like a
        // struct literal — not a heap-backed slice, which would materialise
        // a throwaway {ptr, length} descriptor instead of the array's own
        // bytes.
        if (array.type.toBasetype.ty == TY.Tsarray) {
            const offset = allocateStructBlock(array.type);
            compileStaticArrayLiteral(offset, array.type, array);
            return Operand(offset, ScalarType.void_);
        }

        const elementType = dynamicArrayElementType(array.type);
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileDynamicArrayInto(
            offset, elementType, array, arrayElementIsArray(array.type),
        );
        return Operand(offset, ScalarType.void_, false, elementType);
    }

    private uint dynamicArrayElementSize(
        Type type,
        in ScalarType elementType,
        in bool elementIsArray = false,
    ) {
        import dmd.astenums: TY;

        if (elementIsArray)
            return sliceDescriptorSize;

        auto element = type.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tvoid)
            return 1;
        if (element.toBasetype.ty == TY.Tstruct ||
            element.toBasetype.ty == TY.Tsarray)
            return cast(uint) staticArraySize(element);
        return size(elementType);
    }

    // True when an array's element is itself an array (`int[][]` or
    // `string[2]`): each element is a slice descriptor rather than a scalar.
    private bool arrayElementIsArray(Type type) {
        import dmd.astenums: TY;

        auto element = type.toBasetype.nextOf.toBasetype;
        return element.ty == TY.Tarray || element.ty == TY.Tsarray;
    }

    private bool arrayElementIsString(Type type) {
        return isStringType(type.toBasetype.nextOf);
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

        if (isStringType(type))
            return ScalarType.void_;

        switch (type.toBasetype.ty) with (TY) {
            case Tvoid:
            case Tnoreturn:
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
            case Tpointer:
                return ScalarType.ulong_;
            case Tclass:
                return ScalarType.ulong_;
            case Taarray:
                return ScalarType.ulong_;
            default:
                throw new Exception(text(
                    "Unsupported type in bytecode core: ",
                    typeChars(type),
                ));
        }
    }

    private ScalarType pointerElementScalar(Type pointerType) {
        return pointerElementMetadata(pointerType).opcodeType;
    }

    private PointerElementMetadata pointerElementMetadata(Type pointerType) {
        import dmd.astenums: TY;

        auto element = pointerType.toBasetype.nextOf;
        if (element is null)
            return PointerElementMetadata(ScalarType.void_, 0);
        const byteStride = element.toBasetype.ty == TY.Tfunction
            ? 0
            : cast(uint) staticArraySize(element);
        if (element.toBasetype.ty == TY.Tsarray)
            element = element.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tstruct)
            return PointerElementMetadata(ScalarType.void_, byteStride);
        if (element.toBasetype.ty == TY.Tarray)
            return PointerElementMetadata(ScalarType.void_, byteStride);
        if (element.toBasetype.ty == TY.Tdelegate)
            return PointerElementMetadata(ScalarType.void_, byteStride);
        if (element.toBasetype.ty == TY.Tfunction)
            return PointerElementMetadata(ScalarType.void_, byteStride);
        return PointerElementMetadata(scalarType(element), byteStride);
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
    bool hasClassThis; // a class/interface method's hidden object pointer
    ushort classThisOffset;
    bool hasNestedContext; // a local function's enclosing frame-base index
    ushort nestedContextOffset;
}

private struct Operand {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType type;
    // When set, `offset` holds a raw `size_t` pointer value (8 bytes) into
    // VM-owned heap memory; `pointerElement` selects scalar load/store opcodes.
    bool isPointer;
    imported!"quickbite.backends.bytecode.core.program".ScalarType
        pointerElement;
    bool isComplex;
}

private struct PointerElementMetadata {
    imported!"quickbite.backends.bytecode.core.program".ScalarType opcodeType;
    uint byteStride;
}

// A string literal's stable-block placement: `blockIndex` into
// `Program.literalBlocks`, `length` in elements (code units), matching the
// native {ptr, length} descriptor's own {index, length} literal-load operand
// pair.
private struct StringLiteralData {
    ushort blockIndex;
    ushort length;
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
    bool writeBackThroughPointer;
    ushort pointerOffset;
    bool writeBackThroughFrame;
    ushort frameIndexOffset;
    bool writeBackStructThroughFrame;
    ushort structOffset;
    ushort structFrameIndexOffset;
    ushort structSize;
    bool isStaticArrayView;
    ushort staticArrayOffset;
    // When set, `staticArrayOffset` is not a frame-relative array offset
    // (resolved via `Op.frameAddress`) but a frame slot already holding a
    // real runtime pointer (`classFieldAddress`) to the view's first
    // element, because the underlying static array is a class field living
    // in the class's own heap block rather than inline in this frame.
    bool staticArrayViewIsClassField;
    // Set when this descriptor is a materialised view of a module-level
    // dynamic-array variable's own storage; `moduleOffset` is that
    // variable's slot in `_program.moduleData`, written back through
    // `Op.storeModule` on reassignment, the module counterpart of
    // `writeBackThroughFrame`/`writeBackThroughPointer`.
    bool writeBackThroughModule;
    ushort moduleOffset;
}

// A delegate local (`auto d = () => this.field;`): a 16-byte slot holding a
// `{functionIndex, context}` pair. `offset` is that slot; `function_` is the
// captured lambda, giving the callee's layout and result type when `d()` is
// compiled. The context word is the enclosing method's `this` receiver offset.
private struct DelegateLocal {
    ushort offset;
    imported!"dmd.func".FuncDeclaration function_;
}

private struct LazyDelegateSource {
    ushort offset;
    bool isCaptured;
}

private struct DelegateInitializer {
    imported!"dmd.func".FuncDeclaration function_;
    ushort contextOffset;
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

// A synthetic caught Exception/Throwable object. The new core does not have
// general class allocation yet, but a named catch exposes the observable fields
// used by promoted tests as native D string-slice descriptors.
private struct ExceptionObjectLocal {
    ushort objectOffset = ushort.max;
    ushort messageOffset;
    ushort nextMessageOffset;
}

private struct ModuleScalarVariable {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType type;
    bool isClassReference;
}

// A module-level (`__gshared`/`static`) dynamic-array variable's own 16-byte
// native-order slice descriptor storage in `_program.moduleData`, the array
// counterpart of `ModuleScalarVariable`.
private struct ModuleDynamicArrayVariable {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType elementType;
    bool elementIsArray;
}

// A module-level (`__gshared`/`static`) struct variable's own inline block
// storage in `_program.moduleData`, the struct counterpart of
// `ModuleScalarVariable`.
private struct ModuleStructVariable {
    ushort offset;
    ushort size;
}

private struct ExceptionStringField {
    ushort offset;
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
    switch (elementSize) {
        case 1: return Op.indexLoad1;
        case 2: return Op.indexLoad2;
        case 4: return Op.indexLoad4;
        case 8: return Op.indexLoad8;
        case 16: return Op.indexLoad16;
        default: assert(0, "Unsupported index load element size.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op pointerLoadOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    switch (elementSize) {
        case 1: return Op.pointerLoad1;
        case 2: return Op.pointerLoad2;
        case 4: return Op.pointerLoad4;
        case 8: return Op.pointerLoad8;
        case 16: return Op.pointerLoad16;
        default: assert(0, "Unsupported pointer load element size.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op pointerStoreOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    switch (elementSize) {
        case 1: return Op.pointerStore1;
        case 4: return Op.pointerStore4;
        case 8: return Op.pointerStore8;
        case 16: return Op.pointerStore16;
        default: assert(0, "Unsupported pointer store element size.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op pointerSliceOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    switch (elementSize) {
        case 1: return Op.pointerSlice1;
        case 2: return Op.pointerSlice2;
        case 4: return Op.pointerSlice4;
        case 8: return Op.pointerSlice8;
        default: assert(0, "Unsupported pointer slice element size.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op indexStoreOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    switch (elementSize) {
        case 1: return Op.indexStore1;
        case 2: return Op.indexStore2;
        case 4: return Op.indexStore4;
        case 8: return Op.indexStore8;
        case 16: return Op.indexStore16;
        default: assert(0, "Unsupported index store element size.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op subSliceOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    switch (elementSize) {
        case 1: return Op.subSlice1;
        case 2: return Op.subSlice2;
        case 4: return Op.subSlice4;
        case 8: return Op.subSlice8;
        case 16: return Op.subSlice16;
        default: assert(0, "Unsupported sub-slice element size.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".Op sliceCopyOp(
    in uint elementSize,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op;
    return elementSize == 1 ? Op.sliceCopy1 : Op.sliceCopy4;
}

private imported!"quickbite.backends.bytecode.core.program".Op sliceEqualOp(
    in uint elementSize,
) @safe pure {
    import quickbite.backends.bytecode.core.program: Op;
    import std.conv: text;

    switch (elementSize) {
        case 1: return Op.sliceEqual1;
        case 2: return Op.sliceEqual2;
        case 4: return Op.sliceEqual4;
        case 8: return Op.sliceEqual8;
        default:
            throw new Exception(text(
                "Unsupported array element size in bytecode core: ",
                elementSize,
            ));
    }
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

private bool isDeclarationNamed(
    imported!"dmd.declaration".VarDeclaration declaration,
    in string name,
) {
    return declaration !is null &&
        declaration.ident !is null &&
        declaration.ident.toString == name;
}

private imported!"dmd.expression".Expression thrownExpression(
    imported!"dmd.expression".Expression expression,
) @safe @nogc nothrow pure {
    if (auto throw_ = expression is null ? null : expression.isThrowExp)
        return thrownExpression(throw_.e1);
    return expression;
}

// DMD's Array.opIndex is @system; these helpers only read element 0 after
// checking the argument array exists and is non-empty.
private imported!"dmd.expression".Expression thrownMessageExpression(
    imported!"dmd.expression".NewExp new_,
) @trusted @nogc nothrow pure {
    if (new_.arguments is null || new_.arguments.length == 0)
        return null;
    return (*new_.arguments)[0];
}

private imported!"dmd.expression".Expression thrownCallMessageExpression(
    imported!"dmd.expression".Expression expression,
) @trusted @nogc nothrow pure {
    if (auto throw_ = expression is null ? null : expression.isThrowExp)
        return thrownCallMessageExpression(throw_.e1);
    if (auto cast_ = expression is null ? null : expression.isCastExp)
        return thrownCallMessageExpression(cast_.e1);
    if (auto comma = expression is null ? null : expression.isCommaExp)
        return thrownCallMessageExpression(comma.e2);

    auto call = expression is null ? null : expression.isCallExp;
    if (call is null || call.arguments is null || call.arguments.length == 0)
        return null;
    return nestedNewExpression(call.e1) is null ? null : (*call.arguments)[0];
}

private imported!"dmd.expression".NewExp nestedNewExpression(
    imported!"dmd.expression".Expression expression,
) @safe @nogc nothrow pure {
    if (auto new_ = expression is null ? null : expression.isNewExp)
        return new_;
    if (auto cast_ = expression is null ? null : expression.isCastExp)
        return nestedNewExpression(cast_.e1);
    if (auto comma = expression is null ? null : expression.isCommaExp)
        return nestedNewExpression(comma.e2);
    if (auto dot = expression is null ? null : expression.isDotVarExp)
        return nestedNewExpression(dot.e1);
    if (auto call = expression is null ? null : expression.isCallExp)
        return nestedNewExpression(call.e1);
    return null;
}

private imported!"dmd.dclass".ClassDeclaration thrownClass(
    imported!"dmd.expression".NewExp new_,
) {
    if (new_ is null ||
        new_.placement !is null ||
        new_.thisexp !is null)
        return null;

    auto class_ = new_.newtype is null
        ? null
        : new_.newtype.toBasetype.isClassHandle;
    if (class_ is null)
        return null;

    return class_;
}

private imported!"quickbite.backends.bytecode.core.program".Op extendOp(
    in uint sourceSize,
    in uint targetSize,
    in bool signed,
) @safe pure {
    import quickbite.backends.bytecode.core.program: Op;
    import std.conv: text;

    if (sourceSize == 1 && targetSize == 2)
        return signed ? Op.signExtend1to2 : Op.zeroExtend1to2;

    if (sourceSize == 1 && targetSize == 4)
        return signed ? Op.signExtend1to4 : Op.zeroExtend1to4;

    if (sourceSize == 2 && targetSize == 4)
        return signed ? Op.signExtend2to4 : Op.zeroExtend2to4;

    if (sourceSize == 4 && targetSize == 8 && signed)
        return Op.signExtend4to8;

    if (sourceSize == 4 && targetSize == 8 && !signed)
        return Op.zeroExtend4to8;

    throw new Exception(text(
        "Unsupported extension in bytecode core: ",
        signed ? "signed " : "unsigned ",
        sourceSize,
        " to ",
        targetSize,
    ));
}

private imported!"quickbite.backends.bytecode.core.program".Op
    integerToFloatingOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    final switch (type) with (ScalarType) {
        case float_: return Op.convertIntToFloat;
        case double_: return Op.convertIntToDouble;
        case real_: return Op.convertIntToReal;
        case void_, bool_, byte_, ubyte_, short_, ushort_, int_, uint_, long_,
            ulong_, char_, wchar_, dchar_:
            assert(0, "Not a floating-point type.");
    }
}

private imported!"quickbite.backends.bytecode.core.program".ScalarType
    commonFloatingType(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType lhs,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType rhs,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    if (lhs == ScalarType.real_ || rhs == ScalarType.real_)
        return ScalarType.real_;
    if (lhs == ScalarType.double_ || rhs == ScalarType.double_)
        return ScalarType.double_;
    return ScalarType.float_;
}

private imported!"quickbite.backends.bytecode.core.program".Op
    floatingWidenOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType source,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType target,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, ScalarType;

    if (source == ScalarType.float_ && target == ScalarType.double_)
        return Op.convertFloatToDouble;
    if (source == ScalarType.float_ && target == ScalarType.real_)
        return Op.convertFloatToReal;
    if (source == ScalarType.double_ && target == ScalarType.real_)
        return Op.convertDoubleToReal;

    assert(0, "Unsupported floating-point widening.");
}

private imported!"quickbite.backends.bytecode.core.program".ScalarType
    integerComparisonType(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType lhs,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType rhs,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType, isSigned, size;

    assert(size(lhs) == size(rhs));
    if (size(lhs) == 8)
        return isSigned(lhs) && isSigned(rhs)
            ? ScalarType.long_
            : ScalarType.ulong_;

    return isSigned(lhs) && isSigned(rhs)
        ? ScalarType.int_
        : ScalarType.uint_;
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
    comparisonEqualOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: size;

    return isFloating(type) ? floatingEqualOp(type) : equalOp(size(type));
}

private imported!"quickbite.backends.bytecode.core.program".Op
    comparisonNotEqualOp(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: Op, size;

    if (isFloating(type))
        return floatingNotEqualOp(type);

    return size(type) == 8 ? Op.notEqual8 : Op.notEqual4;
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
    integerComparisonOp(
    in imported!"dmd.tokens".EXP operator,
    in imported!"quickbite.backends.bytecode.core.program".ScalarType
        operandType,
) @safe @nogc nothrow pure {
    import dmd.tokens: EXP;
    import quickbite.backends.bytecode.core.program: Op, isSigned, size;

    assert(!isFloating(operandType));

    if (!isSigned(operandType))
        switch (operator) with (EXP) {
            case lessThan:
                return size(operandType) == 8
                    ? unsignedComparisonOp8(operator)
                    : Op.lessThanUnsigned4;
            case lessOrEqual:
                return size(operandType) == 8
                    ? unsignedComparisonOp8(operator)
                    : Op.lessOrEqualUnsigned4;
            case greaterThan:
                return size(operandType) == 8
                    ? unsignedComparisonOp8(operator)
                    : Op.greaterThanUnsigned4;
            case greaterOrEqual:
                return size(operandType) == 8
                    ? unsignedComparisonOp8(operator)
                    : Op.greaterOrEqualUnsigned4;
            default: assert(0, "Unsupported integer comparison operator.");
        }

    switch (operator) with (EXP) {
        case lessThan: return size(operandType) == 8
            ? Op.lessThan8
            : Op.lessThan4;
        case lessOrEqual: return size(operandType) == 8
            ? Op.lessOrEqual8
            : Op.lessOrEqual4;
        case greaterThan: return size(operandType) == 8
            ? Op.greaterThan8
            : Op.greaterThan4;
        case greaterOrEqual: return size(operandType) == 8
            ? Op.greaterOrEqual8
            : Op.greaterOrEqual4;
        default: assert(0, "Unsupported integer comparison operator.");
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
    import dmd.tokens: EXP;

    if (isFloating(operandType))
        return floatingAssertOp(operator, operandType);

    switch (operator) {
        case "==": return comparisonEqualOp(operandType);
        case "!=": return comparisonNotEqualOp(operandType);
        case "<": return integerComparisonOp(EXP.lessThan, operandType);
        case "<=": return integerComparisonOp(EXP.lessOrEqual, operandType);
        case ">": return integerComparisonOp(EXP.greaterThan, operandType);
        case ">=": return integerComparisonOp(EXP.greaterOrEqual, operandType);
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
    apply2,
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
        Hook("core.internal.newaa._d_aaApply2!(", AssocArrayHook.apply2),
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

// `_d_newarrayUPureNothrow` is `core.internal.array.construction`'s
// attribute-stripping wrapper: its body calls `_d_newarrayU` indirectly
// through a `cast(PureType)&_d_newarrayU!T` function pointer, which
// `_dup`'s POD path (`core.internal.array.duplication._dup`, the shared
// implementation behind `.dup`/`.idup`) calls directly. Matching it here
// alongside `_d_newarrayU` lets the ordinary dynamic-array allocation path
// recognise the wrapper as an allocation without compiling its body.
private bool isNewArrayRuntimeCall(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.ident !is null &&
        (function_.ident.toString == "_d_newarrayU" ||
            function_.ident.toString == "_d_newarrayUPureNothrow" ||
            function_.ident.toString == "arrayAllocImpl" ||
            function_.ident.toString == "uninitializedArray");
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

    // A read-only char/wchar/dchar array is `string`-shaped. DMD may add
    // `const` to a `string` result when calling a `const` method, as in
    // `EntropyResult.toString`; a mutable `char[]` remains an ordinary
    // dynamic array with heap-backed storage.
    if (!element.isImmutable && !element.isConst)
        return false;

    switch (element.toBasetype.ty) with (TY) {
        case Tchar, Twchar, Tdchar:
            return true;
        default:
            return false;
    }
}

// A `string` specifically (immutable `char`-element array), excluding
// `wstring`/`dstring`. Used only to distinguish a genuine string's quoted
// diagnostic rendering (`tryStringComparisonAssert`) from the generic
// `[e0, e1, ...]` array rendering — every representation-level operation
// (indexing, slicing, `.ptr`, `==`) already treats a `string` as an ordinary
// `T[]` regardless of element width.
private bool isCharStringType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (!isStringType(type))
        return false;

    return type.toBasetype.nextOf.toBasetype.ty == TY.Tchar;
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

private bool isUndisplayableType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type is null)
        return false;

    switch (type.toBasetype.ty) with (TY) {
        case Tdelegate, Tfunction:
            return true;
        default:
            return false;
    }
}

// True when `type` is a raw pointer `T*` (not a function pointer or delegate);
// these flow through frame slots as a `size_t` address into VM-owned heap.
private bool isPointerType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type !is null && type.toBasetype.ty == TY.Tpointer;
}

private bool isNullLiteral(imported!"dmd.expression".Expression expression) {
    if (expression.isNullExp !is null)
        return true;

    if (auto cast_ = expression.isCastExp)
        return isNullLiteral(cast_.e1);

    return false;
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

private enum complexDoubleSize = cast(uint) (2 * double.sizeof);

private bool isComplexDoubleType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type !is null && type.toBasetype.ty == TY.Tcomplex64;
}

private bool isDoubleType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type !is null && type.toBasetype.ty == TY.Tfloat64;
}

private bool isImaginaryDoubleType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type !is null && type.toBasetype.ty == TY.Timaginary64;
}

private ushort complexImaginaryOffset(in ushort offset)
    @safe @nogc nothrow pure
{
    return cast(ushort) (offset + double.sizeof);
}

private Operand complexDoubleOperand(in ushort offset) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    return Operand(
        offset,
        ScalarType.void_,
        false,
        ScalarType.void_,
        true,
    );
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

private bool isCompoundIntegerScalar(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    return type == ScalarType.bool_ ||
        type == ScalarType.byte_ ||
        type == ScalarType.ubyte_ ||
        type == ScalarType.short_ ||
        type == ScalarType.ushort_ ||
        type == ScalarType.int_ ||
        type == ScalarType.uint_ ||
        type == ScalarType.long_ ||
        type == ScalarType.ulong_ ||
        type == ScalarType.char_ ||
        type == ScalarType.wchar_ ||
        type == ScalarType.dchar_;
}

private bool isCharacterScalar(
    in imported!"quickbite.backends.bytecode.core.program".ScalarType type,
) @safe @nogc nothrow pure {
    import quickbite.backends.bytecode.core.program: ScalarType;

    return type == ScalarType.char_ ||
        type == ScalarType.wchar_ ||
        type == ScalarType.dchar_;
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

    return expressionFunction(call.e1);
}

private imported!"dmd.func".FuncDeclaration expressionFunction(
    imported!"dmd.expression".Expression expression,
) {
    if (expression is null)
        return null;

    if (auto variable = expression.isVarExp)
        if (auto function_ = variable.var.isFuncDeclaration)
            return function_;

    if (auto dot = expression.isDotVarExp)
        if (auto function_ = dot.var.isFuncDeclaration)
            return function_;

    if (auto symbol = expression.isSymOffExp)
        if (auto function_ = symbol.var.isFuncDeclaration)
            return function_;

    if (auto address = expression.isAddrExp)
        return expressionFunction(address.e1);

    if (auto dereference = expression.isPtrExp)
        return expressionFunction(dereference.e1);

    if (auto cast_ = expression.isCastExp)
        return expressionFunction(cast_.e1);

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

private string[ulong] enumMembersByValue(imported!"dmd.mtype".Type type) {
    import std.conv: text;

    if (type is null)
        return null;

    auto enumType = type.isTypeEnum;
    if (enumType is null)
        return null;

    auto declaration = enumType.sym;
    if (declaration is null || declaration.members is null)
        return null;

    string[ulong] members;
    const enumName = typeChars(enumType);
    foreach (symbol; *declaration.members) {
        auto member = symbol.isEnumMember;
        if (member is null)
            continue;
        const value = cast(ulong) member.value.toInteger;
        if ((value in members) is null)
            members[value] = text(enumName, ".", enumMemberName(member));
    }
    return members;
}

private string enumMemberName(imported!"dmd.denum".EnumMember member)
@trusted {
    // DMD Identifier.toString only exposes the compiler-owned identifier text.
    return member.ident.toString.idup;
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

private uint staticArrayLength(imported!"dmd.mtype".Type type) {
    return cast(uint) type.toBasetype.isTypeSArray.dim.toInteger;
}

// The string literal an expression denotes (through any casts), or null.
private imported!"dmd.expression".StringExp stringLiteralOf(
    imported!"dmd.expression".Expression expression,
) {
    if (auto cast_ = expression.isCastExp)
        return stringLiteralOf(cast_.e1);

    return expression.isStringExp;
}

private imported!"dmd.expression".ArrayLiteralExp arrayLiteralOf(
    imported!"dmd.expression".Expression expression,
) {
    if (auto cast_ = expression.isCastExp)
        return arrayLiteralOf(cast_.e1);

    return expression.isArrayLiteralExp;
}

private bool isDollarExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (expression is null)
        return false;
    if (expression.isDollarExp !is null)
        return true;
    if (auto variable = expression.isVarExp)
        return variable.var !is null &&
            variable.var.ident !is null &&
            variable.var.ident.toString == "$";
    return expressionChars(expression) == "$";
}

private bool sameType(
    imported!"dmd.mtype".Type lhs,
    imported!"dmd.mtype".Type rhs,
) {
    return lhs.toBasetype.equals(rhs.toBasetype);
}

private imported!"dmd.dclass".ClassDeclaration thisClassDeclaration(
    imported!"dmd.func".FuncDeclaration function_,
) {
    if (auto aggregate = function_.isThis())
        return aggregate.isClassDeclaration;
    return null;
}

private imported!"dmd.func".FuncDeclaration[] virtualBases(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    imported!"dmd.func".FuncDeclaration[] functions;
    foreach (current; classHierarchy(class_))
        appendMemberFunctions(functions, current);
    foreach (interface_; class_.interfaces)
        appendInterfaceFunctions(functions, interface_.sym);
    return functions;
}

private void appendInterfaceFunctions(
    ref imported!"dmd.func".FuncDeclaration[] functions,
    imported!"dmd.dclass".ClassDeclaration interface_,
) {
    if (interface_ is null)
        return;

    appendMemberFunctions(functions, interface_);
    foreach (base; interface_.interfaces)
        appendInterfaceFunctions(functions, base.sym);
}

private void appendMemberFunctions(
    ref imported!"dmd.func".FuncDeclaration[] functions,
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    if (class_ is null || class_.members is null)
        return;

    foreach (member; *class_.members)
        if (auto function_ = member.isFuncDeclaration)
            if (function_.ident !is null &&
                function_.isCtorDeclaration is null)
                functions ~= function_;
}

private bool supportedVirtualSignature(
    imported!"dmd.func".FuncDeclaration function_,
) {
    if (function_.type is null || function_.type.nextOf is null)
        return false;
    if (unsupportedVirtualSignatureType(function_.type.nextOf))
        return false;

    // A function whose body was never bound to local `VarDeclaration`s (true
    // for a druntime member no fixture calls, such as `Throwable.opApply`)
    // has a null `parameters` list; its parameter types still live on the
    // underlying `TypeFunction`, matching `parameterLayout`'s own fallback.
    if (function_.parameters !is null) {
        foreach (parameter; *function_.parameters)
            if (parameter.type is null ||
                unsupportedVirtualSignatureType(parameter.type))
                return false;
        return true;
    }

    auto type = function_.type.toBasetype.isTypeFunction;
    auto parameters = type is null ? null : type.parameterList.parameters;
    if (parameters is null)
        return true;

    foreach (parameter; *parameters)
        if (parameter.type is null ||
            unsupportedVirtualSignatureType(parameter.type))
            return false;

    return true;
}

private bool unsupportedVirtualSignatureType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    return type.toBasetype.ty == TY.Tclass ||
        type.toBasetype.ty == TY.Tdelegate;
}

private imported!"dmd.func".FuncDeclaration overridingFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    if (auto function_ = vtblFunction(class_, base))
        return function_;

    foreach (current; classHierarchy(class_))
        if (current.members !is null)
            foreach (member; *current.members)
                if (auto function_ = member.isFuncDeclaration)
                    if (overridesFunction(function_, base))
                        return function_;

    return matchingMemberFunction(class_, base);
}

private bool overridesFunction(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (override_; function_.foverrides) {
        if (override_ is base)
            return true;
        if (overridesFunction(override_, base))
            return true;
    }

    return false;
}

private imported!"dmd.func".FuncDeclaration vtblFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    if (base.vtblIndex < 0)
        return null;

    const index = cast(size_t) base.vtblIndex;
    if (index >= class_.vtbl.length)
        return null;

    auto function_ = class_.vtbl[index].isFuncDeclaration;
    if (function_ is null || !sameFunctionSignature(function_, base))
        return null;

    return function_;
}

private imported!"dmd.func".FuncDeclaration matchingMemberFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (current; classHierarchy(class_))
        if (current.members !is null)
            foreach (member; *current.members)
                if (auto function_ = member.isFuncDeclaration)
                    if (sameFunctionSignature(function_, base))
                        return function_;

    return null;
}

private bool sameFunctionSignature(
    imported!"dmd.func".FuncDeclaration candidate,
    imported!"dmd.func".FuncDeclaration base,
) {
    if (functionName(candidate) != functionName(base))
        return false;

    if (candidate.type !is null &&
        base.type !is null &&
        candidate.type.equals(base.type))
        return true;

    if (candidate.parameters is null || base.parameters is null)
        return candidate.parameters is base.parameters;

    if (candidate.parameters.length != base.parameters.length)
        return false;

    foreach (index, parameter; *candidate.parameters) {
        auto baseParameter = (*base.parameters)[index];
        if (parameter.type is null || baseParameter.type is null)
            return false;
        if (!parameter.type.equals(baseParameter.type))
            return false;
    }

    return true;
}

private imported!"dmd.dclass".ClassDeclaration[] classHierarchy(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    imported!"dmd.dclass".ClassDeclaration[] classes;
    for (auto current = class_; current !is null; current = current.baseClass)
        classes ~= current;
    return classes;
}

private string functionName(
    imported!"dmd.func".FuncDeclaration function_,
) @safe {
    return function_.ident is null ? "" : function_.ident.toString.idup;
}

private string typeInfoName(imported!"dmd.mtype".Type type) {
    if (type is null)
        return "";

    auto classType = type.toBasetype.isTypeClass;
    if (classType !is null && classType.sym !is null)
        return classInfoName(classType.sym);

    return typeChars(type);
}

private string classInfoName(imported!"dmd.dclass".ClassDeclaration class_) {
    import std.conv: text;
    return text(class_.toPrettyChars);
}

private imported!"dmd.mtype".Type typeidObjectType(
    imported!"dmd.expression".TypeidExp typeid_,
) {
    if (auto type = cast(imported!"dmd.mtype".Type) typeid_.obj)
        return type;

    if (auto expression = cast(imported!"dmd.expression".Expression) typeid_.obj)
        return expression.type;

    return null;
}

private imported!"dmd.mtype".Type symbolOffsetTypeInfoType(
    imported!"dmd.expression".SymOffExp symbol,
) {
    auto typeInfo = symbol.var.isTypeInfoDeclaration;
    return typeInfo is null ? null : typeInfo.tinfo;
}

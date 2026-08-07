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
        AssertDiagnostic, AssocArrayKeyField, AssocArrayKeyLayout,
        CatchClause, ClassInfo, CompiledFunction,
        Instruction, NativeCall, Op, Program,
        ResultType, ScalarType, StructDisplayField,
        VirtualFunction, appendElementOp, assocArrayKeyIsArrayFlag,
        assocArrayKeyIsStructLayoutFlag, concatArraysOp, dupArrayOp,
        indexLoadOp, indexStoreOp, isSigned,
        nativeArgumentSlotSize, noCatchObjectField, noExceptionClass,
        noOutParameterOffset, pointerLoadOp, pointerSliceOp, pointerStoreOp,
        size, sliceCopyOp, sliceDescriptorLengthOffset, sliceDescriptorSize,
        sliceEqualOp, sliceFillOp, subSliceOp;
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AddAssignExp, AddrExp, ArrayLengthExp, ArrayLiteralExp,
        AssocArrayLiteralExp, AssertExp,
        AssignExp, BinAssignExp, BinExp, BlitExp, CallExp, CastExp,
        CatAssignExp,
        CatElemAssignExp, CatExp,
        CmpExp, CondExp, ConstructExp, DelegateFuncptrExp, DelegatePtrExp,
        DivExp, DotIdExp, DotVarExp, Expression,
        IdentityExp, IndexExp, LogicalExp, MulExp, FuncExp, DelegateExp,
        NegExp, NewExp, NotExp, OrExp, PostExp, PreExp, PtrExp, RealExp,
        SliceExp,
        StringExp, StructLiteralExp, SymOffExp, ThrowExp, TupleExp, TypeidExp;
    import dmd.arraytypes: Expressions;
    import dmd.dclass: ClassDeclaration;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Catch, Statement;

    private Program* _program;
    private FuncDeclaration[] _functions;
    private size_t[FuncDeclaration] _functionIndices;
    private ushort[imported!"dmd.dclass".ClassDeclaration] _classIndices;
    // Caches a mixed-field struct AA key type's `Program.assocArrayKeyLayouts`
    // index (`registerAssocArrayKeyLayout`), keyed by its `StructDeclaration`
    // so every access site for the same key type shares one layout entry.
    private ushort[imported!"dmd.dstruct".StructDeclaration]
        _assocArrayKeyLayoutIndices;
    private Instruction[] _code;
    private uint _frameOffset;
    // The high-water mark of `_frameOffset` across the current function body.
    // `frameSize` is computed from this peak so transient scopes that reuse
    // frame space (and any `_frameOffset` rewind) never under-size the frame.
    private uint _peakFrameOffset;
    // The one declaration authority. Every declaration is classified once and
    // carries its TypeFacts, storage owner, and representation-specific data.
    private DeclarationRecord[VarDeclaration] _declarations;
    private DeclarationRecord _unavailableDeclaration;
    // The function behind a compiler-generated static AA of delegate values is
    // not a declaration-root storage decision, so it remains a separate cache.
    private FuncDeclaration[VarDeclaration] _staticDelegateAssocArrays;
    private FuncDeclaration _latestStaticDelegateAssocArrayFunction;
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
    private ushort[VarDeclaration] _withPointers;
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
    // `_tryFinallyStack.length` recorded each time a `TryCatchStatement`'s own
    // protected try body starts compiling, innermost last, alongside that
    // try/catch's own catch types; popped when that body finishes. A `throw`
    // compiled while this is non-empty is lexically inside a try body some
    // sibling `catch` might still claim at runtime. When the thrown class is
    // known exactly (a `new`-expression throw), entries whose catch types
    // provably cannot match it are skipped when picking the guard depth (see
    // `throwExitedFinallyCount`); an unknown thrown class (e.g. `throw e;`)
    // conservatively treats the innermost entry as the guard, same as every
    // entry always was before that refinement.
    private CatchProtection[] _catchProtectedDepths;

    private static struct CatchProtection {
        size_t depth;
        ClassDeclaration[] catchClasses;
    }
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
    // A `Tarray` class field's shared array-literal default, computed once
    // per field and reused at every `new C()` site: see
    // `classFieldArraySharedDefaultOrNull`.
    private ClassFieldArrayDefault[VarDeclaration] _classFieldArrayDefaults;
    // Scalar locals' frame offsets, kept across functions. A nested struct's
    // method reads a captured
    // enclosing local through the struct's context pointer, which records the
    // enclosing frame's base; this map recovers the captured local's offset
    // within that frame at the point the method (a separate function) compiles.
    private ushort[VarDeclaration] _capturedOffsets;
    // The function that declared each `_capturedOffsets` entry -- the frame
    // that offset is relative to. A captured variable's owner may be more
    // than one nesting level above the function currently reading or writing
    // it; `capturedFrameIndex` walks the enclosing-function chain from the
    // current function to this owner, one received-context hop per level.
    private FuncDeclaration[VarDeclaration] _capturedOwners;
    // Captured locals that a frame-escaping delegate return
    // (`heapClosureContextOrNull`) has moved out of their owning frame into a
    // dedicated GC-heap block: `loadCapturedLocal`/`storeCapturedLocal`
    // dereference the received context word as that block's raw pointer
    // instead of resolving a live enclosing frame through
    // `capturedFrameIndex`. Scoped to the narrow shape
    // `heapClosureContextOrNull` recognises -- one or two scalar or pointer
    // values captured by exactly one escaping lambda, one nesting level, no
    // `this` combination.
    //
    // Keyed by BOTH the capturing lambda's own `FuncDeclaration` and the
    // captured variable, not the variable alone: a captured local's frame
    // offset is only meaningfully a heap-block pointer when read/written
    // from that SPECIFIC escaping lambda's own body. A sibling nested
    // function reading the same enclosing local (never itself heap-escaped)
    // still receives an ordinary frame-base context, and lambda bodies
    // compile lazily -- often after a LATER escape site has already
    // registered the variable here -- so keying by the variable alone would
    // make that sibling's unrelated frame-base context get misread as a raw
    // heap pointer. `loadCapturedLocal`/`storeCapturedLocal` gate the heap
    // path on `_currentFunction` (the function whose body is presently
    // compiling) matching the outer key.
    private bool[VarDeclaration][FuncDeclaration] _heapClosureVars;
    // A captured local that is heap-boxed before its enclosing function
    // returns keeps this function-local mirror. Later direct writes update
    // both the live frame slot and the closure environment.
    private ushort[VarDeclaration] _heapEscapingClosurePointers;
    private ushort[VarDeclaration] _heapEscapingClosureOffsets;
    // Each `_heapClosureVars` entry's own byte offset within its heap block,
    // set alongside it by `heapClosureContextOrNull`: a single captured local
    // sits at offset 0, and a second one sits at the next fixed
    // `size_t.sizeof`-wide slot (`heapClosureContextOrNull`'s own comment
    // explains why every slot is a full machine word wide regardless of the
    // captured value's own narrower width). `loadCapturedLocal`/
    // `storeCapturedLocal` divide this by the value's own natural width to
    // get the `pointerLoad*`/`pointerStore*` element index those ops expect.
    private ushort[VarDeclaration][FuncDeclaration] _heapClosureOffsets;
    // Lambdas that have already been CALLED, through a statically-known
    // callee (`compileDelegateCall`, e.g. `dg()` where `dg` is a
    // statically classified delegate local), via an ordinary frame-relative
    // context --
    // e.g. `auto dg = () => ++count; auto early = dg();` -- somewhere in the
    // function currently compiling. Merely materialising such a delegate
    // VALUE (declaring `dg`, or returning it) is not itself the hazard: the
    // hazard is a REAL CALL that forces the lambda's one shared body to
    // compile its captured-variable accesses against a frame-relative
    // context, when a LATER escape site (`return dg;`) in the same function
    // would otherwise heap-box the exact same body's accesses instead
    // (`heapClosureContextOrNull` declines for any such lambda when it
    // does). `compileDelegateCall` is only ever reached for a callee
    // declared as a local IN the function currently compiling
    // (delegate metadata is function-local), so marking here already scopes
    // this correctly with no extra bookkeeping. Building a heap
    // escape anyway would leave that one shared lambda body compiling its
    // captured-variable accesses against only one of the two contexts the
    // two different call sites (the earlier local call, and any call made
    // through the later heap-escaped return value) actually pass at run
    // time -- silently wrong for the loser, or, since the heap path
    // reinterprets a frame-base index as a raw pointer, a crash.
    private bool[FuncDeclaration] _frameContextDelegates;
    // The function whose body is currently being compiled; `_capturedOwners`
    // entries recorded while compiling it are attributed to it.
    private FuncDeclaration _currentFunction;
    private imported!"dmd.statement".CompoundAsmStatement _currentAsm;
    // The frame offset of the current method's hidden `this` block when it is a
    // nested struct whose first field (`vthis`) holds the enclosing-frame
    // context index; 0 otherwise. Set while compiling such a method.
    private bool _hasNestedContext;
    private bool _inUnittestEntry; // true only while compiling the entry
                                   // function when it is a UnitTestDeclaration
    private ResultType _currentReturnType; // result type of the function whose
                                           // body is currently being compiled
    private bool _currentReturnsRef;
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

    private static struct Place {
        private enum Kind {
            frame,
            captured,
            module_,
            pointer,
            dynamicIndex,
            assocIndex,
            slice,
        }

        Kind kind;
        ScalarType type;
        ushort offset;
        VarDeclaration declaration;
        bool isPointerValue;
        ScalarType pointerElement;
        ushort indexOffset;
        Type valueType;
        bool heapEscapingDelegate;
        bool declinesCapturingDelegate;
        ushort keyMeta;
        Place* container;
        ScalarType sliceElementType;
        uint sliceElementSize;
        bool sliceElementIsArray;
        bool isStaticSlice;
        DynamicArrayLocal sliceDescriptor;
        Type sliceBaseType;

        this(
            in Kind kind,
            in ScalarType type,
            in ushort offset,
            VarDeclaration declaration = null,
            in bool isPointerValue = false,
            in ScalarType pointerElement = ScalarType.void_,
            in ushort indexOffset = 0,
        ) {
            this.kind = kind;
            this.type = type;
            this.offset = offset;
            this.declaration = declaration;
            this.isPointerValue = isPointerValue;
            this.pointerElement = pointerElement;
            this.indexOffset = indexOffset;
        }

        this(
            in Kind kind,
            Type valueType,
            in ushort offset,
            in ushort indexOffset = 0,
            in bool heapEscapingDelegate = false,
            VarDeclaration declaration = null,
            in bool declinesCapturingDelegate = false,
        ) {
            this.kind = kind;
            this.valueType = valueType;
            this.offset = offset;
            this.indexOffset = indexOffset;
            this.heapEscapingDelegate = heapEscapingDelegate;
            this.declaration = declaration;
            this.declinesCapturingDelegate = declinesCapturingDelegate;
        }
    }

    private void compileFunctionBody(in size_t index) {
        // Only the entry (index 0) can be a unittest body; any lazily
        // compiled callee is an ordinary function.
        if (index > 0)
            _inUnittestEntry = false;

        auto function_ = _functions[index];

        _currentFunction = function_;
        _code = null;
        clearLocalDeclarations;
        _exceptionObjectLocals = null;
        _hasThis = false;
        _hasClassThis = false;
        _nestedContextOffset = ushort.max;
        _classThisOffset = ushort.max;
        _hasNestedContext = false;
        _thisLocal = StructLocal.init;
        _withPointers = null;
        _labelTargets = null;
        _pendingGotos = null;
        _loopStack = null;
        _switchStack = null;
        _tryFinallyStack = null;
        _catchProtectedDepths = null;
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
        _currentReturnsRef = function_.type.isTypeFunction !is null &&
            function_.type.isTypeFunction.isRef;
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
                registerCapturedOffset(function_.vthis, layout.thisOffset);
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
                registerCapturedOffset(function_.vthis, layout.classThisOffset);
        }
        if (function_.parameters !is null)
            foreach (parameterIndex; 0 .. function_.parameters.length) {
                auto parameter = (*function_.parameters)[parameterIndex];
                const offset = layout.offsets[parameterIndex];
                registerCapturedOffset(parameter, offset);

                if (parameterIsLazy(parameter)) {
                    registerFrameParameter(parameter, offset);
                    continue;
                }

                if (parameter.isReference &&
                    !declarationRecord(parameter).facts.isAggregate)
                {
                    auto record = registerReferenceDeclaration(parameter);
                    record.scalar = offset;
                    record.refPointer = record.facts.opcodeType;
                    continue;
                }

                // Aggregate reference parameters remain pointer places. All
                // loads, stores, field/index composition, and forwarding use
                // that one caller-storage address directly.
                if (parameter.isReference)
                    continue;

                registerFrameParameter(parameter, offset);
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

    private void registerFrameParameter(
        VarDeclaration parameter,
        in ushort offset,
    ) {
        import std.conv: text;

        auto record = registerFrameDeclaration(parameter);
        final switch (record.facts.representation)
            with (DeclarationRepresentation)
        {
            case unavailable:
                throw new Exception(text(
                    "Unsupported parameter in bytecode core: ",
                    declarationChars(parameter),
                ));
            case scalar:
                record.scalar = offset;
                return;
            case staticArray:
            case vector:
                record.staticArray = offset;
                return;
            case dynamicArray:
                record.dynamicArray = DynamicArrayLocal(
                    offset, dynamicArrayElementType(parameter.type),
                    arrayElementIsArray(parameter.type),
                );
                return;
            case pointer:
                record.scalar = offset;
                return;
            case struct_:
                record.struct_ = StructLocal(
                    offset, structDeclarationOf(parameter.type),
                );
                return;
            case delegate_:
                record.delegateRuntime = true;
                record.delegateParameter = offset;
                return;
            case complexDouble:
                record.scalar = offset;
                return;
            case lazyDelegate:
                record.lazyDelegate = offset;
                record.lazyDeclaration = true;
                return;
            case classPointer:
                record.scalar = offset;
                return;
            case assocArray:
                record.scalar = offset;
                return;
        }
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
        // `const` would qualify the DMD class reference and prevent restoring it.
        auto previousAsm = _currentAsm;
        _currentAsm = compound;
        scope(exit) _currentAsm = previousAsm;

        if (tryCompileAtomicLoadAsm(compound))
            return;
        if (tryCompileAtomicFetchAddAsm(compound))
            return;
        if (tryCompileAtomicExchangeAsm(compound))
            return;
        compileUnsignedMultiplyAsm(compound);
    }

    // `core.internal.atomic.atomicFetchAdd` returns the value which was in
    // `*dest` before adding `value`. Accept its complete 4- or 8-byte
    // naked-function sequence and lower it to one host atomic fetch-add.
    private bool tryCompileAtomicFetchAddAsm(
        imported!"dmd.statement".CompoundAsmStatement compound,
    ) {
        import quickbite.frontend.dmd.functions: inlineAsmInstructions;
        import std.conv: text;

        const instructions = inlineAsmInstructions(compound);
        if (instructions.length != 5 ||
            !isAsmIdentifier(instructions[0], 0, "naked") ||
            instructions[0].length != 1 ||
            !isAsmIdentifier(instructions[1], 0, "lock") ||
            instructions[1].length != 1 ||
            !isAsmIdentifier(instructions[2], 0, "xadd") ||
            !isAsmPunctuation(instructions[2], 1, "[") ||
            !isAsmIdentifier(instructions[2], 2, "RSI") ||
            !isAsmPunctuation(instructions[2], 3, "]") ||
            !isAsmPunctuation(instructions[2], 4, ",") ||
            !isAsmIdentifier(instructions[2], 5, "EDI", "RDI") ||
            instructions[2].length != 6 ||
            !isAsmIdentifier(instructions[3], 0, "mov") ||
            !isAsmIdentifier(instructions[3], 1, "EAX", "RAX") ||
            !isAsmPunctuation(instructions[3], 2, ",") ||
            !isAsmIdentifier(instructions[3], 3, "EDI", "RDI") ||
            instructions[3].length != 4 ||
            !isAsmIdentifier(instructions[4], 0, "ret") ||
            instructions[4].length != 1)
            return false;

        const destination = asmPointerLocal("dest");
        const value = asmLocal("value");
        const isDword = destination.pointerElement == ScalarType.uint_;
        const type = isDword ? ScalarType.uint_ : ScalarType.ulong_;
        if (destination.pointerElement != type ||
            value.type != type || functionResultType(asmOwner).scalar != type)
            throw new Exception(text(
                "Unsupported inline asm atomic-fetch-add operand: dest type=",
                asmParameterTypeChars("dest"),
                ", dest element=", destination.pointerElement,
                ", value type=", asmParameterTypeChars("value"),
                ", value element=", value.type,
                ", return element=", functionResultType(asmOwner).scalar,
                ".",
            ));

        const result = allocate(type);
        _code ~= Instruction(
            isDword ? Op.atomicFetchAdd4 : Op.atomicFetchAdd8,
            result, destination.offset, value.offset,
        );
        _code ~= Instruction(Op.ret, result);
        return true;
    }

    // `core.internal.atomic.atomicExchange` for a 4-byte value swaps `value`
    // with `*dest` and writes the former destination value to `storage`.
    // Accept only DRuntime's complete lock-xchg sequence, then lower it to one
    // host atomic exchange instead of treating it as an ordinary store.
    private bool tryCompileAtomicExchangeAsm(
        imported!"dmd.statement".CompoundAsmStatement compound,
    ) {
        import quickbite.frontend.dmd.functions: inlineAsmInstructions;

        const instructions = inlineAsmInstructions(compound);
        if (instructions.length != 6 ||
            !isAsmIdentifier(instructions[0], 0, "mov") ||
            !isAsmIdentifier(instructions[0], 1, "EAX") ||
            !isAsmPunctuation(instructions[0], 2, ",") ||
            !isAsmIdentifier(instructions[0], 3, "value") ||
            instructions[0].length != 4 ||
            !isAsmIdentifier(instructions[1], 0, "mov") ||
            !isAsmIdentifier(instructions[1], 1, "RCX") ||
            !isAsmPunctuation(instructions[1], 2, ",") ||
            !isAsmIdentifier(instructions[1], 3, "dest") ||
            instructions[1].length != 4 ||
            !isAsmIdentifier(instructions[2], 0, "lock") ||
            instructions[2].length != 1 ||
            !isAsmIdentifier(instructions[3], 0, "xchg") ||
            !isAsmPunctuation(instructions[3], 1, "[") ||
            !isAsmIdentifier(instructions[3], 2, "RCX") ||
            !isAsmPunctuation(instructions[3], 3, "]") ||
            !isAsmPunctuation(instructions[3], 4, ",") ||
            !isAsmIdentifier(instructions[3], 5, "EAX") ||
            instructions[3].length != 6 ||
            !isAsmIdentifier(instructions[4], 0, "lea") ||
            !isAsmIdentifier(instructions[4], 1, "RCX") ||
            !isAsmPunctuation(instructions[4], 2, ",") ||
            !isAsmIdentifier(instructions[4], 3, "storage") ||
            instructions[4].length != 4 ||
            !isAsmIdentifier(instructions[5], 0, "mov") ||
            !isAsmPunctuation(instructions[5], 1, "[") ||
            !isAsmIdentifier(instructions[5], 2, "RCX") ||
            !isAsmPunctuation(instructions[5], 3, "]") ||
            !isAsmPunctuation(instructions[5], 4, ",") ||
            !isAsmIdentifier(instructions[5], 5, "EAX") ||
            instructions[5].length != 6)
            return false;

        const value = asmLocal("value");
        const destination = asmPointerLocal("dest");
        const storage = asmLocal("storage");
        if (value.type != ScalarType.uint_ ||
            destination.pointerElement != ScalarType.uint_ ||
            storage.type != ScalarType.ulong_)
            throw new Exception("Unsupported inline asm atomic-exchange operand.");

        _code ~= Instruction(
            Op.atomicExchange4, storage.offset, destination.offset, value.offset,
        );
        return true;
    }

    // `core.internal.atomic.atomicLoad` uses a locked compare-and-exchange to
    // read `src`, then writes EAX/RAX through `resultValuePtr`. This accepts
    // only the complete 4- and 8-byte sequences DRuntime emits, and lowers
    // their signed and unsigned integer forms to one host atomic read rather
    // than pretending an ordinary pointer load has the same memory-order
    // semantics.
    private bool tryCompileAtomicLoadAsm(
        imported!"dmd.statement".CompoundAsmStatement compound,
    ) {
        import quickbite.frontend.dmd.functions: inlineAsmInstructions;
        import std.conv: text;

        const instructions = inlineAsmInstructions(compound);
        if (instructions.length != 10 ||
            !isAsmIdentifier(instructions[0], 0, "push") ||
            !isAsmIdentifier(instructions[0], 1, "RBX") ||
            instructions[0].length != 2 ||
            !isAsmIdentifier(instructions[1], 0, "mov") ||
            !isAsmIdentifier(instructions[1], 1, "RDX", "EDX") ||
            !isAsmPunctuation(instructions[1], 2, ",") ||
            !isAsmInteger(instructions[1], 3, "0") ||
            instructions[1].length != 4 ||
            !isAsmIdentifier(instructions[2], 0, "mov") ||
            !isAsmIdentifier(instructions[2], 1, "RAX", "EAX") ||
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
            !isAsmIdentifier(instructions[5], 5, "RDX", "EDX") ||
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
            !isAsmIdentifier(instructions[8], 5, "RAX", "EAX") ||
            instructions[8].length != 6 ||
            !isAsmIdentifier(instructions[9], 0, "pop") ||
            !isAsmIdentifier(instructions[9], 1, "RBX") ||
            instructions[9].length != 2)
            return false;

        const source = asmPointerLocal("src");
        const result = asmPointerLocal("resultValuePtr");
        const isDword = source.pointerElement == ScalarType.int_ ||
            source.pointerElement == ScalarType.uint_;
        const width = isDword ? uint.sizeof : ulong.sizeof;
        if (!isDword && source.pointerElement != ScalarType.long_ &&
                source.pointerElement != ScalarType.ulong_)
            throw new Exception(text(
                "Unsupported inline asm atomic-load operand: src type=",
                asmParameterTypeChars("src"),
                ", src element=", source.pointerElement,
                ", resultValuePtr type=",
                asmParameterTypeChars("resultValuePtr"),
                ", result element=", result.pointerElement,
                ", instruction width=", width,
                ".",
            ));

        const loaded = allocate(source.pointerElement);
        const zero = compileSizeConstant(0);
        _code ~= Instruction(
            isDword ? Op.atomicLoad4 : Op.atomicLoad8,
            loaded,
            source.offset,
            zero,
        );
        emitPointerStore(loaded, result.offset, zero, width);
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

        // The DRuntime inline-asm operands are function parameters. Resolve
        // those first: the declaration registry also contains
        // compiler-introduced variables, and associative-array iteration does
        // not provide a stable choice when more than one declaration has the
        // same identifier.
        // `const` would qualify the DMD class and its parameter declarations.
        auto function_ = asmOwner;
        if (function_.parameters !is null)
            foreach (parameter; *function_.parameters) {
                if (parameter.ident is null || parameter.ident.toString != name)
                    continue;
                if (auto element = declarationRecordView(parameter).pointerOrNull)
                    return Operand(declarationRecord(parameter).scalar, ScalarType.ulong_, true, *element);
                throw new Exception(text("Unsupported inline asm pointer operand: ", name));
            }

        foreach (declaration, record; _declarations) {
            auto offset = record.scalarOrNull;
            if (record.owner !is _currentFunction || offset is null)
                continue;
            if (declaration.ident is null ||
                declaration.ident.toString != name)
                continue;
            if (auto element = declarationRecordView(declaration).pointerOrNull)
                return Operand(*offset, ScalarType.ulong_, true, *element);
            throw new Exception(text("Unsupported inline asm pointer operand: ", name));
        }
        throw new Exception(text("Unsupported inline asm pointer operand: ", name));
    }

    private Operand asmLocal(in string name) {
        import std.conv: text;

        // `const` would qualify the DMD class and its parameter declarations.
        auto function_ = asmOwner;
        if (function_.parameters !is null)
            foreach (parameter; *function_.parameters) {
                if (parameter.ident !is null && parameter.ident.toString == name)
                    return asmOperand(parameter);
            }

        foreach (declaration, record; _declarations) {
            if (record.owner !is _currentFunction ||
                record.scalarOrNull is null)
                continue;
            if (declaration.ident !is null &&
                declaration.ident.toString == name) {
                return asmOperand(declaration);
            }
        }
        throw new Exception(text("Unsupported inline asm operand: ", name));
    }

    // Error diagnostics for recognized DRuntime inline asm must identify the
    // actual instantiated parameter types. Operand metadata alone loses type
    // qualifiers and aliases, which is precisely what distinguishes a new
    // atomic specialization from the supported signed/unsigned integer forms.
    private string asmParameterTypeChars(in string name) {
        import std.conv: text;

        // `const` would qualify the DMD class and its parameter declarations.
        auto function_ = asmOwner;
        if (function_.parameters !is null)
            foreach (parameter; *function_.parameters)
                if (parameter.ident !is null && parameter.ident.toString == name)
                    return typeChars(parameter.type);
        return text("<missing parameter ", name, ">");
    }

    private imported!"dmd.func".FuncDeclaration asmOwner() {
        import quickbite.frontend.dmd.functions: inlineAsmOwner;

        // `const` would qualify the DMD class reference and make it unreturnable.
        auto owner = inlineAsmOwner(_currentAsm);
        return owner is null ? _currentFunction : owner;
    }

    private Operand asmOperand(VarDeclaration declaration) {
        import dmd.astenums: TY;
        import std.conv: text;

        const type = declaration.type.toBasetype.ty;
        if (type == TY.Tbool)
            return Operand(declarationRecord(declaration).scalar, ScalarType.bool_);
        if (type == TY.Tuns32)
            return Operand(declarationRecord(declaration).scalar, ScalarType.uint_);
        if (type == TY.Tuns64)
            return Operand(declarationRecord(declaration).scalar, ScalarType.ulong_);
        throw new Exception(text(
            "Unsupported inline asm operand type: ",
            typeChars(declaration.type),
        ));
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
    // `(*__withSym).field`; resolve the subject once and bind the synthetic
    // pointer to its place address. For an enum/type subject there is no
    // runtime binding (DMD has already constant-folded the members).
    private void compileWithStatement(
        imported!"dmd.statement".WithStatement with_,
    ) {
        if (with_.wthis !is null)
            if (auto place = placeOrNull(with_.exp))
                _withPointers[with_.wthis] = addressOfPlace(*place).offset;

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
    // fall-through edge. A `goto`/`break`/`continue`/`throw` that leaves the body
    // runs the finally inline first (see `runExitedFinally`, `throwExitedFinallyCount`);
    // no runtime handler exists for the throw edge, since which scopes a throw
    // actually exits is resolved at compile time when the thrown class is known
    // exactly, or from the enclosing catch nesting otherwise (see
    // `throwExitedFinallyCount`).
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

    // The count of innermost `_tryFinallyStack` scopes a `throw` at the
    // current compile point unconditionally exits. Unlike `return`/`goto`/
    // `break`/`continue`, a `throw` can be intercepted by a sibling `catch`
    // whose match is generally a runtime, dynamic-type decision, so scopes at
    // or below a still-open catch-protected try body (`_catchProtectedDepths`)
    // are left for the runtime handler, or for that catch handler's own later
    // exit, to resolve -- never inlined here.
    //
    // `exactThrownClass` is the thrown value's exact runtime class when the
    // throw is a direct `new C(...)` (null otherwise, e.g. `throw e;`). With
    // it known, entries whose catch types can never match it (neither `C` nor
    // an ancestor of `C`) are skipped when picking the guard: that catch
    // can't be where this throw actually lands, so its try body's finally
    // scopes must not be excluded from this count on its account. The walk
    // stops at the innermost entry that could still match, or -- if none
    // could -- exits every scope, matching the fully-dynamic-class fallback
    // when `exactThrownClass` is null.
    private size_t throwExitedFinallyCount(ClassDeclaration exactThrownClass = null) {
        size_t guardDepth;
        foreach_reverse (entry; _catchProtectedDepths) {
            if (exactThrownClass !is null &&
                !catchesCouldMatch(exactThrownClass, entry.catchClasses))
                continue;
            guardDepth = entry.depth;
            break;
        }
        return _tryFinallyStack.length - guardDepth;
    }

    // Whether any of `catchClasses` could catch a value whose exact runtime
    // class is `thrown` -- true iff `thrown` is `catchClass_` or one of its
    // subclasses.
    private static bool catchesCouldMatch(
        ClassDeclaration thrown,
        in ClassDeclaration[] catchClasses,
    ) {
        foreach (catchClass_; catchClasses)
            for (auto current = thrown; current !is null; current = current.baseClass)
                if (current is catchClass_)
                    return true;
        return false;
    }

    private void compileReturnStatement(
        imported!"dmd.statement".ReturnStatement return_,
    ) {
        ushort result;
        bool hasResult;

        if (_currentReturnsRef) {
            auto address = placeAddressOrNull(return_.exp);
            if (address is null)
                if (return_.exp.isAddrExp !is null) {
                    address = new Operand;
                    *address = compileExpression(return_.exp);
                }
            if (address is null)
                throw new Exception("Unsupported ref return in bytecode core");
            result = address.offset;
            hasResult = true;
        } else if (_currentReturnType.isArray && _currentReturnType.isStaticArray) {
            // `return arr;` for a `string[N]`/`wstring[N]`/`dstring[N]` result:
            // the `ret` instruction below copies `staticArraySize` inline bytes
            // from `result`, not a 16-byte dynamic-array descriptor
            // (the dynamic-array path) would hand back the wrong shape.
            result = staticArrayReturnOffset(return_.exp);
            hasResult = true;
        } else if (_currentReturnType.isArray) {
            result = dynamicArrayDescriptor(return_.exp).offset;
            hasResult = true;
        } else if (_currentReturnType.isStruct) {
            if (auto place = placeOrNull(return_.exp))
                result = loadPlace(*place).offset;
            else if (auto literal = return_.exp.isStructLiteralExp)
                // `return S(() => ...);`: a top-level `Tdelegate` field of
                // the directly-returned literal gets the same heap-escape
                // treatment `compileDelegateReturn` gives a bare returned
                // delegate -- see `structLiteralReturnOffset`.
                result = structLiteralReturnOffset(literal);
            else
                // `return structValue;`: the result block lives at the struct
                // operand's inline base; `ret` copies its `structSize` bytes
                // back to the caller's destination.
                result = structOperandOffset(return_.exp);
            hasResult = true;
        } else if (_currentReturnType.isDelegate) {
            result = compileDelegateReturn(return_.exp);
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

        if (auto place = placeOrNull(source))
            return loadPlace(*place).offset;

        const totalSize = typeFacts(source.type).byteWidth;
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

        if (tryCatch._body !is null) {
            _catchProtectedDepths ~= CatchProtection(
                _tryFinallyStack.length, catchTypeClasses((*tryCatch.catches)[]),
            );
            compileNestedStatement(tryCatch._body);
            _catchProtectedDepths.length -= 1;
        }

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

    // The declared class of each of `catches`, for the static
    // `catchesCouldMatch` check in `throwExitedFinallyCount`. Called only
    // after `compileTryCatchStatement` has already resolved every one of
    // these same catch types via `catchClass` (which throws on an
    // unsupported catch type), so resolution here cannot fail in practice;
    // an unresolvable type is skipped rather than trusted with `assert`, so
    // a future relaxation of `catchClass` fails safe here too.
    private static ClassDeclaration[] catchTypeClasses(Catch[] catches) {
        ClassDeclaration[] result;
        foreach (catch_; catches) {
            auto type = catch_.type;
            if (type is null && catch_.var !is null)
                type = catch_.var.type;
            if (type is null)
                continue;
            if (auto class_ = type.toBasetype.isClassHandle)
                result ~= class_;
        }
        return result;
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

        auto record = declarationRecord(variable);
        if (record.facts.representation ==
            DeclarationRepresentation.classPointer)
            registerFrameDeclaration(variable).scalar = objectOffset;

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
        const compareWidth = dynamicArrayElementSize(selectorExpression.type);

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
            emitSliceEqual(matches, selector.offset, literalOffset, compareWidth);
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

        // Known only for a direct `new C(...)` throw -- its exact runtime
        // class, which `throwExitedFinallyCount` uses to rule out catch-
        // protected scopes whose declared type provably can't catch it (see
        // there). A rethrow of a caught variable (`throw e;`) has no such
        // exact class, so falls back to the conservative innermost-guard
        // behaviour below.
        auto thrownNew = expression.isNewExp;
        if (thrownNew is null)
            thrownNew = nestedNewExpression(originalExpression);
        auto exactClass = thrownNew is null ? null : thrownClass(thrownNew);

        if (auto new_ = thrownNew) {
            if (auto class_ = exactClass) {
                auto messageExpression = thrownMessageExpression(new_);
                if (messageExpression is null)
                    messageExpression =
                        thrownCallMessageExpression(originalExpression);
                if (messageExpression !is null &&
                    messageExpression.type !is null &&
                    isStringType(messageExpression.type))
                {
                    const messageOffset =
                        dynamicArrayDescriptor(messageExpression).offset;
                    emitThrowString(messageOffset, registerClass(class_), class_);
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

        const exitCount = throwExitedFinallyCount(exactClass);
        if (exitCount != 0)
            runExitedFinally(exitCount);

        _code ~= Instruction(Op.throwObject, object.offset);
        const type = throwResultType(resultType);
        return Operand(allocate(type), type);
    }

    private void emitThrowString(
        in ushort messageOffset,
        in ushort classIndex,
        ClassDeclaration exactClass = null,
    ) {
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
        const exitCount = throwExitedFinallyCount(exactClass);
        if (exitCount != 0) {
            auto savedException = _pendingFinallyExceptionMessageOffset;
            auto savedExceptionClass = _pendingFinallyExceptionClassIndex;
            _pendingFinallyExceptionMessageOffset = messageOffset;
            _pendingFinallyExceptionClassIndex = classIndex;
            runExitedFinally(exitCount);
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
                    cast(ushort) typeFacts(expression.type).byteWidth,
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
                if (auto pointer = declaration in _withPointers)
                    return Operand(
                        *pointer, ScalarType.ulong_, true, ScalarType.void_,
                    );

            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declarationRecordView(declaration).scalarOrNull) {
                    if (declarationRecordView(declaration).structPointerOrNull)
                        return Operand(
                            *existing,
                            ScalarType.ulong_,
                            true,
                            ScalarType.void_,
                        );
                    if (auto element = declarationRecordView(declaration).refPointerOrNull)
                        return loadThroughPointer(
                            Operand(
                                *existing,
                                ScalarType.ulong_,
                                true,
                                *element,
                            ),
                            compileSizeConstant(0),
                        );
                    if (declarationRecordView(declaration).complexDoubleOrNull)
                        return Operand(
                            *existing,
                            ScalarType.void_,
                            false,
                            ScalarType.void_,
                            true,
                        );
                    if (declarationRecordView(declaration).classPointerOrNull)
                        return Operand(
                            *existing,
                            ScalarType.ulong_,
                            true,
                            ScalarType.void_,
                        );
                    if (auto element = declarationRecordView(declaration).pointerOrNull)
                        return Operand(
                            *existing, ScalarType.ulong_, true, *element,
                        );
                    return Operand(*existing, scalarType(declaration.type));
                }
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declarationRecordView(declaration).staticArrayOrNull)
                    return Operand(*existing, ScalarType.void_);
            if (expression.type !is null &&
                (isDynamicArrayArgument(expression) ||
                    isStringType(expression.type)))
                if (auto place = placeOrNull(expression))
                    return loadPlaceValue(*place);
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto moduleVariable =
                        moduleDeclarationRecord(declaration).moduleScalarOrNull) {
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
                    if (moduleVariable.isPointer)
                        return Operand(
                            offset,
                            ScalarType.ulong_,
                            true,
                            moduleVariable.pointerElement,
                        );
                    return Operand(offset, moduleVariable.type);
                }

            // A module-level (`__gshared`/`static`) `cdouble` variable:
            // materialise its 16-byte `{re, im}` pair out of `moduleData`
            // into a fresh frame slot, the same way a module pointer/AA/
            // delegate read does (`Op.loadModule`).
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto moduleVariable =
                        moduleDeclarationRecord(declaration).moduleComplexOrNull) {
                    const offset = allocateComplexDouble;
                    _code ~= Instruction(
                        Op.loadModule,
                        offset,
                        moduleVariable.offset,
                        cast(ushort) complexDoubleSize,
                    );
                    return complexDoubleOperand(offset);
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
                    cast(ushort) TypeFacts.fromOpcode(
                        ScalarType.bool_,
                    ).byteWidth,
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
            return compileScalarIntegerCompoundAssign(
                subtractAssign,
                Op.subInt4,
                Op.subInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto multiplyAssign = expression.isMulAssignExp)
            return compileScalarIntegerCompoundAssign(
                multiplyAssign,
                Op.mulInt4,
                Op.mulInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto rightShiftAssign = expression.isShrAssignExp)
            return compileScalarIntegerCompoundAssign(
                rightShiftAssign,
                Op.shrInt4,
                Op.shrInt4,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto leftShiftAssign = expression.isShlAssignExp)
            return compileScalarIntegerCompoundAssign(
                leftShiftAssign,
                Op.shlInt4,
                Op.shlInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto orAssign = expression.isOrAssignExp)
            return compileScalarIntegerCompoundAssign(
                orAssign,
                Op.bitOrInt4,
                Op.bitOrInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto andAssign = expression.isAndAssignExp)
            return compileScalarIntegerCompoundAssign(
                andAssign,
                Op.bitAndInt4,
                Op.bitAndInt8,
                "Unsupported compound assignment in bytecode core: ",
            );

        if (auto xorAssign = expression.isXorAssignExp)
            return compileScalarIntegerCompoundAssign(
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
        // over a `SliceExp` lvalue (`buf[] = '\xff'`). `this = rhs;` inside a
        // struct method -- e.g. the compiler-synthesized `opAssign` a
        // postblit-typed struct's whole-local reassignment lowers through --
        // arrives the same way over a `ThisExp` lvalue. Inserting a
        // struct-typed value into a fresh associative-array slot from an
        // rvalue (`Point[int] a; a[1] = Point(10, 20);`) arrives the same
        // way over an `IndexExp` lvalue -- DMD blits directly into the
        // freshly obtained slot rather than calling the value type's
        // `opAssign` (if any), since there is no prior value to assign
        // over.
        if (auto construct = expression.isConstructExp)
            if (construct.e1.isDotVarExp !is null ||
                construct.e1.isVarExp !is null ||
                construct.e1.isSliceExp !is null ||
                construct.e1.isThisExp !is null ||
                construct.e1.isIndexExp !is null)
                return compileAssignExpression(construct);
        if (auto blit = expression.isBlitExp)
            if (blit.e1.isDotVarExp !is null ||
                blit.e1.isVarExp !is null ||
                blit.e1.isSliceExp !is null ||
                blit.e1.isThisExp !is null)
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

        if (auto call = expression.isCallExp) {
            auto function_ = callFunction(call);
            auto functionType = function_ is null
                ? null : function_.type.isTypeFunction;
            const result = compileCall(call);
            if (result.isPointer &&
                functionType !is null && functionType.isRef &&
                assocArrayHook(function_) == AssocArrayHook.none &&
                !typeFacts(call.type).isAggregate)
                return loadThroughPointer(
                    result, compileSizeConstant(0),
                );
            return result;
        }

        if (auto assert_ = expression.isAssertExp) {
            compileAssert(assert_);
            return Operand.init;
        }

        if (auto post = expression.isPostExp)
            return compilePostIncrement(post);

        if (auto length = expression.isArrayLengthExp)
            return compileArrayLength(length);

        if (auto vectorArray = expression.isVectorArrayExp)
            if (auto place = placeOrNull(vectorArray.e1))
                return loadPlaceValue(*place);

        if (auto address = expression.isAddrExp) {
            if (auto pointer = placeAddressOrNull(address.e1))
                return *pointer;
            if (auto symbol = address.e1.isSymOffExp)
                if (auto pointer = symbolAddress(
                        symbol.var.isVarDeclaration,
                        symbol.offset,
                        symbol.type,
                    ))
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
            if (auto pointer = symbolAddress(
                    symOff.var.isVarDeclaration,
                    symOff.offset,
                    symOff.type,
                ))
                return *pointer;
            // `&f` can also arrive as a `SymOffExp` over a function symbol;
            // the function-pointer value is its VM function index.
            if (auto function_ = symOff.var.isFuncDeclaration)
                return functionPointer(function_);
        }

        if (expression.isPtrExp !is null)
            if (auto place = placeOrNull(expression))
                return loadPlaceValue(*place);

        if (auto index = expression.isIndexExp) {
            if (auto place = placeOrNull(index))
                return loadPlaceValue(*place);
        }

        if (expression.isSliceExp !is null)
            if (auto place = placeOrNull(expression))
                return loadPlaceValue(*place);

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

        if (expression.isDotVarExp !is null) {
            if (auto place = placeOrNull(expression))
                return loadPlaceValue(*place);
        }

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
                // A lambda literal that captures nothing from its enclosing
                // scope is, by DMD's own default, typed as a plain function
                // pointer (`int function()`), not a delegate -- only an
                // explicitly delegate-typed target (`int delegate() d = ()
                // => 42;`) retypes it to `Tdelegate` during semantic. Route
                // that shape through the same single-word function-pointer
                // value `&f` builds, since a pointer-typed local's
                // declaration only accepts an `isPointer` operand, not the
                // 16-byte `{functionIndex, context}` pair below.
                import dmd.astenums: TY;
                if (literal.type !is null &&
                    literal.type.toBasetype.ty == TY.Tpointer)
                    return functionPointer(literal.fd);

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
        zeroFrameBlock(offset, typeFacts(literal.type).byteWidth);
        compileStructLiteralInto(offset, literal);
        return Operand(offset, ScalarType.void_);
    }

    // The inline frame offset of a struct literal that is itself the direct
    // `return` expression (`return Counter(() => ++count);`,
    // `compileReturnStatement`'s struct branch): identical to
    // `compileStructLiteralOperand` above except it passes
    // `isReturnEscaping: true` down to `compileStructLiteralInto`, so any
    // `Tdelegate` field that is a capturing lambda/nested-function reference
    // -- at any nesting depth inside this literal, since a nested `Tstruct`
    // field forwards the same flag -- gets the same heap-escape treatment
    // `compileDelegateReturn` gives a bare returned delegate: a `return`
    // statement is the last thing its enclosing function executes, so
    // heap-snapshotting the capture here is exactly as sound as it is for a
    // directly-returned delegate. A struct-literal rvalue anywhere else
    // (a plain local's own initializer, a call argument, ...) keeps the
    // ordinary frame-relative path, since its own frame is not (necessarily)
    // going away.
    private ushort structLiteralReturnOffset(StructLiteralExp literal) {
        const offset = allocateStructBlock(literal.type);
        zeroFrameBlock(offset, typeFacts(literal.type).byteWidth);
        compileStructLiteralInto(offset, literal, true);
        return offset;
    }

    // `i++` on an integer local, struct field, or dereferenced pointer: copy
    // the old value to the result slot, then add `e2` (the increment) to the
    // lvalue's slot. Scoped to integer lvalues, matching compound assignment.
    private Operand compilePostIncrement(PostExp post) {
        import dmd.tokens: EXP;
        import std.conv: text;

        auto place = placeOrNull(post.e1);
        if (place is null || !isIntegerScalar(place.type))
            throw new Exception(text(
                "Unsupported post-increment in bytecode core: ",
                expressionChars(post),
            ));

        const lvalue = loadPlace(*place);
        const result = allocate(place.type);
        _code ~= Instruction(
            Op.copy, result, lvalue.offset, cast(ushort) size(place.type),
        );

        // `PostExp.e2` is always the literal `1`; `post.op` (`plusPlus` vs
        // `minusMinus`) decides whether we add or subtract it.
        const increment = compileExpression(post.e2);
        const eightByte = isEightByteInteger(place.type);
        const stepOp = post.op == EXP.minusMinus
            ? (eightByte ? Op.subInt8 : Op.subInt4)
            : (eightByte ? Op.addInt8 : Op.addInt4);
        _code ~= Instruction(
            stepOp, lvalue.offset, lvalue.offset, increment.offset,
        );
        storePlace(*place, lvalue);
        return Operand(result, place.type);
    }

    private Place* placeOrNull(Expression expression) {
        const facts = typeFacts(expression.type);
        return resolvePlace(expression, facts);
    }

    private Place* resolvePlace(Expression expression, in TypeFacts facts) {
        if (auto cast_ = expression.isCastExp)
            return placeOrNull(cast_.e1);
        if (auto vectorArray = expression.isVectorArrayExp)
            return placeOrNull(vectorArray.e1);
        if (auto conditional = expression.isCondExp) {
            const condition = compileBoolCondition(conditional.econd);
            const pointer = allocateBytes(
                cast(uint) size_t.sizeof, size_t.sizeof,
            );
            const falseJump = emitJumpIfFalse(condition);
            auto whenTrue = placeOrNull(conditional.e1);
            if (whenTrue is null)
                return null;
            const whenTrueAddress = addressOfPlace(*whenTrue);
            _code ~= Instruction(
                Op.copy, pointer, whenTrueAddress.offset,
                cast(ushort) size_t.sizeof,
            );
            const endJump = emitJump;
            patchJump(falseJump);
            auto whenFalse = placeOrNull(conditional.e2);
            if (whenFalse is null)
                return null;
            const whenFalseAddress = addressOfPlace(*whenFalse);
            _code ~= Instruction(
                Op.copy, pointer, whenFalseAddress.offset,
                cast(ushort) size_t.sizeof,
            );
            patchJump(endJump);
            return pointerPlace(pointer, expression.type);
        }
        if (auto symbol = expression.isSymOffExp) {
            // DMD type APIs return mutable class references.
            auto pointee = symbol.type.toBasetype.nextOf;
            if (pointee is null)
                return null;
            if (auto address = symbolAddress(
                    symbol.var.isVarDeclaration,
                    symbol.offset,
                    symbol.type,
                ))
                return pointerPlace(address.offset, pointee);
            return null;
        }
        if (auto call = expression.isCallExp) {
            auto function_ = callFunction(call);
            if (facts.isAggregate && function_ !is null &&
                function_.isCtorDeclaration !is null) {
                Operand receiver;
                compileCall(call, &receiver);
                return pointerPlace(receiver.offset, expression.type);
            }
            auto type = callTypeFunction(call);
            if (type !is null && type.isRef)
                return pointerPlace(
                    compileCall(call).offset, expression.type,
                );
            if (facts.isAggregate) {
                const value = compileCall(call);
                return new Place(
                    Place.Kind.frame, expression.type, value.offset,
                );
            }
            return null;
        }
        if (auto variable = expression.isVarExp) {
            auto declaration = variable.var.isVarDeclaration;
            if (declaration is null)
                return null;
            // DeclarationRecord's typed accessors return mutable pointers.
            auto record = declarationRecordView(declaration);
            if (facts.isAggregate) {
                if (declaration.isParameter && declaration.isReference)
                    if (auto offset = declaration in _capturedOffsets)
                        return new Place(
                            Place.Kind.pointer, expression.type,
                            *offset, compileSizeConstant(0),
                            isDelegateValueType(expression.type),
                            null,
                            isDelegateValueType(expression.type),
                        );
                if (auto slot = record.scalarOrNull)
                    if (record.refPointerOrNull !is null)
                        return pointerPlace(*slot, expression.type);
                if (auto local = record.struct_OrNull)
                    return new Place(
                        Place.Kind.frame, expression.type, local.offset,
                    );
                if (auto offset = record.staticArrayOrNull)
                    return new Place(
                        Place.Kind.frame, expression.type, *offset,
                    );
                if (auto local = record.dynamicArrayOrNull)
                    return new Place(
                        Place.Kind.frame, expression.type, local.offset,
                    );
                if (record.complexDoubleOrNull !is null)
                    if (auto slot = record.scalarOrNull)
                        return new Place(
                            Place.Kind.frame, expression.type, *slot,
                        );
                // DeclarationRecord's typed accessors return mutable pointers.
                auto module_ = moduleDeclarationRecord(declaration);
                if (auto value = module_.moduleStructOrNull)
                    return new Place(
                        Place.Kind.module_, expression.type, value.offset,
                    );
                if (auto value = module_.moduleStaticArrayOrNull)
                    return new Place(
                        Place.Kind.module_, expression.type, value.offset,
                    );
                if (auto value = module_.moduleDynamicArrayOrNull)
                    return new Place(
                        Place.Kind.module_, expression.type, value.offset,
                    );
                if (auto value = module_.moduleDelegateOrNull)
                    return new Place(
                        Place.Kind.module_, expression.type, value.offset,
                    );
                if (auto value = module_.moduleComplexOrNull)
                    return new Place(
                        Place.Kind.module_, expression.type, value.offset,
                    );
                if (auto local = record.delegate_OrNull)
                    return new Place(
                        Place.Kind.frame, expression.type, local.offset,
                        0, false,
                        declaration,
                    );
                if (auto local = record.delegateParameterOrNull)
                    return new Place(
                        Place.Kind.frame, expression.type, *local,
                        0, false,
                        declaration,
                        declaration.isReference && declaration.isParameter,
                    );
                if (_hasNestedContext)
                    if (auto captured = declaration in _capturedOffsets) {
                        if (declaration.isThisDeclaration !is null) {
                            const pointer = loadCapturedLocal(
                                declaration, *captured,
                            );
                            if (pointer.isPointer)
                                return pointerPlace(
                                    pointer.offset, expression.type,
                                );
                        }
                        return new Place(
                            Place.Kind.captured,
                            expression.type,
                            *captured,
                            0,
                            false,
                            declaration,
                        );
                    }
                return null;
            }
            if (_hasNestedContext && !declaration.isReference)
                if (auto offset = declaration in _capturedOffsets)
                    if (_capturedOwners[declaration] !is _currentFunction)
                        return new Place(
                            Place.Kind.captured,
                            scalarType(declaration.type), *offset,
                            declaration,
                            isPointerLikePlaceType(declaration.type),
                            isPointerType(declaration.type)
                                ? pointerElementScalar(declaration.type)
                                : ScalarType.void_,
                        );
            if (auto slot = record.scalarOrNull) {
                if (auto element = record.refPointerOrNull) {
                    if (_hasNestedContext && declaration in _capturedOffsets &&
                        _capturedOwners[declaration] !is _currentFunction) {
                        const pointer = allocateBytes(
                            cast(uint) size_t.sizeof, size_t.sizeof,
                        );
                        _code ~= Instruction(
                            Op.frameLoad, pointer,
                            capturedFrameIndex(
                                _capturedOwners[declaration], *slot,
                            ),
                            cast(ushort) size_t.sizeof,
                        );
                        return new Place(
                            Place.Kind.pointer,
                            *element,
                            pointer,
                            null,
                            isPointerLikePlaceType(declaration.type),
                            isPointerType(declaration.type)
                                ? pointerElementScalar(declaration.type)
                                : ScalarType.void_,
                            compileSizeConstant(0),
                        );
                    }
                    return new Place(
                        Place.Kind.pointer,
                        *element,
                        *slot,
                        null,
                        isPointerLikePlaceType(declaration.type),
                        isPointerType(declaration.type)
                            ? pointerElementScalar(declaration.type)
                            : ScalarType.void_,
                        compileSizeConstant(0),
                    );
                }
                auto pointerElement = record.pointerOrNull;
                return new Place(
                    Place.Kind.frame, scalarType(declaration.type), *slot,
                    declaration,
                    pointerElement !is null,
                    pointerElement is null
                        ? ScalarType.void_
                        : *pointerElement,
                );
            }
            if (_hasNestedContext)
                if (auto offset = declaration in _capturedOffsets) {
                    if (declaration.isParameter && declaration.isReference) {
                        const pointer = allocateBytes(
                            cast(uint) size_t.sizeof, size_t.sizeof,
                        );
                        _code ~= Instruction(
                            Op.frameLoad, pointer,
                            capturedFrameIndex(
                                _capturedOwners[declaration], *offset,
                            ),
                            cast(ushort) size_t.sizeof,
                        );
                        return new Place(
                            Place.Kind.pointer,
                            scalarType(declaration.type),
                            pointer,
                            null,
                            isPointerLikePlaceType(declaration.type),
                            isPointerType(declaration.type)
                                ? pointerElementScalar(declaration.type)
                                : ScalarType.void_,
                            compileSizeConstant(0),
                        );
                    }
                    return new Place(
                        Place.Kind.captured,
                        scalarType(declaration.type), *offset,
                        declaration,
                        isPointerLikePlaceType(declaration.type),
                        isPointerType(declaration.type)
                            ? pointerElementScalar(declaration.type)
                            : ScalarType.void_,
                    );
                }
            if (auto moduleVariable = moduleDeclarationRecord(declaration).moduleScalarOrNull)
                return new Place(
                    Place.Kind.module_, moduleVariable.type,
                    moduleVariable.offset,
                );
            return null;
        }
        if (facts.isAggregate &&
            (expression.isThisExp !is null ||
                expression.isSuperExp !is null) && _hasThis)
            return new Place(
                Place.Kind.pointer, expression.type,
                _thisLocal.offset, compileSizeConstant(0),
            );
        if (facts.isAggregate && _hasNestedContext)
            if (auto this_ = expression.isThisExp)
                if (auto captured = this_.var in _capturedOffsets) {
                    const pointer = allocateBytes(
                        cast(uint) size_t.sizeof, size_t.sizeof,
                    );
                    _code ~= Instruction(
                        Op.frameLoad, pointer,
                        capturedFrameIndex(
                            _capturedOwners[this_.var], *captured,
                        ),
                        cast(ushort) size_t.sizeof,
                    );
                    return pointerPlace(pointer, expression.type);
                }
        if (auto dot = expression.isDotVarExp) {
            import std.conv: text;
            import dmd.astenums: TY;

            auto field = dot.var.isVarDeclaration;
            if (field !is null && dot.e1.type !is null) {
                Operand address;
                bool resolved;
                if (dot.e1.type.toBasetype.ty == TY.Tclass) {
                    address = compileExpression(dot.e1);
                    if (address.isPointer) {
                        emitNullClassReferenceCheck(
                            address.offset,
                            text(
                                "class `", expressionChars(dot.e1),
                                "` is `null` and cannot be dereferenced",
                            ),
                        );
                        resolved = true;
                    }
                } else if (typeFacts(dot.e1.type).isAggregate) {
                    if (auto base = placeOrNull(dot.e1)) {
                        address = addressOfPlace(*base);
                        resolved = true;
                    }
                }

                if (resolved) {
                    const fieldAddress = pointerPlaceAddress(
                        address.offset,
                        compileSizeConstant(cast(size_t) field.offset),
                        1,
                        facts.isAggregate
                            ? ScalarType.void_
                            : facts.opcodeType,
                    );
                    return pointerPlace(fieldAddress.offset, field.type);
                }
            }
        }
        if (auto dereference = expression.isPtrExp) {
            import dmd.astenums: TY;

            if (!facts.isAggregate &&
                dereference.type.toBasetype.ty == TY.Tfunction)
                return null;
            const pointer = compileExpression(dereference.e1);
            if (!pointer.isPointer)
                return null;
            if (pointer.pointerElement == ScalarType.void_ &&
                !facts.isAggregate)
                return new Place(
                    Place.Kind.frame, pointer.type, pointer.offset,
                    null,
                    isPointerLikePlaceType(dereference.type),
                    ScalarType.void_,
                );
            if (facts.isAggregate)
                return pointerPlace(pointer.offset, expression.type);
            return new Place(
                Place.Kind.pointer, pointer.pointerElement,
                pointer.offset, null,
                isPointerLikePlaceType(dereference.type),
                isPointerType(dereference.type)
                    ? pointerElementScalar(dereference.type)
                    : ScalarType.void_,
                compileSizeConstant(0),
            );
        }
        if (auto index = expression.isIndexExp) {
            import dmd.astenums: TY;

            if (index.e1.type !is null &&
                index.e1.type.toBasetype.ty == TY.Taarray)
                if (auto container = placeOrNull(index.e1)) {
                    const handle = loadPlace(*container);
                    auto aaType = index.e1.type.toBasetype;
                    return assocArrayIndexPlace(
                        container, handle.offset, index.e2, aaType,
                        index.type,
                    );
                }

            if (index.e1.type !is null &&
                index.e1.type.toBasetype.ty == TY.Tsarray)
                if (auto base = placeOrNull(index.e1)) {
                    const address = addressOfPlace(*base);
                    const elementAddress = advanceStaticArrayPointer(
                        address, index.e2, index.type,
                        compileSizeConstant(
                            staticArrayLength(index.e1.type),
                        ),
                    );
                    return pointerPlace(
                        elementAddress.offset, index.type,
                    );
                }
            if (isPointerType(index.e1.type)) {
                const pointer = compileExpression(index.e1);
                const indexValue = compileExpression(index.e2);
                if (pointer.isPointer)
                    return pointerPlaceAt(
                        pointer.offset, indexValue.offset, index.type,
                    );
            }
            if (index.e1.type !is null &&
                index.e1.type.toBasetype.ty == TY.Tarray) {
                Operand descriptor;
                if (auto base = placeOrNull(index.e1))
                    descriptor = loadPlace(*base);
                else
                    descriptor = compileExpression(index.e1);
                const descriptorMetadata = DynamicArrayLocal(
                    descriptor.offset,
                    dynamicArrayElementType(index.e1.type),
                    arrayElementIsArray(index.e1.type),
                );
                const savedDollarLength = _activeDollarLength;
                _activeDollarLength = sliceLengthSlot(descriptorMetadata);
                const indexValue = compileExpression(index.e2);
                _activeDollarLength = savedDollarLength;
                if (facts.isAggregate &&
                    descriptorMetadata.elementIsArray &&
                    index.type.toBasetype.ty == TY.Tsarray)
                    return pointerPlace(
                        innerArrayRowPointer(
                            descriptorMetadata, indexValue.offset,
                        ),
                        index.type,
                    );
                return dynamicIndexPlace(
                    descriptorMetadata, indexValue.offset, index.type,
                );
            }
        }
        if (auto slice = expression.isSliceExp) {
            auto result = new Place;
            result.kind = Place.Kind.slice;
            result.sliceBaseType = slice.e1.type;

            if (auto destination = tryStaticArraySliceDescriptor(slice)) {
                result.offset = *destination;
                result.sliceElementType =
                    dynamicArrayElementType(slice.e1.type);
                result.sliceElementSize =
                    typeFacts(slice.e1.type.toBasetype.nextOf).byteWidth;
                result.isStaticSlice = true;
                return result;
            }

            const pointerSlice = isPointerType(slice.e1.type);
            auto descriptor = pointerSlice
                ? DynamicArrayLocal.init
                : dynamicArrayDescriptor(slice.e1);
            result.sliceElementType = pointerSlice
                ? dynamicArrayElementType(slice.type)
                : descriptor.elementType;
            result.sliceElementIsArray = pointerSlice
                ? arrayElementIsArray(slice.e1.type)
                : descriptor.elementIsArray;
            result.sliceElementSize = dynamicArrayElementSize(
                slice.e1.type, result.sliceElementIsArray,
            );
            if (!pointerSlice)
                result.sliceDescriptor = descriptor;
            result.offset = allocateBytes(
                sliceDescriptorSize, size_t.sizeof,
            );
            compileSliceInto(result.offset, result.sliceElementType, slice);
            return result;
        }
        return null;
    }

    private auto callTypeFunction(CallExp call) {
        import dmd.astenums: TY;

        auto type = call.e1.type.toBasetype;
        if (type.ty == TY.Tdelegate)
            type = type.nextOf.toBasetype;
        return type.isTypeFunction;
    }

    private Place* pointerPlace(
        in ushort pointer,
        Type type,
        in bool heapEscapingDelegate = false,
    ) {
        const facts = typeFacts(type);
        if (facts.isAggregate)
            return new Place(
                Place.Kind.pointer, type, pointer,
                compileSizeConstant(0),
                heapEscapingDelegate || isDelegateValueType(type),
            );
        auto result = new Place(
            Place.Kind.pointer,
            facts.opcodeType,
            pointer,
            null,
            isPointerLikePlaceType(type),
            isPointerType(type)
                ? pointerElementScalar(type)
                : ScalarType.void_,
            compileSizeConstant(0),
        );
        return result;
    }

    private Place* pointerPlaceAt(
        in ushort pointer,
        in ushort index,
        Type type,
    ) {
        const facts = typeFacts(type);
        if (facts.isAggregate)
            return new Place(
                Place.Kind.pointer, type, pointer, index,
                isDelegateValueType(type),
            );
        return new Place(
            Place.Kind.pointer, facts.opcodeType, pointer,
            null,
            isPointerType(type),
            isPointerType(type)
                ? pointerElementScalar(type)
                : ScalarType.void_,
            index,
        );
    }

    private Place* dynamicIndexPlace(
        in DynamicArrayLocal descriptor,
        in ushort index,
        Type type,
    ) {
        const facts = typeFacts(type);
        if (facts.isAggregate)
            return new Place(
                Place.Kind.dynamicIndex, type,
                descriptor.offset, index,
                isDelegateValueType(type),
            );
        return new Place(
            Place.Kind.dynamicIndex, facts.opcodeType,
            descriptor.offset, null,
            isPointerLikePlaceType(type),
            isPointerType(type)
                ? pointerElementScalar(type)
                : ScalarType.void_,
            index,
        );
    }

    private Place* assocArrayIndexPlace(
        Place* container,
        in ushort handle,
        Expression key,
        Type aaType,
        Type valueType,
    ) {
        auto result = new Place(
            Place.Kind.assocIndex,
            valueType,
            handle,
            assocArrayKeyOffset(key, aaType),
        );
        result.keyMeta = assocArrayKeyMeta(aaType);
        result.container = container;
        return result;
    }

    private bool isPointerLikePlaceType(Type type) {
        import dmd.astenums: TY;

        return isPointerType(type) || type.toBasetype.ty == TY.Tclass;
    }

    private Operand loadPlace(Place place) {
        const aggregate = place.valueType !is null;
        const width = aggregate
            ? typeFacts(place.valueType).byteWidth
            : size(place.type);
        const operandType = aggregate ? ScalarType.void_ : place.type;
        final switch (place.kind) with (Place.Kind) {
            case frame:
                if (!aggregate)
                    if (auto closurePointer =
                        place.declaration in _heapEscapingClosurePointers)
                        return loadThroughPointer(
                            Operand(
                                *closurePointer, ScalarType.ulong_, true,
                                place.type,
                            ),
                            compileSizeConstant(
                                _heapEscapingClosureOffsets[place.declaration] /
                                    width,
                            ),
                        );
                return Operand(place.offset, operandType);
            case captured:
                if (!aggregate)
                    return loadCapturedLocal(place.declaration, place.offset);
                const result = aggregate
                    ? allocateBytes(width, staticArrayAlign(place.valueType))
                    : allocate(place.type);
                _code ~= Instruction(
                    Op.frameLoad,
                    result,
                    capturedFrameIndex(
                        _capturedOwners[place.declaration], place.offset,
                    ),
                    cast(ushort) width,
                );
                return Operand(result, operandType);
            case module_:
                const result = aggregate
                    ? allocateBytes(width, staticArrayAlign(place.valueType))
                    : allocate(place.type);
                _code ~= Instruction(
                    Op.loadModule, result, place.offset,
                    cast(ushort) width,
                );
                return Operand(result, operandType);
            case pointer:
                if (aggregate) {
                    const result = allocateBytes(
                        width, staticArrayAlign(place.valueType),
                    );
                    emitPointerLoad(
                        result, place.offset, place.indexOffset, width,
                    );
                    return Operand(result, operandType);
                }
                return loadThroughPointer(
                    Operand(place.offset, ScalarType.ulong_, true, place.type),
                    place.indexOffset,
                );
            case dynamicIndex:
                const result = aggregate
                    ? allocateBytes(width, staticArrayAlign(place.valueType))
                    : allocate(place.type);
                emitIndexLoad(
                    result, place.offset, place.indexOffset, width,
                );
                return Operand(result, operandType);
            case assocIndex:
                const pointer = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.aaGetRvalue, pointer, place.offset, place.indexOffset,
                    cast(ushort) width, place.keyMeta,
                );
                const result = aggregate
                    ? allocateBytes(width, staticArrayAlign(place.valueType))
                    : allocate(place.type);
                emitPointerLoad(
                    result, pointer, compileSizeConstant(0), width,
                );
                return Operand(result, operandType);
            case slice:
                return Operand(place.offset, ScalarType.void_);
        }
    }

    private Operand loadPlaceValue(Place place) {
        const value = loadPlace(place);
        if (place.valueType !is null &&
            isComplexDoubleType(place.valueType))
            return complexDoubleOperand(value.offset);
        return place.isPointerValue
            ? Operand(
                value.offset, value.type, true, place.pointerElement,
            )
            : value;
    }

    private void storePlace(Place place, in Operand value) {
        const aggregate = place.valueType !is null;
        const width = aggregate
            ? typeFacts(place.valueType).byteWidth
            : size(place.type);
        final switch (place.kind) with (Place.Kind) {
            case frame:
                if (value.offset != place.offset)
                    _code ~= Instruction(
                        Op.copy, place.offset, value.offset,
                        cast(ushort) width,
                    );
                if (!aggregate)
                    if (auto closurePointer =
                        place.declaration in _heapEscapingClosurePointers) {
                        const closureOffset =
                            _heapEscapingClosureOffsets[place.declaration];
                        emitPointerStore(
                            place.offset,
                            *closurePointer,
                            compileSizeConstant(closureOffset / width),
                            width,
                        );
                    }
                return;
            case captured:
                if (!aggregate) {
                    storeCapturedLocal(place.declaration, place.offset, value);
                    return;
                }
                _code ~= Instruction(
                    Op.frameStore,
                    value.offset,
                    capturedFrameIndex(
                        _capturedOwners[place.declaration], place.offset,
                    ),
                    cast(ushort) width,
                );
                return;
            case module_:
                _code ~= Instruction(
                    Op.storeModule, value.offset, place.offset,
                    cast(ushort) width,
                );
                return;
            case pointer:
                emitPointerStore(
                    value.offset, place.offset, place.indexOffset,
                    width,
                );
                return;
            case dynamicIndex:
                emitIndexStore(
                    value.offset, place.offset, place.indexOffset,
                    width,
                );
                return;
            case assocIndex:
                _code ~= Instruction(
                    Op.aaInsert, place.offset, place.indexOffset, value.offset,
                    cast(ushort) width, place.keyMeta,
                );
                if (place.container !is null)
                    storePlace(
                        *place.container,
                        Operand(place.offset, ScalarType.ulong_),
                    );
                return;
            case slice:
                emitSliceCopy(
                    place.offset, value.offset, place.sliceElementSize,
                );
                return;
        }
    }

    private Operand addressOfPlace(Place place) {
        const aggregate = place.valueType !is null;
        const width = aggregate
            ? typeFacts(place.valueType).byteWidth
            : size(place.type);
        const operandType = aggregate ? ScalarType.void_ : place.type;
        final switch (place.kind) with (Place.Kind) {
            case frame:
                if (!aggregate)
                    if (auto closurePointer =
                        place.declaration in _heapEscapingClosurePointers)
                        return pointerPlaceAddress(
                            *closurePointer,
                            compileSizeConstant(
                                _heapEscapingClosureOffsets[place.declaration] /
                                    width,
                            ),
                            width,
                            operandType,
                        );
                return *addressOperand(
                    Op.frameAddress, place.offset, operandType,
                );
            case captured:
                return capturedPlaceAddress(
                    place.declaration, place.offset, operandType,
                );
            case module_:
                return *addressOperand(
                    Op.moduleAddress, place.offset, operandType,
                );
            case pointer:
                return pointerPlaceAddress(
                    place.offset, place.indexOffset, width, operandType,
                );
            case dynamicIndex:
                const pointer = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.copy, pointer, place.offset,
                    cast(ushort) size_t.sizeof,
                );
                return pointerPlaceAddress(
                    pointer, place.indexOffset, width, operandType,
                );
            case assocIndex:
                const placeholder = allocateBytes(width, width);
                _code ~= Instruction(
                    Op.aaGetOrInsert,
                    place.offset,
                    place.indexOffset,
                    placeholder,
                    cast(ushort) width,
                    place.keyMeta,
                );
                if (place.container !is null)
                    storePlace(
                        *place.container,
                        Operand(place.offset, ScalarType.ulong_),
                    );
                const pointer = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.aaIn, pointer, place.offset, place.indexOffset,
                    cast(ushort) width, place.keyMeta,
                );
                return Operand(
                    pointer, ScalarType.ulong_, true, operandType,
                );
            case slice:
                return Operand(
                    place.offset, ScalarType.ulong_, true,
                    place.sliceElementType,
                );
        }
    }

    private Operand capturedPlaceAddress(
        VarDeclaration declaration,
        in ushort offset,
        in ScalarType elementType,
    ) {
        const pointer = allocateBytes(
            cast(uint) size_t.sizeof, size_t.sizeof,
        );
        _code ~= Instruction(
            Op.frameIndexAddress, pointer,
            capturedFrameIndex(_capturedOwners[declaration], offset),
        );
        return Operand(pointer, ScalarType.ulong_, true, elementType);
    }

    private Operand pointerPlaceAddress(
        in ushort pointer,
        in ushort index,
        in uint elementSize,
        in ScalarType elementType,
    ) {
        const result = allocateBytes(
            cast(uint) size_t.sizeof, size_t.sizeof,
        );
        _code ~= Instruction(
            Op.pointerAddress, result, pointer, index,
            cast(ushort) elementSize,
        );
        return Operand(result, ScalarType.ulong_, true, elementType);
    }

    private bool isDelegateValueType(Type type) {
        import dmd.astenums: TY;

        return type !is null && type.toBasetype.ty == TY.Tdelegate;
    }

    private Operand storeExpressionIntoPlace(
        Place place,
        Expression rhs,
    ) {
        if (place.kind == Place.Kind.slice)
            return place.isStaticSlice
                ? storeStaticSlice(place, rhs)
                : storeDynamicSlice(place, rhs);

        const source = place.declinesCapturingDelegate
            ? refEscapingDelegateOperandOffset(rhs)
            : aggregateValueOffset(
                place.valueType, rhs, place.heapEscapingDelegate,
            );
        storePlace(place, Operand(source, ScalarType.void_));
        if (place.declaration !is null &&
            declarationRecordView(place.declaration).delegate_OrNull !is null) {
            registerFrameDeclaration(place.declaration).delegateRuntime = true;
            registerFrameDeclaration(place.declaration).delegateParameter =
                place.offset;
        }
        return isComplexDoubleType(place.valueType)
            ? complexDoubleOperand(source)
            : Operand(source, ScalarType.void_);
    }

    private Operand* placeAddressOrNull(Expression expression) {
        if (auto place = placeOrNull(expression)) {
            auto result = new Operand;
            *result = addressOfPlace(*place);
            return result;
        }
        return null;
    }

    private ushort aggregateValueOffset(
        Type type,
        Expression rhs,
        in bool heapEscapingDelegate,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        // DMD exposes `vector.array` as a struct-typed view over the vector's
        // inline bytes. Its value emitter already returns that backing block;
        // it needs no struct reconstruction.
        if (rhs.isVectorArrayExp !is null)
            if (auto place = placeOrNull(rhs))
                return loadPlace(*place).offset;
        if (rhs.type.toBasetype.ty == TY.Tsarray &&
            type.toBasetype.ty != TY.Tsarray) {
            const result = allocateBytes(
                typeFacts(type).byteWidth, staticArrayAlign(type),
            );
            if (compileStaticArrayValueInto(result, rhs.type, rhs))
                return result;
        }

        switch (type.toBasetype.ty) with (TY) {
            case Tstruct:
                if (auto integer = rhs.isIntegerExp)
                    if (integer.toInteger == 0) {
                        const result = allocateStructBlock(type);
                        zeroFrameBlock(result, typeFacts(type).byteWidth);
                        return result;
                    }
                return structOperandOffset(rhs);
            case Tsarray:
                const result = allocateBytes(
                    typeFacts(type).byteWidth, staticArrayAlign(type),
                );
                if (!compileStaticArrayValueInto(result, type, rhs))
                    throw new Exception(text(
                        "Unsupported aggregate assignment in bytecode core: ",
                        expressionChars(rhs),
                    ));
                return result;
            case Tarray:
                const result = allocateBytes(
                    sliceDescriptorSize, size_t.sizeof,
                );
                compileDynamicArrayInto(
                    result, dynamicArrayElementType(type), rhs,
                    arrayElementIsArray(type),
                );
                return result;
            case Tdelegate:
                return heapEscapingDelegate
                    ? heapEscapingDelegateOperandOffset(rhs)
                    : delegateOperandOffset(rhs);
            default:
                if (isComplexDoubleType(type))
                    return compileComplexDoubleOperand(rhs).offset;
                throw new Exception(text(
                    "Unsupported aggregate assignment in bytecode core: ",
                    expressionChars(rhs),
                ));
        }
    }

    // `arr.length` loads one descriptor value, whether `arr` is an lvalue
    // place or a once-compiled temporary expression.
    private Operand compileArrayLength(ArrayLengthExp length) {
        const descriptor = dynamicArrayDescriptor(length.e1);
        const offset = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, offset, descriptor.offset);
        return Operand(offset, ScalarType.ulong_);
    }

    // The descriptor value and element metadata of an array expression. An
    // lvalue is resolved once and loaded through Place; a non-lvalue is
    // materialised once into a descriptor slot. Static arrays become views
    // over their real storage rather than heap copies.
    private DynamicArrayLocal dynamicArrayDescriptor(Expression expression) {
        import dmd.astenums: TY;
        import std.conv: text;

        if (auto dot = expression.isDotVarExp)
            if (auto name = tryTypeidName(dot))
                return DynamicArrayLocal(name.offset, ScalarType.char_);

        if (auto dot = expression.isDotVarExp)
            if (auto field = tryExceptionStringField(dot))
                return DynamicArrayLocal(field.offset, ScalarType.char_);

        if (expression.type is null)
            throw new Exception(text(
                "Unsupported dynamic array access in bytecode core: ",
                expressionChars(expression),
            ));

        const kind = expression.type.toBasetype.ty;
        if (kind == TY.Tsarray) {
            auto place = placeOrNull(expression);
            if (place is null) {
                const elementType = dynamicArrayElementType(expression.type);
                const elementIsArray = arrayElementIsArray(expression.type);
                const offset = allocateBytes(
                    sliceDescriptorSize, size_t.sizeof,
                );
                compileDynamicArrayInto(
                    offset, elementType, expression, elementIsArray,
                );
                return DynamicArrayLocal(
                    offset, elementType, elementIsArray,
                );
            }
            const address = addressOfPlace(*place);
            const offset = allocateBytes(
                sliceDescriptorSize, size_t.sizeof,
            );
            _code ~= Instruction(
                Op.copy, offset, address.offset,
                cast(ushort) size_t.sizeof,
            );
            const elementWidth = typeFacts(
                cast(Type) expression.type.toBasetype.nextOf,
            ).byteWidth;
            _code ~= Instruction(
                Op.loadConstant,
                cast(ushort) sliceDescriptorLengthOffset(offset),
                constantIndex(
                    typeFacts(expression.type).byteWidth / elementWidth,
                ),
                cast(ushort) size_t.sizeof,
            );
            auto result = DynamicArrayLocal(
                offset,
                dynamicArrayElementType(expression.type),
                arrayElementIsArray(expression.type),
            );
            result.isStaticArrayView = true;
            result.staticArrayViewIsClassField = true;
            result.staticArrayOffset = address.offset;
            return result;
        }

        if (kind != TY.Tarray && !isStringType(expression.type))
            throw new Exception(text(
                "Unsupported dynamic array access in bytecode core: ",
                expressionChars(expression),
            ));

        const elementType = dynamicArrayElementType(expression.type);
        const elementIsArray = arrayElementIsArray(expression.type);
        if (auto place = placeOrNull(expression))
            return DynamicArrayLocal(
                loadPlaceValue(*place).offset,
                elementType,
                elementIsArray,
            );

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileDynamicArrayInto(
            offset, elementType, expression, elementIsArray,
        );
        return DynamicArrayLocal(offset, elementType, elementIsArray);
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
                    cast(ushort) TypeFacts.fromOpcode(
                        ScalarType.ulong_,
                    ).byteWidth,
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
            cast(ushort) TypeFacts.fromOpcode(ScalarType.ulong_).byteWidth,
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
        import dmd.astenums: STC;
        import std.conv: text;

        if ((variable.storage_class & STC.ref_) != STC.none &&
            compileRefLocalDeclaration(variable))
        {
            return;
        }

        final switch (declarationRecord(variable).facts.representation)
            with (DeclarationRepresentation)
        {
            case unavailable:
            case lazyDelegate:
                throw new Exception(text(
                    "Unsupported variable in bytecode core: ",
                    declarationChars(variable),
                ));
            case scalar:
                compileScalarDeclaration(variable);
                return;
            case staticArray:
                compileStaticArrayDeclaration(variable);
                return;
            case vector:
                compileVectorDeclaration(variable);
                return;
            case dynamicArray:
                compileDynamicArrayDeclaration(variable);
                return;
            case pointer:
                compilePointerDeclaration(variable);
                return;
            case struct_:
                compileStructDeclaration(variable);
                return;
            case delegate_:
                compileDelegateDeclaration(variable);
                return;
            case complexDouble:
                compileComplexDoubleDeclaration(variable);
                return;
            case classPointer:
                compileClassPointerDeclaration(variable);
                return;
            case assocArray:
                compileAssocArrayDeclaration(variable);
                return;
        }
    }

    private void compileScalarDeclaration(VarDeclaration variable) {
        const type = scalarType(variable.type);
        const offset = allocateBytes(size(type), size(type));
        registerFrameDeclaration(variable).scalar = offset;
        registerCapturedOffset(variable, offset);

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
        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null)
            return false;

        auto expression = initializerExpression(initializer.exp);
        if (auto address = placeAddressOrNull(expression)) {
            registerReferenceDeclaration(variable).scalar = address.offset;
            const facts = declarationRecord(variable).facts;
            registerReferenceDeclaration(variable).refPointer =
                facts.isAggregate
                    ? ScalarType.void_
                    : facts.opcodeType;
            return true;
        }
        return false;
    }

    private void compileComplexDoubleDeclaration(VarDeclaration variable) {
        const offset = allocateComplexDouble;
        registerFrameDeclaration(variable).scalar = offset;

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

        registerFrameDeclaration(variable).scalar = offset;
        registerCapturedOffset(variable, offset);
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
            registerFrameDeclaration(variable).scalar = offset;
            registerCapturedOffset(variable, offset);
            _code ~= Instruction(
                Op.loadConstant,
                offset,
                constantIndex(0),
                cast(ushort) size_t.sizeof,
            );
            return;
        }

        // Pre-register the slot *before* compiling the initializer. DMD's
        // `in` operator lowering for an associative-array key that is not
        // constant-foldable (e.g. `Name(ab())`, needing a hidden key temp to
        // preserve evaluation order) nests a self-referential assignment to
        // `variable` inside its own initializer's `CommaExp` --
        // `(__aakeyN = Name(ab()), variable = _d_aaInX(...))` -- so the
        // generic assignment compiler reaches a plain `variable = ...`
        // *while still compiling `variable`'s own declaration*. Without this
        // pre-registration that nested assignment finds no slot for
        // `variable` and refuses with "Unsupported assignment in bytecode
        // core". The scalar/pointer metadata set here is harmlessly
        // overwritten (with the same values, or a more precise one for the
        // delegate-pointee case) once the initializer finishes compiling
        // below.
        registerFrameDeclaration(variable).scalar = offset;
        registerCapturedOffset(variable, offset);

        const pointer =
            compileExpression(initializerExpression(initializer.exp));
        if (!pointer.isPointer)
            throw new Exception(text(
                "Unsupported pointer initializer in bytecode core: ",
                declarationChars(variable),
            ));

        auto record = registerFrameDeclaration(variable);
        record.scalar = offset;
        auto declaredElement = variable.type.toBasetype.nextOf;
        if (declaredElement !is null &&
            declaredElement.toBasetype.ty == TY.Tdelegate)
            record.pointer = pointer.pointerElement;
        registerCapturedOffset(variable, offset);
        // A `S* p = new S(...)` pointer addresses a heap struct block; record the
        // struct declaration so `p.field` resolves through the pointer.
        if (auto structDeclaration = structPointerDeclaration(variable.type))
            record.structPointer = structDeclaration;
        // The self-referential `CommaExp` initializer shape above (the
        // nested `variable = ...` assignment) already writes the pointer
        // value directly into `offset` -- skip the otherwise-redundant
        // self-copy.
        if (pointer.offset != offset)
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
        if (delegate_.function_ !is null) {
            const offset = allocateBytes(delegateValueSize, size_t.sizeof);
            emitDelegateValue(
                offset, delegate_.function_, delegate_.contextOffset,
            );
            registerFrameDeclaration(variable).delegate_ = DelegateLocal(
                offset, delegate_.function_,
            );
            // A nested function reading `dg` sees only the captured-locals
            // environment, not current-function delegate metadata (reset per
            // compiled
            // function); register the offset like every other local so its
            // value is reachable there too.
            registerCapturedOffset(variable, offset);
            return;
        }

        // Any other delegate-typed initializer -- a function call returning
        // a delegate, or an existing delegate-typed local/parameter/field
        // copied by value -- has no statically known callee. Resolve it the
        // same way a delegate-typed parameter is resolved and dispatch calls
        // through it at run time via its own function-index word.
        if (initializer !is null) {
            const source =
                delegateOperandOffset(initializerExpression(initializer.exp));
            const offset = allocateBytes(delegateValueSize, size_t.sizeof);
            _code ~= Instruction(
                Op.copy, offset, source, cast(ushort) delegateValueSize,
            );
            registerFrameDeclaration(variable).delegateRuntime = true;
            registerFrameDeclaration(variable).delegateParameter = offset;
            registerCapturedOffset(variable, offset);
            return;
        }

        throw new Exception(text(
            "Unsupported delegate initializer in bytecode core: ",
            declarationChars(variable),
        ));
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

    // `delegateInitializer`'s callee resolution alone, without computing (and
    // so without emitting bytecode for, and without `delegateContextOffset`'s
    // `_frameContextDelegates` bookkeeping for) the context that goes with
    // it. For a caller that only wants to know WHICH function a delegate-typed
    // initializer expression statically names -- not the delegate value
    // itself, which it never builds -- calling `delegateInitializer` instead
    // would wastefully emit a live frame-context computation for a value that
    // is then discarded, and would wrongly mark that function as having a
    // materialised frame-context delegate value when it never actually got
    // one.
    private FuncDeclaration delegateInitializerFunctionOrNull(
        Expression initializer,
    ) {
        if (auto literal = initializer.isFuncExp)
            return literal.fd;

        if (auto delegate_ = initializer.isDelegateExp)
            return delegate_.func;

        if (auto address = initializer.isAddrExp) {
            if (auto variable = address.e1.isVarExp)
                return variable.var.isFuncDeclaration;

            if (auto dot = address.e1.isDotVarExp)
                return dot.var.isFuncDeclaration;
        }

        return null;
    }

    // The frame offset of a delegate-typed field's `{functionIndex, context}`
    // value, resolved and loaded through the shared place pipeline.
    private ushort* delegateFieldOffsetOf(DotVarExp dot) {
        import dmd.astenums: TY;

        auto field = dot.var.isVarDeclaration;
        if (field is null || field.type.toBasetype.ty != TY.Tdelegate)
            return null;
        auto place = placeOrNull(dot);
        if (place is null)
            return null;
        auto offset = new ushort;
        *offset = loadPlaceValue(*place).offset;
        return offset;
    }

    // The frame offset of a delegate-typed expression's 16-byte
    // `{functionIndex, context}` pair: an already-materialised delegate
    // local or parameter reuses its own slot; a struct/class/struct-pointer
    // field resolves through `delegateFieldOffsetOf`; any other delegate
    // expression (a lambda literal, `&freeFunction`, `&receiver.method`) is
    // built fresh.
    private ushort delegateOperandOffset(Expression argument) {
        import std.conv: text;

        while (auto cast_ = argument.isCastExp)
            argument = cast_.e1;

        if (auto variable = argument.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto existing = declarationRecordView(declaration).delegate_OrNull)
                    return existing.offset;
                if (auto existing = declarationRecordView(declaration).delegateParameterOrNull)
                    return *existing;

                // A module-level (`__gshared`/`static`) delegate variable:
                // materialise its 16-byte `{functionIndex, context}` pair
                // out of `moduleData` into a fresh frame slot, the same way
                // a module pointer/AA read does (`Op.loadModule`).
                if (auto moduleVariable =
                        moduleDeclarationRecord(declaration).moduleDelegateOrNull) {
                    const offset =
                        allocateBytes(delegateValueSize, size_t.sizeof);
                    _code ~= Instruction(
                        Op.loadModule, offset, moduleVariable.offset,
                        cast(ushort) delegateValueSize,
                    );
                    return offset;
                }
            }

        if (auto dot = argument.isDotVarExp)
            if (auto offset = delegateFieldOffsetOf(dot))
                return *offset;

        auto delegate_ = delegateInitializer(argument);
        if (delegate_.function_ !is null) {
            // A bare lambda literal (`(...) { ... }`) assigned as a
            // delegate-typed rvalue: `compileExpression`'s own `FuncExp`
            // branch records this exact shape into
            // `_latestStaticDelegateAssocArrayFunction` as the static-
            // delegate-registry hack's read-side fallback (see
            // `tryStaticDelegateAssocArrayCall`) for whenever a
            // `childWriters[key] = someLambda;`-shaped assignment's own
            // structural declaration lookup declines (DMD hoists the
            // `_d_aaGetY` slot pointer into a compiler temp, so
            // `staticDelegateAssocArrayAssignDeclaration`'s `IndexExp`
            // branch sees that temp, not the `childWriters` variable, and
            // never populates `_staticDelegateAssocArrays`). Storing a
            // delegate-typed rhs through a pointer (`storeThroughPointer`'s
            // `Tdelegate` branch) used to reach that same `compileExpression`
            // `FuncExp` branch and so set this side channel as a side
            // effect; it now routes through here instead (this function)
            // to get the correct 16-byte `delegateValueSize` load/store
            // width, bypassing the side channel entirely. Reproduce it here
            // for exactly the same shape (a literal `FuncExp`, matching
            // `compileExpression`'s own guard) so the registry's read-side
            // fallback still has a function to find -- `childWriters` itself
            // has no real persistent backing storage under the hack
            // (`resolveAssocArrayOperand`'s `childWriters`-named branch hands
            // out a fresh, empty `Op.aaNew` handle on every access), so a
            // real `_d_aaGetRvalueX` read of it always misses and raises a
            // spurious "Range violation" once this fallback is empty.
            if (argument.isFuncExp !is null)
                _latestStaticDelegateAssocArrayFunction = delegate_.function_;

            const offset = allocateBytes(delegateValueSize, size_t.sizeof);
            emitDelegateValue(
                offset, delegate_.function_, delegate_.contextOffset,
            );
            return offset;
        }

        // A bare `null` literal (`dg == null`, `dg is null`) -- the delegate
        // counterpart of the zeroed-block default-initializer/array-element
        // `NullExp` handling elsewhere -- yields a zeroed 16-byte block, the
        // same all-zero `{functionIndex, context}` pair a defaulted delegate
        // local already holds.
        if (argument.isNullExp !is null) {
            const offset = allocateBytes(delegateValueSize, size_t.sizeof);
            zeroFrameBlock(offset, delegateValueSize);
            return offset;
        }

        // `callbacks[key]` used as a call target (`callbacks[key]()`) for an
        // associative array whose VALUE type is itself `Tdelegate`: DMD
        // represents the read the same way a nested AA operand (`a[1][2]`)
        // reaches the shared place resolver -- an
        // `IndexExp` whose `e1` is the bounds-checked `_d_aaGetRvalueX`
        // pointer-yielding hook glue (already `Tpointer`-typed, the value
        // slot's real address) and whose `e2` is the constant `0` (the same
        // `*p` == `p[0]` idiom DMD uses generally), not a further nested
        // `CallExp` and not an `IndexExp` whose `e1` is the plain AA
        // variable. The generic place resolver already recognises this exact
        // `p[0]` shape and
        // would normally load through the pointer correctly -- but its
        // `loadThroughPointer` sizes the load from `pointer.pointerElement`,
        // and an AA value's pointee scalar type is deliberately the opaque
        // `void_` marker for any non-scalar value (`assocArrayValueScalarType`,
        // matching every other aggregate AA value: struct, static array,
        // delegate). `size(ScalarType.void_)` is not `delegateValueSize`, so
        // the generic path silently loads the wrong (effectively zero) byte
        // count, leaving the destination slot's stale contents -- commonly
        // all-zero -- to be read back as the delegate's `{functionIndex,
        // context}` pair. Function index 0 is ordinarily the very function
        // doing the calling, so `callbacks[key]()` silently recurses into
        // itself forever, growing the VM's own stack/frame arrays without
        // bound (confirmed multiple gigabytes within seconds). Load through
        // the pointer with the real, known-correct `delegateValueSize`
        // instead of trusting the opaque pointee's absent scalar width.
        if (auto index = argument.isIndexExp)
            if (auto zero = index.e2.isIntegerExp)
                if (zero.toInteger == 0 && isPointerType(index.e1.type)) {
                    const pointer = compileExpression(index.e1);
                    const destination =
                        allocateBytes(delegateValueSize, size_t.sizeof);
                    emitPointerLoad(
                        destination, pointer.offset, compileSizeConstant(0),
                        delegateValueSize,
                    );
                    return destination;
                }

        // Any other delegate-typed expression -- a function call returning a
        // delegate, or an index into an array of delegates (`dgs[0]`) --
        // already yields its own 16-byte `{functionIndex, context}` block
        // through the general expression compiler.
        if (argument.isCallExp !is null || argument.isIndexExp !is null)
            return compileExpression(argument).offset;

        throw new Exception(text(
            "Unsupported delegate argument in bytecode core: ",
            expressionChars(argument),
        ));
    }

    // The `FuncDeclaration` a `return dg;` returns, resolved the same way for
    // both a directly-known lambda literal/nested-function delegate (a
    // statically classified delegate local) and any other statically-known
    // callee shape
    // `delegateInitializer` recognises (`FuncExp`, `&freeFunction`,
    // `&receiver.method`) -- or null if `source` is not one of those (e.g. a
    // delegate read back from a parameter or another call, which has no
    // statically known callee here).
    private FuncDeclaration returnedDelegateFunctionOrNull(Expression source) {
        while (auto cast_ = source.isCastExp)
            source = cast_.e1;

        if (auto variable = source.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declarationRecordView(declaration).delegate_OrNull)
                    return existing.function_;

        return delegateInitializerFunctionOrNull(source);
    }

    // Compiles `return dg;`. A delegate literal that captures nothing
    // (`outerVars.length == 0`, e.g. `() => 5`) or a delegate value read back
    // from a parameter, field, or another call (no statically known callee
    // here) is unaffected either way: its context word is either never
    // dereferenced or its own origin already resolved this question, so the
    // ordinary `delegateOperandOffset` path handles it.
    //
    // A delegate literal or nested-function delegate that actually reads a
    // variable from an enclosing frame (`outerVars`, DMD's own record of the
    // reverse of `closureVars` -- `ai/plans/bytecode.md`'s Closures section:
    // "DMD semantic analysis has already determined `needsClosure()` and
    // `closureVars`") is different: the current call's frame is gone by the
    // time the caller invokes the returned delegate, so that captured-local
    // read would land on whatever later reused the stack region. Real
    // compiled D promotes such a capture to a GC-heap closure.
    // `heapClosureContextOrNull` recognises the narrow shape this core
    // heap-allocates (one or two scalar or pointer values captured by
    // exactly this one escaping lambda, one nesting level, no `this`
    // combination) and, when it matches, builds that heap environment
    // instead. Any wider shape still has no heap closure environment (see
    // `ai/plans/bytecode.md`'s Closures section), so decline loudly instead
    // of returning a value that reads as garbage once the frame is reused.
    private ushort compileDelegateReturn(Expression source) {
        return heapEscapingDelegateOperandOffset(source);
    }

    // The shared mechanism `compileDelegateReturn` uses, also reused for a
    // capturing delegate stored into a CLASS FIELD or an ARRAY ELEMENT
    // (class-field and dynamic-index aggregate places): both are
    // heap-resident storage a capturing
    // lambda can just as easily outlive its declaring frame through as a
    // directly returned delegate, so the same heap-box-the-narrow-shape,
    // decline-the-rest treatment applies instead of `delegateOperandOffset`'s
    // unconditional frame-relative context. `heapClosureContextOrNull`'s
    // narrow shape happens to cover every capturing case exercised so far at
    // these two sites (`delegate.functionReturningClassWithCapturingDelegateFieldIsCallable`,
    // `delegate.functionReturningArrayWithCapturingDelegateElementIsCallable`),
    // where the write is immediately followed only by the enclosing
    // aggregate's own return.
    //
    // Unlike a `return`, a class-field/array-element write is not itself the
    // function's last act. For the scalar/pointer capture shape
    // `heapClosureContextOrNull` recognises, later direct local assignments
    // mirror into the same heap environment, so the escaping delegate sees
    // the enclosing function's final value rather than a stale snapshot.
    private ushort heapEscapingDelegateOperandOffset(
        Expression source,
    ) {
        auto function_ = returnedDelegateFunctionOrNull(source);
        if (function_ !is null && function_.outerVars.length != 0) {
            if (auto heapContext = heapClosureContextOrNull(function_)) {
                const offset = allocateBytes(delegateValueSize, size_t.sizeof);
                emitDelegateValue(offset, function_, *heapContext);
                return offset;
            }
            throwFrameEscapingDelegateDiagnostic(source);
        }

        return delegateOperandOffset(source);
    }

    // Compiles the rhs of `dg = ...;` where `dg` is a `ref`/`out`
    // DELEGATE-TYPED PARAMETER: its frame slot is written back to the
    // caller's own storage once this function RETURNS, so a capturing rhs
    // still needs the same escape-safety `compileDelegateReturn` gives a
    // directly returned delegate -- but, unlike a `return` statement,
    // `heapClosureContextOrNull`'s soundness argument ("nothing in the
    // enclosing function reads or writes these variables again after this
    // point") does not hold here: the assignment can happen mid-function,
    // with arbitrary further statements (including more writes to the same
    // captured variables through the STILL-LIVE frame, e.g. `count = 10;`
    // right after `dg = () => ++count;`) still to come before this function
    // actually returns. Building a heap snapshot at the assignment would
    // freeze a stale copy right then, silently diverging from whatever the
    // frame goes on to do -- so, unlike `compileDelegateReturn`, this always
    // declines a capturing rhs outright rather than ever attempting
    // `heapClosureContextOrNull`. A non-capturing rhs (a plain rebind,
    // e.g. `dg = newValue;`) has no captured state to protect and still
    // resolves through the ordinary frame-relative `delegateOperandOffset`.
    private ushort refEscapingDelegateOperandOffset(Expression source) {
        auto function_ = returnedDelegateFunctionOrNull(source);
        if (function_ !is null && function_.outerVars.length != 0)
            throwFrameEscapingDelegateDiagnostic(source);

        return delegateOperandOffset(source);
    }

    // Shared diagnostic for a capturing delegate/lambda whose declaring
    // function's frame the escape site (a `return` of the delegate itself,
    // or a `return` of a struct literal with the delegate as one of its own
    // top-level fields -- `structLiteralReturnOffset`'s `Tdelegate` branch)
    // could plausibly outlive, but whose capture shape
    // `heapClosureContextOrNull` does not (yet) recognise: three or more
    // captures, a non-scalar/non-pointer capture, a multi-level capture, or a
    // capture combined with `this`. Raised instead of silently building a
    // frame-relative context that reads as garbage once the frame is reused.
    private void throwFrameEscapingDelegateDiagnostic(Expression source) {
        import std.conv: text;

        throw new Exception(text(
            "Unsupported delegate return in bytecode core: returning ",
            "a closure over this function's own locals outlives its ",
            "frame: ", expressionChars(source),
        ));
    }

    // A freshly heap-allocated closure environment's raw pointer, in a fresh
    // frame slot, for `function_`'s escaping capture -- or null if
    // `function_`'s capture doesn't match the shape this core heap-allocates:
    // one or two captured locals, each of scalar or pointer type, captured
    // one level up from a plain (non-`this`-receiving) enclosing function
    // directly into the frame currently being compiled. Any wider shape
    // (more than two captured locals, a non-scalar/non-pointer capture, a
    // multi-level capture, or a capture combined with `this`) still declines
    // via `compileDelegateReturn`'s existing diagnostic instead of risking an
    // unsound heap layout.
    //
    // The heap block holds one fixed `size_t.sizeof`-wide slot per captured
    // local, in `outerVars` order (so a single capture still sits at offset
    // 0, unchanged from before this function grew a second slot): every slot
    // is a full machine word wide regardless of the captured value's own
    // narrower width (e.g. a captured `int` still gets a full 8-byte slot),
    // deliberately not packed tightly by each value's own width. This keeps
    // the arithmetic trivial and always exact: `pointerLoad*`/`pointerStore*`
    // address as `pointer + index * width`, so a slot's byte offset
    // (`i * size_t.sizeof`) divided by that slot's own value width is always
    // a whole number for every width this core's scalar captures ever use (1,
    // 2, 4, or 8 -- all divisors of 8), regardless of which widths precede
    // it. A tightly-packed layout (offsets summing each preceding value's own
    // narrower width) would not have that guarantee in general: an `int`
    // (width 4) directly followed by a captured pointer (width 8) would land
    // the pointer at byte offset 4, and 4 is not a whole multiple of 8.
    // `loadCapturedLocal`/`storeCapturedLocal` divide `_heapClosureOffsets`
    // back down by each variable's own width to get the element index those
    // ops expect.
    //
    // `Op.allocStruct`'s initial byte-copy (sized to the *whole* block, i.e.
    // `outerVars.length * size_t.sizeof`, copied from the first captured
    // local's own frame slot onward) is immediately overwritten in full by
    // the per-variable `emitPointerStore`s below, for every slot including
    // the first: nothing here depends on that initial copy landing on the
    // right bytes, only on the block existing and being rooted, the same way
    // `new S` copies a struct's initialised frame block onto the heap before
    // the fields making up the struct literal below it in the frame are
    // written in individually. Nothing in the enclosing function reads or
    // writes any of these variables again after this point -- a `return`
    // statement is necessarily the end of its execution -- so the frame
    // slots and the heap block never diverge.
    private ushort* heapClosureContextOrNull(FuncDeclaration function_) {
        import dmd.astenums: TY;

        if (function_.outerVars.length == 0 || function_.outerVars.length > 2)
            return null;
        if (thisStructDeclaration(function_) !is null)
            return null;
        if (auto enclosing = enclosingMethodOf(function_))
            if (enclosing.isThis() !is null)
                return null;
        // This exact lambda already has a LIVE frame-context delegate value
        // (e.g. `auto dg = () => ++count;` earlier in the function, possibly
        // already called through while the frame was live): building a
        // second, heap-context delegate value for the same lambda body would
        // leave that one shared body unable to serve both contexts. Decline;
        // see `_frameContextDelegates`'s own comment.
        if (function_ in _frameContextDelegates)
            return null;

        const count = function_.outerVars.length;
        VarDeclaration[2] vars;
        ushort[2] capturedOffsets;
        ushort[2] widths;
        foreach (i; 0 .. count) {
            auto captured = function_.outerVars[i];
            auto owner = captured in _capturedOwners;
            if (owner is null || *owner !is _currentFunction)
                return null;
            auto capturedOffset = captured in _capturedOffsets;
            if (capturedOffset is null)
                return null;
            // Referenced by more than one nested function (DMD's own
            // `nestedrefs` record of this): a sibling lambda sharing this
            // same captured variable (`auto peek = () => count; auto early =
            // peek(); return () => ++count;`) reads it through its OWN,
            // never-heap-escaped frame-base context, but `_heapClosureVars`
            // is per-variable-per-escaping-lambda, not per-sibling -- the
            // sibling's own body has no way to tell "this variable is
            // heap-boxed for a DIFFERENT lambda" from "this variable is
            // heap-boxed for me". Decline rather than risk the sibling
            // misreading its frame-base context as a raw heap pointer.
            if (captured.nestedrefs.length > 1)
                return null;

            // `Tpointer` is deliberately not excluded here: `scalarType`
            // already maps it to the same 8-byte `ScalarType.ulong_` as any
            // other captured scalar, so the `Op.allocStruct`/
            // `emitPointerStore` snapshot below already copies a captured
            // pointer's bytes soundly regardless. The one thing that needed
            // fixing for this to actually work end to end was
            // `loadCapturedLocal` tagging the read-back value `isPointer`
            // (its `TY.Tclass` branch, immediately below this function,
            // already did the analogous thing for a captured class
            // reference) -- otherwise a dereference of the captured pointer
            // (`*p`) threw "Unsupported pointer dereference in bytecode
            // core" even once the raw bytes were already in the right
            // place. `Taarray`/`Tclass` remain excluded even though
            // `scalarType` maps them to `ScalarType.ulong_` too: unlike a
            // pointer or class reference, they still lack the
            // `loadCapturedLocal` tagging fix pointer got here (`Tclass`
            // already has ITS own tagging via the `isClassReference`
            // branch, but a captured class reference or AA handle has not
            // itself been exercised through this heap-closure escape path
            // yet -- left as future work, not attempted here to keep this
            // widening to the shape actually verified).
            const ty = captured.type.toBasetype.ty;
            if (ty == TY.Tstruct || ty == TY.Tsarray || ty == TY.Tarray ||
                ty == TY.Taarray || ty == TY.Tclass || ty == TY.Tdelegate)
                return null;

            vars[i] = captured;
            capturedOffsets[i] = *capturedOffset;
            widths[i] = cast(ushort) typeFacts(captured.type).byteWidth;
        }

        const totalSize = cast(ushort) (count * size_t.sizeof);
        const heapPointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.allocStruct, heapPointer, capturedOffsets[0], totalSize,
        );
        foreach (i; 0 .. count) {
            const slotOffset = cast(ushort) (i * size_t.sizeof);
            const index = compileSizeConstant(slotOffset / widths[i]);
            emitPointerStore(capturedOffsets[i], heapPointer, index, widths[i]);
            _heapClosureVars[function_][vars[i]] = true;
            _heapClosureOffsets[function_][vars[i]] = slotOffset;
            _heapEscapingClosurePointers[vars[i]] = heapPointer;
            _heapEscapingClosureOffsets[vars[i]] = slotOffset;
        }

        auto result = new ushort;
        *result = heapPointer;
        return result;
    }

    private ushort delegateContextOffset(
        FuncDeclaration function_,
        Expression receiver,
    ) {
        if (thisStructDeclaration(function_) !is null) {
            if (auto address = receiver is null ? null : receiver.isAddrExp)
                receiver = address.e1;
            if (receiver is null)
                return _thisLocal.offset;
            auto place = placeOrNull(receiver);
            if (place !is null)
                return addressOfPlace(*place).offset;
            const receiverOffset = structOperandOffset(receiver);
            return addressOperand(
                Op.frameAddress, receiverOffset, ScalarType.void_,
            ).offset;
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

        auto delegateLocal = declarationRecordView(declaration).delegate_OrNull;
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

        const totalSize = typeFacts(variable.type).byteWidth;
        const offset = allocateBytes(totalSize, staticArrayAlign(variable.type));
        // A static array has aggregate declaration metadata: scalar
        // VarExp/assignment paths must not treat its inline block as a scalar
        // slot.
        registerFrameDeclaration(variable).staticArray = offset;
        registerCapturedOffset(variable, offset);

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

        // A static array whose element type default-initializes to `null`
        // (delegates, pointers, classes) blits a single `NullExp` over the
        // whole inline block (`int delegate()[2] dgs;`), the delegate-array
        // counterpart of the integer-`0` blit above.
        if (auto blit = initializer.exp.isBlitExp)
            if (blit.e2.isNullExp !is null) {
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

    // Block-copies `source`'s value into the `typeFacts(type).byteWidth` bytes of
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

        const totalSize = typeFacts(type).byteWidth;

        // `char[N] c = "..."`: copy the literal bytes directly into the inline
        // slot rather than building a slice descriptor.
        if (auto string_ = stringLiteralOf(source)) {
            loadStaticString(offset, totalSize, string_);
            return true;
        }

        // A postblit-bearing static-array copy is represented by DMD as a
        // call. Intercept it before resolving ordinary aggregate places:
        // CallExp places denote their result temporary, whereas this helper
        // must run the element postblits as part of constructing `offset`.
        if (compileArrayConstructor(offset, type, source))
            return true;

        // `T[N] dest = src`: a value-type block copy of all N*sizeof(T) bytes
        // from the source static array's inline slot into the destination's.
        if (auto sourcePlace = placeOrNull(source)) {
            const sourceValue = loadPlace(*sourcePlace);
            _code ~= Instruction(
                Op.copy,
                offset,
                sourceValue.offset,
                cast(ushort) totalSize,
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
        const totalSize = typeFacts(arrayType).byteWidth;
        const offset = allocateBytes(totalSize, staticArrayAlign(arrayType));
        registerFrameDeclaration(variable).staticArray = offset;

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
        const elementSize = typeFacts(elementType).byteWidth;
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
        const elementSize = typeFacts(elementType).byteWidth;
        const count = typeFacts(arrayType).byteWidth / elementSize;

        // The source argument is `cast(T[])sourceArray`; the static-array base
        // is under the cast.
        auto sourceArray = (*call.arguments)[1];
        while (auto cast_ = sourceArray.isCastExp)
            sourceArray = cast_.e1;
        auto sourcePlace = placeOrNull(sourceArray);
        if (sourcePlace is null)
            return false;
        const sourceValue = loadPlace(*sourcePlace);

        _code ~= Instruction(
            Op.copy, destination, sourceValue.offset,
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

        auto arrayPlace = placeOrNull(slice.e1);
        if (arrayPlace is null)
            throw new Exception(text(
                "Unsupported array destructor in bytecode core: ",
                expressionChars(call),
            ));
        const arrayAddress = addressOfPlace(*arrayPlace);

        auto arrayType = slice.e1.type;
        auto elementType = arrayType.toBasetype.nextOf;
        const elementSize = typeFacts(elementType).byteWidth;
        const count = typeFacts(arrayType).byteWidth / elementSize;

        auto dtor = structDeclarationOf(elementType).dtor;
        if (dtor !is null)
            foreach_reverse (i; 0 .. count)
                runStructMethodAtAddress(
                    pointerPlaceAddress(
                        arrayAddress.offset,
                        compileSizeConstant(i * elementSize),
                        1,
                        ScalarType.void_,
                    ).offset,
                    dtor,
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
        registerFrameDeclaration(variable).struct_ = StructLocal(offset, declaration);
        registerCapturedOffset(variable, offset);

        zeroFrameBlock(offset, typeFacts(variable.type).byteWidth);

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

        // `s = t;` where `S` has a postblit but no user-defined `opAssign`:
        // DMD synthesizes an `opAssign` and lowers its by-value argument
        // into a synthesized `__copytmp` local -- this very declaration --
        // whose own initializer is the postblit call
        // `(__copytmp = src).__postblit()`: a raw blit into this
        // declaration's own storage, immediately followed by running the
        // postblit on it. Block-copy the blit's right-hand side into this
        // declaration's offset (already registered as struct metadata
        // above), then run the postblit, mirroring
        // `compileArrayConstructor`'s identical `_d_arrayctor` handling for
        // a static array of postblit elements.
        if (auto call = source.isCallExp)
            if (auto dot = call.e1.isDotVarExp) {
                // The receiver is `__copytmp = t`, which -- since
                // `__copytmp` is being written for the first time here --
                // DMD types as a ConstructExp/BlitExp (op `construct`/
                // `blit`), not a plain AssignExp (op `assign`); all three
                // share the `AssignExp` base and its `e1`/`e2` fields, the
                // same family `compileExpression`'s ConstructExp/BlitExp
                // routing above already distinguishes from a real
                // `EXP.assign`.
                auto blit = dot.e1.isAssignExp;
                if (blit is null)
                    blit = dot.e1.isConstructExp;
                if (blit is null)
                    blit = dot.e1.isBlitExp;
                if (blit !is null)
                    if (auto blitTarget = blit.e1.isVarExp)
                        if (blitTarget.var is variable) {
                            if (auto blitSource =
                                    structValueOffsetOrNull(blit.e2)) {
                                _code ~= Instruction(
                                    Op.copy,
                                    offset,
                                    *blitSource,
                                    cast(ushort) typeFacts(variable.type).byteWidth,
                                );
                                auto postblitFunction = callFunction(call);
                                if (postblitFunction !is null)
                                    runStructMethod(offset, postblitFunction);
                                return;
                            }
                        }
            }

        // `S dest = src` / `S dest = make(...)`: a value-type block copy of the
        // whole struct from its inline base (a local, a nested field, or a
        // materialised struct-valued call) into the declared slot.
        if (auto sourceOffset = structValueOffsetOrNull(source)) {
            _code ~= Instruction(
                Op.copy,
                offset,
                *sourceOffset,
                cast(ushort) typeFacts(variable.type).byteWidth,
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
                        typeFacts(fieldType).byteWidth,
                        string_,
                    );
                    materialised = true;
                    continue;
                }

                const elementSize =
                    TypeFacts.fromOpcode(ScalarType.char_).byteWidth;
                const elementCount =
                    typeFacts(fieldType).byteWidth / elementSize;
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
            typeFacts(type).byteWidth, staticArrayAlign(type),
        );
    }

    // Store each provided field of a struct literal into the inline block at
    // `base + field.offset`. Omitted trailing fields keep their zeroed default;
    // a static-array field initialised from a scalar broadcasts that scalar to
    // every element, and a dynamic-array field copies its slice descriptor.
    private void compileStructLiteralInto(
        in ushort base,
        StructLiteralExp literal,
        bool isReturnEscaping = false,
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
                // Forward `isReturnEscaping` into the nested literal: a field
                // nested arbitrarily deep inside a literal that is itself the
                // direct `return` expression is filled by this same
                // synchronous call, before the enclosing `return` runs, so a
                // capturing `Tdelegate` field at any depth is exactly as sound
                // to heap-escape as one at the top level (see the `Tdelegate`
                // branch below).
                if (auto inner = element.isStructLiteralExp)
                    compileStructLiteralInto(fieldOffset, inner, isReturnEscaping);
                continue;
            }

            if (fieldType.toBasetype.ty == TY.Tsarray) {
                storeStaticArrayField(fieldOffset, fieldType, element);
                continue;
            }

            if (fieldType.toBasetype.ty == TY.Tarray) {
                compileDynamicArrayInto(
                    fieldOffset, dynamicArrayElementType(fieldType), element,
                    arrayElementIsArray(fieldType),
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

                // A field of a literal that is itself the direct `return`
                // expression (`isReturnEscaping`, set by
                // `structLiteralReturnOffset` and forwarded through every
                // nested `Tstruct` field above regardless of depth) is
                // heap-escape-aware here: the same capturing delegate
                // embedded anywhere else (a plain local's own struct
                // literal, a call argument, ...) still resolves through the
                // ordinary frame-relative `delegateOperandOffset` below.
                if (isReturnEscaping) {
                    auto function_ = returnedDelegateFunctionOrNull(element);
                    if (function_ !is null && function_.outerVars.length != 0) {
                        if (auto heapContext =
                                heapClosureContextOrNull(function_)) {
                            emitDelegateValue(
                                fieldOffset, function_, *heapContext,
                            );
                            continue;
                        }
                        throwFrameEscapingDelegateDiagnostic(element);
                    }
                }

                const source = delegateOperandOffset(element);
                _code ~= Instruction(
                    Op.copy, fieldOffset, source, cast(ushort) delegateValueSize,
                );
                continue;
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
                cast(ushort) typeFacts(fieldType).byteWidth,
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
                typeFacts(fieldType).byteWidth,
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
            const elementSize =
                typeFacts(fieldType.toBasetype.nextOf).byteWidth;
            const count = typeFacts(fieldType).byteWidth / elementSize;
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

    private Operand storageAddressOrValue(Expression expression) {
        import std.conv: text;

        if (isPointerType(expression.type))
            return compileExpression(expression);
        if (auto address = placeAddressOrNull(expression))
            return *address;
        if (expression.type !is null &&
            typeFacts(expression.type).isAggregate) {
            const value = aggregateValueOffset(
                expression.type, expression, false,
            );
            return *addressOperand(Op.frameAddress, value, ScalarType.void_);
        }
        throw new Exception(text(
            "Unsupported address or value in bytecode core: ",
            expressionChars(expression),
        ));
    }

    // Resolve the object pointer for a class method call. Struct receivers use
    // the shared place/address path in `compileCall`.
    private Operand compileClassReceiver(CallExp call) {
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

    // The inline frame offset of a struct-valued expression. Lvalues resolve
    // and load through Place; literals materialise directly.
    private ushort structOperandOffset(Expression expression) {
        import std.conv: text;

        expression = initializerExpression(expression);

        if (auto value = structValueOffsetOrNull(expression))
            return *value;

        throw new Exception(text(
            "Unsupported struct value in bytecode core: ",
            expressionChars(expression),
        ));
    }

    private ushort* structValueOffsetOrNull(Expression expression) {
        expression = initializerExpression(expression);

        if (auto comma = expression.isCommaExp) {
            compileExpression(comma.e1);
            return structValueOffsetOrNull(comma.e2);
        }
        if (auto place = placeOrNull(expression)) {
            auto result = new ushort;
            *result = loadPlaceValue(*place).offset;
            return result;
        }
        if (auto literal = expression.isStructLiteralExp) {
            auto result = new ushort;
            *result = compileStructLiteralOperand(literal).offset;
            return result;
        }
        return null;
    }

    // The inline frame offset of an aggregate-valued expression. Structs use
    // their existing lvalue/literal resolver; static arrays use the shared
    // value materializer so a literal is copied as its own bytes rather than
    // being mistaken for a struct literal.
    private ushort aggregateOperandOffset(Type type, Expression expression) {
        import dmd.astenums: TY;
        import std.conv: text;

        if (type.toBasetype.ty == TY.Tsarray) {
            const offset = allocateBytes(
                typeFacts(type).byteWidth, staticArrayAlign(type),
            );
            if (compileStaticArrayValueInto(offset, type, expression))
                return offset;
            throw new Exception(text(
                "Unsupported static array value in bytecode core: ",
                expressionChars(expression),
            ));
        }

        return structOperandOffset(expression);
    }

    // Whether `declaration`'s captured-local access from the function
    // CURRENTLY compiling (`_currentFunction`) should go through a
    // heap-block pointer rather than a live frame slot: true only when
    // `_currentFunction` is itself the specific escaping lambda
    // `heapClosureContextOrNull` heap-boxed `declaration` for. A sibling
    // nested function that also happens to read the same enclosing local,
    // or a later compile of the SAME lambda body reached from a call made
    // while its frame context was still a live frame-base index (both
    // declined by `heapClosureContextOrNull` itself -- see its own
    // `nestedrefs`/`_frameContextDelegates` checks), never reach this true.
    private bool isHeapClosureVar(VarDeclaration declaration) {
        auto forFunction = _currentFunction in _heapClosureVars;
        return forFunction !is null && declaration in *forFunction;
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

        const declaredTy = declaration.type.toBasetype.ty;
        if (declaredTy == TY.Tstruct || declaredTy == TY.Tsarray) {
            const destination = allocateStructBlock(declaration.type);
            _code ~= Instruction(
                Op.frameLoad,
                destination,
                capturedFrameIndex(_capturedOwners[declaration], capturedOffset),
                cast(ushort) typeFacts(declaration.type).byteWidth,
            );
            return Operand(destination, ScalarType.void_);
        }

        const type = scalarType(declaration.type);
        const valueSize = size(type);
        const destination = allocateBytes(valueSize, valueSize);
        if (isHeapClosureVar(declaration))
            emitPointerLoad(
                destination, _nestedContextOffset,
                compileSizeConstant(
                    _heapClosureOffsets[_currentFunction][declaration] / valueSize,
                ),
                valueSize,
            );
        else
            _code ~= Instruction(
                Op.frameLoad,
                destination,
                capturedFrameIndex(_capturedOwners[declaration], capturedOffset),
                cast(ushort) valueSize,
            );
        if (declaredTy == TY.Tclass)
            return Operand(
                destination, ScalarType.ulong_, true, ScalarType.void_,
            );
        // A captured pointer local (`int* p; void nested() { return *p; }`):
        // the load above already moves the right 8-byte value (`scalarType`
        // maps `Tpointer` to `ScalarType.ulong_` same as any other captured
        // scalar), but the resulting `Operand` also needs `isPointer`/
        // `pointerElement` set, exactly as a plain (non-captured) pointer
        // local's own `VarExp` read already tags it -- otherwise a dereference
        // of the captured value
        // (`*p`/`p[i]`) throws "Unsupported pointer dereference in
        // bytecode core". Module pointer places carry the same metadata for
        // their own `VarExp` reads.
        if (declaredTy == TY.Tpointer)
            return Operand(
                destination, ScalarType.ulong_, true,
                pointerElementScalar(declaration.type),
            );
        return Operand(destination, type);
    }

    private void storeCapturedLocal(
        VarDeclaration declaration,
        in ushort capturedOffset,
        in Operand value,
    ) {
        import dmd.astenums: TY;

        const ty = declaration.type.toBasetype.ty;
        const isAggregate = ty == TY.Tstruct || ty == TY.Tsarray;
        const valueSize = isAggregate
            ? typeFacts(declaration.type).byteWidth
            : typeFacts(declaration.type).byteWidth;
        if (isHeapClosureVar(declaration))
            emitPointerStore(
                value.offset, _nestedContextOffset,
                compileSizeConstant(
                    _heapClosureOffsets[_currentFunction][declaration] / valueSize,
                ),
                valueSize,
            );
        else
            _code ~= Instruction(
                Op.frameStore,
                value.offset,
                capturedFrameIndex(_capturedOwners[declaration], capturedOffset),
                cast(ushort) valueSize,
            );
    }

    // Records `variable`'s frame offset alongside the function currently
    // being compiled -- the frame that offset is relative to -- so a later
    // read from a differently-nested function can find its way back to it
    // (`capturedFrameIndex`).
    private void registerCapturedOffset(VarDeclaration variable, in ushort offset) {
        _capturedOffsets[variable] = offset;
        _capturedOwners[variable] = _currentFunction;
    }

    // The frame index (an absolute `stack[]` slot, offset by `capturedOffset`)
    // of a captured variable declared in `owner`'s own frame, read or written
    // from the function currently being compiled.
    //
    // A call site always hands a callee its own live frame as that callee's
    // received context (`compileCall`'s `Op.frameBaseIndex`), matching real D:
    // a nested function's context is its immediate enclosing function's frame,
    // never a further ancestor's. So the current function's own received
    // context (`_nestedContextOffset`) is exactly one hop -- its immediate
    // enclosing function's frame -- which is `owner` only for a single level
    // of nesting. When `owner` sits further up, each intermediate ancestor's
    // own received context is a further hop: it lives at that ancestor's own
    // `nestedContextOffset` within the frame just reached, and that frame is
    // still live on the stack as the current call's (transitive) caller.
    private ushort capturedFrameIndex(in FuncDeclaration owner, in ushort capturedOffset) {
        import std.conv: text;

        ushort contextBase =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        if (_nestedContextOffset == ushort.max && _hasThis &&
            _thisLocal.declaration !is null &&
            _thisLocal.declaration.isNested)
            emitPointerLoad(
                contextBase, _thisLocal.offset, compileSizeConstant(0),
                cast(uint) size_t.sizeof,
            );
        else
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

            for (auto ancestor = enclosingMethodOf(_currentFunction);
                 ancestor !is null && ancestor !is owner;
                 ancestor = enclosingMethodOf(ancestor))
            {
                const ancestorLayout = parameterLayout(ancestor);
                // An intermediate ancestor with no relayable context of its
                // own (a struct method whose hidden `this` receiver takes
                // the nested-context slot instead, `capturedThisStructDeclaration`)
                // cannot forward a further hop; this shape is not modelled.
                if (!ancestorLayout.hasNestedContext)
                    throw new Exception(text(
                        "Unsupported multi-level captured-variable access ",
                        "in bytecode core: `",
                        ancestor.ident is null ? "" : ancestor.ident.toString,
                        "` has no relayable nested-function context",
                    ));
                const slotAddress =
                    allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
                _code ~= Instruction(
                    Op.addInt8, slotAddress, contextBase,
                    compileSizeConstant(ancestorLayout.nestedContextOffset),
                );
                const nextContext =
                    allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
                _code ~= Instruction(
                    Op.frameLoad, nextContext, slotAddress,
                    cast(ushort) size_t.sizeof,
                );
                contextBase =
                    allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
                _code ~= Instruction(
                    Op.subInt8, contextBase, nextContext, compileSizeConstant(1),
                );
            }
        }
        const sourceIndex =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const offsetConstant = compileSizeConstant(capturedOffset);
        _code ~= Instruction(
            Op.addInt8, sourceIndex, contextBase, offsetConstant,
        );
        return sourceIndex;
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

        const blockSize = typeFacts(newExp.newtype).byteWidth;

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
        compileDefaultClassFields(pointer, classType.sym);
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

    // Mirror compileDefaultStructFields for a heap-allocated class object:
    // native codegen copies a class's `.init` template -- every own and
    // inherited field's declared default -- into the new block before any
    // constructor body runs. `allocClass` only zero-fills, so walk the base
    // chain (matching classFieldNamed's own field iteration) and write each
    // field's own initializer through storeClassField first; an explicit
    // constructor body or the no-constructor positional-argument path
    // (initialiseClassObject) runs afterwards and its own field writes
    // override these defaults, matching D's default-then-constructor order.
    private void compileDefaultClassFields(
        in ushort pointer,
        ClassDeclaration class_,
    ) {
        import dmd.astenums: TY;

        for (auto current = class_; current !is null; current = current.baseClass)
            foreach (field; current.fields) {
                if (field.type.toBasetype.ty == TY.Tarray) {
                    compileDefaultClassArrayField(pointer, field);
                    continue;
                }

                auto initializer =
                    field._init is null ? null : field._init.isExpInitializer;
                if (initializer is null)
                    continue;

                storeClassField(
                    pointer, field, initializerExpression(initializer.exp),
                );
            }
    }

    // A `Tarray` class field's own default initializer (`class C { int[]
    // arr = [1, 2, 3]; }`) parses as an `ArrayInitializer`, not the
    // `ExpInitializer` the loop above recognises directly -- the same DMD
    // AST quirk `moduleDynamicArrayInitializerExpressionOrNull` already
    // normalises for a module variable via `initializerToExpression`, so
    // without this every `Tarray`-typed class field default was silently
    // skipped (left zeroed by `allocClass`), not only an array-of-arrays
    // one. A constant-scalar-element array literal (the shape
    // `moduleDynamicArrayLiteralInitializerBytes` already supports) needs
    // more than normalisation, though: confirmed against real `dmd` that
    // every `new C()` which does not override the field shares one static
    // backing array (mutating the array through one instance is visible
    // through another) -- the same way a class's `.init` template is one
    // static blob every allocation copies -- so a per-`new`-site runtime
    // `compileDynamicArrayInto` build (fresh heap array per instance) would
    // be observably wrong. `classFieldArraySharedDefaultOrNull` computes
    // that shared `{pointer, count}` once per field, using module dynamic-array
    // registration's `literalBlocks` mechanism. Every `new C()` site writes
    // the same compile-time-constant descriptor. Any other `Tarray` default
    // shape
    // (a non-literal expression, `null`, or an array-of-arrays element,
    // which `moduleDynamicArrayLiteralInitializerBytes` declines) falls
    // back to the pre-existing per-instance `storeClassField` path.
    private void compileDefaultClassArrayField(
        in ushort pointer,
        VarDeclaration field,
    ) {
        import dmd.initsem: initializerToExpression;

        if (field._init is null)
            return;

        auto rawExpression = field._init.initializerToExpression;
        if (rawExpression is null)
            return;
        auto normalized = initializerExpression(rawExpression);
        if (normalized.isNullExp)
            return;

        if (auto shared_ = classFieldArraySharedDefaultOrNull(field, normalized)) {
            const fieldPointer =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            const offset = compileSizeConstant(field.offset);
            _code ~= Instruction(Op.addInt8, fieldPointer, pointer, offset);

            const destination =
                allocateBytes(sliceDescriptorSize, size_t.sizeof);
            const pointerSlot = compileSizeConstant(shared_.pointer);
            const countSlot = compileSizeConstant(shared_.count);
            _code ~= Instruction(
                Op.copy, destination, pointerSlot, cast(ushort) size_t.sizeof,
            );
            _code ~= Instruction(
                Op.copy,
                cast(ushort) sliceDescriptorLengthOffset(destination),
                countSlot,
                cast(ushort) size_t.sizeof,
            );
            emitPointerStore(
                destination, fieldPointer, compileSizeConstant(0),
                sliceDescriptorSize,
            );
            return;
        }

        storeClassField(pointer, field, normalized);
    }

    // Compute (once per field, cached) the shared `{pointer, count}` a
    // `Tarray` class field's constant-scalar-element array-literal default
    // resolves to, or `null` when `normalized` is not that shape (an
    // array-of-arrays element, a non-literal expression, ...), so the
    // caller falls back to the ordinary per-instance path. Reuses
    // `moduleDynamicArrayLiteralInitializerBytes` -- the same
    // compile-time-bytes builder a module-level dynamic array's literal
    // default already goes through -- so this inherits its exact supported
    // shape (and its exact declined shapes) rather than reimplementing it.
    private ClassFieldArrayDefault* classFieldArraySharedDefaultOrNull(
        VarDeclaration field,
        Expression normalized,
    ) {
        if (auto existing = field in _classFieldArrayDefaults)
            return existing;

        const elementType = dynamicArrayElementType(field.type);
        const elementIsArray = arrayElementIsArray(field.type);

        size_t count;
        auto literalBytes = moduleDynamicArrayLiteralInitializerBytes(
            normalized, elementType, elementIsArray, field.type, count,
        );
        if (literalBytes is null && count == 0)
            return null;

        _program.literalBlocks ~= literalBytes;
        const blockPointer = cast(size_t) _program.literalBlocks[$ - 1].ptr;
        _classFieldArrayDefaults[field] =
            ClassFieldArrayDefault(blockPointer, count);
        return field in _classFieldArrayDefaults;
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
                arrayElementIsArray(field.type),
            );
            emitPointerStore(
                destination, fieldPointer, compileSizeConstant(0),
                sliceDescriptorSize,
            );
            return;
        }

        const value = compileExpression(valueExpression);
        emitPointerStore(
            value.offset, fieldPointer, compileSizeConstant(0),
            typeFacts(field.type).byteWidth,
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
                    arrayElementIsArray(field.type),
                );
                continue;
            }

            const value = compileExpression((*arguments)[index]);
            _code ~= Instruction(
                Op.copy,
                fieldOffset,
                value.offset,
                cast(ushort) typeFacts(field.type).byteWidth,
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

        // The hidden receiver is the same native address every other Place
        // consumer passes to a struct method.
        _code ~= Instruction(
            Op.frameAddress,
            cast(ushort) (argumentArea + layout.thisOffset),
            base,
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

    private void runStructMethodAtAddress(
        in ushort address,
        FuncDeclaration function_,
    ) {
        const index = registerFunction(function_);
        const layout = parameterLayout(function_);
        const argumentArea = allocateBytes(layout.blockSize, 8);
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (argumentArea + layout.thisOffset),
            address,
            cast(ushort) size_t.sizeof,
        );
        _code ~= Instruction(Op.call, index, argumentArea, cast(ushort) 0);
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
        import dmd.astenums: TY;

        const elementType = dynamicArrayElementType(variable.type);
        const elementIsArray = arrayElementIsArray(variable.type);
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        registerFrameDeclaration(variable).dynamicArray =
            DynamicArrayLocal(offset, elementType, elementIsArray);
        registerCapturedOffset(variable, offset);

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            _code ~= Instruction(Op.nullSlice, offset);
            return;
        }

        auto source = initializerExpression(initializer.exp);
        auto staticSource = source;
        while (auto cast_ = staticSource.isCastExp)
            staticSource = cast_.e1;
        if (auto slice = staticSource.isSliceExp)
            if (slice.lwr is null && slice.upr is null)
                staticSource = slice.e1;
        if (staticSource.type !is null &&
            staticSource.type.toBasetype.ty == TY.Tsarray)
            if (auto place = placeOrNull(staticSource)) {
                const address = addressOfPlace(*place);
                registerFrameDeclaration(variable)
                    .dynamicArray.isStaticArrayView = true;
                registerFrameDeclaration(variable)
                    .dynamicArray.staticArrayViewIsClassField = true;
                registerFrameDeclaration(variable)
                    .dynamicArray.staticArrayOffset = address.offset;
            }
        compileDynamicArrayInto(
            offset, elementType, source, elementIsArray);
    }

    // An associative array `int[int]` local holds an 8-byte handle into the
    // machine's VM-owned map table; handle `0` means "no map" (matching real
    // D's null AA), the same zero-init a plain scalar local gets from the
    // frame's own zeroing. Every map-reading/writing opcode already treats
    // handle `0` as an empty map, and `Op.aaInsert` autovivifies a fresh map
    // into the handle's own slot on first insert -- exactly like a null
    // pointer's storage location gaining an address the first time something
    // is allocated through it, distinct from any other variable that once
    // held the same null value.
    private void compileAssocArrayDeclaration(VarDeclaration variable) {
        const offset = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        registerFrameDeclaration(variable).scalar = offset;

        auto initializer =
            variable._init is null ? null : variable._init.isExpInitializer;
        if (initializer is null) {
            // The frame begins zeroed, so a null AA needs no code.
            return;
        }

        compileAssocArrayInto(
            offset, initializerExpression(initializer.exp),
        );
    }

    // Build an associative-array handle at frame offset `destination`: a fresh
    // map populated from a `[k: v, ...]` literal, a copy of another map's own
    // handle (`.dup` and a bare AA-variable initializer, both reference
    // copies matching real D's AA aliasing), or a null map.
    private void compileAssocArrayInto(
        in ushort destination,
        Expression source,
    ) {
        import std.conv: text;

        // `int[int] m;` (DMD's own default `= null` initializer) or an
        // explicit `m = null`: a null AA, matching real D. The frame begins
        // zeroed and handle `0` already reads as an empty map everywhere, so
        // this needs no code; a later insert autovivifies `m`'s own slot.
        if (source.isNullExp !is null)
            return;

        // `int[int] bb = aa;`: copy the source variable's own handle, the
        // same reference-copy semantics real D gives any AA assignment --
        // when `aa` is still null (handle `0`), this leaves `bb` equally
        // null and independently detachable rather than aliasing a shared
        // table, since each variable's handle then autovivifies its own map
        // on its own first insert.
        if (auto variable = source.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration)
                if (declarationRecordView(declaration).assocArrayOrNull)
                    if (auto handleOffset = declarationRecordView(declaration).scalarOrNull) {
                        _code ~= Instruction(
                            Op.copy, destination, *handleOffset,
                            cast(ushort) size_t.sizeof,
                        );
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

        const width = assocArrayValueWidth(literal.type.toBasetype);
        const keyMeta = assocArrayKeyMeta(literal.type.toBasetype);
        _code ~= Instruction(Op.aaNew, destination);
        foreach (index; 0 .. literal.keys.length) {
            const keyOffset = assocArrayKeyOffset(
                (*literal.keys)[index], literal.type.toBasetype,
            );
            const value = compileExpression((*literal.values)[index]);
            _code ~= Instruction(
                Op.aaInsert, destination, keyOffset, value.offset,
                cast(ushort) width, keyMeta,
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
            compileArrayDuplication(
                destination, elementType, duplicate, elementIsArray,
            );
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

        // An lvalue array source loads its descriptor through the same Place
        // used by mutation, preserving D's shared-backing assignment.
        if (auto place = placeOrNull(source)) {
            const value = loadPlaceValue(*place);
            _code ~= Instruction(
                Op.copy,
                destination,
                value.offset,
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

        // An array-of-arrays literal (`[[..], [..]]`, any nesting depth):
        // each element is itself an array, stored as a 16-byte descriptor.
        // Build each inner array into a fresh descriptor slot and store it
        // into the outer block. A row is itself an array-of-arrays (depth 3
        // and beyond, e.g. `int[][][]`'s `int[][]` rows) when *its own*
        // element is an array too -- checked fresh per recursive call
        // rather than reusing the caller's `elementIsArray`, since that
        // flag describes this level's rows, not the row's own elements.
        if (elementIsArray) {
            _code ~= Instruction(
                Op.allocArray,
                destination,
                cast(ushort) sliceDescriptorSize,
                cast(ushort) count,
            );

            const rowElementIsArray =
                arrayElementIsArray(source.type.toBasetype.nextOf);
            foreach (elementIndex; 0 .. count) {
                const inner =
                    allocateBytes(sliceDescriptorSize, size_t.sizeof);
                compileDynamicArrayInto(
                    inner, elementType, (*literal.elements)[elementIndex],
                    rowElementIsArray,
                );
                const index = compileSizeConstant(elementIndex);
                emitIndexStore(inner, destination, index, sliceDescriptorSize);
            }
            return;
        }

        const elementSize =
            dynamicArrayElementSize(source.type, elementIsArray);
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
            emitIndexStore(value.offset, destination, index, elementSize);
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
            : dynamicArrayElementSize(sourceType);
        const destinationElementSize = size(destinationElementType);
        if (sourceElementSize == destinationElementSize)
            return;

        const lengthOffset = cast(ushort) sliceDescriptorLengthOffset(destination);
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
                emitIndexStore(
                    inner, destination, compileSizeConstant(elementIndex),
                    sliceDescriptorSize,
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
            emitIndexStore(
                value.offset, destination, compileSizeConstant(elementIndex),
                elementSize,
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

        auto sourcePlace = placeOrNull(source);
        if (sourcePlace is null)
            throw new Exception(text(
                "Unsupported dynamic array initializer in bytecode core: ",
                expressionChars(source),
            ));
        const sourceAddress = addressOfPlace(*sourcePlace);

        auto sourceElementType = source.type.toBasetype.nextOf;
        const sourceElementSize = typeFacts(sourceElementType).byteWidth;
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

        const count = typeFacts(source.type).byteWidth / sourceElementSize;
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            const loaded = allocateBytes(elementSize, elementSize);
            emitPointerLoad(
                loaded,
                sourceAddress.offset,
                compileSizeConstant(elementIndex),
                elementSize,
            );
            const index = compileSizeConstant(elementIndex);
            emitIndexStore(
                loaded, destination, index, elementSize,
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
                emitIndexStore(
                    slot, destination, compileSizeConstant(elementIndex),
                    elementSize,
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
            emitIndexStore(
                slot, destination, compileSizeConstant(elementIndex),
                elementSize,
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
        import dmd.astenums: TY;
        import std.conv: text;

        // `new T[][](rows, cols)`: both lengths arrive in `new_.arguments`; build
        // an outer array of `rows` inner arrays, each of `cols` elements.
        // `new T[N][](rows)`: only `rows` is a runtime argument -- the inner
        // length `N` is a compile-time static-array bound baked into the
        // element's own type (`new_.type`'s `Tsarray` element), not a second
        // `NewExp` argument, so it is loaded as a constant instead of compiled
        // from a second argument expression that does not exist.
        if (elementIsArray) {
            auto innerElement = new_.type.toBasetype.nextOf;
            const innerIsStatic =
                innerElement.toBasetype.ty == TY.Tsarray;

            if (innerIsStatic && new_.arguments !is null &&
                new_.arguments.length == 1) {
                const dimensions =
                    allocateBytes(2 * size_t.sizeof, size_t.sizeof);
                const rows = compileExpression((*new_.arguments)[0]);
                _code ~= Instruction(
                    Op.copy,
                    dimensions,
                    rows.offset,
                    cast(ushort) size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.loadConstant,
                    cast(ushort) (dimensions + size_t.sizeof),
                    constantIndex(staticArrayLength(innerElement)),
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

            // `new T[][](rows)`: the inner element is itself a dynamic array
            // (not a `Tsarray` row), so there is no compile-time row width to
            // bake in and no second runtime argument either -- each of the
            // `rows` outer slots simply default-inits to its own null slice,
            // the same zero-filled 16-byte descriptor a bare `T[]` local
            // starts with. Fill with `0x00` unconditionally rather than
            // `packedFill(elementType)`: that call's char/wchar special case
            // targets a scalar *data* fill, not this level's slice
            // descriptors.
            if (!innerIsStatic && new_.arguments !is null &&
                new_.arguments.length == 1) {
                const length = compileExpression((*new_.arguments)[0]);
                _code ~= Instruction(
                    Op.allocArrayDynamic,
                    destination,
                    cast(ushort) sliceDescriptorSize,
                    length.offset,
                );
                return;
            }

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

        const elementSize = dynamicArrayElementSize(
            slice.e1.type,
            descriptor.elementIsArray,
        );
        emitSubSlice(destination, descriptor.offset, bounds, elementSize);
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

        const byteStride = pointerElementMetadata(slice.e1.type).byteWidth;
        emitPointerSlice(destination, pointer.offset, bounds, byteStride);
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
        const elementIsArray = arrayElementIsArray(cat.type);
        const elementSize = dynamicArrayElementSize(cat.type, elementIsArray);
        const left = catOperandDescriptor(
            elementType, elementSize, elementIsArray, cat.e1,
        );
        const right = catOperandDescriptor(
            elementType, elementSize, elementIsArray, cat.e2,
        );
        emitConcatArrays(destination, left, right, elementSize);
    }

    // A 16-byte slice descriptor for one side of a concatenation: an array
    // operand uses its existing descriptor (materialised if needed); an element
    // operand (`x ~ arr`) is stored into a fresh one-element heap block.
    // `elementSize` is the concatenation's own array element width (from
    // `dynamicArrayElementSize`, not a bare `size(elementType)`, since
    // `elementType` is only `void_` for a struct/static-array element).
    private ushort catOperandDescriptor(
        in ScalarType elementType,
        in uint elementSize,
        in bool elementIsArray,
        Expression operand,
    ) {
        import dmd.astenums: TY;

        if (operand.type !is null &&
            operand.type.toBasetype.ty == TY.Tarray)
            return dynamicArrayDescriptor(operand).offset;

        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.allocArray, offset, cast(ushort) elementSize, 1,
        );
        const value = compileExpression(operand);
        const index = compileSizeConstant(0);
        emitIndexStore(value.offset, offset, index, elementSize);
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
        in bool elementIsArray = false,
    ) {
        // The dup argument is the source array wrapped in an
        // implicit-const cast; unwrap it so a known dynamic-array local reuses
        // its descriptor in place rather than failing the cast.
        auto array = source;
        while (auto cast_ = array.isCastExp)
            array = cast_.e1;

        const sourceDescriptor = dynamicArrayDescriptor(array).offset;
        const elementSize = dynamicArrayElementSize(
            array.type,
            elementIsArray,
        );
        emitDupArray(destination, sourceDescriptor, elementSize);
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
            const targetElementSize = dynamicArrayElementSize(
                cast_.to,
                elementIsArray,
            );
            const sourceElementIsArray = arrayElementIsArray(cast_.e1.type);
            const sourceElementSize = dynamicArrayElementSize(
                cast_.e1.type,
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
        const elementByteWidth = dynamicArrayElementSize(
            cast_.e1.type,
            descriptor.elementIsArray,
        );
        return pointerToElement(
            descriptor.offset, descriptor.elementType, compileSizeConstant(0),
            elementByteWidth,
        );
    }

    // The runtime address of `outer[i]`'s separately heap-allocated inner row:
    // read the row's
    // own 16-byte slice descriptor out of `outer`'s backing store and take its
    // `.ptr` field. Shared with row assignment so writing a whole new row's
    // worth of values lands in the same heap block a pointer taken earlier
    // still addresses, instead of a fresh, differently addressed block.
    private ushort innerArrayRowPointer(
        in DynamicArrayLocal descriptor,
        in ushort indexSlot,
    ) {
        const inner = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        emitIndexLoad(inner, descriptor.offset, indexSlot, sliceDescriptorSize);
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
        return advanceStaticArrayPointer(
            *addressOperand(
                Op.frameAddress,
                baseOffset,
                ScalarType.void_,
            ),
            indexExpression,
            elementType,
            lengthSlot,
        );
    }

    // The real element pointer for a `DynamicArrayLocal` static-array view
    // (`__r[i]` inside `foreach (ref e; arr) ...`'s lowered loop): a local's
    // or struct field's base is a frame offset, resolved via
    // `Op.frameAddress` (`staticArrayElementPointer`); a class field's base
    // is already the runtime pointer resolved by its place.
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
            compileSizeConstant(typeFacts(elementType).byteWidth);
        _code ~= Instruction(Op.mulInt8, scaled, indexSlot.offset, stride);

        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.addInt8, pointer, basePointer.offset, scaled);

        const ty = elementType.toBasetype.ty;
        const pointerElement = ty == TY.Tsarray ||
            ty == TY.Tstruct ||
            ty == TY.Tarray ||
            ty == TY.Tdelegate
                ? ScalarType.void_
                : scalarType(elementType);
        return Operand(pointer, ScalarType.ulong_, true, pointerElement);
    }

    // Materialise a real address from a frame or module-data offset. Keep
    // address-producing places on this one path so a resolver can select the
    // storage kind without duplicating pointer-slot construction.
    private Operand* addressOperand(
        in Op opcode,
        in ushort offset,
        in ScalarType elementType,
    ) {
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(opcode, pointer, offset);
        auto result = new Operand;
        *result =
            Operand(pointer, ScalarType.ulong_, true, elementType);
        return result;
    }

    private Operand* symbolAddress(
        VarDeclaration declaration,
        in long offset,
        Type pointerType,
    ) {
        if (declaration is null)
            return null;
        auto existing = declarationRecordView(declaration).scalarOrNull;
        auto dynamicArray = declarationRecordView(declaration).dynamicArrayOrNull;
        auto staticArray = declarationRecordView(declaration).staticArrayOrNull;
        auto struct_ = declarationRecordView(declaration).struct_OrNull;
        if (existing !is null)
            if (auto element = declarationRecordView(declaration).refPointerOrNull) {
                auto result = new Operand;
                *result = pointerPlaceAddress(
                    *existing,
                    compileSizeConstant(cast(size_t) offset),
                    1,
                    *element,
                );
                return result;
            }
        if (existing is null && dynamicArray is null &&
            staticArray is null && struct_ is null) {
            if (auto pointer = tryAddressOfCaptured(
                    declaration, pointerType.toBasetype.nextOf))
                return pointer;
            if (auto moduleStruct = moduleDeclarationRecord(declaration).moduleStructOrNull) {
                if (offset != 0)
                    return null;
                return addressOperand(
                    Op.moduleAddress,
                    moduleStruct.offset,
                    ScalarType.void_,
                );
            }
            auto moduleVariable = moduleDeclarationRecord(declaration).moduleScalarOrNull;
            if (moduleVariable is null || offset != 0)
                return null;
            return addressOperand(
                Op.moduleAddress,
                moduleVariable.offset,
                moduleVariable.type,
            );
        }

        const base = existing !is null
            ? *existing
            : dynamicArray !is null
                ? dynamicArray.offset
                : staticArray !is null
                    ? *staticArray
                    : struct_.offset;
        const slot = cast(ushort) (base + offset);
        return addressOperand(
            Op.frameAddress,
            slot,
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
                    ? pointerElementScalar(pointerType)
                    : scalarType(declaration.type))
                : ScalarType.void_,
        );
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

    private Operand* tryAddressOfCaptured(
        VarDeclaration declaration,
        Type pointedType,
    ) {
        auto captured = declaration in _capturedOffsets;
        if (!_hasNestedContext || captured is null)
            return null;

        const sourceIndex = capturedFrameIndex(_capturedOwners[declaration], *captured);
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

    // A pointer operand holding `descriptor.ptr + index * elementByteWidth`:
    // read the descriptor's pointer word, scale the index by the element's
    // real byte width, and add. `elementByteWidth` is the caller's own byte
    // stride (`dynamicArrayElementSize`, not `program.size(elementType)`):
    // an aggregate element (struct, static array, delegate) reports
    // `ScalarType.void_` as its opcode type, and `size(void_) == 0` would
    // silently collapse every index to element 0 instead of throwing --
    // opcode scalar type and native byte stride are separate facts
    // (`ai/plans/bytecode.md`'s "Pointer metadata" section).
    private Operand pointerToElement(
        in ushort descriptorOffset,
        in ScalarType elementType,
        in ushort indexSlot,
        in uint elementByteWidth,
    ) {
        const pointer = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, pointer, descriptorOffset, cast(ushort) size_t.sizeof,
        );
        return offsetPointer(pointer, elementType, indexSlot, elementByteWidth);
    }

    // Advance the `size_t` pointer at `pointerOffset` by `index *
    // elementByteWidth` into a fresh pointer slot, the shared scaling for
    // `&arr[i]` and `.ptr`. See `pointerToElement` above for why the byte
    // stride is an explicit caller-supplied fact rather than derived from
    // `elementType`.
    private Operand offsetPointer(
        in ushort pointerOffset,
        in ScalarType elementType,
        in ushort indexSlot,
        in uint elementByteWidth,
    ) {
        const scaled = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const stride = compileSizeConstant(elementByteWidth);
        _code ~= Instruction(Op.mulInt8, scaled, indexSlot, stride);
        const result = allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(Op.addInt8, result, pointerOffset, scaled);
        return Operand(result, ScalarType.ulong_, true, elementType);
    }

    // Read `size(elementType)` bytes from `[pointer + index * size]` into a
    // fresh element slot, the shared loader for `*p` and `p[i]`.
    private Operand loadThroughPointer(
        in Operand pointer,
        in ushort indexSlot,
    ) {
        const elementSize = size(pointer.pointerElement);
        const offset = allocateBytes(elementSize, elementSize);
        emitPointerLoad(offset, pointer.offset, indexSlot, elementSize);
        return Operand(offset, pointer.pointerElement);
    }

    // A value loaded through a pointer whose static D type is itself a
    // pointer (`int** p; *p`, or a function-pointer value loaded through
    // `*pp`/`pp[i]`) must carry `isPointer` so a further dereference, index,
    // or indirect call sees a pointer operand instead of the plain scalar
    // `loadThroughPointer` returns by default.
    private Operand asPointerValue(in Operand loaded, Type type) {
        if (!isPointerType(type))
            return loaded;

        return Operand(
            loaded.offset, loaded.type, true, pointerElementScalar(type),
        );
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
    // lvalue's declared type; the shared resolver composes through that cast,
    // while `assign.e1.type` still gives the operation type directly.
    private Operand compileDivOrModCompoundAssign(
        BinExp assign,
        in bool isModulo,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        auto place = placeOrNull(assign.e1);
        if (place is null || place.isPointerValue)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));
        const rhs = compileExpression(assign.e2);

        const lvalueType = place.type;
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
            loadPlace(*place),
            operationType,
        );
        const rhsValue = integerOperationOperand(rhs, operationType);
        const destination = allocate(operationType);
        _code ~= Instruction(op, destination, lhs.offset, rhsValue.offset);
        storePlace(*place, Operand(destination, operationType));
        return loadPlace(*place);
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
    // `compileTruthValue`'s pointer branch. `dynamicArrayDescriptor` loads a
    // resolved place or materialises a non-lvalue once, so every `T[]`/string
    // source yields the same {ptr, length} descriptor. Every other operand
    // goes through `compileTruthValue` directly.
    private Operand compileBoolCondition(Expression expression) {
        if (isStringType(expression.type) || isDynamicArrayArgument(expression)) {
            const array = dynamicArrayDescriptor(expression);
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
        // `++x`/`x += n` on an integer local: 4-byte and 8-byte integer widths
        // (size_t is ulong on x86-64, so `++len` lands here) share the lvalue's
        // own slot as the destination. Narrow integer locals promote for the
        // operation and copy only their storage width back, preserving wrapping.
        return compileScalarIntegerCompoundAssign(
            addAssign,
            Op.addInt4,
            Op.addInt8,
            "Unsupported compound assignment in bytecode core: ",
        );
    }

    private Operand compileScalarIntegerCompoundAssign(
        BinExp assign,
        in Op op4,
        in Op op8,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        const rhs = compileExpression(assign.e2);
        auto place = placeOrNull(assign.e1);
        if (place is null)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        if (place.isPointerValue) {
            if (op4 != Op.addInt4 || op8 != Op.addInt8)
                throw new Exception(text(
                    unsupportedMessage,
                    expressionChars(assign),
                ));
            const lhs = loadPlace(*place);
            const destination = allocate(ScalarType.ulong_);
            _code ~= Instruction(
                Op.addInt8, destination, lhs.offset, rhs.offset,
            );
            const value = Operand(destination, ScalarType.ulong_);
            storePlace(*place, value);
            return Operand(
                destination, ScalarType.ulong_, true,
                place.pointerElement,
            );
        }

        return compileScalarIntegerCompoundAssign(
            *place, rhs, assign, op4, op8, unsupportedMessage,
        );
    }

    private Operand compileScalarIntegerCompoundAssign(
        Place place,
        in Operand rhs,
        BinExp assign,
        in Op op4,
        in Op op8,
        in string unsupportedMessage,
    ) {
        import std.conv: text;

        const lvalueType = place.type;
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
            loadPlace(place),
            operationType,
        );
        const rhsValue = integerOperationOperand(
            rhs,
            isEightByteInteger(lvalueType) && eightByteShift
                ? ScalarType.int_
                : operationType,
        );
        const destination = allocate(operationType);
        const operation = isEightByteInteger(operationType)
            ? op8
            : op4 == Op.shrInt4 && lvalueType == ScalarType.uint_
                ? Op.ushrInt4
                : op4;
        _code ~= Instruction(
            operation,
            destination,
            lhs.offset,
            rhsValue.offset,
        );
        const value = Operand(destination, operationType);
        storePlace(place, value);
        return loadPlace(place);
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

    // Assignment resolves its destination once. Slice assignment has its own
    // multi-element place; every scalar or whole-value lvalue uses one Place
    // and one store regardless of its storage or access shape.
    private Operand compileAssignExpression(AssignExp assign) {
        import std.conv: text;

        if (auto registryAssign = tryStaticDelegateAssocArrayAssign(assign))
            return *registryAssign;

        // `arr.length = n`: resize the array in place, preserving existing
        // elements and zero-filling growth. Detected by the ArrayLengthExp
        // lvalue (DMD wraps this in a LoweredAssignExp), not a druntime name.
        if (auto length = assign.e1.isArrayLengthExp)
            return compileArrayLengthAssign(length, assign.e2);

        auto place = placeOrNull(assign.e1);
        if (place is null)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(assign),
            ));

        if (place.valueType !is null || place.kind == Place.Kind.slice)
            return storeExpressionIntoPlace(*place, assign.e2);

        const rhs = compileExpression(assign.e2);
        if (rhs.type != place.type)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(assign),
            ));
        storePlace(*place, rhs);
        return place.isPointerValue
            ? Operand(rhs.offset, rhs.type, true, place.pointerElement)
            : rhs;
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

    private Operand* tryStaticDelegateAssocArrayAssign(AssignExp assign) {
        auto declaration =
            staticDelegateAssocArrayAssignDeclaration(assign.e1);
        if (declaration is null)
            return null;

        auto function_ = delegateInitializerFunctionOrNull(assign.e2);
        if (function_ is null)
            return null;

        _staticDelegateAssocArrays[declaration] = function_;

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

    private DeclarationRecord* moduleDeclarationRecord(
        VarDeclaration declaration,
    ) {
        if (declaration is null)
            return &_unavailableDeclaration;
        auto record = declarationRecord(declaration);
        if (!record.moduleClassificationAttempted) {
            record.moduleClassificationAttempted = true;
            classifyModuleDeclaration(declaration);
        }
        return record;
    }

    private void classifyModuleDeclaration(VarDeclaration declaration) {
        if (!declaration.isDataseg || declaration.isImmutable)
            return;

        final switch (declarationRecord(declaration).facts.representation)
            with (DeclarationRepresentation)
        {
            case unavailable:
            case lazyDelegate:
                return;
            case scalar:
            case pointer:
            case classPointer:
            case assocArray:
                allocateModuleScalarVariable(declaration);
                return;
            case dynamicArray:
                allocateModuleDynamicArrayVariable(declaration);
                return;
            case staticArray:
            case vector:
                allocateModuleStaticArrayVariable(declaration);
                return;
            case struct_:
                allocateModuleStructVariable(declaration);
                return;
            case delegate_:
                allocateModuleDelegateVariable(declaration);
                return;
            case complexDouble:
                allocateModuleComplexVariable(declaration);
                return;
        }
    }

    private ModuleScalarVariable* allocateModuleScalarVariable(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        // A module-level pointer (`int* p;`) is just a size_t-width value:
        // `scalarType` already maps `Tpointer` to `ScalarType.ulong_` for
        // locals, so it falls straight through the generic scalar path
        // below with no pointer-specific storage needed. The frontend
        // itself refuses a non-null initializer for a dataseg pointer
        // (`cannot take address of thread-local variable ... at compile
        // time`), so the only initializer this ever sees in practice is
        // the implicit default (null); `moduleScalarInitializerBytes`
        // handles that as well as an explicit `= null` initializer.
        //
        // A module-level associative array (`int[string] counts;`) is the
        // same shape: `scalarType` already maps `Taarray` to
        // `ScalarType.ulong_` (its opaque VM-map handle, an index rather
        // than a real address -- unlike a pointer or class reference it is
        // never dereferenced directly, only ever passed to the AA runtime
        // hooks), so it too falls straight through the generic scalar path
        // with no AA-specific storage needed here. Only the implicit
        // default (null) initializer is handled -- a non-null AA literal
        // initializer (`= ["a": 1]`) falls through to
        // `moduleScalarInitializerBytes`'s "Unsupported module scalar
        // initializer" throw, same as any other unhandled constant shape.
        // `resolveAssocArrayOperand` (the AA hooks' own handle resolver)
        // reads and, for an insert that autovivifies a still-null handle,
        // writes back this storage; see its own comment.
        if (auto existing = declarationRecordView(declaration).moduleScalarOrNull)
            return existing;

        const representation =
            declarationRecord(declaration).facts.representation;
        const isClassReference =
            representation == DeclarationRepresentation.classPointer;
        if (isClassReference &&
            !moduleVariableHasDefaultInitializer(declaration))
            return null;

        const isPointer = representation == DeclarationRepresentation.pointer;
        const type = isClassReference
            ? ScalarType.ulong_
            : scalarType(declaration.type);
        const initializer = isClassReference
            ? null
            : moduleScalarInitializerBytes(declaration, type);
        const offset = allocateModuleBytes(size(type), size(type));
        registerModuleDeclaration(declaration).moduleScalar = ModuleScalarVariable(
            offset,
            type,
            isClassReference,
            isPointer,
            isPointer ? pointerElementScalar(declaration.type) : ScalarType.void_,
        );
        _program.moduleData[offset .. offset + initializer.length] = initializer[];
        return declarationRecordView(declaration).moduleScalarOrNull;
    }

    // A module-level dynamic array (`byte[] a;`) reserves a plain 16-byte
    // native-order slice descriptor slot, the array counterpart of the
    // scalar allocation above. The default (null) initializer leaves the
    // descriptor's bytes zeroed (a null slice); a non-null initializer that
    // is an array literal of constant scalar elements
    // (`int[] arr = [1, 2, 3];`) compiles its bytes into a fresh
    // `_program.literalBlocks` entry -- a GC-rooted block that never moves,
    // the same stable-address mechanism `appendStringLiteral` already uses
    // -- and writes {blockPointer, count} directly into the descriptor's
    // moduleData bytes right now, at registration time, exactly as
    // `moduleScalarInitializerBytes` writes a scalar's bytes directly: no
    // bytecode instruction is needed, since the compiler and the machine
    // share one process/address space, so a pointer resolved during
    // compilation stays valid for the whole run. An array-of-arrays element
    // is handled at any nesting depth (`int[][]`, `int[][][]`, and so on --
    // see `moduleDynamicArrayLiteralInitializerBytes`); a struct-typed
    // element whose own fields are constant scalars (`Point[] pts =
    // [Point(1, 2), Point(3, 4)];`) is handled too, laid out at each
    // field's own DMD-computed offset within the element's slot, the same
    // way `moduleStructLiteralInitializerBytes` lays out a whole
    // module-level struct variable's default value (see
    // `moduleDynamicArrayStructLiteralInitializerBytes`,
    // `writeStructLiteralFieldBytes`). A static-array element, or any
    // non-constant element (e.g. a function call), is not yet handled and
    // still declines registration.
    //
    // A plain array literal (`[1, 2, 3]`) parses as an `ArrayInitializer`,
    // not an `ExpInitializer` the way a scalar's `int x = 5;` does, so this
    // does not reuse `moduleVariableHasDefaultInitializer` (which only
    // recognises `ExpInitializer` and, for anything else, wrongly reports
    // "default initializer" -- the actual root cause of the bug this
    // function fixes): `moduleDynamicArrayInitializerExpressionOrNull` below
    // normalises every `Initializer` subclass via `initializerToExpression`.
    private ModuleDynamicArrayVariable* allocateModuleDynamicArrayVariable(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        if (auto existing = declarationRecordView(declaration).moduleDynamicArrayOrNull)
            return existing;

        const elementType = dynamicArrayElementType(declaration.type);
        const elementIsArray = arrayElementIsArray(declaration.type);

        auto initializerExpr =
            moduleDynamicArrayInitializerExpressionOrNull(declaration);
        // An empty array literal (`int[] arr = [];`) is semantically the
        // same as no initializer at all -- both are a null/zero-length
        // slice -- so treat it identically rather than falling into
        // `moduleDynamicArrayLiteralInitializerBytes`'s non-empty-literal
        // element inspection, which declines (returns `null`, `count == 0`)
        // on an empty `elements` array for lack of any element to inspect.
        auto emptyLiteralExpr = initializerExpr is null
            ? null : initializerExpr.isArrayLiteralExp;
        const isEmptyLiteral = emptyLiteralExpr !is null &&
            (emptyLiteralExpr.elements is null ||
                emptyLiteralExpr.elements.length == 0);
        const hasDefaultInitializer =
            initializerExpr is null || initializerExpr.isNullExp !is null ||
            isEmptyLiteral;

        size_t literalCount;
        ubyte[] literalBytes;
        if (!hasDefaultInitializer) {
            literalBytes = moduleDynamicArrayLiteralInitializerBytes(
                initializerExpr, elementType, elementIsArray,
                declaration.type, literalCount,
            );
            if (literalBytes is null && literalCount == 0)
                return null;
        }

        const offset = allocateModuleBytes(sliceDescriptorSize, size_t.sizeof);
        registerModuleDeclaration(declaration).moduleDynamicArray = ModuleDynamicArrayVariable(
            offset,
            elementType,
            elementIsArray,
        );
        if (!hasDefaultInitializer) {
            import std.bitmanip: nativeToLittleEndian;

            _program.literalBlocks ~= literalBytes;
            const pointer = cast(size_t) _program.literalBlocks[$ - 1].ptr;
            _program.moduleData[offset .. sliceDescriptorLengthOffset(offset)] =
                nativeToLittleEndian(pointer);
            _program.moduleData[
                sliceDescriptorLengthOffset(offset) .. offset + sliceDescriptorSize
            ] = nativeToLittleEndian(cast(size_t) literalCount);
        }
        return declarationRecordView(declaration).moduleDynamicArrayOrNull;
    }

    // Resolve a module-level dynamic array's initializer to a plain
    // `Expression`, regardless of which `Initializer` subclass DMD parsed it
    // into (`ExpInitializer` for `int x = 5;`, but `ArrayInitializer` for a
    // literal like `[1, 2, 3]`): see `initializerToExpression`.
    private Expression moduleDynamicArrayInitializerExpressionOrNull(
        VarDeclaration declaration,
    ) {
        import dmd.initsem: initializerToExpression;

        resolveNonRootInitializer(declaration);
        if (declaration._init is null)
            return null;

        auto expression = declaration._init.initializerToExpression;
        return expression is null ? null : initializerExpression(expression);
    }

    // Compile-time bytes for a module-level dynamic array's non-null,
    // non-default initializer, when it is a non-empty array literal of
    // constant scalar elements, or (`elementIsArray`) a non-empty array
    // literal of array-literal elements, at any nesting depth (`int[][] m =
    // [[1, 2], [3, 4]];`, `int[][][] m = [[[1, 2], [3, 4]], [[5, 6]]];`, and
    // so on) -- each inner array is built into its own stable
    // `literalBlocks` entry first, the same way `compileDynamicArrayInto`'s
    // own array-of-arrays literal branch builds each row into its own heap
    // block at runtime, so the outer bytes hold one 16-byte `{pointer,
    // count}` descriptor per row rather than raw scalar bytes. The
    // recursive call below re-derives `elementIsArray` from each row's own
    // `Expression.type` (`arrayElementIsArray`) rather than being told a
    // fixed depth by its caller, so a row that is itself another
    // `elementIsArray` shape keeps recursing through the array branch
    // instead of stopping after exactly one level; a row's leaf scalar
    // `elementType` was already resolved once up front by
    // `dynamicArrayElementType`, which itself walks arbitrarily deep
    // through the `Tarray`/`Tsarray` chain, so it stays correct at every
    // recursion depth unchanged. A row that is not itself a
    // constant-scalar-element (or further-nested-array) array literal (a
    // non-literal expression, or an empty `[]` row) declines the whole
    // array, matching the plain-scalar decline below. Returns `null` (with
    // `count` left at 0) when the initializer is not one of these shapes,
    // so the caller can tell "empty literal bytes" (`count == 0` from a
    // genuinely empty `[]` initializer, not yet given real storage either)
    // apart from "declined". `arrayType` is the array's own type at this
    // recursion level (`declaration.type`/`field.type` at the top call,
    // then each row's own `Expression.type` on the way down through the
    // `elementIsArray` branch) -- only consulted when `elementType` is
    // `ScalarType.void_` and `elementIsArray` is false, to tell a
    // struct-typed leaf element (`dynamicArrayElementType` returns
    // `void_` for `Tstruct` the same as it does for the still-declined
    // `Tsarray`/`Tdelegate` leaves) apart from those, since only the
    // struct case is handled below
    // (`moduleDynamicArrayStructLiteralInitializerBytes`).
    private ubyte[] moduleDynamicArrayLiteralInitializerBytes(
        Expression initializerExpr,
        in ScalarType elementType,
        in bool elementIsArray,
        Type arrayType,
        out size_t count,
    ) {
        import std.bitmanip: nativeToLittleEndian;
        import dmd.astenums: TY;

        if (elementType == ScalarType.void_) {
            if (elementIsArray)
                return null;

            auto elementRawType =
                arrayType is null ? null : arrayType.toBasetype.nextOf;
            if (elementRawType !is null &&
                elementRawType.toBasetype.ty == TY.Tstruct)
            {
                return moduleDynamicArrayStructLiteralInitializerBytes(
                    initializerExpr, elementRawType, count,
                );
            }
            return null;
        }

        if (elementIsArray) {
            auto outer = initializerExpr.isArrayLiteralExp;
            if (outer is null || outer.elements is null ||
                outer.elements.length == 0)
            {
                return null;
            }

            count = outer.elements.length;
            ubyte[] bytes;
            bytes.length = count * sliceDescriptorSize;
            foreach (elementIndex; 0 .. count) {
                auto element = (*outer.elements)[elementIndex];
                // Re-derive from the row's own type, rather than always
                // recursing with `false`, so a row that is itself another
                // `elementIsArray` shape (e.g. `int[][][]`'s middle-level
                // row, itself an `int[][]` whose own elements are `int[]`)
                // keeps recursing through the array branch instead of
                // stopping after exactly one level -- this is what
                // generalises this function from one fixed level of nesting
                // to arbitrary depth.
                const rowElementIsArray = element !is null &&
                    element.type !is null && arrayElementIsArray(element.type);
                size_t rowCount;
                auto rowBytes = moduleDynamicArrayLiteralInitializerBytes(
                    element, elementType, rowElementIsArray,
                    element is null ? null : element.type, rowCount,
                );
                if (rowBytes is null && rowCount == 0) {
                    count = 0;
                    return null;
                }

                _program.literalBlocks ~= rowBytes;
                const rowPointer =
                    cast(size_t) _program.literalBlocks[$ - 1].ptr;
                const rowOffset = elementIndex * sliceDescriptorSize;
                bytes[rowOffset .. sliceDescriptorLengthOffset(rowOffset)] =
                    nativeToLittleEndian(rowPointer);
                bytes[
                    sliceDescriptorLengthOffset(rowOffset)
                        .. rowOffset + sliceDescriptorSize
                ] = nativeToLittleEndian(cast(size_t) rowCount);
            }
            return bytes;
        }

        auto literal = initializerExpr.isArrayLiteralExp;
        if (literal is null || literal.elements is null ||
            literal.elements.length == 0)
        {
            return null;
        }

        count = literal.elements.length;
        const elementSize = size(elementType);
        ubyte[] bytes;
        bytes.length = count * elementSize;
        foreach (elementIndex; 0 .. count) {
            auto element = (*literal.elements)[elementIndex];
            if (auto integer = element.isIntegerExp) {
                const raw = nativeToLittleEndian(cast(ulong) integer.toInteger);
                bytes[elementIndex * elementSize .. (elementIndex + 1) * elementSize] =
                    raw[0 .. elementSize];
                continue;
            }
            if (auto real_ = element.isRealExp) {
                if (elementType == ScalarType.real_) {
                    bytes[
                        elementIndex * elementSize .. (elementIndex + 1) * elementSize
                    ] = realBytes(real_)[];
                } else {
                    const raw = nativeToLittleEndian(floatBits(real_, elementType));
                    bytes[
                        elementIndex * elementSize .. (elementIndex + 1) * elementSize
                    ] = raw[0 .. elementSize];
                }
                continue;
            }

            count = 0;
            return null;
        }
        return bytes;
    }

    // The struct-element sibling of the plain-scalar branch above
    // (`Point[] pts = [Point(1, 2), Point(3, 4)];`): each element must
    // itself be a `StructLiteralExp` (not, say, a struct-typed variable
    // reference or a constructor call the frontend hasn't folded away),
    // and its own fields must be constant scalars, exactly the shape
    // `writeStructLiteralFieldBytes` already lays out for a whole
    // module-level struct variable's default value
    // (`moduleStructLiteralInitializerBytes`) -- reused here verbatim,
    // just called once per array element into that element's own
    // `structSize`-byte slice of the outer literal's bytes rather than
    // once for the whole variable's block. `elementRawType` is the
    // element's own (already-confirmed-`Tstruct`) `Type`, resolved by the
    // caller from `arrayType.toBasetype.nextOf`. Returns `null` (with
    // `count` left at 0) when the initializer is not a non-empty array
    // literal of `StructLiteralExp` elements each satisfying
    // `writeStructLiteralFieldBytes`, matching every other decline in this
    // family.
    private ubyte[] moduleDynamicArrayStructLiteralInitializerBytes(
        Expression initializerExpr,
        Type elementRawType,
        out size_t count,
    ) {
        auto literal = initializerExpr.isArrayLiteralExp;
        if (literal is null || literal.elements is null ||
            literal.elements.length == 0)
        {
            return null;
        }

        count = literal.elements.length;
        const elementSize = cast(size_t) typeFacts(elementRawType).byteWidth;
        ubyte[] bytes;
        bytes.length = count * elementSize;
        foreach (elementIndex; 0 .. count) {
            auto element = (*literal.elements)[elementIndex];
            auto elementLiteral =
                element is null ? null : element.isStructLiteralExp;
            auto elementBytes = bytes[
                elementIndex * elementSize .. (elementIndex + 1) * elementSize
            ];
            if (!writeStructLiteralFieldBytes(elementLiteral, elementBytes)) {
                count = 0;
                return null;
            }
        }
        return bytes;
    }

    // A module-level struct (`Point p;`) reserves `Type.size()` bytes at
    // `Type.alignsize()` in `_program.moduleData`, the struct counterpart of
    // `ModuleScalarVariable`/`ModuleDynamicArrayVariable`. Its module place
    // owns both reads and writes, including nested field composition.
    private ModuleStructVariable* allocateModuleStructVariable(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        if (auto existing = declarationRecordView(declaration).moduleStructOrNull)
            return existing;

        const size = cast(ushort) typeFacts(declaration.type).byteWidth;
        const hasDefaultInitializer =
            moduleVariableHasDefaultInitializer(declaration);

        ubyte[] literalBytes;
        if (!hasDefaultInitializer) {
            literalBytes = moduleStructLiteralInitializerBytes(
                declaration, size,
            );
            if (literalBytes is null)
                return null;
        }

        const offset =
            allocateModuleBytes(size, staticArrayAlign(declaration.type));
        registerModuleDeclaration(declaration).moduleStruct =
            ModuleStructVariable(offset, size);
        if (!hasDefaultInitializer)
            _program.moduleData[offset .. offset + size] = literalBytes[];
        return declarationRecordView(declaration).moduleStructOrNull;
    }

    // A module-level fixed-size static array (`int[3] arr;`) reserves
    // `Type.size()` bytes at `Type.alignsize()` in `_program.moduleData`,
    // the Tsarray counterpart of `ModuleStructVariable` above. Unlike
    // `ModuleDynamicArrayVariable` (a 16-byte descriptor pointing at heap
    // storage), the array's own `N * elementSize` bytes live inline in
    // `moduleData`, exactly like a local static array's frame slot: element
    // access resolves a module-backed Place and reads or writes through its
    // native address, so an element operation touches only that element's
    // byte range.
    // Scoped to a scalar element type for now (`int[3]`, not `S[3]`,
    // `int[3][3]`, `int[3][]`, or a delegate/`Taarray` element): those
    // shapes decline registration, falling through to the pre-existing
    // "Unsupported variable in bytecode core" error.
    private ModuleStaticArrayVariable* allocateModuleStaticArrayVariable(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        import dmd.astenums: TY;

        auto elementType = declaration.type.toBasetype.nextOf;
        switch (elementType.toBasetype.ty) with (TY) {
            case Tstruct, Tsarray, Tarray, Taarray, Tdelegate:
                return null;
            default:
                break;
        }
        if (isComplexDoubleType(elementType))
            return null;

        if (auto existing = declarationRecordView(declaration).moduleStaticArrayOrNull)
            return existing;

        const size = cast(ushort) typeFacts(declaration.type).byteWidth;
        // A plain array literal (`[1, 2, 3]`) parses as an
        // `ArrayInitializer`, not an `ExpInitializer`, so this reuses
        // `moduleDynamicArrayInitializerExpressionOrNull`'s
        // `initializerToExpression` normalisation (its logic is entirely
        // generic over the declaration's type, despite the array-specific
        // name) rather than `moduleVariableHasDefaultInitializer`, which
        // would misclassify a literal as "no initializer" and silently drop
        // its values. Dynamic-array module registration uses the same
        // normalization.
        auto initializerExpr =
            moduleDynamicArrayInitializerExpressionOrNull(declaration);
        const hasDefaultInitializer = initializerExpr is null ||
            initializerExpr.isNullExp !is null;

        ubyte[] literalBytes;
        if (!hasDefaultInitializer) {
            literalBytes = moduleStaticArrayLiteralInitializerBytes(
                initializerExpr.isArrayLiteralExp, elementType, size,
            );
            if (literalBytes is null)
                return null;
        }

        const offset =
            allocateModuleBytes(size, staticArrayAlign(declaration.type));
        registerModuleDeclaration(declaration).moduleStaticArray =
            ModuleStaticArrayVariable(offset, size);
        if (!hasDefaultInitializer)
            _program.moduleData[offset .. offset + size] = literalBytes[];
        return declarationRecordView(declaration).moduleStaticArrayOrNull;
    }

    // A module-level delegate variable (`int delegate() dg;`) reserves a
    // plain 16-byte native-order `{functionIndex, context}` slot in
    // `_program.moduleData`, the delegate counterpart of
    // `ModuleDynamicArrayVariable`/`ModuleScalarVariable` -- unlike a module
    // pointer or associative array (an 8-byte value routed through the module
    // scalar representation, since `scalarType` already maps both `Tpointer`
    // and `Taarray` to `ScalarType.ulong_`), a
    // delegate is a 16-byte pair with no `ScalarType` of its own, so it
    // needs this dedicated storage record instead. `allocateModuleBytes`
    // grows `_program.moduleData` with freshly zero-filled bytes, which is
    // already the correct all-zero `{functionIndex, context}` pair a
    // defaulted delegate holds (`compileDelegateDeclaration`'s own
    // all-zero fallback, `emitDelegateValue`'s layout) -- no initializer
    // bytes to write here, unlike a scalar module variable's
    // `moduleScalarInitializerBytes`. Only the implicit default (null)
    // initializer is handled; any other initializer declines registration,
    // falling through to the pre-existing "Unsupported variable in
    // bytecode core" error, matching every other module-variable-kind
    // decline elsewhere in this file. Read (`delegateOperandOffset`),
    // whole-value write (`compileAssignExpression`), and call-through
    // (`moduleDelegateOffsetOf`) each materialise the current 16-byte value
    // into a fresh frame slot via `Op.loadModule`/write it back via
    // `Op.storeModule`, the same pattern already used for a module
    // pointer/AA/struct/static-array variable.
    private ModuleDelegateVariable* allocateModuleDelegateVariable(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        if (auto existing = declarationRecordView(declaration).moduleDelegateOrNull)
            return existing;

        if (!moduleVariableHasDefaultInitializer(declaration))
            return null;

        const offset =
            allocateModuleBytes(delegateValueSize, size_t.sizeof);
        registerModuleDeclaration(declaration).moduleDelegate =
            ModuleDelegateVariable(offset);
        return declarationRecordView(declaration).moduleDelegateOrNull;
    }

    // A module-level `cdouble` variable (`__gshared cdouble c;`) reserves a
    // plain 16-byte native-order `{re, im}` slot in `_program.moduleData`,
    // the complex counterpart of `ModuleDelegateVariable` above. Unlike a
    // module pointer/associative array (an 8-byte value routed through the
    // module scalar representation, since `scalarType` already maps
    // `Tpointer`/`Taarray` to `ScalarType.ulong_`), a `cdouble`
    // is a 16-byte pair with no `ScalarType` of its own. A `cdouble` local uses
    // the same dedicated declaration representation rather than going through
    // the generic scalar machinery, so the module value gets its own storage
    // record too.
    // Unlike a defaulted pointer/AA/delegate (all-zero is the correct
    // default), `cdouble.init` is `double.nan + double.nan * 1i` -- D gives
    // every floating-point-derived type a NaN default, not zero -- confirmed
    // against the `SystemLinker`/`LLVMJit` real-compile oracles, which
    // failed an initial all-zero-default version of this test with `nan !=
    // 0`. So `allocateModuleBytes`'s zero-filled growth is explicitly
    // overwritten with both lanes' NaN bytes here, rather than reused as-is
    // the way every other module-variable kind's default does. Only the
    // implicit default (NaN) initializer is handled; any other initializer
    // declines registration, falling through to the pre-existing
    // "Unsupported variable in bytecode core" error, matching every other
    // module-variable-kind decline elsewhere in this file. The shared module
    // place materialises the current 16-byte value via `Op.loadModule` and
    // writes it back via `Op.storeModule`, the same primitives used for every
    // other module value.
    private ModuleComplexVariable* allocateModuleComplexVariable(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        if (auto existing = declarationRecordView(declaration).moduleComplexOrNull)
            return existing;

        if (!moduleVariableHasDefaultInitializer(declaration))
            return null;

        import std.bitmanip: nativeToLittleEndian;

        const offset =
            allocateModuleBytes(complexDoubleSize, cast(uint) double.sizeof);
        const nanBytes = nativeToLittleEndian(double.nan);
        _program.moduleData[offset .. offset + double.sizeof] = nanBytes[];
        _program.moduleData[
            offset + double.sizeof .. offset + complexDoubleSize
        ] = nanBytes[];
        registerModuleDeclaration(declaration).moduleComplex =
            ModuleComplexVariable(offset);
        return declarationRecordView(declaration).moduleComplexOrNull;
    }

    // Compile-time bytes for a module-level static array's non-null,
    // non-default initializer (`int[3] arr = [1, 2, 3];`), when it is an
    // array literal whose every element is a constant scalar expression --
    // the static-array counterpart of `writeStructLiteralFieldBytes`'s
    // per-field layout, laid out at each element's own `index * elementSize`
    // offset instead of a field's DMD-computed offset. Returns `null`
    // (declining registration, same as the default-initializer path) when
    // the element count does not exactly fill the array, an element is
    // missing, or any element is not a constant scalar expression.
    private ubyte[] moduleStaticArrayLiteralInitializerBytes(
        ArrayLiteralExp literal,
        Type elementType,
        in ushort totalSize,
    ) {
        import std.bitmanip: nativeToLittleEndian;

        if (literal is null || literal.elements is null)
            return null;

        const elementSize = typeFacts(elementType).byteWidth;
        if (elementSize == 0 ||
            literal.elements.length * elementSize != totalSize)
        {
            return null;
        }

        const elementScalarType = scalarType(elementType);

        ubyte[] bytes;
        bytes.length = totalSize;
        foreach (index, element; *literal.elements) {
            if (element is null)
                return null;

            const elementOffset = index * elementSize;
            if (auto integer = element.isIntegerExp) {
                const raw = nativeToLittleEndian(cast(ulong) integer.toInteger);
                bytes[elementOffset .. elementOffset + elementSize] =
                    raw[0 .. elementSize];
                continue;
            }
            if (auto real_ = element.isRealExp) {
                if (elementScalarType == ScalarType.real_) {
                    bytes[elementOffset .. elementOffset + elementSize] =
                        realBytes(real_)[];
                } else {
                    const raw =
                        nativeToLittleEndian(floatBits(real_, elementScalarType));
                    bytes[elementOffset .. elementOffset + elementSize] =
                        raw[0 .. elementSize];
                }
                continue;
            }

            return null;
        }
        return bytes;
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

    // Compile-time bytes for a module-level struct's non-null, non-default
    // initializer (`Point p = Point(1, 2);`), when it is a struct literal
    // with every field given as a constant scalar expression: DMD's
    // `initializerSemantic` already rewrites a `StructInitializer`
    // (`Point p = {1, 2};`) into an `ExpInitializer` wrapping a
    // `StructLiteralExp`, so `moduleVariableHasDefaultInitializer` (which
    // only recognises `ExpInitializer`) already classifies both spellings
    // correctly and needs no `Initializer`-subclass normalisation the way
    // the module-array case did. Returns `null` (declining registration,
    // same as the default-initializer path) when a field is omitted from
    // the literal (defaulting to its own init value), is itself a
    // struct/static-array/dynamic-array/delegate, or is not a constant
    // scalar expression.
    private ubyte[] moduleStructLiteralInitializerBytes(
        VarDeclaration declaration,
        in ushort structSize,
    ) {
        resolveNonRootInitializer(declaration);
        auto initializer = declaration._init is null
            ? null
            : declaration._init.isExpInitializer;
        if (initializer is null)
            return null;

        auto literal =
            initializerExpression(initializer.exp).isStructLiteralExp;

        ubyte[] bytes;
        bytes.length = structSize;
        if (!writeStructLiteralFieldBytes(literal, bytes))
            return null;
        return bytes;
    }

    // Write `literal`'s own field values into `bytes` (already sized to
    // the struct's own byte width) at each field's own DMD-computed
    // offset, when every field is present and a constant scalar
    // expression. Shared by `moduleStructLiteralInitializerBytes` (a whole
    // module-level struct variable's literal default, `bytes` spanning its
    // own `_program.moduleData` slot) and
    // `moduleDynamicArrayStructLiteralInitializerBytes` (one struct-typed
    // element of a module-level dynamic array literal, `bytes` spanning
    // just that one element's slot within the array's `literalBlocks`
    // entry) -- the per-field layout logic is identical either way, only
    // the destination slice differs. Returns `false` (declining; the
    // caller discards whatever was written to `bytes` so far) when a field
    // is omitted from the literal, is itself a
    // struct/static-array/dynamic-array/delegate, or is not a constant
    // scalar expression.
    private bool writeStructLiteralFieldBytes(
        StructLiteralExp literal,
        ubyte[] bytes,
    ) {
        import std.bitmanip: nativeToLittleEndian;
        import dmd.astenums: TY;

        if (literal is null || literal.elements is null ||
            literal.elements.length != literal.sd.fields.length)
        {
            return false;
        }

        foreach (fieldIndex, field; literal.sd.fields) {
            auto element = (*literal.elements)[fieldIndex];
            if (element is null)
                return false;

            switch (field.type.toBasetype.ty) with (TY) {
                case Tstruct, Tsarray, Tarray, Tdelegate:
                    return false;
                default:
                    break;
            }

            const fieldType = scalarType(field.type);
            const fieldSize = size(fieldType);
            const fieldOffset = cast(size_t) field.offset;

            if (auto integer = element.isIntegerExp) {
                const raw = nativeToLittleEndian(cast(ulong) integer.toInteger);
                bytes[fieldOffset .. fieldOffset + fieldSize] =
                    raw[0 .. fieldSize];
                continue;
            }
            if (auto real_ = element.isRealExp) {
                if (fieldType == ScalarType.real_) {
                    bytes[fieldOffset .. fieldOffset + fieldSize] =
                        realBytes(real_)[];
                } else {
                    const raw = nativeToLittleEndian(floatBits(real_, fieldType));
                    bytes[fieldOffset .. fieldOffset + fieldSize] =
                        raw[0 .. fieldSize];
                }
                continue;
            }

            return false;
        }
        return true;
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
        if (isNullLiteral(expression))
            return new ubyte[size(type)];

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

    private Operand compileArrayLengthAssign(
        ArrayLengthExp length,
        Expression newLength,
    ) {
        import dmd.astenums: TY;
        import dmd.typesem: defaultInitLiteral;

        auto destination = dynamicArrayMutationPlace(length.e1);
        const lengthValue = compileExpression(newLength);
        const descriptor = loadDynamicArrayPlace(*destination, length.e1.type);
        const lengthSlot = allocate(ScalarType.ulong_);
        _code ~= Instruction(
            Op.copy,
            lengthSlot,
            lengthValue.offset,
            cast(ushort) size(lengthValue.type),
        );
        auto element = length.e1.type.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tstruct) {
            const elementSize = typeFacts(element).byteWidth;
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
            storeDynamicArrayPlace(*destination, descriptor);
            return Operand(lengthSlot, ScalarType.ulong_);
        }

        _code ~= Instruction(
            Op.setArrayLength,
            descriptor.offset,
            packedFill(
                descriptor.elementType,
                dynamicArrayElementSize(length.e1.type),
            ),
            lengthSlot,
        );
        storeDynamicArrayPlace(*destination, descriptor);
        return Operand(lengthSlot, ScalarType.ulong_);
    }

    private Operand compileAppendElement(CatElemAssignExp append) {
        auto destination = dynamicArrayMutationPlace(append.e1);

        // `outer ~= row` where `outer`'s element is itself an array
        // (`int[][]`/`int[N][]`): the appended row needs its own heap-backed
        // sub-array and 16-byte descriptor, the same shape an array-of-arrays
        // literal builds for each of its elements (`compileDynamicArrayInto`'s
        // `elementIsArray` branch), not the flat scalar/struct byte layout --
        // `outer[i]` always reads a stored element as a descriptor to
        // dereference.
        if (arrayElementIsArray(append.e1.type)) {
            const inner = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            const elementType = dynamicArrayElementType(append.e1.type);
            compileDynamicArrayInto(inner, elementType, append.e2);
            const descriptor = loadDynamicArrayPlace(
                *destination, append.e1.type,
            );
            emitAppendElement(descriptor.offset, inner, sliceDescriptorSize);
            storeDynamicArrayPlace(*destination, descriptor);
            return Operand(descriptor.offset, descriptor.elementType);
        }

        const value = compileExpression(append.e2);
        const descriptor = loadDynamicArrayPlace(*destination, append.e1.type);
        const elementSize = dynamicArrayElementSize(append.e1.type);
        emitAppendElement(descriptor.offset, value.offset, elementSize);
        storeDynamicArrayPlace(*destination, descriptor);
        return Operand(descriptor.offset, descriptor.elementType);
    }

    // `arr ~= other`: concatenate both array descriptors into fresh backing
    // memory, then overwrite the resolved destination's descriptor.
    private Operand compileConcatenationAssign(CatAssignExp concatenate) {
        auto destination = dynamicArrayMutationPlace(concatenate.e1);
        const elementType = dynamicArrayElementType(concatenate.e1.type);
        const elementIsArray = arrayElementIsArray(concatenate.e1.type);
        const right = dynamicArrayDescriptor(concatenate.e2).offset;
        const descriptor = loadDynamicArrayPlace(
            *destination, concatenate.e1.type,
        );
        const elementSize = dynamicArrayElementSize(
            concatenate.e1.type, elementIsArray,
        );
        emitConcatArrays(
            descriptor.offset, descriptor.offset, right, elementSize,
        );
        storeDynamicArrayPlace(*destination, descriptor);
        return Operand(descriptor.offset, descriptor.elementType);
    }

    private Place* dynamicArrayMutationPlace(Expression expression) {
        import std.conv: text;

        auto place = placeOrNull(expression);
        if (place is null)
            throw new Exception(text(
                "Unsupported dynamic array mutation in bytecode core: ",
                expressionChars(expression),
            ));
        return place;
    }

    private DynamicArrayLocal loadDynamicArrayPlace(
        Place place,
        Type type,
    ) {
        const descriptor = loadPlace(place);
        return DynamicArrayLocal(
            descriptor.offset,
            dynamicArrayElementType(type),
            arrayElementIsArray(type),
        );
    }

    private void storeDynamicArrayPlace(
        Place place,
        in DynamicArrayLocal descriptor,
    ) {
        storePlace(place, Operand(descriptor.offset, ScalarType.void_));
    }

    // A real-address slice descriptor over a static-array sub-slice
    // (`arr[lo .. hi]`), sharing `arr`'s own frame or field storage instead of
    // the heap copy a materialised dynamic-array value would build. Needed as
    // both a slice-assignment destination (so the write reaches `arr`'s real
    // storage) and source (so `sliceCopyOp`'s pointer-range overlap check sees
    // genuine aliasing instead of a copy that cannot overlap). Bounds-checks
    // `[lo .. hi]` against the array's own known
    // length the same way a dynamic-array sub-slice does (`Op.subSlice*`'s
    // `validateSubSlice`, matching compiled D's `RangeError` wording byte for
    // byte). Null if `slice.e1` is not a static-array location.
    private ushort* tryStaticArraySliceDescriptor(SliceExp slice) {
        import dmd.astenums: TY;

        if (slice.e1.type is null ||
            slice.e1.type.toBasetype.ty != TY.Tsarray)
            return null;

        auto base = placeOrNull(slice.e1);
        if (base is null)
            return null;
        const address = addressOfPlace(*base);

        const elementType = dynamicArrayElementType(slice.e1.type);
        // `dynamicArrayElementSize` derives the real byte width for a
        // struct/static-array element instead of the `ScalarType.void_`-
        // implied 0 that the raw `size(elementType)` gives it.
        const elementSize = typeFacts(
            slice.e1.type.toBasetype.nextOf,
        ).byteWidth;

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

        // Build a throwaway {pointer, length} descriptor over `base` and go
        // through `subSliceOp` instead of the unchecked `pointerSliceOp`, so
        // an out-of-range bound throws instead of silently reading or
        // writing past the array's frame storage.
        const sourceDescriptor =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, sourceDescriptor, address.offset,
            cast(ushort) size_t.sizeof,
        );
        _code ~= Instruction(
            Op.copy,
            cast(ushort) sliceDescriptorLengthOffset(sourceDescriptor),
            compileSizeConstant(length),
            cast(ushort) size_t.sizeof,
        );

        const destination = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        emitSubSlice(destination, sourceDescriptor, bounds, elementSize);

        auto result = new ushort;
        *result = destination;
        return result;
    }

    private Operand storeStaticSlice(
        Place place,
        Expression rhs,
    ) {
        auto elementType = place.sliceBaseType.toBasetype.nextOf;
        if (elementType !is null && rhs.type !is null &&
            sameType(rhs.type, elementType) &&
            typeFacts(elementType).isAggregate) {
            const value = aggregateValueOffset(elementType, rhs, false);
            emitSliceFill(place.offset, value, place.sliceElementSize);
            return Operand.init;
        }

        if (isBroadcastFillSource(rhs)) {
            const value = compileExpression(rhs);
            emitSliceFill(
                place.offset, value.offset, place.sliceElementSize,
            );
            return Operand.init;
        }

        const source = compileSourceSlice(place.sliceElementType, rhs);
        emitSliceCopy(place.offset, source, place.sliceElementSize);
        return Operand.init;
    }

    // True when `rhs` is a single value broadcast into every element of a
    // slice-assignment range (`arr[0 .. 2] = value;`), as opposed to an
    // array-shaped source `compileSourceSlice` copies element-by-element (a
    // sub-slice, an array literal, a string literal, or another dynamic
    // array). Does not by itself account for a destination element that is
    // its own heap-allocated row descriptor (`elementIsArray` at the call
    // site) -- callers guard that shape separately.
    private bool isBroadcastFillSource(Expression rhs) {
        import dmd.astenums: TY;

        if (rhs.type is null)
            return false;
        if (rhs.isSliceExp !is null)
            return false;
        if (rhs.isArrayLiteralExp !is null)
            return false;
        if (stringLiteralOf(rhs) !is null)
            return false;
        return rhs.type.toBasetype.ty != TY.Tarray;
    }

    private Operand storeDynamicSlice(
        Place place,
        Expression rhs,
    ) {
        auto descriptor = &place.sliceDescriptor;
        const elementType = place.sliceElementType;
        const elementIsArray = place.sliceElementIsArray;
        const destination = place.offset;
        const elementSize = place.sliceElementSize;

        // `elementIsArray` means each destination element is its own
        // separately heap-allocated row descriptor (the `T[N][]`
        // representation), not `elementSize` (=`sliceDescriptorSize`) raw
        // bytes shared by every row. A `T[N]` row's already-allocated block
        // (from the array's construction) is written through its own
        // pointer, one row at a time (`emitRowBroadcastFill`), the same
        // addressing the single-index aggregate place's
        // `innerArrayRowPointer` writeback uses -- only when the rhs is
        // itself shaped like one row (`sameType` against the row's own
        // `Type`, not the whole sliced range).
        //
        // `descriptor.isStaticArrayView` (a genuine multidimensional static
        // array, e.g. `int[3][3]`, viewed through a throwaway heap copy)
        // shares `elementIsArray` with the true `T[N][]` shape but its rows
        // are contiguous inline bytes, not separate heap blocks -- excluded
        // here, or `emitRowBroadcastFill` would dereference row bytes as if
        // they were a row pointer.
        import dmd.astenums: TY;

        if (elementIsArray && descriptor !is null &&
            !descriptor.isStaticArrayView) {
            auto rowType = place.sliceBaseType.toBasetype.nextOf;
            if (rowType.toBasetype.ty == TY.Tsarray) {
                const rowByteSize = typeFacts(rowType).byteWidth;

                if (rhs.type !is null && sameType(rhs.type, rowType)) {
                    const value = compileExpression(rhs);
                    emitRowBroadcastFill(
                        destination, value.offset, rowByteSize,
                    );

                    return Operand.init;
                }

                // A rhs shaped like a matching range of rows (a sub-slice,
                // another `T[N][]`), not a single broadcast row: write
                // through each destination row's own block instead of
                // `sliceCopy16`'s flat by-value descriptor copy below,
                // which would alias every destination row to the source's
                // block (see `Op.rowRangeCopy`'s doc comment).
                //
                // A rhs range sourced from a static-array view (`s[0 .. 2]`
                // where `s` is itself a multidimensional static array, e.g.
                // `int[3][3]`) is contiguous inline row bytes rather than row
                // descriptors. Lower it to the typed row-copy loop below.
                if (auto rhsSlice = rhs.isSliceExp)
                    if (rhsSlice.e1.type.toBasetype.ty == TY.Tsarray) {
                            const rangeSource = compileSourceSlice(
                                elementType, rhs,
                            );
                            emitInlineRowRangeCopy(
                                destination, rangeSource, rowByteSize,
                            );

                            return Operand.init;
                    }

                const rangeSource = compileSourceSlice(elementType, rhs);
                emitRowRangeCopy(destination, rangeSource, rowByteSize);

                return Operand.init;
            }

            // `T[][]` (`Tarray`-row): unlike a `T[N]` row, a `T[]` row is
            // itself just a 16-byte `{ptr, length}` descriptor, the same
            // reference-semantics value every other broadcast-fill element
            // is. There is no separately heap-allocated row block to write
            // through -- broadcasting the rhs row means writing its own
            // descriptor bytes into every destination slot, aliasing every
            // destination row to the rhs row's backing storage, matching
            // `SystemLinker`. `emitSliceFill` (the same helper the
            // non-array-element branch below uses) does exactly that; a
            // row-range rhs (another `T[][]` sub-slice) is not handled here
            // and falls through to the flat `sliceCopy16` below, which
            // already copies each element's 16-byte descriptor by value --
            // correct for reference-typed rows, unlike the `T[N][]` case
            // above.
            if (rowType.toBasetype.ty == TY.Tarray &&
                rhs.type !is null && sameType(rhs.type, rowType)) {
                const value = compileExpression(rhs);
                emitSliceFill(destination, value.offset, elementSize);

                return Operand.init;
            }
        } else if (!elementIsArray && isBroadcastFillSource(rhs)) {
            const value = compileExpression(rhs);
            emitSliceFill(destination, value.offset, elementSize);

            return Operand.init;
        }

        const source = compileSourceSlice(elementType, rhs);
        emitSliceCopy(destination, source, elementSize);

        return Operand.init;
    }

    // Materialise the right-hand side of a dynamic-array slice assignment into a
    // slice descriptor slot. A `SliceExp` shares the source's backing memory; an
    // array or string literal heap-allocates a fresh block holding its elements.
    private ushort compileSourceSlice(
        in ScalarType elementType,
        Expression rhs,
    ) {
        import std.conv: text;
        import dmd.astenums: TY;

        // A static-array-backed rhs sub-slice (`buff[0 .. 3]`) shares
        // `buff`'s real frame storage instead of the throwaway heap copy
        // `compileSliceInto` would otherwise resolve it to
        // (the static-array view produced by `dynamicArrayDescriptor`), so the
        // destination write's own overlap check in `sliceCopyOp` can see a
        // genuine self-aliasing rhs such as `buff[1 .. 4] = buff[0 .. 3]`.
        if (auto slice = rhs.isSliceExp)
            if (auto staticDescriptor = tryStaticArraySliceDescriptor(slice))
                return *staticDescriptor;

        if (auto slice = rhs.isSliceExp) {
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileSliceInto(offset, elementType, slice);
            return offset;
        }

        if (auto string_ = stringLiteralOf(rhs)) {
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileStringElementSlice(offset, elementType, string_);
            return offset;
        }

        if (rhs.isArrayLiteralExp !is null) {
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            compileDynamicArrayInto(offset, elementType, rhs);
            return offset;
        }

        // Any other dynamic-array-typed expression (a plain variable, a call
        // result, ...) is an ordinary frame slot already holding its own
        // full slice descriptor; reuse it directly rather than materialising
        // a redundant copy.
        if (rhs.type !is null && rhs.type.toBasetype.ty == TY.Tarray)
            return dynamicArrayDescriptor(rhs).offset;

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
            emitIndexStore(value, offset, index, elementSize);
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
            const elementSize = typeFacts(elementType).byteWidth;
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
            const elementSize = typeFacts(elementType).byteWidth;
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
            const elementSize = typeFacts(elementType).byteWidth;
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
        const elementSize = typeFacts(elementType).byteWidth;

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

    private Operand compileEqualExpression(Expression expression) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;

        auto equal = cast(BinExp) expression; // DMD AST fields are mutable refs.
        assert(equal !is null);

        // `m1 == m2` / `m1 != m2` for associative arrays: compare entry sets via
        // the VM-owned maps. DMD keeps the EqualExp (with an unused lowering to
        // `_d_aaEqual`), so match the operand type here.
        if (equal.e1.type.toBasetype.ty == TY.Taarray) {
            const width = assocArrayValueWidth(equal.e1.type.toBasetype);
            const keyMeta = assocArrayKeyMeta(equal.e1.type.toBasetype);
            const left = resolveAssocArrayOperand(equal.e1).handle.offset;
            const right = resolveAssocArrayOperand(equal.e2).handle.offset;
            const offset = allocate(ScalarType.bool_);
            _code ~= Instruction(
                Op.aaEqual, offset, left, right, cast(ushort) width, keyMeta,
            );
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

        // `dg1 == dg2` / `dg1 != dg2`, including a `null` operand: a delegate
        // is a builtin type with no `opEquals` to lower through, so DMD keeps
        // this as a plain `EqualExp` over the 16-byte `{functionIndex,
        // context}` pair. `compileExpression` below has no generic VarExp
        // case for a delegate-typed local (the declaration record resolves it
        // through `delegateOperandOffset` instead), so this needs its own
        // branch the same way the aggregate
        // cases above do.
        if (equal.e1.type.toBasetype.ty == TY.Tdelegate)
            return compileDelegateEquality(
                delegateOperandOffset(equal.e1),
                delegateOperandOffset(equal.e2),
                equal.op == EXP.notEqual,
            );

        const bothDynamicArrays = equal.e1.type.toBasetype.ty == TY.Tarray &&
            equal.e2.type.toBasetype.ty == TY.Tarray &&
            dynamicArrayElementType(equal.e1.type) ==
                dynamicArrayElementType(equal.e2.type);
        if (bothDynamicArrays) {
            const elementType = dynamicArrayElementType(equal.e1.type);
            // `int[][] == int[][]` (any nesting depth, `int[][][]` and
            // deeper included): each element is itself a heap-allocated
            // row descriptor, so a flat `sliceEqualOp` below would compare
            // the rows' `.ptr` values instead of their content -- two
            // separately-constructed but content-equal rows would compare
            // unequal. Structural comparison needs the dedicated nested
            // opcode instead.
            const nested = arrayElementIsArray(equal.e1.type) &&
                arrayElementIsArray(equal.e2.type);
            const left = dynamicArrayDescriptor(equal.e1).offset;
            const right = dynamicArrayDescriptor(equal.e2).offset;
            const offset = nested
                ? emitNestedArrayEqual(left, right, equal.e1.type)
                : allocate(ScalarType.bool_);
            if (!nested)
                emitSliceEqual(
                    offset, left, right,
                    dynamicArrayElementSize(equal.e1.type),
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

    // `dg1 == dg2` / `dg1 is dg2` (and the negated forms): compare the two
    // 8-byte halves of the 16-byte `{functionIndex, context}` pair -- there
    // is no 16-byte equality opcode -- and combine them with the same
    // short-circuiting `&&` shape `compileStructIdentity` above uses for a
    // multi-field struct, specialised to exactly two fixed-offset fields.
    private Operand compileDelegateEquality(
        in ushort left,
        in ushort right,
        in bool invert,
    ) {
        const result = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.loadConstant, result, constantIndex(1), 1);

        const functionEqual = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.equal8, functionEqual, left, right);
        const functionFalseJump =
            emitJumpIfFalse(Operand(functionEqual, ScalarType.bool_));

        const contextEqual = allocate(ScalarType.bool_);
        _code ~= Instruction(
            Op.equal8,
            contextEqual,
            cast(ushort) (left + size_t.sizeof),
            cast(ushort) (right + size_t.sizeof),
        );
        const contextFalseJump =
            emitJumpIfFalse(Operand(contextEqual, ScalarType.bool_));

        const endJump = emitJump;
        patchJump(functionFalseJump);
        patchJump(contextFalseJump);
        _code ~= Instruction(Op.loadConstant, result, constantIndex(0), 1);
        patchJump(endJump);

        if (invert)
            _code ~= Instruction(Op.notBool, result, result);
        return Operand(result, ScalarType.bool_);
    }

    private Operand compileIdentityExpression(IdentityExp identity) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;

        // `dg1 is dg2` / `dg1 !is dg2`: a delegate has no `opEquals`, so `is`
        // is the same bitwise comparison `==` already needs
        // (`compileEqualExpression`'s `Tdelegate` branch above); route
        // through the same two-halves helper instead of the generic
        // `compileExpression`, which has no delegate-typed `VarExp` case.
        if (identity.e1.type.toBasetype.ty == TY.Tdelegate)
            return compileDelegateEquality(
                delegateOperandOffset(identity.e1),
                delegateOperandOffset(identity.e2),
                identity.op == EXP.notIdentity,
            );

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
        Operand* resolvedThisOperand = null,
    ) {
        import dmd.astenums: TY;
        import std.conv: text;

        auto function_ = callFunction(call);

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

        // `dg()` through a module-level (`__gshared`/`static`) delegate
        // variable: the same run-time-typed dispatch as a delegate-typed
        // parameter, with the variable's own materialised dataseg value as
        // the descriptor instead of a parameter slot.
        if (function_ is null)
            if (auto offset = moduleDelegateOffsetOf(call))
                return compileDynamicDelegateCall(*offset, call);

        // `s.f()` through a delegate-typed struct FIELD: the same run-time-
        // typed dispatch as a delegate-typed parameter, with the field's own
        // frame offset as the descriptor instead of a parameter slot.
        if (function_ is null)
            if (auto offset = structFieldDelegateOffsetOf(call))
                return compileDynamicDelegateCall(*offset, call);

        // `d()` through a delegate local declared in an enclosing function and
        // read here as a captured variable (ordinary declaration views only
        // expose the function currently being compiled): load its
        // `{functionIndex, context}` pair out of the captured environment into
        // a fresh slot in
        // the current frame, then dispatch it exactly like a delegate-typed
        // parameter. Tried only after every current-function-owned delegate
        // shape above has declined, since a plain parameter also carries a
        // `_capturedOffsets` entry (any local may later be captured by a
        // nested function) that this check would otherwise misread as a
        // capture of its own.
        if (function_ is null)
            if (auto offset = capturedDelegateOffsetOf(call))
                return compileDynamicDelegateCall(*offset, call);

        // `dgs[0]()` through an INDEX into a delegate-typed array, no
        // intermediate delegate-typed local: the same run-time-typed
        // dispatch as a delegate-typed parameter/field, with the indexed
        // element's own descriptor offset (`delegateOperandOffset` already
        // materialises it, in place for a static array element or a fresh
        // copy for a dynamic array element).
        if (function_ is null)
            if (auto offset = indexedDelegateOffsetOf(call))
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
        const isNativeLeaf = function_.fbody is null;
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
        Operand structReceiver;
        // `super.f(...)` binds statically to the base class's own
        // implementation (`function_`/`index` already resolved to it via
        // DMD's `call.f`); dispatching it through the runtime receiver's
        // vtable instead would look the override back up and, for an
        // override whose body itself calls `super.f()`, recurse forever.
        auto superDot = call.e1.isDotVarExp;
        const isSuperCall = superDot !is null && superDot.e1.isSuperExp !is null;

        // A struct method call `receiver.method(args)` passes the receiver as
        // the hidden `this` block (by reference) at the start of the argument
        // area: store the receiver's address there, which the machine
        // dereferences on entry.
        if (layout.hasThis) {
            if (auto dot = call.e1.isDotVarExp)
                structReceiver = storageAddressOrValue(dot.e1);
            else if (_hasThis)
                structReceiver = Operand(
                    _thisLocal.offset, ScalarType.ulong_, true,
                    ScalarType.void_,
                );
            else
                throw new Exception(text(
                    "Missing hidden `this` argument in bytecode core: ",
                    expressionChars(call),
                ));
            if (resolvedThisOperand !is null)
                *resolvedThisOperand = structReceiver;
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (argumentArea + layout.thisOffset),
                structReceiver.offset,
                cast(ushort) size_t.sizeof,
            );
        }

        if (layout.hasClassThis) {
            classReceiver = compileClassReceiver(call);
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
                if (layout.isReference[nextArgumentIndex + argumentIndex]) {
                    emitReferenceArgument(
                        slot, (*call.arguments)[argumentIndex],
                    );
                    continue;
                }
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
                !returnType.isDelegate &&
                returnType.scalar == ScalarType.void_)
                ? cast(ushort) 0
                : allocateBytes(size(returnType), 8);
        if (hasClassReceiver && !isSuperCall) {
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
        if (isPointerType(call.type))
            return Operand(
                destination, ScalarType.ulong_, true,
                pointerElementScalar(call.type),
            );
        if (function_.type.isTypeFunction !is null &&
            function_.type.isTypeFunction.isRef)
            return Operand(
                destination, ScalarType.ulong_, true,
                typeFacts(call.type).isAggregate
                    ? ScalarType.void_
                    : scalarType(call.type),
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

    // A null return always falls through to the call site's unconditional
    // no-available-source throw, never a different path, so it is safe to
    // emit earlier arguments before a later one turns out unsupported.
    private Operand* tryCompileNativeCall(
        CallExp call,
        FuncDeclaration function_,
        in ParameterLayout layout,
        in ushort nativeStructReceiverOffset = noOutParameterOffset,
        imported!"dmd.mtype".TypeStruct nativeStructReceiverType = null,
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
                    (declarationRecordView(pointerDeclaration).pointerOrNull) !is null) {
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

            // `&local` out parameter: `SymOffExp` (as `symbolAddress`
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
            noOutParameterOffset, null, nativeStructReceiverOffset,
            nativeStructReceiverType,
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
            return declaration is null ? null : declarationRecordView(declaration).scalarOrNull;
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
        if (auto local = declarationRecordView(declaration).scalarOrNull)
            return local;
        if (auto struct_ = declarationRecordView(declaration).struct_OrNull)
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
        in ushort nativeStructReceiverOffset = noOutParameterOffset,
        imported!"dmd.mtype".TypeStruct nativeStructReceiverType = null,
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
        // shape every other struct-by-value result uses.
        const isStructReturn = returnType.toBasetype.ty == TY.Tstruct;
        const returnScalar = isArrayReturn || isStructReturn
            ? ScalarType.void_
            : scalarType(returnType.toBasetype);
        const destination = isStructReturn
            ? allocateBytes(
                typeFacts(returnType).byteWidth,
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
                nativeStructReceiverOffset,
                nativeStructReceiverType,
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
        const source =
            dynamicArrayDescriptor((*call.arguments)[0]).offset;
        const elements = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.transcodeUtf, elements, cast(ushort) mode, source,
        );

        // The loop variable is the delegate's single (`ref`) parameter; bind it
        // to a fresh frame slot the body reads through the ordinary local path.
        auto parameter = (*literal.fd.parameters)[0];
        const variableSlot = allocateBytes(elementSize, elementSize);
        registerFrameParameter(parameter, variableSlot);

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

        emitIndexLoad(variableSlot, elements, index, elementSize);

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
            cast(ushort) TypeFacts.fromOpcode(ScalarType.int_).byteWidth,
        );
        return Operand(result, ScalarType.int_);
    }

    // The delegate local invoked by `d()`, or null if `call` is not a call
    // through a delegate local. The callee is a `VarExp` whose declaration
    // record carries a statically known delegate target.
    private DelegateLocal* delegateLocalOf(CallExp call) {
        auto variable = call.e1 is null ? null : call.e1.isVarExp;
        if (variable is null)
            return null;
        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            return null;
        return declarationRecordView(declaration).delegate_OrNull;
    }

    // A call through a delegate-typed local declared in an enclosing
    // function and reached here only as a captured variable: materialise its
    // `{functionIndex, context}` pair out of the captured-locals environment
    // into a fresh slot in the CURRENT frame, returning that slot's offset.
    // `null` when `call` is not this shape.
    private ushort* capturedDelegateOffsetOf(CallExp call) {
        import dmd.astenums: TY;

        if (!_hasNestedContext)
            return null;

        auto variable = call.e1 is null ? null : call.e1.isVarExp;
        if (variable is null)
            return null;
        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null ||
            declaration.type.toBasetype.ty != TY.Tdelegate)
            return null;
        auto capturedOffset = declaration in _capturedOffsets;
        if (capturedOffset is null)
            return null;

        const offset = allocateBytes(delegateValueSize, size_t.sizeof);
        _code ~= Instruction(
            Op.frameLoad, offset,
            capturedFrameIndex(_capturedOwners[declaration], *capturedOffset),
            cast(ushort) delegateValueSize,
        );
        auto result = new ushort;
        *result = offset;
        return result;
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
        if (declaration.isParameter && declaration.isReference) {
            auto place = placeOrNull(call.e1);
            if (place is null)
                return null;
            auto result = new ushort;
            *result = loadPlace(*place).offset;
            return result;
        }
        return declarationRecordView(declaration).delegateParameterOrNull;
    }

    // The frame offset of a module-level (`__gshared`/`static`) delegate
    // variable invoked by `dg()`, or null if `call` is not a call through
    // one. There is no statically known `FuncDeclaration` behind this
    // slot, the same shape a delegate-typed parameter reaches; materialise
    // the variable's current `{functionIndex, context}` pair out of
    // `moduleData` into a fresh frame slot (`Op.loadModule`), the same way
    // `delegateOperandOffset` does for a plain read.
    private ushort* moduleDelegateOffsetOf(CallExp call) {
        auto variable = call.e1 is null ? null : call.e1.isVarExp;
        if (variable is null)
            return null;
        auto declaration = variable.var.isVarDeclaration;
        auto moduleVariable = moduleDeclarationRecord(declaration).moduleDelegateOrNull;
        if (moduleVariable is null)
            return null;

        const offset = allocateBytes(delegateValueSize, size_t.sizeof);
        _code ~= Instruction(
            Op.loadModule, offset, moduleVariable.offset,
            cast(ushort) delegateValueSize,
        );
        auto result = new ushort;
        *result = offset;
        return result;
    }

    // The frame offset of the delegate-typed struct/class/struct-pointer
    // FIELD invoked by `s.f(...)`/`c.f(...)`/`p.f(...)`, or null if `call`
    // is not a call through one. The callee's target is a run-time value
    // with no statically known `FuncDeclaration`, the same shape a
    // delegate-typed parameter reaches.
    private ushort* structFieldDelegateOffsetOf(CallExp call) {
        auto dot = call.e1 is null ? null : call.e1.isDotVarExp;
        if (dot is null || dot.var.isFuncDeclaration !is null)
            return null;

        return delegateFieldOffsetOf(dot);
    }

    // The frame offset of the delegate value read out of an INDEX into a
    // delegate-typed array (`dgs[0]()`), or null if `call` is not a call
    // through one. Unlike `delegateLocalOf`, there is no known
    // `FuncDeclaration` behind this slot; `delegateOperandOffset` already
    // knows how to materialise an indexed delegate element's own
    // `{functionIndex, context}` pair for the argument/initializer case, so
    // reuse it here.
    private ushort* indexedDelegateOffsetOf(CallExp call) {
        import dmd.astenums: TY;

        auto index = call.e1 is null ? null : call.e1.isIndexExp;
        if (index is null || index.type.toBasetype.ty != TY.Tdelegate)
            return null;

        auto offset = new ushort;
        *offset = delegateOperandOffset(index);
        return offset;
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
        if (auto existing = declarationRecordView(declaration).lazyDelegateOrNull)
            return new LazyDelegateSource(*existing);
        if (declarationClassification(declaration).lazyDeclarationOrNull
                is null)
            return null;
        if (auto captured = declaration in _capturedOffsets)
            return new LazyDelegateSource(
                *captured, true, _capturedOwners[declaration],
            );
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
                capturedFrameIndex(source.owner, source.offset),
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

        const functionType = callTypeFunction(call);
        const returnsRef = functionType !is null && functionType.isRef;
        const returnType = returnsRef
            ? ResultType.scalarResult(ScalarType.ulong_)
            : resultType(call.type);
        const destination = allocateIndirectCallResult(
            returnType, returnsRef,
        );
        _code ~= Instruction(
            Op.callIndirect, delegateOffset, argumentArea, destination,
        );
        return returnsRef
            ? refReturnOperand(destination, call.type)
            : Operand(destination, returnType.scalar);
    }

    private void emitLazyCallArgument(
        in ushort destination,
        Expression argument,
    ) {
        import std.conv: text;

        if (auto variable = argument.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto source = declarationRecordView(declaration).lazyDelegateOrNull) {
                    _code ~= Instruction(
                        Op.copy, destination, *source,
                        cast(ushort) delegateValueSize,
                    );
                    return;
                }
                if (declarationClassification(declaration).lazyDeclarationOrNull) {
                    if (auto source = declaration in _capturedOffsets) {
                        _code ~= Instruction(
                            Op.frameLoad, destination,
                            capturedFrameIndex(
                                _capturedOwners[declaration], *source,
                            ),
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
    // receiver address) in the second. Pass the context as the lambda's hidden
    // `this` block, then dispatch through `callIndirect` on the index word.
    private Operand compileDelegateCall(
        DelegateLocal delegateLocal,
        CallExp call,
    ) {
        import std.conv: text;

        // This call reaches `delegateLocal.function_`'s body through its
        // OWN local's already-materialised context, whatever kind that is
        // (see `_frameContextDelegates`'s own comment for why a nested
        // function/lambda's frame-relative context specifically matters to
        // `heapClosureContextOrNull`, and why marking unconditionally here
        // is still safe for every other context kind: `heapClosureContextOrNull`
        // never consults this set for a callee its own earlier guards --
        // `thisStructDeclaration`, `outerVars.length == 0` -- already
        // exclude).
        _frameContextDelegates[delegateLocal.function_] = true;

        const layout = parameterLayout(delegateLocal.function_);
        const argumentArea = allocateBytes(layout.blockSize, 8);

        // Struct-member delegates store the receiver address in the pair's
        // context word; the machine dereferences it as the hidden `this` block.
        if (layout.hasThis)
            _code ~= Instruction(
                Op.copy,
                cast(ushort) (argumentArea + layout.thisOffset),
                cast(ushort) (delegateLocal.offset + size_t.sizeof),
                cast(ushort) size_t.sizeof,
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
        const returnsRef = delegateLocal.function_.type.isTypeFunction.isRef;
        const destination = allocateIndirectCallResult(
            returnType, returnsRef,
        );
        _code ~= Instruction(
            Op.callIndirect, delegateLocal.offset, argumentArea, destination,
        );
        return returnsRef
            ? refReturnOperand(destination, call.type)
            : Operand(destination, returnType.scalar);
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

        const returnType = functionType.isRef
            ? ResultType.scalarResult(ScalarType.ulong_)
            : resultType(call.type);
        const destination = allocateIndirectCallResult(
            returnType, functionType.isRef,
        );
        _code ~= Instruction(
            Op.callIndirectDynamic, descriptorOffset, argumentArea, destination,
        );
        return functionType.isRef
            ? refReturnOperand(destination, call.type)
            : Operand(destination, returnType.scalar);
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

    // `fp(args...)` through a function-pointer value: load the callee's
    // run-time function index from the pointer slot and dispatch through
    // `callIndirect`. There is no statically known `FuncDeclaration` behind
    // the pointer, so the argument area is built from the function-pointer
    // type's own declared parameters -- the same approach
    // `compileDynamicDelegateCall` uses for a delegate-typed parameter, minus
    // the leading context word a plain function pointer has no room for.
    private Operand compileIndirectCall(CallExp call) {
        import dmd.astenums: STC;

        // DMD lowers `fp()` as `(*fp)()`: the callee operand is a `PtrExp` whose
        // dereferenced type is the function type `R function(Args...)`. The
        // pointer slot holding the run-time index is the `PtrExp`'s
        // sub-expression.
        auto deref = call.e1.isPtrExp;
        auto functionType = deref.type.toBasetype.isTypeFunction;
        const returnType = functionType.isRef
            ? ResultType.scalarResult(ScalarType.ulong_)
            : resultType(functionType.next);

        const pointer = compileExpression(deref.e1);

        ParameterLayout layout;
        if (functionType.parameterList.parameters !is null)
            foreach (parameter; *functionType.parameterList.parameters) {
                const isReference = (parameter.storageClass &
                    (STC.ref_ | STC.out_ | STC.auto_)) != STC.none;
                appendParameterLayoutEntry(
                    layout, parameter.type, isReference,
                );
            }

        const argumentArea = allocateBytes(layout.blockSize, size_t.sizeof);
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

        const destination = allocateIndirectCallResult(
            returnType, functionType.isRef,
        );
        _code ~= Instruction(
            Op.callIndirect, pointer.offset, argumentArea, destination,
        );
        // A pointer-returning callee (raw `T*` or another function pointer,
        // e.g. `auto make = () => () => 42;`'s `make()` call, whose result
        // is itself a function pointer another declaration assigns from)
        // needs the same `isPointer` tagging `compileCall`'s named-function
        // path already gives a direct call's pointer result -- a plain
        // scalar-typed operand is not accepted by a pointer-typed local's
        // declaration.
        if (functionType.isRef)
            return refReturnOperand(destination, functionType.next);
        if (isPointerType(functionType.next))
            return Operand(
                destination, ScalarType.ulong_, true,
                pointerElementScalar(functionType.next),
            );
        return Operand(destination, returnType.scalar);
    }

    private Operand refReturnOperand(in ushort offset, Type pointeeType) {
        const facts = typeFacts(pointeeType);
        return Operand(
            offset,
            ScalarType.ulong_,
            true,
            facts.isAggregate ? ScalarType.void_ : facts.opcodeType,
        );
    }

    private ushort allocateIndirectCallResult(
        in ResultType returnType,
        in bool returnsRef,
    ) {
        if (returnsRef)
            return allocateBytes(
                cast(uint) size_t.sizeof, size_t.sizeof,
            );
        if (!returnType.isArray &&
            !returnType.isStruct &&
            !returnType.isDelegate &&
            returnType.scalar == ScalarType.void_)
            return 0;
        return allocateBytes(size(returnType), 8);
    }

    private Operand* compileEmplace(CallExp call) {
        if (call.arguments is null || call.arguments.length < 2)
            return null;

        const destination = compileExpression((*call.arguments)[0]);
        if (!destination.isPointer)
            return null;

        const value = compileExpression((*call.arguments)[1]);
        // `destination.pointerElement` is `void_` for a struct/static-array
        // pointee (no opcode scalar type at all, matching `storeThroughPointer`
        // above); its width then comes from the emplaced value's own DMD
        // type size, never a bare `size(ScalarType.void_)`, which is 0.
        const elementSize = destination.pointerElement == ScalarType.void_
            ? typeFacts((*call.arguments)[1].type).byteWidth
            : size(destination.pointerElement);
        emitPointerStore(
            value.offset, destination.offset, compileSizeConstant(0),
            elementSize,
        );

        auto result = new Operand;
        *result = destination;
        return result;
    }

    private Operand* compileEmplaceRef(CallExp call) {
        import dmd.astenums: TY;

        if (call.arguments is null || call.arguments.length == 0)
            return null;

        auto index = (*call.arguments)[0].isIndexExp;
        if (index is null || index.e1.type is null ||
            index.e1.type.toBasetype.ty != TY.Tarray)
            return null;

        if (call.arguments.length == 1) {
            const descriptor = dynamicArrayDescriptor(index.e1);
            if (descriptor.elementType == ScalarType.void_)
                return null;

            const elementSize = dynamicArrayElementSize(index.e1.type);
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
            emitIndexStore(
                value, descriptor.offset, indexSlot.offset, elementSize,
            );

            auto result = new Operand;
            *result = Operand(value, descriptor.elementType);
            return result;
        }

        if (index.type !is null &&
            index.type.toBasetype.isTypeStruct !is null)
        {
            const descriptor = dynamicArrayDescriptor(index.e1);

            const elementSize = dynamicArrayElementSize(index.e1.type);
            if (elementSize > ulong.sizeof)
                return null;

            if (call.arguments.length == 2) {
                auto source = structValueOffsetOrNull(
                    (*call.arguments)[1],
                );
                if (source is null)
                    return null;

                const value = allocateStructBlock(index.type);
                _code ~= Instruction(
                    Op.copy,
                    value,
                    *source,
                    cast(ushort) elementSize,
                );
                if (auto postblit = structDeclarationOf(index.type).postblit)
                    runStructMethod(value, postblit);

                const indexSlot = compileExpression(index.e2);
                emitIndexStore(
                    value, descriptor.offset, indexSlot.offset, elementSize,
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
            emitIndexStore(
                value, descriptor.offset, indexSlot.offset, elementSize,
            );

            auto result = new Operand;
            *result = Operand(value, ScalarType.void_);
            return result;
        }

        if (auto place = placeOrNull(index)) {
            const value = compileExpression((*call.arguments)[1]);
            storePlace(*place, value);
            auto result = new Operand;
            *result = loadPlace(*place);
            return result;
        }
        if (auto place = placeOrNull(index)) {
            auto result = new Operand;
            *result = storeExpressionIntoPlace(
                *place, (*call.arguments)[1],
            );
            return result;
        }

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

    // A captured lvalue belongs to an enclosing live frame, but the ref-call
    // convention expects an offset relative to this nested caller's frame.
    // `capturedFrameIndex` produces the former's absolute stack index; subtract
    // this frame's base so the callee's normal `base + callerOffset` entry
    // handling reaches that enclosing slot.
    private void emitCallArgument(
        in ushort slot,
        in bool isReference,
        Expression argument,
    ) {
        import dmd.astenums: TY;

        if (isReference) {
            emitReferenceArgument(slot, argument);
            return;
        }

        if (argument.type !is null &&
            argument.type.toBasetype.ty == TY.Tstruct) {
            const source = structOperandOffset(argument);
            _code ~= Instruction(
                Op.copy,
                slot,
                source,
                cast(ushort) typeFacts(argument.type).byteWidth,
            );
            return;
        }

        if (argument.type !is null &&
            argument.type.toBasetype.ty == TY.Tsarray) {
            auto place = placeOrNull(argument);
            assert(place !is null);
            const source = loadPlace(*place);
            _code ~= Instruction(
                Op.copy,
                slot,
                source.offset,
                cast(ushort) typeFacts(argument.type).byteWidth,
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
            auto staticArray = argument;
            while (auto cast_ = staticArray.isCastExp)
                staticArray = cast_.e1;
            if (auto slice = staticArray.isSliceExp)
                if (slice.lwr is null && slice.upr is null)
                    staticArray = slice.e1;
            if (staticArray.type !is null &&
                staticArray.type.toBasetype.ty == TY.Tsarray)
                if (auto place = placeOrNull(staticArray)) {
                    const source = addressOfPlace(*place);
                    const element = staticArray.type.toBasetype.nextOf;
                    const count = typeFacts(staticArray.type).byteWidth /
                        typeFacts(cast(Type) element).byteWidth;
                    _code ~= Instruction(
                        Op.copy, slot, source.offset,
                        cast(ushort) size_t.sizeof,
                    );
                    _code ~= Instruction(
                        Op.loadConstant,
                        cast(ushort) sliceDescriptorLengthOffset(slot),
                        constantIndex(count),
                        cast(ushort) size_t.sizeof,
                    );
                    return;
                }

            const descriptor = dynamicArrayDescriptor(argument).offset;
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

    private void emitReferenceArgument(
        in ushort slot,
        Expression argument,
    ) {
        import std.conv: text;

        auto address = placeAddressOrNull(argument);
        if (address is null)
            throw new Exception(text(
                "Unsupported ref argument in bytecode core: ",
                expressionChars(argument),
            ));
        _code ~= Instruction(
            Op.copy, slot, address.offset, cast(ushort) size_t.sizeof,
        );
    }

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

        auto operand = resolveAssocArrayOperand((*call.arguments)[0]);
        const handle = operand.handle.offset;

        with (AssocArrayHook) final switch (hook) {
            case none:
                throw new Exception("Unreachable AA hook.");

            case length: {
                const offset = allocate(ScalarType.ulong_);
                _code ~= Instruction(Op.aaLength, offset, handle);
                return Operand(offset, ScalarType.ulong_);
            }

            case getRvalue: {
                // `const` fails: `Type` is DMD's mutable AST ref.
                auto aaType = assocArrayType((*call.arguments)[0]);
                const valueType = assocArrayValueScalarType(aaType);
                const width = assocArrayValueWidth(aaType);
                const keyMeta = assocArrayKeyMeta(aaType);
                const keyOffset =
                    assocArrayKeyOffset((*call.arguments)[1], aaType);
                const offset = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.aaGetRvalue, offset, handle, keyOffset,
                    cast(ushort) width, keyMeta,
                );
                return Operand(offset, ScalarType.ulong_, true, valueType);
            }

            case getLvalue:
                auto aaType = assocArrayType((*call.arguments)[0]);
                return addressOfPlace(*assocArrayIndexPlace(
                    operand.container,
                    handle,
                    (*call.arguments)[1],
                    aaType,
                    aaType.nextOf,
                ));

            case in_: {
                // `const` fails: `Type` is DMD's mutable AST ref.
                auto aaType = assocArrayType((*call.arguments)[0]);
                const valueType = assocArrayValueScalarType(aaType);
                const width = assocArrayValueWidth(aaType);
                const keyMeta = assocArrayKeyMeta(aaType);
                const keyOffset =
                    assocArrayKeyOffset((*call.arguments)[1], aaType);
                const offset = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.aaIn, offset, handle, keyOffset, cast(ushort) width,
                    keyMeta,
                );
                return Operand(offset, ScalarType.ulong_, true, valueType);
            }

            case remove: {
                auto aaType = assocArrayType((*call.arguments)[0]);
                const width = assocArrayValueWidth(aaType);
                const keyMeta = assocArrayKeyMeta(aaType);
                const keyOffset =
                    assocArrayKeyOffset((*call.arguments)[1], aaType);
                const offset = allocate(ScalarType.bool_);
                _code ~= Instruction(
                    Op.aaRemove, offset, handle, keyOffset,
                    cast(ushort) width, keyMeta,
                );
                return Operand(offset, ScalarType.bool_);
            }

            case equal: {
                auto aaType = assocArrayType((*call.arguments)[0]);
                const width = assocArrayValueWidth(aaType);
                const keyMeta = assocArrayKeyMeta(aaType);
                const right = resolveAssocArrayOperand(
                    (*call.arguments)[1],
                ).handle.offset;
                const offset = allocate(ScalarType.bool_);
                _code ~= Instruction(
                    Op.aaEqual, offset, handle, right, cast(ushort) width,
                    keyMeta,
                );
                return Operand(offset, ScalarType.bool_);
            }

            case dup: {
                const offset = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(Op.aaDup, offset, handle);
                return Operand(offset, ScalarType.ulong_);
            }

            case keys: {
                auto aaType = assocArrayType((*call.arguments)[0]);
                return compileAssocArraySlice(
                    Op.aaKeys, handle, assocArrayKeyWidth(aaType),
                );
            }

            case values: {
                auto aaType = assocArrayType((*call.arguments)[0]);
                return compileAssocArraySlice(
                    Op.aaValues, handle, assocArrayValueWidth(aaType),
                );
            }

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

        // `AssocArray.keys` (machine.d) packs each key at its real width --
        // a scalar's own size, a struct's own whole-block size, or a
        // `string`'s 16-byte slice descriptor (`assocArrayKeyWidth`, the
        // same stride the direct lookup/insert opcodes already key off via
        // `assocArrayKeyMeta`). Reading it back at that same width (rather
        // than a hardcoded 4-byte `int`) is the general fix;
        // `assocArrayKeyIsArray`/`assocArrayKeyWidth` still throw explicitly
        // for a key type direct lookup itself refuses (`wstring`/`dstring`),
        // so no separate check is needed here.
        auto aaType = assocArrayType((*call.arguments)[0]);
        const keyIsArray = assocArrayKeyIsArray(aaType);
        const keyElementSize = assocArrayKeyWidth(aaType);
        // Same reasoning on the value side: `assocArrayValueWidth` is the
        // one place `aaInsert`/`aaGetRvalue`/`Op.aaValues` all size a value
        // from, so `foreach`'s own per-entry stride must match it exactly
        // -- a local, ad hoc struct-or-scalar calculation here previously
        // both threw for a static-array value (`scalarType` rejects
        // `Tsarray`) and, before `assocArrayValueWidth`'s own Tsarray fix,
        // would have desynced from the real entry stride even if patched
        // locally instead.
        const valueIsAggregate =
            valueParameter.type.toBasetype.ty == TY.Tstruct ||
            valueParameter.type.toBasetype.ty == TY.Tsarray;
        const valueElementSize = assocArrayValueWidth(aaType);

        const keys = compileAssocArraySlice(Op.aaKeys, handle, keyElementSize);
        const values = compileAssocArraySlice(
            Op.aaValues, handle, valueElementSize,
        );

        // A struct key that is itself nothing but a single `string` field
        // (`assocArrayKeyIsArray`'s struct branch) is *compared* by content
        // like a bare `string`, but its declared foreach-parameter type is
        // still `Tstruct` -- checking `keyIsStruct` first here keeps it on
        // the same inline-frame representation the raw-byte
        // struct-key foreach case already uses (`dynamicArrayElementType`
        // below expects an actual `Tarray`, not a struct, so it must never
        // see this key's type).
        const keyIsStruct = keyParameter.type.toBasetype.ty == TY.Tstruct;
        const keySlot = keyIsStruct
            ? allocateBytes(
                keyElementSize, staticArrayAlign(keyParameter.type),
            )
            : keyIsArray
                ? allocateBytes(keyElementSize, size_t.sizeof)
                : allocate(scalarType(keyParameter.type));
        registerFrameParameter(keyParameter, keySlot);

        const valueSlot = allocateBytes(
            valueElementSize,
            valueIsAggregate
                ? staticArrayAlign(valueParameter.type)
                : valueElementSize,
        );
        registerFrameParameter(valueParameter, valueSlot);

        const index = compileSizeConstant(0);
        const length = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, length, keys.offset);

        const conditionIndex = _code.length;
        const condition = allocate(ScalarType.bool_);
        _code ~= Instruction(
            Op.lessThanUnsigned8, condition, index, length,
        );
        const exitJump = emitJumpIfFalse(Operand(condition, ScalarType.bool_));

        emitIndexLoad(keySlot, keys.offset, index, keyElementSize);
        emitIndexLoad(valueSlot, values.offset, index, valueElementSize);

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
            cast(ushort) TypeFacts.fromOpcode(ScalarType.int_).byteWidth,
        );
        return Operand(result, ScalarType.int_);
    }

    // The static `V[K]` type of an associative-array operand (after
    // unwrapping `&aa`/`*aa`, the same shapes the hook lowering wraps the AA
    // argument in), for deriving its value type `V`.
    private Type assocArrayType(Expression expression) {
        auto inner = expression;
        if (auto address = inner.isAddrExp)
            inner = address.e1;
        if (auto deref = inner.isPtrExp)
            inner = deref.e1;
        return inner.type.toBasetype;
    }

    // The pointee scalar for an associative array's value type, matching
    // `dynamicArrayElementType`'s convention (`void_` marks an opaque
    // aggregate block rather than a plain machine scalar). `scalarType`
    // itself never classifies `Tdelegate` (a static-registry AA such as
    // `void delegate(...)[string]`, `staticDelegateAssocArrayDeclaration`,
    // still gives its value slot real -- if never runtime-read -- storage);
    // a delegate value is the same opaque 16-byte `{context, funcptr}` pair
    // `emitDelegateValue` lays out for every other delegate-typed slot.
    private ScalarType assocArrayValueScalarType(Type aaType) {
        import dmd.astenums: TY;

        if (aaType.toBasetype.nextOf.toBasetype.ty == TY.Tdelegate)
            return ScalarType.void_;
        if (arrayElementIsArray(aaType))
            return ScalarType.void_;
        return dynamicArrayElementType(aaType);
    }

    // The byte width of an associative array's value type, the same way
    // `dynamicArrayElementSize` sizes a dynamic array's element: a struct or
    // static-array value is its own block size, a dynamic-array value is its
    // own 16-byte slice descriptor, any other value is its scalar width.
    // `AssocArray.values` (`machine.d`) stores entries packed at this stride,
    // mirroring how a dynamic array carries its own element size.
    //
    // A static-array-typed value (`int[3][string]`) is its own inline block
    // -- confirmed against DMD's real lowering, whose `Impl.valsz` for an
    // `int[3]` value is 12, the array's own raw byte width, never a boxed
    // descriptor -- unlike a `Tsarray` *row* nested inside another dynamic
    // array (`int[2][]`), which this VM always boxes behind its own 16-byte
    // slice descriptor (`arrayElementIsArray`'s own doc comment: "this VM's
    // rows are never a raw inline block"). An AA value slot is not a
    // dynamic-array row, so it must not inherit that boxing: checked before
    // `arrayElementIsArray`, which does not distinguish the two shapes
    // (it would otherwise (mis)size a static-array value as a 16-byte
    // descriptor, desyncing `Op.aaValues`' per-entry stride from every
    // opcode -- `aaInsert`/`aaGetRvalue`/`aaIn` -- that sizes the same
    // value at its own raw block width via this same function).
    private uint assocArrayValueWidth(Type aaType) {
        import dmd.astenums: TY;

        if (aaType.toBasetype.nextOf.toBasetype.ty == TY.Tdelegate)
            return delegateValueSize;
        if (aaType.toBasetype.nextOf.toBasetype.ty == TY.Tsarray)
            return typeFacts(aaType.toBasetype.nextOf).byteWidth;
        return dynamicArrayElementSize(aaType, arrayElementIsArray(aaType));
    }

    // The associative array's own key type (`TypeAArray.index`), the
    // key-side counterpart to `assocArrayValueWidth`'s value type.
    private Type assocArrayKeyType(Type aaType) {
        return aaType.isTypeAArray.index;
    }

    // True when the associative array's key is compared by the content its
    // {ptr, length} descriptor points at (`keysEqual`'s `keyIsArray`,
    // machine.d), rather than by the descriptor's own bytes --
    // two separately-constructed but content-equal `string`s have different
    // backing pointers, so a raw descriptor compare would wrongly treat them
    // as distinct keys. Only a plain `string` (immutable `char[]`) is
    // supported this way; `wstring`/`dstring` throw rather than silently
    // miscompare by the wrong element width.
    //
    // A struct key that is itself nothing but a single plain-`string`
    // field (`struct Name { string text; }`) has the exact same {ptr,
    // length} byte layout as a bare `string` -- there are no interleaved
    // scalar fields to keep raw, so it is content-compared the same way
    // (`assocArray.structKeyWithStringMemberComparesStructurally`,
    // `tests/ut/backends/runner/lang/arrays.d`). A struct with any other
    // shape (more than one field, or a lone field that is not a plain
    // `string`) still falls through to the whole-block raw-byte
    // comparison below -- sound only when no field is itself a
    // string/dynamic array, `assocArrayKeyNonArrayWidth`'s scope.
    private bool assocArrayKeyIsArray(Type aaType) {
        import dmd.astenums: TY;
        import std.conv: text;

        auto keyType = assocArrayKeyType(aaType);
        if (isStringType(keyType)) {
            if (!isCharStringType(keyType))
                throw new Exception(text(
                    "Unsupported associative array key type in bytecode core: ",
                    typeChars(keyType),
                ));
            return true;
        }

        if (keyType.toBasetype.ty == TY.Tstruct) {
            auto declaration = structDeclarationOf(keyType);
            if (declaration.fields.length == 1) {
                auto fieldType = cast(Type) declaration.fields[0].type;
                if (isCharStringType(fieldType))
                    return true;
            }
        }

        return false;
    }

    // The field-wise layout for a multi-field struct AA key that has at
    // least one content-compared field (a plain `string` member) -- covers
    // both a key mixing string and scalar fields (`struct Name { string
    // first; int age; }`) and a key with two or more plain `string` fields
    // and no scalar field at all (`struct FullName { string first; string
    // last; }`). Neither `assocArrayKeyIsArray` (all content -- only its own
    // single-field carve-out) nor the default whole-block raw comparison (all
    // raw) is sound for either shape: a raw compare of an all-`string`-field
    // struct would wrongly compare each field's backing pointer instead of
    // its content, exactly like the mixed-field case does for its one string
    // field. Returns `null` when `keyType` doesn't need this: a lone string
    // field (`assocArrayKeyIsArray`'s own single-field carve-out) or an
    // all-scalar struct already have their own simpler, established
    // treatment that this leaves untouched. Mirrors `compileStructIdentity`'s
    // field-by-field walk for `==`: a plain `string` field compares by
    // content, everything else (any type `scalarType` accepts) by its own
    // raw bytes; a `wstring`/`dstring` field, or any other field `scalarType`
    // rejects (a nested struct, a non-`string` dynamic/static array), throws
    // rather than silently miscomparing or silently falling back to a
    // coarser mode.
    private AssocArrayKeyField[] structKeyFieldLayoutOrNull(Type keyType) {
        import std.conv: text;

        auto declaration = structDeclarationOf(keyType);
        if (declaration.fields.length < 2)
            return null;

        bool anyArrayField;
        foreach (field; declaration.fields) {
            auto fieldType = cast(Type) field.type;
            if (isStringType(fieldType)) {
                if (!isCharStringType(fieldType))
                    throw new Exception(text(
                        "Unsupported associative array key type in ",
                        "bytecode core: ", typeChars(keyType),
                    ));
                anyArrayField = true;
            }
        }
        // An all-raw struct (no string field at all) needs no field-wise
        // handling: it is already correctly served by the whole-block raw
        // comparison below. A struct with at least one string field --
        // whether mixed with scalar fields or not -- always needs the
        // field-wise walk, since a raw compare would be unsound for any
        // string field it has.
        if (!anyArrayField)
            return null;

        AssocArrayKeyField[] fields;
        foreach (field; declaration.fields) {
            auto fieldType = cast(Type) field.type;
            const isArray = isStringType(fieldType);
            const width = isArray
                ? sliceDescriptorSize : typeFacts(fieldType).byteWidth;
            fields ~= AssocArrayKeyField(
                cast(ushort) field.offset, cast(ushort) width, isArray,
            );
        }
        return fields;
    }

    // Registers (or reuses) `keyType`'s field layout in
    // `Program.assocArrayKeyLayouts`, returning its index -- one entry per
    // distinct struct-key shape needing field-wise comparison, shared by
    // every AA access site for that key type.
    private ushort registerAssocArrayKeyLayout(
        Type keyType, AssocArrayKeyField[] fields,
    ) {
        auto declaration = structDeclarationOf(keyType);
        if (auto existing = declaration in _assocArrayKeyLayoutIndices)
            return *existing;
        if (_program.assocArrayKeyLayouts.length >=
            assocArrayKeyIsStructLayoutFlag)
            throw new Exception(
                "Too many associative array key layouts in bytecode core",
            );

        const index = cast(ushort) _program.assocArrayKeyLayouts.length;
        _assocArrayKeyLayoutIndices[declaration] = index;
        _program.assocArrayKeyLayouts ~= AssocArrayKeyLayout(
            fields, cast(ushort) typeFacts(keyType).byteWidth,
        );
        return index;
    }

    // The byte width of a non-array AA key: a struct key is its own whole
    // block size (mirroring `dynamicArrayElementSize`'s Tstruct branch on the
    // value side), any other supported key is its scalar width. Only a
    // struct with no string/dynamic-array member is sound here -- storage is
    // raw bytes and `keysEqual` compares those bytes directly, which would
    // wrongly compare backing pointers instead of string content for a
    // string member (still unsupported, tracked separately).
    private uint assocArrayKeyNonArrayWidth(Type aaType) {
        import dmd.astenums: TY;
        import std.conv: text;

        auto keyType = assocArrayKeyType(aaType);
        if (keyType.toBasetype.ty == TY.Tstruct) {
            // A struct `structKeyFieldLayoutOrNull` itself declined --
            // meaning it found no TOP-LEVEL plain-`string` field to route
            // through field-wise structural comparison -- may still have an
            // array-typed field this raw whole-block path cannot soundly
            // compare: a top-level field that is an array but not a plain
            // immutable `string` (a mutable `char[]`, a `wstring`/`dstring`,
            // or a non-string dynamic array like `int[]`), or an array field
            // nested one or more struct levels deeper (`structKeyFieldLayoutOrNull`
            // only ever looks at `keyType`'s own immediate fields). Two
            // separately-built but content-equal arrays have different
            // backing pointers, so comparing them as part of this raw block
            // would silently compare identity instead of content -- decline
            // instead, the same diagnostic `assocArrayKeyIsArray` already
            // raises for an unsupported array-typed key.
            if (structKeyFieldLayoutOrNull(keyType) is null &&
                    structHasArrayFieldRecursive(keyType))
                throw new Exception(text(
                    "Unsupported associative array key type in ",
                    "bytecode core: ", typeChars(keyType),
                ));
            return typeFacts(keyType).byteWidth;
        }
        return typeFacts(keyType).byteWidth;
    }

    // `assocArrayKeyNonArrayWidth`'s own recursive field scan: true when
    // `keyType` (a struct) has any field, at any nesting depth through
    // further struct fields, whose own type is a dynamic array (`Tarray`,
    // covering every string variant too).
    private bool structHasArrayFieldRecursive(Type keyType) {
        import dmd.astenums: TY;

        auto declaration = structDeclarationOf(keyType);
        foreach (field; declaration.fields) {
            auto fieldType = cast(Type) field.type;
            const ty = fieldType.toBasetype.ty;
            if (ty == TY.Tarray)
                return true;
            if (ty == TY.Tstruct && structHasArrayFieldRecursive(fieldType))
                return true;
        }
        return false;
    }

    // The byte width `AssocArray.keys` (`machine.d`) packs each key entry
    // at, mirroring `assocArrayValueWidth`'s value-side stride: a `string`
    // key is its own 16-byte slice descriptor; any other supported key is
    // its scalar or struct width.
    private uint assocArrayKeyWidth(Type aaType) {
        return assocArrayKeyIsArray(aaType)
            ? sliceDescriptorSize
            : assocArrayKeyNonArrayWidth(aaType);
    }

    // Packs an AA key's width and comparison mode into `Instruction.e`
    // (`assocArrayKeyIsArrayFlag`/`assocArrayKeyIsStructLayoutFlag`): every AA
    // opcode that reads or writes a key needs both, and there is no operand
    // to spare for a second field. A multi-field struct key with at least one
    // string field (`structKeyFieldLayoutOrNull`) needs a third mode neither
    // existing flag combination can express (it is neither all-raw nor
    // all-content when mixed, and even an all-string-field key is a block of
    // *several* content-compared descriptors, not the one whole descriptor
    // `assocArrayKeyIsArray` handles), so it is instead tagged with
    // `assocArrayKeyIsStructLayoutFlag` and carries a
    // `Program.assocArrayKeyLayouts` index (registered once per struct type,
    // `registerAssocArrayKeyLayout`) in the same bits the other two modes use
    // for a byte width -- the layout entry itself already knows the key's
    // total width, so the operand doesn't need to carry it too.
    private ushort assocArrayKeyMeta(Type aaType) {
        import dmd.astenums: TY;

        auto keyType = assocArrayKeyType(aaType);
        if (keyType.toBasetype.ty == TY.Tstruct)
            if (auto fields = structKeyFieldLayoutOrNull(keyType)) {
                const index = registerAssocArrayKeyLayout(keyType, fields);
                assert(index < assocArrayKeyIsStructLayoutFlag);
                return cast(ushort) (index | assocArrayKeyIsStructLayoutFlag);
            }

        const isArray = assocArrayKeyIsArray(aaType);
        const width = isArray
            ? sliceDescriptorSize
            : assocArrayKeyNonArrayWidth(aaType);
        assert(width < assocArrayKeyIsArrayFlag);
        return cast(ushort) (width | (isArray ? assocArrayKeyIsArrayFlag : 0));
    }

    // The frame offset of a compiled AA key's raw bytes, `assocArrayKeyMeta`'s
    // expression-compiling counterpart: a struct-typed key (a local or a
    // literal) is not itself a frame-resident scalar the generic
    // `compileExpression` `VarExp` path recognises, so route it through
    // `structOperandOffset` instead; any other supported key
    // (scalar or `string`) already compiles correctly through the generic
    // path.
    private ushort assocArrayKeyOffset(Expression keyExpression, Type aaType) {
        import dmd.astenums: TY;

        if (assocArrayKeyType(aaType).toBasetype.ty == TY.Tstruct)
            return structOperandOffset(keyExpression);
        return compileExpression(keyExpression).offset;
    }

    private struct AssocArrayOperand {
        Place* container;
        Operand handle;
    }

    // Resolve the AA's authoritative storage once. An lvalue hook can then
    // write an autovivified handle back through this same place; read-only
    // hooks use only the loaded handle.
    private AssocArrayOperand resolveAssocArrayOperand(Expression expression) {
        import std.conv: text;

        auto inner = expression;
        if (auto address = inner.isAddrExp)
            inner = address.e1;
        if (auto deref = inner.isPtrExp)
            inner = deref.e1;

        if (auto container = placeOrNull(inner))
            return AssocArrayOperand(
                container, loadPlaceValue(*container),
            );

        if (staticDelegateAssocArrayDeclaration(inner) !is null) {
            const offset =
                allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
            _code ~= Instruction(Op.aaNew, offset);
            return AssocArrayOperand(
                null, Operand(offset, ScalarType.ulong_),
            );
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
                dynamicArrayDescriptor(assert_.msg).offset;
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
        const messageOffset = dynamicArrayDescriptor(assert_.msg).offset;

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

        // A delegate comparison (`==`, `!=`, `is`, `!is`; a delegate has no
        // relational operators): a delegate has no `opEquals` either, so
        // `assert_.e1` is already the authoritative `EqualExp`/`IdentityExp`
        // `compileBoolValue` (via `compileEqualExpression`/
        // `compileIdentityExpression`) now handles directly. Compile that
        // condition and assert it the same fixed-message way the struct case
        // above does, instead of destructuring the rendered
        // `_d_assert_fail` operands.
        if ((*call.arguments)[1].type.toBasetype.ty == TY.Tdelegate ||
            (*call.arguments)[2].type.toBasetype.ty == TY.Tdelegate)
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
            if (tryNestedArrayComparisonAssert(
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
        const lhs = dynamicArrayDescriptor(lhsExpression).offset;
        const rhs = dynamicArrayDescriptor(rhsExpression).offset;
        const condition = allocate(ScalarType.bool_);
        emitSliceEqual(condition, lhs, rhs, 1);
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
    // byte-wise; a delegate identity (`dg1 is dg2`, no such lowering since a
    // delegate has no `opEquals`) routes through the same two-halves
    // comparison `compileEqualExpression`'s `Tdelegate` branch uses;
    // everything else is an ordinary boolean expression (an `opEquals` call,
    // an `opCmp` relation, a `&&` chain).
    private Operand compileBoolValue(Expression expression) {
        import dmd.astenums: TY;

        if (auto identity = expression.isIdentityExp) {
            if (identity.e1.type.toBasetype.ty == TY.Tdelegate)
                return compileIdentityExpression(identity);
            return compileStructIdentity(identity);
        }
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
                emitSliceEqual(
                    fieldEqual,
                    cast(ushort) (left + field.offset),
                    cast(ushort) (right + field.offset),
                    dynamicArrayElementSize(fieldType),
                );
                falseJumps ~=
                    emitJumpIfFalse(Operand(fieldEqual, ScalarType.bool_));
                continue;
            }

            _code ~= Instruction(
                equalOp(typeFacts(fieldType).byteWidth),
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
    // slice, `dynamicArrayDescriptor` builds a slice view over the static
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
        // when materialised dynamically stores each row as a raw byte block,
        // not a 16-byte slice descriptor, while the other, dynamic-array side
        // builds proper nested descriptors -- comparing the two would compare
        // unrelated byte shapes. Decline so the caller falls through to
        // `tryNestedArrayComparisonAssert`'s row-by-row comparison instead of
        // a silent wrong result.
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
        // `int[][] == int[][]` (any nesting depth): both operands are
        // genuine dynamic arrays whose own element is itself an array (the
        // mixed Tsarray/Tarray nested case above already declined; a
        // Tsarray on both sides never reaches this function at all). Each
        // row is a separately heap-allocated slice descriptor, so the flat
        // `sliceEqualOp` byte compare below would compare row `.ptr` values
        // instead of content -- structural comparison needs the dedicated
        // nested opcode instead.
        const nested = lhsTy == TY.Tarray && rhsTy == TY.Tarray &&
            arrayElementIsArray(lhs.type) &&
            arrayElementIsArray(rhs.type);
        const lhsOffset = dynamicArrayDescriptor(lhs).offset;
        const rhsOffset = dynamicArrayDescriptor(rhs).offset;

        const equal = nested
            ? emitNestedArrayEqual(lhsOffset, rhsOffset, lhs.type)
            : allocateBytes(1, 1);
        if (!nested)
            emitSliceEqual(
                equal, lhsOffset, rhsOffset,
                dynamicArrayElementSize(lhs.type),
            );

        // `==` holds when the slices are equal; `!=` holds when negated.
        ushort condition = equal;
        if (op == "!=") {
            condition = allocateBytes(1, 1);
            _code ~= Instruction(Op.notBool, condition, equal);
        }

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~=
            AssertDiagnostic(
                op, lhsOffset, rhsOffset, elementType, true,
                elementNestingDepth: nested ? arrayNestingDepth(lhs.type) - 1 : 0,
            );
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
        emitSliceEqual(
            equal, lhsOffset, rhsOffset,
            typeFacts(elementType).byteWidth,
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

    // `assert(a == b)` where one side is a static array whose own element is
    // itself an array (`int[2][2]`) and the other is a genuine array of
    // arrays -- either a real `T[][]` local or DMD's hoisted stack temp for a
    // nested array literal, which types each row as its own independently
    // heap-allocated dynamic array rather than a flat static block
    // (`tryStackArrayLiteralSliceInto` builds exactly that shape). The two
    // sides' rows are not the same byte shape (a contiguous inline block on
    // the static side, an independent heap slice on the other), so neither
    // `tryStaticArrayComparisonAssert`'s single memcmp nor
    // `tryArrayComparisonAssert`'s flat slice compare applies; compare row by
    // row instead, mirroring DMD's own recursive `__equals` lowering: the
    // outer lengths must match, then every row compares content-equal, with
    // the static side's row read as a view sharing its own storage (no copy)
    // and the other side's row fetched from its own descriptor.
    private bool tryNestedArrayComparisonAssert(
        in string op,
        Expression lhs,
        Expression rhs,
    ) {
        import dmd.astenums: TY;

        auto nestedStatic = lhs;
        auto other = rhs;
        const lhsIsNested = lhs.type.toBasetype.ty == TY.Tsarray &&
            arrayElementIsArray(lhs.type);
        if (!lhsIsNested) {
            const rhsIsNested = rhs.type.toBasetype.ty == TY.Tsarray &&
                arrayElementIsArray(rhs.type);
            if (!rhsIsNested)
                return false;
            nestedStatic = rhs;
            other = lhs;
        }

        auto rowType = nestedStatic.type.toBasetype.nextOf;
        if (rowType.toBasetype.ty != TY.Tsarray)
            return false;

        auto nestedPlace = placeOrNull(nestedStatic);
        if (nestedPlace is null)
            return false;
        const nestedAddress = addressOfPlace(*nestedPlace);
        const nestedValue = loadPlace(*nestedPlace);

        auto rowElementType = rowType.toBasetype.nextOf;
        const rowElementScalar = scalarType(rowElementType);
        const rowByteSize = typeFacts(rowType).byteWidth;
        const rowLength = cast(uint) (rowByteSize / size(rowElementScalar));
        const rowCount =
            typeFacts(nestedStatic.type).byteWidth / rowByteSize;

        const otherDescriptor = dynamicArrayDescriptor(other).offset;
        const otherLength = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, otherLength, otherDescriptor);

        const lengthsEqual = allocateBytes(1, 1);
        _code ~= Instruction(
            comparisonEqualOp(ScalarType.ulong_),
            lengthsEqual,
            compileSizeConstant(rowCount),
            otherLength,
        );

        size_t[] toFalse =
            [emitJumpIfFalse(Operand(lengthsEqual, ScalarType.bool_))];

        foreach (rowIndex; 0 .. rowCount) {
            const view = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            const rowAddress = pointerPlaceAddress(
                nestedAddress.offset,
                compileSizeConstant(rowIndex * rowByteSize),
                1,
                ScalarType.void_,
            );
            _code ~= Instruction(
                Op.copy, view, rowAddress.offset,
                cast(ushort) size_t.sizeof,
            );
            _code ~= Instruction(
                Op.loadConstant,
                cast(ushort) sliceDescriptorLengthOffset(view),
                constantIndex(rowLength),
                cast(ushort) size_t.sizeof,
            );

            const indexSlot = compileSizeConstant(rowIndex);
            const otherRow = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            emitIndexLoad(otherRow, otherDescriptor, indexSlot, sliceDescriptorSize);

            const rowEqual = allocateBytes(1, 1);
            emitSliceEqual(rowEqual, view, otherRow, size(rowElementScalar));
            toFalse ~= emitJumpIfFalse(Operand(rowEqual, ScalarType.bool_));
        }

        const result = allocateBytes(1, 1);
        _code ~= Instruction(Op.loadConstant, result, constantIndex(1), 1);
        const doneJump = emitJump;
        foreach (patch; toFalse)
            patchJump(patch);
        _code ~= Instruction(Op.loadConstant, result, constantIndex(0), 1);
        patchJump(doneJump);

        ushort condition = result;
        if (op == "!=") {
            condition = allocateBytes(1, 1);
            _code ~= Instruction(Op.notBool, condition, result);
        }

        const diagnostic = _program.assertDiagnostics.length;
        _program.assertDiagnostics ~= AssertDiagnostic(
            op, nestedValue.offset, otherDescriptor, ScalarType.void_,
        );
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

        const width = assocArrayValueWidth(lhs.type.toBasetype);
        const keyMeta = assocArrayKeyMeta(lhs.type.toBasetype);
        const left = resolveAssocArrayOperand(lhs).handle.offset;
        const right = resolveAssocArrayOperand(rhs).handle.offset;
        const equal = allocateBytes(1, 1);
        _code ~= Instruction(
            Op.aaEqual, equal, left, right, cast(ushort) width, keyMeta,
        );

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

    // The `indexLoad*`/`indexStore*` family's emit helpers: `width` is a
    // required parameter, not a hint, so a call site cannot build one of
    // these instructions without stating its element width (structural
    // consolidation queue item 1, `ai/plans/bytecode.md`). Both the opcode
    // (via `indexLoadOp`/`indexStoreOp`) and the instruction's own width
    // operand are derived from the same `width` value, so `indexLoadN`/
    // `indexStoreN` -- the only forms that actually read that operand at run
    // time -- can never see it silently defaulted to zero.
    private void emitIndexLoad(
        in ushort destination, in ushort arrayBase, in ushort index,
        in uint width,
    ) @safe pure {
        _code ~= Instruction(
            indexLoadOp(width), destination, arrayBase, index,
            cast(ushort) width,
        );
    }

    private void emitIndexStore(
        in ushort value, in ushort arrayBase, in ushort index, in uint width,
    ) @safe pure {
        _code ~= Instruction(
            indexStoreOp(width), value, arrayBase, index, cast(ushort) width,
        );
    }

    // The `pointerLoad*`/`pointerStore*`/`pointerSlice*` family's emit
    // helpers, the pointer-family counterpart of `emitIndexLoad`/
    // `emitIndexStore` above: `width` is a required parameter here too, so a
    // call site cannot build one of these instructions without stating the
    // pointee's byte width. `index`/`bounds` is a frame offset -- either a
    // zero constant (`*p`) or a real runtime index/bounds slot (`p[i]`,
    // `p[lo .. hi]`) -- never a hand-built `Instruction`.
    private void emitPointerLoad(
        in ushort destination, in ushort pointer, in ushort index,
        in uint width,
    ) @safe pure {
        _code ~= Instruction(
            pointerLoadOp(width), destination, pointer, index,
            cast(ushort) width,
        );
    }

    private void emitPointerStore(
        in ushort value, in ushort pointer, in ushort index, in uint width,
    ) @safe pure {
        _code ~= Instruction(
            pointerStoreOp(width), value, pointer, index, cast(ushort) width,
        );
    }

    private void emitPointerSlice(
        in ushort destination, in ushort pointer, in ushort bounds,
        in uint width,
    ) @safe pure {
        _code ~= Instruction(
            pointerSliceOp(width), destination, pointer, bounds,
            cast(ushort) width,
        );
    }

    // The `subSlice*` family's emit helper: a single opcode per width (not a
    // load/store/slice split, since forming a sub-slice descriptor is one
    // operation), but the same required-`width` treatment as
    // `emitIndexLoad`/`emitPointerLoad` above. `bounds` is a frame offset for
    // a `{lo, hi}` size_t pair already materialised by the caller, never a
    // hand-built `Instruction`.
    private void emitSubSlice(
        in ushort destination, in ushort source, in ushort bounds,
        in uint width,
    ) @safe pure {
        _code ~= Instruction(
            subSliceOp(width), destination, source, bounds, cast(ushort) width,
        );
    }

    // The `appendElement*` family's emit helper, the same required-`width`
    // treatment as `emitSubSlice` above: one opcode per width, and `width`
    // cannot be omitted or silently defaulted to zero.
    private void emitAppendElement(
        in ushort array, in ushort element, in uint width,
    ) @safe pure {
        _code ~= Instruction(
            appendElementOp(width), array, element, cast(ushort) width,
        );
    }

    // The `dupArray*` family's emit helper, the same required-`width`
    // treatment as `emitAppendElement` above: one opcode per width, and
    // `width` cannot be omitted or silently defaulted to zero.
    private void emitDupArray(
        in ushort destination, in ushort source, in uint width,
    ) @safe pure {
        _code ~= Instruction(
            dupArrayOp(width), destination, source, cast(ushort) width,
        );
    }

    // The `concatArrays*` family's emit helper, the same required-`width`
    // treatment as `emitDupArray` above: one opcode per width, and `width`
    // cannot be omitted or silently defaulted to zero.
    private void emitConcatArrays(
        in ushort destination, in ushort left, in ushort right,
        in uint width,
    ) @safe pure {
        _code ~= Instruction(
            concatArraysOp(width), destination, left, right,
            cast(ushort) width,
        );
    }

    // The `sliceCopy*` family's emit helper, the same required-`width`
    // treatment as `emitConcatArrays` above: one opcode per width (1/2/4/8/16,
    // plus the `N` fallback), and `width` cannot be omitted or silently
    // defaulted to zero.
    private void emitSliceCopy(
        in ushort destination, in ushort source, in uint width,
    ) @safe pure {
        _code ~= Instruction(
            sliceCopyOp(width), destination, source, cast(ushort) width,
        );
    }

    // The `sliceFill*` family's emit helper, the same required-`width`
    // treatment as `emitSliceCopy` above, but over `sliceFill`'s own narrower
    // op<->width table (1/2/4/8, plus the `N` fallback; no `sliceFill16` --
    // see `sliceFillOpWidths` in program.d).
    private void emitSliceFill(
        in ushort destination, in ushort value, in uint width,
    ) @safe pure {
        _code ~= Instruction(
            sliceFillOp(width), destination, value, cast(ushort) width,
        );
    }

    // Broadcast one already-compiled row value (`value`, `rowByteSize`
    // bytes) into every element of a `[lo .. hi)` range of a `T[N][]`
    // destination (`destination`, a slice descriptor over that range). Each
    // destination slot is its own 16-byte `{ptr, length}` row descriptor
    // pointing at a separately heap-allocated block (`Op.allocArray2D`), so
    // this writes through each row's existing `.ptr` in a runtime loop --
    // `emitSliceFill`'s flat byte-fill would instead overwrite the row
    // descriptors themselves, aliasing every destination row to whatever
    // bytes `value` happens to hold rather than writing into each row's own
    // storage.
    private void emitRowBroadcastFill(
        in ushort destination,
        in ushort value,
        in uint rowByteSize,
    ) {
        const index = compileSizeConstant(0);
        const length = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, length, destination);

        const conditionIndex = _code.length;
        const condition = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.lessThanUnsigned8, condition, index, length);
        const exitJump = emitJumpIfFalse(Operand(condition, ScalarType.bool_));

        const rowDescriptor =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        emitIndexLoad(rowDescriptor, destination, index, sliceDescriptorSize);
        const rowPointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, rowPointer, rowDescriptor, cast(ushort) size_t.sizeof,
        );
        emitPointerStore(value, rowPointer, compileSizeConstant(0), rowByteSize);

        const one = compileSizeConstant(1);
        _code ~= Instruction(Op.addInt8, index, index, one);
        _code ~= Instruction(Op.jump, cast(ushort) conditionIndex);

        patchJump(exitJump);
    }

    // Copy a range of rows (`arr[lo .. hi] = otherRows[];`) into a `T[N][]`
    // destination, where `source` is itself a matching range of rows (not a
    // single broadcast row -- see `emitRowBroadcastFill`). `Op.rowRangeCopy`
    // writes each source row's content into the matching destination row's
    // own existing heap-allocated block instead of `sliceCopy16`'s flat
    // by-value descriptor copy, which would alias every destination row to
    // the source's block (see `Op.rowRangeCopy`'s doc comment).
    private void emitRowRangeCopy(
        in ushort destination,
        in ushort source,
        in uint rowByteSize,
    ) @safe pure {
        _code ~= Instruction(
            Op.rowRangeCopy, destination, source, cast(ushort) rowByteSize,
        );
    }

    // Copy contiguous inline source rows into each separately allocated
    // `T[N][]` destination row. The mismatch path delegates to `sliceCopy1`
    // solely for its standard length diagnostic; it throws before reading the
    // synthetic descriptors' null pointers.
    private void emitInlineRowRangeCopy(
        in ushort destination,
        in ushort source,
        in uint rowByteSize,
    ) {
        const destinationLength = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, destinationLength, destination);
        const sourceLength = allocate(ScalarType.ulong_);
        _code ~= Instruction(Op.sliceLength, sourceLength, source);
        const lengthsMatch = allocate(ScalarType.bool_);
        _code ~= Instruction(
            Op.equal8, lengthsMatch, destinationLength, sourceLength,
        );
        const lengthsMatchJump = emitJumpIfTrue(
            Operand(lengthsMatch, ScalarType.bool_),
        );

        const mismatchDestination =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (mismatchDestination + size_t.sizeof),
            destinationLength,
            cast(ushort) size_t.sizeof,
        );
        const mismatchSource =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.copy,
            cast(ushort) (mismatchSource + size_t.sizeof),
            sourceLength,
            cast(ushort) size_t.sizeof,
        );
        emitSliceCopy(mismatchDestination, mismatchSource, 1);
        patchJump(lengthsMatchJump);

        const sourcePointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy, sourcePointer, source, cast(ushort) size_t.sizeof,
        );
        const index = compileSizeConstant(0);
        const conditionIndex = _code.length;
        const condition = allocate(ScalarType.bool_);
        _code ~= Instruction(
            Op.lessThanUnsigned8, condition, index, destinationLength,
        );
        const exitJump = emitJumpIfFalse(Operand(condition, ScalarType.bool_));

        const rowDescriptor =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        emitIndexLoad(rowDescriptor, destination, index, sliceDescriptorSize);
        const destinationPointer =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        _code ~= Instruction(
            Op.copy,
            destinationPointer,
            rowDescriptor,
            cast(ushort) size_t.sizeof,
        );
        const sourceRow = allocateBytes(rowByteSize, 1);
        emitPointerLoad(sourceRow, sourcePointer, index, rowByteSize);
        emitPointerStore(sourceRow, destinationPointer, compileSizeConstant(0), rowByteSize);

        const one = compileSizeConstant(1);
        _code ~= Instruction(Op.addInt8, index, index, one);
        _code ~= Instruction(Op.jump, cast(ushort) conditionIndex);
        patchJump(exitJump);
    }

    // The `sliceEqual*` family's emit helper. Unlike every other
    // width-suffixed family here, `sliceEqualOp` has no `N` fallback (throws
    // if `width` is not one of the four fixed widths -- see
    // `sliceEqualOpWidths` in program.d) and the fixed-width opcode carries
    // no width operand of its own (`width` only selects which opcode to
    // build; the instruction's `a`/`b`/`c` are destination/lhs/rhs). Still
    // the same required-`width` treatment: `width` cannot be omitted or
    // silently defaulted to zero. `Op.sliceEqualNested` (structural
    // array-of-arrays comparison, a genuinely different opcode with its own
    // depth/element-width operands) is not this family and keeps its own
    // `emitNestedArrayEqual` construction site unchanged.
    private void emitSliceEqual(
        in ushort destination, in ushort lhs, in ushort rhs, in uint width,
    ) @safe pure {
        _code ~= Instruction(sliceEqualOp(width), destination, lhs, rhs);
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

    // Appends one type-driven parameter entry to `layout`. A direct reference
    // always occupies one native-address slot; a by-value dynamic array,
    // struct/static array, delegate, or scalar occupies its own inline slot at
    // its natural alignment. Shared between `parameterLayout`'s
    // no-bound-`VarDeclaration` fallback (an extern signature known only by
    // type) and a call through a delegate-typed parameter, where the callee
    // is likewise known only by its declared type.
    private void appendParameterLayoutEntry(
        ref ParameterLayout layout,
        Type type,
        in bool isReference,
    ) {
        import std.conv: text;

        if (isReference) {
            enum pointerAlign = cast(uint) size_t.sizeof;
            layout.blockSize = (layout.blockSize +
                pointerAlign - 1) & ~(pointerAlign - 1);
            layout.offsets ~= cast(ushort) layout.blockSize;
            layout.isReference ~= true;
            layout.blockSize += pointerAlign;
            return;
        }

        const facts = typeFacts(type);
        uint argumentSize;
        uint argumentAlign;
        final switch (facts.representation) with (DeclarationRepresentation) {
            case unavailable:
            case lazyDelegate:
                throw new Exception(text(
                    "Unsupported parameter type in bytecode core: ",
                    typeChars(type),
                ));
            case scalar:
            case pointer:
            case classPointer:
            case assocArray:
                argumentSize = facts.byteWidth;
                argumentAlign = argumentSize;
                break;
            case staticArray:
            case vector:
            case struct_:
            case complexDouble:
                argumentSize = facts.byteWidth;
                argumentAlign = staticArrayAlign(type);
                break;
            case dynamicArray:
            case delegate_:
                argumentSize = facts.byteWidth;
                argumentAlign = cast(uint) size_t.sizeof;
                break;
        }
        layout.blockSize = (layout.blockSize +
            argumentAlign - 1) & ~(argumentAlign - 1);
        layout.offsets ~= cast(ushort) layout.blockSize;
        layout.isReference ~= isReference;
        layout.blockSize += argumentSize;
    }

    private ParameterLayout parameterLayout(FuncDeclaration function_) {
        ParameterLayout layout;

        // A struct method takes its receiver's native address as hidden `this`.
        if (thisStructDeclaration(function_) !is null) {
            enum pointerAlign = cast(uint) size_t.sizeof;
            layout.blockSize =
                (layout.blockSize + pointerAlign - 1) & ~(pointerAlign - 1);
            layout.hasThis = true;
            layout.thisOffset = cast(ushort) layout.blockSize;
            layout.blockSize += pointerAlign;
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

            appendParameterLayoutEntry(
                layout, parameter.type, parameter.isReference,
            );
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
                scalar: ScalarType.void_,
                isArray: true,
                elementType: dynamicArrayElementType(type),
                arrayElementsAreArrays: arrayElementIsArray(type),
                isStruct: false,
                structSize: 0,
                isUndisplayable: false,
                isStaticArray: false,
                arrayLength: 0,
                arrayElementsAreStrings: false,
                enumMembers: null,
                elementEnumMembers: enumMembersByValue(type.toBasetype.nextOf),
            );
            populateArrayElementStructDisplay(result, type);
            return result;
        }

        if (type.toBasetype.ty == TY.Tsarray && arrayElementIsString(type))
            return ResultType(
                scalar: ScalarType.void_,
                isArray: true,
                elementType: dynamicArrayElementType(type),
                arrayElementsAreArrays: arrayElementIsArray(type),
                isStruct: false,
                structSize: typeFacts(type).byteWidth,
                isUndisplayable: false,
                isStaticArray: true,
                arrayLength: staticArrayLength(type),
                arrayElementsAreStrings: arrayElementIsString(type),
            );

        if (type.toBasetype.ty == TY.Tsarray)
            return ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: true,
                structSize: typeFacts(type).byteWidth,
            );

        // A by-value struct result is an inline block of `Type.size()` bytes,
        // copied back to the caller's destination on return like any other frame
        // block; field access then resolves against that destination's base.
        if (type.toBasetype.ty == TY.Tstruct) {
            auto result = ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: true,
                structSize: typeFacts(type).byteWidth,
            );
            populateStructDisplay(result, type);
            return result;
        }

        // A delegate result is a real 16-byte `{functionIndex, context}`
        // pair the caller must receive, not just an REPL-undisplayable
        // value with no bytes -- distinct from the generic
        // `isUndisplayableType` branch below, which only marks display
        // scaffolding.
        if (type.toBasetype.ty == TY.Tdelegate) {
            auto result = ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: false,
                structSize: 0,
                isUndisplayable: true,
            );
            result.isDelegate = true;
            return result;
        }

        if (isUndisplayableType(type))
            return ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: false,
                structSize: 0,
                isUndisplayable: true,
            );

        if (isPointerType(type))
            return ResultType.scalarResult(ScalarType.ulong_);

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
            scalar: ScalarType.void_,
            isArray: false,
            elementType: ScalarType.void_,
            arrayElementsAreArrays: false,
            isStruct: true,
            structSize: typeFacts(element).byteWidth,
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
            return ResultType.scalarResult(ScalarType.void_);
        if (function_.type.isTypeFunction !is null &&
            function_.type.isTypeFunction.isRef)
            return ResultType.scalarResult(ScalarType.ulong_);
        return resultType(returnType(function_));
    }

    // The element scalar type of a dynamic array `T[]`. For an array-of-arrays
    // at any nesting depth (`int[][]`, `int[][][]`, ...) the element is
    // itself a `T[]`; recurse through however many array layers until an
    // element that is not itself an array turns up, and return its scalar
    // type (`int`) -- the type used to size and index the innermost
    // elements.
    private ScalarType dynamicArrayElementType(Type type) {
        import dmd.astenums: TY;

        auto element = type.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tarray)
            return dynamicArrayElementType(element);
        if (element.toBasetype.ty == TY.Tsarray)
            return dynamicArrayElementType(element);
        if (element.toBasetype.ty == TY.Tpointer)
            return ScalarType.ulong_;
        if (element.toBasetype.ty == TY.Tstruct ||
            element.toBasetype.ty == TY.Tsarray ||
            element.toBasetype.ty == TY.Tdelegate)
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

    // The aggregate-vs-scalar classification is `typeFacts`': a
    // struct, static array, or delegate element is a full-width byte blob
    // (`byteWidth`), everything else is a plain scalar. `Tvoid` stays a
    // hand-checked special case: D defines `void[]` with a one-byte element
    // stride even though `void` is not a loadable scalar value.
    private uint dynamicArrayElementSize(
        Type type,
        in bool elementIsArray = false,
    ) {
        import dmd.astenums: TY;

        if (elementIsArray)
            return sliceDescriptorSize;

        auto element = type.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tvoid)
            return 1;
        return typeFacts(element).byteWidth;
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

    // The nesting depth of an array-of-arrays type gated by
    // `arrayElementIsArray` (`T[]` whose element is itself an array): 2 for
    // `int[][]` (one row level below the outer array), 3 for `int[][][]`,
    // and so on. Walks the chain of `Tarray` elements one level at a time,
    // the same way `arrayElementIsArray` and `innermostArrayElementSize`
    // do, stopping as soon as a level's element is not itself a `Tarray` --
    // a `Tsarray` element (e.g. `int[2][]`) still counts as one nested
    // level (matching this function's own one-level gate for that case) but
    // does not extend the walk further: `compileAppendElement` heap-boxes a
    // `Tsarray` row behind its own 16-byte slice descriptor just like a
    // `Tarray` row (this VM's rows are never a raw inline block), so
    // `Op.sliceEqualNested`'s row-descriptor recursion can unwrap that one
    // boxed level, but not recurse further into the static array's own
    // fixed-size interior (see the Tsarray/Tarray decline block in
    // `tryArrayComparisonAssert`).
    private uint arrayNestingDepth(Type type) {
        import dmd.astenums: TY;

        uint depth = 1;
        auto current = type.toBasetype;
        while (arrayElementIsArray(current)) {
            ++depth;
            auto nextBase = current.nextOf.toBasetype;
            if (nextBase.ty != TY.Tarray)
                break;
            current = nextBase;
        }
        return depth;
    }

    // The byte width of the innermost (leaf) row's own elements for an
    // array-of-arrays type gated by `arrayElementIsArray`, e.g. 4 for both
    // `int[][]`'s and `int[][][]`'s `int` leaves, and also 4 for `int[2][]`'s
    // `int` leaves (a `Tsarray` row is heap-boxed behind its own 16-byte
    // slice descriptor just like a `Tarray` row -- see `arrayNestingDepth`
    // -- so once that one boxed level is unwrapped, its own elements, not
    // the row's full byte size, are what a flat byte-compare needs). Walks
    // the same `Tarray` chain
    // as `arrayNestingDepth`, always advancing `current` to the row it just
    // looked at (even the terminating one, whether that row is another
    // `Tarray` level or the leaf `Tsarray`), then reuses
    // `dynamicArrayElementSize`'s existing scalar/struct/static-array sizing
    // for that row's own elements.
    private uint innermostArrayElementSize(Type type) {
        import dmd.astenums: TY;

        auto current = type.toBasetype;
        while (arrayElementIsArray(current)) {
            auto nextBase = current.nextOf.toBasetype;
            current = nextBase;
            if (nextBase.ty != TY.Tarray)
                break;
        }
        return dynamicArrayElementSize(current);
    }

    // Emit `Op.sliceEqualNested`, comparing two array-of-arrays descriptors
    // structurally rather than as raw descriptor bytes: DMD's real
    // `__equals` lowering recurses into each element, so two separately
    // heap-allocated but content-equal rows must compare equal, unlike a
    // byte compare of the outer descriptor (which would compare the rows'
    // `.ptr` values). Handles any nesting depth (`int[][]`, `int[][][]`,
    // ...); caller gates this with `arrayElementIsArray`.
    private ushort emitNestedArrayEqual(
        in ushort left,
        in ushort right,
        Type outerType,
    ) {
        const result = allocateBytes(1, 1);
        _code ~= Instruction(
            Op.sliceEqualNested,
            result,
            left,
            right,
            cast(ushort) arrayNestingDepth(outerType),
            cast(ushort) innermostArrayElementSize(outerType),
        );
        return result;
    }

    // Materialise a compile-time-constant `size_t` index into a frame slot, for
    // opcodes that take their index from a frame slot.
    private ushort compileSizeConstant(in size_t value) @safe pure {
        const offset = allocate(ScalarType.ulong_);
        _code ~= Instruction(
            Op.loadConstant,
            offset,
            constantIndex(value),
            cast(ushort) TypeFacts.fromOpcode(ScalarType.ulong_).byteWidth,
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

    private TypeFacts pointerElementMetadata(Type pointerType) {
        import dmd.astenums: TY;

        auto element = pointerType.toBasetype.nextOf;
        if (element is null)
            return TypeFacts.withoutByteWidth(ScalarType.void_);
        if (element.toBasetype.ty == TY.Tfunction)
            return TypeFacts.withoutByteWidth(
                ScalarType.void_, DeclarationRepresentation.unavailable,
                true,
            );
        return typeFacts(element);
    }

    // `(*p)[i]` where `p`'s pointee is itself a static array (`T[N]*`, e.g.
    // `int[2]* p; (*p)[i]`): indexing steps through the array's own element
    // `T` at `p + i * sizeof(T)`, not through the whole `T[N]` block
    // `pointerElementMetadata` reports for a plain dereference or whole-object
    // assignment. Falls back to
    // `pointerElementMetadata` itself when `p`'s pointee is not a static
    // array (an ordinary `p[i]`/`(*pp)[i]` shape, unaffected by the
    // one-level unwrap this static-array case needs).
    private TypeFacts dereferencedArrayIndexElementMetadata(
        Type pointerType,
    ) {
        import dmd.astenums: TY;

        auto pointee = pointerType.toBasetype.nextOf;
        if (pointee is null || pointee.toBasetype.ty != TY.Tsarray)
            return pointerElementMetadata(pointerType);

        auto element = pointee.toBasetype.nextOf;
        return typeFacts(element);
    }

    // Shared opcode, aggregate, and byte-width classification for a stored
    // type. `pointerElementMetadata`, dynamic-array element sizing, and heap
    // field operations previously derived these facts independently, so a
    // missed case here would otherwise have to be kept in sync by hand across
    // all of them. A static-array, struct, dynamic-array, or delegate
    // element is always an aggregate/opaque region (`void_` opcode type, full
    // byte width) regardless of its own nested element type --
    // unwrapping one level here previously made a static-array pointee
    // (`int[3]*`) fall through to `scalarType(int)`, so
    // `storeThroughPointer`/`loadThroughPointer` read or wrote
    // only the first 4 bytes of a 12-byte static array through such a pointer
    // instead of the whole object. Anything else is a plain scalar read
    // through `scalarType`.
    private TypeFacts typeFacts(Type type) {
        import dmd.astenums: TY;
        import dmd.typesem: size;

        if (type.toBasetype.ty == TY.Terror)
            return TypeFacts.withoutByteWidth(
                ScalarType.void_, DeclarationRepresentation.unavailable,
                true,
            );
        const byteWidth = cast(uint) size(type.toBasetype);
        if (isComplexDoubleType(type))
            return TypeFacts(
                ScalarType.void_, byteWidth,
                DeclarationRepresentation.complexDouble, true,
            );
        switch (type.toBasetype.ty) with (TY) {
            case Tsarray:
                return TypeFacts(
                    ScalarType.void_, byteWidth,
                    DeclarationRepresentation.staticArray, true,
                );
            case Tvector:
                return TypeFacts(
                    ScalarType.void_, byteWidth,
                    DeclarationRepresentation.vector, true,
                );
            case Tarray:
                return TypeFacts(
                    ScalarType.void_, byteWidth,
                    DeclarationRepresentation.dynamicArray, true,
                );
            case Tstruct:
                return TypeFacts(
                    ScalarType.void_, byteWidth,
                    DeclarationRepresentation.struct_, true,
                );
            case Tdelegate:
                return TypeFacts(
                    ScalarType.void_, byteWidth,
                    DeclarationRepresentation.delegate_, true,
                );
            case Tclass:
                return TypeFacts(
                    scalarType(type), byteWidth,
                    DeclarationRepresentation.classPointer, false,
                );
            case Tpointer:
                return TypeFacts(
                    scalarType(type), byteWidth,
                    DeclarationRepresentation.pointer, false,
                );
            case Taarray:
                return TypeFacts(
                    scalarType(type), byteWidth,
                    DeclarationRepresentation.assocArray, false,
                );
            default:
                return TypeFacts(
                    scalarType(type), byteWidth,
                    DeclarationRepresentation.scalar, false,
                );
        }
    }

    private DeclarationRecord* declarationRecordView(
        VarDeclaration declaration,
    ) {
        auto record = declaration in _declarations;
        if (record is null)
            return &_unavailableDeclaration;
        if (record.storage != DeclarationStorage.module_ &&
            record.owner !is _currentFunction)
            return &_unavailableDeclaration;
        return record;
    }

    private DeclarationRecord* declarationClassification(
        VarDeclaration declaration,
    ) {
        if (auto record = declaration in _declarations)
            return record;
        return &_unavailableDeclaration;
    }

    private DeclarationRecord* registerFrameDeclaration(
        VarDeclaration declaration,
    ) {
        auto record = declarationRecord(declaration);
        record.storage = DeclarationStorage.frame;
        record.owner = _currentFunction;
        return record;
    }

    private DeclarationRecord* registerReferenceDeclaration(
        VarDeclaration declaration,
    ) {
        auto record = declarationRecord(declaration);
        record.storage = DeclarationStorage.frameReference;
        record.owner = _currentFunction;
        return record;
    }

    private DeclarationRecord* registerModuleDeclaration(
        VarDeclaration declaration,
    ) {
        auto record = declarationRecord(declaration);
        record.storage = DeclarationStorage.module_;
        record.owner = null;
        return record;
    }

    private DeclarationRecord* declarationRecord(VarDeclaration declaration) {
        if (auto existing = declaration in _declarations)
            return existing;
        DeclarationRecord created;
        created.facts = typeFacts(declaration.type);
        created.facts.representation = parameterIsLazy(declaration)
            ? DeclarationRepresentation.lazyDelegate
            : created.facts.representation;
        if (created.facts.representation == DeclarationRepresentation.pointer)
            created.pointer = pointerElementScalar(declaration.type);
        else if (created.facts.representation ==
            DeclarationRepresentation.classPointer)
            created.classPointer = declaration.type.toBasetype.isTypeClass.sym;
        created.complexDouble = created.facts.representation ==
            DeclarationRepresentation.complexDouble;
        created.assocArray = created.facts.representation ==
            DeclarationRepresentation.assocArray;
        _declarations[declaration] = created;
        return declaration in _declarations;
    }

    private void clearLocalDeclarations() {
        foreach (declaration; _declarations.keys)
            if (auto record = declaration in _declarations)
                if (record.owner is _currentFunction)
                    record.clearLocal;
    }
}

private struct ParameterLayout {
    ushort[] offsets;
    bool[] isReference;
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

private struct TypeFacts {
    private alias ScalarType =
        imported!"quickbite.backends.bytecode.core.program".ScalarType;

    private ScalarType opcodeType;
    private DeclarationRepresentation representation;
    private bool isAggregate;
    private uint _byteWidth;
    private bool _hasByteWidth;

    private this(
        in ScalarType opcodeType,
        in uint byteWidth,
        in DeclarationRepresentation representation,
        in bool isAggregate,
    ) @safe pure {
        this.opcodeType = opcodeType;
        this.representation = representation;
        this.isAggregate = isAggregate;
        _byteWidth = byteWidth;
        _hasByteWidth = true;
    }

    private static TypeFacts withoutByteWidth(
        in ScalarType opcodeType,
        in DeclarationRepresentation representation =
            DeclarationRepresentation.scalar,
        in bool isAggregate = false,
    ) @safe pure {
        TypeFacts result;
        result.opcodeType = opcodeType;
        result.representation = representation;
        result.isAggregate = isAggregate;
        return result;
    }

    // Low-level bytecode operations sometimes begin with an opcode scalar
    // rather than a D type. Keep their storage width under the same checked
    // authority; `void_` denotes an aggregate opcode and is never a width
    // sentinel.
    private static TypeFacts fromOpcode(in ScalarType opcodeType) @safe pure {
        import quickbite.backends.bytecode.core.program: size;

        assert(opcodeType != ScalarType.void_);
        return TypeFacts(
            opcodeType, cast(uint) size(opcodeType),
            DeclarationRepresentation.scalar, false,
        );
    }

    private uint byteWidth() @safe pure const {
        if (!_hasByteWidth)
            throw new Exception("Byte width is unavailable");
        return _byteWidth;
    }
}

private enum DeclarationRepresentation {
    unavailable,
    scalar,
    staticArray,
    vector,
    dynamicArray,
    pointer,
    struct_,
    delegate_,
    complexDouble,
    lazyDelegate,
    classPointer,
    assocArray,
}

private enum DeclarationStorage {
    unavailable,
    frame,
    frameReference,
    module_,
}

private struct DeclarationRecord {
    private imported!"dmd.func".FuncDeclaration owner;
    private TypeFacts facts;
    private ushort scalar;
    private ushort staticArray;
    private DynamicArrayLocal dynamicArray;
    private imported!"quickbite.backends.bytecode.core.program".ScalarType pointer;
    private StructLocal struct_;
    private DelegateLocal delegate_;
    private bool delegateRuntime;
    private imported!"quickbite.backends.bytecode.core.program".ScalarType
        refPointer;
    private bool complexDouble;
    private bool assocArray;
    private ushort lazyDelegate;
    private bool lazyDeclaration;
    private ushort delegateParameter;
    private imported!"dmd.dstruct".StructDeclaration structPointer;
    private imported!"dmd.dclass".ClassDeclaration classPointer;
    private ModuleScalarVariable moduleScalar;
    private ModuleDynamicArrayVariable moduleDynamicArray;
    private ModuleStructVariable moduleStruct;
    private ModuleStaticArrayVariable moduleStaticArray;
    private ModuleDelegateVariable moduleDelegate;
    private ModuleComplexVariable moduleComplex;
    private bool moduleClassificationAttempted;
    private DeclarationStorage storage;
    private bool represents(in DeclarationRepresentation expected) const {
        if ((storage == DeclarationStorage.frame ||
            storage == DeclarationStorage.frameReference) &&
            facts.representation == expected)
            return true;
        if ((storage == DeclarationStorage.frame ||
            storage == DeclarationStorage.frameReference) &&
            expected == DeclarationRepresentation.scalar)
            switch (facts.representation) with (DeclarationRepresentation) {
                case scalar:
                case pointer:
                case complexDouble:
                case classPointer:
                case assocArray:
                    return true;
                default:
                    return false;
            }
        return false;
    }

    private auto scalarOrNull() {
        return storage == DeclarationStorage.frameReference ||
            represents(DeclarationRepresentation.scalar)
            ? &scalar
            : null;
    }
    private auto staticArrayOrNull() {
        return storage == DeclarationStorage.frame &&
            (facts.representation == DeclarationRepresentation.staticArray ||
                facts.representation == DeclarationRepresentation.vector)
            ? &staticArray
            : null;
    }
    private auto dynamicArrayOrNull() {
        return storage == DeclarationStorage.frame &&
            facts.representation == DeclarationRepresentation.dynamicArray
            ? &dynamicArray
            : null;
    }
    private auto pointerOrNull() { return represents(DeclarationRepresentation.pointer) ? &pointer : null; }
    private auto struct_OrNull() {
        return storage == DeclarationStorage.frame &&
            facts.representation == DeclarationRepresentation.struct_
            ? &struct_
            : null;
    }
    private auto delegate_OrNull() {
        return storage == DeclarationStorage.frame &&
            facts.representation == DeclarationRepresentation.delegate_ &&
            !delegateRuntime && delegate_.function_ !is null
            ? &delegate_
            : null;
    }
    private auto refPointerOrNull() {
        return storage == DeclarationStorage.frameReference
            ? &refPointer
            : null;
    }
    private auto complexDoubleOrNull() {
        return storage == DeclarationStorage.frame &&
            facts.representation == DeclarationRepresentation.complexDouble
            ? &complexDouble
            : null;
    }
    private auto assocArrayOrNull() {
        return (storage == DeclarationStorage.frame ||
            storage == DeclarationStorage.frameReference) &&
            facts.representation == DeclarationRepresentation.assocArray
            ? &assocArray
            : null;
    }
    private auto lazyDelegateOrNull() {
        return storage == DeclarationStorage.frame &&
            facts.representation == DeclarationRepresentation.lazyDelegate
            ? &lazyDelegate
            : null;
    }
    private auto lazyDeclarationOrNull() {
        return facts.representation == DeclarationRepresentation.lazyDelegate
            ? &lazyDeclaration : null;
    }
    private auto delegateParameterOrNull() {
        return storage == DeclarationStorage.frame &&
            facts.representation == DeclarationRepresentation.delegate_ &&
            delegateRuntime
            ? &delegateParameter
            : null;
    }
    private auto structPointerOrNull() {
        return storage == DeclarationStorage.frame &&
            facts.representation == DeclarationRepresentation.pointer &&
            structPointer !is null ? &structPointer : null;
    }
    private auto classPointerOrNull() { return represents(DeclarationRepresentation.classPointer) ? &classPointer : null; }
    private auto moduleScalarOrNull() {
        return storage == DeclarationStorage.module_ &&
            (facts.representation == DeclarationRepresentation.scalar ||
            facts.representation == DeclarationRepresentation.pointer ||
            facts.representation == DeclarationRepresentation.classPointer ||
            facts.representation == DeclarationRepresentation.assocArray)
            ? &moduleScalar
            : null;
    }
    private auto moduleDynamicArrayOrNull() {
        return storage == DeclarationStorage.module_ &&
            facts.representation == DeclarationRepresentation.dynamicArray
            ? &moduleDynamicArray
            : null;
    }
    private auto moduleStructOrNull() {
        return storage == DeclarationStorage.module_ &&
            facts.representation == DeclarationRepresentation.struct_
            ? &moduleStruct
            : null;
    }
    private auto moduleStaticArrayOrNull() {
        return storage == DeclarationStorage.module_ &&
            (facts.representation == DeclarationRepresentation.staticArray ||
                facts.representation == DeclarationRepresentation.vector)
            ? &moduleStaticArray
            : null;
    }
    private auto moduleDelegateOrNull() {
        return storage == DeclarationStorage.module_ &&
            facts.representation == DeclarationRepresentation.delegate_
            ? &moduleDelegate
            : null;
    }
    private auto moduleComplexOrNull() {
        return storage == DeclarationStorage.module_ &&
            facts.representation == DeclarationRepresentation.complexDouble
            ? &moduleComplex
            : null;
    }

    private void clearLocal() {
        owner = null;
        if (storage == DeclarationStorage.frame ||
            storage == DeclarationStorage.frameReference)
            storage = DeclarationStorage.unavailable;
    }
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
    bool isStaticArrayView;
    ushort staticArrayOffset;
    // When set, `staticArrayOffset` is not a frame-relative array offset
    // (resolved via `Op.frameAddress`) but a frame slot already holding a
    // real runtime pointer resolved by the field place, because the
    // underlying static array is a class field living
    // in the class's own heap block rather than inline in this frame.
    bool staticArrayViewIsClassField;
}

// A delegate local (`auto d = () => this.field;`): a 16-byte slot holding a
// `{functionIndex, context}` pair. `offset` is that slot; `function_` is the
// captured lambda, giving the callee's layout and result type when `d()` is
// compiled. The context word is the enclosing method's `this` receiver address.
private struct DelegateLocal {
    ushort offset;
    imported!"dmd.func".FuncDeclaration function_;
}

private struct LazyDelegateSource {
    ushort offset;
    bool isCaptured;
    // The function owning `offset`'s frame; only meaningful when `isCaptured`.
    imported!"dmd.func".FuncDeclaration owner;
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
    // Set for a `Tpointer`-typed module variable: `type` is always
    // `ScalarType.ulong_` (the pointer's own native-word storage), but a
    // read still needs to carry the pointed-at element's scalar type so
    // `*p`/`p[i]` recognise the loaded value as a pointer at all, just as a
    // local or parameter pointer's declaration record does.
    bool isPointer;
    imported!"quickbite.backends.bytecode.core.program".ScalarType pointerElement;
}

// A module-level (`__gshared`/`static`) dynamic-array variable's own 16-byte
// native-order slice descriptor storage in `_program.moduleData`, the array
// counterpart of `ModuleScalarVariable`.
private struct ModuleDynamicArrayVariable {
    ushort offset;
    imported!"quickbite.backends.bytecode.core.program".ScalarType elementType;
    bool elementIsArray;
}

// A module-level (`__gshared`/`static`) delegate variable's own 16-byte
// native-order `{functionIndex, context}` pair storage in
// `_program.moduleData`. Unlike `ModuleScalarVariable` (an 8-byte value with
// a real `ScalarType`, the shape a module pointer/associative-array
// variable reuses), a delegate has no `ScalarType` of its own -- the same
// reason a delegate local/field/array-element carries its own dedicated
// tracking rather than going through the generic scalar machinery -- so it
// gets its own record here, the delegate counterpart of
// `ModuleDynamicArrayVariable`.
private struct ModuleDelegateVariable {
    ushort offset;
}

// A module-level (`__gshared`/`static`) `cdouble` variable's own 16-byte
// native-order `{re, im}` pair storage in `_program.moduleData`. Like a
// delegate, a `cdouble` has no `ScalarType` of its own (`scalarType` has no
// `Tcomplex64` case, and `isComplex` is carried as a separate `Operand` flag
// rather than folded into `ScalarType`) -- the same reason a `cdouble` LOCAL
// uses a dedicated declaration representation rather than going through the
// generic scalar machinery, so it gets its own record here, the complex
// counterpart of `ModuleDelegateVariable`.
private struct ModuleComplexVariable {
    ushort offset;
}

// A `Tarray` class field's array-literal default, shared by every `new C()`
// site that does not override the field: `pointer` addresses its own
// `literalBlocks` entry (a GC-rooted block that never moves), `count` is its
// element count. See `classFieldArraySharedDefaultOrNull`.
private struct ClassFieldArrayDefault {
    size_t pointer;
    size_t count;
}

// A module-level (`__gshared`/`static`) struct variable's own inline block
// storage in `_program.moduleData`, the struct counterpart of
// `ModuleScalarVariable`.
private struct ModuleStructVariable {
    ushort offset;
    ushort size;
}

// A module-level (`__gshared`/`static`) fixed-size static-array variable's
// own inline block storage in `_program.moduleData`, the Tsarray counterpart
// of `ModuleStructVariable`.
private struct ModuleStaticArrayVariable {
    ushort offset;
    ushort size;
}

private struct ExceptionStringField {
    ushort offset;
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

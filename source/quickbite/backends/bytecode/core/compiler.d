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
        CatchClause, ClassInfo, CompiledFunction,
        Instruction, NativeCall, Op, Program,
        ResultType, ScalarType, StructDisplayField,
        VirtualFunction,
        indexLoadOp, indexStoreOp, isSigned,
        nativeArgumentSlotSize, noCatchObjectField, noExceptionClass,
        noNativeCallIndex,
        noReceiverOffset, pointerLoadOp, pointerSliceOp, pointerStoreOp,
        size, sliceCopyOp, sliceDescriptorLengthOffset,
        sliceDescriptorPtrOffset, sliceDescriptorSize,
        sliceEqualOp, sliceFillOp, subSliceOp;
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AddAssignExp, AddrExp, ArrayLengthExp, ArrayLiteralExp,
        AssocArrayLiteralExp, AssertExp,
        AssignExp, BinAssignExp, BinExp, BlitExp, CallExp, CastExp,
        CatAssignExp, CatDcharAssignExp,
        CatElemAssignExp, CatExp,
        CmpExp, CondExp, ConstructExp, DelegateFuncptrExp, DelegatePtrExp,
        DivExp, DotIdExp, DotVarExp, EqualExp, Expression,
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
    private size_t[Type] _nativeStructTypeInfos;
    // `TypeInfo_StaticArray`/`TypeInfo_Array`/`TypeInfo_Delegate` instances
    // this backend emitted for a composite type dmd has no host-linked
    // symbol for; see `nativeStaticArrayTypeInfo`/`nativeArrayTypeInfo`/
    // `nativeDelegateTypeInfo`. A single map suffices because a `Type` is
    // a static array, dynamic array, or delegate exclusively, never more
    // than one.
    private size_t[Type] _nativeCompositeTypeInfos;
    // `_d_arrayappendcd`/`_d_arrayappendwd`, keyed by mangled symbol name;
    // see `nativeDcharAppendFunction`.
    private FuncDeclaration[string] _nativeDcharAppendFunctions;
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
    // Named catch variables for the narrow Exception/Throwable object surface:
    // each synthetic object exposes native {length, ptr} string descriptors
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
        ScalarType sliceElementType;
        uint sliceElementSize;
        bool sliceElementIsArray;
        bool isStaticSlice;
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
        _program.functions[index].parameterBytes = layout.blockSize;
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

                if (parameter.isReference &&
                    declarationRecord(parameter).facts.representation ==
                        DeclarationRepresentation.delegate_)
                {
                    auto record = registerReferenceDeclaration(parameter);
                    record.scalar = offset;
                    record.refPointer = ScalarType.void_;
                    continue;
                }

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

    // Registers `function_` in `Program.functions` and returns its index --
    // the guest function-pointer value for `&function_`, uniform whether
    // `function_` is VM-compiled or a native leaf. A native leaf (`fbody is
    // null`; reached this way when its address is taken and later called
    // indirectly, e.g. `core.internal.dassert`'s `assumeFakeAttributes`
    // closing over a druntime hook like `GC.inFinalizer`) has no VM bytecode
    // to lazily compile: its entry's `code` stays empty forever, and
    // `nativeCallIndex` names a matching `Program.nativeCalls` entry that
    // `Op.call`/`Op.callIndirect` dispatch through instead. That entry's
    // `argumentOffsets` are this same call's own `ParameterLayout.offsets`
    // -- the dense VM typed-frame layout a caller lays its argument bytes
    // out in, whether or not the callee turns out to be native -- so
    // `prepareNativeInvocation` reads each argument from where it actually
    // is instead of assuming the uniform stride a direct native call's own
    // argument area uses.
    private ushort registerFunction(FuncDeclaration function_) {
        import quickbite.backends.bytecode.core.program: markScanned;
        import quickbite.frontend.dmd.functions: ensureFunctionBodySemantic;

        ensureFunctionBodySemantic(function_);

        if (auto existing = function_ in _functionIndices)
            return cast(ushort) *existing;

        if (_program is null)
        {
            _program = new Program;
            // A running machine executes this segment directly while lazy
            // compilation can append module slots. Reserve every representable
            // byte now so such appends cannot relocate raw module addresses.
            _program.moduleData.reserve(ushort.max);
            // Module-level variables can hold guest pointer values (slice,
            // class, or struct addresses); scan this segment like compiled D
            // scans its own data segment's pointer fields. Marked after
            // `reserve`, the only operation that can move this block.
            markScanned(_program.moduleData);
        }

        const index = _functions.length;
        _functions ~= function_;
        _functionIndices[function_] = index;
        const layout = parameterLayout(function_);
        const nativeCallIndex = function_.fbody is null
            ? registerNativeCallTarget(function_, layout)
            : noNativeCallIndex;
        _program.functions ~= CompiledFunction(
            null,
            0,
            layout.blockSize,
            functionResultType(function_),
            layout.hasThis,
            nativeCallIndex,
        );
        return cast(ushort) index;
    }

    // Registers a native leaf's `Program.nativeCalls` entry for indirect
    // dispatch: the same table `Op.nativeCall` already keys a direct call's
    // callee by, so `Op.callIndirect`'s native-target branch reuses
    // `callNative` verbatim rather than a parallel FFI path.
    private size_t registerNativeCallTarget(
        FuncDeclaration function_,
        in ParameterLayout layout,
    ) {
        auto parameters =
            function_.type.toBasetype.isTypeFunction.parameterList.parameters;
        auto argumentTypes = new Type[parameters is null ? 0 : parameters.length];
        if (parameters !is null)
            foreach (i, parameter; *parameters)
                argumentTypes[i] = cast(Type) parameter.type;

        const nativeIndex = _program.nativeCalls.length;
        _program.nativeCalls ~= NativeCall(
            function_,
            argumentTypes,
            noReceiverOffset,
            null,
            noReceiverOffset,
            null,
            layout.offsets.dup,
            layout.isReference.dup,
        );
        return nativeIndex;
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

    // `if (__ctfe) { ctfeOnlyCode } else { runtimeCode }` (and DMD's
    // semantic rewrite of `if (!__ctfe) runtimeCode else ctfeOnlyCode` into
    // that same shape, statementsem.d): DMD's own semantic marks the
    // `__ctfe` branch's scope `ctfeBlock` and, on that basis, skips setting
    // lowerings such as `~=`'s `_d_arrayappendcTX` call inside it (`arr ~=
    // e` inside `std.array.array`'s `if (__ctfe)` branch stays an
    // unlowered `CatElemAssignExp`) -- DMD assumes a compiled, non-CTFE
    // backend never executes that branch and so never needs it lowered.
    // The bytecode core is such a backend: `__ctfe` always compiles to the
    // constant `false` (the `VarExp` case above), so the `if (__ctfe)`
    // branch is provably dead at bytecode-VM runtime. Skip compiling it
    // instead of emitting a runtime branch over it, the same dead-code
    // elimination every compiled backend applies to this idiom; compiling
    // it would walk into druntime/Phobos statements DMD deliberately left
    // unlowered for exactly this reason.
    private void compileIfStatement(imported!"dmd.statement".IfStatement if_) {
        if (if_.isIfCtfeBlock) {
            if (if_.elsebody !is null)
                compileNestedStatement(if_.elsebody);
            return;
        }

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
            allocateBytes(totalSize, typeFacts(source.type).alignment);

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
        _program.classes[index].name = classInfoName(class_);
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
        // DMD lowers a `string` switch to a call of
        // `object.__switch!(C, caseStrings...)`, whose real D body (binary
        // search over the case strings) returns the matched case's table
        // index (or -1), and rewrites its cases to those integer indices.
        // Compiling that call like any other expression call gives the same
        // integer result compiled code gets from dmd's glue, so the dispatch
        // below needs no separate handling for a string condition.
        const selector = compileExpression(switch_.condition);

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

            // A declaration's cached `DeclarationRecord` (`.scalar`,
            // `.refPointer`, ...) carries a frame offset relative to
            // whichever function's `compileFunctionBody` call first
            // registered it. Reading it here without checking ownership
            // would misread an enclosing function's parameter slot as one
            // in the CURRENT function's own (unrelated, much smaller) frame
            // whenever a nested lambda captures it -- e.g. a lambda
            // forwarding an enclosing `auto ref` parameter into another
            // call. Route a genuinely captured declaration through
            // `placeOrNull`, which already resolves the enclosing frame
            // correctly (`Place.Kind.captured`/`Place.Kind.pointer`),
            // instead of trusting the stale cached offset directly.
            if (_hasNestedContext)
                if (auto declaration = variable.var.isVarDeclaration)
                    if (declaration in _capturedOffsets &&
                        _capturedOwners[declaration] !is _currentFunction)
                        if (auto place = placeOrNull(expression))
                            return loadPlaceValue(*place);

            if (auto declaration = variable.var.isVarDeclaration)
                if (auto existing = declarationRecordView(declaration).scalarOrNull) {
                    if (declarationRecordView(declaration).structPointerOrNull)
                        return Operand(
                            *existing,
                            ScalarType.ulong_,
                            true,
                            ScalarType.void_,
                        );
                    if (auto element = declarationRecordView(declaration).refPointerOrNull) {
                        const loaded = loadThroughPointer(
                            Operand(
                                *existing,
                                ScalarType.ulong_,
                                true,
                                *element,
                            ),
                            compileSizeConstant(0),
                        );
                        // A `ref` parameter to a class-typed value: the frame
                        // slot holds the address of the caller's class
                        // reference, so `loadThroughPointer` reads the
                        // reference itself. Mark it a pointer, matching the
                        // representation a by-value class parameter gets
                        // below, so field access through it dereferences the
                        // object rather than treating the reference bits as
                        // an opaque scalar.
                        if (declarationRecordView(declaration).classPointerOrNull)
                            return Operand(
                                loaded.offset,
                                ScalarType.ulong_,
                                true,
                                ScalarType.void_,
                            );
                        // A `ref` parameter whose own static type is a
                        // pointer (`ref T val` with `T` a pointer type, e.g.
                        // a generic `ref T` bound to `int*`): the value just
                        // loaded through the frame slot's address IS that
                        // pointer, so a further dereference (`*val`) must see
                        // an operand carrying pointer semantics, not a bare
                        // scalar.
                        return asPointerValue(loaded, declaration.type);
                    }
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
            if (expression.type !is null && typeFacts(expression.type).isAggregate)
                if (auto place = placeOrNull(expression))
                    return loadPlaceValue(*place);
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
            if (auto variable = declaration.declaration.isVarDeclaration) {
                compileVariableDeclaration(variable);
                return Operand.init;
            }

            // A nested type declaration (`struct Inner { ... }` inside a
            // function body) is a compile-time construct that emits no runtime
            // code; semantic has already resolved it.
            if (declaration.declaration.isAggregateDeclaration !is null)
                return Operand.init;
            // A local enum *type* (`enum Foo : ubyte { ... }` inside a
            // function body) is compile-time-only in the same way: it has no
            // runtime storage of its own, only its members' constant values,
            // which are resolved wherever they are referenced.
            if (declaration.declaration.isEnumDeclaration !is null)
                return Operand.init;
            if (auto storage =
                    declaration.declaration.isStorageClassDeclaration)
                if (storage.decl !is null && storage.decl.length == 1)
                    if ((*storage.decl)[0].isTemplateDeclaration !is null ||
                        (*storage.decl)[0].isAggregateDeclaration !is null)
                        // Storage classes on template and aggregate
                        // definitions have no runtime effect. DMD emits the
                        // template wrapper for helpers instantiated by nested
                        // array equality.
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
        // aborts before this is read. An array-typed `null` (e.g. a ternary
        // arm retyped to the ternary's own array type, `cond ? null : arr`)
        // is a genuine {length, ptr} descriptor that IS read, so it gets a
        // full 16-byte zeroed slot via `Op.nullSlice` instead -- a single
        // 8-byte word covers only the descriptor's length, leaving whatever
        // a consumer widens it to read the frame bytes just past this
        // allocation as the pointer word.
        if (expression.isNullExp !is null) {
            import dmd.astenums: TY;

            if (expression.type !is null &&
                expression.type.toBasetype.ty == TY.Tarray) {
                const offset = allocateBytes(
                    sliceDescriptorSize, size_t.sizeof,
                );
                _code ~= Instruction(Op.nullSlice, offset);
                return Operand(offset, ScalarType.void_);
            }

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
                Op.bitXorInt8,
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
        // distinct CatAssignExp (`concatenateAssign`). Both carry a frontend
        // lowering to `_d_arrayappendcTX`/`_d_arrayappendT`; compile that
        // instead of hand-rolled append machinery. `CatDcharAssignExp`
        // (`concatenateDcharAssign`) is a distinct EXP tag excluded by these
        // checks; see `compileDcharAppend` for why it stays un-lowered.
        if (auto append = expression.isCatElemAssignExp) {
            if (append.lowering is null)
                throw new Exception(text(
                    "Unsupported append in bytecode core: ",
                    expressionChars(append),
                ));
            return compileExpression(append.lowering);
        }

        if (auto concatenate = expression.isCatAssignExp) {
            if (concatenate.lowering is null)
                throw new Exception(text(
                    "Unsupported concatenation assignment in bytecode core: ",
                    expressionChars(concatenate),
                ));
            return compileExpression(concatenate.lowering);
        }

        if (auto dcharAppend = expression.isCatDcharAssignExp)
            return compileDcharAppend(dcharAppend);

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
            auto functionType = callTypeFunction(call);
            const result = compileCall(call);
            if (result.isPointer &&
                functionType !is null && functionType.isRef &&
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

        if (auto literal = expression.isAssocArrayLiteralExp)
            return compileExpression(literal.lowering);

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
    // the old value to the result slot, then add `e2` (the increment) and
    // store it back. Scoped to integer lvalues, matching compound
    // assignment. A sub-`int`-width lvalue (e.g. `core.internal.string`'s
    // `TempStringNoAlloc._len++`, a `ubyte` field) is not itself a safe
    // destination for the `addInt4`/`subInt4` opcodes -- those read and
    // write a full 4 bytes, which would overrun a 1- or 2-byte frame slot --
    // so the arithmetic runs on a freshly widened operand (the same
    // sign-driven `int_`/`uint_` promotion `compileTruthValue` uses) and
    // `storePlace` narrows the result back on the way in, exactly as
    // `compileScalarIntegerCompoundAssign` already does for `+=` and its
    // siblings.
    private Operand compilePostIncrement(PostExp post) {
        import dmd.tokens: EXP;
        import std.conv: text;

        auto place = placeOrNull(post.e1);
        if (place is null || !isCompoundIntegerScalar(place.type))
            throw new Exception(text(
                "Unsupported post-increment in bytecode core: ",
                expressionChars(post),
            ));

        const original = loadPlace(*place);
        const result = allocate(place.type);
        _code ~= Instruction(
            Op.copy, result, original.offset, cast(ushort) size(place.type),
        );

        const operationType = size(place.type) < int.sizeof
            ? (isSigned(place.type) ? ScalarType.int_ : ScalarType.uint_)
            : place.type;
        const lhs = integerOperationOperand(original, operationType);

        // `PostExp.e2` is always the literal `1`; `post.op` (`plusPlus` vs
        // `minusMinus`) decides whether we add or subtract it. Unlike `lhs`
        // above, it is read at its own narrow width rather than widened to
        // `operationType`: `addInt4`/`subInt4`/`addInt8`/`subInt8` read a
        // full-width operand, but any bytes above the narrow slot cannot
        // affect `storePlace`'s truncating write-back below, since
        // two's-complement add/sub mod 2^(8*width) depends only on the
        // operands mod 2^(8*width). The pre-increment value this function
        // returns is `result`, copied from `original` before this
        // arithmetic runs, so it is unaffected either way.
        const increment = compileExpression(post.e2);
        const eightByte = isEightByteInteger(operationType);
        const stepOp = post.op == EXP.minusMinus
            ? (eightByte ? Op.subInt8 : Op.subInt4)
            : (eightByte ? Op.addInt8 : Op.addInt4);
        const destination = allocate(operationType);
        _code ~= Instruction(
            stepOp, destination, lhs.offset, increment.offset,
        );
        storePlace(*place, Operand(destination, operationType));

        // `p++`/`p--` on a pointer local: DMD's own semantic already scales
        // `post.e2` by the pointee's byte width (`dcast.d`'s `scaleFactor`,
        // the same rewrite `AddExp`/`AddAssignExp` use for `p + n`/`p += n`),
        // so `increment` above is already the right byte delta -- but the
        // pre-increment VALUE this returns (`arr[i++]`'s old `i`, or here
        // `_d_arraycatnTX`'s `memcpy(resptr++, ...)`) must keep carrying the
        // pointer tag and element type a plain integer Operand drops,
        // matching `compileScalarIntegerCompoundAssign`'s identical pointer
        // branch for `p += n`.
        if (place.isPointerValue)
            return Operand(
                result, place.type, true, place.pointerElement,
            );
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
            if (!conditional.isLvalue)
                return null;
            // A resolver that can decline must look side-effect-free to its
            // caller: the caller's fallback recompiles `expression` from
            // scratch as an rvalue on a decline, and that fallback's own
            // ternary codegen is a real, working, independent path (it does
            // not require both arms to have a Place -- a string-literal arm
            // is a perfectly good rvalue). So a decline here rewinds `_code`
            // to its pre-emission length rather than leaving the condition
            // eval and an unpatched jump as live, permanent instructions in
            // the compiled function for the fallback to land on top of.
            const savedCodeLength = _code.length;
            const condition = compileBoolCondition(conditional.econd);
            const pointer = allocateBytes(
                cast(uint) size_t.sizeof, size_t.sizeof,
            );
            const falseJump = emitJumpIfFalse(condition);
            auto whenTrue = placeOrNull(conditional.e1);
            if (whenTrue is null) {
                _code.length = savedCodeLength;
                return null;
            }
            const whenTrueAddress = addressOfPlace(*whenTrue);
            _code ~= Instruction(
                Op.copy, pointer, whenTrueAddress.offset,
                cast(ushort) size_t.sizeof,
            );
            const endJump = emitJump;
            patchJump(falseJump);
            auto whenFalse = placeOrNull(conditional.e2);
            if (whenFalse is null) {
                _code.length = savedCodeLength;
                return null;
            }
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
            // `(){ return S(args); }()`: `compileCall` itself inlines this
            // shape (`immediateLambdaReturn`) by compiling `S(args)` in
            // place of the whole call, so look through the same wrapper
            // here before testing for a constructor call below -- otherwise
            // `callFunction(call)` sees the IIFE, not the constructor, and
            // this falls back to the receiver-unaware `isAggregate` branch
            // further down, which never gives the constructor a real
            // receiver to initialise (issue #509).
            if (auto inlined = immediateLambdaReturn(call))
                return placeOrNull(inlined);

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
                    if (auto offset = declaration in _capturedOffsets) {
                        if (_hasNestedContext &&
                            _capturedOwners[declaration] !is _currentFunction)
                        {
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
                            return pointerPlace(pointer, expression.type);
                        }
                        return new Place(
                            Place.Kind.pointer, expression.type,
                            *offset, compileSizeConstant(0),
                            isDelegateValueType(expression.type),
                            null,
                            isDelegateValueType(expression.type),
                        );
                    }
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
                // A `Tsarray` element (`int[2][]`'s `int[2]` rows) is the
                // real D layout: stored inline, `T[N].sizeof`-strided, in
                // the array's own backing store, so its address is the
                // same base-plus-scaled-index computation `dynamicIndexPlace`
                // already gives any other full-width aggregate element (a
                // struct, say) -- no separate row descriptor to dereference.
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

            // The element metadata below is derived from `slice.e1`'s own
            // TYPE, not from compiling it: `compileSliceInto` below is the
            // one and only place this Place compiles `slice.e1` (via its
            // own `dynamicArrayDescriptor` call). A second, separate
            // `dynamicArrayDescriptor(slice.e1)` call here -- to read the
            // same type-derived metadata off its returned
            // `DynamicArrayLocal` -- would compile (and so evaluate)
            // `slice.e1` a second time, silently double-running any side
            // effect it carries (e.g. `"...".idup[lo .. hi]`, an
            // allocating call).
            const pointerSlice = isPointerType(slice.e1.type);
            result.sliceElementType = pointerSlice
                ? dynamicArrayElementType(slice.type)
                : dynamicArrayElementType(slice.e1.type);
            result.sliceElementIsArray = arrayElementIsArray(slice.e1.type);
            result.sliceElementSize = dynamicArrayElementSize(slice.e1.type);
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
                    ? allocateBytes(width, typeFacts(place.valueType).alignment)
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
                    ? allocateBytes(width, typeFacts(place.valueType).alignment)
                    : allocate(place.type);
                _code ~= Instruction(
                    Op.loadModule, result, place.offset,
                    cast(ushort) width,
                );
                return Operand(result, operandType);
            case pointer:
                if (aggregate) {
                    const result = allocateBytes(
                        width, typeFacts(place.valueType).alignment,
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
                    ? allocateBytes(width, typeFacts(place.valueType).alignment)
                    : allocate(place.type);
                emitIndexLoad(
                    result, place.offset, place.indexOffset, width,
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
                // `loadPlace`'s dynamicIndex case bounds-checks through
                // `emitIndexLoad`'s opcode; an address consumer bypasses that
                // opcode entirely; so check explicitly here, before the raw
                // pointer arithmetic below loses the descriptor's length.
                const lengthSlot = allocate(ScalarType.ulong_);
                _code ~= Instruction(
                    Op.sliceLength, lengthSlot, place.offset,
                );
                _code ~= Instruction(
                    Op.checkStaticArrayIndex, place.indexOffset, lengthSlot,
                );

                const pointer = allocateBytes(
                    cast(uint) size_t.sizeof, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.copy, pointer,
                    cast(ushort) sliceDescriptorPtrOffset(place.offset),
                    cast(ushort) size_t.sizeof,
                );
                return pointerPlaceAddress(
                    pointer, place.indexOffset, width, operandType,
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
        return type !is null &&
            typeFacts(type).representation ==
                DeclarationRepresentation.delegate_;
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
        return typeFacts(place.valueType).representation ==
            DeclarationRepresentation.complexDouble
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
        import std.conv: text;

        const facts = typeFacts(type);

        // DMD exposes `vector.array` as a struct-typed view over the vector's
        // inline bytes. Its value emitter already returns that backing block;
        // it needs no struct reconstruction.
        if (rhs.isVectorArrayExp !is null)
            if (auto place = placeOrNull(rhs))
                return loadPlace(*place).offset;
        const rhsFacts = typeFacts(rhs.type);
        if (rhsFacts.representation == DeclarationRepresentation.staticArray &&
            facts.representation != DeclarationRepresentation.staticArray &&
            facts.representation != DeclarationRepresentation.vector)
        {
            const result = allocateBytes(
                facts.byteWidth, facts.alignment,
            );
            if (compileStaticArrayValueInto(result, rhs.type, rhs))
                return result;
        }

        final switch (facts.representation) with (DeclarationRepresentation) {
            case struct_:
                if (auto integer = rhs.isIntegerExp)
                    if (integer.toInteger == 0) {
                        const result = allocateStructBlock(type);
                        zeroFrameBlock(result, facts.byteWidth);
                        return result;
                    }
                return structOperandOffset(rhs);
            case staticArray:
                const result = allocateBytes(
                    facts.byteWidth, facts.alignment,
                );
                if (!compileStaticArrayValueInto(result, type, rhs))
                    throw new Exception(text(
                        "Unsupported aggregate assignment in bytecode core: ",
                        expressionChars(rhs),
                    ));
                return result;
            case vector:
                if (auto place = placeOrNull(rhs))
                    return loadPlaceValue(*place).offset;
                return compileExpression(rhs).offset;
            case dynamicArray:
                const result = allocateBytes(
                    sliceDescriptorSize, size_t.sizeof,
                );
                compileDynamicArrayInto(
                    result, dynamicArrayElementType(type), rhs,
                    arrayElementIsDynamicArray(type),
                );
                return result;
            case delegate_:
                return heapEscapingDelegate
                    ? heapEscapingDelegateOperandOffset(rhs)
                    : delegateOperandOffset(rhs);
            case complexDouble:
                return compileComplexDoubleOperand(rhs).offset;
            case unavailable:
            case scalar:
            case pointer:
            case lazyDelegate:
            case classPointer:
            case assocArray:
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

        // `cast(T2[])x`: `placeOrNull` unwraps a cast transparently and
        // resolves the INNER expression's own place (e.g. `x` itself an
        // lvalue, or a pointer slice like `ptr[0 .. n]`), bypassing the
        // cast, so an element-size-changing reinterpretation (`void[]` from
        // `int[]`, the shape `gc_shrinkArrayUsed(ptr[0 .. n], ...)`'s
        // implicit argument conversion takes) needs its own rescale here --
        // the same one `compileCastExpression`/`compileDynamicArrayInto`
        // apply when no place is available. `cast_.e1` a `Tsarray` (`x[]`'s
        // desugaring, or `object.__equals`'s own `cast(T[])row` when a row
        // pulled from a mixed static/dynamic array-of-arrays comparison
        // needs a uniform element type) shares this path too: recursing
        // into this function's own `Tsarray` case below already builds a
        // real view over that static array's inline storage -- a `Tsarray`
        // has no slice descriptor of its own to reconcile.
        if (auto cast_ = expression.isCastExp)
            if (isDynamicArrayArgument(cast_.e1) ||
                isStringType(cast_.e1.type) ||
                cast_.e1.type.toBasetype.ty == TY.Tsarray) {
                const inner = dynamicArrayDescriptor(cast_.e1);
                const elementIsArray = arrayElementIsArray(expression.type);
                const elementType = dynamicArrayElementType(expression.type);
                const targetElementSize =
                    dynamicArrayElementSize(expression.type);
                const sourceElementSize =
                    dynamicArrayElementSize(cast_.e1.type);
                if (targetElementSize == sourceElementSize)
                    return DynamicArrayLocal(
                        inner.offset, elementType, elementIsArray,
                    );

                const offset = allocateBytes(
                    sliceDescriptorSize, size_t.sizeof,
                );
                _code ~= Instruction(
                    Op.copy, offset, inner.offset,
                    cast(ushort) sliceDescriptorSize,
                );
                rescaleReinterpretedSliceLength(
                    offset, expression.type, cast_.e1.type,
                );
                return DynamicArrayLocal(offset, elementType, elementIsArray);
            }

        const kind = expression.type.toBasetype.ty;
        if (kind == TY.Tsarray) {
            auto place = placeOrNull(expression);
            // An rvalue with no `Place` (a literal, or any other temporary
            // with no lvalue location) is materialised through the same
            // inline layout a variable's own storage has --
            // `aggregateOperandOffset`, the shared static-array value path
            // an lvalue's rows already share -- so the view built below
            // sees identical bytes either way, with no separate per-row
            // heap descriptors.
            const address = place is null
                ? *addressOperand(
                    Op.frameAddress,
                    aggregateOperandOffset(expression.type, expression),
                    ScalarType.void_,
                )
                : addressOfPlace(*place);
            const offset = allocateBytes(
                sliceDescriptorSize, size_t.sizeof,
            );
            _code ~= Instruction(
                Op.copy, cast(ushort) sliceDescriptorPtrOffset(offset),
                address.offset,
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
            offset, elementType, expression,
            arrayElementIsDynamicArray(expression.type),
        );
        return DynamicArrayLocal(offset, elementType, elementIsArray);
    }


    // Compile a string literal directly into an expanded native {length, ptr}
    // descriptor at a fresh frame slot.
    private ushort compileStringLiteralPointer(StringExp string_) {
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        emitLoadStringLiteral(offset, string_);
        return offset;
    }

    // Emit a string literal's bytes into a fresh literal block and an
    // `Op.loadStringLiteral` writing the expanded {length, ptr} descriptor
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
    // and emit its native {length, ptr} descriptor, returning the
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

    // Any type dmd can produce a TypeInfo for (builtins, and any aggregate
    // druntime or Phobos already instantiated) has that TypeInfo's real
    // object linked into the running host process at the same address
    // compiled D would read through `typeid`; resolve its symbol there
    // first. A guest-only type's TypeInfo is a backend-emitted artefact
    // that exists in no loaded image, so its symbol simply fails to
    // resolve -- that failure is itself the signal to synthesise one.
    //
    // `Type.vtinfo` only populates once dmd's own semantic pass processes
    // an actual source-level `typeid` naming that exact type. A basic
    // scalar element reached only through a composite's own field --
    // never itself a direct `typeid` operand -- can reach here with a
    // null `vtinfo` even though its real host symbol exists (dmd's own
    // codegen fills this gap in a later backend pass, `glue/todt.d`'s
    // `TypeInfo_toObjFile`, that this frontend-only project never runs).
    // Forcing `vtinfo` population by calling dmd's `genTypeInfo` directly
    // from here corrupts the host process's own GC heap (dmd `Scope`
    // pooling is not safe to drive mid-compilation this way), so resolve
    // a basic type's host TypeInfo the same way `hostBasicTypeInfoAddress`
    // does instead: a real `typeid` expression in this module's own host
    // D code, which links against the identical druntime the guest
    // program does, reaching the same singleton without touching dmd's
    // declaration machinery at all. A composite element (nested array,
    // struct, delegate) recurses back into this same two-source
    // resolution through its own dedicated synthesiser below.
    private size_t nativeTypeInfoAddress(Type type) {
        import quickbite.ffi.ffi: resolveDataSymbol;

        if (type is null)
            return 0;
        if (auto declaration = type.vtinfo)
            if (auto address = resolveDataSymbol(declaration))
                return cast(size_t) address;
        if (auto address = hostBasicTypeInfoAddress(type))
            return address;
        auto basetype = type.toBasetype;
        if (basetype.isTypeStruct !is null)
            return nativeStructTypeInfo(type);
        if (basetype.isTypeSArray !is null)
            return nativeStaticArrayTypeInfo(type);
        if (basetype.isTypeDArray !is null)
            return nativeArrayTypeInfo(type);
        if (basetype.isTypeDelegate !is null)
            return nativeDelegateTypeInfo(type);
        return 0;
    }

    // The real host druntime TypeInfo instance for a basic scalar type
    // (`bool`, the integrals, the character types, the floating-point
    // types): dmd's own `builtinTypeInfo` (`typinf.d`) recognises these as
    // needing no per-type codegen for the same reason -- the host
    // druntime library always carries a real symbol for them, regardless
    // of whether dmd's frontend ever created a `TypeInfoDeclaration` for
    // this particular `Type` object. A host-side `typeid` expression on
    // the matching built-in D type reaches that exact singleton.
    private size_t hostBasicTypeInfoAddress(Type type) {
        import dmd.astenums: TY;
        import object: TypeInfo;

        TypeInfo result;
        switch (type.toBasetype.ty) with (TY) {
            case Tbool: result = typeid(bool); break;
            case Tint8: result = typeid(byte); break;
            case Tuns8: result = typeid(ubyte); break;
            case Tint16: result = typeid(short); break;
            case Tuns16: result = typeid(ushort); break;
            case Tint32: result = typeid(int); break;
            case Tuns32: result = typeid(uint); break;
            case Tint64: result = typeid(long); break;
            case Tuns64: result = typeid(ulong); break;
            case Tchar: result = typeid(char); break;
            case Twchar: result = typeid(wchar); break;
            case Tdchar: result = typeid(dchar); break;
            case Tfloat32: result = typeid(float); break;
            case Tfloat64: result = typeid(double); break;
            case Tfloat80: result = typeid(real); break;
            default: return 0;
        }
        return cast(size_t) cast(void*) result;
    }

    // The element/return type's own TypeInfo address, resolved through the
    // same two-source rule (`nativeTypeInfoAddress`) recursively, for a
    // composite TypeInfo field that must hold one (`TypeInfo_StaticArray`/
    // `TypeInfo_Array.value`, `TypeInfo_Delegate.next`). Neither the
    // element type nor the composite one is necessarily the direct operand
    // of a source-level `typeid`, so the diagnostic is built from the
    // element type itself rather than from an enclosing `TypeidExp`.
    private size_t elementTypeInfoAddress(Type elementType) {
        import std.conv: text;

        const address = nativeTypeInfoAddress(elementType);
        if (address == 0)
            throw new Exception(text(
                "Unsupported typeid in bytecode core: typeid(",
                typeChars(elementType),
                ")",
            ));
        return address;
    }

    // Emit a TypeInfo_Array for a `T[]` element type with no host-linked
    // symbol, the way any D backend's codegen would: `value` is the
    // element type's own TypeInfo, matching dmd's
    // glue/todt.d `visit(TypeInfoArrayDeclaration)`.
    private size_t nativeArrayTypeInfo(Type type) {
        import object: TypeInfo, TypeInfo_Array;

        if (auto existing = type in _nativeCompositeTypeInfos)
            return *existing;

        const elementAddress =
            elementTypeInfoAddress(type.toBasetype.isTypeDArray.next);
        auto result = new TypeInfo_Array;
        result.value = cast(TypeInfo) cast(void*) elementAddress;

        _program.nativeTypeInfos ~= cast(TypeInfo) result;
        const address = cast(size_t) cast(void*) result;
        _nativeCompositeTypeInfos[type] = address;
        return address;
    }

    // Emit a TypeInfo_StaticArray for a `T[N]` element type with no
    // host-linked symbol, the way any D backend's codegen would: `value`
    // is the element type's own TypeInfo and `len` is `N`, matching dmd's
    // glue/todt.d `visit(TypeInfoStaticArrayDeclaration)`.
    private size_t nativeStaticArrayTypeInfo(Type type) {
        import object: TypeInfo, TypeInfo_StaticArray;

        if (auto existing = type in _nativeCompositeTypeInfos)
            return *existing;

        const elementAddress =
            elementTypeInfoAddress(type.toBasetype.isTypeSArray.next);
        auto result = new TypeInfo_StaticArray;
        result.value = cast(TypeInfo) cast(void*) elementAddress;
        result.len = staticArrayLength(type);

        _program.nativeTypeInfos ~= cast(TypeInfo) result;
        const address = cast(size_t) cast(void*) result;
        _nativeCompositeTypeInfos[type] = address;
        return address;
    }

    // Emit a TypeInfo_Delegate for a delegate type with no host-linked
    // symbol, the way any D backend's codegen would: `next` is the
    // delegate's return type TypeInfo and `deco` is the delegate type's
    // own mangled name, matching dmd's
    // glue/todt.d `visit(TypeInfoDelegateDeclaration)`.
    private size_t nativeDelegateTypeInfo(Type type) {
        import object: TypeInfo, TypeInfo_Delegate;
        import std.string: fromStringz;

        if (auto existing = type in _nativeCompositeTypeInfos)
            return *existing;

        auto delegateType = type.toBasetype.isTypeDelegate;
        const returnAddress =
            elementTypeInfoAddress(delegateType.next.nextOf);
        auto result = new TypeInfo_Delegate;
        result.next = cast(TypeInfo) cast(void*) returnAddress;
        result.deco = delegateType.deco.fromStringz.idup;

        _program.nativeTypeInfos ~= cast(TypeInfo) result;
        const address = cast(size_t) cast(void*) result;
        _nativeCompositeTypeInfos[type] = address;
        return address;
    }

    // Emit a TypeInfo_Struct for a struct with no host-linked symbol, the
    // way any D backend's codegen would: the struct's real default-value
    // bytes (via dmd's own `defaultInitLiteral`, the same source
    // `compileStructDeclaration` uses for a bare `S s;`), its dmd-computed
    // size and alignment, its mangled type name, and whether the GC needs
    // to scan it. Method pointers (`xtoHash`, `xopEquals`, `xopCmp`,
    // `xtoString`, `xdtor`, `xpostblit`) stay null; nothing in the
    // bytecode core calls them yet.
    private size_t nativeStructTypeInfo(Type type) {
        import object: TypeInfo, TypeInfo_Struct;
        import dmd.common.outbuffer: OutBuffer;
        import dmd.mangle: mangleToBuffer;
        import dmd.typesem: defaultInitLiteral, hasPointers;

        if (auto existing = type in _nativeStructTypeInfos)
            return *existing;

        auto structType = type.toBasetype.isTypeStruct;

        auto result = new TypeInfo_Struct;
        result.m_init = new ubyte[typeFacts(type).byteWidth];
        result.m_align = typeFacts(type).alignment;
        // `StructFlags.hasPointers` is the first (and so default-`.init`)
        // enum member: an unset field would misreport `hasPointers` for
        // types dmd knows carry no indirections, so both arms must assign.
        result.m_flags = hasPointers(type.toBasetype)
            ? TypeInfo_Struct.StructFlags.hasPointers
            : cast(TypeInfo_Struct.StructFlags) 0;

        OutBuffer nameBuffer;
        mangleToBuffer(type.toBasetype, nameBuffer);
        result.mangledName = nameBuffer[].idup;

        auto literal = structType
            .defaultInitLiteral(structType.sym.loc)
            .isStructLiteralExp;
        writeStructLiteralFieldBytes(literal, cast(ubyte[]) result.m_init);

        _program.nativeTypeInfos ~= cast(TypeInfo) result;
        const address = cast(size_t) cast(void*) result;
        _nativeStructTypeInfos[type] = address;
        return address;
    }

    private Operand* tryTypeidName(DotVarExp dot) {
        import std.conv: text;

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

        // DMD lowers `object.classinfo.name` to `(**object).name`: retain the
        // original class-typed expression at the root of the two dereferences
        // so the VM can ask the runtime object for its dynamic class name.
        if (auto outer = dot.e1.isPtrExp)
            if (auto inner = outer.e1.isPtrExp)
                if (inner.e1.type !is null &&
                    inner.e1.type.toBasetype.isTypeClass !is null) {
                    const object = compileExpression(inner.e1);
                    if (object.isPointer)
                        emitNullClassReferenceCheck(
                            object.offset,
                            text(
                                "class `", expressionChars(inner.e1),
                                "` is `null` and cannot be dereferenced",
                            ),
                        );
                    const offset = allocateBytes(
                        sliceDescriptorSize, size_t.sizeof,
                    );
                    _code ~= Instruction(
                        Op.className, offset, object.offset,
                    );
                    return heapOperand(Operand(offset, ScalarType.void_));
                }

        if (auto classinfo = dot.e1.isDotVarExp)
            if (classinfo.var !is null &&
                classinfo.var.ident !is null &&
                classinfo.var.ident.toString == "classinfo") {
                const object = compileExpression(classinfo.e1);
                if (object.isPointer)
                    emitNullClassReferenceCheck(
                        object.offset,
                        text(
                            "class `", expressionChars(classinfo.e1),
                            "` is `null` and cannot be dereferenced",
                        ),
                    );
                const offset = allocateBytes(
                    sliceDescriptorSize, size_t.sizeof,
                );
                _code ~= Instruction(Op.className, offset, object.offset);
                return heapOperand(Operand(offset, ScalarType.void_));
            }

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
                compileScalarDeclaration(variable);
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
            const offset = allocateBytes(
                cast(uint) size_t.sizeof, size_t.sizeof,
            );
            _code ~= Instruction(
                Op.copy, offset, address.offset,
                cast(ushort) size_t.sizeof,
            );
            registerReferenceDeclaration(variable).scalar = offset;
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
                if (auto pointer = declarationRecordView(declaration).refPointerOrNull)
                    if (auto offset = declarationRecordView(declaration).scalarOrNull) {
                        const destination = allocateBytes(
                            delegateValueSize,
                            size_t.sizeof,
                        );
                        emitPointerLoad(
                            destination,
                            *offset,
                            compileSizeConstant(0),
                            delegateValueSize,
                        );
                        return destination;
                    }
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
        const offset = allocateBytes(
            totalSize, typeFacts(variable.type).alignment,
        );
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

        // `T[N] dest = src`: a value-type block copy of all N*sizeof(T) bytes
        // from the source static array's inline slot into the destination's.
        // Scoped to a genuinely `Tsarray`-typed source: `resolvePlace`'s own
        // `CallExp` handling also resolves a Place for a call returning an
        // aggregate `Tarray` (a 16-byte `{length, ptr}` descriptor, e.g.
        // `_d_arrayctor`'s return value below) -- reading `totalSize`
        // (this destination's own, much wider, byte count) from that
        // 16-byte value would copy past it into whatever memory follows.
        if (source.type !is null &&
            source.type.toBasetype.ty == TY.Tsarray)
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

        // A postblit- or copy-constructor-bearing static-array copy (`const
        // S[2] a = b;`) lowers to a call (`core.internal.array.construction.
        // _d_arrayctor(a[], b[])`) whose own result type is a plain dynamic
        // array, not this destination's `Tsarray` type -- the only shape
        // that reaches this deep with a `CallExp` source. `a[]` is a slice
        // view over `offset`'s own storage (the same real-address view
        // `dynamicArrayDescriptor` builds for any static-array lvalue), so
        // compiling the call for its side effect writes the constructed
        // elements straight through into `offset`; its returned descriptor
        // is discarded, matching dmd's own codegen, which never uses it.
        if (auto call = source.isCallExp) {
            compileExpression(call);
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
        const offset = allocateBytes(
            totalSize, typeFacts(arrayType).alignment,
        );
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

    // A struct `S` local occupies `Type.size()` inline frame bytes at its
    // DMD-computed alignment, each field at `base + field.offset`. The block is
    // zeroed first (scalar fields default to 0, dynamic-array fields to an empty
    // `{0, null}` descriptor), then a struct-literal initializer stores its
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
        // above), then run the postblit.
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

        // `S dest = cond ? a : b`: neither arm need be a Place on its own (a
        // struct-typed ternary is not itself an lvalue merely because both
        // arms are), so branch here and block-copy each arm's own value into
        // the declared slot directly -- the same destination-directed shape
        // `compileDynamicArrayInto`'s CondExp arm already uses for dynamic
        // arrays.
        if (auto conditional = source.isCondExp) {
            const condition = compileBoolCondition(conditional.econd);
            const falseJump = emitJumpIfFalse(condition);
            compileStructValueInto(offset, variable.type, conditional.e1);
            const endJump = emitJump;
            patchJump(falseJump);
            compileStructValueInto(offset, variable.type, conditional.e2);
            patchJump(endJump);
            return;
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

    // One arm of a struct-typed ternary (`compileStructDeclaration`'s CondExp
    // arm above): block-copy `source`'s value into `offset` directly, rather
    // than resolving it through Place first, since an arm need not be a Place
    // on its own (a string-literal arm in the dynamic-array analogue is the
    // same shape). `structValueOffsetOrNull` already unwraps a CommaExp
    // source itself, so only the struct-literal and default-init shapes need
    // their own arm here.
    private void compileStructValueInto(
        in ushort offset, Type type, Expression source,
    ) {
        import std.conv: text;

        source = initializerExpression(source);

        if (auto literal = source.isStructLiteralExp) {
            compileStructLiteralInto(offset, literal);
            return;
        }

        if (auto sourceOffset = structValueOffsetOrNull(source)) {
            _code ~= Instruction(
                Op.copy, offset, *sourceOffset,
                cast(ushort) typeFacts(type).byteWidth,
            );
            return;
        }

        // `S.init` (DMD's init-symbol VarExp): materialise its real default
        // bytes, matching compileStructDeclaration's own VarExp fallback.
        if (source.isVarExp !is null) {
            import dmd.typesem: defaultInitLiteral;

            auto defaultLiteral = type.toBasetype.isTypeStruct
                .defaultInitLiteral(source.loc).isStructLiteralExp;
            if (defaultLiteral !is null) {
                compileStructLiteralInto(offset, defaultLiteral);
                return;
            }

            if (compileDefaultStructFields(offset, structDeclarationOf(type)))
                return;
        }

        throw new Exception(text(
            "Unsupported struct ternary arm in bytecode core: ",
            expressionChars(source),
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
            typeFacts(type).byteWidth, typeFacts(type).alignment,
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
                    arrayElementIsDynamicArray(fieldType),
                );
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
        // A postblit call whose receiver is itself a first-write
        // construction (`(this.payload = c).__postblit()`, druntime
        // `emplaceRef`'s generated `S.this()`) arrives as a
        // ConstructExp/BlitExp, not a plain lvalue: DMD emits this shape
        // whenever a struct-typed field or local is initialised and then
        // immediately postblitted. `placeAddressOrNull` above declines it
        // (a Construct/BlitExp is not a place), so without this the
        // fallback below reads only the assigned VALUE (`aggregateValueOffset`
        // -> `structOperandOffset` -> `initializerExpression` strips the
        // destination) and hands the caller a disconnected temporary -- a
        // wrapping postblit call then mutates that temporary instead of the
        // real field/local. Blit the source into the real destination's
        // storage and return its address instead, restricted to the lvalue
        // shapes DMD is known to emit here (matching the identical
        // whitelist `compileExpression`'s statement-level ConstructExp/
        // BlitExp dispatch already uses).
        if (auto construct = expression.isConstructExp)
            if (construct.e1.isDotVarExp !is null ||
                construct.e1.isVarExp !is null ||
                construct.e1.isSliceExp !is null ||
                construct.e1.isThisExp !is null ||
                construct.e1.isIndexExp !is null)
                if (auto destination = placeOrNull(construct.e1)) {
                    storeExpressionIntoPlace(*destination, construct.e2);
                    return addressOfPlace(*destination);
                }
        if (auto blit = expression.isBlitExp)
            if (blit.e1.isDotVarExp !is null ||
                blit.e1.isVarExp !is null ||
                blit.e1.isSliceExp !is null ||
                blit.e1.isThisExp !is null)
                if (auto destination = placeOrNull(blit.e1)) {
                    storeExpressionIntoPlace(*destination, blit.e2);
                    return addressOfPlace(*destination);
                }
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
                typeFacts(type).byteWidth, typeFacts(type).alignment,
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
    private ushort capturedFrameIndex(in FuncDeclaration owner, in ushort capturedOffset) {
        const contextBase = enclosingFrameBase(owner);
        const sourceIndex =
            allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof);
        const offsetConstant = compileSizeConstant(capturedOffset);
        _code ~= Instruction(
            Op.addInt8, sourceIndex, contextBase, offsetConstant,
        );
        return sourceIndex;
    }

    // A slot holding enclosing function `owner`'s live frame base index,
    // reached from the function currently being compiled.
    //
    // A call site hands a callee its LEXICAL parent's live frame as that
    // callee's received context (`compileCall`'s nested-context hand-off) --
    // the caller's own frame exactly when the caller is that parent --
    // matching real D: a nested function's context is its immediate lexically
    // enclosing function's frame, never its physical caller's. So the current
    // function's own received context (`_nestedContextOffset`) is exactly one
    // hop -- its immediate enclosing function's frame -- which is `owner`
    // only for a single level of nesting. When `owner` sits further up, each
    // intermediate ancestor's own received context is a further hop: it lives
    // at that ancestor's own `nestedContextOffset` within the frame just
    // reached. The hops hold however the callee was physically reached, as
    // long as every hand-off on the way relayed a lexical-parent frame.
    // `compileCall`'s direct-call hand-off does; delegate creation
    // (`delegateContextOffset`) and callers whose own context is
    // `this`-derived still hand the creator's frame, so a walk relayed
    // through those can still misresolve.
    private ushort enclosingFrameBase(in FuncDeclaration owner) {
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
                        "Unsupported multi-level nested-frame walk ",
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
        return contextBase;
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
                Op.copy, cast(ushort) sliceDescriptorPtrOffset(destination),
                pointerSlot, cast(ushort) size_t.sizeof,
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

        size_t count;
        auto literalBytes = moduleDynamicArrayLiteralInitializerBytes(
            normalized, elementType, arrayElementIsDynamicArray(field.type),
            field.type, count,
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
                arrayElementIsDynamicArray(field.type),
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
                    arrayElementIsDynamicArray(field.type),
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
        const elementIsDynamicArray = arrayElementIsDynamicArray(variable.type);
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
            offset, elementType, source, elementIsDynamicArray);
    }

    // `elementIsArray`: true only when each element of the array being built
    // is itself a genuine dynamic array (`int[][]`'s `int[]` rows), needing
    // its own separately heap-allocated 16-byte descriptor
    // (`arrayElementIsDynamicArray`). A `Tsarray` element (`int[2][]`'s
    // `int[2]` rows) is the real D layout instead: stored inline,
    // `T[N].sizeof`-strided, so it takes the same generic full-width-block
    // path below every other aggregate element (a struct, say) already
    // takes.
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
                    destination, cast_.to, cast_.e1.type,
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

        // `dest = new T[](length)` / `new T[][](rows, cols)`: DMD lowers this
        // to a call to `_d_newarrayT!T`/`_d_newarraymTX!(...)` (`.lowering`),
        // which does the real GC allocation and default-init fill; compile
        // that call and copy its 16-byte slice-descriptor result in.
        if (auto new_ = source.isNewExp) {
            if (new_.lowering is null)
                throw new Exception(text(
                    "Unsupported new array in bytecode core: ",
                    expressionChars(new_),
                ));
            const result = compileExpression(new_.lowering);
            _code ~= Instruction(
                Op.copy, destination, result.offset,
                cast(ushort) sliceDescriptorSize,
            );
            return;
        }

        // `dest = src[lo .. hi]` forms a sub-slice sharing the source's
        // backing memory, so writes through `dest` propagate to the original.
        if (auto slice = source.isSliceExp) {
            compileSliceInto(destination, elementType, slice);
            return;
        }

        // `dest = a ~ b` (concatenation): DMD lowers a chain of `~` to one
        // n-ary `_d_arraycatnTX!(...)` call (`.lowering`), which does the
        // real GC allocation and element copy; compile that call and copy
        // its 16-byte slice-descriptor result in. A fully-literal
        // concatenation (e.g. two string literals) is constant-folded by
        // DMD's own `Expression.optimize` before this point, replacing the
        // `CatExp` node itself with a plain literal, so `.lowering` is
        // always populated on any `CatExp` actually reaching here.
        if (auto cat = source.isCatExp) {
            if (cat.lowering is null)
                throw new Exception(text(
                    "Unsupported concatenation in bytecode core: ",
                    expressionChars(cat),
                ));
            const result = compileExpression(cat.lowering);
            _code ~= Instruction(
                Op.copy, destination, result.offset,
                cast(ushort) sliceDescriptorSize,
            );
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

        // A runtime class name is derived from the VM object's dynamic class,
        // not loaded as a field of the host TypeInfo mirror.
        if (auto dot = source.isDotVarExp)
            if (auto name = tryTypeidName(dot)) {
                _code ~= Instruction(
                    Op.copy, destination, name.offset,
                    cast(ushort) sliceDescriptorSize,
                );
                return;
            }

        // An lvalue array source loads its descriptor through the same Place
        // used by mutation, preserving D's shared-backing assignment. Scoped
        // to `Tarray` sources only: a `Tsarray` lvalue's storage is `dim`
        // consecutive elements, not a {length, ptr} descriptor, so
        // reinterpreting it here would copy element bytes as if they were a
        // length and pointer.
        if (source.type !is null && source.type.toBasetype.ty == TY.Tarray)
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

        // A `Tsarray` source used as a dynamic-array value (`outer ~= row;`
        // boxing a static-array row, or a static-array-variable element of
        // an array-of-arrays literal): copy its `dim` elements into a fresh
        // heap block. Scoped to plain scalar elements (`elementType` is
        // `void_` for a struct/nested-array element, which this loop's
        // scalar `loadThroughPointer` cannot widen for) -- the untested
        // aggregate-row shape falls through to the explicit decline below
        // rather than risk mis-copying it silently.
        if (!elementIsArray &&
            elementType != ScalarType.void_ &&
            source.type !is null &&
            source.type.toBasetype.ty == TY.Tsarray)
            if (auto place = placeOrNull(source)) {
                const dim = staticArrayLength(source.type);
                const elementSize = dynamicArrayElementSize(source.type);
                _code ~= Instruction(
                    Op.allocArray,
                    destination,
                    cast(ushort) elementSize,
                    cast(ushort) dim,
                );
                const address = addressOfPlace(*place);
                foreach (elementIndex; 0 .. dim) {
                    const index = compileSizeConstant(elementIndex);
                    const value = loadThroughPointer(
                        Operand(
                            address.offset, ScalarType.ulong_, true,
                            elementType,
                        ),
                        index,
                    );
                    emitIndexStore(value.offset, destination, index, elementSize);
                }
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
        // copy the ordinary {length, ptr} descriptor `compileExpression`
        // already resolves it to.
        if (isStringType(source.type) && source.isArrayLiteralExp is null) {
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

        // An empty literal (`T[] a = [];`) allocates nothing: DMD's own
        // GC-usage pass (`nogc.d`'s `NOGCVisitor.visit(ArrayLiteralExp)`)
        // never calls into `lowerArrayLiteral` for `dim == 0`, leaving
        // `.lowering` null, so a bare null descriptor is both the only
        // available value and the correct one.
        if (count == 0) {
            _code ~= Instruction(Op.nullSlice, destination);
            return;
        }

        const width = elementIsArray
            ? sliceDescriptorSize : dynamicArrayElementSize(source.type);

        // `.lowering` carries the `_d_arrayliteralTX!T(dim)` allocation
        // call: the real `GC.malloc` (needing T's TypeInfo), matching every
        // other allocating array operation this core compiles from its
        // frontend lowering. It only allocates the backing block -- element
        // values are stored below, mirroring dmd's own codegen split
        // (`glue/e2ir.d`'s `visitArrayLiteral`, which fills the elements
        // itself after calling the same hook). DMD's own GC-usage pass
        // (`nogc.d`) leaves it null in two known cases, mirrored by falling
        // back to the same heap-backed block this core already builds for
        // other inline array shapes with no druntime hook of their own
        // (e.g. boxing a `Tsarray` row): an `onstack` literal, one its
        // escape analysis proved never outlives this expression (e.g. used
        // only as a transient comparison operand), whose own codegen
        // materialises the elements directly with no GC call either
        // (`glue/e2ir.d`'s `ExpressionsToStaticArray` branch); and a struct
        // field's default-value literal (`Inner[] values = [Inner(f())];`),
        // semantically analysed once at the field declaration itself,
        // outside any function scope -- `nogc.d`'s `checkGC` bails out
        // early whenever `sc.func is null`, so this literal never runs
        // through the pass that would populate `.lowering`, regardless of
        // which function later constructs a value from it.
        if (literal.lowering !is null) {
            const allocation = compileExpression(literal.lowering);
            _code ~= Instruction(
                Op.copy, cast(ushort) sliceDescriptorPtrOffset(destination),
                allocation.offset, cast(ushort) size_t.sizeof,
            );
            _code ~= Instruction(
                Op.loadConstant,
                cast(ushort) sliceDescriptorLengthOffset(destination),
                constantIndex(count),
                cast(ushort) size_t.sizeof,
            );
        } else {
            _code ~= Instruction(
                Op.allocArray, destination, cast(ushort) width,
                cast(ushort) count,
            );
        }

        // An array-of-arrays literal (`[[..], [..]]`, any nesting depth):
        // each element is itself a genuine dynamic array, stored as a
        // 16-byte descriptor. Build each inner array into a fresh
        // descriptor slot and store it into the outer block. A row is
        // itself an array-of-arrays (depth 3 and beyond, e.g. `int[][][]`'s
        // `int[][]` rows) when *its own* element is a dynamic array too --
        // checked fresh per recursive call rather than reusing the caller's
        // `elementIsArray`, since that flag describes this level's rows,
        // not the row's own elements. A `Tsarray` row (`int[2][]`) is not
        // this shape -- it falls to the generic full-width-block path
        // below, laid out inline like any other aggregate element.
        if (elementIsArray) {
            const rowElementIsArray = arrayElementIsDynamicArray(
                source.type.toBasetype.nextOf,
            );
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

        foreach (elementIndex; 0 .. count) {
            auto element = (*literal.elements)[elementIndex];
            const value = element.type.toBasetype.ty == TY.Tstruct
                ? Operand(structOperandOffset(element), ScalarType.void_)
                : compileExpression(element);
            const index = compileSizeConstant(elementIndex);
            emitIndexStore(value.offset, destination, index, width);
        }
    }

    // `cast(T2[])x`: D reinterprets `x`'s backing bytes as `T2` elements, so an
    // element-size-changing cast rescales the copied descriptor's element
    // count by the byte-size ratio (`newLength = oldLength * oldElementSize /
    // newElementSize`); the pointer word is untouched. A same-size cast (the
    // common qualifier-only case, e.g. `const(int)[]` to `int[]`) is a no-op.
    // Both sides go through `dynamicArrayElementSize`, the same helper
    // `compileCastExpression`'s own element-size comparison uses: it already
    // gives real `void[]` its one-byte stride and an array-of-arrays element
    // its whole-descriptor stride, so this does not need to re-derive width
    // from the `ScalarType` tag, which marks a genuine `void` element and a
    // struct/static-array element the same way.
    private void rescaleReinterpretedSliceLength(
        in ushort destination,
        Type destinationType,
        Type sourceType,
    ) {
        const destinationElementSize = dynamicArrayElementSize(destinationType);
        const sourceElementSize = dynamicArrayElementSize(sourceType);
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
        // is itself a genuine dynamic array, stored as a 16-byte descriptor,
        // mirroring `compileDynamicArrayInto`'s own array-of-arrays literal
        // handling. `variable.type` (the hoisted stack temp's own declared
        // type) names the literal's true shape; `elementType`'s
        // deepest-leaf-scalar convention can't distinguish this from a
        // scalar or inline-`Tsarray` element on its own. A `Tsarray`
        // element (`int[2][]`) is not this shape -- it falls to the
        // generic full-width-block path below, same as any other
        // aggregate element.
        if (arrayElementIsDynamicArray(variable.type)) {
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

        const elementSize = dynamicArrayElementSize(variable.type);
        _code ~= Instruction(
            Op.allocArray,
            destination,
            cast(ushort) elementSize,
            cast(ushort) count,
        );

        foreach (elementIndex; 0 .. count) {
            auto element = (*literal.elements)[elementIndex];
            auto value = element.type.toBasetype.ty == TY.Tstruct
                ? Operand(structOperandOffset(element), ScalarType.void_)
                : compileExpression(element);
            if (value.type != ScalarType.void_ &&
                size(value.type) < elementSize)
                value = extend(value, elementType);
            emitIndexStore(
                value.offset, destination, compileSizeConstant(elementIndex),
                elementSize,
            );
        }
        return true;
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

        const elementSize = dynamicArrayElementSize(slice.e1.type);
        emitSubSlice(destination, descriptor.offset, bounds, elementSize);
    }

    // `p[lo .. hi]` over a pointer: write a slice descriptor
    // {hi - lo, p + lo * elementSize} at `destination`, sharing the heap block
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
        // {length, ptr} form, so it takes the same path as any other `T[]`.
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

            const elementType = dynamicArrayElementType(cast_.to);
            const targetElementSize = dynamicArrayElementSize(cast_.to);
            const sourceElementSize = dynamicArrayElementSize(cast_.e1.type);
            if (targetElementSize == sourceElementSize)
                return source;

            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            _code ~= Instruction(
                Op.copy, offset, source.offset, cast(ushort) sliceDescriptorSize,
            );
            rescaleReinterpretedSliceLength(offset, cast_.to, cast_.e1.type);
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
        const elementByteWidth = dynamicArrayElementSize(cast_.e1.type);
        return pointerToElement(
            descriptor.offset, descriptor.elementType, compileSizeConstant(0),
            elementByteWidth,
        );
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
    // `&f`: the guest function-pointer value is `f`'s plain index into
    // `Program.functions`, uniform whether `f` is VM-compiled or a native
    // leaf (`registerFunction` records which, and `Op.call`/`Op.callIndirect`
    // dispatch on that, not on the value itself).
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
            Op.copy, pointer,
            cast(ushort) sliceDescriptorPtrOffset(descriptorOffset),
            cast(ushort) size_t.sizeof,
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
        if (lhs.type == ScalarType.real_ && rhs.type == ScalarType.real_)
            return emitBinary(Op.addReal, lhs, rhs, ScalarType.real_);

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
        if (isEightByteInteger(lhs.type) &&
            isEightByteInteger(rhs.type))
            return emitBinary(Op.bitXorInt8, lhs, rhs, scalarType(xor.type));

        return compileInt4BinaryResult(
            xor,
            lhs,
            rhs,
            Op.bitXorInt4,
            scalarType(xor.type),
            "Unsupported bitwise xor in bytecode core: ",
        );
    }

    // Integer multiplication (float/double below). Pointer arithmetic scales
    // its integer operand through an 8-byte `cast(long)n * elementSize`, so
    // the 8-byte form is the one that matters here; the 4-byte form operates
    // on raw bits like `addInt4`, so signed and unsigned operands share it.
    private Operand compileMultiplyExpression(MulExp multiply) {
        import std.conv: text;

        const lhs = compileExpression(multiply.e1);
        const rhs = compileExpression(multiply.e2);
        if (lhs.type == ScalarType.float_ && rhs.type == ScalarType.float_)
            return emitBinary(Op.mulFloat, lhs, rhs, ScalarType.float_);
        if (lhs.type == ScalarType.double_ && rhs.type == ScalarType.double_)
            return emitBinary(Op.mulDouble, lhs, rhs, ScalarType.double_);
        if (lhs.type == ScalarType.real_ && rhs.type == ScalarType.real_)
            return emitBinary(Op.mulReal, lhs, rhs, ScalarType.real_);

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
        if (lhs.type == ScalarType.float_ && rhs.type == ScalarType.float_)
            return emitBinary(Op.divFloat, lhs, rhs, ScalarType.float_);
        if (lhs.type == ScalarType.double_ && rhs.type == ScalarType.double_)
            return emitBinary(Op.divDouble, lhs, rhs, ScalarType.double_);
        if (lhs.type == ScalarType.real_ && rhs.type == ScalarType.real_)
            return emitBinary(Op.divReal, lhs, rhs, ScalarType.real_);
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
        if (lhs.type == ScalarType.float_ && rhs.type == ScalarType.float_)
            return emitBinary(Op.modFloat, lhs, rhs, ScalarType.float_);
        if (lhs.type == ScalarType.double_ && rhs.type == ScalarType.double_)
            return emitBinary(Op.modDouble, lhs, rhs, ScalarType.double_);
        if (lhs.type == ScalarType.real_ && rhs.type == ScalarType.real_)
            return emitBinary(Op.modReal, lhs, rhs, ScalarType.real_);
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
        import dmd.astenums: TY;

        const condition = compileBoolCondition(conditional.econd);
        // A dynamic-array-typed result (string included) is a 16-byte
        // {length, ptr} descriptor, not the 8-byte pointer/scalar
        // `operandSize` computes for every other result kind (this
        // function's original design, per the comment below, was a
        // pointer-valued conditional -- an 8-byte value). Reinterpreting an
        // array descriptor as 8 bytes copies only its length word and
        // leaves `result`'s pointer word at its zeroed frame default, so a
        // later consumer reads a descriptor whose length looks right over a
        // null pointer.
        const isArrayResult = conditional.type !is null &&
            conditional.type.toBasetype.ty == TY.Tarray;
        const result = allocateBytes(
            isArrayResult ? sliceDescriptorSize : cast(uint) size_t.sizeof,
            size_t.sizeof,
        );

        const falseJump = emitJumpIfFalse(condition);
        const whenTrue = compileExpression(conditional.e1);
        // An array-typed arm's descriptor Operand is untagged (`void_`
        // type, not `isPointer`) -- the same shape `hasValue` treats as "no
        // value" for a void call result. Every array arm genuinely has a
        // descriptor to copy (even a null/empty one), so bypass `hasValue`
        // for an array result rather than let it read as valueless.
        const trueHasValue = isArrayResult || hasValue(whenTrue);
        uint valueSize;
        if (trueHasValue) {
            valueSize = isArrayResult
                ? sliceDescriptorSize
                : operandSize(whenTrue);
            _code ~= Instruction(
                Op.copy, result, whenTrue.offset, cast(ushort) valueSize,
            );
        }
        const endJump = emitJump;

        patchJump(falseJump);
        const whenFalse = compileExpression(conditional.e2);
        if (!trueHasValue)
            valueSize = isArrayResult
                ? sliceDescriptorSize
                : operandSize(whenFalse);
        if (isArrayResult || hasValue(whenFalse))
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
    // source yields the same {length, ptr} descriptor. Every other operand
    // goes through `compileTruthValue` directly.
    private Operand compileBoolCondition(Expression expression) {
        if (isStringType(expression.type) || isDynamicArrayArgument(expression)) {
            const array = dynamicArrayDescriptor(expression);
            return compileTruthValue(
                Operand(
                    cast(ushort) sliceDescriptorPtrOffset(array.offset),
                    ScalarType.void_,
                    true,
                ),
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
        if (lhs.type == ScalarType.real_ && rhs.type == ScalarType.real_)
            return emitBinary(Op.subReal, lhs, rhs, ScalarType.real_);

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
        if (isEightByteInteger(source.type)) {
            const resultType = scalarType(complement.type);
            const offset = allocate(resultType);
            _code ~= Instruction(Op.bitNotInt8, offset, source.offset);
            return Operand(offset, resultType);
        }
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

        auto place = placeOrNull(assign.e1);
        if (place is null)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));
        const rhs = compileExpression(assign.e2);

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

        const storageType = place.type;
        const operationType = scalarType(assign.e1.type);
        if (!isCompoundIntegerScalar(storageType) ||
            !isCompoundIntegerScalar(operationType) ||
            !isCompoundIntegerScalar(rhs.type))
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const eightByteShift = op8 == Op.shlInt8 ||
            op8 == Op.shrInt8 || op8 == Op.ushrInt8;
        const operationIsEightByte = isEightByteInteger(operationType);
        const validRhs = operationIsEightByte
            ? eightByteShift
                ? size(rhs.type) <= int.sizeof
                : size(rhs.type) <= size(operationType)
            : !isEightByteInteger(rhs.type);
        if (!validRhs || operationIsEightByte && op8 == op4)
            throw new Exception(text(
                unsupportedMessage,
                expressionChars(assign),
            ));

        const lhs = integerOperationOperand(
            loadPlace(place),
            operationType,
        );
        const rhsValue = integerOperationOperand(
            rhs,
            operationIsEightByte && eightByteShift
                ? ScalarType.int_
                : operationType,
        );
        const destination = allocate(operationType);
        const operation = operationIsEightByte
            ? op8
            : op4 == Op.shrInt4 && operationType == ScalarType.uint_
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

        // `arr.length = n`: resize the array in place, preserving existing
        // elements and zero-filling growth. Detected by the ArrayLengthExp
        // lvalue (DMD wraps this in a LoweredAssignExp carrying the
        // `_d_arraysetlengthT` call in `.lowering`), not a druntime name.
        if (assign.e1.isArrayLengthExp !is null) {
            auto lowered = assign.isLoweredAssignExp;
            if (lowered is null || lowered.lowering is null)
                throw new Exception(text(
                    "Unsupported array-length assignment in bytecode core: ",
                    expressionChars(assign),
                ));
            return compileExpression(lowered.lowering);
        }

        auto place = placeOrNull(assign.e1);
        if (place is null)
            throw new Exception(text(
                "Unsupported assignment in bytecode core: ",
                expressionChars(assign),
            ));

        if (assign.e1.type.toBasetype.isTypeAArray is null &&
            assign.e1.type.toBasetype.isTypeDArray !is null &&
            place.kind != Place.Kind.slice) {
            const descriptor = dynamicArrayDescriptor(assign.e2);
            storeDynamicArrayPlace(*place, descriptor);
            return Operand(descriptor.offset, ScalarType.void_);
        }

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
    // -- and writes {count, blockPointer} directly into the descriptor's
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
                initializerExpr, elementType,
                arrayElementIsDynamicArray(declaration.type),
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
            const ptrOffset = sliceDescriptorPtrOffset(offset);
            const lengthOffset = sliceDescriptorLengthOffset(offset);
            _program.moduleData[ptrOffset .. ptrOffset + size_t.sizeof] =
                nativeToLittleEndian(pointer);
            _program.moduleData[lengthOffset .. lengthOffset + size_t.sizeof] =
                nativeToLittleEndian(cast(size_t) literalCount);
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
    // block at runtime, so the outer bytes hold one 16-byte `{count,
    // pointer}` descriptor per row rather than raw scalar bytes. The
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

        // A `Tsarray` row (`int[3][]`'s `int[3]` elements): the real D
        // layout stores each row inline, `T[N].sizeof`-strided, not behind
        // its own heap-allocated descriptor -- fold each row's own literal
        // bytes (`moduleStaticArrayLiteralInitializerBytes`, the same
        // constant-folder a plain module-level `int[3] x = [1, 2, 3];`
        // already uses) directly into this level's `bytes` at
        // `elementIndex * rowByteSize`, no `literalBlocks` entry or
        // descriptor involved.
        if (!elementIsArray && arrayType !is null) {
            auto rowType = arrayType.toBasetype.nextOf;
            if (rowType !is null && rowType.toBasetype.ty == TY.Tsarray) {
                auto outer = initializerExpr.isArrayLiteralExp;
                if (outer is null || outer.elements is null ||
                    outer.elements.length == 0)
                {
                    return null;
                }

                const rowByteSize = typeFacts(rowType).byteWidth;
                auto rowScalarType = rowType.toBasetype.nextOf;
                count = outer.elements.length;
                ubyte[] bytes;
                bytes.length = count * rowByteSize;
                foreach (elementIndex; 0 .. count) {
                    auto element = (*outer.elements)[elementIndex];
                    auto rowLiteral =
                        element is null ? null : element.isArrayLiteralExp;
                    auto rowBytes = moduleStaticArrayLiteralInitializerBytes(
                        rowLiteral, rowScalarType, cast(ushort) rowByteSize,
                    );
                    if (rowBytes is null) {
                        count = 0;
                        return null;
                    }

                    const rowOffset = elementIndex * rowByteSize;
                    bytes[rowOffset .. rowOffset + rowByteSize] = rowBytes[];
                }
                return bytes;
            }
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
                // genuine-dynamic-array shape (e.g. `int[][][]`'s
                // middle-level row, itself an `int[][]` whose own elements
                // are `int[]`) keeps recursing through the array branch
                // instead of stopping after exactly one level -- this is
                // what generalises this function from one fixed level of
                // nesting to arbitrary depth. A `Tsarray` row falls through
                // to the branch below instead, stored inline.
                const rowElementIsArray = element !is null &&
                    element.type !is null &&
                    arrayElementIsDynamicArray(element.type);
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
                const rowPtrOffset = sliceDescriptorPtrOffset(rowOffset);
                const rowLengthOffset = sliceDescriptorLengthOffset(rowOffset);
                bytes[rowPtrOffset .. rowPtrOffset + size_t.sizeof] =
                    nativeToLittleEndian(rowPointer);
                bytes[rowLengthOffset .. rowLengthOffset + size_t.sizeof] =
                    nativeToLittleEndian(cast(size_t) rowCount);
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
            allocateModuleBytes(size, typeFacts(declaration.type).alignment);
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
    private ModuleStaticArrayVariable* allocateModuleStaticArrayVariable(
        VarDeclaration declaration,
    ) {
        if (declaration is null || !declaration.isDataseg ||
            declaration.isImmutable)
        {
            return null;
        }

        auto elementType = declaration.type.toBasetype.nextOf;
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
        if (hasDefaultInitializer) {
            literalBytes.length = size;
            if (!writeStaticArrayDefaultInitializerBytes(
                    declaration.type, literalBytes,
                ))
                return null;
        } else {
            literalBytes = moduleStaticArrayLiteralInitializerBytes(
                initializerExpr.isArrayLiteralExp, elementType, size,
            );
            if (literalBytes is null)
                return null;
        }

        const offset =
            allocateModuleBytes(size, typeFacts(declaration.type).alignment);
        registerModuleDeclaration(declaration).moduleStaticArray =
            ModuleStaticArrayVariable(offset, size);
        _program.moduleData[offset .. offset + size] = literalBytes[];
        return declarationRecordView(declaration).moduleStaticArrayOrNull;
    }

    private bool writeStaticArrayDefaultInitializerBytes(
        Type type,
        ubyte[] bytes,
    ) {
        import dmd.astenums: TY;

        if (type.toBasetype.ty != TY.Tsarray)
            return false;

        auto elementType = type.toBasetype.nextOf;
        const elementSize = typeFacts(elementType).byteWidth;
        const count = staticArrayLength(type);
        if (bytes.length != count * elementSize)
            return false;

        foreach (index; 0 .. count) {
            auto elementBytes = bytes[
                index * elementSize .. (index + 1) * elementSize
            ];
            switch (elementType.toBasetype.ty) with (TY) {
                case Tstruct:
                    if (!writeStructDefaultInitializerBytes(
                            elementType, elementBytes,
                        ))
                        return false;
                    break;
                case Tsarray:
                    if (!writeStaticArrayDefaultInitializerBytes(
                            elementType, elementBytes,
                        ))
                        return false;
                    break;
                default:
                    break;
            }
        }
        return true;
    }

    private bool writeStructDefaultInitializerBytes(
        Type type,
        ubyte[] bytes,
    ) {
        import std.bitmanip: nativeToLittleEndian;

        auto declaration = structDeclarationOf(type);
        if (bytes.length != typeFacts(type).byteWidth)
            return false;

        foreach (field; declaration.fields) {
            auto initializer =
                field._init is null ? null : field._init.isExpInitializer;
            if (initializer is null)
                continue;

            // DMD's literal-value accessors mutate their expression nodes.
            auto value = initializerExpression(initializer.exp);
            const fieldSize = typeFacts(field.type).byteWidth;
            auto fieldBytes = bytes[field.offset .. field.offset + fieldSize];
            if (auto integer = value.isIntegerExp) {
                const raw = nativeToLittleEndian(cast(ulong) integer.toInteger);
                fieldBytes[] = raw[0 .. fieldSize];
                continue;
            }
            if (auto real_ = value.isRealExp) {
                const raw = nativeToLittleEndian(
                    floatBits(real_, scalarType(field.type)),
                );
                fieldBytes[] = raw[0 .. fieldSize];
                continue;
            }
            return false;
        }
        return true;
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

    private void storeDynamicArrayPlace(
        Place place,
        in DynamicArrayLocal descriptor,
    ) {
        final switch (place.kind) with (Place.Kind) {
            case frame:
                if (place.offset != descriptor.offset)
                    _code ~= Instruction(
                        Op.copy,
                        place.offset,
                        descriptor.offset,
                        cast(ushort) sliceDescriptorSize,
                    );
                return;
            case captured:
                _code ~= Instruction(
                    Op.frameStore,
                    descriptor.offset,
                    capturedFrameIndex(
                        _capturedOwners[place.declaration], place.offset,
                    ),
                    cast(ushort) sliceDescriptorSize,
                );
                return;
            case module_:
                _code ~= Instruction(
                    Op.storeModule,
                    descriptor.offset,
                    place.offset,
                    cast(ushort) sliceDescriptorSize,
                );
                return;
            case pointer:
                emitPointerStore(
                    descriptor.offset,
                    place.offset,
                    place.indexOffset,
                    sliceDescriptorSize,
                );
                return;
            case dynamicIndex:
                emitIndexStore(
                    descriptor.offset,
                    place.offset,
                    place.indexOffset,
                    sliceDescriptorSize,
                );
                return;
            case slice:
                throw new Exception("A dynamic-array slice is not a value place.");
        }
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

        // Build a throwaway {length, pointer} descriptor over `base` and go
        // through `subSliceOp` instead of the unchecked `pointerSliceOp`, so
        // an out-of-range bound throws instead of silently reading or
        // writing past the array's frame storage.
        const sourceDescriptor =
            allocateBytes(sliceDescriptorSize, size_t.sizeof);
        _code ~= Instruction(
            Op.copy,
            cast(ushort) sliceDescriptorPtrOffset(sourceDescriptor),
            address.offset,
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
        const elementType = place.sliceElementType;
        // True only for a genuine `Tarray` row (`int[][]`'s `int[]`
        // elements, `arrayElementIsDynamicArray`): each such row is its own
        // separately heap-allocated 16-byte `{length, ptr}` descriptor, a
        // reference-semantics value. A `Tsarray` row (`int[2][]`'s `int[2]`
        // elements) is NOT this shape -- its real D layout stores rows
        // inline, `T[N].sizeof`-strided, in the array's own backing store,
        // so it takes the same broadcast-fill/range-copy path below every
        // scalar or struct element already takes.
        const elementIsArray = place.sliceElementIsArray;
        const destination = place.offset;
        const elementSize = place.sliceElementSize;

        // `T[][]` (`Tarray`-row): a `T[]` row is itself just a 16-byte
        // `{length, ptr}` descriptor, the same reference-semantics value
        // every other broadcast-fill element is. There is no separately
        // heap-allocated row block to write through -- broadcasting the
        // rhs row means writing its own descriptor bytes into every
        // destination slot, aliasing every destination row to the rhs
        // row's backing storage, matching `SystemLinker`. `emitSliceFill`
        // (the same helper the non-array-element branch below uses) does
        // exactly that; a row-range rhs (another `T[][]` sub-slice) is not
        // handled here and falls through to `sliceCopy16` below, which
        // already copies each element's 16-byte descriptor by value --
        // correct for reference-typed rows.
        if (elementIsArray && rhs.type !is null &&
            sameType(rhs.type, place.sliceBaseType.toBasetype.nextOf)) {
            const value = compileExpression(rhs);
            emitSliceFill(destination, value.offset, elementSize);

            return Operand.init;
        }
        if (!elementIsArray && isBroadcastFillSource(rhs)) {
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
        // a literal element (the common case) expands directly into the
        // native {length, ptr} descriptor its 16-byte slot holds, without
        // paying for a full expression compile; a non-literal string
        // element (e.g. `[miniFormatFakeAttributes(a), "true"]`, a call
        // result alongside a literal, in `core.internal.dassert`'s unary
        // `_d_assert_fail`) falls through to the same compile-and-copy the
        // general Tarray case below uses.
        if (isStringType(elementType)) {
            const elementSize = typeFacts(elementType).byteWidth;
            foreach (elementIndex; 0 .. literal.elements.length) {
                auto element = (*literal.elements)[elementIndex];
                auto string_ = stringLiteralOf(element);
                if (string_ !is null) {
                    emitLoadStringLiteral(
                        cast(ushort) (offset + elementIndex * elementSize),
                        string_,
                    );
                    continue;
                }

                const value = compileExpression(
                    element is null ? literal.basis : element,
                );
                _code ~= Instruction(
                    Op.copy,
                    cast(ushort) (offset + elementIndex * elementSize),
                    value.offset,
                    cast(ushort) elementSize,
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

        auto equal = cast(EqualExp) expression;
        assert(equal !is null);

        if (equal.lowering !is null)
            return compileExpression(equal.lowering);

        if (equal.e1.type.toBasetype.isTypeAArray !is null)
            return compileExpression(lowerAssociativeArrayEquality(equal));

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

        // The non-nested static-array case (`equal.e1`/`equal.e2` both
        // `Tsarray`, no `Tarray` row involved): unlike the nested case
        // above, DMD leaves `equal.lowering` null here -- a static array of
        // byte-comparable elements is compared directly by bytes -- so this
        // is never shadowed by it the way the nested case would be.
        // `arrayNestingDepth`/`innermostArrayElementSize` both stop at zero
        // depth for a `Tsarray` outer type (its rows have no `Tarray`
        // descriptor to unwrap), so `emitNestedArrayEqual` reduces to the
        // same length-then-bytes compare `emitSliceEqual` did here, except
        // at any row width -- `int[3][2]`'s 12-byte rows included, which
        // `emitSliceEqual`'s fixed 1/2/4/8-byte family rejects.
        if (equal.e1.type.toBasetype.ty == TY.Tsarray &&
            equal.e2.type.toBasetype.ty == TY.Tsarray)
        {
            const left = dynamicArrayDescriptor(equal.e1).offset;
            const right = dynamicArrayDescriptor(equal.e2).offset;
            const offset = emitNestedArrayEqual(left, right, equal.e1.type);
            if (equal.op == EXP.notEqual)
                _code ~= Instruction(Op.notBool, offset, offset);
            return Operand(offset, ScalarType.bool_);
        }

        const bothDynamicArrays = equal.e1.type.toBasetype.ty == TY.Tarray &&
            equal.e2.type.toBasetype.ty == TY.Tarray &&
            dynamicArrayElementType(equal.e1.type) ==
                dynamicArrayElementType(equal.e2.type);
        if (bothDynamicArrays) {
            // A null `lowering` here means DMD decided the element is
            // byte-comparable (an integral scalar, or any depth of static
            // array bottoming out in one) and left the comparison to be
            // codegen'd directly rather than routed through
            // `object.__equals`: compare lengths, then, when they match, the
            // full byte range. A genuine array-of-arrays element (each row
            // its own separately heap-allocated descriptor) is never
            // byte-comparable this way, so DMD always gives it a real
            // `__equals` lowering instead -- the case reaching here always
            // has its elements stored inline, with no per-row descriptor,
            // which is exactly what a zero-depth structural compare
            // reduces to.
            const left = dynamicArrayDescriptor(equal.e1).offset;
            const right = dynamicArrayDescriptor(equal.e2).offset;
            const offset = emitNestedArrayEqual(left, right, equal.e1.type);
            if (equal.op == EXP.notEqual)
                _code ~= Instruction(Op.notBool, offset, offset);
            return Operand(offset, ScalarType.bool_);
        }

        // `int[] == uint[]` and similar: two dynamic arrays whose element
        // types differ but are both integral/character scalars compare
        // element-wise at each side's own width and signedness, the same
        // "common type" promotion an element-by-element `==` would apply.
        // Neither operand is byte-comparable against the other's raw
        // storage (they may differ in element width), so this cannot share
        // `emitNestedArrayEqual`'s byte-range compare above; a mixed
        // aggregate element (a struct/array pair with no common scalar
        // type) has no such promotion and stays unsupported.
        const mixedWidthDynamicArrays =
            equal.e1.type.toBasetype.ty == TY.Tarray &&
            equal.e2.type.toBasetype.ty == TY.Tarray;
        if (mixedWidthDynamicArrays) {
            const lhsElementType = dynamicArrayElementType(equal.e1.type);
            const rhsElementType = dynamicArrayElementType(equal.e2.type);
            const lhsIsNumeric = isCompoundIntegerScalar(lhsElementType) ||
                isCharacterScalar(lhsElementType);
            const rhsIsNumeric = isCompoundIntegerScalar(rhsElementType) ||
                isCharacterScalar(rhsElementType);
            if (lhsIsNumeric && rhsIsNumeric) {
                const left = dynamicArrayDescriptor(equal.e1);
                const right = dynamicArrayDescriptor(equal.e2);
                const offset = allocateBytes(1, 1);
                _code ~= Instruction(
                    Op.sliceEqualNumeric,
                    offset,
                    left.offset,
                    right.offset,
                    cast(ushort) left.elementType,
                    cast(ushort) right.elementType,
                );
                if (equal.op == EXP.notEqual)
                    _code ~= Instruction(Op.notBool, offset, offset);
                return Operand(offset, ScalarType.bool_);
            }
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

    private Expression lowerAssociativeArrayEquality(EqualExp equal) {
        import dmd.expressionsem: expressionSemantic;

        return expressionSemantic(
            new EqualExp(equal.op, equal.loc, equal.e1, equal.e2),
            _currentFunction._scope,
        );
    }

    // `dg1 == dg2` / `dg1 is dg2` (and the negated forms): a delegate is the
    // 16-byte `{functionIndex, context}` pair, whose two words sit at the
    // operand's own offset and one machine word past it.
    private Operand compileDelegateEquality(
        in ushort left,
        in ushort right,
        in bool invert,
    ) {
        return compileWordPairEquality(
            left, cast(ushort) (left + size_t.sizeof),
            right, cast(ushort) (right + size_t.sizeof),
            invert,
        );
    }

    // Bitwise equality of a two-word value, given each side's two word
    // offsets -- there is no 16-byte equality opcode, so compare the words
    // with the same short-circuiting `&&` shape `compileStructIdentity`
    // above uses for a multi-field struct, specialised to exactly two
    // fields. The caller names the two words, since a two-word value's field
    // order is its own (a slice descriptor is `{length, ptr}`, a delegate
    // `{functionIndex, context}`).
    private Operand compileWordPairEquality(
        in ushort leftFirst,
        in ushort leftSecond,
        in ushort rightFirst,
        in ushort rightSecond,
        in bool invert,
    ) {
        const result = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.loadConstant, result, constantIndex(1), 1);

        const firstEqual = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.equal8, firstEqual, leftFirst, rightFirst);
        const firstFalseJump =
            emitJumpIfFalse(Operand(firstEqual, ScalarType.bool_));

        const secondEqual = allocate(ScalarType.bool_);
        _code ~= Instruction(Op.equal8, secondEqual, leftSecond, rightSecond);
        const secondFalseJump =
            emitJumpIfFalse(Operand(secondEqual, ScalarType.bool_));

        const endJump = emitJump;
        patchJump(firstFalseJump);
        patchJump(secondFalseJump);
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

        // `a is b` on dynamic arrays (`string` included): two slices are the
        // same slice only when both descriptor words agree, so a one-word
        // comparison at the descriptor's base offset would answer with the
        // length alone -- calling two distinct allocations of equal length
        // the same slice, and an empty interior slice `null`.
        if (isDynamicArrayIdentity(identity)) {
            const left = identityDescriptorOffset(identity.e1);
            const right = identityDescriptorOffset(identity.e2);
            return compileWordPairEquality(
                cast(ushort) sliceDescriptorLengthOffset(left),
                cast(ushort) sliceDescriptorPtrOffset(left),
                cast(ushort) sliceDescriptorLengthOffset(right),
                cast(ushort) sliceDescriptorPtrOffset(right),
                identity.op == EXP.notIdentity,
            );
        }

        const lhs = compileExpression(identity.e1);
        const rhs = compileExpression(identity.e2);
        const op = identity.op == EXP.notIdentity
            ? Op.notEqual8
            : Op.equal8;
        const offset = allocate(ScalarType.bool_);
        _code ~= Instruction(op, offset, lhs.offset, rhs.offset);
        return Operand(offset, ScalarType.bool_);
    }

    // Whether `identity` compares two dynamic arrays. A bare `null` literal
    // counts as one when the other side is an array: DMD leaves such a
    // literal typed `typeof(null)` in some positions, but the comparison is
    // still the array-descriptor one.
    private static bool isDynamicArrayIdentity(IdentityExp identity) {
        import dmd.astenums: TY;

        static bool isArrayOrNull(Expression expression) {
            return expression.type.toBasetype.ty == TY.Tarray ||
                expression.isNullExp !is null;
        }

        return (identity.e1.type.toBasetype.ty == TY.Tarray ||
                identity.e2.type.toBasetype.ty == TY.Tarray) &&
            isArrayOrNull(identity.e1) && isArrayOrNull(identity.e2);
    }

    // The slice-descriptor base offset for one side of a dynamic-array
    // identity comparison. A `null` literal DMD left typed `typeof(null)`
    // has no descriptor to load, so materialise the zeroed one it denotes.
    private ushort identityDescriptorOffset(Expression expression) {
        import dmd.astenums: TY;

        if (expression.type.toBasetype.ty != TY.Tarray) {
            const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
            _code ~= Instruction(Op.nullSlice, offset);
            return offset;
        }

        return dynamicArrayDescriptor(expression).offset;
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

        const isNativeLeaf = function_.fbody is null;
        // Semantic analysis can materialize a hidden receiver or context. Do
        // it before deriving the argument layout, because this call site
        // stores arguments at that layout's offsets.
        if (!isNativeLeaf)
            registerFunction(function_);
        const layout = parameterLayout(function_);
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
            const one = compileSizeConstant(1);
            // A nested callee's context is its lexically enclosing function's
            // frame -- the caller's own frame only when the caller IS that
            // function. A callee declared in an enclosing function (a
            // template-alias lambda invoked from a sibling nested function,
            // say) instead receives that ancestor's frame, found by the same
            // received-context walk captured-variable access uses; handing it
            // the caller's own frame would make it resolve captured-variable
            // offsets against the wrong frame.
            auto parent = enclosingMethodOf(function_);
            if (parent is null || parent is _currentFunction ||
                _nestedContextOffset == ushort.max) {
                _code ~= Instruction(Op.frameBaseIndex, context);
                _code ~= Instruction(Op.addInt8, context, context, one);
            } else
                _code ~= Instruction(
                    Op.addInt8, context, enclosingFrameBase(parent), one,
                );
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
        const returnsRef = function_.type.isTypeFunction !is null &&
            function_.type.isTypeFunction.isRef;
        return callResultOperand(
            destination, call.type, returnsRef, returnType,
        );
    }

    // A native callee's `ref`/`out` parameter writes through the address the
    // FFI bridge passes it, which is the native-call argument area's own
    // staging slot (`native_call.d`'s header comment), not the caller's real
    // storage: `emitCallArgument` only ever copies the argument's current
    // VALUE into that slot. Recording the slot alongside the argument's own
    // `Place` here lets `tryCompileNativeCall` copy the slot's post-call
    // bytes back into that place once the call returns, the compile-time
    // equivalent of a VM-compiled `ref` parameter's implicit write-back.
    private struct NativeRefArgumentWriteback {
        Place place;
        ushort slot;
        Type type;
    }

    // A null return always falls through to the call site's unconditional
    // no-available-source throw, never a different path, so it is safe to
    // emit earlier arguments before a later one turns out unsupported.
    private Operand* tryCompileNativeCall(
        CallExp call,
        FuncDeclaration function_,
        in ParameterLayout layout,
        in ushort nativeStructReceiverOffset = noReceiverOffset,
        imported!"dmd.mtype".TypeStruct nativeStructReceiverType = null,
    ) {
        import dmd.astenums: STC, TY;

        const returnTy = function_.type.toBasetype.nextOf.toBasetype.ty;
        if (returnTy != TY.Tbool &&
            returnTy != TY.Tint32 && returnTy != TY.Tint64 &&
            returnTy != TY.Tuns64 &&
            returnTy != TY.Tfloat64 && returnTy != TY.Tvoid &&
            returnTy != TY.Tpointer && returnTy != TY.Tarray &&
            returnTy != TY.Tstruct && returnTy != TY.Tnoreturn)
            return null;

        auto parameterList =
            function_.type.toBasetype.isTypeFunction.parameterList;

        // `call.arguments` is null, not merely empty, for a no-argument call.
        const argumentCount = call.arguments is null ? 0 : call.arguments.length;
        auto callArgumentTypes = new Type[argumentCount];
        foreach (index; 0 .. argumentCount)
            callArgumentTypes[index] = (*call.arguments)[index].type.toBasetype;
        uint argumentAreaSize;
        // `auto`, not `const`: `emitNativeCall` stores this array into
        // `NativeCall.argumentOffsets`, a mutable field.
        auto argumentSlotOffsets =
            nativeArgumentOffsets(callArgumentTypes, argumentAreaSize);
        const argumentArea =
            allocateBytes(argumentAreaSize, nativeArgumentSlotSize);
        auto argumentTypes = new Type[argumentCount];
        NativeRefArgumentWriteback[] writebacks;
        // The return-type list above is the only compile-time gate on the
        // call as a whole. Individual arguments are not similarly gated: a
        // scalar, a string-literal `const(char)*`, a `&local` out parameter,
        // a pointer local passed by value, and a fixed `ref`/`out` scalar,
        // dynamic-array, struct, or static-array parameter each get their
        // own emission below, but any other shape (a `double`, a `float`, a
        // small int, a by-value struct, a delegate, ...) falls through to
        // the plain `emitCallArgument` call at the bottom of the loop rather
        // than bailing here. `quickbite.ffi.ffi` validation at the actual
        // native-call boundary is the real gate for those shapes; a shape it
        // rejects surfaces as the no-available-source diagnostic at run
        // time, not a compile-time decline.
        foreach (index; 0 .. argumentCount) {
            auto argument = (*call.arguments)[index];
            const slot = cast(ushort)
                (argumentArea + argumentSlotOffsets[index]);
            argumentTypes[index] = argument.type.toBasetype;

            if (index < parameterList.length) {
                auto parameter = parameterList[index];
                if (parameter !is null &&
                    (parameter.storageClass & (STC.ref_ | STC.out_)) !=
                        STC.none) {
                    const representation =
                        typeFacts(argument.type).representation;
                    if (representation == DeclarationRepresentation.scalar ||
                        representation ==
                            DeclarationRepresentation.dynamicArray ||
                        representation == DeclarationRepresentation.struct_ ||
                        representation ==
                            DeclarationRepresentation.staticArray)
                        if (auto place = placeOrNull(argument)) {
                            emitCallArgument(slot, false, argument);
                            writebacks ~= NativeRefArgumentWriteback(
                                *place, slot, argument.type,
                            );
                            continue;
                        }
                }
            }

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

            // `&local` out parameter (e.g. strtod's `&endptr`): the slot holds
            // the local's own frame address, which the callee writes through,
            // so it needs nothing the ordinary argument path does not do.
            emitCallArgument(slot, false, argument);
        }

        auto result = emitNativeCall(
            function_, argumentTypes, argumentArea, argumentSlotOffsets,
            noReceiverOffset, null, nativeStructReceiverOffset,
            nativeStructReceiverType,
        );
        foreach (writeback; writebacks) {
            const representation = typeFacts(writeback.type).representation;
            if (representation == DeclarationRepresentation.dynamicArray)
                storeDynamicArrayPlace(
                    writeback.place,
                    DynamicArrayLocal(
                        writeback.slot,
                        dynamicArrayElementType(writeback.type),
                        arrayElementIsArray(writeback.type),
                    ),
                );
            else if (representation == DeclarationRepresentation.struct_ ||
                    representation == DeclarationRepresentation.staticArray)
                // Same aggregate `Op.copy` path `storeExpressionIntoPlace`
                // uses for any other struct/static-array write: the width
                // comes from `writeback.place.valueType`, not from `value`,
                // so a plain `ScalarType.void_` operand is enough.
                storePlace(
                    writeback.place, Operand(writeback.slot, ScalarType.void_),
                );
            else
                storePlace(
                    writeback.place,
                    Operand(
                        writeback.slot,
                        scalarType(writeback.type.toBasetype),
                    ),
                );
        }
        return result;
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
        auto argumentTypes = new Type[argumentCount];
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
        }

        uint argumentAreaSize;
        // `auto`, not `const`: `emitNativeCall` stores this array into
        // `NativeCall.argumentOffsets`, a mutable field.
        auto argumentSlotOffsets =
            nativeArgumentOffsets(argumentTypes, argumentAreaSize);
        const argumentArea =
            allocateBytes(argumentAreaSize, nativeArgumentSlotSize);
        foreach (index; 0 .. argumentCount)
            emitCallArgument(
                cast(ushort) (argumentArea + argumentSlotOffsets[index]),
                false,
                (*call.arguments)[index],
            );

        return emitNativeCall(
            function_,
            argumentTypes,
            argumentArea,
            argumentSlotOffsets,
            receiver.offset,
            receiverType,
        );
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

    // A direct native call's own per-argument layout: argument `index`'s
    // byte offset relative to the call's argument area, packed back to back
    // in argument order. Each argument gets at least `nativeArgumentSlotSize`
    // bytes, and its own `typeFacts` byte width when that is wider (a struct
    // or static array), so a wide aggregate cannot spill into the next
    // argument's own slot the way a fixed `nativeArgumentSlotSize` stride
    // would. `argumentAreaSize` receives the total byte count to reserve for
    // the whole area. `tryCompileNativeCall` and `tryCompileNativeTypeInfoCall`
    // are this function's only two callers, so it is the one place a direct
    // call's argument layout is computed; both `emitCallArgument`'s slot
    // addressing and `NativeCall.argumentOffsets` (read by
    // `native_call.d`'s `prepareNativeInvocation`) use its result rather
    // than re-deriving offsets of their own.
    private ushort[] nativeArgumentOffsets(
        Type[] argumentTypes,
        out uint argumentAreaSize,
    ) {
        import std.algorithm.comparison: max;

        auto offsets = new ushort[argumentTypes.length];
        uint offset = 0;
        foreach (index, type; argumentTypes) {
            const facts = typeFacts(type);
            const alignment = facts.alignment == 0 ? 1 : facts.alignment;
            offset = (offset + alignment - 1) & ~(alignment - 1);
            offsets[index] = cast(ushort) offset;
            offset += max(nativeArgumentSlotSize, facts.byteWidth);
        }
        argumentAreaSize = offset;
        return offsets;
    }

    // Emit the native-call table entry and instruction shared by every native
    // libc call shape: the argument bytes already live at `argumentArea`, at
    // the offsets `argumentOffsets` records.
    private Operand* emitNativeCall(
        FuncDeclaration function_,
        Type[] argumentTypes,
        in ushort argumentArea,
        ushort[] argumentOffsets,
        in ushort nativeClassReceiverOffset = noReceiverOffset,
        imported!"dmd.mtype".TypeClass nativeClassReceiverType = null,
        in ushort nativeStructReceiverOffset = noReceiverOffset,
        imported!"dmd.mtype".TypeStruct nativeStructReceiverType = null,
    ) {
        import dmd.astenums: TY;

        // `auto`, not `const`: `pointerElementScalar` below needs a mutable
        // `Type` and DMD's `toBasetype`/`nextOf` are non-const methods.
        auto returnType = function_.type.toBasetype.nextOf;
        const returnFacts = typeFacts(returnType);
        // A dynamic-array return (e.g. `gc_getArrayUsed`'s `void[]`) has no
        // scalar tag; it is a 16-byte {length, ptr} slice descriptor, the same
        // shape every other array-typed frame slot uses.
        const isArrayReturn = returnType.toBasetype.ty == TY.Tarray;
        // A struct return (e.g. `GC.qalloc`'s `BlkInfo`, libc's `div_t`) is an
        // inline block sized and aligned to the struct's own layout, the same
        // shape every other struct-by-value result uses.
        const isStructReturn = returnType.toBasetype.ty == TY.Tstruct;
        const returnScalar = isArrayReturn || isStructReturn
            ? ScalarType.void_
            : scalarType(returnType.toBasetype);
        // A `ref`-returning native function (e.g. `core.stdc.errno.errno`'s
        // libc-mangled accessor) yields the callee's own storage address, not
        // a value; the destination slot is a raw pointer, matching a
        // VM-compiled `ref`-returning call's own result slot.
        auto functionType = function_.type.toBasetype.isTypeFunction;
        const returnsRef = functionType !is null && functionType.isRef;
        const destination = returnsRef
            ? allocateBytes(cast(uint) size_t.sizeof, size_t.sizeof)
            : isStructReturn
                ? allocateBytes(
                    returnFacts.byteWidth,
                    returnFacts.alignment,
                )
                : isArrayReturn
                    ? allocateBytes(sliceDescriptorSize, size_t.sizeof)
                    : allocate(returnScalar);
        const nativeIndex = _program.nativeCalls.length;
        _program.nativeCalls ~=
            NativeCall(
                function_,
                argumentTypes,
                nativeClassReceiverOffset,
                nativeClassReceiverType,
                nativeStructReceiverOffset,
                nativeStructReceiverType,
                argumentOffsets,
            );
        _code ~= Instruction(
            Op.nativeCall,
            cast(ushort) nativeIndex,
            argumentArea,
            destination,
        );
        // A `ref` return's address dereferences through `compileExpression`'s
        // `CallExp` handling (rvalue read) or wraps directly via
        // `resolvePlace`'s `pointerPlace` (lvalue use), exactly like a
        // VM-compiled `ref`-returning call's result.
        if (returnsRef)
            return new Operand(
                destination, ScalarType.ulong_, true, returnScalar,
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

    // `s ~= someDchar` (`CatDcharAssignExp`): dmd leaves `.lowering` null
    // here, because its hooks (`_d_arrayappendcd`/`_d_arrayappendwd`,
    // druntime's non-importable rt/lifetime.d) have no D declaration
    // anywhere semantic analysis can see -- this is the one construction
    // site where the backend, not dmd, names the callee. Declaring the two
    // hooks as ordinary `extern(C)` D source and parsing it through the
    // same frontend pipeline every other module goes through
    // (`quickbite.frontend.compiler.parseSnippet`) yields real,
    // semantically-resolved `FuncDeclaration`s; compiling a `CallExp`
    // against one of those (`append.e1`/`append.e2` unchanged -- no
    // representation conversion, matching the destination's own {length,
    // ptr} descriptor bit for bit) then runs entirely through the ordinary
    // body-less-function call path (`compileCall` -> `tryCompileNativeCall`
    // -> `resolveCallable`/`dlsym`), including that path's `ref`-parameter
    // write-back.
    private Operand compileDcharAppend(CatDcharAssignExp append) {
        import dmd.astenums: TY;
        import dmd.expression: VarExp;

        const elementTy = append.e1.type.toBasetype.nextOf.toBasetype.ty;
        auto function_ = nativeDcharAppendFunction(
            elementTy == TY.Twchar ? "_d_arrayappendwd" : "_d_arrayappendcd",
        );

        auto arguments = new Expressions();
        arguments.push(append.e1);
        arguments.push(append.e2);
        auto call = new CallExp(
            append.loc, new VarExp(append.loc, function_, false), arguments,
        );
        call.f = function_;
        call.type = function_.type.toBasetype.nextOf;

        return compileCall(call);
    }

    // `_d_arrayappendcd`/`_d_arrayappendwd`'s `FuncDeclaration`s, keyed by
    // mangled symbol name and resolved once by parsing a fixed `extern(C)`
    // prototype source string through the frontend's normal snippet
    // pipeline (which already runs full semantic analysis, giving usable,
    // callable declarations -- `quickbite.frontend.compiler.parseSnippet`
    // caches by source content, so this is cheap on repeated calls too).
    private FuncDeclaration nativeDcharAppendFunction(in string symbol) {
        import quickbite.frontend.compiler: parseSnippet;
        import std.conv: text;

        if (auto existing = symbol in _nativeDcharAppendFunctions)
            return *existing;

        auto module_ = parseSnippet(dcharAppendPrototypeSource).module_;
        collectFunctionDeclarations(module_.members);

        if (auto result = symbol in _nativeDcharAppendFunctions)
            return *result;
        throw new Exception(text(
            "Missing druntime dchar-append hook in bytecode core: ", symbol,
        ));
    }

    // `extern(C)` groups sibling declarations under one `LinkDeclaration`
    // (an `AttribDeclaration`), so the module's own top-level `members`
    // holds that wrapper, not each `FuncDeclaration` directly; unwrap any
    // attribute nesting to reach them.
    private void collectFunctionDeclarations(
        imported!"dmd.arraytypes".Dsymbols* members,
    ) {
        if (members is null)
            return;
        foreach (member; *members) {
            if (auto function_ = member.isFuncDeclaration) {
                if (function_.ident !is null)
                    _nativeDcharAppendFunctions[
                        function_.ident.toString.idup
                    ] = function_;
                continue;
            }
            if (auto attribute = member.isAttribDeclaration)
                collectFunctionDeclarations(attribute.decl);
        }
    }

    private enum dcharAppendPrototypeSource = `
        extern(C) void[] _d_arrayappendcd(ref byte[] x, dchar c);
        extern(C) void[] _d_arrayappendwd(ref byte[] x, dchar c);
    `;

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
        return callResultOperand(
            destination, call.type, returnsRef, returnType,
        );
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
        return callResultOperand(
            destination, call.type, returnsRef, returnType,
        );
    }

    // `f(...)` through a delegate-typed PARAMETER: the callee is a run-time
    // value, so there is no specific `FuncDeclaration` whose own frame layout
    // the argument area could be built from (as `compileDelegateCall` does
    // for a delegate local). Every callee reachable through a delegate VALUE
    // -- a struct method, a class method, or a nested function/lambda --
    // carries a single pointer-sized context word at frame offset 0, ahead of
    // the declared parameters, matching the delegate pair's own `context`
    // word verbatim (a struct method's receiver address there, same as any
    // other pointer-width context). Building the argument area from the
    // declared delegate type alone therefore lines up with the real callee's
    // own registered layout for every shape.
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
            Op.callIndirect, descriptorOffset, argumentArea, destination,
        );
        return callResultOperand(
            destination, call.type, functionType.isRef, returnType,
        );
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
        return callResultOperand(
            destination, functionType.next, functionType.isRef, returnType,
        );
    }

    private Operand callResultOperand(
        in ushort offset,
        Type type,
        in bool returnsRef,
        in ResultType resultType,
    ) {
        if (returnsRef)
            return refReturnOperand(offset, type);

        const facts = typeFacts(type);
        final switch (facts.representation) with (DeclarationRepresentation) {
        case pointer:
            return Operand(
                offset, ScalarType.ulong_, true,
                pointerElementScalar(type),
            );
        case classPointer:
            return Operand(
                offset, ScalarType.ulong_, true, ScalarType.void_,
            );
        case unavailable:
        case scalar:
        case staticArray:
        case vector:
        case dynamicArray:
        case struct_:
        case delegate_:
        case lazyDelegate:
        case assocArray:
        case complexDouble:
            return Operand(offset, resultType.scalar);
        }
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

    // An IIFE (`() { return expr; }()`) is compiled by evaluating `expr`
    // directly in the caller's own context rather than a real nested-function
    // call: cheaper, and it still needs no context/capture wiring, because
    // any variable `expr` reads is one the caller already owns (a capture
    // read merely resolves through the SAME machinery a direct reference
    // in the caller's own body would -- `compileExpression`'s VarExp
    // handling and `placeOrNull` route a captured declaration through its
    // real owning frame regardless of how deeply the read is nested
    // syntactically). Callers that recognise a specific shape of `expr`
    // (e.g. `placeOrNull`'s constructor-call receiver handling) must apply
    // this same unwrapping themselves before testing that shape, or an
    // IIFE wrapping it silently falls back to a plainer, receiver-unaware
    // path (issue #509's second, narrower finding).
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
        import std.conv: text;

        if (isReference) {
            emitReferenceArgument(slot, argument);
            return;
        }

        if (argument.type is null)
            throw new Exception(text(
                "Unsupported call argument in bytecode core: ",
                expressionChars(argument),
            ));

        const facts = typeFacts(argument.type);
        final switch (facts.representation) with (DeclarationRepresentation) {
        case struct_:
            const source = structOperandOffset(argument);
            _code ~= Instruction(
                Op.copy, slot, source, cast(ushort) facts.byteWidth,
            );
            return;
        case staticArray:
        case vector:
            auto place = placeOrNull(argument);
            assert(place !is null);
            const source = loadPlace(*place);
            _code ~= Instruction(
                Op.copy, slot, source.offset, cast(ushort) facts.byteWidth,
            );
            return;
        case delegate_:
            const source = delegateOperandOffset(argument);
            _code ~= Instruction(
                Op.copy, slot, source, cast(ushort) facts.byteWidth,
            );
            return;
        case dynamicArray:
            // A static-array whole slice passed to a callee aliases its frame
            // storage. Keep the general materialisation path below for result
            // values, whose bytes must outlive this VM invocation.
            auto staticSource = argument;
            while (auto cast_ = staticSource.isCastExp)
                staticSource = cast_.e1;
            if (auto slice = staticSource.isSliceExp)
                if (slice.lwr is null && slice.upr is null)
                    staticSource = slice.e1;
            if (staticSource.type !is null &&
                typeFacts(staticSource.type).representation == staticArray)
                if (auto place = placeOrNull(staticSource)) {
                    const source = addressOfPlace(*place);
                    const element = staticSource.type.toBasetype.nextOf;
                    const count = typeFacts(staticSource.type).byteWidth /
                        typeFacts(cast(Type) element).byteWidth;
                    _code ~= Instruction(
                        Op.copy, cast(ushort) sliceDescriptorPtrOffset(slot),
                        source.offset,
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
        case complexDouble:
            const source = compileComplexDoubleOperand(argument);
            _code ~= Instruction(
                Op.copy, slot, source.offset, cast(ushort) facts.byteWidth,
            );
            return;
        case scalar:
        case pointer:
        case classPointer:
        case assocArray:
            const operand = compileExpression(argument);
            _code ~= Instruction(
                Op.copy, slot, operand.offset, cast(ushort) facts.byteWidth,
            );
            return;
        case unavailable:
        case lazyDelegate:
            throw new Exception(text(
                "Unsupported call argument in bytecode core: ",
                expressionChars(argument),
            ));
        }
    }

    private void emitReferenceArgument(
        in ushort slot,
        Expression argument,
    ) {
        import std.conv: text;

        if (auto dot = argument.isDotVarExp)
            if (auto name = tryTypeidName(dot)) {
                const address = addressOperand(
                    Op.frameAddress, name.offset, ScalarType.void_,
                );
                _code ~= Instruction(
                    Op.copy, slot, address.offset, cast(ushort) size_t.sizeof,
                );
                return;
            }

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

        if (compileMessageAssert(assert_))
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

    // A plain `assert(cond)` with no message left over after the literal
    // branches above: any runtime condition under a `checkaction=context`-less
    // parse keeps `assert_.msg is null`; `compileMessageAssert` handles every
    // shape that has a message. Compiled code aborts on failure with
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

    // `assert(cond, message)` with a message: compile `cond` (the same
    // is-null-normalised way `compilePlainAssert` does) and, only on the
    // failing path, compile `message` -- an ordinary expression, whatever
    // shape it is -- and throw its result. This covers every shape DMD gives
    // `.msg` alike: a plain user string, DMD's own verbatim text for a
    // `&&`/`||`/`!` condition, and, under `-checkaction=context`, a call to
    // `core.internal.dassert`'s `_d_assert_fail!(...)` template. The last
    // case needs no recognition here -- it is just a call expression whose
    // real druntime body formats the operands, so compiling it like any
    // other call reproduces compiled code's message exactly. A
    // compile-time-false condition (`assert(false, msg)`) needs no separate
    // case either: its compiled condition operand is a constant `false`, so
    // the jump below is never taken and the throw always runs.
    private bool compileMessageAssert(AssertExp assert_) {
        if (assert_.msg is null)
            return false;

        const condition = compileBoolCondition(assert_.e1);
        const skipJump = emitJumpIfTrue(condition);
        const messageOffset = compileExpression(assert_.msg).offset;
        _code ~= Instruction(
            Op.throwString,
            messageOffset,
            noExceptionClass,
            noCatchObjectField,
        );
        patchJump(skipJump);
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

    // `a == b` / `a != b` over struct values with no `opEquals` (DMD lowers
    // this to a bitwise `is`/`!is`, dispatched here from
    // `compileEqualExpression`): compare the two inline blocks field by field
    // and combine the per-field results with `&&`, yielding a bool.
    // Field-wise comparison sizes each compare by the field's scalar type,
    // ignoring inter-field padding.
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

    // The `sliceCopy*` family's emit helper, the same required-`width`
    // treatment as `emitSubSlice` above: one opcode per width (1/2/4/8/16,
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

        // `RT function(Parameters!T) ...`-style function-pointer
        // reconstruction (e.g. `core.internal.dassert`'s
        // `assumeFakeAttributes`, reached indirectly from every
        // `_d_assert_fail` call via `inFinalizer`) splices a template alias
        // sequence into a parameter list. DMD keeps that splice as a single
        // `Ttuple`-typed parameter here rather than flattening it away,
        // including the empty sequence a zero-parameter callee (like
        // `GC.inFinalizer`) produces. Recurse over the tuple's own elements
        // -- each with its own storage class -- instead of treating the
        // tuple itself as an opaque, unsupported parameter type.
        if (auto tuple = type.toBasetype.isTypeTuple) {
            import dmd.astenums: STC;

            if (tuple.arguments !is null)
                foreach (element; *tuple.arguments) {
                    const elementIsReference = (element.storageClass &
                        (STC.ref_ | STC.out_ | STC.auto_)) != STC.none;
                    appendParameterLayoutEntry(
                        layout, element.type, elementIsReference,
                    );
                }
            return;
        }

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
                argumentAlign = facts.alignment;
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

    // A function result follows the same representation classification used
    // for storage and call arguments; each arm adds only its result/display
    // metadata.
    private ResultType resultType(Type type) {
        import std.conv: text;

        const facts = typeFacts(type);
        final switch (facts.representation) with (DeclarationRepresentation) {
        case dynamicArray:
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
        case staticArray:
            if (arrayElementIsString(type))
                return ResultType(
                    scalar: ScalarType.void_,
                    isArray: true,
                    elementType: dynamicArrayElementType(type),
                    arrayElementsAreArrays: arrayElementIsArray(type),
                    isStruct: false,
                    structSize: facts.byteWidth,
                    isUndisplayable: false,
                    isStaticArray: true,
                    arrayLength: staticArrayLength(type),
                    arrayElementsAreStrings: true,
                );
            return ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: true,
                structSize: facts.byteWidth,
            );
        case vector:
            return ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: true,
                structSize: facts.byteWidth,
            );
        case struct_:
            auto result = ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: true,
                structSize: facts.byteWidth,
            );
            populateStructDisplay(result, type);
            return result;
        case delegate_:
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
        case unavailable:
        case lazyDelegate:
            return ResultType(
                scalar: ScalarType.void_,
                isArray: false,
                elementType: ScalarType.void_,
                arrayElementsAreArrays: false,
                isStruct: false,
                structSize: 0,
                isUndisplayable: true,
            );
        case pointer:
        case classPointer:
        case assocArray:
            return ResultType.scalarResult(ScalarType.ulong_);
        case scalar:
            return ResultType.scalarResult(
                facts.opcodeType,
                enumMembersByValue(type),
            );
        case complexDouble:
            throw new Exception(text(
                "Unsupported function result in bytecode core: ",
                typeChars(type),
            ));
        }
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
        // a throwaway {length, ptr} descriptor instead of the array's own
        // bytes.
        if (array.type.toBasetype.ty == TY.Tsarray) {
            const offset = allocateStructBlock(array.type);
            compileStaticArrayLiteral(offset, array.type, array);
            return Operand(offset, ScalarType.void_);
        }

        const elementType = dynamicArrayElementType(array.type);
        const offset = allocateBytes(sliceDescriptorSize, size_t.sizeof);
        compileDynamicArrayInto(
            offset, elementType, array,
            arrayElementIsDynamicArray(array.type),
        );
        return Operand(offset, ScalarType.void_, false, elementType);
    }

    // The aggregate-vs-scalar classification is `typeFacts`': a struct,
    // static array, or delegate element is a full-width byte blob
    // (`byteWidth`), everything else is a plain scalar. A `Tarray` element
    // (`int[][]`'s rows) is itself sized this same way: its `byteWidth` is
    // the 16-byte `{length, ptr}` slice descriptor, the real layout every
    // row of a genuine dynamic array of dynamic arrays holds. `Tvoid` stays
    // a hand-checked special case: D defines `void[]` with a one-byte
    // element stride even though `void` is not a loadable scalar value.
    private uint dynamicArrayElementSize(Type type) {
        import dmd.astenums: TY;

        auto element = type.toBasetype.nextOf;
        if (element.toBasetype.ty == TY.Tvoid)
            return 1;
        return typeFacts(element).byteWidth;
    }

    // True when an array's element is itself an array (`int[][]` or
    // `string[2]`): the row is compound rather than a plain scalar. Used
    // where the two compound shapes (a genuine `Tarray` row and a `Tsarray`
    // row) still need the same treatment, e.g. structural equality, which
    // must recurse into either shape instead of comparing raw bytes.
    private bool arrayElementIsArray(Type type) {
        import dmd.astenums: TY;

        auto element = type.toBasetype.nextOf.toBasetype;
        return element.ty == TY.Tarray || element.ty == TY.Tsarray;
    }

    // True only when an array's element is itself a genuine dynamic array
    // (`int[][]`'s `int[]` rows): each row is a separately heap-allocated
    // 16-byte `{length, ptr}` slice descriptor. A `Tsarray` element
    // (`int[2][]`'s `int[2]` rows) is NOT this shape -- `T[N][]`'s real D
    // layout stores its rows inline, `T[N].sizeof`-strided, with no
    // descriptor of their own, so it needs the same construction and
    // addressing a struct-element array already gets, not a slice
    // descriptor of its own.
    private bool arrayElementIsDynamicArray(Type type) {
        import dmd.astenums: TY;

        auto element = type.toBasetype.nextOf.toBasetype;
        return element.ty == TY.Tarray;
    }

    private bool arrayElementIsString(Type type) {
        return isStringType(type.toBasetype.nextOf);
    }

    // The number of nested `Tarray`-row descriptor unwrap steps
    // `Op.sliceEqualNested` needs below its own outer descriptor, for an
    // array-of-arrays type gated by `arrayElementIsArray` (`T[]` whose
    // element is itself compound): 1 for `int[][]` (one further `Tarray`
    // row level, each its own separately heap-allocated 16-byte
    // descriptor), 2 for `int[][][]`, and so on. Walks the chain of
    // `Tarray` elements one level at a time, the same way
    // `arrayElementIsArray` and `innermostArrayElementSize` do, stopping as
    // soon as a level's element is not itself a `Tarray`. A `Tsarray`
    // element (e.g. `int[2][]`) contributes NO further step: unlike a
    // `Tarray` row, `T[N][]`'s real D layout stores its rows inline,
    // `T[N].sizeof`-strided, with no descriptor of its own, so once the
    // outer descriptor is unwrapped the rows are already element bytes,
    // ready for the base-case compare.
    private uint arrayNestingDepth(Type type) {
        import dmd.astenums: TY;

        uint steps;
        auto current = type.toBasetype;
        while (arrayElementIsArray(current)) {
            auto nextBase = current.nextOf.toBasetype;
            if (nextBase.ty != TY.Tarray)
                break;
            ++steps;
            current = nextBase;
        }
        return steps;
    }

    // The byte width of the innermost row's own elements for an
    // array-of-arrays type gated by `arrayElementIsArray`: 4 for both
    // `int[][]`'s and `int[][][]`'s `int` leaves (a `Tarray` row's own
    // elements, once every descriptor level `arrayNestingDepth` counts is
    // unwrapped). A chain terminating in a `Tsarray` row (`int[2][]`) has no
    // such unwrapped leaf level to size -- the row itself, inline and
    // `T[N].sizeof`-wide, is what the base-case byte compare needs, so this
    // returns the row's own full width (8 for `int[2]`) instead of
    // recursing into its element. Walks the same `Tarray` chain as
    // `arrayNestingDepth`.
    private uint innermostArrayElementSize(Type type) {
        import dmd.astenums: TY;

        auto current = type.toBasetype;
        while (arrayElementIsArray(current)) {
            auto nextBase = current.nextOf.toBasetype;
            if (nextBase.ty != TY.Tarray)
                return typeFacts(nextBase).byteWidth;
            current = nextBase;
        }
        return dynamicArrayElementSize(current);
    }

    // Emit `Op.sliceEqualNested`, comparing two dynamic-array descriptors by
    // structural content rather than as raw descriptor bytes: for an
    // array-of-arrays element (`int[][]`, any depth), DMD's real `__equals`
    // lowering recurses into each row, so two separately heap-allocated but
    // content-equal rows must compare equal, unlike a byte compare of the
    // outer descriptor (which would compare the rows' `.ptr` values). At
    // zero nesting depth (a plain scalar element, or any depth of static
    // array bottoming out in one) this reduces to a length check plus a
    // single byte comparison of the whole element range, at any element
    // width -- unlike the fixed-width `sliceEqual*` family, there is no
    // width this rejects.
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
            // `typeof(null)`: the VM's own `null` slices/pointers/references
            // are already zeroed 8-byte values (`Op.nullSlice` and friends),
            // so a `typeof(null)`-typed value (a bare `null` literal passed
            // where its context has not yet cast it to a concrete type, e.g.
            // an operand `core.internal.dassert`'s `_d_assert_fail!(...)`
            // formats) is the same all-zero 8-byte representation.
            case Tnull:
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

    // Shared opcode, aggregate, byte-width, and alignment classification for a
    // stored type. `pointerElementMetadata`, dynamic-array element sizing, and
    // heap field operations previously derived these facts independently, so a
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

        if (type.toBasetype.ty == TY.Terror ||
            type.toBasetype.ty == TY.Tfunction)
            return TypeFacts.withoutByteWidth(
                ScalarType.void_, DeclarationRepresentation.unavailable,
                true,
            );
        const byteWidth = cast(uint) size(type.toBasetype);
        const alignment = type.toBasetype.alignsize;
        if (isComplexDoubleType(type))
            return TypeFacts(
                ScalarType.void_, byteWidth, alignment,
                DeclarationRepresentation.complexDouble, true,
            );
        switch (type.toBasetype.ty) with (TY) {
            case Tsarray:
                return TypeFacts(
                    ScalarType.void_, byteWidth, alignment,
                    DeclarationRepresentation.staticArray, true,
                );
            case Tvector:
                return TypeFacts(
                    ScalarType.void_, byteWidth, alignment,
                    DeclarationRepresentation.vector, true,
                );
            case Tarray:
                return TypeFacts(
                    ScalarType.void_, byteWidth, alignment,
                    DeclarationRepresentation.dynamicArray, true,
                );
            case Tstruct:
                return TypeFacts(
                    ScalarType.void_, byteWidth, alignment,
                    DeclarationRepresentation.struct_, true,
                );
            case Tdelegate:
                return TypeFacts(
                    ScalarType.void_, byteWidth, alignment,
                    DeclarationRepresentation.delegate_, true,
                );
            case Tclass:
                return TypeFacts(
                    scalarType(type), byteWidth, alignment,
                    DeclarationRepresentation.classPointer, false,
                );
            case Tpointer:
                return TypeFacts(
                    scalarType(type), byteWidth, alignment,
                    DeclarationRepresentation.pointer, false,
                );
            case Taarray:
                return TypeFacts(
                    scalarType(type), byteWidth, alignment,
                    DeclarationRepresentation.assocArray, false,
                );
            default:
                return TypeFacts(
                    scalarType(type), byteWidth, alignment,
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
    private uint _alignment;
    private bool _hasAlignment;

    private this(
        in ScalarType opcodeType,
        in uint byteWidth,
        in uint alignment,
        in DeclarationRepresentation representation,
        in bool isAggregate,
    ) @safe pure {
        this.opcodeType = opcodeType;
        this.representation = representation;
        this.isAggregate = isAggregate;
        _byteWidth = byteWidth;
        _hasByteWidth = true;
        _alignment = alignment;
        _hasAlignment = true;
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
            cast(uint) size(opcodeType),
            DeclarationRepresentation.scalar, false,
        );
    }

    private uint byteWidth() @safe pure const {
        if (!_hasByteWidth)
            throw new Exception("Byte width is unavailable");
        return _byteWidth;
    }

    private uint alignment() @safe pure const {
        if (!_hasAlignment)
            throw new Exception("Alignment is unavailable");
        return _alignment;
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
// native {length, ptr} descriptor's own {index, length} literal-load operand
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

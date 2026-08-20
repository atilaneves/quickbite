module quickbite.backends.interpreter.impl;


private:


public class Interpreter: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator:
        Evaluator,
        EvalResult,
        ReplSession;
    import quickbite.backends.interpreter.frame_block: FrameBlock;
    import quickbite.backends.interpreter.frame_layout: cachedFrameLayout;
    import quickbite.backends.interpreter.module_table: ModuleTable;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    public alias eval = Evaluator.eval;

    // Module-level guest state has module lifetime, not per-execution
    // lifetime: a global written by one unittest is still written when the
    // next one runs. One table, shared by every execution of this backend
    // instance, is what makes that true.
    private ModuleTable* _moduleTable;
    // A class reference stored in such a global outlives the execution that
    // created it, but its dynamic class and owning allocation live outside
    // the guest bytes, keyed by body address. They describe the same storage
    // the module table holds, so they share its lifetime: drop them at the
    // end of an execution and a surviving reference loses the identity that
    // makes a virtual call dispatch to the original object.
    private imported!"dmd.mtype".Type[void*] _nativeClassTypes;
    private imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate[void*] _nativeClassOwners;
    // A function-local struct instance stored in such a global keeps working
    // across the boundary too: its hidden context field names the same
    // enclosing-activation chain the module table's bytes already anchor, so
    // this table shares their lifetime for exactly the same reason.
    private FrameBlock[][void*] _nestedContextFrames;

    private enum ExecutionMode {
        regular,
        unitTest,
        formatted,
    }

    public this() @safe @nogc nothrow pure {
    }

    public this(const string[] dependencyImages) {
        import quickbite.ffi.ffi: loadDependencyImages;

        loadDependencyImages(dependencyImages);
    }

    public this(
        const imported!"quickbite.ffi.ffi".DependencyImage[] dependencyImages,
    ) {
        import quickbite.ffi.ffi: loadDependencyImages;

        loadDependencyImages(dependencyImages);
    }

    public override bool supportsReplPreludeFormatter() const
    @safe @nogc nothrow pure {
        return true;
    }

    public override EvalResult eval(FuncDeclaration function_) {
        return execute(function_, ExecutionMode.regular);
    }

    protected override EvalResult executeUnitTest(
        UnitTestDeclaration unitTest,
    ) {
        return execute(unitTest, ExecutionMode.unitTest);
    }

    public override EvalResult evalFormattedDisplay(FuncDeclaration function_) {
        return execute(function_, ExecutionMode.formatted);
    }

    private EvalResult execute(
        FuncDeclaration function_,
        in ExecutionMode mode,
    ) {
        try {
            import quickbite.backends.interpreter.frame_layout:
                clearFrameLayoutCache;

            clearFrameLayoutCache;
            Walker walker;
            scope(exit) {
                _nativeClassTypes = walker.nativeClassTypes;
                _nativeClassOwners = walker.nativeClassOwners;
                _nestedContextFrames = walker.nestedContextFrames;
                walker.closeDurableInboundSession;
            }
            walker._executionState = new InterpreterExecutionState;
            walker._executionState.invokeNativeCallback =
                &walker.invokeNativeCallback;
            if (_moduleTable is null)
                _moduleTable = new ModuleTable;
            walker.moduleTable = _moduleTable;
            walker.nativeClassTypes = _nativeClassTypes.dup;
            walker.nativeClassOwners = _nativeClassOwners.dup;
            walker.nestedContextFrames = _nestedContextFrames.dup;
            walker.inUnitTest = mode == ExecutionMode.unitTest;
            import quickbite.frontend.dmd.functions: ensureFunctionBodySemantic;

            ensureFunctionBodySemantic(function_);
            auto layout = cachedFrameLayout(function_);
            walker._activationFrame = FrameBlock.allocate(layout);

            // A top-level `return expr;` inside `function_.fbody` reaches
            // `setReturnValue`, which always constructs into a destination:
            // give the whole run one, typed by the function's own return
            // type, the same way a nested call receives its caller's.
            import quickbite.backends.interpreter.layout:
                typeByteSize, typeHasPointers;
            import quickbite.backends.interpreter.native_block: NativeBlock;
            import quickbite.backends.interpreter.place: Place;

            auto returnType = function_.type.toBasetype.isTypeFunction.next;
            auto returnBlock = NativeBlock.allocate(
                typeByteSize(returnType),
                typeHasPointers(returnType)
                    ? NativeBlock.Scan.conservative
                    : NativeBlock.Scan.no,
            );
            auto rootDestination = ConstructionDestination(Place(returnBlock.address, returnType));
            walker._returnDestination = &rootDestination;

            walker.runStatement(function_.fbody);
            final switch (mode) with (ExecutionMode) {
            case regular:
            case unitTest:
                return EvalResult("");
            case formatted:
                return EvalResult(formattedDisplay(walker.readStoredValue(rootDestination.place)));
            }
        } catch (Exception exception) {
            // The interpreter's own message, verbatim: rewriting it through
            // DMD's CTFE engine (as an earlier revision did) replaced the
            // real, actionable error with whichever body-less leaf CTFE
            // happened to reject.
            return EvalResult(EvalResult.Diagnostic(exception.msg));
        }
    }

    public override ReplSession createReplSession() {
        return new InterpreterReplSession(this);
    }
}

private class InterpreterReplSession:
    imported!"quickbite.backends.evaluator".ReplSession {
    private Interpreter _interpreter;

    public this(Interpreter interpreter) {
        _interpreter = interpreter;
    }

    public override imported!"quickbite.backends.evaluator".EvalResult submit(
        imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        if (cell.evalCell.displayIsFormatted)
            return _interpreter.evalFormattedDisplay(cell.evalCell.function_);

        return _interpreter.eval(cell.evalCell);
    }
}

private bool isTransparentArrayCastTarget(imported!"dmd.mtype".Type type) {
    import quickbite.frontend.dmd.types: isArrayType;

    return isArrayType(type);
}

private string formattedDisplay(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    // `readScalarLeaf`, not the generic `readValue`: a formatted-display
    // root is always a character array (the repl's own display-function
    // contract), so each element place is already known to be a native
    // character scalar -- `readValue`'s enum/aggregate dispatch ahead of
    // its own native-scalar arm would never fire here.
    import quickbite.backends.interpreter.place_value: readScalarLeaf;

    auto aggregate = AggregateValue.native(value);
    char[] display;
    foreach (index; 0 .. AggregateValue.elementCount(value))
        display ~= readScalarLeaf(AggregateValue.elementAt(aggregate, index)).asUtf8Character;
    return display.idup;
}


private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult characterArrayValue(
    ref Walker walker,
    imported!"dmd.mtype".Type type,
    in string characters,
) {
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    ExpressionResult[] elements;
    foreach (character; characters)
        elements ~= ExpressionResult(character);
    return walker.reconstructStoredArray(type, elements);
}


private enum LoopControl {
    none,
    break_,
    continue_,
}

// A caller-provided typed destination for rvalue construction. An absent
// destination represents a void construction; a fresh destination becomes
// constructed exactly once. Only a caller that owns fresh storage may provide
// a destination; assignment must first obtain separate temporary storage.
private struct ConstructionDestination {
    private enum State {
        absent,
        fresh,
        constructed,
    }

    private imported!"quickbite.backends.interpreter.place".Place _place;
    private State _state;

    public this(imported!"quickbite.backends.interpreter.place".Place place)
    @safe {
        _place = place;
        _state = State.fresh;
    }

    public bool hasDestination() const pure nothrow @nogc @safe {
        return _state != State.absent;
    }

    public bool isFresh() const pure nothrow @nogc @safe {
        return _state == State.fresh;
    }

    public bool isConstructed() const pure nothrow @nogc @safe {
        return _state == State.constructed;
    }

    public imported!"quickbite.backends.interpreter.place".Place place() @safe {
        if (!hasDestination)
            throw new Exception(
                "quickbite.backends.interpreter.impl.ConstructionDestination."
                ~ "place: construction has no destination",
            );
        return _place;
    }

    public void markConstructed() @safe {
        if (!isFresh)
            throw new Exception(
                "quickbite.backends.interpreter.impl.ConstructionDestination."
                ~ "markConstructed: destination is not fresh",
            );
        _state = State.constructed;
    }
}

// The evaluated indices within one `ref`/`out` call argument.  The ordinary
// expression walk records them as it evaluates the argument; binding the
// callee's reference slot later composes its address from those exact results
// rather than evaluating an index expression again.
private struct EvaluatedReferenceArgument {
    public size_t[const(void)*] indices;
    public void* address;
    public imported!"dmd.expression".Expression selectedLvalue;
}

// One call owns its evaluated values, source expressions, and `ref`/`out`
// address metadata. Zero- and one-argument calls stay entirely in the caller's
// stack value. Larger calls lay the three aligned arrays into one scanned GC
// block, so evaluation performs exactly one allocation independent of the
// arrays' growth policies while retaining the existing slice-shaped seams.
private struct CallArguments {
    private size_t _length;
    private void* _storage;
    private imported!"quickbite.backends.interpreter.expression_result".
        ExpressionResult _singleValue;
    private imported!"dmd.expression".Expression _singleExpression;
    private EvaluatedReferenceArgument _singleReference;

    public this(in size_t length) {
        import core.memory: GC;

        _length = length;
        if (length <= 1)
            return;

        _storage = GC.malloc(storageByteLength(length));
        values[] = typeof(_singleValue).init;
        expressions[] = null;
        references[] = EvaluatedReferenceArgument.init;
    }

    // @trusted: `_storage` is either null or the base pointer returned by
    // this value's own `GC.malloc` call. Call sites release the uncopied
    // staging value only after every slice derived from it is dead.
    public void release() pure nothrow @nogc @trusted {
        import core.memory: GC;

        auto storage = _storage;
        _storage = null;
        GC.free(storage);
    }

    public @property size_t length() const @safe @nogc nothrow pure {
        return _length;
    }

    public @property imported!"quickbite.backends.interpreter.expression_result".
        ExpressionResult[] values()
    {
        if (_length == 0)
            return null;
        if (_length == 1)
            return (&_singleValue)[0 .. 1];
        return (cast(typeof(_singleValue)*) _storage)[0 .. _length];
    }

    public @property imported!"dmd.expression".Expression[] expressions() {
        if (_length == 0)
            return null;
        if (_length == 1)
            return (&_singleExpression)[0 .. 1];
        return (cast(typeof(_singleExpression)*) (
            cast(ubyte*) _storage + expressionsOffset(_length)
        ))[0 .. _length];
    }

    public @property EvaluatedReferenceArgument[] references() {
        if (_length == 0)
            return null;
        if (_length == 1)
            return (&_singleReference)[0 .. 1];
        return (cast(EvaluatedReferenceArgument*) (
            cast(ubyte*) _storage + referencesOffset(_length)
        ))[0 .. _length];
    }

    private static size_t storageByteLength(in size_t length)
    @safe @nogc nothrow pure {
        return referencesOffset(length) +
            EvaluatedReferenceArgument.sizeof * length;
    }

    private static size_t expressionsOffset(in size_t length)
    @safe @nogc nothrow pure {
        return alignOffset(
            typeof(_singleValue).sizeof * length,
            typeof(_singleExpression).alignof,
        );
    }

    private static size_t referencesOffset(in size_t length)
    @safe @nogc nothrow pure {
        return alignOffset(
            expressionsOffset(length) +
                typeof(_singleExpression).sizeof * length,
            EvaluatedReferenceArgument.alignof,
        );
    }

    private static size_t alignOffset(
        in size_t offset,
        in size_t alignment,
    ) @safe @nogc nothrow pure {
        return (offset + alignment - 1) & ~(alignment - 1);
    }
}

// One native call keeps its source-order types and optional stable operands in
// one staging value. Zero and one argument stay inline; larger calls use one
// exact scanned allocation for both parallel arrays.
private struct NativeCallArguments {
    private size_t _length;
    private void* _storage;
    private imported!"dmd.mtype".Type _singleType;
    private imported!"quickbite.backends.interpreter.native_call_adapter".
        NativeOperand _singleOperand;

    public this(
        imported!"dmd.expression".Expression[] expressions,
    ) {
        import core.memory: GC;

        _length = expressions.length;
        if (_length > 1)
            _storage = GC.calloc(storageByteLength(_length));
        foreach (index, expression; expressions)
            types[index] = expression.type;
    }

    // @trusted: `_storage` is either null or the base pointer returned by
    // this value's own `GC.calloc` call. Call sites release the uncopied
    // staging value only after the synchronous native invocation returns.
    public void release() pure nothrow @nogc @trusted {
        import core.memory: GC;

        auto storage = _storage;
        _storage = null;
        GC.free(storage);
    }

    // `_storage` contains exactly `_length` Types followed by the aligned
    // NativeOperand range. These casts expose only their respective ranges.
    public imported!"dmd.mtype".Type[] types() @trusted {
        alias Type = imported!"dmd.mtype".Type;

        if (_length == 0)
            return null;
        if (_length == 1)
            return (&_singleType)[0 .. 1];
        return (cast(Type*) _storage)[0 .. _length];
    }

    public imported!"quickbite.backends.interpreter.native_call_adapter".
        NativeOperand[] operands() @trusted {
        alias NativeOperand = imported!"quickbite.backends.interpreter.native_call_adapter".
            NativeOperand;

        if (_length == 0)
            return null;
        if (_length == 1)
            return (&_singleOperand)[0 .. 1];
        return (cast(NativeOperand*) (
            cast(ubyte*) _storage + operandsOffset(_length)
        ))[0 .. _length];
    }

    private static size_t storageByteLength(
        in size_t length,
    ) @safe @nogc nothrow pure {
        alias NativeOperand = imported!"quickbite.backends.interpreter.native_call_adapter".
            NativeOperand;

        return operandsOffset(length) + NativeOperand.sizeof * length;
    }

    private static size_t operandsOffset(
        in size_t length,
    ) @safe @nogc nothrow pure {
        alias NativeOperand = imported!"quickbite.backends.interpreter.native_call_adapter".
            NativeOperand;
        alias Type = imported!"dmd.mtype".Type;

        return alignOffset(Type.sizeof * length, NativeOperand.alignof);
    }

    private static size_t alignOffset(
        in size_t offset,
        in size_t alignment,
    ) @safe @nogc nothrow pure {
        return (offset + alignment - 1) / alignment * alignment;
    }
}

private struct UninitializedBindings {
    public bool[void*] addresses;
}

// Owners for raw addresses produced during one recursive expression walk.
// Child walkers share the active scope so a callee can return a newly
// allocated address to its caller. Once the outer expression has stored that
// address in a scanned frame, module, object, or aggregate block, ordinary GC
// scanning supplies the durable root and the temporary owner is released.
private struct TemporaryPointerOwners {
    public imported!"quickbite.backends.interpreter.native_block".NativeBlock[]
        blocks;
    public size_t expressionDepth;
}

// One in-progress full expression: where its shared temporary owners and its
// own queued destructors begin, and whether it is outermost by either
// measure. `outermost` is the shared-blocks boundary (see
// `TemporaryPointerOwners`); `localOutermost` is this walker's own
// destructor boundary -- a function call is a full-expression boundary for
// the callee's internals, so it does not chain off the caller's depth.
private struct FullExpression {
    public size_t firstOwner;
    public size_t firstDestructor;
    public bool outermost;
    public bool localOutermost;
}

// Native places for class array-literal `.init` fields, keyed by the address
// of DMD's initializer node. The pointer indirection keeps the table shared
// when the first insertion happens in a child walker.
private struct ClassArrayFieldDefaults {
    public imported!"quickbite.backends.interpreter.native_block".NativeBlock[
        const(void)*] table;
}

// The live dynamic-call chain used only when a newly created closure needs to
// retain the activation that owns one of its captured addresses. Links point
// into synchronous caller Walkers, so constructing a call allocates nothing.
private struct FrameMetadataLifetime {
    public imported!"quickbite.backends.interpreter.frame_block".FrameBlock* frame;
    public bool* retained;
    public FrameMetadataLifetime* caller;
}

// `nativeDelegateSlots`' payload: a live delegate is either an opaque
// native-code {context, funcptr} pair (ffi.md §35.8) or the interpreter's
// own callable id, looked up again in `_executionState.delegates` for the
// full `RuntimeDelegate`. The two shapes share one table, keyed by the
// delegate-typed slot's own address, but never share a representation.
private struct DelegateSlot {
    public bool isNative;
    public const(void)* context;
    public const(void)* funcptr;
    public size_t functionPointerId;
}

private DelegateSlot delegateSlotValue(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
) {
    return value.isNativeDelegate
        ? DelegateSlot(true, value.nativeDelegateContext, value.nativeDelegateFuncptr, 0)
        : DelegateSlot(false, null, null, value.functionPointerId);
}

private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult
    delegateSlotResult(in DelegateSlot slot)
{
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    return slot.isNative
        ? ExpressionResult.nativeDelegateValue(slot.context, slot.funcptr)
        : ExpressionResult.functionPointerValue(slot.functionPointerId);
}

// A thrown/chained exception's own class identity and a member-function
// delegate's receiver are both, at the native layer, either an owned
// `NativeAggregate` (a locally constructed exception; a struct receiver's
// own storage) or a bare class body address with no aggregate of its own
// (a host-owned exception object's identity; a class receiver, whose place
// address already IS its body address). `nativeAggregateFrom` builds the
// single `NativeAggregate` representation both shapes settle into: the
// owned case keeps its storage unchanged, and the address-only case borrows
// a view sized from `type`'s own layout, so the block's `NativeBlock.
// Ownership` -- not a separate flag -- records that it may not be
// reallocated. Retention is unaffected either way: the owned arm keeps
// exactly the block it already held reachable, and a borrowed block owns
// nothing to retain.
private imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate
    nativeAggregateFrom(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
        imported!"dmd.mtype".Type type,
    )
{
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.layout: classInstanceByteSize;

    if (value.isNativeAggregate)
        return AggregateValue.native(value);

    return NativeAggregate(
        type,
        NativeBlock.borrow(
            value.pointerAddress,
            classInstanceByteSize(type.toBasetype.isTypeClass.sym),
        ),
    );
}

// The inverse: re-boxes a class-identity/receiver `NativeAggregate` back to
// `ExpressionResult` for the generic field-read/write code that both
// exception handling and delegate dispatch share. Dispatches on the
// aggregate's own type, not a flag: a class body has no separate carrier of
// its own, so it re-boxes as its bare address; a struct keeps its full
// native aggregate.
private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult
    expressionResultFrom(
        imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate aggregate,
    )
{
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    return aggregate.type.toBasetype.isTypeClass !is null
        ? ExpressionResult.pointerValue(cast(void*) aggregate.storage.address)
        : ExpressionResult.nativeAggregateValue(aggregate);
}

// One root evaluation owns this context, and every nested call borrows it.
// Callable identities are monotonic, but address-keyed slot metadata follows
// storage lifetime: writes replace it and copies, moves, and clears relocate or
// remove it. Callees publish every change immediately; unwinding never merges
// a private snapshot, and the context dies with the evaluation.
// Maps containing ExpressionResults or Throwables also keep the native storage
// they describe reachable for as long as an address may cross activations.
private struct InterpreterExecutionState {
    // Native code may retain a callback installed by any nested activation.
    // The root's dispatcher remains live for the whole evaluation, and every
    // child borrows the same session through this shared execution state.
    public imported!"quickbite.backends.interpreter.native_call_adapter".
        DelegateInvoker invokeNativeCallback;
    public imported!"quickbite.backends.interpreter.native_call_adapter".
        InterpreterInboundTrampolineSession* durableInboundSession;

    // Captured host Throwables and their interpreter-visible chain links are
    // created by the native exception bridge and read by later member calls.
    public Throwable[const(void)*] nativeThrowableRoots;
    public imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate[void*] nativeThrowableNext;

    // Writes to guest ABI slots register symbolic interpreted callables and
    // TypeInfos; any later activation that reads the same address must see
    // the entry, including after the writing call returns or throws.
    public size_t[const(void)*] nativeFunctionPointerSlots;
    public string[void*] nativeTypeInfoSlots;
    public DelegateSlot[void*] nativeDelegateSlots;

    // Function and delegate identities are allocated once per evaluation.
    // Both directions and the next id therefore form one shared registry.
    public imported!"dmd.func".FuncDeclaration[size_t] functionPointers;
    public size_t[imported!"dmd.func".FuncDeclaration] functionPointerIds;
    public size_t nextFunctionPointerId;
    public RuntimeDelegate[size_t] delegates;

    // Object-address metadata is installed at allocation or native ingress
    // and remains authoritative for every alias in every later activation.
    public imported!"dmd.mtype".Type[void*] nativeClassTypes;
    public imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate[void*] nativeClassOwners;
    public imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate[void*] nativeExceptionMetadata;

    // A struct declared inside a function reads that function's locals through
    // its hidden context field, and its methods can run long after the
    // enclosing activation returned. An interpreted activation is a
    // `FrameBlock`, not a guest address the field's bytes could name, so this
    // table retains the enclosing activation chain (nearest first) keyed by
    // that field's own address -- the same out-of-band shape
    // `nativeDelegateSlots` uses, and carried across value copies by
    // `copyStoredMetadata`. The retained handles keep the frames' GC-owned
    // storage alive for exactly as long as an instance can still be called.
    public imported!"quickbite.backends.interpreter.frame_block".FrameBlock[][void*]
        nestedContextFrames;
}

private class InterpretedException: Exception {
    public imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate object;

    public this(
        imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate object,
        in string message,
    ) {
        super(message);
        this.object = object;
    }
}


private string exceptionMessage(
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    // `readScalarLeaf`, not the generic `readValue`: this reads an
    // exception's `msg` field, always `string` (`char[]`, this function's
    // sole caller's own field name), so each element place is already known
    // to be a native character scalar.
    import quickbite.backends.interpreter.place_value: readScalarLeaf;

    auto aggregate = AggregateValue.native(value);
    char[] result;
    foreach (index; 0 .. AggregateValue.length(aggregate))
        result ~= readScalarLeaf(AggregateValue.elementAt(aggregate, index)).asUtf8Character;
    return result.idup;
}


private string statementLabel(imported!"dmd.identifier".Identifier identifier) {
    return identifier is null ? null : identifier.toString.idup;
}

private struct Walker {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import dmd.declaration: VarDeclaration;
    import dmd.expression: DivExp, Expression, ModExp;
    import dmd.func: FuncDeclaration;
    import dmd.statement: Statement;
    import quickbite.backends.interpreter.frame_block: FrameBlock;
    import quickbite.backends.interpreter.frame_layout: cachedFrameLayout;
    import quickbite.backends.interpreter.native_array: NativeArray;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.native_struct: NativeStruct;
    import quickbite.backends.interpreter.module_table: ModuleTable;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.runtime_values: defaultValue, defaultValueOwner;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    private TemporaryPointerOwners* _temporaryPointerOwners;
    private InterpreterExecutionState* _executionState;

    // A constructed temporary's armed destructor (see
    // `queueTemporaryDestructor`), queued here instead of run immediately, so
    // it fires once the enclosing full expression finishes evaluating, in
    // reverse construction order. Never shared with a child walker: a callee
    // runs its own statements and destroys its own temporaries at its own
    // boundaries, the same as any other full-expression evaluation.
    private imported!"dmd.expression".Expression[] _pendingTemporaryDestructors;
    private size_t _fullExpressionDepth;

    private @property ref Throwable[const(void)*] nativeThrowableRoots() {
        return _executionState.nativeThrowableRoots;
    }

    private @property ref imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate[void*] nativeThrowableNext() {
        return _executionState.nativeThrowableNext;
    }

    private @property ref size_t[const(void)*]
        nativeFunctionPointerSlots()
    {
        return _executionState.nativeFunctionPointerSlots;
    }

    private @property ref string[void*] nativeTypeInfoSlots() {
        return _executionState.nativeTypeInfoSlots;
    }

    private @property ref DelegateSlot[void*] nativeDelegateSlots() {
        return _executionState.nativeDelegateSlots;
    }

    private @property ref FuncDeclaration[size_t] functionPointers() {
        return _executionState.functionPointers;
    }

    private @property ref size_t[FuncDeclaration] functionPointerIds() {
        return _executionState.functionPointerIds;
    }

    private @property ref size_t nextFunctionPointerId() {
        return _executionState.nextFunctionPointerId;
    }

    private @property ref imported!"dmd.mtype".Type[void*] nativeClassTypes() {
        return _executionState.nativeClassTypes;
    }

    private @property ref FrameBlock[][void*] nestedContextFrames() {
        return _executionState.nestedContextFrames;
    }

    private @property ref imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate[void*] nativeClassOwners() {
        return _executionState.nativeClassOwners;
    }

    private @property ref imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate[void*] nativeExceptionMetadata() {
        return _executionState.nativeExceptionMetadata;
    }

    // Non-null only while `runRefArgumentExpression` is walking one call
    // argument.  `runIndexExpression` records its already-evaluated result in
    // the active argument's identity-keyed table; nested calls save and
    // restore this pointer around their own argument evaluation.
    private size_t[const(void)*]* _evaluatedReferenceArgumentIndices;

    // Lazily allocated, execution-wide native `.init` places.
    private ClassArrayFieldDefaults* classArrayFieldDefaults;

    private @property ref imported!"quickbite.backends.interpreter.native_call_adapter".
        InterpreterInboundTrampolineSession* durableInboundSession() {
        return _executionState.durableInboundSession;
    }
    private Expression[VarDeclaration] lazyArgumentExpressions;
    // The caller's own `_activationFrame` at the moment its `lazy` argument
    // was bound. Evaluating the thunk temporarily selects that frame, whose
    // places remain the sole authority for the captured bindings.
    private FrameBlock[VarDeclaration] lazyArgumentFrames;
    // A child initially borrows both lazy maps from its caller. Before adding
    // its own binding it detaches both maps together, so calls without lazy
    // parameters do not copy the caller's accumulated bindings.
    private bool _lazyArgumentMapsBorrowed;
    // DMD may synthesize an IndexExp/SliceExp `$` length declaration after a
    // root frame layout was computed. It is expression-evaluation metadata,
    // not a D storage binding; key its native size_t by the declaration object's
    // address for the duration of this Walker.
    private size_t[const(void)*] _syntheticDollarValues;
    // `= void` is state attached to the authoritative binding address.
    private UninitializedBindings* uninitializedBindingAddresses;
    // A `ref` return's lvalue: an existing binding's address and type,
    // named directly (`addressOfRefReturn` mode). Empty (`Place.init`)
    // outside that mode.
    private Place _refReturnPlace;
    // An interpreted non-void call constructs directly into its caller's
    // fresh storage. This pointer is valid only while the synchronous child
    // activation runs; recursive calls use their own activation and pointer.
    // A void call (outside `addressOfRefReturn` mode) has none.
    private ConstructionDestination* _returnDestination;
    private bool runningCalledFunction;
    private bool inUnitTest;
    private FuncDeclaration currentFunction;

    // Per-activation native storage block. Every local binding resolves to an
    // owning or reference place in this block.
    private FrameBlock _activationFrame;
    private bool _activationFrameMetadataRetained;
    private FrameMetadataLifetime _activationFrameMetadataLifetime;
    private FrameMetadataLifetime* _callerFrameMetadataLifetime;
    // Native static links for lexically enclosing activations, nearest first.
    // The copied FrameBlock handles retain their GC-owned storage, so both a
    // direct nested call and a deeper relay can resolve the original place.
    private FrameBlock[] _enclosingFrames;

    // Module-lifetime storage for module, `static`, and `__gshared` bindings.
    // All child walkers share the same table by pointer.
    private ModuleTable* moduleTable;

    private Place thisValue;
    private void* thisAddress;
    private bool hasThis;
    private imported!"quickbite.backends.interpreter.native_aggregate".
        NativeAggregate pendingFinallyBodyException;
    private bool hasPendingFinallyBodyException;

    private bool returned;
    private bool addressOfRefReturn;
    private bool assignToRefReturn;
    private ExpressionResult refReturnAssignedValue;
    private Statement pendingGotoTarget;
    private Statement pendingSwitchTarget;
    private LoopControl loopControl;
    private string loopControlLabel;

    private void closeDurableInboundSession() {
        if (durableInboundSession !is null)
            durableInboundSession.close;
        durableInboundSession = null;
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null)
            return;

        if (statement.isSwitchErrorStatement !is null)
            return;

        if (returned || loopControl != LoopControl.none)
            return;

        if (statement is pendingSwitchTarget)
            pendingSwitchTarget = null;

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    if (skipUntilSwitchTarget(child))
                        continue;
                    if (skipUntilGotoTarget(child))
                        continue;
                    runStatement(child);
                    if (returned || loopControl != LoopControl.none)
                        break;
                }
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    if (skipUntilSwitchTarget(child))
                        continue;
                    if (skipUntilGotoTarget(child))
                        continue;
                    runStatement(child);
                    if (returned || loopControl != LoopControl.none)
                        break;
                }
            return;
        }

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto tryFinally = statement.isTryFinallyStatement) {
            Exception bodyException;
            try {
                runStatement(tryFinally._body);
            } catch (Throwable exception) {
                bodyException = cast(Exception) exception;
                if (bodyException is null)
                    throw exception;
            }

            const savedReturned = returned;
            // Only a `ref` return transports data through the activation.
            // An ordinary return has already constructed its caller-owned
            // destination before control reaches this finally body.
            // `const` cannot round-trip a `Place` (it holds a `Type` class
            // reference) back into the mutable `_refReturnPlace` below.
            auto savedRefReturn = addressOfRefReturn ? _refReturnPlace :
                Place.init;
            const savedLoopControl = loopControl;
            const savedLoopControlLabel = loopControlLabel;
            returned = false;
            loopControl = LoopControl.none;
            loopControlLabel = null;
            // `const` cannot round-trip a `NativeAggregate` either, for the
            // same reason as `savedRefReturn` above: it holds a `Type` class
            // reference.
            auto savedPendingFinallyBodyException = pendingFinallyBodyException;
            const savedHasPendingFinallyBodyException =
                hasPendingFinallyBodyException;
            if (auto bodyInterpreted = cast(InterpretedException) bodyException) {
                pendingFinallyBodyException = bodyInterpreted.object;
                hasPendingFinallyBodyException = true;
            }
            scope(exit) {
                pendingFinallyBodyException = savedPendingFinallyBodyException;
                hasPendingFinallyBodyException =
                    savedHasPendingFinallyBodyException;
            }
            try {
                runStatement(tryFinally.finalbody);
            } catch (Exception exception) {
                auto finalException = cast(InterpretedException) exception;
                if (finalException is null)
                    throw exception;
                if (auto bodyInterpreted = cast(InterpretedException) bodyException) {
                    auto bodyType = bodyInterpreted.object.type;
                    const chained = chainExceptionObject(
                        expressionResultFrom(bodyInterpreted.object),
                        finalException.object,
                    );
                    bodyInterpreted.object = nativeAggregateFrom(chained, bodyType);
                    throw bodyInterpreted;
                }
                throw finalException;
            }
            if (!returned && loopControl == LoopControl.none) {
                returned = savedReturned;
                if (returned && addressOfRefReturn)
                    _refReturnPlace = savedRefReturn;
                loopControl = savedLoopControl;
                loopControlLabel = savedLoopControlLabel;
                if (bodyException !is null)
                    throw bodyException;
            }
            return;
        }

        if (auto tryCatch = statement.isTryCatchStatement) {
            runTryCatchStatement(tryCatch);
            return;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            if (unrolled.statements !is null)
                foreach (child; *unrolled.statements) {
                    if (skipUntilSwitchTarget(child))
                        continue;
                    if (skipUntilGotoTarget(child))
                        continue;
                    runStatement(child);
                    if (returned || loopControl != LoopControl.none)
                        break;
                }
            return;
        }

        if (auto goto_ = statement.isGotoStatement) {
            if (goto_.label is null || goto_.label.statement is null)
                throw new Exception("Unsupported eval statement: Goto");

            auto label = goto_.label.statement;
            pendingGotoTarget = label.gotoTarget is null
                ? label.statement
                : label.gotoTarget;
            return;
        }

        if (auto label = statement.isLabelStatement) {
            runLabeledStatement(label);
            return;
        }

        if (statement.isImportStatement !is null)
            return;

        if (auto expression = statement.isExpStatement) {
            if (expression.exp is null)
                return;
            executeForEffect(expression.exp);
            return;
        }

        if (auto dtor = statement.isDtorExpStatement) {
            executeForEffect(dtor.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            if (return_.exp !is null) {
                if (assignToRefReturn)
                    writeLocation(return_.exp, refReturnAssignedValue);
                else
                    setReturnValue(return_.exp);
            }
            returned = true;
            return;
        }

        if (auto for_ = statement.isForStatement) {
            runForStatement(for_);
            return;
        }

        if (auto do_ = statement.isDoStatement) {
            runDoStatement(do_);
            return;
        }

        if (auto switch_ = statement.isSwitchStatement) {
            runSwitchStatement(switch_);
            return;
        }

        if (auto case_ = statement.isCaseStatement) {
            if (case_.statement is statement)
                throw new Exception("Unsupported eval statement: Case");
            runStatement(case_.statement);
            return;
        }

        if (auto default_ = statement.isDefaultStatement) {
            if (default_.statement is statement)
                throw new Exception("Unsupported eval statement: Default");
            runStatement(default_.statement);
            return;
        }

        if (auto caseRange = statement.isCaseRangeStatement) {
            if (caseRange.statement is statement)
                throw new Exception("Unsupported eval statement: CaseRange");
            runStatement(caseRange.statement);
            return;
        }

        if (auto gotoCase = statement.isGotoCaseStatement) {
            if (gotoCase.cs is null)
                throw new Exception("Unsupported eval statement: GotoCase");
            pendingSwitchTarget = gotoCase.cs;
            return;
        }

        if (auto gotoDefault = statement.isGotoDefaultStatement) {
            if (gotoDefault.sw is null || gotoDefault.sw.sdefault is null)
                throw new Exception("Unsupported eval statement: GotoDefault");
            pendingSwitchTarget = gotoDefault.sw.sdefault;
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            if (conditionTruthy(if_.condition))
                runStatement(if_.ifbody);
            else
                runStatement(if_.elsebody);
            return;
        }

        if (auto break_ = statement.isBreakStatement) {
            loopControl = LoopControl.break_;
            loopControlLabel = statementLabel(break_.ident);
            return;
        }

        if (auto continue_ = statement.isContinueStatement) {
            loopControl = LoopControl.continue_;
            loopControlLabel = statementLabel(continue_.ident);
            return;
        }

        if (auto with_ = statement.isWithStatement) {
            runWithStatement(with_);
            return;
        }

        if (auto throw_ = statement.isThrowStatement) {
            throwInterpretedException(throw_.exp);
        }

        import std.conv: text;
        throw new Exception(text(
            "Unsupported eval statement: ", statement.stmt,
            " in ", currentFunction is null ? "?" : text(currentFunction.toPrettyChars),
        ));
    }

    pragma(inline, false)
    private void runTryCatchStatement(
        imported!"dmd.statement".TryCatchStatement tryCatch,
    ) {
        try {
            runStatement(tryCatch._body);
        } catch (Exception exception) {
            auto interpreted = cast(InterpretedException) exception;
            if (interpreted is null)
                throw exception;

            const objectValue = expressionResultFrom(interpreted.object);
            auto catch_ = matchingCatch(tryCatch, objectValue);
            if (catch_ is null)
                throw exception;

            bindCatchVariable(catch_, objectValue);
            runStatement(catch_.handler);
        }
    }

    private imported!"dmd.statement".Catch matchingCatch(
        imported!"dmd.statement".TryCatchStatement tryCatch,
        in ExpressionResult object,
    ) {
        if (tryCatch.catches is null || tryCatch.catches.length == 0)
            return null;

        foreach (catch_; *tryCatch.catches)
            if (catchMatches(catch_, object))
                return catch_;

        return null;
    }

    private bool catchMatches(
        imported!"dmd.statement".Catch catch_,
        in ExpressionResult object,
    ) {
        if (catch_.type is null)
            return true;

        auto classType = catch_.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return false;

        return classHasType(object, className(classType.sym));
    }

    // Single write path for a binding. Native bytes and address-keyed
    // callable/symbolic metadata are the entire stored value.
    private void setLocal(VarDeclaration variable, ExpressionResult value) {
        import std.conv: text;

        if (
            !hasBindingPlace(variable) &&
            declarationName(variable) == "__dollar"
        ) {
            _syntheticDollarValues[cast(const(void)*) variable] =
                cast(size_t) value.asLong;
            return;
        }

        if (!hasBindingPlace(variable))
            throw new Exception(text(
                "Interpreter binding `",
                declarationName(variable),
                "` has no native place in `",
                currentFunction is null ? "<root>" : declarationName(currentFunction),
                "`.",
            ));

        // A delegate, function-pointer, or symbolic-classinfo value is never
        // `isNativeAggregate`, so `writeStoredValue`'s aggregate-metadata
        // `consumeMetadata` argument is never read on this write; the
        // general call below (with `consumeMetadata = true`) is already
        // identical for these three value kinds, so they need no dedicated
        // branch here.

        if (
            variable.type.toBasetype.isTypeClass !is null &&
            value == ExpressionResult.null_
        ) {
            writeStoredValue(bindingPlace(variable), value);
            return;
        }

        if (
            variable.type.toBasetype.isTypeClass !is null &&
            value.isPointer
        ) {
            // A by-value class parameter owns a reference slot, not a copy of
            // the object body. Keep that slot authoritative so taking the
            // parameter by `ref` forwards the same live reference rather than
            // the frame's initial null bytes.
            writeStoredValue(bindingPlace(variable), value);
            return;
        }

        writeStoredValue(bindingPlace(variable), value, true);
    }

    // Out-of-band callable and symbolic-reference entries are part of the
    // value stored in their native byte range. Copy them by byte offset so
    // unions, nested aggregates, and mixed metadata fields obey the same
    // value-copy semantics as the native bytes. Snapshot first because source
    // and destination ranges may overlap. Callers that replace temporary or
    // reallocated storage may consume its entries after the copy; ordinary D
    // value copies retain them at the source.
    private void copyStoredMetadata(
        imported!"dmd.mtype".Type type,
        void* oldAddress,
        void* newAddress,
        in bool consumeSource = false,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        copyStoredMetadataRange(
            oldAddress,
            newAddress,
            typeByteSize(type),
            consumeSource,
        );
    }

    private void copyStoredMetadataRange(
        void* oldAddress,
        void* newAddress,
        in size_t byteLength,
        in bool consumeSource = false,
    ) {
        if (
            nativeDelegateSlots.length == 0 &&
            nativeFunctionPointerSlots.length == 0 &&
            nativeTypeInfoSlots.length == 0 &&
            nestedContextFrames.length == 0
        )
            return;

        if (oldAddress is newAddress)
            return;

        size_t[] delegateOffsets;
        DelegateSlot[] delegateValues;
        size_t[] functionOffsets;
        size_t[] functionValues;
        size_t[] typeInfoOffsets;
        string[] typeInfoValues;
        foreach (offset; 0 .. byteLength) {
            auto address = cast(void*) (cast(ubyte*) oldAddress + offset);
            if (auto value = address in nativeDelegateSlots) {
                delegateOffsets ~= offset;
                delegateValues ~= *value;
            }
            if (auto value = cast(const(void)*) address in nativeFunctionPointerSlots) {
                functionOffsets ~= offset;
                functionValues ~= *value;
            }
            if (auto value = address in nativeTypeInfoSlots) {
                typeInfoOffsets ~= offset;
                typeInfoValues ~= *value;
            }
        }

        size_t[] contextOffsets;
        FrameBlock[][] contextFrames;
        foreach (offset; 0 .. byteLength) {
            auto address = cast(void*) (cast(ubyte*) oldAddress + offset);
            if (auto frames = address in nestedContextFrames) {
                contextOffsets ~= offset;
                contextFrames ~= *frames;
            }
        }

        clearStoredMetadataRange(newAddress, byteLength);

        foreach (index, offset; contextOffsets)
            nestedContextFrames[cast(void*) (cast(ubyte*) newAddress + offset)] =
                contextFrames[index];
        foreach (index, offset; delegateOffsets)
            nativeDelegateSlots[cast(void*) (cast(ubyte*) newAddress + offset)] =
                delegateValues[index];
        foreach (index, offset; functionOffsets)
            nativeFunctionPointerSlots[
                cast(const(void)*) (cast(ubyte*) newAddress + offset)
            ] = functionValues[index];
        foreach (index, offset; typeInfoOffsets)
            nativeTypeInfoSlots[cast(void*) (cast(ubyte*) newAddress + offset)] =
                typeInfoValues[index];

        if (
            consumeSource &&
            !rangesOverlap(
                cast(size_t) oldAddress,
                byteLength,
                cast(size_t) newAddress,
                byteLength,
            )
        )
            clearStoredMetadataRange(oldAddress, byteLength);
    }

    // Any write invalidates every symbolic entry whose slot overlaps the
    // overwritten bytes. This is especially important for unions: writing a
    // non-symbolic sibling still overwrites the active symbolic member.
    private void clearStoredMetadata(
        imported!"dmd.mtype".Type type,
        void* address,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        clearStoredMetadataRange(address, typeByteSize(type));
    }

    private void clearStoredMetadataRange(
        void* address,
        in size_t byteLength,
    ) {
        if (
            nativeDelegateSlots.length == 0 &&
            nativeFunctionPointerSlots.length == 0 &&
            nativeTypeInfoSlots.length == 0 &&
            nestedContextFrames.length == 0
        )
            return;

        if (byteLength == 0)
            return;

        const start = cast(size_t) address;
        enum precedingBytes = 2 * (void*).sizeof - 1;
        const prefixLength = start < precedingBytes ? start : precedingBytes;
        const scanStart = start - prefixLength;
        const scanLength = prefixLength + byteLength;
        foreach (offset; 0 .. scanLength) {
            const candidate = scanStart + offset;
            if (
                cast(void*) candidate in nativeDelegateSlots &&
                rangesOverlap(
                    candidate,
                    2 * (void*).sizeof,
                    start,
                    byteLength,
                )
            )
                nativeDelegateSlots.remove(cast(void*) candidate);
            if (
                cast(const(void)*) candidate in nativeFunctionPointerSlots &&
                rangesOverlap(
                    candidate,
                    (void*).sizeof,
                    start,
                    byteLength,
                )
            )
                nativeFunctionPointerSlots.remove(cast(const(void)*) candidate);
            if (
                cast(void*) candidate in nativeTypeInfoSlots &&
                rangesOverlap(
                    candidate,
                    (void*).sizeof,
                    start,
                    byteLength,
                )
            )
                nativeTypeInfoSlots.remove(cast(void*) candidate);
            if (
                cast(void*) candidate in nestedContextFrames &&
                rangesOverlap(
                    candidate,
                    (void*).sizeof,
                    start,
                    byteLength,
                )
            )
                nestedContextFrames.remove(cast(void*) candidate);
        }
    }

    private static bool rangesOverlap(
        in size_t firstStart,
        in size_t firstLength,
        in size_t secondStart,
        in size_t secondLength,
    ) @safe @nogc nothrow pure {
        return firstStart < secondStart + secondLength &&
            secondStart < firstStart + firstLength;
    }

    // Writes one typed place and keeps its out-of-band symbolic TypeInfo
    // identity under the same value-copy rules as the place's native bytes.
    private void writeStoredValue(
        imported!"quickbite.backends.interpreter.place".Place place,
        in ExpressionResult value,
        in bool consumeMetadata = false,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place_value: clearPlace, writeValue;

        import dmd.astenums: TY;

        // Still reached: `runClassInfoExpression`/`runTypeidExpression` fall
        // back to this display-name form for a guest-only class with no
        // resolvable host `TypeInfo_Class` symbol, and that result reaches
        // this write through the ordinary assignment/construction paths.
        if (place.type.toBasetype.isTypeClass !is null && value.isTypeName) {
            clearStoredMetadata(place.type, place.address);
            nativeTypeInfoSlots[place.address] = value.asTypeNameString;
            clearPlace(place);
            return;
        }

        // Still reached: `constructInto`'s `DelegateExp` arm passes
        // `runDelegateExpression`'s result straight here to land in
        // `nativeDelegateSlots`.
        if (place.type.toBasetype.ty == TY.Tdelegate && value != ExpressionResult.null_) {
            clearStoredMetadata(place.type, place.address);
            nativeDelegateSlots[place.address] = delegateSlotValue(value);
            clearPlace(place);
            return;
        }

        auto pointerType = place.type.toBasetype.isTypePointer;
        // Still reached: `constructInto`'s function-typed `SymOffExp` arm
        // passes `functionPointerValue`'s result straight here to land in
        // `nativeFunctionPointerSlots`.
        if (
            pointerType !is null &&
            pointerType.nextOf.toBasetype.isTypeFunction !is null &&
            value.isFunctionPointer
        ) {
            clearStoredMetadata(place.type, place.address);
            nativeFunctionPointerSlots[place.address] = value.functionPointerId;
            place.storeReference(null);
            return;
        }

        if (value.isNativeAggregate)
            copyStoredMetadata(
                place.type,
                AggregateValue.native(value).address,
                place.address,
                consumeMetadata,
            );
        else
            clearStoredMetadata(place.type, place.address);

        writeValue(place, value);
    }

    // A by-value load materializes fresh aggregate storage. Copy the symbolic
    // slot identity into that value while retaining it at the source place.
    private ExpressionResult readStoredValue(
        imported!"quickbite.backends.interpreter.place".Place place,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_call_adapter:
            NativeOperand, nativeDelegateMetadata;
        import quickbite.backends.interpreter.place_value: readValue;

        import dmd.astenums: TY;

        // Still reached: this is the general "read a delegate-typed place"
        // path; `runCallExpression`'s callee dispatch and `equalDelegateValues`
        // derive their `DelegateSlot` from evaluating the callee/operand
        // expression, which bottoms out here for a plain variable or field
        // read.
        if (place.type.toBasetype.ty == TY.Tdelegate) {
            if (auto delegate_ = place.address in nativeDelegateSlots) {
                return delegateSlotResult(*delegate_);
            } else {
                const delegate_ = nativeDelegateMetadata(
                    NativeOperand(place.type, place.address),
                );
                return delegate_.isNull
                    ? ExpressionResult.null_
                    : ExpressionResult.nativeDelegateValue(
                        delegate_.context,
                        delegate_.funcptr,
                    );
            }
        }
        auto pointerType = place.type.toBasetype.isTypePointer;
        // Still reached: the general "read a function-pointer-typed place"
        // path, mirroring the delegate arm above.
        if (
            pointerType !is null &&
            pointerType.nextOf.toBasetype.isTypeFunction !is null
        )
            if (
                auto function_ = cast(const(void)*) place.address
                    in nativeFunctionPointerSlots
            )
                return ExpressionResult.functionPointerValue(*function_);
        // Still reached: `.name`/`m_flags` field reads, `equalOperands`'s
        // symbolic-identity compare, and `classCastValue`'s `TypeInfo_Class`
        // narrowing all read a class-typed place generically and rely on
        // this reconstructing the registered display name.
        if (place.type.toBasetype.isTypeClass !is null)
            if (auto typeInfo = place.address in nativeTypeInfoSlots)
                return ExpressionResult.typeName(*typeInfo);

        const value = readValue(place);
        if (value.isNativeAggregate)
            copyStoredMetadata(
                place.type,
                place.address,
                AggregateValue.native(value).address,
            );
        return value;
    }

    private ExpressionResult withStoredStructField(
        in ExpressionResult receiver,
        imported!"dmd.mtype".Type receiverType,
        in size_t fieldIndex,
        in ExpressionResult fieldValue,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: Place;

        auto field = structFields(receiverType.toBasetype.isTypeStruct)[fieldIndex];
        const symbolicTypeInfo = field.type.toBasetype.isTypeClass !is null &&
            fieldValue.isTypeName;
        // A live delegate value (an interpreted closure, not `null`) has no
        // native ABI function address, so `AggregateValue.withStructField`'s
        // own `place_value.writeValue` call -- unlike `writeStoredValue`
        // below -- has no out-of-band fallback and throws for it. Seed this
        // fresh copy's field with `null` here instead; `writeStoredValue`
        // below writes the REAL `fieldValue` once `destination`'s own field
        // address is known, registering it in `nativeDelegateSlots` the same
        // way it always does for a live delegate.
        const liveDelegate = field.type.toBasetype.ty == TY.Tdelegate &&
            fieldValue != ExpressionResult.null_;
        // A function-pointer value is the same story: it's a distinct
        // `FunctionPointer` ExpressionResult variant, not a `Pointer`, so
        // `AggregateValue.withStructField`'s `place_value.writeValue` call
        // throws for it just like it does for a live delegate. Seed `null`
        // here too; `writeStoredValue` below registers it in
        // `nativeFunctionPointerSlots` once `destination`'s field address
        // is known.
        auto fieldPointerType = field.type.toBasetype.isTypePointer;
        const liveFunctionPointer = fieldPointerType !is null &&
            fieldPointerType.nextOf.toBasetype.isTypeFunction !is null &&
            fieldValue.isFunctionPointer;
        auto result = AggregateValue.withStructField(
            AggregateValue.native(receiver),
            fieldIndex,
            symbolicTypeInfo || liveDelegate || liveFunctionPointer
                ? ExpressionResult.null_
                : fieldValue,
        );
        auto source = AggregateValue.native(receiver);
        copyStoredMetadata(receiverType, source.address, result.address);

        auto fieldPlace = Place(result.address, result.type)
            .field(field);
        writeStoredValue(fieldPlace, fieldValue);
        return ExpressionResult.nativeAggregateValue(result);
    }

    private void retainTemporaryPointerOwner(NativeBlock owner) @safe {
        assert(
            _temporaryPointerOwners !is null &&
                _temporaryPointerOwners.expressionDepth != 0,
            "raw pointer owner escaped its expression scope",
        );
        _temporaryPointerOwners.blocks ~= owner;
    }

    // DMD records an expression temporary's cleanup on the synthesized
    // declaration's `edtor` (`Dsymbol_toElem` in `e2ir.d` arms it when
    // `vd.needsScopeDtor()`) rather than emitting it inline. Mirror that
    // here: arm the destructor after construction succeeds, and run every
    // armed destructor at the walker's own full-expression boundaries
    // (`endFullExpression`), in reverse construction order.
    private void queueTemporaryDestructor(
        imported!"dmd.expression".Expression destructor,
    ) @safe {
        assert(
            _fullExpressionDepth != 0,
            "temporary destructor queued outside its expression scope",
        );
        _pendingTemporaryDestructors ~= destructor;
    }

    private void storeBinding(VarDeclaration variable, in ExpressionResult value) {
        setLocal(variable, value);
        clearUninitializedBindingAddress(bindingPlace(variable).address);
    }

    private void markUninitializedBinding(VarDeclaration variable) {
        if (!hasBindingPlace(variable))
            return;
        if (uninitializedBindingAddresses is null)
            uninitializedBindingAddresses = new UninitializedBindings;
        uninitializedBindingAddresses.addresses[bindingPlace(variable).address] = true;
    }

    private bool isUninitializedBinding(VarDeclaration variable) {
        return hasBindingPlace(variable) &&
            uninitializedBindingAddresses !is null &&
            bindingPlace(variable).address in uninitializedBindingAddresses.addresses;
    }

    private void clearUninitializedBindingAddress(void* address) {
        if (uninitializedBindingAddresses !is null)
            uninitializedBindingAddresses.addresses.remove(address);
    }

    // A binding lives either in this activation or in module storage.
    private bool hasBindingPlace(VarDeclaration variable) {
        return variable.isDataseg || _activationFrame.hasSlot(variable);
    }

    // The authoritative address of a frame or module binding.
    private void* bindingAddress(VarDeclaration variable) {
        if (!variable.isDataseg)
            return _activationFrame.bindingAddress(variable);

        if (auto address = externDataSymbolAddress(variable))
            return address;

        return moduleTable.storageFor(variable);
    }

    // An extern data declaration is a binding whose storage is owned by its
    // loaded dependency image. Resolve it through the same binding constructor
    // as Interpreter-owned module state so every lvalue operation sees the
    // symbol address rather than allocating a parallel module-table block.
    private void* externDataSymbolAddress(VarDeclaration variable) {
        import quickbite.frontend.dmd.functions: isExternDataSymbol;
        import quickbite.ffi.ffi: resolveDataSymbol;

        if (!isExternDataSymbol(variable))
            return null;
        return cast(void*) resolveDataSymbol(variable);
    }

    // The one typed place for a binding's own storage: a true local's frame
    // slot or a dataseg binding's module block. Whole reads, stores, lvalue
    // composition, and reference binding all use this constructor.
    private Place bindingPlace(VarDeclaration variable) {
        import quickbite.backends.interpreter.layout: declaredType;

        return Place(bindingAddress(variable), declaredType(variable));
    }

    // `variable`'s own runtime kind (`Dsymbol.isThisDeclaration`) identifies
    // the hidden `this`/`super` parameter distinctly from every other
    // binding a `placeOfLvalue` walk can hand `resolveBase` -- `VarDeclaration`
    // (an `extern (C++)` class) is not itself `@safe`-annotated, so this is
    // the `@trusted` boundary for reading it.
    private bool isThisVariable(VarDeclaration variable) @trusted {
        return variable.isThisDeclaration !is null;
    }

    // Conservatively recognizes only lvalue
    // trees which `lvalue_place.placeOfLvalue` can compose from storage this
    // activation can actually resolve. Deciding before evaluation matters:
    // falling back after a partially-composed tree could repeat an index
    // side effect. Class receivers retain the existing path because it also
    // performs dynamic-object metadata handling which this path does not
    // replace.
    private bool hasProjectionPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression is null || expression.type is null)
            return false;

        if (auto variableExpression = expression.isVarExp) {
            auto variable = variableExpression.var.isVarDeclaration;
            return variable !is null && hasBindingPlace(variable);
        }

        // A struct method's `this`/`super` is bound onto `thisValue` for the
        // duration of this activation exactly like `bindingPlace` composes a
        // true local's own storage -- the same authority `bindThisReferenceAddress`
        // keeps `thisAddress` synchronised with. Class receivers keep the
        // existing path (see this function's own header comment).
        if (expression.isThisExp !is null || expression.isSuperExp !is null)
            return hasThis &&
                thisValue.type !is null &&
                thisValue.type.toBasetype.isTypeStruct !is null;

        if (auto index = expression.isIndexExp) {
            auto baseType = index.e1.type is null
                ? null
                : index.e1.type.toBasetype;
            if (
                baseType is null ||
                (baseType.isTypeSArray is null &&
                    baseType.isTypeDArray is null &&
                    baseType.isTypePointer is null)
            )
                return false;
            if (auto symbol = index.e1.isSymOffExp)
                return hasProjectionSymbolBase(symbol);
            return hasProjectionPlace(index.e1);
        }

        if (auto dot = expression.isDotVarExp) {
            if (
                dot.var.isVarDeclaration is null ||
                dot.e1.type is null ||
                dot.e1.type.toBasetype.isTypeStruct is null
            )
                return false;
            return hasProjectionPlace(dot.e1);
        }

        if (auto pointer = expression.isPtrExp) {
            if (auto symbol = pointer.e1.isSymOffExp)
                return hasProjectionSymbolBase(symbol);
            if (auto cast_ = pointer.e1.isCastExp)
                if (auto address = cast_.e1.isAddrExp)
                    return hasProjectionPlace(address.e1);
            return pointer.e1.type !is null &&
                pointer.e1.type.toBasetype.isTypePointer !is null &&
                hasProjectionPlace(pointer.e1);
        }

        if (auto cast_ = expression.isCastExp)
            return hasProjectionPlace(cast_.e1);

        return false;
    }

    private bool hasProjectionSymbolBase(
        imported!"dmd.expression".SymOffExp symbol,
    ) {
        auto variable = symbol.var.isVarDeclaration;
        return variable !is null && hasBindingPlace(variable);
    }

    // `placeOfLvalue` composes the storage representation of a projection.
    // A cast has no storage of its own, so it must preserve that
    // representation before a direct array operation can use the resulting
    // place. Otherwise, for example, a pointer place could be treated as an
    // array header. The value path applies the cast before it observes array
    // semantics.
    private bool hasArrayProjectionPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        if (!hasProjectionPlace(expression))
            return false;

        auto type = expression.type.toBasetype;
        if (type.isTypeSArray is null && type.isTypeDArray is null)
            return false;

        return hasRepresentationPreservingProjectionPlace(expression);
    }

    private bool hasRepresentationPreservingProjectionPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto cast_ = expression.isCastExp) {
            if (
                cast_.e1.type is null ||
                !expression.type.toBasetype.equals(cast_.e1.type.toBasetype)
            )
                return false;
            return hasRepresentationPreservingProjectionPlace(cast_.e1);
        }

        if (auto index = expression.isIndexExp) {
            if (index.e1.isSymOffExp !is null)
                return true;
            return hasRepresentationPreservingProjectionPlace(index.e1);
        }

        if (auto dot = expression.isDotVarExp)
            return hasRepresentationPreservingProjectionPlace(dot.e1);

        if (auto pointer = expression.isPtrExp) {
            if (pointer.e1.isSymOffExp !is null)
                return true;
            return hasRepresentationPreservingProjectionPlace(pointer.e1);
        }

        return expression.isVarExp !is null;
    }

    // Only storage-owned/ref-forwarded struct/array trees take the direct
    // write path. Pointer
    // dereferences retain the old path and its null/provenance diagnostics.
    private bool hasDirectWriteProjectionPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        if (!hasProjectionPlace(expression))
            return false;

        if (expression.isVarExp !is null)
            return true;
        if (auto dot = expression.isDotVarExp)
            return hasDirectWriteProjectionPlace(dot.e1);
        if (auto index = expression.isIndexExp)
            return index.e1.type !is null &&
                index.e1.type.toBasetype.isTypePointer is null &&
                hasDirectWriteProjectionPlace(index.e1);
        if (auto cast_ = expression.isCastExp)
            return hasDirectWriteProjectionPlace(cast_.e1);
        return false;
    }

    private bool isDirectProjectionWriteTarget(
        imported!"dmd.expression".Expression expression,
    ) {
        if (!hasDirectWriteProjectionPlace(expression) || expression.type is null)
            return false;

        const type = expression.type.toBasetype;
        if (type.isTypeStruct !is null || type.isTypeSArray !is null)
            return false;

        imported!"dmd.expression".IndexExp[16] indexes;
        size_t indexCount;
        if (!collectDirectWriteProjectionIndexes(expression, indexes, indexCount))
            return false;

        return true;
    }

    // An indexed storage-owned projection can always select its live element
    // place before it constructs the RHS. Unlike a whole struct/static-array
    // assignment, this does not change the surrounding assignment lowering:
    // DMD has already made any required postblit or destructor work explicit
    // around this one element assignment.
    private bool isDirectIndexAssignmentTarget(
        imported!"dmd.expression".IndexExp index,
    ) {
        imported!"dmd.expression".IndexExp[16] indexes;
        size_t indexCount;

        return hasDirectWriteProjectionPlace(index) &&
            collectDirectWriteProjectionIndexes(index, indexes, indexCount);
    }

    private bool collectDirectWriteProjectionIndexes(
        imported!"dmd.expression".Expression expression,
        ref imported!"dmd.expression".IndexExp[16] indexes,
        ref size_t count,
    ) {
        if (auto index = expression.isIndexExp) {
            if (count == indexes.length)
                return false;
            indexes[count++] = index;
            return collectDirectWriteProjectionIndexes(
                index.e1,
                indexes,
                count,
            );
        }
        if (auto dot = expression.isDotVarExp)
            return collectDirectWriteProjectionIndexes(dot.e1, indexes, count);
        if (auto cast_ = expression.isCastExp)
            return collectDirectWriteProjectionIndexes(cast_.e1, indexes, count);
        return expression.isVarExp !is null;
    }

    // Compose the addressable expression once.
    // `$` belongs to its containing index and therefore reads the base
    // place's length before that index expression runs, preserving the same
    // receiver-before-index order as `runIndexExpression`.
    private Place projectionPlace(
        imported!"dmd.expression".Expression expression,
        in bool writeBounds = false,
        scope imported!"dmd.expression".Expression[] evaluatedIndexes = null,
        scope size_t[] evaluatedIndexValues = null,
    ) {
        import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;
        import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;
        import quickbite.backends.interpreter.place: IndexOutOfBoundsException;

        assert(hasProjectionPlace(expression));
        imported!"dmd.expression".IndexExp pendingIndex;
        size_t pendingLength;
        bool pendingBoundsCheck;
        try {
            return placeOfLvalue(
                expression,
                // `placeOfLvalue`'s own `ThisExp` arm composes
                // `Place(resolveBase(variable), declaredType(variable))` for
                // the hidden `this`/`super` variable -- `addressableBindingBase`
                // cannot resolve it (DMD keeps `vthis` out of both the frame
                // and dataseg storage this activation's own bindings occupy),
                // so hand back the address `thisValue`/`thisAddress` already
                // name for this activation's receiver instead, the same
                // address `bindThisReferenceAddress` keeps them synchronised
                // with.
                (variable) @safe => isThisVariable(variable)
                    ? thisValue.address
                    : addressableBindingBase(variable),
                (indexExpression) @system {
                    size_t value;
                    bool alreadyEvaluated;
                    foreach (i, evaluated; evaluatedIndexes)
                        if (evaluated is indexExpression) {
                            value = evaluatedIndexValues[i];
                            alreadyEvaluated = true;
                            break;
                        }
                    if (!alreadyEvaluated)
                        value = scalarOperand!size_t(indexExpression);
                    if (
                        pendingBoundsCheck &&
                        pendingIndex !is null &&
                        pendingIndex.e2 is indexExpression &&
                        value >= pendingLength
                    )
                        throwRangeError(indexOutOfBoundsMessage(
                            value,
                            pendingLength,
                            isSliceValue(pendingIndex.e1),
                            writeBounds || runningCalledFunction,
                        ));
                    return value;
                },
                (index, base) @trusted {
                    pendingIndex = index;
                    pendingBoundsCheck =
                        base.type.toBasetype.isTypePointer is null;
                    if (pendingBoundsCheck)
                        pendingLength = base.arrayLength;
                    if (index.lengthVar !is null)
                        setLocal(
                            index.lengthVar,
                            ExpressionResult(pendingLength),
                        );
                },
            );
        } catch (IndexOutOfBoundsException exception) {
            throwRangeError(exception.msg);
            assert(0);
        }
    }

    // A selected lvalue write updates the
    // authoritative bytes and address-keyed metadata at that place. It does
    // not rebuild or write back any enclosing aggregate snapshot.
    private void writeProjectionPlace(
        imported!"dmd.expression".Expression target,
        in ExpressionResult value,
    ) {
        auto destination = directWriteProjectionPlace(target);
        writeStoredValue(
            destination,
            storageValue(target.type, value),
        );
        clearProjectionRootUninitialized(target);
    }

    private Place directWriteProjectionPlace(
        imported!"dmd.expression".Expression target,
        in bool writeBounds = true,
    ) {
        import quickbite.backends.interpreter.layout: staticArrayLength;
        import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;

        imported!"dmd.expression".IndexExp[16] indexes;
        size_t count;
        const collected = collectDirectWriteProjectionIndexes(
            target,
            indexes,
            count,
        );
        assert(collected);
        if (count < 2)
            return projectionPlace(target, writeBounds);

        // A dynamic-array `$` needs the selected base's runtime length before
        // its expression can run. The ordinary composer supplies that while
        // walking base-first, matching compiled D's dependency-imposed order.
        // Without that dependency, D evaluates the final bracket first.
        foreach (index; indexes[0 .. count])
            if (
                index.lengthVar !is null &&
                index.e1.type.toBasetype.isTypeSArray is null
            )
                return projectionPlace(target, true);

        imported!"dmd.expression".Expression[16] expressions;
        size_t[16] values;
        foreach (i, index; indexes[0 .. count]) {
            auto staticArray = index.e1.type.toBasetype.isTypeSArray;
            if (index.lengthVar !is null) {
                assert(staticArray !is null);
                setLocal(
                    index.lengthVar,
                    ExpressionResult(staticArrayLength(staticArray)),
                );
            }

            expressions[i] = index.e2;
            values[i] = scalarOperand!size_t(index.e2);
            if (
                staticArray !is null &&
                values[i] >= staticArrayLength(staticArray)
            )
                throwRangeError(indexOutOfBoundsMessage(
                    values[i],
                    staticArrayLength(staticArray),
                    /* isSlice */ false,
                    /* runningCalledFunction */ true,
                ));
        }

        return projectionPlace(
            target,
            true,
            expressions[0 .. count],
            values[0 .. count],
        );
    }

    private void clearProjectionRootUninitialized(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto variableExpression = expression.isVarExp) {
            auto variable = variableExpression.var.isVarDeclaration;
            if (variable !is null)
                clearUninitializedBindingAddress(bindingPlace(variable).address);
            return;
        }
        if (auto dot = expression.isDotVarExp) {
            clearProjectionRootUninitialized(dot.e1);
            return;
        }
        if (auto index = expression.isIndexExp) {
            clearProjectionRootUninitialized(index.e1);
            return;
        }
        if (auto cast_ = expression.isCastExp)
            clearProjectionRootUninitialized(cast_.e1);
    }

    // The ordinary aggregate read path materialises a void-initialised root
    // before exposing any of its bytes. A direct receiver/slice place must
    // preserve that first-read behaviour even though it skips the read.
    private void materializeProjectionRoot(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto variableExpression = expression.isVarExp) {
            auto variable = variableExpression.var.isVarDeclaration;
            if (variable !is null && isUninitializedBinding(variable)) {
                defaultLocalValue(variable);
                clearUninitializedBindingAddress(bindingPlace(variable).address);
            }
            return;
        }
        if (auto dot = expression.isDotVarExp) {
            materializeProjectionRoot(dot.e1);
            return;
        }
        if (auto index = expression.isIndexExp) {
            materializeProjectionRoot(index.e1);
            return;
        }
        if (auto cast_ = expression.isCastExp)
            materializeProjectionRoot(cast_.e1);
    }

    // DMD declaration inspection is `@system`; the returned address is still
    // restricted to storage owned by the frame/module/native binding tables.
    //
    // Calls `materializeDatasegInitializer` before composing the address: a
    // never-touched dataseg variable's module-table block is raw zeroed
    // bytes, not its declared default value, and this is `placeOfLvalue`'s
    // `resolveBase` callback for an lvalue chain's base (a doubly-nested
    // `DotVarExp`/`IndexExp` receiver among them), which would otherwise
    // hand out an address into that never-initialized storage. A no-op for
    // a true local and for a dataseg variable already materialized.
    private void* addressableBindingBase(VarDeclaration variable) @trusted {
        materializeDatasegInitializer(variable);
        return bindingPlace(variable).address;
    }


    private bool storeSliceBinding(VarDeclaration variable, in ExpressionResult value) {
        import quickbite.backends.interpreter.native_array: NativeArray;

        if (!AggregateValue.isArray(value))
            return false;

        const nativeAddress = AggregateValue.nativeArrayAddress(value);
        if (nativeAddress is null && AggregateValue.elementCount(value) != 0)
            return false;

        auto arrayType = variable.type.toBasetype.isTypeDArray;
        auto array = NativeArray.borrow(
            arrayType.next, cast(void*) nativeAddress, AggregateValue.elementCount(value));

        array.writeSliceHeader(bindingAddress(variable));
        return true;
    }

    private void bindCatchVariable(
        imported!"dmd.statement".Catch catch_,
        in ExpressionResult object,
    ) {
        if (catch_.var is null)
            return;

        setLocal(catch_.var, object);
        clearUninitializedBindingAddress(bindingPlace(catch_.var).address);
    }


    // `assertReferenceBind` compares exactly a reference slot's typed bytes.
    private static ubyte[] frameBytesAt(void* address, in size_t length) pure nothrow @trusted {
        return (cast(ubyte*) address)[0 .. length];
    }

    private void throwInterpretedException(
        imported!"dmd.expression".Expression expression,
    ) {
        const object = constructedExpressionValue(expression);
        if (dynamicClass(object) is null)
            throw new Exception("Unsupported throw expression.");
        auto objectAggregate = nativeAggregateFrom(object, expression.type);
        if (hasPendingFinallyBodyException) {
            const chained = chainExceptionObject(
                expressionResultFrom(pendingFinallyBodyException),
                objectAggregate,
            );
            throw new InterpretedException(
                nativeAggregateFrom(chained, pendingFinallyBodyException.type),
                exceptionObjectMessage(chained),
            );
        }

        throw new InterpretedException(objectAggregate, exceptionObjectMessage(object));
    }

    private void throwNativeException(
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallException exception,
    ) {
        rootNativeException(exception);
        auto object = nativeExceptionObject(exception);
        throw new InterpretedException(object, exception.msg);
    }

    // A failed assert throws a guest `AssertError`, exactly as compiled D
    // does, so a guest `catch (AssertError)` matches it by class name and by
    // the native object's identity.
    private void throwAssertError(in string message) {
        import core.exception: AssertError;

        auto native = new AssertError(message);
        throw new InterpretedException(
            nativeExceptionBaseObject(
                message,
                native.classinfo.name,
                cast(void*) native,
            ),
            message,
        );
    }

    private void rootNativeException(
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallException exception,
    ) {
        if (exception.nativeThrowableObjectPointer !is null)
            nativeThrowableRoots[exception.nativeThrowableObjectPointer] =
                exception.nativeThrowable;

        if (exception.chainedNext !is null)
            rootNativeException(exception.chainedNext);
    }

    // Preserve each captured host Throwable's real address as its guest
    // identity. Interpreter-visible fields live in a native aggregate keyed
    // by that address, while `.next` stays address-keyed because the host link
    // is runtime-owned storage rather than a guest-layout object body.
    private imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate
    nativeExceptionObject(
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallException exception,
    ) {
        auto object = nativeExceptionBaseObject(
            exception.msg,
            exception.className,
            exception.nativeThrowableObjectPointer,
        );
        if (exception.chainedNext !is null) {
            auto next = nativeExceptionObject(exception.chainedNext);
            nativeThrowableNext[classIdentityAddress(expressionResultFrom(object))] = next;
        }

        return object;
    }

    private imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate
    nativeExceptionBaseObject(
        in string message,
        in string className,
        in const(void)* nativeObjectPointer = null,
    ) {
        import dmd.dclass: ClassDeclaration;

        auto class_ = dynamicClassDeclarationByName(className);
        if (class_ is null)
            class_ = classDeclarationByQualifiedName(className);
        if (class_ is null)
            class_ = ClassDeclaration.exception;
        if (class_ is null)
            throw new Exception("Cannot resolve native exception class.");

        auto metadataOwner = AggregateValue.allocateClass(class_.type);
        initializeNativeClassBody(this, class_.type, metadataOwner);
        auto metadata = ExpressionResult.nativeAggregateValue(metadataOwner);
        if (nativeObjectPointer !is null)
            hydrateNativeExceptionMetadata(
                metadata,
                class_,
                cast(void*) nativeObjectPointer,
            );
        if (AggregateValue.hasClassFieldNamed(metadata, "msg")) {
            import quickbite.backends.interpreter.layout: classFields, fieldName;

            imported!"dmd.mtype".Type messageType;
            foreach (field; classFields(class_))
                if (fieldName(field) == "msg") {
                    messageType = field.type;
                    break;
                }
            metadata = ExpressionResult.nativeAggregateValue(
                AggregateValue.withClassFieldNamed(
                    AggregateValue.native(metadata),
                    "msg",
                    characterArrayValue(this, messageType, message),
                ),
            );
        }

        if (nativeObjectPointer is null) {
            const address = AggregateValue.nativeClassBodyAddress(metadata);
            nativeClassTypes[address] = class_.type;
            nativeClassOwners[address] = metadata.nativeAggregate;
            return metadata.nativeAggregate;
        }

        auto address = cast(void*) nativeObjectPointer;
        nativeClassTypes[address] = class_.type;
        nativeExceptionMetadata[address] = metadata.nativeAggregate;
        return nativeAggregateFrom(ExpressionResult.pointerValue(address), class_.type);
    }

    private void hydrateNativeExceptionMetadata(
        ref ExpressionResult metadata,
        imported!"dmd.dclass".ClassDeclaration class_,
        void* nativeObjectPointer,
    ) {
        import quickbite.backends.interpreter.layout: classFields, fieldName;
        import quickbite.backends.interpreter.place: Place;

        auto destination = Place(
            AggregateValue.nativeClassBodyAddress(metadata),
            class_.type,
        );
        auto source = Place(nativeObjectPointer, class_.type);
        foreach (field; classFields(class_)) {
            const name = fieldName(field);
            if (name == "msg" || name == "_nextInChainPtr")
                continue;
            // `copyPlaceValue`, not the raw `copyFromUnchecked`: a field
            // could be a delegate/function-pointer/nested-context type carrying
            // out-of-band metadata (`ai/plans/value.md` decision 15), and
            // this destination is a class body the Walker may have already
            // populated once before -- this pairs the byte copy with the
            // same clear-then-copy invariant every other typed place write
            // in this module observes.
            copyPlaceValue(source.field(field), destination.field(field));
        }
    }

    private imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate*
    classMetadata(in ExpressionResult object) {
        if (object.isNativeAggregate)
            return null;
        const address = classIdentityAddress(object);
        if (address is null)
            return null;
        if (auto metadata = address in nativeExceptionMetadata)
            return metadata;
        return address in nativeClassOwners;
    }

    private bool classHasFieldNamed(in ExpressionResult object, in string name) {
        if (object.isNativeAggregate)
            return AggregateValue.hasClassFieldNamed(object, name);
        if (auto metadata = classMetadata(object))
            return AggregateValue.hasClassFieldNamed(
                ExpressionResult.nativeAggregateValue(*metadata),
                name,
            );
        return false;
    }

    private ExpressionResult classFieldNamed(in ExpressionResult object, in string name) {
        if (object.isNativeAggregate)
            return readStoredValue(
                AggregateValue.classFieldNamed(AggregateValue.native(object), name),
            );
        if (auto metadata = classMetadata(object))
            return readStoredValue(
                AggregateValue.classFieldNamed(*metadata, name),
            );
        throw new Exception("Class field metadata is unavailable.");
    }

    private ExpressionResult withClassFieldNamed(
        in ExpressionResult object,
        in string name,
        in ExpressionResult field,
    ) {
        if (object.isNativeAggregate)
            return ExpressionResult.nativeAggregateValue(
                AggregateValue.withClassFieldNamed(AggregateValue.native(object), name, field),
            );
        if (auto metadata = classMetadata(object)) {
            *metadata = AggregateValue.withClassFieldNamed(*metadata, name, field);
            return object;
        }
        throw new Exception("Class field metadata is unavailable.");
    }

    private string exceptionObjectMessage(in ExpressionResult object) {
        return classHasFieldNamed(object, "msg")
            ? exceptionMessage(classFieldNamed(object, "msg"))
            : "";
    }

    private ExpressionResult chainExceptionObject(
        in ExpressionResult thrown,
        imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate next,
    ) {
        if (!classHasFieldNamed(thrown, "_nextInChainPtr"))
            return thrown;

        const chained = withClassFieldNamed(thrown, "_nextInChainPtr", expressionResultFrom(next));
        nativeThrowableNext[classIdentityAddress(chained)] = next;
        return chained;
    }

    private bool isThrowableConstructor(
        imported!"dmd.func".FuncDeclaration function_,
    ) const {
        auto class_ = function_.parent is null
            ? null
            : function_.parent.isClassDeclaration;
        if (class_ is null)
            return false;

        const name = className(class_);
        if (name == "Throwable" || name == "Exception" || name == "Error")
            return true;

        return false;
    }

    private ExpressionResult applyThrowableConstructor(
        in ExpressionResult object,
        in ExpressionResult[] arguments,
    ) {
        if (dynamicClass(object) is null || arguments.length == 0)
            return object;

        auto result = withClassFieldNamed(object, "msg", arguments[0]);
        if (
            arguments.length >= 4 &&
            dynamicClass(arguments[3]) !is null &&
            classHasFieldNamed(result, "_nextInChainPtr")
        )
            result = withClassFieldNamed(
                result,
                "_nextInChainPtr",
                arguments[3],
            );

        return result;
    }

    private ExpressionResult runThisConstructorCall(
        imported!"dmd.func".FuncDeclaration function_,
        in ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments,
    ) {
        if (!hasThis)
            throw new Exception("Unsupported eval call.");

        const receiverCarrier = receiverValue(thisValue);
        if (dynamicClass(receiverCarrier) !is null && isThrowableConstructor(function_)) {
            thisValue = receiverPlaceFrom(
                applyThrowableConstructor(receiverCarrier, arguments),
                thisValue.type,
            );
            return receiverValue(thisValue);
        }

        // A delegating constructor (`this(...)` forwarding to another
        // constructor, as std.stdio.File's string constructor does): run the
        // target constructor directly into this constructor's own receiver
        // storage, so its writes land in `thisValue` without a round trip
        // through a carrier.
        if (function_.isConstructorFunction) {
            auto destination = ConstructionDestination(thisValue);
            runMemberFunction(
                function_,
                null,
                receiverCarrier,
                arguments,
                argumentExpressions,
                evaluatedArguments,
                null,
                &destination,
            );
            return receiverValue(thisValue);
        }

        throw new Exception("Unsupported eval call.");
    }

    private bool isThisOrSuperExpression(
        imported!"dmd.expression".Expression expression,
    ) const {
        return
            expression.isThisExp !is null ||
            expression.isSuperExp !is null;
    }

    private bool isThisOrSuperMemberCall(
        imported!"dmd.expression".CallExp call,
    ) const {
        auto dot = call.e1.isDotVarExp;
        if (dot is null)
            return false;

        return isThisOrSuperExpression(dot.e1);
    }

    private bool skipUntilSwitchTarget(Statement statement) {
        if (pendingSwitchTarget is null)
            return false;

        if (statement is pendingSwitchTarget) {
            pendingSwitchTarget = null;
            return false;
        }

        if (statementContainsSwitchTarget(statement))
            return false;

        return true;
    }

    private bool statementContainsSwitchTarget(Statement statement) {
        if (pendingSwitchTarget is null || statement is null)
            return false;

        if (statement is pendingSwitchTarget)
            return true;

        if (auto scope_ = statement.isScopeStatement)
            return statementContainsSwitchTarget(scope_.statement);

        if (auto label = statement.isLabelStatement)
            return statementContainsSwitchTarget(label.statement);

        if (auto case_ = statement.isCaseStatement)
            return statementContainsSwitchTarget(case_.statement);

        if (auto default_ = statement.isDefaultStatement)
            return statementContainsSwitchTarget(default_.statement);

        if (auto caseRange = statement.isCaseRangeStatement)
            return statementContainsSwitchTarget(caseRange.statement);

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    if (statementContainsSwitchTarget(child))
                        return true;
            return false;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    if (statementContainsSwitchTarget(child))
                        return true;
            return false;
        }

        if (auto unrolled = statement.isUnrolledLoopStatement) {
            if (unrolled.statements !is null)
                foreach (child; *unrolled.statements)
                    if (statementContainsSwitchTarget(child))
                        return true;
            return false;
        }

        return false;
    }

    private bool skipUntilGotoTarget(Statement statement) {
        if (pendingGotoTarget is null)
            return false;

        if (statement is pendingGotoTarget) {
            pendingGotoTarget = null;
            return false;
        }

        if (auto label = statement.isLabelStatement) {
            if (
                label.statement is pendingGotoTarget ||
                label.gotoTarget is pendingGotoTarget
            ) {
                pendingGotoTarget = null;
                return false;
            }
        }

        return true;
    }

    private void runLabeledStatement(imported!"dmd.statement".LabelStatement label) {
        const name = statementLabel(label.ident);

        if (auto for_ = label.statement.isForStatement)
            runForStatement(for_, name);
        else if (auto do_ = label.statement.isDoStatement)
            runDoStatement(do_, name);
        else
            runStatement(label.statement);

        if (
            loopControl == LoopControl.break_ &&
            loopControlLabel !is null &&
            loopControlLabel == name
        )
            clearLoopControl;
    }

    private void runWithStatement(
        imported!"dmd.statement".WithStatement with_,
    ) {
        if (with_.wthis !is null) {
            auto initializer = with_.wthis._init.isExpInitializer;
            if (initializer is null)
                throw new Exception("Interpreter with receiver has no initializer.");
            setLocal(
                with_.wthis,
                storageValue(with_.wthis.type, constructedExpressionValue(initializer.exp)),
            );
            runStatement(with_._body);
        } else {
            runStatement(with_._body);
        }
    }

    private void runSwitchStatement(
        imported!"dmd.statement".SwitchStatement switch_,
    ) {
        auto target = switchTarget(switch_);
        if (target is null)
            return;

        auto savedPendingSwitchTarget = pendingSwitchTarget;
        pendingSwitchTarget = target;

        while (
            !returned &&
            loopControl == LoopControl.none &&
            pendingSwitchTarget !is null
        ) {
            auto targetBeforeRun = pendingSwitchTarget;
            runStatement(switch_._body);
            if (pendingSwitchTarget is targetBeforeRun)
                throw new Exception("Unsupported eval statement: Switch");
        }

        if (loopControl == LoopControl.break_ && loopControlLabel is null)
            clearLoopControl;

        pendingSwitchTarget = savedPendingSwitchTarget;
    }

    private Statement switchTarget(
        imported!"dmd.statement".SwitchStatement switch_,
    ) {
        if (switch_.cases !is null) {
            foreach (case_; *switch_.cases) {
                if (case_ is null)
                    continue;
                if (caseMatches(case_, switch_.condition))
                    return case_;
            }
        }

        return switch_.sdefault;
    }

    private bool caseMatches(
        imported!"dmd.statement".CaseStatement case_,
        imported!"dmd.expression".Expression condition,
    ) {
        import dmd.astenums: TY;

        switch (condition.type.toBasetype.ty) with (TY) {
            case Tbool: return scalarCaseMatches!bool(case_, condition);
            case Tint8: return scalarCaseMatches!byte(case_, condition);
            case Tuns8, Tchar: return scalarCaseMatches!ubyte(case_, condition);
            case Tint16: return scalarCaseMatches!short(case_, condition);
            case Tuns16, Twchar: return scalarCaseMatches!ushort(case_, condition);
            case Tint32: return scalarCaseMatches!int(case_, condition);
            case Tuns32, Tdchar: return scalarCaseMatches!uint(case_, condition);
            case Tint64: return scalarCaseMatches!long(case_, condition);
            case Tuns64: return scalarCaseMatches!ulong(case_, condition);
            default: return false;
        }
    }

    private bool scalarCaseMatches(T)(
        imported!"dmd.statement".CaseStatement case_,
        imported!"dmd.expression".Expression condition,
    ) {
        const value = scalarOperandAs!T(condition);
        if (case_.exp !is null)
            return value == scalarOperandAs!T(case_.exp);

        auto range = case_.statement is null
            ? null
            : case_.statement.isCaseRangeStatement;
        if (range is null)
            return false;

        return
            value >= scalarOperandAs!T(range.first) &&
            value <= scalarOperandAs!T(range.last);
    }

    private void runForStatement(
        imported!"dmd.statement".ForStatement for_,
        in string label = null,
    ) {
        runStatement(for_._init);

        while (
            !returned &&
            loopControl == LoopControl.none &&
            (for_.condition is null || conditionTruthy(for_.condition))
        ) {
            runStatement(for_._body);
            if (returned)
                break;
            if (loopControl == LoopControl.break_) {
                if (loopControlLabel is null || loopControlLabel == label)
                    clearLoopControl;
                break;
            }
            if (loopControl == LoopControl.continue_) {
                if (loopControlLabel !is null && loopControlLabel != label)
                    break;
                clearLoopControl;
            }
            if (for_.increment !is null)
                executeForEffect(for_.increment);
        }
    }

    private void runDoStatement(
        imported!"dmd.statement".DoStatement do_,
        in string label = null,
    ) {
        do {
            runStatement(do_._body);
            if (returned)
                break;
            if (loopControl == LoopControl.break_) {
                if (loopControlLabel is null || loopControlLabel == label)
                    clearLoopControl;
                break;
            }
            if (loopControl == LoopControl.continue_) {
                if (loopControlLabel !is null && loopControlLabel != label)
                    break;
                clearLoopControl;
            }
        } while (conditionTruthy(do_.condition));
    }

    private void clearLoopControl() {
        loopControl = LoopControl.none;
        loopControlLabel = null;
    }

    // This function's callers reach it for a value in a wider range of
    // static shapes than `constructedExpressionValue`'s own ~30 call sites
    // ever pass through construction: an unsized dereferenced-function-
    // pointer type, a void-typed call kept only for a side effect, and (found
    // empirically, via the full gate) at least one `constructInto` arm that
    // answers a shape it was never exercised against with a wrong value
    // rather than declining it (`constructPointerExpressionInto`'s `CastExp`
    // branch, a `*p`-shaped pointer operand). Routing every caller through
    // `constructedExpressionValue` is therefore not byte-identical without
    // also auditing or extending `constructInto`'s own coverage, which is
    // explicitly out of scope for this flip (`constructInto` is consumed
    // here, not extended). This keeps the walk-only entry.
    private ExpressionResult runExpressionValue(imported!"dmd.expression".Expression expression) {
        const full = beginFullExpression;
        scope(exit) endFullExpression(full);

        return runExpressionImpl(expression);
    }

    // Construct an rvalue in caller-owned typed storage. `runExpressionImpl`'s
    // per-arm dispatch is used only as a bridge for expression kinds
    // `constructInto`/`constructScalarExpressionInto` do not yet construct
    // directly; each bridged arm retires once its own construction arm
    // lands. The bridged value is adapted to the destination's own type
    // before it is written -- `storageValue`'s existing byte-reinterpreting
    // view for a `void[]` destination (e.g. `__traits(initSymbol, T)`, whose
    // evaluated value is `T`-shaped even though the expression's static type
    // is `void[]`) and its scalar-cast fallback both apply here exactly as
    // they do at every other caller-owned-storage site.
    private void runExpression(
        imported!"dmd.expression".Expression expression,
        ref ConstructionDestination destination,
    ) {
        const full = beginFullExpression;
        scope(exit) endFullExpression(full);

        if (!constructInto(expression, destination)) {
            if (constructScalarExpressionInto(expression, destination.place)) {
                destination.markConstructed;
                return;
            }
            const value = storageValue(
                destination.place.type,
                runExpressionImpl(expression),
            );
            writeStoredValue(destination.place, value);
            destination.markConstructed;
        }
    }

    // The typed place an assert-diagnostic operand evaluates into --
    // `messages.d`'s formatters take this as their `eval` delegate's return
    // type, so an assert message reads native place bytes directly instead
    // of the expression carrier.
    private Place assertOperandPlace(imported!"dmd.expression".Expression expression) {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);
        return destination.place;
    }

    // A normal interpreted return owns its caller-provided destination. A
    // `finally` body can replace an earlier return, however, so its second
    // return first constructs a fresh typed temporary and then replaces the
    // already-complete destination. This keeps the control-flow rule without
    // reintroducing the expression carrier as the call/return channel.
    private void constructReturnValue(
        imported!"dmd.expression".Expression expression,
        ref ConstructionDestination destination,
    ) {
        if (destination.isFresh) {
            runExpression(expression, destination);
        } else {
            import quickbite.backends.interpreter.place: Place;

            auto temporary = ConstructionDestination(Place(
                _activationFrame.temporaryAddress(expression),
                expression.type,
            ));
            runExpression(expression, temporary);
            writeStoredValue(destination.place, readStoredValue(temporary.place));
        }

        // A class place stores only its body pointer. Keep the owning native
        // aggregate when a class binding is returned, just as an argument or
        // assignment does. The expression itself still constructed in the
        // typed return place; this is ownership metadata, not a return value
        // carrier.
        if (expression.type.toBasetype.isTypeClass !is null) {
            auto rooted = rootedNativeClassValue(
                expression,
                readStoredValue(destination.place),
            );
            writeStoredValue(destination.place, rooted);
        }
    }

    // Run `expression` for its effects alone: D gives a discarded
    // expression's value no observable meaning, so no value is produced and
    // none is materialised. Every statement position is such a position, and
    // so is a comma expression's left operand, a `cast(void)` operand, and a
    // `for` increment.
    private void executeForEffect(imported!"dmd.expression".Expression expression) {
        const full = beginFullExpression;
        scope(exit) endFullExpression(full);

        executeForEffectImpl(expression);
    }

    // The no-result walk itself, inside an already-open full expression --
    // an arm here exists only where the discarded value is what a whole
    // sub-walk was for. Everything else evaluates through the value path and
    // drops the result, which is what an arm for it would replace.
    private void executeForEffectImpl(imported!"dmd.expression".Expression expression) {
        // Both operands of a comma expression in a discarding position are
        // discarded: D already defines the left one's value as unused, and
        // here the whole expression's value -- the right operand's -- is
        // unused too.
        if (auto comma = expression.isCommaExp) {
            executeForEffectImpl(comma.e1);
            executeForEffectImpl(comma.e2);
            return;
        }

        // DMD lowers a tuple assignment (`target.tupleof = source.tupleof`,
        // or a `Tuple` constructor's `field[] = values[]`) into a side-effect
        // prefix followed by per-element assignments. The sequence's value is
        // its last element's, so a discarding position discards every one of
        // them.
        if (auto tuple = expression.isTupleExp) {
            if (tuple.e0 !is null)
                executeForEffectImpl(tuple.e0);
            if (tuple.exps !is null)
                foreach (element; *tuple.exps)
                    executeForEffectImpl(element);
            return;
        }

        cast(void) runExpressionImpl(expression);
    }

    // The temporaries a full expression creates live until that expression
    // ends, so their lifetime is bracketed here rather than owned by any AST
    // node. Only the outermost bracket ends the full expression: a nested
    // evaluation is part of the same one.
    private FullExpression beginFullExpression() {
        if (_temporaryPointerOwners is null)
            _temporaryPointerOwners = new TemporaryPointerOwners;

        auto full = FullExpression(
            _temporaryPointerOwners.blocks.length,
            _pendingTemporaryDestructors.length,
            _temporaryPointerOwners.expressionDepth == 0,
            _fullExpressionDepth == 0,
        );
        ++_temporaryPointerOwners.expressionDepth;
        ++_fullExpressionDepth;
        return full;
    }

    private void endFullExpression(in FullExpression full) {
        --_temporaryPointerOwners.expressionDepth;
        --_fullExpressionDepth;

        // Run every destructor armed while evaluating this full expression
        // now, in reverse construction order, before releasing its temporary
        // storage below.
        if (full.localOutermost)
            runPendingTemporaryDestructors(full.firstDestructor);

        if (!full.outermost)
            return;

        _temporaryPointerOwners.blocks.length = full.firstOwner;
    }

    // Re-entrancy-safe: a destructor's own body can construct and arm
    // further temporaries, which would clobber a slice taken up front, so
    // pop from the back instead of iterating a snapshot.
    private void runPendingTemporaryDestructors(in size_t first) {
        while (_pendingTemporaryDestructors.length > first) {
            auto destructor = _pendingTemporaryDestructors[$ - 1];
            --_pendingTemporaryDestructors.length;
            executeForEffect(destructor);
        }
    }

    private ExpressionResult runExpressionImpl(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;

        // DMD's `isX` helpers each test this same
        // discriminator. Jump straight to the one existing handler selected
        // by it instead of repeating that test for every preceding AST kind.
        switch (expression.op) with (EXP) {
        case int64:
            goto integerExpression;
        case float64:
            goto realExpression;
        case null_:
            goto nullExpression;
        case string_:
            goto stringExpression;
        case arrayLiteral:
            goto arrayLiteralExpression;
        case assocArrayLiteral:
            goto assocArrayLiteralExpression;
        case structLiteral:
            goto structLiteralExpression;
        case assert_:
            goto assertExpression;
        case not:
            goto notExpression;
        case andAnd:
        case orOr:
            goto logicalExpression;
        case cast_:
            goto castExpression;
        case equal:
        case notEqual:
            goto equalExpression;
        case identity:
        case notIdentity:
            goto identityExpression;
        case lessThan:
        case lessOrEqual:
        case greaterThan:
        case greaterOrEqual:
            goto comparisonExpression;
        case question:
            goto conditionalExpression;
        case throw_:
            goto throwExpression;
        case plusPlus:
        case minusMinus:
            goto postExpression;
        case addAssign:
            goto addAssignExpression;
        case add:
            goto addExpression;
        case min:
            goto minExpression;
        case mul:
            goto mulExpression;
        case div:
            goto divExpression;
        case mod:
            goto modExpression;
        case leftShift:
            goto leftShiftExpression;
        case rightShift:
            goto rightShiftExpression;
        case unsignedRightShift:
            goto unsignedRightShiftExpression;
        case negate:
            goto negExpression;
        case tilde:
            goto complementExpression;
        case pow:
            goto powExpression;
        case concatenate:
            goto catExpression;
        case assign:
            goto assignExpression;
        case loweredAssignExp:
            goto loweredAssignExpression;
        case construct:
            goto constructExpression;
        case blit:
            goto blitExpression;
        case concatenateAssign:
            goto concatenateAssignExpression;
        case concatenateElemAssign:
            goto concatenateElemAssignExpression;
        case concatenateDcharAssign:
            goto concatenateDcharAssignExpression;
        case minAssign:
        case mulAssign:
        case divAssign:
        case modAssign:
        case leftShiftAssign:
        case rightShiftAssign:
        case unsignedRightShiftAssign:
        case andAssign:
        case orAssign:
        case xorAssign:
            goto scalarCompoundAssignExpression;
        case or:
            goto bitOrExpression;
        case and:
            goto bitAndExpression;
        case xor:
            goto bitXorExpression;
        case comma:
            goto commaExpression;
        case tuple:
            goto tupleExpression;
        case declaration:
            goto declarationExpression;
        case call:
            goto callExpression;
        case delegate_:
            goto delegateExpression;
        case function_:
            goto functionExpression;
        case arrayLength:
            goto arrayLengthExpression;
        case slice:
            goto sliceExpression;
        case index:
            goto indexExpression;
        case new_:
            goto newExpression;
        case symbolOffset:
            goto symbolOffsetExpression;
        case star:
            goto pointerExpression;
        case address:
            goto addressExpression;
        case delegatePointer:
            goto delegatePointerExpression;
        case delegateFunctionPointer:
            goto delegateFunctionPointerExpression;
        case dotIdentifier:
            goto dotIdentifierExpression;
        case dotVariable:
            goto dotVariableExpression;
        case vector:
            goto vectorExpression;
        case vectorArray:
            goto vectorArrayExpression;
        case this_:
            goto thisExpression;
        case super_:
            goto superExpression;
        case typeid_:
            goto typeidExpression;
        case identifier:
            goto identifierExpression;
        case variable:
            goto variableExpression;
        default:
            goto unsupportedExpression;
        }

integerExpression:
        if (auto integer = expression.isIntegerExp) {
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.runtime_values: integerValue;

            auto destination = Place(
                _activationFrame.temporaryAddress(expression),
                expression.type,
            );
            integerValue(integer, destination);
            return readStoredValue(destination);
        }

realExpression:
        if (auto real_ = expression.isRealExp)
            return scalarExpressionValue(real_);

nullExpression:
        if (auto null_ = expression.isNullExp) {
            import dmd.astenums: TY;

            // A `null` literal typed as a dynamic array is a null array, whose
            // `.length` is 0 and which renders as `[]` — the same
            // representation as a default-initialised array field
            // (`defaultValue`).  `new S` of a struct with an array field passes
            // this literal as the field's initialiser.
            if (null_.type !is null && null_.type.toBasetype.ty == TY.Tarray)
                return reconstructStoredArray(null_.type, []);

            return ExpressionResult.null_;
        }

stringExpression:
        if (auto string_ = expression.isStringExp)
            return constructedExpressionValue(string_);

arrayLiteralExpression:
        if (auto array = expression.isArrayLiteralExp)
            return constructedExpressionValue(array);

assocArrayLiteralExpression:
        // DMD's `AssocArrayLiteralExp::semantic` (`tryLowerAALiteral`,
        // expressionsem.d) always rewrites the literal into a call to
        // `object._d_assocarrayliteralTX!(K, V)(keys, values)` and records it
        // on `.lowering`; running that lowered call interprets druntime's own
        // literal construction instead of reconstructing one here.
        if (auto assocArray = expression.isAssocArrayLiteralExp)
            return constructedExpressionValue(assocArray.lowering);

structLiteralExpression:
        if (auto struct_ = expression.isStructLiteralExp)
            return structLiteralValue(struct_);

assertExpression:
        if (auto assert_ = expression.isAssertExp) {
            import quickbite.backends.interpreter.messages:
                assertFailureMessage;

            if (!conditionTruthy(assert_.e1))
                throwAssertError(assertFailureMessage(
                    assert_,
                    runningCalledFunction,
                    inUnitTest,
                    &assertOperandPlace,
                ));
            return ExpressionResult(true);
        }

notExpression:
        if (auto not = expression.isNotExp)
            return scalarExpressionValue(not);

logicalExpression:
        if (auto logical = expression.isLogicalExp) {
            if (logical.type.toBasetype.ty == TY.Tvoid) {
                if (logical.op == EXP.andAnd)
                    return runLogicalAndExpression(logical);
                if (logical.op == EXP.orOr)
                    return runLogicalOrExpression(logical);
            }
            return scalarExpressionValue(logical);
        }

castExpression:
        if (auto cast_ = expression.isCastExp) {
            log("cast expression: ", cast_);
            return castValue(cast_);
        }

equalExpression:
        if (auto equal = expression.isEqualExp)
            return runEqualExpression(equal);

identityExpression:
        if (auto identity = expression.isIdentityExp)
            return runIdentityExpression(identity);

comparisonExpression:
        if (
            expression.op == EXP.lessThan ||
            expression.op == EXP.lessOrEqual ||
            expression.op == EXP.greaterThan ||
            expression.op == EXP.greaterOrEqual
        ) {
            auto comparison = cast(imported!"dmd.expression".CmpExp) expression;
            if (comparison is null)
                assert(0, "comparison expression was not a CmpExp");

            return runComparisonExpression(comparison);
        }

conditionalExpression:
        if (auto conditional = expression.isCondExp)
            return conditional.type.toBasetype.ty == TY.Tvoid
                ? runConditionalExpression(conditional)
                : constructedExpressionValue(conditional);

throwExpression:
        if (auto throw_ = expression.isThrowExp) {
            throwInterpretedException(throw_.e1);
            return ExpressionResult.void_;
        }

postExpression:
        if (auto post = expression.isPostExp)
            return runPostIncrementExpression(post);

addAssignExpression:
        if (auto addAssign = expression.isAddAssignExp)
            return runAddAssignExpression(addAssign);

addExpression:
        if (auto add = expression.isAddExp)
            return isPointerArithmeticExpression(add)
                ? constructedExpressionValue(add)
                : scalarExpressionValue(add);

minExpression:
        if (auto sub = expression.isMinExp)
            return isPointerArithmeticExpression(sub)
                ? constructedExpressionValue(sub)
                : scalarExpressionValue(sub);

mulExpression:
        if (auto mul = expression.isMulExp)
            return scalarExpressionValue(mul);

divExpression:
        if (auto div = expression.isDivExp)
            return scalarExpressionValue(div);

modExpression:
        if (auto mod = expression.isModExp)
            return scalarExpressionValue(mod);

leftShiftExpression:
        if (auto leftShift = expression.isShlExp)
            return scalarExpressionValue(leftShift);

rightShiftExpression:
        if (auto rightShift = expression.isShrExp)
            return scalarExpressionValue(rightShift);

unsignedRightShiftExpression:
        if (auto unsignedRightShift = expression.isUshrExp)
            return scalarExpressionValue(unsignedRightShift);

negExpression:
        if (auto neg = expression.isNegExp)
            return scalarExpressionValue(neg);

complementExpression:
        if (auto complement = expression.isComExp)
            return scalarExpressionValue(complement);

powExpression:
        if (auto pow = expression.isPowExp)
            return scalarExpressionValue(pow);

catExpression:
        if (auto cat = expression.isCatExp)
            return runConcatenateExpression(cat);

assignExpression:
        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

loweredAssignExpression:
        if (auto lowered = expression.isLoweredAssignExp)
            return runLoweredAssignExpression(lowered);

constructExpression:
        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct);

blitExpression:
        if (auto blit = expression.isBlitExp)
            return runAssignExpression(blit);

concatenateAssignExpression:
        if (expression.op == EXP.concatenateAssign) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "concatenateAssign expression was not a BinExp");

            return runArrayConcatenateAssignExpression(assign);
        }

concatenateElemAssignExpression:
        if (expression.op == EXP.concatenateElemAssign) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "concatenateElemAssign expression was not a BinExp");

            return runArrayAppendAssignExpression(assign);
        }

concatenateDcharAssignExpression:
        if (expression.op == EXP.concatenateDcharAssign) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "concatenateDcharAssign expression was not a BinExp");

            return runArrayAppendAssignExpression(assign);
        }

scalarCompoundAssignExpression:
        if (isScalarCompoundAssignExpression(expression)) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "compound assignment expression was not a BinExp");

            return runCompoundAssignExpression(assign);
        }

bitOrExpression:
        if (auto bitOr = expression.isOrExp)
            return scalarExpressionValue(bitOr);

bitAndExpression:
        if (auto bitAnd = expression.isAndExp)
            return scalarExpressionValue(bitAnd);

bitXorExpression:
        if (auto bitXor = expression.isXorExp)
            return scalarExpressionValue(bitXor);

commaExpression:
        if (auto comma = expression.isCommaExp) {
            executeForEffect(comma.e1);
            return runExpressionValue(comma.e2);
        }

tupleExpression:
        if (auto tuple = expression.isTupleExp)
            return runTupleExpression(tuple);

declarationExpression:
        // DMD's own semantic analysis types a `DeclarationExp` `void`:
        // declaring a variable initialises its storage and yields nothing.
        // Decision 7's no-result operation is therefore the only operation a
        // declaration needs, in a discarding position or not.
        if (auto declaration = expression.isDeclarationExp) {
            executeDeclaration(declaration);
            return ExpressionResult.void_;
        }

callExpression:
        if (auto call = expression.isCallExp)
            return call.type.toBasetype.ty == TY.Tvoid
                ? runCallExpression(call, null)
                : constructedExpressionValue(call);

delegateExpression:
        if (auto delegate_ = expression.isDelegateExp)
            return runDelegateExpression(delegate_);

functionExpression:
        if (auto literal = expression.isFuncExp)
            return runFunctionLiteralDeclaration(literal);

arrayLengthExpression:
        if (auto arrayLength = expression.isArrayLengthExp) {
            // An addressable receiver already
            // has authoritative typed storage. Read only its header/fixed
            // length instead of allocating a by-value receiver snapshot.
            if (hasArrayProjectionPlace(arrayLength.e1))
                return ExpressionResult(
                    projectionPlace(arrayLength.e1).arrayLength,
                );
            return ExpressionResult(
                AggregateValue.length(AggregateValue.native(constructedExpressionValue(arrayLength.e1))),
            );
        }

sliceExpression:
        if (auto slice = expression.isSliceExp)
            return runSliceExpression(slice);

indexExpression:
        if (auto index = expression.isIndexExp)
            return runIndexExpression(index);

newExpression:
        if (auto new_ = expression.isNewExp)
            return runNewExpression(new_);

symbolOffsetExpression:
        if (auto symbol = expression.isSymOffExp) {
            if (auto variable = symbol.var.isVarDeclaration)
                return symbolOffsetLocalValue(symbol, variable);
            if (auto function_ = symbol.var.isFuncDeclaration)
                return functionPointerValue(function_);
        }
        goto unsupportedExpression;

pointerExpression:
        if (auto pointer = expression.isPtrExp)
            return runPointerExpression(pointer);

addressExpression:
        if (auto address = expression.isAddrExp)
            return runAddressExpression(address);

delegatePointerExpression:
        if (auto delegatePointer = expression.isDelegatePtrExp)
            return runDelegatePointerExpression(delegatePointer);

delegateFunctionPointerExpression:
        if (auto delegateFunctionPointer = expression.isDelegateFuncptrExp)
            return runDelegateFunctionPointerExpression(delegateFunctionPointer);

dotIdentifierExpression:
        if (auto dotIdentifier = expression.isDotIdExp)
            return runDotIdentifierExpression(dotIdentifier);

dotVariableExpression:
        if (auto dot = expression.isDotVarExp)
            return runDotVarExpression(dot);

vectorExpression:
        if (auto vector = expression.isVectorExp)
            return runVectorExpression(vector);

vectorArrayExpression:
        if (auto vectorArray = expression.isVectorArrayExp)
            return runVectorArrayExpression(vectorArray);

thisExpression:
        if (expression.isThisExp !is null) {
            if (!hasThis)
                throw new Exception("Unsupported eval expression: this");
            return receiverValue(thisValue);
        }

superExpression:
        if (expression.isSuperExp !is null) {
            if (!hasThis)
                throw new Exception("Unsupported eval expression: super");
            return receiverValue(thisValue);
        }

typeidExpression:
        if (auto typeid_ = expression.isTypeidExp)
            return runTypeidExpression(typeid_);

identifierExpression:
        if (auto identifier = expression.isIdentifierExp) {
            const name = identifier.ident is null
                ? ""
                : identifier.ident.toString.idup;

            // DMD's own `IdentifierExp` semantic (`expressionsem.d`) always
            // resolves `__ctfe` into a `VarExp` before a fully-semantic'd
            // module reaches this walker -- confirmed empirically, including
            // through the `-preview=dip1008` scope-catch-var destructor that
            // synthesizes this identifier (`statementsem.d`'s
            // `if (!__ctfe) _d_delThrowable(var)`): its own subsequent
            // `statementSemantic` resolves it before any backend walks it.
            // This arm is defensive dead code kept in the same shape as the
            // `VarExp` arm below rather than assumed unreachable forever.
            if (name == "__ctfe")
                return ExpressionResult(false);

            // Constructor and member-method `this` is the native body
            // pointer. Resolve an unqualified class field through that body,
            // straight off `thisValue`'s own place -- `Place.field` derives
            // the field's offset from `field` itself, not from the place's
            // recorded type, so no reconstruction is needed here.
            if (
                hasThis &&
                thisValue.type !is null &&
                thisValue.type.toBasetype.isTypeClass !is null &&
                currentFunction !is null
            ) {
                auto thisParameter = currentFunction.vthis;
                auto classType = thisParameter is null
                    ? null
                    : thisParameter.type.toBasetype.isTypeClass;
                if (classType !is null && classType.sym !is null) {
                    import quickbite.backends.interpreter.layout: classFields, fieldName;
                    import quickbite.backends.interpreter.place_value: readValue;

                    foreach (field; classFields(classType.sym))
                        if (fieldName(field) == name)
                            return readValue(thisValue.field(field));
                }
            }
        }
        goto unsupportedExpression;

variableExpression:
        if (auto var = expression.isVarExp) {
            import dmd.id: Id;

            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                return runSymbolDeclarationVarExpression(var);

            // The Interpreter runs a compiled-D-equivalent runtime, not
            // DMD's own CTFE engine (that is the separate `Ctfe` backend,
            // `backends/ctfe/dmd_ctfe.d`, which invokes DMD's real CTFE
            // interpreter and legitimately observes `true`); the magic
            // `__ctfe` flag must therefore read `false` here, matching
            // `SystemLinker`.
            if (variable.ident is Id.ctfe)
                return ExpressionResult(false);

            if (isManifestVariable(variable)) {
                if (auto initializer = variable._init.isExpInitializer)
                    return runExpressionValue(initializer.exp);
                return defaultValueResult(variable.type);
            }

            if (
                auto length = cast(const(void)*) variable
                    in _syntheticDollarValues
            )
                return ExpressionResult(*length);

            if (isUninitializedBinding(variable)) {
                import quickbite.backends.interpreter.messages: uninitializedVariableMessage;
                import quickbite.frontend.dmd.types: isStaticArrayType, isStructType;

                // DMD's void diagnostic is field-granular: reading a whole
                // void-initialized aggregate (as `S res = void; return res;`
                // does) materialises a default value; only a still-void scalar
                // read is reported. Match that so patterns like Phobos
                // `trustedVoidInit` evaluate up to any real libc call.
                if (isStructType(variable.type) || isStaticArrayType(variable.type)) {
                    defaultLocalValue(variable);
                    clearUninitializedBindingAddress(bindingPlace(variable).address);
                    return readBindingValue(variable);
                }

                throw new Exception(uninitializedVariableMessage(variable, currentFunction));
            }

            materializeDatasegInitializer(variable);

            if (hasBindingPlace(variable))
                return readBindingValue(variable);

            // A module-level or static variable read before any write (e.g.
            // std.encoding's immutable bomTable): materialize its static
            // initializer, and remember it so repeated reads agree. Locals
            // are excluded: their DeclarationExp evaluates their initializer
            // (an initializer like _d_arrayctor's even reads the variable
            // itself). Seed the type's default first so an initializer that
            // reads the variable back (directly or through calls) terminates,
            // as compiled D's pre-initialized statics do.
            if (variable.isDataseg && variable._init !is null) {
                resolveNonRootInitializer(variable);
                if (auto initializer = variable._init.isExpInitializer) {
                    defaultLocalValue(variable);
                    const value = storageValue(
                        variable.type,
                        evaluateDatasegInitializerExpression(initializer.exp),
                    );
                    setLocal(variable, value);
                    return value;
                }
            }

            return defaultValueResult(variable.type);
        }

unsupportedExpression:
        import std.conv: text;
        throw new Exception(text("Unsupported eval expression: ", expression.op));
    }

    // A module-scope variable of an imported (non-root) module only gets
    // semantic1: DMD runs semantic2 over root modules alone (compiler.d
    // parseRootModulesLocked), so the variable's initializer expression can
    // still be an unresolved IdentifierExp (e.g. std.internal.entropy's
    // `_entropySource = defaultEntropySource`, read via std.random's
    // unpredictableSeed). Run semantic2 on the variable in its own module's
    // global scope on demand — the semantic2 analogue of the functionSemantic3
    // calls that resolve imported function bodies — so the initializer resolves
    // before we evaluate it. semantic2 may replace `variable._init`, so callers
    // re-read it afterwards.
    private void resolveNonRootInitializer(VarDeclaration variable) {
        import dmd.dsymbol: PASS;

        if (variable.semanticRun >= PASS.semantic2done)
            return;

        auto mod = variable.getModule;
        if (mod is null)
            return;

        import dmd.dscope: Scope;
        import dmd.globals: global;
        import dmd.semantic2: semantic2;

        auto scope_ = Scope.createGlobal(mod, global.errorSink);
        semantic2(variable, scope_);
        scope_ = scope_.pop;
        scope_.pop;
    }

    private ExpressionResult runTupleExpression(imported!"dmd.expression".TupleExp tuple) {
        // DMD lowers a tuple assignment (`target.tupleof = source.tupleof`, or a
        // `Tuple` constructor's `field[] = values[]`) into a `TupleExp`: an
        // optional side-effect prefix `e0` followed by the per-element
        // expressions, which are ordinary assignments the interpreter already
        // evaluates. Run the prefix, then each element in order; the sequence's
        // value is its last element (matching the IR lowering), and is discarded
        // in the statement-expression positions this arises in.
        if (tuple.e0 !is null)
            executeForEffect(tuple.e0);

        auto result = ExpressionResult.void_;  // mutated below; `const` cannot express the fold
        if (tuple.exps !is null)
            foreach (element; *tuple.exps)
                result = constructedExpressionValue(element);
        return result;
    }

    private ExpressionResult runSymbolDeclarationVarExpression(
        imported!"dmd.expression".VarExp var,
    ) {
        import dmd.typesem: defaultInitLiteral;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto symbol = var.var.isSymbolDeclaration;
        if (symbol is null)
            assert(0, "non-variable VarExp was not a SymbolDeclaration");

        auto type = symbol.dsym is null ? symbol.type : symbol.dsym.type;

        if (auto structType = type is null ? null : type.toBasetype.isTypeStruct)
            return constructedExpressionValue(structType.defaultInitLiteral(var.loc));

        // `__traits(initSymbol, T)` denotes T's initializer image as an
        // untyped span: the bytes `emplace` copies into raw storage before any
        // constructor runs. A type whose default is not all-zero (a `char`
        // field, a declared field default) needs those real bytes, so the span
        // views an initialized instance rather than blank storage. The same
        // declaration spelled with T's own type is instead T's `.init` value.
        const initializerImage = isVoidSliceType(symbol.type);

        auto classType = type is null ? null : type.toBasetype.isTypeClass;
        if (initializerImage && classType !is null && classType.sym !is null) {
            auto object = AggregateValue.allocateClass(type);
            initializeNativeClassBody(this, type, object);
            return ExpressionResult.nativeAggregateValue(
                AggregateValue.classBodyByteSlice(object, symbol.type),
            );
        }

        assert(0, "SymbolDeclaration VarExp was not an aggregate initializer");
    }

    private ExpressionResult runLogicalAndExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        const left = conditionTruthy(logical.e1);
        if (!left)
            return ExpressionResult(false);

        const right = runDestructorBoundedCondition(logical.e2);
        return ExpressionResult(right);
    }

    private ExpressionResult runLogicalOrExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        const left = conditionTruthy(logical.e1);
        if (left)
            return ExpressionResult(true);

        const right = runDestructorBoundedCondition(logical.e2);
        return ExpressionResult(right);
    }

    // Mirrors `e2ir.d`'s `visitLogical`: DMD lowers `&&`/`||`'s left operand
    // with `toElem` but its evaluated right operand with `toElemDtor` -- the
    // only expression-internal destructor boundary; a `?:` arm gets none.
    // `scope(exit)` also reproduces the oracle's unwind behaviour: the right
    // operand's own temporary is destroyed first, then any outer temporaries
    // as the enclosing full expression unwinds past this call.
    private bool runDestructorBoundedCondition(
        imported!"dmd.expression".Expression operand,
    ) {
        const first = _pendingTemporaryDestructors.length;
        scope(exit) runPendingTemporaryDestructors(first);
        return conditionTruthy(operand);
    }

    private ExpressionResult runComparisonExpression(
        imported!"dmd.expression".CmpExp comparison,
    ) {
        import dmd.tokens: EXP;

        if (hasScalarComparisonOperands(comparison))
            return ExpressionResult(scalarComparison(comparison));

        // D defines `<`/`<=`/`>`/`>=` only for arithmetic types and
        // pointers; DMD's semantic pass lowers array and `opCmp` comparisons
        // to `__cmp`/method calls before this point. Every operand reaching
        // here is therefore a pointer. Read both through their own typed
        // places rather than the carrier: a default-initialized pointer then
        // reads as its real null address instead of needing a separate
        // carrier tag to recognise.
        const left = pointerOperandPlace(comparison.e1).deref.address;
        const right = pointerOperandPlace(comparison.e2).deref.address;
        const difference = pointerAddressDifference(left, right);

        if (comparison.op == EXP.lessThan)
            return ExpressionResult(difference < 0);
        if (comparison.op == EXP.lessOrEqual)
            return ExpressionResult(difference <= 0);
        if (comparison.op == EXP.greaterThan)
            return ExpressionResult(difference > 0);
        return ExpressionResult(difference >= 0);
    }

    // These operations have scalar results only. Construct the result in the
    // expression's typed activation slot so both operands and the result stay
    // outside the value carrier.
    private ExpressionResult scalarExpressionValue(
        imported!"dmd.expression".Expression expression,
    ) {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        assert(
            constructScalarExpressionInto(expression, destination.place),
            "expression did not construct into its scalar destination",
        );
        return readStoredValue(destination.place);
    }

    // A general fallback for call sites whose remaining operand kind is not
    // fixed to one family (e.g. a conditional expression's arms, or pointer
    // arithmetic's mixed pointer/integer operands): construct through the
    // full `runExpression` pipeline, which already tries the typed
    // construction arms before falling back to the carrier, then read the
    // typed result back.
    private ExpressionResult constructedExpressionValue(
        imported!"dmd.expression".Expression expression,
    ) {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);
        return readStoredValue(destination.place);
    }

    // `+`/`-` mix scalar arithmetic with pointer arithmetic. Detect pointer
    // arithmetic from the static operand and result types, not the runtime
    // value: a default-initialized pointer-typed operand (e.g. druntime's
    // dip1008 Throwable chain-link arithmetic) reads as `Null`, not a
    // zero-valued `Pointer`.
    private bool isPointerArithmeticExpression(
        imported!"dmd.expression".BinExp expression,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        return isPointerType(expression.e1.type) ||
            isPointerType(expression.e2.type) ||
            isPointerType(expression.type);
    }

    private long pointerElementSize(imported!"dmd.mtype".Type pointerType) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        auto element = pointerType is null
            ? null
            : pointerType.toBasetype.nextOf;
        const elementSize = element is null ? 0 : cast(long) typeByteSize(element);
        if (elementSize <= 0)
            throw new Exception("Unsupported pointer element type.");

        return elementSize;
    }

    private ExpressionResult runAddressExpression(
        imported!"dmd.expression".AddrExp address,
    ) {
        return addressOfExpression(address.e1, address.op);
    }

    private ExpressionResult addressOfExpression(
        imported!"dmd.expression".Expression e1,
        in imported!"dmd.tokens".EXP op,
    ) {
        import std.conv: text;

        if (auto symbol = e1.isSymOffExp) {
            if (auto variable = symbol.var.isVarDeclaration)
                return symbolOffsetLocalValue(symbol, variable);
            if (auto function_ = symbol.var.isFuncDeclaration)
                return functionPointerValue(function_);
        }

        // `&val` of a `ref` parameter is emitted as AddrExp(VarExp), not the
        // SymOffExp produced for a plain local; point at the parameter's slot
        if (auto var = e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                return bindingPointerValue(variable);

        // A struct method's `this` is an alias to the caller's receiver, not
        // an ordinary local declaration. Its address therefore comes from
        // the receiver place retained when this activation was entered.
        if (
            e1.isThisExp !is null &&
            e1.type.toBasetype.isTypeStruct !is null &&
            thisAddress !is null
        )
            return ExpressionResult.pointerValue(thisAddress);

        if (auto delegate_ = e1.isDelegateExp)
            return runDelegateExpression(delegate_);

        // `this` is not an ordinary binding to compose an address from: the
        // receiver's address is the one this activation was entered with. A
        // struct constructor's implicit `return this` reaches here, and must
        // answer the temporary the constructor ran against.
        if (e1.isThisExp !is null) {
            if (thisAddress !is null)
                return ExpressionResult.pointerValue(thisAddress);
            if (currentFunction !is null && currentFunction.vthis !is null)
                return bindingPointerValue(currentFunction.vthis);
        }

        // D's comma expression yields its right operand, including that
        // operand's lvalue identity. Constructor lowering uses this shape to
        // sequence initialization before referring to the fresh temporary.
        if (auto comma = e1.isCommaExp) {
            executeForEffect(comma.e1);
            return addressOfExpression(comma.e2, op);
        }

        // DMD lowers a method call on an explicitly constructed struct
        // temporary to a constructor call whose receiver ends in
        // `AddrExp(StructLiteralExp)`. Materialize that literal once and keep
        // its native storage alive for the enclosing full expression so the
        // constructor and following method observe the same `this` bytes.
        if (auto literal = e1.isStructLiteralExp) {
            const value = structLiteralValue(literal);
            auto temporary = AggregateValue.native(value);
            retainTemporaryPointerOwner(temporary.storage);
            return ExpressionResult.pointerValue(temporary.address);
        }

        // Taking the address of a dereference recovers the pointer value;
        // evaluating the dereference first would incorrectly require a
        // separate addressable value for the pointee.
        if (auto pointer = e1.isPtrExp)
            return ExpressionResult.pointerValue(
                pointerOperandPlace(pointer.e1).deref.address,
            );

        // `&field` (also `field.ptr`) of a struct's static-array member: a
        // pointer to the field's first element, exactly what arrayPointer
        // builds for `&field[0]`.
        if (auto dot = e1.isDotVarExp) {
            import quickbite.frontend.dmd.types: isStaticArrayType;
            import quickbite.backends.interpreter.class_info_projection:
                isSymbolicClassInfoProjection;

            // `classinfo` resolves symbolically on this backend: no native
            // `TypeInfo_Class` body exists, so composing a field address
            // through it would dereference the receiver's own leading field
            // bytes as a metadata pointer. `x.classinfo.name` reaches here
            // as a `ref` argument because a `TypeInfo` field is an lvalue;
            // write the evaluated value into this activation's typed
            // temporary, exactly as a by-value call result bound by
            // reference does.
            if (isSymbolicClassInfoProjection(dot))
                return addressOfTemporaryValue(dot, runExpressionValue(dot));

            if (isStaticArrayType(dot.type))
                return arrayPointer(dot, 0, op);

            // Build a nested field address from its receiver's one address.
            // In particular, `&a[i++].inner.x` first composes the address of
            // `a[i++].inner`; that evaluates `i++` exactly once, then the
            // outer field offset composes from the resulting native pointer.
            // Re-running `runExpressionValue(dot)` for a detached aggregate read would
            // walk the index a second time.
            if (auto innerDot = dot.e1.isDotVarExp)
                if (auto field = dot.var.isVarDeclaration) {
                    const receiverPointer = addressOfExpression(innerDot, op);
                    if (receiverPointer.isPointer) {
                        import quickbite.backends.interpreter.place: Place;

                        // `&parent.child.x` first yields the address of the
                        // class-reference field `parent.child`; compose `x`
                        // from the referenced body, not from that slot's bytes.
                        if (innerDot.type.toBasetype.isTypeClass !is null)
                            return ExpressionResult.pointerValue(
                                Place(receiverPointer.pointerAddress, innerDot.type)
                                    .deref.field(field).address,
                            );

                        return ExpressionResult.pointerValue(
                            Place(receiverPointer.pointerAddress, innerDot.type)
                                .field(field)
                                .address,
                        );
                    }
                }

            if (auto index = dot.e1.isIndexExp) {
                if (auto field = dot.var.isVarDeclaration) {
                    // `$` inside `index.e2` (a `DollarExp`) is bound to
                    // `index.lengthVar`; the ordinary eager path binds it
                    // from `runExpressionValue(index.e1)`'s length before
                    // evaluating the index, but this branch exists
                    // specifically to avoid evaluating `index.e1` a second,
                    // independent way -- `arrayPointer` below already
                    // resolves it once. A bare variable receiver
                    // (`arr[$ - 1].mid.x`) has no side effect of its own to
                    // duplicate: reading it again here to bind `lengthVar`
                    // is exactly as safe as `arrayPointer`'s own upcoming
                    // resolution of the same variable, so do so before
                    // `index.e2` runs. A receiver with a side effect of its
                    // own (a further nested `IndexExp`, a `CallExp`, ...) is
                    // left as the pre-existing gap it already was --
                    // re-evaluating it here would reintroduce exactly the
                    // double-evaluation hazard this branch exists to avoid.
                    if (index.lengthVar !is null)
                        if (auto receiverVar = index.e1.isVarExp)
                            setLocal(
                                index.lengthVar,
                                ExpressionResult(AggregateValue.length(
                                    AggregateValue.native(constructedExpressionValue(receiverVar)),
                                )),
                            );
                    const elementIndex = scalarOperand!long(index.e2);
                    const elementPointer = arrayPointer(index.e1, elementIndex, op);
                    if (elementPointer.isPointer) {
                        import quickbite.backends.interpreter.place: Place;

                        return ExpressionResult.pointerValue(
                            Place(elementPointer.pointerAddress, dot.e1.type)
                                .field(field)
                                .address,
                        );
                    }
                }
            }

            if (auto receiver = dot.e1.isVarExp)
                if (auto variable = receiver.var.isVarDeclaration)
                    if (auto field = dot.var.isVarDeclaration)
                        if (hasBindingPlace(variable)) {
                            auto place = bindingPlace(variable);
                            if (place.type.toBasetype.isTypeClass !is null)
                                place = place.deref;
                            return ExpressionResult.pointerValue(place.field(field).address);
                        }

            // A class read carries its native body address. Compose the field
            // from that authority and the receiver expression's static class
            // type; native objects such as a caught Throwable need not have
            // been allocated by the Interpreter or entered in its dynamic-type
            // registry for their inherited field layout to be addressable.
            auto nativeClassReceiver = constructedExpressionValue(dot.e1);
            if (
                nativeClassReceiver.isNativeAggregate &&
                dot.e1.type.toBasetype.isTypeClass !is null
            )
                nativeClassReceiver = ExpressionResult.pointerValue(
                    AggregateValue.nativeClassBodyAddress(nativeClassReceiver),
                );
            else if (auto metadata = classMetadata(nativeClassReceiver))
                nativeClassReceiver = ExpressionResult.pointerValue(
                    AggregateValue.nativeClassBodyAddress(*metadata),
                );
            if (
                nativeClassReceiver.isPointer &&
                dot.e1.type.toBasetype.isTypeClass !is null
            ) {
                import quickbite.backends.interpreter.place: Place;

                auto field = dot.var.isVarDeclaration;
                if (field !is null)
                    return ExpressionResult.pointerValue(
                        Place(nativeClassReceiver.pointerAddress, dot.e1.type)
                            .field(field)
                            .address,
                    );
            }

            // A field of an aggregate call result has no binding whose block
            // can root it. Keep its typed storage alive until the enclosing
            // expression stores or discards the returned address.
            if (dot.e1.isCallExp !is null) {
                const receiver = nativeClassReceiver;
                if (receiver.isNativeAggregate) {
                    import quickbite.backends.interpreter.place: Place;

                    auto aggregate = AggregateValue.native(receiver);
                    retainTemporaryPointerOwner(aggregate.storage);
                    auto field = dot.var.isVarDeclaration;
                    if (field !is null)
                        return ExpressionResult.pointerValue(
                            Place(aggregate.address, aggregate.type)
                                .field(field)
                                .address,
                        );
                }
            }

            // Every remaining field address must compose from the owning
            // typed binding. This also covers parameters and nested receiver
            // shapes whose value is represented only by a native place.
            try {
                import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;

                return ExpressionResult.pointerValue(placeOfLvalue(
                    dot,
                    (variable) @safe => addressableBindingBase(variable),
                    (expression) @system => scalarOperand!size_t(expression),
                ).address);
            } catch (Exception exception) {
                throw new Exception(text(
                    "field address has no composable native place: ",
                    dot,
                    ": ",
                    exception.msg,
                ));
            }
        }

        // `&call()` of a ref-returning function: run the call and yield the
        // returned lvalue's address.
        if (auto call = e1.isCallExp)
            return refReturningCallAddress(call, op);

        auto index = e1.isIndexExp;
        if (index is null)
            throw new Exception(
                text("Unsupported eval expression: ", op, " of ", e1.op),
            );

        return arrayPointer(index, 0, op, true /* selfAddress */);
    }

    // A ref return's lvalue, evaluated in the returning function's own
    // frame (`addressOfRefReturn` mode). Both branches still resolve
    // through `runExpressionValue`/`addressOfExpression`, genuinely
    // carrier-typed producers; this is the one boundary that lifts their
    // pointer into the typed place the rest of the ref-return channel
    // carries.
    private Place refReturnPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        // DMD lowers a ref-returning ternary to `return *(cond ? &a : &b())`;
        // the address of that dereference is the pointer expression itself.
        if (auto pointer = expression.isPtrExp)
            return Place(
                pointerOperandPlace(pointer.e1).deref.address,
                expression.type,
            );

        return Place(
            addressOfExpression(expression, EXP.address).pointerAddress,
            expression.type,
        );
    }

    // The one place a `return` statement's result leaves the function body.
    // `addressOfRefReturn` mode wants the returned lvalue itself, named as a
    // place, not its value. Otherwise the caller's construction destination
    // takes the expression's value directly, constructing it in place; for a
    // class return, `constructReturnValue` roots the constructed value
    // against its own storage so the caller sees the same owning allocation
    // the callee constructed rather than a bare body pointer a later
    // collection could reclaim. A void call has no destination and never
    // reaches here with a real `expression` (a void function body has no
    // `return expression;`).
    private void setReturnValue(imported!"dmd.expression".Expression expression)
    in (
        addressOfRefReturn || _returnDestination !is null,
        "setReturnValue: a non-ref return needs a construction destination",
    ) {
        if (addressOfRefReturn) {
            _refReturnPlace = refReturnPlace(expression);
            return;
        }

        constructReturnValue(expression, *_returnDestination);
    }

    private ExpressionResult refReturningCallAddress(
        imported!"dmd.expression".CallExp call,
        in imported!"dmd.tokens".EXP op,
    ) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
        import quickbite.frontend.dmd.functions:
            ensureFunctionBodySemantic, hasNoInterpretableSource;
        import std.conv: text;

        const unsupported =
            text("Unsupported eval expression: ", op, " of ", call.op);

        if (call.f is null)
            throw new Exception(unsupported);
        if (!returnsRef(call.f))
            return addressOfCallResultTemporary(call);

        if (auto dot = call.e1.isDotVarExp)
            return memberRefReturningCallAddress(call, dot, unsupported);

        ensureFunctionBodySemantic(call.f);
        if (call.f.needThis)
            throw new Exception(unsupported);
        const native = hasNoInterpretableSource(call.f);

        auto callArguments = CallArguments(
            call.arguments is null ? 0 : call.arguments.length,
        );
        scope(exit) callArguments.release;
        auto arguments = callArguments.values;
        auto argumentExpressions = callArguments.expressions;
        auto evaluatedArguments = callArguments.references;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments[index] = index < call.f.parameters.length &&
                    isReferenceParameter(
                        call.f,
                        index,
                        (*call.f.parameters)[index],
                    )
                    ? runRefArgumentExpression(argument, evaluated, native)
                    : constructedExpressionValue(argument);
                if (
                    index < call.f.parameters.length &&
                    (*call.f.parameters)[index].type.toBasetype.isTypeClass !is null
                )
                    arguments[index] = rootedNativeClassValue(
                        argument,
                        arguments[index],
                    );
                argumentExpressions[index] = argument;
                evaluatedArguments[index] = evaluated;
            }

        if (native) {
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;

            NativeCallResult nativeResult;
            try {
                if (!invokeNativeDeclaration(
                    call.f,
                    ExpressionResult.void_,
                    null,
                    null,
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                    false,
                    nativeResult,
                ))
                    throw new Exception(unsupported);
            } catch (NativeCallException exception) {
                throwNativeException(exception);
            }
            return ExpressionResult.pointerValue(nativeResult.value.address);
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = call.f;
        auto layout = cachedFrameLayout(call.f);
        child._activationFrame = FrameBlock.allocate(layout);
        child.addressOfRefReturn = true;
        forkExecutionStateInto(child);
        scope(exit) child.retireActivationFrameMetadata;
        bindCapturedReferenceSlots(call.f, child);
        child.bindFunctionParameters(
            call.f,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );
        try {
            child.runStatement(call.f.fbody);
        } catch (InterpretedException exception) {
            mergeFunctionState(call.f, argumentExpressions, child, arguments);
            throw exception;
        }
        mergeFunctionState(call.f, argumentExpressions, child, arguments);

        return returnedLvalueAddress(call.f, argumentExpressions, child);
    }

    // Resolve a member call's receiver expression exactly once: its address
    // (needed to alias a struct `this` to the caller's real storage) and the
    // value read through that address (needed for the null-receiver check,
    // virtual dispatch, and a native callee). A receiver with no address
    // (an rvalue) falls back to evaluating it ordinarily -- still exactly
    // once. Composing the address and the value as two independent
    // evaluations of `receiverExpression` would re-run any side effect it
    // carries (e.g. a ref-returning call) an extra time. A receiver that is
    // itself a constructed temporary owns a full-expression cleanup, queued
    // here for the same reason.
    private void resolveMemberCallReceiver(
        imported!"dmd.expression".Expression receiverExpression,
        out ExpressionResult receiverAddress,
        out ExpressionResult receiver,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;

        receiverAddress = addressOfExpression(receiverExpression, EXP.address);
        receiver = receiverAddress.isPointer
            ? readStoredValue(
                Place(receiverAddress.pointerAddress, receiverExpression.type),
            )
            : constructedExpressionValue(receiverExpression);
        queueConstructedReceiverDestructor(receiverExpression);
    }

    // The address of the lvalue a ref-returning *member* call yields. The
    // callee's `this` must alias the receiver expression's own storage: the
    // returned lvalue is typically a receiver field, and its address is only
    // meaningful to the caller if it points into the caller's aggregate
    // rather than into a copied receiver value.
    private ExpressionResult memberRefReturningCallAddress(
        imported!"dmd.expression".CallExp call,
        imported!"dmd.expression".DotVarExp dot,
        in string unsupported,
    ) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
        import quickbite.frontend.dmd.functions:
            ensureFunctionBodySemantic, hasNoInterpretableSource;

        ExpressionResult receiverAddress;
        ExpressionResult receiver;
        resolveMemberCallReceiver(dot.e1, receiverAddress, receiver);

        // `call` is `dot.e1`'s own constructor whenever this receiver
        // resolution was reached because a further use needed the
        // not-yet-constructed receiver's address (see
        // `popPrematureReceiverConstructorDestructor`): hold its premature
        // arming until the constructor below actually succeeds.
        auto deferredReceiverConstructorDestructor =
            popPrematureReceiverConstructorDestructor(call.f, dot.e1);
        scope(success)
            if (deferredReceiverConstructorDestructor !is null)
                queueTemporaryDestructor(deferredReceiverConstructorDestructor);

        if (receiver == ExpressionResult.null_)
            throw new Exception(
                "function call through null class reference `null`",
            );

        auto function_ = resolveMemberFunction(call.f, receiver);
        ensureFunctionBodySemantic(function_);
        const native = hasNoInterpretableSource(function_);

        ExpressionResult[] arguments;
        Expression[] argumentExpressions;
        EvaluatedReferenceArgument[] evaluatedArguments;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments ~= index < function_.parameters.length &&
                    isReferenceParameter(
                        function_,
                        index,
                        (*function_.parameters)[index],
                    )
                    ? runRefArgumentExpression(argument, evaluated)
                    : constructedExpressionValue(argument);
                if (
                    index < function_.parameters.length &&
                    (*function_.parameters)[index].type.toBasetype.isTypeClass !is null
                )
                    arguments[$ - 1] =
                        rootedNativeClassValue(argument, arguments[$ - 1]);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
            }

        if (native) {
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;

            imported!"dmd.mtype".Type receiverType = receiverClassType(dot.e1);
            if (receiverType is null)
                receiverType = receiverStructType(dot.e1);

            NativeCallResult nativeResult;
            try {
                if (!invokeNativeDeclaration(
                    function_,
                    receiver,
                    receiverType,
                    dot.e1,
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                    false,
                    nativeResult,
                ))
                    throw new Exception(unsupported);
            } catch (NativeCallException exception) {
                throwNativeException(exception);
            }
            return ExpressionResult.pointerValue(nativeResult.value.address);
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.addressOfRefReturn = true;
        forkExecutionStateInto(child);
        scope(exit) child.retireActivationFrameMetadata;
        bindCapturedReferenceSlots(function_, child);
        child.thisValue = receiverPlaceFrom(
            receiver,
            function_.vthis is null ? null : function_.vthis.type,
        );
        child.hasThis = true;
        child.bindThisReferenceAddress(function_, child.thisValue);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );
        aliasThisToReceiverStorage(child, function_, receiverAddress);

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            mergeMemberFunctionState(
                function_,
                dot.e1,
                argumentExpressions,
                child,
                arguments,
            );
            throw exception;
        }
        mergeMemberFunctionState(
            function_,
            dot.e1,
            argumentExpressions,
            child,
            arguments,
        );
        return returnedLvalueAddress(function_, argumentExpressions, child);
    }

    // Alias a member callee's `this` to the receiver's real storage address,
    // already resolved by the caller (`resolveMemberCallReceiver`). A
    // `ref`-returning or ref-assigned member call must read and mutate the
    // caller's own aggregate: field addresses computed inside the callee
    // (`&_field`, `return _field;`) only reach the caller's struct if `this`
    // is a borrowed view of that exact address, never a detached copy of the
    // receiver's value. Taking the receiver's address here a second,
    // independent way would re-run a side-effecting receiver expression
    // (e.g. a ref-returning call) an extra time.
    private void aliasThisToReceiverStorage(
        ref Walker child,
        imported!"dmd.func".FuncDeclaration function_,
        in ExpressionResult receiverAddress,
    ) {
        if (
            function_.vthis is null ||
            function_.vthis.isThisDeclaration is null
        )
            return;

        if (!receiverAddress.isPointer)
            return;

        child.thisAddress = receiverAddress.pointerAddress;
        if (child._activationFrame.hasReferenceSlot(function_.vthis))
            child._activationFrame.setReferenceSlot(
                function_.vthis,
                child.thisAddress,
            );
        if (function_.vthis.type.toBasetype.isTypeStruct !is null)
            child.bindStructReceiver(Place(
                receiverAddress.pointerAddress,
                function_.vthis.type,
            ));
    }

    // A struct receiver borrows the caller's own storage rather than
    // copying it: a mutation the callee makes through `this` (`this.field =
    // ...`, a postblit, a delegating constructor) must land in that exact
    // place. `place` names the bytes to borrow; this is the one spot that
    // spells out the borrowed-native-aggregate representation, so every
    // struct receiver construction routes through it.
    private void bindStructReceiver(Place place) {
        thisValue = place;
    }

    // The place a still-carrier-typed receiver value already names: a
    // struct receiver's own native aggregate storage, or -- for a class
    // receiver, whose carrier is a bare body-address pointer with no type
    // of its own -- `classType` from the surrounding construction context.
    // A boundary helper for the receiver channel's remaining carrier-typed
    // producers (a call's returned receiver, a default-initialised struct,
    // a rebound `this`/`super`), not a receiver-constructing site itself.
    private Place receiverPlaceFrom(
        in ExpressionResult value,
        imported!"dmd.mtype".Type classType,
    ) {
        return value.isNativeAggregate
            ? Place(
                AggregateValue.native(value).address,
                AggregateValue.native(value).type,
            )
            : Place(value.pointerAddress, classType);
    }

    // The inverse of `receiverPlaceFrom`, and of `bindClassReceiver`/
    // `bindStructReceiver`: the receiver carrier a place already names. A
    // struct receiver reads back as the same borrowed native aggregate its
    // own binder would construct; a class receiver's place address IS the
    // body address (no slot to dereference, matching `bindClassReceiver`'s
    // own invariant). Dispatch on `isTypeStruct`, not `isTypeClass`: a
    // nested function's captured `this` carries its receiver through
    // `vthis`, whose declared type DMD gives as an opaque `void*` context
    // pointer, not the real class -- `isTypeStruct` stays reliable there
    // (every struct-receiver construction site gates on it explicitly), so
    // "not a struct" is the correct fallback to the pointer read.
    private ExpressionResult receiverValue(Place place) {
        return place.type.toBasetype.isTypeStruct !is null
            ? borrowedAggregateValue(place)
            : ExpressionResult.pointerValue(place.address);
    }

    // A `ref` foreach variable over an input range may bind to a `front`
    // result returned by value. DMD represents its per-iteration temporary as
    // `AddrExp(CallExp)`: evaluate the call once into typed native storage and
    // return that ordinary temporary's address.
    private ExpressionResult addressOfCallResultTemporary(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(call),
            call.type,
        ));
        constructInto(call, destination);
        return ExpressionResult.pointerValue(destination.place.address);
    }

    // The address of an evaluated value with no composable native place: one
    // ordinary typed temporary in this activation's frame. A reference slot
    // that stores this address is conservatively scanned and stays the durable
    // root beyond that expression, the same lifetime contract
    // `bindSyntheticReferenceSlot` states for its own temporary.
    private ExpressionResult addressOfTemporaryValue(
        imported!"dmd.expression".Expression expression,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.place: Place;

        auto temporary = _activationFrame.temporaryAddress(expression);
        writeStoredValue(Place(temporary, expression.type), value);
        return ExpressionResult.pointerValue(temporary);
    }

    // Forks execution metadata. Binding storage is never copied: each child
    // owns a fresh activation frame, captures borrow parent addresses, and
    // module storage is shared directly.
    private void forkExecutionStateInto(ref Walker child) {
        _activationFrameMetadataLifetime = FrameMetadataLifetime(
            &_activationFrame,
            &_activationFrameMetadataRetained,
            _callerFrameMetadataLifetime,
        );
        child._callerFrameMetadataLifetime = &_activationFrameMetadataLifetime;
        if (child.currentFunction !is null && child.currentFunction.isNested)
            child._enclosingFrames = [_activationFrame] ~ _enclosingFrames;

        child.uninitializedBindingAddresses = uninitializedBindingAddresses;
        // Shared for the same reason: one evaluated array-literal class
        // default must stay the single backing array every fork sees.
        child.classArrayFieldDefaults = classArrayFieldDefaults;
        // Shared for the identical reason, and by the identical shape --
        // see `moduleTable`'s own field comment.
        child.moduleTable = moduleTable;
        child._temporaryPointerOwners = _temporaryPointerOwners;
        // `_pendingTemporaryDestructors` and `_fullExpressionDepth` are
        // deliberately left at the child's own defaults: a function call is
        // a full-expression boundary for the callee's internals, so a
        // callee arms and runs its own temporaries' destructors against its
        // own depth, never the caller's.
        child._executionState = _executionState;
        child.lazyArgumentExpressions = lazyArgumentExpressions;
        child.lazyArgumentFrames = lazyArgumentFrames;
        child._lazyArgumentMapsBorrowed = true;
    }

    // A returned activation normally has no storage lifetime left, so its
    // address-keyed callable metadata must leave the execution registry with
    // it. A closure capture or lazy thunk can retain the frame itself; those
    // two cases keep its metadata live under the same lifetime.
    private void retireActivationFrameMetadata() {
        if (_activationFrameMetadataRetained)
            return;

        foreach (frame; lazyArgumentFrames.byValue)
            if (frame.block.address is _activationFrame.block.address)
                return;

        clearStoredMetadataRange(
            _activationFrame.block.address,
            _activationFrame.byteLength,
        );
    }

    // The child's returned address points into its own frame: a pointer to a
    // `ref` parameter's slot must become the caller's argument lvalue so
    // writes through it reach the argument; any other variable's pointer id
    // is registered here so this frame can resolve it.
    private ExpressionResult returnedLvalueAddress(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        return ExpressionResult.pointerValue(child._refReturnPlace.address);
    }

    // `selfAddress` distinguishes two shapes that both recurse into the
    // `array.isIndexExp` arm below with what looks like the same (IndexExp
    // receiver, offset) signature but need different results:
    //
    // - `true` (used only by the single top-level `&expr[i]` entry point,
    //   `addressOfExpression`'s `arrayPointer(index, 0, op)`): `array` IS
    //   the expression whose address is wanted. Once `element` (the address
    //   of `array` itself, composed from its own receiver) is known, that
    //   IS the answer -- no further `.index` composes past it, matching a
    //   pointer-to-a-dynamic-array-typed-subexpression being that
    //   subexpression's own header address, not its first element's.
    // - `false` (the default; every recursive `arrayPointer` call, plus the
    //   `&arr[i].field` member-call-receiver caller): `array[offset]`'s
    //   address is wanted. `element` above is only `array`'s OWN address,
    //   one level short -- `Place(element, array.type).index(offset)` must
    //   still run even when `offset == 0`, since for a dynamic-array row
    //   that dereferences `element`'s slice header to reach real element
    //   data, landing somewhere completely different from `element` itself.
    //
    // Conflating the two (treating `offset == 0` alone as "self", the bug
    // bbf236db left in place) silently returns a dynamic-array row's own
    // slice-header address instead of its element 0's data address whenever
    // the FINAL index in a nested chain (`a[0][0]`, `a[0][1][0]`, ...) is 0.
    // Whether `expression`'s own lvalue chain -- as `lvalue_place.
    // placeOfLvalue` would walk it, through `DotVarExp`/`PtrExp` receivers --
    // runs through an `IndexExp` anywhere. Pure syntax, no evaluation:
    // `arrayPointer`'s `IndexExp` arm uses this to detect, before evaluating
    // anything, whether its own unconditional `runExpressionValue(index.e1)`
    // would duplicate a side effect that `placeOfLvalue` is about to
    // evaluate again while resolving the same chain's address (`i++` inside
    // `arr[i++].mid.a[j]`).
    private static bool lvalueChainHasIndexExp(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression.isIndexExp !is null)
            return true;
        if (auto dot = expression.isDotVarExp)
            return lvalueChainHasIndexExp(dot.e1);
        if (auto ptr = expression.isPtrExp)
            return lvalueChainHasIndexExp(ptr.e1);
        // `lvalue_place.placeOfLvalue` itself walks straight through a
        // `CastExp` (its own `CastExp` arm recurses on the operand
        // unchanged); mirror that here so a cast-carrying chain
        // (`(cast(Outer[]) arr)[i++].mid.a[j]`) is detected from syntax
        // alone exactly like an uncast one, rather than silently taking the
        // old double-evaluating path below.
        if (auto cast_ = expression.isCastExp)
            return lvalueChainHasIndexExp(cast_.e1);
        return false;
    }

    // Compose this index expression from its receiver's already-resolved
    // place. Both nested-index and nested-field receivers take this route:
    // keeping the `$` binding, outer-index evaluation, and final-offset
    // composition together ensures each expression is evaluated once.
    private ExpressionResult nestedIndexPointer(
        Expression expression,
        Place receiverPlace,
        in long offset,
        in bool selfAddress,
    ) {
        import quickbite.backends.interpreter.place_value: readValue;

        auto index = expression.isIndexExp;
        assert(index !is null);
        if (index.lengthVar !is null)
            setLocal(
                index.lengthVar,
                ExpressionResult(AggregateValue.length(
                    AggregateValue.native(readValue(receiverPlace)),
                )),
            );
        const outerOffset = scalarOperand!size_t(index.e2);
        auto elementPlace = receiverPlace.index(outerOffset);
        if (selfAddress)
            return ExpressionResult.pointerValue(elementPlace.address);
        return ExpressionResult.pointerValue(
            Place(elementPlace.address, expression.type)
                .index(cast(size_t) offset)
                .address,
        );
    }

    // `computeIndex`'s `Place.index` calls raise `IndexOutOfBoundsException`
    // for a real, already-committed out-of-range guest index -- translate it
    // to the guest's own range error rather than letting the host exception
    // type escape. Deliberately narrower than a bare `Exception` catch:
    // `computeIndex` typically runs a full `runExpressionValue` of an index
    // expression along the way, which can raise an unrelated host failure
    // that must not be mislabeled as a guest range error.
    private ExpressionResult mapIndexOutOfBounds(
        scope ExpressionResult delegate() @system computeIndex,
    ) {
        import quickbite.backends.interpreter.place: IndexOutOfBoundsException;

        try {
            return computeIndex();
        } catch (IndexOutOfBoundsException exception) {
            throwRangeError(exception.msg);
            assert(0);
        }
    }

    private ExpressionResult arrayPointer(
        imported!"dmd.expression".Expression array,
        in long offset,
        in imported!"dmd.tokens".EXP op,
        in bool selfAddress = false,
    )
    in (!selfAddress || offset == 0, "selfAddress is only ever paired with offset 0") {
        import std.conv: text;

        auto var = array.isVarExp;
        if (var is null) {
            if (auto comma = array.isCommaExp) {
                executeForEffect(comma.e1);
                return arrayPointer(comma.e2, offset, op, selfAddress);
            }
            if (auto question = array.isCondExp)
                return arrayPointer(
                    conditionTruthy(question.econd) ? question.e1 : question.e2,
                    offset,
                    op,
                    selfAddress,
                );

            // DMD lowers indexing a dynamic-array call through a pointer
            // cast of the CallExp, rather than leaving the IndexExp as the
            // direct address-taking operand.  Evaluate that call once and
            // compose its element address from the returned typed slice.
            if (auto call = array.isCallExp) {
                const arrayValue = constructedExpressionValue(call);
                if (AggregateValue.isArray(arrayValue))
                    return ExpressionResult.pointerValue(
                        AggregateValue.elementAddress(
                            arrayValue,
                            cast(size_t) offset,
                        ),
                    );
            }

            if (auto index = array.isIndexExp) {
                import quickbite.backends.interpreter.layout: typeByteSize;

                // A nested index receiver (`m[i++][j]`) must compose its
                // address before reading its value. Reading `m[i++]` here
                // and recursively composing its address below would run the
                // inner index twice.
                if (auto inner = index.e1.isIndexExp) {
                    if (inner.e1.isVarExp !is null) {
                        import quickbite.backends.interpreter.lvalue_place:
                            placeOfLvalue;
                        import quickbite.backends.interpreter.place:
                            Place;

                        Place resolveInnerPlace() {
                            return placeOfLvalue(
                                inner,
                                (variable) @safe =>
                                    addressableBindingBase(variable),
                                (expression) @system =>
                                    scalarOperand!size_t(expression),
                                // @trusted: `setLocal` is @system because it is
                                // part of the interpreter's general storage
                                // machinery. Here it only binds the `$` length
                                // variable belonging to the index being walked.
                                // `base` is already an addressable Place, so
                                // its length reads directly off the header
                                // bytes -- no whole-value read needed just to
                                // discard everything but the count.
                                (chainIndex, base) @trusted {
                                    if (chainIndex.lengthVar !is null)
                                        setLocal(
                                            chainIndex.lengthVar,
                                            ExpressionResult(base.arrayLength),
                                        );
                                },
                            );
                        }

                        // A static-array row's length (`P[2]` here) is a
                        // compile-time fact that needs no runtime row
                        // address, and DMD's own codegen for
                        // `m[outer][inner]` bounds-checks `inner` against it
                        // before ever evaluating `outer`: confirmed against
                        // `SystemLinker`, `outer`'s own index expression is
                        // never called at all when `inner`'s value is
                        // already out of range, and when only `outer` is out
                        // of range, `inner`'s side effect still runs exactly
                        // once, before `outer`'s.
                        if (auto rowArray = index.e1.type.toBasetype.isTypeSArray) {
                            import quickbite.backends.interpreter.layout:
                                staticArrayLength;

                            const rowLength = staticArrayLength(rowArray);
                            if (index.lengthVar !is null)
                                setLocal(index.lengthVar, ExpressionResult(rowLength));
                            const elementOffset = scalarOperand!size_t(index.e2);
                            if (elementOffset >= rowLength)
                                throwRangeError(
                                    "quickbite.backends.interpreter.place.Place.index: "
                                    ~ "index out of range for static array place",
                                );

                            return mapIndexOutOfBounds(delegate ExpressionResult() {
                                auto elementPlace = resolveInnerPlace().index(elementOffset);
                                if (selfAddress)
                                    return ExpressionResult.pointerValue(elementPlace.address);
                                return ExpressionResult.pointerValue(
                                    Place(elementPlace.address, array.type)
                                        .index(cast(size_t) offset)
                                        .address,
                                );
                            });
                        }

                        return mapIndexOutOfBounds(() =>
                            nestedIndexPointer(
                                array,
                                resolveInnerPlace(),
                                offset,
                                selfAddress,
                            )
                        );
                    }
                }

                // A doubly (or more) nested `DotVarExp` receiver whose own
                // chain runs through an `IndexExp` somewhere
                // (`arr[i++].mid.a[j]`, `s.a[i++].mid.b[j]`, ...) must be
                // resolved through `lvalue_place.placeOfLvalue` BEFORE this
                // arm's own unconditional `runExpressionValue(index.e1)` below
                // ever runs: that eager evaluation exists to read
                // `index.e1`'s VALUE (for `$` support and the
                // native-aggregate fallback further down), but it fully
                // evaluates the exact same chain `placeOfLvalue` needs to
                // walk again to resolve an ADDRESS -- side-effecting index
                // included (`i++`). Running both evaluates that index twice
                // and the second (wrong) value wins. Detect the hazard from
                // the syntax alone, with no evaluation of anything, and
                // resolve the address in one single walk instead, skipping
                // the eager value read entirely for this shape. A chain
                // with no `IndexExp` in it (e.g. `s.inner.a[i]`) has nothing
                // for the eager read to duplicate, so it keeps taking the
                // ordinary path below unchanged.
                if (auto nestedField = index.e1.isDotVarExp) {
                    if (
                        nestedField.e1.isDotVarExp !is null &&
                        lvalueChainHasIndexExp(nestedField)
                    ) {
                        import quickbite.backends.interpreter.lvalue_place:
                            placeOfLvalue, UnsupportedLvalueShapeException;

                        // `placeOfLvalue` refuses a receiver shape it does
                        // not support (e.g. a `CallExp` base,
                        // `makeHolder().arr[1].mid.a[1]`) by throwing --
                        // same contract the neighbouring doubly-nested-
                        // `DotVarExp`-without-side-effecting-index branch
                        // below already relies on. `placeOfLvalue` always
                        // resolves a chain's BASE before evaluating its own
                        // index, so a refusal here always throws before any
                        // index side effect in the chain has run; falling
                        // through to the eager path below to re-resolve the
                        // whole receiver from scratch is therefore safe,
                        // exactly as safe as it is for that neighbouring
                        // branch.
                        try {
                            return mapIndexOutOfBounds(() {
                                auto fieldPlace = placeOfLvalue(
                                    nestedField,
                                    (variable) @safe => addressableBindingBase(variable),
                                    (expression) @system =>
                                        scalarOperand!size_t(expression),
                                    // `$` inside a CHAIN `IndexExp`'s own index
                                    // (e.g. `arr[$ - 1]` inside
                                    // `arr[$ - 1].mid.a[j]`) is bound to THAT
                                    // `IndexExp`'s own `lengthVar` from ITS OWN
                                    // receiver's length -- exactly what
                                    // `runIndexExpression` binds as a side
                                    // effect of evaluating an `IndexExp` on the
                                    // ordinary eager path this branch skips.
                                    // `placeOfLvalue` calls this once per
                                    // `IndexExp` it resolves, with that
                                    // `IndexExp` and its own base's `Place`,
                                    // before evaluating the index itself, so
                                    // binding it here needs no separate,
                                    // potentially-double-evaluating pre-walk.
                                    // @trusted: `setLocal` itself carries no
                                    // attribute (defaults to `@system`); this is
                                    // the same local-binding write every
                                    // ordinary `$` binding elsewhere in this
                                    // class already performs (`index.lengthVar`
                                    // a few lines below), called here only to
                                    // make `$` visible to the chain index
                                    // subexpression it names. `base` is
                                    // already an addressable Place, so its
                                    // length reads directly off the header
                                    // bytes -- no whole-value read needed
                                    // just to discard everything but the
                                    // count.
                                    (chainIndex, base) @trusted {
                                        if (chainIndex.lengthVar !is null)
                                            setLocal(
                                                chainIndex.lengthVar,
                                                ExpressionResult(base.arrayLength),
                                            );
                                    },
                                );
                                return nestedIndexPointer(
                                    array,
                                    fieldPlace,
                                    offset,
                                    selfAddress,
                                );
                            });
                        } catch (UnsupportedLvalueShapeException) {
                            // Fall through to the eager path below for a
                            // receiver shape `placeOfLvalue` does not (yet)
                            // support -- safe refusal is preferable to
                            // inventing a copied pointee, same reasoning as
                            // the neighbouring branch's own catch. A guest
                            // exception raised while composing the receiver
                            // (a bounds failure from a side-effecting chain
                            // index, in particular) is a different type and
                            // does not land here.
                        } catch (InterpretedException exception) {
                            // Already the guest's own exception object --
                            // propagate it unchanged rather than reaching
                            // the generic `Exception` arm below.
                            throw exception;
                        }
                    }
                }

                // An address-taking index must evaluate its receiver before
                // the index: `$` is bound to this receiver's present length,
                // and a call result has no VarExp from which the old path can
                // reconstruct an address.  The native aggregate value keeps
                // the receiver rooted while its typed element address is
                // composed, so neither expression is evaluated a second
                // time.
                // A non-ref dynamic-array call returns the interpreter's
                // one-element result carrier.  Its target is still the one
                // evaluated slice value, not an addressable pointer into the
                // guest array.
                const arrayValue = constructedExpressionValue(index.e1);
                if (index.lengthVar !is null) {
                    const sourceLength = AggregateValue.length(AggregateValue.native(arrayValue));
                    setLocal(index.lengthVar, ExpressionResult(sourceLength));
                }

                const outerOffset = scalarOperand!long(index.e2);
                // An indexed binding is an lvalue even when its evaluated
                // aggregate value retains an initializer handle. Compose
                // from the binding's current place so a `ref` static-array
                // local and its source name the same inline bytes.
                if (index.e1.isVarExp !is null) {
                    // Always element mode: `element` below is `index.e1`'s
                    // own address, one level short of `array`'s (this
                    // IndexExp's) element -- see `arrayPointer`'s
                    // `selfAddress` doc comment.
                    const element = arrayPointer(index.e1, outerOffset, op);
                    if (element.isPointer) {
                        if (selfAddress)
                            return element;
                        // A raw byte offset from `element` would land inside
                        // a slice header instead of the row's data when this
                        // row is itself a dynamic array (e.g. `int[][]`).
                        // `Place.index` dereferences that header first, and
                        // strides directly for a static-array row -- the
                        // same composition the fallthrough case below uses.
                        // This must run even when `offset == 0`: for a
                        // dynamic-array row, element 0's real data address is
                        // NOT `element` itself (that is the row's own header
                        // address), it is one dereference further in.
                        import quickbite.backends.interpreter.place: Place;

                        return ExpressionResult.pointerValue(
                            Place(cast(void*) element.pointerAddress, array.type)
                                .index(cast(size_t) offset)
                                .address,
                        );
                    }
                }
                if (auto field = index.e1.isDotVarExp) {
                    if (field.e1.isVarExp !is null) {
                        // Always element mode -- same reasoning as the
                        // `VarExp` arm above: `pointer` is `field`'s own
                        // address, one level short of `array`'s (this
                        // IndexExp's) element.
                        const pointer = arrayPointer(field, outerOffset, op);
                        if (pointer.isPointer) {
                            if (selfAddress)
                                return pointer;
                            // Same hazard as the `VarExp` arm above: a raw
                            // byte offset from `pointer` would land inside a
                            // slice header instead of the row's data when
                            // this row is itself a dynamic array. Compose
                            // through `Place.index` instead, even when
                            // `offset == 0`.
                            import quickbite.backends.interpreter.place: Place;

                            return ExpressionResult.pointerValue(
                                Place(cast(void*) pointer.pointerAddress, array.type)
                                    .index(cast(size_t) offset)
                                    .address,
                            );
                        }
                    } else if (field.e1.isDotVarExp !is null) {
                        // A doubly (or more) nested field receiver
                        // (`s.inner.a[i]`, `field.e1` itself a `DotVarExp`)
                        // has no `VarExp` for the fast path above to recurse
                        // `arrayPointer` from -- and `arrayPointer`'s own
                        // `DotVarExp` arm below only recognizes a `VarExp`
                        // receiver too, so recursing into it here would hit
                        // the exact same gap one level deeper.
                        // `lvalue_place.placeOfLvalue` already recurses
                        // through an arbitrarily nested `DotVarExp`/`VarExp`
                        // chain to the field's own place without
                        // re-evaluating any side effect (unlike
                        // `addressOfExpression`, whose `DotVarExp` arm
                        // special-cases a static-array-typed field straight
                        // back into this same `arrayPointer` gap); reuse it
                        // for `field`'s own place, then compose the
                        // `outerOffset`'th element the same way the `VarExp`
                        // fast path above does.
                        import quickbite.backends.interpreter.lvalue_place:
                            placeOfLvalue, UnsupportedLvalueShapeException;
                        import quickbite.backends.interpreter.place:
                            Place;

                        try {
                            return mapIndexOutOfBounds(delegate ExpressionResult() {
                                auto fieldPlace = placeOfLvalue(
                                    field,
                                    (variable) @safe => addressableBindingBase(variable),
                                    (expression) @system =>
                                        scalarOperand!size_t(expression),
                                );
                                auto elementPlace = fieldPlace.index(cast(size_t) outerOffset);
                                if (selfAddress)
                                    return ExpressionResult.pointerValue(elementPlace.address);
                                // Same hazard as the `VarExp` arm above.
                                return ExpressionResult.pointerValue(
                                    Place(elementPlace.address, array.type)
                                        .index(cast(size_t) offset)
                                        .address,
                                );
                            });
                        } catch (UnsupportedLvalueShapeException) {
                            // Fall through to the detached-copy fallback
                            // below for a receiver shape `placeOfLvalue`
                            // does not (yet) support -- safe refusal is
                            // preferable to inventing a copied pointee. A
                            // guest exception raised while composing the
                            // receiver does not land here.
                        } catch (InterpretedException exception) {
                            // Already the guest's own exception object --
                            // propagate it unchanged rather than reaching
                            // the generic `Exception` arm below.
                            throw exception;
                        }
                    }
                }
                // A nested/multi-dimensional static-array index
                // (`m[i][j]`, `m.e1` itself an `IndexExp`) must compose its
                // receiver's address the same way the `VarExp` case above
                // does, rather than falling through to `arrayValue` below:
                // `arrayValue` is `runExpressionValue(index.e1)`'s result, and
                // reading a static-array-typed rvalue copies its bytes
                // (`place_value.readValue`'s array arm returns
                // `AggregateValue.copyFromAddress`). Composing the address
                // from that copy silently detaches the receiver from `m`'s
                // real backing storage, so a method call through it (or any
                // further write) is lost.
                if (index.e1.isIndexExp !is null) {
                    // Always element mode -- same reasoning as the `VarExp`
                    // arm above.
                    const element = arrayPointer(index.e1, outerOffset, op);
                    if (element.isPointer) {
                        if (selfAddress)
                            return element;
                        // Same hazard as the `VarExp` arm above: a raw byte
                        // offset from `element` would land inside a slice
                        // header instead of the row's data when this nested
                        // row is itself a dynamic array. Compose through
                        // `Place.index` instead, even when `offset == 0`
                        // (the FINAL index of a nested chain like
                        // `a[0][1][0]`, where `element` is `a[0][1]`'s own
                        // header address, not `a[0][1][0]`'s data address).
                        import quickbite.backends.interpreter.place: Place;

                        return ExpressionResult.pointerValue(
                            Place(cast(void*) element.pointerAddress, array.type)
                                .index(cast(size_t) offset)
                                .address,
                        );
                    }
                }
                if (AggregateValue.isArray(arrayValue)) {
                    // `index.e1` had no VarExp/DotVarExp receiver, so it
                    // was just re-evaluated above as a second, independent
                    // call/index. Keep that result's storage alive until
                    // the enclosing expression stores or discards the
                    // composed address.
                    import quickbite.backends.interpreter.place: Place;

                    auto aggregate = AggregateValue.native(arrayValue);
                    retainTemporaryPointerOwner(aggregate.storage);
                    // Compose straight from the already-resolved native
                    // owner instead of a second `AggregateValue.elementAddress`
                    // call, which would only re-derive the same owner from
                    // `arrayValue` again.
                    auto elementAddress = Place(aggregate.address, aggregate.type)
                        .index(cast(size_t) outerOffset)
                        .address;
                    if (selfAddress)
                        return ExpressionResult.pointerValue(elementAddress);

                    return ExpressionResult.pointerValue(
                        Place(elementAddress, array.type)
                            .index(cast(size_t) offset)
                            .address,
                    );
                }

                // Non-array receivers (notably pointer indexing) retain the
                // established address path. `array.type` (this whole
                // `IndexExp`'s own type, e.g. `Point`) has no `nextOf` to
                // stride by when it names the pointee directly rather than a
                // further array/pointer level -- exactly DMD's own
                // `_d_aaGetRvalueX`-lowered pointer-dereference shape
                // (`revertModifiableAAIndexReads`/`revertIndexAssignToRvalues`
                // in `expressionsem.d`, reached here via a mutating AA-value
                // method-call receiver, `aa[key].method()`), so no further
                // offset composes past this element -- matching the
                // `selfAddress` early return the `index.e1.isVarExp` arm
                // above already takes for the identical reason. (Raw
                // pointer arithmetic has no slice header to dereference, so
                // `offset == 0` is harmless here either way; `selfAddress`
                // is used for consistency with the other arms.)
                const pointer = arrayPointer(index.e1, outerOffset, op);
                if (pointer.isPointer) {
                    if (selfAddress)
                        return pointer;
                    return pointer.pointerOffsetBy(
                        offset * cast(long) typeByteSize(
                            array.type.toBasetype.nextOf,
                        ),
                    );
                }
            }

            if (auto dot = array.isDotVarExp) {
                // A static-array field's real address, for any receiver
                // chain `lvalue_place.placeOfLvalue` can compose -- a bare
                // local (`s.arr`), a class field, or a receiver that is
                // itself a further field access reached through a struct,
                // class, or raw-pointer receiver (`p.entry.value`, the
                // `Entry*` pointer chain a druntime AA bucket composes).
                // Falling through to the detached-copy fallback below for
                // any of these silently returns the address of a
                // byte-for-byte snapshot instead of the field's real
                // storage: a write through it is lost, and a read reflects
                // whatever the snapshot held at copy time, not the field's
                // live value.
                import quickbite.backends.interpreter.lvalue_place:
                    placeOfLvalue, UnsupportedLvalueShapeException;

                try {
                    return mapIndexOutOfBounds(() {
                        auto fieldPlace = placeOfLvalue(
                            dot,
                            (variable) @safe => addressableBindingBase(variable),
                            (expression) @system =>
                                scalarOperand!size_t(expression),
                        );
                        return ExpressionResult.pointerValue(
                            fieldPlace.index(cast(size_t) offset).address,
                        );
                    });
                } catch (UnsupportedLvalueShapeException) {
                    // Fall through to the detached-copy fallback below for
                    // a receiver shape `placeOfLvalue` does not (yet)
                    // support -- safe refusal is preferable to inventing a
                    // copied pointee, the same reasoning the neighbouring
                    // `IndexExp` branches in this function already apply.
                } catch (InterpretedException exception) {
                    // Already the guest's own exception object --
                    // propagate it unchanged rather than reaching the
                    // generic `Exception` arm below.
                    throw exception;
                }

                const value = constructedExpressionValue(array);
                return ExpressionResult.pointerValue(
                    AggregateValue.elementAddress(value, cast(size_t) offset),
                );
            }

            throw new Exception(text("Unsupported eval expression: ", op));
        }

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        // Materialize a dataseg variable's declared default before handing
        // out its module-table address. Frame bindings are already initialized
        // at declaration.
        materializeDatasegInitializer(variable);

        if (!hasBindingPlace(variable))
            throw new Exception(text("Unsupported eval expression: ", op));
        return ExpressionResult.pointerValue(
            bindingPlace(variable).index(cast(size_t) offset).address,
        );
    }

    // `&local`, and `&buf[constantIndex]` which DMD folds to
    // SymOffExp(buf, byteOffset): a pointer into a static array's elements
    // mirrors the unfolded `&buf[i]` IndexExp shape; anything else points at
    // the local's slot.
    private ExpressionResult symbolOffsetLocalValue(
        imported!"dmd.expression".SymOffExp symbol,
        VarDeclaration variable,
    ) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        materializeDatasegInitializer(variable);

        if (!hasBindingPlace(variable))
            throw new Exception("Symbol offset has no native binding place.");
        if (isStaticArrayType(variable.type) &&
            isStaticArrayType(symbol.type.toBasetype.nextOf))
            return ExpressionResult.pointerValue(bindingPlace(variable).address);
        return ExpressionResult.pointerValue(bindingPlace(variable).address)
            .pointerOffsetBy(cast(long) symbol.offset);
    }

    private ExpressionResult bindingPointerValue(VarDeclaration variable) {
        materializeDatasegInitializer(variable);
        if (!hasBindingPlace(variable))
            throw new Exception("Binding has no native address.");
        return ExpressionResult.pointerValue(bindingPlace(variable).address);
    }

    // Evaluates a dataseg variable's own initializer expression in a frame
    // sized for THAT EXPRESSION alone, not whatever function happens to be
    // running when the lazy materialization triggers. A module-scope AA
    // literal's `_d_assocarrayliteralTX` lowering hoists its keys/values
    // arrays into `__arrayliteral_on_stack*` temporaries parented to the
    // initializer's own (module) scope, never to any `FuncDeclaration`'s
    // body (`frame_layout.computeExpressionFrameLayout`'s own comment) --
    // reusing the triggering function's already-computed frame, or the
    // frame-less root the top-level `execute` entry point starts with,
    // leaves such a temp with no slot anywhere, so `setLocal` rejects it
    // ("has no native place"). The initializer can only name other module-
    // scope declarations and its own literal/temp values -- never a local
    // of whatever function triggered this -- so swapping in a dedicated
    // frame around just this evaluation is exact, not an approximation.
    private ExpressionResult evaluateDatasegInitializerExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import quickbite.backends.interpreter.frame_layout:
            computeExpressionFrameLayout;

        auto outer = _activationFrame;
        scope(exit) _activationFrame = outer;

        _activationFrame = FrameBlock.allocate(
            computeExpressionFrameLayout(expression),
        );
        return constructedExpressionValue(expression);
    }

    private void materializeDatasegInitializer(VarDeclaration variable) {
        if (
            !variable.isDataseg || externDataSymbolAddress(variable) !is null ||
            moduleTable.has(variable)
        )
            return;

        // A never-written dataseg variable's module-table block is raw
        // zeroed GC memory (`ModuleTable.allocateBlock`/`NativeBlock.
        // allocate`), not its declared type's default value: the hand-rolled
        // `defaultValue` free function recurses on each struct field's own
        // TYPE default (`runtime_values.structDefaultValue`), silently
        // dropping a field's own default initializer (`int x = 7;` reads
        // back `0`, the field type's `.init`, not `7`). DMD's own
        // `defaultInitLiteral` is the layout-authority source for a default
        // value (the "Layout authority" contract): it already walks
        // `VarDeclaration._init`/`getConstInitializer` per field
        // (`typesem.d`), so evaluating it through the ordinary expression
        // path builds the correct native default.
        //
        if (variable._init is null) {
            import dmd.typesem: defaultInitLiteral;

            setLocal(variable, evaluateDatasegInitializerExpression(
                variable.type.defaultInitLiteral(variable.loc),
            ));
            return;
        }

        resolveNonRootInitializer(variable);

        // A scalar `= expr` initializer parses as `ExpInitializer` directly,
        // but a bracketed array literal (`int[] arr = [1, 2, 3];`) parses as
        // an `ArrayInitializer` instead -- DMD's parser decides between the
        // two by scanning ahead to the token following the closing `]`
        // (`parse.d`'s `parseInitializer`). `initializerToExpression`
        // converts either shape to the same plain `Expression` (an
        // `ArrayLiteralExp` for the array case), so this stays the single
        // dataseg-initializer path for both.
        import dmd.initsem: initializerToExpression;

        auto initializerExp = variable._init.initializerToExpression;
        if (initializerExp !is null) {
            defaultLocalValue(variable);
            setLocal(variable, storageValue(
                variable.type,
                evaluateDatasegInitializerExpression(initializerExp),
            ));
        }
    }

    // Write scalar leaves of a struct cell into its native layout.
    private void writeStructCellScalarFields(ref NativeStruct cell, in ExpressionResult structValue) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: fieldByteOffset;
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeScalarLeaf;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        foreach (index; 0 .. cell.fieldCount) {
            auto fieldType = cell.fieldDeclaration(index).type;

            if (isNativeScalarType(fieldType)) {
                writeScalarLeaf(
                    Place(cell.field(index).ptr, fieldType),
                    readStoredValue(
                        AggregateValue.fieldAt(AggregateValue.native(structValue), index),
                    ),
                );
                continue;
            }

            if (isStaticArrayType(fieldType)) {
                auto elementType = fieldType.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                const fieldValue = readStoredValue(
                    AggregateValue.fieldAt(AggregateValue.native(structValue), index),
                );
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = cell.arrayField(index);
                foreach (elementIndex; 0 .. AggregateValue.elementCount(fieldValue))
                    writeArrayCellElement(
                        arrayCell,
                        elementIndex,
                        readStoredValue(
                            AggregateValue.elementAt(AggregateValue.native(fieldValue), elementIndex),
                        ),
                    );
                continue;
            }

            if (isDynamicArrayType(fieldType)) {
                auto elementType = fieldType.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                const fieldValue = readStoredValue(
                    AggregateValue.fieldAt(AggregateValue.native(structValue), index),
                );
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = NativeArray.allocate(elementType,
                    AggregateValue.elementCount(fieldValue));
                foreach (elementIndex; 0 .. AggregateValue.elementCount(fieldValue))
                    writeArrayCellElement(
                        arrayCell,
                        elementIndex,
                        readStoredValue(
                            AggregateValue.elementAt(AggregateValue.native(fieldValue), elementIndex),
                        ),
                    );
                arrayCell.writeSliceHeader(
                    cell.block,
                    fieldByteOffset(cell.fieldDeclaration(index)),
                );
                continue;
            }

            auto nestedStructType = fieldType.toBasetype.isTypeStruct;
            if (nestedStructType is null || nestedStructType.sym.isUnionDeclaration !is null)
                continue;

            const nestedValue = readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(structValue), index),
            );
            if (!AggregateValue.isStruct(nestedValue))
                continue;

            auto nestedCell = cell.structField(index);
            writeStructCellScalarFields(nestedCell, nestedValue);
        }
    }

    private ExpressionResult readBindingValue(VarDeclaration variable) {
        materializeDatasegInitializer(variable);

        if (hasBindingPlace(variable))
            return readStoredValue(bindingPlace(variable));

        return defaultValueResult(variable.type);
    }

    private ExpressionResult functionPointerValue(FuncDeclaration function_) {
        if (auto id = function_ in functionPointerIds)
            return ExpressionResult.functionPointerValue(*id);

        const id = ++nextFunctionPointerId;
        functionPointerIds[function_] = id;
        functionPointers[id] = function_;
        return ExpressionResult.functionPointerValue(id);
    }

    private ExpressionResult newFunctionPointerValue(FuncDeclaration function_) {
        const id = ++nextFunctionPointerId;
        functionPointers[id] = function_;
        return ExpressionResult.functionPointerValue(id);
    }

    private ExpressionResult runDelegateExpression(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        if (delegate_.func is null)
            throw new Exception("Unsupported eval expression: delegate_");

        const functionPointer = newFunctionPointerValue(delegate_.func);
        const contextPointer = delegateContextPointer(delegate_);

        RuntimeDelegate runtime;
        runtime.function_ = delegate_.func;
        runtime.functionPointerId = functionPointer.functionPointerId;
        runtime.contextPointer = contextPointer.pointerAddress;
        runtime.capturedAddresses = closureCapturedAddresses(delegate_.func);
        if (isMemberFunction(delegate_.func)) {
            if (delegate_.e1 is null)
                throw new Exception("Unsupported eval expression: delegate_");

            runtime.receiver = nativeAggregateFrom(runExpressionValue(delegate_.e1), delegate_.e1.type);
            runtime.hasReceiver = true;
        }

        _executionState.delegates[functionPointer.functionPointerId] = runtime;
        return functionPointer;
    }

    private ExpressionResult runFunctionLiteralDeclaration(
        imported!"dmd.expression".FuncExp literal,
    ) {
        if (literal.fd is null)
            throw new Exception("Unsupported eval expression: functionLiteral");

        const functionPointer = newFunctionPointerValue(literal.fd);

        RuntimeDelegate runtime;
        runtime.function_ = literal.fd;
        runtime.functionPointerId = functionPointer.functionPointerId;
        runtime.contextPointer = null;
        runtime.capturedAddresses = closureCapturedAddresses(literal.fd);
        if (literal.fd.isNested && hasThis) {
            runtime.receiver = nativeAggregateFrom(receiverValue(thisValue), thisValue.type);
            runtime.hasReceiver = true;
        }

        _executionState.delegates[functionPointer.functionPointerId] = runtime;
        return functionPointer;
    }

    // Each of `function_`'s captured outer variables (`frame_layout.
    // capturedVariables`), resolved to ITS OWN address in THIS activation
    // -- the lexically enclosing one, still live right now, whether or not
    // it later returns before the created delegate is called. Reuses
    // `bindingPointerValue`, the same address resolution a `&variable`
    // expression already uses, rather than re-deriving frame addresses.
    // Declines (omits the entry, never throws) a captured variable
    // `bindingPointerValue` cannot resolve to a real address yet; the
    // call-time fallback (`bindCapturedReferenceSlots`'s own
    // `callerReferenceBase` path) still applies for it, unchanged.
    private void*[VarDeclaration] closureCapturedAddresses(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;

        if (!function_.isNested)
            return null;

        void*[VarDeclaration] addresses;
        foreach (variable; capturedVariables(function_)) {
            try {
                auto address = capturedBindingAddress(variable);
                if (address !is null) {
                    addresses[variable] = address;
                    retainCapturedFrameMetadata(address);
                }
            } catch (Exception) {
                continue;
            }
        }

        return addresses;
    }

    // Mark the activation that owns a captured address, following ordinary
    // dynamic callers as well as lexical static links. A `ref` capture can
    // point through several reference slots before reaching the owning frame,
    // so address containment, not declaration identity, is authoritative.
    private void retainCapturedFrameMetadata(const(void)* address) {
        if (_activationFrame.ownsAddress(address)) {
            _activationFrameMetadataRetained = true;
            return;
        }

        for (
            auto lifetime = _callerFrameMetadataLifetime;
            lifetime !is null;
            lifetime = lifetime.caller
        )
            if (lifetime.frame.ownsAddress(address)) {
                *lifetime.retained = true;
                return;
            }
    }

    private ExpressionResult delegateContextPointer(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;

        if (delegate_.e1 !is null) {
            if (auto var = delegate_.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    return bindingPointerValue(variable);
        }

        if (delegate_.func !is null && delegate_.func.isNested) {
            auto captures = capturedVariables(delegate_.func);
            if (captures.length != 0)
                return bindingPointerValue(captures[0]);
        }

        return ExpressionResult.pointerValue(null);
    }

    private ExpressionResult runPointerExpression(
        imported!"dmd.expression".PtrExp pointer,
    ) {
        return dereferencePointerValue(pointer, runExpressionValue(pointer.e1));
    }

    // The dereference half of `runPointerExpression`, split out so a caller
    // that already evaluated `pointer.e1` itself (to also retain that
    // address for a later use, e.g. a member-call receiver rebind) can reuse
    // that single evaluation instead of running the -- possibly
    // side-effecting -- pointer operand a second time.
    private ExpressionResult dereferencePointerValue(
        imported!"dmd.expression".PtrExp pointer,
        in ExpressionResult value,
    ) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        if (value.isFunctionPointer)
            return value;

        if (isStaticArrayType(pointer.type))
            return staticArrayPointerView(value, pointer.e1.type, pointer.type);

        if (value.isPointer)
            return loadNativePointerElement(pointer.e1.type, value, 0);

        throw new Exception(
            "quickbite.backends.interpreter.impl.Walker.runPointerExpression: "
            ~ "data pointers must carry a native binding address",
        );
    }

    private ExpressionResult staticArrayPointerView(
        in ExpressionResult pointer,
        imported!"dmd.mtype".Type pointerType,
        imported!"dmd.mtype".Type staticArrayType,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: staticArrayLength;

        auto staticArray = staticArrayType.toBasetype.isTypeSArray;
        const length = staticArrayLength(staticArray);
        const target = loadNativePointerElement(pointerType, pointer, 0);
        if (AggregateValue.isArray(target))
            return target;
        throw new Exception("Static-array pointer did not address an array value.");
    }

    private ExpressionResult[] arrayElements(in ExpressionResult value) {
        auto aggregate = AggregateValue.native(value);
        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(aggregate))
            elements ~= readStoredValue(AggregateValue.elementAt(aggregate, index));

        return elements;
    }

    private ExpressionResult[] arrayPointerElements(in ExpressionResult value) {
        return arrayElements(value);
    }

    private long arrayPointerOffset(in ExpressionResult value, in long offset) {
        return offset;
    }

    // A void-typed conditional has no result to construct: each arm runs for
    // its own effect only, mirroring `runLogicalAndExpression`/
    // `runLogicalOrExpression`'s void-typed case. A non-void conditional
    // goes through `constructedExpressionValue` instead (`constructInto`'s
    // `CondExp` arm recurses into whichever arm is selected, so it already
    // covers every result type family).
    private ExpressionResult runConditionalExpression(
        imported!"dmd.expression".CondExp conditional,
    ) {
        return conditionTruthy(conditional.econd) ?
            runExpressionValue(conditional.e1) :
            runExpressionValue(conditional.e2);
    }

    private ExpressionResult runIdentityExpression(
        imported!"dmd.expression".IdentityExp identity,
    ) {
        import dmd.tokens: EXP;

        const same = identityOperands(identity);
        if (identity.op == EXP.notIdentity)
            return ExpressionResult(!same);

        return ExpressionResult(same);
    }

    // `is`/`!is` never rewrites for operator overloading the way `==` does
    // (`opover.d` has no `opOverloadIdentity`), so every static operand
    // shape -- scalar, pointer, associative-array handle, class reference,
    // struct, array, delegate, `typeid`/`.classinfo` -- can reach here
    // directly, unlike `equalOperands`'s narrower set. Dispatch the two
    // shapes with an unambiguous native-layout read straight to that read,
    // on the STATIC type rather than a runtime tag off an
    // already-evaluated carrier value: a scalar pair (`hasScalarEqualityOperands`,
    // shared with `runEqualExpression`'s own scalar fast path) loads its
    // host value directly, and a pointer or associative-array handle
    // (`pointerLikeIdentityType`) is its own storage slot's stored address
    // (`Place.deref`). Everything else keeps evaluating through the
    // carrier, in `carrierIdentity`.
    private bool identityOperands(imported!"dmd.expression".IdentityExp identity) {
        if (hasScalarEqualityOperands(identity))
            return scalarEquality(identity);

        if (
            pointerLikeIdentityType(identity.e1.type) &&
            pointerLikeIdentityType(identity.e2.type)
        )
            return pointerOperandPlace(identity.e1).deref.address ==
                pointerOperandPlace(identity.e2).deref.address;

        return carrierIdentity(identity);
    }

    // A pointer or associative-array handle is never `TypeName`-tagged --
    // that carrier representation exists only for a `typeid`/`.classinfo`
    // result, which is always class-typed -- so its identity is always its
    // own storage slot's stored address. A class reference is excluded even
    // though `Place.deref` reads it the same way, because a `typeid`/
    // `.classinfo` result IS class-typed and has no native-layout place at
    // all. A function pointer (`Tpointer` to `Tfunction`) is excluded too:
    // it has no native binding address in this interpreter yet
    // (`expressions.d`'s
    // `nonCapturingLambdaReturningLambdaIsAFunctionPointer` divergence).
    private bool pointerLikeIdentityType(imported!"dmd.mtype".Type type) {
        import dmd.astenums: TY;

        // `auto`: `nextOf` is a mutable-only `dmd.mtype.Type` method, so
        // `base` cannot be `const`.
        auto base = type.toBasetype;
        if (base.ty == TY.Taarray)
            return true;
        if (base.ty != TY.Tpointer)
            return false;

        return base.nextOf.toBasetype.ty != TY.Tfunction;
    }

    // dmd lowers a POD struct's `==` (no user-defined `opEquals`) into an
    // `is` expression (`IdentityExp`), since memberwise equality and
    // bitwise identity coincide for such structs. Route that case through
    // `equalValues` (the same field-recursive, numeric-scalar-coercing
    // comparison a direct `==` uses) instead of a raw `ExpressionResult`
    // compare: a native class aggregate and a pointer-valued class
    // reference both normalize to their shared object-body address.
    // Array-pointer snapshots can
    // contain different element copies while still naming the same
    // allocation and offset; those two fields are their identity. A
    // function pointer or delegate compares its raw carrier representation
    // (the same `FunctionPointer` id `functionPointerValue` caches per
    // `FuncDeclaration`, or mints per closure literal): unlike `==`'s
    // `equalDelegateValues`, `is` needs no `capturedAddresses` fallback,
    // since two references to the very same closure activation always share
    // one id.
    private bool carrierIdentity(imported!"dmd.expression".IdentityExp identity) {
        const left = runExpressionValue(identity.e1);
        const right = runExpressionValue(identity.e2);

        const aggregateValues =
            AggregateValue.isStruct(left) && AggregateValue.isStruct(right) ||
            AggregateValue.isArray(left) && AggregateValue.isArray(right);
        const nullPointerIdentity =
            left.isPointer && left.pointerAddress is null &&
                right == ExpressionResult.null_ ||
            right.isPointer && right.pointerAddress is null &&
                left == ExpressionResult.null_;
        // A symbolic typeid/classinfo (no host `TypeInfo` for the type it
        // names) never reaches here as a raw written slot: `runClassInfoExpression`/
        // `runTypeidExpression` always answer with the resolved identity
        // itself -- a real host address when one exists, the display name
        // otherwise -- so comparing the two evaluated carriers directly
        // already compares identities, not incidental storage. Two
        // evaluations of the same guest-only type share one display name
        // (`left == right` on `TypeName` compares that string); two of the
        // same resolved native type share one host address (falls through
        // to `classIdentityAddress`'s `isPointer` arm below, an ordinary
        // address compare).
        return
            left.isTypeName || right.isTypeName
            ? left == right
            : identity.e1.isTypeidExp is null && identity.e2.isTypeidExp is null &&
            identity.e1.type.toBasetype.isTypeClass !is null
            ? classIdentityAddress(left) == classIdentityAddress(right)
            : aggregateValues
            ? equalValues(left, right)
            : nullPointerIdentity
            ? true
            : left == right;
    }

    private void* classIdentityAddress(in ExpressionResult value) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (value == ExpressionResult.null_)
            return null;

        if (value.isNativeAggregate) {
            auto aggregate = AggregateValue.native(value);
            return aggregate.type.toBasetype.isTypeClass is null
                ? null
                : AggregateValue.nativeClassBodyAddress(aggregate);
        }
        if (value.isPointer)
            return value.pointerAddress;
        return null;
    }

    // A construction caller supplies fresh storage. An ordinary non-void
    // rvalue call gets a typed activation-owned temporary from
    // `constructedExpressionValue` at its call site. Native and
    // not-yet-migrated families still return a carrier, which that temporary
    // is then written from.
    private ExpressionResult runCallExpression(
        imported!"dmd.expression".CallExp call,
        ConstructionDestination* constructionDestination,
    ) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.builtins:
            binaryBuiltinCall,
            interpreterBuiltinArgumentCount,
            isStdConvText,
            stdConvTextCall,
            tryInterpreterBuiltin,
            unaryBuiltinCall;
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
        import quickbite.backends.interpreter.place: Place;

        if (call.f !is null) {
            import quickbite.frontend.dmd.functions: ensureFunctionBodySemantic;

            ensureFunctionBodySemantic(call.f);
        }

        bool nativeCall;
        if (call.f !is null) {
            import quickbite.backends.interpreter.interception_guard:
                bodyContainsAsm;
            import quickbite.frontend.dmd.functions: hasNoInterpretableSource;

            nativeCall = hasNoInterpretableSource(call.f) ||
                bodyContainsAsm(call.f);
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins: InterpreterBuiltin;

            InterpreterBuiltin builtin;
            if (
                tryInterpreterBuiltin(call.f, builtin) &&
                call.arguments !is null &&
                call.arguments.length == interpreterBuiltinArgumentCount(builtin)
            ) {
                import quickbite.backends.interpreter.interception_guard:
                    enforceInterceptionPolicy;

                enforceInterceptionPolicy(call.f, "tryInterpreterBuiltin");

                if (constructionDestination is null) {
                    // A void call has no result destination. Evaluate each
                    // argument for its effects, but do not materialize a
                    // discarded builtin result.
                    foreach (argument; *call.arguments)
                        executeForEffect(argument);
                } else with (InterpreterBuiltin) final switch (builtin) {
                    case fabs:
                    case isInfinity:
                    case signbit:
                    case sqrt:
                        auto argument = (*call.arguments)[0];
                        auto argumentDestination = ConstructionDestination(Place(
                            _activationFrame.temporaryAddress(argument),
                            argument.type,
                        ));
                        runExpression(argument, argumentDestination);
                        unaryBuiltinCall(
                            builtin,
                            argumentDestination.place,
                            constructionDestination.place,
                        );
                        constructionDestination.markConstructed;
                        break;

                    case pow:
                        auto lhs = (*call.arguments)[0];
                        auto lhsDestination = ConstructionDestination(Place(
                            _activationFrame.temporaryAddress(lhs),
                            lhs.type,
                        ));
                        runExpression(lhs, lhsDestination);
                        auto rhs = (*call.arguments)[1];
                        auto rhsDestination = ConstructionDestination(Place(
                            _activationFrame.temporaryAddress(rhs),
                            rhs.type,
                        ));
                        runExpression(rhs, rhsDestination);
                        binaryBuiltinCall(
                            builtin,
                            lhsDestination.place,
                            rhsDestination.place,
                            constructionDestination.place,
                        );
                        constructionDestination.markConstructed;
                        break;
                }
                return ExpressionResult.void_;
            }
        }

        if (call.f !is null && isStdConvText(call.f)) {
            import quickbite.backends.interpreter.interception_guard:
                enforceInterceptionPolicy;
            import quickbite.backends.interpreter.place: Place;

            enforceInterceptionPolicy(call.f, "isStdConvText");
            if (constructionDestination is null) {
                // A discarded `text` result has no observable value, but its
                // arguments still run in source order for their effects.
                if (call.arguments !is null)
                    foreach (argument; *call.arguments)
                        executeForEffect(argument);
            } else {
                Place[] argumentPlaces;
                if (call.arguments !is null) {
                    foreach (argument; *call.arguments) {
                        auto argumentDestination = ConstructionDestination(Place(
                            _activationFrame.temporaryAddress(argument),
                            argument.type,
                        ));
                        runExpression(argument, argumentDestination);
                        argumentPlaces ~= argumentDestination.place;
                    }
                }
                stdConvTextCall(argumentPlaces, constructionDestination.place);
                constructionDestination.markConstructed;
            }
            return ExpressionResult.void_;
        }

        if (call.f !is null && isDruntimeArrayOpAddAssign(call.f)) {
            import quickbite.backends.interpreter.interception_guard:
                enforceInterceptionPolicy;

            enforceInterceptionPolicy(call.f, "isDruntimeArrayOpAddAssign");
            return runArrayOpAddAssignCall(call);
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins:
                isBlitStructArrayDup;

            if (isBlitStructArrayDup(call.f)) {
                import quickbite.backends.interpreter.interception_guard:
                    enforceInterceptionPolicy;

                enforceInterceptionPolicy(call.f, "isBlitStructArrayDup");
                return runBlitStructArrayDupCall(call);
            }
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins:
                AtomicHook, tryAtomicHook;

            AtomicHook atomicHook;
            if (tryAtomicHook(call.f, atomicHook)) {
                import quickbite.backends.interpreter.interception_guard:
                    enforceInterceptionPolicy;

                enforceInterceptionPolicy(call.f, "tryAtomicHook");
                return runAtomicHookCall(call, atomicHook);
            }
        }

        auto stringForeachApply = call.f is null
            ? callExpressionFunction(call.e1)
            : call.f;
        if (
            stringForeachApply !is null &&
            isStringForeachApplyCall(stringForeachApply)
        ) {
            import quickbite.backends.interpreter.interception_guard:
                enforceInterceptionPolicy;

            enforceInterceptionPolicy(
                stringForeachApply,
                "isStringForeachApplyCall",
            );
            return runStringForeachApplyCall(call, stringForeachApply);
        }

        auto callArguments = CallArguments(
            call.arguments is null ? 0 : call.arguments.length,
        );
        scope(exit) callArguments.release;
        auto arguments = callArguments.values;
        auto argumentExpressions = callArguments.expressions;
        auto evaluatedArguments = callArguments.references;
        auto argumentPlaces = new Place[arguments.length];
        if (call.arguments !is null) {
            foreach (index, argument; *call.arguments) {
                auto parameter = call.f is null ||
                    call.f.parameters is null ||
                    index >= call.f.parameters.length
                    ? null
                    : (*call.f.parameters)[index];
                EvaluatedReferenceArgument evaluated;
                bool hasArgumentPlace;
                if (parameter !is null && parameterIsLazy(parameter))
                    // The lazy argument is captured as an expression below;
                    // this aligned entry is never bound or evaluated.
                    arguments[index] = ExpressionResult.void_;
                else if (nativeCall && nativeReferenceParameter(call.f, index))
                    arguments[index] = runRefArgumentExpression(
                        argument,
                        evaluated,
                    );
                else if (parameter !is null &&
                    isReferenceParameter(call.f, index, parameter))
                    arguments[index] = runRefArgumentExpression(
                        argument,
                        evaluated,
                        isStdConvText(call.f),
                    );
                else {
                    auto argumentDestination = ConstructionDestination(Place(
                        _activationFrame.temporaryAddress(argument),
                        argument.type,
                    ));
                    runExpression(argument, argumentDestination);
                    argumentPlaces[index] = argumentDestination.place;
                    hasArgumentPlace = true;
                    arguments[index] = readStoredValue(argumentDestination.place);
                }
                if (
                    parameter !is null &&
                    parameter.type.toBasetype.isTypeClass !is null
                )
                    arguments[index] = rootedNativeClassValue(
                        argument,
                        arguments[index],
                    );
                if (hasArgumentPlace)
                    writeStoredValue(argumentPlaces[index], arguments[index]);
                argumentExpressions[index] = argument;
                evaluatedArguments[index] = evaluated;
            }
        }

        if (auto dot = call.e1.isDotVarExp) {
            // For a `PtrExp` receiver (`p().get()`'s implicit deref of a
            // pointer-returning call), evaluate the pointer operand exactly
            // once here and keep its address around: a struct receiver's
            // later `this`-rebind (`runMemberFunction`, guarded by
            // `isWritableLocation`) would otherwise re-derive that same
            // address via `addressOfExpression`, re-running a
            // side-effecting operand like `p()` a second time. A struct
            // element read through a side-effecting `IndexExp` receiver
            // (`a[i++].method()`) has the identical hazard: compose its
            // address once here too, and read the receiver from that
            // address rather than through a second independent evaluation.
            ExpressionResult receiverPointerAddress;
            bool hasReceiverPointerAddress;
            ExpressionResult receiver;
            if (
                !nativeCall &&
                dot.e1.type.toBasetype.isTypeStruct !is null &&
                hasDirectWriteProjectionPlace(dot.e1)
            ) {
                materializeProjectionRoot(dot.e1);
                // Mutable because the borrowed-block constructor accepts the
                // writable receiver address that the method will mutate.
                auto receiverPlace = directWriteProjectionPlace(dot.e1);
                receiverPointerAddress = ExpressionResult.pointerValue(
                    receiverPlace.address,
                );
                hasReceiverPointerAddress = true;
                receiver = borrowedAggregateValue(receiverPlace);
            } else if (auto pointerReceiver = dot.e1.isPtrExp) {
                receiverPointerAddress = ExpressionResult.pointerValue(
                    pointerOperandPlace(pointerReceiver.e1).deref.address,
                );
                hasReceiverPointerAddress = true;
                receiver = dereferencePointerValue(
                    pointerReceiver,
                    receiverPointerAddress,
                );
            } else if (
                dot.e1.isIndexExp !is null &&
                dot.e1.type.toBasetype.isTypeStruct !is null
            ) {
                import dmd.tokens: EXP;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                receiverPointerAddress = addressOfExpression(dot.e1, EXP.address);
                hasReceiverPointerAddress = true;
                receiver = readValue(
                    Place(receiverPointerAddress.pointerAddress, dot.e1.type),
                );
            } else if (
                dot.e1.isCommaExp !is null &&
                dot.e1.type.toBasetype.isTypeStruct !is null
            ) {
                // DMD lowers a constructed struct temporary to
                // `(Temp __t = void, __t).this(args)`. Take that comma's
                // address so the constructor runs against the temporary's own
                // storage; running the comma as a value would construct into
                // a detached copy and leave the temporary default-initialized
                // for its later destructor.
                import dmd.tokens: EXP;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                receiverPointerAddress = addressOfExpression(dot.e1, EXP.address);
                hasReceiverPointerAddress = receiverPointerAddress.isPointer;
                receiver = readValue(
                    Place(receiverPointerAddress.pointerAddress, dot.e1.type),
                );
            } else if (
                dot.e1.isCallExp !is null &&
                dot.e1.type.toBasetype.isTypeStruct !is null &&
                dot.e1.isCallExp.f !is null &&
                returnsRef(dot.e1.isCallExp.f)
            ) {
                // A ref-returning call denotes the lvalue it returned
                // (`isWritableLocation`'s own `CallExp` case): the later
                // `this`-rebind must reach that exact storage, not a copy.
                // Take its address once here too, so a side-effecting
                // receiver call (`get(holder, evaluations).slot`) runs
                // exactly once rather than the rebind re-running it via a
                // second `addressOfExpression`.
                import dmd.tokens: EXP;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                receiverPointerAddress = addressOfExpression(dot.e1, EXP.address);
                hasReceiverPointerAddress = receiverPointerAddress.isPointer;
                receiver = receiverPointerAddress.isPointer
                    ? readValue(
                        Place(receiverPointerAddress.pointerAddress, dot.e1.type),
                    )
                    : constructedExpressionValue(dot.e1);
            } else
                receiver = constructedExpressionValue(dot.e1);

            // When `call` is itself the constructor about to run against
            // this receiver, hold its premature arming until that call
            // actually succeeds below (see
            // `popPrematureReceiverConstructorDestructor`).
            auto deferredReceiverConstructorDestructor =
                popPrematureReceiverConstructorDestructor(call.f, dot.e1);
            scope(success)
                if (deferredReceiverConstructorDestructor !is null)
                    queueTemporaryDestructor(deferredReceiverConstructorDestructor);

            queueConstructedReceiverDestructor(dot.e1);
            if (dot.e1.type.toBasetype.isTypeClass !is null)
                receiver = rootedNativeClassValue(dot.e1, receiver);
            const interpreterAllocatedClass = receiver.isNativeAggregate &&
                dot.e1.type.toBasetype.isTypeClass !is null;
            if (receiver == ExpressionResult.null_)
                throw new Exception(
                    "function call through null class reference `null`",
                );

            if (call.f !is null && call.f.needThis) {
                // A class TypeInfo's `initializer` is the class-instance
                // initializer span: `classInstanceSize` bytes holding every
                // field's declared default. An interpreted-only TypeInfo has
                // no resident body druntime could read that from, so build
                // the instance image here.
                if (
                    receiver.isTypeName &&
                    declarationName(call.f) == "initializer" &&
                    arguments.length == 0
                )
                    return typeInfoClassInitializer(
                        receiver.asTypeNameString,
                        call.type,
                    );

                // An interpreted-only TypeInfo has symbolic identity but no
                // resident class body on which druntime's member can run.
                // TypeInfo.opEquals defines equality by that identity (and
                // accepts null), so answer it before native object dispatch.
                if (
                    receiver.isTypeName &&
                    call.f.ident !is null &&
                    call.f.ident.toString == "opEquals" &&
                    arguments.length == 1 &&
                    (arguments[0].isTypeName || arguments[0] == ExpressionResult.null_)
                )
                    return ExpressionResult(receiver == arguments[0]);

                import quickbite.frontend.dmd.functions:
                    hasNoInterpretableSource, noAvailableSourceMessage;

                if (
                    call.f.isCtorDeclaration !is null &&
                    isThisOrSuperMemberCall(call)
                )
                    return runThisConstructorCall(
                        call.f,
                        arguments,
                        argumentExpressions,
                        evaluatedArguments,
                    );

                auto function_ = resolveMemberFunction(call.f, receiver);
                if (interpreterAllocatedClass)
                    receiver = ExpressionResult.pointerValue(
                        AggregateValue.nativeClassBodyAddress(receiver),
                    );
                // An interpreter-allocated class has no synthesized vtable
                // yet, so only virtual dispatch is refused. A nonvirtual
                // member resolves by symbol and receives the native body as
                // hidden `this`; it never reads word zero as a vtable.
                if (
                    hasNoInterpretableSource(function_) &&
                    (!interpreterAllocatedClass || function_.vtblIndex < 0)
                ) {
                    import quickbite.backends.interpreter.native_call_adapter:
                        NativeCallException, NativeCallResult;

                    try {
                        imported!"dmd.mtype".Type receiverType =
                            receiverClassType(dot.e1);
                        if (receiverType is null)
                            receiverType = receiverStructType(dot.e1);
                        const returnsReceiver =
                            function_.isCtorDeclaration !is null ||
                            function_.isPostBlitDeclaration !is null;
                        auto nativeReceiver = function_.isCtorDeclaration !is null
                            ? nativeConstructorReceiver(function_, receiver)
                            : receiver;
                        NativeCallResult nativeResult;
                        if (invokeNativeDeclaration(
                            function_,
                            nativeReceiver,
                            receiverType,
                            dot.e1,
                            arguments,
                            argumentExpressions,
                            evaluatedArguments,
                            returnsReceiver,
                            nativeResult,
                            hasReceiverPointerAddress
                                ? receiverPointerAddress.pointerAddress
                                : null,
                            constructionDestination is null
                                ? null
                                : constructionDestination.place.address,
                        )) {
                            if (
                                constructionDestination !is null &&
                                nativeResult.value.address ==
                                    constructionDestination.place.address
                            ) {
                                constructionDestination.markConstructed;
                                return ExpressionResult.void_;
                            }
                            return nativeCallValue(nativeResult.value);
                        }
                    } catch (NativeCallException exception) {
                        throwNativeException(exception);
                    }

                    const unsupportedType =
                        unsupportedNativeTypeMessage(function_);
                    throw new Exception(
                        unsupportedType is null
                            ? noAvailableSourceMessage(function_)
                            : unsupportedType,
                    );
                }
                return runMemberFunction(
                    function_,
                    dot.e1,
                    receiver,
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                    hasReceiverPointerAddress ? &receiverPointerAddress : null,
                    constructionDestination,
                    argumentPlaces,
                );
            }
        }

        if (call.f !is null) {
            import quickbite.frontend.dmd.functions: noAvailableSourceMessage;
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;

            if (nativeCall) {
                if (isMonitorOperation(call.f))
                    return ExpressionResult.void_;

                try {
                    NativeCallResult nativeResult;
                    if (!call.f.needThis && invokeNativeDeclaration(
                            call.f,
                            ExpressionResult.void_,
                            null,
                            null,
                            arguments,
                            argumentExpressions,
                            evaluatedArguments,
                            false,
                            nativeResult,
                            null,
                            constructionDestination is null
                                ? null
                                : constructionDestination.place.address,
                        ))
                    {
                        if (
                            constructionDestination !is null &&
                            nativeResult.value.address ==
                                constructionDestination.place.address
                        ) {
                            constructionDestination.markConstructed;
                            return ExpressionResult.void_;
                        }
                        return nativeCallValue(nativeResult.value);
                    }
                } catch (NativeCallException exception) {
                    throwNativeException(exception);
                }

                // An FFI-uncrossable signature type (e.g. an associative array)
                // gets an honest diagnostic naming the type rather than the
                // misleading no-available-source message.
                const unsupportedType = unsupportedNativeTypeMessage(call.f);
                throw new Exception(
                    unsupportedType is null
                        ? noAvailableSourceMessage(call.f)
                        : unsupportedType,
                );
            }

            if (call.f.isNested && hasThis)
                return runMemberFunction(
                    call.f,
                    null,
                    receiverValue(thisValue),
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                    null,
                    constructionDestination,
                    argumentPlaces,
                );

            return runFunction(
                call.f,
                arguments,
                argumentExpressions,
                false,
                evaluatedArguments,
                null,
                constructionDestination,
                argumentPlaces,
            );
        }

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return runFunction(
                    function_,
                    arguments,
                    argumentExpressions,
                    false,
                    evaluatedArguments,
                    null,
                    constructionDestination,
                    argumentPlaces,
                );

        if (auto function_ = functionPointerExpressionFunction(call.e1)) {
            if (isZeroFormalCall(function_) && arguments.length == 5) {
                if (isRawArraysConformabilityCheck(function_)) {
                    import quickbite.backends.interpreter.interception_guard:
                        enforceInterceptionPolicy;

                    enforceInterceptionPolicy(
                        function_,
                        "enforceRawArraysConformable",
                    );
                    return ExpressionResult(false);
                }

                throw new Exception("Unsupported eval call.");
            }
            if (function_.isNested && hasThis)
                return runMemberFunction(
                    function_,
                    null,
                    receiverValue(thisValue),
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                    null,
                    constructionDestination,
                    argumentPlaces,
                );

            return runFunction(
                function_,
                arguments,
                argumentExpressions,
                false,
                evaluatedArguments,
                null,
                constructionDestination,
                argumentPlaces,
            );
        }

        if (auto variable = lazyCallVariable(call))
            return runLazyArgument(variable, constructionDestination);

        const callee = runExpressionValue(call.e1);
        if (!callee.isNativeDelegate && !callee.isFunctionPointer)
            throw new Exception("Unsupported eval call.");

        // Both callable shapes share one slot representation; dispatch off
        // it instead of the two separate carrier-tag checks it replaces.
        const calleeSlot = delegateSlotValue(callee);
        if (calleeSlot.isNative)
            return runNativeDelegateCall(
                callee,
                call,
                arguments,
                argumentExpressions,
            );

        if (calleeSlot.functionPointerId in _executionState.delegates)
            return runDelegateCall(
                callee,
                arguments,
                argumentExpressions,
                evaluatedArguments,
                constructionDestination,
            );

        auto function_ = calleeSlot.functionPointerId in functionPointers;
        if (function_ is null)
            throw new Exception("Unsupported eval call.");
        return runFunction(
            *function_,
            arguments,
            argumentExpressions,
            false,
            evaluatedArguments,
            null,
            constructionDestination,
            argumentPlaces,
        );
    }

    // DMD lowers a user-constructor receiver to `((S __t = <placeholder>;) ,
    // __t).__ctor(args)`, where `<placeholder>` is `__t`'s type's own
    // default value -- never the constructor's real arguments. Evaluating
    // that declaration (`executeDeclaration`, reached through
    // `addressOfExpression`'s `CommaExp` handling or `runExpressionValue`) arms
    // `__t`'s destructor as soon as the placeholder assignment succeeds,
    // which is correct once `__t` is a complete value but wrong here: when
    // `call` is that same `__ctor`, `__t` is still just reserved storage,
    // and a throwing constructor must leave nothing armed to destroy
    // (compiled D never runs a receiver's destructor when its constructor
    // threw). Pop that premature arming so the caller can hold it until
    // `call` actually succeeds, then requeue it (`scope(success)`) -- every
    // call site that resolves such a receiver needs this, both the
    // constructor's own value evaluation (`evalCall`'s `DotVarExp` handling)
    // and its address evaluation (`memberRefReturningCallAddress`, reached
    // whenever a further ref-returning or address-taking use needs `__t`'s
    // storage before the constructor has run).
    private imported!"dmd.expression".Expression
    popPrematureReceiverConstructorDestructor(
        imported!"dmd.func".FuncDeclaration calleeFunction,
        imported!"dmd.expression".Expression receiverExpression,
    ) {
        if (calleeFunction is null || calleeFunction.isCtorDeclaration is null)
            return null;

        auto comma = receiverExpression.isCommaExp;
        if (comma is null)
            return null;

        auto declaration = comma.e1.isDeclarationExp;
        if (declaration is null)
            return null;

        auto variable = declaration.declaration.isVarDeclaration;
        if (
            variable is null ||
            variable.edtor is null ||
            _pendingTemporaryDestructors.length == 0 ||
            _pendingTemporaryDestructors[$ - 1] !is variable.edtor
        )
            return null;

        --_pendingTemporaryDestructors.length;
        return variable.edtor;
    }

    private static bool isRawArraysConformabilityCheck(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        return function_.ident !is null &&
            (function_.ident.toString == "enforceRawArraysConformable" ||
                function_.ident.toString == "enforceRawArraysConformableNogc");
    }

    // A constructor used directly as a member receiver owns a full-expression
    // temporary. DMD records that cleanup on the synthesized declaration's
    // `edtor` rather than emitting a DtorExpStatement, so arm it here to run
    // at the end of the enclosing full expression instead of when the member
    // call returns. Every member-call receiver-resolution site routes through
    // this, so a constructed-temporary receiver is destroyed exactly once
    // regardless of whether the member call is read, assigned through, or
    // has its address taken.
    private void queueConstructedReceiverDestructor(
        imported!"dmd.expression".Expression receiver,
    ) {
        auto destructor = constructedReceiverDestructor(receiver);
        if (destructor !is null)
            queueTemporaryDestructor(destructor);
    }

    private imported!"dmd.expression".Expression
    constructedReceiverDestructor(
        imported!"dmd.expression".Expression receiver,
    ) {
        auto constructor = receiver.isCallExp;
        if (
            constructor is null ||
            constructor.f is null ||
            constructor.f.isCtorDeclaration is null
        )
            return null;

        auto member = constructor.e1.isDotVarExp;
        if (member is null)
            return null;

        auto comma = member.e1.isCommaExp;
        if (comma is null)
            return null;

        auto declaration = comma.e1.isDeclarationExp;
        if (declaration is null)
            return null;

        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return null;

        // A struct with a user-defined constructor lowers `S(args)` to
        // `((S __t = <placeholder>;) , __t).__ctor(args)`, and `receiver`
        // here is that whole `.__ctor(args)` call, already evaluated as a
        // value -- reaching this point at all means that call returned
        // rather than threw. `shouldArmDeclaredVariableDestructor` reporting
        // true for `__t` means `executeDeclaration` armed it the moment its
        // placeholder assignment ran, before the constructor call above;
        // `popPrematureReceiverConstructorDestructor` will have popped that
        // premature arming at the site that made this call and requeued it
        // once the call succeeded, so declining here avoids arming it twice.
        // A receiver `executeDeclaration` declined to arm (a genuinely
        // uninitialised `= void` local, still `variable.edtor`'s original
        // design case) has nothing to pop or requeue, so it is armed here
        // instead, now that its constructor has run.
        return shouldArmDeclaredVariableDestructor(variable)
            ? null
            : variable.edtor;
    }

    // A writable aggregate receiver is already stored in its caller-owned
    // place. The child method borrows those exact bytes as `this`; creating a
    // detached by-value snapshot here would allocate and then be discarded
    // when `runMemberFunction` rebinds `this` to the same address.
    private ExpressionResult borrowedAggregateValue(Place place) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_aggregate:
            NativeAggregate;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        return ExpressionResult.nativeAggregateValue(NativeAggregate(
            place.type,
            NativeBlock.borrow(place.address, typeByteSize(place.type)),
        ));
    }

    // Evaluate a reference argument's lvalue operands exactly once. When the
    // call binds the composed address directly, the pointee is not an rvalue
    // and needs no snapshot; unsupported lvalue shapes still materialize so
    // the existing synthetic-reference fallback retains its value.
    private ExpressionResult runRefArgumentExpression(
        imported!"dmd.expression".Expression argument,
        out EvaluatedReferenceArgument evaluated,
        in bool materializeValue = true,
    ) {
        // A ref-returning call used as a `ref` argument passes the returned
        // lvalue itself onward: bind the callee's reference slot to that
        // lvalue's address so writes through the parameter reach it, instead
        // of a copied call result.
        if (auto call = argument.isCallExp)
            if (call.f !is null && returnsRef(call.f)) {
                import dmd.tokens: EXP;
                import quickbite.backends.interpreter.place: Place;

                const address = refReturningCallAddress(call, EXP.address);
                if (address.isPointer) {
                    evaluated.address = address.pointerAddress;
                    return readStoredValue(Place(evaluated.address, argument.type));
                }
            }

        // A `this`/`super`-rooted argument (`foo(this)`, `ref this` itself,
        // or `foo(this.field)`/`foo(this.inner.field)`) is bound to this
        // activation's own receiver storage for its whole lifetime --
        // `projectionPlace` composes that chain's live address the same way
        // `writeLocation`'s own `DotVarExp` arm does for a field write. A
        // bare `this`/`super` argument is not itself a `DotVarExp`, so this
        // has to run ahead of the general `DotVarExp` arm below, which has
        // no arm of its own for that shape.
        if (isThisRootedProjection(argument) && hasProjectionPlace(argument)) {
            import quickbite.backends.interpreter.place_value: readValue;

            auto place = projectionPlace(argument);
            evaluated.address = place.address;
            if (!materializeValue)
                return ExpressionResult.void_;
            return readValue(place);
        }

        if (argument.isDotVarExp !is null) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: readValue;

            const address = addressOfExpression(argument, EXP.address);
            if (address.isPointer) {
                evaluated.address = address.pointerAddress;
                if (!materializeValue)
                    return ExpressionResult.void_;
                return readValue(Place(evaluated.address, argument.type));
            }
        }

        if (auto pointer = argument.isPtrExp) {
            const address = pointerOperandPlace(pointer.e1).deref.address;
            if (address !is null) {
                evaluated.address = cast(void*) address;
                if (!materializeValue)
                    return ExpressionResult.void_;
                return loadNativePointerElement(
                    pointer.e1.type,
                    ExpressionResult.pointerValue(cast(void*) address),
                    0,
                );
            }
        }

        // `ptr[i]` off a POINTER RVALUE (not a variable `placeOfLvalue`
        // could compose a `Place` for) -- druntime's own nested-AA write
        // hands exactly this shape as the deeper `_d_aaGetY`'s `aa`
        // argument: `(_d_aaGetY!(K1,V1)(a, key1, found))[0]`, a `[0]` index
        // straight off the outer call's returned `V1*` (the outer entry's
        // own storage), one nesting level per further `[key]`. Without this
        // arm `evaluated.address` stays unset, `bindReferenceSlot` falls
        // through to `placeOfLvalue` (which refuses any `CallExp` base --
        // it has no Walker to evaluate one) and then to the synthetic
        // reference-slot fallback, so the inner map the deeper call
        // allocates gets written into a throwaway copy instead of back
        // through the outer slot; the outer entry's value stays at its
        // zero-initialized default forever. Same address arithmetic as
        // `loadNativePointerElement`, just keeping the address instead of
        // only the value it reads from it.
        if (auto index = argument.isIndexExp) {
            import quickbite.frontend.dmd.types: isPointerType;
            import quickbite.backends.interpreter.layout: typeByteSize;

            if (isPointerType(index.e1.type)) {
                const pointerAddress = pointerOperandPlace(index.e1).deref.address;
                if (pointerAddress !is null) {
                    const elementIndex = scalarOperand!size_t(index.e2);
                    auto elementType = index.e1.type.toBasetype.nextOf.toBasetype;
                    evaluated.address = nativeElementAddress(
                        cast(void*) pointerAddress,
                        elementIndex,
                        typeByteSize(elementType),
                    );
                    if (!materializeValue)
                        return ExpressionResult.void_;
                    return loadNativePointerElement(
                        index.e1.type,
                        ExpressionResult.pointerValue(cast(void*) pointerAddress),
                        elementIndex,
                    );
                }
            }
        }

        if (auto conditional = argument.isCondExp) {
            auto selected = conditionTruthy(conditional.econd)
                ? conditional.e1
                : conditional.e2;
            const value = runRefArgumentExpression(
                selected,
                evaluated,
                materializeValue,
            );
            if (evaluated.selectedLvalue is null)
                evaluated.selectedLvalue = selected;
            return value;
        }

        auto var = argument.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable !is null && isUninitializedBinding(variable))
            return ExpressionResult.void_;
        if (variable !is null) {
            const address = bindingPointerValue(variable);
            if (address.isPointer) {
                evaluated.address = address.pointerAddress;
                if (!materializeValue)
                    return ExpressionResult.void_;
            }
        }

        // Whatever remains here has no addressable place this activation
        // can compose: an arbitrary rvalue expression DMD's own semantic
        // pass allows to bind a `ref`/`out` parameter (a literal materialized
        // into an implicit temporary, a `CondExp` branch that is itself none
        // of the recognized shapes, ...) is a genuine rvalue with no live
        // storage of its own to alias -- DMD's own implicit-temporary
        // materialization for such an argument is exactly what evaluating it
        // here and letting the caller bind a fresh synthetic reference slot
        // reproduces.
        auto previous = _evaluatedReferenceArgumentIndices;
        _evaluatedReferenceArgumentIndices = &evaluated.indices;
        scope(exit)
            _evaluatedReferenceArgumentIndices = previous;

        return runExpressionValue(argument);
    }

    // Run an interpreted delegate that native code called back into through the
    // FFI reverse bridge. The adapter supplies typed places rather than value
    // carriers. This temporary evaluator boundary materializes them only to
    // call the existing recursive walker, then constructs into the supplied
    // native result place.
    private void invokeNativeCallback(
        in imported!"quickbite.backends.interpreter.native_call_adapter".
            InterpretedDelegate callback,
        imported!"dmd.mtype".Type returnType,
        imported!"dmd.mtype".Type[] parameterTypes,
        void*[] argumentBuffers,
        ubyte[] resultBuffer,
    ) {
        import dmd.expression: Expression;
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.native_call_adapter:
            extendInboundIntegerResult;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue, writeValue;

        ExpressionResult[1] inlineCallbackArgument;
        auto arguments = parameterTypes.length == 0
            ? null
            : parameterTypes.length == 1
                ? inlineCallbackArgument[]
                : new ExpressionResult[](parameterTypes.length);
        foreach (index, parameterType; parameterTypes)
            arguments[index] = readValue(Place(
                argumentBuffers[index],
                parameterType,
            ));

        // A void-returning callback has no destination to construct into
        // (decision 7); a non-void one needs a real typed temporary, sized
        // by its own declared return type, or the interpreted delegate's
        // return has nowhere to land.
        if (returnType.ty == TY.Tvoid) {
            runDelegateCall(
                ExpressionResult.functionPointerValue(callback.functionPointerId),
                arguments,
                new Expression[](arguments.length),
            );
            return;
        }

        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        auto resultBlock = NativeBlock.allocate(
            typeByteSize(returnType),
            typeHasPointers(returnType)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );
        auto destination = ConstructionDestination(Place(resultBlock.address, returnType));
        runDelegateCall(
            ExpressionResult.functionPointerValue(callback.functionPointerId),
            arguments,
            new Expression[](arguments.length),
            null,
            &destination,
        );
        const result = readStoredValue(destination.place);

        resultBuffer[] = 0;
        writeValue(Place(resultBuffer.ptr, returnType), result);
        extendInboundIntegerResult(resultBuffer, returnType);
    }

    private ExpressionResult runDelegateCall(
        in ExpressionResult callee,
        in ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        ConstructionDestination* constructionDestination = null,
    ) {
        auto runtime = callee.functionPointerId in _executionState.delegates;
        if (runtime is null)
            throw new Exception("Unsupported eval call.");

        auto rootedArguments = arguments.dup;
        if (runtime.function_.parameters !is null)
            foreach (index, parameter; *runtime.function_.parameters)
                if (
                    index < argumentExpressions.length &&
                    parameter.type.toBasetype.isTypeClass !is null
                )
                    rootedArguments[index] = rootedNativeClassValue(
                        argumentExpressions[index],
                        rootedArguments[index],
                    );

        if (runtime.hasReceiver)
            return runMemberFunction(
                runtime.function_,
                null,
                delegateReceiver(*runtime),
                rootedArguments,
                argumentExpressions,
                evaluatedArguments,
                null,
                constructionDestination,
            );

        return runFunction(
            runtime.function_,
            rootedArguments,
            argumentExpressions,
            false,
            evaluatedArguments,
            runtime.capturedAddresses,
            constructionDestination,
        );
    }

    // Call a native delegate the interpreter holds as an opaque
    // {context, funcptr} value read from a native typed result place, the
    // inverse of the inbound callback bridge.
    private ExpressionResult runNativeDelegateCall(
        in ExpressionResult callee,
        imported!"dmd.expression".CallExp call,
        in ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        import quickbite.backends.interpreter.native_call_adapter:
            InterpreterInboundTrampolineSession, NativeCallException,
            NativeCallRequest, NativeCallResult, invokeNative;
        import dmd.mtype: TypeFunction;

        auto delegateType = call.e1.type.toBasetype;
        auto functionType = delegateType.nextOf is null
            ? null
            : cast(TypeFunction) delegateType.nextOf;
        auto nativeArguments = NativeCallArguments(argumentExpressions);
        scope(exit) nativeArguments.release;
        fillNativeCallOperands(
            null,
            arguments,
            argumentExpressions,
            nativeArguments.types,
            null,
            nativeArguments.operands,
            durableInboundSession,
        );

        try {
            if (durableInboundSession is null)
                durableInboundSession = new InterpreterInboundTrampolineSession(
                    _executionState.invokeNativeCallback,
                );
            auto request = NativeCallRequest(
                delegateSignature: functionType,
                delegateAddress: callee.nativeDelegateFuncptr,
                delegateContext: callee.nativeDelegateContext,
                argumentTypes: nativeArguments.types,
                argumentOperands: nativeArguments.operands,
                callbackSession: durableInboundSession,
            );
            NativeCallResult nativeResult;
            if (invokeNative(request, nativeResult))
                return nativeCallValue(nativeResult.value);
        } catch (NativeCallException exception) {
            throwNativeException(exception);
        }

        throw new Exception("Unsupported eval call.");
    }

    private ExpressionResult delegateReceiver(RuntimeDelegate runtime) {
        return expressionResultFrom(runtime.receiver);
    }

    private ExpressionResult runDelegatePointerExpression(
        imported!"dmd.expression".DelegatePtrExp expression,
    ) {
        return delegateProperty(runExpressionValue(expression.e1), "ptr");
    }

    private ExpressionResult runDelegateFunctionPointerExpression(
        imported!"dmd.expression".DelegateFuncptrExp expression,
    ) {
        return delegateProperty(runExpressionValue(expression.e1), "funcptr");
    }

    private bool isStringForeachApplyCall(FuncDeclaration function_) const {
        import std.algorithm: canFind;

        if (function_.ident is null)
            return false;

        const name = function_.ident.toString;
        return
            name.canFind("_aApplycd1") ||
            name.canFind("_aApplywd1") ||
            name.canFind("_aApplydc1") ||
            name.canFind("_aApplyRwd1");
    }

    private FuncDeclaration callExpressionFunction(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto var = expression.isVarExp)
            return var.var.isFuncDeclaration;

        return functionPointerExpressionFunction(expression);
    }

    private ExpressionResult runStringForeachApplyCall(
        imported!"dmd.expression".CallExp call,
        FuncDeclaration function_,
    ) {
        if (call.arguments is null || call.arguments.length != 2)
            throw new Exception("Unsupported eval call.");

        auto body = functionPointerExpressionFunction((*call.arguments)[1]);
        if (body is null)
            throw new Exception("Unsupported eval call.");

        // Every `opApply` delegate follows the same early-exit convention:
        // its declared return type (always `int`, by that convention) names
        // one activation-owned typed slot, reused for each element's result.
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;

        auto resultType = body.type.toBasetype.isTypeFunction.next;
        auto resultBlock = NativeBlock.allocate(
            typeByteSize(resultType),
            typeHasPointers(resultType)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );

        foreach (value; stringForeachApplyElements(
            function_.ident.toString,
            runExpressionValue((*call.arguments)[0]),
        )) {
            auto destination = ConstructionDestination(Place(resultBlock.address, resultType));
            runFunction(body, [value], [null], false, null, null, &destination);
            const result = readStoredValue(destination.place);
            if (result != ExpressionResult.void_ && result.asLong != 0)
                return result;
        }

        return ExpressionResult(0);
    }

    private ExpressionResult[] stringForeachApplyElements(
        scope const(char)[] helper,
        in ExpressionResult source,
    ) {
        import std.algorithm: canFind, reverse;

        if (helper.canFind("_aApplycd1"))
            return decodedUtf8Dchars(source);

        if (helper.canFind("_aApplywd1"))
            return decodedUtf16Dchars(source);

        if (helper.canFind("_aApplydc1"))
            return utf8EncodedDstringChars(source);

        if (helper.canFind("_aApplyRwd1")) {
            auto values = decodedUtf16Dchars(source);
            values.reverse;
            return values;
        }

        throw new Exception("Unsupported eval call.");
    }

    private ExpressionResult[] decodedUtf8Dchars(in ExpressionResult source) {
        import std.utf: decode;

        auto aggregate = AggregateValue.native(source);
        string encoded;
        foreach (index; 0 .. AggregateValue.length(aggregate))
            encoded ~= cast(char) readStoredValue(AggregateValue.elementAt(aggregate, index))
                .castTo!long.asLong;

        ExpressionResult[] values;
        size_t index;
        while (index < encoded.length)
            values ~= ExpressionResult(decode(encoded, index));

        return values;
    }

    private ExpressionResult[] decodedUtf16Dchars(in ExpressionResult source) {
        import std.utf: decode;

        auto aggregate = AggregateValue.native(source);
        wstring encoded;
        foreach (index; 0 .. AggregateValue.length(aggregate))
            encoded ~= cast(wchar) readStoredValue(AggregateValue.elementAt(aggregate, index))
                .castTo!long.asLong;

        ExpressionResult[] values;
        size_t index;
        while (index < encoded.length)
            values ~= ExpressionResult(decode(encoded, index));

        return values;
    }

    private ExpressionResult[] utf8EncodedDstringChars(in ExpressionResult source) {
        import std.utf: encode;

        auto aggregate = AggregateValue.native(source);
        ExpressionResult[] values;
        foreach (index; 0 .. AggregateValue.length(aggregate)) {
            char[4] encoded;
            const length = encode(
                encoded,
                cast(dchar) readStoredValue(AggregateValue.elementAt(aggregate, index))
                    .castTo!long.asLong,
            );
            foreach (unit; encoded[0 .. length])
                values ~= ExpressionResult(unit);
        }

        return values;
    }

    private FuncDeclaration resolveMemberFunction(
        FuncDeclaration function_,
        in ExpressionResult receiver,
    ) {
        if (dynamicClass(receiver) is null)
            return function_;

        auto class_ = dynamicClass(receiver);
        if (class_ is null)
            return function_;

        if (auto override_ = overridingFunction(class_, function_))
            return override_;

        if (auto interface_ = matchingInterfaceFunction(class_, function_))
            return interface_;

        if (auto vtbl = vtblFunction(class_, function_))
            return vtbl;

        if (auto vtbl = matchingVtableFunction(class_, function_))
            return vtbl;

        if (auto candidate = matchingMemberFunction(class_, function_))
            return candidate;

        return function_;
    }

    private imported!"dmd.dclass".ClassDeclaration dynamicClass(in ExpressionResult value) {
        const address = classIdentityAddress(value);
        if (address !is null)
            if (auto type = address in nativeClassTypes) {
                auto classType = type.toBasetype.isTypeClass;
                return classType is null ? null : classType.sym;
            }

        if (value.isNativeAggregate) {
            auto classType = AggregateValue.native(value).type.toBasetype.isTypeClass;
            return classType is null ? null : classType.sym;
        }

        return null;
    }

    private bool classHasType(in ExpressionResult value, in string name) {
        auto class_ = dynamicClass(value);
        if (class_ is null)
            return false;

        foreach (typeName; classTypeNames(class_))
            if (typeName == name)
                return true;
        return false;
    }

    private string dynamicClassName(in ExpressionResult value) {
        auto class_ = dynamicClass(value);
        return class_ is null ? "" : classInfoName(class_);
    }

    private imported!"dmd.dclass".ClassDeclaration dynamicClassDeclarationByName(
        in string name,
    ) {
        auto scope_ = currentFunction is null
            ? null
            : currentFunction.toParent.isScopeDsymbol;
        while (scope_ !is null) {
            if (auto class_ = classDeclarationByNameInScope(scope_, name))
                return class_;
            auto parent = scope_.toParent;
            scope_ = parent is null ? null : parent.isScopeDsymbol;
        }

        return null;
    }

    private bool isZeroFormalCall(FuncDeclaration function_) const {
        return function_.parameters is null || function_.parameters.length == 0;
    }

    private FuncDeclaration functionPointerExpressionFunction(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto function_ = expression.isFuncExp)
            return function_.fd;

        if (auto delegate_ = expression.isDelegateExp)
            return delegate_.func;

        if (auto address = expression.isAddrExp)
            return functionPointerExpressionFunction(address.e1);

        if (auto ptr = expression.isPtrExp)
            return functionPointerExpressionFunction(ptr.e1);

        if (auto symbol = expression.isSymOffExp)
            return symbol.var.isFuncDeclaration;

        return null;
    }

    // DMD lowers `sums[] = left[] + right[]` to a druntime
    // `core.internal.array.operations.arrayOp` template call; interpret the
    // element-wise semantics directly instead of executing the druntime body.
    private bool isDruntimeArrayOpAddAssign(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import dmd.dtemplate: isExpression;
        import std.algorithm: startsWith;
        import std.conv: text;

        if (
            function_.ident is null ||
            function_.ident.toString != "arrayOp"
        )
            return false;

        auto instance = function_.parent is null
            ? null
            : function_.parent.isTemplateInstance;
        if (instance is null || instance.tiargs is null)
            return false;

        if (
            !text(function_.toPrettyChars)
                .startsWith("core.internal.array.operations.arrayOp!(")
        )
            return false;

        size_t operatorIndex;
        foreach (argument; *instance.tiargs) {
            auto expression = isExpression(argument);
            if (expression is null)
                continue;

            auto literal = expression.isStringExp;
            if (literal is null)
                return false;

            if (operatorIndex >= 2)
                return false;

            const expectedOperator = operatorIndex == 0 ? "+" : "=";
            if (literal.peekString != expectedOperator)
                return false;
            ++operatorIndex;
        }

        return operatorIndex == 2;
    }

    private ExpressionResult runArrayOpAddAssignCall(
        imported!"dmd.expression".CallExp call,
    ) {
        if (call.arguments is null || call.arguments.length != 3)
            throw new Exception("Unsupported eval call.");

        auto target = (*call.arguments)[0].isSliceExp;
        if (target is null)
            throw new Exception("Unsupported eval call.");

        const left = runExpressionValue((*call.arguments)[1]);
        const right = runExpressionValue((*call.arguments)[2]);
        auto leftAggregate = AggregateValue.native(left);
        auto rightAggregate = AggregateValue.native(right);
        if (AggregateValue.length(leftAggregate) != AggregateValue.length(rightAggregate))
            throw new Exception("Unsupported eval call.");

        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(leftAggregate))
            elements ~= readStoredValue(AggregateValue.elementAt(leftAggregate, index)) +
                readStoredValue(AggregateValue.elementAt(rightAggregate, index));

        return writeBackSliceElements(target, elements);
    }

    private ExpressionResult writeBackSliceElements(
        imported!"dmd.expression".SliceExp slice,
        ExpressionResult[] elements,
    ) {
        auto var = slice.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported eval call.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported eval call.");

        auto destination = bindingPlace(variable);

        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? destination.arrayLength
            : scalarOperand!size_t(slice.upr);
        if (upper - lower != elements.length)
            throw new Exception("Unsupported eval call.");

        foreach (index; lower .. upper)
            writeStoredArrayElement(destination.index(index), elements[index - lower]);
        clearUninitializedBindingAddress(destination.address);
        return readBindingValue(variable);
    }

    // core.internal.atomic implements these with inline asm the interpreter
    // cannot execute. Interpretation is single-threaded, so plain reads and
    // writes of the pointed-at value are observably equivalent.
    private ExpressionResult runAtomicHookCall(
        imported!"dmd.expression".CallExp call,
        in imported!"quickbite.backends.interpreter.builtins".AtomicHook hook,
    ) {
        import quickbite.backends.interpreter.builtins: AtomicHook;
        import quickbite.backends.interpreter.place: Place;

        if (call.arguments is null || call.arguments.length == 0)
            throw new Exception("Unsupported eval call.");

        auto destinationExpression = (*call.arguments)[0];

        // Construct the pointer operand in its own typed place rather than
        // reading it through the carrier, the same construction the
        // dereferenced post-increment arm uses: `pointerOperandPlace`
        // evaluates `destinationExpression` exactly once, and
        // `.deref.address` is the identical address
        // `nativeElementAddress(..., 0, ...)` `loadNativePointerElement`
        // composed. The pointee type mirrors that same resolution, so an
        // enum-typed pointee still reads/writes as its base scalar here.
        // `aligned` checks a raw address value rather than dereferencing a
        // pointer, so it never calls this.
        Place pointerTarget() {
            return Place(
                pointerOperandPlace(destinationExpression).deref.address,
                destinationExpression.type.toBasetype.nextOf.toBasetype,
            );
        }

        // Mirrors `storeNativePointerElement`'s own pairing of a target
        // write with clearing that address's uninitialized-binding flag: a
        // native pointer can denote a still-void frame binding directly, and
        // once the atomic write lands, a later aggregate read must use those
        // frame bytes rather than materializing `.init` over them.
        void writeTarget(Place target, in ExpressionResult value) {
            writeStoredValue(target, value);
            clearUninitializedBindingAddress(target.address);
        }

        ExpressionResult operand() {
            if (call.arguments.length < 2)
                throw new Exception("Unsupported eval call.");
            return constructedExpressionValue((*call.arguments)[1]);
        }

        with (AtomicHook) final switch (hook) {
            case aligned:
                executeForEffectImpl(destinationExpression);
                return ExpressionResult(true);

            case load:
                return readStoredValue(pointerTarget);

            case store:
                writeTarget(pointerTarget, operand);
                return ExpressionResult.void_;

            case exchange: {
                auto target = pointerTarget;
                const previous = readStoredValue(target);
                writeTarget(target, operand);
                return previous;
            }

            case fetchAdd:
            case fetchSub: {
                auto target = pointerTarget;
                const previous = readStoredValue(target);
                const delta = hook == fetchAdd
                    ? operand.asLong
                    : -operand.asLong;
                writeTarget(
                    target,
                    castScalarToType(
                        destinationExpression.type.toBasetype.nextOf,
                        ExpressionResult(previous.asLong + delta),
                    ),
                );
                return previous;
            }
        }
    }

    // Struct-array `.dup` is a shallow copy when the element has no copy
    // construction. Copy the contiguous backing range once, then apply the
    // same offset-preserving copy to address-keyed callable and symbolic
    // metadata.
    private ExpressionResult runBlitStructArrayDupCall(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.expression_result: ExpressionResult;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        requireArgumentCount(call, 1);
        const source = runExpressionValue((*call.arguments)[0]);
        if (source == ExpressionResult.null_)
            return source;

        auto resultType = call.type.toBasetype.isTypeDArray;
        if (resultType is null)
            throw new Exception("Struct-array `.dup` needs a dynamic-array result.");

        const length = AggregateValue.length(AggregateValue.native(source));
        auto destination = NativeArray.allocate(resultType.next, length);
        const byteLength = length * typeByteSize(resultType.next);
        auto sourceAddress = cast(void*) AggregateValue.nativeArrayAddress(source);
        copyBytes(destination.block.address, sourceAddress, byteLength);
        copyStoredMetadataRange(
            sourceAddress,
            destination.block.address,
            byteLength,
        );

        auto header = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength,
            NativeBlock.Scan.conservative,
        );
        destination.writeSliceHeader(header, 0);
        return ExpressionResult.nativeAggregateValue(NativeAggregate(
            call.type,
            header,
            destination.block,
        ));
    }

    private void copyBytes(
        void* destination,
        void* source,
        in size_t byteLength,
    ) nothrow @trusted {
        import core.stdc.string: memmove;

        memmove(destination, source, byteLength);
    }

    private void requireArgumentCount(
        imported!"dmd.expression".CallExp call,
        in size_t count,
    ) {
        if (call.arguments is null || call.arguments.length != count)
            throw new Exception("Unsupported eval call.");
    }

    // `AggregateValue.elementAt`'s plain memory read sees a delegate-typed
    // element's zeroed bytes, not its live callable ExpressionResult -- a
    // live delegate entry is registered out-of-band in
    // `nativeDelegateSlots`, keyed by its own element address, exactly the
    // same gap `loadNativePointerElement`'s identical `TY.Tdelegate` arm
    // checks before falling through to a plain read.
    private ExpressionResult nativeArrayElementAt(in ExpressionResult array, in size_t index) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        auto aggregate = AggregateValue.native(array);
        auto elementType = aggregate.type.toBasetype.nextOf;
        if (elementType !is null && elementType.toBasetype.ty == TY.Tdelegate)
            if (auto delegate_ = AggregateValue.elementAddress(array, index) in nativeDelegateSlots)
                return delegateSlotResult(*delegate_);
        return readStoredValue(Place(aggregate.address, aggregate.type).index(index));
    }

    private ExpressionResult runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in bool captureLocals = false,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        in void*[VarDeclaration] closureAddresses = null,
        ConstructionDestination* constructionDestination = null,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces = null,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child._returnDestination = constructionDestination;
        forkExecutionStateInto(child);
        scope(exit) child.retireActivationFrameMetadata;
        bindCapturedReferenceSlots(function_, child, closureAddresses);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
            argumentPlaces,
        );

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            mergeFunctionState(
                function_,
                argumentExpressions,
                child,
                arguments,
                captureLocals,
            );
            throw exception;
        }
        mergeFunctionState(
            function_,
            argumentExpressions,
            child,
            arguments,
            captureLocals,
        );
        // A construction-destination call already wrote its result directly
        // into the caller's own place; a void call has nothing to report.
        // Either way there is nothing left to hand back through here.
        return ExpressionResult.void_;
    }

    // DMD keeps a member function's hidden `this` declaration separate from
    // its ordinary argument list. A receiver already bound onto the
    // walker's own `thisValue` channel names its address directly, whether
    // it is a struct's own storage or a class's body address -- no carrier
    // round-trip needed to recover it. Retain it for `ref this` forwarding
    // after parameter binding (which may clear a stale entry for that
    // declaration).
    private void bindThisReferenceAddress(
        FuncDeclaration function_,
        Place receiver,
    ) {
        auto vthis = function_.vthis;
        if (vthis is null)
            return;

        thisAddress = receiver.address;

        if (
            thisAddress !is null &&
            _activationFrame.hasReferenceSlot(vthis)
        )
            _activationFrame.setReferenceSlot(vthis, thisAddress);
    }

    private ExpressionResult runMemberFunction(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        in ExpressionResult receiver,
        in ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        // Set by a caller that already composed the receiver's place,
        // evaluated a `PtrExp` operand, or evaluated a ref-returning `CallExp`
        // receiver, and retained its address. The `this`-rebind below borrows
        // that same address instead of walking the receiver a second time,
        // which matters when the receiver expression is side-effecting (e.g.
        // `p()` in `p().get()`, `i++` in `a[i++].method()`, or the call
        // itself in `get(holder, evaluations).slot`).
        const(ExpressionResult)* precomputedReceiverPointerAddress = null,
        ConstructionDestination* constructionDestination = null,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces = null,
    ) {
        const memberReceiver = receiver;

        if (declarationName(function_) == "next") {
            if (classHasType(memberReceiver, "Throwable")) {
                const body = classIdentityAddress(memberReceiver);
                if (auto next = body in nativeThrowableNext)
                    return expressionResultFrom(*next);

                if (classHasFieldNamed(memberReceiver, "_nextInChainPtr"))
                    return classFieldNamed(
                        memberReceiver,
                        "_nextInChainPtr",
                    );
            }
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child._returnDestination = constructionDestination;
        forkExecutionStateInto(child);
        scope(exit) child.retireActivationFrameMetadata;
        bindCapturedReferenceSlots(
            function_,
            child,
            nestedReceiverCapturedAddresses(function_, memberReceiver),
        );
        // For constructor calls, DMD may blit the target variable to zero
        // before the ctor runs (e.g. `box = 0 , box.this(input)`), so the
        // receiver evaluates to a non-struct scalar.  Seed `thisValue` from
        // the struct's proper default in that case so the ctor body can write
        // fields.  When the receiver is already a valid struct (e.g.
        // MapResult created from a StructLiteralExp with elements), use it
        // as-is to preserve any hidden context fields.
        auto receiverClassType = function_.vthis is null
            ? null
            : function_.vthis.type;
        if (
            function_.isConstructorFunction &&
            !AggregateValue.isStruct(receiver)
        ) {
            auto structDecl = function_.constructorStructDeclaration;
            child.thisValue = receiverPlaceFrom(
                structDecl !is null
                    ? defaultValueResult(structDecl.type)
                    : memberReceiver,
                receiverClassType,
            );
        } else {
            child.thisValue = receiverPlaceFrom(memberReceiver, receiverClassType);
        }
        child.hasThis = true;
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
            argumentPlaces,
        );
        child.bindThisReferenceAddress(function_, child.thisValue);
        if (
            function_.isConstructorFunction &&
            constructionDestination !is null &&
            !isWritableLocation(receiverExpression)
        ) {
            import quickbite.backends.interpreter.place: Place;

            // DMD gives a struct constructor a temporary receiver to
            // initialize. The call's caller has fresher typed storage for the
            // completed value, so seed that storage from the receiver and
            // lend it to `this`. A writable receiver instead follows the
            // regular `this` binding below, which preserves DMD's assignment
            // receiver for a following postblit. This path does not return
            // `child.thisValue` for the caller to copy from.
            //
            // `constructorStructDeclaration !is null` alone is too broad: it
            // is non-null for any struct member function (DMD's `isThis`
            // just names the enclosing aggregate), not only a constructor.
            // An ordinary member call with a non-writable receiver (e.g.
            // `wrap().call()`, receiver `wrap()`) would otherwise also take
            // this branch and overwrite the call's own return-value
            // destination with the receiver instead of the callee's result.
            if (
                precomputedReceiverPointerAddress !is null &&
                precomputedReceiverPointerAddress.isPointer &&
                receiverExpression !is null
            ) {
                copyPlaceValue(
                    Place(
                        precomputedReceiverPointerAddress.pointerAddress,
                        receiverExpression.type,
                    ),
                    constructionDestination.place,
                );
            } else {
                writeStoredValue(constructionDestination.place, receiverValue(child.thisValue));
            }
            child.thisAddress = constructionDestination.place.address;
            if (child._activationFrame.hasReferenceSlot(function_.vthis))
                child._activationFrame.setReferenceSlot(
                    function_.vthis,
                    child.thisAddress,
                );
            child.bindStructReceiver(constructionDestination.place);
        } else if (
            function_.vthis !is null &&
            function_.vthis.type.toBasetype.isTypeStruct !is null &&
            isWritableLocation(receiverExpression)
        ) {
            import dmd.tokens: EXP;

            // An assign/construct/blit receiver (`(place = value).method()`)
            // already wrote `value` into `place` when `receiver` above was
            // computed (evaluating this call's own receiver expression runs
            // the assignment); resolve the writable address from `place`
            // itself rather than re-evaluating the assignment a second time.
            auto placeExpression = assignmentTarget(receiverExpression);
            if (placeExpression !is null && !isPeelableAssignmentTarget(placeExpression))
                // `place` is a `PtrExp`/`IndexExp` (e.g. `(*next() = value).
                // bump()`, `(arr[i++] = value).bump()`): it may embed a
                // side-effecting operand, and there is no precomputed
                // address for it to reuse (that precompute only exists for
                // a bare `PtrExp`/`IndexExp` *receiver expression itself*,
                // not one recovered by peeling an assignment) -- refuse
                // outright rather than re-evaluate that operand a second
                // time via `addressOfExpression` below.
                throw new Exception(
                    "Unsupported eval expression: chained postblit/method " ~
                    "call receiver's assignment target is a pointer/index " ~
                    "expression that cannot be re-addressed without " ~
                    "evaluating a side-effecting operand twice",
                );
            if (placeExpression is null)
                placeExpression = receiverExpression;

            ExpressionResult address;
            if (precomputedReceiverPointerAddress !is null) {
                address = *precomputedReceiverPointerAddress;
            } else if (
                placeExpression.isThisExp !is null &&
                thisAddress !is null
            ) {
                address = ExpressionResult.pointerValue(thisAddress);
            } else if (
                placeExpression.isDotVarExp !is null &&
                placeExpression.isDotVarExp.e1.isThisExp !is null &&
                thisAddress !is null
            ) {
                import quickbite.backends.interpreter.place: Place;

                address = ExpressionResult.pointerValue(Place(
                    thisAddress,
                    placeExpression.isDotVarExp.e1.type,
                ).field(placeExpression.isDotVarExp.var.isVarDeclaration).address);
            } else {
                address = addressOfExpression(placeExpression, EXP.address);
            }
            if (address.isPointer) {
                child.thisAddress = address.pointerAddress;
                if (child._activationFrame.hasReferenceSlot(function_.vthis))
                    child._activationFrame.setReferenceSlot(
                        function_.vthis,
                        child.thisAddress,
                    );
                // `child.thisValue` is a place by construction here, so it
                // always already carries the receiver's real type -- no
                // fallback to the declared `function_.vthis.type` needed.
                child.bindStructReceiver(Place(
                    address.pointerAddress,
                    child.thisValue.type,
                ));
            }
        }

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            mergeMemberFunctionState(
                function_,
                receiverExpression,
                argumentExpressions,
                child,
                arguments,
            );
            throw exception;
        }
        mergeMemberFunctionState(
            function_,
            receiverExpression,
            argumentExpressions,
            child,
            arguments,
        );

        if (function_.isConstructorFunction) {
            if (constructionDestination !is null) {
                if (constructionDestination.isFresh)
                    constructionDestination.markConstructed;
                return ExpressionResult.void_;
            }
            return receiverValue(child.thisValue);
        }

        // A construction-destination call already wrote its result directly
        // into the caller's own place; a void call has nothing to report.
        // Either way there is nothing left to hand back through here.
        return ExpressionResult.void_;
    }

    private void mergeFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in ExpressionResult[] arguments,
        in bool captureLocals = false,
    ) {
        mergeLazyArgumentMapsFrom(child);
    }

    private void mergeMemberFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in ExpressionResult[] arguments,
    ) {
        mergeLazyArgumentMapsFrom(child);
        child.returned = false;
    }

    private void mergeLazyArgumentMapsFrom(ref Walker child) {
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentFrames = child.lazyArgumentFrames;
        if (!child._lazyArgumentMapsBorrowed)
            _lazyArgumentMapsBorrowed = false;
    }

    private ExpressionResult structValueFromCell(in ExpressionResult current, ref NativeStruct cell) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readScalarLeaf;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        ExpressionResult value = current;
        foreach (index; 0 .. cell.fieldCount) {
            auto fieldType = cell.fieldDeclaration(index).type;

            if (isNativeScalarType(fieldType)) {
                value = ExpressionResult.nativeAggregateValue(AggregateValue.withStructField(
                    AggregateValue.native(value), index,
                    readScalarLeaf(Place(cell.field(index).ptr, fieldType)),
                ));
                continue;
            }

            if (isStaticArrayType(fieldType)) {
                auto elementType = fieldType.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                auto fieldValue = readStoredValue(
                    AggregateValue.fieldAt(AggregateValue.native(value), index),
                );
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = cell.arrayField(index);
                foreach (elementIndex; 0 .. AggregateValue.elementCount(fieldValue)) {
                    ExpressionResult elementValue;
                    if (structType !is null) {
                        auto elementCell = arrayCell.structElement(elementIndex);
                        elementValue = structValueFromCell(
                            readStoredValue(
                                AggregateValue.elementAt(AggregateValue.native(fieldValue), elementIndex),
                            ),
                            elementCell,
                        );
                    } else
                        elementValue = readScalarLeaf(Place(
                            arrayCell.element(elementIndex).ptr,
                            elementType,
                        ));
                    fieldValue = ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                        AggregateValue.native(fieldValue),
                        elementIndex,
                        elementValue,
                    ));
                }
                value = ExpressionResult.nativeAggregateValue(
                    AggregateValue.withStructField(AggregateValue.native(value), index, fieldValue),
                );
                continue;
            }

            if (isDynamicArrayType(fieldType)) {
                auto elementType = fieldType.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                const fieldValue = readStoredValue(
                    AggregateValue.fieldAt(AggregateValue.native(value), index),
                );
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = cell.sliceField(index);
                copyArrayCellTo(
                    fieldType,
                    arrayCell,
                    Place(
                        AggregateValue.native(value).address,
                        AggregateValue.native(value).type,
                    )
                        .field(cell.fieldDeclaration(index)),
                );
                continue;
            }

            auto nestedStructType = fieldType.toBasetype.isTypeStruct;
            if (nestedStructType is null || nestedStructType.sym.isUnionDeclaration !is null)
                continue;

            auto nestedValue = readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(value), index),
            );
            if (!AggregateValue.isStruct(nestedValue))
                continue;

            auto nestedCell = cell.structField(index);
            value = ExpressionResult.nativeAggregateValue(AggregateValue.withStructField(
                AggregateValue.native(value), index,
                structValueFromCell(nestedValue, nestedCell),
            ));
        }

        return value;
    }

    // `assign`/`construct`/`blit` (`=`, its DMD-synthesized construction
    // form, and its DMD-synthesized zero-init/copy form) all share the
    // `BinExp`-derived `.e1` target shape; DMD's own "assign, then mutate the
    // target in place" lowering (e.g. `emplaceRef`'s generated
    // `(this.payload = args).__postblit()`) chains a postblit/method call
    // straight off one of these. Returns the assignment's target expression,
    // or `null` if `expression` is none of the three.
    private static imported!"dmd.expression".Expression assignmentTarget(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto assign = expression.isAssignExp)
            return assign.e1;
        if (auto construct = expression.isConstructExp)
            return construct.e1;
        if (auto blit = expression.isBlitExp)
            return blit.e1;
        return null;
    }

    // Whether `expression` -- a target recovered from an assign/construct/
    // blit chain by `assignmentTarget` -- is safe to resolve an address from
    // directly, i.e. carries no side-effecting operand that a second
    // evaluation could re-run. Only a plain local variable or a `this`-
    // rooted field-access chain qualify: the only shapes the commit's actual
    // use case (`emplaceRef`'s `(this.payload = args).__postblit()`-style
    // lowerings) ever produces. A `PtrExp`/`IndexExp` target (e.g.
    // `(*next() = value).bump()`, `(arr[i++] = value).bump()`) may embed an
    // arbitrary side-effecting operand; the receiver-level
    // `precomputedReceiverPointerAddress` precompute that protects a bare
    // `PtrExp`/`IndexExp` *receiver* doesn't reach a target recovered by
    // peeling, so re-deriving its address via `addressOfExpression` would
    // silently re-run that side effect a second time -- callers must refuse
    // that shape outright instead (see `runMemberFunction`).
    private static bool isPeelableAssignmentTarget(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression.isVarExp !is null || expression.isThisExp !is null)
            return true;
        if (auto dotVar = expression.isDotVarExp)
            return isPeelableAssignmentTarget(dotVar.e1);
        return false;
    }

    private bool isWritableLocation(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression is null)
            return false;

        // By the time a chained postblit/method call's receiver expression
        // is evaluated, the assignment/construction/blit has already written
        // its value into the target place -- the call's receiver is
        // writable exactly when that place is.
        if (auto target = assignmentTarget(expression))
            return isWritableLocation(target);

        // A `ref`-returning call denotes the lvalue it returned, so a member
        // call on it must reach that lvalue's storage rather than a copy.
        if (auto call = expression.isCallExp)
            return call.f !is null && returnsRef(call.f);

        // A comma expression denotes its right operand, so it is writable
        // exactly when that operand is.
        if (auto comma = expression.isCommaExp)
            return isWritableLocation(comma.e2);

        return
            expression.isVarExp !is null ||
            expression.isDotVarExp !is null ||
            expression.isThisExp !is null ||
            expression.isIndexExp !is null ||
            expression.isPtrExp !is null;
    }

    private void bindFunctionParameters(
        imported!"dmd.func".FuncDeclaration function_,
        in ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions = null,
        FrameBlock callerFrame = FrameBlock.init,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces = null,
    ) {
        if (arguments.length == 0) {
            if (function_.parameters !is null && function_.parameters.length != 0)
                throw new Exception("Unsupported interpreter call arguments.");
            return;
        }

        if (
            function_.parameters is null ||
            function_.parameters.length != arguments.length
        )
            throw new Exception("Unsupported interpreter call arguments.");

        foreach (index, parameter; *function_.parameters) {
            if (parameterIsLazy(parameter)) {
                bindLazyFunctionParameter(
                    parameter,
                    index < argumentExpressions.length
                        ? argumentExpressions[index]
                        : null,
                    callerFrame,
                );
                continue;
            }

            // Reference parameters borrow the caller's native place.
            import quickbite.backends.interpreter.frame_layout:
                isReferenceParameter;
            const parameterIsReference = isReferenceParameter(
                function_,
                index,
                parameter,
            );
            if (parameterIsReference && index < argumentExpressions.length) {
                const bound = bindReferenceSlot(
                    parameter,
                    argumentExpressions[index],
                    index < evaluatedArguments.length
                        ? evaluatedArguments[index].indices
                        : null,
                    index < evaluatedArguments.length
                        ? evaluatedArguments[index].address
                        : null,
                    index < evaluatedArguments.length
                        ? evaluatedArguments[index].selectedLvalue
                        : null,
                    callerFrame,
                );
                if (!bound)
                    bindSyntheticReferenceSlot(parameter, arguments[index]);
                continue;
            }

            if (parameterIsReference) {
                bindSyntheticReferenceSlot(parameter, arguments[index]);
                continue;
            }

            if (index < argumentPlaces.length)
                copyPlaceValue(argumentPlaces[index], bindingPlace(parameter));
            else
                setLocal(parameter, arguments[index]);
        }
    }

    // A synthesized call has no source lvalue to borrow. Give its reference
    // parameter one ordinary native allocation. The reference slot is scanned
    // and becomes the durable root before the temporary owner is released;
    // calls with real source expressions take the direct caller-place path.
    private void bindSyntheticReferenceSlot(
        VarDeclaration parameter,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.layout:
            typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;

        auto block = NativeBlock.allocate(
            typeByteSize(parameter.type),
            typeHasPointers(parameter.type)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );
        writeStoredValue(
            Place(block.address, parameter.type),
            storageValue(parameter.type, value),
        );
        retainTemporaryPointerOwner(block);
        _activationFrame.setReferenceSlot(parameter, block.address);
    }

    // Compose the caller lvalue once and store its address in this
    // activation's reference slot. Unsupported shapes decline so synthesized
    // call sites can provide an address-keyed native temporary instead.
    private bool bindReferenceSlot(
        VarDeclaration parameter,
        Expression argumentExpression,
        const(size_t[const(void)*]) evaluatedIndices,
        const(void)* evaluatedAddress,
        const(Expression) evaluatedSelectedLvalue,
        FrameBlock callerFrame,
    ) {
        import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;

        if (evaluatedSelectedLvalue !is null)
            argumentExpression = cast(Expression) evaluatedSelectedLvalue;

        void* address = cast(void*) evaluatedAddress;
        if (address is null) {
            if (argumentExpression is null)
                return false;
            try {
                address = placeOfLvalue(
                    argumentExpression,
                    (variable) => callerReferenceBase(variable, callerFrame),
                    (expression) => evaluatedIndex(expression, evaluatedIndices),
                ).address;
            } catch (Exception) {
                return false;
            }
        }

        if (address is null)
            return false;
        _activationFrame.setReferenceSlot(parameter, address);
        return true;
    }

    // Resolve a caller binding through its sole native storage authority.
    // A reference slot already dereferences to the forwarded place through
    // `FrameBlock.bindingAddress`, so owning and forwarded bindings share
    // this path.
    private void* callerReferenceBase(
        VarDeclaration variable,
        FrameBlock callerFrame,
    ) @trusted {
        if (variable.isDataseg) {
            materializeDatasegInitializer(variable);
            return moduleTable.storageFor(variable);
        }

        if (callerFrame.hasSlot(variable)) {
            auto address = callerFrame.bindingAddress(variable);
            if (address !is null)
                return address;
        }

        throw new Exception(
            "quickbite.backends.interpreter.impl.Walker.callerReferenceBase: "
            ~ "variable has no caller-side storage",
        );
    }

    // Resolve a captured variable through the native static-link chain. An
    // intermediate nested activation need not name the variable itself, so its
    // own layout may have no relay slot; the next enclosing FrameBlock remains
    // the authoritative owner or reference forwarder.
    private void* capturedBindingAddress(VarDeclaration variable) {
        if (variable.isDataseg) {
            materializeDatasegInitializer(variable);
            return bindingAddress(variable);
        }

        if (_activationFrame.hasSlot(variable))
            return _activationFrame.bindingAddress(variable);

        foreach (frame; _enclosingFrames)
            if (frame.hasSlot(variable))
                return frame.bindingAddress(variable);

        throw new Exception(
            "quickbite.backends.interpreter.impl.Walker."
            ~ "capturedBindingAddress: variable has no enclosing storage",
        );
    }

    // The call-argument walk records each runtime index before returning the
    // argument value, so address composition reuses the exact result
    // without re-evaluating a side-effecting subexpression. A folded integer
    // needs no entry; unsupported/synthetic calls have neither and decline.
    private size_t evaluatedIndex(
        Expression expression,
        const(size_t[const(void)*]) evaluatedIndices,
    ) @trusted {
        if (auto evaluated = cast(const(void)*) expression in evaluatedIndices)
            return *evaluated;

        auto integer = expression.isIntegerExp;
        if (integer is null)
            throw new Exception(
                "quickbite.backends.interpreter.impl.Walker.evaluatedIndex: "
                ~ "index was not evaluated with its ref argument",
            );

        return cast(size_t) integer.getInteger;
    }

    // Captures are addresses into the enclosing activation. A delegate
    // snapshots those addresses when created so an escaped closure keeps the
    // GC-owned frame alive; a direct nested call resolves them from the
    // currently enclosing frame.
    private void bindCapturedReferenceSlots(
        imported!"dmd.func".FuncDeclaration function_,
        ref Walker child,
        in void*[VarDeclaration] closureAddresses = null,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;

        foreach (variable; capturedVariables(function_)) {
            if (!child._activationFrame.hasReferenceSlot(variable))
                continue;

            void* address;
            if (auto closureAddress = variable in closureAddresses) {
                address = cast(void*) *closureAddress;
            } else {
                try {
                    address = capturedBindingAddress(variable);
                } catch (Exception) {
                    continue;
                }
            }

            if (address is null)
                continue;

            child._activationFrame.setReferenceSlot(variable, address);
        }
    }

    // Retain a lazy argument's expression and caller frame. Each use evaluates
    // the expression against that live frame, as required by D's lazy
    // parameter semantics.
    private void bindLazyFunctionParameter(
        VarDeclaration parameter,
        Expression argumentExpression,
        FrameBlock callerFrame,
    ) {
        if (auto variable = lazyExpressionVariable(argumentExpression)) {
            if (auto expression = variable in lazyArgumentExpressions) {
                // Mutable locals keep the borrowed-map values usable after
                // detaching replaces this Walker's map handles.
                auto forwardedExpression = *expression;
                FrameBlock forwardedFrame;
                auto hasForwardedFrame = variable in lazyArgumentFrames;
                if (hasForwardedFrame !is null)
                    forwardedFrame = *hasForwardedFrame;

                detachLazyArgumentMaps;
                lazyArgumentExpressions[parameter] = forwardedExpression;
                if (hasForwardedFrame !is null)
                    lazyArgumentFrames[parameter] = forwardedFrame;
                return;
            }
        }

        if (argumentExpression is null)
            throw new Exception("Unsupported interpreter call arguments.");

        detachLazyArgumentMaps;
        lazyArgumentExpressions[parameter] = argumentExpression;
        lazyArgumentFrames[parameter] = callerFrame;
    }

    private void detachLazyArgumentMaps() {
        if (!_lazyArgumentMapsBorrowed)
            return;

        lazyArgumentExpressions = lazyArgumentExpressions.dup;
        lazyArgumentFrames = lazyArgumentFrames.dup;
        _lazyArgumentMapsBorrowed = false;
    }

    private ExpressionResult runLazyArgument(
        VarDeclaration variable,
        ConstructionDestination* constructionDestination = null,
    ) {
        auto expression = variable in lazyArgumentExpressions;
        if (expression is null)
            throw new Exception("Unsupported eval call.");

        auto capturedFrame = variable in lazyArgumentFrames;
        if (capturedFrame is null)
            throw new Exception("Unsupported eval call.");

        auto savedFrame = _activationFrame;
        scope(exit)
            _activationFrame = savedFrame;

        _activationFrame = *capturedFrame;
        return runLazyArgumentExpression(*expression, constructionDestination);
    }

    private ExpressionResult runLazyArgumentExpression(
        Expression expression,
        ConstructionDestination* constructionDestination = null,
    ) {
        if (auto function_ = functionPointerExpressionFunction(expression))
            return runFunction(
                function_,
                [],
                [],
                true,
                null,
                null,
                constructionDestination,
            );

        if (constructionDestination !is null) {
            runExpression(expression, *constructionDestination);
            return ExpressionResult.void_;
        }

        return constructedExpressionValue(expression);
    }

    private VarDeclaration lazyCallVariable(imported!"dmd.expression".CallExp call) {
        if (call.arguments !is null && call.arguments.length != 0)
            return null;

        return lazyExpressionVariable(call.e1);
    }

    private VarDeclaration lazyExpressionVariable(Expression expression) {
        auto variable = expression is null ? null : expression.isVarExp;
        if (variable is null)
            return null;

        auto declaration = variable.var.isVarDeclaration;
        if (declaration is null)
            return null;

        return (declaration in lazyArgumentExpressions) is null
            ? null
            : declaration;
    }

    private bool parameterIsLazy(VarDeclaration parameter) {
        import dmd.astenums: STC;

        return (parameter.storage_class & STC.lazy_) != STC.none;
    }

    private ExpressionResult runEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;

        const same = hasScalarEqualityOperands(equal)
            ? scalarEquality(equal)
            : equalOperands(equal);
        if (equal.op == EXP.notEqual)
            return ExpressionResult(!same);
        return ExpressionResult(same);
    }

    // DMD has already reconciled `==`'s non-scalar operand shapes by the
    // time this walks the AST (`dcast.d`'s `typeCombine`), and its own
    // operator-overload rewriting (`opover.d`'s `opOverloadEqual`) means a
    // pointer or a non-null class pair never reaches a real `EqualExp` node
    // at all: a pointer `==` is rewritten to `is`, and a class `==` (other
    // than against a `typeof(null)`-typed operand, which `opOverloadEqual`
    // deliberately leaves alone) to an `opEquals` `CallExp`. So only an
    // array, a delegate, or a still-untyped numeric pair (imaginary/complex,
    // or that one `class == typeof(null)` survivor) can land here. Dispatch
    // the first two on their STATIC type straight to the mechanism that
    // answers them, rather than reading a runtime tag off an
    // already-evaluated carrier value.
    private bool equalOperands(imported!"dmd.expression".EqualExp equal) {
        import dmd.astenums: TY;

        const ty = equal.e1.type.toBasetype.ty;

        if (ty == TY.Tsarray || ty == TY.Tarray) {
            const left = runExpressionValue(equal.e1);
            const right = runExpressionValue(equal.e2);
            return equalArrayValues(left, right);
        }

        if (ty == TY.Tdelegate) {
            // A delegate's identity depends on the runtime closure registry
            // (`_executionState.delegates`, keyed by a per-evaluation id),
            // not a native-layout slot read; see `equalDelegateValues`.
            const left = runExpressionValue(equal.e1);
            const right = runExpressionValue(equal.e2);
            return equalDelegateValues(left, right);
        }

        // Imaginary/complex operands, and the obscure `class == typeof(
        // null)` pair `opOverloadEqual` leaves untyped: `equalValues`'s own
        // numeric-widening comparison (and, for the latter, its raw
        // fallback) still answers these directly off the carrier.
        const left = runExpressionValue(equal.e1);
        const right = runExpressionValue(equal.e2);
        return equalValues(left, right);
    }

    private bool equalValues(in ExpressionResult left, in ExpressionResult right) {
        // A character compares with a numeric scalar by code point, as D's
        // integral promotions do: bytes read from native memory keep their
        // integer kind through `cast(string)`, e.g. in std.file.readText.
        if (
            (left.isNumericScalar || left.isCharacter) &&
            (right.isNumericScalar || right.isCharacter) &&
            (left.isCharacter || right.isCharacter)
        )
            return left.castTo!real.asReal == right.castTo!real.asReal;

        if (left.isNumericScalar && right.isNumericScalar)
            return left.asReal == right.asReal;

        if (AggregateValue.isArray(left) && AggregateValue.isArray(right))
            return equalArrayValues(left, right);

        // DMD attaches an array comparison's `object.__equals` rewrite as
        // `EqualExp.lowering` rather than replacing the AST node itself
        // (`expressionsem.d`'s `EqualExp::semantic`, the array-comparison
        // branch keeps `result = exp`), so an interpreter that walks `e1`/
        // `e2` directly -- as `equalArrayValues`'s element recursion below
        // does -- never sees that dispatch and reaches this struct arm for
        // each element pair instead. A DIRECT struct `==` does not have this
        // problem: `opOverloadEqual` rewrites it to a real `a.opEquals(b)`
        // `CallExp` at semantic time, so normal call dispatch already runs
        // the struct's own (possibly compiler-generated) `opEquals` body --
        // which is how a struct's own AA-typed field ends up comparing
        // through the interpreted `_d_aaEqual` call that body contains.
        // Route this array-reached struct pair through that same dispatch
        // (`StructDeclaration.xeq`, the resolved `opEquals`/`TypeInfo_Struct.
        // xopEquals` DMD's own semantic already resolved) instead of
        // reimplementing struct equality by hand: `equalStructValues`
        // remains correct only for a POD struct (no `xeq`), where DMD itself
        // lowers `==` to `is` (`runIdentityExpression`'s own comment) and
        // raw field/bitwise comparison is exactly right.
        if (AggregateValue.isStruct(left) && AggregateValue.isStruct(right)) {
            auto structType = AggregateValue.native(left).type.toBasetype.isTypeStruct;
            if (structType !is null && structType.sym.xeq !is null) {
                import quickbite.backends.interpreter.layout:
                    typeByteSize, typeHasPointers;
                import quickbite.backends.interpreter.native_block: NativeBlock;
                import quickbite.backends.interpreter.place: Place;

                auto resultType = structType.sym.xeq.type.toBasetype.isTypeFunction.next;
                auto resultBlock = NativeBlock.allocate(
                    typeByteSize(resultType),
                    typeHasPointers(resultType)
                        ? NativeBlock.Scan.conservative
                        : NativeBlock.Scan.no,
                );
                auto destination = ConstructionDestination(Place(
                    resultBlock.address,
                    resultType,
                ));
                runMemberFunction(
                    structType.sym.xeq,
                    null,
                    left,
                    [right],
                    null,
                    null,
                    null,
                    &destination,
                );
                return isTruthy(readStoredValue(destination.place));
            }

            return equalStructValues(left, right);
        }

        // `EqualExp::semantic` (expressionsem.d) always lowers `aa1 == aa2`
        // to a call to `object._d_aaEqual!(K, V)(aa1, aa2)` whenever the
        // left operand's type is an associative array, so a top-level AA
        // comparison never reaches this function. An AA-typed STRUCT FIELD
        // cannot reach the raw fallback below either, now that the struct
        // arm above dispatches through `xeq`: any struct holding an AA field
        // is exactly the case DMD's own `needOpEquals` refuses to consider
        // POD, so it always has a real `xeq` and never falls through to
        // `equalStructValues`'s field-by-field walk. The raw fallback below
        // stays correct for what it actually still receives -- plain
        // pointers, class references, and other scalar-shaped values -- but
        // it does NOT correctly answer for an AA handle: two content-equal,
        // identity-distinct AAs are different `Impl*` pointers, so a raw
        // compare would wrongly report them unequal.

        if (left.isFunctionPointer || right.isFunctionPointer)
            return equalDelegateValues(left, right);

        return left == right;
    }

    // A delegate compares equal to another by its runtime `{function,
    // context}` pair (D's builtin delegate equality) -- not by the internal
    // `functionPointerId` this walker mints fresh for every delegate
    // EXPRESSION evaluation. `&s1.get` evaluated twice yields two different
    // ids for the identical function+receiver, so the raw
    // `ExpressionResult == ExpressionResult` fallback (still correct for two
    // results carrying the same id, e.g. after plain assignment) answers
    // unequal for the exact case D
    // requires equal. `contextPointer` already carries the receiver's own
    // binding address for a member-function delegate, not a copy
    // (`delegateContextPointer`'s `VarExp` arm resolves it the same way for
    // every delegate kind, member or closure), so comparing it directly is
    // sufficient for a NON-capturing delegate (bound method or plain
    // function pointer) -- no separate receiver-identity tracking is
    // needed there. A CAPTURING closure literal is different: every
    // literal-created delegate shares the same `contextPointer` (`ExpressionResult.
    // pointerValue(null)`, set in `runFunctionLiteralDeclaration`), so two
    // closures of the identical lambda over two different activations
    // (`make(1)` and `make(2)` each returning `() => y`) would otherwise
    // compare equal despite closing over distinct per-activation frame
    // storage. `capturedAddresses` (`RuntimeDelegate`'s per-activation
    // snapshot of each captured variable's frame address) carries that
    // identity instead, so two delegates are equal only when their
    // captured-variable sets match in size and every captured variable
    // resolves to the same address on both sides; an empty set on both
    // sides (nothing captured) falls back to the `contextPointer`
    // comparison unchanged. A `functionPointerId` with no registered
    // runtime (a plain function pointer, never registered in `delegates`)
    // falls back to comparing the two ids directly. A delegate backed by
    // native code has no `functionPointerId` at all -- its `{context,
    // funcptr}` pair from `nativeDelegateSlots` already IS the runtime
    // identity D's builtin equality compares, with no registry indirection
    // to resolve.
    private bool equalDelegateValues(in ExpressionResult left, in ExpressionResult right) {
        if (!left.isFunctionPointer && !left.isNativeDelegate ||
            !right.isFunctionPointer && !right.isNativeDelegate)
            return left == right;

        const leftSlot = delegateSlotValue(left);
        const rightSlot = delegateSlotValue(right);
        if (leftSlot.isNative || rightSlot.isNative)
            return leftSlot.isNative == rightSlot.isNative &&
                leftSlot.context is rightSlot.context &&
                leftSlot.funcptr is rightSlot.funcptr;

        auto leftRuntime = leftSlot.functionPointerId in _executionState.delegates;
        auto rightRuntime = rightSlot.functionPointerId in _executionState.delegates;
        if (leftRuntime is null || rightRuntime is null)
            return leftSlot.functionPointerId == rightSlot.functionPointerId;

        if (leftRuntime.function_ !is rightRuntime.function_)
            return false;

        if (
            leftRuntime.capturedAddresses.length == 0 &&
            rightRuntime.capturedAddresses.length == 0
        )
            return leftRuntime.contextPointer == rightRuntime.contextPointer;

        if (leftRuntime.capturedAddresses.length != rightRuntime.capturedAddresses.length)
            return false;

        foreach (variable, address; leftRuntime.capturedAddresses) {
            auto rightAddress = variable in rightRuntime.capturedAddresses;
            if (rightAddress is null || *rightAddress !is address)
                return false;
        }

        return true;
    }

    private bool equalArrayValues(in ExpressionResult left, in ExpressionResult right) {
        auto leftAggregate = AggregateValue.native(left);
        auto rightAggregate = AggregateValue.native(right);
        if (AggregateValue.length(leftAggregate) != AggregateValue.length(rightAggregate))
            return false;

        foreach (index; 0 .. AggregateValue.length(leftAggregate))
            if (!equalValues(
                arrayElementForEquality(left, index),
                arrayElementForEquality(right, index),
            ))
                return false;

        return true;
    }

    private ExpressionResult arrayElementForEquality(in ExpressionResult value, in size_t index) {
        import quickbite.backends.interpreter.place: Place;

        if (!value.isNativeAggregate)
            return readStoredValue(
                AggregateValue.elementAt(AggregateValue.native(value), index),
            );

        auto aggregate = AggregateValue.native(value);
        return readStoredValue(
            Place(aggregate.address, aggregate.type).index(index),
        );
    }

    // Recurse field-by-field through `equalValues` (mirroring
    // `equalArrayValues`) instead of a raw `ExpressionResult ==
    // ExpressionResult` compare (the `left == right` fallback above), so
    // each field gets the same numeric-scalar coercion a top-level `==`
    // already applies.
    private bool equalStructValues(in ExpressionResult left, in ExpressionResult right) {
        const count = AggregateValue.fieldCount(left);
        if (count != AggregateValue.fieldCount(right))
            return false;

        foreach (index; 0 .. count)
            if (!equalValues(
                structFieldForEquality(left, index),
                structFieldForEquality(right, index),
            ))
                return false;

        return true;
    }

    private ExpressionResult structFieldForEquality(in ExpressionResult value, in size_t index) {
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: Place;

        if (!value.isNativeAggregate)
            return readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(value), index),
            );

        auto aggregate = AggregateValue.native(value);
        auto fields = structFields(aggregate.type.toBasetype.isTypeStruct);
        return readStoredValue(
            Place(aggregate.address, aggregate.type).field(fields[index]),
        );
    }

    private bool isScalarCompoundAssignExpression(
        imported!"dmd.expression".Expression expression,
    ) const {
        import dmd.tokens: EXP;

        switch (expression.op) with (EXP) {
            case minAssign:
            case mulAssign:
            case divAssign:
            case modAssign:
            case leftShiftAssign:
            case rightShiftAssign:
            case unsignedRightShiftAssign:
            case andAssign:
            case orAssign:
            case xorAssign:
                return true;

            default:
                return false;
        }
    }

    private ExpressionResult runCompoundAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        // Compound assignment is one
        // lvalue evaluation. Retaining its Place avoids both the aggregate
        // receiver snapshot and the old second evaluation during writeback.
        if (
            (assign.e1.isDotVarExp !is null || assign.e1.isIndexExp !is null) &&
            isDirectProjectionWriteTarget(assign.e1)
        ) {
            auto destination = directWriteProjectionPlace(assign.e1);
            const left = readStoredValue(destination);
            const right = constructedExpressionValue(assign.e2);
            const value = compoundAssignedValue(assign, left, right);
            writeStoredValue(
                destination,
                castScalarToType(assign.e1.type, value),
            );
            clearProjectionRootUninitialized(assign.e1);
            return readStoredValue(destination);
        }

        // A dereferenced native pointer (`*p += v`) has no storage-owned
        // Place: `hasDirectWriteProjectionPlace` never accepts a `PtrExp`.
        // `pointerOperandPlace` evaluates `pointer.e1` exactly once,
        // matching `runPostIncrementExpression`'s identical `PtrExp` arm;
        // reuse the resulting place for the old value, the write, and the
        // result, instead of the fallback below, which re-evaluates
        // `pointer.e1` in the initial read, `writeLocation`'s own `PtrExp`
        // arm, and the closing read.
        if (auto pointer = assign.e1.isPtrExp) {
            import quickbite.backends.interpreter.place: Place;

            auto destination = Place(
                pointerOperandPlace(pointer.e1).deref.address,
                assign.e1.type.toBasetype,
            );
            const left = readStoredValue(destination);
            const right = constructedExpressionValue(assign.e2);
            const value = compoundAssignedValue(assign, left, right);
            writeStoredValue(destination, value);
            return readStoredValue(destination);
        }

        // The pointer-index sibling of the above (`p[i] += v`, or `(*q)[i]
        // += v` once `*q` is itself pointer-typed):
        // `hasDirectWriteProjectionPlace`'s `IndexExp` arm excludes a
        // pointer-typed `e1` outright, so this also has no storage-owned
        // Place. Resolve the pointer once, then the index once, in the
        // same order the read path (`runIndexExpression`) already
        // evaluates them.
        if (auto index = assign.e1.isIndexExp) {
            import quickbite.backends.interpreter.place: Place;
            import quickbite.frontend.dmd.types: isPointerType;

            if (isPointerType(index.e1.type)) {
                auto pointerPlace = pointerOperandPlace(index.e1);
                const arrayIndex = scalarOperand!size_t(index.e2);
                auto destination = Place(
                    pointerPlace.index(arrayIndex).address,
                    assign.e1.type.toBasetype,
                );
                const left = readStoredValue(destination);
                const right = constructedExpressionValue(assign.e2);
                const value = compoundAssignedValue(assign, left, right);
                writeStoredValue(destination, value);
                return readStoredValue(destination);
            }
        }

        const left = constructedExpressionValue(assign.e1);
        const right = constructedExpressionValue(assign.e2);
        const value = compoundAssignedValue(assign, left, right);
        writeLocation(assign.e1, value);
        return constructedExpressionValue(assign.e1);
    }

    private ExpressionResult compoundAssignedValue(
        imported!"dmd.expression".BinExp assignment,
        in ExpressionResult left,
        in ExpressionResult right,
    ) {
        import dmd.tokens: EXP;

        switch (assignment.op) {
            // DMD's own `scaleFactor` already folds `p += n`/`p -= n`'s
            // element delta into a byte offset scaled by the pointee's size
            // at the frontend level (`dcast.d`'s `scaleFactor`, invoked from
            // `BinAssignExp` semantic for a pointer lhs and integral rhs);
            // `pointerOffsetBy` adds its argument as raw bytes, so `right`
            // needs no further scaling here.
            case EXP.addAssign:
                if (left.isPointer)
                    return left.pointerOffsetBy(right.asLong);
                return left + right;

            case EXP.minAssign:
                if (left.isPointer)
                    return left.pointerOffsetBy(-right.asLong);
                return left - right;

            case EXP.mulAssign:
                return left * right;

            case EXP.divAssign:
                rejectIntMinMinusOneOverflow(left, right, "/");
                return left / right;

            case EXP.modAssign:
                rejectIntMinMinusOneOverflow(left, right, "%");
                return left % right;

            case EXP.leftShiftAssign:
                return runIntegerBinaryValue(assignment, left, right, "<<");

            case EXP.rightShiftAssign:
                return runIntegerBinaryValue(assignment, left, right, ">>");

            case EXP.unsignedRightShiftAssign:
                return runIntegerBinaryValue(assignment, left, right, ">>>");

            case EXP.andAssign:
                return runIntegerBinaryValue(assignment, left, right, "&");

            case EXP.orAssign:
                return runIntegerBinaryValue(assignment, left, right, "|");

            case EXP.xorAssign:
                return runIntegerBinaryValue(assignment, left, right, "^");

            default:
                throw new Exception("Unsupported eval compound assignment.");
        }
    }

    private ExpressionResult runIntegerBinaryValue(
        imported!"dmd.expression".BinExp expression,
        in ExpressionResult leftValue,
        in ExpressionResult rightValue,
        in string operator,
    ) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget;

        const left = leftValue.asLong;
        const right = rightValue.asLong;
        long result;
        switch (operator) {
            case "<<":
                result = left << right;
                break;

            case ">>":
                result = left >> right;
                break;

            case ">>>":
                return castScalarResult(
                    ExpressionResult(unsignedShiftRight(leftValue, expression.e1.type, right)),
                    backendCastTarget(expression.type),
                );

            case "&":
                result = left & right;
                break;

            case "|":
                result = left | right;
                break;

            case "^":
                result = left ^ right;
                break;

            default:
                assert(0, "unsupported integer binary operator");
        }

        return castScalarResult(ExpressionResult(result), backendCastTarget(expression.type));
    }

    private ulong unsignedShiftRight(
        in ExpressionResult value,
        imported!"dmd.mtype".Type type,
        in long shift,
    ) {
        import dmd.astenums: TY;

        auto basetype = type is null ? null : type.toBasetype;
        if (basetype is null)
            return cast(ulong) value.asLong >> shift;

        switch (basetype.ty) with (TY) {
            case Tint8:
            case Tuns8:
            case Tchar:
                return cast(ubyte) value.asLong >> shift;

            case Tint16:
            case Tuns16:
            case Twchar:
                return cast(ushort) value.asLong >> shift;

            case Tint32:
            case Tuns32:
            case Tdchar:
                return cast(uint) value.asLong >> shift;

            case Tint64:
            case Tuns64:
                return cast(ulong) value.asLong >> shift;

            default:
                throw new Exception("Unsupported unsigned right shift operand.");
        }
    }

    private ExpressionResult runDotVarExpression(imported!"dmd.expression".DotVarExp dot) {
        import quickbite.backends.interpreter.class_info_projection:
            isClassInfoNamePointerMember,
            isSyntheticClassInfoMember;
        import quickbite.backends.interpreter.messages: receiverName;
        import std.conv: text;

        // Select a field directly from an
        // addressable struct receiver. `readStoredValue` still returns an
        // ordinary by-value field result; only the discarded whole-receiver
        // snapshot disappears.
        if (
            dot.var.isVarDeclaration !is null &&
            hasProjectionPlace(dot)
        )
            return readStoredValue(projectionPlace(dot));

        if (auto field = dot.var.isVarDeclaration) {
            // Only a HIT answers directly: this fast path's `fieldPlace` is
            // the field's offset within `variable`'s own storage, correct
            // only when `variable` (unlike a class receiver, always a
            // reference) holds the enclosing STRUCT by value. A class
            // receiver falls through unregistered and is answered correctly
            // further down, by the general path that first dereferences the
            // receiver to the object body before composing the field
            // address.
            if (field.type.toBasetype.isTypeClass !is null)
                if (auto variableExpression = dot.e1.isVarExp)
                    if (auto variable = variableExpression.var.isVarDeclaration)
                        if (hasBindingPlace(variable)) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            if (auto typeInfo = fieldPlace.address in nativeTypeInfoSlots)
                                return ExpressionResult.typeName(*typeInfo);
                        }

            auto pointerType = field.type.toBasetype.isTypePointer;
            if (
                pointerType !is null &&
                pointerType.nextOf.toBasetype.isTypeFunction !is null
            )
                if (auto variableExpression = dot.e1.isVarExp)
                    if (auto variable = variableExpression.var.isVarDeclaration)
                        if (hasBindingPlace(variable)) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            if (auto function_ = fieldPlace.address in nativeFunctionPointerSlots)
                                return ExpressionResult.functionPointerValue(*function_);
                        }

            // `handlers[i].action`: a Tdelegate-typed field of a struct
            // ARRAY element. `AggregateValue.elementAt`'s `readValue` copies
            // the element's bytes into a fresh native snapshot with its own
            // (unregistered) address -- the same gap `nativeDelegateSlots`'s
            // own field comment documents -- so any live entry has to be
            // looked up against the array's own backing-storage address
            // (`runArrayAppendAssignExpression`'s own relocation keeps that
            // registration current across an append), not the copy's.
            // `runIndexExpression`'s own `out arrayIndex` overload resolves
            // the index (bounds check, `$` binding, everything) exactly once.
            import dmd.astenums: TY;

            if (field.type.toBasetype.ty == TY.Tdelegate)
                if (auto index = dot.e1.isIndexExp)
                    if (auto var = index.e1.isVarExp)
                        if (auto variable = var.var.isVarDeclaration) {
                            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                            import quickbite.backends.interpreter.place: Place;

                            size_t elementIndex;
                            const elementValue = runIndexExpression(index, elementIndex);
                            const current = readBindingValue(variable);
                            if (current.isNativeAggregate) {
                                    auto elementType =
                                        AggregateValue.native(current).type.toBasetype.nextOf;
                                    if (elementType !is null) {
                                        auto fieldPlace = Place(
                                            AggregateValue.elementAddress(current, elementIndex),
                                            elementType,
                                        ).field(field);
                                        if (auto delegate_ = fieldPlace.address in nativeDelegateSlots)
                                            return delegateSlotResult(*delegate_);
                                    }
                                }
                            return readStoredValue(AggregateValue.fieldAt(
                                AggregateValue.native(elementValue), structFieldIndex(dot),
                            ));
                        }
        }

        if (isSyntheticClassInfoMember(dot))
            return runClassInfoExpression(dot);

        if (declarationName(dot.var) == "name")
            if (auto typeid_ = dot.e1.isTypeidExp)
                return characterArrayValue(
                    this,
                    dot.type,
                    typeInfoName(typeidObjectType(typeid_)),
                );

        if (declarationName(dot.var) == "name")
            if (auto symbol = dot.e1.isSymOffExp)
                if (auto type = symbolOffsetTypeInfoType(symbol))
                    return characterArrayValue(this, dot.type, typeInfoName(type));

        if (isClassInfoNamePointerMember(dot))
            return runClassInfoNameOwnerExpression(dot.e1, dot.type);

        // `TypeInfo_Const.base`, the field `TypeInfo_Shared` inherits: the
        // TypeInfo the qualified type's own TypeInfo wraps.
        if (declarationName(dot.var) == "base")
            if (auto typeid_ = dot.e1.isTypeidExp)
                if (auto type = typeidObjectType(typeid_)) {
                    auto unqualified = unqualifiedTypeInfoType(type);
                    if (auto address = resolvedClassTypeInfoAddress(unqualified))
                        return ExpressionResult.pointerValue(cast(void*) address);
                    return ExpressionResult.typeName(typeInfoName(unqualified));
                }


        const receiver = constructedExpressionValue(dot.e1);
        if (receiver == ExpressionResult.null_)
            throw new Exception(text(
                "class `",
                receiverName(dot.e1),
                "` is `null` and cannot be dereferenced",
            ));

        if (
            receiver.isFunctionPointer &&
            receiver.functionPointerId in _executionState.delegates
        )
            return delegateProperty(receiver, declarationName(dot.var));

        if (receiver.isTypeName && declarationName(dot.var) == "name")
            return characterArrayValue(this, dot.type, receiver.asTypeNameString);

        // `ClassInfo.m_flags`: the class-level facts a collector consults,
        // chief among them whether the object body holds any indirection and
        // so needs scanning.
        if (receiver.isTypeName && declarationName(dot.var) == "m_flags")
            return classInfoFlags(receiver.asTypeNameString);

        // Native dynamic arrays own their length in typed guest storage.
        // `TypeAArray.dotExp` (typesem.d) always lowers `aa.length` to a
        // call to `object._d_aaLen!(K, V)(aa)` at semantic time, so an
        // associative-array receiver never reaches this property lookup.
        if (
            receiver.isNativeAggregate &&
            AggregateValue.isArray(receiver) &&
            declarationName(dot.var) == "length"
        )
            return ExpressionResult(AggregateValue.length(AggregateValue.native(receiver)));

        if (dot.var.isVarDeclaration !is null) {
            const target = receiver.isNativeAggregate && dot.e1.type.toBasetype.isTypeClass !is null
                ? ExpressionResult.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                : receiver;
            if (target.isPointer && dot.e1.type.toBasetype.isTypeClass !is null) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                auto bodyAddress = target.pointerAddress;
                auto bodyType = dot.e1.type;
                if (auto metadata = target.pointerAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = (*metadata).type;
                }
                auto fieldPlace = Place(bodyAddress, bodyType)
                    .field(dot.var.isVarDeclaration);
                if (fieldPlace.type.isTypeClass !is null) {
                    const value = readStoredValue(fieldPlace);
                    if (value.isPointer)
                        if (auto object = value.pointerAddress in nativeClassOwners)
                            return ExpressionResult.nativeAggregateValue(*object);
                    return value;
                }
                // A live delegate value has no native ABI function address
                // (the same gap `nativeDelegateSlots`'s own field comment
                // documents), so it lives out-of-band, keyed by the field's
                // own address, exactly as the struct-field read arm below
                // already checks. A class field's address is always in the
                // object body's own storage.
                if (fieldPlace.type.toBasetype.ty == TY.Tdelegate)
                    if (auto delegate_ = fieldPlace.address in nativeDelegateSlots)
                        return delegateSlotResult(*delegate_);
                return readValue(fieldPlace);
            }
            if (target.isNativeAggregate) {
                import dmd.astenums: TY;

                auto field = dot.var.isVarDeclaration;
                if (auto variableExpression = dot.e1.isVarExp)
                    if (auto variable = variableExpression.var.isVarDeclaration)
                    if (hasBindingPlace(variable)) {
                        auto bindingFieldPlace = bindingPlace(variable)
                            .field(field);
                        if (field.type.toBasetype.ty == TY.Tdelegate)
                            if (auto delegate_ = bindingFieldPlace.address in nativeDelegateSlots)
                                return delegateSlotResult(*delegate_);
                    }
            }
            return readStoredValue(AggregateValue.fieldAt(
                AggregateValue.native(target), structFieldIndex(dot),
            ));
        }

        throw new Exception("Unsupported interpreter field read.");
    }

    private ExpressionResult classInfoFlags(in string className) {
        auto class_ = classDeclarationByQualifiedName(className);
        if (class_ is null)
            throw new Exception("Unsupported interpreter TypeInfo flags.");

        return ExpressionResult(classFlagsWord(class_));
    }

    private ExpressionResult typeInfoClassInitializer(
        in string className,
        imported!"dmd.mtype".Type resultType,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto class_ = classDeclarationByQualifiedName(className);
        if (class_ is null)
            throw new Exception("Unsupported interpreter TypeInfo initializer.");

        auto object = AggregateValue.allocateClass(class_.type);
        initializeNativeClassBody(this, class_.type, object);
        return ExpressionResult.nativeAggregateValue(
            AggregateValue.classBodyByteSlice(object, resultType),
        );
    }

    private NativeArray classSliceField(
        ref NativeBlock cell,
        imported!"dmd.dclass".ClassDeclaration class_,
        in size_t fieldIndex,
    ) {
        import quickbite.backends.interpreter.layout:
            classFields, fieldByteOffset;
        import quickbite.backends.interpreter.native_array:
            readSliceHeaderBytes;

        auto field = classFields(class_)[fieldIndex];
        auto arrayType = field.type.toBasetype.isTypeDArray;
        const offset = fieldByteOffset(field);
        auto header = readSliceHeaderBytes(
            cell.bytes[offset .. offset + NativeArray.sliceHeaderByteLength],
        );
        return NativeArray.borrow(arrayType.next, header.ptr, header.length);
    }

    private ExpressionResult runClassInfoExpression(
        imported!"dmd.expression".DotVarExp classInfo,
    ) {
        if (classInfo.e1.isTypeExp is null) {
            const receiver = runExpressionValue(classInfo.e1);
            if (dynamicClass(receiver) !is null)
                return ExpressionResult.typeName(dynamicClassName(receiver));
        }

        if (auto address = resolvedClassTypeInfoAddress(classInfo.e1.type))
            return ExpressionResult.pointerValue(cast(void*) address);

        return ExpressionResult.typeName(typeInfoName(classInfo.e1.type));
    }

    private ExpressionResult runClassInfoNameOwnerExpression(
        imported!"dmd.expression".Expression ownerExpression,
        imported!"dmd.mtype".Type resultType,
    ) {
        auto owner = classInfoNameOwnerExpression(ownerExpression);
        const receiver = runExpressionValue(owner);
        if (dynamicClass(receiver) !is null)
            return characterArrayValue(this, resultType, dynamicClassName(receiver));

        // A native class reference is its body pointer. Its static class type
        // still supplies the ClassInfo name needed by this interpreter-only
        // property path; the pointer remains the storage authority.
        if (receiver.isPointer && owner.type.toBasetype.isTypeClass !is null)
            if (auto dynamicType = receiver.pointerAddress in nativeClassTypes)
                return characterArrayValue(this, resultType, typeInfoName(*dynamicType));

        throw new Exception("Unsupported interpreter field read.");
    }

    private imported!"dmd.expression".Expression classInfoNameOwnerExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto pointer = expression.isPtrExp)
            return classInfoNameOwnerExpression(pointer.e1);

        return expression;
    }

    private ExpressionResult runDotIdentifierExpression(
        imported!"dmd.expression".DotIdExp dot,
    ) {
        const receiver = constructedExpressionValue(dot.e1);
        const name = dot.ident is null ? "" : dot.ident.toString;
        if (name == "re")
            return receiver.complexRealPart;
        if (name == "im")
            return receiver.complexImaginaryPart;

        throw new Exception("Unsupported interpreter property read.");
    }

    private ExpressionResult delegateProperty(
        in ExpressionResult receiver,
        scope const(char)[] name,
    ) {
        const slot = delegateSlotValue(receiver);
        auto runtime = slot.functionPointerId in _executionState.delegates;
        if (runtime is null)
            throw new Exception("Unsupported interpreter field read.");

        if (name == "ptr")
            return ExpressionResult.pointerValue(runtime.contextPointer);

        if (name == "funcptr")
            return ExpressionResult.functionPointerValue(runtime.functionPointerId);

        throw new Exception("Unsupported interpreter field read.");
    }

    private ExpressionResult runTypeidExpression(
        imported!"dmd.expression".TypeidExp typeid_,
    ) {
        import dmd.dtemplate: isExpression;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.messages: isClassExpression, receiverName;
        import std.conv: text;

        auto expression = isExpression(typeid_.obj);
        if (expression is null) {
            auto type = cast(Type) typeid_.obj;
            if (type is null)
                throw new Exception("Unsupported interpreter typeid expression.");

            return typeidValue(typeid_, type, typeInfoName(type));
        }

        auto value = runExpressionValue(expression);
        if (isClassExpression(expression))
            value = rootedNativeClassValue(expression, value);
        if (value == ExpressionResult.null_ || (isClassExpression(expression) &&
            value == ExpressionResult(false)))
            throw new Exception(text(
                "null pointer dereference evaluating typeid. `",
                receiverName(expression),
                "` is `null`",
            ));

        // A dynamic class the interpreter tracks is guest-only by
        // construction (`dynamicClass` only ever resolves an
        // interpreter-allocated object), so it has no host symbol to
        // recover; only the static-type fallback below can name a real one.
        if (dynamicClass(value) !is null)
            return typeidValue(typeid_, null, dynamicClassName(value));

        return typeidValue(typeid_, expression.type, typeInfoName(expression.type));
    }

    // A real host `TypeInfo_Class` symbol for `resolvedType` takes priority
    // over the symbolic display-name path, exactly as `runClassInfoExpression`
    // resolves `.classinfo`; `resolvedType` is null wherever the caller has
    // already answered from interpreter-tracked dynamic-class identity.
    private ExpressionResult typeidValue(
        imported!"dmd.expression".TypeidExp typeid_,
        imported!"dmd.mtype".Type resolvedType,
        in string name,
    ) {
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        if (isCharacterArrayType(typeid_.type))
            return characterArrayValue(this, typeid_.type, name);

        if (auto address = resolvedClassTypeInfoAddress(resolvedType))
            return ExpressionResult.pointerValue(cast(void*) address);

        return ExpressionResult.typeName(name);
    }

    private ExpressionResult runVectorExpression(
        imported!"dmd.expression".VectorExp vector,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: staticArrayLength;
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;

        auto staticArray = vector.to.basetype.toBasetype.isTypeSArray;
        if (staticArray is null)
            throw new Exception("Unsupported interpreter vector expression.");

        const value = constructedExpressionValue(vector.e1);
        const length = staticArrayLength(staticArray);

        ExpressionResult[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        const array = reconstructStoredArray(vector.to.basetype, elements);
        auto native = AggregateValue.native(array);
        return ExpressionResult.nativeAggregateValue(NativeAggregate(
            vector.type,
            native.storage,
            native.retained,
        ));
    }

    private ExpressionResult runVectorArrayExpression(
        imported!"dmd.expression".VectorArrayExp vectorArray,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;

        const vector = constructedExpressionValue(vectorArray.e1);
        auto native = AggregateValue.native(vector);
        return ExpressionResult.nativeAggregateValue(NativeAggregate(
            vectorArray.type,
            native.storage,
            native.retained,
        ));
    }

    private ExpressionResult runAssignExpression(imported!"dmd.expression".BinExp assign) {
        if (auto index = assign.e1.isIndexExp)
            return runIndexAssignExpression(index, assign.e2);

        if (auto call = assign.e1.isCallExp)
            if (
                call.f !is null &&
                returnsRef(call.f) &&
                hasTypedTemporaryRhs(assign.e2)
            ) {
                import dmd.tokens: EXP;
                import quickbite.backends.interpreter.place: Place;

                const address = refReturningCallAddress(call, EXP.address);
                if (!address.isPointer)
                    throw new Exception("Ref-returning call has no native address.");
                auto destination = Place(address.pointerAddress, assign.e1.type);
                return assignThroughTypedTemporary(destination, assign.e2);
            }

        if (auto pointer = assign.e1.isPtrExp)
            if (
                isRewrittenAssociativeArrayAssignment(pointer) &&
                hasTypedTemporaryRhs(assign.e2)
            )
                return runRewrittenAssociativeArrayAssignment(pointer, assign.e2);

        if (auto pointer = assign.e1.isPtrExp)
            if (hasTypedTemporaryRhs(assign.e2)) {
            import quickbite.backends.interpreter.place: Place;

            const address = pointerOperandPlace(pointer.e1).deref.address;
            if (address !is null) {
                auto destination = Place(cast(void*) address, assign.e1.type);
                const value = assignThroughTypedTemporary(destination, assign.e2);
                clearUninitializedBindingAddress(cast(void*) address);
                return value;
            }
        }

        if (auto dot = assign.e1.isDotVarExp)
            if (isDirectProjectionWriteTarget(dot))
                return runProjectionAssignExpression(dot, assign.e2);

        if (auto slice = assign.e1.isSliceExp)
            return runSliceAssignExpression(slice, assign.e2);

        // A plain binding (or a representation-preserving cast of one) is a
        // live typed place too. Resolve it before constructing the RHS, then
        // let the projection assignment path construct into fresh temporary
        // storage and copy the complete value into that already-selected
        // place. Class bindings retain the existing path: their native slot
        // is only a body pointer and the value path also carries its owning
        // aggregate.
        if (
            isDirectProjectionWriteTarget(assign.e1) &&
            assign.e1.type.toBasetype.isTypeClass is null
        )
            return runProjectionAssignExpression(assign.e1, assign.e2);

        // dmd's semantic3 merges a synthesized `BlitExp(VarExp(param), 0)`
        // into a function's own body for every `out` parameter of a
        // zero-init struct type (the literal's `.type` is retyped to the
        // struct type as a "memset" marker; semantic3.d's own comment:
        // "Must do same check in interpreter"). This exact shape is already
        // special-cased for a plain local declaration in
        // `runDeclarationExpression` (`isBlitExp` with an `IntegerExp` e2),
        // materializing the struct's real default value instead of writing
        // the literal through naively -- but a synthesized out-parameter
        // initializer is a bare top-level assignment, not wrapped in a
        // `DeclarationExp`, so it never reached that check and instead fell
        // through to `runExpressionValue(assign.e2)` below, which evaluated the
        // `IntegerExp` as a scalar `ExpressionResult(0)` and tried to clobber the
        // parameter's native struct value with a bare int.
        //
        // The identical synthesized zero-init blit precedes a whole-struct
        // -typed FIELD's constructor call too (e.g. `core.internal.lifetime.
        // emplaceRef`'s generated wrapper `this.payload = T(args)`, lowered
        // to a zero-init blit of `this.payload` followed by its `__ctor`
        // call): `assign.e1` is then a `DotVarExp`, not a `VarExp`, so it
        // needs the same default-value materialization rather than writing
        // the raw `0` literal into the field's native struct storage.
        if (auto blit = assign.isBlitExp) {
            import quickbite.frontend.dmd.types: isStructType;

            if (blit.e2.isIntegerExp !is null && isStructType(assign.e1.type)) {
                if (auto var = assign.e1.isVarExp)
                    if (auto variable = var.var.isVarDeclaration) {
                        const value = defaultValueResult(variable.type);
                        writeLocation(assign.e1, value);
                        return value;
                    }
                if (assign.e1.isDotVarExp !is null) {
                    const value = defaultValueResult(assign.e1.type);
                    writeLocation(assign.e1, value);
                    return value;
                }
            }
        }

        // A struct or static-array binding is a live typed place too, but
        // `isDirectProjectionWriteTarget` refuses a struct/static-array
        // target above, so a whole-aggregate `VarExp` assignment never
        // reaches `runProjectionAssignExpression`. Resolve it the same way:
        // construct the RHS into a fresh temporary, then copy or convert
        // that complete value into the binding's own place. Class bindings
        // stay on the carrier path below for the same reason as the
        // projection check above.
        if (auto target = assign.e1.isVarExp)
            if (auto variable = target.var.isVarDeclaration)
                if (
                    variable.type.toBasetype.isTypeClass is null &&
                    hasBindingPlace(variable)
                ) {
                    auto destination = bindingPlace(variable);
                    if (canAssignThroughTypedTemporary(destination, assign.e2)) {
                        const value = assignThroughTypedTemporary(destination, assign.e2);
                        clearUninitializedBindingAddress(destination.address);
                        return value;
                    }
                }

        // A fresh closure RHS (`c.f = (int x) => x + captured;`) is a bare
        // `FuncExp`; construct its callable before writing the destination.
        auto literal = assign.e2.isFuncExp;
        auto value = literal is null
            ? constructedExpressionValue(assign.e2)
            : runFunctionLiteralDeclaration(literal);
        if (auto target = assign.e1.isVarExp)
            if (auto variable = target.var.isVarDeclaration)
                if (variable.type.toBasetype.isTypeClass !is null)
                    value = rootedNativeClassValue(assign.e2, value);
        writeLocation(assign.e1, value);

        // Plain-variable assignments are bindings just like declaration
        // initializers: propagate storage-backed views and reference aliases
        // after `writeLocation` has dropped the target's previous binding.
        if (auto var = assign.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration) {
            }

        return value;
    }

    // DMD lowers a modifiable `aa[key]` to `*(_d_aaGetY(...))`.  Evaluating
    // that call first lets interpreted druntime autovivify the live handle
    // and select its entry before construction starts in separate storage.
    private bool isRewrittenAssociativeArrayAssignment(
        imported!"dmd.expression".PtrExp pointer,
    ) {
        auto call = pointer.e1.isCallExp;
        return call !is null &&
            call.f !is null &&
            call.f.ident !is null &&
            call.f.ident.toString == "_d_aaGetY";
    }

    private ExpressionResult runRewrittenAssociativeArrayAssignment(
        imported!"dmd.expression".PtrExp pointer,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.place: Place;

        const address = pointerOperandPlace(pointer.e1).deref.address;
        if (address is null)
            throw new Exception("Associative-array entry has no native address.");

        const value = assignThroughTypedTemporary(
            Place(cast(void*) address, pointer.type),
            rhs,
        );
        clearUninitializedBindingAddress(cast(void*) address);
        return value;
    }

    private ExpressionResult runProjectionAssignExpression(
        imported!"dmd.expression".Expression target,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto destination = directWriteProjectionPlace(target);

        // An assignment first evaluates its live place, then completes the
        // RHS in separate fresh storage. Only the complete typed value moves
        // into the live place. DMD has already made any required conversion,
        // postblit, or destructor action explicit around this assignment, so
        // this is the ordinary representation-preserving move itself.
        // A direct `DotVarExp` has already composed its live field place
        // above. Struct and static-array fields do not enter this path, so
        // their DMD-lowered postblit and chained-method handling is unchanged.
        if (
            canAssignThroughTypedTemporary(destination, rhs)
        ) {
            const value = assignThroughTypedTemporary(destination, rhs);
            clearProjectionRootUninitialized(target);
            return value;
        }

        // Mutable because function literal construction expects DMD's
        // mutable AST node even though this helper does not modify it.
        auto literal = rhs.isFuncExp;
        const value = literal is null
            ? constructedExpressionValue(rhs)
            : runFunctionLiteralDeclaration(literal);
        writeStoredValue(
            destination,
            storageValue(target.type, value),
        );
        clearProjectionRootUninitialized(target);
        return value;
    }

    // Item 9: resolve the assignment's live place before its RHS, then build
    // that RHS in separate fresh typed storage. The typed copy or conversion
    // is the only write to the live place, so aliases cannot observe
    // construction. DMD keeps any postblit, destructor, or move lowering in
    // `rhs`; this helper only stores that complete result.
    private bool canAssignThroughTypedTemporary(
        imported!"quickbite.backends.interpreter.place".Place destination,
        imported!"dmd.expression".Expression rhs,
    ) {
        return destination.type !is null && hasTypedTemporaryRhs(rhs);
    }

    private bool hasTypedTemporaryRhs(
        imported!"dmd.expression".Expression rhs,
    ) {
        return rhs !is null && rhs.type !is null && rhs.isFuncExp is null;
    }

    private bool sameAssignmentType(
        imported!"dmd.mtype".Type targetType,
        imported!"dmd.expression".Expression rhs,
    ) {
        return targetType !is null &&
            rhs.type !is null &&
            targetType.toBasetype.equals(rhs.type.toBasetype);
    }

    private bool sameAssignmentType(
        imported!"dmd.expression".Expression target,
        imported!"dmd.expression".Expression rhs,
    ) {
        return target !is null && sameAssignmentType(target.type, rhs);
    }

    private ExpressionResult assignThroughTypedTemporary(
        imported!"quickbite.backends.interpreter.place".Place destination,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.place: Place;

        assert(canAssignThroughTypedTemporary(destination, rhs));
        auto temporary = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(rhs),
            rhs.type,
        ));
        runExpression(rhs, temporary);
        const value = readStoredValue(temporary.place);
        if (sameAssignmentType(destination.type, rhs))
            copyPlaceValue(temporary.place, destination);
        else
            writeStoredValue(destination, storageValue(destination.type, value));
        return value;
    }

    private void writeLocation(
        imported!"dmd.expression".Expression target,
        in ExpressionResult value,
        in bool arrayRefWriteback = false,
    ) {
        if (auto cast_ = target.isCastExp) {
            writeLocation(cast_.e1, value, arrayRefWriteback);
            return;
        }

        if (auto var = target.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported interpreter assignment target.");
            storeBinding(
                variable,
                storageValue(variable.type, value),
            );

            return;
        }

        if (target.isThisExp !is null && hasThis) {
            // A whole-`this` rebind (e.g. the compiler-generated identity
            // `opAssign`'s `this = p;`, invoked to finish a postblit-typed
            // struct's `s = t;`) must write through the borrowed native
            // address `runMemberFunction` aliased `this` to, not replace
            // `thisValue` with a disconnected copy -- that would silently
            // drop the mutation the caller's own storage was supposed to
            // observe.
            if (thisAddress !is null) {
                import quickbite.backends.interpreter.place: Place;

                const stored = storageValue(target.type, value);
                writeStoredValue(Place(thisAddress, target.type), stored);
                // The written place is thisAddress itself for a struct
                // receiver, but the class receiver's own body address for
                // a class one -- `thisAddress` there is the *slot* the
                // reference was just written into, one indirection short of
                // `bindClassReceiver`'s own body-address invariant.
                thisValue = target.type.toBasetype.isTypeStruct !is null
                    ? Place(thisAddress, target.type)
                    : Place(stored.pointerAddress, target.type);
                return;
            }
            thisValue = receiverPlaceFrom(value, target.type);
            return;
        }

        if (target.isSuperExp !is null && hasThis) {
            thisValue = receiverPlaceFrom(value, target.type);
            return;
        }

        if (auto dot = target.isDotVarExp) {
            if (isDirectProjectionWriteTarget(dot)) {
                writeProjectionPlace(dot, value);
                return;
            }

            // A `this`/`super`-rooted receiver chain (`this.field = v`, or a
            // deeper `this.inner.field = v`) is bound to this activation's
            // own receiver storage for its whole lifetime -- `projectionPlace`
            // composes that chain's live address the same way it composes a
            // true local's own storage (`hasProjectionPlace`'s `ThisExp`/
            // `SuperExp` base case). The direct-write predicate pair
            // deliberately has no base case of its own for an unindexed
            // whole-field write, so compose the field's place directly here
            // instead of reading a snapshot and writing it back through this
            // function's own recursion below.
            if (isThisRootedProjection(dot.e1) && hasProjectionPlace(dot.e1)) {
                writeStoredValue(
                    projectionPlace(dot),
                    storageValue(target.type, value),
                );
                clearProjectionRootUninitialized(dot);
                return;
            }

            // A ref-returning call's receiver (`f().field = v` where `f`
            // returns `ref S`) names a live struct lvalue, not a temporary --
            // the same lvalue `writeIndexLocation`/`runIndexAssignExpression`'s
            // sibling `index.e1.isCallExp` arms already resolve through
            // `refReturningCallAddress` for the index-is-call shape. A class
            // receiver keeps the existing native-object path below (it also
            // performs dynamic-object metadata handling this arm does not
            // replace).
            if (auto call = dot.e1.isCallExp)
                if (
                    call.f !is null &&
                    returnsRef(call.f) &&
                    dot.e1.type.toBasetype.isTypeStruct !is null
                ) {
                    import dmd.tokens: EXP;
                    import quickbite.backends.interpreter.place: Place;

                    const address = refReturningCallAddress(call, EXP.address);
                    if (address.isPointer) {
                        writeStoredValue(
                            Place(address.pointerAddress, dot.e1.type)
                                .field(dot.var.isVarDeclaration),
                            storageValue(target.type, value),
                        );
                        return;
                    }
                }

            const receiver = runExpressionValue(dot.e1);
            if (receiver.isNativeAggregate) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.aggregate_value: AggregateValue;

                auto field = dot.var.isVarDeclaration;
                if (
                    field !is null &&
                    field.type.toBasetype.isTypeClass !is null &&
                    value.isTypeName
                ) {
                    const fieldIndex = structFieldIndex(dot);
                    auto updated = withStoredStructField(
                        receiver,
                        dot.e1.type,
                        fieldIndex,
                        value,
                    );
                    writeLocation(dot.e1, updated);
                    return;
                }
                // Both symbolic-field arms below hand the field's own place
                // straight to `writeStoredValue` (rather than registering the
                // out-of-band table entry here directly) so a stale entry left
                // by a union sibling at this same address is cleared first --
                // `writeStoredValue`'s own Tdelegate/function-pointer arms do
                // exactly this clear-then-register-then-zero sequence.
                if (field !is null && field.type.toBasetype.ty == TY.Tdelegate) {
                    if (auto variableExpression = dot.e1.isVarExp)
                        if (auto variable = variableExpression.var.isVarDeclaration)
                        if (hasBindingPlace(variable)) {
                            writeStoredValue(bindingPlace(variable).field(field), value);
                            return;
                        }
                }
                auto pointerType = field is null
                    ? null
                    : field.type.toBasetype.isTypePointer;
                if (
                    pointerType !is null &&
                    pointerType.nextOf.toBasetype.isTypeFunction !is null &&
                    value.isFunctionPointer
                ) {
                    if (auto variableExpression = dot.e1.isVarExp)
                        if (auto variable = variableExpression.var.isVarDeclaration)
                        if (hasBindingPlace(variable)) {
                            writeStoredValue(bindingPlace(variable).field(field), value);
                            return;
                        }
                }
            }
            const nativeClassReceiver = receiver.isPointer
                ? receiver
                : receiver.isNativeAggregate && dot.e1.type.toBasetype.isTypeClass !is null
                ? ExpressionResult.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                : ExpressionResult.null_;
            if (
                nativeClassReceiver.isPointer &&
                dot.e1.type.toBasetype.isTypeClass !is null
            ) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.place: Place;

                auto field = dot.var.isVarDeclaration;
                auto bodyAddress = nativeClassReceiver.pointerAddress;
                auto bodyType = dot.e1.type;
                if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = (*metadata).type;
                }
                auto fieldPlace = Place(bodyAddress, bodyType)
                    .field(field);
                // A live delegate value (an interpreted closure, not `null`)
                // has no native ABI function address, so `place_value.
                // writeValue`'s Tdelegate arm only ever accepts `null`.
                // `writeStoredValue` registers it out-of-band in
                // `nativeDelegateSlots`, keyed by the field's own address,
                // clearing any stale entry a union sibling left there first.
                // A class field's address is the object body's own storage,
                // live for the object's whole lifetime.
                writeStoredValue(fieldPlace, value);
                return;
            }

            // A dynamic-array header can be reinterpreted as a two-field
            // struct through a pointer.  DMD's own __ArrayCast does this to
            // change the header length while retaining the data pointer.
            // The expression carrier remains an array because those are the
            // bytes' actual guest meaning; update its descriptor rather than
            // reconstructing a field-by-field struct snapshot.
            if (
                receiver.isNativeAggregate &&
                AggregateValue.isArray(receiver) &&
                declarationName(dot.var) == "length"
            ) {
                writeLocation(
                    dot.e1,
                    ExpressionResult.nativeAggregateValue(
                        AggregateValue.borrowArrayOwner(
                            dot.e1.type,
                            cast(size_t) value.asLong,
                            AggregateValue.nativeArrayAddress(receiver),
                        ),
                    ),
                );
                return;
            }

            // Whatever remains here has no addressable place this activation
            // can compose in place: a plain (non-ref) call result or a
            // literal receiver is a genuine rvalue -- DMD itself makes
            // `f().field = v` a compile error for a non-ref `f` returning a
            // struct by value, so this shape is reachable only through an
            // already-lowered AST, not user-written code with observable
            // aliasing to preserve. A captured-variable receiver has live
            // storage but no static predicate resolves it yet (the frame/
            // dataseg-scoped `hasBindingPlace` does not see a closure's
            // cross-activation captures) -- separate follow-on work.
            // A whole-struct-typed target through a `VarExp`-rooted receiver
            // (`local.inner = v`) also lands here even though `local` itself
            // has a place: `isDirectProjectionWriteTarget` excludes
            // struct/static-array-typed targets outright, and reworking that
            // exclusion is a separate change from wiring up the two
            // previously-unaddressable receiver shapes above.
            const fieldIndex = structFieldIndex(dot);
            auto unionType = receiverStructType(dot.e1);
            const updated = unionType !is null && unionType.sym.isUnionDeclaration !is null
                ? withUnionFieldWrite(receiver, unionType, fieldIndex, value)
                : withStoredStructField(
                    receiver,
                    dot.e1.type,
                    fieldIndex,
                    value,
                );
            writeLocation(dot.e1, updated);
            return;
        }

        if (auto index = target.isIndexExp) {
            writeIndexLocation(index, value);
            return;
        }

        if (auto call = target.isCallExp)
            if (writeRefReturningCallLocation(call, value))
                return;

        // `arr.length = n`: resize the array lvalue, padding with default
        // elements when growing and truncating when shrinking, then write the
        // rebuilt array back to its location (a local, or a field through a
        // pointer as in `_data.arr.length = n`).
        if (auto arrayLength = target.isArrayLengthExp) {
            writeArrayLengthLocation(arrayLength, value);
            return;
        }

        // `*ptr = value`: update the pointer variable so its target holds value.
        if (auto ptr = target.isPtrExp) {
            const address = pointerOperandPlace(ptr.e1).deref.address;
            // A dereferenced native pointer (e.g. a malloc'd struct like
            // std.stdio.File's Impl): write straight into native memory.
            if (address !is null) {
                storeNativePointerElement(
                    ptr.e1.type,
                    ExpressionResult.pointerValue(cast(void*) address),
                    0,
                    value,
                );
                return;
            }

            throw new Exception("Unsupported non-native data pointer.");
        }

        import std.conv: text;
        throw new Exception(
            text("Unsupported interpreter assignment target: ", target.op),
        );
    }

    // Whether `expression`'s receiver chain terminates at a bare
    // `this`/`super`, as opposed to a true local/dataseg binding
    // (`VarExp`) or an addressable symbol base -- `hasProjectionPlace`
    // accepts both roots, but only a `this`/`super` root identifies the
    // shape `writeLocation`'s `DotVarExp` arm wires directly through
    // `projectionPlace` here; a `VarExp`-rooted struct-typed target keeps
    // its existing path unchanged.
    private bool isThisRootedProjection(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression is null)
            return false;
        if (expression.isThisExp !is null || expression.isSuperExp !is null)
            return true;
        if (auto dot = expression.isDotVarExp)
            return isThisRootedProjection(dot.e1);
        if (auto cast_ = expression.isCastExp)
            return isThisRootedProjection(cast_.e1);
        return false;
    }

    // Assignment through a ref-returning call (`f(i) = v`, `obj.slot() = v`):
    // run the callee for real — pre-return side effects happen exactly once —
    // and at the executed return statement write the value through the
    // returned lvalue (`assignToRefReturn` mode, the assignment counterpart
    // of `addressOfRefReturn`).
    private bool writeRefReturningCallLocation(
        imported!"dmd.expression".CallExp call,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
        import quickbite.frontend.dmd.functions:
            ensureFunctionBodySemantic, hasNoInterpretableSource;

        if (call.f is null || !returnsRef(call.f))
            return false;

        auto dot = call.e1.isDotVarExp;
        if (dot is null)
            return writeFreeRefReturningCallLocation(call, value);

        ExpressionResult receiverAddress;
        ExpressionResult receiver;
        resolveMemberCallReceiver(dot.e1, receiverAddress, receiver);
        if (receiver == ExpressionResult.null_)
            throw new Exception("function call through null class reference `null`");

        auto function_ = resolveMemberFunction(call.f, receiver);
        ensureFunctionBodySemantic(function_);

        auto callArguments = CallArguments(
            call.arguments is null ? 0 : call.arguments.length,
        );
        scope(exit) callArguments.release;
        auto arguments = callArguments.values;
        auto argumentExpressions = callArguments.expressions;
        auto evaluatedArguments = callArguments.references;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments[index] = index < function_.parameters.length &&
                    isReferenceParameter(
                        function_,
                        index,
                        (*function_.parameters)[index],
                    )
                    ? runRefArgumentExpression(argument, evaluated, false)
                    : constructedExpressionValue(argument);
                if (
                    index < function_.parameters.length &&
                    (*function_.parameters)[index].type.toBasetype.isTypeClass !is null
                )
                    arguments[index] =
                        rootedNativeClassValue(argument, arguments[index]);
                argumentExpressions[index] = argument;
                evaluatedArguments[index] = evaluated;
            }

        if (hasNoInterpretableSource(function_)) {
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;
            import quickbite.backends.interpreter.place: Place;

            imported!"dmd.mtype".Type receiverType = receiverClassType(dot.e1);
            if (receiverType is null)
                receiverType = receiverStructType(dot.e1);

            try {
                NativeCallResult nativeResult;
                if (!invokeNativeDeclaration(
                    function_,
                    receiver,
                    receiverType,
                    dot.e1,
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                    false,
                    nativeResult,
                ))
                    return false;
                auto returnType = function_.type.toBasetype.isTypeFunction
                    .next.toBasetype;
                writeStoredValue(
                    Place(nativeResult.value.address, returnType),
                    value,
                );
                return true;
            } catch (NativeCallException exception) {
                throwNativeException(exception);
            }
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.assignToRefReturn = true;
        child.refReturnAssignedValue = value;
        forkExecutionStateInto(child);
        scope(exit) child.retireActivationFrameMetadata;
        bindCapturedReferenceSlots(function_, child);
        child.thisValue = receiverPlaceFrom(
            receiver,
            function_.vthis is null ? null : function_.vthis.type,
        );
        child.hasThis = true;
        child.bindThisReferenceAddress(function_, child.thisValue);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );
        aliasThisToReceiverStorage(child, function_, receiverAddress);

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            mergeMemberFunctionState(
                function_,
                dot.e1,
                argumentExpressions,
                child,
                arguments,
            );
            throw exception;
        }
        mergeMemberFunctionState(
            function_,
            dot.e1,
            argumentExpressions,
            child,
            arguments,
        );
        return true;
    }

    private bool writeFreeRefReturningCallLocation(
        imported!"dmd.expression".CallExp call,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
        import quickbite.frontend.dmd.functions:
            ensureFunctionBodySemantic, hasNoAvailableSource,
            hasNoInterpretableSource;

        ensureFunctionBodySemantic(call.f);
        if (call.f.needThis)
            return false;
        const native = hasNoAvailableSource(call.f);

        auto callArguments = CallArguments(
            call.arguments is null ? 0 : call.arguments.length,
        );
        scope(exit) callArguments.release;
        auto arguments = callArguments.values;
        auto argumentExpressions = callArguments.expressions;
        auto evaluatedArguments = callArguments.references;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments[index] = index < call.f.parameters.length &&
                    isReferenceParameter(
                        call.f,
                        index,
                        (*call.f.parameters)[index],
                    )
                    ? runRefArgumentExpression(argument, evaluated, native)
                    : constructedExpressionValue(argument);
                argumentExpressions[index] = argument;
                evaluatedArguments[index] = evaluated;
            }

        if (hasNoInterpretableSource(call.f)) {
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;
            import quickbite.backends.interpreter.place: Place;

            try {
                NativeCallResult nativeResult;
                if (!invokeNativeDeclaration(
                    call.f,
                    ExpressionResult.void_,
                    null,
                    null,
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                    false,
                    nativeResult,
                ))
                    return false;
                auto returnType = call.f.type.toBasetype.isTypeFunction
                    .next.toBasetype;
                writeStoredValue(
                    Place(nativeResult.value.address, returnType),
                    value,
                );
                return true;
            } catch (NativeCallException exception) {
                throwNativeException(exception);
            }
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = call.f;
        auto layout = cachedFrameLayout(call.f);
        child._activationFrame = FrameBlock.allocate(layout);
        child.assignToRefReturn = true;
        child.refReturnAssignedValue = value;
        forkExecutionStateInto(child);
        scope(exit) child.retireActivationFrameMetadata;
        bindCapturedReferenceSlots(call.f, child);
        child.bindFunctionParameters(
            call.f,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );

        try {
            child.runStatement(call.f.fbody);
        } catch (InterpretedException exception) {
            mergeFunctionState(call.f, argumentExpressions, child, arguments);
            throw exception;
        }
        mergeFunctionState(call.f, argumentExpressions, child, arguments);
        return true;
    }

    private void writeArrayLengthLocation(
        imported!"dmd.expression".ArrayLengthExp target,
        in ExpressionResult value,
    ) {
        const current = constructedExpressionValue(target.e1);
        const newLength = cast(size_t) value.asLong;
        writeLocation(
            target.e1,
            resizedStoredArray(target.e1.type, current, newLength),
        );
    }

    private ExpressionResult resizedStoredArray(
        imported!"dmd.mtype".Type type,
        in ExpressionResult current,
        in size_t newLength,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: arrayElementType;

        ExpressionResult[] noElements;
        const source = current == ExpressionResult.null_
            ? reconstructStoredArray(type, noElements)
            : current;
        const oldLength = AggregateValue.length(AggregateValue.native(source));
        const previousData = AggregateValue.nativeArrayAddress(source);
        const resized = ExpressionResult.nativeAggregateValue(
            AggregateValue.withArrayLength(AggregateValue.native(source), newLength),
        );
        auto elementType = arrayElementType(type);
        relocatePriorAppendedElementSlots(
            elementType,
            previousData,
            resized,
            oldLength,
        );
        auto destination = Place(AggregateValue.native(resized).address, type);
        foreach (index; oldLength .. newLength)
            writeStoredValue(
                destination.index(index),
                runDefaultValue(elementType),
            );
        return resized;
    }

    private ExpressionResult runDefaultValue(imported!"dmd.mtype".Type type) {
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;

        return constructedExpressionValue(type.defaultInitLiteral(Loc.initial));
    }

    // A value-result caller has no final place yet. Build the D default in a
    // typed native owner, then cross the existing result boundary only when
    // this older expression path requires it.
    private ExpressionResult defaultValueResult(imported!"dmd.mtype".Type type) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto owner = defaultValueOwner(type);
        return readValue(Place(owner.address, type));
    }

    private ExpressionResult storageValue(
        imported!"dmd.mtype".Type type,
        in ExpressionResult value,
    ) {
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        if (type is null)
            return value;

        if (value.isTypeName && isCharacterArrayType(type))
            return characterArrayValue(this, type, value.asTypeNameString);

        // `void[]` denotes raw bytes, so coercing an aggregate to it is a
        // reinterpretation of that aggregate's own storage -- exactly what
        // `void[] bytes = someStruct;` and the allocator APIs that traffic in
        // `void[]` mean by it -- not a value conversion. There is no scalar
        // cast that could express it, so answer a byte view aliasing the
        // source instead of falling through to `backendCastValue`.
        if (value.isNativeAggregate) {
            import dmd.astenums: TY;

            auto array = type.toBasetype.isTypeDArray;
            auto source = AggregateValue.native(value).type.toBasetype;
            if (
                array !is null &&
                array.nextOf.toBasetype.ty == TY.Tvoid &&
                (
                    source.isTypeStruct !is null ||
                    source.isTypeSArray !is null
                )
            )
                return ExpressionResult.nativeAggregateValue(
                    AggregateValue.nativeAggregateByteSlice(
                        AggregateValue.native(value),
                        type,
                    ),
                );
        }

        return castScalarToType(type, value);
    }

    // `storageValue`'s scalar-cast fallback, factored out for callers whose
    // value is already known -- by construction, not by this type's runtime
    // tag -- to be a plain scalar or pointer: a compound-assignment or
    // increment/decrement result never carries a type-name or
    // native-aggregate tag (`compoundAssignedValue`/`incrementedValue` only
    // ever answer a numeric, complex, or pointer variant, or throw), so
    // those callers skip the two tag checks above and land here directly.
    private ExpressionResult castScalarToType(
        imported!"dmd.mtype".Type type,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.runtime_casts:
            CastTarget,
            tryCastTarget;

        if (type is null)
            return value;

        CastTarget target;
        if (!tryCastTarget(type, target))
            return value;

        return castScalarResult(value, target);
    }

    // Casts to the scalar's static type and writes through a typed place. This
    // module does not re-derive scalar width or bit layout.
    private ExpressionResult[] scalarBytes(
        imported!"dmd.mtype".Type type,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeScalarLeaf;

        auto raw = new ubyte[](typeByteSize(type));
        writeScalarLeaf(Place(raw.ptr, type), value);

        ExpressionResult[] bytes;
        foreach (byte_; raw)
            bytes ~= ExpressionResult(byte_);
        return bytes;
    }

    private ExpressionResult scalarWithByte(
        imported!"dmd.mtype".Type type,
        in ExpressionResult current,
        in size_t index,
        in ExpressionResult byte_,
    ) {
        import std.conv: text;

        auto bytes = scalarBytes(type, current);
        if (index >= bytes.length)
            throw new Exception(text("Scalar byte index out of bounds: ", index));

        bytes[index] = ExpressionResult(cast(ubyte) byte_.asLong);
        return scalarFromBytes(type, bytes);
    }

    // The inverse of `scalarBytes` above. `place_value.readScalarLeaf` keeps
    // this transitional ExpressionResult boundary outside `native_scalar`
    // while preserving the codec's `float`/`double` behaviour.
    private ExpressionResult scalarFromBytes(
        imported!"dmd.mtype".Type type,
        in ExpressionResult[] bytes,
    ) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readScalarLeaf;

        auto raw = new ubyte[](bytes.length);
        foreach (index, byte_; bytes)
            raw[index] = cast(ubyte) byte_.asLong;

        return readScalarLeaf(Place(raw.ptr, type));
    }

    private void writeIndexLocation(
        imported!"dmd.expression".IndexExp index,
        in ExpressionResult value,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        const arrayIndex = scalarOperand!size_t(index.e2);

        // DMD's own `modifiableLvalue` semantic reverts an associative-array
        // index used through a further field/method/element access (rather
        // than being the assignment's own direct target) to an rvalue read
        // through `_d_aaGetRvalueX` (`expressionsem.d`'s
        // `revertModifiableAAIndexReads`) -- a `Point* __aaget = ...; *(
        // __aaget ? __aaget : range-error)` shape whose outer node is a
        // plain pointer-dereference `IndexExp` (index 0), reached here when
        // `writeLocation`'s `DotVarExp` arm rebuilds the whole receiver
        // value and recurses back onto it. That pointer already names the
        // AA's own value-slot storage, so writing through it is the correct
        // (and only) place for this element, matching
        // `runIndexAssignExpression`'s identical pointer-index arm.
        if (auto call = index.e1.isCallExp) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.place: Place;

            const address = refReturningCallAddress(call, EXP.address);
            if (!address.isPointer)
                throw new Exception("Ref-returning call has no native address.");
            writeStoredValue(
                Place(address.pointerAddress, index.e1.type).index(arrayIndex),
                storageValue(index.type, value),
            );
            return;
        }

        if (isPointerType(index.e1.type)) {
            const address = pointerOperandPlace(index.e1).deref.address;
            if (address !is null) {
                storeNativePointerElement(
                    index.e1.type,
                    ExpressionResult.pointerValue(cast(void*) address),
                    arrayIndex,
                    value,
                );
                return;
            }
            throw new Exception("Pointer index assignment needs a native address.");
        }

        // `(*p)[i] = v`: `index.e1` is itself a dereference (`p`'s pointee
        // is the static array being indexed, e.g. `int[3]*`), not a
        // variable/field lvalue. `&(*p)` recovers `p`'s own address
        // (`addressOfExpression`'s identical `PtrExp` arm); index directly
        // into the pointee's bytes at that address rather than through a
        // binding.
        if (auto derefBase = index.e1.isPtrExp) {
            const address = pointerOperandPlace(derefBase.e1).deref.address;
            if (address !is null) {
                import quickbite.backends.interpreter.place: Place;

                writeStoredValue(
                    Place(cast(void*) address, index.e1.type).index(arrayIndex),
                    value,
                );
                return;
            }
            throw new Exception("Unsupported interpreter assignment target.");
        }

        // The compound-assignment (`arr[i].field[j][k] += value`) sibling of
        // `runNestedIndexAssignExpression`'s identical `DotVarExp` arm: `index.e1`
        // (`arr[i].field[j]`) is itself an `IndexExp` whose own `e1` is a
        // `DotVarExp`, not a `DotVarExp`/`VarExp` directly, so it fell through
        // both arms below. `value` here is already the compound-assignment's
        // computed result (`writeLocation`'s caller resolved it), so only the
        // write-back composition is needed, not an rhs evaluation.
        if (auto outer = index.e1.isIndexExp) {
            auto dot = outer.e1.isDotVarExp;
            if (dot is null)
                throw new Exception("Unsupported interpreter assignment target.");

            if (receiverClassType(dot.e1) !is null) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue, writeValue;

                const receiver = constructedExpressionValue(dot.e1);
                // A class local exposes its object-body pointer. Resolve the
                // field's `Place` directly through that pointer and write the
                // updated nested element back through it, mirroring this
                // function's singly-indexed `DotVarExp` class arm below.
                const nativeClassReceiver = receiver.isPointer
                    ? receiver
                    : receiver.isNativeAggregate
                    ? ExpressionResult.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                    : ExpressionResult.null_;
                if (!nativeClassReceiver.isPointer)
                    throw new Exception("Class field assignment needs a native address.");

                auto bodyAddress = nativeClassReceiver.pointerAddress;
                auto bodyType = dot.e1.type;
                if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = (*metadata).type;
                }
                auto fieldPlace = Place(bodyAddress, bodyType)
                    .field(dot.var.isVarDeclaration);
                const fieldValue = readValue(fieldPlace);
                const outerIndex = scalarOperand!size_t(outer.e2);
                checkStaticArrayIndexInBounds(fieldValue, outerIndex);
                const outerElement = readStoredValue(
                    AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
                );
                checkStaticArrayIndexInBounds(outerElement, arrayIndex);
                const updatedField = ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                    AggregateValue.native(fieldValue),
                    outerIndex,
                    ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                        AggregateValue.native(outerElement), arrayIndex, value,
                    )),
                ));
                writeValue(fieldPlace, updatedField);
                return;
            }

            // A `this`/`super`-rooted receiver chain (`this.arr[i][j] += v`,
            // or a deeper `this.inner.arr[i][j] += v`) is bound to this
            // activation's own receiver storage for its whole lifetime --
            // `projectionPlace` composes the field's live address the same
            // way `writeLocation`'s own `DotVarExp` arm does for an
            // unindexed field write.
            if (isThisRootedProjection(dot.e1) && hasProjectionPlace(dot.e1)) {
                import quickbite.backends.interpreter.place_value: readValue;

                auto fieldPlace = projectionPlace(dot);
                const fieldValue = readValue(fieldPlace);
                const outerIndex = scalarOperand!size_t(outer.e2);
                checkStaticArrayIndexInBounds(fieldValue, outerIndex);
                const outerElement = readStoredValue(
                    AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
                );
                checkStaticArrayIndexInBounds(outerElement, arrayIndex);
                writeStoredValue(
                    fieldPlace.index(outerIndex).index(arrayIndex),
                    storageValue(index.type, value),
                );
                clearProjectionRootUninitialized(index);
                return;
            }

            // A ref-returning call's receiver (`f().arr[i][j] += v` where
            // `f` returns `ref S`) names a live struct lvalue, not a
            // temporary -- the same lvalue this function's own
            // `index.e1.isCallExp` arm above already resolves through
            // `refReturningCallAddress` for the top-level index-is-call
            // shape.
            if (auto call = dot.e1.isCallExp)
                if (
                    call.f !is null &&
                    returnsRef(call.f) &&
                    dot.e1.type.toBasetype.isTypeStruct !is null
                ) {
                    import dmd.tokens: EXP;
                    import quickbite.backends.interpreter.place: Place;
                    import quickbite.backends.interpreter.place_value: readValue;

                    const address = refReturningCallAddress(call, EXP.address);
                    if (address.isPointer) {
                        auto fieldPlace = Place(address.pointerAddress, dot.e1.type)
                            .field(dot.var.isVarDeclaration);
                        const fieldValue = readValue(fieldPlace);
                        const outerIndex = scalarOperand!size_t(outer.e2);
                        checkStaticArrayIndexInBounds(fieldValue, outerIndex);
                        const outerElement = readStoredValue(
                            AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
                        );
                        checkStaticArrayIndexInBounds(outerElement, arrayIndex);
                        writeStoredValue(
                            fieldPlace.index(outerIndex).index(arrayIndex),
                            storageValue(index.type, value),
                        );
                        return;
                    }
                }

            // Whatever remains here has no addressable place this
            // activation can compose in place: a plain (non-ref) call
            // result or a literal receiver is a genuine rvalue -- DMD
            // itself makes `f().field[j][k] += v` a compile error for a
            // non-ref `f` returning a struct by value, so this shape is
            // reachable only through an already-lowered AST. A
            // captured-variable receiver has live storage but no static
            // predicate resolves it yet (the frame/dataseg-scoped
            // `hasBindingPlace` does not see a closure's cross-activation
            // captures) -- separate follow-on work. A `VarExp`-rooted
            // struct receiver (`local.field[j][k] += v`) also lands here:
            // `local` itself has a place, but this function composes its
            // write targets by hand rather than through the direct-write
            // predicates, so a plain local receiver keeps the snapshot
            // rebuild it always used.
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpressionValue(dot.e1);
            const fieldValue = readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(receiver), fieldIndex),
            );
            const outerIndex = scalarOperand!size_t(outer.e2);
            checkStaticArrayIndexInBounds(fieldValue, outerIndex);
            const outerElement = readStoredValue(
                AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
            );
            checkStaticArrayIndexInBounds(outerElement, arrayIndex);
            const updatedField = ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                AggregateValue.native(fieldValue),
                outerIndex,
                ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                    AggregateValue.native(outerElement), arrayIndex, value,
                )),
            ));
            writeLocation(dot.e1, ExpressionResult.nativeAggregateValue(
                AggregateValue.withStructField(AggregateValue.native(receiver), fieldIndex, updatedField),
            ));
            return;
        }

        if (auto dot = index.e1.isDotVarExp) {
            if (receiverClassType(dot.e1) !is null) {
                const receiver = constructedExpressionValue(dot.e1);
                // A class local exposes its object-body pointer. Resolve the
                // field's `Place` directly through that pointer and write
                // the updated array back through it.
                const nativeClassReceiver = receiver.isPointer
                    ? receiver
                    : receiver.isNativeAggregate
                    ? ExpressionResult.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                    : ExpressionResult.null_;
                if (nativeClassReceiver.isPointer) {
                    import quickbite.backends.interpreter.place: Place;
                    import quickbite.backends.interpreter.place_value: readValue, writeValue;

                    auto bodyAddress = nativeClassReceiver.pointerAddress;
                    auto bodyType = dot.e1.type;
                    if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                        bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                        bodyType = (*metadata).type;
                    }
                    auto fieldPlace = Place(bodyAddress, bodyType)
                        .field(dot.var.isVarDeclaration);
                    const source = readValue(fieldPlace);
                    const updatedArray = ExpressionResult.nativeAggregateValue(
                        AggregateValue.withArrayElement(AggregateValue.native(source), arrayIndex, value),
                    );
                    writeValue(fieldPlace, updatedArray);
                    return;
                }
                throw new Exception("Class field assignment needs a native address.");
            }

            // A `this`/`super`-rooted receiver chain (`this.arr[i] += v`, or
            // a deeper `this.inner.arr[i] += v`) is bound to this
            // activation's own receiver storage for its whole lifetime --
            // `projectionPlace` composes the field's live address the same
            // way `writeLocation`'s own `DotVarExp` arm does for an
            // unindexed field write.
            if (isThisRootedProjection(dot.e1) && hasProjectionPlace(dot.e1)) {
                import quickbite.backends.interpreter.place_value: readValue;

                auto fieldPlace = projectionPlace(dot);
                checkStaticArrayIndexInBounds(readValue(fieldPlace), arrayIndex);
                writeStoredValue(
                    fieldPlace.index(arrayIndex),
                    storageValue(index.type, value),
                );
                clearProjectionRootUninitialized(index);
                return;
            }

            // A ref-returning call's receiver (`f().arr[i] += v` where `f`
            // returns `ref S`) names a live struct lvalue, not a temporary
            // -- the same lvalue this function's own `index.e1.isCallExp`
            // arm above already resolves through `refReturningCallAddress`
            // for the top-level index-is-call shape.
            if (auto call = dot.e1.isCallExp)
                if (
                    call.f !is null &&
                    returnsRef(call.f) &&
                    dot.e1.type.toBasetype.isTypeStruct !is null
                ) {
                    import dmd.tokens: EXP;
                    import quickbite.backends.interpreter.place: Place;
                    import quickbite.backends.interpreter.place_value: readValue;

                    const address = refReturningCallAddress(call, EXP.address);
                    if (address.isPointer) {
                        auto fieldPlace = Place(address.pointerAddress, dot.e1.type)
                            .field(dot.var.isVarDeclaration);
                        checkStaticArrayIndexInBounds(readValue(fieldPlace), arrayIndex);
                        writeStoredValue(
                            fieldPlace.index(arrayIndex),
                            storageValue(index.type, value),
                        );
                        return;
                    }
                }

            // Whatever remains here has no addressable place this
            // activation can compose in place: a plain (non-ref) call
            // result or a literal receiver is a genuine rvalue -- DMD
            // itself makes `f().field[j] += v` a compile error for a
            // non-ref `f` returning a struct by value, so this shape is
            // reachable only through an already-lowered AST. A
            // captured-variable receiver has live storage but no static
            // predicate resolves it yet (the frame/dataseg-scoped
            // `hasBindingPlace` does not see a closure's cross-activation
            // captures) -- separate follow-on work. A `VarExp`-rooted
            // struct receiver (`local.field[j] += v`) also lands here for
            // the same reason as `writeIndexLocation`'s nested-`IndexExp`
            // arm above: this function composes its write targets by hand
            // rather than through the direct-write predicates, so a plain
            // local receiver keeps the snapshot rebuild it always used.
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpressionValue(dot.e1);
            const fieldValue = readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(receiver), fieldIndex),
            );
            const updatedArray = ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                AggregateValue.native(fieldValue), arrayIndex, value,
            ));
            writeLocation(dot.e1, ExpressionResult.nativeAggregateValue(
                AggregateValue.withStructField(AggregateValue.native(receiver), fieldIndex, updatedArray),
            ));
            return;
        }

        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto place = bindingPlace(variable).index(arrayIndex);
        writeStoredValue(place, storageValue(index.type, value));
        clearUninitializedBindingAddress(bindingPlace(variable).address);
    }

    private size_t structFieldIndex(imported!"dmd.expression".DotVarExp dot) {
        import quickbite.backends.interpreter.layout: structFields;

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception("Unsupported interpreter field access.");

        auto structType = receiverStructType(dot.e1);
        if (structType is null || structType.sym is null)
            throw new Exception("Unsupported interpreter field access.");

        foreach (index, candidate; structFields(structType))
            if (candidate is field)
                return index;

        throw new Exception("Unsupported interpreter field access.");
    }

    private ExpressionResult withUnionFieldWrite(
        in ExpressionResult receiver,
        imported!"dmd.mtype".TypeStruct unionType,
        in size_t fieldIndex,
        in ExpressionResult value,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readScalarLeaf, writeScalarLeaf;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        auto fields = structFields(unionType);
        if (fieldIndex >= fields.length)
            throw new Exception("Unsupported interpreter union field access.");
        const symbolicValue = value.isTypeName ||
            value.isFunctionPointer ||
            (fields[fieldIndex].type.toBasetype.ty == TY.Tdelegate &&
                value != ExpressionResult.null_);
        auto updated = ExpressionResult.nativeAggregateValue(AggregateValue.withStructField(
            AggregateValue.native(receiver),
            fieldIndex,
            symbolicValue ? ExpressionResult.null_ : value,
        ));

        auto writtenType = fields[fieldIndex].type;
        const writtenScalar = isNativeScalarType(writtenType);
        auto writtenStructType = writtenType.toBasetype.isTypeStruct;
        const writtenStruct = writtenStructType !is null
            && writtenStructType.sym.isUnionDeclaration is null;
        const writtenArray = isStaticArrayType(writtenType)
            && isNativeScalarType(writtenType.toBasetype.nextOf.toBasetype)
            && AggregateValue.isArray(value);

        if (!writtenScalar && !writtenStruct && !writtenArray)
            return withUnionStoredField(
                receiver,
                unionType,
                fieldIndex,
                value,
                updated,
            );

        auto cell = NativeStruct.allocate(unionType);

        // `NativeStruct.allocate` zero-initialises, and the transient cell
        // used to be seeded ONLY with the just-written member's own bytes
        // before the sibling loop below re-derived every OTHER member's
        // FULL extent from it -- any sibling WIDER than the written member
        // read zeros in the bytes outside the written member's extent
        // instead of the union's PRIOR bytes there (e.g. `int[2] a; int i;`:
        // writing `u.i` after `u.a = [...]` zeroed `a[1]`, which lies
        // entirely outside `i`'s 4-byte extent). Seeding the cell from
        // `receiver` -- the union's current native state, via the same
        // overlay-every-member-in-declaration-order path `promoteStructCell`
        // already uses to seed a cell from scratch -- first fills every
        // byte the union's prior state actually agreed on (every earlier
        // write through this same function already left every native-scalar/
        // array/struct sibling mutually consistent, so re-overlaying them
        // here is harmless, exactly as that seed's own doc comment already
        // established); the just-written member's bytes below then overwrite
        // only their own extent on top, leaving any wider sibling's tail
        // outside that extent intact instead of zeroed.
        writeStructCellScalarFields(cell, receiver);

        if (writtenScalar) {
            writeScalarLeaf(Place(cell.field(fieldIndex).ptr, writtenType), value);
        } else if (writtenStruct) {
            auto writtenCell = cell.structField(fieldIndex);
            writeStructCellScalarFields(writtenCell, value);
        } else {
            auto writtenElementType = writtenType.toBasetype.nextOf.toBasetype;
            auto writtenArrayCell = cell.arrayField(fieldIndex);
            auto valueAggregate = AggregateValue.native(value);
            foreach (elementIndex; 0 .. AggregateValue.length(valueAggregate))
                writeScalarLeaf(
                    Place(writtenArrayCell.element(elementIndex).ptr, writtenElementType),
                    readStoredValue(
                        AggregateValue.elementAt(valueAggregate, elementIndex),
                    ),
                );
        }

        foreach (siblingIndex, sibling; fields) {
            if (siblingIndex == fieldIndex)
                continue;

            if (isNativeScalarType(sibling.type)) {
                updated = ExpressionResult.nativeAggregateValue(AggregateValue.withStructField(
                    AggregateValue.native(updated), siblingIndex,
                    readScalarLeaf(Place(cell.field(siblingIndex).ptr, sibling.type)),
                ));
                continue;
            }

            if (isStaticArrayType(sibling.type)) {
                auto siblingElementType = sibling.type.toBasetype.nextOf.toBasetype;
                if (!isNativeScalarType(siblingElementType))
                    continue;

                auto siblingCurrent = readStoredValue(
                    AggregateValue.fieldAt(AggregateValue.native(updated), siblingIndex),
                );
                if (!AggregateValue.isArray(siblingCurrent))
                    continue;

                auto siblingArrayCell = cell.arrayField(siblingIndex);
                auto siblingAggregate = AggregateValue.native(siblingCurrent);
                foreach (elementIndex; 0 .. AggregateValue.length(siblingAggregate))
                    siblingAggregate = AggregateValue.withArrayElement(siblingAggregate, elementIndex,
                        readScalarLeaf(Place(
                            siblingArrayCell.element(elementIndex).ptr,
                            siblingElementType,
                        )));
                updated = ExpressionResult.nativeAggregateValue(AggregateValue.withStructField(
                    AggregateValue.native(updated), siblingIndex,
                    ExpressionResult.nativeAggregateValue(siblingAggregate),
                ));
                continue;
            }

            auto siblingStructType = sibling.type.toBasetype.isTypeStruct;
            if (siblingStructType is null || siblingStructType.sym.isUnionDeclaration !is null)
                continue;

            auto siblingCurrent = readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(updated), siblingIndex),
            );
            if (!AggregateValue.isStruct(siblingCurrent))
                continue;

            auto siblingCell = cell.structField(siblingIndex);
            updated = ExpressionResult.nativeAggregateValue(AggregateValue.withStructField(
                AggregateValue.native(updated), siblingIndex,
                structValueFromCell(siblingCurrent, siblingCell),
            ));
        }

        return withUnionStoredField(
            receiver,
            unionType,
            fieldIndex,
            value,
            updated,
        );
    }

    private ExpressionResult withUnionStoredField(
        in ExpressionResult receiver,
        imported!"dmd.mtype".TypeStruct unionType,
        in size_t fieldIndex,
        in ExpressionResult value,
        in ExpressionResult updated,
    ) {
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: Place;

        auto source = AggregateValue.native(receiver);
        auto destination = AggregateValue.native(updated);
        copyStoredMetadata(unionType, source.address, destination.address);
        writeStoredValue(
            Place(destination.address, unionType).field(
                structFields(unionType)[fieldIndex],
            ),
            value,
        );
        return updated;
    }

    private ExpressionResult runIndexAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: isPointerType, isStaticArrayType;

        // Compose the selected live element once before the RHS. Its complete
        // typed temporary then copies into that already-selected place, so
        // array and struct elements do not rebuild an enclosing carrier.
        if (isDirectIndexAssignmentTarget(index))
            return runProjectionAssignExpression(index, rhs);

        if (auto call = index.e1.isCallExp) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.place: Place;

            const address = refReturningCallAddress(call, EXP.address);
            if (!address.isPointer)
                throw new Exception("Ref-returning call has no native address.");
            const arrayIndex = scalarOperand!size_t(index.e2);
            auto destination = Place(address.pointerAddress, index.e1.type)
                .index(arrayIndex);
            if (canAssignThroughTypedTemporary(destination, rhs))
                return assignThroughTypedTemporary(destination, rhs);
            const value = constructedExpressionValue(rhs);
            writeStoredValue(destination, storageValue(index.type, value));
            return value;
        }

        if (isPointerType(index.e1.type)) {
            const address = pointerOperandPlace(index.e1).deref.address;
            const arrayIndex = scalarOperand!size_t(index.e2);
            if (address !is null) {
                import quickbite.backends.interpreter.layout: typeByteSize;
                import quickbite.backends.interpreter.place: Place;

                auto elementType = index.e1.type.toBasetype.nextOf.toBasetype;
                auto destination = Place(
                    nativeElementAddress(
                        cast(void*) address,
                        arrayIndex,
                        typeByteSize(elementType),
                    ),
                    elementType,
                );
                if (canAssignThroughTypedTemporary(destination, rhs)) {
                    const value = assignThroughTypedTemporary(destination, rhs);
                    clearUninitializedBindingAddress(cast(void*) address);
                    return value;
                }
                auto literal = rhs.isFuncExp;
                const value = literal is null
                    ? constructedExpressionValue(rhs)
                    : runFunctionLiteralDeclaration(literal);
                storeNativePointerElement(
                    index.e1.type,
                    ExpressionResult.pointerValue(cast(void*) address),
                    arrayIndex,
                    value,
                );
                return value;
            }
            throw new Exception("Pointer index assignment needs a native address.");
        }

        // `(*p)[i] = v`'s SIMPLE-assignment path -- the counterpart of
        // `writeIndexLocation`'s identical `PtrExp` arm (compound
        // assignment/atomic path). `index.e1` is a dereference whose
        // pointee is the static array being indexed (e.g. `int[3]*`), not a
        // variable/field lvalue; `&(*p)` recovers `p`'s own address
        // (`addressOfExpression`'s identical `PtrExp` arm).
        if (auto derefBase = index.e1.isPtrExp) {
            const address = pointerOperandPlace(derefBase.e1).deref.address;
            if (address !is null) {
                import quickbite.backends.interpreter.place: Place;

                const arrayIndex = scalarOperand!size_t(index.e2);
                auto destination = Place(cast(void*) address, index.e1.type)
                    .index(arrayIndex);
                if (canAssignThroughTypedTemporary(destination, rhs)) {
                    const value = assignThroughTypedTemporary(destination, rhs);
                    clearUninitializedBindingAddress(cast(void*) address);
                    return value;
                }
                const value = constructedExpressionValue(rhs);
                writeStoredValue(destination, value);
                return value;
            }
            throw new Exception("Unsupported interpreter assignment target.");
        }

        if (auto outer = index.e1.isIndexExp)
            return runNestedIndexAssignExpression(outer, index, rhs);

        if (auto dot = index.e1.isDotVarExp) {
            // Class sibling of the struct branch below (aggregate
            // composition -- static-array field): `c.arr[i] = v`'s
            // SIMPLE-assignment path (as opposed to
            // `writeIndexLocation`'s compound-assignment/atomic path, fixed
            // alongside this one) previously fell through to
            // `structFieldIndex`, which throws "Unsupported interpreter
            // field access." for a class receiver -- this shape was entirely
            // unsupported. Checked via the STATIC receiver type, matching
            // `writeLocation`'s own class-field dispatch.
            if (receiverClassType(dot.e1) !is null) {
                const receiver = constructedExpressionValue(dot.e1);
                const nativeClassReceiver = receiver.isPointer
                    ? receiver
                    : receiver.isNativeAggregate
                    ? ExpressionResult.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                    : ExpressionResult.null_;
                if (nativeClassReceiver.isPointer) {
                    import quickbite.backends.interpreter.place: Place;

                    auto bodyAddress = nativeClassReceiver.pointerAddress;
                    auto bodyType = dot.e1.type;
                    if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                        bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                        bodyType = (*metadata).type;
                    }
                    auto fieldPlace = Place(bodyAddress, bodyType)
                        .field(dot.var.isVarDeclaration);
                    const source = readStoredValue(fieldPlace);
                    if (index.lengthVar !is null)
                        setLocal(index.lengthVar, ExpressionResult(
                            AggregateValue.length(AggregateValue.native(source)),
                        ));
                    const arrayIndex = scalarOperand!size_t(index.e2);
                    auto destination = fieldPlace.index(arrayIndex);
                    if (canAssignThroughTypedTemporary(destination, rhs))
                        return assignThroughTypedTemporary(destination, rhs);
                    const value = constructedExpressionValue(rhs);
                    writeStoredValue(destination, value);
                    return value;
                }
                throw new Exception("Class field assignment needs a native address.");
            }

            // A `this`/`super`-rooted receiver chain (`this.arr[i] = v`, or
            // a deeper `this.inner.arr[i] = v`) is bound to this
            // activation's own receiver storage for its whole lifetime --
            // `projectionPlace` composes the field's live address the same
            // way `writeLocation`'s own `DotVarExp` arm does for an
            // unindexed field write. With the field itself now a live
            // place, the element write goes through the same
            // typed-temporary discipline `runProjectionAssignExpression`
            // uses for a direct target, instead of composing a whole
            // rebuilt struct value.
            if (isThisRootedProjection(dot.e1) && hasProjectionPlace(dot.e1)) {
                auto fieldPlace = projectionPlace(dot);
                const source = readStoredValue(fieldPlace);
                if (index.lengthVar !is null)
                    setLocal(index.lengthVar, ExpressionResult(
                        AggregateValue.length(AggregateValue.native(source)),
                    ));
                const arrayIndex = scalarOperand!size_t(index.e2);
                auto destination = fieldPlace.index(arrayIndex);
                if (canAssignThroughTypedTemporary(destination, rhs)) {
                    const value = assignThroughTypedTemporary(destination, rhs);
                    clearProjectionRootUninitialized(index);
                    return value;
                }
                const value = constructedExpressionValue(rhs);
                writeStoredValue(destination, storageValue(index.type, value));
                clearProjectionRootUninitialized(index);
                return value;
            }

            // A ref-returning call's receiver (`f().arr[i] = v` where `f`
            // returns `ref S`) names a live struct lvalue, not a temporary
            // -- the same lvalue this function's own `index.e1.isCallExp`
            // arm above already resolves through `refReturningCallAddress`
            // for the top-level index-is-call shape.
            if (auto call = dot.e1.isCallExp)
                if (
                    call.f !is null &&
                    returnsRef(call.f) &&
                    dot.e1.type.toBasetype.isTypeStruct !is null
                ) {
                    import dmd.tokens: EXP;
                    import quickbite.backends.interpreter.place: Place;

                    const address = refReturningCallAddress(call, EXP.address);
                    if (address.isPointer) {
                        auto fieldPlace = Place(address.pointerAddress, dot.e1.type)
                            .field(dot.var.isVarDeclaration);
                        const source = readStoredValue(fieldPlace);
                        if (index.lengthVar !is null)
                            setLocal(index.lengthVar, ExpressionResult(
                                AggregateValue.length(AggregateValue.native(source)),
                            ));
                        const arrayIndex = scalarOperand!size_t(index.e2);
                        auto destination = fieldPlace.index(arrayIndex);
                        if (canAssignThroughTypedTemporary(destination, rhs))
                            return assignThroughTypedTemporary(destination, rhs);
                        const value = constructedExpressionValue(rhs);
                        writeStoredValue(destination, storageValue(index.type, value));
                        return value;
                    }
                }

            // `$` inside index.e2 is a DollarExp bound to index.lengthVar, so
            // it must see the field array's current length: resolve the
            // field and seed lengthVar from it before evaluating index.e2,
            // the same order runIndexExpression (read path) already uses for
            // the same `$` binding. Evaluating e2 first left lengthVar
            // holding a stale (or default zero) length, so `h.arr[$ - 1] =
            // v` right after growing `h.arr` underflowed to size_t.max.
            //
            // Whatever remains here has no addressable place this
            // activation can compose in place: a plain (non-ref) call
            // result or a literal receiver is a genuine rvalue -- DMD
            // itself makes `f().arr[i] = v` a compile error for a non-ref
            // `f` returning a struct by value, so this shape is reachable
            // only through an already-lowered AST. A captured-variable
            // receiver has live storage but no static predicate resolves
            // it yet (the frame/dataseg-scoped `hasBindingPlace` does not
            // see a closure's cross-activation captures) -- separate
            // follow-on work. Any `VarExp`-rooted receiver already took
            // the direct-write path at the top of this function
            // (`isDirectIndexAssignmentTarget`), so a struct receiver
            // reaching here has no projection place of its own to derive.
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpressionValue(dot.e1);
            const source = readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(receiver), fieldIndex),
            );
            if (index.lengthVar !is null)
                setLocal(index.lengthVar, ExpressionResult(
                    AggregateValue.length(AggregateValue.native(source)),
                ));
            const arrayIndex = scalarOperand!size_t(index.e2);
            const value = runExpressionValue(rhs);
            const updatedArray = ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                AggregateValue.native(source), arrayIndex, value,
            ));
            writeLocation(dot.e1, ExpressionResult.nativeAggregateValue(
                AggregateValue.withStructField(AggregateValue.native(receiver), fieldIndex, updatedArray),
            ));
            return value;
        }

        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");


        const current = readBindingValue(variable);

        const arrayIndex = scalarOperand!size_t(index.e2);
        if (isStaticArrayType(index.e1.type))
            checkStaticArrayIndexInBounds(current, arrayIndex);

        import dmd.astenums: TY;

        auto elementType = index.e1.type.toBasetype.nextOf;
        // A live delegate element has no native ABI function address --
        // `place_value.writeValue`'s Tdelegate arm only ever accepts
        // `ExpressionResult.null_` -- so it cannot copy through a typed
        // temporary; it keeps registering the live value out-of-band in
        // `nativeDelegateSlots`, keyed by the element's own address,
        // mirroring the append and struct/class-field write sites.
        const isDelegateElement = elementType !is null
            && elementType.toBasetype.ty == TY.Tdelegate;
        auto destination = bindingPlace(variable).index(arrayIndex);

        if (!isDelegateElement && canAssignThroughTypedTemporary(destination, rhs)) {
            const value = assignThroughTypedTemporary(destination, rhs);
            clearUninitializedBindingAddress(bindingPlace(variable).address);
            return value;
        }

        // A fresh closure RHS (`dgs[0] = () => 1;`) is a bare `FuncExp`;
        // construct its callable before writing the destination.
        auto literal = rhs.isFuncExp;
        const value = literal is null
            ? constructedExpressionValue(rhs)
            : runFunctionLiteralDeclaration(literal);

        const isLiveDelegate = isDelegateElement && value != ExpressionResult.null_;
        const storedValue = isLiveDelegate ? ExpressionResult.null_ : value;
        writeStoredValue(destination, storageValue(elementType, storedValue));
        if (isLiveDelegate)
            nativeDelegateSlots[destination.address] = delegateSlotValue(value);
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return value;
    }

    // A runtime index past a static array's fixed DMD element count is
    // bounds checked here, before `withArrayElement`'s offset arithmetic --
    // otherwise `Place.index` (`place.d`) raises its own generic container
    // `Exception`, not druntime's `ArrayIndexError` text. Compiled D always
    // raises this exact wording for a write, regardless of call depth
    // (unlike the read path's accepted top-level/nested-call divergence), so
    // this forces `indexOutOfBoundsMessage`'s `runningCalledFunction` arm
    // unconditionally rather than threading the Walker's own flag through.
    private void checkStaticArrayIndexInBounds(
        in ExpressionResult array,
        in size_t index,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;

        const length = AggregateValue.length(AggregateValue.native(array));
        if (index >= length)
            throwRangeError(indexOutOfBoundsMessage(
                index,
                length,
                /* isSlice */ false,
                /* runningCalledFunction */ true,
            ));
    }

    private void writeArrayCellElement(
        ref NativeArray cell,
        in size_t index,
        in ExpressionResult value,
    ) {
        if (cell.elementType.isTypeStruct) {
            auto elementCell = cell.structElement(index);
            writeStructCellScalarFields(elementCell, value);
            return;
        }

        if (cell.elementType.isTypeSArray) {
            auto elementCell = cell.arrayElement(index);
            writeStaticArrayCellScalarElements(elementCell, value);
            return;
        }

        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeScalarLeaf;

        writeScalarLeaf(Place(cell.element(index).ptr, cell.elementType), value);
    }

    // Writes `arrayValue`'s scalar leaves into `cell`'s bytes (the
    // static-array-element counterpart of `writeStructCellScalarFields`):
    // shared by
    // `promoteArrayCell`'s static-array-element branch (the cell-creation
    // seed) and `writeArrayCellElement`'s own branch above (a direct
    // element write, `a[i] = [...]`, after the cell already exists).
    // Nested static-array elements recurse through `NativeArray.arrayElement`;
    // scalar elements terminate in the shared scalar codec. A no-op for a
    // value that isn't actually an array (defensive, mirroring
    // `writeStructCellScalarFields`'s static-array-field branch).
    private void writeStaticArrayCellScalarElements(
        ref NativeArray cell,
        in ExpressionResult arrayValue,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeScalarLeaf;

        if (!AggregateValue.isArray(arrayValue))
            return;

        auto aggregate = AggregateValue.native(arrayValue);
        foreach (index; 0 .. cell.length) {
            if (index >= AggregateValue.elementCount(arrayValue))
                continue;

            if (cell.elementType.isTypeSArray) {
                // Mutable because recursive write takes the view by ref.
                auto elementCell = cell.arrayElement(index);
                writeStaticArrayCellScalarElements(
                    elementCell,
                    readStoredValue(AggregateValue.elementAt(aggregate, index)),
                );
            } else {
                writeScalarLeaf(
                    Place(cell.element(index).ptr, cell.elementType),
                    readStoredValue(AggregateValue.elementAt(aggregate, index)),
                );
            }
        }
    }

    // A native cell already owns the aggregate bytes. Copy static-array bytes
    // directly to their typed place, or write a dynamic-array header that
    // aliases the cell's backing storage. Neither path rebuilds an aggregate
    // ExpressionResult solely to write it into another aggregate.
    private void copyArrayCellTo(
        imported!"dmd.mtype".Type type,
        ref NativeArray cell,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        if (type.toBasetype.isTypeDArray !is null) {
            AggregateValue.initializeBorrowedArray(
                destination,
                cell.length,
                cell.block.address,
            );
            return;
        }

        copyPlaceValue(Place(cell.block.address, type), destination);
    }

    private ExpressionResult runNestedIndexAssignExpression(
        imported!"dmd.expression".IndexExp outer,
        imported!"dmd.expression".IndexExp inner,
        imported!"dmd.expression".Expression rhs,
    ) {
        // `rows["a"][1] = 99`: DMD's own `revertIndexAssignToRvalues`
        // (`expressionsem.d`) rewrites an associative-array index nested one
        // level deeper than the assignment's own direct target (indexing
        // `rows["a"]`'s aggregate-typed VALUE, rather than `rows["a"]`
        // itself being assigned) into a `_d_aaGetRvalueX`-based rvalue read
        // -- `outer` (`rows["a"]`) becomes a pointer-dereference `IndexExp`
        // (index 0) over that call's own result, whose address already IS
        // the AA's own value-slot storage (the same lowering
        // `writeIndexLocation`'s own pointer arm composes through for the
        // sibling `aa[key].field = ...` shape). Write through that pointer
        // directly because the ordinary binding path has no pointer-typed
        // base.
        import quickbite.frontend.dmd.types: isPointerType, isStaticArrayType;

        if (isPointerType(outer.e1.type)) {
            import quickbite.backends.interpreter.place: Place;

            const address = pointerOperandPlace(outer.e1).deref.address;
            if (address is null)
                throw new Exception("Unsupported interpreter assignment target.");

            const innerIndex = scalarOperand!size_t(inner.e2);
            auto destination = Place(cast(void*) address, outer.type)
                .index(innerIndex);
            if (canAssignThroughTypedTemporary(destination, rhs)) {
                const value = assignThroughTypedTemporary(destination, rhs);
                clearUninitializedBindingAddress(cast(void*) address);
                return value;
            }
            const value = constructedExpressionValue(rhs);
            writeStoredValue(destination, value);
            return value;
        }

        // `arr[i].field[j][k] = value`: `outer` (`arr[i].field[j]`) is
        // itself an `IndexExp` whose own `e1` is a `DotVarExp`
        // (`arr[i].field`), not a `VarExp` -- the shape the plain-local
        // branch below assumes. Resolve the field's own current array
        // value through the receiver (mirroring `runIndexAssignExpression`'s
        // singly-indexed `DotVarExp` arm), then compose both index levels
        // onto it via the same `withArrayElement`/`elementAt` pair the
        // plain-local branch below uses, before writing the whole updated
        // field back through the receiver's own lvalue. `checkStaticArrayIndexInBounds`
        // bounds-checks a `Tarray` dimension just as well as a `Tsarray` one
        // -- both go through `AggregateValue.length`, which already reads
        // either shape's real runtime length -- so it applies to both
        // dimensions unconditionally here rather than being gated behind
        // `isStaticArrayType` as the plain-local branch's own checks are.
        //
        // `a.m[i][j] = value` (a bare class-typed local's own field,
        // `dot.e1` a `VarExp`) needs the class-field machinery instead:
        // `structFieldIndex` resolves the receiver's type via
        // `receiverStructType`, which returns `null` for a class, so it
        // unconditionally threw "Unsupported interpreter field access." for
        // this receiver shape before any indexing even ran. Dispatching on
        // `receiverClassType(dot.e1)` alone is not enough, though: a class
        // local exposes either its object-body pointer or its owning native
        // aggregate. Resolve the field's `Place` through that address, the same
        // `nativeClassReceiver`/`fieldPlace` composition
        // `runIndexAssignExpression`'s singly-indexed `DotVarExp`/class arm
        // already uses, then write only the selected element through that
        // same `Place` -- a class body's storage is its own host address, so
        // there is no separate receiver lvalue to rebind the way a struct's
        // local binding needs.
        if (auto dot = outer.e1.isDotVarExp) {
            if (receiverClassType(dot.e1) !is null) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                const receiver = constructedExpressionValue(dot.e1);
                const nativeClassReceiver = receiver.isPointer
                    ? receiver
                    : receiver.isNativeAggregate
                    ? ExpressionResult.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                    : ExpressionResult.null_;
                if (!nativeClassReceiver.isPointer)
                    throw new Exception("Unsupported interpreter assignment target.");

                auto fieldPlace = Place(nativeClassReceiver.pointerAddress, dot.e1.type)
                    .field(dot.var.isVarDeclaration);
                const fieldValue = readValue(fieldPlace);
                const outerIndex = scalarOperand!size_t(outer.e2);
                checkStaticArrayIndexInBounds(fieldValue, outerIndex);
                const outerElement = readStoredValue(
                    AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
                );
                const innerIndex = scalarOperand!size_t(inner.e2);
                checkStaticArrayIndexInBounds(outerElement, innerIndex);
                // Both bounds checks already passed against the field's own
                // current shape, so the composed element place is in range;
                // the class field's own storage is directly addressable, so
                // the selected element can be written in isolation instead
                // of rebuilding and rewriting the whole nested array.
                auto destination = fieldPlace.index(outerIndex).index(innerIndex);
                if (canAssignThroughTypedTemporary(destination, rhs))
                    return assignThroughTypedTemporary(destination, rhs);
                const value = constructedExpressionValue(rhs);
                writeStoredValue(destination, value);
                return value;
            }

            // A `this`/`super`-rooted receiver chain (`this.m[i][j] = v`, or
            // a deeper `this.inner.m[i][j] = v`) is bound to this
            // activation's own receiver storage for its whole lifetime --
            // `projectionPlace` composes the field's live address the same
            // way the class arm above composes its own `fieldPlace`, and
            // `writeLocation`'s own `DotVarExp` arm does for an unindexed
            // field write. With the field itself now a live place, the
            // element write goes through the same typed-temporary
            // discipline the class arm above uses, instead of composing a
            // whole rebuilt struct value.
            if (isThisRootedProjection(dot.e1) && hasProjectionPlace(dot.e1)) {
                import quickbite.backends.interpreter.place_value: readValue;

                auto fieldPlace = projectionPlace(dot);
                const fieldValue = readValue(fieldPlace);
                const outerIndex = scalarOperand!size_t(outer.e2);
                checkStaticArrayIndexInBounds(fieldValue, outerIndex);
                const outerElement = readStoredValue(
                    AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
                );
                const innerIndex = scalarOperand!size_t(inner.e2);
                checkStaticArrayIndexInBounds(outerElement, innerIndex);
                auto destination = fieldPlace.index(outerIndex).index(innerIndex);
                if (canAssignThroughTypedTemporary(destination, rhs)) {
                    const value = assignThroughTypedTemporary(destination, rhs);
                    clearProjectionRootUninitialized(inner);
                    return value;
                }
                const value = constructedExpressionValue(rhs);
                writeStoredValue(destination, value);
                clearProjectionRootUninitialized(inner);
                return value;
            }

            // A ref-returning call's receiver (`f().m[i][j] = v` where `f`
            // returns `ref S`) names a live struct lvalue, not a temporary
            // -- the same lvalue the sibling `dot.e1.isCallExp` arms in
            // `runIndexAssignExpression` and `writeIndexLocation` already
            // resolve through `refReturningCallAddress` for their own
            // singly-indexed struct fallbacks.
            if (auto call = dot.e1.isCallExp)
                if (
                    call.f !is null &&
                    returnsRef(call.f) &&
                    dot.e1.type.toBasetype.isTypeStruct !is null
                ) {
                    import dmd.tokens: EXP;
                    import quickbite.backends.interpreter.place: Place;
                    import quickbite.backends.interpreter.place_value: readValue;

                    const address = refReturningCallAddress(call, EXP.address);
                    if (address.isPointer) {
                        auto fieldPlace = Place(address.pointerAddress, dot.e1.type)
                            .field(dot.var.isVarDeclaration);
                        const fieldValue = readValue(fieldPlace);
                        const outerIndex = scalarOperand!size_t(outer.e2);
                        checkStaticArrayIndexInBounds(fieldValue, outerIndex);
                        const outerElement = readStoredValue(
                            AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
                        );
                        const innerIndex = scalarOperand!size_t(inner.e2);
                        checkStaticArrayIndexInBounds(outerElement, innerIndex);
                        auto destination = fieldPlace.index(outerIndex).index(innerIndex);
                        if (canAssignThroughTypedTemporary(destination, rhs))
                            return assignThroughTypedTemporary(destination, rhs);
                        const value = constructedExpressionValue(rhs);
                        writeStoredValue(destination, value);
                        return value;
                    }
                }

            // Whatever remains here has no addressable place this
            // activation can compose in place: a plain (non-ref) call
            // result or a literal receiver is a genuine rvalue -- DMD
            // itself makes `f().m[i][j] = v` a compile error for a
            // non-ref `f` returning a struct by value, so this shape is
            // reachable only through an already-lowered AST. A
            // captured-variable receiver has live storage but no static
            // predicate resolves it yet (the frame/dataseg-scoped
            // `hasBindingPlace` does not see a closure's cross-activation
            // captures) -- separate follow-on work. A `VarExp`-rooted
            // struct receiver (`local.m[i][j] = v`) also lands here: this
            // function composes its write targets by hand rather than
            // through the direct-write predicates, so a plain local
            // receiver keeps the snapshot rebuild it always used.
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpressionValue(dot.e1);
            const fieldValue = readStoredValue(
                AggregateValue.fieldAt(AggregateValue.native(receiver), fieldIndex),
            );
            const outerIndex = scalarOperand!size_t(outer.e2);
            checkStaticArrayIndexInBounds(fieldValue, outerIndex);
            const outerElement = readStoredValue(
                AggregateValue.elementAt(AggregateValue.native(fieldValue), outerIndex),
            );
            const innerIndex = scalarOperand!size_t(inner.e2);
            checkStaticArrayIndexInBounds(outerElement, innerIndex);
            const value = runExpressionValue(rhs);
            const updatedField = ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                AggregateValue.native(fieldValue),
                outerIndex,
                ExpressionResult.nativeAggregateValue(AggregateValue.withArrayElement(
                    AggregateValue.native(outerElement), innerIndex, value,
                )),
            ));
            writeLocation(dot.e1, ExpressionResult.nativeAggregateValue(
                AggregateValue.withStructField(AggregateValue.native(receiver), fieldIndex, updatedField),
            ));
            return value;
        }

        auto var = outer.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const current = readBindingValue(variable);

        const outerIndex = scalarOperand!size_t(outer.e2);
        if (isStaticArrayType(outer.e1.type))
            checkStaticArrayIndexInBounds(current, outerIndex);
        const outerElement = readStoredValue(
            AggregateValue.elementAt(AggregateValue.native(current), outerIndex),
        );
        const innerIndex = scalarOperand!size_t(inner.e2);
        if (isStaticArrayType(inner.e1.type))
            checkStaticArrayIndexInBounds(outerElement, innerIndex);
        auto destination = bindingPlace(variable)
            .index(outerIndex)
            .index(innerIndex);
        if (canAssignThroughTypedTemporary(destination, rhs)) {
            const value = assignThroughTypedTemporary(destination, rhs);
            clearUninitializedBindingAddress(bindingPlace(variable).address);
            return value;
        }
        const value = constructedExpressionValue(rhs);
        writeStoredValue(destination, storageValue(inner.type, value));
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return value;
    }

    // A slice assignment's destination range must be rejected before `rhs` is
    // even evaluated -- matching compiled D, which raises before any side
    // effect in `rhs` runs. `lower > upper` takes priority over an
    // out-of-range `upper`, the same order druntime's own `ArraySliceError`
    // (`core.exception`) picks; message text matches it verbatim, so
    // `SystemLinker` agrees exactly. An unchecked `upper > length` would
    // additionally index a per-path element buffer out of range with a HOST
    // `RangeError` rather than raising the guest one.
    private void checkSliceAssignmentBounds(
        in size_t lower,
        in size_t upper,
        in size_t length,
    ) {
        import std.conv: text;

        if (lower > upper)
            throwRangeError(text(
                "slice [", lower, " .. ", upper,
                "] has a larger lower index than upper index",
            ));

        if (upper > length)
            throwRangeError(text(
                "slice [", lower, " .. ", upper,
                "] extends past source array of length ", length,
            ));
    }

    // A slice destination is live storage, so its RHS must first finish in
    // separate typed storage. This single construction covers an array-copy
    // RHS and a scalar or nested-array broadcast; the existing native slice
    // paths then copy its completed elements into their resolved targets.
    // The out `place` parameter exposes exactly where the RHS landed, so a
    // caller that goes on to index its elements can read them straight out
    // of this typed storage instead of re-deriving a place from the
    // returned value a second time.
    private ExpressionResult constructSliceAssignmentRhs(
        imported!"dmd.expression".Expression rhs,
        out imported!"quickbite.backends.interpreter.place".Place place,
    ) {
        import quickbite.backends.interpreter.place: Place;

        assert(rhs !is null && rhs.type !is null);
        place = Place(_activationFrame.temporaryAddress(rhs), rhs.type);
        auto temporary = ConstructionDestination(place);
        runExpression(rhs, temporary);
        return readStoredValue(place);
    }

    private ExpressionResult runSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;
        import std.conv: text;

        if (isPointerType(slice.e1.type))
            return runPointerSliceAssignExpression(slice, rhs);

        auto var = slice.e1.isVarExp;
        if (var is null) {
            if (auto index = slice.e1.isIndexExp)
                return runIndexedSliceAssignExpression(slice, index, rhs);
            if (auto dot = slice.e1.isDotVarExp)
                return runFieldSliceAssignExpression(slice, dot, rhs);
            if (slice.e1.isCastExp !is null)
                return runCastedSliceAssignExpression(slice, rhs);
            throw new Exception(text(
                "Unsupported interpreter assignment target: slice of ",
                slice.e1.op,
            ));
        }

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception(
                "Unsupported interpreter assignment target: slice of non-variable.",
            );

        if (isUninitializedBinding(variable)) {
            // A `T t = void;` local (e.g. `std.algorithm.mutation.swap`'s
            // raw-byte fallback `ubyte[T.sizeof] t = void;`) never runs
            // `setLocal` at its declaration -- there is no meaningful value
            // to shadow -- so it has no stored value yet the first time it is
            // used as a slice-assignment target. Compiled D leaves its bytes
            // unspecified until written; materialising the ordinary default
            // here is observably identical for the whole-range overwrite
            // (`t[] = ...`) idiom this local exists for, and is no less
            // defined than compiled D for a genuine partial write to
            // still-uninitialized bytes.
            defaultLocalValue(variable);
            clearUninitializedBindingAddress(bindingPlace(variable).address);
        }
        const current = readBindingValue(variable);
        auto currentAggregate = AggregateValue.native(current);

        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? AggregateValue.length(currentAggregate)
            : scalarOperand!size_t(slice.upr);

        checkSliceAssignmentBounds(lower, upper, AggregateValue.length(currentAggregate));

        rejectOverlappingSliceAssignment(
            variable,
            rhs,
            lower,
            upper,
            AggregateValue.length(currentAggregate),
        );

        const block = isBlockSliceAssignment(slice, rhs);
        imported!"quickbite.backends.interpreter.place".Place rhsPlace;
        const value = constructSliceAssignmentRhs(rhs, rhsPlace);

        // A fill assignment (`a[] = scalar;`) evaluates `rhs` to a single
        // element-typed value, not an array to index into -- only the copy
        // form (`a[] = otherArray[];`, whose `rhs.type` matches the SLICE's
        // own array type) yields something `value[index - lower]` can index.
        // `block` (a fill whose ELEMENT type is itself an array, e.g.
        // `matrix[] = row;`) already takes the `copyArrayValue` branch;
        // `value.isArray` distinguishes the remaining two: a genuine array
        // copy vs. a scalar-element fill, which must reuse `value` itself at
        // every position instead of indexing into it. Each element read
        // (from either the untouched tail of `current` or `rhsPlace`)
        // routes through `readStoredValue` so a delegate/function-pointer/
        // symbolic-TypeInfo element keeps its out-of-band identity instead
        // of decoding as all-zero native bytes.
        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(currentAggregate))
            elements ~= index < lower || index >= upper
                ? readStoredValue(AggregateValue.elementAt(currentAggregate, index))
                : block ? copyArrayValue(value, variable.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? readStoredArrayElement(rhsPlace, index - lower)
                    : value;

        auto destination = bindingPlace(variable);
        foreach (index; lower .. upper)
            writeStoredArrayElement(destination.index(index), elements[index]);
        clearUninitializedBindingAddress(destination.address);

        // This variable's own data pointer denotes the same bytes a native
        // pointer to it would, so a whole-range write through it establishes
        // a class's identity exactly as `runPointerSliceAssignExpression`
        // already records for the pointer form of the same write.
        if (lower == 0)
            recordCopiedClassIdentity(
                cast(void*) AggregateValue.nativeArrayAddress(current),
                value,
            );

        return value;
    }

    // Writing one element of an array whose element type is `void`: the
    // element is a byte of raw storage, because `void` names no value the
    // place codec could store. Assigning between `void[]` slices is a byte
    // copy in D -- their bounds and assignment length are measured in bytes
    // -- so retyping the destination place to `ubyte` stores exactly the
    // byte its counterpart `readStoredArrayElement` reads as a raw byte too.
    private void writeStoredArrayElement(
        imported!"quickbite.backends.interpreter.place".Place element,
        in ExpressionResult value,
    ) {
        import dmd.astenums: TY;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.place: Place;

        if (element.type.toBasetype.ty == TY.Tvoid) {
            writeStoredValue(Place(element.address, Type.tuns8), value);
            return;
        }
        writeStoredValue(element, value);
    }

    // Reading one element of an array whose element type is `void`: the same
    // retyping as `writeStoredArrayElement`'s write side, so a `void[]`
    // slice-assignment RHS decodes as the raw byte its destination expects,
    // rather than failing the place codec, which has no case for `void`
    // itself.
    private ExpressionResult readStoredArrayElement(
        imported!"quickbite.backends.interpreter.place".Place array,
        in size_t index,
    ) {
        import dmd.astenums: TY;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.place: Place;

        auto element = array.index(index);
        auto darray = array.type.toBasetype.isTypeDArray;
        if (darray !is null && darray.next.toBasetype.ty == TY.Tvoid)
            element = Place(element.address, Type.tuns8);
        return readStoredValue(element);
    }

    // An indexed array-of-arrays element is already an independently
    // addressable slice header.  Keep that native header and write its
    // elements in place; rebuilding its enclosing array would create a second
    // storage authority for this lvalue shape.
    private ExpressionResult runIndexedSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import std.conv: text;

        const current = runIndexExpression(index);
        auto currentAggregate = AggregateValue.native(current);
        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? AggregateValue.length(currentAggregate)
            : scalarOperand!size_t(slice.upr);

        checkSliceAssignmentBounds(lower, upper, AggregateValue.length(currentAggregate));

        const block = isBlockSliceAssignment(slice, rhs);
        imported!"quickbite.backends.interpreter.place".Place rhsPlace;
        const value = constructSliceAssignmentRhs(rhs, rhsPlace);
        foreach (elementIndex; lower .. upper) {
            const element = block
                ? copyArrayValue(value, index.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? readStoredArrayElement(rhsPlace, elementIndex - lower)
                    : value;
            AggregateValue.withArrayElement(currentAggregate, elementIndex, element);
        }
        return value;
    }

    // A slice assignment through a pointer (`p[i .. j] = source`) writes
    // element by element through the pointer — native memory via the FFI
    // store, D array storage via the tracked pointer — and never converts
    // the lvalue to a detached Array, which would silently sever aliasing.
    private ExpressionResult runPointerSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import std.conv: text;

        const address = pointerOperandPlace(slice.e1).deref.address;
        if (slice.lwr is null || slice.upr is null)
            throw new Exception(text(
                "Unsupported interpreter assignment target: slice of ",
                slice.e1.op,
            ));

        const lower = scalarOperand!size_t(slice.lwr);
        const upper = scalarOperand!size_t(slice.upr);

        // Reject an inverted range before `rhs` is evaluated -- matching
        // compiled D, which raises before any side effect in `rhs` runs --
        // and before the write loop below computes `upper - lower`: with an
        // unsigned `size_t`, `lower > upper` wraps that subtraction to a huge
        // count, turning the loop into a runaway walk through native memory
        // instead of the guest range error compiled D raises. Message text
        // matches druntime's own `ArraySliceError` verbatim, so
        // `SystemLinker` agrees exactly.
        if (lower > upper)
            throwRangeError(text(
                "slice [", lower, " .. ", upper,
                "] has a larger lower index than upper index",
            ));

        const block = isBlockSliceAssignment(slice, rhs);
        imported!"quickbite.backends.interpreter.place".Place rhsPlace;
        const value = constructSliceAssignmentRhs(rhs, rhsPlace);

        // An empty range writes nothing, so the pointer's provenance never
        // matters — a zero-length assignment through a null pointer is a no-op
        // in compiled D, not an unsupported target.
        if (upper == lower)
            return value;

        // A fill assignment (`p[i .. j] = scalar;`, e.g. druntime's own
        // `(cast(ubyte*)&entry.value)[0 .. V.sizeof] = 0` zeroing a new AA
        // entry) evaluates `rhs` to a single element-typed value, not an
        // array to index into -- only the copy form yields something
        // `value[index - lower]` can index. `AggregateValue.isArray`
        // distinguishes the two, matching every other slice-assignment path
        // (`runVariableSliceAssignExpression`, `runFieldSliceAssignExpression`,
        // `runCastedSliceAssignExpression`), which this one had fallen out of
        // step with.
        ExpressionResult elementAt(in size_t index) {
            return block
                ? copyArrayValue(value, slice.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? readStoredArrayElement(rhsPlace, index)
                    : value;
        }

        if (address !is null) {
            foreach (index; 0 .. upper - lower)
                storeNativePointerElement(
                    slice.e1.type,
                    ExpressionResult.pointerValue(cast(void*) address),
                    lower + index,
                    elementAt(index),
                );
            if (lower == 0)
                recordCopiedClassIdentity(cast(void*) address, value);
            return value;
        }

        throw new Exception(text(
            "Unsupported interpreter assignment target: slice of ",
            slice.e1.op,
        ));
    }

    // Copying a class's whole initializer image over storage establishes an
    // object of that class there: it is exactly the write that precedes any
    // constructor, and after it the storage holds that class's fields. So the
    // destination now denotes an object of the source's class, whatever it
    // denoted before -- the bytes that said otherwise are gone.
    private void recordCopiedClassIdentity(
        void* destination,
        in ExpressionResult source,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        // A destination whose own bytes are its storage (a static-array
        // lvalue) has no data pointer distinct from its own address, so
        // there is nothing here to key an identity by; only a destination
        // reached through a dynamic array's data pointer participates.
        if (destination is null)
            return;

        auto image = cast(void*) AggregateValue.nativeArrayAddress(source);
        if (image is null)
            return;

        if (auto type = image in nativeClassTypes)
            nativeClassTypes[destination] = *type;
    }

    private void rejectOverlappingSliceAssignment(
        VarDeclaration variable,
        imported!"dmd.expression".Expression rhs,
        in size_t lower,
        in size_t upper,
        in size_t length,
    ) {
        auto source = rhs.isSliceExp;
        if (source is null)
            return;

        auto var = source.e1.isVarExp;
        if (var is null)
            return;

        if (var.var.isVarDeclaration !is variable)
            return;

        const sourceLower = source.lwr is null
            ? 0
            : scalarOperand!size_t(source.lwr);
        const sourceUpper = source.upr is null
            ? length
            : scalarOperand!size_t(source.upr);

        if (lower < sourceUpper && sourceLower < upper)
            throw new Exception("Range violation");
    }

    // A slice assignment through a struct field (`s.buf[i .. j] = source[]`)
    // writes the assigned elements one by one through the storage the field
    // already denotes -- `fieldSliceStorage` below resolves which storage
    // that is. Rebuilding a whole new array and storing it back into the
    // field slot instead would replace the field's data pointer with a fresh
    // allocation's, silently severing an identity its owner may depend on --
    // e.g. a field backed by a `Mallocator`-returned block whose destructor
    // later frees the field's pointer: swapping in a differently-sourced
    // block there corrupts the allocator on free.
    private ExpressionResult runFieldSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".DotVarExp dot,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto current = fieldSliceStorage(dot);

        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? current.arrayLength
            : scalarOperand!size_t(slice.upr);

        checkSliceAssignmentBounds(lower, upper, current.arrayLength);

        const block = isBlockSliceAssignment(slice, rhs);
        imported!"quickbite.backends.interpreter.place".Place rhsPlace;
        const value = constructSliceAssignmentRhs(rhs, rhsPlace);

        // A fill assignment (`s.field[] = scalar;` or `s.field[a .. b] =
        // scalar;`) evaluates `rhs` to a single element-typed value, not an
        // array to index into -- only the copy form (`s.field[] =
        // otherArray[];`) yields something `value[index - lower]` can index.
        // `AggregateValue.isArray` distinguishes the two, matching the
        // variable slice-assignment path above.
        foreach (index; lower .. upper) {
            const element = block
                ? copyArrayValue(value, slice.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? readStoredArrayElement(rhsPlace, index - lower)
                    : value;
            writeStoredArrayElement(current.index(index), element);
        }

        // A dynamic-array field's data pointer denotes the same bytes a
        // native pointer to it would, so a whole-range write through it
        // establishes a class's identity exactly as
        // `runPointerSliceAssignExpression` already records for the pointer
        // form of the same write. A static-array field has no data pointer
        // distinct from its own address; `recordCopiedClassIdentity` no-ops
        // for it.
        if (lower == 0)
            recordCopiedClassIdentity(
                current.type.toBasetype.isTypeDArray !is null
                    ? cast(void*) current.sliceDataPointer
                    : null,
                value,
            );

        return value;
    }

    // The array storage a struct field's own slice assignment must land in,
    // as a place its caller can index through. D gives an array field two
    // different storage shapes, and either one composes directly to a
    // `Place` over the field's own bytes:
    //
    // - A dynamic-array field's own bytes are a `{ length, ptr }` header,
    //   and its elements live wherever `ptr` points. `Place.index` on that
    //   header place follows the stored `ptr`, so indexing through it
    //   reaches the field's own elements regardless of whether the
    //   receiver struct itself was addressable.
    //
    // - A static-array field's own bytes ARE its elements. Its storage has
    //   to be composed from the receiver's own address instead, which is
    //   what the arm below does; only that address names the bytes the
    //   struct holds.
    private imported!"quickbite.backends.interpreter.place".Place fieldSliceStorage(
        imported!"dmd.expression".DotVarExp dot,
    ) {
        import quickbite.backends.interpreter.layout: declaredType;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isStaticArrayType;
        import dmd.tokens: EXP;
        import std.conv: text;

        auto field = dot.var.isVarDeclaration;
        if (field is null || !isStaticArrayType(declaredType(field))) {
            if (field is null)
                throw new Exception("Unsupported interpreter field access.");

            auto aggregate = AggregateValue.native(constructedExpressionValue(dot.e1));
            return Place(aggregate.address, aggregate.type).field(field);
        }

        const receiver = addressOfExpression(dot.e1, EXP.address);
        if (!receiver.isPointer)
            throw new Exception(text(
                "Unsupported interpreter assignment target: static-array field slice of ",
                dot.e1.op,
            ));

        // A class receiver holds a reference to its object body, so its
        // fields sit at offsets from the referenced body rather than from
        // the reference slot itself; a struct receiver's fields sit inline
        // at its own address.
        auto receiverPlace = Place(receiver.pointerAddress, dot.e1.type);
        if (dot.e1.type.toBasetype.isTypeClass !is null)
            receiverPlace = receiverPlace.deref;

        // The receiver is an lvalue that outlives this assignment -- a
        // frame slot, a dataseg block, or a class body reached through a
        // live reference -- so this place, composed straight over its own
        // field bytes, is exactly the assignment's real target.
        return receiverPlace.field(field);
    }

    // A slice assignment through a cast (`(cast(char[]) view)[] = "foo"`):
    // casting a slice changes the element type of the view, never the storage
    // it denotes, so the assignment must land in the array the cast operand
    // already points at. Evaluating the cast yields a slice header holding
    // that same data pointer, so writing elements through it with
    // `AggregateValue.withArrayElement` reaches the original backing array.
    // Rebuilding an array from the written elements instead would leave the
    // result in a fresh allocation the source never sees.
    private ExpressionResult runCastedSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        const current = constructedExpressionValue(slice.e1);
        auto currentAggregate = AggregateValue.native(current);

        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? AggregateValue.length(currentAggregate)
            : scalarOperand!size_t(slice.upr);

        checkSliceAssignmentBounds(lower, upper, AggregateValue.length(currentAggregate));

        const block = isBlockSliceAssignment(slice, rhs);
        imported!"quickbite.backends.interpreter.place".Place rhsPlace;
        const value = constructSliceAssignmentRhs(rhs, rhsPlace);

        // A fill assignment (`(cast(T[]) view)[] = scalar;`) evaluates `rhs`
        // to a single element-typed value, not an array to index into --
        // only the copy form yields something `value[index - lower]` can
        // index. `AggregateValue.isArray` distinguishes the two, matching
        // the variable slice-assignment path above.
        foreach (index; lower .. upper) {
            const element = block
                ? copyArrayValue(value, slice.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? readStoredArrayElement(rhsPlace, index - lower)
                    : value;
            AggregateValue.withArrayElement(currentAggregate, index, element);
        }

        // A cast changes a view's element type, not the storage it denotes,
        // so its data pointer still denotes the same bytes a native pointer
        // to that storage would: a whole-range write through it establishes
        // a class's identity exactly as `runPointerSliceAssignExpression`
        // already records for the pointer form of the same write.
        if (lower == 0)
            recordCopiedClassIdentity(
                cast(void*) AggregateValue.nativeArrayAddress(current),
                value,
            );

        return value;
    }

    private bool isBlockSliceAssignment(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: arrayElementType, isArrayType;

        auto elementType = arrayElementType(slice.type);
        if (elementType is null || !isArrayType(elementType))
            return false;

        return rhs.type !is null &&
            rhs.type.toBasetype.equals(elementType.toBasetype);
    }

    private ExpressionResult copyArrayValue(
        in ExpressionResult value,
        imported!"dmd.mtype".Type type,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto aggregate = AggregateValue.native(value);
        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(aggregate))
            elements ~= readStoredValue(AggregateValue.elementAt(aggregate, index));

        return reconstructStoredArray(aggregate.type, elements);
    }

    private ExpressionResult runLoweredAssignExpression(
        imported!"dmd.expression".LoweredAssignExp assign,
    ) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;
        import std.conv: text;

        auto arrayLength = assign.e1.isArrayLengthExp;
        if (arrayLength is null) {
            if (assign.lowering !is null)
                return runExpressionValue(assign.lowering);

            throw new Exception(text("Unsupported eval expression: ", assign.op));
        }

        const lengthValue = constructedExpressionValue(assign.e2);

        auto var = arrayLength.e1.isVarExp;
        if (var is null) {
            writeArrayLengthLocation(arrayLength, lengthValue);
            return lengthValue;
        }

        auto variable = var.var.isVarDeclaration;
        if (variable is null || !isDynamicArrayType(variable.type)) {
            writeArrayLengthLocation(arrayLength, lengthValue);
            return lengthValue;
        }

        const current = readBindingValue(variable);

        const newLength = cast(size_t) lengthValue.asLong;

        // DMD lowers postfix `.length++`/`.length--` through a synthetic
        // `ref` local, so resize via that binding's native place.
        writeLocation(
            var,
            resizedStoredArray(variable.type, current, newLength),
        );
        return lengthValue;
    }

    private ExpressionResult runConcatenateExpression(imported!"dmd.expression".CatExp cat) {
        return concatenatedArray(cat.type, cat.e1, cat.e2);
    }

    // A `~`/`~=` result array. Both operands are read once each, then their
    // elements are written directly into the freshly allocated destination:
    // no intermediate element array ever mirrors either operand or the
    // result.
    private ExpressionResult concatenatedArray(
        imported!"dmd.mtype".Type resultType,
        imported!"dmd.expression".Expression e1,
        imported!"dmd.expression".Expression e2,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        auto left = concatenationOperand(resultType, e1);
        auto right = concatenationOperand(resultType, e2);
        auto owner = AggregateValue.allocateArray(resultType, left.count + right.count);
        auto destination = Place(owner.address, resultType);
        writeConcatenationOperand(destination, 0, left);
        writeConcatenationOperand(destination, left.count, right);
        return ExpressionResult.nativeAggregateValue(owner);
    }

    // One concatenation operand's contribution. An array operand's elements
    // stay a borrowed view of its own storage -- never a copy of it, since
    // the source array's identity is capacity-bearing and its own append
    // machinery, not this read, owns any reallocation. A scalar operand
    // contributes its native append elements instead (`nativeAppendElements`'s
    // UTF-8 code-unit split for a wide character appended to `string`, or a
    // single value otherwise).
    private struct ConcatenationOperand {
        bool isArray;
        imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate aggregate;
        ExpressionResult[] scalarElements;

        size_t count() @safe {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;

            return isArray ? AggregateValue.elementCount(aggregate) : scalarElements.length;
        }
    }

    private ConcatenationOperand concatenationOperand(
        imported!"dmd.mtype".Type resultType,
        imported!"dmd.expression".Expression operand,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.frontend.dmd.types: isArrayType;

        const value = constructedExpressionValue(operand);
        if (!isArrayType(operand.type)) {
            ConcatenationOperand result;
            result.scalarElements = nativeAppendElements(resultType, value);
            return result;
        }

        ConcatenationOperand result;
        result.isArray = true;
        result.aggregate = AggregateValue.native(value);
        return result;
    }

    private void writeConcatenationOperand(
        imported!"quickbite.backends.interpreter.place".Place destination,
        in size_t startIndex,
        ConcatenationOperand operand,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (!operand.isArray) {
            foreach (offset, element; operand.scalarElements)
                writeStoredValue(destination.index(startIndex + offset), element);
            return;
        }

        foreach (index; 0 .. AggregateValue.elementCount(operand.aggregate))
            writeStoredValue(
                destination.index(startIndex + index),
                readStoredValue(AggregateValue.elementAt(operand.aggregate, index)),
            );
    }

    private ExpressionResult runArrayAppendAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        // A field or a dereferenced pointer (`*log ~= id`, e.g. a
        // destructor appending through a captured `int[]*` field) both read
        // through their own typed places and write through the generic
        // `writeLocation` -- neither needs the ref-array-parameter or
        // bounds-check handling the `VarExp`/`IndexExp` arms below exist for.
        if (assign.e1.isDotVarExp !is null || assign.e1.isPtrExp !is null) {
            auto literal = assign.e2.isFuncExp;
            const element = literal is null
                ? constructedExpressionValue(assign.e2)
                : runFunctionLiteralDeclaration(literal);
            const appended = ExpressionResult.nativeAggregateValue(AggregateValue.withAppendedArrayElement(
                AggregateValue.native(constructedExpressionValue(assign.e1)),
                element,
            ));
            writeLocation(assign.e1, appended);
            return appended;
        }

        if (auto index = assign.e1.isIndexExp)
            return runIndexedArrayAppendAssignExpression(index, assign.e2);

        auto var = assign.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter array append target.");

        const current = readBindingValue(variable);

        auto literal = assign.e2.isFuncExp;
        const value = literal is null
            ? constructedExpressionValue(assign.e2)
            : runFunctionLiteralDeclaration(literal);
        {
            import dmd.astenums: TY;

            // Begin each append from the binding's current native slice
            // header (already read above as `current`) so captured slices
            // observe prior iterations. Explicit LHS type: `auto` would infer
            // `const(ExpressionResult)` from the `current` arm, and the loop
            // below reassigns `appended` on every iteration.
            ExpressionResult[] noElements;
            ExpressionResult appended = current == ExpressionResult.null_
                ? reconstructStoredArray(variable.type, noElements)
                : current;
            auto elementType = variable.type.toBasetype.isTypeDArray !is null
                ? variable.type.toBasetype.isTypeDArray.next
                : null;
            foreach (rawElement; nativeAppendElements(variable.type, value)) {
                const index = AggregateValue.elementCount(appended);
                const previousData = AggregateValue.nativeArrayAddress(appended);
                // The appended element itself may be a live delegate value
                // (a fresh closure or a copied delegate local), which has no
                // native ABI function address -- `place_value.writeValue`'s
                // Tdelegate arm only ever accepts `ExpressionResult.null_`. Substitute
                // null bytes for the write and register the live value
                // out-of-band in `nativeDelegateSlots`, keyed by the newly
                // appended element's own address, mirroring the sub-field
                // relocation below and `structLiteralValue`'s identical
                // substitute-then-register handling.
                const isLiveDelegate = elementType !is null
                    && elementType.toBasetype.ty == TY.Tdelegate
                    && rawElement != ExpressionResult.null_;
                auto element = isLiveDelegate ? ExpressionResult.null_ : rawElement;
                appended = ExpressionResult.nativeAggregateValue(
                    AggregateValue.withAppendedArrayElement(AggregateValue.native(appended), element),
                );
                if (elementType !is null)
                    relocatePriorAppendedElementSlots(
                        elementType,
                        previousData,
                        appended,
                        index,
                    );
                if (isLiveDelegate) {
                    nativeDelegateSlots[
                        AggregateValue.elementAddress(appended, index)
                    ] = delegateSlotValue(rawElement);
                } else if (elementType !is null && element.isNativeAggregate)
                    // `withAppendedArrayElement`'s native-aggregate arm only
                    // copies `element`'s bytes into the array's own backing
                    // storage; any Tdelegate-typed (sub)field's live
                    // `nativeDelegateSlots` registration is keyed by `element`'s
                    // own (temporary) address, so it needs the same relocation
                    // `setLocal` already does for a whole-value local binding,
                    // here to the newly appended element's real address.
                    copyStoredMetadata(
                        elementType,
                        AggregateValue.native(element).address,
                        AggregateValue.elementAddress(appended, index),
                        true,
                    );
            }
            // A native `ref T[]` parameter already names the caller's slice
            // header. Appending rebinds that header, so it must use the same
            // binding write route as ordinary assignment instead of replacing
            // only this activation's local expression handle.
            storeBinding(
                variable,
                appended,
            );
            return readBindingValue(variable);
        }
    }

    // `withAppendedArrayElement` reallocates a fresh backing block as soon
    // as the array's current block has no spare capacity -- true again
    // immediately for a freshly one-element array's second append -- and
    // copies every existing element's bytes into the new block. That plain
    // byte copy carries ordinary element bytes fine, but does not duplicate
    // each PRIOR element's `nativeDelegateSlots` registration at its new
    // address: the same gap
    // the newly appended element's own registration above needs relocating
    // for, just for every earlier element instead of only the latest one.
    // Detect the reallocation by comparing the slice's data pointer before
    // and after this iteration's append. If it moved, relocate the prior
    // storage as one byte range: symbolic entries already retain their byte
    // offsets, including entries in nested structs and static arrays. The old
    // registrations remain because another live slice may still alias the old
    // allocation.
    private void relocatePriorAppendedElementSlots(
        imported!"dmd.mtype".Type elementType,
        in const(void)* previousData,
        in ExpressionResult appended,
        in size_t count,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        if (count == 0)
            return;

        const appendedData = AggregateValue.nativeArrayAddress(appended);
        if (previousData is appendedData)
            return;

        copyStoredMetadataRange(
            cast(void*) previousData,
            cast(void*) appendedData,
            count * typeByteSize(elementType),
        );
    }

    // Appending a wide character to `string` writes its UTF-8 code units,
    // not the low byte of the code point. Native element writes require
    // spelling that conversion out before storing char-sized slots.
    private ExpressionResult[] nativeAppendElements(
        imported!"dmd.mtype".Type arrayType,
        in ExpressionResult value,
    ) {
        import dmd.astenums: TY;

        auto array = arrayType.toBasetype.isTypeDArray;
        if (array is null || array.next.toBasetype.ty != TY.Tchar || !value.isCharacter)
            return [value];

        ExpressionResult[] elements;
        foreach (character; value.asUtf8Character)
            elements ~= ExpressionResult(character);
        return elements;
    }

    private ExpressionResult runArrayConcatenateAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (assign.e1.isDotVarExp is null) {
            auto var = assign.e1.isVarExp;
            if (var is null || var.var.isVarDeclaration is null)
                throw new Exception(
                    "Unsupported interpreter array concatenate target.",
                );
        }

        const concatenated = concatenatedArray(assign.e1.type, assign.e1, assign.e2);
        writeLocation(assign.e1, concatenated);
        return concatenated;
    }

    private ExpressionResult runIndexedArrayAppendAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter array append target.");

        const current = readBindingValue(variable);

        const arrayIndex = scalarOperand!size_t(index.e2);
        const currentElement = readStoredValue(
            AggregateValue.elementAt(AggregateValue.native(current), arrayIndex),
        );
        auto literal = rhs.isFuncExp;
        const element = literal is null
            ? constructedExpressionValue(rhs)
            : runFunctionLiteralDeclaration(literal);
        const appended = ExpressionResult.nativeAggregateValue(AggregateValue.withAppendedArrayElement(
            AggregateValue.native(currentElement), element,
        ));
        writeStoredValue(bindingPlace(variable).index(arrayIndex), appended);
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return appended;
    }

    private ExpressionResult castScalarResult(
        in ExpressionResult value,
        in imported!"quickbite.backends.interpreter.runtime_casts".CastTarget target,
    ) {
        import quickbite.backends.interpreter.runtime_casts: CastTarget;

        final switch (target) with (CastTarget) {
            case bool_: return value.castTo!bool;
            case byte_: return value.castTo!byte;
            case ubyte_: return value.castTo!ubyte;
            case char_: return value.castTo!char;
            case short_: return value.castTo!short;
            case ushort_: return value.castTo!ushort;
            case wchar_: return value.castTo!wchar;
            case int_: return value.castTo!int;
            case uint_: return value.castTo!uint;
            case dchar_: return value.castTo!dchar;
            case long_: return value.castTo!long;
            case ulong_: return value.castTo!ulong;
            case float_: return value.castTo!float;
            case double_: return value.castTo!double;
            case real_: return value.castTo!real;
            case ifloat_, idouble_, ireal_: return value.castToImaginary;
            case cfloat_, cdouble_, creal_: return value.castToComplex;
        }
    }

    private ExpressionResult castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget;
        import quickbite.frontend.dmd.types: isPointerType;
        import dmd.astenums: TY;

        auto type = cast_.to.toBasetype;
        if (type is null)
            // No cast target type is known: read `cast_.e1` back through
            // its own typed place instead of the carrier, preserving the
            // pass-through value and single evaluation.
            return constructedExpressionValue(cast_.e1);

        if (type.ty == TY.Tvoid) {
            executeForEffect(cast_.e1);
            return ExpressionResult.void_;
        }

        if (type.ty == TY.Tclass)
            return classCastValue(cast_);

        if (type.ty == TY.Tident) {
            ExpressionResult value;
            if (tryIdentifierClassCastValue(cast_, value))
                return value;
        }

        if (
            type.ty == TY.Tarray &&
            type.nextOf.toBasetype.ty == TY.Tvoid
        ) {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
            import quickbite.backends.interpreter.layout: typeByteSize;

            // Read `cast_.e1` back through its own typed place -- same
            // single evaluation as the carrier read, routed through
            // `readStoredValue` instead.
            const value = constructedExpressionValue(cast_.e1);
            if (AggregateValue.isArray(value) &&
                AggregateValue.nativeArrayAddress(value) !is null)
                return ExpressionResult.nativeAggregateValue(
                    AggregateValue.borrowArrayOwner(
                        cast_.to,
                        AggregateValue.length(AggregateValue.native(value)) * typeByteSize(
                            cast_.e1.type.toBasetype.nextOf,
                        ),
                        AggregateValue.nativeArrayAddress(value),
                    ),
                );
            return value;
        }

        if (isTransparentArrayCastTarget(type)) {
            ExpressionResult reinterpreted;
            if (reinterpretScalarArrayCast(cast_, reinterpreted))
                return reinterpreted;

            // `cast(T[])staticArrayExpr` (same element type) is a full slice
            // of the static array's own storage -- the implicit cast DMD
            // inserts around `_d_arrayctor`'s arguments when lowering a
            // static-array whole-value copy. Give it the same borrowed
            // dynamic-array view an explicit `staticArrayExpr[]` gets via
            // `AggregateValue.slice`, rather than passing the untouched
            // static-array aggregate through as though the cast were a
            // no-op.
            import dmd.typesem: equivalent;

            auto sourceStaticArray = cast_.e1.type is null
                ? null
                : cast_.e1.type.toBasetype.isTypeSArray;
            if (
                sourceStaticArray !is null &&
                type.isTypeDArray !is null &&
                equivalent(sourceStaticArray.nextOf, type.nextOf)
            ) {
                import quickbite.backends.interpreter.aggregate_value:
                    AggregateValue;

                // Read `cast_.e1` back through its own typed place -- same
                // single evaluation as the carrier read, routed through
                // `readStoredValue` instead.
                const source = constructedExpressionValue(cast_.e1);
                auto sourceAggregate = AggregateValue.native(source);
                return ExpressionResult.nativeAggregateValue(
                    AggregateValue.slice(
                        sourceAggregate,
                        cast_.to,
                        0,
                        AggregateValue.length(sourceAggregate),
                    ),
                );
            }

            return constructedExpressionValue(cast_.e1);
        }

        if (type.ty == TY.Tbool)
            return boolCastValue(cast_);

        if (type.ty == TY.Tdelegate)
            return delegateCastValue(cast_);

        if (isPointerType(type))
            return pointerCastValue(cast_);

        if (auto integer = cast_.e1.isIntegerExp)
            if (integer.type !is null && integer.type.ty == TY.Tenum) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.runtime_values: integerValue;

                auto destination = Place(
                    _activationFrame.temporaryAddress(cast_),
                    cast_.to,
                );
                integerValue(integer, destination);
                return readStoredValue(destination);
            }

        // The remaining cast targets are plain scalar kinds `castScalarResult`
        // already switches on. Read `cast_.e1` back through its own typed
        // place rather than the carrier's own evaluation path -- same single
        // evaluation, with the read itself routed through typed machinery.
        return castScalarResult(
            constructedExpressionValue(cast_.e1),
            backendCastTarget(type),
        );
    }

    private bool reinterpretScalarArrayCast(
        imported!"dmd.expression".CastExp cast_,
        out ExpressionResult result,
    ) {
        import std.conv: text;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        auto sourceType = cast_.e1.type.toBasetype;
        auto targetType = cast_.to.toBasetype;
        if (!isDynamicArrayType(sourceType) || !isDynamicArrayType(targetType))
            return false;

        sourceType = sourceType.nextOf.toBasetype;
        targetType = targetType.nextOf.toBasetype;
        if (
            !isNativeScalarType(sourceType) ||
            !isNativeScalarType(targetType) ||
            typeByteSize(sourceType) != typeByteSize(targetType)
        )
            return false;

        // Read `cast_.e1` back through its own typed place -- same single
        // evaluation as the carrier read, routed through `readStoredValue`
        // instead.
        const source = constructedExpressionValue(cast_.e1);
        result = ExpressionResult.nativeAggregateValue(
            AggregateValue.borrowArrayOwner(
                cast_.to,
                AggregateValue.length(AggregateValue.native(source)),
                AggregateValue.nativeArrayAddress(source),
            ),
        );
        return true;
    }

    private ExpressionResult boolCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget;

        const value = constructedExpressionValue(cast_.e1);
        if (value.isPointer)
            return ExpressionResult(true);
        if (value == ExpressionResult.null_)
            return ExpressionResult(false);
        if (value.isNativeAggregate && AggregateValue.isArray(value))
            return ExpressionResult(isTruthy(value));

        return castScalarResult(value, backendCastTarget(cast_.to));
    }

    private ExpressionResult delegateCastValue(imported!"dmd.expression".CastExp cast_) {
        import std.conv: text;

        // Read `cast_.e1` back through its own typed place -- delegates and
        // function pointers round-trip through `writeStoredValue`'s side
        // tables there -- rather than the carrier's own evaluation path.
        // Same single evaluation as before.
        const value = constructedExpressionValue(cast_.e1);
        if (value == ExpressionResult.null_ || value.isFunctionPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    private ExpressionResult classCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.frontend.dmd.types: isPointerType;

        auto value = runExpressionValue(cast_.e1);
        value = rootedNativeClassValue(cast_.e1, value);
        if (value == ExpressionResult.null_)
            return value;

        auto classType = cast_.to.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception("Unsupported class cast target.");

        // D checks the runtime type, and yields `null` on a mismatch, only
        // when the source is itself a class or interface reference. From a
        // raw pointer the cast reinterprets the address: the storage need not
        // hold a constructed object yet, which is how `emplace` reaches the
        // instance it is about to initialise.
        if (isPointerType(cast_.e1.type)) {
            // A cast names a view onto whatever object is at the address; it
            // does not make the object one. What the object is was settled
            // when the class was established over that storage, and only
            // establishing another class there can change it -- a cast cannot
            // tell whether that has since happened, so it must not guess.
            //
            // Compiled code recovers the class from the vptr the storage
            // already holds. The interpreter keeps that identity beside the
            // address, so an address it has never seen carries none: for
            // storage reached only through a raw pointer -- foreign memory,
            // or a chunk about to be initialised -- naming the class here is
            // the only statement of what lives there, and without it every
            // later interface cast or virtual call off the result fails.
            // Record only in that case; an address that already answers is
            // left exactly as it is.
            //
            // An interface never becomes an object's class either way: it has
            // no fields of its own and names a view onto whatever object is
            // there, so a class the interface record replaced could no longer
            // resolve an implementation for a later virtual call.
            if (auto address = classIdentityAddress(value)) {
                if (
                    classType.sym.isInterfaceDeclaration is null &&
                    address !in nativeClassTypes
                )
                    nativeClassTypes[address] = classType;
            }
            return value;
        }

        // `typeid` yields the TypeInfo describing a type, and for a class or
        // interface that TypeInfo's own dynamic type is `TypeInfo_Class`, so
        // casting one to `TypeInfo_Class` (or to a base of it) succeeds and
        // keeps describing the same type. A resolved host address is a real
        // `TypeInfo_Class` unconditionally: `resolvedClassTypeInfoAddress`
        // only ever produces one for a class type, so the value's own
        // qualified name never needs recovering to confirm it.
        if (
            isClassTypeInfoClass(classType.sym) &&
            (
                value.isPointer ||
                value.isTypeName &&
                    classDeclarationByQualifiedName(value.asTypeNameString) !is null
            )
        )
            return value;

        if (!classHasType(value, className(classType.sym)))
            return ExpressionResult.null_;

        return value;
    }

    private bool tryIdentifierClassCastValue(
        imported!"dmd.expression".CastExp cast_,
        out ExpressionResult result,
    ) {
        import std.algorithm: canFind;

        if (!typeChars(cast_.to).canFind("Throwable"))
            return false;

        auto value = runExpressionValue(cast_.e1);
        value = rootedNativeClassValue(cast_.e1, value);
        if (value == ExpressionResult.null_) {
            result = value;
            return true;
        }

        if (dynamicClass(value) is null)
            return false;

        result = classHasType(value, "Throwable")
            ? value
            : ExpressionResult.null_;
        return true;
    }

    // DMD semantic lowers `array.ptr` to `cast(T*) array`
    private ExpressionResult pointerCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.frontend.dmd.types: isArrayType, isPointerType;
        import std.conv: text;

        if (isArrayType(cast_.e1.type)) {
            // `.ptr` is raw-pointer extraction, not an indexed slice read:
            // a zero-length slice still retains its backing address and may
            // be regrown through that pointer.  Read the typed header from
            // the evaluated native slice directly; `arrayPointer` remains
            // the checked address-of route for real `array[index]` places.
            if (auto var = cast_.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration) {
                    if (hasBindingPlace(variable))
                        return ExpressionResult.pointerValue(
                            bindingPlace(variable).sliceDataPointer,
                        );
                }

            // Druntime's array-growth hooks (`_d_arraysetlengthT` and
            // siblings) take a `void[]* p` parameter and read `(*p).ptr` to
            // consult the GC block-info cache before reallocating. `p`
            // itself is a plain local/parameter; the same zero-length-safe
            // bypass above applies one dereference further in -- `p`'s own
            // storage holds the pointer to dereference, and `Place.deref`
            // follows it to the array's slice-header place.
            if (auto pointer = cast_.e1.isPtrExp)
                if (auto var = pointer.e1.isVarExp)
                    if (auto variable = var.var.isVarDeclaration) {
                        if (hasBindingPlace(variable))
                            return ExpressionResult.pointerValue(
                                bindingPlace(variable).deref.sliceDataPointer,
                            );
                    }

            const value = constructedExpressionValue(cast_.e1);
            if (value.isNativeAggregate) {
                import quickbite.backends.interpreter.aggregate_value: AggregateValue;

                // `nativeArrayAddress` returning null is ambiguous: it
                // means either "not a dynamic array" or "a dynamic array
                // whose stored `ptr` is legitimately null" (a zero-length
                // slice). Checking the aggregate's own type first, rather
                // than the returned address's truthiness, tells those
                // apart -- a null `ptr` is `.ptr`'s correct answer here,
                // not a signal to fall through to the checked, throwing
                // `arrayPointer` index route below.
                auto aggregate = AggregateValue.native(value);
                if (aggregate.type.toBasetype.isTypeDArray !is null) {
                    const address = AggregateValue.nativeArrayAddress(value);
                    return address is null
                        ? ExpressionResult.null_
                        : ExpressionResult.pointerValue(cast(void*) address);
                }
            }
            return arrayPointer(cast_.e1, 0, cast_.op);
        }

        // A pointer-typed, non-array source (e.g. `cast(void*)
        // somePointer`): construct `cast_.e1` in its own typed place and
        // read its pointee address directly, the same route the
        // post-increment `*p` handler uses for a dereferenced pointer
        // operand. `address is null` mirrors the array branch above,
        // reporting a null pointer as `ExpressionResult.null_` rather than
        // a pointer value wrapping a null address.
        if (isPointerType(cast_.e1.type)) {
            const address = pointerOperandPlace(cast_.e1).deref.address;
            return address is null
                ? ExpressionResult.null_
                : ExpressionResult.pointerValue(cast(void*) address);
        }

        const value = constructedExpressionValue(cast_.e1);
        if (value == ExpressionResult.null_)
            return value;
        if (value.isPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    private ExpressionResult reconstructStoredArray(
        imported!"dmd.mtype".Type type,
        in ExpressionResult[] elements,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        auto owner = AggregateValue.allocateArray(type, elements.length);
        auto destination = Place(owner.address, type);
        foreach (index, element; elements)
            writeStoredValue(destination.index(index), element);
        return ExpressionResult.nativeAggregateValue(owner);
    }

    private bool canContainStoredMetadata(
        imported!"dmd.mtype".Type type,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.layout:
            declaredType, structFields;

        auto base = type.toBasetype;
        if (base.isTypeClass !is null || base.ty == TY.Tdelegate)
            return true;
        if (auto pointer = base.isTypePointer)
            if (pointer.nextOf.toBasetype.isTypeFunction !is null)
                return true;
        if (auto array = base.isTypeDArray)
            return canContainStoredMetadata(array.next);
        if (auto array = base.isTypeSArray)
            return canContainStoredMetadata(array.next);
        if (auto structType = base.isTypeStruct)
            foreach (field; structFields(structType))
                if (canContainStoredMetadata(declaredType(field)))
                    return true;
        return false;
    }

    // Construct a struct literal in the caller's own typed storage. Each field
    // expression constructs directly into its declared field place, in
    // declaration order. Nested array and struct literals therefore use their
    // final native-layout storage too. No aggregate is rebuilt between fields.
    // The destination must read zero wherever the literal's own fields do not
    // reach -- its padding, and the bytes of a union sibling nothing writes --
    // because freshly allocated storage gives it those bytes, and D's own
    // struct hashing and by-value ABI copies observe them.
    //
    // A field typed `delegate`, a class-typed field holding a symbolic
    // `TypeInfo`, and a field typed pointer-to-function can each carry a value
    // with no native ABI address of its own: an interpreted closure, an
    // interpreted type's `TypeInfo`, an interpreted function.
    // `place_value.writeValue` refuses all three by design -- their identity
    // lives out of band, keyed by the field's own address. The fallback path
    // writes them through `writeStoredValue`, which registers that identity
    // together with the native bytes, exactly as direct field assignment does.
    private void constructStructLiteral(
        imported!"dmd.expression".StructLiteralExp literal,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.layout: structFields;

        auto structType = destination.type.toBasetype.isTypeStruct;
        if (structType is null)
            throw new Exception(
                "Interpreter struct-literal construction needs a struct place.",
            );

        // `structFields` forces DMD's own layout, which every field place
        // below composes from (see this package's layout-authority contract).
        auto fieldDeclarations = structFields(structType);

        foreach (index, field; fieldDeclarations) {
            const hasElement = literal.elements !is null
                && index < (*literal.elements).length;
            auto element = hasElement ? (*literal.elements)[index] : null;
            auto fieldDestination = ConstructionDestination(destination.field(field));
            if (element is null) {
                // A union's default value initializes only its first member.
                // The other fields are overlapping views of those bytes, not
                // separately initialized values.
                if (index != 0 && literal.sd.isUnionDeclaration !is null)
                    fieldDestination.markConstructed;
                else
                    constructDefaultStructLiteralField(field, fieldDestination);
            } else {
                constructStructLiteralField(element, fieldDestination);
            }
        }

        bindNestedContextFrames(literal.sd, destination);
    }

    // DMD gives the missing literal field its own typed default-init
    // expression. Construct that expression directly in the field place so a
    // nested default struct or static array does not first become an aggregate
    // carrier value.
    private void constructDefaultStructLiteralField(
        imported!"dmd.declaration".VarDeclaration field,
        ref ConstructionDestination destination,
    ) {
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;

        runExpression(field.type.defaultInitLiteral(Loc.initial), destination);
    }

    // A scalar expression for a static-array field has D's broadcast
    // semantics. Construct its first element once, then copy its typed stored
    // representation into every remaining element. An array expression uses
    // the ordinary destination path and constructs each element itself.
    private void constructStructLiteralField(
        imported!"dmd.expression".Expression expression,
        ref ConstructionDestination destination,
    ) {
        auto staticArray = destination.place.type.toBasetype.isTypeSArray;
        if (
            staticArray !is null &&
            (
                expression.type is null ||
                !expression.type.toBasetype.equals(
                    destination.place.type.toBasetype,
                )
            )
        ) {
            import quickbite.backends.interpreter.layout: staticArrayLength;

            const length = staticArrayLength(staticArray);
            if (length != 0) {
                auto first = ConstructionDestination(destination.place.index(0));
                constructStructLiteralField(expression, first);
                foreach (index; 1 .. length)
                    copyPlaceValue(first.place, destination.place.index(index));
            }
            destination.markConstructed;
            return;
        }

        // A fresh closure (`() => 42`) is a bare `FuncExp`, not a
        // `DelegateExp`; construct the callable before storing it.
        if (auto functionLiteral = expression.isFuncExp) {
            writeStoredValue(
                destination.place,
                runFunctionLiteralDeclaration(functionLiteral),
            );
            destination.markConstructed;
            return;
        }

        runExpression(expression, destination);
    }

    private ExpressionResult structLiteralValue(
        imported!"dmd.expression".StructLiteralExp literal,
    ) {
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
        import quickbite.backends.interpreter.place: placeAt;

        auto storage = NativeAggregate.allocate(literal.type);
        constructStructLiteral(literal, placeAt(storage.storage, literal.type));
        return ExpressionResult.nativeAggregateValue(storage);
    }

    // A struct declared inside a function gets a hidden context field
    // (DMD's `AggregateDeclaration.vthis`) naming the enclosing activation.
    // Record the activations live right now against that field's own address,
    // so a method call on this instance can still reach them after the
    // enclosing function has returned. Nearest activation first, matching
    // `_enclosingFrames`' own order.
    private void bindNestedContextFrames(
        imported!"dmd.dstruct".StructDeclaration declaration,
        imported!"quickbite.backends.interpreter.place".Place value,
    ) {
        if (declaration is null || declaration.vthis is null)
            return;

        nestedContextFrames[value.field(declaration.vthis).address] =
            [_activationFrame] ~ _enclosingFrames;
    }

    // The captured-variable addresses a method of a function-local struct
    // must bind to: its receiver's own recorded context activations, resolved
    // per captured variable exactly as `capturedBindingAddress` resolves one
    // against the currently enclosing frames. The receiver is the authority
    // here because the enclosing function may already have returned, so this
    // walker's own frames no longer name those variables at all.
    private void*[VarDeclaration] nestedReceiverCapturedAddresses(
        imported!"dmd.func".FuncDeclaration function_,
        in ExpressionResult receiver,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;
        import quickbite.backends.interpreter.place: Place;

        if (!receiver.isNativeAggregate)
            return null;

        auto native = AggregateValue.native(receiver);
        auto structType = native.type.toBasetype.isTypeStruct;
        if (structType is null || structType.sym is null)
            return null;

        auto contextField = structType.sym.vthis;
        if (contextField is null)
            return null;

        auto frames = Place(native.address, native.type)
            .field(contextField)
            .address in nestedContextFrames;
        if (frames is null)
            return null;

        void*[VarDeclaration] addresses;
        foreach (variable; capturedVariables(function_))
            foreach (frame; *frames)
                if (frame.hasSlot(variable)) {
                    addresses[variable] = frame.bindingAddress(variable);
                    break;
                }

        return addresses;
    }

    private ExpressionResult runSliceExpression(imported!"dmd.expression".SliceExp slice) {
        size_t lower;
        return runSliceExpression(slice, lower);
    }

    private ExpressionResult runSliceExpression(
        imported!"dmd.expression".SliceExp slice,
        out size_t lower,
    ) {
        auto baseType = slice.e1.type.toBasetype;
        if (
            (baseType.isTypeSArray !is null ||
                baseType.isTypeDArray !is null) &&
            hasArrayProjectionPlace(slice.e1)
        )
            return runAddressableSliceExpression(slice, lower);

        // Pointer slicing forms a native view; it does not read the
        // pointed-to elements. Reads happen only when that view is later
        // indexed, just as they do for compiled D. Detect a pointer source
        // from the static operand type, not a runtime carrier tag:
        // `pointerOperandPlace` reads the operand's real address (null
        // included) the same way every other pointer-typed operand in this
        // file does, rather than depending on a value carrier read tagging
        // the result as `Pointer` -- a tag druntime's array-growth hooks'
        // `(auto p = cast(void*) arr.ptr; p[0 .. n])` idiom does not
        // reliably get once that read is routed through construction.
        if (baseType.isTypePointer !is null) {
            if (slice.upr is null) {
                import std.conv: text;
                throw new Exception(
                    text("Unsupported eval expression: ", slice.op),
                );
            }

            lower = slice.lwr is null
                ? 0
                : scalarOperand!size_t(slice.lwr);
            const upper = scalarOperand!size_t(slice.upr);
            if (lower > upper) {
                import std.conv: text;

                throwRangeError(text(
                    "slice [",
                    lower,
                    " .. ",
                    upper,
                    "] has a larger lower index than upper index",
                ));
            }

            import quickbite.backends.interpreter.layout: typeByteSize;

            const pointerAddress = pointerOperandPlace(slice.e1).deref.address;
            const address = cast(const(ubyte)*) pointerAddress + lower *
                typeByteSize(baseType.nextOf);
            return ExpressionResult.nativeAggregateValue(
                AggregateValue.borrowArrayOwner(
                    slice.type,
                    upper - lower,
                    address,
                ),
            );
        }

        // What remains is an array-typed source the fast path above
        // declined. A non-ref call result or a literal is a genuine rvalue
        // with no backing to preserve; nothing appends through either in
        // place. A captured (non-frame-slot) variable's closure storage has
        // no static predicate that resolves it yet either. All three read a
        // snapshot below. A struct-typed `DotVarExp` receiver -- an implicit
        // `this.field`, a deeper `this.inner.arr`, or any other chain the
        // fast path above declined -- still derives its live address just
        // below, through the same `projectionPlace` composer a direct field
        // write already uses.
        const source = runExpressionValue(slice.e1);
        if (slice.lengthVar !is null)
            setLocal(slice.lengthVar, ExpressionResult(
                AggregateValue.length(AggregateValue.native(source)),
            ));
        lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);

        const upper = slice.upr is null
            ? AggregateValue.length(AggregateValue.native(source))
            : scalarOperand!size_t(slice.upr);

        if (
            AggregateValue.isArray(source) &&
            (lower > upper || upper > AggregateValue.length(AggregateValue.native(source)))
        )
            throwRangeError("Range violation");

        auto nativeAddress = AggregateValue.nativeArrayAddress(source);
        if (auto dot = slice.e1.isDotVarExp)
            if (auto field = dot.var.isVarDeclaration) {
                // A class receiver's field has no projection place below
                // (unlike a struct receiver, already routed through
                // `runAddressableSliceExpression` or derived just below):
                // dereferencing the class reference also performs
                // dynamic-object metadata handling the projection-place
                // machinery does not replace, so it stays hand-composed
                // here.
                if (auto receiver = dot.e1.isVarExp)
                    if (auto variable = receiver.var.isVarDeclaration)
                        if (variable.type.toBasetype.isTypeClass !is null) {
                            auto place = bindingPlace(variable).deref.field(field);
                            nativeAddress = place.type.toBasetype.isTypeDArray !is null
                                ? cast(const(ubyte)*) place.sliceDataPointer
                                : cast(const(ubyte)*) place.address;
                        }

                // Every struct-typed receiver chain this tail can still
                // reach -- an implicit `this.field[a..b]`, a deeper
                // `this.inner.arr[a..b]`, or any other struct-typed chain
                // the fast path above declined -- derives the same live
                // address `projectionPlace` already composes for a direct
                // field write, recursing through the full `DotVarExp` chain
                // instead of hand-matching a single `VarExp` level.
                if (hasProjectionPlace(dot)) {
                    auto place = projectionPlace(dot);
                    nativeAddress = place.type.toBasetype.isTypeDArray !is null
                        ? cast(const(ubyte)*) place.sliceDataPointer
                        : cast(const(ubyte)*) place.address;
                }
            }
        if (nativeAddress !is null) {
            import quickbite.backends.interpreter.layout: typeByteSize;

            nativeAddress = cast(const(ubyte)*) nativeAddress + lower *
                typeByteSize(slice.e1.type.toBasetype.nextOf);
        }

        import dmd.astenums: TY;
        if (
            nativeAddress !is null &&
            slice.type.toBasetype.nextOf.toBasetype.ty == TY.Tvoid
        ) {
            import quickbite.backends.interpreter.layout: typeByteSize;

            return ExpressionResult.nativeAggregateValue(
                AggregateValue.borrowArrayOwner(
                    slice.type,
                    (upper - lower) *
                        typeByteSize(slice.e1.type.toBasetype.nextOf),
                    nativeAddress,
                ),
            );
        }
        if (
            nativeAddress !is null &&
            slice.e1.type.toBasetype.isTypeSArray !is null
        )
            return ExpressionResult.nativeAggregateValue(
                AggregateValue.borrowArrayOwner(
                    slice.type,
                    upper - lower,
                    nativeAddress,
                ),
            );
        if (!source.isNativeAggregate)
            throw new Exception("Array slice needs native aggregate storage.");
        return ExpressionResult.nativeAggregateValue(
            AggregateValue.slice(
                AggregateValue.native(source),
                slice.type,
                lower,
                upper,
            ),
        );
    }

    // Slicing an addressable array reads only its header/length and forms a
    // view over its existing bytes. Materialising the complete array first is
    // both unnecessary and wrong for a static-array field: the resulting
    // slice must alias the field, not a detached snapshot.
    private ExpressionResult runAddressableSliceExpression(
        imported!"dmd.expression".SliceExp slice,
        out size_t lower,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.layout: typeByteSize;

        materializeProjectionRoot(slice.e1);
        // Mutable because a slice exposes a writable view of this place. A
        // pointer-dereferencing receiver (druntime's `(*p).field[..]`
        // growth-hook idiom) has no direct-write projection place -- that
        // path declines pointer dereferences for its own null/provenance
        // diagnostics, irrelevant to a plain read here -- so fall back to
        // the general lvalue composer, which does resolve it.
        auto source = hasDirectWriteProjectionPlace(slice.e1)
            ? directWriteProjectionPlace(slice.e1)
            : projectionPlace(slice.e1);
        const sourceLength = source.arrayLength;
        if (slice.lengthVar !is null)
            setLocal(slice.lengthVar, ExpressionResult(sourceLength));

        lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? sourceLength
            : scalarOperand!size_t(slice.upr);
        if (lower > upper || upper > sourceLength)
            throwRangeError("Range violation");

        auto sourceType = source.type.toBasetype;
        auto data = sourceType.isTypeDArray !is null
            ? source.sliceDataPointer
            : source.address;
        const elementSize = typeByteSize(sourceType.nextOf);
        data = nativeElementAddress(data, lower, elementSize);

        const length =
            slice.type.toBasetype.nextOf.toBasetype.ty == TY.Tvoid
            ? (upper - lower) * elementSize
            : upper - lower;
        return ExpressionResult.nativeAggregateValue(
            AggregateValue.borrowArrayOwner(slice.type, length, data),
        );
    }

    private ExpressionResult runIndexExpression(imported!"dmd.expression".IndexExp index) {
        size_t arrayIndex;
        return runIndexExpression(index, arrayIndex);
    }

    // Read an element from native (C heap) memory addressed by a
    // Pointer: a snapshot ExpressionResult built from the pointee's bytes (a
    // scalar, a pointer, or a whole struct such as std.stdio.File's malloc'd
    // Impl).
    private ExpressionResult loadNativePointerElement(
        imported!"dmd.mtype".Type pointerType,
        in ExpressionResult pointer,
        in size_t index,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;

        auto elementType = pointerType.toBasetype.nextOf.toBasetype;
        auto address = nativeElementAddress(
            pointer.pointerAddress,
            index,
            typeByteSize(elementType),
        );
        return readStoredValue(Place(address, elementType));
    }

    private void storeNativePointerElement(
        imported!"dmd.mtype".Type pointerType,
        in ExpressionResult pointer,
        in size_t index,
        in ExpressionResult value,
    ) {
        import dmd.astenums: TY;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;

        auto elementType = pointerType.toBasetype.nextOf.toBasetype;
        // Indexing a `void*` addresses raw bytes, so the destination is a
        // byte: `void` itself carries no value the place codec could store.
        if (elementType.ty == TY.Tvoid)
            elementType = Type.tuns8;
        auto address = nativeElementAddress(
            pointer.pointerAddress,
            index,
            typeByteSize(elementType),
        );
        writeStoredValue(Place(address, elementType), value);
        // A native pointer can denote a still-void frame binding directly.
        // Once the first element is written, a later aggregate read must use
        // those frame bytes rather than materializing `.init` over them.
        clearUninitializedBindingAddress(pointer.pointerAddress);
    }

    // Pointer arithmetic on a native allocation the interpreted program
    // itself obtained (e.g. from malloc); no more unsafe than the compiled
    // code it mirrors.
    private static void* nativeElementAddress(
        void* base,
        in size_t index,
        in size_t elementSize,
    ) @trusted {
        return cast(void*) (cast(ubyte*) base + index * elementSize);
    }

    // A stable local/ref receiver or one of its fields lends the native call
    // its authoritative typed place. Other receiver expressions are
    // materialized once in a typed temporary by the call adapter.
    private imported!"quickbite.backends.interpreter.native_call_adapter".NativeOperand nativeReceiverOperand(
        imported!"dmd.expression".Expression receiver,
        void* precomputedAddress = null,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.native_call_adapter: NativeOperand;
        import quickbite.backends.interpreter.layout: declaredType;

        // The caller already resolved the receiver expression to the object it
        // designates (a pointer dereference, say). That address is the true
        // receiver, so the native call must write back through it rather than
        // through a copy re-derived from the expression.
        if (precomputedAddress !is null)
            return NativeOperand(receiver.type, precomputedAddress);

        if (auto variableExpression = receiver.isVarExp) {
            auto variable = variableExpression.var.isVarDeclaration;
            if (variable is null || variable.isDataseg)
                return NativeOperand.init;

            if (
                !_activationFrame.hasOwningSlot(variable) &&
                !_activationFrame.hasReferenceSlot(variable)
            )
                return NativeOperand.init;

            auto address = addressableBindingBase(variable);
            if (address is null)
                return NativeOperand.init;

            return NativeOperand(declaredType(variable), address);
        }

        auto field = receiver.isDotVarExp;
        if (field is null || receiver.type is null)
            return NativeOperand.init;

        // A field of `this` is part of the object this activation was entered
        // with, not of a copy of it, so its address is the caller's storage.
        // Lending it to the call is what lets the callee's writes to that
        // field's own members survive the return.
        if (field.e1.isThisExp !is null) {
            const thisFieldAddress = addressOfExpression(receiver, EXP.address);
            return thisFieldAddress.isPointer
                ? NativeOperand(receiver.type, thisFieldAddress.pointerAddress)
                : NativeOperand.init;
        }

        auto fieldReceiver = field.e1.isVarExp;
        if (fieldReceiver is null)
            return NativeOperand.init;

        auto variable = fieldReceiver.var.isVarDeclaration;
        if (
            variable is null ||
            variable.isDataseg ||
            (!_activationFrame.hasOwningSlot(variable) &&
                !_activationFrame.hasReferenceSlot(variable))
        )
            return NativeOperand.init;

        const address = addressOfExpression(receiver, EXP.address);
        return address.isPointer
            ? NativeOperand(receiver.type, address.pointerAddress)
            : NativeOperand.init;
    }

    // Returns a diagnostic naming a top-level associative-array type which
    // cannot cross the native ABI, or null when this call is representable.
    private string unsupportedNativeTypeMessage(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import dmd.astenums: TY;
        import dmd.mtype: TypeFunction;
        import std.conv: text;

        auto type = cast(TypeFunction) function_.type;
        if (type is null)
            return null;

        auto offending = type.next is null
            ? null
            : type.next.toBasetype.ty == TY.Taarray
                ? type.next.toBasetype
                : null;
        if (offending is null && type.parameterList.parameters !is null)
            foreach (parameter; *type.parameterList.parameters)
                if (
                    parameter.type !is null &&
                    parameter.type.toBasetype.ty == TY.Taarray
                ) {
                    offending = parameter.type.toBasetype;
                    break;
                }

        return offending is null
            ? null
            : text(
                "`",
                function_.toChars,
                "` cannot be called natively: the associative array type `",
                offending.toChars,
                "` cannot cross the FFI boundary",
            );
    }

    private ExpressionResult nativeCallValue(
        imported!"quickbite.backends.interpreter.native_call_adapter".
            NativeOperand operand,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        if (operand.address is null || operand.type is null ||
            operand.type.toBasetype.ty == TY.Tvoid)
            return ExpressionResult.void_;
        if (operand.type.toBasetype.ty == TY.Tdelegate)
            return operand.delegateMetadata.isNull
                ? ExpressionResult.null_
                : ExpressionResult.nativeDelegateValue(
                    operand.delegateMetadata.context,
                    operand.delegateMetadata.funcptr,
                );
        return readValue(Place(operand.address, operand.type));
    }

    private bool invokeNativeDeclaration(
        imported!"dmd.func".FuncDeclaration function_,
        ExpressionResult receiver,
        imported!"dmd.mtype".Type receiverType,
        imported!"dmd.expression".Expression receiverExpression,
        ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments,
        in bool returnsReceiver,
        out imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallResult result,
        void* receiverAddress = null,
        void* resultAddress = null,
    ) {
        import quickbite.backends.interpreter.native_call_adapter:
            InterpreterInboundTrampolineSession, NativeCallRequest,
            NativeOperand, invokeNative;

        auto nativeArguments = NativeCallArguments(argumentExpressions);
        scope(exit) nativeArguments.release;
        if (durableInboundSession is null)
            durableInboundSession = new InterpreterInboundTrampolineSession(
                _executionState.invokeNativeCallback,
            );
        auto receiverOperand = receiverExpression is null
            ? NativeOperand.init
            : nativeReceiverOperand(receiverExpression, receiverAddress);
        if (
            receiverType !is null && receiverOperand.address is null &&
            receiver != ExpressionResult.void_
        ) {
            import quickbite.backends.interpreter.layout:
                typeByteSize, typeHasPointers;
            import quickbite.backends.interpreter.native_block: NativeBlock;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: writeValue;

            auto temporary = NativeBlock.allocate(
                typeByteSize(receiverType),
                typeHasPointers(receiverType)
                    ? NativeBlock.Scan.conservative
                    : NativeBlock.Scan.no,
            );
            writeValue(Place(temporary.address, receiverType), receiver);
            receiverOperand = NativeOperand(
                receiverType,
                temporary.address,
                temporary,
            );
        }
        fillNativeCallOperands(
            function_,
            arguments,
            argumentExpressions,
            nativeArguments.types,
            evaluatedArguments,
            nativeArguments.operands,
            durableInboundSession,
        );
        auto request = NativeCallRequest(
            declaration: function_,
            receiverType: receiverType,
            receiverOperand: receiverOperand,
            virtualDispatch: receiverType !is null &&
                receiverType.toBasetype.isTypeClass !is null,
            returnsReceiver: returnsReceiver,
            resultAddress: resultAddress,
            argumentTypes: nativeArguments.types,
            argumentOperands: nativeArguments.operands,
            callbackSession: durableInboundSession,
        );
        return invokeNative(request, result);
    }

    // Existing lvalues and retained C-string pointers cross as typed
    // addresses. Other rvalues become typed NativeBlock temporaries in the
    // adapter.
    private void fillNativeCallOperands(
        imported!"dmd.func".FuncDeclaration function_,
        in ExpressionResult[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        imported!"dmd.mtype".Type[] argumentTypes,
        in EvaluatedReferenceArgument[] evaluatedArguments,
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeOperand[] operands,
        imported!"quickbite.backends.interpreter.native_call_adapter".
            InterpreterInboundTrampolineSession* callbackSession,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.native_call_adapter:
            InterpretedDelegate, NativeOperand;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;
        import dmd.astenums: TY;
        import dmd.tokens: EXP;

        assert(operands.length == argumentExpressions.length);
        foreach (index, expression; argumentExpressions) {
            if (auto typeid_ = expression.isTypeidExp)
                if (auto typeInfo = typeidDeclaration(typeid_)) {
                    import quickbite.ffi.ffi: resolveDataSymbol;

                    if (auto address = resolveDataSymbol(typeInfo)) {
                        auto scratch = NativeBlock.allocate(
                            (void*).sizeof,
                            NativeBlock.Scan.conservative,
                        );
                        *cast(const(void)**) scratch.address = address;
                        operands[index] = NativeOperand(
                            argumentTypes[index],
                            scratch.address,
                            scratch,
                        );
                        continue;
                    }
                }

            if (
                nativeReferenceParameter(function_, index) &&
                index < evaluatedArguments.length &&
                evaluatedArguments[index].address !is null
            ) {
                operands[index] = NativeOperand(
                    nativeParameterType(function_, index),
                    cast(void*) evaluatedArguments[index].address,
                );
                continue;
            }

            if (
                index < arguments.length &&
                index < argumentTypes.length &&
                isCharacterPointer(argumentTypes[index]) &&
                (arguments[index].isPointer || arguments[index] == ExpressionResult.null_)
            ) {
                import quickbite.backends.interpreter.place: Place;

                auto scratch = NativeBlock.allocate(
                    (void*).sizeof,
                    NativeBlock.Scan.conservative,
                );
                auto pointer = arguments[index] == ExpressionResult.null_
                    ? null
                    : arguments[index].pointerAddress;
                Place(scratch.address, argumentTypes[index])
                    .storeReference(pointer);
                operands[index] = NativeOperand(
                    argumentTypes[index],
                    scratch.address,
                    scratch,
                );
                continue;
            }

            if (
                index >= argumentTypes.length ||
                expression.type is null ||
                !expression.type.toBasetype.equals(
                    argumentTypes[index].toBasetype,
                )
            )
                continue;

            if (
                argumentTypes[index].toBasetype.ty == TY.Tdelegate &&
                arguments[index] != ExpressionResult.null_ &&
                !arguments[index].isNativeDelegate
            ) {
                operands[index] = NativeOperand(
                    argumentTypes[index],
                    null,
                    NativeBlock.init,
                    callbackSession,
                    callbackSession.register(InterpretedDelegate(
                        arguments[index].functionPointerId,
                    )),
                );
                continue;
            }

            if (hasStableLocalFieldPlace(expression)) {
                const address = addressOfExpression(expression, EXP.address);
                if (address.isPointer)
                    operands[index] = NativeOperand(
                        nativeReferenceParameter(function_, index)
                            ? nativeParameterType(function_, index)
                            : argumentTypes[index],
                        address.pointerAddress,
                    );
            }

            if (operands[index].address !is null)
                continue;

            auto temporary = NativeBlock.allocate(
                typeByteSize(argumentTypes[index]),
                typeHasPointers(argumentTypes[index])
                    ? NativeBlock.Scan.conservative
                    : NativeBlock.Scan.no,
            );
            writeValue(Place(temporary.address, argumentTypes[index]),
                arguments[index]);
            operands[index] = NativeOperand(
                argumentTypes[index],
                temporary.address,
                temporary,
            );
        }
    }

    private bool isCharacterPointer(imported!"dmd.mtype".Type type) {
        import dmd.astenums: TY;

        return type !is null &&
            type.toBasetype.ty == TY.Tpointer &&
            type.toBasetype.nextOf.toBasetype.ty == TY.Tchar;
    }

    private bool hasStableLocalFieldPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto variableExpression = expression.isVarExp) {
            auto variable = variableExpression.var.isVarDeclaration;
            return variable !is null && !variable.isDataseg &&
                (_activationFrame.hasOwningSlot(variable) ||
                    _activationFrame.hasReferenceSlot(variable));
        }
        if (auto field = expression.isDotVarExp)
            return field.var.isVarDeclaration !is null &&
                hasStableLocalFieldPlace(field.e1);
        return false;
    }

    private bool nativeReferenceParameter(
        imported!"dmd.func".FuncDeclaration function_,
        in size_t index,
    ) {
        import dmd.astenums: STC;

        auto type = function_ is null || function_.type is null
            ? null
            : function_.type.toBasetype.isTypeFunction;
        if (type is null || index >= type.parameterList.length)
            return false;
        return (type.parameterList[index].storageClass &
            (STC.ref_ | STC.out_)) != STC.none;
    }

    private imported!"dmd.mtype".Type nativeParameterType(
        imported!"dmd.func".FuncDeclaration function_,
        in size_t index,
    ) {
        auto type = function_ is null || function_.type is null
            ? null
            : function_.type.toBasetype.isTypeFunction;
        return type is null || index >= type.parameterList.length
            ? null
            : type.parameterList[index].type.toBasetype;
    }

    private imported!"dmd.declaration".TypeInfoDeclaration typeidDeclaration(
        imported!"dmd.expression".TypeidExp typeid_,
    ) {
        // `auto`: `vtinfo` is DMD-owned mutable state.
        auto type = typeidObjectType(typeid_);
        return type is null ? null : type.vtinfo;
    }

    private ExpressionResult runIndexExpression(
        imported!"dmd.expression".IndexExp index,
        out size_t arrayIndex,
    ) {
        import quickbite.frontend.dmd.types:
            isPointerType;

        // DMD's `IndexExp::semantic` (expressionsem.d) always rewrites a
        // non-modifiable `aa[key]` into `_d_aaGetRvalueX!(K, V)(aa, key)[0]`
        // (`lowerAAIndexRead`) and a modifiable one into a `_d_aaGetY` call
        // chain (`rewriteAAIndexAssign`) before the interpreter ever sees
        // this AST, so an `IndexExp` with an associative-array-typed `e1`
        // never reaches here.

        // Compose an addressable array/pointer
        // receiver once and load only the selected element. The returned
        // `ExpressionResult` remains a by-value result; call and other rvalue
        // receivers retain the original materialisation path below.
        if (
            isPointerType(index.e1.type)
                ? hasProjectionPlace(index.e1)
                : hasArrayProjectionPlace(index.e1)
        ) {
            // `auto`: `Place.index`/`arrayLength` are mutable-qualified.
            auto sourcePlace = projectionPlace(index.e1);
            if (isPointerType(index.e1.type)) {
                arrayIndex = scalarOperand!size_t(index.e2);
                if (_evaluatedReferenceArgumentIndices !is null)
                    (*_evaluatedReferenceArgumentIndices)[
                        cast(const(void)*) index.e2
                    ] = arrayIndex;
                return readStoredValue(sourcePlace.index(arrayIndex));
            }

            const sourceLength = sourcePlace.arrayLength;
            if (index.lengthVar !is null)
                setLocal(index.lengthVar, ExpressionResult(sourceLength));
            arrayIndex = scalarOperand!size_t(index.e2);
            if (_evaluatedReferenceArgumentIndices !is null)
                (*_evaluatedReferenceArgumentIndices)[
                    cast(const(void)*) index.e2
                ] = arrayIndex;
            if (arrayIndex >= sourceLength) {
                import quickbite.backends.interpreter.messages:
                    indexOutOfBoundsMessage;

                throwRangeError(indexOutOfBoundsMessage(
                    arrayIndex,
                    sourceLength,
                    isSliceValue(index.e1),
                    runningCalledFunction,
                ));
            }
            return readStoredValue(sourcePlace.index(arrayIndex));
        }

        // `$` inside index.e2 is a DollarExp bound to index.lengthVar, so it
        // must see the array's current length: run index.e1 and seed
        // lengthVar from its result before evaluating index.e2, the same
        // order runSliceExpression already uses for the same `$` binding.
        // Evaluating e2 first left lengthVar holding a stale (or default
        // zero) length, so `arr[$ - 1]` on a just-grown array underflowed to
        // size_t.max instead of the intended last-element index.
        const source = constructedExpressionValue(index.e1);
        if (isPointerType(index.e1.type)) {
            arrayIndex = scalarOperand!size_t(index.e2);
            if (_evaluatedReferenceArgumentIndices !is null)
                // Keyed by `index.e2` (the index subexpression), not the
                // outer `IndexExp` itself: `lvalue_place.placeOfLvalue`'s
                // `evalIndex` callback is invoked with `indexExpIndex(index)`
                // (`index.e2`) when composing a `ref`-argument's address
                // (`bindReferenceSlot`/`evaluatedIndex`), so a mismatched key
                // here always missed the lookup -- silently, since
                // `bindReferenceSlot` catches the resulting exception and
                // declines to bind the reference slot at all. A `ref`
                // parameter bound to `arr[runtimeVariable]` (as opposed to a
                // constant index) therefore never wrote back to the caller's
                // array: the callee mutated its own unbound local copy.
                (*_evaluatedReferenceArgumentIndices)[cast(const(void)*) index.e2] =
                    arrayIndex;

            return loadNativePointerElement(index.e1.type, source, arrayIndex);
        }

        const sourceLength = AggregateValue.length(AggregateValue.native(source));
        if (index.lengthVar !is null)
            setLocal(index.lengthVar, ExpressionResult(sourceLength));

        // matches CTFE, which formats the index as unsigned
        arrayIndex = scalarOperand!size_t(index.e2);
        if (_evaluatedReferenceArgumentIndices !is null)
            // See the `isPointerType` arm above: keyed by `index.e2`, matching
            // `evaluatedIndex`'s lookup key.
            (*_evaluatedReferenceArgumentIndices)[cast(const(void)*) index.e2] =
                arrayIndex;

        if (AggregateValue.isArray(source) && arrayIndex >= sourceLength) {
            import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;

            throwRangeError(indexOutOfBoundsMessage(
                arrayIndex,
                sourceLength,
                isSliceValue(index.e1),
                runningCalledFunction,
            ));
        }

        if (auto var = index.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration) {
                if (hasBindingPlace(variable)) {
                    import dmd.astenums: TY;
                    // A live delegate element's bytes are the all-zero ABI
                    // value (`place_value.writeValue`'s Tdelegate arm only
                    // ever accepts `ExpressionResult.null_`), so a plain `readValue`
                    // here cannot tell a genuinely null element from one
                    // whose live callable ExpressionResult was substituted out-of-band
                    // -- check `nativeDelegateSlots`, keyed by the element's
                    // own address, first, exactly as `nativeArrayElementAt`
                    // already does for the native-aggregate branch below.
                    auto elementType = index.e1.type.toBasetype.nextOf;
                    if (elementType !is null && elementType.toBasetype.ty == TY.Tdelegate)
                        if (
                            auto delegate_ = bindingPlace(variable).index(arrayIndex).address
                                in nativeDelegateSlots
                        )
                            return delegateSlotResult(*delegate_);

                    return readStoredValue(
                        bindingPlace(variable).index(arrayIndex),
                    );
                }
            }

        return nativeArrayElementAt(source, arrayIndex);
    }

    private void throwRangeError(in string message) {
        import core.exception: RangeError;

        auto native = new RangeError;
        native.msg = message;
        auto object = nativeExceptionBaseObject(
            message,
            native.classinfo.name,
            cast(void*) native,
        );
        throw new InterpretedException(object, message);
    }

    private bool isSliceValue(imported!"dmd.expression".Expression expression) {
        if (expression.isSliceExp !is null)
            return true;

        if (auto var = expression.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                if (variable._init !is null)
                    if (auto initializer = variable._init.isExpInitializer)
                        return containsSliceValue(initializer.exp);

        return false;
    }

    private bool containsSliceValue(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression is null)
            return false;
        if (expression.isSliceExp !is null)
            return true;
        if (auto cast_ = expression.isCastExp)
            return containsSliceValue(cast_.e1);
        if (auto construct = expression.isConstructExp)
            return containsSliceValue(construct.e2);
        if (auto assign = expression.isAssignExp)
            return containsSliceValue(assign.e2);
        if (auto comma = expression.isCommaExp)
            return containsSliceValue(comma.e2);
        return false;
    }

    // The single ordered route through data-pointer writes. Direct
    // dereference and compound-assignment/atomic write-back use this gate, so
    // they cannot update different interim authorities.
    private void writePointerElements(
        imported!"dmd.expression".Expression expression,
        in ExpressionResult pointer,
        in ExpressionResult[] values,
    ) {
        if (auto cast_ = expression.isCastExp) {
            writePointerElements(cast_.e1, pointer, values);
            return;
        }

        foreach (index, value; values)
            storeNativePointerElement(expression.type, pointer, index, value);
    }

    private imported!"dmd.expression".Expression addressTarget(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto cast_ = expression.isCastExp)
            return addressTarget(cast_.e1);

        if (auto address = expression.isAddrExp)
            return address.e1;

        return null;
    }

    // `new` first establishes its typed allocation, then writes only its
    // pointer, reference, or slice header into the caller's fresh place.
    // The old value path remains for native constructors, whose FFI result is
    // not address-only yet.
    private bool constructNewExpression(
        imported!"dmd.expression".NewExp new_,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.astenums: TY;
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isPointerType, isStructType;
        import std.conv: text;

        if (new_.placement !is null || new_.thisexp !is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        if (new_.type.toBasetype.ty == TY.Tclass) {
            auto type = new_.newtype is null ? new_.type : new_.newtype;
            auto object = AggregateValue.allocateClass(type);
            auto body = AggregateValue.nativeClassBodyAddress(object);
            const objectValue = ExpressionResult.nativeAggregateValue(object);
            nativeClassOwners[body] = object;
            initializeNativeClassBody(this, type, object);
            destination.storeReference(body);
            if (new_.member is null)
                return true;

            auto arguments = CallArguments(
                new_.arguments is null ? 0 : new_.arguments.length,
            );
            scope(exit) arguments.release;
            auto argumentPlaces = new Place[arguments.length];
            if (new_.arguments !is null)
                foreach (index, argument; *new_.arguments) {
                    auto argumentDestination = ConstructionDestination(Place(
                        _activationFrame.temporaryAddress(argument),
                        argument.type,
                    ));
                    runExpression(argument, argumentDestination);
                    argumentPlaces[index] = argumentDestination.place;
                    arguments.values[index] = readStoredValue(argumentDestination.place);
                }

            if (isThrowableConstructor(new_.member)) {
                nativeClassOwners[body] = applyThrowableConstructor(
                    objectValue,
                    arguments.values,
                ).nativeAggregate;
                return true;
            }

            import dmd.funcsem: functionSemantic3;
            if (!functionSemantic3(new_.member))
                throw new Exception(text("Unsupported eval expression: ", new_.op));

            Walker child;
            child.runningCalledFunction = true;
            child.currentFunction = new_.member;
            child._activationFrame = FrameBlock.allocate(cachedFrameLayout(new_.member));
            child.bindClassReceiver(body, type);
            // DMD's constructor semantic appends an implicit `return this;`;
            // route it into the receiver's own storage (already the
            // constructed object) and discard it below, same as the
            // caller's `this` binding it constructs.
            auto returnDestination = ConstructionDestination(child.thisValue);
            child._returnDestination = &returnDestination;
            child.hasThis = true;
            forkExecutionStateInto(child);
            scope(exit) child.retireActivationFrameMetadata;
            child.bindFunctionParameters(
                new_.member,
                arguments.values,
                null,
                FrameBlock.init,
                null,
                argumentPlaces,
            );
            try {
                child.runStatement(new_.member.fbody);
            } catch (InterpretedException exception) {
                mergeNewClassExpressionState(child);
                throw exception;
            }
            mergeNewClassExpressionState(child);
            return true;
        }

        if (isPointerType(new_.type)) {
            auto type = new_.type.toBasetype.nextOf;
            auto block = NativeBlock.allocate(
                typeByteSize(type),
                typeHasPointers(type)
                    ? NativeBlock.Scan.conservative
                    : NativeBlock.Scan.no,
            );
            auto allocated = ConstructionDestination(Place(block.address, type));
            if (new_.member !is null) {
                import quickbite.frontend.dmd.functions: hasNoAvailableSource;

                if (hasNoAvailableSource(new_.member))
                    return false;

                import dmd.funcsem: functionSemantic3;
                if (!functionSemantic3(new_.member))
                    throw new Exception(text("Unsupported eval expression: ", new_.op));

                runExpression(type.defaultInitLiteral(Loc.initial), allocated);
                auto arguments = CallArguments(
                    new_.arguments is null ? 0 : new_.arguments.length,
                );
                scope(exit) arguments.release;
                auto argumentPlaces = new Place[arguments.length];
                if (new_.arguments !is null)
                    foreach (index, argument; *new_.arguments) {
                        auto argumentDestination = ConstructionDestination(Place(
                            _activationFrame.temporaryAddress(argument),
                            argument.type,
                        ));
                        runExpression(argument, argumentDestination);
                        argumentPlaces[index] = argumentDestination.place;
                        arguments.values[index] = readStoredValue(argumentDestination.place);
                    }

                Walker child;
                child.runningCalledFunction = true;
                child.currentFunction = new_.member;
                child._activationFrame = FrameBlock.allocate(cachedFrameLayout(new_.member));
                child.bindStructReceiver(allocated.place);
                // DMD's constructor semantic appends an implicit `return
                // this;`; route it into the receiver's own storage (already
                // `allocated.place`) and discard it, same as the caller's
                // `this` binding it constructs.
                auto returnDestination = ConstructionDestination(child.thisValue);
                child._returnDestination = &returnDestination;
                child.hasThis = true;
                forkExecutionStateInto(child);
                scope(exit) child.retireActivationFrameMetadata;
                child.bindThisReferenceAddress(new_.member, child.thisValue);
                child.bindFunctionParameters(
                    new_.member,
                    arguments.values,
                    null,
                    FrameBlock.init,
                    null,
                    argumentPlaces,
                );
                child.runStatement(new_.member.fbody);
            } else if (new_.arguments is null) {
                runExpression(type.defaultInitLiteral(Loc.initial), allocated);
            } else if (isStructType(type)) {
                import quickbite.backends.interpreter.layout: structFields;

                runExpression(type.defaultInitLiteral(Loc.initial), allocated);
                auto fields = structFields(type.toBasetype.isTypeStruct);
                foreach (index, argument; *new_.arguments) {
                    if (index >= fields.length)
                        throw new Exception(text("Unsupported eval expression: ", new_.op));
                    auto field = ConstructionDestination(allocated.place.field(fields[index]));
                    runExpression(argument, field);
                }
            } else {
                if (new_.arguments.length != 1)
                    throw new Exception(text("Unsupported eval expression: ", new_.op));
                runExpression((*new_.arguments)[0], allocated);
            }
            destination.storeReference(block.address);
            retainTemporaryPointerOwner(block);
            return true;
        }

        if (!isDynamicArrayType(new_.type) || new_.member !is null ||
            new_.arguments is null || new_.arguments.length == 0)
            return false;

        size_t[] lengths;
        foreach (argument; *new_.arguments)
            lengths ~= scalarOperand!size_t(argument);
        constructNewArray(destination, lengths);
        return true;
    }

    // A class `this` is its body address, and nothing else. `bodyAddress`
    // is already the dereferenced body address (e.g.
    // `AggregateValue.nativeClassBodyAddress`); wrapping it as a native
    // aggregate, or storing a pointer to it, would make a later dereference
    // (`nativeClassBodyAddress` expects a reference-slot address) read
    // through a wild address. This is the one spot that spells out the
    // representation, so every class receiver construction routes through
    // it.
    private void bindClassReceiver(
        void* bodyAddress,
        imported!"dmd.mtype".Type classType,
    ) {
        thisValue = Place(bodyAddress, classType);
    }

    private void constructNewArray(
        imported!"quickbite.backends.interpreter.place".Place destination,
        in size_t[] lengths,
    ) {
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.frontend.dmd.types: arrayElementType;

        assert(lengths.length != 0);
        AggregateValue.initializeArray(destination, lengths[0]);
        auto elementType = arrayElementType(destination.type);
        foreach (index; 0 .. lengths[0]) {
            auto element = ConstructionDestination(destination.index(index));
            if (lengths.length > 1)
                constructNewArray(element.place, lengths[1 .. $]);
            else
                runExpression(elementType.defaultInitLiteral(Loc.initial), element);
        }
    }

    private ExpressionResult runNewExpression(imported!"dmd.expression".NewExp new_) {
        import dmd.astenums: TY;
        import quickbite.frontend.dmd.types: isDynamicArrayType, isPointerType, isStructType;
        import std.conv: text;

        if (new_.placement !is null || new_.thisexp !is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        if (new_.type.toBasetype.ty == TY.Tclass)
            return runNewClassExpression(new_);

        if (
            isPointerType(new_.type) &&
            isStructType(new_.type.toBasetype.nextOf)
        )
            return runNewStructPointerExpression(new_);

        if (isPointerType(new_.type))
            return runNewScalarPointerExpression(new_);

        if (
            !isDynamicArrayType(new_.type) ||
            new_.member !is null ||
            new_.arguments is null ||
            new_.arguments.length == 0
        )
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        size_t[] lengths;
        foreach (argument; *new_.arguments)
            lengths ~= scalarOperand!size_t(argument);

        return newArrayValue(new_.type, lengths);
    }

    private ExpressionResult runNewScalarPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        if (new_.member !is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        auto targetType = new_.type.toBasetype.nextOf;
        ExpressionResult value = defaultValueResult(targetType);
        if (new_.arguments !is null) {
            if (new_.arguments.length != 1)
                throw new Exception(text("Unsupported eval expression: ", new_.op));

            value = constructedExpressionValue((*new_.arguments)[0]);
        }

        return allocateNativePointer(targetType, value);
    }

    // Handles `new T(args)` where T is a struct type, returning a `T*` value.
    // When new_.member is null (no user-defined constructor) the arguments are
    // used as positional aggregate field initialisers.  When new_.member is a
    // constructor the constructor body is executed with a default-initialised
    // receiver and the post-construction `this` value is used.
    private ExpressionResult runNewStructPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto targetType = new_.type.toBasetype.nextOf;
        ExpressionResult structVal = defaultValueResult(targetType);

        if (new_.member !is null) {
            import quickbite.frontend.dmd.functions: hasNoAvailableSource;

            // A body-less native constructor cannot have its (null) body run;
            // route it through the FFI bridge so the heap struct is constructed
            // natively instead of left default-initialised.
            if (hasNoAvailableSource(new_.member))
                return runNewStructNativeConstructor(new_, targetType, structVal);

            // A non-root-module constructor may still be a raw parse tree;
            // resolve its body before walking it.
            {
                import dmd.funcsem: functionSemantic3;
                if (!functionSemantic3(new_.member))
                    throw new Exception(text("Unsupported eval expression: ", new_.op));
            }

            // User-defined constructor: run it and capture the resulting this.
            auto callArguments = CallArguments(
                new_.arguments is null ? 0 : new_.arguments.length,
            );
            scope(exit) callArguments.release;
            auto arguments = callArguments.values;
            auto argumentPlaces = new Place[arguments.length];
            if (new_.arguments !is null)
                foreach (index, argument; *new_.arguments) {
                    auto argumentDestination = ConstructionDestination(Place(
                        _activationFrame.temporaryAddress(argument),
                        argument.type,
                    ));
                    runExpression(argument, argumentDestination);
                    argumentPlaces[index] = argumentDestination.place;
                    arguments[index] = readStoredValue(argumentDestination.place);
                }

            Walker child;
            child.runningCalledFunction = true;
            child.currentFunction = new_.member;
            auto layout = cachedFrameLayout(new_.member);
            child._activationFrame = FrameBlock.allocate(layout);
            child.bindStructReceiver(Place(
                AggregateValue.native(structVal).address,
                AggregateValue.native(structVal).type,
            ));
            // DMD's constructor semantic appends an implicit `return this;`;
            // route it into the receiver's own storage and discard it, same
            // as `structVal`'s own read-back from `child.thisValue` below.
            auto returnDestination = ConstructionDestination(child.thisValue);
            child._returnDestination = &returnDestination;
            child.hasThis = true;
            forkExecutionStateInto(child);
            scope(exit) child.retireActivationFrameMetadata;
            child.bindThisReferenceAddress(new_.member, child.thisValue);
            child.bindFunctionParameters(
                new_.member,
                arguments,
                null,
                FrameBlock.init,
                null,
                argumentPlaces,
            );
            child.runStatement(new_.member.fbody);
            structVal = receiverValue(child.thisValue);
        } else if (new_.arguments !is null) {
            // Aggregate initialiser: assign arguments positionally to fields.
            // `withStoredStructField` (not the raw `AggregateValue.
            // withStructField` call `withStoredStructField` itself uses) is
            // needed here rather than a direct call: a live delegate or
            // function-pointer argument (e.g. `new Entry!(K, V)(key, value)`
            // inside interpreted druntime's own `core.internal.newaa`,
            // called with a real function pointer for `value`) is a distinct
            // `RuntimeDelegate`/`FunctionPointer` `ExpressionResult` variant,
            // not a `Pointer`, so `place_value.writeValue` throws for it --
            // `withStoredStructField` seeds the field with `null` and
            // registers the live value out-of-band instead, exactly as the
            // struct-literal and field-copy call sites already do.
            import quickbite.backends.interpreter.layout: structFields;

            auto structType = targetType.isTypeStruct;
            foreach (index, argument; *new_.arguments) {
                if (index >= structFields(structType).length)
                    throw new Exception(text(
                        "Unsupported eval expression: ", new_.op,
                    ));

                structVal = withStoredStructField(structVal,
                    targetType,
                    index,
                    constructedExpressionValue(argument),
                );
            }
        }

        return allocateNativePointer(targetType, structVal);
    }

    // `new T` establishes one GC-owned native object and returns its address.
    // Its owner remains in the enclosing expression's lexical owner scope
    // until that address reaches scanned guest storage. Guest pointer identity
    // is exactly the allocation address.
    private ExpressionResult allocateNativePointer(
        imported!"dmd.mtype".Type targetType,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.place: Place;

        auto block = NativeBlock.allocate(
            typeByteSize(targetType),
            typeHasPointers(targetType)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );
        writeStoredValue(Place(block.address, targetType), value, true);
        retainTemporaryPointerOwner(block);
        return ExpressionResult.pointerValue(block.address);
    }

    // `new T(args)` where T's constructor is a body-less native leaf: construct
    // the struct through the FFI bridge (seeding `this` from `.init`) and return
    // a pointer to the constructed value.
    private ExpressionResult runNewStructNativeConstructor(
        imported!"dmd.expression".NewExp new_,
        imported!"dmd.mtype".Type targetType,
        in ExpressionResult initValue,
    ) {
        import quickbite.frontend.dmd.functions: noAvailableSourceMessage;
        import quickbite.backends.interpreter.native_call_adapter:
            NativeCallException, NativeCallResult;
        import dmd.expression: Expression;

        auto callArguments = CallArguments(
            new_.arguments is null ? 0 : new_.arguments.length,
        );
        scope(exit) callArguments.release;
        auto arguments = callArguments.values;
        auto argumentExpressions = callArguments.expressions;
        if (new_.arguments !is null)
            foreach (index, argument; *new_.arguments) {
                auto argumentDestination = ConstructionDestination(Place(
                    _activationFrame.temporaryAddress(argument),
                    argument.type,
                ));
                runExpression(argument, argumentDestination);
                arguments[index] = readStoredValue(argumentDestination.place);
                argumentExpressions[index] = argument;
            }

        try {
            NativeCallResult nativeResult;
            if (invokeNativeDeclaration(
                new_.member,
                nativeConstructorReceiver(new_.member, initValue),
                targetType.isTypeStruct,
                null,
                arguments,
                argumentExpressions,
                null,
                true,
                nativeResult,
            ))
                return allocateNativePointer(
                    targetType,
                    nativeCallValue(nativeResult.value),
                );
        } catch (NativeCallException exception) {
            throwNativeException(exception);
        }

        throw new Exception(noAvailableSourceMessage(new_.member));
    }

    private ExpressionResult runNewClassExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto allocationType = new_.newtype is null ? new_.type : new_.newtype;
        auto classType = allocationType.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        auto callArguments = CallArguments(
            new_.arguments is null ? 0 : new_.arguments.length,
        );
        scope(exit) callArguments.release;
        auto arguments = callArguments.values;
        auto argumentPlaces = new Place[arguments.length];
        if (new_.arguments !is null)
            foreach (index, argument; *new_.arguments) {
                auto argumentDestination = ConstructionDestination(Place(
                    _activationFrame.temporaryAddress(argument),
                    argument.type,
                ));
                runExpression(argument, argumentDestination);
                argumentPlaces[index] = argumentDestination.place;
                arguments[index] = readStoredValue(argumentDestination.place);
            }

        auto object = AggregateValue.allocateClass(allocationType);
        const objectValue = ExpressionResult.nativeAggregateValue(object);
        nativeClassOwners[AggregateValue.nativeClassBodyAddress(object)] = object;
        initializeNativeClassBody(this, allocationType, object);
        if (new_.member is null)
            return objectValue;

        if (isThrowableConstructor(new_.member))
            return applyThrowableConstructor(objectValue, arguments);

        // A non-root-module constructor (e.g. a private phobos class) may
        // still be a raw parse tree; resolve its body before walking it.
        {
            import dmd.funcsem: functionSemantic3;
            if (!functionSemantic3(new_.member))
                throw new Exception(text("Unsupported eval expression: ", new_.op));
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = new_.member;
        auto layout = cachedFrameLayout(new_.member);
        child._activationFrame = FrameBlock.allocate(layout);
        forkExecutionStateInto(child);
        scope(exit) child.retireActivationFrameMetadata;
        child.bindClassReceiver(AggregateValue.nativeClassBodyAddress(object), allocationType);
        // DMD's constructor semantic appends an implicit `return this;`;
        // route it into the receiver's own storage and discard it, same as
        // `objectValue` returned below.
        auto returnDestination = ConstructionDestination(child.thisValue);
        child._returnDestination = &returnDestination;
        child.hasThis = true;
        child.bindFunctionParameters(
            new_.member,
            arguments,
            null,
            FrameBlock.init,
            null,
            argumentPlaces,
        );
        try {
            child.runStatement(new_.member.fbody);
        } catch (InterpretedException exception) {
            mergeNewClassExpressionState(child);
            throw exception;
        }
        mergeNewClassExpressionState(child);
        return objectValue;
    }

    private void mergeNewClassExpressionState(ref Walker child) {
        mergeLazyArgumentMapsFrom(child);
    }

    private ExpressionResult newArrayValue(
        imported!"dmd.mtype".Type type,
        in size_t[] lengths,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.types: arrayElementType;
        import std.conv: text;

        // `auto` because DMD returns a mutable class reference
        auto elementType = arrayElementType(type);
        if (elementType is null)
            throw new Exception(text("Unsupported eval expression: ", EXP.new_));

        ExpressionResult[] elements;
        foreach (_; 0 .. lengths[0])
            elements ~= lengths.length > 1
                ? newArrayValue(elementType, lengths[1 .. $])
                : defaultValueResult(elementType);

        return reconstructStoredArray(type, elements);
    }

    // Decision 7's no-result operation for a declaration: the initializer
    // constructs the variable's own storage and there is no value left over
    // to hand back (`runExpressionValue`'s `declarationExpression` arm).
    //
    // Mirrors `Dsymbol_toElem` in DMD's `e2ir.d`: once construction succeeds,
    // arm the variable's destructor (`vd.edtor`) so it runs at a later
    // full-expression boundary, the same as any other constructed temporary.
    // `constructDeclaredVariable` throws on failed construction, so a
    // throwing constructor never reaches the arming below -- matching the
    // oracle fact that a throwing constructor's destructor does not run.
    private void executeDeclaration(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        constructDeclaredVariable(declaration);

        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null || !shouldArmDeclaredVariableDestructor(variable))
            return;

        queueTemporaryDestructor(variable.edtor);
    }

    // A declared local's destructor is armed here unless: it is a manifest
    // constant (no storage, nothing to destroy); it is left uninitialised by
    // a `= void` initializer (an uninitialised binding holds no value to
    // destroy); its initializer is a literal zero blit (`variable = 0`, how
    // DMD default-initialises a provably all-zero struct or static-array
    // local that is never bound to a later constructor call -- mirrors
    // `constructDeclaredVariable`'s own static-array/struct zero-blit arm,
    // which likewise treats this shape as already a complete default value
    // rather than something to run an initializer for); or DMD itself has
    // already arranged its destruction, which `needsScopeDtor` -- `edtor &&
    // !(storage_class & STC.nodtor)` -- reports as false. DMD sets
    // `STC.nodtor` ("don't add in dtor again", `statementsem.d`'s
    // scope-statement lowering) on a local whose destruction it moved into a
    // `DtorExpStatement`; without this guard that local would be destroyed
    // twice.
    //
    // This says nothing about a constructor-call receiver
    // (`((S __t = <placeholder>;) , __t).__ctor(args)`): whether that
    // placeholder declaration reports true here depends on how
    // `<placeholder>` prints. A field-by-field literal placeholder (a struct
    // with a non-zero default, e.g. `Loud(0, true, null)`) is a `BlitExp`
    // whose `e2` is not an `IntegerExp`, so it reports true here like any
    // other locally-owned value with a destructor, because at this point
    // `__t`'s own assignment (not the constructor) has just succeeded. A
    // caller that is about to invoke that same constructor on `__t` must not
    // trust this arming yet -- see `popPrematureReceiverConstructorDestructor`.
    // An all-zero placeholder (e.g. `Zero(0)`) is instead the `IntegerExp`
    // zero blit the guard above declines, so it reports false here and
    // nothing is armed at declaration time; the constructor's own success
    // arms it afterwards instead, through `constructedReceiverDestructor`'s
    // own decline check on this same function.
    private bool shouldArmDeclaredVariableDestructor(VarDeclaration variable) {
        if (isManifestVariable(variable))
            return false;

        if (variable._init !is null && variable._init.isVoidInitializer !is null)
            return false;

        auto initializer = variable._init !is null
            ? variable._init.isExpInitializer
            : null;
        if (initializer !is null) {
            if (initializer.exp.isVoidInitExp !is null)
                return false;

            if (auto blit = initializer.exp.isBlitExp)
                if (blit.e2.isIntegerExp !is null)
                    return false;
        }

        return variable.needsScopeDtor;
    }

    // Decision 7's construction: writes the declaration's initializer into
    // the variable's own storage. Unchanged behaviour, just named for reuse
    // by `executeDeclaration`, which arms the variable's destructor after
    // this returns successfully.
    private void constructDeclaredVariable(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return;

        if (isManifestVariable(variable)) {
            // A manifest constant has no storage to initialise. Its
            // initializer is already folded by semantic analysis, so the walk
            // exists only for a side effect DMD left in it.
            if (auto initializer = variable._init.isExpInitializer)
                executeForEffect(initializer.exp);
            return;
        }

        if (_activationFrame.hasReferenceSlot(variable))
            _activationFrame.setReferenceSlot(variable, null);

        if (variable._init !is null && variable._init.isVoidInitializer !is null) {
            markUninitializedBinding(variable);
            return;
        }

        if (variable._init is null || variable._init.isExpInitializer is null) {
            defaultLocalValue(variable);
            return;
        }

        auto initializer = variable._init.isExpInitializer.exp;
        if (auto assign = initializer.isAssignExp)
            initializer = assign.e2;
        else if (auto construct = initializer.isConstructExp)
            initializer = construct.e2;
        else if (auto blit = initializer.isBlitExp) {
            import quickbite.frontend.dmd.types: isStaticArrayType, isStructType;

            // DMD default-initialises static array locals with `variable[] = 0`
            // or, for synthesized lifetime code, `variable = 0`.
            if (
                isStaticArrayType(variable.type) &&
                (
                    blit.e1.isSliceExp !is null ||
                    blit.e2.isIntegerExp !is null
                )
            ) {
                setLocal(variable, runDefaultValue(variable.type));
                return;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                setLocal(variable, runDefaultValue(variable.type));
                return;
            }

            initializer = blit.e2;
        }

        if (initializer.isVoidInitExp !is null) {
            markUninitializedBinding(variable);
            return;
        }

        // `auto copy = original;` for a struct with a postblit lowers to
        // `(copy = original).__postblit()` as the initializer
        // (`expressionsem.d`'s `ConstructExp` handling): a `DotVarExp` call
        // whose receiver is a `BlitExp` blitting the source into the
        // variable's own storage, then calling the postblit on those
        // now-placed bytes for its effect alone. Construct the source
        // directly into the binding place -- the same bytes the blit would
        // have produced -- then run the postblit for effect on that place,
        // mirroring the element-postblit call in the `_d_arrayctor`
        // interception above.
        if (auto postblitCall = initializer.isCallExp)
            if (
                postblitCall.f !is null &&
                postblitCall.f.isPostBlitDeclaration !is null
            ) {
                import quickbite.frontend.dmd.functions:
                    hasNoInterpretableSource, noAvailableSourceMessage;
                import quickbite.backends.interpreter.layout: typeByteSize;
                import quickbite.backends.interpreter.native_aggregate:
                    NativeAggregate;
                import quickbite.backends.interpreter.native_block: NativeBlock;
                import quickbite.backends.interpreter.native_call_adapter:
                    NativeCallException, NativeCallResult;

                auto receiverBlit = postblitCall.e1.isDotVarExp.e1.isBlitExp;
                auto place = bindingPlace(variable);
                auto destination = ConstructionDestination(place);
                runExpression(receiverBlit.e2, destination);
                clearUninitializedBindingAddress(place.address);

                if (hasNoInterpretableSource(postblitCall.f)) {
                    // A body-less native postblit's FFI bridge runs against
                    // the receiver storage at `place.address`; it hands back
                    // its mutated receiver as the call's own result rather
                    // than always writing through that address in place (the
                    // ABI may return a small struct in registers instead), so
                    // a result reported at a different address still needs
                    // copying into the binding.
                    try {
                        NativeCallResult nativeResult;
                        if (!invokeNativeDeclaration(
                            postblitCall.f,
                            ExpressionResult.void_,
                            place.type,
                            receiverBlit.e1,
                            [],
                            [],
                            null,
                            true,
                            nativeResult,
                            place.address,
                            place.address,
                        ))
                            throw new Exception(
                                noAvailableSourceMessage(postblitCall.f),
                            );
                        if (nativeResult.value.address != place.address)
                            writeStoredValue(place, nativeCallValue(nativeResult.value));
                    } catch (NativeCallException exception) {
                        throwNativeException(exception);
                    }
                    return;
                }

                const receiver = ExpressionResult.nativeAggregateValue(
                    NativeAggregate(
                        place.type,
                        NativeBlock.borrow(place.address, typeByteSize(place.type)),
                    ));
                runMemberFunction(postblitCall.f, null, receiver, [], []);
                return;
            }

        // `T[N] dest = src` for an element type with a postblit lowers to a
        // `_d_arrayctor(cast(T[])dest, cast(T[])src)` call
        // (`expressionsem.d`'s `ConstructExp` handling), not a plain blit.
        // Interpreting that generic druntime template body would recurse
        // into `core.lifetime.copyEmplace`'s TypeInfo-driven machinery,
        // which the interpreter has no honest way to execute for an
        // interpreted (non-native) element type -- it corrupts the native
        // call's argument addresses instead of copying. Block-copy the
        // source's bytes directly into the destination's own storage
        // (the same byte copy `writeValue` already performs for a
        // same-typed static-array source), then run the element postblit on
        // each copied element -- mirroring `compileArrayConstructor`'s
        // identical `_d_arrayctor` interception in the bytecode core
        // compiler. A struct with only a copy constructor or only a
        // destructor (no postblit) also lowers this way; that shape is left
        // to the generic call path below, unchanged.
        if (auto arrayCtorCall = initializer.isCallExp)
            if (
                arrayCtorCall.f !is null &&
                arrayCtorCall.f.ident !is null &&
                arrayCtorCall.f.ident.toString == "_d_arrayctor" &&
                arrayCtorCall.arguments !is null &&
                arrayCtorCall.arguments.length >= 2
            ) {
                auto elementStruct =
                    variable.type.toBasetype.nextOf.toBasetype.isTypeStruct;
                auto postblit = elementStruct is null
                    ? null
                    : elementStruct.sym.postblit;
                if (postblit !is null && hasBindingPlace(variable)) {
                    import quickbite.backends.interpreter.layout:
                        staticArrayLength, typeByteSize;
                    import quickbite.backends.interpreter.native_aggregate:
                        NativeAggregate;
                    import quickbite.backends.interpreter.native_block:
                        NativeBlock;

                    auto sourceArray = (*arrayCtorCall.arguments)[1];
                    while (auto sourceCast = sourceArray.isCastExp)
                        sourceArray = sourceCast.e1;

                    const source = constructedExpressionValue(sourceArray);
                    setLocal(variable, source);

                    const count =
                        staticArrayLength(variable.type.toBasetype.isTypeSArray);
                    foreach (i; 0 .. count) {
                        auto elementPlace = bindingPlace(variable).index(i);
                        const elementReceiver = ExpressionResult.nativeAggregateValue(
                            NativeAggregate(
                                elementPlace.type,
                                NativeBlock.borrow(
                                    elementPlace.address,
                                    typeByteSize(elementPlace.type),
                                ),
                            ));
                        runMemberFunction(postblit, null, elementReceiver, [], []);
                    }

                    return;
                }
            }

        if (isRefVariable(variable)) {
            import dmd.tokens: EXP;

            const pointer = addressOfExpression(initializer, EXP.address);
            if (!pointer.isPointer)
                throw new Exception("Reference initializer has no native place.");
            _activationFrame.setReferenceSlot(variable, pointer.pointerAddress);
            clearUninitializedBindingAddress(pointer.pointerAddress);
            return;
        }

        import quickbite.frontend.dmd.types: isDynamicArrayType;

        if (initializer.isNullExp !is null && isDynamicArrayType(variable.type)) {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;

            setLocal(variable, reconstructStoredArray(variable.type, []));
            return;
        }

        if (auto slice = initializer.isSliceExp) {
            size_t lower;
            setLocal(variable, runSliceExpression(slice, lower));
            return;
        }

        // The initializer constructs the variable's own storage: a fresh
        // binding has no aliases, so its initializer may construct directly
        // into it, typed by the binding itself (decision 7's permitted
        // direct construction, not decision 9's assignment-temporary rule).
        auto destination = ConstructionDestination(bindingPlace(variable));
        runExpression(initializer, destination);
        clearUninitializedBindingAddress(bindingPlace(variable).address);
    }

    // Decision 7's construction operation: `rvalue` writes its value into
    // `destination`'s own storage, so no other storage is allocated to hold it
    // and nothing is copied afterwards. Answers `false` for an expression
    // family that has no destination arm yet, which leaves the caller's value
    // path in charge of it (`value.md` item 10's queue).
    //
    // Only a caller whose destination is not yet live may ask for this. D
    // evaluates an assignment's right-hand side before the assignment itself,
    // so a live lvalue must not receive a partially constructed value: an
    // alias could observe it (decision 7). A declaration initialises the
    // variable's own fresh storage, which is exactly the case that qualifies,
    // and DMD marks it as such with a `ConstructExp`.
    private bool constructInto(
        imported!"dmd.expression".Expression rvalue,
        ref ConstructionDestination destination,
    ) {
        if (!destination.isFresh)
            throw new Exception(
                "quickbite.backends.interpreter.impl.Walker.constructInto: "
                ~ "destination is not fresh",
            );

        auto place = destination.place;

        if (auto conditional = rvalue.isCondExp) {
            if (conditionTruthy(conditional.econd))
                runExpression(conditional.e1, destination);
            else
                runExpression(conditional.e2, destination);
            return true;
        }

        if (auto new_ = rvalue.isNewExp)
            if (constructNewExpression(new_, place)) {
                destination.markConstructed;
                return true;
            }

        if (constructPointerExpressionInto(rvalue, place)) {
            destination.markConstructed;
            return true;
        }

        if (constructDereferenceInto(rvalue, place)) {
            destination.markConstructed;
            return true;
        }

        if (constructPointerDifferenceInto(rvalue, place)) {
            destination.markConstructed;
            return true;
        }

        if (auto cast_ = rvalue.isCastExp) {
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.runtime_casts:
                CastTarget, castTarget, castValue, tryCastTarget;

            // `castValue` below only converts between the scalar kinds
            // `CastTarget` enumerates. A destination type passing
            // `tryCastTarget` says nothing about the source: casts such as
            // `cast(size_t) somePointerOrClassRef` (e.g. inside druntime's
            // `emplace`) have a scalar destination but a pointer or class
            // source, which `castValue` cannot handle. Require the source
            // type to pass the same check before committing to this arm, so
            // an unsupported source falls through to the fallback path that
            // already reinterprets pointer and class references as scalars.
            //
            // `target` must come from `cast_.to`, not `place.type`: they
            // normally agree, but DMD's `.im` property lowering
            // (`typesem.d`'s `TypeBasic.dotExp`) builds a `CastExp` whose
            // `.to` is the true cast target (the imaginary component type)
            // and then overwrites `.type` back to the matching real type so
            // the property reads as a real, not an imaginary, value. Casting
            // by `place.type` there would extract the real part instead of
            // the imaginary part.
            CastTarget target;
            CastTarget sourceTarget;
            if (
                cast_.to !is null &&
                cast_.e1.type !is null &&
                tryCastTarget(cast_.to, target) &&
                tryCastTarget(cast_.e1.type, sourceTarget)
            ) {
                auto source = Place(
                    _activationFrame.temporaryAddress(cast_.e1),
                    cast_.e1.type,
                );
                auto sourceDestination = ConstructionDestination(source);
                runExpression(cast_.e1, sourceDestination);
                castValue(source, target, place);
                destination.markConstructed;
                return true;
            }
        }

        if (auto integer = rvalue.isIntegerExp) {
            import dmd.astenums: TY;
            import quickbite.backends.interpreter.native_scalar:
                isNativeScalarType;

            auto type = place.type.toBasetype;
            if (!isNativeScalarType(place.type) &&
                type.ty != TY.Tpointer)
                goto destinationFallback;

            import quickbite.backends.interpreter.runtime_values: integerValue;

            integerValue(integer, place);
            destination.markConstructed;
            return true;
        }

        if (auto real_ = rvalue.isRealExp) {
            import quickbite.backends.interpreter.native_scalar:
                isNativeScalarType;

            if (!isNativeScalarType(place.type))
                goto destinationFallback;

            import quickbite.backends.interpreter.runtime_values: realValue;

            realValue(real_, place);
            destination.markConstructed;
            return true;
        }

        if (auto slice = rvalue.isSliceExp)
            if (constructSliceInto(slice, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto arrayLength = rvalue.isArrayLengthExp)
            if (constructArrayLengthInto(arrayLength, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto index = rvalue.isIndexExp)
            if (constructIndexInto(index, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto call = rvalue.isCallExp) {
            import dmd.astenums: TY;

            if (call.type.toBasetype.ty == TY.Tvoid)
                return false;

            const result = runCallExpression(call, &destination);
            if (!destination.isConstructed) {
                writeStoredValue(place, result);
                destination.markConstructed;
            }
            return true;
        }

        // A delegate literal and a bare `&function` mint interpreter-only
        // callable identity with no native ABI address of their own.
        // Construct straight into the destination's `nativeDelegateSlots`/
        // `nativeFunctionPointerSlots` entry via `writeStoredValue` instead
        // of falling through to the general carrier-returning walk.
        if (auto delegate_ = rvalue.isDelegateExp) {
            writeStoredValue(place, runDelegateExpression(delegate_));
            destination.markConstructed;
            return true;
        }

        if (auto symbol = rvalue.isSymOffExp)
            if (auto function_ = symbol.var.isFuncDeclaration) {
                writeStoredValue(place, functionPointerValue(function_));
                destination.markConstructed;
                return true;
            }

        if (auto literal = rvalue.isStructLiteralExp) {
            // The literal's own fields must BE the destination's fields: a
            // conversion between two struct types is a value operation
            // (`storageValue`), not a construction, and composing one type's
            // field offsets onto the other's storage would write the wrong
            // bytes.
            auto structType = place.type.toBasetype.isTypeStruct;
            if (
                literal.sd !is null &&
                structType !is null &&
                structType.sym is literal.sd
            ) {
                // This activation may have used this storage for an earlier
                // value of the same binding, whose bytes are still there;
                // `constructStructLiteral` requires the zeroes that freshly
                // allocated storage would have given it.
                clearPlaceValue(place);
                constructStructLiteral(literal, place);
                destination.markConstructed;
                return true;
            }
        }

        if (auto literal = rvalue.isArrayLiteralExp) {
            if (
                literal.type !is null &&
                place.type.toBasetype.equals(literal.type.toBasetype)
            ) {
                constructArrayLiteral(literal, place);
                destination.markConstructed;
                return true;
            }
        }

        if (auto string_ = rvalue.isStringExp) {
            constructStringLiteral(string_, place);
            destination.markConstructed;
            return true;
        }

        // A copy of an aggregate lvalue: the source's own bytes are the value,
        // so copying them from its place is the whole construction. The value
        // path instead materialises a second copy of the source, in storage
        // whose only purpose is to be copied out of again. A struct with a
        // postblit or a copy constructor never reaches here: DMD lowers its
        // copy into an explicit call, which the arms above this one handle.
        if (isAggregateCopySource(rvalue, place.type)) {
            copyPlaceValue(projectionPlace(rvalue), place);
            destination.markConstructed;
            return true;
        }

destinationFallback:
        return false;
    }

    // Array literals construct the header and elements in the caller's typed
    // storage. Each element keeps DMD's source order, including sparse
    // literals whose null entry repeats `basis`. A child without a direct
    // construction arm still uses the established value fallback locally.
    private void constructArrayLiteral(
        imported!"dmd.expression".ArrayLiteralExp literal,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        const length = literal.elements is null ? 0 : (*literal.elements).length;
        AggregateValue.initializeArray(destination, length);
        if (literal.elements is null)
            return;

        foreach (index, element; *literal.elements) {
            auto source = element is null ? literal.basis : element;
            auto elementDestination = ConstructionDestination(destination.index(index));
            if (auto functionLiteral = source.isFuncExp) {
                writeStoredValue(
                    elementDestination.place,
                    runFunctionLiteralDeclaration(functionLiteral),
                );
                elementDestination.markConstructed;
            } else {
                runExpression(source, elementDestination);
            }
        }
    }

    // An addressable array receiver already owns its header or fixed extent.
    // Read that length directly into the caller's typed scalar destination.
    // Other receiver shapes still need the value path because they first
    // produce an aggregate value before its length can be observed.
    private bool constructArrayLengthInto(
        imported!"dmd.expression".ArrayLengthExp arrayLength,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        if (
            arrayLength.type is null ||
            !destination.type.toBasetype.equals(arrayLength.type.toBasetype) ||
            !isNativeScalarType(destination.type) ||
            !hasArrayProjectionPlace(arrayLength.e1)
        )
            return false;

        const length = projectionPlace(arrayLength.e1).arrayLength;
        storeLength(destination, length);
        return true;
    }

    // An addressable index composes the receiver place once, evaluates its
    // index once, and copies the selected typed bytes into fresh caller-owned
    // storage. The static result type must retain the element representation:
    // a cast mismatch follows the established value fallback instead.
    private bool constructIndexInto(
        imported!"dmd.expression".IndexExp index,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        if (
            index.type is null ||
            !destination.type.toBasetype.equals(index.type.toBasetype) ||
            !(isPointerType(index.e1.type)
                ? hasProjectionPlace(index.e1)
                : hasArrayProjectionPlace(index.e1))
        )
            return false;

        // `auto`: `Place.index` and `Place.arrayLength` are mutable-qualified.
        auto source = projectionPlace(index.e1);
        const pointer = isPointerType(index.e1.type);
        const length = pointer ? 0 : source.arrayLength;
        if (!pointer && index.lengthVar !is null)
            setLocal(index.lengthVar, ExpressionResult(length));

        const arrayIndex = scalarOperand!size_t(index.e2);
        if (_evaluatedReferenceArgumentIndices !is null)
            (*_evaluatedReferenceArgumentIndices)[cast(const(void)*) index.e2] =
                arrayIndex;

        if (!pointer && arrayIndex >= length) {
            import quickbite.backends.interpreter.messages:
                indexOutOfBoundsMessage;

            throwRangeError(indexOutOfBoundsMessage(
                arrayIndex,
                length,
                isSliceValue(index.e1),
                runningCalledFunction,
            ));
        }

        copyPlaceValue(source.index(arrayIndex), destination);
        return true;
    }

    // This is the scalar half of decision 11. DMD has already selected an
    // exact static type for every expression, so this dispatcher selects a
    // corresponding host local. It is deliberately not a tagged value type:
    // a recursive operand is constructed in its typed activation temporary,
    // loaded into T, and consumed before the next operand is evaluated.
    private bool constructScalarExpressionInto(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.astenums: TY;
        if (expression.type is null || destination.type is null ||
            !destination.type.toBasetype.equals(expression.type.toBasetype))
            return false;

        switch (destination.type.toBasetype.ty) with (TY) {
            case Tbool: return constructScalar!bool(expression, destination);
            case Tint8: return constructScalar!byte(expression, destination);
            case Tuns8: return constructScalar!ubyte(expression, destination);
            case Tchar: return constructScalar!char(expression, destination);
            case Tint16: return constructScalar!short(expression, destination);
            case Tuns16: return constructScalar!ushort(expression, destination);
            case Twchar: return constructScalar!wchar(expression, destination);
            case Tint32: return constructScalar!int(expression, destination);
            case Tuns32: return constructScalar!uint(expression, destination);
            case Tdchar: return constructScalar!dchar(expression, destination);
            case Tint64: return constructScalar!long(expression, destination);
            case Tuns64: return constructScalar!ulong(expression, destination);
            case Tfloat32: return constructScalar!float(expression, destination);
            case Tfloat64: return constructScalar!double(expression, destination);
            case Tfloat80: return constructScalar!real(expression, destination);
            case Timaginary32: return constructScalar!ifloat(expression, destination);
            case Timaginary64: return constructScalar!idouble(expression, destination);
            case Timaginary80: return constructScalar!ireal(expression, destination);
            case Tcomplex32: return constructComplex!cfloat(expression, destination);
            case Tcomplex64: return constructComplex!cdouble(expression, destination);
            case Tcomplex80: return constructComplex!creal(expression, destination);
            default: return false;
        }
    }

    // A data pointer is already the host address that D code observes. Keep
    // that address in its typed place throughout recursive construction; do
    // not convert it to a scalar or a carrier on the way.
    private bool constructPointerExpressionInto(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.types: isPointerType;

        if (
            expression.type is null ||
            destination.type.toBasetype.isTypePointer is null ||
            !destination.type.toBasetype.equals(expression.type.toBasetype)
        )
            return false;

        // Function pointers retain their symbolic callable metadata. They
        // are not data pointers and stay on their existing path.
        if (destination.type.toBasetype.nextOf.toBasetype.isTypeFunction !is null)
            return false;

        if (expression.isNullExp !is null) {
            destination.storeReference(null);
            return true;
        }

        if (auto address = expression.isAddrExp) {
            if (auto pointer = address.e1.isPtrExp) {
                destination.storeReference(pointerOperandPlace(pointer.e1).deref.address);
                return true;
            }
            if (hasProjectionPlace(address.e1)) {
                destination.storeReference(projectionPlace(address.e1).address);
                return true;
            }
            return false;
        }

        if (auto cast_ = expression.isCastExp) {
            if (isPointerType(cast_.e1.type)) {
                destination.storeReference(pointerOperandPlace(cast_.e1).deref.address);
                return true;
            }

            // A dereferenced array-typed operand (druntime's `(*p).ptr`
            // growth-hook idiom, `p: void[]*`) may legitimately answer a
            // null pointer for an empty slice -- its backing address is
            // still meaningful and distinct from "no value". Storing that
            // address through this typed `Place` and reading it back
            // collapses a null pointer to the untyped
            // `ExpressionResult.null_`, the same conversion every other
            // pointer-typed place read applies, indistinguishable here from
            // a real absence. `pointerCastValue`'s own `PtrExp` bypass avoids
            // exactly that collapse by wrapping the address directly in
            // `ExpressionResult.pointerValue` regardless of nullness, so
            // decline this shape and let it answer instead.
            if (
                hasArrayProjectionPlace(cast_.e1) &&
                cast_.e1.isPtrExp is null
            ) {
                destination.storeReference(projectionPlace(cast_.e1).sliceDataPointer);
                return true;
            }
            return false;
        }

        if (hasDirectWriteProjectionPlace(expression)) {
            destination.storeReference(
                directWriteProjectionPlace(expression).deref.address,
            );
            return true;
        }

        if (auto index = expression.isIndexExp) {
            if (!isPointerType(index.e1.type))
                return false;

            auto source = pointerOperandPlace(index.e1);
            const indexValue = pointerIndexOperand(index.e2);
            destination.storeReference(source.index(indexValue).deref.address);
            return true;
        }

        if (auto binary = expression.isBinExp) {
            void* base;
            long delta;
            if (expression.op == EXP.add) {
                if (isPointerType(binary.e1.type)) {
                    base = pointerOperandPlace(binary.e1).deref.address;
                    delta = pointerOffsetOperand(binary.e2);
                } else if (isPointerType(binary.e2.type)) {
                    base = pointerOperandPlace(binary.e2).deref.address;
                    delta = pointerOffsetOperand(binary.e1);
                } else {
                    return false;
                }
                destination.storeReference(offsetPointerAddress(base, delta));
                return true;
            }
            if (expression.op == EXP.min && isPointerType(binary.e1.type)) {
                base = pointerOperandPlace(binary.e1).deref.address;
                delta = pointerOffsetOperand(binary.e2);
                destination.storeReference(offsetPointerAddress(base, -delta));
                return true;
            }
        }

        return false;
    }

    // DMD leaves pointer subtraction as a byte-address difference and emits
    // the element-size division around it. Compute that difference directly
    // from host addresses, without an intermediate pointer representation.
    private bool constructPointerDifferenceInto(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.types: isPointerType;

        auto subtract = expression.isBinExp;
        if (
            subtract is null || expression.op != EXP.min ||
            !isPointerType(subtract.e1.type) || !isPointerType(subtract.e2.type)
        )
            return false;

        const left = pointerOperandPlace(subtract.e1).deref.address;
        const right = pointerOperandPlace(subtract.e2).deref.address;
        storePointerDifference(destination, pointerAddressDifference(left, right));
        return true;
    }

    // A dereference reads the value at the pointed-to native address. The
    // address itself remains the pointer representation; copying from this
    // typed place handles scalars, pointers, and aggregates without a value
    // carrier. Keep a null dereference on the old diagnostic path rather than
    // faulting while composing a raw host place.
    private bool constructDereferenceInto(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isPointerType;

        auto pointer = expression.isPtrExp;
        if (
            pointer is null || !isPointerType(pointer.e1.type) ||
            expression.type is null ||
            !destination.type.toBasetype.equals(expression.type.toBasetype)
        )
            return false;

        auto source = pointerOperandPlace(pointer.e1).deref;
        if (source.address is null)
            return false;

        // `e1`'s own pointee type is the dereference's declared type, but an
        // implicit qualification-only conversion (e.g. `void*` read through
        // a `const(void*)` context) retypes this PtrExp in place without
        // wrapping it in a cast node, so `expression.type` can carry a
        // stricter qualifier than `e1`'s pointee. That qualifier is already
        // verified compatible with `destination` above; copy at that type
        // rather than `e1`'s, or `copyFromUnchecked`'s exact-base-type check
        // rejects a same-layout, differently-qualified pointer.
        copyPlaceValue(Place(source.address, expression.type), destination);
        return true;
    }

    // Construct a pointer operand in its own typed activation storage. The
    // slot carries both its static pointer type and a collector-visible
    // reference, while its dereferenced address is the sole data value.
    private imported!"quickbite.backends.interpreter.place".Place pointerOperandPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);
        return destination.place;
    }

    private size_t pointerIndexOperand(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;

        switch (expression.type.toBasetype.ty) with (TY) {
            case Tint8: return cast(size_t) scalarOperand!byte(expression);
            case Tuns8, Tchar: return scalarOperand!ubyte(expression);
            case Tint16: return cast(size_t) scalarOperand!short(expression);
            case Tuns16, Twchar: return scalarOperand!ushort(expression);
            case Tint32: return cast(size_t) scalarOperand!int(expression);
            case Tuns32, Tdchar: return scalarOperand!uint(expression);
            case Tint64: return cast(size_t) scalarOperand!long(expression);
            case Tuns64: return cast(size_t) scalarOperand!ulong(expression);
            default: throw new Exception("Pointer index has a non-integral type.");
        }
    }

    private long pointerOffsetOperand(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;

        switch (expression.type.toBasetype.ty) with (TY) {
            case Tint8: return scalarOperand!byte(expression);
            case Tuns8, Tchar: return scalarOperand!ubyte(expression);
            case Tint16: return scalarOperand!short(expression);
            case Tuns16, Twchar: return scalarOperand!ushort(expression);
            case Tint32: return scalarOperand!int(expression);
            case Tuns32, Tdchar: return scalarOperand!uint(expression);
            case Tint64: return scalarOperand!long(expression);
            case Tuns64: return cast(long) scalarOperand!ulong(expression);
            default: throw new Exception("Pointer offset has a non-integral type.");
        }
    }

    private void storePointerDifference(
        imported!"quickbite.backends.interpreter.place".Place destination,
        in long difference,
    ) {
        import dmd.astenums: TY;

        switch (destination.type.toBasetype.ty) with (TY) {
            case Tint8: destination.storeNativeScalar(cast(byte) difference); return;
            case Tuns8, Tchar: destination.storeNativeScalar(cast(ubyte) difference); return;
            case Tint16: destination.storeNativeScalar(cast(short) difference); return;
            case Tuns16, Twchar: destination.storeNativeScalar(cast(ushort) difference); return;
            case Tint32: destination.storeNativeScalar(cast(int) difference); return;
            case Tuns32, Tdchar: destination.storeNativeScalar(cast(uint) difference); return;
            case Tint64: destination.storeNativeScalar(difference); return;
            case Tuns64: destination.storeNativeScalar(cast(ulong) difference); return;
            default: throw new Exception("Pointer difference has a non-integral type.");
        }
    }

    // @trusted: the guest has already requested raw-pointer arithmetic; this
    // is the matching byte offset on its real host address.
    private static void* offsetPointerAddress(void* address, in long delta) @trusted {
        return cast(void*) (cast(ubyte*) address + delta);
    }

    // @trusted: both operands are the host addresses stored in real guest
    // pointer slots; subtraction produces their byte-address difference.
    private static long pointerAddressDifference(
        const(void)* left,
        const(void)* right,
    ) @trusted {
        return cast(long) (cast(ubyte*) left - cast(ubyte*) right);
    }

    private bool constructScalar(T)(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.tokens: EXP;
        import std.traits: Unsigned, isFloatingPoint, isIntegral;

        if (auto integer = expression.isIntegerExp) {
            destination.storeNativeScalar(cast(T) integer.getInteger);
            return true;
        }
        if (auto real_ = expression.isRealExp) {
            static if (is(T == ifloat))
                destination.storeNativeScalar(cast(float) real_.toImaginary);
            else static if (is(T == idouble))
                destination.storeNativeScalar(cast(double) real_.toImaginary);
            else static if (is(T == ireal))
                destination.storeNativeScalar(cast(real) real_.toImaginary);
            else
                destination.storeNativeScalar(cast(T) real_.toReal);
            return true;
        }
        if (auto cast_ = expression.isCastExp)
            return constructScalarCast!T(cast_, destination);
        if (hasDirectWriteProjectionPlace(expression)) {
            // The projection's semantic type is the expression's exact type,
            // so this is an exact-width load into the selected host local.
            // This is a read, not an assignment target: an out-of-bounds
            // index here must raise the same call-depth-sensitive wording
            // `runIndexExpression` raises for the same read outside a
            // projection place, not the write path's unconditional
            // compiled-style wording.
            destination.storeNativeScalar(
                directWriteProjectionPlace(expression, /* writeBounds */ false)
                    .loadNativeScalar!T,
            );
            return true;
        }
        if (auto not = expression.isNotExp) {
            destination.storeNativeScalar(cast(T) !conditionTruthy(not.e1));
            return true;
        }
        if (auto logical = expression.isLogicalExp) {
            const left = conditionTruthy(logical.e1);
            if (logical.op == EXP.andAnd && !left) {
                destination.storeNativeScalar(cast(T) false);
                return true;
            }
            if (logical.op == EXP.orOr && left) {
                destination.storeNativeScalar(cast(T) true);
                return true;
            }
            const first = _pendingTemporaryDestructors.length;
            scope(exit) runPendingTemporaryDestructors(first);
            destination.storeNativeScalar(cast(T) conditionTruthy(logical.e2));
            return true;
        }
        if (auto equal = expression.isEqualExp) {
            if (!hasScalarEqualityOperands(equal))
                return false;
            const same = scalarEquality(equal);
            destination.storeNativeScalar(cast(T) (
                equal.op == EXP.notEqual ? !same : same
            ));
            return true;
        }
        switch (expression.op) with (EXP) {
            case lessThan:
            case lessOrEqual:
            case greaterThan:
            case greaterOrEqual:
                auto comparison = cast(imported!"dmd.expression".CmpExp) expression;
                if (comparison is null || !hasScalarComparisonOperands(comparison))
                    return false;
                destination.storeNativeScalar(cast(T) scalarComparison(comparison));
                return true;
            default:
                break;
        }

        static if (isIntegral!T && !is(T == bool)) {
            if (auto neg = expression.isNegExp) {
                destination.storeNativeScalar(-scalarOperand!T(neg.e1));
                return true;
            }
            if (auto complement = expression.isComExp) {
                destination.storeNativeScalar(~scalarOperand!T(complement.e1));
                return true;
            }
            if (auto pow = expression.isPowExp) {
                // PowExp is itself a BinExp, so this must run before the
                // generic isBinExp arm below or that arm's `default: return
                // false` would shadow it. Square-and-multiply, casting back
                // to T after every multiply so each step's truncation
                // matches the destination type exactly as DMD's own CTFE
                // evaluator does.
                T factor = scalarOperand!T(pow.e1);
                auto exponent = scalarOperand!long(pow.e2);
                if (exponent < 0)
                    throw new Exception("Unsupported negative integer exponent.");

                T result = 1;
                while (exponent != 0) {
                    if ((exponent & 1) != 0)
                        result = cast(T) (result * factor);
                    exponent >>= 1;
                    if (exponent != 0)
                        factor = cast(T) (factor * factor);
                }
                destination.storeNativeScalar(result);
                return true;
            }
            if (auto binary = expression.isBinExp) {
                // Only these ops are handled below; every other BinExp
                // subclass (e.g. CommaExp, produced by druntime's array
                // append/idup machinery) must fall through unevaluated
                // rather than have its operands constructed here.
                switch (expression.op) with (EXP) {
                    case add, min, mul, div, mod, leftShift, rightShift,
                         unsignedRightShift, or, and, xor:
                        break;
                    default:
                        return false;
                }
                const left = scalarOperand!T(binary.e1);
                const right = scalarOperand!T(binary.e2);
                switch (expression.op) with (EXP) {
                    case add: destination.storeNativeScalar(left + right); return true;
                    case min: destination.storeNativeScalar(left - right); return true;
                    case mul: destination.storeNativeScalar(left * right); return true;
                    case div:
                        rejectIntMinMinusOneOverflow(left, right, "/");
                        destination.storeNativeScalar(left / right);
                        return true;
                    case mod:
                        rejectIntMinMinusOneOverflow(left, right, "%");
                        destination.storeNativeScalar(left % right);
                        return true;
                    case leftShift: destination.storeNativeScalar(left << right); return true;
                    case rightShift: destination.storeNativeScalar(left >> right); return true;
                    case unsignedRightShift:
                        // A cast straight to ulong would sign-extend a
                        // negative signed T before shifting. Reinterpret at
                        // T's own width first so the vacated bits zero-fill.
                        destination.storeNativeScalar(
                            cast(T) (cast(Unsigned!T) left >> right),
                        );
                        return true;
                    case or: destination.storeNativeScalar(left | right); return true;
                    case and: destination.storeNativeScalar(left & right); return true;
                    case xor: destination.storeNativeScalar(left ^ right); return true;
                    default: assert(0, "unreachable: filtered above");
                }
            }
        } else static if (isFloatingPoint!T) {
            if (auto neg = expression.isNegExp) {
                destination.storeNativeScalar(-scalarOperand!T(neg.e1));
                return true;
            }
            if (auto binary = expression.isBinExp) {
                // See the integral binary arm above: dispatch on the op
                // before touching operands so unhandled BinExp subclasses
                // (e.g. CommaExp) fall through untouched.
                switch (expression.op) with (EXP) {
                    case add, min, mul, div:
                        break;
                    default:
                        return false;
                }
                const left = scalarOperand!T(binary.e1);
                const right = scalarOperand!T(binary.e2);
                switch (expression.op) with (EXP) {
                    case add: destination.storeNativeScalar(left + right); return true;
                    case min: destination.storeNativeScalar(left - right); return true;
                    case mul: destination.storeNativeScalar(left * right); return true;
                    case div: destination.storeNativeScalar(left / right); return true;
                    default: assert(0, "unreachable: filtered above");
                }
            }
        } else static if (is(T == ifloat) || is(T == idouble) || is(T == ireal)) {
            // isFloatingPoint discounts imaginary types, so they need their
            // own branch. Negation is the only scalar imaginary operator
            // reaching this function: imaginary arithmetic ends up complex
            // or real and is constructed by constructComplex or the
            // isFloatingPoint branch above instead.
            if (auto neg = expression.isNegExp) {
                destination.storeNativeScalar(-scalarOperand!T(neg.e1));
                return true;
            }
        }

        return false;
    }

    private void rejectIntMinMinusOneOverflow(T)(
        in T left,
        in T right,
        in string operator,
    ) const {
        static if (is(T == int)) {
            import std.conv: text;

            if (left != int.min || right != -1)
                return;

            throw new Exception(text(
                "integer overflow: `int.min ",
                operator,
                " -1`\ncannot compare `__error` at compile time",
            ));
        }
    }

    // A complex expression can combine a complex left operand with an
    // imaginary right operand. Construct each operand at its DMD-selected
    // type before converting it to the complex host local; an imaginary
    // place is narrower than its complex destination.
    private bool constructComplex(T)(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.tokens: EXP;

        if (auto cast_ = expression.isCastExp)
            return constructComplexCast!T(cast_, destination);

        if (hasDirectWriteProjectionPlace(expression)) {
            destination.storeNativeScalar(
                directWriteProjectionPlace(expression).loadNativeScalar!T,
            );
            return true;
        }

        if (auto neg = expression.isNegExp) {
            destination.storeNativeScalar(-complexOperand!T(neg.e1));
            return true;
        }

        if (auto binary = expression.isBinExp) {
            // See constructScalar's integral binary arm: dispatch on the op
            // before touching operands so unhandled BinExp subclasses (e.g.
            // CommaExp) fall through untouched.
            switch (expression.op) with (EXP) {
                case add, min, mul, div:
                    break;
                default:
                    return false;
            }
            const left = complexOperand!T(binary.e1);
            const right = complexOperand!T(binary.e2);
            switch (expression.op) with (EXP) {
                case add: destination.storeNativeScalar(left + right); return true;
                case min: destination.storeNativeScalar(left - right); return true;
                case mul: destination.storeNativeScalar(left * right); return true;
                case div: destination.storeNativeScalar(left / right); return true;
                default: assert(0, "unreachable: filtered above");
            }
        }

        return false;
    }

    private bool constructComplexCast(T)(
        imported!"dmd.expression".CastExp cast_,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        if (cast_.e1 is null)
            return false;

        destination.storeNativeScalar(complexOperand!T(cast_.e1));
        return true;
    }

    private T complexOperand(T)(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;

        switch (expression.type.toBasetype.ty) with (TY) {
            case Tbool: return cast(T) scalarOperand!bool(expression);
            case Tint8: return cast(T) scalarOperand!byte(expression);
            case Tuns8: return cast(T) scalarOperand!ubyte(expression);
            case Tchar: return cast(T) scalarOperand!char(expression);
            case Tint16: return cast(T) scalarOperand!short(expression);
            case Tuns16: return cast(T) scalarOperand!ushort(expression);
            case Twchar: return cast(T) scalarOperand!wchar(expression);
            case Tint32: return cast(T) scalarOperand!int(expression);
            case Tuns32: return cast(T) scalarOperand!uint(expression);
            case Tdchar: return cast(T) scalarOperand!dchar(expression);
            case Tint64: return cast(T) scalarOperand!long(expression);
            case Tuns64: return cast(T) scalarOperand!ulong(expression);
            case Tfloat32: return cast(T) scalarOperand!float(expression);
            case Tfloat64: return cast(T) scalarOperand!double(expression);
            case Tfloat80: return cast(T) scalarOperand!real(expression);
            case Timaginary32: return cast(T) scalarOperand!ifloat(expression);
            case Timaginary64: return cast(T) scalarOperand!idouble(expression);
            case Timaginary80: return cast(T) scalarOperand!ireal(expression);
            case Tcomplex32: return cast(T) scalarOperand!cfloat(expression);
            case Tcomplex64: return cast(T) scalarOperand!cdouble(expression);
            case Tcomplex80: return cast(T) scalarOperand!creal(expression);
            default: throw new Exception("Unsupported complex operand type.");
        }
    }

    private bool constructScalarCast(T)(
        imported!"dmd.expression".CastExp cast_,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.astenums: TY;

        if (cast_.e1 is null || cast_.e1.type is null)
            return false;

        switch (cast_.e1.type.toBasetype.ty) with (TY) {
            case Tbool: return convertScalarCast!(T, bool)(cast_.e1, destination);
            case Tint8: return convertScalarCast!(T, byte)(cast_.e1, destination);
            case Tuns8: return convertScalarCast!(T, ubyte)(cast_.e1, destination);
            case Tchar: return convertScalarCast!(T, char)(cast_.e1, destination);
            case Tint16: return convertScalarCast!(T, short)(cast_.e1, destination);
            case Tuns16: return convertScalarCast!(T, ushort)(cast_.e1, destination);
            case Twchar: return convertScalarCast!(T, wchar)(cast_.e1, destination);
            case Tint32: return convertScalarCast!(T, int)(cast_.e1, destination);
            case Tuns32: return convertScalarCast!(T, uint)(cast_.e1, destination);
            case Tdchar: return convertScalarCast!(T, dchar)(cast_.e1, destination);
            case Tint64: return convertScalarCast!(T, long)(cast_.e1, destination);
            case Tuns64: return convertScalarCast!(T, ulong)(cast_.e1, destination);
            case Tfloat32: return convertScalarCast!(T, float)(cast_.e1, destination);
            case Tfloat64: return convertScalarCast!(T, double)(cast_.e1, destination);
            case Tfloat80: return convertScalarCast!(T, real)(cast_.e1, destination);
            default: return false;
        }
    }

    private bool convertScalarCast(T, S)(
        imported!"dmd.expression".Expression source,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        const value = scalarOperand!S(source);
        destination.storeNativeScalar(cast(T) value);
        return true;
    }

    private T scalarOperand(T)(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;

        // The enclosing operation's common type can differ from this
        // operand's static type. First construct and load the operand at its
        // own DMD type, then let the host cast perform D's conversion.
        switch (expression.type.toBasetype.ty) with (TY) {
            case Tbool: return cast(T) scalarOperandAs!bool(expression);
            case Tint8: return cast(T) scalarOperandAs!byte(expression);
            case Tuns8: return cast(T) scalarOperandAs!ubyte(expression);
            case Tchar: return cast(T) scalarOperandAs!char(expression);
            case Tint16: return cast(T) scalarOperandAs!short(expression);
            case Tuns16: return cast(T) scalarOperandAs!ushort(expression);
            case Twchar: return cast(T) scalarOperandAs!wchar(expression);
            case Tint32: return cast(T) scalarOperandAs!int(expression);
            case Tuns32: return cast(T) scalarOperandAs!uint(expression);
            case Tdchar: return cast(T) scalarOperandAs!dchar(expression);
            case Tint64: return cast(T) scalarOperandAs!long(expression);
            case Tuns64: return cast(T) scalarOperandAs!ulong(expression);
            case Tfloat32: return cast(T) scalarOperandAs!float(expression);
            case Tfloat64: return cast(T) scalarOperandAs!double(expression);
            case Tfloat80: return cast(T) scalarOperandAs!real(expression);
            case Timaginary32: return cast(T) scalarOperandAs!ifloat(expression);
            case Timaginary64: return cast(T) scalarOperandAs!idouble(expression);
            case Timaginary80: return cast(T) scalarOperandAs!ireal(expression);
            case Tcomplex32: return cast(T) scalarOperandAs!cfloat(expression);
            case Tcomplex64: return cast(T) scalarOperandAs!cdouble(expression);
            case Tcomplex80: return cast(T) scalarOperandAs!creal(expression);
            default: throw new Exception("Unsupported scalar operand type.");
        }
    }

    private T scalarOperandAs(T)(imported!"dmd.expression".Expression expression) {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);
        return destination.place.loadNativeScalar!T;
    }

    // DMD has already fixed the condition's type. Construct it in a typed
    // activation slot, then inspect that type's native representation. This
    // keeps branch selection outside the universal expression carrier.
    private bool conditionTruthy(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;

        import quickbite.backends.interpreter.place: Place;

        // A void-typed operand has no truth value to construct: D allows
        // `cond && voidCall();` as sugar for `if (cond) voidCall();`, and
        // DMD's own arm-temporary destructor guard (`flag && edtor`, see
        // `expressionsem.d`) reuses the same `&&` node with the temporary's
        // void-returning destructor call as its right operand. Either way
        // the caller only ever discards this operand's boolean result, so
        // run it for effect instead of constructing it into a typed place.
        if (expression.type.toBasetype.ty == TY.Tvoid) {
            executeForEffectImpl(expression);
            return true;
        }

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);
        switch (expression.type.toBasetype.ty) with (TY) {
            case Tbool: return destination.place.loadNativeScalar!bool;
            case Tint8: return destination.place.loadNativeScalar!byte != 0;
            case Tuns8, Tchar: return destination.place.loadNativeScalar!ubyte != 0;
            case Tint16: return destination.place.loadNativeScalar!short != 0;
            case Tuns16, Twchar: return destination.place.loadNativeScalar!ushort != 0;
            case Tint32: return destination.place.loadNativeScalar!int != 0;
            case Tuns32, Tdchar: return destination.place.loadNativeScalar!uint != 0;
            case Tint64: return destination.place.loadNativeScalar!long != 0;
            case Tuns64: return destination.place.loadNativeScalar!ulong != 0;
            case Tfloat32: return destination.place.loadNativeScalar!float != 0;
            case Tfloat64: return destination.place.loadNativeScalar!double != 0;
            case Tfloat80: return destination.place.loadNativeScalar!real != 0;
            case Tpointer, Tclass, Taarray:
                return destination.place.deref.address !is null;
            case Tarray: return destination.place.sliceDataPointer !is null;
            default:
                throw new Exception("Unsupported condition type.");
        }
    }

    private bool scalarComparison(imported!"dmd.expression".CmpExp comparison) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;

        // Comparison operands share DMD's common arithmetic type. Dispatching
        // on that stamped type preserves unsigned 64-bit values and narrow
        // signed overflow rather than widening them through a carrier.
        switch (comparison.e1.type.toBasetype.ty) with (TY) {
            case Tint8: return compareScalars!byte(comparison);
            case Tuns8, Tchar: return compareScalars!ubyte(comparison);
            case Tint16: return compareScalars!short(comparison);
            case Tuns16, Twchar: return compareScalars!ushort(comparison);
            case Tint32: return compareScalars!int(comparison);
            case Tuns32, Tdchar: return compareScalars!uint(comparison);
            case Tint64: return compareScalars!long(comparison);
            case Tuns64: return compareScalars!ulong(comparison);
            case Tfloat32: return compareScalars!float(comparison);
            case Tfloat64: return compareScalars!double(comparison);
            case Tfloat80: return compareScalars!real(comparison);
            default: return false;
        }
    }

    private bool hasScalarComparisonOperands(
        imported!"dmd.expression".CmpExp comparison,
    ) {
        import dmd.astenums: TY;

        switch (comparison.e1.type.toBasetype.ty) with (TY) {
            case Tint8:
            case Tuns8:
            case Tchar:
            case Tint16:
            case Tuns16:
            case Twchar:
            case Tint32:
            case Tuns32:
            case Tdchar:
            case Tint64:
            case Tuns64:
            case Tfloat32:
            case Tfloat64:
            case Tfloat80:
                return true;
            default:
                return false;
        }
    }

    // `EqualExp` and `IdentityExp` both stamp their operands with a
    // reconciled comparison type (`dcast.d`'s `typeCombine`), so a scalar
    // pair's static type -- read off the shared `BinExp` base -- is what
    // decides both whether a fast typed compare applies and, in
    // `scalarEquality`, which host type to load it at. `is` never rewrites
    // for operator overloading the way `==` does, so this same check and
    // load serve `runIdentityExpression` too.
    private bool hasScalarEqualityOperands(
        imported!"dmd.expression".BinExp binary,
    ) {
        import dmd.astenums: TY;

        switch (binary.e1.type.toBasetype.ty) with (TY) {
            case Tbool:
            case Tint8:
            case Tuns8:
            case Tchar:
            case Tint16:
            case Tuns16:
            case Twchar:
            case Tint32:
            case Tuns32:
            case Tdchar:
            case Tint64:
            case Tuns64:
            case Tfloat32:
            case Tfloat64:
            case Tfloat80:
                return true;
            default:
                return false;
        }
    }

    private bool scalarEquality(imported!"dmd.expression".BinExp binary) {
        import dmd.astenums: TY;

        // DMD stamps the operands with the common comparison type. Construct
        // each one in its own typed place so this comparison does not use the
        // migration carrier to recover its scalar representation.
        switch (binary.e1.type.toBasetype.ty) with (TY) {
            case Tbool: return equalScalars!bool(binary);
            case Tint8: return equalScalars!byte(binary);
            case Tuns8, Tchar: return equalScalars!ubyte(binary);
            case Tint16: return equalScalars!short(binary);
            case Tuns16, Twchar: return equalScalars!ushort(binary);
            case Tint32: return equalScalars!int(binary);
            case Tuns32, Tdchar: return equalScalars!uint(binary);
            case Tint64: return equalScalars!long(binary);
            case Tuns64: return equalScalars!ulong(binary);
            case Tfloat32: return equalScalars!float(binary);
            case Tfloat64: return equalScalars!double(binary);
            case Tfloat80: return equalScalars!real(binary);
            default: assert(0, "equality expression has a non-scalar operand");
        }
    }

    private bool equalScalars(T)(imported!"dmd.expression".BinExp binary) {
        return scalarOperand!T(binary.e1) == scalarOperand!T(binary.e2);
    }

    private bool compareScalars(T)(imported!"dmd.expression".CmpExp comparison) {
        import dmd.tokens: EXP;

        const left = scalarOperand!T(comparison.e1);
        const right = scalarOperand!T(comparison.e2);
        switch (comparison.op) with (EXP) {
            case lessThan: return left < right;
            case lessOrEqual: return left <= right;
            case greaterThan: return left > right;
            case greaterOrEqual: return left >= right;
            default: assert(0, "comparison expression has a non-comparison op");
        }
    }

    private void storeLength(
        imported!"quickbite.backends.interpreter.place".Place destination,
        in size_t length,
    ) {
        import dmd.astenums: TY;

        switch (destination.type.toBasetype.ty) with (TY) {
            case Tint8: destination.storeNativeScalar(cast(byte) length); return;
            case Tuns8, Tchar: destination.storeNativeScalar(cast(ubyte) length); return;
            case Tint16: destination.storeNativeScalar(cast(short) length); return;
            case Tuns16, Twchar: destination.storeNativeScalar(cast(ushort) length); return;
            case Tint32: destination.storeNativeScalar(cast(int) length); return;
            case Tuns32, Tdchar: destination.storeNativeScalar(cast(uint) length); return;
            case Tint64: destination.storeNativeScalar(cast(long) length); return;
            case Tuns64: destination.storeNativeScalar(cast(ulong) length); return;
            default: throw new Exception("Array length has a non-integral type.");
        }
    }

    private void constructStringLiteral(
        imported!"dmd.expression".StringExp string_,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.runtime_string_literals:
            stringValue;

        NativeBlock pointerStorage;
        NativeBlock backingStorage;
        stringValue(string_, destination, pointerStorage, backingStorage);
        if (pointerStorage.address !is null)
            retainTemporaryPointerOwner(pointerStorage);
        if (backingStorage.address !is null)
            retainTemporaryPointerOwner(backingStorage);
    }

    // A slice initializer is a native header construction.  When its source
    // has an authoritative place, write the new header directly into the
    // caller's destination.  This keeps the slice's backing bytes as the
    // only storage authority and avoids an aggregate result carrier.
    private bool constructSliceInto(
        imported!"dmd.expression".SliceExp slice,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        if (
            !hasDirectWriteProjectionPlace(slice.e1) ||
            !hasArrayProjectionPlace(slice.e1)
        )
            return false;

        import dmd.astenums: TY;
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.layout: typeByteSize;

        materializeProjectionRoot(slice.e1);
        auto source = directWriteProjectionPlace(slice.e1);
        const sourceLength = source.arrayLength;
        if (slice.lengthVar !is null)
            setLocal(slice.lengthVar, ExpressionResult(sourceLength));

        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? sourceLength
            : scalarOperand!size_t(slice.upr);
        if (lower > upper || upper > sourceLength)
            throwRangeError("Range violation");

        auto sourceType = source.type.toBasetype;
        auto data = sourceType.isTypeDArray !is null
            ? source.sliceDataPointer
            : source.address;
        const elementSize = typeByteSize(sourceType.nextOf);
        data = nativeElementAddress(data, lower, elementSize);

        const length =
            slice.type.toBasetype.nextOf.toBasetype.ty == TY.Tvoid
            ? (upper - lower) * elementSize
            : upper - lower;
        NativeArray.borrow(
            slice.type.toBasetype.nextOf,
            cast(void*) data,
            length,
        ).writeSliceHeader(destination.address);
        return true;
    }

    // An lvalue whose complete value is the bytes at its own place, of the
    // destination's exact type. A class reference is excluded: its value is an
    // object identity whose owning allocation the value path retains
    // (`rootedNativeClassValue`). A slice, associative array, or pointer is
    // excluded for the same reason -- the bytes at the place are a handle into
    // storage the aggregate result retains as well.
    //
    // `hasDirectWriteProjectionPlace`, not the broader `hasProjectionPlace`,
    // for the same reason its own callers use it: a source reached through a
    // pointer dereference keeps the value path, whose dereference reports a
    // pointer carrying no live address (`dereferencePointerValue`) instead of
    // composing that address and reading it. Reading it would fault, which
    // ends the process rather than failing one unittest, and no assertion can
    // observe a fault -- so the reporting engines are the ones a fixture can
    // pin (`lang/diagnostics.d`'s null-dereference block). The shapes this
    // excludes fire nowhere in the test corpus or the dub gate, so the value
    // path keeps them at no measurable cost.
    private bool isAggregateCopySource(
        imported!"dmd.expression".Expression rvalue,
        imported!"dmd.mtype".Type destinationType,
    ) {
        if (rvalue.type is null || destinationType is null)
            return false;

        auto type = destinationType.toBasetype;
        if (type.isTypeStruct is null && type.isTypeSArray is null)
            return false;

        return type.equals(rvalue.type.toBasetype) &&
            hasDirectWriteProjectionPlace(rvalue);
    }

    // Leave a typed place holding no value at all: zero bytes and no
    // out-of-band callable or symbolic identity, the same state freshly
    // allocated storage arrives in.
    private void clearPlaceValue(
        imported!"quickbite.backends.interpreter.place".Place place,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place_value: clearPlace;

        clearStoredMetadataRange(place.address, typeByteSize(place.type));
        clearPlace(place);
    }

    // Copy one typed place's complete value into another: the native bytes
    // plus the out-of-band identity of any callable or symbolic slot inside
    // them, which is part of the value in that byte range and stays registered
    // at the source as well (`copyStoredMetadata`'s own value-copy rule).
    private void copyPlaceValue(
        imported!"quickbite.backends.interpreter.place".Place source,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        copyStoredMetadata(
            destination.type,
            cast(void*) source.address,
            destination.address,
        );
        destination.copyFromUnchecked(source);
    }


    // A binding read may expose only the native body pointer. Preserve the
    // owning aggregate when the binding still has that allocation handle;
    // borrowed host objects remain their real address.
    private ExpressionResult rootedNativeClassValue(
        imported!"dmd.expression".Expression expression,
        in ExpressionResult evaluated,
    ) {
        // A cast between class references denotes the same object, so the
        // operand's own rooted value still applies. A cast from anything else
        // -- a `void*` aimed at raw storage, say -- denotes no such object,
        // and the evaluated result is the only answer.
        if (auto cast_ = expression.isCastExp)
            if (cast_.e1.type !is null &&
                cast_.e1.type.toBasetype.isTypeClass !is null)
                return rootedNativeClassValue(cast_.e1, evaluated);

        auto var = expression.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable !is null) {
            const rooted = readBindingValue(variable);
            if (rooted.isNativeAggregate)
                return rooted;
        }
        return evaluated;
    }

    private void defaultLocalValue(VarDeclaration variable) {
        defaultValue(variable.type, bindingPlace(variable));
    }

    private bool isRefVariable(VarDeclaration variable) const {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.ref_) != STC.none;
    }

    private bool isManifestVariable(VarDeclaration variable) const {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.manifest) != STC.none;
    }

    private ExpressionResult runPostIncrementExpression(
        imported!"dmd.expression".PostExp post,
    ) {
        import dmd.tokens: EXP;

        const delta = post.op == EXP.plusPlus
            ? ExpressionResult(cast(int) 1)
            : post.op == EXP.minusMinus
                ? ExpressionResult(cast(int) -1)
                : ExpressionResult.void_;
        if (delta == ExpressionResult.void_)
            throw new Exception("Unsupported eval post expression.");

        if (auto var = post.e1.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported eval post expression target.");

            // Reuse the ordinary VarExp read path so post-increment observes
            // the binding's authoritative native storage.
            const oldValue = constructedExpressionValue(post.e1);
            writeLocation(post.e1, incrementedValue(oldValue, post.e1.type, delta));
            return oldValue;
        }

        if (post.e1.isDotVarExp !is null) {
            if (isDirectProjectionWriteTarget(post.e1)) {
                auto destination = directWriteProjectionPlace(post.e1);
                const oldValue = readStoredValue(destination);
                writeStoredValue(
                    destination,
                    castScalarToType(
                        post.e1.type,
                        incrementedValue(oldValue, post.e1.type, delta),
                    ),
                );
                clearProjectionRootUninitialized(post.e1);
                return oldValue;
            }

            const oldValue = constructedExpressionValue(post.e1);
            writeLocation(post.e1, incrementedValue(oldValue, post.e1.type, delta));
            return oldValue;
        }

        if (post.e1.isIndexExp !is null) {
            if (isDirectProjectionWriteTarget(post.e1)) {
                auto destination = directWriteProjectionPlace(post.e1);
                const oldValue = readStoredValue(destination);
                writeStoredValue(
                    destination,
                    castScalarToType(
                        post.e1.type,
                        incrementedValue(oldValue, post.e1.type, delta),
                    ),
                );
                clearProjectionRootUninitialized(post.e1);
                return oldValue;
            }

            const oldValue = constructedExpressionValue(post.e1);
            writeLocation(post.e1, incrementedValue(oldValue, post.e1.type, delta));
            return oldValue;
        }

        if (auto pointer = post.e1.isPtrExp) {
            // Construct the pointer operand in its own typed place rather
            // than reading it through the carrier: `pointerOperandPlace`
            // evaluates `pointer.e1` exactly once, matching the single-read
            // contract the atomic hooks build their own target place under,
            // and `.deref.address` is the identical address
            // `nativeElementAddress(..., 0, ...)` those composed. Pair it
            // with `post.e1.type.toBasetype` -- the same pointee type
            // `loadNativePointerElement` resolved -- so an enum-typed
            // pointee still reads/writes as its base scalar here.
            import quickbite.backends.interpreter.place: Place;

            auto target = Place(
                pointerOperandPlace(pointer.e1).deref.address,
                post.e1.type.toBasetype,
            );
            const oldValue = readStoredValue(target);
            writeStoredValue(target, incrementedValue(oldValue, target.type, delta));
            return oldValue;
        }

        throw new Exception("Unsupported eval post expression target.");
    }

    // A post-inc/dec target's next value. A pointer-typed target moves by
    // whole elements: DMD's own `scaleFactor` folds that same scaling into
    // the frontend AST for `p++`/`p--` on a real pointer (multiplying the
    // unit delta by the pointee's size), so `pointerOffsetBy` -- which adds
    // its argument as a raw byte count -- needs the same multiplication here.
    // Anything else is plain scalar arithmetic.
    private ExpressionResult incrementedValue(
        in ExpressionResult oldValue,
        imported!"dmd.mtype".Type type,
        in ExpressionResult delta,
    ) {
        return oldValue.isPointer
            ? oldValue.pointerOffsetBy(delta.asLong * pointerElementSize(type))
            : oldValue + delta;
    }

    private ExpressionResult runAddAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        return runCompoundAssignExpression(assign);
    }
}


private imported!"dmd.mtype".TypeStruct receiverStructType(
    imported!"dmd.expression".Expression receiver,
) {
    if (receiver.type is null)
        return null;

    return receiver.type.toBasetype.isTypeStruct;
}


private bool isTruthy(in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.native_array: readSliceHeaderBytes;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    if (value == ExpressionResult.null_)
        return false;

    if (value.isPointer)
        return true;

    if (AggregateValue.isArray(value)) {
        // DMD's `toBasetype` is mutable.
        auto aggregate = AggregateValue.native(value);
        if (aggregate.type.toBasetype.ty == TY.Tarray)
            return readSliceHeaderBytes(aggregate.storage.bytes).ptr !is null;
        return AggregateValue.length(aggregate) != 0;
    }

    if (value == ExpressionResult(false))
        return false;

    if (value == ExpressionResult(true))
        return true;

    return value.castTo!bool == ExpressionResult(true);
}


private imported!"dmd.mtype".TypeClass receiverClassType(
    imported!"dmd.expression".Expression receiver,
) {
    if (receiver.type is null)
        return null;

    return receiver.type.toBasetype.isTypeClass;
}


private bool returnsRef(imported!"dmd.func".FuncDeclaration function_) {
    auto type = function_.type is null ? null : function_.type.isTypeFunction;
    return type !is null && type.isRef;
}


// The `this` a native constructor initialises: the struct's default `.init`.
// The variable being constructed has no usable value yet, so the evaluated
// receiver is not a struct (mirrors runMemberFunction's ctor seeding).
private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult nativeConstructorReceiver(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult receiver,
) {
    auto structDecl = function_.parent is null
        ? null
        : function_.parent.isStructDeclaration;
    return structDecl !is null ? defaultValueOwnerResult(structDecl.type) : receiver;
}


private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult defaultValueOwnerResult(
    imported!"dmd.mtype".Type type,
) {
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.place_value: readValue;
    import quickbite.backends.interpreter.runtime_values: defaultValueOwner;

    auto owner = defaultValueOwner(type);
    return readValue(Place(owner.address, type));
}


private bool isVoidSliceType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type is null)
        return false;
    auto slice = type.toBasetype.isTypeDArray;
    return slice !is null && slice.next.toBasetype.ty == TY.Tvoid;
}


// A newly allocated native class body begins as zeroed guest storage, but
// D's field defaults need not be zero. Seed each declared field through the
// same place codec used by assignments; the returned NativeAggregate retains
// the reference slot and the body allocation as one expression value.
private void initializeNativeClassBody(
    ref Walker walker,
    imported!"dmd.mtype".Type type,
    imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate object,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.layout: classFields;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.place_value: writeValue;
    import quickbite.backends.interpreter.runtime_values: defaultValue;

    auto classType = type.toBasetype.isTypeClass;
    if (classType is null || classType.sym is null)
        throw new Exception("initializeNativeClassBody needs a class type.");

    // This is where raw storage becomes an object of `type`: the class's
    // fields are laid into it here. A native class reference carries only its
    // body address, so the class that address denotes is kept beside it, and
    // establishing a class over storage is the one moment that answer
    // changes. Re-establishing another class over the same storage therefore
    // replaces it outright -- what the storage was before has been
    // overwritten.
    //
    // Not `const`: the field writes below go through this address.
    auto address = AggregateValue.nativeClassBodyAddress(object);
    walker.nativeClassTypes[address] = type;

    auto body = Place(address, type);
    foreach (field; classFields(classType.sym)) {
        auto destination = body.field(field);
        defaultValue(field.type, destination);
        if (field._init !is null) {
            imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value;
            if (auto initializer = field._init.isExpInitializer)
                value = walker.storageValue(
                    field.type,
                    walker.constructedExpressionValue(initializer.exp),
                );
            else if (field._init.isArrayInitializer !is null)
                value = classFieldArrayLiteralDefault(walker, field);
            else
                continue;
            writeValue(destination, value);
        }
    }
}


// A `Tarray`/`Tsarray` class field's own array-literal default (`int[] arr
// = [1, 2, 3];`) parses as an `ArrayInitializer`, not the `ExpInitializer`
// a scalar default parses as. Real D evaluates that literal once, into the
// class's static `.init` data, and every `new` that does not override the
// field shares that one backing array: mutating it through one instance is
// visible through another. Evaluate the literal once per field declaration
// and cache the resulting native array `ExpressionResult`, so every later instance's
// field descriptor points at the same backing storage instead of a fresh
// per-object copy.
private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult
classFieldArrayLiteralDefault(
    ref Walker walker,
    imported!"dmd.declaration".VarDeclaration field,
) @trusted {
    import dmd.initsem: initializerToExpression;
    import quickbite.backends.interpreter.layout:
        typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.place_value: readValue, writeValue;

    if (walker.classArrayFieldDefaults is null)
        walker.classArrayFieldDefaults = new ClassArrayFieldDefaults;
    const key = cast(const(void)*) field._init;
    if (auto cached = key in walker.classArrayFieldDefaults.table)
        return readValue(Place(cached.address, field.type));

    const value = walker.storageValue(
        field.type,
        walker.constructedExpressionValue(field._init.initializerToExpression),
    );
    auto block = NativeBlock.allocate(
        typeByteSize(field.type),
        typeHasPointers(field.type)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no,
    );
    writeValue(Place(block.address, field.type), value);
    walker.classArrayFieldDefaults.table[key] = block;
    return readValue(Place(block.address, field.type));
}


private imported!"dmd.func".FuncDeclaration overridingFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (current; classHierarchy(class_))
        if (current.members !is null)
            foreach (member; *current.members)
                if (auto function_ = member.isFuncDeclaration)
                    if (overridesFunction(function_, base))
                        return function_;

    return null;
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

    // A vtable index is only meaningful within the table it was assigned
    // against. `base` may be an interface method whose index numbers the
    // interface's own table, so the same index into an implementing class's
    // vtbl names an unrelated method; accept the entry only when it really
    // belongs to this class hierarchy and has the signature being called.
    auto function_ = class_.vtbl[index].isFuncDeclaration;
    if (
        function_ is null ||
        !isClassHierarchyMember(class_, function_) ||
        !sameFunctionSignature(function_, base)
    )
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


// The concrete method implementing `base` reached through one of `class_`'s
// interfaces. An interface's vtbl holds the interface's own declarations, so
// this answers the declaration a call site's signature names even when the
// implementing class never mentions the interface method by that identity.
private imported!"dmd.func".FuncDeclaration matchingInterfaceFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (interface_; class_.interfaces)
        if (auto function_ = matchingInterfaceFunction(*interface_, base))
            return function_;

    return null;
}


private imported!"dmd.func".FuncDeclaration matchingInterfaceFunction(
    ref imported!"dmd.dclass".BaseClass interface_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (function_; interface_.vtbl)
        if (function_ !is null && sameFunctionSignature(function_, base))
            return function_;

    foreach (ref baseInterface; interface_.baseInterfaces)
        if (auto function_ = matchingInterfaceFunction(baseInterface, base))
            return function_;

    return null;
}


// The entry of `class_`'s own vtable that matches `base`'s signature, found
// by scanning rather than by index -- the fallback for a `base` whose
// `vtblIndex` numbers a different table than this class's.
private imported!"dmd.func".FuncDeclaration matchingVtableFunction(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration base,
) {
    foreach (entry; class_.vtbl)
        if (auto function_ = entry.isFuncDeclaration)
            if (
                isClassHierarchyMember(class_, function_) &&
                sameFunctionSignature(function_, base)
            )
                return function_;

    return null;
}


private bool isClassHierarchyMember(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.func".FuncDeclaration function_,
) {
    // `.parent` is the lexically nearest enclosing symbol, which for a
    // method introduced by a `mixin template` is the `TemplateMixin`
    // instantiation, not the class doing the mixing in. `toParent` names
    // the logically enclosing symbol instead, skipping over any
    // `TemplateMixin` layers (`dmd.dsymbol.Dsymbol.toParent`'s own
    // documentation), which is what a vtbl-hierarchy membership check
    // means by "belongs to this class".
    foreach (current; classHierarchy(class_))
        if (function_.toParent is current)
            return true;

    return false;
}


private bool sameFunctionSignature(
    imported!"dmd.func".FuncDeclaration candidate,
    imported!"dmd.func".FuncDeclaration base,
) {
    if (candidate.ident !is base.ident)
        return false;

    if (
        candidate.type !is null &&
        base.type !is null &&
        candidate.type.equals(base.type)
    )
        return true;

    // A parameterless declaration has `parameters` either null or empty
    // depending on how it was built; both mean "no parameters", so compare
    // counts rather than the array identities.
    const candidateParameterCount = candidate.parameters is null
        ? 0
        : candidate.parameters.length;
    const baseParameterCount = base.parameters is null
        ? 0
        : base.parameters.length;
    if (candidateParameterCount != baseParameterCount)
        return false;

    if (candidateParameterCount == 0)
        return true;

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


private imported!"dmd.dclass".ClassDeclaration classDeclarationByNameInScope(
    imported!"dmd.dsymbol".ScopeDsymbol scope_,
    in string name,
) {
    return classDeclarationByNameInMembers(scope_.members, name);
}


private imported!"dmd.dclass".ClassDeclaration classDeclarationByNameInMembers(
    imported!"dmd.dsymbol".Dsymbols* members,
    in string name,
) {
    import dmd.dsymbol: foreachDsymbol;
    import dmd.dsymbolsem: include;

    imported!"dmd.dclass".ClassDeclaration found;
    foreachDsymbol(members, (symbol) {
        if (auto class_ = symbol.isClassDeclaration) {
            if (className(class_) == name || classInfoName(class_) == name) {
                found = class_;
                return 1;
            }
        }

        // A declaration carrying an attribute -- `private class C`, a
        // `version` or `static if` block -- keeps its members inside that
        // attribute rather than directly in the enclosing scope, and the
        // attribute itself is not a scope, so the search descends through it
        // to reach the class the attribute applies to.
        if (auto attribute = symbol.isAttribDeclaration)
            if (
                auto class_ = classDeclarationByNameInMembers(
                    attribute.include(null), name,
                )
            ) {
                found = class_;
                return 1;
            }

        if (auto nested = symbol.isScopeDsymbol)
            if (auto class_ = classDeclarationByNameInScope(nested, name)) {
                found = class_;
                return 1;
            }

        return 0;
    });

    return found;
}


// Unlike dynamicClassDeclarationByName's lexical-scope walk (rooted at the
// current call frame), this searches every module the frontend has
// semantically analysed -- covering a native throw's class even when it
// lives in an imported (not lexically enclosing) module. classInfoName
// equality is unambiguous here: a fully-qualified name (e.g. a native
// `classinfo.name`) can never equal a bare identifier, so reusing
// classDeclarationByNameInScope's dual match cannot misfire.
private imported!"dmd.dclass".ClassDeclaration classDeclarationByQualifiedName(
    in string name,
) {
    import dmd.dmodule: Module;

    foreach (module_; Module.amodules)
        if (auto class_ = classDeclarationByNameInScope(module_, name))
            return class_;

    return null;
}


private string[] classTypeNames(imported!"dmd.dclass".ClassDeclaration class_) {
    string[] names;
    foreach (current; classHierarchy(class_)) {
        names ~= className(current);
        foreach (interface_; current.interfaces)
            appendInterfaceTypeNames(names, interface_.sym);
    }

    return names;
}


private void appendInterfaceTypeNames(
    ref string[] names,
    imported!"dmd.dclass".ClassDeclaration interface_,
) {
    if (interface_ is null)
        return;

    names ~= className(interface_);
    foreach (base; interface_.interfaces)
        appendInterfaceTypeNames(names, base.sym);
}


private string className(imported!"dmd.dclass".ClassDeclaration class_) @safe {
    return class_.ident is null ? "" : class_.ident.toString.idup;
}


// Whether `class_` is `TypeInfo_Class` itself or a base of it -- the classes
// a `TypeInfo` describing a class or interface can be cast to.
private bool isClassTypeInfoClass(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    import std.algorithm: canFind;

    return ["TypeInfo_Class", "TypeInfo", "Object"].canFind(className(class_));
}


private string typeInfoName(imported!"dmd.mtype".Type type) {
    if (type is null)
        return "";

    auto classType = type.toBasetype.isTypeClass;
    if (classType !is null && classType.sym !is null)
        return classInfoName(classType.sym);

    return typeChars(type);
}


// A class `TypeInfo`'s real host address, for a class an imported native
// image actually defines -- the same resolution `fillNativeCallOperands`
// already performs for a `typeid(T)` FFI call argument. A class declared
// only in interpreted code was never compiled, so `resolveDataSymbol` finds
// no such symbol and the caller falls back to the symbolic display-name
// path. Scoped to class types only: a non-class `TypeInfo` value has no
// interpreter-tracked declaration to recover from a bare address later (see
// `classCastValue`'s `TypeInfo_Class` narrowing), so this never manufactures
// one for a struct or scalar `typeid`.
private const(void)* resolvedClassTypeInfoAddress(imported!"dmd.mtype".Type type) {
    import quickbite.ffi.ffi: resolveDataSymbol;

    if (type is null)
        return null;
    if (type.toBasetype.isTypeClass is null)
        return null;
    auto typeInfo = type.vtinfo;
    return typeInfo is null ? null : resolveDataSymbol(typeInfo);
}


// The type whose TypeInfo a qualified type's own TypeInfo carries in `base`.
// `shared` is stripped on its own, leaving any constness behind; otherwise
// the type goes all the way down to mutable.
private imported!"dmd.mtype".Type unqualifiedTypeInfoType(
    imported!"dmd.mtype".Type type,
) {
    import dmd.typesem: mutableOf, unSharedOf;

    if (type is null)
        return null;

    return type.isShared ? type.unSharedOf : type.mutableOf;
}


// The `ClassInfo.m_flags` word compiled D stores for `class_`.
private ushort classFlagsWord(imported!"dmd.dclass".ClassDeclaration class_) {
    import dmd.dclass: ClassFlags;
    import dmd.dsymbolsem: isAbstract;

    // An interface has no object body of its own, so none of the flags that
    // describe one (pointers, constructor, destructor) apply to it.
    if (class_.isInterfaceDeclaration !is null)
        return cast(ushort) (
            ClassFlags.hasOffTi |
            ClassFlags.hasTypeInfo |
            ClassFlags.hasNameSig |
            (class_.isCOMinterface ? ClassFlags.isCOMclass : ClassFlags.none)
        );

    uint flags =
        ClassFlags.hasOffTi |
        ClassFlags.hasGetMembers |
        ClassFlags.hasTypeInfo |
        ClassFlags.hasNameSig;

    if (class_.isCOMclass)
        flags |= ClassFlags.isCOMclass;
    if (class_.isCPPclass)
        flags |= ClassFlags.isCPPclass;
    if (class_.ctor !is null)
        flags |= ClassFlags.hasCtor;
    if (class_.isAbstract)
        flags |= ClassFlags.isAbstract;

    foreach (current; classHierarchy(class_))
        if (current.dtor !is null) {
            flags |= ClassFlags.hasDtor;
            break;
        }

    if (!classFieldsHaveIndirections(class_))
        flags |= ClassFlags.noPointers;

    return cast(ushort) flags;
}


// Whether any field the class declares, or inherits, needs collector
// scanning. A class's own header (vtable and monitor) does not count.
private bool classFieldsHaveIndirections(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    import quickbite.backends.interpreter.layout: typeHasPointers;

    foreach (current; classHierarchy(class_))
        foreach (field; current.fields)
            if (field !is null && field.type !is null && typeHasPointers(field.type))
                return true;

    return false;
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


// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string classInfoName(imported!"dmd.dclass".ClassDeclaration class_) @trusted {
    import std.string: fromStringz;

    return class_.toPrettyChars.fromStringz.idup;
}


private string variableName(
    imported!"dmd.declaration".VarDeclaration variable,
) @safe {
    return variable.ident is null ? "" : variable.ident.toString.idup;
}


private string structLiteralName(
    imported!"dmd.expression".StructLiteralExp literal,
) @safe {
    return literal.sd is null ? "" : literal.sd.ident.toString.idup;
}


// Clearing raw bytes is not `@safe`; this is the `@trusted` boundary.
// `byteLength` is always `layout.typeByteSize` of the type at `address`, so
// the span stays inside the storage that address was composed from -- the
// same precondition `place.d`'s own address arithmetic states.
private void clearBytes(void* address, in size_t byteLength) pure nothrow @trusted {
    (cast(ubyte*) address)[0 .. byteLength] = 0;
}


// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return type.toChars.fromStringz.idup;
}

// DMD lowers `synchronized (obj) { ... }` into balanced `_d_monitorenter` and
// `_d_monitorexit` runtime calls around the block. A guest object has no
// native monitor header for druntime to lock, and guest code runs serially
// within one walker, so answering nothing preserves the statement's control
// flow exactly.
private bool isMonitorOperation(
    imported!"dmd.func".FuncDeclaration function_,
) {
    const name = function_.ident is null ? "" : function_.ident.toString;
    return name == "_d_monitorenter" || name == "_d_monitorexit";
}

private struct RuntimeDelegate {
    public imported!"dmd.func".FuncDeclaration function_;
    public size_t functionPointerId;
    public void* contextPointer;
    // A struct receiver's own native aggregate storage (owned or borrowed,
    // per whichever producer built it -- `runDelegateExpression`'s general
    // expression read for `&x.method` makes a fresh owned copy,
    // `runFunctionLiteralDeclaration`'s `receiverValue` borrows the
    // enclosing activation's live `this` for a captured nested literal); or,
    // for a class receiver, a borrowed view of its bare body address
    // (`nativeAggregateFrom`). Keeping the whole `NativeAggregate` here, not
    // just its address, is what keeps an owned struct copy's backing storage
    // GC-reachable for as long as the delegate that captured it can still be
    // called.
    public imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate receiver;
    public bool hasReceiver;

    // The enclosing activation's own frame address for each of
    // `function_`'s captured outer variables, snapshotted at the moment
    // this delegate value was created (while that activation's frame was
    // still live), never re-derived from whatever activation later calls
    // the delegate. The captured addresses point into that activation's
    // GC-backed `FrameBlock` (decision 17, `value.md`); retaining them
    // here keeps the block itself reachable for exactly as long as this
    // delegate can still be called, the same way any other GC pointer
    // field does.
    public void*[imported!"dmd.declaration".VarDeclaration] capturedAddresses;
}


private bool isMemberFunction(imported!"dmd.func".FuncDeclaration function_) {
    if (function_ is null || function_.parent is null)
        return false;

    return
        function_.parent.isStructDeclaration !is null ||
        function_.parent.isClassDeclaration !is null;
}


private bool isConstructorFunction(imported!"dmd.func".FuncDeclaration function_) {
    return
        function_.isCtorDeclaration !is null ||
        (
            function_.constructorStructDeclaration !is null &&
            function_.ident !is null &&
            function_.ident.toString == "this"
        );
}


private imported!"dmd.dstruct".StructDeclaration constructorStructDeclaration(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    // DMD's aggregate queries are not @safe; this only reads AST links and
    // returns an existing declaration reference.
    imported!"dmd.aggregate".AggregateDeclaration aggregate = function_.isThis;
    return aggregate is null ? null : aggregate.isStructDeclaration;
}


private const(char)[] declarationName(
    imported!"dmd.declaration".Declaration declaration,
) @safe {
    return declaration.ident is null ? "" : declaration.ident.toString;
}


private void log(A...)(auto ref A args) {
    version(unittest) {
        import unit_threaded;
        writelnUt(args);
    }
}

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
                return EvalResult(formattedDisplay(rootDestination.place));
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
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    char[] display;
    foreach (index; 0 .. value.arrayLength)
        display ~= value.index(index).loadNativeScalar!char;
    return display.idup;
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

// One call owns its evaluated places, source expressions, and `ref`/`out`
// address metadata. Zero- and one-argument calls stay entirely in the caller's
// stack value. Larger calls lay the three aligned arrays into one scanned GC
// block, so evaluation performs exactly one allocation independent of the
// arrays' growth policies while retaining the existing slice-shaped seams.
private struct CallArguments {
    private size_t _length;
    private void* _storage;
    private void*[][size_t]* _pool;
    private imported!"quickbite.backends.interpreter.place".Place _singlePlace;
    private imported!"dmd.expression".Expression _singleExpression;
    private EvaluatedReferenceArgument _singleReference;

    public this(in size_t length, void*[][size_t]* pool) {
        import core.memory: GC;

        _length = length;
        _pool = pool;
        if (length <= 1)
            return;

        auto available = length in *pool;
        if (available !is null && available.length != 0) {
            _storage = (*available)[$ - 1];
            (*available).length = (*available).length - 1;
            (*available).assumeSafeAppend;
            return;
        }

        _storage = GC.malloc(storageByteLength(length));
        places[] = typeof(_singlePlace).init;
        expressions[] = null;
        references[] = EvaluatedReferenceArgument.init;
    }

    // Call sites release the uncopied staging value only after every slice
    // derived from it is dead. Clear its scanned references before pooling.
    public void release() @trusted {
        auto storage = _storage;
        if (storage is null)
            return;

        places[] = typeof(_singlePlace).init;
        expressions[] = null;
        references[] = EvaluatedReferenceArgument.init;
        _storage = null;
        (*_pool)[_length] ~= storage;
    }

    public @property size_t length() const @safe @nogc nothrow pure {
        return _length;
    }

    public @property imported!"quickbite.backends.interpreter.place".Place[] places() {
        if (_length == 0)
            return null;
        if (_length == 1)
            return (&_singlePlace)[0 .. 1];
        return (cast(typeof(_singlePlace)*) _storage)[0 .. _length];
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
            typeof(_singlePlace).sizeof * length,
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
    private void*[][size_t]* _pool;
    private imported!"dmd.mtype".Type _singleType;
    private imported!"quickbite.backends.interpreter.native_call_adapter".
        NativeOperand _singleOperand;

    public this(
        imported!"dmd.expression".Expression[] expressions,
        void*[][size_t]* pool,
    ) {
        import core.memory: GC;

        _length = expressions.length;
        _pool = pool;
        if (_length > 1) {
            auto available = _length in *pool;
            if (available !is null && available.length != 0) {
                _storage = (*available)[$ - 1];
                (*available).length = (*available).length - 1;
                (*available).assumeSafeAppend;
            } else
                _storage = GC.calloc(storageByteLength(_length));
        }
        foreach (index, expression; expressions)
            types[index] = expression.type;
    }

    // @trusted: `_storage` is either null or the base pointer returned by
    // this value's own `GC.calloc` call. Call sites release the uncopied
    // staging value only after the synchronous native invocation returns.
    public void release() @trusted {
        auto storage = _storage;
        if (storage is null)
            return;

        types[] = null;
        operands[] = typeof(_singleOperand).init;
        _storage = null;
        (*_pool)[_length] ~= storage;
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

// One guest class identity. A class value is its object-body address; its
// DMD type supplies the field layout. Owning storage stays in the existing
// address-keyed owner tables, so aliases share one identity without a value
// wrapper.
private struct ClassObject {
    public imported!"dmd.mtype".Type type;
    public void* address;
}

private DelegateSlot interpretedDelegateSlot(in size_t functionPointerId)
@safe @nogc nothrow pure {
    return DelegateSlot(false, null, null, functionPointerId);
}

// A struct-typed place is the aggregate's own storage. A class-typed place
// holds the object-body address, so the aggregate view borrows that body.
private imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate
    nativeAggregateFrom(imported!"quickbite.backends.interpreter.place".Place place)
{
    import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.layout: classInstanceByteSize;

    if (place.type.toBasetype.isTypeClass !is null)
        return NativeAggregate(
            place.type,
            NativeBlock.borrow(
                place.deref.address,
                classInstanceByteSize(place.type.toBasetype.isTypeClass.sym),
            ),
        );

    return NativeAggregate(
        place.type,
        NativeBlock.borrow(
            place.address,
            imported!"quickbite.backends.interpreter.layout".typeByteSize(place.type),
        ),
    );
}

// One root evaluation owns this context, and every nested call borrows it.
// Callable identities are monotonic, but address-keyed slot metadata follows
// storage lifetime: writes replace it and copies, moves, and clears relocate or
// remove it. Callees publish every change immediately; unwinding never merges
// a private snapshot, and the context dies with the evaluation.
// Owner maps keep native storage reachable while its address can cross
// activations.
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
    public ClassObject[void*] nativeThrowableNext;

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
    public void*[][size_t] callArgumentStorage;
    public void*[][size_t] nativeCallArgumentStorage;
    public imported!"quickbite.backends.interpreter.frame_block".FrameBlock[][
        imported!"dmd.func".FuncDeclaration] reusableFrames;
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
    public ClassObject object;

    public this(
        ClassObject object,
        in string message,
    ) {
        super(message);
        this.object = object;
    }
}


private string exceptionMessage(
    imported!"quickbite.backends.interpreter.place".Place value,
) {
    char[] result;
    foreach (index; 0 .. value.arrayLength)
        result ~= value.index(index).loadNativeScalar!char;
    return result.idup;
}


private string statementLabel(imported!"dmd.identifier".Identifier identifier) {
    return identifier is null ? null : identifier.toString.idup;
}

private struct Walker {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AssertExp,
        DelegateFuncptrExp,
        DelegatePtrExp,
        DivExp,
        Expression,
        IdentifierExp,
        LogicalExp,
        ModExp,
        ThrowExp,
        TupleExp;
    import dmd.func: FuncDeclaration;
    import dmd.statement: Statement;
    import quickbite.backends.interpreter.frame_block: FrameBlock;
    import quickbite.backends.interpreter.frame_layout:
        cachedFrameLayout, FrameLayout;
    import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
    import quickbite.backends.interpreter.native_array: NativeArray;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.native_struct: NativeStruct;
    import quickbite.backends.interpreter.module_table: ModuleTable;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.runtime_values: defaultValue, defaultValueOwner;

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

    private @property ref ClassObject[void*] nativeThrowableNext() {
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
    private ClassObject pendingFinallyBodyException;
    private bool hasPendingFinallyBodyException;

    private bool returned;
    private bool addressOfRefReturn;
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
                    bodyInterpreted.object = chainExceptionObject(
                        bodyInterpreted.object,
                        finalException.object,
                    );
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
            if (return_.exp !is null)
                setReturnValue(return_.exp);
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

            auto catch_ = matchingCatch(tryCatch, interpreted.object);
            if (catch_ is null)
                throw exception;

            bindCatchVariable(catch_, interpreted.object);
            runStatement(catch_.handler);
        }
    }

    private imported!"dmd.statement".Catch matchingCatch(
        imported!"dmd.statement".TryCatchStatement tryCatch,
        ClassObject object,
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
        ClassObject object,
    ) {
        if (catch_.type is null)
            return true;

        auto classType = catch_.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return false;

        return classHasType(object, className(classType.sym));
    }

    // An index/slice `$`-length binding is always a native `size_t` and has
    // no address-keyed metadata.
    private void setLocal(VarDeclaration variable, in size_t value) {
        import std.conv: text;

        if (
            !hasBindingPlace(variable) &&
            declarationName(variable) == "__dollar"
        ) {
            _syntheticDollarValues[cast(const(void)*) variable] = value;
            return;
        }
        if (!hasBindingPlace(variable))
            throw new Exception(text(
                "Interpreter binding `",
                declarationName(variable),
                "` has no native place.",
            ));
        bindingPlace(variable).storeNativeScalar(value);
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

    private void storeDelegateSlot(Place place, in DelegateSlot slot) {
        import quickbite.backends.interpreter.place: clearPlace;

        clearStoredMetadata(place.type, place.address);
        nativeDelegateSlots[place.address] = slot;
        clearPlace(place);
    }

    private DelegateSlot loadDelegateSlot(Place place) {
        import quickbite.backends.interpreter.native_call_adapter:
            NativeOperand, nativeDelegateMetadata;

        if (auto slot = place.address in nativeDelegateSlots)
            return *slot;
        const native = nativeDelegateMetadata(
            NativeOperand(place.type, place.address),
        );
        return DelegateSlot(true, native.context, native.funcptr, 0);
    }

    private void storeFunctionPointerId(Place place, in size_t id) {
        clearStoredMetadata(place.type, place.address);
        nativeFunctionPointerSlots[place.address] = id;
        place.storeReference(null);
    }

    private size_t* loadFunctionPointerId(Place place) {
        return cast(const(void)*) place.address in nativeFunctionPointerSlots;
    }

    private void storeTypeInfoName(Place place, in string name) {
        import quickbite.backends.interpreter.place: clearPlace;

        clearStoredMetadata(place.type, place.address);
        nativeTypeInfoSlots[place.address] = name;
        clearPlace(place);
    }

    private string* loadTypeInfoName(Place place) {
        return place.address in nativeTypeInfoSlots;
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

        if (
            expression.isVarExp !is null ||
            expression.isThisExp !is null ||
            expression.isSuperExp !is null
        )
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
        return expression.isVarExp !is null ||
            expression.isThisExp !is null ||
            expression.isSuperExp !is null;
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
                        setLocal(index.lengthVar, pendingLength);
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
                setLocal(index.lengthVar, staticArrayLength(staticArray));
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


    private void bindCatchVariable(
        imported!"dmd.statement".Catch catch_,
        ClassObject object,
    ) {
        if (catch_.var is null)
            return;

        auto destination = bindingPlace(catch_.var);
        clearStoredMetadata(destination.type, destination.address);
        destination.storeReference(object.address);
        clearUninitializedBindingAddress(destination.address);
    }


    // `assertReferenceBind` compares exactly a reference slot's typed bytes.
    private static ubyte[] frameBytesAt(void* address, in size_t length) pure nothrow @trusted {
        return (cast(ubyte*) address)[0 .. length];
    }

    private ClassObject classObjectFromReferencePlace(Place place) {
        auto address = place.deref.address;
        auto type = place.type;
        if (auto dynamicType = address in nativeClassTypes)
            type = *dynamicType;
        return ClassObject(type, address);
    }

    private ClassObject classObjectFromReceiverPlace(Place place) {
        auto type = place.type;
        if (auto dynamicType = place.address in nativeClassTypes)
            type = *dynamicType;
        return ClassObject(type, place.address);
    }

    private void writeCharacterArray(Place destination, in string characters) {
        import dmd.astenums: TY;

        auto owner = AggregateValue.allocateArray(
            destination.type,
            characters.length,
        );
        auto source = Place(owner.address, owner.type);
        foreach (index, character; characters) {
            auto element = source.index(index);
            switch (element.type.toBasetype.ty) with (TY) {
            case Tchar:
                element.storeNativeScalar(character);
                break;
            case Twchar:
                element.storeNativeScalar(cast(wchar) character);
                break;
            case Tdchar:
                element.storeNativeScalar(cast(dchar) character);
                break;
            default:
                throw new Exception("Character array has a non-character element type.");
            }
        }
        copyPlaceValue(source, destination);
    }

    private void throwInterpretedException(
        imported!"dmd.expression".Expression expression,
    ) {
        auto object = classObjectFromReferencePlace(
            constructedExpressionPlace(expression),
        );
        if (dynamicClass(object) is null)
            throw new Exception("Unsupported throw expression.");
        if (hasPendingFinallyBodyException) {
            auto chained = chainExceptionObject(
                pendingFinallyBodyException,
                object,
            );
            throw new InterpretedException(
                chained,
                exceptionObjectMessage(chained),
            );
        }

        throw new InterpretedException(object, exceptionObjectMessage(object));
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
    private ClassObject
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
            nativeThrowableNext[object.address] = next;
        }

        return object;
    }

    private ClassObject
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
        if (nativeObjectPointer !is null)
            hydrateNativeExceptionMetadata(
                metadataOwner,
                class_,
                cast(void*) nativeObjectPointer,
        );
        if (AggregateValue.hasClassFieldNamed(metadataOwner, "msg")) {
            writeCharacterArray(
                AggregateValue.classFieldNamed(metadataOwner, "msg"),
                message,
            );
        }

        if (nativeObjectPointer is null) {
            const address = AggregateValue.nativeClassBodyAddress(metadataOwner);
            nativeClassTypes[address] = class_.type;
            nativeClassOwners[address] = metadataOwner;
            return ClassObject(class_.type, cast(void*) address);
        }

        auto address = cast(void*) nativeObjectPointer;
        nativeClassTypes[address] = class_.type;
        nativeExceptionMetadata[address] = metadataOwner;
        return ClassObject(class_.type, address);
    }

    private void hydrateNativeExceptionMetadata(
        imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate metadata,
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

    private NativeAggregate* classMetadata(ClassObject object) {
        if (object.address is null)
            return null;
        if (auto metadata = object.address in nativeExceptionMetadata)
            return metadata;
        return object.address in nativeClassOwners;
    }

    private bool classHasFieldNamed(ClassObject object, in string name) {
        if (auto metadata = classMetadata(object))
            return AggregateValue.hasClassFieldNamed(*metadata, name);
        return false;
    }

    private Place classFieldNamed(ClassObject object, in string name) {
        if (auto metadata = classMetadata(object))
            return AggregateValue.classFieldNamed(*metadata, name);
        throw new Exception("Class field metadata is unavailable.");
    }

    private string exceptionObjectMessage(ClassObject object) {
        return classHasFieldNamed(object, "msg")
            ? exceptionMessage(classFieldNamed(object, "msg"))
            : "";
    }

    private ClassObject chainExceptionObject(
        ClassObject thrown,
        ClassObject next,
    ) {
        if (!classHasFieldNamed(thrown, "_nextInChainPtr"))
            return thrown;

        auto tail = thrown;
        for (;;) {
            auto existing = nextExceptionObject(tail);
            if (existing.address is null)
                break;
            tail = existing;
        }

        auto field = classFieldNamed(tail, "_nextInChainPtr");
        clearStoredMetadata(field.type, field.address);
        field.storeReference(next.address);
        nativeThrowableNext[tail.address] = next;
        return thrown;
    }

    private ClassObject nextExceptionObject(ClassObject object) {
        if (auto next = object.address in nativeThrowableNext)
            return *next;
        if (!classHasFieldNamed(object, "_nextInChainPtr"))
            return ClassObject.init;

        auto address = classFieldNamed(object, "_nextInChainPtr")
            .deref.address;
        if (address is null)
            return ClassObject.init;

        auto type = object.type;
        if (auto dynamicType = address in nativeClassTypes)
            type = *dynamicType;
        return ClassObject(type, address);
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

    private void applyThrowableConstructor(
        imported!"quickbite.backends.interpreter.place".Place object,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
    ) {
        auto objectValue = classObjectFromReceiverPlace(object);
        if (dynamicClass(objectValue) is null || argumentPlaces.length == 0)
            return;
        auto metadata = classMetadata(objectValue);
        if (metadata is null)
            throw new Exception("Class field metadata is unavailable.");

        copyPlaceValue(
            argumentPlaces[0],
            AggregateValue.classFieldNamed(*metadata, "msg"),
        );
        if (
            argumentPlaces.length >= 4 &&
            dynamicClass(classObjectFromReferencePlace(argumentPlaces[3])) !is null &&
            classHasFieldNamed(objectValue, "_nextInChainPtr")
        )
            copyPlaceValue(
                argumentPlaces[3],
                AggregateValue.classFieldNamed(
                    *metadata,
                    "_nextInChainPtr",
                ),
            );
    }

    private void runThisConstructorCall(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments,
        ConstructionDestination* constructionDestination,
    ) {
        if (!hasThis)
            throw new Exception("Unsupported eval call.");

        if (
            dynamicClass(classObjectFromReceiverPlace(thisValue)) !is null &&
            isThrowableConstructor(function_)
        ) {
            applyThrowableConstructor(thisValue, argumentPlaces);
            storeReceiverCallResult(constructionDestination, thisValue);
            return;
        }

        // A delegating constructor (`this(...)` forwarding to another
        // constructor, as std.stdio.File's string constructor does): run the
        // target constructor directly into this constructor's own receiver
        // storage, so its writes land in `thisValue` without a round trip.
        if (function_.isConstructorFunction) {
            auto destination = ConstructionDestination(thisValue);
            runMemberFunction(
                function_,
                null,
                thisValue,
                argumentPlaces,
                argumentExpressions,
                evaluatedArguments,
                null,
                &destination,
            );
            if (
                constructionDestination !is null &&
                constructionDestination.isFresh
            )
                storeReceiverCallResult(constructionDestination, thisValue);
            return;
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
            auto destination = ConstructionDestination(bindingPlace(with_.wthis));
            runExpression(initializer.exp, destination);
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

    // Construct an rvalue in caller-owned typed storage. Every expression
    // kind dispatches through `constructInto`; no value-returning expression
    // walk exists beside it. A conversion between the expression's static
    // type and the destination type is applied by the destination arm that
    // needs it.
    private void runExpression(
        imported!"dmd.expression".Expression expression,
        ref ConstructionDestination destination,
    ) {
        const full = beginFullExpression;
        scope(exit) endFullExpression(full);

        const constructed = constructInto(expression, destination);
        if (!constructed)
            throwUnsupportedExpression(expression);
    }

    // The typed place an assert-diagnostic operand evaluates into --
    // `messages.d`'s formatters take this as their `eval` delegate's return
    // type, so an assert message reads native place bytes directly.
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
    // already-complete destination. This keeps the control-flow rule while
    // the call and return channel remains destination-passing.
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
            copyPlaceValue(temporary.place, destination.place);
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

    // The no-result walk itself, inside an already-open full expression.
    // An arm exists where discarding the result can avoid temporary storage;
    // every other non-void expression constructs into a typed temporary.
    private void executeForEffectImpl(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;

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

        if (auto assert_ = expression.isAssertExp) {
            executeAssertExpression(assert_);
            return;
        }

        if (auto throw_ = expression.isThrowExp) {
            executeThrowExpression(throw_);
            return;
        }

        if (auto logical = expression.isLogicalExp)
            if (logical.type.toBasetype.ty == TY.Tvoid) {
                executeVoidLogicalExpression(logical);
                return;
            }

        if (expression.isThisExp !is null || expression.isSuperExp !is null) {
            requireReceiverExpression(expression);
            return;
        }

        if (auto identifier = expression.isIdentifierExp)
            if (isDefensiveIdentifierExpression(identifier))
                return;

        if (auto delegatePointer = expression.isDelegatePtrExp) {
            requireInterpretedDelegate(delegatePointer.e1);
            return;
        }

        if (auto delegateFunctionPointer = expression.isDelegateFuncptrExp) {
            requireInterpretedDelegate(delegateFunctionPointer.e1);
            return;
        }

        if (auto literal = expression.isFuncExp) {
            constructFunctionLiteralInto(
                literal,
                Place(
                    _activationFrame.temporaryAddress(expression),
                    expression.type,
                ),
            );
            return;
        }

        if (auto dot = expression.isDotIdExp) {
            if (constructComplexComponentInto(
                dot,
                Place(
                    _activationFrame.temporaryAddress(expression),
                    expression.type,
                ),
            ))
                return;
        }

        if (auto vector = expression.isVectorExp) {
            if (constructVectorInto(
                vector,
                Place(
                    _activationFrame.temporaryAddress(expression),
                    expression.type,
                ),
            ))
                return;
        }

        if (auto vectorArray = expression.isVectorArrayExp) {
            if (constructVectorArrayInto(
                vectorArray,
                Place(
                    _activationFrame.temporaryAddress(expression),
                    expression.type,
                ),
            ))
                return;
        }

        if (auto symbol = expression.isSymOffExp) {
            if (auto pointerType = variableSymbolOffsetPointerType(symbol)) {
                if (constructPointerExpressionInto(
                    symbol,
                    Place(
                        _activationFrame.temporaryAddress(expression, pointerType),
                        pointerType,
                    ),
                ))
                    return;
            }
        }

        if (auto post = expression.isPostExp) {
            if (runPostExpression(post, null))
                return;
        }

        if (auto assign = scalarCompoundAssignment(expression)) {
            runScalarCompoundAssignment(assign, null);
            return;
        }

        if (auto assign = expression.isAssignExp) {
            cast(void) runAssignExpression(assign);
            return;
        }

        if (auto construct = expression.isConstructExp) {
            cast(void) runAssignExpression(construct);
            return;
        }

        if (auto blit = expression.isBlitExp) {
            cast(void) runAssignExpression(blit);
            return;
        }

        if (auto lowered = expression.isLoweredAssignExp) {
            cast(void) runLoweredAssignExpression(lowered);
            return;
        }

        import dmd.tokens: EXP;
        if (expression.op == EXP.concatenateAssign) {
            cast(void) runArrayConcatenateAssignExpression(
                cast(imported!"dmd.expression".BinExp) expression,
            );
            return;
        }
        if (
            expression.op == EXP.concatenateElemAssign ||
            expression.op == EXP.concatenateDcharAssign
        ) {
            cast(void) runArrayAppendAssignExpression(
                cast(imported!"dmd.expression".BinExp) expression,
            );
            return;
        }

        if (auto identity = expression.isIdentityExp) {
            executeForEffectImpl(identity.e1);
            executeForEffectImpl(identity.e2);
            return;
        }

        if (auto comparison = relationalComparisonOrNull(expression)) {
            executeForEffectImpl(comparison.e1);
            executeForEffectImpl(comparison.e2);
            return;
        }

        if (auto conditional = expression.isCondExp) {
            if (conditionTruthy(conditional.econd))
                executeForEffectImpl(conditional.e1);
            else
                executeForEffectImpl(conditional.e2);
            return;
        }

        if (auto cast_ = expression.isCastExp)
            if (cast_.type.toBasetype.ty == TY.Tvoid) {
                executeForEffectImpl(cast_.e1);
                return;
            }

        if (auto declaration = expression.isDeclarationExp) {
            executeDeclaration(declaration);
            return;
        }

        if (auto call = expression.isCallExp)
            if (call.type.toBasetype.ty == TY.Tvoid) {
                cast(void) runCallExpression(call, null);
                return;
            }

        if (expression.type is null || expression.type.toBasetype.ty == TY.Tvoid)
            throwUnsupportedExpression(expression);

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        const constructed = constructInto(expression, destination);
        if (!constructed)
            throwUnsupportedExpression(expression);
    }

    private void throwUnsupportedExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import std.conv: text;

        throw new Exception(text("Unsupported eval expression: ", expression.op));
    }

    private imported!"dmd.expression".CmpExp relationalComparisonOrNull(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        switch (expression.op) with (EXP) {
            case lessThan:
            case lessOrEqual:
            case greaterThan:
            case greaterOrEqual:
                return cast(imported!"dmd.expression".CmpExp) expression;
            default:
                return null;
        }
    }

    private bool constructComplexComponentInto(
        imported!"dmd.expression".DotIdExp dot,
        Place destination,
    ) {
        import dmd.astenums: TY;

        if (
            dot.type is null ||
            dot.e1.type is null ||
            destination.type is null ||
            !destination.type.toBasetype.equals(dot.type.toBasetype)
        )
            return false;

        const name = dot.ident is null ? "" : dot.ident.toString;
        if (name != "re" && name != "im")
            return false;

        switch (dot.e1.type.toBasetype.ty) with (TY) {
            case Tcomplex32:
                const value = scalarOperand!cfloat(dot.e1);
                destination.storeNativeScalar(name == "re" ? value.re : value.im);
                return true;
            case Tcomplex64:
                const value = scalarOperand!cdouble(dot.e1);
                destination.storeNativeScalar(name == "re" ? value.re : value.im);
                return true;
            case Tcomplex80:
                const value = scalarOperand!creal(dot.e1);
                destination.storeNativeScalar(name == "re" ? value.re : value.im);
                return true;
            default:
                return false;
        }
    }

    private bool constructVectorInto(
        imported!"dmd.expression".VectorExp vector,
        Place destination,
    ) {
        import quickbite.backends.interpreter.layout: staticArrayLength;

        if (
            vector.type is null ||
            destination.type is null ||
            !destination.type.toBasetype.equals(vector.type.toBasetype)
        )
            return false;

        auto arrayType = vector.to.basetype; // DMD Type APIs are mutable.
        auto staticArray = arrayType.toBasetype.isTypeSArray;
        if (staticArray is null)
            throw new Exception("Unsupported interpreter vector expression.");

        const length = staticArrayLength(staticArray);
        if (length == 0)
            return true;

        auto arrayDestination = Place(destination.address, arrayType);
        auto first = ConstructionDestination(arrayDestination.index(0));
        runExpression(vector.e1, first);
        foreach (index; 1 .. length)
            copyPlaceValue(first.place, arrayDestination.index(index));
        return true;
    }

    private bool constructVectorArrayInto(
        imported!"dmd.expression".VectorArrayExp vectorArray,
        Place destination,
    ) {
        if (
            vectorArray.type is null ||
            vectorArray.e1.type is null ||
            destination.type is null ||
            !destination.type.toBasetype.equals(vectorArray.type.toBasetype)
        )
            return false;

        auto vectorType = vectorArray.e1.type.toBasetype.isTypeVector;
        if (
            vectorType is null ||
            !vectorType.basetype.toBasetype.equals(
                vectorArray.type.toBasetype,
            )
        )
            throw new Exception("Unsupported interpreter vector array expression.");

        auto source = Place(
            _activationFrame.temporaryAddress(vectorArray.e1),
            vectorArray.e1.type,
        );
        auto sourceDestination = ConstructionDestination(source);
        runExpression(vectorArray.e1, sourceDestination);

        // A vector and its `.array` view have the same DMD-owned layout.
        // Give those bytes the result's static type before the typed copy.
        copyPlaceValue(Place(source.address, vectorArray.type), destination);
        return true;
    }

    private void executeAssertExpression(AssertExp assert_) {
        import quickbite.backends.interpreter.messages: assertFailureMessage;

        if (!conditionTruthy(assert_.e1))
            throwAssertError(assertFailureMessage(
                assert_,
                runningCalledFunction,
                inUnitTest,
                &assertOperandPlace,
            ));
    }

    private void executeThrowExpression(ThrowExp throw_) {
        throwInterpretedException(throw_.e1);
    }

    private void executeVoidLogicalExpression(LogicalExp logical) {
        import dmd.tokens: EXP;

        const left = conditionTruthy(logical.e1);
        if (
            logical.op == EXP.andAnd && left ||
            logical.op == EXP.orOr && !left
        )
            cast(void) runDestructorBoundedCondition(logical.e2);
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
        InterpretedException failure;
        while (_pendingTemporaryDestructors.length > first) {
            auto destructor = _pendingTemporaryDestructors[$ - 1];
            --_pendingTemporaryDestructors.length;
            try
                executeForEffect(destructor);
            catch (InterpretedException next) {
                if (failure is null)
                    failure = next;
                else
                    failure.object = chainExceptionObject(
                        failure.object,
                        next.object,
                    );
            }
        }

        if (failure !is null)
            throw failure;
    }

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

    private void constructSymbolDeclarationVariableInto(
        imported!"dmd.expression".VarExp var,
        Place destination,
    ) {
        import dmd.typesem: defaultInitLiteral;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto symbol = var.var.isSymbolDeclaration;
        if (symbol is null)
            assert(0, "non-variable VarExp was not a SymbolDeclaration");

        auto type = symbol.dsym is null ? symbol.type : symbol.dsym.type;

        if (auto structType = type is null ? null : type.toBasetype.isTypeStruct) {
            auto construction = ConstructionDestination(destination);
            runExpression(structType.defaultInitLiteral(var.loc), construction);
            return;
        }

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
            auto image = AggregateValue.classBodyByteSlice(object, symbol.type);
            copyPlaceValue(
                Place(image.address, image.type),
                destination,
            );
            return;
        }

        assert(0, "SymbolDeclaration VarExp was not an aggregate initializer");
    }

    private void constructVariableInto(
        imported!"dmd.expression".VarExp var,
        Place destination,
    ) {
        import dmd.id: Id;

        auto variable = var.var.isVarDeclaration;
        if (variable is null) {
            constructSymbolDeclarationVariableInto(var, destination);
            return;
        }

        if (variable.ident is Id.ctfe) {
            destination.storeNativeScalar(false);
            return;
        }

        if (isManifestVariable(variable)) {
            if (auto initializer = variable._init.isExpInitializer) {
                auto construction = ConstructionDestination(destination);
                runExpression(initializer.exp, construction);
            } else {
                defaultValue(variable.type, destination);
            }
            return;
        }

        if (auto length = cast(const(void)*) variable in _syntheticDollarValues) {
            storeLength(destination, *length);
            return;
        }

        if (isUninitializedBinding(variable)) {
            import quickbite.backends.interpreter.messages:
                uninitializedVariableMessage;
            import quickbite.frontend.dmd.types:
                isStaticArrayType, isStructType;

            if (isStructType(variable.type) || isStaticArrayType(variable.type)) {
                defaultLocalValue(variable);
                clearUninitializedBindingAddress(bindingPlace(variable).address);
                copyQualificationConvertedPlaceValue(
                    bindingPlace(variable),
                    destination,
                );
                return;
            }

            throw new Exception(
                uninitializedVariableMessage(variable, currentFunction),
            );
        }

        materializeDatasegInitializer(variable);
        if (hasBindingPlace(variable)) {
            copyQualificationConvertedPlaceValue(
                bindingPlace(variable),
                destination,
            );
            return;
        }

        defaultValue(variable.type, destination);
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

    private Place constructedExpressionPlace(
        imported!"dmd.expression".Expression expression,
    ) {
        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);
        return destination.place;
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

    private void* addressOfExpression(
        imported!"dmd.expression".Expression e1,
        in imported!"dmd.tokens".EXP op,
    ) {
        import std.conv: text;

        if (auto symbol = e1.isSymOffExp) {
            if (auto variable = symbol.var.isVarDeclaration) {
                materializeDatasegInitializer(variable);
                if (!hasBindingPlace(variable))
                    throw new Exception("Symbol offset has no native binding place.");
                return offsetPointerAddress(
                    bindingPlace(variable).address,
                    cast(long) symbol.offset,
                );
            }
            throw new Exception("Function address needs a typed pointer destination.");
        }

        // `&val` of a `ref` parameter is emitted as AddrExp(VarExp), not the
        // SymOffExp produced for a plain local; point at the parameter's slot
        if (auto var = e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                return addressableBindingBase(variable);

        // A struct method's `this` is an alias to the caller's receiver, not
        // an ordinary local declaration. Its address therefore comes from
        // the receiver place retained when this activation was entered.
        if (
            e1.isThisExp !is null &&
            e1.type.toBasetype.isTypeStruct !is null &&
            thisAddress !is null
        )
            return thisAddress;

        // `this` is not an ordinary binding to compose an address from: the
        // receiver's address is the one this activation was entered with. A
        // struct constructor's implicit `return this` reaches here, and must
        // answer the temporary the constructor ran against.
        if (e1.isThisExp !is null) {
            if (thisAddress !is null)
                return thisAddress;
            if (currentFunction !is null && currentFunction.vthis !is null)
                return addressableBindingBase(currentFunction.vthis);
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
            auto temporary = constructedExpressionPlace(literal);
            return temporary.address;
        }

        // Taking the address of a dereference recovers the pointer value;
        // evaluating the dereference first would incorrectly require a
        // separate addressable value for the pointee.
        if (auto pointer = e1.isPtrExp)
            return pointerOperandPlace(pointer.e1).deref.address;

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
                return constructedExpressionPlace(dot).address;

            if (isStaticArrayType(dot.type))
                return arrayPointer(dot, 0, op);

            // Build a nested field address from its receiver's one address.
            // In particular, `&a[i++].inner.x` first composes the address of
            // `a[i++].inner`; that evaluates `i++` exactly once, then the
            // outer field offset composes from the resulting native pointer.
            // Re-running `constructedExpressionValue(dot)` for a detached aggregate read would
            // walk the index a second time.
            if (auto innerDot = dot.e1.isDotVarExp)
                if (auto field = dot.var.isVarDeclaration) {
                    auto receiverPointer = addressOfExpression(innerDot, op);
                    // `auto`: field composition needs a mutable `void*`.
                    import quickbite.backends.interpreter.place: Place;

                    // `&parent.child.x` first yields the address of the
                    // class-reference field `parent.child`; compose `x`
                    // from the referenced body, not from that slot's bytes.
                    if (innerDot.type.toBasetype.isTypeClass !is null)
                        return Place(receiverPointer, innerDot.type)
                            .deref.field(field).address;

                    return Place(receiverPointer, innerDot.type)
                        .field(field)
                        .address;
                }

            if (auto index = dot.e1.isIndexExp) {
                if (auto field = dot.var.isVarDeclaration) {
                    // `$` inside `index.e2` (a `DollarExp`) is bound to
                    // `index.lengthVar`; the ordinary eager path binds it
                    // from `constructedExpressionValue(index.e1)`'s length before
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
                                constructedExpressionPlace(receiverVar)
                                    .arrayLength,
                            );
                    const elementIndex = scalarOperand!long(index.e2);
                    auto elementPointer = arrayPointer(index.e1, elementIndex, op);
                    // `auto`: field composition needs a mutable `void*`.
                    import quickbite.backends.interpreter.place: Place;

                    return Place(elementPointer, dot.e1.type)
                        .field(field)
                        .address;
                }
            }

            if (auto receiver = dot.e1.isVarExp)
                if (auto variable = receiver.var.isVarDeclaration)
                    if (auto field = dot.var.isVarDeclaration)
                        if (hasBindingPlace(variable)) {
                            auto place = bindingPlace(variable);
                            if (place.type.toBasetype.isTypeClass !is null)
                                place = place.deref;
                            return place.field(field).address;
                        }

            // A class read carries its native body address. Compose the field
            // from that authority and the receiver expression's static class
            // type; native objects such as a caught Throwable need not have
            // been allocated by the Interpreter or entered in its dynamic-type
            // registry for their inherited field layout to be addressable.
            if (dot.e1.type.toBasetype.isTypeClass !is null) {
                auto receiver = constructedExpressionPlace(dot.e1);
                auto bodyAddress = receiver.deref.address;
                auto bodyType = dot.e1.type;
                if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = (*metadata).type;
                }
                auto field = dot.var.isVarDeclaration;
                if (field !is null)
                    return Place(bodyAddress, bodyType).field(field).address;
            }

            // A ref local may bind a field of a returned struct temporary.
            // The receiver's typed activation place owns that temporary for
            // the enclosing expression, so compose the field from the same
            // place without asking the lvalue-only composer to rediscover it.
            if (
                dot.e1.isCallExp !is null &&
                dot.e1.type.toBasetype.isTypeStruct !is null
            )
                if (auto field = dot.var.isVarDeclaration)
                    return constructedExpressionPlace(dot.e1)
                        .field(field)
                        .address;

            // Every remaining field address must compose from the owning
            // typed binding. This also covers parameters and nested receiver
            // shapes whose value is represented only by a native place.
            try {
                import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;

                return placeOfLvalue(
                    dot,
                    (variable) @safe => addressableBindingBase(variable),
                    (expression) @system => scalarOperand!size_t(expression),
                ).address;
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
    // frame (`addressOfRefReturn` mode).
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
            addressOfExpression(expression, EXP.address),
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

    private void* refReturningCallAddress(
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
            &_executionState.callArgumentStorage,
        );
        scope(exit) callArguments.release;
        auto argumentPlaces = callArguments.places;
        auto argumentExpressions = callArguments.expressions;
        auto evaluatedArguments = callArguments.references;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                if (index < call.f.parameters.length &&
                    isReferenceParameter(
                        call.f,
                        index,
                        (*call.f.parameters)[index],
                    ))
                    argumentPlaces[index] = runRefArgumentExpression(
                        argument,
                        evaluated,
                    );
                else {
                    auto destination = ConstructionDestination(Place(
                        _activationFrame.temporaryAddress(argument),
                        argument.type,
                    ));
                    runExpression(argument, destination);
                    argumentPlaces[index] = destination.place;
                }
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
                    Place.init,
                    null,
                    null,
                    argumentPlaces,
                    argumentExpressions,
                    evaluatedArguments,
                    false,
                    nativeResult,
                ))
                    throw new Exception(unsupported);
            } catch (NativeCallException exception) {
                throwNativeException(exception);
            }
            return nativeResult.value.address;
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
            argumentPlaces,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );
        try {
            child.runStatement(call.f.fbody);
        } catch (InterpretedException exception) {
            mergeFunctionState(call.f, argumentExpressions, child);
            throw exception;
        }
        mergeFunctionState(call.f, argumentExpressions, child);

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
        out void* receiverAddress,
        out Place receiver,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;

        receiverAddress = addressOfExpression(receiverExpression, EXP.address);
        receiver = Place(receiverAddress, receiverExpression.type);
        queueConstructedReceiverDestructor(receiverExpression);
    }

    // The address of the lvalue a ref-returning *member* call yields. The
    // callee's `this` must alias the receiver expression's own storage: the
    // returned lvalue is typically a receiver field, and its address is only
    // meaningful to the caller if it points into the caller's aggregate
    // rather than into a copied receiver value.
    private void* memberRefReturningCallAddress(
        imported!"dmd.expression".CallExp call,
        imported!"dmd.expression".DotVarExp dot,
        in string unsupported,
    ) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
        import quickbite.frontend.dmd.functions:
            ensureFunctionBodySemantic, hasNoInterpretableSource;

        void* receiverAddress;
        Place receiver;
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

        if (
            receiver.type.toBasetype.isTypeClass !is null &&
            receiver.address is null
        )
            throw new Exception(
                "function call through null class reference `null`",
            );

        auto function_ = resolveMemberFunction(call.f, receiver);
        ensureFunctionBodySemantic(function_);
        const native = hasNoInterpretableSource(function_);

        Place[] argumentPlaces;
        Expression[] argumentExpressions;
        EvaluatedReferenceArgument[] evaluatedArguments;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                if (index < function_.parameters.length &&
                    isReferenceParameter(
                        function_,
                        index,
                        (*function_.parameters)[index],
                    ))
                    argumentPlaces ~= runRefArgumentExpression(
                        argument,
                        evaluated,
                    );
                else {
                    auto destination = ConstructionDestination(Place(
                        _activationFrame.temporaryAddress(argument),
                        argument.type,
                    ));
                    runExpression(argument, destination);
                    argumentPlaces ~= destination.place;
                }
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
                    argumentPlaces,
                    argumentExpressions,
                    evaluatedArguments,
                    false,
                    nativeResult,
                ))
                    throw new Exception(unsupported);
            } catch (NativeCallException exception) {
                throwNativeException(exception);
            }
            return nativeResult.value.address;
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
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindThisReferenceAddress(function_, child.thisValue);
        child.bindFunctionParameters(
            function_,
            argumentPlaces,
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
            );
            throw exception;
        }
        mergeMemberFunctionState(
            function_,
            dot.e1,
            argumentExpressions,
            child,
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
        void* receiverAddress,
    ) {
        if (
            function_.vthis is null ||
            function_.vthis.isThisDeclaration is null
        )
            return;

        if (receiverAddress is null)
            return;

        child.thisAddress = receiverAddress;
        if (child._activationFrame.hasReferenceSlot(function_.vthis))
            child._activationFrame.setReferenceSlot(
                function_.vthis,
                child.thisAddress,
            );
        if (function_.vthis.type.toBasetype.isTypeStruct !is null)
            child.bindStructReceiver(Place(
                receiverAddress,
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

    // A class expression evaluates into a reference slot. Member dispatch
    // borrows the referenced object body as its receiver; a struct expression
    // already evaluates into the receiver bytes themselves.
    private Place memberReceiverPlace(Place value) {
        return value.type.toBasetype.isTypeClass !is null
            ? value.deref
            : value;
    }

    // A `ref` foreach variable over an input range may bind to a `front`
    // result returned by value. DMD represents its per-iteration temporary as
    // `AddrExp(CallExp)`: evaluate the call once into typed native storage and
    // return that ordinary temporary's address.
    private void* addressOfCallResultTemporary(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(call),
            call.type,
        ));
        constructInto(call, destination);
        return destination.place.address;
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

        _activationFrame.eachStorageBlock((address, byteLength) {
            clearStoredMetadataRange(address, byteLength);
        });
    }

    private FrameBlock acquireActivationFrame(
        FuncDeclaration function_,
        FrameLayout layout,
    ) {
        auto available = function_ in _executionState.reusableFrames;
        if (available is null || available.length == 0)
            return FrameBlock.allocate(layout);

        auto frame = (*available)[$ - 1];
        (*available).length = (*available).length - 1;
        (*available).assumeSafeAppend;
        frame.reset;
        return frame;
    }

    private void releaseActivationFrame(
        FuncDeclaration function_,
        in bool addressMayEscape = false,
    ) {
        retireActivationFrameMetadata;
        if (_activationFrameMetadataRetained || addressMayEscape)
            return;

        foreach (frame; lazyArgumentFrames.byValue)
            if (frame.block.address is _activationFrame.block.address)
                return;

        _executionState.reusableFrames[function_] ~= _activationFrame;
    }

    // The child's returned address points into its own frame: a pointer to a
    // `ref` parameter's slot must become the caller's argument lvalue so
    // writes through it reach the argument; any other variable's pointer id
    // is registered here so this frame can resolve it.
    private void* returnedLvalueAddress(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        return child._refReturnPlace.address;
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
    // anything, whether its own unconditional `constructedExpressionValue(index.e1)`
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
    private void* nestedIndexPointer(
        Expression expression,
        Place receiverPlace,
        in long offset,
        in bool selfAddress,
    ) {
        auto index = expression.isIndexExp;
        assert(index !is null);
        if (index.lengthVar !is null)
            setLocal(index.lengthVar, receiverPlace.arrayLength);
        const outerOffset = scalarOperand!size_t(index.e2);
        auto elementPlace = receiverPlace.index(outerOffset);
        if (selfAddress)
            return elementPlace.address;
        return Place(elementPlace.address, expression.type)
            .index(cast(size_t) offset)
            .address;
    }

    // `computeIndex`'s `Place.index` calls raise `IndexOutOfBoundsException`
    // for a real, already-committed out-of-range guest index -- translate it
    // to the guest's own range error rather than letting the host exception
    // type escape. Deliberately narrower than a bare `Exception` catch:
    // `computeIndex` typically runs a full construction of an index
    // expression along the way, which can raise an unrelated host failure
    // that must not be mislabeled as a guest range error.
    private void* mapIndexOutOfBounds(
        scope void* delegate() @system computeIndex,
    ) {
        import quickbite.backends.interpreter.place: IndexOutOfBoundsException;

        try {
            return computeIndex();
        } catch (IndexOutOfBoundsException exception) {
            throwRangeError(exception.msg);
            assert(0);
        }
    }

    private void* arrayPointer(
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
                auto aggregate = borrowedAggregate(
                    constructedExpressionPlace(call),
                );
                if (AggregateValue.isArray(aggregate))
                    return AggregateValue.elementAddress(
                        aggregate,
                        cast(size_t) offset,
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
                                            base.arrayLength,
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
                                setLocal(index.lengthVar, rowLength);
                            const elementOffset = scalarOperand!size_t(index.e2);
                            if (elementOffset >= rowLength)
                                throwRangeError(
                                    "quickbite.backends.interpreter.place.Place.index: "
                                    ~ "index out of range for static array place",
                                );

                            return mapIndexOutOfBounds(delegate void*() {
                                auto elementPlace = resolveInnerPlace().index(elementOffset);
                                if (selfAddress)
                                    return elementPlace.address;
                                return Place(elementPlace.address, array.type)
                                    .index(cast(size_t) offset)
                                    .address;
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
                // arm's own unconditional `constructedExpressionValue(index.e1)` below
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
                                                base.arrayLength,
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
                // reconstruct an address. The typed temporary keeps the
                // receiver rooted while its element address is composed, so
                // neither expression is evaluated a second time.
                auto arrayValue = constructedExpressionPlace(index.e1);
                if (index.lengthVar !is null) {
                    setLocal(index.lengthVar, arrayValue.arrayLength);
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
                    // `auto`: pointer composition needs a mutable `void*`.
                    auto element = arrayPointer(index.e1, outerOffset, op);
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

                    return Place(element, array.type)
                        .index(cast(size_t) offset)
                        .address;
                }
                if (auto field = index.e1.isDotVarExp) {
                    if (field.e1.isVarExp !is null) {
                        // Always element mode -- same reasoning as the
                        // `VarExp` arm above: `pointer` is `field`'s own
                        // address, one level short of `array`'s (this
                        // IndexExp's) element.
                        // `auto`: pointer composition needs a mutable `void*`.
                        auto pointer = arrayPointer(field, outerOffset, op);
                        if (selfAddress)
                            return pointer;
                        // Same hazard as the `VarExp` arm above: a raw
                        // byte offset from `pointer` would land inside a
                        // slice header instead of the row's data when
                        // this row is itself a dynamic array. Compose
                        // through `Place.index` instead, even when
                        // `offset == 0`.
                        import quickbite.backends.interpreter.place: Place;

                        return Place(pointer, array.type)
                            .index(cast(size_t) offset)
                            .address;
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
                            return mapIndexOutOfBounds(delegate void*() {
                                auto fieldPlace = placeOfLvalue(
                                    field,
                                    (variable) @safe => addressableBindingBase(variable),
                                    (expression) @system =>
                                        scalarOperand!size_t(expression),
                                );
                                auto elementPlace = fieldPlace.index(cast(size_t) outerOffset);
                                if (selfAddress)
                                    return elementPlace.address;
                                // Same hazard as the `VarExp` arm above.
                                return Place(elementPlace.address, array.type)
                                    .index(cast(size_t) offset)
                                    .address;
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
                // does, rather than falling through to `arrayValue` below.
                // Composing from a detached static-array temporary would
                // lose writes to `m`'s real backing storage.
                if (index.e1.isIndexExp !is null) {
                    // Always element mode -- same reasoning as the `VarExp`
                    // arm above.
                    // `auto`: pointer composition needs a mutable `void*`.
                    auto element = arrayPointer(index.e1, outerOffset, op);
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

                    return Place(element, array.type)
                        .index(cast(size_t) offset)
                        .address;
                }
                auto aggregate = borrowedAggregate(arrayValue);
                if (AggregateValue.isArray(aggregate)) {
                    // `index.e1` had no VarExp/DotVarExp receiver, so it
                    // was just re-evaluated above as a second, independent
                    // call/index. Keep that result's storage alive until
                    // the enclosing expression stores or discards the
                    // composed address.
                    import quickbite.backends.interpreter.place: Place;

                    retainTemporaryPointerOwner(aggregate.storage);
                    // Compose straight from the already-resolved native
                    // owner instead of a second `AggregateValue.elementAddress`
                    // call, which would only re-derive the same owner from
                    // `arrayValue` again.
                    auto elementAddress = Place(aggregate.address, aggregate.type)
                        .index(cast(size_t) outerOffset)
                        .address;
                    if (selfAddress)
                        return elementAddress;

                    return Place(elementAddress, array.type)
                        .index(cast(size_t) offset)
                        .address;
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
                // `auto`: pointer composition needs a mutable `void*`.
                auto pointer = arrayPointer(index.e1, outerOffset, op);
                if (selfAddress)
                    return pointer;
                return offsetPointerAddress(
                    pointer,
                    offset * cast(long) typeByteSize(
                        array.type.toBasetype.nextOf,
                    ),
                );
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
                        return fieldPlace.index(cast(size_t) offset).address;
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

                auto value = borrowedAggregate(
                    constructedExpressionPlace(array),
                );
                return AggregateValue.elementAddress(
                    value,
                    cast(size_t) offset,
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
        return bindingPlace(variable).index(cast(size_t) offset).address;
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
    // leaves such a temp with no slot anywhere, so its binding has no native
    // place. The initializer can only name other module-
    // scope declarations and its own literal/temp values -- never a local
    // of whatever function triggered this -- so swapping in a dedicated
    // frame around just this evaluation is exact, not an approximation.
    private void evaluateDatasegInitializerExpression(
        imported!"dmd.expression".Expression expression,
        Place destination,
    ) {
        import quickbite.backends.interpreter.frame_layout:
            computeExpressionFrameLayout;

        auto outer = _activationFrame;
        scope(exit) _activationFrame = outer;

        _activationFrame = FrameBlock.allocate(
            computeExpressionFrameLayout(expression),
        );
        auto construction = ConstructionDestination(destination);
        runExpression(expression, construction);
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

            evaluateDatasegInitializerExpression(
                variable.type.defaultInitLiteral(variable.loc),
                bindingPlace(variable),
            );
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
            evaluateDatasegInitializerExpression(
                initializerExp,
                bindingPlace(variable),
            );
        }
    }

    private size_t functionPointerId(FuncDeclaration function_) {
        if (auto id = function_ in functionPointerIds)
            return *id;

        const id = newFunctionPointerId(function_);
        functionPointerIds[function_] = id;
        return id;
    }

    private size_t newFunctionPointerId(FuncDeclaration function_) {
        const id = ++nextFunctionPointerId;
        functionPointers[id] = function_;
        return id;
    }

    private DelegateSlot runDelegateExpression(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        if (delegate_.func is null)
            throw new Exception("Unsupported eval expression: delegate_");

        const functionPointerId = newFunctionPointerId(delegate_.func);
        auto contextPointer = delegateContextAddress(delegate_);
        // `auto`: a delegate context is stored as a mutable `void*`.

        RuntimeDelegate runtime;
        runtime.function_ = delegate_.func;
        runtime.functionPointerId = functionPointerId;
        runtime.contextPointer = contextPointer;
        runtime.capturedAddresses = closureCapturedAddresses(delegate_.func);
        if (isMemberFunction(delegate_.func)) {
            if (delegate_.e1 is null)
                throw new Exception("Unsupported eval expression: delegate_");

            import quickbite.backends.interpreter.place: Place;

            auto receiverTemporary = ConstructionDestination(Place(
                _activationFrame.temporaryAddress(delegate_.e1),
                delegate_.e1.type,
            ));
            runExpression(delegate_.e1, receiverTemporary);
            runtime.receiver = nativeAggregateFrom(receiverTemporary.place);
            runtime.hasReceiver = true;
        }

        _executionState.delegates[functionPointerId] = runtime;
        return interpretedDelegateSlot(functionPointerId);
    }

    // A function literal's typed destination decides its D value shape. Both
    // shapes use the same callable identity and runtime record, but a
    // delegate owns a two-word delegate slot while a function pointer owns a
    // one-word pointer slot. Keep that distinction in the address-keyed
    // metadata.
    private void constructFunctionLiteralInto(
        imported!"dmd.expression".FuncExp literal,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.astenums: TY;

        if (literal.fd is null)
            throw new Exception("Unsupported eval expression: functionLiteral");

        const isDelegate = destination.type.toBasetype.ty == TY.Tdelegate;
        // `TypeNext.nextOf` does not accept a const-qualified DMD type.
        auto pointer = destination.type.toBasetype.isTypePointer;
        const isFunctionPointer = pointer !is null &&
            pointer.nextOf.toBasetype.isTypeFunction !is null;
        if (!isDelegate && !isFunctionPointer)
            throw new Exception("Function literal has no callable destination.");

        const functionPointerId = ++nextFunctionPointerId;
        functionPointers[functionPointerId] = literal.fd;

        RuntimeDelegate runtime;
        runtime.function_ = literal.fd;
        runtime.functionPointerId = functionPointerId;
        runtime.contextPointer = null;
        runtime.capturedAddresses = closureCapturedAddresses(literal.fd);
        if (literal.fd.isNested && hasThis) {
            runtime.receiver = nativeAggregateFrom(thisValue);
            runtime.hasReceiver = true;
        }

        _executionState.delegates[functionPointerId] = runtime;
        clearPlaceValue(destination);

        if (isDelegate) {
            nativeDelegateSlots[destination.address] = DelegateSlot(
                false,
                null,
                null,
                functionPointerId,
            );
            return;
        }

        nativeFunctionPointerSlots[destination.address] = functionPointerId;
    }

    // Each of `function_`'s captured outer variables (`frame_layout.
    // capturedVariables`), resolved to ITS OWN address in THIS activation
    // -- the lexically enclosing one, still live right now, whether or not
    // it later returns before the created delegate is called. Declines
    // (omits the entry, never throws) a captured variable whose address
    // cannot resolve yet; the
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

    private void* delegateContextAddress(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;

        if (delegate_.e1 !is null) {
            if (auto var = delegate_.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    return addressableBindingBase(variable);
        }

        if (delegate_.func !is null && delegate_.func.isNested) {
            auto captures = capturedVariables(delegate_.func);
            if (captures.length != 0)
                return addressableBindingBase(captures[0]);
        }

        return null;
    }

    // `is`/`!is` never rewrites for operator overloading the way `==` does
    // (`opover.d` has no `opOverloadIdentity`), so every static operand
    // shape -- scalar, pointer, associative-array handle, class reference,
    // struct, array, delegate, `typeid`/`.classinfo` -- can reach here
    // directly, unlike `equalOperands`'s narrower set. Evaluate each operand
    // in source order into its typed temporary, then select the comparison
    // from those static types and their place metadata.
    private bool identityOperands(imported!"dmd.expression".IdentityExp identity) {
        if (hasScalarEqualityOperands(identity))
            return scalarEquality(identity);

        if (
            pointerLikeIdentityType(identity.e1.type) &&
            pointerLikeIdentityType(identity.e2.type)
        )
            return pointerOperandPlace(identity.e1).deref.address ==
                pointerOperandPlace(identity.e2).deref.address;

        auto left = identityOperandPlace(identity.e1);
        auto right = identityOperandPlace(identity.e2);
        return identityPlaces(left, right);
    }

    private imported!"quickbite.backends.interpreter.place".Place
        identityOperandPlace(imported!"dmd.expression".Expression expression)
    {
        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);
        return destination.place;
    }

    // A pointer or associative-array handle is never symbolic `TypeInfo` --
    // a `typeid`/`.classinfo` result is always class-typed -- so its identity
    // is always its own storage slot's stored address. A class reference is
    // excluded even though `Place.deref` reads it the same way, because a `typeid`/
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

    private bool identityPlaces(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        import dmd.astenums: TY;

        const leftKind = left.type.toBasetype.ty;
        const rightKind = right.type.toBasetype.ty;
        if (leftKind == TY.Tnull)
            return identityPlaceIsNull(right);
        if (rightKind == TY.Tnull)
            return identityPlaceIsNull(left);

        switch (leftKind) with (TY) {
            case Tsarray, Tarray:
                return equalArrayPlaces(left, right);
            case Tstruct:
                return identityStructPlaces(left, right);
            case Tclass:
                return classPlacesAreIdentical(left, right);
            case Tdelegate:
                return delegatePlacesAreIdentical(left, right);
            case Tpointer:
                return functionPointerPlacesAreIdentical(left, right);
            case Timaginary32:
                return scalarPlacesAreEqual!ifloat(left, right);
            case Timaginary64:
                return scalarPlacesAreEqual!idouble(left, right);
            case Timaginary80:
                return scalarPlacesAreEqual!ireal(left, right);
            case Tcomplex32:
                return scalarPlacesAreEqual!cfloat(left, right);
            case Tcomplex64:
                return scalarPlacesAreEqual!cdouble(left, right);
            case Tcomplex80:
                return scalarPlacesAreEqual!creal(left, right);
            case Tvector:
                return borrowedAggregate(left).storage.bytes ==
                    borrowedAggregate(right).storage.bytes;
            default:
                throw new Exception("Unsupported interpreter identity operands.");
        }
    }

    private bool identityPlaceIsNull(
        imported!"quickbite.backends.interpreter.place".Place place,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.native_call_adapter:
            NativeOperand, nativeDelegateMetadata;

        auto type = place.type.toBasetype;
        switch (type.ty) with (TY) {
            case Tnull:
                return true;
            case Tarray:
                // Preserve the Interpreter's established element-based
                // array identity: every empty slice is identical to null.
                return place.arrayLength == 0;
            case Tdelegate:
                return place.address !in nativeDelegateSlots &&
                    nativeDelegateMetadata(
                        NativeOperand(place.type, place.address),
                    ).isNull;
            case Tclass:
                if (place.address in nativeTypeInfoSlots)
                    return false;
                return place.deref.address is null;
            case Taarray:
                return place.deref.address is null;
            case Tpointer:
                if (
                    type.nextOf.toBasetype.ty == Tfunction &&
                    cast(const(void)*) place.address
                        in nativeFunctionPointerSlots
                )
                    return false;
                return place.deref.address is null;
            default:
                return false;
        }
    }

    private bool identityStructPlaces(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        return equalStructPlaces(left, right);
    }

    private bool classPlacesAreIdentical(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        auto leftTypeInfo = left.address in nativeTypeInfoSlots;
        auto rightTypeInfo = right.address in nativeTypeInfoSlots;
        if (leftTypeInfo !is null || rightTypeInfo !is null)
            return leftTypeInfo !is null && rightTypeInfo !is null &&
                *leftTypeInfo == *rightTypeInfo;
        return left.deref.address is right.deref.address;
    }

    private bool delegatePlacesAreIdentical(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        import quickbite.backends.interpreter.native_call_adapter:
            NativeOperand, nativeDelegateMetadata;

        auto leftSlot = left.address in nativeDelegateSlots;
        auto rightSlot = right.address in nativeDelegateSlots;
        if (leftSlot !is null || rightSlot !is null)
            return leftSlot !is null && rightSlot !is null &&
                delegateSlotsAreIdentical(*leftSlot, *rightSlot);

        const leftNative = nativeDelegateMetadata(
            NativeOperand(left.type, left.address),
        );
        const rightNative = nativeDelegateMetadata(
            NativeOperand(right.type, right.address),
        );
        return leftNative.context is rightNative.context &&
            leftNative.funcptr is rightNative.funcptr;
    }

    private bool delegateSlotsAreIdentical(
        in DelegateSlot left,
        in DelegateSlot right,
    ) const {
        if (left.isNative != right.isNative)
            return false;
        return left.isNative
            ? left.context is right.context && left.funcptr is right.funcptr
            : left.functionPointerId == right.functionPointerId;
    }

    private bool functionPointerPlacesAreIdentical(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        auto leftId = cast(const(void)*) left.address
            in nativeFunctionPointerSlots;
        auto rightId = cast(const(void)*) right.address
            in nativeFunctionPointerSlots;
        if (leftId !is null || rightId !is null)
            return leftId !is null && rightId !is null && *leftId == *rightId;
        return left.deref.address is right.deref.address;
    }

    private bool scalarPlacesAreEqual(T)(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        return left.loadNativeScalar!T == right.loadNativeScalar!T;
    }

    // A non-void call writes into its caller-owned typed destination. A void
    // call has no destination and produces no result object.
    private void runCallExpression(
        imported!"dmd.expression".CallExp call,
        ConstructionDestination* constructionDestination,
    ) {
        import dmd.expression: Expression;
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

        auto callArguments = CallArguments(
            call.arguments is null ? 0 : call.arguments.length,
            &_executionState.callArgumentStorage,
        );
        scope(exit) callArguments.release;
        auto argumentPlaces = callArguments.places;
        auto argumentExpressions = callArguments.expressions;
        auto evaluatedArguments = callArguments.references;
        if (call.arguments !is null) {
            foreach (index, argument; *call.arguments) {
                auto parameter = call.f is null ||
                    call.f.parameters is null ||
                    index >= call.f.parameters.length
                    ? null
                    : (*call.f.parameters)[index];
                EvaluatedReferenceArgument evaluated;
                if (parameter !is null && parameterIsLazy(parameter))
                    // The lazy argument is captured as an expression below;
                    // this aligned entry is never bound or evaluated.
                    argumentPlaces[index] = Place.init;
                else if (nativeCall && nativeReferenceParameter(call.f, index))
                    argumentPlaces[index] = runRefArgumentExpression(
                        argument,
                        evaluated,
                    );
                else if (parameter !is null &&
                    isReferenceParameter(call.f, index, parameter))
                    argumentPlaces[index] = runRefArgumentExpression(
                        argument,
                        evaluated,
                    );
                else {
                    auto argumentDestination = ConstructionDestination(Place(
                        _activationFrame.temporaryAddress(argument),
                        argument.type,
                    ));
                    runExpression(argument, argumentDestination);
                    argumentPlaces[index] = argumentDestination.place;
                }
                argumentExpressions[index] = argument;
                evaluatedArguments[index] = evaluated;
            }
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.compiler_builtins:
                executeCompilerBuiltin, isExecutableCompilerBuiltin;

            if (isExecutableCompilerBuiltin(call.f)) {
                if (constructionDestination !is null) {
                    executeCompilerBuiltin(
                        call.loc,
                        call.f,
                        argumentPlaces,
                        constructionDestination.place,
                    );
                    constructionDestination.markConstructed;
                }
                return;
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
            void* receiverPointerAddress;
            bool hasReceiverPointerAddress;
            Place receiverValuePlace;
            if (
                !nativeCall &&
                dot.e1.type.toBasetype.isTypeStruct !is null &&
                hasDirectWriteProjectionPlace(dot.e1)
            ) {
                materializeProjectionRoot(dot.e1);
                // Mutable because the borrowed-block constructor accepts the
                // writable receiver address that the method will mutate.
                auto receiverPlace = directWriteProjectionPlace(dot.e1);
                receiverPointerAddress = receiverPlace.address;
                hasReceiverPointerAddress = true;
                receiverValuePlace = receiverPlace;
            } else if (auto pointerReceiver = dot.e1.isPtrExp) {
                receiverPointerAddress =
                    pointerOperandPlace(pointerReceiver.e1).deref.address;
                hasReceiverPointerAddress = true;
                receiverValuePlace = Place(
                    receiverPointerAddress,
                    pointerReceiver.type,
                );
            } else if (
                dot.e1.isIndexExp !is null &&
                dot.e1.type.toBasetype.isTypeStruct !is null
            ) {
                import dmd.tokens: EXP;
                receiverPointerAddress = addressOfExpression(dot.e1, EXP.address);
                hasReceiverPointerAddress = true;
                receiverValuePlace = Place(receiverPointerAddress, dot.e1.type);
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
                receiverPointerAddress = addressOfExpression(dot.e1, EXP.address);
                hasReceiverPointerAddress = true;
                receiverValuePlace = Place(receiverPointerAddress, dot.e1.type);
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
                receiverPointerAddress = addressOfExpression(dot.e1, EXP.address);
                hasReceiverPointerAddress = true;
                receiverValuePlace = Place(receiverPointerAddress, dot.e1.type);
            } else
                receiverValuePlace = constructedExpressionPlace(dot.e1);

            auto receiver = memberReceiverPlace(receiverValuePlace);

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
            const interpreterAllocatedClass =
                dot.e1.type.toBasetype.isTypeClass !is null &&
                receiver.address in nativeClassOwners;
            auto receiverTypeInfoName = loadTypeInfoName(receiverValuePlace);
            if (
                dot.e1.type.toBasetype.isTypeClass !is null &&
                receiver.address is null &&
                receiverTypeInfoName is null
            )
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
                    receiverTypeInfoName !is null &&
                    declarationName(call.f) == "initializer" &&
                    argumentPlaces.length == 0
                ) {
                    typeInfoClassInitializer(
                        *receiverTypeInfoName,
                        constructionDestination,
                    );
                    return;
                }

                // An interpreted-only TypeInfo has symbolic identity but no
                // resident class body on which druntime's member can run.
                // TypeInfo.opEquals defines equality by that identity (and
                // accepts null), so answer it before native object dispatch.
                if (
                    receiverTypeInfoName !is null &&
                    call.f.ident !is null &&
                    call.f.ident.toString == "opEquals" &&
                    argumentPlaces.length == 1
                ) {
                    auto argumentTypeInfoName =
                        loadTypeInfoName(argumentPlaces[0]);
                    const argumentIsNull =
                        argumentPlaces[0].type.toBasetype.isTypeClass !is null &&
                        argumentPlaces[0].loadReference is null;
                    if (argumentTypeInfoName !is null || argumentIsNull) {
                        if (constructionDestination !is null) {
                            constructionDestination.place.storeNativeScalar(
                                argumentTypeInfoName !is null &&
                                *argumentTypeInfoName == *receiverTypeInfoName,
                            );
                            constructionDestination.markConstructed;
                        }
                        return;
                    }
                }

                import quickbite.frontend.dmd.functions:
                    hasNoInterpretableSource, noAvailableSourceMessage;

                if (
                    call.f.isCtorDeclaration !is null &&
                    isThisOrSuperMemberCall(call)
                )
                    return runThisConstructorCall(
                        call.f,
                        argumentPlaces,
                        argumentExpressions,
                        evaluatedArguments,
                        constructionDestination,
                    );

                auto function_ = resolveMemberFunction(call.f, receiver);
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
                        auto nativeReceiverPlace = function_.isCtorDeclaration !is null
                            ? nativeConstructorReceiverPlace(
                                function_,
                                receiver,
                            )
                            : receiver;
                        NativeCallResult nativeResult;
                        if (invokeNativeDeclaration(
                            function_,
                            nativeReceiverPlace,
                            receiverType,
                            dot.e1,
                            argumentPlaces,
                            argumentExpressions,
                            evaluatedArguments,
                            returnsReceiver,
                            nativeResult,
                            hasReceiverPointerAddress
                                ? receiverPointerAddress
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
                                return;
                            }
                            storeNativeCallResult(
                                constructionDestination,
                                nativeResult.value,
                            );
                            return;
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
                runMemberFunction(
                    function_,
                    dot.e1,
                    receiver,
                    argumentPlaces,
                    argumentExpressions,
                    evaluatedArguments,
                    hasReceiverPointerAddress
                        ? receiverPointerAddress
                        : null,
                    constructionDestination,
                );
                return;
            }
        }

        if (call.f !is null) {
            import quickbite.frontend.dmd.functions: noAvailableSourceMessage;
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;

            if (nativeCall) {
                if (isMonitorOperation(call.f))
                    return;

                try {
                    NativeCallResult nativeResult;
                        if (!call.f.needThis && invokeNativeDeclaration(
                            call.f,
                            Place.init,
                            null,
                            null,
                            argumentPlaces,
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
                            return;
                        }
                        storeNativeCallResult(
                            constructionDestination,
                            nativeResult.value,
                        );
                        return;
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

            if (call.f.isNested && hasThis) {
                runMemberFunction(
                    call.f,
                    null,
                    thisValue,
                    argumentPlaces,
                    argumentExpressions,
                    evaluatedArguments,
                    null,
                    constructionDestination,
                );
                return;
            }

            runFunction(
                call.f,
                argumentPlaces,
                argumentExpressions,
                false,
                evaluatedArguments,
                null,
                constructionDestination,
            );
            return;
        }

        if (auto function_ = functionPointerExpressionFunction(call.e1)) {
            import quickbite.frontend.dmd.functions:
                ensureFunctionBodySemantic, hasNoInterpretableSource,
                noAvailableSourceMessage;
            import quickbite.backends.interpreter.interception_guard:
                bodyContainsAsm;
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;

            ensureFunctionBodySemantic(function_);
            if (
                hasNoInterpretableSource(function_) ||
                bodyContainsAsm(function_)
            ) {
                try {
                    NativeCallResult nativeResult;
                    if (invokeNativeFunctionPointer(
                        function_,
                        functionPointerCallSignature(call.e1),
                        argumentPlaces,
                        argumentExpressions,
                        evaluatedArguments,
                        nativeResult,
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
                            return;
                        }
                        storeNativeCallResult(
                            constructionDestination,
                            nativeResult.value,
                        );
                        return;
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
            if (function_.isNested && hasThis) {
                runMemberFunction(
                    function_,
                    null,
                    thisValue,
                    argumentPlaces,
                    argumentExpressions,
                    evaluatedArguments,
                    null,
                    constructionDestination,
                );
                return;
            }

            runFunction(
                function_,
                argumentPlaces,
                argumentExpressions,
                false,
                evaluatedArguments,
                null,
                constructionDestination,
            );
            return;
        }

        if (auto variable = lazyCallVariable(call)) {
            runLazyArgument(variable, constructionDestination);
            return;
        }

        // DMD's implicit dereference of a function-pointer-typed callee
        // (`fp1()`) leaves `call.e1.type` the bare, unsized function type
        // (`int()`); `typeByteSize` cannot size a temporary from that.
        // Retype to the sized function-pointer form instead -- at native
        // layout the callee value IS a pointer, exactly what compiled D
        // loads here. A delegate-typed `call.e1` already has a sized type
        // and is used unchanged.
        import quickbite.backends.interpreter.place: Place;
        import dmd.typesem: pointerTo;

        auto calleeType = call.e1.type.toBasetype.isTypeFunction !is null
            ? call.e1.type.pointerTo
            : call.e1.type;
        auto calleeTemporary = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(call.e1, calleeType),
            calleeType,
        ));
        runExpression(call.e1, calleeTemporary);
        const isDelegate = calleeType.toBasetype.isTypeDelegate !is null;
        auto functionPointer = calleeType.toBasetype.isTypePointer;
        const isFunctionPointer = functionPointer !is null &&
            functionPointer.nextOf.toBasetype.isTypeFunction !is null;
        if (!isDelegate && !isFunctionPointer)
            throw new Exception("Unsupported eval call.");

        DelegateSlot calleeSlot;
        if (isDelegate)
            calleeSlot = loadDelegateSlot(calleeTemporary.place);
        else if (auto id = loadFunctionPointerId(calleeTemporary.place))
            calleeSlot = interpretedDelegateSlot(*id);
        else
            throw new Exception("Unsupported eval call.");
        if (calleeSlot.isNative) {
            runNativeDelegateCall(
                calleeSlot,
                call,
                argumentPlaces,
                argumentExpressions,
                constructionDestination,
            );
            return;
        }

        if (calleeSlot.functionPointerId in _executionState.delegates) {
            runDelegateCall(
                calleeSlot,
                argumentPlaces,
                argumentExpressions,
                evaluatedArguments,
                constructionDestination,
            );
            return;
        }

        auto function_ = calleeSlot.functionPointerId in functionPointers;
        if (function_ is null)
            throw new Exception("Unsupported eval call.");
        runFunction(
            *function_,
            argumentPlaces,
            argumentExpressions,
            false,
            evaluatedArguments,
            null,
            constructionDestination,
        );
        return;
    }

    // DMD lowers a user-constructor receiver to `((S __t = <placeholder>;) ,
    // __t).__ctor(args)`, where `<placeholder>` is `__t`'s type's own
    // default value -- never the constructor's real arguments. Evaluating
    // that declaration (`executeDeclaration`, whether reached from
    // `addressOfExpression`'s `CommaExp` handling or the receiver's own
    // evaluation) arms
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

    // A no-copy `NativeAggregate` view of an already-materialized place.
    private NativeAggregate borrowedAggregate(Place place) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        return NativeAggregate(
            place.type,
            NativeBlock.borrow(place.address, typeByteSize(place.type)),
        );
    }

    // Evaluate a reference argument's lvalue operands exactly once and return
    // its typed place. An addressable argument names the caller's live
    // storage. An rvalue is constructed in one activation temporary that a
    // synthetic reference parameter can borrow.
    private Place runRefArgumentExpression(
        imported!"dmd.expression".Expression argument,
        out EvaluatedReferenceArgument evaluated,
    ) {
        // A ref-returning call used as a `ref` argument passes the returned
        // lvalue itself onward: bind the callee's reference slot to that
        // lvalue's address so writes through the parameter reach it, instead
        // of a copied call result.
        if (auto call = argument.isCallExp)
            if (call.f !is null && returnsRef(call.f)) {
                import dmd.tokens: EXP;
                import quickbite.backends.interpreter.place: Place;

                auto address = refReturningCallAddress(call, EXP.address);
                // `auto`: a reference argument needs a mutable address.
                evaluated.address = address;
                return Place(evaluated.address, argument.type);
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
            auto place = projectionPlace(argument);
            evaluated.address = place.address;
            return place;
        }

        if (argument.isDotVarExp !is null) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.place: Place;

            auto address = addressOfExpression(argument, EXP.address);
            // `auto`: a reference argument needs a mutable address.
            evaluated.address = address;
            return Place(evaluated.address, argument.type);
        }

        if (auto pointer = argument.isPtrExp) {
            const address = pointerOperandPlace(pointer.e1).deref.address;
            if (address !is null) {
                evaluated.address = cast(void*) address;
                return Place(evaluated.address, argument.type);
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
                    return Place(evaluated.address, argument.type);
                }
            }
        }

        if (auto conditional = argument.isCondExp) {
            auto selected = conditionTruthy(conditional.econd)
                ? conditional.e1
                : conditional.e2;
            auto value = runRefArgumentExpression(selected, evaluated);
            if (evaluated.selectedLvalue is null)
                evaluated.selectedLvalue = selected;
            return value;
        }

        auto var = argument.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable !is null) {
            evaluated.address = addressableBindingBase(variable);
            return Place(evaluated.address, argument.type);
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

        import quickbite.backends.interpreter.place: Place;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(argument),
            argument.type,
        ));
        runExpression(argument, destination);
        return destination.place;
    }

    // Run an interpreted delegate that native code called back into through the
    // FFI reverse bridge. The adapter supplies typed places and the recursive
    // walker consumes those same places directly.
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
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;

        Place[1] inlineCallbackArgument;
        Expression[1] inlineCallbackExpression;
        EvaluatedReferenceArgument[1] inlineEvaluatedArgument;
        auto argumentPlaces = parameterTypes.length == 0
            ? null
            : parameterTypes.length == 1
                ? inlineCallbackArgument[]
                : new Place[](parameterTypes.length);
        auto argumentExpressions = parameterTypes.length == 0
            ? null
            : parameterTypes.length == 1
                ? inlineCallbackExpression[]
                : new Expression[](parameterTypes.length);
        auto evaluatedArguments = parameterTypes.length == 0
            ? null
            : parameterTypes.length == 1
                ? inlineEvaluatedArgument[]
                : new EvaluatedReferenceArgument[](parameterTypes.length);
        auto runtime = callback.functionPointerId in _executionState.delegates;
        foreach (index, parameterType; parameterTypes) {
            auto abiPlace = Place(
                argumentBuffers[index],
                parameterType,
            );
            argumentPlaces[index] = abiPlace;

            // DMD paints the generated UTF foreach delegate from `ref C` to
            // `void*` so druntime can use one callback ABI for every code-unit
            // width. libffi supplies the pointer value in its ABI argument
            // cell. Rebind the interpreted function's reference parameter to
            // the pointed-to code unit instead of copying the pointer bytes as
            // the character value.
            if (
                runtime !is null &&
                runtime.function_.parameters !is null &&
                index < runtime.function_.parameters.length &&
                parameterType.toBasetype.ty == TY.Tpointer
            ) {
                auto parameter = (*runtime.function_.parameters)[index];
                if (isReferenceParameter(runtime.function_, index, parameter)) {
                    auto address = abiPlace.deref.address;
                    argumentPlaces[index] = Place(address, parameter.type);
                    evaluatedArguments[index].address = address;
                }
            }
        }

        // A void-returning callback has no destination to construct into
        // (decision 7); a non-void one needs a real typed temporary, sized
        // by its own declared return type, or the interpreted delegate's
        // return has nowhere to land.
        if (returnType.ty == TY.Tvoid) {
            runDelegateCall(
                interpretedDelegateSlot(callback.functionPointerId),
                argumentPlaces,
                argumentExpressions,
                evaluatedArguments,
            );
            return;
        }

        resultBuffer[] = 0;
        auto destination = ConstructionDestination(Place(resultBuffer.ptr, returnType));
        runDelegateCall(
            interpretedDelegateSlot(callback.functionPointerId),
            argumentPlaces,
            argumentExpressions,
            evaluatedArguments,
            &destination,
        );
        extendInboundIntegerResult(resultBuffer, returnType);
    }

    private void runDelegateCall(
        in DelegateSlot callee,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        ConstructionDestination* constructionDestination = null,
    ) {
        auto runtime = callee.functionPointerId in _executionState.delegates;
        if (runtime is null)
            throw new Exception("Unsupported eval call.");

        if (runtime.hasReceiver) {
            runMemberFunction(
                runtime.function_,
                null,
                delegateReceiver(*runtime),
                argumentPlaces,
                argumentExpressions,
                evaluatedArguments,
                null,
                constructionDestination,
            );
            return;
        }

        runFunction(
            runtime.function_,
            argumentPlaces,
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
    private void runNativeDelegateCall(
        in DelegateSlot callee,
        imported!"dmd.expression".CallExp call,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ConstructionDestination* constructionDestination,
    ) {
        import quickbite.backends.interpreter.native_call_adapter:
            InterpreterInboundTrampolineSession, NativeCallException,
            NativeCallRequest, NativeCallResult, invokeNative;
        import dmd.mtype: TypeFunction;

        auto delegateType = call.e1.type.toBasetype;
        auto functionType = delegateType.nextOf is null
            ? null
            : cast(TypeFunction) delegateType.nextOf;
        auto nativeArguments = NativeCallArguments(
            argumentExpressions,
            &_executionState.nativeCallArgumentStorage,
        );
        scope(exit) nativeArguments.release;
        fillNativeCallOperands(
            null,
            argumentPlaces,
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
                delegateAddress: callee.funcptr,
                delegateContext: callee.context,
                resultAddress: constructionDestination is null
                    ? null
                    : constructionDestination.place.address,
                argumentTypes: nativeArguments.types,
                argumentOperands: nativeArguments.operands,
                callbackSession: durableInboundSession,
            );
            NativeCallResult nativeResult;
            if (invokeNative(request, nativeResult)) {
                storeNativeCallResult(constructionDestination, nativeResult.value);
                return;
            }
        } catch (NativeCallException exception) {
            throwNativeException(exception);
        }

        throw new Exception("Unsupported eval call.");
    }

    private Place delegateReceiver(RuntimeDelegate runtime) {
        return Place(runtime.receiver.address, runtime.receiver.type);
    }

    private FuncDeclaration resolveMemberFunction(
        FuncDeclaration function_,
        Place receiver,
    ) {
        auto class_ = dynamicClass(classObjectFromReceiverPlace(receiver));
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

    private imported!"dmd.dclass".ClassDeclaration dynamicClass(
        ClassObject value,
    ) {
        if (value.address is null || value.type is null)
            return null;
        auto classType = value.type.toBasetype.isTypeClass;
        return classType is null ? null : classType.sym;
    }

    private bool classHasType(ClassObject value, in string name) {
        auto class_ = dynamicClass(value);
        if (class_ is null)
            return false;

        foreach (typeName; classTypeNames(class_))
            if (typeName == name)
                return true;
        return false;
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

    private FuncDeclaration functionPointerExpressionFunction(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto variable = expression.isVarExp)
            return variable.var.isFuncDeclaration;

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

    private imported!"dmd.mtype".TypeFunction functionPointerCallSignature(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression is null || expression.type is null)
            return null;

        auto type = expression.type.toBasetype;
        if (auto functionType = type.isTypeFunction)
            return functionType;
        if (auto pointerType = type.isTypePointer)
            return pointerType.nextOf is null
                ? null
                : pointerType.nextOf.toBasetype.isTypeFunction;
        return null;
    }

    // `AggregateValue.elementAt`'s plain memory read sees a delegate-typed
    // element's zeroed bytes, not its live callable identity. A live
    // delegate entry is registered out-of-band in
    // `nativeDelegateSlots`, keyed by its own element address, exactly the
    // same gap `loadNativePointerElement`'s identical `TY.Tdelegate` arm
    // checks before falling through to a plain read.
    private void runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in bool captureLocals = false,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        in void*[VarDeclaration] closureAddresses = null,
        ConstructionDestination* constructionDestination = null,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = acquireActivationFrame(function_, layout);
        child._returnDestination = constructionDestination;
        forkExecutionStateInto(child);
        scope(exit) child.releaseActivationFrame(function_);
        bindCapturedReferenceSlots(function_, child, closureAddresses);
        child.bindFunctionParameters(
            function_,
            argumentPlaces,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            mergeFunctionState(
                function_,
                argumentExpressions,
                child,
                captureLocals,
            );
            throw exception;
        }
        mergeFunctionState(
            function_,
            argumentExpressions,
            child,
            captureLocals,
        );
    }

    // DMD keeps a member function's hidden `this` declaration separate from
    // its ordinary argument list. A receiver already bound onto the
    // walker's own `thisValue` channel names its address directly, whether
    // it is a struct's own storage or a class's body address. Retain it for
    // `ref this` forwarding after parameter binding (which may clear a stale entry for that
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

    private void runMemberFunction(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"quickbite.backends.interpreter.place".Place receiver,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        // Set by a caller that already composed the receiver's place,
        // evaluated a `PtrExp` operand, or evaluated a ref-returning `CallExp`
        // receiver, and retained its address. The `this`-rebind below borrows
        // that same address instead of walking the receiver a second time,
        // which matters when the receiver expression is side-effecting (e.g.
        // `p()` in `p().get()`, `i++` in `a[i++].method()`, or the call
        // itself in `get(holder, evaluations).slot`).
        const(void)* precomputedReceiverAddress = null,
        ConstructionDestination* constructionDestination = null,
    ) {
        if (
            declarationName(function_) == "next" &&
            receiver.type.toBasetype.isTypeClass !is null
        ) {
            auto object = classObjectFromReceiverPlace(receiver);
            if (classHasType(object, "Throwable")) {
                if (auto next = object.address in nativeThrowableNext) {
                    storeReferenceCallResult(
                        constructionDestination,
                        next.address,
                    );
                    return;
                }

                if (classHasFieldNamed(object, "_nextInChainPtr")) {
                    auto next = classFieldNamed(object, "_nextInChainPtr")
                        .deref.address;
                    storeReferenceCallResult(constructionDestination, next);
                    return;
                }
            }
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = acquireActivationFrame(function_, layout);
        child._returnDestination = constructionDestination;
        forkExecutionStateInto(child);
        scope(exit) child.releaseActivationFrame(
            function_,
            function_.isConstructorFunction && constructionDestination is null,
        );
        bindCapturedReferenceSlots(
            function_,
            child,
            nestedReceiverCapturedAddresses(function_, receiver),
        );
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindFunctionParameters(
            function_,
            argumentPlaces,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
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
                precomputedReceiverAddress !is null &&
                receiverExpression !is null
            ) {
                copyPlaceValue(
                    Place(
                        cast(void*) precomputedReceiverAddress,
                        receiverExpression.type,
                    ),
                    constructionDestination.place,
                );
            } else {
                copyPlaceValue(child.thisValue, constructionDestination.place);
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

            void* address;
            if (precomputedReceiverAddress !is null) {
                address = cast(void*) precomputedReceiverAddress;
            } else if (
                placeExpression.isThisExp !is null &&
                thisAddress !is null
            ) {
                address = thisAddress;
            } else if (
                placeExpression.isDotVarExp !is null &&
                placeExpression.isDotVarExp.e1.isThisExp !is null &&
                thisAddress !is null
            ) {
                import quickbite.backends.interpreter.place: Place;

                address = Place(
                    thisAddress,
                    placeExpression.isDotVarExp.e1.type,
                ).field(placeExpression.isDotVarExp.var.isVarDeclaration).address;
            } else {
                address = addressOfExpression(placeExpression, EXP.address);
            }
            child.thisAddress = address;
            if (child._activationFrame.hasReferenceSlot(function_.vthis))
                child._activationFrame.setReferenceSlot(
                    function_.vthis,
                    child.thisAddress,
                );
            // `child.thisValue` is a place by construction here, so it
            // always already carries the receiver's real type -- no
            // fallback to the declared `function_.vthis.type` needed.
            child.bindStructReceiver(Place(
                address,
                child.thisValue.type,
            ));
        }

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            mergeMemberFunctionState(
                function_,
                receiverExpression,
                argumentExpressions,
                child,
            );
            throw exception;
        }
        mergeMemberFunctionState(
            function_,
            receiverExpression,
            argumentExpressions,
            child,
        );

        if (function_.isConstructorFunction) {
            if (constructionDestination !is null) {
                if (constructionDestination.isFresh)
                    constructionDestination.markConstructed;
                return;
            }
            return;
        }
    }

    private void mergeFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in bool captureLocals = false,
    ) {
        mergeLazyArgumentMapsFrom(child);
    }

    private void mergeMemberFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
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
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions = null,
        FrameBlock callerFrame = FrameBlock.init,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
    ) {
        if (argumentPlaces.length == 0) {
            if (function_.parameters !is null && function_.parameters.length != 0)
                throw new Exception("Unsupported interpreter call arguments.");
            return;
        }

        if (
            function_.parameters is null ||
            function_.parameters.length != argumentPlaces.length
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
                if (!bound) {
                    bindSyntheticReferenceSlot(
                        parameter,
                        argumentPlaces[index],
                    );
                }
                continue;
            }

            if (parameterIsReference) {
                bindSyntheticReferenceSlot(parameter, argumentPlaces[index]);
                continue;
            }

            copyPlaceValue(
                argumentPlaces[index],
                bindingPlace(parameter),
            );
        }
    }

    // The rvalue argument's bytes already sit in a typed activation
    // temporary (`runRefArgumentExpression`'s construction); copy them
    // place-to-place at native layout.
    private void bindSyntheticReferenceSlot(
        VarDeclaration parameter,
        imported!"quickbite.backends.interpreter.place".Place source,
    ) {
        import quickbite.backends.interpreter.place: Place;

        auto block = allocateSyntheticReferenceSlotBlock(parameter);
        copyPlaceValue(
            source,
            Place(block.address, parameter.type),
        );
        retainTemporaryPointerOwner(block);
        _activationFrame.setReferenceSlot(parameter, block.address);
    }

    private imported!"quickbite.backends.interpreter.native_block".NativeBlock
        allocateSyntheticReferenceSlotBlock(VarDeclaration parameter) {
        import quickbite.backends.interpreter.layout:
            typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        return NativeBlock.allocate(
            typeByteSize(parameter.type),
            typeHasPointers(parameter.type)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );
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

    private void runLazyArgument(
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
        runLazyArgumentExpression(*expression, constructionDestination);
    }

    private void runLazyArgumentExpression(
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
            return;
        }

        executeForEffect(expression);
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
    // answers them.
    private bool equalOperands(imported!"dmd.expression".EqualExp equal) {
        import quickbite.backends.interpreter.place: Place;

        auto leftTemporary = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(equal.e1),
            equal.e1.type,
        ));
        runExpression(equal.e1, leftTemporary);
        auto rightTemporary = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(equal.e2),
            equal.e2.type,
        ));
        runExpression(equal.e2, rightTemporary);
        return equalPlaces(leftTemporary.place, rightTemporary.place);
    }

    private bool equalPlaces(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.native_scalar: nativeScalarKindOf;

        const leftKind = nativeScalarKindOf(left.type);
        const rightKind = nativeScalarKindOf(right.type);
        if (leftKind == TY.Tnull)
            return identityPlaceIsNull(right);
        if (rightKind == TY.Tnull)
            return identityPlaceIsNull(left);
        if (
            leftKind != rightKind &&
            scalarEqualityKind(leftKind) &&
            scalarEqualityKind(rightKind)
        )
            return scalarPlaceAsComplex(left) == scalarPlaceAsComplex(right);

        switch (leftKind) with (TY) {
            case Tsarray, Tarray: return equalArrayPlaces(left, right);
            case Tstruct: return equalStructPlaces(left, right);
            case Tdelegate: return equalDelegatePlaces(left, right);
            case Tclass: return classPlacesAreIdentical(left, right);
            case Taarray: return left.loadReference is right.loadReference;
            case Tpointer:
                if (left.type.toBasetype.nextOf.toBasetype.ty == Tfunction)
                    return functionPointerPlacesAreIdentical(left, right);
                return left.loadReference is right.loadReference;
            case Tbool: return scalarPlacesAreEqual!bool(left, right);
            case Tint8: return scalarPlacesAreEqual!byte(left, right);
            case Tuns8: return scalarPlacesAreEqual!ubyte(left, right);
            case Tchar: return scalarPlacesAreEqual!char(left, right);
            case Tint16: return scalarPlacesAreEqual!short(left, right);
            case Tuns16: return scalarPlacesAreEqual!ushort(left, right);
            case Twchar: return scalarPlacesAreEqual!wchar(left, right);
            case Tint32: return scalarPlacesAreEqual!int(left, right);
            case Tuns32: return scalarPlacesAreEqual!uint(left, right);
            case Tdchar: return scalarPlacesAreEqual!dchar(left, right);
            case Tint64: return scalarPlacesAreEqual!long(left, right);
            case Tuns64: return scalarPlacesAreEqual!ulong(left, right);
            case Tfloat32: return scalarPlacesAreEqual!float(left, right);
            case Tfloat64: return scalarPlacesAreEqual!double(left, right);
            case Tfloat80: return scalarPlacesAreEqual!real(left, right);
            case Timaginary32: return scalarPlacesAreEqual!ifloat(left, right);
            case Timaginary64: return scalarPlacesAreEqual!idouble(left, right);
            case Timaginary80: return scalarPlacesAreEqual!ireal(left, right);
            case Tcomplex32: return scalarPlacesAreEqual!cfloat(left, right);
            case Tcomplex64: return scalarPlacesAreEqual!cdouble(left, right);
            case Tcomplex80: return scalarPlacesAreEqual!creal(left, right);
            case Tvector:
                return borrowedAggregate(left).storage.bytes ==
                    borrowedAggregate(right).storage.bytes;
            default: throw new Exception("Unsupported interpreter equality operands.");
        }
    }

    private bool scalarEqualityKind(in imported!"dmd.astenums".TY kind) {
        import dmd.astenums: TY;

        switch (kind) with (TY) {
            case Tbool, Tint8, Tuns8, Tchar, Tint16, Tuns16, Twchar,
                Tint32, Tuns32, Tdchar, Tint64, Tuns64, Tfloat32,
                Tfloat64, Tfloat80, Timaginary32, Timaginary64,
                Timaginary80, Tcomplex32, Tcomplex64, Tcomplex80:
                return true;
            default: return false;
        }
    }

    private creal scalarPlaceAsComplex(
        imported!"quickbite.backends.interpreter.place".Place place,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.native_scalar: nativeScalarKindOf;

        switch (nativeScalarKindOf(place.type)) with (TY) {
            case Tbool: return cast(creal) place.loadNativeScalar!bool;
            case Tint8: return cast(creal) place.loadNativeScalar!byte;
            case Tuns8: return cast(creal) place.loadNativeScalar!ubyte;
            case Tchar: return cast(creal) place.loadNativeScalar!char;
            case Tint16: return cast(creal) place.loadNativeScalar!short;
            case Tuns16: return cast(creal) place.loadNativeScalar!ushort;
            case Twchar: return cast(creal) place.loadNativeScalar!wchar;
            case Tint32: return cast(creal) place.loadNativeScalar!int;
            case Tuns32: return cast(creal) place.loadNativeScalar!uint;
            case Tdchar: return cast(creal) place.loadNativeScalar!dchar;
            case Tint64: return cast(creal) place.loadNativeScalar!long;
            case Tuns64: return cast(creal) place.loadNativeScalar!ulong;
            case Tfloat32: return cast(creal) place.loadNativeScalar!float;
            case Tfloat64: return cast(creal) place.loadNativeScalar!double;
            case Tfloat80: return cast(creal) place.loadNativeScalar!real;
            case Timaginary32: return cast(creal) place.loadNativeScalar!ifloat;
            case Timaginary64: return cast(creal) place.loadNativeScalar!idouble;
            case Timaginary80: return cast(creal) place.loadNativeScalar!ireal;
            case Tcomplex32: return cast(creal) place.loadNativeScalar!cfloat;
            case Tcomplex64: return cast(creal) place.loadNativeScalar!cdouble;
            case Tcomplex80: return place.loadNativeScalar!creal;
            default: throw new Exception("Unsupported scalar equality place.");
        }
    }

    // A delegate compares equal to another by its runtime `{function,
    // context}` pair (D's builtin delegate equality) -- not by the internal
    // `functionPointerId` this walker mints fresh for every delegate
    // EXPRESSION evaluation. `&s1.get` evaluated twice yields two different
    // ids for the identical function+receiver, so comparing those ids alone
    // would answer unequal. `contextPointer` already carries the receiver's own
    // binding address for a member-function delegate, not a copy
    // (`delegateContextPointer`'s `VarExp` arm resolves it the same way for
    // every delegate kind, member or closure), so comparing it directly is
    // sufficient for a NON-capturing delegate (bound method or plain
    // function pointer) -- no separate receiver-identity tracking is
    // needed there. A CAPTURING closure literal is different: every
    // literal-created delegate has a null `contextPointer`, so two
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
    private bool equalDelegatePlaces(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        const leftSlot = loadDelegateSlot(left);
        const rightSlot = loadDelegateSlot(right);
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

    private bool equalArrayPlaces(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        if (left.arrayLength != right.arrayLength)
            return false;

        foreach (index; 0 .. left.arrayLength)
            if (!equalPlaces(left.index(index), right.index(index)))
                return false;

        return true;
    }

    private bool equalStructPlaces(
        imported!"quickbite.backends.interpreter.place".Place left,
        imported!"quickbite.backends.interpreter.place".Place right,
    ) {
        import quickbite.backends.interpreter.layout:
            structFields, typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;

        auto structType = left.type.toBasetype.isTypeStruct;
        if (structType.sym.xeq !is null) {
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
            return placeIsTruthy(destination.place);
        }

        foreach (field; structFields(structType))
            if (!equalPlaces(left.field(field), right.field(field)))
                return false;
        return true;
    }

    private imported!"dmd.expression".BinExp scalarCompoundAssignment(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType;

        switch (expression.op) with (EXP) {
            case addAssign:
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
                break;
            default:
                return null;
        }

        auto assignment = expression.isBinExp;
        if (
            assignment is null ||
            assignment.e1 is null ||
            assignment.e1.type is null ||
            (
                !isNativeScalarType(assignment.e1.type) &&
                assignment.e1.type.toBasetype.isTypePointer is null
            )
        )
            return null;
        return assignment;
    }

    // A scalar compound assignment selects its live place before it reads the
    // old value or evaluates the RHS. The selected native place remains the
    // result source after the write, so a caller either receives the new value
    // in its typed destination or discards it.
    private void runScalarCompoundAssignment(
        imported!"dmd.expression".BinExp assignment,
        imported!"quickbite.backends.interpreter.place".Place* destination,
    ) {
        import dmd.astenums: TY;

        bool clearsProjectionRoot;
        auto target = scalarCompoundAssignmentTarget(
            assignment.e1,
            assignment.type,
            clearsProjectionRoot,
        );

        if (target.type.toBasetype.ty == TY.Tpointer) {
            runPointerCompoundAssignment(assignment, target, destination);
        } else {
            // DMD merges both arithmetic operands before this point while it
            // retains the lvalue's original storage type in assignment.type.
            // Dispatch on that merged operation type, then cast the complete
            // result back to the selected target place.
            switch (assignment.e1.type.toBasetype.ty) with (TY) {
                case Tbool: runScalarCompoundAssignmentAs!bool(assignment, target); break;
                case Tint8: runScalarCompoundAssignmentAs!byte(assignment, target); break;
                case Tuns8: runScalarCompoundAssignmentAs!ubyte(assignment, target); break;
                case Tchar: runScalarCompoundAssignmentAs!char(assignment, target); break;
                case Tint16: runScalarCompoundAssignmentAs!short(assignment, target); break;
                case Tuns16: runScalarCompoundAssignmentAs!ushort(assignment, target); break;
                case Twchar: runScalarCompoundAssignmentAs!wchar(assignment, target); break;
                case Tint32: runScalarCompoundAssignmentAs!int(assignment, target); break;
                case Tuns32: runScalarCompoundAssignmentAs!uint(assignment, target); break;
                case Tdchar: runScalarCompoundAssignmentAs!dchar(assignment, target); break;
                case Tint64: runScalarCompoundAssignmentAs!long(assignment, target); break;
                case Tuns64: runScalarCompoundAssignmentAs!ulong(assignment, target); break;
                case Tfloat32: runScalarCompoundAssignmentAs!float(assignment, target); break;
                case Tfloat64: runScalarCompoundAssignmentAs!double(assignment, target); break;
                case Tfloat80: runScalarCompoundAssignmentAs!real(assignment, target); break;
                case Timaginary32: runScalarCompoundAssignmentAs!ifloat(assignment, target); break;
                case Timaginary64: runScalarCompoundAssignmentAs!idouble(assignment, target); break;
                case Timaginary80: runScalarCompoundAssignmentAs!ireal(assignment, target); break;
                case Tcomplex32: runScalarCompoundAssignmentAs!cfloat(assignment, target); break;
                case Tcomplex64: runScalarCompoundAssignmentAs!cdouble(assignment, target); break;
                case Tcomplex80: runScalarCompoundAssignmentAs!creal(assignment, target); break;
                default: throw new Exception("Unsupported eval compound assignment.");
            }
            copyScalarCompoundAssignmentResult(target, destination);
        }

        if (clearsProjectionRoot)
            clearProjectionRootUninitialized(assignment.e1);
    }

    private imported!"quickbite.backends.interpreter.place".Place
    scalarCompoundAssignmentTarget(
        imported!"dmd.expression".Expression expression,
        imported!"dmd.mtype".Type targetType,
        out bool clearsProjectionRoot,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.messages:
            uninitializedVariableMessage;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isPointerType;

        if (auto variableExpression = expression.isVarExp) {
            auto variable = variableExpression.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported eval compound assignment target.");

            materializeDatasegInitializer(variable);
            if (!hasBindingPlace(variable))
                throw new Exception("Unsupported eval compound assignment target.");
            if (isUninitializedBinding(variable))
                throw new Exception(uninitializedVariableMessage(
                    variable,
                    currentFunction,
                ));

            clearsProjectionRoot = true;
            return bindingPlace(variable);
        }

        if (isDirectProjectionWriteTarget(expression)) {
            clearsProjectionRoot = true;
            return directWriteProjectionPlace(expression);
        }

        if (auto pointer = expression.isPtrExp)
            return Place(
                pointerOperandPlace(pointer.e1).deref.address,
                targetType,
            );

        if (auto index = expression.isIndexExp)
            if (isPointerType(index.e1.type)) {
                auto pointer = pointerOperandPlace(index.e1);
                const arrayIndex = scalarOperand!size_t(index.e2);
                return Place(pointer.index(arrayIndex).address, targetType);
            }

        // Class-rooted and other non-binding array projections do not pass
        // the direct-place predicate above. Their address walk still selects
        // the complete lvalue once, including every nested index.
        if (expression.isIndexExp !is null) {
            auto address = addressOfExpression(expression, EXP.address);
            // `auto`: a `Place` needs a mutable address.
            return Place(address, targetType);
        }

        if (auto call = expression.isCallExp)
            if (call.f !is null && returnsRef(call.f)) {
                auto address = refReturningCallAddress(call, EXP.address);
                // `auto`: a `Place` needs a mutable address.
                return Place(address, targetType);
            }

        if (auto dot = expression.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field is null || dot.e1.type is null)
                throw new Exception("Unsupported eval compound assignment target.");

            if (hasProjectionPlace(dot)) {
                clearsProjectionRoot = true;
                return projectionPlace(dot, /* writeBounds */ true);
            }
            if (dot.e1.type.toBasetype.isTypeClass !is null) {
                auto receiver = ConstructionDestination(Place(
                    _activationFrame.temporaryAddress(dot.e1),
                    dot.e1.type,
                ));
                runExpression(dot.e1, receiver);
                auto bodyAddress = receiver.place.deref.address;
                auto bodyType = dot.e1.type;
                if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = (*metadata).type;
                }
                return Place(bodyAddress, bodyType).field(field);
            }
        }

        throw new Exception("Unsupported eval compound assignment target.");
    }

    private void runPointerCompoundAssignment(
        imported!"dmd.expression".BinExp assignment,
        imported!"quickbite.backends.interpreter.place".Place target,
        imported!"quickbite.backends.interpreter.place".Place* destination,
    ) {
        import dmd.tokens: EXP;

        // DMD's scaleFactor has already converted the element delta to a byte
        // delta by the time this AST reaches the interpreter.
        auto oldAddress = target.deref.address; // Pointer arithmetic needs mutable void*.
        const delta = pointerOffsetOperand(assignment.e2);
        auto newAddress = assignment.op == EXP.addAssign // Stores need mutable void*.
            ? offsetPointerAddress(oldAddress, delta)
            : assignment.op == EXP.minAssign
                ? offsetPointerAddress(oldAddress, -delta)
                : null;
        if (
            assignment.op != EXP.addAssign &&
            assignment.op != EXP.minAssign
        )
            throw new Exception("Unsupported eval compound assignment.");

        target.storeReference(newAddress);
        if (destination !is null) {
            if (destination.type.toBasetype.isTypePointer is null)
                throw new Exception("Unsupported eval compound assignment result.");
            destination.storeReference(newAddress);
        }
    }

    private void runScalarCompoundAssignmentAs(L)(
        imported!"dmd.expression".BinExp assignment,
        imported!"quickbite.backends.interpreter.place".Place target,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            castValue;

        auto operation = Place(
            _activationFrame.temporaryAddress(assignment.e1, assignment.e1.type),
            assignment.e1.type,
        );
        castValue(target, backendCastTarget(operation.type), operation);
        const left = operation.loadNativeScalar!L;
        const right = scalarOperand!L(assignment.e2);
        switch (assignment.op) with (EXP) {
            case addAssign: operation.storeNativeScalar(compoundScalarOperation!"+"(left, right)); break;
            case minAssign: operation.storeNativeScalar(compoundScalarOperation!"-"(left, right)); break;
            case mulAssign: operation.storeNativeScalar(compoundScalarOperation!"*"(left, right)); break;
            case divAssign: operation.storeNativeScalar(compoundScalarOperation!"/"(left, right)); break;
            case modAssign: operation.storeNativeScalar(compoundScalarOperation!"%"(left, right)); break;
            case leftShiftAssign: operation.storeNativeScalar(compoundScalarOperation!"<<"(left, right)); break;
            case rightShiftAssign: operation.storeNativeScalar(compoundScalarOperation!">>"(left, right)); break;
            case unsignedRightShiftAssign: operation.storeNativeScalar(compoundScalarOperation!">>>"(left, right)); break;
            case andAssign: operation.storeNativeScalar(compoundScalarOperation!"&"(left, right)); break;
            case orAssign: operation.storeNativeScalar(compoundScalarOperation!"|"(left, right)); break;
            case xorAssign: operation.storeNativeScalar(compoundScalarOperation!"^"(left, right)); break;
            default: throw new Exception("Unsupported eval compound assignment.");
        }
        castValue(operation, backendCastTarget(target.type), target);
    }

    private L compoundScalarOperation(string operator, L, R)(
        in L left,
        in R right,
    ) {
        static if (__traits(compiles, mixin("left " ~ operator ~ " right"))) {
            static if (operator == "/" || operator == "%") {
                alias OperationResult = typeof(mixin(
                    "left " ~ operator ~ " right",
                ));
                static if (is(OperationResult == int))
                    rejectIntMinMinusOneOverflow(
                        cast(int) left,
                        cast(int) right,
                        operator,
                    );
            }
            return cast(L) mixin("left " ~ operator ~ " right");
        } else {
            throw new Exception("Unsupported eval compound assignment.");
        }
    }

    private void copyScalarCompoundAssignmentResult(
        imported!"quickbite.backends.interpreter.place".Place target,
        imported!"quickbite.backends.interpreter.place".Place* destination,
    ) {
        if (destination is null)
            return;

        import quickbite.backends.interpreter.runtime_casts:
            CastTarget, castValue, tryCastTarget;

        CastTarget castTarget;
        if (!tryCastTarget(destination.type, castTarget))
            throw new Exception("Unsupported eval compound assignment result.");
        castValue(target, castTarget, *destination);
    }

    private void constructDotVarInto(
        imported!"dmd.expression".DotVarExp dot,
        Place destination,
    ) {
        import quickbite.backends.interpreter.class_info_projection:
            isClassInfoNamePointerMember,
            isSyntheticClassInfoMember;
        import quickbite.backends.interpreter.messages: receiverName;
        import std.conv: text;

        if (dot.var.isVarDeclaration !is null && hasProjectionPlace(dot)) {
            copyQualificationConvertedPlaceValue(
                projectionPlace(dot),
                destination,
            );
            return;
        }

        if (isSyntheticClassInfoMember(dot)) {
            constructClassInfoInto(dot, destination);
            return;
        }

        if (declarationName(dot.var) == "name")
            if (auto typeid_ = dot.e1.isTypeidExp) {
                writeCharacterArray(
                    destination,
                    typeInfoName(typeidObjectType(typeid_)),
                );
                return;
            }

        if (declarationName(dot.var) == "name")
            if (auto symbol = dot.e1.isSymOffExp)
                if (auto type = symbolOffsetTypeInfoType(symbol)) {
                    writeCharacterArray(destination, typeInfoName(type));
                    return;
                }

        if (isClassInfoNamePointerMember(dot)) {
            constructClassInfoNameOwnerInto(dot.e1, destination);
            return;
        }

        // `TypeInfo_Const.base`, the field `TypeInfo_Shared` inherits: the
        // TypeInfo the qualified type's own TypeInfo wraps.
        if (declarationName(dot.var) == "base")
            if (auto typeid_ = dot.e1.isTypeidExp)
                if (auto type = typeidObjectType(typeid_)) {
                    auto unqualified = unqualifiedTypeInfoType(type);
                    if (auto address = resolvedClassTypeInfoAddress(unqualified)) {
                        clearStoredMetadata(destination.type, destination.address);
                        destination.storeReference(cast(void*) address);
                    } else {
                        storeTypeInfoName(destination, typeInfoName(unqualified));
                    }
                    return;
                }

        auto receiver = constructedExpressionPlace(dot.e1);
        const memberName = declarationName(dot.var);
        if (auto function_ = loadFunctionPointerId(receiver))
            if (*function_ in _executionState.delegates) {
                constructDelegatePropertyInto(
                    interpretedDelegateSlot(*function_),
                    memberName,
                    destination,
                );
                return;
            }

        if (auto typeInfo = loadTypeInfoName(receiver)) {
            if (memberName == "name") {
                writeCharacterArray(destination, *typeInfo);
                return;
            }

            // `ClassInfo.m_flags`: the class-level facts a collector consults,
            // chief among them whether the object body holds any indirection
            // and so needs scanning.
            if (memberName == "m_flags") {
                storeClassInfoFlags(*typeInfo, destination);
                return;
            }
        }

        // Native dynamic arrays own their length in typed guest storage.
        // `TypeAArray.dotExp` (typesem.d) always lowers `aa.length` to a
        // call to `object._d_aaLen!(K, V)(aa)` at semantic time, so an
        // associative-array receiver never reaches this property lookup.
        import quickbite.frontend.dmd.types: isArrayType;

        if (isArrayType(receiver.type) && memberName == "length") {
            storeLength(destination, receiver.arrayLength);
            return;
        }

        if (auto field = dot.var.isVarDeclaration) {
            if (dot.e1.type.toBasetype.isTypeClass !is null) {
                auto object = classObjectFromReferencePlace(receiver);
                if (object.address is null)
                    throw new Exception(text(
                        "class `",
                        receiverName(dot.e1),
                        "` is `null` and cannot be dereferenced",
                    ));

                if (auto metadata = object.address in nativeExceptionMetadata) {
                    object.address = AggregateValue.nativeClassBodyAddress(*metadata);
                    object.type = (*metadata).type;
                }
                copyQualificationConvertedPlaceValue(
                    Place(object.address, object.type).field(field),
                    destination,
                );
                return;
            }

            copyQualificationConvertedPlaceValue(
                receiver.field(field),
                destination,
            );
            return;
        }

        throw new Exception("Unsupported interpreter field read.");
    }

    private void storeClassInfoFlags(in string className, Place destination) {
        auto class_ = classDeclarationByQualifiedName(className);
        if (class_ is null)
            throw new Exception("Unsupported interpreter TypeInfo flags.");

        destination.storeNativeScalar(classFlagsWord(class_));
    }

    private void typeInfoClassInitializer(
        in string className,
        ConstructionDestination* constructionDestination,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (constructionDestination is null)
            return;
        auto class_ = classDeclarationByQualifiedName(className);
        if (class_ is null)
            throw new Exception("Unsupported interpreter TypeInfo initializer.");

        auto object = AggregateValue.allocateClass(class_.type);
        initializeNativeClassBody(this, class_.type, object);
        auto slice = AggregateValue.classBodyByteSlice(
            object,
            constructionDestination.place.type,
        );
        copyPlaceValue(
            Place(slice.address, slice.type),
            constructionDestination.place,
        );
        constructionDestination.markConstructed;
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

    private void constructClassInfoInto(
        imported!"dmd.expression".DotVarExp classInfo,
        Place destination,
    ) {
        if (classInfo.e1.isTypeExp is null) {
            auto object = classObjectFromReferencePlace(
                constructedExpressionPlace(classInfo.e1),
            );
            if (auto class_ = dynamicClass(object)) {
                storeTypeInfoName(destination, classInfoName(class_));
                return;
            }
        }

        if (auto address = resolvedClassTypeInfoAddress(classInfo.e1.type)) {
            clearStoredMetadata(destination.type, destination.address);
            destination.storeReference(cast(void*) address);
            return;
        }

        storeTypeInfoName(destination, typeInfoName(classInfo.e1.type));
    }

    private void constructClassInfoNameOwnerInto(
        imported!"dmd.expression".Expression ownerExpression,
        Place destination,
    ) {
        auto owner = classInfoNameOwnerExpression(ownerExpression);
        auto object = classObjectFromReferencePlace(
            constructedExpressionPlace(owner),
        );
        if (auto class_ = dynamicClass(object)) {
            writeCharacterArray(destination, classInfoName(class_));
            return;
        }

        // A native class reference is its body pointer. Its static class type
        // still supplies the ClassInfo name needed by this interpreter-only
        // property path; the pointer remains the storage authority.
        if (owner.type.toBasetype.isTypeClass !is null)
            if (auto dynamicType = object.address in nativeClassTypes) {
                writeCharacterArray(destination, typeInfoName(*dynamicType));
                return;
            }

        throw new Exception("Unsupported interpreter field read.");
    }

    private imported!"dmd.expression".Expression classInfoNameOwnerExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto pointer = expression.isPtrExp)
            return classInfoNameOwnerExpression(pointer.e1);

        return expression;
    }

    private void constructDelegatePropertyInto(
        in DelegateSlot slot,
        scope const(char)[] name,
        Place destination,
    ) {
        auto runtime = slot.functionPointerId in _executionState.delegates;
        if (runtime is null)
            throw new Exception("Unsupported interpreter field read.");

        if (name == "ptr") {
            clearStoredMetadata(destination.type, destination.address);
            destination.storeReference(runtime.contextPointer);
            return;
        }

        if (name == "funcptr") {
            storeFunctionPointerId(destination, runtime.functionPointerId);
            return;
        }

        throw new Exception("Unsupported interpreter field read.");
    }

    private void constructTypeidInto(
        imported!"dmd.expression".TypeidExp typeid_,
        Place destination,
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

            constructTypeidValueInto(typeid_, type, typeInfoName(type), destination);
            return;
        }

        auto value = constructedExpressionPlace(expression);
        if (isClassExpression(expression)) {
            auto object = classObjectFromReferencePlace(value);
            if (object.address is null)
                throw new Exception(text(
                    "null pointer dereference evaluating typeid. `",
                    receiverName(expression),
                    "` is `null`",
                ));

            // A dynamic class the interpreter tracks is guest-only by
            // construction, so it has no host symbol to recover; only the
            // static-type fallback below can name a real one.
            if (auto class_ = dynamicClass(object)) {
                constructTypeidValueInto(
                    typeid_,
                    null,
                    classInfoName(class_),
                    destination,
                );
                return;
            }
        }

        constructTypeidValueInto(
            typeid_,
            expression.type,
            typeInfoName(expression.type),
            destination,
        );
    }

    // A real host `TypeInfo_Class` symbol for `resolvedType` takes priority
    // over the symbolic display-name path, exactly as `constructClassInfoInto`
    // resolves `.classinfo`; `resolvedType` is null wherever the caller has
    // already answered from interpreter-tracked dynamic-class identity.
    private void constructTypeidValueInto(
        imported!"dmd.expression".TypeidExp typeid_,
        imported!"dmd.mtype".Type resolvedType,
        in string name,
        Place destination,
    ) {
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        if (isCharacterArrayType(typeid_.type)) {
            writeCharacterArray(destination, name);
            return;
        }

        if (auto address = resolvedClassTypeInfoAddress(resolvedType)) {
            clearStoredMetadata(destination.type, destination.address);
            destination.storeReference(cast(void*) address);
            return;
        }

        storeTypeInfoName(destination, name);
    }

    private Place runAssignExpression(imported!"dmd.expression".BinExp assign) {
        if (auto blit = assign.isBlitExp) {
            import quickbite.frontend.dmd.types: isStructType;

            if (blit.e2.isIntegerExp !is null && isStructType(assign.e1.type)) {
                auto destination = directWriteProjectionPlace(assign.e1);
                defaultValue(assign.e1.type, destination);
                clearProjectionRootUninitialized(assign.e1);
                return destination;
            }
        }

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

                auto address = refReturningCallAddress(call, EXP.address);
                // `auto`: a `Place` needs a mutable address.
                auto destination = Place(address, assign.e1.type);
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
                auto value = assignThroughTypedTemporary(destination, assign.e2);
                clearUninitializedBindingAddress(cast(void*) address);
                return value;
            }
        }

        if (isDirectProjectionWriteTarget(assign.e1))
            return runProjectionAssignExpression(assign.e1, assign.e2);

        if (auto slice = assign.e1.isSliceExp)
            return runSliceAssignExpression(slice, assign.e2);

        // A plain binding (or a representation-preserving cast of one) is a
        // live typed place too. Resolve it before constructing the RHS, then
        // let the projection assignment path construct into fresh temporary
        // storage and copy the complete value into that already-selected
        // place.
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
        // through to ordinary scalar construction, which evaluated the
        // `IntegerExp` as an integer and tried to clobber the parameter's
        // native struct value with a bare int.
        //
        // The identical synthesized zero-init blit precedes a whole-struct
        // -typed FIELD's constructor call too (e.g. `core.internal.lifetime.
        // emplaceRef`'s generated wrapper `this.payload = T(args)`, lowered
        // to a zero-init blit of `this.payload` followed by its `__ctor`
        // call): `assign.e1` is then a `DotVarExp`, not a `VarExp`, so it
        // needs the same default-value materialization rather than writing
        // the raw `0` literal into the field's native struct storage.
        // A binding is also a live typed place. Resolve it the same way:
        // construct the RHS into a fresh temporary, then copy that complete
        // value into the binding's own place.
        if (auto target = assign.e1.isVarExp)
            if (auto variable = target.var.isVarDeclaration)
                if (hasBindingPlace(variable)) {
                    auto destination = bindingPlace(variable);
                    auto value = assignThroughTypedTemporary(destination, assign.e2);
                    clearUninitializedBindingAddress(destination.address);
                    return value;
                }

        // Captured bindings and the remaining computed targets do not expose
        // a direct place yet. Keep their established write path local to this
        // fallback, but return the RHS's typed temporary to the construction
        // dispatch instead of carrying its value across that boundary.
        auto result = constructedExpressionPlace(assign.e2);
        writeLocation(assign.e1, result);
        return result;
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

    private Place runRewrittenAssociativeArrayAssignment(
        imported!"dmd.expression".PtrExp pointer,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.place: Place;

        const address = pointerOperandPlace(pointer.e1).deref.address;
        if (address is null)
            throw new Exception("Associative-array entry has no native address.");

        auto value = assignThroughTypedTemporary(
            Place(cast(void*) address, pointer.type),
            rhs,
        );
        clearUninitializedBindingAddress(cast(void*) address);
        return value;
    }

    private Place runProjectionAssignExpression(
        imported!"dmd.expression".Expression target,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto destination = directWriteProjectionPlace(target);

        // An assignment first evaluates its live place, then completes the
        // RHS in separate fresh storage. Only the complete typed value moves
        // into the live place. DMD has already made any required conversion,
        // postblit, or destructor action explicit around this assignment, so
        // this is the ordinary representation-preserving move itself.
        // The direct target has already composed its live place above.
        // DMD-lowered postblit and chained-method handling stays explicit in
        // `rhs`.
        auto value = assignThroughTypedTemporary(destination, rhs);
        clearProjectionRootUninitialized(target);
        return value;
    }

    private bool hasTypedTemporaryRhs(
        imported!"dmd.expression".Expression rhs,
    ) {
        return rhs !is null && rhs.type !is null;
    }

    // Resolve the assignment's live place before its RHS, then build the RHS
    // in separate fresh typed storage. The typed copy is the only write to
    // the live place, so aliases cannot observe construction. DMD keeps any
    // postblit, destructor, or move lowering in `rhs`; this helper only stores
    // that complete result.
    private Place assignThroughTypedTemporary(
        imported!"quickbite.backends.interpreter.place".Place destination,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.place: Place;

        assert(destination.type !is null && hasTypedTemporaryRhs(rhs));
        auto temporary = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(rhs, destination.type),
            destination.type,
        ));
        runExpression(rhs, temporary);
        copyPlaceValue(temporary.place, destination);
        return destination;
    }

    private void writeLocation(
        imported!"dmd.expression".Expression target,
        Place value,
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
            copyPlaceValue(value, bindingPlace(variable), true);
            clearUninitializedBindingAddress(bindingPlace(variable).address);
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
            if (target.type.toBasetype.isTypeStruct !is null) {
                if (thisAddress !is null) {
                    auto receiver = Place(thisAddress, target.type);
                    copyPlaceValue(value, receiver);
                    thisValue = receiver;
                } else {
                    thisValue = value;
                }
            } else {
                auto body = value.loadReference;
                if (thisAddress !is null)
                    Place(thisAddress, target.type).storeReference(body);
                thisValue = Place(body, target.type);
            }
            return;
        }

        if (target.isSuperExp !is null && hasThis) {
            thisValue = target.type.toBasetype.isTypeStruct !is null
                ? value
                : Place(value.loadReference, target.type);
            return;
        }

        if (auto dot = target.isDotVarExp) {
            if (isDirectProjectionWriteTarget(dot)) {
                copyPlaceValue(value, directWriteProjectionPlace(dot));
                clearProjectionRootUninitialized(dot);
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
                copyPlaceValue(value, projectionPlace(dot));
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

                    auto address = refReturningCallAddress(call, EXP.address);
                    // `auto`: a `Place` needs a mutable address.
                    copyPlaceValue(
                        value,
                        Place(address, dot.e1.type).field(dot.var.isVarDeclaration),
                    );
                    return;
                }

            // The receiver has no live place at this fallback (a plain
            // call/literal result, a captured variable, or a `VarExp`-rooted
            // whole-struct target) -- construct it into an activation
            // temporary rather than a live alias, matching every other
            // caller-owned-storage construction in this walker.
            import quickbite.backends.interpreter.place: Place;

            auto receiverTemporary = ConstructionDestination(Place(
                _activationFrame.temporaryAddress(dot.e1),
                dot.e1.type,
            ));
            runExpression(dot.e1, receiverTemporary);
            auto receiverPlace = receiverTemporary.place;
            if (dot.e1.type.toBasetype.isTypeClass !is null) {
                auto bodyAddress = receiverPlace.loadReference;
                auto bodyType = dot.e1.type;
                if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = (*metadata).type;
                }
                copyPlaceValue(
                    value,
                    Place(bodyAddress, bodyType).field(dot.var.isVarDeclaration),
                );
                return;
            }

            copyPlaceValue(value, receiverPlace.field(dot.var.isVarDeclaration));
            writeLocation(dot.e1, receiverPlace);
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
                copyPlaceValue(value, Place(cast(void*) address, ptr.type));
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
    // evaluate the call once, keep the returned typed address, then write the
    // assigned value through that place.
    private bool writeRefReturningCallLocation(
        imported!"dmd.expression".CallExp call,
        Place value,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;

        if (call.f is null || !returnsRef(call.f))
            return false;

        auto address = refReturningCallAddress(call, EXP.address);
        // `auto`: a `Place` needs a mutable address.
        copyPlaceValue(value, Place(address, call.type));
        return true;
    }

    private void writeArrayLengthLocation(
        imported!"dmd.expression".ArrayLengthExp target,
        Place value,
    ) {
        auto current = constructedExpressionPlace(target.e1);
        const newLength = cast(size_t) value.loadSignedScalar;
        writeLocation(
            target.e1,
            resizedStoredArray(target.e1.type, current, newLength),
        );
    }

    private Place resizedStoredArray(
        imported!"dmd.mtype".Type type,
        Place current,
        in size_t newLength,
    ) {
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: arrayElementType;

        auto sourceAggregate = borrowedAggregate(current);
        const oldLength = current.arrayLength;
        const previousData = current.sliceDataPointer;
        auto resized = AggregateValue.withArrayLength(sourceAggregate, newLength);
        auto elementType = arrayElementType(type);
        auto destination = Place(resized.address, type);
        relocatePriorAppendedElementSlots(
            elementType,
            previousData,
            destination,
            oldLength,
        );
        foreach (index; oldLength .. newLength) {
            auto element = ConstructionDestination(destination.index(index));
            runExpression(elementType.defaultInitLiteral(Loc.initial), element);
        }
        return destination;
    }

    private void writeIndexLocation(
        imported!"dmd.expression".IndexExp index,
        Place value,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isPointerType;

        if (hasProjectionPlace(index)) {
            copyPlaceValue(value, directWriteProjectionPlace(index));
            clearProjectionRootUninitialized(index);
            return;
        }

        const arrayIndex = scalarOperand!size_t(index.e2);
        if (auto call = index.e1.isCallExp) {
            auto address = refReturningCallAddress(call, EXP.address);
            copyPlaceValue(
                value,
                Place(address, index.e1.type).index(arrayIndex),
            );
            return;
        }

        if (isPointerType(index.e1.type)) {
            auto pointer = pointerOperandPlace(index.e1);
            copyPlaceValue(value, pointer.index(arrayIndex));
            return;
        }

        if (auto dereference = index.e1.isPtrExp) {
            auto address = pointerOperandPlace(dereference.e1).loadReference;
            copyPlaceValue(
                value,
                Place(address, index.e1.type).index(arrayIndex),
            );
            return;
        }

        auto base = constructedExpressionPlace(index.e1);
        copyPlaceValue(value, base.index(arrayIndex));
        writeLocation(index.e1, base);
    }

    private Place runIndexAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto destination = selectedIndexPlace(index);
        auto value = assignThroughTypedTemporary(destination, rhs);
        clearProjectionRootUninitialized(index);
        clearUninitializedBindingAddress(destination.address);
        return value;
    }

    // Select an indexed live place before the RHS runs. The recursive arm
    // handles lowered associative-array and nested-array shapes without
    // rebuilding any enclosing aggregate value.
    private Place selectedIndexPlace(
        imported!"dmd.expression".IndexExp index,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isPointerType;

        if (isDirectIndexAssignmentTarget(index))
            return directWriteProjectionPlace(index);

        Place base;
        if (auto call = index.e1.isCallExp) {
            base = Place(refReturningCallAddress(call, EXP.address), index.e1.type);
        } else if (isPointerType(index.e1.type)) {
            base = pointerOperandPlace(index.e1);
        } else if (auto dereference = index.e1.isPtrExp) {
            base = Place(
                pointerOperandPlace(dereference.e1).loadReference,
                index.e1.type,
            );
        } else if (auto outer = index.e1.isIndexExp) {
            base = selectedIndexPlace(outer);
        } else if (hasProjectionPlace(index.e1)) {
            base = projectionPlace(index.e1, true);
        } else if (auto dot = index.e1.isDotVarExp) {
            Place field;
            if (classRootedFieldPlace(dot, field)) {
                base = field;
            } else if (auto call = dot.e1.isCallExp) {
                if (
                    call.f is null ||
                    !returnsRef(call.f) ||
                    dot.e1.type.toBasetype.isTypeStruct is null
                )
                    throw new Exception("Unsupported interpreter assignment target.");
                base = Place(
                    refReturningCallAddress(call, EXP.address),
                    dot.e1.type,
                ).field(dot.var.isVarDeclaration);
            } else {
                base = constructedExpressionPlace(index.e1);
            }
        } else {
            base = constructedExpressionPlace(index.e1);
        }

        if (index.lengthVar !is null)
            setLocal(index.lengthVar, base.arrayLength);
        const arrayIndex = scalarOperand!size_t(index.e2);
        return base.index(arrayIndex);
    }

    private bool classRootedFieldPlace(
        imported!"dmd.expression".Expression expression,
        out Place place,
    ) {
        auto dot = expression.isDotVarExp;
        if (dot is null || dot.var.isVarDeclaration is null)
            return false;

        if (receiverClassType(dot.e1) !is null) {
            auto object = classObjectFromReferencePlace(
                constructedExpressionPlace(dot.e1),
            );
            if (object.address is null)
                throw new Exception("Class field access needs a native address.");
            place = Place(object.address, object.type)
                .field(dot.var.isVarDeclaration);
            return true;
        }

        Place receiver;
        if (!classRootedFieldPlace(dot.e1, receiver))
            return false;
        place = receiver.field(dot.var.isVarDeclaration);
        return true;
    }

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
    private Place runSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: isArrayType, isPointerType;

        const pointer = isPointerType(slice.e1.type);
        auto destination = sliceAssignmentBasePlace(slice.e1);
        if (auto var = slice.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                if (isUninitializedBinding(variable)) {
                    defaultLocalValue(variable);
                    clearUninitializedBindingAddress(bindingPlace(variable).address);
                    destination = bindingPlace(variable);
                }

        const length = pointer ? 0 : destination.arrayLength;
        if (pointer && (slice.lwr is null || slice.upr is null))
            throw new Exception("Pointer slice assignment needs explicit bounds.");

        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? length
            : scalarOperand!size_t(slice.upr);
        if (pointer) {
            import std.conv: text;

            if (lower > upper)
                throwRangeError(text(
                    "slice [", lower, " .. ", upper,
                    "] has a larger lower index than upper index",
                ));
        } else {
            checkSliceAssignmentBounds(lower, upper, length);
        }

        if (auto var = slice.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                rejectOverlappingSliceAssignment(
                    variable,
                    rhs,
                    lower,
                    upper,
                    length,
                );

        auto source = constructedExpressionPlace(rhs);
        const block = isBlockSliceAssignment(slice, rhs);
        const arrayCopy = !block && isArrayType(rhs.type);
        if (arrayCopy && source.arrayLength != upper - lower)
            throwRangeError("Range violation");

        foreach (offset; 0 .. upper - lower)
            copySliceAssignmentElement(
                arrayCopy ? source.index(offset) : source,
                destination.index(lower + offset),
            );

        if (lower == 0)
            recordCopiedClassIdentity(
                pointer
                    ? destination.loadReference
                    : destination.type.toBasetype.isTypeDArray !is null
                        ? destination.sliceDataPointer
                        : null,
                source,
            );
        clearProjectionRootUninitialized(slice.e1);
        clearUninitializedBindingAddress(destination.address);
        return source;
    }

    private Place sliceAssignmentBasePlace(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isPointerType;

        if (isPointerType(expression.type))
            return pointerOperandPlace(expression);
        if (auto dot = expression.isDotVarExp)
            if (isThisRootedProjection(dot.e1) && hasProjectionPlace(dot.e1))
                return projectionPlace(dot, true);
        if (hasProjectionPlace(expression))
            return projectionPlace(expression, true);
        if (auto index = expression.isIndexExp)
            return selectedIndexPlace(index);
        if (auto dot = expression.isDotVarExp) {
            Place field;
            if (classRootedFieldPlace(dot, field))
                return field;
            if (auto call = dot.e1.isCallExp)
                if (
                    call.f !is null &&
                    returnsRef(call.f) &&
                    dot.e1.type.toBasetype.isTypeStruct !is null
                )
                    return Place(
                        refReturningCallAddress(call, EXP.address),
                        dot.e1.type,
                    ).field(dot.var.isVarDeclaration);
        }

        // A cast or other array rvalue holds a native array descriptor whose
        // data pointer still names the storage that the slice assignment
        // updates.
        return constructedExpressionPlace(expression);
    }

    private void copySliceAssignmentElement(Place source, Place destination) {
        import dmd.astenums: TY;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.place: Place;

        if (source.type.toBasetype.ty == TY.Tvoid)
            source = Place(source.address, Type.tuns8);
        if (destination.type.toBasetype.ty == TY.Tvoid)
            destination = Place(destination.address, Type.tuns8);
        copyPlaceValue(source, destination);
    }

    // Copying a class's complete initializer image over storage establishes
    // that class identity at the destination data address.
    private void recordCopiedClassIdentity(void* destination, Place source) {
        if (destination is null || source.type is null)
            return;

        auto type = source.type.toBasetype;
        if (type.isTypeDArray is null && type.isTypeSArray is null)
            return;
        auto image = type.isTypeDArray !is null
            ? source.sliceDataPointer
            : source.address;
        if (auto classType = cast(void*) image in nativeClassTypes)
            nativeClassTypes[destination] = *classType;
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
        if (var is null || var.var.isVarDeclaration !is variable)
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

    private bool isBlockSliceAssignment(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: arrayElementType, isArrayType;

        auto elementType = arrayElementType(slice.type);
        return elementType !is null &&
            isArrayType(elementType) &&
            rhs.type !is null &&
            rhs.type.toBasetype.equals(elementType.toBasetype);
    }
    private Place runLoweredAssignExpression(
        imported!"dmd.expression".LoweredAssignExp assign,
    ) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;
        import std.conv: text;
        import dmd.astenums: TY;

        auto arrayLength = assign.e1.isArrayLengthExp;
        if (arrayLength is null) {
            if (assign.lowering !is null) {
                if (assign.lowering.type.toBasetype.ty == TY.Tvoid) {
                    executeForEffect(assign.lowering);
                    return Place.init;
                }
                return constructedExpressionPlace(assign.lowering);
            }

            throw new Exception(text("Unsupported eval expression: ", assign.op));
        }

        auto lengthValue = constructedExpressionPlace(assign.e2);

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

        auto current = bindingPlace(variable);

        const newLength = cast(size_t) lengthValue.loadSignedScalar;

        // DMD lowers postfix `.length++`/`.length--` through a synthetic
        // `ref` local, so resize via that binding's native place.
        writeLocation(
            var,
            resizedStoredArray(variable.type, current, newLength),
        );
        return lengthValue;
    }

    private void constructConcatenationInto(
        imported!"dmd.expression".CatExp cat,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto left = concatenationOperand(cat.type, cat.e1);
        auto right = concatenationOperand(cat.type, cat.e2);
        AggregateValue.initializeArray(destination, left.count + right.count);
        writeConcatenationOperand(destination, 0, left);
        writeConcatenationOperand(destination, left.count, right);
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
        Place value;
        string encodedCharacters;

        size_t count() @safe {
            return isArray
                ? value.arrayLength
                : encodedCharacters is null ? 1 : encodedCharacters.length;
        }
    }

    private ConcatenationOperand concatenationOperand(
        imported!"dmd.mtype".Type resultType,
        imported!"dmd.expression".Expression operand,
    ) {
        import quickbite.frontend.dmd.types: arrayElementType, isArrayType;

        auto value = constructedExpressionPlace(operand);
        ConcatenationOperand result;
        result.value = value;
        auto elementType = arrayElementType(resultType);
        const contributesOneElement = elementType !is null &&
            operand.type !is null &&
            operand.type.toBasetype.equals(elementType.toBasetype);
        if (contributesOneElement || !isArrayType(operand.type)) {
            result.encodedCharacters = encodedAppendCharacters(resultType, value);
            return result;
        }

        result.isArray = true;
        return result;
    }

    // A wide character appended to `char[]` contributes its UTF-8 code units.
    // `null` means that the operand contributes one ordinary typed value.
    private string encodedAppendCharacters(
        imported!"dmd.mtype".Type arrayType,
        Place value,
    ) {
        import dmd.astenums: TY;
        import std.utf: encode;

        auto array = arrayType.toBasetype.isTypeDArray;
        if (array is null || array.next.toBasetype.ty != TY.Tchar)
            return null;

        char[4] encoded;
        size_t length;
        switch (value.type.toBasetype.ty) with (TY) {
            case Tchar:
                encoded[0] = value.loadNativeScalar!char;
                length = 1;
                break;
            case Twchar:
                length = encode(encoded, cast(dchar) value.loadNativeScalar!wchar);
                break;
            case Tdchar:
                length = encode(encoded, value.loadNativeScalar!dchar);
                break;
            default:
                return null;
        }
        return encoded[0 .. length].idup;
    }

    private void writeConcatenationOperand(
        imported!"quickbite.backends.interpreter.place".Place destination,
        in size_t startIndex,
        ConcatenationOperand operand,
    ) {
        if (!operand.isArray) {
            if (operand.encodedCharacters is null) {
                copyPlaceValue(operand.value, destination.index(startIndex));
            } else {
                foreach (offset, character; operand.encodedCharacters)
                    destination.index(startIndex + offset).storeNativeScalar(character);
            }
            return;
        }

        foreach (index; 0 .. operand.value.arrayLength)
            copyPlaceValue(
                operand.value.index(index),
                destination.index(startIndex + index),
            );
    }

    private Place runArrayAppendAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        // A field or a dereferenced pointer (`*log ~= id`, e.g. a
        // destructor appending through a captured `int[]*` field) both read
        // through their own typed places and write through the generic
        // `writeLocation` -- neither needs the ref-array-parameter or
        // bounds-check handling the `VarExp`/`IndexExp` arms below exist for.
        if (assign.e1.isDotVarExp !is null || assign.e1.isPtrExp !is null) {
            auto appended = appendArrayPlace(
                constructedExpressionPlace(assign.e1),
                assign.e2,
            );
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

        auto appended = appendArrayPlace(bindingPlace(variable), assign.e2);
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return appended;
    }

    private Place appendArrayPlace(
        Place current,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.frontend.dmd.types: arrayElementType;

        auto contribution = concatenationOperand(current.type, rhs);
        const oldLength = current.arrayLength;
        const previousData = current.sliceDataPointer;
        auto resized = AggregateValue.withArrayLength(
            borrowedAggregate(current),
            oldLength + contribution.count,
        );
        auto appended = Place(resized.address, current.type);
        relocatePriorAppendedElementSlots(
            arrayElementType(current.type),
            previousData,
            appended,
            oldLength,
        );
        writeConcatenationOperand(appended, oldLength, contribution);
        return appended;
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
        Place appended,
        in size_t count,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        if (count == 0)
            return;

        const appendedData = appended.sliceDataPointer;
        if (previousData is appendedData)
            return;

        copyStoredMetadataRange(
            cast(void*) previousData,
            cast(void*) appendedData,
            count * typeByteSize(elementType),
        );
    }

    private Place runArrayConcatenateAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (assign.e1.isDotVarExp is null) {
            auto var = assign.e1.isVarExp;
            if (var is null || var.var.isVarDeclaration is null)
                throw new Exception(
                    "Unsupported interpreter array concatenate target.",
                );
        }

        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto owner = AggregateValue.allocateArray(assign.e1.type, 0);
        auto concatenated = Place(owner.address, assign.e1.type);
        constructConcatenationInto(
            cast(imported!"dmd.expression".CatExp) assign,
            concatenated,
        );
        writeLocation(assign.e1, concatenated);
        return concatenated;
    }

    private Place runIndexedArrayAppendAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter array append target.");

        const arrayIndex = scalarOperand!size_t(index.e2);
        auto appended = appendArrayPlace(
            bindingPlace(variable).index(arrayIndex),
            rhs,
        );
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return appended;
    }

    private bool constructCastInto(
        imported!"dmd.expression".CastExp cast_,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import std.algorithm: canFind;
        import std.conv: text;
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: clearPlace;
        import quickbite.backends.interpreter.runtime_casts:
            CastTarget, castValue, tryCastTarget;
        import quickbite.frontend.dmd.types: isArrayType, isPointerType;

        if (cast_.to is null) {
            auto source = constructedExpressionPlace(cast_.e1);
            copyQualificationConvertedPlaceValue(source, destination);
            return true;
        }

        auto targetType = cast_.to.toBasetype;
        if (targetType.ty == TY.Tvoid) {
            executeForEffect(cast_.e1);
            return true;
        }

        CastTarget target;
        CastTarget sourceTarget;
        if (
            cast_.e1.type !is null &&
            tryCastTarget(cast_.to, target) &&
            tryCastTarget(cast_.e1.type, sourceTarget)
        ) {
            auto source = constructedExpressionPlace(cast_.e1);
            castValue(source, target, destination);
            return true;
        }

        if (tryCastTarget(cast_.to, target)) {
            auto source = constructedExpressionPlace(cast_.e1);
            auto sourceType = source.type.toBasetype;
            if (
                sourceType.ty == TY.Tpointer ||
                sourceType.ty == TY.Tclass ||
                sourceType.ty == TY.Taarray
            ) {
                storeAddressAsScalar(source.loadReference, target, destination);
                return true;
            }
            if (sourceType.ty == TY.Tnull) {
                storeAddressAsScalar(null, target, destination);
                return true;
            }
        }

        if (targetType.ty == TY.Tbool) {
            auto source = constructedExpressionPlace(cast_.e1);
            destination.storeNativeScalar(placeIsTruthy(source));
            return true;
        }

        if (targetType.ty == TY.Tdelegate) {
            auto source = constructedExpressionPlace(cast_.e1);
            auto sourceType = source.type.toBasetype;
            if (sourceType.ty == TY.Tdelegate) {
                storeDelegateSlot(destination, loadDelegateSlot(source));
                return true;
            }
            if (
                sourceType.ty == TY.Tpointer &&
                sourceType.nextOf.toBasetype.ty == TY.Tfunction
            ) {
                if (auto id = loadFunctionPointerId(source))
                    storeDelegateSlot(destination, interpretedDelegateSlot(*id));
                else
                    storeDelegateSlot(
                        destination,
                        DelegateSlot(true, null, source.loadReference, 0),
                    );
                return true;
            }
            if (sourceType.ty == TY.Tnull) {
                clearStoredMetadata(destination.type, destination.address);
                clearPlace(destination);
                return true;
            }
            throw new Exception(text("Unsupported eval expression: ", cast_.op));
        }

        if (isPointerType(targetType)) {
            auto source = constructedExpressionPlace(cast_.e1);
            auto sourceType = source.type.toBasetype;
            if (isArrayType(sourceType)) {
                destination.storeReference(
                    sourceType.isTypeDArray !is null
                        ? source.sliceDataPointer
                        : source.address,
                );
                return true;
            }
            if (
                sourceType.ty == TY.Tpointer ||
                sourceType.ty == TY.Tclass ||
                sourceType.ty == TY.Taarray
            ) {
                if (
                    sourceType.ty == TY.Tpointer &&
                    sourceType.nextOf.toBasetype.ty == TY.Tfunction
                ) {
                    if (auto id = loadFunctionPointerId(source)) {
                        storeFunctionPointerId(destination, *id);
                        return true;
                    }
                }
                destination.storeReference(source.loadReference);
                return true;
            }
            if (sourceType.ty == TY.Tnull) {
                destination.storeReference(null);
                return true;
            }
            throw new Exception(text("Unsupported eval expression: ", cast_.op));
        }

        if (targetType.ty == TY.Tarray) {
            auto source = constructedExpressionPlace(cast_.e1);
            auto sourceType = source.type.toBasetype;
            void* address;
            size_t length;
            if (isArrayType(sourceType)) {
                address = sourceType.isTypeDArray !is null
                    ? source.sliceDataPointer
                    : source.address;
                length = source.arrayLength;
                if (targetType.nextOf.toBasetype.ty == TY.Tvoid)
                    length *= typeByteSize(sourceType.nextOf);
            } else if (sourceType.isTypeStruct !is null) {
                address = source.address;
                length = typeByteSize(source.type);
            } else {
                return false;
            }
            AggregateValue.initializeBorrowedArray(destination, length, address);
            return true;
        }

        if (
            targetType.ty == TY.Tclass ||
            targetType.ty == TY.Tident && typeChars(cast_.to).canFind("Throwable")
        ) {
            auto source = constructedExpressionPlace(cast_.e1);
            if (auto name = loadTypeInfoName(source)) {
                auto classType = targetType.isTypeClass;
                if (
                    classType !is null &&
                    isClassTypeInfoClass(classType.sym) &&
                    classDeclarationByQualifiedName(*name) !is null
                ) {
                    storeTypeInfoName(destination, *name);
                    return true;
                }
            }

            auto sourceType = source.type.toBasetype;
            if (
                sourceType.ty != TY.Tpointer &&
                sourceType.ty != TY.Tclass &&
                sourceType.ty != TY.Tnull
            )
                return false;

            auto address = sourceType.ty == TY.Tnull
                ? null
                : source.loadReference;
            if (address is null) {
                destination.storeReference(null);
                return true;
            }

            auto classType = targetType.isTypeClass;
            if (sourceType.ty == TY.Tpointer) {
                if (
                    classType !is null &&
                    classType.sym.isInterfaceDeclaration is null &&
                    address !in nativeClassTypes
                )
                    nativeClassTypes[address] = classType;
                destination.storeReference(address);
                return true;
            }

            auto object = classObjectFromReferencePlace(source);
            const wanted = classType is null
                ? "Throwable"
                : className(classType.sym);
            destination.storeReference(
                classHasType(object, wanted) ? address : null,
            );
            return true;
        }

        if (auto integer = cast_.e1.isIntegerExp)
            if (integer.type !is null && integer.type.ty == TY.Tenum) {
                import quickbite.backends.interpreter.runtime_values: integerValue;

                integerValue(integer, destination);
                return true;
            }

        return false;
    }

    private void storeAddressAsScalar(
        void* address,
        in imported!"quickbite.backends.interpreter.runtime_casts".CastTarget target,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.runtime_casts: CastTarget;

        const value = cast(size_t) address;
        final switch (target) with (CastTarget) {
            case bool_: destination.storeNativeScalar(address !is null); return;
            case byte_: destination.storeNativeScalar(cast(byte) value); return;
            case ubyte_: destination.storeNativeScalar(cast(ubyte) value); return;
            case char_: destination.storeNativeScalar(cast(char) value); return;
            case short_: destination.storeNativeScalar(cast(short) value); return;
            case ushort_: destination.storeNativeScalar(cast(ushort) value); return;
            case wchar_: destination.storeNativeScalar(cast(wchar) value); return;
            case int_: destination.storeNativeScalar(cast(int) value); return;
            case uint_: destination.storeNativeScalar(cast(uint) value); return;
            case dchar_: destination.storeNativeScalar(cast(dchar) value); return;
            case long_: destination.storeNativeScalar(cast(long) value); return;
            case ulong_: destination.storeNativeScalar(cast(ulong) value); return;
            case float_: destination.storeNativeScalar(cast(float) value); return;
            case double_: destination.storeNativeScalar(cast(double) value); return;
            case real_: destination.storeNativeScalar(cast(real) value); return;
            case ifloat_: destination.storeNativeScalar(cast(ifloat) value); return;
            case idouble_: destination.storeNativeScalar(cast(idouble) value); return;
            case ireal_: destination.storeNativeScalar(cast(ireal) value); return;
            case cfloat_: destination.storeNativeScalar(cast(cfloat) value); return;
            case cdouble_: destination.storeNativeScalar(cast(cdouble) value); return;
            case creal_: destination.storeNativeScalar(cast(creal) value); return;
        }
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
    // Their identity lives out of band, keyed by the field's own address.
    // Field construction writes the typed place and registers that identity,
    // exactly as direct field assignment does.
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
    // expression. Construct that expression directly in the field place.
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

        runExpression(expression, destination);
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
        Place receiver,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;

        auto structType = receiver.type.toBasetype.isTypeStruct;
        if (structType is null || structType.sym is null)
            return null;

        auto contextField = structType.sym.vthis;
        if (contextField is null)
            return null;

        auto frames = receiver.field(contextField)
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
            auto thisFieldAddress = addressOfExpression(receiver, EXP.address);
            // `auto`: `NativeOperand` takes a mutable address.
            return NativeOperand(receiver.type, thisFieldAddress);
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

        auto address = addressOfExpression(receiver, EXP.address);
        // `auto`: `NativeOperand` takes a mutable address.
        return NativeOperand(receiver.type, address);
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

    private void storeCallResult(
        ConstructionDestination* destination,
        Place source,
    ) {
        if (destination is null)
            return;
        copyQualificationConvertedPlaceValue(source, destination.place);
        destination.markConstructed;
    }

    private void storeReceiverCallResult(
        ConstructionDestination* destination,
        Place receiver,
    ) {
        if (receiver.type.toBasetype.isTypeClass !is null)
            storeReferenceCallResult(destination, receiver.address);
        else
            storeCallResult(destination, receiver);
    }

    private void storeReferenceCallResult(
        ConstructionDestination* destination,
        void* address,
    ) {
        if (destination is null)
            return;
        clearStoredMetadata(destination.place.type, destination.place.address);
        destination.place.storeReference(address);
        destination.markConstructed;
    }

    private void storeNativeCallResult(
        ConstructionDestination* destination,
        imported!"quickbite.backends.interpreter.native_call_adapter".
            NativeOperand operand,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.place: Place;

        if (
            destination is null ||
            operand.address is null ||
            operand.type is null ||
            operand.type.toBasetype.ty == TY.Tvoid
        )
            return;

        if (operand.address == destination.place.address) {
            destination.markConstructed;
            return;
        }

        if (operand.type.toBasetype.ty == TY.Tdelegate) {
            const metadata = operand.delegateMetadata;
            if (metadata.isNull)
                clearPlaceValue(destination.place);
            else
                storeDelegateSlot(
                    destination.place,
                    DelegateSlot(
                        true,
                        metadata.context,
                        metadata.funcptr,
                        0,
                    ),
                );
        } else
            copyQualificationConvertedPlaceValue(
                Place(operand.address, operand.type),
                destination.place,
            );
        destination.markConstructed;
    }

    private bool invokeNativeDeclaration(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"quickbite.backends.interpreter.place".Place receiver,
        imported!"dmd.mtype".Type receiverType,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
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

        auto nativeArguments = NativeCallArguments(
            argumentExpressions,
            &_executionState.nativeCallArgumentStorage,
        );
        scope(exit) nativeArguments.release;
        if (durableInboundSession is null)
            durableInboundSession = new InterpreterInboundTrampolineSession(
                _executionState.invokeNativeCallback,
            );
        auto receiverOperand = receiverExpression is null
            ? receiver.address is null
                ? NativeOperand.init
                : NativeOperand(receiverType, receiver.address)
            : nativeReceiverOperand(receiverExpression, receiverAddress);
        fillNativeCallOperands(
            function_,
            argumentPlaces,
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

    // A direct AST symbol used as a function pointer resolves its native
    // address from the declaration, but its call-site function type controls
    // the ABI. Unlike a delegate call, this path has no hidden context
    // receiver. Delegate arguments still use the root-owned inbound session.
    private bool invokeNativeFunctionPointer(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.mtype".TypeFunction callSignature,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments,
        out imported!"quickbite.backends.interpreter.native_call_adapter".
            NativeCallResult result,
        void* resultAddress = null,
    ) {
        import quickbite.backends.interpreter.native_call_adapter:
            InterpreterInboundTrampolineSession, NativeCallRequest,
            invokeNative;

        if (callSignature is null)
            return false;

        auto nativeArguments = NativeCallArguments(
            argumentExpressions,
            &_executionState.nativeCallArgumentStorage,
        );
        scope(exit) nativeArguments.release;
        if (durableInboundSession is null)
            durableInboundSession = new InterpreterInboundTrampolineSession(
                _executionState.invokeNativeCallback,
            );
        fillNativeCallOperands(
            function_,
            argumentPlaces,
            argumentExpressions,
            nativeArguments.types,
            evaluatedArguments,
            nativeArguments.operands,
            durableInboundSession,
        );
        auto request = NativeCallRequest(
            declaration: function_,
            functionPointerSignature: callSignature,
            resultAddress: resultAddress,
            argumentTypes: nativeArguments.types,
            argumentOperands: nativeArguments.operands,
            callbackSession: durableInboundSession,
        );
        return invokeNative(request, result);
    }

    // Every evaluated argument crosses as its typed address. The only scratch
    // operand is the host TypeInfo pointer that a TypeidExp denotes.
    private void fillNativeCallOperands(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"quickbite.backends.interpreter.place".Place[] argumentPlaces,
        imported!"dmd.expression".Expression[] argumentExpressions,
        imported!"dmd.mtype".Type[] argumentTypes,
        in EvaluatedReferenceArgument[] evaluatedArguments,
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeOperand[] operands,
        imported!"quickbite.backends.interpreter.native_call_adapter".
            InterpreterInboundTrampolineSession* callbackSession,
    ) {
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.native_call_adapter:
            InterpretedDelegate, NativeOperand;
        import quickbite.backends.interpreter.place: Place;
        import dmd.astenums: TY;

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
                index >= argumentTypes.length ||
                expression.type is null ||
                !expression.type.toBasetype.equals(
                    argumentTypes[index].toBasetype,
                )
            )
                continue;

            if (
                argumentTypes[index].toBasetype.ty == TY.Tdelegate &&
                argumentPlaces[index].address !is null
            ) {
                auto slot = cast(const(void)*) argumentPlaces[index].address
                    in nativeDelegateSlots;
                if (slot !is null && !slot.isNative) {
                    operands[index] = NativeOperand(
                        argumentTypes[index],
                        null,
                        NativeBlock.init,
                        callbackSession,
                        callbackSession.register(InterpretedDelegate(
                            slot.functionPointerId,
                        )),
                    );
                    continue;
                }
            }

            if (argumentPlaces[index].address is null)
                continue;
            operands[index] = NativeOperand(
                nativeReferenceParameter(function_, index)
                    ? nativeParameterType(function_, index)
                    : argumentTypes[index],
                argumentPlaces[index].address,
            );
        }
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
    // pointer, reference, or slice header into the caller's fresh place. The
    // native-constructor residue adapts its FFI result at the destination
    // boundary because that result is not address-only yet.
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
            nativeClassOwners[body] = object;
            initializeNativeClassBody(this, type, object);
            destination.storeReference(body);
            if (new_.member is null)
                return true;

            auto arguments = CallArguments(
                new_.arguments is null ? 0 : new_.arguments.length,
                &_executionState.callArgumentStorage,
            );
            scope(exit) arguments.release;
            auto argumentPlaces = arguments.places;
            if (new_.arguments !is null)
                foreach (index, argument; *new_.arguments) {
                    auto argumentDestination = ConstructionDestination(Place(
                        _activationFrame.temporaryAddress(argument),
                        argument.type,
                    ));
                    runExpression(argument, argumentDestination);
                    argumentPlaces[index] = argumentDestination.place;
                }

            if (isThrowableConstructor(new_.member)) {
                applyThrowableConstructor(Place(body, type), argumentPlaces);
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
                argumentPlaces,
                null,
                FrameBlock.init,
                null,
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

                if (hasNoAvailableSource(new_.member)) {
                    runExpression(type.defaultInitLiteral(Loc.initial), allocated);
                    constructNewStructNativeConstructor(
                        new_,
                        allocated.place,
                        block,
                        destination,
                    );
                    return true;
                }

                import dmd.funcsem: functionSemantic3;
                if (!functionSemantic3(new_.member))
                    throw new Exception(text("Unsupported eval expression: ", new_.op));

                runExpression(type.defaultInitLiteral(Loc.initial), allocated);
                auto arguments = CallArguments(
                    new_.arguments is null ? 0 : new_.arguments.length,
                    &_executionState.callArgumentStorage,
                );
                scope(exit) arguments.release;
                auto argumentPlaces = arguments.places;
                if (new_.arguments !is null)
                    foreach (index, argument; *new_.arguments) {
                        auto argumentDestination = ConstructionDestination(Place(
                            _activationFrame.temporaryAddress(argument),
                            argument.type,
                        ));
                        runExpression(argument, argumentDestination);
                        argumentPlaces[index] = argumentDestination.place;
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
                    argumentPlaces,
                    null,
                    FrameBlock.init,
                    null,
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

    private void constructNewStructNativeConstructor(
        imported!"dmd.expression".NewExp new_,
        Place receiver,
        NativeBlock owner,
        Place destination,
    ) {
        import quickbite.backends.interpreter.native_call_adapter:
            NativeCallException, NativeCallResult;
        import quickbite.frontend.dmd.functions: noAvailableSourceMessage;

        auto arguments = CallArguments(
            new_.arguments is null ? 0 : new_.arguments.length,
            &_executionState.callArgumentStorage,
        );
        scope(exit) arguments.release;
        if (new_.arguments !is null)
            foreach (index, argument; *new_.arguments) {
                auto argumentDestination = ConstructionDestination(Place(
                    _activationFrame.temporaryAddress(argument),
                    argument.type,
                ));
                runExpression(argument, argumentDestination);
                arguments.places[index] = argumentDestination.place;
                arguments.expressions[index] = argument;
            }

        try {
            NativeCallResult result;
            if (invokeNativeDeclaration(
                new_.member,
                nativeConstructorReceiverPlace(new_.member, receiver),
                receiver.type.toBasetype.isTypeStruct,
                null,
                arguments.places,
                arguments.expressions,
                null,
                true,
                result,
                receiver.address,
                receiver.address,
            )) {
                if (result.value.address != receiver.address)
                    copyPlaceValue(
                        Place(result.value.address, receiver.type),
                        receiver,
                    );
                destination.storeReference(receiver.address);
                retainTemporaryPointerOwner(owner);
                return;
            }
        } catch (NativeCallException exception) {
            throwNativeException(exception);
        }

        throw new Exception(noAvailableSourceMessage(new_.member));
    }

    private void mergeNewClassExpressionState(ref Walker child) {
        mergeLazyArgumentMapsFrom(child);
    }

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
                defaultLocalValue(variable);
                return;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                defaultLocalValue(variable);
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
        // mirroring the element-postblit call in the native array-constructor
        // path above.
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
                        Place[] noArguments;
                        imported!"dmd.expression".Expression[] noExpressions;
                        if (!invokeNativeDeclaration(
                            postblitCall.f,
                            place,
                            place.type,
                            receiverBlit.e1,
                            noArguments,
                            noExpressions,
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
                            copyQualificationConvertedPlaceValue(
                                Place(
                                    nativeResult.value.address,
                                    nativeResult.value.type,
                                ),
                                place,
                            );
                    } catch (NativeCallException exception) {
                        throwNativeException(exception);
                    }
                    return;
                }

                Place[] noArguments;
                imported!"dmd.expression".Expression[] noExpressions;
                runMemberFunction(
                    postblitCall.f,
                    null,
                    place,
                    noArguments,
                    noExpressions,
                );
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
        // (the same byte copy used for a same-typed static-array source),
        // then run the element postblit on
        // each copied element. A struct with only a copy constructor or
        // only a destructor (no postblit) also lowers this way; that shape
        // is left to the generic call path below, unchanged.
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

                    auto source = constructedExpressionPlace(sourceArray);
                    copyPlaceValue(source, bindingPlace(variable));

                    const count =
                        staticArrayLength(variable.type.toBasetype.isTypeSArray);
                    foreach (i; 0 .. count) {
                        auto elementPlace = bindingPlace(variable).index(i);
                        Place[] noArguments;
                        imported!"dmd.expression".Expression[] noExpressions;
                        runMemberFunction(
                            postblit,
                            null,
                            elementPlace,
                            noArguments,
                            noExpressions,
                        );
                    }

                    return;
                }
            }

        if (isRefVariable(variable)) {
            import dmd.tokens: EXP;

            auto pointer = addressOfExpression(initializer, EXP.address);
            // `auto`: the frame reference slot stores a mutable address.
            _activationFrame.setReferenceSlot(variable, pointer);
            clearUninitializedBindingAddress(pointer);
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
    // and nothing is copied afterwards. Answers `false` only when the
    // expression has no supported destination arm.
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
        import dmd.astenums: TY;

        if (!destination.isFresh)
            throw new Exception(
                "quickbite.backends.interpreter.impl.Walker.constructInto: "
                ~ "destination is not fresh",
            );

        auto place = destination.place;

        if (auto assert_ = rvalue.isAssertExp) {
            executeAssertExpression(assert_);
            destination.markConstructed;
            return true;
        }

        if (auto throw_ = rvalue.isThrowExp) {
            executeThrowExpression(throw_);
            destination.markConstructed;
            return true;
        }

        if (auto logical = rvalue.isLogicalExp)
            if (logical.type.toBasetype.ty == TY.Tvoid) {
                executeVoidLogicalExpression(logical);
                destination.markConstructed;
                return true;
            }

        if (auto tuple = rvalue.isTupleExp) {
            constructTupleInto(tuple, destination);
            return true;
        }

        if (rvalue.isThisExp !is null || rvalue.isSuperExp !is null) {
            constructReceiverExpressionInto(rvalue, place);
            destination.markConstructed;
            return true;
        }

        if (auto identifier = rvalue.isIdentifierExp)
            if (constructDefensiveIdentifierInto(identifier, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto delegatePointer = rvalue.isDelegatePtrExp) {
            constructDelegatePointerInto(delegatePointer, place);
            destination.markConstructed;
            return true;
        }

        if (auto delegateFunctionPointer = rvalue.isDelegateFuncptrExp) {
            constructDelegateFunctionPointerInto(delegateFunctionPointer, place);
            destination.markConstructed;
            return true;
        }

        if (auto dot = rvalue.isDotIdExp)
            if (constructComplexComponentInto(dot, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto vector = rvalue.isVectorExp)
            if (constructVectorInto(vector, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto vectorArray = rvalue.isVectorArrayExp)
            if (constructVectorArrayInto(vectorArray, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto comparison = relationalComparisonOrNull(rvalue))
            if (constructPointerComparisonInto(comparison, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto post = rvalue.isPostExp)
            if (runPostExpression(post, &place)) {
                destination.markConstructed;
                return true;
            }

        if (auto assign = scalarCompoundAssignment(rvalue)) {
            runScalarCompoundAssignment(assign, &place);
            destination.markConstructed;
            return true;
        }

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
            // an unsupported source reaches the later destination adapter,
            // which reinterprets pointer and class references as scalars.
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

        if (
            rvalue.type !is null &&
            place.type.toBasetype.equals(rvalue.type.toBasetype)
        )
            if (auto variable = rvalue.isVarExp) {
                constructVariableInto(variable, place);
                destination.markConstructed;
                return true;
            }

        if (auto call = rvalue.isCallExp) {
            import dmd.astenums: TY;

            if (call.type.toBasetype.ty == TY.Tvoid) {
                runCallExpression(call, null);
                destination.markConstructed;
                return true;
            }

            runCallExpression(call, &destination);
            if (!destination.isConstructed)
                throw new Exception("Call did not construct its result.");
            return true;
        }

        if (auto literal = rvalue.isFuncExp) {
            constructFunctionLiteralInto(literal, place);
            destination.markConstructed;
            return true;
        }

        // A delegate literal and a bare `&function` mint interpreter-only
        // callable identity with no native ABI address of their own.
        // Construct straight into the destination's address-keyed callable
        // slot. Interpreted callables have no native ABI address of their own.
        if (auto delegate_ = rvalue.isDelegateExp) {
            storeDelegateSlot(place, runDelegateExpression(delegate_));
            destination.markConstructed;
            return true;
        }

        if (auto symbol = rvalue.isSymOffExp)
            if (auto function_ = symbol.var.isFuncDeclaration) {
                storeFunctionPointerId(place, functionPointerId(function_));
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
        if (constructScalarExpressionInto(rvalue, place)) {
            destination.markConstructed;
            return true;
        }

        // A declaration destination can add qualification or otherwise
        // require a representation conversion. Construct first at the
        // expression's own static type, then adapt that complete value to the
        // caller's place. The exact-type recursive call cannot return here.
        if (constructAtExpressionType(rvalue, destination))
            return true;

        if (auto symbol = rvalue.isSymOffExp) {
            if (auto pointerType = variableSymbolOffsetPointerType(symbol)) {
                import quickbite.backends.interpreter.place: Place;

                auto pointerDestination = Place(
                    _activationFrame.temporaryAddress(rvalue, pointerType),
                    pointerType,
                );
                if (!constructPointerExpressionInto(rvalue, pointerDestination))
                    throw new Exception("Variable symbol offset did not construct.");
                if (
                    place.type.toBasetype.isTypePointer is null &&
                    place.type.toBasetype.isTypeClass is null
                )
                    throw new Exception(
                        "Variable symbol offset has no reference destination.",
                    );
                clearStoredMetadata(place.type, place.address);
                place.storeReference(pointerDestination.loadReference);
                destination.markConstructed;
                return true;
            }
        }

        if (auto null_ = rvalue.isNullExp) {
            import dmd.astenums: TY;
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;

            if (place.type.toBasetype.ty == TY.Tarray) {
                AggregateValue.initializeArray(place, 0);
                destination.markConstructed;
                return true;
            }
            clearPlaceValue(place);
            destination.markConstructed;
            return true;
        }

        if (auto array = rvalue.isArrayLiteralExp)
            if (constructAtExpressionType(array, destination))
                return true;

        if (auto struct_ = rvalue.isStructLiteralExp)
            if (constructAtExpressionType(struct_, destination))
                return true;

        if (auto assocArray = rvalue.isAssocArrayLiteralExp) {
            if (assocArray.lowering is null)
                throwUnsupportedExpression(rvalue);
            runExpression(assocArray.lowering, destination);
            return true;
        }

        if (auto cast_ = rvalue.isCastExp)
            if (constructCastInto(cast_, place)) {
                destination.markConstructed;
                return true;
            }

        if (auto equal = rvalue.isEqualExp) {
            import dmd.tokens: EXP;

            const same = equalOperands(equal);
            place.storeNativeScalar(
                equal.op == EXP.notEqual ? !same : same,
            );
            destination.markConstructed;
            return true;
        }

        if (auto cat = rvalue.isCatExp) {
            constructConcatenationInto(cat, place);
            destination.markConstructed;
            return true;
        }

        if (auto assign = rvalue.isAssignExp)
            return constructAssignmentInto(assign, destination);

        if (auto lowered = rvalue.isLoweredAssignExp)
            return storeConstructionResult(destination, runLoweredAssignExpression(lowered));

        if (auto construct = rvalue.isConstructExp)
            return constructAssignmentInto(construct, destination);

        if (auto blit = rvalue.isBlitExp)
            return constructAssignmentInto(blit, destination);

        import dmd.tokens: EXP;
        if (rvalue.op == EXP.concatenateAssign)
            return storeConstructionResult(destination, runArrayConcatenateAssignExpression(
                cast(imported!"dmd.expression".BinExp) rvalue,
            ));
        if (
            rvalue.op == EXP.concatenateElemAssign ||
            rvalue.op == EXP.concatenateDcharAssign
        )
            return storeConstructionResult(destination, runArrayAppendAssignExpression(
                cast(imported!"dmd.expression".BinExp) rvalue,
            ));

        if (auto comma = rvalue.isCommaExp) {
            executeForEffectImpl(comma.e1);
            if (comma.type.toBasetype.ty == TY.Tvoid) {
                executeForEffectImpl(comma.e2);
                destination.markConstructed;
            } else {
                runExpression(comma.e2, destination);
            }
            return true;
        }

        if (auto declaration = rvalue.isDeclarationExp) {
            executeDeclaration(declaration);
            destination.markConstructed;
            return true;
        }

        if (auto arrayLength = rvalue.isArrayLengthExp) {
            place.storeNativeScalar(constructedExpressionPlace(arrayLength.e1).arrayLength);
            destination.markConstructed;
            return true;
        }

        if (auto dot = rvalue.isDotVarExp) {
            constructDotVarInto(dot, place);
            destination.markConstructed;
            return true;
        }

        if (auto typeid_ = rvalue.isTypeidExp) {
            constructTypeidInto(typeid_, place);
            destination.markConstructed;
            return true;
        }

        return false;
    }

    private bool storeConstructionResult(
        ref ConstructionDestination destination,
        Place source,
    ) {
        if (source.type is null) {
            import dmd.astenums: TY;

            assert(destination.place.type.toBasetype.ty == TY.Tvoid);
            destination.markConstructed;
            return true;
        }

        copyPlaceValue(source, destination.place);
        destination.markConstructed;
        return true;
    }

    private bool constructAtExpressionType(
        Expression expression,
        ref ConstructionDestination destination,
    ) {
        import dmd.astenums: TY;

        if (
            expression.type is null ||
            expression.type.toBasetype.ty == TY.Tfunction ||
            destination.place.type.toBasetype.equals(expression.type.toBasetype)
        )
            return false;

        if (destination.place.type.toBasetype.ty == TY.Tsarray) {
            constructStructLiteralField(expression, destination);
            return true;
        }

        auto source = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression, expression.type),
            expression.type,
        ));
        runExpression(expression, source);
        if (
            destination.place.type.toBasetype.ty == TY.Taarray &&
            source.place.type.toBasetype.ty == TY.Tpointer
        ) {
            destination.place.storeReference(source.place.loadReference);
            destination.markConstructed;
            return true;
        }
        if (
            isVoidSliceType(destination.place.type) &&
            (
                source.place.type.toBasetype.ty == TY.Tstruct ||
                source.place.type.toBasetype.ty == TY.Tsarray
            )
        ) {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
            import quickbite.backends.interpreter.layout: typeByteSize;

            AggregateValue.initializeBorrowedArray(
                destination.place,
                typeByteSize(source.place.type),
                source.place.address,
            );
            destination.markConstructed;
            return true;
        }
        return storeConstructionResult(destination, source.place);
    }

    private bool constructAssignmentInto(
        imported!"dmd.expression".BinExp assignment,
        ref ConstructionDestination destination,
    ) {
        return storeConstructionResult(destination, runAssignExpression(assignment));
    }

    private void constructTupleInto(
        TupleExp tuple,
        ref ConstructionDestination destination,
    ) {
        if (tuple.e0 !is null)
            executeForEffect(tuple.e0);

        if (tuple.exps is null || (*tuple.exps).length == 0) {
            destination.markConstructed;
            return;
        }

        foreach (element; (*tuple.exps)[0 .. $ - 1])
            executeForEffect(element);
        runExpression((*tuple.exps)[$ - 1], destination);
    }

    private void constructReceiverExpressionInto(
        Expression expression,
        Place destination,
    ) {
        requireReceiverExpression(expression);
        if (expression.type.toBasetype.isTypeClass !is null) {
            destination.storeReference(thisValue.address);
            return;
        }
        copyPlaceValue(thisValue, destination);
    }

    private void constructDelegatePointerInto(
        DelegatePtrExp expression,
        Place destination,
    ) {
        // `const` would qualify the stored context pointer and prevent this
        // typed pointer place from accepting it.
        auto runtime = requireInterpretedDelegate(expression.e1);
        clearStoredMetadata(destination.type, destination.address);
        destination.storeReference(runtime.contextPointer);
    }

    private void constructDelegateFunctionPointerInto(
        DelegateFuncptrExp expression,
        Place destination,
    ) {
        const runtime = requireInterpretedDelegate(expression.e1);
        clearStoredMetadata(destination.type, destination.address);
        nativeFunctionPointerSlots[destination.address] =
            runtime.functionPointerId;
        destination.storeReference(null);
    }

    private RuntimeDelegate* requireInterpretedDelegate(Expression expression) {
        const slot = constructedDelegateSlot(expression);
        if (slot.isNative)
            throw new Exception("Unsupported interpreter field read.");

        auto runtime = slot.functionPointerId in _executionState.delegates;
        if (runtime is null)
            throw new Exception("Unsupported interpreter field read.");
        return runtime;
    }

    private DelegateSlot constructedDelegateSlot(Expression expression) {
        import quickbite.backends.interpreter.native_call_adapter:
            NativeOperand, nativeDelegateMetadata;

        auto destination = ConstructionDestination(Place(
            _activationFrame.temporaryAddress(expression),
            expression.type,
        ));
        runExpression(expression, destination);

        if (auto slot = destination.place.address in nativeDelegateSlots)
            return *slot;

        const native = nativeDelegateMetadata(NativeOperand(
            destination.place.type,
            destination.place.address,
        ));
        if (native.isNull)
            throw new Exception("Expected function pointer.");
        return DelegateSlot(true, native.context, native.funcptr, 0);
    }

    private void requireReceiverExpression(Expression expression) {
        if (hasThis)
            return;
        throw new Exception(expression.isThisExp !is null
            ? "Unsupported eval expression: this"
            : "Unsupported eval expression: super");
    }

    private bool constructDefensiveIdentifierInto(
        IdentifierExp identifier,
        Place destination,
    ) {
        const name = identifierName(identifier);
        if (name == "__ctfe") {
            destination.storeNativeScalar(false);
            return true;
        }

        auto field = defensiveIdentifierField(name);
        if (field is null)
            return false;
        copyPlaceValue(thisValue.field(field), destination);
        return true;
    }

    private bool isDefensiveIdentifierExpression(IdentifierExp identifier) {
        const name = identifierName(identifier);
        return name == "__ctfe" || defensiveIdentifierField(name) !is null;
    }

    private string identifierName(IdentifierExp identifier) {
        return identifier.ident is null ? "" : identifier.ident.toString.idup;
    }

    private VarDeclaration defensiveIdentifierField(in string name) {
        // DMD's own `IdentifierExp` semantic (`expressionsem.d`) always
        // resolves `__ctfe` into a `VarExp` before a fully-semantic'd module
        // reaches this walker. The same is normally true for unqualified
        // fields. Keep these defensive paths in native places in case a
        // partially semantic imported body still exposes either shape.
        if (
            !hasThis ||
            thisValue.type is null ||
            thisValue.type.toBasetype.isTypeClass is null ||
            currentFunction is null
        )
            return null;

        auto thisParameter = currentFunction.vthis;
        auto classType = thisParameter is null
            ? null
            : thisParameter.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return null;

        import quickbite.backends.interpreter.layout: classFields, fieldName;

        foreach (field; classFields(classType.sym))
            if (fieldName(field) == name)
                return field;
        return null;
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
            runExpression(source, elementDestination);
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

    // An index composes or constructs its receiver once, evaluates its index
    // once, and copies the selected typed bytes into caller-owned storage.
    private bool constructIndexInto(
        imported!"dmd.expression".IndexExp index,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        if (index.type is null ||
            !destination.type.toBasetype.equals(index.type.toBasetype))
            return false;

        const pointer = isPointerType(index.e1.type);
        auto source = pointer
            ? pointerOperandPlace(index.e1)
            : hasArrayProjectionPlace(index.e1)
                ? projectionPlace(index.e1)
                : constructedExpressionPlace(index.e1);
        const length = pointer ? 0 : source.arrayLength;
        if (!pointer && index.lengthVar !is null)
            setLocal(index.lengthVar, length);

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
        if (expression.type is null || destination.type is null)
            return false;

        // An identity result is always `bool`. A destination can add a
        // qualifier while retaining that representation, such as the
        // inferred `const` local initialized from `&this is null`.
        if (
            expression.isIdentityExp !is null &&
            expression.type.toBasetype.ty == TY.Tbool &&
            destination.type.toBasetype.ty == TY.Tbool
        )
            return constructScalar!bool(expression, destination);

        if (
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
    // that address in its typed place throughout recursive construction.
    private bool constructPointerExpressionInto(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.types: isPointerType;

        if (auto symbol = expression.isSymOffExp) {
            auto pointerType = variableSymbolOffsetPointerType(symbol);
            if (
                pointerType is null ||
                destination.type.toBasetype.isTypePointer is null ||
                !destination.type.toBasetype.equals(pointerType.toBasetype)
            )
                return false;
            return constructVariableSymbolOffsetInto(symbol, destination);
        }

        if (
            expression.type is null ||
            destination.type.toBasetype.isTypePointer is null ||
            !destination.type.toBasetype.equals(expression.type.toBasetype)
        )
            return false;

        if (auto address = expression.isAddrExp)
            return constructAddressExpressionInto(address, destination);

        // Function pointers retain their symbolic callable metadata. They
        // are not data pointers and stay on their existing path.
        if (destination.type.toBasetype.nextOf.toBasetype.isTypeFunction !is null)
            return false;

        if (expression.isNullExp !is null) {
            destination.storeReference(null);
            return true;
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
            // address through this typed `Place` preserves the null pointer.
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

    private bool constructAddressExpressionInto(
        imported!"dmd.expression".AddrExp address,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        auto pointerType = destination.type.toBasetype.isTypePointer;
        if (pointerType is null)
            return false;

        if (pointerType.nextOf.toBasetype.isTypeFunction !is null) {
            if (auto symbol = address.e1.isSymOffExp)
                if (auto function_ = symbol.var.isFuncDeclaration) {
                    storeFunctionPointerId(destination, functionPointerId(function_));
                    return true;
                }
            if (auto delegate_ = address.e1.isDelegateExp) {
                storeFunctionPointerId(
                    destination,
                    runDelegateExpression(delegate_).functionPointerId,
                );
                return true;
            }
            return false;
        }

        clearStoredMetadata(destination.type, destination.address);
        destination.storeReference(addressOfExpression(address.e1, address.op));
        return true;
    }

    // `&local`, and `&buf[constantIndex]` which DMD folds to
    // `SymOffExp(buf, byteOffset)`, stores the binding's host address directly
    // in the pointer destination. A pointer to a whole static array retains
    // the binding base because the pointee is the array, not one element.
    private bool constructVariableSymbolOffsetInto(
        imported!"dmd.expression".SymOffExp symbol,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        auto variable = symbol.var.isVarDeclaration;
        if (variable is null)
            return false;

        materializeDatasegInitializer(variable);
        if (!hasBindingPlace(variable))
            throw new Exception("Symbol offset has no native binding place.");

        auto base = bindingPlace(variable).address; // Offset arithmetic needs void*.
        const pointsAtWholeStaticArray =
            isStaticArrayType(variable.type) &&
            isStaticArrayType(symbol.type.toBasetype.nextOf);
        destination.storeReference(
            pointsAtWholeStaticArray
                ? base
                : offsetPointerAddress(base, cast(long) symbol.offset),
        );
        return true;
    }

    // Most `SymOffExp` nodes have their address type. DMD can instead retype
    // one to the final cast result, such as a class reference over raw static-
    // array storage, although the node still denotes the declaration's
    // address. Its physical destination is then a pointer to that declaration.
    private imported!"dmd.mtype".Type variableSymbolOffsetPointerType(
        imported!"dmd.expression".SymOffExp symbol,
    ) {
        import dmd.typesem: pointerTo;

        auto variable = symbol.var.isVarDeclaration;
        if (variable is null || symbol.type is null)
            return null;
        if (symbol.type.toBasetype.isTypePointer !is null)
            return symbol.type;
        return variable.type is null ? null : variable.type.pointerTo;
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

    // D defines relational comparison for arithmetic values and pointers.
    // DMD lowers arrays and overloaded comparisons before execution reaches
    // this point. Construct each pointer operand in source order, compare its
    // native address, and write the boolean result to its typed destination.
    private bool constructPointerComparisonInto(
        imported!"dmd.expression".CmpExp comparison,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.types: isPointerType;

        if (
            comparison.type is null ||
            destination.type is null ||
            !destination.type.toBasetype.equals(comparison.type.toBasetype) ||
            !isPointerType(comparison.e1.type) ||
            !isPointerType(comparison.e2.type)
        )
            return false;

        const left = pointerOperandPlace(comparison.e1).deref.address;
        const right = pointerOperandPlace(comparison.e2).deref.address;
        const difference = pointerAddressDifference(left, right);

        switch (comparison.op) with (EXP) {
            case lessThan: destination.storeNativeScalar(difference < 0); return true;
            case lessOrEqual: destination.storeNativeScalar(difference <= 0); return true;
            case greaterThan: destination.storeNativeScalar(difference > 0); return true;
            case greaterOrEqual: destination.storeNativeScalar(difference >= 0); return true;
            default: return false;
        }
    }

    // A dereference reads the value at the pointed-to native address. The
    // address itself remains the pointer representation; copying from this
    // typed place handles scalars, pointers, and aggregates. Keep a null
    // dereference on the old diagnostic path rather than
    // faulting while composing a raw host place.
    private bool constructDereferenceInto(
        imported!"dmd.expression".Expression expression,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isPointerType;

        auto pointer = expression.isPtrExp;
        if (pointer is null || !isPointerType(pointer.e1.type))
            return false;

        auto destinationPointer = destination.type.toBasetype.isTypePointer;
        if (
            expression.type !is null &&
            expression.type.toBasetype.isTypeFunction !is null &&
            destinationPointer !is null &&
            destinationPointer.nextOf.toBasetype.isTypeFunction !is null
        ) {
            copyQualificationConvertedPlaceValue(
                pointerOperandPlace(pointer.e1),
                destination,
            );
            return true;
        }

        if (
            expression.type is null ||
            !destination.type.toBasetype.equals(expression.type.toBasetype)
        )
            return false;

        auto source = pointerOperandPlace(pointer.e1).deref;
        if (source.address is null)
            throw new Exception(
                "data pointers must carry a native binding address",
            );

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
        if (auto identity = expression.isIdentityExp) {
            const same = identityOperands(identity);
            destination.storeNativeScalar(cast(T) (
                identity.op == EXP.notIdentity ? !same : same
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
                    case add, min, mul, div, mod:
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
                    case mod: destination.storeNativeScalar(left % right); return true;
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
    // activation slot, then inspect that type's native representation.
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
        return placeIsTruthy(destination.place);
    }

    private bool placeIsTruthy(
        imported!"quickbite.backends.interpreter.place".Place place,
    ) {
        import dmd.astenums: TY;

        switch (place.type.toBasetype.ty) with (TY) {
            case Tbool: return place.loadNativeScalar!bool;
            case Tint8: return place.loadNativeScalar!byte != 0;
            case Tuns8, Tchar: return place.loadNativeScalar!ubyte != 0;
            case Tint16: return place.loadNativeScalar!short != 0;
            case Tuns16, Twchar: return place.loadNativeScalar!ushort != 0;
            case Tint32: return place.loadNativeScalar!int != 0;
            case Tuns32, Tdchar: return place.loadNativeScalar!uint != 0;
            case Tint64: return place.loadNativeScalar!long != 0;
            case Tuns64: return place.loadNativeScalar!ulong != 0;
            case Tfloat32: return place.loadNativeScalar!float != 0;
            case Tfloat64: return place.loadNativeScalar!double != 0;
            case Tfloat80: return place.loadNativeScalar!real != 0;
            case Tpointer:
                if (place.type.toBasetype.nextOf.toBasetype.ty == Tfunction)
                    return loadFunctionPointerId(place) !is null ||
                        place.loadReference !is null;
                return place.loadReference !is null;
            case Tdelegate:
                const slot = loadDelegateSlot(place);
                return slot.isNative
                    ? slot.funcptr !is null
                    : slot.functionPointerId != 0;
            case Tclass:
                return loadTypeInfoName(place) !is null ||
                    place.loadReference !is null;
            case Taarray: return place.loadReference !is null;
            case Tarray: return place.sliceDataPointer !is null;
            default: throw new Exception("Unsupported condition type.");
        }
    }

    private bool scalarComparison(imported!"dmd.expression".CmpExp comparison) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;

        // Comparison operands share DMD's common arithmetic type. Dispatching
        // on that stamped type preserves unsigned 64-bit values and narrow
        // signed overflow.
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
    // load serve `identityOperands` too.
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
        // each one in its own typed place before comparison.
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

    // A slice initializer constructs one native header over its source bytes.
    private bool constructSliceInto(
        imported!"dmd.expression".SliceExp slice,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.native_array: NativeArray;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.frontend.dmd.types: isPointerType;

        const pointer = isPointerType(slice.e1.type);
        if (pointer && slice.upr is null)
            return false;
        Place source;
        if (pointer)
            source = pointerOperandPlace(slice.e1);
        else if (hasArrayProjectionPlace(slice.e1))
            source = projectionPlace(slice.e1);
        else if (
            slice.e1.isDotVarExp !is null &&
            hasProjectionPlace(slice.e1)
        )
            source = projectionPlace(slice.e1);
        else if (!classRootedFieldPlace(slice.e1, source))
            source = constructedExpressionPlace(slice.e1);
        const sourceLength = pointer ? 0 : source.arrayLength;
        if (!pointer && slice.lengthVar !is null)
            setLocal(slice.lengthVar, sourceLength);

        const lower = slice.lwr is null
            ? 0
            : scalarOperand!size_t(slice.lwr);
        const upper = slice.upr is null
            ? sourceLength
            : scalarOperand!size_t(slice.upr);
        if (pointer && lower > upper) {
            import std.conv: text;

            throwRangeError(text(
                "slice [",
                lower,
                " .. ",
                upper,
                "] has a larger lower index than upper index",
            ));
        }
        if (lower > upper || !pointer && upper > sourceLength)
            throwRangeError("Range violation");

        auto sourceType = source.type.toBasetype;
        auto data = pointer
            ? source.loadReference
            : sourceType.isTypeDArray !is null
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
    // pointer carrying no live address instead of composing that address and
    // reading it. Reading it would fault, which ends the process rather than
    // failing one unittest, and no assertion can observe a fault -- so the
    // reporting engines are the ones a fixture can pin
    // (`lang/diagnostics.d`'s null-dereference block). The shapes this
    // excludes fire nowhere in the test corpus or the dub gate, so the
    // fallback keeps them at no measurable cost.
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
        import quickbite.backends.interpreter.place: clearPlace;

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
        in bool consumeMetadata = false,
    ) {
        copyStoredMetadata(
            destination.type,
            cast(void*) source.address,
            destination.address,
            consumeMetadata,
        );
        destination.copyFromUnchecked(source);
    }

    // A qualification-only conversion keeps the same representation and
    // metadata identity. Retype the source view to the destination's static
    // type so Place's stricter byte-copy check does not reject `T` ->
    // `const(T)`/`inout(T)` copies that DMD's type equality accepts.
    private void copyQualificationConvertedPlaceValue(
        imported!"quickbite.backends.interpreter.place".Place source,
        imported!"quickbite.backends.interpreter.place".Place destination,
    ) {
        import quickbite.backends.interpreter.place: Place;

        if (source.type.toBasetype.equals(destination.type.toBasetype)) {
            copyPlaceValue(Place(source.address, destination.type), destination);
            return;
        }

        copyPlaceValue(source, destination);
    }


    private void defaultLocalValue(VarDeclaration variable) {
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;

        auto destination = ConstructionDestination(bindingPlace(variable));
        runExpression(
            variable.type.defaultInitLiteral(Loc.initial),
            destination,
        );
    }

    private bool isRefVariable(VarDeclaration variable) const {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.ref_) != STC.none;
    }

    private bool isManifestVariable(VarDeclaration variable) const {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.manifest) != STC.none;
    }

    // Postfix increment and decrement select their live lvalue once. When the
    // result is observed, the old value is copied to its place before the
    // selected storage is mutated, so the result stays independent of the
    // write.
    private bool runPostExpression(
        imported!"dmd.expression".PostExp post,
        imported!"quickbite.backends.interpreter.place".Place* destination,
    ) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.place: Place;

        if (
            post.e1 is null ||
            post.e1.type is null ||
            destination !is null && destination.type is null
        )
            return false;

        const delta = post.op == EXP.plusPlus
            ? 1
            : post.op == EXP.minusMinus
                ? -1
                : 0;
        if (delta == 0)
            return false;

        const resultKind = post.e1.type.toBasetype.ty;
        if (
            destination !is null &&
            destination.type.toBasetype.ty != resultKind
        )
            return false;

        Place target;
        bool clearsProjectionRoot;

        if (auto var = post.e1.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported eval post expression target.");

            materializeDatasegInitializer(variable);
            if (!hasBindingPlace(variable))
                throw new Exception("Unsupported eval post expression target.");
            if (isUninitializedBinding(variable)) {
                import quickbite.backends.interpreter.messages:
                    uninitializedVariableMessage;

                throw new Exception(uninitializedVariableMessage(
                    variable,
                    currentFunction,
                ));
            }

            target = bindingPlace(variable);
            clearsProjectionRoot = true;
        } else if (isDirectProjectionWriteTarget(post.e1)) {
            target = directWriteProjectionPlace(post.e1);
            clearsProjectionRoot = true;
        } else if (auto pointer = post.e1.isPtrExp) {
            target = Place(
                pointerOperandPlace(pointer.e1).deref.address,
                post.e1.type.toBasetype,
            );
        } else if (auto index = post.e1.isIndexExp) {
            import quickbite.frontend.dmd.types: isPointerType;

            if (!isPointerType(index.e1.type))
                return false;
            auto pointer = pointerOperandPlace(index.e1);
            const arrayIndex = scalarOperand!size_t(index.e2);
            target = Place(
                pointer.index(arrayIndex).address,
                post.e1.type.toBasetype,
            );
        } else if (auto dot = post.e1.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field is null || dot.e1.type is null)
                return false;

            if (hasProjectionPlace(dot)) {
                target = projectionPlace(dot, /* writeBounds */ true);
                clearsProjectionRoot = true;
            } else {
                if (dot.e1.type.toBasetype.isTypeClass is null)
                    return false;

                auto receiver = ConstructionDestination(Place(
                    _activationFrame.temporaryAddress(dot.e1),
                    dot.e1.type,
                ));
                runExpression(dot.e1, receiver);
                auto bodyAddress = receiver.place.deref.address;
                auto bodyType = dot.e1.type;
                if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = (*metadata).type;
                }
                target = Place(bodyAddress, bodyType).field(field);
            }
        } else {
            return false;
        }

        const kind = target.type.toBasetype.ty;
        if (kind == TY.Tpointer) {
            if (resultKind != TY.Tpointer)
                return false;

            // `auto`: the typed pointer stores below require a mutable
            // address, although this helper does not mutate through it.
            auto oldAddress = target.deref.address;
            if (destination !is null)
                destination.storeReference(oldAddress);
            target.storeReference(offsetPointerAddress(
                oldAddress,
                delta * cast(long) pointerElementSize(target.type),
            ));
        } else {
            if (resultKind != kind)
                return false;

            switch (kind) with (TY) {
                case Tint8: postIncrementScalar!byte(target, destination, delta); break;
                case Tuns8: postIncrementScalar!ubyte(target, destination, delta); break;
                case Tchar: postIncrementScalar!char(target, destination, delta); break;
                case Tint16: postIncrementScalar!short(target, destination, delta); break;
                case Tuns16: postIncrementScalar!ushort(target, destination, delta); break;
                case Twchar: postIncrementScalar!wchar(target, destination, delta); break;
                case Tint32: postIncrementScalar!int(target, destination, delta); break;
                case Tuns32: postIncrementScalar!uint(target, destination, delta); break;
                case Tdchar: postIncrementScalar!dchar(target, destination, delta); break;
                case Tint64: postIncrementScalar!long(target, destination, delta); break;
                case Tuns64: postIncrementScalar!ulong(target, destination, delta); break;
                case Tfloat32: postIncrementScalar!float(target, destination, delta); break;
                case Tfloat64: postIncrementScalar!double(target, destination, delta); break;
                case Tfloat80: postIncrementScalar!real(target, destination, delta); break;
                case Timaginary32: postIncrementScalar!ifloat(target, destination, delta); break;
                case Timaginary64: postIncrementScalar!idouble(target, destination, delta); break;
                case Timaginary80: postIncrementScalar!ireal(target, destination, delta); break;
                case Tcomplex32: postIncrementScalar!cfloat(target, destination, delta); break;
                case Tcomplex64: postIncrementScalar!cdouble(target, destination, delta); break;
                case Tcomplex80: postIncrementScalar!creal(target, destination, delta); break;
                default: return false;
            }
        }

        if (clearsProjectionRoot)
            clearProjectionRootUninitialized(post.e1);
        return true;
    }

    private void postIncrementScalar(T)(
        imported!"quickbite.backends.interpreter.place".Place target,
        imported!"quickbite.backends.interpreter.place".Place* destination,
        in int delta,
    ) {
        const oldValue = target.loadNativeScalar!T;
        if (destination !is null)
            destination.storeNativeScalar(oldValue);
        target.storeNativeScalar(cast(T) (oldValue + delta));
    }

}


private imported!"dmd.mtype".TypeStruct receiverStructType(
    imported!"dmd.expression".Expression receiver,
) {
    if (receiver.type is null)
        return null;

    return receiver.type.toBasetype.isTypeStruct;
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
private imported!"quickbite.backends.interpreter.place".Place nativeConstructorReceiverPlace(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"quickbite.backends.interpreter.place".Place receiver,
) {
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.runtime_values: defaultValueOwner;

    auto structDecl = function_.parent is null
        ? null
        : function_.parent.isStructDeclaration;
    if (structDecl is null)
        return receiver;
    auto owner = defaultValueOwner(structDecl.type);
    return Place(owner.address, structDecl.type);
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
// same typed-place copy used by assignments. The caller retains the reference
// slot and body allocation.
private void initializeNativeClassBody(
    ref Walker walker,
    imported!"dmd.mtype".Type type,
    imported!"quickbite.backends.interpreter.native_aggregate".NativeAggregate object,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.layout: classFields;
    import quickbite.backends.interpreter.place: Place;
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
            Place source;
            if (auto initializer = field._init.isExpInitializer)
                source = walker.constructedExpressionPlace(initializer.exp);
            else if (field._init.isArrayInitializer !is null)
                source = classFieldArrayLiteralDefault(walker, field);
            else
                continue;
            walker.copyPlaceValue(source, destination);
        }
    }
}


// A `Tarray`/`Tsarray` class field's own array-literal default (`int[] arr
// = [1, 2, 3];`) parses as an `ArrayInitializer`, not the `ExpInitializer`
// a scalar default parses as. Real D evaluates that literal once, into the
// class's static `.init` data, and every `new` that does not override the
// field shares that one backing array: mutating it through one instance is
// visible through another. Evaluate the literal once per field declaration
// and cache the resulting native array place, so every later instance's
// field descriptor points at the same backing storage instead of a fresh
// per-object copy.
private imported!"quickbite.backends.interpreter.place".Place
classFieldArrayLiteralDefault(
    ref Walker walker,
    imported!"dmd.declaration".VarDeclaration field,
) @trusted {
    import dmd.initsem: initializerToExpression;
    import quickbite.backends.interpreter.layout:
        typeByteSize, typeHasPointers;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.backends.interpreter.place: Place;

    if (walker.classArrayFieldDefaults is null)
        walker.classArrayFieldDefaults = new ClassArrayFieldDefaults;
    const key = cast(const(void)*) field._init;
    if (auto cached = key in walker.classArrayFieldDefaults.table)
        return Place(cached.address, field.type);

    auto value = walker.constructedExpressionPlace(
        field._init.initializerToExpression,
    );
    auto block = NativeBlock.allocate(
        typeByteSize(field.type),
        typeHasPointers(field.type)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no,
    );
    walker.copyPlaceValue(value, Place(block.address, field.type));
    walker.classArrayFieldDefaults.table[key] = block;
    return Place(block.address, field.type);
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
// interpreter-tracked declaration to recover from a bare address later, so
// this never manufactures one for a struct or scalar `typeid`.
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
    // `constructFunctionLiteralInto` borrows the enclosing activation's live
    // `this` for a captured nested literal); or,
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

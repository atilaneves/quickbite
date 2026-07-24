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
    import quickbite.backends.interpreter.object_table: ObjectTable;
    import quickbite.backends.interpreter.runtime_value: Value;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;

    public alias eval = Evaluator.eval;

    public this() @safe @nogc nothrow pure {
    }

    public this(const string[] dependencyImages) {
        import quickbite.ffi: loadDependencyImages;

        loadDependencyImages(dependencyImages);
    }

    public override bool supportsReplPreludeFormatter() const
    @safe @nogc nothrow pure {
        return true;
    }

    public override EvalResult eval(FuncDeclaration function_) {
        try {
            Walker walker;
            scope(exit) walker.closeDurableInboundSession;
            walker.classObjectTable = new ObjectTable;
            walker.moduleTable = new ModuleTable;
            walker.inUnitTest = function_.isUnitTestDeclaration !is null;
            auto layout = cachedFrameLayout(function_);
            walker._activationFrame = FrameBlock.allocate(layout);
            walker.runStatement(function_.fbody);
            return EvalResult(interpreterDisplayString(walker.result, function_));
        } catch (Exception exception) {
            // The interpreter's own message, verbatim: rewriting it through
            // DMD's CTFE engine (as an earlier revision did) replaced the
            // real, actionable error with whichever body-less leaf CTFE
            // happened to reject.
            return EvalResult(EvalResult.Diagnostic(exception.msg));
        }
    }

    protected override EvalResult executeUnitTest(
        UnitTestDeclaration unitTest,
    ) {
        try {
            Walker walker;
            scope(exit) walker.closeDurableInboundSession;
            walker.classObjectTable = new ObjectTable;
            walker.moduleTable = new ModuleTable;
            walker.inUnitTest = true;
            auto layout = cachedFrameLayout(unitTest);
            walker._activationFrame = FrameBlock.allocate(layout);
            walker.runStatement(unitTest.fbody);
            return EvalResult("");
        } catch (Exception exception) {
            return EvalResult(EvalResult.Diagnostic(exception.msg));
        }
    }

    public override ReplSession createReplSession() {
        return new InterpreterReplSession(this);
    }

    private EvalResult evalFormattedDisplay(FuncDeclaration function_) {
        try {
            Walker walker;
            scope(exit) walker.closeDurableInboundSession;
            walker.classObjectTable = new ObjectTable;
            walker.moduleTable = new ModuleTable;
            auto layout = cachedFrameLayout(function_);
            walker._activationFrame = FrameBlock.allocate(layout);
            walker.runStatement(function_.fbody);
            return EvalResult(walker.result.asCharArrayString);
        } catch (Exception exception) {
            return EvalResult(EvalResult.Diagnostic(exception.msg));
        }
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

private string interpreterDisplayString(
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.interpreter.runtime_value: Value;
    import quickbite.frontend.dmd.types: isCharacterArrayType;

    if (value == Value.void_)
        return "";

    auto returnType = function_.type is null ? null : function_.type.nextOf;
    if (isCharacterArrayType(returnType))
        return `"` ~ value.asCharArrayString ~ `"` ~ value.stringTypeAnnotation;

    return value.toString;
}

private enum LoopControl {
    none,
    break_,
    continue_,
}

private enum nativeExceptionObjectPointerField =
    "__quickbiteNativeThrowableObjectPointer";

private struct ArrayElementAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t index;
}

private struct StructFieldAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t index;
    public bool isClass;
}

// The evaluated indices within one `ref`/`out` call argument.  The ordinary
// expression walk records them as it evaluates the argument; binding the
// callee's reference slot later composes its address from those exact results
// rather than evaluating an index expression again.
private struct EvaluatedReferenceArgument {
    public size_t[const(void)*] indices;
}

// Stable identity for storage reached from one root variable by a sequence of
// DMD field indices.  The path is owned and immutable because keys stored in
// an associative array must not change after insertion.
private struct FieldPathKey {
    public imported!"dmd.declaration".VarDeclaration root;
    public immutable(size_t)[] indices;
}

private class InterpretedException: Exception {
    public imported!"quickbite.backends.interpreter.runtime_value".Value object;

    public this(in imported!"quickbite.backends.interpreter.runtime_value".Value object) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        const message = AggregateValue.classFieldNamed(object, "msg").asCharArrayString;
        super(message);
        this.object = object;
    }
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
    import quickbite.backends.interpreter.object_table: ObjectTable;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.runtime_values: defaultValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    private Throwable[const(void)*] nativeThrowableRoots;

    private Value[VarDeclaration] locals;

    // Non-null only while `runRefArgumentExpression` is walking one call
    // argument.  `runIndexExpression` records its already-evaluated result in
    // the active argument's identity-keyed table; nested calls save and
    // restore this pointer around their own argument evaluation.
    private size_t[const(void)*]* _evaluatedReferenceArgumentIndices;

    // Authoritative native bytes for an address-taken scalar local:
    // populated eagerly the moment `&local` is taken (see
    // `localPointerValue`), for `native_scalar.
    // isNativeScalarType` locals only. Non-address-taken locals, and every
    // aggregate/pointer local, still live only in `locals` above -- this
    // table is a narrow byte-level authority, not a replacement for it.
    // `locals[variable]` stays a synchronously-refreshed mirror of a cell's
    // bytes for as long as a cell exists, so alias/child-Walker paths that
    // only know about `locals` keep seeing the true value.
    private NativeBlock[VarDeclaration] scalarCells;

    // Authoritative native bytes for an address-taken dynamic array local
    // whose element type is `native_scalar.isNativeScalarType`, mirroring
    // `scalarCells` above: populated eagerly the moment `&a[i]` is taken
    // (see `promoteArrayCell`,
    // called from `arrayPointer`). Once a cell exists, a direct element
    // write (`writeIndexLocation`), a write THROUGH a pointer into the
    // element (`writeThroughArrayPointer`), and a pointer deref-read
    // (`runPointerExpression`) all route through the same underlying
    // `NativeArray` bytes instead of `locals`' detached, `.dup`'d elements,
    // so a write through any one of them is visible through the others. Every
    // other array (non-scalar elements, static arrays, growth, slices) is
    // untouched and keeps using the existing boxed/aliasing paths.
    private NativeArray[VarDeclaration] arrayCells;

    // Set (never cleared once true within a frame) by `writeCelledLocal`
    // whenever it replaces `variable`'s array value wholesale rather than
    // mutating one in place -- a plain (non-writeback) assignment, or a
    // ref-writeback whose length changed. The cross-frame writeback call sites
    // (`writeBackNestedLocals`, `writeBackArrayPointerTargets`,
    // `writeBackRefArguments`) need this to tell a genuine REBIND of a
    // ref/captured array apart from an element-level mutation that
    // happened to promote no `arrayCells` entry of its own (`p[0] = x;`
    // through a `ref int[] p` that never took `&p[i]`) -- both leave
    // `variable` absent from `arrayCells` at return, so cell presence alone
    // cannot distinguish them. Keyed by the SAME `VarDeclaration`
    // `writeCelledLocal` was called for: a captured/recursive variable
    // reuses the identical AST node across frames, and a `ref` parameter's
    // own (distinct) node is exactly what `writeBackRefArguments` resolves
    // its writeback decision against.
    private bool[VarDeclaration] arrayRebinds;

    // Class sibling of `arrayRebinds` above: set (never cleared once true within a
    // frame) by `writeCelledLocal` whenever it drops `variable`'s `classCells`
    // entry rather than refreshing it in place -- a plain reference REBIND
    // (`c = b;`), as opposed to a same-object field-write refresh
    // (`writeLocation`'s `DotVarExp`/class-array-field arms, which pass
    // `writeCelledLocal`'s own `classFieldRefresh` flag as `true`). A class
    // has no `opAssign`, so every OTHER plain-`VarExp` assignment of a class
    // value is, by the language's own semantics, always a rebind -- never a
    // field mutation of the SAME object -- and the shared cell (if any) can
    // no longer represent the new value in place without corrupting whatever
    // OTHER alias still shares it (exactly the corruption this fix closes).
    // `writeBackNestedLocals` reads THIS map on `child` (`classWritebackIsMutation`,
    // mirroring `arrayWritebackIsMutation`) to tell a nested/captured
    // variable's genuine in-frame field mutation apart from the callee
    // rebinding it to a different object, before deciding whether the
    // parent's own cell may be refreshed in place or must be dropped too.
    private bool[VarDeclaration] classRebinds;

    // Per-variable record of whether THIS activation's most recent
    // `mirrorToFrame` write for `variable`'s CURRENT binding actually
    // wrote real storage -- composed bytes for a place-composable local, a
    // `{ length, ptr }` header for a slice, or a class reference plus body
    // (a genuine `null` reference, or a resolved non-null one) -- rather
    // than declining. Closes a write/verify TIME
    // asymmetry: `assertClassFrameMirror` used to re-run
    // `classBodyShapeMatches` (and this function's own `Value.null_`/
    // `isClassObject`/`identity == 0`/`isClassBodyComposable` guards)
    // independently at READ time, which can DISAGREE with what the WRITE
    // actually did, because `classBodyShapeMatches` consults MUTABLE
    // walker state (`classIdentityAliasedByAnotherBinding`'s `locals`
    // scan, `classBodyShapeMatchesImpl`'s `classObjectCells` check) that
    // can change between the write and a later read. Confirmed by
    // instrumenting both functions directly: `p = new C(); p.x = seed;`
    // (an unaliased, successful write -- `p`'s frame slot now holds a real
    // object address) followed by `p = identity(y);` where `y` is another
    // live binding of a DIFFERENT object -- `classIdentityAliasedByAnotherBinding`
    // declines this write, so `p`'s frame slot keeps its OLD, unrelated
    // address -- and then `y = null;` before a later read of `p`: the
    // re-derived decision no longer declines (nothing aliases `y`'s former
    // identity any more), so the OLD code went on to compare `p`'s stale,
    // NON-zero frame slot against a freshly composed expectation for the
    // NEW object -- a guaranteed "frame class reference mirror diverged
    // from boxed local" `AssertError` on a correct guest program. Unlike
    // the simpler "never written" case (an all-zero slot), that mismatch
    // is not zero-fill-detectable, so `assertClassReferenceMirror`'s own
    // all-zero skip cannot mask it.
    //
    // `mirrorToFrame` is the ONLY writer, setting this on every one of its
    // own exits (`scope(exit)`, its own header comment) -- `true` only
    // after an actual write by one of its arms (including
    // `mirrorClassToFrame`'s own `Value.null_` arm), `false` on every
    // decline, its own and its arms' alike. Two consumers read it, and
    // neither re-derives the decision for itself:
    //
    // - `assertClassFrameMirror` returns without asserting when it is
    //   absent or `false` -- trusting what the write already decided
    //   rather than a second, possibly-stale opinion.
    // - `callerReferenceBase` refuses to hand a caller-side base address
    //   out of an unestablished slot at all, so no reference-slot
    //   composition ever reads (let alone dereferences) storage the write
    //   side never filled. That consumer is why this record covers every
    //   `mirrorToFrame` arm rather than only the class one: composition
    //   follows a stored reference out of a slot for a class base
    //   (`Place.deref`) or a pointer base alike, and a pointer local whose
    //   mirror declined (a boxed-era carrier with no host address --
    //   `valueMatchesPlace`'s pointer arm) leaves a slot exactly as
    //   unusable as a declined class local's does.
    //
    // Needs no separate rebind invalidation: `locals[variable] = value` is
    // written ONLY by `setLocal`, which calls `mirrorToFrame` with that
    // SAME value immediately afterwards, for every write path this walker
    // has -- declaration, rebind, a loop's fresh binding, parameter
    // binding, and a field mutation's read-modify-write reconstruction
    // alike -- so this map is always freshly overwritten by the very write
    // that changes `variable`'s current binding; there is no path that
    // changes `locals[variable]` without `mirrorToFrame` running again
    // right after.
    //
    // Says nothing, on its own, about a local whose CELL (`scalarCells`/
    // `structCells`/`arrayCells`/`classCells`) is the authority for it: a
    // write through the cell (`writeCelledLocal`, or
    // `writeBackLocalPointerTargets` after a callee mutated the local
    // through a pointer) deliberately leaves the frame slot behind without
    // running `setLocal` at all, so this record stays `true` from the last
    // real mirror write while the slot itself goes stale. Being established
    // is therefore necessary for a slot to be worth VERIFYING, never
    // sufficient, and both consumers pair it with the same four-map cell
    // check (`cellIsAuthorityFor`) for exactly that reason:
    // `assertClassFrameMirror` gets that check from its own caller
    // (`assertFrameMirror`'s own first guard), and `callerReferenceBase`
    // makes it itself, against the caller-side cell maps this activation
    // was forked with. Not duped into a child frame by `forkPerFrameCellsInto`, for
    // the identical reason `arrayRebinds`/`classRebinds` above are not
    // (their own field comments): a fresh activation's frame slots start
    // GC-zeroed and unwritten, so "not yet established" (absent, `false`
    // by `get`'s default) is already the correct starting state.
    private bool[VarDeclaration] mirrorEstablished;

    // Per-variable snapshot of `object_table.ObjectTable.generation` for
    // every identity `mirrorClassToFrame`'s established graph composed --
    // this variable's own top-level identity and every nested class-typed
    // field's identity, transitively -- taken right after the write that
    // set `mirrorEstablished[variable]` true. Closes the gap
    // `mirrorEstablished` alone leaves open: that flag pins THIS
    // variable's own write/verify decision, but says nothing about the
    // SHARED, identity-keyed storage (`classObjectTable`) it vouches for --
    // storage a DIFFERENT binding's mirror write (another local aliasing a
    // NESTED identity through a `DotVarExp`, a sibling top-level local
    // sharing a nested identity, or a callee's own parameter mirror in a
    // DIFFERENT activation, since `classObjectTable` is one instance for
    // the whole execution -- its own field comment) can legitimately
    // rewrite AFTER this variable's mirror last established. Confirmed by
    // three fixtures (`class.sharedNestedBodyRewrittenBySiblingBindingDoesNotCrash`,
    // `...ByDotVarAliasDoesNotCrash`, `...AcrossActivationDoesNotCrash`):
    // each rewrites a NESTED identity of an established graph through a
    // second binding, which used to reach `assertClassBodyValue`'s final
    // byte comparison with `value` still holding the FIRST binding's own
    // stale snapshot of that field -- a guaranteed "class body mirror
    // diverged from boxed local" `AssertError` on a correct guest program
    // (the boxed staleness that causes it is itself a pre-existing,
    // documented gap -- `ai/plans/value.md`'s Cell coherence "Known gaps"
    // -- the crash was never inevitable, only this mirror's own re-
    // verification of stale bytes was).
    //
    // `assertClassBodyValue` checks each identity's CURRENT `classObjectTable.
    // generation` against what is recorded here before asserting its bytes;
    // a mismatch means some other write reached that identity in between,
    // so this skips the assertion for that identity (and, since a
    // rewritten body's own field values are no longer what `value`
    // describes, does not recurse into its fields either) rather than
    // comparing bytes the write side never actually vouched for. Recorded
    // by `recordClassMirrorGenerations`, called only from
    // `mirrorClassToFrame`'s own successful (non-`Value.null_`) write path,
    // right after `writeClassBody` returns -- so every generation recorded
    // here is the POST-write value, matching what `assertClassBodyValue`
    // will later re-read via the identical `classObjectTable.generation`.
    // Not consulted for a `Value.null_` local (`assertClassFrameMirror`'s
    // own null arm never reaches `assertClassBodyValue`), so left
    // unrecorded on that path. Not duped into a child frame by
    // `forkPerFrameCellsInto`, for the identical reason
    // `mirrorEstablished` above is not (its own field comment): a
    // fresh activation starts with nothing established, so an absent entry
    // (`generation(identity) != recordedGenerations.get(identity, size_t.max)`,
    // always true) is already the correct "nothing recorded yet" answer.
    private size_t[size_t][VarDeclaration] classMirrorGenerations;

    // Authoritative native bytes for a struct local that has had one of its
    // `native_scalar.isNativeScalarType` fields address-taken, mirroring
    // `arrayCells` above: populated eagerly the moment `&s.field` is taken
    // for a scalar field (see
    // `promoteStructCell`, called from `addressOfExpression`'s `DotVarExp`
    // arm). Once a cell exists, a direct field write (`writeLocation`'s
    // `DotVarExp` arm, via `writeCelledLocal`) and a pointer deref-read
    // (`runPointerExpression`/`pointerTargetValue`, via
    // `structFieldPointerCellValue`) route through the same underlying
    // `NativeStruct` bytes instead of the boxed snapshot `&s.field` used to
    // return, so a write through one is visible through the other. Only the
    // address-taken field(s) of a plain (non-nested, non-dataseg) struct
    // local are covered; every other field access (nested struct/array/class
    // fields, non-address-taken structs) is untouched and keeps using the
    // existing boxed `locals` path.
    private NativeStruct[VarDeclaration] structCells;

    // Set by `writeThroughStructFieldPointer` for the receiver variable it
    // wrote into, mirroring `arrayPointerWritebacks` above: a cross-frame
    // write (the receiver is the CALLER's own local, absent from the
    // callee's own `locals`) cannot refresh the caller's boxed mirror
    // immediately, so this flags `variable` for
    // `writeBackStructFieldPointerTargets` to re-derive from the
    // (shared-bytes) `structCells` entry once control returns to the frame
    // that actually owns `variable`.
    private bool[VarDeclaration] structFieldPointerWritebacks;

    // Reverse lookup from a promoted `&s.arr[i]` pointer's allocation id back
    // to which struct variable and (static-array) field index share the SAME
    // `structCells` entry's bytes -- the array-typed-field counterpart of
    // the common direct-field reverse lookup,
    // needed because a static-array field's pointer carries an element
    // offset (`Value.pointerElementOffset`) and its cell view is a
    // `NativeArray` (`NativeStruct.arrayField`), not the single scalar byte
    // range the direct-field reverse lookup resolves to. Populated by
    // `promoteStructArrayFieldCell`, called from `arrayPointer`'s
    // `DotVarExp` branch (mirroring `promoteStructFieldCell`'s role for a
    // scalar field). Cross-frame follow-up (2026-07-15): now duplicated into
    // child-frame walkers and merged back exactly like
    // the common direct-field reverse lookup
    // (`mergeStructArrayFieldPointerVariableMaps`), so a `&s.arr[i]` pointer
    // does survive being passed into another function; see
    // `structArrayFieldPointerWritebacks` below for the write-through side.
    private VarDeclaration[size_t] structArrayFieldPointerVariables;
    private size_t[size_t] structArrayFieldPointerFieldIndices;

    // Set by `writeThroughStructArrayFieldPointer` for the receiver variable
    // it wrote into, the array-typed-field sibling of
    // `structFieldPointerWritebacks`: a cross-frame write (the receiver is
    // the CALLER's own local, absent from the callee's own `locals`) cannot
    // refresh the caller's boxed mirror immediately, so this flags `variable`
    // for `writeBackStructArrayFieldPointerTargets` to re-derive from the
    // (shared-bytes) `structCells` entry once control returns to the frame
    // that actually owns `variable`.
    private bool[VarDeclaration] structArrayFieldPointerWritebacks;

    // Cross-frame writes through a common two-index `fieldPointerPaths`
    // entry still need the owning frame's boxed mirror refreshed after the
    // shared `structCells` bytes change.
    // Set by `writeThroughNestedStructFieldPointer` for the receiver variable
    // it wrote into, the nested-field sibling of
    // `structArrayFieldPointerWritebacks`: a cross-frame write (the receiver
    // is the CALLER's own local, absent from the callee's own `locals`)
    // cannot refresh the caller's boxed mirror immediately, so this flags
    // `variable` for `writeBackNestedStructFieldPointerTargets` to re-derive
    // from the (shared-bytes) `structCells` entry once control returns to
    // the frame that actually owns `variable`.
    private bool[VarDeclaration] nestedStructFieldPointerWritebacks;

    // Array-element sibling of the common nested-field reverse lookup:
    // `&a[i].inner.x` where `a` is a dynamic array of a (non-union) struct
    // whose `inner` field is itself a (non-union) struct, and `x` is a
    // scalar field of `inner`. The cell view is `NativeArray.
    // structElement(elementIndex).structField(outerIndex).field(innerIndex)`
    // -- composing the array-of-struct cell's own per-element
    // `NativeStruct` view (`promoteArrayCell`'s struct-element branch) with
    // the same nested-`NativeStruct` view the common field path resolves
    // through, both pre-existing composition accessors.
    // Populated by `promoteArrayNestedStructFieldCell`, called from
    // `addressOfExpression`'s `DotVarExp` branch alongside the existing
    // struct/nested-struct/class promotion calls. Narrower than
    // the common nested-field reverse lookup in the same way that family is
    // narrower than the direct-field reverse lookup: the id is never memoized
    // (this receiver shape already takes `fieldSnapshotAllocationId`'s
    // fresh-id fallback, same as the non-array nested-field case), and this
    // is same-frame only -- no cross-frame duping/merge/writeback, left as a
    // follow-up mirroring the non-array nested-field map's own history.
    private VarDeclaration[size_t] arrayNestedStructFieldPointerVariables;
    private size_t[size_t] arrayNestedStructFieldPointerElementIndices;
    private size_t[size_t] arrayNestedStructFieldPointerOuterFieldIndices;
    private size_t[size_t] arrayNestedStructFieldPointerInnerFieldIndices;

    // Authoritative native bytes for a class-typed local that has had one of
    // its `native_scalar.isNativeScalarType` fields address-taken, mirroring
    // `structCells` above: populated eagerly the moment `&c.field` is taken
    // for a scalar field (see
    // `promoteClassCell`, called from `addressOfExpression`'s `DotVarExp`
    // arm). Once a cell exists, a direct field write (`writeLocation`'s
    // `DotVarExp` arm, via `writeCelledLocal`) and a pointer deref-read
    // (`runPointerExpression`/`pointerTargetValue`, via
    // `classFieldPointerCellValue`) route through the same underlying byte
    // range instead of the boxed snapshot `&c.field` used to return, so a
    // write through one is visible through the other. Unlike `structCells`,
    // this is a plain `NativeBlock` (not a `NativeStruct`): a class's own
    // `Type.size` is a reference's pointer width, not the object body's
    // size, so the block is sized by summing this narrow slice's own
    // (offset + typeByteSize) over `layout.classFields`, not `NativeStruct.
    // allocate`'s `TypeStruct`-only sizing. This map caches the
    // identity-owned block below for bindings that need variable reverse
    // lookup; it does not own object storage.
    private NativeBlock[VarDeclaration] classCells;
    // Class object bodies are owned by object identity. `classCells` is only
    // a binding cache into this table; rebinding a variable drops that cache
    // without destroying storage still reachable through another reference.
    private NativeBlock[size_t] classObjectCells;

    // Common reverse lookup from a field pointer's allocation id to its root
    // variable and DMD field-index path. Direct scalar struct and class fields
    // are migrated; the remaining shape-specific maps move here without
    // changing this representation.
    private FieldPathKey[size_t] fieldPointerPaths;
    // A class-field pointer remains attached to the object after the variable
    // used to reach it is rebound. Index its object identity by allocation id
    // instead of retaining another storage handle.
    private size_t[size_t] classFieldPointerObjectIds;

    // Set by `writeThroughClassFieldPointer` for the receiver variable it
    // wrote into, the class sibling of `structFieldPointerWritebacks`: a
    // cross-frame write (the receiver is the CALLER's own local, absent from
    // the callee's own `locals`) cannot refresh the caller's boxed mirror
    // immediately, so this flags `variable` for
    // `writeBackClassFieldPointerTargets` to re-derive from the
    // (shared-bytes) `classCells` entry once control returns to the frame
    // that actually owns `variable`.
    private bool[VarDeclaration] classFieldPointerWritebacks;

    // A promoted `&c.inner.x` pointer uses the common two-index
    // `fieldPointerPaths` reverse lookup to reach the class variable and
    // (outer, inner) field-index pair sharing the SAME `classCells` entry's
    // bytes. This is the class-receiver sibling of the nested struct field
    // path above, one level of struct-field nesting only:
    // `inner` must itself be a (non-union) struct field of a plain class
    // local, and `x` a scalar field of `inner`. The cell view is a
    // `NativeStruct` adopted over `classCells[variable].subRange(outerOffset,
    // outerSize)` at the inner field index -- the same composition accessor
    // (`NativeStruct.adopt`/`NativeStruct.field`) the struct phase's own
    // nested-field slice already uses, just built from a plain `NativeBlock`
    // instead of a `NativeStruct` (a `classCells` entry has no `NativeStruct`
    // wrapper of its own -- see `classCells`'s own comment above). Populated
    // by `promoteNestedClassStructFieldCell`, called from
    // `addressOfExpression`'s `DotVarExp` branch alongside
    // `promoteClassFieldCell`, mirroring how that branch already combines
    // `promoteStructFieldCell`/`promoteNestedStructFieldCell`. Write-
    // through-pointer support (`*p = v`) landed in a follow-up slice --
    // `writeThroughNestedClassStructFieldPointer`, wired into
    // `writeLocation`'s `PtrExp` arm and `writePointerTarget` alongside its
    // struct/class-field siblings. The common reverse lookup is duplicated
    // into child walkers and merged back with the owning frame's field-path
    // allocation memo winning, so the pointer survives a function call; see
    // `nestedClassStructFieldPointerWritebacks` below for the write-through
    // side.

    // Set by `writeThroughNestedClassStructFieldPointer` for the receiver
    // variable it wrote into, the class-receiver sibling of
    // `nestedStructFieldPointerWritebacks`: a cross-frame write (the receiver
    // is the CALLER's own local, absent from the callee's own `locals`)
    // cannot refresh the caller's boxed mirror immediately, so this flags
    // `variable` for `writeBackNestedClassStructFieldPointerTargets` to
    // re-derive from the (shared-bytes) `classCells` entry once control
    // returns to the frame that actually owns `variable`.
    private bool[VarDeclaration] nestedClassStructFieldPointerWritebacks;

    // Reverse lookup from a promoted `&c.arr[i]` pointer's allocation id back
    // to which class variable and field index share the SAME `classCells`
    // entry's bytes -- the class-receiver sibling of
    // `structArrayFieldPointerVariables`/`...FieldIndices` above, the other
    // aggregate-composition shape alongside the nested-class-struct-field
    // case: `arr` must be a scalar-element static-array field of a plain
    // class local.
    // The cell view is a `NativeArray` adopted over
    // `classCells[variable].subRange(offset, size)` -- the same composition
    // primitive (`NativeArray.adopt`) `NativeStruct.arrayField` uses
    // internally for a struct receiver, built directly from a plain
    // `NativeBlock` instead (a `classCells` entry has no `NativeStruct`
    // wrapper of its own -- see `classCells`'s own comment above). Populated
    // by `promoteClassArrayFieldCell`, called from `arrayPointer`'s
    // `DotVarExp` branch alongside `promoteStructArrayFieldCell`.
    // Write-through-pointer support (`*p = v`) landed in a follow-up slice --
    // `writeThroughClassArrayFieldPointer`, wired into `writeLocation`'s
    // `PtrExp` arm and `writePointerTarget`. Cross-frame follow-up
    // (2026-07-15): now duplicated into child-frame walkers and merged back
    // exactly like `structArrayFieldPointerVariables`/
    // `structArrayFieldPointerFieldIndices`
    // (`mergeClassArrayFieldPointerVariableMaps`), so a `&c.arr[i]` pointer
    // does survive being passed into another function; see
    // `classArrayFieldPointerWritebacks` below for the write-through side.
    private VarDeclaration[size_t] classArrayFieldPointerVariables;
    private size_t[size_t] classArrayFieldPointerFieldIndices;

    // Set by `writeThroughClassArrayFieldPointer` for the receiver variable it
    // wrote into, the class-receiver sibling of
    // `structArrayFieldPointerWritebacks`: a cross-frame write (the receiver
    // is the CALLER's own local, absent from the callee's own `locals`)
    // cannot refresh the caller's boxed mirror immediately, so this flags
    // `variable` for `writeBackClassArrayFieldPointerTargets` to re-derive
    // from the (shared-bytes) `classCells` entry once control returns to the
    // frame that actually owns `variable`.
    private bool[VarDeclaration] classArrayFieldPointerWritebacks;

    private VarDeclaration[size_t] localPointers;
    private size_t[VarDeclaration] localPointerIds;
    private size_t nextLocalPointerId;
    private FuncDeclaration[size_t] functionPointers;
    private size_t[FuncDeclaration] functionPointerIds;
    private size_t nextFunctionPointerId;
    private size_t nextClassObjectId;
    private RuntimeDelegate[size_t] delegates;
    private imported!"quickbite.backends.interpreter.ffi_marshal".
        InterpreterInboundTrampolineSession* durableInboundSession;
    private Expression[VarDeclaration] lazyArgumentExpressions;
    private Value[VarDeclaration][VarDeclaration] lazyArgumentLocals;
    // The caller's own `_activationFrame` at the moment its `lazy` argument
    // was bound, captured alongside `lazyArgumentLocals` so `runLazyArgument`
    // can swap `_activationFrame` to it too -- see the comment there.
    private FrameBlock[VarDeclaration] lazyArgumentFrames;
    // The caller's own `mirrorEstablished`/`classMirrorGenerations`
    // FIELDS (not their values) at the moment the `lazy` argument was bound,
    // captured alongside `lazyArgumentLocals`/`lazyArgumentFrames` so
    // `runLazyArgument` can swap the mirror bookkeeping to the caller's own
    // storage for the duration of the thunk too -- see that function's own
    // comment for why a `setLocal` inside the thunk needs this in addition
    // to `locals`/`_activationFrame`. Captured as a POINTER to the field,
    // never the AA value itself: an empty `bool[VarDeclaration]`/
    // `size_t[size_t][VarDeclaration]` is `null`, so copying the VALUE at
    // bind time would not alias the caller's map -- a first write during the
    // thunk would silently allocate a fresh table on the callee's own copy
    // instead of the caller's real field, leaving the caller's own map
    // exactly as stale as before. `runLazyArgument` swaps through the
    // pointer at both ends (read the caller's current value in, write
    // whatever the thunk produced -- new table or not -- back out), so this
    // is correct whether or not the caller's map was already non-null when
    // the lazy argument was bound.
    private bool[VarDeclaration]*[VarDeclaration] lazyArgumentMirrorEstablished;
    private size_t[size_t][VarDeclaration]*[VarDeclaration]
        lazyArgumentClassMirrorGenerations;
    private bool[VarDeclaration] uninitializedLocals;
    private SliceAlias[VarDeclaration] sliceAliases;
    private ArrayElementAlias[VarDeclaration] arrayElementAliases;
    private StructFieldAlias[VarDeclaration] structFieldAliases;
    private AssocArraySlotAlias[VarDeclaration] assocArraySlotAliases;
    private StructArrayFieldAliases[VarDeclaration] structArrayFieldAliases;
    private size_t[VarDeclaration] arrayAllocations;
    private size_t[VarDeclaration] arrayAllocationAliases;
    private VarDeclaration[size_t] arrayAllocationVariables;
    // Allocation-base storage carried by an evaluated array allocation
    // identity, independent of whichever source variable first minted that
    // identity. Every Value offset for an id is relative to this one base;
    // never replace it with an interior, view-relative cell from another
    // frame. A source slot may be rebound (correctly invalidating its
    // forward/reverse maps) while a derived slice or cast view carrying the
    // old id remains live.
    private NativeArray[size_t] arrayAllocationCarriers;
    private bool[VarDeclaration] arrayPointerWritebacks;
    // Allocation-id memo keyed by the storage root and its field path.
    // Direct and one-level-nested struct and class fields share this
    // representation; extending a supported receiver shape adds indices to
    // the path rather than another parallel map family. Every id minted
    // through this path is also recorded
    // in `fieldSnapshotAllocationIds` so `writeLocation`'s `PtrExp` path can
    // refuse writing through it.
    private size_t[FieldPathKey] fieldPathAddressAllocations;
    private bool[size_t] fieldSnapshotAllocationIds;
    private size_t allocationCount;
    private Value result;
    private bool runningCalledFunction;
    private bool inUnitTest;
    private FuncDeclaration currentFunction;

    // Per-activation native storage block; authority still lives in
    // `locals`/cells until reads route through it.
    private FrameBlock _activationFrame;

    // The object-lifetime storage backing the verified frame mirror for
    // class locals (`mirrorToFrame`'s class arm, `mirrorClassToFrame`,
    // below): one `object_table.ObjectTable`, allocated once by whichever
    // entry point (`Interpreter.eval`/`executeUnitTest`/
    // `evalFormattedDisplay`) constructs the ROOT `Walker` for one call
    // into this backend, and shared -- by pointer, not by value -- into
    // every forked child (`forkPerFrameCellsInto`) for that call's whole
    // execution.
    //
    // Deliberately NOT `classObjectCells`'s own dup-then-merge shape.
    // `classObjectCells` is also identity-keyed, and a `NativeBlock[
    // size_t]` dup is a safe way to fork it (dup copies each `NativeBlock`
    // handle, which stays the same stable address -- `NativeBlock`'s own
    // contract), but a dup still needs the accompanying merge-back loop
    // (`mergePerFrameCellsFrom`) for a body a CHILD allocates to become
    // visible to the PARENT and any later sibling fork; two sibling
    // frames forked from the same parent before a merge would otherwise
    // each allocate their OWN body for the same identity. A single shared
    // pointer needs neither the dup nor the merge: there is only ever one
    // `ObjectTable` instance for the whole execution, so a body any frame
    // allocates is immediately visible through every other frame's copy
    // of this same pointer, with no copy-then-reconcile window where a
    // frame that has not yet merged back could see a stale (or a second,
    // divergent) answer.
    //
    // This only works because the field is allocated exactly ONCE, at
    // root-`Walker` construction, and never lazily on first use: forking
    // a still-null field and letting each side allocate its own instance
    // the first time it is needed would silently reintroduce the very
    // hazard sharing-by-pointer avoids, one level up -- two sibling
    // frames, each minting their own table before either one has
    // allocated anything, would stop agreeing on a shared identity's body
    // address the moment either one allocates first.
    private ObjectTable* classObjectTable;

    // The identity-to-address capability `place_value.writeClassBody` needs
    // to write a class-typed FIELD's own reference (an object graph, not
    // only a single object -- `writeClassBody`'s own header comment) --
    // `classObjectTable.storageFor` itself, bound to this `Walker`'s own
    // table. `writeClassBody` takes this as an explicit delegate parameter
    // rather than importing `impl.d` or `object_table.d` itself, so
    // `place_value.d` stays pure composition parameterized by a
    // caller-supplied policy (the same shape `lvalue_place.placeOfLvalue`'s
    // `resolveBase`/`evalIndex` already use); `&resolveObjectBody` is that
    // delegate, shared by `mirrorClassToFrame` and `assertClassFrameMirror`
    // below so neither can resolve an identity differently from the other.
    private void* resolveObjectBody(
        size_t identity,
        imported!"dmd.dclass".ClassDeclaration class_,
    ) @safe {
        return classObjectTable.storageFor(identity, class_);
    }

    // The module-lifetime storage backing the verified frame mirror for
    // module-level guest state (`VarDeclaration.isDataseg`: module-level,
    // `__gshared`, or `static`) -- `mirrorToFrame`'s dataseg routing below,
    // via `mirrorAddress`/`mirrorPlace`. A dataseg local owns no
    // per-activation frame slot at all (`frame_layout.isAliasingLocal`
    // excludes it from `computeFrameLayout` on purpose: it "lives in the
    // module table instead of any one activation's frame"), so its mirror
    // needs storage that outlives every activation and is shared by every
    // frame that touches it -- exactly `classObjectTable`'s own shape and
    // shared-by-pointer-not-by-value lifetime (see that field's own
    // comment for why a dup-then-merge shape is wrong for an identity-
    // keyed table): allocated exactly ONCE, by whichever entry point
    // constructs the ROOT `Walker` for one call into this backend, and
    // shared -- by pointer -- into every forked child
    // (`forkPerFrameCellsInto`) for that call's whole execution, so two
    // sibling frames that both touch the SAME module variable always
    // resolve to the SAME block instead of each lazily allocating (and
    // disagreeing about) their own.
    private ModuleTable* moduleTable;

    private Value thisValue;
    private bool hasThis;
    private Value pendingFinallyBodyException;
    private bool hasPendingFinallyBodyException;

    private StructArrayFieldAliases thisStructArrayFieldAliases;
    private bool returned;
    private bool addressOfRefReturn;
    private bool assignToRefReturn;
    private Value refReturnAssignedValue;
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
            const savedResult = result;
            const savedLoopControl = loopControl;
            const savedLoopControlLabel = loopControlLabel;
            returned = false;
            loopControl = LoopControl.none;
            loopControlLabel = null;
            const savedPendingFinallyBodyException = pendingFinallyBodyException;
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
                if (returned)
                    result = savedResult;
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
            result = runExpression(expression.exp);
            return;
        }

        if (auto dtor = statement.isDtorExpStatement) {
            result = runExpression(dtor.exp);
            return;
        }

        if (auto return_ = statement.isReturnStatement) {
            if (return_.exp !is null) {
                if (assignToRefReturn)
                    writeLocation(return_.exp, refReturnAssignedValue);
                else
                    result = addressOfRefReturn
                        ? refReturnAddress(return_.exp)
                        : runExpression(return_.exp);
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
            if (isTruthy(runExpression(if_.condition)))
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
        in Value object,
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
        in Value object,
    ) {
        if (catch_.type is null)
            return true;

        auto classType = catch_.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return false;

        return object.classHasType(className(classType.sym));
    }

    // Single write path for a local's boxed value; native-storage mirroring
    // and the authority switch hook here.
    private void setLocal(VarDeclaration variable, Value value) {
        locals[variable] = value;
        mirrorToFrame(variable, value);
    }

    // Keeps `variable`'s mirror storage in sync with its just-written boxed
    // value, so that storage can serve as a verified shadow of the boxed
    // local -- for every place-composable local (`place_value.
    // isPlaceComposable`: a native scalar, a struct or composable union, a
    // static array of composable elements, or a pointer), not only scalars.
    // The mirror storage itself is this activation's own frame slot for a
    // true stack local, or -- because module-level guest state
    // (`VarDeclaration.isDataseg`: module-level, `__gshared`, or `static`)
    // owns no per-activation frame slot at all (`frame_layout.
    // isAliasingLocal`) -- its own block in `moduleTable` (`mirrorPlace`
    // below resolves which). Authority stays with `locals`: this never
    // fails a write it cannot perform cleanly, it simply skips it -- a
    // local with no mirror slot at all (aliasing `ref`/`out`/`lazy`), a
    // type `place_value` does not compose, or a value that does not itself
    // match `place_value.valueMatchesPlace` (e.g. still `void`, a
    // struct/array local mid-construction holding a transient boxed value
    // of the wrong shape,
    // or -- a pointer's own value-dependent case, see `valueMatchesPlace`'s
    // pointer arm -- a boxed-era pointer carrier with no host address of
    // its own) is left unmirrored rather than risking `writeValue`
    // throwing; a later matching write re-syncs it.
    //
    // Never reached for a dataseg variable bound to an extern host address
    // (`ffi.md` §35.2's `isExternDataSymbol`): that variable never enters
    // `locals` in the first place -- `writeLocation`'s `VarExp` arm writes
    // straight through `ffi.resolveDataSymbol`'s resolved address and
    // returns before ever calling `writeCelledLocal`/`setLocal`, and the
    // read path reifies from that same native symbol on every read rather
    // than caching into `locals` -- so `setLocal`, this function's only
    // caller, is simply never invoked for one.
    //
    // A composable union local writes through `place_value.writeValue`'s
    // union arm exactly like every other arm here, and needs no extra
    // gating of its own even though that arm writes only ONE (the widest)
    // member's bytes: `place_value.isPlaceComposable`'s union arm
    // (`isComposableUnion`) already declines every union that single write
    // cannot stand in for, and this function calls it before `writeValue`
    // just as `assertFrameMirror` does. That gate is where the union
    // question is settled, deliberately NOT in the byte assertion below --
    // `assertFrameMirror` recomputes its expected bytes through this SAME
    // `writeValue` on this SAME `value`, so a union whose entries
    // contradict each other produces the identical wrong bytes on both
    // sides and passes the assertion while still being wrong. A divergence
    // both sides compute the same way is invisible to a byte comparison;
    // only declining the shape catches it.
    private void mirrorToFrame(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.place_value: valueMatchesPlace, writeValue;

        // `established` becomes `mirrorEstablished[variable]` on every exit
        // from this function (`scope(exit)` below) -- `false` unless an arm
        // actually wrote real storage, so every decline, this function's own
        // and its arms' alike, records itself as "not established" the same
        // way a fresh, never-written frame slot already reads. See
        // `mirrorEstablished`'s own field comment for what reads it.
        bool established = false;
        scope(exit) mirrorEstablished[variable] = established;

        if (!hasMirrorSlot(variable))
            return;

        if (variable.type.toBasetype.isTypeDArray !is null) {
            established = mirrorSliceToFrame(variable, value);
            return;
        }

        if (variable.type.toBasetype.isTypeClass !is null) {
            established = mirrorClassToFrame(variable, value);
            return;
        }

        if (!valueMatchesPlace(variable.type, value))
            return;

        writeValue(mirrorPlace(variable), value);
        established = true;
    }

    // Whether `variable` has mirror storage to write/verify at all: this
    // activation's own OWNING frame slot for a true stack local
    // (`FrameBlock.hasOwningSlot`), or -- unconditionally -- a
    // `moduleTable` block for a dataseg variable, since `ModuleTable.
    // storageFor` allocates one lazily on first use rather than requiring
    // one to already exist. An aliasing local (`ref`/`out`/`lazy`/
    // manifest -- `frame_layout.isAliasingLocal`'s other case) has neither
    // and answers `false`, matching `_activationFrame.hasOwningSlot`'s own
    // verdict for it today. Gated on `hasOwningSlot`, not `hasSlot`: a
    // `ref`/`out` parameter now owns a REFERENCE slot (`frame_layout`'s
    // `FrameLayout.Slot.Kind.reference`) holding the caller-supplied
    // address it binds to, not a `place_value` composition of its own
    // declared type -- the verified mirror below must never treat that
    // slot's raw bytes as if they were inline storage of that type. A
    // `ref`/`out` parameter's own bind-time verification is
    // `bindReferenceSlot`/`assertReferenceBind` below instead, which never
    // calls this function.
    private bool hasMirrorSlot(VarDeclaration variable) {
        return variable.isDataseg || _activationFrame.hasOwningSlot(variable);
    }

    // The mirror storage address for `variable`: this activation's own
    // frame slot for a true stack local, or `moduleTable`'s own
    // module-lifetime block for a dataseg variable -- the address
    // `mirrorPlace` below pairs with `variable`'s own declared type, and
    // that `mirrorSliceToFrame`/`mirrorClassToFrame` (and their
    // `assertFrameMirror` siblings) use directly for a slice header or a
    // class reference, which are not `place_value`-composed values of
    // their own declared type the way `mirrorPlace` composes for. Callers
    // are expected to have already checked `hasMirrorSlot`.
    private void* mirrorAddress(VarDeclaration variable) {
        return variable.isDataseg
            ? moduleTable.storageFor(variable)
            : _activationFrame.bindingAddress(variable);
    }

    // The mirror `Place` for a place-composable local's own storage --
    // `mirrorAddress` above paired with `variable`'s own declared type,
    // the dataseg-aware sibling of `place.placeAt`'s `FrameBlock` overload.
    // `mirrorToFrame` and `assertFrameMirror` both call this identically,
    // so the write and verify sides can never target different storage
    // for the same variable.
    private Place mirrorPlace(VarDeclaration variable) {
        import quickbite.backends.interpreter.layout: declaredType;

        return Place(mirrorAddress(variable), declaredType(variable));
    }

    // The slice sibling of `mirrorToFrame`'s place-composed write above: a
    // slice is not `place_value.isPlaceComposable` (its elements live behind
    // a stored pointer, not inline in the mirror slot), so the slot instead
    // mirrors the native `{ length, ptr }` header `place.Place.index`
    // already reads through for a slice place -- built here the same way
    // `NativeArray.borrow`/`writeSliceHeader` build and write one anywhere
    // else in this file (see `classSliceField`), through the raw-address
    // overload (`mirrorAddress`) so the identical call covers both a frame
    // slot and a `moduleTable` block. Authority stays with
    // `locals`, exactly as `mirrorToFrame` documents: this never writes a
    // header it cannot vouch for, it simply skips --
    //
    // - a local already promoted to `arrayCells` (a slice local can get its
    //   own cell, `promoteSliceArrayCell`): that cell, not the boxed `value`
    //   here, is the authority for it, matching `assertFrameMirror`'s own
    //   identical exclusion.
    // - a boxed value that is not (yet) `isArray` (still `void`, or mid-
    //   construction), matching `valueMatchesPlace`'s equivalent guard for
    //   the composable shapes above.
    // - a non-empty slice whose `arrayNativeAddress` is `null`: a boxed
    //   `Value[]` tree assembled with no backing native block (e.g. a slice
    //   of a plain array literal never promoted to a cell) has no single
    //   stable element pointer to mirror. Only length 0 is safe to mirror
    //   with a `null` pointer -- an empty slice's header is legitimately
    //   `{ 0, null }` either way.
    //
    // Never throws otherwise: `NativeArray.writeSliceHeader`'s own two
    // checks (bounds, scanned destination) can never fail here -- the
    // destination is this slot's own block, sized to exactly
    // `NativeArray.sliceHeaderByteLength` bytes by `layout.typeByteSize` for
    // a slice type (the `(void[]).sizeof` header, no more), and a frame
    // slot or `moduleTable` block for any slice-typed variable already
    // scans conservatively (`frame_block.frameHasPointers`/`module_table.
    // allocateBlock`, both via `layout.typeHasPointers`, true for every
    // `Type.isTypeDArray`).
    //
    // Returns whether it actually wrote a header, for `mirrorToFrame`'s own
    // `mirrorEstablished` record (that field's own comment).
    private bool mirrorSliceToFrame(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.native_array: NativeArray;

        if (variable in arrayCells)
            return false;

        if (!AggregateValue.isArray(value))
            return false;

        const nativeAddress = AggregateValue.nativeArrayAddress(value);
        if (nativeAddress is null && AggregateValue.elementCount(value) != 0)
            return false;

        auto arrayType = variable.type.toBasetype.isTypeDArray;
        auto array = NativeArray.borrow(
            arrayType.next, cast(void*) nativeAddress, AggregateValue.elementCount(value));

        array.writeSliceHeader(mirrorAddress(variable));
        return true;
    }

    // The class sibling of `mirrorSliceToFrame`'s header write above: a
    // class local's frame slot holds a real reference (address) into an
    // object body owned by `classObjectTable`, whose fields mirror the
    // boxed class value field-by-field the same way a struct's frame slot
    // mirrors a struct's own fields -- decision 15's "a class variable
    // holds a reference to an object body owned by object identity"
    // (`ai/plans/value.md`) made concrete for the frame. Authority stays
    // with `locals`, exactly as every other `mirrorToFrame` arm: this
    // never writes a reference (or a body) it cannot vouch for, it simply
    // skips --
    //
    // - a boxed value that is not (yet) `isClassObject`, and not `Value.
    //   null_` either (still `void`) -- the same "not yet this shape" gap
    //   `valueMatchesPlace` guards for the composable shapes above.
    // - a `classIdentity` of 0: `place_value.readValue`'s own class arm
    //   never mints one for a null reference (it reads back `Value.
    //   null_` instead, handled separately below), so an `isClassObject`
    //   value with identity 0 has no `ObjectTable` key to resolve.
    // - a class whose own fields are not `place_value.
    //   isClassBodyComposable` (a slice field, ... -- see its own header):
    //   `writeClassBody` would throw recursing into that field, so this
    //   declines up front rather than letting the write raise
    //   mid-composition. A class-typed field no longer disqualifies a body
    //   by itself (`isClassBodyComposable`'s own header) -- an object
    //   GRAPH, not only a single object, is now eligible.
    // - a class that IS `isClassBodyComposable` (a TYPE-shape question)
    //   but whose current field VALUES do not themselves match
    //   (`classBodyShapeMatches`, the class-body counterpart of
    //   `valueMatchesPlace` above) -- the case a pointer field adds now
    //   that `place_value.isPlaceComposable` accepts a pointer type:
    //   `isClassBodyComposable` says the field's TYPE composes, but
    //   `writeClassBody`'s recursive `writeValue` still refuses a boxed
    //   pointer carrier with no host address (`isLocalPointer`, ...),
    //   exactly the VALUE-dependent case `valueMatchesPlace`'s own pointer
    //   arm exists to catch. Without this second check, a class with an
    //   `int*` field pointing at a local (a routine, valid program) would
    //   throw here instead of leaving the local unmirrored.
    //   `classBodyShapeMatches` now also carries a class-typed field's own
    //   VALUE-level check -- an unresolvable identity (0, or not actually
    //   an `isClassObject`), or a live cycle (`class Node { Node next; }`
    //   with `a.next.next is a`) -- declining a cyclic graph HERE, before
    //   `writeClassBody` is ever reached, is what keeps this decline and
    //   `assertClassFrameMirror`'s own identical decline symmetric: neither
    //   side ever calls `writeClassBody`'s own cycle-throwing recursion in
    //   the first place (see `writeClassBody`'s own header comment on why
    //   IT still carries a cycle guard despite this).
    //   `classBodyShapeMatches` also declines whenever `variable`'s own
    //   identity is currently boxed by ANOTHER live variable
    //   (`classIdentityAliasedByAnotherBinding`, its own header comment) --
    //   the pre-existing boxed-authority gap where a write through one
    //   alias never refreshes another alias's own `locals[]` copy of the
    //   same identity (`ai/plans/value.md`'s Cell coherence "Known gaps").
    //
    // `Value.null_` DOES mirror, unlike the declines above: a null
    // reference is cheap and verifiable -- a plain `null` pointer written
    // into the slot, no `ObjectTable` lookup and nothing to compose --
    // exactly the "no live object" case `readValue`'s own class arm
    // already special-cases the identical way.
    //
    // Never throws otherwise: a class-typed slot's frame (or `moduleTable`
    // block, for a dataseg class variable) always scans conservatively
    // (`frame_block.frameHasPointers`/`module_table.allocateBlock`, both
    // via `layout.typeHasPointers`, true for any `Type.isTypeClass`, the
    // same fact `mirrorSliceToFrame`'s own header comment leans on for its
    // slice slot), so the reference this writes always lands in a
    // destination the GC can see.
    //
    // Returns whether it actually wrote real storage, which its caller
    // (`mirrorToFrame`) records as `mirrorEstablished[variable]` -- `false`
    // for every decline below, so a decline records itself the same way a
    // fresh, never-written frame slot already reads. See
    // `mirrorEstablished`'s own field comment for why that record exists
    // and what reads it: nothing re-derives this decision at READ time.
    private bool mirrorClassToFrame(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.place_value:
            isClassBodyComposable, writeClassBody;

        auto classType = variable.type.toBasetype.isTypeClass;

        if (value == Value.null_) {
            Place(mirrorAddress(variable), classType).storeReference(null);
            return true;
        }

        if (!AggregateValue.isClass(value))
            return false;

        const identity = AggregateValue.classIdentity(value);
        if (identity == 0)
            return false;

        if (!isClassBodyComposable(classType.sym))
            return false;

        if (!classBodyShapeMatches(variable, classType.sym, value))
            return false;

        // Not `const`: `Place`'s constructor and `storeReference` both
        // take a mutable `void*`.
        auto bodyAddress = classObjectTable.storageFor(identity, classType.sym);
        writeClassBody(Place(bodyAddress, classType), value, &resolveObjectBody);
        Place(mirrorAddress(variable), classType).storeReference(bodyAddress);
        classMirrorGenerations[variable] = null;
        recordClassMirrorGenerations(variable, classType.sym, value, identity);
        return true;
    }

    // Populates `classMirrorGenerations[variable]` with `classObjectTable.
    // generation(identity)` for `identity` and every nested class-typed
    // field's own identity, transitively -- the identical graph
    // `classBodyShapeMatches`/`writeClassBody` already proved acyclic and
    // just composed, walked again here (cheaply: no allocation, no
    // resolution, just a map read per identity) because recording a
    // generation snapshot needs `value`'s own field values, which this
    // function's caller (`mirrorClassToFrame`) already has but `writeClassBody`
    // itself does not hand back. `classMirrorGenerations[variable]`'s own
    // field comment carries the full rationale for why this snapshot exists
    // and how `assertClassBodyValue` consumes it. Guards against re-walking
    // a DAG's shared identity twice (`identity in classMirrorGenerations[variable]`)
    // the same way `classBodyShapeMatchesImpl`'s own `visiting` set does for
    // a live cycle -- the graph is already proven acyclic by the time this
    // runs, so this is only ever a DAG-sharing short-circuit, never a cycle
    // guard of its own.
    private void recordClassMirrorGenerations(
        VarDeclaration variable,
        imported!"dmd.dclass".ClassDeclaration class_,
        in Value value,
        size_t identity,
    ) {
        import quickbite.backends.interpreter.layout: classFields, declaredType;

        classMirrorGenerations[variable][identity] = classObjectTable.generation(identity);

        foreach (index, field; classFields(class_)) {
            auto fieldClassType = declaredType(field).isTypeClass;
            if (fieldClassType is null)
                continue;

            auto fieldValue = AggregateValue.classFieldAt(value, index);
            if (fieldValue == Value.null_)
                continue;

            const nestedIdentity = AggregateValue.classIdentity(fieldValue);
            if (nestedIdentity in classMirrorGenerations[variable])
                continue;

            recordClassMirrorGenerations(
                variable, fieldClassType.sym, fieldValue, nestedIdentity);
        }
    }

    // The class-body counterpart of `place_value.valueMatchesPlace`, for
    // exactly the reason a pointer field needs one: `place_value.
    // isClassBodyComposable` only answers whether `class_`'s own field
    // TYPES compose (recursing `isPlaceComposable`, a type-shape
    // question), the same way `isPlaceComposable` itself gates the
    // generic composable path above -- it was never a VALUE check, and
    // never needed to be one before a pointer field could exist in a
    // composable class body. Now that it can, a field's declared type
    // composing is not enough: `writeClassBody`'s recursive `writeValue`
    // still refuses a pointer field whose current VALUE is a boxed-era
    // carrier with no host address, exactly like `writeValue`'s own
    // top-level pointer arm. Checking every field's value against its own
    // declared type through `valueMatchesPlace` (recursing into a nested
    // struct/array/pointer field exactly as it already does for the
    // generic composable path) catches that case -- and every other
    // "value does not yet match this field's shape" case a struct/array/
    // enum field could already have, on the same terms the generic path
    // already checks for a non-class local. `mirrorClassToFrame` and
    // `assertClassFrameMirror` both call this identically, right after
    // their own `isClassBodyComposable` check, so the two stay symmetric
    // the same way `valueMatchesPlace` itself keeps the generic path
    // symmetric: neither side can compose a field value the other
    // declined.
    //
    // A class-typed field is a second exception, for the identical reason a
    // pointer field is: `isClassBodyComposable` now answers `true` for one
    // unconditionally (a TYPE-shape question, its own header comment), but
    // `writeClassBody` can still refuse the VALUE -- an unresolvable
    // identity, or a live cycle (`class Node { Node next; }` with
    // `a.next.next is a`). `classBodyShapeMatchesImpl` below carries that
    // check, recursing into the referenced object's own fields exactly as
    // `writeClassBody` itself would, so this stays the single PURE gate
    // both `mirrorClassToFrame` and `assertClassFrameMirror` call before
    // either ever reaches `writeClassBody` -- a cycle declines HERE,
    // deterministically, rather than by throwing out of `writeClassBody`'s
    // own recursion (this codebase avoids exceptions for control flow; see
    // AGENTS.md). Not `static` any more: the promoted-cell check below
    // needs `this.classObjectCells`.
    //
    // `variable` adds the TOP-level counterpart of the nested "identity in
    // classObjectCells" decline `classBodyShapeMatchesImpl` already makes
    // for a class-typed FIELD: `classIdentityAliasedByAnotherBinding` below
    // catches the shape that decline cannot, because it is a decline about
    // `variable` ITSELF, not about one of its fields (own header comment).
    //
    // `visiting` is seeded with `value`'s OWN identity here, before the
    // recursion ever starts -- `classBodyShapeMatchesImpl` on its own only
    // ever adds a FIELD's identity to `visiting` as it descends into that
    // field, so a root whose own identity reappears exactly one field down
    // (`n.next = n`) was never checked against anything: the boxed `Value`
    // a field holds is a SNAPSHOT taken at assignment time, not a live
    // view, so `n.next`'s own `next` field reads back `null` (it was still
    // unset when `n.next = n` captured `n`'s state) -- the boxed tree
    // itself is already acyclic and terminates on its own, even though the
    // identity it repeats is the very one `writeClassBody` will re-resolve
    // to the SAME real address a second time. Seeding the root here is
    // what makes that repeat visible to THIS gate too, exactly the "check
    // the current identity" `writeClassBodyImpl` already does on entry,
    // keyed by `bodyPlace.address` instead of a boxed identity -- the two
    // guards agree once both start from the object being written, not only
    // from the fields underneath it.
    //
    // `value.classTypeName != classQualifiedName(class_)` is a fourth
    // decline, closing a real silent GC-heap corruption: `object_table.
    // ObjectTable.storageFor` sizes an identity's body block from
    // whichever caller's `class_` argument reaches it FIRST, and its own
    // header comment says why that is safe
    // -- "an object's runtime class is fixed at construction" -- but that
    // premise is about the OBJECT, not about the `class_` argument every
    // caller here happens to pass, which is `variable`'s (or a field's)
    // own STATIC type, not the object's DYNAMIC one. `Base b = new
    // Derived(); auto d = cast(Derived) b;` boxes the SAME identity
    // through two DIFFERENT static types; whichever mirrors first wins
    // the size for every later caller, so a `Base`-typed mirror running
    // first allocates a `Base`-sized block, and a later `Derived`-typed
    // mirror for the SAME identity gets that same too-small block back
    // unchanged -- `writeClassBody` then writes `Derived`'s wider field
    // layout through it with no bounds check of its own (`place.Place`
    // has none), silently scribbling past the allocation.
    //
    // The fix declines here rather than resolving the object's actual
    // dynamic `ClassDeclaration` to size against: `value`'s only dynamic
    // information is `classTypeName`, a NAME (`quickbite.backends.interpreter.runtime_value.Value`
    // carries no `ClassDeclaration` -- it is DMD-free by design), and the
    // walker's own name-to-declaration resolvers
    // (`classDeclarationByQualifiedName` and friends) search by lexical
    // scope or across every analysed module, which is not the same
    // guarantee as "the exact symbol DMD bound this expression's runtime
    // type to" -- a name collision (two same-named classes in different
    // modules) could resolve to the WRONG declaration and silently
    // undersize or missize a body again. Comparing the name we already
    // trust (`classQualifiedName(class_)`, the identical derivation
    // `readClassValue`/`classDefaultValue` used to produce this very
    // `value.classTypeName` in the first place) against `class_` itself
    // costs only mirror coverage for a polymorphic binding -- a
    // `Base`-typed local holding a `Derived` object never mirrors while
    // seen through `Base`, exactly the same trade
    // `classIdentityAliasedByAnotherBinding` above already makes:
    // declining too often is always the cheaper mistake. Once every
    // static type that ever reaches `storageFor` for a given identity has
    // been proven to equal that identity's own dynamic class (the ONLY
    // way this check can pass), every later call for that identity
    // requests the identical size, so the object-lifetime premise
    // `storageFor`'s own header comment states is true again.
    private bool classBodyShapeMatches(
        VarDeclaration variable,
        imported!"dmd.dclass".ClassDeclaration class_,
        in Value value,
    ) {
        import quickbite.backends.interpreter.layout: classQualifiedName;

        if (classIdentityAliasedByAnotherBinding(
            variable, AggregateValue.classIdentity(value)))
            return false;

        if (AggregateValue.classTypeName(value) != classQualifiedName(class_))
            return false;

        bool[size_t] visiting = [AggregateValue.classIdentity(value): true];
        return classBodyShapeMatchesImpl(class_, value, visiting);
    }

    // The top-level sibling of `classBodyShapeMatchesImpl`'s own nested
    // `identity in classObjectCells` decline: that check catches a
    // class-typed FIELD whose identity some OTHER alias has independently
    // promoted to a cell, but a plain top-level class LOCAL aliased through
    // a non-`VarExp` source (`auto aliasLeaf = mid.leaf;` -- a `DotVarExp`,
    // not the bare `VarExp` `registerClassAliasIfPlainVar` requires) never
    // gets a cell at all, so `classObjectCells` stays empty for it. The
    // fault this guards is the same known, pre-existing boxed-authority gap
    // either way (`ai/plans/value.md`'s Cell coherence "Known gaps" list): a
    // deep field-chain write reached through ONE binding (`mid.leaf.value =
    // ...`) refreshes the shared identity-keyed object body
    // (`classObjectTable`) but never touches another binding's own
    // per-variable `locals[]` copy of the same identity, so that other
    // binding's boxed value silently goes stale.
    //
    // Scanning `locals` for another live variable currently boxing the
    // identical identity is the cheapest signal actually available for
    // this shape -- there is no cell, promoted or otherwise, to consult.
    // It is also a coarse, over-eager one: it declines a SHARED identity
    // outright, whether or not a stale write has actually happened yet, and
    // whether or not the other binding will ever be mutated through. That
    // is the intended trade, not an approximation to tighten later: an
    // unmirrored/unverified local costs nothing today, since `locals[]`
    // remains what every read actually returns regardless of whether the
    // mirror or its assert ever run -- while the failure mode this
    // prevents is an internal `AssertError` (`assertClassBodyValue`/
    // `assertClassReferenceMirror`'s own asserts) turning a pre-existing
    // WRONG ANSWER into a crashed interpreter on a program that used to run
    // at all. Declining too often is always the cheaper mistake here.
    private bool classIdentityAliasedByAnotherBinding(
        VarDeclaration variable,
        size_t identity,
    ) {
        foreach (other, otherValue; locals) {
            if (other is variable)
                continue;

            if (
                AggregateValue.isClass(otherValue)
                    && AggregateValue.classIdentity(otherValue) == identity
            )
                return true;
        }

        return false;
    }

    // `classBodyShapeMatches`'s own recursion, threading `visiting` -- the
    // set of object identities seen ANYWHERE in this graph, a deliberately
    // stricter set than the DFS "currently in progress" one
    // `place_value.readClassValue`/`writeClassBodyImpl` each carry on their
    // own side (see their header comments, and the next paragraph for what
    // this one additionally refuses and why), kept here instead of there
    // because this is a VALUE-only check (no address to resolve or write),
    // so it can decline a cycle without ever calling `writeClassBody` at
    // all. Keyed by `Value.classIdentity`, not an address: this function
    // never resolves one (unlike `place_value`'s own guards), it only walks
    // the boxed VALUE tree, exactly as `valueMatchesPlace` already does for
    // every other shape.
    //
    // `visiting` is a "seen ANYWHERE in this graph" set, not the DFS
    // in-progress set its name suggests: an identity is added and never
    // removed, so a shared DAG -- the same object reached twice from one
    // composed value, whether through sibling fields, cousins, or a
    // grandchild -- declines exactly like a cycle. Sibling sharing used to
    // be allowed on the grounds that `writeClassBody` handles "two fields,
    // one address" fine; it does, but the BOXED value does not. `locals[]`
    // caches one snapshot per REFERENCE, so `parent.left.x = 5` on a
    // `Parent { Child left; Child right; }` whose two fields hold one child
    // refreshes `left`'s snapshot and leaves `right`'s stale (the
    // pre-existing boxed-authority gap `value.md`'s Cell coherence "Known
    // gaps" already records). The write then composes that one shared body
    // once per sibling and the LAST snapshot wins, while the generation
    // snapshot records that final generation for BOTH, so the verify walks
    // in and compares the FIRST sibling's snapshot against bytes written
    // from the second -- an `AssertError` on a program `SystemLinker` runs
    // fine. No byte comparison can catch that: both sides would compose the
    // same contradictory value, so the shape belongs in this gate rather
    // than in the assert. Declining costs only mirror coverage of storage
    // nothing reads yet, and this deliberately over-declines: it refuses
    // every repeated identity, whether or not the snapshots have actually
    // diverged yet, exactly as `classIdentityAliasedByAnotherBinding` does
    // one level up (its own header comment on why declining too often is
    // always the cheaper mistake here).
    //
    // A nested identity present in `classObjectCells` is a THIRD decline
    // condition, and the one closing a real gap found empirically (a
    // `Parent { Child child; }` object whose `child` was independently
    // address-taken -- `&someAlias.x` on a SEPARATE local sharing that
    // identity -- then written through that pointer): `locals[]` caches
    // one boxed copy of an object graph PER VARIABLE that references it,
    // and a write through a promoted CELL for one alias's identity is
    // never propagated into every OTHER variable's own cached copy of the
    // same nested field (a real, pre-existing boxed-authority limit --
    // `ai/plans/value.md`'s Cell coherence contract already names the
    // general shape: "Class-typed fields ... have no cell support on
    // either the read or write side"). `assertFrameMirror`'s OWN
    // caller-level guard already skips this exact staleness for a
    // DIRECTLY promoted variable (`variable in classCells`, checked before
    // `assertClassFrameMirror` is ever reached); a class-typed FIELD has
    // no variable of its own to gate on, so this repeats that same
    // protection one level down, keyed by the shared identity instead of a
    // binding. Declining here — before `writeClassBody` ever touches this
    // object's body — is what keeps `mirrorClassToFrame`'s write and
    // `assertClassFrameMirror`'s verify agreeing: once ANY alias's cell
    // might hold this identity's true current bytes, this mirror stops
    // tracking it at all, exactly as it already does for a promoted local.
    private bool classBodyShapeMatchesImpl(
        imported!"dmd.dclass".ClassDeclaration class_,
        in Value value,
        bool[size_t] visiting,
    ) {
        import quickbite.backends.interpreter.layout:
            classFields, declaredType, classQualifiedName;
        import quickbite.backends.interpreter.place_value:
            isClassBodyComposable, valueMatchesPlace;

        foreach (index, field; classFields(class_)) {
            auto fieldType = declaredType(field);
            auto fieldValue = AggregateValue.classFieldAt(value, index);

            auto fieldClassType = fieldType.isTypeClass;
            if (fieldClassType is null) {
                if (!valueMatchesPlace(fieldType, fieldValue))
                    return false;
                continue;
            }

            if (fieldValue == Value.null_)
                continue;

            if (!AggregateValue.isClass(fieldValue))
                return false;

            // The nested-field counterpart of `classBodyShapeMatches`'s own
            // static/dynamic decline above (its header comment carries the
            // full rationale): a class-typed FIELD whose declared type is
            // narrower than the object it currently references would reach
            // `resolveObjectBody`/`storageFor` with the SAME
            // too-narrow-`class_` hazard the root check exists to close.
            if (AggregateValue.classTypeName(fieldValue)
                != classQualifiedName(fieldClassType.sym))
                return false;

            const identity = AggregateValue.classIdentity(fieldValue);
            if (identity == 0 || (identity in visiting) || (identity in classObjectCells))
                return false;

            if (!isClassBodyComposable(fieldClassType.sym))
                return false;

            visiting[identity] = true;

            if (!classBodyShapeMatchesImpl(fieldClassType.sym, fieldValue, visiting))
                return false;
        }

        return true;
    }

    // Asserts that `variable`'s mirror storage still agrees with the boxed
    // `value` about to be returned for it -- makes any gap between the
    // mirror `setLocal` maintains and the boxed authority show up
    // deterministically instead of silently drifting. Skips a local whose
    // cell (not the mirror) is authoritative for this shape -- a scalar
    // promoted to `scalarCells`, a struct to `structCells`, an array to
    // `arrayCells`, or a class to `classCells` -- one with no mirror slot at
    // all, a type `place_value` does not compose, or a boxed value that does
    // not itself match that type's own shape, matching `mirrorToFrame`'s own
    // guards exactly so this never asserts on a local the mirror never
    // covered. Compares raw bytes rather than `Value == Value`: the
    // mirror's contract is byte equality, not boxed-representation
    // equality, and the two diverge for values `Value`'s own `==` does
    // not treat as equal to themselves or to an equivalent
    // reading -- IEEE NaN, and an enum's `EnumValue` boxing against the plain
    // integral `readScalar` returns for its base type.
    private void assertFrameMirror(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.place_value: valueMatchesPlace, writeValue;
        import quickbite.backends.interpreter.place: placeAt;
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        if (
            variable in scalarCells || variable in structCells
                || variable in arrayCells || variable in classCells
        )
            return;

        if (!hasMirrorSlot(variable))
            return;

        if (variable.type.toBasetype.isTypeDArray !is null) {
            assertFrameSliceMirror(variable, value);
            return;
        }

        if (variable.type.toBasetype.isTypeClass !is null) {
            assertClassFrameMirror(variable, value);
            return;
        }

        if (!valueMatchesPlace(variable.type, value))
            return;

        // The expected bytes: `value` written through the identical
        // `place_value.writeValue` composition into a scratch block of the
        // local's own byte size, rather than a second, hand-rolled encoding
        // -- the only way the two can ever disagree is a real divergence
        // between what `setLocal` mirrored earlier and `value` now.
        //
        // Scan policy comes from `layout.typeHasPointers` over `variable.
        // type` itself, never a hardcoded `no` -- the Containers contract
        // (`value.md`) takes no default for exactly this reason: under-
        // scanning is the unsafe direction, so a forgotten argument must
        // never silently choose it. This is not merely future-proofing:
        // `isPlaceComposable` accepts a pointer type as a leaf and a
        // pointer-bearing struct/union/array through it (`allFieldsComposable`
        // recursing per field), so `variable.type` reaching here can
        // genuinely carry a live host address today -- `writeValue` has
        // just written one into this very scratch a few lines below,
        // whenever `value` itself is a native pointer.
        const length = typeByteSize(variable.type);
        const scan = typeHasPointers(variable.type)
            ? NativeBlock.Scan.conservative : NativeBlock.Scan.no;
        auto scratch = NativeBlock.allocate(length, scan);
        writeValue(placeAt(scratch, variable.type), value);

        assert(
            frameBytesAt(mirrorAddress(variable), length) == scratch.bytes,
            "frame mirror diverged from boxed local",
        );
    }

    // The slice sibling of `assertFrameMirror`'s place-composed comparison
    // above, matching `mirrorSliceToFrame`'s own header write in shape and
    // guards -- a slice's frame slot holds a native `{ length, ptr }`
    // header, not `place_value`-composed bytes, so its expected bytes are a
    // freshly written header rather than a `writeValue` composition. The
    // caller (`assertFrameMirror`) has already excluded a local promoted to
    // `arrayCells`, so this only ever runs for a slice local `
    // mirrorSliceToFrame` itself would (or would decline to) mirror; the
    // remaining guards below -- not yet `isArray`, or a non-empty slice with
    // no stable `arrayNativeAddress` -- match `mirrorSliceToFrame`'s
    // identical ones exactly, so this never asserts on a local the mirror
    // never covered in the first place.
    private void assertFrameSliceMirror(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.native_array: NativeArray;

        if (!AggregateValue.isArray(value))
            return;

        const nativeAddress = AggregateValue.nativeArrayAddress(value);
        if (nativeAddress is null && AggregateValue.elementCount(value) != 0)
            return;

        auto arrayType = variable.type.toBasetype.isTypeDArray;
        auto array = NativeArray.borrow(
            arrayType.next, cast(void*) nativeAddress, AggregateValue.elementCount(value));

        // `Scan.conservative`, unconditionally, rather than reusing the
        // composable path's `Scan.no` scratch above: unlike a composable
        // value's scratch (which `writeValue` never writes a live GC pointer
        // into), `writeSliceHeader` itself refuses to write a GC-visible
        // block address into an unscanned destination -- see its own
        // comment. A conservatively scanned scratch is always an accepted
        // destination for it, whether or not this particular `nativeAddress`
        // happens to be GC-visible.
        auto scratch = NativeBlock.allocate(
            NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
        array.writeSliceHeader(scratch, 0);

        assert(
            frameBytesAt(mirrorAddress(variable), NativeArray.sliceHeaderByteLength)
                == scratch.bytes,
            "frame slice mirror diverged from boxed local",
        );
    }

    // The class sibling of `assertFrameSliceMirror`'s comparison above,
    // matching `mirrorClassToFrame`'s own guards exactly so this never
    // asserts on a local the mirror never covered -- the caller
    // (`assertFrameMirror`) has already excluded a local promoted to
    // `classCells`. A class local's mirror has two independently
    // verifiable parts, so both are checked: the frame slot's own stored
    // reference (`assertClassReferenceMirror`, the same raw-byte
    // comparison `assertFrameSliceMirror` performs for a slice header),
    // and -- only once that reference resolves to a real object, not
    // `Value.null_` -- the object body's own fields at that reference,
    // verified by `assertClassBodyValue` below (own header comment for why
    // that is a dedicated recursive function rather than a call to
    // `place_value.writeClassBody` the way `mirrorClassToFrame` makes).
    private void assertClassFrameMirror(VarDeclaration variable, in Value value) {
        if (!mirrorEstablished.get(variable, false))
            return;

        auto classType = variable.type.toBasetype.isTypeClass;

        if (value == Value.null_) {
            assertClassReferenceMirror(variable, classType, null);
            return;
        }

        const identity = AggregateValue.classIdentity(value);

        // `mirrorEstablished[variable]` is only ever set `true` right
        // after a real write (`mirrorClassToFrame`'s own header comment),
        // and `value` here is bit-identical to the value that write ran
        // with (`setLocal` is the sole writer of `locals`, and always calls
        // `mirrorToFrame` with the SAME value immediately afterwards -- see
        // `mirrorEstablished`'s own field comment), so `identity`
        // cannot be 0 and `classObjectTable.has(identity)` cannot be
        // `false` here in practice: that write already resolved this exact
        // identity through `storageFor`. Checked anyway, as a read-only
        // decline rather than an unguarded `opIndex` -- a verify step must
        // never risk a crash of its own (`RangeError` on a missing key) to
        // save one `has` call.
        if (!classObjectTable.has(identity))
            return;

        auto bodyAddress = (*classObjectTable)[identity].address;
        assertClassReferenceMirror(variable, classType, bodyAddress);
        assertClassBodyValue(
            classType, value, identity, classMirrorGenerations.get(variable, null));
    }

    // Recursively verifies `value`'s composed bytes against the REAL object
    // body `classObjectTable` already holds for `identity`, at every depth
    // an object graph can reach -- the class counterpart of
    // `assertFrameMirror`'s own `writeValue`-into-scratch comparison for a
    // single composable local, generalized past one object.
    //
    // Deliberately NOT a call to `place_value.writeClassBody` the way
    // `mirrorClassToFrame` makes: `writeClassBody`'s resolver, for a
    // class-typed field, hands back the REAL nested object's address and
    // then WRITES into it -- correct for `mirrorClassToFrame` (it is
    // supposed to mutate real storage), wrong for an assertion, which must
    // not mutate the very body it is comparing against. So a class-typed
    // field here reads the nested object's own stable address straight out
    // of `classObjectTable` (`has`/`opIndex`, never `storageFor` --see
    // their own use below for why this never allocates), stores that
    // reference into THIS level's scratch, and recurses into ANOTHER
    // scratch-vs-real comparison one level down, rather than composing
    // into the real nested body at all.
    //
    // No cycle guard of its own: `mirrorEstablished`
    // (`assertClassFrameMirror`'s own gate, checked before this is ever
    // reached) guarantees the WRITE side already ran `classBodyShapeMatches`
    // over this identical value and found it acyclic, before `writeClassBody`
    // composed it -- a cycle reaching here would mean the two disagree, an
    // invariant this function trusts rather than re-checks, the same way
    // `writeClassBody` trusts its own callers once `classBodyShapeMatches`
    // has run.
    //
    // `recordedGenerations` is `classMirrorGenerations[variable]` from the
    // caller (`assertClassFrameMirror`), threaded down unchanged through
    // every recursive call: the snapshot `object_table.ObjectTable.
    // generation` took, per identity, right after `mirrorClassToFrame`'s own
    // write composed this whole graph. Before touching `identity`'s real
    // bytes at all, this checks that snapshot against the identity's CURRENT
    // generation -- a mismatch means some OTHER `storageFor` call (another
    // binding's mirror write reaching this SAME shared identity, in this
    // frame or a completely different activation -- `classMirrorGenerations`'
    // own field comment) has rewritten this body since, so `value`'s cached
    // copy of it is no longer what the real bytes hold. Skipping the
    // assertion (and the recursion into this identity's own fields, since a
    // rewritten body's field values are no longer described by `value`
    // either) is the fix: comparing bytes the write side never actually
    // vouched for is exactly the false-crash shape three fixtures found
    // (`class.sharedNestedBodyRewrittenBySiblingBindingDoesNotCrash` and its
    // two siblings, `classMirrorGenerations`'s own field comment).
    private void assertClassBodyValue(
        imported!"dmd.mtype".TypeClass classType,
        in Value value,
        in size_t identity,
        in size_t[size_t] recordedGenerations,
    ) {
        import quickbite.backends.interpreter.layout: classFields, classInstanceByteSize;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        const recordedGeneration = recordedGenerations.get(identity, size_t.max);
        if (classObjectTable.generation(identity) != recordedGeneration)
            return;

        // Scanned conservatively, unconditionally -- not derived from
        // `layout.typeHasPointers` over any one field, the same choice
        // `object_table.allocateBlock` makes for the real body this
        // scratch mirrors, and for the identical reason: every class
        // instance begins with a vtable pointer (and monitor field) at
        // offset 0 regardless of its own declared fields' types, so there
        // is no non-pointer-carrying shape for a class body to check for.
        // A pointer- or class-typed field also writes a genuine host
        // address into this scratch's own field region -- a real,
        // present-day reason to scan, not merely future-proofing.
        const length = classInstanceByteSize(classType.sym);
        auto scratch = NativeBlock.allocate(length, NativeBlock.Scan.conservative);
        auto scratchPlace = Place(scratch.address, classType);

        foreach (index, field; classFields(classType.sym)) {
            auto fieldPlace = scratchPlace.field(field);
            auto fieldValue = AggregateValue.classFieldAt(value, index);
            auto fieldClassType = fieldPlace.type.isTypeClass;

            if (fieldClassType is null) {
                writeValue(fieldPlace, fieldValue);
                continue;
            }

            if (fieldValue == Value.null_) {
                fieldPlace.storeReference(null);
                continue;
            }

            const nestedIdentity = AggregateValue.classIdentity(fieldValue);

            // The verify-time counterpart of `classBodyShapeMatchesImpl`'s
            // own identical nested decline (its own header comment): a
            // nested field's identity can be promoted into
            // `classObjectCells` -- and mutated through that SEPARATE,
            // `classObjectTable`-independent storage, by a pointer write
            // through a completely different alias -- strictly AFTER the
            // owning variable's own mirror last established successfully
            // (`mirrorEstablished` freezes THAT decision at write
            // time; it says nothing about a DIFFERENT alias's later
            // action on a field this variable never itself rewrote).
            // Unlike `classIdentityAliasedByAnotherBinding`
            // (`mirrorEstablished`'s own header comment explains why
            // THAT one must stay pinned to write time), `identity in
            // classObjectCells` is MONOTONIC: `classObjectCells` entries
            // are never removed (only the per-variable `classCells` cache
            // is, on rebind -- see its own field comment), so re-deriving
            // this ONE condition here can only ADD a decline over what
            // the write saw, never turn a genuine divergence into a false
            // "match" -- safe to check fresh, and necessary to: found via
            // `class.fieldObjectCopiedToLocalSharesAuthoritativeStorage`,
            // whose own `&child.x` promotes exactly this identity, then
            // writes through it, well after `parent`'s own mirror last
            // established.
            if (nestedIdentity in classObjectCells)
                return;

            // `has`/`opIndex`, never `storageFor`: a verify step must
            // never allocate into the shared object table (`storageFor`'s
            // own comment: an unrecognised identity there sizes and
            // inserts a fresh block). Once the decline above does not
            // apply, this nested identity is always already present --
            // `mirrorClassToFrame`'s own successful write (the one that
            // set `mirrorEstablished[variable]`, this whole call
            // chain's precondition -- see `assertClassFrameMirror`) ran
            // `writeClassBody` over this SAME `value`, which resolves
            // (and so allocates) every reachable nested identity via
            // `resolveObjectBody`/`storageFor` before this function is
            // ever called. `has` is still checked, not assumed: declining
            // silently on a violated precondition is cheaper than an
            // `opIndex` `RangeError` crashing the very thing this mirror
            // must never be the reason for.
            if (!classObjectTable.has(nestedIdentity))
                return;

            auto nestedAddress = (*classObjectTable)[nestedIdentity].address;
            fieldPlace.storeReference(nestedAddress);
            assertClassBodyValue(
                fieldClassType, fieldValue, nestedIdentity, recordedGenerations);
        }

        // `classObjectTable[identity]` (not the frame) is the actual body
        // -- `(*classObjectTable)` because the shared table is reached
        // through a pointer (see its own field comment). No all-zero skip
        // here (contrast the pre-`mirrorEstablished` history of this
        // function): `assertClassFrameMirror`'s own `mirrorEstablished`
        // check already guarantees this exact `value`'s own
        // `mirrorClassToFrame` write ran `writeClassBody` over this same
        // body, so `actual` genuinely reflects that write, not a
        // never-touched GC-zeroed block -- comparing it for real is the
        // whole point.
        assert(
            (*classObjectTable)[identity].bytes == scratch.bytes,
            "class body mirror diverged from boxed local",
        );
    }

    // The frame-slot reference comparison both `assertClassFrameMirror`
    // arms above share: `expected` (a body's own address, or `null`)
    // written through the identical `place.Place.storeReference`
    // `mirrorClassToFrame` itself writes with, into a pointer-width
    // scratch block, rather than a second, hand-rolled encoding.
    //
    // Scanned conservatively, unconditionally: unlike the two scratches
    // above, this one is not merely shaped like it could someday hold a
    // pointer -- `expected` genuinely IS a live `ObjectTable`-owned
    // address whenever `value` is a non-null class object, in the
    // caller's very next line. Other roots also keep that body alive
    // right now (the real frame slot `mirrorClassToFrame` already wrote,
    // and `classObjectTable`'s own map), so nothing is actually freed by
    // an unscanned scratch today -- but the Containers contract picks
    // scan policy from what the block holds, not from a "something else
    // probably roots it too" argument, since that is exactly the kind of
    // reasoning a forgotten argument skips.
    private void assertClassReferenceMirror(
        VarDeclaration variable,
        imported!"dmd.mtype".TypeClass classType,
        void* expected,
    ) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        auto scratch = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
        Place(scratch.address, classType).storeReference(expected);

        const actual = frameBytesAt(mirrorAddress(variable), (void*).sizeof);

        // No all-zero skip here (contrast the pre-`mirrorEstablished`
        // history of this function, when this ran off a RE-DERIVED
        // decision that could disagree with what `mirrorClassToFrame`
        // actually did): `assertClassFrameMirror`'s own
        // `mirrorEstablished` check already guarantees `variable`'s
        // OWN last write genuinely stored a reference into this exact
        // slot -- for this exact `value` -- so a real divergence is the
        // only way `actual` can now disagree with `scratch`.
        assert(
            actual == scratch.bytes,
            "frame class reference mirror diverged from boxed local",
        );
    }

    // Reinterprets `length` bytes at `address` as a byte slice, for the
    // raw comparison `assertFrameMirror` needs -- pointer arithmetic on a
    // raw address is not `@safe`; this is the `@trusted` boundary, mirroring
    // `place.d`'s own `placeBytes`. `address` is always a frame slot's own
    // address and `length` its own `layout.typeByteSize`, so the returned
    // slice spans exactly that slot's bytes.
    private static ubyte[] frameBytesAt(void* address, in size_t length) pure nothrow @trusted {
        return (cast(ubyte*) address)[0 .. length];
    }

    private void bindCatchVariable(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (catch_.var is null)
            return;

        setLocal(catch_.var, nativeExceptionCatchObject(catch_, object));
        uninitializedLocals.remove(catch_.var);
    }

    private void throwInterpretedException(
        imported!"dmd.expression".Expression expression,
    ) {
        auto object = runExpression(expression);
        if (!AggregateValue.isClass(object))
            throw new Exception("Unsupported throw expression.");
        if (hasPendingFinallyBodyException)
            throw new InterpretedException(chainExceptionObject(
                pendingFinallyBodyException,
                object,
            ));

        throw new InterpretedException(object);
    }

    private void throwNativeException(
        imported!"quickbite.ffi".NativeCallException exception,
    ) {
        rootNativeException(exception);
        throw new InterpretedException(nativeExceptionObject(exception));
    }

    private void rootNativeException(
        imported!"quickbite.ffi".NativeCallException exception,
    ) {
        if (exception.nativeThrowableObjectPointer !is null)
            nativeThrowableRoots[exception.nativeThrowableObjectPointer] =
                exception.nativeThrowable;

        if (exception.chainedNext !is null)
            rootNativeException(exception.chainedNext);
    }

    // Rebuild the captured native exception chain as linked interpreted
    // exception objects, threading each `.next` through _nextInChainPtr
    // (ffi.md §34.13).
    private Value nativeExceptionObject(
        imported!"quickbite.ffi".NativeCallException exception,
    ) {
        auto object = nativeExceptionBaseObject(
            exception.msg,
            exception.className,
            exception.nativeThrowableObjectPointer,
        );
        if (exception.chainedNext !is null)
            object = AggregateValue.withClassFieldNamed(
                object,
                "_nextInChainPtr",
                nativeExceptionObject(exception.chainedNext),
            );

        return object;
    }

    private Value nativeExceptionBaseObject(
        in string message,
        in string className,
        in const(void)* nativeObjectPointer = null,
    ) {
        if (auto class_ = dynamicClassDeclarationByName(className))
            return withNativeExceptionObjectPointer(
                AggregateValue.withClassFieldNamed(
                    classDefaultValue(class_),
                    "msg",
                    Value(message),
                ),
                nativeObjectPointer,
            );

        // Fully-qualified name (e.g. a native throw's `classinfo.name`) may
        // not be lexically visible from the current call frame but still be
        // known to the frontend, since druntime/Phobos modules the source
        // imports are semantically analysed by dmd-as-a-library. Reusing
        // classDefaultValue/classTypeNames here (rather than the string
        // heuristic below) gives the real base-class chain: correct
        // Error-vs-Exception classification and intermediate bases, instead
        // of `nativeExceptionRoot`'s name-prefix guess.
        if (auto class_ = classDeclarationByQualifiedName(className))
            return withNativeExceptionObjectPointer(
                AggregateValue.withClassFieldNamed(
                    classDefaultValue(class_),
                    "msg",
                    Value(message),
                ),
                nativeObjectPointer,
            );

        return nativeExceptionValue(message, className, nativeObjectPointer);
    }

    // Build a native exception object with the full Throwable field layout so
    // chain-aware field reads (`.next` resolves to _nextInChainPtr) work, while
    // keeping the thrown class's type names so a catch on a dependency subclass
    // still matches. Falls back to the message-only object if the frontend has
    // not recorded the Exception declaration.
    private Value nativeExceptionValue(
        in string message,
        in string className,
        in const(void)* nativeObjectPointer,
    ) const {
        import quickbite.backends.interpreter.runtime_values: defaultValue;
        import quickbite.backends.interpreter.layout: classFields;
        import dmd.dclass: ClassDeclaration;

        auto class_ = ClassDeclaration.exception;
        if (class_ is null)
            return withNativeExceptionObjectPointer(Value.classValue(
                className,
                nativeExceptionTypeNames(className),
                ["msg"],
                [Value(message)],
            ), nativeObjectPointer);

        string[] fieldNames;
        Value[] fields;
        foreach (field; classFields(class_)) {
            fieldNames ~= variableName(field);
            fields ~= defaultValue(field.type);
        }

        return withNativeExceptionObjectPointer(
            AggregateValue.withClassFieldNamed(
                Value.classValue(
                    className,
                    nativeExceptionTypeNames(className),
                    fieldNames,
                    fields,
                ),
                "msg",
                Value(message),
            ),
            nativeObjectPointer,
        );
    }

    private Value nativeExceptionCatchObject(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (!AggregateValue.hasClassFieldNamed(object, nativeExceptionObjectPointerField))
            return object;

        auto classType = catch_.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return object;

        return nativeExceptionObjectWithClassFields(classType.sym, object);
    }

    private Value nativeExceptionObjectWithClassFields(
        imported!"dmd.dclass".ClassDeclaration class_,
        in Value object,
    ) {
        import quickbite.backends.interpreter.layout: classFields;

        if (!AggregateValue.hasClassFieldNamed(object, nativeExceptionObjectPointerField))
            return object;

        const pointer = AggregateValue.classFieldNamed(
            object,
            nativeExceptionObjectPointerField,
        ).asNativePointer;
        string[] fieldNames;
        Value[] fields;
        foreach (field; classFields(class_)) {
            const name = variableName(field);
            fieldNames ~= name;
            fields ~= isSyntheticNativeExceptionField(name) &&
                AggregateValue.hasClassFieldNamed(object, name)
                ? AggregateValue.classFieldNamed(object, name)
                : nativeClassFieldValue(field, pointer);
        }

        return withNativeExceptionObjectPointer(Value.classValue(
            AggregateValue.classTypeName(object),
            AggregateValue.classTypeNames(object),
            fieldNames,
            fields,
        ), pointer);
    }

    // Delete this once class/object storage is fully native-layout backed.
    // Until then, it only keeps the boxed native-exception shim from reading
    // interpreter-owned exception metadata as if it were native object
    // storage.
    private bool isSyntheticNativeExceptionField(in string name)
        @safe @nogc nothrow pure const
    {
        return name == "msg" || name == "_nextInChainPtr";
    }

    private Value nativeClassFieldValue(
        imported!"dmd.declaration".VarDeclaration field,
        const(void)* objectPointer,
    ) {
        import quickbite.backends.interpreter.ffi_marshal: unmarshalNative;
        import quickbite.backends.interpreter.layout: fieldByteOffset;

        return unmarshalNative(
            field.type.toBasetype,
            cast(void*) (cast(ubyte*) objectPointer + fieldByteOffset(field)),
        );
    }

    private Value withNativeExceptionObjectPointer(
        in Value object,
        in const(void)* nativeObjectPointer,
    ) const {
        if (nativeObjectPointer is null)
            return object;

        if (AggregateValue.hasClassFieldNamed(object, nativeExceptionObjectPointerField))
            return AggregateValue.withClassFieldNamed(
                object,
                nativeExceptionObjectPointerField,
                Value.nativePointerValue(cast(void*) nativeObjectPointer),
            );

        return AggregateValue.withAppendedClassField(
            object,
            nativeExceptionObjectPointerField,
            Value.nativePointerValue(cast(void*) nativeObjectPointer),
        );
    }

    private Value chainExceptionObject(in Value thrown, in Value next) const {
        if (!AggregateValue.isClass(thrown) ||
            !AggregateValue.hasClassFieldNamed(thrown, "_nextInChainPtr"))
            return thrown;

        return AggregateValue.withClassFieldNamed(thrown, "_nextInChainPtr", next);
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

    private Value applyThrowableConstructor(
        in Value object,
        in Value[] arguments,
    ) const {
        if (!AggregateValue.isClass(object) || arguments.length == 0)
            return object;

        auto result = AggregateValue.withClassFieldNamed(object, "msg", arguments[0]);
        if (
            arguments.length >= 4 &&
            AggregateValue.isClass(arguments[3]) &&
            AggregateValue.hasClassFieldNamed(result, "_nextInChainPtr")
        )
            result = AggregateValue.withClassFieldNamed(
                result,
                "_nextInChainPtr",
                arguments[3],
            );

        return result;
    }

    private Value runThisConstructorCall(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments,
    ) {
        if (!hasThis)
            throw new Exception("Unsupported eval call.");

        if (AggregateValue.isClass(thisValue) && isThrowableConstructor(function_)) {
            thisValue = applyThrowableConstructor(thisValue, arguments);
            return thisValue;
        }

        // A delegating constructor (`this(...)` forwarding to another
        // constructor, as std.stdio.File's string constructor does): run the
        // target constructor on the current receiver and adopt the
        // constructed value.
        if (function_.isConstructorFunction) {
            thisValue = runMemberFunction(
                function_,
                null,
                thisValue,
                arguments,
                argumentExpressions,
                evaluatedArguments,
            );
            return thisValue;
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

    // For `with(expr)` where expr is a struct lvalue, DMD semantic creates a
    // `wthis` pointer-to-struct temporary and rewrites field accesses in the
    // body to go through `*wthis`.  We seed locals with a pointer value wrapping
    // the struct, run the body (mutations flow through writeLocation's PtrExp
    // arm back into locals[wthis]), then write the final value back to the
    // original expression.  For `with(EnumType)`, wthis is null; DMD resolves
    // enum member references in the body at semantic time, so running the body
    // as-is suffices.
    private void runWithStatement(
        imported!"dmd.statement".WithStatement with_,
    ) {
        if (with_.wthis !is null) {
            const structValue = runExpression(with_.exp);
            setLocal(with_.wthis, Value.pointerValue(structValue));
            runStatement(with_._body);
            if (auto updated = with_.wthis in locals)
                writeLocation(
                    with_.exp,
                    updated.isLocalPointer
                        ? localPointerTarget(*updated)
                        : updated.pointerTarget,
                );
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
            const condition = runExpression(switch_.condition);
            foreach (case_; *switch_.cases) {
                if (case_ is null)
                    continue;
                if (caseMatches(case_, condition))
                    return case_;
            }
        }

        return switch_.sdefault;
    }

    private bool caseMatches(
        imported!"dmd.statement".CaseStatement case_,
        in Value condition,
    ) {
        if (case_.exp !is null) {
            const candidate = runExpression(case_.exp);
            if (candidate.isIntegerCompatibleScalar &&
                condition.isIntegerCompatibleScalar)
                return candidate.asLong == condition.asLong;
            if (candidate == condition)
                return true;
        }

        auto range = case_.statement is null
            ? null
            : case_.statement.isCaseRangeStatement;
        if (range is null)
            return false;

        const value = condition.asLong;
        return
            value >= runExpression(range.first).asLong &&
            value <= runExpression(range.last).asLong;
    }

    private void runForStatement(
        imported!"dmd.statement".ForStatement for_,
        in string label = null,
    ) {
        runStatement(for_._init);

        while (
            !returned &&
            loopControl == LoopControl.none &&
            (for_.condition is null || isTruthy(runExpression(for_.condition)))
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
                runExpression(for_.increment);
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
        } while (isTruthy(runExpression(do_.condition)));
    }

    private void clearLoopControl() {
        loopControl = LoopControl.none;
        loopControlLabel = null;
    }

    private Value runExpression(imported!"dmd.expression".Expression expression) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.runtime_values: integerValue, realValue;

        if (auto integer = expression.isIntegerExp) {
            if (integer.type !is null && integer.type.ty == TY.Tenum)
                return Value.enumValue(
                    expressionChars(integer),
                    cast(long) integer.getInteger,
                );
            return integerValue(integer);
        }

        if (auto real_ = expression.isRealExp)
            return realValue(real_);

        if (auto null_ = expression.isNullExp) {
            import dmd.astenums: TY;

            // A `null` literal typed as a dynamic array is a null array, whose
            // `.length` is 0 and which renders as `[]` — the same
            // representation as a default-initialised array field
            // (`defaultValue`).  `new S` of a struct with an array field passes
            // this literal as the field's initialiser.
            if (null_.type !is null && null_.type.toBasetype.ty == TY.Tarray)
                return AggregateValue.reconstructArray([]);

            return Value.null_;
        }

        if (auto string_ = expression.isStringExp) {
            import quickbite.backends.interpreter.runtime_string_literals: stringValue;

            return stringValue(string_);
        }

        if (auto array = expression.isArrayLiteralExp)
            return arrayValue(array);

        if (auto assocArray = expression.isAssocArrayLiteralExp)
            return assocArrayValue(assocArray);

        if (auto struct_ = expression.isStructLiteralExp)
            return structLiteralValue(struct_);

        if (auto assert_ = expression.isAssertExp) {
            import quickbite.backends.interpreter.messages:
                assertFailureMessage;

            if (!isTruthy(runExpression(assert_.e1)))
                throw new Exception(
                    assertFailureMessage(assert_, runningCalledFunction, inUnitTest, &runExpression),
                );
            return Value(true);
        }

        if (auto not = expression.isNotExp) {
            return Value(!isTruthy(runExpression(not.e1)));
        }

        if (auto logical = expression.isLogicalExp) {
            if (logical.op == EXP.andAnd)
                return runLogicalAndExpression(logical);
            if (logical.op == EXP.orOr)
                return runLogicalOrExpression(logical);
        }

        if (auto cast_ = expression.isCastExp) {
            log("cast expression: ", cast_);
            return castValue(cast_);
        }

        if (auto equal = expression.isEqualExp)
            return runEqualExpression(equal);

        if (auto identity = expression.isIdentityExp)
            return runIdentityExpression(identity);

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

        if (auto conditional = expression.isCondExp)
            return runConditionalExpression(conditional);

        if (auto throw_ = expression.isThrowExp) {
            throwInterpretedException(throw_.e1);
            return Value.void_;
        }

        if (auto post = expression.isPostExp)
            return runPostIncrementExpression(post);

        if (auto addAssign = expression.isAddAssignExp)
            return runAddAssignExpression(addAssign);

        if (auto add = expression.isAddExp)
            return runAddExpression(add);

        if (auto sub = expression.isMinExp)
            return runMinExpression(sub);

        if (auto mul = expression.isMulExp)
            return runExpression(mul.e1) * runExpression(mul.e2);

        if (auto div = expression.isDivExp)
            return runDivExpression(div);

        if (auto mod = expression.isModExp)
            return runModExpression(mod);

        if (auto leftShift = expression.isShlExp)
            return runIntegerBinaryExpression(leftShift, "<<");

        if (auto rightShift = expression.isShrExp)
            return runIntegerBinaryExpression(rightShift, ">>");

        if (auto unsignedRightShift = expression.isUshrExp)
            return runIntegerBinaryExpression(unsignedRightShift, ">>>");

        if (auto neg = expression.isNegExp)
            return -runExpression(neg.e1);

        if (auto complement = expression.isComExp)
            return runIntegerComplementExpression(complement);

        if (auto pow = expression.isPowExp)
            return runPowExpression(pow);

        if (auto cat = expression.isCatExp)
            return runConcatenateExpression(cat);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

        if (auto lowered = expression.isLoweredAssignExp)
            return runLoweredAssignExpression(lowered);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct);

        if (auto blit = expression.isBlitExp)
            return runAssignExpression(blit);

        if (expression.op == EXP.concatenateAssign) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "concatenateAssign expression was not a BinExp");

            return runArrayConcatenateAssignExpression(assign);
        }

        if (expression.op == EXP.concatenateElemAssign) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "concatenateElemAssign expression was not a BinExp");

            return runArrayAppendAssignExpression(assign);
        }

        if (expression.op == EXP.concatenateDcharAssign) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "concatenateDcharAssign expression was not a BinExp");

            return runArrayAppendAssignExpression(assign);
        }

        if (isScalarCompoundAssignExpression(expression)) {
            auto assign = cast(imported!"dmd.expression".BinExp) expression;
            if (assign is null)
                assert(0, "compound assignment expression was not a BinExp");

            return runCompoundAssignExpression(assign);
        }

        if (auto bitOr = expression.isOrExp)
            return runIntegerBinaryExpression(bitOr, "|");

        if (auto bitAnd = expression.isAndExp)
            return runIntegerBinaryExpression(bitAnd, "&");

        if (auto bitXor = expression.isXorExp)
            return runIntegerBinaryExpression(bitXor, "^");

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1);
            return runExpression(comma.e2);
        }

        if (auto tuple = expression.isTupleExp)
            return runTupleExpression(tuple);

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto call = expression.isCallExp)
            return runCallExpression(call);

        if (auto delegate_ = expression.isDelegateExp)
            return runDelegateExpression(delegate_);

        if (expression.isFuncExp)
            return Value.undisplayable;

        if (auto arrayLength = expression.isArrayLengthExp)
            return Value(AggregateValue.length(runExpression(arrayLength.e1)));

        if (auto slice = expression.isSliceExp)
            return runSliceExpression(slice);

        if (auto index = expression.isIndexExp)
            return runIndexExpression(index);

        if (auto new_ = expression.isNewExp)
            return runNewExpression(new_);

        if (auto symbol = expression.isSymOffExp) {
            if (auto variable = symbol.var.isVarDeclaration)
                return symbolOffsetLocalValue(symbol, variable);
            if (auto function_ = symbol.var.isFuncDeclaration)
                return functionPointerValue(function_);
        }

        if (auto pointer = expression.isPtrExp)
            return runPointerExpression(pointer);

        if (auto address = expression.isAddrExp)
            return runAddressExpression(address);

        if (auto delegatePointer = expression.isDelegatePtrExp)
            return runDelegatePointerExpression(delegatePointer);

        if (auto delegateFunctionPointer = expression.isDelegateFuncptrExp)
            return runDelegateFunctionPointerExpression(delegateFunctionPointer);

        if (auto dotIdentifier = expression.isDotIdExp)
            return runDotIdentifierExpression(dotIdentifier);

        if (auto dot = expression.isDotVarExp)
            return runDotVarExpression(dot);

        if (auto vector = expression.isVectorExp)
            return runVectorExpression(vector);

        if (auto vectorArray = expression.isVectorArrayExp)
            return runExpression(vectorArray.e1);

        if (expression.isThisExp !is null) {
            if (!hasThis)
                throw new Exception("Unsupported eval expression: this");
            return thisValue;
        }

        if (expression.isSuperExp !is null) {
            if (!hasThis)
                throw new Exception("Unsupported eval expression: super");
            return thisValue;
        }

        if (auto typeid_ = expression.isTypeidExp)
            return runTypeidExpression(typeid_);

        if (auto identifier = expression.isIdentifierExp) {
            const name = identifier.ident is null
                ? ""
                : identifier.ident.toString.idup;

            // DMD-generated exception support can leave the magic __ctfe flag
            // as an identifier instead of lowering it to a VarExp.
            if (name == "__ctfe")
                return Value(true);

            if (
                hasThis &&
                thisValue.isClassObject &&
                thisValue.hasClassFieldNamed(name)
            )
                return thisValue.classFieldNamed(name);
        }

        if (auto var = expression.isVarExp) {
            import dmd.id: Id;

            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                return runSymbolDeclarationVarExpression(var);

            // Mutable because frame/layout APIs take DMD declarations.
            auto referenceVariable = variable;
            variable = refLocalStorageVariable(variable);

            // the magic __ctfe variable is true under AST interpretation,
            // matching dmd's own interpreter; the language requires both
            // __ctfe branches to be observably equivalent
            if (variable.ident is Id.ctfe)
                return Value(true);

            if (variable in uninitializedLocals) {
                import quickbite.backends.interpreter.messages: uninitializedVariableMessage;
                import quickbite.frontend.dmd.types: isStaticArrayType, isStructType;

                // DMD's void diagnostic is field-granular: reading a whole
                // void-initialized aggregate (as `S res = void; return res;`
                // does) materialises a default value; only a still-void scalar
                // read is reported. Match that so patterns like Phobos
                // `trustedVoidInit` evaluate up to any real libc call.
                if (isStructType(variable.type) || isStaticArrayType(variable.type))
                    return defaultValue(variable);

                throw new Exception(uninitializedVariableMessage(variable, currentFunction));
            }

            // A filled reference slot is the caller's scalar storage. Read
            // it before the legacy parameter-cell fallback so `ref`/`out`
            // mutation is immediately visible across the call boundary.
            import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
            if (
                referenceVariable.isReference &&
                _activationFrame.hasReferenceSlot(referenceVariable) &&
                _activationFrame.bindingAddress(referenceVariable) !is null &&
                isNativeScalarType(referenceVariable.type)
            ) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;
                import quickbite.backends.interpreter.layout: declaredType;

                return readValue(Place(
                    _activationFrame.bindingAddress(referenceVariable),
                    declaredType(referenceVariable),
                ));
            }

            // Byte-level authority: once `&variable` has
            // promoted a cell, its bytes -- not the boxed mirror below --
            // are the true value, so a reinterpret write through a pointer
            // (`writeLocation`'s `PtrExp` arm) is visible here.
            if (auto cell = variable in scalarCells) {
                import quickbite.backends.interpreter.native_scalar: readScalar;

                return readScalar(variable.type, cell.bytes);
            }

            if (auto cell = variable in arrayCells)
                if (auto current = variable in locals)
                    if (current.isArray)
                        return arrayValueFromCell(*current, *cell);

            // A class cell is likewise authoritative for a whole-value read,
            // not only for field access and pointer writeback. Reconstructing
            // here ensures return values and onward arguments cannot carry a
            // stale boxed snapshot after an aliased field mutation.
            if (auto cell = variable in classCells) {
                auto current = variable in locals;
                auto classType = variable.type.toBasetype.isTypeClass;
                if (
                    current !is null && current.isClassObject &&
                    classType !is null && classType.sym !is null
                )
                    return classValueFromCell(*current, *cell, classType.sym);
            }

            if (auto cell = variable in structCells)
                if (auto current = variable in locals)
                    if (current.isStruct)
                        return structValueFromCell(*current, *cell);

            if (auto current = variable in locals) {
                // The frame is already the complete native representation
                // for an ordinary scalar binding.  Once its owning slot has
                // been established, read it back instead of treating the
                // boxed local as storage.  Promoted cells remain above until
                // the combined authority switch removes their lifecycle.
                import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
                import quickbite.backends.interpreter.place_value: readValue;

                if (
                    hasMirrorSlot(variable) &&
                    mirrorEstablished.get(variable, false) &&
                    isNativeScalarType(variable.type)
                )
                    return readValue(mirrorPlace(variable));

                assertFrameMirror(variable, *current);
                return *current;
            }

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
                    setLocal(variable, defaultValue(variable));
                    const value = storageValue(
                        variable.type,
                        runExpression(initializer.exp),
                    );
                    setLocal(variable, value);
                    return value;
                }
            }

            // An `extern __gshared` global defined in a compiled dependency
            // image: read it from its native symbol and reify through its
            // declared type (ffi.md §35.2a). A null address (symbol not loaded)
            // falls through to the default init below, keeping this strictly
            // additive so it cannot regress any extern global that isn't loaded.
            // Writes/TLS/ctor-ordering remain later §35.2 rungs.
            import quickbite.frontend.dmd.functions: isExternDataSymbol;
            if (isExternDataSymbol(variable)) {
                import quickbite.backends.interpreter.ffi_marshal: unmarshalNative;
                import quickbite.ffi: resolveDataSymbol;

                if (auto address = resolveDataSymbol(variable))
                    return unmarshalNative(variable.type.toBasetype, address);
            }

            return defaultValue(variable);
        }

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

    private Value runTupleExpression(imported!"dmd.expression".TupleExp tuple) {
        // DMD lowers a tuple assignment (`target.tupleof = source.tupleof`, or a
        // `Tuple` constructor's `field[] = values[]`) into a `TupleExp`: an
        // optional side-effect prefix `e0` followed by the per-element
        // expressions, which are ordinary assignments the interpreter already
        // evaluates. Run the prefix, then each element in order; the sequence's
        // value is its last element (matching the IR lowering), and is discarded
        // in the statement-expression positions this arises in.
        if (tuple.e0 !is null)
            runExpression(tuple.e0);

        auto result = Value.void_;  // mutated below; `const` cannot express the fold
        if (tuple.exps !is null)
            foreach (element; *tuple.exps)
                result = runExpression(element);
        return result;
    }

    private Value runSymbolDeclarationVarExpression(
        imported!"dmd.expression".VarExp var,
    ) {
        import dmd.typesem: defaultInitLiteral;

        auto symbol = var.var.isSymbolDeclaration;
        if (symbol is null)
            assert(0, "non-variable VarExp was not a SymbolDeclaration");

        auto type = symbol.dsym is null ? symbol.type : symbol.dsym.type;
        auto structType = type is null ? null : type.toBasetype.isTypeStruct;
        if (structType is null)
            assert(0, "SymbolDeclaration VarExp was not a struct initializer");

        return runExpression(structType.defaultInitLiteral(var.loc));
    }

    private Value runLogicalAndExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        const left = isTruthy(runExpression(logical.e1));
        if (!left)
            return Value(false);

        const right = isTruthy(runExpression(logical.e2));
        return Value(right);
    }

    private Value runLogicalOrExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        const left = isTruthy(runExpression(logical.e1));
        if (left)
            return Value(true);

        const right = isTruthy(runExpression(logical.e2));
        return Value(right);
    }

    private Value runComparisonExpression(
        imported!"dmd.expression".CmpExp comparison,
    ) {
        import dmd.tokens: EXP;

        const leftValue = runExpression(comparison.e1);
        const rightValue = runExpression(comparison.e2);

        if (leftValue.isPointer && rightValue.isPointer)
            return runPointerComparison(comparison.op, leftValue, rightValue);

        const left = leftValue.asReal;
        const right = rightValue.asReal;

        if (comparison.op == EXP.lessThan)
            return Value(left < right);
        if (comparison.op == EXP.lessOrEqual)
            return Value(left <= right);
        if (comparison.op == EXP.greaterThan)
            return Value(left > right);
        return Value(left >= right);
    }

    // ordered comparisons between pointers into unrelated allocations are
    // false both ways, matching CTFE
    private Value runPointerComparison(
        in imported!"dmd.tokens".EXP op,
        in Value left,
        in Value right,
    ) {
        import dmd.tokens: EXP;

        if (!left.pointerSameAllocation(right))
            return Value(false);

        const difference = left.pointerOffsetDifference(right);

        if (op == EXP.lessThan)
            return Value(difference < 0);
        if (op == EXP.lessOrEqual)
            return Value(difference <= 0);
        if (op == EXP.greaterThan)
            return Value(difference > 0);
        return Value(difference >= 0);
    }

    private Value runAddExpression(imported!"dmd.expression".AddExp add) {
        const left = runExpression(add.e1);
        const right = runExpression(add.e2);

        if (left.isPointer) {
            const offset = left.isNativePointer
                ? right.asLong
                : pointerElementOffset(add.type, right.asLong);
            return left.pointerOffsetBy(
                offset,
            );
        }

        if (right.isPointer) {
            const offset = right.isNativePointer
                ? left.asLong
                : pointerElementOffset(add.type, left.asLong);
            return right.pointerOffsetBy(
                offset,
            );
        }

        return left + right;
    }

    private Value runMinExpression(imported!"dmd.expression".MinExp sub) {
        const left = runExpression(sub.e1);
        const right = runExpression(sub.e2);

        // DMD lowers `p - q` to `(p - q) / elementSize`; return the byte
        // difference so the lowered division yields the element difference
        if (left.isPointer && right.isPointer) {
            const scale = left.isNativePointer && right.isNativePointer
                ? 1
                : pointerElementSize(sub.e1.type);
            return Value(
                left.pointerOffsetDifference(right) * scale,
            );
        }

        if (left.isPointer) {
            const offset = left.isNativePointer
                ? right.asLong
                : pointerElementOffset(sub.type, right.asLong);
            return left.pointerOffsetBy(
                -offset,
            );
        }

        return left - right;
    }

    private Value runDivExpression(DivExp div) {
        const left = runExpression(div.e1);
        const right = runExpression(div.e2);
        rejectIntMinMinusOneOverflow(left, right, "/");
        return left / right;
    }

    private Value runModExpression(ModExp mod) {
        const left = runExpression(mod.e1);
        const right = runExpression(mod.e2);
        rejectIntMinMinusOneOverflow(left, right, "%");
        return left % right;
    }

    private void rejectIntMinMinusOneOverflow(
        in Value left,
        in Value right,
        in string operator,
    ) const {
        import std.conv: text;

        if (left != Value(int.min) || right != Value(-1))
            return;

        throw new Exception(text(
            "integer overflow: `int.min ",
            operator,
            " -1`\ncannot compare `__error` at compile time",
        ));
    }

    // DMD semantic scales pointer arithmetic operands to byte offsets
    private long pointerElementOffset(
        imported!"dmd.mtype".Type pointerType,
        in long byteOffset,
    ) {
        const elementSize = pointerElementSize(pointerType);
        if (byteOffset % elementSize != 0)
            throw new Exception("Unsupported pointer arithmetic offset.");

        return byteOffset / elementSize;
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

    private Value runAddressExpression(
        imported!"dmd.expression".AddrExp address,
    ) {
        return addressOfExpression(address.e1, address.op);
    }

    private Value addressOfExpression(
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
                return localPointerValue(variable);

        if (auto delegate_ = e1.isDelegateExp)
            return runDelegateExpression(delegate_);

        // `&field` (also `field.ptr`) of a struct's static-array member: a
        // pointer to the field's first element, exactly what arrayPointer
        // builds for `&field[0]`.
        if (auto dot = e1.isDotVarExp) {
            import quickbite.frontend.dmd.types: isStaticArrayType;

            if (isStaticArrayType(dot.type))
                return arrayPointer(dot, 0, op);

            if (auto index = dot.e1.isIndexExp) {
                import quickbite.backends.interpreter.layout: fieldByteOffset;

                if (auto field = dot.var.isVarDeclaration) {
                    const elementIndex = runExpression(index.e2).asLong;
                    const elementPointer = arrayPointer(index.e1, elementIndex, op);
                    if (elementPointer.isNativePointer)
                        return elementPointer.pointerOffsetBy(
                            cast(long) fieldByteOffset(field),
                        );
                }
            }

            // Any other field type: a pointer snapshotting the field's
            // current value, mirroring runNewScalarPointerExpression's
            // single-value allocation. The id is memoized per (receiver
            // variable, field index) so re-taking the same field's address
            // returns the same identity, matching real addresses, while
            // distinct receivers (`&a.f` vs `&b.f`) still differ. It does not
            // alias WRITES THROUGH THE POINTER back to the field;
            // writeLocation's PtrExp path still refuses writing through a
            // known field-snapshot id -- unchanged by the promotion below.
            //
            // For a scalar field of a
            // plain struct LOCAL, `promoteStructFieldCell` additionally gives
            // the receiver a `structCells` entry and records this id's
            // (receiver, field index) in the reverse lookup, so a direct
            // field write after this point (`s.field = v`) becomes visible
            // through THIS pointer's deref-read
            // (`structFieldPointerCellValue`) -- closing the reverse-
            // propagation gap the array phase already closed for `&a[i]`.
            // For the nested-struct-field case, `&s.inner.x` shares the SAME
            // id above -- `fieldSnapshotAllocationId` memoizes that shape per
            // (root variable, outer field index, inner field index) -- but
            // `promoteStructFieldCell` itself no-ops for it, since its
            // receiver is not a plain `VarExp`. `promoteNestedStructFieldCell`
            // recognises the one-level-nested shape on its own and registers
            // this id in its own reverse lookup when it applies; a no-op
            // otherwise.
            // For the class case, `promoteClassFieldCell`
            // is the class sibling of `promoteStructFieldCell` -- gives the
            // receiver a `classCells` entry when `dot`'s receiver is a plain
            // class-typed local (a no-op for a struct receiver, exactly as
            // `promoteStructFieldCell` no-ops for a class receiver).
            // For nested class-struct fields (aggregate composition),
            // `promoteNestedClassStructFieldCell` is the class-receiver
            // sibling of `promoteNestedStructFieldCell` -- `&c.inner.x` where
            // `inner` is a struct field of class-typed local `c` (a no-op for
            // a struct receiver, mirroring `promoteClassFieldCell`'s own
            // no-op for that shape).
            const id = fieldSnapshotAllocationId(dot);
            promoteStructFieldCell(dot, id);
            promoteNestedStructFieldCell(dot, id);
            promoteClassFieldCell(dot, id);
            promoteNestedClassStructFieldCell(dot, id);
            // A side-effecting
            // array index (`&a[i++].inner.x`) must be evaluated exactly
            // once. `promoteArrayNestedStructFieldCell` evaluates it (to
            // seed the reverse-lookup element index) only when this exact
            // shape applies, in which case it hands back the snapshot value
            // built from that SAME evaluation; `runExpression(dot)` below
            // -- which would re-run the whole chain, including the index a
            // second time -- is the fallback for every other shape, none of
            // which touched the index above.
            Value arrayNestedValue;
            const snapshot = promoteArrayNestedStructFieldCell(dot, id, arrayNestedValue)
                ? arrayNestedValue
                : runExpression(dot);
            return Value.arrayPointerValue([snapshot], id, 0);
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

        const offset = runExpression(index.e2).asLong;
        return arrayPointer(index.e1, offset, op);
    }

    // Stable allocation id for `&s.field`, memoized per (receiver variable,
    // field index) when the receiver resolves to a plain `VarExp`. A
    // one-level-nested receiver (`&s.inner.x`/`&c.inner.x`, `dot.e1` itself a
    // `DotVarExp` whose own `e1` resolves to a plain `VarExp`) is memoized
    // too, with a two-index `FieldPathKey`. Any other receiver shape
    // (e.g. `&call().field`, or two or more levels of nesting) gets a fresh
    // id every time. Either way the id is recorded as a field snapshot so
    // writeLocation's PtrExp path can refuse writing through it.
    // A class-typed receiver's field index comes from `classFieldIndex`, not
    // `structFieldIndex`: the latter
    // resolves the receiver's type via `receiverStructType`, which returns
    // `null` for a class and previously made this function throw
    // "Unsupported interpreter field access." for every `&c.field`, before
    // any class-cell machinery could even run. `variable`'s static type
    // never changes, so dispatching once here on the receiver's own type is
    // safe -- the two field-index spaces never collide in
    // `fieldPathAddressAllocations`, whose root is that variable.
    private size_t fieldSnapshotAllocationId(
        imported!"dmd.expression".DotVarExp dot,
    ) {
        auto var = dot.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable !is null) {
            // Mutable because DMD declarations do not expose a const API.
            auto storageVariable = refLocalStorageVariable(variable);
            const fieldIndex = receiverClassType(dot.e1) !is null
                ? classFieldIndex(dot)
                : structFieldIndex(dot);
            auto key = directFieldPathKey(storageVariable, fieldIndex);
            if (auto id = key in fieldPathAddressAllocations)
                return *id;

            const id = ++allocationCount;
            fieldPathAddressAllocations[key] = id;
            fieldSnapshotAllocationIds[id] = true;
            return id;
        }

        // One-level-nested receiver (`&s.inner.x`/`&c.inner.x`): `dot.e1` is
        // itself a `DotVarExp` (`s.inner`/`c.inner`) whose own `e1` resolves
        // to a plain local. Memoized per (root variable, outer field index,
        // inner field index) in the common field-path map: repeated
        // `&s.inner.x` evaluations return the same identity, matching real
        // addresses, exactly as the direct-field case already does. Shared
        // between a struct and a class root variable (a variable's
        // static type never changes, so the two outer-field-index spaces
        // never collide).
        if (auto innerDot = dot.e1.isDotVarExp) {
            auto rootVar = innerDot.e1.isVarExp;
            auto rootVariable = rootVar is null ? null : rootVar.var.isVarDeclaration;
            if (rootVariable !is null) {
                const outerIndex = receiverClassType(innerDot.e1) !is null
                    ? classFieldIndex(innerDot)
                    : structFieldIndex(innerDot);
                const innerIndex = structFieldIndex(dot);

                auto key = fieldPathKey(rootVariable, [outerIndex, innerIndex]);
                if (auto id = key in fieldPathAddressAllocations)
                    return *id;

                const id = ++allocationCount;
                fieldPathAddressAllocations[key] = id;
                fieldSnapshotAllocationIds[id] = true;
                return id;
            }
        }

        const id = ++allocationCount;
        fieldSnapshotAllocationIds[id] = true;
        return id;
    }

    private FieldPathKey directFieldPathKey(
        VarDeclaration root,
        in size_t fieldIndex,
    ) {
        return fieldPathKey(root, [fieldIndex]);
    }

    private FieldPathKey fieldPathKey(
        VarDeclaration root,
        immutable(size_t)[] indices,
    ) {
        return FieldPathKey(root, indices);
    }

    // The address of a ref return's lvalue, evaluated in the returning
    // function's own frame (`addressOfRefReturn` mode).
    private Value refReturnAddress(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        // DMD lowers a ref-returning ternary to `return *(cond ? &a : &b())`;
        // the address of that dereference is the pointer expression itself.
        if (auto pointer = expression.isPtrExp)
            return runExpression(pointer.e1);

        return addressOfExpression(expression, EXP.address);
    }

    private Value refReturningCallAddress(
        imported!"dmd.expression".CallExp call,
        in imported!"dmd.tokens".EXP op,
    ) {
        import dmd.expression: Expression;
        import dmd.funcsem: functionSemantic3;
        import quickbite.frontend.dmd.functions: hasNoAvailableSource;
        import std.conv: text;

        const unsupported =
            text("Unsupported eval expression: ", op, " of ", call.op);

        if (call.f is null || !returnsRef(call.f))
            throw new Exception(unsupported);

        functionSemantic3(call.f);
        if (hasNoAvailableSource(call.f) || call.f.needThis)
            throw new Exception(unsupported);

        Value[] arguments;
        Expression[] argumentExpressions;
        EvaluatedReferenceArgument[] evaluatedArguments;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments ~= index < call.f.parameters.length &&
                    (*call.f.parameters)[index].isReference
                    ? runRefArgumentExpression(argument, evaluated)
                    : runExpression(argument);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
            }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = call.f;
        auto layout = cachedFrameLayout(call.f);
        child._activationFrame = FrameBlock.allocate(layout);
        child.addressOfRefReturn = true;
        child.result = Value(false);
        child.locals = call.f.isNested ? locals.dup : datasegLocals;
        bindCapturedReferenceSlots(call.f, child);
        forkPerFrameCellsInto(child);
        seedPointerTargetLocals(child);
        child.bindFunctionParameters(
            call.f,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            &classMirrorGenerations,
            evaluatedArguments,
        );

        try {
            child.runStatement(call.f.fbody);
        } catch (InterpretedException exception) {
            writeBackFunctionState(call.f, argumentExpressions, child, arguments);
            throw exception;
        }
        writeBackFunctionState(call.f, argumentExpressions, child, arguments);

        return returnedLvalueAddress(call.f, argumentExpressions, child);
    }

    // Duplicates the complete per-frame cell-state maps -- scalar/array/
    // struct/class cells, every field-pointer reverse-lookup map (and its
    // field-index/writeback siblings), allocation bookkeeping, and the
    // function-pointer/delegate/lazy-argument tables -- from this frame into
    // `child`'s own independent copies. This is the single place every
    // interpreted call/nested-frame fork site populates a child `Walker`'s
    // per-frame cell state from the parent, so a new map family only needs
    // to be added here once instead of at every fork site by hand.
    // `locals` is deliberately NOT duped here: each fork site seeds it with
    // its own logic (dataseg-only for a non-nested free function, a full dup
    // for a nested function/member call/destructor, ...).
    private void forkPerFrameCellsInto(ref Walker child) {
        // Shared, not duped: see `classObjectTable`'s own field comment
        // for why an identity-keyed table needs a shared pointer here,
        // not a per-frame copy.
        child.classObjectTable = classObjectTable;
        // Shared for the identical reason, and by the identical shape --
        // see `moduleTable`'s own field comment.
        child.moduleTable = moduleTable;
        child.nativeThrowableRoots = nativeThrowableRoots.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.arrayCells = arrayCells.dup;
        child.structCells = structCells.dup;
        child.classCells = classCells.dup;
        child.classObjectCells = classObjectCells.dup;
        child.nextClassObjectId = nextClassObjectId;
        child.fieldPointerPaths = fieldPointerPaths.dup;
        child.classFieldPointerObjectIds = classFieldPointerObjectIds.dup;
        child.classFieldPointerWritebacks = classFieldPointerWritebacks.dup;
        child.nestedClassStructFieldPointerWritebacks =
            nestedClassStructFieldPointerWritebacks.dup;
        child.classArrayFieldPointerVariables = classArrayFieldPointerVariables.dup;
        child.classArrayFieldPointerFieldIndices =
            classArrayFieldPointerFieldIndices.dup;
        child.classArrayFieldPointerWritebacks = classArrayFieldPointerWritebacks.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.lazyArgumentFrames = lazyArgumentFrames.dup;
        child.lazyArgumentMirrorEstablished = lazyArgumentMirrorEstablished.dup;
        child.lazyArgumentClassMirrorGenerations = lazyArgumentClassMirrorGenerations.dup;
        child.sliceAliases = sliceAliases.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationAliases = arrayAllocationAliases.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.arrayAllocationCarriers = arrayAllocationCarriers.dup;
        child.structFieldPointerWritebacks = structFieldPointerWritebacks.dup;
        child.structArrayFieldPointerVariables = structArrayFieldPointerVariables.dup;
        child.structArrayFieldPointerFieldIndices =
            structArrayFieldPointerFieldIndices.dup;
        child.structArrayFieldPointerWritebacks = structArrayFieldPointerWritebacks.dup;
        child.nestedStructFieldPointerWritebacks = nestedStructFieldPointerWritebacks.dup;
        child.fieldPathAddressAllocations = fieldPathAddressAllocations.dup;
        child.fieldSnapshotAllocationIds = fieldSnapshotAllocationIds.dup;
        child.arrayPointerWritebacks = arrayPointerWritebacks.dup;
        child.allocationCount = allocationCount;
    }

    // The child's returned address points into its own frame: a pointer to a
    // `ref` parameter's slot must become the caller's argument lvalue so
    // writes through it reach the argument; any other variable's pointer id
    // is registered here so this frame can resolve it.
    private Value returnedLvalueAddress(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        import dmd.tokens: EXP;

        if (!child.result.isLocalPointer)
            return child.result;

        auto variable = child.result.localPointerId in child.localPointers;
        if (variable is null)
            return child.result;

        if (function_.parameters !is null)
            foreach (index, parameter; *function_.parameters) {
                if (parameter !is *variable || !parameter.isReference)
                    continue;

                if (index >= argumentExpressions.length)
                    break;

                return addressOfExpression(
                    argumentExpressions[index],
                    EXP.address,
                );
            }

        localPointers[child.result.localPointerId] = *variable;
        localPointerIds[*variable] = child.result.localPointerId;
        return child.result;
    }

    private Value arrayPointer(
        imported!"dmd.expression".Expression array,
        in long offset,
        in imported!"dmd.tokens".EXP op,
    ) {
        import std.conv: text;

        auto var = array.isVarExp;
        if (var is null) {
            if (auto index = array.isIndexExp) {
                import quickbite.backends.interpreter.layout: typeByteSize;

                const outerOffset = runExpression(index.e2).asLong;
                const pointer = arrayPointer(index.e1, outerOffset, op);
                if (pointer.isNativePointer)
                    return pointer.pointerOffsetBy(
                        offset * cast(long) typeByteSize(
                            array.type.toBasetype.nextOf,
                        ),
                    );
            }

            if (auto dot = array.isDotVarExp) {
                import quickbite.backends.interpreter.layout:
                    classFields, fieldByteOffset, typeByteSize;
                import quickbite.frontend.dmd.types:
                    isDynamicArrayType, isStaticArrayType;

                if (isDynamicArrayType(dot.type)) {
                    auto receiver = dot.e1.isVarExp;
                    auto structVariable = receiver is null
                        ? null
                        : receiver.var.isVarDeclaration;
                    if (
                        structVariable !is null &&
                        structVariable.type.toBasetype.isTypeStruct !is null
                    ) {
                        structVariable = refLocalStorageVariable(structVariable);
                        promoteStructCell(structVariable);
                        if (auto cell = structVariable in structCells) {
                            auto fieldCell = cell.sliceField(
                                structFieldIndex(dot),
                            );
                            return Value.nativePointerValue(
                                fieldCell.block.address + offset *
                                    typeByteSize(dot.type.toBasetype.nextOf),
                            );
                        }
                    }

                    auto variable = classCellKeyVariable(dot.e1);
                    if (variable !is null) {
                        promoteClassCell(variable);
                        if (auto cell = variable in classCells) {
                            const fieldIndex = classFieldIndex(dot);
                            auto fieldCell = classSliceField(
                                *cell,
                                variable.type.toBasetype.isTypeClass.sym,
                                fieldIndex,
                            );
                            return Value.nativePointerValue(
                                fieldCell.block.address + offset *
                                    typeByteSize(dot.type.toBasetype.nextOf),
                            );
                        }
                    }
                }

                auto elementType = dot.type.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (
                    isStaticArrayType(dot.type) &&
                    structType !is null &&
                    structType.sym.isUnionDeclaration is null
                ) {
                    auto receiver = dot.e1.isVarExp;
                    auto structVariable = receiver is null
                        ? null
                        : receiver.var.isVarDeclaration;
                    if (
                        structVariable !is null &&
                        structVariable.type.toBasetype.isTypeStruct !is null
                    ) {
                        structVariable = refLocalStorageVariable(structVariable);
                        promoteStructCell(structVariable);
                        if (auto cell = structVariable in structCells) {
                            auto fieldCell = cell.arrayField(
                                structFieldIndex(dot),
                            );
                            return Value.nativePointerValue(
                                fieldCell.block.address + offset *
                                    typeByteSize(elementType),
                            );
                        }
                    }

                    auto variable = classCellKeyVariable(dot.e1);
                    if (variable !is null) {
                        promoteClassCell(variable);
                        if (auto cell = variable in classCells) {
                            // DMD declaration helpers require a mutable node.
                            auto field = classFields(
                                variable.type.toBasetype.isTypeClass.sym,
                            )[classFieldIndex(dot)];
                            return Value.nativePointerValue(
                                cell.address + fieldByteOffset(field) + offset *
                                    typeByteSize(elementType),
                            );
                        }
                    }
                }

                // For the struct-static-array-field case,
                // `&s.arr[i]` where `arr` is a static-array field of a plain
                // struct local. Reusing `fieldSnapshotAllocationId` gives the
                // same memoized-per-(receiver, field index) identity
                // `&s.field` already gets, and registers the id into
                // `fieldSnapshotAllocationIds` regardless of whether
                // `promoteStructArrayFieldCell` below actually promotes a
                // cell, so `writeLocation`'s `PtrExp` arm still refuses a
                // write it cannot back with real aliasing instead of
                // silently rewriting the pointer variable's own snapshot.
                // For the class case (aggregate composition, the other
                // shape alongside the nested-class-struct-field case):
                // `&c.arr[i]` where
                // `arr` is a scalar-element static-array field of a plain
                // class local. `promoteClassArrayFieldCell` is the
                // class-receiver sibling of `promoteStructArrayFieldCell`
                // above (a no-op for a struct receiver, and vice versa).
                const id = fieldSnapshotAllocationId(dot);
                promoteStructArrayFieldCell(dot, id);
                promoteClassArrayFieldCell(dot, id);

                const value = runExpression(array);
                return Value.arrayPointerValue(
                    arrayPointerElements(value),
                    id,
                    arrayPointerOffset(value, offset),
                );
            }

            throw new Exception(text("Unsupported eval expression: ", op));
        }

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        variable = refLocalStorageVariable(variable);

        auto current = variable in locals;
        if (current is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        auto source = variable;
        if (auto alias_ = variable in sliceAliases)
            source = alias_.source;

        // `&a[i]` is the address-taking moment that promotes `source`'s
        // authoritative `NativeArray`
        // cell, the array counterpart of `promoteScalarCell` above -- keyed
        // by `source` (not `variable`) to match `allocationId(source)`
        // just below, so `arrayPointerVariable`'s reverse lookup (via
        // `arrayAllocationVariables`) and this cell agree on which variable
        // owns the shared bytes.
        promoteArrayCell(source);

        if (auto cell = source in arrayCells) {
            import quickbite.backends.interpreter.layout: typeByteSize;

            const elementOffset = arrayPointerOffset(*current, offset);
            return Value.nativePointerValue(
                cell.block.address + elementOffset *
                    typeByteSize(array.type.toBasetype.nextOf),
            );
        }

        const id = variable in arrayAllocationAliases;
        return Value.arrayPointerValue(
            arrayPointerElements(*current),
            id is null ? allocationId(source) : *id,
            arrayPointerOffset(*current, offset),
        );
    }

    // `&local`, and `&buf[constantIndex]` which DMD folds to
    // SymOffExp(buf, byteOffset): a pointer into a static array's elements
    // mirrors the unfolded `&buf[i]` IndexExp shape; anything else points at
    // the local's slot.
    private Value symbolOffsetLocalValue(
        imported!"dmd.expression".SymOffExp symbol,
        VarDeclaration variable,
    ) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        variable = refLocalStorageVariable(variable);

        if (isStaticArrayType(variable.type)) {
            // `&array` points at the static-array local itself, unlike
            // `&array[index]`, which points into its elements. Keep the
            // former on the local-pointer identity path so a plain `ref`
            // static-array local can reuse that exact storage identity.
            if (isStaticArrayType(symbol.type.toBasetype.nextOf))
                return localPointerValue(variable);

            // Taking the address of a still-void static array materialises
            // its storage (as aggregate reads do) so writes through the
            // pointer have somewhere to land.
            if (variable in uninitializedLocals && variable !in locals)
                setLocal(variable, defaultValue(variable));

            if (auto current = variable in locals) {
                import quickbite.backends.interpreter.layout: typeByteSize;

                promoteArrayCell(variable);
                if (auto cell = variable in arrayCells)
                    return Value.nativePointerValue(cell.block.address)
                        .pointerOffsetBy(cast(long) symbol.offset);

                auto elementType = variable.type.toBasetype.nextOf.toBasetype;
                const elementSize = typeByteSize(elementType);
                const elementOffset = elementSize == 0
                    ? 0
                    : cast(size_t) symbol.offset / elementSize;

                auto source = variable;
                if (auto alias_ = variable in sliceAliases)
                    source = alias_.source;

                return Value.arrayPointerValue(
                    arrayPointerElements(*current),
                    allocationId(source),
                    arrayPointerOffset(*current, cast(long) elementOffset),
                );
            }
        }

        return localPointerValue(variable);
    }

    private Value localPointerValue(VarDeclaration variable) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        if (auto alias_ = variable in structFieldAliases)
            if (auto id = directFieldPathKey(alias_.source, alias_.index)
                    in fieldPathAddressAllocations)
                return Value.arrayPointerValue(
                    [readCelledLocal(variable)],
                    *id,
                    0,
                );

        // A normal scalar local already owns native frame storage. Its
        // address is the guest pointer; do not create a second scalar cell
        // merely to manufacture a pointer identity. Aliasing slots and
        // pre-initialization address-taking keep the legacy carrier until
        // their bind/read paths join the authority switch.
        if (
            isNativeScalarType(variable.type) &&
            hasMirrorSlot(variable) &&
            mirrorEstablished.get(variable, false)
        )
            return Value.nativePointerValue(mirrorAddress(variable));

        promoteScalarCell(variable);

        if (auto id = variable in localPointerIds)
            return Value.localPointerValue(*id);

        const id = ++nextLocalPointerId;
        localPointerIds[variable] = id;
        localPointers[id] = variable;
        return Value.localPointerValue(id);
    }

    // A plain aggregate `ref` binding reuses its source's local-pointer id.
    // Resolve that existing identity back to the declaration which owns the
    // storage so reads and assignments through the ref local or parameter do
    // not acquire an independent boxed slot.
    private VarDeclaration refLocalStorageVariable(VarDeclaration variable) {
        if (!isRefVariable(variable))
            return variable;

        auto id = variable in localPointerIds;
        if (id is null)
            return variable;

        auto source = *id in localPointers;
        return source is null ? variable : *source;
    }

    // Eagerly gives an address-taken native-scalar local an authoritative
    // native-byte cell the first time its address is taken, seeded from
    // whatever value the local currently
    // holds (its boxed value in `locals`, or the type's default if never
    // written). Once a cell exists, `writeLocation`'s `PtrExp` arm and the
    // `VarExp` read arm route through it instead of `locals`, so a
    // byte-level write through a same-size pointer cast is visible to a
    // direct read of the local -- the reinterpret-write bug this slice
    // fixes. Non-scalar locals (aggregates, pointers) are untouched; they
    // keep using the existing boxed/aliasing paths.
    private void promoteScalarCell(VarDeclaration variable) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, writeScalar;

        // A dataseg variable (module-level, `__gshared`, or `static`) has its
        // own storage/initialization/extern machinery (the `isDataseg`
        // arms above and in `writeLocation`'s `VarExp` arm): its real value
        // may not exist yet at address-of time (a lazily-materialized
        // initializer) and native writes to an extern data symbol never
        // refresh a cell. Seeding a cell here would shadow both, and read
        // from stale/defaulted bytes instead. Only true stack locals get
        // cells.
        if (variable.isDataseg)
            return;

        // Owning frame storage is already the scalar's native authority once
        // initialized; `localPointerValue` returns that address directly.
        // Keep a cell only for an aliasing/pre-init binding that cannot yet
        // name such a slot.
        if (hasMirrorSlot(variable) && mirrorEstablished.get(variable, false))
            return;

        if (variable in scalarCells)
            return;

        if (!isNativeScalarType(variable.type))
            return;

        // `auto`, not `const`: reassigned below when the local already has a
        // boxed value to seed the cell from.
        auto current = defaultValue(variable);
        if (auto existing = variable in locals)
            current = *existing;

        auto cell = NativeBlock.allocate(typeByteSize(variable.type), NativeBlock.Scan.no);
        writeScalar(variable.type, cell.bytes, current);
        scalarCells[variable] = cell;
    }

    // Eagerly gives an address-taken array local a `NativeArray`
    // cell the first time `&a[i]` is taken (`arrayCells`'s own promotion,
    // mirroring `promoteScalarCell` above), seeded from the array's current boxed
    // elements. A dynamic array whose element type is `native_scalar.
    // isNativeScalarType` gets a scalar-bytes cell; a dynamic array whose
    // element type is a (non-union) struct gets a cell too, seeded field by
    // field through `NativeArray.structElement`/`writeStructCellScalarFields`
    // -- the array-of-struct counterpart of `promoteStructCell` above,
    // reusing the same composition accessor. An array whose element
    // type is itself a scalar-element static array (`int[3][] a`) gets a
    // cell too, seeded element by element through `NativeArray.arrayElement`/
    // `writeStaticArrayCellScalarElements` -- the array-of-array counterpart
    // of the struct branch above, reusing the same inline-bytes container
    // accessor. A union element, a static-array element whose OWN element
    // type is not `native_scalar.isNativeScalarType` (out of this narrow
    // slice's scope -- no deeper-nesting rabbit hole), any other non-scalar
    // element type (class, nested dynamic array, slice) is left untouched and
    // keeps using the existing boxed/aliasing paths. Dataseg arrays may be
    // promoted after their lazily materialized value has entered `locals`:
    // unlike a cell seeded before that point, this preserves the initializer
    // while allowing a typed view returned from a callee to keep sharing the
    // module variable's storage.
    private void promoteArrayCell(VarDeclaration variable) {
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, writeScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        // Dataseg storage has no trustworthy default-value seed: until its
        // current value has been materialized in `locals`, its initializer or
        // extern data symbol remains authoritative.
        if (variable.isDataseg && variable !in locals)
            return;

        auto elementType = variable.type.toBasetype.nextOf.toBasetype;
        if (!isDynamicArrayType(variable.type) && !(
            isStaticArrayType(variable.type) &&
            isStaticArrayType(elementType)
        ))
            return;

        auto current = defaultValue(variable);
        if (auto existing = variable in locals)
            current = *existing;

        if (!current.isArray)
            return;

        if (auto existing = variable in arrayCells) {
            if (
                current.arrayNativeAddress is null ||
                existing.block.address is current.arrayNativeAddress
            )
                return;
            dropArrayCell(variable);
        }

        if (isNativeScalarType(elementType)) {
            if (current.arrayNativeAddress !is null) {
                arrayCells[variable] = NativeArray.borrow(
                    elementType,
                    cast(void*) current.arrayNativeAddress,
                    current.length,
                );
                return;
            }

            auto cell = NativeArray.allocate(elementType, current.length);
            foreach (index; 0 .. current.length)
                writeScalar(elementType, cell.element(index), current[index]);

            arrayCells[variable] = cell;
            return;
        }

        auto structType = elementType.isTypeStruct;
        if (structType !is null) {
            // A `union` element cannot be represented by `writeStructCellScalarFields`'s
            // whole-block scalar-field overlay any more than a union LOCAL can --
            // see `promoteStructCell`'s identical guard for why.
            if (structType.sym.isUnionDeclaration !is null)
                return;

            auto cell = NativeArray.allocate(elementType, current.length);
            foreach (index; 0 .. current.length) {
                auto elementCell = cell.structElement(index);
                writeStructCellScalarFields(elementCell, current[index]);
            }

            arrayCells[variable] = cell;
            return;
        }

        auto arrayType = elementType.isTypeSArray;
        if (arrayType is null)
            return;

        // Only a scalar-element static array is seeded here -- the
        // static-array-element sibling of the union guard above; a deeper
        // nested element (array-of-array-of-struct, array-of-array-of-array)
        // is out of this narrow slice's scope and stays on the existing
        // boxed/aliasing path.
        auto innerElementType = arrayType.next.toBasetype;
        if (!isNativeScalarType(innerElementType))
            return;

        auto cell = NativeArray.allocate(elementType, current.length);
        foreach (index; 0 .. current.length) {
            auto elementCell = cell.arrayElement(index);
            writeStaticArrayCellScalarElements(elementCell, current[index]);
        }

        arrayCells[variable] = cell;
    }

    // Gives a slice local (`int[] s = a[];`) an `arrayCells` entry that
    // shares the SAME `NativeArray` block as its slice source, rather than
    // the detached boxed `.dup` `locals` already holds -- native array
    // storage extended to the reverse slice-aliasing direction
    // (a write to the SOURCE visible through an earlier-taken slice; the
    // forward direction -- a write through the slice, visible in the source
    // -- was already covered by `sliceAliases`/`writeThroughSliceAlias`).
    // Called right after `recordSliceAlias` has resolved `variable`'s own
    // `SliceAlias`, following any chain of nested slices to the ROOT source
    // and the combined lower bound relative to it -- so this reuses that
    // same resolution rather than re-deriving it from `slice.e1` itself.
    //
    // `promoteArrayCell(alias_.source)` mirrors the address-of-time
    // promotion `arrayPointer` already does for `&a[i]`: eager, idempotent,
    // and gated by the same dynamic-array and representable-element guards.
    // A dataseg source is eligible once its current value is materialized in
    // `locals`. Once the source has a cell, `NativeArray.slice`
    // gives a real, bidirectionally-aliasing sub-range view over it -- not
    // a copy -- for `variable`'s own entry, using `alias_.lower` and the
    // slice's own already-computed length (`locals[variable]`, the boxed
    // dup `runSliceExpression` just produced, whose length is exactly the
    // slice's element count regardless of nesting).
    //
    // A no-op, leaving `variable` on the existing boxed/aliasing paths, for:
    // a struct-field-rooted slice (`alias_.hasFieldIndex`, e.g. `val.field[]`
    // -- not a plain local, out of this narrow first slice's scope); and any
    // source that `promoteArrayCell` cannot represent (including a union,
    // deeper nested static array, or other unsupported element shape), which
    // leaves no cell here to share.
    private void promoteSliceArrayCell(VarDeclaration variable) {
        // `variable`'s declaration statement re-executes on every fresh
        // binding (a loop-reused slice temp taken over a differently-sized
        // array each pass, as a `foreach` body's per-iteration `auto r =
        // row[];` does): drop any cell a PRIOR binding promoted before
        // deciding whether THIS one gets a fresh cell, or a stale, wrong-
        // length cell from an earlier binding survives to be read against
        // this binding's own bounds.
        arrayCells.remove(variable);

        auto alias_ = variable in sliceAliases;
        if (alias_ is null || alias_.hasFieldIndex)
            return;

        promoteArrayCell(alias_.source);

        auto cell = alias_.source in arrayCells;
        if (cell is null)
            return;

        auto current = variable in locals;
        const length = current is null ? 0 : current.length;

        // The source cell's own length can have drifted from the boxed
        // `locals` bookkeeping this slice's bounds were computed against
        // -- e.g. the source array was grown by `~=` after its cell was
        // promoted, leaving the cell too short for `alias_.lower + length`.
        // A native cell cannot faithfully represent such a slice, so decline
        // the promotion rather than let `NativeArray.slice` throw: `variable`
        // stays on the boxed `locals` + `writeThroughSliceAlias` aliasing
        // path, exactly as it worked before this promotion existed.
        if (alias_.lower + length > cell.length)
            return;

        arrayCells[variable] = cell.slice(alias_.lower, alias_.lower + length);

        // `recordSliceAlias` has flattened nested slices to their ultimate
        // source and an absolute offset from that source. Give every such
        // view the root's allocation identity and keep that id's carrier at
        // the root cell: a callee may see only this interior cell, but its
        // Value offset must remain meaningful when the carrier merges back
        // into a frame that sees the whole allocation. This also preserves a
        // one-past-the-end coordinate for zero-length slices.
        const rootId = alias_.source in arrayAllocationAliases;
        const id = rootId is null
            ? allocationId(alias_.source)
            : *rootId;
        if (id !in arrayAllocationCarriers)
            arrayAllocationCarriers[id] = *cell;
        arrayAllocationAliases[variable] = id;
    }

    // Eagerly gives an address-taken struct local a `NativeStruct` cell the
    // first time `&s.field` is taken for one of its own scalar fields
    // (mirroring `promoteArrayCell` above), seeded from the struct's
    // current boxed field values. Narrow
    // first slice: only a plain (non-dataseg) struct-typed local gets a
    // cell; a dataseg variable, or a receiver that never resolves to a
    // struct-typed boxed value, is left untouched and keeps using the
    // existing boxed `locals` path.
    private void promoteStructCell(VarDeclaration variable) {
        if (variable.isDataseg)
            return;

        if (variable in structCells)
            return;

        auto structType = variable.type.toBasetype.isTypeStruct;
        if (structType is null)
            return;

        // A `union` is itself a `TypeStruct` (`structType.sym` an
        // `UnionDeclaration`), so without this guard a union local would get
        // a cell here too; `writeStructCellScalarFields` seeds every field
        // at its own (overlapping, offset-0-for-a-plain-union) byte range
        // with no union-vs-struct branch, so a second field's seed would
        // clobber the first's bytes IF the two fields' boxed values ever
        // disagree about the underlying bits. For an address-taken
        // scalar-only union (2026-07-15): when EVERY member is
        // `native_scalar.isNativeScalarType`, that clobber is harmless --
        // the only two ways this cell's bytes are ever (re)seeded are
        // `withUnionFieldWrite` (which re-derives every OTHER native-scalar
        // sibling from the SAME just-written bytes, so all fields already
        // agree bit-for-bit before the overlay runs) and this very seed from
        // the current boxed value (whose members may still individually
        // disagree right after an untouched union's own default-init -- a
        // separate, already-tracked divergence from `SystemLinker`'s
        // first-member-wins zero-init, unrelated to and not worsened by cell
        // promotion, since no existing test reads an untouched union field
        // through a promoted cell). A union with any NON-native-scalar
        // member (a nested aggregate, array, or class field sharing the same
        // bytes) keeps declining exactly as before: `writeStructCellScalarFields`
        // would recurse into that member's own sub-fields at the same
        // overlapping offset with no such consistency guarantee, corrupting
        // `&u.<scalarField>`'s later deref -- an open follow-up, not this
        // slice's scope.
        if (structType.sym.isUnionDeclaration !is null) {
            import quickbite.backends.interpreter.layout: structFields;
            import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

            foreach (field; structFields(structType))
                if (!isNativeScalarType(field.type))
                    return;
        }

        auto current = defaultValue(variable);
        if (auto existing = variable in locals)
            current = *existing;

        if (!current.isStruct)
            return;

        auto cell = NativeStruct.allocate(structType);
        writeStructCellScalarFields(cell, current);
        structCells[variable] = cell;
    }

    // Refreshes every `native_scalar.isNativeScalarType` field's bytes in
    // `cell` from `structValue`'s boxed fields (the struct counterpart of
    // `promoteArrayCell`'s element loop), and -- for the
    // struct-static-array-field case -- every static-array field whose
    // OWN element type is `native_scalar.isNativeScalarType`, via
    // `NativeStruct.arrayField`'s `NativeArray` view over the same block.
    // Also -- the nested-struct-field follow-up -- recurses one level into
    // every (non-union) struct-typed field via `NativeStruct.structField`'s
    // shared-block view, so a nested field's OWN scalar sub-fields get the
    // same seed/refresh treatment, applied recursively (the recursion itself
    // is not depth-limited, even though the address-of/pointer-deref
    // machinery that reads it back currently only resolves one level of
    // nesting -- see the common field-path comment). Every other non-scalar
    // field (class, an unsupported dynamic-array element shape, or a union
    // at any level) is left untouched,
    // matching this narrow slice's scope -- only an address-taken scalar
    // field, scalar-element static-array field, or (one level deep) nested
    // scalar field is ever read back through a `structCells` entry, so
    // leaving another field's bytes stale here is harmless. Called both at
    // cell-creation time (`promoteStructCell`) and on every subsequent
    // whole-struct refresh (`writeCelledLocal`), so a direct `s.arr[i] = x`
    // or `s.inner.x = y` write after `&s.arr[j]`/`&s.inner.x` promoted the
    // cell reaches this same refresh, keeping the field cell current for a
    // later deref-read (`structArrayFieldPointerCellValue`/
    // `nestedStructFieldPointerCellValue`).
    private void writeStructCellScalarFields(ref NativeStruct cell, in Value structValue) {
        import quickbite.backends.interpreter.layout: fieldByteOffset;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, writeScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        foreach (index; 0 .. cell.fieldCount) {
            auto fieldType = cell.fieldDeclaration(index).type;

            if (isNativeScalarType(fieldType)) {
                writeScalar(fieldType, cell.field(index), structValue.structFieldAt(index));
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

                const fieldValue = structValue.structFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                auto arrayCell = cell.arrayField(index);
                foreach (elementIndex; 0 .. fieldValue.length)
                    writeArrayCellElement(
                        arrayCell,
                        elementIndex,
                        fieldValue[elementIndex],
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

                const fieldValue = structValue.structFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                auto arrayCell = fieldValue.arrayNativeAddress is null
                    ? NativeArray.allocate(elementType, fieldValue.length)
                    : NativeArray.borrow(
                        elementType,
                        cast(void*) fieldValue.arrayNativeAddress,
                        fieldValue.length,
                    );
                if (fieldValue.arrayNativeAddress is null)
                    foreach (elementIndex; 0 .. fieldValue.length)
                        writeArrayCellElement(
                            arrayCell,
                            elementIndex,
                            fieldValue[elementIndex],
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

            const nestedValue = structValue.structFieldAt(index);
            if (!nestedValue.isStruct)
                continue;

            auto nestedCell = cell.structField(index);
            writeStructCellScalarFields(nestedCell, nestedValue);
        }
    }

    // `&s.field`'s promotion moment: when `dot`'s receiver resolves to a
    // plain local variable and the field
    // itself is `native_scalar.isNativeScalarType`, gives the receiver a
    // `structCells` entry (`promoteStructCell`, mirroring `promoteArrayCell`'s
    // role in `arrayPointer`) and records `id` -- the SAME allocation id
    // `addressOfExpression`'s caller already memoized via
    // `fieldSnapshotAllocationId` -- in the reverse lookup
    // common `fieldPointerPaths` reverse lookup, so a
    // later deref-read through this id's pointer
    // (`structFieldPointerCellValue`) can find the same cell and field. A
    // no-op (no cell, no reverse-lookup entry) for a non-`VarExp` receiver
    // (e.g. `&call().field`), a non-scalar field, or a receiver whose boxed
    // value isn't a struct -- every one of those leaves `promoteStructCell`
    // itself a no-op, so there is no cell here to point at.
    private void promoteStructFieldCell(
        imported!"dmd.expression".DotVarExp dot,
        in size_t id,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        auto var = dot.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable is null)
            return;

        if (!isNativeScalarType(dot.type))
            return;

        promoteStructCell(variable);
        if ((variable in structCells) is null)
            return;

        fieldPointerPaths[id] = directFieldPathKey(variable, structFieldIndex(dot));
    }

    // Eagerly gives an address-taken class local a `classCells` cell the
    // first time `&c.field` is taken for one of its own scalar fields
    // (the class sibling of `promoteStructCell`), seeded from the object's
    // current boxed field
    // values. Narrow first slice: only a plain (non-dataseg) class-typed
    // local gets a cell; a dataseg variable, or a receiver whose boxed value
    // isn't a class object, is left untouched and keeps using the existing
    // boxed `locals` path. The cell is sized by `layout.classInstanceByteSize`
    // -- DMD's own `structsize`, the same fact `object_table.ObjectTable`
    // sizes its class bodies from -- not by summing (offset + typeByteSize)
    // over `layout.classFields`: a field-end sum omits the vtable/monitor
    // header at the front of every class object and any tail padding DMD adds
    // after the last field, so it can under-size the cell (confirmed: a
    // field-less class's field-end sum is 0). Every field write into this
    // cell already goes through `layout.fieldByteOffset`, DMD's own
    // header-inclusive offset, so a larger cell only adds unused bytes past
    // the last field; nothing reads the cell's length as if it equalled the
    // field-end sum.
    private void promoteClassCell(VarDeclaration variable) {
        import quickbite.backends.interpreter.layout: classInstanceByteSize;

        if (variable.isDataseg)
            return;

        if (variable in classCells)
            return;

        auto classType = variable.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return;

        auto current = defaultValue(variable);
        if (auto existing = variable in locals)
            current = *existing;

        if (!current.isClassObject)
            return;

        const identity = current.classIdentity;
        if (identity == 0)
            return;

        if (auto existing = identity in classObjectCells) {
            classCells[variable] = *existing;
            return;
        }

        const byteSize = classInstanceByteSize(classType.sym);
        auto cell = NativeBlock.allocate(byteSize, NativeBlock.Scan.conservative);
        writeClassCellScalarFields(cell, classType.sym, current);
        classObjectCells[identity] = cell;
        classCells[variable] = cell;
    }

    // Same-frame plain-variable class aliasing: `C c2 = c;` or `c2 = c;`
    // copies a REFERENCE, so `c2` must
    // share `c`'s object identity, not box an independent copy of its
    // fields. Eagerly promotes (or reuses) `source`'s `classCells` entry and
    // points `target` at the SAME `NativeBlock` -- `NativeBlock` is a value
    // struct whose `bytes` is a slice, so copying it (`classCells[target] =
    // *cell`) shares the one underlying byte range, exactly like two
    // direct-field reverse-lookup entries sharing a `structCells` block.
    // A no-op when `source` is not a bare `VarExp` (e.g. `c2 = f();`), or
    // `target` is not class-typed, or `promoteClassCell` itself is a no-op
    // (a dataseg variable, or a receiver whose boxed value is not a class
    // object -- e.g. still `null`) -- every one of those leaves `target`
    // with no `classCells` entry, so it keeps using the existing boxed
    // `locals` path unchanged.
    private void registerClassAliasIfPlainVar(
        VarDeclaration target,
        imported!"dmd.expression".Expression source,
    ) {
        if (target.type.toBasetype.isTypeClass is null)
            return;

        target = refLocalStorageVariable(target);

        auto sourceVar = source.isVarExp;
        if (sourceVar is null)
            return;

        auto sourceVariable = sourceVar.var.isVarDeclaration;
        if (sourceVariable is null || sourceVariable is target)
            return;

        promoteClassCell(sourceVariable);
        if (auto cell = sourceVariable in classCells)
            classCells[target] = *cell;
    }

    // Cross-frame counterpart of `registerClassAliasIfPlainVar` above:
    // a by-value class PARAMETER is still a
    // REFERENCE to the caller's object, exactly like `C c2 = c;`, except the
    // aliasing happens at the call boundary (parameter binding) instead of a
    // declaration, and the two `VarDeclaration`s involved (the caller's
    // argument variable and the callee's own parameter) live in different
    // frames -- `this` is the CALLER (where the argument variable's cell must
    // be promoted/read) and `child` is the callee-to-be (whose classCells
    // entry for the parameter this seeds). Runs once per call, right after
    // `child.classCells = classCells.dup` -- so this assignment is not
    // clobbered by that dup -- and before `child.bindFunctionParameters`.
    // Promotes (or reuses) `this.classCells[sourceVariable]` the same way
    // `registerClassAliasIfPlainVar` does, then points `child`'s entry for
    // `parameter` at that SAME `NativeBlock`, so TWO different parameters
    // bound from the SAME argument variable (`combine(c, c)`) end up sharing
    // one cell too -- the second iteration's `promoteClassCell` is a no-op
    // (the first iteration already promoted it), and both parameters' entries
    // point at the identical bytes. Drops any stale `child.classCells` entry
    // inherited from an ancestor recursive call of the same `FuncDeclaration`
    // (parameters are the same `VarDeclaration` at every recursion depth) so
    // a non-aliasing argument on a later call never resurrects a prior
    // depth's unrelated cell. A no-op (no `child.classCells` entry left) for
    // a `ref` parameter (already reference-passed via
    // `writeBackRefArguments`), a non-class parameter, a non-`VarExp`
    // argument (e.g. `mutate(makeC())`), or a receiver whose
    // `promoteClassCell` is itself a no-op (dataseg source, or a boxed value
    // that is not a class object, e.g. still `null`) -- every one of those
    // leaves the parameter using its ordinary boxed value; no caller
    // writeback is correct for a by-value parameter.
    private void registerClassArgumentAliases(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (parameter.isReference)
                continue;

            if (parameter.type is null || parameter.type.toBasetype.isTypeClass is null)
                continue;

            child.classCells.remove(parameter);

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            if (argument is null)
                continue;

            auto sourceVar = argument.isVarExp;
            if (sourceVar is null)
                continue;

            auto sourceVariable = sourceVar.var.isVarDeclaration;
            if (sourceVariable is null)
                continue;

            promoteClassCell(sourceVariable);
            if (auto cell = sourceVariable in classCells) {
                child.classCells[parameter] = *cell;
                auto sourceValue = sourceVariable in locals;
                if (sourceValue !is null && sourceValue.isClassObject)
                    child.classObjectCells[sourceValue.classIdentity] = *cell;
            }
        }
    }

    // A ref aggregate parameter denotes the caller's storage. Point the
    // parameter at the caller's existing aggregate cell and local-pointer id
    // so repeated arguments (`f(value, value)`) share one authority and one
    // address instead of competing through independent boxed snapshots.
    private void registerRefAggregateArgumentAliases(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (!parameter.isReference)
                continue;

            const baseType = parameter.type.toBasetype;
            const isStruct = baseType.isTypeStruct !is null;
            const isClass = baseType.isTypeClass !is null;
            const isStaticArray = baseType.isTypeSArray !is null;
            if (!isStruct && !isClass && !isStaticArray)
                continue;

            if (isStruct)
                child.structCells.remove(parameter);
            else if (isClass)
                child.classCells.remove(parameter);

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            auto var = argument is null ? null : argument.isVarExp;
            auto source = var is null ? null : var.var.isVarDeclaration;
            if (source is null)
                continue;

            if (isStruct) {
                promoteStructCell(source);
                if (auto cell = source in structCells)
                    child.structCells[parameter] = *cell;
            } else if (isClass) {
                promoteClassCell(source);
                if (auto cell = source in classCells) {
                    child.classCells[parameter] = *cell;
                    auto sourceValue = source in locals;
                    if (sourceValue !is null && sourceValue.isClassObject)
                        child.classObjectCells[sourceValue.classIdentity] = *cell;
                }
            }

            const pointerId = localPointerValue(source).localPointerId;
            child.localPointerIds[parameter] = pointerId;
            child.localPointers[pointerId] = parameter;
            child.nextLocalPointerId = nextLocalPointerId;
        }
    }

    // A direct scalar aggregate field passed by ref already has all the
    // storage machinery needed for a real alias: field promotion gives the
    // caller an authoritative aggregate cell and memoized field address.
    // Share that field subrange with the parameter's scalar cell and retain
    // the existing aggregate-field alias so direct parameter reads, writes,
    // and address-taking all denote the caller's one location.
    private void registerDirectAggregateFieldRefArgumentAliases(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        import quickbite.backends.interpreter.layout:
            classFields, fieldByteOffset, typeByteSize;
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (!parameter.isReference || !isNativeScalarType(parameter.type))
                continue;

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            auto dot = argument is null ? null : argument.isDotVarExp;
            auto var = dot is null ? null : dot.e1.isVarExp;
            auto source = var is null ? null : var.var.isVarDeclaration;
            if (source is null)
                continue;
            // Mutable because DMD declarations do not expose a const API.
            auto storageSource = child.refLocalStorageVariable(source);

            const isClass = storageSource.type.toBasetype.isTypeClass !is null;
            if (isClass) {
                auto cell = storageSource in child.classCells;
                if (cell is null)
                    continue;

                const fieldIndex = classFieldIndex(dot);
                // Mutable because layout.fieldByteOffset follows DMD's
                // mutable VarDeclaration API.
                auto field = classFields(
                    storageSource.type.toBasetype.isTypeClass.sym,
                )[fieldIndex];
                child.structFieldAliases[parameter] = StructFieldAlias(
                    storageSource,
                    fieldIndex,
                    true,
                );
                child.scalarCells[parameter] = cell.subRange(
                    fieldByteOffset(field),
                    typeByteSize(parameter.type),
                );
                continue;
            }

            auto cell = storageSource in child.structCells;
            if (cell is null)
                continue;

            const fieldIndex = structFieldIndex(dot);
            child.structFieldAliases[parameter] = StructFieldAlias(
                storageSource,
                fieldIndex,
            );
            child.scalarCells[parameter] = cell.block.subRange(
                cell.fieldByteOffset(fieldIndex),
                typeByteSize(parameter.type),
            );
        }
    }

    private void prepareDirectAggregateFieldRefArgumentAliases(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (!parameter.isReference || !isNativeScalarType(parameter.type))
                continue;

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            auto dot = argument is null ? null : argument.isDotVarExp;
            auto var = dot is null ? null : dot.e1.isVarExp;
            auto source = var is null ? null : var.var.isVarDeclaration;
            if (source is null)
                continue;
            // Mutable because DMD declarations do not expose a const API.
            auto storageSource = refLocalStorageVariable(source);
            if (
                storageSource.type.toBasetype.isTypeStruct is null &&
                storageSource.type.toBasetype.isTypeClass is null
            )
                continue;

            const id = fieldSnapshotAllocationId(dot);
            if (storageSource.type.toBasetype.isTypeClass !is null)
                promoteClassFieldCell(dot, id);
            else
                promoteStructFieldCell(dot, id);
        }
    }

    // `this`-reached counterpart of `registerClassArgumentAliases` above:
    // the hidden `this` parameter is
    // itself a by-value REFERENCE to the caller's object, exactly like any
    // other by-value class parameter aliased from the same argument
    // variable -- except there is no argument EXPRESSION for `this`, only
    // `receiverExpression` (`c` in `c.setX(99)`). Called from
    // `runMemberFunction` right after `child.classCells = classCells.dup`
    // and before `child.bindFunctionParameters`, same as
    // `registerClassArgumentAliases`. Promotes (or reuses)
    // `this.classCells[sourceVariable]` (the CALLER's cell) and points
    // `child`'s entry for `function_.vthis` -- dmd's own stable
    // `VarDeclaration` identity for the hidden `this` parameter -- at that
    // SAME `NativeBlock`, so a write through `this.x = v` inside the
    // callee's own frame (`writeClassCellFieldIfPresent`, via
    // `classCellKeyVariable` resolving a bare `ThisExp` to `vthis`) lands in
    // the identical bytes another by-value parameter bound from the same
    // argument (`registerClassArgumentAliases`) or the caller's own
    // variable observes. Drops any stale `child.classCells` entry inherited
    // from an ancestor recursive call of the same `FuncDeclaration` first
    // (`vthis` is the same `VarDeclaration` at every recursion depth),
    // matching `registerClassArgumentAliases`'s own drop-on-rebind. A no-op
    // (no `child.classCells[vthis]` entry) for a `null` `vthis` or `null`
    // `receiverExpression` (should not happen for a real member call), a
    // non-`VarExp` receiver (e.g. `makeC().setX(99)`), or a receiver whose
    // `promoteClassCell` is itself a no-op (dataseg source, or a boxed
    // value that is not a class object) -- every one of those leaves
    // `this`-field writes updating only the callee's own boxed `thisValue`,
    // relying on `writeBackThis`'s post-call value copy exactly as before
    // this slice.
    private void registerClassThisAlias(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        ref Walker child,
    ) {
        auto vthis = function_.vthis;
        if (vthis is null)
            return;

        child.classCells.remove(vthis);

        if (receiverExpression is null)
            return;

        auto sourceVar = receiverExpression.isVarExp;
        if (sourceVar is null)
            return;

        auto sourceVariable = sourceVar.var.isVarDeclaration;
        if (sourceVariable is null)
            return;

        // A polymorphic call -- the source variable's STATIC declared type
        // (e.g. `Base`) can be a proper ancestor of `vthis`'s type (the
        // OVERRIDE method's own declaring class, e.g. `Child`, reached via
        // virtual dispatch on a `Base value = new Child(...);` receiver).
        // `promoteClassCell` sizes the cell from the SOURCE variable's
        // static type, so aliasing it to `vthis` here would let the
        // override body's `this.field` reads/writes -- resolved against
        // `vthis`'s own, possibly LARGER, class layout -- run past the
        // smaller cell's bytes (confirmed: an out-of-bounds `NativeBlock`
        // slice read on `class.virtualCallUsesDynamicClass`). Skip
        // aliasing whenever the two class declarations are not identical;
        // the override body then falls back to its own boxed `thisValue`,
        // exactly as before this slice.
        auto sourceClass = sourceVariable.type.toBasetype.isTypeClass;
        auto vthisClass = vthis.type.toBasetype.isTypeClass;
        if (
            sourceClass is null || vthisClass is null ||
            sourceClass.sym !is vthisClass.sym
        )
            return;

        promoteClassCell(sourceVariable);
        if (auto cell = sourceVariable in classCells) {
            child.classCells[vthis] = *cell;
            auto sourceValue = sourceVariable in locals;
            if (sourceValue !is null && sourceValue.isClassObject)
                child.classObjectCells[sourceValue.classIdentity] = *cell;
        }
    }

    // Refreshes every `native_scalar.isNativeScalarType` field's bytes in
    // `cell` from `classValue`'s boxed fields -- the class counterpart of
    // `writeStructCellScalarFields`. Also -- for aggregate composition --
    // widens every scalar-element
    // static-array field via a `NativeArray` adopted over the field's own
    // byte sub-range (the class-receiver sibling of
    // `writeStructCellScalarFields`'s own `NativeStruct.arrayField`-based
    // widening, built directly here since a `classCells` entry has no
    // `NativeStruct` wrapper of its own -- see `classCells`'s own field
    // comment), and recurses one level into every (non-union) struct-typed
    // field, and writes scalar- or struct-element dynamic-array headers whose
    // backing storage is itself a `NativeArray`. Every other non-scalar field
    // (another class reference, an unsupported dynamic-array element shape,
    // or a union at any level) is left untouched.
    private void writeClassCellScalarFields(
        ref NativeBlock cell,
        imported!"dmd.dclass".ClassDeclaration class_,
        in Value classValue,
    ) {
        import quickbite.backends.interpreter.layout:
            classFields, fieldByteOffset, staticArrayLength, typeByteSize;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, writeScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        foreach (index, field; classFields(class_)) {
            if (isNativeScalarType(field.type)) {
                const offset = fieldByteOffset(field);
                const size = typeByteSize(field.type);
                writeScalar(field.type, cell.bytes[offset .. offset + size], classValue.classFieldAt(index));
                continue;
            }

            if (isStaticArrayType(field.type)) {
                auto elementType = field.type.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                const fieldValue = classValue.classFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                const offset = fieldByteOffset(field);
                const size = typeByteSize(field.type);
                const length = staticArrayLength(field.type.toBasetype.isTypeSArray);
                auto arrayCell = NativeArray.adopt(cell.subRange(offset, size), elementType, length);
                foreach (elementIndex; 0 .. fieldValue.length)
                    writeArrayCellElement(
                        arrayCell,
                        elementIndex,
                        fieldValue[elementIndex],
                    );
                continue;
            }

            if (isDynamicArrayType(field.type)) {
                auto elementType = field.type.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                const fieldValue = classValue.classFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                auto arrayCell = fieldValue.arrayNativeAddress is null
                    ? NativeArray.allocate(elementType, fieldValue.length)
                    : NativeArray.borrow(
                        elementType,
                        cast(void*) fieldValue.arrayNativeAddress,
                        fieldValue.length,
                    );
                if (fieldValue.arrayNativeAddress is null)
                    foreach (elementIndex; 0 .. fieldValue.length)
                        writeArrayCellElement(
                            arrayCell,
                            elementIndex,
                            fieldValue[elementIndex],
                        );
                arrayCell.writeSliceHeader(cell, fieldByteOffset(field));
                continue;
            }

            // Aggregate composition: a (non-union) struct-typed field recurses
            // one level, mirroring
            // `writeStructCellScalarFields`'s own nested-struct-field
            // recursion. Unlike that function's `cell` (already a
            // `NativeStruct`), `cell` here is a plain `NativeBlock` -- a
            // `classCells` entry has no `NativeStruct` wrapper of its own
            // (see `classCells`'s own field comment) -- so the nested view is
            // built directly via `NativeStruct.adopt` over the field's own
            // byte sub-range, the same composition accessor
            // `NativeStruct.structField` uses internally for a struct
            // receiver.
            auto nestedStructType = field.type.toBasetype.isTypeStruct;
            if (nestedStructType is null || nestedStructType.sym.isUnionDeclaration !is null)
                continue;

            const nestedValue = classValue.classFieldAt(index);
            if (!nestedValue.isStruct)
                continue;

            const offset = fieldByteOffset(field);
            const size = typeByteSize(field.type);
            auto nestedCell = NativeStruct.adopt(cell.subRange(offset, size), nestedStructType);
            writeStructCellScalarFields(nestedCell, nestedValue);
        }
    }

    // `&c.field`'s promotion moment: when `dot`'s receiver resolves to a plain
    // local variable and the field
    // itself is `native_scalar.isNativeScalarType`, gives the receiver a
    // `classCells` entry (`promoteClassCell`, the class sibling of
    // `promoteStructFieldCell`) and records `id` in the reverse lookup
    // common `fieldPointerPaths` reverse lookup, so a
    // later deref-read through this id's pointer
    // (`classFieldPointerCellValue`) can find the same cell and field. A
    // no-op (no cell, no reverse-lookup entry) for a non-`VarExp` receiver
    // (e.g. `&call().field`), a non-scalar field, or a receiver whose boxed
    // value isn't a class object -- every one of those leaves
    // `promoteClassCell` itself a no-op, so there is no cell here to point
    // at. Also a no-op for a struct receiver: `promoteClassCell` requires
    // `variable.type.toBasetype.isTypeClass`, which is `null` for a struct.
    private void promoteClassFieldCell(
        imported!"dmd.expression".DotVarExp dot,
        in size_t id,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        auto var = dot.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable is null)
            return;

        if (!isNativeScalarType(dot.type))
            return;

        promoteClassCell(variable);
        if ((variable in classCells) is null)
            return;

        fieldPointerPaths[id] = directFieldPathKey(variable, classFieldIndex(dot));
        classFieldPointerObjectIds[id] = locals[variable].classIdentity;
    }

    // Class-receiver sibling of `promoteNestedStructFieldCell` (aggregate
    // composition): `&c.inner.x` where
    // `inner` is a (non-union) struct field of a plain class local `c` and
    // `x` is a scalar field of `inner`. `dot` is the INNER `DotVarExp`
    // (`c.inner.x`, for field `x`); its own `dot.e1` is the OUTER
    // `DotVarExp` (`c.inner`, for field `inner`), whose OWN `e1` must be the
    // root `VarExp` (`c`). Gives the receiver a `classCells` entry
    // (`promoteClassCell`, same as `promoteClassFieldCell`) and records `id`
    // -- the SAME id `addressOfExpression`'s caller already minted via
    // `fieldSnapshotAllocationId` -- in the
    // common `fieldPointerPaths` reverse lookup, so a later deref-read through
    // this id's pointer (`nestedClassStructFieldPointerCellValue`) can find
    // the same cell and field path. A no-op (no cell, no reverse-lookup
    // entry) for anything outside this narrow shape: `dot.e1` not itself a
    // `DotVarExp`, that `DotVarExp`'s own receiver not a plain `VarExp`, the
    // receiver not class-typed, the outer field not a (non-union) struct,
    // the inner field not `native_scalar.isNativeScalarType`, or a receiver
    // whose boxed value isn't a class object -- every one of those leaves
    // `promoteClassCell` itself a no-op (or is never reached), so there is
    // no cell here to point at.
    private void promoteNestedClassStructFieldCell(
        imported!"dmd.expression".DotVarExp dot,
        in size_t id,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        auto innerDot = dot.e1.isDotVarExp;
        if (innerDot is null)
            return;

        auto var = innerDot.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable is null)
            return;

        if (variable.type.toBasetype.isTypeClass is null)
            return;

        auto outerStructType = innerDot.type.toBasetype.isTypeStruct;
        if (outerStructType is null || outerStructType.sym.isUnionDeclaration !is null)
            return;

        if (!isNativeScalarType(dot.type))
            return;

        promoteClassCell(variable);
        if ((variable in classCells) is null)
            return;

        fieldPointerPaths[id] = fieldPathKey(
            variable,
            [classFieldIndex(innerDot), structFieldIndex(dot)],
        );
    }

    // Array-typed-field sibling of `promoteStructFieldCell` above: when `dot`'s
    // receiver resolves to a plain local variable and the field itself is a
    // static
    // array whose element type is `native_scalar.isNativeScalarType`, gives
    // the receiver a `structCells` entry and records `id` in the
    // `structArrayFieldPointerVariables`/`structArrayFieldPointerFieldIndices`
    // reverse lookup, so a later deref-read through this id's pointer
    // (`structArrayFieldPointerCellValue`) can find the same cell and field.
    // A no-op (no cell, no reverse-lookup entry) for a non-`VarExp` receiver,
    // a field that is not a scalar-element static array, or a receiver whose
    // boxed value isn't a struct -- every one of those leaves
    // `promoteStructCell` itself a no-op, so there is no cell here to point
    // at.
    private void promoteStructArrayFieldCell(
        imported!"dmd.expression".DotVarExp dot,
        in size_t id,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        auto var = dot.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable is null)
            return;

        if (!isStaticArrayType(dot.type))
            return;

        auto elementType = dot.type.toBasetype.nextOf.toBasetype;
        if (!isNativeScalarType(elementType))
            return;

        promoteStructCell(variable);
        if ((variable in structCells) is null)
            return;

        structArrayFieldPointerVariables[id] = variable;
        structArrayFieldPointerFieldIndices[id] = structFieldIndex(dot);
    }

    // Class-receiver sibling of `promoteStructArrayFieldCell` above (the other
    // aggregate-composition shape): when `dot`'s receiver resolves to a plain
    // class-typed local variable and the
    // field itself is a static array whose element type is `native_scalar.
    // isNativeScalarType`, gives the receiver a `classCells` entry
    // (`promoteClassCell`, same as `promoteClassFieldCell`) and records `id`
    // in the `classArrayFieldPointerVariables`/`classArrayFieldPointerFieldIndices`
    // reverse lookup, so a later deref-read through this id's pointer
    // (`classArrayFieldPointerCellValue`) can find the same cell and field.
    // A no-op (no cell, no reverse-lookup entry) for a non-`VarExp` receiver,
    // a receiver that is not class-typed, a field that is not a
    // scalar-element static array, or a receiver whose boxed value isn't a
    // class object -- every one of those leaves `promoteClassCell` itself a
    // no-op, so there is no cell here to point at. Also a no-op for a struct
    // receiver: `promoteClassCell` requires `variable.type.toBasetype.
    // isTypeClass`, which is `null` for a struct, mirroring
    // `promoteClassFieldCell`'s own no-op for that shape.
    private void promoteClassArrayFieldCell(
        imported!"dmd.expression".DotVarExp dot,
        in size_t id,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        auto var = dot.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable is null)
            return;

        if (variable.type.toBasetype.isTypeClass is null)
            return;

        if (!isStaticArrayType(dot.type))
            return;

        auto elementType = dot.type.toBasetype.nextOf.toBasetype;
        if (!isNativeScalarType(elementType))
            return;

        promoteClassCell(variable);
        if ((variable in classCells) is null)
            return;

        classArrayFieldPointerVariables[id] = variable;
        classArrayFieldPointerFieldIndices[id] = classFieldIndex(dot);
    }

    // One level of struct-field nesting: `&s.inner.x` where `inner` is a
    // (non-union) struct field of a plain struct local `s` and `x` is a
    // scalar field of `inner`. `dot` is the INNER `DotVarExp` (`s.inner.x`,
    // for the field `x`); its own `dot.e1` is the OUTER `DotVarExp`
    // (`s.inner`, for the field `inner`), detected here directly rather than
    // by a new memoized-id path -- `id` is the SAME id
    // `addressOfExpression`'s caller already minted via
    // `fieldSnapshotAllocationId` (unmemoized for this shape; see the field
    // declarations' own comment above). Gives the receiver a `structCells`
    // entry (`promoteStructCell`, same as `promoteStructFieldCell`/
    // `promoteStructArrayFieldCell`) and records `id` in the
    // common `fieldPointerPaths` reverse lookup, so a later deref-read/write-
    // through this id's pointer (`nestedStructFieldPointerCellValue`/
    // `writeThroughNestedStructFieldPointer`) can find the same cell and
    // field path. A no-op (no cell, no reverse-lookup entry) for anything
    // outside this narrow shape: `dot.e1` not itself a `DotVarExp`, that
    // `DotVarExp`'s own receiver not a plain `VarExp`, the outer field not a
    // (non-union) struct, the inner field not `native_scalar.
    // isNativeScalarType`, or a receiver whose boxed value isn't a struct --
    // every one of those leaves `promoteStructCell` itself a no-op (or is
    // never reached), so there is no cell here to point at.
    private void promoteNestedStructFieldCell(
        imported!"dmd.expression".DotVarExp dot,
        in size_t id,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        auto innerDot = dot.e1.isDotVarExp;
        if (innerDot is null)
            return;

        auto var = innerDot.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable is null)
            return;

        auto outerStructType = innerDot.type.toBasetype.isTypeStruct;
        if (outerStructType is null || outerStructType.sym.isUnionDeclaration !is null)
            return;

        if (!isNativeScalarType(dot.type))
            return;

        promoteStructCell(variable);
        if ((variable in structCells) is null)
            return;

        fieldPointerPaths[id] = fieldPathKey(
            variable,
            [structFieldIndex(innerDot), structFieldIndex(dot)],
        );
    }

    // Array-element sibling of `promoteNestedStructFieldCell` above: `&a[i].
    // inner.x` where `a` is a dynamic array of a (non-union) struct, `inner`
    // is a (non-union) struct field of the element type, and `x` is a scalar
    // field of `inner`. `dot` is the INNER `DotVarExp` (`a[i].inner.x`, for
    // the field `x`); its own `dot.e1` is the OUTER `DotVarExp` (`a[i].inner`,
    // for the field `inner`), whose own `e1` is the `IndexExp` (`a[i]`) --
    // detected here directly, mirroring `promoteNestedStructFieldCell`'s own
    // direct-shape detection rather than a new memoized-path key (this shape
    // was already falling to `fieldSnapshotAllocationId`'s final fresh-id
    // fallback, same as the non-array nested-field case, since `innerDot.e1`
    // is not a `VarExp`). Gives the array variable an `arrayCells` entry
    // (`promoteArrayCell`, same as `arrayPointer`'s `VarExp` branch) and
    // records `id` in the `arrayNestedStructFieldPointerVariables`/
    // `...ElementIndices`/`...OuterFieldIndices`/`...InnerFieldIndices`
    // reverse lookup, so a later deref-read through this id's pointer
    // (`arrayNestedStructFieldPointerCellValue`) can find the same cell,
    // element, and field path. A no-op (no cell, no reverse-lookup entry)
    // for anything outside this narrow shape: `dot.e1` not itself a
    // `DotVarExp`, that `DotVarExp`'s own receiver not an `IndexExp` whose
    // own receiver is a plain `VarExp`, the outer field not a (non-union)
    // struct, the inner field not `native_scalar.isNativeScalarType`, or an
    // array variable whose element type `promoteArrayCell` itself declines
    // (a union element, a non-struct element) -- every one of those leaves
    // `promoteArrayCell` itself a no-op (or is never reached), so there is no
    // cell here to point at.
    //
    // Single-evaluation of the index (2026-07-16): `index.e2` (`a[i++]`'s
    // `i++`) is a general expression and may side-effect. This function must
    // evaluate it exactly once -- to seed `elementIndex` above -- rather than
    // leaving `addressOfExpression`'s caller to separately `runExpression`
    // the whole `dot` chain (which would re-run `index.e2`, a second time,
    // to rebuild the pointer's boxed snapshot). So this function now builds
    // that snapshot itself, indexing the ALREADY-evaluated `elementIndex`
    // directly via `Value.opIndex`/`structFieldAt` -- the same field path
    // `runExpression(dot)` would walk, minus the redundant re-evaluation --
    // and returns `true` with `value` set. Returns `false` (leaving `value`
    // untouched) for every shape described above that this promotion
    // declines outright, none of which have evaluated `index.e2` yet, so the
    // caller's own `runExpression(dot)` fallback remains the sole (first)
    // evaluation for those.
    private bool promoteArrayNestedStructFieldCell(
        imported!"dmd.expression".DotVarExp dot,
        in size_t id,
        out Value value,
    ) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;

        auto innerDot = dot.e1.isDotVarExp;
        if (innerDot is null)
            return false;

        auto index = innerDot.e1.isIndexExp;
        if (index is null)
            return false;

        auto var = index.e1.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable is null)
            return false;

        auto outerStructType = innerDot.type.toBasetype.isTypeStruct;
        if (outerStructType is null || outerStructType.sym.isUnionDeclaration !is null)
            return false;

        if (!isNativeScalarType(dot.type))
            return false;

        promoteArrayCell(variable);
        if ((variable in arrayCells) is null)
            return false;

        const elementIndex = cast(size_t) runExpression(index.e2).asLong;

        arrayNestedStructFieldPointerVariables[id] = variable;
        arrayNestedStructFieldPointerElementIndices[id] = elementIndex;
        const outerFieldIndex = structFieldIndex(innerDot);
        const innerFieldIndex = structFieldIndex(dot);
        arrayNestedStructFieldPointerOuterFieldIndices[id] = outerFieldIndex;
        arrayNestedStructFieldPointerInnerFieldIndices[id] = innerFieldIndex;

        value = runExpression(index.e1)[elementIndex]
            .structFieldAt(outerFieldIndex)
            .structFieldAt(innerFieldIndex);
        return true;
    }

    // Drops `variable`'s `structCells` entry (if any) together with every
    // direct-struct `fieldPointerPaths` reverse-lookup entry that pointed at
    // it: dropping only the forward `structCells`
    // entry would leave
    // a stale `&s.field` pointer's allocation id mapped to `variable`, so a
    // later dereference through that stale id could resolve into whatever
    // cell a subsequent, unrelated binding of the same `VarDeclaration`
    // promotes next instead of correctly finding no cell at all. Called from
    // every fresh-binding site alongside `scalarCells.remove`/
    // `arrayCells.remove`. Collects matching ids before removing rather than
    // mutating `fieldPointerPaths` while iterating it.
    //
    // Also drops field-path memo entries rooted at `variable`: that forward
    // memo -- `fieldSnapshotAllocationId`'s own
    // per-(receiver, field index) cache -- was never cleared by the reverse-
    // lookup cleanup above, so a fresh `&s.field` taken after THIS fresh
    // binding reused the OLD id rather than minting a new one, defeating the
    // very invalidation this function exists for: the reverse-lookup entries
    // just removed would simply be re-created, unchanged, the moment code in
    // the new binding retook the field's address. Without a fresh id, a
    // stale pointer minted under the OLD binding (e.g. held across a
    // recursive call that re-declares `variable`) still resolves -- via
    // `fieldPointerPaths`, re-populated under the SAME id -- into
    // whatever cell THIS binding promotes, instead of correctly declining.
    private void dropStructCell(VarDeclaration variable) {
        structCells.remove(variable);

        size_t[] staleIds;
        foreach (id, path; fieldPointerPaths)
            if (path.root is variable)
                staleIds ~= id;

        foreach (id; staleIds)
            fieldPointerPaths.remove(id);

        // Same stale-id cleanup for the array-typed-field reverse lookup -- a
        // `&s.arr[i]` id left behind here would let a pointer minted BEFORE
        // this fresh binding keep resolving into whatever cell THIS binding
        // promotes next, exactly the bug the scalar-field cleanup above
        // exists to prevent.
        size_t[] staleArrayFieldIds;
        foreach (id, pointedVariable; structArrayFieldPointerVariables)
            if (pointedVariable is variable)
                staleArrayFieldIds ~= id;

        foreach (id; staleArrayFieldIds) {
            structArrayFieldPointerVariables.remove(id);
            structArrayFieldPointerFieldIndices.remove(id);
        }

        removeFieldPathAddressAllocations(variable);
    }

    // Class sibling of `dropStructCell` above: drops `variable`'s `classCells`
    // entry (if any) together with every class `fieldPointerPaths`/
    // `classArrayFieldPointerVariables`
    // reverse-lookup entry (and their field-index siblings) that pointed at
    // it, for the exact same reason `dropStructCell` exists: leaving a stale
    // forward entry behind would let a fresh re-declaration of the same
    // `VarDeclaration` (a loop body re-executing the same `DeclarationExp`,
    // or a recursive call re-declaring the same AST node at a new depth via
    // `child.classCells = classCells.dup`, which shares the underlying
    // `NativeBlock` bytes by reference) go on refreshing the OLD, now-shared
    // cell in place (`writeCelledLocal`'s `classCells` branch) instead of
    // getting a correctly independent one from a fresh `promoteClassCell`.
    // Called from every fresh-binding site alongside `scalarCells.remove`/
    // `dropArrayCell`/`dropStructCell`. Collects matching ids before
    // removing rather than mutating the reverse-lookup maps while iterating
    // them, mirroring `dropStructCell`'s own discipline.
    //
    // Also drops field-path entries rooted at `variable`, same as
    // `dropStructCell`: that forward memo is shared between the struct and
    // class phases (`fieldSnapshotAllocationId` keys it per-`VarDeclaration`
    // regardless of receiver kind), so every current call site already
    // clears it via the accompanying `dropStructCell` call -- removing it
    // again here is a harmless no-op today, kept for parity so this function
    // stays correct on its own if a future call site ever calls it without
    // `dropStructCell`; nested field paths share the same root-keyed map.
    private void dropClassCell(VarDeclaration variable) {
        classCells.remove(variable);

        size_t[] staleFieldIds;
        foreach (id, path; fieldPointerPaths)
            if (path.root is variable)
                staleFieldIds ~= id;

        foreach (id; staleFieldIds) {
            fieldPointerPaths.remove(id);
            classFieldPointerObjectIds.remove(id);
        }

        size_t[] staleArrayFieldIds;
        foreach (id, pointedVariable; classArrayFieldPointerVariables)
            if (pointedVariable is variable)
                staleArrayFieldIds ~= id;

        foreach (id; staleArrayFieldIds) {
            classArrayFieldPointerVariables.remove(id);
            classArrayFieldPointerFieldIndices.remove(id);
        }

        removeFieldPathAddressAllocations(variable);
    }

    // A reference rebind detaches the variable from its former object but
    // does not invalidate pointers already taken into that object. Forget the
    // variable-keyed address memo so a later address-of gets a fresh id;
    // allocation-id-keyed pointer cells continue owning the old storage.
    private void detachClassCell(VarDeclaration variable) {
        classCells.remove(variable);
        removeFieldPathAddressAllocations(variable);
    }

    private void removeFieldPathAddressAllocations(VarDeclaration root) {
        FieldPathKey[] staleKeys;
        foreach (key, _; fieldPathAddressAllocations)
            if (key.root is root)
                staleKeys ~= key;

        foreach (key; staleKeys)
            fieldPathAddressAllocations.remove(key);
    }

    // Array sibling of `dropStructCell` above: drops `variable`'s `arrayCells`
    // entry together with its
    // memoized `arrayAllocations`/`arrayAllocationVariables` id, for exactly
    // the same reason -- `allocationId` memoizes per `VarDeclaration` and was
    // never cleared by the pre-existing `arrayCells.remove` alone, so a
    // fresh `&a[i]` taken after this fresh binding reused the OLD id, and a
    // stale pointer minted under that id before this binding (e.g. passed
    // into a recursive call that re-declares `variable`) kept resolving --
    // via `arrayAllocationVariables`, unchanged -- into whatever cell THIS
    // binding promotes next, reading the wrong frame's bytes (or indexing
    // past a shorter re-declared array) instead of correctly declining to
    // its own frozen boxed snapshot. Called from every fresh-binding site
    // alongside `scalarCells.remove`/`dropStructCell`.
    //
    // Also drops every `arrayNestedStructFieldPointerVariables` reverse-
    // lookup entry (and its `...ElementIndices`/`...OuterFieldIndices`/
    // `...InnerFieldIndices` siblings) that pointed at `variable`
    // (2026-07-16): `promoteArrayNestedStructFieldCell` (`&a[i].
    // inner.x`) populates these four maps but, unlike every other pointer
    // family's own reverse lookup (`fieldPointerPaths` and the remaining
    // shape-specific maps, all cleaned by
    // `dropStructCell`), nothing here ever cleaned them -- a fresh binding
    // of the same `VarDeclaration` (a loop body re-executing the same
    // `DeclarationExp`) left an EARLIER pointer's id still mapped to
    // `variable`, so dereferencing it after the fresh binding resolved into
    // THIS binding's freshly-promoted cell instead of correctly declining to
    // the earlier binding's own frozen snapshot. No separate memo to clear
    // here (unlike the aggregate field-path memo maps
    // above): this shape's receiver is never a plain `VarExp`, so
    // `fieldSnapshotAllocationId` always takes its fresh-id fallback for it
    // and there is nothing memoized per-variable to invalidate. Collects
    // matching ids before removing rather than mutating the maps while
    // iterating them, mirroring `dropStructCell`'s own discipline.
    private void dropArrayCell(VarDeclaration variable) {
        arrayCells.remove(variable);
        arrayAllocationAliases.remove(variable);

        if (auto id = variable in arrayAllocations) {
            arrayAllocationVariables.remove(*id);
            arrayAllocations.remove(variable);
        }

        size_t[] staleNestedFieldIds;
        foreach (id, pointedVariable; arrayNestedStructFieldPointerVariables)
            if (pointedVariable is variable)
                staleNestedFieldIds ~= id;

        foreach (id; staleNestedFieldIds) {
            arrayNestedStructFieldPointerVariables.remove(id);
            arrayNestedStructFieldPointerElementIndices.remove(id);
            arrayNestedStructFieldPointerOuterFieldIndices.remove(id);
            arrayNestedStructFieldPointerInnerFieldIndices.remove(id);
        }
    }

    // Drops the cell families that every fresh local or parameter binding
    // invalidates. Class cells are deliberately excluded: declarations drop
    // them separately, while parameter binding retains its existing class
    // alias state.
    private void dropNonClassCells(VarDeclaration variable) {
        scalarCells.remove(variable);
        dropArrayCell(variable);
        dropStructCell(variable);
    }

    // A declaration introduces fresh storage for every cell family. Keep this
    // separate from `dropNonClassCells`: parameter binding deliberately
    // preserves class cells because they carry the caller's object alias.
    private void dropDeclarationCells(VarDeclaration variable) {
        dropNonClassCells(variable);
        dropClassCell(variable);
    }

    // Reads `variable`'s current value: a promoted `scalarCells` entry (the
    // byte-level authority once `&variable` has promoted one) takes
    // priority over the boxed `locals` mirror, which in turn takes priority
    // over the type's default. Every celled-var read arm that has no extra
    // fallback of its own (a data-segment initializer, a differently-typed
    // pointee) routes through this single helper so no future read path can
    // pick the wrong map.
    private Value readCelledLocal(VarDeclaration variable) {
        import quickbite.backends.interpreter.native_scalar: readScalar;

        if (auto cell = variable in scalarCells)
            return readScalar(variable.type, cell.bytes);

        if (auto cell = variable in arrayCells)
            if (auto current = variable in locals)
                return arrayValueFromCell(*current, *cell);

        if (auto current = variable in locals)
            return *current;

        return defaultValue(variable);
    }

    // Writes `value` -- already `variable`'s own storage type -- to
    // `variable`, refreshing its promoted `scalarCells`/`arrayCells` entry
    // (if one exists) and re-deriving (or keeping current with) the boxed
    // `locals` mirror, so the two never drift no matter which a later read
    // consults -- including the cross-frame `ref` array-parameter writeback
    // gap. This is the ONLY
    // call site `writeBackRefArguments` routes a `ref int[]` parameter's
    // final value through (`writeLocation`'s plain-`VarExp` arm) -- without
    // the `arrayCells` branch below, a caller whose array already had a cell
    // promoted (an earlier `&a[i]`) kept reading the STALE cell (`
    // runIndexExpression`'s cell-priority read, and any pointer's deref-read)
    // even after a callee mutated the array in place through a `ref`
    // parameter and the boxed `locals` mirror was correctly refreshed here.
    // Callers that write through a differently-typed pointee (a reinterpret
    // write) do not use this helper; see `writeLocation`'s `PtrExp` arm.
    //
    // `arrayIsRefWriteback` distinguishes the ref-writeback caller above (an
    // aliased `ref int[]`
    // parameter's final value genuinely representing the SAME storage,
    // mutated in place inside the callee) from every OTHER caller of this
    // function reached via `writeLocation`'s plain-`VarExp` arm, i.e. a
    // plain source-level `s = b;`, which REBINDS `s` to `b`'s storage rather
    // than mutating whatever `s` used to alias. Only the former may refresh
    // a same-length `arrayCells` entry in place; every other array write
    // through this helper drops the cell unconditionally, matching a rebind
    // that cannot be represented as an in-place byte mutation.
    //
    // A cross-frame writeback caller's `true` does NOT always mean "genuinely
    // the same storage" -- the callee may
    // have REBOUND the ref/captured array to a brand-new same-length array
    // (`p = [x, y];`) rather than mutated it in place, and an in-place
    // refresh would then overwrite the bytes a separate, still-live alias
    // (e.g. a pre-existing slice view of the OLD storage) legitimately
    // keeps pointing at. `writeBackNestedLocals`, `writeBackArrayPointerTargets`,
    // and `writeBackRefArguments` no longer pass a hardcoded `true`: each
    // computes it via `arrayWritebackIsMutation`, which reads the callee's
    // own `arrayRebinds` marker (set by THIS function, below) to tell a
    // genuine mutation apart from a rebind before deciding whether the
    // parent's own cell may be refreshed in place or must be dropped.
    // `classFieldRefresh` is the class-typed sibling of `arrayIsRefWriteback`
    // just above, with the polarity flipped: `true` means "this value is an
    // AUTHORITATIVE same-object field-write refresh" (only
    // `writeLocation`'s `DotVarExp`/class-array-field write arms, and
    // `writeThroughSliceAlias`'s class-field arm, pass `true` -- each first
    // re-derives its receiver from the shared cell via
    // `classCellOverlaidValue`/`classValueFromCell` before folding in the ONE
    // field that changed, so refreshing every scalar field from `value` here
    // is safe). The default `false` covers every other caller reached via
    // `writeLocation`'s plain-`VarExp` arm -- a same-frame `c = b;`
    // (`runAssignExpression`), a fresh declaration's initializer, or a
    // cross-frame writeback -- and a class has no `opAssign`, so the
    // language's own semantics make every one of those a reference REBIND,
    // never a field mutation of the SAME object. Refreshing a (possibly
    // SHARED) cell in place from a rebind's new value would silently splice
    // the new object's fields into whatever OTHER alias still shares the old
    // cell (the exact corruption this avoids); dropping it instead (`dropClassCell`)
    // and marking `classRebinds` matches `arrayCells`'s own decline-rather-
    // than-corrupt choice for a changed-identity rebind, and leaves the
    // caller's own alias bookkeeping (`registerClassAliasIfPlainVar`/
    // `registerClassArgumentAliases`/`registerClassThisAlias`, which every
    // known rebind site calls right after) to associate the correct new cell.
    private void writeCelledLocal(
        VarDeclaration variable,
        in Value value,
        in bool arrayIsRefWriteback = false,
        in bool classFieldRefresh = false,
    ) {
        import quickbite.backends.interpreter.native_scalar:
            readScalar, writeScalar;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        if (auto cell = variable in scalarCells) {
            writeScalar(variable.type, cell.bytes, value);
            setLocal(variable, readScalar(variable.type, cell.bytes));
            uninitializedLocals.remove(variable);
            return;
        }

        if (auto cell = variable in arrayCells) {
            // A static-array assignment always mutates its fixed storage;
            // likewise, a same-length value written back from a `ref`
            // dynamic-array parameter's callee-side mutation is in-place.
            // Refresh every element's bytes in either case so the cell agrees
            // with the mirror. Other dynamic-array writes here are REBINDS
            // (a plain `s = b;`, or a ref-writeback whose length genuinely
            // changed): the cell can no longer faithfully represent whatever
            // new storage `variable` now denotes, so drop it rather than let
            // a stale cell keep answering reads -- the same
            // decline-rather-than-corrupt choice `promoteSliceArrayCell`
            // already makes for a drifted source length.
            if (
                (arrayIsRefWriteback || isStaticArrayType(variable.type)) &&
                value.isArray && value.length == cell.length
            ) {
                foreach (index; 0 .. value.length)
                    writeArrayCellElement(*cell, index, value[index]);
            } else {
                // A rebind's cell drop must also drop the memoized
                // allocation id (`dropArrayCell`, not a bare `arrayCells.
                // remove`) -- the same per-binding fresh-id principle the
                // other fresh-binding sites already apply: an id left behind
                // here would let a
                // pointer minted BEFORE this rebind keep resolving, via the
                // still-live reverse map, into whatever cell the REBOUND
                // array's own next address-of promotes, instead of
                // correctly declining to its own frozen snapshot.
                dropArrayCell(variable);
                if (value.isArray)
                    arrayRebinds[variable] = true;
            }
        } else if (!arrayIsRefWriteback && value.isArray) {
            // No cell existed for `variable` at all, but this is still a
            // plain (non-writeback) whole-array assignment -- e.g. a `ref
            // int[] p` parameter rebound (`p = [x, y];`) without ever having
            // `&p[i]` taken, so `promoteArrayCell` never ran for it. Mark the
            // rebind anyway: `writeBackRefArguments` resolves its writeback
            // decision against `p`'s own `arrayRebinds` entry, and cell
            // presence alone cannot tell this apart from an element-level
            // mutation that similarly never promoted a cell (`p[0] = x;`).
            arrayRebinds[variable] = true;
        }

        // Same in-place-mutation refresh, for a struct local's `structCells`
        // entry: `writeLocation`'s
        // `DotVarExp` arm always rewrites the WHOLE struct (`receiver.
        // withStructField(fieldIndex, value)`) before reaching here, so this
        // refreshes every scalar field's bytes rather than just the one that
        // changed -- the same whole-value refresh `arrayCells` above performs
        // for a same-length array write. A boxed value that is no longer a
        // struct (a genuinely different rebinding) cannot be represented in
        // the cell, so the cell is dropped rather than corrupted, mirroring
        // the array branch's own decline-rather-than-corrupt choice.
        if (auto cell = variable in structCells) {
            if (value.isStruct)
                writeStructCellScalarFields(*cell, value);
            else
                structCells.remove(variable);
        }

        // Class sibling of the struct refresh above. Unlike the struct branch
        // above, a plain class
        // assignment through a `VarExp` target is NOT always a refresh of the
        // SAME object -- classes have no `opAssign`, so `writeLocation`'s
        // plain-`VarExp` arm serves both a genuine reference REBIND (`c =
        // b;`) and a same-object field-write refresh recursing back from the
        // `DotVarExp`/class-array-field write arms, and only the caller knows
        // which via `classFieldRefresh`. Only an authoritative refresh
        // (`classFieldRefresh` AND still a class object) may overwrite the
        // cell in place; every other case -- a rebind, or a boxed value that
        // is no longer a class object -- drops the cell (`dropClassCell`, not
        // a bare `classCells.remove`, so stale field-pointer reverse-lookup
        // entries do not survive it either) rather than splicing a possibly
        // unrelated object's fields into a cell another alias may still
        // share, and marks the rebind so a cross-frame writeback caller
        // (`classWritebackIsMutation`) knows not to refresh the parent's own
        // cell in place either.
        //
        // A nested-function-capture cross-frame analog of the same-frame
        // hazard above: the rebind marker
        // used to be set only `if (value.isClassObject)`, so a rebind THROUGH
        // an intermediate `null` (`c = null; c = new C(2); c.x = 5;`, a
        // nested function reassigning a captured aliased class variable)
        // dropped THIS frame's cell -- correctly, `c` no longer denotes the
        // shared object -- without marking the rebind, because `null` is not
        // a class object. `classWritebackIsMutation` then read an absent
        // marker as "child never rebound this" and told the cross-frame
        // writeback to refresh the PARENT's cell in place, splicing the
        // child's brand-new, unrelated object into a buffer another alias
        // (`a` in the example) still shares -- the exact corruption the
        // same-frame fix above closed, reopened cross-frame,
        // and nondeterministic besides (whichever captured variable
        // `writeBackNestedLocals`'s AA-order iteration happens to reconcile
        // last wins the shared buffer). A plain `VarExp` write to a
        // class-typed variable is a rebind whenever it is not an
        // authoritative same-object field refresh, independent of what kind
        // of value it rebinds TO -- so the marker is set unconditionally in
        // the drop branch below, matching `dropClassCell`'s own unconditional
        // drop. The `else if` mirrors `arrayRebinds`'s own no-cell-yet branch
        // above: a rebind reached with no live cell at all (e.g. the SECOND
        // rebind in the chain above, once the first already dropped it) still
        // must leave the marker set for a cross-frame caller to see.
        if (auto cell = variable in classCells) {
            if (classFieldRefresh && value.isClassObject) {
                writeClassCellScalarFields(*cell, variable.type.toBasetype.isTypeClass.sym, value);
            } else {
                detachClassCell(variable);
                classRebinds[variable] = true;
            }
        } else if (!classFieldRefresh && variable.type.toBasetype.isTypeClass !is null) {
            classRebinds[variable] = true;
        }

        setLocal(variable, value);
        uninitializedLocals.remove(variable);
    }

    private Value functionPointerValue(FuncDeclaration function_) {
        if (auto id = function_ in functionPointerIds)
            return Value.functionPointerValue(*id);

        const id = ++nextFunctionPointerId;
        functionPointerIds[function_] = id;
        functionPointers[id] = function_;
        return Value.functionPointerValue(id);
    }

    private Value newFunctionPointerValue(FuncDeclaration function_) {
        const id = ++nextFunctionPointerId;
        functionPointers[id] = function_;
        return Value.functionPointerValue(id);
    }

    private Value runDelegateExpression(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        if (delegate_.func is null)
            throw new Exception("Unsupported eval expression: delegate_");

        const functionPointer = newFunctionPointerValue(delegate_.func);
        const contextPointer = delegateContextPointer(delegate_);

        RuntimeDelegate runtime;
        runtime.function_ = delegate_.func;
        runtime.functionPointerId = functionPointer.functionPointerId;
        runtime.contextPointer = contextPointer;
        if (isMemberFunction(delegate_.func)) {
            if (delegate_.e1 is null)
                throw new Exception("Unsupported eval expression: delegate_");

            runtime.receiver = runExpression(delegate_.e1);
            runtime.hasReceiver = true;
        }

        delegates[functionPointer.functionPointerId] = runtime;
        return functionPointer;
    }

    private Value runFunctionLiteralDeclaration(
        imported!"dmd.expression".FuncExp literal,
    ) {
        if (literal.fd is null)
            throw new Exception("Unsupported eval expression: functionLiteral");

        const functionPointer = newFunctionPointerValue(literal.fd);

        RuntimeDelegate runtime;
        runtime.function_ = literal.fd;
        runtime.functionPointerId = functionPointer.functionPointerId;
        runtime.contextPointer = Value.pointerValue(Value.void_);
        if (literal.fd.isNested && hasThis) {
            runtime.receiver = thisValue;
            runtime.hasReceiver = true;
        }

        delegates[functionPointer.functionPointerId] = runtime;
        return functionPointer;
    }

    private Value delegateContextPointer(
        imported!"dmd.expression".DelegateExp delegate_,
    ) {
        if (delegate_.e1 !is null) {
            if (auto var = delegate_.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    return localPointerValue(variable);
        }

        return Value.pointerValue(Value.void_);
    }

    private Value runPointerExpression(
        imported!"dmd.expression".PtrExp pointer,
    ) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        const value = runExpression(pointer.e1);
        if (value.isFunctionPointer)
            return value;

        if (isStaticArrayType(pointer.type))
            return staticArrayPointerView(value, pointer.e1.type, pointer.type);

        if (value.isNativePointer)
            return loadNativePointerElement(pointer.e1.type, value, 0);

        if (!value.isLocalPointer) {
            Value cellValue;
            if (pointerCellValue(value, cellValue))
                return cellValue;

            // A plain LOCAL static array (`int[3] a;`) never gets an
            // `arrayCells` entry -- `promoteArrayCell` guards on
            // `isDynamicArrayType` -- so none of the cell checks above ever
            // fire for `&a[i]`. Its pointer is still array-allocation-backed
            // (`arrayPointer`/`symbolOffsetLocalValue` both mint one via
            // `allocationId`), so a direct index write to `a` after the
            // pointer was taken lands in `locals[variable]`, not in any
            // cell -- exactly the case `readPointerElement` (the same
            // fresh-`locals` re-read already used for `p[i]` indexing
            // through this same pointer kind) already handles. Reusing it
            // here instead of the raw `value.pointerTarget` snapshot fixes
            // that one gap; for every pointer kind `arrayPointerVariable`
            // doesn't recognise (e.g. a `&s.field` snapshot pointer),
            // `readPointerElement` itself falls back to `pointer.
            // pointerIndex(0)`, identical to the old `value.pointerTarget`
            // (`pointerTarget` is defined as `pointerIndex(0)`), so no other
            // pointer kind's behaviour changes.
            return readPointerElement(pointer.e1.type, value, 0);
        }

        auto variable = value.localPointerId in localPointers;
        if (variable is null)
            throw new Exception("Unsupported interpreter pointer target.");

        if (auto cell = *variable in scalarCells) {
            import quickbite.backends.interpreter.layout: typeByteSize;
            import quickbite.backends.interpreter.native_scalar:
                isNativeScalarType, readScalar;
            import quickbite.backends.interpreter.native_struct: NativeStruct;
            import quickbite.backends.interpreter.runtime_values: defaultValue;

            auto target = pointer.e1.type.toBasetype.nextOf.toBasetype;
            const targetSize = typeByteSize(target);
            if (targetSize <= cell.bytes.length) {
                if (isNativeScalarType(target))
                    return readScalar(target, cell.bytes[0 .. targetSize]);

                if (auto structType = target.isTypeStruct)
                    if (structType.sym.isUnionDeclaration is null) {
                        auto view = NativeStruct.adopt(
                            cell.subRange(0, targetSize),
                            structType,
                        );
                        return structValueFromCell(defaultValue(target), view);
                    }
            }
        }

        return readCelledLocal(*variable);
    }

    private Value staticArrayPointerView(
        in Value pointer,
        imported!"dmd.mtype".Type pointerType,
        imported!"dmd.mtype".Type staticArrayType,
    ) {
        import quickbite.backends.interpreter.layout: staticArrayLength;

        auto staticArray = staticArrayType.toBasetype.isTypeSArray;
        const length = staticArrayLength(staticArray);
        const target = pointer.isNativePointer
            ? loadNativePointerElement(pointerType, pointer, 0)
            : pointerTargetValue(pointer);
        if (AggregateValue.isArray(target))
            return target;

        Value[] elements;
        foreach (index; 0 .. length)
            elements ~= pointer.pointerIndex(index);

        return Value.arrayValue(elements);
    }

    private Value[] arrayElements(in Value value) {
        Value[] elements;
        foreach (index; 0 .. AggregateValue.length(value))
            elements ~= AggregateValue.elementAt(value, index);

        return elements;
    }

    private Value[] arrayPointerElements(in Value value) {
        return AggregateValue.isArray(value)
            ? value.arrayAllocationElements
            : arrayElements(value);
    }

    private long arrayPointerOffset(in Value value, in long offset) {
        return AggregateValue.isArray(value)
            ? cast(long) value.arrayAllocationOffset + offset
            : offset;
    }

    // pointers into the same array local share an opaque allocation id so
    // that identity and ordering survive the copy-on-write value model
    private size_t allocationId(VarDeclaration variable) {
        if (auto id = variable in arrayAllocations)
            return *id;

        arrayAllocations[variable] = ++allocationCount;
        arrayAllocationVariables[arrayAllocations[variable]] = variable;
        return arrayAllocations[variable];
    }

    private Value localPointerByteSlice(
        in Value pointer,
        in size_t lower,
        in size_t upper,
    ) {
        import std.conv: text;

        auto variable = pointer.localPointerId in localPointers;
        if (variable is null)
            throw new Exception("Unsupported interpreter pointer target.");

        if ((*variable in locals) is null)
            setLocal(*variable, defaultValue(*variable));

        const allocation = scalarBytes((*variable).type, localPointerTarget(pointer));
        if (lower > upper || upper > allocation.length)
            throw new Exception(text(
                "pointer slice `[", lower, "..", upper,
                "]` exceeds allocated memory block `[0..",
                allocation.length,
                "]`",
            ));

        return Value.arraySliceValue(
            allocation[lower .. upper],
            allocation,
            lower,
            allocationId(*variable),
        );
    }

    private Value runConditionalExpression(
        imported!"dmd.expression".CondExp conditional,
    ) {
        return isTruthy(runExpression(conditional.econd)) ?
            runExpression(conditional.e1) :
            runExpression(conditional.e2);
    }

    private Value runIdentityExpression(
        imported!"dmd.expression".IdentityExp identity,
    ) {
        import dmd.tokens: EXP;

        const left = runExpression(identity.e1);
        const right = runExpression(identity.e2);
        // dmd lowers a POD struct's `==` (no user-defined `opEquals`) into an
        // `is` expression (`IdentityExp`), since memberwise equality and
        // bitwise identity coincide for such structs. Route that case through
        // `equalValues` (the same field-recursive, numeric-scalar-coercing
        // comparison a direct `==` uses) instead of a raw `Value` compare: a
        // struct field written by anything other than an enum-typed literal
        // `IntegerExp` (default-init, a decoded value, ...) keeps a plain
        // scalar `Value` rather than the `EnumValue` variant `runExpression`
        // tags a literal `Enum.Member` reference with, so a raw compare of
        // two otherwise-identical structs falsely disagrees whenever one
        // side's enum field took a different path to the same value. Other
        // `is` comparisons (pointers, class references, floats) keep their
        // existing raw-value identity semantics. Array-pointer snapshots can
        // contain different element copies while still naming the same
        // allocation and offset; those two fields are their identity.
        const same = isBoxedPointer(left) && isBoxedPointer(right) &&
                left.pointerAllocation != 0 && right.pointerAllocation != 0
            ? left.pointerAllocation == right.pointerAllocation &&
                left.pointerElementOffset == right.pointerElementOffset
            : AggregateValue.isStruct(left) && AggregateValue.isStruct(right)
                ? equalValues(left, right)
                : left == right;
        if (identity.op == EXP.notIdentity)
            return Value(!same);

        return Value(same);
    }

    private Value runCallExpression(imported!"dmd.expression".CallExp call) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.builtins:
            binaryBuiltinCall,
            interpreterBuiltinArgumentCount,
            tryInterpreterBuiltin,
            unaryBuiltinCall;

        if (call.f !is null) {
            import dmd.funcsem: functionSemantic3;
            functionSemantic3(call.f);
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

                with (InterpreterBuiltin) final switch (builtin) {
                    case fabs:
                    case isInfinity:
                    case signbit:
                    case sqrt:
                        return unaryBuiltinCall(
                            builtin,
                            runExpression((*call.arguments)[0]),
                        );

                    case pow:
                        return binaryBuiltinCall(
                            builtin,
                            runExpression((*call.arguments)[0]),
                            runExpression((*call.arguments)[1]),
                        );
                }
            }
        }

        if (call.f !is null && isDruntimeArrayOpAddAssign(call.f)) {
            import quickbite.backends.interpreter.interception_guard:
                enforceInterceptionPolicy;

            enforceInterceptionPolicy(call.f, "isDruntimeArrayOpAddAssign");
            return runArrayOpAddAssignCall(call);
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins:
                AssocArrayHook, tryAssocArrayHook;

            AssocArrayHook assocArrayHook;
            if (tryAssocArrayHook(call.f, assocArrayHook)) {
                import quickbite.backends.interpreter.interception_guard:
                    enforceInterceptionPolicy;

                enforceInterceptionPolicy(call.f, "tryAssocArrayHook");
                return runAssocArrayHookCall(call, assocArrayHook);
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

        Value[] arguments;
        Expression[] argumentExpressions;
        EvaluatedReferenceArgument[] evaluatedArguments;
        if (call.arguments !is null) {
            foreach (index, argument; *call.arguments) {
                auto parameter = call.f is null ||
                    call.f.parameters is null ||
                    index >= call.f.parameters.length
                    ? null
                    : (*call.f.parameters)[index];
                EvaluatedReferenceArgument evaluated;
                if (parameter !is null && parameterIsLazy(parameter))
                    arguments ~= Value.undisplayable;
                else if (parameter !is null && parameter.isReference)
                    arguments ~= runRefArgumentExpression(argument, evaluated);
                else
                    arguments ~= runExpression(argument);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
            }
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins:
                isStdConvText, stdConvTextCall;

            if (isStdConvText(call.f)) {
                import quickbite.backends.interpreter.interception_guard:
                    enforceInterceptionPolicy;
                import quickbite.frontend.dmd.types: isCharacterArrayType;

                enforceInterceptionPolicy(call.f, "isStdConvText");
                // Value no longer preserves the source expression type, but
                // std.conv.text renders char[] arguments as raw string text.
                bool[] rawStringArguments;
                foreach (argumentExpression; argumentExpressions)
                    rawStringArguments ~= isCharacterArrayType(
                        argumentExpression.type,
                    );
                return stdConvTextCall(arguments, rawStringArguments);
            }
        }

        if (auto dot = call.e1.isDotVarExp) {
            const receiver = runExpression(dot.e1);
            if (receiver == Value.null_)
                throw new Exception(
                    "function call through null class reference `null`",
                );

            if (call.f !is null && call.f.needThis) {
                import quickbite.frontend.dmd.functions:
                    hasNoAvailableSource, noAvailableSourceMessage;
                import quickbite.ffi: unsupportedNativeTypeMessage;

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
                if (hasNoAvailableSource(function_)) {
                    import quickbite.backends.interpreter.ffi_marshal:
                        NativeCallException, tryCallNativeConstructor,
                        tryCallNativeMember, tryCallNativeClassMember;

                    Value result;
                    Value[] writebacks;
                    Value receiverWriteback;
                    try {
                        // Constructors and postblits build/copy a native struct
                        // and yield the (post-call) receiver as the expression
                        // value, not their ABI return (ffi.md §34.13).
                        if (auto structType = receiverStructType(dot.e1)) {
                            // A body-less constructor: the receiver `tracked` is
                            // not yet a struct (it is the variable being
                            // constructed), so seed `this` from the struct's
                            // default `.init` and reify the constructed struct
                            // from the receiver buffer.
                            if (function_.isCtorDeclaration !is null) {
                                if (tryCallNativeConstructor(
                                    function_,
                                    structType,
                                    nativeConstructorReceiver(function_, receiver),
                                    arguments,
                                    nativeArgumentTypes(argumentExpressions),
                                    nativeAddressOfLocalArguments(argumentExpressions),
                                    result,
                                    writebacks,
                                )) {
                                    applyNativeWritebacks(writebacks, argumentExpressions);
                                    return result;
                                }
                            }
                            // A body-less postblit runs on the freshly blitted
                            // copy (already evaluated as `receiver`) and returns
                            // void; the value of `copy = original` is the
                            // postblit-mutated receiver, not that void return.
                            else if (function_.isPostBlitDeclaration !is null) {
                                if (tryCallNativeMember(
                                    function_,
                                    structType,
                                    receiver,
                                    arguments,
                                    nativeArgumentTypes(argumentExpressions),
                                    nativeAddressOfLocalArguments(argumentExpressions),
                                    result,
                                    writebacks,
                                    receiverWriteback,
                                )) {
                                    applyNativeWritebacks(writebacks, argumentExpressions);
                                    return receiverWriteback == Value.void_
                                        ? receiver
                                        : receiverWriteback;
                                }
                            }
                        }

                        // A native class receiver dispatches virtually through
                        // the object's vtable and is mutated in place, so it has
                        // no receiver writeback (ffi.md §34.12). A struct
                        // receiver marshals its bytes and may write them back
                        // (§34.9).
                        if (auto classType = receiverClassType(dot.e1)) {
                            if (tryCallNativeClassMember(
                                function_,
                                classType,
                                receiver,
                                arguments,
                                nativeArgumentTypes(argumentExpressions),
                                nativeAddressOfLocalArguments(argumentExpressions),
                                result,
                                writebacks,
                            )) {
                                applyNativeWritebacks(writebacks, argumentExpressions);
                                return result;
                            }
                        } else if (tryCallNativeMember(
                            function_,
                            receiverStructType(dot.e1),
                            receiver,
                            arguments,
                            nativeArgumentTypes(argumentExpressions),
                            nativeAddressOfLocalArguments(argumentExpressions),
                            result,
                            writebacks,
                            receiverWriteback,
                        )) {
                            applyNativeWritebacks(writebacks, argumentExpressions);
                            applyReceiverWriteback(dot.e1, receiverWriteback);
                            return result;
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
                );
            }
        }

        if (call.f !is null) {
            import quickbite.frontend.dmd.functions:
                hasNoAvailableSource, noAvailableSourceMessage;
            import quickbite.ffi: unsupportedNativeTypeMessage;
            import quickbite.backends.interpreter.ffi_marshal:
                InterpreterInboundTrampolineSession, NativeCallException,
                tryCallNative;

            if (hasNoAvailableSource(call.f)) {
                import quickbite.backends.interpreter.ffi_marshal:
                    PointerElementsWriteback;

                Value result;
                Value[] writebacks;
                PointerElementsWriteback[] pointerWritebacks;
                try {
                    if (durableInboundSession is null)
                        durableInboundSession = new InterpreterInboundTrampolineSession(
                            &invokeNativeCallback,
                        );
                    if (
                        !call.f.needThis &&
                        tryCallNative(
                            call.f,
                            nativeCellPointerArguments(
                                arguments,
                                nativeArgumentTypes(argumentExpressions),
                            ),
                            nativeArgumentTypes(argumentExpressions),
                            nativeAddressOfLocalArguments(argumentExpressions),
                            nativeOutParameterInputValues(argumentExpressions),
                            &invokeNativeCallback,
                            durableInboundSession,
                            result,
                            writebacks,
                            pointerWritebacks,
                        )
                    ) {
                        applyNativeWritebacks(writebacks, argumentExpressions);
                        applyPointerElementsWritebacks(pointerWritebacks);
                        return result;
                    }
                } catch (NativeCallException exception) {
                    throwNativeException(exception);
                }

                // An FFI-uncrossable signature type (e.g. an associative array,
                // ffi.md §34.3.1 item 0) gets an honest diagnostic naming the
                // type rather than the misleading no-available-source message.
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
                    thisValue,
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                );

            return runFunction(
                call.f,
                arguments,
                argumentExpressions,
                false,
                evaluatedArguments,
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
                );

        if (auto function_ = functionPointerExpressionFunction(call.e1)) {
            if (isZeroFormalCall(function_) && arguments.length == 5) {
                if (functionName(function_) == "enforceRawArraysConformableNogc") {
                    import quickbite.backends.interpreter.interception_guard:
                        enforceInterceptionPolicy;

                    enforceInterceptionPolicy(
                        function_,
                        "enforceRawArraysConformableNogc",
                    );
                    return Value(false);
                }

                throw new Exception("Unsupported eval call.");
            }
            if (function_.isNested && hasThis)
                return runMemberFunction(
                    function_,
                    null,
                    thisValue,
                    arguments,
                    argumentExpressions,
                    evaluatedArguments,
                );

            return runFunction(
                function_,
                arguments,
                argumentExpressions,
                false,
                evaluatedArguments,
            );
        }

        if (auto variable = lazyCallVariable(call))
            return runLazyArgument(variable);

        const callee = runExpression(call.e1);
        if (callee.isNativeDelegate)
            return runNativeDelegateCall(
                callee,
                call,
                arguments,
                argumentExpressions,
            );

        if (callee.isFunctionPointer && callee.functionPointerId in delegates)
            return runDelegateCall(
                callee,
                arguments,
                argumentExpressions,
                evaluatedArguments,
            );

        if (callee.isFunctionPointer) {
            auto function_ = callee.functionPointerId in functionPointers;
            if (function_ is null)
                throw new Exception("Unsupported eval call.");
            return runFunction(
                *function_,
                arguments,
                argumentExpressions,
                false,
                evaluatedArguments,
            );
        }

        throw new Exception("Unsupported eval call.");
    }

    // A local pointer whose target has native authoritative storage can cross
    // the FFI seam as that storage's real address. Other local-pointer shapes
    // remain boxed and retain the existing unsupported diagnostic.
    private Value[] nativeCellPointerArguments(
        in Value[] arguments,
        imported!"dmd.mtype".Type[] argumentTypes,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        auto result = arguments.dup; // Replaces eligible pointer values below.
        foreach (index, ref argument; result) {
            if (isBoxedPointer(argument)) {
                if (auto variable = arrayPointerVariable(argument)) {
                    if (auto cell = *variable in arrayCells) {
                        const offset = cast(size_t) argument.pointerElementOffset *
                            typeByteSize(argumentTypes[index].nextOf);
                        argument = Value.nativePointerValue(
                            cell.block.address + offset,
                        );
                        continue;
                    }
                }
            }

            if (!argument.isLocalPointer)
                continue;

            // Mutable lookup preserves the declaration's class qualifier for
            // use as an associative-array key below.
            auto variable = argument.localPointerId in localPointers;
            if (variable is null)
                continue;

            // Mutable because the native callee may write through this address.
            auto cell = *variable in scalarCells;
            if (cell !is null)
                argument = Value.nativePointerValue(cell.address);
        }
        return result;
    }

    // A `ref` argument aliases the caller's storage; compiled D binds the
    // address without reading through it. Evaluating it like an ordinary
    // rvalue throws when the caller's local is still `= void` (cerealed's
    // `ubyte b = void; cereal.grain(b);`, where `grain`'s `ref` parameter is
    // only ever written, never read, before the call). Seed a void
    // placeholder instead of reading; `writeBackRefArguments` overwrites it
    // with whatever the callee actually wrote once the call returns.
    private Value runRefArgumentExpression(
        imported!"dmd.expression".Expression argument,
        out EvaluatedReferenceArgument evaluated,
    ) {
        auto var = argument.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable !is null && variable in uninitializedLocals)
            return Value.void_;

        auto previous = _evaluatedReferenceArgumentIndices;
        _evaluatedReferenceArgumentIndices = &evaluated.indices;
        scope(exit)
            _evaluatedReferenceArgumentIndices = previous;

        return runExpression(argument);
    }

    private Value[] pointerArrayElements(in Value pointer) {
        Value[] elements;
        foreach (index; 0 .. pointer.pointerLength)
            elements ~= pointer.pointerIndex(index);

        return elements;
    }

    private Value readPointerElement(
        imported!"dmd.mtype".Type pointerType,
        in Value pointer,
        in size_t index,
    ) {
        if (pointer.isNativePointer)
            return loadNativePointerElement(pointerType, pointer, index);

        if (auto variable = arrayPointerVariable(pointer)) {
            if (auto current = *variable in locals)
                return (*current)[cast(size_t) pointer.pointerElementOffset + index];
        }

        return pointer.pointerIndex(index);
    }

    // Run an interpreted delegate that native code called back into through the
    // FFI reverse bridge (ffi.md §34.16). The callback supplies only values (no
    // source argument expressions), so synthesise null placeholders, as the
    // static-initialiser delegate path does.
    private Value invokeNativeCallback(
        in Value callee,
        in Value[] arguments,
    ) {
        import dmd.expression: Expression;

        return runDelegateCall(callee, arguments, new Expression[](arguments.length));
    }

    private Value runDelegateCall(
        in Value callee,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
    ) {
        auto runtime = callee.functionPointerId in delegates;
        if (runtime is null)
            throw new Exception("Unsupported eval call.");

        if (runtime.hasReceiver)
            return runMemberFunction(
                runtime.function_,
                null,
                delegateReceiver(*runtime),
                arguments,
                argumentExpressions,
                evaluatedArguments,
            );

        return runFunction(
            runtime.function_,
            arguments,
            argumentExpressions,
            false,
            evaluatedArguments,
        );
    }

    // Call a native delegate the interpreter holds as an opaque
    // {context, funcptr} value reified from a native return (ffi.md §35.8),
    // the inverse of the §34.16 callback bridge.
    private Value runNativeDelegateCall(
        in Value callee,
        imported!"dmd.expression".CallExp call,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        import quickbite.backends.interpreter.ffi_marshal:
            NativeCallException, tryCallNativeDelegate;
        import dmd.mtype: TypeFunction;

        auto delegateType = call.e1.type.toBasetype;
        auto functionType = delegateType.nextOf is null
            ? null
            : cast(TypeFunction) delegateType.nextOf;

        Value result;
        Value[] writebacks;
        try {
            if (tryCallNativeDelegate(
                functionType,
                callee,
                arguments,
                nativeArgumentTypes(argumentExpressions),
                nativeAddressOfLocalArguments(argumentExpressions),
                nativeOutParameterInputValues(argumentExpressions),
                &invokeNativeCallback,
                result,
                writebacks,
            )) {
                applyNativeWritebacks(writebacks, argumentExpressions);
                return result;
            }
        } catch (NativeCallException exception) {
            throwNativeException(exception);
        }

        throw new Exception("Unsupported eval call.");
    }

    private Value delegateReceiver(in RuntimeDelegate runtime) {
        if (runtime.contextPointer.isLocalPointer)
            return localPointerTarget(runtime.contextPointer);

        return runtime.receiver;
    }

    private Value runDelegatePointerExpression(
        imported!"dmd.expression".DelegatePtrExp expression,
    ) {
        return delegateProperty(runExpression(expression.e1), "ptr");
    }

    private Value runDelegateFunctionPointerExpression(
        imported!"dmd.expression".DelegateFuncptrExp expression,
    ) {
        return delegateProperty(runExpression(expression.e1), "funcptr");
    }

    private bool isStringForeachApplyCall(FuncDeclaration function_) const {
        import std.algorithm: canFind;

        const name = functionName(function_);
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

    private Value runStringForeachApplyCall(
        imported!"dmd.expression".CallExp call,
        FuncDeclaration function_,
    ) {
        if (call.arguments is null || call.arguments.length != 2)
            throw new Exception("Unsupported eval call.");

        auto body = functionPointerExpressionFunction((*call.arguments)[1]);
        if (body is null)
            throw new Exception("Unsupported eval call.");

        foreach (value; stringForeachApplyElements(
            functionName(function_),
            runExpression((*call.arguments)[0]),
        )) {
            const result = runFunction(body, [value], [null]);
            if (result != Value.void_ && result.asLong != 0)
                return result;
        }

        return Value(0);
    }

    private Value[] stringForeachApplyElements(
        in string helper,
        in Value source,
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

    private Value[] decodedUtf8Dchars(in Value source) {
        import std.utf: decode;

        string encoded;
        foreach (index; 0 .. AggregateValue.length(source))
            encoded ~= cast(char) AggregateValue.elementAt(source, index)
                .castTo!long.asLong;

        Value[] values;
        size_t index;
        while (index < encoded.length)
            values ~= Value(decode(encoded, index));

        return values;
    }

    private Value[] decodedUtf16Dchars(in Value source) {
        import std.utf: decode;

        wstring encoded;
        foreach (index; 0 .. AggregateValue.length(source))
            encoded ~= cast(wchar) AggregateValue.elementAt(source, index)
                .castTo!long.asLong;

        Value[] values;
        size_t index;
        while (index < encoded.length)
            values ~= Value(decode(encoded, index));

        return values;
    }

    private Value[] utf8EncodedDstringChars(in Value source) {
        import std.utf: encode;

        Value[] values;
        foreach (index; 0 .. AggregateValue.length(source)) {
            char[4] encoded;
            const length = encode(
                encoded,
                cast(dchar) AggregateValue.elementAt(source, index)
                    .castTo!long.asLong,
            );
            foreach (unit; encoded[0 .. length])
                values ~= Value(unit);
        }

        return values;
    }

    private FuncDeclaration resolveMemberFunction(
        FuncDeclaration function_,
        in Value receiver,
    ) {
        if (!AggregateValue.isClass(receiver))
            return function_;

        auto class_ = dynamicClass(receiver);
        if (class_ is null)
            return function_;

        if (auto override_ = overridingFunction(class_, function_))
            return override_;

        if (auto vtbl = vtblFunction(class_, function_))
            return vtbl;

        if (auto candidate = matchingMemberFunction(class_, function_))
            return candidate;

        return function_;
    }

    private imported!"dmd.dclass".ClassDeclaration dynamicClass(in Value value) {
        return dynamicClassDeclarationByName(AggregateValue.classTypeName(value));
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

        string[] operators;
        foreach (argument; *instance.tiargs) {
            auto expression = isExpression(argument);
            if (expression is null)
                continue;

            auto literal = expression.isStringExp;
            if (literal is null)
                return false;

            operators ~= literal.peekString.idup;
        }

        return operators == ["+", "="];
    }

    private Value runArrayOpAddAssignCall(
        imported!"dmd.expression".CallExp call,
    ) {
        if (call.arguments is null || call.arguments.length != 3)
            throw new Exception("Unsupported eval call.");

        auto target = (*call.arguments)[0].isSliceExp;
        if (target is null)
            throw new Exception("Unsupported eval call.");

        const left = runExpression((*call.arguments)[1]);
        const right = runExpression((*call.arguments)[2]);
        if (left.length != right.length)
            throw new Exception("Unsupported eval call.");

        Value[] elements;
        foreach (index; 0 .. left.length)
            elements ~= left[index] + right[index];

        return writeBackSliceElements(target, elements);
    }

    private Value writeBackSliceElements(
        imported!"dmd.expression".SliceExp slice,
        Value[] elements,
    ) {
        auto var = slice.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported eval call.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported eval call.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported eval call.");

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? current.length
            : cast(size_t) runExpression(slice.upr).asLong;
        if (upper - lower != elements.length)
            throw new Exception("Unsupported eval call.");

        Value[] updated;
        foreach (index; 0 .. current.length)
            updated ~= index >= lower && index < upper
                ? elements[index - lower]
                : (*current)[index];

        setLocal(variable, Value.arrayValue(updated));
        uninitializedLocals.remove(variable);
        return locals[variable];
    }

    // core.internal.atomic implements these with inline asm the interpreter
    // cannot execute. Interpretation is single-threaded, so plain reads and
    // writes of the pointed-at value are observably equivalent.
    private Value runAtomicHookCall(
        imported!"dmd.expression".CallExp call,
        in imported!"quickbite.backends.interpreter.builtins".AtomicHook hook,
    ) {
        import quickbite.backends.interpreter.builtins: AtomicHook;

        if (call.arguments is null || call.arguments.length == 0)
            throw new Exception("Unsupported eval call.");

        auto destinationExpression = (*call.arguments)[0];
        const destination = runExpression(destinationExpression);

        Value operand() {
            if (call.arguments.length < 2)
                throw new Exception("Unsupported eval call.");
            return runExpression((*call.arguments)[1]);
        }

        with (AtomicHook) final switch (hook) {
            case aligned:
                return Value(true);

            case load:
                return readPointerTarget(destinationExpression, destination);

            case store:
                writePointerTarget(destinationExpression, destination, operand);
                return Value.void_;

            case exchange: {
                const previous =
                    readPointerTarget(destinationExpression, destination);
                writePointerTarget(destinationExpression, destination, operand);
                return previous;
            }

            case fetchAdd:
            case fetchSub: {
                const previous =
                    readPointerTarget(destinationExpression, destination);
                const delta = hook == fetchAdd
                    ? operand.asLong
                    : -operand.asLong;
                writePointerTarget(
                    destinationExpression,
                    destination,
                    storageValue(
                        destinationExpression.type.toBasetype.nextOf,
                        Value(previous.asLong + delta),
                    ),
                );
                return previous;
            }
        }
    }

    private Value readPointerTarget(
        imported!"dmd.expression".Expression pointerExpression,
        in Value pointer,
    ) {
        if (pointer.isNativePointer)
            return loadNativePointerElement(pointerExpression.type, pointer, 0);

        return pointerTargetValue(pointer);
    }

    // DMD lowers associative array operations to druntime template hooks in
    // `core.internal.newaa` and `object`; interpret the semantics directly
    // instead of executing the druntime hook bodies.
    private Value runAssocArrayHookCall(
        imported!"dmd.expression".CallExp call,
        in imported!"quickbite.backends.interpreter.builtins".AssocArrayHook hook,
    ) {
        import quickbite.backends.interpreter.builtins: AssocArrayHook;

        if (call.arguments is null)
            throw new Exception("Unsupported eval call.");

        with (AssocArrayHook) final switch (hook) {
            case length:
                requireArgumentCount(call, 1);
                return Value(runExpression((*call.arguments)[0]).length);

            case getRvalue:
                requireArgumentCount(call, 2);
                return runAssocArrayReadCall(call);

            case getLvalue:
                requireArgumentCount(call, 3);
                return runAssocArrayLvalueCall(call);

            case in_:
                requireArgumentCount(call, 2);
                return runAssocArrayInCall(call);

            case remove:
                requireArgumentCount(call, 2);
                return runAssocArrayRemoveCall(call);

            case equal:
                requireArgumentCount(call, 2);
                return Value(
                    runExpression((*call.arguments)[0]) ==
                    runExpression((*call.arguments)[1]),
                );

            case dup:
                requireArgumentCount(call, 1);
                return runExpression((*call.arguments)[0]);

            case keys:
                requireArgumentCount(call, 1);
                return runExpression((*call.arguments)[0]).assocArrayKeys;

            case values:
                requireArgumentCount(call, 1);
                return runExpression((*call.arguments)[0]).assocArrayValues;

            case apply2:
                requireArgumentCount(call, 2);
                return runAssocArrayApply2Call(call);
        }
    }

    private void requireArgumentCount(
        imported!"dmd.expression".CallExp call,
        in size_t count,
    ) {
        if (call.arguments is null || call.arguments.length != count)
            throw new Exception("Unsupported eval call.");
    }

    private Value runAssocArrayReadCall(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.messages: missingKeyMessage;

        const aa = runExpression((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        if (!aa.assocArrayContains(key))
            throw new Exception(missingKeyMessage(
                (*call.arguments)[1],
                (*call.arguments)[0],
            ));

        return Value.pointerValue(aa.assocArrayElement(key));
    }

    // `aa[key] = value` lowers to a write through the slot pointer returned
    // by `_d_aaGetY(aa, key, found)`; the write-back happens via the slot
    // alias recorded for the pointer variable
    private Value runAssocArrayLvalueCall(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = runExpression((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);
        const contains = aa.assocArrayContains(key);

        if (auto found = (*call.arguments)[2].isVarExp)
            if (auto foundVariable = found.var.isVarDeclaration)
                setLocal(foundVariable, Value(contains));

        return Value.pointerValue(
            contains
                ? aa.assocArrayElement(key)
                : defaultValue(call.type.toBasetype.nextOf),
        );
    }

    private Value runAssocArrayInCall(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = runExpression((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        return aa.assocArrayContains(key)
            ? Value.pointerValue(aa.assocArrayElement(key))
            : Value.null_;
    }

    private Value runAssocArrayRemoveCall(
        imported!"dmd.expression".CallExp call,
    ) {
        auto var = (*call.arguments)[0].isVarExp;
        if (var is null)
            throw new Exception("Unsupported eval call.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported eval call.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported eval call.");

        const key = runExpression((*call.arguments)[1]);
        const removed = current.assocArrayContains(key);
        setLocal(variable, current.withoutAssocArrayKey(key));
        return Value(removed);
    }

    private Value runAssocArrayApply2Call(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = runExpression((*call.arguments)[0]);
        const keys = aa.assocArrayKeys;
        const values = aa.assocArrayValues;
        auto body = functionPointerExpressionFunction((*call.arguments)[1]);
        const delegate_ = body is null
            ? runExpression((*call.arguments)[1])
            : Value.void_;

        foreach (index; 0 .. keys.length) {
            const arguments = [keys[index], values[index]];
            const result = body is null
                ? runDelegateCall(delegate_, arguments, [null, null])
                : runFunction(body, arguments, [null, null], true);
            if (result.asLong != 0)
                return result;
        }

        return Value(0);
    }

    private Value runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in bool captureLocals = false,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
    ) {
        prepareDirectAggregateFieldRefArgumentAliases(
            function_,
            argumentExpressions,
        );

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.result = Value(false);
        child.locals = (captureLocals || function_.isNested)
            ? locals.dup
            : datasegLocals;
        bindCapturedReferenceSlots(function_, child);
        forkPerFrameCellsInto(child);
        seedPointerTargetLocals(child);
        registerClassArgumentAliases(function_, argumentExpressions, child);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            &classMirrorGenerations,
            evaluatedArguments,
        );
        registerRefAggregateArgumentAliases(function_, argumentExpressions, child);
        registerDirectAggregateFieldRefArgumentAliases(
            function_,
            argumentExpressions,
            child,
        );

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackFunctionState(
                function_,
                argumentExpressions,
                child,
                arguments,
                captureLocals,
            );
            throw exception;
        }
        writeBackFunctionState(
            function_,
            argumentExpressions,
            child,
            arguments,
            captureLocals,
        );
        return child.result;
    }

    private Value runMemberFunction(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        in Value receiver,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
    ) {
        prepareDirectAggregateFieldRefArgumentAliases(
            function_,
            argumentExpressions,
        );

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.result = Value(false);
        child.locals = locals.dup;
        forkPerFrameCellsInto(child);
        if (receiverExpression !is null)
            if (auto var = receiverExpression.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    if (auto aliases = variable in structArrayFieldAliases) {
                        child.thisStructArrayFieldAliases = *aliases;
                        foreach (_, sourceVariable; aliases.sources)
                            if (auto value = sourceVariable in locals)
                                child.setLocal(sourceVariable, *value);
                    }
        // For constructor calls, DMD may blit the target variable to zero
        // before the ctor runs (e.g. `box = 0 , box.this(input)`), so the
        // receiver evaluates to a non-struct scalar.  Seed `thisValue` from
        // the struct's proper default in that case so the ctor body can write
        // fields.  When the receiver is already a valid struct (e.g.
        // MapResult created from a StructLiteralExp with elements), use it
        // as-is to preserve any hidden context fields.
        if (function_.isConstructorFunction && !receiver.isStruct) {
            auto structDecl = function_.constructorStructDeclaration;
            child.thisValue = structDecl !is null
                ? defaultValue(structDecl.type)
                : receiver;
        } else {
            child.thisValue = receiver;
        }
        child.hasThis = true;
        registerClassArgumentAliases(function_, argumentExpressions, child);
        registerClassThisAlias(function_, receiverExpression, child);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            &classMirrorGenerations,
            evaluatedArguments,
        );
        registerRefAggregateArgumentAliases(function_, argumentExpressions, child);
        registerDirectAggregateFieldRefArgumentAliases(
            function_,
            argumentExpressions,
            child,
        );

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackMemberFunctionState(
                function_,
                receiverExpression,
                argumentExpressions,
                child,
                arguments,
            );
            throw exception;
        }
        writeBackMemberFunctionState(
            function_,
            receiverExpression,
            argumentExpressions,
            child,
            arguments,
        );

        if (function_.isConstructorFunction)
            return child.thisValue;

        return child.result;
    }

    private void writeBackFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in Value[] arguments,
        in bool captureLocals = false,
    ) {
        mergeNativeThrowableRoots(child);
        nextLocalPointerId = child.nextLocalPointerId;
        mergeReturnedLocalPointer(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        nextClassObjectId = child.nextClassObjectId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        lazyArgumentFrames = child.lazyArgumentFrames;
        mergePerFrameCellsFrom(child);
        writeBackNestedLocals(function_, child, captureLocals);
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
        writeBackArrayPointerTargets(child);
        writeBackStructFieldPointerTargets(child);
        writeBackStructArrayFieldPointerTargets(child);
        writeBackNestedStructFieldPointerTargets(child);
        writeBackClassFieldPointerTargets(child);
        writeBackNestedClassStructFieldPointerTargets(child);
        writeBackClassArrayFieldPointerTargets(child);
        writeBackRefArguments(function_, argumentExpressions, child, arguments);
        writeBackByValueStructArguments(function_, argumentExpressions, child);
    }

    private void writeBackMemberFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in Value[] arguments,
    ) {
        mergeNativeThrowableRoots(child);
        nextLocalPointerId = child.nextLocalPointerId;
        mergeReturnedLocalPointer(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        nextClassObjectId = child.nextClassObjectId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        lazyArgumentFrames = child.lazyArgumentFrames;
        mergePerFrameCellsFrom(child);
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
        writeBackArrayPointerTargets(child);
        writeBackStructFieldPointerTargets(child);
        writeBackStructArrayFieldPointerTargets(child);
        writeBackNestedStructFieldPointerTargets(child);
        writeBackClassFieldPointerTargets(child);
        writeBackNestedClassStructFieldPointerTargets(child);
        writeBackClassArrayFieldPointerTargets(child);
        writeBackRefArguments(function_, argumentExpressions, child, arguments);
        writeBackThisStructArrayFieldAliases(child);
        child.returned = false;
        writeBackThis(receiverExpression, child.thisValue);
    }

    // A returned array carrier may be the first value that makes a source
    // array's native storage observable in this frame. Adopt exactly that
    // escaping cell after its allocation-id maps have merged. Do not copy the
    // child's whole `arrayCells` table: it also contains callee-local bindings
    // whose `VarDeclaration` keys can be reused by another activation. An
    // existing cell in this frame always wins for the same reason as the
    // forward allocation-id merge above.
    private void mergeReturnedArrayCell(ref Walker child) {
        if (!child.result.isArray || child.result.arrayAllocationId == 0)
            return;

        const id = child.result.arrayAllocationId;
        auto sourceVariable = id in child.arrayAllocationVariables;
        if (sourceVariable is null)
            return;

        auto mergedVariable = id in arrayAllocationVariables;
        if (mergedVariable is null || *mergedVariable !is *sourceVariable)
            return;

        if ((*sourceVariable in arrayCells) !is null)
            return;

        auto cell = *sourceVariable in child.arrayCells;
        if (cell !is null)
            arrayCells[*sourceVariable] = *cell;
    }

    private void mergeNativeThrowableRoots(ref Walker child) {
        foreach (pointer, throwable; child.nativeThrowableRoots)
            nativeThrowableRoots[pointer] = throwable;
    }

    private void mergePerFrameCellsFrom(ref Walker child) {
        foreach (identity, cell; child.classObjectCells)
            classObjectCells[identity] = cell;
        allocationCount = child.allocationCount;
        arrayAllocationAliases = child.arrayAllocationAliases;
        mergeArrayAllocationMaps(child);
        mergeArrayAllocationCarriers(child);
        mergeReturnedArrayCell(child);
        mergeFieldPathAddressAllocations(child);
        fieldSnapshotAllocationIds = child.fieldSnapshotAllocationIds;
        arrayPointerWritebacks = child.arrayPointerWritebacks;
        structFieldPointerWritebacks = child.structFieldPointerWritebacks;
        mergeStructArrayFieldPointerVariableMaps(child);
        structArrayFieldPointerWritebacks = child.structArrayFieldPointerWritebacks;
        nestedStructFieldPointerWritebacks = child.nestedStructFieldPointerWritebacks;
        mergeFieldPointerPaths(child);
        classFieldPointerWritebacks = child.classFieldPointerWritebacks;
        nestedClassStructFieldPointerWritebacks =
            child.nestedClassStructFieldPointerWritebacks;
        mergeClassArrayFieldPointerVariableMaps(child);
        classArrayFieldPointerWritebacks = child.classArrayFieldPointerWritebacks;
    }

    // Non-destructive merge for `arrayAllocations`/`arrayAllocationVariables`
    // after a call returns (the array counterpart of the field-pointer map
    // merges below): a wholesale `= child.X` copy-back would let a callee's
    // own fresh-binding invalidation (`dropArrayCell`) of a
    // stale id it inherited from THIS frame's own dup silently erase THIS
    // frame's still-live entry for the same `VarDeclaration` too, now that
    // id invalidation applies across recursion. Every id is minted from one
    // shared, monotonically increasing `allocationCount` (merged back
    // separately, unconditionally, above), so two frames never disagree
    // about what a given id names. The forward map (`arrayAllocations`)
    // only adopts a variable THIS frame did not already have an entry for --
    // a rebind that happened only in a deeper frame's own copy cannot
    // clobber this frame's own still-valid mapping for the same variable.
    //
    // Follow-up (2026-07-14): the reverse map
    // (`arrayAllocationVariables`) merge used to union every child entry in
    // unconditionally. That routed a child-MINTED id (a fresh rebind's own
    // `&a[i]`, e.g. taken after a recursive callee re-declares the same
    // `VarDeclaration`) into THIS frame's reverse map even when this frame's
    // own forward map already binds that same `VarDeclaration` to a
    // DIFFERENT (this frame's own) id -- and dynamic-array elements are
    // GC-allocated, so a pointer minted under the child's id may legally
    // escape upward (returned from the child) into this frame. Once merged,
    // that escaped pointer resolved through THIS frame's OWN, unrelated cell
    // for the same variable instead of correctly declining. A child entry
    // whose variable this frame's forward map binds to a different id is
    // therefore skipped -- precisely the "same `VarDeclaration`, different
    // binding" condition -- while an entry for a variable this frame has no
    // binding/cell for at all keeps merging unconditionally, since the
    // cross-frame writeback machinery still needs those.
    private void mergeArrayAllocationMaps(ref Walker child) {
        foreach (id, variable; child.arrayAllocationVariables) {
            if (auto ownId = variable in arrayAllocations)
                if (*ownId != id)
                    continue;

            arrayAllocationVariables[id] = variable;
        }

        foreach (variable, id; child.arrayAllocations)
            if (variable !in arrayAllocations)
                arrayAllocations[variable] = id;
    }

    // Allocation ids are minted from the shared monotonically increasing
    // counter, so a carrier for an id always names the same storage in every
    // frame. Merge non-destructively: a callee's fresh-binding cleanup must
    // not erase a carrier still reachable by a value in its caller.
    private void mergeArrayAllocationCarriers(ref Walker child) {
        foreach (id, carrier; child.arrayAllocationCarriers)
            if (id !in arrayAllocationCarriers)
                arrayAllocationCarriers[id] = carrier;
    }

    // Array-typed-field sibling of the common direct-field reverse lookup
    // (struct-static-array-field cross-frame follow-up, 2026-07-15):
    // `structArrayFieldPointerVariables`/
    // `FieldIndices` merge the identical, conflict-free way -- the id space
    // is shared with the scalar-field maps (both mint through the same
    // `fieldSnapshotAllocationId` memo), so the same
    // the field-path forward map is the right conflict check
    // here too.
    private void mergeStructArrayFieldPointerVariableMaps(ref Walker child) {
        foreach (id, variable; child.structArrayFieldPointerVariables) {
            auto fieldIndex = id in child.structArrayFieldPointerFieldIndices;
            if (fieldIndex !is null)
                if (auto ownId = directFieldPathKey(variable, *fieldIndex)
                        in fieldPathAddressAllocations)
                    if (*ownId != id)
                        continue;

            structArrayFieldPointerVariables[id] = variable;
            if (fieldIndex !is null)
                structArrayFieldPointerFieldIndices[id] = *fieldIndex;
        }
    }

    // Common reverse-map merge. The owning frame's forward memo wins when
    // the same path names a different activation's allocation id.
    private void mergeFieldPointerPaths(ref Walker child) {
        foreach (id, path; child.fieldPointerPaths) {
            if (auto ownId = path in fieldPathAddressAllocations)
                if (*ownId != id)
                    continue;

            fieldPointerPaths[id] = path;
            if (auto identity = id in child.classFieldPointerObjectIds)
                classFieldPointerObjectIds[id] = *identity;
        }
    }

    // Array-typed-field sibling of `mergeFieldPointerPaths` above
    // (class static-array-field cross-frame follow-up):
    // `classArrayFieldPointerVariables`/
    // `FieldIndices` merge the identical, conflict-free way -- a
    // class-array-field id is memoized through the same
    // field-path map a class scalar field's id is
    // (`arrayPointer`'s `DotVarExp` branch mints it via the same
    // `fieldSnapshotAllocationId`), so the same forward map is the right
    // conflict check here too, mirroring `mergeStructArrayFieldPointerVariableMaps`'s
    // own reasoning for the struct-receiver sibling.
    private void mergeClassArrayFieldPointerVariableMaps(ref Walker child) {
        foreach (id, variable; child.classArrayFieldPointerVariables) {
            auto fieldIndex = id in child.classArrayFieldPointerFieldIndices;
            if (fieldIndex !is null)
                if (auto ownId = directFieldPathKey(variable, *fieldIndex)
                        in fieldPathAddressAllocations)
                    if (*ownId != id)
                        continue;

            classArrayFieldPointerVariables[id] = variable;
            if (fieldIndex !is null)
                classArrayFieldPointerFieldIndices[id] = *fieldIndex;
        }
    }

    // `fieldPathAddressAllocations`' own forward-map merge, matching
    // `mergeArrayAllocationMaps`' "this frame's own entry wins" rule: a
    // field path this frame already has an id for keeps it; only a path this
    // frame has never seen adopts the callee's.
    private void mergeFieldPathAddressAllocations(ref Walker child) {
        foreach (key, id; child.fieldPathAddressAllocations)
            if (key !in fieldPathAddressAllocations)
                fieldPathAddressAllocations[key] = id;
    }

    // Cross-frame writeback discriminator: whether `childVariable`'s final
    // value in `child` still
    // represents an in-place MUTATION of storage `this` frame's own
    // `arrayCells` entry may safely be refreshed with, or a REBIND the
    // callee performed instead. `arrayRebinds` is set by `writeCelledLocal`
    // the moment it replaces a whole array value rather than mutating one in
    // place (see that field's own doc comment) -- an absent entry means
    // every write `child` made to `childVariable` was a same-storage
    // mutation (or `childVariable` was never written at all), so the
    // parent's own cell may be refreshed in place; a present entry means
    // `child` rebound it to different storage at some point, so the
    // parent's own cell must be DROPPED instead, matching a same-frame
    // `s = b;` rebind's existing decline-rather-than-corrupt choice. Reading
    // `child`'s own map (not `this`'s) is what makes this cross-frame: the
    // rebind, if any, happened inside `child`'s execution, not this frame's.
    private bool arrayWritebackIsMutation(
        VarDeclaration childVariable,
        ref Walker child,
    ) {
        return (childVariable in child.arrayRebinds) is null;
    }

    // Class sibling of `arrayWritebackIsMutation` above:
    // `writeBackNestedLocals` below
    // iterates over EVERY variable in `child.locals`, including class-typed
    // ones this frame may already share a `classCells` entry for -- most of
    // which `child` never touched at all, let alone rebound. Reading
    // `child`'s own `classRebinds` marker (set by `writeCelledLocal` the
    // moment it drops a cell rather than refreshing it in place) tells an
    // untouched or genuinely-mutated-in-place variable (absent from the map:
    // safe to refresh, or a no-op if `child` never promoted/shared a cell for
    // it at all) apart from one `child` actually rebound to a different
    // object (present in the map: this frame's own cell must be dropped too,
    // matching a same-frame `c = b;` rebind's own decline-rather-than-corrupt
    // choice), rather than the unconditional whole-cell refresh that
    // corrupted a shared cell for every OTHER alias.
    private bool classWritebackIsMutation(
        VarDeclaration childVariable,
        ref Walker child,
    ) {
        return (childVariable in child.classRebinds) is null;
    }

    // Follow-up (2026-07-14, cross-frame cell staleness):
    // `runIndexExpression`'s cell arm makes a promoted `arrayCells` entry
    // READ-AUTHORITATIVE over the boxed `locals` mirror, but this used to
    // refresh only the mirror with a bare assignment, never reconciling the
    // parent's own cell. A nested function mutating a captured array is a
    // supported, tested Interpreter feature, so the parent's stale cell kept
    // answering reads with the pre-call value (or, if the array grew,
    // indexed a too-short cell and crashed the host) after `child` returned.
    // Routing through `writeCelledLocal` -- the same reconciliation
    // `writeBackRefArguments` already uses for a `ref` array parameter's
    // writeback -- refreshes a same-length cell in place and drops a
    // changed-length one, matching a rebind that cannot be represented as an
    // in-place byte mutation. A no-op for any variable without a cell (falls
    // through to the same plain `locals[variable] = value;` as before), and
    // unchanged for a scalar/struct variable (`writeCelledLocal`'s own
    // pre-existing scalarCells/structCells branches, not gated on this).
    //
    // Whether the callee's write was a genuine in-place mutation or a REBIND
    // is no longer assumed unconditionally --
    // `arrayWritebackIsMutation` answers it per variable, from `child`'s own
    // `arrayRebinds` marker, so a nested function that REPLACES a captured
    // array with a new same-length one (`a = [x, y];`) drops the parent's
    // cell instead of corrupting it, while a nested function that MUTATES a
    // captured array's elements still refreshes the parent's cell in place.
    private void writeBackNestedLocals(
        imported!"dmd.func".FuncDeclaration function_,
        ref Walker child,
        in bool captureLocals = false,
    ) {
        if (!captureLocals && !function_.isNested)
            return;

        foreach (variable, value; child.locals)
            if (variable in locals)
                writeCelledLocal(
                    variable,
                    value,
                    /* arrayIsRefWriteback */ arrayWritebackIsMutation(variable, child),
                    /* classFieldRefresh */ classWritebackIsMutation(variable, child),
                );
    }

    private void writeBackGlobals(ref Walker child) {
        foreach (variable, value; child.locals) {
            if (variable.isDataseg)
                setLocal(variable, value);
        }
    }

    private void writeBackLocalPointerTargets(ref Walker child) {
        foreach (_, variable; child.localPointers) {
            if ((variable in locals) is null)
                continue;

            if ((variable in arrayAllocations) !is null)
                continue;

            // A native-scalar target already carries a promoted `scalarCells`
            // entry: `localPointerValue` promotes eagerly
            // and every frame shares the same `NativeBlock` bytes by
            // reference (`child.scalarCells = scalarCells.dup`), so the
            // child's writes are already visible here. Copying the boxed
            // `child.locals` mirror back would be dead code -- the `VarExp`
            // read arm ignores `locals` in favour of the cell once one
            // exists, so nothing ever reads the value this would restore.
            if (variable in scalarCells)
                continue;

            if (auto value = variable in child.locals)
                setLocal(variable, *value);
        }
    }

    // Same cross-frame cell reconciliation as `writeBackNestedLocals` above,
    // for the non-nested case: a recursive call sharing a dynamic-array
    // PARAMETER's backing storage (no `ref`, no closure) hits this call site
    // instead, via `arrayAllocationVariables` rather than capture. Without
    // routing through `writeCelledLocal` here too, an in-place element write
    // made by the recursive callee left the caller's own promoted cell
    // stale, the same read-authoritative staleness `writeBackNestedLocals`
    // fixes for a captured local.
    //
    // Gated on `variable` being a PARAMETER, unlike `writeBackNestedLocals`:
    // recursion reuses the same `VarDeclaration` for a plain LOCAL
    // declaration at every call depth too (`runDeclarationExpression`'s own
    // `dropArrayCell`), and that case is not aliasing at all -- each depth's
    // `int[] a = ...;` is an unrelated array that only coincidentally shares
    // the AST node. `bindFunctionParameters` calls `dropArrayCell` at every
    // depth exactly the same way, so cell/id state alone cannot tell the two
    // apart (both mint a fresh, non-matching allocation id per depth); a
    // fresh local's differently-sized final value reaching here through the
    // unconditional `writeCelledLocal` call regressed
    // `pointer.recursiveArrayDeclarationDropsStaleArrayCell` (this frame's
    // OWN still-valid cell was wrongly dropped because a deeper, unrelated
    // recursive redeclaration happened to return a shorter array). A
    // parameter, by contrast, is the one case the language actually shares
    // storage through across a recursive call when the same array is passed
    // straight back in (as in `pointer.
    // recursiveArrayParameterElementWriteIsVisibleThroughCallerCell`), so
    // only that case reconciles the cell; every other variable keeps the
    // pre-existing plain mirror copy.
    //
    // As in `writeBackNestedLocals`,
    // `arrayWritebackIsMutation` -- not a hardcoded `true` -- decides
    // whether the recursive callee's write reconciles the caller's cell in
    // place (a genuine element mutation) or drops it (the callee rebound
    // the shared parameter to a new same-length array).
    private void writeBackArrayPointerTargets(ref Walker child) {
        foreach (_, variable; child.arrayAllocationVariables) {
            if ((variable in locals) is null)
                continue;

            if (!isDynamicArrayVariable(variable) &&
                (variable in child.arrayPointerWritebacks) is null)
                continue;

            auto value = variable in child.locals;
            if (value is null)
                continue;

            if (isParameterVariable(variable))
                writeCelledLocal(
                    variable,
                    *value,
                    /* arrayIsRefWriteback */ arrayWritebackIsMutation(variable, child),
                );
            else
                setLocal(variable, *value);
        }
    }

    // `parameterIsLazy`'s sibling: whether `variable` is a function parameter
    // at all (`dmd`'s own `STC.parameter` storage-class flag), used by
    // `writeBackArrayPointerTargets` above to tell a genuine cross-recursion
    // parameter binding apart from a same-`VarDeclaration` local re-declared
    // at a deeper call depth.
    private bool isParameterVariable(VarDeclaration variable) {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.parameter) != STC.none;
    }

    // Write-through-pointer counterpart of `writeBackArrayPointerTargets`,
    // for a cross-frame `&s.field` pointer: a callee that writes through
    // such a pointer via
    // `writeThroughStructFieldPointer` can always refresh the shared
    // `structCells` entry (its bytes are the SAME `NativeStruct` the
    // receiver's own frame holds), but when `variable` belongs to an OUTER
    // frame it is not one of the callee's own locals at all, so there is no
    // `child.locals[variable]` to copy back the way
    // `writeBackArrayPointerTargets` does for arrays. Unlike an array
    // element read (`a[i]`, which consults `arrayCells` first --
    // `runIndexExpression`), a direct struct-field read (`s.field`, via
    // `runDotVarExpression`) never consults `structCells` -- only a
    // `*pointer` deref does -- so the owning frame's boxed `locals` mirror
    // must be refreshed here from the (already-updated) cell once control
    // returns to it, or `s.field` would still read the pre-call value even
    // though `*p` already sees the write.
    private void writeBackStructFieldPointerTargets(ref Walker child) {
        foreach (_, path; child.fieldPointerPaths) {
            auto variable = path.root;
            if ((variable in child.structFieldPointerWritebacks) is null)
                continue;

            auto current = variable in locals;
            if (current is null || !current.isStruct)
                continue;

            auto cell = variable in structCells;
            if (cell is null)
                continue;

            setLocal(variable, structValueFromCell(*current, *cell));
        }
    }

    // Array-typed-field sibling of `writeBackStructFieldPointerTargets` above
    // (struct-static-array-field cross-frame follow-up, 2026-07-15): same
    // reasoning, for a cross-frame `&s.arr[i]` pointer --
    // a direct array-field element read (`s.arr[i]`) never consults
    // `structCells` either, only a `*pointer` deref does, so the owning
    // frame's boxed `locals` mirror must be refreshed here too.
    private void writeBackStructArrayFieldPointerTargets(ref Walker child) {
        foreach (_, variable; child.structArrayFieldPointerVariables) {
            if ((variable in child.structArrayFieldPointerWritebacks) is null)
                continue;

            auto current = variable in locals;
            if (current is null || !current.isStruct)
                continue;

            auto cell = variable in structCells;
            if (cell is null)
                continue;

            setLocal(variable, structValueFromCell(*current, *cell));
        }
    }

    // Nested-struct-field sibling of `writeBackStructFieldPointerTargets`/
    // `writeBackStructArrayFieldPointerTargets` above (nested-struct-field
    // cross-frame follow-up, 2026-07-15): same
    // reasoning, for a cross-frame `&s.inner.x` pointer -- a direct nested
    // field read (`s.inner.x`) never consults `structCells` either, only a
    // `*pointer` deref does, so the owning frame's boxed `locals` mirror
    // must be refreshed here too.
    private void writeBackNestedStructFieldPointerTargets(ref Walker child) {
        foreach (_, path; child.fieldPointerPaths) {
            if (path.indices.length != 2)
                continue;

            auto variable = path.root;
            if ((variable in child.nestedStructFieldPointerWritebacks) is null)
                continue;

            auto current = variable in locals;
            if (current is null || !current.isStruct)
                continue;

            auto cell = variable in structCells;
            if (cell is null)
                continue;

            setLocal(variable, structValueFromCell(*current, *cell));
        }
    }

    // Class sibling of `writeBackStructFieldPointerTargets` above
    // (cross-frame write-through-pointer follow-up):
    // same reasoning, for a cross-frame `&c.field` pointer -- a direct
    // class-field read (`c.field`) never consults `classCells` either, only
    // a `*pointer` deref does, so the owning frame's boxed `locals` mirror
    // must be refreshed here from the (already-updated) cell once control
    // returns to it.
    private void writeBackClassFieldPointerTargets(ref Walker child) {
        foreach (_, path; child.fieldPointerPaths) {
            auto variable = path.root;
            if ((variable in child.classFieldPointerWritebacks) is null)
                continue;

            auto current = variable in locals;
            if (current is null || !current.isClassObject)
                continue;

            auto cell = variable in classCells;
            if (cell is null)
                continue;

            auto classType = variable.type.toBasetype.isTypeClass;
            if (classType is null || classType.sym is null)
                continue;

            setLocal(variable, classValueFromCell(*current, *cell, classType.sym));
        }
    }

    // Nested-class-struct-field sibling of `writeBackClassFieldPointerTargets`
    // above (remaining cross-frame follow-up, 2026-07-15): same reasoning,
    // for a cross-frame `&c.inner.x`
    // pointer -- a direct nested-field read (`c.inner.x`) never consults
    // `classCells` either, only a `*pointer` deref does, so the owning
    // frame's boxed `locals` mirror must be refreshed here too, mirroring
    // `writeBackNestedStructFieldPointerTargets`'s own reasoning for the
    // struct-receiver sibling. Reuses the same `classValueFromCell` helper as
    // the scalar- and array-field siblings -- widened below to also overlay
    // a (non-union) struct-typed field's own nested scalar fields -- so this
    // writeback needs no field-specific derivation of its own.
    private void writeBackNestedClassStructFieldPointerTargets(ref Walker child) {
        foreach (_, path; child.fieldPointerPaths) {
            if (path.indices.length != 2)
                continue;

            auto variable = path.root;
            if ((variable in child.nestedClassStructFieldPointerWritebacks) is null)
                continue;

            auto current = variable in locals;
            if (current is null || !current.isClassObject)
                continue;

            auto cell = variable in classCells;
            if (cell is null)
                continue;

            auto classType = variable.type.toBasetype.isTypeClass;
            if (classType is null || classType.sym is null)
                continue;

            setLocal(variable, classValueFromCell(*current, *cell, classType.sym));
        }
    }

    // Array-typed-field sibling of `writeBackClassFieldPointerTargets` above
    // (class static-array-field cross-frame follow-up): same reasoning, for
    // a cross-frame `&c.arr[i]`
    // pointer -- a direct class-array-field element read (`c.arr[i]`) never
    // consults `classCells` either, only a `*pointer` deref does, so the
    // owning frame's boxed `locals` mirror must be refreshed here too,
    // mirroring `writeBackStructArrayFieldPointerTargets`'s own reasoning for
    // the struct-receiver sibling.
    private void writeBackClassArrayFieldPointerTargets(ref Walker child) {
        foreach (_, variable; child.classArrayFieldPointerVariables) {
            if ((variable in child.classArrayFieldPointerWritebacks) is null)
                continue;

            auto current = variable in locals;
            if (current is null || !current.isClassObject)
                continue;

            auto cell = variable in classCells;
            if (cell is null)
                continue;

            auto classType = variable.type.toBasetype.isTypeClass;
            if (classType is null || classType.sym is null)
                continue;

            setLocal(variable, classValueFromCell(*current, *cell, classType.sym));
        }
    }

    // Re-derives a class `Value` from `cell`'s scalar-field bytes, the class
    // sibling of `structValueFromCell` and the read-side mirror of
    // `writeClassCellScalarFields`: every `native_scalar.isNativeScalarType`
    // field is overlaid onto `current` from the cell (authoritative once a
    // cross-frame write-through-pointer touched it via
    // `writeThroughClassFieldPointer`). Widened (class static-array-field
    // cross-frame follow-up)
    // to also overlay every scalar-element static-array field via a
    // `NativeArray` adopted over the field's own byte sub-range -- the same
    // composition `writeClassCellScalarFields`'s own array-field widening
    // uses, and the class-receiver sibling of `structValueFromCell`'s own
    // array-field widening -- needed so
    // `writeBackClassArrayFieldPointerTargets` above can refresh a
    // cross-frame `&c.arr[i]` write's owning frame the same way. Widened
    // again (remaining cross-frame follow-up, 2026-07-15) to recurse one
    // level into every (non-union)
    // struct-typed field via a `NativeStruct` adopted over the field's own
    // byte sub-range -- the class-receiver sibling of `structValueFromCell`'s
    // own nested-field recursion -- needed so
    // `writeBackNestedClassStructFieldPointerTargets` above can refresh a
    // cross-frame `&c.inner.x` write's owning frame the same way. Any other
    // non-scalar, non-scalar-element-array, non-(non-union)-struct field is
    // left exactly as `current` already had it, matching
    // `writeClassCellScalarFields`'s own bounded reach for this phase's
    // scope. Scalar- and struct-element dynamic-array fields reconstruct
    // through the slice header stored in the class cell and the referenced
    // element block.
    private Value classValueFromCell(
        in Value current,
        ref NativeBlock cell,
        imported!"dmd.dclass".ClassDeclaration class_,
    ) {
        import quickbite.backends.interpreter.layout:
            classFields, fieldByteOffset, staticArrayLength, typeByteSize;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        Value value = current;
        foreach (index, field; classFields(class_)) {
            if (isNativeScalarType(field.type)) {
                const offset = fieldByteOffset(field);
                const size = typeByteSize(field.type);
                value = value.withClassField(
                    index,
                    readScalar(field.type, cell.bytes[offset .. offset + size]),
                );
                continue;
            }

            if (isStaticArrayType(field.type)) {
                auto elementType = field.type.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                auto fieldValue = value.classFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                const offset = fieldByteOffset(field);
                const size = typeByteSize(field.type);
                const length = staticArrayLength(field.type.toBasetype.isTypeSArray);
                auto arrayCell =
                    NativeArray.adopt(cell.subRange(offset, size), elementType, length);
                foreach (elementIndex; 0 .. fieldValue.length) {
                    Value elementValue;
                    if (structType !is null) {
                        auto elementCell = arrayCell.structElement(elementIndex);
                        elementValue = structValueFromCell(
                            fieldValue[elementIndex],
                            elementCell,
                        );
                    } else
                        elementValue = readScalar(
                            elementType,
                            arrayCell.element(elementIndex),
                        );
                    fieldValue = fieldValue.withArrayElement(
                        elementIndex,
                        elementValue,
                    );
                }
                value = value.withClassField(index, fieldValue);
                continue;
            }

            if (isDynamicArrayType(field.type)) {
                auto elementType = field.type.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;
                if (!isNativeScalarType(elementType) && (
                    structType is null ||
                    structType.sym.isUnionDeclaration !is null
                ))
                    continue;

                const fieldValue = value.classFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                auto arrayCell = classSliceField(cell, class_, index);
                value = value.withClassField(
                    index,
                    arrayValueFromCell(fieldValue, arrayCell),
                );
                continue;
            }

            auto nestedStructType = field.type.toBasetype.isTypeStruct;
            if (nestedStructType is null || nestedStructType.sym.isUnionDeclaration !is null)
                continue;

            auto nestedValue = value.classFieldAt(index);
            if (!nestedValue.isStruct)
                continue;

            const offset = fieldByteOffset(field);
            const size = typeByteSize(field.type);
            auto nestedCell = NativeStruct.adopt(cell.subRange(offset, size), nestedStructType);
            value = value.withClassField(index, structValueFromCell(nestedValue, nestedCell));
        }

        return value;
    }

    // Re-derives a struct `Value` from `cell`'s scalar-field bytes: the
    // read-side mirror of `writeStructCellScalarFields`. Every
    // `native_scalar.isNativeScalarType` field is overlaid onto `current`
    // from the cell (authoritative once a write-through-pointer touched
    // it). Widened (2026-07-15, struct-static-array-field cross-frame
    // follow-up) to also overlay every scalar-element static-array field via
    // `NativeStruct.arrayField`, the read-side mirror of
    // `writeStructCellScalarFields`'s own array-field seeding -- needed so
    // `writeBackStructArrayFieldPointerTargets` above can refresh a
    // cross-frame `&s.arr[i]` write's owning frame the same way the
    // scalar-field sibling already does. Widened again (2026-07-15,
    // nested-struct-field cross-frame follow-up) to recurse one level into
    // every (non-union) struct-typed field via `NativeStruct.structField`,
    // the read-side mirror of `writeStructCellScalarFields`'s own
    // nested-field recursion -- needed so
    // `writeBackNestedStructFieldPointerTargets` above can refresh a
    // cross-frame `&s.inner.x` write's owning frame the same way. Any other
    // non-scalar, non-scalar-element-array, non-(non-union)-struct field
    // (never tracked in the cell) is left exactly as `current` already had
    // it.
    private Value structValueFromCell(in Value current, ref NativeStruct cell) {
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        Value value = current;
        foreach (index; 0 .. cell.fieldCount) {
            auto fieldType = cell.fieldDeclaration(index).type;

            if (isNativeScalarType(fieldType)) {
                value = value.withStructField(index, readScalar(fieldType, cell.field(index)));
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

                auto fieldValue = value.structFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                auto arrayCell = cell.arrayField(index);
                foreach (elementIndex; 0 .. fieldValue.length) {
                    Value elementValue;
                    if (structType !is null) {
                        auto elementCell = arrayCell.structElement(elementIndex);
                        elementValue = structValueFromCell(
                            fieldValue[elementIndex],
                            elementCell,
                        );
                    } else
                        elementValue = readScalar(
                            elementType,
                            arrayCell.element(elementIndex),
                        );
                    fieldValue = fieldValue.withArrayElement(
                        elementIndex,
                        elementValue,
                    );
                }
                value = value.withStructField(index, fieldValue);
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

                const fieldValue = value.structFieldAt(index);
                if (!fieldValue.isArray)
                    continue;

                auto arrayCell = cell.sliceField(index);
                value = value.withStructField(
                    index,
                    arrayValueFromCell(fieldValue, arrayCell),
                );
                continue;
            }

            auto nestedStructType = fieldType.toBasetype.isTypeStruct;
            if (nestedStructType is null || nestedStructType.sym.isUnionDeclaration !is null)
                continue;

            auto nestedValue = value.structFieldAt(index);
            if (!nestedValue.isStruct)
                continue;

            auto nestedCell = cell.structField(index);
            value = value.withStructField(index, structValueFromCell(nestedValue, nestedCell));
        }

        return value;
    }

    private void mergeReturnedLocalPointer(ref Walker child) {
        if (!child.result.isLocalPointer)
            return;

        const id = child.result.localPointerId;
        auto variable = id in child.localPointers;
        if (variable is null || (*variable in locals) is null)
            return;

        localPointers[id] = *variable;
        localPointerIds[*variable] = id;
    }

    private void seedPointerTargetLocals(ref Walker child) {
        foreach (_, variable; child.localPointers)
            seedChildLocal(child, variable);

        foreach (_, variable; child.arrayAllocationVariables)
            if (isArrayVariable(variable))
                seedChildLocal(child, variable);
    }

    private void seedChildLocal(ref Walker child, VarDeclaration variable) {
        if (auto value = variable in locals)
            child.setLocal(variable, *value);
    }

    private bool isArrayVariable(VarDeclaration variable) {
        import quickbite.frontend.dmd.types: isArrayType;

        return isArrayType(variable.type);
    }

    private bool isDynamicArrayVariable(VarDeclaration variable) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        return isDynamicArrayType(variable.type);
    }

    private Value[VarDeclaration] datasegLocals() {
        Value[VarDeclaration] result;
        foreach (variable, value; locals) {
            if (variable.isDataseg)
                result[variable] = value;
        }

        return result;
    }

    private void writeBackThisStructArrayFieldAliases(ref Walker child) {
        foreach (_, sourceVariable; child.thisStructArrayFieldAliases.sources) {
            if (auto value = sourceVariable in child.locals)
                setLocal(sourceVariable, *value);
        }
    }

    private void writeBackThis(
        imported!"dmd.expression".Expression receiver,
        in Value value,
    ) {
        // mutations of `this` persist only through lvalue receivers; rvalue
        // temporaries such as struct literals discard them, matching D
        if (!isWritableLocation(receiver))
            return;

        writeLocation(receiver, value);
    }

    private bool isWritableLocation(
        imported!"dmd.expression".Expression expression,
    ) {
        if (expression is null)
            return false;

        return
            expression.isVarExp !is null ||
            expression.isDotVarExp !is null ||
            expression.isThisExp !is null ||
            expression.isIndexExp !is null;
    }

    private bool isDynamicArrayPointerRefArgument(
        imported!"dmd.expression".Expression expression,
    ) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        auto pointerExpression = expression.isPtrExp;
        if (pointerExpression is null)
            return false;

        const pointer = runExpression(pointerExpression.e1);
        if (!isBoxedPointer(pointer) || pointer.pointerAllocation == 0)
            return false;

        auto variable = pointer.pointerAllocation in arrayAllocationVariables;
        return variable !is null && isDynamicArrayType((*variable).type);
    }

    private void bindFunctionParameters(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions = null,
        Value[VarDeclaration] callerLocals = null,
        FrameBlock callerFrame = FrameBlock.init,
        bool[VarDeclaration]* callerMirrorEstablished = null,
        size_t[size_t][VarDeclaration]* callerMirrorGenerations = null,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
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
                    callerLocals,
                    callerFrame,
                    callerMirrorEstablished,
                    callerMirrorGenerations,
                );
                continue;
            }

            // A fresh call binds a new stack slot for `parameter`; drop any
            // inherited/stale `scalarCells`/`arrayCells`/`structCells`/
            // `classCells` entry the same way a fresh `DeclarationExp` does --
            // recursion reuses the same
            // `VarDeclaration` for a parameter at every call depth.
            dropNonClassCells(parameter);
            setLocal(parameter, arguments[index]);

            // Fills `parameter`'s own reference slot (see `frame_layout`'s
            // `FrameLayout.Slot.Kind.reference`) with the caller-side
            // address of its own argument lvalue, when there is one to
            // compose from -- `bindReferenceSlot` below declines silently
            // rather than guessing whenever it cannot. Boxed authority
            // above (`setLocal`, just called) is completely unaffected
            // either way.
            if (parameter.isReference && index < argumentExpressions.length)
                bindReferenceSlot(
                    parameter,
                    argumentExpressions[index],
                    index < evaluatedArguments.length
                        ? evaluatedArguments[index].indices
                        : null,
                    callerFrame,
                    callerMirrorEstablished,
                    arguments[index],
                );

            // `runRefArgumentExpression` seeds a `ref` argument still bound to
            // an uninitialized caller local with a bare `Value.void_`
            // placeholder rather than reading through it. Mirror that
            // uninitialized status onto the callee's own
            // parameter so a nested read through it — including a `DotVarExp`
            // field access on a struct/static-array parameter, e.g. cerealed's
            // `grain(__traits(getMember, val, member))` — hits the same
            // "materialize the default aggregate" / "throw for a still-void
            // scalar" handling `runExpression`'s `VarExp` branch already
            // applies to a directly uninitialized local, instead of reading a
            // bare `Value.void_` straight off `locals` and failing field
            // access outright.
            if (parameter.isReference && arguments[index] == Value.void_)
                uninitializedLocals[parameter] = true;

            recordParameterSliceAlias(
                parameter,
                arguments[index],
                index < argumentExpressions.length
                    ? argumentExpressions[index]
                    : null,
            );
            bindArrayValueCell(parameter, arguments[index]);
        }
    }

    // Fills `parameter`'s own reference slot -- this activation's own
    // `_activationFrame`, given one unconditionally by `frame_layout.
    // computeFrameLayout` for every `ref`/`out` parameter -- with the
    // caller-side address `argumentExpression`'s lvalue resolves to,
    // composed via `lvalue_place.placeOfLvalue`: the first real consumer
    // of that function in the walker. `resolveBase` is
    // `callerReferenceBase` below, resolving strictly against
    // `callerFrame` -- the CALLER's own activation, threaded down through
    // `bindFunctionParameters`'s own `callerFrame` parameter -- and the
    // shared `moduleTable`; never this activation's own `_activationFrame`,
    // which belongs to the callee that has not even started running yet
    // (`this` here IS the callee: `bindFunctionParameters` always runs as
    // `child.bindFunctionParameters(...)`).
    //
    // `placeOfLvalue` refuses an unsupported lvalue shape by throwing --
    // its own documented contract ("every other lvalue shape refuses
    // rather than guesses") -- and `callerReferenceBase`/`constantIndex`
    // below do the same for a variable with no mirrored caller-side
    // storage, storage the write side never actually established
    // (`mirrorEstablished`, the one record both this composition and
    // `assertReferenceBind`'s verification hang off), or a non-constant
    // index (see `constantIndex`'s own header for why). This `catch` is the
    // integration seam translating
    // that throw-to-refuse contract into this function's own
    // decline-silently one: it is not ordinary control flow, since
    // nothing downstream branches on which arm ran, and boxed authority
    // (`parameter`'s own cell in `locals`, already filled by
    // `bindFunctionParameters` immediately before this call, and the
    // existing parameter writeback at return) is unconditionally correct
    // either way -- this slot has no consumer of its own yet, so
    // declining to fill it changes nothing user-visible.
    private void bindReferenceSlot(
        VarDeclaration parameter,
        Expression argumentExpression,
        const(size_t[const(void)*]) evaluatedIndices,
        FrameBlock callerFrame,
        bool[VarDeclaration]* callerMirrorEstablished,
        in Value argumentValue,
    ) {
        import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;

        if (argumentExpression is null)
            return;

        // Set by `callerReferenceBase` whenever the base it resolved is
        // storage the verified mirror does not keep in step with the boxed
        // argument, for either of its two reasons: resolved THROUGH another
        // reference slot (forwarding a `ref` parameter into this call), or
        // owned by a cell whose writes bypass the frame slot. See the
        // `if (!bindNotVerifiable)` guard below.
        //
        // A composition crossing a class body is the third reason, and it
        // is a property of the ARGUMENT EXPRESSION rather than of any one
        // variable, so it is decided here: an object body is shared by
        // every reference to it, so a callee that took the same object by
        // value and wrote a field through its own parameter mirror already
        // rewrote these bytes, in an activation that has since returned,
        // while every boxed value naming the object through some OTHER
        // binding still carries the pre-call field. The ordinary read path
        // survives that state only because `assertClassBodyValue` consults
        // `classMirrorGenerations`; a bind has no such per-binding
        // generation snapshot to consult -- the base variable is still
        // `mirrorEstablished` and owned by no cell -- so it declines the
        // whole shape instead. The slot is still filled: the body IS the
        // right storage, it is the boxed comparison value that is allowed
        // to be stale.
        bool bindNotVerifiable = lvalueCrossesClassBody(argumentExpression);

        void* address;
        try {
            address = placeOfLvalue(
                argumentExpression,
                (variable) => callerReferenceBase(
                    variable,
                    callerFrame,
                    callerMirrorEstablished,
                    bindNotVerifiable,
                ),
                (expression) => evaluatedIndex(expression, evaluatedIndices),
            ).address;
        } catch (Exception) {
            return;
        }

        // A composed address of `null` is never a legitimate storage
        // location -- no real `NativeBlock`/`FrameBlock`/`ModuleTable`
        // allocation this codebase ever makes sits at address zero -- so
        // this can only mean the composition, while it didn't THROW,
        // still failed to find real storage: e.g. a `PtrExp` base
        // (`*chunk`) whose own pointer variable's mirrored bytes read back
        // `null` at a point in a druntime-internal call (an `interpreter.
        // md` §9.10-shimmed helper such as `emplace`, called with
        // synthesized rather than a real call site's own argument
        // expressions) where that address is not actually meaningful.
        // Decline exactly like any other composition failure rather than
        // storing or verifying against a null address -- `assertReferenceBind`
        // would otherwise dereference it directly and crash.
        if (address is null)
            return;

        _activationFrame.setReferenceSlot(parameter, address);

        // A root variable resolved THROUGH another reference slot points at
        // storage several activations up whose bytes are, by the boxed
        // COPY-plus-writeback design (`value.md`'s Cell coherence
        // "Parameter writeback" contract), allowed to lag behind the
        // FORWARDING activation's own already-mutated boxed copy until
        // THAT activation's own writeback runs at its return -- e.g.
        // recursion passing its own `ref` parameter into the next call
        // after having already mutated it. Comparing there would be a
        // false positive on a perfectly correct program: exactly the
        // mid-call divergence `assertReferenceBind`'s own header warns
        // about, one level removed. A base a CELL owns lags for its own,
        // unrelated reason (`cellIsAuthorityFor`), and a composition
        // crossing a class body for a third (`lvalueCrossesClassBody`).
        // Only a shape that is none of those -- an established owning slot
        // or dataseg block the verified mirror keeps synchronously in sync,
        // reached without dereferencing a shared object body -- is safe to
        // verify, and that is decided once, before composing: the write and
        // the verify side never evaluate the question separately, so they
        // cannot answer it differently at two points in time.
        if (!bindNotVerifiable)
            assertReferenceBind(parameter, address, argumentValue);
    }

    // Whether composing `expression`'s lvalue place dereferences a class
    // reference on the way -- `lvalue_place.placeOfLvalue`'s own
    // `receiver.type.isTypeClass` branch, asked here syntactically over the
    // identical `DotVarExp`/`IndexExp`/`PtrExp` chain that function walks.
    // Deliberately coarse: any class-typed receiver at any depth answers
    // `true`, whether or not that particular object's body has actually
    // been rewritten behind this binding's back, because a bind has no
    // per-binding generation snapshot with which to ask the narrower
    // question (see `bindNotVerifiable`'s initialiser). A shape this
    // declines still gets its reference slot filled, it is only the
    // bind-time comparison against the boxed argument that is skipped.
    private static bool lvalueCrossesClassBody(Expression expression) {
        if (expression is null)
            return false;

        if (auto dot = expression.isDotVarExp)
            return dot.e1.type !is null
                && dot.e1.type.toBasetype.isTypeClass !is null
                || lvalueCrossesClassBody(dot.e1);

        if (auto index = expression.isIndexExp)
            return lvalueCrossesClassBody(index.e1);

        if (auto pointer = expression.isPtrExp)
            return lvalueCrossesClassBody(pointer.e1);

        return false;
    }

    // The `resolveBase` `bindReferenceSlot` above supplies to
    // `placeOfLvalue`: the CALLER's own mirror address for `variable` --
    // this activation's caller, i.e. `callerFrame` (never `this.
    // _activationFrame`, the CALLEE's own) -- covering every shape
    // `hasMirrorSlot`/`mirrorAddress` cover for a same-frame read, plus
    // one more: `variable` may itself be a `ref`/`out` parameter of the
    // CALLER (`callerFrame.hasReferenceSlot`), in which case its own
    // reference slot already holds the address ITS binding resolved to
    // (by this exact same function, one call frame up) -- reading that
    // through rather than the slot's own address is what lets a `ref`
    // argument forward correctly across several activations (recursion
    // passing its own `ref` parameter down again, or one function
    // forwarding a `ref` parameter into another). That branch also sets
    // `bindNotVerifiable` for `bindReferenceSlot`'s own bind-time
    // verification to see, since a FORWARDED root's storage is allowed to
    // legitimately lag behind the boxed copy that forwarded it (see that
    // function's own comment). Throws for anything else -- no owning
    // slot, no reference slot, and not dataseg (a `lazy` parameter, a
    // `ref` body local, or any local `frame_layout` gives no slot to) --
    // so `bindReferenceSlot`'s own `catch` turns that into a silent
    // decline rather than a guess.
    //
    // Owning a slot is not enough to hand its address out: an OWNED slot is
    // only a legal base once the write side actually ESTABLISHED it
    // (`callerMirrorEstablished`, the caller's own `mirrorEstablished` field
    // -- never this callee's, which describes a frame that has not started
    // running). Composition does not merely offset from this address --
    // `placeOfLvalue` DEREFERENCES it for a class receiver or a `PtrExp`
    // base, and indexes through a stored slice header -- so a slot the
    // mirror declined to fill (a class local whose body is not composable,
    // a pointer local holding a boxed-era carrier with no host address)
    // would be read as if it held a real reference, yielding `null +
    // fieldOffset`: non-null, past `bindReferenceSlot`'s own null guard,
    // and dereferenced by `assertReferenceBind` -- a SIGSEGV caused by
    // nothing but the shadow, on a program the boxed authority runs
    // correctly. Declining an established-looking base costs nothing but
    // coverage of a slot nothing reads yet, so this refuses the whole
    // shape rather than reasoning about which compositions happen to
    // dereference and which only offset.
    private void* callerReferenceBase(
        VarDeclaration variable,
        FrameBlock callerFrame,
        bool[VarDeclaration]* callerMirrorEstablished,
        ref bool bindNotVerifiable,
    ) @trusted {
        if (variable.isDataseg || callerFrame.hasOwningSlot(variable)) {
            if (
                callerMirrorEstablished is null
                    || !(*callerMirrorEstablished).get(variable, false)
            )
                throw new Exception(
                    "quickbite.backends.interpreter.impl.Walker."
                    ~ "callerReferenceBase: caller-side mirror storage for "
                    ~ "variable is not established",
                );

            // Established, so the slot's bytes are real and composing from
            // them is safe -- but a local a CELL owns has its writes
            // deliberately routed around that slot afterwards, so those
            // bytes are allowed to lag the boxed value bind-time
            // verification would compare them against. Fill the slot,
            // never verify it (see `bindNotVerifiable`'s own declaration).
            if (cellIsAuthorityFor(variable))
                bindNotVerifiable = true;

            return variable.isDataseg
                ? moduleTable.storageFor(variable)
                : callerFrame.bindingAddress(variable);
        }

        if (callerFrame.hasReferenceSlot(variable)) {
            // `hasReferenceSlot` only says `variable` is ELIGIBLE for a
            // reference slot per `frame_layout` -- not that `bindReferenceSlot`
            // ever actually filled it. A `ref`/`out` parameter reaches a
            // call with no argument-expression to compose from at all (a
            // synthesized call, e.g. `invokeNativeCallback`'s placeholder
            // `Expression[]`, or an intercepted druntime hook's own
            // internal call whose `argumentExpressions` this function's
            // own `index < argumentExpressions.length` guard cannot
            // cover) leaves its slot at `NativeBlock.allocate`'s own
            // zero-initialised default -- `null`, never a real address
            // this codebase ever composes deliberately. Reading THAT back
            // as if it were resolved would hand a caller `0x0` to
            // dereference; decline exactly like "no slot at all" instead.
            auto forwarded = callerFrame.bindingAddress(variable);
            if (forwarded !is null) {
                bindNotVerifiable = true;
                return forwarded;
            }
        }

        throw new Exception(
            "quickbite.backends.interpreter.impl.Walker.callerReferenceBase: "
            ~ "variable has no mirrored caller-side storage",
        );
    }

    // Whether a CELL, rather than `variable`'s own frame slot, is the
    // authority for it -- the identical four-map question
    // `assertFrameMirror` asks before verifying an owning local, asked here
    // for the BASE variable of a composed `ref`-argument lvalue. The maps
    // are this activation's, which for a bind is the CALLER's own
    // promotions: `forkPerFrameCellsInto` dups them into the callee before
    // `bindFunctionParameters` runs.
    //
    // A cell-owned local's frame slot is deliberately left behind: a write
    // through the cell (`writeCelledLocal`, or `writeBackLocalPointerTargets`
    // after a callee mutated the local through a pointer) never runs
    // `setLocal`, so no mirror write follows it and the slot keeps whatever
    // the last real mirror write left there. The boxed argument
    // `assertReferenceBind` would compare it against was read THROUGH the
    // cell (`runExpression`'s own `VarExp` arm prefers a promoted cell's
    // bytes over the boxed local for exactly that reason), so the two
    // legitimately disagree and asserting on them fires at a correct
    // program.
    private bool cellIsAuthorityFor(VarDeclaration variable) {
        return (variable in scalarCells) !is null
            || (variable in structCells) !is null
            || (variable in arrayCells) !is null
            || (variable in classCells) !is null;
    }

    // The call-argument walk records each runtime index before returning the
    // boxed argument value, so address composition reuses the exact result
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

    // Bind-time-only verification for a `ref`/`out` parameter's freshly
    // filled reference slot: the composed caller-side `address`'s own
    // bytes, at `parameter`'s own declared type, must equal `value` -- the
    // SAME boxed argument `bindFunctionParameters` just gave `parameter`'s
    // own cell -- written through the identical `place_value.writeValue`
    // composition `assertFrameMirror` itself uses, into a scratch block,
    // rather than a second, hand-rolled encoding.
    //
    // Deliberately BIND-TIME ONLY, unlike every other verified-mirror
    // check in this file: a `ref` parameter's boxed authority
    // (`locals[parameter]`) is a COPY the callee body goes on to mutate
    // directly, reconciled with the caller's own storage only by the
    // EXISTING parameter writeback at return (`value.md`'s Cell coherence
    // "Parameter writeback" contract) -- so the caller's bytes at
    // `address` and the callee's boxed copy legitimately DIVERGE for the
    // rest of the call, from the moment the callee's first mutating
    // statement runs. Checking this on every read, the way
    // `assertFrameMirror` does for an owning local, would fire on
    // perfectly correct programs; checking it exactly once, immediately
    // after binding and before the callee's body has had any chance to
    // diverge the two, is the only point in the call where the equality
    // this asserts is actually guaranteed to hold. This is a real,
    // deliberate weakening of the mirror's usual contract, accepted here
    // because the boxed COPY-plus-writeback machinery it is checking is
    // itself slated for deletion once the authority switch lands
    // (`value.md`'s Remaining work item 5) -- no long-term promise is
    // being watered down, only a short-lived one. A cheap, provably
    // order-independent RETURN-time check was not found: the writeback's
    // own named residuals (rebind-vs-mutation heuristics, the recursive-
    // parameter residual) mean a return-time equality is not guaranteed
    // to hold even on already-correct paths, so asserting it there would
    // risk turning an existing, silent quirk into a crash -- a real
    // shipping-behaviour change this slice must not introduce.
    //
    // Needs no cell-authority skip of its own the way `assertFrameMirror`
    // does: `callerReferenceBase` already made that call while composing
    // the address, and told `bindReferenceSlot` not to verify (its own
    // `bindNotVerifiable`). That is deliberate rather than incidental --
    // the write side and this verify must evaluate the SAME verdict for
    // the same base, and the only way to guarantee that across time is to
    // evaluate it once, before either happens.
    //
    // Declines the same way `assertFrameMirror`'s own composable arm does:
    // silently, for a `value` that is not (yet) `isPlaceComposable`'s
    // shape for `parameter.type`, or does not itself match that shape
    // (`valueMatchesPlace`) -- e.g. a still-`void` argument, or a slice-
    // or class-typed `ref` parameter (neither is `isPlaceComposable`, so
    // this never asserts on either; `bindReferenceSlot` above still fills
    // the reference slot for one, just without this verification).
    private void assertReferenceBind(
        VarDeclaration parameter,
        void* address,
        in Value value,
    ) {
        import quickbite.backends.interpreter.place_value: valueMatchesPlace, writeValue;
        import quickbite.backends.interpreter.place: placeAt;
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        if (!valueMatchesPlace(parameter.type, value))
            return;

        const length = typeByteSize(parameter.type);
        const scan = typeHasPointers(parameter.type)
            ? NativeBlock.Scan.conservative : NativeBlock.Scan.no;
        auto scratch = NativeBlock.allocate(length, scan);
        writeValue(placeAt(scratch, parameter.type), value);

        assert(
            frameBytesAt(address, length) == scratch.bytes,
            "reference slot bind diverged from boxed argument",
        );
    }

    // Fills a nested `function_`'s own captured-outer-variable reference
    // slots (`frame_layout.capturedVariables`/`FrameLayout.Slot.Kind.
    // reference`, added to its layout alongside its `ref`/`out` parameter
    // slots) in `child`'s freshly allocated activation with THIS activation's
    // own address for each captured variable -- decision 15's "a captured
    // variable is the enclosing activation's storage, reached by address"
    // (`value.md`), composed as a verified SHADOW next to the boxed
    // `locals.dup` copy every nested-function call site already makes.
    // Authority stays with that boxed copy: nothing reads this slot yet, and
    // this function never touches `locals`/`_activationFrame` on either
    // `this` or `child` beyond reading them.
    //
    // No-op for a non-nested `function_`: `capturedVariables` is empty for
    // one, so the loop below never runs.
    //
    // Reuses `callerReferenceBase` exactly as `bindReferenceSlot` above
    // reuses it for a `ref`/`out` parameter -- the "caller" it resolves
    // against is THIS activation's own `_activationFrame`, since the
    // lexically enclosing activation for a captured variable IS the
    // activation making this call (this function runs on `this`, the
    // caller, never `child`; contrast `bindReferenceSlot`, which runs ON
    // `child` and is handed the caller's frame explicitly because of that).
    // A captured variable that is itself a `ref`/`out` parameter of the
    // enclosing function, or is itself a capture forwarded from a still-
    // further-out activation (a doubly-nested function directly naming a
    // grandparent's local -- DMD's own `outerVars` already flattens that
    // far), resolves the exact same way a forwarded `ref` argument does,
    // through `callerReferenceBase`'s own reference-slot branch. One
    // topology `callerReferenceBase` alone cannot resolve: a captured
    // variable relayed through an INTERMEDIATE activation that never
    // itself references it (so that activation's own frame has no slot for
    // it at all, owning or reference) -- e.g. `outer` declares `x`,
    // `middle` calls `inner`, and only `inner` reads `x`; DMD gives `inner`
    // a direct `outerVars` entry for `x`, but `middle`'s own frame was
    // never given a slot for `x` since `middle` itself never names it. A
    // real compiled closure walks a static-link chain through every
    // intermediate frame regardless of what it references itself; this
    // shadow has no such chain yet, so that case throws inside
    // `callerReferenceBase` (no owning or reference slot, not dataseg) and
    // declines exactly like any other unmirrored base -- a known gap for a
    // later slice, not a guess.
    //
    // Declines silently, exactly like `bindReferenceSlot`, for every one of
    // its decline conditions: no mirrored caller-side storage at all
    // (`callerReferenceBase`'s own throw), storage the write side never
    // established (also its throw, consulted here against THIS activation's
    // own `mirrorEstablished` for the same reason the frame passed is this
    // activation's own -- the enclosing activation IS the "caller" for a
    // capture), an eligible-but-never-filled reference slot read through,
    // or a composed address of `null`. A captured variable a cell owns
    // fills its slot but skips verification, exactly as a `ref` argument's
    // own cell-owned base does (`bindNotVerifiable`). Verification reuses
    // `assertReferenceBind` unchanged -- the same bind-time-only check,
    // the same skip when resolved through forwarding, the same silent
    // decline for a captured shape `place_value.isPlaceComposable` does
    // not compose (e.g. a captured slice, class, or array/AA) -- rather
    // than a parallel check, and only runs when this activation's own
    // `locals` still holds a boxed value for the captured variable to
    // compare against.
    //
    // Escape lifetime, carried forward for the authority switch rather than
    // solved here: a delegate created from `function_` can outlive THIS
    // activation (stored, returned, or called later, as the boxed world
    // already allows since it copies rather than references). Once native
    // storage becomes the sole authority, this slot's address must stay
    // valid for exactly as long as something can still call through it --
    // decision 17 answers this by making the frame block a GC allocation
    // (like DMD's own compiled closure frame), so a reference slot pointing
    // into it keeps that block alive the same way any other GC pointer
    // does; nothing in THIS slice depends on that, since authority is still
    // boxed and this shadow is read by nothing.
    private void bindCapturedReferenceSlots(
        imported!"dmd.func".FuncDeclaration function_,
        ref Walker child,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;

        if (!function_.isNested)
            return;

        foreach (variable; capturedVariables(function_)) {
            if (!child._activationFrame.hasReferenceSlot(variable))
                continue;

            bool bindNotVerifiable;
            void* address;
            try {
                address = callerReferenceBase(
                    variable,
                    _activationFrame,
                    &mirrorEstablished,
                    bindNotVerifiable,
                );
            } catch (Exception) {
                continue;
            }

            if (address is null)
                continue;

            child._activationFrame.setReferenceSlot(variable, address);

            if (!bindNotVerifiable)
                if (auto value = variable in locals)
                    assertReferenceBind(variable, address, *value);
        }
    }

    // A dynamic-array expression result can carry the allocation identity of
    // authoritative array storage even when its syntax is not a plain
    // variable (for example, a same-width scalar cast). Recover that storage
    // for a binding's own typed view instead of retaining only the boxed
    // element snapshot.
    private void bindArrayValueCell(
        VarDeclaration variable,
        in Value value,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        if (!value.isArray || value.arrayAllocationId == 0)
            return;

        const id = value.arrayAllocationId;
        auto sourceCell = id in arrayAllocationCarriers;
        if (sourceCell is null) {
            auto sourceVariable = id in arrayAllocationVariables;
            if (sourceVariable is null)
                return;

            sourceCell = *sourceVariable in arrayCells;
            if (sourceCell is null)
                return;

            arrayAllocationCarriers[id] = *sourceCell;
            sourceCell = id in arrayAllocationCarriers;
        }

        auto targetType = variable.type.toBasetype;
        if (!isDynamicArrayType(targetType))
            return;

        targetType = targetType.nextOf.toBasetype;
        if (
            !isNativeScalarType(sourceCell.elementType) ||
            !isNativeScalarType(targetType) ||
            typeByteSize(sourceCell.elementType) != typeByteSize(targetType)
        )
            return;

        const offset = value.arrayAllocationOffset;
        if (
            offset > sourceCell.length ||
            value.length > sourceCell.length - offset
        )
            return;

        arrayCells[variable] = sourceCell
            .slice(offset, offset + value.length)
            .reinterpretElements(targetType);
        arrayAllocationAliases[variable] = id;
    }

    // A `lazy` parameter is a delegate over the *caller's live frame*, not a
    // value captured at call time. `locals`
    // is a D associative array: a reference to a heap-allocated hash table.
    // Storing `callerLocals` here without `.dup` (and forwarding it without
    // `.dup` below, and substituting it without `.dup` in `runLazyArgument`)
    // makes the captured environment the *same* table the caller's `locals`
    // still points at, so any mutation performed while evaluating the lazy
    // expression (e.g. a forwarded range's cursor advancing) is visible to
    // the declaring frame immediately, exactly as it is for a real D
    // closure — no separate write-back step is needed. `callerFrame` is
    // captured the same way: the thunk runs on the callee's `Walker`, whose
    // own `_activationFrame` has no slot for the caller's locals, so
    // `runLazyArgument` swaps `_activationFrame` to this captured frame for
    // the duration of the thunk, keeping `setLocal`'s frame mirror pointed at
    // the local it is actually writing instead of silently skipping it.
    //
    // `callerMirrorEstablished`/`callerMirrorGenerations` are POINTERS to
    // the caller's own `mirrorEstablished`/`classMirrorGenerations`
    // fields (`bindFunctionParameters`' own identically named parameters,
    // forwarded from `child.bindFunctionParameters(..., &mirrorEstablished,
    // &classMirrorGenerations)` at every real call site), captured for the
    // same reason `callerLocals`/`callerFrame` are: `setLocal` inside the
    // thunk calls `mirrorClassToFrame`, which records its write/decline
    // decision into `this.mirrorEstablished`/`this.classMirrorGenerations`
    // -- the CALLEE's own fields -- even while `locals`/`_activationFrame`
    // are swapped to write the actual bytes into the CALLER's storage. Left
    // unswapped, that write-decision bookkeeping lands on a map nobody ever
    // reads again (this activation's own, orphaned once the thunk returns),
    // while the CALLER's own map -- the one a later read of the mutated
    // variable actually consults -- keeps whatever STALE decision it
    // recorded before the call, now describing a value the thunk's `setLocal`
    // already changed. See `runLazyArgument`'s own comment for how the swap
    // (and the null-AA-safe write-back through these pointers) works.
    private void bindLazyFunctionParameter(
        VarDeclaration parameter,
        Expression argumentExpression,
        Value[VarDeclaration] callerLocals,
        FrameBlock callerFrame,
        bool[VarDeclaration]* callerMirrorEstablished,
        size_t[size_t][VarDeclaration]* callerMirrorGenerations,
    ) {
        // Same fresh-binding rule as `bindFunctionParameters`: a lazy
        // parameter is still a new
        // stack slot for its own `VarDeclaration`, so drop any inherited/
        // stale cell.
        dropNonClassCells(parameter);
        setLocal(parameter, Value.undisplayable);

        if (auto variable = lazyExpressionVariable(argumentExpression)) {
            if (auto expression = variable in lazyArgumentExpressions) {
                lazyArgumentExpressions[parameter] = *expression;
                if (auto captured = variable in lazyArgumentLocals)
                    lazyArgumentLocals[parameter] = *captured;
                if (auto capturedFrame = variable in lazyArgumentFrames)
                    lazyArgumentFrames[parameter] = *capturedFrame;
                if (
                    auto capturedMirrorEstablished =
                        variable in lazyArgumentMirrorEstablished
                )
                    lazyArgumentMirrorEstablished[parameter] =
                        *capturedMirrorEstablished;
                if (
                    auto capturedMirrorGenerations =
                        variable in lazyArgumentClassMirrorGenerations
                )
                    lazyArgumentClassMirrorGenerations[parameter] =
                        *capturedMirrorGenerations;
                return;
            }
        }

        if (argumentExpression is null)
            throw new Exception("Unsupported interpreter call arguments.");

        lazyArgumentExpressions[parameter] = argumentExpression;
        lazyArgumentLocals[parameter] = callerLocals;
        lazyArgumentFrames[parameter] = callerFrame;
        lazyArgumentMirrorEstablished[parameter] = callerMirrorEstablished;
        lazyArgumentClassMirrorGenerations[parameter] = callerMirrorGenerations;
    }

    private Value runLazyArgument(VarDeclaration variable) {
        auto expression = variable in lazyArgumentExpressions;
        if (expression is null)
            throw new Exception("Unsupported eval call.");

        auto captured = variable in lazyArgumentLocals;
        if (captured is null)
            throw new Exception("Unsupported eval call.");

        auto capturedFrame = variable in lazyArgumentFrames;
        if (capturedFrame is null)
            throw new Exception("Unsupported eval call.");

        auto capturedMirrorEstablished = variable in lazyArgumentMirrorEstablished;
        if (capturedMirrorEstablished is null)
            throw new Exception("Unsupported eval call.");

        auto capturedMirrorGenerations = variable in lazyArgumentClassMirrorGenerations;
        if (capturedMirrorGenerations is null)
            throw new Exception("Unsupported eval call.");

        auto savedLocals = locals;  // mutated below while evaluating the thunk
        auto savedFrame = _activationFrame;
        auto savedMirrorEstablished = mirrorEstablished;
        auto savedMirrorGenerations = classMirrorGenerations;
        scope(exit) {
            // Write whatever the thunk produced -- the SAME table mutated in
            // place, or (see `lazyArgumentMirrorEstablished`'s own field
            // comment) a fresh one if the caller's own field started `null`
            // -- back through the captured pointers before restoring this
            // activation's own fields, so the caller's NEXT read (after
            // `runLazyArgument` returns) sees the decision the thunk's own
            // `setLocal` actually recorded, not this activation's unrelated
            // bookkeeping.
            *(*capturedMirrorEstablished) = mirrorEstablished;
            *(*capturedMirrorGenerations) = classMirrorGenerations;
            locals = savedLocals;
            _activationFrame = savedFrame;
            mirrorEstablished = savedMirrorEstablished;
            classMirrorGenerations = savedMirrorGenerations;
        }

        // No `.dup`: see the comment on `bindLazyFunctionParameter`. `locals`
        // becomes the caller's own live table for the duration of the thunk,
        // and `_activationFrame` becomes the caller's own frame so a mutation
        // the thunk performs (`setLocal`) mirrors into the slot the caller
        // will actually read afterwards, instead of the callee's unrelated
        // frame silently discarding it. `mirrorEstablished`/
        // `classMirrorGenerations` swap the same way, through the captured
        // pointers, so `setLocal`'s own `mirrorClassToFrame` call records its
        // write/decline decision into the CALLER's bookkeeping instead of
        // this activation's own (see `bindLazyFunctionParameter`'s header for
        // why that divergence is unsafe).
        locals = *captured;
        _activationFrame = *capturedFrame;
        mirrorEstablished = *(*capturedMirrorEstablished);
        classMirrorGenerations = *(*capturedMirrorGenerations);
        return runLazyArgumentExpression(*expression);
    }

    private Value runLazyArgumentExpression(Expression expression) {
        if (auto function_ = functionPointerExpressionFunction(expression))
            return runFunction(function_, [], [], true);

        return runExpression(expression);
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

    private void recordParameterSliceAlias(
        VarDeclaration parameter,
        in Value argument,
        imported!"dmd.expression".Expression argumentExpression,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        auto slice = argumentExpression is null
            ? null
            : argumentExpression.isSliceExp;
        if (slice is null || !argument.isArray) {
            recordForwardedArrayAllocationAlias(
                parameter,
                argument,
                argumentExpression,
            );
            sliceAliases.remove(parameter);
            return;
        }

        if (isPointerType(slice.e1.type)) {
            recordPointerSliceAllocationAlias(parameter, argument);
            sliceAliases.remove(parameter);
            return;
        }

        auto var = slice.e1.isVarExp;
        if (var is null) {
            sliceAliases.remove(parameter);
            return;
        }

        auto source = var.var.isVarDeclaration;
        if (source is null) {
            sliceAliases.remove(parameter);
            return;
        }

        auto sourceAlias = source in sliceAliases;
        sliceAliases[parameter] = SliceAlias(
            sourceAlias is null ? source : sourceAlias.source,
            argument.arrayAllocationOffset,
        );
    }

    private void recordPointerSliceAllocationAlias(
        VarDeclaration parameter,
        in Value argument,
    ) {
        if (argument.arrayAllocationId == 0) {
            arrayAllocationAliases.remove(parameter);
            return;
        }

        arrayAllocationAliases[parameter] = argument.arrayAllocationId;
    }

    private void recordForwardedArrayAllocationAlias(
        VarDeclaration parameter,
        in Value argument,
        imported!"dmd.expression".Expression argumentExpression,
    ) {
        auto var = argumentExpression is null
            ? null
            : argumentExpression.isVarExp;
        if (var is null) {
            if (argument.isArray && argument.arrayAllocationId != 0)
                arrayAllocationAliases[parameter] = argument.arrayAllocationId;
            else
                arrayAllocationAliases.remove(parameter);
            return;
        }

        auto source = var.var.isVarDeclaration;
        if (source is null) {
            arrayAllocationAliases.remove(parameter);
            return;
        }

        auto alias_ = source in arrayAllocationAliases;
        if (alias_ is null) {
            arrayAllocationAliases.remove(parameter);
            return;
        }

        arrayAllocationAliases[parameter] = *alias_;
    }

    private void writeBackRefArguments(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in Value[] arguments,
    ) {
        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (!parameter.isReference)
                continue;

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            if (argument is null)
                continue;

            if (auto value = parameter in child.locals) {
                // Compiled D never re-evaluates a `ref` argument's lvalue
                // expression to write a value back: it binds the address once
                // at the call and the callee either writes through it or
                // doesn't. This simulation instead re-runs the argument
                // expression to locate the write destination, which is only
                // safe when the callee actually changed the parameter — an
                // unconditional write-back re-executes a side-effecting
                // location expression (e.g. `shouldEqual(*dec.value!(int*),
                // ...)`, whose `ref` argument `*dec.value!(int*)` re-runs the
                // decoding call itself) even though the callee only ever read
                // it. Skip the whole write-back (and its re-evaluation) when
                // the parameter's value is unchanged. Use `identicalValues`,
                // not plain `==`, for this comparison: for floating scalars
                // D's `==` considers `-0.0 == +0.0` and `NaN != NaN`, either
                // of which would give the wrong skip decision here (dropping
                // a real `+0.0` writeback, or re-executing a side-effecting
                // argument expression because an unchanged `NaN` looks
                // "changed").
                if (index < arguments.length && identicalValues(*value, arguments[index]))
                    continue;

                if (isDynamicArrayPointerRefArgument(argument)) {
                    writeLocation(argument, *value);
                    continue;
                }

                if (value.isArray && value.arrayNativeAddress !is null)
                    if (auto var = argument.isVarExp)
                        if (auto variable = var.var.isVarDeclaration) {
                            dropArrayCell(variable);
                            setLocal(variable, *value);
                            uninitializedLocals.remove(variable);
                            promoteArrayCell(variable);
                            continue;
                        }

                // A `ref` argument spelled `*pointer` (core.atomic's shared
                // overloads forward `*cast(T*)&val`): write back through the
                // pointer's target.
                if (argument.isPtrExp !is null) {
                    writeLocation(argument, *value);
                    continue;
                }

                if (!isWritableLocation(argument))
                    continue;

                // This is the cross-frame `ref` array-parameter writeback
                // case: `*value`
                // MAY genuinely represent the SAME storage `argument`
                // already denotes (the callee mutated it through the
                // aliased `ref` parameter), in which case a same-length
                // `arrayCells` entry may be refreshed in place -- but the
                // callee may instead have REBOUND `parameter` to a brand-new
                // same-length array (`p = [x, y];`), which must NOT be
                // refreshed in place or it corrupts the bytes a separate,
                // still-live alias (e.g. a pre-existing slice view) keeps
                // pointing at the OLD storage.
                // `arrayWritebackIsMutation` tells the two apart from
                // `child`'s own `arrayRebinds` marker for `parameter`.
                writeLocation(argument, *value, arrayWritebackIsMutation(parameter, child));
            }
        }
    }

    // Used only for writeBackRefArguments' unchanged-parameter skip decision.
    // Floating scalars compare by bit pattern (D's `is` semantics for
    // floats), not `==`: `-0.0 is not +0.0` (so a real sign-of-zero write
    // still triggers a write-back) and `NaN is NaN` (so an unchanged NaN
    // ref argument still gets skipped instead of re-executing its location
    // expression). Every other kind defers to the existing `==`.
    private bool identicalValues(in Value left, in Value right) {
        if (left.isFloatingScalar && right.isFloatingScalar)
            return left.asReal is right.asReal;

        return left == right;
    }

    // D slices passed inside a by-value struct share their backing array with
    // the caller.  Write back element mutations (up to the original length)
    // so that element writes inside the callee are visible to the caller,
    // while descriptor changes (append, reassignment) do not leak.
    private void writeBackByValueStructArguments(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (parameter.isReference)
                continue;

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            if (argument is null || !isWritableLocation(argument))
                continue;

            auto finalParam = parameter in child.locals;
            if (finalParam is null || !finalParam.isStruct)
                continue;

            const original = runExpression(argument);
            if (!original.isStruct)
                continue;

            const fieldCount = original.structFieldCount;
            if (finalParam.structFieldCount != fieldCount)
                continue;

            Value updatedStruct = original;
            bool anyChange;
            foreach (fieldIndex; 0 .. fieldCount) {
                const origField = original.structFieldAt(fieldIndex);
                const finalField = finalParam.structFieldAt(fieldIndex);
                if (!origField.isArray || !finalField.isArray)
                    continue;

                const origLen = origField.length;
                const finalLen = finalField.length;
                const copyLen = origLen < finalLen ? origLen : finalLen;
                if (copyLen == 0)
                    continue;

                Value updatedField = origField;
                foreach (elemIdx; 0 .. copyLen)
                    updatedField = updatedField.withArrayElement(elemIdx, finalField[elemIdx]);

                updatedStruct = updatedStruct.withStructField(fieldIndex, updatedField);
                anyChange = true;
            }

            if (anyChange)
                writeLocation(argument, updatedStruct);
        }
    }

    private Value runEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;

        const left = runExpression(equal.e1);
        const right = runExpression(equal.e2);
        const same = equalValues(left, right);
        if (equal.op == EXP.notEqual)
            return Value(!same);
        return Value(same);
    }

    private bool equalValues(in Value left, in Value right) {
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

        if (AggregateValue.isStruct(left) && AggregateValue.isStruct(right))
            return equalStructValues(left, right);

        return left == right;
    }

    private bool equalArrayValues(in Value left, in Value right) {
        if (AggregateValue.length(left) != AggregateValue.length(right))
            return false;

        foreach (index; 0 .. AggregateValue.length(left))
            if (!equalValues(
                AggregateValue.elementAt(left, index),
                AggregateValue.elementAt(right, index),
            ))
                return false;

        return true;
    }

    // A struct field written by anything other than an enum-typed literal
    // `IntegerExp` (default-init, arithmetic, a cast/pointer write-back, ...)
    // keeps its plain scalar `Value` kind instead of `runExpression`'s
    // `Value.enumValue` tagging, so a raw `Value == Value` compare (the
    // `left == right` fallback above) never considers it equal to a
    // same-valued `EnumValue`-tagged field, even though real D's memberwise
    // struct equality does. Recurse field-by-field through `equalValues`
    // (mirroring `equalArrayValues`) so each field gets the same
    // numeric-scalar coercion a top-level `==` already applies.
    private bool equalStructValues(in Value left, in Value right) {
        const count = AggregateValue.fieldCount(left);
        if (count != AggregateValue.fieldCount(right))
            return false;

        foreach (index; 0 .. count)
            if (!equalValues(
                AggregateValue.fieldAt(left, index),
                AggregateValue.fieldAt(right, index),
            ))
                return false;

        return true;
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

    private Value runCompoundAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        const left = runExpression(assign.e1);
        const right = runExpression(assign.e2);
        const value = compoundAssignedValue(assign, left, right);
        writeLocation(assign.e1, value);
        return runExpression(assign.e1);
    }

    private Value compoundAssignedValue(
        imported!"dmd.expression".BinExp assignment,
        in Value left,
        in Value right,
    ) {
        import dmd.tokens: EXP;

        switch (assignment.op) {
            case EXP.addAssign:
                if (left.isPointer)
                    return left.pointerOffsetBy(
                        pointerElementOffset(assignment.e1.type, right.asLong),
                    );
                return left + right;

            case EXP.minAssign:
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

    private Value runPowExpression(imported!"dmd.expression".PowExp pow) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const base = runExpression(pow.e1);
        auto exponent = runExpression(pow.e2).asLong;
        if (exponent < 0)
            throw new Exception("Unsupported negative integer exponent.");

        Value result = backendCastValue(Value(1), backendCastTarget(pow.type));
        Value factor = backendCastValue(base, backendCastTarget(pow.type));
        while (exponent != 0) {
            if ((exponent & 1) != 0)
                result = result * factor;
            exponent >>= 1;
            if (exponent != 0)
                factor = factor * factor;
        }

        return backendCastValue(result, backendCastTarget(pow.type));
    }

    private Value runIntegerComplementExpression(
        imported!"dmd.expression".ComExp complement,
    ) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        return backendCastValue(
            Value(~runExpression(complement.e1).asLong),
            backendCastTarget(complement.type),
        );
    }

    private Value runIntegerBinaryExpression(
        imported!"dmd.expression".BinExp expression,
        in string operator,
    ) {
        return runIntegerBinaryValue(
            expression,
            runExpression(expression.e1),
            runExpression(expression.e2),
            operator,
        );
    }

    private Value runIntegerBinaryValue(
        imported!"dmd.expression".BinExp expression,
        in Value leftValue,
        in Value rightValue,
        in string operator,
    ) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

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
                return backendCastValue(
                    Value(unsignedShiftRight(leftValue, expression.e1.type, right)),
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

        return backendCastValue(Value(result), backendCastTarget(expression.type));
    }

    private ulong unsignedShiftRight(
        in Value value,
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

    private Value runDotVarExpression(imported!"dmd.expression".DotVarExp dot) {
        import quickbite.backends.interpreter.messages: receiverName;
        import std.conv: text;

        if (declarationName(dot.var) == "classinfo")
            return runClassInfoExpression(dot);

        if (declarationName(dot.var) == "name")
            if (auto typeid_ = dot.e1.isTypeidExp)
                return Value(typeInfoName(typeidObjectType(typeid_)));

        if (declarationName(dot.var) == "name")
            if (auto symbol = dot.e1.isSymOffExp)
                if (auto type = symbolOffsetTypeInfoType(symbol))
                    return Value(typeInfoName(type));

        if (declarationName(dot.var) == "name")
            if (dot.e1.isPtrExp !is null)
                return runClassInfoNameOwnerExpression(dot.e1);

        const receiver = runExpression(dot.e1);
        if (receiver == Value.null_)
            throw new Exception(text(
                "class `",
                receiverName(dot.e1),
                "` is `null` and cannot be dereferenced",
            ));

        if (receiver.isFunctionPointer && receiver.functionPointerId in delegates)
            return delegateProperty(receiver, declarationName(dot.var));

        if (receiver.isTypeName && declarationName(dot.var) == "name")
            return Value(receiver.asTypeNameString);

        if (dot.var.isVarDeclaration !is null) {
            const target = receiver.isLocalPointer
                ? localPointerTarget(receiver)
                : receiver;
            if (AggregateValue.isClass(target)) {
                const fieldIndex = classFieldIndex(dot, target);

                // `dot.e1`'s own
                // `classCells` entry, when present, is authoritative over
                // this receiver's independent boxed copy -- it may be a
                // SHARED cell (another alias's write lands here too) or a
                // cell an earlier `&c.field` promoted directly. Falls back
                // to the existing boxed read for every other receiver (no
                // cell at all, the common unaliased/unpromoted case).
                Value cellValue;
                if (classCellFieldValue(dot.e1, fieldIndex, target, cellValue))
                    return cellValue;

                return AggregateValue.classFieldAt(target, fieldIndex);
            }
            return AggregateValue.fieldAt(target, structFieldIndex(dot));
        }

        throw new Exception("Unsupported interpreter field read.");
    }

    // Shared receiver-to-`classCells`-key resolution for `classCellFieldValue`
    // and `writeClassCellFieldIfPresent` below: a bare `VarExp` resolves to
    // its own `VarDeclaration`, exactly
    // as before this slice. A bare `ThisExp` (the receiver of `this.field`
    // inside a method body) resolves to `currentFunction.vthis` -- the
    // hidden `this` parameter's `VarDeclaration`, dmd's own stable per-
    // function identity for it -- which is exactly the key
    // `registerClassThisAlias` seeds `child.classCells` under. Any other
    // receiver shape (e.g. `makeC().field`, `super.field`) resolves to
    // `null`, matching the pre-existing VarExp-only behaviour for every
    // other case.
    private VarDeclaration classCellKeyVariable(
        imported!"dmd.expression".Expression receiverExpression,
    ) {
        if (auto var = receiverExpression.isVarExp)
            return var.var.isVarDeclaration;

        if (receiverExpression.isThisExp !is null)
            return currentFunction is null ? null : currentFunction.vthis;

        return null;
    }

    // Re-derives
    // `receiverExpression`'s CURRENT value from its own `classCells` entry,
    // when one exists, before a whole-object field write folds ONE field's
    // new value into it. Without this, `writeLocation`'s `DotVarExp` arm (and
    // the class-array-field write arms) read `boxedValue` from the STALE
    // plain-`VarExp` path (`runExpression`'s `VarExp` arm has no
    // `classValueFromCell` overlay -- only the 3 cross-frame writeback
    // helpers use one), so every OTHER field of `boxedValue` could already be
    // out of date with a cell another alias had just written through
    // (`writeClassCellFieldIfPresent`/`writeClassCellScalarFields`). Folding
    // the new field into that stale snapshot and refreshing the (possibly
    // SHARED) cell from it -- via `writeCelledLocal`'s own
    // `classFieldRefresh` refresh -- would silently overwrite the other
    // alias's write with the stale value it had before that write ever
    // happened. A no-op (returns `boxedValue` unchanged) when
    // `classCellKeyVariable` cannot resolve `receiverExpression`, or the
    // resolved variable has no `classCells` entry -- the common unaliased/
    // unpromoted case -- reusing `classValueFromCell`, the same read-side
    // overlay the cross-frame writeback helpers already trust.
    private Value classCellOverlaidValue(
        imported!"dmd.expression".Expression receiverExpression,
        in Value boxedValue,
    ) {
        if (!boxedValue.isClassObject)
            return boxedValue;

        auto cell = boxedValue.classIdentity in classObjectCells;
        if (cell is null)
            return boxedValue;

        auto classType = receiverExpression.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return boxedValue;

        return classValueFromCell(boxedValue, *cell, classType.sym);
    }

    // Read-side counterpart of `writeClassCellFieldIfPresent` below, and the
    // direct-field-read sibling of `classFieldPointerCellValue` (which
    // serves pointer DEREF reads): `receiverExpression` must resolve to a
    // `classCells` key via `classCellKeyVariable` above (a bare `VarExp`, or
    // a bare `ThisExp` resolving to `currentFunction.vthis`), and
    // `fieldIndex` must be a supported scalar or aggregate-composition field,
    // or this returns
    // `false` and leaves `value` untouched -- every one of those keeps the
    // caller's existing boxed fallback unchanged. `target` is the caller's
    // already-computed boxed receiver value (`runDotVarExpression`'s own
    // `target`), consulted ONLY as the array-field widening's starting
    // shape (`.isArray`/`.length`) -- every element is then overwritten from
    // the shared cell's bytes, exactly as `classArrayFieldPointerCellValue`
    // already does for the pointer-deref read side and
    // `writeClassCellScalarFields` already does for the write side that
    // keeps this cell current.
    private bool classCellFieldValue(
        imported!"dmd.expression".Expression receiverExpression,
        in size_t fieldIndex,
        in Value target,
        out Value value,
    ) {
        import quickbite.backends.interpreter.layout:
            classFields, fieldByteOffset, staticArrayLength, typeByteSize;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        if (!target.isClassObject)
            return false;

        auto cell = target.classIdentity in classObjectCells;
        if (cell is null)
            return false;

        auto classType = receiverExpression.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return false;

        auto fields = classFields(classType.sym);
        if (fieldIndex >= fields.length)
            return false;

        auto field = fields[fieldIndex];

        if (isNativeScalarType(field.type)) {
            const offset = fieldByteOffset(field);
            const size = typeByteSize(field.type);
            value = readScalar(field.type, cell.bytes[offset .. offset + size]);
            return true;
        }

        if (isStaticArrayType(field.type)) {
            auto elementType = field.type.toBasetype.nextOf.toBasetype;
            auto structType = elementType.isTypeStruct;
            if (!isNativeScalarType(elementType) && (
                structType is null ||
                structType.sym.isUnionDeclaration !is null
            ))
                return false;

            const fieldValue = target.classFieldAt(fieldIndex);
            if (!fieldValue.isArray)
                return false;

            const offset = fieldByteOffset(field);
            const size = typeByteSize(field.type);
            auto arrayCell = NativeArray.adopt(
                cell.subRange(offset, size),
                elementType,
                staticArrayLength(field.type.toBasetype.isTypeSArray),
            );
            Value result = fieldValue;
            foreach (elementIndex; 0 .. fieldValue.length) {
                Value elementValue;
                if (structType !is null) {
                    auto elementCell = arrayCell.structElement(elementIndex);
                    elementValue = structValueFromCell(
                        fieldValue[elementIndex],
                        elementCell,
                    );
                } else
                    elementValue = readScalar(
                        elementType,
                        arrayCell.element(elementIndex),
                    );
                result = result.withArrayElement(
                    elementIndex,
                    elementValue,
                );
            }
            value = result;
            return true;
        }

        if (isDynamicArrayType(field.type)) {
            auto elementType = field.type.toBasetype.nextOf.toBasetype;
            auto structType = elementType.isTypeStruct;
            if (!isNativeScalarType(elementType) && (
                structType is null ||
                structType.sym.isUnionDeclaration !is null
            ))
                return false;

            const fieldValue = target.classFieldAt(fieldIndex);
            if (!fieldValue.isArray)
                return false;

            auto arrayCell = classSliceField(*cell, classType.sym, fieldIndex);
            value = arrayValueFromCell(fieldValue, arrayCell);
            return true;
        }

        // Aggregate composition, struct shape (the symmetric case to the
        // static-array branch above): a (non-union) struct-typed field. Reuses the exact
        // composition primitive `writeClassCellScalarFields`'s own struct
        // recursion already uses -- `NativeStruct.adopt` over the field's
        // own byte sub-range, since a `classCells` entry has no
        // `NativeStruct` wrapper of its own -- and then `structValueFromCell`
        // (the struct-receiver read-back this repo already established for
        // a plain struct local's own nested-struct fields) to overlay every
        // one of the nested struct's own scalar/array/struct fields onto the
        // caller's already-computed boxed field value.
        auto nestedStructType = field.type.toBasetype.isTypeStruct;
        if (nestedStructType !is null && nestedStructType.sym.isUnionDeclaration is null) {
            const fieldValue = target.classFieldAt(fieldIndex);
            if (!fieldValue.isStruct)
                return false;

            const offset = fieldByteOffset(field);
            const size = typeByteSize(field.type);
            auto nestedCell = NativeStruct.adopt(cell.subRange(offset, size), nestedStructType);
            value = structValueFromCell(fieldValue, nestedCell);
            return true;
        }

        return false;
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

    private Value runClassInfoExpression(
        imported!"dmd.expression".DotVarExp classInfo,
    ) {
        if (classInfo.e1.isTypeExp is null) {
            const receiver = runExpression(classInfo.e1);
            if (AggregateValue.isClass(receiver))
                return Value.typeName(AggregateValue.classTypeName(receiver));
        }

        return Value.typeName(typeInfoName(classInfo.e1.type));
    }

    private Value runClassInfoNameOwnerExpression(
        imported!"dmd.expression".Expression ownerExpression,
    ) {
        const receiver = runExpression(classInfoNameOwnerExpression(ownerExpression));
        if (AggregateValue.isClass(receiver))
            return Value(AggregateValue.classTypeName(receiver));

        throw new Exception("Unsupported interpreter field read.");
    }

    private imported!"dmd.expression".Expression classInfoNameOwnerExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        if (auto pointer = expression.isPtrExp)
            return classInfoNameOwnerExpression(pointer.e1);

        return expression;
    }

    private Value runDotIdentifierExpression(
        imported!"dmd.expression".DotIdExp dot,
    ) {
        const receiver = runExpression(dot.e1);
        const name = dot.ident is null ? "" : dot.ident.toString;
        if (name == "re")
            return receiver.complexRealPart;
        if (name == "im")
            return receiver.complexImaginaryPart;

        throw new Exception("Unsupported interpreter property read.");
    }

    private Value delegateProperty(in Value receiver, in string name) {
        auto runtime = receiver.functionPointerId in delegates;
        if (runtime is null)
            throw new Exception("Unsupported interpreter field read.");

        if (name == "ptr")
            return runtime.contextPointer;

        if (name == "funcptr")
            return Value.functionPointerValue(runtime.functionPointerId);

        throw new Exception("Unsupported interpreter field read.");
    }

    private Value runTypeidExpression(
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

            return typeidValue(typeid_, typeInfoName(type));
        }

        const value = runExpression(expression);
        if (value == Value.null_ || (isClassExpression(expression) &&
            value == Value(false)))
            throw new Exception(text(
                "null pointer dereference evaluating typeid. `",
                receiverName(expression),
                "` is `null`",
            ));

        if (AggregateValue.isClass(value))
            return typeidValue(typeid_, AggregateValue.classTypeName(value));

        return typeidValue(typeid_, typeInfoName(expression.type));
    }

    private Value typeidValue(
        imported!"dmd.expression".TypeidExp typeid_,
        in string name,
    ) {
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        return isCharacterArrayType(typeid_.type)
            ? Value(name)
            : Value.typeName(name);
    }

    private Value runVectorExpression(
        imported!"dmd.expression".VectorExp vector,
    ) {
        import quickbite.backends.interpreter.layout: staticArrayLength;

        auto staticArray = vector.to.basetype.toBasetype.isTypeSArray;
        if (staticArray is null)
            throw new Exception("Unsupported interpreter vector expression.");

        const value = runExpression(vector.e1);
        const length = staticArrayLength(staticArray);

        Value[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        return Value.arrayValue(elements);
    }

    private Value runAssignExpression(imported!"dmd.expression".BinExp assign) {
        if (auto pointer = assign.e1.isPtrExp)
            if (isAssocArraySlotPointer(pointer.e1))
                return runAssocArraySlotAssignExpression(pointer.e1, assign.e2);

        if (auto index = assign.e1.isIndexExp)
            return runIndexAssignExpression(index, assign.e2);

        if (auto slice = assign.e1.isSliceExp)
            return runSliceAssignExpression(slice, assign.e2);

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
        // through to `runExpression(assign.e2)` below, which evaluated the
        // `IntegerExp` as a scalar `Value(0)` and clobbered the parameter's
        // boxed struct value with a bare int.
        if (auto blit = assign.isBlitExp) {
            import quickbite.frontend.dmd.types: isStructType;

            if (blit.e2.isIntegerExp !is null && isStructType(assign.e1.type))
                if (auto var = assign.e1.isVarExp)
                    if (auto variable = var.var.isVarDeclaration) {
                        const value = defaultValue(variable);
                        writeLocation(assign.e1, value);
                        return value;
                    }
        }

        const value = runExpression(assign.e2);
        writeLocation(assign.e1, value);

        // Plain-variable assignments are bindings just like declaration
        // initializers: propagate storage-backed views and reference aliases
        // after `writeLocation` has dropped the target's previous binding.
        if (auto var = assign.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration) {
                bindArrayValueCell(variable, value);
                bindScalarArrayCastView(variable, assign.e2);
                registerClassAliasIfPlainVar(variable, assign.e2);
            }

        return value;
    }

    // `arrayRefWriteback`:
    // `writeBackRefArguments` is the only caller that ever passes `true`,
    // for a `VarExp` target's whole-array value written back from a `ref
    // int[]` parameter's callee-side final value, as opposed to a plain
    // source-level rebind (`s = b;`), which always passes the default
    // `false`. `true` here does NOT by itself mean "genuinely the same
    // storage, mutated in place" -- the callee may instead have REBOUND the
    // parameter, so `writeBackRefArguments`
    // computes this per call via `arrayWritebackIsMutation` rather than
    // hardcoding `true`. See `writeCelledLocal`'s own doc comment for why
    // the distinction matters and how it is resolved.
    // `classFieldRefresh`: `true` only from THIS function's own `DotVarExp` and
    // class-array-field-write recursions below, and from
    // `writeIndexLocation`/`runIndexAssignExpression`'s own class-array-field
    // arms and `writeThroughSliceAlias`'s class-field arm -- every one of
    // those first re-derives its receiver from the shared cell
    // (`classCellOverlaidValue`) before folding in the one field that
    // changed, so the recursive `writeLocation` call below may safely tell
    // `writeCelledLocal` this is an authoritative same-object refresh. Every
    // OTHER caller (a plain source-level `s = b;`, a fresh declaration, a
    // cross-frame writeback) keeps the default `false`: a class-typed
    // `VarExp` assignment reached any other way is, per the language's own
    // semantics (classes have no `opAssign`), always a reference REBIND, not
    // a field mutation of the SAME object -- see `writeCelledLocal`'s own
    // doc comment for why conflating the two corrupts a shared cell.
    private void writeLocation(
        imported!"dmd.expression".Expression target,
        in Value value,
        in bool arrayRefWriteback = false,
        in bool classFieldRefresh = false,
    ) {
        if (auto cast_ = target.isCastExp) {
            writeLocation(cast_.e1, value, arrayRefWriteback, classFieldRefresh);
            return;
        }

        if (auto var = target.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported interpreter assignment target.");

            // Mutable because frame/layout APIs take DMD declarations.
            auto referenceVariable = variable;
            variable = refLocalStorageVariable(variable);

            // A bound scalar ref/out parameter already names its caller's
            // storage through this activation's reference slot. Write that
            // place directly instead of allocating a parameter scalar cell
            // and waiting for return-time writeback to make it observable.
            import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
            if (
                referenceVariable.isReference &&
                _activationFrame.hasReferenceSlot(referenceVariable) &&
                _activationFrame.bindingAddress(referenceVariable) !is null &&
                isNativeScalarType(referenceVariable.type)
            ) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue, writeValue;
                import quickbite.backends.interpreter.layout: declaredType;

                auto place = Place(
                    _activationFrame.bindingAddress(referenceVariable),
                    declaredType(referenceVariable),
                );
                writeValue(place, storageValue(referenceVariable.type, value));
                setLocal(referenceVariable, readValue(place));
                uninitializedLocals.remove(referenceVariable);
                return;
            }

            // A native extern __gshared global's memory is the single source of
            // truth (ffi.md §35.2): write through to the resolved symbol and do
            // NOT cache in `locals`, or a later native mutation would be
            // shadowed by a stale copy. The read path (§35.2a) reifies from
            // native memory on every read.
            import quickbite.frontend.dmd.functions: isExternDataSymbol;
            if (isExternDataSymbol(variable)) {
                import quickbite.backends.interpreter.ffi_marshal: marshalNative;
                import quickbite.ffi: resolveDataSymbol;

                if (auto address = resolveDataSymbol(variable)) {
                    // A writable process-memory address belonging to the loaded
                    // dependency image, so the cast to a mutable pointer is safe.
                    marshalNative(variable.type.toBasetype, cast(void*) address,
                        storageValue(variable.type, value));
                    return;
                }
            }

            // Byte-level authority: once `&variable` has
            // promoted a cell, direct reads consult it (the `VarExp` arm of
            // `runExpression`) rather than the `locals` mirror below, so a
            // direct write must refresh the cell too, or a stale cell value
            // resurfaces on the next direct read even though `locals` (and
            // any pointer aliasing the cell) already moved on.
            // `writeCelledLocal` is exactly this cell-then-mirror pattern.
            writeCelledLocal(
                variable,
                storageValue(variable.type, value),
                arrayRefWriteback,
                classFieldRefresh,
            );

            writeThroughArrayElementAlias(variable, locals[variable]);
            writeThroughStructFieldAlias(variable, locals[variable]);
            if ((variable in arrayElementAliases) is null) {
                sliceAliases.remove(variable);
                structArrayFieldAliases.remove(variable);
            }
            return;
        }

        if (target.isThisExp !is null && hasThis) {
            thisValue = value;
            return;
        }

        if (target.isSuperExp !is null && hasThis) {
            thisValue = value;
            return;
        }

        if (auto dot = target.isDotVarExp) {
            const receiver = runExpression(dot.e1);
            if (receiver.isLocalPointer) {
                const targetValue = localPointerTarget(receiver);
                writeLocation(dot.e1, targetValue.isClassObject
                    ? AggregateValue.withClassField(targetValue, classFieldIndex(dot, targetValue), value)
                    : AggregateValue.withStructField(targetValue, structFieldIndex(dot), value));
                return;
            }

            if (receiver.isClassObject) {
                const fieldIndex = classFieldIndex(dot, receiver);

                // `receiver` above came from the plain `VarExp`/`ThisExp`
                // read path, which has no `classCells` overlay, so its OTHER
                // fields may already be stale relative to a cell another
                // alias just wrote through. Re-derive an authoritative
                // receiver from the cell (a no-op when `dot.e1` has none)
                // before folding in this field's write, so the whole-object
                // refresh below cannot clobber a sibling alias's write with
                // stale field values.
                const authoritative = classCellOverlaidValue(dot.e1, receiver);

                // mirror the write
                // into `dot.e1`'s own `classCells` entry, when present,
                // BEFORE the boxed write below -- a no-op unless `dot.e1`
                // is a bare `VarExp` with a cell (shared with another alias,
                // or promoted directly), matching `classCellFieldValue`'s
                // read-side authority so a later read through either
                // variable sees this write.
                writeClassCellFieldIfPresent(dot.e1, fieldIndex, value);
                writeLocation(
                    dot.e1,
                    AggregateValue.withClassField(authoritative, fieldIndex, value),
                    /* arrayRefWriteback */ false,
                    /* classFieldRefresh */ true,
                );
                return;
            }

            // A dynamic-array header can be reinterpreted as a two-field
            // struct through a pointer.  DMD's own __ArrayCast does this to
            // change the header length while retaining the data pointer.
            // The expression carrier remains an array because those are the
            // bytes' actual guest meaning; update its descriptor rather than
            // requiring a recursively-boxed struct snapshot.
            if (receiver.isArray && declarationName(dot.var) == "length") {
                writeLocation(dot.e1, receiver.withArrayLength(
                    cast(size_t) value.asLong,
                ));
                return;
            }

            const fieldIndex = structFieldIndex(dot);
            auto unionType = receiverStructType(dot.e1);
            const updated = unionType !is null && unionType.sym.isUnionDeclaration !is null
                ? withUnionFieldWrite(receiver, unionType, fieldIndex, value)
                : AggregateValue.withStructField(receiver, fieldIndex, value);
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
            const pointer = runExpression(ptr.e1);
            if (pointer.isLocalPointer) {
                auto variable = pointer.localPointerId in localPointers;
                if (variable is null)
                    throw new Exception("Unsupported interpreter assignment target.");

                // Byte-level reinterpret write: a
                // promoted cell exists, so write `value`'s bits in as the
                // pointer's pointee type, then refresh the `locals` mirror
                // by reading the local's own type back out. Without this,
                // `*p = x` through a differently-typed pointer stored the
                // boxed value verbatim -- a real bug vs SystemLinker.
                //
                // A NARROWER
                // native-scalar pointee (e.g. a `ubyte*` reinterpret of a
                // `uint`) writes only into the cell's low
                // `typeByteSize(pointeeType)` bytes -- mirroring
                // the read side's narrowing by slicing -- instead of
                // `writeScalar` throwing on a
                // length mismatch. A non-native-scalar pointee (or a wider
                // one, a pre-existing gap not this call site's to fix)
                // falls through to the boxed write below instead of
                // throwing.
                if (auto cell = *variable in scalarCells) {
                    import quickbite.backends.interpreter.layout: typeByteSize;
                    import quickbite.backends.interpreter.native_scalar:
                        isNativeScalarType, readScalar, writeScalar;

                    auto pointeeType = ptr.e1.type.toBasetype.nextOf.toBasetype;
                    const pointeeSize = typeByteSize(pointeeType);
                    if (
                        isNativeScalarType(pointeeType) &&
                        pointeeSize <= cell.bytes.length
                    ) {
                        writeScalar(pointeeType, cell.bytes[0 .. pointeeSize], value);
                        setLocal(*variable, readScalar((*variable).type, cell.bytes));
                        uninitializedLocals.remove(*variable);
                        return;
                    }

                    // A non-native-scalar pointee (e.g. a struct) or one
                    // wider than the cell cannot be modelled as a byte-level
                    // reinterpret write into the cell. Falling through to a
                    // mirror-only `locals` write here would leave the cell
                    // stale, so a later direct read (which consults the cell
                    // first) would silently return the wrong bytes. Throw
                    // instead of silently miswriting; SystemLinker's real
                    // memory can support this, the interpreter cannot yet.
                    throw new Exception("Unsupported interpreter assignment target.");
                }

                if (value.isArray) {
                    dropArrayCell(*variable);
                    arrayRebinds[*variable] = true;
                }
                setLocal(*variable, value);
                uninitializedLocals.remove(*variable);
                return;
            }

            // A dereferenced native pointer (e.g. a malloc'd struct like
            // std.stdio.File's Impl): write straight into native memory.
            if (pointer.isNativePointer) {
                storeNativePointerElement(ptr.e1.type, pointer, 0, value);
                return;
            }

            if (writeThroughPromotedPointer(pointer, value))
                return;

            // Every OTHER `&s.field` (addressOfExpression's DotVarExp
            // branch) yields a read-only value snapshot, not an alias to
            // the field: refuse loudly instead of silently rewriting the
            // throwaway pointer variable and losing the write.
            if (pointer.pointerAllocation in fieldSnapshotAllocationIds)
                throw new Exception("Unsupported interpreter assignment target.");

            writeLocation(ptr.e1, pointer.withPointerTarget(value));
            return;
        }

        import std.conv: text;
        throw new Exception(
            text("Unsupported interpreter assignment target: ", target.op),
        );
    }

    // Assignment through a ref-returning call (`f(i) = v`, `obj.slot() = v`):
    // run the callee for real — pre-return side effects happen exactly once —
    // and at the executed return statement write the value through the
    // returned lvalue (`assignToRefReturn` mode, the assignment counterpart
    // of `addressOfRefReturn`).
    private bool writeRefReturningCallLocation(
        imported!"dmd.expression".CallExp call,
        in Value value,
    ) {
        import dmd.funcsem: functionSemantic3;
        import quickbite.frontend.dmd.functions: hasNoAvailableSource;

        if (call.f is null || !returnsRef(call.f))
            return false;

        auto dot = call.e1.isDotVarExp;
        if (dot is null)
            return writeFreeRefReturningCallLocation(call, value);

        const receiver = runExpression(dot.e1);
        if (receiver == Value.null_)
            throw new Exception("function call through null class reference `null`");

        auto function_ = resolveMemberFunction(call.f, receiver);
        functionSemantic3(function_);
        if (hasNoAvailableSource(function_))
            return false;

        Value[] arguments;
        imported!"dmd.expression".Expression[] argumentExpressions;
        EvaluatedReferenceArgument[] evaluatedArguments;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments ~= index < function_.parameters.length &&
                    (*function_.parameters)[index].isReference
                    ? runRefArgumentExpression(argument, evaluated)
                    : runExpression(argument);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
            }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.assignToRefReturn = true;
        child.refReturnAssignedValue = value;
        child.result = Value(false);
        child.locals = locals.dup;
        forkPerFrameCellsInto(child);
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            &classMirrorGenerations,
            evaluatedArguments,
        );

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackMemberFunctionState(
                function_,
                dot.e1,
                argumentExpressions,
                child,
                arguments,
            );
            throw exception;
        }
        writeBackMemberFunctionState(
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
        in Value value,
    ) {
        import dmd.funcsem: functionSemantic3;
        import quickbite.frontend.dmd.functions: hasNoAvailableSource;

        functionSemantic3(call.f);
        if (call.f.needThis)
            return false;

        Value[] arguments;
        imported!"dmd.expression".Expression[] argumentExpressions;
        EvaluatedReferenceArgument[] evaluatedArguments;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments ~= index < call.f.parameters.length &&
                    (*call.f.parameters)[index].isReference
                    ? runRefArgumentExpression(argument, evaluated)
                    : runExpression(argument);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
            }

        if (hasNoAvailableSource(call.f)) {
            import quickbite.backends.interpreter.ffi_marshal:
                NativeCallException, tryAssignNativeRefReturn;

            try {
                return tryAssignNativeRefReturn(
                    call.f,
                    arguments,
                    nativeArgumentTypes(argumentExpressions),
                    nativeAddressOfLocalArguments(argumentExpressions),
                    value,
                );
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
        child.result = Value(false);
        child.locals = call.f.isNested ? locals.dup : datasegLocals;
        bindCapturedReferenceSlots(call.f, child);
        forkPerFrameCellsInto(child);
        seedPointerTargetLocals(child);
        child.bindFunctionParameters(
            call.f,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            &classMirrorGenerations,
            evaluatedArguments,
        );

        try {
            child.runStatement(call.f.fbody);
        } catch (InterpretedException exception) {
            writeBackFunctionState(call.f, argumentExpressions, child, arguments);
            throw exception;
        }
        writeBackFunctionState(call.f, argumentExpressions, child, arguments);
        return true;
    }

    private void writeArrayLengthLocation(
        imported!"dmd.expression".ArrayLengthExp target,
        in Value value,
    ) {
        import quickbite.frontend.dmd.types: arrayElementType;

        const current = runExpression(target.e1);
        const oldLength = current == Value.null_ ? 0 : current.length;
        const newLength = cast(size_t) value.asLong;

        Value[] elements;
        foreach (index; 0 .. newLength)
            elements ~= index < oldLength
                ? current[index]
                : runDefaultValue(arrayElementType(target.e1.type));

        writeLocation(target.e1, Value.arrayValue(elements));
    }

    private Value runDefaultValue(imported!"dmd.mtype".Type type) {
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;

        return runExpression(type.defaultInitLiteral(Loc.initial));
    }

    private Value storageValue(
        imported!"dmd.mtype".Type type,
        in Value value,
    ) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastValue = castValue,
            CastTarget,
            tryCastTarget;
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        if (type is null)
            return value;

        if (value.isTypeName && isCharacterArrayType(type))
            return Value(value.asTypeNameString);

        CastTarget target;
        if (!tryCastTarget(type, target))
            return value;

        return backendCastValue(value, target);
    }

    // Delegates to `native_scalar.writeScalar` -- the single scalar<->bytes
    // authority -- rather than re-deriving a
    // scalar's byte width and bit pattern here; this module must not grow
    // its own second set of D layout rules alongside that codec's.
    private Value[] scalarBytes(
        imported!"dmd.mtype".Type type,
        in Value value,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_scalar: writeScalar;

        auto raw = new ubyte[](typeByteSize(type));
        writeScalar(type, raw, value);

        Value[] bytes;
        foreach (byte_; raw)
            bytes ~= Value(byte_);
        return bytes;
    }

    private Value scalarWithByte(
        imported!"dmd.mtype".Type type,
        in Value current,
        in size_t index,
        in Value byte_,
    ) {
        import std.conv: text;

        auto bytes = scalarBytes(type, current);
        if (index >= bytes.length)
            throw new Exception(text("Scalar byte index out of bounds: ", index));

        bytes[index] = Value(cast(ubyte) byte_.asLong);
        return scalarFromBytes(type, bytes);
    }

    // The inverse of `scalarBytes` above, via `native_scalar.readScalar`.
    // This also now succeeds for `float`/`double`: routing through the
    // single scalar<->bytes codec dropped the old name-matched `switch`'s
    // throw on those two types.
    private Value scalarFromBytes(
        imported!"dmd.mtype".Type type,
        in Value[] bytes,
    ) {
        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto raw = new ubyte[](bytes.length);
        foreach (index, byte_; bytes)
            raw[index] = cast(ubyte) byte_.asLong;

        return readScalar(type, raw);
    }

    // Apply the elements a native call wrote through pointers into
    // interpreter-managed arrays (e.g. posix read filling `buf.ptr + n`)
    // back into the arrays the pointers came from.
    private void applyPointerElementsWritebacks(
        in imported!"quickbite.backends.interpreter.ffi_marshal"
            .PointerElementsWriteback[] writebacks,
    ) {
        foreach (writeback; writebacks)
            foreach (index, element; writeback.elements)
                writeThroughArrayPointer(
                    writeback.pointer.pointerOffsetBy(cast(long) index),
                    element,
                );
    }

    private bool writeThroughArrayPointer(in Value pointer, in Value value) {
        auto variable = arrayPointerVariable(pointer);
        if (variable is null)
            return false;

        auto current = *variable in locals;
        if (current is null)
            return false;

        if (!current.isArray) {
            setLocal(*variable, scalarWithByte(
                (*variable).type,
                *current,
                cast(size_t) pointer.pointerElementOffset,
                value,
            ));
            arrayPointerWritebacks[*variable] = true;
            uninitializedLocals.remove(*variable);
            return true;
        }

        setLocal(*variable, AggregateValue.withArrayElement(*current,
            cast(size_t) pointer.pointerElementOffset,
            value,
        ));
        // A write THROUGH the pointer (`*p = x`, `p[k] = x`) must refresh the
        // same promoted `arrayCells` entry a direct element write
        // (`writeIndexLocation`) already keeps current, or a second pointer
        // into the same element -- or a re-read through this one, both of
        // which consult the cell first (`runPointerExpression`) -- would see
        // stale bytes. A no-op when no cell was ever promoted for `variable`.
        writeThroughArrayCell(
            *variable,
            cast(size_t) pointer.pointerElementOffset,
            value,
        );
        arrayPointerWritebacks[*variable] = true;
        uninitializedLocals.remove(*variable);
        return true;
    }

    // Write-through-pointer counterpart of `structFieldPointerCellValue`
    // (the write side of the struct-field-pointer aliasing whose read side
    // `structFieldPointerCellValue` already handles): once `&s.field` has
    // promoted a `structCells` entry, `*p = value` writes `value`'s bytes
    // straight into the cell's field slice and re-derives the boxed
    // `locals` mirror from the (already-updated) whole struct, exactly the
    // same cell-then-mirror discipline `writeCelledLocal`/
    // `writeThroughArrayCell` already use for the direct-write and
    // array-element-pointer cases. Returns `false` (writing nothing) for
    // every field pointer that never promoted a cell -- no `structCells`
    // entry for the receiver, no reverse-lookup field index, or a receiver
    // whose boxed value is no longer a struct -- leaving `writeLocation`'s
    // `PtrExp` arm to keep refusing those exactly as before.
    //
    // `current` (the receiver's own boxed value) can be absent here even on
    // a genuine hit: a CROSS-FRAME write (`variable` is the CALLER's own
    // local, `id` recorded before the call and shared into this callee's
    // frame only via the duped `fieldPointerPaths`/`structCells`)
    // finds `variable` in neither this frame's parameters nor its `locals`
    // at all -- it was never bound here. The write still lands in the
    // shared cell either way; `structFieldPointerWritebacks` flags
    // `variable` so `writeBackStructFieldPointerTargets` can re-derive the
    // OWNING frame's boxed mirror once control returns there (a direct
    // field read never consults `structCells` itself, unlike an array
    // element read -- see `runDotVarExpression` vs `runIndexExpression`).
    // `current`, when present, still declines a rebind (no longer a
    // struct) exactly as before.
    private bool writeThroughStructFieldPointer(in Value pointer, in Value value) {
        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 1)
            return false;

        auto variable = path.root;

        auto cell = variable in structCells;
        if (cell is null)
            return false;

        const fieldIndex = path.indices[0];

        auto current = variable in locals;
        if (current !is null && !current.isStruct)
            return false;

        import quickbite.backends.interpreter.native_scalar: writeScalar;

        writeScalar(
            cell.fieldDeclaration(fieldIndex).type,
            cell.field(fieldIndex),
            value,
        );
        if (current !is null)
            setLocal(variable, AggregateValue.withStructField(*current, fieldIndex, value));
        structFieldPointerWritebacks[variable] = true;
        uninitializedLocals.remove(variable);
        return true;
    }

    // Array-typed-field sibling of `writeThroughStructFieldPointer` above
    // (struct-static-array-field follow-up): once
    // `&s.arr[i]` has promoted a `structCells` entry, `*p = value` writes
    // `value`'s bytes into the cell's `NativeStruct.arrayField` view at the
    // pointer's element offset and re-derives the boxed `locals` mirror from
    // the (already-updated) whole struct, mirroring
    // `writeThroughStructFieldPointer`'s cell-then-mirror discipline.
    // Cross-frame follow-up (2026-07-15): `current` (the receiver's own
    // boxed value) can be absent here even on a genuine hit, exactly as in
    // `writeThroughStructFieldPointer` -- a CROSS-FRAME write (`variable` is
    // the CALLER's own local, `id` recorded before the call and shared into
    // this callee's frame only via the duped
    // `structArrayFieldPointerVariables`/`structCells`) finds `variable` in
    // neither this frame's parameters nor its `locals` at all. The write
    // still lands in the shared cell either way; `structArrayFieldPointerWritebacks`
    // flags `variable` so `writeBackStructArrayFieldPointerTargets` can
    // re-derive the OWNING frame's boxed mirror once control returns there.
    // `current`, when present, still declines a rebind (no longer a struct)
    // exactly as before.
    private bool writeThroughStructArrayFieldPointer(in Value pointer, in Value value) {
        auto variable = pointer.pointerAllocation in structArrayFieldPointerVariables;
        if (variable is null)
            return false;

        auto cell = *variable in structCells;
        if (cell is null)
            return false;

        auto fieldIndex = pointer.pointerAllocation in structArrayFieldPointerFieldIndices;
        if (fieldIndex is null)
            return false;

        auto current = *variable in locals;
        if (current !is null && !current.isStruct)
            return false;

        import quickbite.backends.interpreter.native_scalar: writeScalar;

        auto arrayCell = cell.arrayField(*fieldIndex);
        const elementIndex = cast(size_t) pointer.pointerElementOffset;
        writeScalar(arrayCell.elementType, arrayCell.element(elementIndex), value);

        if (current !is null) {
            const updatedField = AggregateValue.withArrayElement(
                AggregateValue.fieldAt(*current, *fieldIndex), elementIndex, value);
            setLocal(*variable, AggregateValue.withStructField(*current, *fieldIndex, updatedField));
        }
        structArrayFieldPointerWritebacks[*variable] = true;
        uninitializedLocals.remove(*variable);
        return true;
    }

    // Nested-struct-field sibling of `writeThroughStructFieldPointer` above
    // (nested-struct-field follow-up): once `&s.inner.x`
    // has promoted a `structCells` entry, `*p = value` writes `value`'s
    // bytes into the cell's nested `NativeStruct.structField(outerIndex)`
    // view at the inner field index, and re-derives the boxed `locals`
    // mirror from the (already-updated) whole struct, mirroring
    // `writeThroughStructFieldPointer`/`writeThroughStructArrayFieldPointer`'s
    // cell-then-mirror discipline.
    //
    // Cross-frame follow-up (2026-07-15): `current` (the receiver's own
    // boxed value) can be absent here even on a genuine hit, exactly as in
    // `writeThroughStructArrayFieldPointer` -- a CROSS-FRAME write
    // (`variable` is the CALLER's own local, `id` recorded before the call
    // and shared into this callee's frame only via the duped
    // `fieldPointerPaths`/`structCells`) finds `variable` in
    // neither this frame's parameters nor its `locals` at all. The write
    // still lands in the shared cell either way; `nestedStructFieldPointerWritebacks`
    // flags `variable` so `writeBackNestedStructFieldPointerTargets` can
    // re-derive the OWNING frame's boxed mirror once control returns there.
    // `current`, when present, still declines a rebind (no longer a struct)
    // exactly as before.
    private bool writeThroughNestedStructFieldPointer(in Value pointer, in Value value) {
        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 2)
            return false;

        auto variable = path.root;
        auto cell = variable in structCells;
        if (cell is null)
            return false;

        const outerFieldIndex = path.indices[0];
        const innerFieldIndex = path.indices[1];

        auto current = variable in locals;
        if (current !is null && !current.isStruct)
            return false;

        import quickbite.backends.interpreter.native_scalar: writeScalar;

        auto nestedCell = cell.structField(outerFieldIndex);
        writeScalar(nestedCell.fieldDeclaration(innerFieldIndex).type,
            nestedCell.field(innerFieldIndex), value);

        if (current !is null) {
            const updatedInner = AggregateValue.withStructField(
                AggregateValue.fieldAt(*current, outerFieldIndex), innerFieldIndex, value);
            setLocal(variable, AggregateValue.withStructField(*current, outerFieldIndex, updatedInner));
        }
        nestedStructFieldPointerWritebacks[variable] = true;
        uninitializedLocals.remove(variable);
        return true;
    }

    // Class sibling of `writeThroughStructFieldPointer` above
    // (write-through-pointer slice): once `&c.field` has
    // promoted a `classCells` entry, `*p = value` writes `value`'s bytes
    // straight into the cell's field byte range (the same offset/size facts
    // `classFieldPointerCellValue` already reads for the deref-read side) and
    // re-derives the boxed `locals` mirror from the (already-updated) whole
    // object, mirroring `writeThroughStructFieldPointer`'s cell-then-mirror
    // discipline. Cross-frame follow-up (2026-07-15): `current` (the
    // receiver's own boxed value) can be absent here even on a genuine hit,
    // exactly as in `writeThroughStructFieldPointer` -- a CROSS-FRAME write
    // (`variable` is the CALLER's own local, `id` recorded before the call
    // and shared into this callee's frame only via the duped
    // `fieldPointerPaths`/`classCells`) finds `variable` in neither
    // this frame's parameters nor its `locals` at all. The write still lands
    // in the shared cell either way; `classFieldPointerWritebacks` flags
    // `variable` so `writeBackClassFieldPointerTargets` can re-derive the
    // OWNING frame's boxed mirror once control returns there. `current`,
    // when present, still declines a rebind (no longer a class object)
    // exactly as before. Returns `false` (writing nothing) for every other
    // field pointer -- no `classCells` entry for the receiver, no reverse-
    // lookup field index, or a receiver whose boxed value is no longer a
    // class object -- leaving `writeLocation`'s `PtrExp` arm to keep
    // refusing those exactly as before.
    private bool writeThroughClassFieldPointer(in Value pointer, in Value value) {
        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 1)
            return false;

        auto variable = path.root;

        auto identity = pointer.pointerAllocation in classFieldPointerObjectIds;
        if (identity is null)
            return false;

        auto cell = *identity in classObjectCells;
        if (cell is null)
            return false;

        const fieldIndex = path.indices[0];

        auto current = variable in locals;

        import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, typeByteSize;
        import quickbite.backends.interpreter.native_scalar: writeScalar;

        auto classType = variable.type.toBasetype.isTypeClass;
        if (classType is null)
            return false;
        auto field = classFields(classType.sym)[fieldIndex];
        const offset = fieldByteOffset(field);
        const size = typeByteSize(field.type);
        writeScalar(field.type, cell.bytes[offset .. offset + size], value);

        if (current !is null)
            if (auto currentCell = variable in classCells)
                if (currentCell.bytes.ptr is cell.bytes.ptr)
                    setLocal(variable, AggregateValue.withClassField(*current, fieldIndex, value));
        classFieldPointerWritebacks[variable] = true;
        uninitializedLocals.remove(variable);
        return true;
    }

    // Class+nested-struct-field sibling of `writeThroughNestedStructFieldPointer`
    // and `writeThroughClassFieldPointer` above (aggregate composition,
    // write-through-pointer follow-up): once
    // `&c.inner.x` has promoted a `classCells` entry via
    // `promoteNestedClassStructFieldCell`, `*p = value` writes `value`'s
    // bytes straight into the cell's nested `NativeStruct` view -- adopted
    // over the outer field's own byte sub-range, the SAME view
    // `nestedClassStructFieldPointerCellValue` already reads for the
    // deref-read side -- and re-derives the boxed `locals` mirror from the
    // (already-updated) whole object, mirroring
    // `writeThroughNestedStructFieldPointer`'s cell-then-mirror discipline.
    // Cross-frame follow-up (2026-07-15): `current` (the
    // receiver's own boxed value) can be absent here even on a genuine hit,
    // exactly as in `writeThroughClassArrayFieldPointer` -- a CROSS-FRAME
    // write (`variable` is the CALLER's own local, `id` recorded before the
    // call and shared into this callee's frame only via the duped
    // `fieldPointerPaths`/`classCells`) finds `variable`
    // in neither this frame's parameters nor its `locals` at all. The write
    // still lands in the shared cell either way; `nestedClassStructFieldPointerWritebacks`
    // flags `variable` so `writeBackNestedClassStructFieldPointerTargets` can
    // re-derive the CALLER's own boxed mirror once control returns there.
    // Returns `false` (writing nothing) for every other pointer -- no
    // `classCells` entry for the receiver, no reverse-lookup field-index
    // pair, the outer field is no longer struct-typed, or a receiver whose
    // boxed value is no longer a class object -- leaving `writeLocation`'s
    // `PtrExp` arm to keep refusing those exactly as before.
    private bool writeThroughNestedClassStructFieldPointer(in Value pointer, in Value value) {
        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 2)
            return false;

        auto variable = path.root;
        auto cell = variable in classCells;
        if (cell is null)
            return false;

        const outerFieldIndex = path.indices[0];
        const innerFieldIndex = path.indices[1];

        auto current = variable in locals;
        if (current !is null && !current.isClassObject)
            return false;

        import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, typeByteSize;
        import quickbite.backends.interpreter.native_scalar: writeScalar;

        auto classType = variable.type.toBasetype.isTypeClass;
        auto outerField = classFields(classType.sym)[outerFieldIndex];
        auto structType = outerField.type.toBasetype.isTypeStruct;
        if (structType is null)
            return false;

        const offset = fieldByteOffset(outerField);
        const size = typeByteSize(outerField.type);
        auto nestedCell = NativeStruct.adopt(cell.subRange(offset, size), structType);
        writeScalar(nestedCell.fieldDeclaration(innerFieldIndex).type,
            nestedCell.field(innerFieldIndex), value);

        if (current !is null) {
            const updatedInner = AggregateValue.withStructField(
                AggregateValue.classFieldAt(*current, outerFieldIndex), innerFieldIndex, value);
            setLocal(variable, AggregateValue.withClassField(*current, outerFieldIndex, updatedInner));
        }
        nestedClassStructFieldPointerWritebacks[variable] = true;
        uninitializedLocals.remove(variable);
        return true;
    }

    // Class-receiver sibling of `writeThroughStructArrayFieldPointer` above
    // (aggregate composition,
    // write-through-pointer follow-up): once `&c.arr[i]` has promoted a
    // `classCells` entry via `promoteClassArrayFieldCell`, `*p = value`
    // writes `value`'s bytes into the cell's `NativeArray` view -- adopted
    // over the field's own byte sub-range, the SAME view
    // `classArrayFieldPointerCellValue` already reads for the deref-read
    // side, since a `classCells` entry is a plain `NativeBlock` rather than
    // a `NativeStruct` (see `classCells`'s own field comment) -- at the
    // pointer's own element offset, and re-derives the boxed `locals`
    // mirror from the (already-updated) whole object, mirroring
    // `writeThroughStructArrayFieldPointer`'s cell-then-mirror discipline.
    // Cross-frame follow-up:
    // `current` (the receiver's own boxed value) can be absent here even on
    // a genuine hit, exactly as in `writeThroughStructArrayFieldPointer` -- a
    // CROSS-FRAME write (`variable` is the CALLER's own local, `id` recorded
    // before the call and shared into this callee's frame only via the duped
    // `classArrayFieldPointerVariables`/`classCells`) finds `variable` in
    // neither this frame's parameters nor its `locals` at all. The write
    // still lands in the shared cell either way; `classArrayFieldPointerWritebacks`
    // flags `variable` so `writeBackClassArrayFieldPointerTargets` can
    // re-derive the OWNING frame's boxed mirror once control returns there.
    // Returns `false` (writing nothing) for every other pointer -- no
    // `classCells` entry for the receiver, no reverse-lookup field index,
    // the field is no longer a static array, or a receiver whose boxed value
    // is no longer a class object -- leaving `writeLocation`'s `PtrExp` arm
    // to keep refusing those exactly as before.
    private bool writeThroughClassArrayFieldPointer(in Value pointer, in Value value) {
        auto variable = pointer.pointerAllocation in classArrayFieldPointerVariables;
        if (variable is null)
            return false;

        auto cell = *variable in classCells;
        if (cell is null)
            return false;

        auto fieldIndex = pointer.pointerAllocation in classArrayFieldPointerFieldIndices;
        if (fieldIndex is null)
            return false;

        auto current = *variable in locals;
        if (current !is null && !current.isClassObject)
            return false;

        import quickbite.backends.interpreter.layout:
            classFields, fieldByteOffset, staticArrayLength, typeByteSize;
        import quickbite.backends.interpreter.native_scalar: writeScalar;

        auto classType = (*variable).type.toBasetype.isTypeClass;
        auto field = classFields(classType.sym)[*fieldIndex];
        auto arrayType = field.type.toBasetype.isTypeSArray;
        if (arrayType is null)
            return false;

        auto elementType = arrayType.next.toBasetype;
        const offset = fieldByteOffset(field);
        const size = typeByteSize(field.type);
        auto arrayCell = NativeArray.adopt(cell.subRange(offset, size), elementType, staticArrayLength(arrayType));
        const elementIndex = cast(size_t) pointer.pointerElementOffset;
        writeScalar(elementType, arrayCell.element(elementIndex), value);

        if (current !is null) {
            const updatedField = AggregateValue.withArrayElement(
                AggregateValue.classFieldAt(*current, *fieldIndex), elementIndex, value);
            setLocal(*variable, AggregateValue.withClassField(*current, *fieldIndex, updatedField));
        }
        classArrayFieldPointerWritebacks[*variable] = true;
        uninitializedLocals.remove(*variable);
        return true;
    }

    // Write-side counterpart of `classCellFieldValue` above: mirrors a
    // direct field write (`c.field = v`,
    // as opposed to a pointer deref write, which
    // `writeThroughClassFieldPointer` above already handles) into
    // `receiverExpression`'s resolved `classCells` key
    // (`classCellKeyVariable` above -- a bare `VarExp`'s own variable, or a
    // bare `ThisExp`'s `currentFunction.vthis`), when one has a `classCells`
    // entry, so a later read through this SAME cell -- whether via this
    // variable, an aliased variable sharing the cell
    // (`registerClassAliasIfPlainVar`/`registerClassArgumentAliases`/
    // `registerClassThisAlias`), or a pointer promoted from any of them --
    // sees the write. A no-op (nothing written) for a receiver
    // `classCellKeyVariable` cannot resolve, a resolved variable with no
    // `classCells` entry, or a non-scalar field -- every one of those leaves
    // the write to reach only the boxed `locals`/`thisValue` mirror the
    // caller updates separately, exactly as before this slice.
    private void writeClassCellFieldIfPresent(
        imported!"dmd.expression".Expression receiverExpression,
        in size_t fieldIndex,
        in Value value,
    ) {
        import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, typeByteSize;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, writeScalar;

        const receiver = runExpression(receiverExpression);
        if (!receiver.isClassObject)
            return;

        auto cell = receiver.classIdentity in classObjectCells;
        if (cell is null)
            return;

        auto classType = receiverExpression.type.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            return;

        auto fields = classFields(classType.sym);
        if (fieldIndex >= fields.length)
            return;

        auto field = fields[fieldIndex];
        if (!isNativeScalarType(field.type))
            return;

        const offset = fieldByteOffset(field);
        const size = typeByteSize(field.type);
        writeScalar(field.type, cell.bytes[offset .. offset + size], value);
    }

    private bool canWriteThroughArrayPointer(in Value pointer) {
        return arrayPointerVariable(pointer) !is null;
    }

    private imported!"dmd.declaration".VarDeclaration* arrayPointerVariable(
        in Value pointer,
    ) {
        if (!isBoxedPointer(pointer) || pointer.pointerAllocation == 0)
            return null;

        return pointer.pointerAllocation in arrayAllocationVariables;
    }

    private void writeIndexLocation(
        imported!"dmd.expression".IndexExp index,
        in Value value,
    ) {
        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;

        if (auto dot = index.e1.isDotVarExp) {
            // Class sibling of the struct branch below (aggregate
            // composition -- static-array
            // field): `c.arr[i] = v` for a class-typed field previously fell
            // through to `structFieldIndex`, which requires
            // `receiverStructType` and throws "Unsupported interpreter field
            // access." for a class receiver -- this shape was entirely
            // unsupported, not merely missing pointer-aliasing. Checked via
            // the STATIC receiver type (`receiverClassType`), matching
            // `writeLocation`'s own `DotVarExp` arm's `isClassObject`
            // dispatch, and rewrites the WHOLE class object through
            // `writeLocation(dot.e1, ...)` -- the same whole-value path a
            // direct scalar field write takes -- so `writeCelledLocal`'s
            // existing class refresh (`writeClassCellScalarFields`) keeps a
            // promoted `classCells` entry current.
            if (receiverClassType(dot.e1) !is null) {
                const receiver = runExpression(dot.e1);
                const fieldIndex = classFieldIndex(dot, receiver);
                // Same stale-receiver hazard `writeLocation`'s `DotVarExp`
                // arm closes -- re-derive from the shared cell before folding
                // in this element's write.
                const authoritative = classCellOverlaidValue(dot.e1, receiver);
                const updatedArray = AggregateValue.withArrayElement(
                    AggregateValue.classFieldAt(authoritative, fieldIndex), arrayIndex, value);
                writeLocation(
                    dot.e1,
                    AggregateValue.withClassField(authoritative, fieldIndex, updatedArray),
                    /* arrayRefWriteback */ false,
                    /* classFieldRefresh */ true,
                );
                return;
            }

            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const updatedArray = AggregateValue.withArrayElement(
                AggregateValue.fieldAt(receiver, fieldIndex), arrayIndex, value);
            writeLocation(dot.e1, AggregateValue.withStructField(receiver, fieldIndex, updatedArray));
            if (dot.e1.isThisExp !is null)
                writeThroughThisStructArrayFieldAlias(fieldIndex, arrayIndex, value);
            return;
        }

        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        setLocal(variable, AggregateValue.withArrayElement(*current, arrayIndex, value));
        writeThroughSliceAlias(variable, arrayIndex, value);
        writeThroughArrayCell(variable, arrayIndex, value);
        uninitializedLocals.remove(variable);
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

    // A D `union`'s members share one block of bytes in real D, but the
    // boxed `Value.Struct` representation (`withStructField`/
    // `structFieldAt`) stores each member independently in its own
    // `Field[]` slot -- `promoteStructCell`'s union guard deliberately
    // keeps a union local on this boxed path (see its comment), so a plain
    // `u.i = x;` write left every sibling member's own slot untouched,
    // diverging from `SystemLinker`'s overlapping-bytes behaviour (writing
    // `u.i` must be visible, reinterpreted, through `u.f`). This overlays
    // every OTHER sibling field by reinterpreting the just-written value's
    // own bytes as that field's type, using a transient `NativeStruct`
    // (never stored in `structCells` -- allocated and discarded within this
    // call), so `promoteStructCell`'s own guard (and its pointer/cross-frame
    // aliasing machinery) is untouched by this. A native-scalar written/
    // sibling field routes through `native_scalar.writeScalar`/`readScalar`
    // directly on the cell's own field bytes. Widened (2026-07-15,
    // non-scalar union member follow-up) to also handle a
    // written/sibling field that is itself a (non-union) struct, via the
    // SAME composition machinery `promoteStructCell`'s scalar-only cells
    // already use: `writeStructCellScalarFields` to seed the struct-typed
    // field's own scalar sub-fields into the transient cell's shared bytes,
    // and `structValueFromCell` to re-derive a struct-typed sibling's boxed
    // value back out of those same bytes. Widened again (2026-07-16,
    // static-array union member follow-up) so a SIBLING field
    // that is a static array whose OWN element type is `native_scalar.
    // isNativeScalarType` is also refreshed, via the SAME `NativeStruct.
    // arrayField` view `writeStructCellScalarFields`/`structValueFromCell`
    // already use for a struct's own static-array field: `readScalar`s each
    // element back out of the transient cell's shared bytes into the
    // sibling's boxed array value. Widened again (2026-07-16,
    // WRITTEN-side static-array follow-up) so assigning a WHOLE
    // scalar-element static-array union member (e.g. `u.a = [...]`) also
    // seeds the transient cell's shared bytes -- via the SAME `NativeStruct.
    // arrayField` view, `writeScalar`ing each of the just-written array
    // value's own elements -- before the sibling refresh loop above overlays
    // every other member, closing the gap this file's own prior entry
    // flagged as unwidened. A union member that is a dynamic array, class,
    // static array of NON-scalar elements, or nested union is still left on
    // its own prior boxed value on both sides (written and sibling) --
    // matching `writeStructCellScalarFields`'s identical scope;
    // `promoteStructCell`'s guard is unchanged and still declines cell
    // PROMOTION (the address-taken/pointer path) for a union with any such
    // member.
    private Value withUnionFieldWrite(
        in Value receiver,
        imported!"dmd.mtype".TypeStruct unionType,
        in size_t fieldIndex,
        in Value value,
    ) {
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar, writeScalar;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        auto updated = AggregateValue.withStructField(receiver, fieldIndex, value);

        auto fields = structFields(unionType);
        if (fieldIndex >= fields.length)
            return updated;

        auto writtenType = fields[fieldIndex].type;
        const writtenScalar = isNativeScalarType(writtenType);
        auto writtenStructType = writtenType.toBasetype.isTypeStruct;
        const writtenStruct = writtenStructType !is null
            && writtenStructType.sym.isUnionDeclaration is null;
        const writtenArray = isStaticArrayType(writtenType)
            && isNativeScalarType(writtenType.toBasetype.nextOf.toBasetype)
            && value.isArray;

        if (!writtenScalar && !writtenStruct && !writtenArray)
            return updated;

        auto cell = NativeStruct.allocate(unionType);

        // `NativeStruct.allocate` zero-initialises, and the transient cell
        // used to be seeded ONLY with the just-written member's own bytes
        // before the sibling loop below re-derived every OTHER member's
        // FULL extent from it -- any sibling WIDER than the written member
        // read zeros in the bytes outside the written member's extent
        // instead of the union's PRIOR bytes there (e.g. `int[2] a; int i;`:
        // writing `u.i` after `u.a = [...]` zeroed `a[1]`, which lies
        // entirely outside `i`'s 4-byte extent). Seeding the cell from
        // `receiver` -- the union's CURRENT boxed state, via the SAME
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
            writeScalar(writtenType, cell.field(fieldIndex), value);
        } else if (writtenStruct) {
            auto writtenCell = cell.structField(fieldIndex);
            writeStructCellScalarFields(writtenCell, value);
        } else {
            auto writtenElementType = writtenType.toBasetype.nextOf.toBasetype;
            auto writtenArrayCell = cell.arrayField(fieldIndex);
            foreach (elementIndex; 0 .. value.length)
                writeScalar(writtenElementType, writtenArrayCell.element(elementIndex),
                    value[elementIndex]);
        }

        foreach (siblingIndex, sibling; fields) {
            if (siblingIndex == fieldIndex)
                continue;

            if (isNativeScalarType(sibling.type)) {
                updated = AggregateValue.withStructField(updated, siblingIndex,
                    readScalar(sibling.type, cell.field(siblingIndex)));
                continue;
            }

            if (isStaticArrayType(sibling.type)) {
                auto siblingElementType = sibling.type.toBasetype.nextOf.toBasetype;
                if (!isNativeScalarType(siblingElementType))
                    continue;

                auto siblingCurrent = AggregateValue.fieldAt(updated, siblingIndex);
                if (!siblingCurrent.isArray)
                    continue;

                auto siblingArrayCell = cell.arrayField(siblingIndex);
                foreach (elementIndex; 0 .. siblingCurrent.length)
                    siblingCurrent = AggregateValue.withArrayElement(siblingCurrent, elementIndex,
                        readScalar(siblingElementType, siblingArrayCell.element(elementIndex)));
                updated = AggregateValue.withStructField(updated, siblingIndex, siblingCurrent);
                continue;
            }

            auto siblingStructType = sibling.type.toBasetype.isTypeStruct;
            if (siblingStructType is null || siblingStructType.sym.isUnionDeclaration !is null)
                continue;

            auto siblingCurrent = AggregateValue.fieldAt(updated, siblingIndex);
            if (!siblingCurrent.isStruct)
                continue;

            auto siblingCell = cell.structField(siblingIndex);
            updated = AggregateValue.withStructField(updated, siblingIndex,
                structValueFromCell(siblingCurrent, siblingCell));
        }

        return updated;
    }

    private size_t classFieldIndex(imported!"dmd.expression".DotVarExp dot) {
        return classFieldIndex(dot, Value.void_);
    }

    private size_t classFieldIndex(
        imported!"dmd.expression".DotVarExp dot,
        in Value receiver,
    ) {
        import quickbite.backends.interpreter.layout: classFields;

        auto field = dot.var.isVarDeclaration;
        if (field is null)
            throw new Exception("Unsupported interpreter field access.");

        auto class_ = receiver.isClassObject
            ? dynamicClass(receiver)
            : null;
        if (class_ is null) {
            auto classType = receiverClassType(dot.e1);
            class_ = classType is null ? null : classType.sym;
        }
        if (class_ is null)
            throw new Exception("Unsupported interpreter field access.");

        foreach (index, candidate; classFields(class_))
            if (candidate is field)
                return index;

        throw new Exception("Unsupported interpreter field access.");
    }

    private Value runIndexAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        if (isPointerType(index.e1.type)) {
            const pointer = runExpression(index.e1);
            const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
            if (pointer.isNativePointer) {
                const value = runExpression(rhs);
                storeNativePointerElement(index.e1.type, pointer, arrayIndex, value);
                return value;
            }
            if (canWriteThroughArrayPointer(pointer)) {
                const value = runExpression(rhs);
                if (writeThroughArrayPointer(
                    pointer.pointerOffsetBy(cast(long) arrayIndex),
                    value,
                ))
                    return value;

                const updatedPointer = pointer
                    .pointerOffsetBy(cast(long) arrayIndex)
                    .withPointerTarget(value)
                    .pointerOffsetBy(-cast(long) arrayIndex);
                writeLocation(index.e1, updatedPointer);
                return value;
            }
            return runAssocArraySlotAssignExpression(index.e1, rhs);
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
            // unsupported. Checked via the STATIC receiver type
            // (`receiverClassType`), mirroring `writeLocation`'s own
            // `DotVarExp` arm's `isClassObject` dispatch.
            if (receiverClassType(dot.e1) !is null) {
                const receiver = runExpression(dot.e1);
                const fieldIndex = classFieldIndex(dot, receiver);
                // Same stale-receiver hazard `writeLocation`'s `DotVarExp`
                // arm closes -- re-derive from the shared cell before folding
                // in this element's write.
                const authoritative = classCellOverlaidValue(dot.e1, receiver);
                const source = AggregateValue.classFieldAt(authoritative, fieldIndex);
                if (index.lengthVar !is null)
                    setLocal(index.lengthVar, Value(source.length));
                const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
                const value = runExpression(rhs);
                const updatedArray = AggregateValue.withArrayElement(source, arrayIndex, value);
                writeLocation(
                    dot.e1,
                    AggregateValue.withClassField(authoritative, fieldIndex, updatedArray),
                    /* arrayRefWriteback */ false,
                    /* classFieldRefresh */ true,
                );
                return value;
            }

            // `$` inside index.e2 is a DollarExp bound to index.lengthVar, so
            // it must see the field array's current length: resolve the
            // field and seed lengthVar from it before evaluating index.e2,
            // the same order runIndexExpression (read path) already uses for
            // the same `$` binding. Evaluating e2 first left lengthVar
            // holding a stale (or default zero) length, so `h.arr[$ - 1] =
            // v` right after growing `h.arr` underflowed to size_t.max.
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const source = AggregateValue.fieldAt(receiver, fieldIndex);
            if (index.lengthVar !is null)
                setLocal(index.lengthVar, Value(source.length));
            const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
            const value = runExpression(rhs);
            const updatedArray = AggregateValue.withArrayElement(source, arrayIndex, value);
            writeLocation(dot.e1, AggregateValue.withStructField(receiver, fieldIndex, updatedArray));
            return value;
        }

        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        variable = refLocalStorageVariable(variable);

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
        const value = runExpression(rhs);
        setLocal(variable, AggregateValue.withArrayElement(*current, arrayIndex, value));
        writeThroughSliceAlias(variable, arrayIndex, value);
        writeThroughArrayCell(variable, arrayIndex, value);
        uninitializedLocals.remove(variable);
        return value;
    }

    // Refreshes `variable`'s promoted `arrayCells` entry, if one exists,
    // alongside the `locals` mirror
    // a direct element write (`a[i] = x`) already updated -- an earlier
    // `&a[i]` pointer's deref-read (`runPointerExpression`) consults the
    // cell, not `locals`, so a direct element write must keep the cell
    // current or a later deref-read through that pointer would see stale
    // bytes. A no-op when no cell was ever promoted for `variable`.
    private void writeThroughArrayCell(
        VarDeclaration variable,
        in size_t index,
        in Value value,
    ) {
        if (auto cell = variable in arrayCells)
            writeArrayCellElement(*cell, index, value);
    }

    // Writes boxed `value` into `cell`'s element `index` (the array-of-struct
    // counterpart of a bare `native_scalar.writeScalar` element write):
    // `cell.elementType` a native scalar routes through `writeScalar`
    // exactly as before this array-of-struct widening; `cell.elementType` a
    // (necessarily non-union, per `promoteArrayCell`'s own guard) struct
    // routes through `NativeArray.structElement`/`writeStructCellScalarFields`
    // -- the same scalar-fields-only overlay `promoteStructCell`'s own cell
    // uses, applied to one array element's sub-range instead of a whole
    // struct local. `cell.elementType` a (necessarily scalar-element, per
    // `promoteArrayCell`'s own guard) static array routes through `NativeArray.
    // arrayElement`/`writeStaticArrayCellScalarElements`, the array-typed
    // sibling of the struct branch. Shared by every `arrayCells`
    // element-write call site so none of them needs its own element-type
    // branch.
    private void writeArrayCellElement(
        ref NativeArray cell,
        in size_t index,
        in Value value,
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

        import quickbite.backends.interpreter.native_scalar: writeScalar;

        writeScalar(cell.elementType, cell.element(index), value);
    }

    // Writes boxed `arrayValue`'s scalar leaves into `cell`'s bytes (the
    // static-array-element counterpart of `writeStructCellScalarFields`):
    // shared by
    // `promoteArrayCell`'s static-array-element branch (the cell-creation
    // seed) and `writeArrayCellElement`'s own branch above (a direct
    // element write, `a[i] = [...]`, after the cell already exists).
    // Nested static-array elements recurse through `NativeArray.arrayElement`;
    // scalar elements terminate in the shared scalar codec. A no-op for a
    // boxed value that isn't actually an array (defensive, mirroring
    // `writeStructCellScalarFields`'s static-array-field branch).
    private void writeStaticArrayCellScalarElements(
        ref NativeArray cell,
        in Value arrayValue,
    ) {
        import quickbite.backends.interpreter.native_scalar: writeScalar;

        if (!arrayValue.isArray)
            return;

        foreach (index; 0 .. cell.length) {
            if (index >= arrayValue.length)
                continue;

            if (cell.elementType.isTypeSArray) {
                // Mutable because recursive write takes the view by ref.
                auto elementCell = cell.arrayElement(index);
                writeStaticArrayCellScalarElements(
                    elementCell,
                    arrayValue[index],
                );
            } else {
                writeScalar(
                    cell.elementType,
                    cell.element(index),
                    arrayValue[index],
                );
            }
        }
    }

    // Reads `cell`'s element `index` back into a boxed `Value` (the
    // array-of-struct counterpart of a bare `native_scalar.readScalar`
    // element read): `cell.elementType` a native scalar routes through
    // `readScalar` exactly as before this widening; a struct element routes
    // through `structValueFromCell` -- the same read-back `writeBack
    // StructFieldPointerTargets` already uses for a top-level struct-field
    // cell, applied here to one array element's sub-range. `cell.
    // elementType` a static array routes through `arrayValueFromCell`, the
    // array-typed
    // sibling of `structValueFromCell`. The base `Value` overlaid for the
    // struct branch is `variable`'s own current boxed element when one
    // exists (so a non-scalar sub-field, out of this narrow slice's scope,
    // keeps whatever the boxed mirror already had) or the element type's
    // default otherwise; the static-array branch needs no such overlay,
    // since every one of its own elements is authoritative in the cell by
    // construction. Shared by every `arrayCells` element-read call site.
    private Value readArrayCellElement(
        VarDeclaration variable,
        ref NativeArray cell,
        in size_t index,
    ) {
        import quickbite.backends.interpreter.native_scalar: readScalar;

        if (cell.elementType.isTypeStruct) {
            auto current = defaultValue(cell.elementType);
            if (auto existing = variable in locals)
                if (index < existing.length)
                    current = (*existing)[index];

            auto elementCell = cell.structElement(index);
            return structValueFromCell(current, elementCell);
        }

        if (cell.elementType.isTypeSArray) {
            auto elementCell = cell.arrayElement(index);
            return arrayValueFromCell(elementCell);
        }

        return readScalar(cell.elementType, cell.element(index));
    }

    // Re-derives a static-array `Value` from `cell`'s scalar-leaf bytes
    // (the static-array-element counterpart of `structValueFromCell`, used
    // by `readArrayCellElement`'s branch above): every element is read back
    // from the cell -- authoritative once a write-through-pointer or a
    // direct element write touched it. Unlike `structValueFromCell`'s
    // per-field overlay onto a `current` base value, there is no non-scalar
    // sub-element here to preserve -- `promoteArrayCell` only ever creates
    // this cell shape when every leaf is `native_scalar.isNativeScalarType`.
    // Nested static-array elements recurse through `NativeArray.arrayElement`;
    // scalar elements terminate in the shared scalar codec.
    private Value arrayValueFromCell(ref NativeArray cell) {
        import quickbite.backends.interpreter.native_scalar: readScalar;

        Value[] elements;
        elements.length = cell.length;
        foreach (index; 0 .. cell.length) {
            if (cell.elementType.isTypeSArray) {
                auto elementCell = cell.arrayElement(index);
                elements[index] = arrayValueFromCell(elementCell);
            } else {
                elements[index] = readScalar(
                    cell.elementType,
                    cell.element(index),
                );
            }
        }

        return Value.arrayValue(elements);
    }

    // Whole-value read-back for a promoted dynamic array. Struct elements
    // overlay their authoritative scalar fields onto the current boxed
    // element so unsupported fields retain their value. Scalars use the
    // complete cell-only reconstruction above; scalar-element static arrays
    // use the same complete reconstruction for each inline element.
    private Value arrayValueFromCell(
        in Value current,
        ref NativeArray cell,
    ) {
        // Allocation-carrying cast views retain their allocation-base
        // coordinate, but their elements must be decoded afresh from the
        // authoritative carrier bytes. Returning `current` here would retain
        // the right identity while exposing its stale boxed snapshot.
        if (current.arrayAllocationId != 0) {
            const id = current.arrayAllocationId;
            auto carrier = id in arrayAllocationCarriers;
            if (carrier is null)
                throw new Exception("Array allocation carrier is missing.");

            auto typedCarrier = carrier.reinterpretElements(
                cell.elementType,
            );
            const offset = current.arrayAllocationOffset;
            if (
                offset > typedCarrier.length ||
                current.length > typedCarrier.length - offset
            )
                throw new Exception(
                    "Array cell view exceeds its allocation carrier.",
                );

            auto view = typedCarrier.slice(
                offset,
                offset + current.length,
            );
            return arrayValueFromCarrier(view, typedCarrier, id, offset);
        }

        if (cell.elementType.isTypeSArray) {
            Value[] elements;
            elements.length = cell.length;
            foreach (index; 0 .. cell.length) {
                auto elementCell = cell.arrayElement(index);
                elements[index] = arrayValueFromCell(elementCell);
            }
            return arrayCellValue(elements, cell.block.address);
        }

        if (cell.elementType.isTypeStruct is null)
        {
            const elements = arrayElements(arrayValueFromCell(cell));
            return arrayCellValue(elements, cell.block.address);
        }

        Value[] elements;
        elements.length = cell.length;
        foreach (index; 0 .. cell.length) {
            const element = index < current.length
                ? current[index]
                : defaultValue(cell.elementType);
            // Mutable because structValueFromCell takes the view by ref.
            auto elementCell = cell.structElement(index);
            elements[index] = structValueFromCell(element, elementCell);
        }

        return arrayCellValue(elements, cell.block.address);
    }

    private Value arrayCellValue(
        in Value[] elements,
        const(void)* address,
    ) {
        return Value.nativeArrayValue(elements, address);
    }

    private Value arrayValueFromCarrier(
        ref NativeArray view,
        ref NativeArray carrier,
        in size_t allocationId,
        in size_t allocationOffset,
    ) {
        import quickbite.backends.interpreter.native_scalar: readScalar;

        if (
            allocationOffset > carrier.length ||
            view.length > carrier.length - allocationOffset
        )
            throw new Exception("Array carrier view exceeds its allocation.");

        Value[] elements;
        elements.length = view.length;
        foreach (index; 0 .. view.length)
            elements[index] = readScalar(view.elementType, view.element(index));

        Value[] allocation;
        allocation.length = carrier.length;
        foreach (index; 0 .. carrier.length)
            allocation[index] = readScalar(
                carrier.elementType,
                carrier.element(index),
            );

        return Value.arraySliceValue(
            elements,
            allocation,
            allocationOffset,
            allocationId,
        );
    }

    private Value runAssocArraySlotAssignExpression(
        imported!"dmd.expression".Expression pointer,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = pointer.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto alias_ = variable in assocArraySlotAliases;
        if (alias_ is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto source = alias_.source in locals;
        const current = source is null
            ? defaultLocalValue(alias_.source)
            : *source;

        auto function_ = functionPointerExpressionFunction(rhs);
        const value = function_ is null
            ? runExpression(rhs)
            : functionPointerValue(function_);
        setLocal(alias_.source, current.withAssocArrayEntry(alias_.key, value));
        uninitializedLocals.remove(alias_.source);
        return value;
    }

    private bool isAssocArraySlotPointer(
        imported!"dmd.expression".Expression pointer,
    ) {
        auto var = pointer.isVarExp;
        if (var is null)
            return false;

        auto variable = var.var.isVarDeclaration;
        return variable !is null &&
            (variable in assocArraySlotAliases) !is null;
    }

    private Value runNestedIndexAssignExpression(
        imported!"dmd.expression".IndexExp outer,
        imported!"dmd.expression".IndexExp inner,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = outer.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const outerIndex = cast(size_t) runExpression(outer.e2).asLong;
        const innerIndex = cast(size_t) runExpression(inner.e2).asLong;
        const value = runExpression(rhs);
        setLocal(variable, AggregateValue.withArrayElement(*current,
            outerIndex,
            AggregateValue.withArrayElement(
                AggregateValue.elementAt(*current, outerIndex), innerIndex, value),
        ));
        const updatedOuter = locals[variable][outerIndex];
        writeThroughArrayCell(variable, outerIndex, updatedOuter);
        uninitializedLocals.remove(variable);
        return value;
    }

    private Value runSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;
        import std.conv: text;

        if (isPointerType(slice.e1.type))
            return runPointerSliceAssignExpression(slice, rhs);

        auto var = slice.e1.isVarExp;
        if (var is null) {
            if (auto dot = slice.e1.isDotVarExp)
                return runFieldSliceAssignExpression(slice, dot, rhs);
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

        auto current = variable in locals;
        if (current is null)
            throw new Exception(
                "Unsupported interpreter assignment target: slice of unset local.",
            );

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? current.length
            : cast(size_t) runExpression(slice.upr).asLong;

        // An out-of-bounds `upper` must be rejected here, before `rhs` is
        // even evaluated (matching compiled D, which raises this before any
        // side effect in `rhs` runs) and before the cell-write loop below
        // indexes `elements[lower .. upper]` -- `elements` only ever holds
        // `current.length` entries, so an unchecked `upper > current.length`
        // would index it out of range with a HOST `RangeError` even when
        // `variable` has no promoted cell at all. Message text matches
        // druntime's own `ArraySliceError` verbatim (confirmed against a
        // compiled `int[] a = [1, 2]; a[0 .. 5] = 9;`), so `SystemLinker`
        // agrees exactly.
        if (upper > current.length)
            throwRangeError(text(
                "slice [", lower, " .. ", upper,
                "] extends past source array of length ", current.length,
            ));

        rejectOverlappingSliceAssignment(variable, rhs, lower, upper, current.length);

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);

        // A fill assignment (`a[] = scalar;`) evaluates `rhs` to a single
        // element-typed value, not an array to index into -- only the copy
        // form (`a[] = otherArray[];`, whose `rhs.type` matches the SLICE's
        // own array type) yields something `value[index - lower]` can index.
        // `block` (a fill whose ELEMENT type is itself an array, e.g.
        // `matrix[] = row;`) already takes the `copyArrayValue` branch;
        // `value.isArray` distinguishes the remaining two: a genuine array
        // copy vs. a scalar-element fill, which must reuse `value` itself at
        // every position instead of indexing into it.
        Value[] elements;
        foreach (index; 0 .. current.length)
            elements ~= index < lower || index >= upper
                ? (*current)[index]
                : block ? copyArrayValue(value)
                : value.isArray ? value[index - lower] : value;

        setLocal(variable, Value.arrayValue(elements));
        uninitializedLocals.remove(variable);

        // A promoted `arrayCells` entry
        // (e.g. from an earlier `&a[i]` or a slice sharing `variable`'s
        // storage) is read-authoritative over this `locals` mirror --
        // `readIndexExpression`'s cell arm -- so every element this
        // assignment actually covers must also land in the cell, not just
        // the boxed array. A no-op via `writeThroughArrayCell` when no cell
        // was ever promoted.
        foreach (index; lower .. upper)
            writeThroughArrayCell(variable, index, elements[index]);

        return value;
    }

    // A slice assignment through a pointer (`p[i .. j] = source`) writes
    // element by element through the pointer — native memory via the FFI
    // store, D array storage via the tracked pointer — and never converts
    // the lvalue to a detached Array, which would silently sever aliasing.
    private Value runPointerSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".Expression rhs,
    ) {
        import std.conv: text;

        const pointer = runExpression(slice.e1);
        if (slice.lwr is null || slice.upr is null)
            throw new Exception(text(
                "Unsupported interpreter assignment target: slice of ",
                slice.e1.op,
            ));

        const lower = cast(size_t) runExpression(slice.lwr).asLong;
        const upper = cast(size_t) runExpression(slice.upr).asLong;

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);

        // An empty range writes nothing, so the pointer's provenance never
        // matters — a zero-length assignment through a null pointer is a no-op
        // in compiled D, not an unsupported target.
        if (upper == lower)
            return value;

        Value elementAt(in size_t index) {
            return block ? copyArrayValue(value) : value[index];
        }

        if (pointer.isNativePointer) {
            foreach (index; 0 .. upper - lower)
                storeNativePointerElement(
                    slice.e1.type,
                    pointer,
                    lower + index,
                    elementAt(index),
                );
            return value;
        }

        if (canWriteThroughArrayPointer(pointer)) {
            Value updatedPointer = pointer;
            bool usedPointerFallback;
            foreach (index; 0 .. upper - lower) {
                const offset = cast(long) (lower + index);
                const element = elementAt(index);
                if (writeThroughArrayPointer(
                    pointer.pointerOffsetBy(offset),
                    element,
                ))
                    continue;

                updatedPointer = updatedPointer
                    .pointerOffsetBy(offset)
                    .withPointerTarget(element)
                    .pointerOffsetBy(-offset);
                usedPointerFallback = true;
            }

            if (usedPointerFallback)
                writeLocation(slice.e1, updatedPointer);

            return value;
        }

        throw new Exception(text(
            "Unsupported interpreter assignment target: slice of ",
            slice.e1.op,
        ));
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
            : cast(size_t) runExpression(source.lwr).asLong;
        const sourceUpper = source.upr is null
            ? length
            : cast(size_t) runExpression(source.upr).asLong;

        if (lower < sourceUpper && sourceLower < upper)
            throw new Exception("Range violation");
    }

    // A slice assignment through a struct field (`s.buf[i .. j] = source[]`):
    // splice the written elements into the field's current array and write
    // the updated struct back through the field's location.
    private Value runFieldSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".DotVarExp dot,
        imported!"dmd.expression".Expression rhs,
    ) {
        const fieldIndex = structFieldIndex(dot);
        const receiver = runExpression(dot.e1);
        const current = AggregateValue.fieldAt(receiver, fieldIndex);

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? current.length
            : cast(size_t) runExpression(slice.upr).asLong;

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);

        Value[] elements;
        foreach (index; 0 .. current.length)
            elements ~= index < lower || index >= upper
                ? current[index]
                : block ? copyArrayValue(value) : value[index - lower];

        writeLocation(dot.e1, AggregateValue.withStructField(receiver,
            fieldIndex,
            Value.arrayValue(elements),
        ));
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

    private Value copyArrayValue(in Value value) {
        Value[] elements;
        foreach (index; 0 .. value.length)
            elements ~= value[index];

        return Value.arrayValue(elements);
    }

    private Value runLoweredAssignExpression(
        imported!"dmd.expression".LoweredAssignExp assign,
    ) {
        import quickbite.frontend.dmd.types: arrayElementType, isDynamicArrayType;
        import std.conv: text;

        auto arrayLength = assign.e1.isArrayLengthExp;
        if (arrayLength is null)
            throw new Exception(text("Unsupported eval expression: ", assign.op));

        const lengthValue = runExpression(assign.e2);

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

        auto current = variable in locals;
        if (current is null) {
            writeArrayLengthLocation(arrayLength, lengthValue);
            return lengthValue;
        }

        const newLength = cast(size_t) lengthValue.asLong;

        Value[] elements;
        foreach (index; 0 .. newLength)
            elements ~= index < current.length
                ? (*current)[index]
                : runDefaultValue(arrayElementType(variable.type));

        // Go through `writeLocation`, not a direct `locals[variable] = ...`:
        // dmd's postfix `.length++`/`.length--` lowering binds a synthetic
        // `ref` local (e.g. `ref int[] __arraylength3 = h.arr;`) to the real
        // array-length target and resizes through that alias, so `variable`
        // here can itself be a struct-field/array-element alias source
        // recorded by `recordStructFieldAlias`/`recordArrayElementAlias`.
        // Writing `locals[variable]` directly (the previous code) updated
        // only the synthetic alias local and silently dropped the grown
        // array on the caller's aliased struct field; `writeLocation`'s
        // `VarExp` branch runs the same write-through-alias propagation as
        // every other assignment target.
        writeLocation(var, Value.arrayValue(elements));
        return lengthValue;
    }

    private Value runConcatenateExpression(imported!"dmd.expression".CatExp cat) {
        return AggregateValue.reconstructArray(
            concatenationElements(cat.e1) ~ concatenationElements(cat.e2),
        );
    }

    private Value[] concatenationElements(
        imported!"dmd.expression".Expression operand,
    ) {
        import quickbite.frontend.dmd.types: isArrayType;

        const value = runExpression(operand);
        if (!isArrayType(operand.type))
            return [value];

        Value[] elements;
        foreach (index; 0 .. AggregateValue.elementCount(value))
            elements ~= AggregateValue.elementAt(value, index);

        return elements;
    }

    private Value runArrayAppendAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (auto dot = assign.e1.isDotVarExp) {
            const appended = runExpression(assign.e1).withAppendedArrayElement(
                runExpression(assign.e2),
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

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter array append target.");

        const value = runExpression(assign.e2);
        if (current.arrayNativeAddress !is null)
            promoteArrayCell(variable);
        if (auto cell = variable in arrayCells) {
            const newLength = cell.length + 1;
            bool rebound;
            if (!cell.tryExpandUsedTo(newLength)) {
                if (
                    cell.ownership == NativeBlock.Ownership.borrowed &&
                    variable in sliceAliases
                ) {
                    auto replacement = NativeArray.allocate(
                        cell.elementType,
                        newLength,
                    );
                    replacement.block.bytes[0 .. cell.block.byteLength] =
                        cell.block.bytes;
                    dropArrayCell(variable);
                    arrayCells[variable] = replacement;
                    cell = variable in arrayCells;
                    rebound = true;
                } else {
                    cell.reserve(newLength);
                    cell.setLength(newLength);
                }
            }
            writeArrayCellElement(*cell, newLength - 1, value);
            const boxedCurrent = rebound
                ? Value.arrayValue(arrayElements(*current))
                : *current;
            setLocal(variable, arrayValueFromCell(boxedCurrent, *cell));
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            return locals[variable];
        }

        setLocal(variable, current.withAppendedArrayElement(value));
        uninitializedLocals.remove(variable);
        sliceAliases.remove(variable);

        // `~=` may reallocate (D's own
        // "append may reallocate, old pointers go stale" semantics), and even
        // when it does not, a promoted `arrayCells` entry is a fixed-length
        // `NativeArray` sized at promotion time -- it cannot represent the
        // grown length either way. Drop it rather than let a stale,
        // too-short cell answer a later read/write at the new index
        // (`readIndexExpression`'s cell arm, `writeThroughArrayCell`); the
        // next read falls through to this fresh `locals` mirror instead.
        //
        // Dropping the CELL alone left the
        // memoized `arrayAllocations`/`arrayAllocationVariables` id in
        // place, since `variable` itself was never re-declared here -- a
        // pointer re-taken AFTER this append then minted the SAME id as one
        // taken BEFORE it, and a write through the new pointer became
        // visible through the old one even though `~=` may have reallocated
        // in real D. `dropArrayCell` mints a fresh id for the next
        // address-of instead, matching the fresh-id principle that
        // fresh-binding sites already apply -- the correct, D-matching
        // choice even though it changes `p is q` identity for the case
        // where the append happened not to reallocate.
        dropArrayCell(variable);

        return locals[variable];
    }

    private Value runArrayConcatenateAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (assign.e1.isDotVarExp !is null) {
            const concatenated = AggregateValue.reconstructArray(
                concatenationElements(assign.e1) ~
                    concatenationElements(assign.e2),
            );
            writeLocation(assign.e1, concatenated);
            return concatenated;
        }

        if (auto var = assign.e1.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception(
                    "Unsupported interpreter array concatenate target.",
                );

            const concatenated = AggregateValue.reconstructArray(
                concatenationElements(assign.e1) ~
                    concatenationElements(assign.e2),
            );
            writeLocation(assign.e1, concatenated);
            return concatenated;
        }

        throw new Exception("Unsupported interpreter array concatenate target.");
    }

    private Value runIndexedArrayAppendAssignExpression(
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter array append target.");

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter array append target.");

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
        const appended = AggregateValue.withAppendedArrayElement(
            AggregateValue.elementAt(*current, arrayIndex), runExpression(rhs));
        setLocal(variable, AggregateValue.withArrayElement(*current, arrayIndex, appended));
        uninitializedLocals.remove(variable);
        return appended;
    }

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;
        import quickbite.frontend.dmd.types: isPointerType;
        import dmd.astenums: TY;

        auto type = cast_.to.toBasetype;
        if (type is null)
            return runExpression(cast_.e1);

        if (type.ty == TY.Tvoid) {
            runExpression(cast_.e1);
            return Value.void_;
        }

        if (type.ty == TY.Tclass)
            return classCastValue(cast_);

        if (type.ty == TY.Tident) {
            Value value;
            if (tryIdentifierClassCastValue(cast_, value))
                return value;
        }

        if (
            type.ty == TY.Tarray &&
            type.nextOf.toBasetype.ty == TY.Tvoid
        ) {
            import quickbite.backends.interpreter.layout: typeByteSize;

            const value = runExpression(cast_.e1);
            if (value.isArray && value.arrayNativeAddress !is null)
                return Value.nativeArrayValueWithLength(
                    value.length * typeByteSize(
                        cast_.e1.type.toBasetype.nextOf,
                    ),
                    value.arrayNativeAddress,
                );
            return value;
        }

        if (isTransparentArrayCastTarget(type)) {
            Value reinterpreted;
            if (reinterpretScalarArrayCast(cast_, reinterpreted))
                return reinterpreted;
            return runExpression(cast_.e1);
        }

        if (type.ty == TY.Tbool)
            return boolCastValue(cast_);

        if (type.ty == TY.Tdelegate)
            return delegateCastValue(cast_);

        if (isPointerType(type))
            return pointerCastValue(cast_);

        if (auto integer = cast_.e1.isIntegerExp)
            if (integer.type !is null && integer.type.ty == TY.Tenum) {
                import quickbite.backends.interpreter.runtime_values: castIntegerValue;

                return castIntegerValue(integer, type.ty);
            }

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
    }

    private bool reinterpretScalarArrayCast(
        imported!"dmd.expression".CastExp cast_,
        out Value result,
    ) {
        import std.conv: text;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, writeScalar;
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

        const source = runExpression(cast_.e1);
        if (source.arrayAllocationId != 0) {
            const id = source.arrayAllocationId;
            if (auto sourceCarrier = id in arrayAllocationCarriers) {
                const offset = source.arrayAllocationOffset;
                if (
                    offset > sourceCarrier.length ||
                    source.length > sourceCarrier.length - offset
                )
                    throw new Exception(
                        "Existing array cast view exceeds its allocation carrier.",
                    );

                auto targetCarrier =
                    sourceCarrier.reinterpretElements(targetType);
                auto targetView = targetCarrier.slice(
                    offset,
                    offset + source.length,
                );
                result = arrayValueFromCarrier(
                    targetView,
                    targetCarrier,
                    id,
                    offset,
                );
                return true;
            }
        }

        if (auto sourceVar = cast_.e1.isVarExp)
            if (auto sourceVariable = sourceVar.var.isVarDeclaration) {
                promoteArrayCell(sourceVariable);
                if (auto sourceCell = sourceVariable in arrayCells) {
                    auto targetView =
                        sourceCell.reinterpretElements(targetType);
                    const id = sourceVariable in arrayAllocationAliases;
                    const allocation =
                        id is null ? allocationId(sourceVariable) : *id;
                    if (allocation !in arrayAllocationCarriers)
                        arrayAllocationCarriers[allocation] = targetView;
                    auto carrier = allocation in arrayAllocationCarriers;
                    auto sourceCarrier =
                        carrier.reinterpretElements(sourceType);
                    auto targetCarrier =
                        carrier.reinterpretElements(targetType);
                    const offset = source.arrayAllocationOffset;
                    if (
                        offset > targetCarrier.length ||
                        source.length > targetCarrier.length - offset
                    )
                        throw new Exception(
                            text(
                                "New array cast view [",
                                offset,
                                " .. ",
                                offset + source.length,
                                ") exceeds allocation carrier length ",
                                targetCarrier.length,
                                ".",
                            ),
                        );

                    targetView = targetCarrier.slice(
                        offset,
                        offset + source.length,
                    );
                    auto sourceView = sourceCarrier.slice(
                        offset,
                        offset + source.length,
                    );
                    setLocal(sourceVariable, arrayValueFromCarrier(
                        sourceView,
                        sourceCarrier,
                        allocation,
                        offset,
                    ));
                    result = arrayValueFromCarrier(
                        targetView,
                        targetCarrier,
                        allocation,
                        offset,
                    );
                    return true;
                }
            }

        // An unbound array rvalue still needs a boxed expression result. Use
        // one native source block for the reinterpretation; a local binding
        // takes the shared-cell path above and never reaches this fallback.
        auto sourceCell = NativeArray.allocate(sourceType, source.length);
        foreach (index; 0 .. source.length)
            writeScalar(sourceType, sourceCell.element(index), source[index]);

        auto targetView = sourceCell.reinterpretElements(targetType);
        result = arrayValueFromCell(targetView);
        return true;
    }

    private Value boolCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const value = runExpression(cast_.e1);
        if (value.isPointer)
            return Value(true);
        if (value == Value.null_)
            return Value(false);

        return backendCastValue(value, backendCastTarget(cast_.to));
    }

    private Value delegateCastValue(imported!"dmd.expression".CastExp cast_) {
        import std.conv: text;

        const value = runExpression(cast_.e1);
        if (value == Value.null_ || value.isFunctionPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    private Value classCastValue(imported!"dmd.expression".CastExp cast_) {
        const value = runExpression(cast_.e1);
        if (value == Value.null_)
            return value;

        auto classType = cast_.to.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception("Unsupported class cast target.");

        return AggregateValue.hasClassType(value, className(classType.sym))
            ? nativeExceptionObjectWithClassFields(classType.sym, value)
            : Value.null_;
    }

    private bool tryIdentifierClassCastValue(
        imported!"dmd.expression".CastExp cast_,
        out Value result,
    ) {
        import std.algorithm: canFind;

        if (!typeChars(cast_.to).canFind("Throwable"))
            return false;

        const value = runExpression(cast_.e1);
        if (value == Value.null_) {
            result = value;
            return true;
        }

        if (!AggregateValue.isClass(value))
            return false;

        result = AggregateValue.hasClassType(value, "Throwable")
            ? value
            : Value.null_;
        return true;
    }

    // DMD semantic lowers `array.ptr` to `cast(T*) array`
    private Value pointerCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.frontend.dmd.types: isArrayType;
        import std.conv: text;

        if (isArrayType(cast_.e1.type))
            return arrayPointer(cast_.e1, 0, cast_.op);

        const value = runExpression(cast_.e1);
        if (value == Value.null_)
            return value;
        if (value.isPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    private Value arrayValue(
        imported!"dmd.expression".ArrayLiteralExp array,
    ) {
        Value[] values;
        if (array.elements !is null)
            // DMD's sparse form: a null element means the value is in `basis`
            // (see ArrayLiteralExp.getElement).
            foreach (element; *array.elements)
                values ~= runExpression(element is null ? array.basis : element);

        return AggregateValue.reconstructArray(values);
    }

    private Value structLiteralValue(
        imported!"dmd.expression".StructLiteralExp literal,
    ) {
        Value[] fields;
        if (literal.elements !is null)
            foreach (index, element; *literal.elements)
                fields ~= element is null
                    ? structLiteralDefaultFieldValue(literal, index, fields)
                    : structLiteralFieldValue(literal, index, runExpression(element));

        return AggregateValue.reconstructStruct(structLiteralName(literal), fields);
    }

    // DMD's `defaultInitLiteral` for a union only ever fills the FIRST
    // declared member's `elements` slot; every sibling stays `null`
    // (confirmed by inspection: a probe fixture's `elements` array had
    // `[<float.init literal>, null]` for `union U { float f; int i; }`).
    // Real D zero-initializes the union's WHOLE storage block from that
    // first member's own bytes, so an untouched sibling reads the first
    // member's bits reinterpreted as its own type -- not its own type's
    // independent default.
    // `fieldsSoFar` is this literal's own `fields` accumulator: by the time
    // a later index is processed, index 0's value has already been
    // computed and appended, so it is always available here without a
    // second pass.
    private Value structLiteralDefaultFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
        in Value[] fieldsSoFar,
    ) {
        auto field = structLiteralField(literal, index);
        if (field is null)
            return Value.void_;

        Value reinterpreted;
        if (unionSiblingDefaultFieldValue(literal, index, field, fieldsSoFar, reinterpreted))
            return reinterpreted;

        return defaultValue(field);
    }

    // Scalar, struct/union, scalar-leaf-static-array, or one-level static-
    // array-of-plain-struct sibling: returns
    // `false` (leaving `value` untouched) for index 0 itself, a non-union
    // literal, a sibling that
    // is none of those supported shapes, or a first member that is neither
    // `isNativeScalarType`, a struct/union, a scalar-leaf static array, nor a
    // possibly-nested static array of plain structs -- so the caller's
    // existing independent-`defaultValue` fallback applies unchanged in every
    // other case,
    // including the still-open gap for a class first member/sibling. When
    // the first member is a struct or union, reuses `withUnionFieldWrite`'s own
    // `writeStructCellScalarFields` idiom to seed the transient cell's
    // shared bytes from the first member's already-resolved struct value
    // (scalar leaves only, recursing through nested structs/scalar-leaf
    // arrays exactly as that helper already does) before reading the sibling
    // back out. A nested union's boxed fields already agree on those bytes
    // through this same default reconstruction. A union sibling uses that
    // same reader: each supported field is independently reconstructed from
    // the one overlapping block.
    private bool unionSiblingDefaultFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
        imported!"dmd.declaration".VarDeclaration field,
        in Value[] fieldsSoFar,
        out Value value,
    ) {
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar, writeScalar;
        if (index == 0 || fieldsSoFar.length == 0 || literal.sd is null)
            return false;

        if (literal.sd.isUnionDeclaration is null)
            return false;

        auto unionType = literal.type is null ? null : literal.type.toBasetype.isTypeStruct;
        if (unionType is null)
            return false;

        const siblingScalar = isNativeScalarType(field.type);
        auto siblingStructType = field.type.toBasetype.isTypeStruct;
        const siblingStruct = siblingStructType !is null;
        const siblingArray = isScalarLeafStaticArray(field.type);
        auto siblingArrayType = field.type.toBasetype.isTypeSArray;
        auto siblingArrayStructType = siblingArrayType is null
            ? null
            : siblingArrayType.next.toBasetype.isTypeStruct;
        const siblingStructArray = siblingArrayStructType !is null
            && siblingArrayStructType.sym.isUnionDeclaration is null;
        if (
            !siblingScalar &&
            !siblingStruct &&
            !siblingArray &&
            !siblingStructArray
        )
            return false;

        auto firstField = structLiteralField(literal, 0);
        if (firstField is null)
            return false;

        const firstFieldScalar = isNativeScalarType(firstField.type);
        auto firstFieldStructType = firstField.type.toBasetype.isTypeStruct;
        const firstFieldStruct = firstFieldStructType !is null;
        const firstFieldArray = isScalarLeafStaticArray(firstField.type)
            && fieldsSoFar[0].isArray;
        const firstFieldStructArray = isStaticArrayOfPlainStructs(firstField.type)
            && fieldsSoFar[0].isArray;

        if (
            !firstFieldScalar &&
            !firstFieldStruct &&
            !firstFieldArray &&
            !firstFieldStructArray
        )
            return false;

        auto cell = NativeStruct.allocate(unionType);
        if (firstFieldStruct) {
            auto firstCell = cell.structField(0);
            writeStructCellScalarFields(firstCell, fieldsSoFar[0]);
        } else if (firstFieldArray) {
            auto firstCell = cell.arrayField(0);
            writeStaticArrayCellScalarElements(firstCell, fieldsSoFar[0]);
        } else if (firstFieldStructArray) {
            auto firstCell = cell.arrayField(0);
            writeStaticArrayCellStructElements(firstCell, fieldsSoFar[0]);
        } else {
            writeScalar(firstField.type, cell.field(0), fieldsSoFar[0]);
        }

        if (siblingScalar) {
            value = readScalar(field.type, cell.field(index));
        } else if (siblingStruct) {
            auto current = defaultValue(field);
            if (!current.isStruct)
                return false;

            auto siblingCell = cell.structField(index);
            value = structValueFromCell(current, siblingCell);
        } else if (siblingStructArray) {
            value = defaultValue(field);
            if (!value.isArray)
                return false;

            auto siblingCell = cell.arrayField(index);
            foreach (elementIndex; 0 .. siblingCell.length) {
                auto elementCell = siblingCell.structElement(elementIndex);
                value = AggregateValue.withArrayElement(value,
                    elementIndex,
                    structValueFromCell(value[elementIndex], elementCell),
                );
            }
        } else {
            auto siblingCell = cell.arrayField(index);
            value = arrayValueFromCell(siblingCell);
        }
        return true;
    }

    // Struct-leaf counterpart of `writeStaticArrayCellScalarElements`:
    // nested arrays compose `NativeArray` views until the existing
    // `NativeStruct` field writer can seed each plain-struct leaf.
    private void writeStaticArrayCellStructElements(
        ref NativeArray cell,
        in Value arrayValue,
    ) {
        if (!arrayValue.isArray)
            return;

        foreach (index; 0 .. cell.length) {
            if (index >= arrayValue.length)
                continue;

            if (cell.elementType.isTypeSArray) {
                // Mutable because recursive write takes the view by ref.
                auto elementCell = cell.arrayElement(index);
                writeStaticArrayCellStructElements(
                    elementCell,
                    arrayValue[index],
                );
            } else {
                auto elementCell = cell.structElement(index);
                writeStructCellScalarFields(elementCell, arrayValue[index]);
            }
        }
    }

    private bool isScalarLeafStaticArray(imported!"dmd.mtype".Type type) {
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        if (!isStaticArrayType(type))
            return false;

        auto elementType = type.toBasetype.nextOf.toBasetype;
        while (isStaticArrayType(elementType))
            elementType = elementType.nextOf.toBasetype;
        return isNativeScalarType(elementType);
    }

    private bool isStaticArrayOfPlainStructs(
        imported!"dmd.mtype".Type type,
    ) {
        auto elementType = type.toBasetype;
        do {
            auto arrayType = elementType.isTypeSArray;
            if (arrayType is null)
                return false;
            elementType = arrayType.next.toBasetype;
        } while (elementType.isTypeSArray !is null);

        auto structType = elementType.isTypeStruct;
        return structType !is null &&
            structType.sym.isUnionDeclaration is null;
    }

    private Value structLiteralFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
        in Value value,
    ) {
        import quickbite.frontend.dmd.types: isAssocArrayType;
        import quickbite.backends.interpreter.layout: staticArrayLength;

        auto field = structLiteralField(literal, index);
        if (field is null)
            return value;

        if (value == Value.null_ && isAssocArrayType(field.type))
            return Value.assocArrayValue([], []);

        auto staticArray = field.type is null ? null : field.type.toBasetype.isTypeSArray;
        if (staticArray is null || value.isArray)
            return value;

        const length = staticArrayLength(staticArray);
        Value[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        return Value.arrayValue(elements);
    }

    // duplicate keys keep the last value, as in compiled D
    private Value assocArrayValue(
        imported!"dmd.expression".AssocArrayLiteralExp assocArray,
    ) {
        auto value = Value.assocArrayValue([], []);
        foreach (index; 0 .. assocArray.keys.length)
            value = value.withAssocArrayEntry(
                runExpression((*assocArray.keys)[index]),
                runExpression((*assocArray.values)[index]),
            );

        return value;
    }

    private Value runSliceExpression(imported!"dmd.expression".SliceExp slice) {
        size_t lower;
        return runSliceExpression(slice, lower);
    }

    private Value runSliceExpression(
        imported!"dmd.expression".SliceExp slice,
        out size_t lower,
    ) {
        const source = runExpression(slice.e1);
        if (slice.lengthVar !is null)
            setLocal(slice.lengthVar, Value(source.length));
        lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;

        if (source.isPointer) {
            if (slice.upr is null) {
                import std.conv: text;
                throw new Exception(
                    text("Unsupported eval expression: ", slice.op),
                );
            }

            const upper = cast(size_t) runExpression(slice.upr).asLong;

            // Slicing native memory (`ptr[0 .. n]` over a C allocation, as
            // std.file.read does): reify the elements into an array Value.
            if (source.isNativePointer) {
                import quickbite.backends.interpreter.layout: typeByteSize;

                Value[] elements;
                foreach (index; lower .. upper)
                    elements ~= loadNativePointerElement(
                        slice.e1.type,
                        source,
                        index,
                    );
                return AggregateValue.reconstructNativeArray(
                    elements,
                    cast(const(ubyte)*) source.asNativePointer + lower *
                        typeByteSize(slice.e1.type.toBasetype.nextOf),
                );
            }

            if (source.isLocalPointer)
                return localPointerByteSlice(source, lower, upper);

            return source.pointerSlice(lower, upper);
        }

        const upper = slice.upr is null
            ? source.length
            : cast(size_t) runExpression(slice.upr).asLong;

        if (source.isArray && (lower > upper || upper > source.length))
            throwRangeError("Range violation");

        auto nativeAddress = source.arrayNativeAddress;
        if (nativeAddress is null)
            if (auto var = slice.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration) {
                    auto sourceVariable = variable;
                    size_t sourceLower;
                    if (auto alias_ = variable in sliceAliases) {
                        sourceVariable = alias_.source;
                        sourceLower = alias_.lower;
                    }
                    if (auto cell = sourceVariable in arrayCells)
                        nativeAddress = cast(const(ubyte)*) cell.block.address +
                            sourceLower * cell.stride;
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

            return AggregateValue.reconstructNativeArrayWithLength(
                (upper - lower) *
                    typeByteSize(slice.e1.type.toBasetype.nextOf),
                nativeAddress,
            );
        }
        return AggregateValue.slice(source, lower, upper, nativeAddress);
    }

    private Value runIndexExpression(imported!"dmd.expression".IndexExp index) {
        size_t arrayIndex;
        return runIndexExpression(index, arrayIndex);
    }

    // Read an element from native (C heap) memory addressed by a
    // NativePointer: a snapshot Value built from the pointee's bytes (a
    // scalar, a pointer, or a whole struct such as std.stdio.File's malloc'd
    // Impl).
    private Value loadNativePointerElement(
        imported!"dmd.mtype".Type pointerType,
        in Value pointer,
        in size_t index,
    ) {
        import quickbite.backends.interpreter.ffi_marshal: unmarshalNative;
        import quickbite.backends.interpreter.layout: typeByteSize;

        auto elementType = pointerType.toBasetype.nextOf.toBasetype;
        return unmarshalNative(
            elementType,
            nativeElementAddress(
                pointer.asNativePointer,
                index,
                typeByteSize(elementType),
            ),
        );
    }

    private void storeNativePointerElement(
        imported!"dmd.mtype".Type pointerType,
        in Value pointer,
        in size_t index,
        in Value value,
    ) {
        import quickbite.backends.interpreter.ffi_marshal: marshalNative;
        import quickbite.backends.interpreter.layout: typeByteSize;

        auto elementType = pointerType.toBasetype.nextOf.toBasetype;
        marshalNative(
            elementType,
            nativeElementAddress(
                pointer.asNativePointer,
                index,
                typeByteSize(elementType),
            ),
            value,
        );
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

    // Apply writebacks reported by a native call to their source argument
    // variables: `&local` out-parameters (such as strtol's `char** endptr`) and
    // mutable slice arguments the callee wrote through (ffi.md §34.10).
    private void applyNativeWritebacks(
        in Value[] writebacks,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        foreach (index, writeback; writebacks) {
            if (writeback == Value.void_)
                continue;

            auto variable = nativeOutParameterVariable(argumentExpressions[index]);
            if (variable is null)
                throw new Exception("Unsupported native out-parameter target.");

            // A promoted cell is the byte authority: the
            // argument-evaluation pass that ran `&local` for this native
            // call already promoted `variable` (see `promoteScalarCell`),
            // so the writeback must land in the cell too, or a direct
            // `VarExp` read afterwards would see the cell's stale bytes
            // instead of what the callee wrote (e.g. pthread_mutexattr_
            // gettype's `int* kind` out-parameter). `writeCelledLocal` is
            // exactly this cell-then-mirror pattern.
            writeCelledLocal(variable, writeback);
        }
    }

    // Write a mutating native member's receiver back into the caller's variable
    // (ffi.md §34.9). Gated to addressable locals; non-lvalue receivers are out
    // of scope and silently keep their pre-call value.
    private void applyReceiverWriteback(
        imported!"dmd.expression".Expression receiverExpression,
        in Value receiverWriteback,
    ) {
        if (receiverWriteback == Value.void_)
            return;

        auto receiver = receiverExpression.isVarExp;
        if (receiver is null)
            return;

        auto variable = receiver.var.isVarDeclaration;
        if (variable is null)
            return;

        setLocal(variable, receiverWriteback);
        uninitializedLocals.remove(variable);
    }

    // Flag each argument that is `&local`, so the FFI core can treat a
    // single-level pointer-to-scalar at that slot as an out parameter rather
    // than an in-pointer (ffi.md §34.8).
    private bool[] nativeAddressOfLocalArguments(
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        auto flags = new bool[](argumentExpressions.length);
        foreach (index, argument; argumentExpressions)
            flags[index] = isNativeAddressOfLocal(argument);
        return flags;
    }

    private bool isNativeAddressOfLocal(
        imported!"dmd.expression".Expression argument,
    ) {
        import quickbite.frontend.dmd.types: isStaticArrayType;

        if (auto address = argument.isAddrExp)
            if (auto var = address.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    return !isStaticArrayType(variable.type);

        // A pointer into a static-array local (`&buf[i]`, folded to a
        // SymOffExp) is an in-pointer to the array's elements, not an out
        // slot for the callee to fill.
        if (auto symbol = argument.isSymOffExp)
            if (auto variable = symbol.var.isVarDeclaration)
                return !isStaticArrayType(variable.type);

        return argument.isSymOffExp !is null;
    }

    private imported!"dmd.declaration".VarDeclaration nativeOutParameterVariable(
        imported!"dmd.expression".Expression argument,
    ) {
        if (auto address = argument.isAddrExp)
            if (auto var = address.e1.isVarExp)
                return var.var.isVarDeclaration;

        if (auto symbol = argument.isSymOffExp)
            return symbol.var.isVarDeclaration;

        // A mutable slice argument is passed as the plain variable; its
        // writeback targets that same local (ffi.md §34.10).
        if (auto var = argument.isVarExp)
            return var.var.isVarDeclaration;

        return null;
    }

    // The current value behind each `&local` argument (Value.void_ elsewhere):
    // the FFI core marshals it into the out-parameter cell so an in-out callee
    // reads the caller's value instead of a zeroed cell (ffi.md §35.6). A
    // void-initialized local marshals its default value, matching the zeroed
    // cell compiled code cannot improve on deterministically.
    private Value[] nativeOutParameterInputValues(
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        auto values = new Value[](argumentExpressions.length);
        foreach (index, argument; argumentExpressions) {
            if (!isNativeAddressOfLocal(argument))
                continue;

            auto variable = nativeOutParameterVariable(argument);
            if (variable is null)
                continue;

            if (variable in uninitializedLocals)
                values[index] = defaultValue(variable);
            else if (auto current = variable in locals)
                values[index] = *current;
        }
        return values;
    }

    private Value runIndexExpression(
        imported!"dmd.expression".IndexExp index,
        out size_t arrayIndex,
    ) {
        import quickbite.frontend.dmd.types:
            isAssocArrayType,
            isPointerType;

        if (isAssocArrayType(index.e1.type)) {
            arrayIndex = 0;
            return runExpression(index.e1)
                .assocArrayElement(runExpression(index.e2));
        }

        // `$` inside index.e2 is a DollarExp bound to index.lengthVar, so it
        // must see the array's current length: run index.e1 and seed
        // lengthVar from its result before evaluating index.e2, the same
        // order runSliceExpression already uses for the same `$` binding.
        // Evaluating e2 first left lengthVar holding a stale (or default
        // zero) length, so `arr[$ - 1]` on a just-grown array underflowed to
        // size_t.max instead of the intended last-element index.
        const source = runExpression(index.e1);
        if (index.lengthVar !is null)
            setLocal(index.lengthVar, Value(source.length));

        // matches CTFE, which formats the index as unsigned
        arrayIndex = cast(size_t) cast(ulong) runExpression(index.e2).asLong;
        if (_evaluatedReferenceArgumentIndices !is null)
            (*_evaluatedReferenceArgumentIndices)[cast(const(void)*) index] =
                arrayIndex;

        // covers both array-backed pointers and druntime hook results such
        // as `_d_aaGetRvalueX` slot pointers, which DMD dereferences with a
        // zero index
        if (isPointerType(index.e1.type)) {
            if (source.isLocalPointer)
                return localPointerTarget(source);
            if (source.isNativePointer)
                return loadNativePointerElement(index.e1.type, source, arrayIndex);
            return source.pointerIndex(arrayIndex);
        }

        if (source.isArray && arrayIndex >= source.length) {
            import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;

            throwRangeError(indexOutOfBoundsMessage(
                arrayIndex,
                source.length,
                isSliceValue(index.e1),
                runningCalledFunction,
            ));
        }

        // Byte-level authority for a slice's shared storage, reverse
        // direction: once `promoteSliceArrayCell` has given `variable` an
        // `arrayCells` entry sharing storage with its slice source (or
        // `promoteArrayCell` gave the source itself one), its bytes -- not
        // `source`'s own boxed snapshot, which a direct write to the OTHER
        // aliased variable never refreshes -- are the true value. A no-op
        // for any variable without a promoted cell (falls through to the
        // existing boxed read below), and for a non-`VarExp` `index.e1`
        // (a struct field, nested index, ...), which this narrow first
        // slice does not extend.
        if (auto var = index.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                if (auto cell = variable in arrayCells)
                    return readArrayCellElement(variable, *cell, arrayIndex);

        return source[arrayIndex];
    }

    private void throwRangeError(in string message) {
        throw new InterpretedException(nativeExceptionBaseObject(
            message,
            "core.exception.RangeError",
        ));
    }

    private bool isSliceValue(imported!"dmd.expression".Expression expression) {
        if (expression.isSliceExp !is null)
            return true;

        auto var = expression.isVarExp;
        if (var is null)
            return false;

        auto variable = var.var.isVarDeclaration;
        return variable !is null && (variable in sliceAliases) !is null;
    }

    private Value localPointerTarget(in Value pointer) {
        auto variable = pointer.localPointerId in localPointers;
        if (variable is null)
            throw new Exception("Unsupported interpreter pointer target.");

        // Byte-level authority: a promoted
        // cell -- not the boxed `locals` mirror -- is the true value once
        // `&variable` promoted one, the same priority `readCelledLocal`
        // gives `runPointerExpression`'s deref-read arm. Without this,
        // `(*p)++`/atomics through a celled local (this helper's callers,
        // via `pointerTargetValue`/`readPointerTarget`) read stale bytes.
        return readCelledLocal(*variable);
    }

    // Byte-level authority for an array-element pointer:
    // once `&a[i]` has promoted an `arrayCells` entry for the variable a
    // non-local pointer points into, its bytes -- not a boxed snapshot --
    // are the true value. Shared by `runPointerExpression`'s deref-read arm
    // and `pointerTargetValue` (the compound-assignment/atomic/post-
    // increment read path) so both agree on the same cell. Returns `false`
    // (leaving `value` untouched) for every other array pointer -- no
    // promoted cell, or a static array -- which keeps the existing boxed
    // `pointerTarget` fallback at each call site. A struct element is
    // handled the same as a scalar
    // element, both via `readArrayCellElement`.
    private bool arrayPointerCellValue(in Value pointer, out Value value) {
        auto variable = arrayPointerVariable(pointer);
        if (variable is null)
            return false;

        auto cell = *variable in arrayCells;
        if (cell is null)
            return false;

        value = readArrayCellElement(
            *variable,
            *cell,
            cast(size_t) pointer.pointerElementOffset,
        );
        return true;
    }

    // The single ordered route through promoted boxed-pointer cells. Both
    // direct dereference and compound-assignment/atomic reads use this gate,
    // so they cannot disagree about which interim mirror is authoritative.
    private bool pointerCellValue(in Value pointer, out Value value) {
        return arrayPointerCellValue(pointer, value) ||
            structFieldPointerCellValue(pointer, value) ||
            structArrayFieldPointerCellValue(pointer, value) ||
            nestedStructFieldPointerCellValue(pointer, value) ||
            arrayNestedStructFieldPointerCellValue(pointer, value) ||
            classFieldPointerCellValue(pointer, value) ||
            nestedClassStructFieldPointerCellValue(pointer, value) ||
            classArrayFieldPointerCellValue(pointer, value);
    }

    // Byte-level authority for a struct-field pointer:
    // once `&s.field` has promoted a `structCells`
    // entry for the struct variable a non-local pointer points into, its
    // bytes -- not the boxed snapshot `addressOfExpression` took at
    // address-of time -- are the true value. Shared by
    // `runPointerExpression`'s deref-read arm and `pointerTargetValue` (the
    // compound-assignment/atomic/post-increment read path), mirroring
    // `arrayPointerCellValue` above for the array-element case. Returns
    // `false` (leaving `value` untouched) for every other field pointer --
    // no promoted cell, a non-scalar field, or a pointer that was never a
    // struct-field address at all -- which keeps the existing boxed
    // `pointerTarget` fallback at each call site.
    private bool structFieldPointerCellValue(in Value pointer, out Value value) {
        if (!isBoxedPointer(pointer))
            return false;

        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 1)
            return false;

        auto cell = path.root in structCells;
        if (cell is null)
            return false;

        const fieldIndex = path.indices[0];

        import quickbite.backends.interpreter.native_scalar: readScalar;

        value = readScalar(cell.fieldDeclaration(fieldIndex).type, cell.field(fieldIndex));
        return true;
    }

    // Class sibling of `structFieldPointerCellValue` above:
    // once `&c.field` has promoted a `classCells`
    // entry for the class variable a non-local pointer points into, its
    // bytes -- not the boxed snapshot `addressOfExpression` took at
    // address-of time -- are the true value. Shared by the same two call
    // sites. Returns `false` (leaving `value` untouched) for every other
    // field pointer -- no promoted cell, a non-scalar field, or a pointer
    // that was never a class-field address at all.
    private bool classFieldPointerCellValue(in Value pointer, out Value value) {
        if (!isBoxedPointer(pointer))
            return false;

        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 1)
            return false;

        auto variable = path.root;

        auto identity = pointer.pointerAllocation in classFieldPointerObjectIds;
        if (identity is null)
            return false;

        auto cell = *identity in classObjectCells;
        if (cell is null)
            return false;

        const fieldIndex = path.indices[0];

        import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, typeByteSize;
        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto classType = variable.type.toBasetype.isTypeClass;
        if (classType is null)
            return false;
        auto field = classFields(classType.sym)[fieldIndex];
        const offset = fieldByteOffset(field);
        const size = typeByteSize(field.type);
        value = readScalar(field.type, cell.bytes[offset .. offset + size]);
        return true;
    }

    // Array-typed-field sibling of `structFieldPointerCellValue` above:
    // once `&s.arr[i]` has promoted a `structCells` entry, the cell's
    // `NativeStruct.arrayField` view -- not the boxed snapshot
    // `arrayPointer` took at address-of time -- is the true value at the
    // pointer's element offset. Returns `false` (leaving `value` untouched)
    // for every other pointer -- no promoted cell, or a pointer that was
    // never a struct-array-field address at all -- which keeps the existing
    // boxed `pointerTarget` fallback at each call site.
    private bool structArrayFieldPointerCellValue(in Value pointer, out Value value) {
        if (!isBoxedPointer(pointer))
            return false;

        auto variable = pointer.pointerAllocation in structArrayFieldPointerVariables;
        if (variable is null)
            return false;

        auto cell = *variable in structCells;
        if (cell is null)
            return false;

        auto fieldIndex = pointer.pointerAllocation in structArrayFieldPointerFieldIndices;
        if (fieldIndex is null)
            return false;

        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto arrayCell = cell.arrayField(*fieldIndex);
        value = readScalar(
            arrayCell.elementType,
            arrayCell.element(cast(size_t) pointer.pointerElementOffset),
        );
        return true;
    }

    // Class-receiver sibling of `structArrayFieldPointerCellValue` above,
    // the class-array-field counterpart of the nested-class-struct-field
    // case: once `&c.arr[i]` has promoted a `classCells` entry, the
    // cell's `NativeArray` view -- adopted over the field's own byte
    // sub-range, since a `classCells` entry is a plain `NativeBlock` rather
    // than a `NativeStruct` (see `classCells`'s own field comment) -- is the
    // true value at the pointer's element offset, not the boxed snapshot
    // `arrayPointer` took at address-of time. Returns `false` (leaving
    // `value` untouched) for every other pointer -- no promoted cell, or a
    // pointer that was never a class-array-field address at all -- which
    // keeps the existing boxed `pointerTarget` fallback at each call site.
    private bool classArrayFieldPointerCellValue(in Value pointer, out Value value) {
        if (!isBoxedPointer(pointer))
            return false;

        auto variable = pointer.pointerAllocation in classArrayFieldPointerVariables;
        if (variable is null)
            return false;

        auto cell = *variable in classCells;
        if (cell is null)
            return false;

        auto fieldIndex = pointer.pointerAllocation in classArrayFieldPointerFieldIndices;
        if (fieldIndex is null)
            return false;

        import quickbite.backends.interpreter.layout:
            classFields, fieldByteOffset, staticArrayLength, typeByteSize;
        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto classType = (*variable).type.toBasetype.isTypeClass;
        auto field = classFields(classType.sym)[*fieldIndex];
        auto arrayType = field.type.toBasetype.isTypeSArray;
        if (arrayType is null)
            return false;

        auto elementType = arrayType.next.toBasetype;
        const offset = fieldByteOffset(field);
        const size = typeByteSize(field.type);
        auto arrayCell = NativeArray.adopt(cell.subRange(offset, size), elementType, staticArrayLength(arrayType));
        value = readScalar(
            elementType,
            arrayCell.element(cast(size_t) pointer.pointerElementOffset),
        );
        return true;
    }

    // Nested-struct-field sibling of `structFieldPointerCellValue`/
    // `structArrayFieldPointerCellValue` above: once `&s.inner.x` has
    // promoted a
    // `structCells` entry, the cell's nested `NativeStruct.
    // structField(outerIndex)` view -- not the boxed snapshot
    // `addressOfExpression` took at address-of time -- is the true value at
    // the inner field index. Returns `false` (leaving `value` untouched) for
    // every other pointer -- no promoted cell, or a pointer that was never a
    // nested-struct-field address at all -- which keeps the existing boxed
    // `pointerTarget` fallback at each call site.
    private bool nestedStructFieldPointerCellValue(in Value pointer, out Value value) {
        if (!isBoxedPointer(pointer))
            return false;

        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 2)
            return false;

        auto cell = path.root in structCells;
        if (cell is null)
            return false;

        const outerFieldIndex = path.indices[0];
        const innerFieldIndex = path.indices[1];

        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto nestedCell = cell.structField(outerFieldIndex);
        value = readScalar(
            nestedCell.fieldDeclaration(innerFieldIndex).type,
            nestedCell.field(innerFieldIndex),
        );
        return true;
    }

    // Array-element sibling of `nestedStructFieldPointerCellValue` above,
    // composing array-element and nested-field access:
    // once `&a[i].inner.x` has promoted an `arrayCells` entry, the cell's
    // per-element `NativeArray.structElement(elementIndex)` view, further
    // narrowed by its own nested `NativeStruct.structField(outerIndex)` view
    // -- composing the two pre-existing accessors exactly as
    // `promoteArrayNestedStructFieldCell` does -- is the true value at the
    // inner field index, not the boxed snapshot `addressOfExpression` took at
    // address-of time. Returns `false` (leaving `value` untouched) for every
    // other pointer, which keeps the existing boxed `pointerTarget` fallback
    // at each call site.
    private bool arrayNestedStructFieldPointerCellValue(in Value pointer, out Value value) {
        if (!isBoxedPointer(pointer))
            return false;

        auto variable = pointer.pointerAllocation in arrayNestedStructFieldPointerVariables;
        if (variable is null)
            return false;

        auto cell = *variable in arrayCells;
        if (cell is null)
            return false;

        auto elementIndex = pointer.pointerAllocation in arrayNestedStructFieldPointerElementIndices;
        if (elementIndex is null)
            return false;

        auto outerFieldIndex = pointer.pointerAllocation in arrayNestedStructFieldPointerOuterFieldIndices;
        if (outerFieldIndex is null)
            return false;

        auto innerFieldIndex = pointer.pointerAllocation in arrayNestedStructFieldPointerInnerFieldIndices;
        if (innerFieldIndex is null)
            return false;

        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto nestedCell = cell.structElement(*elementIndex).structField(*outerFieldIndex);
        value = readScalar(
            nestedCell.fieldDeclaration(*innerFieldIndex).type,
            nestedCell.field(*innerFieldIndex),
        );
        return true;
    }

    // Class-receiver sibling of `nestedStructFieldPointerCellValue` above:
    // once `&c.inner.x` has promoted a `classCells` entry, the cell's nested
    // `NativeStruct` view -- adopted over the outer field's own byte
    // sub-range, since a `classCells` entry is a plain `NativeBlock` rather
    // than a `NativeStruct` (see `classCells`'s own field comment) -- is the
    // true value at the inner field index, not the boxed snapshot
    // `addressOfExpression` took at address-of time. Returns `false`
    // (leaving `value` untouched) for every other pointer -- no promoted
    // cell, or a pointer that was never a nested-class-struct-field address
    // at all -- which keeps the existing boxed `pointerTarget` fallback at
    // each call site.
    private bool nestedClassStructFieldPointerCellValue(in Value pointer, out Value value) {
        if (!isBoxedPointer(pointer))
            return false;

        auto path = pointer.pointerAllocation in fieldPointerPaths;
        if (path is null || path.indices.length != 2)
            return false;

        auto variable = path.root;
        auto cell = variable in classCells;
        if (cell is null)
            return false;

        const outerFieldIndex = path.indices[0];
        const innerFieldIndex = path.indices[1];

        import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, typeByteSize;
        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto classType = variable.type.toBasetype.isTypeClass;
        auto outerField = classFields(classType.sym)[outerFieldIndex];
        auto structType = outerField.type.toBasetype.isTypeStruct;
        if (structType is null)
            return false;

        const offset = fieldByteOffset(outerField);
        const size = typeByteSize(outerField.type);
        auto nestedCell = NativeStruct.adopt(cell.subRange(offset, size), structType);
        value = readScalar(
            nestedCell.fieldDeclaration(innerFieldIndex).type,
            nestedCell.field(innerFieldIndex),
        );
        return true;
    }

    private Value pointerTargetValue(in Value pointer) {
        if (pointer.isLocalPointer)
            return localPointerTarget(pointer);
        if (!pointer.isPointer) {
            throw new Exception("Expected pointer.");
        }

        Value cellValue;
        if (pointerCellValue(pointer, cellValue))
            return cellValue;

        return pointer.pointerTarget;
    }

    // Promoted-cell readers are an interim boxed-authority path: a local
    // pointer already resolves through its local binding, while a native
    // pointer reads its host address directly. Only the remaining boxed
    // pointer carrier needs the identity maps below.
    private static bool isBoxedPointer(in Value pointer) @safe {
        return pointer.isPointer && !pointer.isLocalPointer && !pointer.isNativePointer;
    }

    private void writePointerTarget(
        imported!"dmd.expression".Expression expression,
        in Value pointer,
        in Value value,
    ) {
        // A native pointer (e.g. into a malloc'd struct like std.stdio.File's
        // Impl): write straight into native memory.
        if (pointer.isNativePointer) {
            storeNativePointerElement(expression.type, pointer, 0, value);
            return;
        }

        if (pointer.isLocalPointer) {
            auto variable = pointer.localPointerId in localPointers;
            if (variable is null)
                throw new Exception("Unsupported interpreter pointer target.");

            // Cell-then-mirror: this write is
            // always at `variable`'s own storage type (an atomic op or a
            // `(*p)++`/`+=` write-back), never a differently-typed
            // reinterpret write, so `writeCelledLocal` applies directly.
            writeCelledLocal(*variable, storageValue((*variable).type, value));
            return;
        }

        if (writeThroughPromotedPointer(pointer, value))
            return;

        if (auto address = expression.isAddrExp) {
            writeLocation(address.e1, value);
            return;
        }

        if (auto cast_ = expression.isCastExp) {
            writePointerTarget(cast_.e1, pointer, value);
            return;
        }

        writeLocation(expression, pointer.withPointerTarget(value));
    }

    // The single ordered route through promoted boxed-pointer writes. Direct
    // dereference and compound-assignment/atomic write-back use this gate, so
    // they cannot update different interim authorities.
    private bool writeThroughPromotedPointer(in Value pointer, in Value value) {
        return writeThroughArrayPointer(pointer, value) ||
            writeThroughStructFieldPointer(pointer, value) ||
            writeThroughStructArrayFieldPointer(pointer, value) ||
            writeThroughNestedStructFieldPointer(pointer, value) ||
            writeThroughClassFieldPointer(pointer, value) ||
            writeThroughNestedClassStructFieldPointer(pointer, value) ||
            writeThroughClassArrayFieldPointer(pointer, value);
    }

    private void writePointerElements(
        imported!"dmd.expression".Expression expression,
        in Value pointer,
        in Value[] values,
    ) {
        if (auto cast_ = expression.isCastExp) {
            writePointerElements(cast_.e1, pointer, values);
            return;
        }

        writeLocation(expression, pointer.withPointerElements(values));
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

    private Value runNewExpression(imported!"dmd.expression".NewExp new_) {
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
            lengths ~= cast(size_t) runExpression(argument).asLong;

        return newArrayValue(new_.type, lengths);
    }

    private Value runNewScalarPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        if (new_.member !is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        auto targetType = new_.type.toBasetype.nextOf;
        Value value = defaultValue(targetType);
        if (new_.arguments !is null) {
            if (new_.arguments.length != 1)
                throw new Exception(text("Unsupported eval expression: ", new_.op));

            value = runExpression((*new_.arguments)[0]);
        }

        return Value.arrayPointerValue([value], ++allocationCount, 0);
    }

    // Handles `new T(args)` where T is a struct type, returning a `T*` value.
    // When new_.member is null (no user-defined constructor) the arguments are
    // used as positional aggregate field initialisers.  When new_.member is a
    // constructor the constructor body is executed with a default-initialised
    // receiver and the post-construction `this` value is used.
    private Value runNewStructPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto targetType = new_.type.toBasetype.nextOf;
        Value structVal = defaultValue(targetType);

        if (new_.member !is null) {
            import quickbite.frontend.dmd.functions: hasNoAvailableSource;

            // A body-less native constructor cannot have its (null) body run;
            // route it through the FFI bridge so the heap struct is constructed
            // natively instead of left default-initialised (ffi.md §34.13).
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
            Value[] arguments;
            if (new_.arguments !is null)
                foreach (argument; *new_.arguments)
                    arguments ~= runExpression(argument);

            Walker child;
            child.runningCalledFunction = true;
            child.currentFunction = new_.member;
            auto layout = cachedFrameLayout(new_.member);
            child._activationFrame = FrameBlock.allocate(layout);
            child.result = Value(false);
            child.thisValue = structVal;
            child.hasThis = true;
            forkPerFrameCellsInto(child);
            child.bindFunctionParameters(new_.member, arguments);
            try {
                child.runStatement(new_.member.fbody);
            } catch (InterpretedException exception) {
                mergeNewStructConstructorState(child);
                throw exception;
            }
            structVal = child.thisValue;
            mergeNewStructConstructorState(child);
        } else if (new_.arguments !is null) {
            // Aggregate initialiser: assign arguments positionally to fields.
            import quickbite.backends.interpreter.layout: structFields;

            auto structType = targetType.isTypeStruct;
            foreach (index, argument; *new_.arguments) {
                if (index >= structFields(structType).length)
                    throw new Exception(text(
                        "Unsupported eval expression: ", new_.op,
                    ));
                structVal = AggregateValue.withStructField(structVal,
                    index,
                    runExpression(argument),
                );
            }
        }

        // A fresh allocation id (mirroring runNewScalarPointerExpression and the
        // AddrExp(DotVarExp) fresh-identity fix) so two `new`-allocated structs
        // with equal field contents compare as distinct pointers, matching real
        // heap addresses; `Value.pointerValue` alone leaves allocation/offset at
        // their zero default, so unrelated `new` results collide on identity.
        return Value.arrayPointerValue([structVal], ++allocationCount, 0);
    }

    // `runNewStructPointerExpression`'s own constructor-call merge, the heap
    // struct sibling of `mergeNewClassExpressionState` and shared with its
    // `InterpretedException` path for the same reason: `nextClassObjectId`
    // only ever advances on the CHILD, so a constructor that mints a class
    // identity and then throws a guest exception the caller catches leaves
    // this activation free to re-mint an identity the child already handed
    // out, and `object_table.ObjectTable.storageFor` throws outright the
    // moment the two objects sharing it disagree on size.
    //
    // `writeBackGlobals` belongs here for the same reason it belongs in
    // every other call site's write-back: a dataseg variable the
    // constructor assigns to lands in the ONE `module_table.ModuleTable`
    // block every frame resolves through (`forkPerFrameCellsInto` shares it
    // by pointer), so leaving this activation's boxed copy at the pre-call
    // value does not merely answer staler -- the next read of that global
    // compares the two and asserts.
    private void mergeNewStructConstructorState(ref Walker child) {
        nextClassObjectId = child.nextClassObjectId;
        mergePerFrameCellsFrom(child);
        writeBackGlobals(child);
    }

    // `new T(args)` where T's constructor is a body-less native leaf: construct
    // the struct through the FFI bridge (seeding `this` from `.init`) and return
    // a pointer to the constructed value (ffi.md §34.13).
    private Value runNewStructNativeConstructor(
        imported!"dmd.expression".NewExp new_,
        imported!"dmd.mtype".Type targetType,
        in Value initValue,
    ) {
        import quickbite.frontend.dmd.functions: noAvailableSourceMessage;
        import quickbite.backends.interpreter.ffi_marshal:
            NativeCallException, tryCallNativeConstructor;
        import dmd.expression: Expression;

        Value[] arguments;
        Expression[] argumentExpressions;
        if (new_.arguments !is null)
            foreach (argument; *new_.arguments) {
                arguments ~= runExpression(argument);
                argumentExpressions ~= argument;
            }

        Value constructed;
        Value[] writebacks;
        try {
            if (tryCallNativeConstructor(
                new_.member,
                targetType.isTypeStruct,
                nativeConstructorReceiver(new_.member, initValue),
                arguments,
                nativeArgumentTypes(argumentExpressions),
                nativeAddressOfLocalArguments(argumentExpressions),
                constructed,
                writebacks,
            )) {
                applyNativeWritebacks(writebacks, argumentExpressions);
                return Value.pointerValue(constructed);
            }
        } catch (NativeCallException exception) {
            throwNativeException(exception);
        }

        throw new Exception(noAvailableSourceMessage(new_.member));
    }

    private Value runNewClassExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto allocationType = new_.newtype is null ? new_.type : new_.newtype;
        auto classType = allocationType.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        Value[] arguments;
        if (new_.arguments !is null)
            foreach (argument; *new_.arguments)
                arguments ~= runExpression(argument);

        auto object = classDefaultValue(classType.sym, ++nextClassObjectId);
        if (new_.member is null)
            return object;

        if (isThrowableConstructor(new_.member))
            return applyThrowableConstructor(object, arguments);

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
        child.result = Value(false);
        child.locals = locals.dup;
        forkPerFrameCellsInto(child);
        child.thisValue = object;
        child.hasThis = true;
        child.bindFunctionParameters(new_.member, arguments);
        try {
            child.runStatement(new_.member.fbody);
        } catch (InterpretedException exception) {
            mergeNewClassExpressionState(child);
            throw exception;
        }
        mergeNewClassExpressionState(child);
        return child.thisValue;
    }

    // `runNewClassExpression`'s own constructor-call merge, shared between
    // its success path and its `InterpretedException` (guest-level throw
    // during construction) path: `nextClassObjectId` (and every other
    // counter/map merged here) is only ever advanced on the CHILD `Walker`
    // constructing the object, so a merge that runs on the success path
    // only leaves this activation's own copy stale whenever the
    // constructor's body throws a guest exception instead of returning --
    // silently re-minting an identity `child` already handed out (`object`,
    // this function's own top-level identity, or one a nested `new`
    // allocated during construction) the NEXT time this activation mints
    // one. Two different objects then share one `object_table.ObjectTable`
    // identity: harmless aliasing in the boxed maps alone, but
    // `ObjectTable.storageFor` throws outright the moment the two
    // instances disagree on size (its own defense-in-depth check, see
    // `value.md`'s class-mirror contract).
    //
    // `writeBackGlobals` is here for the reason
    // `mergeNewStructConstructorState`'s own header gives: the constructor
    // body runs on a child sharing this activation's ONE
    // `module_table.ModuleTable` block by pointer, so a dataseg variable it
    // assigns to is already written in the shared mirror, and leaving this
    // activation's boxed copy at the pre-call value makes the next read of
    // that global assert on the divergence rather than merely answer
    // staler.
    private void mergeNewClassExpressionState(ref Walker child) {
        nextLocalPointerId = child.nextLocalPointerId;
        nextFunctionPointerId = child.nextFunctionPointerId;
        nextClassObjectId = child.nextClassObjectId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        lazyArgumentFrames = child.lazyArgumentFrames;
        mergePerFrameCellsFrom(child);
        writeBackGlobals(child);
    }

    private Value newArrayValue(
        imported!"dmd.mtype".Type type,
        in size_t[] lengths,
    ) {
        import dmd.tokens: EXP;
        import quickbite.frontend.dmd.types: arrayElementType;
        import std.conv: text;

        // `auto` because DMD returns a mutable class reference
        auto elementType = arrayElementType(type);
        if (elementType is null)
            throw new Exception(text("Unsupported eval expression: ", EXP.new_));

        Value[] elements;
        foreach (_; 0 .. lengths[0])
            elements ~= lengths.length > 1
                ? newArrayValue(elementType, lengths[1 .. $])
                : defaultValue(elementType);

        return Value.arrayValue(elements);
    }

    private void recordSliceAlias(
        VarDeclaration variable,
        imported!"dmd.expression".SliceExp slice,
        in size_t lower,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        // pointer slices snapshot the allocation; they do not alias a local
        if (isPointerType(slice.e1.type)) {
            sliceAliases.remove(variable);
            return;
        }

        // `foreach (ref e; val.field)` lowers to `T[] tmp = val.field[];`
        // (dmd's own foreach-to-for rewrite): the sliced aggregate is a
        // struct field (a `DotVarExp`), not a plain local. Track the
        // field's owner and index so the write-through below can rebuild
        // `val.field[...]`, not a nonexistent whole-array local.
        if (auto dot = slice.e1.isDotVarExp) {
            auto var = dot.e1.isVarExp;
            auto source = var is null ? null : var.var.isVarDeclaration;
            if (source is null) {
                sliceAliases.remove(variable);
                return;
            }

            // Class sibling of the struct-field shape above (foreach-ref
            // over a class static-array field):
            // `structFieldIndex(dot)` requires `receiverStructType`, which
            // is null for a class receiver and throws "Unsupported
            // interpreter field access." immediately here, before any
            // write -- this shape was entirely unsupported. Dispatch on the
            // STATIC receiver type (`receiverClassType`), mirroring
            // `writeIndexLocation`'s own `DotVarExp` arm.
            const isClassField = receiverClassType(dot.e1) !is null;
            sliceAliases[variable] = SliceAlias(
                source,
                lower,
                true,
                isClassField ? classFieldIndex(dot) : structFieldIndex(dot),
                isClassField,
            );
            return;
        }

        auto var = slice.e1.isVarExp;
        if (var is null) {
            sliceAliases.remove(variable);
            return;
        }

        auto source = var.var.isVarDeclaration;
        if (source is null) {
            sliceAliases.remove(variable);
            return;
        }

        if (auto alias_ = source in sliceAliases)
            sliceAliases[variable] = SliceAlias(
                alias_.source,
                alias_.lower + lower,
            );
        else
            sliceAliases[variable] = SliceAlias(source, lower);
    }

    private void writeThroughSliceAlias(
        VarDeclaration variable,
        in size_t index,
        in Value value,
    ) {
        auto alias_ = variable in sliceAliases;
        if (alias_ is null)
            return;

        // A still-void static array (e.g. a `ref` parameter bound to the
        // caller's `T val = void;`) leaves the source's
        // `locals` entry holding the bare `Value.void_` placeholder rather
        // than a real `Array`/`Struct` — `val[]`'s `foreach (ref e; val)`
        // lowering slices it into a temporary, and a write through the
        // temporary reaches here to rebuild `val`. Materialise the default
        // value first, mirroring the read-path materialisation
        // `runExpression`'s VarExp branch already applies to a directly
        // uninitialized local, so the write has real storage to land in.
        if (alias_.source in uninitializedLocals)
            setLocal(alias_.source, defaultValue(alias_.source));

        auto source = alias_.source in locals;
        // A slice argument can name caller storage represented in this child
        // frame only by a shared native array cell. Write directly through
        // that authority when no boxed source mirror was carried across.
        if (source is null && (alias_.source in arrayCells) !is null) {
            writeThroughArrayCell(alias_.source, alias_.lower + index, value);
            return;
        }
        if (source is null)
            throw new Exception("Unsupported interpreter slice assignment target.");

        if (alias_.hasFieldIndex) {
            // Class sibling of the struct-field refresh below (foreach-ref
            // over a class static-array field):
            // `alias_.source` may be a class object (`ClassObject`), whose
            // field must be read/written via `classFieldAt`/
            // `withClassField`, not the struct accessors (`structFieldAt`
            // throws "Expected struct." for a `ClassObject` value).
            // `writeCelledLocal` already dispatches its own refresh on the
            // VALUE's runtime kind (`isStruct`/`isClassObject`), so no
            // change is needed there.
            //
            // `*source` is the plain `locals[alias_.source]` boxed mirror,
            // the same stale-relative-to-a-shared-cell snapshot
            // `writeLocation`'s `DotVarExp` arm used to read -- re-derive an
            // authoritative owner from `alias_.source`'s own `classCells`
            // entry (a no-op when it has none) before folding in this
            // element's write, for exactly the same reason.
            Value authoritativeSource = *source;
            if (alias_.isClassField)
                if (auto cell = alias_.source in classCells) {
                    auto classType = alias_.source.type.toBasetype.isTypeClass;
                    if (classType !is null && classType.sym !is null)
                        authoritativeSource =
                            classValueFromCell(authoritativeSource, *cell, classType.sym);
                }

            const updatedField = AggregateValue.withArrayElement(
                alias_.isClassField
                    ? AggregateValue.classFieldAt(authoritativeSource, alias_.fieldIndex)
                    : AggregateValue.fieldAt(authoritativeSource, alias_.fieldIndex),
                alias_.lower + index,
                value,
            );
            const updatedOwner = alias_.isClassField
                ? AggregateValue.withClassField(authoritativeSource, alias_.fieldIndex, updatedField)
                : AggregateValue.withStructField(authoritativeSource, alias_.fieldIndex, updatedField);
            // Struct-static-array-field foreach-ref case: `alias_.source`
            // (the struct owning the field) may
            // already have a `structCells` entry (an earlier `&s.arr[0]` in
            // the same frame) -- `writeCelledLocal` is the SAME whole-struct
            // refresh a direct `s.arr[i] = v` write reaches via
            // `writeLocation`, so a later deref-read through that cell
            // (`structArrayFieldPointerCellValue`) sees this slice-routed
            // write too instead of stale bytes. A no-op when no cell was
            // ever promoted for `alias_.source`. `classFieldRefresh`
            // (documented above) marks this the same authoritative same-object
            // refresh the `DotVarExp` write arm performs, not a rebind.
            writeCelledLocal(
                alias_.source,
                updatedOwner,
                /* arrayIsRefWriteback */ false,
                /* classFieldRefresh */ true,
            );
            return;
        }

        setLocal(alias_.source, AggregateValue.withArrayElement(
            *source, alias_.lower + index, value));
        // A slice-expression parameter (bound
        // via `recordParameterSliceAlias`, which never calls
        // `promoteSliceArrayCell`) has no `arrayCells` entry of its own, but
        // `alias_.source` -- the slice's origin -- may already have one (an
        // earlier `&a[0]` in the caller). Refresh it too, or a later direct
        // read (`readIndexExpression`'s cell arm, authoritative over the
        // boxed mirror just written above) keeps answering with stale bytes.
        // Mirrors the treatment `writeThroughArrayElementAlias` already
        // gives the `ref`-element-alias sibling; a no-op when no cell was
        // ever promoted for `alias_.source`.
        writeThroughArrayCell(alias_.source, alias_.lower + index, value);
        uninitializedLocals.remove(alias_.source);
    }

    private void writeThroughThisStructArrayFieldAlias(
        in size_t fieldIndex,
        in size_t index,
        in Value value,
    ) {
        auto sourceVariable = fieldIndex in thisStructArrayFieldAliases.sources;
        if (sourceVariable is null)
            return;

        auto source = *sourceVariable in locals;
        if (source is null)
            throw new Exception("Unsupported interpreter struct field alias target.");

        setLocal(*sourceVariable, AggregateValue.withArrayElement(*source, index, value));
        // Once `sourceVariable` has a
        // promoted `arrayCells` entry (needing no address-of at all --
        // `foreach (v; a)` promotes it via `promoteSliceArrayCell`), a
        // member-function write to the same array reached through a struct
        // field must also refresh the cell, or a cell-authoritative index
        // read (`runIndexExpression`) keeps answering with stale bytes. This
        // runs in the callee's child `Walker` frame, whose `arrayCells` was
        // duped from the caller (`child.arrayCells = arrayCells.dup`) and
        // shares the same underlying `NativeArray` bytes by reference, so
        // the caller sees the refreshed cell with no separate write-back.
        // Mirrors every other `arrayCells` write-through call site; a no-op
        // when no cell was ever promoted for `sourceVariable`.
        writeThroughArrayCell(*sourceVariable, index, value);
        uninitializedLocals.remove(*sourceVariable);
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(false);

        // A fresh declaration is a new stack slot: drop any inherited/stale
        // `scalarCells`/`arrayCells`/`structCells`/`classCells` entry for it
        // before writing `locals` below, or a later `&variable` would
        // resurrect a prior instance's promoted cell instead of getting a
        // correct fresh one (an earlier version dropped only `scalarCells`,
        // missing the `arrayCells`/`structCells` maps added later;
        // `dropClassCell` closes the same gap for `classCells`, added later
        // still). Recursion reuses the same `VarDeclaration` AST node at
        // every call depth, and duping each of `scalarCells`/`arrayCells`/
        // `structCells`/`classCells` into a `child` `Walker` hands a fresh
        // call frame the outer frame's already-promoted cell (sharing its
        // underlying bytes by reference); a loop body re-executes the same
        // `DeclarationExp` every iteration and hits the same issue without
        // recursion at all -- including a nested `foreach`'s per-iteration
        // slice temporary, whose source array is promoted eagerly by
        // `promoteSliceArrayCell` with no address-of needed at all.
        dropDeclarationCells(variable);

        if (variable._init !is null && variable._init.isVoidInitializer !is null) {
            uninitializedLocals[variable] = true;
            return Value.void_;
        }

        if (variable._init is null || variable._init.isExpInitializer is null) {
            const value = defaultLocalValue(variable);
            setLocal(variable, value);
            structArrayFieldAliases.remove(variable);
            structFieldAliases.remove(variable);
            return value;
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
                const value = defaultValue(variable);
                setLocal(variable, value);
                uninitializedLocals.remove(variable);
                sliceAliases.remove(variable);
                structArrayFieldAliases.remove(variable);
                structFieldAliases.remove(variable);
                return value;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                const value = defaultValue(variable);
                setLocal(variable, value);
                uninitializedLocals.remove(variable);
                sliceAliases.remove(variable);
                structArrayFieldAliases.remove(variable);
                structFieldAliases.remove(variable);
                return value;
            }

            initializer = blit.e2;
        }

        if (initializer.isVoidInitExp !is null) {
            uninitializedLocals[variable] = true;
            return Value.void_;
        }

        // `auto copy = original;` for a struct with a postblit lowers to
        // `(copy = original).__postblit()` as the initializer: the blit inside
        // the call writes the variable, and the call's own value is the
        // postblit's return, not the struct — do not overwrite with it.
        if (auto postblitCall = initializer.isCallExp)
            if (
                postblitCall.f !is null &&
                postblitCall.f.isPostBlitDeclaration !is null
            ) {
                // An interpreted postblit returns void (its walker's
                // incidental result must not overwrite the variable); a
                // body-less native postblit's FFI bridge returns the mutated
                // receiver, which is the value to keep.
                const result = runExpression(initializer);
                uninitializedLocals.remove(variable);
                if (result.isStruct) {
                    setLocal(variable, result);
                    return result;
                }
                if (auto value = variable in locals)
                    return *value;
                return defaultValue(variable);
            }

        import quickbite.frontend.dmd.types: isAssocArrayType, isDynamicArrayType;

        if (initializer.isNullExp !is null && isDynamicArrayType(variable.type)) {
            auto value = Value.arrayValue([]);
            setLocal(variable, value);
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            structArrayFieldAliases.remove(variable);
            structFieldAliases.remove(variable);
            return value;
        }

        if (initializer.isNullExp !is null && isAssocArrayType(variable.type)) {
            auto value = Value.assocArrayValue([], []);
            setLocal(variable, value);
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            structArrayFieldAliases.remove(variable);
            structFieldAliases.remove(variable);
            return value;
        }

        if (auto slice = initializer.isSliceExp) {
            size_t lower;
            auto value = runSliceExpression(slice, lower);
            setLocal(variable, value);
            uninitializedLocals.remove(variable);
            arrayElementAliases.remove(variable);
            recordSliceAlias(variable, slice, lower);
            promoteSliceArrayCell(variable);
            structArrayFieldAliases.remove(variable);
            structFieldAliases.remove(variable);
            return value;
        }

        auto indexInitializer = initializer.isIndexExp;
        const isArrayElementAlias = isRefVariable(variable) &&
            indexInitializer !is null;
        auto dotInitializer = initializer.isDotVarExp;
        const isStructFieldAlias = isRefVariable(variable) &&
            dotInitializer !is null;
        size_t arrayElementAliasIndex;
        Value nativeFieldAliasValue;
        bool hasNativeFieldAlias;
        if (
            isRefVariable(variable) &&
            dotInitializer !is null &&
            dotInitializer.e1.isIndexExp !is null
        ) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.layout: typeByteSize;
            import quickbite.backends.interpreter.native_scalar:
                isNativeScalarType, readScalar;

            if (isNativeScalarType(variable.type)) {
                const pointer = addressOfExpression(dotInitializer, EXP.address);
                if (pointer.isNativePointer) {
                    // Mutable because both the scalar reader and the map
                    // retain the borrowed byte-range view by mutable value.
                    auto cell = NativeBlock.borrow(
                        pointer.asNativePointer,
                        typeByteSize(variable.type),
                    );
                    nativeFieldAliasValue = readScalar(variable.type, cell.bytes);
                    scalarCells[variable] = cell;
                    hasNativeFieldAlias = true;
                }
            }
        }
        auto literal = initializer.isFuncExp;
        auto value = storageValue(
            variable.type,
            hasNativeFieldAlias
                ? nativeFieldAliasValue
                : literal !is null
                ? runFunctionLiteralDeclaration(literal)
                : isArrayElementAlias
                ? runIndexExpression(indexInitializer, arrayElementAliasIndex)
                : runExpression(initializer),
        );
        setLocal(variable, value);
        bindScalarArrayCastView(variable, initializer);
        registerClassAliasIfPlainVar(variable, initializer);
        // A plain `ref` aggregate local denotes `source`'s storage, so share
        // the existing aggregate-cell and local-pointer mechanisms rather
        // than retain a boxed snapshot and distinct address under the alias
        // declaration's AST node.
        if (isRefVariable(variable)) {
            auto sourceVar = initializer.isVarExp;
            auto source = sourceVar is null
                ? null
                : sourceVar.var.isVarDeclaration;
            if (source !is null) {
                const baseType = variable.type.toBasetype;
                if (baseType.isTypeStruct !is null) {
                    promoteStructCell(source);
                    if (auto cell = source in structCells)
                        structCells[variable] = *cell;
                }
                if (
                    baseType.isTypeStruct !is null ||
                    baseType.isTypeClass !is null ||
                    baseType.isTypeSArray !is null
                )
                    localPointerIds[variable] =
                        localPointerValue(source).localPointerId;
            }
        }
        bindArrayValueCell(variable, value);
        uninitializedLocals.remove(variable);
        if (isArrayElementAlias)
            recordArrayElementAlias(variable, indexInitializer, arrayElementAliasIndex);
        else if (isStructFieldAlias)
            recordStructFieldAlias(variable, dotInitializer);
        else {
            arrayElementAliases.remove(variable);
            structFieldAliases.remove(variable);
            sliceAliases.remove(variable);
        }
        recordStructArrayFieldAliases(variable, initializer);
        recordAssocArraySlotAlias(variable, initializer);
        return value;
    }

    // A same-width scalar dynamic-array cast changes only the element type
    // used to interpret the bytes. Give the destination and source locals
    // differently typed views over one NativeArray block so writes through
    // either binding remain visible through the other.
    private void bindScalarArrayCastView(
        VarDeclaration variable,
        imported!"dmd.expression".Expression initializer,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        auto cast_ = initializer.isCastExp;
        if (cast_ is null)
            return;

        auto sourceExpression = cast_.e1;
        auto sourceVar = sourceExpression.isVarExp;
        auto source = sourceVar is null
            ? null
            : sourceVar.var.isVarDeclaration;
        if (source is null)
            return;

        auto sourceType = sourceExpression.type.toBasetype;
        auto targetType = variable.type.toBasetype;
        if (!isDynamicArrayType(sourceType) || !isDynamicArrayType(targetType))
            return;

        sourceType = sourceType.nextOf.toBasetype;
        targetType = targetType.nextOf.toBasetype;
        if (
            !isNativeScalarType(sourceType) ||
            !isNativeScalarType(targetType) ||
            typeByteSize(sourceType) != typeByteSize(targetType)
        )
            return;

        promoteArrayCell(source);
        auto sourceCell = source in arrayCells;
        if (sourceCell is null)
            return;

        arrayCells[variable] = sourceCell.reinterpretElements(targetType);
    }

    private Value defaultLocalValue(VarDeclaration variable) {
        import quickbite.frontend.dmd.types: isAssocArrayType;

        if (isAssocArrayType(variable.type))
            return Value.assocArrayValue([], []);

        return defaultValue(variable);
    }

    private void recordStructArrayFieldAliases(
        VarDeclaration variable,
        imported!"dmd.expression".Expression initializer,
    ) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        auto literal = initializer.isStructLiteralExp;
        if (literal is null || literal.elements is null) {
            structArrayFieldAliases.remove(variable);
            return;
        }

        StructArrayFieldAliases aliases;
        foreach (index, element; *literal.elements) {
            if (element is null)
                continue;

            auto var = element.isVarExp;
            if (var is null)
                continue;

            auto source = var.var.isVarDeclaration;
            if (source is null)
                continue;

            if (!isDynamicArrayType(source.type))
                continue;

            aliases.sources[index] = source;
        }

        if (aliases.sources.length == 0)
            structArrayFieldAliases.remove(variable);
        else
            structArrayFieldAliases[variable] = aliases;
    }

    private void recordArrayElementAlias(
        VarDeclaration variable,
        imported!"dmd.expression".IndexExp index,
        in size_t arrayIndex,
    ) {
        auto var = index.e1.isVarExp;
        if (var is null) {
            arrayElementAliases.remove(variable);
            return;
        }

        auto source = var.var.isVarDeclaration;
        if (source is null) {
            arrayElementAliases.remove(variable);
            return;
        }

        arrayElementAliases[variable] = ArrayElementAlias(
            source,
            arrayIndex,
        );
    }

    private void writeThroughArrayElementAlias(
        VarDeclaration variable,
        in Value value,
    ) {
        auto alias_ = variable in arrayElementAliases;
        if (alias_ is null)
            return;

        auto source = alias_.source in locals;
        if (source is null)
            throw new Exception("Unsupported interpreter array element alias target.");

        setLocal(alias_.source, AggregateValue.withArrayElement(
            *source, alias_.index, value));
        auto sliceAlias = alias_.source in sliceAliases;
        if (sliceAlias is null || (sliceAlias.source in locals) !is null)
            writeThroughSliceAlias(alias_.source, alias_.index, value);
        // A write through a `ref` element alias (e.g. `foreach (ref e; a)
        // e = ...;`, lowered by dmd to `ref e = __r[__key];`) must also
        // refresh `alias_.source`'s promoted `arrayCells` entry, the same
        // way a direct element write (`writeIndexLocation`) and a write
        // through a pointer (`writeThroughArrayPointer`) already do -- or an
        // earlier-taken pointer into the same element (which consults the
        // cell first, `runPointerExpression`) would keep reading stale
        // bytes. A no-op when no cell was ever promoted for `alias_.source`.
        writeThroughArrayCell(alias_.source, alias_.index, value);
        uninitializedLocals.remove(alias_.source);
    }

    private void recordStructFieldAlias(
        VarDeclaration variable,
        imported!"dmd.expression".DotVarExp dot,
    ) {
        auto var = dot.e1.isVarExp;
        if (var is null) {
            structFieldAliases.remove(variable);
            return;
        }

        auto source = var.var.isVarDeclaration;
        if (source is null) {
            structFieldAliases.remove(variable);
            return;
        }

        const isClass = receiverClassType(dot.e1) !is null;
        structFieldAliases[variable] = StructFieldAlias(
            source,
            isClass ? classFieldIndex(dot) : structFieldIndex(dot),
            isClass,
        );
    }

    private void writeThroughStructFieldAlias(
        VarDeclaration variable,
        in Value value,
    ) {
        auto alias_ = variable in structFieldAliases;
        if (alias_ is null)
            return;

        auto source = alias_.source in locals;
        auto structCell = alias_.source in structCells;
        auto classCell = alias_.source in classCells;
        if (source is null && structCell is null && classCell is null)
            throw new Exception(
                "Unsupported interpreter aggregate field alias target.",
            );

        if (source !is null)
            setLocal(alias_.source, alias_.isClass
                ? AggregateValue.withClassField(*source, alias_.index, value)
                : AggregateValue.withStructField(*source, alias_.index, value));
        // A `ref` local bound directly to an
        // aggregate field (`ref int r = s.x;`, recorded via
        // `recordStructFieldAlias`) must also refresh `alias_.source`'s
        // promoted aggregate cell, if one exists (an earlier `&s.x`),
        // or a later read through that pointer
        // (`pointerTargetValue` and its field-cell readers, authoritative
        // over the boxed mirror just re-derived above) keeps answering with
        // stale bytes. Mirrors `writeThroughArrayCell`'s treatment of the
        // array sibling. A no-op when no cell was ever promoted for
        // `alias_.source`.
        //
        // `recordStructFieldAlias` records any `DotVarExp` initializer,
        // including array and nested-struct fields. Refresh the whole cell from
        // the rebuilt boxed owner so dynamic-array headers stay coherent too.
        // If no boxed owner exists, retain the narrow scalar-only fallback.
        if (structCell !is null && source !is null) {
            writeStructCellScalarFields(*structCell, locals[alias_.source]);
        } else if (structCell !is null) {
            import quickbite.backends.interpreter.native_scalar:
                isNativeScalarType, writeScalar;

            auto fieldType = structCell.fieldDeclaration(alias_.index).type;
            if (isNativeScalarType(fieldType))
                writeScalar(fieldType, structCell.field(alias_.index), value);
        } else if (classCell !is null) {
            import quickbite.backends.interpreter.layout:
                classFields, fieldByteOffset, typeByteSize;
            import quickbite.backends.interpreter.native_scalar:
                isNativeScalarType, writeScalar;

            auto classType = alias_.source.type.toBasetype.isTypeClass;
            if (classType !is null && classType.sym !is null) {
                auto field = classFields(classType.sym)[alias_.index];
                if (isNativeScalarType(field.type)) {
                    const offset = fieldByteOffset(field);
                    const size = typeByteSize(field.type);
                    writeScalar(
                        field.type,
                        classCell.bytes[offset .. offset + size],
                        value,
                    );
                }
            }
        }
        uninitializedLocals.remove(alias_.source);
    }

    private bool isRefVariable(VarDeclaration variable) const {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.ref_) != STC.none;
    }

    private void recordAssocArraySlotAlias(
        VarDeclaration variable,
        imported!"dmd.expression".Expression initializer,
    ) {
        import quickbite.backends.interpreter.builtins:
            AssocArrayHook, tryAssocArrayHook;

        assocArraySlotAliases.remove(variable);

        auto call = initializer.isCallExp;
        if (call is null || call.f is null || call.arguments is null ||
            call.arguments.length != 3)
            return;

        AssocArrayHook hook;
        if (!tryAssocArrayHook(call.f, hook) || hook != AssocArrayHook.getLvalue)
            return;

        auto var = (*call.arguments)[0].isVarExp;
        if (var is null)
            return;

        auto source = var.var.isVarDeclaration;
        if (source is null)
            return;

        assocArraySlotAliases[variable] = AssocArraySlotAlias(
            source,
            runExpression((*call.arguments)[1]),
        );
    }

    private Value runPostIncrementExpression(
        imported!"dmd.expression".PostExp post,
    ) {
        import dmd.tokens: EXP;

        const delta = post.op == EXP.plusPlus
            ? Value(cast(int) 1)
            : post.op == EXP.minusMinus
                ? Value(cast(int) -1)
                : Value.void_;
        if (delta == Value.void_)
            throw new Exception("Unsupported eval post expression.");

        if (auto var = post.e1.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported eval post expression target.");

            // `readCelledLocal`: a plain
            // `variable in locals` lookup here bypassed a promoted
            // `scalarCells` entry, reading stale bytes once a cross-frame
            // pointer write refreshed only the cell.
            const oldValue = readCelledLocal(variable);
            if (oldValue.isPointer) {
                writeLocation(post.e1, oldValue.pointerOffsetBy(delta.asLong));
                return oldValue;
            }
            writeLocation(post.e1, oldValue + delta);
            return oldValue;
        }

        if (post.e1.isDotVarExp !is null) {
            const oldValue = runExpression(post.e1);
            writeLocation(post.e1, oldValue + delta);
            return oldValue;
        }

        if (post.e1.isIndexExp !is null) {
            const oldValue = runExpression(post.e1);
            writeLocation(post.e1, oldValue + delta);
            return oldValue;
        }

        if (auto pointer = post.e1.isPtrExp) {
            const target = runExpression(pointer.e1);
            const oldValue = pointerTargetValue(target);
            writePointerTarget(pointer.e1, target, oldValue + delta);
            return oldValue;
        }

        throw new Exception("Unsupported eval post expression target.");
    }

    private Value runAddAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (!runExpression(assign.e1).isLocalPointer)
            return runCompoundAssignExpression(assign);

        const left = runExpression(assign.e1);
        const right = runExpression(assign.e2);
        if (left.isLocalPointer) {
            const value = localPointerTarget(left) + right;
            writePointerTarget(assign.e1, left, value);
            return value;
        }

        const value = left.isPointer
            ? left.pointerOffsetBy(pointerElementOffset(assign.e1.type, right.asLong))
            : left + right;
        writeLocation(assign.e1, value);
        return value;
    }
}


private imported!"dmd.mtype".TypeStruct receiverStructType(
    imported!"dmd.expression".Expression receiver,
) {
    if (receiver.type is null)
        return null;

    return receiver.type.toBasetype.isTypeStruct;
}


private bool isTruthy(in imported!"quickbite.backends.interpreter.runtime_value".Value value) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    if (value == Value.null_)
        return false;

    if (value.isPointer)
        return true;

    if (AggregateValue.isArray(value))
        return AggregateValue.length(value) != 0;

    if (value == Value(false))
        return false;

    if (value == Value(true))
        return true;

    return value.castTo!bool == Value(true);
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
private imported!"quickbite.backends.interpreter.runtime_value".Value nativeConstructorReceiver(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.backends.interpreter.runtime_value".Value receiver,
) {
    import quickbite.backends.interpreter.runtime_values: defaultValue;

    auto structDecl = function_.parent is null
        ? null
        : function_.parent.isStructDeclaration;
    return structDecl !is null ? defaultValue(structDecl.type) : receiver;
}


private imported!"quickbite.backends.interpreter.runtime_value".Value classDefaultValue(
    imported!"dmd.dclass".ClassDeclaration class_,
    in size_t identity = 0,
) {
    import quickbite.backends.interpreter.runtime_values: defaultValue;
    import quickbite.backends.interpreter.runtime_value: Value;
    import quickbite.backends.interpreter.layout: classFields;

    string[] fieldNames;
    Value[] fields;
    foreach (field; classFields(class_)) {
        fieldNames ~= variableName(field);
        fields ~= defaultValue(field.type);
    }

    return Value.classValue(
        classInfoName(class_),
        classTypeNames(class_),
        fieldNames,
        fields,
        identity,
    );
}


// The call site's actual argument types, in source order, so the FFI core can
// type a C variadic call's trailing arguments (the signature carries only the
// fixed parameters, ffi.md §34.14).
private imported!"dmd.mtype".Type[] nativeArgumentTypes(
    imported!"dmd.expression".Expression[] expressions,
) {
    import dmd.mtype: Type;

    Type[] types;
    foreach (expression; expressions)
        types ~= expression.type;

    return types;
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

    return class_.vtbl[index].isFuncDeclaration;
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

    if (
        candidate.type !is null &&
        base.type !is null &&
        candidate.type.equals(base.type)
    )
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


private imported!"dmd.dclass".ClassDeclaration classDeclarationByNameInScope(
    imported!"dmd.dsymbol".ScopeDsymbol scope_,
    in string name,
) {
    import dmd.dsymbol: foreachDsymbol;

    imported!"dmd.dclass".ClassDeclaration found;
    foreachDsymbol(scope_.members, (symbol) {
        if (auto class_ = symbol.isClassDeclaration) {
            if (className(class_) == name || classInfoName(class_) == name) {
                found = class_;
                return 1;
            }
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


private string[] nativeExceptionTypeNames(in string name) @safe pure {
    const root = nativeExceptionRoot(name);
    return [
        unqualifiedName(name),
        name,
        root,
        "Throwable",
        "Object",
        "object." ~ root,
        "object.Throwable",
        "object.Object",
    ];
}

private string nativeExceptionRoot(in string name) @safe pure {
    import std.algorithm: endsWith, startsWith;

    return (
        (
            name.startsWith("core.exception.") ||
            name.startsWith("object.")
        ) &&
        name.endsWith("Error")
    )
        ? "Error"
        : "Exception";
}


private string unqualifiedName(in string name) @safe pure {
    import std.string: lastIndexOf;

    const index = name.lastIndexOf('.');
    return index == -1 ? name : name[index + 1 .. $];
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


private string typeInfoName(imported!"dmd.mtype".Type type) {
    if (type is null)
        return "";

    auto classType = type.toBasetype.isTypeClass;
    if (classType !is null && classType.sym !is null)
        return classInfoName(classType.sym);

    return typeChars(type);
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


// @trusted: under `-boundscheck=off` (the optimised benchmark build) dmd's
// `Array.opIndex` is `@system` — it returns `data.ptr[i]` with no bounds check,
// so it is only `@safe`-inferred when bounds checks are on. The guard above
// validates `index` against `fields.length`, so the access is in bounds.
private imported!"dmd.declaration".VarDeclaration structLiteralField(
    imported!"dmd.expression".StructLiteralExp literal,
    in size_t index,
) @trusted {
    if (literal.sd is null || index >= literal.sd.fields.length)
        return null;

    return literal.sd.fields[index];
}


// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string expressionChars(imported!"dmd.expression".Expression expression) @trusted {
    import std.string: fromStringz;

    return expression.toChars.fromStringz.idup;
}

// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string owned by the AST node, which we copy with `idup` before returning,
// so no unsafe pointer escapes.
private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return type.toChars.fromStringz.idup;
}

// @trusted: `toChars` is not `@safe`; it returns a valid null-terminated C
// string for the lifetime of the DMD function declaration.
private string functionName(imported!"dmd.func".FuncDeclaration function_) @trusted {
    import std.string: fromStringz;

    return function_.toChars.fromStringz.idup;
}

private struct SliceAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t lower;
    // Set when the sliced aggregate is itself a struct field of `source`
    // (e.g. `T[] tmp = val.field[];`, dmd's `foreach (ref e; val.field)`
    // lowering) rather than `source` directly.
    public bool hasFieldIndex;
    public size_t fieldIndex;
    // Set alongside `hasFieldIndex` when `source` is a class object rather
    // than a struct (foreach-ref over a class static-array field):
    // `fieldIndex` must then be read/written via
    // `classFieldAt`/`withClassField`, not the struct accessors.
    public bool isClassField;
}


private struct StructArrayFieldAliases {
    public imported!"dmd.declaration".VarDeclaration[size_t] sources;
}


private struct AssocArraySlotAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public imported!"quickbite.backends.interpreter.runtime_value".Value key;
}


private struct RuntimeDelegate {
    public imported!"dmd.func".FuncDeclaration function_;
    public size_t functionPointerId;
    public imported!"quickbite.backends.interpreter.runtime_value".Value contextPointer;
    public imported!"quickbite.backends.interpreter.runtime_value".Value receiver;
    public bool hasReceiver;
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


private string declarationName(
    imported!"dmd.declaration".Declaration declaration,
) @safe {
    return declaration.ident is null ? "" : declaration.ident.toString.idup;
}


private void log(A...)(auto ref A args) {
    version(unittest) {
        import unit_threaded;
        writelnUt(args);
    }
}

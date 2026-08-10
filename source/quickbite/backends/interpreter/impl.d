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
        try {
            import quickbite.backends.interpreter.frame_layout:
                clearFrameLayoutCache;

            clearFrameLayoutCache;
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
            import quickbite.backends.interpreter.frame_layout:
                clearFrameLayoutCache;

            clearFrameLayoutCache;
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
            import quickbite.backends.interpreter.frame_layout:
                clearFrameLayoutCache;

            clearFrameLayoutCache;
            Walker walker;
            scope(exit) walker.closeDurableInboundSession;
            walker.classObjectTable = new ObjectTable;
            walker.moduleTable = new ModuleTable;
            auto layout = cachedFrameLayout(function_);
            walker._activationFrame = FrameBlock.allocate(layout);
            walker.runStatement(function_.fbody);
            if (walker.result.isNativeAggregate) {
                import quickbite.backends.interpreter.aggregate_value: AggregateValue;

                char[] display;
                foreach (index; 0 .. AggregateValue.elementCount(walker.result))
                    display ~= AggregateValue.elementAt(walker.result, index)
                        .asUtf8Character;
                return EvalResult(display.idup);
            }
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
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.runtime_value: Value;
    import quickbite.frontend.dmd.types: isCharacterArrayType;

    if (value == Value.void_)
        return "";

    auto returnType = function_.type is null ? null : function_.type.nextOf;
    if (isCharacterArrayType(returnType)) {
        if (!value.isNativeAggregate)
            return `"` ~ value.asCharArrayString ~ `"` ~ value.stringTypeAnnotation;


        char[] characters;
        foreach (index; 0 .. AggregateValue.elementCount(value))
            characters ~= AggregateValue.elementAt(value, index).asUtf8Character;
        return (`"` ~ characters ~ `"` ~ value.stringTypeAnnotation).idup;
    }

    if (value.isNativeAggregate)
        return nativeAggregateDisplay(value);

    return value.toString;
}

private string nativeAggregateDisplay(
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;

    auto type = AggregateValue.native(value).type.toBasetype;
    if (type.isTypeDArray !is null || type.isTypeSArray !is null) {
        string display = "[";
        foreach (index; 0 .. AggregateValue.elementCount(value)) {
            if (index != 0)
                display ~= ", ";
            display ~= nativeAggregateElementDisplay(
                AggregateValue.elementAt(value, index),
            );
        }
        return display ~ "]";
    }

    if (auto structType = type.isTypeStruct) {
        import quickbite.backends.interpreter.layout: structFields;

        string display = structType.sym.ident.toString.idup ~ "(";
        bool first = true;
        foreach (index, field; structFields(structType)) {
            if (field.isThisDeclaration !is null)
                continue;
            if (!first)
                display ~= ", ";
            display ~= nativeAggregateElementDisplay(
                AggregateValue.fieldAt(value, index),
            );
            first = false;
        }
        return display ~ ")";
    }

    return value.toString;
}

private string nativeAggregateElementDisplay(
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) {
    return value.isNativeAggregate ? nativeAggregateDisplay(value) : value.dText;
}

private enum LoopControl {
    none,
    break_,
    continue_,
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

private struct UninitializedBindings {
    public bool[void*] addresses;
}

// A class field's own array-literal default (`int[] arr = [1, 2, 3];`) is
// compiled D's static `.init` data: every `new` that does not override the
// field shares that one evaluated backing array. Cached per field
// declaration behind a pointer indirection -- like `UninitializedBindings`
// -- so a fork that first populates the cache from empty still shares the
// same backing table with every other `Walker` in the execution, rather
// than a plain `Value[VarDeclaration]` field silently diverging the moment
// a fork inserts into what was, at fork time, still a null AA.
private struct ClassArrayFieldDefaults {
    public imported!"quickbite.backends.interpreter.runtime_value".Value[
        imported!"dmd.declaration".VarDeclaration] table;
}

private class InterpretedException: Exception {
    public imported!"quickbite.backends.interpreter.runtime_value".Value object;

    public this(in imported!"quickbite.backends.interpreter.runtime_value".Value object) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        const message = exceptionMessage(AggregateValue.classFieldNamed(object, "msg"));
        super(message);
        this.object = object;
    }
}


private string exceptionMessage(
    in imported!"quickbite.backends.interpreter.runtime_value".Value value,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;

    if (!value.isNativeAggregate)
        return value.asCharArrayString;

    char[] result;
    foreach (index; 0 .. AggregateValue.length(value))
        result ~= AggregateValue.elementAt(value, index).asUtf8Character;
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
    import quickbite.backends.interpreter.object_table: ObjectTable;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.runtime_values: defaultValue;
    import quickbite.backends.interpreter.runtime_value: Value;

    private Throwable[const(void)*] nativeThrowableRoots;
    // Captured native Throwable chains outlive the call bridge as rooted
    // interpreter values. Keying by the native body lets Throwable.next use
    // that captured authority without reinterpreting druntime's tagged link.
    private Value[void*] nativeThrowableNext;

    // Heap allocations made by interpreted `new T` own native guest bytes.
    // A native pointer is intentionally only a host address, so this table is
    // the host-only root that keeps each allocation live for the execution.
    // Child walkers copy and merge it with the other execution-wide native
    // roots; the guest pointer never carries an allocation id or a boxed
    // snapshot.
    private NativeBlock[const(void)*] nativePointerRoots;

    // Interpreted function declarations have no host code address. A guest
    // function-pointer slot therefore retains the interpreter callable in a
    // host-only side table keyed by its real native slot address, exactly as
    // an interpreted delegate does. The slot itself stays a valid null host
    // pointer; no boxed pointer carrier is ever written into guest bytes.
    private Value[const(void)*] nativeFunctionPointerSlots;

    // TypeInfo values for interpreted-only guest types have no resident host
    // object address. Their class-reference slots keep null ABI bytes while
    // this table retains the symbolic singleton keyed by the real slot
    // address, matching interpreted delegates and function pointers.
    private Value[void*] nativeTypeInfoSlots;

    private Value[VarDeclaration] locals;

    // Non-null only while `runRefArgumentExpression` is walking one call
    // argument.  `runIndexExpression` records its already-evaluated result in
    // the active argument's identity-keyed table; nested calls save and
    // restore this pointer around their own argument evaluation.
    private size_t[const(void)*]* _evaluatedReferenceArgumentIndices;

    // Authoritative native bytes for an address-taken scalar local:
    // populated eagerly the moment `&local` is taken (see
    // `bindingPointerValue`), for `native_scalar.
    // isNativeScalarType` locals only. Non-address-taken locals, and every
    // aggregate/pointer local, still live only in `locals` above -- this
    // table is a narrow byte-level authority, not a replacement for it.
    // `locals[variable]` stays a synchronously-refreshed mirror of a cell's
    // bytes for as long as a cell exists, so alias/child-Walker paths that
    // only know about `locals` keep seeing the true value.




    private bool[VarDeclaration] mirrorEstablished;

    // See `ClassArrayFieldDefaults`'s own comment. Lazily allocated on first
    // write, like `uninitializedBindingAddresses`; shared, not duped, across
    // forked child `Walker`s.
    private ClassArrayFieldDefaults* classArrayFieldDefaults;


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


    // Common reverse lookup from a field pointer's allocation id to its root
    // variable and DMD field-index path. Direct scalar struct and class fields
    // are migrated; the remaining shape-specific maps move here without
    // changing this representation.
    // A class-field pointer remains attached to the object after the variable
    // used to reach it is rebound. Index its object identity by allocation id
    // instead of retaining another storage handle.



    private FuncDeclaration[size_t] functionPointers;
    private size_t[FuncDeclaration] functionPointerIds;
    private size_t nextFunctionPointerId;
    private size_t nextClassObjectId;
    private RuntimeDelegate[size_t] delegates;
    // A native class reference carries only its body address; retain the
    // dynamic class Type by that address for Object-typed aliases.
    private imported!"dmd.mtype".Type[void*] nativeClassTypes;
    // A VM-allocated class reference exposes only its body address. Keep its
    // allocation handle by that address so later aliases retain the storage
    // that owns the body.
    private Value[void*] nativeClassOwners;
    // A borrowed native Throwable reference carries only its object address.
    // Keep its boxed field description separate from ordinary class ownership
    // so hydrating a catch's static view cannot replace an allocation root.
    private Value[void*] nativeExceptionMetadata;
    // A boxed view of a borrowed native class retains its opaque host object
    // pointer as interpreter metadata keyed by the view's ordinary object
    // identity. Guest fields remain exclusively guest data.
    private void*[size_t] borrowedNativeClassPointers;
    // Interpreted delegates have no guest ABI function pointer. Native
    // delegate slots retain their callable Value out-of-band while their
    // ordinary `{context, function}` guest bytes remain ABI-shaped.
    private Value[void*] nativeDelegateSlots;
    private imported!"quickbite.backends.interpreter.native_call_adapter".
        InterpreterInboundTrampolineSession* durableInboundSession;
    private Expression[VarDeclaration] lazyArgumentExpressions;
    private Value[VarDeclaration][VarDeclaration] lazyArgumentLocals;
    // The caller's own `_activationFrame` at the moment its `lazy` argument
    // was bound, captured alongside `lazyArgumentLocals` so `runLazyArgument`
    // can swap `_activationFrame` to it too -- see the comment there.
    private FrameBlock[VarDeclaration] lazyArgumentFrames;
    // The caller's own `mirrorEstablished` field is captured by pointer so a
    // lazy thunk updates the caller's write decision.
    private bool[VarDeclaration]*[VarDeclaration] lazyArgumentMirrorEstablished;
    private bool[VarDeclaration] uninitializedLocals;
    // `= void` is binding state, not a copied call-frame value. Ref writes
    // clear the caller's address directly, so forwarding cannot leave the
    // caller's declaration marked void until return reconciliation.
    private UninitializedBindings* uninitializedBindingAddresses;
    // Native address authority for a `ref` local whose initializer denotes
    // an already-established native frame slot.
    private void*[VarDeclaration] nativeRefLocalAddresses;
    // Retains the typed guest block for the rare declaration DMD gives no
    // owning/reference frame slot. `nativeRefLocalAddresses` carries only
    // an address, so this map owns the block for every pointer derived from
    // that declaration until a fresh declaration/parameter binding replaces
    // it.
    private NativeBlock[VarDeclaration] fallbackLocalStorage;
    private Value result;
    private bool runningCalledFunction;
    private bool inUnitTest;
    private FuncDeclaration currentFunction;

    // Per-activation native storage block; authority still lives in
    // `locals`/cells until reads route through it.
    private FrameBlock _activationFrame;

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
    // delegate used by `mirrorClassToFrame`.
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
    // (`forkLegacyFrameStateInto`) for that call's whole execution, so two
    // sibling frames that both touch the SAME module variable always
    // resolve to the SAME block instead of each lazily allocating (and
    // disagreeing about) their own.
    private ModuleTable* moduleTable;

    private Value thisValue;
    private bool hasThis;
    private Value pendingFinallyBodyException;
    private bool hasPendingFinallyBodyException;

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
                else if (addressOfRefReturn)
                    result = refReturnAddress(return_.exp);
                else {
                    // A bare `return () => ...;` is a FuncExp as the direct
                    // return expression, never first assigned to a local;
                    // ordinary `runExpression` has no general case for one
                    // (it answers `Value.undisplayable`) -- the same gap
                    // `runDeclarationExpression`/`runAssignExpression`/
                    // `structLiteralValue` already route around via
                    // `runFunctionLiteralDeclaration`. Scoped to a literal
                    // that actually CAPTURES an outer variable
                    // (`frame_layout.capturedVariables`, the same source
                    // `closureCapturedAddresses` already reads) only:
                    // `FuncLiteralDeclaration.isNested` answers true for
                    // any `delegate`-token literal regardless of whether
                    // it captures anything, so it can't tell a capturing
                    // literal apart from a non-capturing one -- and a
                    // non-capturing bare return needs no closure machinery
                    // in the first place. Keeping the non-capturing case on
                    // the `Value.undisplayable` placeholder path preserves
                    // the REPL's own synthetic top-level eval wrapper
                    // (`auto __quickbite_repl_eval_N__() { return <input>;
                    // }`, `frontend/cell.d`), which is the SAME `return
                    // FuncExp;` shape and whose undisplayable-placeholder
                    // rendering `tests/ut/bin/repl.d`'s
                    // `displaysUndisplayablePlaceholderForFunctionLiterals`
                    // pins on purpose (commit d8206025).
                    auto literal = return_.exp.isFuncExp;
                    bool captures = false;
                    if (literal !is null && literal.fd !is null) {
                        import quickbite.backends.interpreter.frame_layout:
                            capturedVariables;

                        captures = capturedVariables(literal.fd).length != 0;
                    }
                    result = !captures
                        ? runExpression(return_.exp)
                        : runFunctionLiteralDeclaration(literal);
                    if (return_.exp.type.toBasetype.isTypeClass !is null)
                        result = rootedNativeClassValue(return_.exp, result);
                }
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

        return AggregateValue.hasClassType(object, className(classType.sym));
    }

    // Single write path for a binding. `locals` retains only roots and
    // non-data expression categories; every data value is written to its
    // typed frame/dataseg place before a later read can observe the binding.
    private void setLocal(VarDeclaration variable, Value value) {
        value = nativeArrayBindingValue(variable, value);
        locals[variable] = value;

        if (!hasMirrorSlot(variable))
            return;

        import dmd.astenums: TY;

        if (variable.type.toBasetype.ty == TY.Tdelegate) {
            nativeDelegateSlots[bindingPlace(variable).address] = value;
            mirrorEstablished[variable] = true;
            return;
        }

        if (value.isFunctionPointer) {
            nativeFunctionPointerSlots[bindingPlace(variable).address] = value;
            Place(bindingPlace(variable).address, variable.type).storeReference(null);
            mirrorEstablished[variable] = true;
            return;
        }

        import quickbite.backends.interpreter.place_value:
            valueMatchesPlace, writeValue;

        if (
            variable.type.toBasetype.isTypeAArray !is null &&
            value == Value.null_
        ) {
            writeValue(bindingPlace(variable), value);
            mirrorEstablished[variable] = true;
            return;
        }

        if (
            variable.type.toBasetype.isTypeClass !is null &&
            value.isTypeName
        ) {
            writeStoredValue(bindingPlace(variable), value);
            mirrorEstablished[variable] = true;
            return;
        }

        if (
            variable.type.toBasetype.isTypeClass !is null &&
            value == Value.null_
        ) {
            writeStoredValue(bindingPlace(variable), value);
            mirrorEstablished[variable] = true;
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
            writeValue(bindingPlace(variable), value);
            mirrorEstablished[variable] = true;
            return;
        }

        if (
            variable.type.toBasetype.isTypeClass !is null &&
            !value.isNativeAggregate &&
            !value.isPointer &&
            value != Value.null_
        ) {
            // Boxed class construction remains only at the allocation seam
            // until that seam creates native bodies directly. It must still
            // establish the one reference slot rather than leave a second
            // boxed local authority behind.
            mirrorEstablished[variable] = mirrorClassToFrame(variable, value);
            return;
        }

        const canStore = value.isNativeAggregate
            ? true
            : valueMatchesPlace(variable.type, value);
        if (!canStore) {
            mirrorEstablished[variable] = false;
            return;
        }

        writeStoredValue(bindingPlace(variable), value, true);
        mirrorEstablished[variable] = true;
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

        if (oldAddress is newAddress)
            return;

        const byteLength = typeByteSize(type);
        const oldStart = cast(size_t) oldAddress;
        const oldEnd = oldStart + byteLength;

        size_t[] delegateOffsets;
        Value[] delegateValues;
        foreach (address, value; nativeDelegateSlots)
            if (cast(size_t) address >= oldStart && cast(size_t) address < oldEnd) {
                delegateOffsets ~= cast(size_t) address - oldStart;
                delegateValues ~= value;
            }

        size_t[] functionOffsets;
        Value[] functionValues;
        foreach (address, value; nativeFunctionPointerSlots)
            if (cast(size_t) address >= oldStart && cast(size_t) address < oldEnd) {
                functionOffsets ~= cast(size_t) address - oldStart;
                functionValues ~= value;
            }

        size_t[] typeInfoOffsets;
        Value[] typeInfoValues;
        foreach (address, value; nativeTypeInfoSlots)
            if (cast(size_t) address >= oldStart && cast(size_t) address < oldEnd) {
                typeInfoOffsets ~= cast(size_t) address - oldStart;
                typeInfoValues ~= value;
            }

        clearStoredMetadata(type, newAddress);

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
                oldStart,
                byteLength,
                cast(size_t) newAddress,
                byteLength,
            )
        )
            clearStoredMetadata(type, oldAddress);
    }

    // Any write invalidates every symbolic entry whose slot overlaps the
    // overwritten bytes. This is especially important for unions: writing a
    // non-symbolic sibling still overwrites the active symbolic member.
    private void clearStoredMetadata(
        imported!"dmd.mtype".Type type,
        void* address,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        const start = cast(size_t) address;
        const end = start + typeByteSize(type);

        const(void)*[] delegateAddresses;
        foreach (slot; nativeDelegateSlots.byKeyValue)
            if (rangesOverlap(
                cast(size_t) slot.key,
                2 * (void*).sizeof,
                start,
                end - start,
            ))
                delegateAddresses ~= slot.key;
        foreach (slot; delegateAddresses)
            nativeDelegateSlots.remove(cast(void*) slot);

        const(void)*[] functionAddresses;
        foreach (slot; nativeFunctionPointerSlots.byKeyValue)
            if (rangesOverlap(
                cast(size_t) slot.key,
                (void*).sizeof,
                start,
                end - start,
            ))
                functionAddresses ~= slot.key;
        foreach (slot; functionAddresses)
            nativeFunctionPointerSlots.remove(slot);

        const(void)*[] typeInfoAddresses;
        foreach (slot; nativeTypeInfoSlots.byKeyValue)
            if (rangesOverlap(
                cast(size_t) slot.key,
                (void*).sizeof,
                start,
                end - start,
            ))
                typeInfoAddresses ~= slot.key;
        foreach (slot; typeInfoAddresses)
            nativeTypeInfoSlots.remove(cast(void*) slot);
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
        in Value value,
        in bool consumeMetadata = false,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place_value: writeValue;

        import dmd.astenums: TY;

        if (place.type.toBasetype.isTypeClass !is null && value.isTypeName) {
            clearStoredMetadata(place.type, place.address);
            nativeTypeInfoSlots[place.address] = value;
            writeValue(place, Value.null_);
            return;
        }

        if (place.type.toBasetype.ty == TY.Tdelegate && value != Value.null_) {
            clearStoredMetadata(place.type, place.address);
            nativeDelegateSlots[place.address] = value;
            writeValue(place, Value.null_);
            return;
        }

        auto pointerType = place.type.toBasetype.isTypePointer;
        if (
            pointerType !is null &&
            pointerType.nextOf.toBasetype.isTypeFunction !is null &&
            value.isFunctionPointer
        ) {
            clearStoredMetadata(place.type, place.address);
            nativeFunctionPointerSlots[place.address] = value;
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
    private Value readStoredValue(
        imported!"quickbite.backends.interpreter.place".Place place,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place_value: readValue;

        if (place.type.toBasetype.isTypeClass !is null)
            if (auto typeInfo = place.address in nativeTypeInfoSlots)
                return *typeInfo;

        const value = readValue(place);
        if (value.isNativeAggregate)
            copyStoredMetadata(
                place.type,
                place.address,
                AggregateValue.native(value).address,
            );
        return value;
    }

    private Value withStoredStructField(
        in Value receiver,
        imported!"dmd.mtype".Type receiverType,
        in size_t fieldIndex,
        in Value fieldValue,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: Place;

        auto field = structFields(receiverType.toBasetype.isTypeStruct)[fieldIndex];
        const symbolicTypeInfo = field.type.toBasetype.isTypeClass !is null &&
            fieldValue.isTypeName;
        auto result = AggregateValue.withStructField(
            receiver,
            fieldIndex,
            symbolicTypeInfo ? Value.null_ : fieldValue,
        );
        auto source = AggregateValue.native(receiver);
        auto destination = AggregateValue.native(result);
        copyStoredMetadata(receiverType, source.address, destination.address);

        auto fieldPlace = Place(destination.address, destination.type)
            .field(field);
        writeStoredValue(fieldPlace, fieldValue);
        return result;
    }

    private Value nativeArrayBindingValue(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        auto arrayType = variable.type.toBasetype.isTypeDArray;
        if (arrayType is null || value.isNativeAggregate || !value.isArray)
            return value;

        auto elements = value.arrayAllocationElements;
        auto carrier = NativeArray.allocate(arrayType.next, elements.length);
        foreach (index, element; elements)
            writeValue(Place(carrier.element(index).ptr, arrayType.next), element);
        nativePointerRoots[carrier.block.address] = carrier.block;

        const offset = value.arrayAllocationOffset;
        if (offset > carrier.length || value.length > carrier.length - offset)
            throw new Exception("Array view exceeds its allocation carrier.");
        return AggregateValue.reconstructNativeArrayWithLength(
            variable.type,
            value.length,
            cast(ubyte*) carrier.block.address +
                offset * typeByteSize(arrayType.next),
        );
    }

    private void storeBinding(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: declaredType;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        if (auto address = variable in nativeRefLocalAddresses) {
            if (value.isFunctionPointer) {
                nativeFunctionPointerSlots[*address] = value;
                Place(*address, declaredType(variable)).storeReference(null);
                clearUninitializedBindingAddress(*address);
                locals[variable] = value;
                uninitializedLocals.remove(variable);
                return;
            }
            if (
                variable.type.toBasetype.isTypeClass !is null &&
                value.isNativeAggregate
            ) {
                writeStoredValue(
                    Place(*address, declaredType(variable)),
                    Value.pointerValue(
                        AggregateValue.nativeClassBodyAddress(value),
                    ),
                );
            } else {
                writeStoredValue(Place(*address, declaredType(variable)), value);
            }
            clearUninitializedBindingAddress(*address);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            return;
        }

        if (
            variable.isReference &&
            _activationFrame.hasReferenceSlot(variable) &&
            _activationFrame.bindingAddress(variable) !is null
        ) {
            if (value.isFunctionPointer) {
                auto address = cast(void*) _activationFrame.bindingAddress(variable);
                nativeFunctionPointerSlots[address] = value;
                Place(address, declaredType(variable)).storeReference(null);
                clearUninitializedBindingAddress(address);
                locals[variable] = value;
                uninitializedLocals.remove(variable);
                return;
            }
            writeStoredValue(
                Place(_activationFrame.bindingAddress(variable), declaredType(variable)),
                value,
            );
            clearUninitializedBindingAddress(_activationFrame.bindingAddress(variable));
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            return;
        }

        setLocal(variable, value);
        if (hasMirrorSlot(variable))
            clearUninitializedBindingAddress(bindingPlace(variable).address);
        uninitializedLocals.remove(variable);
    }

    private void markUninitializedBinding(VarDeclaration variable) {
        if (!hasMirrorSlot(variable))
            return;
        if (uninitializedBindingAddresses is null)
            uninitializedBindingAddresses = new UninitializedBindings;
        uninitializedBindingAddresses.addresses[bindingPlace(variable).address] = true;
    }

    private bool isUninitializedBinding(VarDeclaration variable) {
        if (hasMirrorSlot(variable))
            return uninitializedBindingAddresses !is null &&
                bindingPlace(variable).address in uninitializedBindingAddresses.addresses;
        return (variable in uninitializedLocals) !is null;
    }

    private void clearUninitializedBindingAddress(void* address) {
        if (uninitializedBindingAddresses !is null)
            uninitializedBindingAddresses.addresses.remove(address);
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
    // that `mirrorSliceToFrame`/`mirrorClassToFrame` use directly for a slice
    // header or a
    // class reference, which are not `place_value`-composed values of
    // their own declared type the way `mirrorPlace` composes for. Callers
    // are expected to have already checked `hasMirrorSlot`.
    private void* mirrorAddress(VarDeclaration variable) {
        return variable.isDataseg
            ? moduleTable.storageFor(variable)
            : _activationFrame.bindingAddress(variable);
    }

    // The one typed place for a binding's own storage: a true local's frame
    // slot or a dataseg binding's module block. The combined authority switch
    // routes whole reads, stores, lvalue composition, and reference binding
    // through this constructor so none can choose a separate carrier.
    private Place bindingPlace(VarDeclaration variable) {
        import quickbite.backends.interpreter.layout: declaredType;

        return Place(mirrorAddress(variable), declaredType(variable));
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
        if (auto address = variable in nativeRefLocalAddresses)
            return *address;
        materializeDatasegInitializer(variable);
        return bindingPlace(variable).address;
    }


    private bool mirrorSliceToFrame(VarDeclaration variable, in Value value) {
        import quickbite.backends.interpreter.native_array: NativeArray;

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
        return true;
    }

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
            if (identity == 0 || (identity in visiting))
                return false;

            if (!isClassBodyComposable(fieldClassType.sym))
                return false;

            visiting[identity] = true;

            if (!classBodyShapeMatchesImpl(fieldClassType.sym, fieldValue, visiting))
                return false;
        }

        return true;
    }

    private void bindCatchVariable(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (catch_.var is null)
            return;

        if (auto pointer = borrowedNativeClassPointer(object)) {
            const hydrated = nativeExceptionCatchObject(catch_, object);
            nativeExceptionMetadata[*pointer] = hydrated;
            bindingPlace(catch_.var).storeReference(*pointer);
            mirrorEstablished[catch_.var] = true;
        } else {
            setLocal(catch_.var, object);
        }
        uninitializedLocals.remove(catch_.var);
    }


    // `assertReferenceBind` compares exactly a reference slot's typed bytes.
    private static ubyte[] frameBytesAt(void* address, in size_t length) pure nothrow @trusted {
        return (cast(ubyte*) address)[0 .. length];
    }

    private void throwInterpretedException(
        imported!"dmd.expression".Expression expression,
    ) {
        auto object = runExpression(expression);
        // Ordinary class reads expose the body pointer while their local
        // retains the rooted NativeAggregate. Throwing needs the root so
        // the exception remains live through unwinding and its native class
        // metadata/fields stay available to catch and formatting paths.
        if (auto var = expression.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                if (auto rooted = variable in locals)
                    if ((*rooted).isNativeAggregate)
                        object = *rooted;
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
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallException exception,
    ) {
        rootNativeException(exception);
        throw new InterpretedException(nativeExceptionObject(exception));
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

    // Rebuild the captured native exception chain as linked interpreted
    // exception objects, threading each `.next` through _nextInChainPtr
    // (ffi.md §34.13).
    private Value nativeExceptionObject(
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallException exception,
    ) {
        auto object = nativeExceptionBaseObject(
            exception.msg,
            exception.className,
            exception.nativeThrowableObjectPointer,
        );
        if (exception.chainedNext !is null) {
            const next = nativeExceptionObject(exception.chainedNext);
            if (object.isNativeAggregate)
                nativeThrowableNext[AggregateValue.nativeClassBodyAddress(object)] = next;
            // A borrowed native Throwable already owns its `.next` link.
            // Rewriting that live druntime object through frontend field
            // layout can corrupt adjacent payload; recursion above is still
            // required to register and root each native link.
            if (!object.isNativeAggregate)
                object = AggregateValue.withClassFieldNamed(
                    object,
                    "_nextInChainPtr",
                    next.isNativeAggregate
                        ? Value.pointerValue(
                            AggregateValue.nativeClassBodyAddress(next),
                        )
                        : next,
                );
        }

        if (auto pointer = borrowedNativeClassPointer(object)) {
            // Throwable.next exposes another native reference before its
            // interpreted cast runs, so every captured link needs the same
            // host-only metadata lookup as the outer catch binding.
            nativeExceptionMetadata[*pointer] = object;
        }

        return object;
    }

    private Value nativeExceptionBaseObject(
        in string message,
        in string className,
        in const(void)* nativeObjectPointer = null,
    ) {
        Value object;
        if (auto class_ = dynamicClassDeclarationByName(className)) {
            object = AggregateValue.withClassFieldNamed(
                classDefaultValue(class_),
                "msg",
                Value(message),
            );
        } else if (auto class_ = classDeclarationByQualifiedName(className)) {
            // Fully-qualified name (e.g. a native throw's `classinfo.name`)
            // may not be lexically visible from the current call frame but
            // still be known to the frontend. Reusing the declaration gives
            // the real base-class chain.
            object = AggregateValue.withClassFieldNamed(
                classDefaultValue(class_),
                "msg",
                Value(message),
            );
        } else {
            object = nativeExceptionValue(message, className);
        }

        return withBorrowedNativeClassPointer(object, nativeObjectPointer);
    }

    // Build a native exception object with the full Throwable field layout so
    // chain-aware field reads (`.next` resolves to _nextInChainPtr) work, while
    // keeping the thrown class's type names so a catch on a dependency subclass
    // still matches. Falls back to the message-only object if the frontend has
    // not recorded the Exception declaration.
    private Value nativeExceptionValue(
        in string message,
        in string className,
    ) const {
        import quickbite.backends.interpreter.runtime_values: defaultValue;
        import quickbite.backends.interpreter.layout: classFields;
        import dmd.dclass: ClassDeclaration;

        auto class_ = ClassDeclaration.exception;
        if (class_ is null)
            return Value.classValue(
                className,
                nativeExceptionTypeNames(className),
                ["msg"],
                [Value(message)],
            );

        string[] fieldNames;
        Value[] fields;
        foreach (field; classFields(class_)) {
            fieldNames ~= variableName(field);
            fields ~= defaultValue(field.type);
        }

        return AggregateValue.withClassFieldNamed(
            Value.classValue(
                className,
                nativeExceptionTypeNames(className),
                fieldNames,
                fields,
            ),
            "msg",
            Value(message),
        );
    }

    private Value nativeExceptionCatchObject(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (borrowedNativeClassPointer(object) is null)
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

        auto nativePointer = borrowedNativeClassPointer(object);
        if (nativePointer is null)
            return object;

        const pointer = *nativePointer;
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

        return Value.classValue(
            AggregateValue.classTypeName(object),
            AggregateValue.classTypeNames(object),
            fieldNames,
            fields,
            AggregateValue.classIdentity(object),
        );
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
        import quickbite.backends.interpreter.layout: fieldByteOffset;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto fieldType = field.type.toBasetype;
        return readValue(Place(
            cast(void*) (cast(ubyte*) objectPointer + fieldByteOffset(field)),
            fieldType,
        ));
    }

    private Value withBorrowedNativeClassPointer(
        in Value object,
        in const(void)* nativeObjectPointer,
    ) {
        if (nativeObjectPointer is null)
            return object;

        const existingIdentity = AggregateValue.classIdentity(object);
        const identity = existingIdentity == 0
            ? ++nextClassObjectId
            : existingIdentity;
        const identified = existingIdentity == 0
            ? object.withClassIdentity(identity)
            : object;
        borrowedNativeClassPointers[identity] = cast(void*) nativeObjectPointer;
        return identified;
    }

    private void** borrowedNativeClassPointer(in Value object) {
        if (!AggregateValue.isClass(object) || object.isNativeAggregate)
            return null;
        const identity = AggregateValue.classIdentity(object);
        return identity == 0 ? null : identity in borrowedNativeClassPointers;
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

    private void runWithStatement(
        imported!"dmd.statement".WithStatement with_,
    ) {
        if (with_.wthis !is null) {
            import dmd.tokens: EXP;

            const pointer = addressOfExpression(with_.exp, EXP.address);
            storeBinding(with_.wthis, pointer);
            if (!hasMirrorSlot(with_.wthis) &&
                with_.wthis !in nativeRefLocalAddresses)
                fallbackLocalAddress(with_.wthis);
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
                return reconstructStoredArray(null_.type, []);

            return Value.null_;
        }

        if (auto string_ = expression.isStringExp) {
            import quickbite.backends.interpreter.runtime_string_literals: stringValue;

            NativeBlock pointerStorage;
            const value = stringValue(string_, pointerStorage);
            if (pointerStorage.address !is null)
                nativePointerRoots[pointerStorage.address] = pointerStorage;
            return value;
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
            return runVectorArrayExpression(vectorArray);

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
                return Value(false);

            if (
                hasThis &&
                AggregateValue.isClass(thisValue) &&
                AggregateValue.hasClassFieldNamed(thisValue, name)
            )
                return AggregateValue.classFieldNamed(thisValue, name);

            // Constructor and member-method `this` is the native body
            // pointer. Resolve an unqualified class field through that body
            // rather than falling back to a boxed class-value lookup.
            if (hasThis && thisValue.isPointer && currentFunction !is null) {
                auto thisParameter = currentFunction.vthis;
                auto classType = thisParameter is null
                    ? null
                    : thisParameter.type.toBasetype.isTypeClass;
                if (classType !is null && classType.sym !is null) {
                    import quickbite.backends.interpreter.layout: classFields, fieldName;
                    import quickbite.backends.interpreter.place: Place;
                    import quickbite.backends.interpreter.place_value: readValue;

                    foreach (field; classFields(classType.sym))
                        if (fieldName(field) == name)
                            return readValue(Place(
                                thisValue.pointerAddress,
                                thisParameter.type,
                            ).field(field));
                }
            }
        }

        if (auto var = expression.isVarExp) {
            import dmd.id: Id;

            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                return runSymbolDeclarationVarExpression(var);

            // Mutable because frame/layout APIs take DMD declarations.
            auto referenceVariable = variable;

            // The Interpreter runs a compiled-D-equivalent runtime, not
            // DMD's own CTFE engine (that is the separate `Ctfe` backend,
            // `backends/ctfe/dmd_ctfe.d`, which invokes DMD's real CTFE
            // interpreter and legitimately observes `true`); the magic
            // `__ctfe` flag must therefore read `false` here, matching
            // `SystemLinker`.
            if (variable.ident is Id.ctfe)
                return Value(false);

            if (isUninitializedBinding(variable)) {
                import quickbite.backends.interpreter.messages: uninitializedVariableMessage;
                import quickbite.frontend.dmd.types: isStaticArrayType, isStructType;

                // DMD's void diagnostic is field-granular: reading a whole
                // void-initialized aggregate (as `S res = void; return res;`
                // does) materialises a default value; only a still-void scalar
                // read is reported. Match that so patterns like Phobos
                // `trustedVoidInit` evaluate up to any real libc call.
                if (isStructType(variable.type) || isStaticArrayType(variable.type)) {
                    const value = defaultValue(variable);
                    setLocal(variable, value);
                    uninitializedLocals.remove(variable);
                    return value;
                }

                throw new Exception(uninitializedVariableMessage(variable, currentFunction));
            }

            // A filled reference slot is the caller's scalar storage --
            // for a `ref`/`out` parameter, or (per `frame_layout`'s own
            // `Kind.reference`) a captured outer variable, the enclosing
            // activation's own address. `hasReferenceSlot` alone
            // distinguishes the two reference-slot owners from a plain
            // owning local; no separate `variable.isReference` DMD flag
            // check is needed on top of it. Read it before the legacy
            // parameter-cell fallback so `ref`/`out` mutation and a
            // captured local's value are immediately visible.
            import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
            if (
                _activationFrame.hasReferenceSlot(referenceVariable) &&
                _activationFrame.bindingAddress(referenceVariable) !is null &&
                (
                    isNativeScalarType(referenceVariable.type) ||
                    referenceVariable.type.toBasetype.isTypeStruct !is null ||
                    referenceVariable.type.toBasetype.isTypeSArray !is null ||
                    referenceVariable.type.toBasetype.isTypeDArray !is null ||
                    referenceVariable.type.toBasetype.isTypeAArray !is null ||
                    referenceVariable.type.toBasetype.isTypePointer !is null
                )
            ) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;
                import quickbite.backends.interpreter.layout: declaredType;

                return readStoredValue(Place(
                    _activationFrame.bindingAddress(referenceVariable),
                    declaredType(referenceVariable),
                ));
            }

            // Owning frame and dataseg bytes are the one binding authority.
            // `locals` may retain a root/callable expression handle, but a
            // storage read never reconstructs an aggregate or consults a
            // cell/alias map before loading this typed place.
            if (auto address = variable in nativeRefLocalAddresses) {
                import quickbite.backends.interpreter.layout: declaredType;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                if (auto delegate_ = cast(void*) *address in nativeDelegateSlots)
                    return *delegate_;
                if (auto function_ = *address in nativeFunctionPointerSlots)
                    return *function_;
                return readStoredValue(Place(*address, declaredType(variable)));
            }

            // An `extern __gshared` global defined in a compiled dependency
            // image is authoritative at its native data symbol. Read it
            // before the module-table mirror path below, whose zeroed slot is
            // only interpreter-owned dataseg storage.
            import quickbite.frontend.dmd.functions: isExternDataSymbol;
            if (isExternDataSymbol(variable)) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;
                import quickbite.ffi.ffi: resolveDataSymbol;

                if (auto address = resolveDataSymbol(variable))
                    return readValue(Place(
                        cast(void*) address,
                        variable.type.toBasetype,
                    ));
            }

            materializeDatasegInitializer(variable);

            if (hasMirrorSlot(variable)) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.place_value: readValue;

                if (variable.type.toBasetype.ty == TY.Tdelegate)
                    if (auto delegate_ = bindingPlace(variable).address in nativeDelegateSlots)
                        return *delegate_;

                if (auto function_ = bindingPlace(variable).address in nativeFunctionPointerSlots)
                    return *function_;

                if (!mirrorEstablished.get(variable, false))
                    if (auto current = variable in locals)
                        return *current;

                // A by-value slice read copies its `{length, ptr}` header
                // out of the frame, but the result must retain the native
                // header that owns the backing block for as long as the
                // returned slice can be observed.  The copied header remains
                // the guest value; this is host-only lifetime retention, not
                // an element reconstruction or a second slice authority.
                if (variable.type.toBasetype.isTypeDArray !is null)
                    if (auto rooted = variable in locals)
                        if ((*rooted).isNativeAggregate) {
                            import quickbite.backends.interpreter.aggregate_value: AggregateValue;

                            return AggregateValue.copyFromAddress(
                                variable.type,
                                bindingPlace(variable).address,
                                AggregateValue.native(*rooted).storage,
                            );
                        }

                return readStoredValue(bindingPlace(variable));
            }

            if (auto current = variable in locals) {
                // Only non-storage expression categories (callables and
                // metadata) have no binding place.
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

            // A native AA default is an owning header allocation, not an
            // immutable boxed empty value. Dataseg storage must retain that
            // handle on its first read, so later hooks observe the same table.
            import quickbite.frontend.dmd.types: isAssocArrayType;
            if (variable.isDataseg && isAssocArrayType(variable.type)) {
                const value = defaultValue(variable);
                setLocal(variable, value);
                return value;
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

        // A default-initialized pointer-typed operand (e.g. a GC pool
        // boundary pointer that has never been assigned) reads as `Null`,
        // not a zero-valued `Pointer`; the static operand type still marks
        // this as a pointer comparison. See `runAddExpression`.
        import quickbite.frontend.dmd.types: isPointerType;

        const leftIsPointer = leftValue.isPointer ||
            (leftValue == Value.null_ && isPointerType(comparison.e1.type));
        const rightIsPointer = rightValue.isPointer ||
            (rightValue == Value.null_ && isPointerType(comparison.e2.type));

        if (leftIsPointer && rightIsPointer)
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
        import quickbite.frontend.dmd.types: isPointerType;

        const left = runExpression(add.e1);
        const right = runExpression(add.e2);

        // A default-initialized pointer-typed operand (e.g. druntime's
        // dip1008 Throwable chain-link arithmetic on its own default-null
        // `_nextInChainPtr`) reads as `Null`, not a zero-valued `Pointer`;
        // the static operand type still marks it as pointer arithmetic.
        const leftIsPointer = left.isPointer ||
            (left == Value.null_ && isPointerType(add.e1.type));
        const rightIsPointer = right.isPointer ||
            (right == Value.null_ && isPointerType(add.e2.type));

        if (leftIsPointer) {
            const offset = leftIsPointer
                ? right.asLong
                : pointerElementOffset(add.type, right.asLong);
            return left.pointerOffsetBy(
                offset,
            );
        }

        if (rightIsPointer) {
            const offset = rightIsPointer
                ? left.asLong
                : pointerElementOffset(add.type, left.asLong);
            return right.pointerOffsetBy(
                offset,
            );
        }

        return left + right;
    }

    private Value runMinExpression(imported!"dmd.expression".MinExp sub) {
        import quickbite.frontend.dmd.types: isPointerType;

        const left = runExpression(sub.e1);
        const right = runExpression(sub.e2);

        // See `runAddExpression`: a default-null pointer operand reads as
        // `Null`, not a zero-valued `Pointer`.
        const leftIsPointer = left.isPointer ||
            (left == Value.null_ && isPointerType(sub.e1.type));
        const rightIsPointer = right.isPointer ||
            (right == Value.null_ && isPointerType(sub.e2.type));

        // DMD lowers `p - q` to `(p - q) / elementSize`; return the byte
        // difference so the lowered division yields the element difference
        if (leftIsPointer && rightIsPointer) {
            const scale = leftIsPointer && rightIsPointer
                ? 1
                : pointerElementSize(sub.e1.type);
            return Value(
                left.pointerOffsetDifference(right) * scale,
            );
        }

        if (leftIsPointer) {
            const offset = leftIsPointer
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
                return bindingPointerValue(variable);

        if (auto delegate_ = e1.isDelegateExp)
            return runDelegateExpression(delegate_);

        // Taking the address of a dereference recovers the pointer value;
        // evaluating the dereference first would incorrectly require a
        // separate addressable value for the pointee.
        if (auto pointer = e1.isPtrExp)
            return runExpression(pointer.e1);

        // `&field` (also `field.ptr`) of a struct's static-array member: a
        // pointer to the field's first element, exactly what arrayPointer
        // builds for `&field[0]`.
        if (auto dot = e1.isDotVarExp) {
            import quickbite.frontend.dmd.types: isStaticArrayType;

            if (isStaticArrayType(dot.type))
                return arrayPointer(dot, 0, op);

            // Build a nested field address from its receiver's one address.
            // In particular, `&a[i++].inner.x` first composes the address of
            // `a[i++].inner`; that evaluates `i++` exactly once, then the
            // outer field offset composes from the resulting native pointer.
            // Re-running `runExpression(dot)` for a boxed snapshot would
            // walk the index a second time.
            if (auto innerDot = dot.e1.isDotVarExp)
                if (auto field = dot.var.isVarDeclaration) {
                    const receiverPointer = addressOfExpression(innerDot, op);
                    if (receiverPointer.isPointer) {
                        import quickbite.backends.interpreter.layout: fieldByteOffset;
                        import quickbite.backends.interpreter.place: Place;

                        // `&parent.child.x` first yields the address of the
                        // class-reference field `parent.child`; compose `x`
                        // from the referenced body, not from that slot's bytes.
                        if (innerDot.type.toBasetype.isTypeClass !is null)
                            return Value.pointerValue(
                                Place(receiverPointer.pointerAddress, innerDot.type)
                                    .deref.field(field).address,
                            );

                        return receiverPointer.pointerOffsetBy(
                            cast(long) fieldByteOffset(field),
                        );
                    }
                }

            if (auto index = dot.e1.isIndexExp) {
                import quickbite.backends.interpreter.layout: fieldByteOffset;

                if (auto field = dot.var.isVarDeclaration) {
                    // `$` inside `index.e2` (a `DollarExp`) is bound to
                    // `index.lengthVar`; the ordinary eager path binds it
                    // from `runExpression(index.e1)`'s length before
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
                                Value(AggregateValue.length(runExpression(receiverVar))),
                            );
                    const elementIndex = runExpression(index.e2).asLong;
                    const elementPointer = arrayPointer(index.e1, elementIndex, op);
                    if (elementPointer.isPointer)
                        return elementPointer.pointerOffsetBy(
                            cast(long) fieldByteOffset(field),
                        );
                }
            }

            // A native struct receiver already owns the complete DMD-layout
            // object. Compose its field place directly instead of minting a
            // field-snapshot id and promoting a parallel struct cell.
            if (auto receiver = dot.e1.isVarExp)
                if (auto variable = receiver.var.isVarDeclaration)
                    if (auto nativeReceiver = variable in locals)
                        if ((*nativeReceiver).isNativeAggregate) {
                            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                            import quickbite.backends.interpreter.place: Place;

                            auto field = dot.var.isVarDeclaration;
                            auto aggregate = AggregateValue.native(*nativeReceiver);
                            if (
                                field !is null &&
                                aggregate.type.toBasetype.isTypeStruct !is null
                            ) {
                                auto address = variable in nativeRefLocalAddresses;
                                return Value.pointerValue(
                                    // A local's established frame slot is its
                                    // actual guest storage.  The native
                                    // aggregate in `locals` retains the
                                    // expression result that seeded it, so
                                    // taking a field address from that handle
                                    // would leave an earlier pointer aimed at
                                    // the initializer after a whole-struct
                                    // assignment copies new bytes into the
                                    // frame slot.
                                    Place(
                                        address is null
                                            ? hasMirrorSlot(variable) &&
                                                mirrorEstablished.get(variable, false)
                                                ? mirrorAddress(variable)
                                                : aggregate.address
                                            : *address,
                                        aggregate.type,
                                    )
                                        .field(field)
                                        .address,
                                );
                            }
                        }

            // A native class receiver is already its object-body address.
            // Compose the DMD field offset directly instead of allocating a
            // class-field snapshot identity and its parallel cell state.
            if (auto receiver = dot.e1.isVarExp)
                if (auto variable = receiver.var.isVarDeclaration)
                    if (auto nativeReceiver = variable in locals)
                        if (
                            (*nativeReceiver).isNativeAggregate &&
                            variable.type.toBasetype.isTypeClass !is null
                        ) {
                            import quickbite.backends.interpreter.place: Place;

                            auto field = dot.var.isVarDeclaration;
                            if (field !is null)
                                return Value.pointerValue(
                                    Place(
                                        AggregateValue.nativeClassBodyAddress(*nativeReceiver),
                                        variable.type,
                                    ).field(field).address,
                                );
                        }

            // A class read normally carries only its native body address.
            // Recover its dynamic type from the registry and compose the
            // field place from that authority rather than minting a distinct
            // declaration identity for each `&field` evaluation.
            auto nativeClassReceiver = runExpression(dot.e1);
            if (
                nativeClassReceiver.isPointer &&
                dot.e1.type.toBasetype.isTypeClass !is null &&
                nativeClassReceiver.pointerAddress in nativeClassTypes
            ) {
                import quickbite.backends.interpreter.place: Place;

                auto field = dot.var.isVarDeclaration;
                if (field !is null)
                    return Value.pointerValue(
                        Place(nativeClassReceiver.pointerAddress, dot.e1.type)
                            .field(field)
                            .address,
                    );
            }

            // A field of an aggregate call result has no variable binding,
            // but the NativeAggregate itself owns typed DMD-layout storage.
            // Retain that storage in the execution roots before returning a
            // plain host address into it.
            if (dot.e1.isCallExp !is null) {
                const receiver = nativeClassReceiver;
                if (receiver.isNativeAggregate) {
                    import quickbite.backends.interpreter.place: Place;

                    auto aggregate = AggregateValue.native(receiver);
                    nativePointerRoots[aggregate.storage.address] = aggregate.storage;
                    auto field = dot.var.isVarDeclaration;
                    if (field !is null)
                        return Value.pointerValue(
                            Place(aggregate.address, aggregate.type)
                                .field(field)
                                .address,
                        );
                }
            }

            // Every remaining field address must compose from the owning
            // typed binding. This also covers parameters and nested receiver
            // shapes that do not retain a NativeAggregate handle in
            // `locals`, while keeping the resulting pointer a plain host
            // address.
            try {
                import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;

                return Value.pointerValue(placeOfLvalue(
                    dot,
                    (variable) @safe => addressableBindingBase(variable),
                    (expression) @system => cast(size_t)
                        runExpression(expression).asLong,
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
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
        import quickbite.frontend.dmd.functions: hasNoAvailableSource;
        import std.conv: text;

        const unsupported =
            text("Unsupported eval expression: ", op, " of ", call.op);

        if (call.f is null)
            throw new Exception(unsupported);
        if (!returnsRef(call.f))
            return addressOfCallResultTemporary(call);

        functionSemantic3(call.f);
        if (call.f.needThis)
            throw new Exception(unsupported);
        const native = hasNoAvailableSource(call.f);

        Value[] arguments;
        Expression[] argumentExpressions;
        EvaluatedReferenceArgument[] evaluatedArguments;
        if (call.arguments !is null)
            foreach (index, argument; *call.arguments) {
                EvaluatedReferenceArgument evaluated;
                arguments ~= index < call.f.parameters.length &&
                    isReferenceParameter(
                        call.f,
                        index,
                        (*call.f.parameters)[index],
                    )
                    ? runRefArgumentExpression(argument, evaluated)
                    : runExpression(argument);
                if (
                    index < call.f.parameters.length &&
                    (*call.f.parameters)[index].type.toBasetype.isTypeClass !is null
                )
                    arguments[$ - 1] = rootedNativeClassValue(argument, arguments[$ - 1]);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
            }

        if (native) {
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;

            NativeCallResult nativeResult;
            try {
                if (!invokeNativeDeclaration(
                    call.f,
                    Value.void_,
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
            return Value.pointerValue(nativeResult.referenceAddress);
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
        forkExecutionStateInto(child);
        child.bindFunctionParameters(
            call.f,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
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

    // A `ref` foreach variable over an input range may bind to a `front`
    // result returned by value. DMD represents its per-iteration temporary as
    // `AddrExp(CallExp)`: evaluate the call once into typed native storage and
    // return that ordinary temporary's address.
    private Value addressOfCallResultTemporary(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.layout:
            typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        const value = runCallExpression(call);
        const scan = typeHasPointers(call.type)
            ? NativeBlock.Scan.conservative
            : NativeBlock.Scan.no;
        auto temporary = NativeBlock.allocate(typeByteSize(call.type), scan);
        writeStoredValue(Place(temporary.address, call.type), value);
        nativePointerRoots[temporary.address] = temporary;
        return Value.pointerValue(temporary.address);
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
    private void forkExecutionStateInto(ref Walker child) {
        // Shared, not duped: see `classObjectTable`'s own field comment
        // for why an identity-keyed table needs a shared pointer here,
        // not a per-frame copy.
        child.classObjectTable = classObjectTable;
        child.uninitializedBindingAddresses = uninitializedBindingAddresses;
        // Shared for the same reason: one evaluated array-literal class
        // default must stay the single backing array every fork sees.
        child.classArrayFieldDefaults = classArrayFieldDefaults;
        // Shared for the identical reason, and by the identical shape --
        // see `moduleTable`'s own field comment.
        child.moduleTable = moduleTable;
        child.nativeThrowableRoots = nativeThrowableRoots.dup;
        child.nativeThrowableNext = nativeThrowableNext.dup;
        child.nativePointerRoots = nativePointerRoots.dup;
        child.nativeFunctionPointerSlots = nativeFunctionPointerSlots.dup;
        child.nativeTypeInfoSlots = nativeTypeInfoSlots.dup;
        child.nextClassObjectId = nextClassObjectId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.nativeClassTypes = nativeClassTypes.dup;
        child.nativeClassOwners = nativeClassOwners.dup;
        child.nativeExceptionMetadata = nativeExceptionMetadata.dup;
        child.borrowedNativeClassPointers = borrowedNativeClassPointers.dup;
        child.nativeDelegateSlots = nativeDelegateSlots.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.lazyArgumentFrames = lazyArgumentFrames.dup;
        child.lazyArgumentMirrorEstablished = lazyArgumentMirrorEstablished.dup;
        child.fallbackLocalStorage = fallbackLocalStorage.dup;

        // A reference relay can name DMD's hidden `vthis`, which has no
        // ordinary local entry or frame slot to rediscover here. Retain every
        // explicit native binding; a fresh parameter/declaration removes its
        // own stale entry before it establishes new storage.
        child.nativeRefLocalAddresses = nativeRefLocalAddresses.dup;

        // A captured binding borrows the parent place. Every inherited local
        // gets that address, not just an aggregate that happened to have a
        // native expression root: scalar, slice, struct, and class writes in
        // the child must reach the parent immediately and need no return-time
        // reconciliation. A declaration in the child removes this borrow
        // before it establishes its fresh stack slot.
        foreach (variable, _; child.locals)
            if (hasMirrorSlot(variable))
                child.nativeRefLocalAddresses[variable] = bindingPlace(variable).address;

        // A native root is already the shared cross-frame storage. Do not
        // carry an inherited boxed cell family for that same declaration into
        // the child: it would be a second authority with stale reverse maps.
        foreach (variable, value; locals)
            if (value.isNativeAggregate) {
                // A nested child captures the parent's local binding, not
                // the native expression handle that originally initialized
                // it. Carry an established frame address as the child's
                // borrowed place so re-taking `&s.inner.x` names the same
                // bytes in both frames.
                if (
                    variable in child.locals &&
                    variable !in child.nativeRefLocalAddresses &&
                    hasMirrorSlot(variable) &&
                    mirrorEstablished.get(variable, false)
                )
                    child.nativeRefLocalAddresses[variable] = mirrorAddress(variable);
            }
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
        return child.result;
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
    // anything, whether its own unconditional `runExpression(index.e1)`
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
    private Value nestedIndexPointer(
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
                Value(AggregateValue.length(readValue(receiverPlace))),
            );
        const outerOffset = runExpression(index.e2).asLong;
        const pointer = Value.pointerValue(
            receiverPlace.index(cast(size_t) outerOffset).address,
        );
        if (selfAddress)
            return pointer;
        return Value.pointerValue(
            Place(cast(void*) pointer.pointerAddress, expression.type)
                .index(cast(size_t) offset)
                .address,
        );
    }

    private Value arrayPointer(
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
                runExpression(comma.e1);
                return arrayPointer(comma.e2, offset, op, selfAddress);
            }
            if (auto question = array.isCondExp)
                return arrayPointer(
                    isTruthy(runExpression(question.econd)) ? question.e1 : question.e2,
                    offset,
                    op,
                    selfAddress,
                );

            // DMD lowers indexing a dynamic-array call through a pointer
            // cast of the CallExp, rather than leaving the IndexExp as the
            // direct address-taking operand.  Evaluate that call once and
            // compose its element address from the returned typed slice.
            if (auto call = array.isCallExp) {
                const source = runExpression(call);
                const arrayValue = source;
                if (AggregateValue.isArray(arrayValue)) {
                    if (arrayValue.isNativeAggregate)
                        return Value.pointerValue(
                            AggregateValue.elementAddress(
                                arrayValue,
                                cast(size_t) offset,
                            ),
                        );

                    throw new Exception("boxed pointer from array call result");
                }
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
                            Place, IndexOutOfBoundsException;
                        import quickbite.backends.interpreter.place_value:
                            readValue;

                        Place resolveInnerPlace() {
                            return placeOfLvalue(
                                inner,
                                (variable) @safe =>
                                    addressableBindingBase(variable),
                                (expression) @system =>
                                    cast(size_t) runExpression(expression).asLong,
                                // @trusted: `setLocal` is @system because it is
                                // part of the interpreter's general storage
                                // machinery. Here it only binds the `$` length
                                // variable belonging to the index being walked.
                                (chainIndex, base) @trusted {
                                    if (chainIndex.lengthVar !is null)
                                        setLocal(
                                            chainIndex.lengthVar,
                                            Value(
                                                AggregateValue.length(readValue(base)),
                                            ),
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
                                setLocal(index.lengthVar, Value(rowLength));
                            const elementOffset = runExpression(index.e2).asLong;
                            if (cast(size_t) elementOffset >= rowLength)
                                throwRangeError(
                                    "quickbite.backends.interpreter.place.Place.index: "
                                    ~ "index out of range for static array place",
                                );

                            try {
                                const pointer = Value.pointerValue(
                                    resolveInnerPlace()
                                        .index(cast(size_t) elementOffset)
                                        .address,
                                );
                                if (selfAddress)
                                    return pointer;
                                return Value.pointerValue(
                                    Place(cast(void*) pointer.pointerAddress, array.type)
                                        .index(cast(size_t) offset)
                                        .address,
                                );
                            } catch (IndexOutOfBoundsException exception) {
                                // The row bounds check above already ruled out
                                // `elementOffset`; any exception here comes
                                // from `resolveInnerPlace`'s own first-bracket
                                // bounds check instead.
                                throwRangeError(exception.msg);
                            }
                        }

                        try {
                            return nestedIndexPointer(
                                array,
                                resolveInnerPlace(),
                                offset,
                                selfAddress,
                            );
                        } catch (IndexOutOfBoundsException exception) {
                            // The composed `Place.index` call observes bounds
                            // only after `i++` has committed. Translate its
                            // host exception without retrying the receiver.
                            throwRangeError(exception.msg);
                        }
                    }
                }

                // A doubly (or more) nested `DotVarExp` receiver whose own
                // chain runs through an `IndexExp` somewhere
                // (`arr[i++].mid.a[j]`, `s.a[i++].mid.b[j]`, ...) must be
                // resolved through `lvalue_place.placeOfLvalue` BEFORE this
                // arm's own unconditional `runExpression(index.e1)` below
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
                        import quickbite.backends.interpreter.place: Place;
                        import quickbite.backends.interpreter.place_value: readValue;

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
                            auto fieldPlace = placeOfLvalue(
                                nestedField,
                                (variable) @safe => addressableBindingBase(variable),
                                (expression) @system =>
                                    cast(size_t) runExpression(expression).asLong,
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
                                // subexpression it names.
                                (chainIndex, base) @trusted {
                                    if (chainIndex.lengthVar !is null)
                                        setLocal(
                                            chainIndex.lengthVar,
                                            Value(AggregateValue.length(readValue(base))),
                                        );
                                },
                            );
                            return nestedIndexPointer(
                                array,
                                fieldPlace,
                                offset,
                                selfAddress,
                            );
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
                        } catch (Exception exception) {
                            // Every step composed above (`placeOfLvalue`
                            // past the shape-refusal arm, `fieldPlace.
                            // index`/`Place.index`) only ever raises a bare
                            // host `Exception` for an out-of-range index --
                            // the receiver's shape is already known-good by
                            // this point, so this is a real guest bounds
                            // violation on already-committed side effects
                            // (`i++`'s increment stands), not something
                            // safe to retry from scratch.
                            throwRangeError(exception.msg);
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
                const source = runExpression(index.e1);
                // A non-ref dynamic-array call returns the interpreter's
                // one-element result carrier.  Its target is still the one
                // evaluated slice value, not an addressable pointer into the
                // guest array.
                const arrayValue = source;
                if (index.lengthVar !is null) {
                    const sourceLength = AggregateValue.isArray(arrayValue)
                        ? AggregateValue.length(arrayValue)
                        : arrayValue.length;
                    setLocal(index.lengthVar, Value(sourceLength));
                }

                const outerOffset = runExpression(index.e2).asLong;
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

                        return Value.pointerValue(
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

                            return Value.pointerValue(
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
                        import quickbite.backends.interpreter.place: Place;

                        try {
                            auto fieldPlace = placeOfLvalue(
                                field,
                                (variable) @safe => addressableBindingBase(variable),
                                (expression) @system =>
                                    cast(size_t) runExpression(expression).asLong,
                            );
                            const pointer = Value.pointerValue(
                                fieldPlace.index(cast(size_t) outerOffset).address,
                            );
                            if (selfAddress)
                                return pointer;
                            // Same hazard as the `VarExp` arm above.
                            return Value.pointerValue(
                                Place(cast(void*) pointer.pointerAddress, array.type)
                                    .index(cast(size_t) offset)
                                    .address,
                            );
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
                        } catch (Exception exception) {
                            // `fieldPlace.index`/`Place.index` above only
                            // ever raise a bare host `Exception` for an
                            // out-of-range `outerOffset` -- the receiver's
                            // shape is already known-good by this point, so
                            // this is a real guest bounds violation, not
                            // something the detached-copy fallback below
                            // should silently paper over.
                            throwRangeError(exception.msg);
                        }
                    }
                }
                // A nested/multi-dimensional static-array index
                // (`m[i][j]`, `m.e1` itself an `IndexExp`) must compose its
                // receiver's address the same way the `VarExp` case above
                // does, rather than falling through to `arrayValue` below:
                // `arrayValue` is `runExpression(index.e1)`'s result, and
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

                        return Value.pointerValue(
                            Place(cast(void*) element.pointerAddress, array.type)
                                .index(cast(size_t) offset)
                                .address,
                        );
                    }
                }
                if (AggregateValue.isArray(arrayValue)) {
                    if (arrayValue.isNativeAggregate) {
                        // `index.e1` had no VarExp/DotVarExp receiver, so it
                        // was just re-evaluated above as a second, independent
                        // call/index. That result's native storage has no
                        // root beyond this call's own locals; retain it in
                        // the execution roots before returning a bare address
                        // into it, matching the DotVarExp call-result fix
                        // above (`nativePointerRoots`) -- without this, the
                        // composed address can outlive its backing block.
                        auto aggregate = AggregateValue.native(arrayValue);
                        nativePointerRoots[aggregate.storage.address] = aggregate.storage;
                        auto elementAddress = AggregateValue.elementAddress(
                            arrayValue,
                            cast(size_t) outerOffset,
                        );
                        // DMD leaves this synthetic IndexExp's type null for
                        // a direct `&array[index]`. Its element address is
                        // already complete when this call is itself the
                        // top-level `&array[index]` (`selfAddress`) -- no
                        // further offset composes through it.
                        if (selfAddress)
                            return Value.pointerValue(elementAddress);
                        // `array.type` (this row's own type, e.g. `int[]` or
                        // `int[3]`) drives the leaf stride. `Place.index`
                        // dereferences a dynamic-array row's `{length, ptr}`
                        // header before applying that stride, and applies it
                        // directly for a static-array row's inline bytes --
                        // exactly the two cases the Contracts' "one level at
                        // a time" rule distinguishes; a raw byte offset from
                        // `elementAddress` would land inside a slice header
                        // instead of the row's data for the dynamic-array
                        // case.
                        import quickbite.backends.interpreter.place: Place;

                        return Value.pointerValue(
                            Place(elementAddress, array.type)
                                .index(cast(size_t) offset)
                                .address,
                        );
                    }

                    throw new Exception("boxed pointer from indexed expression result");
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
                import quickbite.backends.interpreter.layout:
                    classFields, fieldByteOffset, typeByteSize;
                import quickbite.frontend.dmd.types:
                    isDynamicArrayType, isStaticArrayType;

                if (auto receiver = dot.e1.isVarExp)
                    if (auto variable = receiver.var.isVarDeclaration)
                        if (auto nativeReceiver = variable in locals)
                            if ((*nativeReceiver).isNativeAggregate) {
                                import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                                import quickbite.backends.interpreter.place: Place;

                                auto field = dot.var.isVarDeclaration;
                                auto aggregate = AggregateValue.native(*nativeReceiver);
                                if (
                                    field !is null &&
                                    aggregate.type.toBasetype.isTypeStruct !is null
                                ) {
                                    // Whole-value struct writes copy into the
                                    // owning frame place.  An earlier native
                                    // expression handle is only a rooted
                                    // rvalue, so an element address must start
                                    // at that place (or at a ref binding's
                                    // source address), never at the handle's
                                    // detached storage.
                                    auto address = variable in nativeRefLocalAddresses;
                                    return Value.pointerValue(
                                        Place(
                                            address is null
                                                ? hasMirrorSlot(variable) &&
                                                    mirrorEstablished.get(variable, false)
                                                    ? mirrorAddress(variable)
                                                    : aggregate.address
                                                : *address,
                                            aggregate.type,
                                        )
                                            .field(field)
                                            .index(cast(size_t) offset)
                                            .address,
                                    );
                                }
                            }

                // Native class values carry the object-body address directly.
                // A field place composes from that address and the class's
                // DMD field offset; it must not create a boxed class-cell
                // alias merely to take an address.
                if (auto receiver = dot.e1.isVarExp)
                    if (auto variable = receiver.var.isVarDeclaration)
                        if (auto nativeReceiver = variable in locals)
                        if (
                            (*nativeReceiver).isNativeAggregate &&
                            variable.type.toBasetype.isTypeClass !is null
                        ) {
                            import quickbite.backends.interpreter.place: Place;

                                auto field = dot.var.isVarDeclaration;
                                if (field !is null)
                                    return Value.pointerValue(
                                    Place(
                                        AggregateValue.nativeClassBodyAddress(*nativeReceiver),
                                        variable.type,
                                    ).field(field).index(cast(size_t) offset).address,
                                    );
                            }

                auto elementType = dot.type.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;

                const value = runExpression(array);
                if (value.isNativeAggregate) {
                    import quickbite.backends.interpreter.aggregate_value: AggregateValue;

                    return Value.pointerValue(
                        AggregateValue.elementAddress(value, cast(size_t) offset),
                    );
                }
                throw new Exception("boxed pointer from dot array");
            }

            throw new Exception(text("Unsupported eval expression: ", op));
        }

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        if (auto address = variable in nativeRefLocalAddresses) {
            import quickbite.backends.interpreter.place: Place;

            return Value.pointerValue(
                Place(*address, variable.type)
                    .index(cast(size_t) offset)
                    .address,
            );
        }

        // A dataseg element's address exists structurally the moment its
        // module-table block exists (allocated lazily by `bindingPlace`
        // itself), whether or not `locals` yet holds a cached read/write of
        // it: a module-scope static array with no explicit initializer (e.g.
        // `S[N] arr;`) never runs `storeBinding`, so requiring a `locals`
        // entry before reaching this check rejected a first-ever
        // address-taking index into it (`arr[i++].method()`) with the
        // generic "Unsupported eval expression" fallback below. An owning
        // frame slot is the analogous in-activation case. A dataseg
        // variable must materialize its declared default value before this
        // address is handed out: the module-table block starts as raw
        // zeroed memory, and a struct element with a non-zero `.init`
        // pattern must read that pattern on first touch, not zero bytes
        // (mirrors `symbolOffsetLocalValue`'s own call below).
        materializeDatasegInitializer(variable);

        if (hasMirrorSlot(variable)) {
            import quickbite.backends.interpreter.place: Place;

            return Value.pointerValue(
                Place(bindingPlace(variable).address, variable.type)
                    .index(cast(size_t) offset)
                    .address,
            );
        }

        auto current = variable in locals;
        if (current is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        // A plain `ref` aggregate local has no owning slot, but its binding
        // records the caller's typed address. Element addresses through that
        // alias must compose from the caller's storage before considering the
        // retained native handle that initialized the alias expression.
        // Native aggregate storage already supplies the guest element
        // address. Do not promote it into the boxed allocation-id/cell path:
        // that would create a second pointer authority for the same bytes.
        if ((*current).isNativeAggregate) {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
            import quickbite.backends.interpreter.place: Place;

            // A local native aggregate seeds its established frame place, but
            // a later whole-value assignment copies new bytes into that
            // place. An earlier element pointer must therefore compose from
            // the frame header/inline bytes, not from the transient aggregate
            // handle held in `locals`; for a dynamic array `Place.index`
            // follows the header's then-current backing pointer, while for a
            // static array it stays at the one inline local allocation.
            if (hasMirrorSlot(variable) && mirrorEstablished.get(variable, false))
                return Value.pointerValue(
                    Place(mirrorAddress(variable), variable.type)
                        .index(cast(size_t) offset)
                        .address,
                );
            return Value.pointerValue(
                AggregateValue.elementAddress(*current, cast(size_t) offset),
            );
        }

        // Some DMD AA lowering introduces a synthetic `ref` declaration
        // whose initializer has already produced the native address of the
        // guest handle. It is not an array carrier to re-expand through the
        // boxed allocation path; at offset zero this existing address is the
        // lvalue the declaration must borrow.
        if ((*current).isPointer && offset == 0)
            return *current;

        throw new Exception(text(
            "arrayPointer native address unavailable: variable=",
            variable.toChars,
            ", type=", variable.type.toChars,
            ", native=", (*current).isNativeAggregate,
            ", array=", (*current).isArray,
        ));
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

        materializeDatasegInitializer(variable);

        if (hasMirrorSlot(variable)) {
            if (isStaticArrayType(variable.type) &&
                isStaticArrayType(symbol.type.toBasetype.nextOf))
                return Value.pointerValue(bindingPlace(variable).address);

            return Value.pointerValue(bindingPlace(variable).address)
                .pointerOffsetBy(cast(long) symbol.offset);
        }

        if (isStaticArrayType(variable.type)) {
            // `&array` points at the static-array local itself, unlike
            // `&array[index]`, which points into its elements. Keep the
            // former on the local-pointer identity path so a plain `ref`
            // static-array local can reuse that exact storage identity.
            if (isStaticArrayType(symbol.type.toBasetype.nextOf))
                return bindingPointerValue(variable);

            // Taking the address of a still-void static array materialises
            // its storage (as aggregate reads do) so writes through the
            // pointer have somewhere to land.
            if (variable in uninitializedLocals && variable !in locals)
                setLocal(variable, defaultValue(variable));

            if (auto current = variable in locals) {
                import quickbite.backends.interpreter.layout: typeByteSize;

                auto elementType = variable.type.toBasetype.nextOf.toBasetype;
                const elementSize = typeByteSize(elementType);
                const elementOffset = elementSize == 0
                    ? 0
                    : cast(size_t) symbol.offset / elementSize;
                if ((*current).isNativeAggregate) {
                    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                    import quickbite.backends.interpreter.place: Place;

                    if (hasMirrorSlot(variable) && mirrorEstablished.get(variable, false))
                        return Value.pointerValue(
                            Place(mirrorAddress(variable), variable.type)
                                .index(elementOffset)
                                .address,
                        );
                    return Value.pointerValue(
                        AggregateValue.elementAddress(*current, elementOffset),
                    );
                }

                throw new Exception("boxed pointer from static symbol offset");
            }
        }

        return bindingPointerValue(variable);
    }

    private Value bindingPointerValue(VarDeclaration variable) {
        if (auto address = variable in nativeRefLocalAddresses)
            return Value.pointerValue(*address);

        materializeDatasegInitializer(variable);

        // A slotless rooted native class retains its actual reference owner.
        // Owning frame bindings continue below to their frame slot, so `&c`
        // and a `ref C` alias both name the reference slot rather than the
        // object's body.
        if (auto current = variable in locals)
            if (
                !hasMirrorSlot(variable) &&
                (*current).isNativeAggregate &&
                variable.type.toBasetype.isTypeClass !is null
            )
                return Value.pointerValue(AggregateValue.native(*current).address);

        // A ref parameter denotes the caller's storage, which its binding
        // records directly in this frame. Taking its address must preserve
        // that address rather than minting a declaration identity for the
        // parameter declaration.
        if (
            isRefVariable(variable) &&
            _activationFrame.hasReferenceSlot(variable) &&
            _activationFrame.bindingAddress(variable) !is null
        )
            return Value.pointerValue(_activationFrame.bindingAddress(variable));

        // Every owning binding already has a DMD-layout slot. The combined
        // switch makes that slot its address identity even before a read
        // materialises the declaration's default value; `uninitializedLocals`
        // retains the language-level `= void` distinction. No cell or local
        // pointer id may stand in for this address.
        if (hasMirrorSlot(variable))
            return Value.pointerValue(bindingPlace(variable).address);

        return Value.pointerValue(fallbackLocalAddress(variable));
    }

    private void materializeDatasegInitializer(VarDeclaration variable) {
        if (
            !variable.isDataseg ||
            mirrorEstablished.get(variable, false)
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
        // `ModuleTable`'s block map is shared, not duped, across every forked
        // child `Walker` a function call creates (`forkExecutionStateInto`'s
        // `child.moduleTable = moduleTable` aliases the same underlying
        // hashmap; D associative arrays are reference types), so
        // `moduleTable.has(variable)` answers "has this variable's block
        // ever been allocated" for the whole program. `mirrorEstablished` (and
        // `locals`) are per-activation bookkeeping that starts empty in every
        // child and is never merged back into the caller (`mergeFunctionState`
        // does not carry it). When the block already exists -- established by
        // a DIFFERENT activation, whether an earlier sibling call or the
        // activation that just returned from calling this one -- this
        // activation must still adopt the block's current, authoritative
        // bytes into its own `locals`/`mirrorEstablished` bookkeeping (several
        // call sites, notably index-assignment's `variable in locals` check,
        // require that bookkeeping even though a plain read would tolerate
        // its absence via the `bindingPlace` fallback). Adopting is a
        // read-then-store-the-same-value round trip: it must never re-run the
        // initializer expression, which would clobber an already-mutated
        // block (observed: three `bump()` calls each resetting a `__gshared
        // int counter = 5;` back to `5` before incrementing, so the final
        // read saw `5` instead of `8`).
        //
        // A `Tdelegate`-typed variable is the one shape this round trip
        // itself destroys: a delegate never writes its bytes into the
        // dataseg block at all (`setLocal`'s `Tdelegate` arm stores it
        // out-of-band in `nativeDelegateSlots`, keyed by the block's
        // address, leaving the block's bytes zeroed), so `readValue` on the
        // block reads back `Value.null_`, and routing that through
        // `setLocal` would overwrite `nativeDelegateSlots[address]` with
        // `null` -- destroying a delegate a sibling/prior activation
        // legitimately registered there (observed: a delegate assigned by
        // one function and called from another read back "Unsupported eval
        // call" because adopting the caller's own dataseg mirror nulled the
        // callee's freshly-assigned delegate). Note this activation's
        // bookkeeping directly from the out-of-band slot instead, without
        // routing through `setLocal`'s destructive side effect.
        if (moduleTable.has(variable)) {
            import dmd.astenums: TY;
            import quickbite.backends.interpreter.place_value: readValue;

            if (variable.type.toBasetype.ty == TY.Tdelegate) {
                locals[variable] = nativeDelegateSlots.get(
                    bindingPlace(variable).address, Value.null_,
                );
                mirrorEstablished[variable] = true;
                return;
            }

            setLocal(variable, readValue(bindingPlace(variable)));
            return;
        }

        if (variable._init is null) {
            import dmd.typesem: defaultInitLiteral;

            setLocal(variable, runExpression(variable.type.defaultInitLiteral(variable.loc)));
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
            setLocal(variable, defaultValue(variable));
            setLocal(variable, storageValue(
                variable.type,
                runExpression(initializerExp),
            ));
        }
    }

    // Every data pointer needs a typed host address. A declaration with no
    // DMD frame slot (notably a synthetic ref local before it binds) receives
    // one retained guest block rather than an opaque declaration identity.
    // The block is seeded once from the current binding and retained in
    // `fallbackLocalStorage`; later reads/writes use the accompanying native
    // relay, so aliases share those same bytes.
    private void* fallbackLocalAddress(VarDeclaration variable) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.layout: declaredType, typeByteSize;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        if (auto block = variable in fallbackLocalStorage)
            return block.address;

        auto block = NativeBlock.allocate(
            typeByteSize(declaredType(variable)),
            NativeBlock.Scan.conservative,
        );
        const value = readBindingValue(variable);
        if (variable.type.toBasetype.ty == TY.Tdelegate)
            nativeDelegateSlots[block.address] = value;
        else
            writeValue(Place(block.address, declaredType(variable)), value);
        fallbackLocalStorage[variable] = block;
        nativeRefLocalAddresses[variable] = block.address;
        return block.address;
    }

    // A plain aggregate `ref` binding reuses its source's local-pointer id.
    // Resolve that existing identity back to the declaration which owns the
    // storage so reads and assignments through the ref local or parameter do
    // not acquire an independent boxed slot.
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
    private void writeStructCellScalarFields(ref NativeStruct cell, in Value structValue) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: fieldByteOffset;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, writeScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        foreach (index; 0 .. cell.fieldCount) {
            auto fieldType = cell.fieldDeclaration(index).type;

            if (isNativeScalarType(fieldType)) {
                writeScalar(fieldType, cell.field(index),
                    AggregateValue.fieldAt(structValue, index));
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

                const fieldValue = AggregateValue.fieldAt(structValue, index);
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = cell.arrayField(index);
                foreach (elementIndex; 0 .. AggregateValue.elementCount(fieldValue))
                    writeArrayCellElement(
                        arrayCell,
                        elementIndex,
                        AggregateValue.elementAt(fieldValue, elementIndex),
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

                const fieldValue = AggregateValue.fieldAt(structValue, index);
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = NativeArray.allocate(elementType,
                    AggregateValue.elementCount(fieldValue));
                foreach (elementIndex; 0 .. AggregateValue.elementCount(fieldValue))
                    writeArrayCellElement(
                        arrayCell,
                        elementIndex,
                        AggregateValue.elementAt(fieldValue, elementIndex),
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

            const nestedValue = AggregateValue.fieldAt(structValue, index);
            if (!AggregateValue.isStruct(nestedValue))
                continue;

            auto nestedCell = cell.structField(index);
            writeStructCellScalarFields(nestedCell, nestedValue);
        }
    }

    private void dropDeclarationCells(VarDeclaration variable) {
        nativeRefLocalAddresses.remove(variable);
        fallbackLocalStorage.remove(variable);
    }

    private Value readBindingValue(VarDeclaration variable) {
        import quickbite.backends.interpreter.layout: declaredType;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        if (auto address = variable in nativeRefLocalAddresses) {
            if (auto function_ = *address in nativeFunctionPointerSlots)
                return *function_;
            return readValue(Place(*address, declaredType(variable)));
        }

        import dmd.astenums: TY;

        if (hasMirrorSlot(variable) && variable.type.toBasetype.ty == TY.Tdelegate)
            if (auto delegate_ = bindingPlace(variable).address in nativeDelegateSlots)
                return *delegate_;

        if (hasMirrorSlot(variable))
            if (auto function_ = bindingPlace(variable).address in nativeFunctionPointerSlots)
                return *function_;

        if (hasMirrorSlot(variable))
            return readValue(bindingPlace(variable));

        if (auto current = variable in locals)
            return *current;

        return defaultValue(variable);
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
        runtime.capturedAddresses = closureCapturedAddresses(delegate_.func);
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
        runtime.contextPointer = Value.pointerValue(null);
        runtime.capturedAddresses = closureCapturedAddresses(literal.fd);
        if (literal.fd.isNested && hasThis) {
            runtime.receiver = thisValue;
            runtime.hasReceiver = true;
        }

        delegates[functionPointer.functionPointerId] = runtime;
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
                const pointer = bindingPointerValue(variable);
                if (pointer.isPointer && pointer.pointerAddress !is null)
                    addresses[variable] = pointer.pointerAddress;
            } catch (Exception) {
                continue;
            }
        }

        return addresses;
    }

    private Value delegateContextPointer(
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

        return Value.pointerValue(null);
    }

    private Value runPointerExpression(
        imported!"dmd.expression".PtrExp pointer,
    ) {
        return dereferencePointerValue(pointer, runExpression(pointer.e1));
    }

    // The dereference half of `runPointerExpression`, split out so a caller
    // that already evaluated `pointer.e1` itself (to also retain that
    // address for a later use, e.g. a member-call receiver rebind) can reuse
    // that single evaluation instead of running the -- possibly
    // side-effecting -- pointer operand a second time.
    private Value dereferencePointerValue(
        imported!"dmd.expression".PtrExp pointer,
        in Value value,
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

    private Value staticArrayPointerView(
        in Value pointer,
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

    private Value[] arrayElements(in Value value) {
        Value[] elements;
        foreach (index; 0 .. AggregateValue.length(value))
            elements ~= AggregateValue.elementAt(value, index);

        return elements;
    }

    private Value[] arrayPointerElements(in Value value) {
        if (value.isNativeAggregate)
            return arrayElements(value);
        return AggregateValue.isArray(value)
            ? value.arrayAllocationElements
            : arrayElements(value);
    }

    private long arrayPointerOffset(in Value value, in long offset) {
        if (value.isNativeAggregate)
            return offset;
        return AggregateValue.isArray(value)
            ? cast(long) value.arrayAllocationOffset + offset
            : offset;
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
        // existing raw-value identity semantics, except that a native class
        // aggregate and a pointer-valued class reference both normalize to
        // their shared object-body address. Array-pointer snapshots can
        // contain different element copies while still naming the same
        // allocation and offset; those two fields are their identity.
        const aggregateValues =
            AggregateValue.isStruct(left) && AggregateValue.isStruct(right) ||
            AggregateValue.isArray(left) && AggregateValue.isArray(right);
        const nullPointerIdentity =
            left.isPointer && left.pointerAddress is null &&
                right == Value.null_ ||
            right.isPointer && right.pointerAddress is null &&
                left == Value.null_;
        const same =
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
        if (identity.op == EXP.notIdentity)
            return Value(!same);

        return Value(same);
    }

    private void* classIdentityAddress(in Value value) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (value == Value.null_)
            return null;

        if (value.isNativeAggregate)
            return AggregateValue.nativeClassBodyAddress(value);
        if (value.isPointer)
            return value.pointerAddress;
        if (auto pointer = borrowedNativeClassPointer(value))
            return *pointer;
        return cast(void*) AggregateValue.classIdentity(value);
    }

    private Value runCallExpression(imported!"dmd.expression".CallExp call) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.builtins:
            binaryBuiltinCall,
            interpreterBuiltinArgumentCount,
            tryInterpreterBuiltin,
            unaryBuiltinCall;
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;

        if (call.f !is null) {
            import dmd.funcsem: functionSemantic3;
            functionSemantic3(call.f);
        }

        bool nativeCall;
        if (call.f !is null) {
            import quickbite.backends.interpreter.interception_guard:
                bodyContainsAsm;
            import quickbite.frontend.dmd.functions: hasNoAvailableSource;

            nativeCall = hasNoAvailableSource(call.f) || bodyContainsAsm(call.f);
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
                else if (nativeCall && nativeReferenceParameter(call.f, index))
                    arguments ~= runRefArgumentExpression(argument, evaluated);
                else if (parameter !is null &&
                    isReferenceParameter(call.f, index, parameter))
                    arguments ~= runRefArgumentExpression(argument, evaluated);
                else
                    arguments ~= runExpression(argument);
                if (
                    parameter !is null &&
                    parameter.type.toBasetype.isTypeClass !is null
                )
                    arguments[$ - 1] = rootedNativeClassValue(argument, arguments[$ - 1]);
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
            Value receiverPointerAddress;
            bool hasReceiverPointerAddress;
            Value receiver;
            if (auto pointerReceiver = dot.e1.isPtrExp) {
                receiverPointerAddress = runExpression(pointerReceiver.e1);
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
            } else
                receiver = runExpression(dot.e1);
            receiver = rootedNativeClassValue(dot.e1, receiver);
            const interpreterAllocatedClass = receiver.isNativeAggregate &&
                dot.e1.type.toBasetype.isTypeClass !is null;
            if (receiver == Value.null_)
                throw new Exception(
                    "function call through null class reference `null`",
                );

            if (call.f !is null && call.f.needThis) {
                // An interpreted-only TypeInfo has symbolic identity but no
                // resident class body on which druntime's member can run.
                // TypeInfo.opEquals defines equality by that identity (and
                // accepts null), so answer it before native object dispatch.
                if (
                    receiver.isTypeName &&
                    functionName(call.f) == "opEquals" &&
                    arguments.length == 1 &&
                    (arguments[0].isTypeName || arguments[0] == Value.null_)
                )
                    return Value(receiver == arguments[0]);

                import quickbite.frontend.dmd.functions:
                    hasNoAvailableSource, noAvailableSourceMessage;

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
                    receiver = Value.pointerValue(
                        AggregateValue.nativeClassBodyAddress(receiver),
                    );
                // An interpreter-allocated class has no synthesized vtable
                // yet, so only virtual dispatch is refused. A nonvirtual
                // member resolves by symbol and receives the native body as
                // hidden `this`; it never reads word zero as a vtable.
                if (
                    hasNoAvailableSource(function_) &&
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
                        ))
                            return nativeResult.value;
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
                );
            }
        }

        if (call.f !is null) {
            import quickbite.frontend.dmd.functions:
                hasNoAvailableSource, noAvailableSourceMessage;
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;

            if (nativeCall) {
                try {
                    // A native callback may have hydrated a native-backed
                    // class for interpreted field access. Native calls consume
                    // the preserved object identity, independent of whether
                    // DMD retained a parameter declaration we can classify.
                    foreach (ref argument; arguments)
                        argument = preservedNativeClassIdentity(argument);
                    NativeCallResult nativeResult;
                    if (!call.f.needThis && invokeNativeDeclaration(
                            call.f,
                            Value.void_,
                            null,
                            null,
                            arguments,
                            argumentExpressions,
                            evaluatedArguments,
                            false,
                            nativeResult,
                        ))
                        return nativeResult.value;
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

    private Value runRefArgumentExpression(
        imported!"dmd.expression".Expression argument,
        out EvaluatedReferenceArgument evaluated,
    ) {
        if (argument.isDotVarExp !is null) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: readValue;

            const address = addressOfExpression(argument, EXP.address);
            if (address.isPointer) {
                evaluated.address = address.pointerAddress;
                return readValue(Place(evaluated.address, argument.type));
            }
        }

        if (auto pointer = argument.isPtrExp)
            if (auto conditional = pointer.e1.isCondExp) {
                auto selected = isTruthy(runExpression(conditional.econd))
                    ? conditional.e1
                    : conditional.e2;
                const address = runExpression(selected);
                if (address.isPointer) {
                    evaluated.address = address.pointerAddress;
                    return loadNativePointerElement(pointer.e1.type, address, 0);
                }
            }

        if (auto conditional = argument.isCondExp) {
            auto selected = isTruthy(runExpression(conditional.econd))
                ? conditional.e1
                : conditional.e2;
            const value = runRefArgumentExpression(selected, evaluated);
            if (evaluated.selectedLvalue is null)
                evaluated.selectedLvalue = selected;
            return value;
        }

        auto var = argument.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable !is null && variable in uninitializedLocals)
            return Value.void_;
        if (variable !is null) {
            const address = bindingPointerValue(variable);
            if (address.isPointer)
                evaluated.address = address.pointerAddress;
        }

        auto previous = _evaluatedReferenceArgumentIndices;
        _evaluatedReferenceArgumentIndices = &evaluated.indices;
        scope(exit)
            _evaluatedReferenceArgumentIndices = previous;

        auto value = runExpression(argument);
        if (auto dot = argument.isDotVarExp)
            if (auto receiver = dot.e1.isVarExp)
                if (auto receiverVariable = receiver.var.isVarDeclaration)
                    if (auto classValue = receiverVariable in locals)
                        if (receiverVariable.type.toBasetype.isTypeClass !is null) {
                            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                            import quickbite.backends.interpreter.place: Place;
                            auto bodyAddress = (*classValue).isNativeAggregate
                                ? AggregateValue.nativeClassBodyAddress(*classValue)
                                : (*classValue).pointerAddress;
                            if (bodyAddress is null)
                                return value;

                            auto field = dot.var.isVarDeclaration;
                            if (field !is null)
                                evaluated.address = Place(
                                    bodyAddress,
                                    receiverVariable.type,
                                ).field(field).address;
                        }

        return value;
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
            );

        return runFunction(
            runtime.function_,
            rootedArguments,
            argumentExpressions,
            false,
            evaluatedArguments,
            runtime.capturedAddresses,
        );
    }

    // Call a native delegate the interpreter holds as an opaque
    // {context, funcptr} value read from a native typed result place, the
    // inverse of the §34.16 callback bridge.
    private Value runNativeDelegateCall(
        in Value callee,
        imported!"dmd.expression".CallExp call,
        in Value[] arguments,
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
        auto argumentTypes = nativeArgumentTypes(argumentExpressions);

        try {
            if (durableInboundSession is null)
                durableInboundSession = new InterpreterInboundTrampolineSession(
                    &invokeNativeCallback,
                );
            auto request = NativeCallRequest(
                delegateSignature: functionType,
                delegateAddress: callee.nativeDelegateFuncptr,
                delegateContext: callee.nativeDelegateContext,
                arguments: arguments.dup,
                argumentTypes: argumentTypes,
                argumentOperands: nativeCallOperands(
                    null,
                    arguments,
                    argumentExpressions,
                    argumentTypes,
                    null,
                ),
                callbackSession: durableInboundSession,
            );
            NativeCallResult nativeResult;
            if (invokeNative(request, nativeResult))
                return nativeResult.value;
        } catch (NativeCallException exception) {
            throwNativeException(exception);
        }

        throw new Exception("Unsupported eval call.");
    }

    private Value delegateReceiver(in RuntimeDelegate runtime) {
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
        if (AggregateValue.length(left) != AggregateValue.length(right))
            throw new Exception("Unsupported eval call.");

        Value[] elements;
        foreach (index; 0 .. AggregateValue.length(left))
            elements ~= AggregateValue.elementAt(left, index) +
                AggregateValue.elementAt(right, index);

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
            ? AggregateValue.length(*current)
            : cast(size_t) runExpression(slice.upr).asLong;
        if (upper - lower != elements.length)
            throw new Exception("Unsupported eval call.");

        Value[] updated;
        foreach (index; 0 .. AggregateValue.length(*current))
            updated ~= index >= lower && index < upper
                ? elements[index - lower]
                : AggregateValue.elementAt(*current, index);

        setLocal(variable, reconstructStoredArray(variable.type, updated));
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
        return loadNativePointerElement(pointerExpression.type, pointer, 0);
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
                return Value(assocArrayLength(assocArrayArgumentValue(
                    (*call.arguments)[0],
                )));

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
                return Value(assocArrayEqual(
                    assocArrayArgumentValue((*call.arguments)[0]),
                    assocArrayArgumentValue((*call.arguments)[1]),
                ));

            case dup:
                requireArgumentCount(call, 1);
                return duplicateAssocArray(assocArrayArgumentValue(
                    (*call.arguments)[0],
                ));

            case keys:
                requireArgumentCount(call, 1);
                return assocArrayKeys(assocArrayArgumentValue(
                    (*call.arguments)[0],
                ), call.type);

            case values:
                requireArgumentCount(call, 1);
                return assocArrayValues(assocArrayArgumentValue(
                    (*call.arguments)[0],
                ), call.type);

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

        const aa = assocArrayArgumentValue((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        if (isNativeAssocArray(aa)) {
            auto keySlot = nativeAssocKeySlot(nativeAssocArray(aa), key);
            auto valueAddress = nativeAssocArray(aa).valueAddress(keySlot.address);
            if (valueAddress is null)
                throw new Exception(missingKeyMessage(
                    (*call.arguments)[1],
                    (*call.arguments)[0],
                ));
            return Value.pointerValue(valueAddress);
        }

        if (!aa.assocArrayContains(key))
            throw new Exception(missingKeyMessage(
                (*call.arguments)[1],
                (*call.arguments)[0],
            ));

        throw new Exception("Associative-array read has no native value slot.");
    }

    // `aa[key] = value` lowers to a write through the slot pointer returned
    // by `_d_aaGetY(aa, key, found)`; the write-back happens via the slot
    // alias recorded for the pointer variable
    private Value runAssocArrayLvalueCall(
        imported!"dmd.expression".CallExp call,
    ) {
        auto aaArgument = (*call.arguments)[0];
        auto aa = assocArrayArgumentValue(aaArgument);
        if (aa == Value.null_) {
            import quickbite.backends.interpreter.native_assoc_array: allocateValue;

            aa = Value.nativeAggregateValue(allocateValue(
                aaArgument.type,
            ));
            auto variableExpression = aaArgument.isVarExp;
            if (variableExpression is null)
                throw new Exception("Associative-array lvalue needs a variable.");
            auto variable = variableExpression.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Associative-array lvalue needs a variable.");
            storeBinding(variable, aa);
        }
        const key = runExpression((*call.arguments)[1]);
        if (isNativeAssocArray(aa)) {
            bool found;
            auto header = nativeAssocArray(aa);
            auto keySlot = nativeAssocKeySlot(header, key);
            auto valueAddress = header.getOrAdd(keySlot.address, found);
            if (auto foundVariable = (*call.arguments)[2].isVarExp)
                if (auto variable = foundVariable.var.isVarDeclaration)
                    setLocal(variable, Value(found));
            return Value.pointerValue(valueAddress);
        }

        const contains = aa.assocArrayContains(key);

        if (auto found = (*call.arguments)[2].isVarExp)
            if (auto foundVariable = found.var.isVarDeclaration)
                setLocal(foundVariable, Value(contains));

        throw new Exception("Associative-array lvalue has no native value slot.");
    }

    private Value runAssocArrayInCall(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = assocArrayArgumentValue((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        if (isNativeAssocArray(aa)) {
            auto keySlot = nativeAssocKeySlot(nativeAssocArray(aa), key);
            auto valueAddress = nativeAssocArray(aa).valueAddress(keySlot.address);
            return valueAddress is null ? Value.null_ : Value.pointerValue(valueAddress);
        }

        if (aa.assocArrayContains(key))
            throw new Exception("Associative-array lookup has no native value slot.");
        return Value.null_;
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
        if (isNativeAssocArray(*current)) {
            auto header = nativeAssocArray(*current);
            auto keySlot = nativeAssocKeySlot(header, key);
            return Value(header.remove(keySlot.address));
        }
        const removed = current.assocArrayContains(key);
        setLocal(variable, current.withoutAssocArrayKey(key));
        return Value(removed);
    }

    private Value runAssocArrayApply2Call(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        const aa = assocArrayArgumentValue((*call.arguments)[0]);
        const keys = assocArrayKeys(aa, null);
        const values = assocArrayValues(aa, null);
        auto body = functionPointerExpressionFunction((*call.arguments)[1]);
        const delegate_ = body is null
            ? runExpression((*call.arguments)[1])
            : Value.void_;

        foreach (index; 0 .. AggregateValue.length(keys)) {
            const arguments = [
                AggregateValue.elementAt(keys, index),
                nativeArrayElementAt(values, index),
            ];
            const result = body is null
                ? runDelegateCall(delegate_, arguments, [null, null])
                : runFunction(body, arguments, [null, null], true);
            if (result.asLong != 0)
                return result;
        }

        return Value(0);
    }

    // `AggregateValue.elementAt`'s plain memory read sees a delegate-typed
    // element's zeroed bytes, not its live callable Value -- `assocArrayValues`
    // registers a live delegate entry out-of-band in `nativeDelegateSlots`,
    // keyed by the RESULT array's own element address, exactly the same gap
    // `loadNativePointerElement`'s identical `TY.Tdelegate` arm checks
    // before falling through to a plain read.
    private Value nativeArrayElementAt(in Value array, in size_t index) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        if (array.isNativeAggregate) {
            auto aggregate = AggregateValue.native(array);
            auto elementType = aggregate.type.toBasetype.nextOf;
            if (elementType !is null && elementType.toBasetype.ty == TY.Tdelegate)
                if (auto delegate_ = AggregateValue.elementAddress(array, index) in nativeDelegateSlots)
                    return *delegate_;
            return readStoredValue(Place(aggregate.address, aggregate.type).index(index));
        }
        return AggregateValue.elementAt(array, index);
    }

    private size_t assocArrayLength(in Value value) {
        return value == Value.null_
            ? 0
            : isNativeAssocArray(value)
            ? nativeAssocArray(value).length
            : value.length;
    }

    // Druntime AA hooks receive the address of the guest AA handle. A native
    // pointer therefore denotes the handle slot, not the associative-array
    // value itself; recover the typed slot before interpreting the argument.
    private Value assocArrayArgumentValue(
        imported!"dmd.expression".Expression expression,
    ) {
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        const value = runExpression(expression);
        if (!value.isPointer)
            return value;

        // This is interpreted guest storage, unlike a pointer crossing the
        // FFI seam. Read its AA handle through the ordinary typed place so
        // the result stays a NativeAggregate instead of an ABI pointer.
        return readValue(Place(
            value.pointerAddress,
            expression.type.toBasetype.nextOf,
        ));
    }

    private Value duplicateAssocArray(in Value value) {
        if (!isNativeAssocArray(value))
            return value;

        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto source = nativeAssocArray(value);
        Value[] keys;
        Value[] values;
        foreach (index; 0 .. source.length) {
            keys ~= readValue(Place(source.keyAt(index).address, source.keyType));
            values ~= readValue(Place(source.valueAt(index).address, source.valueType));
        }
        return AggregateValue.reconstructAssocArray(
            AggregateValue.native(value).type,
            keys,
            values,
        );
    }

    private bool assocArrayEqual(in Value left, in Value right) {
        if (left == Value.null_ || right == Value.null_)
            return assocArrayLength(left) == 0 && assocArrayLength(right) == 0;

        if (!isNativeAssocArray(left) || !isNativeAssocArray(right))
            return left == right;
        return equalAssocArrayValues(left, right);
    }

    private Value assocArrayKeys(in Value value, imported!"dmd.mtype".Type resultType) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (value == Value.null_) {
            Value[] keys;
            return reconstructStoredArray(resultType, keys);
        }
        if (!isNativeAssocArray(value))
            return value.assocArrayKeys;

        import dmd.mtype: TypeDArray;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto header = nativeAssocArray(value);
        Value[] keys;
        foreach (index; 0 .. header.length)
            keys ~= readValue(Place(header.keyAt(index).address, header.keyType));
        return reconstructStoredArray(
            resultType is null ? new TypeDArray(header.keyType) : resultType,
            keys,
        );
    }

    // A delegate-typed VALUE has no native ABI function address (the same
    // gap `nativeDelegateSlots`'s own field comment documents, and the
    // reason `loadNativePointerElement`'s identical `TY.Tdelegate` arm
    // checks this table before falling through to a plain memory read): the
    // entry's live callable Value lives out-of-band, keyed by the value
    // slot's own address, exactly as `runAssocArrayLvalueCall`'s
    // pointer-index write path (`storeNativePointerElement`) already
    // registers it. `AggregateValue.reconstructArray`'s `writeValue` call
    // below only ever accepts `Value.null_` for a Tdelegate element (an
    // interpreted delegate is not native-composable bytes), so every live
    // entry is substituted with `Value.null_` for the reconstruction and
    // then re-registered at the RESULT array's own element address --
    // mirroring `structLiteralValue`'s identical substitute-then-register
    // handling of a live delegate struct-literal field.
    private Value assocArrayValues(in Value value, imported!"dmd.mtype".Type resultType) {
        if (!isNativeAssocArray(value))
            return value.assocArrayValues;

        import dmd.astenums: TY;
        import dmd.mtype: TypeDArray;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto header = nativeAssocArray(value);
        const isDelegateValue = header.valueType.toBasetype.ty == TY.Tdelegate;
        Value[] values;
        size_t[] liveDelegateIndices;
        Value[] liveDelegateValues;
        foreach (index; 0 .. header.length) {
            auto address = header.valueAt(index).address;
            if (isDelegateValue)
                if (auto delegate_ = address in nativeDelegateSlots) {
                    liveDelegateIndices ~= index;
                    liveDelegateValues ~= *delegate_;
                    values ~= Value.null_;
                    continue;
                }
            values ~= readValue(Place(address, header.valueType));
        }
        auto result = reconstructStoredArray(
            resultType is null ? new TypeDArray(header.valueType) : resultType,
            values,
        );
        foreach (position, index; liveDelegateIndices)
            nativeDelegateSlots[AggregateValue.elementAddress(result, index)] =
                liveDelegateValues[position];
        return result;
    }

    private bool isNativeAssocArray(in Value value) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        return value.isNativeAggregate &&
            AggregateValue.native(value).type.toBasetype.isTypeAArray !is null;
    }

    private imported!"quickbite.backends.interpreter.native_assoc_array".NativeAssocArray* nativeAssocArray(
        in Value value,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_assoc_array: headerAt;

        return headerAt(AggregateValue.native(value).address);
    }

    private imported!"quickbite.backends.interpreter.native_block".NativeBlock nativeAssocKeySlot(
        imported!"quickbite.backends.interpreter.native_assoc_array".NativeAssocArray* header,
        in Value key,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        auto slot = NativeBlock.allocate(
            typeByteSize(header.keyType),
            typeHasPointers(header.keyType) ? NativeBlock.Scan.conservative : NativeBlock.Scan.no,
        );
        writeValue(Place(slot.address, header.keyType), key);
        return slot;
    }

    private Value runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in bool captureLocals = false,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        in void*[VarDeclaration] closureAddresses = null,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.result = Value(false);
        child.locals = (captureLocals || function_.isNested)
            ? locals.dup
            : datasegLocals;
        bindCapturedReferenceSlots(function_, child, closureAddresses);
        forkExecutionStateInto(child);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            evaluatedArguments,
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
        return child.result;
    }

    private Value nativeMemberReceiver(
        FuncDeclaration function_,
        in Value receiver,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (receiver.isNativeAggregate)
            return receiver;

        auto vthis = function_.vthis;
        if (vthis is null || !AggregateValue.isStruct(receiver))
            return receiver;

        Value[] fields;
        foreach (index; 0 .. AggregateValue.fieldCount(receiver))
            fields ~= AggregateValue.fieldAt(receiver, index);
        return AggregateValue.reconstructStruct(vthis.type, fields);
    }

    // DMD keeps a member function's hidden `this` declaration separate from
    // its ordinary argument list. A native receiver nevertheless already
    // has an exact guest address; retain it for `ref this` forwarding after
    // parameter binding (which may clear a stale entry for that declaration).
    private void bindThisReferenceAddress(
        FuncDeclaration function_,
        in Value receiver,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto vthis = function_.vthis;
        if (vthis is null)
            return;

        if (receiver.isNativeAggregate)
            nativeRefLocalAddresses[vthis] = AggregateValue.native(receiver).address;
        else if (receiver.isPointer)
            nativeRefLocalAddresses[vthis] = receiver.pointerAddress;
    }

    private Value runMemberFunction(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        in Value receiver,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments = null,
        // Set by a caller that already evaluated a `PtrExp` or `IndexExp`
        // receiver's side-effecting operand itself (to compute `receiver`
        // above) and kept the resulting address around. The `this`-rebind
        // below needs that same address; reusing it here -- instead of
        // re-deriving it from `receiverExpression` -- keeps a side-effecting
        // operand (e.g. `p()` in `p().get()`, or `i++` in `a[i++].method()`)
        // evaluated exactly once.
        const(Value)* precomputedReceiverPointerAddress = null,
    ) {
        const memberReceiver = nativeMemberReceiver(function_, receiver);

        if (declarationName(function_) == "next") {
            const(Value)* throwable = &memberReceiver;
            if (memberReceiver.isPointer)
                if (auto object = memberReceiver.pointerAddress in nativeExceptionMetadata)
                    throwable = object;
            if (
                AggregateValue.isClass(*throwable) &&
                AggregateValue.hasClassType(*throwable, "Throwable")
            ) {
                auto body = memberReceiver.isNativeAggregate
                    ? AggregateValue.nativeClassBodyAddress(memberReceiver)
                    : memberReceiver.isPointer
                    ? memberReceiver.pointerAddress
                    : null;
                if (auto next = body in nativeThrowableNext)
                    return *next;

                if (AggregateValue.hasClassFieldNamed(*throwable, "_nextInChainPtr"))
                    return AggregateValue.classFieldNamed(
                        *throwable,
                        "_nextInChainPtr",
                    );
            }
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.result = Value(false);
        child.locals = locals.dup;
        forkExecutionStateInto(child);
        // For constructor calls, DMD may blit the target variable to zero
        // before the ctor runs (e.g. `box = 0 , box.this(input)`), so the
        // receiver evaluates to a non-struct scalar.  Seed `thisValue` from
        // the struct's proper default in that case so the ctor body can write
        // fields.  When the receiver is already a valid struct (e.g.
        // MapResult created from a StructLiteralExp with elements), use it
        // as-is to preserve any hidden context fields.
        if (
            function_.isConstructorFunction &&
            !AggregateValue.isStruct(receiver)
        ) {
            auto structDecl = function_.constructorStructDeclaration;
            child.thisValue = structDecl !is null
                ? defaultValue(structDecl.type)
                : memberReceiver;
        } else {
            child.thisValue = memberReceiver;
        }
        child.hasThis = true;
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            evaluatedArguments,
        );
        child.bindThisReferenceAddress(function_, child.thisValue);
        if (
            function_.vthis !is null &&
            function_.vthis.type.toBasetype.isTypeStruct !is null &&
            isWritableLocation(receiverExpression)
        ) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.layout: typeByteSize;
            import quickbite.backends.interpreter.native_aggregate:
                NativeAggregate;
            import quickbite.backends.interpreter.native_block: NativeBlock;

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

            Value address;
            if (
                placeExpression.isThisExp !is null &&
                currentFunction !is null && currentFunction.vthis !is null
            ) {
                address = bindingPointerValue(currentFunction.vthis);
            } else if (
                placeExpression.isDotVarExp !is null &&
                placeExpression.isDotVarExp.e1.isThisExp !is null &&
                currentFunction !is null && currentFunction.vthis !is null
            ) {
                import quickbite.backends.interpreter.place: Place;

                const base = bindingPointerValue(currentFunction.vthis);
                address = Value.pointerValue(Place(
                    base.pointerAddress,
                    currentFunction.vthis.type,
                ).field(placeExpression.isDotVarExp.var.isVarDeclaration).address);
            } else if (
                (
                    placeExpression.isPtrExp !is null ||
                    placeExpression.isIndexExp !is null
                ) &&
                precomputedReceiverPointerAddress !is null
            ) {
                address = *precomputedReceiverPointerAddress;
            } else {
                address = addressOfExpression(placeExpression, EXP.address);
            }
            if (address.isPointer) {
                child.nativeRefLocalAddresses[function_.vthis] =
                    address.pointerAddress;
                child.thisValue = Value.nativeAggregateValue(NativeAggregate(
                    function_.vthis.type,
                    NativeBlock.borrow(
                        address.pointerAddress,
                        typeByteSize(function_.vthis.type),
                    ),
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

        if (function_.isConstructorFunction)
            return child.thisValue;

        return child.result;
    }

    private void mergeFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in Value[] arguments,
        in bool captureLocals = false,
    ) {
        mergeNativeThrowableRoots(child);
        mergeNativePointerRoots(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        nextClassObjectId = child.nextClassObjectId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
        borrowedNativeClassPointers = child.borrowedNativeClassPointers;
        nativeDelegateSlots = child.nativeDelegateSlots;
        nativeFunctionPointerSlots = child.nativeFunctionPointerSlots;
        nativeTypeInfoSlots = child.nativeTypeInfoSlots;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        lazyArgumentFrames = child.lazyArgumentFrames;
    }

    private void mergeMemberFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in Value[] arguments,
    ) {
        mergeNativeThrowableRoots(child);
        mergeNativePointerRoots(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        nextClassObjectId = child.nextClassObjectId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
        borrowedNativeClassPointers = child.borrowedNativeClassPointers;
        nativeDelegateSlots = child.nativeDelegateSlots;
        nativeFunctionPointerSlots = child.nativeFunctionPointerSlots;
        nativeTypeInfoSlots = child.nativeTypeInfoSlots;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        lazyArgumentFrames = child.lazyArgumentFrames;
        child.returned = false;
    }

    private void mergeNativeThrowableRoots(ref Walker child) {
        foreach (pointer, throwable; child.nativeThrowableRoots)
            nativeThrowableRoots[pointer] = throwable;
    }

    private void mergeNativePointerRoots(ref Walker child) {
        foreach (address, block; child.nativePointerRoots)
            nativePointerRoots[address] = block;
    }

    /*
    */
    private Value structValueFromCell(in Value current, ref NativeStruct cell) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        Value value = current;
        foreach (index; 0 .. cell.fieldCount) {
            auto fieldType = cell.fieldDeclaration(index).type;

            if (isNativeScalarType(fieldType)) {
                value = AggregateValue.withStructField(value, index,
                    readScalar(fieldType, cell.field(index)));
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

                auto fieldValue = AggregateValue.fieldAt(value, index);
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = cell.arrayField(index);
                foreach (elementIndex; 0 .. AggregateValue.elementCount(fieldValue)) {
                    Value elementValue;
                    if (structType !is null) {
                        auto elementCell = arrayCell.structElement(elementIndex);
                        elementValue = structValueFromCell(
                            AggregateValue.elementAt(fieldValue, elementIndex),
                            elementCell,
                        );
                    } else
                        elementValue = readScalar(
                            elementType,
                            arrayCell.element(elementIndex),
                        );
                    fieldValue = AggregateValue.withArrayElement(fieldValue,
                        elementIndex,
                        elementValue,
                    );
                }
                value = AggregateValue.withStructField(value, index, fieldValue);
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

                const fieldValue = AggregateValue.fieldAt(value, index);
                if (!AggregateValue.isArray(fieldValue))
                    continue;

                auto arrayCell = cell.sliceField(index);
                value = AggregateValue.withStructField(value,
                    index,
                    arrayValueFromCell(fieldValue, arrayCell),
                );
                continue;
            }

            auto nestedStructType = fieldType.toBasetype.isTypeStruct;
            if (nestedStructType is null || nestedStructType.sym.isUnionDeclaration !is null)
                continue;

            auto nestedValue = AggregateValue.fieldAt(value, index);
            if (!AggregateValue.isStruct(nestedValue))
                continue;

            auto nestedCell = cell.structField(index);
            value = AggregateValue.withStructField(value, index,
                structValueFromCell(nestedValue, nestedCell));
        }

        return value;
    }

    private Value[VarDeclaration] datasegLocals() {
        Value[VarDeclaration] result;
        foreach (variable, value; locals) {
            if (variable.isDataseg)
                result[variable] = value;
        }

        return result;
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

        return
            expression.isVarExp !is null ||
            expression.isDotVarExp !is null ||
            expression.isThisExp !is null ||
            expression.isIndexExp !is null ||
            expression.isPtrExp !is null;
    }

    private void bindFunctionParameters(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions = null,
        Value[VarDeclaration] callerLocals = null,
        FrameBlock callerFrame = FrameBlock.init,
        bool[VarDeclaration]* callerMirrorEstablished = null,
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
                );
                continue;
            }

            nativeRefLocalAddresses.remove(parameter);
            fallbackLocalStorage.remove(parameter);
            setLocal(parameter, arguments[index]);

            // Fills `parameter`'s own reference slot (see `frame_layout`'s
            // `FrameLayout.Slot.Kind.reference`) with the caller-side
            // address of its own argument lvalue, when there is one to
            // compose from -- `bindReferenceSlot` below declines silently
            // rather than guessing whenever it cannot. Boxed authority
            // above (`setLocal`, just called) is completely unaffected
            // either way.
            import quickbite.backends.interpreter.frame_layout:
                isReferenceParameter;
            const parameterIsReference = isReferenceParameter(
                function_,
                index,
                parameter,
            );
            if (parameterIsReference && index < argumentExpressions.length)
                bindReferenceSlot(
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
            if (parameterIsReference && arguments[index] == Value.void_)
                uninitializedLocals[parameter] = true;

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
        const(void)* evaluatedAddress,
        const(Expression) evaluatedSelectedLvalue,
        FrameBlock callerFrame,
        bool[VarDeclaration]* callerMirrorEstablished,
        in Value argumentValue,
    ) {
        import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;

        if (argumentExpression is null)
            return;

        if (evaluatedSelectedLvalue !is null)
            argumentExpression = cast(Expression) evaluatedSelectedLvalue;

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
        // survives that state because the authoritative class body is read
        // directly. The slot is still filled; only its boxed comparison
        // value may be stale.
        bool bindNotVerifiable = lvalueCrossesClassBody(argumentExpression);

        void* address = cast(void*) evaluatedAddress;
        if (address !is null) {
            _activationFrame.setReferenceSlot(parameter, address);
            nativeRefLocalAddresses[parameter] = address;
            return;
        }

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
        nativeRefLocalAddresses[parameter] = address;

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
        if (auto address = variable in nativeRefLocalAddresses) {
            bindNotVerifiable = true;
            return *address;
        }

        if (variable.isDataseg || callerFrame.hasOwningSlot(variable)) {
            const uninitializedAddress = variable.isDataseg
                ? moduleTable.storageFor(variable)
                : callerFrame.bindingAddress(variable);
            const uninitialized = uninitializedBindingAddresses !is null &&
                uninitializedAddress in uninitializedBindingAddresses.addresses;
            if (
                !uninitialized &&
                (callerMirrorEstablished is null
                    || !(*callerMirrorEstablished).get(variable, false))
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
            if (uninitialized)
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

    private void assertReferenceBind(
        VarDeclaration parameter,
        void* address,
        in Value value,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.place_value: valueMatchesPlace, writeValue;
        import quickbite.backends.interpreter.place: placeAt;
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.native_block: NativeBlock;

        if (parameter.type.toBasetype.ty == TY.Tdelegate) {
            return;
        }

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
    // Escape lifetime: a delegate created from `function_` can outlive THIS
    // activation (stored, returned, or called later). Decision 17 answers
    // this by making the frame block a GC allocation (like DMD's own
    // compiled closure frame), so a reference slot pointing into it keeps
    // that block alive the same way any other GC pointer does -- but only
    // if the ADDRESS itself survives past this activation's own return.
    // `closureAddresses`, when given (a delegate value's own
    // `RuntimeDelegate.capturedAddresses`, snapshotted at the moment the
    // delegate was created while its enclosing activation's frame was
    // still live -- see `closureCapturedAddresses`), is exactly that: it
    // takes priority per variable over re-deriving an address from `this`
    // activation's own `_activationFrame`, which is only correct when
    // `function_` is called directly while its lexically enclosing
    // activation (`this`) is still the one running -- never true once the
    // delegate has escaped and something else is calling it later.
    private void bindCapturedReferenceSlots(
        imported!"dmd.func".FuncDeclaration function_,
        ref Walker child,
        in void*[VarDeclaration] closureAddresses = null,
    ) {
        import quickbite.backends.interpreter.frame_layout: capturedVariables;

        if (!function_.isNested)
            return;

        foreach (variable; capturedVariables(function_)) {
            if (!child._activationFrame.hasReferenceSlot(variable))
                continue;

            void* address;
            if (auto closureAddress = variable in closureAddresses) {
                address = cast(void*) *closureAddress;
            } else {
                bool bindNotVerifiable;
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
            }

            if (address is null)
                continue;

            child._activationFrame.setReferenceSlot(variable, address);

            import dmd.astenums: TY;
            if (variable.type.toBasetype.ty == TY.Tdelegate)
                if (auto delegate_ = address in nativeDelegateSlots)
                    child.nativeDelegateSlots[address] = *delegate_;

            // A captured binding now borrows the caller's authoritative
            // address directly. Its boxed duplicate is only callable
            // metadata and need not byte-match the live frame slot.
        }
    }

    // A dynamic-array expression result can carry the allocation identity of
    // authoritative array storage even when its syntax is not a plain
    // variable (for example, a same-width scalar cast). Recover that storage
    // for a binding's own typed view instead of retaining only the boxed
    // element snapshot.
    private void bindLazyFunctionParameter(
        VarDeclaration parameter,
        Expression argumentExpression,
        Value[VarDeclaration] callerLocals,
        FrameBlock callerFrame,
        bool[VarDeclaration]* callerMirrorEstablished,
    ) {
        // Same fresh-binding rule as `bindFunctionParameters`: a lazy
        // parameter is still a new
        // stack slot for its own `VarDeclaration`, so drop any inherited/
        // stale cell.
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
                return;
            }
        }

        if (argumentExpression is null)
            throw new Exception("Unsupported interpreter call arguments.");

        lazyArgumentExpressions[parameter] = argumentExpression;
        lazyArgumentLocals[parameter] = callerLocals;
        lazyArgumentFrames[parameter] = callerFrame;
        lazyArgumentMirrorEstablished[parameter] = callerMirrorEstablished;
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


        auto savedLocals = locals;  // mutated below while evaluating the thunk
        auto savedFrame = _activationFrame;
        auto savedMirrorEstablished = mirrorEstablished;
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
            locals = savedLocals;
            _activationFrame = savedFrame;
            mirrorEstablished = savedMirrorEstablished;
        }

        // No `.dup`: see the comment on `bindLazyFunctionParameter`. `locals`
        // becomes the caller's own live table for the duration of the thunk,
        // and `_activationFrame` becomes the caller's own frame so a mutation
        // the thunk performs (`setLocal`) mirrors into the slot the caller
        // will actually read afterwards, instead of the callee's unrelated
        // frame silently discarding it. `mirrorEstablished` swaps through its captured pointer, so `setLocal`'s own `mirrorClassToFrame` call records its
        // write/decline decision into the CALLER's bookkeeping instead of
        // this activation's own (see `bindLazyFunctionParameter`'s header for
        // why that divergence is unsafe).
        locals = *captured;
        _activationFrame = *capturedFrame;
        mirrorEstablished = *(*capturedMirrorEstablished);
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

        const leftIsAssocArray = AggregateValue.isAssocArray(left);
        const rightIsAssocArray = AggregateValue.isAssocArray(right);
        if (
            (leftIsAssocArray && (rightIsAssocArray || right == Value.null_)) ||
            (rightIsAssocArray && left == Value.null_)
        )
            return equalAssocArrayValues(left, right);

        if (left.isFunctionPointer || right.isFunctionPointer)
            return equalDelegateValues(left, right);

        return left == right;
    }

    // A delegate compares equal to another by its runtime `{function,
    // context}` pair (D's builtin delegate equality) -- not by the internal
    // `functionPointerId` this walker mints fresh for every delegate
    // EXPRESSION evaluation. `&s1.get` evaluated twice yields two different
    // ids for the identical function+receiver, so the raw `Value == Value`
    // fallback (still correct for two Values that are literal copies of the
    // same id, e.g. plain assignment) answers unequal for the exact case D
    // requires equal. `contextPointer` already carries the receiver's own
    // binding address for a member-function delegate, not a copy
    // (`delegateContextPointer`'s `VarExp` arm resolves it the same way for
    // every delegate kind, member or closure), so comparing it directly is
    // sufficient for a NON-capturing delegate (bound method or plain
    // function pointer) -- no separate receiver-identity tracking is
    // needed there. A CAPTURING closure literal is different: every
    // literal-created delegate shares the same `contextPointer` (`Value.
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
    // runtime (a plain function pointer, never boxed into `delegates`)
    // falls back to the raw comparison unchanged.
    private bool equalDelegateValues(in Value left, in Value right) {
        if (!left.isFunctionPointer || !right.isFunctionPointer)
            return left == right;

        auto leftRuntime = left.functionPointerId in delegates;
        auto rightRuntime = right.functionPointerId in delegates;
        if (leftRuntime is null || rightRuntime is null)
            return left == right;

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

    private bool equalArrayValues(in Value left, in Value right) {
        if (AggregateValue.length(left) != AggregateValue.length(right))
            return false;

        foreach (index; 0 .. AggregateValue.length(left))
            if (!equalValues(
                arrayElementForEquality(left, index),
                arrayElementForEquality(right, index),
            ))
                return false;

        return true;
    }

    private Value arrayElementForEquality(in Value value, in size_t index) {
        import quickbite.backends.interpreter.place: Place;

        if (!value.isNativeAggregate)
            return AggregateValue.elementAt(value, index);

        auto aggregate = AggregateValue.native(value);
        return readStoredValue(
            Place(aggregate.address, aggregate.type).index(index),
        );
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
                structFieldForEquality(left, index),
                structFieldForEquality(right, index),
            ))
                return false;

        return true;
    }

    private Value structFieldForEquality(in Value value, in size_t index) {
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.place: Place;

        if (!value.isNativeAggregate)
            return AggregateValue.fieldAt(value, index);

        auto aggregate = AggregateValue.native(value);
        auto fields = structFields(aggregate.type.toBasetype.isTypeStruct);
        return readStoredValue(
            Place(aggregate.address, aggregate.type).field(fields[index]),
        );
    }

    private bool equalAssocArrayValues(in Value left, in Value right) {
        import quickbite.backends.interpreter.native_assoc_array: headerAt;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto leftHeader = left == Value.null_
            ? null
            : headerAt(AggregateValue.native(left).address);
        auto rightHeader = right == Value.null_
            ? null
            : headerAt(AggregateValue.native(right).address);
        const leftLength = leftHeader is null ? 0 : leftHeader.length;
        const rightLength = rightHeader is null ? 0 : rightHeader.length;
        if (leftLength != rightLength)
            return false;
        if (leftLength == 0)
            return true;

        foreach (index; 0 .. leftLength) {
            auto rightValueAddress = rightHeader.valueAddress(
                leftHeader.keyAt(index).address,
            );
            if (rightValueAddress is null || !equalValues(
                readValue(Place(leftHeader.valueAt(index).address, leftHeader.valueType)),
                readValue(Place(rightValueAddress, rightHeader.valueType)),
            ))
                return false;
        }

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

        if (auto field = dot.var.isVarDeclaration) {
            if (field.type.toBasetype.isTypeClass !is null)
                if (auto variableExpression = dot.e1.isVarExp)
                    if (auto variable = variableExpression.var.isVarDeclaration)
                        if (
                            hasMirrorSlot(variable) &&
                            mirrorEstablished.get(variable, false)
                        ) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            if (
                                auto typeInfo = fieldPlace.address
                                    in nativeTypeInfoSlots
                            )
                                return *typeInfo;
                        }

            auto pointerType = field.type.toBasetype.isTypePointer;
            if (
                pointerType !is null &&
                pointerType.nextOf.toBasetype.isTypeFunction !is null
            )
                if (auto variableExpression = dot.e1.isVarExp)
                    if (auto variable = variableExpression.var.isVarDeclaration)
                        if (hasMirrorSlot(variable)) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            if (auto function_ = fieldPlace.address in nativeFunctionPointerSlots)
                                return *function_;
                        }

            // `handlers[i].action`: a Tdelegate-typed field of a struct
            // ARRAY element. `AggregateValue.elementAt`'s `readValue` copies
            // the element's bytes into a fresh boxed snapshot with its own
            // (unregistered) address -- the same gap `nativeDelegateSlots`'s
            // own field comment documents -- so any live entry has to be
            // looked up against the array's own backing-storage address
            // (`runArrayAppendAssignExpression`'s own relocation keeps that
            // registration current across an append), not the copy's.
            // `runIndexExpression`'s own `out arrayIndex` overload resolves
            // the index (bounds check, `$` binding, everything) exactly
            // once; `variable in locals` is a plain map lookup, not a second
            // evaluation.
            import dmd.astenums: TY;

            if (field.type.toBasetype.ty == TY.Tdelegate)
                if (auto index = dot.e1.isIndexExp)
                    if (auto var = index.e1.isVarExp)
                        if (auto variable = var.var.isVarDeclaration) {
                            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                            import quickbite.backends.interpreter.place: Place;

                            size_t elementIndex;
                            const elementValue = runIndexExpression(index, elementIndex);
                            if (auto current = variable in locals)
                                if ((*current).isNativeAggregate) {
                                    auto elementType =
                                        AggregateValue.native(*current).type.toBasetype.nextOf;
                                    if (elementType !is null) {
                                        auto fieldPlace = Place(
                                            AggregateValue.elementAddress(*current, elementIndex),
                                            elementType,
                                        ).field(field);
                                        if (auto delegate_ = fieldPlace.address in nativeDelegateSlots)
                                            return *delegate_;
                                    }
                                }
                            return AggregateValue.fieldAt(elementValue, structFieldIndex(dot));
                        }
        }

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

        // Native dynamic arrays and associative arrays own their length in
        // typed guest storage, not in RuntimeValue's recursive carrier.
        if (
            receiver.isNativeAggregate &&
            (AggregateValue.isArray(receiver) || isNativeAssocArray(receiver)) &&
            declarationName(dot.var) == "length"
        )
            return Value(AggregateValue.length(receiver));

        if (dot.var.isVarDeclaration !is null) {
            const target = receiver.isNativeAggregate && dot.e1.type.toBasetype.isTypeClass !is null
                ? Value.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                : receiver;
            if (target.isPointer && dot.e1.type.toBasetype.isTypeClass !is null) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                auto fieldPlace = Place(target.pointerAddress, dot.e1.type)
                    .field(dot.var.isVarDeclaration);
                if (fieldPlace.type.isTypeClass !is null) {
                    if (
                        auto typeInfo = fieldPlace.address
                            in nativeTypeInfoSlots
                    )
                        return *typeInfo;
                    auto address = fieldPlace.deref.address;
                    if (address is null)
                        return Value.null_;
                    if (auto object = address in nativeClassOwners)
                        return *object;
                    return Value.pointerValue(address);
                }
                // A live delegate value has no native ABI function address
                // (the same gap `nativeDelegateSlots`'s own field comment
                // documents), so it lives out-of-band, keyed by the field's
                // own address, exactly as the struct-field read arm below
                // already checks for a mirrored local's field. A class
                // field's own address is always the object body's own
                // storage -- no mirror-slot gate needed, unlike a struct
                // local's binding, which may not have been established yet.
                if (fieldPlace.type.toBasetype.ty == TY.Tdelegate)
                    if (auto delegate_ = fieldPlace.address in nativeDelegateSlots)
                        return *delegate_;
                return readValue(fieldPlace);
            }
            if (AggregateValue.isClass(target)) {
                const fieldIndex = classFieldIndex(dot, target);

                return AggregateValue.classFieldAt(target, fieldIndex);
            }
            if (target.isNativeAggregate) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                import quickbite.backends.interpreter.place: Place;

                auto field = dot.var.isVarDeclaration;
                auto native = AggregateValue.native(target);
                auto fieldPlace = Place(native.address, native.type).field(field);
                if (
                    auto typeInfo = fieldPlace.address in nativeTypeInfoSlots
                )
                    return *typeInfo;
                if (auto variableExpression = dot.e1.isVarExp)
                    if (auto variable = variableExpression.var.isVarDeclaration)
                    if (
                        hasMirrorSlot(variable) &&
                        mirrorEstablished.get(variable, false)
                    ) {
                        auto bindingFieldPlace = bindingPlace(variable)
                            .field(field);
                        if (field.type.toBasetype.ty == TY.Tdelegate)
                            if (auto delegate_ = bindingFieldPlace.address in nativeDelegateSlots)
                                return *delegate_;
                    }
            }
            return AggregateValue.fieldAt(target, structFieldIndex(dot));
        }

        throw new Exception("Unsupported interpreter field read.");
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
        auto owner = classInfoNameOwnerExpression(ownerExpression);
        const receiver = runExpression(owner);
        if (AggregateValue.isClass(receiver))
            return Value(AggregateValue.classTypeName(receiver));

        // A native class reference is its body pointer. Its static class type
        // still supplies the ClassInfo name needed by this interpreter-only
        // property path; no boxed class object is involved.
        if (receiver.isPointer && owner.type.toBasetype.isTypeClass !is null)
            if (auto dynamicType = receiver.pointerAddress in nativeClassTypes)
                return Value(typeInfoName(*dynamicType));

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

        auto value = runExpression(expression);
        if (isClassExpression(expression))
            value = rootedNativeClassValue(expression, value);
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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: staticArrayLength;
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;

        auto staticArray = vector.to.basetype.toBasetype.isTypeSArray;
        if (staticArray is null)
            throw new Exception("Unsupported interpreter vector expression.");

        const value = runExpression(vector.e1);
        const length = staticArrayLength(staticArray);

        Value[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        const array = reconstructStoredArray(vector.to.basetype, elements);
        auto native = AggregateValue.native(array);
        return Value.nativeAggregateValue(NativeAggregate(
            vector.type,
            native.storage,
            native.retained,
        ));
    }

    private Value runVectorArrayExpression(
        imported!"dmd.expression".VectorArrayExp vectorArray,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;

        const vector = runExpression(vectorArray.e1);
        auto native = AggregateValue.native(vector);
        return Value.nativeAggregateValue(NativeAggregate(
            vectorArray.type,
            native.storage,
            native.retained,
        ));
    }

    private Value runAssignExpression(imported!"dmd.expression".BinExp assign) {
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
                        const value = defaultValue(variable);
                        writeLocation(assign.e1, value);
                        return value;
                    }
                if (assign.e1.isDotVarExp !is null) {
                    const value = defaultValue(assign.e1.type);
                    writeLocation(assign.e1, value);
                    return value;
                }
            }
        }

        // A fresh closure RHS (`c.f = (int x) => x + captured;`) is a bare
        // `FuncExp`; ordinary `runExpression` has no general case for one
        // (it answers `Value.undisplayable`) -- the same gap
        // `runDeclarationExpression`/`runIndexAssignExpression`/
        // `structLiteralValue` already route around via
        // `runFunctionLiteralDeclaration`.
        auto literal = assign.e2.isFuncExp;
        auto value = literal is null
            ? runExpression(assign.e2)
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

            // A native ref local is a borrowed place, including when its
            // referent is a class-reference slot. Assignment must update the
            // borrowed slot itself; writing the alias declaration's boxed
            // binding would give it an independent reference and leave the
            // source unchanged.
            if (referenceVariable in nativeRefLocalAddresses) {
                storeBinding(
                    referenceVariable,
                    storageValue(referenceVariable.type, value),
                );
                return;
            }

            // A bound scalar ref/out parameter, or a captured outer
            // variable (the same `Kind.reference` slot, per
            // `frame_layout`), already names its storage through this
            // activation's reference slot. Write that place directly
            // instead of allocating a parameter cell and waiting for
            // return-time writeback to make it observable.
            import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
            if (
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
                writeStoredValue(
                    place,
                    storageValue(referenceVariable.type, value),
                );
                clearUninitializedBindingAddress(
                    _activationFrame.bindingAddress(referenceVariable),
                );
                setLocal(referenceVariable, readValue(place));
                uninitializedLocals.remove(referenceVariable);
                return;
            }

            // A native extern __gshared global's memory is the single source of
            // truth (ffi.md §35.2): write through to the resolved symbol and do
            // NOT cache in `locals`, or a later native mutation would be
            // shadowed by a stale copy. The read path (§35.2a) reads the
            // native symbol's typed place on every access.
            import quickbite.frontend.dmd.functions: isExternDataSymbol;
            if (isExternDataSymbol(variable)) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: writeValue;
                import quickbite.ffi.ffi: resolveDataSymbol;

                if (auto address = resolveDataSymbol(variable)) {
                    // A writable process-memory address belonging to the loaded
                    // dependency image, so the cast to a mutable pointer is safe.
                    writeValue(
                        Place(cast(void*) address, variable.type.toBasetype),
                        storageValue(variable.type, value),
                    );
                    return;
                }
            }

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
            if (
                currentFunction !is null &&
                currentFunction.vthis !is null &&
                currentFunction.vthis in nativeRefLocalAddresses
            ) {
                storeBinding(
                    currentFunction.vthis,
                    storageValue(currentFunction.vthis.type, value),
                );
                return;
            }
            thisValue = value;
            return;
        }

        if (target.isSuperExp !is null && hasThis) {
            thisValue = value;
            return;
        }

        if (auto dot = target.isDotVarExp) {
            const receiver = runExpression(dot.e1);
            if (receiver.isNativeAggregate) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.aggregate_value: AggregateValue;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: writeValue;

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
                if (field !is null && field.type.toBasetype.ty == TY.Tdelegate) {
                    if (auto variableExpression = dot.e1.isVarExp)
                        if (auto variable = variableExpression.var.isVarDeclaration)
                        if (
                            hasMirrorSlot(variable) &&
                            mirrorEstablished.get(variable, false)
                        ) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            nativeDelegateSlots[fieldPlace.address] = value;
                            writeValue(fieldPlace, Value.null_);
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
                        if (
                            hasMirrorSlot(variable) &&
                            mirrorEstablished.get(variable, false)
                        ) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            nativeFunctionPointerSlots[fieldPlace.address] = value;
                            fieldPlace.storeReference(null);
                            return;
                        }
                }
            }
            const nativeClassReceiver = receiver.isPointer
                ? receiver
                : receiver.isNativeAggregate && dot.e1.type.toBasetype.isTypeClass !is null
                ? Value.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                : Value.null_;
            if (
                nativeClassReceiver.isPointer &&
                dot.e1.type.toBasetype.isTypeClass !is null
            ) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: writeValue;

                auto field = dot.var.isVarDeclaration;
                auto fieldPlace = Place(nativeClassReceiver.pointerAddress, dot.e1.type)
                    .field(field);
                // A live delegate value (an interpreted closure, not `null`)
                // has no native ABI function address, so `place_value.
                // writeValue`'s Tdelegate arm only ever accepts `null` --
                // register it out-of-band in `nativeDelegateSlots`, keyed by
                // the field's own address, mirroring the struct-field write
                // arm above. A class field's address is the object body's
                // own storage, live for the object's whole lifetime, so no
                // mirror-slot gate is needed the way a struct local's
                // binding requires.
                if (field !is null && field.type.toBasetype.ty == TY.Tdelegate) {
                    nativeDelegateSlots[fieldPlace.address] = value;
                    writeValue(fieldPlace, Value.null_);
                    return;
                }
                writeStoredValue(fieldPlace, value);
                return;
            }

            if (receiver.isClassObject) {
                const fieldIndex = classFieldIndex(dot, receiver);

                const authoritative = receiver;

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
            if (
                receiver.isNativeAggregate &&
                AggregateValue.isArray(receiver) &&
                declarationName(dot.var) == "length"
            ) {
                writeLocation(
                    dot.e1,
                    AggregateValue.reconstructNativeArrayWithLength(
                        dot.e1.type,
                        cast(size_t) value.asLong,
                        AggregateValue.nativeArrayAddress(receiver),
                    ),
                );
                return;
            }

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
            const pointer = runExpression(ptr.e1);
            // A dereferenced native pointer (e.g. a malloc'd struct like
            // std.stdio.File's Impl): write straight into native memory.
            if (pointer.isPointer) {
                // `*&p` keeps DMD's ref-argument lvalue shape, but the
                // pointer still names `p`'s own established frame slot. Keep
                // that local's expression mirror coherent with the direct
                // native store; otherwise its next read detects a real
                // frame/local divergence.
                if (auto local = mirroredNativePointerLocal(pointer, ptr.e1.type)) {
                    storeBinding(local, storageValue(local.type, value));
                    return;
                }
                storeNativePointerElement(ptr.e1.type, pointer, 0, value);
                return;
            }

            throw new Exception("Unsupported non-native data pointer.");
        }

        import std.conv: text;
        throw new Exception(
            text("Unsupported interpreter assignment target: ", target.op),
        );
    }

    private VarDeclaration mirroredNativePointerLocal(
        in Value pointer,
        imported!"dmd.mtype".Type pointerType,
    ) {
        if (pointerType is null || pointerType.toBasetype.isTypePointer is null)
            return null;

        auto pointee = pointerType.toBasetype.nextOf;
        foreach (variable, _; locals) {
            if (
                !hasMirrorSlot(variable) ||
                !mirrorEstablished.get(variable, false) ||
                mirrorAddress(variable) != pointer.pointerAddress ||
                !variable.type.toBasetype.equals(pointee.toBasetype)
            )
                continue;
            return variable;
        }
        return null;
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
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
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
                    isReferenceParameter(
                        function_,
                        index,
                        (*function_.parameters)[index],
                    )
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
        forkExecutionStateInto(child);
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
            evaluatedArguments,
        );
        if (function_.vthis !is null) {
            import dmd.tokens: EXP;

            const receiverAddress = addressOfExpression(dot.e1, EXP.address);
            if (receiverAddress.isPointer) {
                child.nativeRefLocalAddresses[function_.vthis] =
                    receiverAddress.pointerAddress;
                if (function_.vthis.type.toBasetype.isTypeStruct !is null) {
                    import quickbite.backends.interpreter.layout: typeByteSize;
                    import quickbite.backends.interpreter.native_aggregate:
                        NativeAggregate;
                    import quickbite.backends.interpreter.native_block:
                        NativeBlock;

                    child.thisValue = Value.nativeAggregateValue(NativeAggregate(
                        function_.vthis.type,
                        NativeBlock.borrow(
                            receiverAddress.pointerAddress,
                            typeByteSize(function_.vthis.type),
                        ),
                    ));
                }
            }
        }

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
        in Value value,
    ) {
        import dmd.funcsem: functionSemantic3;
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;
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
                    isReferenceParameter(
                        call.f,
                        index,
                        (*call.f.parameters)[index],
                    )
                    ? runRefArgumentExpression(argument, evaluated)
                    : runExpression(argument);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
            }

        if (hasNoAvailableSource(call.f)) {
            import quickbite.backends.interpreter.native_call_adapter:
                NativeCallException, NativeCallResult;
            import quickbite.backends.interpreter.place: Place;

            try {
                NativeCallResult nativeResult;
                if (!invokeNativeDeclaration(
                    call.f,
                    Value.void_,
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
                    Place(nativeResult.referenceAddress, returnType),
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
        child.result = Value(false);
        child.locals = call.f.isNested ? locals.dup : datasegLocals;
        bindCapturedReferenceSlots(call.f, child);
        forkExecutionStateInto(child);
        child.bindFunctionParameters(
            call.f,
            arguments,
            argumentExpressions,
            locals,
            _activationFrame,
            &mirrorEstablished,
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
        in Value value,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.frontend.dmd.types: arrayElementType;

        const current = runExpression(target.e1);
        const oldLength = current == Value.null_ ? 0 : AggregateValue.length(current);
        const newLength = cast(size_t) value.asLong;

        Value[] elements;
        foreach (index; 0 .. newLength)
            elements ~= index < oldLength
                ? AggregateValue.elementAt(current, index)
                : runDefaultValue(arrayElementType(target.e1.type));

        writeLocation(target.e1, reconstructStoredArray(target.e1.type, elements));
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

    private void writeIndexLocation(
        imported!"dmd.expression".IndexExp index,
        in Value value,
    ) {
        import quickbite.frontend.dmd.types: isPointerType;

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;

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
        if (isPointerType(index.e1.type)) {
            const pointer = runExpression(index.e1);
            if (pointer.isPointer) {
                storeNativePointerElement(index.e1.type, pointer, arrayIndex, value);
                return;
            }
            throw new Exception("Pointer index assignment needs a native address.");
        }

        // `(*p)[i] = v`: `index.e1` is itself a dereference (`p`'s pointee
        // is the static array being indexed, e.g. `int[3]*`), not a
        // variable/field lvalue. `&(*p)` recovers `p`'s own address
        // (`addressOfExpression`'s identical `PtrExp` arm); index directly
        // into the pointee's bytes at that address rather than through a
        // binding, matching the `nativeRefLocalAddresses` arm below for a
        // `ref` static-array alias.
        if (auto derefBase = index.e1.isPtrExp) {
            const pointer = runExpression(derefBase.e1);
            if (pointer.isPointer) {
                import quickbite.backends.interpreter.place: Place;

                writeStoredValue(
                    Place(pointer.pointerAddress, index.e1.type).index(arrayIndex),
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

            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const fieldValue = AggregateValue.fieldAt(receiver, fieldIndex);
            const outerIndex = cast(size_t) runExpression(outer.e2).asLong;
            checkStaticArrayIndexInBounds(fieldValue, outerIndex);
            const outerElement = AggregateValue.elementAt(fieldValue, outerIndex);
            checkStaticArrayIndexInBounds(outerElement, arrayIndex);
            const updatedField = AggregateValue.withArrayElement(
                fieldValue,
                outerIndex,
                AggregateValue.withArrayElement(outerElement, arrayIndex, value),
            );
            writeLocation(dot.e1, AggregateValue.withStructField(receiver, fieldIndex, updatedField));
            return;
        }

        if (auto dot = index.e1.isDotVarExp) {
            if (receiverClassType(dot.e1) !is null) {
                const receiver = runExpression(dot.e1);
                // A class local's own runtime value is commonly a bare
                // pointer to the object body, not a `NativeAggregate` --
                // `AggregateValue.classFieldAt`/`withClassField` only
                // special-case the latter and otherwise fall through to
                // `Value.classFieldAt`'s boxed-class-object arm, throwing
                // "Expected class object." for a bare pointer (the same
                // hazard `runIndexAssignExpression`'s identical `DotVarExp`/
                // class arm already closes for the simple-assignment shape
                // `c.arr[i] = v`). Resolve the field's `Place` directly
                // through the pointer instead and write the updated array
                // back through it, covering this compound/element-of-
                // class-array-field shape (`c.arr[i].field = v`) the same
                // way.
                const nativeClassReceiver = receiver.isPointer
                    ? receiver
                    : receiver.isNativeAggregate
                    ? Value.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                    : Value.null_;
                if (nativeClassReceiver.isPointer) {
                    import quickbite.backends.interpreter.place: Place;
                    import quickbite.backends.interpreter.place_value: readValue, writeValue;

                    auto fieldPlace = Place(nativeClassReceiver.pointerAddress, dot.e1.type)
                        .field(dot.var.isVarDeclaration);
                    const source = readValue(fieldPlace);
                    const updatedArray = AggregateValue.withArrayElement(source, arrayIndex, value);
                    writeValue(fieldPlace, updatedArray);
                    return;
                }

                const fieldIndex = classFieldIndex(dot, receiver);
                // Same stale-receiver hazard `writeLocation`'s `DotVarExp`
                // arm closes -- re-derive from the shared cell before folding
                // in this element's write.
                const authoritative = receiver;
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
            return;
        }

        auto var = index.e1.isVarExp;
        if (var is null)
            throw new Exception("Unsupported interpreter assignment target.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported interpreter assignment target.");

        // Keep the declaration node for a native `ref` binding.  Unlike a
        // local-pointer alias, it has no reverse-map identity to resolve:
        // its declaration carries the source frame address recorded when it
        // was bound.
        auto referenceVariable = variable;

        // A plain `ref` static-array local has no independent element
        // storage. Resolve its lvalue before rebuilding the array so direct
        // `alias_[i] = value` updates the source binding, exactly as an
        // element address through the same alias does.

        if (auto address = referenceVariable in nativeRefLocalAddresses) {
            import quickbite.backends.interpreter.place: Place;

            writeStoredValue(
                Place(*address, referenceVariable.type).index(arrayIndex),
                value,
            );
            uninitializedLocals.remove(referenceVariable);
            return;
        }

        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        setLocal(variable, AggregateValue.withArrayElement(*current, arrayIndex, value));
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

    private Value withUnionFieldWrite(
        in Value receiver,
        imported!"dmd.mtype".TypeStruct unionType,
        in size_t fieldIndex,
        in Value value,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.layout: structFields;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar, writeScalar;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        auto fields = structFields(unionType);
        if (fieldIndex >= fields.length)
            throw new Exception("Unsupported interpreter union field access.");
        const symbolicValue = value.isTypeName ||
            value.isFunctionPointer ||
            (fields[fieldIndex].type.toBasetype.ty == TY.Tdelegate &&
                value != Value.null_);
        auto updated = AggregateValue.withStructField(
            receiver,
            fieldIndex,
            symbolicValue ? Value.null_ : value,
        );

        auto writtenType = fields[fieldIndex].type;
        const writtenScalar = isNativeScalarType(writtenType);
        auto writtenStructType = writtenType.toBasetype.isTypeStruct;
        const writtenStruct = writtenStructType !is null
            && writtenStructType.sym.isUnionDeclaration is null;
        const writtenArray = isStaticArrayType(writtenType)
            && isNativeScalarType(writtenType.toBasetype.nextOf.toBasetype)
            && value.isArray;

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

        return withUnionStoredField(
            receiver,
            unionType,
            fieldIndex,
            value,
            updated,
        );
    }

    private Value withUnionStoredField(
        in Value receiver,
        imported!"dmd.mtype".TypeStruct unionType,
        in size_t fieldIndex,
        in Value value,
        in Value updated,
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
        import quickbite.frontend.dmd.types: isPointerType, isStaticArrayType;

        if (isPointerType(index.e1.type)) {
            const pointer = runExpression(index.e1);
            const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
            if (pointer.isPointer) {
                auto literal = rhs.isFuncExp;
                const value = literal is null
                    ? runExpression(rhs)
                    : runFunctionLiteralDeclaration(literal);
                storeNativePointerElement(index.e1.type, pointer, arrayIndex, value);
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
            const pointer = runExpression(derefBase.e1);
            if (pointer.isPointer) {
                import quickbite.backends.interpreter.place: Place;

                const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
                const value = runExpression(rhs);
                writeStoredValue(
                    Place(pointer.pointerAddress, index.e1.type).index(arrayIndex),
                    value,
                );
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
            // unsupported. Checked via the STATIC receiver type
            // (`receiverClassType`), mirroring `writeLocation`'s own
            // `DotVarExp` arm's `isClassObject` dispatch.
            if (receiverClassType(dot.e1) !is null) {
                const receiver = runExpression(dot.e1);
                const nativeClassReceiver = receiver.isPointer
                    ? receiver
                    : receiver.isNativeAggregate
                    ? Value.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                    : Value.null_;
                if (nativeClassReceiver.isPointer) {
                    import quickbite.backends.interpreter.place: Place;

                    auto fieldPlace = Place(nativeClassReceiver.pointerAddress, dot.e1.type)
                        .field(dot.var.isVarDeclaration);
                    const source = readStoredValue(fieldPlace);
                    if (index.lengthVar !is null)
                        setLocal(index.lengthVar, Value(AggregateValue.length(source)));
                    const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
                    const value = runExpression(rhs);
                    writeStoredValue(fieldPlace.index(arrayIndex), value);
                    return value;
                }
                const fieldIndex = classFieldIndex(dot, receiver);
                // Same stale-receiver hazard `writeLocation`'s `DotVarExp`
                // arm closes -- re-derive from the shared cell before folding
                // in this element's write.
                const authoritative = receiver;
                const source = AggregateValue.classFieldAt(authoritative, fieldIndex);
                if (index.lengthVar !is null)
                    setLocal(index.lengthVar, Value(AggregateValue.length(source)));
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
                setLocal(index.lengthVar, Value(AggregateValue.length(source)));
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


        auto current = variable in locals;
        if (current is null)
            throw new Exception("Unsupported interpreter assignment target.");

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
        if (isStaticArrayType(index.e1.type))
            checkStaticArrayIndexInBounds(*current, arrayIndex);

        // A fresh closure RHS (`dgs[0] = () => 1;`) is a bare `FuncExp`;
        // ordinary `runExpression` has no general case for one (it answers
        // `Value.undisplayable`) -- the same gap this module's other
        // delegate-write call sites already route around via
        // `runFunctionLiteralDeclaration`.
        auto literal = rhs.isFuncExp;
        const value = literal is null
            ? runExpression(rhs)
            : runFunctionLiteralDeclaration(literal);

        // A live delegate element has no native ABI function address --
        // `place_value.writeValue`'s Tdelegate arm only ever accepts
        // `Value.null_` -- so substitute null bytes for the write and
        // register the live value out-of-band in `nativeDelegateSlots`,
        // keyed by the element's own address, mirroring the append and
        // struct/class-field write sites.
        import dmd.astenums: TY;

        auto elementType = index.e1.type.toBasetype.nextOf;
        const isLiveDelegate = elementType !is null
            && elementType.toBasetype.ty == TY.Tdelegate
            && value != Value.null_;
        auto storedValue = isLiveDelegate ? Value.null_ : value;
        if (
            (*current).isNativeAggregate &&
            canContainStoredMetadata(elementType)
        ) {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
            import quickbite.backends.interpreter.place: Place;

            auto destination = hasMirrorSlot(variable) &&
                mirrorEstablished.get(variable, false)
                ? bindingPlace(variable).index(arrayIndex)
                : Place(
                    AggregateValue.native(*current).address,
                    AggregateValue.native(*current).type,
                ).index(arrayIndex);
            writeStoredValue(destination, storedValue);
            if (isLiveDelegate)
                nativeDelegateSlots[destination.address] = value;
            uninitializedLocals.remove(variable);
            return value;
        }
        setLocal(variable, AggregateValue.withArrayElement(*current, arrayIndex, storedValue));
        writeThroughArrayCell(variable, arrayIndex, storedValue);
        if (isLiveDelegate)
            nativeDelegateSlots[bindingPlace(variable).index(arrayIndex).address] = value;
        uninitializedLocals.remove(variable);
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
        in Value array,
        in size_t index,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.messages: indexOutOfBoundsMessage;

        const length = AggregateValue.length(array);
        if (index >= length)
            throwRangeError(indexOutOfBoundsMessage(
                index,
                length,
                /* isSlice */ false,
                /* runningCalledFunction */ true,
            ));
    }

    private void writeThroughArrayCell(
        VarDeclaration variable,
        in size_t index,
        in Value value,
    ) {
        import quickbite.backends.interpreter.place: Place;

        if (auto address = variable in nativeRefLocalAddresses) {
            writeStoredValue(Place(*address, variable.type).index(index), value);
            return;
        }

        if (hasMirrorSlot(variable) && mirrorEstablished.get(variable, false))
            writeStoredValue(bindingPlace(variable).index(index), value);
    }

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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_scalar: writeScalar;

        if (!AggregateValue.isArray(arrayValue))
            return;

        foreach (index; 0 .. cell.length) {
            if (index >= AggregateValue.elementCount(arrayValue))
                continue;

            if (cell.elementType.isTypeSArray) {
                // Mutable because recursive write takes the view by ref.
                auto elementCell = cell.arrayElement(index);
                writeStaticArrayCellScalarElements(
                    elementCell,
                    AggregateValue.elementAt(arrayValue, index),
                );
            } else {
                writeScalar(
                    cell.elementType,
                    cell.element(index),
                    AggregateValue.elementAt(arrayValue, index),
                );
            }
        }
    }

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
        return arrayValueFromCell(cell);
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

    private Value runNestedIndexAssignExpression(
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
        // directly instead of the `locals`-keyed array rebuild below, which
        // has no pointer-typed base at all.
        import quickbite.frontend.dmd.types: isPointerType, isStaticArrayType;

        if (isPointerType(outer.e1.type)) {
            import quickbite.backends.interpreter.place: Place;

            const pointer = runExpression(outer.e1);
            if (!pointer.isPointer)
                throw new Exception("Unsupported interpreter assignment target.");

            const innerIndex = cast(size_t) runExpression(inner.e2).asLong;
            const value = runExpression(rhs);
            writeStoredValue(
                Place(pointer.pointerAddress, outer.type).index(innerIndex),
                value,
            );
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
        // local's own runtime value is commonly a bare pointer to the
        // object body (`receiver.isPointer`), not a `NativeAggregate`
        // (`receiver.isNativeAggregate`) -- `AggregateValue.classFieldAt`/
        // `withClassField` only special-case the latter and otherwise fall
        // through to `Value.classFieldAt`'s boxed-class-object arm, which
        // threw "Expected class object." for a bare pointer. Resolve the
        // field's `Place` directly through the pointer instead, the same
        // `nativeClassReceiver`/`fieldPlace` composition
        // `runIndexAssignExpression`'s singly-indexed `DotVarExp`/class arm
        // already uses, and write the whole updated field back through that
        // same `Place` -- a class body's storage is its own host address, so
        // there is no separate receiver lvalue to rebind the way a struct's
        // (possibly boxed) local binding needs.
        if (auto dot = outer.e1.isDotVarExp) {
            if (receiverClassType(dot.e1) !is null) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue, writeValue;

                const receiver = runExpression(dot.e1);
                const nativeClassReceiver = receiver.isPointer
                    ? receiver
                    : receiver.isNativeAggregate
                    ? Value.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                    : Value.null_;
                if (!nativeClassReceiver.isPointer)
                    throw new Exception("Unsupported interpreter assignment target.");

                auto fieldPlace = Place(nativeClassReceiver.pointerAddress, dot.e1.type)
                    .field(dot.var.isVarDeclaration);
                const fieldValue = readValue(fieldPlace);
                const outerIndex = cast(size_t) runExpression(outer.e2).asLong;
                checkStaticArrayIndexInBounds(fieldValue, outerIndex);
                const outerElement = AggregateValue.elementAt(fieldValue, outerIndex);
                const innerIndex = cast(size_t) runExpression(inner.e2).asLong;
                checkStaticArrayIndexInBounds(outerElement, innerIndex);
                const value = runExpression(rhs);
                const updatedField = AggregateValue.withArrayElement(
                    fieldValue,
                    outerIndex,
                    AggregateValue.withArrayElement(outerElement, innerIndex, value),
                );
                writeValue(fieldPlace, updatedField);
                return value;
            }

            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const fieldValue = AggregateValue.fieldAt(receiver, fieldIndex);
            const outerIndex = cast(size_t) runExpression(outer.e2).asLong;
            checkStaticArrayIndexInBounds(fieldValue, outerIndex);
            const outerElement = AggregateValue.elementAt(fieldValue, outerIndex);
            const innerIndex = cast(size_t) runExpression(inner.e2).asLong;
            checkStaticArrayIndexInBounds(outerElement, innerIndex);
            const value = runExpression(rhs);
            const updatedField = AggregateValue.withArrayElement(
                fieldValue,
                outerIndex,
                AggregateValue.withArrayElement(outerElement, innerIndex, value),
            );
            writeLocation(dot.e1, AggregateValue.withStructField(receiver, fieldIndex, updatedField));
            return value;
        }

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
        if (isStaticArrayType(outer.e1.type))
            checkStaticArrayIndexInBounds(*current, outerIndex);
        const outerElement = AggregateValue.elementAt(*current, outerIndex);
        const innerIndex = cast(size_t) runExpression(inner.e2).asLong;
        if (isStaticArrayType(inner.e1.type))
            checkStaticArrayIndexInBounds(outerElement, innerIndex);
        const value = runExpression(rhs);
        setLocal(variable, AggregateValue.withArrayElement(*current,
            outerIndex,
            AggregateValue.withArrayElement(outerElement, innerIndex, value),
        ));
        const updatedOuter = AggregateValue.elementAt(locals[variable], outerIndex);
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
            if (auto index = slice.e1.isIndexExp)
                return runIndexedSliceAssignExpression(slice, index, rhs);
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
        if (current is null) {
            // A `T t = void;` local (e.g. `std.algorithm.mutation.swap`'s
            // raw-byte fallback `ubyte[T.sizeof] t = void;`) never runs
            // `setLocal` at its declaration -- there is no meaningful value
            // to shadow -- so it has no boxed local yet the first time it is
            // used as a slice-assignment target. Compiled D leaves its bytes
            // unspecified until written; materialising the ordinary default
            // here is observably identical for the whole-range overwrite
            // (`t[] = ...`) idiom this local exists for, and is no less
            // defined than compiled D for a genuine partial write to
            // still-uninitialized bytes.
            if ((variable in uninitializedLocals) is null)
                throw new Exception(
                    "Unsupported interpreter assignment target: slice of unset local.",
                );

            setLocal(variable, defaultLocalValue(variable));
            if (hasMirrorSlot(variable))
                clearUninitializedBindingAddress(bindingPlace(variable).address);
            uninitializedLocals.remove(variable);
            current = variable in locals;
        }

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? AggregateValue.length(*current)
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
        if (upper > AggregateValue.length(*current))
            throwRangeError(text(
                "slice [", lower, " .. ", upper,
                "] extends past source array of length ", AggregateValue.length(*current),
            ));

        rejectOverlappingSliceAssignment(
            variable,
            rhs,
            lower,
            upper,
            AggregateValue.length(*current),
        );

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
        foreach (index; 0 .. AggregateValue.length(*current))
            elements ~= index < lower || index >= upper
                ? AggregateValue.elementAt(*current, index)
                : block ? copyArrayValue(value, variable.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? AggregateValue.elementAt(value, index - lower)
                    : value;

        if (current.isNativeAggregate) {
            import quickbite.backends.interpreter.place: Place;

            auto destination = Place(AggregateValue.native(*current).address,
                variable.type);
            foreach (index; lower .. upper)
                writeStoredValue(destination.index(index), elements[index]);
        } else {
            setLocal(variable, reconstructStoredArray(variable.type, elements));
        }
        uninitializedLocals.remove(variable);

        foreach (index; lower .. upper)
            writeThroughArrayCell(variable, index, elements[index]);

        return value;
    }

    // An indexed array-of-arrays element is already an independently
    // addressable slice header.  Keep that native header and write its
    // elements in place; rebuilding its enclosing array would restore the
    // retired boxed-storage authority for this lvalue shape.
    private Value runIndexedSliceAssignExpression(
        imported!"dmd.expression".SliceExp slice,
        imported!"dmd.expression".IndexExp index,
        imported!"dmd.expression".Expression rhs,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import std.conv: text;

        const current = runIndexExpression(index);
        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? AggregateValue.length(current)
            : cast(size_t) runExpression(slice.upr).asLong;

        if (upper > AggregateValue.length(current))
            throwRangeError(text(
                "slice [", lower, " .. ", upper,
                "] extends past source array of length ", AggregateValue.length(current),
            ));

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);
        foreach (elementIndex; lower .. upper) {
            const element = block
                ? copyArrayValue(value, index.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? AggregateValue.elementAt(value, elementIndex - lower)
                    : value;
            AggregateValue.withArrayElement(current, elementIndex, element);
        }
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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
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
            return block
                ? copyArrayValue(value, slice.type.toBasetype.nextOf)
                : AggregateValue.elementAt(value, index);
        }

        if (pointer.isPointer) {
            foreach (index; 0 .. upper - lower)
                storeNativePointerElement(
                    slice.e1.type,
                    pointer,
                    lower + index,
                    elementAt(index),
                );
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
            ? AggregateValue.length(current)
            : cast(size_t) runExpression(slice.upr).asLong;

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);

        Value[] elements;
        foreach (index; 0 .. AggregateValue.length(current))
            elements ~= index < lower || index >= upper
                ? AggregateValue.elementAt(current, index)
                : block ? copyArrayValue(value, slice.type.toBasetype.nextOf)
                : AggregateValue.elementAt(value, index - lower);

        writeLocation(dot.e1, AggregateValue.withStructField(receiver,
            fieldIndex,
            reconstructStoredArray(dot.var.type, elements),
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

    private Value copyArrayValue(
        in Value value,
        imported!"dmd.mtype".Type type,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        Value[] elements;
        foreach (index; 0 .. AggregateValue.length(value))
            elements ~= AggregateValue.elementAt(value, index);

        return value.isNativeAggregate
            ? reconstructStoredArray(AggregateValue.native(value).type, elements)
            : reconstructStoredArray(type, elements);
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
            elements ~= index < AggregateValue.length(*current)
                ? AggregateValue.elementAt(*current, index)
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
        writeLocation(var, reconstructStoredArray(variable.type, elements));
        return lengthValue;
    }

    private Value runConcatenateExpression(imported!"dmd.expression".CatExp cat) {
        return reconstructStoredArray(
            cat.type,
            concatenationElements(cat.type, cat.e1) ~
                concatenationElements(cat.type, cat.e2),
        );
    }

    private Value[] concatenationElements(
        imported!"dmd.mtype".Type resultType,
        imported!"dmd.expression".Expression operand,
    ) {
        import quickbite.frontend.dmd.types: isArrayType;

        const value = runExpression(operand);
        if (!isArrayType(operand.type))
            return nativeAppendElements(resultType, value);

        Value[] elements;
        foreach (index; 0 .. AggregateValue.elementCount(value))
            elements ~= AggregateValue.elementAt(value, index);

        return elements;
    }

    private Value runArrayAppendAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (auto dot = assign.e1.isDotVarExp) {
            const appended = AggregateValue.withAppendedArrayElement(
                runExpression(assign.e1),
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

        auto literal = assign.e2.isFuncExp;
        const value = literal is null
            ? runExpression(assign.e2)
            : runFunctionLiteralDeclaration(literal);
        if ((*current).isNativeAggregate) {
            import dmd.astenums: TY;

            // A nested foreach body receives a copied `locals` root for a
            // captured slice.  The frame/reference slot is the authority, so
            // begin each append from its current header instead of that stale
            // root; otherwise every iteration rebinds from the initial slice
            // and only the last appended character survives.
            auto appended = runExpression(assign.e1);
            auto elementType = variable.type.toBasetype.isTypeDArray !is null
                ? variable.type.toBasetype.isTypeDArray.next
                : null;
            foreach (rawElement; nativeAppendElements(variable.type, value)) {
                const index = AggregateValue.elementCount(appended);
                const previous = appended;
                // The appended element itself may be a live delegate value
                // (a fresh closure or a copied delegate local), which has no
                // native ABI function address -- `place_value.writeValue`'s
                // Tdelegate arm only ever accepts `Value.null_`. Substitute
                // null bytes for the write and register the live value
                // out-of-band in `nativeDelegateSlots`, keyed by the newly
                // appended element's own address, mirroring the sub-field
                // relocation below and `structLiteralValue`'s identical
                // substitute-then-register handling.
                const isLiveDelegate = elementType !is null
                    && elementType.toBasetype.ty == TY.Tdelegate
                    && rawElement != Value.null_;
                auto element = isLiveDelegate ? Value.null_ : rawElement;
                appended = AggregateValue.withAppendedArrayElement(appended, element);
                if (elementType !is null)
                    relocatePriorAppendedElementSlots(elementType, previous, appended, index);
                if (isLiveDelegate) {
                    nativeDelegateSlots[
                        AggregateValue.elementAddress(appended, index)
                    ] = rawElement;
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
            uninitializedLocals.remove(variable);
            return locals[variable];
        }
        setLocal(variable, current.withAppendedArrayElement(value));
        uninitializedLocals.remove(variable);

        return locals[variable];
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
    // (`previous`) and after (`appended`) this iteration's append, and if
    // it moved, relocate every one of `previous`'s `count` elements from
    // its old per-element address to its corresponding new one --
    // `copyStoredMetadata` carries every symbolic entry in each element's
    // byte range, including entries in nested structs and static arrays. The
    // old registrations remain because another live slice may still alias
    // the old allocation.
    private void relocatePriorAppendedElementSlots(
        imported!"dmd.mtype".Type elementType,
        in Value previous,
        in Value appended,
        in size_t count,
    ) {
        import quickbite.backends.interpreter.place: Place;

        if (count == 0)
            return;

        auto previousAggregate = AggregateValue.native(previous);
        auto appendedAggregate = AggregateValue.native(appended);
        const oldData = Place(previousAggregate.address, previousAggregate.type)
            .sliceDataPointer;
        const newData = Place(appendedAggregate.address, appendedAggregate.type)
            .sliceDataPointer;
        if (oldData is newData)
            return;

        foreach (i; 0 .. count)
            copyStoredMetadata(
                elementType,
                AggregateValue.elementAddress(previous, i),
                AggregateValue.elementAddress(appended, i),
            );
    }

    // Appending a wide character to `string` writes its UTF-8 code units,
    // not the low byte of the code point.  The boxed append path happened to
    // preserve that conversion through its string representation; native
    // element writes require spelling it out before storing char-sized slots.
    private Value[] nativeAppendElements(
        imported!"dmd.mtype".Type arrayType,
        in Value value,
    ) {
        import dmd.astenums: TY;

        auto array = arrayType.toBasetype.isTypeDArray;
        if (array is null || array.next.toBasetype.ty != TY.Tchar || !value.isCharacter)
            return [value];

        Value[] elements;
        foreach (character; value.asUtf8Character)
            elements ~= Value(character);
        return elements;
    }

    private Value runArrayConcatenateAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (assign.e1.isDotVarExp !is null) {
            const concatenated = reconstructStoredArray(
                assign.e1.type,
                concatenationElements(assign.e1.type, assign.e1) ~
                    concatenationElements(assign.e1.type, assign.e2),
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

            const concatenated = reconstructStoredArray(
                assign.e1.type,
                concatenationElements(assign.e1.type, assign.e1) ~
                    concatenationElements(assign.e1.type, assign.e2),
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
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;
            import quickbite.backends.interpreter.layout: typeByteSize;

            const value = runExpression(cast_.e1);
            if (AggregateValue.isArray(value) &&
                AggregateValue.nativeArrayAddress(value) !is null)
                return AggregateValue.reconstructNativeArrayWithLength(
                    cast_.to,
                    AggregateValue.length(value) * typeByteSize(
                        cast_.e1.type.toBasetype.nextOf,
                    ),
                    AggregateValue.nativeArrayAddress(value),
                );
            return value;
        }

        if (isTransparentArrayCastTarget(type)) {
            Value reinterpreted;
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

                const source = runExpression(cast_.e1);
                if (source.isNativeAggregate)
                    return AggregateValue.slice(
                        source, cast_.to, 0, AggregateValue.length(source),
                    );
            }

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
        if (source.isNativeAggregate) {
            result = AggregateValue.reconstructNativeArrayWithLength(
                cast_.to,
                AggregateValue.length(source),
                AggregateValue.nativeArrayAddress(source),
            );
            return true;
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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const value = runExpression(cast_.e1);
        if (value.isPointer)
            return Value(true);
        if (value == Value.null_)
            return Value(false);
        if (value.isNativeAggregate && AggregateValue.isArray(value))
            return Value(isTruthy(value));

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
        auto value = runExpression(cast_.e1);
        value = rootedNativeClassValue(cast_.e1, value);
        if (value.isPointer)
            if (auto dynamicType = value.pointerAddress in nativeClassTypes)
                value = AggregateValue.borrowClass(
                    *dynamicType,
                    value.pointerAddress,
                );
        if (value.isPointer) {
            if (auto owner = value.pointerAddress in nativeClassOwners) {
                value = *owner;
            } else if (
                auto metadata = value.pointerAddress in nativeExceptionMetadata
            ) {
                value = *metadata;
            }
        }
        if (value == Value.null_)
            return value;

        auto classType = cast_.to.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception("Unsupported class cast target.");

        if (!AggregateValue.hasClassType(value, className(classType.sym)))
            return Value.null_;

        // A native class aggregate already carries the reference slot and
        // rooted body. Casting only changes its static expression type; do
        // not route it through the legacy exception reification shim.
        return value.isNativeAggregate
            ? value
            : nativeExceptionObjectWithClassFields(classType.sym, value);
    }

    private bool tryIdentifierClassCastValue(
        imported!"dmd.expression".CastExp cast_,
        out Value result,
    ) {
        import std.algorithm: canFind;

        if (!typeChars(cast_.to).canFind("Throwable"))
            return false;

        auto value = runExpression(cast_.e1);
        value = rootedNativeClassValue(cast_.e1, value);
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

        if (isArrayType(cast_.e1.type)) {
            // `.ptr` is raw-pointer extraction, not an indexed slice read:
            // a zero-length slice still retains its backing address and may
            // be regrown through that pointer.  Read the typed header from
            // the evaluated native slice directly; `arrayPointer` remains
            // the checked address-of route for real `array[index]` places.
            if (auto var = cast_.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration) {
                    import quickbite.backends.interpreter.place: Place;

                    if (auto address = variable in nativeRefLocalAddresses)
                        return Value.pointerValue(
                            Place(*address, variable.type).sliceDataPointer,
                        );
                    if (
                        hasMirrorSlot(variable) &&
                        mirrorEstablished.get(variable, false)
                    )
                        return Value.pointerValue(
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
                        import quickbite.backends.interpreter.place: Place;

                        if (auto address = variable in nativeRefLocalAddresses)
                            return Value.pointerValue(
                                Place(*address, variable.type)
                                    .deref
                                    .sliceDataPointer,
                            );
                        if (
                            hasMirrorSlot(variable) &&
                            mirrorEstablished.get(variable, false)
                        )
                            return Value.pointerValue(
                                bindingPlace(variable).deref.sliceDataPointer,
                            );
                    }

            const value = runExpression(cast_.e1);
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
                        ? Value.null_
                        : Value.pointerValue(cast(void*) address);
                }
            }
            return arrayPointer(cast_.e1, 0, cast_.op);
        }

        const value = runExpression(cast_.e1);
        if (value == Value.null_)
            return value;
        if (value.isPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    // An array-literal element typed `delegate` (`[() => 42]`) may carry a
    // LIVE callable value rather than `null`, the same gap
    // `structLiteralValue` already routes around: a bare `FuncExp` element
    // needs `runFunctionLiteralDeclaration` (ordinary `runExpression`
    // answers `Value.undisplayable` for one), and `AggregateValue.
    // reconstructArray`'s `writeValue` call only ever accepts `Value.null_`
    // for a Tdelegate element, so every live entry is substituted with
    // `Value.null_` for the reconstruction and then re-registered in
    // `nativeDelegateSlots`, keyed by the RESULT array's own element
    // address -- mirroring `structLiteralValue`'s identical
    // substitute-then-register handling.
    private Value arrayValue(
        imported!"dmd.expression".ArrayLiteralExp array,
    ) {
        import dmd.astenums: TY;

        auto elementType = array.type.toBasetype.nextOf;
        const isDelegateArray = elementType !is null
            && elementType.toBasetype.ty == TY.Tdelegate;

        Value[] values;
        size_t[] liveDelegateIndices;
        Value[] liveDelegateValues;
        if (array.elements !is null)
            // DMD's sparse form: a null element means the value is in `basis`
            // (see ArrayLiteralExp.getElement).
            foreach (index, element; *array.elements) {
                auto source = element is null ? array.basis : element;
                auto literal = source.isFuncExp;
                auto value = literal is null
                    ? runExpression(source)
                    : runFunctionLiteralDeclaration(literal);
                if (isDelegateArray && value != Value.null_) {
                    liveDelegateIndices ~= index;
                    liveDelegateValues ~= value;
                    value = Value.null_;
                }
                values ~= value;
            }

        auto result = reconstructStoredArray(array.type, values);
        foreach (position, index; liveDelegateIndices)
            nativeDelegateSlots[AggregateValue.elementAddress(result, index)] =
                liveDelegateValues[position];
        return result;
    }

    private Value reconstructStoredArray(
        imported!"dmd.mtype".Type type,
        in Value[] elements,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        if (!canContainStoredMetadata(type))
            return AggregateValue.reconstructArray(type, elements);

        Value[] nativeElements;
        nativeElements.reserve(elements.length);
        foreach (element; elements)
            nativeElements ~= element.isTypeName ? Value.null_ : element;

        auto result = AggregateValue.reconstructArray(type, nativeElements);
        auto destination = Place(AggregateValue.native(result).address, type);
        foreach (index, element; elements)
            writeStoredValue(destination.index(index), element);
        return result;
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

    // A struct-literal field typed `delegate` may carry a LIVE callable
    // value (a fresh closure, or an existing delegate local) rather than
    // `null`. `place_value.writeValue`'s Tdelegate arm only ever accepts
    // `Value.null_` -- by design, an interpreted delegate has no native ABI
    // function address, so its callable Value lives out-of-band in
    // `nativeDelegateSlots`, keyed by the FIELD's own address, exactly as
    // the direct field-assignment path (`s.f = &add;`, this module's
    // `DotVarExp` write arm) and a delegate-typed local's own declaration
    // (`setLocal`'s `TY.Tdelegate` branch) already register it. A struct
    // literal has no field address of its own until
    // `AggregateValue.reconstructStruct` allocates its native storage, so
    // this substitutes `Value.null_` for any live delegate field before
    // that call -- the same bytes the ordinary default-null case already
    // writes -- and registers the live value at the field's own address
    // once that address exists. `writeStoredValue` carries the registration
    // forward again when this rvalue is copied into durable storage.
    private Value structLiteralValue(
        imported!"dmd.expression".StructLiteralExp literal,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.place: Place;

        Value[] fields;
        imported!"dmd.declaration".VarDeclaration[] liveDelegateFields;
        Value[] liveDelegateValues;
        imported!"dmd.declaration".VarDeclaration[] symbolicTypeInfoFields;
        Value[] symbolicTypeInfoValues;
        if (literal.sd !is null)
            foreach (index; 0 .. literal.sd.fields.length) {
                const hasElement = literal.elements !is null
                    && index < (*literal.elements).length;
                auto element = hasElement ? (*literal.elements)[index] : null;
                // A fresh closure element (`() => 42`) is a bare `FuncExp`,
                // not a `DelegateExp` -- ordinary `runExpression` has no
                // general case for one (it is only ever meaningful at a
                // declaration/assignment seam that can register the fresh
                // function pointer) and answers `Value.undisplayable`
                // instead, the same gap `runIndexAssignExpression` and
                // `runDeclarationExpression` already route around via
                // `runFunctionLiteralDeclaration`.
                auto elementLiteral = element is null ? null : element.isFuncExp;
                auto value = element is null
                    ? structLiteralDefaultFieldValue(literal, index, fields)
                    : structLiteralFieldValue(literal, index, elementLiteral is null
                        ? runExpression(element)
                        : runFunctionLiteralDeclaration(elementLiteral));

                auto field = structLiteralField(literal, index);
                if (
                    field !is null &&
                    field.type.toBasetype.ty == TY.Tdelegate &&
                    value != Value.null_
                ) {
                    liveDelegateFields ~= field;
                    liveDelegateValues ~= value;
                    value = Value.null_;
                }
                if (
                    field !is null &&
                    field.type.toBasetype.isTypeClass !is null &&
                    value.isTypeName
                ) {
                    symbolicTypeInfoFields ~= field;
                    symbolicTypeInfoValues ~= value;
                    value = Value.null_;
                }

                fields ~= value;
            }

        auto result = AggregateValue.reconstructStruct(literal.type, fields);

        if (liveDelegateFields.length != 0) {
            auto native = AggregateValue.native(result);
            foreach (index, field; liveDelegateFields)
                nativeDelegateSlots[
                    Place(native.address, native.type).field(field).address
                ] = liveDelegateValues[index];
        }

        if (symbolicTypeInfoFields.length != 0) {
            auto native = AggregateValue.native(result);
            foreach (index, field; symbolicTypeInfoFields)
                nativeTypeInfoSlots[
                    Place(native.address, native.type).field(field).address
                ] = symbolicTypeInfoValues[index];
        }

        return result;
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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
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
            && AggregateValue.isArray(fieldsSoFar[0]);
        const firstFieldStructArray = isStaticArrayOfPlainStructs(firstField.type)
            && AggregateValue.isArray(fieldsSoFar[0]);

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
            if (!AggregateValue.isStruct(current))
                return false;

            auto siblingCell = cell.structField(index);
            value = structValueFromCell(current, siblingCell);
        } else if (siblingStructArray) {
            value = defaultValue(field);
            if (!AggregateValue.isArray(value))
                return false;

            auto siblingCell = cell.arrayField(index);
            foreach (elementIndex; 0 .. siblingCell.length) {
                auto elementCell = siblingCell.structElement(elementIndex);
                value = AggregateValue.withArrayElement(value,
                    elementIndex,
                    structValueFromCell(
                        AggregateValue.elementAt(value, elementIndex),
                        elementCell,
                    ),
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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (!AggregateValue.isArray(arrayValue))
            return;

        foreach (index; 0 .. cell.length) {
            if (index >= AggregateValue.elementCount(arrayValue))
                continue;

            if (cell.elementType.isTypeSArray) {
                // Mutable because recursive write takes the view by ref.
                auto elementCell = cell.arrayElement(index);
                writeStaticArrayCellStructElements(
                    elementCell,
                    AggregateValue.elementAt(arrayValue, index),
                );
            } else {
                auto elementCell = cell.structElement(index);
                writeStructCellScalarFields(elementCell,
                    AggregateValue.elementAt(arrayValue, index));
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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: staticArrayLength;

        auto field = structLiteralField(literal, index);
        if (field is null)
            return value;

        if (value == Value.null_ && isAssocArrayType(field.type))
        {
            import quickbite.backends.interpreter.native_assoc_array: allocateValue;

            return Value.nativeAggregateValue(allocateValue(field.type));
        }

        auto staticArray = field.type is null ? null : field.type.toBasetype.isTypeSArray;
        if (staticArray is null || AggregateValue.isArray(value))
            return value;

        const length = staticArrayLength(staticArray);
        Value[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        return reconstructStoredArray(field.type, elements);
    }

    // duplicate keys keep the last value, as in compiled D
    private Value assocArrayValue(
        imported!"dmd.expression".AssocArrayLiteralExp assocArray,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        Value[] keys;
        Value[] values;
        foreach (index; 0 .. assocArray.keys.length) {
            keys ~= runExpression((*assocArray.keys)[index]);
            values ~= runExpression((*assocArray.values)[index]);
        }
        return AggregateValue.reconstructAssocArray(assocArray.type, keys, values);
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
            setLocal(slice.lengthVar, Value(AggregateValue.length(source)));
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

            // Pointer slicing forms a native view; it does not read the
            // pointed-to elements. Reads happen only when that view is later
            // indexed, just as they do for compiled D.
            import quickbite.backends.interpreter.layout: typeByteSize;

            const address = cast(const(ubyte)*) source.pointerAddress + lower *
                typeByteSize(slice.e1.type.toBasetype.nextOf);
            return AggregateValue.reconstructNativeArrayWithLength(
                slice.type,
                upper - lower,
                address,
            );
        }

        const upper = slice.upr is null
            ? AggregateValue.length(source)
            : cast(size_t) runExpression(slice.upr).asLong;

        if (AggregateValue.isArray(source) && (lower > upper || upper > AggregateValue.length(source)))
            throwRangeError("Range violation");

        auto nativeAddress = AggregateValue.nativeArrayAddress(source);
        if (auto var = slice.e1.isVarExp)
            if (auto variable = var.var.isVarDeclaration)
                if (auto address = variable in nativeRefLocalAddresses)
                    nativeAddress = cast(const(ubyte)*) *address;
        if (auto dot = slice.e1.isDotVarExp)
            if (auto receiver = dot.e1.isVarExp)
                if (auto variable = receiver.var.isVarDeclaration)
                    if (auto owner = variable in locals) {
                        if (
                            (*owner).isNativeAggregate &&
                            variable.type.toBasetype.isTypeClass !is null
                        ) {
                            import quickbite.backends.interpreter.place: Place;

                            auto field = dot.var.isVarDeclaration;
                            if (field !is null)
                                nativeAddress = cast(const(ubyte)*) Place(
                                    AggregateValue.nativeClassBodyAddress(*owner),
                                    variable.type,
                                ).field(field).address;
                        }
                        else if (
                            (*owner).isNativeAggregate &&
                            variable.type.toBasetype.isTypeStruct !is null
                        ) {
                            import quickbite.backends.interpreter.layout:
                                declaredType;
                            import quickbite.backends.interpreter.place: Place;

                            auto field = dot.var.isVarDeclaration;
                            if (field !is null)
                                nativeAddress = cast(const(ubyte)*) Place(
                                    addressableBindingBase(variable),
                                    declaredType(variable),
                                ).field(field).address;
                        }
                    }
        if (nativeAddress is null)
            if (auto var = slice.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration) {
                    if (
                        variable.type.toBasetype.isTypeSArray !is null &&
                        hasMirrorSlot(variable) &&
                        mirrorEstablished.get(variable, false)
                    )
                        nativeAddress = cast(const(ubyte)*) mirrorAddress(variable);
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
                slice.type,
                (upper - lower) *
                    typeByteSize(slice.e1.type.toBasetype.nextOf),
                nativeAddress,
            );
        }
        // A promoted boxed-era array cell is already native storage. Its
        // slice result must own a typed header over those bytes instead of
        // returning a boxed Array that carries the address beside a recursive
        // element snapshot. NativeAggregate sources keep their retained
        // backing through AggregateValue.slice below.
        if (
            nativeAddress !is null &&
            (!source.isNativeAggregate || slice.e1.type.toBasetype.isTypeSArray !is null)
        )
            return AggregateValue.reconstructNativeArrayWithLength(
                slice.type,
                upper - lower,
                nativeAddress,
            );
        if (source.isNativeAggregate)
            return AggregateValue.slice(source, slice.type, lower, upper);
        return AggregateValue.slice(source, lower, upper);
    }

    private Value runIndexExpression(imported!"dmd.expression".IndexExp index) {
        size_t arrayIndex;
        return runIndexExpression(index, arrayIndex);
    }

    // Read an element from native (C heap) memory addressed by a
    // Pointer: a snapshot Value built from the pointee's bytes (a
    // scalar, a pointer, or a whole struct such as std.stdio.File's malloc'd
    // Impl).
    private Value loadNativePointerElement(
        imported!"dmd.mtype".Type pointerType,
        in Value pointer,
        in size_t index,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto elementType = pointerType.toBasetype.nextOf.toBasetype;
        auto address = nativeElementAddress(
            pointer.pointerAddress,
            index,
            typeByteSize(elementType),
        );
        if (elementType.ty == TY.Tdelegate)
            if (auto delegate_ = address in nativeDelegateSlots)
                return *delegate_;
        if (auto function_ = address in nativeFunctionPointerSlots)
            return *function_;
        if (
            elementType.isTypeAArray !is null ||
            canContainStoredMetadata(elementType)
        )
            return readStoredValue(Place(address, elementType));
        return readValue(Place(address, elementType));
    }

    private void storeNativePointerElement(
        imported!"dmd.mtype".Type pointerType,
        in Value pointer,
        in size_t index,
        in Value value,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        auto elementType = pointerType.toBasetype.nextOf.toBasetype;
        auto address = nativeElementAddress(
            pointer.pointerAddress,
            index,
            typeByteSize(elementType),
        );
        if (elementType.isTypeDelegate !is null) {
            writeStoredValue(Place(address, elementType), value);
            clearUninitializedBindingAddress(pointer.pointerAddress);
            return;
        }
        // `TypeNext.nextOf` is mutable in DMD's API, so this cannot be const.
        auto functionPointerType = elementType.isTypePointer;
        if (
            functionPointerType !is null &&
            functionPointerType.nextOf.toBasetype.isTypeFunction !is null
        ) {
            if (value.isFunctionPointer) {
                nativeFunctionPointerSlots[address] = value;
                Place(address, elementType).storeReference(null);
                clearUninitializedBindingAddress(pointer.pointerAddress);
                return;
            }
            nativeFunctionPointerSlots.remove(address);
        }
        if (canContainStoredMetadata(elementType))
            writeStoredValue(Place(address, elementType), value);
        else
            writeValue(Place(address, elementType), value);
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
    ) {
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.native_call_adapter: NativeOperand;
        import quickbite.backends.interpreter.layout: declaredType;

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

    private bool invokeNativeDeclaration(
        imported!"dmd.func".FuncDeclaration function_,
        Value receiver,
        imported!"dmd.mtype".Type receiverType,
        imported!"dmd.expression".Expression receiverExpression,
        Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        in EvaluatedReferenceArgument[] evaluatedArguments,
        in bool returnsReceiver,
        out imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallResult result,
    ) {
        import quickbite.backends.interpreter.native_call_adapter:
            InterpreterInboundTrampolineSession, NativeCallRequest,
            NativeOperand, invokeNative;

        auto argumentTypes = nativeArgumentTypes(argumentExpressions);
        if (durableInboundSession is null)
            durableInboundSession = new InterpreterInboundTrampolineSession(
                &invokeNativeCallback,
            );
        auto request = NativeCallRequest(
            declaration: function_,
            receiverType: receiverType,
            receiver: receiver,
            receiverOperand: receiverExpression is null
                ? NativeOperand.init
                : nativeReceiverOperand(receiverExpression),
            virtualDispatch: receiverType !is null &&
                receiverType.toBasetype.isTypeClass !is null,
            returnsReceiver: returnsReceiver,
            arguments: arguments,
            argumentTypes: argumentTypes,
            argumentOperands: nativeCallOperands(
                function_,
                arguments,
                argumentExpressions,
                argumentTypes,
                evaluatedArguments,
            ),
            callbackSession: durableInboundSession,
        );
        return invokeNative(request, result);
    }

    // Existing lvalues and retained C-string pointers cross as typed
    // addresses. Other rvalues become typed NativeBlock temporaries in the
    // adapter.
    private imported!"quickbite.backends.interpreter.native_call_adapter".NativeOperand[]
    nativeCallOperands(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
        imported!"dmd.mtype".Type[] argumentTypes,
        in EvaluatedReferenceArgument[] evaluatedArguments,
    ) {
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.native_call_adapter: NativeOperand;
        import dmd.tokens: EXP;

        NativeOperand[] operands;
        operands.length = argumentExpressions.length;
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
                (arguments[index].isPointer || arguments[index] == Value.null_)
            ) {
                import quickbite.backends.interpreter.place: Place;

                auto scratch = NativeBlock.allocate(
                    (void*).sizeof,
                    NativeBlock.Scan.conservative,
                );
                auto pointer = arguments[index] == Value.null_
                    ? null
                    : arguments[index].pointerAddress;
                Place(scratch.address, argumentTypes[index])
                    .storeReference(pointer);
                NativeBlock retained;
                if (pointer !is null)
                    if (auto root = pointer in nativePointerRoots)
                        retained = *root;
                operands[index] = NativeOperand(
                    argumentTypes[index],
                    scratch.address,
                    scratch,
                    retained,
                );
                continue;
            }

            if (
                index >= argumentTypes.length ||
                expression.type is null ||
                !expression.type.toBasetype.equals(
                    argumentTypes[index].toBasetype,
                ) ||
                !hasStableLocalFieldPlace(expression)
            )
                continue;
            const address = addressOfExpression(expression, EXP.address);
            if (address.isPointer)
                operands[index] = NativeOperand(
                    nativeReferenceParameter(function_, index)
                        ? nativeParameterType(function_, index)
                        : argumentTypes[index],
                    address.pointerAddress,
                );
        }
        return operands;
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

    private Value runIndexExpression(
        imported!"dmd.expression".IndexExp index,
        out size_t arrayIndex,
    ) {
        import quickbite.frontend.dmd.types:
            isAssocArrayType,
            isPointerType;

        if (isAssocArrayType(index.e1.type)) {
            arrayIndex = 0;
            const aa = runExpression(index.e1);
            const key = runExpression(index.e2);
            if (isNativeAssocArray(aa)) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue;

                auto header = nativeAssocArray(aa);
                auto keySlot = nativeAssocKeySlot(header, key);
                auto address = header.valueAddress(keySlot.address);
                if (address is null)
                    throw new Exception("Associative-array key is absent.");
                return readValue(Place(address, header.valueType));
            }
            return aa.assocArrayElement(key);
        }

        // `$` inside index.e2 is a DollarExp bound to index.lengthVar, so it
        // must see the array's current length: run index.e1 and seed
        // lengthVar from its result before evaluating index.e2, the same
        // order runSliceExpression already uses for the same `$` binding.
        // Evaluating e2 first left lengthVar holding a stale (or default
        // zero) length, so `arr[$ - 1]` on a just-grown array underflowed to
        // size_t.max instead of the intended last-element index.
        const source = runExpression(index.e1);
        if (isPointerType(index.e1.type)) {
            arrayIndex = cast(size_t) cast(ulong) runExpression(index.e2).asLong;
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

        const sourceLength = AggregateValue.isArray(source)
            ? AggregateValue.length(source)
            : source.length;
        if (index.lengthVar !is null)
            setLocal(index.lengthVar, Value(sourceLength));

        // matches CTFE, which formats the index as unsigned
        arrayIndex = cast(size_t) cast(ulong) runExpression(index.e2).asLong;
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
                if (auto address = variable in nativeRefLocalAddresses) {
                    import quickbite.backends.interpreter.place: Place;
                    import quickbite.backends.interpreter.place_value: readValue;

                    return readValue(Place(*address, variable.type).index(
                        arrayIndex,
                    ));
                }
                if (
                    hasMirrorSlot(variable) &&
                    mirrorEstablished.get(variable, false)
                ) {
                    import dmd.astenums: TY;
                    // A live delegate element's bytes are the all-zero ABI
                    // value (`place_value.writeValue`'s Tdelegate arm only
                    // ever accepts `Value.null_`), so a plain `readValue`
                    // here cannot tell a genuinely null element from one
                    // whose live callable Value was substituted out-of-band
                    // -- check `nativeDelegateSlots`, keyed by the element's
                    // own address, first, exactly as `nativeArrayElementAt`
                    // already does for the native-aggregate branch below.
                    auto elementType = index.e1.type.toBasetype.nextOf;
                    if (elementType !is null && elementType.toBasetype.ty == TY.Tdelegate)
                        if (
                            auto delegate_ = bindingPlace(variable).index(arrayIndex).address
                                in nativeDelegateSlots
                        )
                            return *delegate_;

                    return readStoredValue(
                        bindingPlace(variable).index(arrayIndex),
                    );
                }
                if (auto current = variable in locals)
                    if ((*current).isNativeAggregate)
                        return nativeArrayElementAt(source, arrayIndex);
            }

        return AggregateValue.isArray(source)
            ? nativeArrayElementAt(source, arrayIndex)
            : source[arrayIndex];
    }

    private void throwRangeError(in string message) {
        import core.exception: RangeError;

        auto native = new RangeError;
        native.msg = message;
        throw new InterpretedException(nativeExceptionBaseObject(
            message,
            native.classinfo.name,
            cast(void*) native,
        ));
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

    private void writePointerTarget(
        imported!"dmd.expression".Expression expression,
        in Value pointer,
        in Value value,
    ) {
        // A native pointer (e.g. into a malloc'd struct like std.stdio.File's
        // Impl): write straight into native memory.
        if (pointer.isPointer) {
            storeNativePointerElement(expression.type, pointer, 0, value);
            return;
        }

        throw new Exception(
            "quickbite.backends.interpreter.impl.Walker.writePointerTarget: "
            ~ "data pointers must carry a native binding address",
        );
    }

    // The single ordered route through promoted boxed-pointer writes. Direct
    // dereference and compound-assignment/atomic write-back use this gate, so
    // they cannot update different interim authorities.
    private void writePointerElements(
        imported!"dmd.expression".Expression expression,
        in Value pointer,
        in Value[] values,
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

        return allocateNativePointer(targetType, value);
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
            forkExecutionStateInto(child);
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

        return allocateNativePointer(targetType, structVal);
    }

    // `new T` establishes one GC-owned native object and returns its address.
    // The root table is host-only lifetime retention; guest pointer identity is
    // exactly the allocation address, with no boxed element array or synthetic
    // allocation id left to reconcile on dereference or assignment.
    private Value allocateNativePointer(
        imported!"dmd.mtype".Type targetType,
        in Value value,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize, typeHasPointers;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

        auto block = NativeBlock.allocate(
            typeByteSize(targetType),
            typeHasPointers(targetType)
                ? NativeBlock.Scan.conservative
                : NativeBlock.Scan.no,
        );
        writeValue(Place(block.address, targetType), value);
        nativePointerRoots[block.address] = block;
        return Value.pointerValue(block.address);
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
    // block every frame resolves through (`forkLegacyFrameStateInto` shares it
    // by pointer), so leaving this activation's boxed copy at the pre-call
    // value does not merely answer staler -- the next read of that global
    // compares the two and asserts.
    private void mergeNewStructConstructorState(ref Walker child) {
        mergeNativePointerRoots(child);
        nextClassObjectId = child.nextClassObjectId;
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
        borrowedNativeClassPointers = child.borrowedNativeClassPointers;
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
        import quickbite.backends.interpreter.native_call_adapter:
            NativeCallException, NativeCallResult;
        import dmd.expression: Expression;

        Value[] arguments;
        Expression[] argumentExpressions;
        if (new_.arguments !is null)
            foreach (argument; *new_.arguments) {
                arguments ~= runExpression(argument);
                argumentExpressions ~= argument;
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
                return allocateNativePointer(targetType, nativeResult.value);
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

        auto object = AggregateValue.allocateClass(allocationType);
        nativeClassTypes[AggregateValue.nativeClassBodyAddress(object)] = allocationType;
        nativeClassOwners[AggregateValue.nativeClassBodyAddress(object)] = object;
        initializeNativeClassBody(this, allocationType, object);
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
        forkExecutionStateInto(child);
        child.thisValue = Value.pointerValue(
            AggregateValue.nativeClassBodyAddress(object),
        );
        child.hasThis = true;
        child.bindFunctionParameters(new_.member, arguments);
        try {
            child.runStatement(new_.member.fbody);
        } catch (InterpretedException exception) {
            mergeNewClassExpressionState(child);
            throw exception;
        }
        mergeNewClassExpressionState(child);
        return object;
    }

    private void mergeNewClassExpressionState(ref Walker child) {
        mergeNativePointerRoots(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        nextClassObjectId = child.nextClassObjectId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
        borrowedNativeClassPointers = child.borrowedNativeClassPointers;
        nativeDelegateSlots = child.nativeDelegateSlots;
        nativeFunctionPointerSlots = child.nativeFunctionPointerSlots;
        nativeTypeInfoSlots = child.nativeTypeInfoSlots;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        lazyArgumentFrames = child.lazyArgumentFrames;
    }

    private Value newArrayValue(
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

        Value[] elements;
        foreach (_; 0 .. lengths[0])
            elements ~= lengths.length > 1
                ? newArrayValue(elementType, lengths[1 .. $])
                : defaultValue(elementType);

        return reconstructStoredArray(type, elements);
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(false);

        dropDeclarationCells(variable);

        if (variable._init !is null && variable._init.isVoidInitializer !is null) {
            uninitializedLocals[variable] = true;
            markUninitializedBinding(variable);
            return Value.void_;
        }

        if (variable._init is null || variable._init.isExpInitializer is null) {
            const value = defaultLocalValue(variable);
            setLocal(variable, value);
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
                return value;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                const value = defaultValue(variable);
                setLocal(variable, value);
                uninitializedLocals.remove(variable);
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
                if (AggregateValue.isStruct(result)) {
                    setLocal(variable, result);
                    return result;
                }
                if (auto value = variable in locals)
                    return *value;
                return defaultValue(variable);
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
                if (postblit !is null && hasMirrorSlot(variable)) {
                    import quickbite.backends.interpreter.layout:
                        staticArrayLength, typeByteSize;
                    import quickbite.backends.interpreter.native_aggregate:
                        NativeAggregate;
                    import quickbite.backends.interpreter.native_block:
                        NativeBlock;

                    auto sourceArray = (*arrayCtorCall.arguments)[1];
                    while (auto sourceCast = sourceArray.isCastExp)
                        sourceArray = sourceCast.e1;

                    const source = runExpression(sourceArray);
                    setLocal(variable, source);
                    uninitializedLocals.remove(variable);

                    const count =
                        staticArrayLength(variable.type.toBasetype.isTypeSArray);
                    foreach (i; 0 .. count) {
                        auto elementPlace = bindingPlace(variable).index(i);
                        const elementReceiver = Value.nativeAggregateValue(
                            NativeAggregate(
                                elementPlace.type,
                                NativeBlock.borrow(
                                    elementPlace.address,
                                    typeByteSize(elementPlace.type),
                                ),
                            ));
                        runMemberFunction(postblit, null, elementReceiver, [], []);
                    }

                    if (auto value = variable in locals)
                        return *value;
                    return defaultValue(variable);
                }
            }

        import quickbite.frontend.dmd.types: isAssocArrayType, isDynamicArrayType;

        if (initializer.isNullExp !is null && isDynamicArrayType(variable.type)) {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;

            auto value = reconstructStoredArray(variable.type, []);
            setLocal(variable, value);
            uninitializedLocals.remove(variable);
            return value;
        }

        if (initializer.isNullExp !is null && isAssocArrayType(variable.type)) {
            auto value = Value.null_;
            setLocal(variable, value);
            uninitializedLocals.remove(variable);
            return value;
        }

        if (auto slice = initializer.isSliceExp) {
            size_t lower;
            auto value = runSliceExpression(slice, lower);
            setLocal(variable, value);
            uninitializedLocals.remove(variable);
            return value;
        }

        auto indexInitializer = initializer.isIndexExp;
        const isArrayElementAlias = isRefVariable(variable) &&
            indexInitializer !is null &&
            !isAssocArrayType(indexInitializer.e1.type);
        auto dotInitializer = initializer.isDotVarExp;
        size_t arrayElementAliasIndex;
        Value nativeFieldAliasValue;
        bool hasNativeFieldAlias;
        if (
            isRefVariable(variable) &&
            dotInitializer !is null &&
            (
                dotInitializer.e1.type.toBasetype.isTypeClass !is null ||
                dotInitializer.e1.type.toBasetype.isTypeStruct !is null
            )
        ) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.layout: typeByteSize;
            import quickbite.backends.interpreter.native_scalar:
                isNativeScalarType, readScalar;

            if (isNativeScalarType(variable.type)) {
                const pointer = addressOfExpression(dotInitializer, EXP.address);
                if (pointer.isPointer) {
                    // Mutable because both the scalar reader and the map
                    // retain the borrowed byte-range view by mutable value.
                    auto cell = NativeBlock.borrow(
                        pointer.pointerAddress,
                        typeByteSize(variable.type),
                    );
                    nativeFieldAliasValue = readScalar(variable.type, cell.bytes);
                    nativeRefLocalAddresses[variable] = pointer.pointerAddress;
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
        if (variable.type.toBasetype.isTypeClass !is null)
            value = rootedNativeClassValue(initializer, value);
        setLocal(variable, value);
        if (isArrayElementAlias) {
            import dmd.tokens: EXP;
            import quickbite.backends.interpreter.native_aggregate:
                NativeAggregate;
            import quickbite.backends.interpreter.native_block: NativeBlock;
            import quickbite.backends.interpreter.layout: typeByteSize;

            // The index expression has already been evaluated exactly once
            // above. Reuse its captured index to make the `ref` local a typed
            // borrowed view of that element rather than its detached read.
            const pointer = arrayPointer(
                indexInitializer.e1,
                cast(long) arrayElementAliasIndex,
                EXP.address,
            );
            if (pointer.isPointer) {
                nativeRefLocalAddresses[variable] = pointer.pointerAddress;
                if (value.isNativeAggregate)
                    value = Value.nativeAggregateValue(NativeAggregate(
                        variable.type,
                        NativeBlock.borrow(
                            pointer.pointerAddress,
                            typeByteSize(variable.type),
                        ),
                    ));
                setLocal(variable, value);
            }
        }
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
                if (
                    baseType.isTypeStruct !is null ||
                    baseType.isTypeClass !is null ||
                    baseType.isTypeSArray !is null
                ) {
                    const pointer = bindingPointerValue(source);
                    if (pointer.isPointer) {
                        import quickbite.backends.interpreter.native_aggregate:
                            NativeAggregate;
                        import quickbite.backends.interpreter.native_block: NativeBlock;
                        import quickbite.backends.interpreter.layout: typeByteSize;

                        nativeRefLocalAddresses[variable] = pointer.pointerAddress;
                        // A `ref` local is a view, never a by-value read.
                        // Keep its expression handle on the source's typed
                        // frame bytes so index reads and writes cannot revive
                        // the detached aggregate copy produced while
                        // evaluating the initializer.
                        value = Value.nativeAggregateValue(NativeAggregate(
                            variable.type,
                            NativeBlock.borrow(
                                pointer.pointerAddress,
                                typeByteSize(variable.type),
                            ),
                        ));
                        setLocal(variable, value);
                    }
                }
            }

            const isRvalueMemberReference = dotInitializer !is null &&
                dotInitializer.e1.isCallExp !is null;
            if (variable !in nativeRefLocalAddresses && !isRvalueMemberReference) {
                import dmd.tokens: EXP;

                const pointer = addressOfExpression(initializer, EXP.address);
                if (pointer.isPointer) {
                    nativeRefLocalAddresses[variable] = pointer.pointerAddress;
                    if (value.isNativeAggregate) {
                        import quickbite.backends.interpreter.native_aggregate:
                            NativeAggregate;
                        import quickbite.backends.interpreter.native_block:
                            NativeBlock;
                        import quickbite.backends.interpreter.layout:
                            typeByteSize;

                        value = Value.nativeAggregateValue(NativeAggregate(
                            variable.type,
                            NativeBlock.borrow(
                                pointer.pointerAddress,
                                typeByteSize(variable.type),
                            ),
                        ));
                    }
                    setLocal(variable, value);
                }
            }
        }
        uninitializedLocals.remove(variable);
        return value;
    }


    // A class rvalue normally exposes only its native body pointer. For a
    // plain local copy, retain the source NativeAggregate instead: it owns
    // the reference slot and roots that body, and the two locals then denote
    // the same guest object without creating a boxed class-cell identity.
    private Value rootedNativeClassValue(
        imported!"dmd.expression".Expression expression,
        in Value evaluated,
    ) {
        if (auto cast_ = expression.isCastExp)
            return rootedNativeClassValue(cast_.e1, evaluated);

        // Re-entry through a native callback creates a child Walker. A native
        // class caught there is hydrated for interpreted field access, but
        // its class value still carries the runtime object's preserved body
        // pointer. Restore that opaque identity before the value crosses a
        // later native-call boundary; attempting to compose the hydrated
        // field snapshot into a class-reference slot would invent a second
        // object representation.
        const nativeIdentity = preservedNativeClassIdentity(evaluated);
        if (!evaluated.isPointer && nativeIdentity.isPointer)
            return nativeIdentity;

        auto var = expression.isVarExp;
        auto variable = var is null ? null : var.var.isVarDeclaration;
        if (variable !is null)
            if (auto rooted = variable in locals)
                if ((*rooted).isNativeAggregate)
                    return *rooted;
        if (
            evaluated.isPointer &&
            expression.type !is null &&
            expression.type.toBasetype.isTypeClass !is null
        )
            if (auto dynamicType = evaluated.pointerAddress in nativeClassTypes)
                return AggregateValue.borrowClass(
                    *dynamicType,
                    evaluated.pointerAddress,
                );
        return evaluated;
    }

    private Value preservedNativeClassIdentity(in Value value) {
        if (auto pointer = borrowedNativeClassPointer(value))
            return Value.pointerValue(*pointer);

        return value;
    }

    // A same-width scalar dynamic-array cast changes only the element type
    // used to interpret the bytes. Give the destination and source locals
    // differently typed views over one NativeArray block so writes through
    // either binding remain visible through the other.
    private Value defaultLocalValue(VarDeclaration variable) {
        return defaultValue(variable);
    }

    private bool isRefVariable(VarDeclaration variable) const {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.ref_) != STC.none;
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

            // Reuse the ordinary VarExp read path.  During the authority
            // migration a promoted legacy cell can coexist with an established
            // frame slot; the latter is the address a native pointer wrote,
            // so the post-increment must observe that same storage rather
            // than selecting a stale cell through `readCelledLocal`.
            const oldValue = runExpression(post.e1);
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
            const oldValue = readPointerTarget(pointer.e1, target);
            writePointerTarget(pointer.e1, target, oldValue + delta);
            return oldValue;
        }

        throw new Exception("Unsupported eval post expression target.");
    }

    private Value runAddAssignExpression(
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


private bool isTruthy(in imported!"quickbite.backends.interpreter.runtime_value".Value value) {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.native_array: readSliceHeaderBytes;
    import quickbite.backends.interpreter.runtime_value: Value;

    if (value == Value.null_)
        return false;

    if (value.isPointer)
        return true;

    if (AggregateValue.isArray(value)) {
        if (value.isNativeAggregate) {
            // DMD's `toBasetype` is mutable.
            auto aggregate = AggregateValue.native(value);
            if (aggregate.type.toBasetype.ty == TY.Tarray)
                return readSliceHeaderBytes(aggregate.storage.bytes).ptr !is null;
        }
        return AggregateValue.length(value) != 0;
    }

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


// A newly allocated native class body begins as zeroed guest storage, but
// D's field defaults need not be zero. Seed each declared field through the
// same place codec used by assignments; the returned NativeAggregate retains
// the reference slot and the body allocation as one expression value.
private void initializeNativeClassBody(
    ref Walker walker,
    imported!"dmd.mtype".Type type,
    in imported!"quickbite.backends.interpreter.runtime_value".Value object,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.layout: classFields;
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.place_value: writeValue;
    import quickbite.backends.interpreter.runtime_values: defaultValue;

    auto classType = type.toBasetype.isTypeClass;
    if (classType is null || classType.sym is null)
        throw new Exception("initializeNativeClassBody needs a class type.");

    auto body = Place(AggregateValue.nativeClassBodyAddress(object), type);
    foreach (field; classFields(classType.sym)) {
        auto value = defaultValue(field.type);
        if (field._init !is null) {
            if (auto initializer = field._init.isExpInitializer)
                value = walker.storageValue(
                    field.type,
                    walker.runExpression(initializer.exp),
                );
            else if (field._init.isArrayInitializer !is null)
                value = classFieldArrayLiteralDefault(walker, field);
        }
        writeValue(body.field(field), value);
    }
}


// A `Tarray`/`Tsarray` class field's own array-literal default (`int[] arr
// = [1, 2, 3];`) parses as an `ArrayInitializer`, not the `ExpInitializer`
// a scalar default parses as. Real D evaluates that literal once, into the
// class's static `.init` data, and every `new` that does not override the
// field shares that one backing array: mutating it through one instance is
// visible through another. Evaluate the literal once per field declaration
// and cache the resulting native array `Value`, so every later instance's
// field descriptor points at the same backing storage instead of a fresh
// per-object copy.
private imported!"quickbite.backends.interpreter.runtime_value".Value
classFieldArrayLiteralDefault(
    ref Walker walker,
    imported!"dmd.declaration".VarDeclaration field,
) {
    import dmd.initsem: initializerToExpression;

    if (walker.classArrayFieldDefaults is null)
        walker.classArrayFieldDefaults = new ClassArrayFieldDefaults;
    if (auto cached = field in walker.classArrayFieldDefaults.table)
        return *cached;

    auto value = walker.storageValue(
        field.type,
        walker.runExpression(field._init.initializerToExpression),
    );
    walker.classArrayFieldDefaults.table[field] = value;
    return value;
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

private struct RuntimeDelegate {
    public imported!"dmd.func".FuncDeclaration function_;
    public size_t functionPointerId;
    public imported!"quickbite.backends.interpreter.runtime_value".Value contextPointer;
    public imported!"quickbite.backends.interpreter.runtime_value".Value receiver;
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

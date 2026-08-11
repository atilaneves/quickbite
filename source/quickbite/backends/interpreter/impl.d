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
    private ExpressionResult[void*] _nativeClassOwners;
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
            walker.runStatement(function_.fbody);
            final switch (mode) with (ExecutionMode) {
            case regular:
            case unitTest:
                return EvalResult("");
            case formatted:
                return EvalResult(formattedDisplay(walker.result));
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

    char[] display;
    foreach (index; 0 .. AggregateValue.elementCount(value))
        display ~= AggregateValue.elementAt(value, index).asUtf8Character;
    return display.idup;
}


private imported!"quickbite.backends.interpreter.expression_result".ExpressionResult characterArrayValue(
    imported!"dmd.mtype".Type type,
    in string characters,
) {
    import quickbite.backends.interpreter.aggregate_value: AggregateValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    ExpressionResult[] elements;
    foreach (character; characters)
        elements ~= ExpressionResult(character);
    return AggregateValue.reconstructArray(type, elements);
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

// Native places for class array-literal `.init` fields, keyed by the address
// of DMD's initializer node. The pointer indirection keeps the table shared
// when the first insertion happens in a child walker.
private struct ClassArrayFieldDefaults {
    public imported!"quickbite.backends.interpreter.native_block".NativeBlock[
        const(void)*] table;
}

private class InterpretedException: Exception {
    public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult object;

    public this(
        in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult object,
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
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.runtime_values: defaultValue;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    private Throwable[const(void)*] nativeThrowableRoots;
    // Captured native Throwable chains outlive the call bridge as rooted
    // interpreter values. Keying by the native body lets Throwable.next use
    // that captured authority without reinterpreting druntime's tagged link.
    private ExpressionResult[void*] nativeThrowableNext;

    private TemporaryPointerOwners* _temporaryPointerOwners;

    // Interpreted function declarations have no host code address. A guest
    // function-pointer slot therefore retains the interpreter callable in a
    // host-only side table keyed by its real native slot address, exactly as
    // an interpreted delegate does. The slot itself stays a valid null host
    // pointer; no symbolic pointer carrier is ever written into guest bytes.
    private ExpressionResult[const(void)*] nativeFunctionPointerSlots;

    // TypeInfo values for interpreted-only guest types have no resident host
    // object address. Their class-reference slots keep null ABI bytes while
    // this table retains the symbolic singleton keyed by the real slot
    // address, matching interpreted delegates and function pointers.
    private ExpressionResult[void*] nativeTypeInfoSlots;

    // Non-null only while `runRefArgumentExpression` is walking one call
    // argument.  `runIndexExpression` records its already-evaluated result in
    // the active argument's identity-keyed table; nested calls save and
    // restore this pointer around their own argument evaluation.
    private size_t[const(void)*]* _evaluatedReferenceArgumentIndices;

    // Lazily allocated, execution-wide native `.init` places.
    private ClassArrayFieldDefaults* classArrayFieldDefaults;

    private FuncDeclaration[size_t] functionPointers;
    private size_t[FuncDeclaration] functionPointerIds;
    private size_t nextFunctionPointerId;
    private RuntimeDelegate[size_t] delegates;
    // A native class reference carries only its body address; retain the
    // dynamic class Type by that address for Object-typed aliases.
    private imported!"dmd.mtype".Type[void*] nativeClassTypes;
    // A VM-allocated class reference exposes only its body address. Keep its
    // allocation handle by that address so later aliases retain the storage
    // that owns the body.
    private ExpressionResult[void*] nativeClassOwners;
    // A borrowed native Throwable reference carries only its object address.
    // Its interpreter-visible fields live in a native aggregate keyed by that
    // real address; the host object remains opaque ABI-owned storage.
    private ExpressionResult[void*] nativeExceptionMetadata;
    // Interpreted delegates have no guest ABI function pointer. Native
    // delegate slots retain their callable ExpressionResult out-of-band while their
    // ordinary `{context, function}` guest bytes remain ABI-shaped.
    private ExpressionResult[void*] nativeDelegateSlots;
    // A struct declared inside a function reads that function's locals through
    // its hidden context field, and its methods can run long after the
    // enclosing activation returned. An interpreted activation is a
    // `FrameBlock`, not a guest address the field's bytes could name, so this
    // table retains the enclosing activation chain (nearest first) keyed by
    // that field's own address -- the same out-of-band shape
    // `nativeDelegateSlots` uses, and carried across value copies by
    // `copyStoredMetadata`. The retained handles keep the frames' GC-owned
    // storage alive for exactly as long as an instance can still be called.
    private FrameBlock[][void*] nestedContextFrames;
    private imported!"quickbite.backends.interpreter.native_call_adapter".
        InterpreterInboundTrampolineSession* durableInboundSession;
    private Expression[VarDeclaration] lazyArgumentExpressions;
    // The caller's own `_activationFrame` at the moment its `lazy` argument
    // was bound. Evaluating the thunk temporarily selects that frame, whose
    // places remain the sole authority for the captured bindings.
    private FrameBlock[VarDeclaration] lazyArgumentFrames;
    // DMD may synthesize an IndexExp/SliceExp `$` length declaration after a
    // root frame layout was computed. It is expression-evaluation metadata,
    // not a D storage binding; key its native size_t by the declaration object's
    // address for the duration of this Walker.
    private size_t[const(void)*] _syntheticDollarValues;
    // `= void` is state attached to the authoritative binding address.
    private UninitializedBindings* uninitializedBindingAddresses;
    private ExpressionResult result;
    private bool runningCalledFunction;
    private bool inUnitTest;
    private FuncDeclaration currentFunction;

    // Per-activation native storage block. Every local binding resolves to an
    // owning or reference place in this block.
    private FrameBlock _activationFrame;
    // Native static links for lexically enclosing activations, nearest first.
    // The copied FrameBlock handles retain their GC-owned storage, so both a
    // direct nested call and a deeper relay can resolve the original place.
    private FrameBlock[] _enclosingFrames;

    // Module-lifetime storage for module, `static`, and `__gshared` bindings.
    // All child walkers share the same table by pointer.
    private ModuleTable* moduleTable;

    private ExpressionResult thisValue;
    private void* thisAddress;
    private bool hasThis;
    private ExpressionResult pendingFinallyBodyException;
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
                    result = runExpression(return_.exp);
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

        import dmd.astenums: TY;

        if (variable.type.toBasetype.ty == TY.Tdelegate) {
            nativeDelegateSlots[bindingPlace(variable).address] = value;
            import quickbite.backends.interpreter.place_value: writeValue;
            writeValue(bindingPlace(variable), ExpressionResult.null_);
            return;
        }

        if (value.isFunctionPointer) {
            nativeFunctionPointerSlots[bindingPlace(variable).address] = value;
            import quickbite.backends.interpreter.place_value: writeValue;
            writeValue(bindingPlace(variable), ExpressionResult.null_);
            return;
        }

        import quickbite.backends.interpreter.place_value:
            valueMatchesPlace, writeValue;

        if (
            variable.type.toBasetype.isTypeAArray !is null &&
            value == ExpressionResult.null_
        ) {
            writeValue(bindingPlace(variable), value);
            return;
        }

        if (
            variable.type.toBasetype.isTypeClass !is null &&
            value.isTypeName
        ) {
            writeStoredValue(bindingPlace(variable), value);
            return;
        }

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
            writeValue(bindingPlace(variable), value);
            return;
        }

        const canStore = value.isNativeAggregate
            ? true
            : valueMatchesPlace(variable.type, value);
        if (!canStore)
            throw new Exception("Interpreter binding value is not place-composable.");

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

        if (oldAddress is newAddress)
            return;

        const byteLength = typeByteSize(type);
        const oldStart = cast(size_t) oldAddress;
        const oldEnd = oldStart + byteLength;

        size_t[] delegateOffsets;
        ExpressionResult[] delegateValues;
        foreach (address, value; nativeDelegateSlots)
            if (cast(size_t) address >= oldStart && cast(size_t) address < oldEnd) {
                delegateOffsets ~= cast(size_t) address - oldStart;
                delegateValues ~= value;
            }

        size_t[] functionOffsets;
        ExpressionResult[] functionValues;
        foreach (address, value; nativeFunctionPointerSlots)
            if (cast(size_t) address >= oldStart && cast(size_t) address < oldEnd) {
                functionOffsets ~= cast(size_t) address - oldStart;
                functionValues ~= value;
            }

        size_t[] typeInfoOffsets;
        ExpressionResult[] typeInfoValues;
        foreach (address, value; nativeTypeInfoSlots)
            if (cast(size_t) address >= oldStart && cast(size_t) address < oldEnd) {
                typeInfoOffsets ~= cast(size_t) address - oldStart;
                typeInfoValues ~= value;
            }

        size_t[] contextOffsets;
        FrameBlock[][] contextFrames;
        foreach (address, frames; nestedContextFrames)
            if (cast(size_t) address >= oldStart && cast(size_t) address < oldEnd) {
                contextOffsets ~= cast(size_t) address - oldStart;
                contextFrames ~= frames;
            }

        clearStoredMetadata(type, newAddress);

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

        const(void)*[] contextAddresses;
        foreach (slot; nestedContextFrames.byKeyValue)
            if (rangesOverlap(
                cast(size_t) slot.key,
                (void*).sizeof,
                start,
                end - start,
            ))
                contextAddresses ~= slot.key;
        foreach (slot; contextAddresses)
            nestedContextFrames.remove(cast(void*) slot);
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
        import quickbite.backends.interpreter.place_value: writeValue;

        import dmd.astenums: TY;

        if (place.type.toBasetype.isTypeClass !is null && value.isTypeName) {
            clearStoredMetadata(place.type, place.address);
            nativeTypeInfoSlots[place.address] = value;
            writeValue(place, ExpressionResult.null_);
            return;
        }

        if (place.type.toBasetype.ty == TY.Tdelegate && value != ExpressionResult.null_) {
            clearStoredMetadata(place.type, place.address);
            nativeDelegateSlots[place.address] = value;
            writeValue(place, ExpressionResult.null_);
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
    private ExpressionResult readStoredValue(
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

    private ExpressionResult withStoredStructField(
        in ExpressionResult receiver,
        imported!"dmd.mtype".Type receiverType,
        in size_t fieldIndex,
        in ExpressionResult fieldValue,
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
            symbolicTypeInfo ? ExpressionResult.null_ : fieldValue,
        );
        auto source = AggregateValue.native(receiver);
        auto destination = AggregateValue.native(result);
        copyStoredMetadata(receiverType, source.address, destination.address);

        auto fieldPlace = Place(destination.address, destination.type)
            .field(field);
        writeStoredValue(fieldPlace, fieldValue);
        return result;
    }

    private void retainTemporaryPointerOwner(NativeBlock owner) @safe {
        assert(
            _temporaryPointerOwners !is null &&
                _temporaryPointerOwners.expressionDepth != 0,
            "raw pointer owner escaped its expression scope",
        );
        _temporaryPointerOwners.blocks ~= owner;
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
        const object = runExpression(expression);
        if (dynamicClass(object) is null)
            throw new Exception("Unsupported throw expression.");
        if (hasPendingFinallyBodyException) {
            const chained = chainExceptionObject(
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
        const object = nativeExceptionObject(exception);
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
    private ExpressionResult nativeExceptionObject(
        imported!"quickbite.backends.interpreter.native_call_adapter".NativeCallException exception,
    ) {
        const object = nativeExceptionBaseObject(
            exception.msg,
            exception.className,
            exception.nativeThrowableObjectPointer,
        );
        if (exception.chainedNext !is null) {
            const next = nativeExceptionObject(exception.chainedNext);
            nativeThrowableNext[classIdentityAddress(object)] = next;
        }

        return object;
    }

    private ExpressionResult nativeExceptionBaseObject(
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

        auto metadata = AggregateValue.allocateClass(class_.type);
        initializeNativeClassBody(this, class_.type, metadata);
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
            metadata = AggregateValue.withClassFieldNamed(
                metadata,
                "msg",
                characterArrayValue(messageType, message),
            );
        }

        if (nativeObjectPointer is null) {
            const address = AggregateValue.nativeClassBodyAddress(metadata);
            nativeClassTypes[address] = class_.type;
            nativeClassOwners[address] = metadata;
            return metadata;
        }

        auto address = cast(void*) nativeObjectPointer;
        nativeClassTypes[address] = class_.type;
        nativeExceptionMetadata[address] = metadata;
        return ExpressionResult.pointerValue(address);
    }

    private void hydrateNativeExceptionMetadata(
        ref ExpressionResult metadata,
        imported!"dmd.dclass".ClassDeclaration class_,
        void* nativeObjectPointer,
    ) {
        import quickbite.backends.interpreter.layout: classFields, fieldName;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue, writeValue;

        auto destination = Place(
            AggregateValue.nativeClassBodyAddress(metadata),
            class_.type,
        );
        auto source = Place(nativeObjectPointer, class_.type);
        foreach (field; classFields(class_)) {
            const name = fieldName(field);
            if (name == "msg" || name == "_nextInChainPtr")
                continue;
            writeValue(destination.field(field), readValue(source.field(field)));
        }
    }

    private ExpressionResult* classMetadata(in ExpressionResult object) {
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
            return AggregateValue.hasClassFieldNamed(*metadata, name);
        return false;
    }

    private ExpressionResult classFieldNamed(in ExpressionResult object, in string name) {
        if (object.isNativeAggregate)
            return AggregateValue.classFieldNamed(object, name);
        if (auto metadata = classMetadata(object))
            return AggregateValue.classFieldNamed(*metadata, name);
        throw new Exception("Class field metadata is unavailable.");
    }

    private ExpressionResult withClassFieldNamed(
        in ExpressionResult object,
        in string name,
        in ExpressionResult field,
    ) {
        if (object.isNativeAggregate)
            return AggregateValue.withClassFieldNamed(object, name, field);
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

    private ExpressionResult chainExceptionObject(in ExpressionResult thrown, in ExpressionResult next) {
        if (!classHasFieldNamed(thrown, "_nextInChainPtr"))
            return thrown;

        const chained = withClassFieldNamed(thrown, "_nextInChainPtr", next);
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

        if (dynamicClass(thisValue) !is null && isThrowableConstructor(function_)) {
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
            auto initializer = with_.wthis._init.isExpInitializer;
            if (initializer is null)
                throw new Exception("Interpreter with receiver has no initializer.");
            setLocal(
                with_.wthis,
                storageValue(with_.wthis.type, runExpression(initializer.exp)),
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
        in ExpressionResult condition,
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

    private ExpressionResult runExpression(imported!"dmd.expression".Expression expression) {
        if (_temporaryPointerOwners is null)
            _temporaryPointerOwners = new TemporaryPointerOwners;

        const firstOwner = _temporaryPointerOwners.blocks.length;
        const outermost = _temporaryPointerOwners.expressionDepth == 0;
        ++_temporaryPointerOwners.expressionDepth;
        scope(exit) {
            --_temporaryPointerOwners.expressionDepth;
            if (outermost)
                _temporaryPointerOwners.blocks.length = firstOwner;
        }

        return runExpressionImpl(expression);
    }

    private ExpressionResult runExpressionImpl(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;
        import dmd.tokens: EXP;
        import quickbite.backends.interpreter.runtime_values: integerValue, realValue;

        if (auto integer = expression.isIntegerExp) {
            if (integer.type !is null && integer.type.ty == TY.Tenum)
                return ExpressionResult.enumValue(
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

            return ExpressionResult.null_;
        }

        if (auto string_ = expression.isStringExp) {
            import quickbite.backends.interpreter.runtime_string_literals: stringValue;

            NativeBlock pointerStorage;
            const value = stringValue(string_, pointerStorage);
            if (pointerStorage.address !is null)
                retainTemporaryPointerOwner(pointerStorage);
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
                throwAssertError(assertFailureMessage(
                    assert_,
                    runningCalledFunction,
                    inUnitTest,
                    &runExpression,
                ));
            return ExpressionResult(true);
        }

        if (auto not = expression.isNotExp) {
            return ExpressionResult(!isTruthy(runExpression(not.e1)));
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
            return ExpressionResult.void_;
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

        if (auto literal = expression.isFuncExp)
            return runFunctionLiteralDeclaration(literal);

        if (auto arrayLength = expression.isArrayLengthExp)
            return ExpressionResult(AggregateValue.length(runExpression(arrayLength.e1)));

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
                return ExpressionResult(false);

            // Constructor and member-method `this` is the native body
            // pointer. Resolve an unqualified class field through that body.
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
                    return runExpression(initializer.exp);
                return defaultValue(variable);
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
                    const value = defaultValue(variable);
                    setLocal(variable, value);
                    clearUninitializedBindingAddress(bindingPlace(variable).address);
                    return value;
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
            // immutable empty expression value. Dataseg storage must retain that
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

    private ExpressionResult runTupleExpression(imported!"dmd.expression".TupleExp tuple) {
        // DMD lowers a tuple assignment (`target.tupleof = source.tupleof`, or a
        // `Tuple` constructor's `field[] = values[]`) into a `TupleExp`: an
        // optional side-effect prefix `e0` followed by the per-element
        // expressions, which are ordinary assignments the interpreter already
        // evaluates. Run the prefix, then each element in order; the sequence's
        // value is its last element (matching the IR lowering), and is discarded
        // in the statement-expression positions this arises in.
        if (tuple.e0 !is null)
            runExpression(tuple.e0);

        auto result = ExpressionResult.void_;  // mutated below; `const` cannot express the fold
        if (tuple.exps !is null)
            foreach (element; *tuple.exps)
                result = runExpression(element);
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
            return runExpression(structType.defaultInitLiteral(var.loc));

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
            return AggregateValue.classBodyByteSlice(object, symbol.type);
        }

        assert(0, "SymbolDeclaration VarExp was not an aggregate initializer");
    }

    private ExpressionResult runLogicalAndExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        const left = isTruthy(runExpression(logical.e1));
        if (!left)
            return ExpressionResult(false);

        const right = isTruthy(runExpression(logical.e2));
        return ExpressionResult(right);
    }

    private ExpressionResult runLogicalOrExpression(
        imported!"dmd.expression".LogicalExp logical,
    ) {
        const left = isTruthy(runExpression(logical.e1));
        if (left)
            return ExpressionResult(true);

        const right = isTruthy(runExpression(logical.e2));
        return ExpressionResult(right);
    }

    private ExpressionResult runComparisonExpression(
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
            (leftValue == ExpressionResult.null_ && isPointerType(comparison.e1.type));
        const rightIsPointer = rightValue.isPointer ||
            (rightValue == ExpressionResult.null_ && isPointerType(comparison.e2.type));

        if (leftIsPointer && rightIsPointer)
            return runPointerComparison(comparison.op, leftValue, rightValue);

        const left = leftValue.asReal;
        const right = rightValue.asReal;

        if (comparison.op == EXP.lessThan)
            return ExpressionResult(left < right);
        if (comparison.op == EXP.lessOrEqual)
            return ExpressionResult(left <= right);
        if (comparison.op == EXP.greaterThan)
            return ExpressionResult(left > right);
        return ExpressionResult(left >= right);
    }

    // Pointer relations compare their raw host addresses. The caller has
    // already established that both results are pointer-shaped.
    private ExpressionResult runPointerComparison(
        in imported!"dmd.tokens".EXP op,
        in ExpressionResult left,
        in ExpressionResult right,
    ) {
        import dmd.tokens: EXP;

        const difference = left.pointerOffsetDifference(right);

        if (op == EXP.lessThan)
            return ExpressionResult(difference < 0);
        if (op == EXP.lessOrEqual)
            return ExpressionResult(difference <= 0);
        if (op == EXP.greaterThan)
            return ExpressionResult(difference > 0);
        return ExpressionResult(difference >= 0);
    }

    private ExpressionResult runAddExpression(imported!"dmd.expression".AddExp add) {
        import quickbite.frontend.dmd.types: isPointerType;

        const left = runExpression(add.e1);
        const right = runExpression(add.e2);

        // A default-initialized pointer-typed operand (e.g. druntime's
        // dip1008 Throwable chain-link arithmetic on its own default-null
        // `_nextInChainPtr`) reads as `Null`, not a zero-valued `Pointer`;
        // the static operand type still marks it as pointer arithmetic.
        const leftIsPointer = left.isPointer ||
            (left == ExpressionResult.null_ && isPointerType(add.e1.type));
        const rightIsPointer = right.isPointer ||
            (right == ExpressionResult.null_ && isPointerType(add.e2.type));

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

    private ExpressionResult runMinExpression(imported!"dmd.expression".MinExp sub) {
        import quickbite.frontend.dmd.types: isPointerType;

        const left = runExpression(sub.e1);
        const right = runExpression(sub.e2);

        // See `runAddExpression`: a default-null pointer operand reads as
        // `Null`, not a zero-valued `Pointer`.
        const leftIsPointer = left.isPointer ||
            (left == ExpressionResult.null_ && isPointerType(sub.e1.type));
        const rightIsPointer = right.isPointer ||
            (right == ExpressionResult.null_ && isPointerType(sub.e2.type));

        // DMD lowers `p - q` to `(p - q) / elementSize`; return the byte
        // difference so the lowered division yields the element difference
        if (leftIsPointer && rightIsPointer) {
            const scale = leftIsPointer && rightIsPointer
                ? 1
                : pointerElementSize(sub.e1.type);
            return ExpressionResult(
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

    private ExpressionResult runDivExpression(DivExp div) {
        const left = runExpression(div.e1);
        const right = runExpression(div.e2);
        rejectIntMinMinusOneOverflow(left, right, "/");
        return left / right;
    }

    private ExpressionResult runModExpression(ModExp mod) {
        const left = runExpression(mod.e1);
        const right = runExpression(mod.e2);
        rejectIntMinMinusOneOverflow(left, right, "%");
        return left % right;
    }

    private void rejectIntMinMinusOneOverflow(
        in ExpressionResult left,
        in ExpressionResult right,
        in string operator,
    ) const {
        import std.conv: text;

        if (left != ExpressionResult(int.min) || right != ExpressionResult(-1))
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
            runExpression(comma.e1);
            return addressOfExpression(comma.e2, op);
        }

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
            // Re-running `runExpression(dot)` for a detached aggregate read would
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
                            return ExpressionResult.pointerValue(
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
                                ExpressionResult(AggregateValue.length(runExpression(receiverVar))),
                            );
                    const elementIndex = runExpression(index.e2).asLong;
                    const elementPointer = arrayPointer(index.e1, elementIndex, op);
                    if (elementPointer.isPointer)
                        return elementPointer.pointerOffsetBy(
                            cast(long) fieldByteOffset(field),
                        );
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
            auto nativeClassReceiver = runExpression(dot.e1);
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

    // The address of a ref return's lvalue, evaluated in the returning
    // function's own frame (`addressOfRefReturn` mode).
    private ExpressionResult refReturnAddress(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        // DMD lowers a ref-returning ternary to `return *(cond ? &a : &b())`;
        // the address of that dereference is the pointer expression itself.
        if (auto pointer = expression.isPtrExp)
            return runExpression(pointer.e1);

        return addressOfExpression(expression, EXP.address);
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

        ExpressionResult[] arguments;
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
            return ExpressionResult.pointerValue(nativeResult.referenceAddress);
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = call.f;
        auto layout = cachedFrameLayout(call.f);
        child._activationFrame = FrameBlock.allocate(layout);
        child.addressOfRefReturn = true;
        child.result = ExpressionResult(false);
        bindCapturedReferenceSlots(call.f, child);
        forkExecutionStateInto(child);
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

        const receiver = runExpression(dot.e1);
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
                    : runExpression(argument);
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
            return ExpressionResult.pointerValue(nativeResult.referenceAddress);
        }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.addressOfRefReturn = true;
        child.result = ExpressionResult(false);
        bindCapturedReferenceSlots(function_, child);
        forkExecutionStateInto(child);
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindThisReferenceAddress(function_, receiver);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );
        aliasThisToReceiverStorage(child, function_, dot.e1);

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

    // Alias a member callee's `this` to the receiver expression's real
    // storage address. A `ref`-returning or ref-assigned member call must
    // read and mutate the caller's own aggregate: field addresses computed
    // inside the callee (`&_field`, `return _field;`) only reach the
    // caller's struct if `this` is a borrowed view of that exact address,
    // never a detached copy of the receiver's value.
    private void aliasThisToReceiverStorage(
        ref Walker child,
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
    ) {
        import dmd.tokens: EXP;

        if (
            function_.vthis is null ||
            function_.vthis.isThisDeclaration is null
        )
            return;

        // A `this` receiver's address is this activation's own aliased
        // receiver address; composing it via `addressOfExpression` has no
        // lvalue expression to work from.
        const receiverAddress =
            receiverExpression.isThisExp !is null && thisAddress !is null
            ? ExpressionResult.pointerValue(thisAddress)
            : addressOfExpression(receiverExpression, EXP.address);
        if (!receiverAddress.isPointer)
            return;

        child.thisAddress = receiverAddress.pointerAddress;
        if (child._activationFrame.hasReferenceSlot(function_.vthis))
            child._activationFrame.setReferenceSlot(
                function_.vthis,
                child.thisAddress,
            );
        if (function_.vthis.type.toBasetype.isTypeStruct !is null) {
            import quickbite.backends.interpreter.layout: typeByteSize;
            import quickbite.backends.interpreter.native_aggregate:
                NativeAggregate;
            import quickbite.backends.interpreter.native_block: NativeBlock;

            child.thisValue = ExpressionResult.nativeAggregateValue(NativeAggregate(
                function_.vthis.type,
                NativeBlock.borrow(
                    receiverAddress.pointerAddress,
                    typeByteSize(function_.vthis.type),
                ),
            ));
        }
    }

    // A `ref` foreach variable over an input range may bind to a `front`
    // result returned by value. DMD represents its per-iteration temporary as
    // `AddrExp(CallExp)`: evaluate the call once into typed native storage and
    // return that ordinary temporary's address.
    private ExpressionResult addressOfCallResultTemporary(
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
        retainTemporaryPointerOwner(temporary);
        return ExpressionResult.pointerValue(temporary.address);
    }

    // Forks execution metadata. Binding storage is never copied: each child
    // owns a fresh activation frame, captures borrow parent addresses, and
    // module storage is shared directly.
    private void forkExecutionStateInto(ref Walker child) {
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
        child.nativeThrowableRoots = nativeThrowableRoots.dup;
        child.nativeThrowableNext = nativeThrowableNext.dup;
        child.nativeFunctionPointerSlots = nativeFunctionPointerSlots.dup;
        child.nativeTypeInfoSlots = nativeTypeInfoSlots.dup;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.nativeClassTypes = nativeClassTypes.dup;
        child.nativeClassOwners = nativeClassOwners.dup;
        child.nativeExceptionMetadata = nativeExceptionMetadata.dup;
        child.nativeDelegateSlots = nativeDelegateSlots.dup;
        child.nestedContextFrames = nestedContextFrames.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentFrames = lazyArgumentFrames.dup;
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
                ExpressionResult(AggregateValue.length(readValue(receiverPlace))),
            );
        const outerOffset = runExpression(index.e2).asLong;
        const pointer = ExpressionResult.pointerValue(
            receiverPlace.index(cast(size_t) outerOffset).address,
        );
        if (selfAddress)
            return pointer;
        return ExpressionResult.pointerValue(
            Place(cast(void*) pointer.pointerAddress, expression.type)
                .index(cast(size_t) offset)
                .address,
        );
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
                                            ExpressionResult(
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
                                setLocal(index.lengthVar, ExpressionResult(rowLength));
                            const elementOffset = runExpression(index.e2).asLong;
                            if (cast(size_t) elementOffset >= rowLength)
                                throwRangeError(
                                    "quickbite.backends.interpreter.place.Place.index: "
                                    ~ "index out of range for static array place",
                                );

                            try {
                                const pointer = ExpressionResult.pointerValue(
                                    resolveInnerPlace()
                                        .index(cast(size_t) elementOffset)
                                        .address,
                                );
                                if (selfAddress)
                                    return pointer;
                                return ExpressionResult.pointerValue(
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
                                            ExpressionResult(AggregateValue.length(readValue(base))),
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
                    const sourceLength = AggregateValue.length(arrayValue);
                    setLocal(index.lengthVar, ExpressionResult(sourceLength));
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
                        import quickbite.backends.interpreter.place: Place;

                        try {
                            auto fieldPlace = placeOfLvalue(
                                field,
                                (variable) @safe => addressableBindingBase(variable),
                                (expression) @system =>
                                    cast(size_t) runExpression(expression).asLong,
                            );
                            const pointer = ExpressionResult.pointerValue(
                                fieldPlace.index(cast(size_t) outerOffset).address,
                            );
                            if (selfAddress)
                                return pointer;
                            // Same hazard as the `VarExp` arm above.
                            return ExpressionResult.pointerValue(
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
                    auto aggregate = AggregateValue.native(arrayValue);
                    retainTemporaryPointerOwner(aggregate.storage);
                    auto elementAddress = AggregateValue.elementAddress(
                        arrayValue,
                        cast(size_t) outerOffset,
                    );
                    if (selfAddress)
                        return ExpressionResult.pointerValue(elementAddress);
                    import quickbite.backends.interpreter.place: Place;

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
                import quickbite.backends.interpreter.layout:
                    classFields, fieldByteOffset, typeByteSize;
                import quickbite.frontend.dmd.types:
                    isDynamicArrayType, isStaticArrayType;

                if (auto receiver = dot.e1.isVarExp)
                    if (auto variable = receiver.var.isVarDeclaration)
                        if (auto field = dot.var.isVarDeclaration)
                            if (hasBindingPlace(variable)) {
                                auto place = bindingPlace(variable);
                                if (place.type.toBasetype.isTypeClass !is null)
                                    place = place.deref;
                                return ExpressionResult.pointerValue(
                                    place.field(field).index(cast(size_t) offset).address,
                                );
                            }

                auto elementType = dot.type.toBasetype.nextOf.toBasetype;
                auto structType = elementType.isTypeStruct;

                const value = runExpression(array);
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

    // Write scalar leaves of a struct cell into its native layout.
    private void writeStructCellScalarFields(ref NativeStruct cell, in ExpressionResult structValue) {
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

    private ExpressionResult readBindingValue(VarDeclaration variable) {
        materializeDatasegInitializer(variable);

        import dmd.astenums: TY;

        if (hasBindingPlace(variable) && variable.type.toBasetype.ty == TY.Tdelegate)
            if (auto delegate_ = bindingPlace(variable).address in nativeDelegateSlots)
                return *delegate_;

        if (hasBindingPlace(variable))
            if (auto function_ = bindingPlace(variable).address in nativeFunctionPointerSlots)
                return *function_;

        if (hasBindingPlace(variable))
            return readStoredValue(bindingPlace(variable));

        return defaultValue(variable);
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

    private ExpressionResult runFunctionLiteralDeclaration(
        imported!"dmd.expression".FuncExp literal,
    ) {
        if (literal.fd is null)
            throw new Exception("Unsupported eval expression: functionLiteral");

        const functionPointer = newFunctionPointerValue(literal.fd);

        RuntimeDelegate runtime;
        runtime.function_ = literal.fd;
        runtime.functionPointerId = functionPointer.functionPointerId;
        runtime.contextPointer = ExpressionResult.pointerValue(null);
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
                auto address = capturedBindingAddress(variable);
                if (address !is null)
                    addresses[variable] = address;
            } catch (Exception) {
                continue;
            }
        }

        return addresses;
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
        return dereferencePointerValue(pointer, runExpression(pointer.e1));
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
        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(value))
            elements ~= AggregateValue.elementAt(value, index);

        return elements;
    }

    private ExpressionResult[] arrayPointerElements(in ExpressionResult value) {
        return arrayElements(value);
    }

    private long arrayPointerOffset(in ExpressionResult value, in long offset) {
        return offset;
    }

    private ExpressionResult runConditionalExpression(
        imported!"dmd.expression".CondExp conditional,
    ) {
        return isTruthy(runExpression(conditional.econd)) ?
            runExpression(conditional.e1) :
            runExpression(conditional.e2);
    }

    private ExpressionResult runIdentityExpression(
        imported!"dmd.expression".IdentityExp identity,
    ) {
        import dmd.tokens: EXP;

        const left = runExpression(identity.e1);
        const right = runExpression(identity.e2);
        // dmd lowers a POD struct's `==` (no user-defined `opEquals`) into an
        // `is` expression (`IdentityExp`), since memberwise equality and
        // bitwise identity coincide for such structs. Route that case through
        // `equalValues` (the same field-recursive, numeric-scalar-coercing
        // comparison a direct `==` uses) instead of a raw `ExpressionResult` compare: a
        // struct field written by anything other than an enum-typed literal
        // `IntegerExp` (default-init, a decoded value, ...) keeps a plain
        // scalar `ExpressionResult` rather than the `EnumValue` variant `runExpression`
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
                right == ExpressionResult.null_ ||
            right.isPointer && right.pointerAddress is null &&
                left == ExpressionResult.null_;
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
            return ExpressionResult(!same);

        return ExpressionResult(same);
    }

    private void* classIdentityAddress(in ExpressionResult value) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (value == ExpressionResult.null_)
            return null;

        if (value.isNativeAggregate) {
            auto type = AggregateValue.native(value).type.toBasetype;
            return type.isTypeClass is null
                ? null
                : AggregateValue.nativeClassBodyAddress(value);
        }
        if (value.isPointer)
            return value.pointerAddress;
        return null;
    }

    private ExpressionResult runCallExpression(imported!"dmd.expression".CallExp call) {
        import dmd.expression: Expression;
        import quickbite.backends.interpreter.builtins:
            binaryBuiltinCall,
            interpreterBuiltinArgumentCount,
            tryInterpreterBuiltin,
            unaryBuiltinCall;
        import quickbite.backends.interpreter.frame_layout:
            isReferenceParameter;

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

        ExpressionResult[] arguments;
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
                    // The lazy argument is captured as an expression below;
                    // this aligned entry is never bound or evaluated.
                    arguments ~= ExpressionResult.void_;
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
                import dmd.mtype: Type;
                import quickbite.backends.interpreter.interception_guard:
                    enforceInterceptionPolicy;

                enforceInterceptionPolicy(call.f, "isStdConvText");
                Type[] argumentTypes;
                foreach (argumentExpression; argumentExpressions)
                    argumentTypes ~= argumentExpression.type;
                return stdConvTextCall(arguments, argumentTypes, call.type);
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
            } else
                receiver = runExpression(dot.e1);
            auto receiverDestructor = constructedReceiverDestructor(dot.e1);
            scope(exit)
                if (receiverDestructor !is null)
                    runExpression(receiverDestructor);
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
                    functionName(call.f) == "initializer" &&
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
                    functionName(call.f) == "opEquals" &&
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
                        ))
                        return nativeResult.value;
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
                    return ExpressionResult(false);
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

    // A constructor used directly as a member receiver owns a full-expression
    // temporary. DMD records that cleanup on the synthesized declaration
    // rather than emitting a DtorExpStatement, so return it to the call site
    // that spans the temporary's lifetime.
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
        return variable is null ? null : variable.edtor;
    }

    private ExpressionResult runRefArgumentExpression(
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

                const address = refReturningCallAddress(call, EXP.address);
                if (address.isPointer) {
                    evaluated.address = address.pointerAddress;
                    return readStoredValue(Place(evaluated.address, argument.type));
                }
            }

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

        if (auto pointer = argument.isPtrExp) {
            const address = runExpression(pointer.e1);
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
        if (variable !is null && isUninitializedBinding(variable))
            return ExpressionResult.void_;
        if (variable !is null) {
            const address = bindingPointerValue(variable);
            if (address.isPointer)
                evaluated.address = address.pointerAddress;
        }

        auto previous = _evaluatedReferenceArgumentIndices;
        _evaluatedReferenceArgumentIndices = &evaluated.indices;
        scope(exit)
            _evaluatedReferenceArgumentIndices = previous;

        return runExpression(argument);
    }

    // Run an interpreted delegate that native code called back into through the
    // FFI reverse bridge. The callback supplies only values (no source argument
    // expressions), so synthesise null placeholders, as the static-initialiser
    // delegate path does.
    private ExpressionResult invokeNativeCallback(
        in ExpressionResult callee,
        in ExpressionResult[] arguments,
    ) {
        import dmd.expression: Expression;

        return runDelegateCall(callee, arguments, new Expression[](arguments.length));
    }

    private ExpressionResult runDelegateCall(
        in ExpressionResult callee,
        in ExpressionResult[] arguments,
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

    private ExpressionResult delegateReceiver(in RuntimeDelegate runtime) {
        return runtime.receiver;
    }

    private ExpressionResult runDelegatePointerExpression(
        imported!"dmd.expression".DelegatePtrExp expression,
    ) {
        return delegateProperty(runExpression(expression.e1), "ptr");
    }

    private ExpressionResult runDelegateFunctionPointerExpression(
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

    private ExpressionResult runStringForeachApplyCall(
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
            if (result != ExpressionResult.void_ && result.asLong != 0)
                return result;
        }

        return ExpressionResult(0);
    }

    private ExpressionResult[] stringForeachApplyElements(
        in string helper,
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

        string encoded;
        foreach (index; 0 .. AggregateValue.length(source))
            encoded ~= cast(char) AggregateValue.elementAt(source, index)
                .castTo!long.asLong;

        ExpressionResult[] values;
        size_t index;
        while (index < encoded.length)
            values ~= ExpressionResult(decode(encoded, index));

        return values;
    }

    private ExpressionResult[] decodedUtf16Dchars(in ExpressionResult source) {
        import std.utf: decode;

        wstring encoded;
        foreach (index; 0 .. AggregateValue.length(source))
            encoded ~= cast(wchar) AggregateValue.elementAt(source, index)
                .castTo!long.asLong;

        ExpressionResult[] values;
        size_t index;
        while (index < encoded.length)
            values ~= ExpressionResult(decode(encoded, index));

        return values;
    }

    private ExpressionResult[] utf8EncodedDstringChars(in ExpressionResult source) {
        import std.utf: encode;

        ExpressionResult[] values;
        foreach (index; 0 .. AggregateValue.length(source)) {
            char[4] encoded;
            const length = encode(
                encoded,
                cast(dchar) AggregateValue.elementAt(source, index)
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

    private ExpressionResult runArrayOpAddAssignCall(
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

        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(left))
            elements ~= AggregateValue.elementAt(left, index) +
                AggregateValue.elementAt(right, index);

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

        const current = readBindingValue(variable);

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? AggregateValue.length(current)
            : cast(size_t) runExpression(slice.upr).asLong;
        if (upper - lower != elements.length)
            throw new Exception("Unsupported eval call.");

        ExpressionResult[] updated;
        foreach (index; 0 .. AggregateValue.length(current))
            updated ~= index >= lower && index < upper
                ? elements[index - lower]
                : AggregateValue.elementAt(current, index);

        setLocal(variable, reconstructStoredArray(variable.type, updated));
        clearUninitializedBindingAddress(bindingPlace(variable).address);
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

        if (call.arguments is null || call.arguments.length == 0)
            throw new Exception("Unsupported eval call.");

        auto destinationExpression = (*call.arguments)[0];
        const destination = runExpression(destinationExpression);

        ExpressionResult operand() {
            if (call.arguments.length < 2)
                throw new Exception("Unsupported eval call.");
            return runExpression((*call.arguments)[1]);
        }

        with (AtomicHook) final switch (hook) {
            case aligned:
                return ExpressionResult(true);

            case load:
                return readPointerTarget(destinationExpression, destination);

            case store:
                writePointerTarget(destinationExpression, destination, operand);
                return ExpressionResult.void_;

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
                        ExpressionResult(previous.asLong + delta),
                    ),
                );
                return previous;
            }
        }
    }

    private ExpressionResult readPointerTarget(
        imported!"dmd.expression".Expression pointerExpression,
        in ExpressionResult pointer,
    ) {
        return loadNativePointerElement(pointerExpression.type, pointer, 0);
    }

    // DMD lowers associative array operations to druntime template hooks in
    // `core.internal.newaa` and `object`; interpret the semantics directly
    // instead of executing the druntime hook bodies.
    private ExpressionResult runAssocArrayHookCall(
        imported!"dmd.expression".CallExp call,
        in imported!"quickbite.backends.interpreter.builtins".AssocArrayHook hook,
    ) {
        import quickbite.backends.interpreter.builtins: AssocArrayHook;

        if (call.arguments is null)
            throw new Exception("Unsupported eval call.");

        with (AssocArrayHook) final switch (hook) {
            case length:
                requireArgumentCount(call, 1);
                return ExpressionResult(assocArrayLength(assocArrayArgumentValue(
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
                return ExpressionResult(assocArrayEqual(
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

    private ExpressionResult runAssocArrayReadCall(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.messages: missingKeyMessage;

        const aa = assocArrayArgumentValue((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        if (!isNativeAssocArray(aa))
            throw new Exception(missingKeyMessage(
                (*call.arguments)[1],
                (*call.arguments)[0],
            ));
        auto keySlot = nativeAssocKeySlot(nativeAssocArray(aa), key);
        auto valueAddress = nativeAssocArray(aa).valueAddress(keySlot.address);
        if (valueAddress is null)
            throw new Exception(missingKeyMessage(
                (*call.arguments)[1],
                (*call.arguments)[0],
            ));
        return ExpressionResult.pointerValue(valueAddress);
    }

    // `aa[key] = value` lowers to a write through the slot pointer returned
    // by `_d_aaGetY(aa, key, found)`; the write-back happens via the slot
    // alias recorded for the pointer variable
    private ExpressionResult runAssocArrayLvalueCall(
        imported!"dmd.expression".CallExp call,
    ) {
        auto aaArgument = (*call.arguments)[0];
        auto aa = assocArrayArgumentValue(aaArgument);
        if (aa == ExpressionResult.null_) {
            import quickbite.backends.interpreter.native_assoc_array: allocateValue;

            aa = ExpressionResult.nativeAggregateValue(allocateValue(
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
        bool found;
        auto header = nativeAssocArray(aa);
        auto keySlot = nativeAssocKeySlot(header, key);
        auto valueAddress = header.getOrAdd(keySlot.address, found);
        if (auto foundVariable = (*call.arguments)[2].isVarExp)
            if (auto variable = foundVariable.var.isVarDeclaration)
                setLocal(variable, ExpressionResult(found));
        return ExpressionResult.pointerValue(valueAddress);
    }

    private ExpressionResult runAssocArrayInCall(
        imported!"dmd.expression".CallExp call,
    ) {
        const aa = assocArrayArgumentValue((*call.arguments)[0]);
        const key = runExpression((*call.arguments)[1]);

        if (!isNativeAssocArray(aa))
            return ExpressionResult.null_;
        auto keySlot = nativeAssocKeySlot(nativeAssocArray(aa), key);
        auto valueAddress = nativeAssocArray(aa).valueAddress(keySlot.address);
        return valueAddress is null ? ExpressionResult.null_ : ExpressionResult.pointerValue(valueAddress);
    }

    private ExpressionResult runAssocArrayRemoveCall(
        imported!"dmd.expression".CallExp call,
    ) {
        auto var = (*call.arguments)[0].isVarExp;
        if (var is null)
            throw new Exception("Unsupported eval call.");

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception("Unsupported eval call.");

        const current = readBindingValue(variable);

        const key = runExpression((*call.arguments)[1]);
        if (!isNativeAssocArray(current))
            return ExpressionResult(false);
        auto header = nativeAssocArray(current);
        auto keySlot = nativeAssocKeySlot(header, key);
        return ExpressionResult(header.remove(keySlot.address));
    }

    private ExpressionResult runAssocArrayApply2Call(
        imported!"dmd.expression".CallExp call,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        const aa = assocArrayArgumentValue((*call.arguments)[0]);
        const keys = assocArrayKeys(aa, null);
        const values = assocArrayValues(aa, null);
        auto body = functionPointerExpressionFunction((*call.arguments)[1]);
        const delegate_ = body is null
            ? runExpression((*call.arguments)[1])
            : ExpressionResult.void_;

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

        return ExpressionResult(0);
    }

    // `AggregateValue.elementAt`'s plain memory read sees a delegate-typed
    // element's zeroed bytes, not its live callable ExpressionResult -- `assocArrayValues`
    // registers a live delegate entry out-of-band in `nativeDelegateSlots`,
    // keyed by the RESULT array's own element address, exactly the same gap
    // `loadNativePointerElement`'s identical `TY.Tdelegate` arm checks
    // before falling through to a plain read.
    private ExpressionResult nativeArrayElementAt(in ExpressionResult array, in size_t index) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        auto aggregate = AggregateValue.native(array);
        auto elementType = aggregate.type.toBasetype.nextOf;
        if (elementType !is null && elementType.toBasetype.ty == TY.Tdelegate)
            if (auto delegate_ = AggregateValue.elementAddress(array, index) in nativeDelegateSlots)
                return *delegate_;
        return readStoredValue(Place(aggregate.address, aggregate.type).index(index));
    }

    private size_t assocArrayLength(in ExpressionResult value) {
        return value == ExpressionResult.null_ ? 0 : nativeAssocArray(value).length;
    }

    // Druntime AA hooks receive the address of the guest AA handle. A native
    // pointer therefore denotes the handle slot, not the associative-array
    // value itself; recover the typed slot before interpreting the argument.
    private ExpressionResult assocArrayArgumentValue(
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

    private ExpressionResult duplicateAssocArray(in ExpressionResult value) {
        if (value == ExpressionResult.null_)
            return value;

        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto source = nativeAssocArray(value);
        ExpressionResult[] keys;
        ExpressionResult[] values;
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

    private bool assocArrayEqual(in ExpressionResult left, in ExpressionResult right) {
        if (left == ExpressionResult.null_ || right == ExpressionResult.null_)
            return assocArrayLength(left) == 0 && assocArrayLength(right) == 0;

        return equalAssocArrayValues(left, right);
    }

    private ExpressionResult assocArrayKeys(in ExpressionResult value, imported!"dmd.mtype".Type resultType) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (value == ExpressionResult.null_) {
            ExpressionResult[] keys;
            return reconstructStoredArray(resultType, keys);
        }
        import dmd.mtype: TypeDArray;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto header = nativeAssocArray(value);
        ExpressionResult[] keys;
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
    // entry's live callable ExpressionResult lives out-of-band, keyed by the value
    // slot's own address, exactly as `runAssocArrayLvalueCall`'s
    // pointer-index write path (`storeNativePointerElement`) already
    // registers it. `AggregateValue.reconstructArray`'s `writeValue` call
    // below only ever accepts `ExpressionResult.null_` for a Tdelegate element (an
    // interpreted delegate is not native-composable bytes), so every live
    // entry is substituted with `ExpressionResult.null_` for the reconstruction and
    // then re-registered at the RESULT array's own element address --
    // mirroring `structLiteralValue`'s identical substitute-then-register
    // handling of a live delegate struct-literal field.
    private ExpressionResult assocArrayValues(in ExpressionResult value, imported!"dmd.mtype".Type resultType) {
        import dmd.astenums: TY;
        import dmd.mtype: TypeDArray;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        if (value == ExpressionResult.null_) {
            ExpressionResult[] values;
            return reconstructStoredArray(resultType, values);
        }

        auto header = nativeAssocArray(value);
        const isDelegateValue = header.valueType.toBasetype.ty == TY.Tdelegate;
        ExpressionResult[] values;
        size_t[] liveDelegateIndices;
        ExpressionResult[] liveDelegateValues;
        foreach (index; 0 .. header.length) {
            auto address = header.valueAt(index).address;
            if (isDelegateValue)
                if (auto delegate_ = address in nativeDelegateSlots) {
                    liveDelegateIndices ~= index;
                    liveDelegateValues ~= *delegate_;
                    values ~= ExpressionResult.null_;
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

    private bool isNativeAssocArray(in ExpressionResult value) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        return value.isNativeAggregate &&
            AggregateValue.native(value).type.toBasetype.isTypeAArray !is null;
    }

    private imported!"quickbite.backends.interpreter.native_assoc_array".NativeAssocArray* nativeAssocArray(
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_assoc_array: headerAt;

        return headerAt(AggregateValue.native(value).address);
    }

    private imported!"quickbite.backends.interpreter.native_block".NativeBlock nativeAssocKeySlot(
        imported!"quickbite.backends.interpreter.native_assoc_array".NativeAssocArray* header,
        in ExpressionResult key,
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

    private ExpressionResult runFunction(
        imported!"dmd.func".FuncDeclaration function_,
        in ExpressionResult[] arguments,
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
        child.result = ExpressionResult(false);
        bindCapturedReferenceSlots(function_, child, closureAddresses);
        forkExecutionStateInto(child);
        child.bindFunctionParameters(
            function_,
            arguments,
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

    private ExpressionResult nativeMemberReceiver(
        FuncDeclaration function_,
        in ExpressionResult receiver,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (receiver.isNativeAggregate)
            return receiver;

        auto vthis = function_.vthis;
        if (vthis is null || !AggregateValue.isStruct(receiver))
            return receiver;

        ExpressionResult[] fields;
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
        in ExpressionResult receiver,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        auto vthis = function_.vthis;
        if (vthis is null)
            return;

        if (receiver.isNativeAggregate)
            thisAddress = AggregateValue.native(receiver).address;
        else if (receiver.isPointer)
            thisAddress = receiver.pointerAddress;

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
        // Set by a caller that already evaluated a `PtrExp` or `IndexExp`
        // receiver's side-effecting operand itself (to compute `receiver`
        // above) and kept the resulting address around. The `this`-rebind
        // below needs that same address; reusing it here -- instead of
        // re-deriving it from `receiverExpression` -- keeps a side-effecting
        // operand (e.g. `p()` in `p().get()`, or `i++` in `a[i++].method()`)
        // evaluated exactly once.
        const(ExpressionResult)* precomputedReceiverPointerAddress = null,
    ) {
        const memberReceiver = nativeMemberReceiver(function_, receiver);

        if (declarationName(function_) == "next") {
            if (classHasType(memberReceiver, "Throwable")) {
                const body = classIdentityAddress(memberReceiver);
                if (auto next = body in nativeThrowableNext)
                    return *next;

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
        child.result = ExpressionResult(false);
        bindCapturedReferenceSlots(
            function_,
            child,
            nestedReceiverCapturedAddresses(function_, memberReceiver),
        );
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
            _activationFrame,
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

            ExpressionResult address;
            if (
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
                child.thisAddress = address.pointerAddress;
                if (child._activationFrame.hasReferenceSlot(function_.vthis))
                    child._activationFrame.setReferenceSlot(
                        function_.vthis,
                        child.thisAddress,
                    );
                auto receiverType = child.thisValue.isNativeAggregate
                    ? AggregateValue.native(child.thisValue).type
                    : function_.vthis.type;
                child.thisValue = ExpressionResult.nativeAggregateValue(NativeAggregate(
                    receiverType,
                    NativeBlock.borrow(
                        address.pointerAddress,
                        typeByteSize(receiverType),
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
        in ExpressionResult[] arguments,
        in bool captureLocals = false,
    ) {
        mergeNativeThrowableRoots(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
        nativeDelegateSlots = child.nativeDelegateSlots;
        nestedContextFrames = child.nestedContextFrames;
        nativeFunctionPointerSlots = child.nativeFunctionPointerSlots;
        nativeTypeInfoSlots = child.nativeTypeInfoSlots;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentFrames = child.lazyArgumentFrames;
    }

    private void mergeMemberFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in ExpressionResult[] arguments,
    ) {
        mergeNativeThrowableRoots(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
        nativeDelegateSlots = child.nativeDelegateSlots;
        nestedContextFrames = child.nestedContextFrames;
        nativeFunctionPointerSlots = child.nativeFunctionPointerSlots;
        nativeTypeInfoSlots = child.nativeTypeInfoSlots;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentFrames = child.lazyArgumentFrames;
        child.returned = false;
    }

    private void mergeNativeThrowableRoots(ref Walker child) {
        foreach (pointer, throwable; child.nativeThrowableRoots)
            nativeThrowableRoots[pointer] = throwable;
    }

    private ExpressionResult structValueFromCell(in ExpressionResult current, ref NativeStruct cell) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar;
        import quickbite.frontend.dmd.types:
            isDynamicArrayType, isStaticArrayType;

        ExpressionResult value = current;
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
                    ExpressionResult elementValue;
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
                    arrayValueFromCell(fieldType, arrayCell),
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

            import dmd.astenums: TY;
            if (variable.type.toBasetype.ty == TY.Tdelegate)
                if (auto delegate_ = address in nativeDelegateSlots)
                    child.nativeDelegateSlots[address] = *delegate_;

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
                lazyArgumentExpressions[parameter] = *expression;
                if (auto capturedFrame = variable in lazyArgumentFrames)
                    lazyArgumentFrames[parameter] = *capturedFrame;
                return;
            }
        }

        if (argumentExpression is null)
            throw new Exception("Unsupported interpreter call arguments.");

        lazyArgumentExpressions[parameter] = argumentExpression;
        lazyArgumentFrames[parameter] = callerFrame;
    }

    private ExpressionResult runLazyArgument(VarDeclaration variable) {
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
        return runLazyArgumentExpression(*expression);
    }

    private ExpressionResult runLazyArgumentExpression(Expression expression) {
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

    private ExpressionResult runEqualExpression(imported!"dmd.expression".EqualExp equal) {
        import dmd.tokens: EXP;

        const left = runExpression(equal.e1);
        const right = runExpression(equal.e2);
        const same = equalValues(left, right);
        if (equal.op == EXP.notEqual)
            return ExpressionResult(!same);
        return ExpressionResult(same);
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

        if (AggregateValue.isStruct(left) && AggregateValue.isStruct(right))
            return equalStructValues(left, right);

        const leftIsAssocArray = AggregateValue.isAssocArray(left);
        const rightIsAssocArray = AggregateValue.isAssocArray(right);
        if (
            (leftIsAssocArray && (rightIsAssocArray || right == ExpressionResult.null_)) ||
            (rightIsAssocArray && left == ExpressionResult.null_)
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
    // falls back to the raw comparison unchanged.
    private bool equalDelegateValues(in ExpressionResult left, in ExpressionResult right) {
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

    private bool equalArrayValues(in ExpressionResult left, in ExpressionResult right) {
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

    private ExpressionResult arrayElementForEquality(in ExpressionResult value, in size_t index) {
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
    // keeps its plain scalar `ExpressionResult` kind instead of `runExpression`'s
    // `ExpressionResult.enumValue` tagging, so a raw `ExpressionResult == ExpressionResult` compare (the
    // `left == right` fallback above) never considers it equal to a
    // same-valued `EnumValue`-tagged field, even though real D's memberwise
    // struct equality does. Recurse field-by-field through `equalValues`
    // (mirroring `equalArrayValues`) so each field gets the same
    // numeric-scalar coercion a top-level `==` already applies.
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
            return AggregateValue.fieldAt(value, index);

        auto aggregate = AggregateValue.native(value);
        auto fields = structFields(aggregate.type.toBasetype.isTypeStruct);
        return readStoredValue(
            Place(aggregate.address, aggregate.type).field(fields[index]),
        );
    }

    private bool equalAssocArrayValues(in ExpressionResult left, in ExpressionResult right) {
        import quickbite.backends.interpreter.native_assoc_array: headerAt;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: readValue;

        auto leftHeader = left == ExpressionResult.null_
            ? null
            : headerAt(AggregateValue.native(left).address);
        auto rightHeader = right == ExpressionResult.null_
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

    private ExpressionResult runCompoundAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        const left = runExpression(assign.e1);
        const right = runExpression(assign.e2);
        const value = compoundAssignedValue(assign, left, right);
        writeLocation(assign.e1, value);
        return runExpression(assign.e1);
    }

    private ExpressionResult compoundAssignedValue(
        imported!"dmd.expression".BinExp assignment,
        in ExpressionResult left,
        in ExpressionResult right,
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

    private ExpressionResult runPowExpression(imported!"dmd.expression".PowExp pow) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const base = runExpression(pow.e1);
        auto exponent = runExpression(pow.e2).asLong;
        if (exponent < 0)
            throw new Exception("Unsupported negative integer exponent.");

        ExpressionResult result = backendCastValue(ExpressionResult(1), backendCastTarget(pow.type));
        ExpressionResult factor = backendCastValue(base, backendCastTarget(pow.type));
        while (exponent != 0) {
            if ((exponent & 1) != 0)
                result = result * factor;
            exponent >>= 1;
            if (exponent != 0)
                factor = factor * factor;
        }

        return backendCastValue(result, backendCastTarget(pow.type));
    }

    private ExpressionResult runIntegerComplementExpression(
        imported!"dmd.expression".ComExp complement,
    ) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        return backendCastValue(
            ExpressionResult(~runExpression(complement.e1).asLong),
            backendCastTarget(complement.type),
        );
    }

    private ExpressionResult runIntegerBinaryExpression(
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

    private ExpressionResult runIntegerBinaryValue(
        imported!"dmd.expression".BinExp expression,
        in ExpressionResult leftValue,
        in ExpressionResult rightValue,
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

        return backendCastValue(ExpressionResult(result), backendCastTarget(expression.type));
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
        import quickbite.backends.interpreter.messages: receiverName;
        import std.conv: text;

        if (auto field = dot.var.isVarDeclaration) {
            if (field.type.toBasetype.isTypeClass !is null)
                if (auto variableExpression = dot.e1.isVarExp)
                    if (auto variable = variableExpression.var.isVarDeclaration)
                        if (hasBindingPlace(variable)) {
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
                        if (hasBindingPlace(variable)) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            if (auto function_ = fieldPlace.address in nativeFunctionPointerSlots)
                                return *function_;
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
                return characterArrayValue(
                    dot.type,
                    typeInfoName(typeidObjectType(typeid_)),
                );

        if (declarationName(dot.var) == "name")
            if (auto symbol = dot.e1.isSymOffExp)
                if (auto type = symbolOffsetTypeInfoType(symbol))
                    return characterArrayValue(dot.type, typeInfoName(type));

        if (declarationName(dot.var) == "name")
            if (dot.e1.isPtrExp !is null)
                return runClassInfoNameOwnerExpression(dot.e1, dot.type);

        const receiver = runExpression(dot.e1);
        if (receiver == ExpressionResult.null_)
            throw new Exception(text(
                "class `",
                receiverName(dot.e1),
                "` is `null` and cannot be dereferenced",
            ));

        if (receiver.isFunctionPointer && receiver.functionPointerId in delegates)
            return delegateProperty(receiver, declarationName(dot.var));

        if (receiver.isTypeName && declarationName(dot.var) == "name")
            return characterArrayValue(dot.type, receiver.asTypeNameString);

        // Native dynamic and associative arrays own their length in typed
        // guest storage.
        if (
            receiver.isNativeAggregate &&
            (AggregateValue.isArray(receiver) || isNativeAssocArray(receiver)) &&
            declarationName(dot.var) == "length"
        )
            return ExpressionResult(AggregateValue.length(receiver));

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
                    bodyType = AggregateValue.native(*metadata).type;
                }
                auto fieldPlace = Place(bodyAddress, bodyType)
                    .field(dot.var.isVarDeclaration);
                if (fieldPlace.type.isTypeClass !is null) {
                    if (
                        auto typeInfo = fieldPlace.address
                            in nativeTypeInfoSlots
                    )
                        return *typeInfo;
                    auto address = fieldPlace.deref.address;
                    if (address is null)
                        return ExpressionResult.null_;
                    if (auto object = address in nativeClassOwners)
                        return *object;
                    return ExpressionResult.pointerValue(address);
                }
                // A live delegate value has no native ABI function address
                // (the same gap `nativeDelegateSlots`'s own field comment
                // documents), so it lives out-of-band, keyed by the field's
                // own address, exactly as the struct-field read arm below
                // already checks. A class field's address is always in the
                // object body's own storage.
                if (fieldPlace.type.toBasetype.ty == TY.Tdelegate)
                    if (auto delegate_ = fieldPlace.address in nativeDelegateSlots)
                        return *delegate_;
                return readValue(fieldPlace);
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
                    if (hasBindingPlace(variable)) {
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
        return AggregateValue.classBodyByteSlice(object, resultType);
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
            const receiver = runExpression(classInfo.e1);
            if (dynamicClass(receiver) !is null)
                return ExpressionResult.typeName(dynamicClassName(receiver));
        }

        return ExpressionResult.typeName(typeInfoName(classInfo.e1.type));
    }

    private ExpressionResult runClassInfoNameOwnerExpression(
        imported!"dmd.expression".Expression ownerExpression,
        imported!"dmd.mtype".Type resultType,
    ) {
        auto owner = classInfoNameOwnerExpression(ownerExpression);
        const receiver = runExpression(owner);
        if (dynamicClass(receiver) !is null)
            return characterArrayValue(resultType, dynamicClassName(receiver));

        // A native class reference is its body pointer. Its static class type
        // still supplies the ClassInfo name needed by this interpreter-only
        // property path; the pointer remains the storage authority.
        if (receiver.isPointer && owner.type.toBasetype.isTypeClass !is null)
            if (auto dynamicType = receiver.pointerAddress in nativeClassTypes)
                return characterArrayValue(resultType, typeInfoName(*dynamicType));

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
        const receiver = runExpression(dot.e1);
        const name = dot.ident is null ? "" : dot.ident.toString;
        if (name == "re")
            return receiver.complexRealPart;
        if (name == "im")
            return receiver.complexImaginaryPart;

        throw new Exception("Unsupported interpreter property read.");
    }

    private ExpressionResult delegateProperty(in ExpressionResult receiver, in string name) {
        auto runtime = receiver.functionPointerId in delegates;
        if (runtime is null)
            throw new Exception("Unsupported interpreter field read.");

        if (name == "ptr")
            return runtime.contextPointer;

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

            return typeidValue(typeid_, typeInfoName(type));
        }

        auto value = runExpression(expression);
        if (isClassExpression(expression))
            value = rootedNativeClassValue(expression, value);
        if (value == ExpressionResult.null_ || (isClassExpression(expression) &&
            value == ExpressionResult(false)))
            throw new Exception(text(
                "null pointer dereference evaluating typeid. `",
                receiverName(expression),
                "` is `null`",
            ));

        if (dynamicClass(value) !is null)
            return typeidValue(typeid_, dynamicClassName(value));

        return typeidValue(typeid_, typeInfoName(expression.type));
    }

    private ExpressionResult typeidValue(
        imported!"dmd.expression".TypeidExp typeid_,
        in string name,
    ) {
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        return isCharacterArrayType(typeid_.type)
            ? characterArrayValue(typeid_.type, name)
            : ExpressionResult.typeName(name);
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

        const value = runExpression(vector.e1);
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

        const vector = runExpression(vectorArray.e1);
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
        // `FuncExp`; construct its callable before writing the destination.
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

                writeStoredValue(
                    Place(thisAddress, target.type),
                    storageValue(target.type, value),
                );
                thisValue = value;
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
                        if (hasBindingPlace(variable)) {
                            auto fieldPlace = bindingPlace(variable).field(field);
                            nativeDelegateSlots[fieldPlace.address] = value;
                            writeValue(fieldPlace, ExpressionResult.null_);
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
                ? ExpressionResult.pointerValue(AggregateValue.nativeClassBodyAddress(receiver))
                : ExpressionResult.null_;
            if (
                nativeClassReceiver.isPointer &&
                dot.e1.type.toBasetype.isTypeClass !is null
            ) {
                import dmd.astenums: TY;
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: writeValue;

                auto field = dot.var.isVarDeclaration;
                auto bodyAddress = nativeClassReceiver.pointerAddress;
                auto bodyType = dot.e1.type;
                if (auto metadata = bodyAddress in nativeExceptionMetadata) {
                    bodyAddress = AggregateValue.nativeClassBodyAddress(*metadata);
                    bodyType = AggregateValue.native(*metadata).type;
                }
                auto fieldPlace = Place(bodyAddress, bodyType)
                    .field(field);
                // A live delegate value (an interpreted closure, not `null`)
                // has no native ABI function address, so `place_value.
                // writeValue`'s Tdelegate arm only ever accepts `null` --
                // register it out-of-band in `nativeDelegateSlots`, keyed by
                // the field's own address, just as the struct-field write arm
                // above does. A class field's address is the object body's
                // own storage, live for the object's whole lifetime.
                if (field !is null && field.type.toBasetype.ty == TY.Tdelegate) {
                    nativeDelegateSlots[fieldPlace.address] = value;
                    writeValue(fieldPlace, ExpressionResult.null_);
                    return;
                }
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
                    AggregateValue.reconstructNativeArrayWithLength(
                        dot.e1.type,
                        cast(size_t) value.asLong,
                        AggregateValue.nativeArrayAddress(receiver),
                    ),
                );
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

        const receiver = runExpression(dot.e1);
        if (receiver == ExpressionResult.null_)
            throw new Exception("function call through null class reference `null`");

        auto function_ = resolveMemberFunction(call.f, receiver);
        ensureFunctionBodySemantic(function_);

        ExpressionResult[] arguments;
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
                if (
                    index < function_.parameters.length &&
                    (*function_.parameters)[index].type.toBasetype.isTypeClass !is null
                )
                    arguments[$ - 1] =
                        rootedNativeClassValue(argument, arguments[$ - 1]);
                argumentExpressions ~= argument;
                evaluatedArguments ~= evaluated;
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
        child.currentFunction = function_;
        auto layout = cachedFrameLayout(function_);
        child._activationFrame = FrameBlock.allocate(layout);
        child.assignToRefReturn = true;
        child.refReturnAssignedValue = value;
        child.result = ExpressionResult(false);
        bindCapturedReferenceSlots(function_, child);
        forkExecutionStateInto(child);
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindThisReferenceAddress(function_, receiver);
        child.bindFunctionParameters(
            function_,
            arguments,
            argumentExpressions,
            _activationFrame,
            evaluatedArguments,
        );
        aliasThisToReceiverStorage(child, function_, dot.e1);

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
            ensureFunctionBodySemantic, hasNoInterpretableSource;

        ensureFunctionBodySemantic(call.f);
        if (call.f.needThis)
            return false;

        ExpressionResult[] arguments;
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
        child.result = ExpressionResult(false);
        bindCapturedReferenceSlots(call.f, child);
        forkExecutionStateInto(child);
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
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.frontend.dmd.types: arrayElementType;

        const current = runExpression(target.e1);
        const oldLength = current == ExpressionResult.null_ ? 0 : AggregateValue.length(current);
        const newLength = cast(size_t) value.asLong;

        ExpressionResult[] elements;
        foreach (index; 0 .. newLength)
            elements ~= index < oldLength
                ? AggregateValue.elementAt(current, index)
                : runDefaultValue(arrayElementType(target.e1.type));

        writeLocation(target.e1, reconstructStoredArray(target.e1.type, elements));
    }

    private ExpressionResult runDefaultValue(imported!"dmd.mtype".Type type) {
        import dmd.location: Loc;
        import dmd.typesem: defaultInitLiteral;

        return runExpression(type.defaultInitLiteral(Loc.initial));
    }

    private ExpressionResult storageValue(
        imported!"dmd.mtype".Type type,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.runtime_casts:
            backendCastValue = castValue,
            CastTarget,
            tryCastTarget;
        import quickbite.frontend.dmd.types: isCharacterArrayType;

        if (type is null)
            return value;

        if (value.isTypeName && isCharacterArrayType(type))
            return characterArrayValue(type, value.asTypeNameString);

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
                return AggregateValue.nativeAggregateByteSlice(value, type);
        }

        CastTarget target;
        if (!tryCastTarget(type, target))
            return value;

        return backendCastValue(value, target);
    }

    // Delegates to `native_scalar.writeScalar` -- the single scalar<->bytes
    // authority -- rather than re-deriving a
    // scalar's byte width and bit pattern here; this module must not grow
    // its own second set of D layout rules alongside that codec's.
    private ExpressionResult[] scalarBytes(
        imported!"dmd.mtype".Type type,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_scalar: writeScalar;

        auto raw = new ubyte[](typeByteSize(type));
        writeScalar(type, raw, value);

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

    // The inverse of `scalarBytes` above, via `native_scalar.readScalar`.
    // This also now succeeds for `float`/`double`: routing through the
    // single scalar<->bytes codec dropped the old name-matched `switch`'s
    // throw on those two types.
    private ExpressionResult scalarFromBytes(
        imported!"dmd.mtype".Type type,
        in ExpressionResult[] bytes,
    ) {
        import quickbite.backends.interpreter.native_scalar: readScalar;

        auto raw = new ubyte[](bytes.length);
        foreach (index, byte_; bytes)
            raw[index] = cast(ubyte) byte_.asLong;

        return readScalar(type, raw);
    }

    private void writeIndexLocation(
        imported!"dmd.expression".IndexExp index,
        in ExpressionResult value,
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
        // binding.
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
                        bodyType = AggregateValue.native(*metadata).type;
                    }
                    auto fieldPlace = Place(bodyAddress, bodyType)
                        .field(dot.var.isVarDeclaration);
                    const source = readValue(fieldPlace);
                    const updatedArray = AggregateValue.withArrayElement(source, arrayIndex, value);
                    writeValue(fieldPlace, updatedArray);
                    return;
                }
                throw new Exception("Class field assignment needs a native address.");
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
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar, writeScalar;
        import quickbite.frontend.dmd.types: isStaticArrayType;

        auto fields = structFields(unionType);
        if (fieldIndex >= fields.length)
            throw new Exception("Unsupported interpreter union field access.");
        const symbolicValue = value.isTypeName ||
            value.isFunctionPointer ||
            (fields[fieldIndex].type.toBasetype.ty == TY.Tdelegate &&
                value != ExpressionResult.null_);
        auto updated = AggregateValue.withStructField(
            receiver,
            fieldIndex,
            symbolicValue ? ExpressionResult.null_ : value,
        );

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
            writeScalar(writtenType, cell.field(fieldIndex), value);
        } else if (writtenStruct) {
            auto writtenCell = cell.structField(fieldIndex);
            writeStructCellScalarFields(writtenCell, value);
        } else {
            auto writtenElementType = writtenType.toBasetype.nextOf.toBasetype;
            auto writtenArrayCell = cell.arrayField(fieldIndex);
            foreach (elementIndex; 0 .. AggregateValue.length(value))
                writeScalar(writtenElementType, writtenArrayCell.element(elementIndex),
                    AggregateValue.elementAt(value, elementIndex));
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
                if (!AggregateValue.isArray(siblingCurrent))
                    continue;

                auto siblingArrayCell = cell.arrayField(siblingIndex);
                foreach (elementIndex; 0 .. AggregateValue.length(siblingCurrent))
                    siblingCurrent = AggregateValue.withArrayElement(siblingCurrent, elementIndex,
                        readScalar(siblingElementType, siblingArrayCell.element(elementIndex)));
                updated = AggregateValue.withStructField(updated, siblingIndex, siblingCurrent);
                continue;
            }

            auto siblingStructType = sibling.type.toBasetype.isTypeStruct;
            if (siblingStructType is null || siblingStructType.sym.isUnionDeclaration !is null)
                continue;

            auto siblingCurrent = AggregateValue.fieldAt(updated, siblingIndex);
            if (!AggregateValue.isStruct(siblingCurrent))
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
            // unsupported. Checked via the STATIC receiver type, matching
            // `writeLocation`'s own class-field dispatch.
            if (receiverClassType(dot.e1) !is null) {
                const receiver = runExpression(dot.e1);
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
                        bodyType = AggregateValue.native(*metadata).type;
                    }
                    auto fieldPlace = Place(bodyAddress, bodyType)
                        .field(dot.var.isVarDeclaration);
                    const source = readStoredValue(fieldPlace);
                    if (index.lengthVar !is null)
                        setLocal(index.lengthVar, ExpressionResult(AggregateValue.length(source)));
                    const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
                    const value = runExpression(rhs);
                    writeStoredValue(fieldPlace.index(arrayIndex), value);
                    return value;
                }
                throw new Exception("Class field assignment needs a native address.");
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
                setLocal(index.lengthVar, ExpressionResult(AggregateValue.length(source)));
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


        const current = readBindingValue(variable);

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
        if (isStaticArrayType(index.e1.type))
            checkStaticArrayIndexInBounds(current, arrayIndex);

        // A fresh closure RHS (`dgs[0] = () => 1;`) is a bare `FuncExp`;
        // construct its callable before writing the destination.
        auto literal = rhs.isFuncExp;
        const value = literal is null
            ? runExpression(rhs)
            : runFunctionLiteralDeclaration(literal);

        // A live delegate element has no native ABI function address --
        // `place_value.writeValue`'s Tdelegate arm only ever accepts
        // `ExpressionResult.null_` -- so substitute null bytes for the write and
        // register the live value out-of-band in `nativeDelegateSlots`,
        // keyed by the element's own address, mirroring the append and
        // struct/class-field write sites.
        import dmd.astenums: TY;

        auto elementType = index.e1.type.toBasetype.nextOf;
        const isLiveDelegate = elementType !is null
            && elementType.toBasetype.ty == TY.Tdelegate
            && value != ExpressionResult.null_;
        const storedValue = isLiveDelegate ? ExpressionResult.null_ : value;
        auto destination = bindingPlace(variable).index(arrayIndex);
        writeStoredValue(destination, storageValue(elementType, storedValue));
        if (isLiveDelegate)
            nativeDelegateSlots[destination.address] = value;
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

        const length = AggregateValue.length(array);
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

        import quickbite.backends.interpreter.native_scalar: writeScalar;

        writeScalar(cell.elementType, cell.element(index), value);
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

    private ExpressionResult arrayValueFromCell(
        imported!"dmd.mtype".Type type,
        ref NativeArray cell,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        if (type.toBasetype.isTypeDArray !is null)
            return AggregateValue.reconstructNativeArrayWithLength(
                type,
                cell.length,
                cell.block.address,
            );
        return AggregateValue.copyFromAddress(type, cell.block.address);
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
        // local exposes either its object-body pointer or its owning native
        // aggregate. Resolve the field's `Place` through that address, the same
        // `nativeClassReceiver`/`fieldPlace` composition
        // `runIndexAssignExpression`'s singly-indexed `DotVarExp`/class arm
        // already uses, and write the whole updated field back through that
        // same `Place` -- a class body's storage is its own host address, so
        // there is no separate receiver lvalue to rebind the way a struct's
        // local binding needs.
        if (auto dot = outer.e1.isDotVarExp) {
            if (receiverClassType(dot.e1) !is null) {
                import quickbite.backends.interpreter.place: Place;
                import quickbite.backends.interpreter.place_value: readValue, writeValue;

                const receiver = runExpression(dot.e1);
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

        const current = readBindingValue(variable);

        const outerIndex = cast(size_t) runExpression(outer.e2).asLong;
        if (isStaticArrayType(outer.e1.type))
            checkStaticArrayIndexInBounds(current, outerIndex);
        const outerElement = AggregateValue.elementAt(current, outerIndex);
        const innerIndex = cast(size_t) runExpression(inner.e2).asLong;
        if (isStaticArrayType(inner.e1.type))
            checkStaticArrayIndexInBounds(outerElement, innerIndex);
        const value = runExpression(rhs);
        auto destination = bindingPlace(variable)
            .index(outerIndex)
            .index(innerIndex);
        writeStoredValue(destination, storageValue(inner.type, value));
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return value;
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
            setLocal(variable, defaultLocalValue(variable));
            clearUninitializedBindingAddress(bindingPlace(variable).address);
        }
        const current = readBindingValue(variable);

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? AggregateValue.length(current)
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
        if (upper > AggregateValue.length(current))
            throwRangeError(text(
                "slice [", lower, " .. ", upper,
                "] extends past source array of length ", AggregateValue.length(current),
            ));

        rejectOverlappingSliceAssignment(
            variable,
            rhs,
            lower,
            upper,
            AggregateValue.length(current),
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
        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(current))
            elements ~= index < lower || index >= upper
                ? AggregateValue.elementAt(current, index)
                : block ? copyArrayValue(value, variable.type.toBasetype.nextOf)
                : AggregateValue.isArray(value)
                    ? AggregateValue.elementAt(value, index - lower)
                    : value;

        auto destination = bindingPlace(variable);
        foreach (index; lower .. upper)
            writeStoredArrayElement(destination.index(index), elements[index]);
        clearUninitializedBindingAddress(destination.address);

        return value;
    }

    // Writing one element of an array whose element type is `void`: the
    // element is a byte of raw storage, because `void` names no value the
    // place codec could store. Assigning between `void[]` slices is a byte
    // copy in D -- their bounds and assignment length are measured in bytes
    // -- so retyping the destination place to `ubyte` stores exactly the byte
    // `AggregateValue.elementAt` read from the source.
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
    private ExpressionResult runPointerSliceAssignExpression(
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

        ExpressionResult elementAt(in size_t index) {
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
        import std.conv: text;

        const current = fieldSliceStorage(dot);

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

        foreach (index; lower .. upper) {
            const element = block
                ? copyArrayValue(value, slice.type.toBasetype.nextOf)
                : AggregateValue.elementAt(value, index - lower);
            AggregateValue.withArrayElement(current, index, element);
        }
        return value;
    }

    // The array storage a struct field's own slice assignment must land in,
    // as an aggregate its caller can index through. D gives an array field
    // two different storage shapes, and a value read out of the field is a
    // faithful handle on that storage for only one of them:
    //
    // - A dynamic-array field's own bytes are a `{ length, ptr }` header,
    //   and its elements live wherever `ptr` points. Reading the field
    //   copies those header bytes (`place_value.readValue`'s
    //   `AggregateValue.copyFromAddress`), and the copy still holds the
    //   field's real data pointer, so indexing through it -- which
    //   dereferences that pointer -- reaches the field's own elements.
    //
    // - A static-array field's own bytes ARE its elements. The same read
    //   therefore yields a detached copy of the data, and every write
    //   through it is discarded with that copy. Its storage has to be
    //   composed from the receiver's own address instead, which is what the
    //   arm below does; only that address names the bytes the struct holds.
    private ExpressionResult fieldSliceStorage(
        imported!"dmd.expression".DotVarExp dot,
    ) {
        import quickbite.backends.interpreter.layout: declaredType, typeByteSize;
        import quickbite.backends.interpreter.native_aggregate: NativeAggregate;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.frontend.dmd.types: isStaticArrayType;
        import dmd.tokens: EXP;
        import std.conv: text;

        auto field = dot.var.isVarDeclaration;
        if (field is null || !isStaticArrayType(declaredType(field)))
            return AggregateValue.fieldAt(runExpression(dot.e1), structFieldIndex(dot));

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

        // `NativeBlock.borrow`'s precondition is that the bytes stay live
        // for as long as any handle derived from the block can reach them.
        // They are the receiver's own field bytes, and the receiver is an
        // lvalue that outlives this assignment -- a frame slot, a dataseg
        // block, or a class body reached through a live reference -- so
        // nothing here can outlive them. Borrowing rather than copying is
        // the whole point: the assignment must land in those exact bytes.
        auto fieldType = declaredType(field);
        return ExpressionResult.nativeAggregateValue(NativeAggregate(
            fieldType,
            NativeBlock.borrow(
                receiverPlace.field(field).address,
                typeByteSize(fieldType),
            ),
        ));
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
        const current = runExpression(slice.e1);

        const lower = slice.lwr is null
            ? 0
            : cast(size_t) runExpression(slice.lwr).asLong;
        const upper = slice.upr is null
            ? AggregateValue.length(current)
            : cast(size_t) runExpression(slice.upr).asLong;

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);

        foreach (index; lower .. upper) {
            const element = block
                ? copyArrayValue(value, slice.type.toBasetype.nextOf)
                : AggregateValue.elementAt(value, index - lower);
            AggregateValue.withArrayElement(current, index, element);
        }
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

        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.length(value))
            elements ~= AggregateValue.elementAt(value, index);

        return reconstructStoredArray(AggregateValue.native(value).type, elements);
    }

    private ExpressionResult runLoweredAssignExpression(
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

        const current = readBindingValue(variable);

        const newLength = cast(size_t) lengthValue.asLong;

        ExpressionResult[] elements;
        foreach (index; 0 .. newLength)
            elements ~= index < AggregateValue.length(current)
                ? AggregateValue.elementAt(current, index)
                : runDefaultValue(arrayElementType(variable.type));

        // DMD lowers postfix `.length++`/`.length--` through a synthetic
        // `ref` local, so resize via that binding's native place.
        writeLocation(var, reconstructStoredArray(variable.type, elements));
        return lengthValue;
    }

    private ExpressionResult runConcatenateExpression(imported!"dmd.expression".CatExp cat) {
        return reconstructStoredArray(
            cat.type,
            concatenationElements(cat.type, cat.e1) ~
                concatenationElements(cat.type, cat.e2),
        );
    }

    private ExpressionResult[] concatenationElements(
        imported!"dmd.mtype".Type resultType,
        imported!"dmd.expression".Expression operand,
    ) {
        import quickbite.frontend.dmd.types: isArrayType;

        const value = runExpression(operand);
        if (!isArrayType(operand.type))
            return nativeAppendElements(resultType, value);

        ExpressionResult[] elements;
        foreach (index; 0 .. AggregateValue.elementCount(value))
            elements ~= AggregateValue.elementAt(value, index);

        return elements;
    }

    private ExpressionResult runArrayAppendAssignExpression(
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

        const current = readBindingValue(variable);

        auto literal = assign.e2.isFuncExp;
        const value = literal is null
            ? runExpression(assign.e2)
            : runFunctionLiteralDeclaration(literal);
        {
            import dmd.astenums: TY;

            // Begin each append from the binding's current native slice
            // header so captured slices observe prior iterations.
            ExpressionResult[] noElements;
            auto appended = current == ExpressionResult.null_
                ? reconstructStoredArray(variable.type, noElements)
                : runExpression(assign.e1);
            auto elementType = variable.type.toBasetype.isTypeDArray !is null
                ? variable.type.toBasetype.isTypeDArray.next
                : null;
            foreach (rawElement; nativeAppendElements(variable.type, value)) {
                const index = AggregateValue.elementCount(appended);
                const previous = appended;
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
    // (`previous`) and after (`appended`) this iteration's append, and if
    // it moved, relocate every one of `previous`'s `count` elements from
    // its old per-element address to its corresponding new one --
    // `copyStoredMetadata` carries every symbolic entry in each element's
    // byte range, including entries in nested structs and static arrays. The
    // old registrations remain because another live slice may still alias
    // the old allocation.
    private void relocatePriorAppendedElementSlots(
        imported!"dmd.mtype".Type elementType,
        in ExpressionResult previous,
        in ExpressionResult appended,
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

        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
        const appended = AggregateValue.withAppendedArrayElement(
            AggregateValue.elementAt(current, arrayIndex), runExpression(rhs));
        writeStoredValue(bindingPlace(variable).index(arrayIndex), appended);
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return appended;
    }

    private ExpressionResult castValue(imported!"dmd.expression".CastExp cast_) {
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

                const source = runExpression(cast_.e1);
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
        out ExpressionResult result,
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
        result = AggregateValue.reconstructNativeArrayWithLength(
            cast_.to,
            AggregateValue.length(source),
            AggregateValue.nativeArrayAddress(source),
        );
        return true;
    }

    private ExpressionResult boolCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.runtime_casts:
            backendCastTarget = castTarget,
            backendCastValue = castValue;

        const value = runExpression(cast_.e1);
        if (value.isPointer)
            return ExpressionResult(true);
        if (value == ExpressionResult.null_)
            return ExpressionResult(false);
        if (value.isNativeAggregate && AggregateValue.isArray(value))
            return ExpressionResult(isTruthy(value));

        return backendCastValue(value, backendCastTarget(cast_.to));
    }

    private ExpressionResult delegateCastValue(imported!"dmd.expression".CastExp cast_) {
        import std.conv: text;

        const value = runExpression(cast_.e1);
        if (value == ExpressionResult.null_ || value.isFunctionPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    private ExpressionResult classCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.frontend.dmd.types: isPointerType;

        auto value = runExpression(cast_.e1);
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
            // Compiled code recovers the dynamic class from the vptr the
            // storage already holds; the interpreter keeps that identity
            // beside the address instead, so this cast is where it has to be
            // recorded -- otherwise the resulting reference has no dynamic
            // type and every later interface cast or virtual call off it
            // fails. An address can be reused by a later, unrelated
            // allocation once the object that lived there is freed, so a
            // prior registration is only trustworthy when it is at least as
            // precise as what this cast asserts: overwrite it unless the
            // registered class already descends from (or is) the one named
            // here, which is the case for a real object being reinterpreted
            // through a less specific pointer type.
            if (auto address = classIdentityAddress(value)) {
                auto registered = address in nativeClassTypes;
                auto registeredClass = registered is null
                    ? null
                    : registered.toBasetype.isTypeClass;
                if (
                    registeredClass is null ||
                    !classDescendsFromOrIs(registeredClass.sym, classType.sym)
                )
                    nativeClassTypes[address] = classType;
            }
            return value;
        }

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

        auto value = runExpression(cast_.e1);
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
                        ? ExpressionResult.null_
                        : ExpressionResult.pointerValue(cast(void*) address);
                }
            }
            return arrayPointer(cast_.e1, 0, cast_.op);
        }

        const value = runExpression(cast_.e1);
        if (value == ExpressionResult.null_)
            return value;
        if (value.isPointer)
            return value;

        throw new Exception(text("Unsupported eval expression: ", cast_.op));
    }

    // An array-literal element typed `delegate` (`[() => 42]`) may carry a
    // LIVE callable value rather than `null`. `AggregateValue.
    // reconstructArray`'s `writeValue` call only ever accepts `ExpressionResult.null_`
    // for a Tdelegate element, so every live entry is substituted with
    // `ExpressionResult.null_` for the reconstruction and then re-registered in
    // `nativeDelegateSlots`, keyed by the RESULT array's own element
    // address -- mirroring `structLiteralValue`'s identical
    // substitute-then-register handling.
    private ExpressionResult arrayValue(
        imported!"dmd.expression".ArrayLiteralExp array,
    ) {
        import dmd.astenums: TY;

        auto elementType = array.type.toBasetype.nextOf;
        const isDelegateArray = elementType !is null
            && elementType.toBasetype.ty == TY.Tdelegate;

        ExpressionResult[] values;
        size_t[] liveDelegateIndices;
        ExpressionResult[] liveDelegateValues;
        if (array.elements !is null)
            // DMD's sparse form: a null element means the value is in `basis`
            // (see ArrayLiteralExp.getElement).
            foreach (index, element; *array.elements) {
                auto source = element is null ? array.basis : element;
                auto literal = source.isFuncExp;
                auto value = literal is null
                    ? runExpression(source)
                    : runFunctionLiteralDeclaration(literal);
                if (isDelegateArray && value != ExpressionResult.null_) {
                    liveDelegateIndices ~= index;
                    liveDelegateValues ~= value;
                    value = ExpressionResult.null_;
                }
                values ~= value;
            }

        auto result = reconstructStoredArray(array.type, values);
        foreach (position, index; liveDelegateIndices)
            nativeDelegateSlots[AggregateValue.elementAddress(result, index)] =
                liveDelegateValues[position];
        return result;
    }

    private ExpressionResult reconstructStoredArray(
        imported!"dmd.mtype".Type type,
        in ExpressionResult[] elements,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.place: Place;

        if (!canContainStoredMetadata(type))
            return AggregateValue.reconstructArray(type, elements);

        ExpressionResult[] nativeElements;
        nativeElements.reserve(elements.length);
        foreach (element; elements)
            nativeElements ~= element.isTypeName ? ExpressionResult.null_ : element;

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
    // `ExpressionResult.null_` -- by design, an interpreted delegate has no native ABI
    // function address, so its callable ExpressionResult lives out-of-band in
    // `nativeDelegateSlots`, keyed by the FIELD's own address, exactly as
    // the direct field-assignment path (`s.f = &add;`, this module's
    // `DotVarExp` write arm) and a delegate-typed local's own declaration
    // (`setLocal`'s `TY.Tdelegate` branch) already register it. A struct
    // literal has no field address of its own until
    // `AggregateValue.reconstructStruct` allocates its native storage, so
    // this substitutes `ExpressionResult.null_` for any live delegate field before
    // that call -- the same bytes the ordinary default-null case already
    // writes -- and registers the live value at the field's own address
    // once that address exists. `writeStoredValue` carries the registration
    // forward again when this rvalue is copied into durable storage.
    private ExpressionResult structLiteralValue(
        imported!"dmd.expression".StructLiteralExp literal,
    ) {
        import dmd.astenums: TY;
        import quickbite.backends.interpreter.place: Place;

        ExpressionResult[] fields;
        imported!"dmd.declaration".VarDeclaration[] liveDelegateFields;
        ExpressionResult[] liveDelegateValues;
        imported!"dmd.declaration".VarDeclaration[] symbolicTypeInfoFields;
        ExpressionResult[] symbolicTypeInfoValues;
        if (literal.sd !is null)
            foreach (index; 0 .. literal.sd.fields.length) {
                const hasElement = literal.elements !is null
                    && index < (*literal.elements).length;
                auto element = hasElement ? (*literal.elements)[index] : null;
                // A fresh closure element (`() => 42`) is a bare `FuncExp`,
                // not a `DelegateExp`; construct the callable before
                // registering it in the field's metadata slot.
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
                    value != ExpressionResult.null_
                ) {
                    liveDelegateFields ~= field;
                    liveDelegateValues ~= value;
                    value = ExpressionResult.null_;
                }
                if (
                    field !is null &&
                    field.type.toBasetype.isTypeClass !is null &&
                    value.isTypeName
                ) {
                    symbolicTypeInfoFields ~= field;
                    symbolicTypeInfoValues ~= value;
                    value = ExpressionResult.null_;
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

        bindNestedContextFrames(literal.sd, result);

        return result;
    }

    // A struct declared inside a function gets a hidden context field
    // (DMD's `AggregateDeclaration.vthis`) naming the enclosing activation.
    // Record the activations live right now against that field's own address,
    // so a method call on this instance can still reach them after the
    // enclosing function has returned. Nearest activation first, matching
    // `_enclosingFrames`' own order.
    private void bindNestedContextFrames(
        imported!"dmd.dstruct".StructDeclaration declaration,
        in ExpressionResult value,
    ) {
        import quickbite.backends.interpreter.place: Place;

        if (declaration is null || declaration.vthis is null)
            return;

        if (!value.isNativeAggregate)
            return;

        auto native = AggregateValue.native(value);
        auto address = Place(native.address, native.type)
            .field(declaration.vthis)
            .address;
        nestedContextFrames[address] = [_activationFrame] ~ _enclosingFrames;
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
    private ExpressionResult structLiteralDefaultFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
        in ExpressionResult[] fieldsSoFar,
    ) {
        auto field = structLiteralField(literal, index);
        if (field is null)
            return ExpressionResult.void_;

        ExpressionResult reinterpreted;
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
    // back out. A nested union's typed field views already agree on those bytes
    // through this same default reconstruction. A union sibling uses that
    // same reader: each supported field is independently reconstructed from
    // the one overlapping block.
    private bool unionSiblingDefaultFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
        imported!"dmd.declaration".VarDeclaration field,
        in ExpressionResult[] fieldsSoFar,
        out ExpressionResult value,
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
            value = arrayValueFromCell(field.type, siblingCell);
        }
        return true;
    }

    // Struct-leaf counterpart of `writeStaticArrayCellScalarElements`:
    // nested arrays compose `NativeArray` views until the existing
    // `NativeStruct` field writer can seed each plain-struct leaf.
    private void writeStaticArrayCellStructElements(
        ref NativeArray cell,
        in ExpressionResult arrayValue,
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

    private ExpressionResult structLiteralFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
        in ExpressionResult value,
    ) {
        import quickbite.frontend.dmd.types: isAssocArrayType;
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;
        import quickbite.backends.interpreter.layout: staticArrayLength;

        auto field = structLiteralField(literal, index);
        if (field is null)
            return value;

        if (value == ExpressionResult.null_ && isAssocArrayType(field.type))
        {
            import quickbite.backends.interpreter.native_assoc_array: allocateValue;

            return ExpressionResult.nativeAggregateValue(allocateValue(field.type));
        }

        auto staticArray = field.type is null ? null : field.type.toBasetype.isTypeSArray;
        if (staticArray is null || AggregateValue.isArray(value))
            return value;

        const length = staticArrayLength(staticArray);
        ExpressionResult[] elements;
        foreach (_; 0 .. length)
            elements ~= value;

        return reconstructStoredArray(field.type, elements);
    }

    // duplicate keys keep the last value, as in compiled D
    private ExpressionResult assocArrayValue(
        imported!"dmd.expression".AssocArrayLiteralExp assocArray,
    ) {
        import quickbite.backends.interpreter.aggregate_value: AggregateValue;

        ExpressionResult[] keys;
        ExpressionResult[] values;
        foreach (index; 0 .. assocArray.keys.length) {
            keys ~= runExpression((*assocArray.keys)[index]);
            values ~= runExpression((*assocArray.values)[index]);
        }
        return AggregateValue.reconstructAssocArray(assocArray.type, keys, values);
    }

    private ExpressionResult runSliceExpression(imported!"dmd.expression".SliceExp slice) {
        size_t lower;
        return runSliceExpression(slice, lower);
    }

    private ExpressionResult runSliceExpression(
        imported!"dmd.expression".SliceExp slice,
        out size_t lower,
    ) {
        const source = runExpression(slice.e1);
        if (slice.lengthVar !is null)
            setLocal(slice.lengthVar, ExpressionResult(AggregateValue.length(source)));
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
                if (
                    variable.type.toBasetype.isTypeSArray !is null &&
                    hasBindingPlace(variable)
                )
                    nativeAddress = cast(const(ubyte)*) bindingAddress(variable);
        if (auto dot = slice.e1.isDotVarExp)
            if (auto receiver = dot.e1.isVarExp)
                if (auto variable = receiver.var.isVarDeclaration)
                    if (auto field = dot.var.isVarDeclaration) {
                        auto place = bindingPlace(variable);
                        if (place.type.toBasetype.isTypeClass !is null)
                            place = place.deref;
                        place = place.field(field);
                        nativeAddress = place.type.toBasetype.isTypeDArray !is null
                            ? cast(const(ubyte)*) place.sliceDataPointer
                            : cast(const(ubyte)*) place.address;
                    }
        if (nativeAddress is null)
            if (auto var = slice.e1.isVarExp)
                if (auto variable = var.var.isVarDeclaration) {
                    if (
                        variable.type.toBasetype.isTypeSArray !is null &&
                        hasBindingPlace(variable)
                    )
                        nativeAddress = cast(const(ubyte)*) bindingAddress(variable);
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
        if (
            nativeAddress !is null &&
            slice.e1.type.toBasetype.isTypeSArray !is null
        )
            return AggregateValue.reconstructNativeArrayWithLength(
                slice.type,
                upper - lower,
                nativeAddress,
            );
        if (!source.isNativeAggregate)
            throw new Exception("Array slice needs native aggregate storage.");
        return AggregateValue.slice(source, slice.type, lower, upper);
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
        in ExpressionResult pointer,
        in size_t index,
        in ExpressionResult value,
    ) {
        import dmd.astenums: TY;
        import dmd.mtype: Type;
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.place: Place;
        import quickbite.backends.interpreter.place_value: writeValue;

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
                : nativeReceiverOperand(receiverExpression, receiverAddress),
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
        in ExpressionResult[] arguments,
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

    private ExpressionResult runIndexExpression(
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
            import quickbite.backends.interpreter.place: Place;
            import quickbite.backends.interpreter.place_value: readValue;

            auto header = nativeAssocArray(aa);
            auto keySlot = nativeAssocKeySlot(header, key);
            auto address = header.valueAddress(keySlot.address);
            if (address is null)
                throw new Exception("Associative-array key is absent.");
            return readValue(Place(address, header.valueType));
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

        const sourceLength = AggregateValue.length(source);
        if (index.lengthVar !is null)
            setLocal(index.lengthVar, ExpressionResult(sourceLength));

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
                            return *delegate_;

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
        const object = nativeExceptionBaseObject(
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

    private void writePointerTarget(
        imported!"dmd.expression".Expression expression,
        in ExpressionResult pointer,
        in ExpressionResult value,
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
            lengths ~= cast(size_t) runExpression(argument).asLong;

        return newArrayValue(new_.type, lengths);
    }

    private ExpressionResult runNewScalarPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        if (new_.member !is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        auto targetType = new_.type.toBasetype.nextOf;
        ExpressionResult value = defaultValue(targetType);
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
    private ExpressionResult runNewStructPointerExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto targetType = new_.type.toBasetype.nextOf;
        ExpressionResult structVal = defaultValue(targetType);

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
            ExpressionResult[] arguments;
            if (new_.arguments !is null)
                foreach (argument; *new_.arguments)
                    arguments ~= runExpression(argument);

            Walker child;
            child.runningCalledFunction = true;
            child.currentFunction = new_.member;
            auto layout = cachedFrameLayout(new_.member);
            child._activationFrame = FrameBlock.allocate(layout);
            child.result = ExpressionResult(false);
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
    // Its owner remains in the enclosing expression's lexical owner scope
    // until that address reaches scanned guest storage. Guest pointer identity
    // is exactly the allocation address.
    private ExpressionResult allocateNativePointer(
        imported!"dmd.mtype".Type targetType,
        in ExpressionResult value,
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
        retainTemporaryPointerOwner(block);
        return ExpressionResult.pointerValue(block.address);
    }

    // `runNewStructPointerExpression`'s own constructor-call merge, the heap
    // struct sibling of `mergeNewClassExpressionState`. A constructor can
    // allocate classes or capture host exception metadata before it throws,
    // so those address-keyed maps must survive the child walk.
    private void mergeNewStructConstructorState(ref Walker child) {
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
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

        ExpressionResult[] arguments;
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

    private ExpressionResult runNewClassExpression(
        imported!"dmd.expression".NewExp new_,
    ) {
        import std.conv: text;

        auto allocationType = new_.newtype is null ? new_.type : new_.newtype;
        auto classType = allocationType.toBasetype.isTypeClass;
        if (classType is null || classType.sym is null)
            throw new Exception(text("Unsupported eval expression: ", new_.op));

        ExpressionResult[] arguments;
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
        child.result = ExpressionResult(false);
        forkExecutionStateInto(child);
        child.thisValue = ExpressionResult.pointerValue(
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
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        nativeClassTypes = child.nativeClassTypes;
        nativeClassOwners = child.nativeClassOwners;
        nativeExceptionMetadata = child.nativeExceptionMetadata;
        nativeDelegateSlots = child.nativeDelegateSlots;
        nestedContextFrames = child.nestedContextFrames;
        nativeFunctionPointerSlots = child.nativeFunctionPointerSlots;
        nativeTypeInfoSlots = child.nativeTypeInfoSlots;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentFrames = child.lazyArgumentFrames;
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
                : defaultValue(elementType);

        return reconstructStoredArray(type, elements);
    }

    private ExpressionResult runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return ExpressionResult(false);

        if (isManifestVariable(variable)) {
            if (auto initializer = variable._init.isExpInitializer)
                return runExpression(initializer.exp);
            return defaultValue(variable);
        }

        if (_activationFrame.hasReferenceSlot(variable))
            _activationFrame.setReferenceSlot(variable, null);

        if (variable._init !is null && variable._init.isVoidInitializer !is null) {
            markUninitializedBinding(variable);
            return ExpressionResult.void_;
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
                return value;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                const value = defaultValue(variable);
                setLocal(variable, value);
                return value;
            }

            initializer = blit.e2;
        }

        if (initializer.isVoidInitExp !is null) {
            markUninitializedBinding(variable);
            return ExpressionResult.void_;
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
                if (AggregateValue.isStruct(result)) {
                    setLocal(variable, result);
                    return result;
                }
                return readBindingValue(variable);
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

                    const source = runExpression(sourceArray);
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

                    return readBindingValue(variable);
                }
            }

        if (isRefVariable(variable)) {
            import dmd.tokens: EXP;

            const pointer = addressOfExpression(initializer, EXP.address);
            if (!pointer.isPointer)
                throw new Exception("Reference initializer has no native place.");
            _activationFrame.setReferenceSlot(variable, pointer.pointerAddress);
            clearUninitializedBindingAddress(pointer.pointerAddress);
            return readBindingValue(variable);
        }

        import quickbite.frontend.dmd.types: isAssocArrayType, isDynamicArrayType;

        if (initializer.isNullExp !is null && isDynamicArrayType(variable.type)) {
            import quickbite.backends.interpreter.aggregate_value: AggregateValue;

            auto value = reconstructStoredArray(variable.type, []);
            setLocal(variable, value);
            return value;
        }

        if (initializer.isNullExp !is null && isAssocArrayType(variable.type)) {
            auto value = ExpressionResult.null_;
            setLocal(variable, value);
            return value;
        }

        if (auto slice = initializer.isSliceExp) {
            size_t lower;
            auto value = runSliceExpression(slice, lower);
            setLocal(variable, value);
            return value;
        }

        auto literal = initializer.isFuncExp;
        auto value = storageValue(
            variable.type,
            literal !is null
                ? runFunctionLiteralDeclaration(literal)
                : runExpression(initializer),
        );
        if (variable.type.toBasetype.isTypeClass !is null)
            value = rootedNativeClassValue(initializer, value);
        setLocal(variable, value);
        clearUninitializedBindingAddress(bindingPlace(variable).address);
        return value;
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

    private ExpressionResult defaultLocalValue(VarDeclaration variable) {
        return defaultValue(variable);
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
        return AggregateValue.length(value) != 0;
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
    import quickbite.backends.interpreter.runtime_values: defaultValue;

    auto structDecl = function_.parent is null
        ? null
        : function_.parent.isStructDeclaration;
    return structDecl !is null ? defaultValue(structDecl.type) : receiver;
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
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult object,
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
        walker.runExpression(field._init.initializerToExpression),
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


// The call site's actual argument types, in source order, so the FFI core can
// type a C variadic call's trailing arguments (the signature carries only the
// fixed parameters).
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
    foreach (current; classHierarchy(class_))
        if (function_.parent is current)
            return true;

    return false;
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

// Whether `class_` is `ancestor` or one of its subclasses, i.e. whether an
// instance of `class_` is-a `ancestor`.
private bool classDescendsFromOrIs(
    imported!"dmd.dclass".ClassDeclaration class_,
    imported!"dmd.dclass".ClassDeclaration ancestor,
) {
    foreach (current; classHierarchy(class_))
        if (current is ancestor)
            return true;

    return false;
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
    public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult contextPointer;
    public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult receiver;
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

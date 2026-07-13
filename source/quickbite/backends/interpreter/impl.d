module quickbite.backends.interpreter.impl;


private:


public class Interpreter: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayString;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

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
            walker.inUnitTest = function_.isUnitTestDeclaration !is null;
            walker.runStatement(function_.fbody);
            return EvalResult(displayString(walker.result, function_));
        } catch (Exception exception) {
            // The interpreter's own message, verbatim: rewriting it through
            // DMD's CTFE engine (as an earlier revision did) replaced the
            // real, actionable error with whichever body-less leaf CTFE
            // happened to reject (ai/plans/interpreter.md §5).
            return EvalResult(EvalResult.Diagnostic(exception.msg));
        }
    }
}

private bool isTransparentArrayCastTarget(imported!"dmd.mtype".Type type) {
    import quickbite.frontend.dmd.types: isArrayType;

    return isArrayType(type);
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
}

private class InterpretedException: Exception {
    public imported!"quickbite.lang".Value object;

    public this(in imported!"quickbite.lang".Value object) {
        const message = object.classFieldNamed("msg").asCharArrayString;
        super(message);
        this.object = object;
    }
}

private string statementLabel(imported!"dmd.identifier".Identifier identifier) {
    return identifier is null ? null : identifier.toString.idup;
}

private struct Walker {
    import dmd.declaration: VarDeclaration;
    import dmd.expression: DivExp, Expression, ModExp;
    import dmd.func: FuncDeclaration;
    import dmd.statement: Statement;
    import quickbite.backends.interpreter.native_block: NativeBlock;
    import quickbite.frontend.dmd.values: defaultValue;
    import quickbite.lang: Value;

    private Throwable[const(void)*] nativeThrowableRoots;

    private Value[VarDeclaration] locals;

    // Authoritative native bytes for an address-taken scalar local (value.md
    // item 7's guest-local slice): populated eagerly the moment `&local` is
    // taken (see `localPointerValue`), for `native_scalar.
    // isNativeScalarType` locals only. Non-address-taken locals, and every
    // aggregate/pointer local, still live only in `locals` above -- this
    // table is a narrow byte-level authority, not a replacement for it.
    // `locals[variable]` stays a synchronously-refreshed mirror of a cell's
    // bytes for as long as a cell exists, so alias/child-Walker paths that
    // only know about `locals` keep seeing the true value.
    private NativeBlock[VarDeclaration] scalarCells;

    private VarDeclaration[size_t] localPointers;
    private size_t[VarDeclaration] localPointerIds;
    private size_t nextLocalPointerId;
    private FuncDeclaration[size_t] functionPointers;
    private size_t[FuncDeclaration] functionPointerIds;
    private size_t nextFunctionPointerId;
    private RuntimeDelegate[size_t] delegates;
    private imported!"quickbite.backends.interpreter.ffi_marshal".
        InterpreterInboundTrampolineSession* durableInboundSession;
    private Expression[VarDeclaration] lazyArgumentExpressions;
    private Value[VarDeclaration][VarDeclaration] lazyArgumentLocals;
    private bool[VarDeclaration] uninitializedLocals;
    private SliceAlias[VarDeclaration] sliceAliases;
    private ArrayElementAlias[VarDeclaration] arrayElementAliases;
    private StructFieldAlias[VarDeclaration] structFieldAliases;
    private AssocArraySlotAlias[VarDeclaration] assocArraySlotAliases;
    private StructArrayFieldAliases[VarDeclaration] structArrayFieldAliases;
    private size_t[VarDeclaration] arrayAllocations;
    private size_t[VarDeclaration] arrayAllocationAliases;
    private VarDeclaration[size_t] arrayAllocationVariables;
    private bool[VarDeclaration] arrayPointerWritebacks;
    private size_t allocationCount;
    private size_t lastGCArrayUsedAllocation;
    private Value result;
    private bool runningCalledFunction;
    private bool inUnitTest;
    private FuncDeclaration currentFunction;
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

    private void bindCatchVariable(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (catch_.var is null)
            return;

        locals[catch_.var] = nativeExceptionCatchObject(catch_, object);
        uninitializedLocals.remove(catch_.var);
    }

    private void throwInterpretedException(
        imported!"dmd.expression".Expression expression,
    ) {
        auto object = runExpression(expression);
        if (!object.isClassObject)
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
            object = object.withClassFieldNamed(
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
                classDefaultValue(class_)
                    .withClassFieldNamed("msg", Value(message)),
                nativeObjectPointer,
            );

        // Fully-qualified name (e.g. a native throw's `classinfo.name`) may
        // not be lexically visible from the current call frame but still be
        // known to the frontend, since druntime/Phobos modules the source
        // imports are semantically analysed by dmd-as-a-library. Reusing
        // classDefaultValue/classTypeNames here (rather than the string
        // heuristic below) gives the real base-class chain: correct
        // Error-vs-Exception classification and intermediate bases, instead
        // of `nativeExceptionRoot`'s name-prefix guess (interpreter.md
        // §9.10).
        if (auto class_ = classDeclarationByQualifiedName(className))
            return withNativeExceptionObjectPointer(
                classDefaultValue(class_)
                    .withClassFieldNamed("msg", Value(message)),
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
        import quickbite.frontend.dmd.values: defaultValue;
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

        return withNativeExceptionObjectPointer(Value.classValue(
            className,
            nativeExceptionTypeNames(className),
            fieldNames,
            fields,
        ).withClassFieldNamed("msg", Value(message)), nativeObjectPointer);
    }

    private Value nativeExceptionCatchObject(
        imported!"dmd.statement".Catch catch_,
        in Value object,
    ) {
        if (!object.hasClassFieldNamed(nativeExceptionObjectPointerField))
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

        if (!object.hasClassFieldNamed(nativeExceptionObjectPointerField))
            return object;

        const pointer = object
            .classFieldNamed(nativeExceptionObjectPointerField)
            .asNativePointer;
        string[] fieldNames;
        Value[] fields;
        foreach (field; classFields(class_)) {
            const name = variableName(field);
            fieldNames ~= name;
            fields ~= isSyntheticNativeExceptionField(name) &&
                object.hasClassFieldNamed(name)
                ? object.classFieldNamed(name)
                : nativeClassFieldValue(field, pointer);
        }

        return withNativeExceptionObjectPointer(Value.classValue(
            object.classTypeName,
            object.classTypeNames,
            fieldNames,
            fields,
        ), pointer);
    }

    // Delete this with value.md's native-layout class/object work. It only
    // keeps the boxed native-exception shim from reading interpreter-owned
    // exception metadata as if it were native object storage.
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

        if (object.hasClassFieldNamed(nativeExceptionObjectPointerField))
            return object.withClassFieldNamed(
                nativeExceptionObjectPointerField,
                Value.nativePointerValue(cast(void*) nativeObjectPointer),
            );

        return object.withAppendedClassField(
            nativeExceptionObjectPointerField,
            Value.nativePointerValue(cast(void*) nativeObjectPointer),
        );
    }

    private Value chainExceptionObject(in Value thrown, in Value next) const {
        if (!thrown.isClassObject || !thrown.hasClassFieldNamed("_nextInChainPtr"))
            return thrown;

        return thrown.withClassFieldNamed("_nextInChainPtr", next);
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
        if (!object.isClassObject || arguments.length == 0)
            return object;

        auto result = object.withClassFieldNamed("msg", arguments[0]);
        if (
            arguments.length >= 4 &&
            arguments[3].isClassObject &&
            result.hasClassFieldNamed("_nextInChainPtr")
        )
            result = result.withClassFieldNamed("_nextInChainPtr", arguments[3]);

        return result;
    }

    private Value runThisConstructorCall(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions,
    ) {
        if (!hasThis)
            throw new Exception("Unsupported eval call.");

        if (thisValue.isClassObject && isThrowableConstructor(function_)) {
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
            locals[with_.wthis] = Value.pointerValue(structValue);
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
        import quickbite.frontend.dmd.values: integerValue, realValue;

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
                return Value.arrayValue([]);

            return Value.null_;
        }

        if (auto string_ = expression.isStringExp) {
            import quickbite.frontend.dmd.string_literals: stringValue;

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
            return Value(runExpression(arrayLength.e1).length);

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

            // Byte-level authority (value.md item 7): once `&variable` has
            // promoted a cell, its bytes -- not the boxed mirror below --
            // are the true value, so a reinterpret write through a pointer
            // (`writeLocation`'s `PtrExp` arm) is visible here.
            if (auto cell = variable in scalarCells) {
                import quickbite.backends.interpreter.native_scalar: readScalar;

                return readScalar(variable.type, cell.bytes);
            }

            if (auto current = variable in locals)
                return *current;

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
                    locals[variable] = defaultValue(variable);
                    const value = storageValue(
                        variable.type,
                        runExpression(initializer.exp),
                    );
                    locals[variable] = value;
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

        if (left.isPointer)
            return left.pointerOffsetBy(
                pointerElementOffset(add.type, right.asLong),
            );

        if (right.isPointer)
            return right.pointerOffsetBy(
                pointerElementOffset(add.type, left.asLong),
            );

        return left + right;
    }

    private Value runMinExpression(imported!"dmd.expression".MinExp sub) {
        const left = runExpression(sub.e1);
        const right = runExpression(sub.e2);

        // DMD lowers `p - q` to `(p - q) / elementSize`; return the byte
        // difference so the lowered division yields the element difference
        if (left.isPointer && right.isPointer)
            return Value(
                left.pointerOffsetDifference(right) *
                pointerElementSize(sub.e1.type),
            );

        if (left.isPointer)
            return left.pointerOffsetBy(
                -pointerElementOffset(sub.type, right.asLong),
            );

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
        if (call.arguments !is null)
            foreach (argument; *call.arguments) {
                arguments ~= runExpression(argument);
                argumentExpressions ~= argument;
            }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = call.f;
        child.addressOfRefReturn = true;
        child.result = Value(false);
        child.locals = call.f.isNested ? locals.dup : datasegLocals;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.sliceAliases = sliceAliases.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationAliases = arrayAllocationAliases.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.arrayPointerWritebacks = arrayPointerWritebacks.dup;
        child.allocationCount = allocationCount;
        seedPointerTargetLocals(child);
        child.bindFunctionParameters(call.f, arguments, argumentExpressions, locals);

        try {
            child.runStatement(call.f.fbody);
        } catch (InterpretedException exception) {
            writeBackFunctionState(call.f, argumentExpressions, child);
            throw exception;
        }
        writeBackFunctionState(call.f, argumentExpressions, child);

        return returnedLvalueAddress(call.f, argumentExpressions, child);
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
            if (array.isDotVarExp !is null) {
                const value = runExpression(array);
                return Value.arrayPointerValue(
                    arrayPointerElements(value),
                    ++allocationCount,
                    arrayPointerOffset(value, offset),
                );
            }

            throw new Exception(text("Unsupported eval expression: ", op));
        }

        auto variable = var.var.isVarDeclaration;
        if (variable is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        auto current = variable in locals;
        if (current is null)
            throw new Exception(text("Unsupported eval expression: ", op));

        auto source = variable;
        if (auto alias_ = variable in sliceAliases)
            source = alias_.source;

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

        if (isStaticArrayType(variable.type)) {
            // Taking the address of a still-void static array materialises
            // its storage (as aggregate reads do) so writes through the
            // pointer have somewhere to land.
            if (variable in uninitializedLocals && variable !in locals)
                locals[variable] = defaultValue(variable);

            if (auto current = variable in locals) {
                import quickbite.backends.interpreter.layout: typeByteSize;

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
        promoteScalarCell(variable);

        if (auto id = variable in localPointerIds)
            return Value.localPointerValue(*id);

        const id = ++nextLocalPointerId;
        localPointerIds[variable] = id;
        localPointers[id] = variable;
        return Value.localPointerValue(id);
    }

    // Eagerly gives an address-taken native-scalar local an authoritative
    // native-byte cell (value.md item 7's guest-local slice) the first time
    // its address is taken, seeded from whatever value the local currently
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
            return staticArrayPointerView(value, pointer.type);

        if (value.isNativePointer)
            return loadNativePointerElement(pointer.e1.type, value, 0);

        if (!value.isLocalPointer)
            return value.pointerTarget;

        auto variable = value.localPointerId in localPointers;
        if (variable is null)
            throw new Exception("Unsupported interpreter pointer target.");

        if (auto current = (*variable) in locals)
            return reinterpretLocalPointerLoad(
                *current,
                (*variable).type,
                pointer.e1.type,
            );

        return reinterpretLocalPointerLoad(
            defaultValue(*variable),
            (*variable).type,
            pointer.e1.type,
        );
    }

    // `*cast(T*) &local`: a load of the same bytes at a different static
    // type, not a hardcoded name/type-pair match (ai/plans/value.md item 7,
    // "Shim deletion path"). Only taken when both `source` and `target` are
    // `native_scalar.isNativeScalarType` AND `target` is no wider than
    // `source`: reading a wider target than the source local owns would
    // read bytes the local never had, which stays on the passthrough path
    // below untouched (a pre-existing gap, not this call site's to fix).
    // For every other pair -- an aggregate, a pointer, `real`, or a
    // widening read -- this returns `value` unchanged exactly as before.
    private Value reinterpretLocalPointerLoad(
        in Value value,
        imported!"dmd.mtype".Type sourceType,
        imported!"dmd.mtype".Type pointerType,
    ) {
        import quickbite.backends.interpreter.layout: typeByteSize;
        import quickbite.backends.interpreter.native_block: NativeBlock;
        import quickbite.backends.interpreter.native_scalar:
            isNativeScalarType, readScalar, writeScalar;

        auto source = sourceType is null ? null : sourceType.toBasetype;
        auto pointer = pointerType is null ? null : pointerType.toBasetype;
        auto target = pointer is null || pointer.nextOf is null
            ? null
            : pointer.nextOf.toBasetype;
        if (source is null || target is null)
            return value;

        if (!isNativeScalarType(source) || !isNativeScalarType(target))
            return value;

        const sourceSize = typeByteSize(source);
        const targetSize = typeByteSize(target);
        if (targetSize > sourceSize)
            return value;

        auto block = NativeBlock.allocate(sourceSize, NativeBlock.Scan.no);
        writeScalar(source, block.bytes, value);
        return readScalar(target, block.bytes[0 .. targetSize]);
    }

    private Value staticArrayPointerView(
        in Value pointer,
        imported!"dmd.mtype".Type staticArrayType,
    ) {
        import quickbite.backends.interpreter.layout: staticArrayLength;

        auto staticArray = staticArrayType.toBasetype.isTypeSArray;
        const length = staticArrayLength(staticArray);
        const target = pointerTargetValue(pointer);
        if (target.isArray)
            return target;

        Value[] elements;
        foreach (index; 0 .. length)
            elements ~= pointer.pointerIndex(index);

        return Value.arrayValue(elements);
    }

    private Value[] arrayElements(in Value value) {
        Value[] elements;
        foreach (index; 0 .. value.length)
            elements ~= value[index];

        return elements;
    }

    private Value[] arrayPointerElements(in Value value) {
        return value.isArray
            ? value.arrayAllocationElements
            : arrayElements(value);
    }

    private long arrayPointerOffset(in Value value, in long offset) {
        return value.isArray
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
            locals[*variable] = defaultValue(*variable);

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
        const same = left == right;
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

        if (call.f !is null && functionName(call.f) == "memcpy") {
            import quickbite.backends.interpreter.interception_guard:
                enforceInterceptionPolicy;

            enforceInterceptionPolicy(call.f, "memcpy");
            return runMemcpyCall(call);
        }

        if (call.f !is null && isEmplaceRef(call.f)) {
            import quickbite.backends.interpreter.interception_guard:
                enforceInterceptionPolicy;

            enforceInterceptionPolicy(call.f, "isEmplaceRef");
            return runEmplaceRefCall(call);
        }

        if (call.f !is null) {
            import quickbite.backends.interpreter.builtins:
                GCArrayHook, tryGCArrayHook;

            GCArrayHook gcArrayHook;
            if (tryGCArrayHook(call.f, gcArrayHook)) {
                import quickbite.backends.interpreter.interception_guard:
                    enforceInterceptionPolicy;

                enforceInterceptionPolicy(call.f, "tryGCArrayHook");
                return runGCArrayHookCall(call, gcArrayHook);
            }
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
        if (call.arguments !is null) {
            foreach (index, argument; *call.arguments) {
                auto parameter = call.f is null ||
                    call.f.parameters is null ||
                    index >= call.f.parameters.length
                    ? null
                    : (*call.f.parameters)[index];
                arguments ~= parameter !is null && parameterIsLazy(parameter)
                    ? Value.undisplayable
                    : runExpression(argument);
                argumentExpressions ~= argument;
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
                            arguments,
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
                );

            return runFunction(call.f, arguments, argumentExpressions);
        }

        if (auto var = call.e1.isVarExp)
            if (auto function_ = var.var.isFuncDeclaration)
                return runFunction(function_, arguments, argumentExpressions);

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
                );

            return runFunction(function_, arguments, argumentExpressions);
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
            return runDelegateCall(callee, arguments, argumentExpressions);

        if (callee.isFunctionPointer) {
            auto function_ = callee.functionPointerId in functionPointers;
            if (function_ is null)
                throw new Exception("Unsupported eval call.");
            return runFunction(*function_, arguments, argumentExpressions);
        }

        throw new Exception("Unsupported eval call.");
    }

    private Value runEmplaceRefCall(imported!"dmd.expression".CallExp call) {
        if (call.arguments is null || call.arguments.length != 2)
            throw new Exception("Unsupported eval call.");

        const value = runExpression((*call.arguments)[1]);
        writeLocation((*call.arguments)[0], value);
        return Value.void_;
    }

    private Value runMemcpyCall(imported!"dmd.expression".CallExp call) {
        import quickbite.backends.interpreter.layout: typeByteSize;

        if (call.arguments is null || call.arguments.length < 2)
            throw new Exception("Unsupported eval call.");

        auto destinationExpression = (*call.arguments)[0];
        auto sourceExpression = (*call.arguments)[1];
        const destination = runExpression(destinationExpression);
        const sourcePointer = runExpression(sourceExpression);
        auto sourcePointerType = memcpyElementPointerType(sourceExpression);
        const elementSize = typeByteSize(
            sourcePointerType.toBasetype.nextOf.toBasetype,
        );
        const count = call.arguments.length < 3
            ? sourcePointer.pointerLength
            : cast(size_t) runExpression((*call.arguments)[2]).asLong / elementSize;

        if (destination.isNativePointer) {
            foreach (index; 0 .. count) {
                const source = readPointerElement(
                    sourcePointerType,
                    sourcePointer,
                    index,
                );
                storeNativePointerElement(
                    sourcePointerType,
                    destination,
                    index,
                    source,
                );
            }
            return destination;
        }

        Value[] source;
        foreach (index; 0 .. count)
            source ~= readPointerElement(sourcePointerType, sourcePointer, index);

        if (source.length != 0 && source[0].isStruct) {
            writePointerElements(destinationExpression, destination, source);
            return destination;
        }

        return destination;
    }

    private Value runGCArrayHookCall(
        imported!"dmd.expression".CallExp call,
        in imported!"quickbite.backends.interpreter.builtins".GCArrayHook hook,
    ) {
        import quickbite.backends.interpreter.builtins: GCArrayHook;

        if (call.arguments is null)
            throw new Exception("Unsupported eval call.");

        with (GCArrayHook) final switch (hook) {
            case getUsed:
                requireArgumentCount(call, 2);
                return gcArrayUsed(runExpression((*call.arguments)[0]));

            case reserveCapacity:
                requireArgumentCount(call, 3);
                const slice = runExpression((*call.arguments)[0]);
                const request =
                    cast(size_t) runExpression((*call.arguments)[1]).asLong;
                runExpression((*call.arguments)[2]);
                return Value(request == 0 ? slice.length : request);

            case shrinkUsed:
                requireArgumentCount(call, 3);
                runExpression((*call.arguments)[0]);
                runExpression((*call.arguments)[1]);
                runExpression((*call.arguments)[2]);
                return Value(true);
        }
    }

    private Value gcArrayUsed(in Value pointer) {
        lastGCArrayUsedAllocation = 0;
        if (pointer == Value.null_ || pointer.isNativePointer)
            return Value.null_;

        if (!pointer.isPointer)
            throw new Exception("Expected pointer.");

        lastGCArrayUsedAllocation = pointer.pointerAllocation;
        return Value.arrayValue(pointerArrayElements(pointer));
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

    private imported!"dmd.mtype".Type memcpyElementPointerType(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.astenums: TY;

        auto type = expression.type;
        auto pointed = type.toBasetype.nextOf;
        if (pointed is null || pointed.toBasetype.ty != TY.Tvoid)
            return type;

        if (auto cast_ = expression.isCastExp)
            return memcpyElementPointerType(cast_.e1);

        return type;
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
            );

        return runFunction(runtime.function_, arguments, argumentExpressions);
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
        foreach (index; 0 .. source.length)
            encoded ~= cast(char) source[index].castTo!long.asLong;

        Value[] values;
        size_t index;
        while (index < encoded.length)
            values ~= Value(decode(encoded, index));

        return values;
    }

    private Value[] decodedUtf16Dchars(in Value source) {
        import std.utf: decode;

        wstring encoded;
        foreach (index; 0 .. source.length)
            encoded ~= cast(wchar) source[index].castTo!long.asLong;

        Value[] values;
        size_t index;
        while (index < encoded.length)
            values ~= Value(decode(encoded, index));

        return values;
    }

    private Value[] utf8EncodedDstringChars(in Value source) {
        import std.utf: encode;

        Value[] values;
        foreach (index; 0 .. source.length) {
            char[4] encoded;
            const length = encode(
                encoded,
                cast(dchar) source[index].castTo!long.asLong,
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
        if (!receiver.isClassObject)
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
        return dynamicClassDeclarationByName(value.classTypeName);
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

        locals[variable] = Value.arrayValue(updated);
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
                locals[foundVariable] = Value(contains);

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
        locals[variable] = current.withoutAssocArrayKey(key);
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
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.nativeThrowableRoots = nativeThrowableRoots.dup;
        child.locals = (captureLocals || function_.isNested)
            ? locals.dup
            : datasegLocals;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.sliceAliases = sliceAliases.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationAliases = arrayAllocationAliases.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.arrayPointerWritebacks = arrayPointerWritebacks.dup;
        child.allocationCount = allocationCount;
        seedPointerTargetLocals(child);
        child.bindFunctionParameters(function_, arguments, argumentExpressions, locals);

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackFunctionState(
                function_,
                argumentExpressions,
                child,
                captureLocals,
            );
            throw exception;
        }
        writeBackFunctionState(
            function_,
            argumentExpressions,
            child,
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
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.nativeThrowableRoots = nativeThrowableRoots.dup;
        child.locals = locals.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.sliceAliases = sliceAliases.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationAliases = arrayAllocationAliases.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.arrayPointerWritebacks = arrayPointerWritebacks.dup;
        child.allocationCount = allocationCount;
        if (receiverExpression !is null)
            if (auto var = receiverExpression.isVarExp)
                if (auto variable = var.var.isVarDeclaration)
                    if (auto aliases = variable in structArrayFieldAliases) {
                        child.thisStructArrayFieldAliases = *aliases;
                        foreach (_, sourceVariable; aliases.sources)
                            if (auto value = sourceVariable in locals)
                                child.locals[sourceVariable] = *value;
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
        child.bindFunctionParameters(function_, arguments, argumentExpressions, locals);

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackMemberFunctionState(
                function_,
                receiverExpression,
                argumentExpressions,
                child,
            );
            throw exception;
        }
        writeBackMemberFunctionState(
            function_,
            receiverExpression,
            argumentExpressions,
            child,
        );

        if (function_.isConstructorFunction)
            return child.thisValue;

        return child.result;
    }

    private void writeBackFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
        in bool captureLocals = false,
    ) {
        mergeNativeThrowableRoots(child);
        nextLocalPointerId = child.nextLocalPointerId;
        mergeReturnedLocalPointer(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        allocationCount = child.allocationCount;
        arrayAllocations = child.arrayAllocations;
        arrayAllocationAliases = child.arrayAllocationAliases;
        arrayAllocationVariables = child.arrayAllocationVariables;
        arrayPointerWritebacks = child.arrayPointerWritebacks;
        writeBackNestedLocals(function_, child, captureLocals);
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
        writeBackArrayPointerTargets(child);
        writeBackRefArguments(function_, argumentExpressions, child);
        writeBackByValueClassArguments(function_, argumentExpressions, child);
        writeBackByValueStructArguments(function_, argumentExpressions, child);
    }

    private void writeBackMemberFunctionState(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression receiverExpression,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        mergeNativeThrowableRoots(child);
        nextLocalPointerId = child.nextLocalPointerId;
        mergeReturnedLocalPointer(child);
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        allocationCount = child.allocationCount;
        arrayAllocations = child.arrayAllocations;
        arrayAllocationAliases = child.arrayAllocationAliases;
        arrayAllocationVariables = child.arrayAllocationVariables;
        arrayPointerWritebacks = child.arrayPointerWritebacks;
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
        writeBackArrayPointerTargets(child);
        writeBackRefArguments(function_, argumentExpressions, child);
        writeBackByValueClassArguments(function_, argumentExpressions, child);
        writeBackThisStructArrayFieldAliases(child);
        child.returned = false;
        writeBackThis(receiverExpression, child.thisValue);
    }

    private void mergeNativeThrowableRoots(ref Walker child) {
        foreach (pointer, throwable; child.nativeThrowableRoots)
            nativeThrowableRoots[pointer] = throwable;
    }

    private void writeBackNestedLocals(
        imported!"dmd.func".FuncDeclaration function_,
        ref Walker child,
        in bool captureLocals = false,
    ) {
        if (!captureLocals && !function_.isNested)
            return;

        foreach (variable, value; child.locals)
            if (variable in locals)
                locals[variable] = value;
    }

    private void writeBackGlobals(ref Walker child) {
        foreach (variable, value; child.locals) {
            if (variable.isDataseg)
                locals[variable] = value;
        }
    }

    private void writeBackLocalPointerTargets(ref Walker child) {
        foreach (_, variable; child.localPointers) {
            if ((variable in locals) is null)
                continue;

            if ((variable in arrayAllocations) !is null)
                continue;

            // A native-scalar target already carries a promoted `scalarCells`
            // entry (value.md item 7): `localPointerValue` promotes eagerly
            // and every frame shares the same `NativeBlock` bytes by
            // reference (`child.scalarCells = scalarCells.dup`), so the
            // child's writes are already visible here. Copying the boxed
            // `child.locals` mirror back would be dead code -- the `VarExp`
            // read arm ignores `locals` in favour of the cell once one
            // exists, so nothing ever reads the value this would restore.
            if (variable in scalarCells)
                continue;

            if (auto value = variable in child.locals)
                locals[variable] = *value;
        }
    }

    private void writeBackArrayPointerTargets(ref Walker child) {
        foreach (_, variable; child.arrayAllocationVariables) {
            if ((variable in locals) is null)
                continue;

            if (!isDynamicArrayVariable(variable) &&
                (variable in child.arrayPointerWritebacks) is null)
                continue;

            if (auto value = variable in child.locals)
                locals[variable] = *value;
        }
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
            child.locals[variable] = *value;
    }

    private bool isArrayVariable(VarDeclaration variable) {
        import quickbite.frontend.dmd.types: isArrayType;

        return isArrayType(variable.type);
    }

    private bool isDynamicArrayVariable(VarDeclaration variable) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        return isDynamicArrayType(variable.type);
    }

    private void runDestructor(
        imported!"dmd.func".FuncDeclaration function_,
        in Value receiver,
    ) {
        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.result = Value(false);
        child.locals = locals.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationAliases = arrayAllocationAliases.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.allocationCount = allocationCount;
        child.thisValue = receiver;
        child.hasThis = true;

        child.runStatement(function_.fbody);
        nextLocalPointerId = child.nextLocalPointerId;
        allocationCount = child.allocationCount;
        arrayAllocations = child.arrayAllocations;
        arrayAllocationAliases = child.arrayAllocationAliases;
        arrayAllocationVariables = child.arrayAllocationVariables;
        writeBackGlobals(child);
        writeBackLocalPointerTargets(child);
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
                locals[sourceVariable] = *value;
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
            expression.isThisExp !is null;
    }

    private bool isDynamicArrayPointerRefArgument(
        imported!"dmd.expression".Expression expression,
    ) {
        import quickbite.frontend.dmd.types: isDynamicArrayType;

        auto pointerExpression = expression.isPtrExp;
        if (pointerExpression is null)
            return false;

        const pointer = runExpression(pointerExpression.e1);
        if (
            !pointer.isPointer ||
            pointer.isLocalPointer ||
            pointer.isNativePointer ||
            pointer.pointerAllocation == 0
        )
            return false;

        auto variable = pointer.pointerAllocation in arrayAllocationVariables;
        return variable !is null && isDynamicArrayType((*variable).type);
    }

    private void bindFunctionParameters(
        imported!"dmd.func".FuncDeclaration function_,
        in Value[] arguments,
        imported!"dmd.expression".Expression[] argumentExpressions = null,
        Value[VarDeclaration] callerLocals = null,
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
                );
                continue;
            }

            locals[parameter] = arguments[index];
            recordParameterSliceAlias(
                parameter,
                arguments[index],
                index < argumentExpressions.length
                    ? argumentExpressions[index]
                    : null,
            );
        }
    }

    // A `lazy` parameter is a delegate over the *caller's live frame*, not a
    // value captured at call time (ai/plans/interpreter.md §9.10). `locals`
    // is a D associative array: a reference to a heap-allocated hash table.
    // Storing `callerLocals` here without `.dup` (and forwarding it without
    // `.dup` below, and substituting it without `.dup` in `runLazyArgument`)
    // makes the captured environment the *same* table the caller's `locals`
    // still points at, so any mutation performed while evaluating the lazy
    // expression (e.g. a forwarded range's cursor advancing) is visible to
    // the declaring frame immediately, exactly as it is for a real D
    // closure — no separate write-back step is needed.
    private void bindLazyFunctionParameter(
        VarDeclaration parameter,
        Expression argumentExpression,
        Value[VarDeclaration] callerLocals,
    ) {
        locals[parameter] = Value.undisplayable;

        if (auto variable = lazyExpressionVariable(argumentExpression)) {
            if (auto expression = variable in lazyArgumentExpressions) {
                lazyArgumentExpressions[parameter] = *expression;
                if (auto captured = variable in lazyArgumentLocals)
                    lazyArgumentLocals[parameter] = *captured;
                return;
            }
        }

        if (argumentExpression is null)
            throw new Exception("Unsupported interpreter call arguments.");

        lazyArgumentExpressions[parameter] = argumentExpression;
        lazyArgumentLocals[parameter] = callerLocals;
    }

    private Value runLazyArgument(VarDeclaration variable) {
        auto expression = variable in lazyArgumentExpressions;
        if (expression is null)
            throw new Exception("Unsupported eval call.");

        auto captured = variable in lazyArgumentLocals;
        if (captured is null)
            throw new Exception("Unsupported eval call.");

        auto savedLocals = locals;  // mutated below while evaluating the thunk
        scope(exit) locals = savedLocals;

        // No `.dup`: see the comment on `bindLazyFunctionParameter`. `locals`
        // becomes the caller's own live table for the duration of the thunk.
        locals = *captured;
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
            recordForwardedArrayAllocationAlias(parameter, argumentExpression);
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
        imported!"dmd.expression".Expression argumentExpression,
    ) {
        auto var = argumentExpression is null
            ? null
            : argumentExpression.isVarExp;
        if (var is null) {
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
                if (isDynamicArrayPointerRefArgument(argument)) {
                    writeLocation(argument, *value);
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

                writeLocation(argument, *value);
            }
        }
    }

    private void writeBackByValueClassArguments(
        imported!"dmd.func".FuncDeclaration function_,
        imported!"dmd.expression".Expression[] argumentExpressions,
        ref Walker child,
    ) {
        import dmd.astenums: TY;

        if (function_.parameters is null)
            return;

        foreach (index, parameter; *function_.parameters) {
            if (parameter.isReference)
                continue;

            if (
                parameter.type is null ||
                parameter.type.toBasetype.ty != TY.Tclass
            )
                continue;

            if (index >= argumentExpressions.length)
                continue;

            auto argument = argumentExpressions[index];
            if (argument is null || !isWritableLocation(argument))
                continue;

            auto finalParam = parameter in child.locals;
            if (finalParam is null || !finalParam.isClassObject)
                continue;

            const original = runExpression(argument);
            if (!original.isClassObject)
                continue;

            if (finalParam.classTypeName != original.classTypeName)
                continue;

            if (*finalParam != original)
                writeLocation(argument, *finalParam);
        }
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

        if (left.isArray && right.isArray)
            return equalArrayValues(left, right);

        return left == right;
    }

    private bool equalArrayValues(in Value left, in Value right) {
        if (left.length != right.length)
            return false;

        foreach (index; 0 .. left.length)
            if (!equalValues(left[index], right[index]))
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
        import quickbite.backends.casts:
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
        import quickbite.backends.casts:
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
        import quickbite.backends.casts:
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
            if (target.isClassObject)
                return target.classFieldAt(classFieldIndex(dot, target));
            return target.structFieldAt(structFieldIndex(dot));
        }

        throw new Exception("Unsupported interpreter field read.");
    }

    private Value runClassInfoExpression(
        imported!"dmd.expression".DotVarExp classInfo,
    ) {
        if (classInfo.e1.isTypeExp is null) {
            const receiver = runExpression(classInfo.e1);
            if (receiver.isClassObject)
                return Value.typeName(receiver.classTypeName);
        }

        return Value.typeName(typeInfoName(classInfo.e1.type));
    }

    private Value runClassInfoNameOwnerExpression(
        imported!"dmd.expression".Expression ownerExpression,
    ) {
        const receiver = runExpression(classInfoNameOwnerExpression(ownerExpression));
        if (receiver.isClassObject)
            return Value(receiver.classTypeName);

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

        if (value.isClassObject)
            return typeidValue(typeid_, value.classTypeName);

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

        const value = runExpression(assign.e2);
        writeLocation(assign.e1, value);
        return value;
    }

    private void writeLocation(
        imported!"dmd.expression".Expression target,
        in Value value,
    ) {
        if (auto cast_ = target.isCastExp) {
            writeLocation(cast_.e1, value);
            return;
        }

        if (auto var = target.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable is null)
                throw new Exception("Unsupported interpreter assignment target.");

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

            locals[variable] = storageValue(variable.type, value);

            // Byte-level authority (value.md item 7): once `&variable` has
            // promoted a cell, direct reads consult it (the `VarExp` arm of
            // `runExpression`) rather than the `locals` mirror below, so a
            // direct write must refresh the cell too, or a stale cell value
            // resurfaces on the next direct read even though `locals` (and
            // any pointer aliasing the cell) already moved on.
            if (auto cell = variable in scalarCells) {
                import quickbite.backends.interpreter.native_scalar: writeScalar;

                writeScalar(variable.type, cell.bytes, locals[variable]);
            }

            writeThroughArrayElementAlias(variable, locals[variable]);
            writeThroughStructFieldAlias(variable, locals[variable]);
            uninitializedLocals.remove(variable);
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
                    ? targetValue.withClassField(classFieldIndex(dot, targetValue), value)
                    : targetValue.withStructField(structFieldIndex(dot), value));
                return;
            }

            writeLocation(dot.e1, receiver.isClassObject
                ? receiver.withClassField(classFieldIndex(dot, receiver), value)
                : receiver.withStructField(structFieldIndex(dot), value));
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

                // Byte-level reinterpret write (value.md item 7): a
                // promoted cell exists, so write `value`'s bits in as the
                // pointer's pointee type, then refresh the `locals` mirror
                // by reading the local's own type back out. Without this,
                // `*p = x` through a differently-typed pointer stored the
                // boxed value verbatim -- a real bug vs SystemLinker.
                if (auto cell = *variable in scalarCells) {
                    import quickbite.backends.interpreter.native_scalar:
                        readScalar, writeScalar;

                    auto pointeeType = ptr.e1.type.toBasetype.nextOf.toBasetype;
                    writeScalar(pointeeType, cell.bytes, value);
                    locals[*variable] = readScalar((*variable).type, cell.bytes);
                    uninitializedLocals.remove(*variable);
                    return;
                }

                locals[*variable] = value;
                uninitializedLocals.remove(*variable);
                return;
            }

            // A dereferenced native pointer (e.g. a malloc'd struct like
            // std.stdio.File's Impl): write straight into native memory.
            if (pointer.isNativePointer) {
                storeNativePointerElement(ptr.e1.type, pointer, 0, value);
                return;
            }

            if (writeThroughArrayPointer(pointer, value))
                return;

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
        if (call.arguments !is null)
            foreach (argument; *call.arguments) {
                arguments ~= runExpression(argument);
                argumentExpressions ~= argument;
            }

        Walker child;
        child.runningCalledFunction = true;
        child.currentFunction = function_;
        child.assignToRefReturn = true;
        child.refReturnAssignedValue = value;
        child.result = Value(false);
        child.locals = locals.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.sliceAliases = sliceAliases.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationAliases = arrayAllocationAliases.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.arrayPointerWritebacks = arrayPointerWritebacks.dup;
        child.allocationCount = allocationCount;
        child.thisValue = receiver;
        child.hasThis = true;
        child.bindFunctionParameters(function_, arguments, argumentExpressions, locals);

        try {
            child.runStatement(function_.fbody);
        } catch (InterpretedException exception) {
            writeBackMemberFunctionState(
                function_,
                dot.e1,
                argumentExpressions,
                child,
            );
            throw exception;
        }
        writeBackMemberFunctionState(
            function_,
            dot.e1,
            argumentExpressions,
            child,
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
        if (call.arguments !is null)
            foreach (argument; *call.arguments) {
                arguments ~= runExpression(argument);
                argumentExpressions ~= argument;
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
        child.assignToRefReturn = true;
        child.refReturnAssignedValue = value;
        child.result = Value(false);
        child.locals = call.f.isNested ? locals.dup : datasegLocals;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.sliceAliases = sliceAliases.dup;
        child.arrayAllocations = arrayAllocations.dup;
        child.arrayAllocationAliases = arrayAllocationAliases.dup;
        child.arrayAllocationVariables = arrayAllocationVariables.dup;
        child.arrayPointerWritebacks = arrayPointerWritebacks.dup;
        child.allocationCount = allocationCount;
        seedPointerTargetLocals(child);
        child.bindFunctionParameters(call.f, arguments, argumentExpressions, locals);

        try {
            child.runStatement(call.f.fbody);
        } catch (InterpretedException exception) {
            writeBackFunctionState(call.f, argumentExpressions, child);
            throw exception;
        }
        writeBackFunctionState(call.f, argumentExpressions, child);
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
                : defaultValue(arrayElementType(target.e1.type));

        writeLocation(target.e1, Value.arrayValue(elements));
    }

    private Value storageValue(
        imported!"dmd.mtype".Type type,
        in Value value,
    ) {
        import quickbite.backends.casts:
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

    // Delegates to `native_scalar.writeScalar` -- `ai/plans/value.md` item
    // 7's single scalar<->bytes authority -- rather than re-deriving a
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
    // Note this also now succeeds for `float`/`double` -- see `ai/plans/
    // value.md`'s 2026-07-10 "single scalar<->bytes authority" progress
    // note for why the old name-matched `switch`'s throw on those two types
    // was safe to drop.
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
            locals[*variable] = scalarWithByte(
                (*variable).type,
                *current,
                cast(size_t) pointer.pointerElementOffset,
                value,
            );
            arrayPointerWritebacks[*variable] = true;
            uninitializedLocals.remove(*variable);
            return true;
        }

        locals[*variable] = current.withArrayElement(
            cast(size_t) pointer.pointerElementOffset,
            value,
        );
        arrayPointerWritebacks[*variable] = true;
        uninitializedLocals.remove(*variable);
        return true;
    }

    private bool canWriteThroughArrayPointer(in Value pointer) {
        return arrayPointerVariable(pointer) !is null;
    }

    private imported!"dmd.declaration".VarDeclaration* arrayPointerVariable(
        in Value pointer,
    ) {
        if (
            !pointer.isPointer ||
            pointer.isLocalPointer ||
            pointer.isNativePointer ||
            pointer.pointerAllocation == 0
        )
            return null;

        return pointer.pointerAllocation in arrayAllocationVariables;
    }

    private void writeIndexLocation(
        imported!"dmd.expression".IndexExp index,
        in Value value,
    ) {
        const arrayIndex = cast(size_t) runExpression(index.e2).asLong;

        if (auto dot = index.e1.isDotVarExp) {
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const updatedArray = receiver.structFieldAt(fieldIndex)
                .withArrayElement(arrayIndex, value);
            writeLocation(dot.e1, receiver.withStructField(fieldIndex, updatedArray));
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

        locals[variable] = current.withArrayElement(arrayIndex, value);
        writeThroughSliceAlias(variable, arrayIndex, value);
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
            const arrayIndex = cast(size_t) runExpression(index.e2).asLong;
            const value = runExpression(rhs);
            const fieldIndex = structFieldIndex(dot);
            const receiver = runExpression(dot.e1);
            const updatedArray = receiver.structFieldAt(fieldIndex).withArrayElement(arrayIndex, value);
            writeLocation(dot.e1, receiver.withStructField(fieldIndex, updatedArray));
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
        const value = runExpression(rhs);
        locals[variable] = current.withArrayElement(arrayIndex, value);
        writeThroughSliceAlias(variable, arrayIndex, value);
        uninitializedLocals.remove(variable);
        return value;
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
        locals[alias_.source] = current.withAssocArrayEntry(alias_.key, value);
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
        locals[variable] = current.withArrayElement(
            outerIndex,
            (*current)[outerIndex].withArrayElement(innerIndex, value),
        );
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

        rejectOverlappingSliceAssignment(variable, rhs, lower, upper, current.length);

        const block = isBlockSliceAssignment(slice, rhs);
        const value = runExpression(rhs);

        Value[] elements;
        foreach (index; 0 .. current.length)
            elements ~= index < lower || index >= upper
                ? (*current)[index]
                : block ? copyArrayValue(value) : value[index - lower];

        locals[variable] = Value.arrayValue(elements);
        uninitializedLocals.remove(variable);
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
        const current = receiver.structFieldAt(fieldIndex);

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

        writeLocation(dot.e1, receiver.withStructField(
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
                : defaultValue(arrayElementType(variable.type));

        locals[variable] = Value.arrayValue(elements);
        uninitializedLocals.remove(variable);
        sliceAliases.remove(variable);
        return lengthValue;
    }

    private Value runConcatenateExpression(imported!"dmd.expression".CatExp cat) {
        return Value.arrayValue(
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
        foreach (index; 0 .. value.length)
            elements ~= value[index];

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
        locals[variable] = current.withAppendedArrayElement(value);
        uninitializedLocals.remove(variable);
        sliceAliases.remove(variable);
        return locals[variable];
    }

    private Value runArrayConcatenateAssignExpression(
        imported!"dmd.expression".BinExp assign,
    ) {
        if (assign.e1.isDotVarExp !is null) {
            const concatenated = Value.arrayValue(
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

            const concatenated = Value.arrayValue(
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
        const appended = (*current)[arrayIndex]
            .withAppendedArrayElement(runExpression(rhs));
        locals[variable] = current.withArrayElement(arrayIndex, appended);
        uninitializedLocals.remove(variable);
        return appended;
    }

    private Value castValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
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

        if (isTransparentArrayCastTarget(type))
            return runExpression(cast_.e1);

        if (type.ty == TY.Tbool)
            return boolCastValue(cast_);

        if (type.ty == TY.Tdelegate)
            return delegateCastValue(cast_);

        if (isPointerType(type))
            return pointerCastValue(cast_);

        if (auto integer = cast_.e1.isIntegerExp)
            if (integer.type !is null && integer.type.ty == TY.Tenum) {
                import quickbite.frontend.dmd.values: castIntegerValue;

                return castIntegerValue(integer, type.ty);
            }

        return backendCastValue(runExpression(cast_.e1), backendCastTarget(type));
    }

    private Value boolCastValue(imported!"dmd.expression".CastExp cast_) {
        import quickbite.backends.casts:
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

        return value.classHasType(className(classType.sym))
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

        if (!value.isClassObject)
            return false;

        result = value.classHasType("Throwable")
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

        return Value.arrayValue(values);
    }

    private Value structLiteralValue(
        imported!"dmd.expression".StructLiteralExp literal,
    ) {
        Value[] fields;
        if (literal.elements !is null)
            foreach (index, element; *literal.elements)
                fields ~= element is null
                    ? structLiteralDefaultFieldValue(literal, index)
                    : structLiteralFieldValue(literal, index, runExpression(element));

        return Value.structValue(structLiteralName(literal), fields);
    }

    private Value structLiteralDefaultFieldValue(
        imported!"dmd.expression".StructLiteralExp literal,
        in size_t index,
    ) {
        auto field = structLiteralField(literal, index);
        return field is null ? Value.void_ : defaultValue(field);
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
            locals[slice.lengthVar] = Value(source.length);
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
                Value[] elements;
                foreach (index; lower .. upper)
                    elements ~= loadNativePointerElement(
                        slice.e1.type,
                        source,
                        index,
                    );
                return Value.arrayValue(elements);
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

        return source.arraySlice(lower, upper);
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

            // A promoted cell (value.md item 7) is the byte authority: the
            // argument-evaluation pass that ran `&local` for this native
            // call already promoted `variable` (see `promoteScalarCell`),
            // so the writeback must land in the cell too, or a direct
            // `VarExp` read afterwards would see the cell's stale bytes
            // instead of what the callee wrote (e.g. pthread_mutexattr_
            // gettype's `int* kind` out-parameter).
            if (auto cell = variable in scalarCells) {
                import quickbite.backends.interpreter.native_scalar:
                    readScalar, writeScalar;

                writeScalar(variable.type, cell.bytes, writeback);
                locals[variable] = readScalar(variable.type, cell.bytes);
                uninitializedLocals.remove(variable);
                continue;
            }

            locals[variable] = writeback;
            uninitializedLocals.remove(variable);
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

        locals[variable] = receiverWriteback;
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

        // matches CTFE, which formats the index as unsigned
        arrayIndex = cast(size_t) cast(ulong) runExpression(index.e2).asLong;
        const source = runExpression(index.e1);
        if (index.lengthVar !is null)
            locals[index.lengthVar] = Value(source.length);

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

        if (auto current = (*variable) in locals)
            return *current;

        return defaultValue(*variable);
    }

    private Value pointerTargetValue(in Value pointer) {
        if (pointer.isLocalPointer)
            return localPointerTarget(pointer);
        if (!pointer.isPointer) {
            throw new Exception("Expected pointer.");
        }

        return pointer.pointerTarget;
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

            locals[*variable] = storageValue((*variable).type, value);
            uninitializedLocals.remove(*variable);
            return;
        }

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
            child.result = Value(false);
            child.thisValue = structVal;
            child.hasThis = true;
            child.bindFunctionParameters(new_.member, arguments);
            child.runStatement(new_.member.fbody);
            structVal = child.thisValue;
        } else if (new_.arguments !is null) {
            // Aggregate initialiser: assign arguments positionally to fields.
            import quickbite.backends.interpreter.layout: structFields;

            auto structType = targetType.isTypeStruct;
            foreach (index, argument; *new_.arguments) {
                if (index >= structFields(structType).length)
                    throw new Exception(text(
                        "Unsupported eval expression: ", new_.op,
                    ));
                structVal = structVal.withStructField(
                    index,
                    runExpression(argument),
                );
            }
        }

        return Value.pointerValue(structVal);
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

        auto object = classDefaultValue(classType.sym);
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
        child.result = Value(false);
        child.locals = locals.dup;
        child.localPointers = localPointers.dup;
        child.localPointerIds = localPointerIds.dup;
        child.scalarCells = scalarCells.dup;
        child.nextLocalPointerId = nextLocalPointerId;
        child.functionPointers = functionPointers.dup;
        child.functionPointerIds = functionPointerIds.dup;
        child.nextFunctionPointerId = nextFunctionPointerId;
        child.delegates = delegates.dup;
        child.lazyArgumentExpressions = lazyArgumentExpressions.dup;
        child.lazyArgumentLocals = lazyArgumentLocals.dup;
        child.thisValue = object;
        child.hasThis = true;
        child.bindFunctionParameters(new_.member, arguments);
        child.runStatement(new_.member.fbody);
        nextLocalPointerId = child.nextLocalPointerId;
        nextFunctionPointerId = child.nextFunctionPointerId;
        functionPointers = child.functionPointers;
        functionPointerIds = child.functionPointerIds;
        delegates = child.delegates;
        lazyArgumentExpressions = child.lazyArgumentExpressions;
        lazyArgumentLocals = child.lazyArgumentLocals;
        return child.thisValue;
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

        auto source = alias_.source in locals;
        if (source is null)
            throw new Exception("Unsupported interpreter slice assignment target.");

        locals[alias_.source] = source.withArrayElement(alias_.lower + index, value);
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

        locals[*sourceVariable] = source.withArrayElement(index, value);
        uninitializedLocals.remove(*sourceVariable);
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return Value(false);

        if (variable._init !is null && variable._init.isVoidInitializer !is null) {
            uninitializedLocals[variable] = true;
            return Value.void_;
        }

        if (variable._init is null || variable._init.isExpInitializer is null) {
            const value = defaultLocalValue(variable);
            locals[variable] = value;
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
                locals[variable] = value;
                uninitializedLocals.remove(variable);
                sliceAliases.remove(variable);
                structArrayFieldAliases.remove(variable);
                structFieldAliases.remove(variable);
                return value;
            }

            // DMD default-initialises struct locals with `variable = 0`
            if (isStructType(variable.type) && blit.e2.isIntegerExp !is null) {
                const value = defaultValue(variable);
                locals[variable] = value;
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
                    locals[variable] = result;
                    return result;
                }
                if (auto value = variable in locals)
                    return *value;
                return defaultValue(variable);
            }

        import quickbite.frontend.dmd.types: isAssocArrayType, isDynamicArrayType;

        if (initializer.isNullExp !is null && isDynamicArrayType(variable.type)) {
            auto value = Value.arrayValue([]);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            structArrayFieldAliases.remove(variable);
            structFieldAliases.remove(variable);
            return value;
        }

        if (initializer.isNullExp !is null && isAssocArrayType(variable.type)) {
            auto value = Value.assocArrayValue([], []);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            sliceAliases.remove(variable);
            structArrayFieldAliases.remove(variable);
            structFieldAliases.remove(variable);
            return value;
        }

        if (auto slice = initializer.isSliceExp) {
            size_t lower;
            auto value = runSliceExpression(slice, lower);
            locals[variable] = value;
            uninitializedLocals.remove(variable);
            arrayElementAliases.remove(variable);
            recordSliceAlias(variable, slice, lower);
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
        auto literal = initializer.isFuncExp;
        auto value = storageValue(
            variable.type,
            literal !is null
                ? runFunctionLiteralDeclaration(literal)
                : isArrayElementAlias
                ? runIndexExpression(indexInitializer, arrayElementAliasIndex)
                : runExpression(initializer),
        );
        locals[variable] = value;
        recordGCArrayUsedAlias(variable, initializer);
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

    private void recordGCArrayUsedAlias(
        VarDeclaration variable,
        imported!"dmd.expression".Expression initializer,
    ) {
        import quickbite.backends.interpreter.builtins:
            GCArrayHook, tryGCArrayHook;

        auto call = gcArrayUsedCall(initializer);
        if (call is null || call.f is null) {
            arrayAllocationAliases.remove(variable);
            return;
        }

        GCArrayHook hook;
        if (!tryGCArrayHook(call.f, hook) || hook != GCArrayHook.getUsed) {
            arrayAllocationAliases.remove(variable);
            return;
        }

        if (lastGCArrayUsedAllocation == 0) {
            arrayAllocationAliases.remove(variable);
            return;
        }

        arrayAllocationAliases[variable] = lastGCArrayUsedAllocation;
    }

    private imported!"dmd.expression".CallExp gcArrayUsedCall(
        imported!"dmd.expression".Expression initializer,
    ) {
        if (auto cast_ = initializer.isCastExp)
            return gcArrayUsedCall(cast_.e1);

        return initializer.isCallExp;
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

        locals[alias_.source] = source.withArrayElement(alias_.index, value);
        auto sliceAlias = alias_.source in sliceAliases;
        if (sliceAlias is null || (sliceAlias.source in locals) !is null)
            writeThroughSliceAlias(alias_.source, alias_.index, value);
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

        structFieldAliases[variable] = StructFieldAlias(
            source,
            structFieldIndex(dot),
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
        if (source is null)
            throw new Exception(
                "Unsupported interpreter struct field alias target.",
            );

        locals[alias_.source] = source.withStructField(alias_.index, value);
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

            auto current = variable in locals;
            const oldValue = current is null ? defaultValue(variable) : *current;
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


private bool isTruthy(in imported!"quickbite.lang".Value value) {
    import quickbite.lang: Value;

    if (value == Value.null_)
        return false;

    if (value.isPointer)
        return true;

    if (value.isArray)
        return value.length != 0;

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
private imported!"quickbite.lang".Value nativeConstructorReceiver(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.lang".Value receiver,
) {
    import quickbite.frontend.dmd.values: defaultValue;

    auto structDecl = function_.parent is null
        ? null
        : function_.parent.isStructDeclaration;
    return structDecl !is null ? defaultValue(structDecl.type) : receiver;
}


private imported!"quickbite.lang".Value classDefaultValue(
    imported!"dmd.dclass".ClassDeclaration class_,
) {
    import quickbite.frontend.dmd.values: defaultValue;
    import quickbite.lang: Value;
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

private bool isEmplaceRef(imported!"dmd.func".FuncDeclaration function_) {
    import std.conv: text;
    import std.string: startsWith;

    return text(function_.toPrettyChars)
        .startsWith("core.internal.lifetime.emplaceRef!(");
}


private struct SliceAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public size_t lower;
}


private struct StructArrayFieldAliases {
    public imported!"dmd.declaration".VarDeclaration[size_t] sources;
}


private struct AssocArraySlotAlias {
    public imported!"dmd.declaration".VarDeclaration source;
    public imported!"quickbite.lang".Value key;
}


private struct RuntimeDelegate {
    public imported!"dmd.func".FuncDeclaration function_;
    public size_t functionPointerId;
    public imported!"quickbite.lang".Value contextPointer;
    public imported!"quickbite.lang".Value receiver;
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

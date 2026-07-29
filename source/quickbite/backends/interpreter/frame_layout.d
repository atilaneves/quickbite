module quickbite.backends.interpreter.frame_layout;


private:


// A per-activation frame slot: either an OWNING slot -- inline storage for
// a local that owns its own storage (a value parameter or a body-declared
// variable), sized/aligned to that local's own declared type -- or a
// pointer-width REFERENCE slot holding an address rather than a rendition
// of the local's own declared type: for a `ref`/`out` parameter, the
// caller-supplied address it binds to; for a captured outer variable (a
// nested function's own `FuncDeclaration.outerVars`, see `capturedVariables`
// below), the enclosing activation's own address for that variable. The two
// kinds are deliberately distinguishable (`Slot.kind`) so nothing composing
// a `Place` from a slot's raw bytes at the local's own declared type could
// mistake a reference slot's stored ADDRESS for inline storage of that
// type. A `lazy` parameter and a `ref` body local still get no slot of
// either kind: a `lazy` parameter is a delegate over the caller's own live
// frame, not an address of its own, and a `ref` body local's binding
// machinery is unchanged by this slice -- neither ever appears here.
public struct FrameLayout {
    import dmd.declaration: VarDeclaration;

    public static struct Slot {
        public enum Kind { owning, reference }

        public size_t offset;
        public size_t size;
        public Kind kind = Kind.owning;
    }

    private Slot[VarDeclaration] _slots;
    private size_t _byteLength;

    public bool has(VarDeclaration variable) const pure nothrow @safe {
        return (variable in _slots) !is null;
    }

    public Slot opIndex(VarDeclaration variable) const pure @safe {
        return _slots[variable];
    }

    // The activation's total frame size: the packing cursor after every
    // slot, aligned up to the largest alignment any slot used (or 1 if the
    // activation owns no slot at all).
    public size_t byteLength() const pure nothrow @nogc @safe {
        return _byteLength;
    }

    public const(Slot[VarDeclaration]) slots() const pure nothrow @safe {
        return _slots;
    }
}


// Assigns one frame slot to `function_`'s activation, in encounter order:
// each of its parameters (an OWNING slot for a plain value parameter,
// sized/aligned from DMD's own `layout.typeByteSize`/`typeAlignment`; a
// pointer-width REFERENCE slot for a `ref`/`out` parameter -- sized/
// aligned from the host pointer's own `(void*).sizeof`/`(void*).alignof`,
// since what it holds is an address, never a rendition of the
// parameter's own declared type; nothing at all for a `lazy` parameter,
// which aliases the caller's live frame through a delegate instead of an
// address of its own), then -- for a nested function only -- one more
// pointer-width REFERENCE slot per outer variable it captures
// (`capturedVariables` below; empty for a non-nested function, so this
// adds nothing for one), then every OWNING variable declared in the body
// (`isAliasingLocal` below still excludes a `ref` body local, a
// `static`/`__gshared` variable, and an `enum` manifest constant -- this
// slice only gives `ref`/`out` PARAMETERS a slot of their own; a `ref`
// body local remains untouched). Each slot's offset is packed at the
// current cursor aligned up to that slot's own alignment; `FrameLayout.
// byteLength` is the final cursor aligned up to the largest alignment any
// slot used.
public FrameLayout computeFrameLayout(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    import quickbite.backends.interpreter.layout: typeByteSize, typeAlignment, typeIsSized, declaredType;
    import dmd.declaration: VarDeclaration;

    FrameLayout.Slot[VarDeclaration] slots;
    size_t cursor;
    size_t maxAlignment = 1;

    void place(
        VarDeclaration variable,
        in size_t size,
        in size_t alignment,
        FrameLayout.Slot.Kind kind,
    ) {
        cursor = alignedUp(cursor, alignment);
        slots[variable] = FrameLayout.Slot(cursor, size, kind);
        cursor += size;
        if (alignment > maxAlignment)
            maxAlignment = alignment;
    }

    foreach (index, parameter; activationParameters(function_)) {
        if (isReferenceParameter(function_, index, parameter)) {
            place(
                parameter,
                (void*).sizeof,
                (void*).alignof,
                FrameLayout.Slot.Kind.reference,
            );
            continue;
        }

        auto type = declaredType(parameter);
        if (!typeIsSized(type))
            continue;

        place(parameter, typeByteSize(type), typeAlignment(type), FrameLayout.Slot.Kind.owning);
    }

    foreach (variable; capturedVariables(function_))
        place(variable, (void*).sizeof, (void*).alignof, FrameLayout.Slot.Kind.reference);

    foreach (variable; bodyLocals(function_.fbody)) {
        if (isAliasingLocal(variable))
            continue;

        auto type = declaredType(variable);
        if (!typeIsSized(type))
            continue;

        place(variable, typeByteSize(type), typeAlignment(type), FrameLayout.Slot.Kind.owning);
    }

    return FrameLayout(slots, alignedUp(cursor, maxAlignment));
}


// The enclosing-scope locals `function_` reads or writes as a nested
// function -- DMD's own `FuncDeclaration.outerVars`, populated by
// `funcsem.checkNestedReference` during semantic analysis of `function_`'s
// own body: every reference to a variable belonging to a lexically
// enclosing function gets recorded here, deduplicated, and already
// flattened across however many enclosing scopes it crosses (a doubly-
// nested function's `outerVars` names a grandparent's local directly, not
// just its immediate parent's -- `impl.d`'s capture binding resolves only
// ONE level, against ITS OWN caller's frame, so a capture that needs a
// relay through an intermediate activation that never itself references
// the variable still declines; see that function's own header). Empty for
// a non-nested function. Never includes a `dataseg`/`__gshared`/`static`
// or `enum manifest` variable: `checkNestedReference` excludes both before
// ever touching `outerVars`, matching `isAliasingLocal`'s identical
// exclusion for a body local -- this is DMD's OWN capture analysis, not a
// re-derivation of it: this module must never walk `function_.fbody`
// itself to decide what it captures.
public imported!"dmd.declaration".VarDeclaration[] capturedVariables(
    imported!"dmd.func".FuncDeclaration function_,
) @safe {
    return capturedVariablesImpl(function_);
}

// `FuncDeclaration.outerVars` (an `Array!VarDeclaration`) is a plain field
// read of DMD's own already-populated state, but `FuncDeclaration` (an
// `extern (C++)` class) is not itself `@safe`-annotated; this is the
// `@trusted` boundary, mirroring `activationParameters`'s identical trust
// for `function_.parameters`.
private imported!"dmd.declaration".VarDeclaration[] capturedVariablesImpl(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    import dmd.declaration: VarDeclaration;

    VarDeclaration[] variables;
    foreach (variable; function_.outerVars)
        variables ~= variable;

    return variables;
}


// Rounds `value` up to the next multiple of `alignment`. `alignment` is
// always a DMD-reported type alignment or the host pointer's own
// (>= 1), never zero.
private size_t alignedUp(in size_t value, in size_t alignment) pure nothrow @nogc @safe {
    return (value + alignment - 1) / alignment * alignment;
}


// Memoized `computeFrameLayout` results, keyed by function. A plain module
// variable is thread-local storage in D, so this needs no synchronisation;
// a `FuncDeclaration`'s frame layout never changes once computed, so the
// cache never needs invalidation.
private FrameLayout[imported!"dmd.func".FuncDeclaration] _frameLayoutCache;


// DMD fixture compilations replace their AST arenas, so declaration addresses
// can be reused by a later module in the same test process. Keep memoization
// within one interpreter root execution, but never across compiler lifetimes.
public void clearFrameLayoutCache() @safe {
    _frameLayoutCache.clear;
}


// `computeFrameLayout(function_)`, memoized: the first call for `function_`
// walks its body and caches the result; every later call for the same
// `function_` returns the cached layout instead of re-walking it.
public FrameLayout cachedFrameLayout(
    imported!"dmd.func".FuncDeclaration function_,
) @safe {
    if (auto cached = function_ in _frameLayoutCache)
        return *cached;

    // `auto`, not `const`: `FrameLayout` holds an associative array, so a
    // `const` local cannot convert to the mutable `FrameLayout` this
    // function returns and stores.
    auto layout = computeFrameLayout(function_);
    _frameLayoutCache[function_] = layout;
    return layout;
}


// `function_`'s own parameters, in encounter order, minus a `lazy`
// parameter: `lazy` is the one parameter storage class that gets no frame
// slot of either kind (a `lazy` argument is a delegate over the caller's
// own live frame, not an address `computeFrameLayout` could pack anywhere
// -- see `bindLazyFunctionParameter`/`runLazyArgument` in `impl.d`). A
// `ref`/`out` parameter IS included here (`parameterIsReference` below
// routes it to a reference slot instead of skipping it), unlike
// `isAliasingLocal`'s treatment of the same storage classes for a BODY
// local. Walks DMD's own parameter array via DMD's own dynamic-cast
// accessors and `storage_class` flags -- read-only traversal of
// already-computed DMD state, no arithmetic of our own, so this is the
// `@trusted` boundary the way `layout.classFieldsImpl` trusts its own
// base-to-derived class walk.
private imported!"dmd.declaration".VarDeclaration[] activationParameters(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    import dmd.declaration: VarDeclaration;
    import dmd.astenums: STC;

    VarDeclaration[] parameters;
    if (function_.parameters !is null)
        foreach (parameter; *function_.parameters)
            if ((parameter.storage_class & STC.lazy_) == STC.none)
                parameters ~= parameter;

    return parameters;
}


// Whether `parameter` is a `ref`/`out` parameter -- DMD's own
// `VarDeclaration.isReference` (`(storage_class & (STC.ref_ | STC.out_))
// != 0`), already `@safe` in DMD itself, so no `@trusted` boundary is
// needed here.
public bool isReferenceParameter(
    imported!"dmd.func".FuncDeclaration function_,
    in size_t index,
    imported!"dmd.declaration".VarDeclaration parameter,
) @trusted {
    import dmd.astenums: STC;

    if ((parameter.storage_class & STC.parameter) == STC.none)
        return false;
    if (parameter.isReference)
        return true;
    if (!parameter.type.isShared)
        return false;

    auto functionType = function_.type is null
        ? null
        : function_.type.toBasetype.isTypeFunction;
    auto canonical = functionType is null
        ? null
        : functionType.parameterList.parameters;
    if (canonical is null || index >= canonical.length)
        return false;

    enum refLike = STC.ref_ | STC.out_ | STC.auto_;
    return ((*canonical)[index].storageClass & refLike) != STC.none;
}


// Whether `variable` (a BODY local; a parameter never reaches this --
// `computeFrameLayout` classifies every parameter itself, via
// `activationParameters`/`parameterIsReference` above) has no per-
// activation frame slot to own: either it aliases another frame's storage
// instead of owning its own (a `ref` body local), or it never owns
// per-activation storage in the first place -- a `static`/`__gshared`/
// module-level local (`VarDeclaration.isDataseg`), which lives in the
// module table instead of any one activation's frame, or an `enum`
// manifest constant (`STC.manifest`), which has no storage at all: DMD
// substitutes its value at every use rather than allocating it anywhere.
private bool isAliasingLocal(imported!"dmd.declaration".VarDeclaration variable) @trusted {
    import dmd.astenums: STC;

    if ((variable.storage_class & (STC.ref_ | STC.out_ | STC.lazy_ | STC.manifest)) != STC.none)
        return true;

    return variable.isDataseg;
}


// Every `VarDeclaration` a `DeclarationExp` introduces within `statement`'s
// subtree, in the order the statement tree declares them. Mirrors the
// statement-tree recursion the interpreter's own walker uses to run a
// function body (`Walker.runStatement`): compound and compound-declaration
// blocks, scope statements, if conditions and branches, for/do bodies
// (`while`/`foreach` are
// lowered to `ForStatement` by DMD's own semantic pass, so no separate
// case is needed for them), try/finally/catch, unrolled loop bodies,
// labels, switch/case/default, and with-statements.
private imported!"dmd.declaration".VarDeclaration[] bodyLocals(
    imported!"dmd.statement".Statement statement,
) @trusted {
    import dmd.declaration: VarDeclaration;

    if (statement is null)
        return null;

    VarDeclaration[] locals;

    if (auto compound = statement.isCompoundDeclarationStatement) {
        if (compound.statements !is null)
            foreach (child; *compound.statements)
                locals ~= bodyLocals(child);
        return locals;
    }

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements !is null)
            foreach (child; *compound.statements)
                locals ~= bodyLocals(child);
        return locals;
    }

    if (auto scope_ = statement.isScopeStatement)
        return bodyLocals(scope_.statement);

    if (auto tryFinally = statement.isTryFinallyStatement)
        return bodyLocals(tryFinally._body) ~ bodyLocals(tryFinally.finalbody);

    if (auto tryCatch = statement.isTryCatchStatement) {
        locals = bodyLocals(tryCatch._body);
        if (tryCatch.catches !is null)
            foreach (catch_; *tryCatch.catches)
                locals ~= bodyLocals(catch_.handler);
        return locals;
    }

    if (auto unrolled = statement.isUnrolledLoopStatement) {
        if (unrolled.statements !is null)
            foreach (child; *unrolled.statements)
                locals ~= bodyLocals(child);
        return locals;
    }

    if (auto label = statement.isLabelStatement)
        return bodyLocals(label.statement);

    if (auto for_ = statement.isForStatement)
        return bodyLocals(for_._init) ~ bodyLocals(for_._body);

    if (auto do_ = statement.isDoStatement)
        return bodyLocals(do_._body);

    if (auto switch_ = statement.isSwitchStatement)
        return bodyLocals(switch_._body);

    if (auto case_ = statement.isCaseStatement)
        return case_.statement is statement ? null : bodyLocals(case_.statement);

    if (auto default_ = statement.isDefaultStatement)
        return default_.statement is statement ? null : bodyLocals(default_.statement);

    if (auto caseRange = statement.isCaseRangeStatement)
        return caseRange.statement is statement ? null : bodyLocals(caseRange.statement);

    if (auto if_ = statement.isIfStatement)
        return declaredVariables(if_.condition) ~ bodyLocals(if_.ifbody) ~
            bodyLocals(if_.elsebody);

    if (auto with_ = statement.isWithStatement)
        return bodyLocals(with_._body);

    if (auto expression = statement.isExpStatement)
        return declaredVariable(expression.exp);

    return null;
}


// The `VarDeclaration` a bare `DeclarationExp` introduces, if `expression`
// is one; `null` (as an empty array) for anything else, including a
// declaration of a non-variable symbol (e.g. `alias`).
private imported!"dmd.declaration".VarDeclaration[] declaredVariable(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import dmd.declaration: VarDeclaration;

    if (expression is null)
        return null;

    auto declaration = expression.isDeclarationExp;
    if (declaration is null)
        return null;

    auto variable = declaration.declaration.isVarDeclaration;
    return variable is null ? null : [variable];
}


// Every `VarDeclaration` a `DeclarationExp` introduces within `expression`.
// DMD lowers `if (T name = value)` to a `CommaExp` whose left operand is the
// declaration and whose right operand reads the new local.
private imported!"dmd.declaration".VarDeclaration[] declaredVariables(
    imported!"dmd.expression".Expression expression,
) @trusted {
    if (auto variable = declaredVariable(expression))
        return variable;

    if (auto comma = expression.isCommaExp)
        return declaredVariables(comma.e1) ~ declaredVariables(comma.e2);

    return null;
}

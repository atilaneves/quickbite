module quickbite.backends.interpreter.frame_layout;


private:


// A per-activation frame slot assigned to each local that owns its own
// storage: value parameters and body-declared variables. A local that
// aliases another frame's storage instead of owning one (`ref`/`out`/
// `lazy` parameters, `ref` body locals) never appears here.
public struct FrameLayout {
    import dmd.declaration: VarDeclaration;

    public static struct Slot {
        public size_t offset;
        public size_t size;
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


// Assigns one frame slot to each owning local of `function_`'s activation:
// its value parameters, then every variable declared in its body, in
// encounter order. Sizing and alignment come only from `layout.
// typeByteSize`/`typeAlignment` -- DMD's own numbers, never recomputed
// here. Each slot's offset is packed at the current cursor aligned up to
// that slot's own alignment; `FrameLayout.byteLength` is the final cursor
// aligned up to the largest alignment any slot used.
public FrameLayout computeFrameLayout(
    imported!"dmd.func".FuncDeclaration function_,
) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize, typeAlignment, typeIsSized, declaredType;
    import dmd.declaration: VarDeclaration;

    FrameLayout.Slot[VarDeclaration] slots;
    size_t cursor;
    size_t maxAlignment = 1;

    foreach (variable; owningLocals(function_)) {
        auto type = declaredType(variable);
        if (!typeIsSized(type))
            continue;

        const alignment = typeAlignment(type);
        const size = typeByteSize(type);
        cursor = alignedUp(cursor, alignment);
        slots[variable] = FrameLayout.Slot(cursor, size);
        cursor += size;
        if (alignment > maxAlignment)
            maxAlignment = alignment;
    }

    return FrameLayout(slots, alignedUp(cursor, maxAlignment));
}


// Rounds `value` up to the next multiple of `alignment`. `alignment` is
// always a DMD-reported type alignment (>= 1), never zero.
private size_t alignedUp(in size_t value, in size_t alignment) pure nothrow @nogc @safe {
    return (value + alignment - 1) / alignment * alignment;
}


// Memoized `computeFrameLayout` results, keyed by function. A plain module
// variable is thread-local storage in D, so this needs no synchronisation;
// a `FuncDeclaration`'s frame layout never changes once computed, so the
// cache never needs invalidation.
private FrameLayout[imported!"dmd.func".FuncDeclaration] _frameLayoutCache;


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


// Every owning local of `function_`'s activation, in encounter order:
// its value parameters (skipping `ref`/`out`/`lazy`, which alias the
// caller's storage instead of owning a slot), then every variable
// declared in its body (skipping `ref` locals, which alias another
// frame's storage). Walks DMD's own parameter array and statement tree
// via DMD's own dynamic-cast accessors and `storage_class` flags -- read-
// only traversal of already-computed DMD state, no arithmetic of our own,
// so this is the `@trusted` boundary the way `layout.classFieldsImpl`
// trusts its own base-to-derived class walk.
private imported!"dmd.declaration".VarDeclaration[] owningLocals(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    import dmd.declaration: VarDeclaration;

    VarDeclaration[] locals;

    if (function_.parameters !is null)
        foreach (parameter; *function_.parameters)
            if (!isAliasingLocal(parameter))
                locals ~= parameter;

    foreach (variable; bodyLocals(function_.fbody))
        if (!isAliasingLocal(variable))
            locals ~= variable;

    return locals;
}


// Whether `variable` has no per-activation frame slot to own: either it
// aliases another frame's storage instead of owning its own (a `ref`/
// `out`/`lazy` parameter, or a `ref` body local), or it never owns
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
// blocks, scope statements, if/for/do bodies (`while`/`foreach` are
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
        return bodyLocals(if_.ifbody) ~ bodyLocals(if_.elsebody);

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

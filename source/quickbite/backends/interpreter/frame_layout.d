module quickbite.backends.interpreter.frame_layout;


private:


// A per-activation frame slot: either an OWNING slot -- inline storage for
// a local that owns its own storage (a value parameter or a body-declared
// variable), sized/aligned to that local's own declared type -- or a
// pointer-width REFERENCE slot holding an address rather than a rendition
// of the local's own declared type: for a `ref`/`out` parameter or body
// local, the address it binds to; for a captured outer variable (a nested
// function's own `FuncDeclaration.outerVars`, see `capturedVariables` below),
// the enclosing activation's own address for that variable; and for `vthis`,
// the receiver address. The two kinds are deliberately distinguishable
// (`Slot.kind`) so nothing composing
// a `Place` from a slot's raw bytes at the local's own declared type could
// mistake a reference slot's stored ADDRESS for inline storage of that
// type. A `lazy` parameter gets no slot: it is a thunk over the caller's live
// frame, not an address of its own.
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
// address of its own), then a REFERENCE slot for `vthis`, then -- for a
// function with an out contract -- an OWNING slot for DMD's synthetic
// `__result`, then -- for a nested function only -- one more pointer-width
// REFERENCE slot per outer
// variable it captures (`capturedVariables` below; empty for a non-nested
// function, so this adds nothing for one), then every variable declared in
// the body
// (`isStorageFreeLocal` below excludes a `static`/`__gshared` variable and an
// `enum` manifest constant; a `ref` body local receives a reference slot).
// Each slot's offset is packed at the current cursor aligned up to that slot's
// own alignment; `FrameLayout.byteLength` is the final cursor aligned up to
// the largest alignment any slot used.
public FrameLayout computeFrameLayout(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted {
    import quickbite.backends.interpreter.layout:
        declaredType, typeAlignment, typeByteSize, typeIsSized;
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
        if (variable in slots)
            return;

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

        place(
            parameter,
            typeByteSize(type),
            typeAlignment(type),
            FrameLayout.Slot.Kind.owning,
        );
    }

    if (
        function_.vthis !is null &&
        function_.vthis.isThisDeclaration !is null
    )
        place(
            function_.vthis,
            (void*).sizeof,
            (void*).alignof,
            FrameLayout.Slot.Kind.reference,
        );

    if (function_.vresult !is null) {
        auto type = declaredType(function_.vresult);
        if (typeIsSized(type))
            place(
                function_.vresult,
                typeByteSize(type),
                typeAlignment(type),
                FrameLayout.Slot.Kind.owning,
            );
    }

    foreach (variable; capturedVariables(function_))
        place(variable, (void*).sizeof, (void*).alignof, FrameLayout.Slot.Kind.reference);

    foreach (variable; bodyLocals(function_.fbody)) {
        if (isStorageFreeLocal(variable))
            continue;

        if (variable.isReference) {
            place(
                variable,
                (void*).sizeof,
                (void*).alignof,
                FrameLayout.Slot.Kind.reference,
            );
            continue;
        }

        auto type = declaredType(variable);
        if (!typeIsSized(type))
            continue;

        place(
            variable,
            typeByteSize(type),
            typeAlignment(type),
            FrameLayout.Slot.Kind.owning,
        );
    }

    return FrameLayout(slots, alignedUp(cursor, maxAlignment));
}


// A frame layout for a single free-standing expression, not a function
// body: the slot set a dataseg variable's own initializer expression needs
// for whatever locals DMD's frontend lowering synthesized INSIDE it (an
// AA literal's `_d_assocarrayliteralTX` lowering hoists its keys/values
// arrays into `__arrayliteral_on_stack*` temps, `tryLowerAALiteral`/
// `functionArguments` in dmd's `expressionsem.d`). Those temps are parented
// to whatever scope enclosed the initializer at semantic time -- the
// module, for a module-scope variable -- never to any `FuncDeclaration`'s
// own body, so `computeFrameLayout`'s `bodyLocals(function_.fbody)` walk
// can never find them regardless of which function happens to be running
// when the lazy dataseg materialization triggers. This gives the
// initializer expression a frame of its own, sized from `expressionLocals`
// the same way `computeFrameLayout` sizes a function's body locals: same
// per-declaration slot kind (owning vs. reference), same packing order,
// same alignment rule.
public FrameLayout computeExpressionFrameLayout(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import quickbite.backends.interpreter.layout:
        declaredType, typeAlignment, typeByteSize, typeIsSized;
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
        if (variable in slots)
            return;

        cursor = alignedUp(cursor, alignment);
        slots[variable] = FrameLayout.Slot(cursor, size, kind);
        cursor += size;
        if (alignment > maxAlignment)
            maxAlignment = alignment;
    }

    foreach (variable; expressionLocals(expression)) {
        if (isStorageFreeLocal(variable))
            continue;

        if (variable.isReference) {
            place(
                variable,
                (void*).sizeof,
                (void*).alignof,
                FrameLayout.Slot.Kind.reference,
            );
            continue;
        }

        auto type = declaredType(variable);
        if (!typeIsSized(type))
            continue;

        place(
            variable,
            typeByteSize(type),
            typeAlignment(type),
            FrameLayout.Slot.Kind.owning,
        );
    }

    return FrameLayout(slots, alignedUp(cursor, maxAlignment));
}


// Every `VarDeclaration` DMD's own visitor observes within a single
// expression, including a synthetic declaration a frontend lowering pass
// hoists into it (`__arrayliteral_on_stack*`, an `$`-length variable, ...).
// Preserves encounter order and deduplicates; the same walk `bodyLocals`'s
// own `appendExpression` uses per-expression, exposed here so a lone
// expression (never itself part of any function body) can be sized the
// same way.
private imported!"dmd.declaration".VarDeclaration[] expressionLocals(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import dmd.declaration: VarDeclaration;

    VarDeclaration[] locals;
    bool[VarDeclaration] seen;
    void append(VarDeclaration variable) {
        if (variable is null || variable in seen)
            return;
        seen[variable] = true;
        locals ~= variable;
    }

    appendVarsInExpression(expression, &append);

    return locals;
}


// `expression.foreachVar` (`dmd.visitor.foreachvar`) plus `$`-length
// variables, plus every `__arrayliteral_on_stack*` temp a DIP1000
// scope-argument lowering hides behind an `AssocArrayLiteralExp.lowering`
// DMD's own tree walkers never follow. `dmd.visitor.postorder`'s
// `PostorderExpressionVisitor` -- the driver behind `foreachVar` and
// `foreachExpAndVar` alike -- has a `.lowering`-aware override for
// `CatExp`/`CatAssignExp`/`EqualExp` (each walks `.lowering` INSTEAD of its
// original operands once semantic sets it) but NOT for
// `AssocArrayLiteralExp`: its own override always walks `.keys`/`.values`,
// the PRE-lowering key/value expressions, regardless of whether
// `.lowering` is set. `tryLowerAALiteral`/`functionArguments`
// (`expressionsem.d`) hoists a non-empty keys or values array literal
// passed to the `scope`-inferred `_d_assocarrayliteralTX(keys, values)`
// hook into a `__arrayliteral_on_stack*` `DeclarationExp` nested INSIDE
// that lowering, so it lives nowhere `foreachVar` ever looks: neither this
// walk nor `bodyLocals`'s `computeFrameLayout` walk over a function's own
// body ever reserves it a frame slot, so interpreting the initializer
// (anywhere -- module scope, a local inside a `unittest`, ...) throws
// "has no native place" once DIP1000 makes the temp exist at all. This
// finds every reachable `AssocArrayLiteralExp` in `expression` itself (a
// bare `visit` override on a `StoppableVisitor`, driven by
// `walkPostorder`'s own unrelated structural descent, so it costs nothing
// beyond a second walk) and, for each with a lowering, additionally walks
// that lowering the normal way.
private void appendVarsInExpression(
    imported!"dmd.expression".Expression expression,
    scope void delegate(imported!"dmd.declaration".VarDeclaration) append,
) @trusted {
    import dmd.declaration: VarDeclaration;
    import dmd.dsymbolsem: toAlias;
    import dmd.expression: AssocArrayLiteralExp, DeclarationExp, Expression;
    import dmd.visitor: StoppableVisitor;
    import dmd.visitor.foreachvar: foreachVar;
    import dmd.visitor.postorder: walkPostorder;

    expression.foreachVar(append);
    if (auto index = expression.isIndexExp)
        append(index.lengthVar);
    if (auto slice = expression.isSliceExp)
        append(slice.lengthVar);

    extern (C++) final class LoweredAALiteralFinder: StoppableVisitor {
        alias visit = typeof(super).visit;
        extern (D) void delegate(VarDeclaration) append;

        extern (D) this(
            scope void delegate(VarDeclaration) append,
        ) scope @trusted {
            this.append = append;
        }

        override void visit(Expression e) {
        }

        override void visit(AssocArrayLiteralExp e) {
            if (e.lowering is null)
                return;
            e.lowering.foreachVar(append);
            walkPostorder(e.lowering, this);
        }

        // `PostorderExpressionVisitor` (`dmd.visitor.postorder`, the driver
        // behind `walkPostorder`) has no structural-descent override for
        // `DeclarationExp` at all -- a declared local's own initializer is
        // reached only through `dmd.visitor.foreachvar`'s OWN hand-rolled
        // `VarWalker.visit(DeclarationExp e)`, never through generic
        // postorder descent. Without this override this finder would see
        // `auto map = [p: 105];`'s outer `DeclarationExp` node and stop --
        // exactly cerealed's own regression shape (`tests/bugs.d`'s
        // `assoc.array.with.pair`, a LOCAL, not module-scope, AA literal) --
        // never reaching the nested `AssocArrayLiteralExp` its own
        // initializer carries. Mirrors `VarWalker`'s own recursion
        // condition (skip an alias and a `static`/dataseg declaration,
        // whose initializer `bodyLocals`/`isStorageFreeLocal` handle on
        // their own terms).
        override void visit(DeclarationExp e) {
            auto v = e.declaration.isVarDeclaration;
            if (v is null || v.toAlias !is v || v.isStatic || v._init is null)
                return;
            auto initializer = v._init.isExpInitializer;
            if (initializer is null)
                return;
            walkPostorder(initializer.exp, this);
        }
    }

    scope finder = new LoweredAALiteralFinder(append);
    walkPostorder(expression, finder);
}


// The enclosing-scope locals `function_` reads or writes as a nested
// function -- DMD's own `FuncDeclaration.outerVars`, populated by
// `funcsem.checkNestedReference` during semantic analysis of `function_`'s
// own body: every reference to a variable belonging to a lexically
// enclosing function gets recorded here, deduplicated, and already
// flattened across however many enclosing scopes it crosses (a doubly-
// nested function's `outerVars` names a grandparent's local directly, not
// just its immediate parent's; `impl.d` resolves that declaration through
// the native static-link chain. A method of a function-local aggregate may
// also have `outerVars` even though `FuncDeclaration.isNested` is false, so
// callers must use this list itself as the capture authority. Empty when a
// function captures no enclosing declaration. Never includes a
// `dataseg`/`__gshared`/`static`
// or `enum manifest` variable: `checkNestedReference` excludes both before
// ever touching `outerVars`, matching `isStorageFreeLocal`'s identical
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
// `ref`/`out` parameter is included: `computeFrameLayout` identifies it with
// `isReferenceParameter` and gives it a pointer-width reference slot. Walks
// DMD's own parameter array via DMD's own dynamic-cast accessors and
// `storage_class` flags -- read-only traversal of already-computed DMD state,
// no arithmetic of our own, so this is the `@trusted` boundary the way
// `layout.classFieldsImpl` trusts its own base-to-derived class walk.
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


// Whether `variable` (a body local; parameters are classified separately)
// gets no per-activation frame slot. A `lazy` local or manifest constant has
// no storage, while a `static`, `__gshared`, or module-level declaration lives
// in the module table. A body variable with `isReference` is deliberately not
// storage-free: `computeFrameLayout` gives it a pointer-width reference slot.
private bool isStorageFreeLocal(imported!"dmd.declaration".VarDeclaration variable) @trusted {
    import dmd.astenums: STC;

    if ((variable.storage_class & (STC.lazy_ | STC.manifest)) != STC.none)
        return true;

    return variable.isDataseg;
}


// Every body variable DMD's own visitor observes, including synthetic
// declarations such as `$` length variables and `with` receivers. Preserve
// encounter order and deduplicate variables reached through both the
// statement and expression callbacks.
private imported!"dmd.declaration".VarDeclaration[] bodyLocals(
    imported!"dmd.statement".Statement statement,
) @trusted {
    import dmd.declaration: VarDeclaration;
    import dmd.expression: Expression;
    import dmd.visitor.foreachvar: foreachExpAndVar;

    VarDeclaration[] locals;
    bool[VarDeclaration] seen;
    void append(VarDeclaration variable) {
        if (variable is null || variable in seen)
            return;
        seen[variable] = true;
        locals ~= variable;
    }
    void appendExpression(Expression expression) {
        appendVarsInExpression(expression, &append);
    }

    statement.foreachExpAndVar(
        &appendExpression,
        &append,
    );
    return locals;
}

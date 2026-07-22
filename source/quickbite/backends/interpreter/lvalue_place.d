module quickbite.backends.interpreter.lvalue_place;


private:


// Composes a `Place` for the pure address-composition lvalue shapes: a bare
// variable, a `ThisExp` (the hidden `this` of a method body, resolved to its
// own `vthis` variable exactly like a bare variable -- see that arm's own
// comment for why it currently never resolves through the only consumer), a
// chain of field accesses reached through `DotVarExp` receivers (a struct
// receiver's field sits inline at a fixed offset from the receiver's own
// address; a class receiver holds a reference, so its field composes through
// `Place.deref` onto the object body first), a `PtrExp` (`*p`) that composes
// through `Place.deref` onto the pointee, or an `IndexExp` over a base place
// that is itself one of these shapes. `resolveBase` supplies the base address
// for a variable, and `evalIndex` evaluates an `IndexExp`'s own index
// subexpression to a `size_t` -- the only per-caller policy this function
// needs, so it stays address composition over DMD's own AST and offsets, with
// no evaluation of its own beyond that and no Walker state. `a[i]` composes as
// `placeOfLvalue(a).index(evalIndex(i))`, which `Place.index` resolves
// uniformly for a static-array, pointer, or slice base (following the stored
// pointer for the latter two).
//
// Every arm returns the place OF the expression it was handed, never of
// something one dereference further in. A `SymOffExp` (DMD's constant-offset
// address-of shape, `&local`/`&arr[2]`) therefore has no arm of its own: it
// is an RVALUE naming an address, with no location of its own to return.
// The two shapes that can legitimately meet one -- `*&x` and `(&x)[i]`, both
// of which DMD really does hand a call site (`g(*&p)`, `arr.ptr[i]`) --
// resolve it through `symOffTarget` below instead, which lands directly on
// what it points at with no second dereference of their own.
//
// Every other lvalue shape refuses rather than guesses: `CommaExp` and
// anything else fall through to the same refusal. Those arrive with wiring
// to the expression evaluator.
public imported!"quickbite.backends.interpreter.place".Place placeOfLvalue(
    imported!"dmd.expression".Expression expr,
    void* delegate(imported!"dmd.declaration".VarDeclaration) @safe resolveBase,
    size_t delegate(imported!"dmd.expression".Expression) @safe evalIndex,
) @safe {
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.layout: declaredType;

    if (auto var = expr.isVarExp) {
        auto variable = varExpDeclaration(var).isVarDeclaration;
        if (variable is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "VarExp does not resolve to a variable",
            );

        return Place(resolveBase(variable), declaredType(variable));
    }

    // A struct `this`'s place sits directly at the receiver's own storage, a
    // class `this`'s place holds a stored reference to it, matching how a
    // struct- or class-typed variable already composes above -- but no
    // caller can reach either today, and this arm claims no coverage it does
    // not have. `resolveBase` is only ever `impl.d`'s `callerReferenceBase`,
    // which resolves a dataseg variable, an owning frame slot, or a
    // reference slot; DMD keeps `vthis` out of `FuncDeclaration.parameters`
    // and out of the body's own declarations, so `frame_layout.
    // computeFrameLayout` slots it as neither, and it is not dataseg either.
    // Every lvalue containing `this` therefore declines, unconditionally and
    // safely. Kept, rather than folded into the refusal below, because it is
    // the composition a `vthis` slot would need on the day one exists (a
    // struct's `vthis` is `ref`, so that is a reference slot plus a bind at
    // method entry, not a line here) and its two unit tests pin the
    // struct-vs-class distinction that day depends on.
    if (auto this_ = expr.isThisExp) {
        auto variable = thisExpDeclaration(this_);
        if (variable is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "ThisExp has no `this` variable",
            );

        return Place(resolveBase(variable), declaredType(variable));
    }

    if (auto index = expr.isIndexExp) {
        auto baseExpression = indexExpBase(index);

        // A pointer RVALUE base -- `arr.ptr[i]` and `(&a[1])[0]` both reach
        // here as a `SymOffExp` -- has no storage of its own for
        // `Place.index`'s pointer case to read a stored pointer back out
        // of: the pointer's VALUE is already the address `symOffTarget`
        // composes. Step that target place by `i` elements directly.
        if (auto symbol = baseExpression.isSymOffExp)
            return elementOfTarget(
                symOffTarget(symbol, resolveBase),
                evalIndex(indexExpIndex(index)),
            );

        auto base = placeOfLvalue(baseExpression, resolveBase, evalIndex);
        return base.index(evalIndex(indexExpIndex(index)));
    }

    if (auto dot = expr.isDotVarExp) {
        auto field = dotVarExpDeclaration(dot).isVarDeclaration;
        if (field is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "DotVarExp does not resolve to a field variable",
            );

        auto receiver = placeOfLvalue(dotVarExpReceiver(dot), resolveBase, evalIndex);
        if (receiver.type.isTypeStruct !is null)
            return receiver.field(field);
        if (receiver.type.isTypeClass !is null)
            return receiver.deref.field(field);

        throw new Exception(
            "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
            ~ "DotVarExp receiver is not a struct- or class-typed place",
        );
    }

    if (auto ptr = expr.isPtrExp) {
        auto operand = ptrExpBase(ptr);

        // `*&x` -- DMD hands a `ref` argument written that way exactly this
        // shape (`optimize.d`'s `visitPtr` folds the operand to a
        // `SymOffExp` and returns at `keepLvalue` before folding the
        // `PtrExp` away). The `SymOffExp` names the address directly, so
        // `symOffTarget` IS this place; a `Place.deref` on top would read
        // whatever `x`'s own first pointer-width bytes happen to hold.
        if (auto symbol = operand.isSymOffExp)
            return symOffTarget(symbol, resolveBase);

        return placeOfLvalue(operand, resolveBase, evalIndex).deref;
    }

    throw new Exception(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression",
    );
}


// The place a `SymOffExp` POINTS AT: `symbol.var`'s own base address plus
// DMD's own already-computed byte offset (`SymOffExp.offset`), at the
// pointee type `SymOffExp.type` itself names a pointer to. This is
// `value.md`'s Layout authority contract for the shape -- a constant-index
// address into a static-array local arrives as a `SymOffExp`, and DMD's
// byte offset applies directly to that local's own cell address rather than
// being re-derived as an element index.
//
// Deliberately not an arm of `placeOfLvalue`: what it returns is one
// dereference removed from the expression it is handed, which is exactly
// what that function's arms must never do (see its own header). Its two
// callers there are the shapes that apply that dereference themselves.
private imported!"quickbite.backends.interpreter.place".Place symOffTarget(
    imported!"dmd.expression".SymOffExp symbol,
    void* delegate(imported!"dmd.declaration".VarDeclaration) @safe resolveBase,
) @safe {
    import quickbite.backends.interpreter.place: Place;

    auto variable = symOffExpDeclaration(symbol).isVarDeclaration;
    if (variable is null)
        throw new Exception(
            "quickbite.backends.interpreter.lvalue_place.symOffTarget: "
            ~ "SymOffExp does not resolve to a variable",
        );

    auto pointer = symOffExpType(symbol).isTypePointer;
    if (pointer is null)
        throw new Exception(
            "quickbite.backends.interpreter.lvalue_place.symOffTarget: "
            ~ "SymOffExp's own type is not a pointer to its pointee",
        );

    return Place(
        symOffAddress(resolveBase(variable), symOffExpOffset(symbol)),
        pointer.next,
    );
}


// `target[i]` where `target` is what a pointer RVALUE points at: the place
// `i` elements past it, at that same element type. `Place.index`'s own
// pointer case cannot serve here -- it reads a stored pointer back out of a
// place's own address, and a pointer rvalue has no address of its own to
// read from -- but the stride is the identical DMD number that case uses,
// `layout.typeByteSize` of the element type, applied through the same
// address arithmetic. No bounds check, matching `Place.index`'s own pointer
// case: a raw pointer's extent is unknown.
private imported!"quickbite.backends.interpreter.place".Place elementOfTarget(
    imported!"quickbite.backends.interpreter.place".Place target,
    in size_t i,
) @safe {
    import quickbite.backends.interpreter.place: Place;
    import quickbite.backends.interpreter.layout: typeByteSize;

    return Place(
        symOffAddress(target.address, i * typeByteSize(target.type)),
        target.type,
    );
}


// `var`'s own `Declaration` -- `VarExp.var` (inherited from `SymbolExp`) is a
// plain field, and `VarExp` is not itself `@safe`-annotated, so this is the
// `@trusted` boundary for reading it.
private imported!"dmd.declaration".Declaration varExpDeclaration(
    imported!"dmd.expression".VarExp var,
) @trusted {
    return var.var;
}


// `dot`'s own field `Declaration` -- `DotVarExp.var` is a plain field, and
// `DotVarExp` is not itself `@safe`-annotated, so this is the `@trusted`
// boundary for reading it.
private imported!"dmd.declaration".Declaration dotVarExpDeclaration(
    imported!"dmd.expression".DotVarExp dot,
) @trusted {
    return dot.var;
}


// `dot`'s receiver expression -- `DotVarExp.e1` (inherited from `UnaExp`) is
// a plain field, and `DotVarExp` is not itself `@safe`-annotated, so this is
// the `@trusted` boundary for reading it.
private imported!"dmd.expression".Expression dotVarExpReceiver(
    imported!"dmd.expression".DotVarExp dot,
) @trusted {
    return dot.e1;
}


// `index`'s base expression -- `IndexExp.e1` (inherited from `BinExp`) is a
// plain field, and `IndexExp` is not itself `@safe`-annotated, so this is the
// `@trusted` boundary for reading it.
private imported!"dmd.expression".Expression indexExpBase(
    imported!"dmd.expression".IndexExp index,
) @trusted {
    return index.e1;
}


// `index`'s own index expression -- `IndexExp.e2` (inherited from `BinExp`)
// is a plain field, and `IndexExp` is not itself `@safe`-annotated, so this
// is the `@trusted` boundary for reading it.
private imported!"dmd.expression".Expression indexExpIndex(
    imported!"dmd.expression".IndexExp index,
) @trusted {
    return index.e2;
}


// `ptr`'s own operand expression -- `PtrExp.e1` (inherited from `UnaExp`) is
// a plain field, and `PtrExp` is not itself `@safe`-annotated, so this is
// the `@trusted` boundary for reading it.
private imported!"dmd.expression".Expression ptrExpBase(
    imported!"dmd.expression".PtrExp ptr,
) @trusted {
    return ptr.e1;
}


// `this_`'s own hidden `this` variable -- `ThisExp.var` is a plain field
// (already `VarDeclaration`-typed, unlike `VarExp.var`'s plain
// `Declaration`, so no further narrowing is needed), and `ThisExp` is not
// itself `@safe`-annotated, so this is the `@trusted` boundary for reading
// it. DMD's own `ThisExp` semantic sets this to the enclosing function's
// `vthis` for every `this` an executable body can reach; it stays `null`
// only for the `typeof(this)` type-context special case, which never
// becomes a runtime `Expression` a caller here would compose a place for.
private imported!"dmd.declaration".VarDeclaration thisExpDeclaration(
    imported!"dmd.expression".ThisExp this_,
) @trusted {
    return this_.var;
}


// `symbol`'s own field `Declaration` -- `SymOffExp.var` (inherited from
// `SymbolExp`) is a plain field, and `SymOffExp` is not itself `@safe`-
// annotated, so this is the `@trusted` boundary for reading it.
private imported!"dmd.declaration".Declaration symOffExpDeclaration(
    imported!"dmd.expression".SymOffExp symbol,
) @trusted {
    return symbol.var;
}


// `symbol`'s own byte offset (`SymOffExp.offset`) -- DMD's own already-
// computed byte offset from `symbol.var`'s storage (see `impl.d`'s
// `symbolOffsetLocalValue`, which applies this exact same number straight
// to a cell's address rather than re-deriving it as an element index).
// Plain field, `@trusted` boundary as above.
//
// Read here rather than through `layout.d` on purpose. That module owns the
// TYPE-derived layout facts -- a type's size and alignment, an aggregate's
// field offsets, a static array's element count -- the numbers the
// interpreter would otherwise be tempted to re-derive with rules of its own,
// and whose reads must force DMD's layout passes first. This is none of
// those: it is a constant already folded into one AST node by the front end,
// with nothing to force and no second derivation possible, the same class of
// read as `impl.d`'s `constantIndex` taking `IntegerExp.getInteger`. It stays
// beside the other `SymOffExp` field accessors it is only ever used with.
private size_t symOffExpOffset(
    imported!"dmd.expression".SymOffExp symbol,
) @trusted {
    return cast(size_t) symbol.offset;
}


// `symbol`'s own static type -- `Expression.type`, a plain field, and
// `Expression` (an `extern (C++)` base class) is not itself `@safe`-
// annotated, so this is the `@trusted` boundary for reading it. A
// `SymOffExp` (an address-of expression DMD folded to a constant offset)
// is always typed as a pointer to its pointee, never the pointee type
// itself.
private imported!"dmd.mtype".Type symOffExpType(
    imported!"dmd.expression".SymOffExp symbol,
) @trusted {
    return symbol.type;
}


// Pointer arithmetic on a raw address is not `@safe`; this is the
// `@trusted` boundary, mirroring `place.d`'s own `placeAdd`. `offset` is
// always either DMD's own `SymOffExp.offset` -- a byte offset into
// `variable`'s own storage that DMD itself already computed -- or a stride
// product over `layout.typeByteSize`, DMD's own element size, so
// `address + offset` stays within whatever allocation `address` was formed
// from on the same terms `placeAdd` already relies on.
private void* symOffAddress(void* address, in size_t offset) pure nothrow @trusted {
    return address + offset;
}

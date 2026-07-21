module quickbite.backends.interpreter.lvalue_place;


private:


// Composes a `Place` for the pure address-composition lvalue shapes: a bare
// variable, a `ThisExp` (the hidden `this` of a method body, resolved to its
// own `vthis` variable exactly like a bare variable -- a struct `this`'s
// place sits directly at the receiver's own storage, a class `this`'s place
// holds a stored reference to it, matching how a struct- or class-typed
// variable already composes below), a chain of field accesses reached
// through `DotVarExp` receivers (a struct receiver's field sits inline at a
// fixed offset from the receiver's own address; a class receiver holds a
// reference, so its field composes through `Place.deref` onto the object
// body first), a `PtrExp` (`*p`) that composes through `Place.deref` onto
// the pointee, a `SymOffExp` (DMD's constant-offset address-of shape, e.g.
// `&local` or `&arr[2]`) that composes DMD's own byte offset directly onto
// the variable's address, landing on the pointee `SymOffExp.type` itself
// names as a pointer to, or an `IndexExp` over a base place that is itself
// one of these shapes. `resolveBase` supplies the base address for a
// variable, and `evalIndex` evaluates an `IndexExp`'s own index
// subexpression to a `size_t` -- the only per-caller policy this function
// needs, so it stays address composition over DMD's own AST and offsets,
// with no evaluation of its own beyond that and no Walker state. `a[i]`
// composes as `placeOfLvalue(a).index(evalIndex(i))`, which `Place.index`
// resolves uniformly for a static-array, pointer, or slice base (following
// the stored pointer for the latter two).
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
        auto base = placeOfLvalue(indexExpBase(index), resolveBase, evalIndex);
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

    if (auto ptr = expr.isPtrExp)
        return placeOfLvalue(ptrExpBase(ptr), resolveBase, evalIndex).deref;

    if (auto symbol = expr.isSymOffExp) {
        auto variable = symOffExpDeclaration(symbol).isVarDeclaration;
        if (variable is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "SymOffExp does not resolve to a variable",
            );

        auto pointer = symOffExpType(symbol).isTypePointer;
        if (pointer is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "SymOffExp's own type is not a pointer to its pointee",
            );

        return Place(
            symOffAddress(resolveBase(variable), symOffExpOffset(symbol)),
            pointer.next,
        );
    }

    throw new Exception(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression",
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
// always DMD's own `SymOffExp.offset` -- a byte offset into `variable`'s
// own storage that DMD itself already computed -- so `address + offset`
// stays within whatever allocation `address` was formed from.
private void* symOffAddress(void* address, in size_t offset) pure nothrow @trusted {
    return address + offset;
}

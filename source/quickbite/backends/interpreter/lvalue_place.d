module quickbite.backends.interpreter.lvalue_place;


private:


// Composes a `Place` for the pure address-composition lvalue shapes: a bare
// variable, or a chain of struct-field accesses reached through `DotVarExp`
// receivers whose own place is struct-typed (inline value storage, so the
// field sits at a fixed offset from the receiver's own address). `resolveBase`
// supplies the base address for a variable -- the only per-caller policy this
// function needs, so it stays pure address arithmetic over DMD's own AST and
// offsets, with no subexpression evaluation and no Walker state.
//
// Every other lvalue shape refuses rather than guesses: a class-typed
// receiver holds a reference, so its field lives behind a pointer that must
// be loaded first; `IndexExp` needs the index evaluated (and, for a pointer
// or slice, a pointer load too); `PtrExp`, `CommaExp`, and anything else fall
// through to the same refusal. Those all arrive with wiring to the expression
// evaluator.
public imported!"quickbite.backends.interpreter.place".Place placeOfLvalue(
    imported!"dmd.expression".Expression expr,
    void* delegate(imported!"dmd.declaration".VarDeclaration) @safe resolveBase,
) @safe {
    import quickbite.backends.interpreter.place: Place;

    if (auto var = expr.isVarExp) {
        auto variable = varExpDeclaration(var).isVarDeclaration;
        if (variable is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "VarExp does not resolve to a variable",
            );

        return Place(resolveBase(variable), variableType(variable));
    }

    if (auto dot = expr.isDotVarExp) {
        auto field = dotVarExpDeclaration(dot).isVarDeclaration;
        if (field is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "DotVarExp does not resolve to a field variable",
            );

        auto receiver = placeOfLvalue(dotVarExpReceiver(dot), resolveBase);
        if (receiver.type.isTypeStruct is null)
            throw new Exception(
                "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
                ~ "DotVarExp receiver is not a struct-typed place",
            );

        return receiver.field(field);
    }

    throw new Exception(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression",
    );
}


// `variable`'s declared type -- a plain field read, but `VarDeclaration` (an
// `extern (C++)` class) is not itself `@safe`-annotated, so this is the
// `@trusted` boundary for reading it, mirroring `frame_layout.variableType`.
private imported!"dmd.mtype".Type variableType(
    imported!"dmd.declaration".VarDeclaration variable,
) @trusted {
    return variable.type;
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

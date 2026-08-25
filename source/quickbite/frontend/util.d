module quickbite.frontend.util;

private:

// The visitor is caller supplied and may throw diagnostics, so this traversal
// cannot promise nothrow.
public void foreachUnitTestDeclaration(
    imported!"dmd.dmodule".Module module_,
    scope void delegate(imported!"dmd.declaration".UnitTestDeclaration) visit,
) @safe {
    if (module_.members is null)
        return;

    foreachUnitTestDeclaration(module_.members, visit);
}

private void foreachUnitTestDeclaration(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    scope void delegate(imported!"dmd.declaration".UnitTestDeclaration) visit,
) @trusted {
    import dmd.dsymbolsem: include;

    if (symbols is null)
        return;

    // By index on purpose: running a unittest from the visit callback can
    // instantiate templates, which DMD appends to this very array (root
    // modules collect speculative instances via importedFrom). A slice would
    // keep pointing at the old buffer after the append reallocates it.
    for (size_t i = 0; i < symbols.length; ++i) {
        auto symbol = (*symbols)[i];
        if (auto unitTest = symbol.isUnitTestDeclaration) {
            visit(unitTest);
            continue;
        }

        if (auto attributes = symbol.isAttribDeclaration)
            foreachUnitTestDeclaration(attributes.include(null), visit);
    }
}

// Visits every `shared static this()`/`static this()` declaration in a
// module, in source order, regardless of nesting under attributes (`static
// if`, `version`, ...) or inside a template instance's members. The visitor
// tells the two kinds apart with `isSharedStaticCtorDeclaration`: DMD's
// `isStaticCtorDeclaration` matches both.
public void foreachStaticCtorDeclaration(
    imported!"dmd.dmodule".Module module_,
    scope void delegate(imported!"dmd.func".StaticCtorDeclaration) visit,
) @safe {
    if (module_.members is null)
        return;

    foreachStaticCtorDeclaration(module_.members, visit);
}

// `Dsymbols*` and `include(null)` are DMD-owned pointers this walk only
// reads.
private void foreachStaticCtorDeclaration(
    imported!"dmd.arraytypes".Dsymbols* symbols,
    scope void delegate(imported!"dmd.func".StaticCtorDeclaration) visit,
) @trusted {
    import dmd.dsymbolsem: include;

    if (symbols is null)
        return;

    // By index, as in `foreachUnitTestDeclaration`. This walk only appends
    // to the caller's array, so it cannot itself trigger the reentrant
    // growth that walk guards against; a ctor compiled after this walk
    // finishes can still instantiate a template whose ctors this walk
    // never saw.
    for (size_t i = 0; i < symbols.length; ++i) {
        auto symbol = (*symbols)[i];
        if (auto ctor = symbol.isStaticCtorDeclaration) {
            visit(ctor);
            continue;
        }

        if (auto attributes = symbol.isAttribDeclaration) {
            foreachStaticCtorDeclaration(attributes.include(null), visit);
            continue;
        }

        // A `shared static this` inside a template (e.g. tardy's `vtable`
        // template) only shows up here: `AttribDeclaration.include` does
        // not reach into instantiated templates.
        if (auto templateInstance = symbol.isTemplateInstance) {
            foreachStaticCtorDeclaration(templateInstance.members, visit);
            continue;
        }

        // A `shared static this`/`static this` declared inside a struct,
        // class, or union counts as the enclosing module's module
        // constructor, not the aggregate's own: DMD collects it into the
        // module's startup sequence, so this walk must recurse into
        // aggregate members to find it.
        if (auto aggregate = symbol.isAggregateDeclaration)
            foreachStaticCtorDeclaration(aggregate.members, visit);
    }
}

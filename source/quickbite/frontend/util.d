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

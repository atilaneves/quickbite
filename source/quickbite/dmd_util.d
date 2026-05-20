module quickbite.dmd_util;

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

    foreach (symbol; (*symbols)[]) {
        if (auto unitTest = symbol.isUnitTestDeclaration) {
            visit(unitTest);
            continue;
        }

        if (auto attributes = symbol.isAttribDeclaration)
            foreachUnitTestDeclaration(attributes.include(null), visit);
    }
}

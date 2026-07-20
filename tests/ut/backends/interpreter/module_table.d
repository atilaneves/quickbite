module ut.backends.interpreter.module_table;


import ut;
import quickbite.frontend.compiler: parseSnippet;
import quickbite.backends.interpreter.module_table: ModuleTable;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.native_scalar: writeScalar, readScalar;
import quickbite.backends.interpreter.layout: typeByteSize;
import quickbite.lang: Value;
import dmd.dmodule: Module;
import dmd.arraytypes: Dsymbols;
import dmd.declaration: VarDeclaration;

private:


VarDeclaration findVar(
    Module module_,
    in string name,
) {
    return module_.members is null
        ? null
        : findVar(module_.members, name);
}

// `extern(C)`/`extern(D)`/etc at module scope wraps the declaration in a
// `LinkDeclaration` (an `AttribDeclaration`), so the `VarDeclaration` is not
// a direct member of the module -- recurse into `AttribDeclaration.decl` to
// find it regardless of how many attribute wrappers surround it.
VarDeclaration findVar(
    Dsymbols* members,
    in string name,
) {
    import dmd.attrib: AttribDeclaration;

    if (members is null)
        return null;

    foreach (member; *members) {
        if (auto variable = member.isVarDeclaration)
            if (variable.ident !is null && variable.ident.toString == name)
                return variable;

        if (auto attrib = member.isAttribDeclaration)
            if (auto found = findVar(attrib.decl, name))
                return found;
    }

    return null;
}

VarDeclaration parseVar(in string source, in string name) {
    auto moduleResult = parseSnippet(source);
    auto variable = findVar(moduleResult.module_, name);
    assert(variable !is null, "variable `" ~ name ~ "` not found in parsed snippet");
    return variable;
}


@("ModuleTable.storageFor.stableAddressAcrossRepeatedCalls")
unittest {
    auto variable = parseVar(
        q{ int quickbiteModuleGlobalStable; },
        "quickbiteModuleGlobalStable",
    );
    ModuleTable table;

    auto first = table.storageFor(variable);
    auto second = table.storageFor(variable);

    second.should == first;
}


@("ModuleTable.storageFor.distinctVariablesGetDistinctBlocks")
unittest {
    auto moduleResult = parseSnippet(q{
        int quickbiteModuleGlobalA;
        long quickbiteModuleGlobalB;
    });
    auto a = findVar(moduleResult.module_, "quickbiteModuleGlobalA");
    auto b = findVar(moduleResult.module_, "quickbiteModuleGlobalB");
    assert(a !is null && b !is null, "both module globals must be found");

    ModuleTable table;

    auto aAddress = table.storageFor(a);
    auto bAddress = table.storageFor(b);

    (aAddress != bAddress).should == true;
}


@("ModuleTable.storageFor.blockByteLengthMatchesTypeByteSize")
unittest {
    auto variable = parseVar(
        q{ long quickbiteModuleGlobalByteLength; },
        "quickbiteModuleGlobalByteLength",
    );
    ModuleTable table;

    table.storageFor(variable);

    table[variable].byteLength.should == typeByteSize(variable.type);
}


@("ModuleTable.storageFor.scalarGlobalGetsNoScanPolicy")
unittest {
    auto variable = parseVar(
        q{ int quickbiteModuleGlobalNoScan; },
        "quickbiteModuleGlobalNoScan",
    );
    ModuleTable table;

    table.storageFor(variable);

    table[variable].scan.should == NativeBlock.Scan.no;
}


@("ModuleTable.storageFor.pointerCarryingGlobalGetsConservativeScanPolicy")
unittest {
    auto variable = parseVar(
        q{ int* quickbiteModuleGlobalPointerScan; },
        "quickbiteModuleGlobalPointerScan",
    );
    ModuleTable table;

    table.storageFor(variable);

    table[variable].scan.should == NativeBlock.Scan.conservative;
}


@("ModuleTable.storageFor.scalarStoreLoadRoundTrips")
unittest {
    auto variable = parseVar(
        q{ int quickbiteModuleGlobalRoundTrip; },
        "quickbiteModuleGlobalRoundTrip",
    );
    ModuleTable table;

    auto address = table.storageFor(variable);
    auto bytes = (cast(ubyte*) address)[0 .. typeByteSize(variable.type)];

    // Runtime-computed, not a bare literal passed straight to `Value`.
    int written = 3;
    written = written * 7 + 1;

    writeScalar(variable.type, bytes, Value(written));

    readScalar(variable.type, bytes).asLong.should == written;
}

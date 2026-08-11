module ut.backends.interpreter.module_table;


import ut;
import ut.backends.interpreter: findVar, parseVar;
import quickbite.frontend.compiler: parseSnippet;
import quickbite.backends.interpreter.module_table: ModuleTable;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.native_scalar: writeScalar, readScalar;
import quickbite.backends.interpreter.layout: typeByteSize;
import quickbite.backends.interpreter.expression_result: ExpressionResult;

private:


@("ModuleTable.has.falseUntilFirstStorageForCall")
unittest {
    auto variable = parseVar(
        q{ int quickbiteModuleGlobalLazy; },
        "quickbiteModuleGlobalLazy",
    );
    ModuleTable table;

    table.has(variable).should == false;

    table.storageFor(variable);

    table.has(variable).should == true;
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

    // Runtime-computed, not a bare literal passed straight to `ExpressionResult`.
    int written = 3;
    written = written * 7 + 1;

    writeScalar(variable.type, bytes, ExpressionResult(written));

    readScalar(variable.type, bytes).asLong.should == written;
}

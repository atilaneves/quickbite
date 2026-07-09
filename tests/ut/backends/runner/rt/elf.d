module ut.backends.runner.rt.elf;


import orc.elf:
    localizeUnwindCellReferences,
    normalizeDuplicateUndefinedGlobals;
import ut;


@("elf.duplicateUndefinedGlobalRelocationsUseFirstSymbol")
unittest {
    auto object = duplicateUndefinedGlobalObject;

    normalizeDuplicateUndefinedGlobals(object).should == true;

    relocationSymbolIndex(object, 0).should == 1;
    relocationType(object, 0).should == 42;
    relocationSymbolIndex(object, 1).should == 3;
}

@("elf.uniqueUndefinedGlobalsAreUnchanged")
unittest {
    auto object = uniqueUndefinedGlobalObject;
    const original = object.dup;

    normalizeDuplicateUndefinedGlobals(object).should == false;

    object.should == original;
}

/++
    dmd gives every object its own `WEAK HIDDEN` `DW.ref.__dmd_personality_v0`
    and points `.eh_frame` at it with a PC-relative 32-bit fixup. JITLink admits
    the first object's copy into the JITDylib and externalizes every later
    object's duplicate, so a later graph's fixup reaches into the first graph's
    slab; more than 2 GiB apart, the Delta32 fixup is out of range. Every copy
    of the cell holds the same thing, so the relocation must name the defining
    section's own local `SECTION` symbol — same value, reachable address — with
    the addend carrying what the symbol's value used to contribute.
 +/
@("elf.unwindCellRelocationsUseSectionSymbol")
unittest {
    auto object = hiddenDwRefObject;

    localizeUnwindCellReferences(object).should == true;

    dwRefRelocationSymbolIndex(object, 0).should == dwRefSectionSymbolIndex;
    dwRefRelocationAddend(object, 0).should == 5 + dwRefSymbolValue;
    // Repointing must not disturb the fixup itself: a relocation whose type
    // became R_X86_64_NONE is one .eh_frame silently never patched.
    dwRefRelocationType(object, 0).should == rX8664Pc32;

    // An undefined global in the same object is nobody's self-reference.
    dwRefRelocationSymbolIndex(object, 1).should == dwRefUndefinedSymbolIndex;
    dwRefRelocationAddend(object, 1).should == 7;

    // A defined symbol that is not an unwind cell keeps its own symbol, hidden
    // or not: hidden COMDAT template bodies are deduplicated across objects on
    // purpose, and unlike the cells their copies are not interchangeable.
    dwRefRelocationSymbolIndex(object, 2).should == dwRefComdatSymbolIndex;
    dwRefRelocationAddend(object, 2).should == 3;
}

// Deliberately none of these equals dwRefDataSectionIndex: an assertion that a
// relocation still names the comdat symbol must not pass for an implementation
// that wrongly named the defining section's index instead of its symbol's.
private enum dwRefSectionSymbolIndex = 1;
private enum dwRefComdatSymbolIndex = 2;
private enum dwRefCellSymbolIndex = 3;
private enum dwRefUndefinedSymbolIndex = 5;
private enum dwRefSymbolValue = 8;
private enum dwRefComdatSymbolValue = 16;

private enum dwRefSectionCount = 5;
private enum dwRefStrtabOffset =
    elfHeaderSize + dwRefSectionCount * sectionHeaderSize;
private enum dwRefStrtab = "\0DW.ref.__dmd_personality_v0\0other\0comdat\0";
private enum dwRefStrtabSize = dwRefStrtab.length;
private enum dwRefOtherNameOffset = 29;
private enum dwRefComdatNameOffset = 35;
private enum dwRefSymtabOffset = dwRefStrtabOffset + dwRefStrtabSize;
// Entry 4 is left zeroed: an unused, undefined symbol the transform must skip.
private enum dwRefSymtabEntryCount = 6;
private enum dwRefSymtabSize = symtabEntrySize * dwRefSymtabEntryCount;
private enum dwRefRelaOffset = dwRefSymtabOffset + dwRefSymtabSize;
private enum dwRefRelaEntryCount = 3;
private enum dwRefObjectSize =
    dwRefRelaOffset + relaEntrySize * dwRefRelaEntryCount;

private enum dwRefDataSectionIndex = 4;
private enum stbLocal = 0;
private enum stbGlobal = 1;
private enum stbWeak = 2;
private enum sttObject = 1;
private enum sttSection = 3;
private enum stvHidden = 2;
private enum rX8664Pc32 = 2;

private ubyte[] hiddenDwRefObject() {
    auto object = new ubyte[](dwRefObjectSize);
    object[0 .. 4] = [0x7f, 'E', 'L', 'F'];
    object[4] = 2; // ELF64
    object[5] = 1; // little-endian
    write16(object, 16, 1); // ET_REL
    write64(object, 40, sectionTableOffset);
    write16(object, 58, sectionHeaderSize);
    write16(object, 60, dwRefSectionCount);

    object[dwRefStrtabOffset .. dwRefStrtabOffset + dwRefStrtabSize] =
        cast(ubyte[]) dwRefStrtab.dup;

    writeSection(object, 1, 3, dwRefStrtabOffset, dwRefStrtabSize, 0, 0);
    writeSection(
        object,
        2,
        2,
        dwRefSymtabOffset,
        dwRefSymtabSize,
        1,
        symtabEntrySize,
    );
    writeSection(
        object,
        3,
        4,
        dwRefRelaOffset,
        relaEntrySize * dwRefRelaEntryCount,
        2,
        relaEntrySize,
    );
    writeSection(object, dwRefDataSectionIndex, 1, 0, 0, 0, 0);

    // The local SECTION symbol for .data.DW.ref.__dmd_personality_v0.
    writeDwRefSymbol(
        object,
        dwRefSectionSymbolIndex,
        0,
        symbolInfo(stbLocal, sttSection),
        0,
        dwRefDataSectionIndex,
        0,
    );
    // "comdat": defined and hidden, but not an unwind cell — a stand-in for a
    // hidden COMDAT template body, which must keep its own symbol.
    writeDwRefSymbol(
        object,
        dwRefComdatSymbolIndex,
        dwRefComdatNameOffset,
        symbolInfo(stbWeak, sttObject),
        stvHidden,
        dwRefDataSectionIndex,
        dwRefComdatSymbolValue,
    );
    // DW.ref.__dmd_personality_v0 itself: weak, hidden, defined, at value 8.
    writeDwRefSymbol(
        object,
        dwRefCellSymbolIndex,
        1,
        symbolInfo(stbWeak, sttObject),
        stvHidden,
        dwRefDataSectionIndex,
        dwRefSymbolValue,
    );
    // "other": an undefined global, untouched by the transform.
    writeDwRefSymbol(
        object,
        dwRefUndefinedSymbolIndex,
        dwRefOtherNameOffset,
        symbolInfo(stbGlobal, 0),
        0,
        0,
        0,
    );

    writeDwRefRelocation(object, 0, dwRefCellSymbolIndex, rX8664Pc32, 5);
    writeDwRefRelocation(object, 1, dwRefUndefinedSymbolIndex, rX8664Pc32, 7);
    writeDwRefRelocation(object, 2, dwRefComdatSymbolIndex, rX8664Pc32, 3);
    return object;
}

private void writeDwRefSymbol(
    ubyte[] object,
    in uint index,
    in uint name,
    in ubyte info,
    in ubyte other,
    in ushort sectionIndex,
    in ulong value,
) {
    const offset = dwRefSymtabOffset + index * symtabEntrySize;
    write32(object, offset, name);
    object[offset + 4] = info;
    object[offset + 5] = other;
    write16(object, offset + 6, sectionIndex);
    write64(object, offset + 8, value);
}

private void writeDwRefRelocation(
    ubyte[] object,
    in uint index,
    in uint symbolIndex,
    in uint type,
    in long addend,
) {
    const offset = dwRefRelaOffset + index * relaEntrySize;
    write64(object, offset + 8, (cast(ulong) symbolIndex << 32) | type);
    write64(object, offset + 16, cast(ulong) addend);
}

private uint dwRefRelocationSymbolIndex(in ubyte[] object, in uint index) {
    return cast(uint) (
        read64(object, dwRefRelaOffset + index * relaEntrySize + 8) >> 32
    );
}

private uint dwRefRelocationType(in ubyte[] object, in uint index) {
    return cast(uint) read64(
        object,
        dwRefRelaOffset + index * relaEntrySize + 8,
    );
}

private long dwRefRelocationAddend(in ubyte[] object, in uint index) {
    return cast(long) read64(
        object,
        dwRefRelaOffset + index * relaEntrySize + 16,
    );
}

private enum elfHeaderSize = 64;
private enum sectionHeaderSize = 64;
private enum sectionCount = 4;
private enum sectionTableOffset = elfHeaderSize;
private enum strtabOffset =
    sectionTableOffset + sectionCount * sectionHeaderSize;
private enum strtabSize = 11;
private enum symtabOffset = strtabOffset + strtabSize;
private enum symtabEntrySize = 24;
private enum symtabEntryCount = 4;
private enum symtabSize = symtabEntrySize * symtabEntryCount;
private enum relaOffset = symtabOffset + symtabSize;
private enum relaEntrySize = 24;
private enum relaEntryCount = 2;
private enum objectSize = relaOffset + relaEntrySize * relaEntryCount;

private ubyte[] duplicateUndefinedGlobalObject() {
    auto object = emptyObject;
    writeSymbol(object, 1, 1, symbolInfo(1, 0), 0);
    writeSymbol(object, 2, 1, symbolInfo(1, 0), 0);
    writeSymbol(object, 3, 5, symbolInfo(1, 0), 0);
    writeRelocation(object, 0, 2, 42);
    writeRelocation(object, 1, 3, 17);
    return object;
}

private ubyte[] uniqueUndefinedGlobalObject() {
    auto object = emptyObject;
    writeSymbol(object, 1, 1, symbolInfo(1, 0), 0);
    writeSymbol(object, 2, 5, symbolInfo(1, 0), 0);
    writeRelocation(object, 0, 1, 42);
    writeRelocation(object, 1, 2, 17);
    return object;
}

private ubyte[] emptyObject() {
    auto object = new ubyte[](objectSize);
    object[0 .. 4] = [0x7f, 'E', 'L', 'F'];
    object[4] = 2; // ELF64
    object[5] = 1; // little-endian
    write16(object, 16, 1); // ET_REL
    write64(object, 40, sectionTableOffset);
    write16(object, 58, sectionHeaderSize);
    write16(object, 60, sectionCount);

    object[strtabOffset .. strtabOffset + strtabSize] =
        cast(ubyte[]) "\0dup\0other\0";

    writeSection(object, 1, 3, strtabOffset, strtabSize, 0, 0);
    writeSection(object, 2, 2, symtabOffset, symtabSize, 1, symtabEntrySize);
    writeSection(
        object,
        3,
        4,
        relaOffset,
        relaEntrySize * relaEntryCount,
        2,
        relaEntrySize,
    );
    return object;
}

private void writeSection(
    ubyte[] object,
    in uint index,
    in uint type,
    in ulong offset,
    in ulong size,
    in uint link,
    in ulong entrySize,
) {
    const sectionOffset = sectionTableOffset + index * sectionHeaderSize;
    write32(object, sectionOffset + 4, type);
    write64(object, sectionOffset + 24, offset);
    write64(object, sectionOffset + 32, size);
    write32(object, sectionOffset + 40, link);
    write64(object, sectionOffset + 56, entrySize);
}

private void writeSymbol(
    ubyte[] object,
    in uint index,
    in uint name,
    in ubyte info,
    in ushort sectionIndex,
) {
    const offset = symtabOffset + index * symtabEntrySize;
    write32(object, offset, name);
    object[offset + 4] = info;
    write16(object, offset + 6, sectionIndex);
}

private void writeRelocation(
    ubyte[] object,
    in uint index,
    in uint symbolIndex,
    in uint type,
) {
    const offset = relaOffset + index * relaEntrySize;
    write64(object, offset + 8, (cast(ulong) symbolIndex << 32) | type);
}

private uint relocationSymbolIndex(in ubyte[] object, in uint index) {
    return cast(uint) (
        read64(object, relaOffset + index * relaEntrySize + 8) >> 32
    );
}

private uint relocationType(in ubyte[] object, in uint index) {
    return cast(uint) read64(object, relaOffset + index * relaEntrySize + 8);
}

private ubyte symbolInfo(in ubyte binding, in ubyte type)
        @safe @nogc nothrow pure {
    return cast(ubyte)((binding << 4) | type);
}

private void write16(ubyte[] bytes, in size_t offset, in ushort value) {
    writeUnsigned(bytes, offset, value);
}

private void write32(ubyte[] bytes, in size_t offset, in uint value) {
    writeUnsigned(bytes, offset, value);
}

private void write64(ubyte[] bytes, in size_t offset, in ulong value) {
    writeUnsigned(bytes, offset, value);
}

private void writeUnsigned(T)(ubyte[] bytes, in size_t offset, in T value) {
    foreach (i; 0 .. T.sizeof)
        bytes[offset + i] = cast(ubyte)(value >> (i * 8));
}

private ulong read64(in ubyte[] bytes, in size_t offset)
        @safe @nogc nothrow pure {
    ulong value;
    foreach (i; 0 .. ulong.sizeof)
        value |= cast(ulong) bytes[offset + i] << (i * 8);
    return value;
}

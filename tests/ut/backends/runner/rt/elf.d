module ut.backends.runner.rt.elf;


import quickbite.backends.native.elf: normalizeDuplicateUndefinedGlobals;
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

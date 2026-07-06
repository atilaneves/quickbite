module orc.elf;


private:


public bool normalizeDuplicateUndefinedGlobals(ubyte[] objectBytes) {
    auto elf = Elf64(objectBytes);
    const symtabIndex = elf.singleSectionOfType(SectionType.symtab);
    const symtab = elf.section(symtabIndex);
    const stringTable = elf.sectionBytes(symtab.link);
    const symbols = elf.symbols(symtab);

    uint[uint] duplicateToCanonical;
    uint[string] canonicalByName;
    foreach (index, symbol; symbols) {
        if (symbol.sectionIndex != SectionIndex.undefined)
            continue;
        if (symbol.binding != SymbolBinding.global)
            continue;

        const name = symbolName(stringTable, symbol.name);
        if (name.length == 0)
            continue;
        if (auto canonical = name in canonicalByName)
            duplicateToCanonical[cast(uint) index] = *canonical;
        else
            canonicalByName[name] = cast(uint) index;
    }

    if (duplicateToCanonical.length == 0)
        return false;

    bool changed;
    foreach (section; elf.sections) {
        if (section.type != SectionType.rela || section.link != symtabIndex)
            continue;
        foreach (offset; elf.relocationInfoOffsets(section)) {
            const info = elf.readU64(offset);
            const symbolIndex = cast(uint)(info >> 32);
            if (auto canonical = symbolIndex in duplicateToCanonical) {
                elf.writeU64(
                    offset,
                    (cast(ulong) *canonical << 32) | (info & uint.max),
                );
                changed = true;
            }
        }
    }

    return changed;
}

public bool normalizeDuplicateUndefinedGlobalsInFile(in string path) {
    import std.file: read, write;

    auto objectBytes = cast(ubyte[]) read(path);
    if (!normalizeDuplicateUndefinedGlobals(objectBytes))
        return false;
    write(path, objectBytes);
    return true;
}

private enum SectionType: uint {
    symtab = 2,
    rela = 4,
}

private enum SectionIndex: ushort {
    undefined = 0,
}

private enum SymbolBinding: ubyte {
    local = 0,
    global = 1,
    weak = 2,
}

private struct SectionHeader {
    SectionType type;
    ulong offset;
    ulong size;
    uint link;
    ulong entrySize;
}

private struct Symbol {
    uint name;
    ubyte info;
    SectionIndex sectionIndex;

    @property SymbolBinding binding() const @safe @nogc nothrow pure {
        return cast(SymbolBinding)(info >> 4);
    }
}

private struct Elf64 {
    private ubyte[] _bytes;

    this(ubyte[] bytes) @safe {
        _bytes = bytes;
        validateHeader;
    }

    SectionHeader section(uint index) const @safe {
        const offset = sectionHeaderOffset(index);
        return SectionHeader(
            cast(SectionType) readU32(offset + 4),
            readU64(offset + 24),
            readU64(offset + 32),
            readU32(offset + 40),
            readU64(offset + 56),
        );
    }

    SectionHeader[] sections() const @safe {
        SectionHeader[] values;
        foreach (index; 0 .. sectionCount)
            values ~= section(cast(uint) index);
        return values;
    }

    uint singleSectionOfType(in SectionType type) const @safe {
        uint found = uint.max;
        foreach (index, section; sections) {
            if (section.type != type)
                continue;
            if (found != uint.max)
                throw new Exception(
                    "ELF object has multiple SHT_SYMTAB sections",
                );
            found = cast(uint) index;
        }
        if (found == uint.max)
            throw new Exception("ELF object has no SHT_SYMTAB section");
        return found;
    }

    ubyte[] sectionBytes(in uint index) @safe {
        return bytesFor(section(index));
    }

    Symbol[] symbols(in SectionHeader symtab) const @safe {
        if (symtab.entrySize != 24)
            throw new Exception(
                "ELF SHT_SYMTAB uses an unsupported entry size",
            );
        Symbol[] values;
        foreach (offset; entryOffsets(symtab)) {
            values ~= Symbol(
                readU32(offset),
                readU8(offset + 4),
                cast(SectionIndex) readU16(offset + 6),
            );
        }
        return values;
    }

    size_t[] relocationInfoOffsets(in SectionHeader rela) const @safe {
        if (rela.entrySize != 24)
            throw new Exception("ELF SHT_RELA uses an unsupported entry size");
        size_t[] offsets;
        foreach (offset; entryOffsets(rela))
            offsets ~= offset + 8;
        return offsets;
    }

    ulong readU64(in size_t offset) const @safe @nogc nothrow pure {
        return readUnsigned!ulong(_bytes, offset);
    }

    void writeU64(in size_t offset, in ulong value) @safe @nogc nothrow pure {
        foreach (i; 0 .. ulong.sizeof)
            _bytes[offset + i] = cast(ubyte)(value >> (i * 8));
    }

    private void validateHeader() const @safe {
        if (_bytes.length < 64)
            throw new Exception("ELF object is too small");
        if (_bytes[0 .. 4] != [0x7f, 'E', 'L', 'F'])
            throw new Exception("object is not an ELF file");
        if (_bytes[4] != 2)
            throw new Exception("ELF object is not ELF64");
        if (_bytes[5] != 1)
            throw new Exception("ELF object is not little-endian");
        if (readU16(16) != 1)
            throw new Exception("ELF object is not relocatable");
        if (sectionHeaderSize != 64)
            throw new Exception("ELF section headers use an unsupported size");
    }

    private ubyte[] bytesFor(in SectionHeader section) @safe {
        const offset = toSize(section.offset);
        const size = toSize(section.size);
        requireRange(offset, size);
        return _bytes[offset .. offset + size];
    }

    private size_t[] entryOffsets(in SectionHeader section) const @safe {
        if (section.entrySize == 0)
            throw new Exception("ELF section has zero-sized entries");
        if (section.size % section.entrySize != 0)
            throw new Exception(
                "ELF section size is not a multiple of its entry size",
            );
        const first = toSize(section.offset);
        const entrySize = toSize(section.entrySize);
        const count = toSize(section.size / section.entrySize);
        requireRange(first, toSize(section.size));

        size_t[] offsets;
        foreach (index; 0 .. count)
            offsets ~= first + index * entrySize;
        return offsets;
    }

    private size_t sectionHeaderOffset(in uint index) const @safe {
        if (index >= sectionCount)
            throw new Exception("ELF section index is out of range");
        const offset = toSize(sectionHeaderOffsetValue);
        const size = toSize(sectionHeaderSize);
        const headerOffset = offset + index * size;
        requireRange(headerOffset, size);
        return headerOffset;
    }

    private ushort sectionCount() const @safe @nogc nothrow pure {
        return readU16(60);
    }

    private ushort sectionHeaderSize() const @safe @nogc nothrow pure {
        return readU16(58);
    }

    private ulong sectionHeaderOffsetValue() const @safe @nogc nothrow pure {
        return readU64(40);
    }

    private ubyte readU8(in size_t offset) const @safe @nogc nothrow pure {
        return _bytes[offset];
    }

    private ushort readU16(in size_t offset) const @safe @nogc nothrow pure {
        return readUnsigned!ushort(_bytes, offset);
    }

    private uint readU32(in size_t offset) const @safe @nogc nothrow pure {
        return readUnsigned!uint(_bytes, offset);
    }

    private void requireRange(in size_t offset, in size_t size) const @safe {
        if (offset > _bytes.length || size > _bytes.length - offset)
            throw new Exception("ELF section range is outside the object");
    }
}

private T readUnsigned(T)(in ubyte[] bytes, in size_t offset)
        @safe @nogc nothrow pure {
    T value;
    foreach (i; 0 .. T.sizeof)
        value |= cast(T) bytes[offset + i] << (i * 8);
    return value;
}

private size_t toSize(in ulong value) @safe {
    import std.conv: text;

    if (value > size_t.max)
        throw new Exception(text("ELF value does not fit size_t: ", value));
    return cast(size_t) value;
}

private string symbolName(in ubyte[] stringTable, in uint offset) @safe {
    import std.conv: text;

    if (offset >= stringTable.length)
        throw new Exception(text(
            "ELF symbol name offset is out of range: ",
            offset,
        ));

    size_t end = offset;
    while (end < stringTable.length && stringTable[end] != 0)
        ++end;
    if (end == stringTable.length)
        throw new Exception("ELF symbol name is not nul-terminated");

    char[] chars;
    foreach (value; stringTable[offset .. end])
        chars ~= cast(char) value;
    return chars.idup;
}

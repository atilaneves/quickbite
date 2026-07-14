module orc.elf;


private:


public bool normalizeDuplicateUndefinedGlobals(ubyte[] objectBytes) {
    auto elf = Elf64(objectBytes);
    const symtabIndex = elf.singleSectionOfType(SectionType.symtab);
    const symtab = elf.section(symtabIndex);
    const stringTable = elf.sectionBytes(symtab.link);
    const symbols = elf.symbols(symtab);

    uint[string] firstGlobalByName;
    uint[string] firstWeakByName;
    foreach (index, symbol; symbols) {
        if (symbol.sectionIndex != SectionIndex.undefined)
            continue;
        if (symbol.binding != SymbolBinding.global
                && symbol.binding != SymbolBinding.weak)
            continue;

        const name = symbolName(stringTable, symbol.name);
        if (name.length == 0)
            continue;
        if (symbol.binding == SymbolBinding.global) {
            if (name !in firstGlobalByName)
                firstGlobalByName[name] = cast(uint) index;
        } else if (name !in firstWeakByName)
            firstWeakByName[name] = cast(uint) index;
    }

    uint[uint] duplicateToCanonical;
    foreach (index, symbol; symbols) {
        if (symbol.sectionIndex != SectionIndex.undefined)
            continue;
        if (symbol.binding != SymbolBinding.global
                && symbol.binding != SymbolBinding.weak)
            continue;

        const name = symbolName(stringTable, symbol.name);
        if (name.length == 0)
            continue;
        const canonical = name in firstGlobalByName;
        const canonicalIndex = canonical is null
            ? *(name in firstWeakByName)
            : *canonical;
        if (index != canonicalIndex)
            duplicateToCanonical[cast(uint) index] = canonicalIndex;
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

// ORC's process-symbol generator represents a dlsym result as an absolute
// address. That is valid for ordinary data, but not for STT_TLS: dlsym returns
// one thread's instance, whereas the TLSGD relocation names a TLS module and
// offset. The LLVMJit child only executes on that same thread, so replace the
// dmd TLSGD sequence with the resolved instance address before JITLink sees
// it. This is the object-file counterpart of dmd_codegen.d's RAM TLSGD
// rewrite; movabs is used here because a JIT allocation need not be within
// RIP-relative range of the dependency image.
public bool rewriteTlsGdRelocations(
    ubyte[] objectBytes,
    in ulong[string] tlsAddresses,
) @safe {
    auto elf = Elf64(objectBytes);
    const symtabIndex = elf.singleSectionOfType(SectionType.symtab);
    const symtab = elf.section(symtabIndex);
    const stringTable = elf.sectionBytes(symtab.link);
    const symbols = elf.symbols(symtab);

    bool changed;
    foreach (rela; elf.sections) {
        if (rela.type != SectionType.rela || rela.link != symtabIndex)
            continue;

        bool[ulong] tlsGdCallOffsets;
        foreach (entryOffset; elf.entryOffsets(rela)) {
            const info = elf.readU64(entryOffset + 8);
            if (cast(uint) info != X86_64Relocation.tlsGd)
                continue;

            const symbolIndex = cast(uint) (info >> 32);
            if (symbolIndex >= symbols.length)
                throw new Exception("ELF TLSGD relocation has an invalid symbol index");
            const address = symbolName(stringTable, symbols[symbolIndex].name)
                in tlsAddresses;
            if (address is null)
                continue;

            auto target = elf.sectionBytes(rela.info);
            auto relocationOffset = elf.readU64(entryOffset);
            if (relocationOffset < 4 || relocationOffset + 12 > target.length)
                throw new Exception("ELF TLSGD relocation is outside its target section");
            const instructionOffset = cast(size_t) relocationOffset - 4;
            if (target[instructionOffset] != 0x66
                || target[instructionOffset + 1] != 0x48
                || target[instructionOffset + 2] != 0x8d
                || target[instructionOffset + 3] != 0x3d
                || target[instructionOffset + 8] != 0x66
                || target[instructionOffset + 9] != 0x66
                || target[instructionOffset + 10] != 0x48
                || target[instructionOffset + 11] != 0xe8)
                throw new Exception("ELF TLSGD relocation has an unsupported instruction sequence");

            target[instructionOffset] = 0x48; // movabs rax, imm64
            target[instructionOffset + 1] = 0xb8;
            elf.writeU64In(target, instructionOffset + 2, *address);
            foreach (offset; instructionOffset + 10 .. instructionOffset + 16)
                target[offset] = 0x90;
            elf.writeU64(entryOffset + 8, info & ~cast(ulong) uint.max);
            tlsGdCallOffsets[relocationOffset + 8] = true;
            changed = true;
        }

        foreach (entryOffset; elf.entryOffsets(rela)) {
            // Not `const`: associative-array `in` takes its key as an lvalue.
            auto relocationOffset = elf.readU64(entryOffset);
            if (relocationOffset !in tlsGdCallOffsets)
                continue;
            const info = elf.readU64(entryOffset + 8);
            const type = cast(uint) info;
            if (type != X86_64Relocation.pc32 && type != X86_64Relocation.plt32)
                throw new Exception("ELF TLSGD call has an unsupported relocation type");
            elf.writeU64(entryOffset + 8, info & ~cast(ulong) uint.max);
        }
    }

    return changed;
}

// The TLSGD relocations, rather than every STT_TLS definition, are the ones
// that need a per-thread address substituted before ORC links the object.
public string[] tlsGdSymbolNames(ubyte[] objectBytes) @safe {
    auto elf = Elf64(objectBytes);
    const symtabIndex = elf.singleSectionOfType(SectionType.symtab);
    const symtab = elf.section(symtabIndex);
    const stringTable = elf.sectionBytes(symtab.link);
    const symbols = elf.symbols(symtab);

    bool[string] seen;
    string[] names;
    foreach (rela; elf.sections) {
        if (rela.type != SectionType.rela || rela.link != symtabIndex)
            continue;
        foreach (entryOffset; elf.entryOffsets(rela)) {
            const info = elf.readU64(entryOffset + 8);
            if (cast(uint) info != X86_64Relocation.tlsGd)
                continue;
            const symbolIndex = cast(uint) (info >> 32);
            if (symbolIndex >= symbols.length)
                throw new Exception("ELF TLSGD relocation has an invalid symbol index");
            const name = symbolName(stringTable, symbols[symbolIndex].name);
            if (name.length == 0 || name in seen)
                continue;
            seen[name] = true;
            names ~= name;
        }
    }

    return names;
}

// TLS symbols must never become ORC absolute symbols: dlsym reports a
// thread's instance address, not the module-and-offset definition JITLink
// needs for a TLS relocation.
public string[] tlsSymbolNames(ubyte[] objectBytes) @safe {
    auto elf = Elf64(objectBytes);
    const symtabIndex = elf.singleSectionOfType(SectionType.symtab);
    const symtab = elf.section(symtabIndex);
    const stringTable = elf.sectionBytes(symtab.link);

    bool[string] seen;
    string[] names;
    foreach (symbol; elf.symbols(symtab)) {
        if (symbol.type != SymbolType.tls)
            continue;
        const name = symbolName(stringTable, symbol.name);
        if (name.length == 0 || name in seen)
            continue;
        seen[name] = true;
        names ~= name;
    }

    return names;
}

// dmd gives every object its own `DW.ref.*` unwind indirection cell as a weak,
// hidden object, and references it from `.eh_frame` with a PC-relative 32-bit
// fixup. JITLink admits the first object's copy into the JITDylib and
// externalizes every later object's duplicate weak definition, so a later
// graph's fixup targets the first graph's slab; when the two slabs land more
// than 2 GiB apart the Delta32 fixup is out of range and the object is
// rejected. Resolving object B's reference to object A's hidden weak definition
// is legal ELF — `STV_HIDDEN` bounds visibility at the linked component, not
// at the object — which is why the same dedup is right for hidden COMDAT
// template bodies. What makes it wrong here is only the distance: `ld` resolves
// it inside one image, JITLink across two mmap'd slabs. Repointing each
// reference at the defining section's local SECTION symbol is safe because
// every object's cell is content-identical (one 64-bit relocation to the same
// personality symbol), so the local copy holds the same value at a reachable
// address. The symbol's value moves into the addend, since the addend now
// measures from the section start rather than from the symbol.
public bool localizeUnwindCellReferences(ubyte[] objectBytes) @safe {
    auto elf = Elf64(objectBytes);
    const symtabIndex = elf.singleSectionOfType(SectionType.symtab);
    const symtab = elf.section(symtabIndex);
    const stringTable = elf.sectionBytes(symtab.link);
    const symbols = elf.symbols(symtab);

    uint[uint] sectionSymbolFor;
    foreach (index, symbol; symbols)
        if (symbol.type == SymbolType.section)
            sectionSymbolFor[symbol.sectionIndex] = cast(uint) index;

    // What a relocation naming this symbol must say instead: the local SECTION
    // symbol, and the value the symbol used to contribute to the addend.
    static struct Localized {
        uint sectionSymbol;
        ulong value;
    }

    // The name settles it: dmd emits these cells hidden, but a non-hidden one
    // would be externalized across graphs just the same, and repointing is
    // address-preserving either way, so visibility is not worth a branch.
    Localized[uint] localizedFor;
    foreach (index, symbol; symbols) {
        if (symbol.sectionIndex == SectionIndex.undefined)
            continue;
        if (!isUnwindIndirectionCell(symbolName(stringTable, symbol.name)))
            continue;
        if (auto sectionSymbol = symbol.sectionIndex in sectionSymbolFor)
            localizedFor[cast(uint) index] = Localized(
                *sectionSymbol,
                symbol.value,
            );
    }

    if (localizedFor.length == 0)
        return false;

    bool changed;
    foreach (section; elf.sections) {
        if (section.type != SectionType.rela || section.link != symtabIndex)
            continue;
        foreach (offset; elf.relocationInfoOffsets(section)) {
            const info = elf.readU64(offset);
            // Not `const`: an associative-array `in` takes its key as an
            // lvalue, and a const key there is deprecated on the way to
            // becoming `@system`, which this function is not.
            auto symbolIndex = cast(uint)(info >> 32);
            const localized = symbolIndex in localizedFor;
            if (localized is null)
                continue;
            // The relocation type lives in the low half of r_info and must
            // survive: a zeroed type is R_X86_64_NONE, i.e. a fixup silently
            // never applied.
            elf.writeU64(
                offset,
                (cast(ulong) localized.sectionSymbol << 32)
                    | (info & uint.max),
            );
            const addendOffset = offset + 8;
            elf.writeU64(
                addendOffset,
                elf.readU64(addendOffset) + localized.value,
            );
            changed = true;
        }
    }

    return changed;
}

// The only definitions dmd both emits per-object and references PC-relatively.
// Widening this to every hidden symbol would suppress the legitimate
// cross-object dedup of hidden COMDAT template bodies, whose copies are not
// interchangeable the way these content-identical cells are.
private bool isUnwindIndirectionCell(in string name) @safe @nogc nothrow pure {
    enum prefix = "DW.ref.";
    return name.length > prefix.length && name[0 .. prefix.length] == prefix;
}

// Every rewrite the object needs before JITLink sees it, because JITLink is
// strict where `ld` is lenient.
public bool normalizeObjectFile(in string path) {
    import std.file: read, write;

    auto objectBytes = cast(ubyte[]) read(path);
    const duplicatesCoalesced = normalizeDuplicateUndefinedGlobals(objectBytes);
    const cellsLocalized = localizeUnwindCellReferences(objectBytes);
    if (!duplicatesCoalesced && !cellsLocalized)
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

private enum SymbolType: ubyte {
    section = 3,
    tls = 6,
}

private enum X86_64Relocation: uint {
    none = 0,
    pc32 = 2,
    plt32 = 4,
    tlsGd = 19,
}

private struct SectionHeader {
    SectionType type;
    ulong offset;
    ulong size;
    uint link;
    uint info;
    ulong entrySize;
}

private struct Symbol {
    uint name;
    ubyte info;
    SectionIndex sectionIndex;
    ulong value;

    @property SymbolBinding binding() const @safe @nogc nothrow pure {
        return cast(SymbolBinding)(info >> 4);
    }

    @property SymbolType type() const @safe @nogc nothrow pure {
        return cast(SymbolType)(info & 0xf);
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
            readU32(offset + 44),
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
                    "ELF object has multiple " ~ sectionTypeName(type)
                        ~ " sections",
                );
            found = cast(uint) index;
        }
        if (found == uint.max)
            throw new Exception(
                "ELF object has no " ~ sectionTypeName(type) ~ " section",
            );
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
                readU64(offset + 8),
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

    void writeU64In(
        ubyte[] bytes,
        in size_t offset,
        in ulong value,
    ) @safe @nogc nothrow pure {
        foreach (i; 0 .. ulong.sizeof)
            bytes[offset + i] = cast(ubyte)(value >> (i * 8));
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

    size_t[] entryOffsets(in SectionHeader section) const @safe {
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

private string sectionTypeName(in SectionType type) @safe @nogc nothrow pure {
    final switch (type) with (SectionType) {
    case symtab:
        return "SHT_SYMTAB";
    case rela:
        return "SHT_RELA";
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

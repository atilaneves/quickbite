module quickbite.ffi.symbol;

private:


public enum CompilerAbi {
    dmd,
    ldc,
}

public struct DependencyImage {
    public string path;
    public CompilerAbi compilerAbi;
}

public struct ResolvedSymbol {
    public void* address;
    public CompilerAbi compilerAbi;
}

version (LDC)
    private enum CompilerAbi hostCompilerAbi = CompilerAbi.ldc;
else
    private enum CompilerAbi hostCompilerAbi = CompilerAbi.dmd;

private CompilerAbi[string] _dependencyImageAbis;


public void loadDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages) {
        verifyDependencyImage(dependencyImage);
        loadDependencyImage(
            dependencyImage,
            compilerAbiFromImage(dependencyImage),
        );
    }
}

public void loadDependencyImages(
    in DependencyImage[] dependencyImages,
) {
    foreach (dependencyImage; dependencyImages) {
        verifyDependencyImage(dependencyImage.path);
        loadDependencyImage(dependencyImage.path, dependencyImage.compilerAbi);
    }
}

public void verifyDependencyImages(in string[] dependencyImages) {
    foreach (dependencyImage; dependencyImages)
        verifyDependencyImage(dependencyImage);
}

// A resolved symbol records the ABI of the image that defines it. `LINK.d`
// alone cannot select DMD's or LDC's incompatible explicit-argument order.
public ResolvedSymbol resolveFunctionSymbol(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import core.sys.posix.dlfcn: dlsym;
    version (DragonFlyBSD) import core.sys.dragonflybsd.dlfcn: RTLD_DEFAULT;
    version (FreeBSD) import core.sys.freebsd.dlfcn: RTLD_DEFAULT;
    version (linux) import core.sys.linux.dlfcn: RTLD_DEFAULT;
    version (NetBSD) import core.sys.netbsd.dlfcn: RTLD_DEFAULT;
    version (OpenBSD) import core.sys.openbsd.dlfcn: RTLD_DEFAULT;
    version (OSX) import core.sys.darwin.dlfcn: RTLD_DEFAULT;
    version (Solaris) import core.sys.solaris.dlfcn: RTLD_DEFAULT;
    import dmd.mangle: mangleExact;

    auto address = cast(void*) dlsym(RTLD_DEFAULT, mangleExact(function_));
    return ResolvedSymbol(address, compilerAbiFor(address));
}

// A native class receiver is an opaque object pointer. For a virtual member,
// DMD's slot identifies the final override in the object's resident vtable;
// provenance belongs to that resolved override rather than the declaration
// through which the caller was statically typed.
public ResolvedSymbol resolveClassMemberSymbol(
    imported!"dmd.func".FuncDeclaration function_,
    in void* receiver,
) @trusted {
    if (function_ is null || receiver is null)
        return ResolvedSymbol.init;

    if (function_.vtblIndex < 0)
        return resolveFunctionSymbol(function_);

    // `receiver` is a live native D class object, whose first word is its
    // vtable pointer; the DMD-computed slot is within that table.
    auto vtable = *cast(void***) receiver;
    if (vtable is null)
        return ResolvedSymbol.init;
    auto address = vtable[function_.vtblIndex];
    return ResolvedSymbol(address, compilerAbiFor(address));
}

public CompilerAbi compilerAbiFor(in void* symbol) {
    import core.sys.posix.dlfcn: dladdr, Dl_info;
    import std.path: absolutePath, buildNormalizedPath;
    import std.string: fromStringz;

    if (symbol is null)
        return hostCompilerAbi;

    Dl_info info;
    if (dladdr(symbol, &info) == 0 || info.dli_fname is null)
        return hostCompilerAbi;

    const imagePath = info.dli_fname.fromStringz.idup
        .absolutePath
        .buildNormalizedPath;
    if (auto compilerAbi = imagePath in _dependencyImageAbis)
        return *compilerAbi;
    return hostCompilerAbi;
}

private void verifyDependencyImage(in string dependencyImage) {
    import std.string: endsWith;

    if (!dependencyImage.endsWith(".so"))
        throw new Exception(
            "dependency image must be a loadable shared library (.so): "
            ~ dependencyImage,
        );
}

private void loadDependencyImage(
    in string dependencyImage,
    in CompilerAbi compilerAbi,
) {
    import core.sys.posix.dlfcn: dlerror, dlopen, RTLD_GLOBAL, RTLD_NOW;
    import std.conv: text;
    import std.path: absolutePath, buildNormalizedPath;
    import std.string: fromStringz, toStringz;

    if (dlopen(dependencyImage.toStringz, RTLD_NOW | RTLD_GLOBAL) is null) {
        auto err = dlerror();
        throw new Exception(text(
            "failed to load dependency image: ",
            dependencyImage,
            err is null ? "" : text(" :: ", err.fromStringz),
        ));
    }

    _dependencyImageAbis[dependencyImage.absolutePath.buildNormalizedPath] =
        compilerAbi;
}

private CompilerAbi compilerAbiFromImage(in string dependencyImage) {
    import std.algorithm.searching: canFind;
    import std.file: read;

    const bytes = cast(const(ubyte)[]) dependencyImage.read;
    const comment = elfCommentSection(bytes);
    const saysDmd = comment.canFind(cast(const(ubyte)[]) "DMD v");
    const saysLdc = comment.canFind(cast(const(ubyte)[]) "ldc version ");
    if (saysDmd == saysLdc)
        throw new Exception(
            "dependency image compiler ABI is ambiguous; supply explicit "
            ~ "compiler provenance: " ~ dependencyImage,
        );
    return saysDmd ? CompilerAbi.dmd : CompilerAbi.ldc;
}

private const(ubyte)[] elfCommentSection(in ubyte[] bytes) {
    import std.algorithm.searching: countUntil;

    if (bytes.length < 64 || bytes[0 .. 4] != [0x7f, 'E', 'L', 'F'])
        throw new Exception("dependency image is not a supported ELF image");
    if (bytes[4] != 2 || bytes[5] != 1)
        throw new Exception("dependency image is not little-endian ELF64");

    const sectionOffset = readElfWord!ulong(bytes, 40);
    const sectionEntrySize = readElfWord!ushort(bytes, 58);
    const sectionCount = readElfWord!ushort(bytes, 60);
    const namesIndex = readElfWord!ushort(bytes, 62);
    if (sectionEntrySize < 64 || namesIndex >= sectionCount)
        throw new Exception("dependency image has an invalid ELF section table");

    const namesHeader = sectionOffset + namesIndex * sectionEntrySize;
    const namesOffset = readElfWord!ulong(bytes, namesHeader + 24);
    const namesSize = readElfWord!ulong(bytes, namesHeader + 32);
    const names = checkedElfSlice(bytes, namesOffset, namesSize);

    foreach (index; 0 .. sectionCount) {
        const header = sectionOffset + index * sectionEntrySize;
        const nameOffset = readElfWord!uint(bytes, header);
        if (nameOffset >= names.length)
            throw new Exception("dependency image has an invalid ELF section name");
        const nameTail = names[nameOffset .. $];
        const nameLength = nameTail.countUntil(0);
        if (nameLength < 0)
            throw new Exception("dependency image has an unterminated ELF section name");
        const name = cast(const(char)[]) nameTail[0 .. nameLength];
        if (name == ".comment") {
            const offset = readElfWord!ulong(bytes, header + 24);
            const size = readElfWord!ulong(bytes, header + 32);
            return checkedElfSlice(bytes, offset, size);
        }
    }
    throw new Exception("dependency image has no compiler metadata");
}

private T readElfWord(T)(in ubyte[] bytes, in size_t offset) {
    if (offset > bytes.length || T.sizeof > bytes.length - offset)
        throw new Exception("dependency image has a truncated ELF section table");
    T result;
    foreach (index; 0 .. T.sizeof)
        result |= cast(T) bytes[offset + index] << (index * 8);
    return result;
}

private const(ubyte)[] checkedElfSlice(
    in ubyte[] bytes,
    in size_t offset,
    in size_t length,
) {
    if (offset > bytes.length || length > bytes.length - offset)
        throw new Exception("dependency image has a truncated ELF section");
    return bytes[offset .. offset + length];
}

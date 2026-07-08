module quickbite.frontend.dmd.functions;

private:

public bool hasNoAvailableSource(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.fbody is null;
}

// An `extern __gshared` global whose definition lives in a compiled dependency
// image: it is in the data segment, has no local initializer, and is declared
// `extern`. Reading it means resolving the native symbol (ffi.md §35.2a).
public bool isExternDataSymbol(
    imported!"dmd.declaration".VarDeclaration variable,
) {
    import dmd.astenums: STC;

    return variable.isDataseg &&
        variable._init is null &&
        (variable.storage_class & STC.extern_) != STC.none;
}

public string noAvailableSourceMessage(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.conv: text;

    return text(
        "`",
        function_.toChars,
        "` cannot be interpreted at compile time, ",
        "because it has no available source code",
    );
}

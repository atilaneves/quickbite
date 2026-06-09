module quickbite.frontend.dmd.functions;

private:

public bool hasNoAvailableSource(
    imported!"dmd.func".FuncDeclaration function_,
) {
    return function_.fbody is null;
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

module quickbite.repl_prelude;

private:

public string __quickbiteFormat(T)(in T value) @safe pure {
    import std.conv: text;
    import std.traits: isDynamicArray, isStaticArray, Unqual;

    alias U = Unqual!T;

    static if (is(U == char) || is(U == wchar) || is(U == dchar)) {
        return text("'", value, "'");
    } else static if (is(U == string)) {
        return text(`"`, value, `"`);
    } else static if (is(U == wstring)) {
        return text(`"`, value, `"w`);
    } else static if (is(U == dstring)) {
        return text(`"`, value, `"d`);
    } else static if (isDynamicArray!U || isStaticArray!U) {
        return arrayDisplay(value);
    } else static if (is(U == uint)) {
        return text(value, "u");
    } else static if (is(U == long)) {
        return text(value, "L");
    } else static if (is(U == ulong)) {
        return text(value, "UL");
    } else static if (is(U == float)) {
        return text(floatingDisplay(value), "f");
    } else static if (is(U == double)) {
        return floatingDisplay(value);
    } else static if (is(U == real)) {
        return text(floatingDisplay(value), "L");
    } else {
        return text(value);
    }
}

private string arrayDisplay(T)(in T value) @safe pure {
    string rendered = "[";
    foreach (index, element; value) {
        if (index != 0)
            rendered ~= ", ";
        rendered ~= __quickbiteFormat(element);
    }
    rendered ~= "]";
    return rendered;
}

private string floatingDisplay(T)(in T value) @safe pure {
    import std.algorithm.searching: canFind;
    import std.conv: text;

    const rendered = text(value);
    if (rendered.canFind(".") || rendered.canFind("e") ||
        rendered.canFind("E"))
        return rendered;
    return text(rendered, ".0");
}

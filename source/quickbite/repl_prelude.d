module quickbite.repl_prelude;

private:

import std.traits: Unqual;

public string __quickbiteFormat(T)(in T value) @safe pure {
    import std.conv: text;
    import std.traits: isAssociativeArray, isDynamicArray, isStaticArray,
        Unqual;

    alias U = Unqual!T;

    static if (is(U == enum)) {
        return text(U.stringof, ".", value);
    } else static if (is(U == char) || is(U == wchar) || is(U == dchar)) {
        return characterDisplay(value);
    } else static if (is(U == string) || is(U == wstring) ||
        is(U == dstring) || isCharacterArray!U) {
        return stringDisplay(value);
    } else static if (isDynamicArray!U || isStaticArray!U) {
        return arrayDisplay(value);
    } else static if (is(U == uint)) {
        return text(value) ~ "u";
    } else static if (is(U == long)) {
        return text(value) ~ "L";
    } else static if (is(U == ulong)) {
        return text(value) ~ "UL";
    } else static if (is(U == float)) {
        return floatingDisplay(value) ~ "f";
    } else static if (is(U == double)) {
        return floatingDisplay(value);
    } else static if (is(U == real)) {
        return floatingDisplay(value) ~ "L";
    } else static if (isAssociativeArray!U) {
        return assocArrayDisplay(value);
    } else static if (is(U == struct)) {
        return structDisplay(value);
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

private enum isCharacterArray(T) = is(T == E[], E) &&
    (is(E == char) || is(E == wchar) || is(E == dchar));

private string characterDisplay(T)(in T value) @safe pure {
    string rendered = "'";
    rendered ~= cast(dchar) value;
    rendered ~= "'";
    return rendered;
}

private string stringDisplay(T)(in T value) @safe pure {
    import std.traits: Unqual;

    string rendered = `"`;
    foreach (dchar character; value)
        rendered ~= character;
    rendered ~= `"`;

    static if (isWcharArray!T) {
        rendered ~= "w";
    } else static if (isDcharArray!T) {
        rendered ~= "d";
    }

    return rendered;
}

private enum isWcharArray(T) = is(Unqual!T == E[], E) && is(Unqual!E == wchar);
private enum isDcharArray(T) = is(Unqual!T == E[], E) && is(Unqual!E == dchar);

private string assocArrayDisplay(T)(in T value) @safe pure {
    string rendered = "[";
    bool first = true;
    foreach (key, element; value) {
        if (!first)
            rendered ~= ", ";
        first = false;
        rendered ~= __quickbiteFormat(key) ~ ":" ~ __quickbiteFormat(element);
    }
    rendered ~= "]";
    return rendered;
}

private string structDisplay(T)(in T value) @safe pure {
    import std.traits: Unqual;

    string rendered = Unqual!T.stringof ~ "(";
    foreach (index, field; value.tupleof) {
        if (index != 0)
            rendered ~= ", ";
        rendered ~= __quickbiteFormat(field);
    }
    rendered ~= ")";
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

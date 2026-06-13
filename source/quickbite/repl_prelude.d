module quickbite.repl_prelude;

private:

public string __quickbiteFormat(T)(in T value) @safe pure {
    import std.algorithm.searching: canFind;
    import std.conv: text;

    static if (is(T == char)) {
        return text("'", value, "'");
    } else static if (is(T == double)) {
        const rendered = text(value);
        if (rendered.canFind(".") || rendered.canFind("e") ||
            rendered.canFind("E"))
            return rendered;
        return text(rendered, ".0");
    } else {
        return text(value);
    }
}

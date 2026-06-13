module quickbite.repl_prelude;

private:

public string __quickbiteFormat(T)(in T value) @safe pure {
    import std.conv: text;

    static if (is(T == char)) {
        return text("'", value, "'");
    } else {
        return text(value);
    }
}

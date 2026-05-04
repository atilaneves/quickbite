void encode(T)(T val, ref ubyte[] output) {
    static foreach(i; 0 .. T.sizeof)
        output ~= cast(ubyte)(val >> (i * 8));
}

T decode(T)(in ubyte[] input, ref size_t pos) {
    T result = 0;

    static foreach(i; 0 .. T.sizeof)
        result |= cast(T)(input[pos++]) << (i * 8);

    return result;
}

struct Minicereal {
    ubyte[] bytes;

    void put(T)(T val) {
        encode(val, bytes);
    }

    T get(T)(ref size_t pos) {
        return decode!T(bytes, pos);
    }
}

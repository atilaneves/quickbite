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

unittest {
    ubyte[] buf;
    encode!ubyte(0x2au, buf);
    assert(buf.length == 1);
    assert(buf[0] == 0x2au);
}

unittest {
    ubyte[] input = [0x2au];
    size_t pos = 0;
    assert(decode!ubyte(input, pos) == 0x2au);
    assert(pos == 1);
}

unittest {
    ubyte value = 0x2au;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!ubyte(buf, pos) == value);
    assert(pos == 1);
}

unittest {
    ubyte[] buf;
    encode!byte(cast(byte) -42, buf);
    ubyte[] expected = [0xd6u];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0xd6u];
    size_t pos = 0;
    assert(decode!byte(input, pos) == cast(byte) -42);
    assert(pos == 1);
}

unittest {
    byte value = cast(byte) -42;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!byte(buf, pos) == value);
    assert(pos == 1);
}

unittest {
    ubyte[] buf;
    encode!ushort(0x1234u, buf);
    ubyte[] expected = [0x34u, 0x12u];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0x34u, 0x12u];
    size_t pos = 0;
    assert(decode!ushort(input, pos) == 0x1234u);
    assert(pos == 2);
}

unittest {
    ushort value = 0x1234u;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!ushort(buf, pos) == value);
    assert(pos == 2);
}

unittest {
    ubyte[] buf;
    encode!short(cast(short) -42, buf);
    ubyte[] expected = [0xd6u, 0xffu];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0xd6u, 0xffu];
    size_t pos = 0;
    assert(decode!short(input, pos) == cast(short) -42);
    assert(pos == 2);
}

unittest {
    short value = cast(short) -42;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!short(buf, pos) == value);
    assert(pos == 2);
}

unittest {
    ubyte[] buf;
    encode!uint(0x01020304u, buf);
    ubyte[] expected = [4u, 3u, 2u, 1u];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [4u, 3u, 2u, 1u];
    size_t pos = 0;
    assert(decode!uint(input, pos) == 0x01020304u);
    assert(pos == 4);
}

unittest {
    uint value = 0x01020304u;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!uint(buf, pos) == value);
    assert(pos == 4);
}

unittest {
    ubyte[] buf;
    encode!int(-42, buf);
    ubyte[] expected = [0xd6u, 0xffu, 0xffu, 0xffu];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0xd6u, 0xffu, 0xffu, 0xffu];
    size_t pos = 0;
    assert(decode!int(input, pos) == -42);
    assert(pos == 4);
}

unittest {
    int value = -42;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!int(buf, pos) == value);
    assert(pos == 4);
}

unittest {
    ubyte[] buf;
    encode!ulong(0x8070605040302010UL, buf);
    ubyte[] expected = [
        0x10u,
        0x20u,
        0x30u,
        0x40u,
        0x50u,
        0x60u,
        0x70u,
        0x80u,
    ];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [
        0x10u,
        0x20u,
        0x30u,
        0x40u,
        0x50u,
        0x60u,
        0x70u,
        0x80u,
    ];
    size_t pos = 0;
    assert(decode!ulong(input, pos) == 0x8070605040302010UL);
    assert(pos == 8);
}

unittest {
    ulong value = 0x8070605040302010UL;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!ulong(buf, pos) == value);
    assert(pos == 8);
}

unittest {
    ubyte[] buf;
    encode!long(-42L, buf);
    ubyte[] expected = [
        0xd6u,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
    ];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [
        0xd6u,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
    ];
    size_t pos = 0;
    assert(decode!long(input, pos) == -42L);
    assert(pos == 8);
}

unittest {
    long value = -42L;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!long(buf, pos) == value);
    assert(pos == 8);
}

unittest {
    Minicereal cereal;
    cereal.put(0x01020304);
    size_t pos = 0;
    assert(cereal.get!int(pos) == 0x01020304);
    assert(pos == 4);
}

unittest {
    Minicereal cereal;
    assert(cereal.bytes.length == 0);
}

unittest {
    Minicereal cereal;
    cereal.bytes ~= 0x2au;
    assert(cereal.bytes.length == 1);
    assert(cereal.bytes[0] == 0x2au);
}

unittest {
    Minicereal cereal;
    cereal.bytes ~= cast(ubyte) 42;
    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 42);
    assert(pos == 1);
}

unittest {
    Minicereal cereal;
    cereal.bytes = [0];
    cereal.bytes[0] = cast(ubyte) 42;
    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 42);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    assert(cereal.bytes.length == 1);
    assert(cereal.bytes[0] == 0x2au);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    ubyte[] expected = [0x2au];
    assert(cereal.bytes == expected);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    cereal.put!ushort(0x1234u);
    ubyte[] expected = [0x2au, 0x34u, 0x12u];
    assert(cereal.bytes == expected);
}

unittest {
    Minicereal cereal;
    cereal.put(0x01020304);
    ubyte[] expected = [4u, 3u, 2u, 1u];
    assert(cereal.bytes[] == expected);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x99u);
    cereal.put!ushort(0x1234u);
    ubyte[] expected = [0x34u, 0x12u];
    assert(cereal.bytes[1 .. 3] == expected);
}

unittest {
    Minicereal cereal;
    cereal.bytes = [1, 2, 3, 4];
    ubyte[] expected = [2, 3];
    assert(cereal.bytes[1 .. 3] == expected[]);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x99u);
    cereal.put(0x01020304);
    ubyte[] expected = [4u, 3u, 2u, 1u];
    assert(cereal.bytes[$ - 4 .. $] == expected);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 0x2au);
    assert(pos == 1);
}

unittest {
    Minicereal cereal;
    cereal.put(42);
    size_t pos = 0;
    assert(cereal.get!int(pos) == 42);
    assert(pos == 4);
}

unittest {
    Minicereal cereal;
    cereal.bytes = [4u, 3u, 2u, 1u];
    size_t pos = 0;
    assert(cereal.get!int(pos) == 0x01020304);
    assert(pos == 4);
}

unittest {
    const value = 0x8070605040302010UL;
    Minicereal cereal;
    cereal.put(value);
    size_t pos = 0;
    const decoded = cereal.get!ulong(pos);
    assert(decoded == value);
    assert(decoded > 0UL);
    assert(pos == 8);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    cereal.put!byte(cast(byte) -42);
    cereal.put!ushort(0x1234u);
    cereal.put!short(cast(short) -1234);
    cereal.put!uint(0x01020304u);
    cereal.put!int(-0x01020304);
    cereal.put!ulong(0x8070605040302010UL);
    cereal.put!long(-0x0102030405060708L);

    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 0x2au);
    assert(cereal.get!byte(pos) == cast(byte) -42);
    assert(cereal.get!ushort(pos) == 0x1234u);
    assert(cereal.get!short(pos) == cast(short) -1234);
    assert(cereal.get!uint(pos) == 0x01020304u);
    assert(cereal.get!int(pos) == -0x01020304);
    assert(cereal.get!ulong(pos) == 0x8070605040302010UL);
    assert(cereal.get!long(pos) == -0x0102030405060708L);
    assert(pos == cereal.bytes.length);
}

module quickbite.lang;

private:


public alias Value = imported!"std.sumtype".SumType!(

    Void,

    bool,

    ubyte,
    byte,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,

    char,
    wchar,
    dchar,

    float,
    double,
    real,

);


public struct Void {}

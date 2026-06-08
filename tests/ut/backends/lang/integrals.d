module ut.backends.lang.integrals;


import ut.backends;
import std.conv: text;
import std.meta: AliasSeq;


private alias IntegralTypes = AliasSeq!(
    byte,
    ubyte,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,
);


static foreach (backend; AliasSeq!(Bytecode)) {
    static foreach (T; IntegralTypes) {
        static if (is(T == byte) || is(T == ubyte) || is(T == short) ||
            is(T == ushort) || is(T == int) || is(T == uint))
        @("type." ~ T.stringof ~ "." ~ Bytecode.stringof)
        unittest {
            runBackendSourceFixtureTests!Bytecode(text(
                "alias T = ",
                T.stringof,
                ";",
                q{
                    enum expected = cast(T) 130;

                    T identity(T value) {
                        return value;
                    }

                    int input() {
                        return 130;
                    }

                    unittest {
                        T value = cast(T) input;
                        assert(identity(value) == value);
                        assert(value == expected);
                    }
                },
            ));
        }
    }
}

static foreach (backend; backends) {

    static foreach (T; IntegralTypes) {
        @("type." ~ T.stringof ~ "." ~ backend.stringof)
        unittest {
            runBackendSourceFixtureTests!backend(text(
               "alias T = ", T.stringof, `;`,
                q{
                    enum expected = cast(T) 130;

                    T identity(T value) {
                        return value;
                    }

                    int input() {
                        return 130;
                    }

                    unittest {
                        T value = cast(T) input;
                        assert(identity(value) == value);
                        assert(value == expected);
                    }
                },
            ));
        }
    }

    @("typeFailureMessage.byte.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            alias T = byte;

            T identity(T value) {
                 return value;
            }

            int input() {
                return 130;
            }

            unittest {
                T value = cast(T) input;
                assert(identity(value) == value);
                assert(value == 130);
            }
        }).shouldThrowWithMessage("-126 != 130");
    }

    @("typeFailureMessage.ubyte.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            alias T = ubyte;

            T identity(T value) {
                return value;
            }

            int input() {
                return 130;
            }

            unittest {
                T value = cast(T) input;
                assert(identity(value) == value);
                assert(value == 129);
            }
        }).shouldThrowWithMessage("130 != 129");
    }

    @("typeFailureMessage.uint.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            alias T = uint;

            T identity(T value) {
                return value;
            }

            int input() {
                return 130;
            }

            unittest {
                T value = cast(T) input;
                assert(identity(value) == value);
                assert(value == 131);
            }
        }).shouldThrowWithMessage("130 != 131");
    }
}

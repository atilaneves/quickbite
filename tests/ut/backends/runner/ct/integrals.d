module ut.backends.runner.ct.integrals;


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


static foreach (T; IntegralTypes) {
    static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
        @("type." ~ T.stringof ~ "." ~ backend.stringof)
        unittest {
            runBackendSourceFixtureTests!backend(text(
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

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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

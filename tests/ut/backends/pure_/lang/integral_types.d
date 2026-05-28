module ut.backends.pure_.lang.integral_types;


import std.conv: text;
import std.meta: AliasSeq;
import ut.backends;


private:

static foreach (backend; backends) {
    alias IntegralTypes = AliasSeq!(
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
        @("integralType." ~ T.stringof ~ "." ~ backend.stringof)
        unittest {
            newBackend!backend.runTests(text(
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

    @("integralTypeFailureMessage.byte.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
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

    @("integralTypeFailureMessage.ubyte.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
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

    @("integralTypeFailureMessage.uint.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
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

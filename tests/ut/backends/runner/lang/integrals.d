module ut.backends.runner.lang.integrals;


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
    static foreach (backend; Matrix!(Plus!(IR))) {
        @("type." ~ T.stringof ~ "." ~ backend.stringof)
        @Tags(backend.stringof)
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

static foreach (backend; Matrix!(Plus!(IR))) {
    @("typeFailureMessage.byte.0." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!(Plus!(IR))) {
    @("typeFailureMessage.ubyte.0." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!(Plus!(IR))) {
    @("typeFailureMessage.uint.0." ~ backend.stringof)
    @Tags(backend.stringof)
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

// IR is omitted: its i32 comparison is signed-only, so it evaluates
// `-1 < 0u` as true — a semantic divergence recorded in ai/plans/ir.md.
static foreach (backend; Matrix!()) {
    @("signedUnsignedComparisonIsUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int neg() {
                return -1;
            }

            uint zero() {
                return 0u;
            }

            unittest {
                int a = neg;
                uint b = zero;
                // The signed operand converts to uint, so -1 compares as
                // uint.max and is *not* less than 0u.
                assert(!(a < b));
            }
        });
    }
}

static foreach (backend; Matrix!(Plus!(IR))) {
    @("wraparoundAtTypeBoundaries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int top() {
                return int.max;
            }

            uint bottom() {
                return 0u;
            }

            unittest {
                int a = top;
                assert(a + 1 == int.min);

                uint b = bottom;
                assert(b - 1 == uint.max);
            }
        });
    }
}

// dmd CTFE rejects int.min / -1 as integer overflow; at runtime the same
// division raises SIGFPE on x86_64, so no runtime backend can pin a value.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("int.divisionOverflowAtIntMinIsRejected." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int dividend() {
                return int.min;
            }

            int divisor() {
                return -1;
            }

            unittest {
                int a = dividend;
                int b = divisor;

                // Dividing by the negated divisor stays in range.
                assert(a / -b == int.min);

                assert(a / b == int.min);
            }
        }).shouldThrowWithMessage(
            "integer overflow: `int.min / -1`\n" ~
            "cannot compare `__error` at compile time",
        );
    }
}

// Same as above: CTFE rejects int.min % -1 as integer overflow and the
// runtime instruction traps.
static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("int.moduloOverflowAtIntMinIsRejected." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int dividend() {
                return int.min;
            }

            int divisor() {
                return -1;
            }

            unittest {
                int a = dividend;
                int b = divisor;

                // The modulo by the negated divisor stays in range.
                assert(a % -b == 0);

                assert(a % b == 0);
            }
        }).shouldThrowWithMessage(
            "integer overflow: `int.min % -1`\n" ~
            "cannot compare `__error` at compile time",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("unsignedDivisionIsUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint dividend() {
                return 4_000_000_000u;
            }

            int divisorAsInt() {
                return 3;
            }

            uint divisorAsUint() {
                return 3u;
            }

            unittest {
                uint a = dividend;

                // The int operand converts to uint before dividing, so the
                // result is unsigned division, not division of a's bit
                // pattern reinterpreted as a negative int.
                int b = divisorAsInt;
                assert(a / b == 1_333_333_333u);

                uint c = divisorAsUint;
                assert(a / c == 1_333_333_333u);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("unsignedModuloIsUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint dividend() {
                return 4_000_000_000u;
            }

            int divisorAsInt() {
                return 3;
            }

            uint divisorAsUint() {
                return 3u;
            }

            unittest {
                uint a = dividend;

                // The int operand converts to uint before taking the
                // remainder, so the result is unsigned modulo, not modulo of
                // a's bit pattern reinterpreted as a negative int.
                int b = divisorAsInt;
                assert(a % b == 1u);

                uint c = divisorAsUint;
                assert(a % c == 1u);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("unsignedCompoundDivisionIsUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint dividend() {
                return 4_000_000_000u;
            }

            unittest {
                uint a = dividend;

                // `/=` keeps the lvalue's own unsigned type for the
                // division, not a signed reinterpretation of its bits.
                a /= 3;
                assert(a == 1_333_333_333u);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("unsignedCompoundModuloIsUnsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint dividend() {
                return 4_000_000_000u;
            }

            unittest {
                uint a = dividend;

                // `%=` keeps the lvalue's own unsigned type for the
                // remainder, not a signed reinterpretation of its bits.
                a %= 3;
                assert(a == 1u);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("signedLongDivisionTruncatesTowardZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long dividend() {
                return -1_000_000_000_000L;
            }

            long divisor() {
                return 7L;
            }

            unittest {
                long a = dividend;
                long b = divisor;

                // Signed division truncates toward zero, not toward
                // negative infinity, regardless of which operand is
                // negative.
                assert(a / b == -142_857_142_857L);
                assert((-a) / b == 142_857_142_857L);
                assert(a / (-b) == 142_857_142_857L);
                assert((-a) / (-b) == -142_857_142_857L);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("signedLongModuloFollowsDividendSign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long dividend() {
                return -1_000_000_000_000L;
            }

            long divisor() {
                return 7L;
            }

            unittest {
                long a = dividend;
                long b = divisor;

                // The remainder's sign follows the dividend, not the
                // divisor.
                assert(a % b == -1L);
                assert((-a) % b == 1L);
                assert(a % (-b) == -1L);
                assert((-a) % (-b) == 1L);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("signedLongCompoundModuloFollowsDividendSign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long dividend() {
                return -1_000_000_000_000L;
            }

            unittest {
                long a = dividend;

                // `%=` on a signed 8-byte lvalue keeps the dividend's own
                // sign in the remainder.
                a %= 7L;
                assert(a == -1L);
            }
        });
    }
}

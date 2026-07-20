module ut.backends.runner.lang.math;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("evaluatesRuntimePowDoubleInputs." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                double base = 2.0;
                double exponent = 4.0;
                assert(pow(base, exponent) == 16.0);

                base = 9.0;
                exponent = 0.5;
                double root = pow(base, exponent);
                assert(root > 2.999);
                assert(root < 3.001);

                base = 4.0;
                exponent = -1.0;
                assert(pow(base, exponent) == 0.25);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimePowDoubleInputsFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                double base = 2.0;
                double exponent = 4.0;
                assert(pow(base, exponent) == 17.0);
            }
        }).shouldThrowWithMessage("16 != 17");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimePowDoubleInputsFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                double base = 9.0;
                double exponent = 0.5;
                double root = pow(base, exponent);
                assert(root > 3.001);
            }
        }).shouldThrowWithMessage("3 <= 3.001");
    }
}

static foreach (backend; Matrix!()) {
    @("doesNotTreatUserNamedPowAsMathIntrinsic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double pow(double base, double exponent) {
                return base + exponent;
            }

            unittest {
                double base = 2.0;
                double exponent = 4.0;
                assert(pow(base, exponent) == 6.0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double pow(double base, double exponent) {
                return base + exponent;
            }

            unittest {
                double base = 2.0;
                double exponent = 4.0;
                assert(pow(base, exponent) == 7.0);
            }
        }).shouldThrowWithMessage("6 != 7");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double pow(double base, double exponent) {
                return base + exponent;
            }

            unittest {
                double base = 3.0;
                double exponent = 4.0;
                assert(pow(base, exponent) == 8.0);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSqrtInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 9.0;
                assert(sqrt(input) == 3.0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeSqrtInputFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 9.0;
                assert(sqrt(input) == 4.0);
            }
        }).shouldThrowWithMessage("3 != 4");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeSqrtInputFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 25.0;
                assert(sqrt(input) == 6.0);
            }
        }).shouldThrowWithMessage("5 != 6");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesDifferentRuntimeSqrtInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 16.0;
                assert(sqrt(input) == 4.0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesDifferentRuntimeSqrtInputFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 16.0;
                assert(sqrt(input) == 5.0);
            }
        }).shouldThrowWithMessage("4 != 5");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesDifferentRuntimeSqrtInputFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 36.0;
                assert(sqrt(input) == 7.0);
            }
        }).shouldThrowWithMessage("6 != 7");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeNonIntegerSqrtInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 2.25;
                assert(sqrt(input) == 1.5);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeNonIntegerSqrtInputFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 2.25;
                assert(sqrt(input) == 2.5);
            }
        }).shouldThrowWithMessage("1.5 != 2.5");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeNonIntegerSqrtInputFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 6.25;
                assert(sqrt(input) == 3.5);
            }
        }).shouldThrowWithMessage("2.5 != 3.5");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeNonPerfectSqrtInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 2.0;
                double result = sqrt(input);
                assert(result > 1.414);
                assert(result < 1.415);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeNonPerfectSqrtInputFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 2.0;
                double result = sqrt(input);
                assert(result > 1.415);
            }
        }).shouldThrowWithMessage("1.41421 <= 1.415");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeNonPerfectSqrtInputFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 2.0;
                double result = sqrt(input);
                assert(result < 1.414);
            }
        }).shouldThrowWithMessage("1.41421 >= 1.414");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeFabsDoubleInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                double first = -3.5;
                double second = -12.25;
                assert(fabs(first) == 3.5);
                assert(fabs(second) == 12.25);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeFabsDoubleInputFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                double first = -3.5;
                assert(fabs(first) == 4.5);
            }
        }).shouldThrowWithMessage("3.5 != 4.5");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeFabsDoubleInputFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                double second = -12.25;
                assert(fabs(second) == 13.25);
            }
        }).shouldThrowWithMessage("12.25 != 13.25");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeFabsPositiveDoubleInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                double input = 7.75;
                assert(fabs(input) == 7.75);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                double input = 7.75;
                assert(fabs(input) == 8.75);
            }
        }).shouldThrowWithMessage("7.75 != 8.75");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                double input = 9.5;
                assert(fabs(input) == 10.5);
            }
        }).shouldThrowWithMessage("9.5 != 10.5");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsNaNDoubleInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isNaN;

            unittest {
                double notANumber = double.nan;
                double finite = 21.0;

                assert(isNaN(notANumber));
                assert(!isNaN(finite));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsNaNDoubleInputFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isNaN;

            unittest {
                double notANumber = double.nan;
                assert(!isNaN(notANumber));
            }
        }).shouldThrowWithMessage("true == true");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsNaNDoubleInputFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isNaN;

            unittest {
                double finite = 21.0;
                assert(isNaN(finite));
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsInfinityDoubleInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isInfinity;

            unittest {
                double input = double.infinity;
                assert(isInfinity(input));

                input = -double.infinity;
                assert(isInfinity(input));

                input = double.max;
                assert(!isInfinity(input));

                input = double.nan;
                assert(!isInfinity(input));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsInfinityDoubleInputFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isInfinity;

            unittest {
                double input = double.infinity;
                assert(!isInfinity(input));
            }
        }).shouldThrowWithMessage("true == true");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsInfinityDoubleInputFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isInfinity;

            unittest {
                double input = double.max;
                assert(isInfinity(input));
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitDoubleInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                double input = -0.0;
                assert(signbit(input) != 0);

                input = 0.0;
                assert(signbit(input) == 0);

                input = -12.25;
                assert(signbit(input) != 0);

                input = 12.25;
                assert(signbit(input) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitDoubleInputFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                double input = -0.0;
                assert(signbit(input) == 0);
            }
        }).shouldThrowWithMessage("1 != 0");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitDoubleInputFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                double input = 0.0;
                assert(signbit(input) != 0);
            }
        }).shouldThrowWithMessage("0 == 0");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitNanInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                double input = -double.nan;
                assert(signbit(input) != 0);

                input = double.nan;
                assert(signbit(input) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitNanInputFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                double input = -double.nan;
                assert(signbit(input) == 0);
            }
        }).shouldThrowWithMessage("1 != 0");
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitNanInputFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                double input = double.nan;
                assert(signbit(input) != 0);
            }
        }).shouldThrowWithMessage("0 == 0");
    }
}

static foreach (backend; Matrix!()) {
    @("doesNotTreatUserNamedIsNaNAsMathIntrinsic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isNaN(double value) {
                return true;
            }

            unittest {
                double input = 21.0;
                assert(isNaN(input));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("doesNotTreatUserNamedIsNaNAsMathIntrinsicFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isNaN(double value) {
                return true;
            }

            unittest {
                double input = 21.0;
                assert(!isNaN(input));
            }
        }).shouldThrowWithMessage("true == true");
    }
}

static foreach (backend; Matrix!()) {
    @("doesNotTreatUserNamedIsNaNAsMathIntrinsicFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isNaN(double value) {
                return true;
            }

            unittest {
                double input = double.nan;
                assert(!isNaN(input));
            }
        }).shouldThrowWithMessage("true == true");
    }
}

static foreach (backend; Matrix!()) {
    @("callsUserNamedIsNaNForNanInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isNaN(double value) {
                return false;
            }

            unittest {
                double input = double.nan;
                assert(!isNaN(input));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("callsUserNamedIsNaNForNanInputFailureMessage.0." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isNaN(double value) {
                return false;
            }

            unittest {
                double input = double.nan;
                assert(isNaN(input));
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; Matrix!()) {
    @("callsUserNamedIsNaNForNanInputFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isNaN(double value) {
                return false;
            }

            unittest {
                double input = 21.0;
                assert(isNaN(input));
            }
        }).shouldThrowWithMessage("false != true");
    }
}

static foreach (backend; Matrix!()) {
    @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsics." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double sqrt(double value) {
                return value + 1.0;
            }

            double fabs(double value) {
                return value + 2.0;
            }

            unittest {
                double input = 9.0;
                assert(sqrt(input) == 10.0);
                assert(fabs(input) == 11.0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsicsFailureMessage.0." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double sqrt(double value) {
                return value + 1.0;
            }

            double fabs(double value) {
                return value + 2.0;
            }

            unittest {
                double input = 9.0;
                assert(sqrt(input) == 11.0);
            }
        }).shouldThrowWithMessage("10 != 11");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE assert formatter emits `<double not supported>` for double failure messages"),
)) {
    @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsicsFailureMessage.1." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double sqrt(double value) {
                return value + 1.0;
            }

            double fabs(double value) {
                return value + 2.0;
            }

            unittest {
                double input = 9.0;
                assert(fabs(input) == 12.0);
            }
        }).shouldThrowWithMessage("11 != 12");
    }
}

// In this and all the float/real intrinsic blocks below, Bytecode
// ("Unsupported type in bytecode core: float"/"real") and IR (f32/f64
// valueType assert in compileIntrinsicCall) cannot run float/real
// intrinsics.
static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSqrtFloatInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                float input = 9.0f;
                assert(sqrt(input) == 3.0f);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSqrtRealInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                real input = 9.0L;
                assert(sqrt(input) == 3.0L);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeFabsFloatInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                float input = -2.5f;
                assert(fabs(input) == 2.5f);

                input = 2.5f;
                assert(fabs(input) == 2.5f);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeFabsRealInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: fabs;

            unittest {
                real input = -2.5L;
                assert(fabs(input) == 2.5L);

                input = 2.5L;
                assert(fabs(input) == 2.5L);
            }
        });
    }
}

// SystemLinker is omitted: when an earlier test in the same process has
// already instantiated std.math pow!(float, float), dmd-as-a-library skips
// emitting the instance into the snippet object and the link fails with an
// undefined symbol (libphobos2 does not ship the float instance). Recorded in
// ai/plans/dmd-backend.md.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode)) {
    @("evaluatesRuntimePowFloatInputs." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                float base = 2.0f;
                float exponent = 4.0f;
                assert(pow(base, exponent) == 16.0f);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimePowRealInputs." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                real base = 2.0L;
                real exponent = 4.0L;
                assert(pow(base, exponent) == 16.0L);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsNaNFloatInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isNaN;

            unittest {
                float notANumber = float.nan;
                float finite = 21.0f;

                assert(isNaN(notANumber));
                assert(!isNaN(finite));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsNaNRealInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isNaN;

            unittest {
                real notANumber = real.nan;
                real finite = 21.0L;

                assert(isNaN(notANumber));
                assert(!isNaN(finite));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsInfinityFloatInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isInfinity;

            unittest {
                float input = float.infinity;
                assert(isInfinity(input));

                input = -float.infinity;
                assert(isInfinity(input));

                input = float.max;
                assert(!isInfinity(input));

                input = float.nan;
                assert(!isInfinity(input));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeIsInfinityRealInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: isInfinity;

            unittest {
                real input = real.infinity;
                assert(isInfinity(input));

                input = -real.infinity;
                assert(isInfinity(input));

                input = real.max;
                assert(!isInfinity(input));

                input = real.nan;
                assert(!isInfinity(input));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitFloatInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                float input = -0.0f;
                assert(signbit(input) != 0);

                input = 0.0f;
                assert(signbit(input) == 0);

                input = -12.25f;
                assert(signbit(input) != 0);

                input = 12.25f;
                assert(signbit(input) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeSignbitRealInput." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: signbit;

            unittest {
                real input = -0.0L;
                assert(signbit(input) != 0);

                input = 0.0L;
                assert(signbit(input) == 0);

                input = -12.25L;
                assert(signbit(input) != 0);

                input = 12.25L;
                assert(signbit(input) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeDoubleTruthiness." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double input = 0.5;
                assert((input ? true : false) == true);

                input = 0.0;
                assert((input ? true : false) == false);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeFloatTruthiness." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                float input = 0.5f;
                assert((input ? true : false) == true);

                input = 0.0f;
                assert((input ? true : false) == false);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("evaluatesRuntimeRealTruthiness." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                real input = 0.5L;
                assert((input ? true : false) == true);

                input = 0.0L;
                assert((input ? true : false) == false);
            }
        });
    }
}

// D truthiness is `!= 0`; NaN != 0, so a NaN operand is true.
static foreach (backend; Matrix!()) {
    @("doubleNaNIsTruthy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double n = double.nan;
                assert(n ? true : false);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("floatNaNIsTruthy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                float n = float.nan;
                assert(n ? true : false);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("realNaNIsTruthy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                real n = real.nan;
                assert(n ? true : false);
            }
        });
    }
}

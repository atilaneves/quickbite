module ut.backends.lang.math;


import ut.backends;


static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimePowDoubleInputs." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimePowDoubleInputsFailureMessage.0." ~ backend.stringof)
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

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimePowDoubleInputsFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimePowDoubleInputsFailureMessage.0." ~ backend.stringof)
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

    @("evaluatesRuntimePowDoubleInputsFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; backendsWith!Interpreter) {
    @("doesNotTreatUserNamedPowAsMathIntrinsic." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeSqrtInput." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeSqrtInputFailureMessage.0." ~ backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeSqrtInputFailureMessage.0." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeSqrtInputFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeSqrtInputFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesDifferentRuntimeSqrtInput." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesDifferentRuntimeSqrtInputFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 16.0;
                assert(sqrt(input) == 5.0);
            }
        }).shouldThrowWithMessage("4 != 5");
    }

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesDifferentRuntimeSqrtInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesDifferentRuntimeSqrtInputFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: sqrt;

            unittest {
                double input = 16.0;
                assert(sqrt(input) == 5.0);
            }
        }).shouldThrowWithMessage("4 != 5");
    }

    @("evaluatesDifferentRuntimeSqrtInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeNonIntegerSqrtInput." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeNonIntegerSqrtInputFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeNonIntegerSqrtInputFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeNonIntegerSqrtInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeNonIntegerSqrtInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeNonPerfectSqrtInput." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeNonPerfectSqrtInputFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeNonPerfectSqrtInputFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeNonPerfectSqrtInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeNonPerfectSqrtInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeFabsDoubleInput." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeFabsDoubleInputFailureMessage.0." ~ backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeFabsDoubleInputFailureMessage.0." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeFabsDoubleInputFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeFabsDoubleInputFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeFabsPositiveDoubleInput." ~ backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; backends) {
    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter)) {
    @("evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeIsNaNDoubleInput." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeIsNaNDoubleInputFailureMessage.0." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeIsNaNDoubleInputFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeIsInfinityDoubleInput." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeIsInfinityDoubleInputFailureMessage.0." ~
        backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeIsInfinityDoubleInputFailureMessage.1." ~
        backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeSignbitDoubleInput." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeSignbitDoubleInputFailureMessage.0." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeSignbitDoubleInputFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; backendsWith!(Interpreter, Bytecode)) {
    @("evaluatesRuntimeSignbitNanInput." ~ backend.stringof)
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

static foreach (backend; backendsWith!Interpreter) {
    @("evaluatesRuntimeSignbitNanInputFailureMessage.0." ~ backend.stringof)
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

static foreach (backend; backendsWith!Interpreter) {
    @("evaluatesRuntimeSignbitNanInputFailureMessage.1." ~ backend.stringof)
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

static foreach (backend; backendsWith!Interpreter) {
    @("doesNotTreatUserNamedIsNaNAsMathIntrinsic." ~ backend.stringof)
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

static foreach (backend; backends) {
    @("doesNotTreatUserNamedIsNaNAsMathIntrinsicFailureMessage.0." ~
        backend.stringof)
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

    @("doesNotTreatUserNamedIsNaNAsMathIntrinsicFailureMessage.1." ~
        backend.stringof)
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

    @("callsUserNamedIsNaNForNanInput." ~ backend.stringof)
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

    @("callsUserNamedIsNaNForNanInputFailureMessage.0." ~ backend.stringof)
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

    @("callsUserNamedIsNaNForNanInputFailureMessage.1." ~ backend.stringof)
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

    @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsics." ~ backend.stringof)
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

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsicsFailureMessage.0." ~
        backend.stringof)
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

    @ShouldFail(
        "DMD CTFE returns <double not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsicsFailureMessage.1." ~
        backend.stringof)
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

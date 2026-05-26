module ut.executors.pure_.lang.math;


import ut.executors;


private:

import std.conv: text;
import unit_threaded;


static foreach (executorName; [ExecutorName.ir]) {
    @("evaluatesRuntimePowDoubleInputs." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }

    @("doesNotTreatUserNamedPowAsMathIntrinsic." ~ executorName.text)
    unittest {
        runTests(q{
            double pow(double base, double exponent) {
                return base + exponent;
            }

            unittest {
                double base = 2.0;
                double exponent = 4.0;
                assert(pow(base, exponent) == 6.0);
            }
        }, executorName);
    }

    @("evaluatesRuntimeSqrtInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: sqrt;

            unittest {
                double input = 9.0;
                assert(sqrt(input) == 3.0);
            }
        }, executorName);
    }

    @("evaluatesDifferentRuntimeSqrtInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: sqrt;

            unittest {
                double input = 16.0;
                assert(sqrt(input) == 4.0);
            }
        }, executorName);
    }

    @("evaluatesRuntimeNonIntegerSqrtInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: sqrt;

            unittest {
                double input = 2.25;
                assert(sqrt(input) == 1.5);
            }
        }, executorName);
    }

    @("evaluatesRuntimeNonPerfectSqrtInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: sqrt;

            unittest {
                double input = 2.0;
                double result = sqrt(input);
                assert(result > 1.414);
                assert(result < 1.415);
            }
        }, executorName);
    }

    @("evaluatesRuntimeFabsDoubleInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: fabs;

            unittest {
                double first = -3.5;
                double second = -12.25;
                assert(fabs(first) == 3.5);
                assert(fabs(second) == 12.25);
            }
        }, executorName);
    }

    @("evaluatesRuntimeFabsPositiveDoubleInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: fabs;

            unittest {
                double input = 7.75;
                assert(fabs(input) == 7.75);
            }
        }, executorName);
    }

    @("evaluatesRuntimeIsNaNDoubleInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: isNaN;

            unittest {
                double notANumber = double.nan;
                double finite = 21.0;

                assert(isNaN(notANumber));
                assert(!isNaN(finite));
            }
        }, executorName);
    }

    @("evaluatesRuntimeIsInfinityDoubleInput." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }

    @("evaluatesRuntimeSignbitDoubleInput." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }

    @("evaluatesRuntimeSignbitNanInput." ~ executorName.text)
    unittest {
        runTests(q{
            import std.math: signbit;

            unittest {
                double input = -double.nan;
                assert(signbit(input) != 0);

                input = double.nan;
                assert(signbit(input) == 0);
            }
        }, executorName);
    }

    @("doesNotTreatUserNamedIsNaNAsMathIntrinsic." ~ executorName.text)
    unittest {
        runTests(q{
            bool isNaN(double value) {
                return true;
            }

            unittest {
                double input = 21.0;
                assert(isNaN(input));
            }
        }, executorName);
    }

    @("callsUserNamedIsNaNForNanInput." ~ executorName.text)
    unittest {
        runTests(q{
            bool isNaN(double value) {
                return false;
            }

            unittest {
                double input = double.nan;
                assert(!isNaN(input));
            }
        }, executorName);
    }

    @("doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsics." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }
}

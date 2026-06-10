module ut.backends.runner.ct.expressions;


import ut.backends;
import dmd.target: CPU, target;


private void runSse2BackendSourceFixtureTests(T)(in string moduleSource) {
    const originalCpu = target.cpu;
    target.cpu = CPU.sse2;
    scope(exit) target.cpu = originalCpu;

    runBackendSourceFixtureTests!T(moduleSource);
}


/++
    Expression-specific assert diagnostics.

    Most ordinary `actual != expected` cases are covered elsewhere. Relational
    operators are worth keeping here because the failure messages encode the
    negated operator.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("assertDiagnostic.lessThan." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                assert(42 < bound);
            }
        }).shouldThrowWithMessage("42 >= 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("assertDiagnostic.lessOrEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                assert(43 <= bound);
            }
        }).shouldThrowWithMessage("43 > 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("assertDiagnostic.greaterThan." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                assert(42 > bound);
            }
        }).shouldThrowWithMessage("42 <= 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("assertDiagnostic.greaterOrEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                assert(41 >= bound);
            }
        }).shouldThrowWithMessage("41 < 42");
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("assertDiagnostic.notEqual." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                assert(42 != bound);
            }
        }).shouldThrowWithMessage("42 == 42");
    }
}


/++
    Integer arithmetic and bitwise operators.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.arithmeticOperators." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int divisor() {
                return 44;
            }

            unittest {
                // Keep at least one operand runtime-shaped so DMD does not
                // constant-fold these before the backend sees them.
                assert(one + 41 == 42);
                assert(44 - two == 42);
                assert(21 * two == 42);
                assert(84 / two == 42);
                assert(86 % divisor == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.shiftOperators." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int rightShift() {
                return 2;
            }

            int leftShift() {
                return 1;
            }

            unittest {
                assert(0x80 >> rightShift == 0x20);
                assert(0x10 << leftShift == 0x20);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.bitwiseOperators." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int orMask() {
                return 0x06;
            }

            int andMask() {
                return 0x2f;
            }

            int xorMask() {
                return 0x04;
            }

            unittest {
                assert((0x2a | orMask) == 0x2e);
                assert((andMask & 0x3a) == 0x2a);
                assert((0x2e ^ xorMask) == 0x2a);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.relationalOperators." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bound() {
                return 42;
            }

            unittest {
                assert(41 < bound);
                assert(42 <= bound);
                assert(43 > bound);
                assert(42 >= bound);
                assert(43 != bound);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.unaryOperators." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 42;
            }

            unittest {
                auto value = 0x2a;

                assert(-input == -42);
                assert(~value == -0x2b);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.assignmentOperators." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto orValue = 0x28u;
                orValue |= 0x02u;

                auto subtractValue = 44;
                subtractValue -= 2;

                auto addValue = 40;
                addValue += 2;

                assert(orValue == 0x2au);
                assert(subtractValue == 42);
                assert(addValue == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.commaExpressionSequencesOperands." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 2;
            }

            int answer() {
                int value = seed;
                value += 3, ++value;
                return value;
            }

            unittest {
                assert(answer == 6);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("int.postIncrementUsesRuntimeSeed." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 41;
            }

            unittest {
                int value = seed();
                int observed = value++;

                assert(observed == 41);
                assert(value == 42);
            }
        });
    }
}


/++
    Integer widths, wrapping, casts, and mixed numeric comparisons.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("integer.ubyteCastTruncatesRuntimeValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;

                assert(cast(ubyte) value == 2);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("integer.ubyteLocalTruncatesOnStore." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int source = 258;
                ubyte value = cast(ubyte) source;

                assert(value == 2);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("integer.ubyteAddAssignWrapsOnStore." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte value = 255;

                value += 1;

                assert(value == 0);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("integer.longLiteral." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long answer() {
                return 2_147_483_648L;
            }

            unittest {
                assert(answer > 0L);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("integer.ulongHighBitComparisonsUseUnsignedValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto value = 0x8070605040302010UL;

                assert(0UL < value);
                assert(0UL <= value);
                assert(value >= 0UL);
                assert(value > 0UL);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("integer.ulongDoubleComparisonUsesNumericUnsignedValue." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ulong integer = 0x8000_0000_0000_0000UL;
                double floating = 9_223_372_036_854_775_808.0;

                assert(integer == floating);
                assert(integer <= floating);
                assert(integer >= floating);
                assert(!(integer < floating));
                assert(!(integer > floating));
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("integer.floatEqualityIsNumeric." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                long integer = 0x3ff0_0000_0000_0000L;
                double floating = 1.0;

                assert(integer != floating);
            }
        });
    }
}


/++
    Floating-point, real, complex, and std.math expressions.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("floating.distinguishesFloatingPointValues." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double left = 1.5;
                double right = 2.5;

                assert(left != right);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("floating.evaluatesPow." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 8.0);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("floating.castsFloatingValueNumerically." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double input = 7.75;

                assert(cast(int) input == 7);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @ShouldFail(
        "DMD CTFE returns <float not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("floating.intToFloatCastUsesFloatPrecision." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int input = 16_777_217;
                float converted = cast(float) input;

                assert(converted == 16_777_216.0f);
                assert(converted != 16_777_217.0);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @ShouldFail(
        "DMD CTFE returns <real not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("floating.ulongToRealCastPreservesRealPrecision." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ulong input = ulong.max;
                real converted = cast(real) input;

                assert(converted == 18_446_744_073_709_551_615.0L);
                assert(converted != cast(real) cast(double) input);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("floating.realComparisonPreservesRealPrecision." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                real left = real.max;
                real right = real.infinity;

                assert(left < right);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("complex.literalWithRuntimeParts." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int input) {
                return input + 1;
            }

            unittest {
                auto base = value(41);
                cdouble packed = cast(cdouble) base + 1.0i;

                assert(packed.re == 42);
                assert(packed.im == 1);
            }
        });
    }
}


/++
    Typeid, virtual dispatch, interfaces, and delegates.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("typeid.classReferenceUsesDynamicClass." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {}
            class Child : Base {}

            int classify(int seed) {
                Base value = new Child;
                return typeid(value) is typeid(Child) ? seed + 4 : seed;
            }

            unittest {
                assert(classify(3) == 7);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("typeid.typeNameReturnsIdentifier." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Widget {}

            string typeName(int seed) {
                string name = typeid(Widget).name;
                return seed == name.length ? "" : name;
            }

            unittest {
                assert(typeName(0) == "Widget");
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("class.virtualCallUsesDynamicClass." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {
                int score() {
                    return 0;
                }
            }

            class Child : Base {
                int field;

                this(int field) {
                    this.field = field;
                }

                override int score() {
                    return field + 3;
                }
            }

            int classify(int seed) {
                Base value = new Child(seed + 4);
                return value.score;
            }

            unittest {
                assert(classify(5) == 12);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("interface.virtualCallUsesRuntimeDispatch." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            interface Speaker {
                int score();
            }

            class SpeakerImpl : Speaker {
                int scoreField;

                this(int seed) {
                    scoreField = seed;
                }

                int score() {
                    return scoreField + 1;
                }
            }

            int speak(int seed) {
                Speaker speaker = new SpeakerImpl(seed);
                return speaker.score();
            }

            unittest {
                assert(speak(41) == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("delegate.nestedCallUsesCapturedValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int apply(int seed) {
                int captured = seed + 2;

                int nested(int value) {
                    captured += value;
                    return captured;
                }

                int delegate(int) dg = &nested;

                return dg(5) + dg(1);
            }

            unittest {
                assert(apply(3) == 21);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("delegate.structMemberCallUsesReceiver." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int field;

                int value(int input) {
                    return field + input;
                }
            }

            int apply(int seed) {
                Counter counter = Counter(seed + 2);
                int delegate(int) dg = &counter.value;

                return dg(5);
            }

            unittest {
                assert(apply(3) == 10);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("delegate.ptrPropertyIsRejectedAtCtfe." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int runtimeSeed(int seed) {
                return seed + 1;
            }

            void* delegateContext(int seed) {
                int captured = runtimeSeed(seed);

                int nested() {
                    captured += 2;
                    return captured;
                }

                int delegate() dg = &nested;

                return dg.ptr;
            }

            unittest {
                auto context = delegateContext(3);

                assert(context is null);
            }
        }).shouldThrowWithMessage(
            "`dg.ptr` cannot be evaluated at compile time",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("delegate.funcptrPropertyIsRejectedAtCtfe." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int runtimeSeed(int seed) {
                return seed + 1;
            }

            int function() delegateFunction(int seed) {
                int captured = runtimeSeed(seed);

                int nested() {
                    captured += 2;
                    return captured;
                }

                int delegate() dg = &nested;

                return dg.funcptr;
            }

            unittest {
                auto funcptr = delegateFunction(3);

                assert(funcptr !is null);
            }
        }).shouldThrowWithMessage(
            "`dg.funcptr` cannot be evaluated at compile time",
        );
    }
}


/++
    Casts involving slices, pointers, arrays, and bool.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("cast.hexStringToUshortArrayUsesBigEndianWords." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ushort[] words = cast(ushort[]) x"12345678";

                assert(words.length == 2);
                assert(words[0] == 0x1234);
                assert(words[1] == 0x5678);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("cast.sliceToPointerDereferencesFirstElement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                auto tail = values[start .. $];
                int* p = cast(int*) tail;

                assert(*p == values[start]);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("cast.arrayPointerRoundTripsThroughVoidPointer." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1];
                int* original = &values[0];
                void* erased = cast(void*) original;
                int* restored = cast(int*) erased;

                assert(*restored == 41);
                assert(*(restored + 1) == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("cast.arrayElementAddressToStaticArrayPointer." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1, first + 2, first + 3];
                size_t start = cast(size_t) value(1);
                int[2]* window = cast(int[2]*) &values[start];

                assert((*window)[0] == 42);
                assert((*window)[1] == 43);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("cast.expTypePaintedSliceFromVoidPointer." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int step(int seed) {
                return seed + 1;
            }

            unittest {
                int[] values = [step(40), step(41)];
                void*[] erased = [
                    cast(void*) &values[0],
                    cast(void*) &values[1],
                ];
                int* recovered = cast(int*) erased[0];

                int index(int value) {
                    return value;
                }

                assert(*recovered == index(41));
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("cast.pointerToBoolReflectsNullness." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(41);
                int[] values = [first, first + 1];
                int* present = &values[0];
                int* missing = null;

                assert(cast(bool) present == true);
                assert(cast(bool) missing == false);
            }
        });
    }
}


/++
    Conditional expressions, `new`, pointer arithmetic, and vectors.
+/
static foreach (backend; AliasSeq!(Ctfe)) {
    @("conditional.nonNullPointerIsTrue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int classify(int seed) {
                int[] values = [seed, seed + 1];
                int* p = &values[0];

                return p ? *p + 1 : 0;
            }

            unittest {
                assert(classify(41) == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("new.scalarPointerDereferencesRuntimeValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 40;
                seed += 2;

                auto p = new int(seed);
                ++(*p);

                assert(*p == seed + 1);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("pointer.runtimeOffsetReadsElement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 41;
            }

            int readThroughOffsetPointer() {
                int[] values = [seed(), seed() + 1, seed() + 2, seed() + 3];
                int* offsetOne = values.ptr + 1;

                return *offsetOne + 1;
            }

            unittest {
                assert(readThroughOffsetPointer() == 43);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("pointer.runtimeDifferenceReadsElement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 41;
            }

            int readBehindPointerByOffset() {
                int[] values = [seed(), seed() + 1, seed() + 2];
                int* tail = &values[2];
                int* before = tail - 1;

                return *before + 1;
            }

            unittest {
                assert(readBehindPointerByOffset() == 43);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("vector.scalarCastSplatsToStaticArray." ~ backend.stringof)
    unittest {
        runSse2BackendSourceFixtureTests!backend(q{
            alias Int4 = __vector(int[4]);

            int seed(int value) {
                return value;
            }

            int[4] splat(int input) {
                int scalar = seed(input);
                Int4 vector = cast(Int4) scalar;

                return vector.array;
            }

            unittest {
                int[4] values = splat(7);

                assert(values[0] == 7);
                assert(values[1] == 7);
                assert(values[2] == 7);
                assert(values[3] == 7);
            }
        });
    }
}

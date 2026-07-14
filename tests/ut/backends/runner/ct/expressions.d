module ut.backends.runner.ct.expressions;


import ut.backends;
import dmd.target: CPU, target;
import std.algorithm.searching: canFind;
import std.exception: collectExceptionMsg;


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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("assertDiagnostic.lessThan." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("assertDiagnostic.lessOrEqual." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("assertDiagnostic.greaterThan." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("assertDiagnostic.greaterOrEqual." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("assertDiagnostic.notEqual." ~ backend.stringof)
    @Tags(backend.stringof)
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.arithmeticOperators." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Bytecode ("Unsupported expression `a % b`") and IR ("Unsupported IR
// expression `a % b`") do not implement %.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.moduloSignFollowsDividend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int dividend() {
                return -7;
            }

            int divisor() {
                return 3;
            }

            unittest {
                int a = dividend;
                int b = divisor;

                // The sign of % follows the dividend, not the divisor.
                assert(a % b == -1);
                assert(-a % b == 1);
                assert(a % -b == -1);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.shiftOperators." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Bytecode and IR ("Unsupported ... expression `v >> 28`") do not implement
// shifts.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.unsignedRightShiftZeroFills." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return -1;
            }

            unittest {
                int v = seed;

                // >> sign-extends, >>> zero-fills.
                assert((v >> 28) == -1);
                assert((v >>> 28) == 15);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.bitwiseOperators." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.relationalOperators." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.unaryOperators." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.assignmentOperators." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.commaExpressionSequencesOperands." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.postIncrementUsesRuntimeSeed." ~ backend.stringof)
    @Tags(backend.stringof)
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("integer.ubyteCastTruncatesRuntimeValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;

                assert(cast(ubyte) value == 2);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("integer.ubyteLocalTruncatesOnStore." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("integer.ubyteAddAssignWrapsOnStore." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("integer.longLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("integer.ulongHighBitComparisonsUseUnsignedValue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("integer.ulongDoubleComparisonUsesNumericUnsignedValue." ~
        backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("integer.floatEqualityIsNumeric." ~ backend.stringof)
    @Tags(backend.stringof)
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("floating.distinguishesFloatingPointValues." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("floating.evaluatesPow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.math: pow;

            unittest {
                assert(pow(2.0, 3.0) == 8.0);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("floating.castsFloatingValueNumerically." ~ backend.stringof)
    @Tags(backend.stringof)
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

// The Ctfe counterpart above is @ShouldFail due to a CTFE-formatter
// limitation; compiled code genuinely passes.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("floating.intToFloatCastUsesFloatPrecision." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Bytecode, SystemLinker, LLVMJit)) {
    @ShouldFail(
        "DMD CTFE returns <real not supported> because druntime's " ~
        "assert formatter uses sprintf",
    )
    @("floating.ulongToRealCastPreservesRealPrecision." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Interpreter)) {
    @("floating.ulongToRealCastPreservesRealPrecision." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("floating.realComparisonPreservesRealPrecision." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("complex.literalWithRuntimeParts." ~ backend.stringof)
    @Tags(backend.stringof)
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("typeid.classReferenceUsesDynamicClass." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Compiled typeid(T).name is the fully qualified name (snippet_N.Widget);
// only CTFE returns the bare identifier. The snippet module name varies per
// run, so match the stable suffix of the failure message.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("typeid.typeNameReturnsIdentifier." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const message = collectExceptionMsg!Exception(
            runBackendSourceFixtureTests!backend(q{
                class Widget {}

                string typeName(int seed) {
                    string name = typeid(Widget).name;
                    return seed == name.length ? "" : name;
                }

                unittest {
                    assert(typeName(0) == "Widget");
                }
            }));

        message.canFind(`.Widget" != "Widget"`).should == true;
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("class.virtualCallUsesDynamicClass." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("interface.virtualCallUsesRuntimeDispatch." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("delegate.nestedCallUsesCapturedValue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("delegate.structMemberCallUsesReceiver." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Compiled dg.ptr is the (non-null) closure context pointer, so the
// `context is null` assertion fails; the Ctfe rejection above is CTFE-only.
// The pointer value varies per run, so match the stable suffix of the
// message.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("delegate.ptrPropertyReturnsClosureContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const message = collectExceptionMsg!Exception(
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
            }));

        message.canFind("!is `null`").should == true;
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

// Compiled dg.funcptr is a plain (non-null) function pointer, so the fixture
// passes; the Ctfe rejection above is CTFE-only.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("delegate.funcptrPropertyReturnsFunctionPointer." ~ backend.stringof)
    @Tags(backend.stringof)
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
        });
    }
}


/++
    Casts involving slices, pointers, arrays, and bool.
+/
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.hexStringToUshortArrayUsesBigEndianWords." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.sliceToPointerDereferencesFirstElement." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.arrayPointerRoundTripsThroughVoidPointer." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.arrayFieldPointerDereferencesFirstElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                ubyte[] values;
            }

            ubyte readArrayFieldThroughPointerCast() {
                auto holder = new Holder;
                holder.values.length = 1;
                holder.values[0] = 42;
                auto pointer = cast(ubyte*) holder.values;
                return *pointer;
            }

            unittest {
                assert(readArrayFieldThroughPointerCast() == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.arrayFieldPtrSliceUsesResizedLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                ubyte[] values;
            }

            struct Appender {
                Holder* holder;

                ubyte readArrayFieldPointerSlice() {
                    holder = new Holder;
                    holder.values.length = 1;
                    holder.values = holder.values[0 .. 0];
                    immutable len = holder.values.length;
                    auto slice = (() => holder.values.ptr[0 .. len + 1])();
                    slice[len] = 42;
                    holder.values = slice;
                    return slice[0];
                }
            }

            unittest {
                auto appender = Appender();
                assert(appender.readArrayFieldPointerSlice() == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.arrayFieldPtrSliceElementAddressWritesValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.lifetime: emplace;

            struct Holder {
                ubyte[] values;
            }

            struct Appender {
                Holder* holder;

                ubyte appendByte(ubyte item) {
                    holder = new Holder;
                    holder.values.length = 1;
                    holder.values = holder.values[0 .. 0];
                    immutable len = holder.values.length;
                    auto slice = (() => holder.values.ptr[0 .. len + 1])();
                    auto itemUnqual = (() => &cast() item)();
                    emplace(&slice[len], *itemUnqual);
                    holder.values = slice;
                    return holder.values[0];
                }
            }

            unittest {
                auto appender = Appender();
                assert(appender.appendByte(42) == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.arrayElementAddressToStaticArrayPointer." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.expTypePaintedSliceFromVoidPointer." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("cast.pointerToBoolReflectsNullness." ~ backend.stringof)
    @Tags(backend.stringof)
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("conditional.nonNullPointerIsTrue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("new.scalarPointerDereferencesRuntimeValue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("pointer.runtimeOffsetReadsElement." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("pointer.runtimeDifferenceReadsElement." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Dereferencing a pointer cast to a *different, same-size* type than the
// local it points to (grainReinterpret's shape) does not get an implicit
// promoting cast inserted by DMD's frontend, unlike every other operator
// context; the interpreter itself must reinterpret the raw bits. `dchar` (4
// bytes, already "int-rank") is the necessary representative of the
// char/wchar/dchar family: a 1-byte `char`/`ubyte*` version does not repro,
// because DMD inserts an extra implicit `int` promotion for sub-`int`-sized
// operands in compound-assignment lowering that re-masks the bug.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("pointer.dcharCompoundAssignThroughUintPointerIsIntegerCompatible." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                dchar c = cast(dchar) 0x41;
                uint* p = cast(uint*) &c;
                *p >>= 1;
                assert(c == cast(dchar) 0x20);
            }
        });
    }
}

// D's right-shift compound assignment on an unsigned pointee is a logical
// shift, including when the pointee is reached through a raw pointer.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("pointer.uintCompoundRightShiftIsLogical." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                uint value = 0x8000_0000;
                uint* p = &value;
                *p >>= 1;
                assert(value == 0x4000_0000);
            }
        });
    }
}

// IR (AssertError in compiler.d, valueType) does not support taking the
// address of a local or this compound-assignment shape.

// Same reinterpret-load shape as above, but reading (not writing) the raw
// bits of a `float` local through a same-size `uint*` cast. Ctfe has no
// byte-level memory model for floating-point locals and permanently refuses
// `cast(uint*)&floatLocal`, so it is omitted here (unlike the dchar/uint
// fixture above, where Ctfe does support same-size integer-family pointer
// reinterpretation).
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("pointer.floatBitsThroughUintPointerAreRawBits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                float f = 1.5f;
                uint* p = cast(uint*) &f;
                uint bits = *p;
                assert(bits == 0x3FC00000);
            }
        });
    }
}

// Bytecode and IR ("Unsupported (IR) expression `& f`") do not support
// taking the address of a local.

// Same as above for `double`/`ulong*`.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("pointer.doubleBitsThroughUlongPointerAreRawBits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double d = 1.5;
                ulong* p = cast(ulong*) &d;
                ulong bits = *p;
                assert(bits == 0x3FF8000000000000UL);
            }
        });
    }
}

// Bytecode and IR ("Unsupported (IR) expression `& d`") do not support
// taking the address of a local.

// Reinterpret-WRITE (not read) through a same-size pointer cast: writing raw
// bits into a `float` local via a `uint*` must be visible to a subsequent
// direct read of the local. SystemLinker is the oracle; LLVMJit and Ctfe are
// omitted per the omit-don't-pin convention (address-of-a-local and float
// byte-reinterpretation are unconfirmed/unsupported there).
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker)) {
    @("pointer.uintBitsWrittenThroughPointerReadBackAsFloat." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint oneBits() {
                return 0x3F800000;
            }

            float twoPointZero() {
                return 2.0f;
            }

            unittest {
                float f = twoPointZero;
                uint* p = cast(uint*) &f;
                *p = oneBits;
                assert(f == 1.0f);
            }
        });
    }
}

// Same reinterpret-write, but through a pointer passed across a call: the
// callee writes raw bits into the caller's `float` local via a `uint*`
// parameter. The caller must observe the write after the call returns.
// SystemLinker is the oracle; other backends omitted for the same reasons as
// the fixture above.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.crossFrameUintBitsWrittenThroughPointerReadBackAsFloat." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint oneBits() {
                return 0x3F800000;
            }

            float twoPointZero() {
                return 2.0f;
            }

            void writeBits(uint* p, uint bits) {
                *p = bits;
            }

            unittest {
                float f = twoPointZero;
                writeBits(cast(uint*) &f, oneBits);
                assert(f == 1.0f);
            }
        });
    }
}

// Once `&f` promotes an authoritative native-scalar cell (value.md item 7),
// a later DIRECT reassignment (`f = threePointZero`, not a pointer write)
// must keep that cell current too: both the direct read of `f` and a read
// through the pointer must see the new value's bits, not the stale ones from
// before the reassignment. SystemLinker is the oracle; other backends
// omitted per the omit-don't-pin convention (address-of-a-local is
// unconfirmed/unsupported there).
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker)) {
    @("pointer.directWriteToAddressTakenScalarUpdatesCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            float twoPointZero() {
                return 2.0f;
            }

            float threePointZero() {
                return 3.0f;
            }

            unittest {
                float f = twoPointZero;
                uint* p = cast(uint*) &f;
                f = threePointZero;
                assert(f == 3.0f);
                assert(*p == 0x40400000);
            }
        });
    }
}

// Reinterpret-WRITE through a pointer taken from a `ref` scalar parameter:
// the callee writes raw bits into the parameter's slot via a same-size
// pointer cast, and the CALLER's variable (bound to that `ref` parameter)
// must observe the write after the call returns. This is the guest-level
// call-site frontier of value.md item 7: a freshly promoted native cell for
// the `ref` parameter must stay connected to the caller's own cell/box.
// SystemLinker is the oracle; other backends omitted per the omit-don't-pin
// convention (address-of-a-local/parameter and float byte-reinterpretation
// are unconfirmed/unsupported there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.reinterpretWriteThroughRefParameterPointerReachesCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint oneBits() {
                return 0x3F800000;
            }

            float twoPointZero() {
                return 2.0f;
            }

            void writeThroughRef(ref float f, uint bits) {
                uint* p = cast(uint*) &f;
                *p = bits;
            }

            unittest {
                float x = twoPointZero;
                writeThroughRef(x, oneBits);
                assert(x == 1.0f);
            }
        });
    }
}

// Finding 1 (value.md item 7 review): a fresh `DeclarationExp` binding is a
// new stack slot, but the interpreter never dropped a stale `scalarCells`
// entry inherited for the same `VarDeclaration`. Recursion reuses the same
// AST `VarDeclaration` for `x` at every call depth, and `child.scalarCells =
// scalarCells.dup` hands the inner frame the outer frame's already-promoted
// cell, so `int x = depth;` at depth 0 resurrected depth 1's cell instead of
// getting a fresh one. SystemLinker is the oracle; other backends omitted
// per the omit-don't-pin convention (address-of-a-local is
// unconfirmed/unsupported there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.recursiveDeclarationDropsStaleScalarCell." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int rec(int depth) {
                int x = depth;
                int* p = &x;
                if (depth == 0)
                    return *p;
                const inner = rec(depth - 1);
                return x * 10 + inner;
            }

            unittest {
                assert(rec(1) == 10);
            }
        });
    }
}

// Same Finding 1 bug, loop-shaped: a `foreach` body re-executes the same
// `DeclarationExp` for `x` every iteration, so the first iteration's
// promoted cell must not leak into the second iteration's fresh `x`.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.loopRedeclaredLocalDropsStaleScalarCell." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int tenTimes(int i) {
                return i * 10;
            }

            unittest {
                foreach (i; 0 .. 2) {
                    int x = tenTimes(i);
                    int* p = &x;
                    assert(*p == tenTimes(i));
                }
            }
        });
    }
}

// Finding 2 (value.md item 7 review): post-increment's `VarExp` arm read
// `variable in locals` directly, bypassing a promoted `scalarCells` entry --
// stale once a cross-frame pointer write (`setToFive`) refreshes only the
// cell.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.postIncrementReadsPromotedScalarCell." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            uint twoValue() {
                return 2;
            }

            void setToFive(uint* p) {
                *p = 5;
            }

            unittest {
                uint i = twoValue;
                setToFive(&i);
                i++;
                assert(i == 6);
            }
        });
    }
}

// Finding 3 (value.md item 7 review): `(*p)++` reads and writes through
// `localPointerTarget`/`writePointerTarget`'s local-pointer arm, which only
// consulted the boxed `locals` mirror -- the same bypass post-increment's
// `VarExp` arm had, but for the pointer-deref path.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker)) {
    @("pointer.dereferencedPointerPostIncrementUsesPromotedScalarCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int twoValueInt() {
                return 2;
            }

            unittest {
                int i = twoValueInt;
                int* p = &i;
                (*p)++;
                assert(i == 3);
            }
        });
    }
}

// Finding 5 (value.md item 7 review): `writeLocation`'s `PtrExp` cell arm
// required the pointee to be exactly the cell's own width, throwing for a
// narrower native-scalar pointee (a `ubyte*` reinterpret of a `uint`)
// instead of writing into the low bytes the way the read side
// (`reinterpretLocalPointerLoad`) already narrows by slicing.
static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker)) {
    @("pointer.subWordReinterpretWriteThroughPointerWritesLowByte." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte oneByte() {
                return 0xAB;
            }

            unittest {
                uint u = 0;
                ubyte* p = cast(ubyte*) &u;
                *p = oneByte;
                assert(u == 0xAB);
            }
        });
    }
}

// Finding 1 (value.md item 7 review): `&g` on a dataseg variable (module-
// level/`__gshared`/`static`) routed through `promoteScalarCell`, which
// seeded the cell from `defaultValue` (0) because a dataseg variable's real
// initializer is materialized lazily on first read, and the `VarExp` read
// arm consulted the cell before that fallback -- so taking `gValue`'s
// address made every later read of `gValue` see 0 instead of 42. Only true
// stack locals get cells; dataseg variables keep their own
// storage/initializer/extern machinery.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.addressOfDatasegGlobalDoesNotShadowInitializer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            __gshared int gValue = 42;

            unittest {
                auto p = &gValue;
                assert(gValue == 42);
            }
        });
    }
}

// Finding 2 (value.md item 7 review): once `&i` has promoted a native-scalar
// cell, `writeLocation`'s `PtrExp` arm required the pointee to be a
// native-scalar type no wider than the cell; a struct-typed (or wider)
// pointee used to fall through to a mirror-only `locals` write, leaving the
// cell stale, so a later direct read of `i` (which consults the cell first)
// silently returned the OLD value instead of the struct just written.
// SystemLinker is the oracle for the write itself (real memory supports it);
// the Interpreter cannot yet model a struct-typed write into a scalar cell
// (future work), so Interpreter is omitted from this matrix per the
// omit-don't-pin convention and separately asserted below to fail loudly
// instead of silently miswriting.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("pointer.structWriteThroughNonFittingScalarCellPointerWritesMemory." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S { int a; }

            int seven() {
                return 7;
            }

            unittest {
                int i = seven;
                S* p = cast(S*) &i;
                *p = S(42);
                assert(i == 42);
            }
        });
    }
}

// The Interpreter counterpart of the fixture above: it cannot model a
// struct-typed write into a promoted scalar cell, so it must fail loudly
// rather than silently leave the cell stale and read back `i`'s old value.
static foreach (backend; AliasSeq!(Interpreter)) {
    @("pointer.structWriteThroughNonFittingScalarCellPointerThrowsLoudly." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S { int a; }

            int seven() {
                return 7;
            }

            unittest {
                int i = seven;
                S* p = cast(S*) &i;
                *p = S(42);
                assert(i == 42);
            }
        }).shouldThrowWithMessage("Unsupported interpreter assignment target.");
    }
}

// value.md item 7's array-native-storage guest call site: `&a[0]` takes a
// pointer into a dynamic array local, then the array is written DIRECTLY
// (`a[0] = ...`, not through the pointer). SystemLinker's `p` aliases `a`'s
// real storage, so the direct write is visible through `*p`. Other backends
// omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.arrayElementWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[] a = [one(), two()];
                int* p = &a[0];
                a[0] = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// value.md item 7's write-side counterpart of the fixture above: a write
// THROUGH one pointer into a dynamic array element must be visible through a
// SECOND, independently-taken pointer into the same element. SystemLinker's
// `p`/`q` both alias `a`'s real storage, so a write through `p` is visible
// through `q`. Other backends omitted per the omit-don't-pin convention
// (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.arrayElementWrittenThroughPointerIsVisibleThroughSecondPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[] a = [one(), two()];
                int* p = &a[0];
                int* q = &a[0];
                *p = ninetyNine();
                assert(*q == 99);
            }
        });
    }
}

// value.md item 7 candidate slice: `foreach (ref e; a)` mutation must be
// visible through an earlier-taken pointer into `a`. SystemLinker's `p`
// aliases `a`'s real storage, so the loop's writes are visible through `*p`.
// Other backends omitted per the omit-don't-pin convention (unconfirmed
// there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.arrayElementWrittenByForeachRefIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[] a = [one(), two()];
                int* p = &a[0];
                foreach (ref e; a)
                    e = e + ninetyNine();
                assert(*p == 1 + 99);
            }
        });
    }
}

// value.md item 7 candidate slice: a compound/post-increment write THROUGH an
// array-element pointer (`(*p)++`) must be visible both through the pointer
// itself and directly on the array. SystemLinker's `p` aliases `a`'s real
// storage, so the increment is visible both ways. Other backends omitted per
// the omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.arrayElementPostIncrementedThroughPointerIsVisibleDirectly." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            unittest {
                int[] a = [one(), two()];
                int* p = &a[0];
                (*p)++;
                assert(a[0] == 2 && *p == 2);
            }
        });
    }
}

// value.md item 7's cross-frame array-pointer aliasing candidate: a callee
// takes `&a[i]` of a caller's array passed by `ref` and writes through it.
// SystemLinker's `ref` parameter aliases the caller's real storage, so `p`
// (taken in the caller BEFORE the call, into the SAME backing array) must
// see the write too. Other backends omitted per the omit-don't-pin
// convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.arrayElementWrittenThroughRefParameterPointerVisibleToEarlierCallerPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            void bump(ref int[] a) {
                int* q = &a[0];
                *q = ninetyNine();
            }

            unittest {
                int[] a = [one(), two()];
                int* p = &a[0];
                bump(a);
                assert(*p == 99 && a[0] == 99);
            }
        });
    }
}

// value.md item 7 candidate: a pointer taken into a SLICE (not the source
// array itself) must still see a later direct write to the source. This is
// a genuine characterization test, not a gap fixture: `promoteSliceArrayCell`
// already gives a slice local an `arrayCells` entry sharing the SAME
// `NativeArray` bytes as its root source's own cell (`promoteArrayCell`
// keyed by the slice-alias-resolved root, exactly as `arrayPointer`'s own
// `&a[i]` resolution already does), so `&s[1]` promotes/reads that shared
// cell directly -- confirmed green on Interpreter with no production change
// alongside this fixture. SystemLinker's `p` aliases `a`'s real storage, so
// the direct write is visible through `*p`. Other backends omitted per the
// omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.arrayElementWrittenDirectlyIsVisibleThroughPointerIntoEarlierSlice." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int three() {
                return 3;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[] a = [one(), two(), three()];
                int[] s = a[];
                int* p = &s[1];
                a[1] = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// value.md item 7's struct phase, first guest call site: `&s.x` snapshotted
// the field's value at address-of time instead of aliasing `s`'s own
// storage, so a later direct write to the field (`s.x = ninetyNine()`) was
// invisible through the earlier pointer -- the same snapshot gap the array
// phase closed for `&a[i]`. SystemLinker's `p` aliases `s`'s real storage, so
// the direct write is visible through `*p`. Other backends omitted per the
// omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.structFieldWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
                int y;
            }

            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                S s = S(one(), two());
                int* p = &s.x;
                s.x = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// `&value` of a `ref` parameter is emitted by DMD as AddrExp(VarExp), not the
// SymOffExp produced for a plain local; the interpreter must take the address
// of the parameter's slot.  cerealed's grainReinterpret(ref T) hits this.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("pointer.addressOfRefParameterReadsThroughPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int readThroughRefPointer(ref int value) {
                int* p = &value;
                return *p;
            }

            unittest {
                int seed = 41;
                seed += 1;

                assert(readThroughRefPointer(seed) == 42);
            }
        });
    }
}

// `&call()` of a ref-returning function is AddrExp(CallExp); the interpreter
// must run the call and yield the address of the returned lvalue, aliasing
// the caller's argument so writes through the pointer stick.  automem's
// vector tests hit this on every `theAllocator` fetch.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
    @("pointer.addressOfRefReturningCallAliasesArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ref int self(ref int x) { return x; }

            unittest {
                int i = 1;
                int* p = &self(i);
                *p = 42;
                assert(i == 42);
                assert(*p == 42);
            }
        });
    }
}

// A ref-returning ternary lowers to `*(cond ? &a : &fallback(b))`, so even
// reading the call as an rvalue evaluates AddrExp(CallExp).  phobos'
// `theAllocator` (`!p.isNull() ? p : setupThreadAllocator()`) is this shape.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
    @("pointer.refTernaryReturnLowersToAddressOfCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ref int fallback(ref int b) { return b; }
            ref int pick(bool first, ref int a, ref int b) {
                return first ? a : fallback(b);
            }

            unittest {
                int x = 1;
                int y = 2;
                assert(pick(false, x, y) == 2);
                assert(pick(true, x, y) == 1);
            }
        });
    }
}

// `&struct.field` is AddrExp(DotVarExp); until now only a static-array field
// was handled (arrayPointer), so any other field type fell through to the
// generic unsupported-expression throw.  cerealed's pointer roundtrip test
// (`struct.with.class.reference`) hits this taking the address of a decoded
// struct's class-reference field to assert it is a distinct object from the
// original.  Ctfe omitted: DMD CTFE genuinely refuses to convert a struct
// field's address for pointer-identity comparison at compile time
// (`cannot cast '&Holder(7).value' to 'ulong' at compile time`), not a gap
// to close here.  Bytecode omitted: AddrExp of a DotVarExp is not
// implemented there yet (still under active development).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("pointer.addressOfStructFieldIsDistinctAcrossInstances." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int value;
            }

            unittest {
                int seed = 7;
                auto a = Holder(seed);
                auto b = Holder(seed);

                int* pa = &a.value;
                int* pb = &b.value;

                assert(pa !is pb);
                assert(*pa == seed);
                assert(*pb == seed);
            }
        });
    }
}

// Rung 7 review finding: addressOfExpression's DotVarExp branch minted a
// fresh `++allocationCount` identity on *every* evaluation of `&s.field`, so
// re-taking the same field's address gave a different identity each time
// (`&a.value !is &a.value`) — real D gives the same address back. Fixed by
// memoizing the allocation id per (receiver variable, field index). Ctfe
// omitted: DMD CTFE genuinely refuses this construct at compile time.
// Bytecode omitted: AddrExp of a DotVarExp is not implemented there yet.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("pointer.addressOfStructFieldIsStableAcrossReEvaluation." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int value;
            }

            int seed() {
                return 7;
            }

            unittest {
                auto a = Holder(seed);
                int* p = &a.value;

                assert(p is &a.value);
                assert(*p == 7);
            }
        });
    }
}

// Rung 7 review finding, sibling of the identity fix above: writing through
// a `&s.field` pointer used to silently write into the pointer's own
// throwaway value snapshot instead of `s`'s storage, losing the write with
// no diagnostic. SystemLinker pins real D's actual (aliasing) write-through
// behaviour.
//
// Promoted 2026-07-14 (value.md item 7's struct phase, write-through-pointer
// slice): `Holder` has exactly one scalar field of a plain struct LOCAL,
// address-taken via `&a.value` -- precisely the case the `structCells`
// native cell (already promoted at address-of time) now supports end to
// end. The Interpreter used to refuse this write outright
// (`shouldThrowWithMessage("Unsupported interpreter assignment target.")`,
// characterizing the pre-cell limitation); now it writes through the same
// cell exactly like SystemLinker's real aliasing, so both backends assert
// the SAME value and share one fixture rather than a throw pinned only for
// Interpreter.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.addressOfStructFieldWriteThroughUpdatesField." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int value;
            }

            int seed() {
                return 7;
            }

            unittest {
                auto a = Holder(seed);
                int* p = &a.value;
                *p = 5;

                assert(a.value == 5);
            }
        });
    }
}

// value.md item 7 review, finding 1, extended to arrays: the same
// stale-cell bug `pointer.recursiveDeclarationDropsStaleScalarCell` names
// for `scalarCells`, but for `arrayCells`. Recursion reuses the same AST
// `VarDeclaration` for `a` at every call depth, and `child.arrayCells =
// arrayCells.dup` hands the inner frame the outer frame's already-promoted
// cell (shared by reference); without dropping it on `a`'s fresh
// re-declaration at the inner depth, `&a[0]` there resurrects the outer
// depth's stale cell instead of getting a fresh one for its own (shorter,
// differently-valued) array. SystemLinker is the oracle; other backends
// omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.recursiveArrayDeclarationDropsStaleArrayCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int hundred() {
                return 100;
            }

            int rec(int depth) {
                int[] a = depth == 0 ? [hundred()] : [one(), two()];
                int* p = &a[0];
                if (depth == 0)
                    return *p;
                const inner = rec(depth - 1);
                return a[0] * 1000 + inner;
            }

            unittest {
                assert(rec(1) == 1100);
            }
        });
    }
}

// Struct sibling of the fixture above: the same stale-cell bug for
// `structCells`. Recursion reuses the same AST `VarDeclaration` for `s` at
// every call depth, and `child.structCells = structCells.dup` hands the
// inner frame the outer frame's already-promoted cell; without dropping it
// on `s`'s fresh re-declaration at the inner depth, `&s.x` there resurrects
// the outer depth's stale cell instead of getting a fresh one for its own
// struct value. The per-depth value is computed by a helper (`valueForDepth`)
// rather than a ternary directly in the struct initializer, since dmd lowers
// a struct-typed ternary initializer to a default-init-then-assignment,
// which happens to route through the existing in-place `writeCelledLocal`
// refresh and masks this particular gap. SystemLinker is the oracle; other
// backends omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.recursiveStructDeclarationDropsStaleStructCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
            }

            int one() {
                return 1;
            }

            int hundred() {
                return 100;
            }

            int valueForDepth(int depth) {
                return depth == 0 ? hundred() : one();
            }

            int rec(int depth) {
                S s = S(valueForDepth(depth));
                int* p = &s.x;
                if (depth == 0)
                    return *p;
                const inner = rec(depth - 1);
                return s.x * 1000 + inner;
            }

            unittest {
                assert(rec(1) == 1100);
            }
        });
    }
}

// Final-review finding 3 (BLOCKER): `allocationId`/`fieldSnapshotAllocationId`
// memoize their id per `VarDeclaration` and were never removed alongside the
// cell drop the two fixtures above already exercise, so a pointer minted at
// an OUTER recursion depth and passed DOWN into a call that re-declares the
// same `VarDeclaration` still carries the OLD id -- which, in the inner
// frame, now resolves (via `arrayAllocationVariables`) into whatever cell
// the inner re-declaration just promoted for ITSELF, instead of declining to
// the outer pointer's own frozen snapshot. SystemLinker (real aliased
// storage) returns 207; before any production change Interpreter returned
// 107, the inner depth's own unrelated value. SystemLinker is the oracle;
// other backends omitted per the omit-don't-pin convention (unconfirmed
// there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.recursiveArrayPointerPassedAcrossRebindDereferencesOuterValue." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seven() {
                return 7;
            }

            int zero() {
                return 0;
            }

            int f(int depth, int* p) {
                int[] a = [depth * 100 + seven(), zero()];
                int* q = &a[0];
                if (depth == 2)
                    return f(1, q);
                return *p;
            }

            unittest {
                assert(f(2, null) == 207);
            }
        });
    }
}

// Struct sibling of the fixture above: the same stale-id bug for
// `fieldSnapshotAllocationId`/`structFieldPointerVariables`.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.recursiveStructFieldPointerPassedAcrossRebindDereferencesOuterValue." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
            }

            int seven() {
                return 7;
            }

            int g(int depth, int* p) {
                S s = S(depth * 100 + seven());
                int* q = &s.x;
                if (depth == 2)
                    return g(1, q);
                return *p;
            }

            unittest {
                assert(g(2, null) == 207);
            }
        });
    }
}

// Crash twin of the same finding: the outer pointer indexes past the END of
// the inner (shorter) re-declared array. Before any production change,
// Interpreter resolved the stale outer id into the inner frame's own
// (shorter) cell and threw `NativeArray.element: index out of range`
// instead of declining to the outer pointer's own frozen (in-range)
// snapshot.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.recursiveArrayPointerPassedAcrossShorterRebindDoesNotCrash." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int three() {
                return 3;
            }

            int four() {
                return 4;
            }

            int ninetyNine() {
                return 99;
            }

            int h(int depth, int* p) {
                int[] a = depth == 2
                    ? [one(), two(), three(), four()]
                    : [ninetyNine()];
                int* q = &a[depth == 2 ? 3 : 0];
                if (depth == 2)
                    return h(1, q);
                return *p;
            }

            unittest {
                assert(h(2, null) == 4);
            }
        });
    }
}

// Final-review finding 4 (SHOULD-FIX): `structFieldPointerVariables`/
// `FieldIndices` are copied back wholesale after a call returns. A
// recursive callee's own fresh `S s = ...;` re-declaration drops the
// reverse-lookup entry for `s` from the CALLEE's own (duped) copy via
// `dropStructCell` -- even though the callee here never itself re-takes
// `&s.x` -- and the wholesale replace then adopts the callee's
// (now-missing-the-entry) map wholesale, discarding the CALLER's own
// still-live entry for its own `s`/`p`. Before any production change,
// Interpreter's `*p = 42;` after the call returns did not take effect (the
// write silently declined), so `*p + s.x` read back the pre-write value
// instead of the correct post-write one.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.structFieldPointerWriteThroughSurvivesSiblingRecursionReturn." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
            }

            int seven() {
                return 7;
            }

            int three() {
                return 3;
            }

            int fortyTwo() {
                return 42;
            }

            int f(int depth) {
                S s = S(depth == 1 ? seven() : three());
                if (depth == 1) {
                    int* p = &s.x;
                    f(0);
                    *p = fortyTwo();
                    return *p + s.x;
                }
                return 0;
            }

            unittest {
                assert(f(1) == 84);
            }
        });
    }
}

// value.md item 7's struct phase left cross-frame struct-field-pointer
// write-through unexercised: the caller takes `&s.x` (promoting a
// `structCells` entry and a `structFieldPointerVariables`/
// `structFieldPointerFieldIndices` reverse-lookup entry in the CALLER's own
// frame), then passes the pointer into a callee that writes through it. The
// callee's own child `Walker` dupes `structCells` (so the cell's bytes are
// shared) but never dupes the reverse-lookup maps themselves, so the
// callee's `writeThroughStructFieldPointer` reverse-lookup misses and the
// write falls through to the `fieldSnapshotAllocationIds` refusal check
// (also duped) instead of aliasing. SystemLinker is the oracle; other
// backends omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.structFieldWriteThroughPointerInCalleeIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
                int y;
            }

            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            void put(int* p, int v) {
                *p = v;
            }

            int f() {
                S s = S(one(), two());
                int* p = &s.x;
                put(p, ninetyNine());
                return *p + s.x;
            }

            unittest {
                assert(f() == 198);
            }
        });
    }
}

// Regression sibling of the refusal fixture above: a `new`-with-user-ctor
// child `Walker` (both the struct and class variants in
// `runNewStructPointerExpression`/`runNewClassExpression`) restarted
// `allocationCount` at 0 instead of seeding it from the parent, and never
// merged it (or `fieldAddressAllocations`/`fieldSnapshotAllocationIds`) back.
// A pointer minted inside such a ctor could numerically collide with an
// already-live field-snapshot id from an unrelated `&s.field`, so a later
// legitimate write through it was wrongly refused as an aliasing write.
// Ctfe/Bytecode omitted: `new`-with-user-ctor pointer indirection through a
// class field is not exercised on those backends yet (unrelated gaps, not
// this fix). LLVMJit omitted: allocation ids are an Interpreter-only
// bookkeeping detail with no compiled-code analogue to pin.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.newCtorPointerWriteNotRefusedAfterFieldAddress." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct H {
                int v;
            }

            class C {
                int* q;

                this(int x) {
                    q = new int;
                    *q = x;
                }
            }

            int seven() {
                return 7;
            }

            unittest {
                auto h = H(seven);
                int* p0 = &h.v;
                auto c = new C(0);
                *c.q = 5;
                assert(*c.q == 5);
            }
        });
    }
}

// `new Struct(args)` for a struct with no user-defined constructor (the
// aggregate-initialiser branch of `runNewStructPointerExpression`) returned
// `Value.pointerValue(structVal)`, which never assigns an allocation id —
// every such pointer carries the same all-zero `(allocation, offset)` pair,
// so two independently-`new`-allocated pointers with equal field contents
// compared equal by content instead of by identity.  cerealed's
// `struct.pointer` test (`decOuter.inner.shouldNotEqual(outer.inner)`) hits
// this: the decoded pointer and the original both allocate a fresh
// `InnerStruct` via a bodyless-constructor-free `new`, and both landed on
// allocation id 0.  Bytecode omitted: dereferencing a struct pointer (`*a`)
// is not implemented there yet (still under active development).
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
    @("pointer.newStructPointersWithEqualContentAreDistinct." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int value;
            }

            unittest {
                int seed = 7;
                auto a = new Inner(seed);
                auto b = new Inner(seed);

                assert(a !is b);
                assert(*a == *b);
            }
        });
    }
}

// A ref-returning call as the *assignment target* (`f(i) = v`) must run the
// callee and write through the returned lvalue, aliasing the caller's
// argument.  automem's vector tests hit this shape 10× as
// `Unsupported interpreter assignment target: call`.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
    @("refCall.assignmentToRefReturningCallWritesArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ref int self(ref int x) { return x; }

            unittest {
                int i = 1;
                self(i) = 42;
                assert(i == 42);
            }
        });
    }
}

// A ref-returning ternary as assignment target: the return lowers to
// `*(cond ? &a : &fallback(b))`, so the write must land on whichever branch
// actually ran — phobos' `theAllocator = x` family is this shape.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
    @("refCall.assignmentToRefTernaryReturnWritesChosenBranch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ref int fallback(ref int b) { return b; }
            ref int pick(bool first, ref int a, ref int b) {
                return first ? a : fallback(b);
            }

            unittest {
                int x = 1;
                int y = 2;

                pick(false, x, y) = 42;
                assert(x == 1);
                assert(y == 42);

                pick(true, x, y) = 7;
                assert(x == 7);
                assert(y == 42);
            }
        });
    }
}

// Assigning through a member ref-return must run the callee's body — not
// just locate its return expression — so pre-return side effects happen
// exactly once and the executed return (not the textually first) picks the
// lvalue.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)) {
    @("refCall.assignmentToMemberRefReturnRunsCalleeBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int value;
                int calls;
                ref int slot() { ++calls; return value; }
            }

            unittest {
                Counter counter;
                counter.slot() = 42;
                assert(counter.value == 42);
                assert(counter.calls == 1);
            }
        });
    }
}

// `new S` of a struct with a dynamic-array field passes the field's `null`
// default initialiser as a positional argument; the interpreter must store it
// as an empty array so a null array's `.length` is 0 (compiled D:
// `(new S).arr.length == 0`).  cerealed's Appender (`new Data` then
// `_data.arr.length`) hits this.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("new.heapStructArrayFieldHasZeroLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int[] values;
            }

            size_t heapStructArrayLength() {
                auto holder = new Holder;
                return holder.values.length;
            }

            unittest {
                assert(heapStructArrayLength() == 0);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("struct.defaultInitPreservesExplicitFieldInitializers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Header {
                ubyte tag = 7;
                int code = 42;
            }

            unittest {
                auto header = Header.init;

                assert(header.tag == 7);
                assert(header.code == 42);
            }
        });
    }
}

// Resizing a dynamic-array field through a struct pointer
// (`_data.arr.length = n`) must rebuild the array with default-initialised
// elements; the lvalue is a field access, not a plain local.  cerealed's
// Appender.ensureAddable hits this under CTFE-style execution.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("new.heapStructArrayFieldGrowsByLengthAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int[] values;
            }

            size_t growHeapStructArray() {
                auto holder = new Holder;
                holder.values.length = 3;
                return holder.values.length;
            }

            unittest {
                assert(growHeapStructArray() == 3);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("vector.scalarCastSplatsToStaticArray." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Bytecode ("Unsupported expression `m & 1`") and IR (unmapped type assert in
// compileExpression) do not handle the integer ^^ lowering.
static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit)) {
    @("int.powerOperatorRaisesRuntimeIntegers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int base() {
                return 3;
            }

            int exponent() {
                return 4;
            }

            unittest {
                int b = base;
                int e = exponent;

                assert(b ^^ e == 81);
                assert(b ^^ 0 == 1);
            }
        });
    }
}

// value.md item 7 review, finding 3: `a ~= x` grew the boxed array but left
// a promoted `arrayCells` entry (here promoted by `&a[0]`) at its OLD
// length. A subsequent in-bounds write to the newly-appended element
// (`a[1] = five();`) is unaffected -- `writeThroughArrayCell` is a silent
// no-op past the cell's own length -- but `readIndexExpression`'s cell arm
// still answers the following read from the stale, too-short cell, which
// used to throw a spurious out-of-range error before the fix. SystemLinker
// is the oracle; other backends omitted per the omit-don't-pin convention
// (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.arrayAppendRefreshesStaleCellAfterAddressOf." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int five() {
                return 5;
            }

            int f() {
                int[] a = [one()];
                auto p = &a[0];
                a ~= two();
                a[1] = five();
                return a[1];
            }

            unittest {
                assert(f() == 5);
            }
        });
    }
}

// value.md item 7 review, finding 4: `runSliceAssignExpression`'s bounded
// form (`a[i .. j] = x`) writes `locals[variable]` directly but never
// refreshes a promoted `arrayCells` entry -- here promoted by `&a[0]` --
// which `readIndexExpression`'s cell arm reads in preference to the boxed
// mirror. Only indices `0 .. 2` are assigned; `a[2]` must stay untouched.
// See the sibling `dynamicArray.sliceFillAssignmentWritesThroughSlicePromotedCell`
// fixture in arrays.d for the full-slice-fill variant. SystemLinker is the
// oracle; other backends omitted per the omit-don't-pin convention
// (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.boundedSliceAssignmentWritesThroughAddressOfPromotedCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int three() {
                return 3;
            }

            int ninetyNine() {
                return 99;
            }

            int f() {
                int[] a = [one(), two(), three()];
                int* p = &a[0];
                a[0 .. 2] = ninetyNine();
                return a[0] + a[1] + a[2];
            }

            unittest {
                assert(f() == 99 + 99 + 3);
            }
        });
    }
}

// value.md review (finding 5): `bump(int[] s)` binds `s` via
// `recordParameterSliceAlias` -- a slice-expression argument never calls
// `promoteSliceArrayCell`, so `s` itself never gets an `arrayCells` entry --
// while `a`, the slice's source, already has one (promoted here by
// `&a[0]`). `s[0] = ninetyNine();` reached `writeThroughSliceAlias`, which
// refreshed only the boxed `locals` mirror for `a`, never `a`'s own
// promoted cell; the following `return a[0];` reads through
// `readIndexExpression`'s cell arm, which is authoritative over the boxed
// mirror and so kept answering with the stale, pre-write value.
// SystemLinker is the oracle; other backends omitted per the
// omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.sliceParameterWriteThroughRefreshesSourceCellAfterAddressOf." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            void bump(int[] s) {
                s[0] = ninetyNine();
            }

            int f() {
                int[] a = [one(), two()];
                auto p = &a[0];
                bump(a[]);
                return a[0];
            }

            unittest {
                assert(f() == 99);
            }
        });
    }
}

// value.md review (finding 6): `writePointerTarget` called
// `writeThroughArrayPointer` but not `writeThroughStructFieldPointer`, so
// `(*p)++` through a struct-field pointer read the promoted `structCells`
// entry (via `pointerTargetValue`/`structFieldPointerCellValue`) but wrote
// only the pointer's own boxed snapshot back through the fallback
// `writeLocation` call at the bottom of `writePointerTarget` -- the next
// `*p` re-read the stale cell instead of the freshly-incremented value.
// SystemLinker is the oracle; other backends omitted per the
// omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.structFieldPointerCompoundIncrementWritesThroughCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int f() {
                struct S {
                    int x;
                    int y;
                }

                S s = S(one(), two());
                auto p = &s.x;
                (*p)++;
                return *p;
            }

            unittest {
                assert(f() == 2);
            }
        });
    }
}

// value.md review (finding 7): once `&s.x` has promoted a `structCells`
// entry for `s`, a `ref` LOCAL bound directly to `s.x` (recorded via
// `recordStructFieldAlias`/`structFieldAliases`, the only reachable path to
// `writeThroughStructFieldAlias`) writes `ninetyNine()` through
// `writeThroughStructFieldAlias`, which refreshed only the boxed `locals`
// mirror for `s`, never `s`'s own promoted cell. The following `return *p;`
// reads through `pointerTargetValue`/`structFieldPointerCellValue`, which is
// authoritative over the boxed mirror and so kept answering with the stale,
// pre-write value. SystemLinker is the oracle; other backends omitted per
// the omit-don't-pin convention (unconfirmed there).
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.structFieldRefLocalWriteThroughRefreshesCellAfterAddressOf." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            int f() {
                struct S {
                    int x;
                    int y;
                }

                S s = S(one(), two());
                auto p = &s.x;
                ref int r = s.x;
                r = ninetyNine();
                return *p;
            }

            unittest {
                assert(f() == 99);
            }
        });
    }
}

// Whole-struct assignment (`s = S(...)`) is a genuine in-place copy into
// `s`'s existing storage in D -- unlike an array rebind, `s` keeps denoting
// the SAME storage after the assignment. An earlier `int* p = &s.x` must
// therefore observe the new field value afterward: `writeCelledLocal`'s
// struct branch refreshes the promoted `structCells` entry's scalar-field
// bytes (`writeStructCellScalarFields`) whenever the assigned value is still
// a struct, so a later deref-read through `p`
// (`structFieldPointerCellValue`) sees the new value rather than a stale
// cell.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.wholeStructAssignmentVisibleThroughEarlierFieldPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
                int y;
            }

            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int eight() {
                return 8;
            }

            int nine() {
                return 9;
            }

            int f() {
                S s = S(one(), two());
                int* p = &s.x;
                s = S(eight(), nine());
                return *p;
            }

            unittest {
                assert(f() == 8);
            }
        });
    }
}

// value.md final review (finding 1): `recordStructFieldAlias` records ANY
// `DotVarExp` initializer bound to a `ref` local -- including a non-scalar
// (array/nested-struct) field -- so `writeThroughStructFieldAlias` reached a
// promoted `structCells` entry for a field it cannot represent as a native
// scalar. Once `&s.x` has promoted `s`'s cell, a later `ref int[] r = s.arr;
// r = [...]` write walked into the same unguarded `writeScalar` call the
// scalar sibling uses, which throws on a non-scalar field type. Expect the
// unrelated `s.x` field to still read `1`: the array-field write must skip
// the cell write entirely and leave the boxed mirror path (unaffected by
// this finding) as the sole record for a non-scalar aliased field.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("pointer.structArrayFieldRefLocalWriteDoesNotDisturbScalarFieldCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int three() {
                return 3;
            }

            struct S {
                int x;
                int[] arr;
            }

            int f() {
                S s = S(one(), [two()]);
                int* p = &s.x;
                ref int[] r = s.arr;
                r = [three()];
                return s.x;
            }

            unittest {
                assert(f() == 1);
            }
        });
    }
}
